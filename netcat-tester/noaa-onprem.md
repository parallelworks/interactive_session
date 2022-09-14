## Netcat Interactive Session Tester

This workflow starts submits a job to a slurm scheduler for running of a remote interactive "blocking" session on a given port.

Specifically, this demo app uses netcat to start a mock web server on a remote compute node submitted and provisioned through slurm, and then generates a simple session.html file that can be viewed directly within the Parallel Works environment.

This workflow's intent is to provide a tester for remote resource networking, and as a base template for other interactive session workflows like jupyter notebooks, R server and noVNC.

#### Instructions

* Enter form parameters for the submitted slurm job.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session.html file (double click) in the job directory.
* The netcat webserver should return a hello world statement.