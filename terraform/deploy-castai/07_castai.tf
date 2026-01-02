###############
#
# CastAI Installation using Official Terraform Provider
#
# Logical order: 07
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
# This uses the official CastAI Terraform modules to:
# - Create IAM roles for CastAI to manage the cluster
# - Connect the EKS cluster to CastAI
# - Configure node templates and autoscaler settings
#
# References:
# - https://github.com/castai/terraform-castai-eks-cluster
# - https://github.com/castai/terraform-castai-eks-role-iam
# - https://registry.terraform.io/providers/castai/castai/latest
#
###############

# Step 1: Register the cluster with CastAI (creates cluster_id)
resource "castai_eks_clusterid" "cluster_id" {
  account_id   = local.aws_account
  region       = var.aws_region
  cluster_name = local.cluster_name
}

# Step 2: Get the CastAI user ARN (requires cluster_id)
resource "castai_eks_user_arn" "castai_user_arn" {
  cluster_id = castai_eks_clusterid.cluster_id.id
}

# Step 3: CastAI IAM Role Module - creates the IAM role that CastAI assumes
module "castai_eks_role_iam" {
  source  = "castai/eks-role-iam/castai"
  version = "~> 2.0"

  aws_account_id     = local.aws_account
  aws_cluster_region = var.aws_region
  aws_cluster_name   = local.cluster_name
  aws_cluster_vpc_id = module.vpc.vpc_id
  castai_user_arn    = castai_eks_user_arn.castai_user_arn.arn

  depends_on = [module.eks]
}

# Create a dedicated IAM role for CastAI-provisioned nodes
# This allows us to attach additional policies like AWSLoadBalancerControllerIAMPolicy
resource "aws_iam_role" "castai_node_role" {
  name = "castai-node-${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = local.prefix_env
    Terraform   = "true"
    CastAI      = "true"
  }
}

# Create instance profile for CastAI nodes
resource "aws_iam_instance_profile" "castai_node_profile" {
  name = "castai-node-profile-${local.cluster_name}"
  role = aws_iam_role.castai_node_role.name
}

# Add EKS access entry for CastAI node role so nodes can join the cluster
resource "aws_eks_access_entry" "castai_node_access" {
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.castai_node_role.arn
  type          = "EC2_LINUX"

  depends_on = [module.eks]
}

# Attach required policies to CastAI node role
resource "aws_iam_role_policy_attachment" "castai_node_eks_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.castai_node_role.name
}

resource "aws_iam_role_policy_attachment" "castai_node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.castai_node_role.name
}

resource "aws_iam_role_policy_attachment" "castai_node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.castai_node_role.name
}

resource "aws_iam_role_policy_attachment" "castai_node_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.castai_node_role.name
}

resource "aws_iam_role_policy_attachment" "castai_node_ebs" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.castai_node_role.name
}

# IMPORTANT: Attach the AWS Load Balancer Controller IAM Policy
# This allows the LB controller running on CastAI nodes to manage ALBs/NLBs
resource "aws_iam_role_policy_attachment" "castai_node_alb_controller" {
  policy_arn = data.aws_iam_policy.lbc_policy.arn
  role       = aws_iam_role.castai_node_role.name
}

# CastAI EKS Cluster Module - connects the cluster to CastAI
module "castai_eks_cluster" {
  source  = "castai/eks-cluster/castai"
  version = "~> 13.5.0"

  aws_account_id      = local.aws_account
  aws_cluster_region  = var.aws_region
  aws_cluster_name    = local.cluster_name
  aws_assume_role_arn = module.castai_eks_role_iam.role_arn

  # Delete CastAI-provisioned nodes when cluster is disconnected/destroyed
  delete_nodes_on_disconnect = true

  # Use our custom node configuration with LBC policy attached
  default_node_configuration = module.castai_eks_cluster.castai_node_configurations["default"]

  node_configurations = {
    default = {
      subnets                   = module.vpc.private_subnets
      dns_cluster_ip            = "172.20.0.10"
      instance_profile_arn      = aws_iam_instance_profile.castai_node_profile.arn
      # Only use node security group - ALB controller requires exactly one SG with cluster tag
      security_groups           = [module.eks.node_security_group_id]
      tags = {
        Environment = local.prefix_env
        Terraform   = "true"
        CastAI      = "true"
      }
    }
  }

  # Node template for spot instances
  node_templates = {
    default_by_castai = {
      configuration_id = module.castai_eks_cluster.castai_node_configurations["default"]
      should_taint     = false

      constraints = {
        on_demand          = true
        spot               = true
        use_spot_fallbacks = true
        min_cpu            = 2
        max_cpu            = 32
        architectures      = ["amd64"]
      }
    }
  }

  # Autoscaler settings
  autoscaler_settings = {
    enabled                                 = true
    node_templates_partial_matching_enabled = false

    unschedulable_pods = {
      enabled = true
    }

    node_downscaler = {
      enabled = true

      empty_nodes = {
        enabled = true
      }

      evictor = {
        aggressive_mode           = false
        cycle_interval            = "5m10s"
        enabled                   = true
        node_grace_period_minutes = 10
        scoped_mode               = false
      }
    }

    cluster_limits = {
      enabled = true
      cpu = {
        min_cores = 2
        max_cores = 100
      }
    }
  }

  # Ensure proper dependency ordering
  depends_on = [
    module.eks,
    module.castai_eks_role_iam,
    aws_iam_instance_profile.castai_node_profile
  ]
}

# Scale down the managed node group ASG to 1 after CastAI is ready
# This allows CastAI to take over all node management
resource "null_resource" "scale_down_managed_nodes" {
  # Only run after CastAI cluster module is fully deployed
  depends_on = [module.castai_eks_cluster]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting 60 seconds for CastAI to stabilize..."
      sleep 60

      echo "Scaling down managed node group ASG to 1..."
      ASG_NAME="${module.eks.eks_managed_node_groups["node_group_1"].node_group_autoscaling_group_names[0]}"

      aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name "$ASG_NAME" \
        --min-size 1 \
        --desired-capacity 1 \
        --region ${var.aws_region}
      echo "ASG $ASG_NAME scaled to 1"
    EOT
  }

  # Re-run if cluster name changes
  triggers = {
    cluster_name = local.cluster_name
  }
}
