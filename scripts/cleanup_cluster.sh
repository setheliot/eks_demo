#!/bin/bash

set -e  # Exit on any error

# Check for the required argument
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [-var-file=<tfvars-file>] [castai]"
    echo "  castai    Use deploy-castai directory and destroy CastAI resources first"
    exit 1
fi

# Parse arguments
CASTAI_MODE=false
TFVARS_FILE=""
TFVARS_FILE_ORIG=""
CASTAI_API_KEY=""

for arg in "$@"; do
    if [[ "$arg" == "castai" ]]; then
        CASTAI_MODE=true
    elif [[ "$arg" == "-var-file" ]]; then
        # Handle -var-file <value> format (next iteration will catch value)
        continue
    elif [[ "$arg" =~ ^-var-file=(.*)$ ]]; then
        TFVARS_FILE_ORIG=${BASH_REMATCH[1]}
    elif [[ "$arg" =~ ^-castai-api-key=(.*)$ ]]; then
        CASTAI_API_KEY=${BASH_REMATCH[1]}
    elif [[ -z "$TFVARS_FILE_ORIG" && ! "$arg" =~ ^- ]]; then
        # Assume it's the tfvars file if -var-file was the previous arg
        TFVARS_FILE_ORIG="$arg"
    fi
done

if [[ -z "$TFVARS_FILE_ORIG" ]]; then
    echo "Error: -var-file is required"
    echo "Usage: $0 -var-file=<tfvars-file> [castai]"
    exit 1
fi

# Auto-detect CastAI mode from path if not explicitly set
if [[ "$CASTAI_MODE" == false && "$TFVARS_FILE_ORIG" == *"deploy-castai"* ]]; then
    CASTAI_MODE=true
    echo "🎯 Auto-detected CastAI mode from path"
fi

TFVARS_FILE=$(basename $TFVARS_FILE_ORIG)

# Find the terraform directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_DIR=$(dirname "$SCRIPT_DIR")

if [[ "$CASTAI_MODE" == true ]]; then
    TF_DIR="$REPO_DIR/terraform/deploy-castai"
    echo "🎯 CastAI mode enabled - using deploy-castai directory"

    # Prompt for CastAI API key if not provided
    if [[ -z "$CASTAI_API_KEY" ]]; then
        read -r -p "Enter CastAI API key (or press Enter to use 'dummy' for destroy): " CASTAI_API_KEY
        if [[ -z "$CASTAI_API_KEY" ]]; then
            CASTAI_API_KEY="dummy"
        fi
    fi
else
    TF_DIR="$REPO_DIR/terraform/deploy"
fi

cd $TF_DIR


# Ensure the tfvars file exists
if [[ ! -f "environment/$TFVARS_FILE" ]]; then
    echo "Error: $TFVARS_FILE does not exist."
    exit 1
else
    TFVARS_FILE="environment/$TFVARS_FILE"
fi


# Extract env_name and aws_region from the selected file
ENV_NAME=$(awk -F'"' '/env_name/ {print $2}' "$TFVARS_FILE" | xargs)
AWS_REGION=$(awk -F'"' '/aws_region/ {print $2}' "$TFVARS_FILE" | xargs)

if [[ -z "$ENV_NAME" ]]; then
    echo "❌ Could not extract env_name from $TFVARS_FILE. Ensure the file is correctly formatted."
    exit 1
fi

if [[ -z "$AWS_REGION" ]]; then
    echo "❌ Could not extract aws_region from $TFVARS_FILE. Ensure the file is correctly formatted."
    exit 1
fi

# Determine cluster name based on mode
if [[ "$CASTAI_MODE" == true ]]; then
    CLUSTER_NAME="castai-demo-${ENV_NAME}-cluster"
else
    CLUSTER_NAME="eks-demo-${ENV_NAME}-cluster"
fi

# Get AWS Account ID using STS
AWS_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)

# Check if AWS_ACCOUNT is empty (invalid credentials)
if [[ -z "$AWS_ACCOUNT" || "$AWS_ACCOUNT" == "None" ]]; then
    echo "There are no valid AWS credentials. Please update your AWS credentials to target the correct AWS account."
    exit 1
fi

# Prompt the user for confirmation
echo "✅ Selected environment: [$ENV_NAME] (from [$(basename "$TFVARS_FILE")])"
if [[ "$CASTAI_MODE" == true ]]; then
    echo "🎯 CastAI mode: Will destroy CastAI resources first, then EKS cluster"
fi
echo "💣 Your EKS cluster in AWS account [${AWS_ACCOUNT}] will be DESTROYED"
echo "😇 Is that what you want?\n"
read -r -p "Proceed? [y/n]: " response

# Check if response is "y" or "yes"
if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "👋 Good bye!"
    exit 1
fi

echo "🏃 Running terraform init..."
if ! terraform init 2> terraform_init_err.log; then
    if grep -q "Error refreshing state: state data in S3 does not have the expected content." terraform_init_err.log; then
        echo "👍 Ignoring known state data error and continuing..."
    else
        echo "❌ Unexpected error occurred. Exiting."
        exit 1
    fi 
fi

if [ -f terraform_init_err.log ]; then
    rm terraform_init_err.log
fi

# Check the current Terraform workspace
CURRENT_WS=$(terraform workspace show 2>/dev/null)

if [[ "$CURRENT_WS" != "$ENV_NAME" ]]; then
    echo "🔄 Switching to Terraform workspace: $ENV_NAME"
    
    # Check if the workspace exists
    if ! terraform workspace select "$ENV_NAME" 2>/dev/null; then
        echo "❌ Workspace '$ENV_NAME' does not exist."
    fi
fi

echo "✅ Using Terraform workspace [$ENV_NAME]"

# Update kubeconfig to point to the correct cluster
echo "🔧 Updating kubeconfig for cluster $CLUSTER_NAME in $AWS_REGION..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" 2>/dev/null || echo "⚠️  Could not update kubeconfig (cluster may already be deleted)"

# Build base terraform var args
TF_VAR_ARGS="-var-file=$TFVARS_FILE"
if [[ "$CASTAI_MODE" == true ]]; then
    TF_VAR_ARGS="$TF_VAR_ARGS -var=castai_api_key=$CASTAI_API_KEY"
fi

# Track step numbers
STEP=1

if [[ "$CASTAI_MODE" == true ]]; then
    TOTAL_STEPS=8
else
    TOTAL_STEPS=4
fi

# CastAI-specific destroy steps (run first, in reverse dependency order)
if [[ "$CASTAI_MODE" == true ]]; then
    echo "🏃 $STEP of $TOTAL_STEPS - Destroying CastAI cluster module..."
    terraform destroy \
        -auto-approve \
        -target=null_resource.scale_down_managed_nodes \
        -target=module.castai_eks_cluster \
        $TF_VAR_ARGS || echo "⚠️  Some CastAI resources may have already been removed"
    echo "✅ CastAI cluster module destroyed"
    ((STEP++))

    echo "🏃 $STEP of $TOTAL_STEPS - Destroying CastAI node IAM resources..."
    terraform destroy \
        -auto-approve \
        -target=aws_eks_access_entry.castai_node_access \
        -target=aws_iam_role_policy_attachment.castai_node_alb_controller \
        -target=aws_iam_role_policy_attachment.castai_node_ebs \
        -target=aws_iam_role_policy_attachment.castai_node_ssm \
        -target=aws_iam_role_policy_attachment.castai_node_cni \
        -target=aws_iam_role_policy_attachment.castai_node_ecr \
        -target=aws_iam_role_policy_attachment.castai_node_eks_worker \
        -target=aws_iam_instance_profile.castai_node_profile \
        -target=aws_iam_role.castai_node_role \
        $TF_VAR_ARGS || echo "⚠️  Some IAM resources may have already been removed"
    echo "✅ CastAI node IAM resources destroyed"
    ((STEP++))

    echo "🏃 $STEP of $TOTAL_STEPS - Destroying CastAI IAM role module..."
    terraform destroy \
        -auto-approve \
        -target=module.castai_eks_role_iam \
        $TF_VAR_ARGS || echo "⚠️  CastAI IAM role module may have already been removed"
    echo "✅ CastAI IAM role module destroyed"
    ((STEP++))

    echo "🏃 $STEP of $TOTAL_STEPS - Destroying CastAI cluster registration..."
    terraform destroy \
        -auto-approve \
        -target=castai_eks_user_arn.castai_user_arn \
        -target=castai_eks_clusterid.cluster_id \
        $TF_VAR_ARGS || echo "⚠️  CastAI registration may have already been removed"
    echo "✅ CastAI cluster registration destroyed"
    ((STEP++))
fi

# Run Terraform destroy commands
echo "🏃 $STEP of $TOTAL_STEPS - Running terraform destroy on kubernetes_deployment_v1..."

terraform destroy \
    -auto-approve \
    -target=kubernetes_deployment_v1.guestbook_app_deployment \
    $TF_VAR_ARGS

echo "✅ kubernetes_deployment_v1 deleted"
((STEP++))


echo "🏃 $STEP of $TOTAL_STEPS - Running terraform destroy on kubernetes_persistent_volume_claim_v1..."

terraform destroy \
    -auto-approve \
    -target=kubernetes_persistent_volume_claim_v1.ebs_pvc \
    $TF_VAR_ARGS || echo "⚠️  PVC may have already been removed"

echo "✅ kubernetes_persistent_volume_claim_v1 deleted"
((STEP++))


echo "🏃 $STEP of $TOTAL_STEPS - Running terraform destroy on kubernetes_ingress_v1..."

# The AWS LB Controller webhook can block ingress deletion if the controller is unhealthy.
# Proactively remove the webhook and finalizers to prevent hangs.
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || echo "  (webhook already removed)"

for ingress in $(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ns=$(echo "$ingress" | cut -d'/' -f1)
    name=$(echo "$ingress" | cut -d'/' -f2)
    echo "  Removing finalizers from ingress $ns/$name"
    kubectl patch ingress "$name" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done

terraform destroy \
    -auto-approve \
    -target=module.alb[0].kubernetes_ingress_v1.ingress_alb \
    $TF_VAR_ARGS || echo "⚠️  Ingress may have already been removed"

echo "✅ kubernetes_ingress_v1 deleted"
((STEP++))


echo "🏃 $STEP of $TOTAL_STEPS - Running terraform destroy on all remaining resources..."

terraform destroy \
    -auto-approve \
    $TF_VAR_ARGS

echo "✅✅✅ All resources deleted"