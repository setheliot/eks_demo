# Tear-down (clean up) all the resources - explained


We enforce the following specific order of destruction:
* `Deployment` → `PersistentVolumeClaim` → EKS Cluster

This is the order required for a clean removal when using `terraform destroy`. This allows the cluster controllers to handle necessary cleanup operations.
1. Remove the `Deployment` first to allow cluster controllers to properly delete the pods.
   - Pods must be deleted before the `PersistentVolumeClaim`; otherwise, the deletion process will hang.
1. Remove the `PersistentVolumeClaim` while the cluster is still active to ensure controllers properly detach and delete the EBS volume.
1. Then delete everything else.

---
## What is going on here?

When a single `terraform destroy` command is used to destroy everything, destruction of the `Deployment` and `ReplicaSet` does _not_ delete the pods. Some _other_ resource needed by the cluster controllers (possibly a component of the VPC), is getting destroyed before the `Deployment` is.

This in turn prevents the `PersistentVolumeClaim` from deleting, because it is being used by the pods.

It is possible that a critical VPC component impacts communication between the Kubernetes control plane and the AWS control plane, or something similar.

This problem with `terraform destroy` can be solved by adding the following to the `module "eks"` block:

```
  depends_on = [ module.vpc ]
```

This forces destruction of the VPC to wait until after destruction of the EKS cluster.

### But... this introduced new problems

* It takes much longer to deploy resources with `apply`

* Deploying resources with `apply` becomes unreliable. 

  The change in dependency and timing introduces a new issue where Terraform attempts to create Kubernetes resources _before_ the proper RBAC configurations are applied (e.g., `ClusterRoles`, `RoleBindings`). These resources then fail with errors like

    ```
    Error: serviceaccounts is forbidden: User "arn:aws:sts::12345678912:assumed-role/MyAdmin" cannot create resource "serviceaccounts" in API group "" in the namespace "default"
    ```

  After the `apply` failure, running the same exact `apply` command then succeeds, because by that time the RBAC have propagated. 

* Time to tear-down resources with `destroy` also seems longer

### The goal of this repository is to show how to create these resources

For this repo, the focus is on education and simplicity in creating these resources; therefore, it will not use the `depends_on` fix.

Also this repo aims to show best practices, and in general it is a best practice to let Terraform determine dependency relationships.

### How else might we handle this?

Using [separate distinct Terraform configurations](./separate_configs.md) is the best way to address this issue.
