# k8s

Installs the Kubernetes requirements: SSH, Git, Docker, Kubernetes, PowerShell, Helm, OpenTofu, mkcert, Graphviz, and Cloud CLIs (Azure, AWS, Google Cloud).

See the full list of [requirements](../../docs/requirements.md) for more details.

| Guest | Script |
|---|---|
| **Ubuntu Desktop** | `ubuntu.desktop.k8s.sh` |
| **Windows 11** | `windows.11.k8s.ps1` |

**Ubuntu Desktop**

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.k8s.sh
```

**Optional steps after the script completes (Ubuntu Desktop)**

1. Change hostname: `sudo hostnamectl set-hostname [desired-hostname]`
2. Terminal restart may be needed for group permissions to take effect

**Windows 11**

Open an elevated PowerShell terminal and run the following command.

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/windows.11.k8s.ps1$nc" | iex
```

> Set `$env:YurunaCacheContent` to a unique datetime string to bypass a caching
> proxy; leave it unset to allow caching. See
> [docs/caching.md](../../docs/caching.md).

You can now follow the instructions to install the Yuruna-based [Kubernetes](../../docs/kubernetes.md) examples.

**Verify the Docker and Kubernetes status**

Docker: list images

```bash
docker images
```

Docker: list containers

```bash
docker ps -a
```

Kubernetes: list nodes

```bash
kubectl get nodes
```

Kubernetes: list pods

```bash
kubectl get pods -A
```

Kubernetes: current context

```bash
kubectl config current-context
```

Back to [[Ubuntu Desktop Guest - Workloads](../guest.ubuntu.desktop/README.md)] or [[Windows 11 Guest - Workloads](../guest.windows.11/README.md)]
