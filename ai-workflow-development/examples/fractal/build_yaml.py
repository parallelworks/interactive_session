#!/usr/bin/env python3
"""Assemble a self-contained Activate workflow YAML for the fractal demo.

Reads the locally-developed source files, base64-encodes them, and embeds them
in the workflow's preprocessing job. base64 sidesteps YAML/heredoc indentation
and ${{ }} templating pitfalls — the deployed code is byte-identical to what was
tested locally. Re-run this after editing any source file:

    python3 build_yaml.py && pw workflows update fractal --yaml fractal_session.yaml
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    # Every line must sit at the run-block content indent (10 spaces) so the
    # literal block scalar keeps them; YAML strips those 10 spaces, leaving the
    # base64 body and the closing 'B64' delimiter at column 0 for the heredoc.
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


PY = b64("mandelbrot_server.py")
CTL = b64("controller-v3.sh")
START = b64("start-template-v3.sh")

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# Fractal demo: progressively renders a Mandelbrot set and serves a live progress
# page from a stdlib Python web server, exposed through Activate as a tunnel session.
# Self-contained: preprocessing writes the server + scripts (base64) into the job
# dir, then session_runner allocates a port, runs the service, and registers it.
permissions:
  - '*'
sessions:
  session:
    useTLS: false
    redirect: true

jobs:
  preprocessing:
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Create Inputs
        run: |
          set -x
          # Capture PW_* environment variables (skip the API key) and quote values.
          env | grep '^PW_' | grep -v 'PW_API_KEY' > inputs.sh
          sed -i 's/=\\(.*\\)/="\\1"/' inputs.sh
          # Append form inputs and ensure the pw agent is on PATH.
          cat <<'EOF' >> inputs.sh
          PATH=$HOME/pw:$PATH
          mb_width="${{{{ inputs.fractal.width }}}}"
          mb_height="${{{{ inputs.fractal.height }}}}"
          mb_max_iter="${{{{ inputs.fractal.max_iter }}}}"
          EOF
          # Drop empty / undefined values and export everything.
          sed -i '/=\\s*$\\|=undefined\\s*$/d' inputs.sh
          sed -i '/=""/d' inputs.sh
          sed -i 's/^/export /' inputs.sh
          cat inputs.sh
      - name: Write server and scripts
        run: |
          set -x
          mkdir -p ${{PW_PARENT_JOB_DIR}}/mandelbrot
          base64 -d > ${{PW_PARENT_JOB_DIR}}/mandelbrot/mandelbrot_server.py <<'B64'
{PY}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/mandelbrot/controller-v3.sh <<'B64'
{CTL}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/mandelbrot/start-template-v3.sh <<'B64'
{START}
          B64
          chmod +x ${{PW_PARENT_JOB_DIR}}/mandelbrot/*.sh
          ls -la ${{PW_PARENT_JOB_DIR}}/mandelbrot
          python3 -c "import ast; ast.parse(open('${{PW_PARENT_JOB_DIR}}/mandelbrot/mandelbrot_server.py').read()); print('server code parses OK')"

  session_runner:
    needs:
      - preprocessing
    ssh:
      remoteHost: ${{{{ inputs.resource.ip }}}}
    steps:
      - name: Session Runner
        uses: github/parallelworks/interactive_session@main
        early-cancel: any-job-failed
        with:
          $yaml: workflow/session_runner/v1.4/general.yaml
          session: ${{{{ sessions.session }}}}
          resource: ${{{{ inputs.resource }}}}
          cluster:
            scheduler: ${{{{ inputs.scheduler }}}}
            slurm:
              is_enabled: ${{{{ inputs.slurm.is_enabled }}}}
              partition: ${{{{ inputs.slurm.partition }}}}
              scheduler_directives: ${{{{ inputs.slurm.scheduler_directives }}}}
              time: ${{{{ inputs.slurm.time }}}}
            pbs:
              is_enabled: ${{{{ inputs.pbs.is_enabled }}}}
              scheduler_directives: ${{{{ inputs.pbs.scheduler_directives }}}}
          service:
            start_service_script: ${{PW_PARENT_JOB_DIR}}/mandelbrot/start-template-v3.sh
            controller_script: ${{PW_PARENT_JOB_DIR}}/mandelbrot/controller-v3.sh
            inputs_sh: ${{PW_PARENT_JOB_DIR}}/inputs.sh
            slug: ""
            rundir: ${{PW_PARENT_JOB_DIR}}

'on':
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Service host
        include-workspace: true
        tooltip: Resource to host the fractal server (the workspace works too)
      scheduler:
        type: boolean
        default: false
        label: Schedule Job?
        hidden: ${{{{ inputs.resource.schedulerType == '' }}}}
        ignore: ${{{{ .hidden }}}}
        tooltip: |
          Yes -> submit to the scheduler (sbatch/qsub) on a compute node
          No  -> run on the controller/login (or workspace) node
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
            default: '01:00:00'
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
      fractal:
        type: group
        label: Fractal Settings
        items:
          width:
            label: Image width (px)
            type: integer
            default: 480
          height:
            label: Image height (px)
            type: integer
            default: 320
          max_iter:
            label: Max iterations
            type: integer
            default: 200
"""

out = os.path.join(HERE, "fractal_session.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
