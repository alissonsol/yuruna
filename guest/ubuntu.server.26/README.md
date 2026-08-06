# Ubuntu Server 26.04 Guest - Workloads

See [Guests — ...](../README.md) for the guest workload pattern.

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.ubuntu.server.26/README.md) ·
[Windows Hyper-V](../../host/windows.hyper-v/guest.ubuntu.server.26/README.md) ·
[Ubuntu KVM](../../host/ubuntu.kvm/guest.ubuntu.server.26/README.md).

## Post-install setup

In a guest terminal:

```
/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.<workload>.sh
```

Run `ubuntu.server.26.update.sh` first.

### Available workloads

| `<workload>` | Description |
|--------------|-------------|
| `update` | System update |
| `code` | [Code](../../docs/guest-image-setup.md#code): Java JDK, .NET SDK, Git, VS Code |
| `n8n` | [n8n](../../docs/guest-image-setup.md#n8n) workflow automation |
| `openclaw` | [OpenClaw](../../docs/guest-image-setup.md#openclaw): Git, Node.js, OpenClaw AI agent |
| `postgresql` | [PostgreSQL](../../docs/guest-image-setup.md#postgresql) from PGDG |
| `k8s` | [k8s](../../docs/kubernetes.md#guest-side-prerequisites): Docker, Kubernetes, Helm, OpenTofu, cloud CLIs |
| `stash-service` | [stash service](../../docs/stash-guide.md): Yuruna distributed storage backend |

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.06

Back to [Yuruna](../../README.md)
