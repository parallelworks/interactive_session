#!/usr/bin/env python3
"""Search HTTP API for the rag-service workflow — read-only.

Serves /search (dense cosine | BM25 fts | hybrid RRF), /health and /stats
over a LanceDB table that indexer.py (the sole writer) keeps up to date.
The table is re-opened per request so newly indexed data is visible without
a restart.

Behind `pw endpoints run` it binds 127.0.0.1:{port}; the platform endpoint
provides authentication and the public URL.
"""

import argparse
import json
import logging
import os
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import lancedb
from sentence_transformers import SentenceTransformer

from rag_common import embedding_prefixes, resolve_model_path

LOG = logging.getLogger("rag_server")
logging.basicConfig(
    level=os.environ.get("RAG_SERVER_LOGLEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(message)s",
)

RRF_K = 60
MAX_TOP_K = 100
MODES = ("hybrid", "dense", "fts")


def sql_quote(s):
    return "'" + s.replace("'", "''") + "'"


class TableUnavailable(Exception):
    pass


class Backend:
    def __init__(self, db_dir, table, embedding_model, docs_dir, default_top_k):
        self.db_dir = os.path.abspath(os.path.expanduser(db_dir))
        self.table_name = table
        self.docs_dir = docs_dir
        self.default_top_k = default_top_k
        self.embedding_model_id = embedding_model
        self.state_path = os.path.join(self.db_dir, f"{table}.state.json")
        self.db = lancedb.connect(self.db_dir)
        model_ref = resolve_model_path(embedding_model, os.environ.get("RAG_MODELS_DIR"))
        LOG.info("Loading embedding model %s (from %s)", embedding_model, model_ref)
        self.model = SentenceTransformer(
            model_ref, device=os.environ.get("EMBEDDING_DEVICE", "cpu")
        )
        self.query_prefix, _ = embedding_prefixes(embedding_model)
        if self.query_prefix:
            LOG.info("Query prefix for %s: %r", embedding_model, self.query_prefix)
        self._encode_lock = threading.Lock()

    def open_table(self):
        """Fresh handle per request: sees the indexer's latest commit."""
        try:
            return self.db.open_table(self.table_name)
        except Exception as e:
            raise TableUnavailable(str(e))

    def encode(self, text):
        # Query-side embedding: some model families expect a query prefix
        # (see rag_common.embedding_prefixes); FTS/BM25 uses the raw text.
        with self._encode_lock:
            return self.model.encode(self.query_prefix + text).tolist()

    def read_state(self):
        try:
            with open(self.state_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def corpus_stats(self, tbl=None):
        state = self.read_state()
        try:
            chunks = (tbl or self.open_table()).count_rows()
        except TableUnavailable:
            chunks = None
        return {"files_indexed": len(state.get("files", {})), "chunks": chunks}

    @staticmethod
    def _result(row, score, kind):
        return {
            "text": row["text"],
            "score": round(float(score), 6),
            "score_kind": kind,
            "file_path": row["file_path"],
            "title": row["title"],
            "chunk_index": row["chunk_index"],
            "span_start": row["span_start"],
            "span_end": row["span_end"],
            "doc_sha256": row["doc_sha256"],
        }

    def search(self, query, mode, top_k, where):
        tbl = self.open_table()
        if tbl.count_rows() == 0:
            return [], self.corpus_stats(tbl)

        fetch_k = min(max(top_k * 4, 20), 500)

        def dense_rows():
            q = tbl.search(self.encode(query)).metric("cosine").limit(fetch_k)
            if where:
                q = q.where(where, prefilter=True)
            return q.to_list()

        def fts_rows():
            q = tbl.search(query, query_type="fts").limit(fetch_k)
            if where:
                q = q.where(where, prefilter=True)
            return q.to_list()

        if mode == "dense":
            results = [
                self._result(r, 1.0 - r["_distance"], "cosine") for r in dense_rows()
            ]
        elif mode == "fts":
            results = [self._result(r, r["_score"], "bm25") for r in fts_rows()]
        else:  # hybrid: reciprocal-rank fusion of both rankings
            fused = {}
            for rows in (dense_rows(), fts_rows()):
                for rank, row in enumerate(rows):
                    key = (row["file_path"], row["chunk_index"])
                    entry = fused.setdefault(key, {"row": row, "rrf": 0.0})
                    entry["rrf"] += 1.0 / (RRF_K + rank + 1)
            ranked = sorted(fused.values(), key=lambda e: e["rrf"], reverse=True)
            results = [self._result(e["row"], e["rrf"], "rrf") for e in ranked]

        return results[:top_k], self.corpus_stats(tbl)


BACKEND = None


class Handler(BaseHTTPRequestHandler):
    server_version = "rag-service/1.0"

    def log_message(self, fmt, *args):
        LOG.info("%s %s", self.address_string(), fmt % args)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        route = parsed.path.rstrip("/") or "/"
        try:
            if route == "/":
                self._json(200, {
                    "service": "rag-service",
                    "endpoints": ["/search", "/health", "/stats"],
                })
            elif route == "/health":
                self.handle_health()
            elif route == "/stats":
                self.handle_stats()
            elif route == "/search":
                self.handle_search(params)
            else:
                self._json(404, {"error": f"no such route: {parsed.path}"})
        except TableUnavailable as e:
            self._json(503, {"error": f"table unavailable: {e}"})
        except BrokenPipeError:
            pass
        except Exception as e:
            LOG.exception("request failed: %s", self.path)
            self._json(500, {"error": f"{type(e).__name__}: {e}"})

    def handle_health(self):
        try:
            BACKEND.open_table().count_rows()
            table_ok = True
        except TableUnavailable:
            table_ok = False
        self._json(200, {
            "status": "ok" if table_ok else "degraded",
            "table_ok": table_ok,
            "docs_dir": BACKEND.docs_dir,
            "embedding_model": BACKEND.embedding_model_id,
        })

    def handle_stats(self):
        stats = BACKEND.corpus_stats()
        if stats["chunks"] is None:
            raise TableUnavailable("cannot open table " + BACKEND.table_name)
        self._json(200, {
            "files_indexed": stats["files_indexed"],
            "chunks": stats["chunks"],
            "table": BACKEND.table_name,
            "last_scan_utc": BACKEND.read_state().get("last_scan_utc"),
        })

    def handle_search(self, params):
        query = (params.get("query") or "").strip()
        if not query:
            return self._json(400, {"error": "missing required parameter: query"})

        mode = params.get("mode", "hybrid").lower()
        if mode not in MODES:
            return self._json(400, {"error": f"mode must be one of {list(MODES)}"})

        try:
            top_k = int(params.get("top_k", BACKEND.default_top_k))
        except ValueError:
            return self._json(400, {"error": "top_k must be an integer"})
        top_k = max(1, min(top_k, MAX_TOP_K))

        clauses = []
        if params.get("file_contains"):
            clauses.append(f"file_path LIKE {sql_quote('%' + params['file_contains'] + '%')}")
        if params.get("file_path_in"):
            paths = [p for p in params["file_path_in"].split(",") if p.strip()]
            if paths:
                clauses.append(
                    "file_path IN (" + ", ".join(sql_quote(p) for p in paths) + ")"
                )
        where = " AND ".join(clauses) or None

        results, corpus_stats = BACKEND.search(query, mode, top_k, where)
        self._json(200, {
            "query": query,
            "mode": mode,
            "top_k": top_k,
            "results": results,
            "corpus_stats": corpus_stats,
        })


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--docs-dir", default=os.environ.get("RAG_DOCS_DIR", ""))
    ap.add_argument("--db-dir", default=os.environ.get("RAG_DB_DIR", None))
    ap.add_argument("--table", default=os.environ.get("RAG_TABLE", "activate_rag"))
    ap.add_argument("--embedding-model",
                    default=os.environ.get("RAG_EMBEDDING_MODEL",
                                           "sentence-transformers/all-MiniLM-L6-v2"))
    ap.add_argument("--default-top-k", type=int,
                    default=int(os.environ.get("RAG_DEFAULT_TOP_K", "8")))
    args = ap.parse_args()

    if not args.db_dir:
        ap.error("--db-dir is required (or RAG_DB_DIR)")

    global BACKEND
    BACKEND = Backend(args.db_dir, args.table, args.embedding_model,
                      args.docs_dir, args.default_top_k)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    LOG.info("rag-service search API on %s:%d (table=%s, db=%s)",
             args.host, args.port, args.table, args.db_dir)
    server.serve_forever()


if __name__ == "__main__":
    main()
