set -o pipefail
set -x

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/librechat
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/librechat



# Download the container only when it is not already present (idempotent)
if ! [ -d "${container_dir}" ]; then
    echo "::group::LibreChat Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/librechat:v1.0 librechat-sifs.tar ${container_tgz}
    if [ ! -s ${container_tgz} ]; then
        echo "::error title=Error::Failed to download file ${container_tgz}"
        exit 1
    fi
    if ! tar xf ${container_tgz} -C $(dirname ${container_dir}); then
        echo "::error title=Error::Failed to extract ${container_tgz}"
        exit 1
    fi
    chmod -R a+rX ${container_dir}
    rm ${container_tgz}
    echo "::endgroup::"
fi


REPO="https://github.com/danny-avila/LibreChat.git"
DIR="LibreChat"
DOMAIN_CLIENT="https://activate.parallel.works/me/session/alvaro/librechat"

# ── Clone or pull ─────────────────────────────────────────────────────────────

if [ ! -d "$DIR/.git" ]; then
  echo "Cloning LibreChat..."
  git clone "$REPO" "$DIR"
else
  echo "Pulling latest changes..."
  git -C "$DIR" pull
fi

# ── Set up .env ───────────────────────────────────────────────────────────────

if [ ! -f "$DIR/.env" ]; then
  echo "Creating .env from .env.example..."
  cp "$DIR/.env.example" "$DIR/.env"
fi

sed -i "s|^DOMAIN_CLIENT=.*|DOMAIN_CLIENT=$DOMAIN_CLIENT|" "$DIR/.env"
echo "DOMAIN_CLIENT set to $DOMAIN_CLIENT"
