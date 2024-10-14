import subprocess
import os
from flask import Flask, request, jsonify
import socket

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

app = Flask(__name__)

def grant_ownership(job_dir):
    try:
        # Get the current user's UID and GID
        current_uid = os.getuid()
        current_gid = os.getgid()
        # Change ownership of the directory to the current user
        command_chown = f"sudo chown -R {current_uid}:{current_gid} {job_dir}"
        subprocess.run(command_chown, shell=True, check=True)
        return {"success": True, "message": f"Access granted to {job_dir}"}
    except subprocess.CalledProcessError as e:
        return {"success": False, "message": str(e)}
    
def get_git_hashes():
    """Retrieve git commit hashes from the ngen-cal container."""
    try:
        command = f'{SINGULARITY_EXEC_CMD} cat {NGEN_CAL_GIT_HASH_FILES}'
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        if result.returncode != 0:
            return None, result.stderr.strip()
        
        # The output should contain two lines, one for each commit hash
        hashes = result.stdout.strip().splitlines()
        if len(hashes) != 2:
            output = ', '.join(hashes)
            return None, f"Unexpected output from singularity command {output}"
        
        ngen_commit_hash = hashes[0].split()[-1]  # Extract the last part of the line
        ngen_cal_commit_hash = hashes[1].split()[-1]
        return ngen_commit_hash, ngen_cal_commit_hash
    except Exception as e:
        return None, str(e)

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

        # Try to capture performance with "Reserved" first
        # Cannot run sacct directly on the compute node
        sacct_cmd = 'sacct -j $SLURM_JOB_ID -o JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Reserved --parsable --units=K'
        # sacct_cmd depends on the SLURM version!
        #sacct_cmd = 'sacct -j $SLURM_JOB_ID -o JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Planned'
        ssh_cmd = f'ssh -i ~/.ssh/pw_id_rsa -o StrictHostKeyChecking=no {CONTROLLER_HOSTNAME}'
        script.write(f'sbatch --dependency=afterok:$SLURM_JOB_ID --wrap=\"{ssh_cmd} {sacct_cmd} >> {performance_log}\"\n')
        script.write('echo\n\n')

        # Send the status back using the curl command
        script.write(callback)
    
    return job_script

def submit_job(input_file, output_file, job_id, singularity_run_cmd, callback):
    # Check the file exists on the shared file system
    # Path to the input file on the shared file system
    input_file_local = input_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    output_file_local = output_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    if not os.path.exists(input_file_local):
        return jsonify({"error": f"File path '{input_file_local}' does not exist on the shared filesystem under {LOCAL_DATA_DIR}."}), 400

    # Get commit hashes before job submission
    ngen_commit_hash, ngen_cal_commit_hash = get_git_hashes()
    if ngen_commit_hash is None:  # Check for error during hash retrieval
        return jsonify({"error": ngen_cal_commit_hash}), 500

    try:
        # FIXME: Remove
        job_dir = os.path.dirname(os.path.dirname(input_file_local))
        grant_ownership(job_dir)
        os.makedirs(os.path.dirname(output_file_local), exist_ok=True)

        # Save the script to the job's directory
        job_script = write_slurm_script(job_id, input_file_local, output_file_local, singularity_run_cmd, callback)

        # Use subprocess to run sbatch and capture the output
        result = subprocess.run(["sbatch", job_script], capture_output=True, text=True)

        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500

        # Parse SLURM job ID from sbatch output
        slurm_job_id = result.stdout.strip().split()[-1]

        return jsonify({"slurm_job_id": slurm_job_id, "ngen_commit_hash": ngen_commit_hash, "ngen_cal_commit_hash": ngen_cal_commit_hash}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


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
        return jsonify({"error": "No job ID provided"}), 400

    if not input_file:
        return jsonify({"error": "No ngen-cal input file provided"}), 400
    
    if not output_file:
        return jsonify({"error": "No output_file provided"}), 400
    
    if not auth_token:
        return jsonify({"error": "No auth_token provided"}), 400
    
    singularity_run_cmd = f"{SINGULARITY_RUN_CMD} calibration {input_file}"
    
    try:
        # Get callback
        callback = get_callback(
            f'http://{CONTROLLER_HOSTNAME}:8000/calibration_job_slurm_callback/',
            auth_token,
            calibration_run_id = calibration_run_id,
            job_status = "$job_status"
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


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
    job_type = request.form.get('job_type')
    # Worker name
    worker_name = request.form.get('worker_name')
    # Iteration
    iteration = request.form.get('iteration')


    if not validation_run_id:
        return jsonify({"error": "No job ID provided"}), 400

    if not input_file:
        return jsonify({"error": "No ngen-cal input file provided"}), 400

    if not output_file:
        return jsonify({"error": "No output_file provided"}), 400

    if not auth_token:
        return jsonify({"error": "No auth_token provided"}), 400
    
    # Validate job type and inputs specific to `valid_iteration`
    if job_type == 'valid_iteration':
        if not worker_name:
            return jsonify({"error": "No worker_name provided for job_type 'valid_iteration'"}), 400
        if not iteration:
            return jsonify({"error": "No iteration provided for job_type 'valid_iteration'"}), 400
        
        try:
            iteration_int = int(iteration)  # Attempt to convert to an integer
        except ValueError:
            return jsonify({"error": "Invalid iteration provided; must be an integer"}), 400
    

    if job_type in ['valid_control', 'valid_best']:
        singularity_run_cmd = f"{SINGULARITY_RUN_CMD} validation {input_file}"
    elif job_type == 'valid_iteration':
        singularity_run_cmd = f"{SINGULARITY_RUN_CMD} validation_iteration {input_file} {worker_name} {iteration}"
    else:
        return jsonify({"error": "Invalid job_type provided; must be one of 'valid_control', 'valid_best', or 'valid_iteration'"}), 400

    try:
        # Get callback
        callback = get_callback(
            f'http://{CONTROLLER_HOSTNAME}:8000/validation_job_slurm_callback/',
            auth_token,
            validation_run_id = validation_run_id,
            job_status = "$job_status"
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


    return submit_job(input_file, output_file, validation_run_id, singularity_run_cmd, callback)

@app.route('/job-status', methods=['GET'])
def job_status():
    # Get job ID from request
    slurm_job_id = request.args.get('slurm_job_id')
    
    if not slurm_job_id:
        return jsonify({"error": "No job ID provided"}), 400

    try:
        # First, try to get job status using squeue (for pending or running jobs)
        result = subprocess.run(["squeue", "--job", slurm_job_id, "--format=%T", "--noheader"], capture_output=True, text=True)

        if result.returncode == 0 and result.stdout.strip():
            # If the job is found in squeue, return its status
            job_status = result.stdout.strip()
            return jsonify({"slurm_job_id": slurm_job_id, "status": job_status}), 200

        # If squeue doesn't return a status, fall back to sacct for completed/failed jobs
        result = subprocess.run(["sacct", "--jobs", slurm_job_id, "--format=State", "--noheader"], capture_output=True, text=True)

        if result.returncode == 0 and result.stdout.strip():
            # Parse only the first line from sacct output
            job_status = result.stdout.strip().splitlines()[0]

            return jsonify({"slurm_job_id": slurm_job_id, "status": job_status}), 200

        # If sacct also doesn't return a status, return job not found error
        return jsonify({"error": "Job not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/cancel-job', methods=['POST'])
def cancel_job():
    # Get job ID from request
    slurm_job_id = request.form.get('slurm_job_id')

    if not slurm_job_id:
        return jsonify({"error": "No job ID provided"}), 400

    try:
        # Use subprocess to run scancel
        result = subprocess.run(["scancel", slurm_job_id], capture_output=True, text=True)
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500
        
        
        return jsonify({"message": f"Job {slurm_job_id} cancelled successfully"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500



@app.route('/run-sacct', methods=['POST'])
def run_sacct():
    # Get the SLURM job ID from the request
    slurm_job_id = request.form.get('slurm_job_id')
    # Get the output file path where to write the output
    performance_file = request.form.get('performance_file')

    if not slurm_job_id:
        return jsonify({"error": "No SLURM job ID provided"}), 400
    if not performance_file:
        return jsonify({"error": "No performance file path provided"}), 400
    try:
        # Your existing code for running the sacct command
        # For example:
        cmd = f'sacct -j {slurm_job_id} -o JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Reserved --parsable --units=K > {performance_file}'
        
        subprocess.run(cmd, shell=True, check=True)
        return jsonify({"success": True, "message": f"Job status written to {performance_file}"}), 200
    except subprocess.CalledProcessError as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
