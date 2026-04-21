# Test Extensions

See [../CODE.md](../CODE.md) for where extensions fit in the runner
cycle.

Extension scripts come in two phases:

- **Test-Start** — drive OS installation via JSON sequences
  (`Invoke-Sequence.psm1`) immediately after `New-VM.ps1`.
- **Test-Workload** — validate workloads/features after the VM is
  running.

Sequence files live in mode-specific subfolders selected by
`Invoke-SequenceByName` from `test-config.json`:

- `../sequences/gui/Test-<phase>.<guest-key>.json` — keystroke + OCR
  path (`keystrokeMechanism="GUI"`).
- `../sequences/ssh/Test-<phase>.<guest-key>.json` — SSH path
  (`keystrokeMechanism="SSH"`); falls back to the `gui/` copy when
  missing.

Filenames are identical across subfolders — the folder distinguishes
the modes. `../sequences/actions.json` (action reference) stays at the
top level.

## File naming

`Test-<phase>.<guest-key>.ps1`:

| File | Runs for |
|------|----------|
| `Test-Start.guest.amazon.linux.ps1`    | Amazon Linux OS install |
| `Test-Start.guest.ubuntu.desktop.ps1`  | Ubuntu Desktop OS install |
| `Test-Start.guest.windows.11.ps1`      | Windows 11 OS install |
| `Test-Workload.guest.amazon.linux.ps1` | Amazon Linux workload test |
| `Test-Workload.guest.ubuntu.desktop.ps1` | Ubuntu Desktop workload test |
| `Test-Workload.guest.windows.11.ps1`   | Windows 11 workload test |

Multiple tests per guest: add a suffix after the guest key.

```
Test-Workload.guest.amazon.linux.check-ssh.ps1
Test-Workload.guest.amazon.linux.run-workload.ps1
```

Scripts execute in alphabetical order; all must pass for the guest's
`Invoke-PoolTest` step to pass.

## Script interface

```powershell
param(
    [string]$HostType,    # "host.macos.utm" or "host.windows.hyper-v"
    [string]$GuestKey,    # e.g. "guest.amazon.linux"
    [string]$VMName       # e.g. "test-amazon-linux-01"
)
```

Runs as a child `pwsh -NoProfile -File` process — isolated scope,
cannot mutate runner state.

**Exit**: `0` = pass. Non-zero stops the runner and sends a notification.

When your script runs: the VM has been created, started, and confirmed
running. Do **not** stop/delete the VM or mutate `status.json` — the
runner owns those.

## Example — SSH connectivity

```powershell
# test/extensions/Test-Workload.guest.amazon.linux.check-ssh.ps1
param([string]$HostType, [string]$GuestKey, [string]$VMName)

$timeout = 180; $elapsed = 0
while ($elapsed -lt $timeout) {
    & ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ec2-user@$VMName "echo ok" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Output "ok"; exit 0 }
    Start-Sleep -Seconds 10; $elapsed += 10
}
Write-Error "SSH to $VMName timed out after ${timeout}s."
exit 1
```
