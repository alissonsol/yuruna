<#PSScriptInfo
.VERSION 2026.07.27
.GUID 42b30a01-b620-49c9-86d7-d350a1a6c299
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guid psscriptinfo pester
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
    Repo-wide Pester guard on the script identity convention: every
    PowerShell file carries a PSScriptInfo GUID, every GUID is 42-prefixed,
    and no two files share one.
.DESCRIPTION
    The GUID is what survives a rename -- it is the join key that keeps a
    file's history continuous when its name changes, so a duplicated GUID
    silently merges two files' histories and a missing one loses the file's
    past at the first rename. The 42 prefix is a visual filter in
    mixed-source logs (see docs/test-perf.md for the shape and the minting
    recipe).

    Scope is every tracked .ps1 / .psm1 / .psd1 in the repo, read from
    `git ls-files` so an ignored nested checkout cannot contribute
    look-alike collisions. Throw-based assertions so the file runs under
    the OS-bundled Pester 3.4 and Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.ScriptGuid.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# PSScriptInfo `.GUID <guid>` (scripts) and a manifest's `GUID = '<guid>'`
# (.psd1) are the two shapes the convention appears in.
function Get-ScriptGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*\.GUID\s+([0-9a-fA-F-]{36})\s*$')        { return $Matches[1] }
        if ($line -match "^\s*GUID\s*=\s*['`"]([0-9a-fA-F-]{36})['`"]") { return $Matches[1] }
    }
    return ''
}

function Get-TrackedPowerShellFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Push-Location -LiteralPath $RepoRoot
    try {
        # --others --exclude-standard adds files that are not committed yet but
        # are not ignored either, so a new script is held to the convention
        # before it lands rather than after. --exclude-standard is what keeps an
        # ignored nested checkout out of the collision set.
        $tracked = @(& git ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.psd1')
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed (exit $LASTEXITCODE) in $RepoRoot" }
    } finally {
        Pop-Location
    }
    return [string[]]@($tracked | Where-Object { $_ } | Sort-Object -Unique)
}

$psFiles = Get-TrackedPowerShellFile -RepoRoot $repoRoot
$records = @($psFiles | ForEach-Object {
        [pscustomobject]@{ Rel = $_; Guid = (Get-ScriptGuid -Path (Join-Path $repoRoot $_)) }
    })

Describe 'script identity -- PSScriptInfo GUIDs' {

    It 'finds PowerShell files to check' {
        Assert-True ($records.Count -gt 0) 'git ls-files returned no .ps1/.psm1/.psd1 -- the guard would pass vacuously'
    }

    It 'every PowerShell file declares a GUID' {
        $missing = @($records | Where-Object { -not $_.Guid } | ForEach-Object { $_.Rel })
        Assert-Equal -Expected 0 -Actual $missing.Count `
            -Because "these files carry no PSScriptInfo GUID: $($missing -join ', ')"
    }

    It 'every GUID starts with 42' {
        $bad = @($records | Where-Object { $_.Guid -and $_.Guid -notmatch '^42' } |
                ForEach-Object { "$($_.Rel) [$($_.Guid)]" })
        Assert-Equal -Expected 0 -Actual $bad.Count `
            -Because "these GUIDs are not 42-prefixed (mint one per docs/test-perf.md): $($bad -join '; ')"
    }

    It 'no two files share a GUID' {
        $dupes = @($records | Where-Object { $_.Guid } | Group-Object { $_.Guid.ToLower() } |
                Where-Object { $_.Count -gt 1 } |
                ForEach-Object { "$($_.Name) <- $(($_.Group | ForEach-Object { $_.Rel }) -join ' + ')" })
        Assert-Equal -Expected 0 -Actual $dupes.Count `
            -Because "a shared GUID merges two files' histories: $($dupes -join '; ')"
    }

    It 'every GUID is well-formed' {
        $malformed = @($records | Where-Object { $_.Guid } | Where-Object {
                $parsed = [guid]::Empty
                -not [guid]::TryParse($_.Guid, [ref]$parsed)
            } | ForEach-Object { "$($_.Rel) [$($_.Guid)]" })
        Assert-Equal -Expected 0 -Actual $malformed.Count `
            -Because "not parseable as a GUID: $($malformed -join '; ')"
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
