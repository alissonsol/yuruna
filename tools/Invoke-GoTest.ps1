<#PSScriptInfo
.VERSION 2026.09.13
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
    this gate is the only thing in the repo that runs them. An unrun test body
    silently accumulates failures: a change that violates an invariant a test
    asserts stays green until something actually executes the assertion.

    Modules are discovered by walking for go.mod rather than listing them, so a
    new service is covered the day it is added instead of the day someone
    remembers to add it here.

    All three phases run per module and all are gates. `go build` alone would
    miss the failing assertion; `go test` alone would miss a vet finding that
    fails a stricter toolchain later.

    A module that resolves the shared SDK with `replace ... => ../extension-sdk`
    is built in a staged copy. That path names a sibling directory which exists
    only in the layout the guest bring-up assembles, so running such a module
    where it lives cannot resolve the SDK at all. The staging mirrors the
    guest's -- module at server/, SDK beside it -- and is removed when the
    module's phases finish.

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

# The service modules name the shared SDK as a SIBLING (`replace ... =>
# ../extension-sdk`) because that is the layout their guest bring-up builds in:
# the module copied to $BUILD/server, the SDK copied beside it. In the tree the
# SDK is one directory further out, so a module run where it lives resolves
# nothing. Reproduce the guest's layout in a throwaway directory instead of
# reshaping what ships: the gate then builds what the guest builds, the way the
# guest builds it.
$sdkReplace = '(?m)^\s*replace\s+yuruna\.com/test/extension/extension-sdk\s+=>\s+\.\./extension-sdk\s*$'

foreach ($module in $modules) {
    $name = [IO.Path]::GetRelativePath($RepoRoot, $module) -replace '\\', '/'

    $stage = $null
    $runIn = $module
    if ((Get-Content -Raw -LiteralPath (Join-Path $module 'go.mod')) -match $sdkReplace) {
        # Walk outwards for the SDK rather than assuming a depth: a module whose
        # go.mod sits somewhere other than <area>/server would otherwise stage a
        # directory that is not the SDK, and fail a phase later with an error
        # about the code instead of about the layout.
        $sdk = $null
        for ($dir = Split-Path -Parent $module; $dir; $dir = Split-Path -Parent $dir) {
            $candidate = Join-Path $dir 'extension-sdk'
            if (Test-Path -LiteralPath (Join-Path $candidate 'go.mod')) { $sdk = $candidate; break }
        }
        if (-not $sdk) {
            $failures.Add("${name}: requires the extension SDK, and no extension-sdk module sits above it")
            continue
        }
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-gotest-' + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -LiteralPath $module -Destination (Join-Path $stage 'server') -Recurse
        Copy-Item -LiteralPath $sdk -Destination (Join-Path $stage 'extension-sdk') -Recurse
        $runIn = Join-Path $stage 'server'
    }

    try {
        foreach ($phase in $phases) {
            Push-Location $runIn
            try {
                # -buildvcs=false because a staged module is a copy in a temp
                # directory with no repository above it. Go treats a VCS query
                # it cannot answer as a build failure, so without this every
                # SDK-consuming service fails the gate for a reason that has
                # nothing to do with its code -- and a gate that always fails
                # is read as broken tooling and then ignored.
                $goArgs = @($phase)
                if ($stage) { $goArgs += '-buildvcs=false' }
                $goArgs += './...'
                $output = & go @goArgs 2>&1
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
    } finally {
        if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Information ("{0} Go module(s), {1} failed" -f $modules.Count, $failures.Count) -InformationAction Continue

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Error $f -ErrorAction Continue }
    exit 1
}
exit 0
