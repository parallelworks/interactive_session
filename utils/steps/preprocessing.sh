#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

sed -i 's|\\\\|\\|g' inputs.sh

# FIXME: Need to move files from utils directory to avoid updating the sparse checkout
cp utils/service.json .