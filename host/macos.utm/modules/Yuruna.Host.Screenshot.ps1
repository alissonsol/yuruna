<#PSScriptInfo
.VERSION 2026.10.31
.GUID 420b2519-f223-4eaf-b727-e70a356793f1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver screenshot
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

# --- REGION: Screenshot helpers
# UTM-side screenshot capture: VNC framebuffer first (real pixels even when
# UTM's NSWindow stays black), then CGWindowList screencapture -l <id>,
# then bounds-based screencapture -R fallback. Per-VM VNC port (5910..5989)
# derived deterministically from the VM name so producer (config.plist
# template) and consumers (capture, keystrokes) agree without a sidecar.

function Get-VncDisplayForVm {
    <#
    .SYNOPSIS
        Return a deterministic VNC display number (10..89) from the VM name.
    #>
        [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Displays 0..9 reserved for legacy/default callers.
    $h = 0
    foreach ($ch in $VMName.ToCharArray()) {
        $h = (($h * 131) + [int][char]$ch) -band 0x3FFFFFFF
    }
    return ($h % 80) + 10
}

<#
.SYNOPSIS
    A bundle's config.plist as parsed JSON, read through one bounded plutil
    call; Readable is $false when the read did not complete or did not parse.
.DESCRIPTION
    plutil talks to nothing but the file, yet it is still a process that can
    stall on a wedged filesystem, and every caller of this sits on a path
    that must answer in seconds.
#>
function Read-UtmBundleConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        $Deadline
    )
    $read = Invoke-UtmHostTool -Tool 'plutil' -ArgumentList @('-convert', 'json', '-o', '-', $ConfigPath) -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline
    $json = $null
    if ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0 -and "$($read.StdOut)".Trim()) {
        try { $json = "$($read.StdOut)" | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    }
    return [pscustomobject]@{ Readable = [bool]($null -ne $json); Json = $json; Reason = $(if ($read.DeadlineExhausted) { 'deadline-exhausted' } elseif ($read.TimedOut) { 'timeout' } elseif ($null -ne $json) { 'read' } else { 'failed' }) }
}

<#
.SYNOPSIS
    Return the VNC display recorded in the VM bundle's config.plist, or -1
    when the bundle has no -vnc argument (or cannot be read).
.DESCRIPTION
    The bundle is the authority on which port a VM actually listens on:
    the display is written into QEMU's AdditionalArguments when the VM is
    built, and Start-UtmVM may rewrite it to avoid a collision. A caller
    that derived the port from the VM name instead would aim a screenshot
    at whatever else happens to hold that port.
#>
function Get-VncDisplayFromBundle {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return -1 }
    try {
        $config = Read-UtmBundleConfig -ConfigPath $configPath
        if (-not $config.Readable) { return -1 }
        $qemuArgs = @($config.Json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Value shape: 127.0.0.1:<display>[,share=force-shared]
            if ("$($qemuArgs[$i + 1])" -match ':(\d+)') { return [int]$Matches[1] }
        }
    } catch {
        Write-Debug "Get-VncDisplayFromBundle: could not read $configPath`: $($_.Exception.Message)"
    }
    return -1
}

<#
.SYNOPSIS
    Return a VM bundle's network descriptor -- plist path, network mode and
    MAC -- or $null when the host has no such bundle.
.DESCRIPTION
    The bundle is the authority on how a VM is attached and what MAC it
    boots with: both are fixed when it is BUILT, and the guest's seed
    carries addresses derived for them, so what the bundle says -- not what
    this host's uplink would choose today -- is what the running VM is
    actually on. Address discovery reads both together because it needs
    both to pick a rung, and one plutil invocation answers for the pair.
.PARAMETER TimeoutSeconds
    Cap for the plutil read.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] with VMName, PlistPath, Mode ('Bridged' / 'Shared' /
    '' when unreadable), MacAddress ('' when absent) and Readable ($false
    when the plist read did not complete), or $null.
#>
function Get-UtmBundleNetwork {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        $Deadline
    )
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $mode = ''
    $mac  = ''
    $config = Read-UtmBundleConfig -ConfigPath $configPath -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline
    if ($config.Readable) {
        try {
            $nic  = @($config.Json.Network)[0]
            $mode = "$($nic.Mode)".Trim()
            $mac  = "$($nic.MacAddress)".Trim()
        } catch {
            Write-Debug "Get-UtmBundleNetwork: could not read $configPath`: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        VMName     = $VMName
        PlistPath  = $configPath
        Mode       = $mode
        MacAddress = $mac
        Readable   = [bool]$config.Readable
    }
}

<#
.SYNOPSIS
    Return the network mode recorded in a VM bundle's config.plist
    ('Bridged' / 'Shared'), or '' when the bundle or the key is absent.
.DESCRIPTION
    A caller compares this against what the host's uplink would choose today
    to detect a host that has moved between Wi-Fi and Ethernet since the VM
    was created, and decides whether to forward host ports (Shared) or
    expect a LAN address (Bridged).
#>
function Get-UtmNetworkModeFromBundle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork) { return '' }
    return [string]$bundleNetwork.Mode
}

<#
.SYNOPSIS
    Write $Display into the VM bundle's -vnc QEMU argument. Returns $true
    when the bundle now carries that display.
#>
function Set-VncDisplayInBundle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$Display
    )
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_54d6a4d70cca189d' -Arguments @{ display = "$Display" }))) { return $false }
    try {
        $config = Read-UtmBundleConfig -ConfigPath $configPath
        if (-not $config.Readable) { return $false }
        $qemuArgs = @($config.Json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Preserve whatever suffix the builder attached (share=force-shared
            # lets the screenshot client attach while the console is open);
            # only the display number changes.
            $suffix = ''
            if ("$($qemuArgs[$i + 1])" -match ':\d+(,.*)$') { $suffix = $Matches[1] }
            $value = "127.0.0.1:${Display}${suffix}"
            $null = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :QEMU:AdditionalArguments:$($i + 1) $value", $configPath) -TimeoutSeconds 10
            return ((Get-VncDisplayFromBundle -VMName $VMName) -eq $Display)
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6877083d4624d081' -Arguments @{ configPath = "$configPath"; message = "$($_.Exception.Message)" })
    }
    return $false
}

<#
.SYNOPSIS
    Write the deterministic MAC for $VMName into that VM bundle's first NIC.
    Returns $true when the bundle now carries that address.
.DESCRIPTION
    See https://yuruna.link/4220a755-000a
    for the address itself. A bundle is normally written at BUILD time with the
    identity its guest keeps for life, and then this rewrite is never needed.
    It exists for the bundle written with the per-kind slot name instead (a
    guest whose sequence declares no hostname of its own): that address belongs
    to the slot, and a promoted bundle sitting on it leaves the next guest built
    under that name asking for one already in use. Rename-VM decides whether it
    applies -- moving a bundle that is already on its own identity re-DHCPs a
    guest whose state may record the address it was built on.

    UTM does not refuse the duplicate the way virt-install does: the VMs build
    and start, and the collision surfaces later as guests on one segment
    answering for each other's address, which reads as a network fault rather
    than a naming one. The bundle is also where the guest's DHCP identity ends
    up, because the seed pins dhcp-identifier to the MAC.

    Only the first NIC is rewritten -- a second interface needs a second
    DISTINCT address, not this one twice. -MacAddress writes a given address
    instead of the one $VMName derives: a rename that undoes an earlier one
    restores the address the bundle had under its old name.
#>
function Set-GuestMacInBundle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName, [string]$MacAddress = '')
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    $mac = if ($MacAddress) { $MacAddress.ToUpperInvariant() } else { Get-YurunaGuestMacAddress -VMName $VMName }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_05af7f58bfd72dce' -Arguments @{ mac = "$mac" }))) { return $false }
    try {
        $write = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Network:0:MacAddress $mac", $configPath) -TimeoutSeconds 10
        if (-not (Test-UtmBoundedResultComplete -Result $write) -or $write.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_19d6ab966bbc187c' -Arguments @{ configPath = "$configPath" })
            return $false
        }
        $written = (Get-UtmBundleNetwork -VMName $VMName).MacAddress
        return ($written -and $written -ieq $mac)
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0311eef6cb69b548' -Arguments @{ configPath = "$configPath"; message = "$($_.Exception.Message)" })
    }
    return $false
}

<#
.SYNOPSIS
    $true when nothing is listening on 127.0.0.1:$Port right now.
.DESCRIPTION
    A real bind, not a connect probe: QEMU fails to start when it cannot
    bind, and only a bind tells us whether it will be able to.
#>
function Test-VncPortFree {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { Write-Debug "Test-VncPortFree: listener stop on $Port`: $($_.Exception.Message)" } }
    }
}

<#
.SYNOPSIS
    Return a VNC display in 10..89 whose port is free, preferring $Preferred.
    Returns -1 when every display in the range is taken.
#>
function Find-FreeVncDisplay {
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Preferred = -1, [int[]]$ExcludeDisplays = @())
    # A bind test only sees VMs that are running RIGHT NOW. When the caller
    # is allocating for a fleet whose members are stopped -- or with UTM
    # quit entirely -- every port answers "free" and two VMs happily take
    # the same one. ExcludeDisplays carries the displays already spoken for
    # by other bundles so the choice holds once they all start.
    $excluded = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($d in $ExcludeDisplays) { $null = $excluded.Add([int]$d) }
    if ($Preferred -ge 10 -and $Preferred -le 89 -and
        -not $excluded.Contains($Preferred) -and (Test-VncPortFree -Port (5900 + $Preferred))) {
        return $Preferred
    }
    for ($d = 10; $d -le 89; $d++) {
        if (-not $excluded.Contains($d) -and (Test-VncPortFree -Port (5900 + $d))) { return $d }
    }
    return -1
}

<#
.SYNOPSIS
    Return the VNC displays recorded in every .utm bundle except $ExcludeVMName.
.DESCRIPTION
    The bundles on disk are the only durable record of which display each
    VM will ask QEMU for, so they are what a new allocation has to avoid.
#>
function Get-ClaimedVncDisplay {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([string]$ExcludeVMName)
    $guestDir = "$HOME/yuruna/guest.nosync"
    if (-not (Test-Path -LiteralPath $guestDir)) { return [int[]]@() }
    $displays = @()
    foreach ($bundle in (Get-ChildItem -LiteralPath $guestDir -Filter '*.utm' -Directory -ErrorAction SilentlyContinue)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($bundle.Name)
        if ($name -eq $ExcludeVMName) { continue }
        $display = Get-VncDisplayFromBundle -VMName $name
        if ($display -ge 0) { $displays += $display }
    }
    return [int[]]$displays
}

<#
.SYNOPSIS
    Return the VNC TCP port (5910..5989) for the given VM.
.DESCRIPTION
    The bundle's own -vnc argument wins: Start-UtmVM resolves the display
    at start time, so the name-derived value is only the seed, not the
    answer. Falling back to the hash keeps callers working for a VM that
    has no bundle on this host (or none yet).
#>
function Get-VncPortForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $fromBundle = Get-VncDisplayFromBundle -VMName $VMName
    if ($fromBundle -ge 0) { return 5900 + $fromBundle }
    return 5900 + (Get-VncDisplayForVm -VMName $VMName)
}

# C# helper for a hot byte-swap loop (BGRX framebuffer -> P6 PPM).
# Pure-PowerShell over a 1920x1080 buffer is multiple seconds; compiled
# version is tens of ms. Idempotent via type-presence check.
if (-not ('YurunaVncPixels' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class YurunaVncPixels {
    public static void BgrxToRgb(byte[] src, byte[] dst, int dstOffset) {
        int n = src.Length / 4;
        for (int i = 0; i < n; i++) {
            int s = i * 4;
            int d = dstOffset + i * 3;
            dst[d]     = src[s + 2]; // R
            dst[d + 1] = src[s + 1]; // G
            dst[d + 2] = src[s];     // B
        }
    }
}
'@
}

<#
.SYNOPSIS
    Read exactly $Count bytes from $Stream into a fresh byte[]. Uses
    Stream.ReadExactly (.NET 7+) so the read loop runs inside the runtime
    instead of being driven from PowerShell -- measured against a 1920x1080
    QEMU VNC capture (7.9 MB payload), the runtime-side loop completes
    in ~150 ms while the PowerShell-side equivalent took ~10.6 s because
    QEMU's RFB encoder emits the pixel rect in many small frames and
    every PowerShell loop iteration paid scriptblock-invocation overhead.
.NOTES
    Stream.ReadExactly throws EndOfStreamException on premature EOF; we
    wrap that to match the previous error-message style for log parity.
#>
function Read-VncScreenshotBuffer {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buf = [byte[]]::new($Count)
    try {
        $Stream.ReadExactly($buf, 0, $Count)
    } catch [System.IO.EndOfStreamException] {
        throw "VNC connection closed before $Count bytes were read"
    }
    return $buf
}

<#
.SYNOPSIS
    Capture a VNC framebuffer to PNG via raw RFB 3.8 protocol.
#>
function Get-VncScreenshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$OutputPath,
        [int]$Port = 5900,
        [int]$TimeoutMs = 5000
    )
    $tcp = $null
    $ppmPath = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect('127.0.0.1', $Port)
        $stream = $tcp.GetStream()
        # RFB 3.8 handshake
        $null = Read-VncScreenshotBuffer -Stream $stream -Count 12
        $stream.Write([System.Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"), 0, 12)
        $countBuf = Read-VncScreenshotBuffer -Stream $stream -Count 1
        $numTypes = [int]$countBuf[0]
        if ($numTypes -eq 0) { throw 'VNC server refused (0 security types offered)' }
        $typesBuf = Read-VncScreenshotBuffer -Stream $stream -Count $numTypes
        if ($typesBuf -notcontains 1) { throw "VNC server does not offer None-auth (got: $($typesBuf -join ','))" }
        $stream.WriteByte(1)
        $secResult = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($secResult[0] -ne 0 -or $secResult[1] -ne 0 -or $secResult[2] -ne 0 -or $secResult[3] -ne 0) {
            throw "VNC security handshake failed"
        }
        $stream.WriteByte(1) # ClientInit shared=1
        $initBuf = Read-VncScreenshotBuffer -Stream $stream -Count 24
        $w = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[1], $initBuf[0]), 0)
        $h = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[3], $initBuf[2]), 0)
        $nameLen = [int][BitConverter]::ToInt32([byte[]]@($initBuf[23], $initBuf[22], $initBuf[21], $initBuf[20]), 0)
        $bpp = [int]$initBuf[4]
        $bigEndian = [int]$initBuf[6]
        if ($nameLen -gt 0) { $null = Read-VncScreenshotBuffer -Stream $stream -Count $nameLen }
        if ($bpp -ne 32)    { throw "Unsupported bpp=$bpp (this capture path assumes 32bpp BGRX)" }
        if ($bigEndian -ne 0) { throw "Unsupported big-endian framebuffer (this path assumes little-endian BGRX)" }
        $req = [byte[]]::new(10)
        $req[0] = 3
        $req[1] = 0
        $req[6] = [byte](($w -shr 8) -band 0xFF); $req[7] = [byte]($w -band 0xFF)
        $req[8] = [byte](($h -shr 8) -band 0xFF); $req[9] = [byte]($h -band 0xFF)
        $stream.Write($req, 0, 10)
        $updHdr = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($updHdr[0] -ne 0) { throw "Expected FramebufferUpdate (0), got message type $($updHdr[0])" }
        $nRects = [int][BitConverter]::ToUInt16([byte[]]@($updHdr[3], $updHdr[2]), 0)
        $fbBytes = $w * $h * 4
        $fb = [byte[]]::new($fbBytes)
        for ($r = 0; $r -lt $nRects; $r++) {
            $rectHdr = Read-VncScreenshotBuffer -Stream $stream -Count 12
            $rx = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[1],  $rectHdr[0]),  0)
            $ry = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[3],  $rectHdr[2]),  0)
            $rw = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[5],  $rectHdr[4]),  0)
            $rh = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[7],  $rectHdr[6]),  0)
            $enc = [BitConverter]::ToInt32([byte[]]@($rectHdr[11], $rectHdr[10], $rectHdr[9], $rectHdr[8]), 0)
            if ($enc -ne 0) { throw "Unsupported VNC encoding $enc for rect $r (need Raw=0)" }
            $rectBytes = $rw * $rh * 4
            if ($rx -eq 0 -and $ry -eq 0 -and $rw -eq $w -and $rh -eq $h) {
                # See https://yuruna.link/42e5cdfd-0005
                $stream.ReadExactly($fb, 0, $rectBytes)
            } else {
                # Sub-rect (would occur if we ever sent incremental=1):
                # the row-by-row PowerShell copy is still slow but
                # tolerable because the sub-rect is small. Kept as
                # fallback so the function remains correct under
                # encodings that emit multiple rects.
                $pixels = Read-VncScreenshotBuffer -Stream $stream -Count $rectBytes
                for ($row = 0; $row -lt $rh; $row++) {
                    $srcOff = $row * $rw * 4
                    $dstOff = (($ry + $row) * $w + $rx) * 4
                    [Array]::Copy($pixels, $srcOff, $fb, $dstOff, $rw * 4)
                }
            }
        }
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("P6`n$w $h`n255`n")
        $ppm = [byte[]]::new($headerBytes.Length + $w * $h * 3)
        [Array]::Copy($headerBytes, 0, $ppm, 0, $headerBytes.Length)
        [YurunaVncPixels]::BgrxToRgb($fb, $ppm, $headerBytes.Length)
        $ppmPath = "$OutputPath.ppm"
        [System.IO.File]::WriteAllBytes($ppmPath, $ppm)
        $sipsErr = & sips -s format png $ppmPath --out $OutputPath 2>&1
        if (-not (Test-Path $OutputPath)) {
            Write-Debug "      VNC capture: sips conversion failed: $sipsErr"
            return $false
        }
        return $true
    } catch {
        Write-Debug "      VNC capture failed: $_"
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { Write-Debug "      VNC capture: tcp.Close() failed: $_" } }
        if ($ppmPath -and (Test-Path $ppmPath)) {
            Remove-Item -LiteralPath $ppmPath -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Capture the UTM VM's display (VNC then screencapture fallbacks).
#>
function Get-UtmWindowGeometry {
    <#
    .SYNOPSIS
        Resolves a VM window ID and geometry with bounded macOS automation.
    .PARAMETER VMName
        The literal window name to match.
    .PARAMETER AccessibilityOnly
        Request content bounds after a CG window capture did not work.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$VMName, [switch]$AccessibilityOnly)
    $safeVMName = ConvertTo-Json -InputObject $VMName -Compress
    $windowScript = @"
ObjC.import('CoreGraphics');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = __VMNAME__;
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        var id = ObjC.unwrap(w.kCGWindowNumber);
        var b  = ObjC.unwrap(w.kCGWindowBounds);
        result = '' + id + ',' + b.X + ',' + b.Y + ',' + b.Width + ',' + b.Height;
        break;
    }
}
result;
"@
    $windowScript = $windowScript.Replace('__VMNAME__', $safeVMName)
    $probe = if ($AccessibilityOnly) { $null } else { Invoke-UtmHostTool -Tool 'osascript' -ArgumentList @('-l', 'JavaScript', '-e', $windowScript) -TimeoutSeconds 10 }
    $windowResult = if ($probe) { $probe.StdOut.Trim() } else { '' }
    Write-Debug "      CG window query (window+bounds): $windowResult"
    $windowId = 0
    $originX  = 0.0
    $originY  = 0.0
    $pointW   = 0.0
    $pointH   = 0.0
    $cgOk     = $false
    if ($probe -and (Test-BoundedNativeResultComplete -Result $probe) -and $probe.ExitCode -eq 0 -and "$windowResult" -match '^\d+,-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
        $parts    = "$windowResult".Split(',')
        $windowId = [int]$parts[0]
        $originX  = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
        $originY  = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
        $pointW   = [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        $pointH   = [double]::Parse($parts[4], [Globalization.CultureInfo]::InvariantCulture)
        $cgOk     = $true
    } else {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $probe = Invoke-UtmHostTool -Tool 'osascript' -ArgumentList @('-e', $boundsScript) -TimeoutSeconds 10
        $boundsResult = $probe.StdOut.Trim()
        Write-Debug "      Window bounds query (fallback): $boundsResult"
        if ((Test-BoundedNativeResultComplete -Result $probe) -and $probe.ExitCode -eq 0 -and "$boundsResult" -match '^-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
            $parts   = "$boundsResult".Split(',')
            $originX = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
            $originY = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
            $pointW  = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
            $pointH  = [double]::Parse($parts[3], [Globalization.CultureInfo]::InvariantCulture)
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4ec0afe642270f86' -Arguments @{ vMName = "$VMName"; windowResult = "$windowResult"; boundsResult = "$boundsResult" })
            return $null
        }
    }
    return @{ WindowId = $windowId; OriginX = $originX; OriginY = $originY; PointWidth = $pointW; PointHeight = $pointH; CG = $cgOk }
}

function Get-UtmScreenshot {
    <# .SYNOPSIS
        Captures a UTM console through VNC or shared macOS window geometry.
    .PARAMETER VMName
        The VM to capture.
    .PARAMETER OutputPath
        Destination PNG path.
    #>
    param([string]$VMName, [string]$OutputPath)
    $vncPort = Get-VncPortForVm -VMName $VMName
    if (Get-VncScreenshot -OutputPath $OutputPath -Port $vncPort) {
        Write-Debug "      Captured via VNC (port $vncPort, VM $VMName)"
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    if (-not $script:ScreencaptureChecked) {
        $script:ScreencaptureChecked = $true
        $testFile = Join-Path ([System.IO.Path]::GetTempPath()) "screencapture_test_$PID.png"
        $testErr = & screencapture -x "$testFile" 2>&1
        if (Test-Path $testFile) {
            $fileSize = (Get-Item $testFile).Length
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            if ($fileSize -lt 100) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_63d92a5157f8b436')
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_baea4919b222d9c9')
                $script:ScreencaptureWorks = $false
            } else {
                $script:ScreencaptureWorks = $true
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0b1218dff32f3243' -Arguments @{ testErr = "$testErr" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2401d57af4c6cd28')
            $script:ScreencaptureWorks = $false
        }
    }
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $geometry = Get-UtmWindowGeometry -VMName $VMName
    $windowIdResult = if ($geometry) { [string]$geometry.WindowId } else { '' }
    $captured = $false
    if ($geometry.CG -and "$windowIdResult" -match '^\d+$') {
        $captureErr = & screencapture -x -o -l "$windowIdResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $fileSize = (Get-Item $OutputPath).Length
            if ($fileSize -gt 100) {
                $captured = $true
            } else {
                Write-Debug "      screencapture -l produced small file ($fileSize bytes), trying -R fallback"
                Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Debug "      screencapture -l failed: $captureErr"
        }
    }
    if (-not $captured) {
        $bounds = Get-UtmWindowGeometry -VMName $VMName -AccessibilityOnly
        $boundsResult = if ($bounds) { '{0},{1},{2},{3}' -f $bounds.OriginX, $bounds.OriginY, $bounds.PointWidth, $bounds.PointHeight } else { '' }
        Write-Debug "      Window bounds query: $boundsResult"
        if ($bounds -and $bounds.PointWidth -gt 0 -and $bounds.PointHeight -gt 0) {
            $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
            if (Test-Path $OutputPath) {
                $captured = $true
                Write-Debug "      Captured via -R (window may include overlapping content)"
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_52bc6c4a54214905' -Arguments @{ boundsResult = "$boundsResult"; captureErr = "$captureErr" })
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_663cbbf805c2b958' -Arguments @{ vMName = "$VMName"; windowIdResult = "$windowIdResult"; boundsResult = "$boundsResult" })
        }
    }
    if ($captured) {
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_46fe17589543a111' -Arguments @{ vMName = "$VMName" })
    return $null
}

<#
.SYNOPSIS
    Capture the UTM window with metadata (id, origin, scale) for clicks.
#>
function Get-UtmWindowScreenshot {
    param([string]$VMName, [string]$OutputPath)
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $geometry = Get-UtmWindowGeometry -VMName $VMName
    if (-not $geometry) { return $null }
    $windowId = $geometry.WindowId; $originX = $geometry.OriginX; $originY = $geometry.OriginY
    $pointW = $geometry.PointWidth; $pointH = $geometry.PointHeight; $cgOk = $geometry.CG
    if ($cgOk) {
        $captureErr = & screencapture -x -o -l "$windowId" "$OutputPath" 2>&1
    } else {
        $region = "{0},{1},{2},{3}" -f $originX, $originY, $pointW, $pointH
        $captureErr = & screencapture -x -R "$region" "$OutputPath" 2>&1
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d8b4fab086012607' -Arguments @{ vMName = "$VMName"; captureErr = "$captureErr" })
        return $null
    }
    $fileSize = (Get-Item $OutputPath).Length
    if ($fileSize -lt 100) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_88b70a1a42a7df41' -Arguments @{ fileSize = "${fileSize}" })
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $fs = [IO.File]::OpenRead($OutputPath)
        try {
            $buf = New-Object byte[] 24
            [void]$fs.Read($buf, 0, 24)
        } finally { $fs.Dispose() }
        $pixelW = ([int]$buf[16] -shl 24) -bor ([int]$buf[17] -shl 16) -bor ([int]$buf[18] -shl 8) -bor [int]$buf[19]
        $pixelH = ([int]$buf[20] -shl 24) -bor ([int]$buf[21] -shl 16) -bor ([int]$buf[22] -shl 8) -bor [int]$buf[23]
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6f6bbc018b383fb2' -Arguments @{ outputPath = "$OutputPath"; value = "$_" })
        return $null
    }
    $scale = if ($pointW -gt 0) { $pixelW / $pointW } else { 1.0 }
    Write-Debug "      UTM window: id=$windowId origin=($originX,$originY) point=${pointW}x${pointH} pixel=${pixelW}x${pixelH} scale=$scale"
    return @{
        ImagePath   = $OutputPath
        WindowId    = $windowId
        OriginX     = $originX
        OriginY     = $originY
        Width       = $pixelW
        Height      = $pixelH
        PointWidth  = $pointW
        PointHeight = $pointH
        Scale       = $scale
    }
}
