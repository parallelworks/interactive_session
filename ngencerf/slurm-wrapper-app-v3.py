import subprocess
import os, shutil
from flask import Flask, request, jsonify
import socket
import copy
import logging
from logging.handlers import RotatingFileHandler
import time

log_file_path = os.environ.get("LOG_FILE_PATH", "app.log")
file_handler = RotatingFileHandler(log_file_path, maxBytes=10*1024*1024, backupCount=100)  # 10MB per file
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s - %(message)s',
    handlers=[file_handler]
)
logger = logging.getLogger(__name__)

CONTROLLER_HOSTNAME = socket.gethostname()

# Path to the data directory in the shared filesystem
LOCAL_DATA_DIR = os.environ.get('local_data_dir')  # "/ngencerf-app/data/ngen-cal-data/"
# Path to the data directory within the container
CONTAINER_DATA_DIR = os.environ.get('container_data_dir')  # "/ngencerf/data/"
# Callback dir
CALLBACKS_DIR = os.path.join(LOCAL_DATA_DIR, "slurm-callbacks", "submitted")
# Path to the singularity container with ngen-cal
NWM_CAL_MGR_SINGULARITY_CONTAINER_PATH = os.environ.get('nwm_cal_mgr_singularity_container_path')
# Path to the singularity container with ngen-forcing
NGEN_BMI_FORCING_SINGULARITY_CONTAINER_PATH = os.environ.get('ngen_bmi_forcing_singularity_container_path')
# Path to the singularity container with ngen-forcing
NWM_FCST_MGR_SINGULARITY_CONTAINER_PATH = os.environ.get('nwm_fcst_mgr_singularity_container_path')
# Path to the nwm_verf singularity container
NWM_VERF_SINGULARITY_CONTAINER_PATH = os.environ.get('nwm_verf_singularity_container_path')
# URL to callback from ngencal to the other services
NGENCERF_URL = f"http://{CONTROLLER_HOSTNAME}:8000"
# Command to launch singularity
SINGULARITY_RUN_NWM_CAL_MGR_CMD = f"/usr/bin/time -v singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NWM_CAL_MGR_SINGULARITY_CONTAINER_PATH}"
SINGULARITY_RUN_NGEN_BMI_FORCING_CMD = f"/usr/bin/time -v singularity exec -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NGEN_BMI_FORCING_SINGULARITY_CONTAINER_PATH} /ngen-app/bin/run-ngen-forcing.sh"
SINGULARITY_RUN_NWM_FCST_MGR_CMD = f"/usr/bin/time -v singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NWM_FCST_MGR_SINGULARITY_CONTAINER_PATH}"
SINGULARITY_RUN_NWM_VERF_CMD = f"/usr/bin/time -v singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NWM_VERF_SINGULARITY_CONTAINER_PATH}"

# Slurm job metrics for sacct command
SLURM_JOB_METRICS = os.environ.get('SLURM_JOB_METRICS')

# List of partitions
PARTITIONS_STR = os.environ.get('PARTITIONS')
# Convert the string to a list
if PARTITIONS_STR:
    PARTITIONS = PARTITIONS_STR.split(',')
else:
    PARTITIONS = []

# Max time in seconds the job spends with CF or PD status
MAX_CONFIGURING_WAIT_TIME = int(os.environ.get('MAX_CONFIGURING_WAIT_TIME'))

# Jobs with CF status
configuring_jobs = {}

app = Flask(__name__)


def log_and_return_error(message, status_code=500):
    logger.error(message)
    return jsonify({"error": message}), status_code


def get_next_partition(current_partition=None):
    """
    Returns the next partition in the list based on the current partition.

    If no current partition is provided, it returns the first partition in the list.
    If the provided current partition is not found in the list, it returns None.

    Parameters:
    - current_partition: str or None, the partition currently being used. If None, the first partition is returned.

    Returns:
    - str: the next partition in the list, the first partition if current_partition is None, or None if current_partition is not found.
    """

    # If no current_partition is provided, return the first partition if it exists
    if current_partition is None:
        if PARTITIONS:
            return PARTITIONS[0]
        return None  # Return None if PARTITIONS is empty

    # If the current_partition is not valid, return None
    if current_partition not in PARTITIONS:
        return None

    # Get the index of the current partition
    current_index = PARTITIONS.index(current_partition)

    # Calculate the next index using modulo to wrap around
    next_index = (current_index + 1) % len(PARTITIONS)

    # Return the next partition
    return PARTITIONS[next_index]



def get_callback(callbacks_dir, callback_url, auth_token, **kwargs):
    # Prepare the data dictionary excluding the auth_token
    data = {key: value for key, value in kwargs.items()}

    # Create the JSON string for the --data parameter
    json_data = ', '.join([f'\"{key}\": \"{value}\"' for key, value in data.items()])

    # Construct the complete curl command string
    callback_command = f'curl -s -o {callbacks_dir}/callback.json -w "%{{http_code}}" --location "{callback_url}" --header "Content-Type: application/json" --header "Authorization: Bearer {auth_token}" --data \'{{{json_data}}}\''
    return callback_command


def write_callback(callbacks_dir, callback_command):
    os.makedirs(callbacks_dir, exist_ok=True)
    callback_file_path = os.path.join(callbacks_dir, 'callback')
    with open(callback_file_path, 'w') as file:
        file.write(callback_command)

    logger.info(f'Writing callback script {callback_file_path}')

def ensure_file_owned(file_path: str):
    try:
        # Get the current user's UID and GID
        current_uid = os.getuid()
        current_gid = os.getgid()
        # Ensure directory exists
        file_path_dir = os.path.dirname(file_path)
        subprocess.run(f"sudo mkdir -p {file_path_dir}", shell=True, check=True)
        # Ensure directory is owned by user
        command_chown = f"sudo chown {current_uid}:{current_gid} {file_path_dir}"
        subprocess.run(command_chown, shell=True, check=True)
        # Ensure file exists
        subprocess.run(f"touch {file_path}", shell=True, check=True)
        logger.info(f"Ownership granted to file {file_path}")
        return {"success": True, "message": f"Access granted to {file_path}"}
    except subprocess.CalledProcessError as e:
        logger.exception(f"Failed to change ownership of file {file_path}")
        return {"success": False, "message": str(e)}


def write_slurm_script(run_id, job_type, input_file_local, output_file_local, singularity_run_cmd, nprocs = 1):
    job_script = output_file_local.rsplit('.', 1)[0] + '.slurm.sh'
    job_dir = os.path.dirname(os.path.dirname(input_file_local))
    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, run_id)

    # We need to change these ownerships to be able to write the SLURM script and its output file
    ensure_file_owned(job_script)
    ensure_file_owned(output_file_local)

    # Write the SLURM script
    with open(job_script, 'w') as script:
        script.write('#!/bin/bash\n')
        script.write(f'#SBATCH --job-name={job_type}-{run_id}\n')
        script.write('#SBATCH --nodes=1\n')
        script.write(f'#SBATCH --ntasks-per-node={nprocs}\n')
        script.write(f'#SBATCH --output={output_file_local}\n')
        script.write('\n')

        script.write('echo Running Job $SLURM_JOB_ID \n\n')

        # Change ownership of the directory to the current user and group
        current_uid = os.getuid()
        current_gid = os.getgid()

        # Get number of processors
        script.write('p="$(command -v nproc >/dev/null 2>&1 && nproc || echo 8)"\n')

        # Change ownership in parallel only where uid/gid differ so we skip already-correct entries
        script.write(
            f'sudo find -L "{job_dir}" \\( ! -uid {current_uid} -o ! -gid {current_gid} \\) ! -type l -print0 '
            f'| sudo xargs -0 -r -P"$p" chown {current_uid}:{current_gid}\n\n'
        )

        # Ensure the owner has read+write on files and read+write+execute on directories in parallel
        script.write(
            f'sudo find -L "{job_dir}" ! -type l '
            f'\\( ! -perm -u+r -o ! -perm -u+w -o \\( -xtype d ! -perm -u+x \\) \\) -print0 '
            f'| sudo xargs -0 -r -P"$p" chmod a+rwX\n\n'
        )


        notify_job_start_cmd = (
            f'curl -X POST http://{CONTROLLER_HOSTNAME}:5000/job-start '
            f'-d "job_type={job_type}" -d "run_id={run_id}"\n'
        )
        script.write(notify_job_start_cmd)

        # Execute the singularity command
        script.write(f'{singularity_run_cmd}\n')

        # Check if the command was successful and set the job status accordingly
        script.write('if [ $? -eq 0 ]; then\n')
        script.write('    job_status="DONE"\n')
        script.write('else\n')
        script.write('    job_status="FAILED"\n')
        script.write('fi\n')
        script.write('echo\n\n')

        # Print a message indicating the job completion
        script.write('echo Job Completed with status $job_status\n')
        script.write('echo\n\n')

        script.write(f'sed -i "s/__job_status__/${{job_status}}/g" {callbacks_dir}/callback\n')

        create_performance_files_cmd = (
            f'curl -X POST http://{CONTROLLER_HOSTNAME}:5000/postprocess '
            f'-d "slurm_job_id=$SLURM_JOB_ID" -d "job_type={job_type}" -d "run_id={run_id}"\n'
        )
        script.write(create_performance_files_cmd)

    return job_script


def submit_slurm_job(job_script, partition=None):
    """Submit a job script to SLURM and return the job ID. Optionally specify a partition."""
    try:
        command = ["sbatch"]

        if partition:
            # If a partition is provided, add it to the command
            command += ["--partition", partition]
        elif PARTITIONS:
            # If a PARTITIONS is provided use first
            command += ["--partition", PARTITIONS[0]]

        # Add the job script to the command
        command.append(job_script)

        # Use subprocess to run sbatch and capture the output
        result = subprocess.run(command, capture_output=True, text=True)

        if result.returncode != 0:
            error_msg = f"Failed to submit job script {job_script} with  command {command}: {result.stderr.strip()}"
            logger.error(error_msg)
            return None, error_msg

        # Parse SLURM job ID from sbatch output
        slurm_job_id = result.stdout.strip().split()[-1]
        return slurm_job_id, None
    except Exception as e:
        error_msg = f"Failed to submit job script {job_script}: {str(e)}"
        logger.exception(error_msg)
        return None, error_msg


def squeue_job_status(slurm_job_id):
    cmd = ["squeue", "--job", slurm_job_id, "--format=%T", "--noheader"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        error_msg = f"Failed to run command {cmd}: {result.stderr.strip()}"
        logger.error(error_msg)
        return None, error_msg

    return result.stdout.strip(), None


def submit_job(input_file, output_file, run_id, job_type, singularity_run_cmd, nprocs = 1):
    logger.info(f"Starting job submission for job run ID: {run_id}")
    # Check the file exists on the shared file system
    # Path to the input file on the shared file system
    input_file_local = input_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    output_file_local = output_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    callbacks_dir = os.path.join("postprocess", job_type, run_id)
    if not os.path.exists(input_file_local):
        error_msg = f"File path '{input_file_local}' does not exist on the shared filesystem under {LOCAL_DATA_DIR}."
        logger.exception(error_msg)
        return error_msg, 500

    try:
        # Save the script to the job's directory
        job_script = write_slurm_script(run_id, job_type, input_file_local, output_file_local, singularity_run_cmd, nprocs = nprocs)
        logger.info(f"Job script written to: {job_script}")

        # Submit the job and retrieve SLURM job ID
        slurm_job_id, error = submit_slurm_job(job_script)
        if error:
            shutil.rmtree(callbacks_dir)
            logger.info(f'Removed {callbacks_dir}')
            return jsonify({"error": error}), 500

        # Performance statistics
        performance_file_path = os.path.join(postprocessing_dir, 'performance_file')
        with open(performance_file_path, 'w') as file:
            file.write(output_file_local.replace('stdout', 'performance'))

        logger.info(f"Added performance file to {performance_file_path}")

        # Initialize job
        if PARTITIONS:
            configuring_jobs[slurm_job_id] = {}
            configuring_jobs[slurm_job_id]['ids'] = [slurm_job_id]
            configuring_jobs[slurm_job_id]['job_script'] = job_script
            configuring_jobs[slurm_job_id]['partition'] = get_next_partition()
            configuring_jobs[slurm_job_id]['start_time'] = time.time()
            logger.info(f"Adding job {slurm_job_id} - {job_script} to configuring jobs")

        return slurm_job_id, 200
    except Exception as e:
        error_msg = f"Failed to submit job: {str(e)}"
        logger.exception(error_msg)
        return error_msg, 500


@app.route('/submit-calibration-job', methods=['POST'])
def submit_calibration_job():
    logging.info("submit-calibration-job - Received POST request with the following parameters:")
    for key, value in request.form.items():
        logging.info(f"{key}: {value}")

    job_type = 'calibration'
    # ngen-cal job id
    calibration_run_id = request.form.get('calibration_run_id')
    # Path to the ngen-cal input file within the container
    input_file = request.form.get('input_file')
    # Path to the SLURM job log file in the controller node
    output_file = request.form.get('output_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')
    # Number of MPI proc
    nprocs = request.form.get('nprocs', '1')

    if not calibration_run_id:
        return log_and_return_error("No calibration_run_id provided", status_code=400)

    if not input_file:
        return log_and_return_error("No ngen-cal input file provided", status_code=400)

    if not output_file:
        return log_and_return_error("No output_file provided", status_code=400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code=400)

    singularity_run_cmd = f"{SINGULARITY_RUN_NWM_CAL_MGR_CMD} calibration {input_file}"

    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, calibration_run_id)

    try:
        # Get callback
        callback = get_callback(
            callbacks_dir,
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/calibration_job_slurm_callback/',
            auth_token,
            calibration_run_id=calibration_run_id,
            job_status="__job_status__"
        )

        write_callback(callbacks_dir, callback)

    except Exception as e:
        return log_and_return_error(str(e), 500)

    slurm_job_id, exit_code = submit_job(input_file, output_file, calibration_run_id, job_type, singularity_run_cmd, nprocs = nprocs)
    if exit_code == 500:
        return jsonify({"error": slurm_job_id}), exit_code

    return jsonify({"slurm_job_id": slurm_job_id}), exit_code


@app.route('/submit-validation-job', methods=['POST'])
def submit_validation_job():
    logging.info("submit-validation-job - Received POST request with the following parameters:")
    for key, value in request.form.items():
        logging.info(f"{key}: {value}")

    job_type = 'validation'
    # ngen-cal job id
    validation_run_id = request.form.get('validation_run_id')
    # Path to the ngen-cal input file within the container
    input_file = request.form.get('input_file')
    # Path to the SLURM job log file in the controller node
    output_file = request.form.get('output_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')
    # ngen-cal job type: calibration or validation
    validation_type = request.form.get('validation_type')
    # Worker name
    worker_name = request.form.get('worker_name')
    # Iteration
    iteration = request.form.get('iteration')
    # Number of MPI proc
    nprocs = request.form.get('nprocs', '1')

    if not validation_run_id:
        return log_and_return_error("No validation_run_id provided", status_code=400)

    if not input_file:
        return log_and_return_error("No ngen-cal input file provided", status_code=400)

    if not output_file:
        return log_and_return_error("No output_file provided", status_code=400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code=400)

    # Validate job type and inputs specific to `valid_iteration`
    if validation_type == 'valid_iteration':
        if not worker_name:
            return log_and_return_error("No worker_name provided for validation_type 'valid_iteration'", status_code=400)
        if not iteration:
            return log_and_return_error("No iteration provided for validation_type 'valid_iteration'", status_code=400)

        try:
            iteration_int = int(iteration)  # Attempt to convert to an integer
        except ValueError:
            return log_and_return_error("Invalid iteration provided; must be an integer", status_code=400)

    if validation_type in ['valid_control', 'valid_best']:
        singularity_run_cmd = f"{SINGULARITY_RUN_NWM_CAL_MGR_CMD} validation {input_file}"
    elif validation_type == 'valid_iteration':
        singularity_run_cmd = f"{SINGULARITY_RUN_NWM_CAL_MGR_CMD} validation_iteration {input_file} {worker_name} {iteration}"
    else:
        return log_and_return_error("Invalid validation_type provided; must be one of 'valid_control', 'valid_best', or 'valid_iteration'", status_code = 400)
    
    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, validation_run_id)

    try:
        # Get callback
        callback = get_callback(
            callbacks_dir,
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/validation_job_slurm_callback/',
            auth_token,
            validation_run_id=validation_run_id,
            job_status="__job_status__"
        )

        write_callback(callbacks_dir, callback)

    except Exception as e:
        return log_and_return_error(str(e), status_code=500)

    slurm_job_id, exit_code = submit_job(input_file, output_file, validation_run_id, job_type, singularity_run_cmd, nprocs=nprocs)
    if exit_code == 500:
        return jsonify({"error": slurm_job_id}), exit_code
    return jsonify({"slurm_job_id": slurm_job_id}), exit_code


@app.route('/submit-forecast-job', methods=['POST'])
def submit_forecast_job():
    logging.info("submit-forecast-job - Received POST request with the following parameters:")
    for key, value in request.form.items():
        logging.info(f"{key}: {value}")

    job_type = 'forecast'
    # job id
    forecast_run_id = request.form.get('forecast_run_id')
    # validation yaml
    validation_yaml = request.form.get('validation_yaml')
    # realization file
    realization_file = request.form.get('realization_file')
    # Path to the SLURM job log file in the controller node
    stdout_file = request.form.get('stdout_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')

    if not forecast_run_id:
        return log_and_return_error("No forecast_run_id provided", status_code=400)

    if not validation_yaml:
        return log_and_return_error("No validation_yaml provided", status_code=400)

    if not realization_file:
        return log_and_return_error("No realization_file provided", status_code=400)

    if not stdout_file:
        return log_and_return_error("No stdout_file provided", status_code=400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code=400)

    singularity_run_cmd = f"{SINGULARITY_RUN_NWM_FCST_MGR_CMD} forecast {validation_yaml} {realization_file}"

    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, forecast_run_id)

    try:
        # Get callback
        callback = get_callback(
            callbacks_dir,
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/forecast_job_slurm_callback/',
            auth_token,
            forecast_run_id=forecast_run_id,
            job_status="__job_status__"
        )

        write_callback(callbacks_dir, callback)

    except Exception as e:
        return log_and_return_error(str(e), status_code=500)

    slurm_job_id, exit_code = submit_job(validation_yaml, stdout_file, forecast_run_id, job_type, singularity_run_cmd)
    if exit_code == 500:
        return jsonify({"error": slurm_job_id}), exit_code

    return jsonify({"slurm_job_id": slurm_job_id}), exit_code


@app.route('/submit-cold-start-job', methods=['POST'])
def submit_cold_start_job():
    logging.info("submit-cold-start-job - Received POST request with the following parameters:")
    for key, value in request.form.items():
        logging.info(f"{key}: {value}")

    job_type = 'cold-start'
    # job id
    cold_start_run_id = request.form.get('cold_start_run_id')
    # validation yaml
    validation_yaml = request.form.get('validation_yaml')
    # realization file
    realization_file = request.form.get('realization_file')
    # Path to the SLURM job log file in the controller node
    stdout_file = request.form.get('stdout_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')

    if not cold_start_run_id:
        return log_and_return_error("No cold_start_run_id provided", status_code=400)

    if not validation_yaml:
        return log_and_return_error("No validation_yaml provided", status_code=400)

    if not realization_file:
        return log_and_return_error("No realization_file provided", status_code=400)

    if not stdout_file:
        return log_and_return_error("No stdout_file provided", status_code=400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code=400)

    singularity_run_cmd = f"{SINGULARITY_RUN_NWM_FCST_MGR_CMD} cold_start {validation_yaml} {realization_file}"

    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, cold_start_run_id)

    try:
        # Get callback
        callback = get_callback(
            callbacks_dir,
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/cold_start_job_slurm_callback/',
            auth_token,
            cold_start_run_id=cold_start_run_id,
            job_status="__job_status__"
        )

        write_callback(callbacks_dir, callback)

    except Exception as e:
        return log_and_return_error(str(e), status_code=500)

    slurm_job_id, exit_code = submit_job(validation_yaml, stdout_file, cold_start_run_id, job_type, singularity_run_cmd)
    if exit_code == 500:
        return jsonify({"error": slurm_job_id}), exit_code

    return jsonify({"slurm_job_id": slurm_job_id}), exit_code


@app.route('/submit-verification-job', methods=['POST'])
def submit_verification_job():
    logging.info("submit-verification-job - Received POST request with the following parameters:")
    for key, value in request.form.items():
        logging.info(f"{key}: {value}")

    job_type = 'verification-job'
    # job id
    verification_job_id = request.form.get('verification_job_id')
    # validation yaml
    verification_config = request.form.get('verification_configl')
    # Path to the SLURM job log file in the controller node
    stdout_file = request.form.get('stdout_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')

    if not verification_job_id:
        return log_and_return_error("No verification_job_id provided", status_code=400)

    if not verification_config:
        return log_and_return_error("No verification_config provided", status_code=400)
    
    if not stdout_file:
        return log_and_return_error("No stdout_file provided", status_code=400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code=400)

    singularity_run_cmd = f"{SINGULARITY_RUN_NWM_VERF_CMD} run-ngen-verf.sh verification {verification_config}"

    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, verification_job_id)

    try:
        # Get callback
        callback = get_callback(
            callbacks_dir,
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/verification_job_slurm_callback/',
            auth_token,
            verification_job_id=verification_job_id,
            job_status="__job_status__"
        )

        write_callback(callbacks_dir, callback)

    except Exception as e:
        return log_and_return_error(str(e), status_code=500)

    slurm_job_id, exit_code = submit_job(verification_config, stdout_file, verification_job_id, job_type, singularity_run_cmd)
    if exit_code == 500:
        return jsonify({"error": slurm_job_id}), exit_code

    return jsonify({"slurm_job_id": slurm_job_id}), exit_code


@app.route('/job-status', methods=['GET'])
def job_status():
    # Get job ID from request
    slurm_job_id = request.args.get('slurm_job_id')

    if not slurm_job_id:
        return log_and_return_error("No SLURM job ID provided", 400)

    logger.info(f"Checking status for SLURM job ID: {slurm_job_id}")

    # Update slurm_job_id
    if slurm_job_id in configuring_jobs:
        last_job_id = configuring_jobs[slurm_job_id]['ids'][-1]
        logger.info(f"The SLURM job with ID {slurm_job_id} has been resubmitted. The current job ID is now {last_job_id}.")
    else:
        last_job_id = slurm_job_id

    try:
        # First, try to get job status using squeue (for pending or running jobs)
        job_status, error = squeue_job_status(last_job_id)
        if error:
            logger.info("Error running squeue: {error}")
            result = subprocess.run(["sacct", "-X", "--jobs", last_job_id, "--format=State", "--noheader"], capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                # Parse only the first line from sacct output
                job_status = result.stdout.strip().splitlines()[0]
                logger.info(f"The status of {last_job_id} is {job_status} from sacct")

        if job_status:
            logger.info(f"The status of {last_job_id} is {job_status} from squeue")
            return jsonify({"status": job_status}), 200

        return log_and_return_error("Job not found", 404)
    except Exception as e:
        return log_and_return_error(str(e), 500)


@app.route('/update-configuring-jobs', methods=['POST'])
def update_configuring_jobs():
    logger.info("Updating configuring jobs")
    configuring_jobs_copy = copy.deepcopy(configuring_jobs)

    for slurm_job_id, slurm_job_info in configuring_jobs_copy.items():
        logger.info(f"Processing SLURM job {slurm_job_id} - {slurm_job_info}")
        last_job_id = slurm_job_info['ids'][-1]
        job_status, error = squeue_job_status(last_job_id)
        if error:
            return log_and_return_error(error, 500)

        # If the job is not in 'Configuring', 'Pending' or 'Completing' status, remove it
        # We remove it if completing due to a strange SLURM bug that holds it in that state
        if job_status not in ['CF', 'PD', 'CG','CONFIGURING', 'PENDING', 'COMPLETING']:
            logger.info(f"Removing job {slurm_job_id} -> {last_job_id} with status {job_status} from configuring jobs")
            del configuring_jobs[slurm_job_id]

        else:
            job_elapsed_time = time.time() - slurm_job_info['start_time']
            logger.info(f"Processing SLURM job {slurm_job_id} -> Status {job_status}, Elapsed time: {job_elapsed_time}")

            # Check if the elapsed time exceeds the maximum wait time
            if job_elapsed_time > MAX_CONFIGURING_WAIT_TIME:
                # Use subprocess to run 'scancel'
                logger.info(f"Elapsed time of job {slurm_job_id} -> {last_job_id} is {job_elapsed_time} [s]. Cancelling and resubmitting job")
                result = subprocess.run(["scancel", last_job_id], capture_output=True, text=True)

                if result.returncode != 0:
                    return log_and_return_error(result.stderr.strip(), 500)

                # Resubmit the job and append the new job ID
                next_partition = get_next_partition(slurm_job_info['partition'])
                configuring_jobs[slurm_job_id]['partition'] = next_partition
                configuring_jobs[slurm_job_id]['start_time'] = time.time()
                new_slurm_job_id, error = submit_slurm_job(slurm_job_info['job_script'], partition=next_partition)

                if error:
                    return log_and_return_error(error, 500)

                configuring_jobs[slurm_job_id]['ids'].append(new_slurm_job_id)
                logger.info(f"Resubmitted job {slurm_job_id} -> {new_slurm_job_id}")

    # Return a success message along with the updated jobs
    return jsonify({"message": "Configuring jobs updated successfully.", "configuring_jobs": configuring_jobs}), 200


@app.route('/cancel-job', methods=['POST'])
def cancel_job():
    # Get job ID from request
    slurm_job_id = request.form.get('slurm_job_id')

    if not slurm_job_id:
        return log_and_return_error("No SLURM job ID provided", 400)

    # Update slurm_job_id
    if slurm_job_id in configuring_jobs:
        last_job_id = configuring_jobs[slurm_job_id]['ids'][-1]
    else:
        last_job_id = slurm_job_id

    try:
        # Use subprocess to run scancel
        logger.info(f"Cancelling job {slurm_job_id} -> {last_job_id}")
        result = subprocess.run(["scancel", last_job_id], capture_output=True, text=True)

        if result.returncode != 0:
            return log_and_return_error(result.stderr.strip(), 500)

        return jsonify({"message": f"Job {slurm_job_id} cancelled successfully"}), 200
    except Exception as e:
        return log_and_return_error(str(e), 500)


@app.route('/run-sacct', methods=['POST'])
def run_sacct():
    # Get the SLURM job ID from the request
    slurm_job_id = request.form.get('slurm_job_id')
    # Get the output file path where to write the output
    performance_file = request.form.get('performance_file')

    if not slurm_job_id:
        return log_and_return_error("No SLURM job ID provided", 400)

    if not performance_file:
        return log_and_return_error("No performance file path provided", 400)

    # Update slurm_job_id
    if slurm_job_id in configuring_jobs:
        slurm_job_id = configuring_jobs[slurm_job_id]['ids'][-1]

    try:
        # Your existing code for running the sacct command
        # For example:
        cmd = f'sacct -j {slurm_job_id} -o JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Reserved --parsable --units=K > {performance_file}'
        logger.info(f"Running: {cmd}")
        subprocess.run(cmd, shell=True, check=True)
        return jsonify({"success": True, "message": f"Job status written to {performance_file}"}), 200
    except subprocess.CalledProcessError as e:
        return log_and_return_error(str(e), 500)


@app.route('/job-start', methods=['POST'])
def job_start():
    job_type = request.form.get('job_type')
    run_id = request.form.get('run_id')

    # Validate inputs
    if not job_type:
        return log_and_return_error("No job type provided", 400)

    if not run_id:
        return log_and_return_error("No job id provided", 400)

    callbacks_dir = os.path.dirname(CALLBACKS_DIR, job_type, run_id)
    callback_script = os.path.join(callbacks_dir, 'callback')

    if not os.path.exists(callback_script):
        error_msg = f"Callback script ${callback_script} does not exist"
        logger.error(error_msg)
        log_and_return_error(error_msg, 500)

    # Construct the command to run sleep and sacct
    with open(callback_script, 'r') as f:
        callback = f.read().replace('__job_status__', 'STARTING')

    try:
        # Run the command in the background using subprocess.Popen
        logger.info(f"Running: {callback}")
        subprocess.Popen(callback, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        # Return an immediate response while the command runs in the background
        return jsonify({"success": True, "message": "Starting callback was submitted"}), 200

    except Exception as e:
        # Return an error message if something goes wrong
        return log_and_return_error(str(e), 500)


@app.route('/postprocess', methods=['POST'])
def postprocess():
    slurm_job_id = request.form.get('slurm_job_id')
    job_type = request.form.get('job_type')
    run_id = request.form.get('run_id')
    job_status = request.form.get('job_status')

    # Validate inputs
    if not slurm_job_id:
        return log_and_return_error("No SLURM job ID provided", 400)

    if not job_type:
        return log_and_return_error("No job type provided", 400)

    if not run_id:
        return log_and_return_error("No job id provided", 400)

    if not job_status:
        return log_and_return_error("No job status provided", 400)

    logger.info(f"Postprocessing {job_type} job with id {run_id} and SLURM job id {slurm_job_id}")

    postprocessing_dir = os.path.join('postprocess', job_type, run_id)
    callback_script = os.path.join(postprocessing_dir, 'callback')
    performance_file_path = os.path.join(postprocessing_dir, 'performance_file')
    callback_log_path = os.path.join(postprocessing_dir, 'callback.log')

    if not os.path.exists(callback_script):
        error_msg = f"Callback script ${callback_script} does not exist"
        logger.error(error_msg)
        log_and_return_error(error_msg, 500)

    if not os.path.exists(performance_file_path):
        error_msg = f"Performance file ${performance_file_path} does not exist"
        logger.error(error_msg)
        log_and_return_error(error_msg, 500)

    # Construct the command to run sleep and sacct
    with open(performance_file_path, 'r') as f:
        performance_file = f.read()

    # Replace job status in callback script
    with open(callback_script, 'r') as f:
        callback = f.read().replace('__job_status__', job_status)
    with open(callback_script, 'w') as f:
        f.write(callback)

    sacct_cmd = f'sacct -j {slurm_job_id} -o {SLURM_JOB_METRICS} --parsable --units=K > {performance_file}'
    cmd = f'sleep 5; {sacct_cmd}; ./run_callback.sh {callback_script} >> {callback_log_path} 2>&1'

    try:
        # Run the command in the background using subprocess.Popen
        logger.info(f"Running: {cmd}")
        subprocess.Popen(cmd, shell=True)

        # Return an immediate response while the command runs in the background
        return jsonify({"success": True, "message": f"Job status will be written to {performance_file} after 10 seconds"}), 200

    except Exception as e:
        # Return an error message if something goes wrong
        return log_and_return_error(str(e), 500)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)