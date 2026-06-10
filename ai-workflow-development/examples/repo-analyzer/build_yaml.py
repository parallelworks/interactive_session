#!/usr/bin/env python3
"""Assemble the repo-analyzer workflow.

Contrasts the two ways to get code/files onto a node:
  1. `parallelworks/checkout` — fetch a git repo (sparse) into the job dir. This is
     how the interactive_session workflows ship their scripts.
  2. base64 embedding — our analyzer tool, written into tools/ (no repo needed).
Then an `analyze` job runs the tool over the checked-out tree.
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


ANALYZE = b64("analyze_repo.py")

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# repo-analyzer: clone a GitHub repo (sparse) with parallelworks/checkout, then
# analyze the tree (files/lines by extension, largest files) -> report.md.
permissions:
  - '*'

jobs:
  checkout:
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Checkout target repo (sparse)
        uses: parallelworks/checkout
        with:
          repo: ${{{{ inputs.repo.url }}}}
          branch: ${{{{ inputs.repo.branch }}}}
          sparse_checkout:
            - ${{{{ inputs.repo.path }}}}
      - name: Write analyzer tool
        run: |
          set -x
          mkdir -p ${{PW_PARENT_JOB_DIR}}/tools
          base64 -d > ${{PW_PARENT_JOB_DIR}}/tools/analyze_repo.py <<'B64'
{ANALYZE}
          B64
          echo "checked-out tree:"; ls -la ${{PW_PARENT_JOB_DIR}}/${{{{ inputs.repo.path }}}} | head

  analyze:
    needs:
      - checkout
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Analyze
        run: |
          set -x
          cd ${{PW_PARENT_JOB_DIR}}
          python3 tools/analyze_repo.py --root "${{{{ inputs.repo.path }}}}" | tee -a $OUTPUTS
          echo "===== report.md ====="
          cat report.md

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Compute resource
        include-workspace: true
      repo:
        type: group
        label: Repository
        items:
          url:
            label: Git repo URL
            type: string
            default: https://github.com/parallelworks/interactive_session.git
          branch:
            label: Branch
            type: string
            default: main
          path:
            label: Sparse path to analyze
            type: string
            default: workflow/readmes
"""

out = os.path.join(HERE, "repo-analyzer.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
