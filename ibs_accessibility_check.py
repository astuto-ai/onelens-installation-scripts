#!/usr/bin/env python3
import requests
import json
import subprocess
import sys
import os
import logging
import boto3
from botocore.exceptions import ClientError
from botocore.config import Config

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('e2e_test')

def run_registration_api_test():
    """
    Step 1: Test the cluster registration API and verify the expected error response
    """
    logger.info("Starting Step 1: Testing cluster registration API")

    # API configuration
    API_BASE_URL = "https://api-in.onelens.cloud"
    CLUSTER_NAME = "test-ap-southeast-1-clickhouse-cluster"
    REGISTRATION_TOKEN = "ad41edac-33c6-4e13-86a3-12c08793d0f9"
    ACCOUNT = "609916866699"
    REGION = "ap-southeast-1"
    RELEASE_VERSION = "0.1.1-beta.3"

    # API endpoint and payload
    endpoint = f"{API_BASE_URL}/v1/kubernetes/registration"
    headers = {"Content-Type": "application/json"}
    payload = {
        "registration_token": REGISTRATION_TOKEN,
        "cluster_name": CLUSTER_NAME,
        "account_id": ACCOUNT,
        "region": REGION,
        "agent_version": RELEASE_VERSION
    }

    # Make the API request
    try:
        logger.info(f"Sending POST request to {endpoint}")
        response = requests.post(endpoint, headers=headers, json=payload)

        # Print full response with headers for debugging
        logger.info(f"Response status code: {response.status_code}")
        logger.info(f"Response headers: {response.headers}")

        # Parse and validate response
        try:
            response_json = response.json()
            logger.info(f"Response body: {json.dumps(response_json, indent=2)}")

            # Check if the expected error message is present
            expected_error = "Cluster test-ap-southeast-1-clickhouse-cluster is already registered and connected"
            if (response_json.get("data", {}).get("error_code") == "VALIDATION_ERROR" and
                expected_error in response_json.get("message", "")):
                logger.info("✅ Test PASSED: Received expected validation error")
                return True
            else:
                logger.error("❌ Test FAILED: Did not receive expected validation error")
                return False
        except json.JSONDecodeError:
            logger.error(f"❌ Test FAILED: Invalid JSON response: {response.text}")
            return False
    except requests.RequestException as e:
        logger.error(f"❌ Test FAILED: Request exception: {str(e)}")
        return False

def generate_presigned_url(bucket_name, folder_path, file_name, expires_in=3600):
    """
    Generate a pre-signed URL for uploading a file to S3
    """
    try:
        # Create S3 client with signature version 4
        s3_client = boto3.client('s3', config=Config(signature_version="s3v4"))

        # Ensure folder path ends with a slash
        if not folder_path.endswith('/'):
            folder_path += '/'

        # Generate a pre-signed URL for a dynamic file inside the folder
        object_key = folder_path + file_name
        logger.info(f"Generating presigned URL for:\nBucket: {bucket_name}\nKey: {object_key}")

        response = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket_name, 'Key': object_key},
            ExpiresIn=expires_in
        )

        logger.info("\nSuccess! Presigned URL generated:")
        logger.info(response)
        return response
    except ClientError as e:
        logger.error(f"\nError generating presigned URL:")
        logger.error(f"Error code: {e.response['Error']['Code']}")
        logger.error(f"Error message: {e.response['Error']['Message']}")
        return None
    except Exception as e:
        logger.error(f"\nUnexpected error occurred:")
        logger.error(f"Error: {str(e)}")
        return None

def create_sample_file(file_name, content="This is a test file for S3 upload."):
    """
    Create a sample file for testing S3 upload
    """
    try:
        with open(file_name, 'w') as f:
            f.write(content)
        logger.info(f"Created sample file: {file_name}")
        return True
    except Exception as e:
        logger.error(f"Error creating sample file: {str(e)}")
        return False

def run_shell_command(command):
    """
    Helper function to run shell commands and return output
    """
    try:
        result = subprocess.run(
            command,
            shell=True,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        return True, result.stdout
    except subprocess.CalledProcessError as e:
        return False, f"Command failed with exit code {e.returncode}: {e.stderr}"

def upload_file_with_presigned_url(presigned_url, file_path):
    """
    Upload a file using a pre-signed URL
    """
    try:
        curl_command = f'curl -XPUT "{presigned_url}" -T "{file_path}"'
        logger.info(f"Running command: {curl_command}")

        success, output = run_shell_command(curl_command)

        if success:
            logger.info("\nUpload successful!")
            logger.info(f"Response: {output}")
            return True
        else:
            logger.error(f"\nError uploading file using curl:")
            logger.error(f"Error: {output}")
            return False
    except Exception as e:
        logger.error(f"\nUnexpected error during upload:")
        logger.error(f"Error: {str(e)}")
        return False

def run_s3_upload_test(bucket_name=None, folder_path=None, file_name=None):
    """
    Step 2: Test S3 upload functionality using presigned URLs
    """
    logger.info("Starting Step 2: Testing S3 presigned URL upload")

    # Default values
    default_bucket = "onelens-kubernetes-agent"
    default_folder = "testtenant"
    default_filename = "ibs_test.txt"

    # Use provided values or defaults
    bucket_name = bucket_name or default_bucket
    folder_path = folder_path or default_folder
    file_name = file_name or default_filename

    logger.info(f"Using values - Bucket: {bucket_name}, Folder: {folder_path}, Filename: {file_name}")

    # Create sample file
    if not create_sample_file(file_name):
        return False

    # Generate presigned URL
    presigned_url = generate_presigned_url(bucket_name, folder_path, file_name)
    if not presigned_url:
        logger.error("\nTest failed during presigned URL generation.")
        return False

    # Upload file using presigned URL
    upload_success = upload_file_with_presigned_url(presigned_url, file_name)
    if not upload_success:
        logger.error("\nTest failed during upload step.")
        return False

    logger.info(f"\nS3 upload test completed successfully! File '{file_name}' uploaded to s3://{bucket_name}/{folder_path}{file_name}")
    return True

def main():
    """Main function to run the end-to-end test flow"""
    logger.info("Starting combined end-to-end test flow")

    # Process any command line arguments for S3 test
    s3_args = {}
    if len(sys.argv) == 4:
        s3_args = {
            "bucket_name": sys.argv[1],
            "folder_path": sys.argv[2],
            "file_name": sys.argv[3]
        }

    # Step 1: Run the registration API test
    registration_test_passed = run_registration_api_test()

    # Step 2: Run the S3 upload test
    s3_test_passed = run_s3_upload_test(**s3_args)

    # Determine overall test result
    if registration_test_passed and s3_test_passed:
        logger.info("🎉 All tests PASSED!")
        return 0
    else:
        logger.error("❌ Some tests FAILED. Check logs for details.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
