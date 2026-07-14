<#PSScriptInfo
.VERSION 2026.07.14
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
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds
        $doc  = $resp.Content | ConvertFrom-Json -AsHashtable
        if ($doc -is [System.Collections.IDictionary] -and $doc['ok'] -and
            $doc['aliases'] -is [System.Collections.IDictionary]) {
            return $doc['aliases']
        }
    } catch {
        Write-Verbose "host-aliases fetch from $url failed: $($_.Exception.Message)"
    }
    return $null
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

# Ensures every networkStorage server name in the converted config resolves
# locally: reference host first, operator prompt as fallback.
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
    $referenceAliases = $null
    $referenceAliasesFetched = $false
    foreach ($name in $names) {
        if (Test-PoolStorageHostResolvable -ServerName $name) {
            Write-Information "networkStorage server '$name' already resolves." -InformationAction Continue
            continue
        }
        if (-not $referenceAliasesFetched) {
            $referenceAliases = Get-ConfigSyncReferenceAliasMap -ReferenceHost $ReferenceHost -Port $Port
            $referenceAliasesFetched = $true
        }
        $ip = ''
        if ($referenceAliases -is [System.Collections.IDictionary] -and $referenceAliases.Contains($name)) {
            $ip = "$($referenceAliases[$name])".Trim()
            if ($ip) { Write-Information "networkStorage server '$name': reference host resolves it to $ip." -InformationAction Continue }
        }
        if (-not $ip) {
            if ($NonInteractive) {
                Write-Warning "networkStorage server '$name' does not resolve locally and the reference host could not supply an address; add it to the hosts file manually (automation/Set-HostAlias.ps1)."
                continue
            }
            $ip = (Read-Host "networkStorage server '$name' does not resolve. IP address to map it to (Enter to skip)").Trim()
            if (-not $ip) { continue }
        }
        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) {
            Write-Warning "'$ip' is not a valid IP address; skipping the '$name' alias."
            continue
        }
        if (Invoke-ConfigSyncHostAlias -RepoRoot $RepoRoot -Name $name -IPAddress $parsed.ToString() -NonInteractive:$NonInteractive) {
            Write-Information "hosts file: mapped '$name' -> $($parsed.ToString())." -InformationAction Continue
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

# Ensures every networkStorage user in the converted config has a local vault
# entry: reference host (token-gated, encrypted) first, operator prompt as
# fallback. Requires the authentication extension; degrades to warnings when
# it cannot be loaded.
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

    $token = $SharedToken
    $tokenProbed = [bool]$token
    foreach ($user in $users) {
        $vaultKey = ''
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $user).vaultKey } catch { $null = $_ }
        $resolvedKey = if ([string]::IsNullOrWhiteSpace($vaultKey)) { $user } else { $vaultKey }
        if (Test-VaultEntry -VaultKey $resolvedKey) {
            Write-Information "vault: '$user' already has a stored credential." -InformationAction Continue
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("vault entry '$resolvedKey'", "Store the credential for networkStorage user '$user'")) { continue }

        if (-not $tokenProbed) {
            $tokenProbed = $true
            # The reference endpoint is gated by the operator-set shared
            # pool-auth-token (the same one that gates the aggregator's
            # push ingest); use the local copy when this host already has
            # it, otherwise ask once.
            try {
                $tm = Get-EffectiveUser -LogicalUser 'pool-auth-token'
                if ($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey)) {
                    $token = Get-Password -Username 'pool-auth-token'
                }
            } catch { $null = $_ }
            if (-not $token -and -not $NonInteractive) {
                $token = Read-ConfigSyncSecret -Prompt "Shared pool-auth-token to fetch credentials from $ReferenceHost (Enter to skip)"
            }
        }

        $password = ''
        if ($token) {
            $r = Request-ConfigSyncVaultCredential -ReferenceHost $ReferenceHost -Port $Port -User $user -Token $token
            if ($r.Ok) {
                $password = $r.Password
                Write-Information "vault: fetched the '$user' credential from $ReferenceHost." -InformationAction Continue
            } else {
                Write-Warning $r.Error
            }
        }
        if (-not $password -and -not $NonInteractive) {
            $password = Read-ConfigSyncSecret -Prompt "Password for networkStorage user '$user' (Enter to skip)"
        }
        if (-not $password) {
            Write-Warning "vault: no credential stored for '$user'; the networkStorage mount will stay skipped until one is set (Set-Password -Username '$resolvedKey')."
            continue
        }
        Set-Password -Username $resolvedKey -NewPassword $password
        Write-Information "vault: stored the credential for '$user' (key '$resolvedKey')." -InformationAction Continue
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
    invisible to the live server. Returns @{ ok; vaultKey; keyChanged;
    verified; bounced }.

    Requires the authentication extension loaded (Set-Password et al.).
#>
function Set-PoolAuthToken {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$BounceStatusServer
    )
    $logical = 'pool-auth-token'
    foreach ($fn in @('Set-UserVaultKey', 'Set-Password', 'Get-Password', 'Test-VaultEntry', 'Get-EffectiveUser', 'Reset-UsersConfigCache')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw "Set-PoolAuthToken requires the authentication extension: '$fn' is not available. Import test/extension/authentication/default.psm1 first."
        }
    }
    $result = @{ ok = $false; vaultKey = $logical; keyChanged = $false; verified = $false; bounced = $false }
    if (-not $PSCmdlet.ShouldProcess("host vault ($logical)", 'Provision shared pool-auth-token')) {
        return $result
    }
    # vaultKey == the logical name so Set-Password's -Username and the gate's
    # vaultKey resolution address the identical vault slot.
    $result.keyChanged = [bool](Set-UserVaultKey -LogicalUser $logical -VaultKey $logical)
    $null = Set-Password -Username $logical -NewPassword $Token
    $null = Reset-UsersConfigCache -Confirm:$false
    $tm = Get-EffectiveUser -LogicalUser $logical
    $result.verified = [bool]($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey) -and ((Get-Password -Username $logical) -eq $Token))
    if ($BounceStatusServer) {
        $startScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-StatusService.ps1'
        $pwshExe = [System.Environment]::ProcessPath
        if ((Test-Path -LiteralPath $startScript) -and $pwshExe -and (Test-Path -LiteralPath $pwshExe)) {
            # Child process so the entry-point script's own `exit` and its
            # -Global module (re)imports cannot disturb this runspace.
            try {
                & $pwshExe -NoProfile -File $startScript -Restart *> $null
                $result.bounced = ($LASTEXITCODE -eq 0)
                if (-not $result.bounced) {
                    Write-Warning "Status-server bounce exited $LASTEXITCODE; the token is stored and takes effect at the next cycle."
                }
            } catch {
                Write-Warning "Status-server bounce failed ($($_.Exception.Message)); the token is stored and takes effect at the next cycle."
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
    Get-ConfigSyncReferenceConfig, Get-ConfigSyncReferenceAliasMap, Request-ConfigSyncVaultCredential, `
    Sync-HostConfiguration, Set-PoolAuthToken
