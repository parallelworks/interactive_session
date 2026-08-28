################################################################################
# Interactive Session Service Starter - Ollama GGUF (Singularity)
#
# Purpose: Serve the pulled GGUF models through Ollama's OpenAI-compatible API
#          on a pw endpoint, running Ollama from the SIF downloaded by
#          controller-v4.sh (sandbox fallback when the node cannot mount SIFs)
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_context_length: Model context window in tokens (default: 8192)
#   - service_keep_alive: How long models stay loaded in memory (default: 5m)
################################################################################

set -x

# The controller resolved which image to run and where this run may write, and
# appended both to inputs.sh; re-deriving them here is how the two steps end up
# pointing at different copies.
if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
container_sif=${service_container_sif:-${service_parent_install_dir}/containers/ollama-gguf.sif}
sandbox_dir=${service_parent_install_dir}/containers/ollama-gguf-sandbox

# Apptainer renamed the command, so a host can have the runtime under either
# name, or under a module whose name carries a version. Look for both, try the
# usual module spellings, and where only apptainer exists, stand in for the
# singularity command the rest of this script calls.
# Finding the runtime is more involved than a PATH lookup: a login shell may
# not have run the profile scripts that define module, the runtime is often
# installed outside the default PATH, and sites publish the module under
# several names. Each of those has ended a launch on a system that had
# singularity installed the whole time.
find_container_runtime() {
    local tried="PATH"
    container_runtime="$(command -v singularity || command -v apptainer)"
    [ -n "${container_runtime}" ] && return 0

    # module is a shell function, so it exists only after its init script runs
    if ! type module > /dev/null 2>&1; then
        for init in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh \
                    /usr/share/Modules/init/bash /usr/share/lmod/lmod/init/bash; do
            [ -r "${init}" ] && . "${init}" 2> /dev/null && break
        done
    fi
    if type module > /dev/null 2>&1; then
        tried="${tried}, modules"
        for candidate in apptainer singularity singularityce singularity-ce; do
            module load ${candidate} > /dev/null 2>&1 && break
        done
        container_runtime="$(command -v singularity || command -v apptainer)"
        [ -n "${container_runtime}" ] && return 0
    fi

    # Installed but off PATH, which is common where the runtime is a site
    # package rather than a distribution one
    tried="${tried}, common install paths"
    for candidate in /usr/bin /usr/local/bin /usr/sbin /opt/apptainer/bin /opt/singularity/bin \
                     /usr/local/apptainer/bin /usr/local/singularity/bin \
                     /cm/local/apps/apptainer/current/bin /cm/shared/apps/singularity/current/bin \
                     /sw/apptainer/bin /sw/singularity/bin /apps/singularity/bin; do
        for name in singularity apptainer; do
            if [ -x "${candidate}/${name}" ]; then
                container_runtime="${candidate}/${name}"
                return 0
            fi
        done
    done

    echo "::warning title=Container Runtime::Searched ${tried} and found neither singularity nor apptainer"
    return 1
}

# Resolved once and called by path: a shell function would not survive the
# exec in the generated launcher, which bypasses functions by design.
find_container_runtime
if [ -z "${container_runtime}" ]; then
    echo "::error title=Error::No container runtime on this system: neither singularity nor apptainer is in PATH, and no module of either name could be loaded. Re-run with the service set to Native (Ollama tarball), which installs ollama directly and needs no container runtime."
    exit 1
fi
echo "::notice::Container runtime: ${container_runtime}"

# Sites that inspect TLS present their own certificate authority. The host
# trusts it; the container carries its own store and does not, so every pull
# fails with "certificate signed by unknown authority" on a network that looks
# fine from the shell. Bind the host bundle in where one exists.
container_ca_args=""
for bundle in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
              /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt; do
    if [ -r "${bundle}" ]; then
        container_ca_args="--bind ${bundle}:/etc/ssl/certs/ca-certificates.crt --env SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        echo "::notice::Trusting the host certificate bundle ${bundle} inside the container"
        break
    fi
done

if ! [ -r "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

# Prefer running the SIF directly; some nodes cannot mount it (no squashfs
# kernel/FUSE support), in which case unpack it once into a sandbox directory
host_ollama=""
if "${container_runtime}" exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::SIF image is runnable on this node"
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    # A shared image directory is often owned by whoever installed the image,
    # so the sandbox cannot be built beside it. Fall back to a private one
    # rather than building nothing and running a path that does not exist.
    if [ ! -d "${sandbox_dir}" ] && ! mkdir -p "${sandbox_dir}" 2> /dev/null; then
        sandbox_dir="${HOME}/pw/software/containers/$(basename "${sandbox_dir}")"
        echo "::notice::Image directory is not writable; building the sandbox in ${sandbox_dir}"
        mkdir -p "${sandbox_dir%/*}"
    fi
    if ! [ -d "${sandbox_dir}/usr" ]; then
        echo "Expanding the image into a sandbox..."
        rm -rf "${sandbox_dir}"
        # build --fakeroot needs a user namespace, which plenty of login nodes
        # do not give out ("no user namespace available for fakeroot"). Where
        # that is refused, take the squashfs partition straight out of the SIF
        # and unpack it, which needs no privilege at all.
        if ! "${container_runtime}" build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}" 2> sandbox-build.log; then
            tail -3 sandbox-build.log 2> /dev/null
            echo "::notice::fakeroot build refused; unpacking the image partition instead"
            if ! command -v unsquashfs > /dev/null 2>&1; then
                echo "::error title=Error::Cannot mount ${container_sif}, cannot build a sandbox with fakeroot, and unsquashfs is unavailable to unpack it"
                exit 1
            fi
            fs_id=$("${container_runtime}" sif list "${container_sif}" | awk -F'|' '$5 ~ /Squashfs/ { gsub(/ /, "", $1); print $1; exit }')
            if [ -z "${fs_id}" ]; then
                echo "::error title=Error::No squashfs partition found in ${container_sif}"
                exit 1
            fi
            "${container_runtime}" sif dump "${fs_id}" "${container_sif}" > "${sandbox_dir}.squash" || {
                echo "::error title=Error::Could not read the image partition from ${container_sif}"
                exit 1
            }
            # -no-xattrs: many shared filesystems refuse them and nothing in
            # the image depends on them
            unsquashfs -q -f -no-xattrs -d "${sandbox_dir}" "${sandbox_dir}.squash" || {
                echo "::error title=Error::Could not unpack ${container_sif} into ${sandbox_dir}"
                exit 1
            }
            rm -f "${sandbox_dir}.squash"
        fi
    fi
    container_ref="${sandbox_dir}"

    # A non-suid runtime needs an unprivileged user namespace for a sandbox
    # just as it does for the SIF, so a node that hands out none (seen as
    # "maximum number of user namespaces exceeded" with max_user_namespaces=0)
    # cannot start any container. The sandbox is the image's full root tree
    # and the image wraps the ollama release install, so its binary runs on
    # the host directly, exactly like the native variant.
    if ! "${container_runtime}" exec "${container_ref}" /bin/true > /dev/null 2>&1; then
        for candidate in "${sandbox_dir}/usr/bin/ollama" "${sandbox_dir}/bin/ollama"; do
            if "${candidate}" --version > /dev/null 2>&1; then
                host_ollama="${candidate}"
                break
            fi
        done
        if [ -z "${host_ollama}" ]; then
            echo "::error title=Error::${container_runtime} cannot start containers on this node (user namespaces are unavailable) and the image's ollama binary in ${sandbox_dir} does not run on the host either"
            exit 1
        fi
        echo "::notice::${container_runtime} cannot start containers on this node; serving with ${host_ollama} directly on the host"
    fi
fi

# Model weights are shared with the native ollama-gguf variant; the controller
# appends the resolved service_models_dir to inputs.sh
export OLLAMA_MODELS=${service_models_dir:-${service_parent_install_dir}/ollama-gguf/models}

# The controller resolved the store, picked the hf.co / huggingface.co spelling
# that store actually holds, and exported both service_models and the plain
# names to serve them under, so nothing is re-derived here: two copies of that
# logic disagreeing is how a model ends up served under a name the manifests
# view does not contain.

nv_flag=""
if nvidia-smi -L > /dev/null 2>&1; then
    echo "::notice::NVIDIA GPU detected; enabling --nv"
    nv_flag="--nv"
fi

# auto leaves OLLAMA_CONTEXT_LENGTH unset so ollama picks the default
# "max" means the window the model was trained for, which only the model
# metadata knows. The server reads OLLAMA_CONTEXT_LENGTH once at startup, so
# the number has to exist first: ask a short-lived server here, on the node
# that will serve, since the controller's node may not run containers at all.
ctx_value="${service_context_length}"
if [ "${ctx_value}" = "max" ]; then
    ctx_value=""
    if [ -n "${service_context_resolved}" ]; then
        ctx_value="${service_context_resolved}"
    else
        probe_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 41999)
        if [ -n "${host_ollama}" ]; then
            probe_cmd="env OLLAMA_HOST=127.0.0.1:${probe_port} OLLAMA_MODELS=${OLLAMA_MODELS} ${host_ollama}"
        else
            probe_cmd="${container_runtime} exec ${container_ca_args} \
                --bind ${OLLAMA_MODELS}:${OLLAMA_MODELS} \
                --env OLLAMA_HOST=127.0.0.1:${probe_port} --env OLLAMA_MODELS=${OLLAMA_MODELS} \
                ${container_ref} /bin/ollama"
        fi
        ${probe_cmd} serve > ctx-probe.log 2>&1 &
        probe_pid=$!
        for _ in $(seq 1 30); do
            curl -s "http://127.0.0.1:${probe_port}/" > /dev/null 2>&1 && break
            sleep 1
        done
        best=0
        for model in ${service_models//,/ }; do
            n=$(${probe_cmd} show "${model}" 2> /dev/null \
                | awk '$1 == "context" && $2 == "length" {print $3; exit}')
            case "${n}" in ''|*[!0-9]*) continue ;; esac
            [ "${n}" -gt "${best}" ] && best=${n}
        done
        kill ${probe_pid} 2> /dev/null
        if [ "${best}" -gt 0 ]; then
            ctx_value="${best}"
            echo "::notice title=Context Length::Serving at the model maximum of ${best} tokens"
        else
            echo "::warning title=Context Length::Could not read a context length from the model metadata; serving at the ollama default"
        fi
    fi
fi
ctx_env=""
if [ -n "${ctx_value}" ] && [ "${ctx_value}" != "auto" ]; then
    ctx_env="--env OLLAMA_CONTEXT_LENGTH=${ctx_value}"
fi

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"

# When the controller built a filtered manifests view, over-mount it so the
# container serves only the requested models. Without a container to mount
# into, assemble a store whose manifests are the filtered copy and whose
# blobs are the real ones.
manifests_bind=""
serve_store="${OLLAMA_MODELS}"
if [ -n "${service_manifests_view}" ]; then
    echo "::notice::Serving ${service_served_models:-${service_models}} from the manifests view the controller assembled"
    if [ -n "${host_ollama}" ]; then
        serve_store=${PWD}/ollama-store-view
        mkdir -p ${serve_store}
        ln -sfn "${service_manifests_view}" ${serve_store}/manifests
        ln -sfn "${OLLAMA_MODELS}/blobs" ${serve_store}/blobs
    else
        manifests_bind="--bind ${service_manifests_view}:${OLLAMA_MODELS}/manifests"
    fi
fi

# pw endpoints run exports PORT to the wrapped command; the launcher reads it
# at runtime (it is unknown before launch)
cat > launch-ollama-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
if [ "${service_preload:-true}" = "true" ]; then
    (
        until curl -s "http://127.0.0.1:\${PORT}/" > /dev/null 2>&1; do sleep 1; done
        for model in ${service_served_models:-${service_models}}; do
            echo "Preloading \${model}"
            curl -s "http://127.0.0.1:\${PORT}/api/generate" -d "{\"model\": \"\${model}\"}" > /dev/null
        done
    ) &
fi
EOF
if [ -n "${host_ollama}" ]; then
    [ -n "${ctx_env}" ] && echo "export OLLAMA_CONTEXT_LENGTH=${ctx_value}" >> launch-ollama-${PW_JOB_ID}.sh
    cat >> launch-ollama-${PW_JOB_ID}.sh <<EOF
export OLLAMA_HOST="127.0.0.1:\${PORT}"
export OLLAMA_NOPRUNE="${OLLAMA_NOPRUNE:-false}"
export OLLAMA_MODELS="${serve_store}"
export OLLAMA_KEEP_ALIVE="${service_keep_alive:-5m}"
exec "${host_ollama}" serve
EOF
else
    cat >> launch-ollama-${PW_JOB_ID}.sh <<EOF
exec "${container_runtime}" exec ${nv_flag} ${container_ca_args} \\
    --bind "${service_parent_install_dir}:${service_parent_install_dir}" \\
    --bind "${OLLAMA_MODELS}:${OLLAMA_MODELS}" \\
    ${manifests_bind} \\
    --bind "${PWD}/container_tmp:/tmp" \\
    --env OLLAMA_HOST="127.0.0.1:\${PORT}" \\
    --env OLLAMA_NOPRUNE="${OLLAMA_NOPRUNE:-false}" \\
    --env OLLAMA_MODELS="${OLLAMA_MODELS}" \\
    ${ctx_env} \\
    --env OLLAMA_KEEP_ALIVE="${service_keep_alive:-5m}" \\
    "${container_ref}" /bin/ollama serve
EOF
fi
chmod +x launch-ollama-${PW_JOB_ID}.sh

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting ollama: pw endpoints run --openai --rewrite-host=localhost ${pw_endpoints_args}"

# --openai registers the endpoint as an OpenAI-compatible provider in the
# platform chat; --rewrite-host satisfies ollama's Host header guard.
pw endpoints run --openai --rewrite-host=localhost ${pw_endpoints_args} -- ./launch-ollama-${PW_JOB_ID}.sh

endpoints_rc=$?

# The workflow cancels this job the moment the endpoint registers, which kills
# the wrapped command and returns non-zero. That is how a successful launch
# ends, not a failure, and calling it an error is why a healthy run shows a red
# step and reads as broken. Only a launch that never registered an endpoint is
# one.
if [ ${endpoints_rc} -ne 0 ]; then
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    #pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
