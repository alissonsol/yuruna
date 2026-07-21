<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e9c5b7-2d18-4a3f-bc60-7f1e9a8d2c40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry degradation resilience pester
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
    Pester coverage for the graceful-degradation contract in
    Test.Log.psm1: New-YurunaDegradationRecord (the pure event-record
    builder) and its schema validity against Test.EventSchema.
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). The builder
    is pure, so no cycle event stream / disk is involved; a fixed -Timestamp
    keeps the assertions deterministic. The schema-validity case proves a
    `degradation` event passes Test-CycleEventSchema with zero violations.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Log.psm1'
$evtPath    = Join-Path $here 'Test.EventSchema.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module $evtPath    -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# The archive fixture lives at FILE scope, not inside its Describe: a Describe
# body is executed during discovery and everything it declares is discarded
# before any It runs, so a helper defined there is a CommandNotFoundException by
# the time the It blocks call it.
#
# All $global:__Yuruna* access (the Yuruna.Log cross-module channels Stop-LogFile
# consumes) is confined to these two suppressed helpers so the It blocks stay
# clean; the production Copy-FailureArtifactsToStatusLog suppresses
# PSAvoidGlobalVars for the same channels.
function New-ArchiveFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test must seed/save the Yuruna.Log cross-module globals Stop-LogFile reads.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: temp dir + seed files + saves globals; no production state.')]
    [OutputType([hashtable])]
    param([string]$RootFailureJson)
    $saved = @{ Cycle = $global:__YurunaCycleFolder; LogFile = $global:__YurunaLogFile; LogDir = $env:YURUNA_LOG_DIR }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-archive-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $env:YURUNA_LOG_DIR = $tmp
    if ($RootFailureJson) {
        [System.IO.File]::WriteAllText((Join-Path $tmp 'last_failure.json'), $RootFailureJson, [System.Text.UTF8Encoding]::new($false))
    }
    $cycle = Join-Path $tmp '000001.2026-06-08.00-00-00.4253419c1f0b45a08260f36a1521a857.incomplete'
    New-Item -ItemType Directory -Path $cycle -Force | Out-Null
    $global:__YurunaCycleFolder = $cycle
    $global:__YurunaLogFile = $null
    return @{ Tmp = $tmp; Saved = $saved; Final = ($cycle -replace '\.incomplete$', '') }
}

function Restore-ArchiveFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test teardown: restores the Yuruna.Log cross-module globals it saved.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: restores saved globals/env and removes the temp dir.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $global:__YurunaCycleFolder = $Fixture.Saved.Cycle
    $global:__YurunaLogFile     = $Fixture.Saved.LogFile
    $env:YURUNA_LOG_DIR         = $Fixture.Saved.LogDir
    if ($Fixture.Tmp) { Remove-Item -LiteralPath $Fixture.Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'New-YurunaDegradationRecord' {

    It 'builds the degradation event with all contract fields' {
        $r = New-YurunaDegradationRecord -Dependency 'keystroke-mechanism' `
            -Primary 'ssh-sequence' -Fallback 'gui-sequence' `
            -Reason 'no ssh variant for start.ubuntu.yml' -Severity 'soft' `
            -Timestamp '2026-06-08T12:00:00Z'
        Assert-Equal -Expected 'degradation'          -Actual $r.event       -Because 'event name'
        Assert-Equal -Expected 'keystroke-mechanism'  -Actual $r.dependency  -Because 'dependency'
        Assert-Equal -Expected 'ssh-sequence'         -Actual $r.primary     -Because 'primary'
        Assert-Equal -Expected 'gui-sequence'         -Actual $r.fallback    -Because 'fallback'
        Assert-Equal -Expected 'no ssh variant for start.ubuntu.yml' -Actual $r.reason -Because 'reason'
        Assert-Equal -Expected 'soft'                 -Actual $r.severity    -Because 'severity'
        Assert-Equal -Expected '2026-06-08T12:00:00Z' -Actual $r.timestamp   -Because 'timestamp passthrough'
    }

    It 'defaults severity to soft and reason to empty' {
        $r = New-YurunaDegradationRecord -Dependency 'caching-proxy' -Primary 'squid' -Fallback 'direct-internet' -Timestamp '2026-06-08T12:00:00Z'
        Assert-Equal -Expected 'soft' -Actual $r.severity -Because 'default severity'
        Assert-Equal -Expected ''     -Actual $r.reason   -Because 'default reason'
    }

    It 'stamps a UTC Z timestamp when none is supplied' {
        $r = New-YurunaDegradationRecord -Dependency 'd' -Primary 'p' -Fallback 'f'
        Assert-True ($r.timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "timestamp shape: $($r.timestamp)"
    }

    It 'produces a record that passes the cycle-event schema with zero violations' {
        $r = New-YurunaDegradationRecord -Dependency 'capture-feed' -Primary 'live-framebuffer' `
            -Fallback 'console-restart' -Reason 'frozen feed' -Severity 'soft' -Timestamp '2026-06-08T12:00:00Z'
        $violations = @(Test-CycleEventSchema -Record $r)
        Assert-Equal -Expected 0 -Actual $violations.Count -Because "schema violations: $($violations -join '; ')"
    }

    It 'rejects an out-of-set severity at the parameter binder' {
        $threw = $false
        try { [void](New-YurunaDegradationRecord -Dependency 'd' -Primary 'p' -Fallback 'f' -Severity 'bogus') }
        catch { $threw = $true }
        Assert-True $threw 'ValidateSet should reject severity=bogus'
    }
}

Describe 'Stop-LogFile last_failure.json archiving' {

    It 'archives the cycle last_failure.json + manifests it as kind=failure on a non-pass outcome' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ocr_timeout","context":{"causeDetail":{"ocrTail":"yt2sqluser@host:~$"}}}'
        try {
            Stop-LogFile -Outcome 'fail' -Reason 'archive-test' -Confirm:$false
            Assert-True (Test-Path (Join-Path $fx.Final 'last_failure.json')) 'last_failure.json archived into the cycle folder'
            $man = Get-Content -Raw (Join-Path $fx.Final 'manifest.json') | ConvertFrom-Json
            $entry = @($man.artifacts | Where-Object { $_.path -eq 'last_failure.json' })
            Assert-Equal -Expected 1 -Actual $entry.Count -Because 'manifest lists last_failure.json exactly once'
            Assert-Equal -Expected 'failure' -Actual $entry[0].kind -Because 'manifest classifies it as kind=failure'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'archives last_remediation.json + manifests it as kind=remediation on a non-pass outcome' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ocr_timeout"}'
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Tmp 'last_remediation.json'),
                '{"schemaVersion":1,"failureClass":"ocr_timeout","recommendation":"restart_from_snapshot","autoApply":false}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'fail' -Reason 'remediation-archive-test' -Confirm:$false
            Assert-True (Test-Path (Join-Path $fx.Final 'last_remediation.json')) 'last_remediation.json archived into the cycle folder'
            $man = Get-Content -Raw (Join-Path $fx.Final 'manifest.json') | ConvertFrom-Json
            $entry = @($man.artifacts | Where-Object { $_.path -eq 'last_remediation.json' })
            Assert-Equal -Expected 1 -Actual $entry.Count -Because 'manifest lists last_remediation.json exactly once'
            Assert-Equal -Expected 'remediation' -Actual $entry[0].kind -Because 'manifest classifies it as kind=remediation'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'does NOT archive a (stale) last_remediation.json on a pass outcome' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"unknown"}'
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Tmp 'last_remediation.json'),
                '{"schemaVersion":1,"failureClass":"unknown","recommendation":"pause_and_inspect","autoApply":false}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'pass' -Reason 'clean' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_remediation.json'))) 'a passing cycle must not archive a stale last_remediation.json'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'does NOT archive a (stale) last_failure.json on a pass outcome' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"unknown"}'
        try {
            Stop-LogFile -Outcome 'pass' -Reason 'clean' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_failure.json'))) 'a passing cycle must not archive a stale last_failure.json'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }
}

Describe 'Format-CycleFolderBaseName (hostname-free cycle folder)' {

    It 'uses the opaque hostId as the 4th segment, not the hostname' {
        $name = Format-CycleFolderBaseName -CycleNumber 1058 -CycleId '2026-06-10T15:46:13Z' -HostId '4253419c1f0b45a08260f36a1521a857'
        Assert-Equal -Expected '001058.2026-06-10.15-46-13.4253419c1f0b45a08260f36a1521a857' -Actual $name -Because 'hostId in the 4th segment, zero-padded cycle number'
    }

    It 'keeps the 4-segment shape the rotation/recovery patterns require' {
        $name = Format-CycleFolderBaseName -CycleNumber 1 -CycleId '2026-06-10T15:46:13Z' -HostId '4253419c1f0b45a08260f36a1521a857'
        Assert-True ($name -match '^\d{6}\..+\..+\..+$') "must satisfy the recovery glob: $name"
    }

    It 'falls back to a placeholder (never empty / never the hostname) when no hostId is established' {
        $name = Format-CycleFolderBaseName -CycleNumber 1 -CycleId '2026-06-10T15:46:13Z' -HostId ''
        Assert-Equal -Expected '000001.2026-06-10.15-46-13.unknown-host' -Actual $name -Because 'empty hostId -> unknown-host placeholder'
        Assert-True ($name -match '^\d{6}\..+\..+\..+$') 'placeholder still satisfies the 4-segment pattern'
    }
}
