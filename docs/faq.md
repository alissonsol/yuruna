# `yuruna` Frequently Asked Questions

## Connectivity

- Why I cannot connect to <https://localhost> in a Windows machine?

  - Try to stop HTTP and related processes.
    - Find which process is holding port 80: `netstat -nao | find ":80"`
    - You may need to stop the Web service: `net stop http`
      - That may be hard due to issues like [HTTP services can't be stopped when the Microsoft Web Deployment Service is installed](https://docs.microsoft.com/en-us/troubleshoot/iis/http-service-fail-stopped). Try to stop that service also (`net stop msdepsvc`), reboot, and try steps again.
  - If you run `net stop http` again and still see a service `BranchCache` that keeps needing to be stopped then disable it using the PowerShell cmdlet [`Disable-BC`](https://docs.microsoft.com/en-us/powershell/module/branchcache/disable-bc).

- Browsing to a container via port forward works but not via the ingress in a localhost deployment.

  - Before deploying workloads, make sure that ports to be used are not held by other processes. It is also common that, in the `localhost`, the Docker Desktop process itself holds on to the ports, preventing the local load balancer from binding (see example of [issue](https://github.com/docker/for-mac/issues/4903) repeatedly reported).
  - Solving that may require quitting and starting Docker again (suprisingly, the Restart item in the menu doesn't have the same effect).

- Example doesn't work if executed twice or after another example.

  - If you run an example, clear it, and port 80 is still in use, try quitting Docker and starting again.
  - Check if the ports are exposed to the external IP address: `kubectl get svc --all-namespaces`

- Why the local registry is not working in the macOS?

  - For macOS Monterey, confirm that port 5000 is not in use and stop any service using it. See Stack Overflow [issue](https://stackoverflow.com/questions/69818376/localhost5000-unavailable-in-macos-v12-monterey).
    - See instructions on how to check port usage in the macOS in this [article](https://stackoverflow.com/questions/4421633/who-is-listening-on-a-given-tcp-port-on-mac-os-x).
      - Recent versions of macOS: `lsof -nP -iTCP -sTCP:LISTEN | grep 80`

- Why applications from inside the container cannot connect to outside?

  - Many possibilities. Start by verifying that the `kube-proxy` can connect to the location IP address.
  - Find the IP address of the localhost (`ipconfig` or `ifconfig`).
  - Connect to a terminal in the `kube-proxy` container.
  - It is likely that you need to install `ping`
    - `apt-get update && apt-get install -y net-tools iputils-ping dnsutils`
  - Now ping to the localhost address or any other in the local network or remote as the first debugging step.

***

## General

- What is the answer to the ultimate question of life, the universe, and everything?
  - `42`. That is why every example has the easy to find and replace prefixes starting with `yrn42`.

- I've created cloud resources and components in a machine and moved to develop in another one. Is that possible?
  - Yes. You just need to import the cluster context and the resources.output.yml. The command to import the cluster context should be in the `cluster.tf` for the resource template. You may also try to [merge the Kubernetes configuration](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

- In Windows, got the message: `Error: can't find external program "pwsh"`
  - Check that you have PowerShell version 7.1, with the command `$PSVersionTable`. See latest setup instructions at <https://aka.ms/powershell>.

Back to main [readme](../README.md)
