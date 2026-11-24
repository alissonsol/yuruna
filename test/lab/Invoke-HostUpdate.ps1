<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42744b5f-913d-4a41-bf5f-800b9670f2d0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host-update controller lab
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
    Ask for a host update from the host's own shell, or release one that
    cannot end on its own.
.DESCRIPTION
    Sends nothing over HTTP. A request is one queued row in the private
    journal, written through the transaction the listener's route uses; the
    host controller claims it and does the work, and its progress is
    runtime/host-update.state.json. Nothing is queued while no controller
    holds its lock, for a scope the controller does not run, or while
    another host operation holds the host.

    -Release ends a claimed host update. While a controller runs, only a
    recovering update can be released: the command marks it and the
    controller writes the verdict. With no controller, the command holds the
    controller lock and the lifetime lock itself, opens the runner gate
    with a compare-and-set under the update's id, starts no listener and no
    runner, and writes released with whatever is still armed as debt.
.PARAMETER Scope
    restart (stop the runner, update the source, start it again) or full.
.PARAMETER Drain
    now ends the running cycle instead of waiting for it. Only this command
    can ask for it; a request over HTTP always waits.
.PARAMETER DrainSeconds
    How long to wait for the running cycle before giving up, 60 to 21600.
.PARAMETER ExpectCommit
    A commit prefix the checkout must be at after the source update.
.PARAMETER Release
    The id of the host update to release.
.OUTPUTS
    Nothing on the success stream; one line per outcome on the information
    stream.
      0  queued, released or marked for release
      1  refused (busy, no controller, scope, conflict, release refused)
      2  could not run (private state, journal, locks)
#>
[CmdletBinding(DefaultParameterSetName = 'Request')]
param(
    [Parameter(ParameterSetName = 'Request')][ValidateSet('restart', 'full')][string]$Scope = 'restart',
    [Parameter(ParameterSetName = 'Request')][ValidateSet('now')][string]$Drain,
    [Parameter(ParameterSetName = 'Request')][ValidateRange(60, 21600)][int]$DrainSeconds = 7200,
    [Parameter(ParameterSetName = 'Request')][ValidatePattern('^[0-9A-Fa-f]{7,40}$')][string]$ExpectCommit,
    [Parameter(ParameterSetName = 'Release', Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$Release
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# Restored in finally, null-aware, so an in-process caller keeps its own
# preferences and environment.
$savedPreference = @{ ErrorAction = $ErrorActionPreference; Information = $InformationPreference }
$savedEnvironment = @{}
foreach ($name in @('YURUNA_NONINTERACTIVE', 'YURUNA_RUNTIME_DIR')) {
    $savedEnvironment[$name] = @{ Present = (Test-Path -LiteralPath "Env:$name"); Value = [Environment]::GetEnvironmentVariable($name) }
}
$InformationPreference = 'Continue'
$ErrorActionPreference = 'Stop'
$env:YURUNA_NONINTERACTIVE = '1'
$exitCode = 1
$phase = 'startup'
$terminalState = @('completed', 'refused', 'abandoned')
$controllerLock = $null
$lifetimeLock = $null

function Write-HostUpdateLine {
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Arguments = @{}, [switch]$Warning)
    $line = Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments
    if ($Warning) { Write-Warning $line } else { Write-Information $line }
}

function Get-HostUpdateDebtText {
    param([AllowNull()]$Row)
    $debt = @()
    if ($Row -and $Row['update'] -is [System.Collections.IDictionary]) {
        $debt = @(@($Row['update']['debt']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['obligation'] })
    }
    if ($debt.Count -eq 0) { return 'none' }
    return ($debt -join ',')
}

try {
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force -DisableNameChecking
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
    Initialize-YurunaEntryPointModuleSet -For HostUpdate -ModulesDir $paths.ModulesDir

    if ($PSCmdlet.ParameterSetName -eq 'Request') {
        $phase = 'admission'
        $runtimeDir = Initialize-YurunaRuntimeDir
        $canonical = Resolve-YurunaCanonicalPath -Path $runtimeDir
        if ($canonical.Resolved) { $runtimeDir = [string]$canonical.Path }
        $hostType = Get-HostType
        $capability = Get-HostUpdateCapability -RepoRoot $paths.RepoRoot -RuntimeDir $runtimeDir
        if ([string]$capability.LockState -cne 'held') {
            Write-HostUpdateLine -Key 'runner.host_update_controller_absent' -Arguments @{ lockState = [string]$capability.LockState } -Warning
            exit (Get-EntryPointExitCode -Outcome Failure)
        }
        $scopes = 'restart'
        if ($capability.ControllerState -is [System.Collections.IDictionary] -and [string]$capability.ControllerState['scopes']) {
            $scopes = [string]$capability.ControllerState['scopes']
        }
        if (@($scopes.Split(',')) -cnotcontains $Scope) {
            Write-HostUpdateLine -Key 'runner.host_update_scope_unavailable' -Arguments @{ scopes = $scopes; scope = $Scope } -Warning
            exit (Get-EntryPointExitCode -Outcome Failure)
        }
        $requestId = New-YurunaHostOperationRequestId
        $drainValue = if ($Drain) { 'now' } else { 'after-cycle' }
        $admissionArguments = @{
            RequestId = $requestId; Channel = 'local'; Scope = $Scope; Drain = $drainValue; DrainSeconds = $DrainSeconds
            RuntimeDir = $runtimeDir; HostType = $hostType
        }
        if ($ExpectCommit) { $admissionArguments.ExpectCommit = $ExpectCommit.ToLowerInvariant() }
        $admission = Request-HostUpdateAdmission @admissionArguments -Confirm:$false
        switch -CaseSensitive ([string]$admission.Decision) {
            { $_ -cin @('queued', 'taken-over') } {
                $attach = Get-HostUpdateConsoleHint
                Write-HostUpdateLine -Key 'runner.host_update_queued' -Arguments @{
                    requestId = $requestId; scope = $Scope; drain = $drainValue
                    stateFile = [System.IO.Path]::Combine($runtimeDir, 'host-update.state.json'); attach = $attach
                }
                if ($admission.Decision -ceq 'taken-over') {
                    Write-HostUpdateLine -Key 'runner.host_update_takeover' -Arguments @{ supersededId = [string]$admission.SupersededId }
                }
                $exitCode = Get-EntryPointExitCode -Outcome Ok
            }
            'busy' {
                $activeId = if ($admission.ActiveRequestId) { [string]$admission.ActiveRequestId } else { '-' }
                Write-HostUpdateLine -Key 'runner.host_update_busy' -Arguments @{ activeKind = [string]$admission.ActiveKind; activeRequestId = $activeId } -Warning
                $exitCode = Get-EntryPointExitCode -Outcome Failure
            }
            default {
                Write-HostUpdateLine -Key 'runner.host_update_refused' -Arguments @{
                    requestId = $requestId; decision = [string]$admission.Decision; reason = $(if ($admission.Reason) { [string]$admission.Reason } else { '-' })
                } -Warning
                # A journal or lock this command could not use is not a
                # refusal of the request.
                $refusal = ([string]$admission.Decision -cne 'unavailable') -or ([string]$admission.Reason -cin @('runtime-owner-mismatch', 'journal-full'))
                $exitCode = Get-EntryPointExitCode -Outcome $(if ($refusal) { 'Failure' } else { 'CannotRun' })
            }
        }
    } else {
        $phase = 'release'
        $row = Get-HostUpdateRequest -RequestId $Release
        $refuse = {
            param([string]$Reason)
            Write-HostUpdateLine -Key 'runner.host_update_release_refused' -Arguments @{ requestId = $Release; reason = $Reason } -Warning
            Get-EntryPointExitCode -Outcome Failure
        }
        if (-not $row) { exit (& $refuse 'not-found') }
        if ([string]$row['state'] -cin $terminalState) { exit (& $refuse 'already-ended') }
        if ([string]$row['state'] -ceq 'queued') { exit (& $refuse 'not-claimed') }
        $lockState = Get-HostUpdateControllerLockState
        if ($lockState -ceq 'held') {
            if ([string]$row['state'] -cne 'recovery-pending') {
                # The lock's metadata cannot be read while it is held, so the
                # controller is named from the row, then from its state file.
                $controllerPid = 0
                if ($row['update'] -is [System.Collections.IDictionary] -and $row['update']['controller'] -is [System.Collections.IDictionary]) {
                    $controllerPid = [int]$row['update']['controller']['pid']
                }
                if ($controllerPid -le 0) {
                    $published = (Get-HostUpdateCapability -RepoRoot $paths.RepoRoot -RuntimeDir ([string]$row['runtimeDir'])).ControllerState
                    if ($published -is [System.Collections.IDictionary]) { $controllerPid = [int]$published['pid'] }
                }
                Write-HostUpdateLine -Key 'runner.host_update_release_controller_running' -Arguments @{ requestId = $Release; pid = "$controllerPid" } -Warning
                exit (Get-EntryPointExitCode -Outcome Failure)
            }
            $mark = Request-HostUpdateRelease -RequestId $Release -Actor 'host-command' -Confirm:$false
            if ([string]$mark.Decision -cne 'marked') {
                $exitCode = & $refuse ([string]$mark.Reason)
                if ([string]$mark.Decision -ceq 'unavailable') { $exitCode = Get-EntryPointExitCode -Outcome CannotRun }
                exit $exitCode
            }
            # The controller honors the mark at its next check, every 2 s,
            # unless it is in the middle of a recovery attempt.
            $wait = [System.Diagnostics.Stopwatch]::StartNew()
            $ended = $null
            while ($wait.Elapsed.TotalSeconds -lt 60) {
                $current = Get-HostUpdateRequest -RequestId $Release
                if (-not $current -or [string]$current['state'] -cin $terminalState) { $ended = $current; break }
                Start-Sleep -Milliseconds 1000
            }
            if ($ended) {
                $verdict = if ($ended['update'] -is [System.Collections.IDictionary] -and $ended['update']['verdict']) { [string]$ended['update']['verdict'] } else { [string]$ended['verdict'] }
                Write-HostUpdateLine -Key 'runner.host_update_released' -Arguments @{ requestId = $Release; verdict = $verdict; debt = (Get-HostUpdateDebtText -Row $ended) }
            } else {
                Write-HostUpdateLine -Key 'runner.host_update_release_marked' -Arguments @{ requestId = $Release }
            }
            $exitCode = Get-EntryPointExitCode -Outcome Ok
        } else {
            # No controller: hold its lock for the whole release so none
            # starts beside this command, then the lifetime lock.
            $controllerLockPath = Get-HostUpdateControllerLockPath
            if (-not $controllerLockPath) { exit (& $refuse 'private-state-unavailable') }
            $controllerLock = Enter-YurunaSingleFlightLock -Path $controllerLockPath -WaitMilliseconds 1500 -Metadata @{ purpose = 'host-update-release'; requestId = $Release }
            if (-not $controllerLock.Held) {
                $exitCode = & $refuse "controller-lock-$($controllerLock.Reason)"
                if ([string]$controllerLock.Reason -cne 'held-elsewhere') { $exitCode = Get-EntryPointExitCode -Outcome CannotRun }
                exit $exitCode
            }
            $lifetimeLock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 1500 `
                -Metadata @{ purpose = 'host-update-release'; requestId = $Release }
            if (-not $lifetimeLock.Held) {
                $exitCode = & $refuse "lifetime-lock-$($lifetimeLock.Reason)"
                if ([string]$lifetimeLock.Reason -cne 'held-elsewhere') { $exitCode = Get-EntryPointExitCode -Outcome CannotRun }
                exit $exitCode
            }
            $row = Get-HostUpdateRequest -RequestId $Release
            if (-not $row -or [string]$row['state'] -cnotin @('running', 'recovery-pending')) { exit (& $refuse 'not-claimed') }
            $privateRoot = Get-HostOperationPrivateRoot
            if (-not $privateRoot.Resolved) { $exitCode = & $refuse 'private-state-unavailable'; exit (Get-EntryPointExitCode -Outcome CannotRun) }
            # The first steps of a restore, before the gate opens: no step child
            # or PowerShell upgrade of this update may still be at work, every
            # transient unit (KVM) or process tree (macOS) of an install or
            # enable phase is ended and the temporary sudo rule is removed.
            # Neither listener nor runner is started.
            $phases = if ($row['update'] -is [System.Collections.IDictionary] -and $row['update']['phases'] -is [System.Collections.IDictionary]) { $row['update']['phases'] } else { @{} }
            foreach ($name in @($phases.Keys)) {
                $entry = $phases[$name]
                if ($entry -isnot [System.Collections.IDictionary] -or [string]$entry['state'] -ne 'started' -or $entry['child'] -isnot [System.Collections.IDictionary]) { continue }
                if ((Get-YurunaProcessIdentityLiveness -ProcessId $entry['child']['pid'] -StartTimeUnixMs $entry['child']['startTimeUnixMs']) -ne 'dead') { exit (& $refuse 'step-alive') }
            }
            # The shim upgrades PowerShell holding no lock; its result file
            # says it ended, its bound that it cannot still run.
            $upgrade = $phases['upgrade_pwsh']
            if ($IsWindows -and $upgrade -is [System.Collections.IDictionary] -and [string]$upgrade['state'] -eq 'started') {
                $controllerRoot = Get-HostUpdateControllerRoot -NoCreate
                $resultFile = if ($controllerRoot) { Join-Path $controllerRoot 'pwsh-upgrade.result' } else { $null }
                $startedMs = [long]0
                $startedUtc = $upgrade['startedUtc']
                try {
                    $startedMs = if ($startedUtc -is [datetime]) { [DateTimeOffset]::new($startedUtc.ToUniversalTime()).ToUnixTimeMilliseconds() }
                    else { [DateTimeOffset]::Parse([string]$startedUtc, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() }
                } catch { $startedMs = 0 }
                if (-not ($resultFile -and (Test-Path -LiteralPath $resultFile)) -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startedMs -lt 1200000) { exit (& $refuse 'pwsh-upgrade-running') }
            }
            $elevationCleared = $false
            $armed = @($row['obligations'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['status'] -eq 'armed' } | ForEach-Object { [string]$_['id'] })
            # The host type the update was admitted under, which is this host's.
            $releaseHostType = [string]$row['hostType']
            if ($releaseHostType -cnotin @('host.ubuntu.kvm', 'host.windows.hyper-v', 'host.macos.utm')) { $releaseHostType = Get-HostUpdateHostType }
            if ($releaseHostType -ceq 'host.macos.utm' -and $armed -ccontains 'elevation') {
                # macOS has no units: the installer or Enable-TestAutomation of
                # this update is found by its arguments. Its root members can
                # only be signaled through the temporary rule, so they are
                # ended while the rule is in force, and the rule goes whether
                # or not they all ended; one left keeps the obligation as debt.
                # An Enable-TestAutomation is this update's only when it runs
                # from the checkout the controller ran the update's steps
                # from, or the runner's; this command's own checkout stands in
                # only when neither is recorded.
                $checkouts = [System.Collections.Generic.List[string]]::new()
                $controllerRoot = Get-HostUpdateControllerRoot -NoCreate
                if ($controllerRoot) {
                    $named = [string](Read-HostUpdateControllerCurrent -ControllerRoot $controllerRoot).Checkout
                    if ([System.IO.Path]::IsPathRooted($named)) { $checkouts.Add($named) }
                }
                $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir ([string]$row['runtimeDir']) -PrivateRoot ([string]$privateRoot.Path)
                if ($launch.Valid -and [System.IO.Path]::IsPathRooted([string]$launch.Record['repoRoot'])) { $checkouts.Add([string]$launch.Record['repoRoot']) }
                if ($checkouts.Count -eq 0) { $checkouts.Add([string]$paths.RepoRoot) }
                $work = Get-HostUpdateMacElevatedWork -RequestId $Release -Checkout $checkouts.ToArray()
                $workEnded = ($null -ne $work) -and (Stop-HostUpdateMacElevatedWork -Work $work -Confirm:$false)
                $ruleRemoved = Remove-HostUpdateSudoRule -HostType $releaseHostType -Confirm:$false
                $elevationCleared = $workEnded -and $ruleRemoved
            } elseif ($releaseHostType -ceq 'host.ubuntu.kvm' -and $armed -ccontains 'elevation') {
                $units = Get-HostUpdateElevatedUnit
                $unitsStopped = ($null -ne $units) -and ((@($units).Count -eq 0) -or (Stop-HostUpdateElevatedUnit -Unit @($units) -Confirm:$false))
                # The rule goes whether or not every unit stopped; a unit that
                # did not stop keeps the obligation as debt.
                $ruleRemoved = Remove-HostUpdateSudoRule -HostType $releaseHostType -Confirm:$false
                $elevationCleared = $unitsStopped -and $ruleRemoved
            }
            # The gate is opened only when this update, or the one it took
            # over before its controller re-stamped the gate, holds it.
            $gateIds = @([string]$row['requestId'])
            if ($row['update'] -is [System.Collections.IDictionary] -and $row['update']['inheritedGateRequestId']) { $gateIds += [string]$row['update']['inheritedGateRequestId'] }
            $opened = $false
            for ($try = 0; $try -lt 2 -and -not $opened; $try++) {
                $gate = Get-YurunaRunnerGateState -RuntimeDir ([string]$row['runtimeDir']) -PrivateRoot ([string]$privateRoot.Path)
                if ($gate.State -ceq 'open') { $opened = $true; break }
                if ($gate.State -cnotin @('closed', 'recovery-pending', 'handoff') -or $gateIds -cnotcontains [string]$gate.RequestId) { break }
                $write = Set-YurunaRunnerGate -State released -RequestId ([string]$row['requestId']) -Attempt 1 -RuntimeDir ([string]$row['runtimeDir']) `
                    -ExpectedGeneration ([string]$gate.Generation) -OwnerPid $PID -OwnerRole controller -PrivateRoot ([string]$privateRoot.Path) -Confirm:$false
                $opened = [bool]$write.Written
            }
            if (-not $opened) { exit (& $refuse 'gate-not-opened') }
            $released = Complete-HostUpdateRelease -RequestId $Release -Actor 'host-command' -LifetimeLock $lifetimeLock -ElevationCleared:$elevationCleared -Confirm:$false
            if (-not $released.Released) { exit (& $refuse ([string]$released.Reason)) }
            $debtText = if (@($released.Debt).Count -gt 0) { @($released.Debt) -join ',' } else { 'none' }
            Write-HostUpdateLine -Key 'runner.host_update_released' -Arguments @{ requestId = $Release; verdict = 'released'; debt = $debtText }
            $exitCode = Get-EntryPointExitCode -Outcome Ok
        }
    }
} catch {
    try {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.host_update_unexpected_error' -Arguments @{ phase = "$phase"; message = "$($_.Exception.Message)" })
    } catch {
        Write-Verbose "Invoke-HostUpdate: $phase failed: $($_.Exception.Message)"
    }
    $exitCode = 2
} finally {
    if ($lifetimeLock -and $lifetimeLock.Held) { Exit-YurunaSingleFlightLock -Lock $lifetimeLock }
    if ($controllerLock -and $controllerLock.Held) { Exit-YurunaSingleFlightLock -Lock $controllerLock }
    foreach ($name in $savedEnvironment.Keys) {
        if ($savedEnvironment[$name].Present) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name].Value) }
        else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue -Confirm:$false }
    }
    $ErrorActionPreference = $savedPreference.ErrorAction
    $InformationPreference = $savedPreference.Information
}
exit $exitCode
