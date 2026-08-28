set -o pipefail

################################################################################
# Interactive Session Controller - Ollama GGUF
#
# Purpose: Install Ollama and pull GGUF models from the Ollama library or
#          Hugging Face (hf.co/<owner>/<repo>:<quant>)
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_ollama_version: Ollama release tag (default: v0.32.5)
#   - service_models: Space or comma separated model references to pull
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

# An installed artifact is read-only once staged, so an account that cannot write
# to the shared install directory can still run the copy already sitting there.
# Look for a readable one before deciding to download it again, in the same order
# the model store uses: project directory, install directory, work filesystem,
# home. Only when no candidate has it does the download go to the first writable
# one - home last, since it is the smallest filesystem on these systems.
install_dir_candidates() {
    local seen="" dir=""
    for dir in "${service_shared_install_dir}" "${service_parent_install_dir}" \
               "${WORKDIR:+${WORKDIR}/pw/software}" "${HOME}/pw/software"; do
        [ -n "${dir}" ] || continue
        case " ${seen} " in *" ${dir} "*) continue ;; esac
        seen="${seen} ${dir}"
        echo "${dir}"
    done
}

# Echoes the candidate directory holding a readable copy of the relative path
find_staged_in() {
    local rel=$1 dir=""
    for dir in $(install_dir_candidates); do
        if [ -r "${dir}/${rel}" ]; then
            echo "${dir}"
            return 0
        fi
    done
    return 1
}

first_writable_install_dir() {
    local dir="" probe=""
    for dir in $(install_dir_candidates); do
        probe=${dir}
        while [ ! -e "${probe}" ]; do probe=$(dirname "${probe}"); done
        if [ -w "${probe}" ]; then
            echo "${dir}"
            return 0
        fi
    done
    return 1
}

# Splits the two questions the old single check conflated: which copy of the
# artifact to run, and where this run may write. Staging a 2.8 GB image again
# because the directory holding a perfectly readable one refuses a write is the
# same mistake the model store used to make.
resolve_install_dirs() {
    local rel=$1 staged=""
    staged=$(find_staged_in "${rel}")
    if [ -n "${staged}" ]; then
        artifact_dir="${staged}"
        echo "::notice title=Install Directory::Reusing the staged ${rel} in ${staged}"
    else
        artifact_dir=""
    fi
    if [ -n "${artifact_dir}" ] && [ -w "${artifact_dir}" ]; then
        service_parent_install_dir="${artifact_dir}"
        return 0
    fi
    local writable=""
    writable=$(first_writable_install_dir)
    if [ -z "${writable}" ]; then
        if [ -n "${artifact_dir}" ]; then
            # Nothing to write: the staged copy is enough to run from
            service_parent_install_dir="${artifact_dir}"
            return 0
        fi
        echo "::error title=Install Directory::No candidate install directory holds ${rel} and none of them can be written"
        exit 1
    fi
    service_parent_install_dir="${writable}"
    [ -n "${artifact_dir}" ] || artifact_dir="${writable}"
}

resolve_install_dirs ollama-gguf/bin/ollama
service_install_dir=${artifact_dir}/ollama-gguf
service_exec=${service_install_dir}/bin/ollama
echo "export service_parent_install_dir=\"${service_parent_install_dir}\"" >> inputs.sh

if ! ${service_exec} --version > /dev/null 2>&1; then
    echo "::group::Ollama Installation"
    # A staged copy that does not run is no better than none: install into the
    # writable directory instead of next to the one that failed.
    service_install_dir=${service_parent_install_dir}/ollama-gguf
    service_exec=${service_install_dir}/bin/ollama
    mkdir -p ${service_install_dir}
    tarball=ollama-linux-amd64.tar.zst
    url=https://github.com/ollama/ollama/releases/download/${service_ollama_version:-v0.32.5}/${tarball}
    echo "::notice::Downloading ${url}"
    curl -fsSL -o ${service_install_dir}/${tarball} ${url}
    tar --use-compress-program=unzstd -xf ${service_install_dir}/${tarball} -C ${service_install_dir}
    rm -f ${service_install_dir}/${tarball}
    echo "::endgroup::"
fi

if ! ${service_exec} --version; then
    echo "::error title=Error::ollama installation failed"
    exit 1
fi
# The start template must run the same binary this step resolved
echo "export service_exec=\"${service_exec}\"" >> inputs.sh

# Model store resolution. The order is deliberate: a project directory holds
# models prestaged for everyone on the system, so it is looked at first and is
# worth reusing even where this account cannot write to it; the work filesystem
# comes next, because home is the smallest filesystem on these systems and one
# quantized model is tens of gigabytes; home is the last resort. An operator who
# names a directory on the input form gets that directory and no search.
service_models_requested="${service_models}"

model_manifest_path() {
    local ref=$1 name=$1 tag=latest
    case "${ref}" in *:*) name=${ref%%:*}; tag=${ref##*:};; esac
    case "${name}" in
        */*/*) echo "${OLLAMA_MODELS}/manifests/${name}/${tag}" ;;
        */*) echo "${OLLAMA_MODELS}/manifests/registry.ollama.ai/${name}/${tag}" ;;
        *) echo "${OLLAMA_MODELS}/manifests/registry.ollama.ai/library/${name}/${tag}" ;;
    esac
}

# "Is there a manifest" and "can this account open it" are different questions,
# and a store is only prestaged for the accounts that can read it. A project
# directory whose default ACL denies other leaves every manifest and blob at
# mode rw-rw----: they stat fine, so a plain -s test calls the model cached and
# the failure lands much later as a load error on the compute node. Check the
# manifest and every blob it names for read permission instead.
model_is_readable() {
    local manifest=$1 digest=""
    [ -s "${manifest}" ] && [ -r "${manifest}" ] || return 1
    for digest in $(tr ',' '\n' < "${manifest}" \
        | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'); do
        [ -r "${OLLAMA_MODELS}/blobs/${digest/:/-}" ] || return 1
    done
    return 0
}

# hf.co and huggingface.co address the same registry, and sites that filter by
# domain commonly allow the long name while blocking the short one, which
# surfaces as a connection reset rather than a policy message. Prefer whichever
# form a given store already holds, since a cache written under one name is
# invisible under the other and would be re-pulled in full; otherwise take the
# long name, which more sites allow.
normalise_models_for_store() {
    local store=$1 saved=${OLLAMA_MODELS} out="" ref short long chosen candidate
    export OLLAMA_MODELS=${store}
    for ref in ${service_models_requested//,/ }; do
        short="${ref}"; long="${ref}"
        case "${ref}" in
            hf.co/*) long="huggingface.co/${ref#hf.co/}" ;;
            huggingface.co/*) short="hf.co/${ref#huggingface.co/}" ;;
        esac
        chosen="${long}"
        for candidate in "${ref}" "${short}" "${long}"; do
            if [ -s "$(model_manifest_path ${candidate})" ]; then
                chosen="${candidate}"
                break
            fi
        done
        out="${out} ${chosen}"
    done
    export OLLAMA_MODELS=${saved}
    service_models="$(echo ${out} | xargs)"
}

model_store_candidates() {
    local seen="" dir=""
    for dir in "${service_shared_models_dir}" \
               "${service_parent_install_dir}/ollama-gguf/models" \
               "${WORKDIR:+${WORKDIR}/pw/software/ollama-gguf/models}" \
               "${HOME}/pw/software/ollama-gguf/models"; do
        [ -n "${dir}" ] || continue
        case " ${seen} " in *" ${dir} "*) continue ;; esac
        seen="${seen} ${dir}"
        echo "${dir}"
    done
}

# Leaves service_models normalised against the store it was asked about
store_has_all_models() {
    local store=$1 saved=${OLLAMA_MODELS} model="" manifest="" unreadable="" ok=0
    normalise_models_for_store "${store}"
    export OLLAMA_MODELS=${store}
    for model in ${service_models//,/ }; do
        manifest=$(model_manifest_path ${model})
        model_is_readable "${manifest}" && continue
        ok=1
        [ -s "${manifest}" ] && unreadable="${unreadable} ${model}"
    done
    export OLLAMA_MODELS=${saved}
    if [ -n "${unreadable}" ]; then
        echo "::warning title=Model Directory::${store} already holds${unreadable}, but this account cannot read the files. Under a project directory's default ACL the weights land at mode rw-rw----, readable only to the project group, so they have to be staged again elsewhere. Whoever owns the store can open it once with: chmod -R a+rX ${store}; find ${store} -type d -exec setfacl -d -m o::rx {} +"
    fi
    return ${ok}
}

store_is_writable() {
    local probe=$1
    while [ ! -e "${probe}" ]; do probe=$(dirname "${probe}"); done
    [ -w "${probe}" ]
}

if [ -n "${service_models_dir}" ]; then
    echo "::notice title=Model Directory::Using the model directory from the input form: ${service_models_dir}"
else
    for candidate in $(model_store_candidates); do
        if store_has_all_models "${candidate}"; then
            service_models_dir=${candidate}
            echo "::notice title=Model Directory::Every requested model is already staged in ${candidate}"
            break
        fi
    done
fi
if [ -z "${service_models_dir}" ]; then
    for candidate in $(model_store_candidates); do
        if store_is_writable "${candidate}"; then
            service_models_dir=${candidate}
            echo "::notice title=Model Directory::No store holds every requested model; staging into ${candidate}"
            break
        fi
        echo "::notice title=Model Directory::${candidate} is not writable; trying the next candidate"
    done
fi
if [ -z "${service_models_dir}" ]; then
    echo "::error title=Model Directory::No usable model directory: no candidate holds every requested model in a form this account can read, and none of them can be written"
    exit 1
fi
export OLLAMA_MODELS=${service_models_dir}
normalise_models_for_store "${OLLAMA_MODELS}"
echo "export service_models=\"${service_models}\"" >> inputs.sh

# Ollama names a model after the reference it was pulled with, so a Hugging
# Face model is served - and listed in the platform chat - as
# hf.co/<uploader>/<repo>:<quant>. The registry host and the uploader are
# provenance, not identity, and they make the model id in the chat picker
# unreadable. Serve a plain name instead: the repository, lowercased, without
# the registry, the uploader or the -GGUF suffix, with the quantization as the
# tag. Ollama accepts [a-z0-9._-] in a name, so anything else folds to a dash,
# and a pathological repository name is cut rather than left to fail the
# server's own name validation.
ollama_safe_name() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' \
        | sed 's/--*/-/g; s/^[-._]*//; s/[-._]*$//' | cut -c1-64 | sed 's/[-._]*$//'
}

normalise_served_name() {
    local n=$1 tag=latest
    case "${n}" in *:*) tag=${n##*:}; n=${n%%:*} ;; esac
    printf '%s:%s' "$(ollama_safe_name "${n}")" "$(ollama_safe_name "${tag}")"
}

served_name_for() {
    local ref=$1 name=$1 tag=latest repo=""
    case "${ref}" in *:*) name=${ref%%:*}; tag=${ref##*:} ;; esac
    repo=${name##*/}
    repo=${repo%-GGUF}; repo=${repo%-gguf}; repo=${repo%.gguf}
    normalise_served_name "${repo}:${tag}"
}

# Positional: the operator's names where given, a derived plain name otherwise.
# Dropping the uploader can make two references collide - the same repository
# name and quantization from two accounts - and the loser would silently vanish
# from the view, so a collision is numbered and reported rather than served as
# one model.
read -r -a model_refs <<< "${service_models}"
read -r -a name_overrides <<< "${service_model_names//,/ }"
served_models=""
for i in "${!model_refs[@]}"; do
    if [ -n "${name_overrides[$i]}" ]; then
        candidate=$(normalise_served_name "${name_overrides[$i]}")
    else
        candidate=$(served_name_for "${model_refs[$i]}")
    fi
    [ "${candidate%%:*}" = "" ] && candidate="model:${candidate##*:}"
    suffix=1
    while case " ${served_models} " in *" ${candidate} "*) true ;; *) false ;; esac; do
        suffix=$((suffix + 1))
        candidate="$(ollama_safe_name "${candidate%%:*}-${suffix}"):${candidate##*:}"
        echo "::warning title=Model Name::Two models resolve to the same served name; serving one of them as ${candidate}. Set \"Serve models as\" to name them yourself."
    done
    served_models="${served_models} ${candidate}"
done
served_models="$(echo ${served_models} | xargs)"
read -r -a served_refs <<< "${served_models}"
echo "export service_served_models=\"${served_models}\"" >> inputs.sh

# The store's contents are the only thing that decides what ollama serves -
# there is no allowlist and no rename at the server - so both are done by
# assembling a manifests directory for this run and serving that instead. An
# alias is the same manifest file written under the name to serve it as, which
# costs nothing: manifests are a kilobyte and the blobs they point at are never
# copied.
build_manifests_view() {
    local src rel alias i
    manifests_view=${PW_PARENT_JOB_DIR}/ollama-manifests-view
    rm -rf ${manifests_view}
    mkdir -p ${manifests_view}
    # Not filtering means every cached model stays visible, so mirror the
    # store's manifests first and write the aliases on top of that
    if [ "${service_serve_only_requested}" != "true" ] && [ -d "${OLLAMA_MODELS}/manifests" ]; then
        (cd ${OLLAMA_MODELS}/manifests && find . -type f -exec cp --parents {} ${manifests_view}/ \;) 2> /dev/null
    fi
    for i in "${!model_refs[@]}"; do
        src=$(model_manifest_path "${model_refs[$i]}")
        if ! [ -s "${src}" ]; then
            echo "::error title=Error::manifest for ${model_refs[$i]} not found at ${src}"
            exit 1
        fi
        alias=${served_refs[$i]}
        rel="registry.ollama.ai/library/${alias%%:*}/${alias##*:}"
        mkdir -p ${manifests_view}/$(dirname ${rel})
        cp ${src} ${manifests_view}/${rel}
        chmod u+w ${manifests_view}/${rel}
        if [ "${alias}" != "${model_refs[$i]}" ]; then
            echo "::notice title=Model Name::Serving ${model_refs[$i]} as ${alias}"
        fi
    done
    # Pruning would delete shared blobs the filtered manifests do not reference
    echo "export OLLAMA_NOPRUNE=1" >> inputs.sh
    echo "export service_manifests_view=\"${manifests_view}\"" >> inputs.sh
}

need_pull=false
for model in ${service_models//,/ }; do
    model_is_readable "$(model_manifest_path ${model})" || need_pull=true
done

skip_pull=false
if ! store_is_writable "${OLLAMA_MODELS}"; then
    echo "::notice title=Model Directory::${OLLAMA_MODELS} is not writable; serving the staged models read-only"
    echo "export OLLAMA_NOPRUNE=1" >> inputs.sh
    export OLLAMA_NOPRUNE=1
    skip_pull=true
fi

# The start template reads the resolved store from inputs.sh
echo "export service_models_dir=\"${service_models_dir}\"" >> inputs.sh

start_temp_server() {
    export OLLAMA_HOST=127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    ${service_exec} serve > ollama-controller-serve.log 2>&1 &
    server_pid=$!
    trap "kill ${server_pid} 2> /dev/null" EXIT
    retries=0
    until curl -s http://${OLLAMA_HOST}/ > /dev/null; do
        retries=$((retries + 1))
        if [ ${retries} -gt 30 ]; then
            echo "::error title=Error::ollama server did not start; see ollama-controller-serve.log"
            return 1
        fi
        sleep 1
    done
}

# "Max" means the largest window the models were trained for, which only the
# model metadata knows. Resolve it here, where a server is available, and hand
# the number to the start template: the service reads OLLAMA_CONTEXT_LENGTH
# once at startup and cannot ask later.
resolve_max_context() {
    [ "${service_context_length}" = "max" ] || return 0
    local best=0 n=""
    for model in ${service_models//,/ }; do
        n=$(${service_exec} show ${model} 2>/dev/null | awk '$1 == "context" && $2 == "length" {print $3; exit}')
        case "${n}" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "${n}" -gt "${best}" ] && best=${n}
    done
    if [ "${best}" -gt 0 ]; then
        echo "::notice title=Context Length::Serving at the model maximum of ${best} tokens"
        echo "export service_context_resolved=${best}" >> inputs.sh
    else
        echo "::warning title=Context Length::Could not read a context length from the model metadata; falling back to the ollama default"
    fi
}

if [ "${skip_pull}" = "true" ]; then
    if [ "${service_context_length}" = "max" ] && start_temp_server; then
        resolve_max_context
    fi
    build_manifests_view
    exit 0
fi

# Cached models are served as-is: pulling them again rewrites their manifest,
# which fails when another user owns the file in a shared store
if [ "${need_pull}" != "true" ]; then
    echo "::notice title=Model Directory::All requested models are already cached in ${OLLAMA_MODELS}"
    if [ "${service_context_length}" = "max" ] && start_temp_server; then
        resolve_max_context
    fi
    build_manifests_view
    exit 0
fi

echo "::group::Pull Models"
mkdir -p ${OLLAMA_MODELS}
# Model pulls go through a temporary server on an ephemeral port; the weights
# land in the shared-filesystem OLLAMA_MODELS dir for the service to read
start_temp_server || exit 1

# Pulls resume from partial blobs, so a stalled transfer (ollama can hang on a
# dead connection) is bounded by the timeout and finished by the retry
for model in ${service_models//,/ }; do
    if model_is_readable "$(model_manifest_path ${model})"; then
        echo "::notice::${model} is already cached; skipping pull"
        continue
    fi
    echo "::notice::Pulling ${model}"
    pulled=false
    for attempt in 1 2 3; do
        if timeout 1800 ${service_exec} pull ${model}; then
            pulled=true
            break
        fi
        echo "::warning::Pull attempt ${attempt} for ${model} failed or timed out; retrying"
    done
    if [ "${pulled}" != "true" ]; then
        echo "::error title=Error::failed to pull model ${model}"
        exit 1
    fi
done

# A store is only prestaged for the accounts that can read it. Where the project
# directory's default ACL denies other, every blob this run pulled lands at mode
# rw-rw---- and the next account outside the project group re-downloads what is
# already on the filesystem. Widen what this run wrote and set the default so
# later pulls inherit it. Both are best effort: files another account owns
# cannot be changed from here.
chmod -R a+rX,ug+w ${OLLAMA_MODELS} 2> /dev/null || true
if command -v setfacl > /dev/null 2>&1; then
    setfacl -R -m o::rX ${OLLAMA_MODELS} 2> /dev/null || true
    find ${OLLAMA_MODELS} -type d -exec setfacl -d -m o::rx {} + 2> /dev/null || true
fi

resolve_max_context

${service_exec} list
echo "::endgroup::"

build_manifests_view
