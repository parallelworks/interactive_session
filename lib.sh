echod() {
    echo $(date): $@
}


displayErrorMessage() {
    echo $(date): $1
    sed -i "s/.*ERROR_MESSAGE.*/    \"ERROR_MESSAGE\": \"$1\"/" service.json
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"FAILED\"/" service.json
    exit 1
}

