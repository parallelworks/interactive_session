#!/bin/bash
# Smoke tests for the rag-service search API.
#
# Usage: smoke_search.sh [BASE_URL]
#   BASE_URL   default http://127.0.0.1:8080
#   RAG_SMOKE_AUTH_HEADER   optional, e.g. "Authorization: Bearer $PW_API_KEY"
#                           for testing through the platform endpoint URL.
#
# Requires the corpus produced by fetch_corpus.py plus the fixture markdown
# files (fixtures/*.md) to be present in the indexed docs dir.
set -o pipefail

BASE_URL="${1:-http://127.0.0.1:8080}"
PASS=0
FAIL=0

CHECKER="$(cat <<'PYEOF'
import json, sys
payload = sys.stdin.read()
try:
    data = json.loads(payload)
except ValueError:
    print(f"NOT JSON: {payload[:200]}")
    sys.exit(1)
kind = sys.argv[1]
results = data.get("results", [])
paths = [r.get("file_path", "") for r in results]

def fail(msg):
    print(f"{msg} | top paths: {paths[:3]}")
    sys.exit(1)

if kind == "top1":
    if not results: fail("no results")
    if sys.argv[2] not in paths[0]: fail(f"top1 != *{sys.argv[2]}*")
elif kind == "top3":
    if not any(sys.argv[2] in p for p in paths[:3]): fail(f"*{sys.argv[2]}* not in top3")
elif kind == "all_contain":
    if not results: fail("no results")
    if not all(sys.argv[2] in p for p in paths): fail(f"a result lacks *{sys.argv[2]}*")
elif kind == "score_kind":
    if not results: fail("no results")
    kinds = {r.get("score_kind") for r in results}
    if kinds != {sys.argv[2]}: fail(f"score_kind {kinds} != {sys.argv[2]}")
elif kind == "dense_score_range":
    if not results: fail("no results")
    s = results[0]["score"]
    if not (0.0 <= s <= 1.0): fail(f"dense score {s} outside [0,1]")
elif kind == "fields":
    if not results: fail("no results")
    required = {"text","score","score_kind","file_path","title","chunk_index","span_start","span_end","doc_sha256"}
    missing = required - set(results[0])
    if missing: fail(f"missing fields: {missing}")
print("ok")
PYEOF
)"

fetch() {
    if [ -n "${RAG_SMOKE_AUTH_HEADER}" ]; then
        curl -sS -m 60 -H "${RAG_SMOKE_AUTH_HEADER}" "$@"
    else
        curl -sS -m 60 "$@"
    fi
}

q() { RESP="$(fetch --get "${BASE_URL}/search" "$@")"; }

check() {
    local desc="$1"; shift
    local out
    out="$(python3 -c "${CHECKER}" "$@" <<<"${RESP}")"
    if [ "$out" = "ok" ]; then
        echo "PASS: ${desc}"
        PASS=$((PASS+1))
    else
        echo "FAIL: ${desc} -- ${out}"
        FAIL=$((FAIL+1))
    fi
}

echo "== rag-service smoke tests against ${BASE_URL} =="

# --- deterministic fixture facts: expected top-1 file, all three modes ---
q --data-urlencode "query=what is the frobnicator coefficient" --data-urlencode "mode=hybrid"
check "hybrid: frobnicator coefficient -> frobnicator notes top1" top1 "frobnicator-design-notes.md"

q --data-urlencode "query=scratch quota on the zephyr cluster" --data-urlencode "mode=dense"
check "dense: zephyr scratch quota -> zephyr runbook top1" top1 "zephyr-cluster-runbook.md"

q --data-urlencode "query=tarragon handshake retries" --data-urlencode "mode=fts"
check "fts: tarragon handshake -> tarragon protocol top1" top1 "tarragon-protocol.md"

q --data-urlencode "query=mauve trust region radius" --data-urlencode "mode=hybrid"
check "hybrid: mauve trust region -> quokka spec top1" top1 "quokka-optimizer-spec.md"

# --- real papers: expected file among top-3 (fuzzy topical assertions) ---
q --data-urlencode "query=expected improvement acquisition function" --data-urlencode "mode=hybrid"
check "hybrid: expected improvement -> a bayesian-optimization paper in top3" top3 "bayesian-optimization"

q --data-urlencode "query=covariance matrix adaptation evolution strategy" --data-urlencode "mode=dense"
check "dense: covariance matrix adaptation -> a CMA-ES paper in top3" top3 "cma"

q --data-urlencode "query=practical bayesian optimization of machine learning hyperparameters" --data-urlencode "mode=fts"
check "fts: practical BO of ML -> Snoek et al. (1206.2944) in top3" top3 "1206.2944"

q --data-urlencode "query=aerodynamic shape optimization adjoint" --data-urlencode "mode=hybrid"
check "hybrid: adjoint aero shape opt -> an aerodynamic paper in top3" top3 "aerodynamic"

# --- filters ---
q --data-urlencode "query=quota" --data-urlencode "file_contains=zephyr"
check "filter: file_contains=zephyr restricts results" all_contain "zephyr"

# --- contract: score_kind per mode, dense score range, required fields ---
q --data-urlencode "query=optimization" --data-urlencode "mode=dense"
check "contract: dense score_kind=cosine" score_kind "cosine"
check "contract: dense score in [0,1]" dense_score_range
q --data-urlencode "query=optimization" --data-urlencode "mode=fts"
check "contract: fts score_kind=bm25" score_kind "bm25"
q --data-urlencode "query=optimization" --data-urlencode "mode=hybrid"
check "contract: hybrid score_kind=rrf" score_kind "rrf"
check "contract: every result carries citation fields" fields

# --- error handling ---
code=$(fetch -o /dev/null -w '%{http_code}' "${BASE_URL}/search")
if [ "$code" = "400" ]; then echo "PASS: missing query -> 400"; PASS=$((PASS+1));
else echo "FAIL: missing query -> $code (want 400)"; FAIL=$((FAIL+1)); fi

code=$(fetch -o /dev/null -w '%{http_code}' --get "${BASE_URL}/search" \
       --data-urlencode "query=x" --data-urlencode "mode=bogus")
if [ "$code" = "400" ]; then echo "PASS: bad mode -> 400"; PASS=$((PASS+1));
else echo "FAIL: bad mode -> $code (want 400)"; FAIL=$((FAIL+1)); fi

echo "== ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ]
