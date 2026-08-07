# Yuruna

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Three capabilities: reproducible host/guest VM setups for development
workspaces, Kubernetes deployment across multiple clouds, and a VM-based
test harness. Architecture and conventions: [Yuruna Architecture](docs/architecture.md).

## Safestart

Read the online drafts of chapters [0](https://yuruna.link/book/2026/ch00) and [1](https://yuruna.link/book/2026/ch01) of an upcoming book about the Yuruna framework.

## Quickstart

See the **Administrator Risk Warning** in the [Yuruna License](LICENSE.md).

**1 — Install the prerequisites.** Paste the one-liner for your OS from
the [install scripts](install/README.md#remote-one-liners), or run the
matching `install/` script yourself. It installs dependencies, clones
the framework to `~/git/yuruna` (`%USERPROFILE%\git\yuruna` on
Windows), and seeds `test/test.config.yml`. Reboot if it says RESTART
REQUIRED, then run the rest from the `yuruna` folder.

**2 — Configure the host.**

```
pwsh install/setup.ps1
```

One guided command ([details](install/README.md#guided-setup)): it
turns off sleep and screen lock, sets up storage, builds the
caching-proxy and stash service VMs, and ends on the `Test-Config`
validation gate. On Windows it relaunches itself elevated once.

**3 — Run your first test.**

```
pwsh test/Invoke-TestRunner.ps1
```

Watch progress at `http://localhost:8080/status/`. Each cycle re-clones
the sample project (`repositories.projectUrl` in the config) and runs
the
[website example](https://github.com/alissonsol/yuruna-project/tree/main/example/website)
sequences.

**More info.** [Operator guide](docs/operator.md) — the full
single-machine runbook, including the dedicated test user;
[lab operator guide](docs/lab-operator.md) — several machines as one
lab.

## Host / guest support

- [macOS UTM](host/macos.utm/README.md) host
  - guests:
  [Amazon Linux 2023](host/macos.utm/guest.amazon.linux.2023/README.md) ·
  [macOS 26](host/macos.utm/guest.macos.26/README.md) ·
  [Ubuntu Server 24.04](host/macos.utm/guest.ubuntu.server.24/README.md) ·
  [Ubuntu Server 26.04](host/macos.utm/guest.ubuntu.server.26/README.md) ·
  [Windows 11](host/macos.utm/guest.windows.11/README.md)
- [Windows Hyper-V](host/windows.hyper-v/README.md) host
  - guests:
  [Amazon Linux 2023](host/windows.hyper-v/guest.amazon.linux.2023/README.md) ·
  [Ubuntu Server 24.04](host/windows.hyper-v/guest.ubuntu.server.24/README.md) ·
  [Ubuntu Server 26.04](host/windows.hyper-v/guest.ubuntu.server.26/README.md) ·
  [Windows 11](host/windows.hyper-v/guest.windows.11/README.md)
- [Ubuntu KVM/libvirt](host/ubuntu.kvm/README.md) host
  - guests:
  [Amazon Linux 2023](host/ubuntu.kvm/guest.amazon.linux.2023/README.md) ·
  [Ubuntu Server 24.04](host/ubuntu.kvm/guest.ubuntu.server.24/README.md) ·
  [Ubuntu Server 26.04](host/ubuntu.kvm/guest.ubuntu.server.26/README.md) ·
  [Windows 11](host/ubuntu.kvm/guest.windows.11/README.md)

After the guest OS is up, test workloads:
  - [Amazon Linux 2023](guest/amazon.linux.2023/README.md)
  - [macOS 26](guest/macos.26/README.md)
  - [Ubuntu Server 24.04](guest/ubuntu.server.24/README.md)
  - [Ubuntu Server 26.04](guest/ubuntu.server.26/README.md)
  - [Windows 11](guest/windows.11/README.md)

## Read More

- **[All documentation](docs/README.md)** — what every doc under `docs/` covers
- [Requirements](docs/operator.md#b2-preflight-dependencies) · [Workarounds & FAQ](docs/workarounds.md) · [Roadmap](docs/opportunities.md#roadmap)
- Machine [operator](docs/operator.md) and [lab operator](docs/lab-operator.md) guides
- [Contributing](CONTRIBUTING.md) · [Contributors](CONTRIBUTING.md#contributors) · [Opportunities](docs/opportunities.md)

**Cost warning**: Cloud resources incur charges. Always clean up
[Yuruna Resources ...](docs/kubernetes.md#cleaning-up-cloud-resources) you're not using.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.07
