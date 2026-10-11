<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42b72cec-e0ff-41c1-b348-08961daa46af
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery ledger attempt-budget pester
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
    Pins the recovery ledger: what is written, what a restart still sees, and the
    rules that keep the runner from repeating a repair without bound.
.DESCRIPTION
    A repair is safe to automate only while the runner remembers having tried it.
    These cases drive the ledger file (append, torn lines, redaction, compaction),
    the attempt budget (restart, scopes, expiry, unfinished attempts), the registry
    and planner, and the planning entry point, against temporary directories and
    toy actions. Nothing touches a real runtime directory, a repository or the
    network.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The module finds the event writer through the global command table, so the stand-in writer and the events it collects straddle that scope.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-T0 {
    [datetime]::new(2026, 10, 4, 12, 0, 0, [DateTimeKind]::Utc)
}

function New-ScratchDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temporary directory that AfterEach removes.')]
    param()
    return New-YurunaTestTempDir -Prefix 'recledger'
}

function New-TestResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory typed result.')]
    param(
        [string]$FailureClass = 'wait_timeout',
        [string]$Stage = 'cycle',
        [string]$Reason = 'timed out'
    )
    return (New-RecoveryResult -EntryPoint 'runner' -CycleGeneration (('a' * 32) + ':4') -Outcome 'failed' -ExitCode 1 -FailureClass $FailureClass -Stage $Stage -Reason $Reason)
}

function New-TestContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory context.')]
    param()
    return @{ Calls = [System.Collections.Generic.List[string]]::new() }
}

function Register-ToyAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: registers an in-memory action.')]
    param(
        [string]$Name = 'toy_action',
        [scriptblock]$Applies = { $true },
        [scriptblock]$Precondition = { param($c) $c.Calls.Add('precondition'); @{ Ok = $true; Reason = 'go'; Evidence = @() } },
        [scriptblock]$Action = { param($c) $c.Calls.Add('action'); @{ Ok = $true; Reason = 'did-it'; Evidence = @() } },
        [scriptblock]$Postcondition = { param($c) $c.Calls.Add('postcondition'); @{ Ok = $true; Reason = 'verified'; Evidence = @() } },
        [scriptblock]$Rollback,
        [int]$MaxAttempts = 0,
        [bool]$SkipsFailurePause = $false
    )
    $splat = @{
        Name = $Name; Description = 'toy'; Applies = $Applies; Precondition = $Precondition; Action = $Action
        Postcondition = $Postcondition; MaxAttempts = $MaxAttempts; SkipsFailurePause = $SkipsFailurePause
    }
    if ($Rollback) { $splat['Rollback'] = $Rollback }
    Register-RecoveryAction @splat
}

function Add-TestLedgerLine {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$AttemptId,
        [Parameter(Mandatory)][datetime]$At,
        [string]$Fingerprint = 'fp1-0123456789abcdef',
        [string]$Action = 'toy_action',
        [int]$Attempt = 1
    )
    return (Add-RecoveryLedgerRecord -RuntimeDir $Dir -Now $At -Record @{
        kind = 'attempt'; phase = $Phase; attemptId = $AttemptId; fingerprint = $Fingerprint; action = $Action; attempt = $Attempt
    })
}

function Get-LedgerPhase {
    param([Parameter(Mandatory)][string]$Dir)
    return @((Read-RecoveryLedger -RuntimeDir $Dir).Records | Where-Object { $_.kind -eq 'attempt' } | ForEach-Object { [string]$_.phase })
}

function Get-LedgerLineText {
    param([Parameter(Mandatory)][string]$Dir)
    $path = Get-RecoveryLedgerPath -RuntimeDir $Dir
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @([System.IO.File]::ReadAllLines($path))
}
}

Describe 'Ledger file' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:LedgerPath = Get-RecoveryLedgerPath -RuntimeDir $script:Dir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lives in recovery.ledger.ndjson under the runtime directory' {
        $script:LedgerPath | Should -Be (Join-Path $script:Dir 'recovery.ledger.ndjson')
    }

    It 'appends one line and reads the record back' {
        $record = [ordered]@{
            kind = 'attempt'; phase = 'started'; attemptId = 'a1'; fingerprint = 'fp1-0123456789abcdef'; failureClass = 'wait_timeout'
            action = 'toy_action'; attempt = 2; generation = (('c' * 32) + ':7'); reason = 'go'
            evidence = @([ordered]@{ kind = 'file'; ref = 'a/b.lock'; note = 'old' })
        }
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record $record -Now (Get-T0) | Should -BeTrue
        @(Get-LedgerLineText -Dir $script:Dir).Count | Should -Be 1
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        $read.Skipped | Should -Be 0
        $read.Readable | Should -BeTrue
        @($read.Records).Count | Should -Be 1
        $r = $read.Records[0]
        $r.v | Should -Be 1
        $r.kind | Should -Be 'attempt'
        $r.phase | Should -Be 'started'
        $r.attemptId | Should -Be 'a1'
        $r.fingerprint | Should -Be 'fp1-0123456789abcdef'
        $r.failureClass | Should -Be 'wait_timeout'
        $r.action | Should -Be 'toy_action'
        $r.attempt | Should -Be 2
        $r.generation | Should -Be (('c' * 32) + ':7')
        $r.reason | Should -Be 'go'
        @($r.evidence).Count | Should -Be 1
        $r.evidence[0].ref | Should -Be 'a/b.lock'
    }

    It 'stamps v and a canonical UTC at, and keeps the lines in append order' {
        $t = Get-T0
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'one' -At $t | Should -BeTrue
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'one' -At $t.AddSeconds(90) | Should -BeTrue
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        $read.Records[0].at | Should -Be '2026-10-04T12:00:00Z'
        $read.Records[1].at | Should -Be '2026-10-04T12:01:30Z'
        $read.Records[0].v | Should -Be 1
        @($read.Records | ForEach-Object { $_.phase }) | Should -Be @('started', 'succeeded')
    }

    It 'stamps the current time when no time is given' {
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'resolved'; scope = 'all' } | Should -BeTrue
        $at = [datetime]::ParseExact((Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0].at, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        [math]::Abs(([datetime]::UtcNow - $at).TotalSeconds) | Should -BeLessThan 120
    }

    It 'always hands back at as text, never as a DateTime' {
        # ConvertFrom-Json turns an ISO timestamp into a DateTime, nested values included.
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Now (Get-T0) -Record @{
            kind = 'attempt'; phase = 'started'; attemptId = 'a1'; at = '2026-10-03T08:15:30Z'
            evidence = @([ordered]@{ kind = 'record'; ref = 'stamp'; note = '2026-10-03T08:15:30Z' })
        } | Should -BeTrue
        $r = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0]
        $r.at | Should -BeOfType [string]
        $r.at | Should -Be '2026-10-03T08:15:30Z'
        $r.evidence[0].note | Should -BeOfType [string]
        $r.evidence[0].note | Should -Be '2026-10-03T08:15:30Z'
    }

    It 'accepts a DateTime for at and stores canonical text' {
        $stamp = [datetime]::new(2026, 10, 3, 8, 15, 30, [DateTimeKind]::Utc)
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'resolved'; scope = 'all'; at = $stamp } | Should -BeTrue
        @(Get-LedgerLineText -Dir $script:Dir)[0] | Should -Match '"at":"2026-10-03T08:15:30Z"'
    }

    It 'replaces an at it cannot read with the time of writing, so the line stays usable' {
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Now (Get-T0) -Record @{ kind = 'resolved'; scope = 'all'; at = 'yesterday afternoon' } | Should -BeTrue
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        $read.Skipped | Should -Be 0
        $read.Records[0].at | Should -Be '2026-10-04T12:00:00Z'
    }

    It 'keeps the fields it does not know, after the ones it does' {
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Now (Get-T0) -Record @{ kind = 'attempt'; phase = 'started'; custom = 'kept'; extraNumber = 7 } | Should -BeTrue
        $r = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0]
        $r.custom | Should -Be 'kept'
        $r.extraNumber | Should -Be 7
        @(Get-LedgerLineText -Dir $script:Dir)[0] | Should -Match '^\{"v":1,"at":"2026-10-04T12:00:00Z","kind":"attempt","phase":"started",'
    }

    It 'writes UTF-8 without a BOM, one compact LF-terminated line per record' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'one' -At (Get-T0) | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'one' -At (Get-T0) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($script:LedgerPath)
        $bytes[0] | Should -Be ([byte][char]'{')
        $bytes[-1] | Should -Be 10
        @($bytes | Where-Object { $_ -eq 13 }).Count | Should -Be 0
        @($bytes | Where-Object { $_ -eq 10 }).Count | Should -Be 2
    }

    It 'does not modify the record the caller passed in' {
        $record = @{ kind = 'attempt'; phase = 'started' }
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record $record | Should -BeTrue
        $record.Keys.Count | Should -Be 2
        $record.ContainsKey('v') | Should -BeFalse
        $record.ContainsKey('at') | Should -BeFalse
    }

    It 'refuses a record with no kind, because the reader could never use it' {
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ phase = 'started' } | Should -BeFalse
        Test-Path -LiteralPath $script:LedgerPath | Should -BeFalse
    }

    It 'redacts credentials and opaque secrets in every string, nested ones included' {
        $hex = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Now (Get-T0) -Record @{
            kind = 'attempt'; phase = 'failed'; attemptId = 'a1'
            reason = "clone of https://deploy:s3cr3tPass@example.invalid/org/repo.git failed; password=hunter2 key $hex"
            evidence = @([ordered]@{ kind = 'command'; ref = 'git clone'; note = 'token=abc123def and https://bob@example.invalid/x' })
        } | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($script:LedgerPath)
        $text | Should -Not -Match 's3cr3tPass'
        $text | Should -Not -Match 'hunter2'
        $text | Should -Not -Match $hex
        $text | Should -Not -Match 'abc123def'
        $text | Should -Not -Match 'bob@'
        $r = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0]
        $r.reason | Should -Match 'https://\*\*\*@example\.invalid/org/repo\.git'
        $r.reason | Should -Match 'password=\*\*\*'
        $r.evidence[0].note | Should -Match 'token=\*\*\*'
    }

    It 'caps a free-text field at 300 characters' {
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'failed'; reason = ('x' * 1000) } | Should -BeTrue
        $reason = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0].reason
        $reason.Length | Should -Be 300
        $reason | Should -Match '\.\.\.$'
    }

    It 'bounds the evidence kept on one line' {
        $many = @(1..40 | ForEach-Object { [ordered]@{ kind = 'file'; ref = "f$_"; note = '' } })
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started'; evidence = $many } | Should -BeTrue
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records[0].evidence).Count | Should -Be 20
    }

    It 'returns false, and does not throw, when the runtime directory is missing' {
        $missing = Join-Path $script:Dir 'no-such-dir'
        { Add-RecoveryLedgerRecord -RuntimeDir $missing -Record @{ kind = 'attempt'; phase = 'started' } } | Should -Not -Throw
        Add-RecoveryLedgerRecord -RuntimeDir $missing -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeFalse
    }

    It 'returns false, and does not throw, when a directory stands where the ledger belongs' {
        New-Item -ItemType Directory -Path $script:LedgerPath | Out-Null
        { Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } } | Should -Not -Throw
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeFalse
    }

    It 'retries a sharing violation three times, 50 ms apart, then gives up without throwing' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        [System.IO.File]::WriteAllText($script:LedgerPath, '')
        $held = [System.IO.FileStream]::new($script:LedgerPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeFalse
        } finally {
            $held.Dispose()
        }
        Should -Invoke -CommandName Start-Sleep -ModuleName Test.RecoveryLedger -Times 3 -Exactly -ParameterFilter { $Milliseconds -eq 50 }
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeTrue -Because 'the lock is gone'
    }

    It 'writes nothing, and says so, while another writer holds the guard' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        $held = [System.IO.FileStream]::new((Join-Path $script:Dir 'recovery.ledger.guard'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeFalse
        } finally {
            $held.Dispose()
        }
        Test-Path -LiteralPath $script:LedgerPath | Should -BeFalse
        Should -Invoke -CommandName Start-Sleep -ModuleName Test.RecoveryLedger -Times 40 -Exactly -ParameterFilter { $Milliseconds -eq 50 } -Because 'the wait for a guard is bounded, 50 ms at a time'
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeTrue -Because 'the guard is free again'
    }

    It 'waits for a writer that lets go of the guard, then writes' {
        $held = [System.IO.FileStream]::new((Join-Path $script:Dir 'recovery.ledger.guard'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $job = Start-ThreadJob -ScriptBlock { Start-Sleep -Milliseconds 400; ($using:held).Dispose() }
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started'; attemptId = 'patient' } | Should -BeTrue
            $clock.Elapsed.TotalMilliseconds | Should -BeGreaterThan 250 -Because 'the guard was taken, so the write had to wait for it'
        } finally {
            $job | Wait-Job | Remove-Job -Force
            $held.Dispose()
        }
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records)[0].attemptId | Should -Be 'patient'
    }

    It 'lets go of the guard when the append itself fails' {
        New-Item -ItemType Directory -Path $script:LedgerPath | Out-Null
        Add-RecoveryLedgerRecord -RuntimeDir $script:Dir -Record @{ kind = 'attempt'; phase = 'started' } | Should -BeFalse
        $again = [System.IO.FileStream]::new((Join-Path $script:Dir 'recovery.ledger.guard'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $again.Dispose()
    }

    It 'reads a ledger that an editor gave a byte order mark, and goes on appending to it' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'first' -At (Get-T0) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($script:LedgerPath)
        [System.IO.File]::WriteAllBytes($script:LedgerPath, ([byte[]](0xEF, 0xBB, 0xBF) + $bytes))
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        @($read.Records).Count | Should -Be 1 -Because 'the first line may be the one that spent an attempt'
        $read.Skipped | Should -Be 0
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'first' -At (Get-T0) | Should -BeTrue
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records).Count | Should -Be 2
    }

    It 'appends while a reader has the file open' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'one' -At (Get-T0) | Out-Null
        $reader = [System.IO.File]::Open($script:LedgerPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'one' -At (Get-T0) | Should -BeTrue
        } finally {
            $reader.Dispose()
        }
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records).Count | Should -Be 2
    }

    It 'skips a torn last line, counts it, and never glues the next record onto it' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'one' -At (Get-T0) | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'one' -At (Get-T0) | Out-Null
        [System.IO.File]::AppendAllText($script:LedgerPath, '{"v":1,"at":"2026-10-04T12:0')
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        @($read.Records).Count | Should -Be 2
        $read.Skipped | Should -Be 1

        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'two' -At (Get-T0).AddMinutes(1) | Should -BeTrue
        $after = Read-RecoveryLedger -RuntimeDir $script:Dir
        @($after.Records).Count | Should -Be 3 -Because 'the new record must survive the fragment before it'
        $after.Skipped | Should -Be 1
        $after.Records[2].attemptId | Should -Be 'two'
    }

    It 'skips lines that are not usable records, and ignores blank lines' {
        $good = '{"v":1,"at":"2026-10-04T12:00:00Z","kind":"attempt","phase":"started","attemptId":"ok"}'
        $lines = @(
            '', '[1,2]', '42', '"text"', 'null', 'not json at all',
            '{"v":1,"at":"nonsense","kind":"attempt"}',
            '{"v":1,"at":"2026-10-04T12:00:00Z"}',
            '   ',
            $good
        )
        [System.IO.File]::WriteAllText($script:LedgerPath, ($lines -join "`n") + "`n")
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        @($read.Records).Count | Should -Be 1
        $read.Records[0].attemptId | Should -Be 'ok'
        $read.Skipped | Should -Be 7
    }

    It 'reads a missing ledger as empty and a directory in its place as unreadable' {
        $empty = Read-RecoveryLedger -RuntimeDir $script:Dir
        @($empty.Records).Count | Should -Be 0
        $empty.Skipped | Should -Be 0
        $empty.Readable | Should -BeTrue
        New-Item -ItemType Directory -Path $script:LedgerPath | Out-Null
        (Read-RecoveryLedger -RuntimeDir $script:Dir).Readable | Should -BeFalse
    }
}

Describe 'Several writers' {
    BeforeEach {
        $script:Dir = New-ScratchDir
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lose no line when processes append at the same moment' {
        # .NET appends at an end-of-file offset it tracks itself, so without the
        # guard two processes overwrite each other's lines and no call reports it.
        $worker = Join-Path $script:Dir 'worker.ps1'
        [System.IO.File]::WriteAllText($worker, @'
param([string]$Module, [string]$Dir, [int]$Id, [int]$Count)
Import-Module $Module -DisableNameChecking
Set-Content -LiteralPath (Join-Path $Dir "ready.$Id") -Value 'ready'
while (-not (Test-Path -LiteralPath (Join-Path $Dir 'go'))) { Start-Sleep -Milliseconds 5 }
$failed = 0
for ($i = 0; $i -lt $Count; $i++) {
    $ok = Add-RecoveryLedgerRecord -RuntimeDir $Dir -Record @{ kind = 'attempt'; phase = 'started'; attemptId = "w$Id-$i"; action = 'worker'; attempt = $i }
    if (-not $ok) { $failed++ }
}
exit $failed
'@)
        $pwsh = (Get-Process -Id $PID).Path
        $module = Join-Path $here 'Test.RecoveryLedger.psm1'
        $writers = 3
        $each = 40
        # -WindowStyle is a Windows-only Start-Process parameter: any other
        # edition throws NotSupportedException on it, and the child there has
        # no window to hide anyway.
        $spawn = @{ FilePath = $pwsh; PassThru = $true }
        if ($IsWindows) { $spawn.WindowStyle = 'Hidden' }
        $processes = foreach ($id in 1..$writers) {
            Start-Process @spawn -ArgumentList @('-NoProfile', '-File', $worker, '-Module', $module, '-Dir', $script:Dir, '-Id', $id, '-Count', $each)
        }
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(90)
            while (@(Get-ChildItem -LiteralPath $script:Dir -Filter 'ready.*').Count -lt $writers -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            @(Get-ChildItem -LiteralPath $script:Dir -Filter 'ready.*').Count | Should -Be $writers -Because 'every writer has to be up before they are released together'
            Set-Content -LiteralPath (Join-Path $script:Dir 'go') -Value 'go'
            foreach ($process in $processes) {
                if (-not $process.WaitForExit(120000)) { $process.Kill($true) }
            }
        } finally {
            foreach ($process in $processes) { if (-not $process.HasExited) { $process.Kill($true) } }
        }
        @($processes | ForEach-Object { $_.ExitCode }) | Should -Be @(0, 0, 0) -Because 'no append reported a failure'
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        $read.Skipped | Should -Be 0
        @($read.Records).Count | Should -Be ($writers * $each)
        @($read.Records | ForEach-Object { $_.attemptId } | Select-Object -Unique).Count | Should -Be ($writers * $each)
    }
}

Describe 'Ledger compaction' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:LedgerPath = Get-RecoveryLedgerPath -RuntimeDir $script:Dir
        $script:Now = Get-T0
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps the last seven days, every unfinished attempt and the latest resolved line per scope' {
        $d = $script:Dir
        $old = $script:Now.AddDays(-10)
        Add-TestLedgerLine -Dir $d -Phase 'started' -AttemptId 'old-done' -At $old | Out-Null
        Add-TestLedgerLine -Dir $d -Phase 'succeeded' -AttemptId 'old-done' -At $old | Out-Null
        Add-TestLedgerLine -Dir $d -Phase 'started' -AttemptId 'old-open' -At $old | Out-Null
        Add-RecoveryLedgerRecord -RuntimeDir $d -Now $script:Now.AddDays(-12) -Record @{ kind = 'resolved'; scope = 'all'; generation = 'g-12' } | Out-Null
        Add-RecoveryLedgerRecord -RuntimeDir $d -Now $script:Now.AddDays(-10) -Record @{ kind = 'resolved'; scope = 'all'; generation = 'g-10' } | Out-Null
        Add-RecoveryLedgerRecord -RuntimeDir $d -Now $script:Now.AddDays(-11) -Record @{ kind = 'resolved'; scope = 'fingerprint'; fingerprint = 'fp1-aaaaaaaaaaaaaaaa'; generation = 'g-fp' } | Out-Null
        Add-TestLedgerLine -Dir $d -Phase 'started' -AttemptId 'recent' -At $script:Now.AddDays(-1) | Out-Null
        Add-TestLedgerLine -Dir $d -Phase 'failed' -AttemptId 'recent' -At $script:Now.AddDays(-1) | Out-Null

        Compress-RecoveryLedger -RuntimeDir $d -Now $script:Now -ThresholdBytes 1 | Should -BeTrue

        $kept = (Read-RecoveryLedger -RuntimeDir $d).Records
        $ids = @($kept | Where-Object { $_.kind -eq 'attempt' } | ForEach-Object { "$($_.attemptId)/$($_.phase)" })
        $ids | Should -Contain 'old-open/started'
        $ids | Should -Contain 'recent/started'
        $ids | Should -Contain 'recent/failed'
        $ids | Should -Not -Contain 'old-done/started'
        $ids | Should -Not -Contain 'old-done/succeeded'
        $generations = @($kept | Where-Object { $_.kind -eq 'resolved' } | ForEach-Object { $_.generation })
        $generations | Should -Contain 'g-10' -Because 'the latest resolved line of scope all stays'
        $generations | Should -Contain 'g-fp' -Because 'so does the latest one of each fingerprint'
        $generations | Should -Not -Contain 'g-12'
    }

    It 'leaves the file alone while another writer holds the guard' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'old' -At $script:Now.AddDays(-30) | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'old' -At $script:Now.AddDays(-30) | Out-Null
        $before = [System.IO.File]::ReadAllBytes($script:LedgerPath)
        $held = [System.IO.FileStream]::new((Join-Path $script:Dir 'recovery.ledger.guard'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now -ThresholdBytes 1 | Should -BeFalse
        } finally {
            $held.Dispose()
        }
        [System.IO.File]::ReadAllBytes($script:LedgerPath) | Should -Be $before
        Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now -ThresholdBytes 1 | Should -BeTrue -Because 'with the guard free it can do its work'
    }

    It 'leaves the file alone when it is under the threshold' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'old' -At $script:Now.AddDays(-30) | Out-Null
        $before = [System.IO.File]::ReadAllBytes($script:LedgerPath)
        Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now | Should -BeFalse
        [System.IO.File]::ReadAllBytes($script:LedgerPath) | Should -Be $before
    }

    It 'does not rewrite a file when nothing in it is droppable' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'r1' -At $script:Now.AddHours(-2) | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'r1' -At $script:Now.AddHours(-2) | Out-Null
        Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now -ThresholdBytes 1 | Should -BeFalse
    }

    It 'replaces the file atomically and leaves no temporary file behind' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'old' -At $script:Now.AddDays(-30) | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'old' -At $script:Now.AddDays(-30) | Out-Null
        Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now -ThresholdBytes 1 | Should -BeTrue
        $names = @(Get-ChildItem -LiteralPath $script:Dir -Force | ForEach-Object { $_.Name } | Sort-Object)
        $names | Should -Be @('recovery.ledger.guard', 'recovery.ledger.ndjson') -Because 'the guard is the only other file, and no temporary file is left'
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records).Count | Should -Be 0
    }

    It 'drops lines that do not parse when it rewrites' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'r1' -At $script:Now.AddHours(-2) | Out-Null
        [System.IO.File]::AppendAllText($script:LedgerPath, "garbage line`n")
        Compress-RecoveryLedger -RuntimeDir $script:Dir -Now $script:Now -ThresholdBytes 1 | Should -BeTrue
        $read = Read-RecoveryLedger -RuntimeDir $script:Dir
        $read.Skipped | Should -Be 0
        @($read.Records).Count | Should -Be 1
    }

    It 'compacts by itself when an append pushes the file past 256 KB' {
        $padding = 'padding ' * 12
        $builder = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt 1200; $i++) {
            $null = $builder.Append('{"v":1,"at":"2026-09-04T12:00:00Z","kind":"attempt","phase":"succeeded","attemptId":"old').Append($i).Append('","fingerprint":"fp1-0123456789abcdef","action":"toy_action","attempt":1,"reason":"').Append($padding).Append('"}').Append("`n")
        }
        [System.IO.File]::WriteAllText($script:LedgerPath, $builder.ToString())
        ([System.IO.FileInfo]::new($script:LedgerPath)).Length | Should -BeGreaterThan 262144

        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'fresh' -At $script:Now | Should -BeTrue

        ([System.IO.FileInfo]::new($script:LedgerPath)).Length | Should -BeLessThan 262144
        $records = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        @($records).Count | Should -Be 1
        $records[0].attemptId | Should -Be 'fresh'
    }
}

Describe 'Attempt budget' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        $script:FpA = 'fp1-aaaaaaaaaaaaaaaa'
        $script:FpB = 'fp1-bbbbbbbbbbbbbbbb'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'counts the started lines of the fingerprint and the action, and no others' {
        $t = $script:Now.AddMinutes(-30)
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $t -Fingerprint $script:FpA -Action 'act_one' | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a1' -At $t -Fingerprint $script:FpA -Action 'act_one' | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a2' -At $t -Fingerprint $script:FpA -Action 'act_one' -Attempt 2 | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a2' -At $t -Fingerprint $script:FpA -Action 'act_one' -Attempt 2 | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'b1' -At $t -Fingerprint $script:FpB -Action 'act_one' | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'b1' -At $t -Fingerprint $script:FpB -Action 'act_one' | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'declined' -AttemptId 'a3' -At $t -Fingerprint $script:FpA -Action 'act_one' | Out-Null

        $a = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'act_one' -Now $script:Now
        $a.Used | Should -Be 2 -Because 'only started lines are attempts'
        $a.Exhausted | Should -BeTrue
        $a.MaxAttempts | Should -Be 2
        $a.LedgerReadable | Should -BeTrue
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpB -Action 'act_one' -Now $script:Now).Used | Should -Be 1
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpB -Action 'act_one' -Now $script:Now).Exhausted | Should -BeFalse
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'act_two' -Now $script:Now).Used | Should -Be 0
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'act_one' -Now $script:Now -MaxAttempts 3).Exhausted | Should -BeFalse
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'ACT_ONE' -Now $script:Now).Used | Should -Be 2 -Because 'action names are not case sensitive'
    }

    It 'reports the time of the newest counted attempt' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $script:Now.AddMinutes(-50) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a1' -At $script:Now.AddMinutes(-49) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a2' -At $script:Now.AddMinutes(-20) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a2' -At $script:Now.AddMinutes(-19) -Fingerprint $script:FpA | Out-Null
        $state = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now
        $state.LastAttemptAtUtc | Should -Be '2026-10-04T11:40:00Z'
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpB -Action 'toy_action' -Now $script:Now).LastAttemptAtUtc | Should -Be ''
    }

    It 'survives a restart: a fresh module instance reading the same file reaches the same answer' {
        Register-ToyAction -Name 'toy_action' -Action { param($c) $c.Calls.Add('action'); @{ Ok = $false; Reason = 'nope'; Evidence = @() } }
        $result = New-TestResult
        $ctx = New-TestContext
        (Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $result } + $ctx) -RuntimeDir $script:Dir -Now $script:Now).Decision | Should -Be 'failed'
        (Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $result } + $ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(1)).Decision | Should -Be 'failed'

        Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -DisableNameChecking

        $state = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $result.fingerprint -Action 'toy_action' -Now $script:Now.AddMinutes(2)
        $state.Used | Should -Be 2
        $state.Exhausted | Should -BeTrue
        $third = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $result } + $ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(2)
        $third.Decision | Should -Be 'exhausted'
        @($ctx.Calls | Where-Object { $_ -eq 'action' }).Count | Should -Be 2 -Because 'the restart did not hand out a third attempt'
        Clear-RecoveryAction
    }

    It 'lets a resolved line of scope all re-arm every fingerprint' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $script:Now.AddMinutes(-60) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a1' -At $script:Now.AddMinutes(-59) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'b1' -At $script:Now.AddMinutes(-60) -Fingerprint $script:FpB | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'b1' -At $script:Now.AddMinutes(-59) -Fingerprint $script:FpB | Out-Null
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Generation 'g1' -Now $script:Now.AddMinutes(-30) | Should -BeTrue
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a2' -At $script:Now.AddMinutes(-10) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a2' -At $script:Now.AddMinutes(-9) -Fingerprint $script:FpA | Out-Null

        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now).Used | Should -Be 1
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpB -Action 'toy_action' -Now $script:Now).Used | Should -Be 0
    }

    It 'lets a resolved line of scope fingerprint re-arm only that fingerprint' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $script:Now.AddMinutes(-60) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a1' -At $script:Now.AddMinutes(-59) -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'b1' -At $script:Now.AddMinutes(-60) -Fingerprint $script:FpB | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'b1' -At $script:Now.AddMinutes(-59) -Fingerprint $script:FpB | Out-Null
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Fingerprint $script:FpA -Now $script:Now.AddMinutes(-30) | Should -BeTrue

        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now).Used | Should -Be 0
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpB -Action 'toy_action' -Now $script:Now).Used | Should -Be 1
    }

    It 'orders a resolved line and an attempt stamped in the same second by their place in the file' {
        $t = $script:Now
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'before' -At $t -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'before' -At $t -Fingerprint $script:FpA | Out-Null
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Now $t | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'after' -At $t -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'after' -At $t -Fingerprint $script:FpA | Out-Null
        (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $t.AddMinutes(1)).Used | Should -Be 1
    }

    It 'writes the resolved line with its scope, fingerprint and generation' {
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Generation 'g9' -Now $script:Now | Should -BeTrue
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Fingerprint $script:FpA -Generation 'g10' -Now $script:Now | Should -BeTrue
        $records = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        $records[0].kind | Should -Be 'resolved'
        $records[0].scope | Should -Be 'all'
        $records[0].generation | Should -Be 'g9'
        $records[1].scope | Should -Be 'fingerprint'
        $records[1].fingerprint | Should -Be $script:FpA
        $records[1].generation | Should -Be 'g10'
    }

    It 'returns false from Complete-RecoveryFingerprint when the ledger cannot be written' {
        Complete-RecoveryFingerprint -RuntimeDir (Join-Path $script:Dir 'missing') | Should -BeFalse
    }

    It 'stops counting an attempt 24 hours after it started' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $script:Now -Fingerprint $script:FpA | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId 'a1' -At $script:Now -Fingerprint $script:FpA | Out-Null
        $used = { param($offset) (Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now.Add($offset)).Used }
        (& $used ([timespan]::FromHours(23.9))) | Should -Be 1
        (& $used ([timespan]::FromHours(24))) | Should -Be 0 -Because 'the window is "newer than 24 hours"'
        (& $used ([timespan]::FromHours(25))) | Should -Be 0
    }

    It 'reports an attempt with no later line as unfinished, with its age' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'open1' -At $script:Now.AddMinutes(-4) -Fingerprint $script:FpA | Out-Null
        $state = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now
        $state.UnfinishedAttemptId | Should -Be 'open1'
        $state.UnfinishedAgeMinutes | Should -Be 4
        Add-TestLedgerLine -Dir $script:Dir -Phase 'succeeded' -AttemptId 'open1' -At $script:Now.AddMinutes(-3) -Fingerprint $script:FpA | Out-Null
        $done = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now
        $done.UnfinishedAttemptId | Should -Be ''
        $done.UnfinishedAgeMinutes | Should -Be 0
    }

    It 'treats a ledger that exists but cannot be read as a spent budget, not an empty one' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'a1' -At $script:Now | Out-Null
        $held = [System.IO.FileStream]::new((Get-RecoveryLedgerPath -RuntimeDir $script:Dir), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $state = Get-RecoveryAttemptState -RuntimeDir $script:Dir -Fingerprint $script:FpA -Action 'toy_action' -Now $script:Now
        } finally {
            $held.Dispose()
        }
        $state.LedgerReadable | Should -BeFalse
        $state.Exhausted | Should -BeTrue
    }
}

Describe 'Unfinished attempts' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
        Register-ToyAction -Name 'toy_action'
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'declines while an attempt younger than ten minutes may still be running' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'other' -At $script:Now.AddMinutes(-4) -Fingerprint $script:Result.fingerprint | Out-Null
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'declined'
        $out.RecoveryState | Should -Be 'declined'
        $out.Reason | Should -Be 'attempt-in-progress'
        $script:Ctx.Calls.Count | Should -Be 0 -Because 'neither the precondition nor the action may run beside another process'
        (Get-LedgerPhase -Dir $script:Dir) | Should -Be @('started', 'declined')
    }

    It 'abandons an attempt older than ten minutes exactly once, counts it, and goes on' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'dead' -At $script:Now.AddMinutes(-30) -Fingerprint $script:Result.fingerprint | Out-Null
        $first = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $first.Decision | Should -Be 'applied'
        $first.Attempt | Should -Be 2 -Because 'the abandoned attempt counted as used'
        $second = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(1)
        $second.Decision | Should -Be 'exhausted'

        $abandoned = @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records | Where-Object { $_.phase -eq 'abandoned' })
        $abandoned.Count | Should -Be 1 -Because 'one abandoned line, however many invocations follow'
        $abandoned[0].attemptId | Should -Be 'dead'
        $abandoned[0].action | Should -Be 'toy_action'
        $abandoned[0].fingerprint | Should -Be $script:Result.fingerprint
    }

    It 'treats an attempt of exactly ten minutes as still running and one a second older as dead' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'edge' -At $script:Now -Fingerprint $script:Result.fingerprint | Out-Null
        $running = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(10)
        $running.Decision | Should -Be 'declined'
        $running.Reason | Should -Be 'attempt-in-progress'
        @((Get-LedgerPhase -Dir $script:Dir) | Where-Object { $_ -eq 'abandoned' }).Count | Should -Be 0

        $dead = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(10).AddSeconds(1)
        $dead.Decision | Should -Be 'applied'
        @((Get-LedgerPhase -Dir $script:Dir) | Where-Object { $_ -eq 'abandoned' }).Count | Should -Be 1
    }

    It 'records an abandoned attempt even when the budget is already spent' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'dead' -At $script:Now.AddMinutes(-30) -Fingerprint $script:Result.fingerprint | Out-Null
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -MaxAttempts 1 -Now $script:Now
        $out.Decision | Should -Be 'exhausted'
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -MaxAttempts 1 -Now $script:Now | Out-Null
        @((Get-LedgerPhase -Dir $script:Dir) | Where-Object { $_ -eq 'abandoned' }).Count | Should -Be 1
    }

    It 'closes the books on several dead attempts, one line each' {
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'dead1' -At $script:Now.AddMinutes(-90) -Fingerprint $script:Result.fingerprint | Out-Null
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'dead2' -At $script:Now.AddMinutes(-60) -Fingerprint $script:Result.fingerprint -Attempt 2 | Out-Null
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -MaxAttempts 5 -Now $script:Now | Out-Null
        $ids = @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records | Where-Object { $_.phase -eq 'abandoned' } | ForEach-Object { $_.attemptId })
        $ids.Count | Should -Be 2
        $ids | Should -Contain 'dead1'
        $ids | Should -Contain 'dead2'
    }
}

Describe 'The write-before-act rule' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'has the started line on disk before the action runs' {
        Register-ToyAction -Name 'toy_action' -Action {
            param($c)
            $text = [System.IO.File]::ReadAllText((Join-Path $c.RuntimeDir 'recovery.ledger.ndjson'))
            $seen = ($text -match '"phase":"started"') -and ($text -match [regex]::Escape($c.AttemptId))
            $c.Calls.Add($(if ($seen) { 'started-line-present' } else { 'started-line-missing' }))
            @{ Ok = $true; Reason = 'did-it'; Evidence = @() }
        }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $script:Ctx.Calls | Should -Contain 'started-line-present'
        $script:Ctx.Calls | Should -Not -Contain 'started-line-missing'
    }

    It 'does not run the action when the ledger is a directory, and says ledger-unavailable' {
        Register-ToyAction -Name 'toy_action'
        New-Item -ItemType Directory -Path (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Out-Null
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'ledger-unavailable'
        $out.RecoveryState | Should -Be 'declined'
        $script:Ctx.Calls | Should -Not -Contain 'action'
    }

    It 'does not run the action when the runtime directory does not exist' {
        Register-ToyAction -Name 'toy_action'
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir (Join-Path $script:Dir 'missing') -Now $script:Now
        $out.Decision | Should -Be 'ledger-unavailable'
        $script:Ctx.Calls | Should -Not -Contain 'action'
        $script:Ctx.Calls | Should -Not -Contain 'postcondition'
    }

    It 'does not run the action when the started line cannot be appended to a readable ledger' {
        Register-ToyAction -Name 'toy_action'
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'seed' -At $script:Now.AddHours(-3) -Fingerprint 'fp1-ffffffffffffffff' | Out-Null
        $path = Get-RecoveryLedgerPath -RuntimeDir $script:Dir
        Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
        try {
            $stillWritable = $false
            try { [System.IO.File]::OpenWrite($path).Dispose(); $stillWritable = $true } catch { $stillWritable = $false }
            if ($stillWritable) {
                Set-ItResult -Skipped -Because 'this account can write a read-only file, so the case cannot be built here'
                return
            }
            $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
            $out.Decision | Should -Be 'ledger-unavailable'
            $script:Ctx.Calls | Should -Not -Contain 'action'
        } finally {
            Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false
        }
    }

    It 'does not run the action when the existing ledger cannot be read' {
        Mock -ModuleName Test.RecoveryLedger Start-Sleep { }
        Register-ToyAction -Name 'toy_action'
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'seed' -At $script:Now.AddHours(-3) -Fingerprint 'fp1-ffffffffffffffff' | Out-Null
        $held = [System.IO.FileStream]::new((Get-RecoveryLedgerPath -RuntimeDir $script:Dir), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        } finally {
            $held.Dispose()
        }
        $out.Decision | Should -Be 'ledger-unavailable'
        $script:Ctx.Calls.Count | Should -Be 0
    }

    It 'reports an unknown action without touching the ledger' {
        $out = Invoke-RecoveryAction -Name 'no_such_action' -Context @{ Result = $script:Result } -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'unknown-action'
        $out.RecoveryState | Should -Be 'none'
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
    }
}

Describe 'Budget enforced through Invoke-RecoveryAction' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
        Register-ToyAction -Name 'toy_action' -Action { param($c) $c.Calls.Add('action'); @{ Ok = $false; Reason = 'nope'; Evidence = @() } }
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'allows MaxAttempts attempts, then writes exhausted and stops running the action' {
        $decisions = foreach ($minute in 0..2) {
            (Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes($minute)).Decision
        }
        @($decisions) | Should -Be @('failed', 'failed', 'exhausted')
        @($script:Ctx.Calls | Where-Object { $_ -eq 'action' }).Count | Should -Be 2
        @(Get-LedgerPhase -Dir $script:Dir)[-1] | Should -Be 'exhausted'
    }

    It 'numbers the attempts from one' {
        $first = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $second = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(1)
        $first.Attempt | Should -Be 1
        $second.Attempt | Should -Be 2
        $first.AttemptId | Should -Not -Be $second.AttemptId
        $first.AttemptId | Should -Match '^[0-9a-f]{32}$'
    }

    It 'lets a repair registered with a lower cap use it, and never a higher one' {
        Register-ToyAction -Name 'capped_one' -MaxAttempts 1 -Action { param($c) $c.Calls.Add('capped'); @{ Ok = $false; Reason = 'nope'; Evidence = @() } }
        Register-ToyAction -Name 'capped_high' -MaxAttempts 9 -Action { param($c) $c.Calls.Add('high'); @{ Ok = $false; Reason = 'nope'; Evidence = @() } }
        $ctx = @{ Result = $script:Result } + $script:Ctx
        (Invoke-RecoveryAction -Name 'capped_one' -Context $ctx -RuntimeDir $script:Dir -MaxAttempts 5 -Now $script:Now).Decision | Should -Be 'failed'
        (Invoke-RecoveryAction -Name 'capped_one' -Context $ctx -RuntimeDir $script:Dir -MaxAttempts 5 -Now $script:Now.AddMinutes(1)).Decision | Should -Be 'exhausted'
        (Invoke-RecoveryAction -Name 'capped_high' -Context $ctx -RuntimeDir $script:Dir -MaxAttempts 1 -Now $script:Now).Decision | Should -Be 'failed'
        (Invoke-RecoveryAction -Name 'capped_high' -Context $ctx -RuntimeDir $script:Dir -MaxAttempts 1 -Now $script:Now.AddMinutes(1)).Decision | Should -Be 'exhausted'
    }

    It 'is re-armed by a resolved line' {
        $ctx = @{ Result = $script:Result } + $script:Ctx
        1..3 | ForEach-Object { Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddMinutes($_) | Out-Null }
        (Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(4)).Decision | Should -Be 'exhausted'
        Complete-RecoveryFingerprint -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(5) | Should -BeTrue
        $again = Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddMinutes(6)
        $again.Decision | Should -Be 'failed'
        $again.Attempt | Should -Be 1
    }

    It 'expires on its own after 24 hours' {
        $ctx = @{ Result = $script:Result } + $script:Ctx
        1..2 | ForEach-Object { Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddMinutes($_) | Out-Null }
        (Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddHours(1)).Decision | Should -Be 'exhausted'
        (Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now.AddHours(25)).Decision | Should -Be 'failed'
    }

    It 'stamps each line with the time it is written when no time is pinned' {
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir | Out-Null
        $records = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        @($records).Count | Should -BeGreaterThan 1
        foreach ($r in $records) {
            [math]::Abs(([datetime]::UtcNow - [datetime]::Parse($r.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).TotalSeconds) | Should -BeLessThan 120
        }
    }
}

Describe 'Action context and ledger lines' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'hands the blocks the attempt, the generation, the fingerprint and the runtime directory' {
        $seen = @{}
        Register-ToyAction -Name 'toy_action' -Action {
            param($c)
            foreach ($k in 'Attempt', 'AttemptId', 'Generation', 'Fingerprint', 'RuntimeDir') { $c.Seen[$k] = $c[$k] }
            $c.Seen['HasResult'] = ($c.Result -is [System.Collections.IDictionary])
            @{ Ok = $true; Reason = 'did-it'; Evidence = @() }
        }
        $ctx = @{ Result = $script:Result; Seen = $seen; Calls = $script:Ctx.Calls }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now
        $seen.Attempt | Should -Be 1
        $seen.AttemptId | Should -Be $out.AttemptId
        $seen.Generation | Should -Be $script:Result.cycleGeneration
        $seen.Fingerprint | Should -Be $script:Result.fingerprint
        $seen.RuntimeDir | Should -Be $script:Dir
        $seen.HasResult | Should -BeTrue
        $ctx.ContainsKey('AttemptId') | Should -BeFalse -Because 'the caller context is copied, not modified'
    }

    It 'takes generation and fingerprint from the context when it carries them' {
        Register-ToyAction -Name 'toy_action'
        $ctx = @{ Result = $script:Result; Generation = (('d' * 32) + ':9'); Fingerprint = 'fp1-9999999999999999' } + $script:Ctx
        Invoke-RecoveryAction -Name 'toy_action' -Context $ctx -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        $started = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records | Where-Object { $_.phase -eq 'started' }
        $started.generation | Should -Be (('d' * 32) + ':9')
        $started.fingerprint | Should -Be 'fp1-9999999999999999'
        $started.failureClass | Should -Be 'wait_timeout'
    }

    It 'works with a context that carries only the result and the runtime directory' {
        Register-ToyAction -Name 'toy_action'
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context @{ Result = $script:Result; RuntimeDir = $script:Dir; Calls = $script:Ctx.Calls } -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $out.Action | Should -Be 'toy_action'
    }

    It 'carries the evidence of every step into the result and the lines' {
        Register-ToyAction -Name 'toy_action' `
            -Precondition { @{ Ok = $true; Reason = 'go'; Evidence = @([ordered]@{ kind = 'record'; ref = 'pre'; note = '' }) } } `
            -Action { @{ Ok = $true; Reason = 'did-it'; Evidence = @([ordered]@{ kind = 'file'; ref = 'act'; note = '' }) } } `
            -Postcondition { @{ Ok = $true; Reason = 'verified'; Evidence = @([ordered]@{ kind = 'command'; ref = 'post'; note = '' }) } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        @($out.Evidence | ForEach-Object { $_.ref }) | Should -Be @('pre', 'act', 'post')
        $records = (Read-RecoveryLedger -RuntimeDir $script:Dir).Records
        @($records[0].evidence | ForEach-Object { $_.ref }) | Should -Be @('pre')
        @($records[1].evidence | ForEach-Object { $_.ref }) | Should -Be @('pre', 'act', 'post')
    }

    It 'redacts the reasons a repair returns before they reach the ledger and the result' {
        Register-ToyAction -Name 'toy_action' -Action { @{ Ok = $false; Reason = 'clone-failed: https://u:p4ssw0rd@example.invalid/r.git'; Evidence = @() } }
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $out.Reason | Should -Not -Match 'p4ssw0rd'
        [System.IO.File]::ReadAllText((Get-RecoveryLedgerPath -RuntimeDir $script:Dir)) | Should -Not -Match 'p4ssw0rd'
    }
}

Describe 'Registry and planner' {
    BeforeEach {
        Clear-RecoveryAction
        $script:Result = New-TestResult
    }
    AfterEach {
        Clear-RecoveryAction
    }

    It 'lists the registered names in registration order' {
        Register-ToyAction -Name 'zulu_action'
        Register-ToyAction -Name 'alpha_action'
        Register-ToyAction -Name 'mike_action'
        @(Get-RegisteredRecoveryAction) | Should -Be @('zulu_action', 'alpha_action', 'mike_action')
    }

    It 'returns the registered entry by name, and $null for an unknown one' {
        Register-ToyAction -Name 'toy_action' -MaxAttempts 3 -SkipsFailurePause $true
        $entry = Get-RecoveryAction -Name 'toy_action'
        $entry.Name | Should -Be 'toy_action'
        $entry.Description | Should -Be 'toy'
        $entry.MaxAttempts | Should -Be 3
        $entry.SkipsFailurePause | Should -BeTrue
        $entry.Applies | Should -BeOfType [scriptblock]
        Get-RecoveryAction -Name 'no_such_action' | Should -BeNullOrEmpty
    }

    It 'replaces a registration of the same name and keeps its place' {
        Register-ToyAction -Name 'first_action'
        Register-ToyAction -Name 'second_action'
        Register-RecoveryAction -Name 'first_action' -Description 'replaced' -Applies { $false } -Precondition { @{ Ok = $true } } -Action { @{ Ok = $true } } -Postcondition { @{ Ok = $true } }
        @(Get-RegisteredRecoveryAction) | Should -Be @('first_action', 'second_action')
        (Get-RecoveryAction -Name 'first_action').Description | Should -Be 'replaced'
    }

    It 'clears one name or all of them' {
        Register-ToyAction -Name 'one_action'
        Register-ToyAction -Name 'two_action'
        Clear-RecoveryAction -Name 'one_action'
        @(Get-RegisteredRecoveryAction) | Should -Be @('two_action')
        Clear-RecoveryAction -Name 'never_registered'
        @(Get-RegisteredRecoveryAction) | Should -Be @('two_action')
        Clear-RecoveryAction
        @(Get-RegisteredRecoveryAction).Count | Should -Be 0
    }

    It 'rejects a name that is not lowercase snake_case' {
        foreach ($bad in 'Bad_Name', 'bad-name', '1bad', 'bad name', 'bad__name', '_bad') {
            { Register-ToyAction -Name $bad } | Should -Throw
        }
        { Register-ToyAction -Name 'good_name_2' } | Should -Not -Throw
    }

    It 'keeps its registrations when the module is imported again' {
        Register-ToyAction -Name 'toy_action'
        Import-Module (Join-Path $here 'Test.RecoveryLedger.psm1') -Force -DisableNameChecking
        @(Get-RegisteredRecoveryAction) | Should -Be @('toy_action')
    }

    It 'plans the actions whose Applies accepts the result, in registration order' {
        Register-ToyAction -Name 'a_yes' -Applies { param($Result) $Result['failureClass'] -ceq 'wait_timeout' }
        Register-ToyAction -Name 'b_no' -Applies { param($Result) $Result['failureClass'] -ceq 'script_error' }
        Register-ToyAction -Name 'c_yes' -Applies { $true }
        @(Get-RecoveryPlan -Result $script:Result) | Should -Be @('a_yes', 'c_yes')
    }

    It 'counts an Applies that throws, answers nothing, or answers with a non-boolean as not applicable' {
        Register-ToyAction -Name 'boom' -Applies { throw 'Applies exploded' }
        Register-ToyAction -Name 'silent' -Applies { $null }
        Register-ToyAction -Name 'truthy_text' -Applies { 'yes' }
        Register-ToyAction -Name 'truthy_number' -Applies { 1 }
        Register-ToyAction -Name 'honest' -Applies { $true }
        { Get-RecoveryPlan -Result $script:Result } | Should -Not -Throw
        @(Get-RecoveryPlan -Result $script:Result) | Should -Be @('honest')
    }

    It 'returns an empty plan, not an error, when nothing is registered' {
        @(Get-RecoveryPlan -Result $script:Result).Count | Should -Be 0
    }

    It 'leaves out the names it is told to exclude, and ignores names that are not registered' {
        Register-ToyAction -Name 'keep_one'
        Register-ToyAction -Name 'skip_me'
        Register-ToyAction -Name 'keep_two'
        @(Get-RecoveryPlan -Result $script:Result -ExcludeAction 'skip_me') | Should -Be @('keep_one', 'keep_two')
        @(Get-RecoveryPlan -Result $script:Result -ExcludeAction 'skip_me', 'not_registered', 'keep_one') | Should -Be @('keep_two')
        @(Get-RecoveryPlan -Result $script:Result -ExcludeAction 'SKIP_ME') | Should -Be @('keep_one', 'keep_two')
        @(Get-RecoveryPlan -Result $script:Result -ExcludeAction @()) | Should -Be @('keep_one', 'skip_me', 'keep_two')
        @(Get-RecoveryPlan -Result $script:Result -ExcludeAction $null) | Should -Be @('keep_one', 'skip_me', 'keep_two')
    }

    It 'accepts an ordered dictionary or a hashtable as the result' {
        Register-ToyAction -Name 'toy_action' -Applies { param($Result) $Result['failureClass'] -ceq 'wait_timeout' }
        @(Get-RecoveryPlan -Result $script:Result) | Should -Be @('toy_action')
        @(Get-RecoveryPlan -Result @{ failureClass = 'wait_timeout' }) | Should -Be @('toy_action')
        @(Get-RecoveryPlan -Result @{ failureClass = 'script_error' }).Count | Should -Be 0
    }
}

Describe 'Invoke-RecoveryForResult' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
    }
    AfterEach {
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'with automatic recovery off, advises the plan and writes nothing' {
        Register-ToyAction -Name 'one_action'
        Register-ToyAction -Name 'two_action'
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $false -Now $script:Now
        $out.RecoveryState | Should -Be 'advised'
        $out.Decision | Should -Be 'advised'
        @($out.Advised) | Should -Be @('one_action', 'two_action')
        $out.Action | Should -Be ''
        $out.Attempt | Should -Be 0
        $out.SkipFailurePause | Should -BeFalse
        @($out.Decisions).Count | Should -Be 0
        $script:Ctx.Calls.Count | Should -Be 0 -Because 'advising does not even run a precondition'
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
    }

    It 'with automatic recovery off, leaves an existing ledger byte for byte as it was' {
        Register-ToyAction -Name 'one_action'
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'seed' -At $script:Now.AddHours(-1) | Out-Null
        $path = Get-RecoveryLedgerPath -RuntimeDir $script:Dir
        $before = [System.IO.File]::ReadAllBytes($path)
        $stamp = [System.IO.File]::GetLastWriteTimeUtc($path)
        Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $false -Now $script:Now | Out-Null
        [System.IO.File]::ReadAllBytes($path) | Should -Be $before
        [System.IO.File]::GetLastWriteTimeUtc($path) | Should -Be $stamp
    }

    It 'with automatic recovery off and no action that fits, answers none' {
        Register-ToyAction -Name 'never_applies' -Applies { $false }
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $false
        $out.RecoveryState | Should -Be 'none'
        @($out.Advised).Count | Should -Be 0
    }

    It 'with automatic recovery on and no action that fits, answers none' {
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true
        $out.RecoveryState | Should -Be 'none'
        $out.Decision | Should -Be 'none'
        Test-Path -LiteralPath (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Should -BeFalse
    }

    It 'stops at the first action that applied and reports its pause flag' {
        Register-ToyAction -Name 'a_declines' -Precondition { param($c) $c.Calls.Add('a-pre'); @{ Ok = $false; Reason = 'not-now'; Evidence = @() } } -Action { param($c) $c.Calls.Add('a-act'); @{ Ok = $true } }
        Register-ToyAction -Name 'b_applies' -SkipsFailurePause $true -Action { param($c) $c.Calls.Add('b-act'); @{ Ok = $true; Reason = 'did-it'; Evidence = @() } }
        Register-ToyAction -Name 'c_never_reached' -Action { param($c) $c.Calls.Add('c-act'); @{ Ok = $true } }
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now
        $out.Decision | Should -Be 'applied'
        $out.RecoveryState | Should -Be 'applied'
        $out.Action | Should -Be 'b_applies'
        $out.SkipFailurePause | Should -BeTrue
        $out.Attempt | Should -Be 1
        @($out.Advised) | Should -Be @('a_declines', 'b_applies', 'c_never_reached')
        @($out.Decisions | ForEach-Object { $_.Decision }) | Should -Be @('declined', 'applied')
        $script:Ctx.Calls | Should -Contain 'b-act'
        $script:Ctx.Calls | Should -Not -Contain 'a-act'
        $script:Ctx.Calls | Should -Not -Contain 'c-act'
    }

    It 'returns a result that does not contain itself' {
        Register-ToyAction -Name 'toy_action'
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now
        { $out | ConvertTo-Json -Depth 6 -WarningAction Stop } | Should -Not -Throw
        $out.Decisions[0].Contains('Decisions') | Should -BeFalse
    }

    It 'does not pause-skip for an action that did not set the flag' {
        Register-ToyAction -Name 'toy_action'
        (Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now).SkipFailurePause | Should -BeFalse
    }

    It 'leaves out the excluded actions: they are neither advised nor run' {
        Register-ToyAction -Name 'run_me'
        Register-ToyAction -Name 'later_by_name' -Action { param($c) $c.Calls.Add('later'); @{ Ok = $true } }
        $off = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $false -ExcludeAction 'later_by_name'
        @($off.Advised) | Should -Be @('run_me')
        $on = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -ExcludeAction 'later_by_name', 'unknown_name' -Now $script:Now
        @($on.Advised) | Should -Be @('run_me')
        @($on.Decisions).Count | Should -Be 1
        $script:Ctx.Calls | Should -Not -Contain 'later'
        (Invoke-RecoveryAction -Name 'later_by_name' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now).Decision | Should -Be 'applied' -Because 'an excluded action stays callable by name'
    }

    It 'ranks exhausted and failed above declined, and the later of two equals wins' -ForEach @(
        @{ Outcomes = @('declined', 'exhausted'); Expected = 'exhausted' }
        @{ Outcomes = @('declined', 'failed'); Expected = 'failed' }
        @{ Outcomes = @('failed', 'declined'); Expected = 'failed' }
        @{ Outcomes = @('exhausted', 'declined'); Expected = 'exhausted' }
        @{ Outcomes = @('exhausted', 'failed'); Expected = 'failed' }
        @{ Outcomes = @('failed', 'exhausted'); Expected = 'exhausted' }
        @{ Outcomes = @('declined', 'declined'); Expected = 'declined' }
    ) {
        $index = 0
        foreach ($outcome in $Outcomes) {
            $index++
            $name = "step_$($index)_$outcome"
            switch ($outcome) {
                'declined' { Register-ToyAction -Name $name -Precondition { @{ Ok = $false; Reason = 'not-now'; Evidence = @() } } }
                'failed' { Register-ToyAction -Name $name -Action { @{ Ok = $false; Reason = 'nope'; Evidence = @() } } }
                'exhausted' {
                    Register-ToyAction -Name $name -MaxAttempts 1
                    Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId "seed-$name" -At $script:Now.AddMinutes(-20) -Fingerprint $script:Result.fingerprint -Action $name | Out-Null
                    Add-TestLedgerLine -Dir $script:Dir -Phase 'failed' -AttemptId "seed-$name" -At $script:Now.AddMinutes(-19) -Fingerprint $script:Result.fingerprint -Action $name | Out-Null
                }
            }
        }
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now
        $out.Decision | Should -Be $Expected
        $out.RecoveryState | Should -Be $Expected
        $out.Action | Should -Be ($out.Decisions | Where-Object { $_.Decision -eq $Expected } | Select-Object -Last 1).Action
        $out.SkipFailurePause | Should -BeFalse
    }

    It 'reports ledger-unavailable when the ledger cannot be used, and runs nothing' {
        Register-ToyAction -Name 'toy_action'
        New-Item -ItemType Directory -Path (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Out-Null
        $out = Invoke-RecoveryForResult -Result $script:Result -Context $script:Ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now
        $out.Decision | Should -Be 'ledger-unavailable'
        $script:Ctx.Calls | Should -Not -Contain 'action'
    }

    It 'passes the caller context to the actions with the result added, without modifying it' {
        Register-ToyAction -Name 'toy_action' -Action {
            param($c)
            $c.Calls.Add($(if ($c.Result.failureClass -eq 'wait_timeout' -and $c.Marker -eq 'from-caller') { 'saw-result-and-marker' } else { 'missing' }))
            @{ Ok = $true; Reason = 'did-it'; Evidence = @() }
        }
        $ctx = @{ Marker = 'from-caller'; Calls = $script:Ctx.Calls }
        Invoke-RecoveryForResult -Result $script:Result -Context $ctx -RuntimeDir $script:Dir -Enabled $true -Now $script:Now | Out-Null
        $script:Ctx.Calls | Should -Contain 'saw-result-and-marker'
        $ctx.ContainsKey('Result') | Should -BeFalse
    }
}

Describe 'recovery_action events' {
    BeforeEach {
        $script:Dir = New-ScratchDir
        $script:Now = Get-T0
        Clear-RecoveryAction
        $script:Ctx = New-TestContext
        $script:Result = New-TestResult
        $global:__recoveryEvents = [System.Collections.Generic.List[hashtable]]::new()
        function global:Send-CycleEventSafely {
            param([Parameter(Mandatory)][hashtable]$EventRecord)
            $global:__recoveryEvents.Add($EventRecord)
        }
    }
    AfterEach {
        Remove-Item -Path Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
        Remove-Variable -Name __recoveryEvents -Scope Global -ErrorAction SilentlyContinue
        Clear-RecoveryAction
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'emits one event per attempt line of a successful run' {
        Register-ToyAction -Name 'toy_action'
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $events = @($global:__recoveryEvents)
        $events.Count | Should -Be 2
        @($events | ForEach-Object { $_.phase }) | Should -Be @('started', 'succeeded')
        @($events | ForEach-Object { $_.decision }) | Should -Be @('pending', 'applied')
        foreach ($e in $events) {
            $e.event | Should -Be 'recovery_action'
            $e.action | Should -Be 'toy_action'
            $e.attempt | Should -Be 1
            $e.attemptId | Should -Be $out.AttemptId
            $e.generation | Should -Be $script:Result.cycleGeneration
            $e.fingerprint | Should -Be $script:Result.fingerprint
            $e.failureClass | Should -Be 'wait_timeout'
            $e.timestamp | Should -Be '2026-10-04T12:00:00Z'
            $e.attempt | Should -BeOfType [int]
        }
        $events[0].reason | Should -Be 'go'
        $events[1].reason | Should -Be 'verified'
    }

    It 'emits the declined line and the exhausted line' {
        Register-ToyAction -Name 'toy_action' -Precondition { @{ Ok = $false; Reason = 'not-now'; Evidence = @() } }
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        $declined = @($global:__recoveryEvents)
        $declined.Count | Should -Be 1
        $declined[0].phase | Should -Be 'declined'
        $declined[0].decision | Should -Be 'declined'
        $declined[0].reason | Should -Be 'not-now'

        $global:__recoveryEvents.Clear()
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -MaxAttempts 0 -Now $script:Now | Out-Null
        @($global:__recoveryEvents)[0].phase | Should -Be 'exhausted'
        @($global:__recoveryEvents)[0].decision | Should -Be 'exhausted'
    }

    It 'emits every line of a failed run with its rollback' {
        Register-ToyAction -Name 'toy_action' -Postcondition { @{ Ok = $false; Reason = 'still-broken'; Evidence = @() } } -Rollback { @{ Ok = $true; Reason = 'undone'; Evidence = @() } }
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        @($global:__recoveryEvents | ForEach-Object { $_.phase }) | Should -Be @('started', 'rolled-back', 'failed', 'escalated')
        @($global:__recoveryEvents | ForEach-Object { $_.decision }) | Should -Be @('pending', 'failed', 'failed', 'failed')
    }

    It 'emits the abandoned line of a dead attempt' {
        Register-ToyAction -Name 'toy_action'
        Add-TestLedgerLine -Dir $script:Dir -Phase 'started' -AttemptId 'dead' -At $script:Now.AddMinutes(-30) -Fingerprint $script:Result.fingerprint | Out-Null
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        $abandoned = @($global:__recoveryEvents | Where-Object { $_.phase -eq 'abandoned' })
        $abandoned.Count | Should -Be 1
        $abandoned[0].attemptId | Should -Be 'dead'
        $abandoned[0].decision | Should -Be 'abandoned'
    }

    It 'leaves failureClass out of the event when the result has none' {
        Register-ToyAction -Name 'toy_action'
        $bare = New-RecoveryResult -EntryPoint 'runner' -CycleGeneration (('a' * 32) + ':4') -Outcome 'failed' -ExitCode 1
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $bare } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        foreach ($e in @($global:__recoveryEvents)) { $e.ContainsKey('failureClass') | Should -BeFalse }
    }

    It 'keeps a runner fault class in the ledger line and out of the event, whose schema knows only the shared taxonomy' {
        Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
        Register-ToyAction -Name 'toy_action'
        $fault = New-RecoveryResult -EntryPoint 'runner' -CycleGeneration (('a' * 32) + ':4') -Outcome 'infrastructure-fault' -ExitCode 1 -FailureClass 'cycle_spawn_failed' -Stage 'CycleSpawn' -Reason 'could not start'
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $fault } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        $events = @($global:__recoveryEvents)
        $events.Count | Should -Be 2
        foreach ($e in $events) {
            $e.ContainsKey('failureClass') | Should -BeFalse
            $violations = @(Test-CycleEventSchema -Record $e)
            $violations.Count | Should -Be 0 -Because "the event must pass the schema: $($violations -join '; ')"
        }
        @((Read-RecoveryLedger -RuntimeDir $script:Dir).Records | ForEach-Object { [string]$_['failureClass'] } | Select-Object -Unique) | Should -Be @('cycle_spawn_failed')
    }

    It 'passes the event schema with a shared taxonomy class' {
        Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
        Register-ToyAction -Name 'toy_action'
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        $events = @($global:__recoveryEvents)
        $events.Count | Should -Be 2
        foreach ($e in $events) {
            $violations = @(Test-CycleEventSchema -Record $e)
            $violations.Count | Should -Be 0 -Because "the event must pass the schema: $($violations -join '; ')"
        }
    }

    It 'emits nothing for a run that wrote no ledger line' {
        Invoke-RecoveryAction -Name 'no_such_action' -Context @{ Result = $script:Result } -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        New-Item -ItemType Directory -Path (Get-RecoveryLedgerPath -RuntimeDir $script:Dir) | Out-Null
        Register-ToyAction -Name 'toy_action'
        Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now | Out-Null
        @($global:__recoveryEvents).Count | Should -Be 0
    }

    It 'does not let a failing event writer change the outcome or the ledger' {
        Register-ToyAction -Name 'toy_action'
        function global:Send-CycleEventSafely {
            param([Parameter(Mandatory)][hashtable]$EventRecord)
            throw "the event writer exploded on $($EventRecord['event'])"
        }
        { $script:Out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now } | Should -Not -Throw
        $script:Out.Decision | Should -Be 'applied'
        (Get-LedgerPhase -Dir $script:Dir) | Should -Be @('started', 'succeeded')
    }

    It 'runs the same when no event writer is loaded at all' {
        Remove-Item -Path Function:\Send-CycleEventSafely
        Register-ToyAction -Name 'toy_action'
        $out = Invoke-RecoveryAction -Name 'toy_action' -Context (@{ Result = $script:Result } + $script:Ctx) -RuntimeDir $script:Dir -Now $script:Now
        $out.Decision | Should -Be 'applied'
        (Get-LedgerPhase -Dir $script:Dir) | Should -Be @('started', 'succeeded')
    }
}

AfterAll {
    Clear-RecoveryAction
}
