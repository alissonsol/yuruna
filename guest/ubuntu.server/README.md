# Ubuntu Server Guest - Workloads

See [../../CODE.md](../../CODE.md) for the guest workload pattern.

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.ubuntu.server/README.md) ·
[Windows Hyper-V](../../host/windows.hyper-v/guest.ubuntu.server/README.md).

## Post-VDE Setup

In a guest terminal:

```bash
/automation/fetch-and-execute.sh guest/ubuntu.server/ubuntu.server.<workload>.sh
```

Run `ubuntu.server.update.sh` first.

### Available workloads

| `<workload>` | Description |
|--------------|-------------|
| `update` | System update |
| `code` | [Code](../../docs/code.md): Java JDK, .NET SDK, Git, PowerShell |
| `n8n` | [n8n](../../docs/n8n.md) workflow automation |
| `openclaw` | [OpenClaw](../../docs/openclaw.md): Git, Node.js, OpenClaw AI agent |
| `postgresql` | [PostgreSQL](../../docs/postgresql.md) from PGDG |
| `k8s` | [k8s](../../docs/k8s.md): Docker, Kubernetes, Helm, OpenTofu, cloud CLIs |

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
