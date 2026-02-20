# yuruna

Installs the [yuruna](https://github.com/alissonsol/yuruna) requirements: SSH, Git, Docker, Kubernetes, Homebrew, PowerShell, Helm, OpenTofu, mkcert, Graphviz, and Cloud CLIs (Azure, AWS, Google Cloud).

See the full list of [requirements](../../docs/requirements.md) for more details.

| Guest Environment | Script |
|---|---|
| **Ubuntu Desktop** | `ubuntu.desktop.yuruna.bash` |

**Ubuntu Desktop**

Open a terminal and enter the commands.

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/ubuntu.desktop/ubuntu.desktop.yuruna.bash)"
```

**Optional steps after the script completes**

1. Change hostname: `sudo hostnamectl set-hostname [desired-hostname]`
2. Terminal restart may be needed for group permissions to take effect

**Verify the Docker and Kubernetes status**

Docker: list images

```bash
docker images
````

Docker: list containers

```bash
docker ps -a
````

Kubernetes: list nodes

```bash
kubectl get nodes
````

Kubernetes: list pods

```bash
kubectl get pods -A
````

Kubernetes: current context

```bash
kubectl config current-context
````

You can now follow the instructions to install the Yuruna-based [Kubernetes](../../docs/kubernetes.md) examples.

Back to [Post-VDE Setup](README.md)
