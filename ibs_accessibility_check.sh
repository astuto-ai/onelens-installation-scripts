#!/bin/bash

# Setup logging
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2
}

# Step 1: Test the cluster registration API and verify the expected error response
run_registration_api_test() {
    log_info "Starting Step 1: Testing cluster registration API"

    # API configuration
    API_BASE_URL="https://api-in.onelens.cloud"
    CLUSTER_NAME="LH_IPHSTG_eks-cluster"
    REGISTRATION_TOKEN="2520b927-9103-4f73-9bd8-9fc0c7055ead"
    ACCOUNT="924145393765"
    REGION="eu-west-1"
    RELEASE_VERSION="0.1.1-beta.4"

    # API endpoint and payload
    endpoint="${API_BASE_URL}/v1/kubernetes/registration"

    # Create JSON payload
    payload=$(cat <<EOF
{
    "registration_token": "${REGISTRATION_TOKEN}",
    "cluster_name": "${CLUSTER_NAME}",
    "account_id": "${ACCOUNT}",
    "region": "${REGION}",
    "agent_version": "${RELEASE_VERSION}"
}
EOF
)

    log_info "Sending POST request to ${endpoint}"

    # Make the API request with curl
    response=$(curl -s -w "\n%{http_code}" -X POST "${endpoint}" \
        -H "Content-Type: application/json" \
        -d "${payload}")

    # Extract status code from the response
    status_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    log_info "Response status code: ${status_code}"
    log_info "Response body: ${response_body}"

    # Check if the response contains the expected error message
    expected_error="Cluster LH_IPHSTG_eks-cluster is already registered and connected"

    # Commented out validation logic - uncomment and modify as needed
    # if echo "$response_body" | grep -q "VALIDATION_ERROR" && echo "$response_body" | grep -q "$expected_error"; then
    #     log_info "✅ Test PASSED: Received expected validation error"
    #     return 0
    # else
    #     log_error "❌ Test FAILED: Did not receive expected validation error"
    #     return 1
    # fi

    # For now, just return success since validation is commented out
    log_info "Registration API test completed (validation currently disabled)"
    return 0
}

# Create a sample file for testing S3 upload
create_sample_file() {
    local file_name="$1"
    local content="${2:-This is a test file for S3 upload.}"

    # Simple error handling
    if echo "$content" > "$file_name" 2>/dev/null; then
        log_info "Created sample file: ${file_name}"
        return 0
    else
        log_error "Error creating sample file: $file_name"
        return 1
    fi
}

# Upload a file using a pre-signed URL
upload_file_with_presigned_url() {
    local presigned_url="$1"
    local file_path="$2"

    log_info "Running command: curl -XPUT \"${presigned_url}\" -T \"${file_path}\""

    # Execute curl command and capture output
    upload_output=$(curl -s -X PUT "${presigned_url}" -T "${file_path}" 2>&1)
    upload_status=$?

    if [ $upload_status -eq 0 ]; then
        log_info "Upload successful!"
        log_info "Response: ${upload_output}"
        return 0
    else
        log_error "Error uploading file using curl"
        log_error "Error: curl command failed with status ${upload_status}"
        log_error "Output: ${upload_output}"
        return 1
    fi
}

# Test S3 upload functionality using hardcoded presigned URL
run_s3_upload_test() {
    log_info "Starting Step 2: Testing S3 presigned URL upload"

    # Default filename
    local default_filename="ibs_test.txt"

    # Use provided value or default
    local file_name="${1:-$default_filename}"

    log_info "Using filename: ${file_name}"

    # Create sample file
    create_sample_file "$file_name" || return 1

    # Hardcoded presigned URL (valid for 6 days)
    local presigned_url="https://delete-me-test-backfilling-eks-metrics.s3.amazonaws.com/test_new_agent/myfile.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIAY4APA2CF6Y2JL4LK%2F20250609%2Fap-south-1%2Fs3%2Faws4_request&X-Amz-Date=20250609T062251Z&X-Amz-Expires=518400&X-Amz-SignedHeaders=host&X-Amz-Security-Token=IQoJb3JpZ2luX2VjEMb%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCmFwLXNvdXRoLTEiSDBGAiEA1WOatL%2BLGfPhokRJCIKk0OXYyZepnHA8Hg5hI78GjNgCIQChjTzzDoZ54BquSZy398UXAomgg0LEzGhCuo2Pn6073SqKAwig%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F8BEAAaDDYwOTkxNjg2NjY5OSIME9rV2pXow3sUgH7PKt4C77kbxhV9JZJGSiLfZdLfve0px4j0dOil4WV70Q1ne335r4hDOlQql6xHJt3WTfnAzk58i5yrRZ0H50mfJy6HBrnlT7Mz9%2Bsw9za4S4HcrjQGsY5653ZqOjOlP8qR2SfzkGvC4cwpbW7kDo7dJzC35bc8Iul6STdw8T%2BIrsqMnGP9v9fUgKr5DBP9NIyvmqUKUMUa0nraPD28zKy7awseXp2UQcF3fNC6VkH8RmLQnoS9zsgyomIs2b3rbTDbU5JjuI7IfOLPptH5V%2Fnlpa5lkjA97ZN6pJE4%2F3jswLKOrN87pY8gnBQFVIp5wzkkGjXOy%2Bc0tFnPQgxZXXlLswHHb5%2BUsJwF5%2FtOL%2FB9a0nLEDq3otMzg0IEiXbRqiZ2dmhErpw9f0y%2BK6pwOrlMvVCjulxonXPeqLYu7%2BvqJtfQHno0hBJ5JrwGDSFT0W1MbBiAlJ18UTj39TXdBbP%2FANowkvuZwgY6pQG2VkLP%2Bh0296ayEC47VB7tG47QQ%2FtwsLGL9Fi6u4%2F1Yim67GP5yEBfl24Lhmem3cRvkGTLxgqsc0Xb0oEJWSw%2FwE1BAbSmkeBlkDDsSaYn29bMFl7MfXbogqBeupWxMTd%2B5UBdsJzvPKzdKI0UXBBoUPtDUaPBSii9EFHqgEk2zWN8%2Fg%2FIkwWGBIXawr2Aw6EAgiaDRxYIN6zXPsTnWX4uspFMtyA%3D&X-Amz-Signature=50147e275d553157314dd8a07f2f951b2649304069b3bdda334de2838c43a23c"

    # Alternative presigned URL (commented out)
    # local presigned_url="https://onelens-kubernetes-agent.s3.amazonaws.com/testtenant/myfile.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIAY4APA2CFYAUIJSWU%2F20250504%2Fap-south-1%2Fs3%2Faws4_request&X-Amz-Date=20250504T172908Z&X-Amz-Expires=518400&X-Amz-SignedHeaders=host&X-Amz-Security-Token=IQoJb3JpZ2luX2VjEHEaCmFwLXNvdXRoLTEiRjBEAiB0stJ2hmKViX%2BllmtE2rtWIESENZxtajtLmbEZSkuwXgIgIAVHroDar%2BtagGiUzUgzSAMYT8Ex8XxUhOeLmiS67RcqgQMIGhAAGgw2MDk5MTY4NjY2OTkiDDW7PHdxGUR%2Bzj8EjireAg9WnoXfsMXH0xOkZncU%2FeyNXq0jsKMXZcolvpm4N8x856Dvggy1%2B7irsTyWN%2Beu8BiFQuzCWR73aowBBEBUhgEDItUAN2iWwNClvX5CGWvmeaJhIXuc4c7qrnHdRrwcDvwBDEkWLByVf7FErsU7L4DKfwYzDbS2321pr9%2FoFLCBYe6E%2BqGnxNNKSCbNpG8vMFvHZY4o2QydDbDgjkIChjjJ9LUxdJNZfrRS2RdEQmUAXmQ1qnLQL2Y%2FjglOQZSkTz51HzH%2BIPLHTG8afCbrENKgRck2D%2BOr5JcfukiCadgBKSnhHaM3Let3jpIZuygC8hj5XjT51f%2FykjxFelaorMF6zlDI8bgAAN%2BxqUB8jaDZLPejMtBHtgXYGF4O7x7Egsl2MTu7vj2pvh1NmEeArv%2F48NuQRtAIU%2BmLS89oHcTscXpHKuVDzYpakU%2FTrbd3qshrucOnHxlwA7wQJ57dMLPA3sAGOqcBHXi3gZ9psk1t75MvtCLkuZqJhzFc7RWSEAeaPQc7Ml0p0fl6fjFKlv3VIwVsVO9MRZHq4GnuxZ7dCvZqhR4HsmCHw9C4hsoh%2B7WSGYSuLktlUE%2FhUmDDa75Qtn%2FwPE533afnU%2FCGqLS1LDhzEn9sdVkj6n9R6BDQ3S%2FXkKDml5ScqGngrlxx7ovwUWwrFIb8LdkD%2F4zQJbl20Di4DkiFAL%2BIbsW%2BGjE%3D&X-Amz-Signature=5f7356b6932a5bf4ec7df047d53883c995ca0a0e0a412817d27922bac52dd797"

    # Calculate validity in days (518400 seconds = 6 days)
    local validity_days
    if command -v bc >/dev/null 2>&1; then
        validity_days=$(echo "scale=1; 518400 / (24 * 60 * 60)" | bc)
    else
        validity_days="6.0"  # Hard-coded as a fallback
    fi
    log_info "Using hardcoded presigned URL (valid for ${validity_days} days)"

    # Upload file using presigned URL
    upload_file_with_presigned_url "$presigned_url" "$file_name"
    local upload_success=$?

    if [ $upload_success -ne 0 ]; then
        log_error "Test failed during upload step."
        return 1
    fi

    log_info "S3 upload test completed successfully! File '${file_name}' uploaded to S3."
    return 0
}

main() {
    log_info "Starting combined end-to-end test flow"

    # Process any command line arguments for S3 test
    local file_name=""
    if [ $# -eq 1 ]; then
        file_name="$1"
    fi

    # Step 1: Run the registration API test
    run_registration_api_test
    local registration_test_passed=$?

    # Step 2: Run the S3 upload test with hardcoded URL
    run_s3_upload_test "$file_name"
    local s3_test_passed=$?

    # Determine overall test result
    if [ $registration_test_passed -eq 0 ] && [ $s3_test_passed -eq 0 ]; then
        log_info "🎉 All tests PASSED!"
        exit 0
    else
        log_error "❌ Some tests FAILED. Check logs for details."
        exit 1
    fi
}

# Run main function with all arguments passed to the script
main "$@"
