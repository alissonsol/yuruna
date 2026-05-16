<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456701
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Module-level self-healing: re-import Test.VM.common.psm1 with -Global
# every time Test.Host is loaded. The runner's cycle re-import block
# reloads Test.Host every cycle; doing the -Global import here keeps
# Wait-VMRunning / Test-IpAddress / Format-IpUrlHost (and the other
# cross-host helpers) in the runner's session even when something
# mid-cycle has wiped the global module table -- e.g. a sequence step
# calling `Get-Module | Remove-Module`, or a transitive Import-Module
# without -Global. Without this, a long-running macOS in-process runner
# could lose Wait-VMRunning at an unrelated moment and crash at the
# next New-VM.Resource step. -ErrorAction SilentlyContinue: a missing sibling
# is non-fatal here; Initialize-YurunaHost still fails loudly later if
# truly broken.
$vmCommonPath = Join-Path $PSScriptRoot 'Test.VM.common.psm1'
if (Test-Path $vmCommonPath) {
    Import-Module $vmCommonPath -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
}

function Get-HostType {
    <#
    .SYNOPSIS
    Returns "host.macos.utm", "host.windows.hyper-v", or "host.ubuntu.kvm"
    based on the current platform.
    #>
    # Platform is invariant for the process lifetime; cache the first
    # detection so the per-cycle ~7+ callers don't each pay the
    # Get-Service vmms / Test-Path /dev/kvm cost. As a side benefit the
    # warning fires at most once per process instead of per call.
    if ($script:CachedHostType) { return $script:CachedHostType }
    if ($IsMacOS) {
        if (-not (Test-Path "/Applications/UTM.app")) {
            Write-Warning "Running on macOS but UTM not found at /Applications/UTM.app."
        }
        $script:CachedHostType = "host.macos.utm"
        return $script:CachedHostType
    }
    if ($IsWindows) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Running on Windows but Hyper-V service (vmms) not found."
        }
        $script:CachedHostType = "host.windows.hyper-v"
        return $script:CachedHostType
    }
    if ($IsLinux) {
        # Ubuntu / Debian + KVM/libvirt is the only Linux flavor wired into
        # the harness today. Warn (don't fail) if libvirt isn't installed
        # yet -- the installer (install/ubuntu.kvm.sh) creates the missing
        # bits and a fresh install legitimately runs Get-HostType before
        # libvirtd is up.
        if (-not (Test-Path '/dev/kvm')) {
            Write-Warning "Running on Linux but /dev/kvm missing (kvm.ko not loaded or VT-x/SVM disabled)."
        }
        $script:CachedHostType = "host.ubuntu.kvm"
        return $script:CachedHostType
    }
    Write-Error "Unsupported platform. Only macOS (UTM), Windows (Hyper-V), and Linux (KVM/libvirt) are supported."
    return $null
}

function Get-HostFolder {
    <#
    .SYNOPSIS
    Maps a HostType identifier to its repo-relative folder path.
    .DESCRIPTION
    HostType is the stable identifier (e.g. "host.windows.hyper-v") used by
    test sequences and extension scripts. The on-disk layout is
    "host/<short-name>/" -- strip the "host." prefix and join under "host/".
    #>
    param([Parameter(Mandatory)] [string]$HostType)
    return "host/$($HostType -replace '^host\.','')"
}

function Invoke-LibvirtGroupReExecIfNeeded {
    <#
    .SYNOPSIS
    On host.ubuntu.kvm, auto-relaunch the calling script under
    `sg libvirt -c "..."` when the parent shell's running supplementary
    group set lacks 'libvirt'. Returns silently when no re-exec is
    needed; calls exit and never returns when it does re-exec.

    .DESCRIPTION
    `sudo usermod -aG libvirt $USER` updates /etc/group but does NOT
    refresh the parent shell's effective group set; on systemd-logind
    systems with user lingering, even a desktop logout/login often
    doesn't either. Without libvirt in the effective set, every
    virsh / virt-install call fails with "Permission denied" on
    /var/run/libvirt/libvirt-sock. `sg libvirt -c "..."` spawns a
    subshell that calls initgroups() fresh -- libvirt is then in the
    effective set, and any pwsh child processes (Start-Process pwsh in
    Invoke-TestRunner, virt-install in New-VM, etc.) inherit it
    naturally. install/ubuntu.kvm.sh uses the same trick when invoking
    Remove-TestVMFiles.ps1 from the installer; this function brings
    the same recovery to standalone operator invocations of every
    libvirt-touching script.

    Short-circuits when ANY of:
      * not on host.ubuntu.kvm (other hosts don't have this group issue)
      * caller already inside an sg subshell (YURUNA_SG_RELAUNCH=1)
      * libvirt already in the running supplementary group set
      * user not in libvirt per /etc/group (re-exec wouldn't help;
        Assert-HostConditionSet / Test-HostRequirement will report the
        actual install-time error)
      * sg binary not present (no automatic recovery available)

    YURUNA_SG_RELAUNCH is passed INLINE inside the `sg -c "..."` shell
    command so it lives only in the sg subshell. Setting
    `$env:YURUNA_SG_RELAUNCH = '1'` here would mutate the CURRENT
    pwsh process's environment, which then leaks back to the
    operator's interactive `PS> ` prompt -- every subsequent
    invocation in the same pwsh session would skip the re-exec and
    fail on libvirt-sock again. (Discovered the hard way: the original
    inline implementation in Remove-TestVMFiles.ps1 worked on the first
    call but failed every call after that until the session was closed.)

    .PARAMETER HostType
        Result of Get-HostType. Helper short-circuits when not Ubuntu KVM.

    .PARAMETER ScriptPath
        Full path to the running script -- caller passes $PSCommandPath
        (or $MyInvocation.MyCommand.Path on older pwsh). Forwarded to
        the re-exec'd pwsh via `-File`.

    .PARAMETER BoundParameters
        $PSBoundParameters from the calling script. Forwarded verbatim
        so explicit args survive the relaunch. Supported types in the
        affected scripts: [string], [int], [double], [switch] -- no
        complex types (arrays/hashtables) appear in any current entry
        point's param block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{}
    )

    if ($HostType -ne 'host.ubuntu.kvm')                       { return }
    if ($env:YURUNA_SG_RELAUNCH)                               { return }
    $activeGroups = (& id -nG 2>$null) -split '\s+'
    if ($activeGroups -contains 'libvirt')                     { return }
    $libvirtLine    = & getent group libvirt 2>$null
    $libvirtMembers = if ($libvirtLine) { (($libvirtLine -split ':',4)[3]) -split ',' } else { @() }
    if ($libvirtMembers -notcontains $env:USER)                { return }
    if (-not (Get-Command sg -ErrorAction SilentlyContinue))   { return }

    $scriptName = Split-Path -Leaf $ScriptPath
    Write-Output "This shell's group set predates 'libvirt' membership -- re-launching '$scriptName' under 'sg libvirt'."

    # Build the forwarded-args string for bash. Single-quote each value
    # and escape internal single quotes via the classic bash idiom
    # 'foo' + \' + 'bar' (a closing quote, an escaped quote, a reopening
    # quote). Switches emit "-Name" only when .IsPresent.
    $argParts = @()
    foreach ($key in $BoundParameters.Keys) {
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argParts += "-$key" }
        } else {
            $escaped = "$val" -replace "'", "'\''"
            $argParts += "-$key '$escaped'"
        }
    }
    $argString     = if ($argParts.Count -gt 0) { ' ' + ($argParts -join ' ') } else { '' }
    $scriptEscaped = $ScriptPath -replace "'", "'\''"

    & sg libvirt -c "YURUNA_SG_RELAUNCH=1 pwsh -NoLogo -NoProfile -File '$scriptEscaped'$argString"
    exit $LASTEXITCODE
}

function Initialize-YurunaHost {
    <#
    .SYNOPSIS
    Imports the matching host driver (host/<host>/modules/Yuruna.Host.psm1)
    so test/ orchestration can call interface functions without HostType
    branches.
    .DESCRIPTION
    Determines the current host via Get-HostType, builds the absolute
    path to its Yuruna.Host.psm1, and imports it with -Global so every
    test/ caller (Invoke-TestRunner.ps1, Confirm-Sequence.ps1,
    sequence extensions, etc.) resolves the interface names directly.

    The driver's New-VM/Start-VM/Stop-VM/Get-VM/Remove-VM exports shadow
    Hyper-V's same-named cmdlets in the runner's session -- intentional;
    callers want the harness contract, and the driver's body uses
    module-qualified Hyper-V\... calls when it needs to talk to the
    underlying cmdlet.

    Idempotent: Import-Module -Force re-loads the driver if the file
    changes, otherwise no-ops.
    .PARAMETER RepoRoot
    Absolute path to the repo root (parent of host/ and test/). The
    runner already resolves this; pass it in to avoid re-deriving.
    .PARAMETER HostType
    Optional override for the host identifier; default is Get-HostType.
    Used by tests that simulate other hosts.
    .OUTPUTS
    [string] -- absolute path to the imported Yuruna.Host.psm1, or
    throws if the file is missing for the current host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$HostType
    )
    if (-not $HostType) { $HostType = Get-HostType }
    $hostFolderRel = Get-HostFolder -HostType $HostType
    $modulePath    = Join-Path $RepoRoot (Join-Path $hostFolderRel 'modules/Yuruna.Host.psm1')
    if (-not (Test-Path $modulePath)) {
        throw "Yuruna.Host.psm1 not found for $HostType (looked at $modulePath). Cannot dispatch host operations."
    }
    Import-Module $modulePath -Force -DisableNameChecking -Global
    # Test.VM.common.psm1 holds host-agnostic test helpers (Wait-VMRunning,
    # ...) that build on the host driver's contract. Imported alongside
    # the driver so callers can rely on either set without a separate
    # bootstrap step.
    $vmCommonPath = Join-Path $RepoRoot 'test/modules/Test.VM.common.psm1'
    if (Test-Path $vmCommonPath) {
        Import-Module $vmCommonPath -Force -DisableNameChecking -Global
    }
    Write-Verbose "Initialize-YurunaHost: imported $modulePath"
    return $modulePath
}

function Get-GuestList {
    <#
    .SYNOPSIS
    Returns the ordered list of guest keys from $Config.guestSequence.
    .DESCRIPTION
    Returns verbatim — whether a guest is implemented on the current
    host is decided at runtime by Test-GuestFolder; the runner logs a
    per-guest failure for missing folders. Replaces the old hardcoded
    allow-list. Empty/missing guestSequence returns an empty list with a warning.
    #>
    param([System.Collections.IDictionary]$Config = @{})

    if ($Config.guestSequence -and $Config.guestSequence.Count -gt 0) {
        return @($Config.guestSequence)
    }

    Write-Warning "test.config.yml has no 'guestSequence' entries — nothing to run."
    return @()
}

function Test-GuestFolder {
    <#
    .SYNOPSIS
    Returns $true when the guest's scripts folder exists for a host.
    .DESCRIPTION
    Layout: <repo>/host/<short-host>/<guestKey>/ holds Get-Image.ps1 and
    New-VM.ps1 for that host+guest. Guest is available on a host iff
    the folder exists. guestSequence can legitimately name host-specific
    guests; callers treat missing folder as a per-guest failure, not a
    config error.
    #>
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$HostType,
        [Parameter(Mandatory)] [string]$GuestKey
    )
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    return (Test-Path -Path $folder -PathType Container)
}

function Get-TestVMName {
    <#
    .SYNOPSIS
    Derives the test VM name from guest key + prefix.
    .DESCRIPTION
    Strip "guest.", replace remaining dots with hyphens, append "-01",
    add the prefix. Examples with prefix "test-":
        guest.ubuntu.server  →  test-ubuntu-server-01
        guest.amazon.linux   →  test-amazon-linux-01
        guest.windows.11     →  test-windows-11-01
    Any guest key produces a deterministic VM name without code changes.
    Migration note: pre-2026-04 harness used "test-amazon-linux01",
    "test-windows11-01". VMs from the old convention are orphaned
    (Remove-TestVM keys off the new name); clean them up once with
    `Get-VM test-* | Remove-VM` on Hyper-V or `utmctl list | grep test-`
    on UTM.
    #>
    param(
        [Parameter(Mandatory)] [string]$GuestKey,
        [string]$Prefix = "test-"
    )
    $stem = ($GuestKey -replace '^guest\.', '') -replace '\.', '-'
    return "${Prefix}${stem}-01"
}

function Test-ElevationRequired {
    <#
    .SYNOPSIS
    Returns $true if the host type requires Administrator elevation.
    #>
    param([string]$HostType)
    return ($HostType -eq "host.windows.hyper-v")
}

function Assert-Elevation {
    <#
    .SYNOPSIS
    Checks elevation if required. Returns $false and writes an error if elevation is needed but absent.
    #>
    param([string]$HostType)
    if (-not (Test-ElevationRequired -HostType $HostType)) { return $true }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "host.windows.hyper-v requires elevation. Re-run Invoke-TestRunner.ps1 as Administrator."
        return $false
    }
    return $true
}

function Test-HostRequirement {
    <#
    .SYNOPSIS
        Fast, run-anywhere pre-flight. Returns $true only when the
        absolute minimum needed to call this host's VM cmdlets is in
        place (Administrator on Windows + vmms running, virsh + /dev/kvm
        on Ubuntu, utmctl + UTM.app on macOS). On failure, prints
        Write-Warning lines explaining what is missing and how to fix
        it, and ALWAYS surfaces a Write-Information pointer to
        Test-Config.ps1 for a deeper host-health report.
    .DESCRIPTION
        Called at the top of every operator-facing helper that touches
        host VMs (Remove-TestVMFiles.ps1, ...) so an elevation-missing
        run on Hyper-V fails fast with an actionable message instead of
        dying inside the first cmdlet with the bare "You do not have
        the required permission..." that Hyper-V\Get-VM emits. The
        actual failure observed on ALIUS-ALIEN01 was a non-elevated
        run of Remove-TestVMFiles.ps1: Hyper-V\Get-VM at line 67 threw
        before any user-friendly check had been reached.
        Intentionally lighter than Assert-HostConditionSet (which also
        fails on display-sleep / screen-lock settings); those checks
        belong to the long-running test runner, not to cleanup helpers
        that an operator may legitimately invoke during a maintenance
        window with the screen unlocked.
    .OUTPUTS
        [bool] -- $true when the minimum is met, $false otherwise.
        Never throws; the caller decides whether to exit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$HostType)

    $ok = $true

    switch ($HostType) {
        'host.windows.hyper-v' {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
            if (-not $isAdmin) {
                Write-Warning "host.windows.hyper-v requires Administrator. Re-run this script from an elevated PowerShell -- without elevation, Hyper-V cmdlets (Get-VM/Stop-VM/Remove-VM) fail with 'You do not have the required permission...' before any friendlier check can run."
                $ok = $false
            }
            $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
            if (-not $svc) {
                Write-Warning "Hyper-V Virtual Machine Management service (vmms) is not installed. Enable Hyper-V from an elevated PowerShell: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All  (then reboot)."
                $ok = $false
            } elseif ($svc.Status -ne 'Running') {
                Write-Warning "Hyper-V Virtual Machine Management service (vmms) is not running. Start it from an elevated PowerShell: Start-Service vmms"
                $ok = $false
            }
        }
        'host.ubuntu.kvm' {
            if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
                Write-Warning "virsh not found on PATH. Install libvirt + QEMU: sudo apt install libvirt-clients libvirt-daemon-system qemu-kvm"
                $ok = $false
            }
            if (-not (Test-Path '/dev/kvm')) {
                Write-Warning "/dev/kvm missing -- kvm.ko not loaded or VT-x/SVM disabled in firmware. Enable hardware virtualization in BIOS/UEFI and load the kvm kernel module."
                $ok = $false
            }
        }
        'host.macos.utm' {
            if (-not (Test-Path '/Applications/UTM.app')) {
                Write-Warning "/Applications/UTM.app not found. Install UTM from https://mac.getutm.app."
                $ok = $false
            }
            if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
                Write-Warning "utmctl not found on PATH. The UTM.app bundle ships it at /Applications/UTM.app/Contents/MacOS/utmctl -- symlink it into /usr/local/bin or rerun host/macos.utm/Enable-TestAutomation.ps1."
                $ok = $false
            }
        }
        default {
            Write-Warning "Unknown host type '$HostType' -- skipping requirements check."
        }
    }

    # Always surface the pointer so an operator running a one-off helper
    # learns there is a richer health report available, even when the
    # quick check just passed. -InformationAction Continue so the line
    # shows without the caller having to set $InformationPreference.
    Write-Information "There may be more host-health recommendations available. For a deeper report (config files, transports, framework/project staleness, RAM/CPU, host-specific feature state) run: pwsh test/Test-Config.ps1" -InformationAction Continue

    return $ok
}

function Assert-ScreenLock {
    <#
    .SYNOPSIS
    macOS: verify screen saver lock and display sleep won't blank the
    screen during long-running VM tests. Returns $true if settings are
    acceptable (or not on macOS). Prints instructions and returns $false
    otherwise.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    $issues = @()

    # 1. Display sleep idle time (pmset -g custom → displaysleep).
    #    0 = never sleep (good); > 0 means display will blank.
    try {
        $pmsetLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        if ($pmsetLine -and $pmsetLine.Matches[0].Groups[1].Value -ne "0") {
            $sleepMin = $pmsetLine.Matches[0].Groups[1].Value
            $issues += "Display sleep is set to $sleepMin minute(s)."
        }
    } catch {
        Write-Debug "pmset check failed: $_"
    }

    # 2. Screen saver idleTime (defaults read com.apple.screensaver idleTime).
    #    0 = disabled. A MISSING key is NOT safe — macOS falls back to
    #    a built-in default (~1200s), which lets the screensaver engage
    #    after 20 min despite the script reporting "already disabled".
    #    Flag both missing AND non-zero. Check per-host domain too;
    #    either being unsafe engages the saver.
    try {
        $idleTime     = & defaults read              com.apple.screensaver idleTime 2>$null
        $idleTimeHead = $LASTEXITCODE
        $idleTimeHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
        $idleTimeHostHead = $LASTEXITCODE
        if ($idleTimeHead -ne 0) {
            $issues += "Screen saver idleTime is unset (user domain) — macOS default applies (~20 min)."
        } elseif ("$idleTime".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTime.Trim()) second(s) (user domain)."
        }
        if ($idleTimeHostHead -ne 0) {
            $issues += "Screen saver idleTime is unset (currentHost) — macOS default applies (~20 min)."
        } elseif ("$idleTimeHost".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTimeHost.Trim()) second(s) (currentHost)."
        }
    } catch {
        Write-Debug "Screen saver check failed: $_"
    }

    # 3. Password after screen saver (askForPassword). Missing key on
    #    some macOS versions defaults to 1 (on) — flag missing AND
    #    explicit 1. Check both domains.
    try {
        $askPw     = & defaults read              com.apple.screensaver askForPassword 2>$null
        $askPwHead = $LASTEXITCODE
        $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
        $askPwHostHead = $LASTEXITCODE
        if ($askPwHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (user domain) — macOS default may be 1."
        } elseif ("$askPw".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (user domain)."
        }
        if ($askPwHostHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (currentHost) — macOS default may be 1."
        } elseif ("$askPwHost".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (currentHost)."
        }
    } catch {
        Write-Debug "Screen lock password check failed: $_"
    }

    # 4. Hot corners bound to Start Screen Saver / Sleep Display / Lock
    #    Screen. A drifting cursor during an unattended run can trigger
    #    these and drop the UTM window from CGWindowList.
    try {
        $dangerousCorners = @{ '5' = 'Start Screen Saver'; '10' = 'Put Display to Sleep'; '13' = 'Lock Screen' }
        foreach ($corner in @('tl','tr','bl','br')) {
            $val = & defaults read com.apple.dock "wvous-$corner-corner" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $valTrim = "$val".Trim()
                if ($dangerousCorners.ContainsKey($valTrim)) {
                    $issues += "Hot corner '$corner' triggers '$($dangerousCorners[$valTrim])'."
                }
            }
        }
    } catch {
        Write-Debug "Hot-corner check failed: $_"
    }

    # 5. App Nap suppressed for UTM.app — else macOS throttles UTM's UI
    #    thread and drops its window from CGWindowList even while the VM
    #    runs. Matches "UTM window for '<vm>' not found" symptom.
    try {
        $nap = & defaults read com.utmapp.UTM NSAppSleepDisabled 2>$null
        if ($LASTEXITCODE -ne 0 -or "$nap".Trim() -ne '1') {
            $issues += "App Nap is not suppressed for UTM.app (com.utmapp.UTM NSAppSleepDisabled not set to 1)."
        }
    } catch {
        Write-Debug "App Nap check failed: $_"
    }

    # 6. sysadminctl unified screen lock (Ventura+). Overrides legacy
    #    askForPassword* keys — the machine can still lock even when
    #    every individual defaults key is "safe". Accepted "disabled"
    #    forms from sysadminctl -screenLock status:
    #      • "screenLock delay is -1(.000000) seconds"
    #      • "screenLock is off"
    #    Anything else (e.g. "delay is 300 seconds") means a lock delay is active.
    try {
        # Strip macOS NSLog prefix ("YYYY-MM-DD ... sysadminctl[pid:tid] ")
        # so the match and user-facing message are clean.
        $slStatus = (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1) -replace '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+sysadminctl\[\d+:\w+\]\s+', ''
        $slDisabled = ("$slStatus" -match 'screenLock\s+(is\s+off|delay\s+is\s+-1)')
        if (-not $slDisabled) {
            $issues += "sysadminctl $slStatus"
        }
    } catch {
        Write-Debug "sysadminctl -screenLock check failed: $_"
    }

    # 7. Auto-logout after inactivity ("Log out after N minutes" in
    #    Security / Advanced). Kicks user to loginwindow — same
    #    password-demand symptom as a lock. System-level pref;
    #    world-readable, no sudo.
    try {
        $autoLogout = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
        if ($LASTEXITCODE -eq 0 -and "$autoLogout".Trim() -ne "0") {
            $issues += "Auto-logout is active after $($autoLogout.Trim())s of inactivity (AutoLogOutDelay)."
        }
    } catch {
        Write-Debug "AutoLogOutDelay check failed: $_"
    }

    if ($issues.Count -eq 0) { return $true }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Screen lock / display sleep settings will blank the VM display."
    Write-Warning ""
    foreach ($issue in $issues) {
        Write-Warning "  • $issue"
    }
    Write-Warning ""
    Write-Warning " When the display blanks, UTM screen captures return a black"
    Write-Warning " image and OCR-based waitForText steps will time out."
    Write-Warning ""
    Write-Warning " Quick fix — run from the repo root:"
    Write-Warning "   pwsh ./host/macos.utm/Enable-TestAutomation.ps1"
    Write-Warning ""
    Write-Warning " Or manually in System Settings:"
    Write-Warning "   1. Displays > Advanced > Prevent automatic sleeping when"
    Write-Warning "      the display is off  → ON"
    Write-Warning "   2. Lock Screen > Start Screen Saver when inactive → Never"
    Write-Warning "   3. Lock Screen > Require password after screen saver → OFF"
    Write-Warning "   4. Energy > Turn display off → Never  (or run:"
    Write-Warning "        sudo pmset -c displaysleep 0"
    Write-Warning "        sudo pmset -b displaysleep 0 )"
    Write-Warning "═══════════════════════════════════════════════════════════════════"
    return $false
}

function Initialize-SudoCache {
<#
.SYNOPSIS
    Prime the sudo credential cache once, with a friendly notice, so a
    long sequence of subsequent sudo calls runs without re-prompting.
.DESCRIPTION
    Host-prep PowerShell scripts (Set-MacHostConditionSet, the per-host
    Enable-TestAutomation.ps1 family) make many sudo invocations in
    succession -- pmset, defaults write /Library/Preferences,
    sysadminctl, systemctl, virsh net-*. With a default macOS / Linux
    sudoers config those share a per-tty timestamp that lasts ~5 min,
    so a single `sudo -v` up front is enough to keep the rest silent.
    Without this, the operator sees "[sudo] password for ..." on every
    individual call -- the symptom that drove this helper.

    Idempotent: if `sudo -n true` already succeeds (cache warm because
    the install/<host>.sh wrapper primed it, or a prior call in this
    pwsh process already cached), the function returns silently with no
    output and no prompt. Skipped entirely when running as root.

    Designed to be called at the very top of any PowerShell script /
    function that will make multiple sudo calls in a row.
.PARAMETER Reasons
    One-line descriptions of what the caller will do with sudo. Printed
    inside a fenced box just above the password prompt so the operator
    knows why they are being asked. Empty array prints a generic notice.
.OUTPUTS
    [bool] $true on success (cache is now warm or no elevation needed),
    $false on failure (sudo missing, user cancelled, wrong password).
    Never throws -- callers decide whether to proceed.
.EXAMPLE
    if (-not (Initialize-SudoCache -Reasons @('pmset display sleep', 'defaults write /Library/Preferences'))) {
        throw "Cannot proceed without sudo."
    }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Reasons = @()
    )
    # Windows has no sudo (UAC is a different model); only run on macOS / Linux.
    if (-not ($IsLinux -or $IsMacOS)) { return $true }
    # Already root: no sudo needed.
    try {
        $uid = (& '/usr/bin/id' -u 2>$null)
        if ("$uid".Trim() -eq '0') { return $true }
    } catch {
        Write-Verbose "Initialize-SudoCache: id command unavailable -- assuming non-root and proceeding."
    }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        Write-Warning "Initialize-SudoCache: sudo not on PATH; downstream elevation will fail."
        return $false
    }
    # Cache already warm? Silent fast path -- no notice, no prompt.
    & sudo -n true 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # Wrapper-primed mode: install/<host>.sh already showed the "ONCE"
    # notice AND ran a "sudo prelude" that pre-applied every value
    # Set-MacHostConditionSet would otherwise need sudo for. The pwsh
    # paths that follow are idempotent -- they read state without sudo
    # and only call sudo if a value still needs writing. In the common
    # case after the prelude, NO downstream sudo calls fire, so a
    # preemptive `sudo -v` here would prompt the operator for nothing.
    # Return $false silently and let the rare downstream call (e.g.
    # sysadminctl on a brand-new machine) trigger its own prompt at
    # the moment it's actually needed -- that prompt is at least tied
    # to a visible operation, not a "phantom" elevation.
    if ($env:YURUNA_SUDO_PRIMED -eq '1') {
        return $false
    }
    # Cache cold AND no wrapper context: print the friendly notice, then prompt.
    Write-Output ""
    Write-Output "  +---------------------------------------------------------------+"
    Write-Output "  | This script needs sudo for:                                   |"
    if ($Reasons.Count -gt 0) {
        foreach ($r in $Reasons) {
            $line = "    * $r"
            if ($line.Length -gt 63) { $line = $line.Substring(0, 60) + '...' }
            Write-Output ("  | {0,-61} |" -f $line)
        }
    } else {
        Write-Output "  |     (host configuration commands)                             |"
    }
    Write-Output "  | You will be prompted for your password ONCE, below.           |"
    Write-Output "  +---------------------------------------------------------------+"
    Write-Output ""
    & sudo -v
    return ($LASTEXITCODE -eq 0)
}

function Set-MacHostConditionSet {
    <#
    .SYNOPSIS
    Configures macOS host settings needed for unattended VM testing:
    disables display sleep, screen saver idle, and screen lock password;
    triggers first-run prompts for the Accessibility and Screen Recording
    TCC permissions (both required — keystroke injection + per-window
    capture). Requires sudo for pmset. Idempotent.
    .EXAMPLE
    Set-MacHostConditionSet          # apply all settings
    Set-MacHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsMacOS) {
        Write-Warning "Set-MacHostConditionSet is only supported on macOS."
        return
    }

    # ── 0. Sudo cache + wrapper-primed contract ─────────────────────────
    # When invoked from install/macos.utm.sh, $env:YURUNA_SUDO_PRIMED='1'
    # signals that the bash wrapper already ran a "sudo prelude" -- one
    # batched `sudo bash -c '...'` covering every pmset / defaults write
    # this function would otherwise need sudo for. In that mode pwsh
    # MUST NOT call sudo for any of those writes: the bash sudo cache
    # may have been invalidated by a brew cask post-install (`sudo -k`)
    # or a Touch ID quirk by now, and a `sudo` here would re-prompt the
    # operator -- breaking the "ONCE" promise the wrapper printed.
    # If a value still doesn't read as wanted, warn and continue rather
    # than re-doing the work.
    #
    # When invoked standalone (no wrapper), behave as before: prime
    # sudo with the friendly box and run every block normally.
    $wrapperPrimed = ($env:YURUNA_SUDO_PRIMED -eq '1')
    if (-not $wrapperPrimed) {
        # This function makes ~16 sudo invocations across pmset, sysadminctl,
        # and defaults at /Library/Preferences. macOS sudo's default per-tty
        # 5-min timestamp covers all of them after a single up-front `sudo -v`.
        # The friendly notice only appears when the cache is genuinely cold.
        [void](Initialize-SudoCache -Reasons @(
            'pmset (display sleep, system sleep, power-nap, hibernation)',
            'defaults write /Library/Preferences (auto-logout delay)',
            'sysadminctl -screenLock off (Sonoma+ unified screen lock)'
        ))
    }

    # ── 1. Display sleep → Never (requires sudo) ─────────────────────────
    $changed = $false
    foreach ($source in @("-c", "-b")) {   # -c charger, -b battery
        $pmLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        # pmset -g custom shows the active profile; set both unconditionally —
        # harmless if -b doesn't exist.
    }
    # Current AC value
    $currentSleep = "unknown"
    $pmLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
    if ($pmLine) { $currentSleep = $pmLine.Matches[0].Groups[1].Value }

    if ($currentSleep -ne "0") {
        if ($wrapperPrimed) {
            Write-Warning "Display sleep is '$currentSleep' (expected 0). Run 'sudo pmset -c displaysleep 0; sudo pmset -b displaysleep 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("Display sleep (currently $currentSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting display sleep to Never (AC and battery)..."
            & sudo pmset -c displaysleep 0
            & sudo pmset -b displaysleep 0
            $changed = $true
        }
    } else {
        Write-Information "Display sleep is already set to Never."
    }

    # ── 2. Screen saver idle time → 0 (disabled) ─────────────────────────
    # MISSING idleTime key is NOT the same as 0: macOS falls back to
    # ~1200s built-in default. The old "exit 0 AND value != 0" check
    # skipped the write when absent and printed "already disabled",
    # letting the screensaver engage after ~20min. Skip write only when
    # the key EXISTS and is exactly "0"; any other case (missing, empty,
    # other number) triggers an explicit write.
    $ssIdle = & defaults read com.apple.screensaver idleTime 2>$null
    $ssIdleRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleRead -and "$ssIdle".Trim() -eq "0") {
        Write-Information "Screen saver idle activation is already disabled."
    } else {
        $label = if (-not $ssIdleRead) { 'unset — macOS default applies' } else { "$($ssIdle.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation (was $label)..."
            & defaults write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    }

    # ── 3. Screen lock (password after screen saver) → OFF ───────────────
    # Same "missing key != safe" as §2: some macOS versions default
    # askForPassword to 1. Write 0 unless the key is explicitly "0".
    $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
    $askPwRead = ($LASTEXITCODE -eq 0)
    if ($askPwRead -and "$askPw".Trim() -eq "0") {
        Write-Information "Screen lock password is already disabled."
    } else {
        $label = if (-not $askPwRead) { 'unset — macOS default applies' } else { "$($askPw.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password (currently $label)", "Disable (askForPassword → 0)")) {
            Write-Information "Disabling screen lock password requirement (was $label)..."
            & defaults write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    }

    # ── 2b. Screen saver idle — per-host variant (Ventura+) ──────────────
    # Modern macOS stores screensaver prefs in the ByHost domain. Without
    # this, System Settings still shows non-zero idle time after §2 and
    # the saver still kicks in. Same missing-key-is-unsafe logic as §2.
    $ssIdleHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
    $ssIdleHostRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleHostRead -and "$ssIdleHost".Trim() -eq "0") {
        Write-Information "Screen saver idle activation (currentHost) is already disabled."
    } else {
        $label = if (-not $ssIdleHostRead) { 'unset — macOS default applies' } else { "$($ssIdleHost.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time [currentHost] (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver idleTime -int 0
            $changed = $true
        }
    }

    # ── 3b. Screen lock password — per-host variant ─────────────────────
    # Same missing-key-is-unsafe logic as §3.
    $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
    $askPwHostRead = ($LASTEXITCODE -eq 0)
    if ($askPwHostRead -and "$askPwHost".Trim() -eq "0") {
        Write-Information "Screen lock password (currentHost) is already disabled."
    } else {
        $label = if (-not $askPwHostRead) { 'unset — macOS default applies' } else { "$($askPwHost.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password [currentHost] (currently $label)", "Disable (askForPassword → 0)")) {
            Write-Information "Disabling screen lock password requirement, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver askForPassword -int 0
            $changed = $true
        }
    }

    # ── 3c. "Require password after sleep/screen saver begins" delay ─────
    # Sonoma+ lock-screen pane. A very large delay prevents lock from
    # engaging even if something re-enables askForPassword.
    & defaults write com.apple.screensaver askForPasswordDelay -int 2147483647 2>$null | Out-Null
    & defaults -currentHost write com.apple.screensaver askForPasswordDelay -int 2147483647 2>$null | Out-Null

    # ── 3d. System sleep → Never (requires sudo) ─────────────────────────
    # Display-sleep alone isn't enough: system sleep → display locks on
    # wake regardless of screensaver settings.
    $currentSysSleep = "unknown"
    $sysLine = & pmset -g custom 2>$null | Select-String '^\s*[^d]\s*sleep\s+(\d+)' | Select-Object -First 1
    if ($sysLine) { $currentSysSleep = $sysLine.Matches[0].Groups[1].Value }

    if ($currentSysSleep -ne "0") {
        if ($wrapperPrimed) {
            Write-Warning "System sleep is '$currentSysSleep' (expected 0). Run 'sudo pmset -a sleep 0 disksleep 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("System sleep (currently $currentSysSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting system sleep to Never (all power sources)..."
            # -a covers AC + battery + UPS. Previously we set disksleep
            # only on -c; laptops on battery kept disksleep=10. Disk-sleep
            # wake re-checks lock state and on Ventura+ can trigger the
            # unified screen lock even with askForPassword=0.
            & sudo pmset -a sleep 0
            & sudo pmset -a disksleep 0
            $changed = $true
        }
    } else {
        Write-Information "System sleep is already set to Never."
    }

    # ── 3e/3f. Extended pmset guards (idle-sleep, Power Nap, standby, etc.) ─
    # Even with sleep=0, macOS can perform transitions that blank the
    # display or suspend UTM: Power Nap (dark wake for Mail/Backup),
    # standby (deep sleep), auto-poweroff (power-off after N hours of
    # sleep), hibernation (RAM to disk, power off). Any of these during
    # a multi-hour run can hide the UTM window from CG enumeration —
    # symptom: "UTM window for '<vm>' not found. CG: not_found, bounds:
    # not_found".
    #
    # ttyskeepawake=1 keeps system awake with an active tty (SSH, screen
    # capture). tcpkeepalive=1 keeps sockets responsive. disablesleep=1
    # is belt-and-suspenders against another subsystem re-enabling
    # idle-sleep on battery (-a covers AC + battery + UPS).
    #
    # CRITICAL: idempotency check before any `sudo`. install/macos.utm.sh's
    # bash sudo prelude runs all of these in a single batched root
    # session right after `sudo -v`, so by the time pwsh gets here the
    # values are already in place. Without the precheck, the first
    # `sudo pmset` below would re-prompt for password if the sudo cache
    # went cold during the brew/cask phase — exactly the "second sudo
    # prompt" operators have reported. `pmset -g custom` needs no sudo
    # so the precheck itself never prompts.
    # Every guard is OptionalKey: macOS evolves these names across major
    # versions (Sonoma split `standbydelay` into `standbydelaylow` /
    # `standbydelayhigh`; Tahoe renames or removes more). The bash prelude
    # in install/macos.utm.sh applies them all using the legacy names,
    # which `pmset` accepts as compatibility aliases. The check below
    # only fires when a key IS present and has the wrong value -- a
    # missing key is treated as "macOS no longer surfaces it under that
    # name", not as a verification failure.
    $pmsetGuards = @(
        @{ Key = 'disablesleep'      ; Want = 1 },
        @{ Key = 'powernap'          ; Want = 0 },
        @{ Key = 'standby'           ; Want = 0 },
        @{ Key = 'standbydelay'      ; Want = 0 },
        @{ Key = 'standbydelaylow'   ; Want = 0 },
        @{ Key = 'standbydelayhigh'  ; Want = 0 },
        @{ Key = 'autopoweroff'      ; Want = 0 },
        @{ Key = 'hibernatemode'     ; Want = 0 },
        @{ Key = 'ttyskeepawake'     ; Want = 1 },
        @{ Key = 'tcpkeepalive'      ; Want = 1 },
        @{ Key = 'proximitywake'     ; Want = 0 }
    )
    $pmCustom = & pmset -g custom 2>$null
    $pmsetAnyMismatch = $false
    foreach ($g in $pmsetGuards) {
        $line = $pmCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)') | Select-Object -First 1
        if ($line -and [int]$line.Matches[0].Groups[1].Value -ne $g.Want) {
            $pmsetAnyMismatch = $true; break
        }
    }
    $pmsetAllApplied = -not $pmsetAnyMismatch
    if ($pmsetAllApplied) {
        Write-Information "Extended pmset guards verified (no mismatched keys in 'pmset -g custom')."
    } elseif ($wrapperPrimed) {
        Write-Warning "Extended pmset guards have a mismatch in 'pmset -g custom'; bash prelude may need updating for this macOS version. Skipping."
    } elseif ($PSCmdlet.ShouldProcess("Extended pmset guards", "Apply via sudo pmset -a")) {
        Write-Information "Applying extended pmset guards (powernap, standby, autopoweroff, hibernatemode, ttyskeepawake, tcpkeepalive)..."
        & sudo pmset -a disablesleep 1 2>$null | Out-Null
        & sudo pmset -a powernap       0 2>$null | Out-Null
        & sudo pmset -a standby        0 2>$null | Out-Null
        & sudo pmset -a standbydelay   0 2>$null | Out-Null
        & sudo pmset -a autopoweroff   0 2>$null | Out-Null
        & sudo pmset -a hibernatemode  0 2>$null | Out-Null
        & sudo pmset -a ttyskeepawake  1 2>$null | Out-Null
        & sudo pmset -a tcpkeepalive   1 2>$null | Out-Null
        & sudo pmset -a proximitywake  0 2>$null | Out-Null
        $changed = $true
    }

    # ── 3g. Hot corners — neutralize screen-saver / sleep / lock triggers ──
    # Dock stores hot-corner actions under wvous-{tl,tr,bl,br}-corner.
    # A drifting mouse during an unattended test can land in a corner
    # and trigger screensaver / display-sleep / lock — making the UTM
    # window vanish from the CG window list. Dangerous codes neutralized:
    #   5  = Start Screen Saver
    #   10 = Put Display to Sleep
    #   13 = Lock Screen   (Sonoma+)
    # Safe codes (0=none, 2=Mission Control, 3=Show App Windows, 4=Desktop,
    # 11=Launchpad, 12=Notification Center, 14=Quick Note) are left alone.
    $dangerousCorners = @{ '5' = 'Start Screen Saver'; '10' = 'Put Display to Sleep'; '13' = 'Lock Screen' }
    $dockReloadNeeded = $false
    foreach ($corner in @('tl','tr','bl','br')) {
        $key = "wvous-$corner-corner"
        $val = & defaults read com.apple.dock $key 2>$null
        if ($LASTEXITCODE -eq 0) {
            $valTrim = "$val".Trim()
            if ($dangerousCorners.ContainsKey($valTrim)) {
                $action = $dangerousCorners[$valTrim]
                if ($PSCmdlet.ShouldProcess("Hot corner $corner (currently '$action' = $valTrim)", "Set to 0 (none)")) {
                    Write-Information "Neutralizing hot corner '$corner' ($action → none)..."
                    & defaults write com.apple.dock $key -int 0 2>$null | Out-Null
                    # Clear the modifier too — otherwise the corner is
                    # merely hidden behind a modifier a wandering cursor
                    # might hit alongside a stuck Shift.
                    & defaults write com.apple.dock "wvous-$corner-modifier" -int 0 2>$null | Out-Null
                    $dockReloadNeeded = $true
                    $changed = $true
                }
            }
        }
    }
    if ($dockReloadNeeded) {
        # Dock re-reads these only at launch; kick it so the change
        # takes effect immediately (Dock auto-relaunches).
        & killall Dock 2>$null | Out-Null
    } else {
        Write-Information "Hot corners: no dangerous bindings (screen-saver / sleep / lock) detected."
    }

    # ── 3h. App Nap suppression for UTM.app ──────────────────────────────
    # macOS App Nap throttles background apps that haven't received
    # input. For UTM this can freeze the UI thread, stop updating the
    # window server, and drop the window from CGWindowListCopyWindowInfo
    # — exactly the "UTM window for '<vm>' not found" symptom even when
    # the VM is fine. Opt UTM out unconditionally.
    $utmBundleId = 'com.utmapp.UTM'
    $napState = & defaults read $utmBundleId NSAppSleepDisabled 2>$null
    $napAlreadyOff = ($LASTEXITCODE -eq 0 -and "$napState".Trim() -eq '1')
    if (-not $napAlreadyOff) {
        if ($PSCmdlet.ShouldProcess("App Nap for $utmBundleId", "Disable (NSAppSleepDisabled = YES)")) {
            Write-Information "Disabling App Nap for UTM.app ($utmBundleId)..."
            & defaults write $utmBundleId NSAppSleepDisabled -bool YES 2>$null | Out-Null
            $changed = $true
        }
    } else {
        Write-Information "App Nap for UTM.app is already disabled."
    }

    # ── 3i. Clear any stuck ScreenSaverEngine ────────────────────────────
    # If a prior aborted run left the saver engaged, the engine process
    # may still be running when this script applies settings. Killing
    # is idempotent and harmless when nothing runs; swallow exit codes
    # so "no such process" isn't reported as failure.
    & killall ScreenSaverEngine 2>$null | Out-Null

    # ── 3j. sysadminctl unified screen lock (Ventura+) ───────────────────
    # `sysadminctl -screenLock` is the modern (macOS 13+) unified control
    # that System Settings > Lock Screen > "Require password after screen
    # saver begins or display is turned off" writes to.
    # CRITICAL: overrides legacy askForPassword / askForPasswordDelay.
    # A machine with idleTime=0, askForPassword=0, and
    # askForPasswordDelay=MAX_INT can still lock after minutes because
    # sysadminctl reports e.g. "screenLock delay is 300 seconds".
    #
    # "off" sets delay to -1 (disabled). sysadminctl requires the user's
    # password (not sudo) because it touches the secure keyring entry
    # backing lock-screen policy. `-password -` reads from stdin — a
    # second prompt appears after the sudo prompt.
    # sysadminctl logs to stderr with an NSLog prefix; strip it so the
    # breadcrumb and regex match see clean text.
    # Accepted "off" forms: "screenLock is off" OR "delay is -1".
    $slNsLog  = '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+sysadminctl\[\d+:\w+\]\s+'
    $slStatus = (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1) -replace $slNsLog, ''
    $slAlreadyOff = "$slStatus" -match 'screenLock\s+(is\s+off|delay\s+is\s+-1)'
    if (-not $slAlreadyOff) {
        if ($wrapperPrimed) {
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            Write-Warning " sysadminctl unified screen lock is NOT yet disabled (status:"
            Write-Warning "   $slStatus)"
            Write-Warning ""
            Write-Warning " Run this ONE-TIME command yourself before starting tests:"
            Write-Warning ""
            Write-Warning "   sudo sysadminctl -screenLock off -password -"
            Write-Warning ""
            Write-Warning " sysadminctl asks for your account password from stdin in addition"
            Write-Warning " to sudo's prompt. State is persistent across reboots, so this"
            Write-Warning " warning will not reappear once it succeeds."
            Write-Warning "═══════════════════════════════════════════════════════════════════"
        } elseif ($PSCmdlet.ShouldProcess("sysadminctl $slStatus", "Disable (sysadminctl -screenLock off)")) {
            Write-Information "Disabling sysadminctl unified screen lock (you may be prompted for your account password)..."
            # 2>&1 so "password:" prompt and diagnostics both land on
            # the tty where the user expects them.
            & sudo sysadminctl -screenLock off -password - 2>&1
            # Re-check: if we couldn't disable (wrong password, policy
            # override, MDM), surface the state so the user knows legacy
            # keys won't save them.
            $slAfter = (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1) -replace $slNsLog, ''
            if ("$slAfter" -match 'screenLock\s+(is\s+off|delay\s+is\s+-1)') {
                Write-Information "sysadminctl screen lock is now disabled."
                $changed = $true
            } else {
                Write-Warning "sysadminctl screen lock is STILL active after attempt: $slAfter"
                Write-Warning "  If this Mac is MDM-managed, a Configuration Profile may be"
                Write-Warning "  enforcing screen lock; check: profiles list ; profiles show -type configuration"
            }
        }
    } else {
        Write-Information "sysadminctl unified screen lock is already disabled."
    }

    # ── 3k. Auto-logout after inactivity (Security → Advanced) ───────────
    # `com.apple.autologout.AutoLogOutDelay` (system-level) is the
    # "Log out after N minutes of inactivity" toggle in Lock Screen /
    # Security. macOS kicks the user back to loginwindow after the
    # delay — indistinguishable from a lock ("demands password"), but
    # no screen-saver / pmset key we control would prevent it. System
    # level (/Library/Preferences/.GlobalPreferences); the WRITE
    # requires sudo, but the plist is mode 644 so the READ does not --
    # using `sudo defaults read` here would cause an unnecessary sudo
    # call, defeating the install/macos.utm.sh "sudo prelude" that
    # pre-applies this value to keep the pwsh phase prompt-free.
    $autoLogoutDelay = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
    $autoLogoutOff = ($LASTEXITCODE -ne 0 -or "$autoLogoutDelay".Trim() -eq "0")
    if (-not $autoLogoutOff) {
        if ($wrapperPrimed) {
            Write-Warning "AutoLogOutDelay is '$($autoLogoutDelay.Trim())' (expected 0). Run 'sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0' to fix."
        } elseif ($PSCmdlet.ShouldProcess("Auto-logout delay (currently $($autoLogoutDelay.Trim())s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling auto-logout after inactivity..."
            & sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0
            $changed = $true
        }
    } else {
        Write-Information "Auto-logout after inactivity is already disabled."
    }

    # ── 3l. Spaces "switch to a Space with open windows" toggle ──────────
    # When the harness calls `tell application "UTM" to activate` (the
    # AVF-guest keystroke fallback in Send-KeyUTM / Send-TextUTM), macOS
    # by default yanks the operator across Spaces to UTM's window — which
    # is hostile when the operator has switched to VS Code on a different
    # Space to investigate something while a long test runs.
    # AppleSpacesSwitchOnActivation=false keeps the activation on the
    # current Space; UTM still becomes frontmost (so keystrokes route to
    # it), but the operator's view stays put. Dock must be restarted for
    # the change to take effect.
    $spacesAutoSwitch = & defaults read NSGlobalDomain AppleSpacesSwitchOnActivation 2>$null
    $spacesAutoSwitchOff = ($LASTEXITCODE -eq 0 -and "$spacesAutoSwitch".Trim() -eq "0")
    if (-not $spacesAutoSwitchOff) {
        if ($PSCmdlet.ShouldProcess("AppleSpacesSwitchOnActivation (currently $($spacesAutoSwitch))", "Set to false (don't switch Spaces on app activation)")) {
            Write-Information "Disabling 'switch to a Space with open windows' on app activation..."
            & defaults write NSGlobalDomain AppleSpacesSwitchOnActivation -bool false 2>$null | Out-Null
            & killall Dock 2>$null | Out-Null
            $changed = $true
        }
    } else {
        Write-Information "Spaces auto-switch on app activation is already disabled."
    }

    # Pinning UTM.app to "All Desktops" (right-click Dock icon → Options →
    # Assign To → All Desktops) is the other half of making cross-Space
    # debugging seamless — but it's stored deep inside com.apple.spaces
    # app-bindings plist and is fragile to script. Left as a one-time
    # manual step; flagged here so the operator knows it exists.
    Write-Information "Tip (manual): right-click UTM in the Dock → Options → Assign To → All Desktops."
    Write-Information "      Combined with the AppleSpacesSwitchOnActivation toggle above, this lets"
    Write-Information "      Invoke-TestRunner activate UTM without yanking the operator off VS Code."

    # ── 3m. Managed Configuration Profile detection (MDM override) ───────
    # If MDM-managed, a Configuration Profile can enforce screen lock /
    # password delay / auto-logout at a level that OVERRIDES everything
    # above — `defaults write` is silently ignored or reverted on next
    # mcxrefresh. We can't bypass a profile; warn the user so they
    # don't chase a ghost.
    try {
        $profOutput = & profiles list 2>&1
        $hasProfiles = ($LASTEXITCODE -eq 0 -and "$profOutput" -notmatch 'no configuration profiles')
        if ($hasProfiles) {
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            Write-Warning " Configuration Profile(s) detected on this Mac. If any profile"
            Write-Warning " enforces screen-lock / password / auto-logout policy, the settings"
            Write-Warning " applied by this script will be overridden. Inspect with:"
            Write-Warning "   profiles list"
            Write-Warning "   profiles show -type configuration"
            Write-Warning " Policy keys to look for: screenSaverPasswordDelay, askForPassword,"
            Write-Warning " loginWindowIdleTime, AutoLogOutDelay, forceLockOnSleep."
            Write-Warning "═══════════════════════════════════════════════════════════════════"
        }
    } catch {
        Write-Debug "profiles list failed: $_"
    }

    # ── 4. Accessibility — trigger the system prompt if not granted ───────
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $axResult = & osascript -l JavaScript -e $jxa 2>&1
        if ("$axResult" -eq "true") {
            Write-Information "Accessibility permission is already granted."
        } else {
            Write-Information "Requesting Accessibility permission (a system dialog should appear)..."
            # AXIsProcessTrustedWithOptions + kAXTrustedCheckOptionPrompt=true
            # triggers the macOS consent dialog.
            $jxaPrompt = @"
ObjC.import('CoreFoundation');
ObjC.import('ApplicationServices');
var opts = $.CFDictionaryCreateMutable(null, 1,
    $.kCFTypeDictionaryKeyCallBacks, $.kCFTypeDictionaryValueCallBacks);
var key = $.CFStringCreateWithCString(null, 'AXTrustedCheckOptionPrompt', 0);
$.CFDictionarySetValue(opts, key, $.kCFBooleanTrue);
$.AXIsProcessTrustedWithOptions(opts);
"@
            & osascript -l JavaScript -e $jxaPrompt 2>&1 | Out-Null
            Write-Information "  → Grant access in the dialog, then re-run the test."
        }
    } catch {
        Write-Debug "Accessibility prompt failed: $_"
        Write-Warning "Could not check Accessibility status. Grant it manually in System Settings."
    }

    # ── 5. Screen Recording — preflight + first-run prompt ────────────────
    # Separate TCC bucket from Accessibility. Needed so
    # CGWindowListCopyWindowInfo returns window titles (the harness matches
    # UTM's per-VM window by title) and so `screencapture -l <windowId>`
    # works. Without it, waitForAndClickButton loops on "UTM window for
    # <vm> not found". CGRequestScreenCaptureAccess prompts only on the
    # FIRST call per process; subsequent denied states need the user to
    # toggle System Settings manually and relaunch the terminal.
    #
    # ObjC.bindFunction is REQUIRED on some macOS releases — without it,
    # $.CGPreflightScreenCaptureAccess() returns `undefined` (read as
    # "not granted") even when the grant is in place, misreporting state.
    try {
        $jxa = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
try { ObjC.bindFunction('CGRequestScreenCaptureAccess',  ['bool', []]); } catch (e) {}
var granted = $.CGPreflightScreenCaptureAccess();
if (!granted) { $.CGRequestScreenCaptureAccess(); }
(granted === true || granted === 1) ? 'true' : 'false'
"@
        $srResult = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        if ($srResult -eq 'true') {
            Write-Information "Screen Recording permission is already granted."
        } else {
            Write-Information "Requesting Screen Recording permission (a system dialog may appear)..."
            Write-Information "  → If no dialog appears, macOS already remembered a previous denial."
            Write-Information "    Open System Settings > Privacy & Security > Screen Recording,"
            Write-Information "    enable your terminal app (Terminal.app, iTerm2, Ghostty, etc.),"
            Write-Information "    then FULLY QUIT and relaunch it before re-running the test."
        }
    } catch {
        Write-Debug "Screen Recording prompt failed: $_"
        Write-Warning "Could not check Screen Recording status. Grant it manually in System Settings."
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-MacHostConditionSet to verify:"
        Write-Information "  Assert-MacHostConditionSet -HostType 'host.macos.utm'"
    }
}

function Set-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Configures Windows for unattended VM testing: starts Hyper-V service,
    disables display timeout, disables inactivity lock, opens ICMPv4 +
    the status-server TCP port, and resets display/text scale to 100%
    (so HiDPI up-scaling doesn't defeat OCR on VM screenshots). Requires
    Admin. Idempotent. Scale changes take effect on next sign-in.
    .EXAMPLE
    Set-WindowsHostConditionSet          # apply all settings
    Set-WindowsHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsWindows) {
        Write-Warning "Set-WindowsHostConditionSet is only supported on Windows."
        return
    }

    # ── 0. Elevation check ───────────────────────────────────────────────
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell → Run as Administrator."
        return
    }

    $changed = $false

    # ── 1. Hyper-V service ───────────────────────────────────────────────
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        # vmms missing has two cases with different fixes:
        #   a) Hyper-V feature never enabled  → enable, reboot.
        #   b) Hyper-V enabled via DISM but reboot pending (DISM reports
        #      State=Enabled after /Enable-Feature /NoRestart even though
        #      components don't deploy until reboot) → just reboot; don't
        #      re-run Enable-WindowsOptionalFeature.
        # Distinguish by asking DISM directly instead of guessing.
        $dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
        $featureState = 'Unknown'
        if (Test-Path -LiteralPath $dismExe) {
            $dismOut = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in $dismOut) {
                    if ($line -match '^State\s*:\s*(\S+)') { $featureState = $Matches[1]; break }
                }
            }
        }
        if ($featureState -eq 'Enabled') {
            Write-Warning "Hyper-V feature is Enabled but components (vmms) are not deployed yet."
            Write-Warning "  A Windows RESTART is pending. Reboot, then re-run this script."
        } else {
            Write-Warning "Hyper-V service (vmms) is not installed (feature state: $featureState)."
            Write-Warning "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
            Write-Warning "  Then reboot and re-run this script."
        }
    } elseif ($svc.Status -ne 'Running') {
        if ($PSCmdlet.ShouldProcess("Hyper-V service (vmms)", "Start")) {
            Write-Information "Starting Hyper-V Virtual Machine Management service..."
            Start-Service vmms
            $changed = $true
        }
    } else {
        Write-Information "Hyper-V service (vmms) is already running."
    }

    # ── 2. Display timeout → Never ───────────────────────────────────────
    $acTimeout = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $currentAc = if ($acTimeout) { [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16) } else { 0 }

    if ($currentAc -ne 0) {
        $minutes = [math]::Round($currentAc / 60)
        if ($PSCmdlet.ShouldProcess("Display timeout AC (currently $minutes min)", "Set to 0 (Never)")) {
            Write-Information "Setting display timeout to Never (AC and DC)..."
            & powercfg /change monitor-timeout-ac 0
            & powercfg /change monitor-timeout-dc 0
            $changed = $true
        }
    } else {
        Write-Information "Display timeout (AC) is already set to Never."
    }

    # ── 3. Machine inactivity lock → disabled ────────────────────────────
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lockTimeout = $null
    $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
        $lockTimeout = $regProps.InactivityTimeoutSecs
    }

    if ($lockTimeout -and $lockTimeout -gt 0) {
        if ($PSCmdlet.ShouldProcess("Inactivity lock timeout (currently ${lockTimeout}s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling machine inactivity lock..."
            Set-ItemProperty -Path $regPath -Name 'InactivityTimeoutSecs' -Value 0
            $changed = $true
        }
    } else {
        Write-Information "Machine inactivity lock is already disabled."
    }

    # ── 4. Lock screen on resume → disabled ──────────────────────────────
    # power-plan consolelock via powercfg
    $consoleLock = powercfg /query SCHEME_CURRENT SUB_NONE CONSOLELOCK 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $consoleLockVal = if ($consoleLock) { [Convert]::ToInt32($consoleLock.Matches[0].Groups[1].Value, 16) } else { $null }

    if ($consoleLockVal -and $consoleLockVal -ne 0) {
        if ($PSCmdlet.ShouldProcess("Console lock on resume (currently enabled)", "Disable")) {
            Write-Information "Disabling lock screen on resume from sleep..."
            & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETACTIVE SCHEME_CURRENT
            $changed = $true
        }
    } else {
        Write-Information "Lock screen on resume is already disabled (or not applicable)."
    }

    # ── 5. Allow ICMPv4 echo (ping) from VM guests and the LAN ──────────
    # For `ping <host>` to work:
    #   (a) An Allow rule for inbound ICMPv4 Echo Request must exist and
    #       be enabled for every profile whose interface you want ping
    #       on. Windows ships built-in rules
    #       ('File and Printer Sharing (Echo Request - ICMPv4-In)') in
    #       all three profiles (Domain, Private, Public) but DISABLED.
    #   (b) No higher-precedence block rule matches.
    #
    # The earlier -InterfaceAlias-scoped rule for 'vEthernet (Default
    # Switch)' didn't work — disabled built-ins coexist without being
    # triggered; Windows Firewall doesn't merge them. Reliable fix: enable
    # the built-in echo-request rules across all profiles. This opens
    # ping on the LAN NIC too (expected — operators also want to ping
    # the host from peers for diagnostics). No TCP is exposed; ping is
    # just a liveness probe.
    #
    # A custom scoped rule is still created as belt-and-suspenders in
    # case built-ins are missing (stripped server SKUs, GPO, etc.).

    # 5a. Enable built-in Allow + Inbound + ICMPv4 Echo Request rules.
    $icmpAllowRules = Get-NetFirewallRule -Direction Inbound -Action Allow -ErrorAction SilentlyContinue |
        Where-Object {
            $fltr = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $fltr -and $fltr.Protocol -eq 'ICMPv4'
        } |
        Where-Object {
            $icmp = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            # IcmpType '8' (echo request) may be listed as '8:*' or similar;
            # match on the leading 8. When it's 'Any', keep it too since
            # 'Any' includes echo request.
            $types = ($icmp.IcmpType -join ',')
            $types -match '(^|,)8(:|\*|,|$)' -or $types -match '(^|,)Any($|,)'
        }
    $enabledAny = $false
    foreach ($rule in $icmpAllowRules) {
        if ($rule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess("$($rule.DisplayName) [$($rule.Profile)]", 'Enable built-in ICMPv4 Echo Request rule')) {
                Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                Write-Information "Enabled ICMPv4 echo rule: $($rule.DisplayName) [profile: $($rule.Profile)]"
                $enabledAny = $true
                $changed = $true
            }
        }
    }
    if (-not $enabledAny) {
        Write-Information "ICMPv4 echo-request rules: all matching Allow rules already enabled (count: $($icmpAllowRules.Count))."
    }

    # 5b. Belt-and-suspenders: our own always-on rule, profile Any.
    $icmpRuleName = 'Yuruna: Allow ICMPv4 Echo Request'
    $existingRule = Get-NetFirewallRule -DisplayName $icmpRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        if ($existingRule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess($icmpRuleName, 'Enable existing firewall rule')) {
                Enable-NetFirewallRule -DisplayName $icmpRuleName
                Write-Information "Enabled firewall rule: $icmpRuleName"
                $changed = $true
            }
        } else {
            Write-Information "Firewall rule already present and enabled: $icmpRuleName"
        }
    } else {
        if ($PSCmdlet.ShouldProcess($icmpRuleName, 'Create ICMPv4 echo allow rule (all profiles)')) {
            Write-Information "Creating firewall rule: $icmpRuleName (all profiles)..."
            $null = New-NetFirewallRule `
                -DisplayName $icmpRuleName `
                -Description 'Allow inbound ICMPv4 Echo Request on all profiles so guest VMs and LAN peers can ping the host. Created by Yuruna Enable-TestAutomation (host\windows.hyper-v).' `
                -Direction Inbound `
                -Action Allow `
                -Protocol ICMPv4 `
                -IcmpType 8 `
                -Profile Any
            $changed = $true
        }
    }

    # 5c. Diagnostic: surface any enabled *Block* rule on ICMPv4 Echo that
    # would veto our allow, so the user sees the blocker instead of
    # wondering why ping still fails.
    $icmpBlockRules = Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        Where-Object {
            $fltr = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $fltr -and $fltr.Protocol -eq 'ICMPv4'
        }
    if ($icmpBlockRules) {
        Write-Warning "Found enabled ICMPv4 Block rules that may override the Allow rules above:"
        foreach ($r in $icmpBlockRules) {
            Write-Warning "  $($r.DisplayName) [profile: $($r.Profile)]"
        }
        Write-Warning "If ping still fails, disable these or ask your admin — GPO may be pushing them."
    }

    # ── 6. Allow inbound TCP on the status-server port ───────────────────
    # Start-StatusServer.ps1 binds HttpListener to http://*:$Port/ which
    # covers every interface at the socket level — but Windows Firewall
    # drops inbound TCP on non-loopback interfaces without an Allow
    # rule. On a fresh install localhost works (loopback is never
    # filtered) while a LAN browser on http://<host-ip>:8080/ hangs.
    # Port is read from test.config.yml (same source as Start-StatusServer),
    # default 8080 when missing/unset.
    $statusPort = 8080
    $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($cfg.statusServer -and $cfg.statusServer.port) { $statusPort = [int]$cfg.statusServer.port }
        } catch {
            Write-Verbose "test.config.yml parse failed: $($_.Exception.Message)"
        }
    }

    $statusRuleName = "Yuruna: Allow inbound TCP :$statusPort (Status server)"
    $existingStatusRule = Get-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
    if ($existingStatusRule) {
        # Pre-existing rule may have the right name but wrong port (user
        # changed statusServer.port in test.config.yml after running
        # this once). Verify + rebuild instead of silently leaving it.
        $portFilter = $existingStatusRule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $rulePortMatches = $portFilter -and ($portFilter.Protocol -eq 'TCP') -and ($portFilter.LocalPort -eq "$statusPort")
        if (-not $rulePortMatches) {
            if ($PSCmdlet.ShouldProcess($statusRuleName, "Recreate with port $statusPort")) {
                Write-Information "Rebuilding firewall rule for status server on port $statusPort..."
                Remove-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
                $null = New-NetFirewallRule `
                    -DisplayName $statusRuleName `
                    -Description "Allow inbound TCP on the yuruna status-server port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.Host.psm1)." `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol TCP `
                    -LocalPort $statusPort `
                    -Profile Any
                $changed = $true
            }
        } elseif ($existingStatusRule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess($statusRuleName, 'Enable existing firewall rule')) {
                Enable-NetFirewallRule -DisplayName $statusRuleName
                Write-Information "Enabled firewall rule: $statusRuleName"
                $changed = $true
            }
        } else {
            Write-Information "Firewall rule already present and enabled: $statusRuleName"
        }
    } else {
        if ($PSCmdlet.ShouldProcess($statusRuleName, "Create TCP :$statusPort inbound allow rule (all profiles)")) {
            Write-Information "Creating firewall rule: $statusRuleName (all profiles)..."
            $null = New-NetFirewallRule `
                -DisplayName $statusRuleName `
                -Description "Allow inbound TCP on the yuruna status-server port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.Host.psm1)." `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $statusPort `
                -Profile Any
            $changed = $true
        }
    }

    # 6b. Diagnostic: any enabled TCP Block rule covering this port
    # vetoes the Allow above — surface it instead of leaving the user
    # wondering why LAN clients can't connect.
    $tcpBlockRules = Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        Where-Object {
            $f = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $f -and $f.Protocol -eq 'TCP' -and (
                $f.LocalPort -eq "$statusPort" -or $f.LocalPort -eq 'Any'
            )
        }
    if ($tcpBlockRules) {
        Write-Warning "Found enabled TCP Block rules that may override the status-server Allow rule:"
        foreach ($r in $tcpBlockRules) {
            Write-Warning "  $($r.DisplayName) [profile: $($r.Profile)]"
        }
        Write-Warning "If remote clients still get 'connection timed out' on port $statusPort, disable these or ask your admin — GPO may be pushing them."
    }

    # ── 7. Display text scale → 100% ─────────────────────────────────────
    # OCR on VM screenshots (Tesseract, Get-VMWindowScreenshot) degrades
    # when the host display scales above 100%. vmconnect renders the
    # guest framebuffer through the DPI-scaled compositor; the upscaled
    # bitmap defeats Tesseract segmentation — waitForText silently times
    # out on text a human reads fine. Fresh Windows 11 (HiDPI, 4K) ships
    # at 125% or 150%.
    #
    # Three independent scaling knobs, all reset to 100% (HKCU). All
    # require sign-out to take effect; a warning fires if any changed.
    #
    #   7a. Per-monitor DPI (Settings → System → Display → Scale).
    #       HKCU:\Control Panel\Desktop\PerMonitorSettings\<id>\DpiValue
    #       is an offset from RecommendedDpiValue (0 = recommended,
    #       negative = smaller). 100% = -RecommendedDpiValue regardless
    #       of the monitor's recommended scale.
    #   7b. System-wide DPI fallback for non-per-monitor-aware processes:
    #       HKCU:\Control Panel\Desktop\LogPixels = 96 (= 100%) +
    #       Win8DpiScaling = 1.
    #   7c. Windows 11 text size (Settings → Accessibility → Text size),
    #       separate from display scale:
    #       HKCU:\Software\Microsoft\Accessibility\TextScaleFactor
    #       (100 = 100%, up to 225).

    $scaleChanged = $false

    # REG_DWORD → signed int32: Windows writes DpiValue as signed (e.g.
    # -2 for "two steps below recommended") but PowerShell surfaces
    # REG_DWORD as UInt32 — -2 arrives as 4294967294 and a bare [int]
    # cast throws OverflowException. Reinterpret bits: values with the
    # high bit set map to their two's-complement signed equivalent.
    $asSignedDword = {
        param($raw)
        if ($null -eq $raw) { return 0 }
        $u = [uint32]$raw
        if ($u -gt [int32]::MaxValue) { return [int32]($u - 0x100000000) } else { return [int32]$u }
    }

    # 7a. Per-monitor DPI
    # foreach statement (not ForEach-Object) so $scaleChanged writes
    # reach function scope — ForEach-Object's scriptblock runs in a
    # child scope where the assignment would be silently local.
    $perMonPath = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    if (Test-Path -LiteralPath $perMonPath) {
        $monKeys = Get-ChildItem -LiteralPath $perMonPath -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSIsContainer }
        foreach ($mon in $monKeys) {
            $props = Get-ItemProperty -LiteralPath $mon.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            if (-not ($props.PSObject.Properties.Name -contains 'DpiValue')) { continue }
            $current     = & $asSignedDword $props.DpiValue
            $recommended = if ($props.PSObject.Properties.Name -contains 'RecommendedDpiValue') {
                               & $asSignedDword $props.RecommendedDpiValue
                           } else { 0 }
            # DpiValue is offset from recommended; target 100% = -recommended.
            $target = -$recommended
            if ($current -ne $target) {
                $label = $mon.PSChildName
                if ($PSCmdlet.ShouldProcess("Monitor $label", "Set DpiValue $current -> $target (100% display scale)")) {
                    Set-ItemProperty -LiteralPath $mon.PSPath -Name 'DpiValue' -Value $target -Type DWord
                    Write-Information "Set display scale to 100% for monitor $label (DpiValue: $current -> $target)."
                    $scaleChanged = $true
                }
            }
        }
    } else {
        Write-Verbose "HKCU:\Control Panel\Desktop\PerMonitorSettings absent; skipping per-monitor DPI override."
    }

    # 7b. System-wide DPI (LogPixels fallback for non-per-monitor-aware
    # apps). Touch only when LogPixels overrides the default (96).
    # Win8DpiScaling=1 is meaningful only alongside a non-96 LogPixels
    # — tells Windows to honor it. Default state (LogPixels=96,
    # Win8DpiScaling=0) is 100%; skip the write to avoid churning
    # the registry on a pristine system.
    $desktopPath = 'HKCU:\Control Panel\Desktop'
    $dp = Get-ItemProperty -LiteralPath $desktopPath -ErrorAction SilentlyContinue
    $currentLogPixels = if ($dp -and ($dp.PSObject.Properties.Name -contains 'LogPixels'))      { & $asSignedDword $dp.LogPixels }      else { 96 }
    $currentWin8      = if ($dp -and ($dp.PSObject.Properties.Name -contains 'Win8DpiScaling')) { & $asSignedDword $dp.Win8DpiScaling } else { 0 }
    if ($currentLogPixels -ne 96) {
        if ($PSCmdlet.ShouldProcess($desktopPath, "Set LogPixels=96, Win8DpiScaling=1 (100% system DPI)")) {
            Set-ItemProperty -LiteralPath $desktopPath -Name 'LogPixels'      -Value 96 -Type DWord
            Set-ItemProperty -LiteralPath $desktopPath -Name 'Win8DpiScaling' -Value 1  -Type DWord
            Write-Information "Set system DPI to 96 (100%) for the current user (LogPixels=$currentLogPixels -> 96, Win8DpiScaling=$currentWin8 -> 1)."
            $scaleChanged = $true
        }
    } else {
        Write-Information "System DPI (LogPixels) is already 96 (100%)."
    }

    # 7c. Windows 11 Accessibility "Text size"
    $accPath = 'HKCU:\Software\Microsoft\Accessibility'
    if (-not (Test-Path -LiteralPath $accPath)) {
        if ($PSCmdlet.ShouldProcess($accPath, 'Create Accessibility key')) {
            $null = New-Item -Path $accPath -Force
        }
    }
    $ap = Get-ItemProperty -LiteralPath $accPath -ErrorAction SilentlyContinue
    $currentTsf = if ($ap -and ($ap.PSObject.Properties.Name -contains 'TextScaleFactor')) { [int]$ap.TextScaleFactor } else { 100 }
    if ($currentTsf -ne 100) {
        if ($PSCmdlet.ShouldProcess($accPath, "Set TextScaleFactor $currentTsf -> 100")) {
            Set-ItemProperty -LiteralPath $accPath -Name 'TextScaleFactor' -Value 100 -Type DWord
            Write-Information "Set accessibility TextScaleFactor to 100 ($currentTsf -> 100)."
            $scaleChanged = $true
        }
    } else {
        Write-Information "Accessibility TextScaleFactor is already 100."
    }

    if ($scaleChanged) {
        Write-Warning "Display/text scale changes take effect on next sign-in."
        Write-Warning "Sign out and back in (or reboot) before running Invoke-TestRunner.ps1 again, or OCR will still see the old scale."
        $changed = $true
    }

    # ── 8. Active-display probe (Hyper-V headless gotcha) ────────────────
    # Hyper-V's synthetic GPU paints the guest framebuffer through the
    # host's DWM compositor. DWM is gated on the host having an active
    # display surface -- when no monitor is detected, DWM stops rendering
    # and `Get-HyperVScreenshot` returns all-black thumbnails (both the
    # WMI primary AND the PrintWindow fallback). The VM is still healthy
    # and SSH-reachable; only screen-capture / OCR is broken.
    #
    # WmiMonitorBasicDisplayParams enumerates monitors the OS currently
    # treats as connected -- empty array == headless. The probe only
    # warns; it doesn't fail. An operator running on a desktop with a
    # real monitor sees nothing; a headless server gets a one-line
    # warning + pointer at the troubleshooting page so the silent
    # OCR-times-out failure mode is self-diagnosing on the next install.
    $monitors = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
    if ($monitors.Count -eq 0) {
        Write-Warning "No active display detected on this Hyper-V host."
        Write-Warning "  Hyper-V's synthetic GPU stops painting the VM framebuffer when DWM"
        Write-Warning "  is suspended (no monitor connected) -- screen capture and OCR will"
        Write-Warning "  fail with all-black images even though VMs are running and reachable."
        Write-Warning "  Workarounds (any one):"
        Write-Warning "    * HDMI dummy plug (lowest friction)"
        Write-Warning "    * Virtual display driver (e.g. usbmmidd_v2)"
        Write-Warning "    * Keep an RDP session connected to this host"
        Write-Warning "  See host/windows.hyper-v/troubleshooting.md for the full story."
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-HostConditionSet to verify:"
        Write-Information "  Assert-HostConditionSet -HostType 'host.windows.hyper-v'"
    }
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Accessibility permission (needed
    for AXUIElementPostKeyboardEvent). Returns $true if granted (or
    not on macOS). Prints setup instructions and returns $false on
    missing permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # AXIsProcessTrusted() true when the process has Accessibility access.
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = & osascript -l JavaScript -e $jxa 2>&1
        if ("$result" -eq "true") { return $true }
    } catch {
        Write-Debug "Accessibility check failed: $_"
    }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Accessibility permission is NOT granted for this terminal."
    Write-Warning ""
    Write-Warning " The test harness needs Accessibility access to send keystrokes"
    Write-Warning " to UTM VMs without requiring window focus."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Accessibility"
    Write-Warning "   2. Click the + button and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. Restart the terminal and re-run the test"
    Write-Warning ""
    Write-Warning " Without this permission, keystrokes require UTM to stay focused"
    Write-Warning " and any window change will cause missed input."
    Write-Warning "═══════════════════════════════════════════════════════════════════"
    return $false
}

function Assert-ScreenRecording {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Screen Recording permission (needed
    for CGWindowListCopyWindowInfo to include window titles — the
    harness matches UTM's per-VM window by title — and for
    `screencapture -l <windowId>`). Returns $true if granted (or not on
    macOS). Prints setup instructions and returns $false on missing
    permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # Primary check: CGPreflightScreenCaptureAccess is the canonical
    # TCC query — it reads the Screen Recording grant directly and is
    # the same call the OS uses internally. JavaScriptCore's $. bridge
    # needs a registered signature for C functions not shipped in its
    # built-in header set; AX* functions ship with signatures but
    # CGPreflight/CGRequest do not in every release. ObjC.bindFunction
    # registers the signature explicitly so the return type is correct.
    $jxaPre = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
var r = $.CGPreflightScreenCaptureAccess();
(r === true || r === 1) ? 'true' : 'false'
"@
    try {
        $result = (& osascript -l JavaScript -e $jxaPre 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: CGPreflight returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "CGPreflight check failed: $_"
    }

    # Fallback: enumerate on-screen windows and require at least TWO
    # foreign windows with non-empty kCGWindowName. Used only when
    # CGPreflight is unavailable/broken (old macOS, custom JXA build).
    # Requiring two owners avoids false positives from a single
    # permissive-NSWindowSharingType window that would otherwise claim
    # the grant is in place when it isn't.
    $jxa = @"
ObjC.import('CoreGraphics');
var list = $.CGWindowListCopyWindowInfo((1 << 0) | (1 << 4), 0);
if (!list) { 'false' } else {
    var n = $.CFArrayGetCount(list);
    var nameKey  = $.CFStringCreateWithCString(null, 'kCGWindowName', 0);
    var ownerKey = $.CFStringCreateWithCString(null, 'kCGWindowOwnerName', 0);
    var owners = {};
    for (var i = 0; i < n; i++) {
        var d = $.CFArrayGetValueAtIndex(list, i);
        var nm = $.CFDictionaryGetValue(d, nameKey);
        if (!nm || $.CFStringGetLength(nm) === 0) continue;
        var ow = $.CFDictionaryGetValue(d, ownerKey);
        var owStr = ow ? ObjC.unwrap(ow) : '';
        if (owStr) owners[owStr] = true;
    }
    (Object.keys(owners).length >= 2) ? 'true' : 'false'
}
"@
    try {
        $result = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: enumeration fallback returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "Window-title enumeration failed: $_"
    }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Screen Recording permission does NOT appear granted for this"
    Write-Warning " terminal. The harness needs it to enumerate UTM's windows —"
    Write-Warning " CGWindowList only returns titles to processes with this"
    Write-Warning " permission — and to capture a specific VM window via"
    Write-Warning " screencapture -l <windowId>. Without it, waitForAndClickButton"
    Write-Warning " loops on 'UTM window for <vm> not found'."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Screen Recording"
    Write-Warning "   2. Click + and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, Ghostty, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. FULLY QUIT the terminal (Cmd-Q or killall) and relaunch it"
    Write-Warning "      — macOS will NOT honor the grant in the running process."
    Write-Warning "   5. Re-run the test harness from the new terminal."
    Write-Warning ""
    Write-Warning " If the toggle IS on and you already relaunched the terminal,"
    Write-Warning " run this diagnostic and report the output:"
    Write-Warning ""
    Write-Warning "   osascript -l JavaScript -e 'ObjC.import(\"CoreGraphics\");"
    Write-Warning "     ObjC.bindFunction(\"CGPreflightScreenCaptureAccess\","
    Write-Warning "     [\"bool\",[]]); `$.CGPreflightScreenCaptureAccess();'"
    Write-Warning ""
    Write-Warning " If that prints 'true', override this check with"
    Write-Warning "   `$Env:YURUNA_SKIP_SCREEN_RECORDING_CHECK = '1'"
    Write-Warning " and re-run — then please file an issue with the diagnostic"
    Write-Warning " output so the probe can be tuned for your macOS version."
    Write-Warning "═══════════════════════════════════════════════════════════════════"

    if ($env:YURUNA_SKIP_SCREEN_RECORDING_CHECK -eq '1') {
        Write-Warning "YURUNA_SKIP_SCREEN_RECORDING_CHECK=1 — proceeding anyway."
        return $true
    }
    return $false
}

function Assert-MacHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for macOS prerequisites: Accessibility + Screen Recording
    permissions and screen lock / display sleep settings. Returns $true
    on non-macOS or when all conditions pass; $false with diagnostics on
    failure. Invoke once at startup and again before each test cycle.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    if (-not (Assert-Accessibility    -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenRecording  -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenLock       -HostType $HostType)) { return $false }

    return $true
}

function Assert-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for Windows prerequisites: Administrator elevation and
    Hyper-V service. Returns $true on non-Windows or when all pass;
    $false with diagnostics on failure.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.windows.hyper-v") { return $true }

    # 1. Administrator elevation
    if (-not (Assert-Elevation -HostType $HostType)) { return $false }

    # 2. Hyper-V management service must be running
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        Write-Warning " Hyper-V Virtual Machine Management service (vmms) is not running."
        Write-Warning ""
        Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
        Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
        Write-Warning ""
        Write-Warning " If Hyper-V is not installed, enable it first:"
        Write-Warning "   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
        Write-Warning " then reboot."
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        return $false
    }

    # 3. Screen lock / display timeout — warn if display will turn off
    try {
        $acTimeout = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
            Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
            Select-Object -First 1)
        if ($acTimeout) {
            $seconds = [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16)
            if ($seconds -ne 0) {
                $minutes = [math]::Round($seconds / 60)
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                Write-Warning " Display timeout is set to $minutes minute(s) on AC power."
                Write-Warning " The screen will blank during long test runs, which may cause"
                Write-Warning " Hyper-V Enhanced Session screen captures to fail."
                Write-Warning ""
                Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
                Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                return $false
            }
        }
    } catch {
        Write-Debug "Display timeout check failed: $_"
    }

    # 4. Lock screen timeout — warn if machine will lock
    try {
        $lockTimeout = $null
        $regProps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
            $lockTimeout = $regProps.InactivityTimeoutSecs
        }
        if ($lockTimeout -and $lockTimeout -gt 0) {
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            Write-Warning " Machine inactivity lock is set to $lockTimeout second(s)."
            Write-Warning " The lock screen will activate during long test runs."
            Write-Warning ""
            Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
            Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            return $false
        }
    } catch {
        Write-Debug "Lock screen timeout check failed: $_"
    }

    return $true
}

function Assert-HostConditionSet {
    <#
    .SYNOPSIS
    Platform dispatcher: calls Assert-WindowsHostConditionSet or
    Assert-MacHostConditionSet based on the detected host type.
    Returns $true when all platform-specific prerequisites are met.
    #>
    param([string]$HostType)

    if ($HostType -eq "host.windows.hyper-v") {
        return Assert-WindowsHostConditionSet -HostType $HostType
    }
    if ($HostType -eq "host.macos.utm") {
        return Assert-MacHostConditionSet -HostType $HostType
    }
    if ($HostType -eq "host.ubuntu.kvm") {
        # Ubuntu KVM doesn't have macOS-style screen-saver / display-sleep
        # asserts, and elevation isn't a runtime requirement (the harness
        # runs as a libvirt-group user). The real readiness question is:
        # can THIS process reach libvirtd? Assert-Virtualization checks
        # /dev/kvm + libvirtd active + a no-op virsh `list` round-trip.
        # Initialize-YurunaHost (called by the runner just before this
        # function) imports Yuruna.Host.psm1 for host.ubuntu.kvm, so
        # Assert-Virtualization is in scope here.
        if (Assert-Virtualization) { return $true }
        # Diagnose: which of the three preconditions failed?
        if (-not (Test-Path -LiteralPath '/dev/kvm')) {
            Write-Error "/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD)."
            return $false
        }
        $active = (& systemctl is-active libvirtd 2>$null).Trim()
        if ($active -ne 'active') {
            Write-Error "libvirtd is not active (state=$active). Try: 'sudo systemctl start libvirtd' and check 'systemctl status libvirtd'."
            return $false
        }
        # libvirtd up, /dev/kvm present, but the round-trip failed -- the
        # by-far most common cause is a stale supplementary group set on
        # the calling shell. Detect that case specifically so the operator
        # gets actionable steps, not a generic "permission denied".
        $activeGroups   = (& id -nG 2>$null) -split '\s+'
        $libvirtLine    = & getent group libvirt 2>$null
        $libvirtMembers = if ($libvirtLine) { (($libvirtLine -split ':',4)[3]) -split ',' } else { @() }
        if ($libvirtMembers -contains $env:USER -and $activeGroups -notcontains 'libvirt') {
            Write-Error @"
Cannot reach libvirtd from this process: '$env:USER' IS in the 'libvirt'
group per /etc/group, but THIS shell's running group set does NOT include
libvirt -- so virt-install and virsh hit 'Permission denied' on the
libvirt socket. A desktop logout/login does NOT always refresh the group
set on systemd-logind systems with user lingering.

Fix (pick one) and re-run Invoke-TestRunner.ps1:
  A. one-off, no logout needed:
       sg libvirt -c 'pwsh ./Invoke-TestRunner.ps1'
  B. this shell only:
       newgrp libvirt
       pwsh ./Invoke-TestRunner.ps1
  C. fully refresh (most reliable):
       sudo reboot
"@
            return $false
        }
        if ($libvirtMembers -notcontains $env:USER) {
            Write-Error "'$env:USER' is not in the 'libvirt' group at all -- re-run install/ubuntu.kvm.sh, or: 'sudo usermod -aG libvirt $env:USER' then log out / back in."
            return $false
        }
        Write-Error "virsh round-trip against libvirtd failed but the usual causes (kvm missing, libvirtd down, stale group set) don't apply. Run 'virsh -c qemu:///system list' manually for the verbatim error."
        return $false
    }

    Write-Warning "Unknown host type '$HostType' -- skipping condition checks."
    return $true
}

function Invoke-GitPull {
    <#
    .SYNOPSIS
    Runs git pull in the repo root. Returns $true on success.
    #>
    param([string]$RepoRoot)

    # Fetch without modifying working tree. Linear-backoff retry on
    # failure: on macOS the Application Firewall stalls outbound TCP
    # connects right after a process opens a new listening socket
    # (status server, caching-proxy forwarders). Shows up as "Couldn't
    # connect / No route to host" on the first fetches of a fresh
    # runner and has recovered past a 5s wait in observed runs. 5
    # retries with 10/20/30/40/50s waits cover ~2.5 min of blip without
    # masking a genuine outage.
    $maxRetries  = 5
    $attempt     = 0
    while ($true) {
        $attempt++
        $totalAttempts = $maxRetries + 1
        Write-Information "Fetching remote changes in: $RepoRoot (attempt $attempt/$totalAttempts)" -InformationAction Continue
        $output = & git -C $RepoRoot fetch 2>&1
        Write-Information "$output" -InformationAction Continue
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -gt $maxRetries) {
            Write-Error "git fetch failed (exit $LASTEXITCODE) after $totalAttempts attempts."
            return $false
        }
        $waitSeconds = 10 * $attempt
        Write-Information "  git fetch failed (exit $LASTEXITCODE); retrying in ${waitSeconds}s..." -InformationAction Continue
        Start-Sleep -Seconds $waitSeconds
    }

    # Determine local vs remote HEAD positions
    $local  = & git -C $RepoRoot rev-parse HEAD 2>$null
    $remote = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Information "No upstream tracking branch found; skipping ahead/behind check." -InformationAction Continue
        return $true
    }

    if ($local -eq $remote) {
        Write-Information "Local branch is up to date with remote." -InformationAction Continue
        return $true
    }

    $mergeBase = & git -C $RepoRoot merge-base $local $remote 2>$null

    if ($mergeBase -eq $remote) {
        # Local ahead of remote — unpushed commits; fine
        Write-Information "Local branch is ahead of remote. Proceeding with local changes." -InformationAction Continue
        return $true
    }

    # Behind or diverged from remote
    $behind = & git -C $RepoRoot rev-list --count "$local..$remote" 2>$null
    if ($mergeBase -eq $local) {
        # Local behind — safe to fast-forward pull
        Write-Information "Local branch is behind remote by $behind commit(s). Pulling..." -InformationAction Continue
        $pullOutput = & git -C $RepoRoot pull --ff-only 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Information "Pull succeeded: $pullOutput" -InformationAction Continue
            return $true
        }
        Write-Error "git pull --ff-only failed (exit $LASTEXITCODE): $pullOutput"
        return $false
    }

    # Diverged — both sides have unique commits
    $ahead = & git -C $RepoRoot rev-list --count "$remote..$local" 2>$null
    Write-Error "Local branch has diverged from remote ($ahead ahead, $behind behind). Rebase or merge manually."
    return $false
}

function Get-CurrentGitCommit {
    <#
    .SYNOPSIS
    Returns the short git commit hash of HEAD.
    #>
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

function Update-ProjectClone {
    <#
    .SYNOPSIS
    At cycle start, refresh <RepoRoot>/project/ from test.config.yml's repositories.projectUrl.
    .DESCRIPTION
    The project under verification lives in a separate Git repository
    (configured via test.config.yml `repositories.projectUrl`). Each cycle
    blows away <RepoRoot>/project/ and re-clones it so previous cycle
    output cannot leak forward. Returns @{ success; skipped; errorMessage }.

    When `repositories.projectUrl` is empty/missing, this is a no-op (skipped) -
    that path is the in-tree stop-gap, where project/ ships as part of
    the framework repo and the runner uses it directly.

    Safety: we refuse to delete unless the resolved target sits strictly
    under $RepoRoot. A misconfigured RepoRoot or project path could
    otherwise scrub something unrelated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ProjectUrl
    )
    if ([string]::IsNullOrWhiteSpace($ProjectUrl)) {
        Write-Information "repositories.projectUrl is empty - skipping project clone (using in-tree project/)." -InformationAction Continue
        return @{ success = $true; skipped = $true; errorMessage = $null }
    }

    $projectDir = Join-Path $RepoRoot 'project'
    $resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    # Resolve project dir without requiring it to exist; manual path build
    # so the safety check works even when project/ was wiped mid-cycle.
    $resolvedProjectParent = (Resolve-Path -LiteralPath $RepoRoot).Path
    $projectDirNormalized  = [System.IO.Path]::GetFullPath((Join-Path $resolvedProjectParent 'project'))
    if (-not $projectDirNormalized.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ success = $false; skipped = $false; errorMessage = "Refusing to delete project dir outside RepoRoot: $projectDirNormalized" }
    }

    if ($PSCmdlet.ShouldProcess($projectDir, "Wipe and re-clone from $ProjectUrl")) {
        if (Test-Path $projectDir) {
            Write-Information "Removing previous project clone: $projectDir" -InformationAction Continue
            try {
                # -Force chases hidden + read-only entries (.git/objects/pack
                # files arrive read-only on Windows after a clone).
                Remove-Item -LiteralPath $projectDir -Recurse -Force -ErrorAction Stop
            } catch {
                return @{ success = $false; skipped = $false; errorMessage = "Failed to remove previous project clone ($projectDir): $($_.Exception.Message)" }
            }
        }
        Write-Information "Cloning $ProjectUrl -> $projectDir" -InformationAction Continue
        $cloneOut = & git clone --depth 1 $ProjectUrl $projectDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ success = $false; skipped = $false; errorMessage = "git clone failed (exit $LASTEXITCODE): $cloneOut" }
        }
        Write-Information "Project clone refreshed." -InformationAction Continue
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

function Install-PowerShellYamlIfMissing {
<#
.SYNOPSIS
    Ensure the powershell-yaml module is available to the runner.
.DESCRIPTION
    Test.SequencePlanner.Resolve-CyclePlan reads project/test/
    test.sequence.yml and every per-sequence baseline file via
    Read-SequenceFile, which Import-Modules powershell-yaml on demand.
    pwsh 7 doesn't ship it, so on a freshly-imaged host the planner
    throws -- the inner runner's try/catch then falls back to the
    legacy guestSequence list, which leaves Start-GuestOS with an
    empty sequence array and records every guest as "skipped" in
    status.json with no log line. Installing here at host-prep time
    keeps that silent-skip trap out of the cycle.

    Idempotent: returns $true immediately when the module is already
    discoverable on PSModulePath. CurrentUser scope, so no elevation
    is required. -Force suppresses the PSGallery "untrusted repository"
    prompt that would otherwise hang an unattended Enable-TestAutomation
    run.
.OUTPUTS
    [bool] $true when the module is available afterwards (already
    installed or just installed); $false on install failure.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    if (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue) {
        Write-Verbose "powershell-yaml already installed."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('powershell-yaml', 'Install-Module (CurrentUser scope)')) {
        Write-Information "WhatIf: Install-Module powershell-yaml -Scope CurrentUser" -InformationAction Continue
        return $false
    }
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Information "Installed module: powershell-yaml (CurrentUser scope)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Failed to install powershell-yaml: $($_.Exception.Message). Install manually with: Install-Module powershell-yaml -Scope CurrentUser"
        return $false
    }
}

function Install-PSScriptAnalyzerIfMissing {
<#
.SYNOPSIS
    Ensure the PSScriptAnalyzer module is available to the harness and to
    editor / CI lint flows.
.DESCRIPTION
    PSScriptAnalyzer surfaces rule violations across the harness's
    PowerShell sources (`.ps1` and `.psm1`). pwsh 7 does not ship it,
    so install it once per host (re-runs are no-ops). Installed right
    after powershell-yaml so the "install PowerShell + Yaml support,
    then add PSScriptAnalyzer" ordering is honored on a fresh box.

    Idempotent: returns $true immediately when the module is already
    discoverable on PSModulePath. CurrentUser scope, so no elevation
    is required. -Force suppresses the PSGallery "untrusted repository"
    prompt that would otherwise hang an unattended Enable-TestAutomation
    run.
.OUTPUTS
    [bool] $true when the module is available afterwards (already
    installed or just installed); $false on install failure.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    if (Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue) {
        Write-Verbose "PSScriptAnalyzer already installed."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('PSScriptAnalyzer', 'Install-Module (CurrentUser scope)')) {
        Write-Information "WhatIf: Install-Module PSScriptAnalyzer -Scope CurrentUser" -InformationAction Continue
        return $false
    }
    try {
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Information "Installed module: PSScriptAnalyzer (CurrentUser scope)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Failed to install PSScriptAnalyzer: $($_.Exception.Message). Install manually with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
        return $false
    }
}

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Initialize-YurunaHost, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Test-HostRequirement, Assert-HostConditionSet, Initialize-SudoCache, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Set-MacHostConditionSet, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit, Update-ProjectClone
