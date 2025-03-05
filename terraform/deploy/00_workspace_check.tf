###############
#
# As a convention (and enforced here) users deploying these resources should use a terraform workspace
# that matches the env_name from the .tfvars file they are using. This prevents name conflicts within a region
# as well as for global resources (like IAM roles).
#
# Logical order: 00 
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#

# Fetch the current workspace name
locals {
  current_workspace = terraform.workspace
}

# Log a failure and quit if the workspace does not match `var.env_name`
resource "null_resource" "check_workspace" {
  count = local.current_workspace != var.env_name ? 1 : 0

  provisioner "local-exec" {
    command = <<EOT
      echo "Error: Current workspace (${local.current_workspace}) does not match expected environment name (${var.env_name}). Exiting...";
      exit 1
    EOT
  }
}
