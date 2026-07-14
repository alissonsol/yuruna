<#PSScriptInfo
.VERSION 2026.07.14
.GUID 4288bcbc-ede3-4dda-bb77-b9782c7615ad
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Common
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

# Neutral leaf: dependency-free helpers shared across the automation / host / test
# layers so a single definition cannot drift between hand-copied blocks. Each
# consumer imports it -Global -Force at its top (the same pattern the operation
# modules use for Yuruna.Result / Yuruna.VariableExpansion), so the helpers resolve
# at operation time and the module holds no per-run state of its own.

function New-YurunaTimestampedBackup {
    <#
    .SYNOPSIS
        Copy a source .yml into <WorkFolder>/<Prefix>.<yyyy-MM-dd-HH-mm-ss>.yml as a
        best-effort timestamped backup.
    .DESCRIPTION
        The one timestamped-backup step the component/resource/workload publishers
        share. The caller keeps ownership of the work-folder lifecycle
        (New-Item / Resolve-Path) because it reuses that folder for other artifacts;
        only the timestamp + copy + verbose line live here so the timestamp format
        cannot drift between publishers. Best-effort by contract: -ErrorAction
        SilentlyContinue on the copy, and nothing is emitted to the pipeline so a
        publisher's singular result-manifest return stays clean.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort backup copy of a config file (-ErrorAction SilentlyContinue by contract); ShouldProcess would not fit a publisher prelude step that never blocks on the copy result.')]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$Prefix
    )
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}', (Get-Date)))
    $backupFile = Join-Path -Path $WorkFolder -ChildPath "$Prefix.$dtTime.yml"
    Copy-Item "$SourceFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $SourceFile copied to: $backupFile"
}

function Get-HostProxyBackupPath {
<#
.SYNOPSIS
    Return the absolute path of the host-proxy backup JSON file, creating
    its parent state directory if it doesn't already exist.
.DESCRIPTION
    $HOME/.yuruna/host-proxy.backup.json is the source of truth for
    Clear-HostProxy's restore; its mere existence is also the "are we
    currently promoted?" flag. Same path on every host -- this lives in the
    cross-host Yuruna.Common leaf rather than per-host Yuruna.Host.psm1.
.OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $stateDir = Join-Path $HOME '.yuruna'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    return (Join-Path $stateDir 'host-proxy.backup.json')
}

function ConvertTo-ProxyHostPort {
<#
.SYNOPSIS
    Parse "http://host:port" into separate host / port fields.
.DESCRIPTION
    WinINet ProxyServer takes "host:port", macOS networksetup takes
    server + port as separate args -- callers consume different
    fragments of the URL.
.OUTPUTS
    [hashtable] @{ Host; Port; HostPort; Url }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -notmatch '^https?://([^:/]+):(\d+)/?$') {
        throw "ConvertTo-ProxyHostPort: '$Url' is not a valid http://host:port URL."
    }
    return @{
        Host     = $matches[1]
        Port     = [int]$matches[2]
        HostPort = "$($matches[1]):$($matches[2])"
        Url      = "http://$($matches[1]):$($matches[2])/"
    }
}

# Get-PortMapStatePath's no-`-RuntimeDir` branch calls Initialize-YurunaRuntimeDir
# (owned by test/modules/Test.YurunaDir.psm1). That is a soft, call-time
# dependency resolved from the caller's session, NOT imported here: this leaf
# stays dependency-free, and every host/status caller passes -RuntimeDir so the
# branch is never taken outside the test harness (which imports Test.YurunaDir).
function Get-PortMapStatePath {
<#
.SYNOPSIS
    Return the path of the port-map state JSON. Cross-host: same name
    in $env:YURUNA_RUNTIME_DIR / status/runtime on every platform.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RuntimeDir)
    if (-not $RuntimeDir) {
        $RuntimeDir = Initialize-YurunaRuntimeDir
    } elseif (-not (Test-Path $RuntimeDir)) {
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    }
    return (Join-Path $RuntimeDir 'caching-proxy-port-map.json')
}

function Test-IsAdministrator {
<#
.SYNOPSIS
    Returns $true on Windows when the current process is elevated; $false
    on every other host (admin is a Windows-specific concept).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CachingProxyPort {
<#
.SYNOPSIS
    Resolve the client-facing caching-proxy port for one of the supported
    schemes (http / https / ftp), honoring per-scheme env-var overrides
    with squid-style defaults.
.DESCRIPTION
    Reads `$env:YURUNA_CACHING_PROXY_<SCHEME>_PORT`. Empty / missing /
    non-integer values fall through to the squid defaults: 3128 for HTTP,
    3129 for HTTPS, 3128 for FTP. The FTP knob is reserved for callers
    extending the harness (squid handles FTP via HTTP CONNECT today, so
    out-of-the-box code uses 3128 -- same value as HTTP).

    Companion to YURUNA_CACHING_PROXY_IP: clients that need to point at
    a non-default external squid (different IP AND/OR different port)
    set both knobs together.
.OUTPUTS
    [int]
.EXAMPLE
    Get-CachingProxyPort                       # 3128 (or override)
    Get-CachingProxyPort -Scheme https         # 3129 (or override)
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateSet('http','https','ftp')]
        [string]$Scheme = 'http'
    )
    $envVar = "YURUNA_CACHING_PROXY_$($Scheme.ToUpperInvariant())_PORT"
    $val = [System.Environment]::GetEnvironmentVariable($envVar)
    if ($val) {
        $parsed = 0
        if ([int]::TryParse($val, [ref]$parsed) -and $parsed -gt 0 -and $parsed -lt 65536) {
            return $parsed
        }
        Write-Warning "${envVar}='$val' is not a valid TCP port; falling through to default."
    }
    switch ($Scheme) {
        'http'  { return 3128 }
        'https' { return 3129 }
        'ftp'   { return 3128 }
    }
}

function Test-Ipv4Address {
<#
.SYNOPSIS
    Strict IPv4 dotted-quad validator.
.DESCRIPTION
    Returns $true iff the input is a canonical decimal IPv4 address:
    exactly four dot-separated octets, each octet is digits-only with no
    leading zero (except the lone digit '0'), and each numeric value is
    in 0..255. Rejects "999.999.999.999", "01.2.3.4", "1.2.3", "1.2.3.4 ",
    null, empty, and shortened forms.

    Provided here because the loose regex '^\d+\.\d+\.\d+\.\d+$' accepts
    out-of-range octets and gives false confidence (downstream TCP
    connect fails, but only after we've already passed validation).
    [System.Net.IPAddress]::TryParse is not strict enough either -- it
    accepts shortened/hex/octal forms.
.OUTPUTS
    [bool]
.EXAMPLE
    Test-Ipv4Address '192.168.1.1'        # True
    Test-Ipv4Address '999.999.999.999'    # False
    Test-Ipv4Address '01.2.3.4'           # False (leading zero)
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
        $parts = $Address -split '\.'
        if ($parts.Count -ne 4) { return $false }
        foreach ($p in $parts) {
            if ($p -notmatch '^(?:0|[1-9]\d{0,2})$') { return $false }
            if ([int]$p -gt 255) { return $false }
        }
        return $true
    }
}

function Test-Ipv6Address {
<#
.SYNOPSIS
    Strict IPv6 validator.
.DESCRIPTION
    Returns $true iff the input parses as a canonical IPv6 address.
    Accepts the standard hex-colon forms ("::1", "fe80::1", full
    "2001:db8:0:0:0:0:0:1"), the IPv4-mapped form ("::ffff:192.0.2.1"),
    and a trailing zone-id ("fe80::1%en0", "fe80::1%3" -- RFC 4007/6874);
    the zone is host-local, stripped before parsing.

    Implementation uses [System.Net.IPAddress]::TryParse and then
    requires AddressFamily=InterNetworkV6 so an IPv4 input ("1.2.3.4")
    that TryParse happily accepts is rejected here. URL-bracket forms
    ("[::1]", "[::1]:8080") are rejected because brackets are URL
    syntax, not part of the address.
.OUTPUTS
    [bool]
.EXAMPLE
    Test-Ipv6Address '::1'                      # True
    Test-Ipv6Address 'fe80::1%en0'              # True
    Test-Ipv6Address 'gggg::1'                  # False
    Test-Ipv6Address '1.2.3.4'                  # False (v4, not v6)
    Test-Ipv6Address '[::1]'                    # False (URL brackets)
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
        # Reject URL-bracket forms ("[::1]", "[::1]:8080"). .NET 7+'s
        # IPAddress.TryParse silently accepts them, but brackets are URL
        # syntax, not part of the address itself.
        if ($Address -match '[\[\]]') { return $false }
        # RFC 4007 zone-id is not part of the address; strip before parse.
        $candidate = $Address
        $pct = $candidate.IndexOf('%')
        if ($pct -ge 0) { $candidate = $candidate.Substring(0, $pct) }
        # Reject any whitespace inside the address (TryParse may tolerate
        # leading/trailing whitespace in some runtimes).
        if ($candidate -match '\s') { return $false }
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$ip)) { return $false }
        return $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    }
}

function Format-IpUrlHost {
<#
.SYNOPSIS
    Returns the input wrapped in square brackets when it is a valid
    IPv6 address; otherwise returns it unchanged.
.DESCRIPTION
    Used when embedding an IP into a URL host component (RFC 3986 /
    6874). IPv6 needs to be bracketed so the URL's colon-prefixed
    port doesn't get glued onto the address; IPv4 addresses and DNS
    hostnames are passed through verbatim.
.OUTPUTS
    [string]
.EXAMPLE
    Format-IpUrlHost '192.168.1.1'        # 192.168.1.1
    Format-IpUrlHost '2001:db8::1'        # [2001:db8::1]
    Format-IpUrlHost 'host.local'         # host.local
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Address
    )
    process {
        if (Test-Ipv6Address $Address) { return "[$Address]" }
        return $Address
    }
}

function Test-IpAddress {
<#
.SYNOPSIS
    True if input is a valid IPv4 OR IPv6 address.
.DESCRIPTION
    Convenience wrapper for callsites that legitimately accept either
    family -- operator-set env vars, parameters, files written by the
    harness. Internally combines Test-Ipv4Address and Test-Ipv6Address;
    rejects the same edge cases each does (out-of-range octets, garbage
    hex, URL-bracket forms, shortened-IPv4 forms, etc).
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        return ((Test-Ipv4Address $Address) -or (Test-Ipv6Address $Address))
    }
}

function ConvertTo-Sha512CryptHash {
<#
.SYNOPSIS
    Returns the SHA-512 ($6$) crypt hash for a plaintext password.
    Cross-host helper for guest user-data / autoinstall password fields.
.DESCRIPTION
    Wraps `openssl passwd -6` with two non-negotiable guarantees:

    1. The plaintext is passed AFTER the `--` end-of-options marker.
       `New-RandomPassword` draws from an alphabet that includes `-`,
       so ~1/72 of generated passwords start with `-`. Without `--`,
       `openssl passwd -6 -4aWj*CRw` parses `-4aWj*CRw` as an unknown
       option flag, prints `passwd: Use -help for summary` to stderr,
       returns nothing on stdout, and exits non-zero. The cycle then
       writes a malformed (or empty) HASH_PLACEHOLDER into cloud-init
       user-data and the guest comes up with no working password.
       Any future password-handling consumer should pass plaintext
       AFTER `--` (or via stdin) for the same reason.

    2. The shape of the result is validated (`$6$...`) before return.
       Older openssl builds lack `-6`; we surface a clear error rather
       than substituting a bogus hash.

    Platform-specific binary probe (Git for Windows paths, Homebrew
    paths, PATH fallback on Linux) lives here, shared by the three
    parallel per-host New-VM.ps1 scripts so the path logic stays in one
    place instead of drifting across copies.

    The plaintext is briefly visible in the openssl process's argv
    while it runs (process listings). This is acceptable in the
    repo's threat model: vault.yml itself stores plaintext on disk
    (see test/extension/authentication/default.psm1 -- Set-Password
    docstring), and the harness runs in a private dev context.
    `-stdin` is the stricter alternative but introduces a CRLF/encoding
    surface on Windows pwsh that the `--` form sidesteps.
.PARAMETER Plaintext
    The plaintext password to hash. Must be non-empty.
.PARAMETER OpenSslPath
    Optional explicit path to an openssl binary, bypassing the probe.
    Mostly useful for tests.
.OUTPUTS
    [string] -- the `$6$<salt>$<hash>` crypt string.
#>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Plaintext IS the input; this function exists to convert it to a hash. Vault context is plaintext-on-disk by design.')]
    param(
        [Parameter(Mandatory)][string]$Plaintext,
        [string]$OpenSslPath
    )
    if (-not $Plaintext) { throw 'ConvertTo-Sha512CryptHash: Plaintext is empty.' }

    $candidates = @()
    if ($OpenSslPath) {
        $candidates += $OpenSslPath
    } else {
        if ($IsWindows) {
            $candidates += @(
                "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
                "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe",
                "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe"
            )
        } elseif ($IsMacOS) {
            $candidates += @(
                '/opt/homebrew/opt/openssl@3/bin/openssl',
                '/opt/homebrew/opt/openssl/bin/openssl',
                '/usr/local/opt/openssl@3/bin/openssl',
                '/usr/local/opt/openssl/bin/openssl'
            )
        }
        $candidates += 'openssl'
    }

    foreach ($p in $candidates) {
        if ($p -ne 'openssl' -and -not (Test-Path -LiteralPath $p)) { continue }
        try {
            # `--` MUST stay -- a leading dash in $Plaintext would
            # otherwise be parsed as an option. See function description.
            $raw = (& $p passwd -6 -- $Plaintext 2>$null)
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $hash = ([string]$raw).Trim()
                if ($hash.StartsWith('$6$')) {
                    Write-Verbose "ConvertTo-Sha512CryptHash: hashed via '$p'"
                    return $hash
                }
            }
        } catch {
            Write-Verbose "ConvertTo-Sha512CryptHash: '$p' not usable: $($_.Exception.Message)"
        }
    }
    throw "ConvertTo-Sha512CryptHash: no working openssl with SHA-512 (-6) support found. Tried: $($candidates -join ', '). Install OpenSSL >= 1.1 (Linux/macOS) or Git for Windows."
}

Export-ModuleMember -Function New-YurunaTimestampedBackup, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Get-CachingProxyPort, Test-Ipv4Address, Test-Ipv6Address, Format-IpUrlHost, Test-IpAddress, ConvertTo-Sha512CryptHash
