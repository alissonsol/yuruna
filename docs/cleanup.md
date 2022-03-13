# `yuruna` resources clean up

**These instructions will destroy resources**. Make sure you enter the correct parameters.

## Cleaning up automatically

Execute the following command to clear the resources for a given configuration.

```shell
yuruna clear [project_root] [config_subfolder]
```

Clearing the resources for the project `website` in the `Azure` cloud (assuming [authentication](authenticate.md) steps were followed).

```shell
./yuruna.ps1 clear ../examples/website azure
```

If needed, resources can be deleted by executing the command below from the folder with the initial deployment files (`.yuruna/resources/$resourceTemplate`)

```shell
terraform destroy -auto-approve -refresh=false
```

In some cases, that command doesn't find the resources to destroy (`0 destroyed`). It needs the created `.terraform` folder to be still available. If that was removed, you should follow the instructions below for manually cleaning resources.

Don't forget to delete the cluster context from `[user]/.kube/config`. That can be easily done using the [Visual Studio Code](https://code.visualstudio.com/) extension for [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools). It can also be done from the command line with [kubectl](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-delete-context-em-).

## Manually cleaning up AWS resources

- From the [AWS Management Console](https://console.aws.amazon.com/), delete clusters, registries, VPCs, IPs and other resources.

## Manually cleaning up Azure resources

- From the [Azure Portal](https://portal.azure.com), delete the "Azure Resource Groups" that have been created. Deleting the resource groups will delete all associated resources.
  - There will be a global resource for registry and clusters. For each Kubernetes cluster, there will be a corresponding AKS node resource group (see [AKS faq](https://docs.microsoft.com/en-us/azure/aks/faq)). Those are named with the suffix "_nodes".

## Manually cleaning up GCP resources

- From the [GCP Console](https://console.cloud.google.com/), delete any resources that were previous created.

Back to main [readme](../README.md)
