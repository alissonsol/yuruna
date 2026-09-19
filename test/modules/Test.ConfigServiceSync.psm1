<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42523d00-1e52-4f07-92e7-2f54c6fa62da
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
        GET /control/vault-credential, which is gated by the internal
        authentication key and returns the password encrypted with a key
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
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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
function Get-ConfigSyncLocalPathDefault {
    <#
    .SYNOPSIS
        Returns the conventional networkStorage local mount path for a host type:
        Windows drive letters ('y:' pool / 'z:' stash), Linux '/mnt/<server>',
        macOS '~/Shares/<server>'.
    #>
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
                [void]$warnings.Add((Format-YurunaOperatorMessage -Key 'runner.operator_33ef5efa4b4f6f93' -Arguments @{ tier = "$tier" }))
            }
            $out[$lpKey] = ''; $out[$npKey] = ''; $out[$nuKey] = ''
            if ($tier -eq 'pool') { $out['moveLogsToPoolStorage'] = $false }
            continue
        }

        $out[$npKey] = Get-PoolStorageUncPath -Path $refNp -Style $style
        $out[$nuKey] = $refNu
        # moveLogsToPoolStorage travels with the pool tier. It MUST be carried
        # explicitly: this function rebuilds the networkStorage node from a fixed key
        # list and the caller REPLACES the node with the result, so any key not named
        # here is silently erased from the local config on every sync -- which for
        # this key would quietly turn move mode off across a fleet.
        if ($tier -eq 'pool') {
            $out['moveLogsToPoolStorage'] = [bool]$refNs['moveLogsToPoolStorage']
        }
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
        throw (Format-YurunaOperatorMessage -Key 'configsync.operator_39909717f78f9c25' -Arguments @{ name = "$($Reference.GetType().Name)" })
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
                [void]$warnings.Add((Format-YurunaOperatorMessage -Key 'runner.operator_1892e8b52e72fec6' -Arguments @{ poolKey = "${poolKey}" }))
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
        [void]$warnings.Add((Format-YurunaOperatorMessage -Key 'runner.operator_9a858ae5d0aa2217'))
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
            $kept = if ($localProj) { (Format-YurunaOperatorMessage -Key 'configsync.operator_548c2e9979f8bf3d' -Arguments @{ localProj = "$localProj" }) } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_69ca94406cbb5c1f') }
            [void]$warnings.Add((Format-YurunaOperatorMessage -Key 'runner.operator_41ba00697204a0ca' -Arguments @{ proj = "$proj"; kept = "$kept" }))
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
            $kept = if ($localClone) { (Format-YurunaOperatorMessage -Key 'configsync.operator_732d72e3a7f2581a' -Arguments @{ localClone = "$localClone" }) } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_9e1f86637c4a7e09') }
            [void]$warnings.Add((Format-YurunaOperatorMessage -Key 'runner.operator_70119a5d0827593a' -Arguments @{ clone = "$clone"; kept = "$kept" }))
        }
    }

    return @{ Config = $merged; Warnings = [string[]]@($warnings) }
}

# --- REGION: Shared-token credential envelope (client + server sides)
# Both ends hold the internal authentication key; nothing else is shared.
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
    Client side: the base64 HMAC proof that the caller knows the
    internal authentication key, bound to the requested user and the client nonce.
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
    proof = base64( HMAC-SHA256(internal-auth-key, "yuruna-control|proof|<expiry>") ).
    Bound to the expiry only: the internal authentication key is pool-wide, so a valid proof means
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
    A non-secret tag identifying WHICH internal authentication key this host holds:
    base64( HMAC-SHA256(internal-auth-key, "yuruna-control|tag|v1") ).
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
        # AllowEmptyString: the server gate calls this with whatever internal auth key it
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

<#
.SYNOPSIS
    Classifies an observed AES-GCM availability into an operator verdict.
    Pure (no I/O); the probe below feeds it what the runtime reported.
.DESCRIPTION
    Split from the probe for the reason every classifier here is: the decision
    has to be testable on a host where the algorithm IS present, which is every
    host that would run the suite.

    $null means the runtime does not expose IsSupported at all. That is
    reported as supported, deliberately: absence of the property is not
    evidence of absence of the algorithm, and blocking on a question this
    cannot answer would fail hosts that work.
.OUTPUTS
    [hashtable] Supported [bool], Reason [string] -- Reason is operator-actionable.
#>
function Get-ConfigSyncEnvelopeSupport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$IsSupported)
    if ($null -eq $IsSupported -or [bool]$IsSupported) { return @{ Supported = $true; Reason = '' } }
    return @{
        Supported = $false
        Reason    = ((Format-YurunaOperatorMessage -Key 'configsync.operator_9d03f7dc75755f81' -Arguments @{ pSVersion = "$($PSVersionTable.PSVersion)"; trim = "$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())" }))
    }
}

<#
.SYNOPSIS
    Whether this runtime can do the AES-GCM every credential envelope needs.
.DESCRIPTION
    Not every .NET build carries AES-GCM. A runtime without it fails at the
    moment of USE -- deep inside a decrypt, with an exception the callers
    historically folded into "the reply did not unseal", which reads as a wrong
    code and sends the operator back to the dashboard for a fresh one that
    cannot work either.

    Asking first turns that into one sentence naming the runtime. Reported
    rather than thrown so a caller can decide: a preflight lists it beside the
    other requirements, while an exchange refuses before it burns a rotating
    code and an audited attempt.
.OUTPUTS
    [hashtable] Supported [bool], Reason [string].
#>
function Test-ConfigSyncEnvelopeSupport {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $probe = $null
    try { $probe = [System.Security.Cryptography.AesGcm]::IsSupported }
    catch {
        Write-Verbose (Format-YurunaOperatorMessage -Key 'configsync.operator_764ff5e955c8393d' -Arguments @{ message = "$($_.Exception.Message)" })
    }
    return Get-ConfigSyncEnvelopeSupport -IsSupported $probe
}

function New-ConfigSyncAesGcm {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure object constructor; does not mutate state.')]
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.AesGcm])]
    param([Parameter(Mandatory)][byte[]]$Key)
    # Ask before constructing. Without this the failure arrives as
    # "Algorithm 'AesGcm' is not supported on this platform" from a constructor
    # two frames below a catch that turns it into a wrong-code message.
    $support = Test-ConfigSyncEnvelopeSupport
    if (-not $support.Supported) {
        throw [System.PlatformNotSupportedException]::new($support.Reason)
    }
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
function Get-ConfigSyncReferenceConfig {
    <#
    .SYNOPSIS
        Fetches the reference host's parsed test.config.yml as a hashtable via
        GET /control/test-config. Throws with a clear message when unreachable.
    #>
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
        throw (Format-YurunaOperatorMessage -Key 'configsync.operator_dd5832aa8d056afc' -Arguments @{ url = "$url"; message = "$($_.Exception.Message)" })
    }
    if ($doc -isnot [System.Collections.IDictionary]) {
        throw (Format-YurunaOperatorMessage -Key 'configsync.operator_aadf46f9f5285e05' -Arguments @{ url = "$url" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_53ba34766fd02d32' -Arguments @{ referenceHost = "$ReferenceHost"; message = "$($_.Exception.Message)" })
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
        return @{ Map = $null; Warning = (Format-YurunaOperatorMessage -Key 'configsync.operator_a693215e036db1c5' -Arguments @{ referenceHost = "$ReferenceHost"; reason = "$reason" }) }
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
    [hashtable] @{ Ok; Password; Status; Error } -- Error carries the reason on
    failure, Status the observed HTTP status (0 when the host did not answer) so
    a caller can tell a rejected key from an absent credential.
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
        return @{ Ok = $false; Password = $null; Status = 0; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_1e110e2f0d3775ed' -Arguments @{ message = "$($_.Exception.Message)" }) }
    }
    $doc = $null
    try { $doc = $resp.Content | ConvertFrom-Json -AsHashtable } catch { $null = $_ }
    if ($resp.StatusCode -ne 200 -or $doc -isnot [System.Collections.IDictionary] -or -not $doc['ok']) {
        $reason = if ($doc -is [System.Collections.IDictionary] -and $doc['error']) { [string]$doc['error'] } else { "HTTP $($resp.StatusCode)" }
        return @{ Ok = $false; Password = $null; Status = [int]$resp.StatusCode; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_1c3a81fa1d766f68' -Arguments @{ user = "$User"; reason = "$reason" }) }
    }
    try {
        $pw = Unprotect-ConfigSyncCredential -Token $Token -User $User -ClientNonce $clientNonce -Envelope ([pscustomobject]$doc)
        return @{ Ok = $true; Password = $pw; Status = [int]$resp.StatusCode; Error = $null }
    } catch {
        return @{ Ok = $false; Password = $null; Status = [int]$resp.StatusCode; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_b5a627b2ae01c0f8' -Arguments @{ user = "$User" }) }
    }
}

<#
.SYNOPSIS
    Classifies a /control/vault-credential probe response into a readiness
    verdict. Pure (no I/O); the HTTP wrapper below feeds it the observed status.
.DESCRIPTION
    The route checks its preconditions in a fixed order -- user referenced by
    this host's config (404), internal auth key configured here (503), proof
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
            $why = if ($ServerError) { $ServerError } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_88e60532873f2e23') }
            return @{ Ready = $false; Status = 0; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_9e13d40e10a4ef3a' -Arguments @{ referenceHost = "$ReferenceHost"; why = "$why" }) }
        }
        403 {
            # Proof mismatch is the SUCCESS case for a probe: the reference holds
            # an internal auth key and has a credential path for this user -- the
            # only thing standing between us and the password is the right token.
            return @{ Ready = $true; Status = 403; Error = $null }
        }
        503 {
            return @{ Ready = $false; Status = 503; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_67b60623c8140b5b' -Arguments @{ referenceHost = "$ReferenceHost"; referenceHost2 = "${ReferenceHost}" }) }
        }
        404 {
            return @{ Ready = $false; Status = 404; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_90cdc42e0c228655' -Arguments @{ referenceHost = "$ReferenceHost"; user = "$User"; serverError = "$ServerError" }) }
        }
        200 {
            # Unreachable in practice (an all-zero proof cannot verify); treat a
            # 200 as a serving endpoint rather than pretending it is broken.
            return @{ Ready = $true; Status = 200; Error = $null }
        }
        default {
            $why = if ($ServerError) { $ServerError } else { "HTTP $StatusCode" }
            return @{ Ready = $false; Status = $StatusCode; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_504335d8f73a9c9f' -Arguments @{ referenceHost = "$ReferenceHost"; why = "$why" }) }
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
    input it cannot use: a reference host with no internal auth key of its own can
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'configsync.operator_7e06c62add5ec176' -Arguments @{ aliasScript = "$aliasScript"; iPAddress = "$IPAddress"; name = "$Name" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_f5c0e102b6efe224'), "Map '$Name' -> '$IPAddress'")) { return $true }
    $needsSudo = (-not $IsWindows)
    if ($needsSudo) {
        try { $needsSudo = ((& id -u 2>$null | Out-String).Trim() -ne '0') } catch { $needsSudo = $true }
    }
    try {
        if ($needsSudo) {
            # -n (never block on a password prompt) and, on macOS, -E: a Homebrew
            # PowerShell cannot start under sudo's stripped environment and exits
            # 131 before reading the script. See Get-SudoPwshArgumentList.
            # The prompt names the account and the reason. Reaching this point
            # means the run has just finished narrating vault keys and the
            # storage-account credentials it fetched from the reference host, so
            # a bare "Password:" arrives looking like a continuation of that and
            # invites one of those credentials as the answer. What is wanted is
            # this machine's own login password, and nothing but the prompt can
            # say so.
            $sudoArgs = Get-SudoPwshArgumentList -ScriptPath $aliasScript `
                -ScriptArgument @('-ComputerName', $Name, '-IPAddress', $IPAddress) `
                -NonInteractive:$NonInteractive `
                -Prompt (Format-YurunaOperatorMessage -Key 'configsync.operator_fd00a4e339d2a5c1' -Arguments @{ name = "$Name" })
            & sudo @sudoArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'configsync.operator_21d662e284475037' -Arguments @{ name = "$Name"; lASTEXITCODE = "$LASTEXITCODE"; iPAddress = "$IPAddress" })
                return $false
            }
        } else {
            & $aliasScript -ComputerName $Name -IPAddress $IPAddress
        }
        return $true
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2dd32a949870972e' -Arguments @{ name = "$Name"; message = "$($_.Exception.Message)" })
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
    # Latched on the first elevation this loop cannot get, so the operator is
    # asked at most once. sudo caches a successful authentication for a few
    # minutes, so a run that gets the password right already prompts only for
    # the first name; without the latch a run that gets it WRONG prompts again
    # for every remaining name, and each prompt is a fresh three-attempt round
    # of the same rejection. Two names turn one mistake into six refusals, which
    # reads like the machine disagreeing with itself rather than one wrong
    # answer -- and the second prompt invites the operator to conclude a
    # DIFFERENT password must be wanted.
    $sudoRefused = $false
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
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_fe82ced102a46bde' -Arguments @{ name = "$name"; localIp = "$localIp" }) -InformationAction Continue
                continue
            }
            if ($NonInteractive) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_056c2704a3155ed1' -Arguments @{ name = "$name" })
                continue
            }
            $typed = (Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_8f35c185912eb1c6' -Arguments @{ name = "$name" })).Trim()
            if (-not $typed) { continue }
            $refIp = $typed
        }

        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($refIp, [ref]$parsed)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_377f048ed2d85082' -Arguments @{ refIp = "$refIp"; name = "$name" })
            continue
        }
        $target = $parsed.ToString()

        if ($localIp -eq $target) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5157cdf2a7a41e75' -Arguments @{ name = "$name"; target = "$target" }) -InformationAction Continue
            continue
        }
        if ($localIp) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c8a1299ffd87dc6f' -Arguments @{ name = "$name"; localIp = "$localIp"; target = "$target" }) -InformationAction Continue
        } else {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_93724a8a6a68d0e6' -Arguments @{ name = "$name"; target = "$target" }) -InformationAction Continue
        }
        if ($sudoRefused) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_efa65548849c32e4' -Arguments @{ name = "$name"; target = "$target" })
            continue
        }
        if (Invoke-ConfigSyncHostAlias -RepoRoot $RepoRoot -Name $name -IPAddress $target -NonInteractive:$NonInteractive) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_68148e020fe75460' -Arguments @{ name = "$name"; target = "$target" }) -InformationAction Continue
        } else {
            $sudoRefused = $true
            # Said once, here, because the cost is not visible where it lands:
            # the names stay pointed wherever they pointed before, and the
            # failure surfaces later as a mount that cannot reach the share.
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_af02ae2f4290672d')
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
    # Trimmed because a secret is pasted far more often than typed, and a
    # trailing space or newline rides along invisibly. Both consumers use the
    # value as HMAC key material, where one stray byte is indistinguishable
    # from the wrong secret entirely: the far end can only answer "mismatch".
    return (ConvertFrom-SecureString -SecureString $secure -AsPlainText).Trim()
}

# --- REGION: https://yuruna.link/42fa6f45-0026
function Test-LabTokenShape {
    <#
    .SYNOPSIS
        Is this string shaped like the dashboard's Lab token (the 6-character
        redemption code), rather than an internal authentication key?
    .DESCRIPTION
        The two secrets an operator can hold have disjoint shapes -- 6 characters of
        lowercase alphanumerics against 48 hexadecimal ones -- so which one is in
        hand is decidable, and nothing has to guess. Case is folded first because
        the dashboard renders the code in a font where the operator's shift key is
        the only thing deciding case.

        Callers that need the redemption code use this to accept it; callers that
        need the key itself use it to recognize the one value they must never
        treat as key material.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Value = '')
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim().ToLowerInvariant() -match '^[a-z0-9]{6}$')
}

<#
.SYNOPSIS
    Turn whatever the operator typed at a secret prompt into an internal
    authentication key, redeeming a dashboard Lab token in place when that is
    what arrived.
.DESCRIPTION
    An operator who has a lab at all has the Lab token tile in front of them;
    the internal authentication key lives in another host's vault and is
    deliberately never displayed. So the value most likely to be typed at a
    prompt asking for the key is the one thing that cannot serve as the key.

    Rather than refuse it, this redeems it: the exchange that turns a Lab token
    into the key is the same one enrollment runs, so accepting the code here
    both unblocks the caller and leaves the host properly enrolled -- holding
    the key in its vault, answering control routes, and reporting to the
    dashboards -- instead of borrowing a secret for one command.

    Redemption is a state change beyond what a prompt implies, so it is
    announced before it happens and reported after. When the aggregator cannot
    be reached the code is refused rather than guessed at, and the caller is
    told which command completes the enrollment by hand.
.OUTPUTS
    [hashtable] @{ Key; Enrolled; Redeemed; Error } -- Key is '' when nothing
    usable could be produced; Error is operator-actionable.
#>
function Resolve-ConfigSyncInternalAuthKey {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][AllowEmptyString()][string]$Value = '',
        # Skip the vault write and use the redeemed key for this run only.
        [switch]$NoPersist
    )
    $typed = "$Value".Trim()
    if (-not $typed) { return @{ Key = ''; Enrolled = $false; Redeemed = $false; Error = $null } }
    if (-not (Test-LabTokenShape -Value $typed)) {
        return @{ Key = $typed; Enrolled = $false; Redeemed = $false; Error = $null }
    }

    $code = $typed.ToLowerInvariant()
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f70223166f852c07') -InformationAction Continue

    # Resolved on demand: this module works on hosts that never reach an
    # aggregator, and loading the caching-proxy resolver up front would make
    # its absence a load error rather than a redemption that simply cannot run.
    $baseUrl = ''
    try {
        $proxyModule = Join-Path $RepoRoot 'test/modules/Test.CachingProxyService.psm1'
        if (Test-Path -LiteralPath $proxyModule) {
            Import-Module $proxyModule -Force -DisableNameChecking
            if (Get-Command Get-PoolAggregatorServiceSeedUrl -ErrorAction SilentlyContinue) {
                $baseUrl = [string](Get-PoolAggregatorServiceSeedUrl -MaxWaitSeconds 30)
            }
        }
    } catch { $null = $_ }
    if (-not $baseUrl) {
        return @{ Key = ''; Enrolled = $false; Redeemed = $false; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_21a32e8df2354bc6' -Arguments @{ code = "$code" }) }
    }

    # https first (a provisioned proxy mints the aggregator's TLS leaf), plain
    # http as the transport fallback. Only a transport failure falls through:
    # an answered refusal is the aggregator's verdict, and retrying the same
    # code would burn another audited attempt against a budget the operator
    # cannot see.
    $verdict = $null
    foreach ($base in @($baseUrl, ($baseUrl -replace '^https:', 'http:'))) {
        $verdict = Request-LabTokenExchange -AggregatorBaseUrl $base -LabToken $code
        if ($verdict.Ok -or $verdict.Status -ne 0) { break }
    }
    if (-not $verdict -or -not $verdict.Ok) {
        $why = if ($verdict) { $verdict.Error } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_8e92cae30e0c221a') }
        return @{ Key = ''; Enrolled = $false; Redeemed = $false; Error = $why }
    }

    if ($NoPersist) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_076859b0b8d40bc0') -InformationAction Continue
        return @{ Key = $verdict.Token; Enrolled = $false; Redeemed = $true; Error = $null }
    }

    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_818563ad5a66e6c0') -InformationAction Continue
    $enrolled = $false
    try {
        $provision = Set-InternalAuthKey -Token $verdict.Token
        $enrolled = [bool]$provision.ok
        if (-not $enrolled) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_920bc1e950eec0e5' -Arguments @{ keyChanged = "$($provision.keyChanged)"; verified = "$($provision.verified)" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c591b9085240b247' -Arguments @{ message = "$($_.Exception.Message)" })
    }
    return @{ Key = $verdict.Token; Enrolled = $enrolled; Redeemed = $true; Error = $null }
}

# --- REGION: https://yuruna.link/42d69dfa-0028
function Sync-ConfigSyncVaultCredential {
    <#
    .SYNOPSIS
        Converges every networkStorage user's vault entry onto the reference host's
        credential: probe before prompting, and rewrite on drift so re-runs converge.
    .DESCRIPTION
        Resolves each of poolStorageNetworkUser / stashStorageNetworkUser through
        the authentication extension to its vault key, fetches the reference host's
        value over the token-gated credential endpoint, and stores it when it is
        absent or disagrees. An entry that already matches is left untouched and no
        write happens, so a repeat run is a no-op.

        The internal authentication key is what makes the fetch possible: an explicit
        -InternalAuthKey wins, else this host's stored key, else -- for a
        genuinely missing credential in an interactive session -- a prompt.

        Emits one record per user, so a caller can tell a converged entry from a
        merely SURVIVING one. Those look identical from the console -- both end with
        a credential in the vault -- and the difference decides whether the mount
        will work: an entry kept because nothing could replace it is, on a host
        converting away from standalone, precisely the locally minted password the
        lab's share has never heard of. Callers that must not accept it pass
        -RequireReferenceValue.
    .OUTPUTS
        [pscustomobject[]] one record per user, @{ User; VaultKey; Status;
        Converged; Detail }. Status is one of stored / updated / already-matches
        (Converged) or kept-local / no-token / unverified / missing / whatif (not).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$NetworkStorage,
        [Parameter(Mandatory)][string]$ReferenceHost,
        [Parameter()][int]$Port = 8080,
        [Parameter()][Alias('SharedToken')][string]$InternalAuthKey = '',
        [switch]$NonInteractive,
        # Refuse to keep a local entry the reference host did not supply, and
        # overwrite one that disagrees, instead of treating "an entry exists" as
        # good enough. The no-token shortcut is disabled with it: without a key
        # nothing can be fetched, so every user reports 'no-token' rather than
        # 'kept-local' and the caller fails the run instead of shipping a host
        # whose credentials were never checked against the lab.
        [switch]$RequireReferenceValue
    )
    try {
        Import-Module (Join-Path $RepoRoot 'test/modules/Test.Extension.psm1') -Force -DisableNameChecking
        $null = Import-Extension -Area 'authentication' -RequireSingle
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ee39d57334aa53b8' -Arguments @{ message = "$($_.Exception.Message)" })
        return [pscustomobject[]]@()
    }

    $users = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('poolStorageNetworkUser', 'stashStorageNetworkUser')) {
        $u = if ($NetworkStorage.Contains($key)) { "$($NetworkStorage[$key])".Trim() } else { '' }
        if ($u -and $users -notcontains $u) { [void]$users.Add($u) }
    }

    # -WhatIf must not prompt either: a prompt is an operator-visible side effect,
    # and a rehearsal that stops to demand a password is not a rehearsal.
    $canPrompt = (-not $NonInteractive) -and (-not $WhatIfPreference)

    # Acquire the key WITHOUT prompting: an explicit -InternalAuthKey wins,
    # else this host's own stored internal auth key. Prompting is deferred to the
    # point a genuinely MISSING credential needs it, so a re-run where every entry
    # is already present -- the common case -- never stops to ask for a key, yet
    # a key that is available (passed or stored) is still used to refresh a
    # rotated password silently.
    $authKey = $InternalAuthKey
    if (-not $authKey) {
        $authKey = Get-InternalAuthKeyValue
        if ($authKey) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8afa11662de4dcbc' -Arguments @{ referenceHost = "$ReferenceHost" }) -InformationAction Continue
        }
    }
    $keyPromptTried = $false
    $outcome = [System.Collections.Generic.List[pscustomobject]]::new()
    # Local so the emitting lines read as one shape; every exit below records
    # exactly one outcome per user.
    $record = {
        param([string]$User, [string]$VaultKey, [string]$Status, [string]$Detail)
        [void]$outcome.Add([pscustomobject]@{
            User      = $User
            VaultKey  = $VaultKey
            Status    = $Status
            Converged = ($Status -in @('stored', 'updated', 'already-matches'))
            Detail    = $Detail
        })
    }

    foreach ($user in $users) {
        $vaultKey = ''
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $user).vaultKey } catch { $null = $_ }
        $resolvedKey = if ([string]::IsNullOrWhiteSpace($vaultKey)) { $user } else { $vaultKey }
        $hasEntry = [bool](Test-VaultEntry -VaultKey $resolvedKey)

        # No internal authentication key to fetch a possibly-rotated value with, and a working
        # entry is already here: keep it, with no network round-trip and no prompt.
        # Fetching (hence refreshing) is impossible without the key by design, so
        # there is nothing the reference could tell us that would change the outcome.
        # Pass -InternalAuthKey (or store an internal auth key here) to have re-runs refresh
        # this against the reference.
        #
        # -RequireReferenceValue takes this branch off the table. The caller has
        # said an unchecked entry is not acceptable, and on a host converting away
        # from standalone it is actively wrong: the entry it would keep was minted
        # here, for a share this host used to serve itself.
        if (-not $authKey -and $hasEntry -and -not $RequireReferenceValue) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5e743da1cdfcdf13' -Arguments @{ user = "$user"; referenceHost = "$ReferenceHost" }) -InformationAction Continue
            & $record $user $resolvedKey 'kept-local' (Format-YurunaOperatorMessage -Key 'configsync.operator_14636e2b7f9a6280' -Arguments @{ referenceHost = "$ReferenceHost" })
            continue
        }
        if (-not $authKey -and $RequireReferenceValue) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ef1995d6348801eb' -Arguments @{ user = "$user"; referenceHost = "$ReferenceHost" })
            & $record $user $resolvedKey 'no-token' (Format-YurunaOperatorMessage -Key 'configsync.operator_ebe04affa70e41bf' -Arguments @{ referenceHost = "$ReferenceHost" })
            continue
        }

        $capability = Test-ConfigSyncCredentialEndpoint -ReferenceHost $ReferenceHost -Port $Port -User $user
        $password = ''
        if ($capability.Ready) {
            # Prompt for the key only when it is needed to BOOTSTRAP a missing
            # entry -- never merely to check an existing one for rotation, which
            # would nag on every re-run. Asked once, and only when the reference
            # can actually serve (Ready), so the prompt is never a dead end.
            if (-not $authKey -and -not $keyPromptTried -and -not $hasEntry -and $canPrompt) {
                $keyPromptTried = $true
                $typed = Read-ConfigSyncSecret -Prompt (Format-YurunaOperatorMessage -Key 'configsync.operator_cb757afbb07cffde')
                if ($typed) {
                    $resolved = Resolve-ConfigSyncInternalAuthKey -RepoRoot $RepoRoot -Value $typed
                    if ($resolved.Error) { Write-Warning $resolved.Error }
                    $authKey = [string]$resolved.Key
                    if ($resolved.Redeemed -and $resolved.Enrolled) {
                        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3b1fcc74c72da88c') -InformationAction Continue
                    }
                }
            }
            if ($authKey) {
                $r = Request-ConfigSyncVaultCredential -ReferenceHost $ReferenceHost -Port $Port -User $user -Token $authKey
                if ($r.Ok) {
                    $password = $r.Password
                } else {
                    Write-Warning $r.Error
                    # A rejected proof is a verdict on the key, not on this user:
                    # the same key would be rejected for every remaining one. Drop
                    # it so each user is not charged another identical warning, and
                    # say once what would actually fix it.
                    if ($r.Status -eq 403) {
                        $authKey = ''
                        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_45df46c63b590ee5' -Arguments @{ referenceHost = "$ReferenceHost" })
                    }
                }
            } elseif (-not $hasEntry) {
                # Serviceable, but we have no key and cannot (or were told not to)
                # get one. Only worth flagging when the entry is missing; an entry
                # that already exists is kept quietly below.
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_edbab3e6c6e97d54' -Arguments @{ referenceHost = "$ReferenceHost"; user = "$user" })
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7e929f75228fd7c0' -Arguments @{ user = "$user"; error = "$($capability.Error)" })
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
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_579dcdc19a4bffcf' -Arguments @{ user = "$user"; referenceHost = "$ReferenceHost" }) -InformationAction Continue
                & $record $user $resolvedKey 'already-matches' (Format-YurunaOperatorMessage -Key 'configsync.operator_6c4892a60072cac0' -Arguments @{ referenceHost = "$ReferenceHost" })
                continue
            }
            if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_9a587adc27d9c74d' -Arguments @{ resolvedKey = "$resolvedKey" }), (Format-YurunaOperatorMessage -Key 'configsync.credential_action' -Arguments @{ hasEntry = [string]$hasEntry; user = "$user"; referenceHost = "$ReferenceHost" }))) {
                Set-Password -Username $resolvedKey -NewPassword $password
                Write-Information (Format-YurunaOperatorMessage -Key 'configsync.credential_done' -Arguments @{ hasEntry = [string]$hasEntry; user = "$user"; resolvedKey = "$resolvedKey"; referenceHost = "$ReferenceHost" }) -InformationAction Continue
                & $record $user $resolvedKey $(if ($hasEntry) { 'updated' } else { 'stored' }) (Format-YurunaOperatorMessage -Key 'configsync.operator_6d042d22c83afafc' -Arguments @{ referenceHost = "$ReferenceHost" })
            } else {
                & $record $user $resolvedKey 'whatif' (Format-YurunaOperatorMessage -Key 'configsync.credential_preview' -Arguments @{ hasEntry = [string]$hasEntry; referenceHost = "$ReferenceHost" })
            }
            continue
        }

        # Nothing came back from the reference. An entry already here still works
        # -- keep it rather than making the operator retype what it holds. Under
        # -RequireReferenceValue that is not good enough: the entry is reported
        # unconverged so the caller can refuse the run. It is deliberately still
        # KEPT rather than deleted -- clearing it would take a working standalone
        # mount down as well, leaving the host worse off than before it tried.
        if ($hasEntry) {
            if ($RequireReferenceValue) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f5675f4c1c4608a9' -Arguments @{ user = "$user"; referenceHost = "$ReferenceHost" })
                & $record $user $resolvedKey 'unverified' (Format-YurunaOperatorMessage -Key 'configsync.operator_a01d26f897759fcf' -Arguments @{ referenceHost = "$ReferenceHost" })
            } else {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b36976f094aa3f4e' -Arguments @{ user = "$user" }) -InformationAction Continue
                & $record $user $resolvedKey 'kept-local' (Format-YurunaOperatorMessage -Key 'configsync.operator_922f6f240e2393dd' -Arguments @{ referenceHost = "$ReferenceHost" })
            }
            continue
        }
        $typed = ''
        if ($canPrompt) {
            $typed = Read-ConfigSyncSecret -Prompt (Format-YurunaOperatorMessage -Key 'configsync.operator_41342d0410aa7c6d' -Arguments @{ user = "$user" })
        }
        if (-not $typed) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ceff4f91aefb6062' -Arguments @{ user = "$user"; resolvedKey = "$resolvedKey" })
            & $record $user $resolvedKey 'missing' (Format-YurunaOperatorMessage -Key 'configsync.operator_d8478026c13990f5')
            continue
        }
        if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_9a587adc27d9c74d' -Arguments @{ resolvedKey = "$resolvedKey" }), (Format-YurunaOperatorMessage -Key 'runner.operator_743d4c89a27b0230' -Arguments @{ user = "$user" }))) {
            Set-Password -Username $resolvedKey -NewPassword $typed
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e0385afcaf2704d0' -Arguments @{ user = "$user"; resolvedKey = "$resolvedKey" }) -InformationAction Continue
            # Operator-typed, not reference-supplied. Reported as converged
            # because the operator is the authority the reference stands in for --
            # they read it off the lab, which is the same value.
            & $record $user $resolvedKey 'stored' (Format-YurunaOperatorMessage -Key 'configsync.operator_0c6e2106f0eb6822')
        } else {
            & $record $user $resolvedKey 'whatif' (Format-YurunaOperatorMessage -Key 'configsync.operator_259ae96e9169d2f6')
        }
    }
    return [pscustomobject[]]@($outcome)
}

# --- REGION: Orchestrator
function Test-ConfigSyncReferenceFreshness {
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

.PARAMETER InternalAuthKey
    Internal authentication key for the fetch. Empty means read it from local config.

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

.PARAMETER RequireReferenceCredential
    Do not accept a networkStorage vault entry the reference host did not supply.
    Without it, an entry that is already present survives when nothing can be
    fetched -- correct for a host refreshing its config, and wrong for one
    converting away from standalone, where the surviving entry is the password
    this host minted for a share it used to serve itself. The unconverged users
    come back in CredentialResult; this switch does not fail the run on its own.

.OUTPUTS
    [pscustomobject] Wrote, BackupPath, Warnings, ValidationExit, CredentialResult.
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
        [Parameter()][Alias('SharedToken')][string]$InternalAuthKey = '',
        [switch]$NonInteractive,
        [switch]$SkipValidation,
        [switch]$NoPool,
        # Copy from a reference host whose config is behind this host's schema
        # without asking. For scripted syncs that have already accepted the drift.
        [switch]$AllowStaleReference,
        [switch]$RequireReferenceCredential
    )
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $hostType = Get-HostType
    if (-not $hostType) { throw (Format-YurunaOperatorMessage -Key 'configsync.operator_a610cd0fd716e5f9') }

    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_885ea33d3fbe29cb' -Arguments @{ referenceHost = "${ReferenceHost}"; statusPort = "${StatusPort}" }) -InformationAction Continue
    $reference = Get-ConfigSyncReferenceConfig -ReferenceHost $ReferenceHost -Port $StatusPort

    # --- REGION: Retired key spellings on the reference
    # Rewrite them onto the current paths BEFORE anything reads the config.
    # Every consumer downstream looks up current names only, so a value parked
    # under a retired one is indistinguishable from a value that is not there --
    # and "not there" is not inert: Convert-ConfigSyncNetworkStorage reads a
    # missing poolStorageNetworkPath as "the reference has no pool storage" and
    # CLEARS the tier, which takes the user names with it and leaves the
    # credential sync iterating an empty list. A reference one rename behind
    # would erase exactly the section it was fetched to supply.
    #
    # Ahead of the freshness gate, so a reference whose only drift is spelling
    # syncs cleanly -- including unattended, where that gate is a hard failure.
    # The operator is still told, because the fix belongs at the source: this
    # rewrite is per-sync and the reference keeps serving the old names to
    # everyone else until it is reconciled.
    $namingModule = Join-Path $RepoRoot 'test/modules/Test.ConfigNaming.psm1'
    if (Test-Path -LiteralPath $namingModule) {
        Import-Module $namingModule -Force -DisableNameChecking
        $migrated = @(Update-RetiredConfigKey -Config $reference -Confirm:$false)
        if ($migrated.Count -gt 0) {
            Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_400083668bb425de' -Arguments @{ referenceHost = "${ReferenceHost}"; count = "$($migrated.Count)" }))
            foreach ($m in $migrated) {
                $note = if ($m.Action -eq 'superseded') { (Format-YurunaOperatorMessage -Key 'configsync.operator_9e44a801c5e38eb2') }
                        elseif ($m.Factor -ne 1)        { " (x$($m.Factor) -> $($m.Value))" }
                        else                            { '' }
                Write-Warning "  $($m.Old) -> $($m.New)$note"
            }
        }
    }

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
            [void]$detail.Add((Format-YurunaOperatorMessage -Key 'configsync.operator_9d1be9a1af0107c6' -Arguments @{ referenceHost = "${ReferenceHost}"; count = "$($freshness.Retired.Count)" }))
            foreach ($r in $freshness.Retired) { [void]$detail.Add("    - $r") }
        }
        if ($freshness.Missing.Count -gt 0) {
            [void]$detail.Add((Format-YurunaOperatorMessage -Key 'configsync.operator_03e72c207d4307ef' -Arguments @{ referenceHost = "${ReferenceHost}"; count = "$($freshness.Missing.Count)" }))
            foreach ($m in $freshness.Missing) { [void]$detail.Add("    - $m") }
        }
        if ($freshness.Unknown.Count -gt 0) {
            [void]$detail.Add((Format-YurunaOperatorMessage -Key 'configsync.operator_99c291e04af53ea0' -Arguments @{ referenceHost = "${ReferenceHost}"; count = "$($freshness.Unknown.Count)" }))
            foreach ($u in $freshness.Unknown) { [void]$detail.Add("    - $u") }
        }
        $summary = (Format-YurunaOperatorMessage -Key 'configsync.operator_202dc5f92e411bb6' -Arguments @{ referenceHost = "${ReferenceHost}"; detail = "$(($detail -join "`n"))" })
        Write-Warning $summary
        if ($AllowStaleReference) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d5df7de49d6582c5')
        } elseif ($NonInteractive) {
            throw (Format-YurunaOperatorMessage -Key 'configsync.operator_a07da31688eb8071' -Arguments @{ referenceHost = "${ReferenceHost}" })
        } elseif (-not $PSCmdlet.ShouldContinue(
                    (Format-YurunaOperatorMessage -Key 'configsync.operator_89d813963a42571e'),
                    (Format-YurunaOperatorMessage -Key 'configsync.operator_fcdef223bcd5d9cb' -Arguments @{ referenceHost = "$ReferenceHost" }))) {
            throw (Format-YurunaOperatorMessage -Key 'configsync.operator_a98b32ec2329c210' -Arguments @{ referenceHost = "${ReferenceHost}" })
        }
    } elseif ($freshness.Checked) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6f45c80f05654384' -Arguments @{ referenceHost = "${ReferenceHost}" }) -InformationAction Continue
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
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8611bc4c42a9779a') -InformationAction Continue
    } elseif ($PSCmdlet.ShouldProcess($configPath, (Format-YurunaOperatorMessage -Key 'runner.operator_26170942123e2fb5' -Arguments @{ referenceHost = "$ReferenceHost" }))) {
        if ($local) {
            # Same recoverability convention as the template reconcile: the
            # pre-sync file is always one copy away.
            $backupPath = "$configPath.backup"
            Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
        }
        $wrote = [bool](Write-YurunaStateFile -Path $configPath -Content $yaml -Confirm:$false)
        if (-not $wrote) {
            throw (Format-YurunaOperatorMessage -Key 'configsync.operator_acd19bbbd8ecb77b' -Arguments @{ configPath = "$configPath" })
        }
        $backupNote = if ($backupPath) { (Format-YurunaOperatorMessage -Key 'configsync.operator_d1da8b19d2899d33' -Arguments @{ backupPath = "$backupPath" }) } else { '' }
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5691792ef0c34155' -Arguments @{ referenceHost = "${ReferenceHost}"; backupNote = "${backupNote}" }) -InformationAction Continue
    }

    $ns = $canonical['networkStorage']
    $credentialResult = @()
    if ($ns -is [System.Collections.IDictionary]) {
        Sync-ConfigSyncHostAlias -RepoRoot $RepoRoot -NetworkStorage $ns `
            -ReferenceHost $ReferenceHost -Port $StatusPort -NonInteractive:$NonInteractive
        # Captured, not left on the pipeline: this function returns a summary
        # object, and per-user records escaping into that stream would make the
        # caller's `$r.Wrote` read off whichever record landed first.
        $credentialResult = @(Sync-ConfigSyncVaultCredential -RepoRoot $RepoRoot -NetworkStorage $ns `
            -ReferenceHost $ReferenceHost -Port $StatusPort -InternalAuthKey $InternalAuthKey `
            -NonInteractive:$NonInteractive -RequireReferenceValue:$RequireReferenceCredential)

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
                default     { Write-Verbose (Format-YurunaOperatorMessage -Key 'configsync.operator_265250e5e60166b6' -Arguments @{ action = "$($sudo.Action)"; message = "$($sudo.Message)" }) }
            }
        }
    }

    $validationExit = $null
    if (-not $SkipValidation -and -not $WhatIfPreference) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0d5b3ab6571f7a39') -InformationAction Continue
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'test/Test-Config.ps1')
        $validationExit = $LASTEXITCODE
        if ($validationExit -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'configsync.operator_562b56f7b48a5230' -Arguments @{ validationExit = "$validationExit" })
        }
    }

    return [pscustomobject]@{
        Wrote             = $wrote
        BackupPath        = $backupPath
        Warnings          = $merge.Warnings
        ValidationExit    = $validationExit
        CredentialResult  = [pscustomobject[]]@($credentialResult)
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
        Write-Debug (Format-YurunaOperatorMessage -Key 'configsync.operator_d065ed41fc7b982c' -Arguments @{ message = "$($_.Exception.Message)" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_47371277eaeea492' -Arguments @{ message = "$($_.Exception.Message)" })
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
    Read this host's stored internal authentication key, or '' when none is set.
.DESCRIPTION
    Resolves the 'internal-auth-key' vault entry through the same
    users.yml-vaultKey indirection the control gate uses, falling back to the
    legacy 'lab-auth-token' and 'pool-auth-token' logical names so a host whose vault was
    provisioned under either name keeps verifying proofs and fetching
    credentials without re-enrollment. Never calls Get-Password without a
    confirmed vault entry (an unpopulated user would auto-generate a junk
    credential). Requires the authentication extension loaded; returns ''
    when it is not.

    The value is returned trimmed, matching the aggregator's own read of the
    baked key file. Both ends HMAC it to publish and compare control tags, so a
    copy that differs only in surrounding whitespace would read as two different
    secrets and strand every host on "onsite (token mismatch)".
#>
function Get-InternalAuthKeyValue {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($logical in @('internal-auth-key', 'lab-auth-token', 'pool-auth-token')) {
        try {
            if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue)) { return '' }
            $tm = Get-EffectiveUser -LogicalUser $logical
            if ($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey)) {
                # Trimmed to match the aggregator, which strips surrounding whitespace
                # when it reads the same key off disk. The two ends HMAC this value to
                # compare tags; a stored copy differing by one trailing newline would
                # report the whole pool as "onsite (token mismatch)" while both sides
                # genuinely hold the same secret.
                return ([string](Get-Password -Username $logical)).Trim()
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
    or the proxy holds no internal auth key). $StatusCode 0 denotes a transport
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
                return @{ Ok = $false; Token = ''; Status = 200; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_b8277d0b77dd315e' -Arguments @{ aggregatorUrl = "$AggregatorUrl" }) }
            }
            return @{ Ok = $true; Token = $Token; Status = 200; Error = $null }
        }
        0 {
            $why = if ($ServerError) { $ServerError } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_88e60532873f2e23') }
            return @{ Ok = $false; Token = ''; Status = 0; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_2273c132a7fe499b' -Arguments @{ aggregatorUrl = "$AggregatorUrl"; why = "$why" }) }
        }
        403 {
            return @{ Ok = $false; Token = ''; Status = 403; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_fe98a0adcdbd07b3' -Arguments @{ aggregatorUrl = "$AggregatorUrl" }) }
        }
        429 {
            return @{ Ok = $false; Token = ''; Status = 429; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_29ef5c3e50b93287' -Arguments @{ aggregatorUrl = "$AggregatorUrl" }) }
        }
        503 {
            return @{ Ok = $false; Token = ''; Status = 503; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_c593d83f1f3260d0' -Arguments @{ aggregatorUrl = "$AggregatorUrl" }) }
        }
        default {
            $why = if ($ServerError) { $ServerError } else { "HTTP $StatusCode" }
            return @{ Ok = $false; Token = ''; Status = $StatusCode; Error = (Format-YurunaOperatorMessage -Key 'configsync.operator_b636602072bf575e' -Arguments @{ aggregatorUrl = "$AggregatorUrl"; why = "$why" }) }
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
    $support = Test-ConfigSyncEnvelopeSupport
    if (-not $support.Supported) {
        # A warning, not a verbose line: returning '' here is indistinguishable
        # from a wrong code at the call site, and this is the one cause no
        # amount of re-reading the dashboard can fix.
        Write-Warning $support.Reason
        return ''
    }
    try {
        foreach ($field in @('salt', 'nonce', 'ciphertext', 'tag')) {
            if (-not $Envelope[$field]) {
                # Named, because a silent empty return here reads downstream as
                # a failed decrypt -- a different fault with different advice.
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9bf3c592a7c65740' -Arguments @{ field = "$field" })
                return ''
            }
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
        Write-Verbose (Format-YurunaOperatorMessage -Key 'configsync.operator_ae8bc8821187bf0f' -Arguments @{ message = "$($_.Exception.Message)" })
        return ''
    }
}

<#
.SYNOPSIS
    Redeems a dashboard Lab token at the pool-aggregator service for the
    internal authentication key.
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
    # Ask before spending the code. The aggregator counts and audits every
    # exchange, and the code rotates, so a host that cannot open the reply must
    # not consume one to discover that -- and must not be told to fetch another.
    # Status -1 marks a CLIENT precondition, distinct from 0 (no answer): the
    # caller's scheme-fallback loop retries only on 0, which is right, because
    # plain HTTP would fail here for exactly the same reason.
    $support = Test-ConfigSyncEnvelopeSupport
    if (-not $support.Supported) {
        return @{ Ok = $false; Token = ''; Status = -1; Error = $support.Reason }
    }
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
    Provision THIS host as a holder of the internal authentication key (idempotent).
.DESCRIPTION
    The internal authentication key gates cross-host config-sync AND the
    status-service control routes (the deep-link control proofs the pool
    aggregator mints). Storing it needs two coupled writes that are easy to
    get subtly wrong by hand:

      1. users.yml -- internal-auth-key.vaultKey must be NON-EMPTY (an empty
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
function Set-InternalAuthKey {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$BounceStatusService,
        [ValidateRange(10, 900)][int]$BounceTimeoutSeconds = 180
    )
    $logical = 'internal-auth-key'
    foreach ($fn in @('Set-UserVaultKey', 'Set-Password', 'Get-Password', 'Test-VaultEntry', 'Get-EffectiveUser', 'Reset-UsersConfigCache')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            throw (Format-YurunaOperatorMessage -Key 'configsync.operator_0bda1d154849ebae' -Arguments @{ fn = "$fn" })
        }
    }
    $result = @{ ok = $false; vaultKey = $logical; keyChanged = $false; verified = $false; retired = [string[]]@(); bounced = $false; bounceLog = $null }
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_88f4431aaa292749' -Arguments @{ logical = "$logical" }), (Format-YurunaOperatorMessage -Key 'runner.operator_5d1e7425aad78672'))) {
        return $result
    }
    # Each step is announced on the Information stream before it runs. The vault
    # writes are sub-second, but the status-service bounce routinely takes tens of
    # seconds (port map + readiness wait), and a silent script in that window is
    # indistinguishable from a wedged one -- the operator needs to see which step
    # owns the wait.
    $steps = if ($BounceStatusService) { 5 } else { 4 }

    # vaultKey == the logical name so Set-Password's -Username and the gate's
    # vaultKey resolution address the identical vault slot.
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7ba5d08640a599cc' -Arguments @{ steps = "$steps"; logical = "$logical" }) -InformationAction Continue
    $result.keyChanged = [bool](Set-UserVaultKey -LogicalUser $logical -VaultKey $logical)
    $keyNote = if ($result.keyChanged) { (Format-YurunaOperatorMessage -Key 'configsync.operator_9a3e9ae77884bd96') } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_fb81a6a9d802efb2') }
    Write-Information "[1/$steps] users.yml: $keyNote." -InformationAction Continue

    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_95ba94e5707466db' -Arguments @{ steps = "$steps"; logical = "$logical" }) -InformationAction Continue
    $null = Set-Password -Username $logical -NewPassword $Token
    $null = Reset-UsersConfigCache -Confirm:$false
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_73e9bfb2f827b680' -Arguments @{ steps = "$steps" }) -InformationAction Continue

    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_72d9ea5574f8cb54' -Arguments @{ steps = "$steps" }) -InformationAction Continue
    $tm = Get-EffectiveUser -LogicalUser $logical
    $result.verified = [bool]($tm.vaultKey -and (Test-VaultEntry -VaultKey $tm.vaultKey) -and ((Get-Password -Username $logical) -eq $Token))
    $verifyNote = if ($result.verified) { (Format-YurunaOperatorMessage -Key 'configsync.operator_10c994f8cce1fea5') } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_9dd67c3b0ec875db') }
    Write-Information "[3/$steps] vault: $verifyNote." -InformationAction Continue

    # Retire the names the read chain still falls back to, so one secret lives
    # under exactly one key. Strictly AFTER the verify: the fallback copy is the
    # only thing standing between a failed write and an unreachable host, and
    # deleting it first would turn a recoverable mis-store into a re-enrollment.
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a83b3a51c09e16c5' -Arguments @{ steps = "$steps" }) -InformationAction Continue
    if (-not $result.verified) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_aa2359b64eecf6a9' -Arguments @{ steps = "$steps" }) -InformationAction Continue
    } elseif (-not (Get-Command Remove-VaultEntry -ErrorAction SilentlyContinue) -or
              -not (Get-Command Remove-UserEntry  -ErrorAction SilentlyContinue)) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_368d0ba243d4262e' -Arguments @{ steps = "$steps" }) -InformationAction Continue
    } else {
        $retired = [System.Collections.Generic.List[string]]::new()
        foreach ($old in @('lab-auth-token', 'pool-auth-token')) {
            try {
                $oldKey = ''
                try { $oldKey = [string](Get-EffectiveUser -LogicalUser $old).vaultKey } catch { $null = $_ }
                $removedVault = $false
                if ($oldKey) { $removedVault = [bool](Remove-VaultEntry -VaultKey $oldKey -Confirm:$false) }
                $removedUser = [bool](Remove-UserEntry -LogicalUser $old -Confirm:$false)
                if ($removedVault -or $removedUser) { [void]$retired.Add($old) }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_115a0cebc1971e79' -Arguments @{ old = "$old"; message = "$($_.Exception.Message)" })
            }
        }
        $result.retired = [string[]]@($retired)
        $retiredNote = if ($retired.Count) { (Format-YurunaOperatorMessage -Key 'runner.vault_retired_entries' -Arguments @{ names = ($retired -join ', ') }) } else { (Format-YurunaOperatorMessage -Key 'configsync.operator_9a0416e3d899776d') }
        Write-Information "[4/$steps] vault: $retiredNote." -InformationAction Continue
    }

    if ($BounceStatusService) {
        $startScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'service/Start-StatusService.ps1'
        $pwshExe = [System.Environment]::ProcessPath
        if ((Test-Path -LiteralPath $startScript) -and $pwshExe -and (Test-Path -LiteralPath $pwshExe)) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4f7e838f26c3bf54' -Arguments @{ steps = "$steps"; bounceTimeoutSeconds = "${BounceTimeoutSeconds}" }) -InformationAction Continue
            $bounce = Invoke-StatusServiceBounce -PwshExe $pwshExe -StartScript $startScript -TimeoutSeconds $BounceTimeoutSeconds
            $result.bounced   = $bounce.ok
            $result.bounceLog = $bounce.logPath
            if ($bounce.ok) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5b98a93cb6af39a9' -Arguments @{ steps = "$steps" }) -InformationAction Continue
            } elseif ($bounce.timedOut) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7d74f75db443e9e2' -Arguments @{ bounceTimeoutSeconds = "${BounceTimeoutSeconds}"; logPath = "$($bounce.logPath)" })
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7f5c0d3fa4f8cdf8' -Arguments @{ exitCode = "$($bounce.exitCode)"; logPath = "$($bounce.logPath)" })
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6a63d02d5ebb8e7d')
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
    Sync-ConfigSyncVaultCredential, Test-LabTokenShape, Resolve-ConfigSyncInternalAuthKey, `
    Sync-HostConfiguration, Test-ConfigSyncReferenceFreshness, Set-InternalAuthKey, Get-InternalAuthKeyValue, `
    Request-LabTokenExchange, Get-LabTokenExchangeVerdict, Unprotect-LabTokenEnvelope, `
    Test-ConfigSyncEnvelopeSupport, Get-ConfigSyncEnvelopeSupport
