<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4269e850-8f14-4f24-8d83-52240f2bc8e0
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

# --- REGION: Record the stop intent
# The stop is on record, and this service's operation lock held, before the
# first change: the reboot sweep and a host refresh then honor the request
# instead of restarting the guest, and a concurrent Start cannot rebuild it
# mid-teardown. A request that cannot be recorded changes nothing. The marker
# is read first so the intent names how the service is deployed.
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
$runtimeDir = Initialize-YurunaRuntimeDir
$deployment = Get-ExtensionServiceDeploymentIdentity -Area 'pool-control-service' -RuntimeDir $runtimeDir
$hostingMode = if ($deployment.HostingMode -eq 'host-process') { 'host-process' } else { 'vm' }
$serviceOp = Enter-YurunaServiceOperation -Key 'pool-control' -VMName $VMName -Operation Stop -HostingMode $hostingMode -Script 'Stop-PoolControlServiceVM.ps1' -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit $ExitFailure
}
# Every exit below runs the finally at the end of this file, which records the
# result and releases the operation lock even inside a long-lived shell.
$serviceOpResult = 'failed'
$serviceOpFinalState = 'unknown'
try {

# --- REGION: Clear the service marker
# Read the marker BEFORE removing it. A -HostSideProof run records the host-side
# daemon's pid here; stop that process so the host-side proof is fully torn down.
# The pid is stopped only once it is shown to still be that daemon (its name,
# and its start time when the marker recorded one): a pid outlives its process
# and is handed to something else, which must be left running. A live process
# that is left running keeps the marker: it is the only record of that pid,
# and without it a later stop would find nothing and call the stop complete.
$m = Read-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir
$hostProcessLeftRunning = $false
if ($m) {
    if ($deployment.Pid) {
        $hostProcess = Get-ExtensionServiceHostProcessState -ProcessId ([int]$deployment.Pid) `
            -ProcessStartUnixMs ([long]$deployment.ProcessStartUnixMs) -ExpectedName 'pool-control-service'
        if ($hostProcess.IdentityVerified) {
            if ($PSCmdlet.ShouldProcess("pid $($deployment.Pid)", 'Stop host-side pool-control-service')) {
                Stop-Process -Id ([int]$deployment.Pid) -Force -ErrorAction SilentlyContinue
            } else {
                $hostProcessLeftRunning = $true
            }
        } elseif ($hostProcess.Alive) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_pid_unverified' -Arguments @{
                    pid = [string]$deployment.Pid; reason = [string]$hostProcess.Reason })
            $hostProcessLeftRunning = $true
        }
    }
    if (-not $hostProcessLeftRunning -and (Remove-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir -Confirm:$false)) {
        Write-Information "  Cleared pool-control-service marker (host will drop from Extension hosts)." -InformationAction Continue
    }
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
# Confirmed only by a final reading of absent, and only when no host-side
# process was left running: either one means the service is not stopped, and
# the stop request still stands.
$finalState = Get-VMState -VMName $VMName
$serviceOpFinalState = [string]$finalState
if ($hostProcessLeftRunning) {
    $serviceOpFinalState = 'host-process-running'
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_stop_incomplete' -Arguments @{ pid = [string]$deployment.Pid })
    exit $ExitFailure
}
if ($finalState -eq 'absent') {
    $serviceOpResult = 'confirmed'
    Write-Information "Pool-control service stopped; marker cleared; VM '$VMName' and its files removed." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit $ExitFailure
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -FinalState $serviceOpFinalState -Confirm:$false)
}
