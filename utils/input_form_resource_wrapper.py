#!/pw/.miniconda3/bin/python
import json
import os
import sys
import logging
import subprocess
from base64 import b64encode
from copy import deepcopy

"""
# Form Resource Wrapper
The code in this workflow is a wrapper to run before any other workflow in order to process and organize 
the resource information. The wrapper performs the following actions:
1. Creates a directory for each resource under the job directory.
2. Creates `input.json` and `inputs.sh` files for each resource under the resource's directory. Note 
   that this is helpful to create code that runs on each of the resources without having to parse the 
   workflow arguments every time (see link below). For more information see resource inputs section below.
   https://github.com/parallelworks/workflow_tutorial/blob/main/011_script_submitter_timeout_failover/main.sh
3. Creates a batch header with the PBS or SLURM directives under the resource's directory. Note that this 
   header can be used as the header of any script that the workflow submits to the resource. 
4. Replaces the values of _replace_with_<parameter-section>.<parameter-name> with the corresponding value
5. Sets the variable submit_cmd to sbatch or qsub if jobscheduler type is SLURM or PBS, respectively. If
   qos is present in the inputs dict it sets submit_cmd to sbatch --qos <qos>
6. Some parameters have different items (like default value, help, type) depending on other parameters. For,
   example, parameter p1 may have a different default value if the resource is onprem or cloud. The form does
   not support this type of logic so instead we define a parameter p1_tag_onprem and p1_tag_cloud. The resource
   wrapper removes everything after _tag_ and renames the parameter to p1.
7. Calculates the --ntasks-per-node SLURM parameter required to fit a maximum number of workers per node 
   specified in the max_workers_per_node input parameter


### Workflow XML
The wrapper only works if the resources are defined using a specific format in the workflow.xml file. 
1. Every resource is defined in a separate section.
2. The section name is "pwrl_<resource label>", where the prefix "pwrl_" (PW resource label) is used to 
   indicate that the section corresponds to a resource definition section. 
3. Every section may contain the following special parameters: "jobschedulertype", "scheduler_directives", 
   "_sch_ parameters" and "nports".
4. jobschedulertype: Select SLURM, PBS or CONTROLLER if the workflow uses this resource to run jobs on a 
   SLURM partition, a PBS queue or the controller node, respectively.
5. scheduler_directives: Use to type SLURM or PBS scheduler directives for the resource. Use the semicolon 
   character ";" to separate parameters and do not include the "#SLURM" or "#PBS" keywords. For example, 
   "--mem=1000;--gpus-per-node=1" or "-l mem=1000;-l nodes=1:ppn=4".
6. _sch_ parameters: These parameters are used to directly expose SLURM and PBS scheduler directives on 
   the input form in a way that does not require the end user to know the directives or type them using 
   the "scheduler_directives" parameter. A special format must be used to name these parameters. The 
   parameter name is directly converted to the corresponding scheduler directive. Therefore, new directives 
   can be added to the XML without having to modify the workflow code. 

### Resource Inputs
The wrapper uses the inputs.sh and inputs.json files to write the resources/<resource-label>/inputs.json and
resources/<resource-label>/inputs.sh files. These files contain the following information:
2. The resource section of the inputs.json is collapsed and any other resource section is removed, see example below.
   Original inputs.json:
   {
	"novnc_dir": "__WORKDIR__/pw/bootstrap/noVNC-1.3.0",
	"novnc_tgz": "/swift-pw-bin/apps/noVNC-1.3.0.tgz",
	"pwrl_host": {
		"resource": {
			"id": "6419f5bd7d72b40e5b9a2af7",
			"name": "gcpv2",
			"status": "on",
			"namespace": "alvaro",
			"type": "gclusterv2",
			"workdir": "/home/alvaro",
			"publicIp": "35.222.63.173",
			"privateIp": "10.128.0.66",
			"username": "alvaro"
		},
		"nports": "1",
		"jobschedulertype": "CONTROLLER"
	},
	"advanced_options": {
		"service_name": "turbovnc",
		"stream": true
	}
}
resources/host/inputs.json:
{
    "resource": {
        "id": "6419f5bd7d72b40e5b9a2af7",
        "name": "gcpv2",
        "status": "on",
        "namespace": "alvaro",
        "type": "gclusterv2",
        "workdir": "/home/alvaro",
        "publicIp": "alvaro@35.222.63.173",
        "privateIp": "10.128.0.66",
        "username": "alvaro",
        "ports": [
            55238
        ],
        "jobdir": "/home/alvaro/pw/jobs/desktop/00023"
    },
    "nports": "1",
    "jobschedulertype": "CONTROLLER",
    "novnc_dir": "/home/alvaro/pw/bootstrap/noVNC-1.3.0",
    "novnc_tgz": "/swift-pw-bin/apps/noVNC-1.3.0.tgz",
    "advanced_options": {
        "service_name": "turbovnc",
        "stream": true
    }
}
"""

# FIXME: There many ssh connections in this script. Reduce the number of ssh connections

def encode_string_to_base64(text):
    # Convert the string to bytes
    text_bytes = text.encode('utf-8')
    # Encode the bytes to base64
    encoded_bytes = b64encode(text_bytes)
    # Convert the encoded bytes back to a string
    encoded_string = encoded_bytes.decode('utf-8')
    return encoded_string

RESOURCES_DIR: str = 'resources'
SUPPORTED_RESOURCE_TYPES: list = ['gclusterv2', 'pclusterv2', 'azclusterv2', 'slurmshv2', 'existing', 'aws-slurm', 'google-slurm', 'azure-slurm']
ONPREM_RESOURCE_TYPES: list = ['slurmshv2', 'existing']
SSH_CMD: str = 'ssh  -o StrictHostKeyChecking=no'


def get_logger(log_file, name, level=logging.INFO):
    formatter = logging.Formatter('%(asctime)s %(levelname)-8s %(message)s')
    
    # Create directory for the log file if it doesn't exist
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    
    # Create a file handler for writing to the log file
    file_handler = logging.FileHandler(log_file)
    file_handler.setFormatter(formatter)
    
    # Create a stream handler for printing to stdout
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    
    # Get the logger
    logger = logging.getLogger(name)
    logger.setLevel(level)
    
    # Add both handlers to the logger
    logger.addHandler(file_handler)
    logger.addHandler(stream_handler)
    
    return logger

os.makedirs(RESOURCES_DIR, exist_ok = True)
log_file = os.path.join(RESOURCES_DIR, os.path.basename(__file__).replace('py', 'log'))
logger = get_logger(log_file, 'resource_wrapper')


def get_command_output(command):
    logger.info(f'Running command <{command}>')
    try:
        result = subprocess.check_output(command, shell=True, universal_newlines=True)
        output = result.strip()
        return output
    except subprocess.CalledProcessError as e:
        raise(Exception(f"An error occurred while executing the command: {e}"))


def replace_placeholders(inputs_dict, placeholder_dict):
    for ik,iv in inputs_dict.items():
        if type(iv) == str:
            for pk, pv in placeholder_dict.items():
                if pk in iv:
                    inputs_dict[ik] =iv.replace(pk, pv)
        elif type(iv) == dict:
            inputs_dict[ik] = replace_placeholders(iv, placeholder_dict)

    return inputs_dict 



def extract_value_from_dict(string, my_dict):
    """
    Extracts a value from a nested dictionary based on a hierarchical key specified in dot notation.

    Args:
        string (str): A string representing a hierarchical key in dot notation.
        my_dict (dict): The dictionary from which to extract the value.

    Returns:
        The value located at the hierarchical key specified by the input string.
    """
    keys = string.split('.')
    result = my_dict
    for key in keys:
        result = result[key]
    return result


def replace_assigned_values(inputs_dict, inputs_dict_orig):
    keys = list(inputs_dict.keys())
    for ik in keys: #,iv in inputs_dict.items():
        iv = inputs_dict[ik]
        if type(iv) == str:
            if iv.startswith('_replace_with_'):
                pkey = iv.replace('_replace_with_', '')
                inputs_dict[ik] = extract_value_from_dict(pkey, inputs_dict_orig)

        elif type(iv) == dict:
            inputs_dict[ik] = replace_assigned_values(iv, inputs_dict_orig)

    return inputs_dict 


def workers_per_node_to_tasks_per_node(max_workers_per_node, cpus_per_node):
    truncated = cpus_per_node // max_workers_per_node
    remainder = cpus_per_node % max_workers_per_node
    if remainder < truncated:
        return truncated
    else:
        return truncated + 1

def complete_resource_information(inputs_dict):
    
    if not inputs_dict['resource']['publicIp']:
        if not inputs_dict['resource']['privateIp']:
            msg = f'No public or private IP found'
            logger.error(msg)
            print(f'ERROR: {msg}', flush = True)
            raise(Exception(msg))
        else:
            inputs_dict['resource']['publicIp'] = inputs_dict['resource']['privateIp']

    inputs_dict['resource']['publicIp'] = inputs_dict['resource']['username'] + '@' + inputs_dict['resource']['publicIp']
    
    if 'workdir' in inputs_dict:
        inputs_dict['resource']['workdir'] = inputs_dict['workdir']

    if 'jobschedulertype' not in inputs_dict:
        inputs_dict['jobschedulertype'] = 'CONTROLLER'

    if inputs_dict['resource']['name'] == 'user_workspace':
        inputs_dict['jobschedulertype'] = 'LOCAL'
        inputs_dict['resource']['workdir'] = os.path.expanduser("~")
    else:
        workdir = inputs_dict['resource'].get('workdir')
        if not workdir or workdir == '${HOME}':
            command_to_get_home_directory = f"{SSH_CMD} {inputs_dict['resource']['publicIp']} pwd"
            inputs_dict['resource']['workdir'] = get_command_output(command_to_get_home_directory)

        if inputs_dict['jobschedulertype'] == 'SLURM':
            if '_sch__dd_partition_e_' in inputs_dict:
                partition = inputs_dict['_sch__dd_partition_e_']
                command_to_obtain_cpus_per_node=f"{SSH_CMD} {inputs_dict['resource']['publicIp']} sinfo -Nel | awk '/{partition}/ " + "{print $5}' | tail -n1"
                cpus_per_node = get_command_output(command_to_obtain_cpus_per_node)
                if cpus_per_node:
                    cpus_per_node = int(cpus_per_node)
                    inputs_dict['cpus_per_node'] = cpus_per_node


            if 'cpus_per_node' in inputs_dict and 'max_workers_per_node' in inputs_dict:
                max_workers_per_node = int(inputs_dict['max_workers_per_node'])
                inputs_dict['_sch__dd_ntasks_d_per_d_node_e_'] = workers_per_node_to_tasks_per_node(max_workers_per_node, cpus_per_node)

            inputs_dict['submit_cmd'] = "sbatch"
            if 'qos' in inputs_dict:
                inputs_dict['submit_cmd'] = inputs_dict['submit_cmd']  + ' --qos ' + inputs_dict['qos']
            inputs_dict['cancel_cmd'] = "scancel"
            inputs_dict['status_cmd'] = "squeue" 

        elif inputs_dict['jobschedulertype'] == 'PBS':
            inputs_dict['submit_cmd'] = "qsub"
            inputs_dict['cancel_cmd'] = "qdel"
            inputs_dict['status_cmd'] = "qstat"


    inputs_dict['resource']['jobdir'] = os.path.join(
        inputs_dict['resource']['workdir'],
        'pw/jobs',
        inputs_dict['workflow_name'],
        inputs_dict['job_number']
    )

    inputs_dict = replace_placeholders(
        inputs_dict, 
        {
            '__workdir__': inputs_dict['resource']['workdir'],
            '__WORKDIR__': inputs_dict['resource']['workdir'],
	        '__user__': inputs_dict['resource']['username'],
            '__USER__': inputs_dict['resource']['username'],
            '__user__': os.environ['PW_USER'],
            '__USER__': os.environ['PW_USER'],
            '__pw_user__': os.environ['PW_USER'],
            '__PW_USER__': os.environ['PW_USER']
        }
    )

    inputs_dict = replace_assigned_values(inputs_dict, inputs_dict)
    return inputs_dict

def flatten_dictionary(dictionary, parent_key='', separator='_'):
    flattened_dict = {}
    for key, value in dictionary.items():
        new_key = f"{parent_key}{separator}{key}" if parent_key else key
        if isinstance(value, dict):
            flattened_dict.update(flatten_dictionary(value, new_key, separator))
        if isinstance(value, list):
            flattened_dict[new_key] = '___'.join([str(i) for i in value])
        else:
            flattened_dict[new_key] = value
    return flattened_dict

def get_scheduler_directives_from_input_form(inputs_dict):
    """
    The parameter names are converted to scheduler directives
    # Character mapping for special scheduler parameters:
    # 1. _sch_ --> ''
    # 1. _d_ --> '-'
    # 2. _dd_ --> '--'
    # 2. _e_ --> '='
    # 3. ___ --> ' ' (Not in this function)
    # Get special scheduler parameters
    """

    scheduler_directives = []
    for k,v in inputs_dict.items():
        if k.startswith('_sch_'):
            schd = k.replace('_sch_', '')
            schd = schd.replace('_d_', '-')
            schd = schd.replace('_dd_', '--')
            schd = schd.replace('_e_', '=')
            schd = schd.replace('___', ' ')
            if v:
                scheduler_directives.append(schd+str(v))
        
    return scheduler_directives


def create_batch_header(inputs_dict, header_sh):
    scheduler_directives = []

    if 'scheduler_directives' in inputs_dict:
        scheduler_directives = inputs_dict['scheduler_directives'].split(';')
    
    elif inputs_dict['jobschedulertype'] == 'SLURM':
        if 'scheduler_directives_slurm' in inputs_dict:
            scheduler_directives = inputs_dict['scheduler_directives_slurm'].split(';')
    
    elif inputs_dict['jobschedulertype'] == 'PBS':
        if 'scheduler_directives_pbs' in inputs_dict:
            scheduler_directives = inputs_dict['scheduler_directives_pbs'].split(';')

    if scheduler_directives:
        scheduler_directives = [schd.lstrip() for schd in scheduler_directives]

    scheduler_directives += get_scheduler_directives_from_input_form(inputs_dict)

    jobdir = inputs_dict['resource']['jobdir']
    scheduler_directives += [f'-o {jobdir}/logs.out', f'-e {jobdir}/logs.out']
    jobschedulertype = inputs_dict['jobschedulertype']

    if jobschedulertype == 'SLURM':
        directive_prefix="#SBATCH"
        scheduler_directives += ["--job-name={}".format(inputs_dict['job_name']), f"--chdir={jobdir}"]
    elif jobschedulertype == 'PBS':
        directive_prefix="#PBS"
        scheduler_directives += ["-N {}".format(inputs_dict['job_name'])]
    else:
        return
    
    if 'shebang' in inputs_dict:
        shebang = inputs_dict['shebang']
    else:
        shebang = '#!/bin/bash'
        
    with open(header_sh, 'w') as f:
        f.write(shebang + '\n')
        for schd in scheduler_directives:
            if schd:
                schd.replace('___',' ')
                f.write(f'{directive_prefix} {schd}\n')

def convert_bool_to_string(bool_var):
    if bool_var:
        return "true"
    return "false"

def create_resource_directory(resource_inputs, resource_label):
    dir = os.path.join(RESOURCES_DIR, resource_label)
    inputs_json = os.path.join(dir, 'inputs.json')
    inputs_sh = os.path.join(dir, 'inputs.sh')
    header_sh = os.path.join(dir, 'batch_header.sh')
    resource_inputs_flatten = flatten_dictionary(resource_inputs)
    # Remove dictionaries
    resource_inputs_flatten = {key: value for key, value in resource_inputs_flatten.items() if not isinstance(value, dict)}

    os.makedirs(dir, exist_ok=True)

    with open(inputs_json, 'w') as f:
        json.dump(resource_inputs, f, indent = 4)

    with open(inputs_sh, 'w') as f:
        for k,v in resource_inputs_flatten.items():
            if type(v) == bool:
                v = convert_bool_to_string(v)
            f.write(f"export {k}=\"{v}\"\n")

    create_batch_header(resource_inputs, header_sh)


def extract_resource_inputs(inputs_dict, resource_label):
    """
    Extracts inputs from a dictionary, including the resource-specific data identified 
    by the provided resource label, along with any general inputs not associated with a resource label.
    
    Parameters:
        inputs_dict (dict): The dictionary with the contents of /pw/jobs/<workflow-name>/inputs.json
        label (str): The resource label identifying the resource-specific data to be extracted.
    
    Returns:
        dict: A dictionary containing both the resource data corresponding to the provided label
        and any general inputs not associated with a specific resource.
    """
    resource_inputs = inputs_dict[f'pwrl_{resource_label}']

    # Copy every other input with no resource label
    for key, value in inputs_dict.items():
        if not key.startswith('pwrl_'):
            resource_inputs[key] = value
    
    return resource_inputs



def check_slurm(public_ip):
    # Fail if slurmctld is not running
    command = f'{SSH_CMD} {public_ip} ps aux | grep slurmctld | grep -v grep || echo'
    is_slurmctld = get_command_output(command)

    if not is_slurmctld:
        msg = f'slurmctld is not running in resource {public_ip}'
        logger.error(msg)
        print(f'ERROR: {msg}', flush = True)
        raise(Exception(msg))


def create_remote_job_directory(ip, jobdir):
    mkdir_cmd =f"{SSH_CMD} {ip} mkdir -p {jobdir}"
    get_command_output(mkdir_cmd)


def prepare_resource(inputs_dict, resource_label):

    resource_inputs = extract_resource_inputs(inputs_dict, resource_label)

    resource_inputs = complete_resource_information(resource_inputs)
    resource_inputs['resource']['label'] = resource_label

    if resource_inputs['jobschedulertype'] == 'SLURM' and resource_inputs['resource']['type'] not in ONPREM_RESOURCE_TYPES:
        check_slurm(resource_inputs['resource']['publicIp'])

    logger.info(json.dumps(resource_inputs, indent = 4))
    create_resource_directory(resource_inputs, resource_label)

    create_remote_job_directory(resource_inputs['resource']['publicIp'], resource_inputs['resource']['jobdir'])
    

def clean_inputs(inputs_dict):
    """
    Some parameters have different items (like default value, help, type) depending on other parameters. For,
    example, parameter p1 may have a different default value if the resource is onprem or cloud. The form does
    not support this type of logic so instead we define a parameter p1_tag_onprem and p1_tag_cloud. The resource
    wrapper removes everything after _tag_ and renames the parameter to p1.
    """
    new_inputs_dict = deepcopy(inputs_dict)

    for ik,iv in inputs_dict.items():
        if '_tag_' in ik:
            del new_inputs_dict[ik]
            new_ik = ik.split('_tag_')[0]
        else:
            new_ik = ik

        if type(iv) == dict:
            new_inputs_dict[new_ik] = clean_inputs(iv)
        elif iv:
            new_inputs_dict[new_ik] = iv

    return new_inputs_dict

if __name__ == '__main__':
    with open('inputs.json') as inputs_json:
        inputs_dict = json.load(inputs_json)

    # FIXME: Remove this code when issue https://github.com/parallelworks/core/issues/5826 is resolved!
    if len(sys.argv) == 2:
        public_ip = sys.argv[1]
        inputs_dict['pwrl_host']['resource']['publicIp'] = public_ip
    ################################################################################

    inputs_dict = clean_inputs(inputs_dict)

    # Add basic job info to inputs_dict:
    inputs_dict['job_number'] = os.path.basename(os.getcwd())
    inputs_dict['job_number_int'] = int(inputs_dict['job_number'])
    inputs_dict['workflow_name'] = os.path.basename(os.path.dirname(os.getcwd()))
    inputs_dict['job_name'] = "{}-{}".format(inputs_dict['workflow_name'], inputs_dict['job_number'])
    inputs_dict['pw_job_dir'] = os.getcwd()
    inputs_dict['pw_user'] = os.environ.get('PW_USER')
    inputs_dict['pw_platform_host'] = os.environ.get('PW_PLATFORM_HOST')

    # Find all resource labels
    resource_labels = [label.replace('pwrl_','') for label in inputs_dict.keys() if label.startswith('pwrl_')]
    
    if not resource_labels:
        logger.info('No resource labels found. Exiting wrapper.')
        exit()
        
    logger.info('Resource labels: [{}]'.format(', '.join(resource_labels)))
    
    for label in resource_labels:
        logger.info(f'Preparing resource <{label}>')
        prepare_resource(inputs_dict, label)
