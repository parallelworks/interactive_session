import subprocess
import os
from flask import Flask, request, jsonify
import requests
import socket


# Path to the data directory in the shared filesystem
LOCAL_DATA_DIR = os.environ.get('LOCAL_DATA_DIR') #"/ngencerf-app/data/ngen-cal-data/"
# Path to the data directory within the container
CONTAINER_DATA_DIR = os.environ.get('CONTAINER_DATA_DIR') #"/ngencerf/data/"
# Path to the singularity container with ngen-cal
NGEN_CAL_SINGULARITY_CONTAINER_PATH = os.environ.get('NGEN_CAL_SINGULARITY_CONTAINER_PATH')
# Command to launch singularity
SINGULARITY_CMD = f"singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} {NGEN_CAL_SINGULARITY_CONTAINER_PATH}"
# CALLBACK URL
CALLBACK_URL = os.environ.get('CALLBACK_URL') #'http://localhost:8000/calibration/slurm_callback/'

app = Flask(__name__)

# Dictionary to store job details keyed by job_id
job_data = {}

hostname = socket.gethostname()

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

def write_slurm_script(job_id, job_type, input_file, input_file_local, job_stage, output_file_local, auth_token):
    # FIXME: remove test write commands
    job_script = input_file_local.replace('.yaml', '.slurm.sh')

    cmd = f"{SINGULARITY_CMD} {job_type} {input_file}"

    # Write the SLURM script
    with open(job_script, 'w') as script:
        script.write('#!/bin/bash\n')
        script.write(f'#SBATCH --job-name={job_id}\n')
        script.write('#SBATCH --nodes=1\n')
        script.write('#SBATCH --ntasks-per-node=1\n')
        script.write(f'#SBATCH --output={output_file_local}\n')
        
        # Execute the singularity command
        script.write(f'{cmd}\n') 
        
        # Check if the command was successful and set the job status accordingly
        script.write('if [ $? -eq 0 ]; then\n')
        script.write('    job_status="DONE"\n')
        script.write('else\n')
        script.write('    job_status="FAILED"\n')
        script.write('fi\n')
        
        # Send the status back using the curl command
        script.write(f'curl --location \'{CALLBACK_URL}\' \\\n')
        script.write('    --header \'Content-Type: application/json\' \\\n')
        script.write(f'    --header \'Authorization: Bearer {auth_token}\' \\\n')
        script.write(f'    --data \'{{"process_id": "{job_id}", "stage": "{job_stage}", "job_status": "$job_status"}}\'\n')
        
        # Added: Trigger a callback to clean up job_data entry after job completion
        script.write(f'curl --location \'http://{hostname}:5000/cleanup-job\' \\\n')
        script.write('    --header \'Content-Type: application/json\' \\\n')
        script.write(f'    --data \'{{"slurm_job_id": "$SLURM_JOB_ID"}}\'\n')

        # Print a message indicating the job completion
        script.write('echo Job Completed with status $job_status\n')

    
    return job_script


@app.route('/submit-job', methods=['POST'])
def submit_job():
    # ngen-cal job id
    job_id = request.form.get('job_id')
    # ngen-cal job type: calibration or validation
    job_type = request.form.get('job_type')  
    # Path to the ngen-cal input file within the container
    input_file = request.form.get('input_file')
    # Job stage string for callback
    job_stage = request.form.get('job_stage')
    # Path to the SLURM job log file in the controller node
    output_file = request.form.get('output_file')
    # Path to the SLURM job log file in the controller node
    auth_token = request.form.get('auth_token')

    if not job_id:
        return jsonify({"error": "No job ID provided"}), 400

    if not job_type:
        return jsonify({"error": "No job directory provided"}), 400
    elif job_type not in ['calibration', 'validation']:
        return jsonify({"error": "Invalid job type. Must be 'calibration' or 'validation'."}), 400

    if not input_file:
        return jsonify({"error": "No ngen-cal input file provided"}), 400
    
    if not job_stage:
        return jsonify({"error": "No job_stage provided"}), 400
    
    if not output_file:
        return jsonify({"error": "No output_file provided"}), 400
    
    if not auth_token:
        return jsonify({"error": "No auth_token provided"}), 400

    # Check the file exists on the shared file system
    # Path to the input file on the shared file system
    input_file_local = input_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    output_file_local = output_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    if not os.path.exists(input_file_local):
        return jsonify({"error": f"File path '{input_file_local}' does not exist on the shared filesystem under {LOCAL_DATA_DIR}."}), 400

    try:
        # FIXME: Remove
        job_dir = os.path.dirname(os.path.dirname(input_file_local))
        grant_ownership(job_dir)
        os.makedirs(os.path.dirname(output_file_local), exist_ok=True)

        # Save the script to the job's directory
        job_script = write_slurm_script(job_id, job_type, input_file, input_file_local, job_stage, output_file_local, auth_token)

        # Use subprocess to run sbatch and capture the output
        result = subprocess.run(["sbatch", job_script], capture_output=True, text=True)

        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500

        # Parse SLURM job ID from sbatch output
        slurm_job_id = result.stdout.strip().split()[-1]

        # Store job details in the dictionary
        job_data[slurm_job_id] = {
            'job_stage': job_stage,
            'auth_token': auth_token,
            'job_id': job_id
        }


        return jsonify({"slurm_job_id": slurm_job_id}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

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
    # ngen-cal job id
    job_id = request.form.get('job_id')
    # Job stage string for callback
    job_stage = request.form.get('job_stage')
    # Auth token for callback
    auth_token = request.form.get('auth_token')

    if not slurm_job_id:
        return jsonify({"error": "No job ID provided"}), 400
    
    # Retrieve job details from the dictionary using slurm_job_id as the key
    job_details = job_data.get(slurm_job_id)
    if not job_details:
        return jsonify({"error": "Job not found"}), 404
    
    job_stage = job_details['job_stage']
    auth_token = job_details['auth_token']
    job_id = job_details['job_id']

    try:
        # Use subprocess to run scancel
        result = subprocess.run(["scancel", slurm_job_id], capture_output=True, text=True)
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500
        
        del job_data[slurm_job_id]
        
        # Trigger the callback to notify job cancellation using requests
        headers = {
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {auth_token}'
        }
        payload = {
            "process_id": job_id,
            "stage": job_stage,
            "job_status": "CANCELED"
        }

        # Send the callback request
        response = requests.post(CALLBACK_URL, headers=headers, json=payload)

        # Check if the callback was successful
        if response.status_code != 200:
            return jsonify({"error": f"Callback failed: {response.text}"}), 500
        
        return jsonify({"message": f"Job {slurm_job_id} cancelled successfully"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/cleanup-job', methods=['POST'])
def cleanup_job():
    slurm_job_id = request.json.get('slurm_job_id')

    if not slurm_job_id:
        return jsonify({"error": "No SLURM job ID provided"}), 400

    # Check if the job exists in the dictionary
    if slurm_job_id in job_data:
        # Remove the job entry from the dictionary
        del job_data[slurm_job_id]
        return jsonify({"message": f"Job {slurm_job_id} removed from job_data"}), 200
    else:
        return jsonify({"error": f"Job {slurm_job_id} not found in job_data"}), 404


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
