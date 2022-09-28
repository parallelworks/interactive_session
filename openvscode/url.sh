server_dir=__server_dir__

if [ -z ${server_dir} ] || [[ "${server_dir}" == "__""server_dir""__" ]]; then
    server_dir=~/
fi

export URLEND="?folder=${server_dir}\""

if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="pwide-kube"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="pwide"
    export IPADDRESS="$PW_USER_HOST"
fi