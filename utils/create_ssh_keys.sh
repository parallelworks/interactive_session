#!/bin/bash

if ! [ -f "${HOME}/.ssh/id_rsa" ]; then
    ssh-keygen -t rsa -N "" -q -f  ${HOME}/.ssh/id_rsa
fi