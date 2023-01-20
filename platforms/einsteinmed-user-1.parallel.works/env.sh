export CONDA_PYTHON_EXE=/public/apps/conda3/bin/python3
export EXPAND_ALIASES="shopt -s expand_aliases &&"

mkdir -p  ~/pw/bootstrap
rsync /swift-pw-bin/apps/* ~/pw/bootstrap

export USER_CONTAINER_HOST=${PW_USER_HOST} 

# Separate multiple lines with ;#
export RUNTIME_FIXES="source ~/.bashrc"

# Path to /pw
export PW_PATH=${HOME}