# Delivering Singularity containers as SIF files (ORAS on ghcr.io)

> Working notes from the **n8n** conversion (`n8n-endpoint` branch, 2026-07), where
> the sandbox-tarball delivery (`ghcr.io/parallelworks/n8n:1.0` — an `n8n.tgz`
> holding an unpacked sandbox directory) was replaced by a **SIF file**
> (`ghcr.io/parallelworks/n8n:2.0`). Ground truth:
> `n8n-singularity/{build-container.sh,controller-v4.sh,start-template-v4.sh}`.
> Everything below was verified on live runs on gcpsmall unless marked otherwise.

## Why SIF instead of a tarballed sandbox

| | sandbox + tgz (old) | SIF (new) |
|---|---|---|
| Artifact | tar of a sandbox directory (tens of thousands of small files inside) | one compressed, mountable image file (n8n: 255 MB) |
| Install | `oras pull` + `tar -xzf` (double disk during extract, slow untar on shared filesystems) | `oras pull`, done |
| Runtime | runs anywhere — it's a plain directory | needs the node to be able to mount squashfs → **probe + sandbox fallback** (below) |
| Build | `singularity build --sandbox` + `tar -czf` | `singularity build <name>.sif docker://<image>` |
| Integrity | none (loose files, easy to corrupt with a partial untar) | single file; SIF is checksummed at build |

The only thing the sandbox bought us was independence from squashfs mount support.
Keep that as a **fallback built on demand from the SIF** — building a sandbox from a
local SIF is pure unpacking, needs **no internet**, so it is safe on compute nodes.

## Build and push

Build (see `n8n-singularity/build-container.sh`):

```bash
export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp     # build scratch off /tmp
export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache # OCI layer cache
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"
singularity build --force n8n.sif docker://n8nio/n8n:1.123.4
singularity exec n8n.sif n8n --version   # smoke-test before pushing
```

No upstream image (e.g. a pip-installed app)? Build from a definition file instead —
`singularity build --force --fakeroot app.sif app.def` works unprivileged on
apptainer 1.4.5 (verified: `streamlit-singularity/streamlit.def` on gcpsmall, 2026-07);
bootstrap from `docker://python:3.12-slim` and `pip install` in `%post`.

Push as a plain ORAS artifact with the repo's own oras binary (`tools/oras/oras`):

```bash
printf '%s' "$GHCR_TOKEN" | tools/oras/oras login ghcr.io -u <github-user> --password-stdin
tools/oras/oras push ghcr.io/parallelworks/<name>:<tag> <name>.sif
tools/oras/oras logout ghcr.io   # so later pull tests exercise the anonymous path
```

- **Package visibility is inherited by new tags.** `parallelworks/n8n` was already
  public, so pushing `2.0` needed no GitHub admin action. Verify anonymous access
  without any stored credentials:
  ```bash
  TOKEN=$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:parallelworks/<name>:pull" | jq -r .token)
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
      https://ghcr.io/v2/parallelworks/<name>/manifests/<tag>   # 200 = public
  ```
  A brand-new package is **private by default** and must be made public in the
  GitHub UI (Package settings → Danger Zone) before workflows can pull it.
- **Version by tag, don't overwrite:** `n8n:1.0` = legacy sandbox tgz (still used by
  `controller-v3.sh` on older branches), `n8n:2.0` = SIF. Old workflow versions keep
  working.
- Pull with **oras**, matching how it was pushed. A plain `oras push` records the
  generic artifact type (`application/vnd.unknown.artifact.v1`), not the SIF media
  type that `singularity pull oras://` expects — stick to the repo's
  `oras_pull_file` helper (untested: `singularity push`/`pull oras://` as an
  alternative pair).

## Runtime: try the SIF, fall back to a sandbox

Some nodes cannot mount SIF images (no squashfs kernel/FUSE support, locked-down
setuid). Probe with the cheapest possible container run — **on the node that runs
the service**, not the login node: with `scheduler: true` the service lands on a
compute node whose support can differ, so the probe belongs in the **start
template**, never the controller. From `n8n-singularity/start-template-v4.sh`:

```bash
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    container_ref="${container_sif}"          # mount works: run the SIF directly
else
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then        # unpack once, reuse afterwards
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi
# ...later: singularity run ... "${container_ref}"
```

- The probe covers every failure mode at once (kernel squashfs, squashfuse, setuid,
  userns) — no need to diagnose which one is missing.
- The fallback build is **offline-safe** (local unpack) and idempotent via the
  directory guard. Keep the sandbox at a distinct path (`containers/<name>-sandbox`)
  so it can't be confused with a legacy extracted sandbox at `containers/<name>`.
- Both branches verified on gcpsmall: the live run took the SIF branch
  (`Apptainer runtime parent: n8n.sif` in `ps`), and the fallback build + a sandbox
  `n8n --version` were exercised manually on the same node.

## Recipe: convert a sandbox-tgz workflow to SIF

Using n8n as the template (diff `controller-v3.sh` → `controller-v4.sh`):

1. **Build script** — replace `build --sandbox` + `tar` with a single
   `singularity build <name>.sif docker://<image>:<tag>`; update the push hint to
   the new ghcr tag (`n8n-singularity/build-container.sh`).
2. **Build, smoke-test, push** the SIF as above; verify anonymous pull returns 200.
3. **Controller** — keep the install-dir fallback and idempotency guard; swap
   `oras_pull_file <repo>:<old> <name>.tgz` + `tar -xzf` for
   `oras_pull_file <repo>:<new> <name>.sif` + a non-empty check + `chmod a+r`.
   The guard changes from `[ -d dir ]` to `[ -f file.sif ]`.
4. **Start template** — point at the SIF, add the probe + sandbox fallback block
   above, and pass `container_ref` to `singularity run`. Everything else about the
   launch is unchanged (binds, `--env`, `--writable-tmpfs` all work the same for a
   SIF as for a sandbox).
5. **Test both branches**: a live run that uses the SIF directly, and a manual
   `singularity build --fakeroot --force --sandbox <dir> <sif>` +
   `singularity exec <dir> <app> --version` on the target node to prove the
   fallback works there.

## Gotchas

- `singularity build` from `docker://` needs internet — build on the login node or
  your own machine, never in the start template.
- Squashfs-less kernels are common, not exotic (e.g. AWS RHEL9 cluster images):
  the sandbox fallback can be the primary path on a whole cluster. The probe
  handles it unattended.
- Apps that create Unix sockets under `$TMPDIR` (vLLM's ZMQ `ipc://`) crash when it
  points into the deep job dir — socket paths cap at 107 chars. Bind a per-job dir
  to container `/tmp` and set `TMPDIR=/tmp` inside the container instead.
- Derive the cached SIF filename from the tag (`vllm:v1.0` → `vllm-v1.0.sif`) so
  changing the artifact URI re-pulls while old versions stay cached.
- Set `SINGULARITY_TMPDIR` **and** `SINGULARITY_CACHEDIR` under `${HOME}` for both
  build and fallback: `/tmp` is often too small for image builds and is not shared
  across nodes. (Apptainer also accepts the `APPTAINER_*` names; the `SINGULARITY_*`
  ones still work everywhere this repo targets.)
- `--fakeroot` on the fallback build preserves in-container ownership without
  requiring sudo (works on gcpsmall's apptainer 1.4.5 out of the box).
- `chmod a+r` the pulled SIF (the controller may run as a different user than a
  scheduled job in some setups; matches the old `chmod -R a+rX` on sandboxes —
  and is much cheaper: one file instead of a whole tree).
