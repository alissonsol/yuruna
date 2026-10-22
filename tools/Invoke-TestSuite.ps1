<#PSScriptInfo
.VERSION 2026.10.22
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
    Discover every tracked or new *.Tests.ps1 in the selected source roots.
    See https://yuruna.link/42d38664-000b for the suite execution contract.

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

    A baseline row is `total`, `skipped` and `seconds`, recorded by
    -UpdateBaseline on the reference host, plus three optional fields that are
    edited by hand in a reviewed change and that a refresh carries over:
      platformTotal   { "macos": 6 } -- the test count that platform must reach
                      when it differs from `total`. A suite that defines some of
                      its Describe blocks only on some platforms has fewer tests
                      elsewhere, and one flat count would fail every full run on
                      the platform with fewer. Platforms are windows, linux and
                      macos; one with no entry is held to `total`. A refresh on
                      another platform never lowers such a row's `total`.
      platformSkipped { "linux": 1, "windows": 0 } -- reviewed skip budgets for
                      known platforms. Missing entries use `skipped`; refresh
                      preserves both this map and that fallback budget. Actual
                      observed skips remain in suite-results.json.
      timeoutSeconds  a cap of its own for one suite, for a suite that takes
                      several times longer on a slow host than the recorded cost
                      plus the allowance covers. It only raises the cap.

    RECORDED PASSES: on Linux with strace and python3, a run with -Record traces
    each suite it runs (tools/suite_impact.py) and keeps, for every passing
    suite, the paths its process tree read, probed and listed, with their
    fingerprints and the suite's NUnit result. A later run without -All counts
    a recorded pass instead of running the suite again when every recorded input
    is unchanged and the record's context matches: the same calendar day, root,
    platform, toolchain, runner and environment (process and session identifiers
    excepted). A reused suite still goes through all five conditions, from its
    recorded NUnit file. Such a run is complete for a commit; a release runs with
    -All. Without strace or python3 nothing is recorded and every suite runs.
    Records live under the clone's Git directory (yuruna/test-impact).

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
    Concurrent suite processes. Default: half the logical processors, at least 8
    and at most 16. Past 16 the longest suite slows under the load faster than
    the extra workers finish the rest, so the run takes longer, not less.
.PARAMETER TimeoutSeconds
    Per-suite wall-clock limit before the process is killed. Default 300, added
    to the suite's recorded cost. A baseline row's `timeoutSeconds` raises the
    cap for that one suite.
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
.PARAMETER FailFast
    After a suite fails, stop its owned sibling processes and retain a result
    for every canceled or unlaunched suite with exit code 125. Such results
    are incomplete and fail the run. Successful runs retain full coverage;
    omit this switch to collect all failures. Existing suite deadlines still apply.
.PARAMETER Quiet
    Print only the summary line.
.PARAMETER All
    Run every selected suite, counting no recorded pass. Release gates use it.
    UpdateBaseline and RegisterNewSuites always behave this way.
.PARAMETER Record
    Trace every suite this run executes and record each one that passes. A
    traced suite runs slower (up to three times for one that probes many paths),
    so its cap is four times the untraced one. Ignored, with a note, where
    strace or python3 is unavailable.
.PARAMETER Background
    Record at idle priority, and launch no further suite while a run without
    this switch is active on the same clone. tools/Start-TestWatcher.ps1 runs
    the suites this way after each change so the next foreground run finds them
    recorded. Implies Record.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1
    Runs every suite without a reusable recorded pass; exits non-zero on any of
    the five conditions.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -All
    Runs every suite, as a release requires.
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
    [int]$ThrottleLimit = [Math]::Clamp([int][Math]::Floor([Environment]::ProcessorCount / 2), 8, 16),
    [int]$TimeoutSeconds = 300,
    [string]$ResultsPath,
    [string]$BaselinePath,
    [switch]$ListOnly,
    [switch]$UpdateBaseline,
    [switch]$RegisterNewSuites,
    [switch]$PassThru,
    [switch]$FailFast,
    [switch]$Quiet,
    [switch]$All,
    [switch]$Record,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]'6.0.0' -and $_.Version -lt [version]'7.0.0' })) {
    Write-Error "Pester 6.x is not installed. Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -SkipPublisherCheck" -ErrorAction Continue
    exit 2
}

$Platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
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

# --- REGION: Get-SuiteFloor
# The test count a suite must reach on this platform. A row's `total` is the count
# recorded on the reference host; a suite whose Describe blocks are defined only on
# some platforms legitimately has fewer tests elsewhere, and its row then names the
# floor for that platform in `platformTotal` (windows, linux or macos).
function Get-SuiteFloor {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Platform)
    $floors = $Row.PSObject.Properties['platformTotal']
    if ($floors -and $floors.Value -is [pscustomobject] -and $floors.Value.PSObject.Properties[$Platform]) {
        return [int]$floors.Value.$Platform
    }
    return [int]$Row.total
}

# --- REGION: Get-SuiteSkipBudget
function Get-SuiteSkipBudget {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Platform)
    $budgets = $Row.PSObject.Properties['platformSkipped']
    if ($budgets -and $budgets.Value -is [pscustomobject] -and $budgets.Value.PSObject.Properties[$Platform]) {
        return [int]$budgets.Value.$Platform
    }
    return [int]$Row.skipped
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
        # Reviewed platform floors and skip budgets survive refresh alongside
        # per-suite timeouts; one platform must not weaken another's coverage.
        if ($row.Value.PSObject.Properties['platformTotal']) {
            $floors = $row.Value.platformTotal
            if ($floors -isnot [pscustomobject]) { throw "Suite '$($row.Name)' has an invalid platformTotal." }
            foreach ($floor in $floors.PSObject.Properties) {
                if ($floor.Name -cnotin @('windows', 'linux', 'macos')) { throw "Suite '$($row.Name)' names an unknown platform '$($floor.Name)'." }
                $null = Assert-BaselineCount $floor.Value "$($row.Name).platformTotal.$($floor.Name)" -Minimum 1
            }
        }
        if ($row.Value.PSObject.Properties['timeoutSeconds']) {
            $null = Assert-BaselineCount $row.Value.timeoutSeconds "$($row.Name).timeoutSeconds" -Minimum 1
        }
        if ($row.Value.PSObject.Properties['platformSkipped']) {
            $budgets = $row.Value.platformSkipped
            if ($budgets -isnot [pscustomobject]) { throw "Suite '$($row.Name)' has an invalid platformSkipped." }
            foreach ($budget in $budgets.PSObject.Properties) {
                if ($budget.Name -cnotin @('windows', 'linux', 'macos')) { throw "Suite '$($row.Name)' names an unknown platform '$($budget.Name)'." }
                if (($budget.Value -isnot [int] -and $budget.Value -isnot [long]) -or $budget.Value -lt 0 -or
                    $budget.Value -gt (Get-SuiteFloor -Row $row.Value -Platform $budget.Name)) {
                    throw "$($row.Name).platformSkipped.$($budget.Name) must be a nonnegative integer no greater than the platform test count."
                }
            }
        }
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
        [string[]]$AllowedRoot = @('test/modules', 'host/modules'),
        [ValidateSet('windows', 'linux', 'macos')][string]$Platform = $(if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }))

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
        $skipBudget = if ($previous) { Get-SuiteSkipBudget -Row $previous.Value -Platform $Platform } else { 0 }
        if ($counts.skipped -gt $skipBudget) { throw "Suite '$($row.path)' increased its skip budget ($skipBudget -> $($counts.skipped))." }
        if ($previous -and $counts.total -lt (Get-SuiteFloor -Row $previous.Value -Platform $Platform)) { throw "Suite '$($row.path)' lost tests." }

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

# --- REGION: Recorded passes
# A recorded pass stands only for what strace saw the suite read. Whatever it
# cannot see reaches every record through the context: the calendar day (tests
# read the clock), the root, platform, account, toolchain, the runner's own
# files and the environment. The environment leaves out the variables the
# runner sets for each suite and the ones that only name a process, session,
# socket or token, which differ in every shell and that no suite branches on.
$script:ImpactVolatileVariable = '^(_|PWD|OLDPWD|SHLVL|COLUMNS|LINES|TMPDIR|TMP|TEMP|YURUNA_TEST_TEMP_ROOT|DOTNET_EnableDiagnostics|' +
    'CLAUDE_PID|CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_MESSAGING_SOCKET|CLAUDE_CODE_MESSAGING_TOKEN|CLAUDE_CODE_SSE_PORT|' +
    'VSCODE_PID|VSCODE_IPC_HOOK.*|VSCODE_GIT_IPC_HANDLE|GIO_LAUNCHED_DESKTOP_FILE_PID|INVOCATION_ID|JOURNAL_STREAM|MANAGERPID|' +
    'SYSTEMD_EXEC_PID|SSH_AUTH_SOCK|SSH_AGENT_PID|GPG_AGENT_INFO|DBUS_SESSION_BUS_ADDRESS|SESSION_MANAGER|XAUTHORITY|WINDOWID|' +
    'TERM_SESSION_ID|TMUX_PANE|GOTELEMETRY_GOPLS_CLIENT_START_TIME|GOTELEMETRY_GOPLS_CLIENT_TOKEN|MEMORY_PRESSURE_WATCH|MEMORY_PRESSURE_WRITE)$'

function Get-SuiteImpactContext {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$PesterVersion, [Parameter(Mandatory)][string[]]$File)
    $variables = [Environment]::GetEnvironmentVariables()
    $names = [string[]]@($variables.Keys | Where-Object { $_ -cnotmatch $script:ImpactVolatileVariable })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $environment = ($names | ForEach-Object { "$_=$($variables[$_])" }) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = { param([byte[]]$Bytes) [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
        $lines = @(
            'schema=1'
            "day=$([DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))/$([DateTime]::Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))"
            "root=$Root"
            "platform=$([Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier)"
            "user=$([Environment]::UserName)"
            "pwsh=$($PSVersionTable.PSVersion)"
            "pester=$PesterVersion"
            "environment=$(& $digest ([Text.Encoding]::UTF8.GetBytes($environment)))"
        )
        $lines += @($File | ForEach-Object { "file=$([IO.Path]::GetFileName($_)):$(& $digest ([IO.File]::ReadAllBytes($_)))" })
        return (& $digest ([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))
    } finally { $sha.Dispose() }
}

# Decides what this run may reuse and record. Every missing piece turns the
# feature off with a note and leaves the run as it would be without it: every
# suite runs and nothing is recorded.
function Get-SuiteImpactSetting {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ToolDirectory, [Parameter(Mandatory)][string]$PesterVersion,
        [switch]$Reuse, [switch]$Record)
    $setting = @{ Reuse = $false; Record = $false; Note = $null; ImpactRoot = $null; Cache = $null }
    if (-not ($Reuse -or $Record)) { return $setting }
    $tool = Join-Path $ToolDirectory 'suite_impact.py'
    if (-not $IsLinux) { $setting.Note = 'recorded passes need strace, which runs only on Linux'; return $setting }
    if (-not (Test-Path -LiteralPath $tool)) { $setting.Note = "recorded passes need $tool"; return $setting }
    $python = Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { $setting.Note = 'recorded passes need python3'; return $setting }
    $commonDirectory = git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $commonDirectory) { $setting.Note = 'recorded passes need a Git work tree to keep them in'; return $setting }
    $setting.ImpactRoot = Join-Path ([string]$commonDirectory) 'yuruna/test-impact'
    # Worktrees share one Git directory; each root keeps records of its own.
    $rootKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Root))).Substring(0, 16).ToLowerInvariant()
    $setting.Cache = Join-Path $setting.ImpactRoot $rootKey
    $setting.Python = $python.Source
    $setting.Tool = $tool
    $setting.Context = Get-SuiteImpactContext -Root $Root -PesterVersion $PesterVersion -File @($PSCommandPath, (Join-Path $ToolDirectory '_InvokeOneSuite.ps1'), $tool)
    $setting.Reuse = [bool]$Reuse
    if ($Record) {
        $tracer = if ($env:YURUNA_STRACE) { $env:YURUNA_STRACE } else {
            (Get-Command strace -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        }
        if (-not $tracer) {
            $setting.Note = 'nothing is recorded: strace is not on PATH (set YURUNA_STRACE to use another copy)'
        } else {
            # The probe uses the options a recording uses, so an older strace or a
            # host that forbids ptrace is found here instead of in every suite.
            $null = & $tracer -f -q -y --seccomp-bpf -e signal=none -e 'trace=%file,%process,getdents64,fchdir' -o /dev/null -- true 2>&1
            if ($LASTEXITCODE -ne 0) {
                $setting.Note = "nothing is recorded: $tracer cannot trace here (ptrace denied, or a strace older than 6.0)"
            } else {
                $setting.Record = $true
                $setting.Tracer = $tracer
                # Records are compared by content inside the workspace: this root
                # and every Git checkout beside it.
                $parent = Split-Path -Parent $Root
                $setting.Zone = @($Root) + @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -ne $Root -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) } |
                    ForEach-Object FullName)
            }
        }
    }
    return $setting
}

# Background runs yield to foreground ones. A foreground run holds a lock file
# open for its whole run; one that crashed leaves a file anyone can open, which
# is removed once it is old enough that it cannot be one still being locked.
function Test-ForegroundRun {
    param([string]$Directory)
    if (-not $Directory -or -not [IO.Directory]::Exists($Directory)) { return $false }
    foreach ($lock in [IO.Directory]::GetFiles($Directory, '*.lock')) {
        try {
            ([IO.File]::Open($lock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)).Dispose()
            if ([IO.File]::GetLastWriteTimeUtc($lock) -lt [DateTime]::UtcNow.AddMinutes(-1)) {
                Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
            }
        } catch [IO.FileNotFoundException] {
            continue
        } catch {
            return $true
        }
    }
    return $false
}

function Get-NUnitCount {
    param([Parameter(Mandatory)][string]$Path)
    $document = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    if ($document.DocumentElement.LocalName -cne 'test-results') { throw 'Expected an NUnit test-results root element.' }
    $r = $document.'test-results'
    [pscustomobject]@{
        total = [int]$r.total; failed = [int]$r.failures; errors = [int]$r.errors
        skipped = [int]$r.skipped + [int]$r.ignored + [int]$r.'not-run'
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
$baselineRow = @{}
if ($baseline -and $baseline.suites) {
    foreach ($p in $baseline.suites.PSObject.Properties) {
        $order[$p.Name] = [double]$p.Value.seconds
        $baselineRow[$p.Name] = $p.Value
    }
}
$ordered = $suites | Sort-Object -Property @{ Expression = { if ($order.ContainsKey($_)) { -$order[$_] } else { [double]::NegativeInfinity } } }

# The cap exists to catch a suite that has stopped making progress, and one
# flat number cannot tell that apart from a suite whose honest work is simply
# longer than average -- the recorded cost above already knows the difference.
# Each suite therefore gets its own measured seconds plus the flat allowance,
# so the allowance keeps one meaning (time beyond what this suite needs) for a
# four-second suite and a four-minute one alike. A suite with no recorded cost
# is new, and keeps the flat value.
#
# A suite whose honest work is longer than its recorded cost plus the allowance on
# some host (one that takes 230 s on a fast host and 700 s on a slow one) names a
# cap of its own in its baseline row: `timeoutSeconds`. It can only raise the cap,
# never lower it below what the recorded cost already earns.
$timeoutFor = @{}
foreach ($rel in $ordered) {
    $recorded = if ($order.ContainsKey($rel)) { [math]::Max(0, [double]$order[$rel]) } else { 0 }
    $cap = [int]($TimeoutSeconds + [math]::Ceiling($recorded))
    $own = 0
    if ($baselineRow.ContainsKey($rel) -and $baselineRow[$rel].PSObject.Properties['timeoutSeconds']) {
        $null = [int]::TryParse([string]$baselineRow[$rel].timeoutSeconds, [ref]$own)
    }
    $timeoutFor[$rel] = [math]::Max($cap, $own)
}

$pesterVersion = (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'6.0.0' -and $_.Version -lt [version]'7.0.0' } |
    Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
$impact = Get-SuiteImpactSetting -Root $RepoRoot -ToolDirectory $PSScriptRoot -PesterVersion $pesterVersion `
    -Reuse:(-not ($All -or $UpdateBaseline -or $RegisterNewSuites)) -Record:($Record -or $Background)
if ($Background) {
    # Every suite process inherits the idle priority, so the operator's own
    # work and any foreground run keep the processors first.
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::Idle
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

$failureSignal = [Threading.ManualResetEventSlim]::new($false)
$runTemp = $null
$runLock = $null
$foregroundLock = $null
try {
    $logDir = Join-Path $ResultsPath ('logs/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $logDir

    $foregroundDirectory = if ($impact.ImpactRoot) { Join-Path $impact.ImpactRoot 'foreground' } else { $null }
    if ($foregroundDirectory -and -not $Background) {
        try {
            $null = New-Item -ItemType Directory -Force -Path $foregroundDirectory
            $foregroundLockPath = Join-Path $foregroundDirectory "$PID-$([guid]::NewGuid().ToString('N')).lock"
            $foregroundLock = [IO.File]::Open($foregroundLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch {
            Write-Verbose "background runs will not yield to this one: $($_.Exception.Message)"
        }
    }

    # --- REGION: Reuse recorded passes
    # A reused suite's recorded NUnit file goes where its run would have written
    # one, so the five conditions and every later reader see the same evidence.
    $reused = [Collections.Generic.List[object]]::new()
    $whyRun = @{}
    if ($impact.Reuse -and $ordered.Count) {
        $answers = $null
        try {
            $answerText = ConvertTo-Json -InputObject @{ suites = @($ordered) } -Compress |
                & $impact.Python $impact.Tool check --cache $impact.Cache --context $impact.Context
            if ($LASTEXITCODE -ne 0) { throw "suite_impact.py check exited with $LASTEXITCODE" }
            $answers = ($answerText -join "`n") | ConvertFrom-Json -AsHashtable
        } catch {
            $impact.Note = "recorded passes were not consulted: $($_.Exception.Message)"
        }
        if ($answers) {
            $remaining = [Collections.Generic.List[string]]::new()
            foreach ($rel in $ordered) {
                $answer = $answers[$rel]
                if ($answer -and $answer.hit) {
                    $xml = Join-Path $ResultsPath ('nunit-' + ($rel -replace '[\\/]', '_') + '.xml')
                    try {
                        [IO.File]::WriteAllText($xml, [string]$answer.nunit, [Text.UTF8Encoding]::new($false))
                        $count = Get-NUnitCount -Path $xml
                        # ConvertFrom-Json turns an ISO 8601 string into a DateTime.
                        $recordedAt = $answer.recordedUtc
                        if ($recordedAt -is [datetime]) {
                            $recordedAt = $recordedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
                        }
                        $reused.Add([pscustomobject]@{
                                path = $rel; rc = 0; haveXml = $true; total = $count.total; failed = $count.failed
                                errors = $count.errors; skipped = $count.skipped; seconds = 0; message = ''
                                stdoutLog = $null; stderrLog = $null; impact = "reused the pass recorded at $recordedAt"
                            })
                        continue
                    } catch {
                        Remove-Item -LiteralPath $xml -Force -ErrorAction SilentlyContinue
                        $answer = @{ reason = "the recorded NUnit file is unreadable: $($_.Exception.Message)" }
                    }
                }
                $whyRun[$rel] = if ($answer) { [string]$answer.reason } else { 'no recorded pass' }
                $remaining.Add($rel)
            }
            $ordered = @($remaining)
        }
    }
    if (($Record -or $Background) -and -not $impact.Record) {
        Write-Warning "Invoke-TestSuite: $($impact.Note)"
    } elseif ($impact.Note -and -not $Quiet) {
        Write-Information "Invoke-TestSuite: $($impact.Note)" -InformationAction Continue
    }
    $recording = if ($impact.Record) {
        # Paths under these never count as inputs: this run's results and
        # temporary folders, the gitignored folder every run writes its results
        # under, the clone's own caches, and the user's cache. Resolving a
        # results path lists its parent, which other runs keep changing.
        $ignore = @($ResultsPath, (Join-Path $RepoRoot '.test-results'), (Split-Path -Parent $impact.ImpactRoot))
        if ($env:HOME) { $ignore += Join-Path $env:HOME '.cache' }
        @{ Python = $impact.Python; Tool = $impact.Tool; Tracer = $impact.Tracer; Cache = $impact.Cache
            Context = $impact.Context; Zone = $impact.Zone; Ignore = $ignore }
    } else { $null }
    $foregroundCheck = if ($Background) { ${function:Test-ForegroundRun}.ToString() } else { $null }

    if (-not $Quiet) {
        $reusedText = if ($reused.Count) { " ($($reused.Count) more reused from recorded passes)" } else { '' }
        $tracedText = if ($recording) { ', traced, timeout x4' } else { '' }
        Write-Information "Running $($ordered.Count) suite(s)$reusedText, throttle $ThrottleLimit, timeout ${TimeoutSeconds}s + each suite's recorded cost$tracedText" -InformationAction Continue
    }

    # --- REGION: Run
    # One master folder per run holds every suite's folder, and the master goes
    # only when the run ends. A cygwin mount keeps the TMP of the first process
    # that starts, so removing a suite folder early would leave /tmp dangling
    # for every later bash process. The lock is held for the whole run: the
    # stale-temp sweep treats a master whose lock cannot be taken as belonging
    # to a live run, and a crashed run releases the lock with its process.
    $runTempBase = if ($IsWindows) { [IO.Path]::GetTempPath() } else { '/tmp' }
    $runTemp = Join-Path $runTempBase ('yrn-run-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Force -Path $runTemp
    $runLock = [IO.File]::Open((Join-Path $runTemp 'run.lock'), [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $Quiet) { $InformationPreference = 'Continue' }
    $results = $ordered | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $rel     = $_
        $root    = $using:RepoRoot
        $shim    = $using:Shim
        $outDir  = $using:ResultsPath
        $logs    = $using:logDir
        $runTempRoot = $using:runTemp
        $caps    = $using:timeoutFor
        $signal  = $using:failureSignal
        $timeout = if ($caps.ContainsKey($rel)) { $caps[$rel] } else { $using:TimeoutSeconds }
        $recording = $using:recording
        $whyRun = ($using:whyRun)[$rel]
        $impactNote = $whyRun
        $foregroundCheck = $using:foregroundCheck
        if ($foregroundCheck -and (& ([scriptblock]::Create($foregroundCheck)) -Directory $using:foregroundDirectory)) {
            $reason = 'not launched: a foreground run is active on this clone'
            return [pscustomobject]@{
                path = $rel; rc = 125; haveXml = $false; total = 0; failed = 0; errors = 0; skipped = 0
                seconds = 0; message = $reason; stdoutLog = $null; stderrLog = $null; impact = $reason
            }
        }
        if (-not $using:Quiet) {
            $shownLimit = if ($recording) { "${timeout}s, x4 while traced" } else { "${timeout}s" }
            Write-Information "Starting $rel (limit $shownLimit)" -InformationAction Continue
        }

        $xml = Join-Path $outDir ('nunit-' + ($rel -replace '[\\/]', '_') + '.xml')
        # Clear only this suite's stale XML; a filtered run must preserve other
        # suites' evidence. The directory lock protects the whole publication.
        if (Test-Path -LiteralPath $xml) { Remove-Item -LiteralPath $xml -Force }
        $stdoutLog = Join-Path $logs ([IO.Path]::GetFileNameWithoutExtension($xml) + '.stdout.log')
        $stderrLog = Join-Path $logs ([IO.Path]::GetFileNameWithoutExtension($xml) + '.stderr.log')
        if ($using:FailFast -and $signal.IsSet) {
            $reason = 'not launched after another suite failed (FailFast)'
            [IO.File]::WriteAllText($stdoutLog, '', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stderrLog, $reason, [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                path = $rel; rc = 125; haveXml = $false; total = 0; failed = 0; errors = 0; skipped = 0
                seconds = 0; message = $reason; stdoutLog = $stdoutLog; stderrLog = $stderrLog; impact = $impactNote
            }
        }
        # Each suite gets a temp folder of its own under the run's master
        # folder. Every process the suite starts inherits it through TMPDIR
        # (Unix) and TMP/TEMP (Windows), so a test that leaks, a child that is
        # killed mid-write and Pester's own TestDrive all land in a folder the
        # run removes. The folder is kept after the worker exits, including
        # after a timeout or cancellation kill: a cygwin process started later
        # in the run would otherwise inherit a dangling /tmp. The master is
        # removed when the run ends. /tmp rather than a long $TMPDIR on Unix: the
        # runtime's sockets live in this folder and a Unix socket path is capped
        # near 104 bytes on macOS. DOTNET_EnableDiagnostics=0 stops every .NET
        # child from creating the debugger FIFOs and diagnostic socket at all;
        # nobody attaches a debugger to a suite worker.
        $suiteTemp = Join-Path $runTempRoot ('yrn-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        $null = New-Item -ItemType Directory -Force -Path $suiteTemp

        # A traced suite that does not pass runs again untraced, and that run
        # decides. ptrace changes how a traced process dies -- a killed child
        # stays visible until strace reaps it -- so a test that bounds a process
        # kill, or a stop strace cannot follow, can fail only because it was
        # traced. A suite that fails that way twice in the context's day runs
        # untraced for the rest of it; one such failure can be a load flake,
        # which tracing makes likelier.
        $trace = [bool]$recording
        $untraceableMark = $null
        $untraceable = $false
        $tracedFailures = 0
        if ($recording) {
            $untraceableMark = Join-Path $recording.Cache ('untraceable/' +
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($rel))).Substring(0, 32).ToLowerInvariant())
            if ([IO.File]::Exists($untraceableMark)) {
                $mark = [IO.File]::ReadAllLines($untraceableMark)
                if ($mark.Count -ge 2 -and $mark[0] -ceq $recording.Context) { $null = [int]::TryParse($mark[1], [ref]$tracedFailures) }
            }
            if ($tracedFailures -ge 2) {
                $trace = $false
                $untraceable = $true
            }
        }
        $tracedFailure = $null
        while ($true) {
            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = (Get-Process -Id $PID).Path
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.WorkingDirectory       = $root
            foreach ($name in 'TMPDIR', 'TMP', 'TEMP', 'YURUNA_TEST_TEMP_ROOT') { $psi.Environment[$name] = $suiteTemp }
            $psi.Environment['DOTNET_EnableDiagnostics'] = '0'
            # NonInteractive is process-local; every nested launcher must set it so
            # an unexpected host prompt fails instead of waiting on the operator.
            foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $shim, '-Suite', (Join-Path $root $rel), '-Xml', $xml)) {
                $psi.ArgumentList.Add($a)
            }
            $observations = $null
            if ($trace) {
                # The same suite process, started by the recorder under strace.
                $observations = Join-Path $suiteTemp 'observations.json'
                $traced = [Collections.Generic.List[string]]::new()
                $traced.AddRange([string[]]@($recording.Tool, 'run', '--strace', $recording.Tracer, '--out', $observations))
                foreach ($zone in $recording.Zone) { $traced.AddRange([string[]]@('--zone', $zone)) }
                foreach ($skip in @($recording.Ignore) + $runTempRoot) { $traced.AddRange([string[]]@('--ignore', $skip)) }
                $traced.Add('--')
                $traced.Add($psi.FileName)
                $traced.AddRange([string[]]@($psi.ArgumentList))
                $psi.ArgumentList.Clear()
                foreach ($a in $traced) { $psi.ArgumentList.Add($a) }
                $psi.FileName = $recording.Python
            }

            $limit = if ($trace) { 4 * $timeout } else { $timeout }
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            $p  = [Diagnostics.Process]::Start($psi)
            # Drain both streams before waiting: a suite that fills a 64 KB pipe buffer
            # would otherwise block forever and be killed as a false timeout. Pester
            # writes internal reporting errors to stdout, so retain both streams even
            # when the child exits successfully. Logs stay quiet unless evidence fails.
            $stdout = $p.StandardOutput.ReadToEndAsync()
            $stderr = $p.StandardError.ReadToEndAsync()
            $cancelled = $false
            if ($using:FailFast -or -not $using:Quiet) {
                $waitClock = [Diagnostics.Stopwatch]::StartNew()
                $timedOut = $false
                $nextProgress = 30
                while ($true) {
                    $remaining = [Math]::Max(1, [int][Math]::Ceiling($limit * 1000 - $waitClock.Elapsed.TotalMilliseconds))
                    if ($p.WaitForExit([Math]::Min(1000, $remaining))) { break }
                    if ($using:FailFast -and $signal.IsSet) { $cancelled = $true; break }
                    if ($waitClock.Elapsed.TotalSeconds -ge $limit) { $timedOut = $true; break }
                    if (-not $using:Quiet -and $waitClock.Elapsed.TotalSeconds -ge $nextProgress) {
                        Write-Information ("Still running {0}: {1:n0}s elapsed, limit {2}s" -f $rel,
                            $waitClock.Elapsed.TotalSeconds, $limit) -InformationAction Continue
                        $nextProgress += 30
                    }
                }
            } else { $timedOut = -not $p.WaitForExit($limit * 1000) }
            if ($timedOut -or $cancelled) {
                # Only this worker's owned child and its descendants are stopped.
                # A failed stop cannot turn timeout or cancellation into a passing row.
                try { $p.Kill($true) } catch { Write-Debug "kill after timeout failed: $($_.Exception.Message)" }
                $null = $p.WaitForExit(5000)
            }
            $t0.Stop()

            $rc  = if ($timedOut) { 124 } elseif ($cancelled) { 125 } else { $p.ExitCode }
            $out = if ($stdout.Wait(5000)) { $stdout.Result } else { '[stdout did not close after process exit or timeout]' }
            $err = if ($stderr.Wait(5000)) { $stderr.Result } else { '[stderr did not close after process exit or timeout]' }
            [IO.File]::WriteAllText($stdoutLog, $out, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stderrLog, $err, [Text.UTF8Encoding]::new($false))
            $p.Dispose()
            $err = $err.Trim()
            if ($timedOut) { $err = "timed out after ${limit}s`n$err".Trim() }
            if ($cancelled) { $err = "cancelled after another suite failed (FailFast)`n$err".Trim() }

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

            if ($haveXml -and ($failed -gt 0 -or $errors -gt 0)) {
                # Worker verbosity is quiet; NUnit is the authority for both the
                # verdict and the assertion that explains it to the operator.
                $failures = @($document.SelectNodes('//test-case[failure] | //test-suite[failure]'))
                $details = [Collections.Generic.List[string]]::new()
                foreach ($failure in ($failures | Select-Object -First 10)) {
                    $details.Add("FAIL  $($failure.GetAttribute('name'))")
                    foreach ($field in 'message', 'stack-trace') {
                        $node = $failure.SelectSingleNode("failure/$field")
                        if ($node -and $node.InnerText) {
                            $text = $node.InnerText.Trim()
                            if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + ' [truncated; see NUnit results]' }
                            $details.Add($text)
                        }
                    }
                }
                if ($failures.Count -gt 10) { $details.Add("... $($failures.Count - 10) more failure(s); see NUnit results.") }
                $details.Add("NUnit results: $xml")
                $details.Add("Worker logs: $stdoutLog ; $stderrLog")
                $err = (@($err, ($details -join "`n")) | Where-Object { $_ }) -join "`n"
            }

            if (-not $haveXml) {
                # A zero process exit cannot prove tests passed without their results.
                # Keep Pester's original diagnostic, which can be emitted only on stdout.
                $err = (@($err, $out.Trim(), "Worker logs: $stdoutLog ; $stderrLog") | Where-Object { $_ }) -join "`n"
            }
            $passed = $rc -eq 0 -and $haveXml -and $total -gt 0 -and $failed -eq 0 -and $errors -eq 0
            if ($trace -and -not $passed -and -not $cancelled) {
                $tracedFailure = (@(($err -split "`n") | Where-Object { $_.Trim() }) + "rc=$rc")[0].Trim()
                if ($tracedFailure.Length -gt 200) { $tracedFailure = $tracedFailure.Substring(0, 200) + '...' }
                if (Test-Path -LiteralPath $xml) { Remove-Item -LiteralPath $xml -Force }
                $trace = $false
                # A folder of its own for the second run too, so nothing the
                # traced run left behind can reach it.
                $suiteTemp = Join-Path $runTempRoot ('yrn-suite-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
                $null = New-Item -ItemType Directory -Force -Path $suiteTemp
                continue
            }
            break
        }
        if ($using:FailFast -and ($rc -ne 0 -or -not $haveXml -or $total -eq 0 -or $failed -gt 0 -or $errors -gt 0)) {
            $signal.Set()
        }

        if ($recording) {
            $outcome = 'not recorded: the suite did not pass'
            if ($passed -and $untraceable) {
                $outcome = 'not recorded: it failed under strace twice today, so it ran untraced'
            } elseif ($passed -and $tracedFailure) {
                $outcome = "not recorded: it failed only under strace ($tracedFailure)"
                try {
                    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $untraceableMark)
                    [IO.File]::WriteAllText($untraceableMark, "$($recording.Context)`n$($tracedFailures + 1)`n", [Text.UTF8Encoding]::new($false))
                } catch { Write-Debug "untraceable mark not written: $($_.Exception.Message)" }
            } elseif ($passed -and $observations) {
                $outcome = 'not recorded: the traced run wrote no observations'
                if (Test-Path -LiteralPath $observations) {
                    $answer = & $recording.Python $recording.Tool commit --candidate $observations --cache $recording.Cache `
                        --suite $rel --context $recording.Context --xml $xml --total $total --skipped $skipped `
                        --seconds ([math]::Round($t0.Elapsed.TotalSeconds, 2)) 2>&1
                    try {
                        $verdict = ($answer -join "`n") | ConvertFrom-Json
                        $outcome = if ($verdict.recorded) { 'recorded' } else { "not recorded: $($verdict.reason)" }
                    } catch {
                        $outcome = "not recorded: $(($answer | Out-String).Trim())"
                    }
                }
            }
            $impactNote = (@($whyRun, $outcome) | Where-Object { $_ }) -join '; '
        }

        if (-not $using:Quiet) {
            Write-Information ("Finished {0} in {1:n1}s: rc={2}, tests={3}, failed={4}, errors={5}, XML={6}" -f
                $rel, $t0.Elapsed.TotalSeconds, $rc, $total, $failed, $errors, $haveXml) -InformationAction Continue
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
            impact  = $impactNote
        }
    }
    $sw.Stop()

    # --- REGION: Adjudicate
    $results = @(@($reused) + @($results | Where-Object { $null -ne $_ }) | Sort-Object path)
    $problems = [Collections.Generic.List[string]]::new()

    # Report the originating failure before its canceled siblings.
    foreach ($r in ($results | Sort-Object @{ Expression = { $_.rc -eq 125 } }, path)) {
        if ($r.rc -ne 0) { $problems.Add("$($r.path): suite process exited with rc=$($r.rc)") }
        if (-not $r.haveXml) {
            $problems.Add("$($r.path): produced no result file (rc=$($r.rc))$(if ($r.message) { " -- $($r.message)" })")
            continue
        }
        if ($r.failed -gt 0 -or $r.errors -gt 0) {
            $problems.Add("$($r.path): $($r.failed) failed, $($r.errors) error(s)$(if ($r.message) { "`n$($r.message)" })")
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
            $was = Get-SuiteFloor -Row $p.Value -Platform $Platform
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
        reused  = $reused.Count
        seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }

    # --- REGION: Report
    if (-not $Quiet) {
        $results |
            Select-Object @{n = 'suite'; e = { [IO.Path]::GetFileName($_.path) } },
                          @{n = 'result'; e = {
                                  if (-not $_.haveXml -or $_.rc -ne 0) { 'incomplete' }
                                  elseif ($_.failed -gt 0 -or $_.errors -gt 0 -or $_.total -eq 0) { 'failed' }
                                  elseif ([string]$_.impact -like 'reused*') { 'reused' }
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
        pesterVersion = $pesterVersion
        throttle      = $ThrottleLimit
        impact        = [pscustomobject]@{
            reused   = $reused.Count
            recorded = @($results | Where-Object { [string]$_.impact -match '(^|; )recorded$' }).Count
            traced   = [bool]$recording
            note     = $impact.Note
        }
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
            $writtenRun = Get-Content -LiteralPath (Join-Path $ResultsPath 'suite-results.json') -Raw | ConvertFrom-Json
            if ($RegisterNewSuites) {
                # New rows have no skip allowance. Validate all of their NUnit cases
                # without presenting unexecuted historical rows as part of this run.
                Assert-SuiteBaselineRefresh -Run $writtenRun -Baseline $null -ExpectedSuites $suites -ResultsPath $ResultsPath -AllowedRoot $Path
                foreach ($suite in $suites) {
                    if ((Get-FileHash -LiteralPath (Join-Path $RepoRoot $suite) -Algorithm SHA256).Hash -cne $registrationSourceHashes[$suite]) {
                        throw "Suite source changed during registration: $suite"
                    }
                }
            } else {
                Assert-SuiteBaselineRefresh -Run $writtenRun -Baseline $baseline -ExpectedSuites $suites -ResultsPath $ResultsPath -AllowedRoot $Path
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
            $row = [ordered]@{ total = $r.total; skipped = $r.skipped; seconds = $r.seconds }
            $previous = if ($baseline -and -not $RegisterNewSuites) { $baseline.suites.PSObject.Properties[$r.path] } else { $null }
            if ($previous) {
                foreach ($field in @('platformTotal', 'platformSkipped', 'timeoutSeconds')) {
                    if ($previous.Value.PSObject.Properties[$field]) { $row[$field] = $previous.Value.$field }
                }
                # A suite with per-platform floors has a reference count that a run on
                # another platform must not lower: `total` is what every platform
                # without a floor of its own is held to.
                if ($previous.Value.PSObject.Properties['platformTotal'] -and [int]$previous.Value.total -gt $row.total) {
                    $row.total = [int]$previous.Value.total
                }
                # The reviewed override permits skips only on named platforms;
                # keep the fallback unchanged for every unlisted platform.
                if ($previous.Value.PSObject.Properties['platformSkipped']) {
                    $row.skipped = [int]$previous.Value.skipped
                }
            }
            $map[$r.path] = [pscustomobject]$row
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
                    suites = $map.Count; tests = [int]($map.Values | Measure-Object total -Sum).Sum
                    failed = 0; skipped = [int]($map.Values | Measure-Object skipped -Sum).Sum
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

    $reusedSummary = if ($reused.Count) { ", $($reused.Count) reused from recorded passes" } else { '' }
    Write-Information ("{0} suite(s), {1} test(s), {2} failed, {3} skipped, {4} incomplete suite(s), {5}s{6}" -f
        $totals.suites, $totals.tests, ($totals.failed + $totals.errors), $totals.skipped, $totals.incomplete, $totals.seconds,
        $reusedSummary) -InformationAction Continue

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
    $failureSignal.Dispose()
    $resultLock.Dispose()
    if ($foregroundLock) {
        $foregroundLock.Dispose()
        Remove-Item -LiteralPath $foregroundLockPath -Force -ErrorAction SilentlyContinue
    }
    # Every suite has exited by now, killed ones included, so the master and the
    # suite folders under it hold nothing a live process still uses. The lock
    # goes first: a directory holding an open file cannot be removed on Windows.
    if ($runLock) { $runLock.Dispose() }
    if ($runTemp) {
        # Windows refuses to delete a file a dying descendant still holds, so
        # the removal gets a few short retries. A failure is reported and leaves
        # the verdict alone; the next run's sweep removes a master left behind.
        $runTempLeft = $null
        foreach ($attempt in 1..5) {
            try {
                if (Test-Path -LiteralPath $runTemp) { Remove-Item -LiteralPath $runTemp -Recurse -Force -ErrorAction Stop }
                $runTempLeft = $null
                break
            } catch {
                $runTempLeft = $_.Exception.Message
                Start-Sleep -Milliseconds 400
            }
        }
        if ($runTempLeft) { Write-Warning "run temp folder '$runTemp' not fully removed: $runTempLeft" }
    }
    # The per-suite folders contain what this run's suites leave; this drains
    # what lives outside them -- the runtime entries of processes that ran
    # outside the containment or started with a scrubbed environment, and
    # stale harness temp names from earlier runs. Housekeeping only: it never
    # changes the run's verdict.
    try {
        Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -ErrorAction Stop
        $null = Remove-YurunaOrphanedRuntimeIpc -Confirm:$false
        $null = Remove-YurunaStaleTempEntry -Confirm:$false
    } catch {
        Write-Verbose "temp housekeeping after the run: $($_.Exception.Message)"
    }
}
