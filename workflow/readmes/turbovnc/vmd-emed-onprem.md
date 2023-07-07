## Visual Molecular Dynamics Interactive Session
This workflow starts an interactive session for [VMD](http://www.ks.uiuc.edu/Research/vmd/) in a desktop environment. The services are started in the selected slurm partition using an sbatch command.

#### Instructions

* Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/<workflow-name>/<job-name>/` directory.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session.html file (double click) in the job directory.
* To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).

