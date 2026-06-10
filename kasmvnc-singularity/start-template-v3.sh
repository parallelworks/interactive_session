#!/bin/bash
# start.sh - Desktop Startup Script (runs on compute node)
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.

set -ex

echo "::group::Desktop Service Starting (Compute Node)"

# Container runtime selection. Prefer apptainer over singularity: apptainer mounts
# SIFs rootless (it bundles squashfuse/fuse-overlayfs), and a SIF -- being a single
# file -- reads reliably on parallel filesystems (Lustre/GPFS/WEKA/NFS) where an
# exploded sandbox directory returns truncated reads that corrupt Perl/Python at
# startup. Older setuid-mode singularity (no suid bit, no FUSE) cannot mount a SIF
# unprivileged and is forced onto the unreliable sandbox path.
# Works whether the runtime is already in PATH or must be loaded via environment
# modules, so it is portable across the many systems this script runs on. Every
# later invocation uses ${CONTAINER}.
CONTAINER=""
if command -v apptainer &>/dev/null; then
    CONTAINER=apptainer
elif module load apptainer &>/dev/null && command -v apptainer &>/dev/null; then
    CONTAINER=apptainer
    echo "::notice::Loaded apptainer module"
elif command -v singularity &>/dev/null; then
    CONTAINER=singularity
elif module load singularity &>/dev/null && command -v singularity &>/dev/null; then
    CONTAINER=singularity
    echo "::notice::Loaded singularity module"
else
    echo "::error title=Error::Neither apptainer nor singularity found in PATH or via environment modules"
    exit 1
fi
echo "::notice::Using container runtime: ${CONTAINER} ($(${CONTAINER} --version 2>/dev/null))"

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

# Container image candidates, in order of preference. The actual choice is made
# below, once we know whether this Singularity can mount a SIF unprivileged:
#   1. SIF                (GPU; reads reliably on parallel filesystems) if mountable
#   2. GPU sandbox dir    (VirtualGL) in place
#   3. base sandbox dir   (software, no GPU) -- runs everywhere, the guaranteed floor
container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu
container_sif=${container_dir}.sif
base_container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
echo "mv cancel.sh cancel.sh.executed" >> cancel.sh


find_available_display() {
    local minPort=5901
    local maxPort=5999
    local port displayNumber x11Port
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        displayNumber=${port: -2}
        XdisplayNumber=${displayNumber#0}

        # Check if VNC port (5900+display) is in use
        if netstat -aln | grep -q "LISTEN.*:${port}\b" 2>/dev/null; then
            continue
        fi
        # Check if X11 TCP port (6000+display) is in use (e.g. SSH X11 forwarding)
        x11Port=$((6000 + XdisplayNumber))
        if netstat -aln | grep -q "LISTEN.*:${x11Port}\b" 2>/dev/null; then
            continue
        fi
        # Check for X11 socket/lock files (filesystem and abstract Unix domain sockets)
        # Abstract sockets are held in kernel namespace and won't appear under /tmp/.X11-unix/
        # but are visible via ss -xl; Singularity shares the host network namespace so the
        # container would collide with them.
        if [ -e "/tmp/.X11-unix/X${XdisplayNumber}" ] || [ -e "/tmp/.X${XdisplayNumber}-lock" ]; then
            continue
        fi
        if ss -xl 2>/dev/null | grep -qE "\.X11-unix/X${XdisplayNumber}([^0-9]|$)"; then
            continue
        fi
        if pgrep -f "(Xvnc|Xorg|Xvfb) :${XdisplayNumber}( |$)" > /dev/null 2>&1; then
            continue
        fi

        export displayPort=${port}
        export DISPLAY=":${XdisplayNumber}"
        return 0
    done
    return 1
}

find_available_display || { echo "::error::No available display found"; exit 1; }


echo "::notice::Starting KasmVNC Container..."

# Auto-detect GPU support for Singularity --nv flag
GPU_FLAG=""
if command -v nvidia-smi &>/dev/null && nvidia-smi --list-gpus &>/dev/null; then
    GPU_FLAG="--nv"
    echo "::notice::NVIDIA GPU detected, enabling Singularity --nv flag"
else
    echo "::notice::No NVIDIA GPU detected, running without --nv"
fi

# This script runs on the compute node, where the GPU (if any) actually is. For
# hardware rendering with a GPU present, make sure the host has the NVIDIA OpenGL/
# EGL userspace so that Singularity --nv can inject it into the container for
# VirtualGL (many cloud GPU images ship compute-only drivers). Best-effort and
# idempotent; the container falls back to software if it can't be provisioned.
# Skipped entirely for software rendering.
NV_GL_BIND_FLAGS=""
if [ "${rendering}" = "hardware" ] && [ -n "${GPU_FLAG}" ]; then
    # Locate this runtime's helper scripts. The platform concatenates this template
    # into a run-dir script, so ${BASH_SOURCE} is unreliable -- probe known paths.
    kasm_src_dir=""
    for _d in "${PW_PARENT_JOB_DIR}/kasmvnc-singularity" \
              "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" \
              "$(pwd)/kasmvnc-singularity" "$(pwd)"; do
        if [ -n "${_d}" ] && [ -f "${_d}/install-host-nvidia-gl.sh" ]; then
            kasm_src_dir="${_d}"
            break
        fi
    done
    if [ -n "${kasm_src_dir}" ]; then
        bash "${kasm_src_dir}/install-host-nvidia-gl.sh" || echo "::warning::host NVIDIA GL setup skipped/failed"
    fi

    # When the host lacks root, install-host-nvidia-gl.sh extracts the NVIDIA GL/EGL
    # userspace into a user-writable dir instead of /usr/lib64. Bind those libraries
    # into the container's /usr/lib64 (where the loader and the EGL ICD look) so GPU
    # rendering works without root. If GL was installed system-wide (root) this dir
    # won't exist and --nv injects the libraries directly instead.
    nv_gl_userdir="${service_parent_install_dir}/nvidia-gl"
    if [ -e "${nv_gl_userdir}/libEGL_nvidia.so.0" ]; then
        for _lib in "${nv_gl_userdir}"/*.so*; do
            [ -e "${_lib}" ] || continue
            _real="$(readlink -f "${_lib}")"
            NV_GL_BIND_FLAGS="${NV_GL_BIND_FLAGS} --bind ${_real}:/usr/lib64/$(basename "${_lib}")"
        done
        echo "::notice::Binding rootless NVIDIA GL userspace from ${nv_gl_userdir} into the container"
    fi
fi

# Directories auto-mounted when present. Absence is normal across the many systems
# this runs on, so missing auto-mounts are skipped silently (debug, not warning).
default_mount_directories="${HOME} /p/work /p/work1 /p/app /p/cwfs /scratch /run/munge /etc/pbs.conf /var/spool/pbs /opt/pbs"

# User-requested mounts come from the 'container_mount_paths' editor input (one path
# per line). Strip any CR a browser editor may have added so existence checks don't
# fail on a trailing '\r'.
container_mount_paths=$(printf '%s' "${container_mount_paths}" | tr -d '\r')

# Build "--bind dir" flags for directories that exist. With warn_missing="warn" a
# user-visible warning is emitted for absent paths (used for the user-requested
# paths); the auto-mount defaults stay silent.
build_mount_flags() {
    local directories="$1"
    local warn_missing="$2"
    local flags="" dir

    for dir in ${directories}; do
        if [ -e "${dir}" ]; then
            flags="${flags} --bind ${dir}"
            echo "::debug::Mount: ${dir} exists, adding to bind mounts" >&2
        elif [ "${warn_missing}" = "warn" ]; then
            echo "::warning::Mount path '${dir}' does not exist on this host; skipping" >&2
        else
            echo "::debug::Mount: ${dir} does not exist, skipping" >&2
        fi
    done

    echo "${flags}"
}

# Build mount flags: silent for the auto-mounted defaults, warn for user-requested paths
MOUNT_FLAGS="$(build_mount_flags "${default_mount_directories}") $(build_mount_flags "${container_mount_paths}" warn)"
echo "::notice::Mount flags: ${MOUNT_FLAGS}"

touch empty
chmod 644 empty
touch error.log
chmod 666 error.log

# Create a per-job /tmp to avoid cross-user permission conflicts on shared nodes
# (Singularity bind-mounts host /tmp by default; container entrypoint writes /tmp/env.sh)
mkdir -p $PWD/container_tmp
# Pre-create .X11-unix so Xvnc doesn't fail trying to mkdir it as root under --userns
mkdir -p $PWD/container_tmp/.X11-unix
# Writable XKB dir: under --userns /var/lib/xkb is read-only inside the image,
# so xkbcomp can't write the compiled keymap and Xvnc fails to activate the keyboard.
mkdir -p $PWD/xkb
echo "rm -rf $PWD/container_tmp" >> cancel.sh
echo "rm -rf $PWD/xkb" >> cancel.sh

# Unset host env vars that corrupt the container's runtime.
# On Cray EX systems, LD_LIBRARY_PATH carries PE paths (libsci, mpich, cce) that
# cause Python/Perl inside the container to load incompatible native libraries.
# PYTHONSTARTUP points to a host file that doesn't exist in the container.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Only bind /etc/environment if it's safe (simple key=value, no shell control flow).
# Some systems have shell syntax in /etc/environment that breaks Singularity's 95-apps.sh.
ETC_ENV_FLAG=""
if [ -f /etc/environment ] && ! grep -qE '^\s*(if|for|while|case|do|then|function)\b' /etc/environment 2>/dev/null; then
    ETC_ENV_FLAG="--bind /etc/environment:/etc/environment:ro"
else
    echo "::warning::Skipping /etc/environment bind (file missing or contains shell syntax)"
fi

USERNS_FLAG=""
WRITABLE_TMPFS_FLAG=""
_sing_bin=$(command -v "${CONTAINER}" 2>/dev/null)
if [ -n "${_sing_bin}" ] && ! test -u "${_sing_bin}"; then
    # No setuid bit: unprivileged installation requires --userns
    USERNS_FLAG="--userns"
    echo "::notice::${CONTAINER} has no setuid bit, enabling --userns"
elif df -T "${service_parent_install_dir}/containers" 2>/dev/null | awk 'NR==2{print $2}' | grep -qi lustre; then
    echo "::notice::Container is on a Lustre filesystem, skipping --writable-tmpfs (overlay not supported)"
else
    WRITABLE_TMPFS_FLAG="--writable-tmpfs"
fi

# Build the ordered list of container-image candidates (most preferred first). The
# run loop tries each and falls through to the next if the container won't stay up.
# Software rendering (the default) uses only the base container, the old way.
# Hardware rendering uses ONLY the GPU images and fails if none run (no base fallback):
#   1. SIF             (GPU; reliable reads on parallel FS) -- only if this
#                       Singularity can actually mount a SIF unprivileged (some site
#                       builds are setuid-mode w/o the suid bit and no FUSE fallback,
#                       failing with "No setuid installation found")
#   2. GPU sandbox dir (VirtualGL) -- GPU where sandbox reads are clean
# Container paths contain no spaces, so a space-separated list is safe.
container_candidates=""
if [ "${rendering}" = "hardware" ]; then
    if [ -f "${container_sif}" ]; then
        if ${CONTAINER} exec ${USERNS_FLAG} "${container_sif}" true >/dev/null 2>&1; then
            container_candidates="${container_candidates} ${container_sif}"
        else
            echo "::warning::SIF present but ${CONTAINER} cannot mount it unprivileged; skipping SIF"
        fi
    fi
    [ -d "${container_dir}" ]      && container_candidates="${container_candidates} ${container_dir}"
    # Hardware rendering does NOT fall back to the base (software) container -- if
    # neither the SIF nor the GPU sandbox is usable, the empty-candidates check
    # below fails the job.
else
    # Software rendering (default): base container only.
    container_candidates="${base_container_dir}"
fi
container_candidates=$(echo ${container_candidates})   # trim leading/trailing space
if [ -z "${container_candidates}" ]; then
    echo "::error::No usable container image found (looked for ${container_sif}, ${container_dir}, ${base_container_dir})"
    exit 1
fi
echo "::notice::Rendering mode: ${rendering:-software}; container image candidates (in order): ${container_candidates}"

env

# Try each candidate; per candidate retry a couple of times on a fresh display in
# case of a display collision. Fall through to the next candidate if the container
# does not stay up (a SIF that can't be mounted, or a sandbox with truncated reads).
display_tries_per_image=2
kasmvnc_container_pid=""
container_image=""
started=""
_launched=""
for _cand in ${container_candidates}; do
    echo "::notice::Trying container image: ${_cand}"
    _try=0
    while [ ${_try} -lt ${display_tries_per_image} ]; do
        _try=$((_try + 1))
        if [ -n "${_launched}" ]; then
            rm -rf $PWD/container_tmp $PWD/xkb
            find_available_display || { echo "::error::No available display found"; exit 1; }
        fi
        _launched=1
        mkdir -p $PWD/container_tmp/.X11-unix
        mkdir -p $PWD/xkb

        echo "::notice::Starting KasmVNC container on display :${XdisplayNumber} (image: ${_cand}, try ${_try}/${display_tries_per_image})..."
        set -x
        ${CONTAINER} run \
            ${WRITABLE_TMPFS_FLAG} ${USERNS_FLAG} ${ETC_ENV_FLAG} \
            ${GPU_FLAG} \
            ${NV_GL_BIND_FLAGS} \
            ${MOUNT_FLAGS} \
            --env XAUTHORITY=/tmp/.Xauthority \
            --env DISPLAY=":${XdisplayNumber}" \
            --env BASE_PATH="${basepath}" \
            --env NGINX_PORT="${service_port}" \
            --env KASM_PORT=$(pw agent open-port) \
            --env VNC_DISPLAY="${XdisplayNumber}" \
            --bind /etc/passwd:/etc/passwd:ro \
            --bind /etc/group:/etc/group:ro \
            --bind /etc/ssl/certs:/etc/ssl/certs:ro \
            --bind $PWD/empty:/etc/nginx/conf.d/default.conf \
            --bind $PWD/error.log:/var/log/nginx/error.log \
            --bind $PWD/container_tmp:/tmp \
            --bind $PWD/xkb:/var/lib/xkb \
            "${_cand}" &
        set +x
        kasmvnc_container_pid=$!
        echo "::notice::KasmVNC container started with PID ${kasmvnc_container_pid} (image: ${_cand})"

        sleep 20
        if kill -0 "${kasmvnc_container_pid}" 2>/dev/null; then
            started=1
            container_image="${_cand}"
            break
        fi
        echo "::warning::Container (${_cand}) exited within 20s on display :${XdisplayNumber}"
    done
    [ -n "${started}" ] && break
    echo "::warning::Image ${_cand} did not stay up; falling back to the next image"
done

if [ -z "${started}" ]; then
    echo "::error::KasmVNC failed to start with any image"
    exit 1
fi
echo "::notice::KasmVNC running (image: ${container_image}, PID ${kasmvnc_container_pid})"

# Register cleanup for the running container and its display.
echo "kill ${kasmvnc_container_pid} #kasmvnc_container_pid" >> cancel.sh
echo "pkill -TERM -f \"Xvnc :${XdisplayNumber}\"" >> cancel.sh
echo "sleep 3" >> cancel.sh
echo "pkill -KILL -f \"Xvnc :${XdisplayNumber}\"" >> cancel.sh

sleep 5

if ! kill -0 "${kasmvnc_container_pid}" 2>/dev/null; then
    echo "::error::KasmVNC failed to start"
    exit 1
fi

xauthority_file=""
echo "::notice::Waiting for .Xauthority file"
for i in $(seq 1 10); do
    xauthority_file=$(find container_tmp -name .Xauthority 2>/dev/null | head -1)
    if [ -n "${xauthority_file}" ]; then
        break
    fi
    echo "Waiting for .Xauthority file (attempt ${i}/10)..."
    sleep 5
done
if [ -n "${xauthority_file}" ]; then
    export XAUTHORITY="${PWD}/${xauthority_file}"
    echo "::notice::Setting XAUTHORITY to ${XAUTHORITY}"
else
    echo "::warning::.Xauthority file not found after 10 attempts"
fi
# Wait some time for display to be ready
sleep 20
xterm_cmd="$(which xterm 2>/dev/null || echo ${service_parent_install_dir}/tools/xterm)"
export DISPLAY=":${XdisplayNumber}"
run_xterm_loop(){
    while true; do
        echo "::notice::Starting xterm with ${xterm_cmd}"
        ${xterm_cmd} -fa "DejaVu Sans Mono" -fs 12 -e bash -c '
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║              Welcome to your Remote Desktop Session          ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "\n"
printf "This terminal runs directly on the cluster node — not inside the\n"
printf "desktop environment. If you close it, it will automatically reopen.\n\n"
printf "The desktop you see in your browser runs inside a container\n"
printf "(an isolated software environment). Applications started from\n"
printf "this terminal run on the host node instead.\n\n"
printf "Tip: You can launch host applications here. The & keeps your\n"
printf "terminal free while the app runs. Example:\n\n"
printf "  firefox &\n\n"
printf "────────────────────────────────────────────────────────────────\n\n"
exec bash'
        sleep 1
    done
}

export DISPLAY=":${XdisplayNumber}"
run_xterm_loop | tee -a ${PW_PARENT_JOB_DIR}/xterm.out &
run_xterm_pid=$!
echo "kill ${run_xterm_pid} || true # run_xterm_loop" >> cancel.sh

if [ -n "${startup_command}" ]; then
    echo "::notice::Running startup command: ${startup_command}"
    eval ${startup_command} &
    startup_command_pid=$!
    echo "kill ${startup_command_pid} || true # startup_command" >> cancel.sh
fi

# Wait for container to exit
wait ${kasmvnc_container_pid}
echo "::notice::Exiting job"
echo "::endgroup::"
kill ${run_xterm_pid}
rm cancel.sh
exit 1

