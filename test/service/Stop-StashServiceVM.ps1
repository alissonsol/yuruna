<#PSScriptInfo
.VERSION 2026.09.13
.GUID 4234ee0c-21ea-43ed-ad32-56a9835e71aa
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

    In-flight uploads are not drained: a graceful stop runs first so the
    daemon's flush worker can push NAS-offline buffered uploads to the share,
    but deleting the disk then discards anything still buffered locally --
    the same caveat as any reimage. Committed (on-share) artifacts and their
    sidecars are durable. See https://yuruna.link/42f5e921.

.PARAMETER VMName   Name of the stash-service VM. Default: yuruna-stash-service.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop and remove the service VM and withdraw its advertisement')) { return }

$InformationPreference = 'Continue'

# --- REGION: Initialize service runtime
# See https://yuruna.link/42fffc2c-000b
# Left at the inherited 'Continue' deliberately, and it must stay that way:
# 'Stop' is not scoped to this script and would promote every host-contract
# helper's non-terminating error. Hard stops here are explicit Write-Error + exit.

# See https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit $ExitFailure
}

Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Information "Host type: $HostType" -InformationAction Continue
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- REGION: Clear the service marker
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
try {
    $runtimeDir = Initialize-YurunaRuntimeDir
    if (Remove-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtimeDir -Confirm:$false) {
        Write-Information "  Cleared stash-service marker (host will drop from Extension hosts)." -InformationAction Continue
    }
} catch { Write-Verbose "stash-service marker remove: $($_.Exception.Message)" }

# --- REGION: Publish the service withdrawal
# Publish the removal NOW: regenerate host.registration.json so the marker's absence
# (activeExtensions drops 'stash-service') reaches the aggregator on its next poll,
# without waiting for a test cycle -- the symmetric counterpart to Start-StashServiceVM.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Information "  Refreshed host.registration.json (host drops from Extension hosts within one aggregator poll)." -InformationAction Continue
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# --- REGION: Stop the VM
$state = Get-VMState -VMName $VMName
if ($state -eq 'absent') {
    Write-Information "  VM '$VMName' not registered with $HostType." -InformationAction Continue
} elseif ($state -in @('stopped', 'shutoff')) {
    Write-Information "  VM '$VMName' is already stopped." -InformationAction Continue
} else {
    # --- REGION: https://yuruna.link/42e220c4-0008
    Write-Information "Stopping '$VMName' (current state: $state)..." -InformationAction Continue
    $ok = Stop-VM -VMName $VMName -Confirm:$false
    if (-not $ok) {
        Write-Warning "Stop-VM returned `$false; escalating to Stop-VMForce..."
        [void](Stop-VMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
    }
}

# --- REGION: Remove the VM and its files
# See https://yuruna.link/42e220c4-0008
Write-Information "Removing VM '$VMName' and its on-disk files..." -InformationAction Continue
Remove-GuestVMQuietly -VMName $VMName -SkipStop -BestEffort

# --- REGION: Verify the final VM state
$finalState = Get-VMState -VMName $VMName
if ($finalState -eq 'absent') {
    Write-Information "Stash service stopped; marker cleared; VM '$VMName' and its files removed." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit $ExitFailure
