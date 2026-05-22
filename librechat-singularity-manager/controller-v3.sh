#!/bin/bash
set -o pipefail
set -x

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir="${HOME}/pw/software"
fi

FLASK_ENV="${service_parent_install_dir}/tools/flask"

if [ ! -f "${FLASK_ENV}/bin/flask" ]; then
    echo "::group::Flask venv setup"
    mkdir -p "$(dirname "${FLASK_ENV}")"
    python3 -m venv "${FLASK_ENV}"
    "${FLASK_ENV}/bin/pip" install --quiet flask
    echo "::endgroup::"
fi

echo "::notice::Flask ready at ${FLASK_ENV}"
