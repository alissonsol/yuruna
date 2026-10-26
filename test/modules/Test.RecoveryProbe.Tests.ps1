<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42e97954-e78f-416a-ba82-810b6f837f0e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery probe failure-pause pester
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
    The probes the failure pause runs to learn that a host condition cleared.
.DESCRIPTION
    A hypervisor that answered again, a bridged switch that forwarded again or a
    pool share with room again still cost the host the whole failure pause,
    because nothing asked. The probes ask from a short-lived process, and a
    cleared probe ends the pause through the recovery ledger.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryProbe.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryActions.psm1') -Force -DisableNameChecking
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'The probe registry' {
    It 'names a probe for each host condition that clears on its own, and none for a guest fault' {
        foreach ($class in 'hypervisor_unresponsive', 'host_network_degraded', 'pool_storage_full') {
            $probe = Get-RecoveryProbe -FailureClass $class
            $probe | Should -Not -BeNullOrEmpty -Because $class
            $probe.IntervalSeconds | Should -BeGreaterOrEqual 30
        }
        Get-RecoveryProbe -FailureClass 'wait_timeout' | Should -BeNullOrEmpty
        Get-RecoveryProbe -FailureClass '' | Should -BeNullOrEmpty
    }
    It 'lists exactly the registered classes in the probe script''s accepted values' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-RecoveryProbe.ps1'), [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'FailureClass' }
        $set = @($param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0].PositionalArguments | ForEach-Object { $_.Value }
        (@($set | Sort-Object) -join ',') | Should -Be ((@('hypervisor_unresponsive', 'host_network_degraded', 'pool_storage_full') | Sort-Object) -join ',')
    }
}

Describe 'Running a probe' {
    It 'counts only a complete run that exited 0 as cleared' -TestCases @(
        @{ Run = @{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = "loading`nhypervisor: Responsive (responsive)`n" }; Ran = $true; Cleared = $true; Detail = 'hypervisor: Responsive (responsive)' }
        @{ Run = @{ Started = $true; TimedOut = $false; ExitCode = 1; StdOut = 'hypervisor: Unresponsive (timeout)' }; Ran = $true; Cleared = $false; Detail = 'hypervisor: Unresponsive (timeout)' }
        @{ Run = @{ Started = $true; TimedOut = $false; ExitCode = 2; StdOut = 'probe failed: boom' }; Ran = $true; Cleared = $false; Detail = 'probe failed: boom' }
        @{ Run = @{ Started = $true; TimedOut = $true; ExitCode = 0; StdOut = '' }; Ran = $true; Cleared = $false; Detail = 'probe timed out after 180 s' }
        @{ Run = @{ Started = $false; TimedOut = $false; ExitCode = -1; StdOut = '' }; Ran = $false; Cleared = $false; Detail = 'probe could not start' }
    ) {
        param($Run, $Ran, $Cleared, $Detail)
        $seen = @{}
        $answer = $Run
        $r = Invoke-RecoveryProbe -FailureClass hypervisor_unresponsive -RepoRoot $script:RepoRoot -ConfigPath 'fixture.yml' -Runner {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            $seen['FilePath'] = $FilePath
            $seen['ArgumentList'] = @($ArgumentList)
            $seen['TimeoutSeconds'] = $TimeoutSeconds
            $answer
        }.GetNewClosure()
        $seen['FilePath'] | Should -Be ([Environment]::ProcessPath) -Because 'the probe runs in a pwsh of its own'
        $r.Ran | Should -Be $Ran
        $r.Cleared | Should -Be $Cleared
        $r.Detail | Should -Be $Detail
        ($seen['ArgumentList'] -join ' ') | Should -Match '-File \S*Invoke-RecoveryProbe\.ps1 -FailureClass hypervisor_unresponsive -ConfigPath fixture\.yml'
        $seen['TimeoutSeconds'] | Should -Be 180
    }
    It 'does not run for a class with no probe' {
        $r = Invoke-RecoveryProbe -FailureClass wait_timeout -RepoRoot $script:RepoRoot -Runner { throw 'must not run' }
        $r.Ran | Should -BeFalse
    }
    It 'runs the real probe script in its own process' {
        $config = Join-Path $TestDrive 'probe.yml'
        Set-Content -LiteralPath $config -Value 'logLevel: Information' -Encoding utf8
        $r = Invoke-RecoveryProbe -FailureClass pool_storage_full -RepoRoot $script:RepoRoot -ConfigPath $config
        $r.Ran | Should -BeTrue -Because $r.Detail
        $r.Cleared | Should -BeTrue -Because "a host with no pool share has room: $($r.Detail)"
        $r.Detail | Should -Be 'pool storage: room for a cycle'
    }
}

Describe 'Ending a pause on a cleared probe' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Dir
        $script:Result = New-RecoveryResult -EntryPoint runner -CycleGeneration (('a' * 32) + ':3') -Outcome 'infrastructure-fault' -ExitCode 1 `
            -FailureClass 'pool_storage_full' -Stage 'PoolStorage' -Reason 'the pool share has no room for this cycle'
    }
    It 'applies only to a class with a probe, and only with a cleared probe in hand' {
        @(Get-RecoveryPlan -Result $script:Result) | Should -Contain 'end_failure_pause_on_probe'
        $guest = New-RecoveryResult -EntryPoint runner -CycleGeneration (('a' * 32) + ':3') -Outcome 'failed' -ExitCode 1 -FailureClass 'wait_timeout'
        @(Get-RecoveryPlan -Result $guest) | Should -Not -Contain 'end_failure_pause_on_probe'
        $held = Invoke-RecoveryAction -Name 'end_failure_pause_on_probe' -RuntimeDir $script:Dir -MaxAttempts 2 `
            -Context @{ Result = $script:Result; RuntimeDir = $script:Dir; Probe = [pscustomobject]@{ Ran = $true; Cleared = $false; Detail = 'still full' } }
        $held.Decision | Should -Be 'declined'
        $cleared = Invoke-RecoveryAction -Name 'end_failure_pause_on_probe' -RuntimeDir $script:Dir -MaxAttempts 2 `
            -Context @{ Result = $script:Result; RuntimeDir = $script:Dir; Probe = [pscustomobject]@{ Ran = $true; Cleared = $true; Detail = 'pool storage: room for a cycle' } }
        $cleared.Decision | Should -Be 'applied'
        $cleared.SkipFailurePause | Should -BeTrue
    }
}

# The ledger's attempt budget re-arms at every pass, so a hang that the watchdog
# killed between passes could take every early end of every pause, all day.
Describe 'The runner-minute budget of a failure class' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Dir
        $script:History = (Get-RecoveryResultPath -RuntimeDir $script:Dir).History
        $script:Now = [datetime]::UtcNow
        function Add-FailedMinute {
            param([string]$Class, [int]$Minutes)
            $row = New-RecoveryResult -EntryPoint runner -CycleGeneration (('b' * 32) + ':1') -Outcome failed -ExitCode 1 `
                -FailureClass $Class -RecordedAtUtc $script:Now.AddMinutes(-30) -DurationSeconds ($Minutes * 60)
            Add-Content -LiteralPath $script:History -Value ($row | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
        }
    }
    It 'ends no pause early once the class spent its minutes in the last 24 h' {
        $result = New-RecoveryResult -EntryPoint runner -CycleGeneration (('b' * 32) + ':2') -Outcome failed -ExitCode 1 -FailureClass wait_timeout -Reason 'timed out'
        Add-FailedMinute -Class wait_timeout -Minutes 100
        $under = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result; RuntimeDir = $script:Dir } -RuntimeDir $script:Dir -MaxAttempts 5
        $under.Decision | Should -Be 'applied' -Because 'one hundred of 180 minutes'
        Add-FailedMinute -Class wait_timeout -Minutes 90
        $over = Invoke-RecoveryAction -Name 'end_failure_pause_early' -Context @{ Result = $result; RuntimeDir = $script:Dir } -RuntimeDir $script:Dir -MaxAttempts 5
        $over.Decision | Should -Be 'declined'
        $over.Reason | Should -Match '^class-budget-spent: 190 of 180 runner-minutes in 24 h'
    }
    It 'holds the probe end to the same budget' {
        $result = New-RecoveryResult -EntryPoint runner -CycleGeneration (('b' * 32) + ':3') -Outcome 'infrastructure-fault' -ExitCode 1 -FailureClass pool_storage_full
        Add-FailedMinute -Class pool_storage_full -Minutes 200
        $probe = [pscustomobject]@{ Ran = $true; Cleared = $true; Detail = 'pool storage: room for a cycle' }
        $spent = Invoke-RecoveryAction -Name 'end_failure_pause_on_probe' -Context @{ Result = $result; RuntimeDir = $script:Dir; Probe = $probe } -RuntimeDir $script:Dir -MaxAttempts 5
        $spent.Decision | Should -Be 'declined'
        $spent.Reason | Should -Match 'class-budget-spent'
    }
}
