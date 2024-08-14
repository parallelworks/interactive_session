#!/bin/bash

config_file=$1

if ! [ -f "${HOME}/.ssh/pw_id_rsa" ]; then
    ssh-keygen -t rsa -N "" -q -f ${HOME}/.ssh/pw_id_rsa
fi

# Check if the IdentityFile for usercontainer is already set to pw_id_rsa
if grep -q "Host usercontainer" "$config_file" && grep -q "IdentityFile.*pw_id_rsa" "$config_file"; then
    echo "pw_id_rsa is already set, no changes made."
else
    # Modify id_rsa to pw_id_rsa if pw_id_rsa is not already set
    sed -i '/Host usercontainer/{:a;n;/IdentityFile/s/id_rsa/pw_id_rsa/;Ta}' "$config_file"
    echo "IdentityFile for usercontainer updated to pw_id_rsa."
fi
