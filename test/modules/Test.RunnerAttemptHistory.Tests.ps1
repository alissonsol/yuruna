<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42c99f20-212d-4f14-a8a8-7d826d2aa939
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner attempt history retention pester
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
    Pins the retention of Update-RunnerAttemptHistory in
    Test.RunnerAttemptHistory.psm1: the latest attempts, plus the older failures
    a later attempt passed after, with their evidence.
.DESCRIPTION
    Every cycle is an attempt, so on a host that recovers, the passing attempts
    after a failure fill the window of latest attempts within hours, and the
    failure -- index row and evidence -- must stay readable past that. These
    cases write attempt evidence with known finish times and read back the
    published index and the artifact folders that remain.
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerAttemptHistory.psm1') -Force -DisableNameChecking

    function New-AttemptRecord {
        <#
        .SYNOPSIS
            Write one attempt's gate evidence, finished FinishedUtc, as the gate does.
        .OUTPUTS
            [string] the evidence path relative to the runtime directory.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes attempt evidence under a throwaway runtime directory.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$RuntimeDir,
            [Parameter(Mandatory)][string]$Generation,
            [Parameter(Mandatory)][bool]$Passed,
            [Parameter(Mandatory)][datetime]$FinishedUtc
        )
        $relative = Initialize-RunnerAttemptDirectory -RuntimeDir $RuntimeDir -AttemptGeneration $Generation -Confirm:$false
        $record = [ordered]@{
            schemaVersion = 1; attemptGeneration = $Generation
            startedAtUtc = $FinishedUtc.AddSeconds(-20).ToString('o'); finishedAtUtc = $FinishedUtc.ToString('o')
            passed = $Passed; skipped = $false; exitCode = $(if ($Passed) { 0 } else { 1 })
            failureClass = $(if ($Passed) { '' } else { 'config_gate_failed' }); description = $(if ($Passed) { '' } else { "failure of $Generation" })
            recordPath = "$relative/config-gate.json"; transcriptPath = "$relative/config-gate.log"
        }
        [IO.File]::WriteAllText((Join-Path $RuntimeDir "$relative/config-gate.json"), ($record | ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $RuntimeDir "$relative/config-gate.log"), 'transcript')
        return "$relative/config-gate.json"
    }

    function Read-AttemptIndex {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$RuntimeDir)
        return (Get-Content -Raw -LiteralPath (Join-Path $RuntimeDir 'runner-attempts/index.json') | ConvertFrom-Json -AsHashtable)
    }
}

Describe 'Runner attempt history retention' {
    BeforeEach { $script:Dir = New-YurunaTestTempDir -Prefix 'yrn-attempt-history' }
    AfterEach { Remove-YurunaTestTempDir $script:Dir }

    It 'keeps older failures a later attempt passed after, and retires older passes' {
        $start = [datetime]::UtcNow.AddHours(-10)
        $paths = [ordered]@{}
        $order = @('f1', 'p1', 'f2', 'p2', 'f3', 'p3', 'p4', 'p5')
        for ($i = 0; $i -lt $order.Count; $i++) {
            $name = $order[$i]
            $paths[$name] = New-AttemptRecord -RuntimeDir $script:Dir -Generation "runner:$name" -Passed ($name -like 'p*') -FinishedUtc $start.AddMinutes(20 * $i)
        }
        Update-RunnerAttemptHistory -RuntimeDir $script:Dir -MaxAttempts 3 -MaxOlderFailures 2 -Confirm:$false
        $index = Read-AttemptIndex -RuntimeDir $script:Dir
        @($index.attempts | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:p5', 'runner:p4', 'runner:p3')
        @($index.olderFailures | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:f3', 'runner:f2')
        foreach ($kept in 'p5', 'p4', 'p3', 'f3', 'f2') {
            Test-Path -LiteralPath (Join-Path $script:Dir $paths[$kept]) | Should -BeTrue -Because "$kept is in the index, so its evidence stays"
        }
        foreach ($gone in 'p2', 'p1', 'f1') {
            Test-Path -LiteralPath (Split-Path -Parent (Join-Path $script:Dir $paths[$gone])) | Should -BeFalse -Because "$gone is past both bounds"
        }
        $index.olderFailures[0].description | Should -Be 'failure of runner:f3'
        $index.olderFailures[0].transcriptPath | Should -Match '/config-gate\.log$'
    }

    It 'keeps a failure between passing cycles readable after the window''s worth of passes, with the default bounds' {
        $start = [datetime]::UtcNow.AddHours(-8)
        $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation 'runner:0' -Passed $true -FinishedUtc $start
        $failure = New-AttemptRecord -RuntimeDir $script:Dir -Generation 'runner:1' -Passed $false -FinishedUtc $start.AddMinutes(17)
        foreach ($n in 2..21) { $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation "runner:$n" -Passed $true -FinishedUtc $start.AddMinutes(17 * $n) }
        Update-RunnerAttemptHistory -RuntimeDir $script:Dir -Confirm:$false
        $index = Read-AttemptIndex -RuntimeDir $script:Dir
        @($index.attempts).Count | Should -Be 20 -Because 'the latest attempts stay at the window a reader may bound them to'
        @($index.attempts | Where-Object { -not $_.passed }).Count | Should -Be 0
        @($index.olderFailures | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:1')
        Test-Path -LiteralPath (Join-Path $script:Dir $failure) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:Dir 'runner-attempts') -Directory).Count | Should -Be 21 -Because 'the oldest pass is retired'
    }

    It 'bounds a failure no attempt has passed after by the window' {
        $start = [datetime]::UtcNow.AddHours(-3)
        foreach ($n in 1..5) { $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation "runner:$n" -Passed $false -FinishedUtc $start.AddMinutes(10 * $n) }
        Update-RunnerAttemptHistory -RuntimeDir $script:Dir -MaxAttempts 2 -Confirm:$false
        $index = Read-AttemptIndex -RuntimeDir $script:Dir
        @($index.attempts | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:5', 'runner:4')
        @($index.olderFailures).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:Dir 'runner-attempts') -Directory).Count | Should -Be 2
    }

    It 'retires older failures past their own bound, oldest first' {
        $start = [datetime]::UtcNow.AddHours(-3)
        foreach ($n in 1..4) { $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation "runner:f$n" -Passed $false -FinishedUtc $start.AddMinutes(10 * $n) }
        $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation 'runner:p' -Passed $true -FinishedUtc $start.AddMinutes(60)
        Update-RunnerAttemptHistory -RuntimeDir $script:Dir -MaxAttempts 1 -MaxOlderFailures 2 -Confirm:$false
        $index = Read-AttemptIndex -RuntimeDir $script:Dir
        @($index.attempts | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:p')
        @($index.olderFailures | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:f4', 'runner:f3')
        @(Get-ChildItem -LiteralPath (Join-Path $script:Dir 'runner-attempts') -Directory).Count | Should -Be 3
    }

    It 'keeps no older failures when their bound is zero' {
        $start = [datetime]::UtcNow.AddHours(-3)
        $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation 'runner:f' -Passed $false -FinishedUtc $start
        $null = New-AttemptRecord -RuntimeDir $script:Dir -Generation 'runner:p' -Passed $true -FinishedUtc $start.AddMinutes(10)
        Update-RunnerAttemptHistory -RuntimeDir $script:Dir -MaxAttempts 1 -MaxOlderFailures 0 -Confirm:$false
        @((Read-AttemptIndex -RuntimeDir $script:Dir).olderFailures).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:Dir 'runner-attempts') -Directory).Count | Should -Be 1
    }
}
