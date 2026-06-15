# Python AI Multi-Agent

**Chat with your compute clusters in plain English.** Ask a question — *"which
cluster is least busy?"*, *"start my job on cluster B"*, *"do any of these have a
free GPU?"* — and get one clear answer, backed by real commands run live on the
machines themselves.

It works by putting a small AI agent **on each cluster** and a single
**orchestrator** in front of them that you talk to from the platform chat.

```
                  You  (platform chat)
                        │
              ┌─────────▼──────────┐
              │   Orchestrator     │     the one chat model you talk to
              │   (your workspace) │     (Python AI Orchestrator)
              └─────────┬──────────┘
            asks the right clusters, in parallel
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐
    │  Worker  │  │  Worker  │  │  Worker  │   one agent per cluster
    │ cluster A│  │ cluster B│  │ cluster C│   (Python AI Worker)
    └──────────┘  └──────────┘  └──────────┘
```

## ⚠️ This is two workflows — use them together

Python AI ships as a **pair**, and you need both:

| Workflow | Run it… | Does |
|---|---|---|
| **Python AI Worker** | **once per cluster** you want to reach | Runs commands on that cluster and reasons over the output |
| **Python AI Orchestrator** | **once**, on your workspace | The single agent you chat with; routes your questions to the workers and combines their answers |

A worker on its own has no chat for you to talk to, and the orchestrator with no
workers can't reach any clusters. **Launch at least one worker, then the
orchestrator.**

## Getting started

**1. Add a worker to each cluster.** Launch **Python AI Worker** once per
cluster, picking that cluster in the form. Keep *Schedule Job?* **off** so the
worker stays on the login node (where it can reach the internet and be reached by
the orchestrator).

**2. Launch the orchestrator.** Launch **Python AI Orchestrator**. It always runs
on your workspace and **finds your workers automatically** — nothing to
configure.

**3. Chat.** Open the platform chat. You'll see one model per choice:

- **`python-ai-orchestrator`** — talks to *all* your clusters and combines the
  answers. Use it for *"compare my clusters"* or *"where should I run X?"*.
- **`python-ai-<cluster>`** (e.g. `python-ai-gcpsmall`) — talks to *just that one*
  cluster. Use it when you only care about a single machine.

> Add or remove workers any time. A new worker shows up as its own
> `python-ai-<cluster>` model and the orchestrator starts using it
> automatically — no restart needed.

## What you can ask it

- **"Where should I run a GPU training job?"** — checks each cluster's GPUs,
  memory and load, then recommends one.
- **"How busy is each cluster right now?"** — reports queues and utilization
  across all of them.
- **"On cluster B, start my simulation in `~/runs/exp1` and tell me the job ID."**
- **"Which clusters have CUDA 13 and at least 40 GB of free disk?"**
- **"Did my job on cluster A finish?"** — checks the scheduler and tells you.

## Settings

Both workflows run with sensible defaults — you usually don't need to change
anything.

| Setting | What it does | Default |
|---|---|---|
| **System prompt** | The instructions that shape the agent's behavior. Edit it to change tone, rules, or what it's allowed to do. (On the worker, `{cluster}` is replaced with the cluster's name.) | the built-in prompt |
| **Model** | The LLM behind the agents — must support tool calling | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation your model usage is billed to | `Private LLM Group` |
| **Per-task timeout** *(orchestrator)* | How long to wait for a cluster to answer | 300 s |
| **Agent port** *(worker)* | Port the worker listens on, on the login node | 8717 |

On the worker, **Cluster** selects where it runs.

## Good to know

- **Run one worker per cluster.** The orchestrator reaches each worker privately
  over the platform's own connection — no open ports or extra setup.
- **For long jobs, ask the agent to *submit* and report back** (e.g. the job ID),
  then ask *"is it done?"* later. It won't sit and block waiting.
- **Answers come from real command output**, not guesses — the agents only know
  what the live commands on each cluster tell them.
- **The worker can run shell commands** on the cluster as you. Anyone allowed to
  use the chat can do the same, so treat access accordingly.

## Stopping

Cancel the workflow runs from the platform when you're done — each shuts its agent
down cleanly. Cancelling a worker just removes that cluster from the
orchestrator's view; cancelling the orchestrator ends the chat.
