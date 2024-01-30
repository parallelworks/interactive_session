#!/pw/.miniconda3/bin/python
import json
import os
import logging
import requests
import subprocess
import time
import random
import socket
# VERSION: 15

"""
# Form Resource Wrapper
The code in this workflow is a wrapper to run before any other workflow in order to process and organize 
the resource information. The wrapper performs the following actions:
1. Creates a directory for each resource under the job directory.
2. Completes and validates the following resource information: public ip, internal ip, remote user, 
   working directory, job directory and resource type. Note that this information may be missing or 
   incorrect if the workflow was launched while the resource is starting. 
3. Creates `input.json` and `inputs.sh` files for each resource under the resource's directory. Note 
   that this is helpful to create code that runs on each of the resources without having to parse the 
   workflow arguments every time (see link below). For more information see resource inputs section below.
   https://github.com/parallelworks/workflow_tutorial/blob/main/011_script_submitter_timeout_failover/main.sh
4. Creates a batch header with the PBS or SLURM directives under the resource's directory. Note that this 
   header can be used as the header of any script that the workflow submits to the resource. 
5. Finds a given number of available ports

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
7. nports: Number of available ports to find for this resource. These ports are added to the inputs.json and 
   inputs.sh files.


### Resource Inputs
The wrapper uses the inputs.sh and inputs.json files to write the resources/<resource-label>/inputs.json and
resources/<resource-label>/inputs.sh files. These files contain the following information:
1. Completed and validated resource information (see sections above)
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


RESOURCES_DIR: str = 'resources'
SUPPORTED_RESOURCE_TYPES: list = ['gclusterv2', 'pclusterv2', 'azclusterv2', 'slurmshv2']
SSH_CMD: str = 'ssh  -o StrictHostKeyChecking=no'
PW_PLATFORM_HOST: str = os.environ['PW_PLATFORM_HOST']
PW_API_KEY: str = os.environ['PW_API_KEY']
MIN_PORT: int = 50000
MAX_PORT: int = 55500


def get_logger(log_file, name, level = logging.INFO):
    formatter = logging.Formatter('%(asctime)s %(levelname)-8s %(message)s')
    os.makedirs(os.path.dirname(log_file), exist_ok = True)
    handler = logging.FileHandler(log_file)
    handler.setFormatter(formatter)
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.addHandler(handler)
    return logging.getLogger(name)

os.makedirs(RESOURCES_DIR, exist_ok = True)
log_file = os.path.join(RESOURCES_DIR, os.path.basename(__file__).replace('py', 'log'))
logger = get_logger(log_file, 'resource_wrapper')


def find_available_port_with_socket():
    """
    Only use this function if find_available_port_with_api fails because the ports
    are not reserved with this function.  
    """
    port_range = list(range(MIN_PORT, MAX_PORT + 1))
    random.shuffle(port_range)
    
    for port in port_range:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('localhost', port))
                return port
            except socket.error:
                pass
    return None
 

def find_available_port_with_api():
    url = f'https://{PW_PLATFORM_HOST}/api/v2/usercontainer/getSingleOpenPort?minPort={MIN_PORT}&maxPort={MAX_PORT}&key={PW_API_KEY}'
    logger.info(f'Get request to {url}')
    res = requests.get(url)
    return res.text()


def find_available_ports(n: int):
    available_ports = []
    for i in range(n):
        try: 
            port = find_available_port_with_api()
        except:
            logger.warning('find_available_port_with_api failed')
            port = find_available_port_with_socket()
        
        logger.debug('Selected port ' + str(port))
        available_ports.append(port)
    
    return available_ports



def establish_ssh_connection(resource_info):    
    try:
        ip_address = get_resource_external_ip(resource_info)
        username = get_resource_user(resource_info)
        if '@' in ip_address:
            command = f"{SSH_CMD} {ip_address} hostname"
        else:
            command = f"{SSH_CMD} {username}@{ip_address} hostname"
        
        logger.info(f'Testing SSH connection with command <{command}>')
        subprocess.run(command, check=True, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception as e:
        msg = 'Unable to stablish SSH connection to resource <{name}> with namespace <{namespace}>'.format(
            name = resource_info['name'],
            namespace = resource_info['namespace']
        )
        logger.info(msg)
        return False

def get_command_output(command):
    logger.info(f'Running command <{command}>')
    try:
        result = subprocess.check_output(command, shell=True, universal_newlines=True)
        output = result.strip()
        return output
    except subprocess.CalledProcessError as e:
        raise(Exception(f"An error occurred while executing the command: {e}"))

def is_ip_address(hostname):
    if all([ i.isdigit() for i in hostname.split('.')]):
        return True
    return False


def get_resource_info(resource_id):
    resource_info = {}

    url_resources = 'https://' + \
        PW_PLATFORM_HOST + \
        "/api/resources?key=" + PW_API_KEY

    res = requests.get(url_resources)

    for resource in res.json():
        if type(resource['id']) == str:
            if resource['type'] in SUPPORTED_RESOURCE_TYPES:
                if resource['id'].lower().replace('_', '') == resource_id.lower().replace('_', ''):
                    if resource['status'] != 'on':
                       raise(Exception(f'Resource {resource_id} status is not on. Exiting.'))
                    return resource
    raise (Exception(
        'Resource {} not found. Make sure the resource type is supported!'.format(resource_id)))

def get_resource_workdir(resource_info, public_ip):
    coaster_properties = resource_info['variables']
    workdir = None
    if 'workdir' in coaster_properties:
        workdir = coaster_properties['workdir']
    
    if not workdir:
        command = f'{SSH_CMD} {public_ip} pwd'
        workdir = get_command_output(command)
    
    return workdir

def get_resource_user(resource_info):
    if 'settings' in resource_info:
        if 'slurmUsername' in resource_info['settings']:
            return resource_info['settings']['slurmUsername']
    
    return os.environ['PW_USER']


def get_resource_external_ip(resource_info):
    controller_ip = resource_info.get('controllerIp')
    if controller_ip:
        return controller_ip
    if 'masterNode' in resource_info['state']:
        if '@' in resource_info['state']['masterNode']:
            return resource_info['state']['masterNode']
        else:
            user =  get_resource_user(resource_info)
            return user + '@' + resource_info['state']['masterNode']


def get_resource_internal_ip(resource_info, public_ip):
    coaster_properties = resource_info['variables']
    if 'privateIp' in coaster_properties:
        internal_ip = coaster_properties['privateIp']
    else:
        internal_ip = ''

    if is_ip_address(internal_ip):
        command = f"{SSH_CMD} {public_ip} hostname -I"
    elif not internal_ip:
        command = f"{SSH_CMD} {public_ip} hostname -I"
    else:
        remote_command = f"/usr/sbin/ifconfig {internal_ip} | sed -En -e 's/.*inet ([0-9.]+).*/\\1/p'"
        command = f"{SSH_CMD} {public_ip} \"{remote_command}\""
    
    internal_ip = get_command_output(command)
    return internal_ip.split(' ')[0]

def get_resource_info_with_verified_ip(resource_id, timeout = 600):
    start_time = time.time()
    while True:
        resource_info =  get_resource_info(resource_id)
        if establish_ssh_connection(resource_info):
            return resource_info
        
        time.sleep(5)
        if time.time() - start_time > timeout:
            msg = f'Valid IP address not found for resource {resource_id}. Exiting application.'
            logger.error(msg)
            raise(Exception(msg))

        msg = 'Retrying SSH connection to resource <{name}> with namespace <{namespace}>'.format(
            name = resource_info['name'],
            namespace = resource_info['namespace']
        )

        logger.info(msg)


def replace_placeholders(inputs_dict, placeholder_dict):
    for ik,iv in inputs_dict.items():
        if type(iv) == str:
            for pk, pv in placeholder_dict.items():
                if pk in iv:
                    inputs_dict[ik] =iv.replace(pk, pv)
        elif type(iv) == dict:
            inputs_dict[ik] = replace_placeholders(iv, placeholder_dict)

    return inputs_dict 

def get_partition_os(partition_name, resource_info):
    for partition in resource_info['variables']['config']['partition_config']:
        if partition['name'] == partition_name:
            if 'os' in partition:
                return partition['os']


def get_ssh_config_path(workdir, jobschedulertype, public_ip):
    """
    Returns the ssh config path of the cluster if it exists. Otherwise it returns nothing
    """
    if jobschedulertype == 'CONTROLLER':
        ssh_config_path = 'pw/.pw/config'
    else:
        ssh_config_path =  'pw/.pw/config_compute'

    ssh_config_path = os.path.join(workdir, ssh_config_path)

    command = f"{SSH_CMD} {public_ip} ls {ssh_config_path} 2>/dev/null || echo"

    config_exists = get_command_output(command)

    if config_exists:
        return ssh_config_path

def get_ssh_usercontainer_options(workdir, jobschedulertype, public_ip, private_ip):
    # In some clusters the PW SSH config file is not included in ~/.ssh/config
    ssh_config_path = get_ssh_config_path(
        workdir,
        jobschedulertype, 
        public_ip
    )

    if ssh_config_path:
        return f'-F {ssh_config_path} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    elif jobschedulertype == 'CONTROLLER':
        return f'-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    else:
        return f'-J {private_ip} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

def complete_resource_information(inputs_dict):
    if 'nports' in inputs_dict:
        inputs_dict['resource']['ports'] = find_available_ports(int(inputs_dict['nports']))

    if 'jobschedulertype' not in inputs_dict:
        inputs_dict['jobschedulertype'] = 'CONTROLLER'

    if inputs_dict['resource']['name'] == 'user_workspace':
        inputs_dict['jobschedulertype'] = 'LOCAL'
        inputs_dict['resource']['workdir'] = os.path.expanduser("~")
        inputs_dict['resource']['username'] = os.environ['PW_USER']
    else:
        resource_id = inputs_dict['resource']['id']
        resource_info = get_resource_info_with_verified_ip(resource_id)
        public_ip = get_resource_external_ip(resource_info)

        inputs_dict['resource']['publicIp'] = public_ip
        inputs_dict['resource']['username'] = get_resource_user(resource_info)
        inputs_dict['resource']['type'] = resource_info['type']
        inputs_dict['resource']['workdir'] = get_resource_workdir(resource_info, public_ip)
        inputs_dict['resource']['privateIp'] = get_resource_internal_ip(resource_info, public_ip)

        if inputs_dict['jobschedulertype'] == 'SLURM':
            inputs_dict['submit_cmd'] = "sbatch"
            inputs_dict['cancel_cmd'] = "scancel"
            inputs_dict['status_cmd'] = "squeue" 
        elif inputs_dict['jobschedulertype'] == 'PBS':
            inputs_dict['submit_cmd'] = "qsub"
            inputs_dict['cancel_cmd'] = "qdel"
            inputs_dict['status_cmd'] = "qstat"

        inputs_dict['resource']['ssh_usercontainer_options'] = get_ssh_usercontainer_options(
            inputs_dict['resource']['workdir'],
            inputs_dict['jobschedulertype'], 
            inputs_dict['resource']['publicIp'],
            inputs_dict['resource']['privateIp']
        )


    inputs_dict['resource']['jobdir'] = os.path.join(
        inputs_dict['resource']['workdir'],
        'pw/jobs',
        *os.getcwd().split('/')[-2:]
    )

    # If the OS of the SLURM partition is Windows we assume that the 
    # job directory is not shared. 
    if '_sch__dd_partition_e_' in inputs_dict:
        if inputs_dict['resource']['type'] != 'slurmshv2':
            os_name=get_partition_os(inputs_dict['_sch__dd_partition_e_'], resource_info)
            if os_name == 'windows':
                inputs_dict['resource']['jobdir'] = inputs_dict['resource']['workdir']

    inputs_dict = replace_placeholders(
        inputs_dict, 
        {
            '__workdir__': inputs_dict['resource']['workdir'],
            '__WORKDIR__': inputs_dict['resource']['workdir'],
            '__user__': inputs_dict['resource']['username'],
            '__USER__': inputs_dict['resource']['username'],
            '__pw_user__': os.environ['PW_USER'],
            '__PW_USER__': os.environ['PW_USER']
        }
    )

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
                scheduler_directives.append(schd+v)
        
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
    
    with open(header_sh, 'w') as f:
        f.write('#!/bin/bash\n')
        for schd in scheduler_directives:
            if schd:
                schd.replace('___',' ')
                f.write(f'{directive_prefix} {schd}\n')
        
def create_resource_directory(label, inputs_dict):
    dir = os.path.join(RESOURCES_DIR, label)
    inputs_json = os.path.join(dir, 'inputs.json')
    inputs_sh = os.path.join(dir, 'inputs.sh')
    header_sh = os.path.join(dir, 'batch_header.sh')
    inputs_dict_flatten = flatten_dictionary(inputs_dict)
    # Remove dictionaries
    inputs_dict_flatten = {key: value for key, value in inputs_dict_flatten.items() if not isinstance(value, dict)}

    os.makedirs(dir, exist_ok=True)

    with open(inputs_json, 'w') as f:
        json.dump(inputs_dict, f, indent = 4)

    with open(inputs_sh, 'w') as f:
        for k,v in inputs_dict_flatten.items():
            # Parse newlines as \n for textarea parameter type
            if type(v) == str:
                v = v.replace('\n', '\\n')
            elif type(v) == bool:
                v = str(v).lower() 
            f.write(f"export {k}=\"{v}\"\n")

    create_batch_header(inputs_dict, header_sh)

def is_ssh_tunnel_working(ip_address, ssh_usercontainer_options):
    # Define the SSH command 
    ssh_command = f"ssh {ip_address} \"ssh {ssh_usercontainer_options} usercontainer hostname\""
        
    try:
        # Run the SSH command and capture the output
        output = subprocess.check_output(ssh_command, shell=True, text=True)
        
        # Get the hostname of the local machine
        local_hostname = socket.gethostname()
        
        # Compare the output and local hostname
        if output.strip() == local_hostname:
            return True
        else:
            return False
    except subprocess.CalledProcessError:
        return False


if __name__ == '__main__':
    with open('inputs.json') as inputs_json:
        inputs_dict = json.load(inputs_json)

    # Add basic job info to inputs_dict:
    inputs_dict['job_number'] = os.path.basename(os.getcwd())
    inputs_dict['workflow_name'] = os.path.basename(os.path.dirname(os.getcwd()))
    inputs_dict['job_name'] = "{}-{}".format(inputs_dict['workflow_name'], inputs_dict['job_number'])
    inputs_dict['pw_job_dir'] = os.getcwd()

    # Find all resource labels
    resource_labels = [label.replace('pwrl_','') for label in inputs_dict.keys() if label.startswith('pwrl_')]
    
    if not resource_labels:
        logger.info('No resource labels found. Exiting wrapper.')
        exit()
        
    logger.info('Resource labels: [{}]'.format(', '.join(resource_labels)))
    
    for label in resource_labels:
        logger.info(f'Preparing resource <{label}>')
        # Copy only the resource information corresponding to the resource label
        label_inputs_dict = inputs_dict[f'pwrl_{label}']
        # Copy every other input with no resource label
        for key, value in inputs_dict.items():
            if not key.startswith('pwrl_'):
                label_inputs_dict[key] = value

        label_inputs_dict = complete_resource_information(label_inputs_dict)
        logger.info(json.dumps(label_inputs_dict, indent = 4))
        create_resource_directory(label, label_inputs_dict)
	    
        ip_address = inputs_dict[f'pwrl_{label}']["resource"]["publicIp"]
        ssh_usercontainer_options = inputs_dict[f'pwrl_{label}']['resource']['ssh_usercontainer_options']
    
        if not is_ssh_tunnel_working(ip_address, ssh_usercontainer_options):
            logger.warning('SSH reverse tunnel is not working. Attempting to re-establish tunnel...')

            try:
                subprocess.run(f"ssh -f -N -T -oStrictHostKeyChecking=no -R localhost:2222:localhost:22 {ip_address}", shell=True, check=True)
            except:
                error_message = 'Tunnel retrying failed, exiting workflow'
                logger.error(error_message)
                print(error_message, flush=True)  # Print the error message
                sys.exit(1)  # Exit with an error code
