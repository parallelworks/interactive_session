import requests

# API endpoint for submitting a job
url = 'http://localhost:5000/submit-job'

# Job details
job_data = {
    'job_id': '12345', 
    'job_type': 'calibration',
    'input_file': '/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_calib.yaml',
    'job_stage': 'this-is-a-string',
    'output_file': 'test.out',
    'auth_token': 'this-is-the-auth-token'
}

try:
    # Make a POST request to submit the job
    response = requests.post(url, data=job_data)
    
    if response.status_code == 200:
        slurm_job_id = response.json().get('slurm_job_id')
        print(f"Job submitted successfully! SLURM ob ID: {slurm_job_id}")
    else:
        print(f"Failed to submit job: {response.json().get('error')}")
except Exception as e:
    print(f"An error occurred: {str(e)}")
