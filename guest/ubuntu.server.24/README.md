# Ubuntu Server 24.04 Guest - Workloads

See [Guests — ...](../README.md) for the guest workload pattern.

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.ubuntu.server.24/README.md) ·
[Windows Hyper-V](../../host/windows.hyper-v/guest.ubuntu.server.24/README.md) ·
[Ubuntu KVM](../../host/ubuntu.kvm/guest.ubuntu.server.24/README.md).

## Post-install setup

In a guest terminal:

```
/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.<workload>.sh
```

Run `ubuntu.server.24.update.sh` first.

### Available workloads

| `<workload>` | Description |
|--------------|-------------|
| `update` | System update |
| `code` | [Code](../../docs/code.md): Java JDK, .NET SDK, Git, PowerShell |
| `n8n` | [n8n](../../docs/n8n.md) workflow automation |
| `openclaw` | [OpenClaw](../../docs/openclaw.md): Git, Node.js, OpenClaw AI agent |
| `postgresql` | [PostgreSQL](../../docs/postgresql.md) from PGDG |
| `k8s` | [k8s](../../docs/kubernetes.md#guest-side-prerequisites): Docker, Kubernetes, Helm, OpenTofu, cloud CLIs |

[Troubleshooting](../../docs/guest-ubuntu-24.md) · Back to [Guests](../README.md) · [Yuruna](../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
