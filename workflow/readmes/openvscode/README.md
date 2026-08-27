# VS Code

Runs [code-server](https://github.com/coder/code-server) — VS Code in the
browser — on a cluster, exposed through a platform endpoint.

## Inputs

- **Service host** — the cluster that runs the IDE. With **Schedule Job?**
  enabled the service is submitted to a compute node via SLURM/PBS (with the
  usual directive inputs); otherwise it runs on the login/controller node.
- **Download URL** — the code-server release tarball to install.
- **Password** — optional password for the IDE session; blank means no
  password.
- **Directory to open** — the folder the IDE opens, encoded in the endpoint
  URL.

## Lifecycle

The workflow run completes once the endpoint registers; the service keeps
running on the resource. Find it with `pw endpoints list` (named
`openvscode-<run-slug>`) and tear it down with
`pw endpoints delete openvscode-<run-slug>`.

The code-server installation persists under `<parent_install_dir>` (default
`${HOME}/pw/software`), so subsequent runs skip the download.
