## Juice Server Session
This workflow starts a Jupyter Notebook [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README.md) using the specified docker repository.

### Examples
1. [TensorFlow](https://www.tensorflow.org/install/docker): `tensorflow/tensorflow:2.7.0-gpu-jupyter`. The latest version of TensorFlow may be incompatible with the cuda version. The older versions may contain incompatible jupyter notebook versions. 
2. [PyTorch](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/pytorch): `nvcr.io/nvidia/pytorch:22.01-py3`
