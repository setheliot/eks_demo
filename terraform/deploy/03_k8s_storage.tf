###############################################################################
#
# PERSISTENT STORAGE WITH EBS CSI DRIVER
#
# Logical order: 03
##### "Logical order" refers to the order a human would think of these executions
##### (although Terraform will determine actual order executed)
#
###############################################################################
# Kubernetes storage concepts:
#
# 1. CSI Driver (Container Storage Interface)
#    - A standardized way to expose storage systems to Kubernetes
#    - The EBS CSI Driver lets K8s create/attach/mount EBS volumes automatically
#    - Installed as an EKS add-on in 01_infrastructure.tf
#
# 2. StorageClass
#    - Defines "classes" of storage (like gp3, io1, etc.)
#    - Tells K8s how to provision new volumes (what type, encryption, etc.)
#
# 3. PersistentVolumeClaim (PVC)
#    - A request for storage by a pod
#    - "I need 10Gi of storage from the 'ebs-storage-class'"
#
# 4. PersistentVolume (PV)
#    - The actual storage resource (an EBS volume in our case)
#    - Created automatically when a pod uses the PVC (dynamic provisioning)
#
# Flow: Pod references PVC -> PVC triggers StorageClass -> CSI Driver creates EBS -> PV bound to PVC
###############################################################################

###############################################################################
# IAM PERMISSIONS FOR EBS CSI DRIVER
###############################################################################
# The CSI driver needs permissions to create, attach, and delete EBS volumes.
# AWS provides a managed policy for this.
###############################################################################
data "aws_iam_policy" "csi_policy" {
  name = "AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "csi_policy_attachment" {
  policy_arn = data.aws_iam_policy.csi_policy.arn
  role       = module.eks.eks_managed_node_groups["node_group_1"].iam_role_name
}

###############################################################################
# STORAGE CLASS
###############################################################################
# The StorageClass defines what kind of EBS volumes to create.
# When a PVC requests storage from this class, the CSI driver provisions
# an EBS volume with these specifications.
###############################################################################
resource "kubernetes_storage_class" "ebs" {
  metadata {
    name = "ebs-storage-class"
    annotations = {
      # Make this the default - PVCs without a class will use this
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # The CSI driver that handles provisioning
  # Docs: https://github.com/kubernetes-sigs/aws-ebs-csi-driver
  storage_provisioner = "ebs.csi.aws.com"

  # What happens when the PVC is deleted?
  reclaim_policy = "Delete"

  # WaitForFirstConsumer: Don't create the EBS volume until a pod actually
  # needs it. This ensures the volume is created in the same AZ as the pod.
  # Without this, you might get: volume in us-east-1a, pod scheduled in us-east-1b = failure!
  volume_binding_mode = "WaitForFirstConsumer"

  # EBS volume configuration
  # Docs: https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html
  parameters = {
    type      = "gp3"    # General Purpose SSD v3 - best price/performance for most workloads
    fsType    = "ext4"   # Linux filesystem type
    encrypted = "true"   # Encrypt data at rest (security best practice)
  }

  depends_on = [module.eks]
}


###############################################################################
# PERSISTENT VOLUME CLAIM
###############################################################################
# A PVC is a request for storage. Our app will mount this to persist data.
# The actual EBS volume isn't created until a pod uses this PVC
# (because of WaitForFirstConsumer above).
###############################################################################
resource "kubernetes_persistent_volume_claim_v1" "ebs_pvc" {
  metadata {
    name = local.ebs_claim_name
  }

  spec {
    # ReadWriteOnce: Volume can be mounted read-write by ONE node
    # This is the only mode EBS supports (it's a block device attached to one EC2)
    # Note: Multiple pods on the SAME node can share it
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Gi" # Request 1 GiB of storage
      }
    }

    storage_class_name = "ebs-storage-class"

  }

  # IMPORTANT: Don't wait for the PVC to bind to a PV
  # With WaitForFirstConsumer, binding only happens when a pod uses this PVC.
  # Without this flag, Terraform would hang indefinitely waiting for binding.
  wait_until_bound = false

  depends_on = [module.eks]
}

###############################################################################
# What happens next:
# 1. Terraform creates the PVC (status: Pending - no volume yet)
# 2. When a pod references this PVC, the scheduler picks a node
# 3. CSI driver creates an EBS volume in the node's AZ
# 4. CSI driver attaches the EBS to the node and mounts it in the pod
# 5. PVC status changes to Bound
###############################################################################