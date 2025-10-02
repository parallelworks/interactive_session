# SLURM REST API Wrapper for NGEN-CAL Jobs
This Flask-based API is designed to submit, monitor, and cancel jobs for the ngen-cal model running inside a Singularity container in a SLURM-managed cluster. The app runs on the controller node of the SLURM cluster and facilitates interactions with SLURM via RESTful API calls. The API writes the SLURM job script and SLURM logs to the same directory as the input file. The app is launched and stopped by the `ngencerf_start` workflow from the Parallel Works platform.

### Environment Variables
The environment variables are defined in the XML or YAML definition file of the `ngencerf_start` workflow.
- `LOCAL_DATA_DIR`: Path to the data directory on the shared filesystem (e.g., `/ngencerf-app/data/ngen-cal-data/`).
- `CONTAINER_DATA_DIR`: Path to the data directory within the container (e.g., `/ngencerf/data/`).
- `NGEN_CAL_SINGULARITY_CONTAINER_PATH`: Path to the Singularity container that includes `ngen-cal`.
- `NGEN_BMI_FORCING_SINGULARITY_CONTAINER_PATH`: Path to the Singularity container that includes `ngen-bmi-forcing`.


## API Endpoints
### 1. Submit a Calibration Job
Submit a `ngen-cal` calibration job to SLURM.
**Endpoint:**
```
POST /submit-calibration-job
```
**Request Parameters:**
- `calibration_run_id`: (string, required) Unique identifier for the `ngen-cal` calibration job.
- `input_file`: (string, required) Path to the ngen-cal input file inside the container (e.g., `/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_calib.yaml`).
- `output_file`: (string, required) Path to the SLURM job log file in the controller node.
- `auth_token`: (string, required) Token to authenticate with `http://localhost:8000/calibration/slurm_callback/`.

**Response:**
- `slurm_job_id`: The SLURM job ID (different from the ngen-cal job ID).
- `ngen_commit_hash`: Commit hash of the ngen repository
- `ngen_cal_commit_hash`: Commit hash of the ngen-cal repository

**Curl Example:**
```
curl -X POST http://<controller-ip>:5000/submit-calibration-job \
    -F "calibration_run_id=ngen_cal_123" \
    -F "input_file=/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_calib.yaml" \
    -F "job_stage=this-is-a-string" \
    -F "output_file=/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_stdout.out" \
    -F "auth_token=authentication-token"
```

**Note:**
- The `job_id` is the unique identifier for the ngen-cal job.
- The `slurm_job_id` is the SLURM-specific job identifier assigned when the job is submitted to the SLURM scheduler.


### 2. Submit a Validation Job
Submit a ngen-cal validation job to SLURM. Endpoint:

**Endpoint:**
```
POST /submit-validation-job
```


**Request Parameters:**
- `validation_run_id`: (string, required) Unique identifier for the `ngen-cal` validation job.
- `input_file`: (string, required) Path to the ngen-cal input file inside the container (e.g., `/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_validation.yaml`).
- `output_file`: (string, required) Path to the SLURM job log file in the controller node.
- `auth_token`: (string, required) Token to authenticate with `http://localhost:8000/calibration/slurm_callback/`.
- `job_type`: (string, required) The type of job to run using the ngen-cal container. Must be one of the following: valid_control, valid_best or valid_iteration.
- `worker_name`: (string, required only for valid_iteration) Name of the worker processing the job.
- `iteration`: (integer, required only for valid_iteration) Current iteration number for the validation job.

**Response:**
- `slurm_job_id`: The SLURM job ID (different from the ngen-cal job ID).
- `ngen_commit_hash`: Commit hash of the ngen repository
- `ngen_cal_commit_hash`: Commit hash of the ngen-cal repository

**Curl Example:**
```
curl -X POST http://<controller-ip>:5000/submit-validation-job \
    -F "validation_run_id=ngen_val_123" \
    -F "input_file=/ngencerf/data/test_calib/kge_dds/cfe_noah/01123000/Input/01123000_config_validation.yaml" \
    -F "worker_name=worker1" \
    -F "iteration=1" \
    -F "output_file=test.out" \
    -F "auth_token=authentication-token"
```

### 2. Check Job Status
Check the status of a submitted SLURM job.

**Endpoint:**
```
GET /job-status
```
**Request Parameters:**
- `slurm_job_id`: (string, required) The SLURM job ID.

**Response:**
- `slurm_job_id`: The SLURM job ID (different from the ngen-cal job ID).
- `job_id`: (string, required) Unique identifier for the `ngen-cal` job.
- `job_stage`: (string, required) Required to initiate the callback.
- `auth_token`: (string, required) Token to authenticate with http://localhost:8000/calibration/slurm_callback/.

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


