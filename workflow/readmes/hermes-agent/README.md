# Hermes Multi-Agent

Chat with your compute clusters in plain language. Hermes puts one **AI agent on
each cluster** and a single **orchestrator** you talk to from the platform chat.
Ask a question and it asks the right clusters, runs the commands there, and
gives you one clear answer.

```
                  You  (platform chat)
                        │
              ┌─────────▼──────────┐
              │   Hermes           │     one chat model you talk to
              │   Orchestrator     │     (runs on your workspace)
              └─────────┬──────────┘
            asks each cluster, in parallel
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
    ┌──────────┐  ┌──────────┐  ┌──────────┐
    │  Worker  │  │  Worker  │  │  Worker  │   one agent per cluster
    │ cluster A│  │ cluster B│  │ cluster C│   (runs commands there)
    └──────────┘  └──────────┘  └──────────┘
```

## What you can ask it

- **“Where should I run a GPU training job?”** — it checks each cluster's GPUs,
  memory and load, then recommends one.
- **“How busy is each cluster right now?”** — it reports queues and utilization
  across all of them.
- **“On cluster B, start my simulation in `~/runs/exp1` and tell me the job ID.”**
- **“Which clusters have CUDA 13 and at least 40 GB of free disk?”**

## Getting started

**1. Add a worker to each cluster you want to reach.** Launch the **Hermes
Worker** workflow once per cluster, picking that cluster in the form. Keep
*Schedule Job?* off so the worker stays on the login node.

**2. Launch the orchestrator.** Launch the **Hermes Orchestrator** workflow. It
always runs on your workspace and finds your workers automatically — there's
nothing to configure.

**3. Chat.** Open the platform chat. You'll see a model per choice:

- **`hermes-orchestrator`** — talks to *all* your clusters and combines the
  answers (use this for "compare my clusters" / "where should I run X?").
- **`hermes-<cluster>`** (e.g. `hermes-gcpsmall`) — talks to *just that one*
  cluster. Pick this when you only care about a single machine.

> Launch a worker any time — it shows up as its own `hermes-<cluster>` model and
> the orchestrator starts using it automatically, no restart needed.

## Settings

Both workflows use sensible defaults; you usually don't need to change anything.

| Setting | What it does | Default |
|---|---|---|
| **Model** | The AI model behind the agents (must support tool calling) | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation your AI usage is billed to | `Private LLM Group` |
| **Per-task timeout** | How long the orchestrator waits for a cluster to answer | 300 s |

On the worker, **Cluster** selects where it runs and **Agent port** is the port
it listens on (change it only if 8717 is in use).

## Good to know

- Run **one worker per cluster**. The orchestrator talks to each worker
  privately over the platform's own connection — no open ports or extra setup.
- For long jobs, ask the agent to **submit** the work and report back (e.g. the
  job ID); then ask “is it done?” later. It won't sit and wait.
- The agents only know what real commands tell them — answers come from live
  output on each cluster, not guesses.

## Stopping

Cancel the workflow runs from the platform when you're done (each one shuts its
agent down cleanly). Cancelling a worker just removes that cluster from the
orchestrator's view; cancelling the orchestrator ends the chat agent.
