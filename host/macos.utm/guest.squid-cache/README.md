# Squid Cache VM (macOS UTM)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[docs/caching.md](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[test/CachingProxy.md](../../../test/CachingProxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (arm64, qcow2 → raw, resized to 512 GB sparse).
- [New-VM.ps1](New-VM.ps1) — assembles the UTM bundle and seeds via
  cloud-init.
- [vmconfig/user-data](vmconfig/user-data) — cloud-init: squid,
  Prometheus + Grafana + squid-exporter, snapshot-cache tuning,
  `offline_mode` flip after prewarm.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.
- [config.plist.template](config.plist.template) — UTM VM template
  (Apple Virtualization, 12 GB RAM / 4 vCPU; dedicated cache box sized
  so squid's `cache_mem` can take 75 % of RAM).

Back to [macOS UTM Host Setup](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
