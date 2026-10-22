<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4254370d-577a-4b3f-a8a8-77e38fafee0e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner watcher
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Keep recorded suite passes current while the workspace changes, so the next
    foreground run of tools/Invoke-TestSuite.ps1 has little left to run.
.DESCRIPTION
    Every -IntervalSeconds the watcher fingerprints the workspace: this checkout
    and every Git checkout beside it (HEAD, every changed or untracked path with
    its size and time), plus the calendar day, because a recorded pass is
    reusable only on the day it was recorded. Once that fingerprint has stayed
    the same for -QuietSeconds and differs from the one last recorded, it runs
    the public suites, and the private ones under dev-only when they exist, with
    -Background: at idle priority, recording every suite that has no reusable
    pass, and launching no further suite while a foreground run is active. A
    change made during a round starts another round once the workspace is quiet.

    The watcher runs nothing a foreground run would not, and its results never
    replace one: a foreground run still decides, suite by suite, whether a
    record holds for the inputs it sees. Recording needs Linux, python3 and
    strace; the watcher refuses to start without them, since it could only
    repeat work no later run can reuse.

    Start it from the same kind of shell that runs the gates. The environment is
    part of every record's context, so a record made under another environment
    is not reused.
.PARAMETER IntervalSeconds
    Seconds between workspace fingerprints. Default 5.
.PARAMETER QuietSeconds
    Seconds the workspace must stay unchanged before a round starts. Default 15.
.PARAMETER ThrottleLimit
    Concurrent suite processes for each round. Default: half the logical
    processors, at least 2 and at most 16.
.PARAMETER Once
    Run one round now, whatever the fingerprint, and exit with its result.
.EXAMPLE
    pwsh tools/Start-TestWatcher.ps1
    Watch until stopped with Ctrl+C.
.EXAMPLE
    pwsh tools/Start-TestWatcher.ps1 -Once
    Record every suite without a reusable pass, then exit.
.OUTPUTS
    One line per round. -Once exits 0 when every suite ran or was reused and
    passed, 1 otherwise, and 2 when recording is unavailable here.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 3600)][int]$IntervalSeconds = 5,
    [ValidateRange(0, 3600)][int]$QuietSeconds = 15,
    [ValidateRange(1, 64)][int]$ThrottleLimit = [Math]::Clamp([int][Math]::Floor([Environment]::ProcessorCount / 2), 2, 16),
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $PSScriptRoot 'Invoke-TestSuite.ps1'
$DevOnlyRunner = Join-Path $RepoRoot 'dev-only/tools/Invoke-DevOnlyTests.ps1'

$tracer = if ($env:YURUNA_STRACE) { $env:YURUNA_STRACE } else {
    (Get-Command strace -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
$missing = @(
    if (-not $IsLinux) { 'Linux' }
    if (-not (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue)) { 'python3' }
    if (-not $tracer) { 'strace on PATH (or YURUNA_STRACE)' }
)
if ($missing.Count) {
    Write-Error "Start-TestWatcher: recording needs $($missing -join ', ')." -ErrorAction Continue
    exit 2
}

# --- REGION: Workspace fingerprint
# --no-optional-locks keeps the poll from taking index.lock for a stat refresh,
# which would fail an operator's git command that runs at the same moment.
function Get-WorkspaceState {
    $checkouts = @($RepoRoot) + @(Get-ChildItem -LiteralPath (Split-Path -Parent $RepoRoot) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $RepoRoot -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) } |
        ForEach-Object FullName)
    $text = [Text.StringBuilder]::new()
    $null = $text.Append("day=$([DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))/$([DateTime]::Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))`n")
    foreach ($checkout in $checkouts) {
        $head = git -C $checkout rev-parse HEAD 2>$null
        $null = $text.Append("$checkout HEAD=$head`n")
        $status = git -C $checkout --no-optional-locks status --porcelain=v1 -z --untracked-files=all 2>$null
        foreach ($entry in ([string]$status -split "`0")) {
            if ($entry.Length -lt 4) { continue }
            $null = $text.Append($entry)
            $file = [IO.FileInfo]::new((Join-Path $checkout $entry.Substring(3)))
            if ($file.Exists) { $null = $text.Append(" $($file.Length) $($file.LastWriteTimeUtc.Ticks)") }
            $null = $text.Append("`n")
        }
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text.ToString())))
}

# --- REGION: Rounds
function Invoke-Round {
    param([Parameter(Mandatory)][int]$Throttle)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $runs = @(
        @{ Name = 'suites'; Script = $Runner; Results = Join-Path $RepoRoot '.test-results/background' }
        if (Test-Path -LiteralPath $DevOnlyRunner) {
            @{ Name = 'dev-only suites'; Script = $DevOnlyRunner; Results = Join-Path $RepoRoot '.test-results/background-dev-only' }
        }
    )
    $passed = $true
    $parts = foreach ($run in $runs) {
        $argv = @('-NoProfile', '-NonInteractive', '-File', $run.Script, '-Background', '-Quiet', '-ResultsPath', $run.Results)
        if ($run.Script -eq $Runner) { $argv += @('-ThrottleLimit', [string]$Throttle) }
        $null = & (Get-Process -Id $PID).Path @argv 2>&1
        if ($LASTEXITCODE -ne 0) { $passed = $false }
        $report = Join-Path $run.Results 'suite-results.json'
        if (Test-Path -LiteralPath $report) {
            $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
            "$($run.Name): $($result.impact.reused) reused, $($result.impact.recorded) recorded, " +
                "$(@($result.suites).Count - $result.impact.reused - $result.impact.recorded) ran without a record, " +
                "$(@($result.problems).Count) problem(s)"
        } else { "$($run.Name): no report (exit $LASTEXITCODE)" }
    }
    Write-Information ("{0} round in {1:n0}s -- {2}" -f [DateTime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $clock.Elapsed.TotalSeconds,
        ($parts -join '; ')) -InformationAction Continue
    return $passed
}

if ($Once) {
    exit $(if (Invoke-Round -Throttle $ThrottleLimit) { 0 } else { 1 })
}

Write-Information "Start-TestWatcher: watching $RepoRoot and the checkouts beside it; Ctrl+C stops." -InformationAction Continue
$recordedState = $null
$seenState = $null
$quiet = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    $state = Get-WorkspaceState
    if ($state -cne $seenState) {
        $seenState = $state
        $quiet.Restart()
    }
    if ($state -cne $recordedState -and $quiet.Elapsed.TotalSeconds -ge $QuietSeconds) {
        $null = Invoke-Round -Throttle $ThrottleLimit
        $recordedState = $state
    }
    Start-Sleep -Seconds $IntervalSeconds
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
