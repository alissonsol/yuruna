<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42f0b9d3-7c48-4a21-b5e6-08c9d13f7a25
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate pester baseline protection
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
    CI gate: the tracked suite baseline names every suite the runner discovers.
.DESCRIPTION
    The baseline is what stops a suite from disappearing quietly. The runner
    compares a run against it and refuses a suite that vanished or lost tests --
    but only for suites the baseline lists. A suite added after the baseline was
    recorded is protected by nothing: deleting it again fails no check, because
    the record that would have noticed never mentioned it.

    That is the gap this closes. It compares the runner's own discovery against
    the recorded set and fails when the two disagree in either direction:

      - a discovered suite the baseline never recorded, which is a suite whose
        deletion nothing would catch;
      - a recorded suite that no longer exists, which is a deletion that already
        happened and has to be an explicit re-record rather than a silent one.

    It also checks the record against itself. The totals block is what a release
    report quotes, so a totals line that does not equal the sum of the per-suite
    entries is a report that says something the evidence does not.

    This gate DISCOVERS; it does not run the tests. Discovery is the runner's
    own `-ListOnly` path, so there is one definition of what a suite is rather
    than a second one here that drifts. Running the suite is release
    preparation's job, and it records the result against the source commit.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  Every discovered suite is recorded and the totals are self-consistent.
        1  The baseline and the discovered set disagree.
        2  The gate could not reach a verdict -- the runner or the baseline is
           missing, or discovery failed.
.PARAMETER Root
    Repository root. Default: the parent of this script's directory.
.PARAMETER BaselinePath
    The baseline record to check. Default: test/modules/suite-baseline.json.
    For mutation tests, which point the gate at a deliberately edited copy.
.PARAMETER Quiet
    Print only the summary line. Findings still print.
.EXAMPLE
    pwsh tools/Test-SuiteBaseline.ps1
    # Checks the tracked baseline against discovery; exits 0 / 1 / 2.
#>

[CmdletBinding()]
[OutputType([void])]
param(
    [string]$Root,
    [string]$BaselinePath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $ToolRoot }

Import-Module (Join-Path $Root 'test/modules/Test.Prelude.psm1') -Global -Force
$ExitOk        = Get-EntryPointExitCode -Outcome Ok
$ExitFailure   = Get-EntryPointExitCode -Outcome Failure
$ExitCannotRun = Get-EntryPointExitCode -Outcome CannotRun

if (-not $BaselinePath) { $BaselinePath = Join-Path $Root 'test/modules/suite-baseline.json' }
$Runner = Join-Path $ToolRoot 'Invoke-TestSuite.ps1'

foreach ($required in @(
        @{ Path = $Runner;       What = 'the suite runner' }
        @{ Path = $BaselinePath; What = 'the tracked suite baseline' })) {
    if (-not (Test-Path -LiteralPath $required.Path -PathType Leaf)) {
        Write-Error -ErrorAction Continue `
            -Message ("Cannot evaluate the suite baseline: {0} is missing at {1}" -f $required.What, $required.Path)
        exit $ExitCannotRun
    }
}

# The runner's own discovery, so "a suite" means one thing in this repository.
# -ListOnly returns the names and runs nothing; a gate that launched the suite
# from inside another gate would turn one full run into several.
$pwshPath = (Get-Process -Id $PID).Path
if (-not $pwshPath) { $pwshPath = 'pwsh' }
$discovered = @(& $pwshPath -NoProfile -File $Runner -Root $Root -ListOnly 2>&1)
if ($LASTEXITCODE -ne 0) {
    Write-Error -ErrorAction Continue `
        -Message ("Cannot evaluate the suite baseline: discovery failed:`n{0}" -f ($discovered -join "`n"))
    exit $ExitCannotRun
}
$discovered = @($discovered | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
if ($discovered.Count -eq 0) {
    Write-Error -ErrorAction Continue -Message 'Cannot evaluate the suite baseline: discovery returned no suites.'
    exit $ExitCannotRun
}

$baseline = $null
try { $baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($BaselinePath)) }
catch {
    Write-Error -ErrorAction Continue `
        -Message ("Cannot evaluate the suite baseline: the record does not parse: {0}" -f $_.Exception.Message)
    exit $ExitCannotRun
}
if (-not $baseline.suites) {
    Write-Error -ErrorAction Continue -Message 'Cannot evaluate the suite baseline: the record lists no suites.'
    exit $ExitCannotRun
}
# The map is keyed by suite path. Any other shape -- an array, a string -- still
# answers PSObject.Properties, but with the container's own CLR members, so the
# comparison below would report every real suite as unprotected and the totals
# loop would throw on a member that is not a number. A record this gate cannot
# read is a verdict it cannot reach, not a disagreement it found.
if ($baseline.suites -isnot [Management.Automation.PSCustomObject]) {
    Write-Error -ErrorAction Continue `
        -Message 'Cannot evaluate the suite baseline: the record does not list suites as a name-keyed object.'
    exit $ExitCannotRun
}

$recorded = @($baseline.suites.PSObject.Properties.Name)
$findings = [Collections.Generic.List[string]]::new()

foreach ($suite in $discovered) {
    if ($recorded -cnotcontains $suite) {
        $findings.Add("$suite runs but is not in the baseline, so deleting it would fail nothing")
    }
}
foreach ($suite in $recorded) {
    if ($discovered -cnotcontains $suite) {
        $findings.Add("$suite is in the baseline but no longer discovered; re-record deliberately")
    }
}

# The totals are the numbers a release report quotes. They have to be the sum of
# what the record actually holds, not a line someone edited on its own.
if ($baseline.totals) {
    $sumSuites = $recorded.Count
    $sumTests = 0
    $sumSkipped = 0
    foreach ($property in $baseline.suites.PSObject.Properties) {
        $sumTests += [int]$property.Value.total
        $sumSkipped += [int]$property.Value.skipped
    }
    foreach ($check in @(
            @{ Name = 'suites'; Recorded = [int]$baseline.totals.suites; Computed = $sumSuites }
            @{ Name = 'tests'; Recorded = [int]$baseline.totals.tests; Computed = $sumTests }
            @{ Name = 'skipped'; Recorded = [int]$baseline.totals.skipped; Computed = $sumSkipped })) {
        if ($check.Recorded -ne $check.Computed) {
            $findings.Add(("the recorded {0} total is {1} but the per-suite entries sum to {2}" -f
                    $check.Name, $check.Recorded, $check.Computed))
        }
    }
    if ([int]$baseline.totals.failed -ne 0) {
        $findings.Add("the baseline records $([int]$baseline.totals.failed) failure(s); a protection floor is a passing run")
    }
} else {
    $findings.Add('the baseline records no totals, so a release report has nothing to quote')
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) {
        Write-Output ("PASS  {0} discovered suite(s), all recorded" -f $discovered.Count)
        Write-Output ("PASS  totals agree with the per-suite entries ({0} test(s))" -f [int]$baseline.totals.tests)
    }
    Write-Output ("Test-SuiteBaseline: {0} suite(s) / {1} test(s) protected." -f
        $discovered.Count, [int]$baseline.totals.tests)
    exit $ExitOk
}

Write-Warning ("Test-SuiteBaseline: {0} finding(s):" -f $findings.Count)
foreach ($finding in $findings) { Write-Warning ("  FINDING: {0}" -f $finding) }
Write-Warning ''
Write-Warning 'Fix: run the full suite and re-record the baseline from that run:'
Write-Warning '    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -UpdateBaseline'
Write-Warning '  Record it from a passing run. A baseline written over a failing one'
Write-Warning '  protects the failure.'
exit $ExitFailure
