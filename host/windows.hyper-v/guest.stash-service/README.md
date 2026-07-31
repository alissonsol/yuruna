# stash service VM (Hyper-V)

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 26.04 LTS cloud image
  (amd64, qcow2 → VHDX, resized to 256 GB dynamic).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM (8 GB RAM /
  core-count-policy vCPUs, min 4) and seeds via cloud-init.
- [host/vmconfig/stash-service.base.user-data](../../vmconfig/stash-service.base.user-data) — shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault.
- [host/vmconfig/stash-service.meta-data](../../vmconfig/stash-service.meta-data) — shared
  cloud-init instance metadata.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.31

Back to [Yuruna](../../../README.md)
