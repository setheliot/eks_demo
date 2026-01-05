###############
#
# Kubernetes Cluster Autoscaler
# Automatically scales EKS managed node groups based on pending pods
#
# Logical order: 08
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
# References:
# - https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
# - https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md
#
###############

# IAM Policy for Cluster Autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${local.prefix_env}-cluster-autoscaler"
  description = "IAM policy for Kubernetes Cluster Autoscaler"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

# Attach the policy to the node IAM role
resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
  role       = module.eks.eks_managed_node_groups["node_group_1"].iam_role_name
}

# Service Account for Cluster Autoscaler
resource "kubernetes_service_account" "cluster_autoscaler_sa" {
  metadata {
    name      = "cluster-autoscaler"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "cluster-autoscaler"
    }
  }

  depends_on = [module.eks]
}

# Helm release for Cluster Autoscaler
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"

  set = [
    {
      name  = "autoDiscovery.clusterName"
      value = local.cluster_name
    },
    {
      name  = "awsRegion"
      value = var.aws_region
    },
    {
      name  = "rbac.serviceAccount.create"
      value = "false"
    },
    {
      name  = "rbac.serviceAccount.name"
      value = kubernetes_service_account.cluster_autoscaler_sa.metadata[0].name
    },
    {
      name  = "extraArgs.balance-similar-node-groups"
      value = "true"
    },
    {
      name  = "extraArgs.skip-nodes-with-system-pods"
      value = "false"
    }
  ]

  depends_on = [module.eks]
}
