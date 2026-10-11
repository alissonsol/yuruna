<#PSScriptInfo
.VERSION 2026.10.11
.GUID 426c2966-1a4f-4c9d-a3cb-136c7311b803
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest pkill selfmatch pester
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
    Guards guest shell scripts against a `pkill -f` pattern that matches the
    script's own running process.
.DESCRIPTION
    fetch-and-execute.sh runs a downloaded guest script as the literal
    command-string argument to `bash -c "$script_content" ...`, so the
    kernel-level argv -- and therefore /proc/<pid>/cmdline, what `pkill -f`
    searches -- IS this script's own source text for the whole time it runs.
    A `pkill -f PATTERN` call whose PATTERN also appears as one contiguous
    literal substring elsewhere in the same file (almost always: right there
    in the pkill line itself) matches the running script's own shell and
    SIGTERMs it mid-execution, surfacing as an unexplained exit 143 with no
    diagnostic pointing at the cause.

    This swept every tracked guest/**/*.sh for `pkill -f <literal>` calls and
    asserts the literal pattern never appears as a contiguous substring
    anywhere in that same file. A script that needs the match can still get
    it by assembling the pattern from pieces at runtime (see
    guest/shared/ubuntu.update.sh), which keeps the contiguous string out of
    the file -- and so out of this process's own cmdline -- while still
    matching the target process, whose cmdline does carry it whole.
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$testDir   = Split-Path -Parent $here
$repoRoot  = Split-Path -Parent $testDir
$guestRoot = Join-Path $repoRoot 'guest'
$script:guestRoot = $guestRoot
$script:repoRoot = $repoRoot

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Matches `pkill -f <pattern>` with a single- or double-quoted, or bare,
# pattern argument -- the forms guest scripts in this repo actually use.
$script:PkillPattern = [regex]'pkill\s+(?:[^\s]+\s+)*-f\s+(?:"([^"]+)"|''([^'']+)''|(\S+))'

function Get-PkillSelfMatchOffense {
    param([string]$FullPath, [string]$RelativePath)
    $content = Get-Content -LiteralPath $FullPath -Raw
    $offenses = @()
    foreach ($match in $script:PkillPattern.Matches($content)) {
        $pattern = @($match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value) |
            Where-Object { $_ } | Select-Object -First 1
        if (-not $pattern) { continue }
        # A dynamic argument (variable expansion, command substitution) is
        # never one contiguous literal string in the source, so it cannot be
        # the kind of self-match this guard targets; skip it rather than
        # false-positive on ordinary shell quoting.
        if ($pattern -match '[$`]') { continue }
        $occurrences = 0
        $searchFrom = 0
        while (($index = $content.IndexOf($pattern, $searchFrom, [System.StringComparison]::Ordinal)) -ge 0) {
            $occurrences++
            $searchFrom = $index + 1
        }
        if ($occurrences -gt 0) {
            $offenses += "${RelativePath}: pkill -f '$pattern' is a literal substring of this file's own source ($occurrences occurrence(s)); bash -c runs this script's text as its own cmdline, so this self-matches. Build the pattern from pieces at runtime instead."
        }
    }
    $offenses
}
}

Describe 'guest scripts do not pkill -f their own running process' {
    It 'has no pkill -f pattern that is a literal substring of its own guest script' {
        $offenders = @()
        if (-not (Test-Path -LiteralPath $script:guestRoot)) {
            Set-ItResult -Skipped -Because 'no guest/ directory in this checkout'
            return
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $script:guestRoot -Recurse -Filter '*.sh' -File)) {
            $relative = $file.FullName.Substring($script:repoRoot.Length + 1)
            $offenders += @(Get-PkillSelfMatchOffense -FullPath $file.FullName -RelativePath $relative)
        }
        Assert-True ($offenders.Count -eq 0) ("self-matching pkill -f found:`n" + ($offenders -join "`n"))
    }
}
