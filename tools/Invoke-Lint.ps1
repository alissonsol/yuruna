<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d3e6a1-9b74-4c25-8f30-1a2b3c4d5e6f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lint pssa
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES PSScriptAnalyzer
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Run PSScriptAnalyzer over the repo's PowerShell source -- git-tracked and
    new (not-yet-committed, non-ignored) files ONLY.
.DESCRIPTION
    `Invoke-ScriptAnalyzer -Path . -Recurse` walks the working tree without
    honoring .gitignore, so on a tree where the harness has run it also scans
    generated/ignored directories that are not source and are not the merge
    gate: the per-cycle clone (project/), the runtime state dir
    (test/status/runtime/, incl. the generated .status-service.ps1), pool build
    outputs, etc. Their pre-existing findings drown out the real ones.

    This wrapper selects files with `git ls-files --cached --others
    --exclude-standard` (tracked + new, minus everything .gitignore covers) so
    the scan matches what a clean checkout / merge actually contains. It uses
    the repo PSScriptAnalyzerSettings.psd1 and does not filter by severity --
    every finding must be zero before merge (see CONTRIBUTING.md).
.PARAMETER Path
    Optional repo-relative subpath to limit the scan (e.g. 'test/modules').
    Default: the whole repo.
.PARAMETER Quiet
    Print only the summary line, not each finding.
.EXAMPLE
    pwsh tools/Invoke-Lint.ps1
    Scans all tracked/new PowerShell files; exits non-zero if any finding.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Error "PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser"
    exit 2
}
Import-Module PSScriptAnalyzer

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'

Push-Location $RepoRoot
try {
    # Tracked + untracked-but-not-ignored, restricted to PowerShell files. This
    # is the exact set .gitignore does NOT cover, so generated/runtime trees are
    # excluded without a hand-maintained path list.
    # Forward slashes: git pathspecs are '/'-separated on every platform, so do
    # NOT use Join-Path (it would emit a backslash on Windows that git mismatches).
    $pathspec = @('*.ps1', '*.psm1', '*.psd1')
    if ($Path) {
        $prefix = ($Path -replace '\\', '/').TrimEnd('/')
        $pathspec = $pathspec | ForEach-Object { "$prefix/$_" }
    }
    $files = @(git ls-files --cached --others --exclude-standard -- @pathspec |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Sort-Object -Unique)

    if ($files.Count -eq 0) {
        Write-Output "No PowerShell files to scan$(if ($Path) { " under '$Path'" })."
        exit 0
    }

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        foreach ($r in @(Invoke-ScriptAnalyzer -Path $f -Settings $Settings)) { $findings.Add($r) }
    }

    if (-not $Quiet) {
        foreach ($r in $findings) {
            Write-Output ("{0}:{1}:{2}  {3}  {4}" -f $r.ScriptName, $r.Line, $r.Column, $r.RuleName, $r.Message)
        }
    }
    Write-Output ("PSScriptAnalyzer: {0} finding(s) across {1} tracked/new PowerShell file(s)." -f $findings.Count, $files.Count)
    exit ($findings.Count -gt 0 ? 1 : 0)
} finally {
    Pop-Location
}
