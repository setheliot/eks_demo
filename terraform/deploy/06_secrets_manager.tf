###############################################################################
#
# SECRETS MANAGEMENT WITH SECRETS STORE CSI DRIVER
#
# Logical order: 06
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############################################################################
# This demonstrates how to securely provide secrets to pods using:
# - AWS Secrets Manager: Stores and manages secrets outside your cluster
# - Secrets Store CSI Driver: Mounts secrets as files in pods
#
# Why use this instead of Kubernetes Secrets?
# - Centralized secret management across all your AWS resources
# - Automatic rotation support
# - Audit logging via CloudTrail
# - No secrets stored in etcd (the K8s database)
# - Secrets are fetched at pod startup, not stored in the cluster
#
# Architecture:
# 1. Secret stored in AWS Secrets Manager
# 2. Secrets Store CSI Driver installed in cluster (Helm)
# 3. AWS Provider DaemonSet fetches secrets from AWS
# 4. SecretProviderClass defines which secrets to fetch
# 5. Pod mounts secrets as files via CSI volume
###############################################################################

###############################################################################
# AWS SECRETS MANAGER SECRET
###############################################################################
# Store your secret in AWS Secrets Manager. In production, you'd create this
# separately (not in Terraform with plaintext values!).
###############################################################################
resource "aws_secretsmanager_secret" "test_secret" {
  name = "${local.prefix_env}-secret"

  # For demo: delete immediately. Production: keep 30-day recovery window!
  recovery_window_in_days = 0

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

# The actual secret value (JSON format is common for multiple key-value pairs)
# WARNING: In production, never put real secrets in Terraform code!
# Use: terraform apply -var="db_password=xxx" or external secret management
resource "aws_secretsmanager_secret_version" "test_secret_version" {
  secret_id = aws_secretsmanager_secret.test_secret.id
  secret_string = jsonencode({
    username = "admin"
    password = "MySecurePassword123"
  })
}


###############################################################################
# IAM PERMISSIONS FOR SECRETS ACCESS
###############################################################################
# The pod needs IAM permissions to read from Secrets Manager.
# We attach this to the same IRSA role used for DynamoDB (from 04_authentication.tf).
###############################################################################
resource "aws_iam_policy" "secrets_manager_policy" {
  name        = "guestbook-secrets-${local.prefix_env}-${var.aws_region}-policy"
  description = "Policy for accessing Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "${aws_secretsmanager_secret.test_secret.arn}"
      }
    ]
  })
}

# Attach to the existing IRSA role (pod already uses this ServiceAccount)
resource "aws_iam_role_policy_attachment" "secrets_manager_attachment" {
  policy_arn = aws_iam_policy.secrets_manager_policy.arn
  role       = aws_iam_role.ddb_access_role.name
}

###############################################################################
# SECRETS STORE CSI DRIVER (Helm)
###############################################################################
# The CSI Driver is the Kubernetes component that:
# - Watches for pods with CSI volume mounts
# - Coordinates with provider (AWS) to fetch secrets
# - Mounts secrets as files in the pod's filesystem
#
# This is the "generic" driver - it needs a provider for each secret store
# (AWS, Azure, GCP, HashiCorp Vault, etc.)
###############################################################################
resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  values = [
    yamlencode({
      syncSecret = {
        enabled = true # Also sync to K8s Secrets (useful for env vars)
      }
    })
  ]

  depends_on = [module.eks]
}

###############################################################################
# AWS SECRETS MANAGER CSI PROVIDER
###############################################################################
# The AWS Provider is a DaemonSet that runs on each node. It:
# - Receives requests from the CSI Driver
# - Uses IAM credentials to fetch secrets from AWS Secrets Manager
# - Returns secret data to the CSI Driver for mounting
#
# We deploy it manually (not via Helm) to show the components involved.
###############################################################################

# ServiceAccount for the AWS provider pods
resource "kubernetes_service_account" "aws_provider" {
  metadata {
    name      = "csi-secrets-store-provider-aws"
    namespace = "kube-system"
  }

  depends_on = [helm_release.secrets_store_csi_driver]
}

# RBAC: The provider needs to read pod/node info to validate requests
resource "kubernetes_cluster_role" "aws_provider" {
  metadata {
    name = "csi-secrets-store-provider-aws-cluster-role"
  }

  rule {
    api_groups = [""]
    resources  = ["serviceaccounts/token"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get"]
  }

  depends_on = [helm_release.secrets_store_csi_driver]
}

# AWS Secrets Manager CSI Provider - ClusterRoleBinding
resource "kubernetes_cluster_role_binding" "aws_provider" {
  metadata {
    name = "csi-secrets-store-provider-aws-cluster-rolebinding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.aws_provider.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.aws_provider.metadata[0].name
    namespace = "kube-system"
  }
}

###############################################################################
# AWS PROVIDER DAEMONSET
###############################################################################
# DaemonSet ensures one provider pod runs on each node.
# This is required because the CSI driver communicates with the provider
# via a Unix socket on the local node.
###############################################################################
resource "kubernetes_daemonset" "aws_provider" {
  metadata {
    name      = "csi-secrets-store-provider-aws"
    namespace = "kube-system"
    labels = {
      app = "csi-secrets-store-provider-aws"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "csi-secrets-store-provider-aws"
      }
    }

    template {
      metadata {
        labels = {
          app = "csi-secrets-store-provider-aws"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.aws_provider.metadata[0].name
        host_network         = false

        container {
          name              = "provider-aws-installer"
          image             = "public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws:2.1.0"
          image_pull_policy = "Always"

          args = ["--provider-volume=/var/run/secrets-store-csi-providers"]

          resources {
            requests = {
              cpu    = "50m"
              memory = "100Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "100Mi"
            }
          }

          security_context {
            privileged                 = false
            allow_privilege_escalation = false
          }

          volume_mount {
            name       = "providervol"
            mount_path = "/var/run/secrets-store-csi-providers"
          }

          volume_mount {
            name              = "mountpoint-dir"
            mount_path        = "/var/lib/kubelet/pods"
            mount_propagation = "HostToContainer"
          }
        }

        volume {
          name = "providervol"
          host_path {
            path = "/var/run/secrets-store-csi-providers"
          }
        }

        volume {
          name = "mountpoint-dir"
          host_path {
            path = "/var/lib/kubelet/pods"
            type = "DirectoryOrCreate"
          }
        }

        node_selector = {
          "kubernetes.io/os" = "linux"
        }
      }
    }

    strategy {
      type = "RollingUpdate"
    }
  }

  depends_on = [
    kubernetes_service_account.aws_provider,
    kubernetes_cluster_role_binding.aws_provider
  ]
}

###############################################################################
# SECRET PROVIDER CLASS
###############################################################################
# This custom resource tells the CSI driver WHICH secrets to fetch and HOW.
# Pods reference this by name in their volume definition.
#
# Think of it as: "When a pod asks for 'test-secret-provider', fetch these
# secrets from AWS Secrets Manager and mount them as files."
###############################################################################
resource "kubectl_manifest" "secret_provider_class" {
  yaml_body = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: test-secret-provider
      namespace: default
    spec:
      provider: aws    # Use the AWS provider we installed above
      parameters:
        objects: |
          - objectName: "${aws_secretsmanager_secret.test_secret.name}"
            objectType: "secretsmanager"
  YAML

  depends_on = [kubernetes_daemonset.aws_provider]
}

###############################################################################
# How pods mount secrets (see 05_application.tf):
#
# volumes:
#   - name: secrets-store
#     csi:
#       driver: secrets-store.csi.k8s.io
#       readOnly: true
#       volumeAttributes:
#         secretProviderClass: "test-secret-provider"
#
# volumeMounts:
#   - name: secrets-store
#     mountPath: "/mnt/secrets"
#     readOnly: true
#
# Result: Secret appears as file at /mnt/secrets/<secret-name>
###############################################################################
