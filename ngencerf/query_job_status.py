import requests

# API endpoint for querying job status
url = 'http://localhost:5000/job-status'

# SLURM Job ID to query
slurm_job_id = '4'

# Parameters for the request
params = {'job_id': slurm_job_id}

try:
    # Make a GET request to query the job status
    response = requests.get(url, params=params)
    
    if response.status_code == 200:
        job_status = response.json().get('status')
        print(job_status)
        exit()
        print(f"Job ID: {slurm_job_id}, Status: {job_status}")
    elif response.status_code == 404:
        print(f"Job ID: {slurm_job_id} not found")
    else:
        print(f"Failed to query job status: {response.json().get('error')}")
except Exception as e:
    print(f"An error occurred: {str(e)}")
