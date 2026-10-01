<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42de8e40-1c77-40c0-96f2-3a5e144992e2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service start-cycle worker host-refresh pester
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
    The detached start-cycle worker: every control mutation happens only
    under the lifetime repair lock and a confirmed reservation, in the order
    the runner relies on, and the runner is started only on positive absence
    observed after the cleanup.
.DESCRIPTION
    Each case runs the real worker as its own process against a scratch HOME
    and runtime, with the real single-flight lock. The functions owned by the
    refresh journal (the lock path and the reservation) and by the detached
    launcher are replaced by a stub module, imported after the worker's own
    imports, that records every call and answers from control files the case
    writes -- the worker is tested against the contract, not against a
    particular implementation of it. The runner's state before and after the
    cleanup comes from the same control files, so a cleanup stand-in can
    change it mid-run.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Worker = Join-Path $here 'Invoke-StartCycleWorker.ps1'
$script:Runner = Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path

$script:StubModule = @'
$script:StubDir = $env:YURUNA_TEST_STUB_DIR
function Write-StubCall { param([string]$Line) Add-Content -LiteralPath (Join-Path $script:StubDir 'calls.log') -Value $Line }
function Get-StubControl { param([string]$Name)
    $path = Join-Path $script:StubDir $Name
    if (Test-Path -LiteralPath $path) { return ([IO.File]::ReadAllText($path)).Trim() }
    return '' }
function Get-YurunaHostRefreshLockPath { param([switch]$NoCreate) $null = $NoCreate; Write-StubCall 'lockpath'; return (Join-Path $script:StubDir 'host-refresh.lock') }
function Confirm-HostRefreshStartCycleReservation { param($OperationId, $Generation, $LifetimeLock, $Worker)
    Write-StubCall "confirm:$OperationId|$Generation|$([bool]$LifetimeLock.Held)|$($Worker.pid)"
    $reservation = Get-StubControl 'reservation'
    if ($reservation -like 'reason:*') { return [pscustomobject]@{ Valid = $false; Reason = $reservation.Substring(7) } }
    if ($reservation -eq "$OperationId|$Generation") { return [pscustomobject]@{ Valid = $true; Reason = 'valid' } }
    return [pscustomobject]@{ Valid = $false; Reason = 'reservation-lost' } }
function Complete-HostRefreshStartCycleReservation { param($OperationId, $Generation) Write-StubCall "complete:$OperationId|$Generation"; return [pscustomobject]@{ Cleared = $true } }
function Start-YurunaDetachedProcess { param($FilePath, $ArgumentList, $WorkingDirectory, $StdOutPath, $StdErrPath, $StdInPath, $PrivateDirectory, $Environment, $Deadline, [switch]$Confirm)
    $null = $Deadline, $Confirm
    Write-StubCall ('launch:' + (ConvertTo-Json -Compress -Depth 4 -InputObject @{
        file = $FilePath; args = @($ArgumentList); cwd = $WorkingDirectory; out = $StdOutPath; err = $StdErrPath; in = $StdInPath; dir = $PrivateDirectory; env = $Environment }))
    if ((Get-StubControl 'launch') -eq 'fail') { return [pscustomobject]@{ Launched = $false; Reason = 'launcher-failed' } }
    return [pscustomobject]@{ Launched = $true; Reason = 'launched'; FinalPid = 12345 } }
function Get-YurunaRunnerRecordState { param($PidFile, $StartFile, $ExpectedScriptPath)
    $null = $PidFile, $StartFile, $ExpectedScriptPath
    $state = Get-StubControl 'runner.state'
    Write-StubCall "observe:$state"
    return [pscustomobject]@{ State = $state; Pid = 0; Reason = 'stub' } }
function Read-YurunaRunnerLaunchRecord { param($RuntimeDir) $null = $RuntimeDir
    $record = Get-StubControl 'launch-record'
    if (-not $record) { return [pscustomobject]@{ Found = $false; Valid = $false; Record = $null; Reason = 'missing' } }
    return [pscustomobject]@{ Found = $true; Valid = $true; Record = (ConvertFrom-Json -InputObject $record -AsHashtable); Reason = 'ok' } }
function Test-YurunaRunnerLaunchSpec { param($Record, $ScriptPath, [switch]$RequireExistingConfig) $null = $Record, $ScriptPath, $RequireExistingConfig
    return [pscustomobject]@{ Valid = $true; Reason = 'ok'; Parameter = '' } }
Export-ModuleMember -Function Get-YurunaHostRefreshLockPath, Confirm-HostRefreshStartCycleReservation, Complete-HostRefreshStartCycleReservation,
    Start-YurunaDetachedProcess, Get-YurunaRunnerRecordState, Read-YurunaRunnerLaunchRecord, Test-YurunaRunnerLaunchSpec
'@

# The wrapper runs the worker in its own process and, right after the worker
# imports the refresh journal module (its last import), imports the stub
# module over it, so the stubs are what the worker calls. A module named in
# the stub directory's fail-import file fails to load, as a module broken by
# a pull would.
$script:Wrapper = @'
param([string]$Worker, [string]$Stub, [string]$ArgumentFile)
function global:Import-Module {
    $cmdlet = Get-Command -Name 'Import-Module' -CommandType Cmdlet
    $failing = Join-Path $env:YURUNA_TEST_STUB_DIR 'fail-import'
    if ([IO.File]::Exists($failing) -and [string]$args[0] -like ('*' + ([IO.File]::ReadAllText($failing)).Trim())) {
        throw [System.IO.FileLoadException]::new('stub import failure')
    }
    & $cmdlet @args
    if ([string]$args[0] -like '*Test.HostRefreshIntent.psm1') { & $cmdlet $Stub -Global -Force -DisableNameChecking }
}
# Named arguments arrive as one JSON object: pwsh -File passes only the first
# element of an array argument, and an array splat binds positionally.
$workerArgument = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ArgumentFile)) -AsHashtable
& $Worker @workerArgument
exit $LASTEXITCODE
'@

function New-StartCycleScratch {
    <#
    .SYNOPSIS
        A scratch HOME, runtime with controls, log, stub directory and a
        cleanup stand-in.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway test tree.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$RunnerStateBefore = 'Missing',
        [string]$RunnerStateAfter = '',
        [int]$CleanupExit = 0,
        [int]$CleanupSleepSeconds = 0
    )
    $root = New-YurunaTestTempDir -Prefix 'yuruna-startcycle'
    $scratch = [pscustomobject]@{
        Root = $root; Home = (Join-Path $root 'home'); Runtime = (Join-Path $root 'runtime'); Log = (Join-Path $root 'log')
        Stub = (Join-Path $root 'stub'); Cleanup = (Join-Path $root 'Remove-TestVMFiles.ps1')
        OperationId = [Guid]::NewGuid().ToString('D'); Generation = 'gen-0001'
    }
    $null = New-Item -ItemType Directory -Path $scratch.Home, $scratch.Runtime, $scratch.Log, $scratch.Stub
    [IO.File]::WriteAllText((Join-Path $scratch.Stub 'stub.psm1'), $script:StubModule)
    [IO.File]::WriteAllText((Join-Path $scratch.Stub 'wrapper.ps1'), $script:Wrapper)
    [IO.File]::WriteAllText((Join-Path $scratch.Stub 'runner.state'), $RunnerStateBefore)
    [IO.File]::WriteAllText((Join-Path $scratch.Stub 'reservation'), "$($scratch.OperationId)|$($scratch.Generation)")
    $after = if ($RunnerStateAfter) { "[IO.File]::WriteAllText('$((Join-Path $scratch.Stub 'runner.state') -replace "'", "''")', '$RunnerStateAfter')" } else { '' }
    [IO.File]::WriteAllText($scratch.Cleanup, @"
[IO.File]::WriteAllText('$((Join-Path $scratch.Stub 'cleanup.ran') -replace "'", "''")', `$env:YURUNA_NONINTERACTIVE + '|' + `$env:YURUNA_RUNTIME_DIR)
$after
Start-Sleep -Seconds $CleanupSleepSeconds
Write-Output 'cleanup output'
exit $CleanupExit
"@)
    foreach ($name in @('control.cycle-pause', 'control.step-pause', 'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release')) {
        [IO.File]::WriteAllText((Join-Path $scratch.Runtime $name), "held:$name")
    }
    [IO.File]::WriteAllText((Join-Path $scratch.Runtime 'status.json'), (ConvertTo-Json -Compress -InputObject ([ordered]@{
                overallStatus = 'running'; cyclePaused = $true; stepPaused = $true; cyclePausedSinceUtc = '2026-09-25T10:00:00Z'
                stepPausedSinceUtc = '2026-09-25T10:00:00Z'; labHold = $true; labHoldAreas = @('proxy'); cycle = 42 })))
    return $scratch
}

function Invoke-StartCycleWorker {
    <#
    .SYNOPSIS
        Run the worker under the wrapper as its own process.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Scratch,
        [string]$Generation,
        [int]$LockWaitSeconds = 2,
        [int]$CleanupTimeoutSeconds = 120
    )
    $saved = @{}
    foreach ($name in @('HOME', 'USERPROFILE', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_TEST_STUB_DIR')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        # Windows derives the home directory from USERPROFILE, not HOME.
        $env:HOME = $Scratch.Home
        $env:USERPROFILE = $Scratch.Home
        $env:YURUNA_RUNTIME_DIR = $Scratch.Runtime
        $env:YURUNA_LOG_DIR = $Scratch.Log
        $env:YURUNA_TEST_STUB_DIR = $Scratch.Stub
        $argumentFile = Join-Path $Scratch.Stub 'arguments.json'
        [IO.File]::WriteAllText($argumentFile, (ConvertTo-Json -Compress -InputObject ([ordered]@{
                        OperationId = $Scratch.OperationId; Generation = $(if ($Generation) { $Generation } else { $Scratch.Generation })
                        RuntimeDir = $Scratch.Runtime; CleanupScriptPath = $Scratch.Cleanup; RunnerScriptPath = $script:Runner
                        WorkingDirectory = $Scratch.Root; LockWaitSeconds = $LockWaitSeconds; CleanupTimeoutSeconds = $CleanupTimeoutSeconds })))
        $output = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $Scratch.Stub 'wrapper.ps1') -Worker $script:Worker `
            -Stub (Join-Path $Scratch.Stub 'stub.psm1') -ArgumentFile $argumentFile 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
    $statePath = Join-Path $Scratch.Runtime 'start-cycle.state.json'
    $state = if (Test-Path -LiteralPath $statePath) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) } else { $null }
    $callsPath = Join-Path $Scratch.Stub 'calls.log'
    $calls = if (Test-Path -LiteralPath $callsPath) { @([IO.File]::ReadAllLines($callsPath)) } else { @() }
    return [pscustomobject]@{ ExitCode = $code; State = $state; Calls = $calls; Output = ($output -replace "`e\[[0-9;]*[A-Za-z]", '') }
}

function Get-ControlSnapshot {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Scratch)
    $snapshot = @{}
    foreach ($name in @('control.cycle-pause', 'control.step-pause', 'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release', 'status.json', 'control.cycle-restart')) {
        $path = Join-Path $Scratch.Runtime $name
        $snapshot[$name] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null }
    }
    return $snapshot
}

function Confirm-NothingChanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][hashtable]$After, [string]$Because = '')
    $findings = @()
    foreach ($name in $Before.Keys) { if ($Before[$name] -cne $After[$name]) { $findings += "$name changed" } }
    Assert-NoFinding $findings $Because
}
}

Describe 'a start-cycle changes controls only under the lock and a confirmed reservation' {

    It 'clears the controls in order, cleans up, starts an absent runner and clears its reservation' {
        $scratch = New-StartCycleScratch -RunnerStateBefore 'Missing'
        try {
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 0 $run.ExitCode "the worker failed: $($run.Output)"
            Assert-StringEqual 'completed' $run.State.phase
            Assert-StringEqual 'succeeded' $run.State.result
            Assert-StringEqual 'spawned' $run.State.action
            Assert-Null $run.State.reason
            foreach ($name in @('control.cycle-pause', 'control.step-pause', 'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release')) {
                Assert-False (Test-Path -LiteralPath (Join-Path $scratch.Runtime $name)) "$name is cleared"
            }
            $status = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $scratch.Runtime 'status.json')))
            Assert-False $status.cyclePaused
            Assert-False $status.stepPaused
            Assert-StringEqual '' $status.cyclePausedSinceUtc
            Assert-False $status.labHold
            Assert-Equal 0 @($status.labHoldAreas).Count
            Assert-Equal 42 $status.cycle 'every other status field is kept'
            Assert-True (Test-Path -LiteralPath (Join-Path $scratch.Runtime 'control.cycle-restart')) 'the restart request is written'
            Assert-StringEqual "1|$($scratch.Runtime)" ([IO.File]::ReadAllText((Join-Path $scratch.Stub 'cleanup.ran'))) 'the cleanup ran non-interactive against this runtime'
            $order = @($run.Calls | ForEach-Object { ($_ -split '[:|]')[0] })
            Assert-StringEqual 'lockpath,confirm,observe,observe,launch,complete' ($order -join ',') 'lock, confirm, observe before and after the cleanup, launch, then clear'
            Assert-Match "^confirm:$($scratch.OperationId)\|gen-0001\|True\|" ($run.Calls | Where-Object { $_ -like 'confirm:*' })
            $launch = ConvertFrom-Json -InputObject ((@($run.Calls | Where-Object { $_ -like 'launch:*' })[0]).Substring(7))
            Assert-StringEqual $script:Runner $launch.file
            Assert-Equal 0 @($launch.args).Count 'with no launch record the runner starts on its defaults'
            Assert-StringEqual $scratch.Runtime $launch.env.YURUNA_RUNTIME_DIR
            $private = Join-Path $scratch.Home '.yuruna/host-refresh/start-cycle'
            Assert-StringEqual $private $launch.dir 'the runner streams go to the private start-cycle directory'
            Assert-StringEqual (Join-Path $private "runner.$($scratch.OperationId).err") $launch.err
            Assert-StringEqual (Join-Path $private 'stdin.empty') $launch.in
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $scratch.Log -Recurse -Force -File).Count 'the worker writes nothing under the log directory'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $scratch.Runtime -Filter 'runner.spawned-from-web.*').Count 'no runner transcript is written where it is served'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'wakes a live runner through the restart request instead of starting another' {
        $scratch = New-StartCycleScratch -RunnerStateBefore 'AliveOwned'
        try {
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 0 $run.ExitCode
            Assert-StringEqual 'restarted' $run.State.action
            Assert-Equal 0 @($run.Calls | Where-Object { $_ -like 'launch:*' }).Count 'a live runner is never duplicated'
            Assert-True (Test-Path -LiteralPath (Join-Path $scratch.Runtime 'control.cycle-restart'))
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'decides from the state after the cleanup, in both directions' {
        $started = New-StartCycleScratch -RunnerStateBefore 'Missing' -RunnerStateAfter 'AliveOwned'
        try {
            $run = Invoke-StartCycleWorker -Scratch $started
            Assert-StringEqual 'restarted' $run.State.action 'a runner that appeared during cleanup is not started again'
            Assert-Equal 0 @($run.Calls | Where-Object { $_ -like 'launch:*' }).Count
        } finally { Remove-YurunaTestTempDir $started.Root }
        $exited = New-StartCycleScratch -RunnerStateBefore 'AliveOwned' -RunnerStateAfter 'DeadOrRecycled'
        try {
            $run = Invoke-StartCycleWorker -Scratch $exited
            Assert-StringEqual 'spawned' $run.State.action 'a runner that exited during cleanup is replaced'
        } finally { Remove-YurunaTestTempDir $exited.Root }
    }

    It 'starts nothing when the runner state is unknown and reports it incomplete' {
        $scratch = New-StartCycleScratch -RunnerStateBefore 'Unknown'
        try {
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 2 $run.ExitCode
            Assert-StringEqual 'incomplete' $run.State.result
            Assert-StringEqual 'not_spawned' $run.State.action
            Assert-StringEqual 'runner_unknown' $run.State.reason
            Assert-Equal 0 @($run.Calls | Where-Object { $_ -like 'launch:*' }).Count
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'changes nothing while another operation holds the lifetime lock, and releases its reservation' {
        $scratch = New-StartCycleScratch
        try {
            $before = Get-ControlSnapshot -Scratch $scratch
            $held = Enter-YurunaSingleFlightLock -Path (Join-Path $scratch.Stub 'host-refresh.lock')
            Assert-True $held.Held "the test could not take the lifetime lock: $($held.Reason)"
            try { $run = Invoke-StartCycleWorker -Scratch $scratch -LockWaitSeconds 1 } finally { Exit-YurunaSingleFlightLock -Lock $held }
            Assert-Equal 1 $run.ExitCode
            Assert-StringEqual 'failed' $run.State.result
            Assert-StringEqual 'lock_busy' $run.State.reason
            Confirm-NothingChanged -Before $before -After (Get-ControlSnapshot -Scratch $scratch) -Because 'a worker that cannot take the lock writes no control file'
            Assert-False (Test-Path -LiteralPath (Join-Path $scratch.Stub 'cleanup.ran')) 'no cleanup ran'
            Assert-Equal 1 @($run.Calls | Where-Object { $_ -like 'complete:*' }).Count 'the reservation is cleared so a refresh is not blocked behind it'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'changes nothing for every reason its reservation cannot be confirmed' {
        # The reasons the reservation API returns: the reservation is gone (or
        # belongs to another generation), the admission lock stayed busy, the
        # journal could not be written, or the lifetime lock is not held.
        foreach ($case in @(
                @{ Reservation = 'other-op|gen-0009'; Reason = 'reservation_lost' },
                @{ Reservation = 'reason:reservation-lost'; Reason = 'reservation_lost' },
                @{ Reservation = 'reason:admission-busy'; Reason = 'busy' },
                @{ Reservation = 'reason:journal-unwritable'; Reason = 'internal_error' },
                @{ Reservation = 'reason:lifetime-lock-not-held'; Reason = 'internal_error' })) {
            $scratch = New-StartCycleScratch
            try {
                [IO.File]::WriteAllText((Join-Path $scratch.Stub 'reservation'), $case.Reservation)
                $before = Get-ControlSnapshot -Scratch $scratch
                $run = Invoke-StartCycleWorker -Scratch $scratch
                Assert-Equal 1 $run.ExitCode $case.Reservation
                Assert-StringEqual 'failed' $run.State.result
                Assert-StringEqual $case.Reason $run.State.reason $case.Reservation
                Confirm-NothingChanged -Before $before -After (Get-ControlSnapshot -Scratch $scratch) -Because "a refused worker ($($case.Reservation)) writes no control file"
                Assert-Equal 0 @($run.Calls | Where-Object { $_ -like 'observe:*' -or $_ -like 'launch:*' }).Count
                Assert-Equal 1 @($run.Calls | Where-Object { $_ -like 'complete:*' }).Count 'the reservation is still cleared'
            } finally { Remove-YurunaTestTempDir $scratch.Root }
        }
    }

    It 'refuses before any change when a module fails to load, and still clears its reservation' {
        $scratch = New-StartCycleScratch
        try {
            [IO.File]::WriteAllText((Join-Path $scratch.Stub 'fail-import'), 'Test.InnerSpawn.psm1')
            $before = Get-ControlSnapshot -Scratch $scratch
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 1 $run.ExitCode "unexpected exit: $($run.Output)"
            Assert-StringEqual 'completed' $run.State.phase 'the refusal is published'
            Assert-StringEqual 'failed' $run.State.result
            Assert-StringEqual 'internal_error' $run.State.reason
            Confirm-NothingChanged -Before $before -After (Get-ControlSnapshot -Scratch $scratch) -Because 'a worker missing a module writes no control file'
            Assert-False (Test-Path -LiteralPath (Join-Path $scratch.Stub 'cleanup.ran')) 'no cleanup ran'
            Assert-Equal 0 @($run.Calls | Where-Object { $_ -like 'lockpath*' -or $_ -like 'confirm:*' }).Count 'nothing is attempted without the module'
            Assert-Equal 1 @($run.Calls | Where-Object { $_ -like 'complete:*' }).Count 'the reservation is cleared rather than left to its owner dying'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'still decides after a cleanup that failed, and reports the run incomplete' {
        $scratch = New-StartCycleScratch -CleanupExit 7
        try {
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 2 $run.ExitCode
            Assert-StringEqual 'incomplete' $run.State.result
            Assert-StringEqual 'spawned' $run.State.action
            Assert-StringEqual 'cleanup_failed' $run.State.reason
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'bounds a cleanup that hangs, then still decides' {
        $scratch = New-StartCycleScratch -CleanupSleepSeconds 300
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-StartCycleWorker -Scratch $scratch -CleanupTimeoutSeconds 60
            $watch.Stop()
            Assert-StringEqual 'cleanup_timeout' $run.State.reason
            Assert-StringEqual 'spawned' $run.State.action
            Assert-True ($watch.Elapsed.TotalSeconds -lt 120) "the bounded cleanup took $([int]$watch.Elapsed.TotalSeconds) s"
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'reports a failed runner launch as failed' {
        $scratch = New-StartCycleScratch
        try {
            [IO.File]::WriteAllText((Join-Path $scratch.Stub 'launch'), 'fail')
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 1 $run.ExitCode
            Assert-StringEqual 'failed' $run.State.result
            Assert-StringEqual 'not_spawned' $run.State.action
            Assert-StringEqual 'spawn_failed' $run.State.reason
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'starts the runner with the options its recorded launch carried' {
        $scratch = New-StartCycleScratch
        try {
            $config = Join-Path $scratch.Root 'custom.config.yml'
            [IO.File]::WriteAllText($config, 'x: 1')
            [IO.File]::WriteAllText((Join-Path $scratch.Stub 'launch-record'), (ConvertTo-Json -Compress -InputObject @{
                        parameters = @{ ConfigPath = $config; NoGitPull = $true; CycleDelaySeconds = 15 }; explicitlyBound = @('ConfigPath', 'NoGitPull', 'CycleDelaySeconds') }))
            $run = Invoke-StartCycleWorker -Scratch $scratch
            Assert-Equal 0 $run.ExitCode "the worker failed: $($run.Output)"
            $launch = ConvertFrom-Json -InputObject ((@($run.Calls | Where-Object { $_ -like 'launch:*' })[0]).Substring(7))
            Assert-StringEqual "-ConfigPath $config -NoGitPull -CycleDelaySeconds 15" (@($launch.args) -join ' ')
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'refuses an invocation it cannot publish under, writing nothing' {
        $scratch = New-StartCycleScratch
        try {
            $before = Get-ControlSnapshot -Scratch $scratch
            $run = Invoke-StartCycleWorker -Scratch $scratch -Generation "bad generation`n"
            Assert-Equal 1 $run.ExitCode
            Assert-Null $run.State 'no state is published for an operation that failed validation'
            Confirm-NothingChanged -Before $before -After (Get-ControlSnapshot -Scratch $scratch)
            Assert-Equal 0 $run.Calls.Count
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }
}
