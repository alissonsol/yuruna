# Yuruna

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Three capabilities: reproducible host/guest VM setups for development
workspaces, Kubernetes deployment across multiple clouds, and a VM-based
test harness. Architecture and conventions: [Yuruna Architecture](docs/architecture.md).

## Safestart

It is recommended that you read the online drafts of chapters [0](https://yuruna.link/book/2026/ch00) and [1](https://yuruna.link/book/2026/ch01) of an upcoming book about the Yuruna framework.

## Quickstart

See the **Administrator Risk Warning** in the [Yuruna License](LICENSE.md).

1. **Install Yuruna on a host.** Paste the one-liner for your OS from
   [install scripts](install/README.md#remote-one-liners). It installs
   dependencies and clones the framework to `~/git/yuruna`
   (`%USERPROFILE%\git\yuruna` on Windows).

2. **In a PowerShell window (`pwsh`), from the `yuruna` folder, configure and run:**

   ```
   Copy-Item test/test.config.yml.template test/test.config.yml
   ```

   Edit `test/test.config.yml` and test the configuration.

   ```
   test/Test-Config.ps1
   ```
   Fix any error before proceeding.

   ```
   pwsh test/Invoke-TestRunner.ps1
   ```

   The runner clones the sample project repo (`yuruna-project`, configured
   via `repositories.projectUrl` in the file you just copied) into
   `project/` on every cycle and discovers the
   [website example](https://github.com/alissonsol/yuruna-project/tree/main/example/website)
   sequences automatically.

3. **Watch progress at** `http://localhost:8080/status/`.

Tests may break if a screensaver activates, the machine sleeps, or similar conditions interrupt them. For each host type, there is a script `Enable-TestAutomation.ps1` in the corresponding folder, which sets configurations to avoid most interruptions.

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

- [Requirements](docs/requirements.md) · [FAQ](docs/faq.md) · [Roadmap](docs/roadmap.md)
- [Host pools](docs/pool-admin.md) · [Hosts](host/README.md) · [Guests](guest/README.md)
- [Contributing](CONTRIBUTING.md) · [Contributors](docs/contributors.md) · [Opportunities](docs/opportunities.md)

**Cost warning**: Cloud resources incur charges. Always clean up
[Yuruna Resources ...](docs/cleanup.md) you're not using.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.07
