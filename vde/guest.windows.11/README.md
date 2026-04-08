# Windows 11 Guest - Workloads

Workload scripts and tools for Windows 11 guests.

## VM Setup

Create the guest VM on your host first:

- [macOS UTM host](../host.macos.utm/guest.windows.11/README.md)
- [Windows Hyper-V host](../host.windows.hyper-v/guest.windows.11/README.md)

## Post-VDE Setup

Open an **elevated PowerShell terminal** in the guest and run the command for each desired workload.

### Update

```powershell
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.update.ps1?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" | iex
```

**After the initial update, the [Latest Stable PowerShell](https://aka.ms/powershell-release?tag=stable) release should be available.** Open a new Administrator console with the latest PowerShell to guarantee compatibility with the workload scripts.

### Available workloads

- [Code](../docs/code.md) - Java (JDK), .NET SDK, Git, and Visual Studio Code

```powershell
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.code.ps1?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" | iex
```

- [k8s](../docs/k8s.md) - All Kubernetes requirements (Docker, Kubernetes, Helm, OpenTofu, Cloud CLIs, and more)

```powershell
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.k8s.ps1?nocache=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" | iex
```

**Please read:** While installing all the Kubernetes requirements for Windows will succeed, starting Docker will demand a coordinated change of virtualization settings for both the host (Hyper-V or mac UTM) and the guest. Those instructions are too long and unreliable to be automated at this time. For now, ask your favorite AI assistant using the prompts below:

- **macOS UTM**: _Provide detailed instructions on how to configure a macOS UTM and a Windows 11 guest so that Docker can be started in the guest environment using ARM64 host CPUs._
- **Windows Hyper-V**: _Provide detailed instructions on how to configure a Windows Hyper-V host and a Windows 11 guest so that Docker can be started in the guest environment._

TODO: Create scripts that will configure the settings for both the host and the guest, after instructions become more reliable.

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
