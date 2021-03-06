# `yuruna` website example

A simple .NET C# website container deployed to a Kubernetes cluster.

## Search and replace

What to search and replace in order to reuse this project as the basis for a new one. Search in case-sensitive mode.

- yrn42website-prefix -> Common project prefix for containers. Example: yrn42
- yrn42website-ns -> Kubernetes namespace for installing containers. Example: yrn42
- yrn42website-dns -> DNS prefix. Example: yrn42
- yrn42website-rg -> Name for group of resources (Azure). Example: yrn42
- yrn42website-tags -> Resource tags. Example: yrn42
- yrn42website-domain -> Domain for web email, site. Example: yrn42.com
- yrn42website-cluster -> Name for the K8S cluster (or at least a common prefix). Example: yrn42
- yrn42website-uxname -> Name for site in the UX (This will be visible to end users). Example: yrn42

Despite the several placeholders enabling reuse in different configurations, it is recommended to replace as many valuables as possible to become identical, easing future maintenance. Replace `yrn42website-domain` first and then use this regular expression to search and replace the others:  `(yrn42website)[A-Za-z0-9\-]*`

Before deploying to the cloud environments, seek for `TO-SET` and set the required values. See section "Cloud deployment instructions".

## End to end deployment

Below are the end-to-end steps to deploy the `website` project to `localhost` (assuming Docker is installed and Kubernetes enabled). Execution below is from the `automation` folder. You may need to start PowerShell (`pwsh`).

- Create resources

```shell
./yuruna.ps1 resources ../projects/examples/website localhost
```

- Build the components

```shell
./yuruna.ps1 components ../projects/examples/website localhost
```

- Deploy the  workloads

```shell
./yuruna.ps1 workloads ../projects/examples/website localhost
```

*NOTE*: In AKS, if you need to rerun the `workloads`, your IP Address may be deleted when the previous ingress controller is deleted. Check how to lock the IP resource in this [issue](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).

## Resources

Terraform will be used to create the following resources:

- A Kubernetes cluster
- A container registry
- A public IP address

As output, the following values will become available for later steps:

- ${env:registryName}.registryLocation
- ${context.name}.clusterIp
- ${context.name}.frontendIp
- ${context.name}.hostname

## Components

- A Docker container image for a .NET C# website.
- NGINX Ingress Controller, which will be installed using a [Helm chart](https://kubernetes.github.io/ingress-nginx/deploy/#using-helm).

## Workloads

- The frontend/website will be deployed to the cluster.
- NGINX controller will be deployed to the cluster redirecting ports to the website.

## Validation

- Check you can navigate to the endpoint reported after publishing the workloads.
- Check services are available with the command: `kubectl get services --all-namespaces`
- Check cluster events with the command: `kubectl get events --all-namespaces`
- In Azure, if the `EXTERNAL-IP` for the `nginx-ingress` is still loading after several minutes
  - Check if there is an event starting with `Error syncing load balancer: failed to ensure load balancer: ensurePublicIPExists for service...`
  - Make sure the `azure-dns-label-name` in the Helm deployment has the same label of the `frontendIp` public IP. You can verify that in the <https://portal.azure.com>. Hint: it is the cluster name!

## Cloud deployment instructions

### DNS

- Before executing `./yuruna.ps1 workloads` please confirm that the `yrn42website-domain` DNS entry (example: www.yrn42.com) already points to the `frontendIp`.
  - After resource creation, you will get the Terraform output with the `frontendIp`. From the configuration interface for your DNS provider, point the `yrn42website-domain` to that IP address.
    - Another option to test is: `curl -v http://{frontendIp} -H 'Host: {yrn42website-domain}'`.
    - Yet another option: add an entry to your `hosts` folder pointing `yrn42website-domain` to the resulting value for`frontendIp`. Don't forget to remove it!

### Azure

- Search for `TO-SET`
  - Azure requires a globally unique registry name.
    - Ping `yourname.azurecr.io` and confirm that name is not already in use.
    - Set the value just to the unique host name, like `yrn42website` (not `yrn42website.azurecr.io`).
  - The current value is intentionally left empty so that validation will point out the need to edit the files.
- Afterwards, execute the same commands above, replacing `localhost` with `azure`.

Back to main [readme](../../../README.md). Back to list of [examples](../README.md).
