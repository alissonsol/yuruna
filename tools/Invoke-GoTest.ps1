<#PSScriptInfo
.VERSION 2026.08.20
.GUID 423bf361-3c2d-4eec-ac8d-50aca4319afe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna go test vet build extension
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
    Build, vet and test every Go module under test/extension.
.DESCRIPTION
    The extension services carry ~19,700 lines of Go test across ~69 files, and
    before this script nothing in the repo ran any of it. That is not a
    theoretical gap: one module was found failing at HEAD because a UI change
    added a table column and the accessibility invariant that column violated
    was never re-checked.

    Modules are discovered by walking for go.mod rather than listing them, so a
    new service is covered the day it is added instead of the day someone
    remembers to add it here.

    All three phases run per module and all are gates. `go build` alone would
    miss the failing assertion; `go test` alone would miss a vet finding that
    fails a stricter toolchain later.

.PARAMETER Path
    Repo-relative root to search for Go modules. Default: test/extension.
.PARAMETER SkipTest
    Run build and vet only. For a fast syntax check, not for a gate.
.PARAMETER Quiet
    Print only the summary line.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-GoTest.ps1
    Exits non-zero if any module fails to build, vet or test.
#>

[CmdletBinding()]
param(
    [string]$Path = 'test/extension',
    [switch]$SkipTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Error "go is not installed or not on PATH." -ErrorAction Continue
    exit 2
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SearchIn = Join-Path $RepoRoot $Path
if (-not (Test-Path -LiteralPath $SearchIn)) {
    Write-Error "no such path: $SearchIn" -ErrorAction Continue
    exit 2
}

$modules = @(Get-ChildItem -LiteralPath $SearchIn -Recurse -File -Filter 'go.mod' |
        Sort-Object FullName |
        ForEach-Object { $_.DirectoryName })

if ($modules.Count -eq 0) {
    Write-Error "no go.mod found under $SearchIn" -ErrorAction Continue
    exit 2
}

$phases = if ($SkipTest) { @('build', 'vet') } else { @('build', 'vet', 'test') }
$failures = [Collections.Generic.List[string]]::new()

foreach ($module in $modules) {
    $name = [IO.Path]::GetRelativePath($RepoRoot, $module) -replace '\\', '/'
    foreach ($phase in $phases) {
        Push-Location $module
        try {
            $output = & go $phase './...' 2>&1
            $ok = ($LASTEXITCODE -eq 0)
        } finally {
            Pop-Location
        }
        if (-not $ok) {
            $failures.Add("${name}: go $phase failed")
            if (-not $Quiet) {
                Write-Information "--- ${name}: go $phase ---" -InformationAction Continue
                ($output | Out-String).TrimEnd() | Write-Information -InformationAction Continue
            }
            # The later phases would only restate the same breakage.
            break
        }
        if (-not $Quiet -and $phase -eq 'test') {
            ($output | Where-Object { $_ -match '^(ok|---|FAIL|\?)' } | Out-String).TrimEnd() |
                Write-Information -InformationAction Continue
        }
    }
}

Write-Information ("{0} Go module(s), {1} failed" -f $modules.Count, $failures.Count) -InformationAction Continue

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Error $f -ErrorAction Continue }
    exit 1
}
exit 0
