###############################################################################
#
# AWS LOAD BALANCER CONTROLLER (LBC)
#
# Logical order: 02
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############################################################################
# The AWS Load Balancer Controller is a Kubernetes controller that manages
# AWS Elastic Load Balancers for your cluster. It watches for Ingress and
# Service resources, then creates/configures ALBs and NLBs automatically.
#
# Why do we need this?
# - Kubernetes doesn't know how to create AWS load balancers natively
# - The controller bridges Kubernetes Ingress -> AWS ALB/NLB
# - It uses subnet tags (set in 01_infrastructure.tf) to know where to place LBs
#
# Flow: You create Ingress -> Controller sees it -> Creates ALB -> Routes traffic
#
# Docs: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/
###############################################################################

###############################################################################
# IAM PERMISSIONS FOR THE CONTROLLER
###############################################################################
# The LBC needs AWS permissions to create/manage load balancers, target groups,
# listeners, security groups, etc. The policy is created once per account
# in terraform/init/ and then referenced here.
###############################################################################

# Retrieve the LBC IAM policy (created by terraform/init/)
# If this fails, run terraform apply in terraform/init/ first
data "aws_iam_policy" "lbc_policy" {
  name = "AWSLoadBalancerControllerIAMPolicy"
}

# Attach the policy to the node IAM role
# This grants the controller (running on nodes) permission to manage LBs
resource "aws_iam_role_policy_attachment" "alb_policy_node" {
  policy_arn = data.aws_iam_policy.lbc_policy.arn
  role       = module.eks.eks_managed_node_groups["node_group_1"].iam_role_name
}

###############################################################################
# KUBERNETES SERVICE ACCOUNT
###############################################################################
# The controller pod needs a ServiceAccount to authenticate to Kubernetes.
# We create it separately so we can reference it in the Helm release.
###############################################################################
resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system" # System components go in kube-system
  }

  depends_on = [module.eks]
}

###############################################################################
# HELM RELEASE - INSTALL THE CONTROLLER
###############################################################################
# Helm is a package manager for Kubernetes. The LBC is distributed as a
# Helm chart, which bundles all the K8s resources (Deployment, RBAC, etc.)
# needed to run the controller.
###############################################################################
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts" # Official AWS Helm repo
  chart      = "aws-load-balancer-controller"

  # Configure the chart with our cluster-specific values
  set = [
    {
      name  = "clusterName"
      value = local.cluster_name
    },
    {
      # Don't let Helm create the ServiceAccount - we created it above
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account.alb_controller.metadata[0].name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      # Controller needs VPC ID to find subnets and create LBs
      name  = "vpcId"
      value = module.vpc.vpc_id
    }
  ]

  depends_on = [module.eks]
}

