# Metabase Interactive Session
This workflow starts a Metabase server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md), on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the `Target Type` input to select your environment.

## Compute Cluster
Launches a metabase server on a **Compute Cluster** using a user-specified docker image. Default is `metabase/metabase` from [this](https://hub.docker.com/r/metabase/metabase) DockerHub repository.

## Kubernetes Cluster
This workflow launches Metabase on a **Kubernetes Cluster** using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `metabase` from [this](https://hub.docker.com/r/metabase/metabase/) DockerHub repository.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Metabase and access it via a web interface.



