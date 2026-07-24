set -o pipefail
set -x

source tools/oras/libs.sh

streamlit_registry=${streamlit_registry:-ghcr.io/parallelworks/streamlit:1.0}
# Cache the SIF in a registry-derived directory so changing the registry input
# cannot silently reuse an image downloaded from another reference
registry_slug=$(printf '%s' "${streamlit_registry}" | tr -c 'a-zA-Z0-9._-' '_')

mkdir -p "${service_parent_install_dir}" || true
if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/${registry_slug}/streamlit.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers/${registry_slug} ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/containers/${registry_slug} ${service_parent_install_dir}/tools

container_sif=${service_parent_install_dir}/containers/${registry_slug}/streamlit.sif

# Download the SIF only when it is not already present (idempotent)
if ! [ -f "${container_sif}" ]; then
    echo "::group::Streamlit SIF Download"
    echo "::notice::Downloading streamlit.sif from ${streamlit_registry}"
    oras_pull_file ${streamlit_registry} streamlit.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}. The registry artifact must contain a file named streamlit.sif."
        exit 1
    fi
    chmod a+r ${container_sif}
    echo "::endgroup::"
fi
