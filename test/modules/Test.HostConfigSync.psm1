<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d7f3b9-5c1e-4a80-9e2d-7f8a9b0c1d2e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host config sync networkStorage
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
    Host-to-host test.config.yml sync: copy the configuration of a reference
    pool host onto this host, converting host-type-specific values.
.DESCRIPTION
    A pool host's test.config.yml is almost entirely host-agnostic; the
    exceptions are the networkStorage local mount idioms (Windows drive
    letters vs /mnt/<server> vs ~/Shares/<server>) and a handful of
    non-portable values (file:// repository URLs, absolute clone paths).
    Sync-HostConfiguration pulls the reference host's config over its
    status server (GET /control/test-config, JSON), converts those values
    for the local host type, preserves the local 'secrets' node, and then
    reconciles the two side channels the config depends on:

      * hosts-file aliases -- a networkStorage server name that does not
        resolve locally is looked up on the reference host
        (GET /control/host-aliases) and written via
        automation/Set-HostAlias.ps1 (operator prompt as fallback);
      * vault credentials -- a networkStorage user with no local vault
        entry is fetched from the reference host's
        GET /control/vault-credential, which is gated by the shared
        pool-auth-token and returns the password encrypted with a key
        derived from that token, so no secret crosses the LAN in
        cleartext (operator prompt as fallback).

    The per-host-type operator entry points are the thin
    host/<type>/Sync-HostConfiguration.ps1 shells; everything here is
    platform-neutral so the three shells cannot drift on the sync logic.
#>

# Write-YurunaStateFile (atomic temp+rename) and ConvertTo-SortedConfig
# (canonical key/array ordering) are the same primitives every other
# test.config.yml writer routes through, so a synced file is byte-stable
# against the per-cycle template reconcile instead of churning on first run.
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1')     -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1')    -Force -DisableNameChecking
# Get-PoolStorageUncPath / Get-PoolStorageServerName / Test-PoolStorageHostResolvable:
# the networkStorage path grammar lives in one module; reusing it keeps this
# converter and the mount path from ever disagreeing on what a share path means.
Import-Module (Join-Path $PSScriptRoot 'Test.PoolStorage.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostDetection.psm1') -Force -DisableNameChecking

# One version string binds the HMAC proof, the HKDF key derivation, and the
# envelope shape together: bumping it invalidates every older client/server
# pairing at once instead of failing open on a partial mismatch.
$script:ConfigSyncCredentialLabel = 'yuruna-config-sync|v1'

# --- REGION: Pure conversion helpers (no I/O; unit-tested directly)

<#
.SYNOPSIS
    Returns the conventional networkStorage local mount path for a host type:
    Windows drive letters ('y:' pool / 'z:' stash), Linux '/mnt/<server>',
    macOS '~/Shares/<server>'.
#>
function Get-ConfigSyncLocalPathDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][ValidateSet('pool', 'stash')][string]$Tier,
        [Parameter()][AllowEmptyString()][string]$ServerName
    )
    if ($HostType -like '*windows*') {
        if ($Tier -eq 'pool') { return 'y:' }
        return 'z:'
    }
    if ([string]::IsNullOrWhiteSpace($ServerName)) { return '' }
    if ($HostType -like '*macos*') { return "~/Shares/$ServerName" }
    return "/mnt/$ServerName"
}

<#
.SYNOPSIS
    Converts a reference host's networkStorage node for the local host type:
    share paths get the local slash style, users copy verbatim, and each
    tier's localPath keeps a non-empty local value (it reflects a working
    mount) or falls back to the per-OS convention.
.OUTPUTS
    [hashtable] @{ NetworkStorage = [ordered]; Warnings = [string[]] }
#>
function Convert-ConfigSyncNetworkStorage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Reference,
        [Parameter()][AllowNull()]$Local,
        [Parameter(Mandatory)][string]$HostType
    )
    $refNs   = if ($Reference -is [System.Collections.IDictionary]) { $Reference } else { @{} }
    $localNs = if ($Local     -is [System.Collections.IDictionary]) { $Local }     else { @{} }
    $style   = if ($HostType -like '*windows*') { 'windows' } else { 'unix' }

    $out      = [ordered]@{}
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($tier in @('pool', 'stash')) {
        $npKey = "${tier}NetworkPath"; $nuKey = "${tier}NetworkUser"; $lpKey = "${tier}LocalPath"
        $refNp   = if ($refNs.Contains($npKey))   { "$($refNs[$npKey])".Trim() }   else { '' }
        $refNu   = if ($refNs.Contains($nuKey))   { "$($refNs[$nuKey])".Trim() }   else { '' }
        $localNp = if ($localNs.Contains($npKey)) { "$($localNs[$npKey])".Trim() } else { '' }
        $localLp = if ($localNs.Contains($lpKey)) { "$($localNs[$lpKey])".Trim() } else { '' }

        if ([string]::IsNullOrWhiteSpace($refNp)) {
            # Reference is the source of truth: an unconfigured tier on the
            # reference clears the tier here too, but never silently -- the
            # previous file is backed up by the caller before the write.
            if ($localNp -or $localLp) {
                [void]$warnings.Add("networkStorage: the reference host has no $tier storage configured; the local $tier values are being cleared (previous file kept in the .backup).")
            }
            $out[$lpKey] = ''; $out[$npKey] = ''; $out[$nuKey] = ''
            continue
        }

        $out[$npKey] = Get-PoolStorageUncPath -Path $refNp -Style $style
        $out[$nuKey] = $refNu
        if (-not [string]::IsNullOrWhiteSpace($localLp)) {
            # A populated local mount path reflects a mount that already
            # works on this host; adopting the reference's idiom would break
            # it for zero benefit.
            $out[$lpKey] = $localLp
        } else {
            $server = Get-PoolStorageServerName -NetworkPath $refNp
            $out[$lpKey] = Get-ConfigSyncLocalPathDefault -HostType $HostType -Tier $tier -ServerName $server
        }
    }
    return @{ NetworkStorage = $out; Warnings = [string[]]@($warnings) }
}

<#
.SYNOPSIS
    Merges a reference host's config onto this host: full copy with the
    networkStorage conversion applied, the local 'secrets' node preserved,
    and non-portable values (file:// projectUrl, absolute pool.localClonePath)
    kept local -- each with a warning.
.OUTPUTS
    [hashtable] @{ Config = [IDictionary]; Warnings = [string[]] }
#>
function Merge-ConfigSyncReferenceConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Reference,
        [Parameter()][AllowNull()]$Local,
        [Parameter(Mandatory)][string]$HostType
    )
    if ($Reference -isnot [System.Collections.IDictionary]) {
        throw "Merge-ConfigSyncReferenceConfig: the reference config is not a map (got $($Reference.GetType().Name))."
    }
    $warnings = [System.Collections.Generic.List[string]]::new()
    # The reference dictionary is a per-call parse owned by this sync; it is
    # mutated in place rather than deep-copied.
    $merged = $Reference

    $localNs = $null
    if ($Local -is [System.Collections.IDictionary] -and $Local.Contains('networkStorage')) {
        $localNs = $Local['networkStorage']
    }
    $refNs = if ($merged.Contains('networkStorage')) { $merged['networkStorage'] } else { $null }
    $conv  = Convert-ConfigSyncNetworkStorage -Reference $refNs -Local $localNs -HostType $HostType
    $merged['networkStorage'] = $conv.NetworkStorage
    foreach ($w in $conv.Warnings) { [void]$warnings.Add($w) }

    # Credentials are host-managed: the local 'secrets' node survives the
    # sync, and a reference host's node is never adopted.
    if ($merged.Contains('secrets')) {
        $merged.Remove('secrets')
        [void]$warnings.Add("secrets: the reference host's secrets node was NOT copied (credentials never cross hosts through the config sync).")
    }
    if ($Local -is [System.Collections.IDictionary] -and $Local.Contains('secrets')) {
        $merged['secrets'] = $Local['secrets']
    }

    # repositories.projectUrl supports a file:// / bare-local-path form that
    # only exists on the host that set it; carrying it over would break the
    # first cycle here.
    $refRepos = if ($merged.Contains('repositories')) { $merged['repositories'] } else { $null }
    if ($refRepos -is [System.Collections.IDictionary] -and $refRepos.Contains('projectUrl')) {
        $proj = "$($refRepos['projectUrl'])".Trim()
        if ($proj -and $proj -notmatch '^https?://') {
            $localProj = ''
            if ($Local -is [System.Collections.IDictionary] -and
                $Local['repositories'] -is [System.Collections.IDictionary]) {
                $localProj = "$($Local['repositories']['projectUrl'])".Trim()
            }
            $refRepos['projectUrl'] = $localProj
            $kept = if ($localProj) { "kept the local value '$localProj'" } else { 'left it empty' }
            [void]$warnings.Add("repositories.projectUrl: the reference value '$proj' is a local path on the reference host and is not portable; $kept.")
        }
    }

    # pool.localClonePath: empty means "<runtime>/pool-intent" (portable);
    # a populated value is an OS-native absolute path from the reference host.
    $refPool = if ($merged.Contains('pool')) { $merged['pool'] } else { $null }
    if ($refPool -is [System.Collections.IDictionary] -and $refPool.Contains('localClonePath')) {
        $clone = "$($refPool['localClonePath'])".Trim()
        if ($clone) {
            $localClone = ''
            if ($Local -is [System.Collections.IDictionary] -and
                $Local['pool'] -is [System.Collections.IDictionary]) {
                $localClone = "$($Local['pool']['localClonePath'])".Trim()
            }
            $refPool['localClonePath'] = $localClone
            $kept = if ($localClone) { "kept the local value '$localClone'" } else { 'left it empty (defaults to <runtime>/pool-intent)' }
            [void]$warnings.Add("pool.localClonePath: the reference value '$clone' is an absolute path on the reference host and is not portable; $kept.")
        }
    }

    return @{ Config = $merged; Warnings = [string[]]@($warnings) }
}

# --- REGION: Shared-token credential envelope (client + server sides)
# Both ends hold the operator-set pool-auth-token; nothing else is shared.
# The request carries an HMAC proof-of-knowledge (the token itself never
# crosses the wire) and the response password is AES-256-GCM encrypted with
# an HKDF key derived from token + a fresh per-response salt, with the user
# and the client's nonce bound into the derivation -- a captured response
# cannot be decrypted without the token nor replayed for a different user.
# The status server is plain HTTP on a trusted LAN; this keeps the secret
# confidential in transit without a TLS dependency.

function Get-ConfigSyncHmac {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The `return ,$bytes` idiom below is what makes the caller actually receive the declared [byte[]]. Static analysis reads the comma as an [object[]] wrapper; at runtime the pipeline unwraps it and the caller gets the byte[].')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Data
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Token))
    # The unary comma is load-bearing. A bare `return $bytes` writes the array to
    # the pipeline ELEMENT BY ELEMENT, and the caller collects the pieces back
    # into an [object[]] -- not the [byte[]] the OutputType above advertises
    # (that attribute documents, it does not coerce). Most callers never notice,
    # because a [byte[]]-typed parameter converts the object[] back. Test-ConfigSyncProof
    # does notice: it passes this value to a ReadOnlySpan<byte> parameter, and a
    # ByRef-like type is the one thing PowerShell cannot convert an object[] into,
    # so the comparison throws instead of returning a verdict.
    try { return ,$hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data)) }
    finally { $hmac.Dispose() }
}

<#
.SYNOPSIS
    Client side: the base64 HMAC proof that the caller knows the shared
    pool-auth-token, bound to the requested user and the client nonce.
#>
function Get-ConfigSyncProof {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Nonce
    )
    return [Convert]::ToBase64String((Get-ConfigSyncHmac -Token $Token -Data "$($script:ConfigSyncCredentialLabel)|proof|$User|$Nonce"))
}

<#
.SYNOPSIS
    Server side: constant-time check of a client's proof (see Get-ConfigSyncProof).
#>
function Test-ConfigSyncProof {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Nonce,
        [Parameter(Mandatory)][string]$Proof
    )
    # [byte[]] casts: a bare `$x = Get-ConfigSyncHmac` unrolls the returned byte[] into
    # an Object[] on the PowerShell pipeline, which FixedTimeEquals (ReadOnlySpan<byte>)
    # cannot bind -- the cast pins both operands back to byte[].
    [byte[]]$expected = Get-ConfigSyncHmac -Token $Token -Data "$($script:ConfigSyncCredentialLabel)|proof|$User|$Nonce"
    [byte[]]$given = $null
    try { $given = [Convert]::FromBase64String($Proof) } catch { return $false }
    if ($given.Length -ne $expected.Length) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $given)
}

<#
.SYNOPSIS
    Mint the wire proof the status server's mutating /control/* routes accept:
    "<expiryUnixSeconds>.<base64 HMAC>". The pool aggregator's /go/host mints the
    identical value in Go so a Grafana deep-link can carry it to the browser UI.
.DESCRIPTION
    proof = base64( HMAC-SHA256(pool-auth-token, "yuruna-control|proof|<expiry>") ).
    Bound to the expiry only: the pool-auth-token is pool-wide, so a valid proof means
    "authorized within the TTL". The raw token never leaves the minting host (only the
    HMAC + the plaintext expiry travel, in a URL fragment).
#>
function Get-YurunaControlProof {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][long]$ExpiryUnixSeconds
    )
    $proof = [Convert]::ToBase64String((Get-ConfigSyncHmac -Token $Token -Data "yuruna-control|proof|$ExpiryUnixSeconds"))
    return "$ExpiryUnixSeconds.$proof"
}

<#
.SYNOPSIS
    Constant-time verify of a control proof from Get-YurunaControlProof (or the
    aggregator's Go mint). Returns $false on any malformed / expired / mismatched input.
.DESCRIPTION
    Parses "<expiry>.<base64 HMAC>", requires now <= expiry <= now + MaxTtlSeconds
    (rejects a far-future proof so a captured token cannot mint an eternal pass),
    recomputes the HMAC over the given expiry, and FixedTimeEquals-compares.
#>
function Test-YurunaControlProof {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # AllowEmptyString: the server gate calls this with whatever pool-auth-token it
        # read -- possibly empty on a host that has none -- and must get $false, not a
        # binding throw that would break the route.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Wire,
        [int]$MaxTtlSeconds = 900
    )
    if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($Wire)) { return $false }
    $dot = $Wire.IndexOf('.')
    if ($dot -le 0 -or $dot -ge ($Wire.Length - 1)) { return $false }
    [long]$expiry = 0
    if (-not [long]::TryParse($Wire.Substring(0, $dot), [ref]$expiry)) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($expiry -lt $now -or $expiry -gt ($now + $MaxTtlSeconds)) { return $false }
    [byte[]]$given = $null
    try { $given = [Convert]::FromBase64String($Wire.Substring($dot + 1)) } catch { return $false }
    [byte[]]$expected = Get-ConfigSyncHmac -Token $Token -Data "yuruna-control|proof|$expiry"
    if ($given.Length -ne $expected.Length) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $given)
}

function Get-ConfigSyncEnvelopeKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'Same `return ,$bytes` idiom as Get-ConfigSyncHmac: the comma is what preserves the declared [byte[]] across the pipeline.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$ClientNonce,
        [Parameter(Mandatory)][byte[]]$Salt
    )
    $ikm  = [System.Text.Encoding]::UTF8.GetBytes($Token)
    $info = [System.Text.Encoding]::UTF8.GetBytes("$($script:ConfigSyncCredentialLabel)|key|$User|$ClientNonce")
    # Comma for the same reason as Get-ConfigSyncHmac. This one currently survives
    # without it only because its consumers declare [byte[]] parameters, which
    # convert the object[] back; that is luck, not a contract.
    return ,[System.Security.Cryptography.HKDF]::DeriveKey(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, $ikm, 32, $Salt, $info)
}

function New-ConfigSyncAesGcm {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure object constructor; does not mutate state.')]
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.AesGcm])]
    param([Parameter(Mandatory)][byte[]]$Key)
    # The (key, tagSize) constructor is the non-deprecated form on current
    # .NET; older runtimes only have the single-argument one.
    try { return [System.Security.Cryptography.AesGcm]::new($Key, 16) }
    catch [System.Management.Automation.MethodException] { return [System.Security.Cryptography.AesGcm]::new($Key) }
}

<#
.SYNOPSIS
    Server side: encrypts a vault password for the requesting client.
.OUTPUTS
    [hashtable] envelope: @{ v; salt; nonce; ciphertext; tag } (base64 fields).
#>
function Protect-ConfigSyncCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Encrypts the plaintext the vault stores; SecureString cannot feed the cipher.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'The user is the vault lookup key bound into the key derivation, not a login pair; PSCredential does not fit an encrypt helper.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$ClientNonce,
        [Parameter(Mandatory)][string]$Password
    )
    $salt  = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    $nonce = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
    $key   = Get-ConfigSyncEnvelopeKey -Token $Token -User $User -ClientNonce $ClientNonce -Salt $salt
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $cipher = [byte[]]::new($plain.Length)
    $tag    = [byte[]]::new(16)
    $aes = New-ConfigSyncAesGcm -Key $key
    try { $aes.Encrypt($nonce, $plain, $cipher, $tag) }
    finally { $aes.Dispose(); [Array]::Clear($plain, 0, $plain.Length); [Array]::Clear($key, 0, $key.Length) }
    return @{
        v          = 1
        salt       = [Convert]::ToBase64String($salt)
        nonce      = [Convert]::ToBase64String($nonce)
        ciphertext = [Convert]::ToBase64String($cipher)
        tag        = [Convert]::ToBase64String($tag)
    }
}

<#
.SYNOPSIS
    Client side: decrypts a Protect-ConfigSyncCredential envelope. Throws on
    a wrong token or a tampered payload (GCM tag mismatch).
#>
function Unprotect-ConfigSyncCredential {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$ClientNonce,
        [Parameter(Mandatory)]$Envelope
    )
    $salt   = [Convert]::FromBase64String([string]$Envelope.salt)
    $nonce  = [Convert]::FromBase64String([string]$Envelope.nonce)
    $cipher = [Convert]::FromBase64String([string]$Envelope.ciphertext)
    $tag    = [Convert]::FromBase64String([string]$Envelope.tag)
    $key    = Get-ConfigSyncEnvelopeKey -Token $Token -User $User -ClientNonce $ClientNonce -Salt $salt
    $plain  = [byte[]]::new($cipher.Length)
    $aes = New-ConfigSyncAesGcm -Key $key
    try { $aes.Decrypt($nonce, $cipher, $tag, $plain) }
    finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
    $result = [System.Text.Encoding]::UTF8.GetString($plain)
    [Array]::Clear($plain, 0, $plain.Length)
    return $result
}

# --- REGION: Reference-host HTTP wrappers (bounded; the status server is plain HTTP)

<#
.SYNOPSIS
    Fetches the reference host's parsed test.config.yml as a hashtable via
    GET /control/test-config. Throws with a clear message when unreachable.
#>
function Get-ConfigSyncReferenceConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter()][int]$TimeoutSeconds = 15
    )
    $url = "http://${ReferenceHost}:${Port}/control/test-config"
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds
        $doc  = $resp.Content | ConvertFrom-Json -AsHashtable
    } catch {
        throw "Could not fetch the reference config from $url : $($_.Exception.Message)"
    }
    if ($doc -isnot [System.Collections.IDictionary]) {
        throw "The reference config from $url did not parse as a map."
    }
    return $doc
}

<#
.SYNOPSIS
    Fetches the reference host's networkStorage name->IP resolutions via
    GET /control/host-aliases. Returns $null when the endpoint is missing
    (older framework on the reference) or unreachable -- callers fall back
    to prompting the operator.
.DESCRIPTION
    A failure here is REPORTED, not swallowed. Every value this endpoint
    serves is one the operator would otherwise have to type in by hand, so a
    silent $null turns a serviceable reference host into an unexplained
    prompt -- the operator has no way to tell "the reference does not know
    this name" (nothing to do) from "the reference could not answer"
    (fixable, and worth fixing). The reason is surfaced as a warning and the
    caller still degrades to the prompt.
#>
function Get-ConfigSyncReferenceAliasMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter()][int]$TimeoutSeconds = 15
    )
    $url = "http://${ReferenceHost}:${Port}/control/host-aliases"
    try {
        # -SkipHttpErrorCheck: a 4xx/5xx carries the server's {"ok":false,
        # "error":...} explanation in its BODY. Letting Invoke-WebRequest throw
        # on status would discard exactly the text that tells the operator what
        # to repair on the reference host.
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    } catch {
        Write-Warning "host-aliases: $ReferenceHost is not answering ($($_.Exception.Message)). Any networkStorage name that does not resolve here has to be entered by hand."
        return $null
    }
    $doc = $null
    try { $doc = $resp.Content | ConvertFrom-Json -AsHashtable } catch { $null = $_ }
    $resolved = Resolve-ConfigSyncAliasResponse -StatusCode ([int]$resp.StatusCode) -Doc $doc -ReferenceHost $ReferenceHost
    if ($resolved.Warning) { Write-Warning $resolved.Warning }
    return $resolved.Map
}

<#
.SYNOPSIS
    Classifies a /control/host-aliases response into an alias map plus an
    optional operator warning. Pure (no I/O); the HTTP wrapper does the fetch
    and emits the warning.
.DESCRIPTION
    A non-200 or ok:false response is turned into a warning that carries the
    server's own reason, NOT a silent $null. The route 500s
    ('...not loaded in the server runspace') on a status server that started
    without its modules, and the client used to swallow that and drop straight
    to a hand-entry prompt -- hiding a one-restart fix on the reference behind
    an unexplained request for input.
.OUTPUTS
    [hashtable] @{ Map = [IDictionary] or $null; Warning = [string] or $null }.
#>
function Resolve-ConfigSyncAliasResponse {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$ReferenceHost
    )
    $isMap = $Doc -is [System.Collections.IDictionary]
    if ($StatusCode -ne 200 -or -not $isMap -or -not $Doc['ok']) {
        $reason = if ($isMap -and $Doc['error']) { [string]$Doc['error'] } else { "HTTP $StatusCode" }
        return @{ Map = $null; Warning = "host-aliases: $ReferenceHost could not supply its networkStorage name->IP map ($reason). Any name that does not resolve here has to be entered by hand; restarting the status server on $ReferenceHost (test/Start-StatusService.ps1 -Restart) usually clears this." }
    }
    $map = if ($Doc['aliases'] -is [System.Collections.IDictionary]) { $Doc['aliases'] } else { $null }
    return @{ Map = $map; Warning = $null }
}

# The IPv4-first address this host currently resolves $Name to, or '' when it
# does not resolve. Mirrors the pick order of the reference host's
# /control/host-aliases route, so the two ends are comparable and a re-run can
# tell "already correct" from "mapped to a stale address".
function Get-ConfigSyncLocalAddress {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    try {
        $addrs = @([System.Net.Dns]::GetHostAddresses($Name))
        $pick  = $addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $pick) { $pick = $addrs | Select-Object -First 1 }
        if ($pick) { return $pick.ToString() }
    } catch {
        Write-Verbose "Get-ConfigSyncLocalAddress($Name): $($_.Exception.Message)"
    }
    return ''
}

<#
.SYNOPSIS
    Fetches one vault credential from the reference host's token-gated
    GET /control/vault-credential and decrypts it locally.
.OUTPUTS
    [hashtable] @{ Ok; Password; Error } -- Error carries the reason on failure.
#>
function Request-ConfigSyncVaultCredential {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Token,
        [Parameter()][int]$TimeoutSeconds = 15
    )
    $clientNonce = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
    $proof = Get-ConfigSyncProof -Token $Token -User $User -Nonce $clientNonce
    $url = "http://${ReferenceHost}:${Port}/control/vault-credential" +
        "?user=$([uri]::EscapeDataString($User))" +
        "&nonce=$([uri]::EscapeDataString($clientNonce))" +
        "&proof=$([uri]::EscapeDataString($proof))"
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    } catch {
        return @{ Ok = $false; Password = $null; Error = "vault-credential request failed: $($_.Exception.Message)" }
    }
    $doc = $null
    try { $doc = $resp.Content | ConvertFrom-Json -AsHashtable } catch { $null = $_ }
    if ($resp.StatusCode -ne 200 -or $doc -isnot [System.Collections.IDictionary] -or -not $doc['ok']) {
        $reason = if ($doc -is [System.Collections.IDictionary] -and $doc['error']) { [string]$doc['error'] } else { "HTTP $($resp.StatusCode)" }
        return @{ Ok = $false; Password = $null; Error = "vault-credential for '$User': $reason" }
    }
    try {
        $pw = Unprotect-ConfigSyncCredential -Token $Token -User $User -ClientNonce $clientNonce -Envelope ([pscustomobject]$doc)
        return @{ Ok = $true; Password = $pw; Error = $null }
    } catch {
        return @{ Ok = $false; Password = $null; Error = "vault-credential for '$User': decrypt failed (token mismatch or tampered payload)" }
    }
}

<#
.SYNOPSIS
    Classifies a /control/vault-credential probe response into a readiness
    verdict. Pure (no I/O); the HTTP wrapper below feeds it the observed status.
.DESCRIPTION
    The route checks its preconditions in a fixed order -- user referenced by
    this host's config (404), pool-auth-token configured here (503), proof
    verifies (403), stored credential exists (404) -- so everything up to the
    proof check is observable WITHOUT the token. A deliberately wrong proof that
    comes back 403 therefore means "a correct token would have worked", which is
    the readiness signal. $StatusCode 0 denotes a transport failure (the host
    did not answer at all).
.OUTPUTS
    [hashtable] @{ Ready; Status; Error } -- Ready=$true when only the token
    stands between the caller and the password; Error is operator-actionable.
#>
function Get-ConfigSyncCredentialReadiness {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter()][AllowEmptyString()][string]$ServerError = '',
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter(Mandatory)][string]$User
    )
    switch ($StatusCode) {
        0 {
            $why = if ($ServerError) { $ServerError } else { 'no response' }
            return @{ Ready = $false; Status = 0; Error = "$ReferenceHost is not answering on the status port ($why)." }
        }
        403 {
            # Proof mismatch is the SUCCESS case for a probe: the reference holds
            # a pool-auth-token and has a credential path for this user -- the
            # only thing standing between us and the password is the right token.
            return @{ Ready = $true; Status = 403; Error = $null }
        }
        503 {
            return @{ Ready = $false; Status = 503; Error = "$ReferenceHost has no shared pool-auth-token configured, so it cannot serve credentials to a peer. Provision one on BOTH hosts (on ${ReferenceHost}: pwsh test/Set-PoolAuthToken.ps1 -Token <shared-secret> -BounceStatusServer), then re-run this sync." }
        }
        404 {
            return @{ Ready = $false; Status = 404; Error = "$ReferenceHost cannot serve the credential for '$User' ($ServerError)." }
        }
        200 {
            # Unreachable in practice (an all-zero proof cannot verify); treat a
            # 200 as a serving endpoint rather than pretending it is broken.
            return @{ Ready = $true; Status = 200; Error = $null }
        }
        default {
            $why = if ($ServerError) { $ServerError } else { "HTTP $StatusCode" }
            return @{ Ready = $false; Status = $StatusCode; Error = "$ReferenceHost could not serve credentials ($why)." }
        }
    }
}

<#
.SYNOPSIS
    Asks the reference host whether it could serve the credential for $User at
    all -- before the operator is asked for the shared token that would unlock it.
.DESCRIPTION
    Sends a deliberately wrong proof (the route rejects it at the proof check
    and never serves anything, so the probe cannot leak a credential even
    against a host that HAS the token) and hands the observed status to
    Get-ConfigSyncCredentialReadiness. This keeps the sync from begging for
    input it cannot use: a reference host with no pool-auth-token of its own can
    never serve a credential, so prompting for the token -- and then for every
    password once the operator skips it -- would demand by hand precisely the
    values this sync exists to copy.
.OUTPUTS
    [hashtable] @{ Ready; Status; Error }.
#>
function Test-ConfigSyncCredentialEndpoint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter(Mandatory)][string]$User,
        [Parameter()][int]$TimeoutSeconds = 15
    )
    $nonce = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
    $proof = [Convert]::ToBase64String([byte[]]::new(32))
    $url = "http://${ReferenceHost}:${Port}/control/vault-credential" +
        "?user=$([uri]::EscapeDataString($User))" +
        "&nonce=$([uri]::EscapeDataString($nonce))" +
        "&proof=$([uri]::EscapeDataString($proof))"
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
    } catch {
        return Get-ConfigSyncCredentialReadiness -StatusCode 0 -ServerError $_.Exception.Message -ReferenceHost $ReferenceHost -User $User
    }
    $doc = $null
    try { $doc = $resp.Content | ConvertFrom-Json -AsHashtable } catch { $null = $_ }
    $serverError = if ($doc -is [System.Collections.IDictionary] -and $doc['error']) { [string]$doc['error'] } else { '' }
    return Get-ConfigSyncCredentialReadiness -StatusCode ([int]$resp.StatusCode) -ServerError $serverError -ReferenceHost $ReferenceHost -User $User
}

# --- REGION: Side-channel reconciliation (hosts file + vault)

# Runs automation/Set-HostAlias.ps1, escalating via sudo on macOS/Linux when
# not already root (the hosts file is root-owned there; on Windows the
# per-host shell already asserts an elevated session).
function Invoke-ConfigSyncHostAlias {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$IPAddress,
        [switch]$NonInteractive
    )
    $aliasScript = Join-Path $RepoRoot 'automation/Set-HostAlias.ps1'
    if (-not (Test-Path -LiteralPath $aliasScript)) {
        Write-Warning "Set-HostAlias.ps1 not found at $aliasScript; add '$IPAddress  $Name' to the hosts file manually."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("hosts file", "Map '$Name' -> '$IPAddress'")) { return $true }
    $needsSudo = (-not $IsWindows)
    if ($needsSudo) {
        try { $needsSudo = ((& id -u 2>$null | Out-String).Trim() -ne '0') } catch { $needsSudo = $true }
    }
    try {
        if ($needsSudo) {
            $sudoArgs = @()
            if ($NonInteractive) { $sudoArgs += '-n' }   # never block on a sudo password prompt
            & sudo @sudoArgs pwsh -NoProfile -File $aliasScript -ComputerName $Name -IPAddress $IPAddress
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "sudo Set-HostAlias for '$Name' exited $LASTEXITCODE; add '$IPAddress  $Name' to /etc/hosts manually."
                return $false
            }
        } else {
            & $aliasScript -ComputerName $Name -IPAddress $IPAddress
        }
        return $true
    } catch {
        Write-Warning "Set-HostAlias for '$Name' failed: $($_.Exception.Message)"
        return $false
    }
}

# Converges every networkStorage server name in the converted config onto the
# address the REFERENCE host resolves it to: the reference is the source of
# truth for the sync, so its answer is consulted for every name, not only for
# the ones that fail to resolve here. Skipping the lookup whenever a name
# resolved locally made the sync a one-shot bootstrap -- a NAS that moved to a
# new address left a stale hosts entry that still "resolved", so no re-run could
# ever repair it, and the mounts kept failing against the old IP. Now a re-run
# rewrites a mapping that disagrees with the reference and writes nothing when
# they already agree. Operator prompt remains the last resort.
function Sync-ConfigSyncHostAlias {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$NetworkStorage,
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [switch]$NonInteractive
    )
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('poolNetworkPath', 'stashNetworkPath')) {
        $np = if ($NetworkStorage.Contains($key)) { "$($NetworkStorage[$key])".Trim() } else { '' }
        if (-not $np) { continue }
        $server = Get-PoolStorageServerName -NetworkPath $np
        if ($server -and $names -notcontains $server) { [void]$names.Add($server) }
    }
    if ($names.Count -eq 0) { return }

    $referenceAliases = Get-ConfigSyncReferenceAliasMap -ReferenceHost $ReferenceHost -Port $Port
    foreach ($name in $names) {
        $localIp = Get-ConfigSyncLocalAddress -Name $name
        $refIp   = ''
        if ($referenceAliases -is [System.Collections.IDictionary] -and $referenceAliases.Contains($name)) {
            $refIp = "$($referenceAliases[$name])".Trim()
        }

        if (-not $refIp) {
            # The reference could not name an address (endpoint unavailable, or
            # it does not resolve the name either). A working local mapping is
            # still a working local mapping -- keep it rather than re-prompting.
            if ($localIp) {
                Write-Information "networkStorage server '$name' resolves to $localIp here; the reference host did not supply an address, so the local mapping is kept." -InformationAction Continue
                continue
            }
            if ($NonInteractive) {
                Write-Warning "networkStorage server '$name' does not resolve locally and the reference host could not supply an address; add it to the hosts file manually (automation/Set-HostAlias.ps1)."
                continue
            }
            $typed = (Read-Host "networkStorage server '$name' does not resolve. IP address to map it to (Enter to skip)").Trim()
            if (-not $typed) { continue }
            $refIp = $typed
        }

        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($refIp, [ref]$parsed)) {
            Write-Warning "'$refIp' is not a valid IP address; skipping the '$name' alias."
            continue
        }
        $target = $parsed.ToString()

        if ($localIp -eq $target) {
            Write-Information "networkStorage server '$name' already resolves to $target (the reference agrees); no change." -InformationAction Continue
            continue
        }
        if ($localIp) {
            Write-Information "networkStorage server '$name' resolves to $localIp here but the reference host maps it to $target; updating the hosts entry." -InformationAction Continue
        } else {
            Write-Information "networkStorage server '$name': the reference host resolves it to $target." -InformationAction Continue
        }
        if (Invoke-ConfigSyncHostAlias -RepoRoot $RepoRoot -Name $name -IPAddress $target -NonInteractive:$NonInteractive) {
            Write-Information "hosts file: mapped '$name' -> $target." -InformationAction Continue
        }
    }
}

# Reads a secret from the console without echoing it; returns '' on Enter (skip).
function Read-ConfigSyncSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) { return '' }
    return (ConvertFrom-SecureString -SecureString $secure -AsPlainText)
}

# Converges every networkStorage user's vault entry onto the credential the
# REFERENCE host holds: fetched over the token-gated, encrypted endpoint, with
# an operator prompt only for what the reference genuinely cannot supply.
#
# Two rules earn their keep here:
#
#   * Ask the reference what it can do BEFORE asking the operator for anything.
#     The shared pool-auth-token unlocks the fetch, but a reference host that
#     has no token of its own can never serve a credential no matter what the
#     operator types -- so prompting for the token, and then for every password
#     once the operator skips it, demands by hand precisely the values this sync
#     exists to copy. The capability probe needs no token and turns that into
#     one sentence naming the fix.
#   * An existing vault entry is not a reason to stop. Skipping every user who
#     already had one made the sync a one-shot bootstrap: a NAS password rotated
#     on the reference could never reach a host that had the old one, and the
#     mount failed with a credential the sync was staring right at. The fetched
#     value is compared against the stored one and written only when they
#     differ, so a re-run converges and a no-op run writes nothing.
#
# Requires the authentication extension; degrades to warnings when it cannot be
# loaded.
function Sync-ConfigSyncVaultCredential {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$NetworkStorage,
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter()][string]$SharedToken = '',
        [switch]$NonInteractive
    )
    try {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.Extension.psm1') -Force -DisableNameChecking
        $null = Import-Extension -Area 'authentication' -RequireSingle
    } catch {
        Write-Warning "Could not load the authentication extension ($($_.Exception.Message)); skipping the vault-credential sync. Populate the vault manually (Set-Password)."
        return
    }

    $users = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('poolNetworkUser', 'stashNetworkUser')) {
        $u = if ($NetworkStorage.Contains($key)) { "$($NetworkStorage[$key])".Trim() } else { '' }
        if ($u -and $users -notcontains $u) { [void]$users.Add($u) }
    }

    # -WhatIf must not prompt either: a prompt is an operator-visible side effect,
    # and a rehearsal that stops to demand a password is not a rehearsal.
    $canPrompt = (-not $NonInteractive) -and (-not $WhatIfPreference)

    # Acquire the shared token WITHOUT prompting: an explicit -SharedToken wins,
    # else this host's own stored pool-auth-token. Prompting is deferred to the
    # point a genuinely MISSING credential needs it, so a re-run where every entry
    # is already present -- the common case -- never stops to ask for a token, yet
    # a token that is available (passed or stored) is still used to refresh a
    # rotated password silently.
    $token = $SharedToken
    if (-not $token) {
        try {
            $tm = Get-EffectiveUser -LogicalUser 'pool-auth-token'
            if ($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey)) {
                $token = Get-Password -Username 'pool-auth-token'
                Write-Information "vault: using this host's stored pool-auth-token to fetch credentials from $ReferenceHost." -InformationAction Continue
            }
        } catch { $null = $_ }
    }
    $tokenPromptTried = $false

    foreach ($user in $users) {
        $vaultKey = ''
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $user).vaultKey } catch { $null = $_ }
        $resolvedKey = if ([string]::IsNullOrWhiteSpace($vaultKey)) { $user } else { $vaultKey }
        $hasEntry = [bool](Test-VaultEntry -VaultKey $resolvedKey)

        # No shared token to fetch a possibly-rotated value with, and a working
        # entry is already here: keep it, with no network round-trip and no prompt.
        # Fetching (hence refreshing) is impossible without the token by design, so
        # there is nothing the reference could tell us that would change the outcome.
        # Pass -SharedToken (or store a pool-auth-token here) to have re-runs refresh
        # this against the reference.
        if (-not $token -and $hasEntry) {
            Write-Information "vault: '$user' has a stored credential; keeping it (no shared token available to check it against $ReferenceHost)." -InformationAction Continue
            continue
        }

        $capability = Test-ConfigSyncCredentialEndpoint -ReferenceHost $ReferenceHost -Port $Port -User $user
        $password = ''
        if ($capability.Ready) {
            # Prompt for the token only when it is needed to BOOTSTRAP a missing
            # entry -- never merely to check an existing one for rotation, which
            # would nag on every re-run. Asked once, and only when the reference
            # can actually serve (Ready), so the prompt is never a dead end.
            if (-not $token -and -not $tokenPromptTried -and -not $hasEntry -and $canPrompt) {
                $tokenPromptTried = $true
                $token = Read-ConfigSyncSecret -Prompt "Shared pool-auth-token to fetch credentials from $ReferenceHost (Enter to skip)"
            }
            if ($token) {
                $r = Request-ConfigSyncVaultCredential -ReferenceHost $ReferenceHost -Port $Port -User $user -Token $token
                if ($r.Ok) {
                    $password = $r.Password
                } else {
                    Write-Warning $r.Error
                }
            } elseif (-not $hasEntry) {
                # Serviceable, but we have no token and cannot (or were told not to)
                # get one. Only worth flagging when the entry is missing; an entry
                # that already exists is kept quietly below.
                Write-Warning "vault: $ReferenceHost can serve the '$user' credential but this host has no shared pool-auth-token to unlock it; pass -SharedToken, or provision one here (pwsh test/Set-PoolAuthToken.ps1 -Token <shared-secret>)."
            }
        } else {
            Write-Warning "vault: the '$user' credential cannot be fetched from the reference host -- $($capability.Error)"
        }

        if ($password) {
            # Get-Password AUTO-GENERATES a junk credential when the user has no
            # vault entry and an empty vaultKey, so it is only ever called behind
            # a confirmed entry.
            $current = ''
            if ($hasEntry) {
                try { $current = [string](Get-Password -Username $user) } catch { $current = '' }
            }
            if ($hasEntry -and $current -eq $password) {
                Write-Information "vault: '$user' already matches the credential on $ReferenceHost; no change." -InformationAction Continue
                continue
            }
            $action = if ($hasEntry) { 'Update' } else { 'Store' }
            if ($PSCmdlet.ShouldProcess("vault entry '$resolvedKey'", "$action the '$user' credential fetched from $ReferenceHost")) {
                Set-Password -Username $resolvedKey -NewPassword $password
                $done = if ($hasEntry) { 'updated (the reference has a newer credential)' } else { 'stored' }
                Write-Information "vault: $done the credential for '$user' (key '$resolvedKey') from $ReferenceHost." -InformationAction Continue
            }
            continue
        }

        # Nothing came back from the reference. An entry already here still works
        # -- keep it rather than making the operator retype what it holds.
        if ($hasEntry) {
            Write-Information "vault: '$user' has a stored credential and the reference host supplied nothing to replace it; keeping the local one." -InformationAction Continue
            continue
        }
        $typed = ''
        if ($canPrompt) {
            $typed = Read-ConfigSyncSecret -Prompt "Password for networkStorage user '$user' (Enter to skip)"
        }
        if (-not $typed) {
            Write-Warning "vault: no credential stored for '$user'; the networkStorage mount will stay skipped until one is set (Set-Password -Username '$resolvedKey')."
            continue
        }
        if ($PSCmdlet.ShouldProcess("vault entry '$resolvedKey'", "Store the credential for networkStorage user '$user'")) {
            Set-Password -Username $resolvedKey -NewPassword $typed
            Write-Information "vault: stored the credential for '$user' (key '$resolvedKey')." -InformationAction Continue
        }
    }
}

# --- REGION: Orchestrator

<#
.SYNOPSIS
    Copies a reference pool host's test.config.yml onto this host, converting
    host-type-specific values, then reconciles hosts-file aliases and vault
    credentials so the synced config is actually usable here.
.PARAMETER ReferenceHost
    Network name or IP address of the host to copy from (any host type).
.PARAMETER StatusPort
    The reference host's status-server port (default 8080).
.PARAMETER SharedToken
    The shared pool-auth-token value used to fetch missing vault credentials
    from the reference host. When omitted, the local vault's own
    pool-auth-token is used if configured; an interactive session prompts as
    the last resort.
.PARAMETER NonInteractive
    Never prompt: anything that would need operator input is skipped with a
    warning instead.
.PARAMETER SkipValidation
    Skip the final `pwsh test/Test-Config.ps1` run.
#>
function Sync-HostConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$StatusPort = 8080,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$SharedToken = '',
        [switch]$NonInteractive,
        [switch]$SkipValidation
    )
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $hostType = Get-HostType
    if (-not $hostType) { throw "Sync-HostConfiguration: unsupported platform." }

    Write-Information "Fetching test.config.yml from http://${ReferenceHost}:${StatusPort}/control/test-config ..." -InformationAction Continue
    $reference = Get-ConfigSyncReferenceConfig -ReferenceHost $ReferenceHost -Port $StatusPort

    $configPath = Join-Path $RepoRoot 'test/test.config.yml'
    $local = $null
    if (Test-Path -LiteralPath $configPath) {
        $local = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
    }

    $merge = Merge-ConfigSyncReferenceConfig -Reference $reference -Local $local -HostType $hostType
    foreach ($w in $merge.Warnings) { Write-Warning $w }

    $canonical = ConvertTo-SortedConfig $merge.Config
    $yaml = $canonical | ConvertTo-Yaml
    $currentYaml = if ($local) { (ConvertTo-SortedConfig $local) | ConvertTo-Yaml } else { $null }
    $wrote = $false
    $backupPath = $null
    if ($yaml -eq $currentYaml) {
        Write-Information "test.config.yml already matches the reference (after conversion); no rewrite." -InformationAction Continue
    } elseif ($PSCmdlet.ShouldProcess($configPath, "Replace with the converted config from $ReferenceHost")) {
        if ($local) {
            # Same recoverability convention as the template reconcile: the
            # pre-sync file is always one copy away.
            $backupPath = "$configPath.backup"
            Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
        }
        $wrote = [bool](Write-YurunaStateFile -Path $configPath -Content $yaml -Confirm:$false)
        if (-not $wrote) {
            throw "Sync-HostConfiguration: atomic write of $configPath failed."
        }
        $backupNote = if ($backupPath) { " (previous file backed up to $backupPath)" } else { '' }
        Write-Information "test.config.yml updated from ${ReferenceHost}${backupNote}." -InformationAction Continue
    }

    $ns = $canonical['networkStorage']
    if ($ns -is [System.Collections.IDictionary]) {
        Sync-ConfigSyncHostAlias -RepoRoot $RepoRoot -NetworkStorage $ns `
            -ReferenceHost $ReferenceHost -Port $StatusPort -NonInteractive:$NonInteractive
        Sync-ConfigSyncVaultCredential -RepoRoot $RepoRoot -NetworkStorage $ns `
            -ReferenceHost $ReferenceHost -Port $StatusPort -SharedToken $SharedToken `
            -NonInteractive:$NonInteractive

        # On Linux the poolStorage mount runs `sudo -n mount/mkdir/umount`, which
        # fails without an /etc/sudoers.d drop-in granting those NOPASSWD -- the
        # WARN the operator saw at the end of validation, after which the runner
        # buffers locally. The unattended runner cannot self-elevate, but THIS is
        # an interactive operator session, so offer to install the drop-in now
        # (one sudo prompt) rather than let the mount fail. Idempotent (a no-op
        # when already configured), Linux-only (macOS mounts via mount_smbfs -N and
        # Windows via SMB mappings need no sudo), and gated on a configured mount.
        $needsMount = $false
        foreach ($k in @('poolNetworkPath', 'stashNetworkPath')) {
            if ($ns.Contains($k) -and -not [string]::IsNullOrWhiteSpace("$($ns[$k])")) { $needsMount = $true; break }
        }
        if ($needsMount -and $IsLinux -and -not $WhatIfPreference -and (Get-Command Set-PoolStorageSudoers -ErrorAction SilentlyContinue)) {
            $sudo = Set-PoolStorageSudoers -NonInteractive:$NonInteractive
            switch ($sudo.Action) {
                'installed' { Write-Information "poolStorage: $($sudo.Message)" -InformationAction Continue }
                'present'   { Write-Information "poolStorage: $($sudo.Message)" -InformationAction Continue }
                'skipped'   { Write-Warning $sudo.Message }
                'failed'    { Write-Warning "poolStorage: $($sudo.Message)" }
                default     { Write-Verbose "poolStorage sudoers: $($sudo.Action) -- $($sudo.Message)" }
            }
        }
    }

    $validationExit = $null
    if (-not $SkipValidation -and -not $WhatIfPreference) {
        Write-Information "Validating the synced config (test/Test-Config.ps1) ..." -InformationAction Continue
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'test/Test-Config.ps1')
        $validationExit = $LASTEXITCODE
        if ($validationExit -ne 0) {
            Write-Warning "Test-Config.ps1 reported failures (exit $validationExit); review its output above."
        }
    }

    return [pscustomobject]@{
        Wrote          = $wrote
        BackupPath     = $backupPath
        Warnings       = $merge.Warnings
        ValidationExit = $validationExit
    }
}

# Byte-offset tail of a file another process is still writing. Returns the lines
# appended since $Offset plus the new offset, so a caller can poll it in a loop
# to stream a live transcript. FileShare ReadWrite+Delete because the writer
# holds the file open; a trailing fragment with no newline yet is left in place
# rather than emitted as half a line, and the offset is always counted from the
# UNTRIMMED text so a stripped BOM cannot desynchronize it.
function Get-BounceLogDelta {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0
    )
    $result = @{ Offset = $Offset; Lines = @() }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    } catch {
        Write-Debug "bounce transcript not readable yet: $($_.Exception.Message)"
        return $result
    }
    try {
        if ($stream.Length -lt $Offset) { $Offset = 0 }   # writer truncated/rotated it
        $pending = $stream.Length - $Offset
        if ($pending -le 0) { return $result }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new($pending)
        $read   = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $result }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $cut  = $text.LastIndexOf("`n")
        if ($cut -lt 0) { return $result }
        $complete = $text.Substring(0, $cut + 1)
        $result.Offset = $Offset + [System.Text.Encoding]::UTF8.GetByteCount($complete)
        $result.Lines  = @($complete.TrimStart([char]0xFEFF) -split "`r?`n" | Where-Object { $_ -ne '' })
    } finally {
        $stream.Dispose()
    }
    return $result
}

# Run Start-StatusService.ps1 -Restart in a child pwsh, streaming its output back
# as it lands, WITHOUT handing that child -- or the status server it detaches --
# a handle to any pipe this process is reading.
#
# On Windows the spawn shape below is load-bearing: adding -Redirect* or
# -NoNewWindow here turns on handle inheritance, the detached status server
# inherits and pins the caller's stdout pipe, and the bounce hangs silently and
# unboundedly. Full trap description and why file redirection does not fix it:
# docs/workarounds.md#a-detached-grandchild-pins-the-callers-pipe-on-windows
# (also captured in feedback_windows-detached-grandchild-pins-pipe.md).
function Invoke-StatusServiceBounce {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PwshExe,
        [Parameter(Mandatory)][string]$StartScript,
        [ValidateRange(10, 900)][int]$TimeoutSeconds = 180
    )
    $logPath = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-status-bounce-$PID.log"
    $result  = @{ ok = $false; exitCode = -1; timedOut = $false; logPath = $logPath }
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    # '' escapes an embedded quote so a path with an apostrophe survives the
    # child's re-parse of this command string.
    $inner = "& '{0}' -Restart *>&1 | Tee-Object -FilePath '{1}'" -f `
        ($StartScript -replace "'", "''"), ($logPath -replace "'", "''")
    $spawn = @{
        FilePath     = $PwshExe
        ArgumentList = @('-NoProfile', '-NonInteractive', '-Command', $inner)
        PassThru     = $true
    }
    if ($IsWindows) {
        $spawn.WindowStyle = 'Hidden'
    } else {
        $spawn.RedirectStandardOutput = "$logPath.out"
        $spawn.RedirectStandardError  = "$logPath.err"
    }
    $proc = $null
    try {
        $proc = Start-Process @spawn
    } catch {
        Write-Warning "Status-server bounce could not start: $($_.Exception.Message)"
        return $result
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $offset   = [long]0
    $exited   = $false
    while (-not $exited) {
        # WaitForExit(ms) waits on THIS process only. Start-Process -Wait would
        # instead wait on the whole descendant tree -- which includes the status
        # server -- and reintroduce the unbounded wait from the other direction.
        $exited = $proc.WaitForExit(500)
        $delta  = Get-BounceLogDelta -Path $logPath -Offset $offset
        $offset = $delta.Offset
        foreach ($line in $delta.Lines) {
            Write-Information "        $line" -InformationAction Continue
        }
        if (-not $exited -and [DateTime]::UtcNow -ge $deadline) {
            # Left running on purpose: it may be mid-launch, and a tree kill here
            # would take down the very server it is bringing up.
            $result.timedOut = $true
            return $result
        }
    }
    $result.exitCode = [int]$proc.ExitCode
    $result.ok       = ($result.exitCode -eq 0)
    return $result
}

<#
.SYNOPSIS
    Provision THIS host as a holder of the shared pool-auth-token (idempotent).
.DESCRIPTION
    The shared pool-auth-token gates cross-host config-sync AND the
    status-server control routes (the deep-link control proofs the pool
    aggregator mints). Storing it needs two coupled writes that are easy to
    get subtly wrong by hand:

      1. users.yml -- pool-auth-token.vaultKey must be NON-EMPTY (an empty
         vaultKey routes Get-Password down the auto-generate path, which the
         gate rejects) AND must EQUAL the -Username Set-Password writes
         under. Set-Password keys the vault by -Username; the gate resolves
         the slot by vaultKey. A mismatch (the classic dash-vs-dot slip)
         stores the token under one key and reads another -> a silent 403.
         This sets both to the logical name, closing that class by
         construction.
      2. vault.yml -- the token itself, via Set-Password.

    Verifies the round-trip through the SAME resolution the gate uses, and
    optionally restarts the status server (in an isolated child pwsh) so the
    running process re-reads users.yml now instead of next cycle --
    Import-Extension skips re-import once loaded, so the edit is otherwise
    invisible to the live server. Each step is announced on the Information
    stream, and the bounce streams the child's transcript through as it runs.
    Returns @{ ok; vaultKey; keyChanged; verified; bounced; bounceLog }.

    Requires the authentication extension loaded (Set-Password et al.).
#>
function Set-PoolAuthToken {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$BounceStatusServer,
        [ValidateRange(10, 900)][int]$BounceTimeoutSeconds = 180
    )
    $logical = 'pool-auth-token'
    foreach ($fn in @('Set-UserVaultKey', 'Set-Password', 'Get-Password', 'Test-VaultEntry', 'Get-EffectiveUser', 'Reset-UsersConfigCache')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Set-PoolAuthToken requires the authentication extension: '$fn' is not available. Import test/extension/authentication/default.psm1 first."
        }
    }
    $result = @{ ok = $false; vaultKey = $logical; keyChanged = $false; verified = $false; bounced = $false; bounceLog = $null }
    if (-not $PSCmdlet.ShouldProcess("host vault ($logical)", 'Provision shared pool-auth-token')) {
        return $result
    }
    # Each step is announced on the Information stream before it runs. The vault
    # writes are sub-second, but the status-server bounce routinely takes tens of
    # seconds (port map + readiness wait), and a silent script in that window is
    # indistinguishable from a wedged one -- the operator needs to see which step
    # owns the wait.
    $steps = if ($BounceStatusServer) { 4 } else { 3 }

    # vaultKey == the logical name so Set-Password's -Username and the gate's
    # vaultKey resolution address the identical vault slot.
    Write-Information "[1/$steps] users.yml: pointing logical user '$logical' at vault key '$logical' ..." -InformationAction Continue
    $result.keyChanged = [bool](Set-UserVaultKey -LogicalUser $logical -VaultKey $logical)
    $keyNote = if ($result.keyChanged) { 'vaultKey updated' } else { 'vaultKey already correct, file unchanged' }
    Write-Information "[1/$steps] users.yml: $keyNote." -InformationAction Continue

    Write-Information "[2/$steps] vault: storing the shared token under '$logical' ..." -InformationAction Continue
    $null = Set-Password -Username $logical -NewPassword $Token
    $null = Reset-UsersConfigCache -Confirm:$false
    Write-Information "[2/$steps] vault: token stored." -InformationAction Continue

    Write-Information "[3/$steps] vault: verifying the round-trip through the same resolution the control gate uses ..." -InformationAction Continue
    $tm = Get-EffectiveUser -LogicalUser $logical
    $result.verified = [bool]($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey) -and ((Get-Password -Username $logical) -eq $Token))
    $verifyNote = if ($result.verified) { 'round-trip verified' } else { 'round-trip FAILED -- the token cannot be read back' }
    Write-Information "[3/$steps] vault: $verifyNote." -InformationAction Continue

    if ($BounceStatusServer) {
        $startScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-StatusService.ps1'
        $pwshExe = [System.Environment]::ProcessPath
        if ((Test-Path -LiteralPath $startScript) -and $pwshExe -and (Test-Path -LiteralPath $pwshExe)) {
            Write-Information "[4/$steps] status server: restarting so the running process re-reads users.yml now (up to ${BounceTimeoutSeconds}s) ..." -InformationAction Continue
            $bounce = Invoke-StatusServiceBounce -PwshExe $pwshExe -StartScript $startScript -TimeoutSeconds $BounceTimeoutSeconds
            $result.bounced   = $bounce.ok
            $result.bounceLog = $bounce.logPath
            if ($bounce.ok) {
                Write-Information "[4/$steps] status server: restarted." -InformationAction Continue
            } elseif ($bounce.timedOut) {
                Write-Warning "Status-server bounce is still running after ${BounceTimeoutSeconds}s; it was left alone (killing it would take the server down with it). Transcript: $($bounce.logPath). The token is stored and takes effect at the next cycle."
            } else {
                Write-Warning "Status-server bounce exited $($bounce.exitCode) (transcript: $($bounce.logPath)); the token is stored and takes effect at the next cycle."
            }
        } else {
            Write-Warning "Cannot bounce the status server (Start-StatusService.ps1 or the pwsh executable was not found); the token is stored and takes effect at the next cycle."
        }
    }
    $result.ok = [bool]$result.verified
    return $result
}

Export-ModuleMember -Function `
    Get-ConfigSyncLocalPathDefault, Convert-ConfigSyncNetworkStorage, Merge-ConfigSyncReferenceConfig, `
    Get-ConfigSyncProof, Test-ConfigSyncProof, Get-YurunaControlProof, Test-YurunaControlProof, Protect-ConfigSyncCredential, Unprotect-ConfigSyncCredential, `
    Get-ConfigSyncReferenceConfig, Get-ConfigSyncReferenceAliasMap, Resolve-ConfigSyncAliasResponse, `
    Request-ConfigSyncVaultCredential, Test-ConfigSyncCredentialEndpoint, Get-ConfigSyncCredentialReadiness, `
    Sync-HostConfiguration, Set-PoolAuthToken
