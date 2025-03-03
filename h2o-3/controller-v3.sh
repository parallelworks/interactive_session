cd ${resource_jobdir}

displayErrorMessage() {
    echo $(date): $1
    exit 1
}


if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi


# https://h2o-release.s3.amazonaws.com/h2o/rel-3.46.0/6/h2o-3.46.0.6.zip
service_rel_install_dir="$(basename ${service_download_url} .zip)"
service_bin="${service_parent_install_dir}/${service_rel_install_dir}/h2o.jar"

if [ -f "${service_bin}" ]; then
    echo "Service already installed under ${service_rel_install_dir}/h2o.jar"
    exit 0
fi

cd ${service_parent_install_dir}
rm -rf ${service_rel_install_dir}
wget ${service_download_url}
unzip $(basename ${service_download_url})

if [ -f "${service_bin}" ]; then
    displayErrorMessage "Failed to install ${service_download_url}"
fi