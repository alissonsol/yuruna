# Yuruna

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Three capabilities: reproducible host/guest VM setups for development
workspaces, Kubernetes deployment across multiple clouds, and a VM-based
test harness. Architecture and conventions: [Yuruna Architecture](docs/architecture.md).

## Quickstart

- Execute the [install](install/README.md) script for your host
- In a PowerShell (pwsh) command prompt
  - Navigate to the `test` folder
  - Execute the script `Start-CachingProxy.ps1` (wait for the cache to be ready)
  - Execute the script `Invoke-TestRunner.ps1`
  - Check results at `http://localhost:8080/status/`

## Host / guest support

- [macOS UTM](host/macos.utm/README.md) host
  - guests:
  [Amazon Linux](host/macos.utm/guest.amazon.linux/README.md) ·
  [macOS 26](host/macos.utm/guest.macos.26/README.md) ·
  [Ubuntu Server](host/macos.utm/guest.ubuntu.server/README.md) ·
  [Windows 11](host/macos.utm/guest.windows.11/README.md)
- [Windows Hyper-V](host/windows.hyper-v/README.md) host
  - guests:
  [Amazon Linux](host/windows.hyper-v/guest.amazon.linux/README.md) ·
  [Ubuntu Server](host/windows.hyper-v/guest.ubuntu.server/README.md) ·
  [Windows 11](host/windows.hyper-v/guest.windows.11/README.md)
- [Ubuntu KVM/libvirt](host/ubuntu.kvm/README.md) host
  - guests:
  [Amazon Linux](host/ubuntu.kvm/guest.amazon.linux/README.md) ·
  [Ubuntu Server](host/ubuntu.kvm/guest.ubuntu.server/README.md) ·
  [Windows 11](host/ubuntu.kvm/guest.windows.11/README.md)

After the guest OS is up, install workloads:
[Amazon Linux](guest/amazon.linux/README.md) ·
[Ubuntu Server](guest/ubuntu.server/README.md) ·
[Windows 11](guest/windows.11/README.md)

## Read More

- [Hosts](host/README.md) · [Guests](guest/README.md) ·
  [Kubernetes Deployment](docs/kubernetes.md) · [Yuruna Requirements](docs/requirements.md)
- [FAQ](docs/faq.md) · [Contributing](CONTRIBUTING.md) · [Roadmap](docs/roadmap.md)

**Cost warning**: Cloud resources incur charges. Always clean up
[Yuruna Resources ...](docs/cleanup.md) you're not using.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
