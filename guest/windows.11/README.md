# Windows 11 Guest - Workloads

See [../CODE.md](../CODE.md) for the guest workload pattern (one-liner
convention, `YurunaCacheContent`).

Create the guest VM first:
[macOS UTM](../host.macos.utm/guest.windows.11/README.md) ·
[Windows Hyper-V](../host.windows.hyper-v/guest.windows.11/README.md).

## Post-VDE Setup

Open an **elevated PowerShell terminal** in the guest. The one-liner is
the same shape for every workload — only the script name changes:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/<script>$nc" | iex
```

Run `windows.11.update.ps1` first. After the initial update the
[latest stable PowerShell](https://aka.ms/powershell-release?tag=stable)
is installed — open a new elevated console to guarantee compatibility
before running other workloads.

### Available workloads

| Script | Workload |
|--------|----------|
| `windows.11.update.ps1` | System update |
| `windows.11.code.ps1` | [Code](../docs/code.md): Java JDK, .NET SDK, Git, VS Code |
| `windows.11.k8s.ps1` | [k8s](../docs/k8s.md): Docker, Kubernetes, Helm, OpenTofu, cloud CLIs |

**Docker note**: installing k8s requirements succeeds, but starting
Docker needs coordinated virtualization settings on both host and guest.
Those instructions are too long and unreliable to automate yet. Until
they stabilize, ask an AI assistant for the current recipe for
(macOS UTM + ARM64 host) or (Windows Hyper-V host).

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
