## MLflow Interactive Session
This workflow starts an [mlflow server](https://mlflow.org/docs/latest/cli.html#mlflow-server) [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md), on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the `Target Type` input to select your environment.

## Compute Cluster
Launches MLFlow on a **Compute Cluster** using a user-specified install or load command. 

## Kubernetes Cluster
This workflow launches MLFlow on a **Kubernetes Cluster** using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `ubuntu/mlflow:2.1.1_1.0-22.04`.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.