<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42d362a1-db11-4834-938e-bcea5a9d09f2
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
    Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.ScriptGuid.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# PSScriptInfo `.GUID <guid>` (scripts) and a manifest's `GUID = '<guid>'`
# (.psd1) are the two shapes the convention appears in.
function Get-ScriptGuid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try { [void][IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch { return '' }
    try { $lines = [IO.File]::ReadAllLines($Path) } catch { return '' }
    foreach ($line in $lines) {
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

function Get-ScriptGuidRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    foreach ($relative in (Get-TrackedPowerShellFile -RepoRoot $RepoRoot)) {
        $guid = Get-ScriptGuid -Path (Join-Path $RepoRoot $relative)
        # The index can still name a retired file; unreadable existing files must remain in the census.
        if ($null -ne $guid) { [pscustomobject]@{ Rel = $relative; Guid = $guid } }
    }
}

$script:records = @(Get-ScriptGuidRecord -RepoRoot $repoRoot)

}

Describe 'script identity -- PSScriptInfo GUIDs' {

    It 'finds PowerShell files to check' {
        Assert-True ($script:records.Count -gt 0) 'git ls-files returned no .ps1/.psm1/.psd1 -- the guard would pass vacuously'
    }

    It 'every PowerShell file declares a GUID' {
        $missing = @($script:records | Where-Object { -not $_.Guid } | ForEach-Object { $_.Rel })
        Assert-Equal -Expected 0 -Actual $missing.Count `
            -Because "these files carry no PSScriptInfo GUID: $($missing -join ', ')"
    }

    It 'every GUID starts with 42' {
        $bad = @($script:records | Where-Object { $_.Guid -and $_.Guid -notmatch '^42' } |
                ForEach-Object { "$($_.Rel) [$($_.Guid)]" })
        Assert-Equal -Expected 0 -Actual $bad.Count `
            -Because "these GUIDs are not 42-prefixed (mint one per docs/test-perf.md): $($bad -join '; ')"
    }

    It 'no two files share a GUID' {
        $dupes = @($script:records | Where-Object { $_.Guid } | Group-Object { $_.Guid.ToLower() } |
                Where-Object { $_.Count -gt 1 } |
                ForEach-Object { "$($_.Name) <- $(($_.Group | ForEach-Object { $_.Rel }) -join ' + ')" })
        Assert-Equal -Expected 0 -Actual $dupes.Count `
            -Because "a shared GUID merges two files' histories: $($dupes -join '; ')"
    }

    It 'every GUID is well-formed' {
        $malformed = @($script:records | Where-Object { $_.Guid } | Where-Object {
                $parsed = [guid]::Empty
                -not [guid]::TryParse($_.Guid, [ref]$parsed)
            } | ForEach-Object { "$($_.Rel) [$($_.Guid)]" })
        Assert-Equal -Expected 0 -Actual $malformed.Count `
            -Because "not parseable as a GUID: $($malformed -join '; ')"
    }
}


Describe 'the working-tree script GUID census' {
    BeforeAll {
        function New-ScriptGuidCensusFixture {
            [CmdletBinding(SupportsShouldProcess)]
            param()
            $root = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-guid-census-' + [guid]::NewGuid().ToString('N'))
            if (-not $PSCmdlet.ShouldProcess($root, 'Create private GUID census fixture')) { return $null }
            [void][IO.Directory]::CreateDirectory($root)
            & git -C $root init --quiet
            if ($LASTEXITCODE -ne 0) { throw 'Private GUID census fixture initialization failed.' }
            return $root
        }

        function Remove-ScriptGuidCensusFixture {
            [CmdletBinding(SupportsShouldProcess)]
            param([Parameter(Mandatory)][string]$FixtureRoot)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $resolved = [IO.Path]::GetFullPath($FixtureRoot)
            $parent = [IO.Path]::GetDirectoryName($resolved)
            $name = [IO.Path]::GetFileName($resolved)
            if (-not [string]::Equals($parent, $tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $name -notmatch '^yuruna-guid-census-[a-f0-9]{32}$') {
                throw 'Refused GUID fixture cleanup outside its intended temporary root.'
            }
            if (([IO.File]::GetAttributes($resolved) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Refused GUID fixture cleanup through a reparse point.'
            }
            $reparse = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse -ErrorAction Stop |
                Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
            if ($reparse.Count -gt 0) { throw 'Remove fixture reparse points separately before recursive cleanup.' }
            if ($PSCmdlet.ShouldProcess($resolved, 'Remove private GUID census fixture')) {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            }
        }
    }

    It 'omits a tracked file only after the working-tree file is deleted' {
        $fixture = New-ScriptGuidCensusFixture
        try {
            $path = Join-Path $fixture 'retired.ps1'
            [IO.File]::WriteAllText($path, '.GUID 42a701dd-4c44-4321-a234-123456789abc')
            & git -C $fixture add -- retired.ps1
            if ($LASTEXITCODE -ne 0) { throw 'Private GUID census fixture staging failed.' }
            Assert-Equal -Expected 1 -Actual @(Get-ScriptGuidRecord -RepoRoot $fixture).Count
            [IO.File]::Delete($path)
            Assert-True (@(Get-TrackedPowerShellFile -RepoRoot $fixture) -contains 'retired.ps1') 'the fixture index still names the deletion'
            Assert-Equal -Expected 0 -Actual @(Get-ScriptGuidRecord -RepoRoot $fixture).Count
            Assert-True ($null -eq (Get-ScriptGuid -Path (Join-Path $fixture 'missing-parent/retired.ps1'))) 'a missing parent also proves absence'
        } finally { Remove-ScriptGuidCensusFixture -FixtureRoot $fixture }
    }

    It 'keeps a new untracked file without a GUID in the failure census' {
        $fixture = New-ScriptGuidCensusFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fixture 'new.ps1'), 'Write-Output fixture')
            $found = @(Get-ScriptGuidRecord -RepoRoot $fixture)
            Assert-Equal -Expected 1 -Actual $found.Count
            Assert-StringEqual -Expected 'new.ps1' -Actual $found[0].Rel
            Assert-True ($null -ne $found[0].Guid -and $found[0].Guid -ceq '') 'the new missing GUID remains a failure'
        } finally { Remove-ScriptGuidCensusFixture -FixtureRoot $fixture }
    }

    It 'keeps an existing unreadable tracked path rather than treating it as absent' {
        $fixture = New-ScriptGuidCensusFixture
        try {
            $path = Join-Path $fixture 'unreadable.ps1'
            [IO.File]::WriteAllText($path, '.GUID 42a701dd-4c44-4321-a234-123456789abc')
            & git -C $fixture add -- unreadable.ps1
            if ($LASTEXITCODE -ne 0) { throw 'Private GUID census fixture staging failed.' }
            [IO.File]::Delete($path)
            [void][IO.Directory]::CreateDirectory($path)
            $found = @(Get-ScriptGuidRecord -RepoRoot $fixture)
            Assert-Equal -Expected 1 -Actual $found.Count
            Assert-StringEqual -Expected 'unreadable.ps1' -Actual $found[0].Rel
            Assert-True ($null -ne $found[0].Guid -and $found[0].Guid -ceq '') 'an existing directory is an access error, not a missing file'
        } finally { Remove-ScriptGuidCensusFixture -FixtureRoot $fixture }
    }

    It 'keeps an existing Windows file with a denied read in the failure census' -Skip:(-not $IsWindows) {
        $fixture = New-ScriptGuidCensusFixture
        $held = $null
        try {
            $path = Join-Path $fixture 'locked.ps1'
            [IO.File]::WriteAllText($path, '.GUID 42a701dd-4c44-4321-a234-123456789abc')
            $held = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $found = @(Get-ScriptGuidRecord -RepoRoot $fixture)
            Assert-Equal -Expected 1 -Actual $found.Count
            Assert-StringEqual -Expected 'locked.ps1' -Actual $found[0].Rel
            Assert-True ($null -ne $found[0].Guid -and $found[0].Guid -ceq '') 'a sharing violation remains a missing-GUID failure'
        } finally {
            if ($held) { $held.Dispose() }
            Remove-ScriptGuidCensusFixture -FixtureRoot $fixture
        }
    }

    It 'keeps an existing broken Windows junction in the failure census' -Skip:(-not $IsWindows) {
        $fixture = New-ScriptGuidCensusFixture
        $path = Join-Path $fixture 'broken.ps1'
        try {
            [IO.File]::WriteAllText($path, '.GUID 42a701dd-4c44-4321-a234-123456789abc')
            & git -C $fixture add -- broken.ps1
            if ($LASTEXITCODE -ne 0) { throw 'Private GUID census fixture staging failed.' }
            [IO.File]::Delete($path)
            $target = Join-Path $fixture 'private-target'
            [void][IO.Directory]::CreateDirectory($target)
            New-Item -ItemType Junction -Path $path -Target $target -ErrorAction Stop | Out-Null
            [IO.Directory]::Delete($target)
            Assert-True (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'the broken junction itself still exists'
            $found = @(Get-ScriptGuidRecord -RepoRoot $fixture)
            Assert-Equal -Expected 1 -Actual $found.Count
            Assert-StringEqual -Expected 'broken.ps1' -Actual $found[0].Rel
            Assert-True ($null -ne $found[0].Guid -and $found[0].Guid -ceq '') 'a broken existing reparse point remains a failure'
        } finally {
            try { [IO.Directory]::Delete($path) }
            catch [IO.DirectoryNotFoundException] { Write-Verbose 'The private junction parent is already absent.' }
            catch [IO.FileNotFoundException] { Write-Verbose 'The private junction is already absent.' }
            Remove-ScriptGuidCensusFixture -FixtureRoot $fixture
        }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
