<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42e5c0b7-3a91-4d68-b2f4-8c07d15e9a36
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna preflight gates tooling versions
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
    Report which gates this machine can actually run, and refuse to call a
    skipped one green.
.DESCRIPTION
    Every gate needs something: a language runtime, a linter, a browser. When
    one of those is missing the gate does not fail -- it skips, prints a
    cheerful line, and the run ends green. That is the worst of the three
    possible answers, because it is indistinguishable from the gate having
    passed, and the thing it was watching is now unwatched by a machine that
    reports no problem.

    This names each tool, the gate that needs it, and what goes unchecked
    without it. It does not run the gates; it answers whether running them
    would mean anything.

    Release mode is the difference between a developer's machine and a build
    that speaks for the project. On a laptop a missing browser is an
    inconvenience and the row is reported as degraded. In release mode every
    row is required, because a release that skipped a gate has not been checked
    -- it has been described as checked.
.PARAMETER Release
    Treat every row as required. A missing tool then fails.
.PARAMETER Quiet
    Print only the rows that are not satisfied, and the summary.
.EXAMPLE
    pwsh -File tools/Invoke-Preflight.ps1
.EXAMPLE
    pwsh -File tools/Invoke-Preflight.ps1 -Release
#>

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# Required means the project cannot be checked at all without it. Everything
# else is a gate that would silently stop watching, which is why the row still
# exists rather than being left out of the report.
$Rows = @(
    @{ Name = 'pwsh'; Kind = 'command'; Command = 'pwsh'; Required = $true
       MinVersion = '7.0'
       Gate = 'every PowerShell gate and the whole suite'
       Missing = 'nothing can run' }
    @{ Name = 'git'; Kind = 'command'; Command = 'git'; Required = $true
       Gate = 'the registry coverage checks, which enumerate the tracked tree'
       Missing = 'a shipped source could leave every gate unnoticed' }
    @{ Name = 'Pester'; Kind = 'module'; Module = 'Pester'; Required = $true
       MinVersion = '5.0'
       Gate = 'tools/Invoke-TestSuite.ps1'
       Missing = 'no test runs' }
    @{ Name = 'PSScriptAnalyzer'; Kind = 'module'; Module = 'PSScriptAnalyzer'; Required = $true
       Gate = 'the PowerShell lint, and the generated-catalog lint bound'
       Missing = 'the emitter could produce PowerShell nobody reads' }
    @{ Name = 'powershell-yaml'; Kind = 'module'; Module = 'powershell-yaml'; Required = $true
       MinVersion = '0.4'
       Gate = 'the structured project display inventory and the cycle planner'
       Missing = 'reachable project YAML cannot be parsed, so display metadata can escape the release inventory' }
    @{ Name = 'go'; Kind = 'command'; Command = 'go'; Required = $false
       VersionArgs = @('version')
       Gate = 'tools/Invoke-GoTest.ps1'
       Missing = 'every service binary and the shared i18n package go unbuilt and untested' }
    @{ Name = 'node'; Kind = 'command'; Command = 'node'; Required = $false
       Gate = 'tools/Invoke-JsTest.ps1'
       Missing = 'the JavaScript suites report as run and assert nothing' }
    @{ Name = 'shellcheck'; Kind = 'command'; Command = 'shellcheck'; Required = $false
       VersionArgs = @('--version')
       Gate = 'tools/Invoke-ShellCheck.ps1'
       Missing = 'the guest bring-up scripts go unchecked' }
    @{ Name = 'chrome'; Kind = 'anyCommand'; Any = @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')
       Required = $false
       Gate = 'the accessibility, palette-floor, catalog-kernel and request-timeout suites'
       Missing = 'nothing renders, so every floor claim rests on reading the source' }
)

function Get-CommandVersion {
    <#
    .SYNOPSIS
        A tool's own version line, or '' when it will not give one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [string[]]$VersionArgs = @('--version'))
    try {
        # 2>&1 because several of these write their banner to stderr, and a
        # version that lands on the wrong stream is not a missing version.
        # The first line that actually carries a number, not simply the first
        # line: shellcheck opens with a banner and puts its version underneath,
        # and taking the banner would report a present tool as versionless.
        $out = @(& $Name @VersionArgs 2>&1 | ForEach-Object { [string]$_ })
        foreach ($line in $out) {
            if ($line -match '\d+\.\d+') { return $line.Trim() }
        }
        if ($out.Count -gt 0) { return ([string]$out[0]).Trim() }
        return ''
    } catch { return '' }
}

function Get-FirstVersionNumber {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '(\d+)\.(\d+)(\.\d+)?')
    if (-not $m.Success) { return '' }
    return $m.Value
}

$results = [Collections.Generic.List[object]]::new()

foreach ($row in $Rows) {
    $found = $false
    $version = ''
    $detail = ''

    switch ($row.Kind) {
        'command' {
            $cmd = Get-Command $row.Command -ErrorAction SilentlyContinue
            if ($cmd) {
                $found = $true
                $probeArgs = if ($row.VersionArgs) { $row.VersionArgs } else { @('--version') }
                $version = Get-FirstVersionNumber -Text (Get-CommandVersion -Name $row.Command -VersionArgs $probeArgs)
            }
        }
        'anyCommand' {
            foreach ($candidate in $row.Any) {
                $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
                if ($cmd) {
                    $found = $true
                    $detail = $candidate
                    $version = Get-FirstVersionNumber -Text (Get-CommandVersion -Name $candidate)
                    break
                }
            }
        }
        'module' {
            $mod = Get-Module -ListAvailable -Name $row.Module -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($mod) { $found = $true; $version = [string]$mod.Version }
        }
    }

    $state = 'ok'
    $why = ''
    if (-not $found) {
        $state = if ($Release -or $row.Required) { 'missing' } else { 'degraded' }
        $why = $row.Missing
    } elseif ($row.MinVersion -and $version) {
        $have = $null; $want = $null
        if ([version]::TryParse((($version -split '\.')[0..1] -join '.'), [ref]$have) -and
            [version]::TryParse($row.MinVersion, [ref]$want) -and $have -lt $want) {
            $state = if ($Release -or $row.Required) { 'missing' } else { 'degraded' }
            $why = "found $version, needs $($row.MinVersion) or newer"
        }
    }

    $results.Add([pscustomobject]@{
            Name = $row.Name; State = $state; Version = $version
            Detail = $detail; Gate = $row.Gate; Why = $why
        })
}

$blocking = @($results | Where-Object State -EQ 'missing')
$degraded = @($results | Where-Object State -EQ 'degraded')

foreach ($r in $results) {
    if ($Quiet -and $r.State -eq 'ok') { continue }
    $shown = if ($r.Detail) { "$($r.Name) ($($r.Detail))" } else { $r.Name }
    $stamp = if ($r.Version) { $r.Version } else { '--' }
    Write-Output ("{0,-8} {1,-20} {2,-12} {3}" -f $r.State.ToUpperInvariant(), $shown, $stamp, $r.Gate)
    if ($r.Why) { Write-Output ("         without it: {0}" -f $r.Why) }
}

$mode = if ($Release) { 'release' } else { 'developer' }
Write-Output ("Invoke-Preflight [{0}]: {1} row(s), {2} blocking, {3} degraded." -f
    $mode, $results.Count, $blocking.Count, $degraded.Count)

if ($blocking.Count -gt 0) { exit 1 }
exit 0
