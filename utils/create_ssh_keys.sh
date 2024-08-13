#!/bin/bash

if ! [ -f "${HOME}/.ssh/pw_id_rsa" ]; then
    ssh-keygen -t rsa -N "" -q -f  ${HOME}/.ssh/pw_id_rsa
fi