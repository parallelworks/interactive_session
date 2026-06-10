#!/usr/bin/env python3
"""Assemble a self-contained multi-job DAG workflow (no subworkflow).

Demonstrates the orchestration primitives: a job graph wired with `needs`, data
passed between jobs via `$OUTPUTS` / `${{ needs.<job>.outputs.<KEY> }}`, and a
conditional step driven by an upstream output. Pure batch — not every workflow
needs a subworkflow; subworkflows are for job submission / sessions, plain
orchestration is a first-class use.
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


GEN = b64("gen.py")
ANALYZE = b64("analyze.py")

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# pipeline: a 3-stage DAG (generate -> analyze -> report) on one resource.
# Jobs share ${{PW_PARENT_JOB_DIR}}, pass values via $OUTPUTS, and the report job
# runs a conditional step based on an upstream output.
permissions:
  - '*'

jobs:
  generate:
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Write code
        run: |
          set -x
          mkdir -p ${{PW_PARENT_JOB_DIR}}/pipeline
          base64 -d > ${{PW_PARENT_JOB_DIR}}/pipeline/gen.py <<'B64'
{GEN}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/pipeline/analyze.py <<'B64'
{ANALYZE}
          B64
      - name: Generate dataset
        run: |
          set -x
          cd ${{PW_PARENT_JOB_DIR}}
          rows=$(python3 pipeline/gen.py --rows "${{{{ inputs.data.rows }}}}" --noise "${{{{ inputs.data.noise }}}}" --out data.csv)
          echo "n_rows=${{rows}}" | tee -a $OUTPUTS
          head -3 data.csv

  analyze:
    needs:
      - generate
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Least-squares fit
        run: |
          set -x
          cd ${{PW_PARENT_JOB_DIR}}
          # analyze.py prints KEY=VALUE lines (slope=, mean_y=, stdev_y=, good_fit=)
          # which tee writes straight into $OUTPUTS as job outputs.
          python3 pipeline/analyze.py | tee -a $OUTPUTS
          cat stats.json

  report:
    needs:
      - generate
      - analyze
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Write report
        run: |
          cd ${{PW_PARENT_JOB_DIR}}
          cat > report.md <<EOF
          # Pipeline report

          - rows generated: ${{{{ needs.generate.outputs.n_rows }}}}
          - fitted slope:   ${{{{ needs.analyze.outputs.slope }}}}
          - fitted mean_y:  ${{{{ needs.analyze.outputs.mean_y }}}}
          - stdev_y:        ${{{{ needs.analyze.outputs.stdev_y }}}}
          - good fit:       ${{{{ needs.analyze.outputs.good_fit }}}}
          EOF
          cat report.md
      - name: Flag a poor fit
        if: ${{{{ needs.analyze.outputs.good_fit == 'false' }}}}
        run: |
          echo "::warning title=Poor fit::slope ${{{{ needs.analyze.outputs.slope }}}} is outside the expected band"
      - name: Confirm a good fit
        if: ${{{{ needs.analyze.outputs.good_fit == 'true' }}}}
        run: |
          echo "::notice title=Good fit::slope ${{{{ needs.analyze.outputs.slope }}}} looks healthy"

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Compute resource
        include-workspace: true
      data:
        type: group
        label: Dataset
        items:
          rows:
            label: Rows
            type: integer
            default: 1000
          noise:
            label: Noise stdev
            type: number
            default: 2.0
"""

out = os.path.join(HERE, "pipeline.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
