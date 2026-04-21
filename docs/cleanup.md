# Yuruna Resources Clean Up

**These instructions will destroy resources**. Make sure you enter the correct parameters.

## Cleaning up automatically

Execute the following command to clear the resources for a given configuration.

```shell
Invoke-Clear.ps1 [project_root] [config_subfolder]
```

Clearing the resources for the project `website` in the `Azure` cloud (assuming [authentication](authenticate.md) steps were followed).

```shell
Invoke-Clear.ps1 website azure
```

If needed, you can delete resources directly from the folder with the initial deployment files (`.yuruna/resources/$resourceTemplate`):

```shell
tofu destroy -auto-approve -refresh=false
```

This command needs the created `.terraform` folder to still be available. Without it you'll see `0 destroyed` — follow the manual cleanup instructions below instead.

Don't forget to delete the cluster context from `[user]/.kube/config`. The [Visual Studio Code](https://code.visualstudio.com/) [Kubernetes extension](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools) or [`kubectl`](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-delete-context-em-) can both do this.

## Manually cleaning up AWS resources

- From the [AWS Management Console](https://console.aws.amazon.com/), delete clusters, registries, VPCs, IPs and other resources.

## Manually cleaning up Azure resources

- From the [Azure Portal](https://portal.azure.com), delete the "Azure Resource Groups" that have been created. Deleting the resource groups will delete all associated resources.
  - There will be a global resource for registry and clusters. For each Kubernetes cluster, there will be a corresponding AKS node resource group (see [AKS faq](https://learn.microsoft.com/en-us/azure/aks/faq)). Those are named with the suffix "_nodes".

## Manually cleaning up GCP resources

- From the [GCP Console](https://console.cloud.google.com/), delete any resources that were previously created.

Back to [[Yuruna](../README.md)]
