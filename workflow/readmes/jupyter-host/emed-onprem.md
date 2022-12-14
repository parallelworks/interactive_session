## Jupyter Interactive Session
This workflow starts a Jupyter server in a slurm partition or in the controller node. The services are started in the selected slurm partition using an sbatch command.

#### Instructions

* Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/<job-number>` directory.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session.html file (double click) in the job directory.
* To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).
* Local execution of this workflow (i.e. launching the session) is logged in `/pw/jobs/<job-number>/std.out` and `std.err`.
* Remote execution logging (i.e. what happens on the compute node) is logged in `/pw/jobs/<job-number>/session-<job-number>.out`.
