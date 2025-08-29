#!/bin/bash
set -e

# ---------- Loading animation function ----------
show_loading() {
    local message="$1"
    local pid="$2"
    local delay=0.5
    local spinstr='|/-\'
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r[%c] %s" "$spinstr" "$message"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r[✓] %s\n" "$message"
}

# ---------- Usage check ----------
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <cluster-name> <region>"
  exit 1
fi

CLUSTER_NAME=$1
REGION=$2
NODEGROUP_NAME="onelens-nodegroup"

# ---------- Fetch AWS account ID ----------

echo "Fetching AWS account ID..." 
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Detected AWS Account ID: $ACCOUNT_ID"

# ---------- Initial confirmation ----------
echo ""
echo "================================================="
echo "Initial Configuration:"
echo "AWS Account ID  : $ACCOUNT_ID"
echo "Cluster Name    : $CLUSTER_NAME"
echo "Region          : $REGION"
echo "================================================="

read -p "Proceed with this AWS account and cluster? (yes/no): " INITIAL_CONFIRM
if [[ "$INITIAL_CONFIRM" == "no" ]]; then
  echo "please rerun the script with right aws credentials and access to the eks cluster"
  exit 0
fi

echo "Proceeding with subnet discovery..."

ROLE_PREFIX="onelens"
MAX_ROLE_LEN=64

# ---------- IAM Role Name (trim if needed) ----------
ROLE_BASE="${ROLE_PREFIX}-${CLUSTER_NAME}-${REGION}"
if [ ${#ROLE_BASE} -gt $MAX_ROLE_LEN ]; then
  EXTRA_LEN=$((MAX_ROLE_LEN - ${#ROLE_PREFIX} - 2 - ${#REGION}))
  TRIMMED_CLUSTER=$(echo "$CLUSTER_NAME" | cut -c1-$EXTRA_LEN)
  ROLE_NAME="${ROLE_PREFIX}-${TRIMMED_CLUSTER}-${REGION}"
else
  ROLE_NAME="$ROLE_BASE"
fi
echo "Computed IAM Role Name: $ROLE_NAME"

# ---------- Defaults ----------
SUBNET_TYPE="public"
AMI_TYPE="AL2023_ARM_64_STANDARD"

# ---------- Fetch and display subnet table ----------
echo "Fetching VPC subnets for cluster $CLUSTER_NAME..."
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text)

echo ""
echo "Available Subnets:"
echo "================================================================================================================"
printf "%-6s %-40s %-20s %-10s %-15s\n" "Index" "Subnet Name" "CIDR Range" "Type" "AZ"
echo "================================================================================================================"

SUBNET_INDEX=1
SUBNET_ARRAY=()

# Fetch all subnet details in one call
SUBNET_DETAILS=$(aws ec2 describe-subnets \
  --subnet-ids $SUBNET_IDS \
  --region "$REGION" \
  --query 'Subnets[*].[SubnetId,Tags[?Key==`Name`].Value | [0],CidrBlock,MapPublicIpOnLaunch,AvailabilityZone]' \
  --output text)

while IFS=$'\t' read -r SUBNET_ID SUBNET_NAME CIDR_RANGE IS_PUBLIC AZ; do
  # Handle cases where subnet name might be empty
  if [[ -z "$SUBNET_NAME" || "$SUBNET_NAME" == "None" ]]; then
    SUBNET_NAME="$SUBNET_ID"
  fi

  # Determine subnet type
  if [[ "$IS_PUBLIC" == "True" ]]; then
    SUBNET_TYPE_DISPLAY="Public"
  else
    SUBNET_TYPE_DISPLAY="Private"
  fi

  printf "%-6s %-40s %-20s %-10s %-15s\n" "$SUBNET_INDEX" "$SUBNET_NAME" "$CIDR_RANGE" "$SUBNET_TYPE_DISPLAY" "$AZ"

  # Store subnet info in array for later use
  SUBNET_ARRAY+=("$SUBNET_ID:$SUBNET_TYPE_DISPLAY:$CIDR_RANGE:$AZ:$SUBNET_NAME")

  SUBNET_INDEX=$((SUBNET_INDEX + 1))
done <<< "$SUBNET_DETAILS"

echo "================================================================================================================"

# ---------- Subnet selection ----------
echo ""
echo "Please select a subnet for your nodegroup:"
read -p "Enter subnet index (1-$((SUBNET_INDEX-1))) or press Enter for first subnet: " SELECTED_INDEX

# If user just presses Enter, select first subnet
if [ -z "$SELECTED_INDEX" ]; then
  SELECTED_INDEX=1
  echo "✅ Auto-selected first subnet (index 1)"
fi

# Validate input
if ! [[ "$SELECTED_INDEX" =~ ^[0-9]+$ ]] || [ "$SELECTED_INDEX" -lt 1 ] || [ "$SELECTED_INDEX" -gt $((SUBNET_INDEX-1)) ]; then
  echo "❌ Invalid subnet index. Please run the script again and select a valid index."
  exit 1
fi

# Get selected subnet details
SELECTED_SUBNET_INFO=${SUBNET_ARRAY[$((SELECTED_INDEX-1))]}
SELECTED_SUBNET_ID=$(echo "$SELECTED_SUBNET_INFO" | cut -d: -f1)
SELECTED_SUBNET_TYPE=$(echo "$SELECTED_SUBNET_INFO" | cut -d: -f2)
SELECTED_SUBNET_CIDR=$(echo "$SELECTED_SUBNET_INFO" | cut -d: -f3)
SELECTED_SUBNET_AZ=$(echo "$SELECTED_SUBNET_INFO" | cut -d: -f4)
SELECTED_SUBNET_NAME=$(echo "$SELECTED_SUBNET_INFO" | cut -d: -f5)

echo ""
echo "Selected Subnet Details:"
echo "  ID:   $SELECTED_SUBNET_ID"
echo "  Name: $SELECTED_SUBNET_NAME"
echo "  CIDR: $SELECTED_SUBNET_CIDR"
echo "  Type: $SELECTED_SUBNET_TYPE"
echo "  AZ:   $SELECTED_SUBNET_AZ"

# Update SUBNET_TYPE variable based on selection
if [[ "$SELECTED_SUBNET_TYPE" == "Public" ]]; then
  SUBNET_TYPE="public"
else
  SUBNET_TYPE="private"
fi

# ---------- Compute Configuration ----------
echo ""
echo "================================================="
echo "Compute Configuration:"
echo "================================================="

# ---------- Fetch number of pods ----------
echo "Counting pods in cluster $CLUSTER_NAME..."
NUM_RUNNING=$(kubectl get pods --field-selector=status.phase=Running --all-namespaces | wc -l | tr -d '[:space:]')
NUM_PENDING=$(kubectl get pods --field-selector=status.phase=Pending --all-namespaces | wc -l | tr -d '[:space:]')
NUM_PODS=$((NUM_RUNNING + NUM_PENDING))
## add 20% buffer to the pods count
NUM_PODS=$(((NUM_PODS * 12 + 9) / 10))
echo "Detected Pods with additional 20% buffer for future considerations: $NUM_PODS"

read -p "Type Enter to continue with the detected pods count ($NUM_PODS) or modify the count: " MODIFY_PODS

if [[ "$MODIFY_PODS" =~ ^[0-9]+$ ]]; then
  NUM_PODS=$MODIFY_PODS
fi

if ! [[ "$NUM_PODS" =~ ^[0-9]+$ ]]; then
  echo "Invalid input. Please enter a positive number."
  exit 1
fi

echo "Pod count set to: $NUM_PODS"


# ---------- Instance type selection ----------
if [ "$NUM_PODS" -lt 100 ]; then
  INSTANCE_TYPE="t4g.small"
elif [ "$NUM_PODS" -lt 500 ]; then
  INSTANCE_TYPE="t4g.medium"
elif [ "$NUM_PODS" -lt 1500 ]; then
  INSTANCE_TYPE="t4g.large"
elif [ "$NUM_PODS" -le 2000 ]; then
  INSTANCE_TYPE="t4g.xlarge"
else
  INSTANCE_TYPE="t4g.2xlarge"
fi
echo "Recommended Instance Type: $INSTANCE_TYPE"

# ---------- AMI Type ----------
echo "Default AMI Type: $AMI_TYPE"

echo "================================================="

# ---------- User Input for Compute Configuration ----------
echo ""
echo "Please configure compute settings:"
read -p "Enter Instance Type [$INSTANCE_TYPE] for $NUM_PODS pods: " INPUT_INSTANCE_TYPE
if [[ -n "$INPUT_INSTANCE_TYPE" ]]; then
  INSTANCE_TYPE="$INPUT_INSTANCE_TYPE"
fi

read -p "Enter AMI Type [$AMI_TYPE]: " INPUT_AMI_TYPE
if [[ -n "$INPUT_AMI_TYPE" ]]; then
  AMI_TYPE="$INPUT_AMI_TYPE"
fi

echo ""
echo "Final Compute Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  AMI Type:      $AMI_TYPE"

# ---------- Show detected config ----------
echo "================================================="
echo "Configuration detected:"
echo "AWS Account ID  : $ACCOUNT_ID"
echo "Cluster Name    : $CLUSTER_NAME"
echo "Region          : $REGION"
echo "Nodegroup Name  : $NODEGROUP_NAME"
echo "IAM Role Name   : $ROLE_NAME"
echo "Detected Pods   : $NUM_PODS"
echo "Subnet ID       : $SELECTED_SUBNET_ID"
echo "Instance Type   : $INSTANCE_TYPE"
echo "AMI Type        : $AMI_TYPE"
echo "================================================="

# ---------- Ask for confirmation ----------
read -p "Proceed with this configuration? (yes/no): " CONFIRM
if [[ "$CONFIRM" == "no" ]]; then
  echo "please rerun the script with right nodegroup configuration"
  exit 0
fi

echo "Proceeding with nodegroup creation..."

# ---------- Create IAM role ----------
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

echo "Creating IAM role $ROLE_NAME..."
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" || echo "Role may already exist."

echo "Attaching IAM policies to role $ROLE_NAME..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
echo "Role ARN: $ROLE_ARN"

# ---------- Create nodegroup ----------
echo "Creating nodegroup $NODEGROUP_NAME in cluster $CLUSTER_NAME..."
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-role "$ROLE_ARN" \
  --subnets "$SELECTED_SUBNET_ID" \
  --instance-types "$INSTANCE_TYPE" \
  --scaling-config minSize=1,maxSize=1,desiredSize=1 \
  --taints '[{"key":"onelens-workload","value":"agent","effect":"NO_SCHEDULE"}]' \
  --labels '{"onelens-workload":"agent"}' \
  --region "$REGION" \
  --ami-type "$AMI_TYPE"

aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --region "$REGION" &
WAIT_PID=$!

show_loading "Waiting for nodegroup $NODEGROUP_NAME to become ACTIVE..." "$WAIT_PID"
wait $WAIT_PID

echo "✅ Nodegroup $NODEGROUP_NAME is now ACTIVE in $SUBNET_TYPE subnet $SELECTED_SUBNET_ID with instance type $INSTANCE_TYPE and AMI type $AMI_TYPE."


echo ""
echo "✅ Your agent can now be installed with the following Helm commands:"
echo "======================================================================"
cat <<EOF
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
helm repo update

helm upgrade --install onelensdeployer onelens/onelensdeployer -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=$CLUSTER_NAME \\
  --set job.env.REGION=$REGION \\
  --set-string job.env.ACCOUNT=$ACCOUNT_ID \\
  --set job.env.REGISTRATION_TOKEN="<registration-token>" \\
  --set job.env.NODE_SELECTOR_KEY=onelens-workload \\
  --set job.env.NODE_SELECTOR_VALUE=agent \\
  --set job.env.TOLERATION_KEY=onelens-workload \\
  --set job.env.TOLERATION_VALUE=agent \\
  --set job.env.TOLERATION_OPERATOR=Equal \\
  --set job.env.TOLERATION_EFFECT=NoSchedule \\
  --set job.nodeSelector.onelens-workload=agent \\
  --set 'job.tolerations[0].key=onelens-workload' \\
  --set 'job.tolerations[0].operator=Equal' \\
  --set 'job.tolerations[0].value=agent' \\
  --set 'job.tolerations[0].effect=NoSchedule'
EOF
echo "======================================================================"