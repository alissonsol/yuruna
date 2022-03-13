# `yuruna` website example

A simple .NET C# website container deployed to a Kubernetes cluster.

## End-to-end deployment

Below are the end-to-end steps to deploy the `website` project to `localhost` (assuming Docker is installed and Kubernetes enabled). The execution below is from the `automation` folder. You may need to start PowerShell (`pwsh`).

Before deploying, seek for `TO-SET` in the config files and set the required values. See section "Cloud deployment instructions".

**IMPORTANT**: Before proceeding, read the Connectivity section of the [Frequently Asked Questions](../../docs/faq.md).

- Create resources

```shell
./yuruna.ps1 resources ../examples/website localhost
```

- Build the components

```shell
./yuruna.ps1 components ../examples/website localhost
```

- Deploy the  workloads

```shell
./yuruna.ps1 workloads ../examples/website localhost
```

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

## Cloud deployment instructions

### DNS

- Before executing `./yuruna.ps1 workloads` please confirm that the `yrn42website-domain` DNS entry (example: www.yrn42.com) already points to the `frontendIp`.
  - After resource creation, you will get the Terraform output with the `frontendIp`. From the configuration interface for your DNS provider, point the `yrn42website-domain` to that IP address.
    - Another option to test is: `curl -v http://{frontendIp} -H 'Host: {yrn42website-domain}'`.
    - Yet another option: add an entry to your `hosts` folder pointing `yrn42website-domain` to the resulting value for`frontendIp`. Don't forget to remove it!

### Azure

- Search for `TO-SET`
  - Azure requires a globally unique registry name.
    - Ping `yourname.azurecr.io` to confirm that a name is not already in use.
- Afterward, execute the same commands above, replacing `localhost` with `azure`.
- In Azure, if the `EXTERNAL-IP` for the `nginx-ingress` is still loading after several minutes
  - Check if there is an event starting with `Error syncing load balancer: failed to ensure load balancer: ensurePublicIPExists for service...`
  - Make sure the `azure-dns-label-name` in the Helm deployment has the same label of the `frontendIp` public IP. You can verify that in the <https://portal.azure.com>. Hint: it is the cluster name!
- In AKS, if you need to rerun the `workloads`, your IP Address may be deleted when the previous ingress controller is deleted. Check how to lock the IP resource in this [issue](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).

Back to main [readme](../../README.md). Back to list of [examples](../README.md).
