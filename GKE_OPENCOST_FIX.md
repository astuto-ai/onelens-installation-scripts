# Fix OpenCost Exporter GCP API Key Issue

## Error
```
panic: Supply a GCP Key to start getting data
```

## Solution Options

### Option 1: Provide GCP API Key (Quick Fix)

Update the Helm release with a GCP API key:

```bash
# Get or create a GCP API key
# 1. Go to: https://console.cloud.google.com/apis/credentials
# 2. Create API Key or use existing one
# 3. Enable "Cloud Billing API" for the key

# Update the Helm release
helm upgrade onelens-agent onelens/onelens-agent \
  -n onelens-agent \
  -f globalvalues.yaml \
  --set prometheus-opencost-exporter.opencost.exporter.cloudProviderApiKey="YOUR_GCP_API_KEY"
```

### Option 2: Use Workload Identity (Recommended for Production)

Configure Workload Identity so OpenCost can use the node's service account:

```bash
# 1. Enable Workload Identity on your GKE cluster (if not already enabled)
gcloud container clusters update CLUSTER_NAME \
  --workload-pool=PROJECT_ID.svc.id.goog \
  --zone=ZONE

# 2. Create a service account for OpenCost
gcloud iam service-accounts create opencost-sa \
  --display-name="OpenCost Service Account" \
  --project=PROJECT_ID

# 3. Grant required permissions
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:opencost-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/billing.viewer"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:opencost-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

# 4. Bind Kubernetes service account to GCP service account
gcloud iam service-accounts add-iam-policy-binding \
  opencost-sa@PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:PROJECT_ID.svc.id.goog[onelens-agent/onelens-agent-prometheus-opencost-exporter]"

# 5. Annotate the Kubernetes service account
kubectl annotate serviceaccount onelens-agent-prometheus-opencost-exporter \
  -n onelens-agent \
  iam.gke.io/gcp-service-account=opencost-sa@PROJECT_ID.iam.gserviceaccount.com

# 6. Restart the pod
kubectl delete pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent
```

### Option 3: Disable Cloud Provider Integration (If Not Needed)

If you don't need GCP pricing data, you can configure OpenCost to work without it:

```bash
# Update values to disable cloud provider requirement
helm upgrade onelens-agent onelens/onelens-agent \
  -n onelens-agent \
  -f globalvalues.yaml \
  --set prometheus-opencost-exporter.opencost.exporter.cloudProviderApiKey="" \
  --set prometheus-opencost-exporter.opencost.exporter.extraEnv.GCP_SERVICE_KEY_NAME=""
```

However, this may limit cost calculation accuracy.

## Quick Fix Command

```bash
# Replace YOUR_GCP_API_KEY with your actual API key
helm upgrade onelens-agent onelens/onelens-agent \
  -n onelens-agent \
  -f globalvalues.yaml \
  --set prometheus-opencost-exporter.opencost.exporter.cloudProviderApiKey="YOUR_GCP_API_KEY" \
  --reuse-values
```

## Verify Fix

```bash
# Check pod status
kubectl get pods -n onelens-agent | grep opencost

# Check logs
kubectl logs -f deployment/onelens-agent-prometheus-opencost-exporter -n onelens-agent

# Should see successful startup without panic
```

