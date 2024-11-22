## Start ngenCERF
This workflow starts and connects the ngenCERF service as a PW [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README.md).


The ngencerf_start workflow runs on the controller node of a shared SLURM cluster and performs the following actions:
- Starting Docker Containers: Uses docker compose up to launch the service containers.
- NGINX Wrapper: Configures and runs an NGINX wrapper to manage HTTP requests.
- SLURM Wrapper: Initiates a SLURM wrapper application, enabling the main service to submit jobs to the SLURM scheduler via a REST API.
- SSH Tunnel: Creates an SSH tunnel for secure access to the UI from the platform

Most of the inputs to the workflow are configured in this [file](https://github.com/parallelworks/interactive_session/blob/main/workflow/yamls/ngencerf/start.yaml). To share the session with other users please follow the instructions on this [link](https://parallelworks.com/docs/run/sessions/running-sessions). 


Note that you will need to rebuild the app every time the session name changes or every time a different user starts the app. 