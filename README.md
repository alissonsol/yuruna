# Yuruna

**Tools and automation for development environments and cloud deployments.**

Three capabilities: Virtual Development Environments (VDE) for
reproducible workspaces, Kubernetes deployment across multiple clouds,
and a VM-based test harness. Architecture and conventions:
[CODE.md](CODE.md).

## VDE

- macOS UTM host: [setup](virtual/host.macos.utm/README.md) · guests:
  [Amazon Linux](virtual/host.macos.utm/guest.amazon.linux/README.md) ·
  [Ubuntu Desktop](virtual/host.macos.utm/guest.ubuntu.desktop/README.md) ·
  [Ubuntu Server](virtual/host.macos.utm/guest.ubuntu.server/README.md) ·
  [Windows 11](virtual/host.macos.utm/guest.windows.11/README.md)
- Windows Hyper-V host: [setup](virtual/host.windows.hyper-v/README.md) · guests:
  [Amazon Linux](virtual/host.windows.hyper-v/guest.amazon.linux/README.md) ·
  [Ubuntu Desktop](virtual/host.windows.hyper-v/guest.ubuntu.desktop/README.md) ·
  [Ubuntu Server](virtual/host.windows.hyper-v/guest.ubuntu.server/README.md) ·
  [Windows 11](virtual/host.windows.hyper-v/guest.windows.11/README.md)

After the guest OS is up, install workloads:
[Amazon Linux](virtual/guest.amazon.linux/README.md) ·
[Ubuntu Desktop](virtual/guest.ubuntu.desktop/README.md) ·
[Ubuntu Server](virtual/guest.ubuntu.server/README.md) ·
[Windows 11](virtual/guest.windows.11/README.md)

## Read More

- [VDE Overview](virtual/README.md) · [Kubernetes](docs/kubernetes.md) ·
  [Requirements](docs/requirements.md) · [FAQ](docs/faq.md) ·
  [Contributing](docs/contributing.md)

**Cost warning**: Cloud resources incur charges. Always
[clean up](docs/cleanup.md) resources you're not using.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
