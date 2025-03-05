# Define environment stage name
variable "env_name" {
  description = "Unique identifier for tfvars configuration used"
  type        = string
}

# Define the instance type for EKS nodes
variable "instance_type" {
  description = "Instance type for EKS worker nodes"
  type        = string
  default     = "t3.micro"
}

# AWS Region to deploy the EKS cluster
variable "aws_region" {
  description = "AWS region to deploy the EKS cluster"
  type        = string
}

# EKS version
variable "eks_cluster_version" {
  description = "EKS version"
  type        = string
  default     = "1.32"
}

# Use ALB - can set this to false for to get NLB
### NLB not yet implemented. If false you get no load balancer
variable "use_alb" {
  description = "When true, uses AWS LBC to create ALB. When false an NLB is created"
  type        = bool
  default     = true
}