# Stash Service VM (Hyper-V)

Canonical documentation: **[Stash Service](../../../docs/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 24.04 LTS cloud image
  (amd64, qcow2 → VHDX, resized to 256 GB dynamic).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM (8 GB RAM /
  4 vCPU) and seeds via cloud-init.
- [vmconfig/user-data](vmconfig/user-data) — minimal cloud-init:
  `yuruna` user with the harness SSH key + a console password from
  the authentication vault. No daemon launch (out of scope per
  [§4.6](../../../docs/stash-service.md#daemon)).
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [Windows Hyper-V Host Setup](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
