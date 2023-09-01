if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="pwide-kube"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="pwide"
    export IPADDRESS="$PW_USER_HOST"
fi


export URLEND="\""
