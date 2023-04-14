## Jupyter Interactive Session
This workflow starts a Jupyter server in a slurm partition or in the controller node. The services are started in the selected slurm partition using an sbatch command.

#### Instructions

* Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/<job-number>` directory.
* Wait for node to be provisioned from slurm.
* Once provisioned, open the session.html file (double click) in the job directory.
* To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).
* Local execution of this workflow (i.e. launching the session) is logged in `/pw/jobs/<job-number>/std.out` and `std.err`.
* Remote execution logging (i.e. what happens on the compute node) is logged in `/pw/jobs/<job-number>/session-<job-number>.out`.

#### Using multiple conda environments with notebooks

There are two things to keep in mind with using custom Conda environments with Jupyter notebooks:
1. The workflow that starts the notebook needs to know which Conda environment has the necessary software for **displaying** the notebook. This can be installed into a Conda environment with:
```bash
conda install -c conda-forge jupyter
conda install nb_conda_kernels
conda install -c anaconda jinja2
conda install requests
pip install remote_ikernel
```
Normally, the `base` environment already has these packages and users do not need to install them unless they want to create their own environments or they are experiencing package conflicts. This is why the workflow form has the `base` environment as the default entry for the `Conda environment` field.

2. Once displayed, notebooks can also connect to remote kernels running in other Conda environments. Changing the kernel allows users to run the notebook code in the Conda environment of their choice.  A notebook can be connected to only one kernel at a time. Users select their kernels via the `Kernel -> Change Kernel` menu item in any Jupyter notebook. In order for a Conda environment to appear in the list of available kernels, it must have the following packages installed:
```bash
conda install requests
conda install ipykernel
conda install -c anaconda jinja2
```
User customized Conda environments installed in `$HOME/.conda/` (the default location) will appear in the `Kernel -> Change Kernel` list prefixed with `.conda-`. The Conda environment that was used to launch/display the notebook (i.e. the environment that is specified in the `Conda environment` field of the Jupyter notebook launch form) is listed first as simply `ipykernel` (even though it may have a different name when that same environment is listed under `conda env list`).
