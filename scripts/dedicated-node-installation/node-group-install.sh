#!/bin/bash
set -e

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <cluster-name> <region>"
  exit 1
fi

CLUSTER_NAME=$1
REGION=$2
NODEGROUP_NAME="onelens-nodegroup-single-az"

# Fetch AWS account ID dynamically
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="Onelens-AmazonEKSNodegroupRole"

# Create IAM role with trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

echo "Creating role $ROLE_NAME"

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" || echo "Role may already exist"

echo "Attaching policies to role $ROLE_NAME"

# Attach AWS managed policies
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# Fetch cluster VPC config
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.resourcesVpcConfig.subnetIds" --output text)

# Pick a unique public subnet if available, else fallback to first subnet
SELECTED_SUBNET=""
for SUBNET_ID in $SUBNET_IDS; do
  MAP_PUBLIC_IP=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" --query "Subnets[0].MapPublicIpOnLaunch" --output text)
  if [ "$MAP_PUBLIC_IP" = "True" ]; then
    SELECTED_SUBNET="$SUBNET_ID"
    break
  fi
done

if [ -z "$SELECTED_SUBNET" ]; then
  echo "No public subnet found, using first available subnet"
  SELECTED_SUBNET=$(echo $SUBNET_IDS | awk '{print $1}')
fi

echo "Using subnet $SELECTED_SUBNET"

# Fetch number of pods in the cluster automatically
NUM_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
echo "Detected $NUM_PODS running pods"

# Determine instance type based on pod count
if [ "$NUM_PODS" -lt 100 ]; then
  INSTANCE_TYPE="t2.small"
elif [ "$NUM_PODS" -lt 500 ]; then
  INSTANCE_TYPE="t2.medium"
elif [ "$NUM_PODS" -lt 1500 ]; then
  INSTANCE_TYPE="t2.large"
elif [ "$NUM_PODS" -le 2000 ]; then
  INSTANCE_TYPE="t2.xlarge"
else
  echo "Pod count too high, adjust instance selection logic"
  exit 1
fi

echo "Using instance type $INSTANCE_TYPE"

# Create nodegroup in single AZ using custom SG
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-role "$ROLE_ARN" \
  --subnets "$SELECTED_SUBNET" \
  --instance-types "$INSTANCE_TYPE" \
  --scaling-config minSize=1,maxSize=1,desiredSize=1 \
  --taints '[{"key":"onelens-workload","value":"agent","effect":"NO_SCHEDULE"}]' \
  --labels '{"onelens-workload":"agent"}' \
  --region "$REGION" \
  --nodegroup-name "$NODEGROUP_NAME" 

echo "Nodegroup $NODEGROUP_NAME creation started in subnet $SELECTED_SUBNET with instance type $INSTANCE_TYPE"