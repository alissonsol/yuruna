# Test Extensions

Extension scripts run custom tests against each guest VM after it has been
created, started, and verified running. They validate that workloads,
configurations, and features work correctly on each guest.

## Quick start

1. Create a `.ps1` script in this directory following the naming convention below
2. The runner discovers it automatically on the next cycle
3. Exit `0` for pass, non-zero for fail

## File naming

Scripts must be named `Test-Workload.<guest-key>.ps1`:

| File | Runs for |
|------|----------|
| `Test-Workload.guest.amazon.linux.ps1` | Amazon Linux guest |
| `Test-Workload.guest.ubuntu.desktop.ps1` | Ubuntu Desktop guest |
| `Test-Workload.guest.windows.11.ps1` | Windows 11 guest |

To run **multiple tests** for a guest, add a suffix after the guest key:

```
Test-Workload.guest.amazon.linux.check-ssh.ps1
Test-Workload.guest.amazon.linux.run-workload.ps1
```

Scripts execute in alphabetical order. All scripts matching a guest key must
pass for the guest's `CustomTests` step to pass.

## Script interface

Each extension script receives three parameters:

```powershell
param(
    [string]$HostType,    # "host.macos.utm" or "host.windows.hyper-v"
    [string]$GuestKey,    # e.g. "guest.amazon.linux"
    [string]$VMName       # e.g. "test-amazon-linux01"
)
```

The script runs as a **child process** (`pwsh -NoProfile -File`), so it has
its own scope and cannot affect the runner's state.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Test passed |
| Non-zero | Test failed — runner stops and sends a notification |

### What you can assume

When your script runs:

- The VM has been created by `New-VM.ps1`
- The VM has been started and confirmed running
- The host type matches the platform you are on

### What you should not do

- Do not delete or stop the VM (the runner handles cleanup)
- Do not modify `status.json` (the runner manages it)

## PSScriptInfo header

All extension scripts should include a PSScriptInfo header with a GUID
starting with `42` and version `0.1`. See the existing `Test-Workload.*.ps1`
files for the template.

## Example: SSH connectivity check

```powershell
# test/extensions/Test-Workload.guest.amazon.linux.check-ssh.ps1
param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

Write-Output "Checking SSH connectivity to $VMName..."

$timeout = 180
$elapsed = 0
while ($elapsed -lt $timeout) {
    $result = & ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ec2-user@$VMName "echo ok" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Output "SSH connection successful."
        exit 0
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
}

Write-Error "SSH connection to $VMName timed out after ${timeout}s."
exit 1
```

## Example: Run a workload

```powershell
# test/extensions/Test-Workload.guest.amazon.linux.enable-code.ps1
param(
    [string]$HostType,
    [string]$GuestKey,
    [string]$VMName
)

Write-Output "Deploying workload to $VMName..."

# For yuruna "Code" workload:
# & ssh ec2-user@$VMName "cd /workload && ./enable-code.sh"
# if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Output "Workload completed successfully."
exit 0
```
