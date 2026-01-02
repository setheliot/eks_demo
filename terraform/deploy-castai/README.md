# EKS Cluster Using Cast AI

[Cast AI](https://cast.ai/) is a platform for managing Kubernetes clusters, including EKS

This terraform will create a cluster using an EKS Cluster managed by Cast AI. The cluster runs a sample app.

The terraform provided here is _experimental_.
* It is temperamental and may not always work -- you are using at you own risk
* This is for educational purposes _only_ -- do NOT use for any production workloads

To install this:
* First set your Cast AI API Key
```bash
export TF_VAR_castai_api_key=<key>
```
* Then follow the directions in [Option 2 in the main README](../../README.md#option-2-for-those-familiar-with-using-terraform).
  * But _instead_ of using the `terraform/deploy` directory, use `terraform/deploy-castai` 

To `destroy` please use the [`cleanup_cluster.sh`](../../scripts/cleanup_cluster.sh) script. Do not use `terraform destroy` as this will hang and leave orphaned resources (see [here](../../docs/cleanup.md) for why this happens).

