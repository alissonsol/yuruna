<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42f6a7b8-c9d0-4e12-8345-6a7b8c9d0e1f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool-control service extension service
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
    Stop the Pool control service and clear its marker.
.DESCRIPTION
    Symmetric with Start-PoolControlServiceVM. Removes runtime/pool-control-service.json (so
    Test.Capability drops the pool-control-service area) and refreshes the registration
    record so the host clears from the dashboard's Extension hosts table. Then
    tears down the pool-control-service VM and every file it owns -- the registry/domain
    entry, the copied disk image, the cloud-init seed, and (UTM) the .utm bundle --
    so the next Start rebuilds from a clean slate. The durable pool state lives on
    the pool NAS, not on the disposable VM disk. When the service was instead run
    with -HostSideProof, the marker carries the host-side pid and that process is
    stopped too. The Go service posts an active:false beacon goodbye on
    SIGTERM/exit, so the aggregator's Extension-hosts row clears from both paths.
.PARAMETER VMName
    Name of the pool-control-service VM. Default: yuruna-pool-control-service.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-pool-control-service'
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

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
$ExitOk     = Get-EntryPointExitCode -Outcome Ok
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Information "Host type: $HostType" -InformationAction Continue
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# Read the marker BEFORE removing it. A -HostSideProof run records the host-side
# daemon's pid here; stop that process so the host-side proof is fully torn down.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
$m = Read-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir
if ($m) {
    if ($m.pid -and $PSCmdlet.ShouldProcess("pid $($m.pid)", 'Stop host-side pool-control-service')) {
        Stop-Process -Id ([int]$m.pid) -Force -ErrorAction SilentlyContinue
    }
    if (Remove-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir -Confirm:$false) {
        Write-Information "  Cleared pool-control-service marker (host will drop from Extension hosts)." -InformationAction Continue
    }
}

# Publish the removal NOW: regenerate host.registration.json so the marker's
# absence (activeExtensions drops 'pool-control-service') reaches the aggregator on its
# next poll, without waiting for a test cycle. Best-effort telemetry -- never
# fails the stop. Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Information "  Refreshed host.registration.json (host drops from Extension hosts within one aggregator poll)." -InformationAction Continue
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# Tear down the pool-control-service VM and every file it owns so the next Start rebuilds
# from a clean slate. The durable pool state lives on the pool NAS, not on the
# disposable VM disk, which Start rebuilds from the base image. A graceful stop
# runs first (clean systemd shutdown); the teardown then removes the domain,
# disk, seed, and (UTM) bundle. Run best-effort: an operator who only used
# -HostSideProof has no VM here, in which case Get-VMState is 'absent' and the
# sweep is a no-op that still clears any disk dir left by a crashed New-VM.
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
    Write-Information "Pool-control service stopped; marker cleared; VM '$VMName' and its files removed." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit 1
