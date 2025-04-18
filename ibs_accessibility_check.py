#!/usr/bin/env python3
import requests
import json
import subprocess
import sys
import os
import logging

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

def run_s3_upload_test(file_name=None):
    """
    Step 2: Test S3 upload functionality using hardcoded presigned URL
    """
    logger.info("Starting Step 2: Testing S3 presigned URL upload")

    # Default filename
    default_filename = "ibs_test.txt"

    # Use provided value or default
    file_name = file_name or default_filename

    logger.info(f"Using filename: {file_name}")

    # Create sample file
    if not create_sample_file(file_name):
        return False

    # Hardcoded presigned URL (valid for 6 days)
    presigned_url = "https://onelens-kubernetes-agent.s3.amazonaws.com/testtenant/ibs_test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIAY4APA2CF7GZR6BWV%2F20250418%2Fap-south-1%2Fs3%2Faws4_request&X-Amz-Date=20250418T065554Z&X-Amz-Expires=518400&X-Amz-SignedHeaders=host&X-Amz-Security-Token=IQoJb3JpZ2luX2VjEOX%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCmFwLXNvdXRoLTEiRjBEAiAVwiWAYDO0HATWyI9CcF1jNt8QyIz9LSbsKe6jJaIF0AIgNpMPjqjd5z5yRK0wmNPvoMuYXxUb%2BbHNEvDZSUm0iX8qgQMIbxAAGgw2MDk5MTY4NjY2OTkiDHpII9TuI2hBRCxk%2BSreAgMP6fr4cEq1K1MWi3mHhuXSxKX%2Bjf9j0wKyKrxJmvripdBzUNq6pxeri0y%2BzPTiH6ZT466YCunU1tAoyLhjwFxAeX0y6o0tkUTFMpDOLzBQh9JHBPz6R6AGtFfNBcWplwSuGVB7rQfAfSYbnna2ojL5ryuqct%2FJe3NmKy5VYNf9BQrtMp1v09%2FwvSpo7iMEByHaoEs58UEzBMy3GYuWyBkcclbRY%2B1OSvgASBQcMzT7O0m1ZH0OUcFId32MuXPT%2Bkjt2Y6jLGOj7NacTjpiQVq%2B9VxCd%2BnrZuo9jfp%2BdtQIv0tZ%2FH77A7hBtBJbu1VBtmctz6n%2FYTXq0rUw5XS8kyeKk6dFRzfM5XAlSUOuX6wpbaNEA4pM6SOB7i2HL7Wpahzn18WFtTPAiLiyH0aZrP9EcnbPCEzhnnTiLNjKzOl3cJ%2BJns1QrpIEkBEIeNRk%2FfNNOlRRHS%2F2P0xEhfH%2FMKjEh8AGOqcBpKUIZdx7SUdMw9fvEibq7wlRyPM7LoXVXKGDBmzqMvoJJOYsm4EkUpzRCReRyUNKkjzMS%2Bfj%2B9XEWonVOIOICz1XikZqsc5doMToFXjq4zLak%2F6S7s%2FxIPjh7DHdJ2l0VtSjMAtyPrcQm1FItx2Ir0ea0sOhEuynzxMZ0EVwgQCoUEeHQGpM8QcxZQw2K7YizVId%2BxlWDy7S3jiKGDNUMnyNUJPFc6A%3D&X-Amz-Signature=445849effedd99385798af18031b83198e48f37c81a0e8d501a9c1a595edf815"

    # Calculate validity in days (518400 seconds = 6 days)
    validity_days = 518400 / (24 * 60 * 60)
    logger.info(f"Using hardcoded presigned URL (valid for {validity_days:.1f} days)")

    # Upload file using presigned URL
    upload_success = upload_file_with_presigned_url(presigned_url, file_name)
    if not upload_success:
        logger.error("\nTest failed during upload step.")
        return False

    logger.info(f"\nS3 upload test completed successfully! File '{file_name}' uploaded to S3.")
    return True

def main():
    """Main function to run the end-to-end test flow"""
    logger.info("Starting combined end-to-end test flow")

    # Process any command line arguments for S3 test
    file_name = None
    if len(sys.argv) == 2:
        file_name = sys.argv[1]

    # Step 1: Run the registration API test
    registration_test_passed = run_registration_api_test()

    # Step 2: Run the S3 upload test with hardcoded URL
    s3_test_passed = run_s3_upload_test(file_name)

    # Determine overall test result
    if registration_test_passed and s3_test_passed:
        logger.info("🎉 All tests PASSED!")
        return 0
    else:
        logger.error("❌ Some tests FAILED. Check logs for details.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
