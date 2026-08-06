#!/usr/bin/env python3
"""Document indexer for the rag-service workflow — the SOLE WRITER of the
LanceDB table.

Watches a docs directory (polling observer — reliable on NFS), chunks and
embeds new/changed files with sentence-transformers, and keeps a LanceDB
table in sync: per-file delete+re-add on change, row deletion when a file
vanishes, periodic full rescans as a safety net.

Index state (path -> sha256/mtime/size) is persisted to a JSON file next to
the dataset so a restart re-embeds nothing that has not changed, and files
deleted while the indexer was down are reconciled away at startup.

Ported from activate-rag-vllm's indexer.py; the Chroma HTTP client and the
SQLite FTS side-index are replaced by embedded LanceDB with a native BM25
FTS index on the chunk text.
"""

import argparse
import fnmatch
import hashlib
import json
import logging
import os
import queue
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import lancedb
import pyarrow as pa
from pypdf import PdfReader
from sentence_transformers import SentenceTransformer
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
from watchdog.observers.polling import PollingObserver

from rag_common import embedding_prefixes, resolve_model_path

LOG = logging.getLogger("indexer")
logging.basicConfig(
    level=os.environ.get("INDEXER_LOGLEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(message)s",
)

INCLUDE_EXT = (".txt", ".md", ".log", ".pdf", ".csv")
EXCLUDE_GLOBS = (".*", "*.part", "*.tmp", "*.swp")
SCAN_LIMIT = 1_000_000


def sha256_file(path, bufsize=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(bufsize), b""):
            h.update(block)
    return h.hexdigest()


def load_text(path):
    p = path.lower()
    if p.endswith((".txt", ".md", ".log")):
        with open(path, "r", errors="ignore") as f:
            return f.read()
    if p.endswith(".pdf"):
        text = []
        try:
            r = PdfReader(path)
            for pg in r.pages:
                t = pg.extract_text() or ""
                if t:
                    text.append(t)
        except Exception as e:
            LOG.warning("PDF read failed %s: %s", path, e)
        return "\n".join(text)
    if p.endswith(".csv"):
        import csv

        rows = []
        with open(path, newline="", errors="ignore") as f:
            for row in csv.reader(f):
                rows.append(" ".join(row))
        return "\n".join(rows)
    return ""


def chunk_text_with_spans(text, size, overlap):
    """Fixed windows with character spans so results can cite exact ranges."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        j = min(i + size, n)
        out.append((text[i:j], (i, j)))
        if j >= n:
            break
        i = max(0, j - overlap)
    return out


def sql_quote(s):
    return "'" + s.replace("'", "''") + "'"


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Indexer:
    def __init__(self, args):
        self.docs_dir = os.path.abspath(os.path.expanduser(args.docs_dir))
        self.chunk_chars = args.chunk_chars
        self.chunk_overlap = args.chunk_overlap
        self.stabilize_seconds = args.stabilize_seconds
        self.table_name = args.table

        db_dir = os.path.abspath(os.path.expanduser(args.db_dir))
        os.makedirs(db_dir, exist_ok=True)
        self.db = lancedb.connect(db_dir)
        self.state_path = os.path.join(db_dir, f"{self.table_name}.state.json")

        model_ref = resolve_model_path(args.embedding_model, os.environ.get("RAG_MODELS_DIR"))
        LOG.info("Loading embedding model %s (from %s)", args.embedding_model, model_ref)
        self.model = SentenceTransformer(
            model_ref, device=os.environ.get("EMBEDDING_DEVICE", "cpu")
        )
        _, self.passage_prefix = embedding_prefixes(args.embedding_model)
        if self.passage_prefix:
            LOG.info("Passage prefix for %s: %r", args.embedding_model, self.passage_prefix)
        dim = self.model.get_sentence_embedding_dimension()

        schema = pa.schema(
            [
                pa.field("vector", pa.list_(pa.float32(), dim)),
                pa.field("text", pa.string()),
                pa.field("file_path", pa.string()),
                pa.field("title", pa.string()),
                pa.field("chunk_index", pa.int32()),
                pa.field("span_start", pa.int64()),
                pa.field("span_end", pa.int64()),
                pa.field("doc_sha256", pa.string()),
            ]
        )
        if self.table_name in self.db.table_names():
            self.tbl = self.db.open_table(self.table_name)
            existing_dim = self.tbl.schema.field("vector").type.list_size
            if existing_dim != dim:
                LOG.error(
                    "Table %s has %d-dim vectors but model %s emits %d dims; "
                    "use a different table_name or db dir",
                    self.table_name, existing_dim, args.embedding_model, dim,
                )
                raise SystemExit(1)
        else:
            self.tbl = self.db.create_table(self.table_name, schema=schema)
            LOG.info("Created table %s in %s", self.table_name, db_dir)

        self.state = {"files": {}, "last_scan_utc": None}
        if os.path.exists(self.state_path):
            try:
                with open(self.state_path) as f:
                    self.state = json.load(f)
                self.state.setdefault("files", {})
            except (ValueError, OSError) as e:
                LOG.warning("State file unreadable (%s); starting fresh", e)

        self.queue = queue.Queue()
        self.fts_dirty = False

    # -- state persistence -------------------------------------------------

    def save_state(self):
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=1)
        os.replace(tmp, self.state_path)

    # -- selection ---------------------------------------------------------

    def should_index(self, path):
        p = Path(path)
        name = p.name
        if any(fnmatch.fnmatch(name, g) for g in EXCLUDE_GLOBS):
            return False
        if not name.lower().endswith(INCLUDE_EXT):
            return False
        return p.is_file()

    def stable(self, path):
        try:
            return (time.time() - os.stat(path).st_mtime) >= self.stabilize_seconds
        except OSError:
            return False

    # -- table operations (worker thread only) ------------------------------

    def table_file_paths(self):
        if self.tbl.count_rows() == 0:
            return set()
        rows = self.tbl.search().select(["file_path"]).limit(SCAN_LIMIT).to_list()
        return {r["file_path"] for r in rows}

    def upsert_file(self, path):
        if not self.should_index(path):
            return
        if not self.stable(path):
            LOG.debug("Deferring (not stable yet): %s", path)
            return
        try:
            st = os.stat(path)
        except OSError:
            return

        prev = self.state["files"].get(path)
        if prev and prev.get("mtime") == st.st_mtime and prev.get("size") == st.st_size:
            LOG.debug("[SKIP-UNCHANGED] %s (mtime/size match)", path)
            return
        file_hash = sha256_file(path)
        if prev and prev.get("sha256") == file_hash:
            LOG.info("[SKIP-UNCHANGED] %s (sha256 match)", path)
            prev["mtime"] = st.st_mtime
            prev["size"] = st.st_size
            self.save_state()
            return

        text = load_text(path)
        if not text.strip():
            self.tbl.delete(f"file_path = {sql_quote(path)}")
            self.state["files"].pop(path, None)
            self.save_state()
            LOG.info("[DELETE-EMPTY] %s", path)
            return

        chunks_spans = chunk_text_with_spans(text, self.chunk_chars, self.chunk_overlap)
        chunks = [c for c, _ in chunks_spans]
        spans = [s for _, s in chunks_spans]
        LOG.info("[EMBED] %s -> %d chunks", path, len(chunks))
        # Prefix only the encoder input; stored text and spans stay original
        vecs = self.model.encode(
            [self.passage_prefix + c for c in chunks], show_progress_bar=False
        )

        title = os.path.basename(path)
        rows = [
            {
                "vector": vecs[i].tolist(),
                "text": chunks[i],
                "file_path": path,
                "title": title,
                "chunk_index": i,
                "span_start": spans[i][0],
                "span_end": spans[i][1],
                "doc_sha256": file_hash,
            }
            for i in range(len(chunks))
        ]
        self.tbl.delete(f"file_path = {sql_quote(path)}")
        self.tbl.add(rows)
        self.fts_dirty = True

        self.state["files"][path] = {
            "sha256": file_hash,
            "mtime": st.st_mtime,
            "size": st.st_size,
            "chunks": len(chunks),
        }
        self.save_state()
        LOG.info("[UPSERT] %s -> %d chunks", path, len(chunks))

    def delete_file(self, path):
        self.tbl.delete(f"file_path = {sql_quote(path)}")
        if self.state["files"].pop(path, None) is not None:
            self.save_state()
        self.fts_dirty = True
        LOG.info("[DELETE] %s", path)

    def rebuild_fts(self):
        if self.tbl.count_rows() == 0:
            return
        t0 = time.time()
        self.tbl.create_fts_index("text", use_tantivy=False, replace=True)
        LOG.info("[FTS] index rebuilt in %.1fs", time.time() - t0)

    # -- worker ------------------------------------------------------------

    def worker(self):
        while True:
            try:
                kind, payload = self.queue.get(timeout=2)
            except queue.Empty:
                if self.fts_dirty:
                    try:
                        self.rebuild_fts()
                    except Exception:
                        LOG.exception("[FTS] rebuild failed")
                    self.fts_dirty = False
                continue
            try:
                if kind == "upsert":
                    self.upsert_file(payload)
                elif kind == "delete":
                    self.delete_file(payload)
                elif kind == "scan_done":
                    self.state["last_scan_utc"] = payload
                    self.save_state()
            except Exception:
                LOG.exception("Failed processing %s %s", kind, payload)

    # -- scanning ----------------------------------------------------------

    def walk_docs(self):
        found = set()
        for dirpath, _, files in os.walk(self.docs_dir):
            for name in files:
                p = os.path.join(dirpath, name)
                if self.should_index(p):
                    found.add(p)
        return found

    def reconcile(self):
        """Startup pass: embed only new/changed files, drop rows for files
        that vanished while the indexer was down."""
        disk = self.walk_docs()
        in_table = self.table_file_paths()
        # A file the state remembers but the table lost must be re-embedded;
        # dropping the state entry defeats the worker's sha256 short-circuit.
        for path in disk:
            if path not in in_table:
                self.state["files"].pop(path, None)
            self.queue.put(("upsert", path))
        for path in (set(self.state["files"]) | in_table) - disk:
            self.queue.put(("delete", path))
        self.queue.put(("scan_done", utc_now_iso()))
        LOG.info(
            "Reconcile queued: %d on disk, %d in table, %d in state",
            len(disk), len(in_table), len(self.state["files"]),
        )

    def periodic_rescan(self, interval, stop_event):
        if interval <= 0:
            return
        LOG.info("Periodic rescan enabled: every %ss", interval)
        while not stop_event.wait(interval):
            try:
                disk = self.walk_docs()
                for path in disk:
                    if self.stable(path):
                        self.queue.put(("upsert", path))
                for path in set(self.state["files"]) - disk:
                    self.queue.put(("delete", path))
                self.queue.put(("scan_done", utc_now_iso()))
            except Exception:
                LOG.exception("Rescan failed")


class Handler(FileSystemEventHandler):
    def __init__(self, idx):
        self.idx = idx

    def on_created(self, e):
        if not e.is_directory:
            self.idx.queue.put(("upsert", e.src_path))

    def on_modified(self, e):
        if not e.is_directory:
            self.idx.queue.put(("upsert", e.src_path))

    def on_moved(self, e):
        if not e.is_directory:
            self.idx.queue.put(("delete", e.src_path))
            self.idx.queue.put(("upsert", e.dest_path))

    def on_deleted(self, e):
        if not e.is_directory:
            self.idx.queue.put(("delete", e.src_path))


def env(name, default):
    return os.environ.get(name, default)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--docs-dir", default=env("RAG_DOCS_DIR", None),
                    help="directory of documents to index (required)")
    ap.add_argument("--db-dir", default=env("RAG_DB_DIR", None),
                    help="LanceDB dataset directory (required)")
    ap.add_argument("--table", default=env("RAG_TABLE", "activate_rag"))
    ap.add_argument("--embedding-model",
                    default=env("RAG_EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2"))
    ap.add_argument("--chunk-chars", type=int, default=int(env("RAG_CHUNK_CHARS", "700")))
    ap.add_argument("--chunk-overlap", type=int, default=int(env("RAG_CHUNK_OVERLAP", "80")))
    ap.add_argument("--rescan-seconds", type=int, default=int(env("INDEXER_RESCAN_SECONDS", "20")))
    ap.add_argument("--stabilize-seconds", type=int, default=int(env("INDEXER_STABILIZE_SECONDS", "5")))
    ap.add_argument("--poll", action="store_true",
                    help="use the polling observer (required on NFS)")
    args = ap.parse_args()

    if not args.docs_dir or not args.db_dir:
        ap.error("--docs-dir and --db-dir are required (or RAG_DOCS_DIR / RAG_DB_DIR)")
    if not os.path.isdir(os.path.expanduser(args.docs_dir)):
        ap.error(f"docs dir does not exist: {args.docs_dir}")

    idx = Indexer(args)
    idx.reconcile()

    worker = threading.Thread(target=idx.worker, daemon=True)
    worker.start()

    stop = threading.Event()
    rescan = threading.Thread(
        target=idx.periodic_rescan, args=(args.rescan_seconds, stop), daemon=True
    )
    rescan.start()

    obs = PollingObserver() if args.poll else Observer()
    obs.schedule(Handler(idx), path=idx.docs_dir, recursive=True)
    obs.start()
    LOG.info("Watching %s (poll=%s)", idx.docs_dir, args.poll)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop.set()
        obs.stop()
        obs.join()


if __name__ == "__main__":
    main()
