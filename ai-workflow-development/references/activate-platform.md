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
  shared paths), `PW_JOB_DIR`, `PW_JOB_ID`, `PW_USER`, plus all `PW_*`. The
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
  them. (Verified: 3 workers logged the same finish second.) Generate repetitive
  jobs programmatically in your `build_yaml.py` rather than hand-copying them.
- See `workflow/tutorials/nginx/` (jobs, `needs`, `$OUTPUTS`, conditional `if:`,
  sessions) and `workflow/tutorials/matrix/workflow.yaml` (fan-out workers via a matrix
  strategy — the pattern to copy for a parameter sweep).

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
> (caught by `--dry-run`). Fix: pass `define_cleanup_script: false` +
> `cleanup_script_path: ""`.

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
pw ssh <resource>                  # shell onto a resource's node (to inspect remote job dirs)
pw forward ...                     # SSH port-forward
```

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
├── HOSTNAME                               # node the service is on (localhost if scheduler:false)
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
| **Round-robin retry / failover across resources** | `workflow/tutorials/round-robin-failover/` |

> **Adding a new tutorial requires maintainer approval.** Tutorials must each show
> something new and non-repetitive — do not add one to `workflow/tutorials/` without
> sign-off from the repo maintainer (Alvaro). Prefer pointing at an existing tutorial.

(There is an `ai-workflow-development/examples/` directory in this repo. It was a
one-off learning exercise — **do not cite or rely on it**; use the repo workflows and
tutorials above instead.)

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

The **`slug`** you pass to `session_runner` is the path appended after the session URL:
`lab` for JupyterLab, `""` for an app that serves correctly at the root, or even a query
string like `?folder=...` (openvscode). Apps that serve everything with **relative**
paths need no base path — use `slug: ""` and skip the proxy. Check the platform
[Sessions docs](https://parallelworks.com/docs/run/sessions) for current behavior.
