###############
#
# Deploy containers to run application code, and a Load Balancer to access the app
#
# Logical order: 05
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#


# Define the app name
locals {
  app_name = "guestbook-${local.prefix_env}"
}

# This defines the kubernetes deployment for the guestbook (XYZ) app
resource "kubernetes_deployment_v1" "guestbook_app_deployment" {
  metadata {
    name = "${local.app_name}-deployment"
    labels = {
      app = local.app_name
    }
  }

  spec {
    replicas = 3
    selector {
      match_labels = {
        app = local.app_name
      }
    }
    template {
      metadata {
        labels = {
          app = local.app_name
        }
      }
      spec {
        service_account_name = local.ddb_serviceaccount
        container {
          # Application is from here https://github.com/setheliot/xyz_app_poc/tree/main/src 
          # Improvements and pull requests welcomed!
          image = "ghcr.io/setheliot/xyz-demo-app:latest"
          name  = "${local.app_name}-xyz-demo-app-container"

          port {
            container_port = 80
          }

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }

          # Mount the PVC as a volume in the container
          volume_mount {
            name       = "ebs-k8s-attached-storage"
            mount_path = "/app/data" # Path inside the container
          }

          # Store the DDB Table name for use by the container
          env {
            name  = "DDB_TABLE"
            value = aws_dynamodb_table.guestbook.name
          }

          # Add environment variable using Kubernetes Downward API to get node name
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          # Add environment variable for the region
          env {
            name  = "AWS_REGION"
            value = var.aws_region # This is the region where the EKS cluster is deployed
          }
        } #container

        # Define the volume using the PVC
        volume {
          name = "ebs-k8s-attached-storage"

          persistent_volume_claim {
            claim_name = local.ebs_claim_name
          }
        } #volumes
      }   #spec (template)
    }     #template
  }       #spec (resource)

  # Give time for the cluster to complete (controllers, RBAC and IAM propagation)
  # See https://github.com/setheliot/eks_demo/blob/main/docs/separate_configs.md
  depends_on = [module.eks]
}

# Create ALB 

module "alb" {

  depends_on = [module.eks]

  source     = "./modules/alb"
  prefix_env = local.prefix_env
  app_name   = local.app_name

  count = var.use_alb ? 1 : 0
}

output "alb_dns_name" {
  value = var.use_alb ? module.alb[0].alb_dns_name : "(ALB not provisioned)"
}


###############
# Create NLB
# module "nlb" {
#   source     = "./modules/nlb"
#   prefix_env = local.prefix_env
#   app_name   = local.app_name
#   count      = var.use_alb ? 0 : 1
# }
# 
# output "nlb_dns_name" {
#   value = var.use_alb ? "(This app uses an ALB)" : module.legacy-nlb[0].nlb_dns_name
# }

