## RStudio Interactive Session

This workflow starts an interactive session for RStudio in a desktop environment. The services are started in the selected slurm partition using an sbatch command.

#### Instructions

- Enter form parameters and click _Execute_ to launch a PW job. The job status can be monitored under COMPUTE > Workflow Monitor. The job files and logs are under the newly created `/pw/jobs/<workflow-name>/<job-name>/` directory.
- Wait for node to be provisioned from slurm.
- Once provisioned, open the session.html file (double click) in the job directory.
- To close a session kill the PW job by clicking on COMPUTE > Workflow Monitor > Cancel Job (red icon).



#### Requirements
Needs RStudio, novnc and a desktop environment. A snapshot can be created in PW > ACCOUNT > Cloud Snapshots using the following build script:
```
sudo yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo
sudo -n yum install tigervnc-server -y
sudo -n yum install python3 -y
sudo -n yum groupinstall "Server with GUI" -y
sudo -n yum install epel-release -y 
sudo -n yum install R -y 
wget https://download1.rstudio.org/desktop/centos7/x86_64/rstudio-2022.07.2-576-x86_64.rpm
sudo -n yum install rstudio-2022.07.2-576-x86_64.rpm -y
```