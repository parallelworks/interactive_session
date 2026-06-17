# LibreChat + Langflow Proxy (hsp-all.yaml)

`hsp-all.yaml` launches **LibreChat**, the **Manager** dashboard, and **Langflow** as one
workflow, and adds an optional **Langflow proxy** that turns each Langflow flow into a
model you can pick and chat with inside LibreChat.

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
               │     ├─ LANGFLOW_LOAD_FLOWS_PATH=<proxy_dir>/flows  → flows imported
               │     │     (owned by the Langflow superuser, so they're discoverable)
               │     ├─ proxy_port=$(pw agent open-port)
               │     └─ echo $proxy_port > $PW_PARENT_JOB_DIR/LANGFLOW_PROXY_PORT
               ▼
librechat job ──┐  controller: read LANGFLOW_PROXY_PORT (bounded wait), then add to
                │  librechat.yaml:
                │     - name: "Langflow"
                │       baseURL: http://localhost:<proxy_port>/v1
                │       models: { fetch: true }      ← LibreChat lists every flow
                ▼
LibreChat fetches /v1/models from the proxy → each Langflow flow appears as a model.
```

The dynamic port is the only thing the two jobs need to agree on, so it's handed off
through a single file: **`${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT`**.

## Form inputs (Langflow Settings)

| Field | Default | Purpose |
|---|---|---|
| **Start Langflow Proxy?** (`enable_proxy`) | `true` (hidden) | Master switch. Not `true` → plain workflow, no proxy. |
| **Langflow Proxy Path** (`proxy_dir`) | — | Path to the `langflow_proxy` code (the dir holding the `langflow_proxy/` package). **Required to start the proxy.** Flows in `<proxy_dir>/flows/*.json` are auto-imported. |
| **Proxy Flow Configs File** (`proxy_flows_file`) | — | Optional YAML with a top-level `flows:` block for per-flow model routing. Falls back to `<proxy_dir>/flows.yaml`, else flows run with their own model settings. |

Optional auth: if **Langflow API Key** (`LANGFLOW_API_KEY`, in Environment Variables) is
set, the proxy requires it and the LibreChat endpoint sends it automatically.

## On / off

| `enable_proxy` | `proxy_dir` | Result |
|---|---|---|
| `true` (default) | set | **Proxy on** — flows imported, proxy launched, LibreChat "Langflow" endpoint added |
| `true` | empty | No proxy (no code to run) — plain LibreChat + Manager + Langflow |
| `false` / empty | any | **Original workflow**, no proxy artifacts |

Every proxy hook (venv, flow import, proxy launch, LibreChat endpoint) is guarded by the
switch, so any workflow that doesn't set it runs exactly as before.

## Assumptions & requirements

- **Same service host.** LibreChat reaches the proxy on `localhost`, so Langflow and
  LibreChat must share the node — use **Schedule Job? = No** (login node). Scheduling them
  to separate compute nodes breaks the `localhost` hop.
- **Discoverable flows.** The proxy lists flows that have a `ChatInput` node and an owner
  (`user_id`). Auto-imported flows are owned by the superuser, so they show up; the bundled
  Langflow starter templates (global, no owner) are intentionally hidden.
- **Singularity/Apptainer** on the node (same as the rest of the workflow).
- The proxy code lives at `proxy_dir` and is **not** shipped in this repo.

## Quick start

1. Resource + **Schedule Job? = No**.
2. **Langflow Settings → Langflow Proxy Path** = the proxy code dir on the cluster
   (e.g. `~/pw/langflow_proxy`). Put your flow JSONs in `<proxy_dir>/flows/`.
3. Launch. Open the **langflow** link to confirm your flow imported; open **librechat**,
   pick the **Langflow** endpoint, choose your flow, and chat.

To turn the integration off, leave **Langflow Proxy Path** empty — the workflow runs as
plain LibreChat + Manager + Langflow.
