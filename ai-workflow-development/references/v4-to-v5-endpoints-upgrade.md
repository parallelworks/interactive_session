# Upgrading a v4 session workflow to v5 (pw endpoints)

> **Temporary working notes** distilled from the completed conversions —
> **openvscode** (PRs #982–#986), **jupyterlab-host** (`jupyterlab-endpoints`
> branch), and **webshell** (`webshell-endpoint` branch) — all verified end-to-end on
> live runs (2026-07). Use the openvscode and
> jupyterlab `*_v5.yaml` files as the ground truth; this doc explains the deltas and
> the order to apply them. Platform facts live in
> [activate-platform.md](activate-platform.md) (§12 "Endpoint sessions").
>
> **hsp variant (`hsp_v5.yaml`):** same steps, but start from `hsp_v4.yaml`'s form —
> keep the top-level `resource` input and the full hsp `slurm`/`pbs` groups
> (account/qos/cpus_per_task/nodes/node_type) and pass them all through to
> `workflow/script_submitter/v3.6/hsp.yaml` (copy the `with:` block from
> `kasmvnc-container/hsp_v5.yaml`). Also drop the v4 hsp extras: the
> `PW_PLATFORM_HOST=activate.hpc.mil` fallback, the random `password=`, the
> `module load singularity` line, and `service_rootless_docker`. Verified end-to-end
> with `jupyterlab-host/hsp_v5.yaml` on gcpsmall, 2026-07-29 (run completed in ~2 min,
> `{port}` substituted, 200 on `/lab`, anon 307, delete killed the tree); same checks
> passed for the pre-existing `openvscode/hsp_v5.yaml` the same day.
> **Check whether an `hsp_v5.yaml` already exists before writing one** — openvscode's
> shipped with the original endpoints PRs (#976/#982), and "creating" it would have
> clobbered the #1015/#1016 fixes.
>
> **noaa variant (`noaa_v5.yaml`):** same steps, but start from `noaa_v4.yaml`'s form —
> keep the **top-level** `resource` input (not nested under `cluster`) and the noaa
> `slurm` group (account/qos/ntasks/nodes, shown only for `provider == 'existing'`),
> and pass them all through to `workflow/script_submitter/v3.6/noaa.yaml`. Replicate
> `session_runner/v1.4/noaa.yaml`'s extra **"Set Up Install Parent Directory"** step in
> preprocessing, between *Create Inputs* and *Controller Preprocessing* (if
> `service_parent_install_dir` is empty and `/contrib/pw` exists, append it to
> `inputs.sh`) — `script_submitter` does not compute it. Drop the v4 noaa extras: Juice
> lines and the `PW_PLATFORM_HOST=noaa.parallel.works` fallback. Verified end-to-end on
> gcpsmall 2026-07-30 for jupyter-host, jupyterlab-host, webshell, n8n, openvscode, and
> kasmvnc (desktop + rstudio): all runs completed, `{port}` substituted, local 200s,
> anon 307, `pw endpoints delete` killed the trees. Two catches: (1) jupyter-host
> noaa_v4's `conda_install_dir: .miniconda3c` collides with jupyterlab-host's — the
> shared `base` env made `jupyter-notebook` crash with `No module named
> 'jupyter_server.contents'`; use `.miniconda3cn` like the general variants. (2) a
> non-optional `password` field rejects `""` from the CLI `-i` payload — pass a real
> test value. (3) noaa/emed forms carry `existing`-provider-only fields
> (`use_conda`, `install_command`, `*_tag_existing`) that only ever ran against the
> v3 scripts — **check the v4 scripts still support them before wiring the form**.
> `jupyterlab-host/controller-v4.sh` had dropped v3's `install_command` branch and
> unconditionally overwrote `service_load_env` with the conda path (start template
> too), so a NOAA `existing` run fell into the conda-yaml branch with a nonexistent
> `install_command.yaml` (fixed 2026-07-30 by mirroring `jupyter-host/controller-v4.sh`:
> re-add the branch, guard the overwrite with `[ -z "${service_load_env}" ]`). Note the
> ignored `parent_install_dir` NOT appearing in `inputs.sh` on `existing` clusters is
> by design — ignored fields interpolate empty and the `sed '/=""/d'` removes them; the
> "Set Up Install Parent Directory" step appends `/contrib/pw` right after.

## What changes conceptually

| | v4 (sessions) | v5 (endpoints) |
|---|---|---|
| Exposure | `sessions:` block + `session_runner/v1.4` reverse tunnel; URL under `/me/session/<user>/<name>/<slug>` | service wraps itself in `pw endpoints run` (or a `pw-cli` sidecar on k8s); subdomain URL `https://<name>.activate.pw/<slug>` |
| Base path | apps that build absolute URLs need base_url config or an nginx proxy | **none needed** — subdomain endpoints serve at the root (delete the nginx/base-path machinery) |
| Auth | platform login on the session URL | same: endpoints are **platform-authenticated by default** (anon → `307` login redirect), so `token=''`/`--auth=none` keeps v4's trust model |
| Port | `session_runner` allocates `${service_port}` | `pw endpoints run` assigns it — reference it as the literal **`{port}`** token (also env `PORT`), never `${port}` |
| Submission | `session_runner` (wraps script_submitter) | **`script_submitter/v3.6` directly** — preprocessing does the controller + script assembly itself |
| Lifecycle (non-k8s) | run alive for the session's life | run **completes** once the endpoint registers; service outlives it; teardown = `pw endpoints delete <name>` (kills the remote process tree) |
| Lifecycle (k8s) | run alive streaming logs | unchanged — run stays alive; **cancel run = teardown** (a Deployment restarts an exited sidecar, so the endpoint can't own the pod lifecycle) |

Endpoint name convention: **`<service-name>-${PW_RUN_SLUG}`** — built in preprocessing,
polled in `wait_for_endpoint`. Both jobs see the same value because `PW_RUN_SLUG` is
run-scoped, and it reaches compute nodes via the `inputs.sh` `env | grep '^PW_'` capture.

## Step 1 — `controller-v4.sh` (copy from `controller-v3.sh`, then strip)

- Delete everything that existed only to serve the session: **nginx** (sif download,
  configs), **Juice**, base-path helpers.
- Keep the actual install logic (download/conda/etc.), idempotent as before.
- Keep the final "executable exists or `exit 1`" check.

## Step 2 — `start-template-v4.sh` (the real rewrite)

Contract differences vs v3:
- **No `cancel.sh`, no `sleep inf`, no port allocation.** The YAML prepends a generic
  cleanup trap; `pw endpoints run` runs the server in the **foreground** and is itself
  the thing that keeps the job alive.
  - **Exception:** if the service spawns a daemon that escapes the endpoint's process
    tree (webshell's shared `screen` session), DO write a `cancel.sh` that kills it —
    the generic trap runs `./cancel.sh` on teardown, and `script_submitter`'s
    `define_cleanup_script: true` + `cleanup_script_path: ./cancel.sh` runs it on
    cancel-before-ready. Write it to the script's CWD (relative `> cancel.sh`): the
    script runs from `subworkflows/session_runner/step_0/`, which is also where the
    trap and the cleanup step look. Verified: `pw endpoints delete` → tree killed →
    trap fires → screen quit (webshell live run).
- Launch shape (see `jupyterlab-host/start-template-v4.sh`, `openvscode/start-template-v4.sh`):
  ```bash
  pw endpoints run ${pw_endpoints_args} -- <server-cmd> --port {port} ...
  if [ $? -ne 0 ]; then
      echo "::error title=Error::pw endpoints command failed"
      # Fail loud: without this, wait_for_endpoint polls forever
      pw workflows runs cancel ${PW_RUN_SLUG}
      exit 1
  fi
  ```
- **Delete base-path handling.** Jupyter's config shrinks to root_dir +
  `allow_remote_access` + auth; no `basepath`, no nginx. (Path-based endpoints via
  `--no-subdomain` would use the `{path}` token instead — not used by the repo's v5s.)
- **Apps that build absolute URLs** (n8n's `N8N_EDITOR_BASE_URL`/`WEBHOOK_URL`) read
  the public URL from **`PW_ENDPOINT_URL`**, exported by `pw endpoints run` to the
  wrapped command (also exported: `PORT`, `PW_ENDPOINT_HOST`, `PW_ENDPOINT_PATH`).
  Since these are unknown before launch, generate a **launcher script** that
  references `${PORT}`/`${PW_ENDPOINT_URL}` and run
  `pw endpoints run ${pw_endpoints_args} -- ./launch-<svc>.sh` — this also sidesteps
  nested-quoting pain for container commands (verified: n8n logs "Editor is now
  accessible via <endpoint URL>").
- **Daemon-owned services need `cancel.sh`** (exception to "no cancel.sh"): anything
  that escapes the endpoint's process tree — webshell's `screen`, docker containers
  (owned by dockerd) — gets a `cancel.sh` that kills it; the generic trap runs it on
  teardown. For docker, keep a foreground `docker logs -f <name>` as the endpoint's
  liveness process and name the container by `${PW_RUN_SLUG}` (the port is unknown
  when `cancel.sh` is written). Write `cancel.sh` to the script's CWD.
- **Singularity SIF vs sandbox:** ship a SIF (ORAS artifact on ghcr) and test
  `singularity exec <sif> /bin/true` **in the start template** (the execution node —
  login vs compute support can differ); on failure build a sandbox once:
  `singularity build --fakeroot --force --sandbox <dir> <sif>` with
  `SINGULARITY_TMPDIR`/`SINGULARITY_CACHEDIR` under `${HOME}` (both paths verified on
  gcpsmall, n8n conversion). Full build/push/convert recipe:
  [singularity-sif-containers.md](singularity-sif-containers.md).
- Password/token: optional password → hash it (`jupyter_server.auth.passwd` via a
  python heredoc — avoids shell-quoting the `$`-laden hash); none → `token = ''` is
  fine because the endpoint already requires platform login.

## Step 3 — `general_v5.yaml` (diff your `general_v4.yaml` against openvscode/jupyterlab v5)

1. **Delete the top-level `sessions:` block.**
2. **Create Inputs**: drop `basepath=` and Juice lines; add
   `pw_endpoints_args="--name ${{ inputs.service.name }}-${PW_RUN_SLUG} --slug <slug>"`
   (slug examples: `lab`, `?folder=${{ inputs.service.directory }}`, `""`).
3. **Add two preprocessing steps** (copy verbatim from a v5): *Controller
   Preprocessing* (cat inputs.sh + controller-v4.sh, run it inline) and *Create
   Service Script* (inputs.sh + generic cleanup trap heredoc + start-template-v4.sh;
   emits `SCRIPT_PATH` and `SKIP_CLEANUP_PATH` outputs).
4. **Replace the session_runner `with:` block** with `script_submitter/v3.6`:
   `use_existing_script: true`, `script_path: ${{ needs.preprocessing.outputs.SCRIPT_PATH }}`,
   `define_cleanup_script: true`, `cleanup_script_path: ./cancel.sh`,
   `submit_and_exit: false`, `skip_cleanups_file: ${{ needs.preprocessing.outputs.SKIP_CLEANUP_PATH }}`,
   plus the same `scheduler`/`slurm`/`pbs` mappings as v4.
5. **Add the `wait_for_endpoint` job**: poll `pw endpoints list` for the name every
   10 s; on success `touch` the SKIP_CLEANUP file and `parallelworks/cancel-jobs` the
   submitter — that's what lets the run complete while the service lives on.
6. Form: keep the v4 `cluster`/`service` groups; drop the `juice` group.
7. `parallelworks/checkout` → your **dev branch** while testing; **flip to `main`
   after merge** (both openvscode and jupyterlab needed this follow-up).

## Step 4 — `general_k8s_v5.yaml`

Start from `workflow/yamls/jupyterlab-host/general_k8s_v5.yaml` (it includes two
improvements over openvscode's): all of Step 3, plus:

- Top-level `env: { PW_API_KEY: ${PW_API_KEY} }`.
- **Delete the k8s `Service` manifest and the `update-session` job.** Instead add a
  **`pw-cli` sidecar** to the Deployment: `ghcr.io/parallelworks/pw-cli:v7.79.0`,
  args `endpoints http --name <name>-${PW_RUN_SLUG} --slug <slug> --output text <port>`,
  env `PW_PLATFORM_HOST` (inline) + `PW_API_KEY` from a Secret.
- **Create API Key Secret** step (idempotent `kubectl create secret … --dry-run=client
  -o yaml | kubectl apply -f -`) with a `cleanup:` that deletes it. Cleanup order ends
  up: deployment → secret → PVC (reverse step order) — correct dependency order.
- `Stream Logs` gets `--all-containers` (sidecar logs are your endpoint diagnostics).
- Replace `create_k8s_session` with `wait_for_endpoint_k8s` (waits for `pod.running`,
  then polls `pw endpoints list`).
- **No `skip_cleanups_file` on the k8s path** — the run must stay alive (log
  streaming) and cancel-run is the teardown.
- Guard *Controller Preprocessing* and *Create Service Script* with
  `if: ${{ inputs.resource.type != 'kubernetes' }}` so a k8s run doesn't install the
  non-k8s software on the workspace exec node (jupyterlab improvement; openvscode
  installs unconditionally).
- App container: prefer a container-agnostic launch (`command: ["jupyter","lab"]` +
  explicit `--ServerApp.port=<image_port>`) over image-specific entrypoint scripts.

## Step 5 — Test end to end (what "done" means)

```bash
pw workflows run --dry-run -i '{"cluster":{"resource":"<name>","scheduler":false}}' /abs/path/general_v5.yaml
pw workflows create <wf> --yaml /abs/path/general_v5.yaml     # ABSOLUTE path (see gotcha)
pw workflows run <wf> -i '{"cluster":{"resource":"<name>","scheduler":false}}' --name t1 -o json
```
Then verify, in order:
1. `pw endpoints list` shows `<service>-<run-slug>` **running** with its URL.
2. Non-k8s: the **run completes** on its own (wait_for_endpoint fired); the service
   process (`pw endpoints run … -- <server> --port <realport>`) is alive — `{port}`
   was substituted with a number.
3. `curl localhost:<realport>/<slug>` returns the app (200/expected title); the
   public URL returns `307 → …?sessionRedirect=…` for anonymous curl (platform auth).
4. Teardown: non-k8s `pw endpoints delete <name>` kills the process tree; k8s
   `pw workflows runs cancel <slug>` deletes deployment/secret/PVC and the endpoint
   drops off `pw endpoints list` within seconds.
5. k8s CLI runs need the resource **object** (compute-resources doesn't hydrate bare
   names): `{"id":"<pw kube ls id>","name":"<k8s-cluster>","type":"kubernetes","uri":"pw://<name>"}`.

## Discovering v5 endpoint sessions programmatically (verified)

In `pw sessions ls -o json`, an endpoint session has `type: "endpoint"`,
`openAI` set by `--openai`, its **local port in `software.port`** (top-level
`remotePort` is 0), and **no `targetName`/`targetType`** — the hosting resource
is not recorded. A workflow that must be found by another agent therefore tags
itself via `--description` (returned verbatim in the session row): the agent
fleet uses `--description agent-worker:<cluster>`, and `agent-orchestrator`'s
`discover_workers()` accepts both this and the v4 tunnel-session shape
(verified live: workspace orchestrator → lite-agent endpoint worker on gcpsmall,
full ask_cluster round trip).

## Gotchas checklist (each one bit a real run)

- **Step `cleanup:` runs when its JOB ends — on success too — not at workflow end**
  (verified 2026-07-29, librechat hsp_v5 run 00001). A preprocessing-step cleanup
  guarded by `[ -f "${PWD}/SKIP_CLEANUP" ]` always fires before `wait_for_endpoint`
  can touch that file, so it deleted the librechat_dir lock while the service ran.
  Guard job-scoped cleanups with a completion marker the job's LAST step writes
  (`touch PREPROCESSING_DONE`; see `librechat-container/hsp_v5.yaml`) — only
  cross-job cleanups (e.g. session_runner's) can use the SKIP_CLEANUP file.
  `hsp-all_v5.yaml`'s librechat Lock cleanup still carries the broken guard.
- **hsp conversions of services that used `session_runner/v1.4/hsp.yaml` must
  replicate its shared-install-dir step**: derive `service_parent_install_dir` from
  `PROJECTS_HOME` (`${PROJECTS_HOME}/hsp`, falling back to `${HOME}/pw`) in
  preprocessing — `script_submitter` does not compute it (copy the block from
  `hsp-all_v5.yaml` / `librechat-container/hsp_v5.yaml`).

- **The endpoint proxy preserves the public Host header** (`<name>.activate.pw`).
  An app with a DNS-rebinding/host guard (hermes dashboard v0.17+) passes every
  local curl and then 400s "Invalid Host header" for real users — and the
  anonymous-curl 307 check does NOT catch it (auth redirects before the app).
  Fix: `pw endpoints run --rewrite-host=localhost`. Catch it pre-launch with
  `curl -H "Host: <public-domain>" localhost:<port>` (verified: hermes-agent).

- `{port}` **token, not `${port}`** — shell expands `${port}` to empty before `pw`
  sees it and the app falls back to its default port.
- `pw workflows create/update --yaml <path>`: an unreadable path still creates the
  workflow **empty**; always pass absolute paths.
- `pw workflows run` uses the **stored** definition — `update` after every YAML edit.
- Checkout `branch:` left pointing at a merged-and-deleted dev branch breaks future
  runs — flip to `main` right after merge.
- Deleting the endpoint on k8s does NOT tear anything down — the Deployment restarts
  the sidecar and it re-registers. Cancel the run instead.
- Don't hand-verify with `--dry-run` alone; the four checks in Step 5 are the test.
- The ttyd bundled in `downloads/vnc/noVNC-1.3.0.tgz` is a 1.7.1 fork with a
  `-R/--readonly` flag — **writable by default**, unlike upstream ttyd ≥1.7 which is
  read-only without `-W`. No writable flag needed (verified over the ws protocol).
- A root-slug service (webshell) just omits `--slug` from `pw_endpoints_args` —
  `--slug ""` risks the empty token being eaten by the arg parser.
