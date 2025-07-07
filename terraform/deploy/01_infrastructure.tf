###############
#
# AWS Infrastructure including the EKS Cluster
#
# Logical order: 01 
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############

#
# VPC and Subnets
data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az_count = length(data.aws_availability_zones.available.names)
  max_azs  = min(local.az_count, 3) # Use up to 3 AZs, but only if available (looking at you, us-west-1 👀)
}

module "vpc" {

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name            = "${local.prefix_env}-vpc"
  cidr            = "10.0.0.0/16"
  azs             = slice(data.aws_availability_zones.available.names, 0, local.max_azs)
  private_subnets = slice(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"], 0, local.max_azs)
  public_subnets  = slice(["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"], 0, local.max_azs)

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Tag subnets for use by AWS Load Balancer controller
  # https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.1/deploy/subnet_discovery/
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"     # ✅ Required for ALB
    "kubernetes.io/cluster/${local.cluster_name}" = "owned" # Links subnet to EKS
    "Name"                                        = "${local.prefix_env}-public-subnet"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1" # For internal load balancers
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    "Name"                                        = "${local.prefix_env}-private-subnet"
  }

  tags = {
    Terraform   = "true"
    Environment = local.prefix_env

    # Ensure workspace check logic runs before resources created
    always_zero = length(null_resource.check_workspace)
  }
}

# The managed node group will add a unique ID to the end of this
locals {
  eks_node_iam_role_name = substr("eks-node-role-${local.cluster_name}", 0, 36)
}


#
# EKS Cluster
module "eks" {

  source  = "terraform-aws-modules/eks/aws"
  version = ">= 20.0"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # coredns, kube-proxy, and vpc-cni are automatically installed by EKS         
  cluster_addons = {
    eks-pod-identity-agent = {},
    aws-ebs-csi-driver     = {}
  }

  eks_managed_node_groups = {
    node_group_1 = {
      name                           = "${local.prefix_env}-node-group"
      ami_type                       = "AL2023_x86_64_STANDARD"
      use_latest_ami_release_version = true
      instance_types                 = [var.instance_type]

      min_size     = 1
      max_size     = 5
      desired_size = 3

      # Setup a custom launch template for the managed nodes
      # Notes these settings are the same as the defaults
      use_custom_launch_template = true
      create_launch_template     = true

      # Enable Instance Metadata Service (IMDS)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      # Attach the managed policies for SSM access by the nodes
      iam_role_name = local.eks_node_iam_role_name
      iam_role_additional_policies = {
        ssm_access = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      } # iam_role_additional_policies
    }   # node_group_1
  }     # eks_managed_node_groups

  # Cluster access entry
  enable_cluster_creator_admin_permissions = true

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"

    # Ensure workspace check logic runs before resources created
    always_zero = length(null_resource.check_workspace)
  }

  # Transient failures in creating StorageClass, PersistentVolumeClaim, 
  # ServiceAccount, Deployment, were observed due to RBAC propagation not 
  # completed. Therefore raising this from its default 30s 
  dataplane_wait_duration = "60s"

}

locals {
  node_security_group_id = module.eks.node_security_group_id
}

# Create VPC endpoints (Private Links) for SSM Session Manager access to nodes
resource "aws_security_group" "vpc_endpoint_sg" {
  name   = "${local.prefix_env}-vpc-endpoint-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    description     = "Allow EKS Nodes to access VPC Endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [local.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

resource "aws_vpc_endpoint" "private_link_ssm" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

resource "aws_vpc_endpoint" "private_link_ssmmessages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

resource "aws_vpc_endpoint" "private_link_ec2messages" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

# DynamoDb table
resource "aws_vpc_endpoint" "private_link_dynamodb" {

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

resource "aws_dynamodb_table" "guestbook" {

  name             = "${local.prefix_env}-guestbook"
  billing_mode     = "PROVISIONED"
  read_capacity    = 2
  write_capacity   = 2
  hash_key         = "GuestID"
  range_key        = "Name"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "GuestID"
    type = "S"
  }

  attribute {
    name = "Name"
    type = "S"
  }

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }

  # Ensure workspace check logic runs before resources created
  depends_on = [null_resource.check_workspace]

}
