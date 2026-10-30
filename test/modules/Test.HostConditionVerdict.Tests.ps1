<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42d64c35-2931-4e2a-aa8a-75a10025ea5a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-condition verdict pester
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
    Pester coverage for the host-condition gate's verdict: bounded probes that
    refuse when they cannot answer, and a refused cycle filed under the
    condition that refused it.
.DESCRIPTION
    The gate used to answer with a bare bool, so a refused cycle's failure
    record said only that the condition was "named in the warnings above",
    and the preamble's refusal left no record at all. Its probes were also
    unbounded: on macOS a pmset or defaults read that threw was skipped and
    the host passed, and on Windows a powercfg call that never returned held
    the gate until the preamble watchdog ended the cycle.

    Every platform's probes are driven here off their real host through the
    bounded-call seams (Invoke-MacBoundedTool, Invoke-BoundedNativeCommand,
    Read-WindowsPowerSetting), so the suite runs on any OS.
    Run: Invoke-Pester -Path test/modules/Test.HostConditionVerdict.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.psm1') -Force -DisableNameChecking
    # Assert-Elevation, which the Windows gate calls first.
    Import-Module (Join-Path $here 'Test.HostDetection.psm1') -Global -DisableNameChecking
    $script:MacModule = Get-Module -Name 'Test.HostCondition.Mac'
    $script:WindowsModule = Get-Module -Name 'Test.HostCondition.Windows'
}

Describe 'Get-HostConditionVerdict names the refused condition' {
    BeforeAll {
        $script:Fixture = @()
        function script:Register-VerdictFixture {
            param([string]$HostType, [bool]$Passes, [scriptblock]$Failure)
            $script:Fixture += $HostType
            $assert = if ($Passes) { { param([string]$HostType) $null = $HostType; $true } } else { { param([string]$HostType) $null = $HostType; $false } }
            Register-HostConditionProvider -HostType $HostType -Assert $assert -AssertMinimum { $true } -Failure $Failure
        }
    }
    AfterAll {
        $store = (Get-YurunaRegistryDirectory)['HostCondition'].Store[0]
        foreach ($hostType in $script:Fixture) { $store.Remove($hostType) }
    }

    It 'passes with no condition when the provider passes' {
        Register-VerdictFixture -HostType 'host.fixture.verdict-pass' -Passes $true -Failure { [pscustomobject]@{ Condition = 'stale'; Detail = 'x' } }
        $verdict = Get-HostConditionVerdict -HostType 'host.fixture.verdict-pass'
        Assert-True $verdict.Passed 'a passing provider passes'
        Assert-Equal -Expected '' -Actual $verdict.Condition -Because 'a pass names no condition, whatever the reader holds'
        Assert-Equal -Expected '' -Actual $verdict.Message
    }

    It 'files the condition and detail the provider names, under the class unknown' {
        Register-VerdictFixture -HostType 'host.fixture.verdict-lock' -Passes $false -Failure { [pscustomobject]@{ Condition = 'lock-timeout'; Detail = 'InactivityTimeoutSecs=600' } }
        $verdict = Get-HostConditionVerdict -HostType 'host.fixture.verdict-lock'
        Assert-False $verdict.Passed 'a refusing provider refuses'
        Assert-Equal -Expected 'lock-timeout' -Actual $verdict.Condition
        Assert-Equal -Expected 'InactivityTimeoutSecs=600' -Actual $verdict.Detail
        Assert-Equal -Expected 'unknown' -Actual $verdict.FailureClass -Because 'a console-only fix is never a class the outer loop retries unattended'
        Assert-True ($verdict.Message -match "'lock-timeout'" -and $verdict.Message -match 'InactivityTimeoutSecs=600') "the record sentence names both: $($verdict.Message)"
    }

    It 'files the elevation condition under elevation_required' {
        Register-VerdictFixture -HostType 'host.fixture.verdict-elevation' -Passes $false -Failure { [pscustomobject]@{ Condition = 'elevation'; Detail = '' } }
        (Get-HostConditionVerdict -HostType 'host.fixture.verdict-elevation').FailureClass | Should -BeExactly 'elevation_required'
    }

    It 'files a refusal it cannot attribute as unnamed: <Case>' -TestCases @(
        @{ Case = 'no reader'; Failure = $null }
        @{ Case = 'reader returns nothing'; Failure = { $null } }
        @{ Case = 'reader throws'; Failure = { throw 'reader broke' } }
    ) {
        param([string]$Case, [scriptblock]$Failure)
        $hostType = "host.fixture.verdict-$($Case -replace '\W', '-')"
        Register-VerdictFixture -HostType $hostType -Passes $false -Failure $Failure
        $verdict = Get-HostConditionVerdict -HostType $hostType
        Assert-False $verdict.Passed 'the refusal stands'
        Assert-Equal -Expected 'unnamed' -Actual $verdict.Condition
        Assert-Equal -Expected 'unknown' -Actual $verdict.FailureClass
    }

    It 'keeps Assert-HostConditionSet as the verdict''s bool' {
        Register-VerdictFixture -HostType 'host.fixture.verdict-bool' -Passes $false -Failure $null
        $answer = Assert-HostConditionSet -HostType 'host.fixture.verdict-bool'
        Assert-True ($answer -is [bool] -and -not $answer) 'a refusal is $false, not a record'
    }
}

Describe 'Windows host conditions read powercfg bounded and name each refusal' {
    BeforeAll {
        # Get-Service exists only on Windows; Pester mocks a command that exists.
        if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
            function global:Get-Service { param([string]$Name) $null = $Name }
            $script:DefinedGetService = $true
        }
        $script:PowerQuery = @(
            'Power Setting GUID: 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e  (Turn off display after)'
            '    Current AC Power Setting Index: 0x00000000'
            '    Current DC Power Setting Index: 0x0000012c'
        ) -join "`n"
    }
    AfterAll {
        if ($script:DefinedGetService) { Remove-Item -Path Function:/global:Get-Service -ErrorAction SilentlyContinue }
    }

    It 'returns nothing for a powercfg call that <Case>' -TestCases @(
        @{ Case = 'timed out'; Outcome = @{ TimedOut = $true; Started = $true; ExitCode = 124; StdOut = '' } }
        @{ Case = 'could not start'; Outcome = @{ TimedOut = $false; Started = $false; ExitCode = -1; StdOut = '' } }
        @{ Case = 'exited non-zero'; Outcome = @{ TimedOut = $false; Started = $true; ExitCode = 1; StdOut = 'Invalid Parameters' } }
    ) {
        param([string]$Case, [hashtable]$Outcome)
        $null = $Case
        $script:FixtureOutcome = [pscustomobject]$Outcome
        Mock -ModuleName Test.HostCondition.Windows Invoke-BoundedNativeCommand { $script:FixtureOutcome }
        $read = & $script:WindowsModule { Read-WindowsPowerSetting -Subgroup 'SUB_VIDEO' -Setting 'VIDEOIDLE' }
        Assert-Null $read 'an unanswered read is not a value'
        Should -Invoke -ModuleName Test.HostCondition.Windows Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'powercfg' -and $TimeoutSeconds -gt 0 -and ($ArgumentList -join ' ') -eq '/query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE'
        }
    }

    It 'reads the AC and DC index from an answered query' {
        $script:FixtureOutcome = [pscustomobject]@{ TimedOut = $false; Started = $true; ExitCode = 0; StdOut = $script:PowerQuery }
        Mock -ModuleName Test.HostCondition.Windows Invoke-BoundedNativeCommand { $script:FixtureOutcome }
        $read = & $script:WindowsModule { Read-WindowsPowerSetting -Subgroup 'SUB_VIDEO' -Setting 'VIDEOIDLE' }
        Assert-Equal -Expected 0 -Actual $read.Ac
        Assert-Equal -Expected 300 -Actual $read.Dc
    }

    It 'names <Condition> when <Case>' -TestCases @(
        @{ Case = 'the process is not elevated'; Condition = 'elevation'; Elevated = $false; Service = 'Running'; Power = 'answered'; Detail = '' }
        @{ Case = 'vmms is stopped'; Condition = 'hypervisor-service'; Elevated = $true; Service = 'Stopped'; Power = 'answered'; Detail = 'vmms=Stopped' }
        @{ Case = 'the display timeout cannot be read'; Condition = 'display-timeout'; Elevated = $true; Service = 'Running'; Power = 'unread'; Detail = 'VIDEOIDLE unreadable' }
        @{ Case = 'the display timeout read throws'; Condition = 'display-timeout'; Elevated = $true; Service = 'Running'; Power = 'throws'; Detail = 'VIDEOIDLE unreadable' }
        @{ Case = 'the display turns off'; Condition = 'display-timeout'; Elevated = $true; Service = 'Running'; Power = 'nonzero'; Detail = 'VIDEOIDLE=600' }
    ) {
        param([string]$Case, [string]$Condition, [bool]$Elevated, [string]$Service, [string]$Power, [string]$Detail)
        $null = $Case
        $script:FixtureElevated = $Elevated
        $script:FixtureService = $Service
        $script:FixturePower = $Power
        Mock -ModuleName Test.HostCondition.Windows Assert-Elevation { $script:FixtureElevated }
        Mock -ModuleName Test.HostCondition.Windows Get-Service { [pscustomobject]@{ Status = $script:FixtureService } }
        Mock -ModuleName Test.HostCondition.Windows Read-WindowsPowerSetting {
            switch ($script:FixturePower) {
                'unread'  { $null }
                'throws'  { throw 'powercfg broke' }
                'nonzero' { [pscustomobject]@{ Ac = 600; Dc = 600 } }
                default   { [pscustomobject]@{ Ac = 0; Dc = 0 } }
            }
        }
        $passed = Assert-WindowsHostConditionSet -HostType 'host.windows.hyper-v' 3>$null
        Assert-False $passed "the gate refuses when $Case"
        $failure = Get-WindowsHostConditionFailure
        Assert-Equal -Expected $Condition -Actual $failure.Condition
        Assert-Equal -Expected $Detail -Actual $failure.Detail
    }

    It 'clears the named condition on the next call' {
        Mock -ModuleName Test.HostCondition.Windows Assert-Elevation { $false }
        $null = Assert-WindowsHostConditionSet -HostType 'host.windows.hyper-v' 3>$null
        $null = Assert-WindowsHostConditionSet -HostType 'host.macos.utm'
        Assert-Null (Get-WindowsHostConditionFailure) 'a stale refusal must not be read back after a pass'
    }
}

Describe 'macOS screen-lock probes refuse when a tool does not answer' {
    BeforeAll {
        # The guards are private to the module; read them there once.
        $script:SafePmset = & $script:MacModule {
            $lines = @('AC Power:', ' displaysleep         0')
            foreach ($g in @(Get-MacSleepGuardList) + @(Get-MacPmsetGuardList)) { $lines += " $($g.Key)    $($g.Want)" }
            $lines -join "`n"
        }
        # Answers every probe Get-MacScreenLockIssue makes with a safe value,
        # except the tools named in $script:Unanswered, which time out or
        # cannot start as $script:UnansweredHow says.
        $script:SafeAnswer = {
            param([string]$Tool)
            if ($script:Unanswered -contains $Tool) {
                if ($script:UnansweredHow -eq 'timeout') { return [pscustomobject]@{ Text = ''; TimedOut = $true; Started = $true; ExitCode = 124 } }
                return [pscustomobject]@{ Text = ''; TimedOut = $false; Started = $false; ExitCode = -1 }
            }
            $text = switch ($Tool) {
                'pmset' { $script:SafePmset }
                'sysadminctl' { 'screenLock delay is -1 seconds' }
                default { '0' }
            }
            return [pscustomobject]@{ Text = $text; TimedOut = $false; Started = $true; ExitCode = 0 }
        }
    }
    BeforeEach {
        $script:Unanswered = @()
        $script:UnansweredHow = 'timeout'
        Mock -ModuleName Test.HostCondition.Mac Invoke-MacBoundedTool { & $script:SafeAnswer $Tool }
    }

    It 'reports nothing for a host whose every setting is safe' {
        $issues = @(Get-MacScreenLockIssue)
        Assert-Equal -Expected 0 -Actual $issues.Count -Because "a safe host has no issue: $($issues -join ' | ')"
    }

    It 'reports one undetermined power read when pmset times out, and no setting from it' {
        $script:Unanswered = @('pmset')
        $issues = @(Get-MacScreenLockIssue)
        Assert-Equal -Expected 1 -Actual $issues.Count -Because "only the unanswered read: $($issues -join ' | ')"
        Assert-True ($issues[0] -match 'pmset' -and $issues[0] -match 'could not be read') "the line names the tool: $($issues[0])"
    }

    It 'reports each preference read as undetermined when defaults cannot start, not as a missing key' {
        $script:Unanswered = @('defaults')
        $script:UnansweredHow = 'not-started'
        $issues = @(Get-MacScreenLockIssue)
        # idleTime and askForPassword in two domains, four hot corners, auto-logout.
        Assert-Equal -Expected 9 -Actual $issues.Count -Because "one line per unanswered read: $($issues -join ' | ')"
        Assert-True (@($issues | Where-Object { $_ -notmatch 'could not be read' }).Count -eq 0) 'every line is the undetermined form'
    }

    It 'reports the unified screen lock as undetermined when sysadminctl times out' {
        $script:Unanswered = @('sysadminctl')
        $issues = @(Get-MacScreenLockIssue)
        Assert-Equal -Expected 1 -Actual $issues.Count
        Assert-True ($issues[0] -match 'sysadminctl') "the line names the tool: $($issues[0])"
    }

    It 'bounds every probe it makes' {
        $null = Get-MacScreenLockIssue
        # pmset once, defaults nine times, sysadminctl once -- and nothing unbounded.
        Should -Invoke -ModuleName Test.HostCondition.Mac Invoke-MacBoundedTool -Times 11 -Exactly
        $body = (Get-Command Get-MacScreenLockIssue).ScriptBlock.Ast.Body.Extent.Text
        Assert-False ($body -match '&\s*(pmset|defaults|sysadminctl)\b') 'no direct call of a probe tool remains'
    }

    It 'files the first refused gate, with the screen-lock issue lines as its detail' {
        Mock -ModuleName Test.HostCondition.Mac Assert-Accessibility { $true }
        Mock -ModuleName Test.HostCondition.Mac Assert-ScreenRecording { $true }
        Mock -ModuleName Test.HostCondition.Mac Get-MacScreenLockIssue { @('first issue', 'second issue') }
        $passed = Assert-MacHostConditionSet -HostType 'host.macos.utm' 3>$null
        Assert-False $passed 'the screen-lock gate refuses'
        $failure = Get-MacHostConditionFailure
        Assert-Equal -Expected 'screen-lock' -Actual $failure.Condition
        Assert-Equal -Expected 'first issue; second issue' -Actual $failure.Detail
    }

    It 'files the grant that refused first' {
        Mock -ModuleName Test.HostCondition.Mac Assert-Accessibility { $false }
        $null = Assert-MacHostConditionSet -HostType 'host.macos.utm' 3>$null
        Assert-Equal -Expected 'accessibility' -Actual (Get-MacHostConditionFailure).Condition
    }
}

Describe 'Linux host conditions name each refusal' {
    It 'names the missing KVM device' {
        Mock -ModuleName Test.HostCondition.Linux Write-HostClockDriftWarning { }
        Mock -ModuleName Test.HostCondition.Linux Test-Path { $false } -ParameterFilter { $LiteralPath -eq '/dev/kvm' }
        $passed = Assert-LinuxHostConditionSet -HostType 'host.ubuntu.kvm' -ErrorAction SilentlyContinue
        Assert-False $passed 'no KVM device refuses'
        Assert-Equal -Expected 'kvm-device' -Actual (Get-LinuxHostConditionFailure).Condition
    }
}

Describe 'A refused host condition reaches the failure record' {
    It 'the preamble files the verdict before it exits' {
        # The script cannot run here; its order is pinned instead. The refusal
        # used to exit with no record at all.
        $ast = Get-YurunaTestFileAst -Path (Join-Path (Split-Path -Parent $here) 'modules/Invoke-TestRunnerInnerLoop.ps1')
        $branch = $ast.Find({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -eq '-not $hostConditionVerdict.Passed' }, $true)
        Assert-NotNull $branch 'the preamble branches on the verdict'
        $statements = @($branch.Clauses[0].Item2.Statements | ForEach-Object { $_.Extent.Text })
        $record = [array]::FindIndex([string[]]$statements, [Predicate[string]]{ param($t) $t -match "^Write-CycleInfraFailure -Stage 'HostCondition' -FailureClass \`$hostConditionVerdict\.FailureClass" -and $t -match '-ErrorMessage \$hostConditionVerdict\.Message' })
        $exit = [array]::FindIndex([string[]]$statements, [Predicate[string]]{ param($t) $t -eq 'exit $ExitFailure' })
        Assert-True ($record -ge 0) 'the refusal writes the infra failure record from the verdict'
        Assert-True ($exit -gt $record) 'and only then exits'
    }

    It 'the cycle body files the named condition and its class' {
        Import-Module (Join-Path $here 'Test.Prelude.psm1') -Global -DisableNameChecking
        Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
        Mock -ModuleName Test.RunnerInnerLoop Initialize-CycleGatingState {
            @{ CycleCount = 7; ConsecutiveCrashes = 0; FailuresBeforeAlert = 3; SuccessesBeforeRearm = 2; ConsecutiveFailures = 0
               ConsecutiveSuccesses = 0; AlertArmed = $true; GatingFile = 'fixture-gating.json' }
        }
        Mock -ModuleName Test.RunnerInnerLoop Test-YurunaRefreshCycleGate { $true }
        Mock -ModuleName Test.RunnerInnerLoop Get-HostConditionVerdict {
            [pscustomobject]@{ Passed = $false; Condition = 'elevation'; Detail = ''; FailureClass = 'elevation_required'
                Message = "Host condition 'elevation' failed; the warnings above give the remedy, which is applied at the host console." }
        }
        Mock -ModuleName Test.RunnerInnerLoop Write-CycleInfraFailure { }
        Mock -ModuleName Test.RunnerInnerLoop Invoke-RunnerBootstrapFailureGate { }
        Mock -ModuleName Test.RunnerInnerLoop Sync-RunnerBootstrapGateCounter { }
        Mock -ModuleName Test.RunnerInnerLoop Get-CurrentGitCommit { 'framework-sha' }
        $runtime = Join-Path $TestDrive 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = $runtime
            $state = @{
                RepoRoot = $TestDrive; TestRoot = (Join-Path $TestDrive 'test'); SequencesDir = 'sequences'; ScreenshotsDir = 'screenshots'
                StatusFile = (Join-Path $runtime 'status.json'); ConfigPath = 'fixture.yml'; TemplatePath = 'template.yml'
                HostType = 'host.windows.hyper-v'; ModulesDir = $here; NoGitPull = $true; NoProjectClone = $true; NoConfigGate = $true
                NoStatusService = $true; CycleDelaySeconds = 0; CachingProxyServiceUrl = ''; StartScript = 'fixture.ps1'
                StepHeartbeatFile = (Join-Path $runtime 'heartbeat'); ShutdownState = @{ Requested = $false }
                RunnerCfgState = @{ StopOnFailure = $true; GetImageRefreshSeconds = 0; CycleDelaySeconds = 0 }; Config = @{}
            }
            Invoke-RunnerInnerCycle -State $state 6>$null 3>$null
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedRuntime
        }
        Assert-False $state.OverallPassed 'a refused cycle is a failed cycle'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-CycleInfraFailure -Times 1 -Exactly -ParameterFilter {
            $Stage -eq 'HostCondition' -and $FailureClass -eq 'elevation_required' -and $ErrorMessage -match "'elevation'"
        }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Invoke-RunnerBootstrapFailureGate -Times 1 -Exactly -ParameterFilter {
            $FailureClass -eq 'elevation_required'
        }
    }
}
