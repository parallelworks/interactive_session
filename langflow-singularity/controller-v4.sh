#!/usr/bin/env bash
set -o pipefail
set -x

################################################################################
# Interactive Session Controller - Langflow (Singularity)
#
# Purpose: Download the Langflow and HFTEI SIF images from GHCR and prepare the
#          data directory. The images are shared across sessions on the same
#          cluster so each download only happens once.
# Runs on: Controller/login node (has internet access)
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install root (default: ${HOME}/pw/software)
#   - service_langflow_data_dir:  Langflow data dir (default: ${HOME}/pw/.langflow)
################################################################################

source ${PW_PARENT_JOB_DIR}/tools/oras/libs.sh

mkdir -p "${service_parent_install_dir}" || true
if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/langflow.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_sif=${service_parent_install_dir}/containers/langflow.sif

# Create and open up the Langflow data directory so the container user can write to it
mkdir -p "${service_langflow_data_dir:-${HOME}/pw/.langflow}"
chmod 777 "${service_langflow_data_dir:-${HOME}/pw/.langflow}" -Rf || true

# Download the container only when it is not already present (idempotent)
if ! [ -f "${container_sif}" ]; then
    echo "::group::Langflow Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/langflow:2.0 langflow.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}"
        exit 1
    fi
    chmod a+r ${container_sif}
    echo "::endgroup::"
fi

echo "::notice::Langflow container ready at ${container_sif}"

# ── Optional: HFTEI embeddings server container ────────────────────────────────
if [ "${langflow_enable_hftei}" = "true" ]; then
    hftei_sif=${service_parent_install_dir}/containers/hftei-cpu-1.6.0.sif
    if ! [ -f "${hftei_sif}" ]; then
        echo "::group::HFTEI Singularity Container Download"
        oras_pull_file ghcr.io/parallelworks/hftei:cpu-1.6.0 hftei-cpu-1.6.0.sif ${hftei_sif}
        if [ ! -s ${hftei_sif} ]; then
            echo "::error title=Error::Failed to download file ${hftei_sif}"
            exit 1
        fi
        chmod a+r ${hftei_sif}
        echo "::endgroup::"
    fi
    echo "::notice::HFTEI container ready at ${hftei_sif}"

    # Download the embedding model when it is not already present (idempotent)
    if [ -n "${langflow_hftei_model_dir}" ] && [ ! -s "${langflow_hftei_model_dir}/model.safetensors" ]; then
        echo "::group::HFTEI Embedding Model Download (sentence-transformers/all-mpnet-base-v2)"
        mkdir -p "${langflow_hftei_model_dir}/1_Pooling"
        hf_base="https://huggingface.co/sentence-transformers/all-mpnet-base-v2/resolve/main"
        for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json vocab.txt model.safetensors 1_Pooling/config.json; do
            if ! curl -sSL --fail -o "${langflow_hftei_model_dir}/${f}" "${hf_base}/${f}"; then
                echo "::error title=Error::Failed to download ${hf_base}/${f}. Stage the model at ${langflow_hftei_model_dir} manually, or disable HFTEI."
                exit 1
            fi
        done
        chmod -R a+rX "${langflow_hftei_model_dir}" || true
        echo "::endgroup::"
    fi
    echo "::notice::HFTEI model ready at ${langflow_hftei_model_dir}"
fi

# ── Optional: Langflow proxy Python environment ────────────────────────────────
# When ${langflow_proxy_dir} is set (combined LibreChat + Langflow workflow), build
# a venv with the proxy's dependencies so the start script can launch the
# OpenAI-compatible proxy alongside Langflow. The proxy CODE lives at
# ${langflow_proxy_dir} and is intentionally NOT shipped in this repo.
if [ "${langflow_enable_proxy}" = "true" ]; then
    # The proxy is enabled, so a valid proxy code directory is REQUIRED on this (Langflow)
    # host. The proxy CODE is intentionally NOT shipped in this repo — it must be staged on
    # the Langflow host at ${langflow_proxy_dir}. Fail loudly here rather than silently
    # skipping the proxy: a skipped proxy never publishes LANGFLOW_PROXY_PORT, which would
    # leave LibreChat waiting indefinitely for an endpoint that never appears. Because this
    # controller exits non-zero, the Langflow job fails and `early-cancel: any-job-failed`
    # tears the LibreChat job down too — no hang.
    if [ -z "${langflow_proxy_dir}" ]; then
        echo "::error title=Langflow proxy not configured::'Start Langflow Proxy?' is enabled but no 'Langflow Proxy Path' was provided. Set it to the langflow_proxy code directory on the Langflow host ($(hostname)), or disable the proxy."
        exit 1
    fi
    if [ ! -d "${langflow_proxy_dir}/langflow_proxy" ]; then
        echo "::error title=Langflow proxy code not found::'Langflow Proxy Path' = '${langflow_proxy_dir}' has no 'langflow_proxy/' package on the Langflow host ($(hostname)). Stage the langflow_proxy code there (it is not shipped in this repo; remember each cluster has its own filesystem), or disable the proxy."
        exit 1
    fi
    proxy_venv="${service_parent_install_dir}/tools/langflow_proxy_venv"
    if [ ! -x "${proxy_venv}/bin/python" ]; then
        echo "::group::Langflow proxy venv setup"
        python3 -m venv "${proxy_venv}"
        # requirements.txt is an editable self-install (-e .) which needs write
        # access to the code dir; install the declared deps directly instead.
        "${proxy_venv}/bin/pip" install --quiet --upgrade pip
        "${proxy_venv}/bin/pip" install --quiet fastapi uvicorn pydantic aiohttp pyyaml
        # Make the venv usable by any user (shared install under service_parent_install_dir).
        chmod -R a+rX "${proxy_venv}" || true
        echo "::endgroup::"
    fi
    echo "::notice::Langflow proxy venv ready at ${proxy_venv}"
fi
