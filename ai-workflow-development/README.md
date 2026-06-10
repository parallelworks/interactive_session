# Building Activate workflows with AI agents

This directory collects **approaches for using an AI coding agent (Claude Code) to
design, build, test, and debug [Activate](https://parallelworks.com) workflows.**
Each approach is a different way to *host and drive the agent* — but they all share
the same platform knowledge and the same library of worked examples.

## The model: shared context + examples, per-approach methodology

| Piece | Where | Shared? |
|-------|-------|---------|
| **Context** — platform facts (workflow YAML schema, `session_runner`/`script_submitter`, `pw` CLI, job-dir layout) | [`references/activate-platform.md`](references/activate-platform.md) | shared by every approach |
| **Examples** — 7 runnable, verified demo workflows | [`examples/`](examples/) | shared by every approach |
| **Methodology** — the step-by-step process the agent follows | `<approach>/SKILL.md` | per approach |
| **Reproduction guide** — how to set up and drive the agent | `<approach>/README.md` | per approach |

The agent consumes these as a **Claude Code skill**. When `SKILL.md` + `references/`
+ `examples/` are installed under `~/.claude/skills/activate-workflows/`, Claude Code
(the CLI *and* the VS Code extension both read `~/.claude`) auto-discovers the skill
and follows the methodology whenever you ask it to build an Activate workflow.

## Approaches

| # | Approach | Where the agent runs | Workflow target | Guide |
|---|----------|----------------------|-----------------|-------|
| 01 | VS Code + Claude on a cloud cluster | The cluster's VS Code session (login node) | That same cluster | [`01-vscode-on-cluster/`](01-vscode-on-cluster/) |

_Future approaches — e.g. agent on the user workspace targeting many clusters, agent
on a laptop driving remote resources via `pw`, or a headless CLI run in CI — get a
new numbered directory that **reuses the same `references/` and `examples/`** and
ships its own `SKILL.md` + `README.md`._

## What a skill is made of (the three pieces)

- **`SKILL.md`** — the *methodology*: a concise, repeatable process (develop locally →
  wrap in YAML, reusing subworkflows → test with `pw` → debug from the job dir →
  iterate). Its frontmatter (`name: activate-workflows` + a `description`) lets Claude
  auto-trigger it, and you can invoke it by name.
- **`references/activate-platform.md`** — the *context*: dense, copy-paste-ready
  platform facts the agent consults instead of guessing.
- **`examples/`** — seven verified, runnable demo workflows the methodology points at
  (sessions, batch, multi-job DAG, fan-out/fan-in, `parallelworks/checkout`).

## Installing the skill

Pick an approach and follow its README. The install is the same everywhere — combine
the **shared** context + examples with that approach's `SKILL.md` into
`~/.claude/skills/activate-workflows/`:

```bash
# from the repo root (interactive_session/)
DST=~/.claude/skills/activate-workflows
mkdir -p "$DST/references"
cp ai-workflow-development/01-vscode-on-cluster/SKILL.md    "$DST/SKILL.md"
cp ai-workflow-development/references/activate-platform.md  "$DST/references/activate-platform.md"
cp -r ai-workflow-development/examples                       "$DST/examples"
```

The relative links inside `SKILL.md` (`references/…`, `examples/…`) are written for
that installed layout, where all three sit side by side. Then, in Claude Code:

> *Using the activate-workflows skill, build a workflow that …*

## Adding a new approach

1. `cp -r 01-vscode-on-cluster NN-your-approach`.
2. Keep its `SKILL.md` as-is unless the *process* genuinely differs for your
   environment (the core methodology is portable).
3. Rewrite its `README.md`: prerequisites, how to host/drive the agent, how it targets
   resources, and the skill-install step (which reuses the shared `references/` +
   `examples/`).
4. Add a row to the **Approaches** table above.
