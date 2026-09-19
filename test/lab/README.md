# Lab setup

Standing a lab up on a machine, and the host-level settings a test host
needs to run unattended. These act on *this* host; the pool intent that
ties hosts together lives in [`../pool/`](../pool/).

## Host-neutral entry points

Four dispatchers. Each detects the host type and runs that host's copy of
the script from `host/<host type>/`, so the same command works everywhere:

```
pwsh test/lab/Enable-TestAutomation.ps1                        # prepare this host for unattended runs
pwsh test/lab/Disable-TestAutomation.ps1                       # ... and put those host settings back
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <host> # copy another pool host's test.config.yml
pwsh test/lab/Remove-OrphanedVMFiles.ps1                       # delete files left by VMs that are already gone
```

Arguments (`-WhatIf` among them) are forwarded to the per-host script,
which owns the behavior and documents it:
[macOS UTM](../../host/macos.utm/README.md),
[Windows Hyper-V](../../host/windows.hyper-v/README.md),
[Ubuntu KVM](../../host/ubuntu.kvm/README.md). On Windows,
`Enable-TestAutomation` and `Sync-HostConfiguration` need an elevated
PowerShell.

These four reach `automation/Yuruna.HostRedirect.psm1` through
`Split-Path -Parent (Split-Path -Parent $PSScriptRoot)` -- two levels up,
because they sit one below `test/`. The redirect module resolves the
per-host script from its own location, so it is unaffected by where the
dispatcher lives.

`Remove-OrphanedVMFiles` only sweeps files whose VM is already gone. To
stop and unregister the test VMs *and* sweep, use
[`../Remove-TestVMFiles.ps1`](../Remove-TestVMFiles.ps1).

## Lab creation and storage

| Script | Purpose |
|---|---|
| `New-Lab.ps1` | create a lab: its storage layout, config and identity |
| `New-LocalLabStorage.ps1` | publish this machine's own pool/stash SMB shares and the accounts scoped to them |
| `Clear-LocalLabStorage.ps1` | withdraw those shares and accounts (leaves the data) |
| `Set-LabToken.ps1` | enroll this host: redeem the dashboard's 6-character Lab token for the internal authentication key |
| `Lab-Diag.ps1` | show where a Lab token exchange stops, step by step, when `Set-LabToken.ps1` fails |
| `Invoke-HostRefresh.ps1` | probe hypervisor responsiveness and report a repair the operator would need to run by hand; `-WhatIf` previews with no lock, request or mutation |

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code from the dashboard's Lab token tile>
```

`New-LocalLabStorage.ps1` calls `New-Lab.ps1` directly (same folder), and
is itself invoked by `install/setup.ps1`. `Clear-LocalLabStorage.ps1` is
run for you by [`../pool/Convert-ToPoolWorker.ps1`](../pool/Convert-ToPoolWorker.ps1)
when a standalone machine joins a lab.

Walk-through: [Lab operator](../../docs/lab-operator.md).

## Path base

Scripts here that load harness modules resolve their roots through
`Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder`,
which walks one level up to `test/`. Pre-prelude imports use
`Join-Path $PSScriptRoot '../modules/<name>.psm1'`.
