# Yuruna

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Three capabilities: reproducible host/guest VM setups for development
workspaces, Kubernetes deployment across multiple clouds, and a VM-based
test harness. Architecture and conventions: [Yuruna Architecture](docs/architecture.md).

## Safestart

It is recommended that you read the online drafts of chapters [0](https://yuruna.link/book/2026/ch00) and [1](https://yuruna.link/book/2026/ch01) of an upcoming book about the Yuruna framework.

## Quickstart

See the **Administrator Risk Warning** in the [Yuruna License](LICENSE.md).

**A.1 — Install Yuruna on the host.** Paste the one-liner for your OS
from the [install scripts](install/README.md#remote-one-liners). It
installs dependencies, clones the framework to `~/git/yuruna`
(`%USERPROFILE%\git\yuruna` on Windows), and creates
`test/test.config.yml` from its template. Reboot if the installer says
RESTART REQUIRED, then run the commands below from the `yuruna` folder.

> **Shortcut.** `pwsh install/setup.ps1` does A.2 and A.3 for you — and can set
> up a whole lab — asking only what it cannot infer. See
> [Guided setup](install/README.md#guided-setup). The steps below are the
> by-hand path, and stay the reference when a step needs judgment or fails.

**A.2 — Enable test automation.** Sleep, screen savers, and screen lock
interrupt tests; this explicit opt-in turns them off. Elevated
(Administrator PowerShell on Windows, `sudo` on macOS/Ubuntu):

```
pwsh test/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling changes.

**A.3 — Configure and run.** Edit `test/test.config.yml`, then validate
it:

```
pwsh test/Test-Config.ps1
```

Fix any FAIL, then start the runner:

```
pwsh test/Invoke-TestRunner.ps1
```

Every cycle re-clones the sample project repo (`yuruna-project`, set by
`repositories.projectUrl` in the config) into `project/` and discovers
the
[website example](https://github.com/alissonsol/yuruna-project/tree/main/example/website)
sequences automatically.

**A.4 — Watch progress at** `http://localhost:8080/status/`.

For a durable setup — dedicated test user, storage, caching-proxy service,
stash service — continue with the [operator guide](docs/operator.md);
to run several machines as one lab, the
[lab operator guide](docs/lab-operator.md).

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

Last review: 2026.07.31
