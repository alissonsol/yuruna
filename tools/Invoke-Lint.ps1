<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42bd51d4-c3b9-4fa3-ae75-af2ab0905275
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
    the repo PSScriptAnalyzerSettings.psd1 and does not filter by severity.

    One rule/path conflict is classified explicitly: generated pseudo-catalog
    PSD1 files are normalized UTF-8 without BOM because their byte hashes are
    release authority and PowerShell 7 is their reader, while
    PSUseBOMForUnicodeEncodedFile asks all non-ASCII PowerShell files for a BOM.
    No other path or analyzer rule is suppressed.
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
    [switch]$Quiet,
    [Parameter(DontShow)][string]$AnalyzerIsolatePath,
    [Parameter(DontShow)][string]$AnalyzerBatchFile
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Error "PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser" -ErrorAction Continue
    exit 2
}
Import-Module PSScriptAnalyzer

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'

# PSScriptAnalyzer occasionally poisons its process-wide state and throws a
# NullReferenceException for a file it analyzes cleanly in a fresh process.
# This internal mode is the genuinely isolated last retry used below. It emits
# only a small JSON projection, so the parent never mistakes analyzer text for
# a finding or loses a real result through remoting serialization.
if ($AnalyzerIsolatePath) {
    $lastError = ''
    foreach ($attempt in 1..3) {
        try {
            $isolated = @(Invoke-ScriptAnalyzer -Path $AnalyzerIsolatePath -Settings $Settings)
            $payload = [ordered]@{
                success = $true
                findings = @($isolated | ForEach-Object {
                        [ordered]@{
                            scriptName = [string]$_.ScriptName
                            scriptPath = [string]$_.ScriptPath
                            line = [int]$_.Line
                            column = [int]$_.Column
                            ruleName = [string]$_.RuleName
                            message = [string]$_.Message
                        }
                    })
            }
            Write-Output (ConvertTo-Json -InputObject $payload -Depth 5 -Compress)
            exit 0
        } catch { $lastError = $_.Exception.Message }
    }
    Write-Output (ConvertTo-Json -InputObject ([ordered]@{
                success = $false; error = $lastError; findings = @()
            }) -Compress)
    exit 2
}

# The scan worker. PSScriptAnalyzer keeps state for a whole process and is not
# safe to drive from several runspaces of one process -- concurrent calls
# collide on a shared command table and the analyzer throws before it reads a
# file -- so the only unit of parallelism available here is the process. This
# mode is the body one worker runs over its own slice of the file list, and it
# reports through JSON so the parent never mistakes analyzer text for a finding.
if ($AnalyzerBatchFile) {
    $batch = @(Get-Content -LiteralPath $AnalyzerBatchFile | Where-Object { $_ })
    $payload = foreach ($relative in $batch) {
        $absolute = Join-Path $RepoRoot $relative
        # Invoke-ScriptAnalyzer intermittently throws a NullReferenceException on
        # a file it analyzes cleanly in isolation -- the fault depends on the
        # analyzer state left by files scanned earlier in the same session, so it
        # moves between files and runs. Retrying that one file in isolation
        # usually succeeds. A file that fails twice is reported and fails the run
        # rather than aborting it: an unscanned file must never look like a clean
        # one, but one flaky file must not hide the findings in the other 350.
        $results = $null
        $why = $null
        foreach ($attempt in 1..2) {
            try { $results = @(Invoke-ScriptAnalyzer -Path $absolute -Settings $Settings); break }
            catch {
                if ($attempt -eq 2) {
                    $isolatedOutput = & pwsh -NoProfile -File $PSCommandPath `
                        -AnalyzerIsolatePath $absolute 2>&1 | Out-String
                    $isolatedCode = $LASTEXITCODE
                    $isolatedResult = $null
                    try { $isolatedResult = ConvertFrom-Json -InputObject $isolatedOutput }
                    catch { $isolatedResult = $null }
                    if ($isolatedCode -eq 0 -and $isolatedResult -and $isolatedResult.success) {
                        $results = @($isolatedResult.findings)
                    } else {
                        $why = if ($isolatedResult -and $isolatedResult.error) {
                            [string]$isolatedResult.error
                        } else { $isolatedOutput.Trim() }
                    }
                }
            }
        }
        [ordered]@{
            file = $relative
            why = $why
            findings = @($results | Where-Object { $_ } | ForEach-Object {
                    [ordered]@{
                        scriptName = [string]$_.ScriptName
                        scriptPath = [string]$_.ScriptPath
                        line = [int]$_.Line
                        column = [int]$_.Column
                        ruleName = [string]$_.RuleName
                        message = [string]$_.Message
                    }
                })
        }
    }
    Write-Output (ConvertTo-Json -InputObject $payload -Depth 6 -Compress -AsArray)
    exit 0
}

function Test-IsGeneratedCatalogBomConflict {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RuleName
    )

    $normalized = $RelativePath -replace '\\', '/'
    return $RuleName -ceq 'PSUseBOMForUnicodeEncodedFile' -and
        $normalized -cmatch '^globalization/generated/powershell/[^/]+\.psd1$'
}

Push-Location $RepoRoot
try {
    # Tracked + untracked-but-not-ignored, restricted to PowerShell files. This
    # is the exact set .gitignore does NOT cover, so generated/runtime trees are
    # excluded without a hand-maintained path list.
    #
    # The extension filter runs HERE, not as a git pathspec. A `*.ps1` pathspec
    # is expanded against the current directory before git sees it whenever a
    # file there matches, so from the repo root git gets the single root-level
    # .ps1 filename and returns it alone, leaving every .ps1 in a subdirectory
    # unscanned (`*.psm1` matches nothing at the root, survives as a pattern, and
    # those files are scanned). Listing first and filtering in PowerShell removes
    # the expansion entirely; -Path is applied to the same list.
    # Forward slashes: git output is '/'-separated on every platform, so do NOT
    # use Join-Path (it would emit a backslash on Windows that would not match).
    $prefix = if ($Path) { ($Path -replace '\\', '/').TrimEnd('/') + '/' } else { '' }
    $files = @(git ls-files --cached --others --exclude-standard |
        Where-Object { $_ -and $_ -match '\.(ps1|psm1|psd1)$' } |
        Where-Object { -not $prefix -or $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object -Unique)

    if ($files.Count -eq 0) {
        Write-Output "No PowerShell files to scan$(if ($Path) { " under '$Path'" })."
        exit 0
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $unanalyzed = New-Object System.Collections.Generic.List[string]
    $classified = New-Object System.Collections.Generic.List[object]
    # The scan is the longest step in the release gate and every file is
    # independent, so it runs as several worker processes over disjoint slices.
    # Process, not runspace: see the worker mode above for why the analyzer
    # cannot be driven concurrently inside one process.
    #
    # Slices are strided rather than contiguous so one directory of large files
    # cannot land entirely on one worker and hold the whole scan open.
    $workerCount = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount - 1))
    if ($files.Count -lt ($workerCount * 4)) { $workerCount = 1 }
    $batchRoot = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-lint-' + [Guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $batchRoot -Force
    $scanned = @()
    try {
        $slices = @(0..($workerCount - 1) | ForEach-Object {
                $offset = $_
                $slice = @(for ($i = $offset; $i -lt $files.Count; $i += $workerCount) { $files[$i] })
                $batchPath = Join-Path $batchRoot "batch-$offset.txt"
                [IO.File]::WriteAllLines($batchPath, [string[]]$slice)
                [pscustomobject]@{ Path = $batchPath; Files = $slice }
            })
        $scanned = @($slices | ForEach-Object -ThrottleLimit $workerCount -Parallel {
                $self = $using:PSCommandPath
                $text = & pwsh -NoProfile -File $self -AnalyzerBatchFile $_.Path 2>&1 | Out-String
                [pscustomobject]@{ Files = $_.Files; Code = $LASTEXITCODE; Text = $text }
            })
    } finally {
        Remove-Item -LiteralPath $batchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $scanByFile = @{}
    foreach ($worker in $scanned) {
        $parsed = $null
        try { $parsed = ConvertFrom-Json -InputObject $worker.Text } catch { $parsed = $null }
        if ($worker.Code -ne 0 -or -not $parsed) {
            # A worker that did not answer leaves its whole slice unscanned, and
            # an unscanned file must never be reported as a clean one.
            foreach ($missed in $worker.Files) {
                $scanByFile[$missed] = [pscustomobject]@{
                    Findings = $null; Why = "the analyzer worker failed: $($worker.Text.Trim())" }
            }
            continue
        }
        foreach ($entry in @($parsed)) {
            $scanByFile[[string]$entry.file] = [pscustomobject]@{
                Findings = $entry.findings; Why = $entry.why }
        }
    }

    # Report in file order. Workers finish in whatever order they finish, and a
    # run's output must not depend on that.
    foreach ($f in $files) {
        $scan = $scanByFile[$f]
        if (-not $scan) {
            $unanalyzed.Add("${f}: the scan returned no result for this file")
            continue
        }
        if ($scan.Why) { $unanalyzed.Add("${f}: $($scan.Why)") }
        foreach ($r in @($scan.Findings)) {
            if (-not $r) { continue }
            if (Test-IsGeneratedCatalogBomConflict -RelativePath $f -RuleName ([string]$r.ruleName)) {
                $classified.Add($r)
                continue
            }
            $findings.Add($r)
        }
    }

    if (-not $Quiet) {
        foreach ($r in $classified) {
            Write-Output ("CLASSIFIED  {0}  {1} (generated normalized UTF-8 is deliberately BOM-less)" -f `
                $r.ScriptName, $r.RuleName)
        }
        foreach ($r in $findings) {
            Write-Output ("{0}:{1}:{2}  {3}  {4}" -f $r.ScriptName, $r.Line, $r.Column, $r.RuleName, $r.Message)
        }
    }
    foreach ($u in $unanalyzed) { Write-Output "UNANALYZED  $u" }
    Write-Output ("PSScriptAnalyzer: {0} finding(s) across {1} tracked/new PowerShell file(s), {2} generated no-BOM conflict(s) classified{3}." -f `
        $findings.Count, $files.Count, $classified.Count, `
        $(if ($unanalyzed.Count) { ", $($unanalyzed.Count) UNANALYZED" } else { '' }))
    exit (($findings.Count -gt 0 -or $unanalyzed.Count -gt 0) ? 1 : 0)
} finally {
    Pop-Location
}
