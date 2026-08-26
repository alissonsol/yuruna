# Service lifecycle

Start / stop pairs for the long-lived services a lab host runs. Every
script here is operator-facing and safe to run by hand from the repo
root:

| Pair | What it manages |
|---|---|
| `Start-CachingProxyServiceVM.ps1` / `Stop-CachingProxyServiceVM.ps1` | the Squid caching-proxy-service VM and the host proxy settings that point at it |
| `Start-StashServiceVM.ps1` / `Stop-StashServiceVM.ps1` | the stash-service VM and its presence marker |
| `Start-DownloadAgentServiceVM.ps1` / `Stop-DownloadAgentServiceVM.ps1` | the download-agent VM and its pool claim |
| `Start-PoolControlServiceVM.ps1` / `Stop-PoolControlServiceVM.ps1` | the pool-control-service VM that serves the lab dashboard |
| `Start-ConfigService.ps1` / `Stop-ConfigService.ps1` | the in-process host config service (no VM) |

[`Start-StatusService.ps1`](Start-StatusService.ps1) /
[`Stop-StatusService.ps1`](Stop-StatusService.ps1) complete the set: the host
status HTTP server that publishes the status UI (no VM of its own).

Two caching-proxy-service operations sit alongside the pair that owns that VM:

| Script | What it does |
|---|---|
| `Move-CachingProxyService.ps1` | hand the caching-proxy-service over to another host in the lab |
| `Repair-CachingProxyServiceForwarder.ps1` | macOS/UTM: re-verify the proxy VM is reachable on the LAN and refresh its state file |

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
pwsh test/service/Stop-CachingProxyServiceVM.ps1
```

## The -WhatIf contract across the pairs

The intended contract is that every `Start-*ServiceVM.ps1` /
`Stop-*ServiceVM.ps1` declares `[CmdletBinding(SupportsShouldProcess)]`, and
that each Start gates the destroy/rebuild delegation to `New-VM.ps1` behind
`$PSCmdlet.ShouldProcess`. Today the scripts fall into two groups, and they
fail differently:

- `Start-PoolControlServiceVM` and `Start-DownloadAgentServiceVM` declare
  `[CmdletBinding(SupportsShouldProcess)]`, so `-WhatIf` binds. On
  `Start-PoolControlServiceVM` the gate still covers only the `-HostSideProof`
  build/launch, not the VM path, so `-WhatIf` is accepted there and the VM is
  rebuilt anyway.
- `Start-StashServiceVM`, `Start-CachingProxyServiceVM`, `Stop-StashServiceVM`
  and `Stop-CachingProxyServiceVM` declare no `CmdletBinding` at all, so
  `-WhatIf` is not a parameter they have: passing it fails parameter binding
  before any work starts rather than running a dry run.

Do not infer the contract from a sibling that does honor it.

## The readiness budget across the three VM bring-ups

All three VM bring-ups wait on the same `Wait-YurunaServiceVmDaemon` with the
same 2700 s floor and print the same "the wait extends itself while the guest
reports it is still building" promise. They resolve the budget differently:
`Start-DownloadAgentServiceVM` reads it through
`Get-DownloadAgentServiceReadyTimeoutSeconds`, while
`Start-PoolControlServiceVM` and `Start-StashServiceVM` parse
`<SERVICE>_READY_TIMEOUT_SECONDS` inline. Only `Start-StashServiceVM` passes
`-MaxTimeoutSeconds` explicitly; the other two take
`Wait-YurunaServiceVmDaemon`'s default, which caps the extension at twice
`-TimeoutSeconds`. So all three do grow, but only the stash bring-up states
its own ceiling instead of inheriting one. Treat the module helper as the
shape to converge on.

## The name/folder split

`test/extension/*/*.config.yml` and the service roster in
[`../modules/Test.ServiceVm.psm1`](../modules/Test.ServiceVm.psm1) declare
only a script *name* (`stopScript: Stop-StashServiceVM.ps1`); the harness
supplies this folder when it resolves one. That keeps the extension config
schema -- which pins the value to a bare filename -- unchanged for
third-party extensions, and keeps "where service scripts live" a single
decision rather than one repeated in every config.

The Stop name is derived from the Start name rather than listed
(`Get-PoolWorkerStopScriptName` in
[`../modules/Test.PoolWorker.psm1`](../modules/Test.PoolWorker.psm1)), so a
pair that stops matching by name stops being retirable during pool-worker
conversion. Keep both halves of a pair in this folder.

## Path base

Each script resolves its roots through
`Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder`,
which walks one level up to `test/`. Pre-prelude module imports use
`Join-Path $PSScriptRoot '../modules/<name>.psm1'`.
