#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$(lib_dir)/resource-sizing.sh"
set_test_file "test-storage.sh"
ROOT=$(repo_root)

# Prerequisites
if ! command -v helm &>/dev/null; then
    echo "SKIP: helm not found"
    exit 0
fi
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts 2>/dev/null || true
helm repo update onelens 2>/dev/null || true
if ! helm show chart onelens/onelens-agent --version 2.1.3 &>/dev/null; then
    echo "SKIP: chart not accessible"
    exit 0
fi
CHART_VERSION="2.1.3"

###############################################################################
# Test 1: AWS storage class provisioner and volumeType
###############################################################################
RENDERED_AWS=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set onelens-agent.storageClass.provisioner="ebs.csi.aws.com" \
    --set onelens-agent.storageClass.volumeType="gp3" \
    2>/dev/null)

assert_contains "$RENDERED_AWS" "ebs.csi.aws.com" "AWS: provisioner is ebs.csi.aws.com"
assert_contains "$RENDERED_AWS" "gp3" "AWS: volumeType is gp3"

###############################################################################
# Test 2: Azure storage class provisioner and skuName
###############################################################################
RENDERED_AZURE=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set onelens-agent.storageClass.provisioner="disk.csi.azure.com" \
    --set onelens-agent.storageClass.azure.skuName="StandardSSD_LRS" \
    2>/dev/null)

assert_contains "$RENDERED_AZURE" "disk.csi.azure.com" "Azure: provisioner is disk.csi.azure.com"
assert_contains "$RENDERED_AZURE" "StandardSSD_LRS" "Azure: skuName is StandardSSD_LRS"

###############################################################################
# Test 3: PVC size per tier
###############################################################################
for tier_pods in 25 75 200 700 1200 2000; do
    select_retention_tier "$tier_pods"

    RENDERED=$(helm template test-release onelens/onelens-agent \
        --version "$CHART_VERSION" \
        --set prometheus.server.persistentVolume.enabled=true \
        --set-string prometheus.server.persistentVolume.size="$PROMETHEUS_VOLUME_SIZE" \
        2>/dev/null)

    # Find the PVC storage request in rendered output
    pvc_size=$(echo "$RENDERED" | grep -A 20 'PersistentVolumeClaim' | grep -A 3 'requests:' | grep 'storage:' | head -1 | awk '{print $2}' | tr -d '"' || true)
    assert_eq "$pvc_size" "$PROMETHEUS_VOLUME_SIZE" "PVC size for ${tier_pods} pods = $PROMETHEUS_VOLUME_SIZE"
done

###############################################################################
# Test 4: Retention size per tier matches library values
###############################################################################
select_retention_tier 25
assert_eq "$PROMETHEUS_RETENTION_SIZE" "4GB" "tiny tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "8Gi" "tiny tier volume size"

select_retention_tier 75
assert_eq "$PROMETHEUS_RETENTION_SIZE" "6GB" "small tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "10Gi" "small tier volume size"

select_retention_tier 200
assert_eq "$PROMETHEUS_RETENTION_SIZE" "12GB" "medium tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "20Gi" "medium tier volume size"

select_retention_tier 700
assert_eq "$PROMETHEUS_RETENTION_SIZE" "20GB" "large tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "30Gi" "large tier volume size"

select_retention_tier 1200
assert_eq "$PROMETHEUS_RETENTION_SIZE" "30GB" "xl tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "40Gi" "xl tier volume size"

select_retention_tier 2000
assert_eq "$PROMETHEUS_RETENTION_SIZE" "35GB" "xxl tier retention size"
assert_eq "$PROMETHEUS_VOLUME_SIZE" "50Gi" "xxl tier volume size"

###############################################################################
# Test 5: install.sh storage class paths match expected helm paths
###############################################################################
# Verify install.sh uses the correct --set paths for storage
install_storage_paths=$(grep -oE '\-\-set onelens-agent\.storageClass\.[a-zA-Z.]*=' "$ROOT/install.sh" | sed 's/--set //' | sed 's/=//' | sort -u || true)

assert_contains "$install_storage_paths" "onelens-agent.storageClass.provisioner" "install.sh sets storageClass.provisioner"

# AWS-specific path
aws_path=$(grep 'storageClass.volumeType' "$ROOT/install.sh" | head -1 || true)
assert_ne "$aws_path" "" "install.sh has AWS volumeType --set path"

# Azure-specific path
azure_path=$(grep 'storageClass.azure.skuName' "$ROOT/install.sh" | head -1 || true)
assert_ne "$azure_path" "" "install.sh has Azure skuName --set path"

###############################################################################
# Test 6: EBS tags and encryption paths exist in install.sh
###############################################################################
ebs_tags_code=$(grep -c 'EBS_TAGS_ENABLED' "$ROOT/install.sh" || true)
assert_gt "$ebs_tags_code" "0" "install.sh handles EBS_TAGS_ENABLED"

ebs_encrypt_code=$(grep -c 'EBS_ENCRYPTION_ENABLED' "$ROOT/install.sh" || true)
assert_gt "$ebs_encrypt_code" "0" "install.sh handles EBS_ENCRYPTION_ENABLED"

###############################################################################
# Test 7: Azure disk tags and encryption paths exist in install.sh
###############################################################################
azure_tags_code=$(grep -c 'AZURE_DISK_TAGS_ENABLED' "$ROOT/install.sh" || true)
assert_gt "$azure_tags_code" "0" "install.sh handles AZURE_DISK_TAGS_ENABLED"

azure_encrypt_code=$(grep -c 'AZURE_DISK_ENCRYPTION_ENABLED' "$ROOT/install.sh" || true)
assert_gt "$azure_encrypt_code" "0" "install.sh handles AZURE_DISK_ENCRYPTION_ENABLED"

###############################################################################
# Test 8: EFS support in values and install.sh
###############################################################################
# values.yaml must have efs section with fileSystemId
efs_values=$(grep -c 'efs:' "$ROOT/charts/onelens-agent/values.yaml" || true)
assert_gt "$efs_values" "0" "values.yaml has efs section"

efs_fsid=$(grep -c 'fileSystemId' "$ROOT/charts/onelens-agent/values.yaml" || true)
assert_gt "$efs_fsid" "0" "values.yaml has efs.fileSystemId"

# globalvalues.yaml must have matching efs section
efs_global=$(grep -c 'efs:' "$ROOT/globalvalues.yaml" || true)
assert_gt "$efs_global" "0" "globalvalues.yaml has efs section"

# install.sh must accept EFS_FILESYSTEM_ID and set efs.csi.aws.com provisioner
efs_install=$(grep -c 'EFS_FILESYSTEM_ID' "$ROOT/install.sh" || true)
assert_gt "$efs_install" "0" "install.sh accepts EFS_FILESYSTEM_ID env var"

efs_provisioner=$(grep -c 'efs.csi.aws.com' "$ROOT/install.sh" || true)
assert_gt "$efs_provisioner" "0" "install.sh sets efs.csi.aws.com provisioner"

###############################################################################
# Test 9: Azure Files support in values and install.sh
###############################################################################
# values.yaml must have azureFiles section
azfiles_values=$(grep -c 'azureFiles:' "$ROOT/charts/onelens-agent/values.yaml" || true)
assert_gt "$azfiles_values" "0" "values.yaml has azureFiles section"

# globalvalues.yaml must have matching azureFiles section
azfiles_global=$(grep -c 'azureFiles:' "$ROOT/globalvalues.yaml" || true)
assert_gt "$azfiles_global" "0" "globalvalues.yaml has azureFiles section"

# install.sh must accept AZURE_FILES_ENABLED and set file.csi.azure.com provisioner
azfiles_install=$(grep -c 'AZURE_FILES_ENABLED' "$ROOT/install.sh" || true)
assert_gt "$azfiles_install" "0" "install.sh accepts AZURE_FILES_ENABLED env var"

azfiles_provisioner=$(grep -c 'file.csi.azure.com' "$ROOT/install.sh" || true)
assert_gt "$azfiles_provisioner" "0" "install.sh sets file.csi.azure.com provisioner"

###############################################################################
# Test 10: Retention rendered in prometheus args
###############################################################################
select_retention_tier 200
RENDERED_RET=$(helm template test-release onelens/onelens-agent \
    --version "$CHART_VERSION" \
    --set-string prometheus.server.retention="$PROMETHEUS_RETENTION" \
    --set-string prometheus.server.retentionSize="$PROMETHEUS_RETENTION_SIZE" \
    2>/dev/null)

ret_args=$(echo "$RENDERED_RET" | grep 'storage.tsdb.retention' || true)
assert_contains "$ret_args" "retention.time=$PROMETHEUS_RETENTION" "retention duration in prometheus args"
assert_contains "$ret_args" "retention.size=$PROMETHEUS_RETENTION_SIZE" "retention size in prometheus args"

test_summary
exit $?
