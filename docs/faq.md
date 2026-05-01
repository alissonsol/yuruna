# Yuruna Frequently Asked Questions

## Connectivity

### Why does connection to <http://localhost> fail?

  - Windows-specific: stop HTTP and related processes.
    - Find what's holding port 80: `netstat -nao | find ":80"`.
    - Stop the Web service: `net stop http`.
      - Blocked by [HTTP services can't be stopped when the Microsoft Web Deployment Service is installed](https://learn.microsoft.com/en-us/troubleshoot/iis/http-service-fail-stopped) → also `net stop msdepsvc`, reboot, retry.
    - If `BranchCache` keeps needing a stop, disable it via [`Disable-BC`](https://learn.microsoft.com/en-us/powershell/module/branchcache/disable-bc).
  - Browser [HSTS](https://en.wikipedia.org/wiki/HTTP_Strict_Transport_Security): remove localhost (or your dev site) from the [preloaded HSTS list](https://www.chromium.org/hsts/). In the browser, open `about://net-internals#hsts` → under "Delete domain security policies" type the site → Delete.

### Why does browsing to a container work via port forward but not via the ingress in a localhost deployment?

  - Confirm the required ports aren't held by other processes before deploying. On `localhost`, Docker Desktop itself often holds them ([docker/for-mac#4903](https://github.com/docker/for-mac/issues/4903)). Quit and restart Docker (Restart menu item is not enough).

### Why doesn't an example work if executed twice or after another example?

  - Run, clear, port 80 still busy → quit Docker and start again.
  - Check exposed ports: `kubectl get svc --all-namespaces`.

### Why is the local registry not working on macOS?

  - macOS Monterey: confirm port 5000 isn't in use ([SO](https://stackoverflow.com/questions/69818376/localhost5000-unavailable-in-macos-v12-monterey)). Recent macOS: `lsof -nP -iTCP -sTCP:LISTEN | grep 5000`.

### Why can't applications inside the container connect to the outside?

  - Verify `kube-proxy` can reach the host IP. Find the host IP (`ipconfig`/`ifconfig`). Exec into `kube-proxy`, install `ping` if needed (`apt-get update && apt-get install -y iputils-ping`), and ping outward.

---

## General

### What is the answer to the ultimate question of life, the universe, and everything?

  - `42`. That's why every example uses easily-found-and-replaced prefixes starting with `yrn42`.

### I've created cloud resources and components on one machine and moved to develop on another. Is that possible?

  - Yes. Import the cluster context and `resources.output.yml`. The import command is in the resource template's `cluster.tf`. See also [merging Kubernetes configurations](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

### Why do I get `Error: can't find external program "pwsh"`?

  - Check PowerShell 7.5+ via `$PSVersionTable`. Setup: <https://aka.ms/powershell>.

Back to [[Yuruna](../README.md)]
