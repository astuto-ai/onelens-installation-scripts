#!/bin/bash

set -e

echo "Applying RBAC (Role + RoleBinding) for secrets access...and clusterRole and cluster rolebinding......."

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ibs_patch_onboard_clusterrole
rules:
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles", "clusterrolebindings"]
  verbs: ["get", "list", "watch"]
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ibs_patch_onboard_ClusterRoleBinding
metadata:
  name: helm-cluster-binding
subjects:
- kind: ServiceAccount
  name: onelens-agent-sa
  namespace: onelens-agent
roleRef:
  kind: ClusterRole
  name: helm-cluster-role
  apiGroup: rbac.authorization.k8s.io
EOF

# Create Role for reading secrets
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ibs_patch_onboard_Role
  namespace: onelens-agent
rules:
- apiGroups: [""]
  resources:
    - secrets
    - configmaps
    - services
    - serviceaccounts
    - persistentvolumeclaims
  verbs: ["*"]
- apiGroups: ["apps"]
  resources:
    - deployments
    - replicasets
    - statefulsets
    - daemonsets
  verbs: ["*"]
- apiGroups: ["batch"]
  resources:
    - jobs
    - cronjobs
  verbs: ["*"]
- apiGroups: ["autoscaling"]
  resources:
    - horizontalpodautoscalers
  verbs: ["*"]
- apiGroups: ["policy"]
  resources:
    - poddisruptionbudgets
  verbs: ["*"]
EOF

# Create RoleBinding to bind the Role to the default ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ibs_patch_onboard_RoleBinding
  namespace: onelens-agent
subjects:
- kind: ServiceAccount
  name: onelens-agent-sa
  namespace: onelens-agent
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF

echo "RBAC configured."

# Define the CronJob YAML
cat <<EOF > cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ibs_patch_onboard
  namespace: onelens-agent
spec:
  schedule: "0 2 * * *"  # 2:00 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: onelens-agent-sa 
          containers:
          - name: downloader
            image: ubuntu:22.04
            command:
              - /bin/bash
              - -c
              - |
                echo "Installing prerequisites..."
                apt-get update && apt-get install -y wget curl bash file
                echo "Downloading script..."
                wget -q -O /tmp/ibs_patching.sh https://raw.githubusercontent.com/astuto-ai/onelens-installation-scripts/IBS/ibs_patching.sh || {
                  echo "Download failed!"
                  exit 1
                }
                echo "Download complete. Running script..."
                chmod +x /tmp/ibs_patching.sh
                head -n 10 /tmp/ibs_patching.sh
                file /tmp/ibs_patching.sh
                bash -x /tmp/ibs_patching.sh
          restartPolicy: OnFailure
EOF

echo "Creating Kubernetes CronJob..."i
kubectl apply -f cronjob.yaml
rm cronjob.yaml
echo "CronJob created successfully."

