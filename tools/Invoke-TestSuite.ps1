<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42859ca6-4a84-417f-b9e8-f2a3a4dd84a5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester runner
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
    Discover and run every Pester suite in the repo, one process per suite, and
    fail on any regression -- including the ones an exit code cannot express.
.DESCRIPTION
    The repo carries ~178 *.Tests.ps1 files, and this script is the only thing
    that runs them as a set. A suite nothing runs can stop being runnable and
    stay that way indefinitely.

    Each suite runs in its own pwsh process via tools/_InvokeOneSuite.ps1, so
    one suite's module imports, global state or crash cannot color another's
    result. Suites are ordered longest-first (using recorded durations when a
    baseline exists) because wall time is dominated by the slowest few.

    WHY THE RESULT FILE, NOT THE EXIT CODE, IS THE AUTHORITY: Pester's
    standalone path does not propagate a failing run through the call operator,
    so a suite whose tests fail still exits 0. Worse, a suite whose Describe
    discovers nothing also exits 0 -- with zero tests. Both are green to any
    caller that trusts rc. This script therefore reads the NUnit result file
    and treats a MISSING file as the process-level failure signal.

    Five conditions fail the run. Each exists because it has been observed or
    is structurally invisible to the others:
      1. the suite process did not produce a result file (crash, parse error,
         timeout)
      2. the result file reports failures or errors
      3. the result file reports zero tests -- a fixture set that quietly
         emptied reads as green otherwise
      4. a suite present in the baseline is missing from this run -- a deleted
         or renamed suite is silent test loss
      5. a suite's test count dropped below its baseline -- a Describe that
         stopped discovering half its cases is silent test loss too

    Conditions 4 and 5 need the baseline to mean anything, which is why it is
    tracked (test/modules/suite-baseline.json) rather than generated per
    machine. Per-run output is disposable and goes to a gitignored directory.

    The suites are NOT part of a test cycle and this script must never be
    called from one -- it runs beside the harness, on a developer or CI host.

.PARAMETER Root
    Tree to discover suites in. Defaults to the repo this script lives in.
    Pointing it at a fixture tree is how the runner's own suite exercises it;
    outside a git work tree discovery falls back to a filesystem walk.
.PARAMETER Path
    Root-relative directories to search. Default: test/modules, host/modules.
.PARAMETER Filter
    Wildcard applied to the suite file's base name, e.g. 'Test.Pool*'.
.PARAMETER ThrottleLimit
    Concurrent suite processes. Default 8.
.PARAMETER TimeoutSeconds
    Per-suite wall-clock limit before the process is killed. Default 300.
.PARAMETER ResultsPath
    Directory for per-suite NUnit XML and suite-results.json. Default
    .test-results (gitignored).
.PARAMETER BaselinePath
    Tracked baseline used by conditions 4 and 5. Default
    test/modules/suite-baseline.json.
.PARAMETER ListOnly
    Print the discovered suite paths and exit, running nothing. Lets a caller
    (and this script's own suite) check the discovery selector without paying
    for a full run.
.PARAMETER UpdateBaseline
    Rewrite the baseline from this run instead of comparing against it.
.PARAMETER PassThru
    Emit the result object on the pipeline.
.PARAMETER Quiet
    Print only the summary line.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1
    Runs every suite; exits non-zero on any of the five conditions.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -Filter 'Test.Pool*' -Quiet
    Runs one family, summary only.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -UpdateBaseline
    Re-records the tracked baseline after a deliberate, reviewed change.
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string[]]$Path = @('test/modules', 'host/modules'),
    [string]$Filter,
    [int]$ThrottleLimit = 8,
    [int]$TimeoutSeconds = 300,
    [string]$ResultsPath,
    [string]$BaselinePath,
    [switch]$ListOnly,
    [switch]$UpdateBaseline,
    [switch]$PassThru,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' })) {
    Write-Error "Pester 5+ is not installed. Install-Module Pester -Scope CurrentUser" -ErrorAction Continue
    exit 2
}

$RepoRoot = if ($Root) { (Resolve-Path -LiteralPath $Root).Path } else { Split-Path -Parent $PSScriptRoot }
$Shim     = Join-Path $PSScriptRoot '_InvokeOneSuite.ps1'
if (-not (Test-Path -LiteralPath $Shim)) {
    Write-Error "missing sibling script: $Shim" -ErrorAction Continue
    exit 2
}
if (-not $ResultsPath)  { $ResultsPath  = Join-Path $RepoRoot '.test-results' }
if (-not $BaselinePath) { $BaselinePath = Join-Path $RepoRoot 'test/modules/suite-baseline.json' }

# --- REGION: Discover the suites
# git ls-files is the same selector tools/Invoke-Lint.ps1 uses, so both gates
# see one set of files: tracked plus new, minus everything .gitignore covers.
# A working tree where the harness has run holds generated copies of suites
# under project/ and test/status/runtime/; walking the filesystem would sweep
# those in and run each suite twice.
function Get-SuiteFile {
    param([string]$Root, [string[]]$Under, [string]$NameFilter)

    $tracked = $null
    try {
        Push-Location $Root
        $tracked = @(git ls-files --cached --others --exclude-standard 2>$null |
            Where-Object { $_ -and $_ -match '\.Tests\.ps1$' })
    } catch {
        $tracked = $null
    } finally {
        Pop-Location
    }

    if (-not $tracked) {
        # No git, or not a work tree: fall back to a filesystem walk of the
        # requested directories only, which keeps the fallback from sweeping in
        # the generated trees above.
        $tracked = @(foreach ($u in $Under) {
                $full = Join-Path $Root $u
                if (Test-Path -LiteralPath $full) {
                    Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.Tests.ps1' |
                        ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/' }
                }
            })
    }

    $prefixes = @($Under | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') + '/' })
    $tracked |
        Where-Object { $p = $_; ($prefixes | Where-Object { $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) } |
        Where-Object { -not $NameFilter -or ([IO.Path]::GetFileName($_) -like $NameFilter) } |
        Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) } |
        Sort-Object -Unique
}

$suites = @(Get-SuiteFile -Root $RepoRoot -Under $Path -NameFilter $Filter)
if ($suites.Count -eq 0) {
    Write-Error "no *.Tests.ps1 found under: $($Path -join ', ')" -ErrorAction Continue
    exit 2
}

if ($ListOnly) {
    $suites
    exit 0
}

# --- REGION: Load the baseline
$baseline = $null
if ((Test-Path -LiteralPath $BaselinePath) -and -not $UpdateBaseline) {
    try {
        $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    } catch {
        Write-Error "baseline is unreadable ($BaselinePath): $($_.Exception.Message)" -ErrorAction Continue
        exit 2
    }
}

# Longest-first: the tail is set by the slowest suite, so starting it first is
# worth more than any other scheduling choice. Unknown suites sort first so a
# newly added one is never left to start last.
$order = @{}
if ($baseline -and $baseline.suites) {
    foreach ($p in $baseline.suites.PSObject.Properties) { $order[$p.Name] = [double]$p.Value.seconds }
}
$ordered = $suites | Sort-Object -Property @{ Expression = { if ($order.ContainsKey($_)) { -$order[$_] } else { [double]::NegativeInfinity } } }

$null = New-Item -ItemType Directory -Force -Path $ResultsPath
Get-ChildItem -LiteralPath $ResultsPath -Filter 'nunit-*.xml' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (-not $Quiet) {
    Write-Information "Running $($ordered.Count) suite(s), throttle $ThrottleLimit, timeout ${TimeoutSeconds}s" -InformationAction Continue
}

# --- REGION: Run
$sw = [Diagnostics.Stopwatch]::StartNew()
$results = $ordered | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $rel     = $_
    $root    = $using:RepoRoot
    $shim    = $using:Shim
    $outDir  = $using:ResultsPath
    $timeout = $using:TimeoutSeconds

    $xml = Join-Path $outDir ('nunit-' + ($rel -replace '[\\/]', '_') + '.xml')
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = (Get-Process -Id $PID).Path
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $root
    foreach ($a in @('-NoProfile', '-File', $shim, '-Suite', (Join-Path $root $rel), '-Xml', $xml)) {
        $psi.ArgumentList.Add($a)
    }

    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $p  = [Diagnostics.Process]::Start($psi)
    # Drain both streams before waiting: a suite that fills a 64 KB pipe buffer
    # would otherwise block forever and be killed as a false timeout. stdout is
    # drained and discarded -- the result file carries the counts, and a suite's
    # console chatter would drown the runner's own table.
    $null   = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($timeout * 1000)
    if ($timedOut) {
        # Already timing out; a failure to kill changes nothing the caller can
        # act on, and the rc=124 below is the signal that matters.
        try { $p.Kill($true) } catch { Write-Debug "kill after timeout failed: $($_.Exception.Message)" }
        $null = $p.WaitForExit(5000)
    }
    $t0.Stop()

    $rc  = if ($timedOut) { 124 } else { $p.ExitCode }
    $err = if ($timedOut) { "timed out after ${timeout}s" } else { ($stderr.Result | Out-String).Trim() }

    $total = $failed = $skipped = $errors = 0
    $haveXml = Test-Path -LiteralPath $xml
    if ($haveXml) {
        try {
            $r = ([xml](Get-Content -LiteralPath $xml -Raw)).'test-results'
            $total   = [int]$r.total
            $failed  = [int]$r.failures
            $errors  = [int]$r.errors
            $skipped = [int]$r.skipped + [int]$r.ignored + [int]$r.'not-run'
        } catch {
            $haveXml = $false
            $err = "unreadable result file: $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        path    = $rel
        rc      = $rc
        haveXml = $haveXml
        total   = $total
        failed  = $failed
        errors  = $errors
        skipped = $skipped
        seconds = [math]::Round($t0.Elapsed.TotalSeconds, 2)
        message = $err
    }
}
$sw.Stop()

# --- REGION: Adjudicate
$results = @($results | Sort-Object path)
$problems = [Collections.Generic.List[string]]::new()

foreach ($r in $results) {
    if (-not $r.haveXml) {
        $problems.Add("$($r.path): produced no result file (rc=$($r.rc))$(if ($r.message) { " -- $($r.message)" })")
        continue
    }
    if ($r.failed -gt 0 -or $r.errors -gt 0) {
        $problems.Add("$($r.path): $($r.failed) failed, $($r.errors) error(s)")
    }
    if ($r.total -eq 0) {
        $problems.Add("$($r.path): discovered 0 tests")
    }
}

if ($baseline -and $baseline.suites) {
    $seen = @{}
    foreach ($r in $results) { $seen[$r.path] = $r }
    foreach ($p in $baseline.suites.PSObject.Properties) {
        if (-not $seen.ContainsKey($p.Name)) {
            $problems.Add("$($p.Name): in the baseline but not in this run (deleted, renamed, or filtered out)")
            continue
        }
        $was = [int]$p.Value.total
        $now = $seen[$p.Name].total
        if ($now -lt $was) {
            $problems.Add("$($p.Name): $now tests, baseline had $was -- tests disappeared")
        }
    }
}

$totals = [pscustomobject]@{
    suites  = $results.Count
    tests   = [int]($results | Measure-Object total   -Sum).Sum
    failed  = [int]($results | Measure-Object failed  -Sum).Sum
    errors  = [int]($results | Measure-Object errors  -Sum).Sum
    skipped = [int]($results | Measure-Object skipped -Sum).Sum
    seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}

# --- REGION: Report
if (-not $Quiet) {
    $results |
        Select-Object @{n = 'suite'; e = { [IO.Path]::GetFileName($_.path) } },
                      @{n = 'tests'; e = { $_.total } },
                      @{n = 'fail';  e = { $_.failed + $_.errors } },
                      @{n = 'skip';  e = { $_.skipped } },
                      @{n = 'sec';   e = { $_.seconds } } |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        Write-Information -InformationAction Continue
}

$run = [pscustomobject]@{
    schemaVersion = 1
    startedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    host          = [Environment]::MachineName
    pwshVersion   = $PSVersionTable.PSVersion.ToString()
    pesterVersion = (Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
    throttle      = $ThrottleLimit
    totals        = $totals
    problems      = @($problems)
    suites        = $results
}
$run | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $ResultsPath 'suite-results.json') -Encoding utf8NoBOM

if ($UpdateBaseline) {
    $map = [ordered]@{}
    foreach ($r in $results) {
        $map[$r.path] = [ordered]@{ total = $r.total; skipped = $r.skipped; seconds = $r.seconds }
    }
    [ordered]@{
        schemaVersion = 1
        recordedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        pesterVersion = $run.pesterVersion
        totals        = [ordered]@{
            suites = $totals.suites; tests = $totals.tests
            failed = $totals.failed; skipped = $totals.skipped
        }
        suites        = $map
    } | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $BaselinePath -Encoding utf8NoBOM
    Write-Information "baseline written: $BaselinePath ($($totals.suites) suites, $($totals.tests) tests)" -InformationAction Continue
}

Write-Information ("{0} suite(s), {1} test(s), {2} failed, {3} skipped, {4}s" -f
    $totals.suites, $totals.tests, ($totals.failed + $totals.errors), $totals.skipped, $totals.seconds) -InformationAction Continue

if ($PassThru) { $run }

if ($problems.Count -gt 0) {
    Write-Information '' -InformationAction Continue
    foreach ($p in $problems) { Write-Error $p -ErrorAction Continue }
    exit 1
}
exit 0
