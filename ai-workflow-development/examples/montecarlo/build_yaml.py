#!/usr/bin/env python3
"""Assemble a self-contained Activate workflow YAML for the Monte Carlo demo.

A *batch compute* workflow (no session): preprocessing writes the code, then
`script_submitter/v3.6` runs it on the chosen resource — directly on the login
node (scheduler:false) or on a SLURM/PBS compute node (scheduler:true).

base64-embeds the source files so the deployed code is byte-identical to what was
tested locally and we avoid heredoc-indent / ${{ }} templating pitfalls. Re-run
after edits, then `pw workflows update montecarlo --yaml montecarlo.yaml`.
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    # 10-space indent = the run-block content indent, so the literal block keeps
    # these lines; YAML strips the 10 spaces, leaving base64 + delimiter at col 0.
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


PY = b64("montecarlo_pi.py")
RUN = b64("run_montecarlo.sh")

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# Monte Carlo pi — a batch compute workflow driven by script_submitter/v3.6.
# Runs on the login node (scheduler:false) or a SLURM/PBS compute node
# (scheduler:true). Progress streams to run.<JOBID>.out; the structured result is
# written to montecarlo_result.json in the run directory.
permissions:
  - '*'

jobs:
  preprocessing:
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Write code and inputs
        run: |
          set -x
          mkdir -p ${{PW_PARENT_JOB_DIR}}/montecarlo
          # Capture PW_* env (skip the API key), quote, and add form inputs.
          env | grep '^PW_' | grep -v 'PW_API_KEY' > ${{PW_PARENT_JOB_DIR}}/inputs.sh
          sed -i 's/=\\(.*\\)/="\\1"/' ${{PW_PARENT_JOB_DIR}}/inputs.sh
          cat <<'EOF' >> ${{PW_PARENT_JOB_DIR}}/inputs.sh
          mc_samples="${{{{ inputs.mc.samples }}}}"
          mc_batches="${{{{ inputs.mc.batches }}}}"
          EOF
          sed -i '/=\\s*$\\|=undefined\\s*$/d' ${{PW_PARENT_JOB_DIR}}/inputs.sh
          sed -i '/=""/d' ${{PW_PARENT_JOB_DIR}}/inputs.sh
          sed -i 's/^/export /' ${{PW_PARENT_JOB_DIR}}/inputs.sh
          base64 -d > ${{PW_PARENT_JOB_DIR}}/montecarlo/montecarlo_pi.py <<'B64'
{PY}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/montecarlo/run_montecarlo.sh <<'B64'
{RUN}
          B64
          chmod +x ${{PW_PARENT_JOB_DIR}}/montecarlo/run_montecarlo.sh
          ls -la ${{PW_PARENT_JOB_DIR}}/montecarlo
          python3 -c "import ast; ast.parse(open('${{PW_PARENT_JOB_DIR}}/montecarlo/montecarlo_pi.py').read()); print('compute code parses OK')"

  run_montecarlo:
    needs:
      - preprocessing
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Submit Monte Carlo job
        uses: github/parallelworks/interactive_session@main
        early-cancel: any-job-failed
        with:
          $yaml: workflow/script_submitter/v3.6/general.yaml
          resource: ${{{{ inputs.resource }}}}
          rundir: ${{PW_PARENT_JOB_DIR}}
          use_existing_script: true
          script_path: ${{PW_PARENT_JOB_DIR}}/montecarlo/run_montecarlo.sh
          shebang: '#!/bin/bash'
          scheduler: ${{{{ inputs.scheduler }}}}
          use_scheduler_agent: false
          # script_submitter marks cleanup_script_path required (no default); the
          # subworkflow defaults-filler ignores the UI hidden/ignore rules, so we
          # must pass it explicitly even though we don't use a cleanup script.
          define_cleanup_script: false
          cleanup_script_path: ""
          slurm:
            is_enabled: ${{{{ inputs.slurm.is_enabled }}}}
            partition: ${{{{ inputs.slurm.partition }}}}
            time: ${{{{ inputs.slurm.time }}}}
            scheduler_directives: ${{{{ inputs.slurm.scheduler_directives }}}}
          pbs:
            is_enabled: ${{{{ inputs.pbs.is_enabled }}}}
            scheduler_directives: ${{{{ inputs.pbs.scheduler_directives }}}}
      - name: Show result
        run: |
          set -x
          echo "::notice::Monte Carlo finished — result:"
          cat ${{PW_PARENT_JOB_DIR}}/montecarlo_result.json

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Compute resource
        include-workspace: true
        tooltip: Where to run the Monte Carlo job
      scheduler:
        type: boolean
        default: false
        label: Schedule Job?
        hidden: ${{{{ inputs.resource.schedulerType == '' }}}}
        ignore: ${{{{ .hidden }}}}
        tooltip: |
          Yes -> submit to the scheduler (sbatch/qsub) and run on a compute node
          No  -> run directly on the controller/login node
      slurm:
        type: group
        label: SLURM Directives
        hidden: ${{{{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}}}
        ignore: ${{{{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}}}
        items:
          is_enabled:
            type: boolean
            hidden: true
            default: true
          partition:
            type: slurm-partitions
            label: SLURM partition
            optional: true
            resource: ${{{{ inputs.resource }}}}
          time:
            label: Walltime
            type: string
            default: '00:10:00'
          scheduler_directives:
            type: editor
            optional: true
      pbs:
        type: group
        label: PBS Directives
        hidden: ${{{{ inputs.resource.schedulerType != 'pbs' || inputs.scheduler == false }}}}
        ignore: ${{{{ inputs.resource.schedulerType != 'pbs' || inputs.scheduler == false }}}}
        items:
          is_enabled:
            type: boolean
            hidden: true
            default: true
          scheduler_directives:
            label: Scheduler Directives
            type: editor
      mc:
        type: group
        label: Monte Carlo Settings
        items:
          samples:
            label: Total samples
            type: integer
            default: 12000000
          batches:
            label: Progress batches
            type: integer
            default: 24
"""

out = os.path.join(HERE, "montecarlo.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
