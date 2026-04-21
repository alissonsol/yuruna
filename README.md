# Yuruna

**Tools and automation for development environments and cloud deployments.**

Yuruna has three capabilities: Virtual Development Environments (VDE) for reproducible workspaces; Kubernetes deployment across multiple clouds; and a VM-based test harness that validates workloads via keystroke injection or SSH.

- [macOS UTM host](virtual/host.macos.utm/README.md) Setup
  - [Amazon Linux](virtual/host.macos.utm/guest.amazon.linux/README.md) guest
  - [Ubuntu Desktop](virtual/host.macos.utm/guest.ubuntu.desktop/README.md) guest
  - [Windows 11](virtual/host.macos.utm/guest.windows.11/README.md) guest
- [Windows Hyper-V host](virtual/host.windows.hyper-v/README.md) Setup
  - [Amazon Linux](virtual/host.windows.hyper-v/guest.amazon.linux/README.md) guest
  - [Ubuntu Desktop](virtual/host.windows.hyper-v/guest.ubuntu.desktop/README.md) guest
  - [Windows 11](virtual/host.windows.hyper-v/guest.windows.11/README.md) guest
- [Kubernetes](docs/kubernetes.md) deployment

After the guest operating system is ready, there are instructions on installing workloads.

  - [Amazon Linux](virtual/guest.amazon.linux/README.md) workloads
  - [Ubuntu Desktop](virtual/guest.ubuntu.desktop/README.md) workloads
  - [Windows 11](virtual/guest.windows.11/README.md) workloads

## Read More

- [VDE Overview](virtual/README.md) - Virtual Development Environment
- [Kubernetes Deployment](docs/kubernetes.md) - Multi-cloud Kubernetes automation
- [Requirements](docs/requirements.md) - Full tool installation guide
- [FAQ](docs/faq.md) - Troubleshooting common issues
- [Contributing](docs/contributing.md) - How to contribute

## Important Notes

- **Cost warning**: Cloud resources incur charges. Always [clean up](docs/cleanup.md) resources you're not using.
- Scripts and examples are provided "as is" without guarantees. See [license](LICENSE.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
