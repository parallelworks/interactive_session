---
name: activate-workflows
description: >-
  Develop, test, and debug workflows on the Activate platform by Parallel Works.
  Use whenever the task involves an Activate / Parallel Works workflow, a remote
  interactive session, a web server exposed through the platform, the session_runner
  or script_submitter subworkflows, or the `pw` CLI (workflows create/update/run,
  sessions, cluster). Provides a proven local-first process plus a reference of
  platform facts pointing at the repo's real workflows and tutorials.
---

# Developing Activate (Parallel Works) workflows

A repeatable process for building a workflow that runs code on a compute resource
and (optionally) exposes a web server as a platform session. Read
[references/activate-platform.md](references/activate-platform.md) for the YAML
schema, subworkflow interfaces, `pw` CLI, and job-directory layout — this file is
the **process**; that file is the **facts**.

**The platform docs are authoritative and updated over time — this skill is a
snapshot that can fall behind.** When something here conflicts with them, trust the
docs and harden this skill (Step 5):
- Building workflows — <https://parallelworks.com/docs/run/workflows/building-workflows>
- Sessions — <https://parallelworks.com/docs/run/sessions>
- `pw` CLI — <https://parallelworks.com/docs/cli>

**Assume the `pw` client is already authenticated** — otherwise ask the user to log
in. Confirm context with `pw context list` if unsure. **Set `permissions: ['*']`** in
every workflow: besides allowing everyone to run it, it is what lets the in-workflow
`pw` client authenticate (e.g. `pw agent open-port`).

## Golden rules

- **Reuse subworkflows for submission/sessions; plain DAGs for the rest.** For a web
  service + session, wrap your code with `session_runner`. For "just run a
  script/sim on a cluster," call `script_submitter` (`v3.6`) directly. Do **not**
  hand-write job submission, port allocation, or tunnel logic. But pure orchestration
  (multi-job DAG, data flow, fan-out) needs **no** subworkflow — that's a first-class
  use. Learn the patterns from the **repo's own workflows and tutorials**, not from
  invented demos (reference §9): sessions →
  `workflow/yamls/{webshell,jupyterlab-host,openvscode}/`; job DAG / sessions / outputs
  → `workflow/tutorials/nginx/`; **fan-out / sweep → `workflow/tutorials/matrix/`**;
  retry/failover → `workflow/tutorials/round-robin-failover/`.
- **Pick the deployment variant by platform host — don't default to `general`.**
  `session_runner`/`script_submitter` ship as `general` / `emed` / `hsp` / `noaa`, and
  the **resource/scheduler/slurm/pbs form sections differ between them**. Choose:
  `emed` for `cluster.einsteinmed.edu`, `noaa` for `noaa.parallel.works`, `hsp` for
  `activate.hpc.mil`, `general` otherwise — **if unclear, ask the user.** Then copy the
  cluster/slurm/pbs form and `with:` block from the matching
  `workflow/yamls/<service>/<variant>_v4.yaml`. (`pw context list` shows the host.)
- **Pass every required subworkflow input, and `--dry-run` first.** A subworkflow's
  defaults-filler does NOT apply its own `hidden`/`ignore` rules, so non-optional
  fields with no default must be passed explicitly even when its form would hide
  them (e.g. `script_submitter`'s `cleanup_script_path`). `--dry-run` catches this —
  and variant/field mismatches — cheaply before you burn a real run.
- **Develop locally before touching YAML.** The YAML is a thin wrapper around code
  that already works.
- **Know where your job runs.** `ssh.remoteHost: ${{ inputs.resource.ip }}` runs a
  job on that resource's login node — that's where the job dir and your process
  live. See Step 4.

## Step 1 — Develop the code locally first

Write and test the core program (server, simulation, script) **directly on this
machine** until it runs standalone. Do not write any YAML yet.

- For a web service: bind a port from an argument/env var, default to `0.0.0.0`,
  and serve everything the page needs. Prefer the **standard library / preinstalled
  tools** so the controller script has nothing to install. Test every endpoint with
  `curl` and confirm it terminates/looks right.
- Drive it the way the platform will: `python3 server.py --port 8731 …` in the
  background, then `curl localhost:8731/...`. Iterate here — it's the fastest loop.
- Keep each piece a real file (you'll check these into the repo and `checkout` later).

Done when: the program runs from a clean shell with no manual setup and produces
correct output.

## Step 2 — Wrap the working code in workflow YAML

Mirror the proven pattern (see `workflow/yamls/webshell/general_v4.yaml`): a
**preprocessing** job that gets your files onto the node + writes `inputs.sh`, then a
**session_runner** (or **script_submitter**) job.

Provide the two contract scripts `session_runner` expects:
- **`controller-v3.sh`** — idempotent setup on the login node (has internet). Often
  just verifies prerequisites.
- **`start-template-v3.sh`** — binds **`${service_port}`** on `0.0.0.0`, writes
  `${PW_PARENT_JOB_DIR}/cancel.sh` (how to stop the service), and ends with
  `sleep inf` (or runs the server in foreground).

**Getting the scripts onto the node — use `parallelworks/checkout`, never base64**
(reference §10). Two modes depending on whether Claude can push to the repo:
1. **Write access (recommended):** ask the user to grant a **deploy key with write
   permission**. Work on a **development branch — never `main`** — commit and push your
   code, then `parallelworks/checkout` that branch (`branch: <dev-branch>`,
   `sparse_checkout: [<service-dir>]`). The user reviews/merges the branch, then you
   flip `branch:` to `main`.
2. **No write access:** you can't push, so stage the files on the resource (e.g.
   `~/pw/dev/<workflow>/`) and give preprocessing **two steps** — the
   `parallelworks/checkout` step **commented out** (configured for after the merge) and
   a **copy step** (`cp -r ~/pw/dev/<workflow>/. .`) that mimics it. The user later
   pushes & merges, uncomments checkout, and deletes the copy step.

Wire `session_runner`'s `service.{start_service_script,controller_script,inputs_sh,
rundir}` to `${PW_PARENT_JOB_DIR}/...` paths, set `slug` (`""` for a root web app),
and pass `resource`, `cluster.scheduler`, `cluster.slurm`, `cluster.pbs` **from the
matching variant's `*_v4.yaml`**. Add `include-workspace: true` on the
`compute-clusters` input if the workspace should be selectable.

**Sessions served from a base-path URL.** A session lives at
`…/me/session/<user>/<session-name>/<slug>`. Apps that build absolute URLs
(JupyterLab, many SPAs) need to know that prefix — either set the app's base-URL
(compute `basepath=/me/session/${PW_USER}/${{ sessions.session }}` and feed it in) or
front it with an **nginx reverse proxy** on `${service_port}`. See reference §11 and
`jupyterlab-host/start-template-v3.sh`. Apps that serve relative paths just use
`slug: ""` and need neither.

Numbers from `integer` inputs arrive as **strings**; guard with `${var:-default}`.

## Step 3 — Test end-to-end with the `pw` client

```bash
# always validate first — catches YAML/schema/variant errors without executing
pw workflows run --dry-run -i '{"resource":"<name>","scheduler":false}' ./my.yaml

pw workflows create my-wf  --yaml my.yaml --display-name "My WF"
pw workflows update my-wf  --yaml my.yaml          # after each edit
pw workflows run    my-wf  -i '{"resource":"<name>","scheduler":false,"…":…}' \
                           --name "e2e-1" -o json  # note run.slug + redirect (session name)
```

- **Pass the resource as a bare name string** (`"gcpsmall"`, `"workspace"`); the
  platform resolves the full object. Never hardcode IPs.
- Pick an **active** resource (`pw cluster ls`). `scheduler:false` runs the service
  on the login node — simplest for a demo.
- Watch progress: `pw workflows runs logs <slug> -f` or poll
  `pw workflows runs view <slug> -o json`. Success looks like the `create_session`
  job logging **"Session is ready"**.
- Confirm the session: `pw sessions ls -o table` shows it `running`, `tunnel`, with
  the remote host/port.

## Step 4 — Debug from the job directory and processes

After every run, inspect artifacts on the **node where the job ran** (the resource's
login node when `scheduler:false`):

```bash
ls -la ~/pw/jobs/<workflow-name>/<NNNNN>/         # run number zero-padded to 5 digits
cat   ~/pw/jobs/<workflow-name>/<NNNNN>/run.*.out # script_submitter output
cat   ~/pw/jobs/<workflow-name>/<NNNNN>/SESSION_PORT  ~/.../HOSTNAME
cat   ~/pw/jobs/<workflow-name>/<NNNNN>/<your-service>.out
ps -x | grep <your-process>                       # is the service alive?
curl  localhost:$(cat ~/pw/jobs/<wf>/<NNNNN>/SESSION_PORT)/   # does it answer?
```

**The execution node may not be this machine.** It's the login node of the chosen
resource. If files/processes aren't here, you targeted a different resource — either
target the resource whose login node *is* this host, or `pw ssh <resource>` to it.
Logs are always reachable via the API regardless of node:
```bash
pw workflows runs logs   <slug> --job session_runner          # subworkflow steps
pw workflows runs errors <slug> -o text                       # just the failures
```

Diagnose → fix the local code or YAML → push to the dev branch (Mode A) or re-stage
the files (Mode B) → `pw workflows update` → re-run. **Cancel runs you're done with:**
`pw workflows runs cancel <slug>` (its cleanup trap runs `cancel.sh`, stops the
service, and removes the session). A lingering `sleep inf` run holds resources.

## Step 5 — Harden this skill

Every time you hit a surprise — a wrong YAML field, an unexpected CLI flag, a
misunderstood subworkflow input, a debugging trick that worked — **add it to this
file or the reference** so the next run avoids it. These files are living documents.
Because the **platform docs change**, re-check them when behavior surprises you and
correct this skill toward the docs. **Do not add a new tutorial to
`workflow/tutorials/` without maintainer approval** — each must show something new and
non-repetitive; point at an existing tutorial instead.

## Best practices

- **Develop locally first; prefer the standard library** so controller scripts have
  nothing to install.
- **Deliver code with `parallelworks/checkout`, not base64.** Push to a dev branch and
  checkout that branch (write access), or stage on the resource + a commented-out
  checkout beside a stand-in copy step (no write access). See Step 2 / reference §10.
- **Match the deployment variant to the platform host** (`emed`/`noaa`/`hsp`/`general`)
  and copy that variant's resource/slurm/pbs form — don't reuse `general` blindly.
- **Orchestrate with the job graph.** Share files across jobs via `${PW_PARENT_JOB_DIR}`
  (`cd` into it). Pass values with `echo "K=v" | tee -a $OUTPUTS` (or pipe a program
  that prints `K=v` lines) and read `${{ needs.<job>.outputs.K }}`. Drive conditional
  steps with `if: ${{ needs.X.outputs.flag == 'true' }}` — compute the boolean
  upstream. Fan out with a **matrix strategy** (see `workflow/tutorials/matrix/`); fan
  in with `needs: [w1,w2,w3]`.
- **Make scripts idempotent and traceable:** `set -o pipefail`, `set -x`; check
  before installing; safe to re-run.
- **Stream progress and emit structured results.** Print incremental progress (it
  streams to `run.<JOBID>.out` / the page) and write a machine-readable result
  (JSON) — don't make the user guess whether it's alive or done.
- **Defensive inputs:** `integer`/numeric inputs arrive as strings — guard with
  `${var:-default}`; quote every `${{ ... }}` interpolation so empties/spaces don't
  break the shell.
- **Relative paths inside submitted scripts.** `script_submitter` `cd`s into `rundir`
  first; reference files relative to it, not via `${PW_PARENT_JOB_DIR}` (which may be
  unset on a SLURM/PBS compute node — the home FS is shared, so relative paths work).
- **Pin subworkflow versions** (`v1.4`, `v3.6`) so a marketplace update can't silently
  change behavior.
- **Clean up:** provide `cancel.sh`/cleanup scripts, and cancel runs you're done with
  (`pw workflows runs cancel`) so nothing lingers (`sleep inf`, SLURM allocations).

## Common pitfalls (learned from real runs)

- **Wrong deployment variant / mismatched resource form:** using `general`'s
  slurm/pbs fields against an `emed`/`noaa`/`hsp` subworkflow fails `--dry-run` with
  field errors. Match the variant to the host and copy its `*_v4.yaml` form.
- **Resource passing:** bare name string in `-i`, not a hand-built object; login
  IPs change, so never hardcode `ip`.
- **Subworkflow "Missing required fields":** pass non-optional subworkflow inputs
  with no default even when its form hides them (e.g. `cleanup_script_path: ""` +
  `define_cleanup_script: false` for `script_submitter`).
- **Scheduled jobs run on a compute node** that may lack `${PW_PARENT_JOB_DIR}`; use
  paths relative to `rundir`. Cloud-burst nodes are slow to provision (**6+ min**
  observed; `idle~ → CF → RUNNING`, `POWERING_UP` while booting) — watch with
  `squeue`/`sacct` on the login node and poll with long intervals; it's not a hang.
- **`workspace` resolves with empty `ip`** → its SSH steps run on the workspace node
  (a *different* host than a cluster login node). Match your debugging location to
  the resource you chose.
- **Code-delivery mistakes:** don't base64-embed; if you used the no-write-access
  copy step, remember it must be swapped for the (currently commented) checkout once
  the branch is merged.
- **Base-path apps break at the session URL** if served at the host root — set the
  app's base URL or front it with an nginx proxy (reference §11).
- **Service must bind `0.0.0.0:${service_port}`** (not `127.0.0.1`, not a fixed
  port) or the tunnel can't reach it / the port clashes.
- **Forgot `cancel.sh` or `sleep inf`:** the service is killed immediately or the
  job exits before the session registers.
- **Missing `permissions: ['*']`:** in-workflow `pw` calls fail to authenticate.
- **`pw sessions stop` 404s** if the run was already canceled (cancel tears the
  session down). Not an error.
- **Always `--dry-run`** before a real run; it catches schema/YAML problems cheaply.
