#!/bin/bash
# Ensure the NVIDIA OpenGL/EGL *userspace* libraries matching the running kernel
# driver are present on the host. Singularity `--nv` injects whatever NVIDIA libs
# exist on the host into the container; many cloud GPU images ship only the
# compute/CUDA userspace, so libGLX_nvidia / libEGL_nvidia are missing and
# VirtualGL has no GPU to render on.
#
# This fetches the matching NVIDIA .run for the *running* driver version, extracts
# only the GL/EGL userspace .so files, and installs them into /usr/lib64 (no
# kernel modules are touched). Idempotent and best-effort: it never fails the
# caller -- if anything is missing the desktop simply falls back to software GL.
#
# Usage: install-host-nvidia-gl.sh

log() { echo "[host-nvidia-gl] $*"; }

# Only relevant on NVIDIA GPU hosts.
command -v nvidia-smi >/dev/null 2>&1 || { log "no nvidia-smi; skipping"; exit 0; }
nvidia-smi -L >/dev/null 2>&1            || { log "no usable GPU; skipping"; exit 0; }

# Already have the OpenGL + EGL userspace? Then nothing to do.
if ls /usr/lib64/libGLX_nvidia.so.* >/dev/null 2>&1 \
   && ls /usr/lib64/libEGL_nvidia.so.* >/dev/null 2>&1; then
    log "NVIDIA GL/EGL userspace already present; nothing to do"
    exit 0
fi

VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "${VER}" ] || { log "could not determine driver version; skipping"; exit 0; }
log "kernel driver ${VER}; GL/EGL userspace missing -> installing matching userspace"

# Need root to write /usr/lib64.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then SUDO="sudo -n"; else
        log "no root / passwordless sudo; cannot install host GL userspace (will fall back to software)"
        exit 0
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
RUN="NVIDIA-Linux-x86_64-${VER}.run"
URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${VER}/${RUN}"

log "downloading ${URL}"
curl -fSL -o "${WORK}/${RUN}" "${URL}" || { log "download failed; skipping"; exit 0; }
chmod +x "${WORK}/${RUN}"
( cd "${WORK}" && ./"${RUN}" --extract-only --target nvx >/dev/null 2>&1 ) \
    || { log "extract failed; skipping"; exit 0; }
SRC="${WORK}/nvx"
[ -d "${SRC}" ] || { log "extracted tree missing; skipping"; exit 0; }

# Versioned GL/EGL userspace libraries (no kernel modules, no nvidia-smi, no glvnd).
copied=0
for lib in libGLX_nvidia libEGL_nvidia libGLESv2_nvidia libGLESv1_CM_nvidia \
           libnvidia-glcore libnvidia-eglcore libnvidia-glsi libnvidia-tls \
           libnvidia-glvkspirv libnvidia-rtcore libnvidia-allocator; do
    f="${SRC}/${lib}.so.${VER}"
    if [ -f "${f}" ]; then
        ${SUDO} install -m 0755 "${f}" /usr/lib64/ && copied=$((copied + 1))
    fi
done
log "installed ${copied} NVIDIA GL/EGL userspace libraries into /usr/lib64"

# SONAME symlinks expected by glvnd / Singularity --nv.
${SUDO} ln -sf "libGLX_nvidia.so.${VER}"       /usr/lib64/libGLX_nvidia.so.0       2>/dev/null || true
${SUDO} ln -sf "libEGL_nvidia.so.${VER}"       /usr/lib64/libEGL_nvidia.so.0       2>/dev/null || true
${SUDO} ln -sf "libGLESv2_nvidia.so.${VER}"    /usr/lib64/libGLESv2_nvidia.so.2    2>/dev/null || true
${SUDO} ln -sf "libGLESv1_CM_nvidia.so.${VER}" /usr/lib64/libGLESv1_CM_nvidia.so.1 2>/dev/null || true
${SUDO} ln -sf "libnvidia-allocator.so.${VER}" /usr/lib64/libnvidia-allocator.so.1 2>/dev/null || true

# Host-side EGL vendor ICD (harmless; the container ships its own copy too).
if [ ! -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
    ${SUDO} mkdir -p /usr/share/glvnd/egl_vendor.d
    printf '%s\n' \
        '{' \
        '    "file_format_version" : "1.0.0",' \
        '    "ICD" : {' \
        '        "library_path" : "libEGL_nvidia.so.0"' \
        '    }' \
        '}' | ${SUDO} tee /usr/share/glvnd/egl_vendor.d/10_nvidia.json >/dev/null
fi

${SUDO} ldconfig
log "done"
