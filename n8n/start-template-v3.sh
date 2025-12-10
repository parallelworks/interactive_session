# Runs via ssh + sbatch
set -x

mkdir -p n8n_data
chmod 777 n8n_data -Rf

cat >> docker-compose.yml <<HERE
services:
  n8n:
    image: ${service_docker_repo}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${service_port}:8989"
    environment:
      - GENERIC_TIMEZONE=UTC
      - N8N_HOST=localhost
      - N8N_PORT=8989
      - N8N_PROTOCOL=http
      - N8N_PATH=${basepath}
      - N8N_EDITOR_BASE_URL=https://${pw_platform_host}${basepath}
      - WEBHOOK_URL=https://${pw_platform_host}${basepath}
    volumes:
      - ./n8n_data:/home/node/.n8n

HERE

stack_name=$(echo "n8n${job_name}" | tr '/' '-' | tr '.' '-' | tr '[:upper:]' '[:lower:]')


if [ ${#stack_name} -gt 50 ]; then
    stack_name=${stack_name: -50}
fi

sudo systemctl start docker
docker_compose_cmd="sudo docker compose -p ${stack_name}"

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} != "CONTROLLER" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
${docker_compose_cmd} down 
HERE

${docker_compose_cmd} up

${docker_compose_cmd} logs -f
