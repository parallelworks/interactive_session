#!/usr/bin/env python3
"""Assemble the fileserver session workflow (session_runner/v1.4).

The smallest possible session: no custom server code at all — the start script
just runs `python3 -m http.server`. Shows that a session_runner service can be a
stock binary/built-in, and demonstrates serving a chosen directory.
"""
import base64
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))


def b64(name):
    with open(os.path.join(HERE, name), "rb") as fh:
        enc = base64.b64encode(fh.read()).decode()
    return "\n".join("          " + line for line in textwrap.wrap(enc, 100))


CTL = b64("controller-v3.sh")
START = b64("start-template-v3.sh")

YAML = f"""\
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
# fileserver: browse/download a directory on the resource via a tunnel session.
# No custom code — the start script runs Python's stdlib http.server.
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
      - name: Create inputs and scripts
        run: |
          set -x
          env | grep '^PW_' | grep -v 'PW_API_KEY' > inputs.sh
          sed -i 's/=\\(.*\\)/="\\1"/' inputs.sh
          cat <<'EOF' >> inputs.sh
          PATH=$HOME/pw:$PATH
          fs_dir="${{{{ inputs.fs.directory }}}}"
          EOF
          sed -i '/=\\s*$\\|=undefined\\s*$/d' inputs.sh
          sed -i '/=""/d' inputs.sh
          sed -i 's/^/export /' inputs.sh
          mkdir -p ${{PW_PARENT_JOB_DIR}}/fileserver
          base64 -d > ${{PW_PARENT_JOB_DIR}}/fileserver/controller-v3.sh <<'B64'
{CTL}
          B64
          base64 -d > ${{PW_PARENT_JOB_DIR}}/fileserver/start-template-v3.sh <<'B64'
{START}
          B64

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
            start_service_script: ${{PW_PARENT_JOB_DIR}}/fileserver/start-template-v3.sh
            controller_script: ${{PW_PARENT_JOB_DIR}}/fileserver/controller-v3.sh
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
      scheduler:
        type: boolean
        default: false
        label: Schedule Job?
        hidden: ${{{{ inputs.resource.schedulerType == '' }}}}
        ignore: ${{{{ .hidden }}}}
      slurm:
        type: group
        label: SLURM Directives
        hidden: ${{{{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}}}
        ignore: ${{{{ inputs.resource.schedulerType != 'slurm' || inputs.scheduler == false }}}}
        items:
          is_enabled: {{ type: boolean, hidden: true, default: true }}
          partition: {{ type: slurm-partitions, label: SLURM partition, optional: true, resource: '${{{{ inputs.resource }}}}' }}
          time: {{ label: Walltime, type: string, default: '01:00:00' }}
          scheduler_directives: {{ type: editor, optional: true }}
      pbs:
        type: group
        label: PBS Directives
        hidden: ${{{{ inputs.resource.schedulerType != 'pbs' || inputs.scheduler == false }}}}
        ignore: ${{{{ inputs.resource.schedulerType != 'pbs' || inputs.scheduler == false }}}}
        items:
          is_enabled: {{ type: boolean, hidden: true, default: true }}
          scheduler_directives: {{ label: Scheduler Directives, type: editor }}
      fs:
        type: group
        label: File Server
        items:
          directory:
            label: Directory to serve
            type: string
            default: ${{HOME}}/pw/jobs
            tooltip: Read-only directory exposed through the session
"""

out = os.path.join(HERE, "fileserver.yaml")
with open(out, "w") as fh:
    fh.write(YAML)
print("wrote", out, "(%d bytes)" % len(YAML))
