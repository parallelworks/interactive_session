## Jupyter Interactive Session
This workflow starts a Jupyter server on a scheduled compute node or on the controller/login node, depending on the **Schedule Job?** setting. When scheduled, the job is submitted via `sbatch` (SLURM) or `qsub` (PBS).

#### Instructions

* Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/<workflow-name>/<job-name>/` directory.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session by clicking its link in COMPUTE > Workflow Monitor.
* To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).

