<#PSScriptInfo
.VERSION 2026.08.03
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
    return (Join-Path $RuntimeDir 'caching-proxy-service-port-map.json')
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

function Get-PwshApplicationPath {
<#
.SYNOPSIS
    Absolute path of the pwsh EXECUTABLE to hand another program, or 'pwsh'
    when it cannot be resolved from PATH.
.DESCRIPTION
    Deliberately resolved through PATH (Get-Command -CommandType Application)
    rather than [Environment]::ProcessPath. On a Homebrew PowerShell those are
    different files: PATH finds brew's wrapper, which exports DOTNET_ROOT before
    exec'ing the runtime, while ProcessPath is the libexec apphost the wrapper
    exec'd -- launching THAT directly is how a nested pwsh ends up unable to
    find libhostfxr. Never use ProcessPath to re-launch pwsh.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $resolved = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved -and $resolved.Source) { return $resolved.Source }
    return 'pwsh'
}

function Get-SudoPwshArgumentList {
<#
.SYNOPSIS
    Builds the argument vector for running a PowerShell script under sudo:
    @([-n] [-E] <pwsh> -NoProfile -File <script> <script args...>). Pure apart
    from the PATH lookup for pwsh.
.DESCRIPTION
    Two things have to be right or the child never reaches the script.

    The environment. macOS PowerShell installed from the Homebrew FORMULA is
    framework-dependent on brew's dotnet and finds its runtime through
    DOTNET_ROOT, exported by the wrapper on PATH. sudo's env_reset drops that
    variable, so the child starts, fails to locate libhostfxr, and exits 131 --
    before reading a line of the script, and with an error that names .NET
    rather than the caller. -E preserves it.

    -E is macOS-only on purpose. Linux ships a self-contained
    /opt/microsoft/powershell/7 that needs nothing preserved, and a sudoers rule
    carrying NOSETENV there REJECTS -E outright -- so adding it unconditionally
    would break the hosts that work today. The durable machine-wide fix on macOS
    is /etc/dotnet/install_location_<arch>; install/macos.utm.sh writes it.

    The interpreter. Passed as an absolute path from Get-PwshApplicationPath so
    the child is the same PowerShell the caller is using.
.PARAMETER ScriptPath
    Script for pwsh to run with -File.
.PARAMETER ScriptArgument
    Arguments appended after the script path.
.PARAMETER NonInteractive
    Adds sudo -n, so a cold sudo timestamp fails immediately instead of blocking
    on a password prompt no one is watching.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [switch]$NonInteractive
    )
    $sudoOption = @()
    if ($NonInteractive) { $sudoOption += '-n' }
    if ($IsMacOS)        { $sudoOption += '-E' }
    return [string[]]@($sudoOption + @((Get-PwshApplicationPath), '-NoProfile', '-File', $ScriptPath) + $ScriptArgument)
}

function Invoke-YurunaSudo {
<#
.SYNOPSIS
    Run one command under sudo, adding -n on the unattended path so a cold sudo
    timestamp fails immediately instead of blocking on a password prompt.
.DESCRIPTION
    THE PROBLEM THIS SOLVES. The test runner spawns its inner cycle with the
    call operator, so the inner inherits the launch terminal. sudo reads the
    password from /dev/tty, NOT from stdin -- redirecting or closing stdin does
    nothing. A bare `& sudo ...` anywhere in the cycle therefore parks the whole
    host on a prompt nobody is present to answer, while runner.heartbeat (a
    threadpool timer) keeps ticking and the dashboard keeps showing the last
    cycle's green. Passing -n turns that indefinite stall into an immediate,
    attributable failure.

    WHEN -n IS ADDED. Whenever $env:YURUNA_NONINTERACTIVE is '1' -- set by the
    outer runner around every inner spawn, and by the inner on itself. An
    operator running a host script by hand has no such variable, keeps the
    interactive behaviour, and can still be prompted once, which is correct:
    they are watching.

    WHEN IT THROWS. If sudo reports that it needs a password (or a terminal, or
    that the account may not run the command), that is not a transient error:
    every later elevated call this cycle fails the same way, and the host needs
    hands on it. Throwing once, with the exact /etc/sudoers.d rule to install,
    beats twenty silent no-ops that leave the cycle "green but wrong". Pass
    -TolerateBlocked for a caller that genuinely wants to continue degraded.
.PARAMETER Argument
    The command and its arguments, e.g. @('systemctl','daemon-reload').
.PARAMETER InputText
    Text piped to the command's stdin. This is how root-owned files get written
    across the codebase (`$body | sudo tee /etc/...`), and it is why the stdin
    of the child cannot simply be closed: tee needs it for the payload, while
    sudo takes the password from /dev/tty regardless.
.PARAMETER TolerateBlocked
    Return the result instead of throwing when sudo says it needs a password.
.OUTPUTS
    [hashtable] @{ ExitCode; Output; Blocked }.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [string]$InputText,
        [switch]$TolerateBlocked
    )
    $unattended = ($env:YURUNA_NONINTERACTIVE -eq '1')
    $sudoArgs = @()
    if ($unattended) { $sudoArgs += '-n' }
    $sudoArgs += $Argument

    $raw = if ($PSBoundParameters.ContainsKey('InputText')) {
        $InputText | & sudo @sudoArgs 2>&1
    } else {
        & sudo @sudoArgs 2>&1
    }
    $rc  = $LASTEXITCODE
    $out = (@($raw) | ForEach-Object { "$_" }) -join "`n"

    # sudo's own refusal signatures. Matched on text because the exit code is 1
    # for "wrong password", "no tty", and "not permitted" alike -- and also for
    # plenty of ordinary command failures we must NOT misreport as an elevation
    # problem.
    $blocked = ($rc -ne 0) -and ($out -match 'a password is required|a terminal is required|no tty present|may not run|is not in the sudoers file')
    $result = @{ ExitCode = $rc; Output = $out; Blocked = $blocked }
    if (-not $blocked) { return $result }

    $cmd  = @($Argument)[0]
    $who  = try { "$(& '/usr/bin/id' -un 2>$null)".Trim() } catch { "$($env:USER)".Trim() }
    $full = (Get-Command -CommandType Application -Name (Split-Path -Leaf "$cmd") -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $full) { $full = $cmd }
    $msg = @(
        "Elevation required and no operator is present: sudo refused '$cmd'."
        "  Account: $who"
        "  sudo:    $($out.Trim())"
        '  This cannot be repaired remotely -- it needs onsite/console access:'
        "    echo '$who ALL=(root) NOPASSWD: $full' | sudo tee /etc/sudoers.d/yuruna-runner >/dev/null"
        '    sudo chmod 0440 /etc/sudoers.d/yuruna-runner && sudo visudo -cf /etc/sudoers.d/yuruna-runner'
    ) -join [Environment]::NewLine

    if ($TolerateBlocked) {
        Write-Warning $msg
        return $result
    }
    throw $msg
}

function Get-CachingProxyServicePort {
<#
.SYNOPSIS
    Resolve the client-facing caching-proxy-service port for one of the supported
    schemes (http / https / ftp), honoring per-scheme env-var overrides
    with squid-style defaults.
.DESCRIPTION
    Reads `$env:YURUNA_CACHING_PROXY_SERVICE_<SCHEME>_PORT`. Empty / missing /
    non-integer values fall through to the squid defaults: 3128 for HTTP,
    3129 for HTTPS, 3128 for FTP. The FTP knob is reserved for callers
    extending the harness (squid handles FTP via HTTP CONNECT today, so
    out-of-the-box code uses 3128 -- same value as HTTP).

    Companion to YURUNA_CACHING_PROXY_SERVICE_IP: clients that need to point at
    a non-default external squid (different IP AND/OR different port)
    set both knobs together.
.OUTPUTS
    [int]
.EXAMPLE
    Get-CachingProxyServicePort                       # 3128 (or override)
    Get-CachingProxyServicePort -Scheme https         # 3129 (or override)
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateSet('http','https','ftp')]
        [string]$Scheme = 'http'
    )
    $envVar = "YURUNA_CACHING_PROXY_SERVICE_$($Scheme.ToUpperInvariant())_PORT"
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
    ConvertTo-Ipv4UInt32 '192.168.64.2'   # 3232251906
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

function Test-TcpConnectOutcome {
<#
.SYNOPSIS
    Connect to $IpAddress:$Port within $TimeoutMs and report WHAT happened, not
    merely whether it worked.
.DESCRIPTION
    A failed TCP connect carries two opposite diagnoses and a bool cannot hold
    either of them:

      * 'refused' -- the peer sent an RST. The host is up and the path to it
        works; nothing is listening on that port. A service is down, restarting,
        or was never started. It comes back in milliseconds.
      * 'timeout' -- nothing answered before the deadline. Now the PATH is the
        suspect: a peer that vanished, a bridge that stopped forwarding, an
        uplink that roamed, or a peer too loaded to accept.

    Collapsing those into "did not answer within Ns" sends the reader hunting
    through the network for a fault that is entirely inside the peer, and throws
    away the tell that distinguishes them -- the elapsed time. Tens of
    milliseconds against a 3000 ms budget is not a timeout, it is a refusal.

    ElapsedMs is returned for exactly that reason: a caller that prints it makes
    the distinction legible even to a reader who does not know these outcomes
    exist.
.PARAMETER TimeoutMs
    Deadline for the connect. Bounds only the 'timeout' verdict; a refusal
    returns as fast as the peer answers.
.OUTPUTS
    [hashtable] @{
        Outcome   = 'reachable' | 'refused' | 'timeout' | 'unreachable' | 'error'
        Reachable = [bool] Outcome -eq 'reachable'
        ElapsedMs = [int]
        Detail    = socket error text, '' when there was none
    }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $tcp     = New-Object System.Net.Sockets.TcpClient
    $outcome = 'timeout'
    $detail  = ''
    try {
        $async = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            # The wait completing means the operation FINISHED, not that it
            # succeeded -- a refusal completes it just as much as a connect
            # does. EndConnect is what surfaces which, and calling it is also
            # what releases the async operation instead of abandoning it.
            try {
                $tcp.EndConnect($async)
                $outcome = if ($tcp.Connected) { 'reachable' } else { 'refused' }
            } catch {
                $detail = $_.Exception.Message
                # The SocketException can arrive wrapped; walk to it rather
                # than matching on message text, which is localized.
                $ex = $_.Exception
                while ($ex -and -not ($ex -is [System.Net.Sockets.SocketException])) { $ex = $ex.InnerException }
                switch ("$(if ($ex) { $ex.SocketErrorCode })") {
                    'ConnectionRefused'  { $outcome = 'refused' }
                    'HostUnreachable'    { $outcome = 'unreachable' }
                    'NetworkUnreachable' { $outcome = 'unreachable' }
                    'HostDown'           { $outcome = 'unreachable' }
                    'TimedOut'           { $outcome = 'timeout' }
                    default              { $outcome = 'error' }
                }
            }
        }
    } catch {
        $detail  = $_.Exception.Message
        $outcome = 'error'
    } finally {
        $tcp.Close()
        $sw.Stop()
    }
    return @{
        Outcome   = $outcome
        Reachable = ($outcome -eq 'reachable')
        ElapsedMs = [int]$sw.ElapsedMilliseconds
        Detail    = $detail
    }
}

function Get-TcpOutcomeExplanation {
<#
.SYNOPSIS
    One sentence saying what a Test-TcpConnectOutcome result means and where to
    go looking. Shared so every caller phrases the same finding the same way.
.PARAMETER Outcome
    A Test-TcpConnectOutcome hashtable.
.PARAMETER Endpoint
    How to name the target in the sentence, e.g. "192.168.64.4:3128".
.OUTPUTS
    [string]
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Outcome,
        [Parameter(Mandatory)][string]$Endpoint
    )
    $ms = [int]$Outcome.ElapsedMs
    switch ([string]$Outcome.Outcome) {
        'reachable'   { return "$Endpoint accepted in ${ms} ms." }
        'refused'     { return "$Endpoint REFUSED the connection in ${ms} ms -- the host answered, so the network path is fine and nothing is listening on that port. The service is down, restarting, or was never started." }
        'timeout'     { return "$Endpoint did not answer within ${ms} ms -- nothing responded at all, so the path is the suspect: the peer is gone, a bridge stopped forwarding, the uplink roamed, or the peer is too loaded to accept." }
        'unreachable' { return "$Endpoint is unreachable after ${ms} ms -- the network rejected the route before any peer was contacted (no interface, no route, or a host that is down)." }
        default       { return "$Endpoint could not be probed after ${ms} ms: $($Outcome.Detail)" }
    }
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

function Get-PoolFacingIpv4Segment {
<#
.SYNOPSIS
    The IPv4 network this host reaches the rest of the lab over, or $null
    when it cannot be determined.
.DESCRIPTION
    A host runs two kinds of guest network: the LAN it shares with every
    other machine, and a hypervisor-private one only it can see (the macOS
    shared vmnet, a Hyper-V Default Switch, libvirt's virbr0). Both look
    identical from the host -- an RFC 1918 address on a live interface,
    answering probes -- so a service VM on the private one is confirmed by
    its own host and then unreachable for everyone else.

    Telling them apart needs the routing table, not the address: the
    network carrying the route OFF this machine is the one other machines
    are on. A UDP socket "connected" to an address that is not local
    performs exactly that route lookup and nothing else -- UDP connect
    sends no packet -- and its local endpoint is the address the kernel
    would source from. The interface owning that address supplies the
    mask.

    Returns $null on any inconclusive step (no route, no matching
    interface, no mask available). Callers MUST treat $null as "unknown"
    and permit, never as "nothing is on the segment" -- the same tri-state
    discipline as Get-Ipv4OnLinkVerdict.
.PARAMETER ReferenceAddress
    An address to resolve the route toward. Defaults to a documentation
    address (RFC 5737 TEST-NET-1), which is unallocated and therefore
    guaranteed to resolve through the DEFAULT route rather than a local
    one; nothing is ever sent to it. Pass a real lab address (the caching
    proxy) when the pool is reached over a route other than the default.
.OUTPUTS
    [pscustomobject] with Address, AddressValue, MaskValue, NetworkValue,
    PrefixLength -- the same shape Get-HostIpv4Subnet emits -- or $null.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$ReferenceAddress = '192.0.2.1')

    $local = $null
    $socket = $null
    try {
        $reference = $null
        if (-not [System.Net.IPAddress]::TryParse($ReferenceAddress, [ref]$reference)) { return $null }
        if ($reference.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
        $socket = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        # Port 9 (discard). Connect on a datagram socket only binds the local
        # end to the route's source address; no datagram is sent.
        $socket.Connect($reference, 9)
        $endpoint = [System.Net.IPEndPoint]$socket.LocalEndPoint
        if ($endpoint) { $local = $endpoint.Address.ToString() }
    } catch {
        Write-Debug "Get-PoolFacingIpv4Segment: route lookup toward '$ReferenceAddress' failed: $($_.Exception.Message)"
        return $null
    } finally {
        if ($socket) { $socket.Dispose() }
    }
    if (-not (Test-Ipv4Address $local)) { return $null }

    $addrVal = ConvertTo-Ipv4UInt32 $local
    if ($null -eq $addrVal) { return $null }
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                if ($unicast.Address.ToString() -ne $local) { continue }
                # IPv4Mask is not implemented on every platform/interface; a
                # missing or zero mask would make every address compare as
                # on-segment, so it is treated as unknown instead.
                $maskVal = ConvertTo-Ipv4UInt32 ([string]$unicast.IPv4Mask)
                if ($null -eq $maskVal -or $maskVal -eq [uint32]0) { continue }
                $prefix = 0
                for ($bit = 31; $bit -ge 0; $bit--) {
                    if (($maskVal -shr $bit) -band [uint32]1) { $prefix++ } else { break }
                }
                return [pscustomobject]@{
                    Address      = $local
                    AddressValue = $addrVal
                    MaskValue    = $maskVal
                    NetworkValue = [uint32]($addrVal -band $maskVal)
                    PrefixLength = $prefix
                }
            }
        }
    } catch {
        Write-Debug "Get-PoolFacingIpv4Segment: interface enumeration failed: $($_.Exception.Message)"
    }
    # macOS fallback: .NET's enumeration is the portable path, but the mask it
    # reports is not available on every platform/interface. Get-HostIpv4Subnet
    # reads the same interfaces out of ifconfig, where the mask always is.
    foreach ($subnet in (Get-HostIpv4Subnet)) {
        if ($subnet.Address -ne $local) { continue }
        return $subnet
    }
    return $null
}

function Get-Ipv4PoolSegmentVerdict {
<#
.SYNOPSIS
    Decide whether an IPv4 address is one the REST OF THE LAB could reach,
    or one that exists only inside this host.
.DESCRIPTION
    Returns one of three values:
      'onsegment'  -- the address shares this host's pool-facing network;
      'offsegment' -- the pool-facing network is known and the address is
                      not on it (the signature of a guest sitting on a
                      hypervisor-private network: the macOS shared vmnet,
                      a Hyper-V Default Switch, libvirt's virbr0);
      'unknown'    -- the pool-facing network could not be determined, or
                      the address is unparseable.

    The tri-state is deliberate, and callers must act ONLY on 'offsegment'.
    An address on another routed subnet of a larger lab is 'offsegment'
    here as well, so this is a reason to stop ADVERTISING an address to
    other hosts -- something only its own host can be wrong about -- never
    a reason to stop using it locally, and never the last word: a service
    that is genuinely reachable still registers through its own announce,
    which the pool confirms by probing it.
.PARAMETER Address
    The candidate IPv4 address.
.PARAMETER Segment
    Pre-resolved pool-facing segment from Get-PoolFacingIpv4Segment.
    Supplied by callers testing several addresses against one answer, and
    by tests that need a fixed one.
.OUTPUTS
    [string] 'onsegment' | 'offsegment' | 'unknown'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Address,
        [pscustomobject]$Segment
    )
    $candidate = ConvertTo-Ipv4UInt32 $Address
    if ($null -eq $candidate) { return 'unknown' }
    $seg = $Segment
    if (-not $PSBoundParameters.ContainsKey('Segment')) { $seg = Get-PoolFacingIpv4Segment }
    if (-not $seg) { return 'unknown' }
    if (([uint32]($candidate -band $seg.MaskValue)) -eq $seg.NetworkValue) { return 'onsegment' }
    return 'offsegment'
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
    'offlink' rejects; 'unknown' is accepted, because an empty interface
    enumeration proves nothing and must not collapse into rejecting every
    candidate -- when the host subnets cannot be enumerated, selection falls
    back to the lease-expiry tie-break alone.
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

function Select-StaleDhcpLeaseBlock {
<#
.SYNOPSIS
    Pick the lease blocks in macOS `/var/db/dhcpd_leases` that a name lookup
    could mistake for a live guest, and that provably are not one.
.DESCRIPTION
    macOS files each lease under the name the guest sent and never prunes, so
    a VM name that is rebuilt accumulates one block per incarnation. Only the
    newest is real; the rest are indistinguishable from it to a name lookup
    except by expiry, which is the whole reason Select-DhcpLeaseIpAddress has
    to guess at all. During the seconds a freshly built guest has not yet
    taken its lease, that guess necessarily lands on a predecessor.

    Removing the predecessors removes the guess. What is selected:

      * only names carrying MORE than one block -- a name with a single block
        is the only answer a lookup can give for it, right or wrong, and
        deleting it changes nothing except to lose history;
      * never the largest-expiry block of a name, which is the live guest by
        the same rule Select-DhcpLeaseIpAddress selects it by;
      * never a block whose address is confirmed to be in use, whatever the
        expiry says. -InUseVerdict is the caller's reachability test, and it
        is the veto: an address that answers belongs to something running, and
        an expiry-based heuristic does not get to overrule an observation.
        Its 'unknown' is not a veto -- a probe that could not be run proves
        nothing, and treating that as in-use would select nothing on a host
        where probing is unavailable.

    Blocks with no parseable name, address, or expiry are left alone: they
    cannot be shown stale, and this is a file the DHCP server owns.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Name
    Restrict to these guest names. Empty (the default) considers every name.
.PARAMETER InUseVerdict
    Scriptblock taking one IPv4 string, returning 'inuse' | 'free' | 'unknown'.
    Defaults to treating everything as 'unknown' -- a caller that wants the
    veto passes a real probe.
.OUTPUTS
    Zero or more [pscustomobject] @{ Name; IpAddress; LeaseExpiry; Text },
    newest-expiry first within each name. Callers must normalize with @().
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [string[]]$Name = @(),
        [scriptblock]$InUseVerdict
    )
    if ([string]::IsNullOrWhiteSpace($LeaseText)) { return }
    if (-not $InUseVerdict) { $InUseVerdict = { 'unknown' } }
    $wanted = @($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $parsed = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($b in [regex]::Matches($LeaseText, '\{[^}]*\}')) {
        $text = $b.Value
        if ($text -notmatch '(?m)^\s*name=(.+?)\s*$') { continue }
        $blockName = [string]$Matches[1]
        if ($wanted.Count -gt 0 -and $wanted -notcontains $blockName) { continue }
        if ($text -notmatch '(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$') { continue }
        $ip = [string]$Matches[1]
        if (-not (Test-Ipv4Address $ip)) { continue }
        if ($text -notmatch '(?m)^\s*lease=0x([0-9a-fA-F]+)\s*$') { continue }
        [void]$parsed.Add([pscustomobject]@{
            Name        = $blockName
            IpAddress   = $ip
            LeaseExpiry = [Convert]::ToInt64($Matches[1], 16)
            Text        = $text
        })
    }

    foreach ($group in ($parsed | Group-Object -Property Name)) {
        if ($group.Count -le 1) { continue }
        # Sort once and drop the head: the largest expiry is the live guest,
        # by the same rule the resolver picks it. Ties keep both -- two blocks
        # with one expiry cannot be told apart, so neither is provably stale.
        $ordered = @($group.Group | Sort-Object -Property LeaseExpiry -Descending)
        $keepExpiry = $ordered[0].LeaseExpiry
        foreach ($block in $ordered) {
            if ($block.LeaseExpiry -eq $keepExpiry) { continue }
            $verdict = 'unknown'
            try { $verdict = [string](& $InUseVerdict $block.IpAddress) }
            catch { Write-Debug "Select-StaleDhcpLeaseBlock: the in-use probe for $($block.IpAddress) failed: $_" }
            if ($verdict -eq 'inuse') {
                Write-Debug "Select-StaleDhcpLeaseBlock: keeping $($block.IpAddress) for '$($block.Name)' -- it answers, so the expiry is not the whole story."
                continue
            }
            $block
        }
    }
}

function Remove-DhcpLeaseBlockText {
<#
.SYNOPSIS
    Return `$LeaseText` with the given blocks removed, or the text unchanged
    when none of them are present.
.DESCRIPTION
    Works on the exact block strings Select-StaleDhcpLeaseBlock captured, so
    the caller never re-parses and cannot drift from what it decided to
    remove. A block that is no longer found is skipped rather than treated as
    an error: the DHCP server rewrites this file whenever a lease moves, and
    a block that vanished under us is already gone.

    Only whole `{ ... }` blocks and the newline that follows them are cut, so
    the surviving text stays exactly the shape the DHCP server wrote.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Block
    Objects carrying a .Text property holding the verbatim block.
.OUTPUTS
    [string] the resulting file text.
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string transform: returns new text and touches nothing. The caller that writes the lease file is the one carrying ShouldProcess.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Block
    )
    $text = [string]$LeaseText
    foreach ($b in @($Block)) {
        $blockText = [string]$b.Text
        if ([string]::IsNullOrEmpty($blockText)) { continue }
        $index = $text.IndexOf($blockText, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { continue }
        $end = $index + $blockText.Length
        # Take the block's trailing newline with it so removals do not leave a
        # growing run of blank lines behind.
        if ($end -lt $text.Length -and $text[$end] -eq "`r") { $end++ }
        if ($end -lt $text.Length -and $text[$end] -eq "`n") { $end++ }
        $text = $text.Remove($index, $end - $index)
    }
    return $text
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

function ConvertTo-MemoryStartupBytes {
<#
.SYNOPSIS
    Parse a memory size (plain bytes, or a KB/MB/GB/TB-suffixed number) into an
    [int64] byte count.
.DESCRIPTION
    Normalizes the value of a sequence `variables.memoryStartupBytes` for the
    per-guest New-VM.ps1 scripts, so an author can write `34359738368`,
    `32768MB`, or `32GB` interchangeably. Suffixes are binary (1 KB = 1024
    bytes), matching PowerShell's own `1MB`/`1GB` literals -- so `32GB` yields
    the same 34359738368 the scripts would get from a raw `32GB` literal.

    Empty / whitespace / null returns 0 -- the "unset; keep the per-guest
    default" sentinel every caller checks with `-gt 0`. A non-numeric value, a
    bad suffix, or a non-positive size throws so a typo fails the build loudly
    instead of silently reverting to the default.
.PARAMETER Value
    The raw sequence-variable value (already stringified by the planner cascade).
.OUTPUTS
    [int64] byte count, or 0 when unset.
#>
    [OutputType([int64])]
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun mirrors the memoryStartupBytes sequence variable it parses and the Hyper-V MemoryStartupBytes property it feeds; a singular rename would break that one-to-one mapping with the field name authors write.')]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [int64]0 }
    $t = $Value.Trim()
    $m = [regex]::Match($t, '^(?<num>\d+)\s*(?<unit>KB|MB|GB|TB|KiB|MiB|GiB|TiB|B)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) {
        throw "Invalid memoryStartupBytes '$Value': expected an integer byte count or a number with a KB/MB/GB/TB suffix (e.g. 34359738368, 32768MB, 32GB)."
    }
    $num  = [int64]$m.Groups['num'].Value
    $unit = $m.Groups['unit'].Value.ToUpperInvariant()
    # PowerShell's 1KB/1MB/1GB/1TB literals are binary multipliers; reuse them so
    # a suffixed value and the equivalent bare literal agree to the byte.
    $mult = switch ($unit) {
        'KB'  { 1KB } 'KIB' { 1KB }
        'MB'  { 1MB } 'MIB' { 1MB }
        'GB'  { 1GB } 'GIB' { 1GB }
        'TB'  { 1TB } 'TIB' { 1TB }
        default { 1 }   # bytes / explicit 'B' / no suffix
    }
    $bytes = [int64]$num * [int64]$mult
    if ($bytes -le 0) {
        throw "Invalid memoryStartupBytes '$Value': must be a positive size."
    }
    return $bytes
}

function Get-YurunaServiceVmName {
<#
.SYNOPSIS
    The VM names that host this framework's SERVICES, as opposed to the guests a
    cycle creates and destroys.
.DESCRIPTION
    Concurrency guards exist to keep leftover TEST guests from competing with a
    cycle. These three are the opposite kind of VM: the cycle consumes them. The
    caching proxy serves every guest install, the stash service receives the
    build's binaries, and the pool-control service serves the intent store.
    Stopping one at cycle start -- or refusing to start because one is running --
    does not free the host, it removes something the cycle is about to require.

    There is one definition because there is more than one guard, and a name
    present in one list and missing from the other produces the worst outcome of
    the two: a service stopped by the first guard, then a refusal from the second
    because it is somehow still running. Callers that let an operator rename a
    service VM pass the new name explicitly.
.OUTPUTS
    System.String[]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@('yuruna-caching-proxy-service', 'yuruna-stash-service', 'yuruna-pool-control-service')
}

function Select-NameByPrefix {
<#
.SYNOPSIS
    Filter VM names to those starting with any of $Prefix.
.DESCRIPTION
    Shared by every host driver's Get-VMName so "matches the prefix"
    means the same thing on UTM, Hyper-V and libvirt. Matching is
    literal and case-insensitive: VM names are compared the way the
    hypervisors themselves treat them, and a prefix is a plain string,
    never a wildcard pattern -- an operator prefix containing [ or *
    would otherwise silently behave as a character class and sweep VMs
    it was never meant to name.

    An empty or absent prefix set selects everything. That makes
    Get-VMName with no -Prefix a full inventory call, and it keeps a
    caller that resolved its prefix list to nothing from silently
    matching nothing when it meant "no filter".
.PARAMETER Name
    Candidate names.
.PARAMETER Prefix
    Zero or more literal name prefixes.
.OUTPUTS
    [string[]] the matching names, in input order.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Name,
        [string[]]$Prefix
    )
    $candidates = @($Name | Where-Object { $_ })
    if ($candidates.Count -eq 0) { return [string[]]@() }
    $wanted = @($Prefix | Where-Object { $_ })
    if ($wanted.Count -eq 0) { return [string[]]$candidates }
    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        foreach ($p in $wanted) {
            if ($candidate.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$matched.Add($candidate)
                break
            }
        }
    }
    return $matched.ToArray()
}

Export-ModuleMember -Function New-YurunaTimestampedBackup, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Get-PwshApplicationPath, Get-SudoPwshArgumentList, Invoke-YurunaSudo, Get-CachingProxyServicePort, Test-Ipv4Address, Test-Ipv6Address, Format-IpUrlHost, Test-IpAddress, ConvertTo-Sha512CryptHash, ConvertTo-YurunaMacAddress, ConvertTo-Ipv4UInt32, Get-HostIpv4Subnet, Get-Ipv4OnLinkVerdict, Get-PoolFacingIpv4Segment, Get-Ipv4PoolSegmentVerdict, Test-TcpConnectOutcome, Get-TcpOutcomeExplanation, Select-DhcpLeaseIpAddress, Select-StaleDhcpLeaseBlock, Remove-DhcpLeaseBlockText, Get-UtmGuestSeedHostname, ConvertTo-MemoryStartupBytes, Select-NameByPrefix, Get-YurunaServiceVmName
