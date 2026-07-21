<#PSScriptInfo
.VERSION 2026.07.21
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
        only the timestamp + copy + retention + verbose line live here so the
        timestamp format cannot drift between publishers. Best-effort by contract:
        -ErrorAction SilentlyContinue on the copy and the retention sweep, and
        nothing is emitted to the pipeline so a publisher's singular
        result-manifest return stays clean.

        Retention: only the newest $KeepCount backups per prefix are kept. The
        publishers run every cycle, so without a cap the dated copies accumulate
        without bound. The timestamp format sorts lexicographically ==
        chronologically, so the sweep needs no date parsing.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort backup copy of a config file (-ErrorAction SilentlyContinue by contract); ShouldProcess would not fit a publisher prelude step that never blocks on the copy result.')]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$Prefix,
        [int]$KeepCount = 20
    )
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}', (Get-Date)))
    $backupFile = Join-Path -Path $WorkFolder -ChildPath "$Prefix.$dtTime.yml"
    Copy-Item "$SourceFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $SourceFile copied to: $backupFile"
    if ($KeepCount -gt 0) {
        # The name filter is deliberately narrow (exact prefix + the dated-yml
        # shape) so the sweep can never touch the live config or any
        # non-backup artifact sharing the work folder.
        $stale = @(Get-ChildItem -LiteralPath $WorkFolder -File -Filter "$Prefix.*.yml" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($Prefix) + '\.\d{4}(-\d{2}){5}\.yml$') } |
            Sort-Object -Property Name -Descending |
            Select-Object -Skip $KeepCount)
        foreach ($old in $stale) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
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

function ConvertTo-YurunaMacAddress {
<#
.SYNOPSIS
    Normalize and validate a MAC address to canonical AA:BB:CC:DD:EE:FF.
.DESCRIPTION
    Accepts the three common notations -- colon-separated, dash-separated,
    and bare 12-hex-digit -- and returns the canonical uppercase
    colon-separated form. Callers reformat from the canonical form to
    their platform's native notation (Hyper-V StaticMacAddress takes bare
    hex; virt-install and UTM config.plist take colons).

    Returns $null (with a Warning naming the reason) when the input is
    not a usable unicast MAC:
      * not 12 hex digits after separator removal, or mixed separators;
      * multicast (first octet's least-significant bit set) -- DHCP
        cannot lease to a multicast source address;
      * all-zeros -- rejected by every hypervisor.

    Additionally warns (but still returns the MAC) when the
    locally-administered bit (0x02 of the first octet) is NOT set: a
    globally-unique OUI address can collide with real hardware on the
    LAN. Pick from the x2/x6/xA/xE second-hex-digit ranges to stay safe.
.OUTPUTS
    [string] canonical MAC, or $null when invalid.
.EXAMPLE
    ConvertTo-YurunaMacAddress '02-11-22-33-44-55'   # '02:11:22:33:44:55'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MacAddress)

    $trimmed = $MacAddress.Trim()
    # One notation at a time: colon-separated, dash-separated, or bare.
    # A permissive strip-all-separators pass would accept mixed forms
    # like '02:11-22...' that are more likely typos than intent.
    if ($trimmed -notmatch '^([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{12})$') {
        Write-Warning "MAC address '$MacAddress' is not valid. Use AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, or AABBCCDDEEFF (12 hex digits)."
        return $null
    }
    $bare = ($trimmed -replace '[:-]', '').ToUpperInvariant()
    if ($bare -eq '000000000000') {
        Write-Warning "MAC address '$MacAddress' is all-zeros; hypervisors reject it."
        return $null
    }
    $firstOctet = [Convert]::ToInt32($bare.Substring(0, 2), 16)
    if ($firstOctet -band 0x01) {
        Write-Warning "MAC address '$MacAddress' is multicast (first octet's low bit is set); a NIC cannot source from it, so DHCP would never lease. Use an even first octet (e.g. 02:...)."
        return $null
    }
    if (-not ($firstOctet -band 0x02)) {
        Write-Warning "MAC address '$MacAddress' does not have the locally-administered bit set (first octet 0x02); it may collide with real hardware on the LAN. Consider a first octet like 02, 06, 0A, or 0E."
    }
    return (($bare -split '(..)' | Where-Object { $_ }) -join ':')
}

function ConvertTo-Ipv4UInt32 {
<#
.SYNOPSIS
    Convert a dotted-quad IPv4 string to its 32-bit numeric value.
.DESCRIPTION
    Folds the four octets by hand rather than going through
    [System.Net.IPAddress]::GetAddressBytes() + [BitConverter]::ToUInt32.
    GetAddressBytes returns network (big-endian) order, and BitConverter
    reads host order, so on a little-endian machine that pair silently
    reverses the octets. The reversed value still compares cleanly against
    another reversed value, but NOT against a mask -- the bug surfaces only
    as a wrong subnet verdict, never as an exception. Manual folding has no
    endianness to get wrong.

    Returns $null when the input is not a strict dotted-quad, so callers
    can treat "unparseable" and "out of range" identically.
.OUTPUTS
    [System.Nullable[uint32]] the numeric address, or $null.
.EXAMPLE
    ConvertTo-Ipv4UInt32 '192.168.64.2'   # 3232251394
#>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    if (-not (Test-Ipv4Address $Address)) { return $null }
    $o = $Address -split '\.'
    return [uint32](([uint32]$o[0] * 16777216) + ([uint32]$o[1] * 65536) + ([uint32]$o[2] * 256) + [uint32]$o[3])
}

function Get-HostIpv4Subnet {
<#
.SYNOPSIS
    Enumerate the live IPv4 subnets the host is directly attached to.
.DESCRIPTION
    Returns one object per usable IPv4 interface address, carrying the
    numeric address, numeric mask and numeric network so callers can do
    membership tests without re-parsing.

    Parses `/sbin/ifconfig` on macOS rather than using
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    or `ipconfig getiflist`. Both of those OMIT the vmnet bridge (bridge100)
    that every UTM guest is attached to, so a membership test built on them
    rejects every legitimate guest address. `ifconfig` with no arguments is
    the only enumeration on macOS that lists it.

    macOS prints the netmask in HEX (`netmask 0xffffff00`), not dotted-quad.
    Code that parses it as an address yields a mask of 0, which makes every
    candidate compare as on-link -- a guard that looks like it works and
    silently permits nothing. The hex form is required here.

    Loopback (127.0.0.0/8) and link-local (169.254.0.0/16) addresses are
    excluded: a candidate must never be judged reachable because it happens
    to share a subnet with lo0 or an autoconfigured stub.

    On a non-macOS host, or when the enumeration yields nothing, an EMPTY
    array is returned. Callers must treat empty as "unknown", never as
    "nothing is on-link" -- see Get-Ipv4OnLinkVerdict.
.PARAMETER IfconfigText
    Pre-captured `ifconfig` output to parse instead of invoking it. Lets
    callers and tests exercise the parser against a fixed interface table.
.OUTPUTS
    [pscustomobject[]] with Address, AddressValue, MaskValue, NetworkValue,
    PrefixLength.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$IfconfigText)

    $text = $IfconfigText
    if (-not $PSBoundParameters.ContainsKey('IfconfigText')) {
        if (-not $IsMacOS) { return @() }
        try {
            $text = (& /sbin/ifconfig 2>$null) -join "`n"
        } catch {
            Write-Debug "Get-HostIpv4Subnet: ifconfig enumeration failed: $($_.Exception.Message)"
            return @()
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $result = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '^\s+inet (\d+\.\d+\.\d+\.\d+)\s+netmask\s+0x([0-9a-fA-F]{8})') { continue }
        $addr = $Matches[1]
        $maskHex = $Matches[2]
        if ($addr -match '^(127\.|169\.254\.)') { continue }
        $addrVal = ConvertTo-Ipv4UInt32 $addr
        if ($null -eq $addrVal) { continue }
        $maskVal = [uint32][Convert]::ToUInt32($maskHex, 16)
        # A zero mask would make every candidate on-link. Treat it as an
        # unusable entry rather than an all-permitting one.
        if ($maskVal -eq [uint32]0) { continue }
        $prefix = 0
        for ($bit = 31; $bit -ge 0; $bit--) {
            if (($maskVal -shr $bit) -band [uint32]1) { $prefix++ } else { break }
        }
        $result += [pscustomobject]@{
            Address      = $addr
            AddressValue = $addrVal
            MaskValue    = $maskVal
            NetworkValue = [uint32]($addrVal -band $maskVal)
            PrefixLength = $prefix
        }
    }
    return , ([pscustomobject[]]$result)
}

function Get-Ipv4OnLinkVerdict {
<#
.SYNOPSIS
    Decide whether an IPv4 address sits on a subnet the host is attached to.
.DESCRIPTION
    Returns one of three values:
      'onlink'  -- the address is inside a live host interface's subnet;
      'offlink' -- host subnets are known and the address is in none of them;
      'unknown' -- no host subnet could be enumerated, or the address is
                   unparseable.

    The tri-state is deliberate. An address that is not on any live subnet
    can only leave the host by the default route, where nothing answers for
    it -- rejecting it converts a long connect-timeout into an immediate
    "not found" and lets the caller keep looking. But an enumeration that
    comes back empty proves nothing, and collapsing that to 'offlink' would
    reject every address and turn a working discovery into a hard failure.
    Callers must act only on 'offlink' and let 'unknown' pass through.

    Membership is exact netmask arithmetic, not a leading-octet string
    compare: a /20 or /23 bridge is common enough that a hardcoded /24
    assumption both admits and rejects the wrong addresses.
.PARAMETER IpAddress
    The candidate IPv4 address.
.PARAMETER Subnet
    Pre-enumerated host subnets from Get-HostIpv4Subnet. Supplied by
    callers that test many candidates against one table, and by tests that
    need a fixed table.
.OUTPUTS
    [string] 'onlink' | 'offlink' | 'unknown'
.EXAMPLE
    Get-Ipv4OnLinkVerdict -IpAddress '192.168.65.42'   # 'offlink' when the
                                                       # host has no such NIC
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$IpAddress,
        [pscustomobject[]]$Subnet
    )
    $candidate = ConvertTo-Ipv4UInt32 $IpAddress
    if ($null -eq $candidate) { return 'unknown' }
    $table = $Subnet
    if (-not $PSBoundParameters.ContainsKey('Subnet')) { $table = Get-HostIpv4Subnet }
    if (-not $table -or $table.Count -eq 0) { return 'unknown' }
    foreach ($s in $table) {
        if (([uint32]($candidate -band $s.MaskValue)) -eq $s.NetworkValue) { return 'onlink' }
    }
    return 'offlink'
}

function Select-DhcpLeaseIpAddress {
<#
.SYNOPSIS
    Pick the live guest IPv4 out of macOS `/var/db/dhcpd_leases` text.
.DESCRIPTION
    The macOS shared-NAT DHCP server files each lease as a `{ ... }` block
    keyed by the name the guest sent, and NEVER prunes blocks for guests
    that no longer exist. Two things follow, and both have bitten:

    1. The name is the guest's own hostname, which is the VM name only when
       no sequence pinned `variables.hostname`. When one is pinned the guest
       registers under THAT name, and every block still filed under the VM
       name belongs to a predecessor. Those blocks match, so a VM-name
       lookup does not come back empty -- it comes back with a dead address,
       frequently on a subnet the host has since stopped serving. Callers
       pass -Name in priority order (pinned hostname first, VM name second)
       so the guest is found whichever name it registered under.

    2. Several blocks can carry the same name: the live guest plus stale
       leases from deleted predecessors that reused the name. The lease's
       hw_address is a DHCP DUID rather than the bundle's link MAC, so it
       cannot disambiguate. The live guest keeps RENEWING while a dead one's
       lease only ages, so the largest `lease=` expiry is the live one. A
       block with no parseable `lease=` cannot prove it is renewing and is
       skipped outright rather than allowed to displace one that can.

    Candidates are additionally filtered by -OnLinkVerdict. Only an explicit
    'offlink' rejects; 'unknown' is accepted, so a host whose interfaces
    cannot be enumerated keeps the pre-existing behavior instead of
    discarding every candidate.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Name
    Names to try, most specific first. The first name that yields an
    acceptable address wins; later names are not consulted.
.PARAMETER OnLinkVerdict
    Scriptblock taking one IPv4 string and returning 'onlink' | 'offlink' |
    'unknown'. Defaults to Get-Ipv4OnLinkVerdict against the live host.
.OUTPUTS
    [string] the selected IPv4, or $null when no name yields one.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [Parameter(Mandatory)][string[]]$Name,
        [scriptblock]$OnLinkVerdict
    )
    if ([string]::IsNullOrWhiteSpace($LeaseText)) { return $null }
    if (-not $OnLinkVerdict) {
        # Enumerate once for the whole scan; Get-VMIp runs inside polling
        # loops, and shelling out per candidate block would be a real cost.
        $subnetTable = Get-HostIpv4Subnet
        $OnLinkVerdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet $subnetTable }.GetNewClosure()
    }
    $blocks = [regex]::Matches($LeaseText, '\{[^}]*\}')
    foreach ($candidateName in $Name) {
        if ([string]::IsNullOrWhiteSpace($candidateName)) { continue }
        # Compile the name pattern once per name; building it inside the
        # block loop forces a fresh regex compile for every block.
        $namePattern = "(?m)^\s*name=$([regex]::Escape($candidateName))\s*$"
        $bestIp = $null
        $bestLease = [int64]-1
        foreach ($b in $blocks) {
            $text = $b.Value
            if ($text -notmatch $namePattern) { continue }
            if ($text -notmatch "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") { continue }
            $ip = [string]$Matches[1]
            if (-not (Test-Ipv4Address $ip)) { continue }
            if ($text -notmatch "(?m)^\s*lease=0x([0-9a-fA-F]+)\s*$") { continue }
            $leaseVal = [Convert]::ToInt64($Matches[1], 16)
            if ((& $OnLinkVerdict $ip) -eq 'offlink') {
                Write-Debug "Select-DhcpLeaseIpAddress: rejecting lease $ip for '$candidateName' -- not on any live host interface subnet, so it is unreachable except by the default route."
                continue
            }
            # Strict -gt so an equal or lower expiry block later in the file
            # cannot displace a more recently renewed one already recorded.
            if ($leaseVal -gt $bestLease) { $bestLease = $leaseVal; $bestIp = $ip }
        }
        if ($bestIp) { return $bestIp }
    }
    return $null
}

function Get-UtmGuestSeedHostname {
<#
.SYNOPSIS
    Read the hostname a UTM guest was seeded with, or fall back to the VM name.
.DESCRIPTION
    A sequence can pin `variables.hostname`, which the per-guest New-VM
    substitutes into the cloud-init meta-data as `local-hostname:` before
    baking the seed ISO. The guest then DHCP-registers under that name, not
    under the VM name, so anything keyed on the VM name is looking for the
    wrong string.

    The baked seed at <bundle>/Data/seed.iso is the only durable record of
    that value on the host: the staging directory under
    $HOME/yuruna/image/<image>/seed_temp/ is deleted at the end of New-VM.
    ISO9660 stores the file uncompressed, so the raw bytes can be searched
    directly -- no `hdiutil attach` and no mount point to clean up.

    Degrades to $VMName and never throws. Guests whose meta-data hardcodes
    a hostname, guests with no cloud-init seed at all, and a bundle that has
    not been built yet must all keep working; a missing seed means "no
    hostname was pinned", which is exactly the VM-name case.
.PARAMETER VMName
    The VM name, used both to locate the bundle and as the fallback.
.PARAMETER BundleRoot
    Directory holding the `<VMName>.utm` bundles.
.OUTPUTS
    [string] the pinned hostname, or $VMName.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$BundleRoot = (Join-Path $HOME 'yuruna/guest.nosync')
    )
    try {
        $seedPath = Join-Path $BundleRoot "$VMName.utm" -AdditionalChildPath 'Data', 'seed.iso'
        if (-not (Test-Path -LiteralPath $seedPath)) { return $VMName }
        # Latin1 round-trips every byte to a char, so a binary image can be
        # regexed without a decoder rejecting or substituting anything.
        $bytes = [System.IO.File]::ReadAllBytes($seedPath)
        $text = [System.Text.Encoding]::Latin1.GetString($bytes)
        if ($text -match '(?m)^local-hostname:\s*(\S+)\s*$') {
            $pinned = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($pinned)) { return [string]$pinned }
        }
    } catch {
        Write-Debug "Get-UtmGuestSeedHostname: seed read failed for ${VMName}: $($_.Exception.Message)"
    }
    return $VMName
}

Export-ModuleMember -Function New-YurunaTimestampedBackup, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Get-CachingProxyPort, Test-Ipv4Address, Test-Ipv6Address, Format-IpUrlHost, Test-IpAddress, ConvertTo-Sha512CryptHash, ConvertTo-YurunaMacAddress, ConvertTo-Ipv4UInt32, Get-HostIpv4Subnet, Get-Ipv4OnLinkVerdict, Select-DhcpLeaseIpAddress, Get-UtmGuestSeedHostname
