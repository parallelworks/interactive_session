# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# https://h2o-release.s3.amazonaws.com/h2o/rel-3.46.0/6/h2o-3.46.0.6.zip
service_rel_install_dir="$(basename ${service_download_url} .zip)"
service_bin="${service_parent_install_dir}/${service_rel_install_dir}/h2o.jar"

java -jar ${service_bin}