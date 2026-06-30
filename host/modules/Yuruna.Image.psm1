<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42de9c8b-f7a6-4b34-9182-3c4d5e6f7ab7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna image checksum download integrity
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
    General image-download integrity gateway. Generalizes the warn-only
    SHA-256 verification pattern Yuruna.UbuntuImage.psm1 ships for the
    Ubuntu live-server ISOs.

.DESCRIPTION
    The Ubuntu ISO pipeline runs through a warn-only checksum policy.
    The other guest-image sources (Windows ISO, Amazon Linux 2023
    qcow2, caching-proxy base, macOS images) reach disk through
    `Save-CachedHttpUri` + `Invoke-WebRequest` without going through
    any shared integrity layer; a supply-chain incident on any of
    those mirrors would land silently.

    Save-ImageWithChecksum is the single chokepoint:

      1. Download the image to a destination path. Routes through
         the host's `Save-CachedHttpUri` when available (squid bump
         + per-process custom CA trust) and falls back to a direct
         Invoke-WebRequest.
      2. Compute SHA-256 over the downloaded file.
      3. Compare against an expected hash. The expected hash can
         come from -ExpectedSha256 directly OR by parsing a published
         checksum file at -ChecksumUrl with -ChecksumPattern (defaults
         to the conventional `<sha256>  <filename>` shape used by
         the cloud-images mirrors).
      4. POLICY (matches the Ubuntu-ISO policy):
           - hash match    -> silent pass, return $true
           - hash mismatch -> emit a visual banner Write-Warning,
                              continue (caller keeps the file)
           - no checksum   -> silent pass, return $true (publisher
                              didn't supply one; not Yuruna's call
                              to block on that)

    Caller can flip strictness via -OnMismatch:
       'WarnAndContinue'  (default)  warn + keep the file
       'WarnAndDelete'                emit banner + delete the file
       'Throw'                        emit banner + throw an exception

    Designed to be the migration target for the AL2023 / Windows /
    caching-proxy / macOS Get-Image.ps1 scripts. The Ubuntu path
    keeps using Yuruna.UbuntuImage (which has the codename resolver
    on top); this gateway covers everything else.
#>

# Conventional checksum-file pattern. The cloud-images / releases.ubuntu.com /
# Microsoft Eval Center distributions all publish SHA256SUMS files in the
# `<sha256>  <filename>` shape (two spaces). Override -ChecksumPattern to
# match a different mirror layout.
$script:DefaultChecksumPattern = '^([0-9a-fA-F]{64})\s+\*?{0}\s*$'

# Pinned PRIMARY-key fingerprints that sign Ubuntu's published SHA256SUMS:
# the CD Image key signs the ISO mirrors (releases.ubuntu.com / cdimage),
# the UEC Image key signs the cloud images; cloud-images.ubuntu.com is
# dual-signed by both. These are the trust anchor for the best-effort GPG
# authentication in Test-PublishedChecksumSignature. Refresh on an Ubuntu
# signing-key rotation: verify a fresh SHA256SUMS.gpg with `gpg --verify` and
# update the fingerprints here (same discipline as the usbmmidd SHA-256 pin).
$script:UbuntuImageSignerFingerprint = @(
    '843938DF228D22F7B3742BC0D94AA3F0EFE21092'  # Ubuntu CD Image Automatic Signing Key (2012)
    'D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81'  # UEC Image Automatic Signing Key
)

function Get-ImageChecksumLine {
    <#
    .SYNOPSIS
        Pull the SHA-256 line for a target filename out of a published
        checksum file. Returns the hex hash, or $null when not found.
    .PARAMETER ChecksumUrl
        URL of the SHA256SUMS-style file.
    .PARAMETER TargetFileName
        Filename to match. Embedded into the regex as a literal.
    .PARAMETER Pattern
        Regex with the literal token {0} marking where the escaped
        filename goes. {0} is substituted literally (NOT via -f), so
        regex quantifiers like {64} in the pattern are safe. Default
        works for the cloud-images / Ubuntu releases layout.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$TargetFileName,
        [string]$Pattern = $script:DefaultChecksumPattern
    )
    $body = $null
    try {
        $body = (Invoke-WebRequest -Uri $ChecksumUrl -ErrorAction Stop).Content
    } catch {
        Write-Verbose "Get-ImageChecksumLine: fetch failed at $ChecksumUrl : $($_.Exception.Message)"
        return $null
    }
    if (-not $body) { return $null }
    $escaped = [regex]::Escape($TargetFileName)
    # Substitute the filename token literally, NOT via -f: the pattern
    # carries regex quantifiers like {64}, which the -f operator misreads
    # as format placeholders (throwing "Index ... less than the size of
    # the argument list" and leaving $rx null). .Replace leaves every
    # other brace untouched so the quantifier survives into the regex.
    $rx = [regex]::new($Pattern.Replace('{0}', $escaped), 'Multiline')
    $m = $rx.Match($body)
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Test-PublishedChecksumSignature {
    <#
    .SYNOPSIS
        Best-effort detached-GPG authentication of a published SHA256SUMS
        file against a pinned set of signing-key fingerprints.
    .DESCRIPTION
        Authenticates the SHA256SUMS that the hash check trusts. GPG is a
        BONUS here, never a hard dependency, so a missing tool, a missing
        signature, or an unreachable keyserver can NEVER brick a download --
        those degrade to 'unverified' and the caller proceeds on the hash
        alone. Only a signature that is present, checkable, and definitively
        wrong returns 'bad'.

          'unverified' - gpg absent, no detached .gpg published / fetch failed,
                         keyserver unreachable, or the pinned key can't be
                         obtained. Caller proceeds on the hash (with a warning).
          'bad'        - signature present + key available but BAD, or a good
                         signature from a key OUTSIDE the pinned set (tamper).
          'good'       - a valid signature from a pinned key.

        The pinned public keys are imported from a repo-bundled keyring into a
        throwaway homedir (offline; no dirmngr/keyserver, which is unreliable
        under a custom --homedir on Windows). The pinned FINGERPRINT set is the
        trust anchor: a signature counts as 'good' only when VALIDSIG names one
        of the pinned fingerprints, so swapping the bundled key file alone
        cannot pass verification.
    .OUTPUTS
        [string] 'good' | 'bad' | 'unverified'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [string]$SignatureUrl,
        [string[]]$AllowedFingerprint = $script:UbuntuImageSignerFingerprint,
        [string]$KeyringPath = (Join-Path $PSScriptRoot 'keys/ubuntu-image-signing-keys.asc')
    )
    $gpgCmd = Get-Command gpg -ErrorAction SilentlyContinue
    if (-not $gpgCmd) { return 'unverified' }
    if (-not (Test-Path -LiteralPath $KeyringPath)) { return 'unverified' }
    if (-not $SignatureUrl) { $SignatureUrl = "$ChecksumUrl.gpg" }
    $allow = @($AllowedFingerprint | ForEach-Object { ($_ -replace '\s', '').ToUpperInvariant() })
    if ($allow.Count -eq 0) { return 'unverified' }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-gpg-' + [Guid]::NewGuid().ToString('N'))
    $sumsFile = Join-Path $work 'SHA256SUMS'
    $sigFile  = Join-Path $work 'SHA256SUMS.gpg'
    try {
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
        try {
            Invoke-WebRequest -Uri $ChecksumUrl  -OutFile $sumsFile -ErrorAction Stop
            Invoke-WebRequest -Uri $SignatureUrl -OutFile $sigFile  -ErrorAction Stop
        } catch {
            return 'unverified'
        }
        # Import the bundled pinned public keys into the throwaway keyring
        # (offline -- no dirmngr/keyserver, which is unreliable under a custom
        # --homedir on Windows). The pinned fingerprint set is still the trust
        # anchor: a signature is 'good' only if VALIDSIG names a pinned fpr.
        & $gpgCmd.Source --homedir $work --batch --quiet --import $KeyringPath 2>$null
        $status = & $gpgCmd.Source --homedir $work --batch --status-fd 1 --verify $sigFile $sumsFile 2>$null
        if ($status | Where-Object { $_ -match '^\[GNUPG:\] BADSIG ' }) { return 'bad' }
        # VALIDSIG carries the signing-key fpr and (last field) the primary-key
        # fpr; collect every 40-hex token so a subkey signature still matches
        # via its primary, and intersect with the pinned set.
        $validFprs = @($status |
            Where-Object { $_ -match '^\[GNUPG:\] VALIDSIG ' } |
            ForEach-Object { [regex]::Matches($_, '[0-9A-Fa-f]{40}') } |
            ForEach-Object { $_.Value.ToUpperInvariant() })
        if ($validFprs.Count -eq 0) { return 'unverified' }
        foreach ($f in $allow) { if ($validFprs -contains $f) { return 'good' } }
        return 'bad'
    } catch {
        return 'unverified'
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Save-ImageWithChecksum {
    <#
    .SYNOPSIS
        Download an image to disk, optionally verify SHA-256 against a
        publisher checksum source, warn loudly on mismatch (default
        policy: keep the file and continue).
    .PARAMETER SourceUrl
        HTTP(S) URL of the image to download.
    .PARAMETER DestPath
        Local destination path. Parent directory created if absent.
    .PARAMETER ExpectedSha256
        Pre-computed SHA-256 (64 hex chars). Skips ChecksumUrl lookup
        when provided.
    .PARAMETER ChecksumUrl
        URL of a publisher SHA256SUMS file to parse. Only consulted
        when ExpectedSha256 is not provided.
    .PARAMETER ChecksumTargetFileName
        Filename to match inside the SHA256SUMS body. Defaults to
        the basename of SourceUrl.
    .PARAMETER ChecksumPattern
        Format-string regex; {0} is replaced by the escaped target
        filename. Defaults to the cloud-images / Ubuntu format.
    .PARAMETER OnMismatch
        Policy when computed hash != expected hash:
          - 'WarnAndContinue'  (default) emit banner, return $true
          - 'WarnAndDelete'    emit banner, delete file, return $false
          - 'Throw'            emit banner, throw an exception
    .PARAMETER VerifyUbuntuSignature
        When set and a -ChecksumUrl is used, best-effort authenticate the
        published SHA256SUMS via its detached GPG signature against the pinned
        Ubuntu signing keys (Test-PublishedChecksumSignature) before trusting
        the hash. A definitively bad/foreign signature is treated like a
        mismatch (subject to -OnMismatch); gpg/keyserver/signature-absent
        degrades to a warning and proceeds on the hash.
    .OUTPUTS
        [bool] $true when the download landed successfully (regardless
        of checksum outcome under WarnAndContinue); $false when the
        download itself failed or WarnAndDelete fired.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$DestPath,
        [string]$ExpectedSha256,
        [string]$ChecksumUrl,
        [string]$ChecksumTargetFileName,
        [string]$ChecksumPattern = $script:DefaultChecksumPattern,
        [ValidateSet('WarnAndContinue','WarnAndDelete','Throw')]
        [string]$OnMismatch = 'WarnAndContinue',
        [switch]$VerifyUbuntuSignature
    )
    if (-not $PSCmdlet.ShouldProcess($DestPath, "Download $SourceUrl with checksum policy $OnMismatch")) { return $true }
    $destDir = Split-Path -Parent $DestPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
    }
    Write-Information "Downloading $SourceUrl -> $DestPath" -InformationAction Continue
    try {
        if (Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue) {
            Save-CachedHttpUri -Uri $SourceUrl -OutFile $DestPath
        } else {
            Invoke-WebRequest -Uri $SourceUrl -OutFile $DestPath -ErrorAction Stop
        }
    } catch {
        Write-Warning "Save-ImageWithChecksum: download failed for $SourceUrl : $($_.Exception.Message)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $DestPath)) {
        Write-Warning "Save-ImageWithChecksum: download reported success but $DestPath is missing."
        return $false
    }
    $expected = $ExpectedSha256
    if (-not $expected -and $ChecksumUrl) {
        $targetName = if ($ChecksumTargetFileName) { $ChecksumTargetFileName } else { Split-Path -Leaf $SourceUrl }
        $expected = Get-ImageChecksumLine -ChecksumUrl $ChecksumUrl -TargetFileName $targetName -Pattern $ChecksumPattern
        if (-not $expected) {
            Write-Warning "Save-ImageWithChecksum: no checksum entry for '$targetName' at $ChecksumUrl ; accepting without verification (policy)."
            return $true
        }
    }
    if (-not $expected) {
        # No checksum source supplied at all -- caller chose to download
        # without integrity check. Same accepting-policy as missing-entry.
        return $true
    }
    if ($VerifyUbuntuSignature -and $ChecksumUrl) {
        switch (Test-PublishedChecksumSignature -ChecksumUrl $ChecksumUrl) {
            'good'       { Write-Information "  SHA256SUMS GPG signature OK (pinned Ubuntu key)" -InformationAction Continue }
            'unverified' { Write-Warning "Save-ImageWithChecksum: SHA256SUMS signature unverified (gpg/keyserver unavailable or no detached .gpg); proceeding on hash only." }
            'bad'        {
                Write-Warning ('=' * 72)
                Write-Warning "  SHA256SUMS GPG SIGNATURE INVALID"
                Write-Warning "  Checksum : $ChecksumUrl"
                Write-Warning "  The published checksum file failed signature verification against"
                Write-Warning "  the pinned Ubuntu signing keys -- treating the source as tampered."
                Write-Warning "  Policy   : $OnMismatch"
                Write-Warning ('=' * 72)
                switch ($OnMismatch) {
                    'WarnAndContinue' { }
                    'WarnAndDelete'   { Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue; return $false }
                    'Throw'           { throw "SHA256SUMS GPG signature invalid for $ChecksumUrl" }
                }
            }
        }
    }
    Write-Information "Verifying SHA-256 against publisher checksum..." -InformationAction Continue
    $actual = (Get-FileHash -Path $DestPath -Algorithm SHA256).Hash
    if ($actual -ieq $expected) {
        Write-Information "  checksum OK ($actual)" -InformationAction Continue
        return $true
    }
    Write-Warning ('=' * 72)
    Write-Warning "  IMAGE CHECKSUM MISMATCH"
    Write-Warning "  File     : $DestPath"
    Write-Warning "  Source   : $SourceUrl"
    Write-Warning "  Expected : $expected"
    Write-Warning "  Actual   : $actual"
    if ($ChecksumUrl)   { Write-Warning "  Checksum : $ChecksumUrl" }
    Write-Warning "  Policy   : $OnMismatch"
    Write-Warning ('=' * 72)
    switch ($OnMismatch) {
        'WarnAndContinue' { return $true }
        'WarnAndDelete'   {
            Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        'Throw'           { throw "Image checksum mismatch for $DestPath (expected $expected, got $actual)" }
    }
}

function Convert-Qcow2ToVhdx {
    <#
    .SYNOPSIS
        Convert a qcow2/.img cloud image to a dynamic VHDX for Hyper-V and
        resize it, clearing the NTFS sparse flag qemu-img leaves behind.
    .DESCRIPTION
        Hyper-V boots VHDX; the Ubuntu / AL cloud images ship qcow2. qemu-img
        on Windows writes the VHDX through NTFS sparse files, leaving
        FILE_ATTRIBUTE_SPARSE_FILE set so Resize-VHD then fails with
        0xC03A001A ("must not be sparse") -- see feedback_qemu_img_vhdx_sparse.md.
        This clears the flag, then resizes via Resize-VHD with a qemu-img
        fallback. A resize failure is non-fatal (warned); a convert failure
        cleans up the partial DestPath and returns $false. Native qemu-img
        output is captured (never emitted) so it cannot pollute the [bool]
        return.
    .OUTPUTS
        [bool] $true when the convert succeeded (DestPath is a usable VHDX),
        $false when qemu-img is missing or the convert failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][long]$SizeBytes
    )
    $qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue
    if (-not $qemuImg) {
        foreach ($c in @("$env:ProgramFiles\qemu\qemu-img.exe", "${env:ProgramFiles(x86)}\qemu\qemu-img.exe")) {
            if (Test-Path $c) { $qemuImg = $c; break }
        }
    }
    if (-not $qemuImg) {
        Write-Warning "qemu-img not found. Install QEMU for Windows (winget install SoftwareFreedomConservancy.QEMU) or add qemu-img to PATH."
        return $false
    }
    Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
    Write-Information "Converting qcow2 to VHDX..." -InformationAction Continue
    $convertOut = & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $SourcePath $DestPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "qemu-img convert failed (exit $LASTEXITCODE): $convertOut"
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    # Clear the NTFS sparse flag qemu-img leaves set, else Resize-VHD fails
    # with 0xC03A001A. See feedback_qemu_img_vhdx_sparse.md.
    & fsutil sparse setflag $DestPath 0 2>&1 | Out-Null
    # See https://yuruna.link/memory#why-cache-vhdx-uses-resize-vhd-instead-of-qemu-img-resize
    $sizeGb = [math]::Round($SizeBytes / 1GB)
    Write-Information "Resizing VHDX to ${sizeGb}GB..." -InformationAction Continue
    $resized = $false
    try {
        Resize-VHD -Path $DestPath -SizeBytes $SizeBytes -ErrorAction Stop
        $resized = $true
    } catch {
        Write-Warning "Resize-VHD failed: $($_.Exception.Message); falling back to qemu-img resize."
        $resizeOut = & $qemuImg resize $DestPath "${sizeGb}G" 2>&1
        if ($LASTEXITCODE -eq 0) { $resized = $true } else { Write-Warning "qemu-img resize failed: $resizeOut" }
    }
    if (-not $resized) {
        Write-Warning "VHDX resize failed via both Resize-VHD and qemu-img; the VM will have only the base cloud-image capacity."
        Write-Warning "Resize manually: fsutil sparse setflag '$DestPath' 0; Resize-VHD -Path '$DestPath' -SizeBytes $SizeBytes"
    }
    return $true
}

Export-ModuleMember -Function Save-ImageWithChecksum, Get-ImageChecksumLine, Convert-Qcow2ToVhdx, Test-PublishedChecksumSignature
