# Stash Service VM (Hyper-V)

Canonical documentation: **[Stash Service](../../../docs/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 24.04 LTS cloud image
  (amd64, qcow2 → VHDX, resized to 256 GB dynamic).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM (8 GB RAM /
  4 vCPU) and seeds via cloud-init.
- [host/vmconfig/stash-service.base.user-data](../../vmconfig/stash-service.base.user-data) — shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault. No daemon launch (out of
  scope per [§4.6](../../../docs/stash-service.md#what-v1-does-not-implement)).
- [host/vmconfig/stash-service.meta-data](../../vmconfig/stash-service.meta-data) — shared
  cloud-init instance metadata.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../../../README.md)
