<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42639d1d-6649-49d9-82a8-a37f8410ebbc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows hyper-v disable-test-automation
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
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Restore the Windows host settings Enable-TestAutomation changed.
.DESCRIPTION
    Reads status/runtime/host.pre-automation.json -- written by
    Enable-TestAutomation before it changed anything -- and puts each captured
    knob back:

      * powercfg monitor timeout (AC and DC separately)
      * powercfg CONSOLELOCK (AC and DC separately)
      * InactivityTimeoutSecs policy
      * per-monitor DpiValue, plus LogPixels / Win8DpiScaling / TextScaleFactor
      * the Enabled state of each built-in inbound ICMPv4 rule Enable switched on
      * the W32Time startup type and run state Enable's clock discipline changed

    And removes what Enable added outright: the status-port firewall rule and
    the 'Yuruna: Allow ICMPv4 Echo Request' rule.

    Without a capture file (a host enabled before the capture shipped), ONLY the
    two rules above are removed -- they are provably ours. Every other setting is
    left exactly as it is and reported, because a "restore" to a guessed default
    is a change the operator never asked for.

    Requires Administrator: powercfg, the policy key and the firewall rules all
    need it. The redirector's elevation gate applies before this runs.
.PARAMETER StopServices
    Also stop the caching-proxy, stash, pool-control and download-agent VMs
    this host runs.
    Off by default: restoring host settings and tearing down services are
    different intentions, and doing both on one word surprises somebody.
.EXAMPLE
    pwsh host/windows.hyper-v/Disable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StopServices
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsWindows) {
    Write-Error 'Disable-TestAutomation.ps1 (host/windows.hyper-v) only runs on Windows.'
    exit 1
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.StatusFirewall.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Config.psm1')              -Force -DisableNameChecking

# A live cycle would have display sleep and screen lock restored underneath it,
# blanking capture mid-run for a reason nothing in the transcript explains.
if (-not (Assert-SafeToDisable)) { exit 1 }

$state = Read-HostAutomationState
if ($state) {
    Write-Information "Restoring from the capture taken at $($state.capturedUtc)."
} else {
    Write-Warning 'No pre-automation capture on this host (Enable-TestAutomation did not write one, or the file was removed).'
    Write-Warning 'Only what is provably ours will be removed: the status-port rule and the Yuruna ICMP rule. Everything else is reported, not guessed at.'
}

$restored = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()

# --- REGION: Script-local helpers
# Thin local shim over the shared driver so the three per-host scripts stay
# readable: -State, -Cmdlet and the two lists are the same on every call.
function Restore-Knob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Absent
    )
    Invoke-HostKnobRestore -State $state -Name $Name -Description $Description `
        -Apply $Apply -Absent $Absent -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

# --- REGION: Power settings
foreach ($scheme in @('AC', 'DC')) {
    $flag = if ($scheme -eq 'AC') { '/SETACVALUEINDEX' } else { '/SETDCVALUEINDEX' }
    Restore-Knob -Name "powercfg/monitor-timeout-$scheme" -Description "Monitor timeout ($scheme)" -Apply {
        param($v)
        & powercfg $flag SCHEME_CURRENT SUB_VIDEO VIDEOIDLE ([int]$v)
    }.GetNewClosure()
    Restore-Knob -Name "powercfg/CONSOLELOCK-$scheme" -Description "Console lock on resume ($scheme)" -Apply {
        param($v)
        & powercfg $flag SCHEME_CURRENT SUB_NONE CONSOLELOCK ([int]$v)
    }.GetNewClosure()
}
if ($restored.Count -gt 0 -and $PSCmdlet.ShouldProcess('Active power scheme', 'Re-apply so the restored indices take effect')) {
    # powercfg writes the index into the scheme but does not activate it; without
    # this the restored values sit in the registry and the live scheme keeps the
    # automation values.
    & powercfg /SETACTIVE SCHEME_CURRENT
}

# --- REGION: Inactivity policy
Restore-Knob -Name 'policy/InactivityTimeoutSecs' -Description 'InactivityTimeoutSecs policy' -Apply {
    param($v)
    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'InactivityTimeoutSecs' -Value ([int]$v) -Type DWord
} -Absent {
    Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'InactivityTimeoutSecs' -ErrorAction SilentlyContinue
}

# --- REGION: Display scaling
$dpiKnob = Get-HostAutomationKnob -State $state -Name 'dpi/perMonitor'
if ($dpiKnob -and $dpiKnob.present) {
    $root = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    foreach ($prop in $dpiKnob.value.PSObject.Properties) {
        $monitor = $prop.Name
        $prior   = [string]$prop.Value
        $subKey  = Join-Path $root $monitor
        if (-not (Test-Path -LiteralPath $subKey)) {
            # The accepted caveat: a monitor present at Enable time and gone now
            # is REPORTED, never recreated. Writing a scaling key for a display
            # that is not attached is how a machine ends up with a setting for
            # hardware it does not have.
            $skipped.Add("Display scaling for monitor '$monitor' (that monitor is not attached now; prior DpiValue was $prior)")
            continue
        }
        if ($prior -eq 'absent') {
            if ($PSCmdlet.ShouldProcess("Display scaling for '$monitor'", 'Remove DpiValue (was unset)')) {
                Remove-ItemProperty -LiteralPath $subKey -Name 'DpiValue' -ErrorAction SilentlyContinue
                $restored.Add("Display scaling '$monitor' -> removed (was unset)")
            }
        } elseif ($PSCmdlet.ShouldProcess("Display scaling for '$monitor'", "Restore DpiValue to $prior")) {
            Set-ItemProperty -LiteralPath $subKey -Name 'DpiValue' -Value ([int]$prior) -Type DWord
            $restored.Add("Display scaling '$monitor' -> $prior")
        }
    }
} else {
    $skipped.Add('Per-monitor display scaling (not captured)')
}

foreach ($spec in @(
    @{ Name = 'dpi/LogPixels'      ; Path = 'HKCU:\Control Panel\Desktop'            ; Prop = 'LogPixels'      ; Desc = 'LogPixels' }
    @{ Name = 'dpi/Win8DpiScaling' ; Path = 'HKCU:\Control Panel\Desktop'            ; Prop = 'Win8DpiScaling' ; Desc = 'Win8DpiScaling' }
    @{ Name = 'dpi/TextScaleFactor'; Path = 'HKCU:\Software\Microsoft\Accessibility' ; Prop = 'TextScaleFactor'; Desc = 'Text scale factor' }
)) {
    $path = $spec.Path; $prop = $spec.Prop
    Restore-Knob -Name $spec.Name -Description $spec.Desc -Apply {
        param($v)
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $path -Name $prop -Value ([int]$v) -Type DWord
    }.GetNewClosure() -Absent {
        Remove-ItemProperty -LiteralPath $path -Name $prop -ErrorAction SilentlyContinue
    }.GetNewClosure()
}

# --- REGION: Firewall rules
# Removed outright: both rules are ours, by name.
$statusPort = 8080
$configPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $configPath) {
    try {
        $tc = Read-TestConfig -Path $configPath
        if ($tc -and $tc.statusService -and $tc.statusService.port) { $statusPort = [int]$tc.statusService.port }
    } catch { Write-Verbose "status port read: $($_.Exception.Message)" }
}
$statusRuleName = Get-YurunaStatusFirewallRuleName -Port $statusPort
foreach ($ruleName in @($statusRuleName, 'Yuruna: Allow ICMPv4 Echo Request')) {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) { Write-Verbose "firewall rule '$ruleName' is already absent."; continue }
    if ($PSCmdlet.ShouldProcess($ruleName, 'Remove the firewall rule Yuruna created')) {
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        $restored.Add("Firewall rule removed: $ruleName")
    }
}

# Built-in ICMPv4 rules: only the ones Enable switched ON go back off. A rule
# that was already enabled before automation stays enabled -- it was not ours to
# change, and disabling it would break whatever else relies on it.
$icmpKnob = Get-HostAutomationKnob -State $state -Name 'firewall/icmpv4BuiltIn'
if ($icmpKnob -and $icmpKnob.present) {
    foreach ($prop in $icmpKnob.value.PSObject.Properties) {
        if ([string]$prop.Value -eq 'True') { continue }
        $rule = Get-NetFirewallRule -Name $prop.Name -ErrorAction SilentlyContinue
        if (-not $rule) { $skipped.Add("Built-in ICMPv4 rule '$($prop.Name)' (no longer present)"); continue }
        if ($rule.Enabled -ne 'True') { continue }
        if ($PSCmdlet.ShouldProcess($rule.DisplayName, 'Disable (it was disabled before automation)')) {
            Disable-NetFirewallRule -Name $prop.Name -ErrorAction SilentlyContinue
            $restored.Add("Built-in ICMPv4 rule disabled again: $($rule.DisplayName)")
        }
    }
} else {
    $skipped.Add('Built-in ICMPv4 rule states (not captured; left enabled)')
}

# --- REGION: Host clock
Restore-Knob -Name 'service/W32Time' -Description 'Windows Time service (W32Time)' -Apply {
    param($v)
    $svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'the Windows Time service is not present on this host' }
    $priorStart = [string]$v.StartType
    if ($priorStart -and $svc.StartType -ne $priorStart) {
        Set-Service -Name 'W32Time' -StartupType $priorStart -ErrorAction Stop
    }
    # Stopping it is part of the restore: the clock is only disciplined while
    # the service runs, and a host that had it stopped is a host the operator
    # left free to drift.
    if ([string]$v.Status -ne 'Running' -and $svc.Status -eq 'Running') {
        Stop-Service -Name 'W32Time' -ErrorAction Stop
    }
}

# --- REGION: Services (opt-in)
if ($StopServices) {
    Stop-YurunaServiceVMSet -RepoRoot $RepoRoot -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

# --- REGION: Report
Write-DisableReport -Platform 'windows.hyper-v' -Restored $restored -Skipped $skipped

Write-Output ''
Write-Output 'NOT reversed (deliberately) -- run these yourself if you want them gone:'
Write-DisableManualStep -What 'Installed packages and PSGallery modules (powershell-yaml, PSScriptAnalyzer)' -Command @(
    'Uninstall-Module powershell-yaml, PSScriptAnalyzer'
)
Write-DisableManualStep -What 'Hyper-V and vmms service state (the bootstrapper enabled these, not Enable-TestAutomation)'
Write-DisableManualStep -What 'Cloned repos, VM images and run history under ~/yuruna'
Write-DisableManualStep -What 'networkStorage configuration, the vaulted credential and any mounts' `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableCommonEpilogue -StateCaptured ([bool]$state) -StopServices ([bool]$StopServices)
