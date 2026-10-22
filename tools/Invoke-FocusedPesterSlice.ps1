<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42e1dc8e-ab00-4102-ab67-38cbf54ecfbe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna gates pester focused-slice
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
    Run one focused Pester slice and print what it found for the cross-repository gate.
.DESCRIPTION
    tools/Invoke-CrossRepoGate.ps1 runs its focused slices beside its other gates,
    each in a process of its own, and judges the result itself. This script only
    runs the slice and reports the facts the gate judges by, on one line that
    starts with YURUNA_FOCUSED_SLICE: the passed, failed and skipped-or-not-run
    counts, how many tests each required file contributed, and every failed test
    or container with the first line of its reason. Anything else the slice
    prints (a module warning, a test's own output) stays out of that line.
.PARAMETER RelativePath
    The slice's suite files, relative to the repository root and separated by ';'.
    One string, because an array does not survive a pwsh -File command line.
.OUTPUTS
    Exit 0 with the YURUNA_FOCUSED_SLICE line when the slice ran; 2 when Pester
    6.x is not installed; 1 when the slice could not execute.
#>

[CmdletBinding()]
param([Parameter(Mandatory)][string]$RelativePath)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$relative = @($RelativePath -split ';' | Where-Object { $_ })
$paths = @($relative | ForEach-Object { Join-Path $RepoRoot $_ })

# Import-Module takes the highest copy in range. The bounds keep these slices on
# the 6.x line the runner selects, whatever else is installed.
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'6.0' -and $_.Version -lt [version]'7.0' })) {
    Write-Output 'Pester 6.x is not installed'
    exit 2
}
try {
    Import-Module Pester -MinimumVersion 6.0 -MaximumVersion 6.999.999 -ErrorAction Stop
    $result = Invoke-Pester -Path $paths -Output None -PassThru
    $counts = [ordered]@{}
    foreach ($item in $relative) {
        $absolute = [IO.Path]::GetFullPath((Join-Path $RepoRoot $item))
        $counts[$item] = @($result.Tests | Where-Object { $_.ScriptBlock.File -and
                [IO.Path]::GetFullPath($_.ScriptBlock.File) -eq $absolute }).Count
    }
    $firstLine = {
        param($Record)
        $reason = ([string]($Record.ErrorRecord | Select-Object -First 1)) -split "`r?`n" |
            Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
        if ($reason) { $reason.Trim() } else { '' }
    }
    $failedNames = @($result.Tests | Where-Object Result -EQ 'Failed' | ForEach-Object {
            $reason = & $firstLine $_
            if ($reason) { "$($_.ExpandedPath) -- $reason" } else { [string]$_.ExpandedPath }
        } | Where-Object { $_ } | Sort-Object -Unique)
    # A container that fails before its tests run produces no failed test at
    # all. Only a container carrying its OWN error is named: one marked failed
    # merely because a test inside it failed is already named above.
    $failedNames += @($result.Containers | Where-Object Result -EQ 'Failed' | ForEach-Object {
            $reason = & $firstLine $_
            if ($reason) { "container $([IO.Path]::GetFileName([string]$_.Item)) -- $reason" }
        } | Where-Object { $_ })
    $facts = [ordered]@{
        passed      = [int]$result.PassedCount
        failed      = [int]$result.FailedCount + [int]$result.FailedBlocksCount + [int]$result.FailedContainersCount
        incomplete  = [int]$result.SkippedCount + [int]$result.NotRunCount
        counts      = $counts
        failedNames = @($failedNames)
    }
    Write-Output ('YURUNA_FOCUSED_SLICE ' + (ConvertTo-Json -InputObject $facts -Compress -Depth 4))
    exit 0
} catch {
    Write-Output "focused Pester slice failed to execute: $($_.Exception.Message)"
    exit 1
}
