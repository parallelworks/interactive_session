if [[ "$USERMODE" == "k8s" ]];then
    export FORWARDPATH="pwide-kube"
    export IPADDRESS="$(hostname -I | xargs)"
else
    export FORWARDPATH="pwide"
    export IPADDRESS="$PW_USER_HOST"
fi

export URLEND="vnc.html?autoconnect=true\&show_dot=true\&path=websockify\&password=headless\&host=\"+window.location.host+\"/${FORWARDPATH}/${IPADDRESS}/__OPENPORT__\"+\"\/\&dt=\"+(new Date()).getTime()"
