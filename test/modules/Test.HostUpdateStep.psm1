<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42bb1969-e19d-4e56-b3de-fa59dcf949ee
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update step runner listener source
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.DiagnosticPreservation.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RunnerElevation.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostOperationJournal.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostRepair.psm1') -DisableNameChecking

# The work of one phase of a host update, run by the step child the host
# controller starts. A step reads the journal and never writes it: its only
# output is the result file, written last, which the controller journals.
# Every token it writes is one of the controller's closed lists.

# What a step may spend of its phase's bound (preflight 60 s, stop_runner
# 120 s, update_source 300 s, install 2400 s on KVM and macOS and 3600 s on
# Windows, enable 300 s and 600 s on macOS, start_listener 60 s, start_runner
# 240 s), so it writes its own result before the controller ends it at the
# bound. The source update has the pull's own 280 s deadline inside it.
$script:HostUpdateStepBudgetMs = @{
    preflight = 45000; stop_runner = 100000; update_source = 290000; install = $(if ($IsWindows) { 3540000 } else { 2340000 }); enable = 280000
    start_listener = 45000; start_runner = 220000
}
$script:HostUpdateStepBudgetOverrideMs = @{ 'host.macos.utm' = @{ enable = 580000 } }
$script:HostUpdateStepResultMaxEntries = 32

# --- REGION: Platform
function Get-HostUpdateStepPlatform {
    <#
    .SYNOPSIS
        Windows, MacOS or Linux: the rules a step follows. macOS is read from
        the request's host type, so a test can drive the macOS rules on any
        host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HostType)
    if ($IsWindows) { return 'Windows' }
    if ($HostType -ceq 'host.macos.utm') { return 'MacOS' }
    return 'Linux'
}

function Get-HostUpdateStepBudget {
    <#
    .SYNOPSIS
        What a step may spend, in milliseconds, for its phase and host type.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Step, [string]$HostType)
    $override = $script:HostUpdateStepBudgetOverrideMs[[string]$HostType]
    if ($override -and $override.ContainsKey($Step)) { return [long]$override[$Step] }
    return [long]$script:HostUpdateStepBudgetMs[$Step]
}

# --- REGION: Result
function New-HostUpdateStepResult {
    <#
    .SYNOPSIS
        A result record for one step attempt, before its outcome is known.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$Attempt)
    return [ordered]@{
        schemaVersion  = 1
        step           = $Step
        requestId      = $RequestId
        attempt        = $Attempt
        outcome        = 'failed'
        reason         = $null
        remarks        = [System.Collections.Generic.List[string]]::new()
        operatorAction = $null
        protocol       = $null
        commit         = [ordered]@{ before = $null; after = $null; resident = $null }
        runnerConsole  = $null
        reclaimed      = $null
        detail         = [ordered]@{}
    }
}

function Set-HostUpdateStepOutcome {
    <#
    .SYNOPSIS
        Record a step's outcome, its reason and what it asks of the operator.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][ValidateSet('done', 'skipped', 'failed')][string]$Outcome,
        [string]$Reason,
        [string]$Action
    )
    $Result['outcome'] = $Outcome
    $Result['reason'] = if ($Reason) { $Reason } else { $null }
    $Result['operatorAction'] = if ($Action) { $Action } else { $null }
}

function Write-HostUpdateStepResult {
    <#
    .SYNOPSIS
        Write the result file through a temporary file and a rename, so the
        controller never reads half of one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $record = [ordered]@{}
    foreach ($key in $Result.Keys) { $record[$key] = $Result[$key] }
    $record['remarks'] = [string[]]@($Result['remarks'] | Select-Object -Unique)
    return [bool](Write-YurunaStateFileJson -Path $Path -InputObject $record -Depth 8 -Confirm:$false)
}

function Get-HostUpdateStepExitCode {
    <#
    .SYNOPSIS
        The step child's exit code for its result: 0 done, 2 done with
        remarks, 3 skipped, 1 failed. The result file is what the controller
        reads; the exit code mirrors it for tests and manual runs.
    .PARAMETER Result
        The step's result record.
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][System.Collections.IDictionary]$Result)
    if ($null -eq $Result) { return 1 }
    switch ([string]$Result['outcome']) {
        'done' { if (@($Result['remarks'] | Where-Object { $_ }).Count -gt 0) { return 2 } return 0 }
        'skipped' { return 3 }
        default { return 1 }
    }
}

# --- REGION: Readers
function Get-HostUpdateStepRecordValue {
    <#
    .SYNOPSIS
        One field of a dictionary or an object, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) { return $Record[$Name] }
    if ($Record.PSObject.Properties[$Name]) { return $Record.$Name }
    return $null
}

function Get-HostUpdateStepLaunchParameter {
    <#
    .SYNOPSIS
        One recorded runner option of a valid launch record, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$LaunchRecord, [Parameter(Mandatory)][string]$Name)
    if (-not $LaunchRecord -or -not $LaunchRecord.Valid) { return $null }
    return (Get-HostUpdateStepRecordValue -Record (Get-HostUpdateStepRecordValue -Record $LaunchRecord.Record -Name 'parameters') -Name $Name)
}

function Get-HostUpdateStepConfigPath {
    <#
    .SYNOPSIS
        The configuration the runner was started with: the launch record's,
        else the one an entry point of this checkout would resolve.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$LaunchRecord, [Parameter(Mandatory)][string]$RepoRoot)
    $recorded = [string](Get-HostUpdateStepLaunchParameter -LaunchRecord $LaunchRecord -Name 'ConfigPath')
    if ($recorded) { return $recorded }
    if ($env:YURUNA_CONFIG_PATH) { return [string]$env:YURUNA_CONFIG_PATH }
    return [System.IO.Path]::Combine($RepoRoot, 'test', 'test.config.yml')
}

function Get-HostUpdateStepCommit {
    <#
    .SYNOPSIS
        The checkout's HEAD commit, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $r = Invoke-BoundedNativeCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'rev-parse', 'HEAD') -TimeoutSeconds 10
    $sha = ([string]$r.StdOut).Trim().ToLowerInvariant()
    if ((Test-BoundedNativeResultComplete -Result $r) -and $r.ExitCode -eq 0 -and $sha -cmatch '\A[0-9a-f]{40}\z') { return $sha }
    return $null
}

function Test-HostUpdateStepDetachedHead {
    <#
    .SYNOPSIS
        $true when the checkout's HEAD is detached, the way a host pins a
        version; $false on a branch or when git cannot tell.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $r = Invoke-BoundedNativeCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'symbolic-ref', '-q', 'HEAD') -TimeoutSeconds 10
    return ((Test-BoundedNativeResultComplete -Result $r) -and $r.ExitCode -eq 1)
}

function Get-HostUpdateStepResidentState {
    <#
    .SYNOPSIS
        The resident runner's record state for this checkout.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][string]$RepoRoot)
    $record = Get-YurunaRunnerRecordState -PidFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.pid')) -StartFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.start')) `
        -ExpectedScriptPath @([System.IO.Path]::Combine($RepoRoot, 'test', 'Start-TestRunner.ps1'))
    return [string]$record.State
}

function Test-HostUpdateStepStartExpected {
    <#
    .SYNOPSIS
        Whether the start_runner phase will start a runner, by the rule the
        stop_runner phase records:
        an inherited runner obligation, a live resident, or a launch record
        whose last exit was not clean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()]$LaunchRecord
    )
    foreach ($obligation in @($Row['obligations'])) {
        if ($obligation -is [System.Collections.IDictionary] -and [string]$obligation['id'] -eq 'runner' -and [string]$obligation['status'] -eq 'armed') { return $true }
    }
    if ((Get-HostUpdateStepResidentState -RuntimeDir $RuntimeDir -RepoRoot $RepoRoot) -eq 'AliveOwned') { return $true }
    if (-not $LaunchRecord -or -not $LaunchRecord.Found) { return $false }
    return -not [bool](Get-HostUpdateStepRecordValue -Record $LaunchRecord.Record -Name 'cleanExit')
}

# --- REGION: Runner stop
function Stop-HostUpdateStepRunner {
    <#
    .SYNOPSIS
        Stop every inner, cycle and resident process whose record is alive
        and owned, one identity-checked process at a time, until a snapshot
        shows none or the deadline passes.
    .DESCRIPTION
        No quiescence comparison: a host update stops a runner that is busy
        (drain now) or parked, so a snapshot that differs from the last one
        is simply stopped again. The step's own ancestry (the controller and
        its shim) is protected by the plan; the listener's and the beacon's
        subtrees are pruned by the exclusion set. Pauses, holds and the launch
        record are left as they are.
    .OUTPUTS
        [pscustomobject] @{ Outcome done|failed; Reason; Reclaimed
        { outer; cycle; inner }; Stopped }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Every signal goes through Stop-YurunaRunnerProcessTarget, which asks; a step child runs unattended.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$PrivateRoot,
        [Parameter(Mandatory)][psobject]$Deadline
    )
    $reclaimed = [ordered]@{ outer = $null; cycle = $null; inner = $null }
    $stopped = [System.Collections.Generic.List[object]]::new()
    $answer = { param([string]$Outcome, [string]$Reason) [pscustomobject]@{ Outcome = $Outcome; Reason = $Reason; Reclaimed = $reclaimed; Stopped = $stopped.ToArray() } }
    $snapshotArgs = @{ RuntimeDir = $RuntimeDir; RepoRoot = $RepoRoot; WorkerPid = $PID; Deadline = $Deadline }
    if ($PrivateRoot) { $snapshotArgs.PrivateRoot = $PrivateRoot }
    while ($true) {
        $plan = New-YurunaRunnerReclaimPlan -Snapshot (Get-YurunaRunnerSnapshot @snapshotArgs)
        if (@($plan.Refusals).Count -gt 0) { return (& $answer 'failed' 'runner_identity_unknown') }
        $roots = @($plan.Roots)
        if ($roots.Count -eq 0) { return (& $answer 'done' $null) }
        if (Test-YurunaDeadlineExpired -Deadline $Deadline) { return (& $answer 'failed' 'runner_survived') }
        foreach ($root in $roots) {
            $role = ([string]$root.Role).ToLowerInvariant()
            if ($reclaimed.Contains($role)) { $reclaimed[$role] = [ordered]@{ pid = [int]$root.Pid; startTimeUnixMs = $root.StartTimeUnixMs } }
        }
        $stop = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline $Deadline -Confirm:$false
        foreach ($target in @($stop.Targets)) {
            if ($stopped.Count -ge $script:HostUpdateStepResultMaxEntries) { break }
            $stopped.Add([ordered]@{ pid = $target.Pid; role = $target.Role; startTimeUnixMs = $target.StartTimeUnixMs; action = [string]$target.Action })
        }
        if (-not $stop.Converged -and (Test-YurunaDeadlineExpired -Deadline $Deadline)) { return (& $answer 'failed' 'runner_survived') }
        $null = Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 500
    }
}

# --- REGION: Steps
function Test-HostUpdateStepSessionUsable {
    <#
    .SYNOPSIS
        Whether this macOS session can start a working runner, read in this
        process, with the reading kept in the result's detail.
    .DESCRIPTION
        A reading that cannot be made counts as usable, as a grant whose
        state reads unknown does, the rule the controller's session check
        follows too: the probes time out, and a runner that then cannot
        start is refused by its own startup gate, which ends the update
        recovering with that refusal to read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $reading = $null
    try { $reading = Get-HostUpdateMacSessionReading } catch { Write-Verbose "Test-HostUpdateStepSessionUsable: the session reading threw: $($_.Exception.Message)" }
    if ($reading -isnot [System.Collections.IDictionary] -or $reading['Usable'] -isnot [bool]) {
        $Result['detail']['session'] = 'unread'
        return $true
    }
    $grants = [ordered]@{}
    if ($reading['Grants'] -is [System.Collections.IDictionary]) { foreach ($id in @($reading['Grants'].Keys)) { $grants[[string]$id] = [string]$reading['Grants'][$id] } }
    $Result['detail']['session'] = [ordered]@{ kind = [string]$reading['SessionKind']; ssh = [bool]$reading['Ssh']; grants = $grants; usable = [bool]$reading['Usable'] }
    return [bool]$reading['Usable']
}

function Test-HostUpdateStepFullScopePublished {
    <#
    .SYNOPSIS
        Whether the controller's published state lists the full scope.
    .PARAMETER RuntimeDir
        The runtime directory the controller publishes
        host-controller.state.json in.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = [System.IO.Path]::Combine($RuntimeDir, 'host-controller.state.json')
    try {
        $info = [System.IO.FileInfo]::new($path)
        if (-not $info.Exists -or $info.LinkTarget -or $info.Length -gt 65536) { return $false }
        $state = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Test-HostUpdateStepFullScopePublished: '$path' unreadable: $($_.Exception.Message)"
        return $false
    }
    if ($state -isnot [System.Collections.IDictionary]) { return $false }
    return (@(([string]$state['scopes']) -split ',') -ccontains 'full')
}

function Invoke-HostUpdateStepPreflight {
    <#
    .SYNOPSIS
        The preflight phase: refuse, changing nothing, when the host cannot take the
        update.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $served = [System.Collections.Generic.List[string]]::new()
    $served.Add($Context.RepoRoot); $served.Add($Context.RuntimeDir)
    if ($env:YURUNA_LOG_DIR) { $served.Add([string]$env:YURUNA_LOG_DIR) }
    # The two checks the repair makes before any disruption: a lock file
    # system whose exclusion is qualified, and a HOME that is the account's,
    # so one account has one lock namespace.
    $root = Get-HostOperationPrivateRoot -NoCreate -ServedRoot $served.ToArray()
    $homeCheck = Get-HostOperationPrivateRoot -NoCreate -VerifyHome -ServedRoot $served.ToArray()
    $qualificationPath = if ($root.Resolved) { [string]$root.Path } else { $HOME }
    $qualified = $false
    try { $qualified = [bool](Get-YurunaSingleFlightLockQualification -Path $qualificationPath).Qualified } catch { Write-Verbose "Invoke-HostUpdateStepPreflight: lock qualification failed: $($_.Exception.Message)" }
    if (-not $qualified) { Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'lock_unqualified' -Action 'act_at_host'; return }
    if (-not $root.Resolved -or [string]$homeCheck.HomeVerified -ne 'verified') {
        $Result['detail']['home'] = [string]$homeCheck.HomeVerified
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'home_unverified' -Action 'act_at_host'
        return
    }
    if ((Get-YurunaOneShotLeaseState -RuntimeDir $Context.RuntimeDir).State -eq 'Held') {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'one_shot_active' -Action 'end_one_shot'
        return
    }
    if (Get-DiagnosticVmPreservation -RuntimeDir $Context.RuntimeDir) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'diagnostic_hold' -Action 'release_diagnostic_hold'
        return
    }
    $platform = Get-HostUpdateStepPlatform -HostType $Context.HostType
    # On macOS the runner this update starts inherits the session of the
    # controller, and so of this step: without the desktop session or with a
    # privacy grant denied, it would start into a startup config gate that
    # refuses it, after the runner was already stopped.
    if ($platform -eq 'MacOS' -and -not (Test-HostUpdateStepSessionUsable -Result $Result)) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'session_unusable' -Action 'act_at_host'
        return
    }
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $Context.RuntimeDir -PrivateRoot $Context.PrivateRoot
    $start = Test-HostUpdateStepStartExpected -Row $Context.Row -RuntimeDir $Context.RuntimeDir -RepoRoot $Context.RepoRoot -LaunchRecord $launch
    $Result['detail']['startExpected'] = $start
    if ($start) {
        if (-not $launch.Valid) {
            $Result['detail']['launchRecord'] = [string]$launch.Reason
            Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'launch_record_invalid' -Action 'start_runner'
            return
        }
        # A resumed start refuses without the runner's passwordless sudo, and
        # a stopped runner pulls nothing: without this the update would stop
        # the runner and stay recovering.
        if (-not (Test-RunnerElevationReady -Command (Get-RunnerElevationCommand -HostType $Context.HostType))) {
            Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'runner_elevation_missing' -Action 'provision_elevation'
            return
        }
    }
    # The full scope runs the installer and the host settings as root or
    # Administrator: on KVM through the runner's passwordless manifest, which
    # writes the temporary rule. On macOS the probe writes the temporary
    # rule's own path, so only the controller makes it, never while an update
    # is claimed; it probed just before this claim and published the scopes
    # first, and that is the result read here, with no sudo.
    $scope = [string](Get-HostUpdateStepRecordValue -Record (Get-HostUpdateStepRecordValue -Record $Context.Update -Name 'request') -Name 'scope')
    if ($scope -eq 'full') {
        if ($platform -eq 'MacOS') {
            if (-not (Test-HostUpdateStepFullScopePublished -RuntimeDir $Context.RuntimeDir)) {
                Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'scope_unavailable' -Action 'provision_elevation'
                return
            }
        } elseif (-not (Test-HostUpdateFullScopeReady)) {
            Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'runner_elevation_missing' -Action 'provision_elevation'
            return
        }
    }
    Set-HostUpdateStepOutcome -Result $Result -Outcome done
}

function Invoke-HostUpdateStepStopRunner {
    <#
    .SYNOPSIS
        The stop_runner phase: stop the runner, and report by role what was stopped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $stop = Stop-HostUpdateStepRunner -RuntimeDir $Context.RuntimeDir -RepoRoot $Context.RepoRoot -PrivateRoot $Context.PrivateRoot -Deadline $Context.Deadline
    $Result['reclaimed'] = $stop.Reclaimed
    $Result['detail']['stopped'] = @($stop.Stopped)
    if ($stop.Outcome -eq 'failed') { Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $stop.Reason -Action 'stop_runner_by_hand'; return }
    Set-HostUpdateStepOutcome -Result $Result -Outcome done
}

function Invoke-HostUpdateStepUpdateSource {
    <#
    .SYNOPSIS
        The update_source phase: the source update a cycle runs, with the
        runner's recorded options, then the expected commit.
    .DESCRIPTION
        The pull reads the canary ring and the host identity from the
        runtime directory and $global:__YurunaHostId the prologue set, and
        the mirror and pool settings from the runner's configuration, so the
        runner's forwarded environment is restored first. A follower held by
        its ring stays where it is and says so.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'The pull reads $global:__YurunaHostId, the identity channel the entry points set; the prologue set it.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $Context.RuntimeDir -PrivateRoot $Context.PrivateRoot
    if ([bool](Get-HostUpdateStepLaunchParameter -LaunchRecord $launch -Name 'NoGitPull')) {
        $Result['remarks'].Add('no_git_pull')
        Set-HostUpdateStepOutcome -Result $Result -Outcome skipped
        return
    }
    if (-not (Get-Command Invoke-OuterGitPull -ErrorAction SilentlyContinue)) {
        $Result['detail']['pull'] = 'pull-unavailable'
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'pull_failed' -Action 'repair_checkout'
        return
    }
    $recorded = if ($launch.Valid) { Get-HostUpdateStepRecordValue -Record $launch.Record -Name 'environment' } else { $null }
    if ($recorded -is [System.Collections.IDictionary]) {
        foreach ($name in $recorded.Keys) {
            if ([string]$name -cin @('YURUNA_RUNTIME_DIR') -or [string]$name -cnotmatch '\AYURUNA_[A-Z0-9_]+\z') { continue }
            [Environment]::SetEnvironmentVariable([string]$name, [string]$recorded[$name])
        }
    }
    $config = Get-HostUpdateStepConfigPath -LaunchRecord $launch -RepoRoot $Context.RepoRoot
    $env:YURUNA_CONFIG_PATH = $config
    $Result['commit']['before'] = Get-HostUpdateStepCommit -RepoRoot $Context.RepoRoot
    $since = [DateTime]::UtcNow.AddSeconds(-2)
    $pulled = $false
    try { $pulled = [bool](Invoke-OuterGitPull -RepoRoot $Context.RepoRoot -ConfigPath $config) } catch {
        Write-Verbose "Invoke-HostUpdateStepUpdateSource: the pull threw: $($_.Exception.Message)"
        $Result['detail']['pull'] = 'threw'
        $pulled = $false
    }
    $Result['commit']['after'] = Get-HostUpdateStepCommit -RepoRoot $Context.RepoRoot
    if (-not $pulled) {
        $outer = Get-Module -Name Test.RunnerOuterLoop | Select-Object -First 1
        if ($outer) { $Result['detail']['class'] = [string](& $outer { $script:LastOuterPullFailureClass }) }
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'pull_failed' -Action 'repair_checkout'
        return
    }
    $ring = [System.IO.Path]::Combine($Context.RuntimeDir, 'framework-ring.json')
    try {
        $info = [System.IO.FileInfo]::new($ring)
        if ($info.Exists -and $info.LastWriteTimeUtc -ge $since -and $info.Length -le 65536) {
            $decision = [System.IO.File]::ReadAllText($ring) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($decision -is [System.Collections.IDictionary] -and ([string]$decision['outcome']).StartsWith('held-', [StringComparison]::Ordinal)) { $Result['remarks'].Add('ring_held') }
        }
    } catch { Write-Verbose "Invoke-HostUpdateStepUpdateSource: ring decision unreadable: $($_.Exception.Message)" }
    if (Test-HostUpdateStepDetachedHead -RepoRoot $Context.RepoRoot) { $Result['remarks'].Add('checkout_pinned') }
    $expect = [string](Get-HostUpdateStepRecordValue -Record (Get-HostUpdateStepRecordValue -Record $Context.Update -Name 'request') -Name 'expectCommit')
    if ($expect -and -not ([string]$Result['commit']['after']).StartsWith($expect.ToLowerInvariant(), [StringComparison]::Ordinal)) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'commit_mismatch' -Action 'repair_checkout'
        return
    }
    Set-HostUpdateStepOutcome -Result $Result -Outcome done
}

function Invoke-HostUpdateStepStartListener {
    <#
    .SYNOPSIS
        The start_listener phase: start the listener in its non-destructive
        mode when the runner's configuration enables it, replacing an owned
        one that is wedged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $Context.RuntimeDir -PrivateRoot $Context.PrivateRoot
    $config = $null
    try { $config = Read-TestConfig -Path (Get-HostUpdateStepConfigPath -LaunchRecord $launch -RepoRoot $Context.RepoRoot) } catch {
        Write-Verbose "Invoke-HostUpdateStepStartListener: configuration unreadable: $($_.Exception.Message)"
        $config = $null
    }
    $enabled = $false
    $port = 8080
    if ($config -is [System.Collections.IDictionary] -and $config['statusService'] -is [System.Collections.IDictionary]) {
        $enabled = [bool]$config['statusService']['enabled']
        if ($config['statusService']['port']) { $port = [int]$config['statusService']['port'] }
    }
    if (-not $enabled -or [bool](Get-HostUpdateStepLaunchParameter -LaunchRecord $launch -Name 'NoStatusService')) {
        $Result['remarks'].Add('listener_disabled')
        Set-HostUpdateStepOutcome -Result $Result -Outcome skipped
        return
    }
    $listener = Start-HostOperationStatusService -RepoRoot $Context.RepoRoot -RuntimeDir $Context.RuntimeDir -Port $port `
        -ResultPath ([System.IO.Path]::Combine($Context.WorkDirectory, "listener.$($Context.Attempt).result.json")) -Deadline $Context.Deadline -ReplaceWedged -Confirm:$false
    $Result['detail']['listener'] = "listener_$([string]$listener.Outcome)"
    if ([string]$listener.Outcome -in @('existing-ready', 'started')) { Set-HostUpdateStepOutcome -Result $Result -Outcome done; return }
    $Result['detail']['listenerReason'] = [string]$listener.Reason
    Set-HostUpdateStepOutcome -Result $Result -Outcome failed
}

function ConvertTo-HostUpdateStepStartFailure {
    <#
    .SYNOPSIS
        The reason and operator action of a start that did not end ready.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Resume)
    $outcome = [string](Get-HostUpdateStepRecordValue -Record $Resume -Name 'Outcome')
    $reason = [string](Get-HostUpdateStepRecordValue -Record $Resume -Name 'Reason')
    $ack = Get-HostUpdateStepRecordValue -Record $Resume -Name 'Ack'
    $ackReason = [string](Get-HostUpdateStepRecordValue -Record $ack -Name 'failureReason')
    if ($outcome -eq 'timeout') { return @{ Reason = 'runner_start_timeout'; Action = 'repair_checkout' } }
    if ($outcome -eq 'launch-failed' -and $reason -eq 'runner-exited') { return @{ Reason = 'runner_exited'; Action = 'repair_checkout' } }
    if ($outcome -eq 'launch-failed' -and $reason -eq 'console-state-unknown') { return @{ Reason = 'console_state_unknown'; Action = 'act_at_host' } }
    if ($reason -eq 'config-gate-failed' -or $ackReason -eq 'config-gate-failed') { return @{ Reason = 'config_gate_failed'; Action = 'act_at_host' } }
    return @{ Reason = 'runner_start_failed'; Action = 'repair_checkout' }
}

function Get-HostUpdateStepConsoleArgument {
    <#
    .SYNOPSIS
        The console the started runner gets: a tmux session on the
        controller's socket on KVM and macOS, a window of its own on
        Windows.
    .DESCRIPTION
        The attempt number names a tmux session: the controller counts every
        start of this phase in the journal, restore and recovering included,
        so no name is ever reused.
    .PARAMETER Context
        The step context.
    .PARAMETER Platform
        Windows or Posix.
    .OUTPUTS
        [hashtable] parameters for Invoke-YurunaRunnerHandoffResume.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][ValidateSet('Windows', 'Posix')][string]$Platform)
    if ($Platform -eq 'Windows') { return @{ ConsoleWindow = $true } }
    return @{
        ConsoleSocketPath  = [System.IO.Path]::Combine($Context.ControllerRoot, 'runner-console.sock')
        ConsoleSessionName = "runner-$($Context.RequestId)-$($Context.Attempt)"
        ConsoleLogPath     = [System.IO.Path]::Combine($Context.WorkDirectory, "console.$($Context.Attempt).log")
    }
}

function Update-HostUpdateStepWindowsPath {
    <#
    .SYNOPSIS
        Read PATH again from the machine and user environment of the
        registry, machine entries first, as a new logon would.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes only the environment of this step child, which the runner it starts inherits.')]
    [CmdletBinding()]
    param()
    $machine = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $user = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $parts = @($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parts.Count -gt 0) { $env:Path = $parts -join ';' }
}

function Invoke-HostUpdateStepStartRunner {
    <#
    .SYNOPSIS
        The start_runner phase: start the runner from its launch record, in a
        console when the host has one, and wait for its acknowledgment.
    .DESCRIPTION
        Safe to repeat. A live, owned resident with the gate open means an
        earlier attempt succeeded. Otherwise the gate is closed again under
        this request (which revokes a handoff an interrupted attempt left),
        any live resident is stopped, and only then is the runner started.
        Nothing is carried between attempts in memory: the gate generation is
        read at use, and the identities the stop_runner phase stopped come from the
        journal, overlaid by what this attempt stopped itself.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result)
    if ($Context.ControllerPid -le 0) {
        $Result['detail']['cause'] = 'controller-pid-missing'
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'runner_start_failed' -Action 'repair_checkout'
        return
    }
    $gateArgs = @{ RuntimeDir = $Context.RuntimeDir; PrivateRoot = $Context.PrivateRoot }
    $gate = Get-YurunaRunnerGateState @gateArgs
    if ($gate.State -eq 'open' -and (Get-HostUpdateStepResidentState -RuntimeDir $Context.RuntimeDir -RepoRoot $Context.RepoRoot) -eq 'AliveOwned') {
        $Result['detail']['already'] = $true
        Set-HostUpdateStepOutcome -Result $Result -Outcome done
        return
    }
    $inherited = [string](Get-HostUpdateStepRecordValue -Record $Context.Update -Name 'inheritedGateRequestId')
    if ($gate.State -ne 'open' -and [string]$gate.RequestId -cne $Context.RequestId -and -not ($inherited -and [string]$gate.RequestId -ceq $inherited)) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'gate_busy' -Action 'act_at_host'
        return
    }
    $closed = Set-YurunaRunnerGate -State closed -RequestId $Context.RequestId -Attempt 1 -RuntimeDir $Context.RuntimeDir -ExpectedGeneration ([string]$gate.Generation) `
        -OwnerPid $Context.ControllerPid -OwnerRole controller -PrivateRoot $Context.PrivateRoot -Confirm:$false
    if (-not $closed.Written) {
        $Result['detail']['gate'] = [string]$closed.Reason
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'gate_busy' -Action 'act_at_host'
        return
    }
    $stop = Stop-HostUpdateStepRunner -RuntimeDir $Context.RuntimeDir -RepoRoot $Context.RepoRoot -PrivateRoot $Context.PrivateRoot -Deadline $Context.Deadline
    $Result['reclaimed'] = $stop.Reclaimed
    if ($stop.Outcome -eq 'failed') { Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $stop.Reason -Action 'stop_runner_by_hand'; return }
    $reclaimed = @{ outer = $null; cycle = $null; inner = $null }
    $journaled = Get-HostUpdateStepRecordValue -Record $Context.Update -Name 'reclaimed'
    foreach ($role in @('outer', 'cycle', 'inner')) {
        $own = $stop.Reclaimed[$role]
        $reclaimed[$role] = if ($own) { $own } else { Get-HostUpdateStepRecordValue -Record $journaled -Name $role }
    }
    # The gate stays closed from here to the acknowledgment, so nothing can
    # move the checkout between this read and the runner's start.
    $Result['commit']['resident'] = Get-HostUpdateStepCommit -RepoRoot $Context.RepoRoot
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $Context.RuntimeDir -PrivateRoot $Context.PrivateRoot
    $gate = Get-YurunaRunnerGateState @gateArgs
    $resumeArgs = @{
        LaunchRecord = $launch; RequestId = $Context.RequestId; Attempt = $Context.Attempt; RuntimeDir = $Context.RuntimeDir; RepoRoot = $Context.RepoRoot
        ExpectedGateGeneration = [string]$gate.Generation; Reclaimed = $reclaimed; PrivateRoot = $Context.PrivateRoot; PrivateDirectory = $Context.WorkDirectory
        Deadline = $Context.Deadline; OnReady = 'released'; Confirm = $false
    }
    foreach ($pair in (Get-HostUpdateStepConsoleArgument -Context $Context -Platform $(if ($IsWindows) { 'Windows' } else { 'Posix' })).GetEnumerator()) {
        $resumeArgs[$pair.Key] = $pair.Value
    }
    # A tool an install phase of the same update put on PATH is found by the
    # runner only when PATH is read again: this process has the PATH its
    # controller started with.
    if ($IsWindows) { Update-HostUpdateStepWindowsPath }
    $resume = $null
    try { $resume = Invoke-YurunaRunnerHandoffResume @resumeArgs } catch {
        Write-Verbose "Invoke-HostUpdateStepStartRunner: the start threw: $($_.Exception.Message)"
        $resume = $null
    }
    $console = [string](Get-HostUpdateStepRecordValue -Record $resume -Name 'Console')
    if ($console -in @('tmux', 'window', 'none')) { $Result['runnerConsole'] = $console }
    $Result['detail']['resume'] = [ordered]@{
        outcome = [string](Get-HostUpdateStepRecordValue -Record $resume -Name 'Outcome')
        reason = [string](Get-HostUpdateStepRecordValue -Record $resume -Name 'Reason')
        consoleReason = [string](Get-HostUpdateStepRecordValue -Record $resume -Name 'ConsoleReason')
        panePid = Get-HostUpdateStepRecordValue -Record $resume -Name 'ConsolePid'
        outerPid = Get-HostUpdateStepRecordValue -Record $resume -Name 'OuterPid'
    }
    if ([string](Get-HostUpdateStepRecordValue -Record $resume -Name 'Outcome') -eq 'ready') {
        if ($Result['runnerConsole'] -eq 'none') { $Result['remarks'].Add('runner_console_unavailable') }
        Set-HostUpdateStepOutcome -Result $Result -Outcome done
        return
    }
    $failure = ConvertTo-HostUpdateStepStartFailure -Resume $resume
    Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $failure.Reason -Action $failure.Action
}

# --- REGION: Install and enable (full scope)
# The installer's markers: a copy without one does not know the unattended
# switch, and the KVM installer would ignore it and run an attended install.
$script:HostUpdateStepInstallerMarker = @{
    Linux   = @{ Path = 'install/ubuntu.kvm.sh'; Pattern = '(?m)^YURUNA_UNATTENDED_PROTOCOL_VERSION=1$' }
    MacOS   = @{ Path = 'install/macos.utm.sh'; Pattern = '(?m)^YURUNA_UNATTENDED_PROTOCOL_VERSION=1$' }
    Windows = @{ Path = 'install/windows.hyper-v.ps1'; Pattern = '(?m)^\$script:YurunaUnattendedProtocolVersion = 1\r?$' }
}
# The installer reasons a step passes on; any other failure is installer_failed.
$script:HostUpdateStepInstallerReason = @('not_provisioned', 'not_elevated', 'runner_present', 'installer_failed', 'clt_missing')
# The remark tokens of an installer record a step passes on: conditions the
# installer went on past that an operator should read. Any other entry of the
# record's remarks is not one of the controller's tokens and is dropped.
$script:HostUpdateStepInstallerRemark = @('utm_upgrade_deferred', 'brew_update_failed')
# What the macOS work runs with: Homebrew's fixed prefixes first, because a
# process that never ran `brew shellenv` does not find brew, or the pwsh and
# utmctl links in /usr/local/bin, on its PATH. Homebrew asks nothing
# (NONINTERACTIVE) and a sudo it starts by itself cannot read a password
# (SUDO_ASKPASS names a program that fails); Homebrew keeps the old keg of an
# upgraded formula, because the listener, the controller and this step run
# from the PowerShell keg. Inherited switches of the repair and the attended
# installer would send the installer down another path or log.
$script:HostUpdateStepMacPathPrefix = @('/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin')
$script:HostUpdateStepMacEnvironment = [ordered]@{ NONINTERACTIVE = '1'; SUDO_ASKPASS = '/usr/bin/false'; HOMEBREW_NO_INSTALL_CLEANUP = '1' }
$script:HostUpdateStepMacRemoveName = @('YURUNA_REPAIR', 'YURUNA_REFRESH', 'YURUNA_INSTALL_LOG')

function Get-HostUpdateStepBound {
    <#
    .SYNOPSIS
        The controller's bound of the install or enable phase for a host
        type: 2400 s for an install on KVM and macOS, 3600 s on Windows,
        300 s for the enable phase and 600 s on macOS.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][ValidateSet('install', 'enable')][string]$Step, [string]$HostType)
    return [int](Get-HostUpdatePhaseBound -HostType $HostType)[$Step]
}

function Get-HostUpdateStepPwshPath {
    <#
    .SYNOPSIS
        The PowerShell 7 this step runs on, which runs the Windows installer
        and Enable-TestAutomation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = $null
    try { $path = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $path = $null }
    if ($path -and [System.IO.Path]::GetFileNameWithoutExtension($path) -eq 'pwsh') { return $path }
    $command = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    return 'pwsh'
}

function Get-HostUpdateStepRemainingSecond {
    <#
    .SYNOPSIS
        Whole seconds left of the step's budget, at least one, after a
        reserve kept back for the cleanup that follows the wait.
    .PARAMETER ReserveSeconds
        On KVM 70 s: the unit's stop (40 s; the unit escalates to SIGKILL
        after 15 s), the rule's removal and its timer's stop (10 s each), and
        the result file. On macOS 90 s: a process table (20 s), the
        test-account members' stop, the root members' TERM and KILL through
        sudo (10 s calls, up to 5 s of waiting each), the rule's removal
        (10 s), and the result file.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][psobject]$Deadline, [ValidateRange(0, 600)][int]$ReserveSeconds = 70)
    $remaining = [long](Get-YurunaDeadlineRemainingMs -Deadline $Deadline) - ([long]$ReserveSeconds * 1000)
    return [int][Math]::Max([long]1, [Math]::Min([long]2147483, [long][Math]::Floor($remaining / 1000)))
}

function Invoke-HostUpdateStepWork {
    <#
    .SYNOPSIS
        Run the work of the install or enable phase and report how it ended.
    .DESCRIPTION
        On KVM the work needs root through sudo, and the test account cannot
        signal a root process, so it runs in the transient unit
        yuruna-host-update-<phase>-<attempt> under the temporary rule: the
        unit's control group is then its whole process tree, and the
        runner's passwordless systemctl ends it. A unit an earlier update or
        attempt left is ended first, so two never run side by side and a
        name is free to be used again. The rule is removed when the work
        ends, however it ends. On Windows the step is elevated and runs the
        work as its own child. On macOS there is no unit: the work runs as
        the test account, as a child of this step, and calls sudo -n per
        command under the temporary rule; what it leaves running is ended
        while the rule is in force, root members through sudo -n /bin/kill,
        before the rule is removed.
    .PARAMETER Context
        The step context.
    .PARAMETER Result
        The step's result record, which gets what happened to the rule.
    .PARAMETER FilePath
        The program.
    .PARAMETER ArgumentList
        Its arguments.
    .PARAMETER Environment
        Variables the work needs; on KVM the unit gets these and the
        ones systemd sets for its user.
    .PARAMETER Native
        A replacement for the native calls.
    .OUTPUTS
        [pscustomobject] @{ Ran; ExitCode; TimedOut; Reason }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A step child runs unattended; the rule and unit helpers it calls gate each change.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [AllowNull()][scriptblock]$Native
    )
    $answer = { param($Ran, $Code, $TimedOut, $Reason) [pscustomobject]@{ Ran = [bool]$Ran; ExitCode = $Code; TimedOut = [bool]$TimedOut; Reason = $Reason } }
    if ($IsWindows) {
        $r = if ($Native) { & $Native $FilePath $ArgumentList (Get-HostUpdateStepRemainingSecond -Deadline $Context.Deadline) } else {
            Invoke-BoundedNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -WorkingDirectory $Context.RepoRoot `
                -TimeoutSeconds (Get-HostUpdateStepRemainingSecond -Deadline $Context.Deadline)
        }
        return (& $answer $true $r.ExitCode $r.TimedOut $null)
    }
    $account = [Environment]::UserName
    if ((Get-HostUpdateStepPlatform -HostType $Context.HostType) -eq 'MacOS') {
        return (Invoke-HostUpdateStepMacWork -Context $Context -Result $Result -Account $account -FilePath $FilePath -ArgumentList $ArgumentList -Environment $Environment -Native $Native)
    }
    $earlier = Get-HostUpdateElevatedUnit -Native $Native
    if ($null -eq $earlier -or (@($earlier).Count -gt 0 -and -not (Stop-HostUpdateElevatedUnit -Unit $earlier -Native $Native -Confirm:$false))) {
        return (& $answer $false $null $false 'earlier-unit-alive')
    }
    $expiry = [int](Get-HostUpdateStepBound -Step $Context.Step -HostType $Context.HostType) + 120
    $rule = Set-HostUpdateSudoRule -Account $account -ExpirySeconds $expiry -WorkDirectory $Context.WorkDirectory -Native $Native -Confirm:$false
    $Result['detail']['rule'] = [string]$rule.Reason
    if (-not $rule.Written) { return (& $answer $false $null $false 'elevation_rule_refused') }
    $unit = "yuruna-host-update-$($Context.Step)-$($Context.Attempt)"
    try {
        $arguments = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @('-n', 'systemd-run', "--unit=$unit", "--uid=$account", '--wait', '--collect', '--quiet',
                '--property=StandardInput=null', '--property=TimeoutStopSec=15s', "--property=WorkingDirectory=$($Context.RepoRoot)")) { $arguments.Add($item) }
        foreach ($name in @($Environment.Keys | Sort-Object)) { $arguments.Add('--setenv'); $arguments.Add("$name=$($Environment[$name])") }
        $arguments.Add('--')
        $arguments.Add($FilePath)
        foreach ($item in $ArgumentList) { $arguments.Add($item) }
        $r = Invoke-HostUpdateNative -Native $Native -FilePath 'sudo' -ArgumentList $arguments.ToArray() -TimeoutSeconds (Get-HostUpdateStepRemainingSecond -Deadline $Context.Deadline)
        return (& $answer $true $r.ExitCode $r.TimedOut $null)
    } finally {
        # Whatever ended the wait, the unit and the rule end with it.
        $stopped = Stop-HostUpdateElevatedUnit -Unit @($unit) -Native $Native -TimeoutSeconds 40 -Confirm:$false
        $removed = Remove-HostUpdateSudoRule -Native $Native -TimeoutSeconds 10 -Confirm:$false
        $Result['detail']['unitStopped'] = [bool]$stopped
        $Result['detail']['ruleRemoved'] = [bool]$removed
    }
}

function Get-HostUpdateStepMacEnvironment {
    <#
    .SYNOPSIS
        The environment of the macOS work: the phase's variables, the fixed
        ones, and a PATH that starts with Homebrew's prefixes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Environment = @{})
    $result = @{}
    foreach ($name in $Environment.Keys) { $result[[string]$name] = [string]$Environment[$name] }
    foreach ($name in $script:HostUpdateStepMacEnvironment.Keys) { $result[$name] = $script:HostUpdateStepMacEnvironment[$name] }
    $inherited = if ($result.ContainsKey('PATH')) { $result['PATH'] } else { [string]$env:PATH }
    $rest = @($inherited -split ':' | Where-Object { $_ -and $_ -cnotin $script:HostUpdateStepMacPathPrefix })
    $result['PATH'] = (@($script:HostUpdateStepMacPathPrefix) + $rest) -join ':'
    return $result
}

function Invoke-HostUpdateStepChildWork {
    <#
    .SYNOPSIS
        Run the work of a macOS install or enable phase as a child of this
        step and wait for it, up to a bound.
    .DESCRIPTION
        The child's standard input is /dev/null and both output streams go
        to a log in the request's work folder, through a shell that execs the
        program, so the process has the program's own arguments and holds no
        pipe of this step. At the bound the phase's processes are read from
        one process table before anything is ended: a root member of the
        tree is reparented once its parent dies and could not be found
        again. Members are then ended, root ones through sudo -n /bin/kill,
        which the caller's temporary rule allows; with no complete table,
        the child's tree is ended as the test account.
    .PARAMETER RequestId
        The host update, which names the installer's processes.
    .PARAMETER FilePath
        The program.
    .PARAMETER ArgumentList
        Its arguments.
    .PARAMETER Environment
        Variables set for the child.
    .PARAMETER RemoveEnvironmentVariable
        Inherited variables the child must not have.
    .PARAMETER WorkingDirectory
        The child's working directory: the checkout the work runs from, which
        also names the Enable runs that belong to this update.
    .PARAMETER LogPath
        Where the child's output goes.
    .PARAMETER TimeoutSeconds
        The bound.
    .PARAMETER Native
        A replacement for the native calls that end root members.
    .OUTPUTS
        [pscustomobject] @{ Started; ExitCode; TimedOut }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A step child runs unattended; it starts and ends only its own work.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string[]]$RemoveEnvironmentVariable = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][ValidateRange(1, 2147483)][int]$TimeoutSeconds,
        [AllowNull()][scriptblock]$Native
    )
    $answer = { param($Started, $Code, $TimedOut) [pscustomobject]@{ Started = [bool]$Started; ExitCode = $Code; TimedOut = [bool]$TimedOut } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
    foreach ($item in @('-c', 'log=$1; shift; exec "$@" < /dev/null >> "$log" 2>&1', 'sh', $LogPath, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$item) }
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($name in $RemoveEnvironmentVariable) { $null = $psi.Environment.Remove($name) }
    foreach ($name in $Environment.Keys) { $psi.Environment[[string]$name] = [string]$Environment[$name] }
    $process = $null
    try { $process = [System.Diagnostics.Process]::Start($psi) } catch {
        Write-Verbose "Invoke-HostUpdateStepChildWork: the work did not start: $($_.Exception.Message)"
        return (& $answer $false $null $false)
    }
    try {
        if ($process.WaitForExit([int][Math]::Min([long]$TimeoutSeconds * 1000, [long][int]::MaxValue))) {
            $process.WaitForExit()
            return (& $answer $true $process.ExitCode $false)
        }
        $work = Get-HostUpdateMacElevatedWork -RequestId $RequestId -Checkout $WorkingDirectory
        if ($null -ne $work) { $null = Stop-HostUpdateMacElevatedWork -Work $work -Native $Native -Confirm:$false }
        # The table may not have named the child (incomplete, or argv that
        # did not match); its own tree is then ended as the test account.
        if (-not $process.WaitForExit(2000)) {
            try { $process.Kill($true) } catch { Write-Verbose "Invoke-HostUpdateStepChildWork: the kill failed: $($_.Exception.Message)" }
            $null = $process.WaitForExit(5000)
        }
        return (& $answer $true 124 $true)
    } finally { $process.Dispose() }
}

function Invoke-HostUpdateStepMacWork {
    <#
    .SYNOPSIS
        The macOS branch of Invoke-HostUpdateStepWork.
    .DESCRIPTION
        Work an earlier attempt of this request left running (its installer,
        or an unattended Enable-TestAutomation) is ended first, under the new
        rule, so two never run side by side; work that does not end refuses
        the attempt. Whatever ends the wait, the work's processes are ended
        again, while the rule is in force, before the rule is removed.
    .OUTPUTS
        [pscustomobject] @{ Ran; ExitCode; TimedOut; Reason }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A step child runs unattended; the rule and work helpers it calls gate each change.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [AllowNull()][scriptblock]$Native
    )
    $answer = { param($Ran, $Code, $TimedOut, $Reason) [pscustomobject]@{ Ran = [bool]$Ran; ExitCode = $Code; TimedOut = [bool]$TimedOut; Reason = $Reason } }
    # A table that cannot be read refuses before any rule is written.
    if ($null -eq (Get-HostUpdateMacElevatedWork -RequestId $Context.RequestId -Checkout $Context.RepoRoot)) { return (& $answer $false $null $false 'earlier-work-unknown') }
    $expiry = [int](Get-HostUpdateStepBound -Step $Context.Step -HostType $Context.HostType) + 120
    $rule = Set-HostUpdateSudoRule -Account $Account -ExpirySeconds $expiry -WorkDirectory $Context.WorkDirectory -Native $Native -HostType 'host.macos.utm' -Confirm:$false
    $Result['detail']['rule'] = [string]$rule.Reason
    if (-not $rule.Written) { return (& $answer $false $null $false 'elevation_rule_refused') }
    try {
        # Read again once the rule is in force: earlier work that forked a
        # root child while the rule was checked and written would leave that
        # child out of the first reading, and once its parent ends it is
        # reparented where no later reading finds it.
        $earlier = Get-HostUpdateMacElevatedWork -RequestId $Context.RequestId -Checkout $Context.RepoRoot
        if ($null -eq $earlier) { return (& $answer $false $null $false 'earlier-work-unknown') }
        if (@($earlier).Count -gt 0 -and -not (Stop-HostUpdateMacElevatedWork -Work $earlier -Native $Native -Confirm:$false)) {
            return (& $answer $false $null $false 'earlier-work-alive')
        }
        $r = Invoke-HostUpdateStepChildWork -RequestId $Context.RequestId -FilePath $FilePath -ArgumentList $ArgumentList -Environment (Get-HostUpdateStepMacEnvironment -Environment $Environment) `
            -RemoveEnvironmentVariable $script:HostUpdateStepMacRemoveName -WorkingDirectory $Context.RepoRoot -Native $Native `
            -LogPath ([System.IO.Path]::Combine($Context.WorkDirectory, "$($Context.Step).$($Context.Attempt).work.log")) `
            -TimeoutSeconds (Get-HostUpdateStepRemainingSecond -Deadline $Context.Deadline -ReserveSeconds 90)
        if (-not $r.Started) { return (& $answer $false $null $false 'work-not-started') }
        return (& $answer $true $r.ExitCode $r.TimedOut $null)
    } finally {
        $left = Get-HostUpdateMacElevatedWork -RequestId $Context.RequestId -Checkout $Context.RepoRoot
        $Result['detail']['workStopped'] = [bool](Stop-HostUpdateMacElevatedWork -Work $left -Native $Native -Confirm:$false)
        $Result['detail']['ruleRemoved'] = [bool](Remove-HostUpdateSudoRule -Native $Native -TimeoutSeconds 10 -HostType 'host.macos.utm' -Confirm:$false)
    }
}

function Copy-HostUpdateStepInstaller {
    <#
    .SYNOPSIS
        Copy the Windows installer into a new folder under %ProgramData%\yuruna
        that only Administrators and SYSTEM can write, and check the copy.
    .DESCRIPTION
        The step is elevated; a file in a folder the account can write
        unelevated could be replaced between the copy and the run, the
        reason the installer runs its own elevated stage from such a
        folder. The folder is owned by Administrators with OWNER RIGHTS
        read-only, as the controller root is, because the account that
        creates a folder owns it and an owner may rewrite its access list.
        The folder is named by request and attempt, so the PowerShell
        upgrade of the upgrade_pwsh phase finds the copy, which the shim
        accepts only under %ProgramData%\yuruna; the upgrade_pwsh phase checks
        it and its hash again.
    .OUTPUTS
        [pscustomobject] @{ Path; Sha256 }, or $null.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A step child runs unattended; it writes only its own new folder.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$Attempt)
    $dir = Get-HostUpdateInstallerCopyDirectory -RequestId $RequestId -Attempt $Attempt
    if (-not $dir) { return $null }
    try {
        if ([System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::Delete($dir, $true) }
        if (-not (New-HostUpdateWindowsAdminOnlyDirectory -Path $dir -Confirm:$false)) { return $null }
        $target = [System.IO.Path]::Combine($dir, 'windows.hyper-v.ps1')
        [System.IO.File]::Copy($Source, $target)
        $a = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($Source)))
        $b = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($target)))
        if ($a -cne $b) { return $null }
        return [pscustomobject]@{ Path = $target; Sha256 = $b }
    } catch {
        Write-Verbose "Copy-HostUpdateStepInstaller: $($_.Exception.Message)"
        return $null
    }
}

function Read-HostUpdateStepInstallResult {
    <#
    .SYNOPSIS
        The installer's result record, when it is this request's and
        attempt's: on KVM under the state folder, on Windows under
        LOCALAPPDATA.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$Attempt, [string]$Path)
    if (-not $Path) {
        $Path = if ($IsWindows) { [System.IO.Path]::Combine($env:LOCALAPPDATA, 'yuruna', 'install-result.json') } else {
            $state = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { [System.IO.Path]::Combine($HOME, '.local', 'state') }
            [System.IO.Path]::Combine($state, 'yuruna', 'install-result.json')
        }
    }
    try {
        $info = [System.IO.FileInfo]::new($Path)
        if (-not $info.Exists -or $info.LinkTarget -or $info.Length -gt 1048576) { return $null }
        $record = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Read-HostUpdateStepInstallResult: '$Path' unreadable: $($_.Exception.Message)"
        return $null
    }
    if ($record -isnot [System.Collections.IDictionary] -or [string]$record['requestId'] -cne $RequestId -or "$($record['attempt'])" -ne "$Attempt" -or
        -not [bool]$record['unattended']) { return $null }
    return $record
}

function Invoke-HostUpdateStepInstall {
    <#
    .SYNOPSIS
        The install phase: run the checkout's installer unattended and report its
        record: the reason token of a failure, issues as a remark, the
        record's own remark tokens, a PowerShell that changed (KVM, macOS) or
        waits for its upgrade (Windows), and a restart of Windows the
        installer asked for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result, [AllowNull()][scriptblock]$Native)
    $Result['restartRequired'] = $false
    $Result['pwshChanged'] = $false
    $Result['pwshUpgradePending'] = $false
    $marker = $script:HostUpdateStepInstallerMarker[(Get-HostUpdateStepPlatform -HostType $Context.HostType)]
    $installer = [System.IO.Path]::Combine($Context.RepoRoot, $marker.Path)
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($installer) } catch { $text = $null }
    if (-not $text -or $text -cnotmatch $marker.Pattern) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'installer_unmarked' -Action 'repair_checkout'
        return
    }
    if ($IsWindows) {
        $copied = Copy-HostUpdateStepInstaller -Source $installer -RequestId $Context.RequestId -Attempt $Context.Attempt
        if (-not $copied) {
            $Result['detail']['copy'] = 'failed'
            Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'installer_failed' -Action 'act_at_host'
            return
        }
        $copy = $copied.Path
        $Result['installerSha256'] = $copied.Sha256
        $work = Invoke-HostUpdateStepWork -Context $Context -Result $Result -Native $Native -FilePath (Get-HostUpdateStepPwshPath) -Environment @{ YURUNA_NONINTERACTIVE = '1' } -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $copy, '-Unattended', '-YurunaDir', $Context.RepoRoot,
            '-RequestId', $Context.RequestId, '-Attempt', "$($Context.Attempt)")
    } else {
        # A unit starts with systemd's own PATH; the step's is the one its
        # PowerShell was found on. The macOS work adds Homebrew's prefixes.
        $environment = @{ YURUNA_DIR = $Context.RepoRoot; YURUNA_RUNTIME_DIR = $Context.RuntimeDir; YURUNA_NONINTERACTIVE = '1'; PATH = [string]$env:PATH }
        if ($env:XDG_STATE_HOME) { $environment['XDG_STATE_HOME'] = [string]$env:XDG_STATE_HOME }
        $work = Invoke-HostUpdateStepWork -Context $Context -Result $Result -Native $Native -FilePath '/bin/bash' -Environment $environment -ArgumentList @(
            $installer, '--unattended', '--request-id', $Context.RequestId, '--attempt', "$($Context.Attempt)")
    }
    $Result['detail']['work'] = [ordered]@{ ran = $work.Ran; exitCode = $work.ExitCode; timedOut = $work.TimedOut; reason = [string]$work.Reason }
    if (-not $work.Ran) {
        $reason = if ($work.Reason -eq 'elevation_rule_refused') { 'elevation_rule_refused' } else { 'installer_failed' }
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $reason -Action 'provision_elevation'
        return
    }
    $record = Read-HostUpdateStepInstallResult -RequestId $Context.RequestId -Attempt $Context.Attempt
    if (-not $record) {
        $Result['detail']['record'] = 'missing'
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'installer_failed' -Action 'read_remarks'
        return
    }
    $Result['detail']['installer'] = [ordered]@{ outcome = [string]$record['outcome']; exitCode = $record['exitCode']; step = [string]$record['step'] }
    $upgrade = $record['pwshUpgrade']
    if ($upgrade -is [System.Collections.IDictionary]) {
        if ($IsWindows -and [bool]$upgrade['pending']) { $Result['pwshUpgradePending'] = $true }
        if (-not $IsWindows -and -not [bool]$upgrade['pending'] -and [string]$upgrade['from'] -cne [string]$upgrade['to']) { $Result['pwshChanged'] = $true }
    }
    $Result['restartRequired'] = [bool]$record['restartRequired'] -or [string]$record['outcome'] -eq 'restart-required'
    if ([string]$record['outcome'] -eq 'failed') {
        $reason = [string]$record['reason']
        if ($reason -cnotin $script:HostUpdateStepInstallerReason) { $reason = 'installer_failed' }
        $action = switch ($reason) { 'not_elevated' { 'provision_elevation' } 'runner_present' { 'stop_runner_by_hand' } 'clt_missing' { 'act_at_host' } default { 'read_remarks' } }
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $reason -Action $action
        return
    }
    if (@($record['issues']).Count -gt 0) { $Result['remarks'].Add('install_issues') }
    foreach ($remark in @($record['remarks'])) {
        if ($remark -is [string] -and $remark -cin $script:HostUpdateStepInstallerRemark) { $Result['remarks'].Add($remark) }
    }
    Set-HostUpdateStepOutcome -Result $Result -Outcome done
}

function Invoke-HostUpdateStepEnable {
    <#
    .SYNOPSIS
        The enable phase: Enable-TestAutomation -SkipPoolStorage
        -NoOperatorPrompt.
        Exit 2 is a pass with the remark host_settings_unmet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Result, [AllowNull()][scriptblock]$Native)
    $script = [System.IO.Path]::Combine($Context.RepoRoot, 'test', 'lab', 'Enable-TestAutomation.ps1')
    $environment = @{ YURUNA_NONINTERACTIVE = '1'; YURUNA_RUNTIME_DIR = $Context.RuntimeDir }
    if (-not $IsWindows) { $environment['PATH'] = [string]$env:PATH }
    $work = Invoke-HostUpdateStepWork -Context $Context -Result $Result -Native $Native -FilePath (Get-HostUpdateStepPwshPath) -Environment $environment -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script, '-SkipPoolStorage', '-NoOperatorPrompt')
    $Result['detail']['work'] = [ordered]@{ ran = $work.Ran; exitCode = $work.ExitCode; timedOut = $work.TimedOut; reason = [string]$work.Reason }
    if (-not $work.Ran) {
        $reason = if ($work.Reason -eq 'elevation_rule_refused') { 'elevation_rule_refused' } else { 'enable_failed' }
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason $reason -Action 'provision_elevation'
        return
    }
    if ($work.TimedOut -or $work.ExitCode -notin @(0, 2)) {
        Set-HostUpdateStepOutcome -Result $Result -Outcome failed -Reason 'enable_failed' -Action 'read_remarks'
        return
    }
    if ($work.ExitCode -eq 2) { $Result['remarks'].Add('host_settings_unmet') }
    Set-HostUpdateStepOutcome -Result $Result -Outcome done
}

# --- REGION: Entry
function Get-HostUpdateStepCanonicalPath {
    <#
    .SYNOPSIS
        A directory's canonical spelling (links resolved), for comparison.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $canonical = Resolve-YurunaCanonicalPath -Path $Path
    $text = if ($canonical.Resolved -and $canonical.Path) { [string]$canonical.Path } else { [System.IO.Path]::GetFullPath($Path) }
    return $text.TrimEnd('/', '\')
}

function Resolve-HostUpdateStepWorkDirectory {
    <#
    .SYNOPSIS
        The request's work folder under the controller root, when the result
        path lies directly in it; otherwise $null and nothing is written.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ResultPath, [Parameter(Mandatory)][string]$RequestId)
    $controllerRoot = Get-HostUpdateControllerRoot -NoCreate
    if (-not $controllerRoot -or -not [System.IO.Path]::IsPathFullyQualified($ResultPath)) { return $null }
    $expected = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($controllerRoot, 'work', $RequestId))
    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ResultPath))
    if ($directory -cne $expected -or -not [System.IO.Directory]::Exists($directory)) { return $null }
    return [pscustomobject]@{ ControllerRoot = $controllerRoot; WorkDirectory = $directory }
}

function Invoke-HostUpdateStep {
    <#
    .SYNOPSIS
        Run one step of a host update and write its result file.
    .DESCRIPTION
        The prologue every step shares: the runtime directory comes from
        YURUNA_RUNTIME_DIR and is never defaulted, and must be the one the
        request names; the host identity must already exist in it (it is
        never minted here) and is published as $global:__YurunaHostId, as
        Start-TestRunner.ps1 does, because the source update reads the canary
        ring from exactly these two values. The request row is read, never
        written.
    .PARAMETER Step
        preflight, stop_runner, update_source, install, enable,
        start_listener or start_runner.
    .PARAMETER RequestId
        The host update's request id.
    .PARAMETER Attempt
        The phase's attempt number, as the controller journaled it.
    .PARAMETER ResultPath
        The result file, in the request's work folder under the controller
        root.
    .PARAMETER RepoRoot
        The checkout the step acts on.
    .PARAMETER ControllerPid
        The controller, recorded as the gate's owner by start_runner.
    .PARAMETER StartTickMs
        When the step child started, on the boot-relative tick clock, so its
        budget counts the module imports.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] the result written,
        or $null when the result path is not the request's work folder.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Publishes $global:__YurunaHostId, the identity channel the entry points set and the source update reads.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('preflight', 'stop_runner', 'update_source', 'install', 'enable', 'start_listener', 'start_runner')][string]$Step,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Attempt,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$ControllerPid = 0,
        [long]$StartTickMs = [Environment]::TickCount64
    )
    $work = Resolve-HostUpdateStepWorkDirectory -ResultPath $ResultPath -RequestId $RequestId
    if (-not $work) {
        [Console]::Error.WriteLine("yuruna-host-update-step: event=result-path-refused step=$Step")
        return $null
    }
    $result = New-HostUpdateStepResult -Step $Step -RequestId $RequestId -Attempt $Attempt
    $finish = {
        # Read last: after the source update it is the number of the new code.
        $result['protocol'] = Get-HostUpdateProtocolVersion -RepoRoot $RepoRoot
        $null = Write-HostUpdateStepResult -Path $ResultPath -Result $result
        $result
    }
    $runtime = [string]$env:YURUNA_RUNTIME_DIR
    if (-not $runtime -or -not [System.IO.Path]::IsPathFullyQualified($runtime) -or -not [System.IO.Directory]::Exists($runtime)) {
        Set-HostUpdateStepOutcome -Result $result -Outcome failed -Reason 'runtime_unresolved' -Action 'act_at_host'
        return (& $finish)
    }
    $row = Get-HostUpdateRequest -RequestId $RequestId
    if (-not $row) {
        $result['detail']['cause'] = 'request-unreadable'
        Set-HostUpdateStepOutcome -Result $result -Outcome failed -Reason 'step_interrupted' -Action 'act_at_host'
        return (& $finish)
    }
    $requested = [string]$row['runtimeDir']
    if (-not $requested -or (Get-HostUpdateStepCanonicalPath -Path $runtime) -cne (Get-HostUpdateStepCanonicalPath -Path $requested)) {
        Set-HostUpdateStepOutcome -Result $result -Outcome failed -Reason 'runtime_unresolved' -Action 'act_at_host'
        return (& $finish)
    }
    $uuidPath = [System.IO.Path]::Combine($runtime, 'host.uuid')
    $uuid = $null
    try { if ([System.IO.File]::Exists($uuidPath)) { $uuid = ([System.IO.File]::ReadAllText($uuidPath)).Trim() } } catch { Write-Verbose "Invoke-HostUpdateStep: host.uuid unreadable: $($_.Exception.Message)" }
    if (-not $uuid) {
        Set-HostUpdateStepOutcome -Result $result -Outcome failed -Reason 'host_identity_unresolved' -Action 'act_at_host'
        return (& $finish)
    }
    $hostId = Get-YurunaHostId -RuntimeDir $runtime
    if (-not $hostId) {
        Set-HostUpdateStepOutcome -Result $result -Outcome failed -Reason 'host_identity_unresolved' -Action 'act_at_host'
        return (& $finish)
    }
    $global:__YurunaHostId = $hostId
    $root = Get-HostOperationPrivateRoot -NoCreate
    $budget = (Get-HostUpdateStepBudget -Step $Step -HostType ([string]$row['hostType'])) - [Math]::Max([long]0, [Environment]::TickCount64 - $StartTickMs)
    $context = @{
        Step = $Step; RequestId = $RequestId; Attempt = $Attempt; RepoRoot = $RepoRoot; RuntimeDir = $runtime; Row = $row
        Update = $row['update']; HostType = [string]$row['hostType']; PrivateRoot = if ($root.Resolved) { [string]$root.Path } else { $null }
        ControllerRoot = $work.ControllerRoot; WorkDirectory = $work.WorkDirectory; ControllerPid = $ControllerPid
        Deadline = New-YurunaDeadline -TotalMilliseconds ([Math]::Max([long]5000, $budget))
    }
    switch ($Step) {
        'preflight' { Invoke-HostUpdateStepPreflight -Context $context -Result $result }
        'stop_runner' { Invoke-HostUpdateStepStopRunner -Context $context -Result $result }
        'update_source' { Invoke-HostUpdateStepUpdateSource -Context $context -Result $result }
        'install' { Invoke-HostUpdateStepInstall -Context $context -Result $result }
        'enable' { Invoke-HostUpdateStepEnable -Context $context -Result $result }
        'start_listener' { Invoke-HostUpdateStepStartListener -Context $context -Result $result }
        'start_runner' { Invoke-HostUpdateStepStartRunner -Context $context -Result $result }
    }
    return (& $finish)
}

Export-ModuleMember -Function Invoke-HostUpdateStep, Get-HostUpdateStepExitCode
