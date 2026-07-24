# LibreChat + Manager + Langflow (All-in-One)

One workflow, three browser sessions: a full **LibreChat** AI chat, a **Manager**
dashboard to watch/restart services, and a **Langflow** visual flow builder — with
every Langflow flow available as a selectable model inside LibreChat.

```
                      Activate platform — session links
   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
   │  librechat   │        │   manager    │        │   langflow   │
   │  chat UI     │        │  dashboard   │        │   canvas     │
   └──────┬───────┘        └──────────────┘        └──────┬───────┘
          │  pick the "Langflow" endpoint → a flow,        │
          │  send a message                                │
          ▼                                                 ▼
   ┌─────────────────────┐   OpenAI-compatible      ┌──────────────────┐
   │   Langflow proxy    │ ───────────────────────▶ │  Langflow flow   │
   │ (1 flow = 1 model)  │   forwards the turn      │  → LLM "brain"   │
   └─────────────────────┘                          └──────────────────┘
```

## The three sessions

| Session | Opens | What it is |
|---|---|---|
| **librechat** | ✓ (redirects) | The chat UI. Langflow flows show up here under the **Langflow** endpoint. |
| **manager** | — | Live status + one-click restart for each LibreChat service. |
| **langflow** | — | The visual builder — design and edit your flows. |

LibreChat itself runs five containers (MongoDB, MeiliSearch, PostgreSQL+pgvector,
RAG API, LibreChat) plus the GenAI MIL and ACTIVATE endpoints, pre-configured.

## Pick where each service runs

The launch form has a **resource + cluster section per service**:

| Service | Resource input | Notes |
|---|---|---|
| **LibreChat + Manager** | `LibreChat host` | Always run **together** — the Manager reads LibreChat's `service.env`, PIDs and logs from the local disk. |
| **Langflow** | `Langflow host` | Same machine **or a different one** — your choice. |

When Langflow runs on a **different** resource, the workflow bridges the proxy
automatically (`pw ssh` to read its port, `pw forward` to expose it on LibreChat's
`localhost`) — so chatting a Langflow flow from LibreChat just works either way.

Both default to **Schedule Job? = No** (login node), the recommended setting.

## Langflow flows as chat models

Each flow with a chat input becomes one model under LibreChat's **Langflow** endpoint.
Two flows ship ready to import:

| Flow | Model brain | Use it for |
|---|---|---|
| **chatbot** | Configurable (GenAI.mil, vLLM, or the ACTIVATE platform's `…/api/openai/v1`) | Plain chat through a single model. |
| **rag_chatbot** | Same, plus an **HFTEI** embeddings server and a **LanceDB** vector database | Retrieval-augmented chat: enhances the query, retrieves from the corpus in **RAG Database Directory** (mounted at `/data`), and answers from the retrieved context. |

Route each flow's models (and the RAG corpus) with a **Proxy Flow Configs File**; a
`base_url` may reference the HFTEI server started by this workflow as
`http://localhost:${HFTEI_PORT}`. Platform `org:*` models get their `X-Allocation`
header from the discovered allocation, or set `allocation:` per model config.

Add your own: drop flow JSONs in `<Langflow Proxy Path>/flows/` — they're auto-imported
and appear as models automatically.

## Getting started

1. Pick the **LibreChat host** and the **Langflow host** (same or different).
2. Set **Langflow Settings → Langflow Proxy Path** to the `langflow_proxy` code dir on
   the cluster.
3. Launch. First run downloads the container images (a few minutes).
4. Open **librechat**, register a local account, pick the **Langflow** endpoint, choose a
   flow (e.g. `chatbot` or `rag_chatbot`), and chat. Use **manager** to watch/restart
   services and **langflow** to edit flows.

## Good to know

- **Singularity/Apptainer** must be available on each node (auto-loaded via `module` if
  needed). No Docker or root required.
- **API key**: the ACTIVATE endpoint uses your platform key automatically; add
  `GENAI_MIL_API_KEY` (or others) under **Environment Variables** only for those providers.
- **Persistence**: chat history, uploads, the database and Langflow flows live under your
  home directory and survive restarts. Point a new deployment at the same paths to share them.
- **Scheduler**: SLURM and PBS are supported; if you schedule to compute nodes, LibreChat and
  the Manager must still land on the same node.
