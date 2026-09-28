<#PSScriptInfo
.VERSION 2026.09.27
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
    Directory for per-suite NUnit XML, retained worker logs, and
    suite-results.json. Default .test-results (gitignored). Only one runner
    may write to this directory at a time.
.PARAMETER BaselinePath
    Tracked baseline used by conditions 4 and 5. Default
    test/modules/suite-baseline.json.
.PARAMETER ListOnly
    Print the discovered suite paths and exit, running nothing. Lets a caller
    (and this script's own suite) check the discovery selector without paying
    for a full run.
.PARAMETER UpdateBaseline
    Atomically refresh the baseline only from a passing full run: the default
    discovery paths, or an explicit -Path together with its own -BaselinePath
    (a separately recorded suite set, such as the private suites under
    dev-only/test), and no Filter or ListOnly. The existing baseline still guards
    against lost suites/tests, and new skips are rejected. Result JSON and all
    NUnit files are revalidated before replacement. Deliberate test removal or
    new skip allowances require a separate reviewed baseline edit.
.PARAMETER RegisterNewSuites
    Run every discovered suite absent from an existing baseline and atomically
    add only those passing, unskipped rows. Existing rows and their historical
    full-run timestamp stay unchanged. Registration records its own timestamp
    and source hashes; it is not a full-run success claim. Refuse removed suites,
    changed discovery/source/baseline files, filters, and UpdateBaseline.
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
    [switch]$RegisterNewSuites,
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
$ResultsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsPath)
if (-not $BaselinePath) { $BaselinePath = Join-Path $RepoRoot 'test/modules/suite-baseline.json' }

# A narrower -Path is a different suite set. Recording it over the default
# baseline would drop every suite it did not discover, so it may refresh only
# a baseline of its own.
$privateScope = $PSBoundParameters.ContainsKey('Path') -and $PSBoundParameters.ContainsKey('BaselinePath')
if ($UpdateBaseline -and ($Filter -or $ListOnly -or (-not $privateScope -and
        @(Compare-Object @('host/modules', 'test/modules') @($Path | Sort-Object)).Count -ne 0))) {
    Write-Error 'UpdateBaseline requires a full run: the default Path, or an explicit -Path with its own -BaselinePath; no Filter, no ListOnly.' -ErrorAction Continue
    exit 2
}

if ($RegisterNewSuites -and ($UpdateBaseline -or $Filter -or $ListOnly -or (-not $privateScope -and
        @(Compare-Object @('host/modules', 'test/modules') @($Path | Sort-Object)).Count -ne 0))) {
    Write-Error 'RegisterNewSuites requires complete discovery, an existing baseline, and no Filter, ListOnly, or UpdateBaseline.' -ErrorAction Continue
    exit 2
}

# --- REGION: Assert-BaselineCount
function Assert-BaselineCount {
    param([AllowNull()]$Value, [string]$Label, [int]$Minimum = 0)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
        $Value -isnot [ValueType]) { throw "$Label is not an integer counter." }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $number -lt $Minimum -or $number -gt [int]::MaxValue -or $number -ne [math]::Truncate($number)) {
        throw "$Label is not a valid integer counter."
    }
    return [int]$number
}

# --- REGION: Assert-RefreshBaseline
function Assert-RefreshBaseline {
    param([Parameter(Mandatory)]$Baseline, [string[]]$AllowedRoot = @('test/modules', 'host/modules'))
    if ($Baseline -isnot [pscustomobject] -or $Baseline.schemaVersion -cne 1 -or
        $Baseline.suites -isnot [pscustomobject] -or $Baseline.totals -isnot [pscustomobject]) {
        throw 'Existing baseline has an invalid schema.'
    }
    $rows = @($Baseline.suites.PSObject.Properties)
    if ($rows.Count -eq 0) { throw 'Existing baseline contains no suites.' }
    $tests = $skips = 0L
    foreach ($row in $rows) {
        # Get-SuiteFile spells a root with forward slashes and no trailing one,
        # so 'dev-only/test/' or 'dev-only\test' must name the same rows here.
        if (-not ($AllowedRoot | Where-Object { $row.Name -like ((($_ -replace '\\', '/').TrimEnd('/')) + '/*.Tests.ps1') }) -or
            $row.Name -match '(?:^|/)\.\.(?:/|$)' -or $row.Value -isnot [pscustomobject]) {
            throw 'Existing baseline contains an invalid suite.'
        }
        $count = Assert-BaselineCount $row.Value.total "$($row.Name).total" -Minimum 1
        $skipped = Assert-BaselineCount $row.Value.skipped "$($row.Name).skipped"
        if ($skipped -gt $count) { throw 'Existing baseline contains impossible skip counts.' }
        $tests += $count
        $skips += $skipped
    }
    if ((Assert-BaselineCount $Baseline.totals.suites 'baseline.totals.suites' -Minimum 1) -ne $rows.Count -or
        (Assert-BaselineCount $Baseline.totals.tests 'baseline.totals.tests' -Minimum 1) -ne $tests -or
        (Assert-BaselineCount $Baseline.totals.skipped 'baseline.totals.skipped') -ne $skips -or
        (Assert-BaselineCount $Baseline.totals.failed 'baseline.totals.failed') -ne 0) {
        throw 'Existing baseline totals are inconsistent or contain failures.'
    }
}

# --- REGION: Assert-SuiteBaselineRefresh
function Assert-SuiteBaselineRefresh {
    param([Parameter(Mandatory)]$Run, [AllowNull()]$Baseline,
        [Parameter(Mandatory)][string[]]$ExpectedSuites, [Parameter(Mandatory)][string]$ResultsPath,
        [string[]]$AllowedRoot = @('test/modules', 'host/modules'))

    if ($Run -isnot [pscustomobject] -or $Run.schemaVersion -cne 1 -or
        $Run.totals -isnot [pscustomobject] -or $Run.suites -isnot [array] -or
        $Run.suites.Count -eq 0 -or $Run.problems -isnot [array] -or $Run.problems.Count -ne 0) {
        throw 'Baseline refresh requires a passing full-suite report.'
    }
    if ($Baseline) { Assert-RefreshBaseline -Baseline $Baseline -AllowedRoot $AllowedRoot }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sums = @{ suites = 0L; tests = 0L; failed = 0L; errors = 0L; skipped = 0L }
    foreach ($row in $Run.suites) {
        if ($row -isnot [pscustomobject] -or $row.path -isnot [string] -or
            $row.path -cnotin $ExpectedSuites -or -not $seen.Add($row.path) -or
            $row.haveXml -isnot [bool] -or -not $row.haveXml) {
            throw 'Baseline refresh report contains an invalid, duplicated, or XML-less suite.'
        }
        $counts = @{}
        foreach ($field in @('total', 'failed', 'errors', 'skipped', 'rc')) {
            $minimum = if ($field -ceq 'total') { 1 } else { 0 }
            $counts[$field] = Assert-BaselineCount $row.$field "$($row.path).$field" -Minimum $minimum
        }
        if ($counts.rc -ne 0 -or $counts.failed -ne 0 -or $counts.errors -ne 0 -or
            $counts.skipped -gt $counts.total) { throw "Suite '$($row.path)' did not pass." }
        $previous = if ($Baseline) { $Baseline.suites.PSObject.Properties[$row.path] } else { $null }
        $skipBudget = if ($previous) { $previous.Value.skipped } else { 0 }
        if ($counts.skipped -gt $skipBudget) { throw "Suite '$($row.path)' increased its skip budget ($skipBudget -> $($counts.skipped))." }
        if ($previous -and $counts.total -lt $previous.Value.total) { throw "Suite '$($row.path)' lost tests." }

        $xmlPath = Join-Path $ResultsPath ('nunit-' + ($row.path -replace '[\\/]', '_') + '.xml')
        $document = [xml](Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop)
        $xml = $document.'test-results'
        if (-not $xml) { throw "Missing NUnit test-results in '$xmlPath'." }
        $xmlCounts = @{}
        foreach ($field in @('total', 'failures', 'errors', 'skipped', 'ignored', 'not-run', 'inconclusive', 'invalid')) {
            $number = 0
            if (-not [int]::TryParse([string]$xml.GetAttribute($field), [ref]$number) -or $number -lt 0) {
                throw "Invalid NUnit '$field' in '$xmlPath'."
            }
            $xmlCounts[$field] = $number
        }
        $xmlSkipped = $xmlCounts.skipped + $xmlCounts.ignored + $xmlCounts.'not-run'
        $cases = @($document.SelectNodes('//test-case'))
        $unexecuted = @($cases | Where-Object { $_.GetAttribute('executed') -ceq 'False' })
        $unexpected = @($cases | Where-Object {
                -not (($_.GetAttribute('executed') -ceq 'True' -and $_.GetAttribute('result') -ceq 'Success' -and
                    $_.GetAttribute('success') -ceq 'True') -or
                    ($_.GetAttribute('executed') -ceq 'False' -and $_.GetAttribute('result') -cin @('Ignored', 'Skipped', 'NotRun')))
            })
        if ($xmlCounts.total -ne $counts.total -or $xmlCounts.failures -ne 0 -or $xmlCounts.errors -ne 0 -or
            $xmlCounts.inconclusive -ne 0 -or $xmlCounts.invalid -ne 0 -or $xmlSkipped -ne $counts.skipped -or
            $cases.Count -ne $counts.total -or $unexecuted.Count -ne $xmlSkipped -or $unexpected.Count -ne 0) {
            throw "NUnit evidence does not corroborate passing suite '$($row.path)'."
        }
        $sums.suites++
        $sums.tests += $counts.total
        foreach ($field in @('failed', 'errors', 'skipped')) { $sums[$field] += $counts[$field] }
    }
    if ($seen.Count -ne $ExpectedSuites.Count) { throw 'Full-suite report does not cover current discovery.' }
    if ($Baseline) {
        foreach ($previous in $Baseline.suites.PSObject.Properties) {
            if (-not $seen.Contains($previous.Name)) { throw "Baseline suite '$($previous.Name)' disappeared." }
        }
    }
    foreach ($field in @('suites', 'tests', 'failed', 'errors', 'skipped')) {
        if ((Assert-BaselineCount $Run.totals.$field "totals.$field") -ne $sums[$field]) {
            throw "Report totals.$field does not match suite evidence."
        }
    }
}

# --- REGION: Discover the suites
# git ls-files is the same selector tools/Invoke-Lint.ps1 uses, so both gates
# see one set of files: tracked plus new, minus everything .gitignore covers.
# A working tree where the harness has run holds generated copies of suites
# under project/ and test/status/runtime/; walking the filesystem would sweep
# those in and run each suite twice.
function Test-SuiteInScope {
    param([string]$RelativePath, [string[]]$Under, [string]$NameFilter)
    $relative = $RelativePath.Replace('\', '/')
    if ($NameFilter -and [IO.Path]::GetFileName($relative) -notlike $NameFilter) { return $false }
    foreach ($directory in $Under) {
        $prefix = $directory.Replace('\', '/').TrimEnd('/') + '/'
        if ($relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

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

    $tracked |
        Where-Object { Test-SuiteInScope -RelativePath $_ -Under $Under -NameFilter $NameFilter } |
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
$baselineHash = $null
if (Test-Path -LiteralPath $BaselinePath) {
    try {
        $baselineHash = (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash
        $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
        if ($UpdateBaseline -or $RegisterNewSuites) { Assert-RefreshBaseline -Baseline $baseline -AllowedRoot $Path }
    } catch {
        Write-Error "baseline is unreadable ($BaselinePath): $($_.Exception.Message)" -ErrorAction Continue
        exit 2
    }
}

$discoveredSuites = $suites
$registrationSourceHashes = [ordered]@{}
if ($RegisterNewSuites) {
    if (-not $baseline) {
        Write-Error 'RegisterNewSuites requires an existing valid baseline; use UpdateBaseline for the initial full run.' -ErrorAction Continue
        exit 2
    }
    $missing = @($baseline.suites.PSObject.Properties.Name | Where-Object { $_ -cnotin $discoveredSuites })
    if ($missing.Count) {
        Write-Error "Registration cannot remove baseline suites: $($missing -join ', ')" -ErrorAction Continue
        exit 1
    }
    $suites = @($discoveredSuites | Where-Object { $_ -cnotin $baseline.suites.PSObject.Properties.Name })
    if ($suites.Count -eq 0) {
        Write-Information 'Every discovered suite is already registered; the baseline was not changed.' -InformationAction Continue
        exit 0
    }
    foreach ($suite in $suites) {
        $registrationSourceHashes[$suite] = (Get-FileHash -LiteralPath (Join-Path $RepoRoot $suite) -Algorithm SHA256).Hash
    }
    Write-Information "Registering $($suites.Count) new suite(s); $($baseline.suites.PSObject.Properties.Name.Count) existing floors will remain unchanged and are not rerun." -InformationAction Continue
}

# Longest-first: the tail is set by the slowest suite, so starting it first is
# worth more than any other scheduling choice. Unknown suites sort first so a
# newly added one is never left to start last.
$order = @{}
if ($baseline -and $baseline.suites) {
    foreach ($p in $baseline.suites.PSObject.Properties) { $order[$p.Name] = [double]$p.Value.seconds }
}
$ordered = $suites | Sort-Object -Property @{ Expression = { if ($order.ContainsKey($_)) { -$order[$_] } else { [double]::NegativeInfinity } } }

# The cap exists to catch a suite that has stopped making progress, and one
# flat number cannot tell that apart from a suite whose honest work is simply
# longer than average -- the recorded cost above already knows the difference.
# Each suite therefore gets its own measured seconds plus the flat allowance,
# so the allowance keeps one meaning (time beyond what this suite needs) for a
# four-second suite and a four-minute one alike. A suite with no recorded cost
# is new, and keeps the flat value.
$timeoutFor = @{}
foreach ($rel in $ordered) {
    $recorded = if ($order.ContainsKey($rel)) { [math]::Max(0, [double]$order[$rel]) } else { 0 }
    $timeoutFor[$rel] = [int]($TimeoutSeconds + [math]::Ceiling($recorded))
}

$null = New-Item -ItemType Directory -Force -Path $ResultsPath
# Deterministic result names must not be removed or read by overlapping runs.
# Keep the lock file after disposal: unlinking it would let a third process
# lock a new inode while another process still holds the original one.
try {
    $resultLock = [IO.File]::Open((Join-Path $ResultsPath '.runner.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    Write-Error "Cannot lock results directory '$ResultsPath'; another runner may be using it. $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

try {
    $logDir = Join-Path $ResultsPath ('logs/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $logDir

    if (-not $Quiet) {
        Write-Information "Running $($ordered.Count) suite(s), throttle $ThrottleLimit, timeout ${TimeoutSeconds}s + each suite's recorded cost" -InformationAction Continue
    }

    # --- REGION: Run
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $results = $ordered | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $rel     = $_
        $root    = $using:RepoRoot
        $shim    = $using:Shim
        $outDir  = $using:ResultsPath
        $logs    = $using:logDir
        $caps    = $using:timeoutFor
        $timeout = if ($caps.ContainsKey($rel)) { $caps[$rel] } else { $using:TimeoutSeconds }

        $xml = Join-Path $outDir ('nunit-' + ($rel -replace '[\\/]', '_') + '.xml')
        # Clear only this suite's stale XML; a filtered run must preserve other
        # suites' evidence. The directory lock protects the whole publication.
        if (Test-Path -LiteralPath $xml) { Remove-Item -LiteralPath $xml -Force }
        $stdoutLog = Join-Path $logs ([IO.Path]::GetFileNameWithoutExtension($xml) + '.stdout.log')
        $stderrLog = Join-Path $logs ([IO.Path]::GetFileNameWithoutExtension($xml) + '.stderr.log')
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
        # would otherwise block forever and be killed as a false timeout. Pester
        # writes internal reporting errors to stdout, so retain both streams even
        # when the child exits successfully. Logs stay quiet unless evidence fails.
        $stdout = $p.StandardOutput.ReadToEndAsync()
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
        $out = if ($stdout.Wait(5000)) { $stdout.Result } else { '[stdout did not close after process exit or timeout]' }
        $err = if ($stderr.Wait(5000)) { $stderr.Result } else { '[stderr did not close after process exit or timeout]' }
        [IO.File]::WriteAllText($stdoutLog, $out, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderrLog, $err, [Text.UTF8Encoding]::new($false))
        $p.Dispose()
        $err = $err.Trim()
        if ($timedOut) { $err = "timed out after ${timeout}s`n$err".Trim() }

        $total = $failed = $skipped = $errors = 0
        $haveXml = Test-Path -LiteralPath $xml -PathType Leaf
        if ($haveXml) {
            try {
                $document = [xml](Get-Content -LiteralPath $xml -Raw -ErrorAction Stop)
                # NUnit's name attribute shadows Name in PowerShell's XML adapter.
                if ($document.DocumentElement.LocalName -cne 'test-results') { throw 'Expected an NUnit test-results root element.' }
                $r = $document.'test-results'
                $total   = [int]$r.total
                $failed  = [int]$r.failures
                $errors  = [int]$r.errors
                $skipped = [int]$r.skipped + [int]$r.ignored + [int]$r.'not-run'
            } catch {
                $haveXml = $false
                $err = "unreadable result file: $($_.Exception.Message)`n$err".Trim()
            }
        }

        if (-not $haveXml) {
            # A zero process exit cannot prove tests passed without their results.
            # Keep Pester's original diagnostic, which can be emitted only on stdout.
            $err = (@($err, $out.Trim(), "Worker logs: $stdoutLog ; $stderrLog") | Where-Object { $_ }) -join "`n"
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
            stdoutLog = $stdoutLog
            stderrLog = $stderrLog
        }
    }
    $sw.Stop()

    # --- REGION: Adjudicate
    $results = @($results | Sort-Object path)
    $problems = [Collections.Generic.List[string]]::new()

    foreach ($r in $results) {
        if ($r.rc -ne 0) { $problems.Add("$($r.path): suite process exited with rc=$($r.rc)") }
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

    if ($baseline -and $baseline.suites -and -not $RegisterNewSuites) {
        $seen = @{}
        foreach ($r in $results) { $seen[$r.path] = $r }
        foreach ($p in $baseline.suites.PSObject.Properties) {
            # A scoped run still detects missing suites within its selected scope.
            if (-not (Test-SuiteInScope -RelativePath $p.Name -Under $Path -NameFilter $Filter)) { continue }
            if (-not $seen.ContainsKey($p.Name)) {
                $problems.Add("$($p.Name): in the baseline but not in this run (deleted or renamed)")
                continue
            }
            # Missing evidence is already an infrastructure failure, not proof that
            # a suite discovered fewer tests. Keep the baseline unchanged either way.
            if (-not $seen[$p.Name].haveXml) { continue }
            $was = [int]$p.Value.total
            $now = $seen[$p.Name].total
            if ($now -lt $was) {
                $problems.Add("$($p.Name): $now tests, baseline had $was -- tests disappeared")
            }
        }
    }

    $totals = [pscustomobject]@{
        suites  = $results.Count
        incomplete = @($results | Where-Object { -not $_.haveXml -or $_.rc -ne 0 }).Count
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
                          @{n = 'result'; e = {
                                  if (-not $_.haveXml -or $_.rc -ne 0) { 'incomplete' }
                                  elseif ($_.failed -gt 0 -or $_.errors -gt 0 -or $_.total -eq 0) { 'failed' }
                                  else { 'passed' }
                              } },
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
        scope         = if ($RegisterNewSuites) { 'new-suite-registration' } elseif ($Filter) { 'filtered' } else { 'selected-paths' }
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

    if (($UpdateBaseline -or $RegisterNewSuites) -and $problems.Count -eq 0) {
        try {
            $currentSuites = @(Get-SuiteFile -Root $RepoRoot -Under $Path)
            if (@(Compare-Object $discoveredSuites $currentSuites).Count -ne 0) { throw 'Suite discovery changed during the run.' }
            $record = Get-Content -LiteralPath (Join-Path $ResultsPath 'suite-results.json') -Raw | ConvertFrom-Json
            if ($RegisterNewSuites) {
                # New rows have no skip allowance. Validate all of their NUnit cases
                # without presenting unexecuted historical rows as part of this run.
                Assert-SuiteBaselineRefresh -Run $record -Baseline $null -ExpectedSuites $suites -ResultsPath $ResultsPath -AllowedRoot $Path
                foreach ($suite in $suites) {
                    if ((Get-FileHash -LiteralPath (Join-Path $RepoRoot $suite) -Algorithm SHA256).Hash -cne $registrationSourceHashes[$suite]) {
                        throw "Suite source changed during registration: $suite"
                    }
                }
            } else {
                Assert-SuiteBaselineRefresh -Run $record -Baseline $baseline -ExpectedSuites $suites -ResultsPath $ResultsPath -AllowedRoot $Path
            }
            $currentHash = if (Test-Path -LiteralPath $BaselinePath) { (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash } else { $null }
            if ($currentHash -cne $baselineHash) { throw 'Baseline changed during the run; refusing to overwrite it.' }
        } catch {
            $problems.Add("Baseline was not changed: $($_.Exception.Message)")
            $run.problems = @($problems)
            $run | ConvertTo-Json -Depth 6 |
                Set-Content -LiteralPath (Join-Path $ResultsPath 'suite-results.json') -Encoding utf8NoBOM
        }
    }

    if (($UpdateBaseline -or $RegisterNewSuites) -and $problems.Count -eq 0) {
        $map = [ordered]@{}
        if ($RegisterNewSuites) {
            foreach ($row in $baseline.suites.PSObject.Properties) { $map[$row.Name] = $row.Value }
        }
        foreach ($r in $results) {
            $map[$r.path] = [pscustomobject][ordered]@{ total = $r.total; skipped = $r.skipped; seconds = $r.seconds }
        }
        if ($RegisterNewSuites) {
            $sortedMap = [ordered]@{}
            foreach ($name in ($map.Keys | Sort-Object)) { $sortedMap[$name] = $map[$name] }
            $baseline.suites = [pscustomobject]$sortedMap
            $baseline.totals = [pscustomobject][ordered]@{
                suites = $map.Count
                tests = [int]($map.Values | Measure-Object total -Sum).Sum
                failed = 0
                skipped = [int]($map.Values | Measure-Object skipped -Sum).Sum
            }
            $registration = [ordered]@{
                registeredUtc = [DateTime]::UtcNow.ToString('o')
                pesterVersion = $run.pesterVersion
                suites = [string[]]$suites
                tests = $totals.tests
                sourceSha256 = $registrationSourceHashes
            }
            $registrations = @()
            if ($baseline.PSObject.Properties['registrations']) { $registrations = @($baseline.registrations) }
            $baseline | Add-Member -NotePropertyName registrations -NotePropertyValue @($registrations + $registration) -Force
            Assert-RefreshBaseline -Baseline $baseline -AllowedRoot $Path
            $newBaseline = $baseline | ConvertTo-Json -Depth 8
        } else {
            $newBaseline = [ordered]@{
                schemaVersion = 1
                recordedUtc   = (Get-Date).ToUniversalTime().ToString('o')
                pesterVersion = $run.pesterVersion
                totals        = [ordered]@{
                    suites = $totals.suites; tests = $totals.tests
                    failed = $totals.failed; skipped = $totals.skipped
                }
                suites        = $map
            } | ConvertTo-Json -Depth 6
        }
        $temporaryBaseline = "$BaselinePath.$([guid]::NewGuid().ToString('n')).tmp"
        try {
            [IO.File]::WriteAllText($temporaryBaseline, $newBaseline + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporaryBaseline, $BaselinePath, $true)
        } finally {
            if (Test-Path -LiteralPath $temporaryBaseline) { Remove-Item -LiteralPath $temporaryBaseline -Force }
        }
        if ($RegisterNewSuites) {
            Write-Information "baseline registered: $($totals.suites) new suite(s), $($totals.tests) passing test(s); historical rows and full-run timestamp preserved." -InformationAction Continue
        } else {
            Write-Information "baseline written: $BaselinePath ($($totals.suites) suites, $($totals.tests) tests)" -InformationAction Continue
        }
    }

    Write-Information ("{0} suite(s), {1} test(s), {2} failed, {3} skipped, {4} incomplete suite(s), {5}s" -f
        $totals.suites, $totals.tests, ($totals.failed + $totals.errors), $totals.skipped, $totals.incomplete, $totals.seconds) -InformationAction Continue

    # Keep the report beside its logs so a later run does not erase the link
    # between an incomplete suite and its original diagnostics.
    $run | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $logDir 'suite-results.json') -Encoding utf8NoBOM

    if ($PassThru) { $run }

    if ($problems.Count -gt 0) {
        Write-Information '' -InformationAction Continue
        foreach ($p in $problems) { Write-Error $p -ErrorAction Continue }
        exit 1
    }
    exit 0
} finally {
    $resultLock.Dispose()
}
