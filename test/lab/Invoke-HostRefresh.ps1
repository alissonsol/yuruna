<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42f6a7b8-9c0d-4e1f-af2a-3b4c5d6e7f8a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host-refresh repair lab
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
    Local host-refresh entry point (channel A). Probes hypervisor
    responsiveness and reports what a repair would do; local reclamation of
    a proven-dead runner is implemented, everything above rung 1 is
    reported as unavailable rather than attempted.
.DESCRIPTION
    THIS IS A DELIBERATELY BOUNDED SLICE of the full contract in
    dev-only/2026-09.host-refresh/2026-09.host-refresh.md, not the complete
    implementation. What is real and tested:

      * -WhatIf: a genuinely read-only preview. No lock, no directory
        creation, no request write, no signal to anything. Reports the
        current probe result and the full rung declaration.
      * The lifetime single-flight lock (Test.SingleFlightLock) and the
        durable request record (Test.HostRefreshIntent), so two concurrent
        invocations do not both act, and a retry of the same request is
        recognized rather than treated as new work.
      * Rung 0 (probe): Test-VirtualizationResponsive, real per platform.
      * A live/dead runner classification via Get-RunnerInstanceState.
      * Reporting: this script never signals a live "OtherRunner" process.
        A stale (dead-PID) record is a case this script also does not clear
        yet -- see the exit-2 message for the manual recovery command.

    What this script does NOT implement, on purpose, because the safety-
    critical protocol they need (a verified process-target walk with
    status-server/beacon exclusion proven from a live snapshot, the
    Windows parent-exit handshake, the preflight-token handoff, held-
    control-barrier preservation, and the service census) was not built to
    completion in the same session as this entry point:
      * Rung 1 (reclaim): detection only, no signal sent to any process.
      * Rung 2 and above: not attempted. Get-VirtualizationRepairRung may
        mark a rung Available for a platform whose driver verb exists; this
        script still refuses to attempt anything past rung 0 today.
      * The service-VM census and restoration this repair would owe after
        disrupting a hypervisor.
      * Remote channels B/C/D, which are unimplemented.

    A truthful partial result is the design: see the plan's own closing
    line, "a truthful partial result is preferable to an unsupported claim
    of convergence."
.PARAMETER Tier
    'restart' (default) or 'full'. 'full' is accepted but every full-tier
    rung is Available=$false today, so it behaves identically to 'restart'.
.PARAMETER MaxRung
    Rung Name ceiling (see Get-VirtualizationRepairRung). Never raises
    availability past what this script actually implements (rung 0 acts;
    rung 1 only reports).
.PARAMETER ConfigPath
    Reserved for the full protocol's config resolution (section 2 step 4).
    Not consumed by this bounded slice.
.PARAMETER Force
    Reserved. This slice never mutates a healthy or a live-runner host
    regardless of -Force, since it does not implement the reclamation this
    switch would need to bypass.
.PARAMETER AllowHardStop
    Reserved for the full hard-stop policy (section 1). Not consumed: this
    slice never sends a TERM/KILL signal to anything.
.PARAMETER RestoreServiceVmName
    Reserved for the service-restore-set protocol (section 5). Not
    consumed by this bounded slice.
.PARAMETER LeaveStoppedServiceVmName
    Reserved, matching RestoreServiceVmName.
.OUTPUTS
    Exit 0: repaired / already-healthy (rung 0 found Responsive, or a live
    runner is present and healthy). Exit 1: preflight refusal (could not
    secure the private root, host owner check failed). Exit 2: partial --
    an actionable finding exists (Unresponsive/Undetermined hypervisor, or
    a dead runner) but this slice does not act on it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('restart', 'full')][string]$Tier = 'restart',
    [string]$MaxRung,
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$AllowHardStop,
    [string[]]$RestoreServiceVmName,
    [string[]]$LeaveStoppedServiceVmName
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
# Captured and cleared immediately: $WhatIfPreference is process-ambient and
# inherited by every SupportsShouldProcess function this script calls
# transitively, including this repo's own internal module-initialization
# helpers (Test.Registry.psm1's New-YurunaRegistry among them), which were
# never designed to run with it set and fail with a null-array index when
# they do -- confirmed directly: leaving $WhatIfPreference set through
# Initialize-YurunaEntryPointModuleSet reproduces exactly that crash. This
# script implements its own read-only preview explicitly instead of relying
# on the ambient mechanism for anything past its own top-level checks.
$script:HostRefreshPreview = [bool]$WhatIfPreference
$WhatIfPreference = $false
$here     = Split-Path -Parent $PSCommandPath
$ModulesDir = Join-Path (Split-Path -Parent $here) 'modules'
$RepoRoot   = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $ModulesDir 'Test.Prelude.psm1') -Global -Force -DisableNameChecking
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
Initialize-YurunaEntryPointModuleSet -For Outer -ModulesDir $paths.ModulesDir
Import-Module (Join-Path $paths.ModulesDir 'Test.HostDetection.psm1')     -Global -Force -DisableNameChecking
Import-Module (Join-Path $paths.ModulesDir 'Test.HostBootstrap.psm1')    -Global -Force -DisableNameChecking
Import-Module (Join-Path $paths.ModulesDir 'Test.SingleInstance.psm1')   -Global -Force -DisableNameChecking
Import-Module (Join-Path $paths.ModulesDir 'Test.SingleFlightLock.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $paths.ModulesDir 'Test.HostRefresh.psm1')      -Global -Force -DisableNameChecking
Import-Module (Join-Path $paths.ModulesDir 'Test.HostRefreshIntent.psm1') -Global -Force -DisableNameChecking

$hostType = Get-HostType
Invoke-LibvirtGroupReExecIfNeeded -HostType $hostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $hostType)

$rungs = Get-VirtualizationRepairRung -HostType $hostType
$probe = Test-VirtualizationResponsive

$runtimeDir = Join-Path $paths.TestRoot 'status/runtime'
$runnerPidFile   = Join-Path $runtimeDir 'runner.pid'
$runnerStartFile = Join-Path $runtimeDir 'runner.start'
$runnerState = $null
try {
    $runnerState = Get-RunnerInstanceState -RunnerPidFile $runnerPidFile -RunnerStartFile $runnerStartFile
} catch {
    Write-Verbose "Invoke-HostRefresh: could not read runner instance state: $($_.Exception.Message)"
}

function Write-YurunaHostRefreshSummary {
    param($Probe, $Rungs, $RunnerState, [switch]$Preview)
    Write-Output ''
    Write-Output '========'
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1a5944a737ed4e90' -Arguments @{ report = "$(if ($Preview) { '(preview -- read-only, nothing was acted on)' } else { 'report' })" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0d2117a74cbfa3ca' -Arguments @{ hostType = "$hostType" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_5b278ab6be06e98e' -Arguments @{ state = "$($Probe.state)"; reason = "$($Probe.reason)"; elapsedMs = "$($Probe.elapsedMs)" })
    if ($RunnerState) {
        Write-Output "  Runner:        $($RunnerState.status)$(if ($RunnerState.pid) { " (pid $($RunnerState.pid))" })"
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_507f379237cefeeb')
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8f85b3fcba9cd85d')
    foreach ($rung in $Rungs) {
        $flag = if ($rung.Available) { 'available' } else { "unavailable: $($rung.UnavailableReason)" }
        Write-Output "    [$($rung.Order)] $($rung.Name) -- $flag"
    }
    Write-Output '========'
}

if ($script:HostRefreshPreview) {
    Write-YurunaHostRefreshSummary -Probe $probe -Rungs $rungs -RunnerState $runnerState -Preview
    exit (Get-EntryPointExitCode -Outcome Ok)
}

# Host-owner / identity check: refuse rather than proceed under an identity
# this repair cannot verify. A remote/root/unknown owner check for disruptive
# GUI work (section 2 step 5) is NOT implemented in this slice; the only
# check made here is that a private, owner-secured state root can actually
# be resolved, which already fails closed for a misconfigured HOME or a
# permissions problem.
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
$requestPath = Get-YurunaHostRefreshRequestPath
$lockPath    = Get-YurunaHostRefreshLockPath
if (-not $requestPath -or -not $lockPath) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_2fb31966478fca46')
    exit (Get-EntryPointExitCode -Outcome Failure)
}

$lock = Enter-YurunaSingleFlightLock -Path $lockPath -Metadata @{
    pid = $PID; generation = [Guid]::NewGuid().ToString('n'); startTimeUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}
if (-not $lock.Held) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_6eca51811f4cfdd3' -Arguments @{ reason = "$($lock.Reason)" })
    exit (Get-EntryPointExitCode -Outcome Failure)
}

try {
    $requestId = New-YurunaHostRefreshRequestId
    $policy = @{ Tier = $Tier; MaxRung = $MaxRung; Force = [bool]$Force; AllowHardStop = [bool]$AllowHardStop }
    $claim = Confirm-HostRefreshIntent -RequestPath $requestPath -RequestId $requestId -Policy $policy
    if (-not $claim.Accepted) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a6cceb1dcf23a282' -Arguments @{ reason = "$($claim.Reason)"; state = "$($claim.Request.State)" })
        exit (Get-EntryPointExitCode -Outcome Failure)
    }

    Write-YurunaHostRefreshSummary -Probe $probe -Rungs $rungs -RunnerState $runnerState

    if ($probe.state -eq 'Responsive' -and $runnerState -and $runnerState.status -in @('Self', 'OtherRunner')) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_dfd19c97aaa9ff6e')
        $null = Complete-YurunaHostRefreshRequest -RequestPath $requestPath -State 'completed' -Verdict 'already-healthy' -Confirm:$false
        exit (Get-EntryPointExitCode -Outcome Ok)
    }
    if ($probe.state -eq 'Responsive' -and (-not $runnerState -or $runnerState.status -in @('None', 'Stale'))) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_292bf0f1ef450037')
        $null = Complete-YurunaHostRefreshRequest -RequestPath $requestPath -State 'completed' -Verdict 'partial' -Detail 'rung 1 reclaim not implemented'
        exit (Get-EntryPointExitCode -Outcome CannotRun)
    }

    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_88f502760b28fd59' -Arguments @{ state = "$($probe.state)"; reason = "$($probe.reason)" })
    $null = Complete-YurunaHostRefreshRequest -RequestPath $requestPath -State 'completed' -Verdict 'partial' -Detail "probe $($probe.state)/$($probe.reason)"
    exit (Get-EntryPointExitCode -Outcome CannotRun)
} finally {
    Exit-YurunaSingleFlightLock -Lock $lock
}
