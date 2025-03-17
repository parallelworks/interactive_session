# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

echo "Activating Airflow environment"
export AIRFLOW_HOME=${service_airflow_home}
service_conda_install_dir=${service_parent_install_dir}/miniconda3-$(basename ${service_airflow_home})
source ${service_conda_install_dir}/bin/activate

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

airflow_port=8080 #$(findAvailablePort)

#################
# START AIRFLOW #
#################
#base_url="https://alvaro-airfloww.activate.pw/"
#sed -i "s|^base_url .*|base_url = ${base_url}|" ${AIRFLOW_HOME}/airflow.cfg
sed -i "s|^enable_proxy_fix .*|enable_proxy_fix = True|" ${AIRFLOW_HOME}/airflow.cfg


# Do now use "airflow standalone"! It does not allow adding new users
airflow db init
# Run "airflow db reset" in cancel.sh?
 
airflow users create \
    --username ${service_username} \
    --firstname ${service_firstname} \
    --lastname ${service_lastname} \
    --role ${service_role} \
    --email ${service_email} \
    --password ${service_password}


airflow scheduler 2>&1 | tee scheduler.log &
airflow_scheduler_pid=$!
echo "kill ${airflow_scheduler_pid} # airflow scheduler" >> cancel.sh

airflow webserver --port 8080 2>&1 | tee webserver.log &
airflow_webserver_pid=$!
echo "kill ${airflow_webserver_pid} # airflow webserver" >> cancel.sh

# Transfer dags to dags folder
if [ -d "dags" ]; then
    dags_folder=$(cat ${AIRFLOW_HOME}/airflow.cfg | grep dags_folder | cut -d'=' -f2)
    if ! [ -z "${dags_folder}" ]; then
        mkdir -p ${dags_folder}
        cp -r dags/* ${dags_folder}
    fi
fi

sleep inf
