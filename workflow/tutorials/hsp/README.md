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
- Hand a script to a reusable subworkflow that submits it to the cluster scheduler (SLURM or PBS) and streams, monitors, and cleans up the job for you
- Build a form that adapts to the chosen resource with dynamic dropdowns and show/hide rules
- Fan out the same workflow across a whole list of resources at once with a `matrix` strategy
- Turn that fan-out into a race where the first session to come up wins and the losing workers stop themselves

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
git clone https://github.com/parallelworks/interactive_session.git
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
          branch: main
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
        default: 2500
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

**Where jobs run — `PW_JOB_DIR`.**
By default every job runs from a per-run working directory on the node it lands on: `${HOME}/pw/jobs/<workflow-name>/<job-number>`, exported to your steps as `PW_JOB_DIR` (and as `PW_PARENT_JOB_DIR`, which a subworkflow reads to find the top-level run's directory). Both jobs here share that directory — which is why `run` can call `./fractal-demo/run.sh`: `install` checked the code out into the very same place. To run a job somewhere else, set `working-directory` at the job level. The run directory is **not** removed when the workflow finishes — whatever a job writes there persists until you delete it yourself (Stage 3 shows one way, with a step `cleanup`).

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

### Run it from the command line (`pw`)

You can also run the workflow with the `pw` CLI. First create an inputs file — say `01-controller.json`:

```json
{
  "port": 8000,
  "resolution": 2500,
  "resource": "<Resource URI>"
}
```

Set `resource` to one of your active clusters, which you can list with `pw cluster list --status=active`. You can also copy the inputs JSON from any past run — click the run and open its **INPUTS** tab — where `resource` appears as a full object; you can replace that whole object with just its URI string, as above.

Run the YAML directly. This does **not** create a workflow on the platform; it just runs the file:

```bash
pw workflows run -i 01-controller.json ./01-controller.yaml
```

Or create the workflow on the platform, then run it by name:

```bash
pw workflows create --yaml 01-controller.yaml --display-name "Fractal Demo" fractal_demo
pw workflows run -i 01-controller.json fractal_demo
```

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
        cleanup: rm -r ${PW_JOB_DIR}          # NEW: delete the run directory when the step exits

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

**`cleanup` — teardown when the step exits.**
The `run` step now carries a `cleanup`. A step's `cleanup` runs when that step exits — including when the run is cancelled — and undoes whatever the step set up. Here it is a stand-in: `rm -r ${PW_JOB_DIR}` deletes the run directory (the `${HOME}/pw/jobs/...` folder from Stage 1) once the step is done. Because `run.sh` serves forever, that only fires on cancel — so it is really a "clean up after yourself when stopped" hook. In a real workflow this is where you stop what the step started: `docker stop` / `docker rm` a container, `scancel` a SLURM job, or `qdel` a PBS job. Stage 4 leans on exactly this to tear scheduled jobs down.

**Log annotations (`::notice::`).**
A line a step prints in the form `::notice::message` is surfaced as a notice in the workflow UI (there are also `::warning::` and `::error::`). It is a clean way to surface a value — here, the port that was chosen. The next stage uses these heavily.

Now each run gets its own port, so two runs on the same cluster no longer collide — and you are still redirected straight to the progress page.

---

## Stage 4 — Submit to a scheduler with a subworkflow (`04-subworkflow.yaml`)

Until now everything ran on the **controller** (login) node. Heavy work belongs on a **compute node**, requested through the cluster's scheduler. Doing that by hand is a lot of fiddly machinery — build the `#SBATCH`/`#PBS` headers, submit with `sbatch`/`qsub`, keep the workflow job alive while the queued job runs, stream its output, and tear everything down on cancel. The **recommended** approach is not to write any of that. Instead, write your script and hand it to the **`script_submitter` subworkflow**, which already does all of it. This is [`04-subworkflow.yaml`](04-subworkflow.yaml).

`install` does the same checkout and venv build as before, then writes the script body and publishes its path:

```yaml
  install:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Checkout Fractal Demo
        # ... unchanged ...
      - name: Install Dependencies
        # ... unchanged ...
      - name: Create Run Script               # build the body the job will run, wherever it lands
        run: |
          cat <<EOF >> script.sh
          hostname > HOSTNAME                  # record which node we land on
          export PORT=\$(pw agent open-port)   # \$ escaped → evaluated when the script RUNS
          echo \${PORT} > PORT
          export RESOLUTION=${{ inputs.resolution }}   # baked in NOW — env: can't reach the submitter
          ${PWD}/fractal-demo/run.sh           # ${PWD} expands NOW → absolute path to the demo
          EOF
          chmod +x script.sh
          echo "SCRIPT_PATH=${PWD}/script.sh" | tee -a $OUTPUTS   # hand the path to the subworkflow
```

The whole submit/stream/monitor/cleanup dance collapses into one job that calls the subworkflow:

```yaml
  script_submitter:
    needs:
      - install
    steps:
      - name: Script Submitter
        uses: github/parallelworks/interactive_session@main    # run another workflow as a step
        with:
          $yaml: workflow/script_submitter/v3.6/hsp.yaml        # which subworkflow to run
          resource: ${{ inputs.resource }}
          shebang: '#!/bin/bash'
          use_existing_script: true                            # we built the script in install...
          script_path: ${{ needs.install.outputs.SCRIPT_PATH }} # ...so pass its absolute path
          scheduler: ${{ inputs.scheduler }}
          use_scheduler_agent: false
          slurm:                                               # pass the SLURM group straight through
            is_enabled: ${{ inputs.slurm.is_enabled }}
            partition: ${{ inputs.slurm.partition }}
            # ... account, qos, cpus_per_task, nodes, node_type, time, scheduler_directives ...
          pbs:                                                 # ...and a PBS group
            is_enabled: ${{ inputs.pbs.is_enabled }}
            account: ${{ inputs.pbs.account }}
            scheduler_directives: ${{ inputs.pbs.scheduler_directives }}
```

The `session` job still polls for `PORT`/`HOSTNAME` and opens the tunnel — but it reads them from the *subworkflow's* run directory, because that is where the script actually ran:

```yaml
  session:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Read hostname and port
        retry:
          max-retries: 180
          interval: 10s                          # poll for up to ~30 minutes
        run: |
          rundir=./subworkflows/script_submitter/step_0        # where the subworkflow ran the script
          if [ ! -s ${rundir}/PORT ] || [ ! -s ${rundir}/HOSTNAME ]; then
            echo "::notice:: PORT or HOSTNAME not ready yet"
            exit 1                                              # non-zero → the retry fires again
          fi
          echo "PORT=$(cat ${rundir}/PORT)" | tee -a $OUTPUTS
          # HOSTNAME is the compute node when scheduled, else localhost
          # ...
      - name: Create Session
        uses: parallelworks/update-session
        with:
          remotePort: '${{ needs.session.outputs.PORT }}'
          remoteHost: ${{ needs.session.outputs.HOSTNAME }}
          target: ${{ inputs.resource.id }}
          name: ${{ sessions.fractal }}
```

### Concepts introduced

**Subworkflows (`uses:` + `$yaml`).**
`uses: github/parallelworks/interactive_session@main` runs *another workflow* as a step. `$yaml` selects which workflow file inside that repo to run (here `workflow/script_submitter/v3.6/hsp.yaml`), and the remaining `with:` keys are that subworkflow's inputs. 

**Hand it a script, not logic — `use_existing_script` + `script_path`.**
`install` writes `script.sh` and publishes `SCRIPT_PATH`; the submitter takes `use_existing_script: true` + `script_path` and runs exactly that file. The heredoc is **unquoted**, so `${PWD}` expands at *write* time — the demo is referenced by an absolute path, so it resolves wherever the script ends up running — while `\$(pw agent open-port)` and `\${PORT}` are escaped and run later, on the compute node for a scheduled job. The `resolution` input is baked in the same way (`export RESOLUTION=${{ inputs.resolution }}`): the workflow-level `env:` from Stage 3 does **not** cross into the `script_submitter` subworkflow that runs the script, so anything `run.sh` needs from the form has to travel *inside* the script.

**Reading the subworkflow's outputs — `./subworkflows/script_submitter/step_0`.**
The submitter runs your script in *its own* job directory, so the `PORT` and `HOSTNAME` files the script writes land under `subworkflows/script_submitter/step_0/`, not the parent job dir. The `session` job reads them from that relative path. (This couples to the subworkflow's internal layout — fine here, but worth knowing.)

**`retry` — waiting for a queued job to come up.**
The host and port only exist once the script actually runs, which for a queued SLURM job may be minutes later. `retry` re-runs the step on failure — `max-retries: 180` at `interval: 10s` ≈ 30 minutes — and the step exits non-zero until both files exist, so the loop waits the job out.

**A form that adapts to the resource.**
The "Schedule Job?" toggle and the `slurm`/`pbs` groups only appear when they apply: `hidden`/`ignore` key off `inputs.resource.schedulerType` (`slurm`, `pbs`, or empty) and `inputs.scheduler`. `slurm-partitions`/`slurm-qos`/`slurm-accounts` are **dynamic dropdowns** that fetch their choices from the chosen cluster, and `inputs.resource.provider == 'existing'` gates the directives that only make sense on a user-registered cluster. The hidden `is_enabled` boolean (default `true`, sent only when the group is active) is what tells the subworkflow which path to take.

**`configurations` — one-click presets for known PBS systems.**
A top-level `configurations:` block defines named presets that pre-fill the run form. Each entry lists the `inputs:` to apply — here `scheduler: true`, `pbs.is_enabled: true`, and a `pbs.scheduler_directives` block carrying the sample `#PBS` node layout for one system (`Carpenter`, `Ruth`, `Warhawk`, `Wheat`):

```yaml
configurations:
  Carpenter:
    inputs:
      scheduler: true
      pbs:
        is_enabled: true
        scheduler_directives: |
          #PBS -l walltime=00:30:00
          #PBS -V
          #PBS -q standard
          #PBS -l select=1:ncpus=192:mpiprocs=192   # the per-site node layout
  # Ruth / Warhawk (select=1:ncpus=128:mpiprocs=128), Wheat (…:nmlas=4) …
```

Pick your resource, choose the matching configuration, and the right directives are filled in for you — no need to memorize each site's `select=...`. The samples are lifted from [`workflow/script_submitter/v3.6/hsp.yaml`](../../script_submitter/v3.6/hsp.yaml); tweak the walltime, queue, or node counts in the form for a given run.

### Lessons from the script submitter (what it does for you)

You hand the subworkflow a script and a few flags; in return it runs all the machinery you would otherwise hand-write. Reading [`workflow/script_submitter/v3.6/hsp.yaml`](../../script_submitter/v3.6/hsp.yaml) is the best way to see *why* each piece exists — the highlights:

- **One path, chosen by `if`.** `ssh_job`, `slurm_job`, `pbs_job`, and `scheduler_agent_job` each carry an `if:` keyed off `slurm.is_enabled` / `pbs.is_enabled` / `use_scheduler_agent`. Exactly one runs — directly on the controller, via `sbatch`/`qsub`, or through the scheduler-agent — and a `preprocessing` job assembles the matching `#SBATCH`/`#PBS` headers from the form.
- **Streaming with `early-cancel`.** A `stream_output` job runs `tail -f run.<JOB_ID>.out` so you watch progress live. `tail -f` never returns on its own, so `early-cancel: any-job-failed` stops it if anything fails, and the path job ends with `uses: parallelworks/cancel-jobs` to stop it explicitly once the work is done.
- **`cleanup` runs on exit, in reverse step order.** The submit step declares `cleanup: scancel ${jobid}` (or `qdel`) so a canceled run tears the scheduled job down. But cleanup fires the moment the job *exits* — so if the job finished right after `sbatch`, its cleanup would `scancel` the job it just submitted, killing the session before it starts.
- **A monitor step keeps the job alive.** That is why submission is followed by a **Monitor** step that polls `squeue` (confirming with `sacct`, because an empty `squeue` can be a transient controller hiccup rather than an exit) until the job truly leaves the queue. The submitting job stays alive for the job's lifetime, so by the time `cleanup` runs the `scancel` is a harmless no-op.
- **Cleanup on the right node.** When you provide one (`define_cleanup_script` + `cleanup_script_path`), the cleanup `ssh`'s to the compute node — read from the `HOSTNAME` file — to run your `cancel.sh` *there*, since the controller can't stop a process living on the compute node.

This is the recommended way to run a script on a cluster: don't reimplement scheduler handling — delegate it, and let the subworkflow carry the streaming, monitoring, and cleanup machinery for you.

---

## Stage 5 — Fan out across resources with a matrix (`05-matrix.yaml`)

Every stage so far rendered one fractal on one resource you picked. Stage 5 runs the **same** Stage 4 workflow across a whole *list* of resources at once — each entry on its own cluster, each choosing its own controller-vs-scheduler path, each rendering its own fractal. The form turns the single resource picker into a repeatable **list** of "workers," and a **matrix strategy** turns that list into one job per entry. This is [`05-matrix.yaml`](05-matrix.yaml).

The job itself is tiny: it just hands each worker to the Stage 4 subworkflow.

```yaml
jobs:
  fractal_demo:
    strategy:
      fail-fast: true
      matrix:
        worker: ${{ inputs.workers }}        # one matrix job per element of the workers list
    steps:
      - name: Fractal Demo
        uses: github/parallelworks/interactive_session@main
        with:
          $yaml: workflow/tutorials/hsp/04-subworkflow.yaml   # run Stage 4 as a subworkflow, once per worker
          resource: ${{ matrix.worker.resource }}             # THIS job's own worker — not the whole list
          resolution: ${{ inputs.resolution }}
          scheduler: ${{ matrix.worker.scheduler }}
          slurm:                                              # the worker's own SLURM group, passed straight through
            is_enabled: ${{ matrix.worker.slurm.is_enabled }}
            # ... partition, qos, cpus_per_task, nodes, node_type, time, scheduler_directives ...
          pbs:
            is_enabled: ${{ matrix.worker.pbs.is_enabled }}
            # ... account, scheduler_directives ...
```

The form replaces the single resource block with a list the user can grow:

```yaml
'on':
  execute:
    inputs:
      resolution:
        # ... unchanged ...
      workers:
        type: list                            # a repeatable group — one entry per resource
        label: Compute Resources
        template:                             # every list item has this shape
          resource:
            type: compute-clusters
            # ... as before ...
          scheduler:
            type: boolean
            hidden: ${{ inputs.workers.[index].resource.schedulerType == '' }}   # [index] = THIS list item
            # ...
          slurm:
            # ... the same SLURM group as Stage 4, but every self-reference is inputs.workers.[index]... ...
          pbs:
            # ... same idea ...
```

### Concepts introduced

**`strategy.matrix` — fan-out.**
A `strategy.matrix` runs the job once for every value of a matrix variable. Setting `worker: ${{ inputs.workers }}` makes the variable the `workers` list itself, so the `fractal_demo` job expands into one copy per element — `fractal_demo-0`, `fractal_demo-1`, … — all running concurrently. Add a third worker in the form and a third job appears automatically; nothing in the YAML hardcodes the count.

**`matrix.<name>` vs the template's `[index]` — two different "current item"s.**
This is the subtle part, and the easiest thing to get wrong. Inside a *job*, the current matrix value is `${{ matrix.worker }}`, so each job reads *its own* worker with `matrix.worker.resource`, `matrix.worker.scheduler`, and so on. Inside the *form template*, `[index]` is a **separate** token meaning "the item being rendered" — which is why every `hidden`/`ignore`/`resource` expression in the `workers` template is written `inputs.workers.[index]...`. They are not interchangeable: `[index]` only resolves inside the list template, and in a job it silently falls back to the first element. Writing `inputs.workers.[index]` in the job (instead of `matrix.worker`) is exactly the trap that makes *every* matrix job inherit `workers[0]`'s settings.

**`list` input with a `template`.**
A `list` input renders an "add another" control in the form; `template` defines the shape of each entry. Here each entry is a full resource + "Schedule Job?" + SLURM/PBS form — the same controls Stage 4 introduced, nested one level deeper and keyed to `inputs.workers.[index]` so each row reads from its own values. The `slurm`/`pbs` groups still hide and `ignore` themselves per row based on that row's resource and scheduler choice.

**`fail-fast` and `max-parallel`.**
`fail-fast: true` cancels the remaining matrix jobs as soon as one fails. `max-parallel: N` (omitted here) would cap how many run at once; without it, every worker runs in parallel.

**Each matrix job runs the full Stage 4 workflow.**
Because the step's `$yaml` is `04-subworkflow.yaml`, every worker goes through the entire Stage 4 pipeline — install, pick a port, submit to its scheduler (or run on its controller), and register its own `fractal` session. A two-worker run where one worker has *Schedule Job?* off and the other on will run one fractal on a login node and submit the other to SLURM, side by side.

---

## Stage 6 — First start wins: race a list of resources (`06-first-start-wins.yaml`)

Stage 5 fanned the render out to **every** resource and left you with one session per worker. Stage 6 keeps the same fan-out but treats the list as a **race**: every worker starts, the first one whose session comes up **wins** (that is the one you land on), and the rest **stop themselves** — their session and their render are torn down. Use it when you have several resources and want *whichever is ready first*, not all of them. This is [`06-first-start-wins.yaml`](06-first-start-wins.yaml) and its subworkflow [`06-first-start-wins-subworkflow.yaml`](06-first-start-wins-subworkflow.yaml).

The parent is the Stage 5 matrix, almost unchanged — one job per worker, each handed to the subworkflow. The only additions are `permissions: ['*']` and the new subworkflow it calls:

```yaml
permissions:
  - '*'                                    # NEW: lets the subworkflow's pw CLI authenticate

jobs:
  fractal_demo:
    strategy:
      fail-fast: true
      matrix:
        worker: ${{ inputs.workers }}       # one job per worker — exactly like Stage 5
    steps:
      - name: Fractal Demo
        uses: github/parallelworks/interactive_session@main
        with:
          $yaml: workflow/tutorials/hsp/06-first-start-wins-subworkflow.yaml   # NEW subworkflow
          resource: ${{ matrix.worker.resource }}
          # ... resolution, scheduler, slurm, pbs — passed through exactly as in Stage 5 ...
```

All the racing lives in the subworkflow. It is Stage 4's `install` → `script_submitter` → `session` pipeline plus one new job, `first_start_wins`, that looks at the run's sessions and decides whether this worker won or lost:

```yaml
  first_start_wins:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: First Start Wins
        retry:                                  # poll until the sessions show up
          max-retries: 8640
          interval: 10s
        run: |
          MY_NAME="${{ sessions.fractal }}"
          # Look only at THIS run's *_fractal sessions that are RUNNING. The first
          # one in `pw sessions ls` order is the winner; everyone else stands down.
          decision=$(pw sessions ls -o json | ...keep this run's running *_fractal
                                                 sessions; WIN if we are the first,
                                                 LOSE if another is ahead, else WAIT...)
          [ "${decision}" = "WAIT" ] && exit 1    # nothing running yet → keep polling
          if [ "${decision}" = "WIN" ]; then
            # stay first for a few polls (the list is eventually consistent), then win
            [ "${PW_WORKFLOW_STEP_CURRENT_RETRY:-0}" -lt 3 ] && exit 1
            echo "CANCEL=false" | tee -a $OUTPUTS   # winner: leave the session up
            exit 0
          fi
          echo "CANCEL=true" | tee -a $OUTPUTS      # loser
      - name: Cancel Jobs
        if: ${{ needs.first_start_wins.outputs.CANCEL == 'true' }}   # only losers reach here
        uses: parallelworks/cancel-jobs
        with:
          jobs:
            - script_submitter                  # stop the losing render...
            - session                           # ...and its session job
      - name: Stop Session
        if: ${{ needs.first_start_wins.outputs.CANCEL == 'true' }}   # only losers reach here
        run: pw sessions stop "${{ sessions.fractal }}" || true      # delete the dead session
```

### Concepts introduced

**Same fan-out as Stage 5, but the list is a race.**
Every worker still installs and starts rendering, and `redirect: true` drops you onto the `fractal` session as soon as one is up. What `first_start_wins` adds is making sure exactly **one** session survives instead of one per worker.

**Choosing the winner from the session list.**
`pw sessions ls -o json` returns every session; the job keeps only *this run's* fractal sessions that are **running** — matched by `workflowRun.slug == ${PW_RUN_SLUG}` (the parent run's slug, shared by every worker) and a name ending in `_fractal`, filtered to `status == "running"`. Among those, the **first one the list returns** is the winner and every other worker stands down. List order is the universal tie-breaker: every worker reads the same list, so they all pick the same winner. Only running sessions count, so a worker whose own session isn't up yet while another's is simply loses.

**`permissions: ['*']` — introduced here, in the parent *and* the subworkflow.**
This is the first stage that needs it. `permissions: ['*']` grants the workflow a token with the same access as the user who runs it, which is what authenticates the in-workflow `pw` CLI for calls that touch the platform API — here `pw sessions ls` and `pw sessions stop`. Earlier stages did **not** need it: `pw agent open-port` (Stages 3–5) works without any `permissions` grant. Because the `pw sessions` calls run inside the subworkflow, the grant must be present on the **parent** too — otherwise those calls come back `401 Unauthorized` even if the subworkflow declares it.

**Confirm before committing — the session list is eventually consistent.**
Just after two sessions register, each worker can briefly see only *its own* running and think it won. So a worker that is currently in front re-checks for a few polls (guarded by `PW_WORKFLOW_STEP_CURRENT_RETRY`) before it commits; a worker that was actually beaten sees the winning session on a later poll and steps aside. Without this settle, two workers can both "win."

**One output flag drives the cleanup — no `sleep inf`.**
The winner writes `CANCEL=false` and simply finishes; its session stays up because its `script_submitter` job is still serving the page. A loser writes `CANCEL=true`, and two later steps key their `if:` off `${{ needs.first_start_wins.outputs.CANCEL }}`: **Cancel Jobs** runs `cancel-jobs` to tear down that worker's render and its `session` job, and **Stop Session** then runs `pw sessions stop` to delete the session object itself. Both are needed — canceling the `session` job stops `update-session` but leaves the registered session behind as a dead tunnel, so the explicit `pw sessions stop` is what actually removes it. Stop Session runs **after** Cancel Jobs on purpose: with `update-session` already stopped, deleting the session can't `404` an in-flight creation and fault the run. Publishing a value with `tee -a $OUTPUTS` and gating a later step on it (the `$OUTPUTS` trick from Stage 3) is what lets the winner exit cleanly instead of parking a job on `sleep inf`.
