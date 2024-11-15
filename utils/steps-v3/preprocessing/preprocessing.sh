#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

sed -i 's|\\\\|\\|g' inputs.sh
