# Rendering a Fractal on Activate — A Workflow Tutorial (pw endpoints)

This tutorial turns a small, self-contained fractal renderer into an Activate workflow. You start by running the script by hand on a cluster so you can see exactly what it does, then automate it one piece at a time. Each stage has a matching workflow file you can run as-is from the Activate UI.

The web page the demo serves reaches your browser through **`pw endpoints`**: the service side dials out from wherever it runs, registers a reverse tunnel, and gets its own URL (`https://<subdomain>.activate.pw/`). There is also a [session-tunnel edition](../hsp/README.md) of this tutorial that exposes the same demo the older way, with a `sessions:` block and tunnel wiring — you do not need it to follow this one.

By the end of the stages built so far you will understand how to:

- Define workflow inputs — with labels, tooltips, defaults, and validation — and run steps on a remote cluster over SSH
- Use `needs` to sequence jobs and to run independent jobs in parallel
- Pull example code onto the cluster with the `checkout` action
- Pass workflow inputs into your scripts as environment variables
- Expose a web server through the platform with `pw endpoints run` — no tunnel wiring, no port bookkeeping: the endpoint picks a free port at runtime and hands it to your server through the `PORT` environment variable
- Wait for an endpoint to come online with a `retry` step, and surface its URL with `$OUTPUTS` and log annotations (`::notice::`, `::warning::`, `::error::`)
- Hand a script to a reusable subworkflow that submits it to the cluster scheduler (SLURM or PBS) and streams, monitors, and cleans up the job for you — and see why endpoints make the "where did my job land?" question disappear
- Build a form that adapts to the chosen resource with dynamic dropdowns and show/hide rules
- Fan out the same workflow across a whole list of resources at once with a `matrix` strategy
- Turn that fan-out into a race where the first endpoint to come up wins and the losing workers stop themselves

---

## Background — sessions vs endpoints

Activate has two ways to put a web page running on a cluster into your browser. A **session tunnel** is opened by the platform, which tunnels *in* to a host and port your workflow must know and register. An **endpoint** dials *out* from wherever the server runs and registers itself. If you have seen session-based workflows before, this table maps one onto the other; if not, skip it — the stages explain everything they use.

| | Session tunnel | `pw endpoints` (this tutorial) |
|---|---|---|
| Who opens the connection | the platform tunnels **in** to `host:port` on the cluster | the service side dials **out** and registers itself |
| What the workflow must know | the node the server landed on and its port | nothing — the endpoint registers from wherever the script runs |
| Port | you pick one and thread it through the jobs | `pw endpoints run` assigns one and exports it as `PORT` |
| URL | `…/me/session/<user>/<session-name>` | `https://<subdomain>.activate.pw/` (subdomain endpoints serve at the root) |
| Auth | platform login | same — endpoints require platform login unless explicitly made public |
| Declared in YAML | `sessions:` block + `update-session` action | nothing — just the `pw endpoints run` command |
| Needs `permissions: ['*']` | only for `pw sessions ls/stop` | from the first `pw endpoints` call (Stage 2 onward) |

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

`run.sh` starts the web server on port 8000, then renders the image one row at a time, so the page fills in top to bottom as it goes. When the render finishes it keeps serving, so the result stays up until you stop it.

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
`pw endpoints run` spawns the command after `--`, registers the endpoint, and forwards the endpoint's URL to the command's port until the command exits. The server and its exposure share one lifetime: cancel the step and both are gone. There is no session declaration, no tunnel wiring, no plumbing between jobs — the whole Stage 2 delta is one wrapper around the command you already had, and one input *removed*.

**The port travels through the environment.**
With no `--port` flag, `pw endpoints run` picks a free local port itself and **exports it as `PORT`** to the wrapped command — which is exactly how `run.sh` already reads it. Nothing else in the workflow ever needs to know the number. (If you need to pin a specific port, pass `--port <N>`; and if your command takes the port as an argument instead of the environment, write the literal token `{port}` in the command and `pw` substitutes the number — `{port}`, **not** `${port}`, which the shell would expand to an empty string before `pw` ever sees it.)

**Naming with `${PW_RUN_SLUG}`.**
`PW_RUN_SLUG` is a platform-injected environment variable holding the run's slug — the same value in every job of the run. Baking it into the endpoint name (`fractal-<run-slug>`) makes the name unique per run *and* predictable, so any other job (or you, at a terminal) can find this run's endpoint with `pw endpoints list`. Stage 4 leans on exactly that.

**`permissions: ['*']`.**
Registering an endpoint is a platform API call, so the in-workflow `pw` CLI must be authenticated — which is what `permissions: ['*']` grants. (Stage 1 needed no grant because it never called the platform API from inside the workflow.)

**Workflow-level `env`.**
The top-level `env:` block defines variables available to every step in the workflow. We set `RESOLUTION` there once, so `run.sh` reads it from the environment and the run command only carries what is specific to it. (Stage 1 set it inline on the command — this is the same idea, hoisted to one place.)

**Where's my URL?**
`pw endpoints run` prints the URL in the `run` step's log, and the endpoint shows up in the **Sessions** page of the UI and in `pw endpoints list`. Stage 4 adds a job that waits for the endpoint and publishes the URL as a proper output and notice.

---

## Stage 4 — Submit to a scheduler with a subworkflow (`04-subworkflow.yaml`)

Until now everything ran on the **controller** (login) node. Heavy work belongs on a **compute node**, requested through the cluster's scheduler. The recommended move is to *not* hand-write the sbatch/qsub machinery: write your script and hand it to the **`script_submitter` subworkflow**, which submits, streams, monitors, and cleans up for you. This is [`04-subworkflow.yaml`](04-subworkflow.yaml).

What endpoints change is the *script* — and everything downstream of it. `install` writes the script body and publishes its path:

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
```

A session-tunnel version of this script would have to record `hostname > HOSTNAME`, pick a free port, and write a `PORT` file — bookkeeping whose only purpose is to tell the platform where the tunnel should point. None of that exists here. In its place, a `wait_for_endpoint` job polls the platform and publishes the URL:

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
```

### Concepts introduced

**Subworkflows (`uses:` + `$yaml`).**
`uses: github/parallelworks/interactive_session@main` runs *another workflow* as a step. `$yaml` selects which workflow file inside that repo to run (here `workflow/script_submitter/v3.6/hsp.yaml`), and the remaining `with:` keys are that subworkflow's inputs. You hand it your script's path (`use_existing_script: true` + `script_path`, published by `install` through `$OUTPUTS`) and the form's scheduler settings, and it does the whole submit/stream/monitor/cleanup dance.

**The endpoint doesn't care where the job landed.**
This is the punchline of the whole tutorial. A session tunnel points *at* a host and port, so a session-based workflow has to capture the compute node's hostname and chosen port and feed both into the platform. An endpoint dials **out** from whichever node executes the script — controller or compute node, SLURM or PBS — so none of that machinery exists here. The waiting job polls the *platform* (`pw endpoints list`), not the cluster filesystem.

**Bake values into the script at write time.**
The heredoc is unquoted, so `${{ inputs.resolution }}`, `${PW_RUN_SLUG}`, and `${PWD}` all expand **now**, while the script is being written on the controller node. That matters for three reasons: the workflow-level `env:` does not cross into the `script_submitter` subworkflow; `PW_RUN_SLUG` may not be exported in a compute node's batch environment; and `${PWD}` pins the demo to an absolute path that resolves wherever the script runs.

**`retry` — poll until something exists.**
The endpoint only appears in `pw endpoints list` once `run.sh` is actually up — for a queued SLURM/PBS job that may be minutes later. `retry` re-runs the step while it exits non-zero — `max-retries: 180` at `interval: 10s` ≈ 30 minutes — so the step simply fails until the endpoint registers, then succeeds and publishes the URL.

**`$OUTPUTS` and `::notice::` — surface the URL.**
`$OUTPUTS` is a file the platform injects into each step; writing `KEY=VALUE` lines to it publishes those values as outputs of the job (readable downstream as `${{ needs.wait_for_endpoint.outputs.URL }}`). `tee -a` appends to the file *and* echoes the line to the log. A line printed in the form `::notice::message` is surfaced as a notice in the workflow UI (there are also `::warning::` and `::error::`) — here it puts the clickable URL right in the run page.

**`early-cancel: any-job-failed` — don't wait for a corpse.**
If the render job dies (say the submission fails), the wait step would happily poll for the full 30 minutes for an endpoint that will never register. `early-cancel: any-job-failed` cancels it as soon as any job fails instead.

**Per-worker endpoint names.**
The name grows a suffix: `fractal-<run-slug>-<resource-name>`. `PW_RUN_SLUG` is *run-scoped* — in Stage 5 every matrix worker shares it — so the resource name is what keeps concurrent workers from colliding, while the shared `fractal-<run-slug>-` prefix is what lets Stage 6 find *all* of this run's endpoints.

**A form that adapts to the resource.**
The "Schedule Job?" toggle and the `slurm`/`pbs` groups only appear when they apply: `hidden`/`ignore` key off `inputs.resource.schedulerType` (`slurm`, `pbs`, or empty) and `inputs.scheduler`. `slurm-partitions`/`slurm-qos`/`slurm-accounts` are **dynamic dropdowns** that fetch their choices from the chosen cluster. The hidden `is_enabled` boolean (default `true`, sent only when the group is active) is what tells the subworkflow which path to take. The top-level `configurations:` block defines one-click presets that pre-fill the form with a known PBS system's directives (`Carpenter`, `Ruth`, `Warhawk`, `Wheat`).

**Lifecycle: the run stays alive; cancel to stop.**
`pw endpoints run` serves in the foreground, so the submitted job — and with it the workflow run — stays alive for as long as the page is up. Canceling the run makes `script_submitter` tear the job down (`scancel`/`qdel`/kill), the process tree dies, and the endpoint deregisters itself. (The repo's production `*_v5.yaml` session workflows flip this: they *complete* the run once the endpoint is live and let the service outlive it, torn down later with `pw endpoints delete` — see `workflow/yamls/openvscode/general_v5.yaml` if you want that pattern.)

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
Every worker registers `fractal-<run-slug>-<its-resource-name>` — the run-slug part identical across workers (it is the *parent* run's slug), the resource name distinct per row. After the run, `pw endpoints list` shows the whole fleet at a glance. (Two rows pointing at the *same* resource would collide on the name — the race in Stage 6 is also the cure for wanting the same thing twice.)

---

## Stage 6 — First start wins: race a list of resources (`06-first-start-wins.yaml`)

Stage 5 fanned the render out to **every** resource and left you with one endpoint per worker. Stage 6 keeps the same fan-out but treats the list as a **race**: every worker starts, the first one whose endpoint is **running** wins, and the rest stop themselves — their render is torn down and their endpoint disappears with it. This is [`06-first-start-wins.yaml`](06-first-start-wins.yaml) and its subworkflow [`06-first-start-wins-subworkflow.yaml`](06-first-start-wins-subworkflow.yaml).

The parent is Stage 5 with the `$yaml` swapped to the racing subworkflow. All the racing lives in the subworkflow: it is Stage 4's `install` → `script_submitter` pipeline plus one new job, `first_start_wins`:

```yaml
  first_start_wins:
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
            echo "CANCEL=false" | tee -a $OUTPUTS   # winner: leave the endpoint up
            exit 0
          fi
          echo "CANCEL=true" | tee -a $OUTPUTS      # loser
      - name: Cancel Jobs
        if: ${{ needs.first_start_wins.outputs.CANCEL == 'true' }}   # only losers reach here
        uses: parallelworks/cancel-jobs
        with:
          jobs:
            - script_submitter                  # stop the losing render
        cleanup: pw endpoints delete "fractal-${PW_RUN_SLUG}-${{ inputs.resource.name }}" || true
```

### Concepts introduced

**The scoreboard is `pw endpoints list`, keyed by name prefix.**
Every worker's endpoint starts with `fractal-<run-slug>-` (built in Stage 4), so a prefix match on the first column plus `status == running` isolates *this run's* endpoints with a few lines of `awk`. Among those, the **first one the list returns** is the winner and every other worker stands down. List order is the universal tie-breaker: every worker reads the same list, so they all pick the same winner. Only running endpoints count, so a worker whose own endpoint isn't up yet while another's is simply loses.

**Confirm before committing — the endpoint list is eventually consistent.**
Just after two endpoints register, each worker can briefly see only *its own* running and think it won. So a worker that is currently in front re-checks for a few polls (guarded by `PW_WORKFLOW_STEP_CURRENT_RETRY`) before it commits; a worker that was actually beaten sees the winning endpoint on a later poll and steps aside. Without this settle, two workers can both "win."

**One output flag drives the cleanup.**
The winner writes `CANCEL=false` and simply finishes; its endpoint stays up because its `script_submitter` job is still serving the page — the WIN branch also prints the winning URL as a notice. A loser writes `CANCEL=true`, and the **Cancel Jobs** step keys its `if:` off `${{ needs.first_start_wins.outputs.CANCEL }}` to run `cancel-jobs`, stopping that worker's render. Killing the process tree deregisters the endpoint on its own — an endpoint *is* its client process — so the `pw endpoints delete` in the `cleanup` is a defensive no-op for the edge where the process lingers.

---

## Testing status

The controller path (`Schedule Job? = No`) was verified end-to-end on live clusters. Stage 2 (the merged dynamic-port version) was run live: the endpoint registered and came up `running`, an anonymous request to its URL got the platform-auth redirect, and canceling the run deregistered the endpoint. Stage 4 was verified in an earlier round (endpoint registered from the submitted script, URL published by `wait_for_endpoint`), and stage 6 as a real two-resource race (both endpoints up, every worker picked the same winner, the loser stood down and its endpoint disappeared, cancel tore the winner down); since then only their checkout path changed, which was re-validated by dry-run and live-tested through the identical steps in the session-tunnel edition. Stage 6's parent exercises the same matrix mechanics as stage 5, and stage 1 is byte-identical to the session tutorial's tested stage. The scheduler path (`Schedule Job? = Yes`) reuses `script_submitter` unchanged but has not been re-verified in this edition.
