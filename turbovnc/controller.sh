sshusercontainer="ssh ${resource_ssh_usercontainer_options_controller} -f ${USER_CONTAINER_HOST}"


displayErrorMessage() {
    echo $(date): $1
    ${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\"ERROR_MESSAGE\\\": \\\"$1\\\"|\" /pw/jobs/desktop_noaa/00022/service.json"
    ${sshusercontainer} "sed -i \"s|.*JOB_STATUS.*|    \\\"JOB_STATUS\\\": \\\"FAILED\\\",|\" /pw/jobs/desktop_noaa/00022/service.json"
    exit 1
}


bootstrap_tgz() {
    tgz_path=$1
    install_dir=$2
    # Check if the code directory is present
    # - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
    if ! [ -d "${install_dir}" ]; then
        echo "Bootstrapping ${install_dir}"
        install_parent_dir=$(dirname ${install_dir})
        mkdir -p ${install_parent_dir}
        
        # first check if the noVNC file is available on the node
        if [[ -f "/core/pworks-main/${tgz_path}" ]]; then
            cp /core/pworks-main/${tgz_path} ${install_parent_dir}
        else
            echo "Copying ${tgz_path} from user container"
            echo "rsync -avzq -e \"ssh ${resource_ssh_usercontainer_options}\" ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}"
            rsync -avzq -e "ssh ${resource_ssh_usercontainer_options}" ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
        fi
        tar -zxf ${install_parent_dir}/$(basename ${tgz_path}) -C ${install_parent_dir}
    fi
    # Check if the directory exists
    if [ -d "${install_dir}" ]; then
        # Check if the directory is empty
        if [ -z "$(ls -A "${install_dir}")" ]; then
            displayErrorMessage "Error tranferring noVNC files. Directory ${install_dir} is empty"
        fi
    else
        displayErrorMessage "Error tranferring noVNC files. Directory ${install_dir} does not exist"
    fi
}

bootstrap_tgz ${novnc_tgz} ${novnc_dir}