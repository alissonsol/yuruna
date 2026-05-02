# k8s

Installs Kubernetes requirements: SSH, Git, Docker, Kubernetes,
PowerShell, Helm, OpenTofu, mkcert, Graphviz, Cloud CLIs (Azure, AWS,
GCP). Full list: [requirements.md](requirements.md). Guest workload
pattern: [../CODE.md](../CODE.md).

| Guest | Command |
|---|---|
| **Ubuntu Desktop** | `/automation/fetch-and-execute.sh guest/ubuntu.desktop/ubuntu.desktop.k8s.sh` |
| **Ubuntu Server** | `/automation/fetch-and-execute.sh guest/ubuntu.server/ubuntu.server.k8s.sh` |
| **Windows 11** | `irm "…/guest/windows.11/windows.11.k8s.ps1$nc" \| iex` (see [../guest/windows.11/README.md](../guest/windows.11/README.md)) |

**Ubuntu (Desktop or Server) — optional after:** change hostname with
`sudo hostnamectl set-hostname <name>`; a terminal restart may be
needed for new group permissions.

You can now follow [Kubernetes](kubernetes.md) deployment.

## Verify

```bash
docker images
docker ps -a
kubectl get nodes
kubectl get pods -A
kubectl config current-context
```

Back to [[Ubuntu Desktop](../guest/ubuntu.desktop/README.md)] ·
[[Ubuntu Server](../guest/ubuntu.server/README.md)] ·
[[Windows 11](../guest/windows.11/README.md)]
