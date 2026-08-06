<#PSScriptInfo
.VERSION 2026.08.06
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
    qcow2, caching-proxy-service base, macOS images) reach disk through
    `Save-CachedHttpUri` + `Invoke-WebRequest` with no shared integrity
    layer, so a supply-chain incident on those mirrors would land
    silently.

    Save-ImageWithChecksum is the single chokepoint:

      1. Download to a destination path, through the host's
         `Save-CachedHttpUri` when available (squid bump + per-process
         custom CA trust), else a direct Invoke-WebRequest.
      2. Compute SHA-256 over the downloaded file.
      3. Compare against an expected hash, supplied by -ExpectedSha256
         or parsed from a published checksum file at -ChecksumUrl with
         -ChecksumPattern (defaults to the conventional
         `<sha256>  <filename>` shape the cloud-images mirrors use).
      4. POLICY (matches the Ubuntu-ISO policy). Four outcomes, four
         decisions, every default permissive so a caller that does not
         opt in keeps the behaviour it was written against:
           - hash match          -> silent pass, return $true
           - hash mismatch       -> -OnMismatch
           - publisher lists no
             entry, or no
             checksum source     -> -OnMissingChecksum
           - checksum file
             unreachable         -> -OnUnreachableChecksum

    Keeping those three failure modes apart is the point: "the mirror
    publishes no hash for this file" and "we never reached the mirror"
    are different facts, and one of them is not the publisher's doing.

    -OnMismatch and its siblings flip that strictness; see their
    parameter help.

    Designed to be the migration target for the AL2023 / Windows /
    caching-proxy-service / macOS Get-Image.ps1 scripts. The Ubuntu path
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

function ConvertTo-ChecksumText {
    <#
    .SYNOPSIS
        Decode a published checksum body into text a regex can match.
    .DESCRIPTION
        cloud-images.ubuntu.com and releases.ubuntu.com serve SHA256SUMS with
        NO Content-Type header, so Invoke-WebRequest cannot infer text and
        hands `.Content` back as System.Byte[]; a retry wrapper that pipes that
        array unrolls it further into an object[] of individual bytes. Both
        shapes coerce to a string as the space-joined DECIMAL value of every
        byte -- a body no checksum pattern can ever match, which reads
        downstream as "the publisher lists no entry for this file". Decode by
        inspecting the type; never rely on the content-type guess.
    .OUTPUTS
        [string] UTF-8 text with any byte-order mark removed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()]$Content)
    if ($null -eq $Content) { return '' }
    $text = ''
    if ($Content -is [byte[]]) {
        $text = [System.Text.Encoding]::UTF8.GetString($Content)
    } elseif ($Content -is [string]) {
        $text = $Content
    } elseif ($Content -is [System.Collections.IEnumerable]) {
        $items = @($Content)
        if ($items.Count -gt 0 -and $items[0] -is [byte]) {
            try { $text = [System.Text.Encoding]::UTF8.GetString([byte[]]$items) }
            catch { $text = ($items | ForEach-Object { [string]$_ }) -join "`n" }
        } else {
            $text = ($items | ForEach-Object { [string]$_ }) -join "`n"
        }
    } else {
        $text = [string]$Content
    }
    return $text.TrimStart([char]0xFEFF)
}

function Get-ChecksumHttpStatus {
    <#
    .SYNOPSIS
        HTTP status code carried by a failed checksum fetch, 0 when unknown.
    .DESCRIPTION
        Invoke-WebRequest raises an exception carrying the .Response to read
        the code from. The squid SSL-bump path does not: it drives HttpClient
        directly and throws a plain message, so there the code survives only in
        the text. Reading both is what keeps a 404 arriving through the cache
        classified as "the mirror does not publish this" instead of blaming the
        network.
    .OUTPUTS
        [int] status code, or 0 when none could be read.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()]$ErrorRecord)
    if (-not $ErrorRecord) { return 0 }
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    } catch { $null = $_ }
    $message = ''
    try { $message = [string]$ErrorRecord.Exception.Message } catch { $message = '' }
    if ($message -match '\bHTTP\s+(\d{3})\b') { return [int]$Matches[1] }
    return 0
}

function Get-PublishedChecksumBody {
    <#
    .SYNOPSIS
        Fetch a published SHA256SUMS-style file to disk once and return its
        decoded text with the outcome classified.
    .DESCRIPTION
        The body lands on DISK rather than arriving through `.Content`, so one
        artifact serves both consumers: the detached-GPG check authenticates
        the exact bytes the hash is then parsed from. Two independent fetches
        leave a window in which the signed body and the parsed body are not the
        same file, which defeats the signature gate.

        Three outcomes, because "the publisher lists no checksum" and "we could
        not reach the publisher" call for different decisions:
          'fetched'     - Body holds the decoded text.
          'absent'      - HTTP 403/404/410; the file genuinely is not published.
          'unreachable' - anything else that survived the retry budget, plus a
                          success that produced no bytes (a captive portal or a
                          truncating proxy answers 200 with nothing).

        The fetch takes the SAME egress as the transfer it verifies: through
        Save-CachedHttpUri when the host driver supplies one. On a host whose
        only route out is the squid cache, a direct request fails every time
        and would masquerade as an unreachable publisher.
    .PARAMETER DestinationPath
        Where the fetched file lands. The caller owns its lifetime so the same
        file can be handed to the signature verifier.
    .OUTPUTS
        [hashtable] State / Body / Path / Status / Detail
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$TimeoutSec = 60,
        [int]$MaxAttempts = 4
    )
    # Invoke-WebRequest reads -TimeoutSec 0 as "wait forever", so a caller that
    # zeroes it out would hang a bring-up on a black-holed mirror rather than
    # falling into the classification below.
    if ($TimeoutSec -le 0) { $TimeoutSec = 60 }
    $destDir = Split-Path -Parent $DestinationPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
    }
    # Resolve the retry helper by path when no caller has imported it: without
    # it the verification fetch would be strictly less resilient than the
    # multi-hundred-MB transfer it verifies, which does get a retry budget.
    if (-not (Get-Command -Name Invoke-WithYurunaRetry -ErrorAction SilentlyContinue)) {
        $retryModule = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../automation/Yuruna.Retry.psm1'))
        if (Test-Path -LiteralPath $retryModule) { Import-Module $retryModule -ErrorAction SilentlyContinue }
    }
    $fetch = {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        if (Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue) {
            Save-CachedHttpUri -Uri $ChecksumUrl -OutFile $DestinationPath
        } else {
            Invoke-WebRequest -Uri $ChecksumUrl -OutFile $DestinationPath -TimeoutSec $TimeoutSec -ErrorAction Stop
        }
    }.GetNewClosure()
    $fetchError = $null
    if (Get-Command -Name Invoke-WithYurunaRetry -ErrorAction SilentlyContinue) {
        $attempted = Invoke-WithYurunaRetry -Label "checksum fetch $ChecksumUrl" -ScriptBlock $fetch `
            -MaxAttempts $MaxAttempts -InitialDelaySeconds 5 -MaxDelaySeconds 20 `
            -ShouldRetry {
                param($info)
                # 403/404/410 is the publisher's answer, not a fault: spending
                # the whole backoff budget on it only delays the same result.
                return -not ((Get-ChecksumHttpStatus -ErrorRecord $info.Error) -in 403, 404, 410)
            }
        if (-not $attempted.Success) { $fetchError = $attempted.LastError }
    } else {
        try { & $fetch } catch { $fetchError = $_ }
    }
    if ($fetchError) {
        $status = Get-ChecksumHttpStatus -ErrorRecord $fetchError
        $state  = if ($status -in 403, 404, 410) { 'absent' } else { 'unreachable' }
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        return @{ State = $state; Body = ''; Path = $null; Status = $status; Detail = $fetchError.Exception.Message }
    }
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        return @{ State = 'unreachable'; Body = ''; Path = $null; Status = 0; Detail = "the fetch reported success but $DestinationPath is missing" }
    }
    $body = ConvertTo-ChecksumText -Content ([System.IO.File]::ReadAllBytes($DestinationPath))
    if (-not $body.Trim()) {
        return @{ State = 'unreachable'; Body = ''; Path = $null; Status = 0; Detail = 'the fetched checksum file is empty' }
    }
    return @{ State = 'fetched'; Body = $body; Path = $DestinationPath; Status = 0; Detail = '' }
}

function Get-ImageChecksumLine {
    <#
    .SYNOPSIS
        Pull the SHA-256 line for a target filename out of a published
        checksum file, classified as found / absent / unreachable.
    .DESCRIPTION
        Three outcomes rather than "the hash, or $null". A publisher that lists
        no entry and a publisher we could not reach are different facts;
        collapsing both into one $null makes a failed lookup print as the
        publisher's doing and passes the download through unverified.
    .PARAMETER ChecksumUrl
        URL of the SHA256SUMS-style file. Still required when -ChecksumBody
        supplies the content, so messages stay attributable to a source.
    .PARAMETER TargetFileName
        Filename to match. Embedded into the regex as a literal.
    .PARAMETER Pattern
        Regex with the literal token {0} marking where the escaped
        filename goes. {0} is substituted literally (NOT via -f), so
        regex quantifiers like {64} in the pattern are safe. Default
        works for the cloud-images / Ubuntu releases layout.
    .PARAMETER ChecksumBody
        Already-fetched body, raw bytes or text. Supplying it skips the fetch,
        which is how a caller that also needs the artifact for a signature
        check keeps both consumers on one download.
    .OUTPUTS
        [hashtable] State ('found' | 'absent' | 'unreachable') / Hash / Status / Detail
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [Parameter(Mandatory)][string]$TargetFileName,
        [string]$Pattern = $script:DefaultChecksumPattern,
        [AllowNull()]$ChecksumBody,
        [int]$TimeoutSec = 60
    )
    $body = ''
    if ($PSBoundParameters.ContainsKey('ChecksumBody')) {
        $body = ConvertTo-ChecksumText -Content $ChecksumBody
    } else {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-sums-' + [Guid]::NewGuid().ToString('N'))
        try {
            $fetched = Get-PublishedChecksumBody -ChecksumUrl $ChecksumUrl -DestinationPath (Join-Path $work 'SHA256SUMS') -TimeoutSec $TimeoutSec
            if ($fetched.State -ne 'fetched') {
                # Warning, not Verbose: runs log at Information, where a failed
                # fetch, a genuinely unpublished checksum and a lookup that
                # simply broke all read the same -- and a verification bypass
                # that says nothing is a bypass nobody notices.
                Write-Warning "Get-ImageChecksumLine: checksum file $($fetched.State) at $ChecksumUrl (HTTP $($fetched.Status)): $($fetched.Detail)"
                return @{ State = $fetched.State; Hash = ''; Status = $fetched.Status; Detail = $fetched.Detail }
            }
            $body = $fetched.Body
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $body) {
        return @{ State = 'absent'; Hash = ''; Status = 0; Detail = 'the checksum body was empty' }
    }
    $escaped = [regex]::Escape($TargetFileName)
    # Substitute the filename token literally, NOT via -f: the pattern
    # carries regex quantifiers like {64}, which the -f operator misreads
    # as format placeholders (throwing "Index ... less than the size of
    # the argument list" and leaving $rx null). .Replace leaves every
    # other brace untouched so the quantifier survives into the regex.
    $rx = [regex]::new($Pattern.Replace('{0}', $escaped), 'Multiline')
    $m = $rx.Match($body)
    if (-not $m.Success) {
        return @{ State = 'absent'; Hash = ''; Status = 0; Detail = "no line matching '$TargetFileName'" }
    }
    return @{ State = 'found'; Hash = $m.Groups[1].Value; Status = 0; Detail = '' }
}

function Test-PublishedChecksumSignature {
    <#
    .SYNOPSIS
        Best-effort detached-GPG authentication of a published SHA256SUMS
        file against a pinned set of signing-key fingerprints.
    .DESCRIPTION
        Authenticates the SHA256SUMS that the hash check trusts. GPG is a
        BONUS here, never a hard dependency: a missing tool, signature, or
        keyserver can NEVER brick a download. Only a signature that is
        present, checkable, and definitively wrong returns 'bad'.

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
    .PARAMETER ChecksumFilePath
        Local copy of the SHA256SUMS the caller already fetched. Supplying it
        binds the signature and the parsed hash to ONE artifact; without it this
        function fetches its own copy and the two consumers can end up
        authenticating and parsing different bytes.
    .OUTPUTS
        [string] 'good' | 'bad' | 'unverified'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ChecksumUrl,
        [string]$ChecksumFilePath,
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
            # Copy rather than verify in place: gpg is handed a path inside the
            # throwaway homedir, and the caller's copy stays untouched for the
            # hash parse that follows.
            if ($ChecksumFilePath -and (Test-Path -LiteralPath $ChecksumFilePath)) {
                Copy-Item -LiteralPath $ChecksumFilePath -Destination $sumsFile -Force -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $ChecksumUrl -OutFile $sumsFile -ErrorAction Stop
            }
            Invoke-WebRequest -Uri $SignatureUrl -OutFile $sigFile -ErrorAction Stop
        } catch {
            return 'unverified'
        }
        # Offline import of the bundled pinned public keys: no dirmngr/keyserver,
        # which is unreliable under a custom --homedir on Windows.
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

function Invoke-UnverifiedDownloadPolicy {
    <#
    .SYNOPSIS
        Carry out the accept / delete / throw decision for a download that
        could not be hash-verified.
    .DESCRIPTION
        One implementation so the three not-verified outcomes -- no entry in
        the published list, no checksum source at all, and an unreachable
        checksum file -- cannot drift apart as each grows its own switch. The
        caller emits the banner that says WHICH outcome fired; this only
        executes the decision.
    .OUTPUTS
        [bool] $true to keep the file, $false once it has been deleted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('WarnAndContinue','WarnAndDelete','Throw')][string]$Policy,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][string]$Reason
    )
    switch ($Policy) {
        'WarnAndDelete' {
            Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        'Throw' { throw $Reason }
    }
    return $true
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
        Regex carrying the literal token {0}, which is replaced by the
        escaped target filename. Defaults to the cloud-images / Ubuntu
        format.
    .PARAMETER OnMismatch
        Policy when computed hash != expected hash:
          - 'WarnAndContinue'  (default) emit banner, return $true
          - 'WarnAndDelete'    emit banner, delete file, return $false
          - 'Throw'            emit banner, throw an exception
    .PARAMETER OnMissingChecksum
        Same three values, for the case where nothing was available to compare
        against: the publisher's list has no line for this file, the file is
        not published at all (HTTP 403/404/410), or the caller supplied no
        checksum source. Opt-in per call site and permissive by default,
        because a mirror that ships no hash is a publisher's choice rather than
        evidence of tampering -- and the no-source branch is the one every
        AL2023 bring-up takes when the release directory lists no sidecar.
    .PARAMETER OnUnreachableChecksum
        Same three values, for a checksum file that could not be fetched at all
        after the retry budget. Distinct from -OnMissingChecksum on purpose: an
        unreachable mirror says nothing about what the publisher ships, and the
        checksum fetch is the request most exposed to a half-built proxy.
    .PARAMETER VerifyUbuntuSignature
        When set and a -ChecksumUrl is used, best-effort authenticate the
        published SHA256SUMS via its detached GPG signature against the pinned
        Ubuntu signing keys (Test-PublishedChecksumSignature) before trusting
        the hash. A definitively bad/foreign signature is treated like a
        mismatch (subject to -OnMismatch); gpg/keyserver/signature-absent
        degrades to a warning and proceeds on the hash.
    .PARAMETER RetryBudgetSeconds
        Wall-clock budget for retrying a FAILED transfer. These images are
        hundreds of MB and routinely travel through a squid cache provisioned
        minutes earlier, so a mid-stream truncation ("The response ended
        prematurely, with at least N additional bytes expected") is transient,
        not a reason to abort a bring-up. Neither Save-CachedHttpUri nor
        Invoke-WebRequest resumes, so each retry restarts from zero and the
        partial file is removed between attempts. 0 disables retrying.
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
        [ValidateSet('WarnAndContinue','WarnAndDelete','Throw')]
        [string]$OnMissingChecksum = 'WarnAndContinue',
        [ValidateSet('WarnAndContinue','WarnAndDelete','Throw')]
        [string]$OnUnreachableChecksum = 'WarnAndContinue',
        [switch]$VerifyUbuntuSignature,
        [int]$RetryBudgetSeconds = 600
    )
    if (-not $PSCmdlet.ShouldProcess($DestPath, "Download $SourceUrl with checksum policy $OnMismatch")) { return $true }
    $destDir = Split-Path -Parent $DestPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
    }
    Write-Information "Downloading $SourceUrl -> $DestPath" -InformationAction Continue
    # A resumed transfer is not available on either path, so every attempt must
    # start from an absent destination: a truncated file left in place would
    # otherwise be appended to or mistaken for a complete one.
    $fetch = {
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        if (Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue) {
            Save-CachedHttpUri -Uri $SourceUrl -OutFile $DestPath
        } else {
            Invoke-WebRequest -Uri $SourceUrl -OutFile $DestPath -ErrorAction Stop
        }
    }
    try {
        # Invoke-DownloadWithRetry arrives with the host driver's global import of
        # Yuruna.HostDownload; resolve it by name so a caller that has not loaded a
        # driver still gets the single-attempt behavior rather than an error.
        if ($RetryBudgetSeconds -gt 0 -and (Get-Command -Name Invoke-DownloadWithRetry -ErrorAction SilentlyContinue)) {
            Invoke-DownloadWithRetry -Download $fetch -TimeoutSeconds $RetryBudgetSeconds
        } else {
            & $fetch
        }
    } catch {
        Write-Warning "Save-ImageWithChecksum: download failed for $SourceUrl : $($_.Exception.Message)"
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    if (-not (Test-Path -LiteralPath $DestPath)) {
        Write-Warning "Save-ImageWithChecksum: download reported success but $DestPath is missing."
        return $false
    }
    $expected = $ExpectedSha256
    # One fetch of the published checksum file feeds BOTH consumers below: the
    # signature check authenticates the bytes the hash is parsed from. It also
    # runs when the caller already knows the hash but asked for the signature,
    # which is the only way -VerifyUbuntuSignature means anything there.
    if ($ChecksumUrl -and ((-not $expected) -or $VerifyUbuntuSignature)) {
        $sumsWork = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-sums-' + [Guid]::NewGuid().ToString('N'))
        try {
            $published = Get-PublishedChecksumBody -ChecksumUrl $ChecksumUrl -DestinationPath (Join-Path $sumsWork 'SHA256SUMS')
            if ($published.State -eq 'unreachable' -and $expected) {
                # A caller that already holds the hash loses only the signature
                # leg here. Routing it through the unreachable policy instead
                # would skip the comparison it explicitly asked for and accept
                # bytes it had everything it needed to reject.
                Write-Warning "Save-ImageWithChecksum: could not fetch $ChecksumUrl ($($published.Detail)); verifying against the caller-supplied hash, signature unchecked."
            }
            elseif ($published.State -eq 'unreachable') {
                Write-Warning ('=' * 72)
                Write-Warning "  PUBLISHER CHECKSUM UNREACHABLE"
                Write-Warning "  File     : $DestPath"
                Write-Warning "  Checksum : $ChecksumUrl"
                Write-Warning "  Error    : $($published.Detail)"
                Write-Warning "  The download could not be verified. This is a fetch failure, NOT"
                Write-Warning "  evidence that the publisher ships no checksum for it."
                Write-Warning "  Policy   : $OnUnreachableChecksum"
                Write-Warning ('=' * 72)
                return (Invoke-UnverifiedDownloadPolicy -Policy $OnUnreachableChecksum -DestPath $DestPath `
                        -Reason "Publisher checksum unreachable at $ChecksumUrl : $($published.Detail)")
            }
            if ($published.State -eq 'fetched' -and $VerifyUbuntuSignature) {
                switch (Test-PublishedChecksumSignature -ChecksumUrl $ChecksumUrl -ChecksumFilePath $published.Path) {
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
            if (-not $expected) {
                $targetName = if ($ChecksumTargetFileName) { $ChecksumTargetFileName } else { Split-Path -Leaf $SourceUrl }
                $line = Get-ImageChecksumLine -ChecksumUrl $ChecksumUrl -TargetFileName $targetName `
                    -Pattern $ChecksumPattern -ChecksumBody $published.Body
                if ($line.State -eq 'found') {
                    $expected = $line.Hash
                } else {
                    # Report what was actually observed: a 403 from a corporate
                    # proxy and a 404 from the mirror lead to different fixes,
                    # and neither is "the publisher lists no entry".
                    $why = if ($published.Status) { "the publisher answered HTTP $($published.Status)" } else { 'the published list has no line for it' }
                    Write-Warning "Save-ImageWithChecksum: no checksum entry for '$targetName' at $ChecksumUrl -- $why ; policy $OnMissingChecksum."
                    return (Invoke-UnverifiedDownloadPolicy -Policy $OnMissingChecksum -DestPath $DestPath `
                            -Reason "No checksum entry for '$targetName' at $ChecksumUrl ($why)")
                }
            }
        } finally {
            Remove-Item -LiteralPath $sumsWork -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $expected) {
        # No checksum source supplied at all -- the caller opted out of
        # verification rather than a publisher failing to provide one. Kept off
        # the warning stream under the permissive default so a mirror with no
        # sidecar does not add noise to every run, while still routed through
        # the policy so a strict caller can refuse the artifact.
        Write-Verbose "Save-ImageWithChecksum: no checksum source supplied for $DestPath ; policy $OnMissingChecksum."
        if ($OnMissingChecksum -ne 'WarnAndContinue') {
            Write-Warning "Save-ImageWithChecksum: no checksum source supplied for $SourceUrl ; policy $OnMissingChecksum."
        }
        return (Invoke-UnverifiedDownloadPolicy -Policy $OnMissingChecksum -DestPath $DestPath `
                -Reason "No checksum source supplied for $DestPath")
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

function Resolve-QemuImgCommand {
    <#
    .SYNOPSIS
        Path to qemu-img, or $null when it isn't installed.
    .DESCRIPTION
        PATH first, then the two Windows installer locations: the QEMU
        installer does not add itself to PATH, so a Windows host with QEMU
        properly installed still fails a bare Get-Command probe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @("$env:ProgramFiles\qemu\qemu-img.exe", "${env:ProgramFiles(x86)}\qemu\qemu-img.exe")) {
        if (Test-Path $c) { return $c }
    }
    return $null
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
        fallback. A convert failure, or a resize that fails on both paths,
        removes the partial DestPath and returns $false. Native qemu-img output
        is captured (never emitted) so it cannot pollute the [bool] return.
    .PARAMETER SizeBytes
        Target nominal size. Omit (or pass 0) to convert only and leave the
        VHDX at the cloud image's native capacity -- what a shared base image
        wants, because each consumer grows its OWN copy to the size that VM
        needs. Growing a per-VM copy is safe; a shared base pre-grown to the
        largest consumer would force the smaller ones to SHRINK, which
        Hyper-V refuses while the guest partition still spans the disk.
    .OUTPUTS
        [bool] $true when DestPath is a usable VHDX at the requested size;
        $false when qemu-img is missing or the convert or resize failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [long]$SizeBytes = 0
    )
    $qemuImg = Resolve-QemuImgCommand
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
    if ($SizeBytes -le 0) {
        Write-Information "  convert-only: VHDX left at the cloud image's native capacity." -InformationAction Continue
        return $true
    }
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
        # Both resize paths failed, so the VHDX is only the base cloud-image
        # capacity. Refuse it as success -- a caller that proceeds would
        # provision an undersized disk (a 512 GB cache on a ~4 GB image) -- and
        # remove the stub so a retry cannot adopt it.
        Write-Warning "VHDX resize failed via both Resize-VHD and qemu-img; refusing the base-capacity disk."
        Write-Warning "Resize manually: fsutil sparse setflag '$DestPath' 0; Resize-VHD -Path '$DestPath' -SizeBytes $SizeBytes"
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
    }
    return $resized
}

# --- REGION: https://yuruna.link/guest-image-setup#shared-extension-service-base-image
# One shared cloud image for every extension-service VM; NOT the
# guest.ubuntu.server.26 installer ISO. Bump the codename and the stem together.
$script:UbuntuExtensionImageCodename = 'resolute'
$script:UbuntuExtensionImageStem     = 'ubuntu.extension.26'

function Get-UbuntuExtensionImageBaseName {
    <#
    .SYNOPSIS
        On-disk stem of the shared extension-service base image for a host
        type, with no filesystem or hypervisor lookup.
    .DESCRIPTION
        Split out from Get-UbuntuExtensionImageInfo for callers that only need
        the name -- notably the orphan sweeps, which run this before they have
        established that the hypervisor is even usable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HostType
    )
    return "host.$HostType.$script:UbuntuExtensionImageStem"
}

function Get-UbuntuExtensionImageInfo {
    <#
    .SYNOPSIS
        Resolve where the shared extension-service base image lives for a host
        type, and which publisher URL fills it.
    .DESCRIPTION
        Single source of truth for the release codename, the guest
        architecture, the on-disk stem and the artifact format, so the
        service Get-Image.ps1 and New-VM.ps1 scripts can never disagree about
        which file they are producing and consuming.
    .PARAMETER HostType
        Host folder name under host/ -- also the middle segment of the base
        image stem, matching the "host.<host-type>.*" convention every other
        base image on disk already follows.
    .OUTPUTS
        [hashtable] HostType, Arch, SourceUrl, ChecksumUrl, DownloadDir,
        BaseImageName, BaseImageFile, OriginFile, Format.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('macos.utm', 'ubuntu.kvm', 'windows.hyper-v')]
        [string]$HostType
    )
    switch ($HostType) {
        'macos.utm' {
            # UTM runs on Apple Silicon via Apple Virtualization / HVF.
            $arch   = 'arm64'
            # --- REGION: https://yuruna.link/vmconfig#macos-utm-qcow2-punchhole-alignment
            # Stays qcow2: a raw disk trips the macOS F_PUNCHHOLE 4 KiB-alignment
            # EINVAL under UTM's discard=unmap.
            $format = 'qcow2'
            $dir    = Join-Path $HOME "yuruna/image/$script:UbuntuExtensionImageStem"
        }
        'ubuntu.kvm' {
            $machine = (& uname -m).Trim()
            switch ($machine) {
                'x86_64'  { $arch = 'amd64' }
                'aarch64' { $arch = 'arm64' }
                default   { throw "Unsupported architecture for the extension-service base image: $machine" }
            }
            # libvirt-qemu boots qcow2 natively; no conversion needed.
            $format = 'qcow2'
            $dir    = Join-Path $HOME "yuruna/image/$script:UbuntuExtensionImageStem"
        }
        'windows.hyper-v' {
            $arch   = 'amd64'
            # Hyper-V boots VHDX, and it expects guest disks under the host's
            # own VirtualHardDiskPath (which the operator may have relocated).
            $format = 'vhdx'
            $dir    = (Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
            if (-not $dir) {
                throw "Could not read the Hyper-V VirtualHardDiskPath: Get-VMHost failed. Hyper-V may not be installed, or this session is not elevated."
            }
            if (-not (Test-Path -LiteralPath $dir)) {
                throw "The Hyper-V default VHDX folder does not exist: $dir"
            }
        }
    }
    $codename = $script:UbuntuExtensionImageCodename
    $sourceUrl = "https://cloud-images.ubuntu.com/$codename/current/$codename-server-cloudimg-$arch.img"
    $baseImageName = Get-UbuntuExtensionImageBaseName -HostType $HostType
    return @{
        HostType      = $HostType
        Arch          = $arch
        SourceUrl     = $sourceUrl
        ChecksumUrl   = "$($sourceUrl.Substring(0, $sourceUrl.LastIndexOf('/')))/SHA256SUMS"
        DownloadDir   = $dir
        BaseImageName = $baseImageName
        BaseImageFile = Join-Path $dir "$baseImageName.$format"
        OriginFile    = Join-Path $dir "$baseImageName.txt"
        Format        = $format
    }
}

function Save-UbuntuExtensionImage {
    <#
    .SYNOPSIS
        Download (and on Hyper-V convert) the shared extension-service base
        image described by Get-UbuntuExtensionImageInfo.
    .DESCRIPTION
        Full resolve-skip-download-verify-promote pipeline:
          * a download agent, when one is reachable, answers "you already
            hold the current artifact" or serves verified bytes with the
            origin never contacted
            (docs/guest-image-setup.md#agent-first-image-downloads)
          * skip-if-same-source guard on the 4-line sentinel, so the second
            and third service asking for the image cost one HEAD request
          * SHA-256 + pinned-key GPG verification of the publisher checksum
          * previous artifact preserved as <stem>.previous.<ext>
          * sentinel rewritten with the DOWNLOAD size (not the converted
            artifact's), which is what the guard compares next run

        Requires the caller to have imported its host's Yuruna.Host.psm1
        first: Test-DownloadAlreadyCurrent / Write-ImageSentinel arrive
        through that driver's global import of Yuruna.HostDownload, and the
        driver's cache-injecting Save-CachedHttpUri wrapper is what routes
        the download through the squid cache. Resolving them by name here
        rather than importing Yuruna.HostDownload directly is deliberate:
        a module-scope import would shadow that wrapper with the shared
        implementation and silently bypass the cache.
    .PARAMETER MinimumBytes
        Floor for the "did we get an error page instead of an image" check.
    .OUTPUTS
        [bool] $true when BaseImageFile is present and current.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Image,
        [long]$MinimumBytes = 100MB
    )
    foreach ($dependency in @('Test-DownloadAlreadyCurrent', 'Write-ImageSentinel')) {
        if (-not (Get-Command -Name $dependency -ErrorAction SilentlyContinue)) {
            Write-Error "Save-UbuntuExtensionImage: $dependency is not available. Import the host driver (host/<host-type>/modules/Yuruna.Host.psm1) before calling."
            return $false
        }
    }

    New-Item -ItemType Directory -Force -Path $Image.DownloadDir | Out-Null

    # PID-suffixed staging names: every extension service resolves to this
    # one artifact, so two service builds running at once would otherwise
    # interleave writes into a single partial file.
    $downloadFile = Join-Path $Image.DownloadDir "$($Image.BaseImageName).downloading.$PID.img"

    # --- REGION: https://yuruna.link/guest-image-setup#agent-first-image-downloads
    # Ask the download agent before the origin is touched at all. The hook lands
    # ahead of the same-source guard and the single Save-ImageWithChecksum call
    # below, so this chain consults the agent exactly once; every other answer --
    # no client module, no agent, no pool, a checksum mismatch, a deadline --
    # falls through to the guard-plus-download path below.
    $agentServed       = $false
    $agentSourceUrl    = ''
    $agentLastModified = ''
    if ((Get-Command -Name Resolve-DownloadAgentEndpoint -ErrorAction SilentlyContinue) -and
        (Get-Command -Name Request-DownloadAgentImage -ErrorAction SilentlyContinue)) {
        $agentBaseUrl = ''
        try { $agentBaseUrl = [string](Resolve-DownloadAgentEndpoint) } catch { $agentBaseUrl = '' }
        if (-not $agentBaseUrl) {
            Write-Verbose "Save-UbuntuExtensionImage: no download agent reachable; using the origin path."
        } else {
            # Fingerprint the local copy with the sentinel's filename + byte
            # count and no SHA-256: the sentinel records the DOWNLOAD size,
            # which is the pooled artifact's size even on Hyper-V where the
            # local file is a converted VHDX, and re-hashing a multi-hundred-MB
            # image every run would cost more than it saves.
            $agentArgs = @{
                BaseUrl         = $agentBaseUrl
                HostType        = $Image.HostType
                ImageKey        = 'ubuntu.extension.26'
                Arch            = $Image.Arch
                Variant         = 'stable'
                StagingPath     = $downloadFile
                DeadlineSeconds = 7200
            }
            if ((Test-Path -LiteralPath $Image.BaseImageFile) -and (Test-Path -LiteralPath $Image.OriginFile)) {
                $sentinelLines = @(Get-Content -LiteralPath $Image.OriginFile -ErrorAction SilentlyContinue)
                $sentinelBytes = 0L
                if ($sentinelLines.Count -ge 3 -and [int64]::TryParse($sentinelLines[2].Trim(), [ref]$sentinelBytes) -and $sentinelBytes -gt 0) {
                    $agentArgs['LocalFilename']  = $sentinelLines[0].Trim()
                    $agentArgs['LocalByteCount'] = $sentinelBytes
                }
            }
            $agentResult = $null
            try {
                Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
                $agentResult = Request-DownloadAgentImage @agentArgs
            } catch {
                Write-Warning "Download agent at $agentBaseUrl failed ($($_.Exception.Message)); falling back to the origin download path."
                $agentResult = $null
            }
            if ($agentResult -and $agentResult.outcome -eq 'skipped') {
                $msg = @(
                    "Skipping download: the download agent at $agentBaseUrl confirms $($Image.BaseImageFile) is the current ubuntu.extension.26 artifact."
                    "  Sentinel: $($Image.OriginFile)"
                    "  To force a re-download, delete or rename: $($Image.BaseImageFile)"
                ) -join [Environment]::NewLine
                Write-Information $msg -InformationAction Continue
                Write-Output $msg
                return $true
            } elseif ($agentResult -and $agentResult.outcome -eq 'downloaded') {
                $agentServed       = $true
                $agentSourceUrl    = [string]$agentResult.sourceUrl
                $agentLastModified = [string]$agentResult.lastModified
                Write-Output "Download agent at $agentBaseUrl served verified $($agentResult.filename) to $downloadFile"
            } elseif ($agentResult) {
                $detail = if ($agentResult.error) { ": $($agentResult.error)" } else { '' }
                Write-Warning "Download agent at $agentBaseUrl answered '$($agentResult.outcome)'$detail; falling back to the origin download path."
            }
        }
    }

    if (-not $agentServed) {
        # --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
        if (Test-DownloadAlreadyCurrent -SourceUrl $Image.SourceUrl -BaseImageFile $Image.BaseImageFile -OriginFile $Image.OriginFile -Verbose:($VerbosePreference -ne 'SilentlyContinue')) {
            $skipLines = @(Get-Content -LiteralPath $Image.OriginFile -ErrorAction SilentlyContinue)
            $msg = @(
                "Skipping download: source URL + size + Last-Modified all match the prior run for $($Image.BaseImageFile)."
                "  Sentinel: $($Image.OriginFile)"
                "    filename     : $($skipLines[0])"
                "    source URL   : $($skipLines[1])"
                "    byte count   : $($skipLines[2])"
                "    last-modified: $($skipLines[3])"
                "  To force a re-download, delete or rename: $($Image.BaseImageFile)"
            ) -join [Environment]::NewLine
            Write-Information $msg -InformationAction Continue
            Write-Output $msg
            return $true
        }

        # --- REGION: Download the cloud image
        Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
        $sourceBaseName = $Image.SourceUrl.Substring($Image.SourceUrl.LastIndexOf('/') + 1)
        $downloaded = Save-ImageWithChecksum `
            -SourceUrl   $Image.SourceUrl `
            -DestPath    $downloadFile `
            -ChecksumUrl $Image.ChecksumUrl `
            -ChecksumTargetFileName $sourceBaseName `
            -OnMismatch  'WarnAndDelete' `
            -VerifyUbuntuSignature `
            -Confirm:$false
        if (-not $downloaded) {
            Write-Error "Download failed for $($Image.SourceUrl)"
            return $false
        }
    }
    # Capture the HTTP-download size BEFORE any conversion: the artifact at
    # BaseImageFile is the converted file, not the bytes the guard compares
    # against the publisher's Content-Length next run.
    $downloadedSize = (Get-Item -LiteralPath $downloadFile).Length
    if ($downloadedSize -lt $MinimumBytes) {
        Write-Error "Downloaded file is suspiciously small ($([math]::Round($downloadedSize / 1MB, 1)) MB). Expected ~600 MB."
        Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    # --- REGION: Stage the final artifact
    # Left at the cloud image's native capacity on purpose; each New-VM.ps1
    # grows its own copy (Expand-ExtensionVmDisk) to the size that service needs.
    $stagedFile = Join-Path $Image.DownloadDir "$($Image.BaseImageName).staging.$PID.$($Image.Format)"
    Remove-Item -LiteralPath $stagedFile -Force -ErrorAction SilentlyContinue
    if ($Image.Format -eq 'vhdx') {
        # --- REGION: Convert qcow2 to VHDX
        # Convert-Qcow2ToVhdx owns qemu-img discovery and the NTFS sparse-flag
        # clear (feedback_qemu_img_vhdx_sparse.md), so the trap fix lives once.
        if (-not (Convert-Qcow2ToVhdx -SourcePath $downloadFile -DestPath $stagedFile)) {
            Write-Error "qcow2 to VHDX conversion failed for the download"
            Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue
    } else {
        # The cloud image already IS qcow2; the .img extension is the
        # publisher's naming, not a different format.
        Move-Item -LiteralPath $downloadFile -Destination $stagedFile
    }

    # --- REGION: Preserve previous and finalize
    $previousFile = Join-Path $Image.DownloadDir "$($Image.BaseImageName).previous.$($Image.Format)"
    Remove-Item -LiteralPath $previousFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Image.BaseImageFile) {
        Move-Item -LiteralPath $Image.BaseImageFile -Destination $previousFile
        Write-Output "Previous image preserved as: $previousFile"
    }
    Move-Item -LiteralPath $stagedFile -Destination $Image.BaseImageFile

    # --- REGION: https://yuruna.link/guest-image-setup#skip-if-same-source-guard
    if ($agentServed) {
        # Describe the bytes that actually landed: the agent reports the origin
        # URL and Last-Modified it downloaded from, and HEAD-ing the origin here
        # would re-touch the server the agent path exists to spare. A URL that
        # ever drifts from Get-UbuntuExtensionImageInfo's fixed one simply makes
        # the next run's guard re-download, which is the safe direction.
        Write-ImageSentinel -SourceUrl $agentSourceUrl -OriginFile $Image.OriginFile -SizeBytes $downloadedSize -LastModified $agentLastModified -Confirm:$false
    } else {
        Write-ImageSentinel -SourceUrl $Image.SourceUrl -OriginFile $Image.OriginFile -SizeBytes $downloadedSize -Confirm:$false
    }
    Write-Output "Recorded source filename, URL, byte count, and Last-Modified to: $($Image.OriginFile)"
    Write-Output "Download complete: $($Image.BaseImageFile)"
    return $true
}

function Expand-ExtensionVmDisk {
    <#
    .SYNOPSIS
        Grow a per-VM copy of the shared extension-service base image to the
        nominal size that service needs.
    .DESCRIPTION
        The base image stays at the cloud image's native capacity so one
        artifact can serve services with different disk budgets; growth
        happens here, on the copy, before first boot, and cloud-init's
        growpart then expands the root partition into it.

        qcow2 and dynamic VHDX both grow as metadata, so this is fast and
        consumes no additional disk until the guest writes.
    .OUTPUTS
        [bool] $true when the disk reached the requested size.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$SizeBytes,
        [ValidateSet('qcow2', 'vhdx')][string]$Format = 'qcow2'
    )
    $sizeGb = [math]::Round($SizeBytes / 1GB)
    Write-Output "Resizing $Format disk to ${sizeGb}GB..."
    if ($Format -eq 'vhdx') {
        # Copying a VHDX can carry the NTFS sparse attribute along, and
        # Resize-VHD refuses a sparse file with 0xC03A001A.
        # See feedback_qemu_img_vhdx_sparse.md.
        & fsutil sparse setflag $Path 0 2>&1 | Out-Null
        # See https://yuruna.link/memory#why-cache-vhdx-uses-resize-vhd-instead-of-qemu-img-resize
        try {
            Resize-VHD -Path $Path -SizeBytes $SizeBytes -ErrorAction Stop
            return $true
        } catch {
            Write-Warning "Resize-VHD failed: $($_.Exception.Message); falling back to qemu-img resize."
        }
    }
    $qemuImg = Resolve-QemuImgCommand
    if (-not $qemuImg) {
        Write-Warning "qemu-img not found; cannot resize $Path."
        return $false
    }
    $resizeArgs = @('resize')
    if ($Format -eq 'qcow2') { $resizeArgs += @('-f', 'qcow2') }
    $resizeOut = & $qemuImg @resizeArgs $Path "${sizeGb}G" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "qemu-img resize failed: $resizeOut"
        return $false
    }
    return $true
}

Export-ModuleMember -Function Save-ImageWithChecksum, Get-ImageChecksumLine, Get-PublishedChecksumBody, ConvertTo-ChecksumText, `
    Convert-Qcow2ToVhdx, Test-PublishedChecksumSignature, `
    Resolve-QemuImgCommand, Get-UbuntuExtensionImageBaseName, Get-UbuntuExtensionImageInfo, Save-UbuntuExtensionImage, Expand-ExtensionVmDisk
