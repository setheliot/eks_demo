###############
#
# Secrets Manager integration with EKS using Secrets Store CSI Driver
#
# Logical order: 06
#

# Create the secret in AWS Secrets Manager
resource "aws_secretsmanager_secret" "test_secret" {
  name = "test-secret"

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

resource "aws_secretsmanager_secret_version" "test_secret_version" {
  secret_id = aws_secretsmanager_secret.test_secret.id
  secret_string = jsonencode({
    username = "admin"
    password = "MySecurePassword123"
  })
}



# IAM policy for Secrets Manager access
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

# Attach the policy to the DDB IAM role
resource "aws_iam_role_policy_attachment" "secrets_manager_attachment" {
  policy_arn = aws_iam_policy.secrets_manager_policy.arn
  role       = aws_iam_role.ddb_access_role.name
}

# Install Secrets Store CSI Driver via Helm
resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  values = [
    yamlencode({
      syncSecret = {
        enabled = true
      }
    })
  ]

  depends_on = [module.eks]
}

# AWS Secrets Manager CSI Provider - ServiceAccount
resource "kubernetes_service_account" "aws_provider" {
  metadata {
    name      = "csi-secrets-store-provider-aws"
    namespace = "kube-system"
  }

  depends_on = [helm_release.secrets_store_csi_driver]
}

# AWS Secrets Manager CSI Provider - ClusterRole
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

# AWS Secrets Manager CSI Provider - DaemonSet
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

# Create SecretProviderClass
resource "kubectl_manifest" "secret_provider_class" {
  yaml_body = <<-YAML
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: test-secret-provider
      namespace: default
    spec:
      provider: aws
      parameters:
        objects: |
          - objectName: "${aws_secretsmanager_secret.test_secret.name}"
            objectType: "secretsmanager"
  YAML

  depends_on = [kubernetes_daemonset.aws_provider]
}
