<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42e5b4c3-d2a1-4f9a-6789-0b1c2d3e4f51
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows
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

# Windows sibling of Test.HostCondition.psm1: applies AND asserts the
# per-host preconditions for unattended VM testing on host.windows.hyper-v
# (Hyper-V service, display timeout, inactivity lock, firewall rules for
# ICMPv4 + the status-service TCP port, display/text scale = 100% so
# HiDPI doesn't defeat OCR on VM screenshots). Loaded by the
# Test.HostCondition.psm1 facade; callers continue to import the facade
# and resolve these names through its Export-ModuleMember. See
# Test.HostCondition.psm1 for the per-platform split rationale.

function Set-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Configures Windows for unattended VM testing: starts Hyper-V service,
    disables display timeout, disables inactivity lock, opens ICMPv4 +
    the status-service TCP port, and resets display/text scale to 100%
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

    # ── 6. Allow inbound TCP on the status-service port ───────────────────
    # Start-StatusService.ps1 binds HttpListener to http://*:$Port/ which
    # covers every interface at the socket level — but Windows Firewall
    # drops inbound TCP on non-loopback interfaces without an Allow
    # rule. On a fresh install localhost works (loopback is never
    # filtered) while a LAN browser on http://<host-ip>:8080/ hangs.
    # Port is read from test.config.yml (same source as Start-StatusService),
    # default 8080 when missing/unset.
    $statusPort = 8080
    $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($cfg.statusService -and $cfg.statusService.port) { $statusPort = [int]$cfg.statusService.port }
        } catch {
            Write-Verbose "test.config.yml parse failed: $($_.Exception.Message)"
        }
    }

    $statusRuleName = "Yuruna: Allow inbound TCP :$statusPort (Status server)"
    $existingStatusRule = Get-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
    if ($existingStatusRule) {
        # Pre-existing rule may have the right name but wrong port (user
        # changed statusService.port in test.config.yml after running
        # this once). Verify + rebuild instead of silently leaving it.
        $portFilter = $existingStatusRule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $rulePortMatches = $portFilter -and ($portFilter.Protocol -eq 'TCP') -and ($portFilter.LocalPort -eq "$statusPort")
        if (-not $rulePortMatches) {
            if ($PSCmdlet.ShouldProcess($statusRuleName, "Recreate with port $statusPort")) {
                Write-Information "Rebuilding firewall rule for status server on port $statusPort..."
                Remove-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
                $null = New-NetFirewallRule `
                    -DisplayName $statusRuleName `
                    -Description "Allow inbound TCP on the yuruna status-service port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.Host.psm1)." `
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
                -Description "Allow inbound TCP on the yuruna status-service port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.Host.psm1)." `
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
        Write-Warning "Found enabled TCP Block rules that may override the status-service Allow rule:"
        foreach ($r in $tcpBlockRules) {
            Write-Warning "  $($r.DisplayName) [profile: $($r.Profile)]"
        }
        Write-Warning "If remote clients still get 'connection timed out' on port $statusPort, disable these or ask your admin — GPO may be pushing them."
    }

    # Display text scale -> 100% on three independent HKCU knobs
    # (per-monitor DPI, system DPI fallback, Win11 TextScaleFactor).
    # Rationale and registry keys: https://yuruna.link/host/hyperv
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
        Write-Warning "  See docs/host-hyperv.md for the full story."
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-HostConditionSet to verify:"
        Write-Information "  Assert-HostConditionSet -HostType 'host.windows.hyper-v'"
    }
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

Export-ModuleMember -Function Set-WindowsHostConditionSet, Assert-WindowsHostConditionSet
