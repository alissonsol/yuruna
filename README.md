# Yuruna

**Tools and automation for development environments and cloud deployments.**

Three capabilities: Virtual Development Environments (VDE) for
reproducible workspaces, Kubernetes deployment across multiple clouds,
and a VM-based test harness. Architecture and conventions:
[CODE.md](CODE.md).

## VDE

- macOS UTM host: [setup](host/macos.utm/README.md) · guests:
  [Amazon Linux](host/macos.utm/guest.amazon.linux/README.md) ·
  [Ubuntu Desktop](host/macos.utm/guest.ubuntu.desktop/README.md) ·
  [Ubuntu Server](host/macos.utm/guest.ubuntu.server/README.md) ·
  [Windows 11](host/macos.utm/guest.windows.11/README.md)
- Windows Hyper-V host: [setup](host/windows.hyper-v/README.md) · guests:
  [Amazon Linux](host/windows.hyper-v/guest.amazon.linux/README.md) ·
  [Ubuntu Desktop](host/windows.hyper-v/guest.ubuntu.desktop/README.md) ·
  [Ubuntu Server](host/windows.hyper-v/guest.ubuntu.server/README.md) ·
  [Windows 11](host/windows.hyper-v/guest.windows.11/README.md)

After the guest OS is up, install workloads:
[Amazon Linux](guest/amazon.linux/README.md) ·
[Ubuntu Desktop](guest/ubuntu.desktop/README.md) ·
[Ubuntu Server](guest/ubuntu.server/README.md) ·
[Windows 11](guest/windows.11/README.md)

## Read More

- [Hosts](host/README.md) · [Guests](guest/README.md) ·
  [Kubernetes](docs/kubernetes.md) · [Requirements](docs/requirements.md) ·
  [FAQ](docs/faq.md) · [Contributing](docs/contributing.md)

**Cost warning**: Cloud resources incur charges. Always
[clean up](docs/cleanup.md) resources you're not using.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
