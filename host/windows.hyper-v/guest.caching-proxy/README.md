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
  4 vCPU) and seeds via cloud-init. Dedicated cache box budgeted
  around squid's 7 GB `cache_mem` (58 % of RAM).
- [host/vmconfig/caching-proxy.base.user-data](../../vmconfig/caching-proxy.base.user-data) — shared
  cloud-init base (+ per-host overlay): squid, Prometheus + Grafana + squid-exporter,
  snapshot-cache tuning, `offline_mode` flip after prewarm.
- [host/vmconfig/caching-proxy.meta-data](../../vmconfig/caching-proxy.meta-data) — shared
  cloud-init instance metadata.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../../../README.md)
