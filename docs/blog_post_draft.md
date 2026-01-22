# Building a Production-Ready EKS Cluster with Terraform: A Complete Guide

If you're new to Amazon EKS, the number of moving parts can be overwhelming. VPCs, subnets, node groups, CSI drivers, IRSA, load balancer controllers... where do you even start?

This guide walks through building a complete EKS cluster using Terraform, explaining each component and why it matters. By the end, you'll have a working cluster running a demo application with persistent storage, secrets management, and automatic scaling.

**Repository**: [github.com/setheliot/eks_demo](https://github.com/setheliot/eks_demo)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [VPC and Networking](#vpc-and-networking)
3. [EKS Cluster Setup](#eks-cluster-setup)
4. [AWS Load Balancer Controller](#aws-load-balancer-controller)
5. [Persistent Storage with EBS CSI](#persistent-storage-with-ebs-csi)
6. [IAM Roles for Service Accounts (IRSA)](#iam-roles-for-service-accounts-irsa)
7. [Secrets Management](#secrets-management)
8. [Cluster Autoscaler](#cluster-autoscaler)
9. [Deploying the Application](#deploying-the-application)
10. [Cleanup](#cleanup)

---

## Architecture Overview

Our cluster includes:

- **VPC** with public and private subnets across multiple availability zones
- **EKS Cluster** with managed node groups running Amazon Linux 2023
- **AWS Load Balancer Controller** for Kubernetes Ingress
- **EBS CSI Driver** for persistent volumes
- **Secrets Store CSI Driver** for AWS Secrets Manager integration
- **Cluster Autoscaler** for automatic node scaling
- **DynamoDB** for application data storage


---

## VPC and Networking

EKS requires a VPC with both public and private subnets. Here's why:

- **Public subnets**: Host your Application Load Balancers that receive traffic from the internet
- **Private subnets**: Host your EKS worker nodes (more secure, no direct internet access)
- **NAT Gateway**: Allows private subnet resources to reach the internet for updates and pulling container images

### Subnet Tags for Load Balancer Discovery

This is a critical detail many tutorials miss. The AWS Load Balancer Controller uses **tags** to discover which subnets it can place load balancers in:

```terraform
# From terraform/deploy/01_infrastructure.tf

public_subnet_tags = {
  "kubernetes.io/role/elb"                      = "1"     # Tells LBC: "Put internet-facing ALBs here"
  "kubernetes.io/cluster/${local.cluster_name}" = "owned" # Associates subnet with this EKS cluster
}

private_subnet_tags = {
  "kubernetes.io/role/internal-elb"             = "1"     # Tells LBC: "Put internal ALBs here"
  "kubernetes.io/cluster/${local.cluster_name}" = "owned"
}
```

Without these tags, your Ingress resources won't work, and you'll spend hours debugging why your ALB isn't being created.

---

## EKS Cluster Setup

We use the useful [terraform-aws-modules/eks](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest) module. Here are the key configuration decisions:

### Authentication Mode

```terraform
authentication_mode = "API"
```

EKS now supports "API" mode for authentication, which uses EKS access entries. This is the modern approach, replacing the older `aws-auth` ConfigMap method that was error-prone and hard to manage.

### Managed Node Groups

```terraform
eks_managed_node_groups = {
  node_group_1 = {
    ami_type       = "AL2023_x86_64_STANDARD"  # Amazon Linux 2023 (recommended)
    instance_types = [var.instance_type]
    min_size       = 1
    max_size       = 5
    desired_size   = 3

    # IMDSv2 - security best practice
    metadata_options = {
      http_tokens = "required"  # Enforces IMDSv2
    }
  }
}
```

Key points:
- **Amazon Linux 2023** is the recommended OS for EKS nodes
- **IMDSv2** prevents [SSRF (server-side request forgery)](https://aws.amazon.com/blogs/security/defense-in-depth-open-firewalls-reverse-proxies-ssrf-vulnerabilities-ec2-instance-metadata-service/) attacks by requiring token-based metadata access
- **Autoscaling bounds** (min/max) are used by the Cluster Autoscaler

### EKS Add-ons

```terraform
cluster_addons = {
  eks-pod-identity-agent = {}  # Enables EKS Pod Identity
  aws-ebs-csi-driver     = {}  # Required for EBS persistent volumes
}
```

The EBS CSI Driver is essential - without it, your PersistentVolumeClaims requesting EBS storage will stay in "Pending" forever.

---

## AWS Load Balancer Controller

Kubernetes doesn't know how to create AWS load balancers natively. The AWS Load Balancer Controller bridges this gap:

```
You create Ingress → Controller sees it → Creates ALB → Routes traffic to pods
```

### Installation

```terraform
# From terraform/deploy/02_k8_lbc.tf

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  set = [
    { name = "clusterName", value = local.cluster_name },
    { name = "vpcId",       value = module.vpc.vpc_id },
    { name = "region",      value = var.aws_region }
  ]
}
```

The controller needs IAM permissions to create load balancers, target groups, and security groups. We attach these permissions to the node IAM role.

---

## Persistent Storage with EBS CSI

Kubernetes has a clean abstraction for storage:

1. **StorageClass** - Defines *how* to provision storage (EBS gp3, encrypted, etc.)
2. **PersistentVolumeClaim (PVC)** - A *request* for storage ("I need 10Gi")
3. **PersistentVolume (PV)** - The *actual* storage resource (created automatically)

### The StorageClass

```terraform
# From terraform/deploy/03_k8s_storage.tf

resource "kubernetes_storage_class" "ebs" {
  metadata {
    name = "ebs-storage-class"
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"  # Critical!

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
```

### Why WaitForFirstConsumer Matters

`WaitForFirstConsumer` delays volume creation until a pod actually needs it. This is crucial because:

- EBS volumes are **AZ-specific** (a volume in us-east-1a can't attach to a node in us-east-1b)
- Without this setting, the volume might be created in the wrong AZ
- With it, Kubernetes waits to see where the pod is scheduled, then creates the volume in that AZ

### The PVC

```terraform
resource "kubernetes_persistent_volume_claim_v1" "ebs_pvc" {
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ebs-storage-class"
    resources {
      requests = { storage = "1Gi" }
    }
  }

  wait_until_bound = false  # Don't hang Terraform!
}
```

The `wait_until_bound = false` is important for Terraform. With `WaitForFirstConsumer`, the PVC won't bind until a pod uses it, so Terraform would hang forever waiting.

---

## IAM Roles for Service Accounts (IRSA)

IRSA is the recommended way to give pods AWS permissions. Instead of attaching broad permissions to node roles, each pod gets only what it needs.

### How It Works

1. EKS creates an OIDC identity provider for your cluster
2. You create an IAM role that trusts this OIDC provider
3. You annotate a K8s ServiceAccount with the IAM role ARN
4. Pods using that ServiceAccount automatically get temporary AWS credentials

### The Trust Policy

```terraform
# From terraform/deploy/04_authentication.tf

data "aws_iam_policy_document" "service_account_trust_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.aws_account}:oidc-provider/${local.oidc}"]
    }

    # Only this specific ServiceAccount can assume the role
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:sub"
      values   = ["system:serviceaccount:default:${local.ddb_serviceaccount}"]
    }
  }
}
```

The conditions are critical for security - they prevent other pods from assuming this role.

### The ServiceAccount

```terraform
resource "kubernetes_service_account" "ddb_serviceaccount" {
  metadata {
    name = local.ddb_serviceaccount
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ddb_access_role.arn
    }
  }
}
```

That annotation is the magic link. When a pod uses this ServiceAccount, the EKS pod identity webhook injects AWS credentials automatically.

---

## Secrets Management

We use the Secrets Store CSI Driver to mount AWS Secrets Manager secrets directly into pods as files.

### Why Not Kubernetes Secrets?

- **Centralized management**: Same secrets for K8s and other AWS services
- **Automatic rotation**: Secrets Manager can rotate secrets; K8s Secrets can't
- **Audit logging**: CloudTrail tracks who accessed what
- **No etcd storage**: Secrets are fetched at runtime, not stored in the cluster

### Architecture

```
AWS Secrets Manager
        │
        ▼
  AWS Provider (DaemonSet on each node)
        │
        ▼
  Secrets Store CSI Driver
        │
        ▼
  Pod (secrets mounted as files at /mnt/secrets)
```

### SecretProviderClass

```terraform
# From terraform/deploy/06_secrets_manager.tf

resource "kubectl_manifest" "secret_provider_class" {
  yaml_body = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: test-secret-provider
    spec:
      provider: aws
      parameters:
        objects: |
          - objectName: "${aws_secretsmanager_secret.test_secret.name}"
            objectType: "secretsmanager"
  YAML
}
```

Pods reference this in their volume definition, and secrets appear as files.

---

## Cluster Autoscaler

The Cluster Autoscaler automatically adjusts the number of nodes based on pending pods:

- **Scale up**: When pods can't be scheduled due to insufficient resources
- **Scale down**: When nodes are underutilized for an extended period

### Auto-Discovery

```terraform
# Node group tags (in 01_infrastructure.tf)
tags = {
  "k8s.io/cluster-autoscaler/enabled"               = "true"
  "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
}
```

The autoscaler finds node groups to manage by looking for these tags - no need to hardcode node group names.

---

## Deploying the Application

Our guestbook application demonstrates all these features:

```terraform
# From terraform/deploy/05_application.tf

resource "kubernetes_deployment_v1" "guestbook_app_deployment" {
  spec {
    template {
      spec {
        service_account_name = local.ddb_serviceaccount  # IRSA for DynamoDB access

        container {
          image = "ghcr.io/setheliot/xyz-demo-app:latest"

          # Mount EBS persistent storage
          volume_mount {
            name       = "ebs-k8s-attached-storage"
            mount_path = "/app/data"
          }

          # Mount secrets from Secrets Manager
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          env {
            name  = "DDB_TABLE"
            value = aws_dynamodb_table.guestbook.name
          }
        }

        # EBS volume via PVC
        volume {
          name = "ebs-k8s-attached-storage"
          persistent_volume_claim {
            claim_name = local.ebs_claim_name
          }
        }

        # Secrets via CSI
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = "test-secret-provider"
            }
          }
        }
      }
    }
  }
}
```

---

## Cleanup

Due to Kubernetes finalizers, you can't just run `terraform destroy`. Resources must be deleted in order:

1. Deployment (releases the PVC)
2. PVC (releases the PV/EBS volume)
3. Ingress (releases the ALB)
4. Everything else

The included cleanup script handles this:

```bash
cd scripts
./cleanup_cluster.sh -var-file=environment/us-east-1.tfvars
```

---

## Getting Started

```bash
# Clone the repo
git clone https://github.com/setheliot/eks_demo.git
cd eks_demo

# Deploy (interactive script handles everything)
cd scripts
./ez_cluster_deploy.sh
```

The deployment takes about 15-20 minutes. When complete, you'll get the ALB DNS name to access your application.

---

## Conclusion

Building a production-ready EKS cluster involves many components working together:

- **Networking**: VPC with proper subnet tags for load balancer discovery
- **Compute**: Managed node groups with security best practices (IMDSv2)
- **Storage**: EBS CSI Driver with `WaitForFirstConsumer` for AZ-aware provisioning
- **Authentication**: IRSA for least-privilege pod permissions
- **Secrets**: Secrets Store CSI Driver for centralized secret management
- **Scaling**: Cluster Autoscaler with tag-based discovery

Each piece builds on the others. Understanding these relationships is key to operating EKS effectively.

The full code is available at [github.com/setheliot/eks_demo](https://github.com/setheliot/eks_demo). Feel free to fork it, experiment, and adapt it for your own projects.

---

*Questions or feedback? Open an issue on the repository!*
