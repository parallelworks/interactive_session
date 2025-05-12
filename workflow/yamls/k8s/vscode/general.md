## JupyterLab on Kubernetes 
This workflow launches Code Server on a Kubernetes cluster using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `codercom/code-server:latest` from [this](https://hub.docker.com/r/codercom/code-server) DockerHub repository.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.

