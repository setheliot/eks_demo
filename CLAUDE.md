# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an educational Terraform project that deploys a demo "guestbook" application on AWS EKS. It demonstrates EKS best practices including VPC setup, managed node groups, AWS Load Balancer Controller, EBS CSI storage, DynamoDB integration, and Secrets Manager with CSI driver.

## Commands

### Deploy the cluster
```bash
cd scripts
./ez_cluster_deploy.sh
```
This interactive script validates AWS credentials, checks backend state, and deploys all resources.

### Tear down the cluster
```bash
cd scripts
./cleanup_cluster.sh -var-file=environment/<env>.tfvars
```

### Manual Terraform commands (from terraform/deploy/)
```bash
terraform init
terraform workspace new <env_name>   # or: terraform workspace select <env_name>
terraform plan -var-file=environment/<env>.tfvars
terraform apply -var-file=environment/<env>.tfvars -auto-approve
```

## Architecture

### Terraform Structure
- `terraform/init/` - One-time setup: creates AWSLoadBalancerControllerIAMPolicy (run once per AWS account)
- `terraform/deploy/` - Main deployment configuration with numbered files indicating logical order:
  - `00_workspace_check.tf` - Enforces workspace name matches env_name from tfvars
  - `01_infrastructure.tf` - VPC, subnets, EKS cluster, DynamoDB table, VPC endpoints for SSM
  - `02_k8_lbc.tf` - AWS Load Balancer Controller via Helm
  - `03_k8s_storage.tf` - EBS CSI driver setup, StorageClass, PersistentVolumeClaim
  - `04_authentication.tf` - IRSA (IAM Roles for Service Accounts) for DynamoDB access
  - `05_application.tf` - Kubernetes Deployment for guestbook app, ALB module
  - `06_secrets_manager.tf` - Secrets Store CSI Driver and AWS provider DaemonSet
- `terraform/deploy/modules/alb/` - ALB Ingress configuration
- `terraform/deploy/environment/` - Region-specific tfvars files (us-east-1.tfvars, eu-west-1.tfvars, etc.)

### Key Patterns
- **Workspace convention**: Terraform workspace name must match `env_name` in the tfvars file
- **Resource naming**: Uses `eks-demo-<env_name>` prefix pattern (stored in `local.prefix_env`)
- **Dependencies**: Most K8s resources include `depends_on = [module.eks]` to handle RBAC propagation timing
- **Backend state**: Uses S3 + DynamoDB for state locking (must be configured in backend.tf before first use)

### Providers
- AWS (~> 5.95.0)
- Kubernetes (~> 2.35)
- Helm (~> 3.0)
- kubectl (alekc/kubectl ~> 2.0) - for raw manifest application

## Important Notes

- This cluster does NOT use EKS Auto Mode (see https://github.com/setheliot/eks_auto_mode for that)
- The guestbook app container is from `ghcr.io/setheliot/xyz-demo-app:latest`
- Cleanup requires staged destroys (deployment -> PVC -> ingress -> everything else) due to Kubernetes finalizer dependencies
