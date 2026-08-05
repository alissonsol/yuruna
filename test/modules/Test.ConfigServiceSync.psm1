<#PSScriptInfo
.VERSION 2026.08.05
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
    status service (GET /control/test-config, JSON), converts those values
    for the local host type, preserves the local 'secrets' node, and then
    reconciles the two side channels the config depends on:

      * hosts-file aliases -- a networkStorage server name that does not
        resolve locally is looked up on the reference host
        (GET /control/host-aliases) and written via
        automation/Set-HostAlias.ps1 (operator prompt as fallback);
      * vault credentials -- a networkStorage user with no local vault
        entry is fetched from the reference host's
        GET /control/vault-credential, which is gated by the shared
        lab-auth-token and returns the password encrypted with a key
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
# Get-SudoPwshArgumentList (the nested-sudo argument vector) lives here.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking

# One version string binds the HMAC proof, the HKDF key derivation, and the
# envelope shape together: bumping it invalidates every older client/server
# pairing at once instead of failing open on a partial mismatch.
$script:ConfigSyncCredentialLabel = 'yuruna-config-sync|v1'

# Pinned to the aggregator's sealLabToken (Go). The label is the AEAD's
# associated data; the iteration count is sized for the 6-character lab
# connection token, which is weak enough that a captured envelope has to stay
# expensive to attack offline. Deriving happens once per enrollment, never on a
# refused attempt.
$script:LabTokenEnvelopeLabel      = 'yuruna-lab-token|v1'
$script:LabTokenEnvelopeIterations = 600000

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
        $npKey = "${tier}StorageNetworkPath"; $nuKey = "${tier}StorageNetworkUser"; $lpKey = "${tier}StorageLocalPath"
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
        [Parameter(Mandatory)][string]$HostType,
        # Strip the pool-membership nodes (pool + networkStorage) so a host can
        # sync a reference config WITHOUT joining the pool: no NAS mount, no cycle
        # replication, and thus no hosts/info.<hostId>.yml identity record on the
        # share. vmStart / repositories (incl. the caching-proxy service) are untouched,
        # so cache reuse still works. For disposable / self-verification hosts
        # (e.g. example/nested.host) whose ephemeral hostId would otherwise
        # register a new dead entry in the pool set on every run.
        [switch]$NoPool
    )
    if ($Reference -isnot [System.Collections.IDictionary]) {
        throw "Merge-ConfigSyncReferenceConfig: the reference config is not a map (got $($Reference.GetType().Name))."
    }
    $warnings = [System.Collections.Generic.List[string]]::new()
    # The reference dictionary is a per-call parse owned by this sync; it is
    # mutated in place rather than deep-copied.
    $merged = $Reference

    if ($NoPool) {
        # Drop the pool-membership nodes outright. The pool.localClonePath block
        # further down is a no-op once 'pool' is gone (it guards on Contains).
        foreach ($poolKey in @('networkStorage', 'pool')) {
            if ($merged.Contains($poolKey)) {
                $merged.Remove($poolKey)
                [void]$warnings.Add("${poolKey}: dropped (-NoPool) -- config synced without pool membership; this host will not mount the NAS, replicate cycles, or register in the pool set.")
            }
        }
    } else {
        $localNs = $null
        if ($Local -is [System.Collections.IDictionary] -and $Local.Contains('networkStorage')) {
            $localNs = $Local['networkStorage']
        }
        $refNs = if ($merged.Contains('networkStorage')) { $merged['networkStorage'] } else { $null }
        $conv  = Convert-ConfigSyncNetworkStorage -Reference $refNs -Local $localNs -HostType $HostType
        $merged['networkStorage'] = $conv.NetworkStorage
        foreach ($w in $conv.Warnings) { [void]$warnings.Add($w) }
    }

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
# Both ends hold the shared lab-auth-token; nothing else is shared.
# The request carries an HMAC proof-of-knowledge (the token itself never
# crosses the wire) and the response password is AES-256-GCM encrypted with
# an HKDF key derived from token + a fresh per-response salt, with the user
# and the client's nonce bound into the derivation -- a captured response
# cannot be decrypted without the token nor replayed for a different user.
# The status service is plain HTTP on a trusted LAN; this keeps the secret
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
    lab-auth-token, bound to the requested user and the client nonce.
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
    Mint the wire proof the status service's mutating /control/* routes accept:
    "<expiryUnixSeconds>.<base64 HMAC>". The pool-aggregator service's /go/host mints the
    identical value in Go so a Grafana deep-link can carry it to the browser UI.
.DESCRIPTION
    proof = base64( HMAC-SHA256(lab-auth-token, "yuruna-control|proof|<expiry>") ).
    Bound to the expiry only: the lab-auth-token is pool-wide, so a valid proof means
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
    A non-secret tag identifying WHICH lab-auth-token this host holds:
    base64( HMAC-SHA256(lab-auth-token, "yuruna-control|tag|v1") ).
.DESCRIPTION
    Answers "does this host share the proxy's token?" without either end
    disclosing the token. The host publishes the tag on the open
    /control/control-status route; the pool-aggregator service computes the same
    tag over ITS token and compares, which is what drives the dashboard's
    Control column. Equal tags mean a control proof minted by that proxy will
    verify here; unequal means it will not (the usual cause is a host enrolled
    against a proxy that has since been rebuilt with a new token).

    The data string is a FIXED constant whose label segment is "tag", never
    "proof". Get-YurunaControlProof signs "yuruna-control|proof|<expiry>", so no
    expiry can ever produce this message and reading the tag does not help forge
    a proof. The tag is likewise not a hash OF the token -- recovering the token
    from it means guessing the token itself, and the proxy build mints 24 random
    bytes (New-VM.ps1 for guest.caching-proxy-service).
#>
function Get-YurunaControlTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # AllowEmptyString so the route can call this with whatever it read from
        # the vault; a host holding no token gets '' back, not a binding throw.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
    return [Convert]::ToBase64String((Get-ConfigSyncHmac -Token $Token -Data 'yuruna-control|tag|v1'))
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
        # AllowEmptyString: the server gate calls this with whatever lab-auth-token it
        # read -- possibly empty on a host that has none -- and must get $false, not a
        # binding throw that would break the route.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Wire,
        # Held strictly ABOVE the aggregator's 15-minute mint. There is no skew
        # grace on this window, so an equal bound would reject a freshly minted
        # proof on any host whose clock trails the proxy; the surplus is that
        # tolerance, not a longer replay window (the minted expiry still governs).
        [int]$MaxTtlSeconds = 1200
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

# --- REGION: Reference-host HTTP wrappers (bounded; the status service is plain HTTP)

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
    ('...not loaded in the server runspace') on a status service that started
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
        return @{ Map = $null; Warning = "host-aliases: $ReferenceHost could not supply its networkStorage name->IP map ($reason). Any name that does not resolve here has to be entered by hand; restarting the status service on $ReferenceHost (test/Start-StatusService.ps1 -Restart) usually clears this." }
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
    this host's config (404), lab-auth-token configured here (503), proof
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
            # a lab-auth-token and has a credential path for this user -- the
            # only thing standing between us and the password is the right token.
            return @{ Ready = $true; Status = 403; Error = $null }
        }
        503 {
            return @{ Ready = $false; Status = 503; Error = "$ReferenceHost has no shared lab-auth-token configured, so it cannot serve credentials to a peer. Enroll BOTH hosts with the Lab token shown on the Yuruna hosts dashboard (on ${ReferenceHost}: pwsh test/Set-LabToken.ps1 -LabToken <dashboard-code> -BounceStatusService), then re-run this sync." }
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
    input it cannot use: a reference host with no lab-auth-token of its own can
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
            # -n (never block on a password prompt) and, on macOS, -E: a Homebrew
            # PowerShell cannot start under sudo's stripped environment and exits
            # 131 before reading the script. See Get-SudoPwshArgumentList.
            $sudoArgs = Get-SudoPwshArgumentList -ScriptPath $aliasScript `
                -ScriptArgument @('-ComputerName', $Name, '-IPAddress', $IPAddress) `
                -NonInteractive:$NonInteractive
            & sudo @sudoArgs
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
# resolves locally would make the sync a one-shot bootstrap: a NAS that moved to
# a new address leaves a stale hosts entry that still "resolves", so no re-run
# could ever repair it and the mounts would keep failing against the old IP. A
# re-run therefore rewrites a mapping that disagrees with the reference and
# writes nothing when they already agree. Operator prompt remains the last resort.
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
    foreach ($key in @('poolStorageNetworkPath', 'stashStorageNetworkPath')) {
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

# --- REGION: https://yuruna.link/memory#why-the-networkstorage-vault-sync-probes-before-prompting-and-rewrites-on-drift
# Converges every networkStorage user's vault entry onto the reference host's
# credential: probe before prompting, and rewrite on drift so re-runs converge.
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
    foreach ($key in @('poolStorageNetworkUser', 'stashStorageNetworkUser')) {
        $u = if ($NetworkStorage.Contains($key)) { "$($NetworkStorage[$key])".Trim() } else { '' }
        if ($u -and $users -notcontains $u) { [void]$users.Add($u) }
    }

    # -WhatIf must not prompt either: a prompt is an operator-visible side effect,
    # and a rehearsal that stops to demand a password is not a rehearsal.
    $canPrompt = (-not $NonInteractive) -and (-not $WhatIfPreference)

    # Acquire the shared token WITHOUT prompting: an explicit -SharedToken wins,
    # else this host's own stored lab-auth-token. Prompting is deferred to the
    # point a genuinely MISSING credential needs it, so a re-run where every entry
    # is already present -- the common case -- never stops to ask for a token, yet
    # a token that is available (passed or stored) is still used to refresh a
    # rotated password silently.
    $token = $SharedToken
    if (-not $token) {
        $token = Get-LabAuthTokenValue
        if ($token) {
            Write-Information "vault: using this host's stored lab-auth-token to fetch credentials from $ReferenceHost." -InformationAction Continue
        }
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
        # Pass -SharedToken (or store a lab-auth-token here) to have re-runs refresh
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
                $token = Read-ConfigSyncSecret -Prompt "Shared lab-auth-token to fetch credentials from $ReferenceHost (Enter to skip)"
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
                Write-Warning "vault: $ReferenceHost can serve the '$user' credential but this host has no shared lab-auth-token to unlock it; pass -SharedToken, or enroll this host with the dashboard's Lab token (pwsh test/Set-LabToken.ps1 -LabToken <dashboard-code>)."
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
    The reference host's status-service port (default 8080).
.PARAMETER SharedToken
    The shared lab-auth-token value used to fetch missing vault credentials
    from the reference host. When omitted, the local vault's own
    lab-auth-token is used if configured; an interactive session prompts as
    the last resort.
.PARAMETER NonInteractive
    Never prompt: anything that would need operator input is skipped with a
    warning instead.
.PARAMETER SkipValidation
    Skip the final `pwsh test/Test-Config.ps1` run.
.PARAMETER NoPool
    Sync the reference config but DO NOT join the pool: the pool + networkStorage
    nodes are dropped, so this host never mounts the NAS, replicates cycles, or
    registers a hosts/info.<hostId>.yml identity record. The caching-proxy service and
    repository settings still come across, so cache reuse is unaffected. Use for
    disposable / self-verification hosts (e.g. example/nested.host).
#>
<#
.SYNOPSIS
    Compare a reference host's config against THIS host's template schema.
.DESCRIPTION
    The reference host is another machine running its own checkout, which may be
    behind this one: it can lack keys the current schema defines, still spell keys
    that were retired, or carry keys the schema dropped. Copying such a config
    across propagates a half-migrated file onto this host, where the missing keys
    silently take their defaults -- so the sync asks before doing it.
    Comparison is against the LOCAL template, which is the schema source of truth.
.OUTPUTS
    [pscustomobject] IsCurrent [bool], Missing [string[]], Retired [string[]],
    Unknown [string[]], Checked [bool].
#>
function Test-ConfigSyncReferenceFreshness {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Reference,
        [Parameter(Mandatory)][string]$TemplatePath
    )

    $result = [pscustomobject]@{
        IsCurrent = $true; Missing = @(); Retired = @(); Unknown = @(); Checked = $false
    }
    if (-not (Test-Path -LiteralPath $TemplatePath)) { return $result }

    $template  = Get-Content -Raw -LiteralPath $TemplatePath | ConvertFrom-Yaml -Ordered
    $tplLeaves = Get-ConfigLeafValue -Config $template
    $refLeaves = Get-ConfigLeafValue -Config (Copy-HashtableWithoutSecretNode $Reference)

    $missing = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $tplLeaves.Keys) { if (-not $refLeaves.Contains($p)) { [void]$missing.Add($p) } }
    foreach ($p in $refLeaves.Keys) { if (-not $tplLeaves.Contains($p)) { [void]$unknown.Add($p) } }

    # Retired spellings are a stronger signal than a plain unknown key: the value
    # is real but parked under a name nothing reads any more.
    $retired = [System.Collections.Generic.List[string]]::new()
    $namingMod = Join-Path $PSScriptRoot 'Test.ConfigNaming.psm1'
    if ((Test-Path -LiteralPath $namingMod) -and -not (Get-Command Get-RetiredConfigKeyMap -ErrorAction SilentlyContinue)) {
        Import-Module $namingMod -Force -DisableNameChecking
    }
    if (Get-Command Get-RetiredConfigKeyMap -ErrorAction SilentlyContinue) {
        # ORDINAL, not the dictionary's own lookup: PowerShell dictionaries compare
        # keys case-insensitively, so `Contains('vmStart.cachingProxyIP')` is true
        # for the CURRENT key `vmStart.cachingProxyIp` and every clean reference
        # would be reported stale. The acronym-only renames are exactly the ones
        # that need case to tell old from new (same note as Test.ConfigNaming's
        # case-sensitive line scanner).
        $refPaths = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($refLeaves.Keys), [StringComparer]::Ordinal)
        $map = Get-RetiredConfigKeyMap
        foreach ($old in $map.Keys) {
            if ($refPaths.Contains([string]$old)) { [void]$retired.Add("$old -> $($map[$old].New)") }
        }
    }

    $result.Missing   = [string[]]@($missing | Sort-Object)
    $result.Retired   = [string[]]@($retired | Sort-Object)
    $result.Unknown   = [string[]]@($unknown | Sort-Object)
    $result.Checked   = $true
    $result.IsCurrent = ($missing.Count -eq 0 -and $retired.Count -eq 0 -and $unknown.Count -eq 0)
    return $result
}

<#
.SYNOPSIS
    Copies test.config.yml from a reference host's status service onto this host,
    converting it to this host's platform and schema on the way.

.DESCRIPTION
    The reference host is the source of truth: its config is fetched over HTTP
    from /control/test-config, merged onto this host's template, backed up, and
    written to test/test.config.yml.

    Before anything is written the reference is checked against this checkout's
    template. Copying from a host that is behind the current schema lands a
    half-migrated config -- keys the reference lacks fall back to template
    defaults and keys it still spells the retired way are read by nothing -- so a
    stale reference stops the run and asks, rather than surfacing at the next
    cycle as an unexplained default.

.PARAMETER ReferenceHost
    Host name or IP whose status service serves the config to copy.

.PARAMETER StatusPort
    Status-service port on the reference host.

.PARAMETER RepoRoot
    Repository root to write into. Defaults to the checkout this module lives in.

.PARAMETER SharedToken
    Lab auth token for the fetch. Empty means read it from local config.

.PARAMETER NonInteractive
    Never prompt. A stale reference throws instead of asking, so a scripted run
    fails with a message rather than stalling on a prompt nobody can answer.

.PARAMETER SkipValidation
    Skip the test/Test-Config.ps1 pass over the freshly written config.

.PARAMETER NoPool
    Leave the pool-storage keys and their sudoers drop-in alone.

.PARAMETER AllowStaleReference
    Accept a reference host that is behind this host's schema without asking.
    This is the bypass for the freshness prompt -- see the note on ShouldContinue
    at the gate itself.

.OUTPUTS
    [pscustomobject] Wrote, BackupPath, Warnings, ValidationExit.
#>
function Sync-HostConfiguration {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidShouldContinueWithoutForce', '',
        Justification = 'The bypass exists, it is just not spelled -Force: -AllowStaleReference is what answers this prompt unattended, and -NonInteractive turns it into a throw. A second switch meaning the same thing would leave callers guessing which one the gate reads.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$StatusPort = 8080,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$SharedToken = '',
        [switch]$NonInteractive,
        [switch]$SkipValidation,
        [switch]$NoPool,
        # Copy from a reference host whose config is behind this host's schema
        # without asking. For scripted syncs that have already accepted the drift.
        [switch]$AllowStaleReference
    )
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $hostType = Get-HostType
    if (-not $hostType) { throw "Sync-HostConfiguration: unsupported platform." }

    Write-Information "Fetching test.config.yml from http://${ReferenceHost}:${StatusPort}/control/test-config ..." -InformationAction Continue
    $reference = Get-ConfigSyncReferenceConfig -ReferenceHost $ReferenceHost -Port $StatusPort

    # --- REGION: Reference freshness gate
    # Copying from a host that is behind this checkout's schema silently lands a
    # half-migrated config here: keys the reference lacks fall back to template
    # defaults, and keys it still spells the retired way are read by nothing. Say
    # so and ask before overwriting, rather than discovering it at the next cycle.
    $freshness = Test-ConfigSyncReferenceFreshness `
        -Reference $reference -TemplatePath (Join-Path $RepoRoot 'test/test.config.yml.template')
    if ($freshness.Checked -and -not $freshness.IsCurrent) {
        $detail = [System.Collections.Generic.List[string]]::new()
        if ($freshness.Retired.Count -gt 0) {
            [void]$detail.Add("  Retired key names still in use on ${ReferenceHost} ($($freshness.Retired.Count)):")
            foreach ($r in $freshness.Retired) { [void]$detail.Add("    - $r") }
        }
        if ($freshness.Missing.Count -gt 0) {
            [void]$detail.Add("  Keys this host's schema defines that ${ReferenceHost} does NOT have ($($freshness.Missing.Count)) -- they will take template defaults:")
            foreach ($m in $freshness.Missing) { [void]$detail.Add("    - $m") }
        }
        if ($freshness.Unknown.Count -gt 0) {
            [void]$detail.Add("  Keys on ${ReferenceHost} that this host's schema no longer defines ($($freshness.Unknown.Count)) -- they will be dropped:")
            foreach ($u in $freshness.Unknown) { [void]$detail.Add("    - $u") }
        }
        $summary = "Reference host ${ReferenceHost} is NOT up to date with this host's test.config.yml.template:`n" +
                   ($detail -join "`n") +
                   "`n  Fix at the source: run 'pwsh tools/Update-TestConfigNaming.ps1' then 'pwsh test/Test-Config.ps1' on ${ReferenceHost}, then re-run this sync."
        Write-Warning $summary
        if ($AllowStaleReference) {
            Write-Warning "Proceeding anyway (-AllowStaleReference)."
        } elseif ($NonInteractive) {
            throw "Sync-HostConfiguration: refusing to copy a stale config from ${ReferenceHost} in -NonInteractive mode. Re-run with -AllowStaleReference to accept the drift, or bring the reference host up to date first."
        } elseif (-not $PSCmdlet.ShouldContinue(
                    "Copy this partially-migrated configuration onto this host anyway?",
                    "Reference host $ReferenceHost is not up to date")) {
            throw "Sync-HostConfiguration: cancelled -- ${ReferenceHost} is not up to date."
        }
    } elseif ($freshness.Checked) {
        Write-Information "Reference config from ${ReferenceHost} matches this host's schema." -InformationAction Continue
    }

    $configPath = Join-Path $RepoRoot 'test/test.config.yml'
    $local = $null
    if (Test-Path -LiteralPath $configPath) {
        $local = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
    }

    $merge = Merge-ConfigSyncReferenceConfig -Reference $reference -Local $local -HostType $hostType -NoPool:$NoPool
    foreach ($w in $merge.Warnings) { Write-Warning $w }

    $canonical = ConvertTo-SortedConfig $merge.Config
    # Render through the documented writer so a synced config arrives carrying the
    # template's per-knob comments, exactly like a locally reconciled one.
    $templatePath = Join-Path $RepoRoot 'test/test.config.yml.template'
    $yaml = if (Test-Path -LiteralPath $templatePath) {
        ConvertTo-DocumentedConfigYaml `
            -TemplateText ([string](Get-Content -Raw -LiteralPath $templatePath)) -Config $canonical
    } else { $canonical | ConvertTo-Yaml }
    $currentYaml = if (Test-Path -LiteralPath $configPath) { [string](Get-Content -Raw -LiteralPath $configPath) } else { $null }
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
        foreach ($k in @('poolStorageNetworkPath', 'stashStorageNetworkPath')) {
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
# as it lands, WITHOUT handing that child -- or the status service it detaches --
# a handle to any pipe this process is reading.
#
# On Windows the spawn shape below is load-bearing: adding -Redirect* or
# -NoNewWindow here turns on handle inheritance, the detached status service
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
    Read this host's stored shared lab-auth-token, or '' when none is set.
.DESCRIPTION
    Resolves the 'lab-auth-token' vault entry through the same
    users.yml-vaultKey indirection the control gate uses, falling back to the
    legacy 'pool-auth-token' logical name so a host whose vault was
    provisioned under that name keeps verifying proofs and fetching
    credentials without re-enrollment. Never calls Get-Password without a
    confirmed vault entry (an unpopulated user would auto-generate a junk
    credential). Requires the authentication extension loaded; returns ''
    when it is not.
#>
function Get-LabAuthTokenValue {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($logical in @('lab-auth-token', 'pool-auth-token')) {
        try {
            if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue)) { return '' }
            $tm = Get-EffectiveUser -LogicalUser $logical
            if ($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey)) {
                return [string](Get-Password -Username $logical)
            }
        } catch { $null = $_ }
    }
    return ''
}

<#
.SYNOPSIS
    Classifies a POST /api/v1/lab-token exchange response into an operator
    verdict. Pure (no I/O); the HTTP wrapper below feeds it the observed
    status.
.DESCRIPTION
    The aggregator answers 200 with the shared token sealed under the redeemed
    code for a redeemable code, 400 for a malformed one, 403 for an
    unknown/expired one, 429 when the caller's address burned its
    failed-attempt budget, and 503 when the exchange is disabled (rotation off,
    or the proxy holds no lab-auth-token). $StatusCode 0 denotes a transport
    failure (the aggregator did not answer); the caller passes the token it
    managed to open, so an envelope that would not unseal arrives here as an
    empty -Token and is refused.
.OUTPUTS
    [hashtable] @{ Ok; Token; Status; Error } -- Error is operator-actionable.
#>
function Get-LabTokenExchangeVerdict {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter()][AllowEmptyString()][string]$Token = '',
        [Parameter()][AllowEmptyString()][string]$ServerError = '',
        [Parameter(Mandatory)][string]$AggregatorUrl
    )
    switch ($StatusCode) {
        200 {
            if ([string]::IsNullOrWhiteSpace($Token)) {
                return @{ Ok = $false; Token = ''; Status = 200; Error = "$AggregatorUrl answered the exchange but the reply did not unseal with this Lab token. Either the reply came from something other than the lab's aggregator, or the code was consumed against a different proxy; read the current code off the Yuruna hosts dashboard and re-run." }
            }
            return @{ Ok = $true; Token = $Token; Status = 200; Error = $null }
        }
        0 {
            $why = if ($ServerError) { $ServerError } else { 'no response' }
            return @{ Ok = $false; Token = ''; Status = 0; Error = "$AggregatorUrl is not answering ($why). Check the caching-proxy-service address and that the pool-aggregator service is running on it." }
        }
        403 {
            return @{ Ok = $false; Token = ''; Status = 403; Error = "The Lab token was not accepted by $AggregatorUrl -- it rotates every minute, so read the CURRENT code off the Yuruna hosts dashboard and re-run right away." }
        }
        429 {
            return @{ Ok = $false; Token = ''; Status = 429; Error = "$AggregatorUrl throttled this host after too many failed attempts. Wait a few minutes, read a fresh Lab token off the dashboard, and re-run." }
        }
        503 {
            return @{ Ok = $false; Token = ''; Status = 503; Error = "$AggregatorUrl has the lab-token exchange disabled (rotation off, or the proxy holds no lab-auth-token). Rebuild the caching-proxy service from a host that holds the token, or check the pool-aggregator service flags." }
        }
        default {
            $why = if ($ServerError) { $ServerError } else { "HTTP $StatusCode" }
            return @{ Ok = $false; Token = ''; Status = $StatusCode; Error = "$AggregatorUrl refused the exchange ($why)." }
        }
    }
}

<#
.SYNOPSIS
    Opens a lab-token envelope: AES-256-GCM under a PBKDF2 key derived from the
    redeemed lab connection token. Returns '' when it does not authenticate.
.DESCRIPTION
    Twin of the aggregator's sealLabToken. The GCM tag is what authenticates the
    ANSWER: only a party holding the displayed code can produce an envelope this
    opens, so an enrolling host -- which cannot verify the aggregator's TLS leaf,
    signed as it is by a CA that host does not trust yet -- cannot be handed a
    token of an on-path attacker's choosing. A tamper, a wrong code, or a reply
    from something that is not this lab's aggregator all surface as ''.
#>
function Unprotect-LabTokenEnvelope {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$LabToken,
        [Parameter(Mandatory)]$Envelope
    )
    try {
        foreach ($field in @('salt', 'nonce', 'ciphertext', 'tag')) {
            if (-not $Envelope[$field]) { return '' }
        }
        $salt  = [Convert]::FromBase64String([string]$Envelope['salt'])
        $nonce = [Convert]::FromBase64String([string]$Envelope['nonce'])
        $ct    = [Convert]::FromBase64String([string]$Envelope['ciphertext'])
        $tag   = [Convert]::FromBase64String([string]$Envelope['tag'])
        # Iteration count and label are pinned to the Go side; a mismatch shows
        # up as a tag failure rather than a silently wrong plaintext.
        $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
            $LabToken, $salt, $script:LabTokenEnvelopeIterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try { $key = $kdf.GetBytes(32) } finally { $kdf.Dispose() }
        $plain = [byte[]]::new($ct.Length)
        $aes = New-ConfigSyncAesGcm -Key $key
        try {
            $aes.Decrypt($nonce, $ct, $tag, $plain,
                [System.Text.Encoding]::UTF8.GetBytes($script:LabTokenEnvelopeLabel))
        } finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
        $opened = [System.Text.Encoding]::UTF8.GetString($plain)
        [Array]::Clear($plain, 0, $plain.Length)
        return $opened
    } catch {
        Write-Verbose "lab-token envelope did not authenticate: $($_.Exception.Message)"
        return ''
    }
}

<#
.SYNOPSIS
    Redeems a dashboard Lab token at the pool-aggregator service for the shared
    lab-auth-token.
.DESCRIPTION
    POSTs {labToken} to <base>/api/v1/lab-token and classifies the answer via
    Get-LabTokenExchangeVerdict. The reply carries the shared token SEALED under
    the redeemed code, so knowledge of that code -- not the transport -- both
    authorizes the request and authenticates the answer: -SkipCertificateCheck
    is unavoidable here (the aggregator's leaf is signed by the proxy's own CA,
    which a host being enrolled does not trust yet), and the seal is what keeps
    that from mattering. -MaximumRedirection 0 and -NoProxy keep the exchange
    where it was addressed: a redirect could bounce it to a listener of
    someone else's choosing, and a host that has promoted the caching-proxy service
    would otherwise re-originate it from the proxy's address, collapsing the
    aggregator's per-address throttle and audit onto one identity.
.OUTPUTS
    [hashtable] @{ Ok; Token; Status; Error }.
#>
function Request-LabTokenExchange {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$AggregatorBaseUrl,
        [Parameter(Mandatory)][string]$LabToken,
        [Parameter()][int]$TimeoutSeconds = 15
    )
    $url = "$($AggregatorBaseUrl.TrimEnd('/'))/api/v1/lab-token"
    $body = @{ labToken = $LabToken } | ConvertTo-Json -Compress
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType 'application/json' `
            -TimeoutSec $TimeoutSeconds -SkipCertificateCheck -SkipHttpErrorCheck `
            -MaximumRedirection 0 -NoProxy
    } catch {
        return Get-LabTokenExchangeVerdict -StatusCode 0 -ServerError $_.Exception.Message -AggregatorUrl $url
    }
    $token = ''
    $serverError = ''
    try {
        $doc = $resp.Content | ConvertFrom-Json -AsHashtable
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc['ciphertext']) { $token = Unprotect-LabTokenEnvelope -LabToken $LabToken -Envelope $doc }
            if ($doc['error']) { $serverError = [string]$doc['error'] }
        }
    } catch { $serverError = "$($resp.Content)".Trim() }
    if (-not $serverError -and [int]$resp.StatusCode -ne 200) { $serverError = "$($resp.Content)".Trim() }
    return Get-LabTokenExchangeVerdict -StatusCode ([int]$resp.StatusCode) -Token $token -ServerError $serverError -AggregatorUrl $url
}

<#
.SYNOPSIS
    Provision THIS host as a holder of the shared lab-auth-token (idempotent).
.DESCRIPTION
    The shared lab-auth-token gates cross-host config-sync AND the
    status-service control routes (the deep-link control proofs the pool
    aggregator mints). Storing it needs two coupled writes that are easy to
    get subtly wrong by hand:

      1. users.yml -- lab-auth-token.vaultKey must be NON-EMPTY (an empty
         vaultKey routes Get-Password down the auto-generate path, which the
         gate rejects) AND must EQUAL the -Username Set-Password writes
         under. Set-Password keys the vault by -Username; the gate resolves
         the slot by vaultKey. A mismatch (the classic dash-vs-dot slip)
         stores the token under one key and reads another -> a silent 403.
         This sets both to the logical name, closing that class by
         construction.
      2. vault.yml -- the token itself, via Set-Password.

    Verifies the round-trip through the SAME resolution the gate uses, and
    optionally restarts the status service (in an isolated child pwsh) so the
    running process re-reads users.yml now instead of next cycle --
    Import-Extension skips re-import once loaded, so the edit is otherwise
    invisible to the live server. Each step is announced on the Information
    stream, and the bounce streams the child's transcript through as it runs.
    Returns @{ ok; vaultKey; keyChanged; verified; bounced; bounceLog }.

    Requires the authentication extension loaded (Set-Password et al.).
#>
function Set-LabAuthToken {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$BounceStatusService,
        [ValidateRange(10, 900)][int]$BounceTimeoutSeconds = 180
    )
    $logical = 'lab-auth-token'
    foreach ($fn in @('Set-UserVaultKey', 'Set-Password', 'Get-Password', 'Test-VaultEntry', 'Get-EffectiveUser', 'Reset-UsersConfigCache')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Set-LabAuthToken requires the authentication extension: '$fn' is not available. Import test/extension/authentication/default.psm1 first."
        }
    }
    $result = @{ ok = $false; vaultKey = $logical; keyChanged = $false; verified = $false; bounced = $false; bounceLog = $null }
    if (-not $PSCmdlet.ShouldProcess("host vault ($logical)", 'Provision shared lab-auth-token')) {
        return $result
    }
    # Each step is announced on the Information stream before it runs. The vault
    # writes are sub-second, but the status-service bounce routinely takes tens of
    # seconds (port map + readiness wait), and a silent script in that window is
    # indistinguishable from a wedged one -- the operator needs to see which step
    # owns the wait.
    $steps = if ($BounceStatusService) { 4 } else { 3 }

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

    if ($BounceStatusService) {
        $startScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-StatusService.ps1'
        $pwshExe = [System.Environment]::ProcessPath
        if ((Test-Path -LiteralPath $startScript) -and $pwshExe -and (Test-Path -LiteralPath $pwshExe)) {
            Write-Information "[4/$steps] status service: restarting so the running process re-reads users.yml now (up to ${BounceTimeoutSeconds}s) ..." -InformationAction Continue
            $bounce = Invoke-StatusServiceBounce -PwshExe $pwshExe -StartScript $startScript -TimeoutSeconds $BounceTimeoutSeconds
            $result.bounced   = $bounce.ok
            $result.bounceLog = $bounce.logPath
            if ($bounce.ok) {
                Write-Information "[4/$steps] status service: restarted." -InformationAction Continue
            } elseif ($bounce.timedOut) {
                Write-Warning "Status-server bounce is still running after ${BounceTimeoutSeconds}s; it was left alone (killing it would take the server down with it). Transcript: $($bounce.logPath). The token is stored and takes effect at the next cycle."
            } else {
                Write-Warning "Status-server bounce exited $($bounce.exitCode) (transcript: $($bounce.logPath)); the token is stored and takes effect at the next cycle."
            }
        } else {
            Write-Warning "Cannot bounce the status service (Start-StatusService.ps1 or the pwsh executable was not found); the token is stored and takes effect at the next cycle."
        }
    }
    $result.ok = [bool]$result.verified
    return $result
}

Export-ModuleMember -Function `
    Get-ConfigSyncLocalPathDefault, Convert-ConfigSyncNetworkStorage, Merge-ConfigSyncReferenceConfig, `
    Get-ConfigSyncProof, Test-ConfigSyncProof, Get-YurunaControlProof, Test-YurunaControlProof, Get-YurunaControlTag, Protect-ConfigSyncCredential, Unprotect-ConfigSyncCredential, `
    Get-ConfigSyncReferenceConfig, Get-ConfigSyncReferenceAliasMap, Resolve-ConfigSyncAliasResponse, `
    Request-ConfigSyncVaultCredential, Test-ConfigSyncCredentialEndpoint, Get-ConfigSyncCredentialReadiness, `
    Sync-HostConfiguration, Test-ConfigSyncReferenceFreshness, Set-LabAuthToken, Get-LabAuthTokenValue, `
    Request-LabTokenExchange, Get-LabTokenExchangeVerdict, Unprotect-LabTokenEnvelope
