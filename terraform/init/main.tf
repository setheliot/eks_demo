
#
# This should only be run if the IAM policy does not already exist

#
# Create  policy to give EKS nodes necessary permissions to run the LBC
resource "aws_iam_policy" "alb_controller_custom" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/iam_policy.json")
}
