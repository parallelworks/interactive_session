from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from airflow.sensors.filesystem import FileSensor
from datetime import datetime
import time
import os
import subprocess

AIRFLOW_HOME = os.environ.get('AIRFLOW_HOME')
# Retrieves the installation path of the Conda environment where Airflow is currently running
# Only works if airflow is installed in the base environment!  
CONDA_PREFIX = os.environ.get('CONDA_PREFIX')
WRF_CONDA_ENVIRONMENT="wrf-33"
DATA_PARENT_DIRECTORY = os.path.join(
    os.path.expanduser("~"),
    'wrf_data'
)

def get_slurm_status(job_id):
    result = subprocess.run(["squeue", "-j", job_id, "-h", "-o", "%T"], capture_output=True, text=True)
    status = result.stdout.strip()
    
    if status == "":
        result = subprocess.run(["sacct", "-j", job_id, "--format=state", "-n"], capture_output=True, text=True)
        status = result.stdout.split('\n')[0].strip()
    
    return status

def print_file_contents(file_path):
    if os.path.exists(file_path):
        with open(file_path, "r") as file:
            print(f"\nContents of {file_path}:")
            print(file.read())
    else:
        print(f"File {file_path} not found.")

def monitor_slurm_job(data_dir, **kwargs):
    job_id = kwargs['ti'].xcom_pull(task_ids='submit_job', key='return_value')
    if not job_id:
        raise ValueError("SLURM Job ID not found")
    
    print(f"Monitoring SLURM Job ID: {job_id}")
    slurm_log_file = f"{data_dir}/plot_wrf.{job_id}.out"
    print(f"SLURM job log file: {slurm_log_file}")
    while True:
        status = get_slurm_status(job_id)
        
        if status in ["", "COMPLETED"]:
            print(f"Job {job_id} completed successfully or no longer in queue.")
            break
        elif status in ["FAILED", "CANCELLED", "TIMEOUT", "NODE_FAIL", "OUT_OF_MEMORY"]:
            print_file_contents(slurm_log_file)
            raise RuntimeError(f"SLURM job {job_id} failed with status: {status}")
        else:
            print(f"Job {job_id} is in status: {status}. Checking again in 30 seconds...")
            time.sleep(30)
    
    print_file_contents(slurm_log_file)


def write_slurm_script(data_dir, **kwargs):
    script_path = os.path.join(AIRFLOW_HOME, "dags", "plot_wrf_data.py")
    slurm_script_path = os.path.join(data_dir, "slurm_script.sh")
    
    if not os.path.exists(script_path):
        raise FileNotFoundError(f"Script {script_path} not found")
    
    slurm_script_content = f"""#!/bin/bash
#SBATCH --job-name=plot_wrf.%j
#SBATCH --output={data_dir}/plot_wrf.%j.out
#SBATCH --time=00:30:00
#SBATCH --ntasks=1
source {CONDA_PREFIX}/etc/profile.d/conda.sh 
conda activate {WRF_CONDA_ENVIRONMENT}
python {AIRFLOW_HOME}/dags/plot_wrf_data.py {data_dir}/wrf-output
"""
    
    with open(slurm_script_path, 'w') as slurm_script:
        slurm_script.write(slurm_script_content)
    
    kwargs['ti'].xcom_push(key='slurm_script_path', value=slurm_script_path)

with DAG(
    dag_id='submit_slurm_python_script',
    default_args={
        'owner': 'airflow',
        'start_date': datetime(2024, 3, 13),
        'retries': 1,
    },
    schedule_interval=None,
    catchup=False,
    tags=['slurm', 'sbatch', 'python-script']
) as dag:

    # Get current date
    today = datetime.now()

    # Format and print the date
    formatted_date = today.strftime('%Y-%m-%d')

    data_directory = os.path.join(DATA_PARENT_DIRECTORY, formatted_date)

    verify_or_create_conda_env = BashOperator(
        task_id='verify_or_create_conda_env',
        bash_command=f"""
        source {CONDA_PREFIX}/bin/activate

        if conda env list | grep -q "{WRF_CONDA_ENVIRONMENT}"; then
            echo "Conda environment {WRF_CONDA_ENVIRONMENT} exists."
        else
            echo "Creating Conda environment..."
            conda create -y -n {WRF_CONDA_ENVIRONMENT}
            conda activate {WRF_CONDA_ENVIRONMENT}
            conda install -y -c conda-forge xarray matplotlib ffmpeg netCDF4
        fi
        """,
    )

    wait_for_directory = FileSensor(
        task_id='wait_for_directory',
        filepath=data_directory,
        poke_interval=30,  # Check every 30 seconds
        timeout=3600,  # Timeout after 1 hour
        mode='poke',
    )

    write_script = PythonOperator(
        task_id='write_script',
        python_callable=write_slurm_script,
        op_kwargs={'data_dir': data_directory},
        provide_context=True,
    )

    submit_job = BashOperator(
        task_id='submit_job',
        bash_command="sbatch --parsable {{ ti.xcom_pull(task_ids='write_script', key='slurm_script_path') }}",
        do_xcom_push=True,
    )

    monitor_job = PythonOperator(
        task_id='monitor_job',
        python_callable=monitor_slurm_job,
        op_kwargs={'data_dir': data_directory},
        provide_context=True,
    )

    verify_or_create_conda_env >> wait_for_directory >> write_script >> submit_job >> monitor_job
