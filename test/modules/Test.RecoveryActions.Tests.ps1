<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 428b7f5c-e722-4d67-858d-b11427a01f39
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery actions git-lock reclone failure-pause pester
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
    Pins the repair protocol and the three repairs the runner may make on its own.
.DESCRIPTION
    A repair that changes the machine has to prove itself and undo itself. These
    cases drive every branch of the protocol with a toy action (a precondition
    that declines, an action that throws, a postcondition that fails and a
    rollback that does or does not work), then the built-in repairs against
    throwaway repositories and stand-ins for the clone, the health check, the
    status probe and the process probe. Nothing touches the real runtime
    directory, the real framework checkout, a hypervisor or the network.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The module finds the event writer through the global command table, so the stand-in writer and the events it collects straddle that scope.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryActions.psm1') -Force -DisableNameChecking

# The throwaway repositories must not inherit the developer's git configuration:
# commit signing would prompt, and a file system monitor would leave a daemon
# holding the directory.
$script:GitEnvNames = @('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_TERMINAL_PROMPT')
$script:SavedGitEnv = @{}
foreach ($name in $script:GitEnvNames) { $script:SavedGitEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
$script:EmptyGitConfig = Join-Path ([System.IO.Path]::GetTempPath()) ('recactions-gitconfig-' + [guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($script:EmptyGitConfig, '')
$env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_TERMINAL_PROMPT = '0'
$script:HaveGit = [bool](Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)

function New-ScratchDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temporary directory that AfterEach removes.')]
    param()
    return New-YurunaTestTempDir -Prefix 'recactions' -ErrorAction Stop
}

function Initialize-TestRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($script:HaveGit) {
        & git -c init.defaultBranch=main init -q $Path 2>&1 | Out-Null
        & git -C $Path -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init 2>&1 | Out-Null
    } else {
        New-Item -ItemType Directory -Path (Join-Path $Path '.git/refs/heads') -Force | Out-Null
    }
}

function Add-LockFile {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Relative = '.git/index.lock',
        [double]$MinutesOld = 60,
        [datetime]$At,
        [string]$Content = 'held by process 4242'
    )
    $path = Join-Path $RepoPath $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Content)
    $stamp = if ($PSBoundParameters.ContainsKey('At')) { $At } else { [datetime]::UtcNow.AddMinutes(-$MinutesOld) }
    [System.IO.File]::SetLastWriteTimeUtc($path, $stamp)
    return $path
}

function New-TestResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory typed result.')]
    param(
        [string]$FailureClass = 'bootstrap_sync',
        [string]$Stage = 'FrameworkPull',
        [string]$Reason = "fatal: Unable to create '.git/index.lock': File exists."
    )
    return (New-RecoveryResult -EntryPoint 'runner' -CycleGeneration (('a' * 32) + ':4') -Outcome 'failed' -ExitCode 1 -FailureClass $FailureClass -Stage $Stage -Reason $Reason)
}

function Get-LedgerPhase {
    param([Parameter(Mandatory)][string]$Dir)
    return @((Read-RecoveryLedger -RuntimeDir $Dir).Records | Where-Object { $_.kind -eq 'attempt' } | ForEach-Object { [string]$_.phase })
}

function Get-LedgerRecord {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Phase
    )
    # The leading comma keeps a single match an array, so callers can index it with [0].
    return , @((Read-RecoveryLedger -RuntimeDir $Dir).Records | Where-Object { $_.kind -eq 'attempt' -and $_.phase -eq $Phase })
}

function New-LockFixture {
    # A framework checkout with a project checkout inside it, a runtime directory,
    # and stand-ins for the two probes that record what they were asked.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates temporary directories that AfterEach removes.')]
    param(
        [Parameter(Mandatory)][string]$Base,
        [int]$StatusExit = 0
    )
    $framework = Join-Path $Base 'fw'
    $project = Join-Path $framework 'project'
    $runtime = Join-Path $Base 'runtime'
    Initialize-TestRepo -Path $framework
    Initialize-TestRepo -Path $project
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $log = [System.Collections.Generic.List[string]]::new()
    $exitCode = $StatusExit
    $context = @{
        RepoRoot        = $framework
        ProjectDir      = $project
        ProjectUrl      = ''
        ConfigPath      = (Join-Path $Base 'test.config.yml')
        RuntimeDir      = $runtime
        Log             = $log
        GitProcessProbe = { $log.Add('process-probe'); $false }.GetNewClosure()
        GitStatusProbe  = { param($RepoPath) $log.Add("status:$RepoPath"); @{ ExitCode = $exitCode; Output = $(if ($exitCode -ne 0) { 'fatal: broken' } else { '' }) } }.GetNewClosure()
    }
    return [pscustomobject]@{ Framework = $framework; Project = $project; Runtime = $runtime; Context = $context; Log = $log }
}

function New-CloneFixture {
    # A runtime directory and stand-ins for the clone, the health check and the
    # swap recovery. Health answers come from a queue: the precondition reads the
    # first, the postcondition the second.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates temporary directories that AfterEach removes.')]
    param(
        [Parameter(Mandatory)][string]$Base,
        [bool[]]$Health = @($false, $true),
        [string]$CloneBehavior = 'ok',
        [string]$ProjectUrl = 'https://example.invalid/org/project.git',
        [string[]]$RestoreActions = @()
    )
    $framework = Join-Path $Base 'fw'
    $runtime = Join-Path $Base 'runtime'
    New-Item -ItemType Directory -Path (Join-Path $framework 'project'), $runtime -Force | Out-Null
    $log = [System.Collections.Generic.List[string]]::new()
    $queue = @{ Index = 0 }
    $verdicts = @($Health)
    $behavior = $CloneBehavior
    $restored = @($RestoreActions)
    $context = @{
        RepoRoot                = $framework
        ProjectDir              = (Join-Path $framework 'project')
        ProjectUrl              = $ProjectUrl
        ConfigPath              = (Join-Path $Base 'test.config.yml')
        RuntimeDir              = $runtime
        Log                     = $log
        TestProjectCloneHealth  = {
            param($Path)
            $verdict = $verdicts[[math]::Min($queue.Index, $verdicts.Count - 1)]
            $queue.Index++
            $log.Add("health:$Path")
            [pscustomobject]@{ Healthy = $verdict; Revision = 'abc123'; Reason = $(if ($verdict) { '' } else { 'HEAD does not resolve to a commit' }) }
        }.GetNewClosure()
        UpdateProjectClone      = {
            param($RepoRoot, $ProjectUrl)
            $log.Add("update:$RepoRoot|$ProjectUrl")
            switch ($behavior) {
                'throw' { throw 'network is unreachable' }
                'nothing' { return }
                'fail' { return @{ success = $false; skipped = $false; errorMessage = "git clone failed (exit 128): fatal: unable to access 'https://deploy:s3cr3tPass@example.invalid/org/project.git/'"; revision = $null } }
                default { return @{ success = $true; skipped = $false; errorMessage = $null; revision = 'abc123def456' } }
            }
        }.GetNewClosure()
        RestoreProjectCloneSwap = { param($RepoRoot) $log.Add("restore:$RepoRoot"); return @($restored) }.GetNewClosure()
    }
    return [pscustomobject]@{ Framework = $framework; Runtime = $runtime; Context = $context; Log = $log }
}

function Register-ToyAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: registers an in-memory action.')]
    param(
        [string]$Name = 'toy_action',
        [scriptblock]$Precondition = { param($c) $c.Calls.Add('precondition'); @{ Ok = $true; Reason = 'go'; Evidence = @() } },
        [scriptblock]$Action = { param($c) $c.Calls.Add('action'); @{ Ok = $true; Reason = 'did-it'; Evidence = @() } },
        [scriptblock]$Postcondition = { param($c) $c.Calls.Add('postcondition'); @{ Ok = $true; Reason = 'verified'; Evidence = @() } },
        [scriptblock]$Rollback,
        [int]$PostconditionRetries = 0,
        [int]$PostconditionDelaySeconds = 0,
        [bool]$SkipsFailurePause = $false
    )
    $splat = @{
        Name = $Name; Description = 'toy'; Applies = { $true }; Precondition = $Precondition; Action = $Action
        Postcondition = $Postcondition; PostconditionRetries = $PostconditionRetries
        PostconditionDelaySeconds = $PostconditionDelaySeconds; SkipsFailurePause = $SkipsFailurePause
    }
    if ($Rollback) { $splat['Rollback'] = $Rollback }
    Register-RecoveryAction @splat
}
}

AfterAll {
    foreach ($name in $script:GitEnvNames) { [Environment]::SetEnvironmentVariable($name, $script:SavedGitEnv[$name]) }
    Remove-Item -LiteralPath $script:EmptyGitConfig -Force -ErrorAction SilentlyContinue
    Clear-RecoveryAction
    Register-BuiltinRecoveryAction
}

Describe 'Built-in registration' {
    It 'registers exactly the three repairs, in the order they should be tried, when the module loads' {
        @(Get-RegisteredRecoveryAction) | Should -Be @('clear_stale_git_lock', 'reclone_project', 'end_failure_pause_early')
    }

    It 'registers them again, without duplicates, when asked or when the module is imported again' {
        Register-BuiltinRecoveryAction
        Register-BuiltinRecoveryAction
        @(Get-RegisteredRecoveryAction) | Should -Be @('clear_stale_git_lock', 'reclone_project', 'end_failure_pause_early')
        Import-Module (Join-Path $here 'Test.RecoveryActions.psm1') -Force -DisableNameChecking
        @(Get-RegisteredRecoveryAction) | Should -Be @('clear_stale_git_lock', 'reclone_project', 'end_failure_pause_early')
    }

    It 'describes each repair, lets all three skip the pause, and caps the git repairs at two attempts' {
        foreach ($name in 'clear_stale_git_lock', 'reclone_project', 'end_failure_pause_early') {
            $entry = Get-RecoveryAction -Name $name
            $entry.Description | Should -Not -BeNullOrEmpty
            $entry.SkipsFailurePause | Should -BeTrue
        }
        (Get-RecoveryAction -Name 'clear_stale_git_lock').MaxAttempts | Should -Be 2
        (Get-RecoveryAction -Name 'reclone_project').MaxAttempts | Should -Be 2
        (Get-RecoveryAction -Name 'end_failure_pause_early').MaxAttempts | Should -Be 0 -Because 'the configured budget applies unchanged'
    }

    It 'exports the lock finder and the process check besides the registration function' {
        $exports = @((Get-Module Test.RecoveryActions).ExportedFunctions.Keys | Sort-Object)
        $exports | Should -Be @('Find-StaleGitLock', 'Register-BuiltinRecoveryAction', 'Test-GitProcessRunning')
    }
}

Describe 'Repair protocol' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = [datetime]::new(2026, 10, 4, 12, 0, 0, [DateTimeKind]::Utc)
        Clear-RecoveryAction
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $script:Ctx = @{ Result = $script:Result; Calls = $script:Calls; Counter = @{ N = 0 }; Seen = @{} }
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'declines when the precondition says no: nothing runs, and no attempt is spent' {
        Register-ToyAction -Precondition {
            param($c)
            $c.Calls.Add('precondition')
            @{ Ok = $false; Reason = 'not-now'; Evidence = @([ordered]@{ kind = 'record'; ref = 'why'; note = 'busy' }) }
        }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'declined'
        $out.RecoveryState | Should -Be 'declined'
        $out.Reason | Should -Be 'not-now'
        $out.Attempt | Should -Be 0
        $out.SkipFailurePause | Should -BeFalse
        @($out.Evidence | ForEach-Object { $_.ref }) | Should -Be @('why')
        @($script:Calls) | Should -Be @('precondition')
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('declined')
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:Result.fingerprint -Action 'toy_action' -Now $script:Now).Used | Should -Be 0
    }

    It 'gives a decline with no reason a reason of its own' {
        Register-ToyAction -Precondition { @{ Ok = $false } }
        (Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).Reason | Should -Be 'precondition-declined'
    }

    It 'treats a precondition that throws as a decline, never as an unhandled error' {
        Register-ToyAction -Precondition { throw 'precondition kaboom' }
        { $script:Out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now } | Should -Not -Throw
        $script:Out.Decision | Should -Be 'declined'
        $script:Out.Reason | Should -Match '^precondition-threw: precondition kaboom'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('declined')
    }

    It 'treats a precondition that answers nothing as a decline' {
        Register-ToyAction -Precondition { }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'no-result'
    }

    It 'finds the result among stray output, and accepts a result object that is not a hashtable' {
        Register-ToyAction `
            -Precondition { 'a stray line'; [pscustomobject]@{ Ok = $true; Reason = 'go'; Evidence = @() } } `
            -Action { 1; 2; @{ Ok = $true; Reason = 'did-it'; Evidence = @() } } `
            -Postcondition { Write-Output 'noise'; @{ Ok = $true; Reason = 'verified'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $out.Reason | Should -Be 'verified'
    }

    It 'treats an Ok that is not a boolean $true as not ok' {
        Register-ToyAction -Precondition { @{ Ok = 'True'; Reason = 'stringly' } }
        (Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).Decision | Should -Be 'declined'
    }

    It 'applies when every step is ok: started, then succeeded' {
        Register-ToyAction -SkipsFailurePause $true
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $out.RecoveryState | Should -Be 'applied'
        $out.Action | Should -Be 'toy_action'
        $out.Attempt | Should -Be 1
        $out.AttemptId | Should -Match '^[0-9a-f]{32}$'
        $out.Reason | Should -Be 'verified'
        $out.SkipFailurePause | Should -BeTrue
        @($script:Calls) | Should -Be @('precondition', 'action', 'postcondition')
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'succeeded')
    }

    It 'does not report a pause skip for an action that did not ask for one' {
        Register-ToyAction
        (Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).SkipFailurePause | Should -BeFalse
    }

    It 'fails when the action throws, skips the postcondition, and escalates' {
        Register-ToyAction -Action { param($c) $c.Calls.Add('action'); throw 'action kaboom' }
        { $script:Out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now } | Should -Not -Throw
        $script:Out.Decision | Should -Be 'failed'
        $script:Out.RecoveryState | Should -Be 'failed'
        $script:Out.Reason | Should -Match '^action-threw: action kaboom'
        $script:Out.SkipFailurePause | Should -BeFalse
        $script:Out.Attempt | Should -Be 1
        @($script:Calls) | Should -Be @('precondition', 'action')
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'failed', 'escalated')
    }

    It 'fails with the action''s own reason when the action says it could not do it' {
        Register-ToyAction -Action { param($c) $c.Calls.Add('action'); @{ Ok = $false; Reason = 'cannot-do-it'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Be 'cannot-do-it'
        @($script:Calls) | Should -Not -Contain 'postcondition'
        (Get-LedgerRecord -Dir $script:Dir -Phase 'failed')[0].reason | Should -Be 'cannot-do-it'
    }

    It 'names the failure when an action says no without a reason, or answers nothing' {
        Register-ToyAction -Name 'no_reason' -Action { @{ Ok = $false } }
        Register-ToyAction -Name 'no_answer' -Action { }
        (Invoke-RecoveryAction -Name 'no_reason' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).Reason | Should -Be 'action-failed'
        (Invoke-RecoveryAction -Name 'no_answer' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).Reason | Should -Be 'no-result'
    }

    It 'rolls back when the postcondition fails, handing the rollback the action''s own result' {
        Register-ToyAction `
            -Action { param($c) $c.Calls.Add('action'); @{ Ok = $true; Reason = 'did-it'; Evidence = @(); Marker = 'from-the-action' } } `
            -Postcondition { param($c) $c.Calls.Add('postcondition'); @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } } `
            -Rollback { param($c, $actionResult) $c.Calls.Add('rollback'); $c.Seen['Marker'] = $actionResult.Marker; @{ Ok = $true; Reason = 'undone'; Evidence = @([ordered]@{ kind = 'record'; ref = 'rb'; note = '' }) } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Be 'still-broken'
        @($script:Calls) | Should -Be @('precondition', 'action', 'postcondition', 'rollback')
        $script:Ctx.Seen.Marker | Should -Be 'from-the-action'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
        (Get-LedgerRecord -Dir $script:Dir -Phase 'rolled-back')[0].reason | Should -Be 'undone'
        @($out.Evidence | ForEach-Object { $_.ref }) | Should -Contain 'rb'
    }

    It 'rolls back when the action itself fails, so a half-done action is undone' {
        Register-ToyAction `
            -Action { param($c) $c.Calls.Add('action'); throw 'half way' } `
            -Rollback { param($c, $actionResult) $c.Calls.Add('rollback'); $c.Seen['Reason'] = $actionResult.Reason; @{ Ok = $true; Reason = 'undone'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        @($script:Calls) | Should -Be @('precondition', 'action', 'rollback')
        $script:Ctx.Seen.Reason | Should -Match '^action-threw: half way'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
    }

    It 'records a rollback that fails: rollback-failed, then failed, then escalated' {
        Register-ToyAction `
            -Postcondition { @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } } `
            -Rollback { @{ Ok = $false; Reason = 'could-not-undo'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Be 'still-broken' -Because 'the result names the step that failed first'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'rollback-failed', 'failed', 'escalated')
        (Get-LedgerRecord -Dir $script:Dir -Phase 'rollback-failed')[0].reason | Should -Be 'could-not-undo'
    }

    It 'records a rollback that throws the same way' {
        Register-ToyAction `
            -Postcondition { @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } } `
            -Rollback { throw 'rollback kaboom' }
        { $script:Out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now } | Should -Not -Throw
        $script:Out.Decision | Should -Be 'failed'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'rollback-failed', 'failed', 'escalated')
        (Get-LedgerRecord -Dir $script:Dir -Phase 'rollback-failed')[0].reason | Should -Match '^rollback-threw: rollback kaboom'
    }

    It 'goes straight from started to failed to escalated when no rollback is registered' {
        Register-ToyAction -Postcondition { @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } }
        Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'failed', 'escalated')
    }

    It 'treats a postcondition that throws as a failed postcondition' {
        Register-ToyAction -Postcondition { throw 'probe kaboom' } -Rollback { @{ Ok = $true; Reason = 'undone'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Match '^postcondition-threw: probe kaboom'
    }

    It 'names the failure when a postcondition says no without a reason' {
        Register-ToyAction -Postcondition { @{ Ok = $false } }
        (Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now).Reason | Should -Be 'postcondition-failed'
    }

    It 'asks the postcondition again as often as it was registered to, and applies once it holds' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        Register-ToyAction -PostconditionRetries 2 -PostconditionDelaySeconds 3 -Postcondition {
            param($c)
            $c.Counter.N++
            $c.Calls.Add('postcondition')
            @{ Ok = ($c.Counter.N -ge 3); Reason = 'settled'; Evidence = @() }
        }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        @($script:Calls | Where-Object { $_ -eq 'postcondition' }).Count | Should -Be 3
        Should -Invoke -CommandName Start-Sleep -ModuleName Test.RecoveryLedger -Times 2 -Exactly -ParameterFilter { $Seconds -eq 3 }
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'succeeded')
    }

    It 'gives up after the registered number of retries and rolls back' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        Register-ToyAction -PostconditionRetries 1 -Postcondition {
            param($c)
            $c.Calls.Add('postcondition')
            @{ Ok = $false; Reason = 'still-broken'; Evidence = @() }
        } -Rollback { @{ Ok = $true; Reason = 'undone'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'failed'
        @($script:Calls | Where-Object { $_ -eq 'postcondition' }).Count | Should -Be 2
        Should -Invoke -CommandName Start-Sleep -ModuleName Test.RecoveryLedger -Times 0 -Exactly -ParameterFilter { $Seconds -gt 0 } -Because 'no delay was registered'
    }

    It 'evaluates a failing postcondition once when no retries were registered' {
        Register-ToyAction -Postcondition {
            param($c)
            $c.Calls.Add('postcondition')
            @{ Ok = $false; Reason = 'still-broken'; Evidence = @() }
        }
        Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        @($script:Calls | Where-Object { $_ -eq 'postcondition' }).Count | Should -Be 1
    }

    It 'counts a failed attempt as used, and stops running the action when the budget is spent' {
        Register-ToyAction -Postcondition { @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } }
        $decisions = foreach ($minute in 0..2) {
            (Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now.AddMinutes($minute)).Decision
        }
        @($decisions) | Should -Be @('failed', 'failed', 'exhausted')
        @($script:Calls | Where-Object { $_ -eq 'action' }).Count | Should -Be 2
    }

    It 'redacts a credential in the exception text before it reaches the result and the ledger' {
        Register-ToyAction -Action { throw 'clone of https://deploy:s3cr3tPass@example.invalid/org/repo.git failed' }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $script:Ctx -RuntimeDir $script:Dir -Now $script:Now
        $out.Reason | Should -Not -Match 's3cr3tPass'
        [System.IO.File]::ReadAllText((Get-RecoveryLedgerPath -RuntimeDir $script:Dir)) | Should -Not -Match 's3cr3tPass'
    }
}

Describe 'Finding stale git locks' {
    BeforeEach {
        $script:Base = New-ScratchDir
        $script:Repo = Join-Path $script:Base 'repo'
        Initialize-TestRepo -Path $script:Repo
        $script:Now = [datetime]::new(2026, 10, 4, 12, 0, 0, [DateTimeKind]::Utc)
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ignores a lock younger than the minimum age and reports an older one' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -At $script:Now.AddMinutes(-2) | Out-Null
        Add-LockFile -RepoPath $script:Repo -Relative '.git/HEAD.lock' -At $script:Now.AddMinutes(-30) | Out-Null
        $found = @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now)
        $found.Count | Should -Be 1
        $found[0].RelativePath | Should -Be '.git/HEAD.lock'
        $found[0].AgeMinutes | Should -Be 30
        $found[0].Path | Should -Be (Join-Path (Join-Path $script:Repo '.git') 'HEAD.lock')
    }

    It 'reports a lock only once it is strictly older than the minimum' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -At $script:Now.AddMinutes(-10) | Out-Null
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now).Count | Should -Be 0
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -At $script:Now.AddMinutes(-10).AddSeconds(-1) | Out-Null
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now).Count | Should -Be 1
    }

    It 'honors the minimum age it is given' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -At $script:Now.AddMinutes(-30) | Out-Null
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now -MinAgeMinutes 60).Count | Should -Be 0
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now -MinAgeMinutes 5).Count | Should -Be 1
    }

    It 'uses the current time when none is given' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -MinutesOld 45 | Out-Null
        $found = @(Find-StaleGitLock -RepoPath $script:Repo)
        $found.Count | Should -Be 1
        $found[0].AgeMinutes | Should -BeGreaterThan 44
        $found[0].AgeMinutes | Should -BeLessThan 47
    }

    It 'finds the locks git keeps directly in .git' {
        foreach ($name in 'index.lock', 'HEAD.lock', 'packed-refs.lock', 'shallow.lock', 'config.lock') {
            Add-LockFile -RepoPath $script:Repo -Relative ".git/$name" -At $script:Now.AddHours(-1) | Out-Null
        }
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now | ForEach-Object { $_.RelativePath }) |
            Should -Be @('.git/config.lock', '.git/HEAD.lock', '.git/index.lock', '.git/packed-refs.lock', '.git/shallow.lock')
    }

    It 'finds the locks of refs, nested branch names included, down to three directory levels' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/refs/heads/main.lock' -At $script:Now.AddHours(-1) | Out-Null
        Add-LockFile -RepoPath $script:Repo -Relative '.git/refs/heads/feature/topic.lock' -At $script:Now.AddHours(-1) | Out-Null
        Add-LockFile -RepoPath $script:Repo -Relative '.git/refs/heads/a/b/three.lock' -At $script:Now.AddHours(-1) | Out-Null
        Add-LockFile -RepoPath $script:Repo -Relative '.git/refs/heads/a/b/c/four.lock' -At $script:Now.AddHours(-1) | Out-Null
        $found = @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now | ForEach-Object { $_.RelativePath })
        $found | Should -Contain '.git/refs/heads/main.lock'
        $found | Should -Contain '.git/refs/heads/feature/topic.lock'
        $found | Should -Contain '.git/refs/heads/a/b/three.lock'
        $found | Should -Not -Contain '.git/refs/heads/a/b/c/four.lock'
    }

    It 'ignores everything that is not a regular *.lock file' {
        $old = $script:Now.AddHours(-1)
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.git/looks.lock') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Repo '.git/refs/heads/dir.lock') -Force | Out-Null
        foreach ($name in 'index', 'lock', 'index.lock.bak', 'index.locked', 'notes.txt') {
            Add-LockFile -RepoPath $script:Repo -Relative ".git/$name" -At $old | Out-Null
        }
        Add-LockFile -RepoPath $script:Repo -Relative '.git/objects/pack/tmp.lock' -At $old | Out-Null
        Add-LockFile -RepoPath $script:Repo -Relative 'working-tree.lock' -At $old | Out-Null
        @(Find-StaleGitLock -RepoPath $script:Repo -Now $script:Now).Count | Should -Be 0
    }

    It 'returns nothing for a worktree pointer, a plain directory and a path that does not exist' {
        $pointer = Join-Path $script:Base 'linked'
        New-Item -ItemType Directory -Path $pointer -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $pointer '.git'), 'gitdir: ../repo/.git/worktrees/linked')
        Add-LockFile -RepoPath $pointer -Relative 'index.lock' -At $script:Now.AddHours(-1) | Out-Null
        @(Find-StaleGitLock -RepoPath $pointer -Now $script:Now).Count | Should -Be 0

        $plain = Join-Path $script:Base 'plain'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        @(Find-StaleGitLock -RepoPath $plain -Now $script:Now).Count | Should -Be 0
        { Find-StaleGitLock -RepoPath (Join-Path $script:Base 'absent') -Now $script:Now } | Should -Not -Throw
        @(Find-StaleGitLock -RepoPath (Join-Path $script:Base 'absent') -Now $script:Now).Count | Should -Be 0
    }

    It 'reports a path relative to the repository whatever form the repository path takes' {
        Add-LockFile -RepoPath $script:Repo -Relative '.git/index.lock' -At $script:Now.AddHours(-1) | Out-Null
        $messy = $script:Repo + [System.IO.Path]::DirectorySeparatorChar
        @(Find-StaleGitLock -RepoPath $messy -Now $script:Now)[0].RelativePath | Should -Be '.git/index.lock'
    }
}

Describe 'Seeing whether git is running' {
    It 'answers true when a git process is listed' {
        Mock -ModuleName Test.RecoveryActions Get-RecoveryGitProcess { @([pscustomobject]@{ Id = 4242 }) }
        Test-GitProcessRunning | Should -BeTrue
    }

    It 'answers false when none is' {
        Mock -ModuleName Test.RecoveryActions Get-RecoveryGitProcess { @() }
        Test-GitProcessRunning | Should -BeFalse
    }

    It 'answers true, not false, when the process list cannot be read' {
        Mock -ModuleName Test.RecoveryActions Get-RecoveryGitProcess { throw 'access denied' }
        Test-GitProcessRunning | Should -BeTrue
    }

    It 'answers with a boolean against the real process table' {
        Test-GitProcessRunning | Should -BeOfType [bool]
    }
}

Describe 'clear_stale_git_lock' {
    BeforeEach {
        $script:Base = New-ScratchDir
        $script:Fx = New-LockFixture -Base $script:Base
        $script:Now = [datetime]::UtcNow
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
        $script:Result = New-TestResult
    }
    AfterEach {
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'moves an old lock into the quarantine of the attempt, keeping its label, path and content' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 45 -Content 'pid 777'
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $script:Fx.Context) -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'applied'
        $out.RecoveryState | Should -Be 'applied'
        $out.SkipFailurePause | Should -BeTrue
        $out.Attempt | Should -Be 1
        $out.Reason | Should -Be 'git-status-ok'
        Test-Path -LiteralPath $lock | Should -BeFalse
        $kept = Join-Path $script:Fx.Runtime "recovery.quarantine/$($out.AttemptId)/framework/.git/index.lock"
        Test-Path -LiteralPath $kept -PathType Leaf | Should -BeTrue -Because 'a lock is moved, never deleted'
        [System.IO.File]::ReadAllText($kept) | Should -Be 'pid 777'
        Get-LedgerPhase -Dir $script:Fx.Runtime | Should -Be @('started', 'succeeded')
        @($script:Fx.Log | Where-Object { $_ -like 'status:*' }) | Should -Be @("status:$($script:Fx.Framework)")
    }

    It 'reaches both repositories and keeps the label and relative path of each lock' {
        Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30 | Out-Null
        Add-LockFile -RepoPath $script:Fx.Project -Relative '.git/refs/heads/feature/topic.lock' -MinutesOld 30 | Out-Null
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $script:Fx.Context) -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'applied'
        $root = Join-Path $script:Fx.Runtime "recovery.quarantine/$($out.AttemptId)"
        Test-Path -LiteralPath (Join-Path $root 'framework/.git/index.lock') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'project/.git/refs/heads/feature/topic.lock') | Should -BeTrue
        @($script:Fx.Log | Where-Object { $_ -like 'status:*' } | Sort-Object) | Should -Be @(@("status:$($script:Fx.Framework)", "status:$($script:Fx.Project)") | Sort-Object)
        @($out.Evidence | Where-Object { $_.kind -eq 'file' }).Count | Should -BeGreaterOrEqual 2
    }

    It 'leaves a lock younger than ten minutes, and declines when no old lock exists' {
        $young = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 3
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $script:Fx.Context) -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'no-stale-lock'
        Test-Path -LiteralPath $young | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Fx.Runtime 'recovery.quarantine') | Should -BeFalse
        Get-LedgerPhase -Dir $script:Fx.Runtime | Should -Be @('declined')
        $script:Fx.Log | Should -Not -Contain 'process-probe' -Because 'with no lock to move, whether git runs does not matter'
    }

    It 'moves only the old locks when old and young ones sit side by side' {
        $old = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $young = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/HEAD.lock' -MinutesOld 2
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $script:Fx.Context) -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'applied'
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $young | Should -BeTrue
    }

    It 'declines while a git process is running, and touches nothing' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitProcessProbe'] = { $true }
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'git-process-running'
        Test-Path -LiteralPath $lock | Should -BeTrue
        @($out.Evidence | Where-Object { $_.kind -eq 'file' }).Count | Should -Be 1 -Because 'the decline says which lock it held back'
        Get-LedgerPhase -Dir $script:Fx.Runtime | Should -Be @('declined')
    }

    It 'reads a process probe that answers nothing as git running' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitProcessProbe'] = { }
        (Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime).Reason | Should -Be 'git-process-running'
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'declines, rather than fails, when the process probe throws' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitProcessProbe'] = { throw 'cannot list processes' }
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Match '^precondition-threw: cannot list processes'
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'consults the real process table when no probe is supplied' {
        Mock -ModuleName Test.RecoveryActions Get-RecoveryGitProcess { @([pscustomobject]@{ Id = 1 }) }
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context.Remove('GitProcessProbe')
        (Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime).Reason | Should -Be 'git-process-running'
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'puts the lock back and fails when git still does not work afterwards' {
        $fx = New-LockFixture -Base (New-ScratchDir) -StatusExit 128
        try {
            $lock = Add-LockFile -RepoPath $fx.Framework -Relative '.git/index.lock' -MinutesOld 30 -Content 'pid 888'
            $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
            $out.Decision | Should -Be 'failed'
            $out.Reason | Should -Be 'git-status-failed'
            $out.SkipFailurePause | Should -BeFalse
            Test-Path -LiteralPath $lock | Should -BeTrue -Because 'the rollback moves the quarantined lock back'
            [System.IO.File]::ReadAllText($lock) | Should -Be 'pid 888'
            Test-Path -LiteralPath (Join-Path $fx.Runtime "recovery.quarantine/$($out.AttemptId)") | Should -BeFalse -Because 'the quarantine copy goes only after a successful rollback'
            Get-LedgerPhase -Dir $fx.Runtime | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $fx.Framework) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'puts back the locks of every repository when git fails in only one of them' {
        $locks = @(
            (Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30),
            (Add-LockFile -RepoPath $script:Fx.Project -Relative '.git/index.lock' -MinutesOld 30)
        )
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $project = $script:Fx.Project
        $context['GitStatusProbe'] = { param($RepoPath) @{ ExitCode = $(if ($RepoPath -eq $project) { 128 } else { 0 }); Output = '' } }.GetNewClosure()
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'failed'
        foreach ($lock in $locks) { Test-Path -LiteralPath $lock | Should -BeTrue }
    }

    It 'counts a status probe that answers nothing as a failure' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitStatusProbe'] = { }
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Be 'git-status-failed'
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'never overwrites a lock that has reappeared: the rollback fails and the quarantined copy stays' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30 -Content 'old holder'
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitStatusProbe'] = {
            param($RepoPath)
            [System.IO.File]::WriteAllText((Join-Path $RepoPath '.git/index.lock'), 'new holder')
            @{ ExitCode = 128; Output = 'fatal' }
        }
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'failed'
        [System.IO.File]::ReadAllText($lock) | Should -Be 'new holder'
        $kept = Join-Path $script:Fx.Runtime "recovery.quarantine/$($out.AttemptId)/framework/.git/index.lock"
        [System.IO.File]::ReadAllText($kept) | Should -Be 'old holder'
        Get-LedgerPhase -Dir $script:Fx.Runtime | Should -Be @('started', 'rollback-failed', 'failed', 'escalated')
        (Get-LedgerRecord -Dir $script:Fx.Runtime -Phase 'rollback-failed')[0].reason | Should -Be 'rollback-target-exists'
    }

    It 'restores what it had already moved when the action stops half way' {
        $head = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/HEAD.lock' -MinutesOld 30
        $index = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        Mock -ModuleName Test.RecoveryActions Move-Item { throw 'being used by another process' } -ParameterFilter { "$LiteralPath" -like '*index.lock' -and "$Destination" -like '*recovery.quarantine*' }
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context (@{ Result = $script:Result } + $script:Fx.Context) -RuntimeDir $script:Fx.Runtime
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Match '^action-threw: being used by another process'
        Test-Path -LiteralPath $head | Should -BeTrue -Because 'the lock that was moved first is back'
        Test-Path -LiteralPath $index | Should -BeTrue
        Get-LedgerPhase -Dir $script:Fx.Runtime | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
    }

    It 'does not run a second time on the same failure once its two attempts are used' {
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitStatusProbe'] = { @{ ExitCode = 128; Output = 'fatal' } }
        $decisions = foreach ($i in 1..3) {
            Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30 | Out-Null
            (Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime).Decision
        }
        @($decisions) | Should -Be @('failed', 'failed', 'exhausted')
    }

    It 'clears a lock with the real bounded git status when no probe is supplied, in a path with a space' -Skip:(-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
        $fx = New-LockFixture -Base (Join-Path $script:Base 'with space')
        $lock = Add-LockFile -RepoPath $fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $fx.Context
        $context.Remove('GitStatusProbe')
        $out = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'applied'
        $out.Reason | Should -Be 'git-status-ok'
        Test-Path -LiteralPath $lock | Should -BeFalse
        @($out.Evidence | Where-Object { $_.kind -eq 'command' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'reads an exit code that the probe gives as text' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $context['GitStatusProbe'] = { @{ ExitCode = '0'; Output = '' } }
        (Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime).Decision | Should -Be 'applied'
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'measures lock ages against the time the invocation was pinned to' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 1
        $context = @{ Result = $script:Result } + $script:Fx.Context
        $early = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime -Now ([datetime]::UtcNow.AddMinutes(-30))
        $early.Decision | Should -Be 'declined'
        Test-Path -LiteralPath $lock | Should -BeTrue
        $late = Invoke-RecoveryAction -Name 'clear_stale_git_lock' -Context $context -RuntimeDir $script:Fx.Runtime -Now ([datetime]::UtcNow.AddMinutes(60))
        $late.Decision | Should -Be 'applied'
        Test-Path -LiteralPath $lock | Should -BeFalse
    }

    It 'stops the plan at the lock repair, so the project is not cloned over a checkout it just repaired' {
        $projectResult = New-TestResult -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' -Reason "fatal: Unable to create '.git/index.lock': File exists."
        $log = $script:Fx.Log
        $context = $script:Fx.Context.Clone()
        $context['ProjectUrl'] = 'https://example.invalid/org/project.git'
        $context['TestProjectCloneHealth'] = { param($Path) $log.Add("health:$Path"); [pscustomobject]@{ Healthy = $false; Reason = 'missing' } }.GetNewClosure()
        $context['UpdateProjectClone'] = { param($RepoRoot, $ProjectUrl) $log.Add("update:$RepoRoot|$ProjectUrl"); @{ success = $true; skipped = $false; errorMessage = $null; revision = 'abc' } }.GetNewClosure()
        $lock = Add-LockFile -RepoPath $script:Fx.Project -Relative '.git/index.lock' -MinutesOld 30
        $out = Invoke-RecoveryForResult -Result $projectResult -Context $context -RuntimeDir $script:Fx.Runtime -Enabled $true
        @($out.Advised) | Should -Be @('clear_stale_git_lock', 'reclone_project')
        $out.Action | Should -Be 'clear_stale_git_lock'
        $out.Decision | Should -Be 'applied'
        @($out.Decisions).Count | Should -Be 1
        Test-Path -LiteralPath $lock | Should -BeFalse
        @($script:Fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 0
    }

    It 'also works through the planner for a pull that failed on a lock' {
        $lock = Add-LockFile -RepoPath $script:Fx.Framework -Relative '.git/index.lock' -MinutesOld 30
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Fx.Context -RuntimeDir $script:Fx.Runtime -Enabled $true
        $out.Decision | Should -Be 'applied'
        $out.Action | Should -Be 'clear_stale_git_lock'
        $out.SkipFailurePause | Should -BeTrue
        @($out.Advised) | Should -Be @('clear_stale_git_lock')
        Test-Path -LiteralPath $lock | Should -BeFalse
    }
}

Describe 'The bounded git status' {
    BeforeEach {
        $script:Base = New-ScratchDir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'answers zero for a repository and non-zero for a directory that is not one' -Skip:(-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
        $repo = Join-Path $script:Base 'repo'
        Initialize-TestRepo -Path $repo
        $plain = Join-Path $script:Base 'plain'
        New-Item -ItemType Directory -Path $plain | Out-Null
        (InModuleScope Test.RecoveryActions -Parameters @{ P = $repo } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }).ExitCode | Should -Be 0
        $bad = InModuleScope Test.RecoveryActions -Parameters @{ P = $plain } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }
        $bad.ExitCode | Should -Not -Be 0
        $bad.Output | Should -Not -BeNullOrEmpty
    }

    It 'does not write the index, so the probe cannot race the next git or recreate a lock' -Skip:(-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
        $repo = Join-Path $script:Base 'repo'
        Initialize-TestRepo -Path $repo
        $tracked = Join-Path $repo 'tracked.txt'
        [System.IO.File]::WriteAllText($tracked, 'content')
        & git -C $repo add tracked.txt 2>&1 | Out-Null
        & git -C $repo -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m tracked 2>&1 | Out-Null
        # Same content, different timestamp: a status that is allowed to write
        # refreshes the index entry and rewrites the file.
        [System.IO.File]::SetLastWriteTimeUtc($tracked, [datetime]::UtcNow.AddMinutes(30))
        $index = Join-Path $repo '.git/index'
        $before = (Get-FileHash -LiteralPath $index).Hash

        $savedOptionalLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', 'Process')
        try {
            $env:GIT_OPTIONAL_LOCKS = '1'
            $probe = InModuleScope Test.RecoveryActions -Parameters @{ P = $repo } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }
            $probe.ExitCode | Should -Be 0
            (Get-FileHash -LiteralPath $index).Hash | Should -Be $before
            Test-Path -LiteralPath (Join-Path $repo '.git/index.lock') | Should -BeFalse

            & git -C $repo status --porcelain 2>&1 | Out-Null
            (Get-FileHash -LiteralPath $index).Hash | Should -Not -Be $before -Because 'the control: an ordinary status does rewrite the index here'
        } finally {
            if ($null -eq $savedOptionalLocks) {
                Remove-Item -LiteralPath Env:GIT_OPTIONAL_LOCKS
            } else {
                [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $savedOptionalLocks, 'Process')
            }
        }
    }

    It 'reports a missing git as -1 rather than throwing' {
        $emptyBin = Join-Path $script:Base 'bin'
        New-Item -ItemType Directory -Path $emptyBin | Out-Null
        $savedPath = $env:PATH
        try {
            $env:PATH = $emptyBin
            $result = InModuleScope Test.RecoveryActions -Parameters @{ P = $script:Base } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }
        } finally {
            $env:PATH = $savedPath
        }
        $result.ExitCode | Should -Be -1
        $result.Output | Should -Be 'git is missing'
    }

    It 'never waits on the output pipes with the parameterless WaitForExit' {
        $source = Get-Content -LiteralPath (Join-Path $here 'Test.RecoveryActions.psm1') -Raw
        $source | Should -Not -Match '\.WaitForExit\(\s*\)'
        $source | Should -Match '\.WaitForExit\(\$TimeoutSeconds \* 1000\)'
    }

    Context 'with a stand-in git that misbehaves' -Skip:(-not $IsWindows) {
        BeforeEach {
            $script:Bin = Join-Path $script:Base 'bin'
            New-Item -ItemType Directory -Path $script:Bin | Out-Null
            $script:SavedPath = $env:PATH
            $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $env:PATH
        }
        AfterEach {
            $env:PATH = $script:SavedPath
        }

        It 'kills a status that outlasts the bound and reports 124' {
            [System.IO.File]::WriteAllText((Join-Path $script:Bin 'git.cmd'), "@echo off`r`nping -n 31 127.0.0.1 > nul`r`n")
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $result = InModuleScope Test.RecoveryActions -Parameters @{ P = $script:Base } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P -TimeoutSeconds 1 }
            $clock.Stop()
            $result.ExitCode | Should -Be 124
            $result.Output | Should -Match 'did not finish'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        }

        It 'carries the exit code and the text of a status that fails' {
            [System.IO.File]::WriteAllText((Join-Path $script:Bin 'git.cmd'), "@echo off`r`necho fatal: not a git repository 1>&2`r`nexit /b 7`r`n")
            $result = InModuleScope Test.RecoveryActions -Parameters @{ P = $script:Base } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }
            $result.ExitCode | Should -Be 7
            $result.Output | Should -Match 'not a git repository'
        }

        It 'returns when git exits even though a background process keeps the output pipes open' {
            # A file system monitor daemon does exactly this; waiting for the pipes to
            # close instead of for the process would hang here until it ends.
            [System.IO.File]::WriteAllText((Join-Path $script:Bin 'git.cmd'), "@echo off`r`nstart /b ping -n 16 127.0.0.1`r`nexit /b 0`r`n")
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $result = InModuleScope Test.RecoveryActions -Parameters @{ P = $script:Base } -ScriptBlock { param($P) Invoke-RecoveryGitStatus -RepoPath $P }
            $clock.Stop()
            $result.ExitCode | Should -Be 0
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        }
    }
}

Describe 'reclone_project' {
    BeforeEach {
        $script:Base = New-ScratchDir
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
        $script:Result = New-TestResult -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' -Reason 'git clone failed (exit 128): early EOF'
    }
    AfterEach {
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'declines when the checkout is already healthy, without cloning' {
        $fx = New-CloneFixture -Base $script:Base -Health @($true)
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'project-already-healthy'
        @($fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 0
        Get-LedgerPhase -Dir $fx.Runtime | Should -Be @('declined')
        @($fx.Log | Where-Object { $_ -like 'health:*' }) | Should -Be @("health:$($fx.Context.ProjectDir)")
    }

    It 'declines with no project URL anywhere: the project then ships inside the framework checkout' {
        $fx = New-CloneFixture -Base $script:Base -ProjectUrl ''
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'no-project-url'
        $fx.Log.Count | Should -Be 0
    }

    It 'declines on a denied access record, even when the context has a URL' {
        $fx = New-CloneFixture -Base $script:Base
        [System.IO.File]::WriteAllText((Join-Path $fx.Runtime 'project.access.json'), '{"url":"https://example.invalid/pool/assigned.git","status":"denied","detail":"no access"}')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'project-access-denied'
        $fx.Log.Count | Should -Be 0
    }

    It 'uses the URL of an access record that says ok when the context has none' {
        $fx = New-CloneFixture -Base $script:Base -ProjectUrl ''
        [System.IO.File]::WriteAllText((Join-Path $fx.Runtime 'project.access.json'), '{"url":"https://example.invalid/pool/assigned.git","status":"ok","assignedBy":{"poolId":"p1"},"checkedAt":"2026-10-04T10:00:00Z"}')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'applied'
        @($fx.Log | Where-Object { $_ -like 'update:*' }) | Should -Be @("update:$($fx.Framework)|https://example.invalid/pool/assigned.git")
    }

    It 'prefers the URL in the context over the one in an ok access record' {
        $fx = New-CloneFixture -Base $script:Base
        [System.IO.File]::WriteAllText((Join-Path $fx.Runtime 'project.access.json'), '{"url":"https://example.invalid/pool/assigned.git","status":"ok"}')
        Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime | Out-Null
        @($fx.Log | Where-Object { $_ -like 'update:*' }) | Should -Be @("update:$($fx.Framework)|https://example.invalid/org/project.git")
    }

    It 'does not use the URL of an access record that is not ok, or one it cannot read (<Label>)' -ForEach @(
        @{ Label = 'unreachable'; Text = '{"url":"https://example.invalid/pool/assigned.git","status":"unreachable"}' }
        @{ Label = 'no status'; Text = '{"url":"https://example.invalid/pool/assigned.git"}' }
        @{ Label = 'not json'; Text = 'this is not json' }
        @{ Label = 'a json array'; Text = '[{"status":"ok","url":"https://example.invalid/x.git"}]' }
    ) {
        $fx = New-CloneFixture -Base $script:Base -ProjectUrl ''
        [System.IO.File]::WriteAllText((Join-Path $fx.Runtime 'project.access.json'), $Text)
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'no-project-url'
    }

    It 'applies when the clone works and the checkout is healthy afterwards' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false, $true)
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'applied'
        $out.RecoveryState | Should -Be 'applied'
        $out.SkipFailurePause | Should -BeTrue
        $out.Attempt | Should -Be 1
        $out.Reason | Should -Be 'project-healthy'
        @($fx.Log) | Should -Be @(
            "health:$($fx.Context.ProjectDir)",
            "update:$($fx.Framework)|https://example.invalid/org/project.git",
            "health:$($fx.Context.ProjectDir)"
        )
        @($out.Evidence | ForEach-Object { $_.ref }) | Should -Contain 'project-revision'
        Get-LedgerPhase -Dir $fx.Runtime | Should -Be @('started', 'succeeded')
    }

    It 'checks the project folder under the framework checkout when the context names none' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false, $true)
        $context = @{ Result = $script:Result } + $fx.Context
        $context.Remove('ProjectDir')
        Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime | Out-Null
        @($fx.Log | Where-Object { $_ -like 'health:*' } | Select-Object -Unique) | Should -Be @("health:$(Join-Path $fx.Framework 'project')")
    }

    It 'rolls back and fails when the clone worked but the checkout is still not healthy' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false, $false) -RestoreActions @('restored-previous')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'failed'
        $out.RecoveryState | Should -Be 'failed'
        $out.SkipFailurePause | Should -BeFalse
        $out.Reason | Should -Match '^project-unhealthy: HEAD does not resolve'
        @($fx.Log | Where-Object { $_ -like 'restore:*' }) | Should -Be @("restore:$($fx.Framework)")
        Get-LedgerPhase -Dir $fx.Runtime | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
        (Get-LedgerRecord -Dir $fx.Runtime -Phase 'rolled-back')[0].reason | Should -Be 'swap-restored'
    }

    It 'rolls back and fails when the clone reports failure, redacting what it says' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false) -CloneBehavior 'fail'
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Match '^clone-failed: git clone failed \(exit 128\)'
        $out.Reason | Should -Not -Match 's3cr3tPass'
        [System.IO.File]::ReadAllText((Get-RecoveryLedgerPath -RuntimeDir $fx.Runtime)) | Should -Not -Match 's3cr3tPass'
        @($fx.Log | Where-Object { $_ -like 'health:*' }).Count | Should -Be 1 -Because 'a failed clone has no postcondition to prove'
        @($fx.Log | Where-Object { $_ -like 'restore:*' }).Count | Should -Be 1
        (Get-LedgerRecord -Dir $fx.Runtime -Phase 'rolled-back')[0].reason | Should -Be 'nothing-to-restore'
    }

    It 'rolls back and fails when the clone throws' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false) -CloneBehavior 'throw'
        { $script:Out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime } | Should -Not -Throw
        $script:Out.Decision | Should -Be 'failed'
        $script:Out.Reason | Should -Match '^action-threw: network is unreachable'
        @($fx.Log | Where-Object { $_ -like 'restore:*' }).Count | Should -Be 1
    }

    It 'fails, naming it, when the clone answers nothing' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false) -CloneBehavior 'nothing'
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'failed'
        $out.Reason | Should -Be 'clone-no-answer'
    }

    It 'declines when the health check cannot answer, rather than cloning blind' {
        $fx = New-CloneFixture -Base $script:Base
        $context = @{ Result = $script:Result } + $fx.Context
        $context['TestProjectCloneHealth'] = { }
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'health-check-no-answer'
        @($fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 0
    }

    It 'declines when the context names no framework checkout' {
        $fx = New-CloneFixture -Base $script:Base
        $context = @{ Result = $script:Result } + $fx.Context
        $context['RepoRoot'] = ''
        $context['ProjectDir'] = ''
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'no-repository'
    }

    It 'keeps a credential in the project URL out of the evidence and the ledger' {
        $fx = New-CloneFixture -Base $script:Base -ProjectUrl 'https://deploy:s3cr3tPass@example.invalid/org/project.git'
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'applied'
        [System.IO.File]::ReadAllText((Get-RecoveryLedgerPath -RuntimeDir $fx.Runtime)) | Should -Not -Match 's3cr3tPass'
        ($out.Evidence | ConvertTo-Json -Depth 5) | Should -Not -Match 's3cr3tPass'
    }

    It 'stops after two attempts for the same failure' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false) -CloneBehavior 'fail'
        $decisions = foreach ($i in 1..3) {
            (Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime).Decision
        }
        @($decisions) | Should -Be @('failed', 'failed', 'exhausted')
        @($fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 2
    }

    It 'loads nothing from Test.HostGit when every dependency is supplied' {
        Remove-Module Test.HostGit -Force -ErrorAction SilentlyContinue
        $fx = New-CloneFixture -Base $script:Base
        Invoke-RecoveryAction -Name 'reclone_project' -Context (@{ Result = $script:Result } + $fx.Context) -RuntimeDir $fx.Runtime | Out-Null
        Get-Module Test.HostGit | Should -BeNullOrEmpty
    }

    It 'also works through the planner for a failed project clone' {
        $fx = New-CloneFixture -Base $script:Base
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $fx.Context -RuntimeDir $fx.Runtime -Enabled $true
        $out.Decision | Should -Be 'applied'
        $out.Action | Should -Be 'reclone_project'
        @($out.Advised) | Should -Be @('reclone_project')
    }

    It 'is tried after the lock repair declines for want of a lock' {
        $lockResult = New-TestResult -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' -Reason "fatal: Unable to create '.git/index.lock': File exists."
        $fx = New-CloneFixture -Base $script:Base -Health @($false, $true)
        $out = Invoke-RecoveryForResult -Result $lockResult -Context $fx.Context -RuntimeDir $fx.Runtime -Enabled $true
        @($out.Decisions | ForEach-Object { $_.Action }) | Should -Be @('clear_stale_git_lock', 'reclone_project')
        @($out.Decisions | ForEach-Object { $_.Decision }) | Should -Be @('declined', 'applied')
        $out.Decisions[0].Reason | Should -Be 'no-stale-lock'
        $out.Action | Should -Be 'reclone_project'
        $out.Decision | Should -Be 'applied'
    }

    It 'reads the verdict of the real health check, loaded on first use' -Skip:(-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
        Remove-Module Test.HostGit -Force -ErrorAction SilentlyContinue
        $fx = New-CloneFixture -Base $script:Base
        Remove-Item -LiteralPath $fx.Context.ProjectDir -Recurse -Force
        Initialize-TestRepo -Path $fx.Context.ProjectDir
        $context = @{ Result = $script:Result } + $fx.Context
        $context.Remove('TestProjectCloneHealth')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'project-already-healthy'
        @($fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 0
        Get-Module Test.HostGit | Should -Not -BeNullOrEmpty -Because 'the real command came from the module, loaded when it was first needed'
    }

    It 'carries the reason of the real health check into the result when the checkout is still not usable' -Skip:(-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
        $fx = New-CloneFixture -Base $script:Base
        $context = @{ Result = $script:Result } + $fx.Context
        $context.Remove('TestProjectCloneHealth')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'failed' -Because 'the stand-in clone changed nothing on disk'
        $out.Reason | Should -Match '^project-unhealthy: the directory is not a git checkout'
        @($fx.Log | Where-Object { $_ -like 'update:*' }).Count | Should -Be 1
    }

    It 'puts a set-aside checkout back with the real swap recovery when the clone fails' {
        $fx = New-CloneFixture -Base $script:Base -Health @($false) -CloneBehavior 'fail'
        $project = $fx.Context.ProjectDir
        Remove-Item -LiteralPath $project -Recurse -Force
        $previous = Join-Path $fx.Framework 'project.previous'
        New-Item -ItemType Directory -Path $previous -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $previous 'marker.txt'), 'the last good checkout')
        $context = @{ Result = $script:Result } + $fx.Context
        $context.Remove('RestoreProjectCloneSwap')
        $out = Invoke-RecoveryAction -Name 'reclone_project' -Context $context -RuntimeDir $fx.Runtime
        $out.Decision | Should -Be 'failed'
        [System.IO.File]::ReadAllText((Join-Path $project 'marker.txt')) | Should -Be 'the last good checkout'
        Test-Path -LiteralPath $previous | Should -BeFalse
        (Get-LedgerRecord -Dir $fx.Runtime -Phase 'rolled-back')[0].reason | Should -Be 'swap-restored'
    }
}

Describe 'end_failure_pause_early' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = [datetime]::new(2026, 10, 4, 12, 0, 0, [DateTimeKind]::Utc)
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
    }
    AfterEach {
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'loads the remediation dispatcher on first use when the process does not have it' {
        Remove-Module Test.Remediation -Force -ErrorAction SilentlyContinue
        Get-Command -Name Test-AutoRemediationAllowed -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        @(Get-RecoveryPlan -Result (New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out')) | Should -Contain 'end_failure_pause_early'
        Get-Command -Name Test-AutoRemediationAllowed -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'applies to exactly the failure classes the dispatcher lists as safe to retry' {
        Import-Module (Join-Path $here 'Test.Remediation.psm1') -Force -DisableNameChecking -Global
        $allowed = @((Get-AutoRemediationAllowList).Keys)
        $allowed.Count | Should -BeGreaterThan 0
        foreach ($class in @(Get-FailureClassEnum)) {
            $plan = @(Get-RecoveryPlan -Result (New-TestResult -FailureClass $class -Stage 'cycle' -Reason 'x'))
            if ($class -in $allowed) {
                $plan | Should -Contain 'end_failure_pause_early' -Because "$class is on the allow-list"
            } else {
                $plan | Should -Not -Contain 'end_failure_pause_early' -Because "$class is not on the allow-list"
            }
        }
    }

    It 'does not apply to a result with no failure class' {
        $bare = New-RecoveryResult -EntryPoint 'runner' -CycleGeneration (('a' * 32) + ':4') -Outcome 'failed' -ExitCode 1
        @(Get-RecoveryPlan -Result $bare) | Should -Not -Contain 'end_failure_pause_early'
    }

    It 'applies nowhere when the dispatcher cannot be loaded' {
        Mock -ModuleName Test.RecoveryActions Get-Command { $null } -ParameterFilter { $Name -eq 'Test-AutoRemediationAllowed' }
        Mock -ModuleName Test.RecoveryActions Import-Module { }
        @(Get-RecoveryPlan -Result (New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out')) | Should -Not -Contain 'end_failure_pause_early'
    }

    It 'ends the pause: applied, with the pause skip, and a ledger entry per attempt' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $out = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result; RuntimeDir = $script:Dir } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $out.SkipFailurePause | Should -BeTrue
        $out.Attempt | Should -Be 1
        $out.AttemptId | Should -Match '^[0-9a-f]{32}$'
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('started', 'succeeded')
        $started = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records | Where-Object { $_.phase -eq 'started' }
        $started.action | Should -Be 'end_failure_pause_early'
        $started.fingerprint | Should -Be $result.fingerprint
        $started.generation | Should -Be $result.cycleGeneration
        $started.failureClass | Should -Be 'wait_timeout'
    }

    It 'allows the configured number of attempts for one fingerprint, then leaves the pause alone' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $context = @{ Result = $result; RuntimeDir = $script:Dir }
        $decisions = foreach ($minute in 0..2) {
            Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context $context -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes($minute)
        }
        @($decisions | ForEach-Object { $_.Decision }) | Should -Be @('applied', 'applied', 'exhausted')
        @($decisions | ForEach-Object { $_.Attempt }) | Should -Be @(1, 2, 2)
        $decisions[2].SkipFailurePause | Should -BeFalse
    }

    It 'counts the budget per failure fingerprint, so another failure starts fresh' {
        $first = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $second = New-TestResult -FailureClass 'network_timeout' -Stage 'cycle' -Reason 'timed out'
        $first.fingerprint | Should -Not -Be $second.fingerprint
        foreach ($minute in 0..1) {
            Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $first } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes($minute) | Out-Null
        }
        (Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $first } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes(2)).Decision | Should -Be 'exhausted'
        (Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $second } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes(2)).Decision | Should -Be 'applied'
    }

    It 'keeps its count across a restart of the runner' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        foreach ($minute in 0..1) {
            Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes($minute) | Out-Null
        }
        Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $here 'Test.RecoveryActions.psm1') -Force -DisableNameChecking
        (Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes(2)).Decision | Should -Be 'exhausted'
    }

    It 'starts over after a pass' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        foreach ($minute in 0..1) {
            Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes($minute) | Out-Null
        }
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(3) | Should -BeTrue
        $again = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result } -RuntimeDir $script:Dir -MaxAttempts 2 -Now $script:Now.AddMinutes(4)
        $again.Decision | Should -Be 'applied'
        $again.Attempt | Should -Be 1
    }

    It 'declines a class that is not on the allow-list when asked by name' {
        $result = New-TestResult -FailureClass 'script_error' -Stage 'cycle' -Reason 'x'
        $out = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result } -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'declined'
        $out.Reason | Should -Be 'class-not-allowed'
        $out.SkipFailurePause | Should -BeFalse
        Get-LedgerPhase -Dir $script:Dir | Should -Be @('declined')
    }

    It 'stays out of the plan when the caller keeps it for later, and is still callable by name' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $planned = Invoke-RecoveryForResult -Result $result -Context @{} -RuntimeDir $script:Dir -Enabled $true -ExcludeAction 'end_failure_pause_early' -Now $script:Now
        $planned.RecoveryState | Should -Be 'none'
        @($planned.Advised).Count | Should -Be 0
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
        (Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result; RuntimeDir = $script:Dir } -RuntimeDir $script:Dir -Now $script:Now).Decision | Should -Be 'applied'
    }

    It 'is only advised, and writes nothing, while automatic recovery is off' {
        $result = New-TestResult -FailureClass 'wait_timeout' -Stage 'cycle' -Reason 'timed out'
        $out = Invoke-RecoveryForResult -Result $result -Context @{} -RuntimeDir $script:Dir -Enabled $false
        $out.RecoveryState | Should -Be 'advised'
        @($out.Advised) | Should -Be @('end_failure_pause_early')
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
    }
}

Describe 'Planning across the built-in repairs' {
    BeforeEach {
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
    }
    AfterEach {
        Clear-RecoveryAction
        Register-BuiltinRecoveryAction
    }

    It 'plans <Plan> for <Label>' -ForEach @(
        @{ Label = 'a pull that failed on a lock'; Class = 'bootstrap_sync'; Stage = 'FrameworkPull'; Reason = "fatal: Unable to create '/srv/yuruna/.git/index.lock': File exists."; Plan = 'clear_stale_git_lock' }
        @{ Label = 'a project clone that failed on a lock'; Class = 'bootstrap_sync'; Stage = 'ProjectClone'; Reason = "fatal: Unable to create '/srv/yuruna/project.incoming/.git/index.lock': File exists."; Plan = 'clear_stale_git_lock reclone_project' }
        @{ Label = 'a project clone that failed for another reason'; Class = 'bootstrap_sync'; Stage = 'ProjectClone'; Reason = 'git clone failed (exit 128): early EOF'; Plan = 'reclone_project' }
        @{ Label = 'a project clone, with the stage spelled in lowercase'; Class = 'bootstrap_sync'; Stage = 'projectclone'; Reason = 'early EOF'; Plan = 'reclone_project' }
        @{ Label = 'a pull that failed for another reason'; Class = 'bootstrap_sync'; Stage = 'FrameworkPull'; Reason = 'the branch diverged'; Plan = '' }
        @{ Label = 'a different stage that names a lock'; Class = 'bootstrap_sync'; Stage = 'GitPull'; Reason = 'cannot lock ref: refs/heads/main.lock exists'; Plan = '' }
        @{ Label = 'a reason that only resembles a lock'; Class = 'bootstrap_sync'; Stage = 'FrameworkPull'; Reason = 'see /tmp/x.lockfile'; Plan = '' }
        @{ Label = 'a lock named in a failure of another class'; Class = 'script_error'; Stage = 'FrameworkPull'; Reason = 'index.lock exists'; Plan = '' }
        @{ Label = 'a transient class'; Class = 'wait_timeout'; Stage = 'cycle'; Reason = 'timed out'; Plan = 'end_failure_pause_early' }
        @{ Label = 'a transient class at a pull stage that names a lock'; Class = 'network_timeout'; Stage = 'FrameworkPull'; Reason = 'could not create index.lock'; Plan = 'end_failure_pause_early' }
        @{ Label = 'a class nothing repairs'; Class = 'credential_expired'; Stage = 'cycle'; Reason = 'expired'; Plan = '' }
    ) {
        $result = New-TestResult -FailureClass $Class -Stage $Stage -Reason $Reason
        (@(Get-RecoveryPlan -Result $result) -join ' ') | Should -Be $Plan
    }

    It 'matches the failure class exactly, not by case' {
        $result = [ordered]@{ failureClass = 'Bootstrap_Sync'; stage = 'ProjectClone'; reason = 'index.lock exists' }
        @(Get-RecoveryPlan -Result $result).Count | Should -Be 0
    }

    It 'plans the lock repair ahead of the reclone, in the registered order' {
        $result = New-TestResult -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' -Reason 'index.lock exists'
        $plan = @(Get-RecoveryPlan -Result $result)
        $plan.IndexOf('clear_stale_git_lock') | Should -BeLessThan $plan.IndexOf('reclone_project')
    }
}
