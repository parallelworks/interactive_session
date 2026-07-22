# Activate (Parallel Works) platform reference

Dense, copy-paste-ready facts for building workflows on the Activate platform.
Everything here was verified against `pw v7.56.0`, the `interactive_session` repo
(`session_runner/v1.4`, `script_submitter/v3.6`), and live runs on this machine.

## Official documentation (authoritative — consult when in doubt)

This skill is a snapshot and **the platform docs are the source of truth**. They are
updated over time, so they may describe newer behavior than what is captured here. If
anything below conflicts with the docs, or a CLI flag / YAML field doesn't behave as
documented here, **trust the docs and fix this file** (Step 5 of the methodology):

- Building workflows — <https://parallelworks.com/docs/run/workflows/building-workflows>
- Sessions — <https://parallelworks.com/docs/run/sessions>
- `pw` CLI — <https://parallelworks.com/docs/cli>

---

## 1. Mental model

- A **workflow** is a YAML file. It defines an input **form** (`on.execute.inputs`),
  one or more **jobs**, and optionally **sessions**.
- Jobs run **on a resource**, reached over SSH (`ssh.remoteHost`). Steps are shell
  (`run:`) or reusable **actions** (`uses:`). Jobs form a DAG via `needs:`.
- A **session** exposes a web server running on a resource through the platform UI
  (a reverse tunnel). The `nginx` tutorial builds one up step by step.
- **Subworkflows** are workflows invoked from a step with `uses:` + `$yaml:`. Reuse
  `session_runner` (start a web service + make a session) and `script_submitter`
  (submit a script via SSH/SLURM/PBS) instead of writing launch logic yourself.

### Where jobs run = where you debug (IMPORTANT)
`ssh: remoteHost: ${{ inputs.resource.ip }}` runs that job's steps on the **login
node** of the selected resource. The job directory and any service process live on
**that** node, not necessarily the box you launched `pw` from.
- This Claude shell's host is itself a cluster login node (e.g. `*-mgmt`). Choosing
  the resource whose login node **is** that host (here: `gcpsmall`) puts the job dir
  and process **local**, inspectable with `ls ~/pw/jobs/...` and `ps -x`.
- Choosing `workspace` runs jobs on a **different** node (`pw-user-alvaro`); inspect
  there instead. Reach any resource's node with `pw ssh <resource>`.

---

## 2. Resources

List with `pw cluster ls` (`-o json` for fields). Status `active` = usable now.

A `compute-clusters` form input resolves to an object with these fields (inside the
workflow, via `${{ inputs.<name>.* }}`):

| field | example | notes |
|-------|---------|-------|
| `id` | `685193ec1bba202cb3341fb7` | used as `update-session` target |
| `ip` | `34.132.29.251` | login-node IP; **empty for workspace** → step runs locally |
| `name` | `gcpsmall` | |
| `type` / `provider` | `google-slurm` | |
| `schedulerType` | `slurm` / `pbs` / `''` | `''` when no scheduler (e.g. `existing`, workspace) |
| `namespace`, `user` | `alvaro` | |

**Passing a resource via the CLI:** give the **bare name string** and the platform
resolves the full object. Do NOT hand-build the object or hardcode `ip` (login IPs
change when a cluster restarts):
```bash
pw workflows run my-session -i '{"resource":"gcpsmall","scheduler":false}'
```
`pw cluster ls -o json` field names differ from the resolved object (`ipAddress` vs
`ip`); rely on name resolution, not the raw cluster JSON.

> **⚠ `compute-resources` inputs do NOT hydrate from the CLI (verified).** Bare-name
> resolution is a `compute-clusters` feature. A `compute-resources` input (the picker
> that also lists kubernetes clusters, used by `*_k8s_*.yaml`) passed as `"gcpsmall"`
> or `"pw://alvaro/gcpsmall"` reaches the workflow as a **raw string** — `.ip`/`.type`
> resolve empty and `ssh.remoteHost` steps **silently run on the workspace exec node**.
> From the UI the picker sends a full object, so this bites CLI testing only. Pass the
> object yourself in `-i`:
> - Cluster: `{"$type":"computeResource","id":"<id>","ip":"<ip>","name":"gcpsmall","namespace":"<user>","provider":"google-slurm","schedulerType":"slurm","type":"google-slurm","uri":"pw://<user>/gcpsmall","user":"<user>"}`
>   (fresh `id`/`ip` from `pw cluster ls -o json`, mapping `ipAddress`→`ip`).
> - With `$type: computeResource` the server validates `id` against **clusters** — a
>   kubernetes cluster id fails with `Compute resource not found`. Omit `$type` and the
>   object passes through **verbatim, unvalidated**: for a kubernetes cluster send
>   `{"id":"<pw kube ls id>","name":"k3sgpu","type":"kubernetes","uri":"pw://k3sgpu"}`
>   (set the fields the workflow reads: `name` for `pw kube auth`, `type` for the guards).

**The workspace as a resource:** `include-workspace: true` on a `compute-clusters`
input makes the user workspace selectable. Pass `"workspace"` (aliases:
`user-workspace`). It resolves to `id=user-workspace`, `type=computeResource`,
**empty `ip`** → SSH steps run locally on the workspace node.

---

## 3. Workflow YAML schema

Top of file (enables editor autocomplete; harmless at runtime):
```yaml
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
```

### Top-level keys
| key | purpose |
|-----|---------|
| `permissions` | list of users/groups allowed to run; `['*']` = everyone. **Also required for the `pw` client to be auto-authenticated inside the workflow** — without `permissions: ['*']`, in-workflow `pw` calls (e.g. `pw agent open-port`) fail to authenticate. Always set it. |
| `sessions` | named session objects this workflow creates |
| `jobs` | the job DAG |
| `env` | workflow-level environment variables injected into every job/step's runtime env. **The canonical way to make `PW_API_KEY` available to your workflow code** — set `env: { PW_API_KEY: ${PW_API_KEY} }` (see §12). **⚠ Do NOT also name an input *group* `env`** if this block references `${{ inputs.env.* }}`: the shared `env` name makes the expression engine recurse → `400 Expression Parser Error: max recursion exceeded`, which fails **both `--dry-run` and `pw workflows run`** (the web UI may still submit it). Name the group e.g. `env_vars`. |
| `'on'.execute.inputs` | the input form (note the quoted `'on'` to avoid YAML's bool) |

### `sessions`
```yaml
sessions:
  session:                 # arbitrary name; reference as ${{ sessions.session }}
    useTLS: false          # service speaks plain HTTP
    redirect: true         # after launch, redirect the user to the Sessions page
    # useCustomDomain: ${{ inputs.resource.type == 'kubernetes' }}  # SaaS *.activate.pw
```

### `jobs.<name>`
```yaml
jobs:
  myjob:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}   # run steps on this host (empty ⇒ local)
    working-directory: ${{ inputs.service.rundir }}   # optional; default = job dir
    needs: [otherjob]                          # DAG edges
    if: ${{ inputs.resource.type != 'kubernetes' }}   # conditional execution
    steps:
      - name: A shell step
        run: |
          echo hello
        cleanup: |                              # runs on cancel/failure (e.g. scancel)
          echo cleaning up
      - name: A reusable action
        uses: parallelworks/checkout
        early-cancel: any-job-failed            # cancel this job if any job fails
        with: { ... }
```

### Steps: `run` vs `uses`
- `run:` — shell. `set -x` for tracing. Emit annotations with
  `echo "::notice::msg"`, `::warning::`, `::error title=Error::msg`, `::group::`/`::endgroup::`.
- Export step outputs: `echo "KEY=value" | tee -a $OUTPUTS`, then read with
  `${{ needs.<job>.outputs.KEY }}` or `${{ needs.<job>.steps.<id>.outputs.KEY }}`.
- `uses:` — an action. Common ones seen in the repo:
  - `parallelworks/checkout` — clone a git repo **into the job dir** (`PW_PARENT_JOB_DIR`).
    `with: { repo, branch, sparse_checkout: [paths...] }` (list items may be templated).
    Verified: `sparse_checkout: [workflow/readmes]` materializes
    `${PW_PARENT_JOB_DIR}/workflow/readmes`, visible to later `needs:`-dependent jobs.
    This is **the** way to get code onto the node — see §10. Every real session YAML in
    the repo (e.g. `workflow/yamls/webshell/general_v4.yaml`) starts preprocessing with a
    `parallelworks/checkout` of `interactive_session` + a `sparse_checkout` of the service dir.
  - `parallelworks/update-session` — register/refresh a session (target/name/slug/remoteHost/remotePort)
  - `parallelworks/cancel-jobs` — cancel sibling jobs (e.g. a `tail -f` streamer)
  - `parallelworks/scheduler-agent`, `parallelworks/wait-for-agent` — dynamic compute node
  - `github/parallelworks/interactive_session@main` + `$yaml:` — call a subworkflow (below)

### Calling a subworkflow
```yaml
- uses: github/parallelworks/interactive_session@main
  $yaml: workflow/session_runner/v1.4/general.yaml   # path within that repo
  with: { ...subworkflow inputs... }
# or a marketplace slug:
- uses: marketplace/script_submitter/v3.6
  with: { ... }
```

### Inputs (`on.execute.inputs`)
Each input has a `type`. Groups nest via `items`. Visibility via `hidden`/`ignore`
expressions (`ignore: ${{ .hidden }}` mirrors the hidden flag).

| type | renders / resolves to |
|------|----------------------|
| `string`, `integer`, `number`, `boolean` | scalar (`number` = float, `integer` = int); numbers arrive as **strings** in `${{ }}`/shell — guard with `${v:-default}` |
| `editor` | multi-line text box (e.g. scheduler directives) |
| `dropdown` | `options: [{label, value}]` |
| `group` | container with `items:` (values at `inputs.<group>.<item>`) |
| `list` | repeater the user adds rows to; each row has the fields under `template:`. At runtime `${{ inputs.<name> }}` is a **JSON array** — parse with `python3`, don't slice in shell. Items can themselves be `compute-clusters` (pass `[{"resource":"<name>"}]` in `-i`). See `workflow/tutorials/round-robin-failover/`. |
| `compute-clusters` | resource picker → resource object (§2); `include-workspace: true/false` |
| `slurm-partitions` | partition dropdown; needs `resource: ${{ inputs.resource }}` |

Common attributes: `label`, `default`, `tooltip`, `optional: true`, `hidden: <expr>`,
`ignore: <expr>`, `collapsed: true`. Expressions read other inputs, `org.<VAR>`
(org secrets/vars, e.g. `${{ org.JUICE_TOKEN }}`), and `${{ .hidden }}`.

### Expressions & env
- `${{ ... }}` — platform templating, evaluated **before** the shell sees the line
  (inputs, `needs.*.outputs`, `sessions.*`, `org.*`, comparisons).
- `${VAR}` / `$VAR` — ordinary shell, evaluated at runtime on the node.
- Useful runtime env vars: `PW_PARENT_JOB_DIR` (parent run's job dir — use for all
  shared paths), `PW_JOB_DIR`, `PW_JOB_ID`, `PW_RUN_SLUG` (the run's slug — the argument
  `pw workflows runs cancel` takes), `PW_USER`, plus all `PW_*`. The
  `inputs.sh` convention captures these with `env | grep '^PW_'`.

### Multi-job orchestration (DAG, outputs, fan-out — all verified)
Not every workflow needs a subworkflow — plain job orchestration is a first-class
use (subworkflows are specifically for job *submission* and *sessions*). The job
graph gives you sequencing, data flow, conditionals, and parallelism:

- **Sequencing & sharing:** `needs: [a, b]` makes a job wait for `a` and `b`. All
  jobs in a run share `${PW_PARENT_JOB_DIR}`, so a file one job writes there is
  readable by later jobs (`cd ${PW_PARENT_JOB_DIR}` at the top of multi-step jobs).
- **Data flow via `$OUTPUTS`:** in a step, either `echo "KEY=value" | tee -a $OUTPUTS`,
  or pipe a program whose stdout is already `KEY=value` lines:
  `python3 analyze.py | tee -a $OUTPUTS`. Consume downstream as
  `${{ needs.<job>.outputs.KEY }}` (or `${{ needs.<job>.steps.<id>.outputs.KEY }}`).
- **Conditional steps/jobs:** `if: ${{ needs.analyze.outputs.good_fit == 'true' }}`.
  String equality is reliable; compute booleans **upstream** (e.g. in Python) and
  emit them, rather than doing numeric comparisons inside the expression.
- **Fan-out / fan-in:** sibling jobs that share a common `needs` but don't depend on
  each other **run concurrently**; a downstream job with `needs: [w1, w2, w3]` joins
  them. (Verified: 3 workers logged the same finish second.) For N identical workers,
  use a **matrix strategy** (`strategy.matrix`) rather than hand-copying jobs — see
  `workflow/tutorials/matrix/workflow.yaml`.
- **No env var carries a matrix worker's index** (verified) — but `PW_JOB_DIR` embeds
  it: inside a subworkflow invoked from matrix job `foo`, it looks like
  `…/subworkflows/foo-N/step_0/…`, so a step can recover its worker number by parsing
  `PW_JOB_DIR` (e.g. `grep -oE 'foo-[0-9]+'`). Needed whenever per-worker names must be
  unique and two workers may target the same resource — see the endpoint naming in
  `workflow/tutorials/pw_endpoints/04-subworkflow.yaml`. (`PW_PARENT_JOB_DIR` stays the
  top-level run dir at every nesting depth.)
- See `workflow/tutorials/nginx/` (jobs, `needs`, `$OUTPUTS`, conditional `if:`,
  sessions) and `workflow/tutorials/matrix/workflow.yaml` (fan-out workers via a matrix
  strategy — the pattern to copy for a parameter sweep).

### Step retries & attempt-aware logic (verified — see `tutorials/round-robin-failover`)
A step can declare a `retry` block; it re-runs the step while it exits **non-zero**:
```yaml
- name: Probe
  retry:
    max-retries: 2     # EXTRA attempts after the first (so 3 total); may be an expression
    interval: 2s       # wait between attempts
    timeout: 60s       # cap a single attempt
  run: |
    ssh "${TARGET_IP}" nvidia-smi   # exit code drives the retry
```
- **`exit <code>` drives it:** zero = success (stop), non-zero = retry. A step that
  exhausts its retries ends the run as **error** — pair it with a later
  `if: ${{ always }}` step to report a clean result.
- **Per-attempt env vars:** `PW_WORKFLOW_STEP_CURRENT_RETRY` (0 on the first try) and
  `PW_WORKFLOW_STEP_MAX_RETRIES` are exported each attempt. `index % N` over a list turns
  the retry counter into a **round-robin selector** (fail over to the next resource).
- **Per-attempt failover into a subworkflow `with:` block now works (re-verified July
  2026 — an earlier platform version rejected it).** The shape:
  `${{ inputs.workers get env.PW_WORKFLOW_STEP_CURRENT_RETRY get resource get ip }}`
  resolves inside a `uses:` step's `with:`, advancing with the retry counter — verified
  live with a dead first resource failing over to a healthy second
  (`workflow/tutorials/pw_endpoints/07-failover.yaml`). Two caveats still apply:
  (1) a list item picked with `get` does **not** pass through `with:` as one object —
  rebuild the resource **field by field** (`id`, `ip`, `name`, `namespace`, `provider`,
  `schedulerType`, `type`, `uri`, `user`); (2) a resource passed as a **URI string does
  not re-hydrate** through `with:`. A retried `uses:` step surfaces only the **last**
  attempt's logs via `pw workflows runs logs`; evidence of earlier attempts is the wall
  clock and whatever per-attempt output you emit yourself. (`subworkflows/<job>/step_N`
  in the job-dir path is the **step index within the job**, not the attempt number —
  retried attempts reuse the same directory.) Per-attempt SSH failover on a plain `ssh:`/`run:` step is
  `round-robin-failover`; for a matrix-style per-item resource, `matrix.worker.resource`
  passes as a native object.
- **`max-retries` can be computed:** `max-retries: ${{ needs.<job>.outputs.N - 1 }}` —
  arithmetic is evaluated in the expression layer. An upstream step writing `N` to
  `$OUTPUTS` lets a later step in the **same job** size its own retries
  (`needs.<this-job>.outputs.N`; outputs written earlier in a job are visible later in it).
- **In-step SSH vs job-level `ssh:`:** a job-level `ssh.remoteHost` pins every step to one
  host; running `ssh "$HOST" cmd` *inside* a step lets the step pick (and change) its
  target per attempt — that's how round-robin failover reaches a different resource each try.

---

## 4. `session_runner` subworkflow (start a web service + make a session)

Path: `workflow/session_runner/v1.4/<deployment>.yaml`. Older: `v1.3`.

### Choosing the deployment variant (`general` / `emed` / `hsp` / `noaa`) — IMPORTANT
Do **not** default to `general`. Pick the variant that matches the **Activate platform
host you are on** (check `pw context list` → the `user@host` / platform host):

| Platform host | Variant |
|---|---|
| `cluster.einsteinmed.edu` | `emed` |
| `noaa.parallel.works` | `noaa` |
| `activate.hpc.mil` | `hsp` |
| anything else | `general` |
| unclear | **ask the user** |

The same choice applies to **`script_submitter`** (§5) and to the **resource form
section** of your YAML: the `resource`, `scheduler`, `slurm`, and `pbs` input groups and
the `with:` block you pass differ per variant (e.g. `emed`'s `slurm` has `slurm_options`,
`partition_default`, `cpus_per_task`, `mem`, `gres_gpu_*` instead of `general`'s
`partition`). **Copy the cluster/slurm/pbs form and the `with:` mapping from the matching
`workflow/yamls/<service>/<variant>_v4.yaml`**, not from a `general` example, or
`--dry-run` will reject the run with mismatched fields.

**Invoke it** from a job that depends on your preprocessing:
```yaml
session_runner:
  needs: [preprocessing]
  ssh:
    remoteHost: ${{ inputs.resource.ip }}
  steps:
    - uses: github/parallelworks/interactive_session@main
      early-cancel: any-job-failed
      with:
        $yaml: workflow/session_runner/v1.4/general.yaml
        session: ${{ sessions.session }}
        resource: ${{ inputs.resource }}
        cluster:
          scheduler: ${{ inputs.scheduler }}            # false ⇒ run on login node
          slurm: { is_enabled: ..., partition: ..., time: ..., scheduler_directives: ... }
          pbs:   { is_enabled: ..., scheduler_directives: ... }
        service:
          start_service_script: ${PW_PARENT_JOB_DIR}/<dir>/start-template-v3.sh
          controller_script:    ${PW_PARENT_JOB_DIR}/<dir>/controller-v3.sh
          inputs_sh:            ${PW_PARENT_JOB_DIR}/inputs.sh
          slug: ""                                      # URL path after the host; "" = root app
          rundir: ${PW_PARENT_JOB_DIR}
```

**Inputs:** `session`, `resource`, `cluster.{scheduler,slurm,pbs}`,
`service.{start_service_script, controller_script, inputs_sh, slug, rundir}`.

**What it does (verified flow):**
1. Runs `inputs.sh` + your **controller_script** on the controller/login node (setup,
   installs — this node has internet).
2. Builds the start script: prepends port allocation (`service_port=$(pw agent
   open-port)` if unset), writes `SESSION_PORT` + `HOSTNAME`, installs a cleanup
   trap that runs `cancel.sh`, `touch job.started`, then appends your
   **start_service_script**. Submits it via `script_submitter/v3.6` (SSH if
   `scheduler:false`, else SLURM/PBS).
3. `wait_for_job_start` waits for `job.started`. For `scheduler:false` it forces
   `HOSTNAME=localhost` (service shares the login node).
4. `create_session` curls `http://$HOSTNAME:$SESSION_PORT` until it answers, then
   `parallelworks/update-session` (target=`resource.id`, name=`session`, slug,
   remoteHost, remotePort) → "Session is ready".
5. On cancel/failure, the trap runs `cancel.sh` and kills the process group.

**Your contract (the two scripts you provide):**
- `controller-v3.sh` — idempotent install/setup on the login node. All `inputs.sh`
  vars are available.
- `start-template-v3.sh` — must:
  - bind the service on **`${service_port}`** and **host `0.0.0.0`** (so the tunnel reaches it),
  - write `${PW_PARENT_JOB_DIR}/cancel.sh` (commands that stop the service),
  - keep the job alive (background the server + `sleep inf`, or run it in foreground).
- `inputs.sh` — your preprocessing job writes it (PW vars + form values), one
  `export VAR="..."` per line. `session_runner` sources it before both scripts.

---

## 5. `script_submitter` subworkflow (run a script on a resource)

Path: `workflow/script_submitter/v3.6/<deployment>.yaml`. Marketplace slug:
`marketplace/script_submitter/v3.6`. Used standalone, or internally by `session_runner`.
**Pick the deployment variant (`general`/`emed`/`hsp`/`noaa`) by the same host rule as
§4**, and match the `slurm`/`pbs` `with:` block to that variant.

Submission modes (auto-selected from inputs):
- `scheduler:false` → run directly on the login node over SSH.
- `scheduler:true` + `slurm.is_enabled`/`pbs.is_enabled` → `sbatch`/`qsub`, monitored to completion.
- `use_scheduler_agent:true` → provision a compute node via `parallelworks/scheduler-agent` (single-node only; recommended for single-node scheduler jobs).

**Key inputs:** `resource`, `rundir`, then either `script` (inline text, when
`use_existing_script:false`) or `use_existing_script:true` + `script_path`; `shebang`
(default `#!/bin/bash`); `scheduler`, `use_scheduler_agent`; `slurm`/`pbs` groups;
`define_cleanup_script` + `cleanup_script_path` (cleanup runs on cancel, 300s timeout,
on the compute node for scheduled jobs). Output → `run.<JOBID>.out` in `rundir`
(JOBID = the run slug, e.g. `run.my-session-00001.out`).

**Invoke it as a subworkflow** (verified — batch compute, no session):
```yaml
run_my_job:
  needs: [preprocessing]
  ssh:
    remoteHost: ${{ inputs.resource.ip }}
  steps:
    - uses: github/parallelworks/interactive_session@main
      early-cancel: any-job-failed
      with:
        $yaml: workflow/script_submitter/v3.6/general.yaml
        resource: ${{ inputs.resource }}
        rundir: ${PW_PARENT_JOB_DIR}
        use_existing_script: true
        script_path: ${PW_PARENT_JOB_DIR}/my/run.sh   # written by preprocessing
        shebang: '#!/bin/bash'
        scheduler: ${{ inputs.scheduler }}             # false ⇒ login node; true ⇒ sbatch/qsub
        use_scheduler_agent: false
        define_cleanup_script: false                   # ⚠ see gotcha below
        cleanup_script_path: ""                        # ⚠ must be passed even when unused
        slurm: { is_enabled: ${{ inputs.slurm.is_enabled }}, partition: ..., time: ..., scheduler_directives: ... }
        pbs:   { is_enabled: ${{ inputs.pbs.is_enabled }}, scheduler_directives: ... }
```

> **⚠ Subworkflow required-field gotcha (verified):** you must pass **every**
> non-optional subworkflow input that has no default — *even ones the subworkflow's
> form hides/ignores conditionally*. The defaults-filler does **not** evaluate the
> subworkflow's own `hidden`/`ignore` expressions. Omitting `script_submitter`'s
> `cleanup_script_path` fails with `Missing required fields: Cleanup Script Path`
> **or the far less obvious `Could not parse subworkflow`** (observed with the
> `general` variant, whose `cleanup_script_path` has no default — the `hsp` variant
> tolerates the omission, so this bites when switching variants). Both are caught by
> `--dry-run`. Fix: pass `define_cleanup_script: false` + `cleanup_script_path: ""`.

> **Best practice — paths inside the submitted script:** `script_submitter` `cd`s
> into `rundir` before running your script, so reference files **relative to rundir**
> (`my/run.sh`, `./out.json`), **not** `${PW_PARENT_JOB_DIR}` — for SLURM/PBS jobs the
> script runs on a *compute node* where `PW_PARENT_JOB_DIR` may not be exported. The
> home/run filesystem is shared (NFS) between login and compute nodes, so relative
> paths resolve there.

**`scheduler:true` behavior (verified on google-slurm):** `sbatch` submits to the
default partition; a cloud-burst node goes `idle~ → CONFIGURING (CF) → RUNNING`
(provisioning a fresh VM is slow — observed **8+ minutes**, and it can stall:
`scontrol show node` shows `POWERING_UP + NOT_RESPONDING` and `sacct` shows the job
`RUNNING` while the VM is still booting and the script hasn't started). Poll with long
intervals; don't assume a hang — but a stuck cloud node is also possible (infra, not
your workflow). When the node responds, your script runs and writes `HOSTNAME` = the
compute node. The login-node path (`scheduler:false`) is the fast, reliable check;
use SLURM when you genuinely need a compute node.

`script_submitter` builds the sbatch script as (verified): shebang → `#SBATCH` headers
(`--job-name`, `--time`, `--chdir=<rundir>`, `-o/-e → run.<slug>.out`) → `hostname >
HOSTNAME` → your script body. `--chdir` is why your script's cwd is `rundir` on the
compute node (relative paths work). A scheduled batch run's job dir adds `headers.sh`,
`run.sh` (the sbatch script), and `run.<slug>.out` (job stdout/stderr) alongside your
own files and outputs. Since the workflow exec node is the cluster **login node**, watch it
live there with `squeue` / `sinfo` / `sacct`. On cancel, `script_submitter` runs
`scancel` (and your cleanup script, if any, on the compute node).

**Use it directly** when your task is "run this script/sim on a cluster" with no web
session (batch compute). Use **`session_runner`** when you also need a live web UI.

---

## 6. `pw` CLI reference (verified)

Global flags: `--context`, `--platform-host`, `-v/--verbose`. Assume already
authenticated (`pw context list` shows the current user/org); never run `pw auth`.

### Workflows
```bash
pw workflows ls [-o list|json]
pw workflows create <name> --yaml file.yaml [--display-name "X"] [--description "Y"]
pw workflows update <name> --yaml file.yaml [--display-name ...] [--description ...]
pw workflows get <name> -o yaml            # fetch the stored YAML
pw workflows delete <name>
pw workflows run <name-or-file> [-i <json|file>] [--name "label"] [--dry-run] [-o json|text]
```
`run` accepts a saved name, a `marketplace/...` slug, or a local `./file.yaml` (inline
run → workflow `inline.<slug>`). `-i` is a JSON string or path to a JSON file.
`--dry-run` validates YAML+schema server-side **without executing** — run it before
every real launch. `-o json` returns the run object (`run.slug`, `run.number`,
`run.status`, plus `redirect` = the session name when one is created).

### Runs (debugging)
```bash
pw workflows runs list [--workflow <name>] [--status running|completed|error|canceled] [--limit N] [-o json|table]
pw workflows runs view  <slug> [-o text|json]
pw workflows runs logs  <slug> [--job <name>] [--step <name|idx>] [--failed] [--tail N] [-f]
pw workflows runs errors <slug> [-o text|json] [--tail N]
pw workflows runs cancel <slug>            # triggers cleanup trap → cancel.sh → stops service + session
pw workflows runs clean [filters]
```
`runs logs`/`errors` work from any host (pulled via API) — your first stop when the
service node isn't local. `--job session_runner` / `--job create_session` narrow to
the interesting subworkflow jobs. Step logs may 404 for steps that haven't produced
output yet — harmless.

### Sessions
```bash
pw sessions ls [-o table|json] [-t desktop|vscode|tunnel]
pw sessions create --type tunnel --remote-port <P> <resource> [--name N] [--open] [--connect --port <L>]
pw sessions open <name>            # open in browser
pw sessions connect <name>         # local port-forward
pw sessions stop <name>            # may 404 if the run already tore it down
```
A running tunnel session shows `STATUS=running`, `TYPE=tunnel`, `REMOTE HOST`,
`REMOTE PORT`. `pw sessions create --type tunnel` is the manual equivalent of what
`session_runner` automates.

### Other useful
```bash
pw cluster ls [-o json]            # resources + status
pw ssh <resource> ["cmd"]          # shell on a resource's node, or run "cmd" and exit
pw forward -L [bind:]lport:host:rport <resource>   # local→remote tunnel (auto-reconnects)
```

### Reaching a service on another node/cluster (`pw forward` / `pw ssh`) — verified
`pw forward` opens a **local** listener that tunnels to `host:rport` *as seen from the
`<resource>` login node* (it auto-reconnects — background it with `&` and add the kill to
`cancel.sh`). **Choosing `host` is the subtle part:**
- service on the resource's **login node** (job *not* scheduled) → use **`localhost`**. A
  login-node service answers only on the login node's own loopback — forwarding to its
  *external hostname* does **not** connect.
- service on a **compute node** (scheduled job) → use that node's name from the job's
  **`HOSTNAME` file**; the tunnel hops login→compute. **Rule: `localhost` when not scheduled,
  the `HOSTNAME` value when scheduled.** (Both require the service to bind `0.0.0.0`.)

`pw ssh <resource> "cat <path>"` reads a file off another resource — handy because
`${PW_PARENT_JOB_DIR}` resolves to the **same path on every resource** in a run (same
user/home/run number), so one job can fetch a sibling job's published file (a port it
allocated, its `HOSTNAME`) cross-cluster. **Each cluster has its own filesystem** — code or
data staged on one resource is absent on another; stage it on the resource that uses it.

A Singularity/Apptainer container shares the **host network namespace** by default, so an
in-container service reaches a host-side `pw forward` listener (and host `localhost:<port>`)
with no extra flags.

---

## 7. Job directory layout

Named run → `~/pw/jobs/<workflow-name>/<NNNNN>/` on the **execution node** (run number
**zero-padded to 5 digits**, e.g. `~/pw/jobs/my-session/00002/`). Inline run →
`~/pw/jobs/<run-slug>/`. This path is `${PW_PARENT_JOB_DIR}`.

Contents after a `session_runner` launch (all verified on a live run):
```
~/pw/jobs/my-session/00002/
├── inputs.sh                              # exported PW vars + your form values
├── controller-preprocessing-<JOBID>.sh    # inputs.sh + your controller script (what ran)
├── start-service-<JOBID>.sh               # inputs.sh + port/trap glue + your start script
├── run.sh / run-template.sh               # script_submitter's generated wrapper
├── run.<JOBID>.out                        # script_submitter stdout/stderr
├── HOSTNAME                               # the service node's REAL hostname (login *-mgmt or compute node) — not literally "localhost"; it's the pw forward target for a scheduled job (§6)
├── SESSION_PORT                           # the allocated service_port
├── job.started                            # marker session_runner waits for
├── cancel.sh                              # your shutdown script (run on cancel)
├── <your service dir>/ ...                # files checked out / staged by preprocessing
├── <your service output>                  # e.g. server.out, result.json
├── logs/<job>/step_N/                      # per-step logs
└── subworkflows/session_runner/step_0/logs/<job>/...   # subworkflow step logs
```
Debug checklist on the service node: `cat run.<JOBID>.out`, your service log,
`cat SESSION_PORT HOSTNAME`, `ps -x | grep <your-process>`, `curl localhost:$(cat SESSION_PORT)/`.

---

## 8. Best example workflows in `interactive_session`

Repo: `https://github.com/parallelworks/interactive_session` (local clone at
`/home/alvaro/interactive_session`). Read these for working patterns:

| file | why |
|------|-----|
| `DeveloperGuide.md`, `AIPromptAddingNewWorkflow.md`, `CLAUDE.md` | the repo's own how-to + conventions |
| `workflow/yamls/webshell/general_v4.yaml` | **simplest** full example (preprocessing → session_runner) |
| `webshell/{controller,start-template}-v3.sh` | minimal controller + start scripts |
| `workflow/session_runner/v1.4/general.yaml` + `README.md` | the subworkflow internals + interface |
| `workflow/script_submitter/v3.6/general.yaml` + `README.md` | submission modes + interface |
| `workflow/yamls/jupyterlab-host/general_v4.yaml` + scripts | typical: install + nginx base-path proxy + `slug` (see §11) |
| `workflow/yamls/openvscode/general_v4.yaml` | session whose `slug` is a query string (`?folder=...`) |
| `workflow/yamls/kasmvnc-container/` | complex: containers, multiple options |

Conventions: scripts idempotent; service binds `${service_port}` on `0.0.0.0`; write
`cancel.sh`; end with `sleep inf`; all shared paths under `${PW_PARENT_JOB_DIR}`; form
inputs grouped into a cluster group + a service group; `permissions: ['*']`.

---

## 9. Where to look for working patterns (use the repo, not invented examples)

Learn from the **real workflows already in the `interactive_session` repo** and the
**tutorials under `workflow/tutorials/`** — they are maintained, reviewed, and kept in
sync with the platform. Read the one closest to your task:

| Pattern you need | Look at |
|---|---|
| **Simplest session** (preprocessing → `session_runner`) | `workflow/yamls/webshell/general_v4.yaml` + `webshell/{controller,start-template}-v3.sh` |
| **Session with install + base-path nginx proxy** (§11) | `workflow/yamls/jupyterlab-host/general_v4.yaml` + `jupyterlab-host/*.sh` |
| **Session whose `slug` is a query string** | `workflow/yamls/openvscode/general_v4.yaml` (`slug=?folder=...`) |
| **`parallelworks/checkout` (sparse) to fetch code** | preprocessing job of any `*_v4.yaml` above |
| **Fan-out / sweep over N workers** (matrix strategy) | `workflow/tutorials/matrix/workflow.yaml` (use this for sweeps) |
| **Job DAG: `needs`, `$OUTPUTS`, sessions, `update-session`, `pw agent open-port`** | `workflow/tutorials/nginx/` (`readme.md` + `workflow.yaml`, staged 1→4) |
| **Step `retry`, attempt-aware vars, `list` inputs, computed `max-retries`, failover** | `workflow/tutorials/round-robin-failover/` (staged README + `workflow.yaml`) |

> **Adding a new tutorial requires maintainer approval.** Tutorials must each show
> something new and non-repetitive — do not add one to `workflow/tutorials/` without
> sign-off from the repo maintainer (Alvaro). Prefer pointing at an existing tutorial.

---

## 10. Getting your workflow code onto the node

`parallelworks/checkout` clones a git repo into the job dir — that is how every real
session YAML delivers its `controller-v3.sh` / `start-template-v3.sh` (§3). **Do not
base64-embed files** (the old approach); use one of these two modes.

### Mode A — Claude has write access (recommended)
Ask the user to grant write access via a **deploy key with write permission** on the
repo. Then:
1. Do all work on a **development branch — never push to `main`.**
2. Commit and push your workflow code (scripts, etc.) to that branch.
3. In preprocessing, `parallelworks/checkout` that **branch** (sparse-checkout your
   service dir), exactly like the repo examples but with `branch: <your-dev-branch>`.
4. The user reviews and merges the branch themselves; then flip the `branch:` to `main`.

### Mode B — Claude has no write access (cannot push)
`parallelworks/checkout` can't fetch code that isn't pushed yet, so stage it on the
resource and **mimic** checkout with a copy step:
1. Create a directory on the resource (e.g. `~/pw/dev/<workflow>/`) and write your files
   there.
2. Give preprocessing **two steps**:
   - the `parallelworks/checkout` step **commented out**, configured as it will be once
     the branch is merged (`repo`, `branch`, `sparse_checkout`);
   - a **copy step** that stands in for it, materializing the same files in the job dir:
     ```yaml
     # - name: Checkout            # uncomment after the branch is merged...
     #   uses: parallelworks/checkout
     #   with:
     #     repo: https://github.com/parallelworks/interactive_session.git
     #     branch: <your-dev-branch>
     #     sparse_checkout: [ <your-service-dir> ]
     - name: Copy staged files (stand-in for checkout)
       run: |
         set -x
         cp -r ~/pw/dev/<workflow>/. .   # mimics what checkout would materialize
     ```
3. Hand the changes to the user: they push & merge, **uncomment the checkout step, and
   delete the copy step.** The two-step layout makes that swap a clean diff.

---

## 11. Sessions served from a base-path URL (nginx proxy)

A session is reached at `https://<platform-host>/me/session/<user>/<session-name>/<slug>`
— i.e. the app is served from a **URL prefix**, not the host root. Apps that build
**absolute URLs** (JupyterLab, many SPAs) break unless they know that prefix. Two
remedies, both used in the repo:

- **Tell the app its base path.** Compute it in preprocessing/`inputs.sh`:
  ```bash
  basepath=/me/session/${PW_USER}/${{ sessions.session }}
  ```
  then point the app's base-URL setting at it (JupyterLab:
  `c.ServerApp.base_url = '${basepath}'`, plus `default_url`/`static_url_prefix`/… — see
  `jupyterlab-host/start-template-v3.sh`).
- **Front it with an nginx reverse proxy** that listens on `${service_port}` and proxies
  to the app on a private port, rewriting the prefix (and setting the WebSocket upgrade
  headers). `jupyterlab-host/start-template-v3.sh` writes an `nginx.conf` and runs an
  `nginx-unprivileged` container for exactly this.
- **If the app honors `X-Forwarded-Prefix`, you need neither.** The session tunnel
  forwards that header, so an app that reads it at runtime (injecting the prefix into
  its served HTML / asset URLs) serves correctly under the base path with no base-URL
  config and no nginx proxy — WebSockets included. (Verified with Hermes' dashboard.)

The **`slug`** you pass to `session_runner` is the path appended after the session URL:
`lab` for JupyterLab, `""` for an app that serves correctly at the root, or even a query
string like `?folder=...` (openvscode). Apps that serve everything with **relative**
paths need no base path — use `slug: ""` and skip the proxy. Check the platform
[Sessions docs](https://parallelworks.com/docs/run/sessions) for current behavior.

---

## 12. AI agents & LLM-backed sessions (verified building `hermes-agent`)

### Platform LLM endpoint — a service's "brain"
OpenAI-compatible at **`https://${PW_PLATFORM_HOST}/api/openai/v1`**; auth
`Authorization: Bearer ${PW_API_KEY}` (see below). **Org-provider models (`org:*`,
e.g. `org:glm/glm-5.1`) require an `X-Allocation: <name>` header** — without it you
get `400 "X-Allocation header is required for org provider requests"`. List
allocation names at **`GET https://${PW_PLATFORM_HOST}/api/allocations`** (objects
with `name`/`unit`/`total`/`used`; e.g. `Private LLM Group`). Discover models with
`pw ai models ls [-o json]`; chat from the CLI with `pw ai chats new -p "..."
"<model-id>"`. The connected GLM models support OpenAI tool/function calling, so
you can build tool-using agents straight against the endpoint. (LibreChat points at
the same endpoint — see `librechat-singularity/controller-v3.sh`.) `PW_API_KEY` also
authenticates `GET /api/allocations`, so a job can auto-discover an allocation name at
runtime. To send `X-Allocation` from a client that takes default headers, pass it there —
e.g. langchain `ChatOpenAI(base_url=..., api_key=PW_API_KEY, default_headers={"X-Allocation": name})`
(verified) — it then rides on every request, streaming included.

**The `model` you send must be the FULL id from `pw ai models ls` / `GET /v1/models`,
not the short name the Chat model picker shows (verified, lite-agent).** The endpoint
routes by a fully-qualified id: `org:owner/provider` (e.g. `org:glm/glm-5.1`) or — for a
**session-served** model (one exposed by another `openAI: true` session, e.g. a vLLM
session) — `session:<user>:<provider>/<model>` (e.g.
`session:alvaro:marketplace.vllmrag.latest_35_session//gpt-oss-20b`; the leading `/` in
the model name yields the `//`). The picker only displays the trailing short name
(`/gpt-oss-20b`); sending that verbatim fails with
`400 "Invalid provider identifier format. Expected 'owner:provider-name'"`, which
surfaces in the built-in chat as a generic **"network error"** (the agent's brain call
500s/aborts the stream). Resolve a short name to its full id by matching it against
`GET /v1/models` (the id whose trailing segment equals the name). Session model ids embed
the *backing* session's run number and so change when it relaunches — resolve at runtime,
don't hardcode. `X-Allocation` is required for `org:*` but harmless for session models.
Session-served models can support tool calling too (gpt-oss-20b does).

### `PW_API_KEY` at runtime — the platform credential (don't persist it)
**Whenever you need `PW_API_KEY` anywhere in the workflow's code, expose it once with
a top-level `env:` block** so the platform injects it into every job/step's runtime
env:
```yaml
env:
  PW_API_KEY: ${PW_API_KEY}
```
This is the canonical way (used by `hermes-orchestrator`/`hermes-worker`). Still keep
the key OUT of `inputs.sh`: standard preprocessing writes
`env | grep '^PW_' | grep -v 'PW_API_KEY'` deliberately, and a long-running service
process inherits the key directly anyway (verified via `/proc/<pid>/environ`), so a
service can use it as the platform bearer token — `export OPENAI_API_KEY="${PW_API_KEY}"`
— with no org secret. Expose it via the top-level `env:` block, read it from the
runtime env, and never persist it to `inputs.sh`.

### `openAI: true` sessions → the built-in chat (don't hand-roll a chat UI)
A session declared `openAI: true` (schema-confirmed in `workflow.schema.json`)
registers its tunneled service as a **model in the platform's built-in chat**. The
service must serve `GET /v1/models` and `POST /v1/chat/completions` (SSE streaming
supported, but it must be framed carefully — see the SSE note below). Pair with
`redirect: false` (it's an API, not a page); `detach: true` to persist past the run.
```yaml
sessions:
  my_session:
    openAI: true
    redirect: false
```
This is the right way to give a session a chat interface — **don't build a bespoke
HTML chat page**. **Where it surfaces depends on where the session runs** (verified):
- **Workspace** session → chat **models**: `pw ai models ls` lists
  `session:<user>:<session-name>/<model-id>`; chat via `pw ai chats` or the web UI.
- **Cluster** session → chat **provider**: `pw ai providers ls` lists it
  (`csp: openai-tunnel`); the web Chat polls its `/v1/models` and lists its models.
  Not shown in `pw ai models ls`, and `pw ai chats` may not target it — use the web Chat.

Both work in the built-in chat — the tunnel makes location transparent
([Session Tunnels](https://parallelworks.com/docs/ai/ai-providers/session-tunnels)),
so a cluster agent needs no workspace proxy.

**One session can expose MANY models — and the platform re-polls (verified,
hermes-agent).** Each entry your `/v1/models` returns registers as its own chat
model `session:<user>:<session-name>/<model-id>`, all routed to the same session's
`/v1/chat/completions`; branch on the request's `model` field to send each to the
right place. The list is **dynamic**: the platform re-polls `/v1/models`, so models
you add later (e.g. when a new backend appears) show up without relaunching the
session. This is a clean way to surface several agents/targets from one
**workspace** session (one alternative to launching a separate per-cluster session
per target — both work) — the hermes orchestrator advertises itself **plus one
`hermes-<cluster>` model per worker**, routing a per-worker chat straight to that
worker's own endpoint.

**Serving SSE so the built-in chat doesn't abort it (hard-won — `http.server`):**
the chat sends `stream: true`; if your streamed reply isn't framed the way the
proxy expects it kills the chat with `stream error … INTERNAL_ERROR; received from
peer` (and your server logs a `BrokenPipeError`). Two requirements, both needed:
1. **Reply over HTTP/1.1 with `Transfer-Encoding: chunked`** (set
   `protocol_version = "HTTP/1.1"` on a `BaseHTTPRequestHandler`, add the header,
   write each SSE event as one chunk `b"%x\r\n%s\r\n"`, end with `b"0\r\n\r\n"`).
   An HTTP/1.0 close-delimited body reads as *truncated* to the HTTP/2 proxy.
2. **Keep bytes flowing while you think.** A real LLM streams tokens continuously;
   an agent loop goes silent for seconds during each brain/tool call, and the proxy
   resets an idle stream. Emit a keepalive (an empty-content delta, or an SSE `:`
   comment) ~every second from a background thread until real output is ready.
   (Verified: a 3-second silent gap was enough to get reset.) `--dry-run` and
   non-streaming both pass while streaming fails — only a real chat exercises this.


### Runtime session discovery
`pw sessions ls -o json` gives per session: `name`, `status`, `targetName`
(`<ns>/<cluster>` or `workspace`), `targetType` (`cluster`|`workspace`),
`remoteHost`, `remotePort`, `localPort`, `openAI`, `workflowRun.{name,slug,number}`.
**Session name = `<workflow-name>_<runNumber>_<sessionKey>`** (the `sessions:` key
is the trailing part). Match the **sessionKey marker** in the name to find your
sessions at runtime — more stable than the workflow name (chosen at `create`). Map
a discovered session to its `targetName` (cluster) and `remotePort`.

### `pw ssh` from inside a running session (cross-node transport)
A service process CAN run `pw ssh <cluster> <cmd>` / `pw ssh workspace <cmd>` at
runtime (reuses pw auth; needs `$HOME/pw` on PATH — the `PATH=$HOME/pw:$PATH`
inputs.sh line covers it). Clean, inbound-port-free cross-cluster transport (e.g. an
orchestrator on the workspace → `pw ssh <cluster> curl localhost:<port>`). **stdin
is NOT reliably forwarded** through `pw ssh <c> <cmd>` — base64 the payload INTO the
command instead: `pw ssh c "echo <b64> | base64 -d | curl --data-binary @- http://localhost:P/x"`.

### Endpoint sessions (`pw endpoints`) — the v5 workflow pattern (verified)
**Upgrading a v4 workflow to this pattern? Follow the step-by-step playbook in
[v4-to-v5-endpoints-upgrade.md](v4-to-v5-endpoints-upgrade.md)** (distilled from the
openvscode and jupyterlab-host conversions). The `*_v5.yaml` workflows (openvscode,
jupyterlab-host) replace platform sessions
(`sessions:` + `session_runner`) with **endpoint sessions**: the service side runs
`pw endpoints run`/`http`, which dials out, registers a reverse tunnel, and gets a
subdomain URL (`https://<name>.activate.pw/<slug>`; `--slug` may be a query string like
`?folder=/dir` or a path like `lab`). Key facts, all verified on live runs:
- **Endpoints are platform-authenticated by default**: an anonymous request to
  `https://<name>.activate.pw/...` gets `307 → https://<platform-host>/?sessionRedirect=…`.
  A service that relied on the session tunnel's login (e.g. Jupyter with `token = ''`)
  keeps the same trust model behind an endpoint; only serving it "publicly"
  (`pw endpoints http --help`) changes that.
- **The endpoint name is a registry key, not the subdomain**: a random subdomain is
  assigned by default (`-s/--subdomain` pins one). Names are how you *find* endpoints —
  `pw endpoints list | grep -w <name>` — so build them from `${PW_RUN_SLUG}` (plus the
  resource name when several workers share a run). Killing the client process (cancel
  the run/step) deregisters the endpoint within seconds; racing/fan-out over a shared
  name prefix is shown in `workflow/tutorials/pw_endpoints/` (verified two-resource
  first-start-wins race).
- **Base-path apps need no base_url and no nginx on a subdomain endpoint**
  (`jupyterlab-host/start-template-v4.sh`): subdomain endpoints serve at the root, so
  `pw endpoints run ${pw_endpoints_args} -- jupyter-lab --port {port} --config …` is
  enough — v3's nginx proxy + base-path config is obsolete in v5. For path-based
  endpoints (`--no-subdomain`) set the app's base path to the `{path}` token
  (exported as `PW_ENDPOINT_PATH`) instead.
- **`pw endpoints run` substitutes the `{port}` token** (also exports `PORT`) into the
  wrapped command — shell `${port}` expands to empty *before* `pw` sees it, so the app
  falls back to its default port (code-server → `:80` → `EACCES`, instant exit) while
  the tunnel forwards to the assigned port. Always write `{port}`.
- **Lifecycle = the tunnel client.** In v5 the workflow *run* completes once
  `wait_for_endpoint` sees the name in `pw endpoints list` (it touches the
  `skip_cleanups_file` and `parallelworks/cancel-jobs` the submitter); the service
  outlives the run. `pw endpoints delete <name>` tears down the whole remote process
  tree (verified: the `pw endpoints run` child dies with it).
- **Env-var auth for containers/sidecars (v7.79.0):** the CLI authenticates from
  `PW_API_KEY` + `PW_PLATFORM_HOST` env vars with no config file — this is how to run
  it in a pod. `ghcr.io/parallelworks/pw-cli:<ver>` is distroless (entrypoint
  `/usr/local/bin/pw`, nonroot 65532), so pass subcommands via container `args:`.
- **Kubernetes: run the client as a sidecar** (see
  `workflow/yamls/openvscode/general_k8s_v5.yaml`): the app container serves its port,
  the `pw-cli` sidecar runs `pw endpoints http --name <n> -o text <port>` against pod-local
  `localhost:<port>`; feed `PW_API_KEY` from a Secret created with
  `kubectl create secret generic ... --from-literal=PW_API_KEY="${PW_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -`
  (top-level `env: {PW_API_KEY: ${PW_API_KEY}}` exposes it to the step; the key never
  lands in a file). Unlike v5 non-k8s, the k8s run must **stay alive** (log streaming)
  and clean up on cancel: a Deployment restarts an exited sidecar, so the endpoint
  cannot own the pod's lifecycle — cancel run → `kubectl delete` → endpoint deregisters.
- `PW_RUN_SLUG` holds the **run slug** (same in every job) — build the endpoint name as
  `<service>-${PW_RUN_SLUG}` in one job and wait for it in another. (`PW_JOB_ID` carries
  the same value, but prefer `PW_RUN_SLUG` — the name says what it is.) It is also the
  argument `pw workflows runs cancel` takes, enabling **fail-loud self-cancellation**:
  the openvscode v4-suffixed start template runs `pw workflows runs cancel ${PW_RUN_SLUG}`
  when `pw endpoints run` exits non-zero, so a failed service tears down the whole run
  instead of leaving `wait_for_endpoint` polling forever. Both vars reach scheduled
  compute nodes via the `inputs.sh` `env | grep '^PW_'` capture.

### More verified gotchas
- **`pw workflows run <name>` uses the STORED definition.** After editing a YAML,
  `pw workflows update <name> --yaml file.yaml` first, or the run uses the old form
  (e.g. `400 Missing required fields` for an input you removed).
- **`pw workflows create --yaml <path>` with an unreadable path still creates the
  workflow — empty** ("workflow created but failed to read YAML file"), and a
  subsequent `run` executes that empty definition instead of erroring. The Bash shell
  cwd is not guaranteed between tool calls — pass the YAML as an **absolute path**, and
  recover with `pw workflows update <name> --yaml <abs-path>`.
- **Pin a service port:** export `service_port` in `inputs.sh` and `session_runner`
  uses it (it only runs `pw agent open-port` when unset) — handy when another
  service must reach it at a known port.
- **Long synchronous requests through the session tunnel can `502 Proxy Error`**
  (~a minute+ exceeds the proxy timeout). Stream to keep bytes flowing, or use an
  async job+poll pattern for long work.
- Transient `pw workflows run/cancel` API timeouts happen — just retry.
- **List-template `default:`s do not fill explicit empty strings (probable platform
  bug — verified July 2026).** Three paths behave differently for a field passed as
  `""`: a **top-level input** is default-filled; a value passed **directly to a
  subworkflow input** is filled by that subworkflow's own default; but a **list-template
  field** (e.g. `workers[0].slurm.time` from an inputs JSON copied off a past run)
  stays `""` and flows through `with:` chains untouched. Consequence: an empty
  `slurm.time` reaches `script_submitter`, and the `general`/`emed`/`noaa` variants
  emit `#SBATCH --time=` → `sbatch: error: Invalid --time specification` (only `hsp`
  guards it). Do NOT patch the submitters and do NOT add warnings to the tutorials —
  Alvaro is reporting the `default:` behavior to the platform devs (July 2026); expect
  it to be fixed platform-side. If a scalar input must be guarded, a ternary works
  (`"${{ x == '' ? '1h' : x }}"` — quote it: the ternary's `: ` breaks plain YAML scalars).
