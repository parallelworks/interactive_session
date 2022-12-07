export URLEND="tree?dt=\"+(new Date()).getTime()"
#export URLEND="tree/home/${PW_USER}\""

if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="me"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="me"
    export IPADDRESS="$PW_USER_HOST"
fi