<#PSScriptInfo
.VERSION 2026.05.29
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
        Format-string regex with {0} replaced by the escaped filename.
        Default works for the cloud-images / Ubuntu releases layout.
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
    $rx = [regex]::new(($Pattern -f $escaped), 'Multiline')
    $m = $rx.Match($body)
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
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
        [string]$OnMismatch = 'WarnAndContinue'
    )
    if (-not $PSCmdlet.ShouldProcess($DestPath, "Download $SourceUrl with checksum policy $OnMismatch")) { return $true }
    $destDir = Split-Path -Parent $DestPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
    }
    Write-Output "Downloading $SourceUrl -> $DestPath"
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
    Write-Output "Verifying SHA-256 against publisher checksum..."
    $actual = (Get-FileHash -Path $DestPath -Algorithm SHA256).Hash
    if ($actual -ieq $expected) {
        Write-Output "  checksum OK ($actual)"
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

Export-ModuleMember -Function Save-ImageWithChecksum, Get-ImageChecksumLine
