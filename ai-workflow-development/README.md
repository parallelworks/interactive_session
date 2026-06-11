# Building Activate workflows with AI agents

Approaches for using an AI coding agent (Claude Code) to design, build, test, and
debug [Activate](https://parallelworks.com) workflows. Each approach is a different way
to *host and drive the agent*; they share the same platform reference and point the
agent at the repo's own workflows and tutorials.

**Official docs (authoritative — newer than this skill when they conflict):**
[building workflows](https://parallelworks.com/docs/run/workflows/building-workflows) ·
[sessions](https://parallelworks.com/docs/run/sessions) ·
[`pw` CLI](https://parallelworks.com/docs/cli)

## The model

| Piece | Where | Shared? |
|-------|-------|---------|
| **Reference** — platform facts (YAML schema, `session_runner`/`script_submitter`, `pw` CLI, job-dir layout, deployment variants, code delivery, base-path sessions) | [`references/activate-platform.md`](references/activate-platform.md) | shared by every approach |
| **Examples to learn from** — the repo's real workflows (`workflow/yamls/`) and tutorials (`workflow/tutorials/`) | the `interactive_session` repo | shared |
| **Methodology** — the step-by-step process the agent follows | `<approach>/SKILL.md` | per approach |
| **Setup guide + installer** — how to host/drive the agent | `<approach>/README.md` + `<approach>/install.sh` | per approach |

The agent consumes `SKILL.md` + `references/` as a **Claude Code skill** installed under
`~/.claude/skills/activate-workflows/`. Claude Code (CLI *and* VS Code extension both
read `~/.claude`) then auto-discovers it.

## Approaches

| # | Approach | Where the agent runs | Workflow target | Guide |
|---|----------|----------------------|-----------------|-------|
| 01 | VS Code + Claude on a cloud cluster | The cluster's VS Code session (login node) | That same cluster | [`01-vscode-on-cluster/`](01-vscode-on-cluster/) |

_Future approaches get a new numbered directory that **reuses the shared
`references/`** and ships its own `SKILL.md`, `README.md`, and `install.sh`._

## Installing the skill

Each approach ships a `bash install.sh`. For approach 01:

```bash
cd 01-vscode-on-cluster
bash install.sh
```

It copies that approach's `SKILL.md` + the shared
`references/activate-platform.md` into `~/.claude/skills/activate-workflows/`. Then, in
Claude Code:

> *Using the activate-workflows skill, build a workflow that …*

The skill points at the `interactive_session` repo's real workflows and tutorials for
worked patterns, so keep that repo available on the node.

## Adding a new approach

1. `cp -r 01-vscode-on-cluster NN-your-approach`.
2. Keep `SKILL.md` unless the *process* genuinely differs (the core methodology is
   portable). `install.sh` already resolves the shared `references/` relative to itself.
3. Rewrite `README.md`: prerequisites, how to host/drive the agent, how it targets
   resources, and `bash install.sh`.
4. Add a row to the **Approaches** table above.

> The skill teaches from the repo's own `workflow/yamls/` and `workflow/tutorials/` —
> point new material there. New tutorials require maintainer approval.
