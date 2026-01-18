###############
#
# AWS Infrastructure including the EKS Cluster
#
# Logical order: 01
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############

###############################################################################
# VPC AND SUBNETS
###############################################################################
# EKS requires a VPC with both public and private subnets across multiple AZs.
# - Public subnets: Host load balancers that receive traffic from the internet
# - Private subnets: Host your EKS worker nodes (more secure, no direct internet access)
# - NAT Gateway: Allows private subnet resources to reach the internet for updates
#
# This architecture follows AWS best practices for production EKS deployments.
###############################################################################

# Query available AZs in the current region
data "aws_availability_zones" "available" {
  # Exclude local zones (these are edge locations, not full AZs)
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az_count = length(data.aws_availability_zones.available.names)
  max_azs  = min(local.az_count, 3) # Use up to 3 AZs, but only if available (looking at you, us-west-1 👀)
}

# The terraform-aws-modules/vpc module simplifies VPC creation with sensible defaults
module "vpc" {

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name            = "${local.prefix_env}-vpc"
  cidr            = "10.0.0.0/16" # /16 gives us 65,536 IP addresses to work with
  azs             = slice(data.aws_availability_zones.available.names, 0, local.max_azs)
  private_subnets = slice(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"], 0, local.max_azs)
  public_subnets  = slice(["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"], 0, local.max_azs)

  enable_nat_gateway   = true
  single_nat_gateway   = true # Use one NAT GW to save costs; use multiple for HA in production
  enable_dns_hostnames = true # Required for EKS to resolve internal DNS names

  ###############################################################################
  # SUBNET TAGS FOR AWS LOAD BALANCER CONTROLLER
  ###############################################################################
  # Without these tags, your Ingress resources won't work!
  # Docs: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/subnet_discovery/
  ###############################################################################
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"     # Tells LBC: "Put internet-facing ALBs here"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned" # Associates subnet with this EKS cluster
    "Name"                                        = "${local.prefix_env}-public-subnet"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1" # Tells LBC: "Put internal ALBs here"
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


###############################################################################
# EKS CLUSTER
###############################################################################
# Amazon EKS is a managed Kubernetes service. AWS handles the control plane
# (API server, etcd, scheduler, etc.) while you manage the worker nodes.
###############################################################################
module "eks" {

  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37" # latest 20.x

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  # Authentication mode "API" uses EKS access entries (the modern approach)
  # This replaces the older aws-auth ConfigMap method
  authentication_mode             = "API"
  cluster_endpoint_public_access  = true  # Allow kubectl access from internet
  cluster_endpoint_private_access = false # Nodes access API via public endpoint

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # Worker nodes run in private subnets

  ###############################################################################
  # EKS ADD-ONS
  ###############################################################################
  # Add-ons extend cluster functionality. These run as pods in your cluster.
  # Note: coredns, kube-proxy, and vpc-cni are automatically installed by EKS
  ###############################################################################
  cluster_addons = {
    eks-pod-identity-agent = {} # Enables EKS Pod Identity (newer alternative to IRSA)
    aws-ebs-csi-driver     = {} # Required for EBS persistent volumes (see 03_k8s_storage.tf)
  }

  ###############################################################################
  # MANAGED NODE GROUPS
  ###############################################################################
  # EKS Managed Node Groups simplify node lifecycle management:
  # - AWS handles node provisioning, updates, and termination
  # - Auto Scaling Group is created and managed for you
  # - Nodes automatically register with the EKS cluster
  ###############################################################################
  eks_managed_node_groups = {
    node_group_1 = {
      name                           = "${local.prefix_env}-node-group"
      ami_type                       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 (recommended)
      use_latest_ami_release_version = true
      instance_types                 = [var.instance_type]

      min_size     = 1  # Cluster Autoscaler can scale down to this
      max_size     = 5  # Cluster Autoscaler can scale up to this
      desired_size = 3  # Starting number of nodes

      # Custom launch template gives us control over instance configuration
      use_custom_launch_template = true
      create_launch_template     = true

      # IMDSv2 (Instance Metadata Service v2) - security best practice
      # Requires token-based access to instance metadata, preventing SSRF attacks
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required" # Enforces IMDSv2
        http_put_response_hop_limit = 2          # Allow containers to access IMDS
      }

      # SSM access allows you to connect to nodes without SSH keys
      # Use: aws ssm start-session --target <instance-id>
      iam_role_name = local.eks_node_iam_role_name
      iam_role_additional_policies = {
        ssm_access = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Tags for Cluster Autoscaler auto-discovery (see 08_cluster_autoscaler.tf)
      # The autoscaler finds node groups to manage by looking for these tags
      tags = {
        "k8s.io/cluster-autoscaler/enabled"               = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
      }
    }
  }

  # Grants the IAM principal running Terraform admin access to the cluster
  enable_cluster_creator_admin_permissions = true

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"

    # Ensure workspace check logic runs before resources created
    always_zero = length(null_resource.check_workspace)
  }

  # Wait for the data plane to be ready before proceeding
  # RBAC propagation can take time; 60s prevents transient failures
  # when creating K8s resources immediately after cluster creation
  dataplane_wait_duration = "60s"

}

locals {
  node_security_group_id = module.eks.node_security_group_id
}

###############################################################################
# VPC ENDPOINTS
###############################################################################
# VPC Endpoints allow private connectivity to AWS services without using the
# internet. Since our nodes are in private subnets, they need endpoints to:
# - SSM: AWS Systems Manager for node access (no SSH keys needed!)
# - DynamoDB: Database access for our guestbook app
###############################################################################

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

# Gateway endpoint for DynamoDB - free and fast!
resource "aws_vpc_endpoint" "private_link_dynamodb" {

  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway" # Gateway endpoints are free (vs Interface endpoints)
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }
}

###############################################################################
# DYNAMODB TABLE
###############################################################################
# Our guestbook application uses DynamoDB as its database.
# DynamoDB is a fully managed NoSQL database - no servers to manage!
###############################################################################
resource "aws_dynamodb_table" "guestbook" {

  name         = "${local.prefix_env}-guestbook"
  billing_mode = "PROVISIONED" # Fixed capacity; use "PAY_PER_REQUEST" for variable workloads
  # RCU/WCU set low for demo; production would need capacity planning
  read_capacity  = 2
  write_capacity = 2
  hash_key       = "GuestID"
  range_key      = "Name"

  # DynamoDB Streams captures changes - useful for triggers, replication, analytics
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE" # Stream contains the new version of modified items

  # Point-in-time recovery - restore table to any second in the last 35 days
  point_in_time_recovery {
    enabled = true
  }

  # Only define attributes used in keys or indexes
  attribute {
    name = "GuestID"
    type = "S" # S = String, N = Number, B = Binary
  }

  attribute {
    name = "Name"
    type = "S"
  }

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
  }

  depends_on = [null_resource.check_workspace]

}
