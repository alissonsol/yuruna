<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42e9bd8a-5257-4459-82a4-765455c96fe3
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
    normalization, find/replace, or broad changes converting encoding
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
.PARAMETER BomOnly
    Check for a BOM but allow non-ASCII bytes. For the far larger set of
    files that must merely stay BOM-free: a BOM is never wanted anywhere
    (it is invisible in every editor, rides into hashes and heredocs, and
    breaks byte-for-byte consumers), while non-ASCII content is legitimate
    outside the bootstrap set -- guest scripts print box-drawing characters,
    docs quote real names.

.EXAMPLE
    pwsh tools/Test-AsciiNoBom.ps1
    # Checks install/windows.hyper-v.ps1; exits 0 / 1.

.EXAMPLE
    pwsh tools/Test-AsciiNoBom.ps1 -Path 'install/*.ps1' -Quiet
    # Glob over every installer script; quiet on PASS.

.PARAMETER Staged
    Check the files staged for commit instead of -Path. The lookup lives
    here rather than in the caller because `pwsh -File` binds each argument
    after the script as a separate positional value -- a list of paths
    passed as `-Path a b c` fails to bind, so a shell hook cannot hand one
    over. Added, copied and modified files only; a deletion has nothing to
    read.

.EXAMPLE
    pwsh tools/Test-AsciiNoBom.ps1 -BomOnly -Staged -Quiet
    # BOM sweep over what is about to be committed; non-ASCII is allowed.
#>

[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Quiet,
    [switch]$BomOnly,
    [switch]$Staged,
    [switch]$Bootstrap
)

$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot

Import-Module (Join-Path $RepoRoot 'test/modules/Test.Prelude.psm1') -Global -Force
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

if ($Bootstrap) {
    # The four paths a fresh host executes byte-for-byte before any
    # BOM-tolerant shell exists. A switch rather than a path list for the same
    # reason -Staged is one: `pwsh -File` binds each argument after the script
    # as a separate positional value, so `-Path a b c` does not bind and a
    # caller that tried would silently check NOTHING and pass.
    $Path = @(
        (Join-Path $RepoRoot 'install/windows.hyper-v.ps1'),
        (Join-Path $RepoRoot 'install/ubuntu.kvm.sh'),
        (Join-Path $RepoRoot 'install/macos.utm.sh'),
        (Join-Path $RepoRoot 'guest/windows.11/*.ps1')
    )
}

if ($Staged) {
    # Advisory: a repo-less or git-less environment must not block a commit,
    # so an unusable git degrades to "nothing to check" rather than a failure.
    $names = @(& git -C $RepoRoot diff --cached --name-only --diff-filter=ACM 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Test-AsciiNoBom: could not list staged files (git exit $LASTEXITCODE); nothing checked."
        exit $ExitOk
    }
    $Path = @($names | Where-Object { $_ } | ForEach-Object { Join-Path $RepoRoot $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($Path.Count -eq 0) {
        if (-not $Quiet) { Write-Output 'Test-AsciiNoBom: no staged files to check.' }
        exit $ExitOk
    }
}

if (-not $Path -or $Path.Count -eq 0) {
    # The default set is every tracked file whose type is ASCII BY POLICY.
    #
    # It began as four bootstrap paths -- the three installers fetched with
    # `irm | iex` or `curl | bash`, and the guest/windows.11 scripts a fresh
    # Windows guest runs the same way -- where a BOM or a non-ASCII byte
    # aborts at line 1 before any tolerant shell exists. Those are still the
    # sharpest cases, but four files turned out to be too narrow an aperture:
    # a tree-wide normalization can rewrite a character in three copies of a
    # shared block and miss the fourth, and nothing here would notice. That
    # is not hypothetical -- it forked the page-chrome block that
    # Test.ExtensionUiChrome.Tests.ps1 requires to be byte-identical, and
    # only that unrelated guard caught it.
    #
    # WHAT IS DELIBERATELY NOT COVERED, and why widening further would be
    # wrong rather than merely stricter: markdown, HTML and JavaScript carry
    # USER-VISIBLE typography -- em dashes in a <title>, an ellipsis in a
    # loading label, the box-drawing separators in yuruna.common.js -- and
    # store_test.go holds a deliberate "file.cafe" charset fixture whose
    # whole purpose is to be non-ASCII. Forcing those to ASCII would damage
    # what they render or what they prove. The types below carry no such
    # content: all 476 PowerShell files, 35 shell scripts, 5 stylesheets, and
    # every tracked JSON and YAML document are ASCII today, so this gate is
    # green on adoption and stays a real signal rather than a backlog.
    $trackedTypes = @('*.ps1', '*.psm1', '*.psd1', '*.sh', '*.bash', '*.css', '*.json', '*.yml', '*.yaml')
    $tracked = @(& git -C $RepoRoot ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -eq 0 -and $tracked.Count -gt 0) {
        $Path = @($tracked |
            Where-Object { $n = [IO.Path]::GetFileName($_); $trackedTypes | Where-Object { $n -like $_ } } |
            ForEach-Object { Join-Path $RepoRoot $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    # Outside a work tree there is nothing to enumerate, so fall back to the
    # bootstrap set the gate started with rather than checking nothing.
    if (-not $Path -or $Path.Count -eq 0) {
        $Path = @(
            (Join-Path $RepoRoot 'install/windows.hyper-v.ps1'),
            (Join-Path $RepoRoot 'install/ubuntu.kvm.sh'),
            (Join-Path $RepoRoot 'install/macos.utm.sh'),
            (Join-Path $RepoRoot 'guest/windows.11/*.ps1')
        )
    }
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
    # Reached only with an explicit -Path (a -Staged run with nothing staged
    # returns earlier). Passing here would report success having read nothing,
    # which is the failure mode this gate exists to prevent.
    exit $ExitFailure
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
    if ($BomOnly) {
        if (-not $Quiet) { Write-Output "PASS  $file  ($($bytes.Length) bytes, no BOM)" }
        continue
    }
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
$mode = if ($BomOnly) { 'BOM-only' } else { 'ASCII+BOM' }
if ($failures.Count -eq 0) {
    Write-Output "Test-AsciiNoBom [$mode]: $($resolved.Count) file(s) checked, all clean."
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
