# Service lifecycle

Start / stop pairs for the long-lived services a lab host runs. Every
script here is operator-facing and safe to run by hand from the repo
root:

| Pair | What it manages |
|---|---|
| `Start-CachingProxyServiceVM.ps1` / `Stop-CachingProxyServiceVM.ps1` | the Squid caching-proxy VM and the host proxy settings that point at it |
| `Start-StashServiceVM.ps1` / `Stop-StashServiceVM.ps1` | the stash-service VM and its presence marker |
| `Start-DownloadAgentServiceVM.ps1` / `Stop-DownloadAgentServiceVM.ps1` | the download-agent VM and its pool claim |
| `Start-PoolControlServiceVM.ps1` / `Stop-PoolControlServiceVM.ps1` | the pool-control-service VM that serves the lab dashboard |
| `Start-ConfigService.ps1` / `Stop-ConfigService.ps1` | the in-process host config service (no VM) |

`Stop-StatusService.ps1` also lives here. Its partner
[`../Start-StatusService.ps1`](../Start-StatusService.ps1) stays in `test/`
because starting the status UI is a daily-driver command; stopping it is not.

Two caching-proxy operations sit alongside the pair that owns that VM:

| Script | What it does |
|---|---|
| `Move-CachingProxyService.ps1` | hand the caching-proxy service over to another host in the lab |
| `Repair-CachingProxyServiceForwarder.ps1` | macOS/UTM: re-verify the proxy VM is reachable on the LAN and refresh its state file |

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
pwsh test/service/Stop-CachingProxyServiceVM.ps1
```

## The name/folder split

`test/extension/*/*.config.yml` and the service roster in
[`../modules/Test.ServiceVm.psm1`](../modules/Test.ServiceVm.psm1) declare
only a script *name* (`stopScript: Stop-StashServiceVM.ps1`); the harness
supplies this folder when it resolves one. That keeps the extension config
schema — which pins the value to a bare filename — unchanged for
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
