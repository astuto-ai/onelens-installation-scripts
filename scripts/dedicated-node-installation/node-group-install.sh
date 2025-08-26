#!/bin/bash
set -e

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
if [[ "$INITIAL_CONFIRM" != "yes" ]]; then
  echo "Aborted by user."
  exit 0
fi

echo "Proceeding with subnet discovery..."

ROLE_PREFIX="Onelens"
MAX_ROLE_LEN=64

# ---------- IAM Role Name (trim if needed) ----------
ROLE_BASE="${ROLE_PREFIX}-${CLUSTER_NAME}-${REGION}"
if [ ${#ROLE_BASE} -gt $MAX_ROLE_LEN ]; then
  EXTRA_LEN=$((MAX_ROLE_LEN - ${#ROLE_PREFIX} - 1 - ${#REGION}))
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
SUBNET_IDS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.resourcesVpcConfig.subnetIds" --output text)

echo ""
echo "Available Subnets:"
echo "================================================================================================================"
printf "%-6s %-40s %-20s %-10s %-15s\n" "Index" "Subnet Name" "CIDR Range" "Type" "AZ"
echo "================================================================================================================"

SUBNET_INDEX=1
SUBNET_ARRAY=()
for SUBNET_ID in $SUBNET_IDS; do
  # Get subnet info separately to avoid parsing issues
  SUBNET_NAME=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" --query "Subnets[0].Tags[?Key=='Name'].Value|[0]" --output text)
  CIDR_RANGE=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" --query "Subnets[0].CidrBlock" --output text)
  IS_PUBLIC=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" --query "Subnets[0].MapPublicIpOnLaunch" --output text)
  AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" --query "Subnets[0].AvailabilityZone" --output text)
  
  # Set subnet type
  if [[ "$IS_PUBLIC" == "True" ]]; then
    SUBNET_TYPE_DISPLAY="Public"
  else
    SUBNET_TYPE_DISPLAY="Private"
  fi
  
  # Handle cases where subnet name might be empty
  if [[ -z "$SUBNET_NAME" || "$SUBNET_NAME" == "None" ]]; then
    SUBNET_NAME="$SUBNET_ID"
  fi
  
  # Clean up any extra whitespace and ensure proper formatting
  SUBNET_NAME=$(echo "$SUBNET_NAME" | xargs)
  CIDR_RANGE=$(echo "$CIDR_RANGE" | xargs)
  AZ=$(echo "$AZ" | xargs)
  
  printf "%-6s %-40s %-20s %-10s %-15s\n" "$SUBNET_INDEX" "$SUBNET_NAME" "$CIDR_RANGE" "$SUBNET_TYPE_DISPLAY" "$AZ"
  
  # Store subnet info in array for later use
  SUBNET_ARRAY+=("$SUBNET_ID:$SUBNET_TYPE_DISPLAY:$CIDR_RANGE:$AZ")
  
  SUBNET_INDEX=$((SUBNET_INDEX + 1))
done
echo "================================================================================================================"

# ---------- Subnet selection ----------
echo ""
echo "Please select a subnet for your nodegroup:"
read -p "Enter subnet index (1-$((SUBNET_INDEX-1))): " SELECTED_INDEX

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

echo ""
echo "Selected Subnet Details:"
echo "  ID: $SELECTED_SUBNET_ID"
echo "  Name: $(aws ec2 describe-subnets --subnet-ids "$SELECTED_SUBNET_ID" --region "$REGION" --query "Subnets[0].Tags[?Key=='Name'].Value|[0]" --output text | sed 's/None//' | sed 's/^[[:space:]]*//')"
echo "  CIDR: $SELECTED_SUBNET_CIDR"
echo "  Type: $SELECTED_SUBNET_TYPE"
echo "  AZ: $SELECTED_SUBNET_AZ"

# Update SUBNET_TYPE variable based on selection
if [[ "$SELECTED_SUBNET_TYPE" == "Public" ]]; then
  SUBNET_TYPE="public"
else
  SUBNET_TYPE="private"
fi

echo ""
echo "Updated configuration:"
echo "  Subnet Type: $SUBNET_TYPE (based on selection)"

# ---------- Compute Configuration ----------
echo ""
echo "================================================="
echo "Compute Configuration:"
echo "================================================="

# ---------- Fetch number of pods ----------
echo "Counting pods in cluster $CLUSTER_NAME..."
NUM_PODS=$(kubectl get pods --all-namespaces --no-headers | wc -l | tr -d '[:space:]')
echo "Detected Pods: $NUM_PODS"

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
echo "  AMI Type: $AMI_TYPE"

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
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted by user."
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

echo "Waiting for nodegroup $NODEGROUP_NAME to become ACTIVE..."
aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --region "$REGION"

echo "✅ Nodegroup $NODEGROUP_NAME is now ACTIVE in $SUBNET_TYPE subnet $SELECTED_SUBNET_ID with instance type $INSTANCE_TYPE and AMI type $AMI_TYPE."
echo "  Subnet Details:"
echo "    ID: $SELECTED_SUBNET_ID"
echo "    CIDR: $SELECTED_SUBNET_CIDR"
echo "    AZ: $SELECTED_SUBNET_AZ"
