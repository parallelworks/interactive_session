## Start ngenCERF
This workflow starts and connects the ngenCERF service as a PW [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README.md).


The ngencerf_start workflow runs on the controller node of a shared SLURM cluster and performs the following actions:
- Starting Docker Containers: Uses docker compose up to launch the service containers.
- NGINX Wrapper: Configures and runs an NGINX wrapper to manage HTTP requests.
- SLURM Wrapper: Initiates a SLURM wrapper application, enabling the main service to submit jobs to the SLURM scheduler via a REST API.
- SSH Tunnel: Creates an SSH tunnel for secure access to the UI from the platform

Most of the inputs to the workflow are configured in this [file](https://github.com/parallelworks/interactive_session/blob/main/workflow/xmls/ngencerf/ngencerf.xml). Other users on the cluster can connect to the service by running the `ngencerf_connect` workflow on the shared cluster where the ngencerf_start workflow is running. Upon cancellation of the workflow, all services are terminated to release resources.


**Important Note:**
- The `ngencerf_start` workflow also allows the user to connect to the UI.
- The `ngencerf_connect` workflow should not be run by the same user as the ngencerf_start workflow!
