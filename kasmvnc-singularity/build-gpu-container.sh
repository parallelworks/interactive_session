#!/bin/bash
# Build a GPU-enabled (VirtualGL) KasmVNC Singularity sandbox from a base sandbox.
#
# Usage: build-gpu-container.sh <base_sandbox_dir> <output_sandbox_dir> [def_file]
#
# The base sandbox is the standard kasmvnc-<os> image (pulled from ghcr by the
# controller). This layers VirtualGL + the NVIDIA EGL ICD + a GPU-aware desktop
# launcher on top of it (see kasmvnc-gpu.def). Requires singularity/apptainer
# with fakeroot (or root) and internet access for the VirtualGL package.

set -euo pipefail

BASE="${1:?usage: build-gpu-container.sh <base_sandbox> <output_sandbox> [def]}"
OUT="${2:?usage: build-gpu-container.sh <base_sandbox> <output_sandbox> [def]}"
DEF="${3:-$(cd "$(dirname "$0")" && pwd)/kasmvnc-gpu.def}"

[ -d "${BASE}" ] || { echo "::error::Base sandbox not found: ${BASE}"; exit 1; }
[ -f "${DEF}" ]  || { echo "::error::Definition file not found: ${DEF}"; exit 1; }

SING="$(command -v singularity 2>/dev/null || command -v apptainer 2>/dev/null)"
[ -n "${SING}" ] || { echo "::error::singularity/apptainer not found"; exit 1; }

FAKEROOT=""
if [ "$(id -u)" -ne 0 ]; then
    FAKEROOT="--fakeroot"
fi

# Remove a sandbox directory. Fakeroot builds leave read-only (0555) dirs and
# files owned by mapped subuids that a plain `rm -rf` cannot remove, so escalate:
# chmod (we own them) -> rm -> remove under fakeroot using the base image.
remove_sandbox() {
    local d="$1"
    [ -e "${d}" ] || return 0
    chmod -R u+rwX "${d}" 2>/dev/null || true
    rm -rf "${d}" 2>/dev/null && return 0
    "${SING}" exec ${FAKEROOT} --bind "$(dirname "${d}")":/_p "${BASE}" \
        rm -rf "/_p/$(basename "${d}")" 2>/dev/null || true
    rm -rf "${d}" 2>/dev/null || true
    [ ! -e "${d}" ]
}

tmpout="${OUT}.building.$$"
# Clean our temp dir plus any stale leftovers from previously-failed builds.
for stale in "${OUT}".building.*; do remove_sandbox "${stale}" || true; done
trap 'remove_sandbox "${tmpout}" 2>/dev/null || true' EXIT

echo "::notice::Building GPU container from ${BASE} -> ${OUT}"
# NOTE: singularity disables flag interspersing -- every flag (including
# --build-arg) must come BEFORE the positional <image> <def> arguments.
"${SING}" build ${FAKEROOT} --sandbox --build-arg BASE_SANDBOX="${BASE}" \
    "${tmpout}" "${DEF}"

remove_sandbox "${OUT}" || { echo "::error::failed to remove existing ${OUT}"; exit 1; }
mv "${tmpout}" "${OUT}"
# Sandboxes often contain root-owned, restrictively-permissioned files; make sure
# the running user can read/traverse them (same fix the controller applies to the base).
chmod -R a+rX "${OUT}" 2>/dev/null || true
echo "::notice::GPU container ready: ${OUT}"
