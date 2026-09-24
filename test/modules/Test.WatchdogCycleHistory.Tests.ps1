<#PSScriptInfo
.VERSION 2026.09.24
.GUID 426ffdec-7946-4b27-9d2c-487151f04ec7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner watchdog history diagnostic pester
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
    Guards that a cycle the watchdog killed is recorded where a reader looks for
    it, and that a diagnostic capture cannot spend an exhausted budget.
.DESCRIPTION
    A killed inner never reaches Complete-Run, which is the only writer of a
    cycle-history row. Correcting the live status fields without also recording
    history leaves the host's own page showing an unbroken run of passes while
    the pool dashboard -- reading its own append-only ledger -- counts the
    failure. Two surfaces disagreeing about the same cycle is the condition
    these tests pin shut: the row is written, it is written once however many
    times the fault path runs, it keeps the '.incomplete/' folder the results
    actually live in, and it carries a classified cause instead of 'unknown'.

    The capture side pins the other half. A budget consulted only between rungs
    does not stop a pre-flight stage that reaches the host driver or the vault
    from being entered after the deadline and adding its own unbounded wait on
    top of a budget already gone.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1')               -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Status.psm1')                  -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1')         -Force -DisableNameChecking

    function Initialize-TempRuntimeDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-wdhist-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    # A document shaped like the one a cycle publishes while it is still
    # running: no finishedAt, folder still '.incomplete/', guests mid-flight.
    function New-RunningStatusDocument {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: constructs and returns the fixture document; changes no system state.')]
        param(
            [string]$CycleStartUtc = '2026-09-19T17:49:59Z',
            [array]$History = @()
        )
        return [ordered]@{
            schemaVersion  = 1
            host           = 'host.ubuntu.kvm'
            hostname       = 'test-host'
            cycleStartUtc  = $CycleStartUtc
            startedAt      = $CycleStartUtc
            finishedAt     = $null
            overallStatus  = 'running'
            cycle          = 1234
            cycleFolderUrl = 'log/001234.2026-09-19.17-49-59.42546f61.incomplete/'
            gitCommits     = @(@{ sha = 'abc1234'; repoUrl = 'https://example.invalid/repo' })
            lastFailure    = $null
            guests         = @(
                [ordered]@{
                    guestKey = 'guest.ubuntu.server.26'
                    status   = 'running'
                    failureArtifacts = ''
                    steps    = @(
                        [ordered]@{ name = 'New-VM'; status = 'pass'; startedAt = '2026-09-19T17:50:00Z'; finishedAt = '2026-09-19T17:50:11Z' }
                        [ordered]@{ name = 'Start-GuestOS'; status = 'running'; startedAt = '2026-09-19T17:50:11Z'; finishedAt = $null }
                    )
                }
            )
            sequences      = @(
                [ordered]@{ name = 'workload.guest.ubuntu.server.26'; guests = @('guest.ubuntu.server.26') }
            )
            history        = @($History)
        }
    }

    function Write-StatusDocument {
        param([string]$Dir, $Document)
        $path = Join-Path $Dir 'status.json'
        Set-Content -LiteralPath $path -Value ($Document | ConvertTo-Json -Depth 32) -Encoding utf8
        return $path
    }

    # -AsHashtable to match how the runner reads its own document: plain
    # ConvertFrom-Json coerces an ISO-8601 string into [datetime], so an
    # assertion on it would be testing the reader, not the file.
    function Read-StatusDocument {
        param([string]$Path)
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable)
    }

    # The schema-v2 record the outer watchdog writes for a kill it performed.
    function Write-SyntheticFailureRecord {
        param([string]$Dir, [string]$FailureClass = 'wait_timeout')
        $path = Join-Path $Dir 'last_failure.json'
        Set-Content -LiteralPath $path -Encoding utf8 -Value (@{
            schemaVersion        = 2
            reason               = 'watchdog_kill'
            failureClass         = $FailureClass
            severity             = 'hard'
            classificationSource = 'synthetic'
            description          = 'watchdog kill (inner runspace SIGKILLed)'
            action               = 'watchdog kill (inner runspace SIGKILLed)'
            stepNumber           = 0
            sequenceName         = ''
            vmName               = ''
            guestKey             = ''
        } | ConvertTo-Json -Depth 6)
        return $path
    }
}

Describe 'A cycle the watchdog killed reaches the host page history' {

    It 'writes the row Complete-Run never got to write' {
        $dir = Initialize-TempRuntimeDir
        try {
            $older = [ordered]@{ cycleStartUtc = '2026-09-19T16:47:49Z'; overallStatus = 'pass' }
            $path  = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument -History @($older))

            Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -Reason 'inner exited 137' -FailureRecordPath '' -Confirm:$false | Should -BeTrue

            $doc = Read-StatusDocument -Path $path
            @($doc.history).Count         | Should -Be 2
            # The new row describes the cycle the document is still on.
            $doc.history[0].cycleStartUtc | Should -Be $doc.cycleStartUtc
            $doc.history[0].overallStatus | Should -Be 'fail'
            # The row has to be self-dating: a killed cycle has no finishedAt of
            # its own, and a row without one cannot be ordered against the rest.
            $doc.history[0].finishedAt    | Should -Not -BeNullOrEmpty
            # The cycle that already closed its own books is untouched below it.
            ([datetime]$doc.history[1].cycleStartUtc).ToUniversalTime() | Should -Be ([datetime]'2026-09-19T16:47:49Z').ToUniversalTime()

            # The on-disk spelling is the contract: the pool aggregator and the
            # dashboard both parse these stamps out of the file, so the row has
            # to carry the same Z-suffixed form the live document does and not a
            # rendering that depends on who deserialized it.
            $raw = Get-Content -Raw -LiteralPath $path
            ([regex]::Matches($raw, '"cycleStartUtc":\s*"2026-09-19T17:49:59Z"')).Count | Should -Be 2
            # No stamp anywhere in the file may come back in .NET round-trip
            # form: re-reading and rewriting the whole document is how a reader's
            # rendering would leak into it, and '2026-09-19T17:49:59.0000000Z' is
            # not what the consumers of this file parse.
            $raw | Should -Not -Match '\.0000000'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the .incomplete folder the partial results actually live in' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            # Complete-Run strips the suffix because the folder is renamed right
            # after it. Nothing renames a killed cycle's folder, so a stripped
            # row here would link to a path that does not exist.
            $doc.history[0].cycleFolderUrl | Should -BeLike '*.incomplete/'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'carries the class the watchdog recorded instead of leaving it unknown' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path   = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            $record = Write-SyntheticFailureRecord -Dir $dir -FailureClass 'wait_timeout'

            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -Reason 'inner exited 137' -FailureRecordPath $record -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            # The pool aggregator reads lastFailure.failureClass off the live
            # document; without it every killed cycle lands in the dashboard's
            # failure-class breakdown as 'unknown'.
            $doc.lastFailure.failureClass         | Should -Be 'wait_timeout'
            $doc.history[0].lastFailure.failureClass | Should -Be 'wait_timeout'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'names a preamble stall when the kill left no record' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -Reason 'inner exited 137' -StalledPhase 'config-gate' -FailureRecordPath '' -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            $doc.lastFailure.failureClass | Should -Be 'preamble_stall'
            $doc.lastFailure.stepName     | Should -Be 'config-gate'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'names a killed cycle when it got past the preamble' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -Reason 'inner exited 137' -FailureRecordPath '' -Confirm:$false

            (Read-StatusDocument -Path $path).lastFailure.failureClass | Should -Be 'cycle_killed'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records one row for the fault-then-paused pair a single kill produces' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            # Exactly the sequence one kill drives: the inner is reaped, then the
            # failure pause opens behind it.
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -Reason 'inner exited 137' -FailureRecordPath '' -Confirm:$false
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' `
                -Reason 'failure-pause begin (inner exited 137)' -FailureRecordPath '' -Confirm:$false

            @((Read-StatusDocument -Path $path).history).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves alone a cycle that did close its own books' {
        $dir = Initialize-TempRuntimeDir
        try {
            $own  = [ordered]@{ cycleStartUtc = '2026-09-19T17:49:59Z'; overallStatus = 'pass' }
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument -History @($own))

            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            @($doc.history).Count         | Should -Be 1
            # Complete-Run's row is the richer one; this path must not restate it.
            $doc.history[0].overallStatus | Should -Be 'pass'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps a cause the inner had already classified' {
        $dir = Initialize-TempRuntimeDir
        try {
            $document = New-RunningStatusDocument
            $document.lastFailure = [ordered]@{ failureClass = 'script_error'; severity = 'hard' }
            $path   = Write-StatusDocument -Dir $dir -Document $document
            $record = Write-SyntheticFailureRecord -Dir $dir

            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -FailureRecordPath $record -Confirm:$false

            # A cycle that got far enough to classify itself has the better
            # answer; the generic one must not overwrite it.
            (Read-StatusDocument -Path $path).lastFailure.failureClass | Should -Be 'script_error'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'trims the history to the same depth Complete-Run keeps' {
        $dir = Initialize-TempRuntimeDir
        try {
            $rows = 1..5 | ForEach-Object {
                [ordered]@{ cycleStartUtc = "2026-09-1${_}T00:00:00Z"; overallStatus = 'pass' }
            }
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument -History @($rows))
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' `
                -MaxHistoryRuns 3 -FailureRecordPath '' -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            @($doc.history).Count         | Should -Be 3
            $doc.history[0].overallStatus | Should -Be 'fail'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'adds no row for a state that still produces a verdict' {
        $dir = Initialize-TempRuntimeDir
        try {
            $path = Write-StatusDocument -Dir $dir -Document (New-RunningStatusDocument)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'cycle-start' -Confirm:$false

            $doc = Read-StatusDocument -Path $path
            @($doc.history).Count | Should -Be 0
            $doc.overallStatus    | Should -Be 'running'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-RunnerFaultCause' {

    It 'prefers the record over the phrasing it was called with' {
        $dir = Initialize-TempRuntimeDir
        try {
            $record = Write-SyntheticFailureRecord -Dir $dir -FailureClass 'wait_timeout'
            $cause  = Get-RunnerFaultCause -FailureRecordPath $record -Reason 'inner exited 137' -StalledPhase 'config-gate'
            # One event, one class name: a reader of the record and a reader of
            # status.json must not come away with different vocabularies.
            $cause.failureClass | Should -Be 'wait_timeout'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to the reason when no record explains the kill' {
        $cause = Get-RunnerFaultCause -FailureRecordPath '' -Reason 'inner exited 137'
        $cause.failureClass | Should -Be 'cycle_killed'
        $cause.errorMessage | Should -Be 'inner exited 137'
        $cause.severity     | Should -Be 'hard'
    }

    It 'survives a record that is not readable as JSON' {
        $dir = Initialize-TempRuntimeDir
        try {
            $bad = Join-Path $dir 'last_failure.json'
            Set-Content -LiteralPath $bad -Value '{ this is not json' -Encoding utf8
            # A truncated record is exactly what a kill mid-write leaves behind,
            # so it must degrade to the synthesized cause rather than throw and
            # cost the cycle its only record.
            $cause = Get-RunnerFaultCause -FailureRecordPath $bad -Reason 'inner exited 137'
            $cause.failureClass | Should -Be 'cycle_killed'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-CycleHistoryEntry' {

    It 'summarizes the guest that was still in flight when the cycle died' {
        $document = New-RunningStatusDocument
        $entry = New-CycleHistoryEntry -Document $document -OverallStatus 'fail' `
            -CycleFolderUrl 'log/001234.incomplete/' -FinishedAt '2026-09-19T19:33:00Z'

        $entry.overallStatus | Should -Be 'fail'
        # Where it got to is the useful part of a killed cycle's row: the guest
        # keeps the status it held, and the verdict is carried by the row.
        $entry.guestSummary['guest.ubuntu.server.26'].status | Should -Be 'running'
        $entry.guestSummary['guest.ubuntu.server.26'].stepDurationsSeconds['New-VM'] | Should -Be 11
        $entry.totalDurationSeconds | Should -BeGreaterThan 0
    }

    It 'takes an explicit null cause over whatever the document carries' {
        $document = New-RunningStatusDocument
        $document.lastFailure = [ordered]@{ failureClass = 'script_error' }
        $entry = New-CycleHistoryEntry -Document $document -OverallStatus 'pass' `
            -CycleFolderUrl 'log/001234/' -LastFailure $null
        $entry.lastFailure | Should -BeNullOrEmpty
    }
}

Describe 'A diagnostic capture cannot spend a budget it has already used' {

    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        Import-Module (Join-Path $here 'Test.Diagnostic.psm1') -Force -DisableNameChecking
    }

    It 'reads a budget-exhausted capture as a timeout, not as an absence' {
        # The wording of the manifest reason is what Get-GuestDiagnosticOutcome
        # keys on; a stage gate that worded it differently would classify a
        # capture that ran out of time as merely 'unavailable'.
        $manifest = @{
            success = $false; outPath = $null; mechanism = 'none'
            skipped = $true;  bytes = 0L; exitCode = 0
            reason  = 'total 300s budget exhausted before the credential lookup'
        }
        $outcome = & (Get-Module Test.Diagnostic) { param($m) Get-GuestDiagnosticOutcome -Manifest $m } $manifest
        $outcome | Should -Be 'timeout'
    }

    It 'gates every pre-flight stage that reaches the host driver or the vault' {
        $here    = Split-Path -Parent $PSCommandPath
        $errs    = $null
        $ast     = [System.Management.Automation.Language.Parser]::ParseFile(
                       (Join-Path $here 'Test.Diagnostic.psm1'), [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty

        $capture = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                      $n.Name -eq 'Invoke-GuestDiagnosticCapture' }, $true)
        @($capture).Count | Should -Be 1

        # A gate is only worth having if it is reached before the call it
        # guards, so the count is pinned rather than merely its presence.
        $gates = $capture[0].FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      $n.GetCommandName() -eq 'Get-DiagBudgetSpentManifest' }, $true)
        @($gates).Count | Should -BeGreaterOrEqual 2
    }

    It 'measures the capture from outside, where every way out of it is visible' {
        $here = Split-Path -Parent $PSCommandPath
        $errs = $null
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile(
                    (Join-Path $here 'Test.Diagnostic.psm1'), [ref]$null, [ref]$errs)
        $save = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                      $n.Name -eq 'Save-GuestDiagnostic' }, $true)
        @($save).Count | Should -Be 1

        # Inside the capture the caps are per stage, so the whole capture's cost
        # is only knowable from its caller -- including the paths that throw.
        $text = $save[0].Extent.Text
        $text | Should -Match 'budgetExceeded'
        $text | Should -Match 'elapsedSeconds'
    }
}
