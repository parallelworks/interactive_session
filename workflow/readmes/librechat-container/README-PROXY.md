# LibreChat + Langflow Proxy

This workflow launches **LibreChat**, the **Manager** dashboard, and **Langflow** together,
with a **Langflow proxy** that turns each Langflow flow into a model you can pick and chat
with inside LibreChat.

> For the LibreChat + Manager basics see [README-ALL.md](README-ALL.md); for Langflow itself
> see [langflow-singularity/README.md](../langflow-singularity/README.md). This file covers
> only the **proxy** that wires the two together.

## Big picture

```
                         Activate platform — session tunnels
        ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
        │  librechat   │        │   manager    │        │   langflow   │
        │   chat UI    │        │  dashboard   │        │    canvas    │
        └──────┬───────┘        └──────────────┘        └──────────────┘
               │
   pick the "Langflow" endpoint → a flow-model, then send a message
   POST  http://localhost:<proxy_port>/v1/chat/completions
               │
               ▼
        ┌─────────────────────────────┐    reads     ┌──────────────────┐
        │        langflow_proxy        │ ───────────▶ │   langflow.db    │
        │  OpenAI-compatible API        │  1 flow =    │  (flow catalog)  │
        │  co-located with Langflow     │  1 model     └──────────────────┘
        └──────────────┬───────────────┘
                       │  forwards the turn to Langflow's run API
                       ▼
        ┌─────────────────────────────┐   the flow's Language Model node
        │   Langflow flow (run API)    │ ─────────────────▶  LLM "brain"
        └─────────────────────────────┘     (GenAI.MIL / platform / vLLM …)
```

The proxy is a small FastAPI server (OpenAI-compatible). It **runs inside the
`langflow` job** (co-located with Langflow), and LibreChat reaches it over `localhost`.

## Three sessions

| Session | Redirect | What it is |
|---|---|---|
| **librechat** | ✓ opens it | The chat UI — the proxy shows up here as the **Langflow** endpoint |
| **manager** | — | Service status / restart dashboard |
| **langflow** | — | The visual flow builder (design & edit flows) |

## How the proxy gets wired (at launch)

```
langflow job ──┐  controller: build proxy venv (fastapi/uvicorn/…)
               │  start: import flows  +  launch proxy  +  publish port
               │     ├─ LANGFLOW_LOAD_FLOWS_PATH=<merged flows>  → flows imported
               │     │     (owned by the Langflow superuser, so they're discoverable)
               │     ├─ proxy_port=$(pw agent open-port)
               │     └─ echo $proxy_port > $PW_PARENT_JOB_DIR/LANGFLOW_PROXY_PORT
               ▼
librechat job ──┐  controller: obtain LANGFLOW_PROXY_PORT (bounded wait), then add to
                │  librechat.yaml:
                │     - name: "Langflow"
                │       baseURL: http://localhost:<proxy_port>/v1
                │       models: { fetch: true }      ← LibreChat lists every flow
                │  start: if Langflow is on another resource, pw-forward the port
                ▼
LibreChat fetches /v1/models from the proxy → each Langflow flow appears as a model.
```

The dynamic port is the only thing the two jobs need to agree on. How it crosses
from the Langflow host to the LibreChat host depends on whether they share a machine:

- **Same resource** (LibreChat host == Langflow host): the file
  `${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT` is on the shared filesystem, and the proxy
  is already on `localhost` — nothing extra to do.
- **Different resources** (the compute-targets layout below): the LibreChat **controller**
  reads the port from the Langflow host with `pw ssh <langflow_resource> cat …/LANGFLOW_PROXY_PORT`
  (the parent-job-dir path is identical on both hosts) and mirrors it locally; the LibreChat
  **start script** then runs `pw forward -L <port>:localhost:<port> <langflow_resource>` so the
  proxy is reachable at this node's `localhost:<port>` — keeping the `http://localhost:<port>/v1`
  endpoint valid. The LibreChat container shares the host network namespace, so it reaches the
  forwarded listener.

## Form inputs (Langflow Settings)

| Field | Purpose |
|---|---|
| **Langflow Proxy Path** (`proxy_dir`) | Path to the `langflow_proxy` code (the dir holding the `langflow_proxy/` package). Flows in `<proxy_dir>/flows/*.json` are auto-imported into Langflow, **merged with the flows shipped in `langflow-singularity/flows/`** (`chatbot` and `pw-test-one`). |
| **Proxy Flow Configs File** (`proxy_flows_file`) | Optional YAML with a top-level `flows:` block for per-flow model routing. Falls back to `<proxy_dir>/flows.yaml`, else flows run with their own model settings. |

### Bundled flows

Two flows ship under `langflow-singularity/flows/` and are imported automatically:

- **`chatbot`** — the original flow (GenAI.mil Language Model). Requires a reachable
  GenAI.mil endpoint.
- **`pw-test-one`** — a self-contained ACTIVATE test flow. Its Language Model node targets
  the platform OpenAI endpoint (`https://${PW_PLATFORM_HOST}/api/openai/v1`), authenticates
  with the runtime `PW_API_KEY`, and auto-adds the `X-Allocation` header that platform
  `org:*` models require (discovered from `/api/allocations`, preferring an LLM allocation;
  override with `PW_ALLOCATION` / `PW_TEST_MODEL`). Use it to verify the full chain without
  external provider access.

Optional auth: if **Langflow API Key** (`LANGFLOW_API_KEY`, in Environment Variables) is
set, the proxy requires it and the LibreChat endpoint sends it automatically.

## Compute targets

Each service picks its own resource and cluster settings in the launch form:

- **LibreChat host** (`librechat_resource`) — also runs the **Manager**. LibreChat and the
  Manager **must share this resource**: the Manager reads LibreChat's `service.env`, PID and
  log files straight off the local filesystem.
- **Langflow host** (`langflow_resource`) — may be the **same** resource or a **different**
  one. When different, the proxy port is bridged automatically via `pw ssh` + `pw forward`
  (see *How the proxy gets wired*), so the `localhost` endpoint in `librechat.yaml` keeps working.

## Assumptions & requirements

- **LibreChat ↔ proxy reachability is handled for you.** Same resource → `localhost`
  directly; different resource → `pw forward` bridges it. Both are exercised by the workflow.
- **Discoverable flows.** The proxy lists flows that have a `ChatInput` node and an owner
  (`user_id`). Auto-imported flows are owned by the superuser, so they show up; the bundled
  Langflow starter templates (global, no owner) are intentionally hidden.
- **Singularity/Apptainer** on the node (same as the rest of the workflow).
- The proxy code lives at `proxy_dir` and is **not** shipped in this repo (only the two
  example flows under `langflow-singularity/flows/` are).

## Quick start

1. Resource + **Schedule Job? = No**.
2. **Langflow Settings → Langflow Proxy Path** = the proxy code dir on the cluster
   (e.g. `~/pw/langflow_proxy`). Put your flow JSONs in `<proxy_dir>/flows/`.
3. Launch. Open the **langflow** link to confirm your flow imported; open **librechat**,
   pick the **Langflow** endpoint, choose your flow, and chat.
