#!/bin/bash
# Provision the NVIDIA OpenGL/EGL *userspace* libraries matching the running
# kernel driver so the KasmVNC/VirtualGL container can render on the GPU.
#
# Singularity `--nv` injects whatever NVIDIA libs exist on the host, but many
# cloud GPU images ship only the compute/CUDA userspace -- libGLX_nvidia /
# libEGL_nvidia are missing, so VirtualGL has no GPU OpenGL to use. This fetches
# the matching NVIDIA .run for the *running* driver version and extracts the
# GL/EGL userspace .so files (no kernel modules are touched). Two modes:
#
#   * root / passwddless sudo -> install system-wide into /usr/lib64; --nv then
#     injects them into the container automatically.
#   * no root -> extract into a user-writable dir ($service_parent_install_dir/
#     nvidia-gl). The start script bind-mounts these into the container's
#     /usr/lib64 at run time, so GPU rendering still works without root.
#
# Idempotent and best-effort: it never fails the caller. If nothing can be
# provisioned the desktop simply falls back to software (llvmpipe) rendering.
#
# Usage: install-host-nvidia-gl.sh

log() { echo "[host-nvidia-gl] $*"; }

# Only relevant on NVIDIA GPU hosts.
command -v nvidia-smi >/dev/null 2>&1 || { log "no nvidia-smi; skipping"; exit 0; }
nvidia-smi -L >/dev/null 2>&1            || { log "no usable GPU; skipping"; exit 0; }

# Already have the OpenGL + EGL userspace system-wide? Then --nv handles it.
if ls /usr/lib64/libGLX_nvidia.so.* >/dev/null 2>&1 \
   && ls /usr/lib64/libEGL_nvidia.so.* >/dev/null 2>&1; then
    log "NVIDIA GL/EGL userspace already present in /usr/lib64; nothing to do"
    exit 0
fi

VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "${VER}" ] || { log "could not determine driver version; skipping"; exit 0; }

# Pick install mode: system-wide if we have root, otherwise a user-local dir that
# the start script binds into the container.
GLUSERDIR="${service_parent_install_dir:-${HOME}/pw/software}/nvidia-gl"
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    MODE=system; DEST=/usr/lib64
elif sudo -n true 2>/dev/null; then
    MODE=system; DEST=/usr/lib64; SUDO="sudo -n"
else
    MODE=user; DEST="${GLUSERDIR}"
    # Idempotent: already provisioned for this exact driver version?
    if [ -e "${GLUSERDIR}/libEGL_nvidia.so.0" ] \
       && [ "$(cat "${GLUSERDIR}/.driver_version" 2>/dev/null)" = "${VER}" ]; then
        log "user-mode GL userspace ${VER} already present in ${GLUSERDIR}; nothing to do"
        exit 0
    fi
    rm -rf "${GLUSERDIR}" 2>/dev/null
    mkdir -p "${GLUSERDIR}" || { log "cannot create ${GLUSERDIR}; skipping"; exit 0; }
fi
log "kernel driver ${VER}; GL/EGL userspace missing -> provisioning (${MODE} mode) into ${DEST}"

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
        ${SUDO} install -m 0755 "${f}" "${DEST}/" && copied=$((copied + 1))
    fi
done
log "provisioned ${copied} NVIDIA GL/EGL userspace libraries into ${DEST}"

# SONAME symlinks expected by glvnd / the dynamic loader.
${SUDO} ln -sf "libGLX_nvidia.so.${VER}"       "${DEST}/libGLX_nvidia.so.0"       2>/dev/null || true
${SUDO} ln -sf "libEGL_nvidia.so.${VER}"       "${DEST}/libEGL_nvidia.so.0"       2>/dev/null || true
${SUDO} ln -sf "libGLESv2_nvidia.so.${VER}"    "${DEST}/libGLESv2_nvidia.so.2"    2>/dev/null || true
${SUDO} ln -sf "libGLESv1_CM_nvidia.so.${VER}" "${DEST}/libGLESv1_CM_nvidia.so.1" 2>/dev/null || true
${SUDO} ln -sf "libnvidia-allocator.so.${VER}" "${DEST}/libnvidia-allocator.so.1" 2>/dev/null || true

if [ "${MODE}" = system ]; then
    # EGL vendor ICD (harmless; the container ships its own copy too).
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
    log "done (system-wide; Singularity --nv will inject these)"
else
    echo "${VER}" > "${GLUSERDIR}/.driver_version"
    log "done (user-mode; the start script will bind ${GLUSERDIR} into the container)"
fi
