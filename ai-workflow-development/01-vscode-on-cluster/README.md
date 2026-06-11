# Approach 01 — VS Code + Claude on a cloud cluster

Run Claude Code **inside a VS Code session on a cloud cluster** and let it build,
deploy, and debug Activate workflows that target *that same cluster*. Because the
agent's shell and the workflow's jobs share one node, debugging is fully local
(`ps -x`, `~/pw/jobs/…`).

## Setup

1. **Start VS Code on the cluster** — launch the **openvscode** session from the
   Activate UI, or `pw sessions create --type vscode <cluster> --open`. Open the
   integrated terminal (a shell on the cluster node).
2. **Authenticate `pw`** (cluster nodes are usually pre-authenticated; if not,
   `pw auth token` — see <https://parallelworks.com/docs/cli>). Check with
   `pw context list` and `pw cluster ls` (cluster should be `active`).
3. **Install the Claude Code VS Code extension**, sign in, and set permission mode to
   **bypass permissions** (the methodology runs many `pw`/`git`/shell commands).
4. **Install the skill** — from this directory:
   ```bash
   bash install.sh
   ```
   It copies `SKILL.md` + the shared `references/` into
   `~/.claude/skills/activate-workflows/`. Keep the `interactive_session` repo on the
   node — the skill points at its real workflows (`workflow/yamls/`) and tutorials
   (`workflow/tutorials/`) for examples.
5. **Ask for a workflow**, e.g.:
   > *Using the activate-workflows skill, build a workflow that runs a simulation and
   > serves a live progress page as a session.*

The agent then follows `SKILL.md`: **develop locally → wrap in YAML (reusing
`session_runner`/`script_submitter`, matching the deployment variant) → deliver code
via `parallelworks/checkout` → test with `pw workflows create/run` → debug from
`~/pw/jobs` + `ps -x` → iterate.**

## Notes

- **Give Claude write access** via a deploy key with write permission so it can push
  workflow code to a **development branch** (never `main`) and `parallelworks/checkout`
  it. Without write access, the agent stages files on the resource and uses a stand-in
  copy step beside a commented-out checkout for you to merge later (SKILL Step 2).
- Pick the resource whose login node **is** the VS Code node, run with
  `scheduler:false`, so `~/pw/jobs` and `ps -x` are local.
- `--dry-run` every YAML before a real run; cancel session runs when done
  (`pw workflows runs cancel <slug>`).
- The platform docs are the source of truth and may be newer than this skill:
  [workflows](https://parallelworks.com/docs/run/workflows/building-workflows) ·
  [sessions](https://parallelworks.com/docs/run/sessions) ·
  [CLI](https://parallelworks.com/docs/cli).
