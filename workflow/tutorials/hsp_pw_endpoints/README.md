# Rendering a Fractal on Activate — A Workflow Tutorial (pw endpoints edition)

This tutorial turns a small, self-contained fractal renderer into an Activate workflow. You start by running the script by hand on a cluster so you can see exactly what it does, then automate it one piece at a time. Each stage has a matching workflow file you can run as-is from the Activate UI.

It is the **endpoint edition** of the [session-tunnel tutorial](../hsp/README.md): the stages, the fractal demo, and almost all of the workflow machinery are the same — what changes is how the web page reaches your browser. Where the original declares a `sessions:` block and wires up a tunnel with `parallelworks/update-session`, this edition wraps the server in **`pw endpoints run`**, which dials out from wherever the server runs, registers a reverse tunnel, and gets its own URL (`https://<subdomain>.activate.pw/`). If you have not seen the platform concepts before (jobs, `needs`, checkout, subworkflows, matrix), the explanations in the original README apply here unchanged; this one focuses on what endpoints change.

By the end of the stages built so far you will understand how to:

- Define workflow inputs — with labels, tooltips, defaults, and validation — and run steps on a remote cluster over SSH
- Use `needs` to sequence jobs and to run independent jobs in parallel
- Pull example code onto the cluster with the `checkout` action
- Pass workflow inputs into your scripts as environment variables
- Expose a web server through the platform with `pw endpoints run` — no session block, no tunnel wiring, no port bookkeeping
- Let the endpoint pick a free port at runtime and hand it to your server through the `PORT` environment variable
- Wait for an endpoint to come online with a `retry` step, and surface its URL with `$OUTPUTS` and log annotations (`::notice::`, `::warning::`, `::error::`)
- Hand a script to a reusable subworkflow that submits it to the cluster scheduler (SLURM or PBS) and streams, monitors, and cleans up the job for you — and see why endpoints make the "where did my job land?" question disappear
- Build a form that adapts to the chosen resource with dynamic dropdowns and show/hide rules
- Fan out the same workflow across a whole list of resources at once with a `matrix` strategy
- Turn that fan-out into a race where the first endpoint to come up wins and the losing workers stop themselves

---

## Sessions vs endpoints, in one table

| | Session tunnel (original tutorial) | `pw endpoints` (this tutorial) |
|---|---|---|
| Who opens the connection | the platform tunnels **in** to `host:port` on the cluster | the service side dials **out** and registers itself |
| What the workflow must know | the node the server landed on and its port (`HOSTNAME`/`PORT` files, `update-session`) | nothing — the endpoint registers from wherever the script runs |
| Port | you pick one (`pw agent open-port`) and thread it through | `pw endpoints run` assigns one and exports it as `PORT` |
| URL | `…/me/session/<user>/<session-name>` | `https://<subdomain>.activate.pw/` (subdomain endpoints serve at the root) |
| Auth | platform login | same — endpoints require platform login unless explicitly made public |
| Declared in YAML | `sessions:` block + `update-session` action | nothing — just the `pw endpoints run` command |
| Needs `permissions: ['*']` | only for `pw sessions ls/stop` (Stage 6) | from the first `pw endpoints` call (Stage 2 onward) |

---

## Prerequisites

- An Activate cluster you can reach, with SSH access to its controller node
- Python 3.6 or newer on the cluster — `install.sh` uses it to build the demo's own virtual environment (the demo itself uses only the standard library, so there is nothing else to download)
- Basic familiarity with YAML

---

## The example

The thing we are automating is the same [`fractal-demo/`](../hsp/fractal-demo/README.md) as the original tutorial — this edition checks it out from the same place (`workflow/tutorials/hsp/fractal-demo`), so there is exactly one copy of the demo in the repo:

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
cd interactive_session/workflow/tutorials/hsp/fractal-demo
```

Install the environment, then render and serve a fractal:

```bash
./install.sh                        # builds the venv at ~/pw/software/fractal-demo
RESOLUTION=1000 PORT=8000 ./run.sh  # render a 1000x1000 fractal and serve it on port 8000
```

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

This stage is **identical to the original tutorial's Stage 1** — no session and no endpoint yet, just the workflow fetching, installing, and running the demo. The file is [`01-controller.yaml`](01-controller.yaml); the original README's [Stage 1 explanations](../hsp/README.md#stage-1--run-it-as-a-workflow-01-controlleryaml) (jobs, `needs`, `ssh`, `PW_JOB_DIR`, expressions, `checkout`, the inputs form, running it with the `pw` CLI) all apply verbatim.

To *view* the page this stage serves, use the manual endpoint from Stage 0 (`pw endpoints http --name fractal 8000` on the controller node). The next stage makes the workflow do that itself.

---

## Stage 2 — Create the endpoint automatically (`02-automated-endpoint-creation.yaml`)

Stage 1 still relies on the endpoint you opened by hand in Stage 0. The workflow can create it itself — by wrapping the server command in `pw endpoints run`. Compare with the original Stage 2, which needed a `sessions:` block *and* a third job calling `update-session`; here nothing else is added. This is [`02-automated-endpoint-creation.yaml`](02-automated-endpoint-creation.yaml):

```yaml
permissions:
  - '*'                                       # NEW: authenticates the in-workflow pw CLI

jobs:
  install:
    # ... unchanged from Stage 1 ...

  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve                # CHANGED: pw endpoints run wraps run.sh
        run: |
          RESOLUTION=${{ inputs.resolution }} pw endpoints run \
            --name fractal-${PW_RUN_SLUG} \
            --port ${{ inputs.port }} \
            -- ./fractal-demo/run.sh

'on':
  execute:
    inputs:
      # ... unchanged from Stage 1 (resource, resolution, port) ...
```

### Concepts introduced

**`pw endpoints run -- COMMAND` — serve and expose in one step.**
`pw endpoints run` spawns the command after `--`, registers the endpoint, and forwards the endpoint's URL to the command's port until the command exits. The server and its exposure now share one lifetime: cancel the step and both are gone. There is no `sessions:` block, no `update-session` job, and no `resource.id` plumbing — the whole Stage 2 delta is one wrapper around the command you already had.

**The port travels through the environment.**
`--port ${{ inputs.port }}` pins the local port, and `pw endpoints run` **exports `PORT`** to the wrapped command — which is exactly how `run.sh` already reads it. (You could also write the literal token `{port}` in the command and `pw` substitutes the number; the env var is the cleaner fit here. If you ever interpolate it, mind the spelling: `{port}`, **not** `${port}` — the shell expands `${port}` to an empty string before `pw` ever sees it.)

**Naming with `${PW_RUN_SLUG}`.**
`PW_RUN_SLUG` is a platform-injected environment variable holding the run's slug — the same value in every job of the run. Baking it into the endpoint name (`fractal-<run-slug>`) makes the name unique per run *and* predictable, so any other job (or you, at a terminal) can find this run's endpoint with `pw endpoints list`. Stage 3 leans on exactly that.

**`permissions: ['*']` arrives earlier than in the session tutorial.**
Registering an endpoint is a platform API call, so the in-workflow `pw` CLI must be authenticated — which is what `permissions: ['*']` grants. (In the original tutorial nothing before Stage 6 needed it, because `pw agent open-port` works unauthenticated.)

**Where's my URL?**
The platform does not redirect you automatically (that was the session block's `redirect: true`). Find the URL in the **Sessions** page of the UI, or with `pw endpoints list`, or in the `run` step's log. Stage 3 adds a job that surfaces it properly.

---

## Stage 3 — Let the endpoint pick the port (`03-dynamic-port.yaml`)

So far the port is hardcoded through the `port` input. If two people run the workflow on the same cluster, they collide on port 8000. In the session tutorial this took a new `pw agent open-port` step, an `$OUTPUTS` hand-off, and rewiring two jobs. With endpoints it is the *removal* of a flag: drop `--port` and `pw endpoints run` picks a free port itself, handing it to `run.sh` through `PORT` as always. We use the freed-up space to solve Stage 2's "where's my URL?" properly, with a job that waits for the endpoint and publishes its URL. This is [`03-dynamic-port.yaml`](03-dynamic-port.yaml):

```yaml
permissions:
  - '*'

env:                                          # NEW: a workflow-level variable, visible to every step
  RESOLUTION: ${{ inputs.resolution }}

jobs:
  install:
    # ... unchanged from Stage 2 ...

  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve                # CHANGED: no --port; pw picks one
        run: pw endpoints run --name fractal-${PW_RUN_SLUG} -- ./fractal-demo/run.sh
        cleanup: rm -r ${PW_JOB_DIR}          # NEW: delete the run directory when the step exits

  wait_for_endpoint:                          # NEW: wait for the endpoint, publish its URL
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Wait for endpoint
        early-cancel: any-job-failed
        retry:
          max-retries: 180
          interval: 10s                       # poll for up to ~30 minutes
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

'on':
  execute:
    inputs:
      # the `port` input is gone — the endpoint picks the port itself now
      resource:
        # ... unchanged ...
      resolution:
        # ... unchanged ...
```

### Concepts introduced

**Dynamic ports come for free.**
No `pw agent open-port`, no threading a port between jobs: dropping `--port` is the entire change to the `run` job. Two runs on the same cluster no longer collide.

**`retry` — poll until something exists.**
The endpoint only appears in `pw endpoints list` once `run.sh` is actually up. `retry` re-runs the step while it exits non-zero — `max-retries: 180` at `interval: 10s` ≈ 30 minutes — so the step simply fails until the endpoint registers, then succeeds and publishes the URL. (The session tutorial introduces `retry` one stage later, to wait for a queued job's `HOSTNAME`/`PORT` files; same tool, same shape.)

**`$OUTPUTS` and `::notice::` — surface the URL.**
Writing `URL=…` to `$OUTPUTS` publishes it as a job output (readable downstream as `${{ needs.wait_for_endpoint.outputs.URL }}`), and the `::notice::` line puts the clickable URL right in the workflow UI.

**`early-cancel: any-job-failed` — don't wait for a corpse.**
If the `run` job dies (say `pw endpoints run` fails to start), the wait step would happily poll for the full 30 minutes for an endpoint that will never register. `early-cancel: any-job-failed` cancels it as soon as any job fails instead.

**Workflow-level `env`, step `cleanup`.**
Same lessons as the original Stage 3: the top-level `env:` block hoists `RESOLUTION` so the run command only carries what changes, and the `cleanup:` on the run step (here deleting the run directory) fires when the step exits — including on cancel.

---

## Stage 4 — Submit to a scheduler with a subworkflow (`04-subworkflow.yaml`)

Until now everything ran on the **controller** (login) node. Heavy work belongs on a **compute node**, requested through the cluster's scheduler. As in the original tutorial, the recommended move is to *not* hand-write the sbatch/qsub machinery: write your script and hand it to the **`script_submitter` subworkflow**, which submits, streams, monitors, and cleans up for you. This is [`04-subworkflow.yaml`](04-subworkflow.yaml); the [original Stage 4 notes](../hsp/README.md#stage-4--submit-to-a-scheduler-with-a-subworkflow-04-subworkflowyaml) on subworkflows, the adaptive SLURM/PBS form, `configurations` presets, and what the submitter does internally all apply unchanged.

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

Compare with the original's script, which had to record `hostname > HOSTNAME`, run `pw agent open-port`, and write a `PORT` file — three lines of bookkeeping whose only purpose was to tell `update-session` where the tunnel should point. All three are gone, along with the entire "read hostname and port, then create the session" job. In their place, the same `wait_for_endpoint` job from Stage 3 (with the Stage-4 endpoint name):

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
          # ... same poll-and-publish as Stage 3 ...
```

### Concepts introduced

**The endpoint doesn't care where the job landed.**
This is the punchline of the whole edition. A session tunnel points *at* a host and port, so the original tutorial had to capture the compute node's hostname, pick between `localhost` and the `HOSTNAME` file depending on the scheduler flag, and feed both into `update-session`. An endpoint dials **out** from whichever node executes the script — controller or compute node, SLURM or PBS — so none of that machinery exists here. The waiting job polls the *platform* (`pw endpoints list`), not the cluster filesystem.

**Bake values into the script at write time.**
The heredoc is unquoted, so `${{ inputs.resolution }}`, `${PW_RUN_SLUG}`, and `${PWD}` all expand **now**, while the script is being written on the controller node. That matters for three reasons: the workflow-level `env:` does not cross into the `script_submitter` subworkflow; `PW_RUN_SLUG` may not be exported in a compute node's batch environment; and `${PWD}` pins the demo to an absolute path that resolves wherever the script runs.

**Per-worker endpoint names.**
The name grows a suffix: `fractal-<run-slug>-<resource-name>`. `PW_RUN_SLUG` is *run-scoped* — in Stage 5 every matrix worker shares it — so the resource name is what keeps concurrent workers from colliding, while the shared `fractal-<run-slug>-` prefix is what lets Stage 6 find *all* of this run's endpoints.

**Lifecycle: the run stays alive; cancel to stop.**
`pw endpoints run` serves in the foreground, so the submitted job — and with it the workflow run — stays alive for as long as the page is up, exactly like the session tutorial. Canceling the run makes `script_submitter` tear the job down (`scancel`/`qdel`/kill), the process tree dies, and the endpoint deregisters itself. (The repo's production `*_v5.yaml` session workflows flip this: they *complete* the run once the endpoint is live and let the service outlive it, torn down later with `pw endpoints delete` — see `workflow/yamls/openvscode/general_v5.yaml` and `ai-workflow-development/references/v4-to-v5-endpoints-upgrade.md` if you want that pattern.)

---

## Stage 5 — Fan out across resources with a matrix (`05-matrix.yaml`)

Stage 5 runs the **same** Stage 4 workflow across a whole *list* of resources at once — each entry on its own cluster, each choosing its own controller-vs-scheduler path, each rendering its own fractal and registering its own endpoint. The mechanics are identical to the [original Stage 5](../hsp/README.md#stage-5--fan-out-across-resources-with-a-matrix-05-matrixyaml) — a `list` input with a `template`, a `strategy.matrix` that expands one job per entry, `matrix.worker` vs the template's `[index]` — so read those notes there. This is [`05-matrix.yaml`](05-matrix.yaml):

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

Two endpoint-specific notes on top of the original's lessons:

**`permissions` must be granted by the parent.**
The `pw endpoints` calls run inside the subworkflow, but a subworkflow's `pw` CLI is only authenticated if the **parent** grants `permissions: ['*']` too — the same rule the original tutorial hits in Stage 6.

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

### What changed from the session race

**The scoreboard is `pw endpoints list`, keyed by name prefix.**
The original filtered `pw sessions ls -o json` on `workflowRun.slug == PW_RUN_SLUG` — sessions carry their run's identity as metadata. Endpoints carry it in the **name** instead: every worker's endpoint starts with `fractal-<run-slug>-` (built in Stage 4), so a prefix match on the first column plus `status == running` reproduces exactly the same filter with a few lines of `awk`. The decision logic on top — WAIT/WIN/LOSE, list order as the shared tie-break, and the "confirm you stay first for a few polls before committing" guard against the eventually-consistent list — is unchanged from the original, and the original README's explanations of those apply as-is.

**Losing is simpler: kill the process, the endpoint follows.**
A canceled session job left a dead tunnel behind, so the original needed `pw sessions stop` to delete the session object. An endpoint *is* its client process: when `cancel-jobs` stops the losing `script_submitter`, the process tree dies and the endpoint deregisters itself. The `pw endpoints delete` in the `cleanup` is a defensive no-op for the edge where the process lingers — and note there is one less job to cancel, because Stage 4 lost the `session` job to begin with. The winner's `wait`/surface duty is folded into the WIN branch, which prints the winning URL.

---

## Testing status

The controller path (`Schedule Job? = No`) was verified end-to-end on live clusters: stages 2–4 individually (endpoint registered, URL published, page served, platform-auth redirect for anonymous requests, cancel deregisters the endpoint), and stage 6 as a real two-resource race (both endpoints up, every worker picked the same winner, the loser stood down and its endpoint disappeared, cancel tore the winner down). Stage 6's parent exercises the same matrix mechanics as stage 5, and stage 1 is byte-identical to the session tutorial's tested stage. The scheduler path (`Schedule Job? = Yes`) reuses `script_submitter` unchanged from the session tutorial but has not been re-verified in this edition.
