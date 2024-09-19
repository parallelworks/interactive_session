# SLURM REST API Wrapper for NGEN-CAL Jobs
This Flask-based API is designed to submit, monitor, and cancel jobs for the ngen-cal model running inside a Singularity container in a SLURM-managed cluster. The app runs on the controller node of the SLURM cluster and facilitates interactions with SLURM via RESTful API calls. The API writes the SLURM job script and SLURM logs to the same directory as the input file. The app is launched and stopped by the `ngencerf_start` workflow from the Parallel Works platform.

### Environment Variables
The environment variables are defined in the XML or YAML definition file of the `ngencerf_start` workflow.
- `LOCAL_DATA_DIR`: Path to the data directory on the shared filesystem (e.g., `/ngencerf-app/data/ngen-cal-data/`).
- `CONTAINER_DATA_DIR`: Path to the data directory within the container (e.g., `/ngencerf/data/`).
- `SINGULARITY_CONTAINER_PATH`: Path to the Singularity container that includes `ngen-cal`.

## API Endpoints
### 1. Submit a Job
Submit a `ngen-cal` job to SLURM. The job type can be either a `calibration` or `validation` job.
**Endpoint:** 
```
POST /submit-job
```
**Request Parameters:**
- `job_id`: (string, required) Unique identifier for the `ngen-cal` job.
- `job_type`: (string, required) Type of job: either `calibration` or `validation`.
- `input_file`: (string, required) Path to the ngen-cal input file inside the container (e.g., `/ngencerf/data/input.yaml`).


**Response:**
- `slurm_job_id`: The SLURM job ID (different from the ngen-cal job ID).

**Curl Example:**
```
curl -X POST http://<controller-ip>:5000/submit-job \
    -F "job_id=ngen_cal_123" \
    -F "job_type=calibration" \
    -F "input_file=/ngencerf/data/input.yaml"
```

**Note:**
- The `job_id` is the unique identifier for the ngen-cal job.
- The `slurm_job_id` is the SLURM-specific job identifier assigned when the job is submitted to the SLURM scheduler.


### 2. Submit a Job
Check the status of a submitted SLURM job.

**Endpoint:** 
```
GET /job-status
```
**Request Parameters:**
- `slurm_job_id`: (string, required) The SLURM job ID.

**Response:**
- `slurm_job_id`: The SLURM job ID (different from the ngen-cal job ID).
- `status`: The current status of the job as reported by the SLURM scheduler (PENDING, RUNNING, COMPLETED, FAILED, etc.).

**Curl Example:**
```
curl -X GET "http://<controller-ip>:5000/job-status?slurm_job_id=123456"
```

### 3. Cancel a Job
Cancel a running or pending SLURM job.

**Endpoint:** 
```
POST /cancel-job
```
**Request Parameters:**
- `slurm_job_id`: (string, required) The SLURM job ID to cancel.

**Response:**
- A success message indicating that the job has been canceled.

**Curl Example:**
```
curl -X POST http://<controller-ip>:5000/cancel-job \
    -F "slurm_job_id=123456"
```

## Error Handling
In case of any errors, the API responds with an appropriate error message and HTTP status code. For example:

- Missing required parameters will return a 400 Bad Request with a descriptive error message.
- SLURM job submission errors (via sbatch) or cancellation errors (via scancel) will return a 500 Internal Server Error with the error details from SLURM.

