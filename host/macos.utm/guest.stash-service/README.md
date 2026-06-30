# Stash Service VM (macOS UTM)

Canonical documentation: **[Stash Service](../../../docs/design/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 26.04 LTS cloud image
  (arm64 qcow2 → raw, resized to 256 GB sparse on APFS).
- [New-VM.ps1](New-VM.ps1) — builds the UTM bundle (8 GB RAM /
  4 vCPU, QEMU backend with `-vnc` and bridged networking) and
  seeds via cloud-init.
- [config.plist.template](config.plist.template) — UTM bundle
  config skeleton with placeholders substituted by `New-VM.ps1`.
- [host/vmconfig/stash-service.base.user-data](../../vmconfig/stash-service.base.user-data) — shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault.
- [host/vmconfig/stash-service.meta-data](../../vmconfig/stash-service.meta-data) — shared
  cloud-init instance metadata.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.30

Back to [Yuruna](../../../README.md)
