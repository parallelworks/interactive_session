# Hermes multi-agent (orchestrator + per-cluster workers)

An **orchestrator agent on the platform workspace** that coordinates **one worker
agent per cluster**. Both are **OpenAI-compatible agents** declared as
`openAI: true` sessions, so the Activate platform registers them as **models in
its built-in chat** — you just chat with them (no bespoke UI). Built on the same
`session_runner` pattern as every other session in this repo.

> "Hermes" (Nous Research) is **not installed** — the agents run a built-in
> minimal agent loop against the platform LLM. Swapping in real Hermes is
> optional (see *Status & limitations* #4).

## Architecture

```
                    platform workspace
              ┌──────────────────────────────┐
              │  hermes-orchestrator          │  orchestrator.py
              │  OpenAI agent; tools =        │  (chat model: openAI:true)
              │  list_workers, delegate       │
              └───────────────┬──────────────┘
        pw ssh <cluster> curl localhost:<port>/task   (hub-and-spoke; parallel)
          ┌─────────────┬─────┴───────────┐
          ▼             ▼                 ▼
   ┌────────────┐ ┌────────────┐   ┌────────────┐
   │ gcpsmall   │ │ a30gpu...  │   │  cluster N │   agent_server.py per cluster
   │ worker     │ │ worker     │   │  worker    │   (OpenAI agent; run_shell tool)
   └────────────┘ └────────────┘   └────────────┘
        every agent's brain → platform OpenAI endpoint (GLM)
```

- **Brain**: every agent calls `https://${PW_PLATFORM_HOST}/api/openai/v1`,
  authenticated with the **runtime `PW_API_KEY`** (never written to disk).
  Org-provider models (`org:*`, e.g. GLM) also require the `X-Allocation` header,
  sent per request. Default model `org:glm/glm-5.1` (tool-calling capable).
- **Workers** are agents that act on their own cluster: brain + a `run_shell`
  tool → they run commands and answer from real output.
- **Orchestrator** is an agent whose *tools are the workers*: `list_workers`
  (discovery) and `delegate(cluster, task)`. Its brain decides when to delegate,
  to whom, and synthesizes the replies.
- **Transport** orchestrator→worker: `pw ssh <cluster> curl localhost:<port>/task`
  — no inbound ports, reuses pw auth, works from inside a deployed session.
  Delegation is **parallel** (total time ≈ slowest worker).
- **Why workers run on the login node** (`scheduler:false`): that's where both the
  internet (for the brain) and `pw ssh … localhost` reach them.

## Files

| File | Role |
|------|------|
| `hermes-agent/agent_server.py` | WORKER: OpenAI agent (`/v1/chat/completions`, `/v1/models`, SSE) + `/task` (orchestrator contract) + `/health` |
| `hermes-agent/orchestrator.py` | ORCHESTRATOR: OpenAI agent (`/v1/chat/completions`, `/v1/models`, SSE); tools = `list_workers`, `delegate`; auto-discovers workers |
| `hermes-agent/controller-v3.sh` | idempotent login-node setup; brain base URL; installs Hermes only if `hermes_install_cmd` given |
| `hermes-agent/start-template-v3.sh` | role dispatch; exports brain env (PW_API_KEY, X-Allocation, model); `cancel.sh`; `sleep inf` |
| `workflow/yamls/hermes-worker/general_v4.yaml` | worker workflow (run once per cluster) |
| `workflow/yamls/hermes-orchestrator/general_v4.yaml` | orchestrator workflow (run once on the workspace) |

## Setup (once)

No org secret needed — auth is the runtime `PW_API_KEY`. Just confirm the
defaults match your platform:
1. A tool-calling-capable model id: `pw ai models ls` (default `org:glm/glm-5.1`).
2. The allocation to bill: `GET /api/allocations` (default `Private LLM Group`).

## Run

```bash
# a worker on each cluster (login node)
pw workflows run hermes-worker -i '{"cluster":{"resource":"gcpsmall","scheduler":false}}'     --name w-gcpsmall
pw workflows run hermes-worker -i '{"cluster":{"resource":"a30gpuserver","scheduler":false}}' --name w-a30

# the orchestrator on the workspace -- no roster needed; it discovers workers
pw workflows run hermes-orchestrator -i '{"cluster":{"resource":"workspace","scheduler":false}}' --name orchestrator
```

(`pw workflows create … --yaml …` first time; `pw workflows update … --yaml …`
after editing a YAML — `run` uses the **stored** definition, not the local file.)

## Use it (platform chat)

Both sessions register as chat models (`openAI: true`). List them and chat:

```bash
pw ai models ls                                   # find the model id
pw ai chats new -p "which cluster is best for a GPU job?" "<orchestrator-model-id>"
```

…or pick the model in the platform web chat. Ask the **orchestrator** anything
about the clusters — it calls `list_workers`, delegates with `delegate(cluster,
task)`, and synthesizes. Example collaborative goal: *"Which cluster is best for
a GPU training job?"* → each worker runs `nvidia-smi` locally, the orchestrator
recommends one.

## Worker discovery

The orchestrator runs `pw sessions ls`, keeps running sessions whose **name
contains the `hermes_worker` marker** (set by the worker YAML's `sessions:` key —
independent of the workflow name), and reads each one's cluster (`targetName`)
and port (`remotePort`). No static roster; new workers appear automatically.

## Status & limitations

1. **Worker chat-model registration (OPEN).** Worker sessions are `openAI: true`
   and serve `/v1/models`, but cluster-hosted openAI sessions were **not** observed
   registering in `pw ai models ls` (only the **workspace-hosted** orchestrator
   did). Workers are always reachable **via the orchestrator** regardless; whether
   each worker is *individually* chat-selectable depends on platform behavior —
   confirm the rule for cluster-tunnel openAI sessions.
2. **Long synchronous goals can 502.** A heavy goal (many commands across clusters,
   ~minute+) can exceed the session-tunnel proxy timeout. Mitigated by parallel
   delegation + streaming; the ultimate fix is an async job+poll pattern.
3. **Cluster self-label cosmetic.** A worker may report its cluster as the
   username; the orchestrator addresses workers by the discovered name, so this is
   display-only. (`inputs.cluster.resource.name` interpolation needs fixing.)
4. **Real Hermes (optional).** Agents use the built-in brain loop today. For Nous
   Hermes: set `hermes_install_cmd`; confirm provider keys and the headless run
   flag (`run_hermes_task()` in `agent_server.py`); ensure Hermes can send the
   custom `X-Allocation` header (else front it with a header-injecting proxy).

## Notes

- Worker port is **pinned** (`agent_port`, default 8717); discovery also reads each
  worker's actual `remotePort`, so the orchestrator doesn't have to assume it.
- Workers must run with `scheduler:false` (login node) for transport + brain access.
- Code is delivered via `parallelworks/checkout`. The dev branch was merged to
  `main` — set the checkout `branch:` to `main` in both YAMLs.
- Clean up when done: `pw workflows runs cancel <slug>` (runs `cancel.sh`).
```
