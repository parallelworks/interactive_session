# Agent Orchestrator

Talk to **all your clusters at once.** Run an agent on each cluster
([Lite Agent](../lite-agent/) or [Hermes Agent](../hermes-agent/)), then launch
this orchestrator on your workspace — it asks the right clusters in parallel and
gives you one answer.

```
   You ─► ACTIVATE chat ─► Agent Orchestrator   (workspace; the model you talk to)
                                  │  asks the right clusters in parallel
                  ┌───────────────┼───────────────┐
                  ▼               ▼               ▼
             Agent @ A       Agent @ B       Agent @ C   (lite-agent or hermes-agent;
             runs commands on each cluster and reports back)
```

*"Where should I run my GPU workload?"* → it asks each cluster's agent, then
recommends one.

## Fleets (the marker)

Both the orchestrator and the agents take a **Fleet marker** (default `worker`).
**An orchestrator only sees agents with the same marker.** Launch agents and an
orchestrator with `gpuworker` and you get a separate fleet that ignores the
`worker` agents — handy for grouping by purpose or keeping experiments apart.

## Use it

1. On each cluster, launch **Lite Agent** and/or **Hermes Agent** (the latter in
   *Built-in chat* mode) — same **Fleet marker** on each.
2. Launch **Agent Orchestrator** with that marker (runs on your workspace; finds
   the agents automatically).
3. Open ACTIVATE **Chat**:
   - **`<marker>-orchestrator`** — talks to *all* clusters in the fleet and combines answers.
   - **`<marker>-<cluster>`** (e.g. `worker-gcpsmall`) — talks to just that one cluster.

Launch or stop an agent any time — it joins or drops off automatically.

## Settings

| Setting | What it does | Default |
|---|---|---|
| **Fleet marker** | Only agents with this marker are coordinated | `worker` |
| **Model** | The LLM behind the orchestrator (must support tool calling). Accepts any id from `pw ai models ls` or the short name shown in the Chat model picker (e.g. `glm-5.1`, or `/gpt-oss-20b` for a session-served model) | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation usage is billed to (for `org:*` models) | `Private LLM Group` |
| **Per-cluster timeout** | How long to wait for a cluster's agent to answer | 300 s |

## Good to know

- Each cluster's agent does the real work; the orchestrator routes questions and
  synthesizes the replies.
- It reaches each agent privately over the platform's own connection — no open
  ports or roster to maintain.

## Stopping

Cancel the run to end the orchestrator chat. Cancelling an agent just removes that
cluster from the fleet; the others keep working.
