#!/usr/bin/env python3
"""Analyze a source tree: file counts + size + line counts by extension, and the
largest files. Writes repo_report.json and report.md. Skips .git and binaries.
"""
import argparse
import json
import os

ap = argparse.ArgumentParser()
ap.add_argument("--root", default=".")
ap.add_argument("--top", type=int, default=8)
a = ap.parse_args()

exts = {}
total_files = total_bytes = total_lines = 0
biggest = []

for dirpath, dirs, files in os.walk(a.root):
    if ".git" in dirs:
        dirs.remove(".git")
    for fn in files:
        p = os.path.join(dirpath, fn)
        try:
            sz = os.path.getsize(p)
        except OSError:
            continue
        total_files += 1
        total_bytes += sz
        ext = os.path.splitext(fn)[1].lower() or "(none)"
        e = exts.setdefault(ext, {"files": 0, "bytes": 0, "lines": 0})
        e["files"] += 1
        e["bytes"] += sz
        try:
            with open(p, "rb") as fh:
                data = fh.read()
            if b"\x00" not in data[:4096]:  # treat as text
                n = data.count(b"\n")
                e["lines"] += n
                total_lines += n
        except OSError:
            pass
        biggest.append((sz, os.path.relpath(p, a.root)))

biggest.sort(reverse=True)
by_ext = dict(sorted(exts.items(), key=lambda kv: -kv[1]["files"]))
report = {
    "root": a.root,
    "files": total_files,
    "bytes": total_bytes,
    "lines": total_lines,
    "by_extension": by_ext,
    "largest": [{"bytes": s, "path": p} for s, p in biggest[: a.top]],
}
with open("repo_report.json", "w") as fh:
    json.dump(report, fh, indent=2)

with open("report.md", "w") as fh:
    fh.write("# Repo analysis: %s\n\n" % a.root)
    fh.write("- files: %d\n- total size: %d bytes\n- text lines: %d\n\n"
             % (total_files, total_bytes, total_lines))
    fh.write("## By extension\n\n")
    for ext, d in list(by_ext.items())[:12]:
        fh.write("- `%s`: %d files, %d lines\n" % (ext, d["files"], d["lines"]))
    fh.write("\n## Largest files\n\n")
    for b in report["largest"]:
        fh.write("- %s (%d bytes)\n" % (b["path"], b["bytes"]))

print("::notice::analyzed %d files, %d text lines under %s"
      % (total_files, total_lines, a.root))
