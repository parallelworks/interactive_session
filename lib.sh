if [ ! -z "${KUBERNETES_PORT}" ];then
    export USERMODE="k8s"
else
    export USERMODE="docker"
fi

echod() {
    echo $(date): $@
}


displayErrorMessage() {
    echo $(date): $1
    sed -i "s/.*ERROR_MESSAGE.*/    \"ERROR_MESSAGE\": \"$1\"/" service.json
    exit 1
}

