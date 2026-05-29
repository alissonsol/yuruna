# Yuruna

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Three capabilities: reproducible host/guest VM setups for development
workspaces, Kubernetes deployment across multiple clouds, and a VM-based
test harness. Architecture and conventions: [Yuruna Architecture](docs/architecture.md).

## Quickstart

See the **Administrator Risk Warning** in the [Yuruna License](LICENSE.md).

1. **Install Yuruna on the host.** Paste the one-liner for your OS from
   [install scripts](install/README.md#remote-one-liners). It installs
   dependencies and clones the framework to `~/git/yuruna`
   (`%USERPROFILE%\git\yuruna` on Windows).

2. **In `pwsh`, from the `yuruna` folder, configure and run:**

   ```
   Copy-Item test/test.config.yml.template test/test.config.yml
   pwsh test/Start-CachingProxy.ps1      # wait until "cache ready"
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

- [Hosts](host/README.md) · [Guests](guest/README.md) ·
  [Kubernetes Deployment](docs/kubernetes.md) · [Yuruna Requirements](docs/requirements.md)
- [FAQ](docs/faq.md) · [Contributing](CONTRIBUTING.md) · [Roadmap](docs/roadmap.md) ·
  [Contributor opportunities](docs/opportunities.md)

**Cost warning**: Cloud resources incur charges. Always clean up
[Yuruna Resources ...](docs/cleanup.md) you're not using.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
