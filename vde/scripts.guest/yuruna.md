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

**Manual steps after the script completes**

1. Set hostname: `sudo hostnamectl set-hostname [desired-hostname]`
2. Initialize Kubernetes: `sudo kubeadm init --pod-network-cidr=10.244.0.0/16`
3. Configure kubectl:

    ```bash
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    ```

4. Install networking plugin (e.g., Flannel):

    ```bash
    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
    ```

5. Remove taints from nodes (if needed for single-node cluster)
6. Rename kubectl context: `kubectl config rename-context kubernetes-admin@kubernetes docker-desktop`
7. Terminal restart may be needed for group permissions to take effect

Back to [Post-VDE Setup](README.md)
