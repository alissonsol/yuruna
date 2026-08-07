<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42d19b7f-33bb-437b-9765-9cdf3d82f362
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
    pwsh test/Stop-DownloadAgentServiceVM.ps1
    # Clears the marker, refreshes registration, then removes the VM.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service'
)

$InformationPreference = 'Continue'

# $ErrorActionPreference is deliberately left at its inherited 'Continue', and
# must stay that way. A script-scoped 'Stop' is not scoped to the script: an
# advanced function invoked from here runs under it too, so every host-contract
# call below would have its NON-terminating errors promoted to terminating ones.
# Those helpers report and carry on by design -- Get-VMState answers 'absent' for
# a VM that was never created, Remove-GuestVMQuietly -BestEffort is documented to
# tolerate an already-gone VM -- and under 'Stop' each of those intended outcomes
# ends the teardown instead. The sibling service teardowns (stash, caching proxy)
# run at 'Continue' for the same reason.

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# lines above on purpose: an explicit level is the operator's choice and replaces
# this script's own default. $InformationPreference is then re-read from the
# global the cascade writes, because the script-scoped assignment above shadows
# it for the rest of this file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
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

# Clear the marker FIRST, before anything touches the VM. The aggregator polls
# this host's registration on its own schedule, so the window between "the VM is
# being destroyed" and "the host stops claiming the area" is a window in which
# peers are told to fetch images from an endpoint that is already gone. Removing
# the claim first makes the worst case a host that looks agent-less slightly
# early, which costs one fallback download instead of a failed one.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.DownloadAgentService.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if (Remove-DownloadAgentServiceMarker -RuntimeDir $runtimeDir) {
    Write-Information "  Cleared download-agent-service marker (host will drop from Extension hosts)." -InformationAction Continue
}

# Publish the removal NOW: regenerate host.registration.json so the marker's
# absence (activeExtensions drops 'download-agent-service') reaches the
# aggregator on its next poll, without waiting for a test cycle. Best-effort
# telemetry -- never fails the stop. Set-Variable -Scope Global keeps
# PSAvoidGlobalVars quiet.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Information "  Refreshed host.registration.json (host drops from Extension hosts within one aggregator poll)." -InformationAction Continue
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# Tear down the VM and every file it owns so the next Start rebuilds from a
# clean slate. A graceful stop runs first (clean systemd shutdown, which is also
# what lets the daemon post its beacon goodbye and release the pool lease); the
# teardown then removes the domain, disk, seed, and (UTM) bundle. Run
# best-effort: a host that never built the VM has state 'absent' here, in which
# case the sweep is a no-op that still clears any disk dir left by a crashed
# New-VM.
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

# -SkipStop: the stop above already ran; Remove-VM force-stops internally if the
# graceful path did not fully settle.
Write-Information "Removing VM '$VMName' and its on-disk files..." -InformationAction Continue
Remove-GuestVMQuietly -VMName $VMName -SkipStop -BestEffort

$finalState = Get-VMState -VMName $VMName
if ($finalState -eq 'absent') {
    Write-Information "Download-agent service stopped; marker cleared; VM '$VMName' and its files removed. The image pool on the pool share is untouched." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit $ExitFailure
