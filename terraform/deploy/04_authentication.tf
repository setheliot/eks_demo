###############################################################################
#
# IAM ROLES FOR SERVICE ACCOUNTS (IRSA)
#
# Logical order: 04
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############################################################################
# IRSA lets Kubernetes pods assume IAM roles to access AWS services.
# This is the recommended way to give pods AWS permissions (not node roles!).
#
# How IRSA works:
# 1. EKS creates an OIDC identity provider for your cluster
# 2. You create an IAM role that trusts this OIDC provider
# 3. You annotate a K8s ServiceAccount with the IAM role ARN
# 4. Pods using that ServiceAccount automatically get temporary AWS credentials
#
# The magic: AWS STS validates the pod's identity via OIDC before issuing credentials
###############################################################################

locals {
  ddb_serviceaccount = "ddb-${local.prefix_env}-serviceaccount"
  oidc               = module.eks.oidc_provider # The OIDC provider URL (without https://)
}

###############################################################################
# IAM TRUST POLICY
###############################################################################
# This policy tells AWS IAM: "Trust tokens from this OIDC provider, but ONLY
# if they're for this specific ServiceAccount in this specific namespace."
#
# This is what prevents other pods from assuming this role!
###############################################################################
data "aws_iam_policy_document" "service_account_trust_policy" {
  statement {
    # Allow the OIDC provider to assume this role via web identity
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      # The OIDC provider for our EKS cluster
      identifiers = ["arn:aws:iam::${local.aws_account}:oidc-provider/${local.oidc}"]
    }

    # CRITICAL: These conditions restrict which ServiceAccount can assume the role
    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:sub"
      # Format: system:serviceaccount:<namespace>:<serviceaccount-name>
      values   = ["system:serviceaccount:default:${local.ddb_serviceaccount}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:aud"
      values   = ["sts.amazonaws.com"] # Standard audience for EKS IRSA
    }
  }
}

###############################################################################
# IAM ROLE
###############################################################################
# This role will be assumed by pods using our ServiceAccount.
# It has permissions to access DynamoDB (attached below).
###############################################################################
resource "aws_iam_role" "ddb_access_role" {
  name = "ddb-${local.prefix_env}-${var.aws_region}-role"

  # The trust policy defines WHO can assume this role
  assume_role_policy = data.aws_iam_policy_document.service_account_trust_policy.json

  description = "Role used by Service Account to access DynamoDB"

  tags = {
    Name = "IRSA role for DynamoDB access"
  }
}

# Attach DynamoDB permissions to the role
# In production, use a custom policy with least-privilege (not FullAccess!)
resource "aws_iam_role_policy_attachment" "ddb_access_attachment" {
  role       = aws_iam_role.ddb_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

###############################################################################
# KUBERNETES SERVICE ACCOUNT
###############################################################################
# The ServiceAccount is annotated with the IAM role ARN.
# When a pod uses this ServiceAccount, the EKS pod identity webhook
# automatically injects AWS credentials into the pod.
###############################################################################
resource "kubernetes_service_account" "ddb_serviceaccount" {
  metadata {
    name      = local.ddb_serviceaccount
    namespace = "default"
    annotations = {
      # This annotation is the magic link between K8s ServiceAccount and IAM Role
      "eks.amazonaws.com/role-arn" = aws_iam_role.ddb_access_role.arn
    }
  }

  depends_on = [module.eks]
}

###############################################################################
# How pods use this:
# 1. Deployment spec includes: serviceAccountName: ddb-<env>-serviceaccount
# 2. Pod starts with AWS credentials injected as environment variables
# 3. AWS SDK in the pod automatically uses these credentials
# 4. Pod can access DynamoDB with the permissions from the IAM role
###############################################################################

