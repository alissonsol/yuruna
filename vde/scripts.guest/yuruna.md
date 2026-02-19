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

1. Set hostname: `sudo hostnamectl set-hostname [desired-hostname]`
2. Terminal restart may be needed for group permissions to take effect

**Verify the Kubernetes cluster**

```bash
kubectl get nodes
kubectl get pods -A
kubectl config current-context
```

The node should show `Ready` status, system pods should be running, and the context should be `docker-desktop`.

Back to [Post-VDE Setup](README.md)
