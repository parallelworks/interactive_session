---
name: activate-workflows
description: >-
  Develop, test, and debug workflows on the Activate platform by Parallel Works.
  Use whenever the task involves an Activate / Parallel Works workflow, a remote
  interactive session, a web server exposed through the platform, the session_runner
  or script_submitter subworkflows, or the `pw` CLI (workflows create/update/run,
  sessions, cluster). Provides a proven local-first process plus a reference of
  platform facts and a worked fractal demo.
---

# Developing Activate (Parallel Works) workflows

A repeatable process for building a workflow that runs code on a compute resource
and (optionally) exposes a web server as a platform session. Read
[references/activate-platform.md](references/activate-platform.md) for the YAML
schema, subworkflow interfaces, `pw` CLI, and job-directory layout — this file is
the **process**; that file is the **facts**. The worked example lives in
[examples/fractal/](examples/fractal/).

**Assume the `pw` client is already authenticated.** otherwise ask the
user to log in. Confirm context with `pw context list` if unsure.

## Golden rules

- **Reuse subworkflows for submission/sessions; plain DAGs for the rest.** For a web
  service + session, wrap your code with `session_runner`
  (`workflow/session_runner/v1.4/general.yaml`). For "just run a script/sim on a
  cluster," call `script_submitter` (`v3.6`) directly. Do **not** hand-write job
  submission, port allocation, or tunnel logic. But pure orchestration (multi-job
  DAG, data flow, fan-out) needs **no** subworkflow — that's a first-class use.
  Seven worked examples cover the patterns ([examples/](examples/)):
  sessions — [fractal](examples/fractal/), [trainwatch](examples/trainwatch/),
  [fileserver](examples/fileserver/); batch — [montecarlo](examples/montecarlo/)
  (script_submitter), [pipeline](examples/pipeline/) (DAG), [sweep](examples/sweep/)
  (fan-out), [repo-analyzer](examples/repo-analyzer/) (`parallelworks/checkout`).
- **Pass every required subworkflow input, and `--dry-run` first.** A subworkflow's
  defaults-filler does NOT apply its own `hidden`/`ignore` rules, so non-optional
  fields with no default must be passed explicitly even when its form would hide
  them (e.g. `script_submitter`'s `cleanup_script_path`). `--dry-run` catches this
  cheaply before you burn a real run.
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
- Keep each piece a real file (you'll embed or check these out later).

Done when: the program runs from a clean shell with no manual setup and produces
correct output.

## Step 2 — Wrap the working code in workflow YAML

Mirror the proven pattern (see `workflow/yamls/webshell/general_v4.yaml`): a
**preprocessing** job that prepares files + `inputs.sh`, then a **session_runner**
(or **script_submitter**) job.

Provide the two contract scripts `session_runner` expects:
- **`controller-v3.sh`** — idempotent setup on the login node (has internet). Often
  just verifies prerequisites.
- **`start-template-v3.sh`** — binds **`${service_port}`** on `0.0.0.0`, writes
  `${PW_PARENT_JOB_DIR}/cancel.sh` (how to stop the service), and ends with
  `sleep inf` (or runs the server in foreground).

Get the scripts onto the node. Two options:
1. **`parallelworks/checkout`** a git repo (what the repo examples do), or
2. **Self-contained**: have preprocessing write them. To embed code without
   heredoc-indentation or `${{ }}` templating breakage, **base64-encode the files
   and `base64 -d <<'B64'`** them in a `run:` step. See `examples/fractal/build_yaml.py`
   for a builder that keeps the deployed code byte-identical to the local files.
   **Every embedded line must be indented to the `run:` block's content indent**
   (e.g. 10 spaces) or YAML ends the literal block early
   (`could not find expected ':'`).

Wire `session_runner`'s `service.{start_service_script,controller_script,inputs_sh,
rundir}` to `${PW_PARENT_JOB_DIR}/...` paths, set `slug` (`""` for a root web app),
and pass `resource`, `cluster.scheduler`, `cluster.slurm`, `cluster.pbs`. The full
input form (resource picker + scheduler/slurm/pbs groups) is in the reference and
the fractal example — copy it. Add `include-workspace: true` on the `compute-clusters`
input if the workspace should be selectable.

Numbers from `integer` inputs arrive as **strings**; guard with `${var:-default}`.

## Step 3 — Test end-to-end with the `pw` client

```bash
# always validate first — catches YAML/schema errors without executing
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

Diagnose → fix the local code or YAML → `pw workflows update` (rebuild the YAML
first if you embed code) → re-run. **Cancel runs you're done with:**
`pw workflows runs cancel <slug>` (its cleanup trap runs `cancel.sh`, stops the
service, and removes the session). A lingering `sleep inf` run holds resources.

## Step 5 — Harden this skill

Every time you hit a surprise — a wrong YAML field, an unexpected CLI flag, a
misunderstood subworkflow input, a debugging trick that worked — **add it to this
file or the reference** so the next run avoids it. These files are living documents;
the validation run exists to harden them.

## Best practices

- **Develop locally first; prefer the standard library** so controller scripts have
  nothing to install (both examples are pure-stdlib Python → zero `pip`).
- **Self-contained YAML via base64.** Embed code with `base64 -d <<'B64'` rather
  than raw heredocs — it dodges YAML-indent, `${{ }}` templating, and quoting
  landmines, and keeps deployed code byte-identical to what you tested. Keep a
  `build_yaml.py` so the YAML regenerates from the source files (see any example).
  The alternative for whole git repos is `parallelworks/checkout` (see repo-analyzer).
- **Orchestrate with the job graph.** Share files across jobs via `${PW_PARENT_JOB_DIR}`
  (`cd` into it). Pass values with `echo "K=v" | tee -a $OUTPUTS` (or pipe a program
  that prints `K=v` lines) and read `${{ needs.<job>.outputs.K }}`. Drive conditional
  steps with `if: ${{ needs.X.outputs.flag == 'true' }}` — compute the boolean
  upstream. Fan out by giving sibling jobs the same `needs` (no edge between them);
  fan in with `needs: [w1,w2,w3]`. Generate repetitive jobs in `build_yaml.py`.
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
- **Embedded-code YAML errors:** under-indented heredoc body terminates the literal
  block → `could not find expected ':'`. Keep every embedded line at the block
  indent; base64 avoids brace/`$`/quote landmines entirely.
- **Service must bind `0.0.0.0:${service_port}`** (not `127.0.0.1`, not a fixed
  port) or the tunnel can't reach it / the port clashes.
- **Forgot `cancel.sh` or `sleep inf`:** the service is killed immediately or the
  job exits before the session registers.
- **`pw sessions stop` 404s** if the run was already canceled (cancel tears the
  session down). Not an error.
- **Always `--dry-run`** before a real run; it catches schema/YAML problems cheaply.
