# Download-agent service VM (Ubuntu KVM)

Canonical documentation: **[Download-agent service](../../../docs/download-agent.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) -- base Ubuntu 26.04 LTS cloud image
  (amd64 qcow2, resized to 256 GB sparse).
- [New-VM.ps1](New-VM.ps1) -- defines the libvirt domain (4 GB RAM /
  core-count-policy vCPUs, min 4) and seeds via cloud-init NoCloud ISO.
- [host/vmconfig/download-agent-service.base.user-data](../../vmconfig/download-agent-service.base.user-data) -- shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault. Fetches the framework and
  runs the bring-up script that builds + launches the daemon under systemd.
- [host/vmconfig/download-agent-service.meta-data](../../vmconfig/download-agent-service.meta-data) -- shared
  cloud-init instance metadata.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.05

Back to [Yuruna](../../../README.md)
