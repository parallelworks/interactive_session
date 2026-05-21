#!/bin/bash
set -o pipefail
set -x

source tools/oras/libs.sh

CONTAINER_DIR="${HOME}/pw/software/containers/librechat-manager"
CONTAINER_TGZ="${CONTAINER_DIR}.tgz"

mkdir -p "${HOME}/pw/software/containers" "${HOME}/pw/software/tools"
chmod a+rX "${HOME}/pw/software/containers" "${HOME}/pw/software/tools"

if ! [ -d "${CONTAINER_DIR}" ]; then
    echo "::group::librechat-manager Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/librechat-singularity-manager:1.0 librechat-manager.tgz ${CONTAINER_TGZ}
    if [ ! -s ${CONTAINER_TGZ} ]; then
        echo "::error title=Error::Failed to download file ${CONTAINER_TGZ}"
        exit 1
    fi
    if ! tar -xzf ${CONTAINER_TGZ} -C $(dirname ${CONTAINER_DIR}); then
        echo "::error title=Error::Failed to extract ${CONTAINER_TGZ}"
        exit 1
    fi
    chmod -R a+rX ${CONTAINER_DIR}
    rm ${CONTAINER_TGZ}
    echo "::endgroup::"
fi

echo "::notice::librechat-manager container ready at ${CONTAINER_DIR}"
