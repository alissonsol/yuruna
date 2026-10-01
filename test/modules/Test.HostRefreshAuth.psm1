<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42e8622b-95b2-4be6-8609-d3f74ffc4bd0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh remote authorization proof hmac
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
    Remote host refresh authorization: the versioned refresh proof a host
    verifies, the per-host verifier key it holds, and the provisioning
    primitives that create and distribute the refresh secrets.
.DESCRIPTION
    The legacy control proof cannot authorize a refresh: it is lab-wide,
    binds only an expiry, and is minted publicly by the aggregator's host and
    stash redirects. A refresh proof is bound to one host, one request id,
    one tier and ceiling and a short lifetime, and is signed with a key
    derived per host from an operator-provisioned signing authority, so a
    compromised host can verify proofs for itself but mint nothing for any
    other host.

    This module is the host-side twin of the Go package
    extension-sdk/hostrefresh: the same wire format, the same verification
    order and the same shared golden vectors. It imports only the
    globalization module and runs no native command, so the status listener
    can load it through Import-RouteModule in a runspace that holds no host
    driver.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Wire constants
# Shared with extension-sdk/hostrefresh; the golden vectors pin both.
$script:HostRefreshProofVersion = 'yhr1'
$script:HostRefreshAuthorityPrefix = 'yhra1'
$script:HostRefreshCredentialPrefix = 'yhrc1'
$script:HostRefreshHostKeyPrefix = 'yhrk1'
$script:HostRefreshSecretBytes = 32
$script:HostRefreshMaxWireBytes = 512
$script:HostRefreshMaxLifetimeSeconds = 300
$script:HostRefreshSkewSeconds = 60
$script:HostRefreshMaxSecretFileBytes = 4096

# Domain-separation labels: each HMAC input begins with a label no other input
# can produce, so a tag or a derived key never doubles as a proof.
$script:HostRefreshHostKeyLabel = 'yuruna-host-refresh|host-key|v1|'
$script:HostRefreshProofLabel = 'yuruna-host-refresh|v1|host-refresh|'
$script:HostRefreshKeyTagLabel = 'yuruna-host-refresh|tag|v1'
$script:HostRefreshAuthorityTagLabel = 'yuruna-host-refresh|authority-tag|v1'
$script:HostRefreshCredentialTagLabel = 'yuruna-host-refresh|credential-tag|v1'

# The rung ladder in Order; the index of a name is its Order. Remote requests
# may name Order 0 through 4 (the restart tier) only. A suite compares this
# list with the host's rung declaration and with the Go SDK's copy.
$script:HostRefreshRungNames = @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')
$script:HostRefreshRemoteRungCeiling = 4
$script:HostRefreshTiers = @('restart', 'full')

# Which platforms may accept a remote refresh. A platform qualifies only after
# the in-process key-protection checks below have run natively there: the
# BSD-backed file-mode read on macOS and the ACL walk on Windows have not, so
# a key on those platforms cannot yet be trusted to be private.
$script:HostRefreshRemoteQualified = @{ linux = $true; macos = $false; windows = $false }

# .NET regular expressions anchor with \A and \z: '$' also matches before a
# final newline, which would let a line break ride inside an identifier.
$script:HostRefreshHostIdPattern = '\A[0-9a-f]{32}\z'
$script:HostRefreshRequestIdPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:HostRefreshUnixPattern = '\A(0|[1-9][0-9]{0,18})\z'
$script:HostRefreshVersionPattern = '\Ayhr[0-9]+\z'
$script:HostRefreshBase64UrlPattern = '\A[A-Za-z0-9_-]+\z'

$script:HostRefreshVerifierKeyName = 'remote-verifier.key'
$script:HostRefreshAuthorityFileName = 'authority.key'
$script:HostRefreshCredentialFileName = 'operator.credential'

# --- REGION: Encoding and HMAC primitives
function ConvertTo-HostRefreshBase64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-HostRefreshBase64Url {
    # Strict unpadded base64url: the alphabet is checked first because the
    # .NET decoder skips whitespace, and the value is re-encoded and compared
    # so non-zero trailing bits (a second spelling of the same bytes) refuse.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -cnotmatch $script:HostRefreshBase64UrlPattern -or ($Text.Length % 4) -eq 1) { return $null }
    $std = $Text.Replace('-', '+').Replace('_', '/')
    $std = $std.PadRight($std.Length + ((4 - ($std.Length % 4)) % 4), '=')
    [byte[]]$bytes = $null
    try { $bytes = [Convert]::FromBase64String($std) } catch { return $null }
    if (-not [string]::Equals((ConvertTo-HostRefreshBase64Url -Bytes $bytes), $Text, [StringComparison]::Ordinal)) { return $null }
    return , $bytes
}

function Get-HostRefreshHmac {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][string]$Message
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { return , $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message)) }
    finally { $hmac.Dispose() }
}

function ConvertTo-HostRefreshCanonicalHostId {
    # Lowercase with dashes removed: the dashed rendering dashboards show and
    # the bare form hosts write name the same host. '' when not a host id.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$HostId)
    if ([string]::IsNullOrEmpty($HostId)) { return '' }
    $c = $HostId.Replace('-', '').ToLowerInvariant()
    if ($c -cmatch $script:HostRefreshHostIdPattern) { return $c }
    return ''
}

function ConvertFrom-HostRefreshUnix {
    # One canonical spelling per instant: no sign, no leading zero, and a
    # value that fits a signed 64-bit integer. $null otherwise.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The returned variable is [long]-typed; the analyzer infers the type of its literal initializer instead.')]
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param([AllowEmptyString()][string]$Text)
    if ($Text -cnotmatch $script:HostRefreshUnixPattern) { return $null }
    [long]$value = 0
    if (-not [long]::TryParse($Text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    return $value
}

function Test-HostRefreshRung {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Name, [switch]$Remote)
    $order = [Array]::IndexOf([string[]]$script:HostRefreshRungNames, $Name)
    if ($order -lt 0) { return $false }
    if ($Remote) { return $order -le $script:HostRefreshRemoteRungCeiling }
    return $true
}

function Get-HostRefreshPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

# --- REGION: Identity and proof
function Test-YurunaHostRefreshRequestId {
    <#
    .SYNOPSIS
        True when RequestId is a canonical lowercase UUID in the 8-4-4-4-12
        form, the one spelling every refresh channel uses.
    .DESCRIPTION
        One spelling per request is what keeps a retry from ever becoming a
        second request: an uppercase, braced or undashed form of the same
        GUID is refused rather than normalized.
    .PARAMETER RequestId
        The value to check; empty is simply not valid.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RequestId)
    return $RequestId -cmatch $script:HostRefreshRequestIdPattern
}

function Get-YurunaHostRefreshHostKey {
    <#
    .SYNOPSIS
        Derive one host's refresh verifier key from the signing authority.
    .DESCRIPTION
        HMAC-SHA256(authority, "yuruna-host-refresh|host-key|v1|" + hostId).
        Each host holds only its own derived key. Derivation accepts any
        non-empty authority (the golden vector uses a short one); the 32-byte
        floor is enforced where an authority is loaded.
    .PARAMETER AuthorityKey
        The signing authority bytes.
    .PARAMETER HostId
        The canonical 32-hex host id.
    .OUTPUTS
        [byte[]] -- cast the result with [byte[]]; never capture it with @().
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$AuthorityKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId
    )
    if ($AuthorityKey.Length -eq 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'authority' })
    }
    if ($HostId -cnotmatch $script:HostRefreshHostIdPattern) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'hostId' })
    }
    [byte[]]$key = Get-HostRefreshHmac -Key $AuthorityKey -Message ($script:HostRefreshHostKeyLabel + $HostId)
    return , $key
}

function Get-YurunaHostRefreshKeyTag {
    <#
    .SYNOPSIS
        The non-secret name of a host verifier key, for provisioning output
        and status only.
    .DESCRIPTION
        base64url(HMAC-SHA256(key, "yuruna-host-refresh|tag|v1")). It cannot
        be used to forge a proof or recover the key.
    .PARAMETER Key
        The host verifier key bytes.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Key)
    return ConvertTo-HostRefreshBase64Url -Bytes ([byte[]](Get-HostRefreshHmac -Key $Key -Message $script:HostRefreshKeyTagLabel))
}

function Get-YurunaHostRefreshAuthorityTag {
    <#
    .SYNOPSIS
        The non-secret name of a refresh signing authority.
    .PARAMETER Authority
        The signing authority bytes.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Authority)
    return ConvertTo-HostRefreshBase64Url -Bytes ([byte[]](Get-HostRefreshHmac -Key $Authority -Message $script:HostRefreshAuthorityTagLabel))
}

function New-YurunaHostRefreshProof {
    <#
    .SYNOPSIS
        The deterministic refresh proof for the given claims under a host key.
    .DESCRIPTION
        yhr1.<hostId>.<requestId>.<tier>.<maxRung>.<iat>.<exp>.<b64u HMAC>,
        with the HMAC under the host key over the same fields. Every field's
        syntax is validated; the lifetime is not, so the verifier's lifetime
        refusals can be exercised with real signatures. Operators never need
        this: pool-control mints proofs from its provisioned authority.
    .PARAMETER HostKey
        The host verifier key bytes.
    .PARAMETER HostId
        Canonical 32-hex host id.
    .PARAMETER RequestId
        Canonical lowercase UUID.
    .PARAMETER Tier
        restart or full.
    .PARAMETER MaxRung
        A rung name of the ladder.
    .PARAMETER IssuedUnixSeconds
        Issue instant, unix seconds.
    .PARAMETER ExpiryUnixSeconds
        Expiry instant, unix seconds.
    .OUTPUTS
        [string] the wire.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Computes a string in memory; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][byte[]]$HostKey,
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Tier,
        [Parameter(Mandatory)][string]$MaxRung,
        [Parameter(Mandatory)][long]$IssuedUnixSeconds,
        [Parameter(Mandatory)][long]$ExpiryUnixSeconds
    )
    $bad = $null
    if ($HostKey.Length -eq 0) { $bad = 'hostKey' }
    elseif ($HostId -cnotmatch $script:HostRefreshHostIdPattern) { $bad = 'hostId' }
    elseif (-not (Test-YurunaHostRefreshRequestId -RequestId $RequestId)) { $bad = 'requestId' }
    elseif ($script:HostRefreshTiers -cnotcontains $Tier) { $bad = 'tier' }
    elseif (-not (Test-HostRefreshRung -Name $MaxRung)) { $bad = 'maxRung' }
    elseif ($IssuedUnixSeconds -lt 0 -or $ExpiryUnixSeconds -lt 0) { $bad = 'instant' }
    if ($bad) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = $bad }) }
    $iat = $IssuedUnixSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $exp = $ExpiryUnixSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $message = $script:HostRefreshProofLabel + (@($HostId, $RequestId, $Tier, $MaxRung, $iat, $exp) -join '|')
    $mac = ConvertTo-HostRefreshBase64Url -Bytes ([byte[]](Get-HostRefreshHmac -Key $HostKey -Message $message))
    return (@($script:HostRefreshProofVersion, $HostId, $RequestId, $Tier, $MaxRung, $iat, $exp, $mac) -join '.')
}

function Test-YurunaHostRefreshProof {
    <#
    .SYNOPSIS
        Judge a refresh proof against this host's id and the request it was
        asked to admit, at an explicit instant with an explicit skew.
    .DESCRIPTION
        The order is fixed and shared with the Go verifier: missing, then
        shape (over 512 bytes, wrong field count, bad field syntax; another
        yhr<N> version is version_unsupported), then a constant-time MAC over
        the fields as received, then host, request, policy, lifetime, and the
        clock. Checking the MAC before any claim means a forged proof learns
        nothing about which claim would have been wrong.

        Reads no clock: NowUnixSeconds and SkewSeconds are explicit, which is
        what makes every expiry and skew boundary testable. The skew is
        two-sided. Never throws.
    .PARAMETER HostKey
        This host's verifier key; null or empty makes every proof invalid.
    .PARAMETER Wire
        The X-Yuruna-Refresh-Proof header value.
    .PARAMETER HostId
        This host's own id.
    .PARAMETER RequestId
        The request id from the body.
    .PARAMETER Tier
        The tier from the body.
    .PARAMETER MaxRung
        The ceiling from the body.
    .PARAMETER NowUnixSeconds
        The current instant, unix seconds.
    .PARAMETER SkewSeconds
        Two-sided clock tolerance.
    .PARAMETER MaxLifetimeSeconds
        Longest accepted issue-to-expiry span.
    .OUTPUTS
        [pscustomobject] Valid, Reason (ok or a refresh_proof_* code), HostId,
        RequestId, Tier, MaxRung, IssuedUnixSeconds, ExpiryUnixSeconds (the
        claims once the proof has parsed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]]$HostKey,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Wire,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Tier,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MaxRung,
        [Parameter(Mandatory)][long]$NowUnixSeconds,
        [Parameter(Mandatory)][int]$SkewSeconds,
        [int]$MaxLifetimeSeconds = 300
    )
    $verdict = {
        param([string]$Reason, $Fields, [Nullable[long]]$Iat, [Nullable[long]]$Exp)
        [pscustomobject]@{
            Valid             = ($Reason -ceq 'ok')
            Reason            = $Reason
            HostId            = if ($Fields) { $Fields[1] } else { $null }
            RequestId         = if ($Fields) { $Fields[2] } else { $null }
            Tier              = if ($Fields) { $Fields[3] } else { $null }
            MaxRung           = if ($Fields) { $Fields[4] } else { $null }
            IssuedUnixSeconds = $Iat
            ExpiryUnixSeconds = $Exp
        }
    }
    if ([string]::IsNullOrEmpty($Wire)) { return (& $verdict 'refresh_proof_missing' $null $null $null) }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Wire) -gt $script:HostRefreshMaxWireBytes) {
        return (& $verdict 'refresh_proof_malformed' $null $null $null)
    }
    $f = $Wire.Split('.')
    if ($f[0] -cmatch $script:HostRefreshVersionPattern -and $f[0] -cne $script:HostRefreshProofVersion) {
        return (& $verdict 'refresh_proof_version_unsupported' $null $null $null)
    }
    if ($f.Count -ne 8 -or $f[0] -cne $script:HostRefreshProofVersion) { return (& $verdict 'refresh_proof_malformed' $null $null $null) }
    $iat = ConvertFrom-HostRefreshUnix -Text $f[5]
    $exp = ConvertFrom-HostRefreshUnix -Text $f[6]
    [byte[]]$given = ConvertFrom-HostRefreshBase64Url -Text $f[7]
    if ($f[1] -cnotmatch $script:HostRefreshHostIdPattern -or
        -not (Test-YurunaHostRefreshRequestId -RequestId $f[2]) -or
        $script:HostRefreshTiers -cnotcontains $f[3] -or
        -not (Test-HostRefreshRung -Name $f[4]) -or
        $null -eq $iat -or $null -eq $exp -or $null -eq $given -or $given.Length -ne 32) {
        return (& $verdict 'refresh_proof_malformed' $null $null $null)
    }
    if ($null -eq $HostKey -or $HostKey.Length -eq 0) { return (& $verdict 'refresh_proof_invalid' $f $iat $exp) }
    $message = $script:HostRefreshProofLabel + (@($f[1], $f[2], $f[3], $f[4], $f[5], $f[6]) -join '|')
    [byte[]]$expected = Get-HostRefreshHmac -Key $HostKey -Message $message
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals([byte[]]$expected, [byte[]]$given)) {
        return (& $verdict 'refresh_proof_invalid' $f $iat $exp)
    }
    if ($f[1] -cne (ConvertTo-HostRefreshCanonicalHostId -HostId $HostId)) { return (& $verdict 'refresh_proof_host_mismatch' $f $iat $exp) }
    if ($f[2] -cne $RequestId) { return (& $verdict 'refresh_proof_request_mismatch' $f $iat $exp) }
    if ($f[3] -cne $Tier -or $f[4] -cne $MaxRung) { return (& $verdict 'refresh_proof_policy_mismatch' $f $iat $exp) }
    if ($exp -le $iat -or ($exp - $iat) -gt $MaxLifetimeSeconds) { return (& $verdict 'refresh_proof_lifetime_invalid' $f $iat $exp) }
    # Clamped so the differences cannot overflow: both instants are
    # non-negative, so neither subtraction leaves the Int64 range.
    $now = [Math]::Max([long]0, $NowUnixSeconds)
    $skew = [long][Math]::Max(0, $SkewSeconds)
    if ($iat -gt $now -and ($iat - $now) -gt $skew) { return (& $verdict 'refresh_proof_not_yet_valid' $f $iat $exp) }
    if ($now -gt $exp -and ($now - $exp) -gt $skew) { return (& $verdict 'refresh_proof_expired' $f $iat $exp) }
    return (& $verdict 'ok' $f $iat $exp)
}

# --- REGION: Verifier key on this host
function Get-YurunaHostRefreshVerifierKeyPath {
    <#
    .SYNOPSIS
        Where this host's refresh verifier key lives, computed without any
        side effect.
    .DESCRIPTION
        <private root>/remote-verifier.key, where the private root defaults to
        $HOME/.yuruna/host-refresh -- the same root Get-YurunaPrivateStateRoot
        creates and secures, never inside a served tree. A suite pins that the
        two agree.
    .PARAMETER PrivateRoot
        Override the private root (tests and provisioning pass the resolved
        root).
    .OUTPUTS
        [string] the path, or '' when no home directory is known.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$PrivateRoot)
    if ([string]::IsNullOrWhiteSpace($PrivateRoot)) {
        if ([string]::IsNullOrWhiteSpace($HOME)) { return '' }
        $PrivateRoot = [IO.Path]::Combine($HOME, '.yuruna', 'host-refresh')
    }
    return [IO.Path]::Combine($PrivateRoot, $script:HostRefreshVerifierKeyName)
}

function Test-HostRefreshOwnerOnlyAcl {
    # Windows: every Allow entry must name the current user, SYSTEM or the
    # Administrators group. An identity that cannot be resolved fails closed.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $allowed = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch { return $false }
        if ($allowed -notcontains $sid) { return $false }
    }
    return $true
}

function Test-HostRefreshPrivateFileMode {
    # True when no user other than the owner can read, write or execute the
    # file (Unix), or when only the owner, SYSTEM and Administrators hold
    # access (Windows).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return (Test-HostRefreshOwnerOnlyAcl -Path $Path) }
    $mode = [int][System.IO.File]::GetUnixFileMode($Path)
    return ($mode -band 63) -eq 0
}

function Read-HostRefreshSecretText {
    # One secret line from a file, refusing a link, a non-regular file, an
    # oversize file and loose permissions. Returns @{ Status; Text } with
    # Status ok|absent|reparse-point|not-regular|permissions-open|too-large|
    # unreadable; Text only when ok, with one line terminator removed.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $fi = [System.IO.FileInfo]::new($Path)
    if ($fi.LinkTarget) { return @{ Status = 'reparse-point'; Text = $null } }
    if (-not $fi.Exists) {
        if ([System.IO.Directory]::Exists($Path)) { return @{ Status = 'not-regular'; Text = $null } }
        return @{ Status = 'absent'; Text = $null }
    }
    if ($fi.Length -gt $script:HostRefreshMaxSecretFileBytes) { return @{ Status = 'too-large'; Text = $null } }
    try {
        if (-not (Test-HostRefreshPrivateFileMode -Path $Path)) { return @{ Status = 'permissions-open'; Text = $null } }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
    } catch {
        Write-Verbose "Read-HostRefreshSecretText: '$Path' unreadable: $($_.Exception.Message)"
        return @{ Status = 'unreadable'; Text = $null }
    }
    if ($text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    return @{ Status = 'ok'; Text = $text }
}

function ConvertFrom-HostRefreshSecretLine {
    # "<prefix>.<b64u 32 bytes>" -> byte[], or $null when the line is anything
    # else.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Prefix)
    $dot = $Text.IndexOf('.')
    if ($dot -lt 0 -or -not [string]::Equals($Text.Substring(0, $dot), $Prefix, [StringComparison]::Ordinal)) { return $null }
    [byte[]]$b = ConvertFrom-HostRefreshBase64Url -Text $Text.Substring($dot + 1)
    if ($null -eq $b -or $b.Length -ne $script:HostRefreshSecretBytes) { return $null }
    return , $b
}

function ConvertFrom-HostRefreshHostKeyLine {
    # "yhrk1.<hostId>.<b64u 32 bytes>" -> @{ HostId; Key }, or $null.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $f = $Text.Split('.')
    if ($f.Count -ne 3 -or $f[0] -cne $script:HostRefreshHostKeyPrefix -or $f[1] -cnotmatch $script:HostRefreshHostIdPattern) { return $null }
    [byte[]]$b = ConvertFrom-HostRefreshBase64Url -Text $f[2]
    if ($null -eq $b -or $b.Length -ne $script:HostRefreshSecretBytes) { return $null }
    return @{ HostId = $f[1]; Key = $b }
}

function Read-YurunaHostRefreshVerifierKey {
    <#
    .SYNOPSIS
        Read this host's refresh verifier key, with every in-process check a
        private key needs.
    .DESCRIPTION
        Refuses a key file or either of its two parent directories that is a
        symbolic link or reparse point, a file other users can access (Unix
        mode bits; Windows ACL), an oversize or malformed file, and a key
        derived for another host. Never throws.
    .PARAMETER HostId
        This host's id; empty reports host_id_unavailable.
    .PARAMETER PrivateRoot
        Override the private root.
    .OUTPUTS
        [hashtable] State provisioned|missing|invalid; Reason ok|absent|
        key_malformed|key_host_mismatch|key_permissions_open|key_reparse_point|
        key_unreadable|host_id_unavailable; Key [byte[]] or $null; KeyTag.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId,
        [string]$PrivateRoot
    )
    $result = { param([string]$State, [string]$Reason) @{ State = $State; Reason = $Reason; Key = $null; KeyTag = '' } }
    $canonical = ConvertTo-HostRefreshCanonicalHostId -HostId $HostId
    if (-not $canonical) { return (& $result 'invalid' 'host_id_unavailable') }
    $path = Get-YurunaHostRefreshVerifierKeyPath -PrivateRoot $PrivateRoot
    if (-not $path) { return (& $result 'invalid' 'key_unreadable') }
    try {
        $root = [System.IO.Path]::GetDirectoryName($path)
        foreach ($dir in @($root, [System.IO.Path]::GetDirectoryName($root))) {
            if ($dir -and [System.IO.DirectoryInfo]::new($dir).LinkTarget) { return (& $result 'invalid' 'key_reparse_point') }
        }
        $read = Read-HostRefreshSecretText -Path $path
    } catch {
        Write-Verbose "Read-YurunaHostRefreshVerifierKey: $($_.Exception.Message)"
        return (& $result 'invalid' 'key_unreadable')
    }
    switch ($read.Status) {
        'absent' { return (& $result 'missing' 'absent') }
        'reparse-point' { return (& $result 'invalid' 'key_reparse_point') }
        'permissions-open' { return (& $result 'invalid' 'key_permissions_open') }
        'unreadable' { return (& $result 'invalid' 'key_unreadable') }
        'ok' { }
        default { return (& $result 'invalid' 'key_malformed') }
    }
    $parsed = ConvertFrom-HostRefreshHostKeyLine -Text $read.Text
    if ($null -eq $parsed) { return (& $result 'invalid' 'key_malformed') }
    if ($parsed.HostId -cne $canonical) { return (& $result 'invalid' 'key_host_mismatch') }
    [byte[]]$key = $parsed.Key
    return @{ State = 'provisioned'; Reason = 'ok'; Key = $key; KeyTag = (Get-YurunaHostRefreshKeyTag -Key $key) }
}

function Get-YurunaHostRefreshRemoteQualification {
    <#
    .SYNOPSIS
        Whether this platform may accept a remote refresh at all.
    .DESCRIPTION
        A static declaration: linux qualifies; macos and windows do not, until
        the key-protection checks in this module have passed natively there.
    .PARAMETER Platform
        linux, macos or windows; default the current one.
    .OUTPUTS
        [hashtable] Qualified [bool]; Reason ok|platform_unqualified.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([ValidateSet('linux', 'macos', 'windows')][string]$Platform)
    if (-not $Platform) { $Platform = Get-HostRefreshPlatform }
    if ($script:HostRefreshRemoteQualified[$Platform]) { return @{ Qualified = $true; Reason = 'ok' } }
    return @{ Qualified = $false; Reason = 'platform_unqualified' }
}

function Get-YurunaHostRefreshRemoteState {
    <#
    .SYNOPSIS
        The remote-refresh summary a host advertises: provisioned, missing,
        invalid or unqualified. Carries no key material.
    .PARAMETER HostId
        This host's id.
    .PARAMETER PrivateRoot
        Override the private root.
    .PARAMETER Platform
        Override the platform.
    .OUTPUTS
        [hashtable] Remote provisioned|missing|invalid|unqualified; Reason;
        KeyTag (non-secret, '' unless provisioned).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId,
        [string]$PrivateRoot,
        [ValidateSet('linux', 'macos', 'windows')][string]$Platform
    )
    $qualify = @{}
    if ($Platform) { $qualify['Platform'] = $Platform }
    $qualification = Get-YurunaHostRefreshRemoteQualification @qualify
    if (-not $qualification.Qualified) { return @{ Remote = 'unqualified'; Reason = $qualification.Reason; KeyTag = '' } }
    $key = Read-YurunaHostRefreshVerifierKey -HostId $HostId -PrivateRoot $PrivateRoot
    switch ($key.State) {
        'provisioned' { return @{ Remote = 'provisioned'; Reason = 'ok'; KeyTag = $key.KeyTag } }
        'missing' { return @{ Remote = 'missing'; Reason = $key.Reason; KeyTag = '' } }
    }
    return @{ Remote = 'invalid'; Reason = $key.Reason; KeyTag = '' }
}

function Test-YurunaHostRefreshAuthorization {
    <#
    .SYNOPSIS
        The listener's refresh-proof layer for a non-loopback caller: may this
        request be admitted on this host?
    .DESCRIPTION
        In order: the platform must qualify (refresh_remote_unqualified); the
        tier must be restart and the ceiling a rung of Order 0 through 4
        (refresh_tier_not_remote); a verifier key must be installed and valid
        (refresh_remote_unprovisioned, refresh_remote_key_invalid); then the
        proof verdict of Test-YurunaHostRefreshProof with a 60-second skew and
        a 300-second maximum lifetime. Reads the clock once, only when
        NowUnixSeconds is omitted. Never throws: any exception, and a HostId
        that is not a host id, is refresh_verifier_failed.
    .PARAMETER ProofWire
        The X-Yuruna-Refresh-Proof header value.
    .PARAMETER HostId
        This host's own id.
    .PARAMETER RequestId
        The body's request id.
    .PARAMETER Tier
        The body's tier.
    .PARAMETER MaxRung
        The body's ceiling.
    .PARAMETER NowUnixSeconds
        The instant to judge at; omitted reads the clock.
    .PARAMETER PrivateRoot
        Override the private root.
    .PARAMETER Platform
        Override the platform.
    .OUTPUTS
        [hashtable] Authorized [bool]; Reason; HttpStatus 200|403;
        IssuedUnixSeconds; ExpiryUnixSeconds.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ProofWire,
        [AllowEmptyString()][string]$HostId = '',
        [AllowEmptyString()][string]$RequestId = '',
        [AllowEmptyString()][string]$Tier = '',
        [AllowEmptyString()][string]$MaxRung = '',
        [Nullable[long]]$NowUnixSeconds,
        [string]$PrivateRoot,
        [ValidateSet('linux', 'macos', 'windows')][string]$Platform
    )
    $refuse = { param([string]$Reason) @{ Authorized = $false; Reason = $Reason; HttpStatus = 403; IssuedUnixSeconds = $null; ExpiryUnixSeconds = $null } }
    try {
        $qualify = @{}
        if ($Platform) { $qualify['Platform'] = $Platform }
        if (-not (Get-YurunaHostRefreshRemoteQualification @qualify).Qualified) { return (& $refuse 'refresh_remote_unqualified') }
        if ($Tier -cne 'restart' -or -not (Test-HostRefreshRung -Name $MaxRung -Remote)) { return (& $refuse 'refresh_tier_not_remote') }
        $key = Read-YurunaHostRefreshVerifierKey -HostId $HostId -PrivateRoot $PrivateRoot
        # Without its own canonical id the listener can judge no proof at all;
        # that is its failure, and blaming the installed key would send the
        # operator to reinstall a key that is fine.
        if ($key.Reason -ceq 'host_id_unavailable') { return (& $refuse 'refresh_verifier_failed') }
        if ($key.State -ceq 'missing') { return (& $refuse 'refresh_remote_unprovisioned') }
        if ($key.State -cne 'provisioned') { return (& $refuse 'refresh_remote_key_invalid') }
        $now = if ($null -ne $NowUnixSeconds) { [long]$NowUnixSeconds } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $proof = Test-YurunaHostRefreshProof -HostKey ([byte[]]$key.Key) -Wire $ProofWire -HostId $HostId -RequestId $RequestId `
            -Tier $Tier -MaxRung $MaxRung -NowUnixSeconds $now -SkewSeconds $script:HostRefreshSkewSeconds `
            -MaxLifetimeSeconds $script:HostRefreshMaxLifetimeSeconds
        return @{
            Authorized        = [bool]$proof.Valid
            Reason            = $proof.Reason
            HttpStatus        = if ($proof.Valid) { 200 } else { 403 }
            IssuedUnixSeconds = $proof.IssuedUnixSeconds
            ExpiryUnixSeconds = $proof.ExpiryUnixSeconds
        }
    } catch {
        Write-Verbose "Test-YurunaHostRefreshAuthorization: $($_.Exception.Message)"
        return (& $refuse 'refresh_verifier_failed')
    }
}

# --- REGION: Provisioning
function Write-HostRefreshSecretFile {
    # Writes one or more secret lines owner-only from the first byte. Each
    # temporary file is created beside its destination with mode 0600 (Unix)
    # or an owner-only ACL (Windows) and verified private before any secret
    # byte is written, then flushed. Only once every file is staged are they
    # renamed into place, in order: a failure while creating, checking or
    # writing leaves every destination as it was, and only a rename failing
    # after an earlier one succeeded leaves the set partly replaced, which its
    # own refusal names. Every refusal names paths, never content, and removes
    # each temporary file not yet renamed.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string[]]$Line,
        [switch]$Overwrite
    )
    $temps = [string[]]::new($Path.Count)
    $moved = 0
    $current = $Path[0]
    try {
        for ($i = 0; $i -lt $Path.Count; $i++) {
            $current = $Path[$i]
            $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($current))
            $temps[$i] = [System.IO.Path]::Combine($dir, '.' + [System.IO.Path]::GetFileName($current) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $options = [System.IO.FileStreamOptions]::new()
            $options.Mode = [System.IO.FileMode]::CreateNew
            $options.Access = [System.IO.FileAccess]::Write
            $options.Share = [System.IO.FileShare]::None
            if (-not $IsWindows) { $options.UnixCreateMode = [System.IO.UnixFileMode]'UserRead, UserWrite' }
            $stream = [System.IO.FileStream]::new($temps[$i], $options)
            try {
                if ($IsWindows) {
                    $acl = Get-Acl -LiteralPath $temps[$i]
                    $acl.SetAccessRuleProtection($true, $false)
                    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
                    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                            [System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))
                    Set-Acl -LiteralPath $temps[$i] -AclObject $acl -ErrorAction Stop -WhatIf:$false -Confirm:$false
                }
                # A filesystem that ignores the requested mode would otherwise
                # receive the secret readable by others.
                if (-not (Test-HostRefreshPrivateFileMode -Path $temps[$i])) { throw [System.IO.IOException]::new('mode') }
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line[$i] + "`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
        }
        for ($i = 0; $i -lt $Path.Count; $i++) {
            $current = $Path[$i]
            [System.IO.File]::Move($temps[$i], $current, [bool]$Overwrite)
            $moved++
        }
    } catch {
        $detail = $_.Exception.GetType().Name
        foreach ($t in $temps) {
            if (-not $t) { continue }
            try { if ([System.IO.File]::Exists($t)) { [System.IO.File]::Delete($t) } } catch { Write-Verbose "cleanup: $($_.Exception.Message)" }
        }
        if ($moved -gt 0) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_authority_incomplete' -Arguments @{
                    path = ($Path[0..($moved - 1)] -join ', '); pendingPath = "$current"; detail = "$detail" })
        }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_write_failed' -Arguments @{ path = "$current"; detail = "$detail" })
    }
}

function New-HostRefreshRandomSecret {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns random bytes in memory; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()
    $b = [byte[]]::new($script:HostRefreshSecretBytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}

function Initialize-HostRefreshSecretDirectory {
    # Creates the directory owner-only when absent and refuses one that is a
    # link: a secret directory that is an alias could put the secret anywhere.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Directory)
    $info = [System.IO.DirectoryInfo]::new($Directory)
    if ($info.LinkTarget) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_private_root_unavailable' -Arguments @{ reason = 'reparse-point' })
    }
    if (-not $info.Exists) {
        if ($IsWindows) { [void][System.IO.Directory]::CreateDirectory($Directory) }
        else { [void][System.IO.Directory]::CreateDirectory($Directory, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
}

function New-YurunaHostRefreshAuthority {
    <#
    .SYNOPSIS
        Create the refresh signing authority and the operator refresh
        credential in a private directory.
    .DESCRIPTION
        Two independent 32-byte random secrets, written owner-only as
        authority.key (yhra1) and operator.credential (yhrc1). Refuses to
        replace existing files unless Rotate is given; rotating invalidates
        every host key derived from the old authority. Both files are staged
        before either is replaced, so a failed write changes neither. If the
        second rename alone fails, the refusal says which file was written;
        run again with Rotate to replace both. The returned record carries
        tags and paths, never a secret.
    .PARAMETER Directory
        Where to write; created owner-only when absent.
    .PARAMETER Rotate
        Replace an existing authority and credential.
    .OUTPUTS
        [pscustomobject] Created; Reason ok|exists|preview; AuthorityPath;
        CredentialPath; AuthorityTag; CredentialTag; Rotated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Directory,
        [switch]$Rotate
    )
    $authorityPath = [System.IO.Path]::Combine($Directory, $script:HostRefreshAuthorityFileName)
    $credentialPath = [System.IO.Path]::Combine($Directory, $script:HostRefreshCredentialFileName)
    $record = { param([bool]$Created, [string]$Reason, [string]$FirstTag, [string]$SecondTag, [bool]$Rotated)
        [pscustomobject]@{ Created = $Created; Reason = $Reason; AuthorityPath = $authorityPath; CredentialPath = $credentialPath
            AuthorityTag = $FirstTag; CredentialTag = $SecondTag; Rotated = $Rotated }
    }
    $exists = [System.IO.File]::Exists($authorityPath) -or [System.IO.File]::Exists($credentialPath)
    if ($exists -and -not $Rotate) { return (& $record $false 'exists' '' '' $false) }
    if (-not $PSCmdlet.ShouldProcess($Directory, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auth_action_create_authority'))) {
        return (& $record $false 'preview' '' '' $false)
    }
    Initialize-HostRefreshSecretDirectory -Directory $Directory
    [byte[]]$authority = New-HostRefreshRandomSecret
    [byte[]]$credential = New-HostRefreshRandomSecret
    while ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($authority, $credential)) {
        [byte[]]$credential = New-HostRefreshRandomSecret
    }
    Write-HostRefreshSecretFile -Path @($authorityPath, $credentialPath) -Overwrite:$Rotate -Line @(
        ($script:HostRefreshAuthorityPrefix + '.' + (ConvertTo-HostRefreshBase64Url -Bytes $authority)),
        ($script:HostRefreshCredentialPrefix + '.' + (ConvertTo-HostRefreshBase64Url -Bytes $credential)))
    $credentialTag = ConvertTo-HostRefreshBase64Url -Bytes ([byte[]](Get-HostRefreshHmac -Key $credential -Message $script:HostRefreshCredentialTagLabel))
    return (& $record $true 'ok' (Get-YurunaHostRefreshAuthorityTag -Authority $authority) $credentialTag ([bool]$exists))
}

function Read-YurunaHostRefreshAuthority {
    <#
    .SYNOPSIS
        Load the refresh signing authority from a private directory.
    .DESCRIPTION
        Throws a localized message when the authority is missing, readable by
        other users, a link, not a regular file, oversize or unreadable (each
        named), or not one yhra1 line of 32 bytes.
    .PARAMETER Directory
        The authority directory.
    .OUTPUTS
        [hashtable] Authority [byte[]]; AuthorityTag; Path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Directory)
    $path = [System.IO.Path]::Combine($Directory, $script:HostRefreshAuthorityFileName)
    $read = Read-HostRefreshSecretText -Path $path
    switch ($read.Status) {
        'ok' { }
        'absent' { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_authority_missing' -Arguments @{ path = "$Directory" }) }
        'permissions-open' { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_permissions_open' -Arguments @{ path = "$path" }) }
        default { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_unusable' -Arguments @{ path = "$path"; reason = "$($read.Status)" }) }
    }
    [byte[]]$authority = ConvertFrom-HostRefreshSecretLine -Text $read.Text -Prefix $script:HostRefreshAuthorityPrefix
    if ($null -eq $authority) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_malformed' -Arguments @{ path = "$path"; prefix = $script:HostRefreshAuthorityPrefix })
    }
    return @{ Authority = $authority; AuthorityTag = (Get-YurunaHostRefreshAuthorityTag -Authority $authority); Path = $path }
}

function ConvertTo-YurunaHostRefreshHostKeyLine {
    <#
    .SYNOPSIS
        The one line that carries a host's refresh verifier key to that host.
    .DESCRIPTION
        yhrk1.<hostId>.<unpadded base64url key>: the encoding
        Export-YurunaHostRefreshHostKey writes and
        Install-YurunaHostRefreshVerifierKey reads, so a caller that derives a
        key itself never spells the format a second time. The line is secret
        material; write it only to an owner-only file.
    .PARAMETER HostId
        The host's id, dashed or bare.
    .PARAMETER Key
        The 32-byte host verifier key.
    .OUTPUTS
        [string] the line, without a line terminator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Key
    )
    $canonical = ConvertTo-HostRefreshCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    if ($Key.Length -ne $script:HostRefreshSecretBytes) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'hostKey' })
    }
    return $script:HostRefreshHostKeyPrefix + '.' + $canonical + '.' + (ConvertTo-HostRefreshBase64Url -Bytes $Key)
}

function Export-YurunaHostRefreshHostKey {
    <#
    .SYNOPSIS
        Write one host's refresh verifier key to a file for transport to that
        host.
    .DESCRIPTION
        Derives the key from the authority and writes one yhrk1 line
        owner-only. Refuses an existing OutputPath rather than replacing a
        file the operator may still need. The record carries the tag, never
        the key.
    .PARAMETER AuthorityDirectory
        The authority directory.
    .PARAMETER HostId
        The destination host's id (dashed or bare).
    .PARAMETER OutputPath
        The file to create.
    .OUTPUTS
        [pscustomobject] Written; Reason ok|exists|preview; HostId; KeyTag; Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AuthorityDirectory,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$HostId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )
    $canonical = ConvertTo-HostRefreshCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    $record = { param([bool]$Written, [string]$Reason, [string]$KeyTag)
        [pscustomobject]@{ Written = $Written; Reason = $Reason; HostId = $canonical; KeyTag = $KeyTag; Path = $OutputPath } }
    if ([System.IO.File]::Exists($OutputPath) -or [System.IO.Directory]::Exists($OutputPath) -or [System.IO.FileInfo]::new($OutputPath).LinkTarget) {
        return (& $record $false 'exists' '')
    }
    $authority = Read-YurunaHostRefreshAuthority -Directory $AuthorityDirectory
    [byte[]]$key = Get-YurunaHostRefreshHostKey -AuthorityKey ([byte[]]$authority.Authority) -HostId $canonical
    $tag = Get-YurunaHostRefreshKeyTag -Key $key
    if (-not $PSCmdlet.ShouldProcess($OutputPath, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auth_action_export_host_key' -Arguments @{ hostId = $canonical }))) {
        return (& $record $false 'preview' $tag)
    }
    Write-HostRefreshSecretFile -Path $OutputPath -Line (ConvertTo-YurunaHostRefreshHostKeyLine -HostId $canonical -Key $key)
    return (& $record $true 'ok' $tag)
}

function Install-YurunaHostRefreshVerifierKey {
    <#
    .SYNOPSIS
        Install a transported refresh verifier key on this host.
    .DESCRIPTION
        Validates the yhrk1 line and that it was derived for this host, then
        writes it owner-only into the private root, replacing any previous
        key. Throws a localized message on a malformed key, a key for another
        host, or a private root that is a link or, for a real write, missing.
        A preview accepts a root that does not exist yet, because the caller
        creates it only for the real run.
    .PARAMETER KeyText
        The key line (one trailing line terminator is ignored).
    .PARAMETER HostId
        This host's id.
    .PARAMETER PrivateRoot
        The resolved private root.
    .PARAMETER SourcePath
        Where the key came from, named in a refusal.
    .OUTPUTS
        [pscustomobject] Installed; Reason ok|preview; HostId; KeyTag; Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$KeyText,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$HostId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot,
        [string]$SourcePath = 'KeyText'
    )
    $canonical = ConvertTo-HostRefreshCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    $text = $KeyText
    if ($text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    $parsed = ConvertFrom-HostRefreshHostKeyLine -Text $text
    if ($null -eq $parsed) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_key_malformed' -Arguments @{ path = "$SourcePath"; prefix = $script:HostRefreshHostKeyPrefix })
    }
    if ($parsed.HostId -cne $canonical) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_host_id_mismatch' -Arguments @{ keyHostId = $parsed.HostId; hostId = $canonical })
    }
    if ([System.IO.DirectoryInfo]::new($PrivateRoot).LinkTarget) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_private_root_unavailable' -Arguments @{ reason = 'reparse-point' })
    }
    $path = Get-YurunaHostRefreshVerifierKeyPath -PrivateRoot $PrivateRoot
    [byte[]]$key = $parsed.Key
    $tag = Get-YurunaHostRefreshKeyTag -Key $key
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auth_action_install_host_key' -Arguments @{ hostId = $canonical }))) {
        return [pscustomobject]@{ Installed = $false; Reason = 'preview'; HostId = $canonical; KeyTag = $tag; Path = $path }
    }
    # Only the real write needs the root to exist: a preview runs before the
    # caller has created and secured it.
    $rootInfo = [System.IO.DirectoryInfo]::new($PrivateRoot)
    if ($rootInfo.LinkTarget -or -not $rootInfo.Exists) {
        $why = if ($rootInfo.LinkTarget) { 'reparse-point' } else { 'absent' }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_auth_private_root_unavailable' -Arguments @{ reason = $why })
    }
    Write-HostRefreshSecretFile -Path $path -Line $text -Overwrite
    return [pscustomobject]@{ Installed = $true; Reason = 'ok'; HostId = $canonical; KeyTag = $tag; Path = $path }
}

function Remove-YurunaHostRefreshVerifierKey {
    <#
    .SYNOPSIS
        Delete this host's refresh verifier key, after which the host refuses
        every non-loopback refresh request.
    .PARAMETER PrivateRoot
        The private root.
    .OUTPUTS
        [pscustomobject] Removed; Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot)
    $path = Get-YurunaHostRefreshVerifierKeyPath -PrivateRoot $PrivateRoot
    $info = [System.IO.FileInfo]::new($path)
    if (-not $info.Exists -and -not $info.LinkTarget) { return [pscustomobject]@{ Removed = $false; Path = $path } }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auth_action_remove_host_key'))) {
        return [pscustomobject]@{ Removed = $false; Path = $path }
    }
    [System.IO.File]::Delete($path)
    return [pscustomobject]@{ Removed = $true; Path = $path }
}

Export-ModuleMember -Function `
    Test-YurunaHostRefreshRequestId, Get-YurunaHostRefreshHostKey, Get-YurunaHostRefreshKeyTag, Get-YurunaHostRefreshAuthorityTag, `
    New-YurunaHostRefreshProof, Test-YurunaHostRefreshProof, Get-YurunaHostRefreshVerifierKeyPath, Read-YurunaHostRefreshVerifierKey, `
    Get-YurunaHostRefreshRemoteQualification, Get-YurunaHostRefreshRemoteState, Test-YurunaHostRefreshAuthorization, `
    New-YurunaHostRefreshAuthority, Read-YurunaHostRefreshAuthority, ConvertTo-YurunaHostRefreshHostKeyLine, Export-YurunaHostRefreshHostKey, `
    Install-YurunaHostRefreshVerifierKey, Remove-YurunaHostRefreshVerifierKey
