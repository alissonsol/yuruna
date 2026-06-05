# Stash Service VM (Ubuntu KVM)

Canonical documentation: **[Stash Service](../../../docs/stash-service.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu 24.04 LTS cloud image
  (amd64 qcow2, resized to 256 GB sparse).
- [New-VM.ps1](New-VM.ps1) — defines the libvirt domain (8 GB RAM /
  4 vCPU) and seeds via cloud-init NoCloud ISO.
- [vmconfig/user-data](../../vmconfig/stash-service.base.user-data) — minimal cloud-init:
  `yuruna` user with the harness SSH key + a console password from
  the authentication vault.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [Ubuntu KVM Host Setup](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
