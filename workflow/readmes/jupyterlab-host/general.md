## JupyterLab Interactive Session
This workflow starts a JupyterLab server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README.md).


### Requirements
This workflow is designed to seamlessly function on PW cloud clusters or clusters where the user possesses root or docker access. 

If you intend to deploy this workflow on alternative resources, like an on-prem cluster, you need to create and share an nginx singularity containerby following the instructions outlined below:


```
Bootstrap: docker
From: nginxinc/nginx-unprivileged
```

Afterwards, execute the command:

```
singularity build nginx-unprivileged.simg nginx_unprivileged.def
```

Ensure that the workflow has access to the specified path for the resultant nginx-unprivileged.simg.

### Dask Integration on Parallel Works
Refer to the included Jupyter notebook at `jupyterlab-host/dask-extension-jupyterlab-demo.ipynb` for a practical guide illustrating:

1. Deployment of Dask on a SLURM cluster using the [SLURMCluster](https://jobqueue.dask.org/en/latest/generated/dask_jobqueue.SLURMCluster.html) object.
2. Data transfer to and from a PW storage resource, corresponding to an AWS S3 bucket. Authentication is streamlined through short-term credentials.
3. Integration of the [Dask extension for JupyterLab](https://github.com/dask/dask-labextension)

A sample YAML file outlining Dask dependencies for PW is provided at `jupyterlab-host/dask-extension-jupyterlab.yaml`. These dependencies are automatically installed by selecting the input form parameters displayed in this [screenshot](https://raw.githubusercontent.com/parallelworks/interactive_session/jupyterlab-yaml-file/workflow/readmes/jupyterlab-host/dask-input-form.png). Alternatively, you have the option to use your own YAML file.
 
