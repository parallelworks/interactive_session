#!/pw/.miniconda3/bin/python
import requests
import os
import json
import argparse

"""
Description: 
The script is a versatile command-line tool that retrieves and formats cloud storage bucket access tokens.
It accepts user-specified arguments for the bucket ID and desired output format (JSON or text).
This tool simplifies the process of obtaining and utilizing bucket access tokens for cloud storage management tasks.

Example bash command to obtain credentials from the CONTROLLER NODE of a cloud cluster:
eval $(ssh usercontainer /swift-pw-bin/utils/bucket_token_generator.py --bucket_id <id> --token_format text)

Example bash command to obtain credentials from a COMPUTE NODE within the cloud cluster:
eval $(ssh -J <controller-internal-ip> usercontainer /swift-pw-bin/utils/bucket_token_generator.py --bucket_id <id> --token_format text)

Example python script to obtain credentials from the CONTROLLER NODE of a cloud cluster:

import subprocess
import os
import json

def load_bucket_credentials(bucket_id):
    cmd = [
        "ssh", "usercontainer",
        "/swift-pw-bin/utils/bucket_token_generator.py",
        "--bucket_id", bucket_id,
        "--token_format", "json"
    ]
    
    output = subprocess.check_output(cmd, universal_newlines = True)
    env_vars = json.loads(output)
    os.environ.update(env_vars)

"""

PW_PLATFORM_HOST = os.environ.get('PW_PLATFORM_HOST')
PW_API_KEY = os.environ.get('PW_API_KEY')
STORAGE_URL = f'https://{PW_PLATFORM_HOST}/api/v2/storage?key={PW_API_KEY}'
BUCKET_TOKEN_URL = f'https://{PW_PLATFORM_HOST}/api/v2/vault/getBucketToken?key={PW_API_KEY}'


if not PW_PLATFORM_HOST or not PW_API_KEY:
    raise EnvironmentError("Please set the 'PW_PLATFORM_HOST' and 'PW_API_KEY' environment variables.")


def get_bucket_info_with_name(bucket_name: str, bucket_namespace: str) -> dict:
    res = requests.get(STORAGE_URL)
    for bucket in res.json():
        if bucket_name == bucket['name'] and bucket_namespace == bucket['namespace']:
            return bucket
    
    # If no matching bucket is found, raise an exception
    raise Exception(f"No bucket found with name '{bucket_name}' and namespace '{bucket_namespace}'")

def get_bucket_info_with_id(bucket_id: str) -> dict:
    res = requests.get(STORAGE_URL)
    for bucket in res.json():
        if bucket_id == bucket['id']:
            return bucket
    
    # If no matching bucket is found, raise an exception
    raise Exception(f"No bucket found with id '{bucket_id}'")


def get_bucket_token(bucket_id: str) -> dict:
    try:
        post_response = requests.post(BUCKET_TOKEN_URL, data={"bucketID": bucket_id})
        post_response.raise_for_status()  # Raise an exception for HTTP errors
        return post_response.json()
    except requests.exceptions.RequestException as e:
        raise Exception(f"Failed to retrieve bucket token: {str(e)}")

def replace_dict_keys_with_env_vars(post_response: dict, bucket_type: str) -> dict:
    token_dict = {}

    if bucket_type == 'google-bucket':
        token_dict['BUCKET_NAME'] = post_response['bucketName']
        token_dict['CLOUDSDK_AUTH_ACCESS_TOKEN'] = post_response['token']
    elif bucket_type == 'aws-bucket':
        token_dict['BUCKET_NAME'] = post_response['bucketName']
        token_dict['AWS_ACCESS_KEY_ID'] = post_response['access_key']
        token_dict['AWS_SECRET_ACCESS_KEY'] = post_response['secret_key']
        token_dict['AWS_SESSION_TOKEN'] = post_response['security_token']
    else:
        raise ValueError(f"Unsupported bucket_type: {bucket_type}. Only 'google-bucket' or 'aws-bucket' types are supported.")

    return token_dict

def print_formatted_token(token_dict: dict, token_format: str) -> None:
    if token_format == 'json':
        print(json.dumps(token_dict))
    elif token_format == 'text':
        token_txt = "\n".join([f'export {key}="{value}"' for key, value in token_dict.items()])
        print(token_txt)
    else:
        raise ValueError(f"Unsupported token format: {token_format}. Only 'json' or 'text' formats are supported.")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Retrieve and format bucket tokens')
    parser.add_argument('--bucket_id', type=str, help='Bucket ID string or <bucket-namespace>/<bucket-name>')
    parser.add_argument('--token_format', type=str, help='Token format (json or text)')
    args = parser.parse_args()

    try:
        if '/' in args.bucket_id:
            bucket_namespace, bucket_name = args.bucket_id.split('/')
            bucket_info = get_bucket_info_with_name(bucket_name, bucket_namespace)
        else:
            bucket_info = get_bucket_info_with_id(args.bucket_id)

    except ValueError as ve:
        raise(ValueError(f"Error: The bucket_id '{args.bucket_id}' does not match the expected format: string with lowercase letters and numbers or <bucket-namespace>/<bucket-id>"))
    
    except Exception as e:
        raise(Exception(f"{e}"))

    bucket_id = bucket_info['id']
    bucket_type = bucket_info ['type']

    try:
        post_response = get_bucket_token(bucket_id)
        token_dict = replace_dict_keys_with_env_vars(post_response, bucket_type)
        print_formatted_token(token_dict, args.token_format)
    except Exception as e:
        print(f"Error: {str(e)}")
