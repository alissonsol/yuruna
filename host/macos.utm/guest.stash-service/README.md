# Stash Service VM (macOS UTM)

Canonical documentation: **[Stash Service](../../../docs/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 24.04 LTS cloud image
  (arm64 qcow2 → raw, resized to 256 GB sparse on APFS).
- [New-VM.ps1](New-VM.ps1) — builds the UTM bundle (8 GB RAM /
  4 vCPU, QEMU backend with `-vnc` and bridged networking) and
  seeds via cloud-init.
- [config.plist.template](config.plist.template) — UTM bundle
  config skeleton with placeholders substituted by `New-VM.ps1`.
- [vmconfig/user-data](vmconfig/user-data) — minimal cloud-init:
  `yuruna` user with the harness SSH key + a console password from
  the authentication vault.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [macOS UTM Host Setup](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
