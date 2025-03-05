# Single Terraform configuration or multiple ones?

The approach taken here is a single Terraform config that creates everything. This includes AWS resources, the EKS Cluster, Kubernetes resources and the application deployment (which is a Kubernetes resource that sets up pods running a container).

Being in a single Terraform config simplifies creation, and requires only a single `terraform apply` command. This is the right approach for this demo repo and its goals to introduce the concepts of AWS EKS **Auto Mode**, and enable users to set up a working cluster and application quickly.

Another approach, which may be better for production deployments (and cleanup), is to separate Terraform into two distinct configurations:

1. **Infrastructure Configuration:** Deploys AWS resources such as the VPC, EKS cluster, and DynamoDB table.  
2. **Kubernetes Configuration:** Deploys Kubernetes resources, including application code as part of the `Deployment`.

This separation ensures that 
* On `apply`, the EKS cluster is fully functional with credentials propagated and controllers running before Kubernetes resources are deployed 
* On `destroy`, Kubernetes resources can be cleaned up properly while the cluster and VPC remain intact.

For this repo the focus is on education and simplicity to _create_ these resources; therefore, it retains the _single_ Terraform configuration approach.

---
### Single Terraform config challenges

Putting Kubernetes resources in the same Terraform configuration as the Kubernetes cluster creation leads to errors when Terraform tries to create the Kubernetes resources before the cluster is completely read.

The workaround applied here to ensure the Kubernetes Cluster is fully functional before Kubernetes resources are deployed is:
- Add a timer at to the eks module that runs after cluster creation is complete
- However most Kubernetes resources will not wait for this timer. They are not actually dependent on the eks module, but only need the [Kubernetes provider](https://github.com/setheliot/eks_auto_mode/blob/main/terraform/providers.tf#L32) online before they start. The Kubernetes provider has everything it needs at Cluster creation (before the timer even starts).
- Therefore I added `depends_on = [module.eks]` to all Kubernetes resources. This forces them to wait for the  timer.
