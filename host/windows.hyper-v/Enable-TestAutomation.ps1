<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4256c18e-dd7e-400d-aa57-445e74e55994
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows hyper-v enable-test-automation
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
    Prepares the Windows Hyper-V host to run yuruna automated VM tests.

.DESCRIPTION
    Captures the host's original settings once, then applies the platform's
    unattended-test prerequisites and optional pool-storage setup. Re-running
    preserves the original capture used by Disable-TestAutomation.ps1.
    Also registers the scheduled task "Yuruna Host Controller", which runs
    the host controller that carries out host updates.
    See https://yuruna.link/42e220c4-0004 and https://yuruna.link/42dc5bb9-0001.
    Run as Administrator. After a display-scale change, sign out and back in
    before testing so the compositor uses the new scale.

.PARAMETER NoOperatorPrompt
    Apply the settings with nobody at the keyboard, as the enable phase of a
    host update runs it. Nothing is asked: no PSGallery install and no
    networkStorage questionnaire (it implies -SkipPoolStorage). The host
    controller's scheduled task is verified, never registered or restarted,
    because the controller running this update is the one a restart would
    end. A setting that needs a person is counted as unmet (exit 2).
    YURUNA_NONINTERACTIVE is 1 for this script's lifetime and restored
    afterwards. Refuses with exit 1, before capturing or changing anything,
    when -Confirm asks for a prompt before each change.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    .\Enable-TestAutomation.ps1
    .\Enable-TestAutomation.ps1 -WhatIf
    .\Enable-TestAutomation.ps1 -SkipPoolStorage -NoOperatorPrompt
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Settings-only run: skip the interactive networkStorage questionnaire at the
    # end. install/setup.ps1 configures storage itself, in its own order, and
    # would otherwise ask the same questions twice.
    [switch]$SkipPoolStorage,
    [switch]$NoOperatorPrompt
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = "Stop"
# Set-WindowsHostConditionSet reports each setting it touches via
# Write-Information; without Continue the display-scale, screen-lock and
# display-timeout decisions print nothing and the operator cannot tell what
# changed.
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsWindows) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_ffd2efb19a40de43')
    exit 1
}

# --- REGION: No-prompt mode
# -NoOperatorPrompt is a promise made before anything runs; -Confirm asks for a
# prompt per change, the opposite request, so the combination refuses before
# the capture or any setting is touched. Every prompt predicate this run's
# modules and children use reads YURUNA_NONINTERACTIVE; the caller's value is
# put back when the script ends.
$savedNonInteractive = [Environment]::GetEnvironmentVariable('YURUNA_NONINTERACTIVE')
if ($NoOperatorPrompt) {
    if ($PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']) {
        Write-Error -Message (Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_confirm_conflict') -ErrorAction Continue
        exit 1
    }
    $env:YURUNA_NONINTERACTIVE = '1'
    $ConfirmPreference = 'None'
    $SkipPoolStorage = $true
}
$exitCode = 0
try {

# --- REGION: Initialize host setup
# See https://yuruna.link/42e5cdfd-000b
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
if ($NoOperatorPrompt) {
    Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters -SkipModuleInstall -Confirm:$false
    Write-Information (Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_mode_host')
} else {
    Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters
}

# --- REGION: Pre-automation capture
# BEFORE anything is changed: record what these knobs were, so
# Disable-TestAutomation can put them back. Written once and never overwritten
# -- a second Enable must not capture Enable's own values as the operator's.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
$capturePath = Save-HostAutomationState -Platform 'windows.hyper-v' -WhatIf:$WhatIfPreference
if ($capturePath) { Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_18ab1c2a314eaf6a' -Arguments @{ capturePath = "$capturePath" }) }

# --- REGION: Host condition set
# -SkipPoolStorage is ours, not Set-WindowsHostConditionSet's; splatting it
# through would fail parameter binding.
$conditionArgs = @{}
foreach ($k in $PSBoundParameters.Keys) { if ($k -notin @('SkipPoolStorage', 'NoOperatorPrompt')) { $conditionArgs[$k] = $PSBoundParameters[$k] } }
if ($NoOperatorPrompt) { $conditionArgs['Confirm'] = $false }
# Select the count out of whatever came back rather than casting the lot.
# Set-WindowsHostConditionSet shells out to powercfg, dism and w32tm, and one
# uncaptured line from any of them would make its return an array -- which a
# straight [int] cast turns into a thrown error, converting a cosmetic leak into
# a failed setup step.
$conditionResult = @(Set-WindowsHostConditionSet @conditionArgs)
$unmetCount = @($conditionResult | Where-Object { $_ -is [int] } | Select-Object -Last 1)
$unmetCount = if ($unmetCount.Count) { [int]$unmetCount[0] } else { 0 }

# --- REGION: Pool storage and host identity
# See https://yuruna.link/428405a0-0009
if ($SkipPoolStorage) {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_07d790b607ee2b44')
} elseif (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}

# See https://yuruna.link/42e220c4-0004
if (Test-YurunaVirtualDisplayEnabled) {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_05f01e441da81178')
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_29fdf0ffc1344091')
}

# --- REGION: Host controller
# See https://yuruna.link/42f909ad-002b
# The host controller runs under a scheduled task of this account, outside the
# runner and the listener, so a host update can stop and start both. The task
# starts Windows PowerShell on the shim at each logon, with the highest
# privileges the account has, and the shim starts the controller. The task's
# definition is rendered from the template on every run; it is registered
# again only when it differs from the one this script last registered, which
# is kept in the controller root. A module imported inside another one is not
# visible here, so each module this region calls is imported by name.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.SingleFlightLock.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostOperationJournal.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostUpdate.psm1') -Force -DisableNameChecking
$controllerTask = 'Yuruna Host Controller'
if ($NoOperatorPrompt) {
    # Verified, never registered: the controller running this update is the
    # one a restart of the task would end.
    $shimPath = Get-HostUpdateControllerShimPath
    $deployment = 'shim-missing'
    if ($shimPath) {
        $definition = Get-HostUpdateControllerTaskXml -TemplatePath (Join-Path $RepoRoot 'host/windows.hyper-v/host-controller/yuruna-host-controller.task.xml') `
            -AccountSid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
            -PowerShellPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ShimPath $shimPath
        $recordedPath = Join-Path (Split-Path -Parent $shimPath) 'task.xml'
        $recorded = if ([System.IO.File]::Exists($recordedPath)) { [System.IO.File]::ReadAllText($recordedPath) } else { $null }
        $deployment = Test-HostUpdateControllerDeployment -RepoRoot $RepoRoot -Definition $definition -InstalledDefinition $recorded
        if ($deployment -eq 'ready' -and -not (Get-ScheduledTask -TaskName $controllerTask -ErrorAction SilentlyContinue)) { $deployment = 'task-missing' }
    }
    if ($deployment -ne 'ready') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_not_verified' -Arguments @{ reason = "$deployment" })
        $unmetCount++
    }
} elseif (-not $WhatIfPreference) {
    $files = Install-HostUpdateControllerFile -RepoRoot $RepoRoot -Confirm:$false
    # The snapshot is staged before current is written, so a failure to
    # write current still names one; only these two reasons leave a
    # deployment the shim can start.
    if ($files.Reason -notin @('installed', 'unchanged')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_task_files_failed' -Arguments @{ reason = "$($files.Reason)" })
        $unmetCount++
    } else {
        $controllerRoot = Split-Path -Parent $files.Shim
        $definition = Get-HostUpdateControllerTaskXml -TemplatePath (Join-Path $RepoRoot 'host/windows.hyper-v/host-controller/yuruna-host-controller.task.xml') `
            -AccountSid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
            -PowerShellPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ShimPath $files.Shim
        $task = Register-HostUpdateControllerTask -TaskName $controllerTask -Definition $definition -DefinitionPath (Join-Path $controllerRoot 'task.xml') `
            -StopPath (Join-Path $controllerRoot 'stop') -ShimChanged ([bool]$files.ShimChanged) -Confirm:$false
        if ($task.Change -ne 'none') { Write-Output (Format-YurunaOperatorMessage -Key "host.host_controller_task_$($task.Change)") }
        switch ($task.Outcome) {
            'running' { Write-Output (Format-YurunaOperatorMessage -Key 'host.host_controller_task_running' -Arguments @{ snapshot = "$($files.Snapshot)" }) }
            'not-running' {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_task_not_running' -Arguments @{ path = "$controllerRoot" })
                $unmetCount++
            }
            default {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.host_controller_task_failed' -Arguments @{ detail = "$($task.Detail)" })
                $unmetCount++
            }
        }
    }
}

# --- REGION: Outcome
# See https://yuruna.link/42e220c4-0004 for the shared 0/1/2 host-setup contract.
if ($unmetCount -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6661089d0f925ca8' -Arguments @{ unmetCount = "$unmetCount" })
    $exitCode = 2
}
} finally {
    if ($NoOperatorPrompt) {
        if ($null -eq $savedNonInteractive) { Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue }
        else { $env:YURUNA_NONINTERACTIVE = $savedNonInteractive }
    }
}
exit $exitCode
