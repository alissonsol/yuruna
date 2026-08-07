<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456761
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Stops the Yuruna stash service VM and removes every file it owns --
    the registry/domain entry, the copied disk image, the cloud-init
    seed, and (UTM) the .utm bundle -- so the next Start-StashServiceVM
    builds from a clean slate with no leftover VM files.

    The durable stash data is untouched: received files, the per-artifact
    sidecar records, and the persisted SSH host key live on the NAS stash
    share, not on the disposable VM disk. Start rebuilds the disk from the
    base image.

    In-flight uploads are not drained (sec 3.2): a graceful stop runs first
    so the daemon's flush worker can push NAS-offline buffered uploads to the
    share, but deleting the disk then discards anything still buffered
    locally -- the same reimage caveat as sec 8.4. Committed (on-share)
    artifacts and their sidecars are durable.

.PARAMETER VMName   Name of the stash-service VM. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# two lines above on purpose: an explicit level is the operator's choice and
# replaces this script's own default. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# Clear the Extension hosts advertisement: this host no longer runs a stash service.
# (Written by Start-StashServiceVM; folded into host.registration.json by
# Write-HostRegistrationRecord and read by the pool-aggregator-service.) Removed regardless
# of VM state -- a stopped/absent server must drop from the dashboard. Best-effort.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
try {
    $runtimeDir = Initialize-YurunaRuntimeDir
    if (Remove-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtimeDir -Confirm:$false) {
        Write-Output "  Cleared stash-service marker (host will drop from Extension hosts)."
    }
} catch { Write-Verbose "stash-service marker remove: $($_.Exception.Message)" }

# Publish the removal NOW: regenerate host.registration.json so the marker's absence
# (activeExtensions drops 'stash-service') reaches the aggregator on its next poll,
# without waiting for a test cycle -- the symmetric counterpart to Start-StashServiceVM.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Output "  Refreshed host.registration.json (host drops from Extension hosts within one aggregator poll)."
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

$state = Get-VMState -VMName $VMName
if ($state -eq 'absent') {
    Write-Output "  VM '$VMName' not registered with $HostType."
} elseif ($state -in @('stopped', 'shutoff')) {
    Write-Output "  VM '$VMName' is already stopped."
} else {
    # Graceful stop FIRST: a clean systemd shutdown lets the stash daemon's flush
    # worker push any NAS-offline buffered uploads to the share before the disk is
    # deleted below, shrinking the unflushed-loss window. A hard stop is still
    # acceptable, so escalate on a stuck graceful stop rather than blocking (the
    # teardown below force-stops a half-up daemon).
    Write-Output "Stopping '$VMName' (current state: $state)..."
    $ok = Stop-VM -VMName $VMName -Confirm:$false
    if (-not $ok) {
        Write-Warning "Stop-VM returned `$false; escalating to Stop-VMForce..."
        [void](Stop-VMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
    }
}

# Remove the VM and every on-disk file it owns. Run unconditionally -- even an
# 'absent' (unregistered) VM can leave a disk directory behind from a New-VM that
# crashed mid-build, and this sweeps it. Best-effort: a cleanup hiccup must not
# abort the stop, and the host contract Remove-VM warns on any file it cannot
# delete. -SkipStop: the stop above already ran; Remove-VM force-stops internally
# if the graceful path did not fully settle.
Write-Output "Removing VM '$VMName' and its on-disk files..."
Remove-GuestVMQuietly -VMName $VMName -SkipStop -BestEffort

$finalState = Get-VMState -VMName $VMName
if ($finalState -eq 'absent') {
    Write-Output "Removed '$VMName' and its VM files."
    exit 0
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit 1
