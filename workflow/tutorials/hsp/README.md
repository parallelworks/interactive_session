# Rendering a Fractal on Activate — A Workflow Tutorial

This tutorial turns a small, self-contained fractal renderer into an Activate workflow. You start by running the script by hand on a cluster so you can see exactly what it does, then automate it one piece at a time. Each stage has a matching workflow file you can run as-is from the Activate UI.

By the end of the stages built so far you will understand how to:

- Define workflow inputs — with labels, tooltips, defaults, and validation — and run steps on a remote cluster over SSH
- Use `needs` to sequence jobs and to run independent jobs in parallel
- Pull example code onto the cluster with the `checkout` action
- Pass workflow inputs into your scripts as environment variables
- Create a browser session automatically with the `update-session` action
- Pick a free port at runtime with `pw agent` and pass values between jobs as outputs

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

  run:
    needs:
      - install
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Render and Serve                # CHANGED: serve on the chosen port
        run: RESOLUTION=${{ inputs.resolution }} PORT=${{ needs.install.outputs.PORT }} ./fractal-demo/run.sh

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

**`needs.<job>.outputs.<name>`.**
This reads a value published by an upstream job. `${{ needs.install.outputs.PORT }}` is used in two places — the `run` job and the `session` job — so both use the exact port chosen in `install`.

**Why the port is chosen in `install`, not `run`.**
You can only read a job's outputs by listing it under `needs`, and `needs` waits for that job to *finish*. The `run` job runs `run.sh`, which serves forever and never finishes — so no job could ever read an output from it. `install` finishes, so it is the right place to pick the port and hand it to everything downstream.

**`permissions: ['*']`.**
The `pw` CLI authenticates against the Activate API. `permissions` grants the workflow a token with the same access as the user who runs it. Without it, `pw agent open-port` fails.

Now each run gets its own port, so two runs on the same cluster no longer collide — and you are still redirected straight to the progress page.
