# Squid Cache VM (macOS UTM)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[Caching](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[Caching proxy — test-harness operator reference](../../../docs/caching-proxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (arm64, qcow2, resized to 512 GB sparse).
- [New-VM.ps1](New-VM.ps1) — assembles the UTM bundle and seeds via
  cloud-init.
- [host/vmconfig/caching-proxy.base.user-data](../../vmconfig/caching-proxy.base.user-data) — shared
  cloud-init base (+ per-host overlay): squid, Prometheus + Grafana + squid-exporter,
  snapshot-cache tuning, `offline_mode` flip after prewarm.
- [host/vmconfig/caching-proxy.meta-data](../../vmconfig/caching-proxy.meta-data) — shared
  cloud-init instance metadata.
- [config.plist.template](config.plist.template) — UTM VM template
  (QEMU backend with `-vnc`, 12 GB RAM / core-count-policy vCPUs
  (min 4); dedicated cache box
  budgeted around squid's 7 GB `cache_mem` — 58 % of RAM).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../../../README.md)
