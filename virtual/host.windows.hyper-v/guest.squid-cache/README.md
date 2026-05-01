# Squid Cache VM (Hyper-V)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[docs/caching.md](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[test/CachingProxy.md](../../../test/CachingProxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (amd64, qcow2 → VHDX, resized to 144 GB).
- [New-VM.ps1](New-VM.ps1) — creates the Hyper-V VM and seeds via
  cloud-init.
- [vmconfig/user-data](vmconfig/user-data) — cloud-init: squid,
  Prometheus + Grafana + squid-exporter, snapshot-cache tuning,
  `offline_mode` flip after prewarm.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.

Back to [[Windows Hyper-V Host Setup](../README.md)]
