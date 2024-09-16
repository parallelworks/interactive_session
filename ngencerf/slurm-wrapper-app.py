import subprocess
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/submit-job', methods=['POST'])
def submit_job():
    # Get SLURM script from request
    slurm_script = request.form.get('slurm_script')
    
    if not slurm_script:
        return jsonify({"error": "No SLURM script provided"}), 400

    try:
        # Create a temporary file to save the script
        with open("job_script.sh", "w") as script_file:
            script_file.write(slurm_script)

        # Use subprocess to run sbatch and capture the output
        result = subprocess.run(["sbatch", "job_script.sh"], capture_output=True, text=True)

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
        # Use subprocess to run squeue or sacct to get job status
        result = subprocess.run(["squeue", "--job", job_id, "--format=%T", "--noheader"], capture_output=True, text=True)
        
        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500

        # Clean the output and return job status
        job_status = result.stdout.strip()
        
        if not job_status:
            return jsonify({"error": "Job not found"}), 404

        return jsonify({"job_id": job_id, "status": job_status}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)