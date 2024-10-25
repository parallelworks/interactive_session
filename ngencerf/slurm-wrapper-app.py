import subprocess
import os
from flask import Flask, request, jsonify
import socket
import copy
import logging
from logging.handlers import RotatingFileHandler

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
LOCAL_DATA_DIR = os.environ.get('LOCAL_DATA_DIR') #"/ngencerf-app/data/ngen-cal-data/"
# Path to the data directory within the container
CONTAINER_DATA_DIR = os.environ.get('CONTAINER_DATA_DIR') #"/ngencerf/data/"
# Path to the singularity container with ngen-cal
NGEN_CAL_SINGULARITY_CONTAINER_PATH = os.environ.get('NGEN_CAL_SINGULARITY_CONTAINER_PATH')
# URL to callback from ngencal to the other services
NGENCERF_URL=f"http://{CONTROLLER_HOSTNAME}:8000"
# Command to launch singularity
SINGULARITY_RUN_CMD = f"/usr/bin/time -v singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NGEN_CAL_SINGULARITY_CONTAINER_PATH}"
# Command to obtain git hashes
SINGULARITY_EXEC_CMD = f"singularity exec -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} --env NGENCERF_URL={NGENCERF_URL} {NGEN_CAL_SINGULARITY_CONTAINER_PATH}"

# Files with the git hashes within ngen-cal container
NGEN_CAL_GIT_HASH_FILES = '/ngen-app/ngen/.git/HEAD /ngen-app/ngen-cal/.git/HEAD'

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

def grant_ownership(job_dir):
    try:
        # Get the current user's UID and GID
        current_uid = os.getuid()
        current_gid = os.getgid()
        # Change ownership of the directory to the current user
        command_chown = f"sudo chown -R {current_uid}:{current_gid} {job_dir}"
        subprocess.run(command_chown, shell=True, check=True)
        logger.info(f"Ownership granted to directory {job_dir}")
        return {"success": True, "message": f"Access granted to {job_dir}"}
    except subprocess.CalledProcessError as e:
        logger.exception(f"Failed to change ownership for directory {job_dir}")
        return {"success": False, "message": str(e)}
    
def get_git_hashes():
    """Retrieve git commit hashes from the ngen-cal container."""
    try:
        command = f'{SINGULARITY_EXEC_CMD} cat {NGEN_CAL_GIT_HASH_FILES}'
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        if result.returncode != 0:
            error_msg = f"Failed to retrieve git hashes: {result.stderr.strip()}"
            logger.error(error_msg)
            return None, error_msg
        
        # The output should contain two lines, one for each commit hash
        hashes = result.stdout.strip().splitlines()
        if len(hashes) != 2:
            output = ', '.join(hashes)
            error_msg = f"Unexpected output from singularity command: {output}"
            logger.error(error_msg)
            return None, error_msg
        
        ngen_commit_hash = hashes[0].split()[-1]  # Extract the last part of the line
        ngen_cal_commit_hash = hashes[1].split()[-1]
        return ngen_commit_hash, ngen_cal_commit_hash
    except Exception as e:
        error_msg = str(e)
        logger.exception(f"Error retrieving git hashes: {error_msg}")
        return None, error_msg

def get_callback(callback_url, auth_token, **kwargs):
    # Prepare the data dictionary excluding the auth_token
    data = {key: value for key, value in kwargs.items()}

    # Create the JSON string for the --data parameter
    json_data = ', '.join([f'\\"{key}\\": \\"{value}\\"' for key, value in data.items()])

    # Construct the complete curl command string
    callback_command = (
        f'curl --location "{callback_url}" \\\n'
        f'    --header "Content-Type: application/json" \\\n'
        f'    --header "Authorization: Bearer {auth_token}" \\\n'
        f'    --data "{{{json_data}}}"\n'
    )

    return callback_command    

def write_slurm_script(run_id, input_file_local, output_file_local, singularity_run_cmd, callback):
    job_script = input_file_local.replace('.yaml', '.slurm.sh')
    # Performance statistics
    performance_log = output_file_local.replace('stdout', 'performance')

    # Write the SLURM script
    with open(job_script, 'w') as script:
        script.write('#!/bin/bash\n')
        script.write(f'#SBATCH --job-name={run_id}\n')
        script.write('#SBATCH --nodes=1\n')
        script.write('#SBATCH --ntasks-per-node=1\n')
        script.write(f'#SBATCH --output={output_file_local}\n')
        script.write('\n')
        
        script.write('echo Running Job $SLURM_JOB_ID \n\n')
        
        # Execute the singularity command
        script.write(f'{singularity_run_cmd}\n') 
        script.write('echo\n\n')

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

        create_performance_files_cmd = f'curl -X POST http://{CONTROLLER_HOSTNAME}:5000/run-sacct -d \"slurm_job_id=$SLURM_JOB_ID\" -d \"performance_file={performance_log}\"\n'
        script.write(create_performance_files_cmd)
        script.write('echo\n\n')
 
        # Send the status back using the curl command
        script.write(callback)
    
    return job_script

import subprocess

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
    
def convert_to_seconds(time_str):
    return sum(int(x) * 60 ** i for i, x in enumerate(reversed(time_str.split(':'))))

def squeue_job_elapsed_time(slurm_job_id):
    try:
        cmd = ["squeue", "--job", slurm_job_id, "--format=%M", "--noheader"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            error_msg = f"Failed to run command {cmd}: {result.stderr.strip()}"
            logger.error(error_msg)
            return None, error_msg
        
        elapsed_time_str = result.stdout.strip()
        return convert_to_seconds(elapsed_time_str), None

    except Exception as e:
        error_msg = f"Failed to obtain elapsed time: {str(e)}"
        logger.exception(error_msg)
        return None, error_msg


def submit_job(input_file, output_file, job_id, singularity_run_cmd, callback):
    logger.info(f"Starting job submission for job ID: {job_id}")
    # Check the file exists on the shared file system
    # Path to the input file on the shared file system
    input_file_local = input_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    output_file_local = output_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    if not os.path.exists(input_file_local):
        error_msg = f"File path '{input_file_local}' does not exist on the shared filesystem under {LOCAL_DATA_DIR}."
        return log_and_return_error(error_msg, status_code = 400)
    
    # Get commit hashes before job submission
    ngen_commit_hash, ngen_cal_commit_hash = get_git_hashes()
    if ngen_commit_hash is None:  # Check for error during hash retrieval
        error_msg = f"Failed to retrieve commit hashes: {ngen_cal_commit_hash}"
        return log_and_return_error(error_msg, status_code = 500)

    logger.info(f"Commit hashes retrieved - NGEN: {ngen_commit_hash}, NGEN_CAL: {ngen_cal_commit_hash}")

    try:
        # FIXME: Remove
        job_dir = os.path.dirname(os.path.dirname(input_file_local))
        grant_ownership(job_dir)
        os.makedirs(os.path.dirname(output_file_local), exist_ok=True)

        # Save the script to the job's directory
        job_script = write_slurm_script(job_id, input_file_local, output_file_local, singularity_run_cmd, callback)
        logger.info(f"Job script written to: {job_script}")

        # Submit the job and retrieve SLURM job ID
        slurm_job_id, error = submit_slurm_job(job_script)
        if error:
            return jsonify({"error": error}), 500

        # Initialize job
        if PARTITIONS:
            configuring_jobs[slurm_job_id] = {}
            configuring_jobs[slurm_job_id]['ids'] = [slurm_job_id]
            configuring_jobs[slurm_job_id]['job_script'] = job_script
            configuring_jobs[slurm_job_id]['partition'] = get_next_partition()
            logger.info(f"Adding job {slurm_job_id} - {job_script} to configuring jobs")

        return jsonify({"slurm_job_id": slurm_job_id, "ngen_commit_hash": ngen_commit_hash, "ngen_cal_commit_hash": ngen_cal_commit_hash}), 200
    except Exception as e:
        error_msg = f"Failed to submit job: {str(e)}"
        logger.exception(error_msg)
        return jsonify({"error": error_msg}), 500

@app.route('/submit-calibration-job', methods=['POST'])
def submit_calibration_job():
    # ngen-cal job id
    calibration_run_id = request.form.get('calibration_run_id')
    # Path to the ngen-cal input file within the container
    input_file = request.form.get('input_file')
    # Path to the SLURM job log file in the controller node
    output_file = request.form.get('output_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')

    if not calibration_run_id:
        return log_and_return_error("No calibration job ID provided", status_code = 400)

    if not input_file:
        return log_and_return_error("No ngen-cal input file provided", status_code = 400)
    
    if not output_file:
        return log_and_return_error("No output_file provided", status_code = 400)
    
    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code = 400)
    
    singularity_run_cmd = f"{SINGULARITY_RUN_CMD} calibration {input_file}"
    
    try:
        # Get callback
        callback = get_callback(
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/calibration_job_slurm_callback/',
            auth_token,
            calibration_run_id = calibration_run_id,
            job_status = "$job_status"
        )
    except Exception as e:
        return log_and_return_error(str(e), 500)

    return submit_job(input_file, output_file, calibration_run_id, singularity_run_cmd, callback)

@app.route('/submit-validation-job', methods=['POST'])
def submit_validation_job():
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


    if not validation_run_id:
        return log_and_return_error("No validation job ID provided", status_code = 400)

    if not input_file:
        return log_and_return_error("No ngen-cal input file provided", status_code = 400)

    if not output_file:
        return log_and_return_error("No output_file provided", status_code = 400)

    if not auth_token:
        return log_and_return_error("No auth_token provided", status_code = 400)
    
    # Validate job type and inputs specific to `valid_iteration`
    if validation_type == 'valid_iteration':
        if not worker_name:
            return log_and_return_error("No worker_name provided for validation_type 'valid_iteration'", status_code = 400)
        if not iteration:
            return log_and_return_error("No iteration provided for validation_type 'valid_iteration'", status_code = 400)
        
        try:
            iteration_int = int(iteration)  # Attempt to convert to an integer
        except ValueError:
            return log_and_return_error("Invalid iteration provided; must be an integer", status_code = 400)    

    if validation_type in ['valid_control', 'valid_best']:
        singularity_run_cmd = f"{SINGULARITY_RUN_CMD} validation {input_file}"
    elif validation_type == 'valid_iteration':
        singularity_run_cmd = f"{SINGULARITY_RUN_CMD} validation_iteration {input_file} {worker_name} {iteration}"
    else:
        return log_and_return_error("Invalid validation_type provided; must be one of 'valid_control', 'valid_best', or 'valid_iteration'", status_code = 400) 

    try:
        # Get callback
        callback = get_callback(
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration/validation_job_slurm_callback/',
            auth_token,
            validation_run_id = validation_run_id,
            job_status = "$job_status"
        )
    except Exception as e:
        return log_and_return_error(str(e), status_code = 500) 

    return submit_job(input_file, output_file, validation_run_id, singularity_run_cmd, callback)


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
            return log_and_return_error(error, 500)
        
        if job_status:
            logger.info(f"The status of {slurm_job_id} is {job_status} from squeue")
            return jsonify({"slurm_job_id": slurm_job_id, "status": job_status}), 200

        # If squeue doesn't return a status, fall back to sacct for completed/failed jobs
        result = subprocess.run(["sacct", "--jobs", slurm_job_id, "--format=State", "--noheader"], capture_output=True, text=True)

        if result.returncode == 0 and result.stdout.strip():
            # Parse only the first line from sacct output
            job_status = result.stdout.strip().splitlines()[0]
            logger.info(f"The status of {slurm_job_id} is {job_status} from sacct")
            return jsonify({"slurm_job_id": slurm_job_id, "status": job_status}), 200

        # If sacct also doesn't return a status, return job not found error
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

        # If the job is not in 'Configuring' or 'Pending' status, remove it
        if job_status not in ['CF', 'PD', 'CONFIGURING', 'PENDING']:
            logger.info(f"Removing job {slurm_job_id} -> {last_job_id} with status: {job_status}")
            del configuring_jobs[slurm_job_id]

        else:
            job_elapsed_time, error = squeue_job_elapsed_time(last_job_id)
            if error:
                return log_and_return_error(error, 500)

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
                new_slurm_job_id, error = submit_slurm_job(slurm_job_info['job_script'], partition = next_partition)
                
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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
