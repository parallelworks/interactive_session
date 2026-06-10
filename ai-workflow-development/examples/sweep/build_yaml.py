#!/usr/bin/env python3
"""Assemble a fan-out / fan-in parameter-sweep workflow.

`prepare` writes the code; three worker jobs (w1/w2/w3) each `needs: [prepare]`
but NOT each other, so the DAG runs them concurrently over different bands;
`aggregate` `needs: [w1,w2,w3]` and merges the parts. This is the canonical
HPC fan-out/fan-in shape expressed purely with the job graph.
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


MIN = b64("minimize.py")
AGG = b64("aggregate.py")

# Three bands tiling x in [-6, 6].
BANDS = [("1", -6, -2), ("2", -2, 2), ("3", 2, 6)]


def worker(wid, lo, hi):
    return f"""\
  w{wid}:
    needs:
      - prepare
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Sweep band {wid}
        run: |
          set -x
          cd ${{PW_PARENT_JOB_DIR}}
          python3 sweep/minimize.py --id {wid} --lo {lo} --hi {hi} --steps "${{{{ inputs.sweep.steps }}}}"
"""


WORKERS = "\n".join(worker(w, lo, hi) for w, lo, hi in BANDS)

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# sweep: fan-out parameter study. prepare -> {{w1,w2,w3 in parallel}} -> aggregate.
# Workers share ${{PW_PARENT_JOB_DIR}} and write part_<id>.json concurrently; the
# aggregator merges them and reports the global minimum.
permissions:
  - '*'

jobs:
  prepare:
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Write code
        run: |
          set -x
          mkdir -p ${{PW_PARENT_JOB_DIR}}/sweep
          rm -f ${{PW_PARENT_JOB_DIR}}/part_*.json
          base64 -d > ${{PW_PARENT_JOB_DIR}}/sweep/minimize.py <<'B64'
{MIN}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/sweep/aggregate.py <<'B64'
{AGG}
          B64

{WORKERS}
  aggregate:
    needs:
      - w1
      - w2
      - w3
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Merge results
        run: |
          set -x
          cd ${{PW_PARENT_JOB_DIR}}
          ls -la part_*.json
          python3 sweep/aggregate.py | tee -a $OUTPUTS
          echo "--- sweep_result.json ---"
          cat sweep_result.json

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Compute resource
        include-workspace: true
      sweep:
        type: group
        label: Sweep Settings
        items:
          steps:
            label: Grid steps per band (per axis)
            type: integer
            default: 240
"""

out = os.path.join(HERE, "sweep.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
