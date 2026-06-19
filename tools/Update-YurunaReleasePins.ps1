<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42e1f2a3-b4c5-4d67-8901-aabbccddee01
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna release installer integrity sign
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
    Release-prep for the bootstrap installers: regenerate install/install.sha256
    from the live installer files, sign it with the release private key, and run
    the ASCII/no-BOM gate as a HARD precondition.

.DESCRIPTION
    Reads the CalVer release from the repo-root VERSION file and produces the
    integrity artifacts a tagged release publishes:

      install/install.sha256       SHA-256 of the three bootstrap installers
      install/install.sha256.sig   detached PKCS#1 v1.5 / SHA-256 signature

    Both are fetched and verified by the verified two-step install path (see
    install/README.md) against the bundled public key in install/keys/.

    The ASCII/no-BOM gate (test/Test-AsciiNoBom.ps1) runs FIRST and hard-fails
    the release if a byte-parsed bootstrap script carries a BOM or a non-ASCII
    byte -- the authoritative backstop the per-cycle gate and the pre-commit
    hook (Item 6) point at for the published artifact.

    It also repoints the release pins -- the installer clone defaults and the
    README one-liners/verified path from `main` to `refs/tags/<VERSION>`. Pins
    are rewritten by default; use -SkipPins to regenerate and gate the manifest
    without touching the refs.

.PARAMETER PrivateKeyPath
    Path to the release RSA private key (PEM). Read only at release time from a
    location the release owner supplies; never stored in the repo. Omit with
    -SkipSign to regenerate + gate without signing (e.g. a CI dry-run).

.PARAMETER RepoRoot
    Repo root. Defaults to the parent of this script's tools/ folder.

.PARAMETER SkipSign
    Regenerate install.sha256 and run the gate, but do not sign. The existing
    .sig is left untouched (and will no longer match -- intended only for a
    dry-run / pre-key bootstrap).

.OUTPUTS
    [int] 0 on success; non-zero on gate failure or a signing/IO error.
#>

[CmdletBinding()]
param(
    [string]$PrivateKeyPath,
    [string]$RepoRoot,
    [switch]$SkipSign,
    [switch]$SkipPins
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$installDir   = Join-Path $RepoRoot 'install'
$versionFile  = Join-Path $RepoRoot 'VERSION'
$sha256File   = Join-Path $installDir 'install.sha256'
$sigFile      = Join-Path $installDir 'install.sha256.sig'
$asciiGate    = Join-Path $RepoRoot 'test/Test-AsciiNoBom.ps1'

# The three bootstrap installers, repo-relative, in a stable order so the
# manifest is deterministic across runs.
$installers = @(
    'install/macos.utm.sh',
    'install/ubuntu.kvm.sh',
    'install/windows.hyper-v.ps1'
)

function Update-ReleasePin {
    # Repoint the pinned ref everywhere a fresh host reads it -- the three
    # installer branch defaults (main -> <Version>) and the install/README.md
    # one-liners + verified-path snippet (refs/heads/main, or an older
    # refs/tags/<calver>, -> refs/tags/<Version>). Idempotent: re-running with
    # the same Version is a no-op. The existing clone/checkout/pull logic
    # handles a CalVer tag transparently (detached checkout + no-op ff-only
    # pull), so no installer logic change is needed -- only this default flip.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version)
    $utf8   = [System.Text.UTF8Encoding]::new($false)
    $calver = '\d{4}\.\d{2}\.\d{2}'
    $edits = @(
        @{ file = 'install/ubuntu.kvm.sh';       pat = '(YURUNA_BRANCH:-)(main|' + $calver + ')(\})';          rep = '${1}' + $Version + '${3}' }
        @{ file = 'install/macos.utm.sh';        pat = '(YURUNA_BRANCH:-)(main|' + $calver + ')(\})';          rep = '${1}' + $Version + '${3}' }
        @{ file = 'install/windows.hyper-v.ps1'; pat = '(\$YurunaBranch\s*=\s*'')(main|' + $calver + ')('')';  rep = '${1}' + $Version + '${3}' }
        # Only the verified-path snippet (refs/tags/<calver>) is repinned; the
        # convenience one-liners deliberately stay on refs/heads/main (unverified
        # latest). The CLONE is what gets pinned, via the YURUNA_BRANCH defaults.
        @{ file = 'install/README.md';           pat = '(alissonsol/yuruna/)refs/tags/' + $calver; rep = '${1}refs/tags/' + $Version }
    )
    foreach ($e in $edits) {
        $p = Join-Path $Root $e.file
        if (-not (Test-Path -LiteralPath $p)) { throw "Pin target not found: $p" }
        $t = [System.IO.File]::ReadAllText($p)
        $n = [regex]::Replace($t, $e.pat, $e.rep)
        if ($n -ne $t) {
            if ($PSCmdlet.ShouldProcess($p, "pin release ref -> $Version")) {
                [System.IO.File]::WriteAllText($p, $n, $utf8)
                Write-Information "  pinned $($e.file) -> $Version" -InformationAction Continue
            }
        } else {
            Write-Information "  $($e.file): already at $Version (no change)" -InformationAction Continue
        }
    }
}

if (-not (Test-Path -LiteralPath $versionFile)) { throw "VERSION file not found at $versionFile" }
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^\d{4}\.\d{2}\.\d{2}$') {
    throw "VERSION '$version' is not bare CalVer (YYYY.MM.DD)."
}
Write-Information "Release version (from VERSION): $version" -InformationAction Continue

# --- Hard gate FIRST: a BOM/non-ASCII byte in a byte-parsed bootstrap script
# must never reach a published release. ---
if (Test-Path -LiteralPath $asciiGate) {
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $asciiGate -Quiet
    if ($LASTEXITCODE -ne 0) { throw "ASCII/no-BOM gate failed (test/Test-AsciiNoBom.ps1). Release aborted." }
    Write-Information "ASCII/no-BOM gate: PASS" -InformationAction Continue
} else {
    Write-Warning "Test-AsciiNoBom.ps1 not found at $asciiGate; ASCII gate SKIPPED."
}

# --- Pin the release ref (installer defaults + README one-liners/verified
# path). Run by default; -SkipPins regenerates the manifest without touching
# the refs. This is the step that flips `main` -> `refs/tags/<VERSION>` at the
# release, so the per-release work is just: bump VERSION, run this, cut the tag.
if (-not $SkipPins) {
    Write-Information "Pinning release refs to $version ..." -InformationAction Continue
    Update-ReleasePin -Root $RepoRoot -Version $version
} else {
    Write-Information "-SkipPins: installer/one-liner refs left unchanged." -InformationAction Continue
}

# --- Regenerate install.sha256 (lowercase hex, two-space GNU text format so
# `sha256sum -c install.sha256` works on the host). ---
$lines = foreach ($rel in $installers) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "Installer not found: $full" }
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    "$h  $rel"
}
$content = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText($sha256File, $content, [System.Text.UTF8Encoding]::new($false))
Write-Information "Wrote $sha256File ($($installers.Count) installers)" -InformationAction Continue

# --- Sign install.sha256 -> install.sha256.sig (detached PKCS#1 v1.5/SHA-256).
# openssl is the release-machine signer; the verify side uses openssl
# (macOS/Linux) or .NET RSACryptoServiceProvider (Windows PS 5.1). ---
if ($SkipSign) {
    Write-Warning "-SkipSign: install.sha256 regenerated but NOT signed; $sigFile is now stale."
    return 0
}
if (-not $PrivateKeyPath) { throw "-PrivateKeyPath is required to sign (or pass -SkipSign for a dry-run)." }
if (-not (Test-Path -LiteralPath $PrivateKeyPath)) { throw "Release private key not found at $PrivateKeyPath" }
$openssl = (Get-Command openssl -ErrorAction SilentlyContinue)?.Source
if (-not $openssl) {
    # On Windows the release machine often carries openssl only under Git for Windows.
    foreach ($c in @(
            "$env:ProgramFiles\Git\usr\bin\openssl.exe",
            "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
            "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")) {
        if (Test-Path -LiteralPath $c) { $openssl = $c; break }
    }
}
if (-not $openssl) { throw "openssl not found on PATH or under Git for Windows; required to sign the release manifest." }

& $openssl dgst -sha256 -sign $PrivateKeyPath -out $sigFile $sha256File
if ($LASTEXITCODE -ne 0) { throw "openssl signing failed (exit $LASTEXITCODE)." }

# Self-verify against the bundled public key so a release never ships a
# signature the verify path would reject.
$pubPem = Join-Path $installDir 'keys/yuruna-release-signing.pub.pem'
& $openssl dgst -sha256 -verify $pubPem -signature $sigFile $sha256File | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Self-verify FAILED: $sigFile does not verify against $pubPem." }
Write-Information "Signed + self-verified: $sigFile" -InformationAction Continue
return 0
