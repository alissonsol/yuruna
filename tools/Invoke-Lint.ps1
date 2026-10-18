<#PSScriptInfo
.VERSION 2026.10.14
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
    No other path or analyzer rule is suppressed. Command-binding findings
    are confirmed in a fresh process with that rule alone: concurrent rules
    can corrupt the analyzer's shared command metadata. Other findings stay
    intact, and an unsuccessful confirmation fails the scan.
.PARAMETER Path
    Optional PowerShell file or directory to scan: repository-relative (e.g.
    'test/modules/Test.Locale.psm1' or 'test/modules'), or an absolute path inside
    or outside this repository. Leading './' and either slash style are accepted.
    An absolute path outside the repository is listed with the same git selector
    inside its own worktree, or every file below it when no worktree encloses it.
    An explicit scope with no tracked/new, non-ignored PowerShell source fails.
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
    [Parameter(DontShow)][string]$AnalyzerBatchFile,
    [Parameter(DontShow)][switch]$AnalyzerCommandBindingOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Error "PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser" -ErrorAction Continue
    exit 2
}
Import-Module PSScriptAnalyzer

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Settings = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
Import-Module (Join-Path $PSScriptRoot 'Gate.Scope.psm1') -Force -DisableNameChecking

# PSScriptAnalyzer occasionally poisons its process-wide state and throws a
# NullReferenceException for a file it analyzes cleanly in a fresh process.
# This internal mode is the genuinely isolated last retry used below. It emits
# only a small JSON projection, so the parent never mistakes analyzer text for
# a finding or loses a real result through remoting serialization.
if ($AnalyzerIsolatePath) {
    $lastError = ''
    foreach ($attempt in 1..3) {
        try {
            $analyzerArguments = @{ Path = $AnalyzerIsolatePath; ErrorAction = 'Stop' }
            if ($AnalyzerCommandBindingOnly) {
                $analyzerArguments.Settings = @{ IncludeRules = @('PSUseCmdletCorrectly') }
            } else { $analyzerArguments.Settings = $Settings }
            $isolated = @(Invoke-ScriptAnalyzer @analyzerArguments)
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

# --- REGION: Invoke-IsolatedLintAnalysis
function Invoke-IsolatedLintAnalysis {
    <#
    .SYNOPSIS
        Obtain checked analyzer evidence from a fresh PowerShell process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ToolPath,
        [switch]$CommandBindingOnly
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-File', $ToolPath, '-AnalyzerIsolatePath', $Path)
    if ($CommandBindingOnly) { $arguments += '-AnalyzerCommandBindingOnly' }
    $shell = (Get-Process -Id $PID).Path
    $output = & $shell @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    $result = $null
    try { $result = ConvertFrom-Json -InputObject $output -ErrorAction Stop }
    catch { throw "Isolated analyzer returned invalid JSON (exit ${code}): $($output.Trim())" }
    if ($code -ne 0 -or $result.success -isnot [bool] -or -not $result.success -or
        'findings' -notin @($result.PSObject.Properties.Name) -or $result.findings -isnot [Array]) {
        throw "Isolated analyzer failed (exit ${code}): $($output.Trim())"
    }
    return $result
}

# --- REGION: Confirm-LintCommandBindingFinding
function Confirm-LintCommandBindingFinding {
    <#
    .SYNOPSIS
        Recheck command-binding diagnostics without concurrent analyzer rules.
    #>
    [CmdletBinding()]
    [OutputType([object[]], [Array])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Finding,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ToolPath
    )

    if (-not @($Finding | Where-Object RuleName -EQ 'PSUseCmdletCorrectly').Count) {
        return $Finding
    }
    # Only this rule's evidence is replaced. A clean confirmation must not
    # discard an unrelated security, syntax, or style finding from the scan.
    $confirmed = Invoke-IsolatedLintAnalysis -Path $Path -ToolPath $ToolPath -CommandBindingOnly
    @($Finding | Where-Object RuleName -NE 'PSUseCmdletCorrectly')
    @($confirmed.findings)
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
        $absolute = if ([IO.Path]::IsPathRooted($relative)) { $relative } else { Join-Path $RepoRoot $relative }
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
                    try {
                        $isolatedResult = Invoke-IsolatedLintAnalysis -Path $absolute -ToolPath $PSCommandPath
                        $results = @($isolatedResult.findings)
                    } catch { $why = $_.Exception.Message }
                }
            }
        }
        if (-not $why) {
            try {
                $results = @(Confirm-LintCommandBindingFinding -Finding @($results) `
                        -Path $absolute -ToolPath $PSCommandPath)
            } catch { $why = $_.Exception.Message }
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
    $explicitScope = $PSBoundParameters.ContainsKey('Path')
    $target = $null
    if ($explicitScope) {
        try { $target = Resolve-GateTarget -Value $Path -RepoRoot $RepoRoot }
        catch {
            Write-Error -Message $_.Exception.Message -ErrorAction Continue
            exit 2
        }
    }
    if ($target -and $target.Kind -eq 'External') {
        # An absolute path outside this repository is not in this repository's
        # index, so its files come from its own worktree (or from a plain walk).
        $files = @(Get-GateExternalFile -Path $target.Path |
            Where-Object { $_ -match '\.(ps1|psm1|psd1)$' } |
            Sort-Object -Unique)
    } else {
        $scope = if ($target) { $target.Scope } else { '' }
        $files = @(git ls-files --cached --others --exclude-standard |
            Where-Object { $_ -and $_ -match '\.(ps1|psm1|psd1)$' } |
            Where-Object { Test-GateScopeMatch -RelativePath $_ -Scope $scope } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Sort-Object -Unique)
    }

    if ($files.Count -eq 0) {
        if ($explicitScope) {
            Write-Error -Message "No tracked/new, non-ignored PowerShell source matches explicit scope '$Path'." -ErrorAction Continue
            exit 2
        }
        Write-Output 'No PowerShell files to scan.'
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
