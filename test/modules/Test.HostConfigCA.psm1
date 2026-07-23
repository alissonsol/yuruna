<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d7c1b4-6e8a-4f3c-9d20-5a7b1c2e3f40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host config ca mtls certificate
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

# Per-host Config CA backing the Host Config Service (mTLS). Mints and persists a
# host-rooted EC P-256 certificate authority under
# $env:YURUNA_RUNTIME_DIR/host-config-ca/ (gitignored, like vault.yml and
# host.uuid). From that CA come two leaf kinds:
#   * one SERVER leaf for the Host Config Service (Start-HostConfigService.ps1);
#   * one CLIENT leaf per VM, issued at New-VM time and baked into the VM's
#     cloud-init seed.
# A VM presenting a client leaf signed by THIS host's CA proves it was created by
# THIS host -- the cryptographic realization of "serve config to ONLY the VMs
# running under that same host" (docs/design/host-config-service-and-extension-hosts.md).
#
# Crypto is operator-approved security posture (do not change without sign-off,
# see feedback_no_unauthorized_security_changes): EC P-256, SHA-256, CA 10y,
# leaves 2y. The server leaf's SAN is a STABLE dns name (ConfigServerSan); guests
# reach the host's current IP via `curl --connect-to <san>:<port>:<hostIp>:<port>`
# so a host DHCP change never invalidates the leaf (it only invalidates the baked
# host IP, the same staleness the status-server fetch already has).

$script:ConfigCaDirName  = 'host-config-ca'
$script:ConfigServerSan  = 'yuruna-host-config'
$script:ConfigCaSubject  = 'CN=Yuruna Host Config CA'
$script:ConfigCaYears    = 10
$script:ConfigLeafYears  = 2
# EKU OIDs.
$script:OidServerAuth    = '1.3.6.1.5.5.7.3.1'
$script:OidClientAuth    = '1.3.6.1.5.5.7.3.2'

# X509 key-storage flags for loading the CA signing material (ca.pfx). On Windows
# and Linux, EphemeralKeySet keeps the private key purely in memory, so the
# frequent per-VM signing leaves no residue in the host key store. macOS does NOT
# support EphemeralKeySet -- the loader throws "This platform does not support
# loading with EphemeralKeySet" -- so it loads with Exportable instead, the same
# flag the server leaf already uses. The CA key is already at rest in ca.pfx
# (chmod 600), so the macOS path adds no new at-rest exposure; the EC P-256 /
# SHA-256 crypto posture is unchanged on every platform.
$script:ConfigCaPfxLoadFlags = if ($IsMacOS) {
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
} else {
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
}

<#
.SYNOPSIS
    Resolve (and create) the per-host Config CA directory under the runtime tree.
.DESCRIPTION
    Prefers $env:YURUNA_RUNTIME_DIR (set by every entry point via
    Initialize-YurunaRuntimeDir), falling back to that function when available so
    a fresh import still resolves. Throws when no runtime directory can be found.
.OUTPUTS
    System.String -- the CA directory path.
#>
function Get-YurunaConfigCaDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir) -and (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue)) {
        $runtimeDir = Initialize-YurunaRuntimeDir
    }
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) {
        throw "Get-YurunaConfigCaDir: cannot resolve the runtime directory (set `$env:YURUNA_RUNTIME_DIR or import Test.YurunaDir)."
    }
    $dir = Join-Path $runtimeDir $script:ConfigCaDirName
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

<#
.SYNOPSIS
    Wrap DER bytes in a PEM block (LF newlines) for curl/OpenSSL on the guest.
.DESCRIPTION
    Hand-rolled rather than [PemEncoding]::Write / ExportCertificatePem so the
    module works on .NET 6 (PowerShell 7.2) as well as newer runtimes.
.OUTPUTS
    System.String -- the PEM-encoded block.
#>
function ConvertTo-YurunaPem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure encoder: bytes in, PEM string out; mutates nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $b64 = [Convert]::ToBase64String($Bytes)
    $sb  = [System.Text.StringBuilder]::new()
    [void]$sb.Append("-----BEGIN $Label-----`n")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $len = [Math]::Min(64, $b64.Length - $i)
        [void]$sb.Append($b64.Substring($i, $len))
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("-----END $Label-----`n")
    return $sb.ToString()
}

# A 16-byte positive serial (high bit cleared so it is never read as negative).
function New-YurunaConfigSerial {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor (random serial bytes); mutates nothing.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()
    $serial = [Guid]::NewGuid().ToByteArray()
    $serial[0] = $serial[0] -band 0x7F
    return $serial
}

<#
.SYNOPSIS
    Ensure the per-host Config CA exists; mint it on first call. Returns the CA
    as an X509Certificate2 WITH its private key (usable to sign leaves).
.DESCRIPTION
    Persists ca.pfx (PKCS#12, the signing material) and ca.crt (PEM, the public
    cert baked into VM trust stores) under the runtime tree. Idempotent: an
    existing CA is loaded and returned untouched unless -Force re-mints it.
    Loaded with $script:ConfigCaPfxLoadFlags (EphemeralKeySet on Windows/Linux so
    per-VM signing leaves no host key-store residue; Exportable on macOS, which
    does not support EphemeralKeySet).
.OUTPUTS
    System.Security.Cryptography.X509Certificates.X509Certificate2
#>
function Initialize-YurunaConfigCA {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param([switch]$Force)
    $dir      = Get-YurunaConfigCaDir
    $caPfx    = Join-Path $dir 'ca.pfx'
    $caCrt    = Join-Path $dir 'ca.crt'
    $utf8     = [System.Text.UTF8Encoding]::new($false)
    if (-not $Force -and (Test-Path -LiteralPath $caPfx)) {
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [System.IO.File]::ReadAllBytes($caPfx), '', $script:ConfigCaPfxLoadFlags)
    }
    if (-not $PSCmdlet.ShouldProcess($caPfx, 'Mint per-host Config CA')) {
        # Nothing to return without minting; surface the absence to the caller.
        if (Test-Path -LiteralPath $caPfx) {
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                [System.IO.File]::ReadAllBytes($caPfx), '', $script:ConfigCaPfxLoadFlags)
        }
        throw "Initialize-YurunaConfigCA: -WhatIf declined minting and no CA exists yet."
    }
    $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
    try {
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $script:ConfigCaSubject, $ec, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $req.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $true, 0, $true))
        $req.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
        $req.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($req.PublicKey, $false))
        $notBefore = [DateTimeOffset]::UtcNow.AddDays(-1)
        $notAfter  = [DateTimeOffset]::UtcNow.AddYears($script:ConfigCaYears)
        $caCert    = $req.CreateSelfSigned($notBefore, $notAfter)
        $pfxBytes  = $caCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
        [System.IO.File]::WriteAllBytes($caPfx, $pfxBytes)
        [System.IO.File]::WriteAllText($caCrt, (ConvertTo-YurunaPem -Label 'CERTIFICATE' -Bytes $caCert.RawData), $utf8)
        # Lock the signing material to the owner where chmod exists.
        if (-not $IsWindows) { & chmod 600 $caPfx 2>$null }
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfxBytes, '', $script:ConfigCaPfxLoadFlags)
    } finally {
        $ec.Dispose()
    }
}

<#
.SYNOPSIS
    Returns the Config CA certificate as a PEM string (the value baked into a
    VM's trust store and used by the guest as `curl --cacert`).
#>
function Get-YurunaConfigCaCertificatePem {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir   = Get-YurunaConfigCaDir
    $caCrt = Join-Path $dir 'ca.crt'
    if (Test-Path -LiteralPath $caCrt) {
        return [System.IO.File]::ReadAllText($caCrt)
    }
    $ca = Initialize-YurunaConfigCA
    return (ConvertTo-YurunaPem -Label 'CERTIFICATE' -Bytes $ca.RawData)
}

# Build an EC P-256 leaf signed by the Config CA. Internal: callers use the
# New-YurunaConfig*Certificate wrappers, which set the right EKU + SAN.
function New-YurunaConfigLeaf {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory certificate; persistence and ShouldProcess belong to the caller.')]
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$EkuOid,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]$San,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Ca
    )
    $leafEc = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $Subject, $leafEc, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $req.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false))
    # EC leaves authenticate via ECDSA signatures (ECDHE_ECDSA); DigitalSignature
    # is the only key usage they need -- KeyEncipherment is RSA-specific.
    $req.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
    $oids = [System.Security.Cryptography.OidCollection]::new()
    [void]$oids.Add([System.Security.Cryptography.Oid]::new($EkuOid))
    $req.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $false))
    $req.CertificateExtensions.Add($San.Build())
    $notBefore = [DateTimeOffset]::UtcNow.AddDays(-1)
    $notAfter  = [DateTimeOffset]::UtcNow.AddYears($script:ConfigLeafYears)
    $serial    = New-YurunaConfigSerial
    $signed    = $req.Create($Ca, $notBefore, $notAfter, $serial)
    # Bind the freshly generated private key onto the CA-signed public cert.
    # CopyWithPrivateKey is an EXTENSION method (ECDsaCertificateExtensions), so it
    # must be invoked statically in PowerShell -- $signed.CopyWithPrivateKey(...) is
    # not visible. The returned cert owns the key, so $leafEc is intentionally left
    # for GC rather than disposed (disposing it can invalidate the cert's key).
    return [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::CopyWithPrivateKey($signed, $leafEc)
}

<#
.SYNOPSIS
    Ensure the Host Config Service server leaf exists; mint it (signed by the
    Config CA) on first call. Returns an X509Certificate2 WITH its private key
    for SslStream.AuthenticateAsServer.
.DESCRIPTION
    SAN = the stable dns name (ConfigServerSan) plus loopback IPs (for local
    readiness probes). Persisted as server.pfx so a service restart reuses it.
    Loaded with Exportable (default key set) -- schannel on Windows wants the
    server key in a real key set, not EphemeralKeySet.
.OUTPUTS
    System.Security.Cryptography.X509Certificates.X509Certificate2
#>
function New-YurunaConfigServerCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param([switch]$Force)
    $dir       = Get-YurunaConfigCaDir
    $serverPfx = Join-Path $dir 'server.pfx'
    $flags     = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    if (-not $Force -and (Test-Path -LiteralPath $serverPfx)) {
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [System.IO.File]::ReadAllBytes($serverPfx), '', $flags)
    }
    if (-not $PSCmdlet.ShouldProcess($serverPfx, 'Mint Host Config Service server leaf')) {
        if (Test-Path -LiteralPath $serverPfx) {
            return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                [System.IO.File]::ReadAllBytes($serverPfx), '', $flags)
        }
        throw "New-YurunaConfigServerCertificate: -WhatIf declined minting and no server leaf exists yet."
    }
    $ca  = Initialize-YurunaConfigCA
    $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san.AddDnsName($script:ConfigServerSan)
    $san.AddIpAddress([System.Net.IPAddress]::Loopback)
    $san.AddIpAddress([System.Net.IPAddress]::IPv6Loopback)
    $leaf      = New-YurunaConfigLeaf -Subject "CN=$($script:ConfigServerSan)" -EkuOid $script:OidServerAuth -San $san -Ca $ca
    $pfxBytes  = $leaf.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
    [System.IO.File]::WriteAllBytes($serverPfx, $pfxBytes)
    if (-not $IsWindows) { & chmod 600 $serverPfx 2>$null }
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxBytes, '', $flags)
}

<#
.SYNOPSIS
    Mint a per-VM CLIENT leaf signed by the Config CA. Returns a hashtable with
    the PEM cert, PEM key, and the CA PEM -- the three values baked into a VM's
    cloud-init seed so the guest can present a client cert to the Host Config
    Service (and trust the server).
.DESCRIPTION
    Not persisted on the host (issued per VM, on demand): a rebuilt VM gets a
    fresh client leaf. The subject/SAN carry the VM name (and hostId when given)
    purely for human/audit legibility -- authorization is "chains to this host's
    CA", not the subject string.
.OUTPUTS
    [hashtable] @{ CertificatePem; PrivateKeyPem; CaCertificatePem }
#>
function New-YurunaConfigClientCertificate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Issues an in-memory client leaf and returns its PEM material; persists nothing on the host.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SubjectName,
        [Parameter()][string]$HostId = ''
    )
    $ca  = Initialize-YurunaConfigCA
    $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $san.AddDnsName($SubjectName)
    $cn   = if ($HostId) { "CN=$SubjectName,OU=$HostId" } else { "CN=$SubjectName" }
    $leaf = New-YurunaConfigLeaf -Subject $cn -EkuOid $script:OidClientAuth -San $san -Ca $ca
    # GetECDsaPrivateKey is also an extension method -> static invocation.
    $leafKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($leaf)
    try {
        $keyDer = $leafKey.ExportPkcs8PrivateKey()
    } finally {
        # The DER bytes are copied out above, so the live ECDsa handle is no longer
        # needed. Disposing it releases the backing CNG/OpenSSL key rather than
        # leaking one handle per issued VM leaf (this is the leaf's own key object,
        # distinct from the cert returned by New-YurunaConfigServerCertificate).
        if ($leafKey) { $leafKey.Dispose() }
    }
    return @{
        CertificatePem   = (ConvertTo-YurunaPem -Label 'CERTIFICATE' -Bytes $leaf.RawData)
        PrivateKeyPem    = (ConvertTo-YurunaPem -Label 'PRIVATE KEY' -Bytes $keyDer)
        CaCertificatePem = (Get-YurunaConfigCaCertificatePem)
    }
}

<#
.SYNOPSIS
    Build an X509Certificate2 for the Config CA from its PUBLIC cert only (no
    private key) -- used by the service to validate client certs against a custom
    trust root.
#>
function Get-YurunaConfigCaPublicCertificate {
    [CmdletBinding()]
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    param()
    $dir   = Get-YurunaConfigCaDir
    $caCrt = Join-Path $dir 'ca.crt'
    if (-not (Test-Path -LiteralPath $caCrt)) { [void](Initialize-YurunaConfigCA -Confirm:$false) }
    # Load from the DER bytes parsed out of the PEM, NOT the X509Certificate2 file
    # constructor: that constructor auto-detects the file format via the platform
    # crypto backend, which reads PEM on Windows but NOT on macOS -- there it throws,
    # which killed the detached -Serve process before it could listen (the launcher
    # never loads ca.crt as a cert, so the failure showed up only in the service).
    # DER bytes load identically on every platform. (CreateFromPem takes a
    # ReadOnlySpan<char> that PowerShell cannot reliably bind a [string] to across
    # versions -- see Test.HostConfigCA.Tests.ps1; the .Tests file uses the same
    # strip-headers -> base64 -> DER reconstruction.)
    $pem = [System.IO.File]::ReadAllText($caCrt)
    $b64 = (($pem -split "`r?`n") | Where-Object { $_ -and ($_ -notmatch 'CERTIFICATE') }) -join ''
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($b64))
}

<#
.SYNOPSIS
    Validate a presented client certificate: returns $true only when it chains to
    THIS host's Config CA (custom-root trust, no revocation). The Host Config
    Service's TLS client-cert callback delegates here.
#>
function Test-YurunaConfigClientCertificate {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Certificate,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$CaCertificate
    )
    if ($null -eq $Certificate) { return $false }
    $client = $Certificate -as [System.Security.Cryptography.X509Certificates.X509Certificate2]
    if (-not $client) {
        try { $client = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Certificate) } catch { return $false }
    }
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.TrustMode      = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$chain.ChainPolicy.CustomTrustStore.Add($CaCertificate)
        $built = [bool]$chain.Build($client)
        if (-not $built) {
            # Build() surfaces WHY it rejected (expired leaf, partial chain, untrusted
            # root) only in ChainStatus; without echoing it a legitimate rejection and a
            # buggy CA look identical in the log. Diagnostics only -- the verdict below is
            # exactly $chain.Build()'s bool; nothing here changes what is accepted.
            $why = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join '; '
            if (-not [string]::IsNullOrWhiteSpace($why)) {
                Write-Verbose "Test-YurunaConfigClientCertificate: client chain rejected -- $why"
            }
        }
        return $built
    } catch {
        Write-Verbose "Test-YurunaConfigClientCertificate: $($_.Exception.Message)"
        return $false
    } finally {
        $chain.Dispose()
    }
}

Export-ModuleMember -Function `
    Get-YurunaConfigCaDir, `
    Initialize-YurunaConfigCA, `
    Get-YurunaConfigCaCertificatePem, `
    Get-YurunaConfigCaPublicCertificate, `
    New-YurunaConfigServerCertificate, `
    New-YurunaConfigClientCertificate, `
    Test-YurunaConfigClientCertificate, `
    ConvertTo-YurunaPem
