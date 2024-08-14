#!/bin/bash

config_file=$1

if ! [ -f "${HOME}/.ssh/pw_id_rsa" ]; then
    ssh-keygen -t rsa -N "" -q -f ${HOME}/.ssh/pw_id_rsa
fi

# Modify the ssh config file for Host usercontainer
sed -i '/Host usercontainer/{:a;n;/IdentityFile/s/id_rsa/pw_id_rsa/;Ta}' "$config_file"
