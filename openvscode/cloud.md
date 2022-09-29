## OpenVSCode Server Interactive Session
This workflow starts an [OpenVSCode Server](https://github.com/gitpod-io/openvscode-server) in a slurm partition or in the controller node. The services are started in the selected slurm partition using an sbatch command.

Optionally add a [Github Authentication Token](https://docs.github.com/en/enterprise-server@3.4/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) to access your Github Account.

#### Instructions

* Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/job-number` directory.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session.html file (double click) in the job directory.
* To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).

