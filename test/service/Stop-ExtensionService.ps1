<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42046a95-dbf3-4dd6-b06d-4ee539c58a98
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
    Stops an extension hosted in a VM or host process and records its stop intent.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][ValidateSet('stash', 'download-agent', 'pool-control')][string]$ServiceKey,
    [Parameter(Mandatory)][string]$Area,
    [Parameter(Mandatory)][string]$ServiceName,
    [Parameter(Mandatory)][string]$CallerScript
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop the extension service and withdraw its advertisement')) { return }

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

# --- REGION: Record the stop intent
# The stop is on record, and this service's operation lock held, before the
# first change: the reboot sweep and a host refresh then honor the request
# instead of restarting the guest, and a concurrent Start cannot rebuild it
# mid-teardown. A request that cannot be recorded changes nothing.
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
$deployment = Get-ExtensionServiceDeploymentIdentity -Area $Area -RuntimeDir $runtimeDir
$hostingMode = if ($deployment.HostingMode -eq 'host-process') { 'host-process' } else { 'vm' }
$serviceOp = Enter-YurunaServiceOperation -HostingMode $hostingMode -Key $ServiceKey -VMName $VMName -Operation Stop -Script (Split-Path -Leaf $CallerScript) -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit $ExitFailure
}
# Every exit below runs the finally at the end of this file, which records the
# result and releases the operation lock even inside a long-lived shell.
$serviceOpResult = 'failed'
$serviceOpFinalState = 'unknown'
try {

# --- REGION: Clear the service marker only after stopping a verified host process
$m = Read-ExtensionServiceMarker -Area $Area -RuntimeDir $runtimeDir
$hostProcessLeftRunning = $false
$markerLeftPresent = $false
if ($m) {
    if ($deployment.Pid) {
        $hostProcess = Get-ExtensionServiceHostProcessState -ProcessId ([int]$deployment.Pid) `
            -ProcessStartUnixMs ([long]$deployment.ProcessStartUnixMs) -ExpectedName $Area
        if ($hostProcess.IdentityVerified) {
            if ($PSCmdlet.ShouldProcess("pid $($deployment.Pid)", "Stop host-side $Area")) {
                $targetProcess = $null
                try {
                    $targetProcess = Get-Process -Id ([int]$deployment.Pid) -ErrorAction Stop
                    # Capture the handle and recheck identity before stopping it;
                    # a PID can be reused between the marker lookup and this call.
                    $null = $targetProcess.SafeHandle
                    $startMs = [DateTimeOffset]::new($targetProcess.StartTime).ToUnixTimeMilliseconds()
                    if ($deployment.ProcessStartUnixMs -le 0 -or
                        [Math]::Abs([decimal]$startMs - [decimal]$deployment.ProcessStartUnixMs) -gt 2000) {
                        $hostProcessLeftRunning = $true
                    } else {
                        Stop-Process -InputObject $targetProcess -Force -ErrorAction Stop
                        $hostProcessLeftRunning = -not $targetProcess.WaitForExit(5000)
                    }
                } catch {
                    $hostProcessLeftRunning = $true
                    try {
                        if ($targetProcess -and $targetProcess.HasExited) { $hostProcessLeftRunning = $false }
                    } catch { Write-Verbose "Process exit state unavailable: $_" }
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_pid_unverified' -Arguments @{
                        pid = [string]$deployment.Pid; reason = [string]$_.Exception.Message })
                } finally {
                    if ($targetProcess) { $targetProcess.Dispose() }
                }
            } else {
                $hostProcessLeftRunning = $true
            }
        } elseif ($hostProcess.Alive -or $hostProcess.Reason -ne 'not-running') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_pid_unverified' -Arguments @{
                    pid = [string]$deployment.Pid; reason = [string]$hostProcess.Reason })
            $hostProcessLeftRunning = $true
        }
    }
    if (-not $hostProcessLeftRunning) {
        $markerLeftPresent = -not (Remove-ExtensionServiceMarker -Area $Area -RuntimeDir $runtimeDir -Confirm:$false)
        if (-not $markerLeftPresent) {
            Write-Information "  Cleared $Area marker (host will drop from Extension hosts)." -InformationAction Continue
        }
    }
}


if ($hostProcessLeftRunning -or $markerLeftPresent) {
    $serviceOpFinalState = if ($hostProcessLeftRunning) { 'host-process-running' } else { 'marker-present' }
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_stop_incomplete' -Arguments @{ pid = [string]$deployment.Pid })
    exit $ExitFailure
}

# --- REGION: Publish the service withdrawal
# Publish the removal NOW: regenerate host.registration.json so the marker's absence
# (activeExtensions drops this service) reaches the aggregator on its next poll,
# without waiting for a test cycle.
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
# Confirmed only by a final reading of absent: a removal that left the VM
# registered is a failed stop, and the stop request still stands.
$finalState = Get-VMState -VMName $VMName
$serviceOpFinalState = [string]$finalState
if ($hostProcessLeftRunning) {
    $serviceOpFinalState = 'host-process-running'
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_poolcontrol_stop_incomplete' -Arguments @{ pid = [string]$deployment.Pid })
    exit $ExitFailure
}
if ($finalState -eq 'absent') {
    $serviceOpResult = 'confirmed'
    Write-Information "$ServiceName service stopped; marker cleared; VM '$VMName' and its files removed." -InformationAction Continue
    exit $ExitOk
}
Write-Warning "VM '$VMName' final state: $finalState (expected absent after removal). Inspect via the host's tooling, then re-run or use Remove-TestVMFiles.ps1."
exit $ExitFailure
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -FinalState $serviceOpFinalState -Confirm:$false)
}
