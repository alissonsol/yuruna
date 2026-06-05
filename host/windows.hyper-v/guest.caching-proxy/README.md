# Squid Cache VM (Hyper-V)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[Caching](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[Caching proxy — test-harness operator reference](../../../docs/caching-proxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (amd64, qcow2 → VHDX, resized to 512 GB dynamic).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM (12 GB RAM /
  4 vCPU) and seeds via cloud-init. Dedicated cache box sized so
  squid's `cache_mem` can take 75 % of RAM.
- [vmconfig/user-data](../../vmconfig/caching-proxy.base.user-data) — cloud-init: squid,
  Prometheus + Grafana + squid-exporter, snapshot-cache tuning,
  `offline_mode` flip after prewarm.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [Windows Hyper-V Host Setup](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
