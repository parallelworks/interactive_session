# Rendering a Fractal on Activate — A Workflow Tutorial (pw endpoints)

This tutorial turns a small, self-contained fractal renderer into an Activate workflow. You start by running the script by hand on a cluster so you can see exactly what it does, then automate it one piece at a time. Each stage has a matching workflow file you can run as-is from the Activate UI.

The web page the demo serves reaches your browser through **`pw endpoints`**: the service side dials out from wherever it runs, registers a reverse tunnel, and gets its own URL (`https://<subdomain>.activate.pw/`). There is also a [session-tunnel edition](../hsp/README.md) of this tutorial that exposes the same demo the older way, with a `sessions:` block and tunnel wiring — you do not need it to follow this one.

By the end of the stages built so far you will understand how to:

- Define workflow inputs — with labels, tooltips, defaults, and validation — and run steps on a remote cluster over SSH
- Use `needs` to sequence jobs and to run independent jobs in parallel
- Pull example code onto the cluster with the `checkout` action
- Pass workflow inputs into your scripts as environment variables
- Expose a web server through the platform with `pw endpoints run` — no tunnel wiring, no port bookkeeping: the endpoint picks a free port at runtime and hands it to your server through the `PORT` environment variable
- Detach the whole render-and-serve command from the workflow with `setsid`/`nohup`, so the run completes while the page keeps serving — deleted later with `pw endpoints delete`
- Wait for an endpoint to come online with a `retry` step, and surface its URL with `$OUTPUTS` and log annotations (`::notice::`, `::warning::`, `::error::`)
- Hand a script to a reusable subworkflow that submits it to the cluster scheduler (SLURM or PBS) and streams, monitors, and cleans up the job for you — and see why endpoints make the "where did my job land?" question disappear
- Keep a scheduled job cancelable while it is queued, then hand it off cleanly once the page is up, with the submitter's `skip_cleanups_file`
- Build a form that adapts to the chosen resource with dynamic dropdowns and show/hide rules
- Fan out the same workflow across a whole list of resources at once with a `matrix` strategy
- Turn that fan-out into a race where the first endpoint to come up wins and the losing workers stop themselves

---

## Background — sessions vs endpoints

Activate has two ways to put a web page running on a cluster into your browser: a **session tunnel** is opened by the platform, which tunnels *in* to a host and port your workflow must register; an **endpoint** dials *out* from wherever the server runs and registers itself. If sessions are new to you, skip the table — the stages explain everything they use.

| | Session tunnel | `pw endpoints` (this tutorial) |
|---|---|---|
| Who opens the connection | the platform tunnels **in** to `host:port` on the cluster | the service side dials **out** and registers itself |
| What the workflow must know | the node the server landed on and its port | nothing — the endpoint registers from wherever the script runs |
| Port | you pick one and thread it through the jobs | `pw endpoints run` assigns one and exports it as `PORT` |
| URL | `…/me/session/<user>/<session-name>` | `https://<subdomain>.activate.pw/` (subdomain endpoints serve at the root) |
| Auth | platform login | same — endpoints require platform login unless explicitly made public |
| Declared in YAML | `sessions:` block + `update-session` action | nothing — just the `pw endpoints run` command |
| Needs `permissions: ['*']` | only for `pw sessions` calls | from the first `pw endpoints` call (Stage 2 onward) |

---

## Prerequisites

- An Activate cluster you can reach, with SSH access to its controller node
- Python 3.6 or newer on the cluster — `install.sh` uses it to build the demo's own virtual environment (the demo itself uses only the standard library, so there is nothing else to download)
- Basic familiarity with YAML

---

## The example

The thing we are automating lives in [`workflow/tutorials/fractal-demo/`](../fractal-demo/README.md): a small script that renders a Mandelbrot fractal *and* serves a web page showing the progress live.

```
  run.sh ──renders──▶ fractal.png + status.json ──serves──▶ live web page
```

| Script | What it does |
| --- | --- |
| `install.sh` | Builds a Python virtual environment at `~/pw/software/fractal-demo`. No packages to download. |
| `run.sh` | Renders the fractal and serves the live progress page. `RESOLUTION` sets the size (and run time); `PORT` sets the page's port. |

`run.sh` starts a web server, then computes the fractal one row at a time, writing the image and a small status file into the folder the server reads from — so the page fills in as it renders. Note that `run.sh` reads **`PORT` from the environment** — that little detail is what makes the endpoint integration a one-liner later.

---

## Stage 0 — Run it by hand

Before automating anything, run the demo manually so the moving parts are familiar. SSH into your cluster's controller node and fetch the example:

```bash
git clone https://github.com/parallelworks/interactive_session.git
cd interactive_session/workflow/tutorials/fractal-demo
```

Install the environment, then render and serve a fractal:

```bash
./install.sh                        # builds the venv at ~/pw/software/fractal-demo
RESOLUTION=1000 PORT=8000 ./run.sh  # render a 1000x1000 fractal and serve it on port 8000
```

When the render finishes, `run.sh` keeps serving, so the result stays up until you stop it.

### View it with an endpoint

An **endpoint** exposes a locally-running web app through the platform: the `pw` CLI dials out, registers a reverse tunnel, and prints a URL — no inbound network access, no session form. With `run.sh` still serving on port 8000, open a **second terminal** on the same node and run:

```bash
pw endpoints http --name fractal 8000
```

The command prints the endpoint's URL (something like `https://<random-subdomain>.activate.pw/`) and keeps forwarding until you exit it. Open the URL to watch the fractal render in your browser. Opening it logged out redirects you to the platform login first — endpoints are platform-authenticated by default.

You can also see it in `pw endpoints list`, alongside its status and URL.

### Cleanup

Press Ctrl+C in the `pw endpoints http` terminal — the endpoint deregisters the moment the client exits (check `pw endpoints list`). Then Ctrl+C the `run.sh` terminal to stop rendering and serving.

> Two commands, two teardowns. `pw endpoints run` — used in every stage from here on — fuses them: it *spawns* the server itself, so one command serves, exposes, and tears both down together.

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
            - workflow/tutorials/fractal-demo
      - name: Install Dependencies
        run: |
          # keep only the example directory from the sparse checkout
          mv workflow/tutorials/fractal-demo .
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
By default every job in a workflow starts at the same time. `needs` makes a job wait for another to finish first. Here `run` lists `install` under `needs`, so the example is checked out and installed before `run` renders and serves it. (You will see jobs actually run *in parallel* in Stage 4.)

**`ssh` at the job level.**
Setting `ssh.remoteHost` on a job runs every step in that job on the remote cluster over SSH. Each job sets it to `${{ inputs.resource.ip }}` — the IP of whichever cluster you pick in the form.

**Where jobs run — `PW_JOB_DIR`.**
By default every job runs from a per-run working directory on the node it lands on: `${HOME}/pw/jobs/<workflow-name>/<job-number>`, exported to your steps as `PW_JOB_DIR` (and as `PW_PARENT_JOB_DIR`, which a subworkflow reads to find the top-level run's directory). Both jobs here share that directory — which is why `run` can call `./fractal-demo/run.sh`: `install` checked the code out into the very same place. To run a job somewhere else, set `working-directory` at the job level. The run directory is **not** removed when the workflow finishes — whatever a job writes there persists until you delete it yourself.

**Expressions `${{ }}`.**
Expressions are evaluated at runtime and replaced with their values. `${{ inputs.resource.ip }}` becomes the chosen cluster's IP; `${{ inputs.resolution }}` becomes the number entered in the form.

**`uses: parallelworks/checkout` and `sparse_checkout`.**
`uses` runs a built-in action instead of a shell command. The `checkout` action clones a repository onto the cluster; `sparse_checkout` limits it to just the directories you list, so you do not download the whole repo to run one example.

**Inputs become environment variables.**
`run.sh` reads `RESOLUTION` and `PORT` from the environment, so the workflow passes the form values straight through: `RESOLUTION=${{ inputs.resolution }} PORT=${{ inputs.port }} ./fractal-demo/run.sh`. No argument parsing, no editing the script.

**`run.sh` renders, then keeps serving.**
The `run` job's one step renders the fractal and then keeps the web server up, so the job stays alive for as long as the page should be available.

**`on.execute.inputs`.**
This section defines the run form. Each input has a `type` (`compute-clusters` renders a cluster picker, `number` a validated numeric field), a `label` shown above it, and a `tooltip` shown on hover. `number` inputs add `default`, `min`, and `max`; the resource input adds `autoselect` (pre-select a cluster) and `optional: false` (required).

To run it, open **Workflows** in the Activate UI, select this workflow, pick your cluster, adjust the resolution if you like, and click **Execute**. To *view* the page this stage serves, use the manual endpoint from Stage 0 (`pw endpoints http --name fractal 8000` on the controller node) — the next stage makes the workflow do that itself.

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

> At this stage the endpoint is still created by hand. The next stage lets the workflow create it for you.

---

## Stage 2 — Create the endpoint automatically (`02-automated-session-creation.yaml`)

Stage 1 still relies on the endpoint you opened by hand in Stage 0. The workflow can create it itself — by wrapping the server command in `pw endpoints run`. That one wrapper also retires the `port` input: the endpoint picks a free port at runtime and hands it to `run.sh`, so two runs on the same cluster never collide. This is [`02-automated-session-creation.yaml`](02-automated-session-creation.yaml):

```yaml
# permissions authenticates the in-workflow pw CLI — pw endpoints registers the
# endpoint through the platform API.
permissions:
  - '*'

env:                                          # NEW: a workflow-level variable, visible to every step
  RESOLUTION: ${{ inputs.resolution }}

jobs:
  install:
    # ... unchanged from Stage 1 ...

  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve
        # No --port: pw picks a free local port and exports it as PORT, which
        # run.sh reads. RESOLUTION comes from the workflow-level env block.
        run: pw endpoints run --name fractal-${PW_RUN_SLUG} -- ./fractal-demo/run.sh

'on':
  execute:
    inputs:
      # the `port` input is gone — the endpoint picks the port itself now
      resource:
        # ... unchanged from Stage 1 ...
      resolution:
        # ... unchanged from Stage 1 ...
```

### Concepts introduced

**`pw endpoints run -- COMMAND` — serve and expose in one step.**
`pw endpoints run` spawns the command after `--`, registers the endpoint, and forwards the endpoint's URL to the command's port until the command exits. There is no session declaration, no tunnel wiring, no plumbing between jobs — the whole Stage 2 delta is one wrapper around the command you already had, and one input *removed*.

**Cancel the run or delete the endpoint — either takes everything down.**
`pw endpoints run` runs directly inside the workflow step, so the run, the server, and the endpoint form one chain:

```
  workflow run ──runs──▶ pw endpoints run ──spawns──▶ run.sh (the server)
                                │
                                └──registers──▶ the endpoint (its URL)
```

Cut the chain anywhere and all of it stops:

- **Cancel the workflow run** (from the UI, or `pw workflows runs cancel`) → the step is killed, `pw endpoints run` dies and takes `run.sh` down with it, and the endpoint deregisters.
- **Delete the endpoint** (from the Sessions page, or `pw endpoints delete fractal-<run-slug>`) → the platform shuts down `pw endpoints run`, which kills `run.sh` and exits — and with the step's command gone, the workflow run ends too.

Either way there is nothing left to clean up: no orphaned server still rendering, no dead URL still listed.

**The port travels through the environment.**
With no `--port` flag, `pw endpoints run` picks a free local port itself and **exports it as `PORT`** to the wrapped command — which is exactly how `run.sh` already reads it. Nothing else in the workflow ever needs to know the number. (To pin a port, pass `--port <N>`. If your command takes the port as an argument, write the literal token `{port}` and `pw` substitutes it — not `${port}`, which the shell expands to an empty string first.)

**Naming with `${PW_RUN_SLUG}`.**
`PW_RUN_SLUG` is a platform-injected environment variable holding the run's slug — the same value in every job of the run. Baking it into the endpoint name (`fractal-<run-slug>`) makes the name unique per run *and* predictable, so any other job (or you, at a terminal) can find this run's endpoint with `pw endpoints list`. Stage 4 leans on exactly that.

**`permissions: ['*']`.**
Registering an endpoint is a platform API call, so the in-workflow `pw` CLI must be authenticated — which is what `permissions: ['*']` grants. (Stage 1 needed no grant because it never called the platform API from inside the workflow.)

**Workflow-level `env`.**
The top-level `env:` block defines variables available to every step. `RESOLUTION` is set there once and `run.sh` reads it from the environment — Stage 1's inline `RESOLUTION=…`, hoisted to one place.

**Where's my URL?**
`pw endpoints run` prints the URL in the `run` step's log, and the endpoint shows up in the **Sessions** page of the UI and in `pw endpoints list`. Stage 3 adds a step that waits for the endpoint and publishes the URL as a proper output and notice.

**The run stays alive as long as the page does.**
`pw endpoints run` serves in the foreground, so the `run` step never finishes on its own — and the platform executes that step **from your user workspace, over an SSH connection to the cluster**, held open the whole time. That connection is the server's lifeline: if the workspace restarts or the SSH connection fails, the step dies, taking the server and endpoint with it. Fine for a demo; fragile for a page that should stay up. Stage 3 removes that dependency.

---

## Stage 3 — Let the workflow finish, keep the server running (`03-exit-workflow.yaml`)

In Stage 2 the workflow run is the lifeline of everything `run.sh` does — the computation *and* the server:

```
  Stage 2 — the step holds the work:

  workspace ══ SSH, held open for hours ══▶ run step ──▶ pw endpoints run ──▶ run.sh (render + serve)
                                                                │
  (workspace restarts or SSH drops ⇒ everything dies)           └──▶ endpoint URL
```

Stage 3 cuts the whole thing loose. The `run` step starts `pw endpoints run` **detached** — in its own session, unaffected by the step ending — a second step waits until the endpoint is live and publishes the URL, and the run **completes** while the computation and its server keep going on the cluster:

```
  Stage 3 — the step starts the work and leaves:

  workspace ══ SSH, open for seconds ══▶ run step ──detach──▶ pw endpoints run ──▶ run.sh (render + serve)
                                             │                       │
                              run completes, SSH closes              └──▶ endpoint URL
                                                (keeps rendering and serving on the cluster)
```

This is [`03-exit-workflow.yaml`](03-exit-workflow.yaml). Only the `run` job changes from Stage 2:

```yaml
  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve Detached
        run: |
          if command -v setsid >/dev/null 2>&1; then
            setsid pw endpoints run --name fractal-${PW_RUN_SLUG} -- ./fractal-demo/run.sh > run.${PW_JOB_ID}.out 2>&1 < /dev/null &
          else
            nohup pw endpoints run --name fractal-${PW_RUN_SLUG} -- ./fractal-demo/run.sh > run.${PW_JOB_ID}.out 2>&1 < /dev/null &
          fi
      - name: Wait for Endpoint
        retry:
          max-retries: 60
          interval: 5s                        # poll for up to ~5 minutes
        run: |
          endpoint_name="fractal-${PW_RUN_SLUG}"
          row=$(pw endpoints list | grep -w "${endpoint_name}" || true)
          if [ -z "${row}" ]; then
            echo "::notice::Endpoint ${endpoint_name} not registered yet"
            exit 1                            # non-zero → the retry fires again
          fi
          URL=$(echo "${row}" | awk '{print $3}')
          echo "URL=${URL}" | tee -a $OUTPUTS
          echo "::notice::Fractal is being served at ${URL}"
```

### Concepts introduced

**Detaching, one piece at a time.**
The launch line is the same one the `script_submitter` subworkflow uses to submit jobs. Each piece has one job:

| Piece | What it does |
|---|---|
| `setsid` | starts the command in a **new session** — the hangup that ends the step's SSH connection can never reach it |
| `nohup` (fallback) | same goal where `setsid` is not installed: the command ignores the hangup |
| `> run.${PW_JOB_ID}.out 2>&1` | the process outlives the step's log, so its output goes to a file in the job directory |
| `< /dev/null` | no terminal to read from — the command can never block waiting for input |
| `&` | don't wait — the step finishes immediately |

To read the server's output later, look in the job directory on the cluster: `~/pw/jobs/<workflow>/<run-number>/run.<job-id>.out`.

**Wait before you exit — a completed run means a live page.**
Detaching alone would let the run finish before the server even bound its port — a crashed server would still show a green run. The **Wait for Endpoint** step closes that gap: `retry` re-runs it while it exits non-zero (60 tries × 5s ≈ 5 minutes) until the endpoint shows up in `pw endpoints list`; then `URL=…` into `$OUTPUTS` publishes the URL as a job output and the `::notice::` line puts it, clickable, on the run page. A completed run now *means* the page is up.

**Deleting the endpoint now cancels `run.sh`.**
Once the run completes there is nothing left to cancel on the Runs page — the endpoint *is* the handle on the detached work. `pw endpoints delete fractal-<run-slug>` (or deleting it from the Sessions page) kills `pw endpoints run` and the whole `run.sh` tree under it.

**The trade.**
Stage 2 is simpler and self-cleaning, but everything hangs off an open SSH connection from your workspace. Stage 3's work belongs to the cluster — workspace restarts and dropped connections don't touch it — at the price of one extra step, and remembering that teardown is `pw endpoints delete`. The repo's production `*_v5.yaml` workflows use this same exit-and-keep-serving shape.

---

## Stage 4 — Submit to a scheduler with a subworkflow (`04-subworkflow.yaml`)

Until now everything ran on the **controller** (login) node. Heavy work belongs on a **compute node**, requested through the cluster's scheduler. The recommended move is to *not* hand-write the sbatch/qsub machinery: write your script and hand it to the **`script_submitter` subworkflow**, which submits, streams, monitors, and cleans up for you. This is [`04-subworkflow.yaml`](04-subworkflow.yaml) — and it keeps Stage 3's ending: once the page is up the run completes, and the server keeps serving.

What endpoints change is the *script* — and everything downstream of it. `install` writes the script body, publishes its path, and names a **skip-cleanups file** whose role appears below:

```yaml
      - name: Create Run Script
        run: |
          cat <<EOF >> script.sh
          # Everything the script needs is baked in NOW (expanded at write time):
          # the workflow-level env: does NOT reach the script_submitter subworkflow
          # that runs this script, and PW_RUN_SLUG may not be exported on a
          # compute node.
          export RESOLUTION=${{ inputs.resolution }}
          pw endpoints run --name fractal-${PW_RUN_SLUG}-${{ inputs.resource.name }} -- ${PWD}/fractal-demo/run.sh
          EOF
          chmod +x script.sh
          echo "SCRIPT_PATH=${PWD}/script.sh" | tee -a $OUTPUTS
          echo "SKIP_CLEANUP_PATH=${PWD}/SKIP_CLEANUP" | tee -a $OUTPUTS
```

A session-tunnel version of this script would have to record `hostname > HOSTNAME`, pick a free port, and write a `PORT` file — bookkeeping whose only purpose is to tell the platform where the tunnel should point. None of that exists here.

The whole submit/stream/monitor/cleanup dance is one job — note the two new inputs at the bottom:

```yaml
  script_submitter:
    needs:
      - install
    steps:
      - name: Script Submitter
        uses: github/parallelworks/interactive_session@main    # run another workflow as a step
        early-cancel: any-job-failed
        with:
          $yaml: workflow/script_submitter/v3.6/hsp.yaml        # which workflow inside that repo
          resource: ${{ inputs.resource }}
          use_existing_script: true                             # we built the script in install...
          script_path: ${{ needs.install.outputs.SCRIPT_PATH }} # ...so pass its path
          scheduler: ${{ inputs.scheduler }}
          submit_and_exit: false
          skip_cleanups_file: ${{ needs.install.outputs.SKIP_CLEANUP_PATH }}
          slurm:   # ... the form's SLURM group, passed straight through ...
          pbs:     # ... same idea ...
```

And `wait_for_endpoint` still polls until the endpoint registers and publishes its URL — but then it **arms the skip file and cancels the submitter**, which is what lets the run complete while the job keeps serving:

```yaml
  wait_for_endpoint:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Wait for endpoint
        early-cancel: any-job-failed
        retry:
          max-retries: 180
          interval: 10s
        run: |
          endpoint_name="fractal-${PW_RUN_SLUG}-${{ inputs.resource.name }}"
          row=$(pw endpoints list | grep -w "${endpoint_name}" || true)
          if [ -z "${row}" ]; then
            echo "::notice::Endpoint ${endpoint_name} not registered yet"
            exit 1                            # non-zero → the retry fires again
          fi
          URL=$(echo "${row}" | awk '{print $3}')
          echo "URL=${URL}" | tee -a $OUTPUTS
          echo "::notice::Fractal is being served at ${URL}"
          touch ${{ needs.install.outputs.SKIP_CLEANUP_PATH }}   # NEW: disarm the cleanups...
          sleep 2
      - name: Cancel Script Submitter                            # NEW: ...and release the submitter
        uses: parallelworks/cancel-jobs
        with:
          jobs:
            - script_submitter
```

### Concepts introduced

**Subworkflows (`uses:` + `$yaml`).**
`uses: github/parallelworks/interactive_session@main` runs *another workflow* as a step. `$yaml` selects which workflow file inside that repo to run (here `workflow/script_submitter/v3.6/hsp.yaml`), and the remaining `with:` keys are that subworkflow's inputs — the script's path (published by `install` through `$OUTPUTS`) and the form's scheduler settings.

**The endpoint doesn't care where the job landed.**
This is the punchline of the whole tutorial. A session tunnel points *at* a host and port, so a session-based workflow has to capture the compute node's hostname and chosen port and feed both into the platform. An endpoint dials **out** from whichever node executes the script — controller or compute node, SLURM or PBS — so none of that machinery exists here. The waiting job polls the *platform* (`pw endpoints list`), not the cluster filesystem.

**Bake values into the script at write time.**
The heredoc is unquoted, so `${{ inputs.resolution }}`, `${PW_RUN_SLUG}`, and `${PWD}` all expand **now**, while the script is being written on the controller node. That matters for three reasons: the workflow-level `env:` does not cross into the `script_submitter` subworkflow; `PW_RUN_SLUG` may not be exported in a compute node's batch environment; and `${PWD}` pins the demo to an absolute path that resolves wherever the script runs.

**One file arms and disarms the cleanups.**
When the `script_submitter` job is canceled it tears down whatever it started — `scancel` the SLURM job, `qdel` the PBS job, kill the process — *unless* the file named in `skip_cleanups_file` exists. The file does not exist until `wait_for_endpoint` creates it, and that one detail gives each phase the right behavior:

| Before the endpoint is up | Once the endpoint is up |
|---|---|
| No skip file yet, so the cleanups are **armed**. Cancel the run while the job is queued, or while a cloud node is still booting, and the job is `scancel`/`qdel`/killed for you — no manual cleanup, no waiting for the endpoint. | `wait_for_endpoint` publishes the URL, **touches `SKIP_CLEANUP`**, and cancels the submitter. The cleanup finds the file and leaves the job serving. The run completes. |

**Why not `submit_and_exit: true`?**
The submitter has a shortcut input that ends the run even sooner: submit the script, skip the monitoring and the cleanups, return. One flag instead of a skip file and a cancel step — but it gives up exactly the two things the table above buys:

1. **Canceling a queued job from the platform.** With cleanups skipped from the start, a job stuck in the queue can only be removed by hand (`scancel`/`qdel` at a terminal). With the skip-file approach you just cancel the run — at any point before the page is up.
2. **Monitoring until the page is up.** `submit_and_exit` returns before the job even leaves the queue. With `submit_and_exit: false` the submitter keeps monitoring the job's status and streaming its logs until the endpoint starts — if the job dies in the queue or the script crashes, the run fails loud instead of "completing" with no page.

**`retry` and `early-cancel`, stretched for the queue.**
The wait step's tools are Stage 3's — `retry` until the endpoint shows up, `$OUTPUTS` + `::notice::` to surface the URL — but the poll window grows to ~30 minutes (`max-retries: 180` × `10s`), because a scheduled job can sit in the queue, or wait for a cloud node to boot, long before the script runs. And a wait that long must not outlive a dead partner: `early-cancel: any-job-failed` on **both** the wait step and the submitter step means whichever side fails takes the other down instead of leaving it hanging.

**Per-worker endpoint names.**
The name grows a suffix: `fractal-<run-slug>-<resource-name>`. `PW_RUN_SLUG` is *run-scoped* — in Stage 5 every matrix worker shares it — so the resource name is what keeps concurrent workers from colliding, while the shared `fractal-<run-slug>-` prefix is what lets Stage 6 find *all* of this run's endpoints.

**A form that adapts to the resource.**
The "Schedule Job?" toggle and the `slurm`/`pbs` groups only appear when they apply: `hidden`/`ignore` key off `inputs.resource.schedulerType` (`slurm`, `pbs`, or empty) and `inputs.scheduler`. `slurm-partitions`/`slurm-qos`/`slurm-accounts` are **dynamic dropdowns** that fetch their choices from the chosen cluster. The hidden `is_enabled` boolean (default `true`, sent only when the group is active) is what tells the subworkflow which path to take. The top-level `configurations:` block defines one-click presets that pre-fill the form with a known PBS system's directives (`Carpenter`, `Ruth`, `Warhawk`, `Wheat`).

**Deleting the endpoint cancels the job — same as Stage 3.**
`pw endpoints delete fractal-<run-slug>-<resource-name>` kills the tree wherever it landed — login node or compute node — the script exits, and a scheduled job releases its node back to the scheduler. This wait → skip → cancel shape is exactly the one the repo's production `*_v5.yaml` session workflows use (e.g. `workflow/yamls/jupyterlab-host/general_v5.yaml`).

---

## Stage 5 — Fan out across resources with a matrix (`05-matrix.yaml`)

Stage 5 runs the **same** Stage 4 workflow across a whole *list* of resources at once — each entry on its own cluster, each choosing its own controller-vs-scheduler path, each rendering its own fractal and registering its own endpoint. This is [`05-matrix.yaml`](05-matrix.yaml):

```yaml
permissions:
  - '*'                                    # the subworkflow's pw endpoints calls need this grant on the parent too

jobs:
  fractal_demo:
    strategy:
      fail-fast: true
      matrix:
        worker: ${{ inputs.workers }}      # one matrix job per element of the workers list
    steps:
      - name: Fractal Demo
        uses: github/parallelworks/interactive_session@main
        with:
          $yaml: workflow/tutorials/hsp_pw_endpoints/04-subworkflow.yaml
          resource: ${{ matrix.worker.resource }}
          resolution: ${{ inputs.resolution }}
          scheduler: ${{ matrix.worker.scheduler }}
          slurm:  # ... the worker's own SLURM group, passed straight through ...
          pbs:    # ... same idea ...
```

The form replaces the single resource block with a **`list`** input the user can grow: each entry has the shape defined under `template:` — a resource picker plus the same "Schedule Job?"/SLURM/PBS controls as Stage 4, nested one level deeper.

### Concepts introduced

**`strategy.matrix` — fan-out.**
A `strategy.matrix` runs the job once for every value of a matrix variable. Setting `worker: ${{ inputs.workers }}` makes the variable the `workers` list itself, so the `fractal_demo` job expands into one copy per element — `fractal_demo-0`, `fractal_demo-1`, … — all running concurrently. Add a third worker in the form and a third job appears automatically; nothing in the YAML hardcodes the count. `fail-fast: true` cancels the remaining matrix jobs as soon as one fails; `max-parallel: N` (omitted here) would cap how many run at once.

**`matrix.<name>` vs the template's `[index]` — two different "current item"s.**
This is the subtle part, and the easiest thing to get wrong. Inside a *job*, the current matrix value is `${{ matrix.worker }}`, so each job reads *its own* worker with `matrix.worker.resource`, `matrix.worker.scheduler`, and so on. Inside the *form template*, `[index]` is a **separate** token meaning "the item being rendered" — which is why every `hidden`/`ignore`/`resource` expression in the `workers` template is written `inputs.workers.[index]...`. They are not interchangeable: `[index]` only resolves inside the list template, and in a job it silently falls back to the first element. Writing `inputs.workers.[index]` in the job (instead of `matrix.worker`) is exactly the trap that makes *every* matrix job inherit `workers[0]`'s settings.

**`permissions` must be granted by the parent.**
The `pw endpoints` calls run inside the subworkflow, but a subworkflow's `pw` CLI is only authenticated if the **parent** grants `permissions: ['*']` too.

**One endpoint per worker, unique by construction.**
Every worker registers `fractal-<run-slug>-<its-resource-name>` — the run-slug part identical across workers (it is the *parent* run's slug), the resource name distinct per row. (Two rows pointing at the *same* resource would collide on the name — the race in Stage 6 is also the cure for wanting the same thing twice.)

**The run completes; the fleet keeps serving.**
Each worker runs Stage 4, so each worker finishes once its endpoint is up — the parent run completes when the slowest worker's page is live, and every render keeps serving. `pw endpoints list` shows the whole fleet at a glance; delete each one with `pw endpoints delete fractal-<run-slug>-<resource-name>`.

---

## Stage 6 — First start wins: race a list of resources (`06-first-start-wins.yaml`)

Stage 5 fanned the render out to **every** resource and left you with one endpoint per worker. Stage 6 keeps the same fan-out but treats the list as a **race**: every worker starts, the first one whose endpoint is **running** wins, and the rest stop themselves — their render is torn down and their endpoint disappears with it. The run then completes with exactly one page serving: Stage 4's ending, decided by a race. This is [`06-first-start-wins.yaml`](06-first-start-wins.yaml) and its subworkflow [`06-first-start-wins-subworkflow.yaml`](06-first-start-wins-subworkflow.yaml).

The parent is Stage 5 with the `$yaml` swapped to the racing subworkflow. All the racing lives in the subworkflow: it is Stage 4's `install` → `script_submitter` pipeline (skip file included) with `wait_for_endpoint` replaced by a job that waits for the *race*, `first_start_wins`:

```yaml
  first_start_wins:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: First Start Wins
        retry:                                  # poll until the endpoints show up
          max-retries: 8640
          interval: 10s
        run: |
          PREFIX="fractal-${PW_RUN_SLUG}-"
          MY_NAME="fractal-${PW_RUN_SLUG}-${{ inputs.resource.name }}"

          # Prints one word: WAIT | WIN | LOSE. First RUNNING endpoint whose
          # name carries this run's prefix wins; list order is the tie-break.
          decision=$(pw endpoints list | awk -v prefix="${PREFIX}" -v me="${MY_NAME}" '
            index($1, prefix) == 1 && $2 == "running" && !first { first = $1 }
            END {
              if (!first)          print "WAIT"
              else if (first == me) print "WIN"
              else                  print "LOSE"
            }')

          [ "${decision}" = "WAIT" ] && exit 1     # nothing running yet → keep polling
          if [ "${decision}" = "WIN" ]; then
            # stay first for a few polls (the list is eventually consistent), then win
            [ "${PW_WORKFLOW_STEP_CURRENT_RETRY:-0}" -lt 3 ] && exit 1
            URL=$(pw endpoints list | grep -w "${MY_NAME}" | awk '{print $3}')
            echo "URL=${URL}" | tee -a $OUTPUTS
            touch ${{ needs.install.outputs.SKIP_CLEANUP_PATH }}   # winner: disarm the cleanups
            sleep 2
            exit 0
          fi
          echo "::notice::losing — standing down"   # loser: leave the cleanups armed
      - name: Cancel Script Submitter               # winner AND loser reach here
        uses: parallelworks/cancel-jobs
        with:
          jobs:
            - script_submitter
        cleanup: test -f ${{ needs.install.outputs.SKIP_CLEANUP_PATH }} || pw endpoints delete "fractal-${PW_RUN_SLUG}-${{ inputs.resource.name }}" || true
```

### Concepts introduced

**The scoreboard is `pw endpoints list`, keyed by name prefix.**
Every worker's endpoint starts with `fractal-<run-slug>-` (built in Stage 4), so a prefix match on the first column plus `status == running` isolates *this run's* endpoints with a few lines of `awk`. Among those, the **first one the list returns** is the winner and every other worker stands down. List order is the universal tie-breaker: every worker reads the same list, so they all pick the same winner. Only running endpoints count, so a worker whose own endpoint isn't up yet while another's is simply loses.

**Confirm before committing — the endpoint list is eventually consistent.**
Just after two endpoints register, each worker can briefly see only *its own* running and think it won. So a worker that is currently in front re-checks for a few polls (guarded by `PW_WORKFLOW_STEP_CURRENT_RETRY`) before it commits; a worker that was actually beaten sees the winning endpoint on a later poll and steps aside. Without this settle, two workers can both "win."

**One cancel, two meanings — the skip file decides.**
Winner and losers end exactly the same way: cancel your own `script_submitter`. What that cancel *does* is decided entirely by Stage 4's skip file:

| | The winner | A loser |
|---|---|---|
| Before canceling | publishes the winning URL and **touches `SKIP_CLEANUP`** | leaves the file untouched |
| The submitter's cleanup | finds the file — the render keeps serving | runs — the render is killed, and its endpoint deregisters on its own (an endpoint *is* its client process) |

The guarded `pw endpoints delete` in the `cleanup:` is a defensive no-op for a loser process that lingers — the file test keeps it away from the winner's endpoint. When the dust settles, the whole fan-out has **completed** and exactly one page is serving; delete its endpoint later, like every stage since 3.

---

## Testing status

The controller path (`Schedule Job? = No`) was verified end-to-end on live clusters. Stage 2 (the merged dynamic-port version) was run live: the endpoint registered and came up `running`, an anonymous request to its URL got the platform-auth redirect, and canceling the run deregistered the endpoint. Stage 3 was run live: the endpoint came up, the run completed on its own while the detached server kept serving, and `pw endpoints delete` killed the detached process tree and removed the endpoint from the list. Stage 4 was run live twice: once on the controller path (endpoint up, URL published, run completed while the job kept serving, `pw endpoints delete` tore the job down), and once on the scheduler path to verify the armed cleanups — a `Schedule Job? = Yes` run was canceled while its SLURM job was still provisioning a node, before the endpoint existed, and the submitter's cleanup `scancel`ed the job, leaving no queue entry and no endpoint. The full scheduler happy path (endpoint served from a compute node) has not been re-verified in this edition. Stage 5 was run live through the parent matrix: the worker's endpoint came up, the parent run completed while the page kept serving, and `pw endpoints delete` tore it down. Stage 6's race was run live both ways: a clean run whose worker **won** (confirmed first place across the settle polls, published its URL, disarmed its cleanups, and its page outlived the completed run), and a run raced against an endpoint registered ahead of it, whose worker **lost** (decided LOSE, stood down, its render and endpoint vanished, the leading endpoint kept serving, and the run still completed). Both race runs used a single worker; the same decision logic was verified earlier with two real resources racing. Stage 1 is byte-identical to the session tutorial's tested stage.
