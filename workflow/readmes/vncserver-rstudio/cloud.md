## Rstudio Interactive Session

This workflow starts Rstudio in an a desktop environment. The workflow may take 10/15 minutes to install TigerVNC, Gnome Desktop and Rstudio if this are not installed in the base image.

#### Instructions

- Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/job-number` directory.
- Wait for node to be provisioned from slurm.
- Once provisioned, open the session.html file (double click) in the job directory.
- To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).
