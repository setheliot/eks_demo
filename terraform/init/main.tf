
#
# This should only be run if the IAM policies do not already exist

#
# Create  policy to give EKS nodes necessary permissions to run the LBC
# IAM policy is from here:
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.6/deploy/installation/#configure-iam
# source for policy document is here:
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.1/docs/install/iam_policy.json
resource "aws_iam_policy" "alb_controller_custom" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/iam_policy.json")
}


