<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456713
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# ── UTM dialog watchdog (macOS only) ─────────────────────────────────────────
# Background osascript process that clicks non-destructive accept buttons on
# any UTM dialog/sheet every ~2 s. Suppresses both the import-time "custom
# QEMU arguments" warning and the runtime "QEMU error: ... Invalid argument"
# popups, keeping the harness unattended.
#
# PID of the running osascript is kept at
# $HOME/virtual/utm-dialog-watchdog.pid. Start-UtmDialogWatchdog kills any
# stale watchdog first, then spawns a fresh one. Stop-UtmDialogWatchdog is
# called from Stop-TestVM to shut it down. If anything leaks (harness
# crash), the next Start-UtmDialogWatchdog's stale-PID cleanup handles it.

$script:WatchdogPidFile    = Join-Path $HOME "virtual/utm-dialog-watchdog.pid"
$script:WatchdogScriptPath = Join-Path $HOME "virtual/utm-dialog-watchdog.applescript"
$script:WatchdogLogPath    = Join-Path $HOME "virtual/utm-dialog-watchdog.log"

function Stop-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if (-not (Test-Path $script:WatchdogPidFile)) { return }
    if (-not $PSCmdlet.ShouldProcess($script:WatchdogPidFile, 'Stop UTM dialog watchdog')) { return }
    $pidText = (Get-Content $script:WatchdogPidFile -Raw -ErrorAction SilentlyContinue)
    if ($pidText) {
        $pidText = $pidText.Trim()
        if ($pidText -as [int]) {
            & '/bin/kill' $pidText 2>$null | Out-Null
        }
    }
    Remove-Item -LiteralPath $script:WatchdogPidFile -Force -ErrorAction SilentlyContinue
}

function Start-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if (-not $PSCmdlet.ShouldProcess('UTM dialog watchdog', 'Start')) { return }
    # Idempotent: kill any stale watchdog before spawning a new one.
    Stop-UtmDialogWatchdog
    $stateDir = Split-Path -Parent $script:WatchdogPidFile
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Non-destructive accept-label list. Deliberately excludes Cancel /
    # Stop / Quit / Force-Quit etc. so the watchdog never terminates a
    # VM the harness is actively driving.
    $asScript = @'
set acceptLabels to {"Continue", "OK", "Okay", "Run", "Open", "Allow", "Dismiss", "Close", "Ignore"}
repeat
    try
        tell application "System Events"
            tell process "UTM"
                set candidates to {}
                try
                    repeat with w in (every window)
                        repeat with s in (every sheet of w)
                            set end of candidates to s
                        end repeat
                    end repeat
                end try
                try
                    repeat with d in (every window whose subrole is "AXDialog")
                        set end of candidates to d
                    end repeat
                end try
                repeat with c in candidates
                    try
                        repeat with b in (every button of c)
                            if (title of b) is in acceptLabels then
                                click b
                                exit repeat
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        end tell
    end try
    delay 2
end repeat
'@
    Set-Content -LiteralPath $script:WatchdogScriptPath -Value $asScript -NoNewline
    $proc = Start-Process -FilePath '/usr/bin/osascript' `
        -ArgumentList @($script:WatchdogScriptPath) `
        -RedirectStandardOutput $script:WatchdogLogPath `
        -RedirectStandardError  "$($script:WatchdogLogPath).stderr" `
        -PassThru
    $proc.Id | Set-Content -LiteralPath $script:WatchdogPidFile
    Write-Debug "      UTM dialog watchdog started (pid $($proc.Id))"
}

# ── Start VM ─────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Starts a VM that was previously created by New-VM.ps1.
    Returns a hashtable: { success, errorMessage }
#>
function Invoke-StartVM {
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm"       { return Start-UtmVM    -VMName $VMName }
        "host.windows.hyper-v" { return Start-HyperVVM -VMName $VMName }
        default { return @{ success=$false; errorMessage="Unknown host type for Start-VM: $HostType" } }
    }
}

function Start-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$VMName)
    $hostname = $IsMacOS ? (& hostname -s 2>$null).Trim() : (& hostname).Trim()
    $utmBundle = "$HOME/Desktop/Yuruna.VDE/$hostname.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        return @{ success=$false; errorMessage="UTM bundle not found: $utmBundle" }
    }
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start UTM VM')) {
            # Delete any saved vmstate before starting. Apple Virtualization Framework
            # resumes from vmstate if present (instead of cold-booting), which can leave
            # the display in an inconsistent state and produce a blank screen after a
            # prior reboot cycle that UTM interrupted mid-flight.
            $vmstatePath = Join-Path $utmBundle "Data/vmstate"
            if (Test-Path $vmstatePath) {
                Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
                Write-Output "  Removed stale vmstate for '$VMName' — forcing cold boot."
            }
            # Auto-dismiss UTM dialogs while the VM is running.
            # Two classes of unattended popups have to be handled for the
            # harness to run without a human at the keyboard:
            #   (1) IMPORT: "This virtual machine uses custom QEMU arguments
            #       which is potentially dangerous..." — triggered every
            #       time `open $utmBundle` re-imports the bundle. No
            #       plist/UserDefaults/Registry opt-out exists (confirmed
            #       by inspecting UTM's binary and Registry).
            #   (2) RUNTIME: "QEMU error: drive<UUID>, #block<N>: Invalid
            #       argument" — surfaced intermittently by QEMU's block
            #       layer on macOS APFS. The qcow2 change in New-VM.ps1
            #       suppresses the common disk-image cause, but the EFI
            #       pflash (a UTM-managed drive not in config.plist) can
            #       still surface one.
            # A background osascript watchdog covers both: it polls UTM's
            # windows every 2 s and clicks any non-destructive accept
            # button (OK / Continue / Dismiss / Close / etc.). Runs for
            # the duration of the VM cycle. Stop-TestVM kills it by PID.
            # Stale watchdog from a prior cycle is killed before spawn.
            Start-UtmDialogWatchdog
            & open "$utmBundle"
            # Give UTM a moment to process the import + watchdog to click through
            # the custom-args dialog before we ask utmctl to start the VM.
            Start-Sleep -Seconds 3
            & utmctl start "$VMName" 2>&1 | Write-Output
            if ($LASTEXITCODE -ne 0) {
                return @{ success=$false; errorMessage="utmctl start failed for '$VMName' (exit code $LASTEXITCODE)" }
            }
        }
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Failed to start UTM VM '$VMName': $_" }
    }
}

function Start-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$VMName)
    try {
        if ($PSCmdlet.ShouldProcess($VMName, 'Start Hyper-V VM')) {
            Start-VM -Name $VMName -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
            # Open the VM console window in basic mode (no Enhanced Session).
            # This provides a visible window for screenshots and keystroke delivery
            # without requiring guest integration tools inside the VM.
            $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
            if (Test-Path $vmconnect) {
                Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
                Start-Sleep -Seconds 2
                # Auto-dismiss the "Another user is connected" prompt
                # if vmms still tracks a phantom session — without this,
                # the very first vmconnect launch of a test run blocks
                # on a manual "Yes" click. See
                # Resolve-VMConnectAnotherUserDialog for the rationale.
                [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
            }
        }
        return @{ success=$true; errorMessage=$null }
    } catch {
        return @{ success=$false; errorMessage="Start-VM failed for '$VMName': $_" }
    }
}

# ── Stop VM (without destroy) ────────────────────────────────────────────────

<#
.SYNOPSIS
    Stops a running VM without deleting it. Used between per-guest tests
    to avoid one guest's window interfering with another's screenshot.
    Returns $true on success.
#>
function Stop-TestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$HostType, [string]$VMName)
    switch ($HostType) {
        "host.macos.utm" {
            if ($PSCmdlet.ShouldProcess($VMName, 'Stop UTM VM')) {
                # Kill the dialog watchdog first so it doesn't linger after
                # the VM goes away. Start-UtmVM's stale-PID cleanup would
                # reap it on the next cycle anyway, but stopping here keeps
                # the process table tidy and avoids an osascript clicking
                # on an unrelated UTM dialog between cycles.
                Stop-UtmDialogWatchdog
                & utmctl stop "$VMName" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Output "Stopped UTM VM: $VMName"
                    Start-Sleep -Seconds 2
                    return $true
                }
                Write-Warning "utmctl stop failed for '$VMName' (exit $LASTEXITCODE)"
                return $false
            }
            return $true
        }
        "host.windows.hyper-v" {
            if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop Hyper-V VM')) { return $true }
            # Prefer Stop-HyperVVMForce (Test.New-VM.psm1): Stop-VM -TurnOff
            # with a 20 s deadline, then kill vmwp.exe for the VM's GUID if
            # it's still not Off. Plain Stop-VM -TurnOff hangs indefinitely
            # when vmms can't complete a 'Stopping' transition — exactly the
            # stuck test-ubuntu-server-01 case that broke continuous runs
            # even with stopOnFailure=false, because the runner blocked
            # here before it ever got to Remove-TestVM.
            $stopped = $false
            if (Get-Command Stop-HyperVVMForce -ErrorAction SilentlyContinue) {
                try {
                    $stopped = [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
                } catch {
                    Write-Warning "Stop-HyperVVMForce threw for '$VMName': $_"
                    $stopped = $false
                }
            } else {
                # Fallback only — Test.New-VM.psm1 is loaded by
                # Invoke-TestRunner alongside this module, so this branch
                # is reached only when Test.Start-VM is used in isolation.
                try {
                    Stop-VM -Name $VMName -Force -TurnOff -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
                    $stopped = $true
                } catch {
                    Write-Warning "Stop-VM failed for '$VMName': $_"
                    $stopped = $false
                }
            }
            # Close the vmconnect window for this VM regardless — the host
            # window has no value once the VM is off (or being killed).
            Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            if ($stopped) {
                Write-Output "Stopped Hyper-V VM: $VMName"
            } else {
                Write-Warning "Failed to stop Hyper-V VM '$VMName'; Remove-TestVM may take over."
            }
            return $stopped
        }
        default {
            Write-Warning "Unknown host type for Stop-VM: $HostType"
            return $false
        }
    }
}

# ── Verify running ───────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Polls until the VM reaches a running state or the timeout expires.
    After confirming the VM is running, waits an additional BootDelaySeconds
    to allow the guest OS to initialize before any screenshot or test.
    Returns $true on success.
#>
function Confirm-VMStarted {
    param(
        [string]$HostType,
        [string]$VMName,
        [int]$TimeoutSeconds  = 120,
        [int]$BootDelaySeconds = 0
    )
    $running = switch ($HostType) {
        "host.macos.utm"       { Confirm-UtmVMStarted    -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        "host.windows.hyper-v" { Confirm-HyperVVMStarted -VMName $VMName -TimeoutSeconds $TimeoutSeconds }
        default { Write-Error "Unknown host type for start verification: $HostType"; $false }
    }
    if ($running -and $BootDelaySeconds -gt 0) {
        Write-Output "VM is running. Waiting ${BootDelaySeconds}s for guest OS to initialize..."
        Start-Sleep -Seconds $BootDelaySeconds
    }
    return $running
}

function Confirm-UtmVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $output = & utmctl status "$VMName" 2>&1
        if ($output -match "started|running") {
            Write-Output "Verified: UTM VM '$VMName' is running"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "UTM VM '$VMName' did not reach running state within ${TimeoutSeconds}s"
    return $false
}

function Confirm-HyperVVMStarted {
    param([string]$VMName, [int]$TimeoutSeconds = 120)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Output "Verified: Hyper-V VM '$VMName' is running (State: $($vm.State))"
            return $true
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Write-Error "Hyper-V VM '$VMName' did not reach Running state within ${TimeoutSeconds}s"
    return $false
}

# ── Resolve "Another user is connected" dialog (Hyper-V) ────────────────────

<#
.SYNOPSIS
    Auto-dismiss vmconnect's "Another user is connected" prompt.

.DESCRIPTION
    vmconnect surfaces a modal dialog ("Another user is connected to '<VM>'.
    If you continue they will be disconnected. Would you like to connect?")
    whenever vmms still tracks a console session for that VM — typically
    a phantom from a prior crashed vmconnect, or a session opened in a
    different OS user / terminal session that our Get-Process filter
    cannot see and Stop-Process cannot reach. CloseMainWindow on our
    own vmconnect doesn't help: vmms's session state is independent of
    our process. Clicking "Yes" on the dialog tells vmconnect to take
    ownership, which does clear vmms's phantom — so polling for the
    dialog and posting WM_COMMAND IDYES (the "Yes" button activation
    Win32 dialogs respond to) keeps the runner unattended.

    Polls for up to TimeoutSeconds. Returns $true if a dialog was
    dismissed, $false if none appeared (the healthy path).
#>
function Resolve-VMConnectAnotherUserDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 8
    )
    if (-not $IsWindows) { return $false }
    if (-not ('YurunaVMConnectDialog' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class YurunaVMConnectDialog {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hParent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint WM_COMMAND = 0x0111;
    const uint BM_CLICK   = 0x00F5;
    // Standard Win32 dialog button IDs. The "Another user is connected"
    // dialog is a yes/no, so IDYES (6) is the button we want; IDOK (1)
    // is sent as a fallback for any vmconnect dialog that defaults to
    // OK instead of Yes.
    const int IDOK  = 1;
    const int IDYES = 6;

    private static string ChildText(IntPtr hWnd) {
        StringBuilder agg = new StringBuilder();
        EnumChildWindows(hWnd, (h, lp) => {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            agg.Append(sb.ToString()); agg.Append('\n');
            return true;
        }, IntPtr.Zero);
        return agg.ToString();
    }

    public static IntPtr FindDialog(uint[] vmconnectPids, string vmName) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            bool ours = false;
            for (int i = 0; i < vmconnectPids.Length; i++) {
                if (vmconnectPids[i] == pid) { ours = true; break; }
            }
            if (!ours) return true;
            var cls = new StringBuilder(64);
            GetClassName(hWnd, cls, 64);
            // Standard Win32 dialog box class. vmconnect's main window
            // uses a different class ("VMConnectClass" or similar), so
            // this filter excludes the connected-VM window.
            if (cls.ToString() != "#32770") return true;
            // Match the VM name in the dialog body — locale-independent
            // (the VM name is verbatim regardless of UI language).
            if (ChildText(hWnd).IndexOf(vmName, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd; return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Dismiss(IntPtr hWnd) {
        SetForegroundWindow(hWnd);
        System.Threading.Thread.Sleep(120);
        // WM_COMMAND with the button's control ID is what a real Yes
        // click sends to the dialog proc. IDYES handles the "Another
        // user" prompt; IDOK is a belt-and-suspenders for any other
        // affirmative-default vmconnect dialog.
        SendMessage(hWnd, WM_COMMAND, (IntPtr)IDYES, IntPtr.Zero);
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            SendMessage(hWnd, WM_COMMAND, (IntPtr)IDOK, IntPtr.Zero);
        }
        // Final fallback: enumerate child buttons and BM_CLICK any
        // labelled "Yes" / "Connect" / "OK". Covers vmconnect dialogs
        // whose buttons use non-standard control IDs.
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            EnumChildWindows(hWnd, (h, lp) => {
                var cls = new StringBuilder(64);
                GetClassName(h, cls, 64);
                if (string.Equals(cls.ToString(), "Button", StringComparison.OrdinalIgnoreCase)) {
                    var t = new StringBuilder(128);
                    GetWindowText(h, t, 128);
                    string text = t.ToString();
                    if (text.IndexOf("Yes",     StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("Connect", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("OK",      StringComparison.OrdinalIgnoreCase) >= 0) {
                        SendMessage(h, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                    }
                }
                return true;
            }, IntPtr.Zero);
        }
        return true;
    }
}
"@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vmconnectPids = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
            ForEach-Object { [uint32]$_.Id })
        if ($vmconnectPids.Count -gt 0) {
            $hWnd = [YurunaVMConnectDialog]::FindDialog([uint32[]]$vmconnectPids, $VMName)
            if ($hWnd -ne [IntPtr]::Zero) {
                Write-Information "    Auto-dismissing vmconnect 'Another user is connected' dialog for '$VMName'"
                [void][YurunaVMConnectDialog]::Dismiss($hWnd)
                Start-Sleep -Milliseconds 600
                return $true
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# ── Reconnect vmconnect ──────────────────────────────────────────────────────

<#
.SYNOPSIS
    Refreshes the VM display connection to recover from a blank screen.

    Hyper-V: closes and reopens the vmconnect window, forcing a full
    framebuffer refresh. After a host reboot vmconnect sometimes fails to
    repaint; reconnecting fixes it. Auto-dismisses vmconnect's "Another
    user is connected" prompt if it appears (see
    Resolve-VMConnectAnotherUserDialog).

    UTM (macOS): activates the UTM application via AppleScript, which
    forces the display window to the front and triggers a Metal repaint.
    This is a best-effort nudge; the authoritative fix for the
    simpledrm -> virtio-gpu KMS race is nomodeset in the guest GRUB config
    (applied by ubuntu.desktop.update.sh).
#>
function Restart-VMConnect {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType, [string]$VMName)

    switch ($HostType) {
        "host.macos.utm" {
            if (-not $PSCmdlet.ShouldProcess($VMName, 'Activate UTM display window')) { return }
            # Bring UTM to the foreground. This forces the SwiftUI Metal view
            # to repaint, which recovers a stale framebuffer after a guest reboot.
            & osascript -e 'tell application "UTM" to activate' 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            Write-Information "    Activated UTM window for '$VMName' (display repaint)"
        }
        "host.windows.hyper-v" {
            $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
            if (-not (Test-Path $vmconnect)) { return }
            if (-not $PSCmdlet.ShouldProcess($VMName, 'Reconnect vmconnect')) { return }
            # Close any existing vmconnect window for this VM gracefully.
            # Force-killing (Stop-Process -Force) bypasses WM_CLOSE so vmconnect
            # never tells vmms to release its console session — the next
            # vmconnect launch then trips "Another user is already connected
            # to this virtual machine" and blocks the runner on a manual
            # "Connect anyway" click. CloseMainWindow lets the session
            # release cleanly; force-kill is only a fallback for an
            # unresponsive window.
            $existing = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) })
            foreach ($p in $existing) {
                try { [void]$p.CloseMainWindow() } catch { Write-Verbose "CloseMainWindow failed for vmconnect pid $($p.Id): $_" }
            }
            foreach ($p in $existing) {
                if (-not $p.WaitForExit(3000)) {
                    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "Force-kill of vmconnect pid $($p.Id) failed: $_" }
                }
            }
            # Give vmms a few seconds to drop the console session before
            # reopening. Reopening too quickly reproduces the "another user
            # is connected" dialog even after a clean CloseMainWindow.
            if ($existing.Count -gt 0) { Start-Sleep -Seconds 3 }
            # Reopen the console
            Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
            Start-Sleep -Seconds 2
            # vmms can still report a phantom session even after a clean
            # close (e.g. a vmconnect from another OS user / terminal
            # session that our process filter never saw). Auto-click
            # "Yes" on the "Another user is connected" prompt so the
            # runner stays unattended; no-op when no dialog appears.
            [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
            Write-Information "    Reconnected vmconnect for '$VMName'"
        }
    }
}

Export-ModuleMember -Function Invoke-StartVM, Stop-TestVM, Confirm-VMStarted, Restart-VMConnect
