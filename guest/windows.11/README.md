# Windows 11 Guest - Workloads

See [Guests -- ...](../README.md) for the guest workload pattern (one-liner
convention, `YurunaCacheContent`).

Create the guest VM first:
[macOS UTM](../../host/macos.utm/guest.windows.11/README.md) -
[Windows Hyper-V](../../host/windows.hyper-v/guest.windows.11/README.md) -
[Ubuntu KVM](../../host/ubuntu.kvm/guest.windows.11/README.md).

## Post-install setup

Open an **elevated PowerShell terminal** in the guest. The one-liner is
the same shape for every workload -- only the script name changes:

```
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/<script>$nc" | iex
```

Run `windows.11.update.ps1` first. After the initial update the
[latest stable PowerShell](https://aka.ms/powershell-release?tag=stable)
is installed -- open a new elevated console to guarantee compatibility
before running other workloads.

Framework materialization first tries the host archive. If that is unavailable,
the updater uses the full commit in `E_FB_REPO`/`E_FB_REF`, or the repository and
commit recorded on the trusted VM seed, through the LAN mirror and then GitHub.
Both routes must produce that exact commit; an existing framework directory is
preserved. Trusted launchers should set both `E_FB_*` fields for each invocation
when reusing a VM after the host has updated. The current Windows workload
sequence is a placeholder and does not provide invocation metadata automatically.
Without either immutable identity, the existing configured clone URL remains the
explicit legacy fallback.

### Available workloads

| Script | Workload |
|--------|----------|
| `windows.11.update.ps1` | System update |
| `windows.11.code.ps1` | [Code](../../docs/guest-image-setup.md#code): Java JDK, .NET SDK, Git, VS Code |
| `windows.11.k8s.ps1` | [k8s](../../docs/kubernetes.md#guest-side-prerequisites): Docker, Kubernetes, Helm, OpenTofu, cloud CLIs |

The `n8n`, `openclaw`, and `postgresql` workloads are intentionally out
of scope for the Windows 11 guest; use a Linux guest instead.

**Docker note**: installing k8s requirements succeeds, but starting
Docker needs coordinated virtualization settings on both host and guest.
Those steps are too long and unreliable to automate yet; until they
stabilize, ask an AI assistant for the current recipe for
(macOS UTM + ARM64 host) or (Windows Hyper-V host).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna](../../README.md)
