# Yuruna Hacks

Some notes and hacks learned during the development process.

## Files not changed

Some files are set `assume-unchanged` by scripts that modify the values saved into them. Revert that with the command `git update-index --really-refresh`.

## Note about Docker registry names

It is common for cloud providers to demand a unique registry name and corresponding ([FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name)). Changing the registry name may require changes in the file `config/deployment.yml`.

## Hack to workaround Kubernetes context collision

You can keep contexts simultaneously pointing to the clusters in different clouds by using the [config rename-context](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-rename-context-em-) option for `kubectl`.

```shell
kubectl config rename-context old-name new-name
```

## Troubleshooting the automated certificate issuing process

- Check the [cert-manager.io FAQ](https://cert-manager.io/docs/faq/acme/)
  - Under the cluster `Custom Resources`, check the `certificaterequests`
  - Notice this sentence from [Syncing Secrets Across Namespaces](https://cert-manager.io/docs/faq/kubed/): "Wildcard certificates are not supported with HTTP01 validation and require DNS01"
    - See documentation on [Challenge Types](https://letsencrypt.org/docs/challenge-types/)

## Hack to debug issues from container

The containers have minimal software installed. Even to ping you have to install it.

```shell
apt-get update
apt-get install -y iputils-ping
```

Then, if you want to build a project outside, you may need to use `dotnet restore`, then `dotnet build` and `dotnet run`. For the restore step to work, you may need to have [`nuget`](https://docs.microsoft.com/en-us/nuget/install-nuget-client-tools) installed and in the path. Then, in what is really the reason for the information to be here in the "hacks" page: at times you first have to execute `nuget restore [name].proj` ahead of `dotnet restore [name].proj`.

See also [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx/tree/master/docs/examples/grpc) for debugging instructions.

## Docker and Kubernetes issues

Usually, the Docker functionality to `Reset to factory defaults` is the best path to a solution. It is under the "Troubleshoot" menu (which somehow looks like a question mark, and more like a help button!).

Afterward, remove the `~/.kube` folder and enable Kubernetes again (this loses at least some configuration, and possibly data).

For the error
```shell
docker-credential-desktop executable file not found in $PATH
```

In ~/.docker/config.json change credsStore to credStore. That temporarily disables credentials for docker.

 You can either remove the credsStore entry to store credentials directly in the config file or install a suitable credential helper (like osxkeychain or wincred) and update the credsStore value accordingly. 

## Azure deletes static IP when deleting an ingress using it

This is an unexpected Azure behavior, confirmed by this post: [How to make Azure not delete Public IP when deleting service / ingress-controller?](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle). Following the workaround also has its side-effects. It is better to `clear`, and then rebuild everything (`resources`, `components`, and `workloads`).

## Invoke-Expression: Cannot bind argument to parameter 'Command' because it is an empty string.

Usually due to an executed `shell` expression that doesn't return anything. Add `$true` to the end of the expression.

## Debug service

Edit until it works using `kubectl edit svc [service-name] -n [namespace-name]`. The same is valid for other kinds of artifacts (configMaps, pods, etc.). Then try to create the sequence of `kubectl patch` statements to guarantee the artifact will get to the right state.

## Debugging localhost issues

A workaround after deploying resources and components is to reset the Kubernetes cluster in Docker and reconnect the contexts. There is a PowerShell script named `context-copy` under the automation folder that can be used for this. The context names that may need to be reconnected are listed in the `resources.output.yml` file; deleting those contexts ahead of time avoids issues. Then, use `context-copy [sourceContextName] [destinationContextName]`.

GitHub issue documenting need to restart Docker: <https://github.com/docker/for-mac/issues/4903>

## PodSecurityPolicy

- Check with `kubectl get psp -A`
- Delete with `kubectl delete psp [name]`

Back to the main [readme](../README.md)
