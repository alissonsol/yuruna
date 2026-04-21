# Yuruna

**Tools and automation for development environments and cloud deployments.**

Yuruna has three capabilities: Virtual Development Environments (VDE) for reproducible workspaces; Kubernetes deployment across multiple clouds; and a VM-based test harness that validates workloads via keystroke injection or SSH.

- [macOS UTM host](vde/host.macos.utm/README.md) Setup
  - [Amazon Linux](vde/host.macos.utm/guest.amazon.linux/README.md) guest
  - [Ubuntu Desktop](vde/host.macos.utm/guest.ubuntu.desktop/README.md) guest
  - [Windows 11](vde/host.macos.utm/guest.windows.11/README.md) guest
- [Windows Hyper-V host](vde/host.windows.hyper-v/README.md) Setup
  - [Amazon Linux](vde/host.windows.hyper-v/guest.amazon.linux/README.md) guest
  - [Ubuntu Desktop](vde/host.windows.hyper-v/guest.ubuntu.desktop/README.md) guest
  - [Windows 11](vde/host.windows.hyper-v/guest.windows.11/README.md) guest
- [Kubernetes](docs/kubernetes.md) deployment

After the guest operating system is ready, there are instructions on installing workloads.

  - [Amazon Linux](vde/guest.amazon.linux/README.md) workloads
  - [Ubuntu Desktop](vde/guest.ubuntu.desktop/README.md) workloads
  - [Windows 11](vde/guest.windows.11/README.md) workloads

## Read More

- [VDE Overview](vde/README.md) - Virtual Development Environment
- [Kubernetes Deployment](docs/kubernetes.md) - Multi-cloud Kubernetes automation
- [Requirements](docs/requirements.md) - Full tool installation guide
- [FAQ](docs/faq.md) - Troubleshooting common issues
- [Contributing](docs/contributing.md) - How to contribute

## Important Notes

- **Cost warning**: Cloud resources incur charges. Always [clean up](docs/cleanup.md) resources you're not using.
- Scripts and examples are provided "as is" without guarantees. See [license](LICENSE.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
