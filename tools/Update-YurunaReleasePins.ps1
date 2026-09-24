<#PSScriptInfo
.VERSION 2026.09.24
.GUID 428d9261-f6c4-49d0-94e9-7a19661cc048
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

    The ASCII/no-BOM gate (tools/Test-AsciiNoBom.ps1) runs FIRST and hard-fails
    the release if a byte-parsed bootstrap script carries a BOM or a non-ASCII
    byte -- the authoritative backstop the per-cycle gate and the pre-commit
    hook point at for the published artifact.

    It also repoints the one release pin that is still hard-coded -- the README
    verified-path snippet's signed-download URL -- to `refs/tags/<VERSION>`.
    The installers themselves carry no baked version: -PinVersion / PIN_VERSION
    reads the repo's VERSION file at install time, and the clone DEFAULT stays on
    the moving `main` branch so normal installs auto-update. The pin is rewritten
    by default; use -SkipPins to regenerate and gate the manifest without
    touching the ref.

.PARAMETER PrivateKeyPath
    Path to the release RSA private key (PEM). Read only at release time from a
    location the release owner supplies; never stored in the repo. The supplied
    key must match the public key bundled under install/keys/. Omit with
    -SkipSign to regenerate + gate without signing.

.PARAMETER RepoRoot
    Repo root. Defaults to the parent of this script's tools/ folder.

.PARAMETER SkipSign
    Regenerate install.sha256 and run the gate, but do not sign. The existing
    .sig is left untouched (and will no longer match -- intended only for a
    dry-run / pre-key bootstrap).

.PARAMETER SkipPins
    Leave the README verified-download ref unchanged while regenerating and
    signing the installer manifest. This is the repair path for manifest drift.

.PARAMETER Commit
    After signing, commit the release artifacts (VERSION, the three installers,
    install/README.md, install.sha256, install.sha256.sig) as "Release <VERSION>".
    Skipped if there is nothing to commit. Default off (prep only).

.PARAMETER Tag
    After committing, create the annotated git tag named EXACTLY <VERSION> -- the
    bare CalVer from the VERSION file, never typed by hand -- at HEAD. Refuses if
    a variant tag like v<VERSION> exists, if the release artifacts are still
    uncommitted, or if <VERSION> already points somewhere other than HEAD.
    Normally paired with -Commit (the run regenerates the manifest, so the tree
    must be committed before it can be tagged). Implied by -Push.

.PARAMETER Push
    Push the current branch (best-effort) and the <VERSION> tag to -Remote, then
    validate that refs/tags/<VERSION> resolves on the remote. That post-push
    check is what catches a missing or misnamed release tag at release time
    instead of on a fresh host. Implies -Tag.

.PARAMETER Remote
    Git remote for -Push and the post-push validation. Defaults to 'origin'.

.OUTPUTS
    [int] 0 on success; non-zero on gate failure or a signing/IO error.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PrivateKeyPath,
    [string]$RepoRoot,
    [switch]$SkipSign,
    [switch]$SkipPins,
    [switch]$Commit,
    [switch]$Tag,
    [switch]$Push,
    [string]$Remote = 'origin'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# -Push implies -Tag (you cannot validate a tag you did not create).
if ($Push) { $Tag = $true }
# A committed/tagged/pushed release must carry a fresh signature; refuse to
# publish a stale or unsigned manifest.
if ($SkipSign -and ($Commit -or $Tag)) {
    throw "-SkipSign cannot be combined with -Commit/-Tag/-Push: a published release must carry a fresh signature. Drop -SkipSign."
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$installDir   = Join-Path $RepoRoot 'install'
$versionFile  = Join-Path $RepoRoot 'VERSION'
$sha256File   = Join-Path $installDir 'install.sha256'
$sigFile      = Join-Path $installDir 'install.sha256.sig'
$pubPem       = Join-Path $installDir 'keys/yuruna-release-signing.pub.pem'
$asciiGate    = Join-Path $RepoRoot 'tools/Test-AsciiNoBom.ps1'

# The three bootstrap installers, repo-relative, in a stable order so the
# manifest is deterministic across runs.
$installers = @(
    'install/macos.utm.sh',
    'install/ubuntu.kvm.sh',
    'install/windows.hyper-v.ps1'
)

# --- REGION: Signing key preconditions
# These checks precede every write. Existence is not readability -- Test-Path
# only stats the inode, so a key whose permission bits carry no read bit passes
# it and then fails deep inside openssl. Name the mode as well: a key at 0600
# that picks up a stray digit (06000) keeps its owner but loses every rwx bit,
# and the openssl error alone does not say so. The cryptographic identity check
# happens against a disposable candidate below, before either live artifact is
# replaced.
$openssl = $null
if (-not $SkipSign) {
    if (-not $PrivateKeyPath) { throw "-PrivateKeyPath is required to sign (or pass -SkipSign for unsigned regeneration)." }
    if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
        throw "Release private key not found at $PrivateKeyPath"
    }
    try { [System.IO.File]::OpenRead($PrivateKeyPath).Dispose() }
    catch {
        $modeText = ''
        if (-not $IsWindows) {
            $mode = (Get-Item -LiteralPath $PrivateKeyPath).UnixFileMode
            if ($null -ne $mode) { $modeText = " (mode $([Convert]::ToString([int]$mode, 8)); a signing key needs 0600)" }
        }
        throw "Release private key at $PrivateKeyPath is not readable$modeText. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $pubPem -PathType Leaf)) {
        throw "Bundled release public key not found at $pubPem"
    }
    $openssl = (Get-Command openssl -ErrorAction SilentlyContinue)?.Source
    if (-not $openssl) {
        # On Windows the release machine often carries openssl only under Git for Windows.
        foreach ($c in @(
                "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
                "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")) {
            if (Test-Path -LiteralPath $c -PathType Leaf) { $openssl = $c; break }
        }
    }
    if (-not $openssl) {
        throw "openssl not found on PATH or under Git for Windows; required to sign the release manifest."
    }
}

# --- REGION: Publish-VerifiedManifestPair
function Publish-VerifiedManifestPair {
    <#
    .SYNOPSIS
        Replace a verified manifest/signature pair and restore both on error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidateManifest,
        [Parameter(Mandatory)][string]$CandidateSignature,
        [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$Signature,
        [Parameter(DontShow)][scriptblock]$MoveFile = {
            param([string]$Source, [string]$Destination)
            [IO.File]::Move($Source, $Destination, $true)
        }
    )

    # The candidates and backups share the target directory. That keeps each
    # rename on one volume; the rollback closes the unavoidable gap between the
    # two filesystem operations if the second replacement fails.
    $token = [Guid]::NewGuid().ToString('N')
    $manifestBackup = Join-Path (Split-Path -Parent $Manifest) ".install.sha256.$token.backup"
    $signatureBackup = Join-Path (Split-Path -Parent $Signature) ".install.sha256.sig.$token.backup"
    $hadManifest = [IO.File]::Exists($Manifest)
    $hadSignature = [IO.File]::Exists($Signature)
    $preserveBackups = $false

    try {
        if ($hadManifest) { [IO.File]::Copy($Manifest, $manifestBackup, $false) }
        if ($hadSignature) { [IO.File]::Copy($Signature, $signatureBackup, $false) }
    } catch {
        [IO.File]::Delete($manifestBackup)
        [IO.File]::Delete($signatureBackup)
        throw "Could not stage installer-manifest rollback copies; the live pair was not replaced. $($_.Exception.Message)"
    }

    try {
        & $MoveFile $CandidateManifest $Manifest
        & $MoveFile $CandidateSignature $Signature
    } catch {
        $publishError = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        foreach ($item in @(
                @{ Had = $hadSignature; Backup = $signatureBackup; Live = $Signature },
                @{ Had = $hadManifest; Backup = $manifestBackup; Live = $Manifest })) {
            try {
                if ($item.Had) {
                    & $MoveFile $item.Backup $item.Live
                } else {
                    [IO.File]::Delete($item.Live)
                }
            } catch {
                $rollbackErrors.Add("$($item.Live): $($_.Exception.Message)")
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            $preserveBackups = $true
            $retained = @(@($manifestBackup, $signatureBackup) |
                    Where-Object { [IO.File]::Exists($_) })
            $recovery = if ($retained.Count) {
                "Recovery copies retained at: $($retained -join ', ')"
            } else {
                'No rollback copy survived; preserve the live files for manual recovery.'
            }
            throw "Publishing the verified installer-manifest pair failed ($publishError), and rollback also failed: $($rollbackErrors -join '; '). $recovery"
        }
        throw "Publishing the verified installer-manifest pair failed; the original pair was restored. $publishError"
    } finally {
        foreach ($path in @($CandidateManifest, $CandidateSignature)) {
            [IO.File]::Delete($path)
        }
        if (-not $preserveBackups) {
            [IO.File]::Delete($manifestBackup)
            [IO.File]::Delete($signatureBackup)
        }
    }
}

function Update-ReleasePin {
    # Repoint the install/README.md verified-path snippet (the signed-download
    # URL) from refs/tags/<calver> to refs/tags/<Version>. The installers do NOT
    # carry a baked version: -PinVersion / PIN_VERSION reads the repo's VERSION
    # file at install time, and the clone DEFAULT stays on the moving 'main'
    # branch -- so a release never re-pins a fresh install and there is nothing
    # to rewrite in the three installer scripts. Idempotent: re-running with the
    # same Version is a no-op.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version)
    $utf8   = [System.Text.UTF8Encoding]::new($false)
    $calver = '\d{4}\.\d{2}\.\d{2}(?:\.\d+)?'
    $edits = @(
        # Only the README verified-path snippet hard-codes a tag in its
        # signed-download URL; the convenience one-liners deliberately stay on
        # refs/heads/main (unverified latest).
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
if ($version -notmatch '^\d{4}\.\d{2}\.\d{2}(\.\d+)?$') {
    throw "VERSION '$version' is not bare CalVer (YYYY.MM.DD or YYYY.MM.DD.N)."
}
Write-Information "Release version (from VERSION): $version" -InformationAction Continue

# --- REGION: ASCII/no-BOM hard gate
# Runs FIRST: a BOM/non-ASCII byte in a byte-parsed bootstrap script must
# never reach a published release.
if (Test-Path -LiteralPath $asciiGate) {
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $asciiGate -Quiet
    if ($LASTEXITCODE -ne 0) { throw "ASCII/no-BOM gate failed (tools/Test-AsciiNoBom.ps1). Release aborted." }
    Write-Information "ASCII/no-BOM gate: PASS" -InformationAction Continue
} else {
    Write-Warning "Test-AsciiNoBom.ps1 not found at $asciiGate; ASCII gate SKIPPED."
}

# --- REGION: Build install.sha256 candidate
# Lowercase hex, two-space GNU text format so `sha256sum -c install.sha256`
# works on the host.
$lines = foreach ($rel in $installers) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "Installer not found: $full" }
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    "$h  $rel"
}
$content = ($lines -join "`n") + "`n"

$releaseActions = @('replace install/install.sha256')
if (-not $SkipSign) { $releaseActions += 'replace its verified detached signature' }
if (-not $SkipPins) { $releaseActions += "pin the verified-download ref to $version" }
if ($Commit) { $releaseActions += 'commit the release artifacts' }
if ($Tag) { $releaseActions += "create or validate tag $version" }
if ($Push) { $releaseActions += "push and validate tag $version on $Remote" }
if (-not $PSCmdlet.ShouldProcess($RepoRoot, ($releaseActions -join ', '))) {
    return 0
}

$utf8 = [Text.UTF8Encoding]::new($false)
$candidateToken = [Guid]::NewGuid().ToString('N')
$candidateManifest = Join-Path $installDir ".install.sha256.$candidateToken.candidate"
$candidateSignature = Join-Path $installDir ".install.sha256.sig.$candidateToken.candidate"

try {
    [IO.File]::WriteAllText($candidateManifest, $content, $utf8)

    # --- REGION: Sign and verify the disposable candidate pair
    # Detached PKCS#1 v1.5/SHA-256. The signature is verified against the
    # bundled public key while both files still have disposable names. A wrong
    # key, invalid key, openssl failure, or verification failure therefore
    # leaves the live pair byte-for-byte unchanged.
    if (-not $SkipSign) {
        $signOutput = @(& $openssl dgst -sha256 -sign $PrivateKeyPath -out $candidateSignature $candidateManifest 2>&1)
        $signExit = $LASTEXITCODE
        if ($signExit -ne 0) {
            throw "openssl signing the candidate manifest failed (exit $signExit): $($signOutput -join ' ')"
        }

        $verifyOutput = @(& $openssl dgst -sha256 -verify $pubPem -signature $candidateSignature $candidateManifest 2>&1)
        $verifyExit = $LASTEXITCODE
        if ($verifyExit -ne 0) {
            throw "The supplied release private key does not match the bundled public key at $pubPem; candidate self-verify failed (openssl exit $verifyExit): $($verifyOutput -join ' ')"
        }
    }

    # --- REGION: Pin the README verified-download path to the release tag
    # Candidate signing happens first so a bad key cannot leave a pin edit
    # behind. -SkipPins is the narrow repair path that touches only the signed
    # manifest pair. See the Update-ReleasePin preamble for why only the README
    # needs repinning.
    if (-not $SkipPins) {
        Write-Information "Pinning release refs to $version ..." -InformationAction Continue
        Update-ReleasePin -Root $RepoRoot -Version $version -Confirm:$false
    } else {
        Write-Information "-SkipPins: installer/one-liner refs left unchanged." -InformationAction Continue
    }

    # --- REGION: Publish verified artifacts
    if ($SkipSign) {
        [IO.File]::Move($candidateManifest, $sha256File, $true)
        Write-Information "Wrote $sha256File ($($installers.Count) installers)" -InformationAction Continue
        Write-Warning "-SkipSign: install.sha256 regenerated but NOT signed; $sigFile is now stale."
    } else {
        Publish-VerifiedManifestPair -CandidateManifest $candidateManifest `
            -CandidateSignature $candidateSignature -Manifest $sha256File -Signature $sigFile
        Write-Information "Wrote $sha256File ($($installers.Count) installers)" -InformationAction Continue
        Write-Information "Signed + self-verified: $sigFile" -InformationAction Continue
    }
} finally {
    # Candidate cleanup is idempotent: a successful publish moved the files;
    # every failure path deletes whatever openssl managed to create.
    [IO.File]::Delete($candidateManifest)
    [IO.File]::Delete($candidateSignature)
}

# --- REGION: Publish: commit, tag, push, validate (all opt-in)
# Slip-proofing for the release tag. The tag name is ALWAYS the bare CalVer
# read+validated from VERSION, never typed by hand -- guards against the
# v-prefixed-tag regression class (a 'v' tag while every installer pins the
# bare CalVer). -Commit/-Tag/-Push are opt-in; with none set the script only
# preps the manifest. -Push implies -Tag (set near the top).
if ($Commit -or $Tag -or $Push) {
    $git = (Get-Command git -ErrorAction SilentlyContinue)?.Source
    if (-not $git) { throw "git not found on PATH; required for -Commit/-Tag/-Push." }

    function Invoke-GitChecked {
        param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$AllowFail)
        $out = & $git -C $RepoRoot @GitArgs 2>&1
        if ($out) { $out | ForEach-Object { Write-Information "    git: $_" -InformationAction Continue } }
        if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
            throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)."
        }
        return $LASTEXITCODE
    }

    $releaseFiles = @('VERSION') + $installers + @(
        'install/README.md',
        'install/install.sha256',
        'install/install.sha256.sig'
    )

    # --- REGION: Commit
    if ($Commit) {
        Write-Information "Committing release artifacts for $version" -InformationAction Continue
        foreach ($rel in $releaseFiles) {
            if (Test-Path -LiteralPath (Join-Path $RepoRoot $rel)) {
                Invoke-GitChecked -GitArgs @('add', '--', $rel) | Out-Null
            }
        }
        if ((Invoke-GitChecked -GitArgs @('diff', '--cached', '--quiet') -AllowFail) -eq 0) {
            Write-Information "  nothing to commit (release artifacts already committed)." -InformationAction Continue
        } else {
            Invoke-GitChecked -GitArgs @('commit', '-m', "Release $version") | Out-Null
            Write-Information "  committed: Release $version" -InformationAction Continue
        }
    }

    # --- REGION: Tag
    if ($Tag) {
        # Guard 1: never allow a variant tag (e.g. v<version>). One bare-CalVer
        # tag per release is the invariant every installer ref resolver assumes.
        if ((Invoke-GitChecked -GitArgs @('rev-parse', '--verify', '--quiet', "refs/tags/v$version") -AllowFail) -eq 0) {
            throw "A variant tag 'v$version' exists. Releases use the bare CalVer tag '$version'. Remove the variant first: git tag -d v$version ; git push $Remote :refs/tags/v$version"
        }

        # Guard 2: the release artifacts must be committed, or HEAD would be
        # tagged WITHOUT the signed manifest. (-Commit above satisfies this.)
        foreach ($rel in $releaseFiles) {
            $relStatus = & $git -C $RepoRoot status --porcelain -- $rel 2>$null
            if ($relStatus) {
                throw "Release artifact '$rel' has uncommitted changes; tagging now would tag a commit without the signed manifest. Re-run with -Commit (or commit the artifacts), then tag."
            }
        }

        $head = (& $git -C $RepoRoot rev-parse HEAD).Trim()
        $existing = & $git -C $RepoRoot rev-parse --verify --quiet "refs/tags/$version^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $existing) {
            if ($existing.Trim() -eq $head) {
                Write-Information "Tag '$version' already at HEAD ($head) -- leaving as-is." -InformationAction Continue
            } else {
                throw "Tag '$version' already exists at $($existing.Trim()), not HEAD ($head). Refusing to move a published tag."
            }
        } else {
            Write-Information "Creating annotated tag '$version' at HEAD ($head)" -InformationAction Continue
            Invoke-GitChecked -GitArgs @('tag', '-a', $version, '-m', "Release $version") | Out-Null
        }
    }

    # --- REGION: Push + validate
    if ($Push) {
        $branch = (& $git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
        if ($branch -and $branch -ne 'HEAD') {
            Write-Information "Pushing branch '$branch' to $Remote" -InformationAction Continue
            if ((Invoke-GitChecked -GitArgs @('push', $Remote, $branch) -AllowFail) -ne 0) {
                Write-Warning "  branch push rejected (e.g. a protected main requiring a PR). The tag is still pushed + validated; land the branch via PR."
            }
        }
        Write-Information "Pushing tag '$version' to $Remote" -InformationAction Continue
        Invoke-GitChecked -GitArgs @('push', $Remote, "refs/tags/$version") | Out-Null
        if ((Invoke-GitChecked -GitArgs @('ls-remote', '--exit-code', '--tags', $Remote, $version) -AllowFail) -ne 0) {
            throw "Post-push validation FAILED: refs/tags/$version does not resolve on $Remote."
        }
        Write-Information "Validated: refs/tags/$version resolves on $Remote." -InformationAction Continue
    }
}

return 0
