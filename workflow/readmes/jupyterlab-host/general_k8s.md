# JupyterLab Interactive Session
This workflow starts a JupyterLab server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md), on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the Target Type input to select your environment.


## Compute Cluster
Launches a JupyterLab server on a **Compute Cluster** using SLURM or PBS.

### Dask Integration on Parallel Works
Refer to the included Jupyter notebook at `jupyterlab-host/dask-extension-jupyterlab-demo.ipynb` for a practical guide illustrating:

1. Deployment of Dask on a SLURM cluster using the [SLURMCluster](https://jobqueue.dask.org/en/latest/generated/dask_jobqueue.SLURMCluster.html) object.
2. Data transfer to and from a PW storage resource, corresponding to an AWS S3 bucket. Authentication is streamlined through short-term credentials.
3. Integration of the [Dask extension for JupyterLab](https://github.com/dask/dask-labextension)

A sample YAML file outlining Dask dependencies for PW is provided at `jupyterlab-host/dask-extension-jupyterlab.yaml`. These dependencies are automatically installed by selecting the input form parameters displayed in this [screenshot](https://raw.githubusercontent.com/parallelworks/interactive_session/jupyterlab-yaml-file/workflow/readmes/jupyterlab-host/dask-input-form.png). Alternatively, you have the option to use your own YAML file.
 


## Kubernetes Cluster
Launches a JupyterLab server on a **Kubernetes Cluster** using a user-specified image and resource settings. The image must have JupyterLab pre-installed.

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Use a JupyterLab-compatible image (default: jupyter/datascience-notebook).
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy JupyterLab and access it via a web interface.

### Using Nvidia GPUs
For GPU-accelerated workloads, use images from the [Nvidia NGC Catalog](https://catalog.ngc.nvidia.com/containers). **Ensure that the driver version on the node meets the minimum driver requirement for that image.**

Examples:
- **PyTorch:**  `nvcr.io/nvidia/pytorch:24.09-py3`
- **TensorFlow:** `nvcr.io/nvidia/tensorflow:25.02-tf2-py3`


#### Test GPU Access in JupyterLab

##### PyTorch
```
import torch
if torch.cuda.is_available():
    num_gpus = torch.cuda.device_count()
    print(f"GPU is available. Number of GPUs: {num_gpus}")
    for i in range(num_gpus):
        print(f" - GPU {i}: {torch.cuda.get_device_name(i)}")
else:
    print("No GPU available. Using CPU only.")
```

##### TensorFlow
```
import tensorflow as tf
physical_devices = tf.config.list_physical_devices('GPU')
if physical_devices:
    print(f"TensorFlow detected {len(physical_devices)} GPU(s).")
    for i, device in enumerate(physical_devices):
        print(f" - GPU {i}: {device}")
else:
    print("No GPU available. Using CPU only.")
```

##### Nvidia MIG Instances
To use more than one Multi-Instance GPUs (MIG) set the `CUDA_VISIBLE_DEVICES` environment variable.
```
!nvidia-smi -L | grep MIG | grep -o 'MIG-[a-f0-9-]\+'
import os
# Replace with the MIG instance IDs
os.environ["CUDA_VISIBLE_DEVICES"] = (
    "MIG-5a9b896b-dbaa-50ca-bd8d-6c50ed9b31c1,"
    "MIG-9dc7b6fb-7215-536d-b2c3-5ee18463260c"
)
```
