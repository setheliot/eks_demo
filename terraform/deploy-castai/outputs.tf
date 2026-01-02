# Output the VPC ID
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

# Output the EKS cluster details
output "eks_cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster API Endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_arn" {
  description = "EKS Cluster ARN"
  value       = module.eks.cluster_arn
}

# Output the AWS Region
output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

# CastAI outputs
output "castai_cluster_id" {
  description = "CastAI cluster ID"
  value       = module.castai_eks_cluster.cluster_id
}

output "castai_node_role_arn" {
  description = "IAM role ARN for CastAI-provisioned nodes"
  value       = aws_iam_role.castai_node_role.arn
}

output "castai_instance_profile_arn" {
  description = "Instance profile ARN for CastAI-provisioned nodes"
  value       = aws_iam_instance_profile.castai_node_profile.arn
}

