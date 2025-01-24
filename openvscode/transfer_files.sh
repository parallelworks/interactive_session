# The URL downloads a different file when using wget/curl than when pasting it in the browser
# service_copilot_url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage"
service_copilot_usercontainer_path="${pw_job_dir}/${service_name}/GitHub.copilot-latest.vsix"

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${resource_workdir}/pw/software
fi

rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${service_copilot_usercontainer_path} ${resource_publicIp}:${service_parent_install_dir}
