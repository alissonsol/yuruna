# Yuruna Frequently Asked Questions

## Connectivity

### Why does connection to <http://localhost> fail?

  - Windows-specific: Try to stop HTTP and related processes.
    - Find which process is holding port 80: `netstat -nao | find ":80"`
    - You may need to stop the Web service: `net stop http`
      - That may be hard due to issues like [HTTP services can't be stopped when the Microsoft Web Deployment Service is installed](https://learn.microsoft.com/en-us/troubleshoot/iis/http-service-fail-stopped). Try to stop that service also (`net stop msdepsvc`), reboot, and try steps again.
    - If you run `net stop http` again and still see a service `BranchCache` that keeps needing to be stopped, then disable it using the PowerShell cmdlet [`Disable-BC`](https://learn.microsoft.com/en-us/powershell/module/branchcache/disable-bc).
  - Browser issue: [HSTS](https://en.wikipedia.org/wiki/HTTP_Strict_Transport_Security) requirement
    - You may need to remove localhost or another site used during development from the list of [preloaded HSTS sites](https://www.chromium.org/hsts/) for your browser.
    - Navigate to `about://net-internals#hsts` in the browser address bar
      - Under "Delete domain security policies", type the site (example `localhost`) and press the "Delete" button.

### Why does browsing to a container work via port forward but not via the ingress in a localhost deployment?

  - Before deploying workloads, confirm the required ports aren't held by other processes. On `localhost`, Docker Desktop itself commonly holds these ports, preventing the local load balancer from binding (see [this repeatedly-reported issue](https://github.com/docker/for-mac/issues/4903)).
  - Fixing it usually requires quitting and restarting Docker (the Restart menu item does not have the same effect).

### Why doesn't an example work if executed twice or after another example?

  - If you run an example, clear it, and port 80 is still in use, quit Docker and start again.
  - Check which ports are exposed: `kubectl get svc --all-namespaces`

### Why is the local registry not working on macOS?

  - On macOS Monterey, confirm port 5000 is not in use and stop any service using it. See Stack Overflow [issue](https://stackoverflow.com/questions/69818376/localhost5000-unavailable-in-macos-v12-monterey).
    - To check port usage on macOS, see this [article](https://stackoverflow.com/questions/4421633/who-is-listening-on-a-given-tcp-port-on-mac-os-x). Recent macOS: `lsof -nP -iTCP -sTCP:LISTEN | grep 80`

### Why can't applications inside the container connect to the outside?

  - Many possibilities. Start by verifying `kube-proxy` can reach the host IP.
  - Find the localhost IP (`ipconfig` or `ifconfig`).
  - Connect to a terminal in the `kube-proxy` container. You may need to install `ping`: `apt-get update && apt-get install -y net-tools iputils-ping dnsutils`
  - Ping the localhost address or another local/remote host as the first debugging step.

---

## General

### What is the answer to the ultimate question of life, the universe, and everything?

  - `42`. That is why every example has the easy to find and replace prefixes starting with `yrn42`.

### I've created cloud resources and components on one machine and moved to develop on another. Is that possible?

  - Yes. Import the cluster context and the `resources.output.yml`. The cluster-context import command is in the `cluster.tf` for the resource template. You can also [merge the Kubernetes configuration](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

### Why do I get the error message: `Error: can't find external program "pwsh"`

  - Check that you have PowerShell version 7.5+, with the command `$PSVersionTable`. See latest setup instructions at <https://aka.ms/powershell>.

Back to [[Yuruna](../README.md)]
