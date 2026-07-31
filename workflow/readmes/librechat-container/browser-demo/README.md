# LibreChat + Manager + Langflow (All-in-One)

One workflow, three browser sessions: a full **LibreChat** AI chat, a **Manager**
dashboard to watch/restart services, and a **Langflow** visual flow builder — with
every Langflow flow available as a selectable model inside LibreChat, including a
ready-made **RAG pipeline** (embeddings server + vector database included).

📽️ **Demo slides**: [browser demo walkthrough](https://docs.google.com/presentation/d/1GuFDqojqDlqAz9TV3RBG5zsO_cDigw0e/edit?usp=sharing&ouid=109780783715781979532&rtpof=true&sd=true)

```
                     Activate platform — session links
  ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
  │  librechat   │        │   manager    │        │   langflow   │
  │   chat UI    │        │  dashboard   │        │    canvas    │
  └──────┬───────┘        └──────────────┘        └──────┬───────┘
         │ pick the "Langflow" endpoint → a flow          │ edit flows
         ▼                                                ▼
  ┌─────────────────────┐  OpenAI-compatible   ┌────────────────────────┐
  │   Langflow proxy    │ ───────────────────▶ │      Langflow flow     │
  │ (1 flow = 1 model)  │                      │   chatbot, rag_chatbot │
  └─────────────────────┘                      └───────────┬────────────┘
                                                           │
                        ┌──────────────────────────────────┼──────────────┐
                        ▼                                  ▼              ▼
              ┌──────────────────┐              ┌────────────────┐  ┌──────────┐
              │  LLM  ("brain")  │              │ HFTEI server   │  │ LanceDB  │
              │ platform models  │              │ MPNet-V2       │  │ /data    │
              │ …/api/openai/v1  │              │ embeddings     │  │ corpora  │
              └──────────────────┘              └────────────────┘  └──────────┘
                 set by "LLM Model"                └── the RAG pipeline ──┘
```

## The three sessions

| Session | Opens | What it is |
|---|---|---|
| 💬 **librechat** | ✓ (redirects) | The chat UI. Langflow flows show up here under the **Langflow** endpoint. |
| 🩺 **manager** | — | Live status + one-click restart for each LibreChat service. |
| 🧩 **langflow** | — | The visual builder — design and edit your flows. |

LibreChat itself runs five containers (MongoDB, MeiliSearch, PostgreSQL+pgvector,
RAG API, LibreChat) plus the GenAI MIL and ACTIVATE endpoints, pre-configured.

## 📦 Before you launch — what must already be on the cluster

Everything lives on the **Langflow host** unless noted. `<install dir>` is
`${PROJECTS_HOME}/hsp` on HSP systems (`~/pw` when `PROJECTS_HOME` is unset).

### You stage these ⚠️

| # | What | Where | Notes |
|---|---|---|---|
| 1 | **Langflow proxy code** | `<install dir>/tools/langflow_proxy-main/` (or set **Langflow Proxy Path**) | The dir containing the `langflow_proxy/` package. Not shipped in this repo. |
| 2 | **Flow definitions** | `<proxy dir>/flows/*.json` | `chatbot.json`, `rag_chatbot.json` — use the **fixed copies from `langflow-singularity/flows/`** (or set *Import bundled test flows?* to import them straight from the repo). |
| 3 | **Proxy flow configs** | `<proxy dir>/flows.yaml` (or set **Proxy Flow Configs File**) | Deployment routing: RAG corpus, TEI `retrieve` entry, per-model extras like `allocation:`. Example below. |
| 4 | **RAG vector database** | Any dir → set **RAG Database Directory** | LanceDB directory; each table is a corpus. Mounted at **`/data`** in the Langflow container. `data.lancedb.tgz` corresponds to the `policy-docs` corpus. |

### The workflow fetches these for you ✅

| What | From | Cached at |
|---|---|---|
| Langflow container (+ lancedb) | `ghcr.io/parallelworks/langflow:2.0` | `<install dir>/containers/langflow.sif` |
| HFTEI embeddings container | `ghcr.io/parallelworks/hftei:cpu-1.6.0` | `<install dir>/containers/hftei-cpu-1.6.0.sif` |
| LibreChat stack (5 containers) | `ghcr.io/parallelworks/librechat:v1.0` | `<install dir>/containers/librechat/` |
| MPNet-V2 embedding model | huggingface.co (only if the dir is missing) | **HFTEI Model Directory**, default `<install dir>/models/MPNet-V2` |

### Generated at runtime 🔄 (never stage these)

`proxy-config.yaml` (job dir — live-editable, re-read on every request),
`librechat.yaml` + `.env` (LibreChat dir), `~/.secrets/OPENAI_COMPATIBLE_API_API_KEY`
(platform key for the flows), and the Langflow database.

### Directory layout at a glance

```
<install dir>/                          ← ${PROJECTS_HOME}/hsp on HSP systems
├── containers/                         ✅ auto-pulled SIFs
├── models/MPNet-V2/                    ✅ auto-downloaded embedding weights
└── tools/langflow_proxy-main/          ⚠️ you stage
    ├── langflow_proxy/                     the proxy package
    ├── flows/{chatbot,rag_chatbot}.json    the flow definitions (fixed copies!)
    └── flows.yaml                          RAG + model routing

<RAG Database Directory>/               ⚠️ you stage → mounted at /data
├── policy.lance/                           corpus "policy"
└── hpcmp.lance/                            corpus "hpcmp"

${HOME}/pw/
├── LibreChat/                          🔄 chat history, uploads, config
└── .langflow/langflow.db               🔄 imported flows (wipe when flows change!)
```

## 🧠 Which model do the flows use?

Set **Langflow Settings → LLM Model** to any id from
`https://<platform>/api/openai/v1/models` (e.g. `session:<user>:<session>//<model>`
for a model served by one of your sessions). The workflow validates it **up front**
— a wrong id fails the run in seconds and lists what is available. Leave it
**empty** to auto-pick the first connected model; if none are connected the run
fails immediately.

The chosen model + platform URL are injected into every LLM entry of `chatbot`
and `rag_chatbot` in the generated `proxy-config.yaml`. Everything else comes from
`flows.yaml`:

```yaml
flows:
  rag_chatbot:
    models:
      enhance:  { allocation: "allocation00" }   # extras survive the injection;
      respond:  { allocation: "allocation00" }   # org:* models need an allocation
      retrieve:                                  # embeddings — never overridden
        provider: "HuggingFace TEI"
        base_url: "http://localhost:${HFTEI_PORT}"   # substituted at launch
        model: "mpnet-v2"
    rag:
      user_query: { top_k: 10, corpus: "policy", db_type: "lancedb", db_path: "/data" }
      user_context: { top_k: 0 }
```

Add your own flows: drop JSONs in `<proxy dir>/flows/` — they're auto-imported and
appear as models automatically.

## 🚀 Getting started

1. Stage items **1–4** above on the Langflow host.
2. Pick the **LibreChat host** and the **Langflow host** (same or different — when
   they differ, the workflow bridges the proxy automatically with `pw forward`).
3. Set **RAG Database Directory** and (optionally) **LLM Model**; leave the rest on
   defaults. Launch — the first run pulls containers (a few minutes).
4. Open **librechat**, register a local account, pick the **Langflow** endpoint,
   choose `chatbot` or `rag_chatbot`, and chat. Use **manager** to watch/restart
   services and **langflow** to edit flows.

## 💡 Good to know

- **Wipe the Langflow database when flow JSONs change** (`rm -rf ~/pw/.langflow` by
  default) — imports overwrite flows by name, but stale session state from an old
  flow version can leave chats answering empty.
- **Live tuning**: edit `proxy-config.yaml` in the run's job dir
  (`~/pw/jobs/<workflow>/<run>/langflow/`) — models, corpus, top_k apply on the
  next message, no restart. Flow JSON changes do need a rerun.
- **Singularity/Apptainer** must be available on each node (auto-loaded via
  `module` if needed). No Docker or root required.
- **API keys**: the platform endpoint uses your run's key automatically; add
  `GENAI_MIL_API_KEY` (or others) under **Environment Variables** only for those
  providers.
- **Persistence**: chat history, uploads and flows live under your home directory
  and survive restarts; the shared `<install dir>` caches are reused across users.
- **Scheduler**: SLURM and PBS are supported; if you schedule to compute nodes,
  LibreChat and the Manager must still land on the same node.
