# Download-agent service VM (macOS UTM)

Canonical documentation: **[Download-agent service](../../../docs/download-agent.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) -- base Ubuntu 26.04 LTS cloud image
  (arm64 qcow2, resized to 256 GB sparse on APFS).
- [New-VM.ps1](New-VM.ps1) -- builds the UTM bundle (8 GB RAM /
  core-count-policy vCPUs (min 4), QEMU backend with `-vnc` and bridged networking) and
  seeds via cloud-init.
- [config.plist.template](config.plist.template) -- UTM bundle
  config skeleton with placeholders substituted by `New-VM.ps1`.
- [host/vmconfig/download-agent-service.base.user-data](../../vmconfig/download-agent-service.base.user-data) -- shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault. Fetches the framework and
  runs the bring-up script that builds + launches the daemon under systemd.
- [host/vmconfig/download-agent-service.meta-data](../../vmconfig/download-agent-service.meta-data) -- shared
  cloud-init instance metadata.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.04

Back to [Yuruna](../../../README.md)
