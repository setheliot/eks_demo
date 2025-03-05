###############
#
# Resources needed to give the application the necessary permissions
# Includes IAM Role and Kubernetes ServiceAccount
#
# Logical order: 04
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#

#
# Use IRSA to give pods the necessary permissions
#

#
# Create trust policy to be used by Service Account role

locals {
  ddb_serviceaccount = "ddb-${local.prefix_env}-serviceaccount"
  oidc               = module.eks.oidc_provider
}


data "aws_iam_policy_document" "service_account_trust_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.aws_account}:oidc-provider/${local.oidc}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:sub"
      values   = ["system:serviceaccount:default:${local.ddb_serviceaccount}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}


resource "aws_iam_role" "ddb_access_role" {
  name = "ddb-${local.prefix_env}-${var.aws_region}-role"

  assume_role_policy = data.aws_iam_policy_document.service_account_trust_policy.json

  description = "Role used by Service Account to access DynamoDB"

  tags = {
    Name = "IRSA role used by DDB"
  }
}

resource "aws_iam_role_policy_attachment" "ddb_access_attachment" {
  role       = aws_iam_role.ddb_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}


#
# Create service account
resource "kubernetes_service_account" "ddb_serviceaccount" {
  metadata {
    name      = local.ddb_serviceaccount
    namespace = "default"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ddb_access_role.arn
    }
  }

  # Give time for the cluster to complete (controllers, RBAC and IAM propagation)
  # See https://github.com/setheliot/eks_demo/blob/main/docs/separate_configs.md
  depends_on = [module.eks]
}

