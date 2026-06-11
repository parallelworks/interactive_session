# Hermes multi-agent (orchestrator + per-cluster workers)

A **Hermes orchestrator on the platform** that coordinates **one Hermes worker
agent per cluster**. Built on the same `session_runner` pattern as every other
session in this repo.

## Architecture

```
                 platform workspace
              ┌───────────────────────┐
              │  hermes-orchestrator   │   orchestrator.py  (a session)
              │  (Hermes coordinator)  │
              └─────────┬──────────────┘
        pw ssh <cluster> curl localhost:<agent_port>/task
          ┌─────────────┼───────────────┐
          ▼             ▼                ▼
   ┌────────────┐ ┌────────────┐  ┌────────────┐
   │ gcpsmall   │ │ a30gpu...  │  │  cluster N │   agent_server.py (a session each)
   │ hermes     │ │ hermes     │  │  hermes    │
   │ worker     │ │ worker     │  │  worker    │
   └────────────┘ └────────────┘  └────────────┘
        each worker's brain → platform OpenAI-compatible endpoint
```

- **Brain**: every agent calls the platform's OpenAI-compatible endpoint,
  always `https://${PW_PLATFORM_HOST}/api/openai/v1`, authenticated with the
  **runtime `PW_API_KEY`** (never written to disk). Org-provider models
  (`org:*`, e.g. GLM) also require the `X-Allocation` header, sent per request.
- **Transport (the part Hermes doesn't do across clusters)**: the orchestrator
  reaches each worker with `pw ssh <cluster> curl localhost:<agent_port>`.
  Hub-and-spoke: **no inbound ports**, reuses pw auth, works for any cluster.
- **Why workers run on the login node** (`scheduler:false`): that's where the
  internet (for the brain) and `pw ssh ... localhost` both reach them.

## Files

| File | Role |
|------|------|
| `hermes-agent/agent_server.py` | worker HTTP front-end (`/health`, `/task`) — stdlib |
| `hermes-agent/orchestrator.py` | orchestrator HTTP control + `pw ssh` dispatch — stdlib |
| `hermes-agent/controller-v3.sh` | install Hermes + configure the brain (idempotent) |
| `hermes-agent/start-template-v3.sh` | start the right role on `${service_port}` |
| `workflow/yamls/hermes-worker/general_v4.yaml` | start one worker (run per cluster) |
| `workflow/yamls/hermes-orchestrator/general_v4.yaml` | start the orchestrator (roster of workers) |

## Setup (once)

No org secret needed — auth is the runtime `PW_API_KEY`. Just confirm the
defaults match your platform:
1. A tool-calling-capable model id: `pw ai models ls` (default `org:glm/glm-5.1`).
2. The allocation to bill: `GET /api/allocations` (default `Private LLM Group`).

## Run

```bash
# 1) a worker on each cluster (login node)
pw workflows create hermes-worker --yaml workflow/yamls/hermes-worker/general_v4.yaml
pw workflows run hermes-worker -i '{"cluster":{"resource":"gcpsmall","scheduler":false}}'      --name w-gcpsmall
pw workflows run hermes-worker -i '{"cluster":{"resource":"a30gpuserver","scheduler":false}}'  --name w-a30

# 2) the orchestrator on the workspace, given the worker cluster names
pw workflows create hermes-orchestrator --yaml workflow/yamls/hermes-orchestrator/general_v4.yaml
pw workflows run hermes-orchestrator -i '{
  "cluster":{"resource":"workspace","scheduler":false},
  "workers":[{"name":"gcpsmall"},{"name":"a30gpuserver"}],
  "service":{"agent_port":8717}
}' --name orchestrator
```

Then drive the orchestrator from its session (or curl it):
`POST /run {"goal":"..."}` → it delegates to each worker and aggregates.

## ⚠️ Confirm against the Hermes docs (the only non-platform unknowns)

The platform plumbing is complete and tested. Three Hermes-specific bits are
marked `CONFIRM`/`TODO` in the code — until set, the agent runs in **stub mode**
(echoes tasks) so the wiring is demonstrable:

1. **Install** — set the `hermes_install_cmd` input to the official installer
   (`controller-v3.sh`).
2. **Brain config keys** — `~/.hermes/.env` uses `OPENAI_BASE_URL` /
   `OPENAI_API_KEY`; verify against
   <https://hermes-agent.nousresearch.com/docs/integrations/providers>.
3. **Headless task run** — `run_hermes_task()` in `agent_server.py` shells to
   `hermes`; confirm the single-shot flag (or set `$HERMES_TASK_CMD`). For true
   Hermes-to-Hermes coordination, wire `run_goal()` in `orchestrator.py` to a
   Hermes coordinator whose delegate tool calls `delegate(cluster, task)`
   (<https://hermes-agent.ai/features/multi-agent>).

## Notes

- Worker port is **pinned** (`agent_port`, default 8717) so the orchestrator
  roster is just a list of cluster names. Keep the two values in sync.
- Workers must run with `scheduler:false` (login node) for the transport to reach
  them and for brain internet access.
- Clean up when done: `pw workflows runs cancel <slug>` (runs `cancel.sh`).
