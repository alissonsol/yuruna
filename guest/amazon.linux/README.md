# Amazon Linux Guest - Workloads

See [../../CODE.md](../../CODE.md) for the guest workload pattern.

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.amazon.linux/README.md) ·
[Windows Hyper-V](../../host/windows.hyper-v/guest.amazon.linux/README.md).

## Post-VDE Setup

In a guest terminal:

```bash
/automation/fetch-and-execute.sh guest/amazon.linux/amazon.linux.<workload>.sh
```

Run `amazon.linux.update.sh` first.

### Available workloads

| `<workload>` | Description |
|--------------|-------------|
| `update` | System update |
| `code` | [Code](../../docs/code.md): Java JDK, .NET SDK, Git, VS Code |
| `n8n` | [n8n](../../docs/n8n.md) workflow automation |
| `openclaw` | [OpenClaw](../../docs/openclaw.md): Git, Node.js, OpenClaw AI agent |
| `postgresql` | [PostgreSQL](../../docs/postgresql.md) from PGDG |

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
