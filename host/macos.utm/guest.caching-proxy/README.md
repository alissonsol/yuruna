# Squid Cache VM (macOS UTM)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[Caching](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[Caching proxy — test-harness operator reference](../../../docs/caching-proxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (arm64, qcow2 → raw, resized to 512 GB sparse).
- [New-VM.ps1](New-VM.ps1) — assembles the UTM bundle and seeds via
  cloud-init.
- [host/vmconfig/caching-proxy.base.user-data](../../vmconfig/caching-proxy.base.user-data) — shared
  cloud-init base (+ per-host overlay): squid, Prometheus + Grafana + squid-exporter,
  snapshot-cache tuning, `offline_mode` flip after prewarm.
- [host/vmconfig/caching-proxy.meta-data](../../vmconfig/caching-proxy.meta-data) — shared
  cloud-init instance metadata.
- [config.plist.template](config.plist.template) — UTM VM template
  (Apple Virtualization, 12 GB RAM / 4 vCPU; dedicated cache box sized
  so squid's `cache_mem` can take 75 % of RAM).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.30

Back to [Yuruna](../../../README.md)
