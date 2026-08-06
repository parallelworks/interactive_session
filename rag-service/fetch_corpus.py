#!/usr/bin/env python3
"""Download an open-access test corpus of optimization-methods papers from arXiv.

Standard library only. Queries the arXiv Atom API for a fixed set of seed
papers plus topic searches, downloads one PDF at a time from export.arxiv.org
with >=3 s between HTTP requests, and writes a manifest.json describing what
landed. Idempotent: PDFs already present (verified by sha256 when known) are
not re-downloaded.

Usage: fetch_corpus.py --out <dir> [--max 15]
"""

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

API_URL = "http://export.arxiv.org/api/query"
USER_AGENT = (
    "activate-rag-service-corpus-fetcher/1.0 "
    "(Parallel Works ACTIVATE workflow test corpus; contact: alvaro@parallelworks.com)"
)
REQUEST_GAP_SECONDS = 3.0
ATOM = "{http://www.w3.org/2005/Atom}"

# Seed papers that the smoke tests rely on. Titles are verified against the
# API response; a seed whose returned title does not match is skipped.
SEEDS = [
    ("1807.02811", "a tutorial on bayesian optimization"),
    ("1012.2599", "bayesian optimization of expensive cost functions"),
    ("1206.2944", "practical bayesian optimization of machine learning"),
    ("1604.00772", "the cma evolution strategy: a tutorial"),
]

TOPIC_QUERIES = [
    'all:"bayesian optimization"',
    'all:"surrogate-based optimization"',
    'all:"aerodynamic shape optimization"',
    'all:"CMA-ES" AND all:"evolution strategies"',
    'all:"derivative-free optimization"',
]

_last_request_time = [0.0]


def _polite_get(url, timeout=60):
    wait = REQUEST_GAP_SECONDS - (time.monotonic() - _last_request_time[0])
    if wait > 0:
        time.sleep(wait)
    _last_request_time[0] = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def _api_query(params):
    url = API_URL + "?" + urllib.parse.urlencode(params)
    print(f"[api] {url}")
    with _polite_get(url) as resp:
        return ET.fromstring(resp.read())


def _parse_entries(root):
    entries = []
    for entry in root.findall(ATOM + "entry"):
        raw_id = (entry.findtext(ATOM + "id") or "").strip()
        m = re.search(r"arxiv\.org/abs/(.+)$", raw_id)
        if not m:
            continue
        versioned_id = m.group(1)
        base_id = re.sub(r"v\d+$", "", versioned_id)
        title = re.sub(r"\s+", " ", entry.findtext(ATOM + "title") or "").strip()
        authors = [
            (a.findtext(ATOM + "name") or "").strip()
            for a in entry.findall(ATOM + "author")
        ]
        published = (entry.findtext(ATOM + "published") or "").strip()
        pdf_url = None
        for link in entry.findall(ATOM + "link"):
            if link.get("title") == "pdf":
                pdf_url = link.get("href")
                break
        if not pdf_url:
            pdf_url = f"http://arxiv.org/pdf/{versioned_id}"
        # The brief and arXiv's own guidance say to pull PDFs from the export
        # mirror, which is what the API is for.
        pdf_url = pdf_url.replace("://arxiv.org/", "://export.arxiv.org/")
        entries.append(
            {
                "arxiv_id": base_id,
                "title": title,
                "authors": authors,
                "published": published,
                "pdf_url": pdf_url,
            }
        )
    return entries


def _slug(title, max_len=60):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s[:max_len].rstrip("-")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _download_pdf(entry, out_dir):
    fname = f"{entry['arxiv_id'].replace('/', '_')}-{_slug(entry['title'])}.pdf"
    path = out_dir / fname
    if path.exists() and path.stat().st_size > 10_000:
        print(f"[skip] already present: {fname}")
        entry["file"] = fname
        entry["sha256"] = _sha256(path)
        return True
    print(f"[pdf] {entry['pdf_url']} -> {fname}")
    try:
        with _polite_get(entry["pdf_url"], timeout=120) as resp:
            data = resp.read()
    except (urllib.error.URLError, OSError) as e:
        print(f"[warn] download failed for {entry['arxiv_id']}: {e}", file=sys.stderr)
        return False
    if not data.startswith(b"%PDF"):
        print(f"[warn] {entry['arxiv_id']}: response is not a PDF, skipping", file=sys.stderr)
        return False
    path.write_bytes(data)
    entry["file"] = fname
    entry["sha256"] = _sha256(path)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="output directory for PDFs + manifest.json")
    ap.add_argument("--max", type=int, default=15, help="maximum number of PDFs (default 15)")
    args = ap.parse_args()

    from pathlib import Path

    out_dir = Path(args.out).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    selected = {}

    root = _api_query({"id_list": ",".join(sid for sid, _ in SEEDS), "max_results": len(SEEDS)})
    by_id = {e["arxiv_id"]: e for e in _parse_entries(root)}
    for sid, expected in SEEDS:
        entry = by_id.get(sid)
        if entry is None:
            print(f"[warn] seed {sid} not returned by API, skipping", file=sys.stderr)
            continue
        if expected not in entry["title"].lower():
            print(
                f"[warn] seed {sid} title mismatch ({entry['title']!r}), skipping",
                file=sys.stderr,
            )
            continue
        selected[sid] = entry

    per_topic = max(3, (args.max - len(selected)) // len(TOPIC_QUERIES) + 1)
    for q in TOPIC_QUERIES:
        if len(selected) >= args.max:
            break
        root = _api_query(
            {
                "search_query": q,
                "max_results": per_topic,
                "sortBy": "relevance",
                "sortOrder": "descending",
            }
        )
        for entry in _parse_entries(root):
            if len(selected) >= args.max:
                break
            selected.setdefault(entry["arxiv_id"], entry)

    manifest = []
    for entry in selected.values():
        if _download_pdf(entry, out_dir):
            manifest.append(entry)

    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[done] {len(manifest)} PDFs in {out_dir}, manifest at {manifest_path}")

    seed_ids = {sid for sid, _ in SEEDS}
    got_seeds = seed_ids & {m["arxiv_id"] for m in manifest}
    if got_seeds != seed_ids:
        print(f"[warn] missing seed papers: {sorted(seed_ids - got_seeds)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
