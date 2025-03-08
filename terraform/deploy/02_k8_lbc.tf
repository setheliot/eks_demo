###############
#
# AWS Load Balancer Controller (LBC) in the Kubernetes Cluster
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.6/deploy/installation
#
# Logical order: 02 
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#

#
# AWS Load Balancer Controller

# Retrieve the LBC IAM policy
# This should have already been created once per account by the init modules
# If it does not exist, will fail with timeout after 2 minutes
data "aws_iam_policy" "lbc_policy" {
  name = "AWSLoadBalancerControllerIAMPolicy"
}

# Attach the policy to the node IAM role
resource "aws_iam_role_policy_attachment" "alb_policy_node" {
  policy_arn = data.aws_iam_policy.lbc_policy.arn
  role       = module.eks.eks_managed_node_groups["node_group_1"].iam_role_name
}

#
# Create the K8s Service Account that will be used by Helm
resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }

  # Give time for the cluster to complete (controllers, RBAC and IAM propagation)
  # See https://github.com/setheliot/eks_demo/blob/main/docs/separate_configs.md
  depends_on = [module.eks]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  set {
    name  = "clusterName"
    value = local.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # Give time for the cluster to complete (controllers, RBAC and IAM propagation)
  # See https://github.com/setheliot/eks_demo/blob/main/docs/separate_configs.md
  depends_on = [module.eks]
}

