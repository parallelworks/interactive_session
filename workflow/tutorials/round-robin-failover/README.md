# Round-Robin Failover — A Workflow Tutorial

This tutorial builds a workflow that probes a **list of compute resources** for an
available GPU and **falls over to the next resource** when one fails. It starts with a
manual check, then automates it step by step using Activate workflows.

By the end you will understand how to:

- Run a command on a chosen resource over SSH from inside a step
- Retry a failing step with the `retry` block
- Cycle through a list of resources round-robin, one per attempt
- Read a `list` input and use per-attempt environment variables
- Compute `max-retries` dynamically so each resource is tried exactly once

---

## Prerequisites

- An Activate account with **two or more resources** you can SSH into, at least one
  with a GPU and (ideally) one without — so you can see the failover happen.
- Basic familiarity with YAML.

The examples below use two real resources: `gcpsmall` (no GPU) and `a30gpuserver`
(has an NVIDIA A30).

---

## Stage 1 — Manual check

SSH into a resource and ask the GPU driver to report itself:

```bash
ssh gcpsmall nvidia-smi
# NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver...   (exit 9)

ssh a30gpuserver nvidia-smi
# +---------------------------------------------------------------+
# | NVIDIA-SMI 580.159.03   Driver Version: 580.159.03  ...        |   (exit 0)
```

`nvidia-smi` exits **0** when a GPU and driver are present and **non-zero** otherwise.
That exit code is the only signal we need. The goal: given a list of resources, find
the first one where `nvidia-smi` succeeds.

---

## Stage 2 — Probe one resource, with a retry

A workflow can run that same check. The interesting part is that the step does **not**
pin itself to a host with a job-level `ssh:` block — it runs on the workflow executor
and SSHes to a resource we choose *inside* the step. That choice is what we will vary
between attempts later.

```yaml
permissions:
  - '*'                                   # also lets the in-workflow pw client authenticate

jobs:
  round_robin_fallback:
    steps:
      - name: Probe GPU
        retry:
          max-retries: 2                  # 1 first try + 2 retries = 3 attempts
          interval: 2s                    # wait between attempts
          timeout: 60s                    # give up an attempt after 60s
        run: |
          ssh "${{ inputs.resource.ip }}" nvidia-smi   # SSH to the picked resource
          EXIT_CODE=$?
          echo "EXIT_CODE=${EXIT_CODE}" >> $OUTPUTS     # publish for a later step
          exit ${EXIT_CODE}                             # non-zero → retry fires
      - name: Check Exit Code
        if: ${{ always }}                 # run even after the probe exhausts its retries
        run: |
          EXIT_CODE="${{ needs.round_robin_fallback.outputs.EXIT_CODE }}"
          if [ "${EXIT_CODE}" = "0" ]; then
            echo "::notice::GPU is available"
          else
            echo "::error title=GPU Unavailable::nvidia-smi failed (exit code: ${EXIT_CODE})"
          fi

on:
  execute:
    inputs:
      resource:
        label: Resource
        type: compute-clusters
```

### Concepts introduced

**`retry`.**
Attaching a `retry` block to a step re-runs it when it exits non-zero. `max-retries` is
the number of *extra* attempts after the first, `interval` is the wait between them, and
`timeout` caps a single attempt. A step that keeps failing until retries are exhausted
ends as an **error**.

**SSH from inside a step (not a job-level `ssh:`).**
Setting `ssh.remoteHost` on a job would pin every step to one host. Here we instead run
`ssh "${{ inputs.resource.ip }}" nvidia-smi` inside the step, so the *step* decides which
host to reach. That freedom is what lets the next stages target a different resource on
each attempt.

**`exit ${EXIT_CODE}` drives the retry.**
The step exits with `nvidia-smi`'s code. Zero means success (no retry); non-zero triggers
the next attempt.

**`if: ${{ always }}`.**
A step (or job) is normally skipped if something it depends on failed. `always` forces it
to run regardless — here so we always report a clear result even when the probe failed.

**`$OUTPUTS` and `needs.<job>.outputs`.**
Writing `KEY=value` lines to `$OUTPUTS` publishes step outputs. A later step reads them as
`${{ needs.<job>.outputs.KEY }}`. Note this job reads its **own** earlier output via
`needs.round_robin_fallback.outputs.EXIT_CODE` — outputs written earlier in a job are
visible to later steps in that same job.

---

## Stage 3 — Round-robin across a list of resources

Instead of one resource, accept a **list** and rotate through it — attempt *k* targets
`workers[k % N]`. So if the first resource has no GPU, the retry automatically moves to
the next one.

```yaml
permissions:
  - '*'

jobs:
  round_robin_fallback:
    steps:
      - name: Round Robin Fallback
        retry:
          max-retries: ${{ inputs.max_retries }}
          interval: 2s
          timeout: 60s
        run: |
          # inputs.workers is JSON; pick workers[ retry_index % N ]
          read TARGET_IP TARGET_NAME <<< $(echo '${{ inputs.workers }}' | python3 -c "import sys,json; w=json.load(sys.stdin); idx=int('${PW_WORKFLOW_STEP_CURRENT_RETRY}') % len(w); r=w[idx]['resource']; print(r['ip'], r['name'])")
          echo "Attempt ${PW_WORKFLOW_STEP_CURRENT_RETRY}/${PW_WORKFLOW_STEP_MAX_RETRIES}, resource: ${TARGET_NAME} (${TARGET_IP})"
          ssh "${TARGET_IP}" nvidia-smi
          EXIT_CODE=$?
          echo "EXIT_CODE=${EXIT_CODE}" >> $OUTPUTS
          exit ${EXIT_CODE}
      - name: Check Exit Code
        if: ${{ always }}
        run: |
          EXIT_CODE="${{ needs.round_robin_fallback.outputs.EXIT_CODE }}"
          if [ "${EXIT_CODE}" = "0" ]; then
            echo "::notice::GPU is available"
          else
            echo "::error title=GPU Unavailable::nvidia-smi failed on all resources (exit code: ${EXIT_CODE})"
          fi

on:
  execute:
    inputs:
      max_retries:
        type: number
        label: Max Retries
        default: 10
      workers:
        type: list                        # renders an "add another" repeater
        label: Compute Resources
        template:                         # each entry has these fields
          resource:
            label: Resource
            type: compute-clusters
```

### Concepts introduced

**`list` inputs and `template`.**
A `list` input renders a repeater the user can add rows to; each row has the fields under
`template`. At runtime `${{ inputs.workers }}` is a JSON array — here
`[{"resource": {...}}, {"resource": {...}}]`. Parse it with `python3` rather than trying
to slice it in shell.

**`PW_WORKFLOW_STEP_CURRENT_RETRY` / `PW_WORKFLOW_STEP_MAX_RETRIES`.**
On each attempt the platform exports the current retry index (0 on the first try) and the
configured maximum. Using `index % N` turns the retry counter into a round-robin selector
over the list.

**Why round-robin.** If `max_retries` is larger than the list, attempts wrap back to the
start — useful for transient failures (a resource that is briefly unreachable gets tried
again on a later pass).

---

## Stage 4 — One attempt per resource (dynamic `max-retries`)

For a pure "try each resource once, in order" probe, the number of attempts should equal
the number of resources — no more, no less. Compute it from the list length instead of
hardcoding `max_retries`.

```yaml
permissions:
  - '*'

jobs:
  round_robin_fallback:
    steps:
      - name: Get Number of workers
        run: |
          NUM_WORKERS=$(echo '${{ inputs.workers }}' | \
            python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
          echo "NUM_WORKERS=$NUM_WORKERS" | tee -a $OUTPUTS
      - name: Round Robin Fallback
        retry:
          # first try + (N-1) retries = N attempts → each resource probed once
          max-retries: ${{ needs.round_robin_fallback.outputs.NUM_WORKERS - 1 }}
          interval: 2s
          timeout: 60s
        run: |
          read TARGET_IP TARGET_NAME <<< $(echo '${{ inputs.workers }}' | python3 -c "import sys,json; w=json.load(sys.stdin); idx=int('${PW_WORKFLOW_STEP_CURRENT_RETRY}') % len(w); r=w[idx]['resource']; print(r['ip'], r['name'])")
          echo "Attempt ${PW_WORKFLOW_STEP_CURRENT_RETRY}/${PW_WORKFLOW_STEP_MAX_RETRIES}, resource: ${TARGET_NAME} (${TARGET_IP})"
          ssh "${TARGET_IP}" nvidia-smi
          EXIT_CODE=$?
          echo "EXIT_CODE=${EXIT_CODE}" >> $OUTPUTS
          exit ${EXIT_CODE}
      - name: Check Exit Code
        if: ${{ always }}
        run: |
          EXIT_CODE="${{ needs.round_robin_fallback.outputs.EXIT_CODE }}"
          if [ "${EXIT_CODE}" = "0" ]; then
            echo "::notice::GPU is available"
          else
            echo "::error title=GPU Unavailable::nvidia-smi failed on all resources (exit code: ${EXIT_CODE})"
          fi

on:
  execute:
    inputs:
      workers:
        type: list
        label: Compute Resources
        tooltip: >-
          Ordered list of compute resources to probe for an available GPU. They are
          tried one at a time, in list order, until one responds to nvidia-smi.
          Put your preferred resource first; add more as fallbacks.
        template:
          resource:
            label: Resource
            type: compute-clusters
            include-workspace: false
            tooltip: A compute resource to check for an available GPU.
```

This is the final `workflow.yaml` in this directory.

### Concepts introduced

**Arithmetic in expressions.**
`${{ needs.round_robin_fallback.outputs.NUM_WORKERS - 1 }}` evaluates the subtraction in
the platform expression layer, so `max-retries` becomes `N - 1` at runtime — giving exactly
`N` total attempts.

**A prior step's output feeding a later step's config.**
The `Get Number of workers` step publishes `NUM_WORKERS`; the very next step consumes it in
its `retry.max-retries`. Step outputs are available to later steps in the same job via
`needs.<this-job>.outputs.*` — no `needs:` edge to another job required.

---

## Run it

```bash
pw workflows run ./workflow.yaml \
  -i '{"workers":[{"resource":"gcpsmall"},{"resource":"a30gpuserver"}]}' \
  --name rr-fallback
```

With `gcpsmall` first (no GPU) and `a30gpuserver` second (has a GPU), the observed run:

```
Attempt 0/1, resource: gcpsmall (34.69.209.204)
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver...
Step Failed. Retrying in 2 seconds. Retries left: 1
Attempt 1/1, resource: a30gpuserver (gpu.parallel.works)
... NVIDIA A30 ...
::notice::GPU is available
```

If every resource lacks a GPU the probe exhausts its retries, the run ends in **error**,
and the `Check Exit Code` step (which runs `always`) emits
`::error title=GPU Unavailable::...`.

---

## Summary

| Stage | What changes | Key concept |
|---|---|---|
| 1 | Manual: `ssh <resource> nvidia-smi` | The exit code is the signal |
| 2 | Workflow probes one resource, retries | `retry`, in-step SSH, `$OUTPUTS`, `if: always` |
| 3 | Probe a list, round-robin per attempt | `list` inputs, `PW_WORKFLOW_STEP_CURRENT_RETRY`, `index % N` |
| 4 | Attempts = list length | arithmetic in `${{ }}`, step output → later step's `max-retries` |
