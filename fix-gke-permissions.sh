#!/bin/bash
# Script to find and fix GKE node service account permissions

set -e

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Could not get project ID. Make sure you're authenticated with gcloud."
    exit 1
fi

echo "Project ID: $PROJECT_ID"
echo ""

# Method 1: Try to get from node pool
echo "=== Attempting to find service account from node pool ==="
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | cut -d'_' -f4 2>/dev/null || echo "")
ZONE=$(kubectl config current-context 2>/dev/null | cut -d'_' -f3 2>/dev/null || echo "")

if [ -n "$CLUSTER_NAME" ] && [ -n "$ZONE" ]; then
    echo "Detected cluster: $CLUSTER_NAME in zone: $ZONE"
    
    # Try to get node pool name
    NODE_POOL_NAME=$(gcloud container node-pools list --cluster=$CLUSTER_NAME --zone=$ZONE --format="value(name)" 2>/dev/null | head -1)
    
    if [ -n "$NODE_POOL_NAME" ]; then
        echo "Found node pool: $NODE_POOL_NAME"
        NODE_SA=$(gcloud container node-pools describe $NODE_POOL_NAME \
            --cluster=$CLUSTER_NAME \
            --zone=$ZONE \
            --format="value(config.serviceAccount)" 2>/dev/null || echo "")
        
        if [ -n "$NODE_SA" ]; then
            echo "Found service account from node pool: $NODE_SA"
        fi
    fi
fi

# Method 2: If not found, try default compute service account
if [ -z "$NODE_SA" ]; then
    echo ""
    echo "=== Trying default compute service account ==="
    # Try different formats
    for SA_FORMAT in \
        "${PROJECT_ID}@${PROJECT_ID}.iam.gserviceaccount.com" \
        "${PROJECT_ID}-compute@developer.gserviceaccount.com" \
        "${PROJECT_ID}@compute-system.iam.gserviceaccount.com"; do
        
        if gcloud iam service-accounts describe "$SA_FORMAT" &>/dev/null; then
            NODE_SA="$SA_FORMAT"
            echo "Found existing service account: $NODE_SA"
            break
        fi
    done
fi

# Method 3: List and let user choose
if [ -z "$NODE_SA" ]; then
    echo ""
    echo "=== Listing available service accounts ==="
    echo "Please identify the service account used by your GKE nodes:"
    gcloud iam service-accounts list --format="table(email,displayName)" 2>/dev/null | head -20
    
    echo ""
    echo "Common service account formats:"
    echo "  - ${PROJECT_ID}@${PROJECT_ID}.iam.gserviceaccount.com (default)"
    echo "  - ${PROJECT_ID}-compute@developer.gserviceaccount.com (legacy)"
    echo ""
    read -p "Enter the service account email (or press Enter to use default): " USER_SA
    
    if [ -n "$USER_SA" ]; then
        NODE_SA="$USER_SA"
    else
        # Try the most common format
        NODE_SA="${PROJECT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
        echo "Using default: $NODE_SA"
    fi
fi

# Verify service account exists
if ! gcloud iam service-accounts describe "$NODE_SA" &>/dev/null; then
    echo ""
    echo "Error: Service account '$NODE_SA' does not exist."
    echo ""
    echo "Please create it or use an existing one:"
    echo "  gcloud iam service-accounts create compute-sa --display-name='Compute Service Account'"
    echo ""
    echo "Or find the correct one with:"
    echo "  gcloud iam service-accounts list"
    exit 1
fi

echo ""
echo "=== Granting IAM permissions to: $NODE_SA ==="

# Grant required permissions
echo "Granting roles/compute.instanceAdmin.v1..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/compute.instanceAdmin.v1" \
    --condition=None 2>&1 | grep -v "WARNING" || echo "  (may already have this role)"

echo "Granting roles/iam.serviceAccountUser..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --condition=None 2>&1 | grep -v "WARNING" || echo "  (may already have this role)"

echo ""
echo "=== Verifying permissions ==="
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:${NODE_SA}" \
    --format="table(bindings.role)" 2>/dev/null | grep -E "(compute.instanceAdmin|iam.serviceAccountUser)" || echo "  (checking...)"

echo ""
echo "=== Done! ==="
echo "Permissions granted. Wait 1-2 minutes for propagation, then:"
echo "  1. Delete stuck PVCs: kubectl delete pvc --all -n onelens-agent"
echo "  2. Pods will automatically retry and should succeed"

