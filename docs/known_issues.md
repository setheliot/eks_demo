### 1. `terraform apply` fails with authentication errors when creating some Kubernetes resources

The following Kubernetes resources are affected:
`StorageClass`, `PersistentVolumeClaim`, `ServiceAccount`, `Deployment`

The errors reported for each of these look like this:

```
│ Error: storageclasses.storage.k8s.io is forbidden: User "arn:aws:sts::253490795979:assumed-role/SethAdmin/aws-go-sdk-1738171484847914000" cannot create resource "storageclasses" in API group "storage.k8s.io" at the cluster scope
│
│   with kubernetes_storage_class.ebs,
│   on 02_k8s_resources.tf line 19, in resource "kubernetes_storage_class" "ebs":
│   19: resource "kubernetes_storage_class" "ebs" {
```
#### Cause

Although the EKS Cluster deployment is completed, Terraform attempted to create these resources before all cluster functionality is available. In this case, it could have been due to RBAC Role Bindings not yet being completed.

#### How to fix

Re-run the `terraform apply` command. The cluster has had time to become fully functional and the previously failed resources will succeed.

##### That feels like a workaround. What is the real fix?

* See this note on using [separate distinct Terraform configurations](./separate_configs.md)

#### Other notes
When creating the EKS cluster, the `dataplane_wait_duration` variable has been increased from its default 30s to 60s, to address this issue.

If you are using timeouts to fix an issue though, then you have not _fixed_ it, you have only decreased how often it will happen. 🤷‍♂️

Note: This issue should be solved by [this](./separate_configs.md#single-terraform-config-challenges).

### 2. `terraform init` fails with checksum violation

```
$ terraform init                                                                      [18:29:20]
Initializing the backend...
╷
│ Error: Error refreshing state: state data in S3 does not have the expected content.
│
│ The checksum calculated for the state stored in S3 does not match the checksum
│ stored in DynamoDB.
| ...
```

#### Cause

Your workspace has reset to "default," which has no state, and therefore fails checksum

### Hot to fix

```
terraform workspace select <env_name>

terraform init
```
