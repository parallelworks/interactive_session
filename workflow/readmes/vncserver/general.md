## Desktop Interactive Session
This workflow starts a remote desktop [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md) accessible via a web browser, on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the `Target Type` input to select your environment.

## Kubernetes Cluster
Launches KasmVNC on a Kubernetes cluster using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `kasmweb/desktop:1.16.0` from [this](https://hub.docker.com/r/kasmweb/desktop) DockerHub repository. Enter `kasm_user` when prompted for a user.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.


## Compute Cluster
 It utilizes either TurboVNC, TigerVNC or KasmVNC, depending on which is installed on the target resource.
