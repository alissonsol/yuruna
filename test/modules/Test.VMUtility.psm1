<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cross-host
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Cross-host test helpers. Functions land here when they are used by
    tests but are NOT host-specific (i.e. wouldn't fit in any single
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

    Cross-host helpers that satisfy the placement rule above land here.
#>

# Test.YurunaDir.psm1 owns $env:YURUNA_RUNTIME_DIR + Initialize-YurunaRuntimeDir;
# import here so Get-PortMapStatePath can resolve the state file even when
# a caller hasn't bootstrapped the full runner path. -Global so a caller
# that already imported Test.YurunaDir into its own session keeps seeing
# Initialize-YurunaRuntimeDir afterwards -- a -Force re-import without
# -Global evicts the caller's binding into Test.VMUtility's private scope,
# which is exactly what broke Start-StatusService.ps1 at "Initialize-
# YurunaRuntimeDir is not recognized".
Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Force -Global

function Wait-VMRunning {
<#
.SYNOPSIS
    Polls Get-VMState until the VM is running, then optionally waits a
    boot delay. Host-agnostic; relies entirely on the host driver's
    Get-VMState contract.
.DESCRIPTION
    The polling is identical on every host -- only the underlying
    state probe differs, and that difference lives behind Get-VMState
    in host/<host-tag>/modules/Yuruna.Host.psm1.
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
        # A transient Get-VMState throw (e.g. WMI/virsh hiccup during boot) must not abort the
        # wait under ErrorActionPreference=Stop; treat it as "not running yet" and keep polling
        # until the deadline.
        $state = $null
        try { $state = Get-VMState -VMName $VMName } catch { Write-Verbose "Wait-VMRunning: Get-VMState threw: $($_.Exception.Message)" }
        if ($state -eq 'running') {
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
    Test.VMUtility.psm1 (cross-host) rather than per-host Yuruna.Host.psm1.
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
    $ref = $null
    $act = $null
    try {
        Add-Type -AssemblyName System.Drawing
        try {
            $ref = [System.Drawing.Bitmap]::new($ReferencePath)
            $act = [System.Drawing.Bitmap]::new($ActualPath)
            if ($ref.Width -ne $act.Width -or $ref.Height -ne $act.Height) {
                $resized = [System.Drawing.Bitmap]::new($act, $ref.Width, $ref.Height)
                $act.Dispose()
                $act = $resized
            }

            # LockBits + Marshal.Copy into managed byte[]. Each Bitmap.GetPixel
            # is a P/Invoke through GDI+ (microseconds per call); a 1024x768 at
            # step=4 needs ~49k pairs of calls and ran 1-3 s. Reading the whole
            # pixel buffer once and indexing into a byte[] is 10-50x faster.
            # Format32bppArgb byte order is B, G, R, A; stride is row-aligned.
            $rect = [System.Drawing.Rectangle]::new(0, 0, $ref.Width, $ref.Height)
            $pf   = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
            $lock = [System.Drawing.Imaging.ImageLockMode]::ReadOnly
            $refData = $ref.LockBits($rect, $lock, $pf)
            $actData = $act.LockBits($rect, $lock, $pf)
            try {
                $stride    = $refData.Stride
                $byteCount = $stride * $ref.Height
                $refBytes  = [byte[]]::new($byteCount)
                $actBytes  = [byte[]]::new($byteCount)
                [System.Runtime.InteropServices.Marshal]::Copy($refData.Scan0, $refBytes, 0, $byteCount)
                [System.Runtime.InteropServices.Marshal]::Copy($actData.Scan0, $actBytes, 0, $byteCount)
            } finally {
                $ref.UnlockBits($refData)
                $act.UnlockBits($actData)
            }

            $matchingPixels = 0
            $step = 4
            $sampled = 0
            for ($y = 0; $y -lt $ref.Height; $y += $step) {
                $rowStart = $y * $stride
                for ($x = 0; $x -lt $ref.Width; $x += $step) {
                    $sampled++
                    $i = $rowStart + ($x * 4)
                    $diff = [Math]::Abs([int]$refBytes[$i]     - [int]$actBytes[$i]) +
                            [Math]::Abs([int]$refBytes[$i + 1] - [int]$actBytes[$i + 1]) +
                            [Math]::Abs([int]$refBytes[$i + 2] - [int]$actBytes[$i + 2])
                    if ($diff -lt 30) { $matchingPixels++ }
                }
            }
            $similarity = $sampled -gt 0 ? [Math]::Round($matchingPixels / $sampled, 4) : 0.0
            $isMatch = $similarity -ge $Threshold
            Write-Information "Screenshot comparison: similarity=$similarity threshold=$Threshold match=$isMatch"
            return @{ match=$isMatch; similarity=$similarity; error=$null }
        } finally {
            # Dispose both source bitmaps on EVERY path: a LockBits / Marshal.Copy
            # throw would otherwise bypass the release and leak native GDI+ handles
            # across the per-cycle screenshot compares. Null-guarded because a
            # failed Bitmap::new leaves its variable $null; $act may already hold
            # the resized copy (the original is disposed at swap time).
            if ($ref) { $ref.Dispose() }
            if ($act) { $act.Dispose() }
        }
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

    Reference PNGs live under $ScreenshotsDir/<guestKey>/reference/
    in the source tree (one PNG per checkpoint named in schedule.json,
    captured manually and committed by the operator). Runtime captures
    (compared against the references each cycle) land under
    test/status/captures/training/<guestKey>/ -- gitignored, wiped when
    cleaning the host.
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
    $guestDir = Join-Path $ScreenshotsDir $GuestKey
    # Module file lives at test/modules/Test.VMUtility.psm1; one Split-Path
    # -Parent reaches test/. Runtime captures separate from reference PNGs
    # so cleaning status/ never wipes operator training output. Files are
    # written with the guest key prefixed onto the filename (one flat
    # captures/training/ folder; no per-guest subdir, to honor the
    # "max two subfolder levels under status/" rule).
    $testRoot   = Split-Path -Parent $PSScriptRoot
    $captureDir = Join-Path -Path $testRoot -ChildPath 'status' `
                       -AdditionalChildPath 'captures', 'training'
    if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Force -Path $captureDir | Out-Null }
    foreach ($cp in $schedule) {
        $cpName    = $cp.name
        $delay     = [int]$cp.delaySeconds
        $threshold = $cp.threshold ? [double]$cp.threshold : 0.85
        $refFile   = Join-Path $guestDir "reference/$cpName.png"
        if (-not (Test-Path $refFile)) {
            return @{ success=$false; skipped=$false; errorMessage="Reference screenshot missing: $refFile. Commit a PNG at that path (one per checkpoint in schedule.json) or remove the checkpoint." }
        }
        Write-Information "  Screenshot checkpoint '$cpName': waiting ${delay}s..."
        Start-Sleep -Seconds $delay
        $capFile = Join-Path $captureDir "${GuestKey}__${cpName}.png"
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

function Remove-GuestVMQuietly {
    <#
    .SYNOPSIS
        Tear down a guest VM with the Hyper-V progress bar suppressed.
    .DESCRIPTION
        Wraps the ProgressPreference save/restore around the Yuruna.Host
        contract Stop-VM + Remove-VM so the ~dozen teardown sites in the inner
        runner share one implementation -- one place to evolve VM teardown, the
        path that matters most when a cycle is failing. Stop-VM / Remove-VM are
        the -Global contract exports (resolved at call time after
        Initialize-YurunaHost); this helper never re-imports the host driver.
    .PARAMETER SkipStop
        Remove without stopping first (the pre-spawn cleanup of a leftover VM).
    .PARAMETER BestEffort
        Add -ErrorAction SilentlyContinue (emergency / catch-all teardown paths
        that must never throw on an already-gone VM).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Thin wrapper over the host contract Stop-VM/Remove-VM, which own the -Confirm:$false teardown semantics.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$SkipStop,
        [switch]$BestEffort
    )
    $savedProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        if ($BestEffort) {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
            Remove-VM -VMName $VMName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } else {
            if (-not $SkipStop) { Stop-VM -VMName $VMName -Confirm:$false | Out-Null }
            Remove-VM -VMName $VMName -Confirm:$false | Out-Null
        }
    } finally {
        $global:ProgressPreference = $savedProgress
    }
}

function Update-StashServerMarkerAddress {
    <#
    .SYNOPSIS
        Resolve the stash VM's current IPv4 and record it as `stashBaseUrl`
        (http://<ip>) in the stash-server.json marker, so the pool-aggregator
        can deep-link the Extension hosts cell to the stash VM's UI.
    .DESCRIPTION
        Best-effort and never throws -- telemetry must not fail a bring-up or a
        cycle. The stash VM's guest address is not known until the host's
        virtualization stack reports it (KVP / dhcpd_leases / utmctl), which can
        lag minutes after boot on a Hyper-V External vSwitch, so callers poll:
        pass a -TimeoutSeconds budget when the VM may have just started
        (Start-StashServer), or 0 for a single-shot refresh on an established VM
        (the per-cycle runner call). Resolution goes through the host contract
        Get-VMIp resolved at call time after Initialize-YurunaHost (the same
        late-bind the teardown helpers use); a host without it loaded is a no-op.
        The marker is rewritten only when the URL changes, atomic temp+rename so a
        polling aggregator never reads a torn file. Format-IpUrlHost brackets an
        IPv6 literal for the URL authority.
    .OUTPUTS
        System.String -- the resolved stash base URL, or $null when unresolved.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort single-file marker refresh; never throws, overwrite is idempotent.')]
    [OutputType([string])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$VMName,
        [int]$TimeoutSeconds = 0
    )
    try {
        if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
        $markerPath = Join-Path $RuntimeDir 'stash-server.json'
        if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json -ErrorAction Stop
        # A marker being torn down (active:false) must not be re-advertised.
        if ($null -ne $marker.active -and -not [bool]$marker.active) { return $null }
        if (-not $VMName) { $VMName = [string]$marker.vmName }
        if ([string]::IsNullOrWhiteSpace($VMName)) { return $null }
        if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return $null }

        $ip = $null
        $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
        while (-not $ip) {
            $candidate = $null
            try { $candidate = [string](Get-VMIp -VMName $VMName) }
            catch { Write-Verbose "Update-StashServerMarkerAddress: Get-VMIp '$VMName' failed: $($_.Exception.Message)" }
            if ($candidate -and (Test-IpAddress $candidate)) { $ip = $candidate }
            elseif ((Get-Date) -ge $deadline) { break }
            else { Start-Sleep -Seconds 3 }
        }
        if (-not $ip) { return $null }

        $url = "http://$(Format-IpUrlHost $ip)"
        if ([string]$marker.stashBaseUrl -eq $url) { return $url }

        # Preserve every existing marker field; set/replace stashBaseUrl only.
        $record = [ordered]@{}
        foreach ($prop in $marker.PSObject.Properties) { $record[$prop.Name] = $prop.Value }
        $record['stashBaseUrl'] = $url
        $tmp = "$markerPath.tmp"
        [System.IO.File]::WriteAllText($tmp, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $markerPath -Force -ErrorAction Stop
        return $url
    } catch {
        Write-Verbose "Update-StashServerMarkerAddress: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Wait-VMRunning, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Compare-Screenshot, Get-ScreenshotSchedule, Invoke-ScreenshotTest, Get-CachingProxyPort, Test-Ipv4Address, Test-Ipv6Address, Test-IpAddress, Format-IpUrlHost, ConvertTo-Sha512CryptHash, Remove-GuestVMQuietly, Update-StashServerMarkerAddress
