# Approach 01 — VS Code + Claude on a cloud cluster

**The agent runs *on* a cloud cluster and builds workflows that target *that same
cluster*.** You start a VS Code session on the cluster, run the Claude Code VS Code
extension inside it, authenticate the `pw` client in the terminal, and let the agent
develop, deploy (`pw workflows …`), and debug workflows — all on the one node.
Because the agent's shell and the workflow's jobs share that node, debugging is fully
local (`ps -x`, `~/pw/jobs/…`).

This is the approach used to author the `activate-workflows` skill and its seven
examples.

## What's distinctive about this approach

- **Single node, single target.** The agent's shell, the `pw` client, and the
  workflow's `scheduler:false` jobs all run on the cluster's login/management node.
  `inputs.resource` is that cluster (passed to `pw` as the bare cluster name).
- **Local debugging.** The agent inspects `~/pw/jobs/<workflow>/<run>/` and `ps -x`
  directly, because the running service is on the same host it's working from.
  (Targeting `workspace` instead would put jobs on a *different* node — see
  "where jobs run = where you debug" in the context file.)
- **Internet on the node.** A cluster login node is the controller and has internet,
  so `git`/`pip`/`pw agent open-port` all work during development.

## Prerequisites

- An Activate account with an **active cloud cluster** (e.g. a `google-slurm` cluster
  such as `gcpsmall`). Start/stop clusters from the **Activate UI** (there is no
  `pw cluster start`). Confirm it's up with `pw cluster ls` → `active`.
- `python3` on the node (standard); the examples are pure-stdlib, so nothing to
  `pip install`.
- The `pw` CLI (preinstalled on Activate cluster nodes).

## Reproduce the setup

### 1. Start VS Code on the cluster
Either:
- **Activate UI:** launch the **openvscode** (VS Code in the browser) session on your
  cluster, **or**
- **CLI (from your workspace/laptop):** `pw sessions create --type vscode <cluster> --open`

Open the integrated terminal — it is a shell **on the cluster node**.

### 2. Authenticate the `pw` client in the terminal
On Activate, the CLI is pre-authenticated on user workspaces and *existing* clusters;
on a **cloud cluster** you authenticate once:
```bash
pw auth token            # or: pw auth apikey   (see https://parallelworks.com/docs/cli#authentication)
pw auth whoami           # confirm your user
pw context list          # confirm user@host + organization, CURRENT = *
pw cluster ls            # confirm your cluster shows "active"
```

### 3. Install the Claude extension + grant bypass permissions
- Install the **Claude Code** extension from the VS Code marketplace (it runs the
  agent inside this on-cluster VS Code) and sign in.
- Set the permission mode to **bypass permissions** ("skip permission prompts"). This
  lets the agent run `pw`, `git`, file edits, and shell commands without approving
  each one — appropriate here because it's your own trusted dev cluster. (Per-action
  approval also works, but the methodology issues many commands.)

### 4. Install the skill, then ask for a workflow
Install the skill files (next section), then tell the agent, e.g.:

> *Using the activate-workflows skill, build a workflow that runs a Mandelbrot render
> and serves a live progress page as a session.*

The agent follows `SKILL.md`: **develop locally → wrap in YAML (reusing
`session_runner`/`script_submitter`) → test with `pw workflows create/run` → debug
from `~/pw/jobs` + `ps -x` → iterate** until it runs end-to-end.

## What to do with the skill files

Claude Code discovers **skills** in `~/.claude/skills/`. A skill is a folder named for
the skill, containing `SKILL.md` (+ optional `references/`, `examples/`). Install this
one so the agent (CLI or VS Code extension — both read `~/.claude`) picks it up. Run in
the VS Code terminal, **from the repo root** (`interactive_session/`):

```bash
DST=~/.claude/skills/activate-workflows
mkdir -p "$DST/references"
cp ai-workflow-development/01-vscode-on-cluster/SKILL.md    "$DST/SKILL.md"
cp ai-workflow-development/references/activate-platform.md  "$DST/references/activate-platform.md"
cp -r ai-workflow-development/examples                       "$DST/examples"
```

After this, `~/.claude/skills/activate-workflows/` contains:

| File | Role | Source |
|------|------|--------|
| **`SKILL.md`** | the *methodology* the agent follows; its frontmatter (`name: activate-workflows`, `description`) lets Claude auto-trigger it and lets you invoke it by name | this approach's directory (per-approach) |
| **`references/activate-platform.md`** | the *platform context* the agent consults (YAML schema, `session_runner`/`script_submitter` interfaces, `pw` CLI, job-dir layout) | shared `references/` |
| **`examples/`** | seven verified demo workflows `SKILL.md` points at | shared `examples/` |

> The relative links inside `SKILL.md` (`references/…`, `examples/…`) resolve once the
> three sit together in `~/.claude/skills/activate-workflows/` — exactly what the
> install above produces. (In the repo they live in separate places so the context and
> examples can be **shared** by every approach.)

Verify the agent can see it:
```bash
ls ~/.claude/skills/activate-workflows     # -> SKILL.md  references/  examples/
```
In Claude Code the skill now appears in the available-skills list; invoke it with
*"Using the activate-workflows skill, …"*.

## Notes from building this approach

- Pick the resource whose login node **is** the VS Code node so `ps -x` / `~/pw/jobs`
  are local — here that's the cluster itself, run with `scheduler:false`.
- The `pw` client is assumed authenticated; the agent never runs `pw auth`.
- Cancel session runs when finished (`pw workflows runs cancel <slug>`) — a session's
  start script holds a `sleep inf`.
- `--dry-run` every YAML before a real run; embed code via `base64` (or
  `parallelworks/checkout`) — both are covered in `SKILL.md` and the examples.
