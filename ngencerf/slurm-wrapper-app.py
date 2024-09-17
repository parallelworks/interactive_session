import subprocess
import os
from flask import Flask, request, jsonify

LOCAL_DATA_DIR = os.environ.get('LOCAL_DATA_DIR') #"/ngencerf-app/data/ngen-cal-data/"
CONTAINER_DATA_DIR = os.environ.get('CONTAINER_DATA_DIR') #"/ngencerf/data/"
SINGULARITY_CMD = f"singularity run -B {LOCAL_DATA_DIR}:{CONTAINER_DATA_DIR} /ngencerf-app/singularity/ngen-cal.sif"

app = Flask(__name__)

def write_slurm_script(job_id, job_type, input_file, input_file_local):
    # FIXME: remove test write commands
    job_script = input_file_local.replace('.yaml', '.slurm.sh')
    job_out = input_file_local.replace('.yaml', '.slurm.out')

    cmd = f"{SINGULARITY_CMD} {job_type} {input_file}"
    with open(job_script, 'w') as script:
        script.write('#!/bin/bash\n')
        script.write(f'#SBATCH --job-name={job_id}\n')
        script.write('#SBATCH --nodes=1\n')
        script.write('#SBATCH --ntasks-per-node=1\n')
        script.write('#SBATCH --nodes=1\n')
        script.write(f'#SBATCH --output={job_out}\n')
        script.write(f'job_id={job_id}\n')
        script.write(f'{cmd}\n')
        script.write(f'echo Job Completed\n')
    
    return job_script


@app.route('/submit-job', methods=['POST'])
def submit_job():
    # ngen-cal job id
    job_id = request.form.get('job_id')
    # ngen-cal job type: calibration or validation
    job_type = request.form.get('job_type')  
    # Path to the ngen-cal input file within the container
    input_file = request.form.get('input_file')

    if not job_id:
        return jsonify({"error": "No job ID provided"}), 400

    if not job_type:
        return jsonify({"error": "No job directory provided"}), 400
    elif job_type not in ['calibration', 'validation']:
        return jsonify({"error": "Invalid job type. Must be 'calibration' or 'validation'."}), 400

    if not input_file:
        return jsonify({"error": "No ngen-cal input file provided"}), 400
    
    # Check the file exists on the shared file system
    # Path to the input file on the shared file system
    input_file_local = input_file.replace(CONTAINER_DATA_DIR, LOCAL_DATA_DIR)
    if not os.path.exists(input_file_local):
        return jsonify({"error": f"File path '{input_file_local}' does not exist on the shared filesystem under {LOCAL_DATA_DIR}."}), 400

    try:
        # Save the script to the job's directory
        job_script = write_slurm_script(job_id, job_type, input_file, input_file_local)

        # Use subprocess to run sbatch and capture the output
        result = subprocess.run(["sbatch", job_script], capture_output=True, text=True)

        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500

        # Parse SLURM job ID from sbatch output
        job_id = result.stdout.strip().split()[-1]

        return jsonify({"job_id": job_id}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/job-status', methods=['GET'])
def job_status():
    # Get job ID from request
    job_id = request.args.get('job_id')
    
    if not job_id:
        return jsonify({"error": "No job ID provided"}), 400

    try:
        # First, try to get job status using squeue (for pending or running jobs)
        result = subprocess.run(["squeue", "--job", job_id, "--format=%T", "--noheader"], capture_output=True, text=True)

        if result.returncode == 0 and result.stdout.strip():
            # If the job is found in squeue, return its status
            job_status = result.stdout.strip()
            return jsonify({"job_id": job_id, "status": job_status}), 200

        # If squeue doesn't return a status, fall back to sacct for completed/failed jobs
        result = subprocess.run(["sacct", "--jobs", job_id, "--format=State", "--noheader"], capture_output=True, text=True)

        if result.returncode == 0 and result.stdout.strip():
            # Parse only the first line from sacct output
            job_status = result.stdout.strip().splitlines()[0]

            return jsonify({"job_id": job_id, "status": job_status}), 200

        # If sacct also doesn't return a status, return job not found error
        return jsonify({"error": "Job not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/cancel-job', methods=['POST'])
def cancel_job():
    # Get job ID from request
    job_id = request.form.get('job_id')

    if not job_id:
        return jsonify({"error": "No job ID provided"}), 400

    try:
        # Use subprocess to run scancel
        result = subprocess.run(["scancel", job_id], capture_output=True, text=True)

        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500

        return jsonify({"message": f"Job {job_id} cancelled successfully"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)