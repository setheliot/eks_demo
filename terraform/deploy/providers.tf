# AWS Provider configuration
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  prefix     = "eks-demo"
  prefix_env = "${local.prefix}-${var.env_name}"

  cluster_name    = "${local.prefix_env}-cluster"
  cluster_version = var.eks_cluster_version

  aws_account = data.aws_caller_identity.current.account_id

  ebs_claim_name = "ebs-volume-pv-claim"
}

#
# Setup the Kubernetes provider
# Can only be configured after the EKS cluster is created


# Data provider for cluster auth
data "aws_eks_cluster_auth" "cluster_auth" {
  name = module.eks.cluster_name
}

# Kubernetes provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster_auth.token
}

# Helm provider for the cluster
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster_auth.token
  }
}


