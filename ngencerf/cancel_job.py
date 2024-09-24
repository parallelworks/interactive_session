import requests

# API endpoint for canceling a job
url = 'http://localhost:5000/cancel-job'

# SLURM Job ID to cancel
slurm_job_data = {
    'slurm_job_id': '4'

}

try:
    # Make a POST request to cancel the job
    response = requests.post(url, data=slurm_job_data)
    
    if response.status_code == 200:
        print(f"Job {slurm_job_data['slurm_job_id']} cancelled successfully.")
    else:
        print(f"Failed to cancel job: {response.json().get('error')}")
except Exception as e:
    print(f"An error occurred: {str(e)}")
