# RAG Service

A standalone retrieval service for agents. It watches a directory of documents
on the cluster, indexes them into an embedded [LanceDB](https://lancedb.com)
dataset (dense vectors + BM25 full-text), and exposes a search HTTP API through
a platform endpoint. It serves retrieval only:
no LLM, no chat proxy, no OpenAI-compatible surface.

Two processes run on one node, launched by the start script:

- **indexer.py** — the sole writer. Polling file watcher (NFS-safe) plus a
  periodic full rescan; chunks (fixed windows with character spans) and embeds
  with sentence-transformers on CPU; per-file delete+re-add on change; persists
  a path→sha256 state file next to the dataset so indexer restarts re-embed
  nothing unchanged, and files deleted while it was down are reconciled at
  startup. Refuses to write into a table whose vector dimension doesn't match
  the selected model.
- **rag_server.py** — read-only search API wrapped by `pw endpoints run`.
  Re-opens the table per request, so new data is searchable without a restart.

## Form inputs (group `service`)

| Input | Default | Meaning |
|---|---|---|
| `docs_dir` | *(required)* | Directory of documents to index and watch (shared filesystem). `.pdf`, `.md`, `.txt`, `.csv`, `.log`. |
| `embedding_model_id` | `BAAI/bge-small-en-v1.5` | Dropdown of curated models (below); downloaded on the login node into `<parent_install_dir>/models`, cached for offline compute nodes. |
| `chunk_chars` | `700` | Chunk window size in characters. |
| `chunk_overlap` | `80` | Chunk overlap in characters. |
| `default_top_k` | `8` | `/search` result count when `top_k` is not given. |
| `table_name` | `activate_rag` | LanceDB table; use different tables for different corpora. |
| `parent_install_dir` | *(empty)* | Root for the dependency container and model cache; falls back to `${HOME}/pw/software` when left empty. |

The LanceDB dataset itself (vectors + FTS index + state file) lives under the
**run's job directory**, so each run
indexes its corpus fresh and two runs never share a table.

### Embedding model options

| Option | Model | Dim | Size | Prefix convention |
|---|---|---|---|---|
| Fast | `sentence-transformers/all-MiniLM-L6-v2` | 384 | ~80MB | none |
| Balanced *(default)* | `BAAI/bge-small-en-v1.5` | 384 | ~130MB | instruction prefix on queries only |
| Higher quality | `BAAI/bge-base-en-v1.5` | 768 | ~440MB | instruction prefix on queries only; 2x vector storage, ~3x compute |
| Multilingual | `intfloat/multilingual-e5-small` | 384 | ~470MB | `query: ` / `passage: ` on both sides |

Models are saved as plain directories, `<parent_install_dir>/models/<org>/<name>`
(no hub-cache `models--` naming), and the service loads that local copy
offline. All are ungated Apache-2.0/MIT Hugging Face repos (no auth token
needed). The
query/passage prefixes are applied automatically per model family
(`rag_common.embedding_prefixes`) — only to the text fed to the encoder;
stored chunk text, spans, and BM25 search always use the original text. All
four options pass `smoke_search.sh` (validated per option, not assumed).

`scheduler: true` is supported: the controller pre-downloads the embedding
model into `SENTENCE_TRANSFORMERS_HOME` on the shared filesystem, and the
start script forces offline mode (`HF_HUB_OFFLINE=1`), so compute nodes need
no internet (beyond platform reachability for `pw endpoints run`).

## Runtime environment (Singularity SIF)

Python dependencies ship as a Singularity container,
`ghcr.io/parallelworks/rag-service:1.0` (built from `rag-service.def` +
`requirements.txt` by `build-container.sh`; ~450 MB, CPU-only torch). The
controller pulls the SIF once via ORAS into
`<parent_install_dir>/containers/rag-service.sif`; the start template probes
whether the node can mount SIFs and falls back to unpacking a sandbox
directory (offline-safe) if not. The service code itself is not baked into
the container — it comes from the workflow checkout, so code changes never
require a container rebuild. To change pinned dependencies: edit
`requirements.txt`, run `./build-container.sh`, push a **new tag**, and bump
`CONTAINER_TAG` in `controller-v4.sh`.

## Search API

`GET /search?query=<text>&top_k=<int>&mode=hybrid|dense|fts&file_contains=<substr>&file_path_in=<csv>`

- `mode=dense` — cosine similarity; `score = 1 − cosine_distance` in `[0, 1]`,
  `score_kind: "cosine"`.
- `mode=fts` — BM25 over chunk text; `score_kind: "bm25"`.
- `mode=hybrid` (default) — reciprocal-rank fusion (k=60) of the dense and BM25
  rankings; `score_kind: "rrf"`.
- `file_contains` — substring match on `file_path` (SQL LIKE semantics: `%`/`_`
  act as wildcards). `file_path_in` — comma-separated exact paths.

```json
{
  "query": "expected improvement acquisition function",
  "mode": "hybrid",
  "top_k": 8,
  "results": [
    {
      "text": "…chunk text…",
      "score": 0.0321,
      "score_kind": "rrf",
      "file_path": "/home/user/corpus/1807.02811-a-tutorial-on-bayesian-optimization.pdf",
      "title": "1807.02811-a-tutorial-on-bayesian-optimization.pdf",
      "chunk_index": 12,
      "span_start": 8400,
      "span_end": 9100,
      "doc_sha256": "…"
    }
  ],
  "corpus_stats": {"files_indexed": 19, "chunks": 2130}
}
```

No hits → `200` with `results: []`. Missing `query` or bad `mode`/`top_k` →
`400`. Table not openable → `503` with a JSON error (never a silent empty 200).

Operational endpoints:

- `GET /health` → `{status, table_ok, docs_dir, embedding_model}`
- `GET /stats` → `{files_indexed, chunks, table, last_scan_utc}`

### Example curls

Endpoints are platform-authenticated; anonymous requests get a 307 to the
login page. A platform token (`PW_API_KEY` inside a workflow, or the `token`
from `~/.config/pw/credentials`) passed as a Bearer header authenticates
(verified live):

```bash
AUTH="Authorization: Bearer ${PW_API_KEY}"
BASE=https://<subdomain>.activate.pw    # from `pw endpoints list`

curl -H "$AUTH" "$BASE/health"
curl -H "$AUTH" "$BASE/stats"
curl -H "$AUTH" --get "$BASE/search" \
  --data-urlencode "query=expected improvement acquisition function" \
  --data-urlencode "mode=hybrid" --data-urlencode "top_k=5"
curl -H "$AUTH" --get "$BASE/search" \
  --data-urlencode "query=scratch quota" \
  --data-urlencode "file_contains=runbook" --data-urlencode "mode=fts"
```

On the service node itself, `curl localhost:<port>/...` works with no auth
(the server binds 127.0.0.1; the platform endpoint provides the public URL and
authentication).

## Test corpus

`rag-service/fetch_corpus.py --out <dir> [--max 15]` (stdlib only) downloads
open-access optimization-methods papers from arXiv (rate-limited, one PDF at a
time) and writes `manifest.json`. `rag-service/fixtures/*.md` are four small
documents with invented facts for deterministic assertions. With both in the
docs dir, `rag-service/smoke_search.sh <base-url>` asserts ranking, score
contract, filters, and error handling across all three modes (set
`RAG_SMOKE_AUTH_HEADER` when pointing it at the public endpoint URL).

## Lifecycle

The workflow run completes once the endpoint registers; the service lives on.
Tear it down with `pw endpoints delete rag-service-<run-slug>` (also kills the
background indexer via the cleanup trap and `cancel.sh`).
