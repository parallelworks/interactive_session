# The URL downloads a different file when using wget/curl than when pasting it in the browser
# service_copilot_url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage"
service_copilot_usercontainer_path="${pw_job_dir}/${service_name}/GitHub.copilot-latest.vsix"

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${resource_workdir}/pw/software
fi


# Define the remote file path
remote_file="${service_parent_install_dir}/$(basename ${service_copilot_usercontainer_path})"

# Check if the file exists on the remote server using ls
ls_output=$(${sshcmd} "ls ${remote_file} 2>/dev/null")

# Check if ls_output is empty
if [ -z "${ls_output}" ]; then
    echo "Transferring file ${service_copilot_usercontainer_path} to ${remote_file}"
    rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${service_copilot_usercontainer_path} ${resource_publicIp}:${service_parent_install_dir}
else
    echo "File ${remote_file} exists already"
fi
