<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cross-host
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Cross-host test helpers (placeholder). Functions land here when the
    refactor extracts code from test/modules/Test.*.psm1 that is used
    by tests but is NOT host-specific (i.e. wouldn't fit in any single
    host/<x>/modules/Yuruna.Host.psm1).
#>

#requires -version 7

<#
.SYNOPSIS
    Cross-host test helpers shared across all hosts.

.DESCRIPTION
    Sibling to host/<host-tag>/modules/Yuruna.Host.psm1. Where a host
    driver implements the host-specific contract, this module collects
    helpers that are part of test orchestration but are themselves
    platform-agnostic -- e.g. SSH key-pair management (uses ssh-keygen
    the same way on every host), git-pull plumbing, pure parsing, etc.

    Initially empty; populated as the refactor proceeds.
#>

# Test.TrackDir.psm1 owns $env:YURUNA_TRACK_DIR + Initialize-YurunaTrackDir;
# import here so Get-PortMapStatePath can resolve the state file even when
# a caller hasn't bootstrapped the full runner path. -Global so a caller
# that already imported Test.TrackDir into its own session keeps seeing
# Initialize-YurunaTrackDir afterwards -- a -Force re-import without
# -Global evicts the caller's binding into Test.VM.common's private scope,
# which is exactly what broke Start-StatusServer.ps1 at "Initialize-
# YurunaTrackDir is not recognized".
Import-Module (Join-Path $PSScriptRoot 'Test.TrackDir.psm1') -Force -Global

function Wait-VMRunning {
<#
.SYNOPSIS
    Polls Get-VMState until the VM is running, then optionally waits a
    boot delay. Host-agnostic; relies entirely on the host driver's
    Get-VMState contract.
.DESCRIPTION
    Replaces the legacy Confirm-VMStarted -HostType ... pattern. The
    polling itself is identical on every host -- only the underlying
    state probe differs, and that difference now lives behind
    Get-VMState in host/<host-tag>/modules/Yuruna.Host.psm1.
.PARAMETER VMName
    Guest VM name as registered with the host hypervisor.
.PARAMETER TimeoutSeconds
    Total time budget. Default 120; the runner overrides this from
    test.config.yml's vmStart.startTimeoutSeconds.
.PARAMETER PollSeconds
    Interval between Get-VMState calls. Default 5 -- enough granularity
    for the VM-start window without burning CPU.
.PARAMETER BootDelaySeconds
    Additional sleep AFTER the VM reaches 'running'. Used to let
    cloud-init / first-boot scripts settle before the runner starts
    sending OCR-driven keystrokes. Default 0 (no delay).
.OUTPUTS
    [bool] -- $true on running before timeout, $false on timeout.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds   = 120,
        [int]$PollSeconds      = 5,
        [int]$BootDelaySeconds = 0
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VMState -VMName $VMName) -eq 'running') {
            Write-Verbose "Verified: VM '$VMName' is running"
            if ($BootDelaySeconds -gt 0) {
                Write-Verbose "VM is running. Waiting ${BootDelaySeconds}s for guest OS to initialize..."
                Start-Sleep -Seconds $BootDelaySeconds
            }
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Warning "VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

function Get-HostProxyBackupPath {
<#
.SYNOPSIS
    Return the absolute path of the host-proxy backup JSON file, creating
    its parent state directory if it doesn't already exist.
.DESCRIPTION
    $HOME/.yuruna/host-proxy.backup.json is the source of truth for
    Clear-HostProxy's restore; its mere existence is also the "are we
    currently promoted?" flag. Same path on every host -- this lives in
    Test.VM.common.psm1 (cross-host) rather than per-host Yuruna.Host.psm1.
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

function Get-PortMapStatePath {
<#
.SYNOPSIS
    Return the path of the port-map state JSON. Cross-host: same name
    in $env:YURUNA_TRACK_DIR / status/track on every platform.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$TrackDir)
    if (-not $TrackDir) {
        $TrackDir = Initialize-YurunaTrackDir
    } elseif (-not (Test-Path $TrackDir)) {
        New-Item -ItemType Directory -Path $TrackDir -Force | Out-Null
    }
    return (Join-Path $TrackDir 'caching-proxy-port-map.json')
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

function Compare-Screenshot {
<#
.SYNOPSIS
    Compares two PNG images and returns a similarity score (0.0 to 1.0).
.DESCRIPTION
    Pixel-level comparison via System.Drawing. Returns 1.0 for identical
    images. Host-agnostic -- callers on either host pass paths to PNGs
    captured via the contract's Get-VMScreenshot.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ReferencePath,
        [string]$ActualPath,
        [double]$Threshold = 0.85
    )
    if (-not (Test-Path $ReferencePath)) {
        Write-Error "Reference screenshot not found: $ReferencePath"
        return @{ match=$false; similarity=0.0; error="Reference not found" }
    }
    if (-not (Test-Path $ActualPath)) {
        Write-Error "Actual screenshot not found: $ActualPath"
        return @{ match=$false; similarity=0.0; error="Actual not found" }
    }
    try {
        Add-Type -AssemblyName System.Drawing
        $ref = [System.Drawing.Bitmap]::new($ReferencePath)
        $act = [System.Drawing.Bitmap]::new($ActualPath)
        if ($ref.Width -ne $act.Width -or $ref.Height -ne $act.Height) {
            $resized = [System.Drawing.Bitmap]::new($act, $ref.Width, $ref.Height)
            $act.Dispose()
            $act = $resized
        }
        $matchingPixels = 0
        $step = 4
        $sampled = 0
        for ($y = 0; $y -lt $ref.Height; $y += $step) {
            for ($x = 0; $x -lt $ref.Width; $x += $step) {
                $sampled++
                $rp = $ref.GetPixel($x, $y)
                $ap = $act.GetPixel($x, $y)
                $diff = [Math]::Abs([int]$rp.R - [int]$ap.R) +
                        [Math]::Abs([int]$rp.G - [int]$ap.G) +
                        [Math]::Abs([int]$rp.B - [int]$ap.B)
                if ($diff -lt 30) { $matchingPixels++ }
            }
        }
        $similarity = $sampled -gt 0 ? [Math]::Round($matchingPixels / $sampled, 4) : 0.0
        $ref.Dispose()
        $act.Dispose()
        $isMatch = $similarity -ge $Threshold
        Write-Information "Screenshot comparison: similarity=$similarity threshold=$Threshold match=$isMatch"
        return @{ match=$isMatch; similarity=$similarity; error=$null }
    } catch {
        Write-Error "Screenshot comparison failed: $_"
        return @{ match=$false; similarity=0.0; error="$_" }
    }
}

function Get-ScreenshotSchedule {
<#
.SYNOPSIS
    Reads the screenshot schedule JSON for a guest. Host-agnostic.
#>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([string]$GuestKey, [string]$ScreenshotsDir)
    $scheduleFile = Join-Path $ScreenshotsDir "$GuestKey/schedule.json"
    if (-not (Test-Path $scheduleFile)) { return @() }
    try {
        $schedule = Get-Content -Raw $scheduleFile | ConvertFrom-Json
        return @($schedule.checkpoints)
    } catch {
        Write-Warning "Failed to read screenshot schedule: $scheduleFile -- $_"
        return @()
    }
}

function Invoke-ScreenshotTest {
<#
.SYNOPSIS
    Executes all screenshot checkpoints for a running VM via the contract.
.DESCRIPTION
    Host-agnostic test orchestrator: relies on the host driver's
    Get-VMScreenshot (Yuruna.Host) for capture and on Compare-Screenshot
    here for the pixel comparison.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$GuestKey,
        [string]$VMName,
        [string]$ScreenshotsDir
    )
    $schedule = Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir
    if ($schedule.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    $guestDir   = Join-Path $ScreenshotsDir $GuestKey
    $captureDir = Join-Path $guestDir "captures"
    if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Force -Path $captureDir | Out-Null }
    foreach ($cp in $schedule) {
        $cpName    = $cp.name
        $delay     = [int]$cp.delaySeconds
        $threshold = $cp.threshold ? [double]$cp.threshold : 0.85
        $refFile   = Join-Path $guestDir "reference/$cpName.png"
        if (-not (Test-Path $refFile)) {
            return @{ success=$false; skipped=$false; errorMessage="Reference screenshot missing: $refFile. Run Train-Screenshots.ps1 -GuestKey $GuestKey first." }
        }
        Write-Information "  Screenshot checkpoint '$cpName': waiting ${delay}s..."
        Start-Sleep -Seconds $delay
        $capFile = Join-Path $captureDir "$cpName.png"
        $captured = Get-VMScreenshot -VMName $VMName -OutFile $capFile
        if (-not $captured) {
            return @{ success=$false; skipped=$false; errorMessage="Failed to capture screenshot for checkpoint '$cpName'" }
        }
        $result = Compare-Screenshot -ReferencePath $refFile -ActualPath $capFile -Threshold $threshold
        if (-not $result.match) {
            $msg = "Screenshot '$cpName' mismatch: similarity=$($result.similarity) threshold=$threshold"
            if ($result.error) { $msg += " error=$($result.error)" }
            return @{ success=$false; skipped=$false; errorMessage=$msg }
        }
        Write-Information "  Screenshot checkpoint '$cpName': PASS (similarity=$($result.similarity))"
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
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

    Provided here because the loose regex '^\d+\.\d+\.\d+\.\d+$' that the
    repo previously used in many places accepts out-of-range octets and
    gives false confidence (downstream TCP connect fails, but only after
    we've already passed validation). [System.Net.IPAddress]::TryParse is
    not strict enough either -- it accepts shortened/hex/octal forms.
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

Export-ModuleMember -Function Wait-VMRunning, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Compare-Screenshot, Get-ScreenshotSchedule, Invoke-ScreenshotTest, Get-CachingProxyPort, Test-Ipv4Address, Test-Ipv6Address, Test-IpAddress, Format-IpUrlHost
