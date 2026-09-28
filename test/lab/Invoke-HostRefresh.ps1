<#PSScriptInfo
.VERSION 2026.09.27
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
    Repair a wedged local hypervisor and leave the runner, its services and
    the listener running again -- or report exactly why it did not.
.DESCRIPTION
    One bounded repair attempt, the same implementation every channel uses:
    an operator's shell, the macOS bootstrap's refresh dispatch, the status
    listener, a pool-control request and the outer runner's automatic
    trigger. It climbs a ladder of rungs (probe, reclaim, start-if-stopped,
    restart-if-hung, ...) up to the requested ceiling, running only rungs
    this checkout can execute on this platform, re-probing after each, and
    then converges services, the listener and the runner on a separate
    reserve of time.

    Safety properties:
      * One repair per host account at a time (a held-open lifetime lock),
        one durable request journal and recovery record under
        $HOME/.yuruna/host-refresh, outside every served directory.
      * Nothing prompts: no console question, no consent dialog, no
        interactive sudo. Every native call is bounded by the invocation's
        915-second budget (60 s startup, 600 s ladder, 240 s convergence,
        15 s reporting).
      * Only proven-owned runner processes are ever signaled; the status
        listener, its beacon and another account's processes never are.
        Operator pauses, holds and restart requests survive the repair.
      * Restarting UTM can suspend running guests, and a hard stop can power
        them off uncleanly; a hard stop happens only with -AllowHardStop on a
        local request.
      * -WhatIf is a read-only plan: nothing is created, locked, written,
        signaled or started.

    Everything an attempt disrupted stays an outstanding obligation until
    verified or disposed; -Resume retries the one unresolved request and
    -DisposeObligation records, audited, that an obligation was handled by
    hand.
.PARAMETER Tier
    restart (orders 0-4) or full (orders 0-6, local only).
.PARAMETER MaxRung
    A rung name; it only lowers the tier's ceiling.
.PARAMETER ConfigPath
    The runner configuration to restart with; by default the runner's
    recorded configuration, then the runtime's configuration snapshot, then
    test/test.config.yml.
.PARAMETER Force
    Proceed past the healthy-cycle check: a responsive hypervisor with a
    healthy runner gets rung 1 (reclaim and verified restart) and no higher.
.PARAMETER AllowHardStop
    Permit a hard stop of UTM and its guest helpers when a graceful quit
    does not finish. Local requests only.
.PARAMETER RestoreServiceVmName
    Service VMs of unknown state to restore after a hypervisor restart.
.PARAMETER LeaveStoppedServiceVmName
    Service VMs of unknown state to leave stopped.
.PARAMETER Resume
    Retry the one unresolved request with its stored policy.
.PARAMETER DisposeObligation
    Record that outstanding obligations (service:<key>, endpoint:<key>,
    runner, listener, controls) were handled outside the repair.
.PARAMETER RequestId
    A request already admitted by the listener, pool-control or the runner;
    it carries no policy of its own.
.PARAMETER DeadlineTickMs
    The invocation's total expiry on the boot-relative tick clock, from a
    parent process; it can only shorten the budget.
.PARAMETER PreAdmissionDeadlineTickMs
    The startup expiry from a parent process; it can only shorten it.
.OUTPUTS
    Preview: one Yuruna.HostRefreshPreview object. Executing: nothing on the
    success stream; the verdict is the exit code, the private journal and the
    public runtime/host-refresh.state.json.
      0  repaired, already-healthy, preview, disposed
      1  refused, failed
      2  partial, still-unresponsive, abandoned
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'New')]
param(
    [Parameter(ParameterSetName = 'New')][ValidateSet('restart', 'full')][string]$Tier = 'restart',
    [Parameter(ParameterSetName = 'New')][ValidateSet('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')][string]$MaxRung,
    [Parameter(ParameterSetName = 'New')][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(ParameterSetName = 'New')][switch]$Force,
    [Parameter(ParameterSetName = 'New')][switch]$AllowHardStop,
    [Parameter(ParameterSetName = 'New')][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string[]]$RestoreServiceVmName,
    [Parameter(ParameterSetName = 'New')][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string[]]$LeaveStoppedServiceVmName,
    [Parameter(ParameterSetName = 'Resume', Mandatory)][switch]$Resume,
    [Parameter(ParameterSetName = 'Dispose', Mandatory)][ValidatePattern('^(service:[a-z0-9][a-z0-9-]{0,62}|endpoint:[a-z0-9][a-z0-9-]{0,62}|runner|listener|controls)$')][string[]]$DisposeObligation,
    [Parameter(ParameterSetName = 'Internal', Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RequestId,
    [ValidateRange(1, [long]::MaxValue)][long]$DeadlineTickMs,
    [ValidateRange(1, [long]::MaxValue)][long]$PreAdmissionDeadlineTickMs
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
# $WhatIfPreference is process-ambient: left set, every SupportsShouldProcess
# function reached transitively -- module-initialization helpers included --
# would run in preview, and some fail outright. This script implements its own
# read-only preview, so it records the request and clears the preference.
$script:HostRefreshPreview = [bool]$WhatIfPreference
$WhatIfPreference = $false

# Restored in finally, null-aware: an in-process caller keeps its own
# preferences and environment, and an unset variable is removed rather than
# left empty (an empty variable is still inherited by children).
$savedPreference = @{
    Confirm = $ConfirmPreference; ErrorAction = $ErrorActionPreference; Information = $InformationPreference
}
$savedEnvironment = @{}
foreach ($name in @('YURUNA_NONINTERACTIVE', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR')) {
    $savedEnvironment[$name] = @{ Present = (Test-Path -LiteralPath "Env:$name"); Value = [Environment]::GetEnvironmentVariable($name) }
}
$ConfirmPreference = 'None'
$InformationPreference = 'Continue'
$ErrorActionPreference = 'Stop'
# Before any relaunch: the relaunched child inherits the environment.
$env:YURUNA_NONINTERACTIVE = '1'
$exitCode = 1
$phase = 'startup'
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force -DisableNameChecking
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
    $moduleSet = (Get-Command Initialize-YurunaEntryPointModuleSet).Parameters['For'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues }
    if (@($moduleSet) -notcontains 'Refresh') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_refresh_command_missing' -Arguments @{ command = 'Initialize-YurunaEntryPointModuleSet -For Refresh'; module = 'Test.Prelude' })
        exit 1
    }
    Initialize-YurunaEntryPointModuleSet -For Refresh -ModulesDir $paths.ModulesDir

    $budgetArguments = @{}
    if ($PSBoundParameters.ContainsKey('DeadlineTickMs')) { $budgetArguments.ExpiryTick = $DeadlineTickMs }
    if ($PSBoundParameters.ContainsKey('PreAdmissionDeadlineTickMs')) { $budgetArguments.PreAdmissionExpiryTick = $PreAdmissionDeadlineTickMs }
    $budget = New-HostRefreshBudget @budgetArguments
    $preAdmission = Get-HostRefreshPhaseDeadline -Budget $budget -Phase PreAdmission

    $closure = Assert-HostRefreshCommandSet -Stage Startup -Preview:$script:HostRefreshPreview
    if (-not $closure.Complete) {
        for ($i = 0; $i -lt $closure.Missing.Count; $i++) {
            Write-HostRefreshLog -Key 'runner.host_refresh_command_missing' -Arguments @{ command = $closure.Missing[$i]; module = $closure.MissingModule[$i] } -Level Warning -ConsoleOnly
        }
        exit 1
    }
    $protocol = Get-HostRefreshProtocolVersion -RepoRoot $paths.RepoRoot
    if (-not $protocol.Valid) {
        Write-HostRefreshLog -Key 'runner.host_refresh_protocol_mismatch' -Arguments @{ path = "$($protocol.Path)"; found = "$($protocol.Version)"; expected = "$($protocol.Expected)" } -Level Warning -ConsoleOnly
        exit 1
    }
    $hostType = Get-HostType

    if (-not $script:HostRefreshPreview) {
        $phase = 'relaunch'
        # From this script's own scope, so the relaunch forwards this script
        # and its parameters; the ticks travel with them so the child keeps
        # this budget instead of starting a new one.
        $forward = New-HostRefreshRelaunchParameter -BoundParameters $PSBoundParameters -Budget $budget
        Invoke-LibvirtGroupReExecIfNeeded -HostType $hostType -ScriptPath $PSCommandPath -BoundParameters $forward
        try {
            Import-Module powershell-yaml -Global -ErrorAction Stop
        } catch {
            Write-HostRefreshLog -Key 'runner.host_refresh_refused' -Arguments @{ reason = 'yaml-module-missing' } -Level Warning -ConsoleOnly
            exit 1
        }
        $yaml = Assert-HostRefreshCommandSet -Stage Startup
        if (-not $yaml.Complete) {
            for ($i = 0; $i -lt $yaml.Missing.Count; $i++) {
                Write-HostRefreshLog -Key 'runner.host_refresh_command_missing' -Arguments @{ command = $yaml.Missing[$i]; module = $yaml.MissingModule[$i] } -Level Warning -ConsoleOnly
            }
            exit 1
        }
    }

    $phase = 'driver'
    [void](Initialize-YurunaHost -RepoRoot $paths.RepoRoot -HostType $hostType)
    $driver = Assert-HostRefreshCommandSet -HostType $hostType -Stage Driver
    if (-not $driver.Complete) {
        for ($i = 0; $i -lt $driver.Missing.Count; $i++) {
            Write-HostRefreshLog -Key 'runner.host_refresh_command_missing' -Arguments @{ command = $driver.Missing[$i]; module = $driver.MissingModule[$i] } -Level Warning -ConsoleOnly
        }
        exit 1
    }

    $phase = 'context'
    $mode = switch ($PSCmdlet.ParameterSetName) {
        'Internal' { 'Claim' }
        'Resume' { 'Resume' }
        'Dispose' { 'Dispose' }
        default { 'New' }
    }
    $contextArguments = @{ Paths = $paths; HostType = $hostType; Preview = $script:HostRefreshPreview; Deadline = $preAdmission }
    $targetRequest = $null
    if ($mode -eq 'Claim') { $targetRequest = Read-YurunaHostRefreshRequest -RequestId $RequestId }
    elseif ($mode -in @('Resume', 'Dispose')) { $targetRequest = Get-HostRefreshActiveRequest }
    # A disposition touches only the journal and the runner gate. Resolving a
    # configuration it never uses would let an ambiguous or deleted one keep
    # an abandoned request -- and every admission behind it -- blocked.
    if ($mode -eq 'Dispose') { $contextArguments.NoConfig = $true }
    if ($targetRequest) {
        if ($targetRequest['runtimeDir']) { $contextArguments.RequestRuntimeDir = [string]$targetRequest['runtimeDir'] }
        if ($mode -ne 'Dispose') {
            if ($targetRequest['recovery'] -is [System.Collections.IDictionary] -and $targetRequest['recovery']['configPath']) {
                $contextArguments.RecoveryConfigPath = [string]$targetRequest['recovery']['configPath']
            } elseif ($targetRequest['context'] -is [System.Collections.IDictionary] -and $targetRequest['context']['configPath']) {
                $contextArguments.ConfigPath = [string]$targetRequest['context']['configPath']
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('ConfigPath')) { $contextArguments.ConfigPath = $ConfigPath }
    $context = Resolve-HostRefreshContext @contextArguments
    if (-not $script:HostRefreshPreview -and $context.Resolved) {
        # outer.log and every child find the owning runtime through this
        # variable; a stray log directory would let an indirect degradation
        # emit write a cycle-events file nobody reads.
        $env:YURUNA_RUNTIME_DIR = [string]$context.RuntimeDir
        Remove-Item -LiteralPath Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue -Confirm:$false
    }
    $identity = Get-HostRefreshOperatorIdentity -HostType $hostType -RuntimeDir ([string]$context.RuntimeDir) -Deadline $preAdmission
    if ($identity.Allowed -and $identity.SessionKind -in @('Remote', 'Unknown')) {
        Write-HostRefreshLog -Key 'runner.host_refresh_session_passive' -Arguments @{ sessionKind = "$($identity.SessionKind)" } -Preview:$script:HostRefreshPreview
    }

    $phase = 'worker'
    $workerArguments = @{
        Context = $context; Budget = $budget; Identity = $identity; Mode = $mode; Preview = $script:HostRefreshPreview; Confirm = $false
    }
    if ($mode -eq 'New') {
        $workerArguments.Policy = @{
            tier = $Tier; maxRung = $MaxRung; force = [bool]$Force; allowHardStop = [bool]$AllowHardStop
            restoreServiceVmName = [string[]]@($RestoreServiceVmName); leaveStoppedServiceVmName = [string[]]@($LeaveStoppedServiceVmName)
        }
    }
    if ($mode -eq 'Claim') { $workerArguments.RequestId = $RequestId }
    if ($mode -eq 'Dispose') { $workerArguments.DisposeObligation = $DisposeObligation }
    $result = Invoke-HostRefreshWorker @workerArguments
    if ($script:HostRefreshPreview) { Write-Output $result.plan }
    Write-HostRefreshSummary -Result $result -Preview:$script:HostRefreshPreview
    $exitCode = [int]$result.exitCode
} catch {
    try {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_refresh_unexpected_error' -Arguments @{ phase = "$phase"; message = "$($_.Exception.Message)" })
    } catch {
        Write-Verbose "Invoke-HostRefresh: $phase failed: $($_.Exception.Message)"
    }
    $exitCode = 1
} finally {
    # The environment first: once the caller's confirmation preference is
    # back, Remove-Item could ask to confirm, and a non-interactive session
    # would then leave the variable behind.
    foreach ($name in $savedEnvironment.Keys) {
        if ($savedEnvironment[$name].Present) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name].Value) }
        else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue -Confirm:$false }
    }
    $ConfirmPreference = $savedPreference.Confirm
    $ErrorActionPreference = $savedPreference.ErrorAction
    $InformationPreference = $savedPreference.Information
}
exit $exitCode
