#!/bin/bash

set -e  # Exit on any error

# Check for the required argument
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 -var-file=<tfvars-file>"
    exit 1
fi

# Parse argument
if [[ "$1" == "-var-file" ]]; then
    TFVARS_FILE=$2
elif [[ "$1" =~ ^-var-file=(.*)$ ]]; then
    TFVARS_FILE=${BASH_REMATCH[1]}
else
    echo "Error: Invalid argument format.  Usage: $0 -var-file=<tfvars-file>"
    exit 1
fi

TFVARS_FILE=$(basename $TFVARS_FILE)

# Find the terraform directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_DIR=$(dirname "$SCRIPT_DIR")
TF_DIR="$REPO_DIR/terraform"
cd $TF_DIR


# Ensure the tfvars file exists
if [[ ! -f "environment/$TFVARS_FILE" ]]; then
    echo "Error: $TFVARS_FILE does not exist."
    exit 1
else
    TFVARS_FILE="environment/$TFVARS_FILE"
fi


# Extract env_name from the selected file
ENV_NAME=$(awk -F'"' '/env_name/ {print $2}' "$TFVARS_FILE" | xargs)

if [[ -z "$ENV_NAME" ]]; then
    echo "❌ Could not extract env_name from $TFVARS_FILE. Ensure the file is correctly formatted."
    exit 1
fi

echo "✅ Selected environment: $ENV_NAME (from $(basename "$TFVARS_FILE"))"

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


# Run Terraform destroy commands
echo "🏃 1 of 3 - Running terraform destroy on kubernetes_deployment_v1..."

terraform destroy \
    -auto-approve \
    -target=kubernetes_deployment_v1.guestbook_app_deployment \
    -var-file=$TFVARS_FILE

echo "✅ kubernetes_deployment_v1 deleted"

echo "🏃 2 of 3 - Running terraform destroy on kubernetes_persistent_volume_claim_v1..."

terraform destroy \
    -auto-approve \
    -target=kubernetes_persistent_volume_claim_v1.ebs_pvc \
    -var-file=$TFVARS_FILE

echo "✅ kubernetes_persistent_volume_claim_v1 deleted"

echo "🏃 3 of 3 - Running terraform destroy on all remaining resources..."

terraform destroy \
    -auto-approve \
    -var-file=$TFVARS_FILE

echo "✅✅✅ All resources deleted"