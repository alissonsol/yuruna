# Squid Cache VM (Hyper-V)

Canonical documentation — setup, cache configuration, monitoring (Grafana
+ Prometheus + cachemgr.cgi), access / credentials, and management — lives
at:

**[docs/caching.md](../../../docs/caching.md)**

The test-harness wrappers that expose the cache to remote clients
(`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`, and the
`YURUNA_CACHING_PROXY_IP` override consumed by `Invoke-TestRunner.ps1`)
are documented in
**[test/CachingProxy.md](../../../test/CachingProxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — downloads and prepares the base
  Ubuntu Server cloud image (amd64, qcow2 → VHDX, resized to 144 GB).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM and seeds it via
  cloud-init.
- [vmconfig/user-data](vmconfig/user-data) — cloud-init config: squid,
  Prometheus + Grafana + squid-exporter, snapshot-cache tuning,
  `offline_mode` flip after prewarm.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [[Windows Hyper-V Host Setup](../README.md)]
