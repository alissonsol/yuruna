<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42b3f81a-6c27-4d95-8e13-7a5f2c904db6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization performance budget bytes requests
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
    Measure what every shipped page costs a reader, and hold it to a checked
    baseline.
.DESCRIPTION
    Two numbers decide whether a page is still affordable on the floor: how many
    bytes it pulls, and how many requests it needs to pull them. Both are
    measured here from the working tree, so a change is caught before it is
    deployed rather than after somebody notices a slow page on a phone.

    The rows are deliberately the cheap deterministic ones. No timing, no
    sampling, no browser -- the same tree gives the same answer on any machine
    at any hour, which is what lets this run in an ordinary suite and fail
    honestly. A render-timing harness is a different instrument with different
    failure modes and does not belong in the same gate.

    Tolerances are declared per row in the baseline rather than assumed here. A
    growth of a few hundred bytes in a runtime that is already tens of kilobytes
    is noise; the same growth in a page's request count is not, so requests are
    pinned exactly and bytes are given room.
.PARAMETER Update
    Rewrite the baseline from this measurement, after a deliberate change.
.PARAMETER RegistryPath
    Browser-source registry to measure. Defaults to the checked manifest. This
    override exists so mutation tests can prove a missing disposition fails.
.PARAMETER BaselinePath
    Baseline to compare or update. Defaults to globalization/perf-baseline.json.
.PARAMETER Root
    Repository root to measure. Defaults to this tool's repository. The override
    exists for isolated candidate-discovery and byte-budget mutation tests.
.PARAMETER Quiet
    Print only findings.
.EXAMPLE
    pwsh -File tools/Invoke-PerfBaseline.ps1
.EXAMPLE
    pwsh -File tools/Invoke-PerfBaseline.ps1 -Update
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Update,
    [switch]$Quiet,
    [string]$RegistryPath,
    [string]$BaselinePath,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

$RepoRoot = if ($Root) { [IO.Path]::GetFullPath($Root) } else { Split-Path -Parent $PSScriptRoot }
if (-not $RegistryPath) { $RegistryPath = Join-Path $RepoRoot 'globalization/manifests/browser-sources.json' }
if (-not $BaselinePath) { $BaselinePath = Join-Path $RepoRoot 'globalization/perf-baseline.json' }

# Defaults when the baseline does not name its own. Bytes get proportional room
# because an asset grows with the features it carries; a request is a round trip
# on a phone network and is pinned exactly.
$DefaultByteTolerancePercent = 5
$DefaultByteToleranceAbsolute = 512

function Get-GzipByteCount {
    <#
    .SYNOPSIS
        The size this file would travel as, compressed the way a server sends it.
    .DESCRIPTION
        Raw bytes alone would understate a text asset by roughly a factor of
        three and overstate the cost of a change to one. What a reader waits for
        is the compressed size.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $output = [IO.MemoryStream]::new()
    try {
        # Deterministic on purpose: SmallestSize is a fixed setting, so the same
        # bytes give the same count on every machine that runs this.
        $gzip = [IO.Compression.GZipStream]::new($output, [IO.Compression.CompressionLevel]::SmallestSize, $true)
        try { $gzip.Write($Bytes, 0, $Bytes.Length) } finally { $gzip.Dispose() }
        return [int]$output.Length
    } finally {
        $output.Dispose()
    }
}

function Get-PageRequestCount {
    <#
    .SYNOPSIS
        How many separate things a page asks for before it can render.
    .DESCRIPTION
        Counts the subresources declared in the markup: scripts, stylesheets and
        images. Each is a round trip, and on the floor browser they are not
        multiplexed -- a page that grew from one script to two did not get
        slightly slower, it got another full round trip on a phone network
        before it could run.

        Inline script and style cost no request and are not counted. A data:
        URI is inline by another name and is not counted either.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Html)

    $count = 0
    foreach ($pattern in @(
            '<script\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']',
            '<link\b[^>]*\brel\s*=\s*["'']stylesheet["''][^>]*\bhref\s*=\s*["'']([^"'']+)["'']',
            '<link\b[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*\brel\s*=\s*["'']stylesheet["'']',
            '<img\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']')) {
        foreach ($m in [regex]::Matches($Html, $pattern, 'IgnoreCase')) {
            $href = $m.Groups[1].Value.Trim()
            if (-not $href -or $href.StartsWith('data:')) { continue }
            $count++
        }
    }
    return $count
}

function Get-Measurement {
    <#
    .SYNOPSIS
        The current byte and request rows for the whole shipped surface.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "The browser-source registry is missing: $RegistryPath"
    }
    $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RegistryPath))
    $excluded = @($registry.excludeSuffixes | ForEach-Object { [string]$_ })

    # The registry is the disposition table, not a hand-picked sample.  Prove
    # it covers the tracked and untracked candidate surface before measuring it; otherwise deleting a
    # row makes both the measurement and its baseline disappear together and
    # produces the same green output as a complete run.
    Push-Location $RepoRoot
    try { $trackedPages = @(& git ls-files --cached --others --exclude-standard -- '*.html') } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'git could not enumerate candidate HTML pages' }
    $trackedPages = @($trackedPages | Where-Object {
            $_ -notlike 'dev-only/*' -and $_ -notlike 'docs/*'
        } | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
    $registeredPages = @($registry.pages | ForEach-Object {
            ([string]$_.path) -replace '\\', '/'
        } | Sort-Object -Unique)
    $pageGap = @($trackedPages | Where-Object { $registeredPages -notcontains $_ })
    $stalePage = @($registeredPages | Where-Object { $trackedPages -notcontains $_ })
    if ($pageGap.Count -gt 0 -or $stalePage.Count -gt 0) {
        $parts = @()
        if ($pageGap.Count -gt 0) { $parts += 'unregistered: ' + ($pageGap -join ', ') }
        if ($stalePage.Count -gt 0) { $parts += 'not in candidate: ' + ($stalePage -join ', ') }
        throw 'the page performance registry is incomplete (' + ($parts -join '; ') + ')'
    }

    $assets = [ordered]@{}
    foreach ($root in $registry.roots) {
        $dir = Join-Path $RepoRoot ([string]$root.path)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Recurse -Include '*.js', '*.css' |
                Sort-Object FullName)) {
            $skip = $false
            foreach ($suffix in $excluded) { if ($file.Name.EndsWith($suffix)) { $skip = $true; break } }
            if ($skip) { continue }
            $relative = ([IO.Path]::GetRelativePath($RepoRoot, $file.FullName)) -replace '\\', '/'
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $assets[$relative] = [ordered]@{
                rawBytes  = $bytes.Length
                gzipBytes = Get-GzipByteCount -Bytes $bytes
                transferDisposition = 'deterministic-gzip-estimate'
            }
        }
    }

    $pages = [ordered]@{}
    foreach ($page in $registry.pages) {
        $path = Join-Path $RepoRoot ([string]$page.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $relative = ([string]$page.path) -replace '\\', '/'
        $html = [IO.File]::ReadAllText($path)
        $pages[$relative] = [ordered]@{
            disposition = 'budgeted'
            requests  = Get-PageRequestCount -Html $html
            rawBytes  = ([Text.UTF8Encoding]::new($false)).GetByteCount($html)
            gzipBytes = Get-GzipByteCount -Bytes ([IO.File]::ReadAllBytes($path))
        }
    }

    return [ordered]@{
        schema = 'yuruna.perf-baseline/v2'
        note   = 'Every shipped asset and page has a fail-new deterministic budget. Executable scenario ceilings are provisional until the release evidence run records its controlled measurements.'
        tolerance = [ordered]@{
            bytePercent  = $DefaultByteTolerancePercent
            byteAbsolute = $DefaultByteToleranceAbsolute
            requests     = 0
        }
        assets = $assets
        pages  = $pages
        executableBudgets = [ordered]@{
            browserFloorColdFirstUsable = [ordered]@{
                coverage = 'every registered page'
                markerContract = 'locale, direction, above-fold text/controls, and primary data or accessible state are ready'
                samples = 30
                statistic = 'median'
                relativePercent = 10
                absoluteToleranceMs = 100
            }
            browserCapabilityOffFirstUsable = [ordered]@{
                coverage = 'every registered page'
                markerContract = 'same first-usable marker as the floor-browser row, with optional APIs disabled'
                samples = 100
                statistic = 'p95'
                relativePercent = 15
                absoluteToleranceMs = 100
            }
            browserSteadyRender = [ordered]@{
                coverage = 'every registered page with poll-driven rendering'
                samples = 100
                statistic = 'median-and-p95'
                relativePercent = 10
                absoluteToleranceMs = 25
            }
            powershellCli = [ordered]@{
                coverage = 'cold-start, warm-import, and post-catalog working-set rows'
                samples = 100
                statistic = 'median-and-p95'
                relativePercent = 10
                absoluteTolerance = 'recorded-before-candidate'
            }
            transcriptThroughput = [ordered]@{
                coverage = 'representative cycle-log lines per second'
                samples = 100
                statistic = 'median-and-p95'
                relativePercent = 10
                absoluteTolerance = 'recorded-before-candidate'
            }
            goService = [ordered]@{
                coverage = 'startup, steady RSS, binary size, lookup, allocation, and concurrent-render rows'
                samples = 100
                statistic = 'median-and-p95'
                relativePercent = 10
                absoluteTolerance = 'recorded-before-candidate'
            }
            httpLatency = [ordered]@{
                coverage = 'loopback or recorded network-profile median and p95 after the G2-10/G3-04 harness lands'
                samples = 100
                statistic = 'median-and-p95'
                relativePercent = 10
                absoluteTolerance = 'recorded-before-candidate'
                activation = 'G2-10/G3-04'
            }
        }
    }
}

function Get-CanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    return ((ConvertTo-Json -InputObject $Value -Depth 12) -replace "`r`n", "`n").TrimEnd() + "`n"
}

$current = Get-Measurement

if ($Update) {
    if ($PSCmdlet.ShouldProcess($BaselinePath, 'record the performance baseline')) {
        [IO.File]::WriteAllText($BaselinePath, (Get-CanonicalJson -Value $current))
        if (-not $Quiet) {
            Write-Output "baseline written: $BaselinePath ($($current.assets.Count) asset(s), $($current.pages.Count) page(s))"
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
    Write-Output "FINDING: no baseline at $BaselinePath. Record one with -Update."
    exit 1
}

$baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($BaselinePath))
$bytePercent = if ($baseline.tolerance.bytePercent) { [double]$baseline.tolerance.bytePercent } else { $DefaultByteTolerancePercent }
$byteAbsolute = if ($baseline.tolerance.byteAbsolute) { [double]$baseline.tolerance.byteAbsolute } else { $DefaultByteToleranceAbsolute }

$findings = @()

if ($baseline.schema -ne 'yuruna.perf-baseline/v2') {
    $findings += "baseline schema '$($baseline.schema)' is not yuruna.perf-baseline/v2"
}
foreach ($asset in $baseline.assets.PSObject.Properties) {
    if ($asset.Value.transferDisposition -ne 'deterministic-gzip-estimate') {
        $findings += "$($asset.Name) has no deterministic transfer-size disposition"
    }
}
foreach ($page in $baseline.pages.PSObject.Properties) {
    if ($page.Value.disposition -ne 'budgeted') {
        $findings += "$($page.Name) has no page performance disposition"
    }
}
foreach ($budget in @('browserFloorColdFirstUsable', 'browserCapabilityOffFirstUsable',
        'browserSteadyRender', 'powershellCli', 'transcriptThroughput', 'goService', 'httpLatency')) {
    if (-not $baseline.executableBudgets -or
        $baseline.executableBudgets.PSObject.Properties.Name -notcontains $budget) {
        $findings += "executable scenario '$budget' has no provisional budget"
        continue
    }
    $scenario = $baseline.executableBudgets.$budget
    $minimumSamples = if ($budget -eq 'browserFloorColdFirstUsable') { 30 } else { 100 }
    if ([int]$scenario.samples -lt $minimumSamples) {
        $findings += "executable scenario '$budget' requires at least $minimumSamples samples"
    }
    if (-not $scenario.coverage -or -not $scenario.statistic -or
        [double]$scenario.relativePercent -le 0) {
        $findings += "executable scenario '$budget' has an incomplete coverage/statistic/relative limit"
    }
    if (@($scenario.PSObject.Properties.Name | Where-Object { $_ -like 'absoluteTolerance*' }).Count -eq 0) {
        $findings += "executable scenario '$budget' has no absolute noise tolerance disposition"
    }
}

function Test-ByteRow {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$What, [double]$Was, [double]$Now)
    if ($Now -le $Was) { return '' }
    # Either allowance is enough. A small file would otherwise fail on a
    # one-line comment, and a large one would absorb a real regression.
    $allowed = [Math]::Max($byteAbsolute, $Was * $bytePercent / 100.0)
    $grew = $Now - $Was
    if ($grew -le $allowed) { return '' }
    return ("{0}: {1} bytes, was {2} -- grew {3}, more than the {4} allowed" -f `
        $What, [int]$Now, [int]$Was, [int]$grew, [int]$allowed)
}

foreach ($name in $baseline.assets.PSObject.Properties.Name) {
    if (-not $current.assets.Contains($name)) {
        $findings += "${name}: in the baseline but not in the tree (deleted, renamed, or dropped from the registry)"
        continue
    }
    $was = $baseline.assets.$name
    $now = $current.assets[$name]
    foreach ($row in @(
            @{ What = "${name} raw"; Was = [double]$was.rawBytes; Now = [double]$now.rawBytes },
            @{ What = "${name} gzip"; Was = [double]$was.gzipBytes; Now = [double]$now.gzipBytes })) {
        $finding = Test-ByteRow -What $row.What -Was $row.Was -Now $row.Now
        if ($finding) { $findings += $finding }
    }
}

foreach ($name in $baseline.pages.PSObject.Properties.Name) {
    if (-not $current.pages.Contains($name)) {
        $findings += "${name}: in the baseline but not in the tree"
        continue
    }
    $was = $baseline.pages.$name
    $now = $current.pages[$name]
    # Requests are pinned exactly. One more subresource is one more round trip
    # before the page can run, which is not a rounding difference.
    if ([int]$now.requests -ne [int]$was.requests) {
        $findings += ("{0}: {1} request(s) on the critical path, baseline has {2}" -f $name, [int]$now.requests, [int]$was.requests)
    }
    foreach ($row in @(
            @{ What = "${name} raw"; Was = [double]$was.rawBytes; Now = [double]$now.rawBytes },
            @{ What = "${name} gzip"; Was = [double]$was.gzipBytes; Now = [double]$now.gzipBytes })) {
        $finding = Test-ByteRow -What $row.What -Was $row.Was -Now $row.Now
        if ($finding) { $findings += $finding }
    }
}

# A source or page that appeared without being recorded is an unbudgeted row,
# not informational drift.  Failing here is what prevents a newly shipped
# bundle from bypassing every ceiling until somebody happens to re-record it.
$added = @()
foreach ($name in $current.assets.Keys) {
    if (-not $baseline.assets.PSObject.Properties.Name.Contains($name)) { $added += $name }
}
foreach ($name in $current.pages.Keys) {
    if (-not $baseline.pages.PSObject.Properties.Name.Contains($name)) { $added += $name }
}
foreach ($a in $added) { $findings += "$a is shipped but unbudgeted; review it and re-record with -Update" }

if ($findings.Count -gt 0) {
    foreach ($f in $findings) { Write-Output "FINDING: $f" }
    Write-Output "Invoke-PerfBaseline: $($findings.Count) finding(s)."
    exit 1
}

if (-not $Quiet) {
    Write-Output ("Invoke-PerfBaseline: {0} asset(s) and {1} page(s) within budget." -f $current.assets.Count, $current.pages.Count)
}
exit 0
