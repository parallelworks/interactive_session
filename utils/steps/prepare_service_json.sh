#!/bin/bash
# Edit service.json 
source utils/load-env.sh
source resources/host/inputs.sh

set -x 

echo "Editing the service.json file"

source ${service_name}/url.sh

# FIXME: Move this to <service-name>/url.sh
if [[ "${service_name}" == "nicedcv" ]] || [[ "${service_name}" == "hammerspace" ]]; then
    URL="\"/sme/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/sme\",|" service.json
else
    URL="\"/me/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/me\",|" service.json
fi

# JSON values cannot contain quotes "
#URL_JSON=$(echo ${URL} | sed 's|\"|\\\\\"|g')
#sed -i "s|.*URL.*|    \"URL\": \"${URL_JSON}\",|" service.json
sed -i "s|.*PORT.*|    \"PORT\": \"${openPort}\",|" service.json
SLUG=$(echo ${URLEND} | sed 's|\"|\\\\\"|g')
sed -i "s|.*SLUG.*|    \"SLUG\": \"${SLUG}\",|" service.json

cat service.json