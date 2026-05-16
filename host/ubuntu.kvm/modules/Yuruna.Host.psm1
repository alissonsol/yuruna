<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e8f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host kvm libvirt
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for Ubuntu KVM/libvirt hosts. Implements the
    contract documented at the top of host/macos.utm/modules/Yuruna.Host.psm1.
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for Ubuntu KVM/libvirt hosts.

.DESCRIPTION
    Drives guest VMs on a Linux host running libvirt + KVM. Sibling
    implementations live at host/macos.utm/modules/Yuruna.Host.psm1
    (macOS UTM) and host/windows.hyper-v/modules/Yuruna.Host.psm1
    (Windows Hyper-V). Same 38-function contract on all three; the
    test harness is host-agnostic.

    All libvirt calls go through `qemu:///system` (the system
    daemon, libvirtd). The user is expected to be in the `libvirt`
    group so virsh / virt-install run without sudo for VM ops; some
    operations (apt, /etc/environment, systemctl) call sudo
    explicitly.
#>

# === Module setup ===========================================================

$script:HostTag        = 'host.ubuntu.kvm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/ubuntu.kvm'
$script:VirshUri       = 'qemu:///system'
$script:VmRootDir      = Join-Path $HOME 'yuruna/vms'
$script:PortMapDir     = Join-Path $HOME 'yuruna/portmap'

Import-Module (Join-Path $script:TestModulesDir 'Test.VM.common.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxy.psm1') -Force -DisableNameChecking

# Per-guest base image paths -- single table keeps Get-ImagePath, Get-Image,
# and the per-guest Get-Image.ps1 scripts in agreement. A typo or new guest
# fails loud here instead of silently composing the wrong path.
$script:ImagePathTable = @{
    'guest.amazon.linux'  = "$HOME/yuruna/image/amazon.linux/host.ubuntu.kvm.guest.amazon.linux.qcow2"
    'guest.ubuntu.server' = "$HOME/yuruna/image/ubuntu.env/host.ubuntu.kvm.guest.ubuntu.server.iso"
    'guest.windows.11'    = "$HOME/yuruna/image/windows.11/host.ubuntu.kvm.guest.windows.11.iso"
}

# === Private helpers ========================================================

<#
.SYNOPSIS
    Run virsh and return its stdout/stderr lines as an array; never throws.
#>
function Invoke-Virsh {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([Parameter(Mandatory)][string[]]$VirshArgs)
    $output = & virsh --connect $script:VirshUri @VirshArgs 2>&1
    if (-not $output) { return @() }
    return @($output | ForEach-Object { "$_" })
}

<#
.SYNOPSIS
    Returns the libvirt domstate string for a VM, or '' on lookup failure.
#>
function Get-VirshDomState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $lines = Invoke-Virsh -VirshArgs @('domstate', $VMName)
    if ($LASTEXITCODE -ne 0) { return '' }
    $first = ($lines | Where-Object { "$_" -ne '' } | Select-Object -First 1)
    return "$first".Trim()
}

# === VM lifecycle ===========================================================

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyUrl
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create VM ($GuestKey)")) {
        return @{ success = $false; errorMessage = 'WhatIf' }
    }
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host/ubuntu.kvm' (Join-Path $GuestKey 'New-VM.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; errorMessage = "New-VM.ps1 not found at: $scriptPath" }
    }
    $childArgs = @('-VMName', $VMName)
    $scriptAcceptsProxy = $false
    try {
        $cmdInfo = Get-Command -Name $scriptPath -ErrorAction Stop
        $scriptAcceptsProxy = [bool]($cmdInfo.Parameters -and $cmdInfo.Parameters.ContainsKey('CachingProxyUrl'))
    } catch {
        $scriptAcceptsProxy = $false
    }
    if ($PSBoundParameters.ContainsKey('CachingProxyUrl') -and $scriptAcceptsProxy) {
        $childArgs += @('-CachingProxyUrl', $CachingProxyUrl)
        Write-Verbose "Running: $scriptPath -VMName $VMName -CachingProxyUrl '$CachingProxyUrl'"
    } else {
        Write-Verbose "Running: $scriptPath -VMName $VMName"
    }
    $output = & pwsh -NoProfile -File $scriptPath @childArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Information $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success = $false; errorMessage = "New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success = $true; errorMessage = $null }
}

<#
.SYNOPSIS
    Start a guest VM previously created by New-VM.
#>
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Start VM')) {
        return @{ success = $false; errorMessage = 'WhatIf' }
    }
    # Idempotent: a VM already running is success.
    $state = Get-VirshDomState -VMName $VMName
    if ($state -eq 'running') {
        return @{ success = $true; errorMessage = $null; alreadyRunning = $true }
    }
    if (-not $state) {
        return @{ success = $false; errorMessage = "VM '$VMName' is not defined to libvirt." }
    }
    $output = Invoke-Virsh -VirshArgs @('start', $VMName)
    if ($LASTEXITCODE -ne 0) {
        return @{ success = $false; errorMessage = "virsh start failed: $($output -join '; ')" }
    }
    return @{ success = $true; errorMessage = $null }
}

<#
.SYNOPSIS
    Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
#>
function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop VM')) { return $false }
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state -or $state -eq 'shut off') { return $true }   # already stopped
    if ($Force.IsPresent) { return [bool](Stop-VMForce -VMName $VMName -Confirm:$false) }
    Invoke-Virsh -VirshArgs @('shutdown', $VMName) | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    # virsh shutdown is asynchronous (ACPI shutdown signal); poll up to ~30s
    # for the OS to follow through.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VirshDomState -VMName $VMName) -in @('shut off', '')) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

<#
.SYNOPSIS
    Force-stop a guest VM via virsh destroy, escalating to a qemu pid kill when destroy fails.
#>
function Stop-VMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Force-stop VM (virsh destroy)')) { return $false }
    Invoke-Virsh -VirshArgs @('destroy', $VMName) | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # Last-resort escalation: find the qemu pid via libvirt's pidfile.
    # /var/run/libvirt/qemu/<vm>.pid is the canonical location on Ubuntu.
    $pidFile = "/var/run/libvirt/qemu/$VMName.pid"
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $qpid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
            if ($qpid -gt 0) {
                # Absolute path makes this unambiguously the Linux 'kill'
                # binary, not PowerShell's Stop-Process alias.
                & sudo /bin/kill -9 $qpid 2>$null | Out-Null
                Start-Sleep -Seconds 1
                $deadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
                while ((Get-Date) -lt $deadline) {
                    if ((Get-VirshDomState -VMName $VMName) -in @('shut off', '')) { return $true }
                    Start-Sleep -Seconds 1
                }
            }
        } catch {
            Write-Warning "Stop-VMForce: kill of pid in $pidFile failed: $($_.Exception.Message)"
        }
    }
    return $false
}

<#
.SYNOPSIS
    Remove a guest VM and its on-disk artifacts.
#>
function Remove-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }

    # Force-stop first; ignore errors (VM may be absent or already stopped).
    Invoke-Virsh -VirshArgs @('destroy', $VMName) | Out-Null

    # --- See https://yuruna.link/memory#why-remove-vm-on-kvm-omits-remove-all-storage
    Invoke-Virsh -VirshArgs @('undefine', '--nvram', $VMName) | Out-Null

    # Per-VM artifact directory (qcow2, seed.iso, autounattend.iso, nvram).
    # New-VM.ps1 places everything under ~/yuruna/vms/<vmname>/. This is
    # what actually deletes the per-VM disk; the virsh undefine above
    # only drops the libvirt domain definition + tracked NVRAM file.
    $vmDir = Join-Path $script:VmRootDir $VMName
    if (Test-Path -LiteralPath $vmDir) {
        try { Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Remove-VM: could not delete '$vmDir' ($($_.Exception.Message))." }
    }
    return $true
}

<#
.SYNOPSIS
    Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
#>
function Get-VMState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) { return 'absent' }
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state) { return 'absent' }
    switch -Regex ($state) {
        '^running$'                 { return 'running' }
        '^(shut off|crashed)$'      { return 'stopped' }
        '^(paused|in shutdown)$'    { return 'stopped' }
        '^(idle|pmsuspended)$'      { return 'stopped' }
        default                     { return 'unknown' }
    }
}

<#
.SYNOPSIS
    Returns true when a console window is open for the given VM.
#>
function Test-VMConsoleOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    # virt-viewer / remote-viewer are the canonical console clients on
    # Linux. pgrep -f matches the VMName argument that virt-viewer
    # carries on its command line.
    if (-not (Get-Command pgrep -ErrorAction SilentlyContinue)) { return $false }
    $hits = & pgrep -f "(virt-viewer|remote-viewer).*$([regex]::Escape($VMName))" 2>$null
    return ($LASTEXITCODE -eq 0 -and "$hits".Trim() -ne '')
}

<#
.SYNOPSIS
    Refresh or re-open the host-side console window for the given VM.
.DESCRIPTION
    Mirrors the Hyper-V `Restart-HyperVConnect` behaviour: kill any
    existing viewer for THIS VM, then launch a fresh one. The operator
    sees a console window for every guest under test, same as on
    Hyper-V's vmconnect and on macOS UTM's display window.

    Detachment: a naive `Start-Process virt-viewer` inherits the parent
    pwsh's stdout/stderr FDs, so the test harness's upstream
    `ForEach-Object` pipe never EOFs after the sequence parent exits and
    the harness hangs indefinitely after "Sequence complete." We invoke
    virt-viewer through `setsid -f` with </dev/null >/dev/null 2>&1 so
    the child runs in its own session with no inherited stdio FDs --
    closing the harness's pipe behaves the same as on the other hosts.

    GDK_BACKEND=x11: forces virt-viewer (a GTK app) to use the X11
    backend even on Wayland sessions, so it goes through XWayland and
    grabs the keyboard via the legacy XGrabKeyboard API instead of the
    Wayland xdg-desktop-portal Inhibit interface. The portal path
    triggers GNOME's "Allow inhibiting shortcuts? [Allow] [Deny]" modal
    on every fresh viewer launch -- which would block the test runner
    every cycle. XWayland keyboard grab is silent, has no side effects
    on the rest of the desktop session, and the per-process env var
    leaves other GTK apps on the host untouched.
#>
function Restart-VMConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Restart console window')) { return $false }
    if (-not (Get-Command virt-viewer -ErrorAction SilentlyContinue)) {
        Write-Verbose "Restart-VMConsole: virt-viewer not installed; skipping."
        return $false
    }
    & pkill -f "virt-viewer.*$([regex]::Escape($VMName))" 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    & bash -c "setsid -f env GDK_BACKEND=x11 virt-viewer --connect '$($script:VirshUri)' '$VMName' </dev/null >/dev/null 2>&1" 2>$null
    Write-Verbose "    Reconnected virt-viewer for '$VMName'"
    return $true
}

# === Image ==================================================================

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($GuestKey, 'Download / refresh base image')) {
        return @{ success = $false; skipped = $false; errorMessage = 'WhatIf' }
    }
    $scriptPath = Join-Path $RepoRoot (Join-Path 'host/ubuntu.kvm' (Join-Path $GuestKey 'Get-Image.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 not found at: $scriptPath" }
    }
    if (-not $Force) {
        $imagePath = Get-ImagePath -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            Write-Information "Image exists, skipping download: $imagePath"
            return @{ success = $true; skipped = $true; errorMessage = $null }
        }
    }
    Write-Information "Running: $scriptPath"
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object { Write-Information ([string]$_) }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 exited with code $code" }
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

<#
.SYNOPSIS
    Return the expected on-disk path of the base image for a guest.
#>
function Get-ImagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    return $script:ImagePathTable[$GuestKey]
}

# === VM I/O =================================================================

<#
.SYNOPSIS
    Type text into the guest VM via gui or ssh mechanism.
#>
function Send-Text {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui',
        # Required when -Mechanism ssh: maps to the SSH login user via
        # Test.Ssh\Get-GuestSshUser (per-guest test user, ec2-user, root, ...).
        [string]$GuestKey,
        [int]$CharDelayMs = 30,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; current paths
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honour it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on KVM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; .success is the right
        # bool to surface -- the prior `[bool]<hashtable>` cast always
        # returned $true because a non-null hashtable is truthy.
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: defer to Invoke-Sequence's host-aware dispatcher (same pattern
    # as the macOS impl). Sequence-driven runs go through there; manual
    # Send-Text calls should usually use -Mechanism ssh on Linux guests.
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        Import-Module $invokeSequence -Force -DisableNameChecking
        return [bool](Invoke-Sequence\Send-Text -HostType $script:HostTag -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a named key to the guest VM via gui or ssh mechanism.
#>
function Send-Key {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning "Send-Key -Mechanism ssh: not meaningful for SSH (use Send-Text with the typed command)."
        return $false
    }
    # `virsh send-key` accepts Linux input event names (KEY_ENTER, KEY_TAB,
    # KEY_LEFTMETA, ...) and QEMU keycodes. Map the few names the harness
    # actually emits to KEY_*; pass anything else through verbatim so an
    # operator can use the underlying kernel name directly.
    $map = @{
        'Enter'     = 'KEY_ENTER'
        'Return'    = 'KEY_ENTER'
        'Tab'       = 'KEY_TAB'
        'Escape'    = 'KEY_ESC'
        'Esc'       = 'KEY_ESC'
        'Space'     = 'KEY_SPACE'
        'Backspace' = 'KEY_BACKSPACE'
        'Up'        = 'KEY_UP'
        'Down'      = 'KEY_DOWN'
        'Left'      = 'KEY_LEFT'
        'Right'     = 'KEY_RIGHT'
    }
    $code = $map[$Key]
    if (-not $code) { $code = $Key }   # pass-through
    Invoke-Virsh -VirshArgs @('send-key', $VMName, $code) | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Send a mouse click at the given pixel coordinate.
#>
function Send-Click {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Write-Warning "Send-Click on host.ubuntu.kvm: not implemented (Hyper-V-only today). Use SSH-mode workloads on KVM. (vm='$VMName' ignored x=$X y=$Y)"
    return $false
}

<#
.SYNOPSIS
    Capture a PNG of the VM display from frame or window source.
#>
function Get-VMScreenshot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    # KVM only exposes the guest framebuffer (virsh screenshot); the
    # window-vs-frame distinction maps to the same op here. Document the
    # collapse in the debug stream so a 'window' caller can see why it
    # got a frame.
    if ($Source -eq 'window') {
        Write-Debug "Get-VMScreenshot on host.ubuntu.kvm: -Source 'window' falls back to framebuffer capture."
    }
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    # virsh screenshot writes PPM by default; convert to PNG via
    # ImageMagick (`convert`) if available, else netpbm (`pamtopng`),
    # else write the PPM next to the requested .png path with a warning.
    $ppm = [System.IO.Path]::ChangeExtension($OutFile, '.ppm')
    Invoke-Virsh -VirshArgs @('screenshot', $VMName, $ppm) | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ppm)) {
        Write-Warning "Get-VMScreenshot: virsh screenshot failed for '$VMName'."
        return $null
    }
    if (Get-Command convert -ErrorAction SilentlyContinue) {
        & convert $ppm $OutFile 2>$null | Out-Null
    } elseif (Get-Command pamtopng -ErrorAction SilentlyContinue) {
        & pamtopng $ppm > $OutFile 2>$null
    } else {
        Write-Warning "Get-VMScreenshot: neither 'convert' (imagemagick) nor 'pamtopng' (netpbm) found; leaving raw PPM at $ppm."
        return $ppm
    }
    Remove-Item -LiteralPath $ppm -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutFile) { return $OutFile }
    return $null
}

<#
.SYNOPSIS
    Return a host-specific handle for the VM console window.
#>
function Get-VMConsoleHandle {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Return the libvirt-managed qemu pid as a stable handle. Callers
    # use this only as an opaque identity check; not as something
    # they pass to a Win32 API.
    $pidFile = "/var/run/libvirt/qemu/$VMName.pid"
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $qpid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
            if ($qpid -gt 0) { return $qpid }
        } catch { Write-Debug $_ }
    }
    return $null
}

# === Discovery ==============================================================

<#
.SYNOPSIS
    Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
#>
function Wait-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-VMIp -VMName $VMName
        if ($candidate) { return [string]$candidate }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # `virsh domifaddr` queries libvirt's lease database (dnsmasq for the
    # 'default' network). Three sources to try, in order of reliability:
    #   1) lease  -- the default; works for libvirt-managed networks
    #   2) agent  -- needs qemu-guest-agent installed in the guest
    #   3) arp    -- last resort; passive ARP cache scan
    # Two-pass per source: prefer routable v4, fall back to routable v6.
    # Downstream Add-PortMap uses pwsh forwarders that today bind v4
    # sockets, so v4 stays preferred; v6 is returned only when no v4 is
    # available so v6-only guests don't surface as $null.
    foreach ($source in @('lease', 'agent', 'arp')) {
        $lines = Invoke-Virsh -VirshArgs @('domifaddr', $VMName, '--source', $source)
        if ($LASTEXITCODE -ne 0) { continue }
        # Output rows look like:
        #   vnet0      52:54:00:1a:b2:c3    ipv4         192.168.122.42/24
        #   vnet0      52:54:00:1a:b2:c3    ipv6         2001:db8::1234/64
        foreach ($l in $lines) {
            if ($l -match '^\s*\S+\s+\S+\s+ipv4\s+(\d+\.\d+\.\d+\.\d+)/\d+') {
                $ip = $Matches[1]
                if ((Test-Ipv4Address $ip) -and ($ip -notmatch '^(127\.|169\.254\.)')) { return $ip }
            }
        }
        foreach ($l in $lines) {
            if ($l -match '^\s*\S+\s+\S+\s+ipv6\s+([0-9A-Fa-f:]+)/\d+') {
                $ip = $Matches[1]
                if ((Test-Ipv6Address $ip) -and ($ip -inotmatch '^(::1$|fe80:)')) { return $ip }
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0 -or -not $xml) { return $null }
    $joined = [string]::Join("`n", $xml)
    # First <interface ...><mac address='xx:xx:..'/> wins -- harness VMs
    # have a single NIC by convention.
    if ($joined -match "<mac\s+address='([0-9a-fA-F:]{17})'") {
        return $Matches[1].ToLower()
    }
    return $null
}

# === Networking =============================================================

<#
.SYNOPSIS
    Return the name of the host-side External-type vSwitch or network.
#>
function Get-ExternalNetwork {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # libvirt convention: a bridged 'external' network ($env:YURUNA_EXTERNAL_NETWORK
    # or 'yuruna-external' if defined) is preferred when present; otherwise
    # fall back to the built-in NAT 'default' network. Callers compare the
    # returned name to the cache VM's interface in Test-CacheVMOnExternalNetwork.
    $candidates = @()
    if ($Env:YURUNA_EXTERNAL_NETWORK) { $candidates += $Env:YURUNA_EXTERNAL_NETWORK }
    $candidates += @('yuruna-external', 'default')
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    foreach ($c in $candidates) {
        if ($defined -contains $c) { return $c }
    }
    return 'default'
}

<#
.SYNOPSIS
    Create the host-side External-type vSwitch or network if missing.
#>
function New-ExternalNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess('libvirt default network', 'Ensure default network is up + autostart')) { return $null }
    # libvirt's default network ships with the daemon; nothing to create
    # here -- just ensure it's started and on autostart so guests find it.
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if (-not ($running -contains 'default')) {
        Invoke-Virsh -VirshArgs @('net-start', 'default') | Out-Null
    }
    Invoke-Virsh -VirshArgs @('net-autostart', 'default') | Out-Null
    return 'default'
}

# -- helpers for New-YurunaExternalNetwork -----------------------------------
# Internal. Returns the interface name carrying the default IPv4 route, or
# $null if none. Filters out the NIC if it's already a bridge port whose
# master is the one we're about to (re-)create; matches "what's the WAN-
# facing physical NIC of this host" semantically.
function Get-YurunaDefaultRouteIface {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $jsonLines = & ip -j -4 route show default 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $jsonLines) { return $null }
    try {
        $routes = ($jsonLines -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
    $first = @($routes) | Where-Object { $_.dev } | Select-Object -First 1
    if (-not $first) { return $null }
    return [string]$first.dev
}

# Internal. True iff $Iface is a wireless (802.11) interface. The kernel
# exposes /sys/class/net/<iface>/wireless for Wi-Fi NICs; the presence
# of the directory is a stable signal across drivers.
function Test-YurunaIfaceIsWifi {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Iface)
    return (Test-Path "/sys/class/net/$Iface/wireless")
}

# Internal. If $Iface is already a slave of a Linux bridge, return the
# bridge name; otherwise $null. /sys/class/net/<iface>/master is the
# canonical kernel pointer for bridge membership.
function Get-YurunaIfaceBridgeMaster {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    $masterLink = "/sys/class/net/$Iface/master"
    if (-not (Test-Path $masterLink)) { return $null }
    $target = & readlink -f $masterLink 2>$null
    if (-not $target) { return $null }
    $candidate = Split-Path -Leaf $target
    # Confirm it actually IS a bridge (vs other master types like bond).
    if (Test-Path "/sys/class/net/$candidate/bridge") { return $candidate }
    return $null
}

# Internal. True iff NetworkManager is installed AND running. Two checks
# rather than one: `command -v nmcli` can be present without NM active
# (the binary survives an `apt purge network-manager-runtime`), and a
# running NM is what we need to actually create+activate the bridge.
function Test-YurunaNetworkManagerActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $false }
    $state = & nmcli -t -f RUNNING general 2>$null
    return ("$state".Trim() -eq 'running')
}

function Test-NetworkManagerCrashedRecently {
    <#
    .SYNOPSIS
        Returns $true if NetworkManager core-dumped within the last
        $WithinMinutes minutes. Read-only -- queries the systemd journal
        only (no sudo; journal read works for any 'adm'/'systemd-journal'
        group member).
    .DESCRIPTION
        NetworkManager 1.54.x can hit an internal settings-layer
        assertion (nm:ERROR:.../nm-settings-utils.c: assertion failed)
        while a Linux bridge is being created via nmcli, and then SIGABRT
        itself (systemd records 'code=dumped, status=6/ABRT'). That
        crash is what raises Ubuntu's apport "system problem detected"
        dialog. Once it has happened, re-running the same nmcli sequence
        just crashes NM again. Callers use this to SKIP the nmcli bridge
        path and fall back to libvirt NAT instead of re-triggering the
        crash + another apport report.
    .PARAMETER WithinMinutes
        Look-back window. Default 60. Use a short window (~3) right after
        an nmcli call to attribute a just-now failure to a NM crash.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$WithinMinutes = 60)
    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { return $false }
    $hits = & journalctl -u NetworkManager --since "-${WithinMinutes}min" --no-pager 2>$null |
        Select-String -Pattern 'code=dumped|core-dump|nm-settings-utils\.c.*assertion'
    return (@($hits).Count -gt 0)
}

function Write-YurunaNmcliFailure {
    <#
    .SYNOPSIS
        Emit the right diagnosis for a failed nmcli call: distinguish a
        NetworkManager crash (its own bug -- the apport-dialog source)
        from a plain rejected request, and surface the verbatim nmcli
        output either way.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [object[]]$NmcliOutput = @()
    )
    if (Test-NetworkManagerCrashedRecently -WithinMinutes 3) {
        Write-Warning "NetworkManager CRASHED while trying to $Operation."
        Write-Warning "  This is an upstream NetworkManager bug (an internal assertion in"
        Write-Warning "  nm-settings-utils.c, then SIGABRT) -- NOT a yuruna fault -- and it"
        Write-Warning "  is what raised the Ubuntu 'system problem detected' dialog."
        Write-Warning "  The cache VM will fall back to libvirt NAT 'default' (host-only)."
        Write-Warning "  To stop this recurring: re-run with YURUNA_EXTERNAL_BRIDGE_SKIP=1,"
        Write-Warning "  upgrade NetworkManager, or define 'yuruna-external' manually"
        Write-Warning "  (see host/ubuntu.kvm/guest.squid-cache/README.md)."
    } else {
        Write-Warning "nmcli: failed to $Operation. nmcli reported:"
        foreach ($l in @($NmcliOutput)) {
            if ("$l".Trim()) { Write-Warning "    $l" }
        }
    }
}

# --- See https://yuruna.link/memory#why-the-libvirt-bridge-self-heal-probes-brif-and-activates-the-slave
function Repair-YurunaExternalBridgeSlave {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork only when its idempotency branch detects a half-built bridge. The user-facing caller (Start-CachingProxy.ps1) already opted in to network-changing behavior via New-YurunaExternalNetwork''s SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$NetworkName)

    if (-not (Test-YurunaNetworkManagerActive)) { return }

    $xmlLines = Invoke-Virsh -VirshArgs @('net-dumpxml', $NetworkName)
    $bridgeName = $null
    foreach ($line in $xmlLines) {
        if ($line -match "<bridge\s+name='([^']+)'") { $bridgeName = $matches[1]; break }
    }
    if (-not $bridgeName) { return }

    $brifDir = "/sys/class/net/$bridgeName/brif"
    if (-not (Test-Path -LiteralPath $brifDir)) {
        Write-Warning "Bridge '$bridgeName' (referenced by libvirt network '$NetworkName') does not exist on the host. Falling through; New-YurunaExternalNetwork's bridge-build path will rebuild it."
        return
    }
    $ports = @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
    if ($ports.Count -gt 0) { return }  # bridge has a real uplink already

    Write-Warning "Bridge '$bridgeName' has no physical uplink (only tap ports attached). Self-healing: activating the matching bridge-slave NM connection..."

    # Find slave NM connection(s) whose connection.master equals our
    # bridge. `nmcli -g connection.master c show <name>` returns just
    # the value (empty for non-slaves), avoiding colon-escaping issues
    # in NAME fields.
    $slaveConns = @()
    $allNames = @(& nmcli -g NAME c show 2>$null | Where-Object { $_ })
    foreach ($n in $allNames) {
        $master = (& nmcli -g connection.master c show $n 2>$null | Select-Object -First 1)
        if ($master -and ("$master".Trim() -eq $bridgeName)) {
            $slaveConns += $n
        }
    }
    if ($slaveConns.Count -eq 0) {
        Write-Warning "No NM connection has connection.master=$bridgeName. Cannot self-heal -- the cache VM will fail to get an IP. Manual recovery: 'sudo nmcli connection delete $bridgeName' then re-run Start-CachingProxy.ps1 to rebuild from scratch."
        return
    }

    foreach ($slave in $slaveConns) {
        & sudo nmcli connection up $slave 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Information "Self-heal: activated bridge-slave '$slave'. Bridge '$bridgeName' now has a LAN uplink; guests on libvirt network '$NetworkName' will DHCP normally."
            return
        }
        Write-Warning "Self-heal: 'sudo nmcli connection up $slave' failed (exit $LASTEXITCODE). Trying any remaining slave candidates..."
    }
    $slaveList = $slaveConns -join ', '
    Write-Warning "Self-heal: none of the candidate bridge-slave connections ($slaveList) could be brought up. The cache VM will fail to get an IP. Manual recovery from the host console: 'sudo nmcli connection up <slave>', or delete the bridge with 'sudo nmcli connection delete $bridgeName' and re-run Start-CachingProxy.ps1."
}

<#
.SYNOPSIS
    Create a host-side Linux bridge + matching libvirt network so a guest
    on this network DHCPs onto the host's LAN and is reachable by remote
    LAN clients (mirrors the Hyper-V Yuruna-External vSwitch role).

.DESCRIPTION
    Idempotent. If $NetworkName is already defined in libvirt, ensures
    it's active + autostart, then runs Repair-YurunaExternalBridgeSlave
    to self-heal a half-built host bridge (bridge NM connection up but
    the slave NIC never enslaved -- DHCP loops, guests get no lease).
    The self-heal is a no-op on a healthy bridge; on a broken one it
    activates the matching bridge-slave NM connection, which may briefly
    flap the host's LAN session. Otherwise (network not yet defined):

      1. Resolves the host's default-route NIC.
      2. Refuses Wi-Fi (most APs filter frames for the bridge-side MAC).
      3. Detects whether the NIC is already a bridge port -- reuses
         that bridge if so (no host networking change).
      4. Else creates a new bridge ($BridgeName) and moves the NIC
         onto it via nmcli (preferred) or netplan (fallback). THIS
         CAUSES A BRIEF NETWORK OUTAGE while DHCP migrates IP from
         the NIC to the bridge -- callers running over SSH on this NIC
         should expect their session to drop and require reconnect.
      5. Defines + starts a libvirt network of type bridge.

    On any failure the function returns $null and logs a clear message;
    it does NOT attempt to roll back a partial bridge config -- the
    operator is better positioned to decide whether to clean up or
    re-run after fixing the upstream problem.

.OUTPUTS
    The libvirt network name on success ($NetworkName), or $null.
#>
function Get-YurunaExternalNetworkPlan {
    <#
    .SYNOPSIS
        Read-only preview of what New-YurunaExternalNetwork WOULD do, so a
        caller can explain the host-networking impact to the operator
        up front -- before any change is made -- and decide whether to
        proceed. Has NO side effects: only queries virsh + the host's
        network interface state.
    .DESCRIPTION
        Mirrors steps 1-3 of New-YurunaExternalNetwork (idempotency
        check, default-route NIC resolution, already-bridged check)
        without performing step 4 (the actual bridge build). Lets
        Start-CachingProxy.ps1 print the brief-network-outage warning at
        the very start of the run instead of mid-way, and proceed in one
        shot with no ShouldProcess prompt.
    .OUTPUTS
        [hashtable] with keys:
          Action      'reuse-network' | 'reuse-bridge' | 'create-bridge'
                      | 'fallback-nat'
          NetworkName libvirt network name
          BridgeName  Linux bridge name (existing or to-be-created)
          Nic         default-route interface, or $null
          WillChangeHostNetworking  $true only for 'create-bridge'
          CanBridge   $false when a LAN-routable bridge is impossible
                      (no default route, or Wi-Fi NIC) -- the cache VM
                      then falls back to NAT 'default' (host-only),
                      which is degraded but NOT a hard failure
          Explanation operator-facing multi-line description
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    $plan = @{
        Action                   = $null
        NetworkName               = $NetworkName
        BridgeName                = $BridgeName
        Nic                       = $null
        WillChangeHostNetworking  = $false
        CanBridge                 = $true
        Explanation               = $null
    }

    # Step 1: libvirt network already defined?
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    if ($defined -contains $NetworkName) {
        $plan.Action      = 'reuse-network'
        $plan.Explanation = "libvirt network '$NetworkName' already exists -- it will simply be (re)started and set to autostart. No host networking change."
        return $plan
    }

    # Step 2: default-route NIC.
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "No IPv4 default route on the host -- a bridged LAN network cannot be built. The cache VM will use libvirt's NAT 'default' network and be reachable from THIS host only."
        return $plan
    }
    $plan.Nic = $nic

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "Default-route NIC '$nic' is Wi-Fi. Linux bridges don't work over 802.11 STA mode (APs drop frames for MACs the radio didn't authenticate), so a bridged network is impossible here. The cache VM will use NAT 'default' (host-only). Use a wired connection for LAN exposure."
        return $plan
    }

    # Step 3: NIC already a bridge port?
    $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
    if ($existingBridge) {
        $plan.Action      = 'reuse-bridge'
        $plan.BridgeName  = $existingBridge
        $plan.Explanation = "NIC '$nic' is already a port of bridge '$existingBridge' -- it will be reused as-is. No host networking change."
        return $plan
    }

    # Step 4: the bridge would have to be built. Before committing to
    # that, check whether NetworkManager has crashed recently -- if it
    # has, the nmcli bridge-build sequence is what crashed it (upstream
    # NM assertion bug), and re-running it just crashes NM again plus
    # raises another apport "system problem" dialog. Degrade to NAT.
    if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = @"
NetworkManager has core-dumped recently on this host (visible in its
journal -- an internal NM assertion in nm-settings-utils.c, triggered by
nmcli bridge creation). That crash is what raised the Ubuntu 'system
problem detected' dialog.

Re-running the bridge build would just crash NetworkManager again, so it
will be SKIPPED. The cache VM will use libvirt's NAT 'default' network
(reachable from this host only) -- which is fully functional for guests
on this same host.

For LAN exposure despite the NM bug, either:
  * upgrade NetworkManager (the assertion is an upstream NM defect), or
  * define the 'yuruna-external' bridge manually (netplan) -- see
    host/ubuntu.kvm/guest.squid-cache/README.md
"@
        return $plan
    }

    # The bridge would have to be built -- this is the only branch that
    # perturbs host networking.
    $plan.Action                  = 'create-bridge'
    $plan.WillChangeHostNetworking = $true
    $plan.Explanation = @"
The host's default-route NIC ($nic) will be moved onto a new Linux bridge
($BridgeName). The bridge requests a fresh DHCP lease in place of the NIC,
causing a brief network outage (typically 1-5 s on a responsive DHCP
server). An SSH session over $nic will likely drop and reconnect once the
new lease arrives.

Rollback (NetworkManager):
  sudo nmcli connection delete '$BridgeName'
  sudo nmcli connection delete '$BridgeName-slave-$nic'
  sudo nmcli connection modify '$nic' connection.autoconnect yes
  sudo nmcli connection up '$nic'
"@
    return $plan
}

<#
.SYNOPSIS
    Define a libvirt bridged network ($NetworkName, default 'yuruna-external')
    backed by a host bridge ($BridgeName, default 'yuruna-br0') over the
    default-route NIC, so cache and test guests are reachable from the LAN.
.DESCRIPTION
    Idempotent and self-healing. On a host where the libvirt network is
    already defined, returns the network name immediately AFTER checking
    that its backing bridge has a working LAN uplink (a previous bring-up
    can leave the bridge half-built -- NM bridge connection up, slave
    never activated -- and guests on it never get DHCP leases). If the
    bridge is half-built, Repair-YurunaExternalBridgeSlave activates the
    matching bridge-slave connection.

    On a clean host:
      1. Resolves the default-route NIC (refuses Wi-Fi; bridges over Wi-Fi
         don't work for guest traffic the way they do over Ethernet).
      2. Builds the Linux bridge via NetworkManager (nmcli) or netplan,
         whichever is active on the host. Brief LAN flap (1-5 s) while
         DHCP migrates from the bare NIC onto the bridge.
      3. Defines the libvirt network as a forward-mode=bridge interface
         pointing at the new host bridge, sets it autostart, starts it.

    All diagnostics are emitted via Write-Information / Write-Warning /
    Write-Error so the function's only success output stays the single
    network name string -- callers can safely assign with
    `$x = New-YurunaExternalNetwork`. A stray Write-Output would turn $x
    into a string[] and break downstream consumers (Get-ExternalNetwork
    compares against the exact name).
.PARAMETER NetworkName
    libvirt network name. Default 'yuruna-external'.
.PARAMETER BridgeName
    Host bridge interface name. Default 'yuruna-br0'.
.OUTPUTS
    [string] The network name on success (existing OR freshly created),
    $null when the operator opted out via -WhatIf or when the bridge
    build failed.
#>
function New-YurunaExternalNetwork {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([string])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    # IMPORTANT: this function's only pipeline output is a single string
    # (network name) or $null. All diagnostics MUST go through
    # Write-Information / Write-Warning / Write-Error so callers can
    # safely assign with `$x = New-YurunaExternalNetwork`. A stray
    # Write-Output would turn $x into a string[] and break downstream
    # consumers (Get-ExternalNetwork compares against this exact name).

    # -- Step 1: idempotency -------------------------------------------------
    # Fast-return when the libvirt network is already defined -- but
    # NOT before verifying the backing host bridge actually has a LAN
    # uplink. A previous bring-up can leave the bridge half-built
    # (bridge NM connection up, slave never activated): the libvirt
    # network looks fine to virsh, but guests on it never get DHCP
    # leases because the bridge has no path to the upstream DHCP server.
    # Repair-YurunaExternalBridgeSlave detects + self-heals that state.
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    if ($defined -contains $NetworkName) {
        Write-Information "libvirt network '$NetworkName' already defined."
        $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
        if (-not ($running -contains $NetworkName)) {
            Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        }
        Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
        Repair-YurunaExternalBridgeSlave -NetworkName $NetworkName
        return $NetworkName
    }

    # -- Step 2: resolve default-route NIC -----------------------------------
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        Write-Warning "No IPv4 default route on the host. Cannot create '$NetworkName' bridge -- connect a NIC to the LAN first."
        return $null
    }
    Write-Information "Default-route interface: $nic"

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        Write-Warning "Default-route NIC '$nic' is Wi-Fi. Linux bridges over Wi-Fi don't work in 802.11 STA mode -- most APs drop frames for any MAC the radio didn't authenticate, so the cache VM's DHCP request will be silently dropped. Run this on a wired connection."
        return $null
    }

    # -- Step 3: maybe the NIC is already bridged ----------------------------
    # If the operator (or a previous run) already put the WAN NIC on a
    # bridge, reuse it. This keeps the host networking change to zero:
    # we only need to define the libvirt network pointing at the existing
    # bridge. $BridgeName becomes a no-op suggestion in that case.
    $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
    if ($existingBridge) {
        Write-Information "Interface '$nic' is already a port of bridge '$existingBridge'. Reusing it (no host networking change)."
        $BridgeName = $existingBridge
    } else {
        # -- Step 4: build the bridge ----------------------------------------
        # Guard: if NetworkManager has core-dumped recently AND NM is the
        # active backend, the nmcli bridge build is almost certainly what
        # crashed it (upstream NM assertion bug in nm-settings-utils.c).
        # Re-running it just crashes NM again and raises another apport
        # "system problem" dialog -- skip straight to NAT fallback. The
        # netplan backend (NM not active) is unaffected, so this guard is
        # scoped to the NM-active case only.
        if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
            Write-Warning "NetworkManager has core-dumped recently on this host (see its journal)."
            Write-Warning "  The nmcli bridge build is what crashes it -- an upstream NM bug, not a"
            Write-Warning "  yuruna fault. Skipping bridge creation to avoid crashing NM again."
            Write-Warning "  Cache VM will use libvirt NAT 'default' (host-only). For LAN exposure,"
            Write-Warning "  upgrade NetworkManager or define 'yuruna-external' manually."
            return $null
        }

        # The full brief-network-outage warning + rollback recipe is
        # surfaced UP FRONT by the caller via Get-YurunaExternalNetworkPlan
        # (Start-CachingProxy.ps1's plan phase), so it isn't repeated here.
        # ShouldProcess is kept so a standalone or -Confirm caller still
        # gets a gate; Start-CachingProxy passes -Confirm:$false because it
        # already explained the impact and planned the run.
        Write-Information "Building Linux bridge '$BridgeName' on NIC '$nic' (brief network outage; rollback recipe was printed in the plan above)."

        if (-not $PSCmdlet.ShouldProcess("$nic + $BridgeName", "Move '$nic' onto new Linux bridge '$BridgeName' (brief network outage)")) {
            Write-Warning "Bridge creation not confirmed. Cache VM will fall back to libvirt's NAT 'default' network (host-only)."
            return $null
        }

        $ok = $false
        if (Test-YurunaNetworkManagerActive) {
            $ok = New-YurunaBridgeViaNmcli -Nic $nic -BridgeName $BridgeName
        } else {
            Write-Information "NetworkManager not active -- trying netplan path."
            $ok = New-YurunaBridgeViaNetplan -Nic $nic -BridgeName $BridgeName
        }
        if (-not $ok) {
            Write-Warning "Bridge creation failed. The host's original NIC config should be unchanged. See messages above for the specific tool error."
            return $null
        }
    }

    # -- Step 5: define + start the libvirt network --------------------------
    # libvirt's <forward mode='bridge'/> with a <bridge name='...'/> tells
    # qemu to attach guests directly to the named bridge via a tap; the
    # guest's MAC is visible on the LAN and gets its own DHCP lease.
    $xmlContent = @"
<network>
  <name>$NetworkName</name>
  <forward mode='bridge'/>
  <bridge name='$BridgeName'/>
</network>
"@
    $xmlPath = New-TemporaryFile
    try {
        Set-Content -LiteralPath $xmlPath.FullName -Value $xmlContent -NoNewline
        Invoke-Virsh -VirshArgs @('net-define', $xmlPath.FullName) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "virsh net-define '$NetworkName' failed (exit $LASTEXITCODE)."
            return $null
        }
        Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "virsh net-start '$NetworkName' failed (exit $LASTEXITCODE). Try: sudo virsh -c qemu:///system net-start $NetworkName"
            return $null
        }
        Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
    } finally {
        Remove-Item -LiteralPath $xmlPath.FullName -Force -ErrorAction SilentlyContinue
    }
    Write-Information "libvirt network '$NetworkName' bridged on '$BridgeName' is ready."
    return $NetworkName
}

# Internal. Build $BridgeName via NetworkManager, with $Nic as a slave.
# Returns $true on success. Side effect: the active connection on $Nic
# is brought down and replaced by the bridge connection.
function New-YurunaBridgeViaNmcli {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    $slaveConn = "$BridgeName-slave-$Nic"

    # Idempotency: a previous attempt -- or a NetworkManager crash
    # mid-build -- can leave half-created '$BridgeName' /
    # '$BridgeName-slave-*' connection profiles behind. Re-running
    # `nmcli connection add` on top of those fails outright, and feeding
    # NM a duplicate/conflicting profile is itself a trigger for the
    # nm-settings-utils.c assertion crash. Delete every stale profile
    # for this bridge first so the build starts from a clean slate.
    $staleConns = @(& nmcli -t -f NAME connection show 2>$null) |
        Where-Object { $_ -eq $BridgeName -or $_ -like "$BridgeName-slave-*" }
    foreach ($sc in $staleConns) {
        Write-Information "  Removing stale NetworkManager connection '$sc' (leftover from a previous attempt)."
        & sudo nmcli connection delete $sc 2>&1 | ForEach-Object { Write-Verbose "$_" }
    }

    # nmcli connection add type bridge -- creates the bridge connection
    # profile + the kernel bridge interface. stp=no avoids the 30 s
    # spanning-tree forwarding delay (we have exactly one physical NIC
    # under this bridge; loops are impossible). ipv4.method=auto +
    # ipv6.method=auto let the bridge DHCP independently after $Nic's
    # original IP lease is dropped. nmcli output is captured (not piped
    # to Write-Verbose) so Write-YurunaNmcliFailure can surface the
    # verbatim error -- or diagnose a NetworkManager crash -- on failure.
    $addOut = & sudo nmcli connection add type bridge ifname $BridgeName con-name $BridgeName `
        bridge.stp no `
        ipv4.method auto `
        ipv6.method auto 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge connection '$BridgeName'" -NmcliOutput $addOut
        return $false
    }

    # Clone $Nic's MAC onto the bridge BEFORE first activation. Without
    # this, NM assigns a random locally-administered MAC to the bridge
    # and the upstream DHCP server hands out a new IP -- breaking the
    # operator's SSH session and any DNS A records pointing at the host.
    # With the cloned MAC the bridge takes $Nic's place at the DHCP
    # server's lease table and the same IP comes back. Best-effort: if
    # /sys/class/net/<nic>/address is missing or empty we skip and warn
    # (the bridge still works, just with a fresh IP).
    $nicMac = $null
    $macPath = "/sys/class/net/$Nic/address"
    if (Test-Path -LiteralPath $macPath) {
        $nicMac = (Get-Content -LiteralPath $macPath -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($nicMac) { $nicMac = $nicMac.Trim() }
    }
    if ($nicMac) {
        & sudo nmcli connection modify $BridgeName bridge.mac-address $nicMac 2>&1 |
            ForEach-Object { Write-Verbose "$_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "nmcli: could not set bridge.mac-address=$nicMac on '$BridgeName'. Bridge will still come up, but DHCP may return a different IP than '$Nic' currently holds."
        }
    } else {
        Write-Warning "Could not read $macPath -- not cloning MAC onto bridge. DHCP may return a different IP than '$Nic' currently holds."
    }

    # Attach $Nic as a bridge-slave. This profile is the one NM will
    # auto-activate at boot to keep the bridge populated.
    $slaveOut = & sudo nmcli connection add type bridge-slave ifname $Nic master $BridgeName `
        con-name $slaveConn 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge-slave connection for '$Nic'" -NmcliOutput $slaveOut
        # Best effort: delete the orphan bridge profile so a retry is clean.
        & sudo nmcli connection delete $BridgeName 2>&1 | Out-Null
        return $false
    }

    # Disable the existing NIC profile's autoconnect so on reboot the
    # bridge is the one that activates (not the bare NIC re-grabbing
    # the LAN IP and starving the bridge of carrier). The OLD active
    # connection name is whatever NM currently has bound to $Nic --
    # query and modify in place. If no active connection (NIC was
    # manually unbound), nothing to disable.
    $oldConn = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                Where-Object { $_ -match "^([^:]+):$Nic`$" } |
                ForEach-Object { ($_ -split ':', 2)[0] } |
                Select-Object -First 1)
    if ($oldConn -and $oldConn -ne $slaveConn -and $oldConn -ne $BridgeName) {
        & sudo nmcli connection modify $oldConn connection.autoconnect no 2>&1 | Out-Null
    }

    # Activate the bridge profile. This creates the kernel bridge
    # interface under NM's control but does NOT yet take $Nic's
    # carrier -- contrary to a tempting reading, `nmcli c up <bridge>`
    # does not auto-enslave member ports. The bridge sits up with no
    # uplink until the slave is brought up below; DHCP on the bridge
    # will start, time out at ~45 s with `ip-config-unavailable`, and
    # loop -- which is exactly the failure mode that left the cache
    # VM stranded with no IP before this fix.
    Write-Information "  Activating bridge '$BridgeName'..."
    $brUpOut = & sudo nmcli connection up $BridgeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "bring up bridge '$BridgeName'" -NmcliOutput $brUpOut
        Write-Warning "  Recover manually: 'sudo nmcli connection up $BridgeName', or remove the"
        Write-Warning "  half-built bridge with 'sudo nmcli connection delete $BridgeName $slaveConn'."
        return $false
    }

    # Critical: explicitly activate the slave so $Nic actually gets
    # enslaved to the bridge. The slave profile's autoconnect=yes alone
    # is NOT sufficient when another profile (netplan-<nic>, "Wired
    # connection N", etc.) currently holds $Nic -- NM will not
    # auto-deactivate a competing active profile to satisfy a slave's
    # autoconnect. A user-initiated `nmcli c up $slaveConn` overrides
    # that policy: NM deactivates the conflicting profile, binds $Nic
    # to the slave, the bridge sees new carrier, and DHCP succeeds.
    # This is the moment SSH sessions over $Nic flap; with the cloned
    # MAC above the new DHCP lease should be the same IP and SSH
    # reconnects within a few seconds.
    Write-Information "  Enslaving '$Nic' to bridge '$BridgeName' (brief outage now)..."
    $slUpOut = & sudo nmcli connection up $slaveConn 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "enslave '$Nic' to bridge '$BridgeName'" -NmcliOutput $slUpOut
        Write-Warning "  Bridge is up but has no physical uplink, so guests would not get DHCP"
        Write-Warning "  leases. Recover with 'sudo nmcli connection up $slaveConn'."
        return $false
    }

    # Wait up to 30 s for the bridge to DHCP. nmcli connection up
    # returns when the connection is "activated" -- which can be before
    # DHCP completes. A bridge with no IP is still useless for the
    # libvirt network we are about to define, so block here briefly.
    for ($i = 0; $i -lt 30; $i++) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information "  Bridge '$BridgeName' DHCP-leased: $($brIp -replace '^\s+|\s+$','')"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning "Bridge '$BridgeName' came up but has no IPv4 lease after 30 s. The libvirt network will still work for guests, but the host won't be able to reach them. Check 'ip -4 addr show $BridgeName' and your DHCP server."
    return $true
}

# Internal. Build $BridgeName via netplan, with $Nic as the only port.
# Returns $true on success. Side effect: writes a new file under
# /etc/netplan/ and runs `netplan apply`, which renews the lease for the
# bridge in place of $Nic.
function New-YurunaBridgeViaNetplan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    # netplan's renderer defaults to systemd-networkd on Ubuntu Server
    # cloud images. We do NOT set `renderer:` here so we don't force a
    # backend swap on hosts where the operator picked NetworkManager
    # explicitly (and Test-YurunaNetworkManagerActive returned false
    # only because NM was momentarily not running).
    $netplanPath = "/etc/netplan/99-yuruna-external.yaml"
    $yaml = @"
network:
  version: 2
  ethernets:
    ${Nic}:
      dhcp4: no
      dhcp6: no
  bridges:
    ${BridgeName}:
      interfaces: [${Nic}]
      dhcp4: yes
      dhcp6: yes
      parameters:
        stp: false
"@
    # netplan files are root-owned 600; write via sudo+tee.
    $yaml | & sudo tee $netplanPath > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not write '$netplanPath'. Are you in the sudo group?"
        return $false
    }
    & sudo chmod 600 $netplanPath 2>&1 | Out-Null

    # netplan validates the rendered config before applying. A parse
    # error here means our yaml is wrong; bail BEFORE running apply so
    # the operator's networking stays untouched.
    & sudo netplan generate 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "netplan generate failed -- the yaml at $netplanPath was rejected. Inspect it and re-run."
        return $false
    }

    Write-Information "  Applying netplan (brief outage now)..."
    & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "netplan apply failed. To roll back: sudo rm $netplanPath && sudo netplan apply."
        return $false
    }

    # Wait up to 30 s for the bridge to DHCP. Same rationale as nmcli.
    for ($i = 0; $i -lt 30; $i++) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information "  Bridge '$BridgeName' DHCP-leased: $($brIp -replace '^\s+|\s+$','')"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning "Bridge '$BridgeName' came up but has no IPv4 lease after 30 s. The libvirt network will still work for guests, but the host won't be able to reach them. Check 'ip -4 addr show $BridgeName' and your DHCP server."
    return $true
}

<#
.SYNOPSIS
    Returns true if the squid-cache VM is on a bridged libvirt network
    (LAN-routable IP, no host portproxy needed).
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    # Matches the Hyper-V contract semantic: true iff the cache VM has
    # its own LAN-routable IP -- consumers on the LAN can hit it
    # directly with no host-side portproxy in the path. On KVM this is
    # equivalent to "VM's <source network='...'/> is NOT the NAT
    # 'default' network". 'yuruna-external' (bridge), any user-defined
    # YURUNA_EXTERNAL_NETWORK, or a custom bridge all qualify; only the
    # built-in NAT 'default' (192.168.122/24, host-only without a port
    # forwarder) does not.
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state) { return $false }
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0) { return $false }
    $joined = [string]::Join("`n", $xml)
    # Pull the first source network name from the dumpxml output.
    # Domains may have multiple interfaces; the first one is what the
    # cache VM lands on per our New-VM.ps1 (only one --network spec).
    if ($joined -notmatch "<source\s+network='([^']+)'") { return $false }
    $srcNet = $Matches[1]
    return ($srcNet -ne 'default')
}

<#
.SYNOPSIS
    Expose the caching-proxy VM's ports on the host's LAN IP so LAN
    clients reach the NAT-networked cache at http://<host-lan-ip>:<port>.
.DESCRIPTION
    The cache VM sits on libvirt's NAT 'default' network, so its
    192.168.122/24 address is reachable from this host only. To make it
    LAN-reachable WITHOUT reconfiguring host networking or NetworkManager,
    this installs one socket-activated systemd unit pair per port:

      yuruna-cacheproxy-p<hostport>.socket   ListenStream=0.0.0.0:<hostport>
      yuruna-cacheproxy-p<hostport>.service  systemd-socket-proxyd <vmip>:<vmport>

    Why socket-activated forwarding and not nftables DNAT: a DNAT rule
    into the NAT subnet is dropped by libvirt's OWN forward chain --
    libvirt installs an `oifname virbr0 ... reject` rule for unsolicited
    inbound traffic to its guests. Making DNAT work means overriding
    libvirt's firewall rules, which is firewall-backend-specific and is
    regenerated every time libvirt restarts. systemd-socket-proxyd
    instead connects to the VM as a host-LOCAL process; host<->guest
    traffic is not subject to that forward filtering, so it works
    regardless of libvirt's backend. systemd runs the proxy as root (so
    a privileged :80 bind succeeds) and the enabled .socket units are
    restored on boot -- fixing both fatal flaws of the previous pwsh
    Start-Process forwarders, which could not bind :80 and did not
    survive a reboot.
.OUTPUTS
    [bool] $true when at least one forwarder socket is listening.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @()
    )
    # PROXY-protocol prefixing is a macOS shared-NAT-only mitigation;
    # accepted for cross-host contract parity, surfaced as a debug line.
    if ($ProxyProtocolPort.Count -gt 0) {
        Write-Debug "Add-PortMap on host.ubuntu.kvm: -ProxyProtocolPort $($ProxyProtocolPort -join ',') ignored; uses systemd-socket-proxyd."
    }
    if (-not (Test-Ipv4Address $VMIp)) {
        Write-Warning "Add-PortMap: VMIp '$VMIp' is not a valid IPv4 address -- skipping LAN exposure."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMIp, "Install systemd socket-proxy forwarders for ports $($Port -join ',')")) { return $false }

    # systemd-socket-proxyd: Ubuntu ships it under /usr/lib/systemd;
    # older layouts use /lib/systemd. The unit's ExecStart needs an
    # absolute path, so resolve it now and bail clearly if absent.
    $proxyd = @('/usr/lib/systemd/systemd-socket-proxyd','/lib/systemd/systemd-socket-proxyd') |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $proxyd) {
        Write-Warning "Add-PortMap: systemd-socket-proxyd not found -- cannot expose the cache on the host LAN IP."
        return $false
    }

    # Build the hostPort -> vmPort mapping list. Straight ports map 1:1;
    # a PortRemap entry (e.g. 8022 -> 22) overrides that hostPort. This
    # is a plain array of objects ON PURPOSE -- NOT [ordered]@{}: an
    # OrderedDictionary keyed by integers indexes POSITIONALLY when the
    # index is an [int], so `$map[3128]` is an out-of-range positional
    # lookup ("argument out of range, Parameter 'index'"), not the key
    # lookup it looks like. An object array sidesteps that trap.
    $remap = @{}
    foreach ($k in $PortRemap.Keys) { $remap[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if (-not $remap.ContainsKey([int]$p)) {
            $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
        }
    }
    foreach ($k in $remap.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remap[$k] }
    }

    # Clear any prior yuruna-cacheproxy units first: on a re-run the cache
    # VM's NAT IP can differ, and a stale forwarder would point LAN
    # clients at a dead address.
    [void](Remove-PortMap -Confirm:$false)

    $written = 0
    foreach ($m in $mappings) {
        $hostPort = $m.HostPort
        $vmPort   = $m.VMPort
        $base     = "yuruna-cacheproxy-p$hostPort"
        # No PartOf= on the socket: the .socket must keep listening when
        # the socket-activated .service recycles (systemd-socket-proxyd
        # exits when idle and is re-activated on the next connection).
        # Tying the socket to the service via PartOf would tear the
        # listener down on every idle cycle.
        $socketBody = @"
[Unit]
Description=Yuruna caching-proxy forward :$hostPort -> ${VMIp}:$vmPort

[Socket]
ListenStream=0.0.0.0:$hostPort

[Install]
WantedBy=sockets.target
"@
        $serviceBody = @"
[Unit]
Description=Yuruna caching-proxy socket-proxy :$hostPort -> ${VMIp}:$vmPort
Requires=$base.socket
After=$base.socket

[Service]
ExecStart=$proxyd ${VMIp}:$vmPort
"@
        $socketBody  | & sudo tee "/etc/systemd/system/$base.socket"  > $null 2>&1
        $okSocket = ($LASTEXITCODE -eq 0)
        $serviceBody | & sudo tee "/etc/systemd/system/$base.service" > $null 2>&1
        $okService = ($LASTEXITCODE -eq 0)
        if ($okSocket -and $okService) {
            $written++
        } else {
            Write-Warning "  Could not write systemd units for port $hostPort -- skipping it."
        }
    }
    if ($written -eq 0) {
        Write-Warning "Add-PortMap: no forwarder units could be written (sudo / disk issue?)."
        return $false
    }

    & sudo systemctl daemon-reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
    $up = 0
    foreach ($m in $mappings) {
        $sock = "yuruna-cacheproxy-p$($m.HostPort).socket"
        & sudo systemctl enable --now $sock 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Information "  Forwarder listening: 0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)"
            $up++
        } else {
            Write-Warning "  systemctl enable --now $sock failed -- port $($m.HostPort) not exposed."
        }
    }
    return ($up -gt 0)
}

<#
.SYNOPSIS
    Tear down every yuruna caching-proxy forwarder: the systemd
    socket-proxy units, plus any legacy pwsh Start-Process forwarders.
    Idempotent -- "nothing installed" is still success.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('yuruna-cacheproxy forwarders', 'Stop + remove')) { return $false }

    # Current mechanism: systemd socket-proxy units. Disable+stop the
    # .socket (drops it from sockets.target and closes the listener),
    # stop the .service, delete the unit files, reload systemd.
    $units = @(Get-ChildItem -LiteralPath '/etc/systemd/system' -Filter 'yuruna-cacheproxy-*' -ErrorAction SilentlyContinue)
    if ($units.Count -gt 0) {
        foreach ($u in ($units | Where-Object { $_.Name -like '*.socket' })) {
            & sudo systemctl disable --now $u.Name 2>&1 | Out-Null
        }
        foreach ($u in ($units | Where-Object { $_.Name -like '*.service' })) {
            & sudo systemctl stop $u.Name 2>&1 | Out-Null
        }
        & sudo rm -f @($units | ForEach-Object { $_.FullName }) 2>&1 | Out-Null
        & sudo systemctl daemon-reload 2>&1 | Out-Null
    }

    # Legacy pwsh Start-Process forwarders (pre-systemd mechanism): kill
    # any survivors tracked by portmap-*.pid, then clear the staging dir.
    if (Test-Path -LiteralPath $script:PortMapDir) {
        foreach ($pidFile in Get-ChildItem -LiteralPath $script:PortMapDir -Filter 'portmap-*.pid' -ErrorAction SilentlyContinue) {
            try {
                $fpid = [int]((Get-Content -LiteralPath $pidFile.FullName -Raw).Trim())
                if ($fpid -gt 0) { & /bin/kill -9 $fpid 2>$null | Out-Null }
            } catch { Write-Debug "Remove-PortMap legacy: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $script:PortMapDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# Start-PortForwarder (a pwsh Start-Process TcpListener forwarder) was
# removed: it could not bind privileged ports (:80) as a non-root user
# and its detached processes did not survive a host reboot. Add-PortMap
# now installs systemd socket-activated forwarders instead -- see its
# .DESCRIPTION above.

<#
.SYNOPSIS
    Return the host's best LAN-routable IPv4 for browser-facing URLs.
#>
function Get-BestHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # `ip route get 1.1.1.1` resolves the default-route iface + the source
    # IP the kernel would use; that's the LAN-facing address even when
    # multiple NICs / VPNs are present. iproute2 ships with every Ubuntu.
    $out = & ip -4 route get 1.1.1.1 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in @($out)) {
        if (($line -match 'src\s+(\d+\.\d+\.\d+\.\d+)') -and (Test-Ipv4Address $Matches[1])) {
            return $Matches[1]
        }
    }
    return $null
}

<#
.SYNOPSIS
    Return the host IP a guest reaches the host at (per SwitchName).
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SwitchName)
    # The libvirt 'default' network always uses 192.168.122.0/24 with the
    # host on .1. SwitchName is reserved for parity with Hyper-V; on KVM
    # the libvirt bridge is implied. If a custom external bridge is in
    # play, the operator should override via $env:YURUNA_GUEST_REACHABLE_HOST_IP.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.ubuntu.kvm: -SwitchName '$SwitchName' ignored; libvirt bridge implied." }
    if ($Env:YURUNA_GUEST_REACHABLE_HOST_IP) { return $Env:YURUNA_GUEST_REACHABLE_HOST_IP }
    return '192.168.122.1'
}

# === Caching proxy ==========================================================

<#
.SYNOPSIS
    Probe and return the squid-cache URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyState).ipAddress -- the cache VM's
         IP recorded by Start-CachingProxy.ps1 (our own VM).

    No libvirt enumeration, no loopback-forwarder fallback. Get-Caching-
    ProxyVMIp still exposes the recorded IP for direct callers that need
    it, and falls back to a live libvirt query for the by-name VM, but
    that fallback is no longer part of the discovery contract surfaced
    through Test-CachingProxyAvailable. LAN-wide cache discovery is a
    separate future feature.
#>
function Test-CachingProxyAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyPort -Scheme http
    # External cache override (same shape as macOS / Hyper-V).
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if (-not (Test-IpAddress $externIp)) {
            Write-Warning "YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 or IPv6 address -- ignoring."
            return $null
        }
        if (Test-TcpReachable -TargetHost $externIp -Port $httpPort -TimeoutMs 1000) {
            return "http://${externIp}:${httpPort}"
        }
        Write-Warning "YURUNA_CACHING_PROXY_IP=${externIp} set but ${externIp}:${httpPort} did not answer."
        return $null
    }

    # Local cache: probe only the IP we recorded ourselves at the last
    # Start-CachingProxy.ps1. Empty state -> no cache (the explicit
    # contract after Stop-CachingProxy.ps1). State-set-but-unreachable
    # is loud (Write-Warning) because the inner runner's bootstrap
    # detection runs ONCE per cycle -- a silently-failed probe means
    # the whole cycle's guests download direct from the internet, and
    # we want the operator to see "why" alongside the headline
    # "Caching proxy: not detected" line in Invoke-TestRunner output.
    $stateIp = (Read-CachingProxyState).ipAddress
    if (-not $stateIp -or -not (Test-IpAddress $stateIp)) {
        Write-Warning "Test-CachingProxyAvailable: state.ipAddress is empty -- no locally-owned cache. Set `$Env:YURUNA_CACHING_PROXY_IP to point at a remote cache, or run Start-CachingProxy.ps1."
        return $null
    }
    # 1500 ms matches test/Test-CachingProxy.ps1's CLI probe so a
    # cache that answers the standalone smoke test also answers here;
    # the earlier 500 ms left a window where a momentarily busy squid
    # would miss the runner's single bootstrap probe and silently
    # strand the whole inner cycle.
    if (Test-TcpReachable -TargetHost $stateIp -Port $httpPort -TimeoutMs 1500) {
        return "http://${stateIp}:${httpPort}"
    }
    Write-Warning "Test-CachingProxyAvailable: state.ipAddress=${stateIp} did not answer :${httpPort} within 1500 ms; treating cache as unavailable. Verify with 'nc -z ${stateIp} ${httpPort}'; if it answers, the cache is running and the next runner cycle will pick it up. If not, re-run Start-CachingProxy.ps1 (the VM may have restarted with a new DHCP lease)."
    return $null
}

<#
.SYNOPSIS
    TCP-reachable probe with a bounded timeout (no exception escapes).
#>
function Test-TcpReachable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 500
    )
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected) { return $true }
    } catch { Write-Debug "Test-TcpReachable ${TargetHost}:${Port}: $($_.Exception.Message)" }
    finally { $tcp.Close() }
    return $false
}

<#
.SYNOPSIS
    Return the cache VM's real IP for downstream port-forwarder setup.
#>
function Get-CachingProxyVMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Prefer the recorded IP from Start-CachingProxy.ps1 (matches macOS / Windows).
    $ip = (Read-CachingProxyState).ipAddress
    if ($ip -and (Test-IpAddress $ip)) { return $ip }
    # Live discovery via libvirt: ask the VM.
    return (Get-VMIp -VMName 'yuruna-caching-proxy')
}

# === Host config ============================================================

<#
.SYNOPSIS
    Promote a proxy URL to the machine-wide host proxy with backup.
#>
function Set-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    if (-not $PSCmdlet.ShouldProcess('Linux host (apt + /etc/environment)', "Set proxy = $ProxyUrl")) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    # Snapshot the current state once so Clear-HostProxy can restore it.
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $state = Read-LinuxProxyState
        $state['timestamp']  = (Get-Date).ToUniversalTime().ToString('o')
        $state['promotedTo'] = $parts.Url
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-Information "  Host proxy: backup written to $backupPath"
    } else {
        Write-Information "  Host proxy: existing backup at $backupPath preserved (still apply)"
    }
    Set-LinuxHostProxy -ProxyUrl $parts.Url
    Write-Information "  Host proxy: /etc/environment + /etc/apt/apt.conf.d/99yuruna-host-proxy set to $($parts.Url)"
    return $true
}

<#
.SYNOPSIS
    Restore the host proxy from the saved backup, or disable if none.
#>
function Clear-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Linux host', 'Disable proxy / restore backup')) { return $false }
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        try {
            $state = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Host proxy: could not parse backup '$backupPath' ($($_.Exception.Message)). Falling back to disable-only."
            $state = $null
        }
    }
    if ($state -and $state.previousUrl) {
        Set-LinuxHostProxy -ProxyUrl $state.previousUrl
        Write-Information "  Host proxy: restored to $($state.previousUrl)"
    } else {
        Disable-LinuxHostProxy
        Write-Information "  Host proxy: cleared (no prior URL to restore)"
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Aggressively wipe every host-proxy reference and the backup file.
#>
function Remove-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Linux host', 'Wipe host proxy state')) { return $false }
    Disable-LinuxHostProxy
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    Write-Information "  Host proxy: wiped (apt config removed; /etc/environment proxy lines stripped)"
    return $true
}

<#
.SYNOPSIS
    Read current Linux host proxy state into a backup hashtable.
#>
function Read-LinuxProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $state = @{ previousUrl = $null; aptConfigPresent = $false }
    if (Test-Path -LiteralPath '/etc/environment') {
        $env = Get-Content -LiteralPath /etc/environment -ErrorAction SilentlyContinue
        foreach ($line in $env) {
            if ($line -match '^(?:HTTPS?|https?)_proxy\s*=\s*"?([^"]+?)"?\s*$') {
                $state['previousUrl'] = $Matches[1]; break
            }
        }
    }
    $state['aptConfigPresent'] = (Test-Path -LiteralPath '/etc/apt/apt.conf.d/99yuruna-host-proxy')
    return $state
}

<#
.SYNOPSIS
    Apply the proxy via /etc/environment + /etc/apt/apt.conf.d (sudo).
#>
function Set-LinuxHostProxy {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public Set-HostProxy/Clear-HostProxy callers already gate via SupportsShouldProcess.')]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    # /etc/environment: clean any prior yuruna-managed lines first, then
    # write the new ones. Match upper-case + lower-case forms.
    $script = @"
set -e
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment 2>/dev/null || true
printf 'http_proxy="%s"\nhttps_proxy="%s"\nHTTP_PROXY="%s"\nHTTPS_PROXY="%s"\n' '$ProxyUrl' '$ProxyUrl' '$ProxyUrl' '$ProxyUrl' >> /etc/environment
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99yuruna-host-proxy <<EOF
Acquire::http::Proxy "$ProxyUrl";
Acquire::https::Proxy "$ProxyUrl";
EOF
chmod 0644 /etc/apt/apt.conf.d/99yuruna-host-proxy
"@
    & sudo bash -c $script
}

<#
.SYNOPSIS
    Disable the Linux host proxy (rm apt config + strip /etc/environment).
#>
function Disable-LinuxHostProxy {
    [CmdletBinding()]
    param()
    $script = @'
set -e
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment 2>/dev/null || true
rm -f /etc/apt/apt.conf.d/99yuruna-host-proxy 2>/dev/null || true
'@
    & sudo bash -c $script
}

<#
.SYNOPSIS
    Return the path of the host-proxy backup JSON.
#>
function Get-HostProxyBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Test.VM.common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # /dev/kvm is the kernel signal that hardware virt is enabled and
    # exposed; libvirtd being active is the userspace signal. Both
    # required for guests to actually run with KVM acceleration.
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        Write-Verbose "Assert-Virtualization: /dev/kvm missing (kvm.ko not loaded or VT-x/SVM disabled in firmware)."
        return $false
    }
    $active = & systemctl is-active libvirtd 2>$null
    if ("$active".Trim() -ne 'active') {
        Write-Verbose "Assert-Virtualization: libvirtd is not active (state=$active)."
        return $false
    }
    # libvirtd being active is not the same as THIS process being able to
    # reach it. A user added to 'libvirt' via usermod -aG only gets the
    # group in their effective set after a re-login -- and on systemd-
    # logind systems with user lingering, even a desktop logout/login
    # often does NOT refresh existing terminal sessions. Without this
    # check, the runner cruises past Assert-Virtualization, spends ~8
    # minutes downloading ISOs, and only THEN crashes inside New-VM.ps1
    # with the verbatim libvirt-sock "Permission denied" line.
    & virsh --connect $script:VirshUri list --name >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Assert-Virtualization: virsh list failed (exit $LASTEXITCODE) -- this process cannot reach $script:VirshUri."
        return $false
    }
    return $true
}

# === SSH server (host-side) =================================================

<#
.SYNOPSIS
    Returns true if the host has a code path for SSH-server lifecycle.
#>
function Test-SshServerSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $true
}

<#
.SYNOPSIS
    Returns true if the host SSH server is installed.
#>
function Test-SshServerInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # On Debian/Ubuntu, openssh-server installs sshd at /usr/sbin/sshd.
    # Fall back to the dpkg query when sshd is removed but the package
    # is still flagged as half-installed.
    if (Test-Path -LiteralPath '/usr/sbin/sshd') { return $true }
    $st = & dpkg-query -W -f='${db:Status-Status}' openssh-server 2>$null
    return ("$st".Trim() -eq 'installed')
}

<#
.SYNOPSIS
    Install the host SSH server (idempotent).
#>
function Install-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('openssh-server', 'apt-get install')) { return $false }
    if (Test-SshServerInstalled) { return $true }
    & sudo apt-get update -qq | Out-Null
    & sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Start the host SSH server and set it to autostart.
#>
function Start-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('ssh.service', 'systemctl enable --now ssh')) { return $false }
    if (-not (Test-SshServerInstalled)) { return $false }
    & sudo systemctl enable --now ssh 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Stop the host SSH server.
#>
function Stop-SshServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('ssh.service', 'systemctl disable --now ssh')) { return $false }
    & sudo systemctl disable --now ssh 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Return 'running', 'stopped', 'not-installed', or 'unsupported'.
#>
function Get-SshServerStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Test-SshServerInstalled)) { return 'not-installed' }
    $active = & systemctl is-active ssh 2>$null
    if ("$active".Trim() -eq 'active') { return 'running' }
    return 'stopped'
}

# === Exports ================================================================

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Get-VMState, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, `
    Get-ExternalNetwork, New-ExternalNetwork, New-YurunaExternalNetwork, Get-YurunaExternalNetworkPlan, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyAvailable, Get-CachingProxyVMIp, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    Test-SshServerSupported, Test-SshServerInstalled, Install-SshServer, `
    Start-SshServer, Stop-SshServer, Get-SshServerStatus
