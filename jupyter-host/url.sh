#export URLEND="tree?dt=\"+(new Date()).getTime()"
export URLEND="tree/home/${PW_USER}\""

if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="pwide-kube-nb"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="pwide-nb"
    export IPADDRESS="$PW_USER_HOST"
fi