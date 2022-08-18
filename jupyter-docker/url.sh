export URLEND="tree?dt=\"+(new Date()).getTime()"

if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="pwide-kube-nb"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="pwide-nb"
    export IPADDRESS="$PW_USER_HOST"
fi