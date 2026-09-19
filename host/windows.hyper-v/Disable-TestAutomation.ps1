<#PSScriptInfo
.VERSION 2026.09.18
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
    Restores values captured in status/runtime/host.pre-automation.json and
    removes Yuruna-owned additions. Missing captured values are reported and
    left unchanged. Refuses to restore settings during an active test cycle.
    Service shutdown is opt-in. See https://yuruna.link/42e220c4-0004.

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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsWindows) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_8c0479442a041d98')
    exit 1
}

# --- REGION: Initialize host setup
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.StatusFirewall.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostMetricsExporter.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Config.psm1')              -Force -DisableNameChecking

# A live cycle would have display sleep and screen lock restored underneath it,
# blanking capture mid-run for a reason nothing in the transcript explains.
if (-not (Assert-SafeToDisable)) { exit 1 }

# --- REGION: Read captured host settings
$state = Read-HostAutomationState
if ($state) {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_97b7a77dbbb6e9c9' -Arguments @{ capturedUtc = "$($state.capturedUtc)" })
} else {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b151e82086a9c67b')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0949a2e9ce231a20')
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
if ($restored.Count -gt 0 -and $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_8a80424abbee4c3a'), (Format-YurunaOperatorMessage -Key 'host.operator_69289c4188f77d5e'))) {
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
            if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_7508ef45e94fa220' -Arguments @{ monitor = "$monitor" }), (Format-YurunaOperatorMessage -Key 'host.operator_a22ecf5c7e7a413e'))) {
                Remove-ItemProperty -LiteralPath $subKey -Name 'DpiValue' -ErrorAction SilentlyContinue
                $restored.Add("Display scaling '$monitor' -> removed (was unset)")
            }
        } elseif ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_7508ef45e94fa220' -Arguments @{ monitor = "$monitor" }), (Format-YurunaOperatorMessage -Key 'host.operator_33cb4ea4e0ebc428' -Arguments @{ prior = "$prior" }))) {
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
# Removed outright: every rule here is ours, by name. The exporter SERVICE is
# not removed with them -- it is an installed package, not a host setting this
# script overwrote: winget uninstall --id Prometheus.WindowsExporter.
$statusPort = 8080
$configPath = Join-Path $RepoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $configPath) {
    try {
        $tc = Read-TestConfig -Path $configPath
        if ($tc -and $tc.statusService -and $tc.statusService.port) { $statusPort = [int]$tc.statusService.port }
    } catch { Write-Verbose "status port read: $($_.Exception.Message)" }
}
$statusRuleName  = Get-YurunaStatusFirewallRuleName -Port $statusPort
$metricsRuleName = Get-YurunaHostMetricsFirewallRuleName -Port (Get-YurunaHostMetricsPort)
foreach ($ruleName in @($statusRuleName, $metricsRuleName, 'Yuruna: Allow ICMPv4 Echo Request')) {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) { Write-Verbose "firewall rule '$ruleName' is already absent."; continue }
    if ($PSCmdlet.ShouldProcess($ruleName, (Format-YurunaOperatorMessage -Key 'host.operator_b15dd410559b0438'))) {
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
        if ($PSCmdlet.ShouldProcess($rule.DisplayName, (Format-YurunaOperatorMessage -Key 'host.operator_7d0283f1761a3fa6'))) {
            Disable-NetFirewallRule -Name $prop.Name -ErrorAction SilentlyContinue
            $restored.Add("Built-in ICMPv4 rule disabled again: $($rule.DisplayName)")
        }
    }
} else {
    $skipped.Add('Built-in ICMPv4 rule states (not captured; left enabled)')
}

# --- REGION: Host clock
Restore-Knob -Name 'service/W32Time' -Description (Format-YurunaOperatorMessage -Key 'host.clock_service_description') -Apply {
    param($v)
    $svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
    if (-not $svc) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_a64eb0bfe41b92f6') }
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
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_87f50089fdd7e8c5')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_86f7c664d47e8d92') -Command @(
    (Format-YurunaOperatorMessage -Key 'host.operator_8da23b13d6bee38a')
)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_4449d0e3b35c0780')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_51ad715d8bf6eabf')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_c65c4b6881513631') `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableCommonEpilogue -StateCaptured ([bool]$state) -StopServices ([bool]$StopServices)
