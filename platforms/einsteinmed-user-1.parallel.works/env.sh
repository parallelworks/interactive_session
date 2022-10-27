export CONDA_PYTHON_EXE=/public/apps/conda3/bin/python3

rsync /swift-pw-bin/apps/*.tgz ~/pw/bootstrap

export USER_CONTAINER_HOST=${PW_USER_HOST} 