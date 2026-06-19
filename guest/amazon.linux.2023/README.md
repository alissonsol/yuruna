# Amazon Linux 2023 Guest - Workloads

See [Guests — ...](../README.md) for the guest workload pattern.

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.amazon.linux.2023/README.md) ·
[Windows Hyper-V](../../host/windows.hyper-v/guest.amazon.linux.2023/README.md) ·
[Ubuntu KVM](../../host/ubuntu.kvm/guest.amazon.linux.2023/README.md).

## Post-install setup

In a guest terminal:

```
/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.<workload>.sh
```

Run `amazon.linux.2023.update.sh` first.

### Available workloads

| `<workload>` | Description |
|--------------|-------------|
| `update` | System update |
| `code` | [Code](../../docs/code.md): Java JDK, .NET SDK, Git, VS Code |
| `n8n` | [n8n](../../docs/n8n.md) workflow automation |
| `openclaw` | [OpenClaw](../../docs/openclaw.md): Git, Node.js, OpenClaw AI agent |
| `postgresql` | [PostgreSQL](../../docs/postgresql.md) from PGDG |

The Kubernetes workload (`k8s`) is intentionally out of scope for
Amazon Linux 2023; use one of the Ubuntu Server guests for `k8s`.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../../README.md)
