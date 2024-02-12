## Docker Service
This workflow connects a service hosted in a Docker container to the Parallel Works platform using the [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README.md) workflow framework.  It accepts a Docker command to start the server, which can utilize the following special placeholders replaced by the workflow:
1. `__docker_port__``
2. `__base_url__``
3. `__container_name__``

Two examples are provided below for Matlab and Tensorflow. 

Matlab:
```
sudo -n docker run -i --rm --name __container_name__  -v /home/alvaro:/home/alvaro -p __docker_port__:__docker_port__ --shm-size=512M --env MWI_ENABLE_WEB_LOGGING=True  --env MWI_APP_HOST=0.0.0.0 --env MWI_APP_PORT=__docker_port__ --env MWI_ENABLE_TOKEN_AUTH=False --env MWI_BASE_URL=__base_url__  mathworks/matlab:r2022a  -browser
```

TensorFlow:
```
sudo -n docker run -i --rm --name __container_name__  -v /home/alvaro:/home/alvaro -p __docker_port__:__docker_port__ tensorflow/tensorflow:latest-gpu-jupyter jupyter-notebook --port=__docker_port__ --ip=0.0.0.0 --no-browser  --allow-root --ServerApp.trust_xheaders=True  --ServerApp.allow_origin='*'  --ServerApp.allow_remote_access=True --ServerApp.token=""  --ServerApp.base_url=__base_url__
```
