# Stash Service VM (Ubuntu KVM)

Canonical documentation: **[Stash Service](../../../docs/design/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 26.04 LTS cloud image
  (amd64 qcow2, resized to 256 GB sparse).
- [New-VM.ps1](New-VM.ps1) — defines the libvirt domain (8 GB RAM /
  4 vCPU) and seeds via cloud-init NoCloud ISO.
- [host/vmconfig/stash-service.base.user-data](../../vmconfig/stash-service.base.user-data) — shared
  minimal cloud-init base (+ per-host overlay): `yuruna` user with the harness SSH
  key + a console password from the authentication vault.
- [host/vmconfig/stash-service.meta-data](../../vmconfig/stash-service.meta-data) — shared
  cloud-init instance metadata.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.03

Back to [Yuruna](../../../README.md)
