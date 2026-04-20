# Squid Cache VM (macOS UTM)

Canonical documentation — setup, cache configuration, monitoring (Grafana
+ Prometheus + cachemgr.cgi), access / credentials, and management — now
lives at:

**[test/CachingProxy.md](../../../test/CachingProxy.md)**

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — downloads and prepares the base
  Ubuntu Server cloud image (arm64, qcow2 → raw, resized to 144 GB).
- [New-VM.ps1](New-VM.ps1) — assembles the UTM bundle and seeds it via
  cloud-init.
- [vmconfig/user-data](vmconfig/user-data) — cloud-init config: squid,
  Prometheus + Grafana + squid-exporter, snapshot-cache tuning,
  `offline_mode` flip after prewarm.
- [vmconfig/meta-data](vmconfig/meta-data) — cloud-init instance
  metadata.
- [config.plist.template](config.plist.template) — UTM VM definition
  template (Apple Virtualization backend, 4 GB RAM / 4 vCPU).

Back to [[macOS UTM Host Setup](../README.md)]
