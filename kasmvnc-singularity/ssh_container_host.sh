#!/bin/bash
xfce4-terminal --command="bash -c \"ssh -i ${HOME}/.ssh/pw_id_rsa ${USER}@localhost; exec bash\""