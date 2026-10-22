<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4246d32b-8525-4736-8ed7-b3883787ca97
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
    Throw-based assertions (Pester 5+). The builder
    is pure, so no cycle event stream / disk is involved; a fixed -Timestamp
    keeps the assertions deterministic. The schema-validity case proves a
    `degradation` event passes Test-CycleEventSchema with zero violations.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Log.psm1'
$evtPath    = Join-Path $here 'Test.EventSchema.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module $evtPath    -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# --- REGION: Fixture helpers
# See https://yuruna.link/42e220c4-0014
function New-ArchiveFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test must seed/save the Yuruna.Log cross-module globals Stop-LogFile reads.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: temp dir + seed files + saves globals; no production state.')]
    [OutputType([hashtable])]
    param([string]$RootFailureJson)
    $saved = @{ Cycle = $global:__YurunaCycleFolder; LogFile = $global:__YurunaLogFile; LogDir = $env:YURUNA_LOG_DIR; RunId = $global:__YurunaRunId }
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
    # The remediation archive matches on this, so a fixture without one cannot
    # tell "produced by this cycle" from "left by an earlier one".
    $runId = [guid]::NewGuid().ToString()
    $global:__YurunaRunId = $runId
    return @{ Tmp = $tmp; Saved = $saved; Cycle = $cycle; Final = ($cycle -replace '\.incomplete$', ''); RunId = $runId }
}

# The cycle-folder handle is the mirror's default destination, so proving the
# "no handle" branch means unsetting it; that is the only reason to touch the
# global outside the fixture pair.
function Clear-CycleFolderHandle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test must clear the Yuruna.Log cross-module cycle-folder handle to reach the no-handle branch.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: clears one in-memory global that Restore-ArchiveFixture puts back; no production state.')]
    param()
    $global:__YurunaCycleFolder = $null
}

function Restore-ArchiveFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test teardown: restores the Yuruna.Log cross-module globals it saved.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: restores saved globals/env and removes the temp dir.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $global:__YurunaCycleFolder = $Fixture.Saved.Cycle
    $global:__YurunaLogFile     = $Fixture.Saved.LogFile
    $global:__YurunaRunId       = $Fixture.Saved.RunId
    $env:YURUNA_LOG_DIR         = $Fixture.Saved.LogDir
    if ($Fixture.Tmp) { Remove-Item -LiteralPath $Fixture.Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

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
        $r = New-YurunaDegradationRecord -Dependency 'caching-proxy-service' -Primary 'squid' -Fallback 'direct-internet' -Timestamp '2026-06-08T12:00:00Z'
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
                ('{"schemaVersion":1,"runId":"' + $fx.RunId + '","failureClass":"ocr_timeout","recommendation":"restart_from_snapshot","autoApply":false}'),
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'fail' -Reason 'remediation-archive-test' -Confirm:$false
            Assert-True (Test-Path (Join-Path $fx.Final 'last_remediation.json')) 'last_remediation.json archived into the cycle folder'
            $man = Get-Content -Raw (Join-Path $fx.Final 'manifest.json') | ConvertFrom-Json
            $entry = @($man.artifacts | Where-Object { $_.path -eq 'last_remediation.json' })
            Assert-Equal -Expected 1 -Actual $entry.Count -Because 'manifest lists last_remediation.json exactly once'
            Assert-Equal -Expected 'remediation' -Actual $entry[0].kind -Because 'manifest classifies it as kind=remediation'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    # The log root outlives the cycle, and the dispatcher does not run for every
    # failure -- one that stops before classification leaves the root file
    # untouched. Archiving on presence then gives this cycle the PREVIOUS
    # cycle's recommendation, which reads as a diagnosis of a failure it never
    # saw. A non-pass outcome is not evidence of ownership; the run stamp is.
    It 'does NOT archive a last_remediation.json left by an earlier run, even on a non-pass outcome' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"unknown"}'
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Tmp 'last_remediation.json'),
                '{"schemaVersion":1,"runId":"11111111-2222-3333-4444-555555555555","failureClass":"unknown","recommendation":"pause_and_inspect","autoApply":false}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'fail' -Reason 'inherited-remediation-test' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_remediation.json'))) 'a remediation stamped with another run must not be archived'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'does NOT archive an unstamped last_remediation.json (predates the run stamp)' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"unknown"}'
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Tmp 'last_remediation.json'),
                '{"schemaVersion":1,"failureClass":"unknown","recommendation":"pause_and_inspect","autoApply":false}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'fail' -Reason 'unstamped-remediation-test' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_remediation.json'))) 'an unstamped remediation cannot be shown to belong to this cycle'
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

    # The record a cycle actually failed on is routinely gone from the log root
    # by the time the cycle ends: every sequence start clears it there, so a host
    # running several guests per cycle loses a non-final guest's record before
    # anything reads it. The mirror the writers take at classification time is
    # then the only copy, and the cycle-end sweep must keep it rather than
    # conclude from an empty log root that nothing failed.
    It 'keeps a mirror written during the cycle when the root copy has since been cleared' {
        $fx = New-ArchiveFixture
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Cycle 'last_failure.json'),
                '{"schemaVersion":2,"guestKey":"guest.mirrored","failureClass":"provisioning_failure"}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'fail' -Reason 'cleared-root-test' -Confirm:$false
            $archived = Join-Path $fx.Final 'last_failure.json'
            Assert-True (Test-Path $archived) 'the mirror is the only copy of this cycle failure and must survive the cycle end'
            Assert-Match 'guest.mirrored' (Get-Content -Raw $archived) 'the surviving record must be the one this cycle wrote'
            $man = Get-Content -Raw (Join-Path $fx.Final 'manifest.json') | ConvertFrom-Json
            $entry = @($man.artifacts | Where-Object { $_.path -eq 'last_failure.json' })
            Assert-Equal -Expected 1 -Actual $entry.Count -Because 'manifest lists last_failure.json exactly once, so a re-copy cannot double-list it'
            Assert-Equal -Expected 'failure' -Actual $entry[0].kind -Because 'manifest classifies the surviving record as kind=failure'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    # A cycle that recovered -- a warm resume re-ran the failed sequence and it
    # passed -- still holds the first attempt's mirror. A record in the cycle
    # folder means "this cycle failed", so a pass has to clear it or every
    # recovery is filed as a failure.
    It 'clears a mirror on a pass outcome' {
        $fx = New-ArchiveFixture
        try {
            [System.IO.File]::WriteAllText(
                (Join-Path $fx.Cycle 'last_failure.json'),
                '{"schemaVersion":2,"guestKey":"guest.recovered","failureClass":"ocr_timeout"}',
                [System.Text.UTF8Encoding]::new($false))
            Stop-LogFile -Outcome 'pass' -Reason 'recovered' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_failure.json'))) 'a recovered cycle must not be left looking failed'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }
}

Describe 'Copy-CycleFailureRecord' {

    It 'mirrors the log root record into the cycle folder' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ssh_timeout","vmName":"","guestKey":""}'
        try {
            $cycle = "$($fx.Final).incomplete"
            Assert-True (Copy-CycleFailureRecord) 'a fresh record must be mirrored'
            Assert-True (Test-Path (Join-Path $cycle 'last_failure.json')) 'the cycle-folder copy is what makes the cycle self-describing'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'also mirrors into the folder of the guest the record names' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ssh_timeout","vmName":"vm-a","guestKey":"guest.a"}'
        try {
            $cycle = "$($fx.Final).incomplete"
            $null = Copy-CycleFailureRecord
            $guestCopy = Join-Path $cycle 'vm-a/last_failure.json'
            Assert-True (Test-Path $guestCopy) 'the guest copy is the one that cannot be attributed to the wrong guest'
            $rec = Get-Content -LiteralPath $guestCopy -Raw | ConvertFrom-Json
            Assert-Equal -Expected 'ssh_timeout' -Actual $rec.failureClass
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'keeps two guests of one cycle in separate records' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"provisioning_failure","vmName":"vm-a","guestKey":"guest.a"}'
        try {
            $cycle = "$($fx.Final).incomplete"
            $null = Copy-CycleFailureRecord
            # The next guest's sequence start clears the root, then its own
            # failure writes a record naming it.
            $rootRecord = Join-Path $fx.Tmp 'last_failure.json'
            Remove-Item -LiteralPath $rootRecord -Force
            [System.IO.File]::WriteAllText($rootRecord, '{"schemaVersion":2,"failureClass":"lab_dependency_down","vmName":"vm-b","guestKey":"guest.b"}', [System.Text.UTF8Encoding]::new($false))
            $null = Copy-CycleFailureRecord
            $a = Get-Content -LiteralPath (Join-Path $cycle 'vm-a/last_failure.json') -Raw | ConvertFrom-Json
            $b = Get-Content -LiteralPath (Join-Path $cycle 'vm-b/last_failure.json') -Raw | ConvertFrom-Json
            Assert-Equal -Expected 'provisioning_failure' -Actual $a.failureClass -Because 'the first guest keeps its own cause'
            Assert-Equal -Expected 'lab_dependency_down'  -Actual $b.failureClass
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'leaves a record that names no guest in the cycle folder alone' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"host_condition_unmet","vmName":"","guestKey":""}'
        try {
            $cycle = "$($fx.Final).incomplete"
            $null = Copy-CycleFailureRecord
            Assert-True (Test-Path (Join-Path $cycle 'last_failure.json')) 'a host-level failure still describes the cycle'
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $cycle -Directory -ErrorAction SilentlyContinue).Count -Because 'no guest is named, so no per-guest folder is invented'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'refuses a root copy older than the mirror it would overwrite' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ssh_timeout","vmName":"vm-a","guestKey":"guest.a"}'
        try {
            $cycle = "$($fx.Final).incomplete"
            $null = Copy-CycleFailureRecord
            # An earlier RUN's record nothing wiped: older than this cycle's own.
            $rootRecord = Join-Path $fx.Tmp 'last_failure.json'
            [System.IO.File]::WriteAllText($rootRecord, '{"schemaVersion":2,"failureClass":"from_an_earlier_run","vmName":"vm-a","guestKey":"guest.a"}', [System.Text.UTF8Encoding]::new($false))
            (Get-Item -LiteralPath $rootRecord).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-4)
            Assert-True (-not (Copy-CycleFailureRecord)) 'an older root copy is not this cycle evidence'
            foreach ($copy in @((Join-Path $cycle 'last_failure.json'), (Join-Path $cycle 'vm-a/last_failure.json'))) {
                $rec = Get-Content -LiteralPath $copy -Raw | ConvertFrom-Json
                Assert-Equal -Expected 'ssh_timeout' -Actual $rec.failureClass -Because "$copy must keep this cycle's own record"
            }
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'returns false without throwing when the record already IS the cycle-folder copy' {
        # Bootstrap stages run before Start-LogFile and write straight into the
        # cycle folder; copying a file onto itself throws.
        $fx = New-ArchiveFixture -RootFailureJson ''
        try {
            $cycle = "$($fx.Final).incomplete"
            [System.IO.File]::WriteAllText((Join-Path $cycle 'last_failure.json'), '{"schemaVersion":2,"failureClass":"bootstrap_sync","vmName":"","guestKey":""}', [System.Text.UTF8Encoding]::new($false))
            Assert-True (-not (Copy-CycleFailureRecord -LogDir $cycle)) 'same source and destination is a no-op, not a crash'
            Assert-True (Test-Path (Join-Path $cycle 'last_failure.json')) 'and the record is still there'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'returns false when there is no record and when there is no log directory' {
        $fx = New-ArchiveFixture -RootFailureJson ''
        try {
            Assert-True (-not (Copy-CycleFailureRecord)) 'nothing to mirror'
            $env:YURUNA_LOG_DIR = ''
            Assert-True (-not (Copy-CycleFailureRecord)) 'nowhere to mirror from'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'catalogs both copies in the cycle manifest, each with its own kind' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ssh_timeout","vmName":"vm-a","guestKey":"guest.a"}'
        try {
            Stop-LogFile -Outcome 'fail' -Reason 'guest failure' -Confirm:$false
            $manifest = Get-Content -LiteralPath (Join-Path $fx.Final 'manifest.json') -Raw | ConvertFrom-Json
            $cycleEntry = @($manifest.artifacts | Where-Object { $_.path -eq 'last_failure.json' })
            $guestEntry = @($manifest.artifacts | Where-Object { $_.path -eq 'vm-a/last_failure.json' })
            Assert-Equal -Expected 1 -Actual $cycleEntry.Count -Because 'exactly one cycle-level record, never several competing for the answer'
            Assert-Equal -Expected 'failure' -Actual $cycleEntry[0].kind
            Assert-Equal -Expected 1 -Actual $guestEntry.Count
            Assert-Equal -Expected 'failure-guest' -Actual $guestEntry[0].kind -Because 'a per-guest copy is not the cycle verdict'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'clears every copy on a pass outcome, the per-guest one included' {
        # A warm resume re-ran the failed sequence and it passed: the cycle has
        # no failure of its own, so nothing under its folder may claim one.
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"failureClass":"ssh_timeout","vmName":"vm-a","guestKey":"guest.a"}'
        try {
            $null = Copy-CycleFailureRecord
            Remove-Item -LiteralPath (Join-Path $fx.Tmp 'last_failure.json') -Force
            Stop-LogFile -Outcome 'pass' -Reason 'recovered' -Confirm:$false
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'last_failure.json'))) 'a recovered cycle must not look failed'
            Assert-True (-not (Test-Path (Join-Path $fx.Final 'vm-a/last_failure.json'))) 'nor may the guest folder still hold the first attempt'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }

    It 'reports no copy when no cycle folder is open' {
        $fx = New-ArchiveFixture -RootFailureJson '{"schemaVersion":2,"guestKey":"guest.a"}'
        try {
            Clear-CycleFolderHandle
            Assert-False (Copy-CycleFailureRecord) 'a stage running outside a cycle has nowhere to mirror to'
        } finally { Restore-ArchiveFixture -Fixture $fx }
    }
}


Describe 'Format-CycleFolderBaseName (hostname-free cycle folder)' {

    It 'uses the opaque hostId as the 4th segment, not the hostname' {
        $name = Format-CycleFolderBaseName -CycleNumber 1058 -CycleStartUtc '2026-06-10T15:46:13Z' -HostId '4253419c1f0b45a08260f36a1521a857'
        Assert-Equal -Expected '001058.2026-06-10.15-46-13.4253419c1f0b45a08260f36a1521a857' -Actual $name -Because 'hostId in the 4th segment, zero-padded cycle number'
    }

    It 'keeps the 4-segment shape the rotation/recovery patterns require' {
        $name = Format-CycleFolderBaseName -CycleNumber 1 -CycleStartUtc '2026-06-10T15:46:13Z' -HostId '4253419c1f0b45a08260f36a1521a857'
        Assert-True ($name -match '^\d{6}\..+\..+\..+$') "must satisfy the recovery glob: $name"
    }

    It 'falls back to a placeholder (never empty / never the hostname) when no hostId is established' {
        $name = Format-CycleFolderBaseName -CycleNumber 1 -CycleStartUtc '2026-06-10T15:46:13Z' -HostId ''
        Assert-Equal -Expected '000001.2026-06-10.15-46-13.unknown-host' -Actual $name -Because 'empty hostId -> unknown-host placeholder'
        Assert-True ($name -match '^\d{6}\..+\..+\..+$') 'placeholder still satisfies the 4-segment pattern'
    }
}

Describe 'Add-OcrHistoryFrame keeps the earliest frames of a guest' {
    BeforeAll {
        function Add-ScriptedFrame {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: writes fixture frames under the test drive.')]
            param([string]$Directory, [Collections.Generic.Queue[string]]$Queue, [int]$Index, [int]$KeepEarliest)
            $path = Join-Path $Directory ('raw_{0:d3}.png' -f $Index)
            [IO.File]::WriteAllText($path, 'frame')
            [IO.File]::WriteAllText([IO.Path]::ChangeExtension($path, '.txt'), 'ocr')
            Add-OcrHistoryFrame -Queue $Queue -Path $path -Limit 2 -KeepEarliest $KeepEarliest
        }
        function Invoke-InCycleFolder {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
                Justification = 'Test must seed and restore the cycle-folder global Save-StepFailureEvidence reads.')]
            param([string]$CycleFolder, [string]$LogDir, [scriptblock]$Action)
            $saved = @{ Cycle = $global:__YurunaCycleFolder; LogDir = $env:YURUNA_LOG_DIR }
            try {
                $global:__YurunaCycleFolder = $CycleFolder
                $env:YURUNA_LOG_DIR = $LogDir
                $null = New-Item -ItemType Directory $LogDir -Force
                & $Action
            } finally {
                $global:__YurunaCycleFolder = $saved.Cycle
                $env:YURUNA_LOG_DIR = $saved.LogDir
            }
        }
    }
    It 'moves the first evicted frames aside with their OCR sidecars and deletes the rest' {
        $ring = Join-Path $TestDrive 'ring-keep'
        $null = New-Item -ItemType Directory $ring -Force
        $queue = [Collections.Generic.Queue[string]]::new()
        foreach ($index in 1..7) { Add-ScriptedFrame -Directory $ring -Queue $queue -Index $index -KeepEarliest 3 }
        @(Get-ChildItem $ring -Filter 'raw_*.png' -File).Name | Should -Be @('raw_006.png', 'raw_007.png')
        @(Get-ChildItem (Join-Path $ring 'earliest') -Filter 'raw_*.png' -File | Sort-Object Name).Name | Should -Be @('raw_001.png', 'raw_002.png', 'raw_003.png')
        Test-Path (Join-Path $ring 'earliest/raw_001.txt') | Should -BeTrue
        Test-Path (Join-Path $ring 'raw_004.png') | Should -BeFalse
        Test-Path (Join-Path $ring 'raw_004.txt') | Should -BeFalse
    }
    It 'keeps nothing aside when asked to keep nothing' {
        $ring = Join-Path $TestDrive 'ring-none'
        $null = New-Item -ItemType Directory $ring -Force
        $queue = [Collections.Generic.Queue[string]]::new()
        foreach ($index in 1..4) { Add-ScriptedFrame -Directory $ring -Queue $queue -Index $index -KeepEarliest 0 }
        Test-Path (Join-Path $ring 'earliest') | Should -BeFalse
    }
    It 'copies the earliest frames into the per-attempt failure evidence' {
        $cycle = Join-Path $TestDrive 'cycle'
        $earliest = Join-Path $cycle 'screens_vm-01/earliest'
        $null = New-Item -ItemType Directory $earliest -Force
        [IO.File]::WriteAllText((Join-Path $earliest 'raw_001.png'), 'frame')
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step1-attempt1' -Confirm:$false
        }
        $relative | Should -Be 'vm-01/failed_step1-attempt1'
        Test-Path (Join-Path $cycle 'vm-01/failed_step1-attempt1/earliest/raw_001.png') | Should -BeTrue
    }
    It 'retains VM observations when no screenshot was available' {
        $cycle = Join-Path $TestDrive 'diagnostic-only'
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'diagnostic-log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step2-attempt1' -Confirm:$false -DiagnosticRecord @{
                vmName = 'vm-01'; hostType = 'host.ubuntu.kvm'; architecture = 'Arm64'; vmState = 'running'; unrelatedSecret = 'fixture-secret-value'
                consoleSecondOpinion = @{ Verdict = 'guest-wedged'; QemuPid = 12; CpuPercent = 782; FramesChanged = $false; unrelatedSecret = 'fixture-secret-value' }
            }
        }
        $relative | Should -Be 'vm-01/failed_step2-attempt1'
        $record = Get-Content -Raw -LiteralPath (Join-Path $cycle "$relative/vm-diagnostics.json") | ConvertFrom-Json
        $record.vmName | Should -Be 'vm-01'
        $record.hostType | Should -Be 'host.ubuntu.kvm'
        $record.architecture | Should -Be 'Arm64'
        $record.vmState | Should -Be 'running'
        $record.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
        $record.consoleSecondOpinion.FramesChanged | Should -BeFalse
        (Get-Content -Raw -LiteralPath (Join-Path $cycle "$relative/vm-diagnostics.json")) | Should -Not -Match 'fixture-secret-value|unrelatedSecret'
    }
    It 'captures bounded UTM control evidence beside the failed attempt before returning it' {
        . (Get-Module Test.Log) {
            function New-YurunaDeadline {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub: returns an in-memory deadline marker; no external state.')]
                param($TotalMilliseconds)
                @{ Budget = $TotalMilliseconds }
            }
            function Save-UtmControlSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                param($OutputDirectory, $Trigger, $VMName, $LogTimeoutSeconds, $LogWindowMinutes, $Deadline, [switch]$SkipScreenshot)
                $null = $PSCmdlet.ShouldProcess($OutputDirectory, 'Fixture snapshot')
                $script:SnapshotArguments = @{ Directory = $OutputDirectory; Trigger = $Trigger; VMName = $VMName; LogTimeout = $LogTimeoutSeconds; LogWindow = $LogWindowMinutes; Budget = $Deadline.Budget; SkipScreenshot = [bool]$SkipScreenshot }
                [IO.File]::WriteAllText((Join-Path $OutputDirectory 'utm-control-snapshot.startup-timeout.json'), '{"captured":true}')
                [pscustomobject]@{ Written = $true; Reason = 'written'; Path = (Join-Path $OutputDirectory 'utm-control-snapshot.startup-timeout.json') }
            }
        }
        $cycle = Join-Path $TestDrive 'utm-diagnostic'
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'utm-log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step2-attempt1' -Confirm:$false -DiagnosticRecord @{
                vmName = 'vm-01'; hostType = 'host.macos.utm'; architecture = 'Arm64'; vmState = 'running'; captureStartupSnapshot = $true
                consoleSecondOpinion = @{ Verdict = 'guest-wedged'; CpuPercent = 782 }
            }
        }
        $arguments = & (Get-Module Test.Log) { $script:SnapshotArguments }
        $arguments.VMName | Should -Be 'vm-01'
        $arguments.Trigger | Should -Be 'startup-timeout'
        $arguments.LogTimeout | Should -Be 10
        $arguments.LogWindow | Should -Be 60 -Because 'the first startup wait can exceed forty minutes before evidence is collected'
        $arguments.Budget | Should -Be 30000
        $arguments.SkipScreenshot | Should -BeTrue -Because 'the native screenshot API does not consume the shared deadline'
        Test-Path (Join-Path $cycle "$relative/utm-control-snapshot.startup-timeout.json") | Should -BeTrue
        $record = Get-Content -Raw -LiteralPath (Join-Path $cycle "$relative/vm-diagnostics.json") | ConvertFrom-Json
        $record.controlSnapshot.written | Should -BeTrue
    }
    It 'keeps the observation record when optional native evidence capture fails' {
        . (Get-Module Test.Log) {
            function Save-UtmControlSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                param($OutputDirectory, $Trigger, $VMName, $LogTimeoutSeconds, $LogWindowMinutes, $Deadline, [switch]$SkipScreenshot)
                $null = @($OutputDirectory, $Trigger, $VMName, $LogTimeoutSeconds, $LogWindowMinutes, $Deadline, $SkipScreenshot)
                $null = $PSCmdlet.ShouldProcess('fixture', 'Snapshot failure')
                throw 'fixture diagnostic failure'
            }
        }
        $cycle = Join-Path $TestDrive 'utm-diagnostic-failure'
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'utm-failed-log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step2-attempt1' -Confirm:$false -DiagnosticRecord @{
                vmName = 'vm-01'; hostType = 'host.macos.utm'; captureStartupSnapshot = $true; consoleSecondOpinion = @{ Verdict = 'guest-wedged' }
            }
        }
        $relative | Should -Be 'vm-01/failed_step2-attempt1'
        $record = Get-Content -Raw -LiteralPath (Join-Path $cycle "$relative/vm-diagnostics.json") | ConvertFrom-Json
        $record.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
        $record.controlSnapshot.written | Should -BeFalse
        $record.controlSnapshot.reason | Should -Match 'fixture diagnostic failure'
    }
    It 'does not collect native evidence or write files during WhatIf' {
        . (Get-Module Test.Log) {
            $script:SnapshotArguments = $null
            function Save-UtmControlSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                param()
                $null = $PSCmdlet.ShouldProcess('fixture', 'Forbidden preview snapshot')
                throw 'WhatIf must not invoke this capability'
            }
        }
        $cycle = Join-Path $TestDrive 'diagnostic-preview'
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'preview-log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step2-attempt1' -WhatIf -DiagnosticRecord @{ vmName = 'vm-01'; hostType = 'host.macos.utm'; captureStartupSnapshot = $true }
        }
        $relative | Should -BeNullOrEmpty
        Test-Path $cycle | Should -BeFalse
        & (Get-Module Test.Log) { $script:SnapshotArguments } | Should -BeNullOrEmpty
    }
    It 'retains an ordinary wait observation without collecting startup-only native evidence' {
        . (Get-Module Test.Log) {
            $script:OrdinarySnapshotCalls = 0
            function New-YurunaDeadline {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub: returns an in-memory deadline marker; no external state.')]
                param($TotalMilliseconds)
                @{ Budget = $TotalMilliseconds }
            }
            function Save-UtmControlSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                param($OutputDirectory, $Trigger, $VMName, $LogTimeoutSeconds, $Deadline)
                $null = @($Trigger, $VMName, $LogTimeoutSeconds, $Deadline)
                $null = $PSCmdlet.ShouldProcess($OutputDirectory, 'Fixture snapshot')
                $script:OrdinarySnapshotCalls++
                [pscustomobject]@{ Written = $true; Reason = 'written'; Path = 'fixture-native.json' }
            }
        }
        $cycle = Join-Path $TestDrive 'ordinary-wait'
        $relative = Invoke-InCycleFolder -CycleFolder $cycle -LogDir (Join-Path $TestDrive 'ordinary-log') -Action {
            Save-StepFailureEvidence -VMName 'vm-01' -Label 'step8-attempt1' -Confirm:$false -DiagnosticRecord @{
                vmName = 'vm-01'; hostType = 'host.macos.utm'; consoleSecondOpinion = @{ Verdict = 'guest-wedged' }
            }
        }
        $relative | Should -Be 'vm-01/failed_step8-attempt1'
        $record = Get-Content -Raw -LiteralPath (Join-Path $cycle "$relative/vm-diagnostics.json") | ConvertFrom-Json
        $record.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
        & (Get-Module Test.Log) { $script:OrdinarySnapshotCalls } | Should -Be 0
        $record.controlSnapshot | Should -BeNullOrEmpty
    }
}
