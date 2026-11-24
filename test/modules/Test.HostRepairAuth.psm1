<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42e8622b-95b2-4be6-8609-d3f74ffc4bd0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-repair remote authorization proof hmac
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
    Remote host operation authorization: the versioned repair proof a host
    verifies, the per-host verifier key it holds, the yup1 host update proof
    and the pool-control record it is verified with, and the provisioning
    primitives that create and distribute them.
.DESCRIPTION
    The legacy control proof cannot authorize a repair: it is lab-wide,
    binds only an expiry, and is minted publicly by the aggregator's host and
    stash redirects. A repair proof is bound to one host, one request id,
    one tier and ceiling and a short lifetime, and is signed with a key
    derived per host from an operator-provisioned signing authority, so a
    compromised host can verify proofs for itself but mint nothing for any
    other host.

    A host update proof is an RSA signature instead, verified with
    pool-control's public key from the pool-control record, so the host keeps
    no secret for it and no platform is barred by where one could be kept.

    This module is the host-side twin of the Go packages
    extension-sdk/hostrepair and extension-sdk/hostupdate: the same wire
    formats, the same verification order and the same shared golden vectors. It imports only the
    globalization module and runs no native command, so the status listener
    can load it through Import-RouteModule in a runspace that holds no host
    driver.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Wire constants
# Shared with extension-sdk/hostrepair; the golden vectors pin both.
$script:HostRepairProofVersion = 'yrp1'
$script:HostRepairAuthorityPrefix = 'yrpa1'
$script:HostRepairCredentialPrefix = 'yoc1'
$script:HostRepairHostKeyPrefix = 'yrpk1'
$script:HostRepairSecretBytes = 32
$script:HostRepairMaxWireBytes = 512
$script:HostRepairMaxLifetimeSeconds = 300
$script:HostRepairSkewSeconds = 60
$script:HostRepairMaxSecretFileBytes = 4096

# Domain-separation labels: each HMAC input begins with a label no other input
# can produce, so a tag or a derived key never doubles as a proof.
$script:HostRepairHostKeyLabel = 'yuruna-host-repair|host-key|v1|'
$script:HostRepairProofLabel = 'yuruna-host-repair|v1|host-repair|'
$script:HostRepairKeyTagLabel = 'yuruna-host-repair|tag|v1'
$script:HostRepairAuthorityTagLabel = 'yuruna-host-repair|authority-tag|v1'
$script:HostRepairCredentialTagLabel = 'yuruna-operator-credential|tag|v1'

# The rung ladder in Order; the index of a name is its Order. Remote requests
# may name Order 0 through 4 (the restart tier) only. A suite compares this
# list with the host's rung declaration and with the Go SDK's copy.
$script:HostRepairRungNames = @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')
$script:HostRepairRemoteRungCeiling = 4
$script:HostRepairTiers = @('restart', 'full')

# Which platforms may accept a remote repair. A platform qualifies only after
# the in-process key-protection checks below have run natively there: the
# BSD-backed file-mode read on macOS and the ACL walk on Windows have not, so
# a key on those platforms cannot yet be trusted to be private.
$script:HostRepairRemoteQualified = @{ linux = $true; macos = $false; windows = $false }

# .NET regular expressions anchor with \A and \z: '$' also matches before a
# final newline, which would let a line break ride inside an identifier.
$script:HostRepairHostIdPattern = '\A[0-9a-f]{32}\z'
$script:HostOperationRequestIdPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:HostRepairUnixPattern = '\A(0|[1-9][0-9]{0,18})\z'
$script:HostRepairVersionPattern = '\Ayrp[0-9]+\z'
$script:HostRepairBase64UrlPattern = '\A[A-Za-z0-9_-]+\z'

$script:HostRepairVerifierKeyName = 'remote-verifier.key'
$script:HostRepairAuthorityFileName = 'authority.key'
$script:HostRepairCredentialFileName = 'operator.credential'

# --- REGION: Encoding and HMAC primitives
function ConvertTo-HostRepairBase64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-HostRepairBase64Url {
    # Strict unpadded base64url: the alphabet is checked first because the
    # .NET decoder skips whitespace, and the value is re-encoded and compared
    # so non-zero trailing bits (a second spelling of the same bytes) refuse.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -cnotmatch $script:HostRepairBase64UrlPattern -or ($Text.Length % 4) -eq 1) { return $null }
    $std = $Text.Replace('-', '+').Replace('_', '/')
    $std = $std.PadRight($std.Length + ((4 - ($std.Length % 4)) % 4), '=')
    [byte[]]$bytes = $null
    try { $bytes = [Convert]::FromBase64String($std) } catch { return $null }
    if (-not [string]::Equals((ConvertTo-HostRepairBase64Url -Bytes $bytes), $Text, [StringComparison]::Ordinal)) { return $null }
    return , $bytes
}

function Get-HostRepairHmac {
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

function ConvertTo-HostRepairCanonicalHostId {
    # Lowercase with dashes removed: the dashed rendering dashboards show and
    # the bare form hosts write name the same host. '' when not a host id.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$HostId)
    if ([string]::IsNullOrEmpty($HostId)) { return '' }
    $c = $HostId.Replace('-', '').ToLowerInvariant()
    if ($c -cmatch $script:HostRepairHostIdPattern) { return $c }
    return ''
}

function ConvertFrom-HostRepairUnix {
    # One canonical spelling per instant: no sign, no leading zero, and a
    # value that fits a signed 64-bit integer. $null otherwise.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The returned variable is [long]-typed; the analyzer infers the type of its literal initializer instead.')]
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param([AllowEmptyString()][string]$Text)
    if ($Text -cnotmatch $script:HostRepairUnixPattern) { return $null }
    [long]$value = 0
    if (-not [long]::TryParse($Text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    return $value
}

function Test-HostRepairRung {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Name, [switch]$Remote)
    $order = [Array]::IndexOf([string[]]$script:HostRepairRungNames, $Name)
    if ($order -lt 0) { return $false }
    if ($Remote) { return $order -le $script:HostRepairRemoteRungCeiling }
    return $true
}

function Get-HostRepairPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

# --- REGION: Identity and proof
function Test-YurunaHostOperationRequestId {
    <#
    .SYNOPSIS
        True when RequestId is a canonical lowercase UUID in the 8-4-4-4-12
        form, the one spelling every repair channel uses.
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
    return $RequestId -cmatch $script:HostOperationRequestIdPattern
}

function Get-YurunaHostRepairHostKey {
    <#
    .SYNOPSIS
        Derive one host's repair verifier key from the signing authority.
    .DESCRIPTION
        HMAC-SHA256(authority, "yuruna-host-repair|host-key|v1|" + hostId).
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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'authority' })
    }
    if ($HostId -cnotmatch $script:HostRepairHostIdPattern) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'hostId' })
    }
    [byte[]]$key = Get-HostRepairHmac -Key $AuthorityKey -Message ($script:HostRepairHostKeyLabel + $HostId)
    return , $key
}

function Get-YurunaHostRepairKeyTag {
    <#
    .SYNOPSIS
        The non-secret name of a host verifier key, for provisioning output
        and status only.
    .DESCRIPTION
        base64url(HMAC-SHA256(key, "yuruna-host-repair|tag|v1")). It cannot
        be used to forge a proof or recover the key.
    .PARAMETER Key
        The host verifier key bytes.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Key)
    return ConvertTo-HostRepairBase64Url -Bytes ([byte[]](Get-HostRepairHmac -Key $Key -Message $script:HostRepairKeyTagLabel))
}

function Get-YurunaHostRepairAuthorityTag {
    <#
    .SYNOPSIS
        The non-secret name of a repair signing authority.
    .PARAMETER Authority
        The signing authority bytes.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Authority)
    return ConvertTo-HostRepairBase64Url -Bytes ([byte[]](Get-HostRepairHmac -Key $Authority -Message $script:HostRepairAuthorityTagLabel))
}

function New-YurunaHostRepairProof {
    <#
    .SYNOPSIS
        The deterministic repair proof for the given claims under a host key.
    .DESCRIPTION
        yrp1.<hostId>.<requestId>.<tier>.<maxRung>.<iat>.<exp>.<b64u HMAC>,
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
    elseif ($HostId -cnotmatch $script:HostRepairHostIdPattern) { $bad = 'hostId' }
    elseif (-not (Test-YurunaHostOperationRequestId -RequestId $RequestId)) { $bad = 'requestId' }
    elseif ($script:HostRepairTiers -cnotcontains $Tier) { $bad = 'tier' }
    elseif (-not (Test-HostRepairRung -Name $MaxRung)) { $bad = 'maxRung' }
    elseif ($IssuedUnixSeconds -lt 0 -or $ExpiryUnixSeconds -lt 0) { $bad = 'instant' }
    if ($bad) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = $bad }) }
    $iat = $IssuedUnixSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $exp = $ExpiryUnixSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $message = $script:HostRepairProofLabel + (@($HostId, $RequestId, $Tier, $MaxRung, $iat, $exp) -join '|')
    $mac = ConvertTo-HostRepairBase64Url -Bytes ([byte[]](Get-HostRepairHmac -Key $HostKey -Message $message))
    return (@($script:HostRepairProofVersion, $HostId, $RequestId, $Tier, $MaxRung, $iat, $exp, $mac) -join '.')
}

function Test-YurunaHostRepairProof {
    <#
    .SYNOPSIS
        Judge a repair proof against this host's id and the request it was
        asked to admit, at an explicit instant with an explicit skew.
    .DESCRIPTION
        The order is fixed and shared with the Go verifier: missing, then
        shape (over 512 bytes, wrong field count, bad field syntax; another
        yrp<N> version is version_unsupported), then a constant-time MAC over
        the fields as received, then host, request, policy, lifetime, and the
        clock. Checking the MAC before any claim means a forged proof learns
        nothing about which claim would have been wrong.

        Reads no clock: NowUnixSeconds and SkewSeconds are explicit, which is
        what makes every expiry and skew boundary testable. The skew is
        two-sided. Never throws.
    .PARAMETER HostKey
        This host's verifier key; null or empty makes every proof invalid.
    .PARAMETER Wire
        The X-Yuruna-Repair-Proof header value.
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
        [pscustomobject] Valid, Reason (ok or a repair_proof_* code), HostId,
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
    if ([string]::IsNullOrEmpty($Wire)) { return (& $verdict 'repair_proof_missing' $null $null $null) }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Wire) -gt $script:HostRepairMaxWireBytes) {
        return (& $verdict 'repair_proof_malformed' $null $null $null)
    }
    $f = $Wire.Split('.')
    if ($f[0] -cmatch $script:HostRepairVersionPattern -and $f[0] -cne $script:HostRepairProofVersion) {
        return (& $verdict 'repair_proof_version_unsupported' $null $null $null)
    }
    if ($f.Count -ne 8 -or $f[0] -cne $script:HostRepairProofVersion) { return (& $verdict 'repair_proof_malformed' $null $null $null) }
    $iat = ConvertFrom-HostRepairUnix -Text $f[5]
    $exp = ConvertFrom-HostRepairUnix -Text $f[6]
    [byte[]]$given = ConvertFrom-HostRepairBase64Url -Text $f[7]
    if ($f[1] -cnotmatch $script:HostRepairHostIdPattern -or
        -not (Test-YurunaHostOperationRequestId -RequestId $f[2]) -or
        $script:HostRepairTiers -cnotcontains $f[3] -or
        -not (Test-HostRepairRung -Name $f[4]) -or
        $null -eq $iat -or $null -eq $exp -or $null -eq $given -or $given.Length -ne 32) {
        return (& $verdict 'repair_proof_malformed' $null $null $null)
    }
    if ($null -eq $HostKey -or $HostKey.Length -eq 0) { return (& $verdict 'repair_proof_invalid' $f $iat $exp) }
    $message = $script:HostRepairProofLabel + (@($f[1], $f[2], $f[3], $f[4], $f[5], $f[6]) -join '|')
    [byte[]]$expected = Get-HostRepairHmac -Key $HostKey -Message $message
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals([byte[]]$expected, [byte[]]$given)) {
        return (& $verdict 'repair_proof_invalid' $f $iat $exp)
    }
    if ($f[1] -cne (ConvertTo-HostRepairCanonicalHostId -HostId $HostId)) { return (& $verdict 'repair_proof_host_mismatch' $f $iat $exp) }
    if ($f[2] -cne $RequestId) { return (& $verdict 'repair_proof_request_mismatch' $f $iat $exp) }
    if ($f[3] -cne $Tier -or $f[4] -cne $MaxRung) { return (& $verdict 'repair_proof_policy_mismatch' $f $iat $exp) }
    if ($exp -le $iat -or ($exp - $iat) -gt $MaxLifetimeSeconds) { return (& $verdict 'repair_proof_lifetime_invalid' $f $iat $exp) }
    # Clamped so the differences cannot overflow: both instants are
    # non-negative, so neither subtraction leaves the Int64 range.
    $now = [Math]::Max([long]0, $NowUnixSeconds)
    $skew = [long][Math]::Max(0, $SkewSeconds)
    if ($iat -gt $now -and ($iat - $now) -gt $skew) { return (& $verdict 'repair_proof_not_yet_valid' $f $iat $exp) }
    if ($now -gt $exp -and ($now - $exp) -gt $skew) { return (& $verdict 'repair_proof_expired' $f $iat $exp) }
    return (& $verdict 'ok' $f $iat $exp)
}

# --- REGION: Verifier key on this host
function Get-YurunaHostRepairVerifierKeyPath {
    <#
    .SYNOPSIS
        Where this host's repair verifier key lives, computed without any
        side effect.
    .DESCRIPTION
        <private root>/remote-verifier.key, where the private root defaults to
        $HOME/.yuruna/host-repair -- the same root Get-YurunaPrivateStateRoot
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
        $PrivateRoot = [IO.Path]::Combine($HOME, '.yuruna', 'host-repair')
    }
    return [IO.Path]::Combine($PrivateRoot, $script:HostRepairVerifierKeyName)
}

function Test-HostRepairOwnerOnlyAcl {
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

function Test-HostRepairPrivateFileMode {
    # True when no user other than the owner can read, write or execute the
    # file (Unix), or when only the owner, SYSTEM and Administrators hold
    # access (Windows).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return (Test-HostRepairOwnerOnlyAcl -Path $Path) }
    $mode = [int][System.IO.File]::GetUnixFileMode($Path)
    return ($mode -band 63) -eq 0
}

function Read-HostRepairSecretText {
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
    if ($fi.Length -gt $script:HostRepairMaxSecretFileBytes) { return @{ Status = 'too-large'; Text = $null } }
    try {
        if (-not (Test-HostRepairPrivateFileMode -Path $Path)) { return @{ Status = 'permissions-open'; Text = $null } }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
    } catch {
        Write-Verbose "Read-HostRepairSecretText: '$Path' unreadable: $($_.Exception.Message)"
        return @{ Status = 'unreadable'; Text = $null }
    }
    if ($text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    return @{ Status = 'ok'; Text = $text }
}

function ConvertFrom-HostRepairSecretLine {
    # "<prefix>.<b64u 32 bytes>" -> byte[], or $null when the line is anything
    # else.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Prefix)
    $dot = $Text.IndexOf('.')
    if ($dot -lt 0 -or -not [string]::Equals($Text.Substring(0, $dot), $Prefix, [StringComparison]::Ordinal)) { return $null }
    [byte[]]$b = ConvertFrom-HostRepairBase64Url -Text $Text.Substring($dot + 1)
    if ($null -eq $b -or $b.Length -ne $script:HostRepairSecretBytes) { return $null }
    return , $b
}

function ConvertFrom-HostRepairHostKeyLine {
    # "yrpk1.<hostId>.<b64u 32 bytes>" -> @{ HostId; Key }, or $null.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $f = $Text.Split('.')
    if ($f.Count -ne 3 -or $f[0] -cne $script:HostRepairHostKeyPrefix -or $f[1] -cnotmatch $script:HostRepairHostIdPattern) { return $null }
    [byte[]]$b = ConvertFrom-HostRepairBase64Url -Text $f[2]
    if ($null -eq $b -or $b.Length -ne $script:HostRepairSecretBytes) { return $null }
    return @{ HostId = $f[1]; Key = $b }
}

function Read-YurunaHostRepairVerifierKey {
    <#
    .SYNOPSIS
        Read this host's repair verifier key, with every in-process check a
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
    $canonical = ConvertTo-HostRepairCanonicalHostId -HostId $HostId
    if (-not $canonical) { return (& $result 'invalid' 'host_id_unavailable') }
    $path = Get-YurunaHostRepairVerifierKeyPath -PrivateRoot $PrivateRoot
    if (-not $path) { return (& $result 'invalid' 'key_unreadable') }
    try {
        $root = [System.IO.Path]::GetDirectoryName($path)
        foreach ($dir in @($root, [System.IO.Path]::GetDirectoryName($root))) {
            if ($dir -and [System.IO.DirectoryInfo]::new($dir).LinkTarget) { return (& $result 'invalid' 'key_reparse_point') }
        }
        $read = Read-HostRepairSecretText -Path $path
    } catch {
        Write-Verbose "Read-YurunaHostRepairVerifierKey: $($_.Exception.Message)"
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
    $parsed = ConvertFrom-HostRepairHostKeyLine -Text $read.Text
    if ($null -eq $parsed) { return (& $result 'invalid' 'key_malformed') }
    if ($parsed.HostId -cne $canonical) { return (& $result 'invalid' 'key_host_mismatch') }
    [byte[]]$key = $parsed.Key
    return @{ State = 'provisioned'; Reason = 'ok'; Key = $key; KeyTag = (Get-YurunaHostRepairKeyTag -Key $key) }
}

function Get-YurunaHostRepairRemoteQualification {
    <#
    .SYNOPSIS
        Whether this platform may accept a remote repair at all.
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
    if (-not $Platform) { $Platform = Get-HostRepairPlatform }
    if ($script:HostRepairRemoteQualified[$Platform]) { return @{ Qualified = $true; Reason = 'ok' } }
    return @{ Qualified = $false; Reason = 'platform_unqualified' }
}

function Get-YurunaHostRepairRemoteState {
    <#
    .SYNOPSIS
        The remote-repair summary a host advertises: provisioned, missing,
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
    $qualification = Get-YurunaHostRepairRemoteQualification @qualify
    if (-not $qualification.Qualified) { return @{ Remote = 'unqualified'; Reason = $qualification.Reason; KeyTag = '' } }
    $key = Read-YurunaHostRepairVerifierKey -HostId $HostId -PrivateRoot $PrivateRoot
    switch ($key.State) {
        'provisioned' { return @{ Remote = 'provisioned'; Reason = 'ok'; KeyTag = $key.KeyTag } }
        'missing' { return @{ Remote = 'missing'; Reason = $key.Reason; KeyTag = '' } }
    }
    return @{ Remote = 'invalid'; Reason = $key.Reason; KeyTag = '' }
}

function Test-YurunaHostRepairAuthorization {
    <#
    .SYNOPSIS
        The listener's repair-proof layer for a non-loopback caller: may this
        request be admitted on this host?
    .DESCRIPTION
        In order: the platform must qualify (repair_remote_unqualified); the
        tier must be restart and the ceiling a rung of Order 0 through 4
        (repair_tier_not_remote); a verifier key must be installed and valid
        (repair_remote_unprovisioned, repair_remote_key_invalid); then the
        proof verdict of Test-YurunaHostRepairProof with a 60-second skew and
        a 300-second maximum lifetime. Reads the clock once, only when
        NowUnixSeconds is omitted. Never throws: any exception, and a HostId
        that is not a host id, is repair_verifier_failed.
    .PARAMETER ProofWire
        The X-Yuruna-Repair-Proof header value.
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
        if (-not (Get-YurunaHostRepairRemoteQualification @qualify).Qualified) { return (& $refuse 'repair_remote_unqualified') }
        if ($Tier -cne 'restart' -or -not (Test-HostRepairRung -Name $MaxRung -Remote)) { return (& $refuse 'repair_tier_not_remote') }
        $key = Read-YurunaHostRepairVerifierKey -HostId $HostId -PrivateRoot $PrivateRoot
        # Without its own canonical id the listener can judge no proof at all;
        # that is its failure, and blaming the installed key would send the
        # operator to reinstall a key that is fine.
        if ($key.Reason -ceq 'host_id_unavailable') { return (& $refuse 'repair_verifier_failed') }
        if ($key.State -ceq 'missing') { return (& $refuse 'repair_remote_unprovisioned') }
        if ($key.State -cne 'provisioned') { return (& $refuse 'repair_remote_key_invalid') }
        $now = if ($null -ne $NowUnixSeconds) { [long]$NowUnixSeconds } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $proof = Test-YurunaHostRepairProof -HostKey ([byte[]]$key.Key) -Wire $ProofWire -HostId $HostId -RequestId $RequestId `
            -Tier $Tier -MaxRung $MaxRung -NowUnixSeconds $now -SkewSeconds $script:HostRepairSkewSeconds `
            -MaxLifetimeSeconds $script:HostRepairMaxLifetimeSeconds
        return @{
            Authorized        = [bool]$proof.Valid
            Reason            = $proof.Reason
            HttpStatus        = if ($proof.Valid) { 200 } else { 403 }
            IssuedUnixSeconds = $proof.IssuedUnixSeconds
            ExpiryUnixSeconds = $proof.ExpiryUnixSeconds
        }
    } catch {
        Write-Verbose "Test-YurunaHostRepairAuthorization: $($_.Exception.Message)"
        return (& $refuse 'repair_verifier_failed')
    }
}

# --- REGION: Host update proof and the pool-control record
# A yup1 proof is an RSA PKCS#1 v1.5 SHA-256 signature by pool-control's
# update signing key, verified here with the public key in the pool-control
# record. The host keeps nothing private for it, so no platform is barred by
# where a secret could be kept; what the host relies on is that only its own
# account can replace the record, the protection of the private root. Shared
# with extension-sdk/hostupdate; its golden vectors pin both.
$script:HostUpdateProofVersion = 'yup1'
$script:HostUpdateVersionPattern = '\Ayup[0-9]+\z'
$script:HostUpdateMessageLabel = 'yuruna-host-update|v2|'
$script:HostUpdateMaxWireBytes = 1024
$script:HostUpdateMinKeyBits = 3072
$script:HostUpdatePublicKeyPrefix = 'yupk1'
$script:HostUpdateScopes = @('restart', 'full')
$script:HostUpdateDrainPattern = '\A[1-9][0-9]{1,4}\z'
$script:HostUpdateCommitPattern = '\A[0-9a-f]{7,40}\z'
$script:HostUpdateRecordName = 'pool-control.record'
$script:HostUpdateRecordSchema = 'yuruna.pool-control-record/v1'
$script:HostUpdateRecordKeys = @('schema', 'poolControl', 'updateKey')
$script:HostUpdateMaxUrlBytes = 256
$script:HostUpdateSigningKeyFileName = 'update-signing.key'
$script:HostUpdatePublicKeyFileName = 'update-signing.pub'

function ConvertFrom-HostUpdatePublicKeyLine {
    # "yupk1.<b64u SubjectPublicKeyInfo DER>" -> @{ Der; Tag }, or $null when
    # the line is anything else, the DER has trailing bytes, the key is not
    # RSA, or the modulus is below the floor.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dot = $Text.IndexOf('.')
    if ($dot -lt 0 -or -not [string]::Equals($Text.Substring(0, $dot), $script:HostUpdatePublicKeyPrefix, [StringComparison]::Ordinal)) { return $null }
    [byte[]]$der = ConvertFrom-HostRepairBase64Url -Text $Text.Substring($dot + 1)
    if ($null -eq $der) { return $null }
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $read = 0
        $rsa.ImportSubjectPublicKeyInfo($der, [ref]$read)
        if ($read -ne $der.Length -or $rsa.KeySize -lt $script:HostUpdateMinKeyBits) { return $null }
    } catch {
        return $null
    } finally { $rsa.Dispose() }
    $sha = [System.Security.Cryptography.SHA256]::HashData($der)
    return @{ Der = $der; Tag = (ConvertTo-HostRepairBase64Url -Bytes $sha) }
}

function Test-YurunaHostUpdateProof {
    <#
    .SYNOPSIS
        Judge a yup1 host update proof against this host's id and the
        effective values of the request it was asked to admit.
    .DESCRIPTION
        The order is fixed and shared with the Go verifier: missing, then
        shape (over 1024 bytes, wrong field count, bad field syntax; another
        yup<N> version is version_unsupported), then the signature over the
        fields as received, then host, request, policy (scope, drain bound,
        expected commit), lifetime, and the clock. Reads no clock and never
        throws.
    .PARAMETER PublicKeyText
        The yupk1 line of the pool-control record; empty makes every proof
        invalid.
    .PARAMETER Wire
        The X-Yuruna-Update-Proof header value.
    .PARAMETER HostId
        This host's own id.
    .PARAMETER RequestId
        The request id from the body.
    .PARAMETER Scope
        The effective scope.
    .PARAMETER DrainSeconds
        The effective drain bound.
    .PARAMETER ExpectCommit
        The expected commit, or empty when the request names none.
    .PARAMETER NowUnixSeconds
        The current instant, unix seconds.
    .PARAMETER SkewSeconds
        Two-sided clock tolerance.
    .PARAMETER MaxLifetimeSeconds
        Longest accepted issue-to-expiry span.
    .OUTPUTS
        [pscustomobject] Valid, Reason (ok or an update_proof_* code),
        IssuedUnixSeconds, ExpiryUnixSeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PublicKeyText,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Wire,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Scope,
        [Parameter(Mandatory)][int]$DrainSeconds,
        [AllowNull()][AllowEmptyString()][string]$ExpectCommit = '',
        [Parameter(Mandatory)][long]$NowUnixSeconds,
        [Parameter(Mandatory)][int]$SkewSeconds,
        [int]$MaxLifetimeSeconds = 300
    )
    $verdict = {
        param([string]$Reason, [Nullable[long]]$Iat, [Nullable[long]]$Exp)
        [pscustomobject]@{ Valid = ($Reason -ceq 'ok'); Reason = $Reason; IssuedUnixSeconds = $Iat; ExpiryUnixSeconds = $Exp }
    }
    if ([string]::IsNullOrEmpty($Wire)) { return (& $verdict 'update_proof_missing' $null $null) }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Wire) -gt $script:HostUpdateMaxWireBytes) { return (& $verdict 'update_proof_malformed' $null $null) }
    $f = $Wire.Split('.')
    if ($f[0] -cmatch $script:HostUpdateVersionPattern -and $f[0] -cne $script:HostUpdateProofVersion) {
        return (& $verdict 'update_proof_version_unsupported' $null $null)
    }
    if ($f.Count -ne 9 -or $f[0] -cne $script:HostUpdateProofVersion) { return (& $verdict 'update_proof_malformed' $null $null) }
    $iat = ConvertFrom-HostRepairUnix -Text $f[6]
    $exp = ConvertFrom-HostRepairUnix -Text $f[7]
    [byte[]]$signature = ConvertFrom-HostRepairBase64Url -Text $f[8]
    $drain = 0
    $drainValid = $f[4] -cmatch $script:HostUpdateDrainPattern -and [int]::TryParse($f[4], [ref]$drain) -and $drain -ge 60 -and $drain -le 21600
    if ($f[1] -cnotmatch $script:HostRepairHostIdPattern -or
        -not (Test-YurunaHostOperationRequestId -RequestId $f[2]) -or
        $script:HostUpdateScopes -cnotcontains $f[3] -or -not $drainValid -or
        ($f[5] -cne '' -and $f[5] -cnotmatch $script:HostUpdateCommitPattern) -or
        $null -eq $iat -or $null -eq $exp -or $null -eq $signature -or $signature.Length -eq 0) {
        return (& $verdict 'update_proof_malformed' $null $null)
    }
    $key = if ($PublicKeyText) { ConvertFrom-HostUpdatePublicKeyLine -Text $PublicKeyText } else { $null }
    if ($null -eq $key) { return (& $verdict 'update_proof_invalid' $iat $exp) }
    $message = $script:HostUpdateMessageLabel + (@($f[1], $f[2], $f[3], $f[4], $f[5], $f[6], $f[7]) -join '|')
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $read = 0
        $rsa.ImportSubjectPublicKeyInfo([byte[]]$key.Der, [ref]$read)
        $signed = $rsa.VerifyData([System.Text.Encoding]::UTF8.GetBytes($message), $signature,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch {
        $signed = $false
    } finally { $rsa.Dispose() }
    if (-not $signed) { return (& $verdict 'update_proof_invalid' $iat $exp) }
    $commit = if ($ExpectCommit) { $ExpectCommit } else { '' }
    if ($f[1] -cne (ConvertTo-HostRepairCanonicalHostId -HostId $HostId)) { return (& $verdict 'update_proof_host_mismatch' $iat $exp) }
    if ($f[2] -cne $RequestId) { return (& $verdict 'update_proof_request_mismatch' $iat $exp) }
    if ($f[3] -cne $Scope -or $drain -ne $DrainSeconds -or $f[5] -cne $commit) { return (& $verdict 'update_proof_policy_mismatch' $iat $exp) }
    if ($exp -le $iat -or ($exp - $iat) -gt $MaxLifetimeSeconds) { return (& $verdict 'update_proof_lifetime_invalid' $iat $exp) }
    $now = [Math]::Max([long]0, $NowUnixSeconds)
    $skew = [long][Math]::Max(0, $SkewSeconds)
    if ($iat -gt $now -and ($iat - $now) -gt $skew) { return (& $verdict 'update_proof_not_yet_valid' $iat $exp) }
    if ($now -gt $exp -and ($now - $exp) -gt $skew) { return (& $verdict 'update_proof_expired' $iat $exp) }
    return (& $verdict 'ok' $iat $exp)
}

function ConvertTo-YurunaPoolControlUrl {
    <#
    .SYNOPSIS
        The canonical form of a pool-control base URL, or '' when the value
        cannot be one.
    .DESCRIPTION
        An absolute http or https URL of at most 256 bytes with a host, no
        user information, query or fragment, and no whitespace or control
        character; a trailing slash is removed. The Diagnostics page sends its
        operator there, so nothing a page could turn into another kind of
        link is accepted.
    .PARAMETER Url
        The value an operator supplied, or the one a record holds.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Url)
    if ([string]::IsNullOrEmpty($Url) -or [System.Text.Encoding]::UTF8.GetByteCount($Url) -gt $script:HostUpdateMaxUrlBytes) { return '' }
    if ($Url -cmatch '[\s\x00-\x1f\x7f]' -or $Url.Contains('#') -or $Url.Contains('?')) { return '' }
    $parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) { return '' }
    if (@('http', 'https') -cnotcontains $parsed.Scheme -or [string]::IsNullOrEmpty($parsed.Host) -or $parsed.UserInfo) { return '' }
    if (-not $Url.StartsWith($parsed.Scheme + '://', [StringComparison]::Ordinal)) { return '' }
    return $Url.TrimEnd('/')
}

function Get-YurunaPoolControlRecordPath {
    <#
    .SYNOPSIS
        Where this host's pool-control record lives, computed without any
        side effect.
    .PARAMETER PrivateRoot
        Override the private root.
    .OUTPUTS
        [string] the path, or '' when no home directory is known.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$PrivateRoot)
    if ([string]::IsNullOrWhiteSpace($PrivateRoot)) {
        if ([string]::IsNullOrWhiteSpace($HOME)) { return '' }
        $PrivateRoot = [IO.Path]::Combine($HOME, '.yuruna', 'host-repair')
    }
    return [IO.Path]::Combine($PrivateRoot, $script:HostUpdateRecordName)
}

function ConvertFrom-HostUpdateRecordText {
    # The record is one JSON object with exactly the schema, poolControl and
    # updateKey strings, each once. @{ PoolControl; PublicKey; Tag } or $null.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 2
    $document = $null
    try { $document = [System.Text.Json.JsonDocument]::Parse($Text, $options) } catch { return $null }
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
        $values = @{}
        foreach ($property in $root.EnumerateObject()) {
            if ($script:HostUpdateRecordKeys -cnotcontains $property.Name -or $values.ContainsKey($property.Name) -or
                $property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { return $null }
            $values[$property.Name] = $property.Value.GetString()
        }
        if ($values.Count -ne $script:HostUpdateRecordKeys.Count -or $values['schema'] -cne $script:HostUpdateRecordSchema) { return $null }
        $url = ConvertTo-YurunaPoolControlUrl -Url $values['poolControl']
        $key = ConvertFrom-HostUpdatePublicKeyLine -Text $values['updateKey']
        if (-not $url -or $url -cne $values['poolControl'] -or $null -eq $key) { return $null }
        return @{ PoolControl = $url; PublicKey = [string]$values['updateKey']; Tag = $key.Tag }
    } finally { $document.Dispose() }
}

function Read-YurunaPoolControlRecord {
    <#
    .SYNOPSIS
        Read this host's pool-control record: pool-control's base URL and
        the public key its host update proofs verify with.
    .DESCRIPTION
        Refuses a record or either of its two parent directories that is a
        symbolic link or reparse point, a record other users can access, an
        oversize or malformed record, a URL that is not an absolute http or
        https address, and a key that is not an RSA key of at least 3072
        bits. Never throws.
    .PARAMETER PrivateRoot
        Override the private root.
    .OUTPUTS
        [hashtable] State provisioned|missing|invalid; Reason ok|absent|
        record_malformed|record_permissions_open|record_reparse_point|
        record_unreadable; PoolControl; PublicKey; KeyTag.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$PrivateRoot)
    $result = { param([string]$State, [string]$Reason) @{ State = $State; Reason = $Reason; PoolControl = ''; PublicKey = ''; KeyTag = '' } }
    $path = Get-YurunaPoolControlRecordPath -PrivateRoot $PrivateRoot
    if (-not $path) { return (& $result 'invalid' 'record_unreadable') }
    try {
        $root = [System.IO.Path]::GetDirectoryName($path)
        foreach ($dir in @($root, [System.IO.Path]::GetDirectoryName($root))) {
            if ($dir -and [System.IO.DirectoryInfo]::new($dir).LinkTarget) { return (& $result 'invalid' 'record_reparse_point') }
        }
        $read = Read-HostRepairSecretText -Path $path
    } catch {
        Write-Verbose "Read-YurunaPoolControlRecord: $($_.Exception.Message)"
        return (& $result 'invalid' 'record_unreadable')
    }
    switch ($read.Status) {
        'absent' { return (& $result 'missing' 'absent') }
        'reparse-point' { return (& $result 'invalid' 'record_reparse_point') }
        'permissions-open' { return (& $result 'invalid' 'record_permissions_open') }
        'unreadable' { return (& $result 'invalid' 'record_unreadable') }
        'ok' { }
        default { return (& $result 'invalid' 'record_malformed') }
    }
    $parsed = ConvertFrom-HostUpdateRecordText -Text $read.Text
    if ($null -eq $parsed) { return (& $result 'invalid' 'record_malformed') }
    return @{ State = 'provisioned'; Reason = 'ok'; PoolControl = $parsed.PoolControl; PublicKey = $parsed.PublicKey; KeyTag = $parsed.Tag }
}

function Get-YurunaHostUpdateRemoteState {
    <#
    .SYNOPSIS
        The remote host update summary a host advertises: provisioned,
        missing or invalid, with pool-control's base URL when provisioned.
        Carries no key material.
    .PARAMETER PrivateRoot
        Override the private root.
    .OUTPUTS
        [hashtable] Remote provisioned|missing|invalid; Reason; PoolControl
        ('' unless provisioned); KeyTag ('' unless provisioned).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$PrivateRoot)
    $record = Read-YurunaPoolControlRecord -PrivateRoot $PrivateRoot
    return @{ Remote = [string]$record.State; Reason = [string]$record.Reason; PoolControl = [string]$record.PoolControl; KeyTag = [string]$record.KeyTag }
}

function Test-YurunaHostUpdateAuthorization {
    <#
    .SYNOPSIS
        The listener's update-proof layer for a caller that is not this
        host itself: may this host update be admitted?
    .DESCRIPTION
        In order: a pool-control record must be installed and valid
        (update_remote_unprovisioned, update_remote_invalid); this host must
        know its own id (update_verifier_failed); then the verdict of
        Test-YurunaHostUpdateProof with a 60-second skew and a 300-second
        maximum lifetime. Reads the clock once, only when NowUnixSeconds is
        omitted. Never throws: any exception is update_verifier_failed.
    .PARAMETER ProofWire
        The X-Yuruna-Update-Proof header value.
    .PARAMETER HostId
        This host's own id.
    .PARAMETER RequestId
        The body's request id.
    .PARAMETER Scope
        The effective scope.
    .PARAMETER DrainSeconds
        The effective drain bound.
    .PARAMETER ExpectCommit
        The expected commit, or empty.
    .PARAMETER NowUnixSeconds
        The instant to judge at; omitted reads the clock.
    .PARAMETER PrivateRoot
        Override the private root.
    .OUTPUTS
        [hashtable] Authorized [bool]; Reason; HttpStatus 200|403.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyString()][string]$ProofWire,
        [AllowEmptyString()][string]$HostId = '',
        [AllowEmptyString()][string]$RequestId = '',
        [AllowEmptyString()][string]$Scope = '',
        [int]$DrainSeconds = 0,
        [AllowNull()][AllowEmptyString()][string]$ExpectCommit = '',
        [Nullable[long]]$NowUnixSeconds,
        [string]$PrivateRoot
    )
    $refuse = { param([string]$Reason) @{ Authorized = $false; Reason = $Reason; HttpStatus = 403 } }
    try {
        $record = Read-YurunaPoolControlRecord -PrivateRoot $PrivateRoot
        if ($record.State -ceq 'missing') { return (& $refuse 'update_remote_unprovisioned') }
        if ($record.State -cne 'provisioned') { return (& $refuse 'update_remote_invalid') }
        if (-not (ConvertTo-HostRepairCanonicalHostId -HostId $HostId)) { return (& $refuse 'update_verifier_failed') }
        $now = if ($null -ne $NowUnixSeconds) { [long]$NowUnixSeconds } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $proof = Test-YurunaHostUpdateProof -PublicKeyText ([string]$record.PublicKey) -Wire $ProofWire -HostId $HostId -RequestId $RequestId `
            -Scope $Scope -DrainSeconds $DrainSeconds -ExpectCommit $ExpectCommit -NowUnixSeconds $now `
            -SkewSeconds $script:HostRepairSkewSeconds -MaxLifetimeSeconds $script:HostRepairMaxLifetimeSeconds
        return @{ Authorized = [bool]$proof.Valid; Reason = [string]$proof.Reason; HttpStatus = $(if ($proof.Valid) { 200 } else { 403 }) }
    } catch {
        Write-Verbose "Test-YurunaHostUpdateAuthorization: $($_.Exception.Message)"
        return (& $refuse 'update_verifier_failed')
    }
}

# --- REGION: Provisioning
function Write-HostRepairSecretFile {
    # See https://yuruna.link/4213a0b3-008b
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
                if (-not (Test-HostRepairPrivateFileMode -Path $temps[$i])) { throw [System.IO.IOException]::new('mode') }
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
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_authority_incomplete' -Arguments @{
                    path = ($Path[0..($moved - 1)] -join ', '); pendingPath = "$current"; detail = "$detail" })
        }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_write_failed' -Arguments @{ path = "$current"; detail = "$detail" })
    }
}

function New-HostRepairRandomSecret {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers cast with [byte[]] and never capture with @().')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns random bytes in memory; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()
    $b = [byte[]]::new($script:HostRepairSecretBytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}

function Initialize-HostRepairSecretDirectory {
    # Creates the directory owner-only when absent and refuses one that is a
    # link: a secret directory that is an alias could put the secret anywhere.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Directory)
    $info = [System.IO.DirectoryInfo]::new($Directory)
    if ($info.LinkTarget) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = 'reparse-point' })
    }
    if (-not $info.Exists) {
        if ($IsWindows) { [void][System.IO.Directory]::CreateDirectory($Directory) }
        else { [void][System.IO.Directory]::CreateDirectory($Directory, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
}

function New-YurunaHostRepairAuthority {
    <#
    .SYNOPSIS
        Create the repair signing authority and the operator repair
        credential in a private directory.
    .DESCRIPTION
        Two independent 32-byte random secrets, written owner-only as
        authority.key (yrpa1) and operator.credential (yoc1). Refuses to
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
    $authorityPath = [System.IO.Path]::Combine($Directory, $script:HostRepairAuthorityFileName)
    $credentialPath = [System.IO.Path]::Combine($Directory, $script:HostRepairCredentialFileName)
    $record = { param([bool]$Created, [string]$Reason, [string]$FirstTag, [string]$SecondTag, [bool]$Rotated)
        [pscustomobject]@{ Created = $Created; Reason = $Reason; AuthorityPath = $authorityPath; CredentialPath = $credentialPath
            AuthorityTag = $FirstTag; CredentialTag = $SecondTag; Rotated = $Rotated }
    }
    $exists = [System.IO.File]::Exists($authorityPath) -or [System.IO.File]::Exists($credentialPath)
    if ($exists -and -not $Rotate) { return (& $record $false 'exists' '' '' $false) }
    if (-not $PSCmdlet.ShouldProcess($Directory, (Format-YurunaOperatorMessage -Key 'runner.host_repair_auth_action_create_authority'))) {
        return (& $record $false 'preview' '' '' $false)
    }
    Initialize-HostRepairSecretDirectory -Directory $Directory
    [byte[]]$authority = New-HostRepairRandomSecret
    [byte[]]$credential = New-HostRepairRandomSecret
    while ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($authority, $credential)) {
        [byte[]]$credential = New-HostRepairRandomSecret
    }
    Write-HostRepairSecretFile -Path @($authorityPath, $credentialPath) -Overwrite:$Rotate -Line @(
        ($script:HostRepairAuthorityPrefix + '.' + (ConvertTo-HostRepairBase64Url -Bytes $authority)),
        ($script:HostRepairCredentialPrefix + '.' + (ConvertTo-HostRepairBase64Url -Bytes $credential)))
    $credentialTag = ConvertTo-HostRepairBase64Url -Bytes ([byte[]](Get-HostRepairHmac -Key $credential -Message $script:HostRepairCredentialTagLabel))
    return (& $record $true 'ok' (Get-YurunaHostRepairAuthorityTag -Authority $authority) $credentialTag ([bool]$exists))
}

function Read-YurunaHostRepairAuthority {
    <#
    .SYNOPSIS
        Load the repair signing authority from a private directory.
    .DESCRIPTION
        Throws a localized message when the authority is missing, readable by
        other users, a link, not a regular file, oversize or unreadable (each
        named), or not one yrpa1 line of 32 bytes.
    .PARAMETER Directory
        The authority directory.
    .OUTPUTS
        [hashtable] Authority [byte[]]; AuthorityTag; Path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Directory)
    $path = [System.IO.Path]::Combine($Directory, $script:HostRepairAuthorityFileName)
    $read = Read-HostRepairSecretText -Path $path
    switch ($read.Status) {
        'ok' { }
        'absent' { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_authority_missing' -Arguments @{ path = "$Directory" }) }
        'permissions-open' { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_permissions_open' -Arguments @{ path = "$path" }) }
        default { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_unusable' -Arguments @{ path = "$path"; reason = "$($read.Status)" }) }
    }
    [byte[]]$authority = ConvertFrom-HostRepairSecretLine -Text $read.Text -Prefix $script:HostRepairAuthorityPrefix
    if ($null -eq $authority) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_malformed' -Arguments @{ path = "$path"; prefix = $script:HostRepairAuthorityPrefix })
    }
    return @{ Authority = $authority; AuthorityTag = (Get-YurunaHostRepairAuthorityTag -Authority $authority); Path = $path }
}

function ConvertTo-YurunaHostRepairHostKeyLine {
    <#
    .SYNOPSIS
        The one line that carries a host's repair verifier key to that host.
    .DESCRIPTION
        yrpk1.<hostId>.<unpadded base64url key>: the encoding
        Export-YurunaHostRepairHostKey writes and
        Install-YurunaHostRepairVerifierKey reads, so a caller that derives a
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
    $canonical = ConvertTo-HostRepairCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    if ($Key.Length -ne $script:HostRepairSecretBytes) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'hostKey' })
    }
    return $script:HostRepairHostKeyPrefix + '.' + $canonical + '.' + (ConvertTo-HostRepairBase64Url -Bytes $Key)
}

function Export-YurunaHostRepairHostKey {
    <#
    .SYNOPSIS
        Write one host's repair verifier key to a file for transport to that
        host.
    .DESCRIPTION
        Derives the key from the authority and writes one yrpk1 line
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
    $canonical = ConvertTo-HostRepairCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    $record = { param([bool]$Written, [string]$Reason, [string]$KeyTag)
        [pscustomobject]@{ Written = $Written; Reason = $Reason; HostId = $canonical; KeyTag = $KeyTag; Path = $OutputPath } }
    if ([System.IO.File]::Exists($OutputPath) -or [System.IO.Directory]::Exists($OutputPath) -or [System.IO.FileInfo]::new($OutputPath).LinkTarget) {
        return (& $record $false 'exists' '')
    }
    $authority = Read-YurunaHostRepairAuthority -Directory $AuthorityDirectory
    [byte[]]$key = Get-YurunaHostRepairHostKey -AuthorityKey ([byte[]]$authority.Authority) -HostId $canonical
    $tag = Get-YurunaHostRepairKeyTag -Key $key
    if (-not $PSCmdlet.ShouldProcess($OutputPath, (Format-YurunaOperatorMessage -Key 'runner.host_repair_auth_action_export_host_key' -Arguments @{ hostId = $canonical }))) {
        return (& $record $false 'preview' $tag)
    }
    Write-HostRepairSecretFile -Path $OutputPath -Line (ConvertTo-YurunaHostRepairHostKeyLine -HostId $canonical -Key $key)
    return (& $record $true 'ok' $tag)
}

function Install-YurunaHostRepairVerifierKey {
    <#
    .SYNOPSIS
        Install a transported repair verifier key on this host.
    .DESCRIPTION
        Validates the yrpk1 line and that it was derived for this host, then
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
    $canonical = ConvertTo-HostRepairCanonicalHostId -HostId $HostId
    if (-not $canonical) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_invalid_claim' -Arguments @{ field = 'hostId' }) }
    $text = $KeyText
    if ($text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 2) }
    elseif ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    $parsed = ConvertFrom-HostRepairHostKeyLine -Text $text
    if ($null -eq $parsed) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_key_malformed' -Arguments @{ path = "$SourcePath"; prefix = $script:HostRepairHostKeyPrefix })
    }
    if ($parsed.HostId -cne $canonical) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_host_id_mismatch' -Arguments @{ keyHostId = $parsed.HostId; hostId = $canonical })
    }
    if ([System.IO.DirectoryInfo]::new($PrivateRoot).LinkTarget) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = 'reparse-point' })
    }
    $path = Get-YurunaHostRepairVerifierKeyPath -PrivateRoot $PrivateRoot
    [byte[]]$key = $parsed.Key
    $tag = Get-YurunaHostRepairKeyTag -Key $key
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_repair_auth_action_install_host_key' -Arguments @{ hostId = $canonical }))) {
        return [pscustomobject]@{ Installed = $false; Reason = 'preview'; HostId = $canonical; KeyTag = $tag; Path = $path }
    }
    # Only the real write needs the root to exist: a preview runs before the
    # caller has created and secured it.
    $rootInfo = [System.IO.DirectoryInfo]::new($PrivateRoot)
    if ($rootInfo.LinkTarget -or -not $rootInfo.Exists) {
        $why = if ($rootInfo.LinkTarget) { 'reparse-point' } else { 'absent' }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = $why })
    }
    Write-HostRepairSecretFile -Path $path -Line $text -Overwrite
    return [pscustomobject]@{ Installed = $true; Reason = 'ok'; HostId = $canonical; KeyTag = $tag; Path = $path }
}

function Remove-YurunaHostRepairVerifierKey {
    <#
    .SYNOPSIS
        Delete this host's repair verifier key, after which the host refuses
        every non-loopback repair request.
    .PARAMETER PrivateRoot
        The private root.
    .OUTPUTS
        [pscustomobject] Removed; Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot)
    $path = Get-YurunaHostRepairVerifierKeyPath -PrivateRoot $PrivateRoot
    $info = [System.IO.FileInfo]::new($path)
    if (-not $info.Exists -and -not $info.LinkTarget) { return [pscustomobject]@{ Removed = $false; Path = $path } }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_repair_auth_action_remove_host_key'))) {
        return [pscustomobject]@{ Removed = $false; Path = $path }
    }
    [System.IO.File]::Delete($path)
    return [pscustomobject]@{ Removed = $true; Path = $path }
}

function ConvertTo-HostUpdatePublicKeyLine {
    # The yupk1 line of an RSA key's public half.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Security.Cryptography.RSA]$Rsa)
    return $script:HostUpdatePublicKeyPrefix + '.' + (ConvertTo-HostRepairBase64Url -Bytes $Rsa.ExportSubjectPublicKeyInfo())
}

function New-YurunaHostUpdateSigningKey {
    <#
    .SYNOPSIS
        Create pool-control's host update signing key in a private
        directory.
    .DESCRIPTION
        A new RSA key of 3072 bits, written owner-only as one PKCS#8 PEM
        block in update-signing.key. Refuses to replace an existing key
        unless Rotate is given; rotating makes every installed pool-control
        record refuse the new proofs until it is installed again with the
        new public key. The returned record carries the public key line and
        its tag, never the private key.
    .PARAMETER Directory
        Where to write; created owner-only when absent.
    .PARAMETER Rotate
        Replace an existing key.
    .OUTPUTS
        [pscustomobject] Created; Reason ok|exists|preview; KeyPath;
        PublicKey; KeyTag; Rotated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Directory,
        [switch]$Rotate
    )
    $keyPath = [System.IO.Path]::Combine($Directory, $script:HostUpdateSigningKeyFileName)
    $record = { param([bool]$Created, [string]$Reason, [string]$PublicKey, [string]$Tag, [bool]$Rotated)
        [pscustomobject]@{ Created = $Created; Reason = $Reason; KeyPath = $keyPath; PublicKey = $PublicKey; KeyTag = $Tag; Rotated = $Rotated } }
    $exists = [System.IO.File]::Exists($keyPath) -or [bool][System.IO.FileInfo]::new($keyPath).LinkTarget
    if ($exists -and -not $Rotate) { return (& $record $false 'exists' '' '' $false) }
    if (-not $PSCmdlet.ShouldProcess($keyPath, (Format-YurunaOperatorMessage -Key 'runner.host_update_auth_action_create_signing_key'))) {
        return (& $record $false 'preview' '' '' $false)
    }
    Initialize-HostRepairSecretDirectory -Directory $Directory
    $rsa = [System.Security.Cryptography.RSA]::Create($script:HostUpdateMinKeyBits)
    try {
        $pem = $rsa.ExportPkcs8PrivateKeyPem()
        $line = ConvertTo-HostUpdatePublicKeyLine -Rsa $rsa
    } finally { $rsa.Dispose() }
    Write-HostRepairSecretFile -Path $keyPath -Line $pem -Overwrite:$Rotate
    $parsed = ConvertFrom-HostUpdatePublicKeyLine -Text $line
    return (& $record $true 'ok' $line ([string]$parsed.Tag) ([bool]$exists))
}

function Read-YurunaHostUpdateSigningKey {
    <#
    .SYNOPSIS
        The public half of the host update signing key in a private
        directory.
    .DESCRIPTION
        Throws a localized message when the key is missing, readable by
        other users, a link, oversize or unreadable, or not one PKCS#8 RSA
        key of at least 3072 bits. Returns only public values.
    .PARAMETER Directory
        The directory that holds update-signing.key.
    .OUTPUTS
        [hashtable] PublicKey (the yupk1 line); KeyTag; Path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Directory)
    $path = [System.IO.Path]::Combine($Directory, $script:HostUpdateSigningKeyFileName)
    $read = Read-HostRepairSecretText -Path $path
    if ($read.Status -cne 'ok') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_update_auth_signing_key_unusable' -Arguments @{ path = "$path"; reason = "$($read.Status)" })
    }
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        try { $rsa.ImportFromPem($read.Text) } catch {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_update_auth_signing_key_unusable' -Arguments @{ path = "$path"; reason = 'malformed' })
        }
        if ($rsa.KeySize -lt $script:HostUpdateMinKeyBits) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_update_auth_signing_key_unusable' -Arguments @{ path = "$path"; reason = 'too-small' })
        }
        $line = ConvertTo-HostUpdatePublicKeyLine -Rsa $rsa
    } finally { $rsa.Dispose() }
    $parsed = ConvertFrom-HostUpdatePublicKeyLine -Text $line
    return @{ PublicKey = $line; KeyTag = [string]$parsed.Tag; Path = $path }
}

function Get-YurunaPoolControlRecordChange {
    <#
    .SYNOPSIS
        The values a new pool-control record would replace, so an operator
        reads each previous value before the record is written.
    .DESCRIPTION
        Compares the canonical new values with the installed record: one row
        per value that differs. An installed record that cannot be read is
        one row named record, with its reason code as the previous value. No
        record, a record with the same values, or a new value the install
        refuses gives no row, because nothing is replaced then.
    .PARAMETER PublicKey
        The new yupk1 line.
    .PARAMETER PoolControlUrl
        The new base URL.
    .PARAMETER PrivateRoot
        The private root.
    .OUTPUTS
        [object[]] of [pscustomobject] Key; Previous; Current.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PublicKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PoolControlUrl,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot
    )
    $url = ConvertTo-YurunaPoolControlUrl -Url $PoolControlUrl
    $line = $PublicKey.Trim()
    if (-not $url -or $null -eq (ConvertFrom-HostUpdatePublicKeyLine -Text $line)) { return @() }
    $installed = Read-YurunaPoolControlRecord -PrivateRoot $PrivateRoot
    if ($installed.State -ceq 'missing') { return @() }
    if ($installed.State -cne 'provisioned') { return @([pscustomobject]@{ Key = 'record'; Previous = [string]$installed.Reason; Current = 'replaced' }) }
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($url -cne $installed.PoolControl) { $rows.Add([pscustomobject]@{ Key = 'poolControl'; Previous = [string]$installed.PoolControl; Current = $url }) }
    if ($line -cne $installed.PublicKey) { $rows.Add([pscustomobject]@{ Key = 'updateKey'; Previous = [string]$installed.PublicKey; Current = $line }) }
    return @($rows)
}

function Install-YurunaPoolControlRecord {
    <#
    .SYNOPSIS
        Install this host's pool-control record: the base URL its
        Diagnostics page sends an operator to, and the public key host update proofs
        verify with.
    .DESCRIPTION
        Validates both values, then writes the record owner-only into the
        private root, replacing any previous record. Throws a localized
        message on a URL or key that cannot be used, or a private root that
        is a link or, for a real write, missing.
    .PARAMETER PublicKey
        The yupk1 line pool-control's signing key prints.
    .PARAMETER PoolControlUrl
        Pool-control's base URL.
    .PARAMETER PrivateRoot
        The resolved private root.
    .OUTPUTS
        [pscustomobject] Installed; Reason ok|preview; PoolControl; KeyTag;
        Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PublicKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PoolControlUrl,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot
    )
    $url = ConvertTo-YurunaPoolControlUrl -Url $PoolControlUrl
    if (-not $url) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_update_auth_url_invalid' -Arguments @{ url = "$PoolControlUrl" }) }
    $line = $PublicKey.Trim()
    $key = ConvertFrom-HostUpdatePublicKeyLine -Text $line
    if ($null -eq $key) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_update_auth_public_key_invalid') }
    if ([System.IO.DirectoryInfo]::new($PrivateRoot).LinkTarget) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = 'reparse-point' })
    }
    $path = Get-YurunaPoolControlRecordPath -PrivateRoot $PrivateRoot
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_update_auth_action_install_record' -Arguments @{ poolControl = $url }))) {
        return [pscustomobject]@{ Installed = $false; Reason = 'preview'; PoolControl = $url; KeyTag = [string]$key.Tag; Path = $path }
    }
    $rootInfo = [System.IO.DirectoryInfo]::new($PrivateRoot)
    if ($rootInfo.LinkTarget -or -not $rootInfo.Exists) {
        $why = if ($rootInfo.LinkTarget) { 'reparse-point' } else { 'absent' }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_repair_auth_private_root_unavailable' -Arguments @{ reason = $why })
    }
    $text = [ordered]@{ schema = $script:HostUpdateRecordSchema; poolControl = $url; updateKey = $line } | ConvertTo-Json -Compress
    Write-HostRepairSecretFile -Path $path -Line $text -Overwrite
    return [pscustomobject]@{ Installed = $true; Reason = 'ok'; PoolControl = $url; KeyTag = [string]$key.Tag; Path = $path }
}

function Remove-YurunaPoolControlRecord {
    <#
    .SYNOPSIS
        Delete this host's pool-control record, after which the host refuses
        every host update from another machine.
    .PARAMETER PrivateRoot
        The private root.
    .OUTPUTS
        [pscustomobject] Removed; Path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PrivateRoot)
    $path = Get-YurunaPoolControlRecordPath -PrivateRoot $PrivateRoot
    $info = [System.IO.FileInfo]::new($path)
    if (-not $info.Exists -and -not $info.LinkTarget) { return [pscustomobject]@{ Removed = $false; Path = $path } }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_update_auth_action_remove_record'))) {
        return [pscustomobject]@{ Removed = $false; Path = $path }
    }
    [System.IO.File]::Delete($path)
    return [pscustomobject]@{ Removed = $true; Path = $path }
}

Export-ModuleMember -Function `
    Test-YurunaHostOperationRequestId, Get-YurunaHostRepairHostKey, Get-YurunaHostRepairKeyTag, Get-YurunaHostRepairAuthorityTag, `
    New-YurunaHostRepairProof, Test-YurunaHostRepairProof, Get-YurunaHostRepairVerifierKeyPath, Read-YurunaHostRepairVerifierKey, `
    Get-YurunaHostRepairRemoteQualification, Get-YurunaHostRepairRemoteState, Test-YurunaHostRepairAuthorization, `
    New-YurunaHostRepairAuthority, Read-YurunaHostRepairAuthority, ConvertTo-YurunaHostRepairHostKeyLine, Export-YurunaHostRepairHostKey, `
    Install-YurunaHostRepairVerifierKey, Remove-YurunaHostRepairVerifierKey, `
    Test-YurunaHostUpdateProof, ConvertTo-YurunaPoolControlUrl, Get-YurunaPoolControlRecordPath, Read-YurunaPoolControlRecord, `
    Get-YurunaHostUpdateRemoteState, Test-YurunaHostUpdateAuthorization, New-YurunaHostUpdateSigningKey, Read-YurunaHostUpdateSigningKey, `
    Get-YurunaPoolControlRecordChange, Install-YurunaPoolControlRecord, Remove-YurunaPoolControlRecord
