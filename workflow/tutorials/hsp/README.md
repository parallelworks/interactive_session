# Rendering a Fractal on Activate — A Workflow Tutorial

This tutorial turns a small, self-contained fractal renderer into an Activate workflow. You start by running the script by hand on a cluster so you can see exactly what it does, then automate it one piece at a time. Each stage has a matching workflow file you can run as-is from the Activate UI.

By the end of the stages built so far you will understand how to:

- Define workflow inputs — with labels, tooltips, defaults, and validation — and run steps on a remote cluster over SSH
- Use `needs` to sequence jobs and to run independent jobs in parallel
- Pull example code onto the cluster with the `checkout` action
- Pass workflow inputs into your scripts as environment variables
- Create a browser session automatically with the `update-session` action
- Pick a free port at runtime with `pw agent` and pass values between jobs as outputs
- Surface messages in the workflow UI with log annotations (`::notice::`, `::warning::`, `::error::`)
- Submit the job to the cluster scheduler (SLURM) — then stream its output, monitor it, and clean it up
- Build a form that adapts to the chosen resource with dynamic dropdowns and show/hide rules
- Replace the hand-rolled scheduler logic with a reusable subworkflow that submits your script (SLURM and PBS)

---

## Prerequisites

- An Activate cluster you can reach, with SSH access to its controller node
- Python 3.6 or newer on the cluster — `install.sh` uses it to build the demo's own virtual environment (the demo itself uses only the standard library, so there is nothing else to download)
- Basic familiarity with YAML

---

## The example

The thing we are automating lives in [`fractal-demo/`](fractal-demo/README.md): a small script that renders a Mandelbrot fractal *and* serves a web page showing the progress live.

```
  run.sh ──renders──▶ fractal.png + status.json ──serves──▶ live web page
```

| Script | What it does |
| --- | --- |
| `install.sh` | Builds a Python virtual environment at `~/pw/software/fractal-demo`. No packages to download. |
| `run.sh` | Renders the fractal and serves the live progress page. `RESOLUTION` sets the size (and run time); `PORT` sets the page's port. |

`run.sh` starts a web server, then computes the fractal one row at a time, writing the image and a small status file into the folder the server reads from — so the page fills in as it renders. The rest of the tutorial is about getting Activate to run this for you and to put the page in your browser.

---

## Stage 0 — Run it by hand

Before automating anything, run the demo manually so the moving parts are familiar. SSH into your cluster's controller node and fetch the example:

```bash
git clone -b hsp-tutorial https://github.com/parallelworks/interactive_session.git
cd interactive_session/workflow/tutorials/hsp/fractal-demo
```

Install the environment, then render and serve a fractal:

```bash
./install.sh                        # builds the venv at ~/pw/software/fractal-demo
RESOLUTION=1000 PORT=8000 ./run.sh  # render a 1000x1000 fractal and serve it on port 8000
```

`run.sh` starts the web server on port 8000, then renders the image one row at a time, so the page fills in top to bottom as it goes. When the render finishes it keeps serving, so the result stays up until you stop it.

### View it with a session

A **session** is a browser-accessible tunnel from the Activate platform to a port on your cluster. With `run.sh` still running, go to **Sessions → New Session** in the Activate UI and fill in:

| Field | Value |
|---|---|
| Session Type | Tunnel |
| Name | fractal |
| Target | your cluster resource |
| Remote Port | 8000 |

Click **NEW SESSION**, then open the session link to watch the fractal render in your browser.

### Cleanup

Press Ctrl+C in the terminal running `run.sh` to stop rendering and serving. If you open the session link afterward you will see an error — there is no longer anything listening on that port.

---

## Stage 1 — Run it as a workflow (`01-controller.yaml`)

Instead of SSHing in and typing commands, a workflow can fetch the code, install it, then render the fractal and serve the page for you. This is the file [`01-controller.yaml`](01-controller.yaml):

```yaml
jobs:
  install:                                    # First job: put the example on the cluster
    ssh:
      remoteHost: ${{ inputs.resource.ip }}   # Run this job's steps on the chosen cluster over SSH
    steps:
      - name: Checkout Fractal Demo
        uses: parallelworks/checkout          # Built-in action: clone code onto the cluster
        with:
          repo: https://github.com/parallelworks/interactive_session.git
          branch: hsp-tutorial
          sparse_checkout:                     # Fetch only the example directory, not the whole repo
            - workflow/tutorials/hsp/fractal-demo
      - name: Install Dependencies
        run: |
          # keep only the example directory from the sparse checkout
          mv workflow/tutorials/hsp/fractal-demo .
          rm -r workflow
          ./fractal-demo/install.sh

  run:
    needs:
      - install                               # Wait until the code is installed
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve                # run.sh both renders the fractal and serves the page
        run: RESOLUTION=${{ inputs.resolution }} PORT=${{ inputs.port }} ./fractal-demo/run.sh

'on':
  execute:
    inputs:                                   # The form users fill in before running the workflow
      resource:
        type: compute-clusters                # Renders a cluster picker
        label: Resource Target
        tooltip: The compute cluster to run the fractal example on.
        autoselect: true
        optional: false
      resolution:
        type: number                          # Renders a validated number field
        label: Resolution
        tooltip: Image size in pixels. Larger values look sharper but take longer to render.
        default: 1000
        min: 100
        max: 10000
      port:
        type: number
        label: Port
        tooltip: Port the progress web server listens on.
        default: 8000
        min: 1024
        max: 65535
```

### Concepts introduced

**`needs` — ordering and parallelism.**
By default every job in a workflow starts at the same time. `needs` makes a job wait for another to finish first. Here `run` lists `install` under `needs`, so the example is checked out and installed before `run` renders and serves it. (You will see jobs actually run *in parallel* in Stage 2.)

**`ssh` at the job level.**
Setting `ssh.remoteHost` on a job runs every step in that job on the remote cluster over SSH. Each job sets it to `${{ inputs.resource.ip }}` — the IP of whichever cluster you pick in the form.

**Expressions `${{ }}`.**
Expressions are evaluated at runtime and replaced with their values. `${{ inputs.resource.ip }}` becomes the chosen cluster's IP; `${{ inputs.resolution }}` becomes the number entered in the form.

**`uses: parallelworks/checkout` and `sparse_checkout`.**
`uses` runs a built-in action instead of a shell command. The `checkout` action clones a repository onto the cluster; `sparse_checkout` limits it to just the directories you list, so you do not download the whole repo to run one example.

**Inputs become environment variables.**
`run.sh` reads `RESOLUTION` and `PORT` from the environment, so the workflow passes the form values straight through: `RESOLUTION=${{ inputs.resolution }} PORT=${{ inputs.port }} ./fractal-demo/run.sh`. No argument parsing, no editing the script.

**`run.sh` renders, then keeps serving.**
The `run` job's one step renders the fractal and then keeps the web server up, so the job stays alive for as long as the page should be available. (Remember this — it matters in Stage 3.)

**`on.execute.inputs`.**
This section defines the run form. Each input has a `type` (`compute-clusters` renders a cluster picker, `number` a validated numeric field), a `label` shown above it, and a `tooltip` shown on hover. `number` inputs add `default`, `min`, and `max`; the resource input adds `autoselect` (pre-select a cluster) and `optional: false` (required).

To run it, open **Workflows** in the Activate UI, select this workflow, pick your cluster, adjust the resolution if you like, and click **Execute**. While it runs, open the session you created in Stage 0 to watch the fractal render.

> At this stage the session is still created by hand. The next stage lets the workflow create it for you.

---

## Stage 2 — Create the session automatically (`02-automated-session-creation.yaml`)

Stage 1 still relies on the session you made by hand in Stage 0. The workflow can create that session itself. This needs two additions: a `sessions` block that declares the session, and a job that calls the `parallelworks/update-session` action. Everything else is unchanged. This is [`02-automated-session-creation.yaml`](02-automated-session-creation.yaml):

```yaml
sessions:                                     # NEW: declare a browser session for this workflow
  fractal:
    redirect: true                            # send the user straight to this session when the workflow runs

jobs:
  install:
    # ... unchanged from Stage 1 ...
  run:
    # ... unchanged from Stage 1 ...

  session:                                    # NEW: create the browser tunnel
    needs:
      - install
    steps:                                    # no `ssh` block — this step runs on the Activate platform
      - name: Create Session
        uses: parallelworks/update-session    # built-in action that wires up a tunnel session
        with:
          remotePort: '${{ inputs.port }}'    # the port run.sh serves on
          target: ${{ inputs.resource.id }}   # the cluster's resource ID (not its IP)
          name: ${{ sessions.fractal }}       # reference to the session declared above

'on':
  execute:
    inputs:
      # ... unchanged from Stage 1 (resource, resolution, port) ...
```

### Concepts introduced

**`sessions` block.**
Declaring a session at the top of the workflow registers it with the platform. You reference it later as `${{ sessions.fractal }}`, which resolves to a unique session identifier for this run.

**`redirect: true`.**
When the workflow runs, the platform takes you straight to this session — no need to hunt for it in the Sessions panel. Only one session per workflow may set `redirect: true`.

**`update-session` runs on the platform, not the cluster.**
The `session` job has no `ssh` block. `parallelworks/update-session` wires up the tunnel from the Activate side, so it never touches the cluster. For a tunnel it needs three things: `name` (the declared session), `target` (the resource), and `remotePort` (the port on the cluster). It waits for `install` and then runs *in parallel* with `run`; the tunnel goes live as soon as `run.sh` starts serving.

**`resource.id` vs `resource.ip`.**
A `compute-clusters` input exposes both. Use `.ip` to SSH into the cluster (as the `install` and `run` jobs do); use `.id` to refer to the resource in platform actions like `update-session`.

Run this workflow and Activate drops you straight onto the progress page as the fractal renders — no manual session needed.

---

## Stage 3 — Choose the port at runtime (`03-dynamic-port-with-pw-agent.yaml`)

So far the port is hardcoded through the `port` input. If two people run the workflow on the same cluster, they collide on port 8000. Instead, let the platform hand us a free port at runtime. We drop the `port` input, ask `pw agent` for a port, and feed that one port to both `run` and the session. This is [`03-dynamic-port-with-pw-agent.yaml`](03-dynamic-port-with-pw-agent.yaml):

```yaml
permissions:                                  # NEW: lets the `pw` CLI authenticate inside the workflow
  - '*'

sessions:
  fractal:
    redirect: true

env:                                          # NEW: a workflow-level variable, visible to every step
  RESOLUTION: ${{ inputs.resolution }}

jobs:
  install:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Checkout Fractal Demo
        # ... unchanged from Stage 2 ...
      - name: Install Dependencies
        # ... unchanged from Stage 2 ...
      - name: Select Port                     # NEW: pick a free port and publish it
        run: |
          PORT=$(pw agent open-port)              # ask the platform for a port free on the cluster
          echo "PORT=${PORT}" | tee -a $OUTPUTS   # publish it as an output of the install job
          echo "::notice::Fractal will be served on port ${PORT}"   # show a message in the UI

  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve                # CHANGED: serve on the chosen port
        run: PORT=${{ needs.install.outputs.PORT }} ./fractal-demo/run.sh   # RESOLUTION now comes from env

  session:
    needs:
      - install
    steps:
      - name: Create Session
        uses: parallelworks/update-session
        with:
          remotePort: '${{ needs.install.outputs.PORT }}'   # CHANGED: same chosen port
          target: ${{ inputs.resource.id }}
          name: ${{ sessions.fractal }}

'on':
  execute:
    inputs:
      # the `port` input is gone — the workflow picks the port itself now
      resource:
        # ... unchanged from Stage 2 ...
      resolution:
        # ... unchanged from Stage 2 ...
```

### Concepts introduced

**`pw agent open-port`.**
The `pw` CLI is available in every step. `open-port` asks the platform for a port that is free on the cluster and prints it, which we capture into the `PORT` shell variable.

**`$OUTPUTS`.**
`$OUTPUTS` is a file the platform injects into each step. Writing `KEY=VALUE` lines to it publishes those values as outputs of the job. `tee -a` appends to the file *and* echoes the line to the log so you can see it. Here it publishes `PORT`.

**Workflow-level `env`.**
The top-level `env:` block defines variables available to every step in the workflow. We set `RESOLUTION` there once, so `run.sh` reads it from the environment and the run step only has to pass the port. (Earlier stages set it inline on the command — this is the same idea, hoisted to one place.)

**`needs.<job>.outputs.<name>`.**
This reads a value published by an upstream job. `${{ needs.install.outputs.PORT }}` is used in two places — the `run` job and the `session` job — so both use the exact port chosen in `install`.

**Why the port is chosen in `install`, not `run`.**
You can only read a job's outputs by listing it under `needs`, and `needs` waits for that job to *finish*. The `run` job runs `run.sh`, which serves forever and never finishes — so no job could ever read an output from it. `install` finishes, so it is the right place to pick the port and hand it to everything downstream.

**`permissions: ['*']`.**
The `pw` CLI authenticates against the Activate API. `permissions` grants the workflow a token with the same access as the user who runs it. Without it, `pw agent open-port` fails.

**Log annotations (`::notice::`).**
A line a step prints in the form `::notice::message` is surfaced as a notice in the workflow UI (there are also `::warning::` and `::error::`). It is a clean way to surface a value — here, the port that was chosen. The next stage uses these heavily.

Now each run gets its own port, so two runs on the same cluster no longer collide — and you are still redirected straight to the progress page.

---

## Stage 4 — Submit to the SLURM scheduler (`04-slurm.yaml`)

Until now everything ran on the **controller** (login) node. But heavy work belongs on a **compute node**, requested through the cluster's scheduler. This stage adds a "Schedule Job?" toggle: leave it off and the fractal runs on the controller as before; turn it on and the workflow writes an `sbatch` script, submits it, watches it, and tunnels the session to the compute node where the server actually ends up running.

This is by far the most involved file in the series — [`04-slurm.yaml`](04-slurm.yaml). We will walk through it idea by idea rather than as one block.

### Install always runs on the controller node

```yaml
  install:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}   # the controller / login node
    steps:
      - name: Checkout Fractal Demo
        # ... unchanged ...
      - name: Install Dependencies
        # ... unchanged ...
      - name: Create Run Script               # build the body the job will run, wherever it runs
        run: |
          cat <<'EOF' >> script.sh
          hostname > HOSTNAME                  # record which node we land on
          export PORT=$(pw agent open-port)    # and which port we serve on
          echo ${PORT} > PORT
          ./fractal-demo/run.sh                # RESOLUTION comes from the workflow env
          EOF
          chmod +x script.sh
```

`install` always targets `inputs.resource.ip`, the controller node — it has internet for the checkout and the venv build. Even when the fractal will later run on a compute node, setup happens here, once.

Notice the new idea: instead of running `run.sh` directly, `install` writes `script.sh` — a script body that, *wherever it eventually runs*, records its `hostname`, opens a port **on that machine**, and starts the fractal. For a scheduled job that machine is a compute node, so the port and hostname must be discovered there, not on the controller. (`RESOLUTION` is not baked in — it comes from the workflow-level `env` from Stage 3.)

> Jobs default to the same working directory (`~/pw/jobs/<workflow>/<job-number>/` on the resource). That is how files one job writes — `script.sh`, `PORT`, `HOSTNAME`, the output log — are visible to the others.

### Two paths, chosen by the resource

```yaml
  ssh_job:
    if: ${{ inputs.slurm.is_enabled != true }}    # run directly on the controller
    ...
  slurm_job:
    if: ${{ inputs.slurm.is_enabled == true }}    # submit to SLURM
    ...
```

Exactly one of these runs, selected by `if`. `ssh_job` wraps `script.sh` with a shebang and runs it on the controller; `slurm_job` prepends `#SBATCH` headers and submits it with `sbatch`. Which one fires is driven by the form (below), which keys off **`inputs.resource.schedulerType`** — an attribute of the chosen resource that says which scheduler it uses (`slurm`, `pbs`, or empty for none).

### Streaming the output live — `early-cancel` and `cancel-jobs`

```yaml
  stream_output:
    needs:
      - install
    steps:
      - name: Stream Output
        early-cancel: any-job-failed            # stop early if any job fails
        run: |
          touch run.${PW_JOB_ID}.out
          tail -f run.${PW_JOB_ID}.out          # follow the job's output in the workflow log
```

`tail -f` never returns on its own, so this job would otherwise run forever. Two things bound it:

- **`early-cancel: any-job-failed`** (the only supported value) cancels the step if any other job fails — otherwise a failure elsewhere would leave it tailing forever.
- The path job ends by stopping it explicitly:

```yaml
      - name: Cancel Streaming
        uses: parallelworks/cancel-jobs         # built-in action: cancel other jobs by name
        with:
          jobs:
            - stream_output
```

`parallelworks/cancel-jobs` cancels named jobs from inside the workflow — here, the streaming job once the real work is submitted and done.

### Keeping a scheduled job alive — `cleanup` and a monitor step

`sbatch` returns immediately: it queues the job and exits while the job runs later on a compute node. We want the SLURM job torn down if the workflow is canceled, so the submit step declares a cleanup:

```yaml
      - name: Submit SLURM Script
        run: |
          echo "::notice::Submitting SLURM Job"
          jobid=$(sbatch run.sh | tail -1 | awk '{print $4}')
          echo "jobid=${jobid}" | tee -a $OUTPUTS
        cleanup: scancel ${{ needs.slurm_job.outputs.jobid }}   # tear down the SLURM job on exit
```

But **`cleanup` runs as soon as the job exits or is canceled, in reverse order of the steps**. If `slurm_job` finished right after `sbatch`, its cleanup would immediately `scancel` the job we just submitted — killing the session before it starts. So we must *not let `slurm_job` finish* while the SLURM job is alive. The fix is a step that blocks until the job is really done:

```yaml
      - name: Monitor SLURM Job
        run: |
          jobid=${{ needs.slurm_job.outputs.jobid }}
          echo "::notice::Monitoring SLURM job ${jobid}"
          # poll squeue (confirming with sacct) until the job leaves the queue, then exit 0
          ...
```

Now `slurm_job` stays alive for the lifetime of the SLURM job. By the time `cleanup` runs, the job has already exited and the `scancel` is a harmless no-op.

### Waiting for the job to come up — `retry`

The server's host and port only exist once `script.sh` actually runs — which, for a queued SLURM job, may be minutes later. The session job polls for them:

```yaml
  session:
    needs:
      - install
    steps:
      - name: Read hostname and port
        retry:
          max-retries: 180
          interval: 10s                          # poll for up to ~30 minutes
        run: |
          if [ ! -s PORT ] || [ ! -s HOSTNAME ]; then
            echo "::notice:: PORT or HOSTNAME not ready yet"
            exit 1                                # non-zero → the retry fires again
          fi
          echo "PORT=$(cat PORT)" | tee -a $OUTPUTS
          echo "HOSTNAME=$(cat HOSTNAME)" | tee -a $OUTPUTS
      - name: Create Session
        uses: parallelworks/update-session
        with:
          remotePort: '${{ needs.session.outputs.PORT }}'
          remoteHost: ${{ needs.session.outputs.HOSTNAME }}   # the COMPUTE node, for a scheduled job
          target: ${{ inputs.resource.id }}
          name: ${{ sessions.fractal }}
```

**`retry`** re-runs a step on failure — `max-retries: 180` at `interval: 10s` keeps trying for about 30 minutes. The step exits non-zero until both files exist, so the loop effectively waits for the job to start. Note the new `remoteHost`: the tunnel now points at the compute node's hostname (it was implicitly the controller in earlier stages).

### A form that adapts to the resource — `hidden`, `ignore`, dynamic dropdowns

The inputs do the work of only asking for what the chosen resource needs.

```yaml
      scheduler:
        type: boolean
        label: Schedule Job?
        hidden: ${{ inputs.resource.schedulerType == '' }}   # hide if the resource has no scheduler
        ignore: ${{ .hidden }}                                # ...and drop the value when hidden
      slurm:
        type: group
        label: SLURM Directives
        hidden: ${{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}
        ignore: ${{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}
        items:
          is_enabled:
            type: boolean
            hidden: true
            default: true        # true unless the whole group is hidden+ignored — the ssh/slurm switch
          partition:
            type: slurm-partitions             # dynamic dropdown, populated from the resource
            resource: ${{ inputs.resource }}
          qos:
            type: slurm-qos
            resource: ${{ inputs.resource }}
            ignore: ${{ 'existing' != inputs.resource.provider }}   # only for user-registered clusters
            hidden: ${{ .ignore }}
          node_type:
            type: dropdown
            option-key: ${{ inputs.resource.ip }}   # which option list to show, keyed per resource
            options:
              some.cluster.hostname: [standard, bigmem, ...]
```

- **`hidden`** controls whether a field appears in the form; **`ignore`** controls whether its value is sent to the workflow at all. They are usually linked: `ignore: ${{ .hidden }}` (or `hidden: ${{ .ignore }}`) makes one mirror the other — `.hidden` and `.ignore` are self-references to this field's own values.
- **`inputs.resource.schedulerType`** drives the visibility: no scheduler → the toggle is hidden; not SLURM → the whole `slurm` group is hidden and ignored.
- **`inputs.resource.provider`** distinguishes a user-registered on-prem cluster (`provider == 'existing'`) from a cloud-provisioned one. Directives like account, QoS, CPUs, and nodes only make sense on `existing` clusters, so they use `ignore: ${{ 'existing' != inputs.resource.provider }}` — visible only there.
- **Dynamic dropdowns** — the `slurm-partitions`, `slurm-qos`, and `slurm-accounts` types fetch their choices from the cluster you picked (`resource: ${{ inputs.resource }}`), so you only see options that actually exist on it. A plain `dropdown` can vary its option list per resource with `option-key`.
- **`is_enabled`** is the trick behind the two `if`s: a hidden boolean defaulting to `true`. When the `slurm` group is ignored (no scheduler, or the toggle off), `is_enabled` is never sent, so `slurm.is_enabled != true` and `ssh_job` runs. When the group is active it is `true`, so `slurm_job` runs instead.

This one file does a lot — branching on the scheduler, building `sbatch` headers, streaming, monitoring, cleaning up, and a form that reshapes itself per resource. The next stage rebuilds the same behavior with a **subworkflow** that hides most of this machinery behind a reusable building block.

---

## Stage 5 — Let a subworkflow submit the job (`05-subworkflow.yaml`)

Stage 4 worked, but it hand-rolled everything: branching on the scheduler, building headers, submitting, streaming, monitoring, cleaning up — hundreds of lines, SLURM only. The **recommended** approach is not to reimplement any of that. Instead, write your script and hand it to a **subworkflow** that already knows how to submit scripts to a cluster. This is [`05-subworkflow.yaml`](05-subworkflow.yaml).

`install` just writes the script body (as in Stage 4), and the whole submit/stream/monitor/cleanup dance collapses into a single job:

```yaml
  install:
    # ... checkout + install + write script.sh (as in Stage 4) ...

  script_submitter:
    needs:
      - install
    steps:
      - name: Script Submitter
        uses: github/parallelworks/interactive_session@main   # run another workflow as a step
        with:
          $yaml: workflow/script_submitter/v3.6/hsp.yaml       # which subworkflow to run
          resource: ${{ inputs.resource }}
          rundir: ${PW_PARENT_JOB_DIR}                         # the shared job directory
          shebang: '#!/bin/bash'
          script: ${PW_PARENT_JOB_DIR}/script.sh               # the script to submit
          scheduler: ${{ inputs.scheduler }}
          slurm:                                               # pass the SLURM group straight through
            is_enabled: ${{ inputs.slurm.is_enabled }}
            partition: ${{ inputs.slurm.partition }}
            # ... account, qos, nodes, time, scheduler_directives ...
          pbs:                                                 # ...and a PBS group
            is_enabled: ${{ inputs.pbs.is_enabled }}
            account: ${{ inputs.pbs.account }}
            scheduler_directives: ${{ inputs.pbs.scheduler_directives }}
```

The `session` job is unchanged from Stage 4 — it polls for `PORT`/`HOSTNAME` and creates the tunnel.

### Concepts introduced

**Subworkflows (`uses:` + `$yaml`).**
`uses: github/parallelworks/interactive_session@main` runs *another workflow* as a step. `$yaml` selects which workflow file inside that repo to run (here `workflow/script_submitter/v3.6/hsp.yaml`), and the remaining `with:` keys are that subworkflow's inputs. The subworkflow runs as part of your run.

**The `script_submitter` subworkflow does the scheduler work.**
You give it your `script`, the `scheduler` flag, and the `slurm`/`pbs` directive groups; it does everything Stage 4 did by hand — choosing SLURM vs PBS vs running on the controller, building the headers, submitting, streaming the output, monitoring the job, and cleaning it up. It is versioned (`v3.6`) — pin a version. Because it is maintained centrally, your workflow shrinks to "write a script, hand it over."

**SLURM *and* PBS for free.**
Stage 4 only handled SLURM. The subworkflow handles both, so 05 simply adds a `pbs` input group next to `slurm` and passes it through — no new submission logic to write.

**`${PW_PARENT_JOB_DIR}`.**
The shared job directory on the resource. We pass it as `rundir` and use it to locate `script.sh`, so the subworkflow runs the script in the same directory where `install` wrote it — and where the `session` job later reads `PORT` and `HOSTNAME`.

Compared with Stage 4, the bespoke `ssh_job`, `slurm_job`, and `stream_output` jobs and the monitor-and-cleanup dance are gone, replaced by one `script_submitter` job. This is the recommended way to run a script on a cluster: don't reimplement scheduler handling — delegate it.
