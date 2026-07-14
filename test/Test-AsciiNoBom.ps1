<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42d0c9e8-f7a6-4c54-5432-bad0c9e8f7a6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate ascii bom
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
    CI gate: verify a target file is pure 7-bit ASCII with no UTF-8 BOM.
.DESCRIPTION
    The bootstrap installer `install/windows.hyper-v.ps1` runs through
    PS 5.1's `irm | iex` pipeline, which parses byte-for-byte: a UTF-8
    BOM or any non-ASCII byte aborts at line 1 before the param block
    is reached. See repo memory file
    feedback_bootstrap_installer_no_bom.md for the trap class.

    The constraint holds today by convention only. This script is the
    automated guard so a future bulk encoding pass (line-ending
    normalisation, find/replace, or broad changes converting encoding
    to UTF-8 with BOM) cannot silently break first-install on a fresh PS 5.1
    host without CI catching it.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  All target files are clean.
        1  At least one file failed (BOM present, or non-ASCII byte).

.PARAMETER Path
    One or more file paths to check. Wildcards allowed. Default: the
    canonical bootstrap installer
    (`install/windows.hyper-v.ps1`, resolved relative to this script's
    repo root).
.PARAMETER Quiet
    Suppress per-file PASS lines; only failures and the final summary
    print. Errors still surface.

.EXAMPLE
    pwsh test/Test-AsciiNoBom.ps1
    # Checks install/windows.hyper-v.ps1; exits 0 / 1.

.EXAMPLE
    pwsh test/Test-AsciiNoBom.ps1 -Path 'install/*.ps1' -Quiet
    # Glob over every installer script; quiet on PASS.
#>

[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Quiet
)

$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot

Import-Module (Join-Path $TestRoot 'modules/Test.Prelude.psm1') -Global -Force
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

if (-not $Path -or $Path.Count -eq 0) {
    # Default set: every script fetched and executed byte-for-byte on a
    # fresh host before any BOM-tolerant shell exists -- the three bootstrap
    # installers (PS 5.1 `irm | iex` and the `curl | bash` Linux/macOS ones,
    # where a leading BOM breaks the shebang) and the guest/windows.11 scripts
    # the freshly-provisioned Windows guest runs first the same way. A BOM or
    # non-ASCII byte in any of them aborts at line 1. Add more such scripts
    # here as they adopt the convention.
    $Path = @(
        (Join-Path $RepoRoot 'install/windows.hyper-v.ps1'),
        (Join-Path $RepoRoot 'install/ubuntu.kvm.sh'),
        (Join-Path $RepoRoot 'install/macos.utm.sh'),
        (Join-Path $RepoRoot 'guest/windows.11/*.ps1')
    )
}

# Resolve every input (supporting wildcards) into concrete file paths.
$resolved = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
    $hits = @(Resolve-Path -Path $p -ErrorAction SilentlyContinue)
    if (-not $hits) {
        Write-Warning "Test-AsciiNoBom: no matches for path '$p' (skipping)"
        continue
    }
    foreach ($h in $hits) {
        if ($h.Path -and (Test-Path -LiteralPath $h.Path -PathType Leaf)) {
            $resolved.Add($h.Path)
        }
    }
}
if ($resolved.Count -eq 0) {
    Write-Warning "Test-AsciiNoBom: no files matched any input path."
    exit $ExitOk
}

$failures = New-Object System.Collections.Generic.List[hashtable]
foreach ($file in $resolved) {
    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($file)
    } catch {
        $failures.Add(@{ path = $file; reason = "read failed: $($_.Exception.Message)"; offset = $null; byte = $null })
        continue
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        # Empty file is trivially compliant; not flagged.
        if (-not $Quiet) { Write-Output "PASS  $file  (empty)" }
        continue
    }
    # Check 1: UTF-8 BOM (0xEF 0xBB 0xBF). PS 5.1's irm|iex chokes on
    # this at line 1.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $failures.Add(@{ path = $file; reason = 'UTF-8 BOM (0xEF 0xBB 0xBF) at offset 0'; offset = 0; byte = '0xEF 0xBB 0xBF' })
        continue
    }
    # Check 2: UTF-16 LE/BE BOM (0xFF 0xFE / 0xFE 0xFF). Also fatal.
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        $failures.Add(@{ path = $file; reason = 'UTF-16 BOM at offset 0'; offset = 0; byte = ('0x{0:X2} 0x{1:X2}' -f $bytes[0], $bytes[1]) })
        continue
    }
    # Check 3: every byte must be 7-bit ASCII (0x00..0x7F). Locate the
    # first offender so a human can jump straight to the byte.
    $offender = -1
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) { $offender = $i; break }
    }
    if ($offender -ge 0) {
        $failures.Add(@{
            path   = $file
            reason = "non-ASCII byte at offset $offender"
            offset = $offender
            byte   = ('0x{0:X2}' -f $bytes[$offender])
        })
        continue
    }
    if (-not $Quiet) { Write-Output "PASS  $file  ($($bytes.Length) bytes, pure ASCII, no BOM)" }
}

Write-Output ''
if ($failures.Count -eq 0) {
    Write-Output "Test-AsciiNoBom: $($resolved.Count) file(s) checked, all clean."
    exit $ExitOk
}
Write-Warning "Test-AsciiNoBom: $($failures.Count) of $($resolved.Count) file(s) FAILED:"
foreach ($f in $failures) {
    Write-Warning ("  FAIL  {0}" -f $f.path)
    Write-Warning ("        reason: {0}" -f $f.reason)
    if ($null -ne $f.offset) {
        Write-Warning ("        offset: {0} (byte: {1})" -f $f.offset, $f.byte)
    }
}
Write-Warning ''
Write-Warning 'Fix: rewrite each failing file as BOM-less, ASCII-only UTF-8. The'
Write-Warning '  PS7 idiom is:'
Write-Warning '    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))'
Write-Warning '  See repo memory file feedback_bootstrap_installer_no_bom.md.'
exit $ExitFailure
