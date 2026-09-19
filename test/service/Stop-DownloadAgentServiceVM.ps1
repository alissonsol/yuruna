<#PSScriptInfo
.VERSION 2026.09.18
.GUID 429cbb3b-d9b5-4a3c-af14-67208c19e773
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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
    Stop the Download-agent service and clear its marker.
.DESCRIPTION
    Symmetric with Start-DownloadAgentServiceVM. Removes
    runtime/download-agent-service.json (so Test.Capability drops the
    download-agent-service area) and refreshes the registration record so the
    host clears from the dashboard's Extension hosts table. Then tears down the
    download-agent-service VM and every file it owns -- the registry/domain
    entry, the copied disk image, the cloud-init seed, and (UTM) the .utm bundle
    -- so the next Start rebuilds from a clean slate.

    The image pool itself lives on the pool share, not on the disposable VM
    disk, so nothing downloaded is lost: a rebuilt agent adopts the same pool,
    re-reads its pointers, and serves the existing generations immediately.

    The Go service posts an active:false beacon goodbye on SIGTERM/exit, so the
    aggregator's Extension-hosts row clears from both paths.
.PARAMETER VMName
    Name of the download-agent-service VM. Default:
    yuruna-download-agent-service.
.EXAMPLE
    pwsh test/service/Stop-DownloadAgentServiceVM.ps1
    # Clears the marker, refreshes registration, then removes the VM.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service'
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
Import-Module (Join-Path $ModulesDir 'Test.DownloadAgentService.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if (Remove-DownloadAgentServiceMarker -RuntimeDir $runtimeDir) {
    Write-Information "  Cleared download-agent-service marker (host will drop from Extension hosts)." -InformationAction Continue
}

# --- REGION: Publish the service withdrawal
# See https://yuruna.link/42e220c4-0008
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Information "  Refreshed host.registration.json (host drops from Extension hosts within one aggregator poll)." -InformationAction Continue
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# --- REGION: Stop the VM
# See https://yuruna.link/42e220c4-0008
$state = Get-VMState -VMName $VMName
if ($state -eq 'absent') {
    Write-Information "  VM '$VMName' not registered with $HostType." -InformationAction Continue
} elseif ($state -in @('stopped', 'shutoff')) {
    Write-Information "  VM '$VMName' is already stopped." -InformationAction Continue
} else {
    Write-Information "Stopping '$VMName' (current state: $state)..." -InformationAction Continue
    $ok = Stop-VM -VMName $VMName -Confirm:$false
    if (-not $ok) {
        Write-Warning "Stop-VM returned `$false; escalating to Stop-VMForce..."
        [void](Stop-VMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
    }
}

# --- REGION: Remove the VM and its files
# -SkipStop: the stop above already ran; Remove-VM force-stops internally if the
# graceful path did not fully settle.
Write-Information "Removing VM '$VMName' and its on-disk files..." -InformationAction Continue
Remove-GuestVMQuietly -VMName $VMName -SkipStop -BestEffort

# --- REGION: Verify the final VM state
$finalState = Get-VMState -VMName $VMName
if ($finalState -eq 'absent') {
    Write-Information "Download-agent service stopped; marker cleared; VM '$VMName' and its files removed. The image pool on the pool share is untouched." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit $ExitFailure
