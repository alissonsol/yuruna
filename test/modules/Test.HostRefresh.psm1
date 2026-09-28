<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42b6904c-f865-423b-822a-edb5cb5994fe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh virtualization rung repair
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostRefreshIntent.psm1') -DisableNameChecking

# Host refresh: the repair-ladder declaration, the local repair worker and
# everything a caller needs around it (budget, verdict and exit code, public
# progress projection, context and identity resolution, command closure).
#
# The module holds no driver import. The generated status-server child loads
# it through Import-RouteModule to advertise the capability without ever
# calling Initialize-YurunaHost; loading a driver there would force-import
# Test.CachingProxyService and run that driver's contract-coverage check
# inside the listener. Every driver, service-evidence and runner-protocol
# command the worker uses is therefore resolved by name at call time, and a
# missing one is a structured refusal or a skipped rung, never a crash.

$script:HostRefreshProtocolVersion = 1
$script:HostRefreshHostTypes = @('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v')
$script:HostRefreshPlatform = @{ 'host.macos.utm' = 'macos'; 'host.ubuntu.kvm' = 'linux'; 'host.windows.hyper-v' = 'windows' }
$script:HostRefreshRunnerPlatform = @{ 'host.macos.utm' = 'MacOS'; 'host.ubuntu.kvm' = 'Linux'; 'host.windows.hyper-v' = 'Windows' }
$script:HostRefreshTierCeiling = @{ restart = 4; full = 6 }
# One budget for a local invocation. The ladder gets 600 s from admission but
# never runs into the 240 s convergence reserve or the 15 s reporting reserve;
# pre-admission work (startup, identity, lock, relaunch) has 60 s of its own.
$script:HostRefreshBudgetMs = [ordered]@{
    Total        = [long]915000
    PreAdmission = [long]60000
    Ladder       = [long]600000
    Convergence  = [long]240000
    Reporting    = [long]15000
}

# Static facts of every rung on every host: the ladder is always reported
# whole, unavailable rungs included, so every surface can say why a rung is
# closed.
$script:HostRefreshRungCatalog = @{
    'host.macos.utm'       = @(
        @{ Name = 'probe'; Order = 0; Destructive = $false; RequiresElevation = $false; RequiresSession = $false; EstimatedSeconds = 5 }
        # A restarted runner drives UTM, which needs the desktop session.
        @{ Name = 'reclaim'; Order = 1; Destructive = $false; RequiresElevation = $false; RequiresSession = $true; EstimatedSeconds = 30 }
        @{ Name = 'start-if-stopped'; Order = 2; Destructive = $false; RequiresElevation = $false; RequiresSession = $true; EstimatedSeconds = 60 }
        @{ Name = 'restart-if-hung'; Order = 3; Destructive = $true; RequiresElevation = $false; RequiresSession = $true; EstimatedSeconds = 120 }
        @{ Name = 'restart-broker'; Order = 4; Destructive = $true; RequiresElevation = $true; RequiresSession = $true; EstimatedSeconds = 60 }
        @{ Name = 'reapply-settings'; Order = 5; Destructive = $true; RequiresElevation = $true; RequiresSession = $true; EstimatedSeconds = 300 }
        @{ Name = 'reinstall'; Order = 6; Destructive = $true; RequiresElevation = $true; RequiresSession = $true; EstimatedSeconds = 900 }
        @{ Name = 'reboot'; Order = 7; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 300 }
    )
    'host.ubuntu.kvm'      = @(
        @{ Name = 'probe'; Order = 0; Destructive = $false; RequiresElevation = $false; RequiresSession = $false; EstimatedSeconds = 5 }
        @{ Name = 'reclaim'; Order = 1; Destructive = $false; RequiresElevation = $false; RequiresSession = $false; EstimatedSeconds = 30 }
        @{ Name = 'start-if-stopped'; Order = 2; Destructive = $false; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 60 }
        @{ Name = 'restart-if-hung'; Order = 3; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 60 }
        @{ Name = 'restart-broker'; Order = 4; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 30 }
        @{ Name = 'reapply-settings'; Order = 5; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 120 }
        @{ Name = 'reinstall'; Order = 6; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 900 }
        @{ Name = 'reboot'; Order = 7; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 300 }
    )
    'host.windows.hyper-v' = @(
        @{ Name = 'probe'; Order = 0; Destructive = $false; RequiresElevation = $false; RequiresSession = $false; EstimatedSeconds = 5 }
        @{ Name = 'reclaim'; Order = 1; Destructive = $false; RequiresElevation = $false; RequiresSession = $false; EstimatedSeconds = 30 }
        @{ Name = 'start-if-stopped'; Order = 2; Destructive = $false; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 60 }
        @{ Name = 'restart-if-hung'; Order = 3; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 120 }
        @{ Name = 'restart-broker'; Order = 4; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 30 }
        @{ Name = 'reapply-settings'; Order = 5; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 120 }
        @{ Name = 'reinstall'; Order = 6; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 900 }
        @{ Name = 'reboot'; Order = 7; Destructive = $true; RequiresElevation = $true; RequiresSession = $false; EstimatedSeconds = 300 }
    )
}
# The declaration: 'available' or the code that says why not. Enabling a rung
# is one entry here plus the recorded canary evidence the release gates list.
$script:HostRefreshRungStatus = @{
    'host.macos.utm'       = @{
        'probe' = 'available'; 'reclaim' = 'available'; 'start-if-stopped' = 'gui-launch-unqualified'
        'restart-if-hung' = 'utm-restart-unqualified'; 'restart-broker' = 'broker-recipe-missing'
        'reapply-settings' = 'settings-recipe-unsafe'; 'reinstall' = 'package-recovery-unqualified'; 'reboot' = 'no-reboot-supervision'
    }
    'host.ubuntu.kvm'      = @{
        'probe' = 'available'; 'reclaim' = 'available'; 'start-if-stopped' = 'available'
        'restart-if-hung' = 'daemon-layout-unqualified'; 'restart-broker' = 'modular-daemon-recipe-missing'
        'reapply-settings' = 'settings-recipe-unsafe'; 'reinstall' = 'unsupported-on-platform'; 'reboot' = 'no-reboot-supervision'
    }
    'host.windows.hyper-v' = @{
        'probe' = 'available'; 'reclaim' = 'available'; 'start-if-stopped' = 'available'
        'restart-if-hung' = 'provider-recipe-missing'; 'restart-broker' = 'unsupported-on-platform'
        'reapply-settings' = 'settings-recipe-unsafe'; 'reinstall' = 'unsupported-on-platform'; 'reboot' = 'no-reboot-supervision'
    }
}
# Rungs this module can execute. A rung without an executor is never
# available, whatever the declaration says.
$script:HostRefreshRungExecutor = [ordered]@{
    'probe'            = 'Invoke-HostRefreshProbeRung'
    'reclaim'          = 'Invoke-HostRefreshReclaimRung'
    'start-if-stopped' = 'Invoke-HostRefreshStartIfStoppedRung'
    'restart-if-hung'  = 'Invoke-HostRefreshRestartIfHungRung'
}
# What each rung's executor calls outside this module, with the file that
# must define and export it. 'driver' is the host's Yuruna.Host.psm1. The
# executor-honesty test checks every available rung against its sources, and
# the worker checks the same list at run time before acting.
$script:HostRefreshRungRequiredCommand = [ordered]@{
    'probe'            = @(
        @{ Name = 'Test-VirtualizationResponsive'; Source = 'driver' }
    )
    'reclaim'          = @(
        @{ Name = 'Get-YurunaRunnerSnapshot'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'New-YurunaRunnerReclaimPlan'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Compare-YurunaRunnerReclaimPlan'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Stop-YurunaRunnerProcessTarget'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Remove-YurunaRunnerRecordGeneration'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Get-YurunaRunnerProtocolCapability'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Get-YurunaRefreshGateState'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Set-YurunaRefreshGate'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Read-YurunaRunnerLaunchRecord'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Invoke-YurunaRunnerRefreshResume'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Resolve-StaleBreakActive'; Source = 'test/modules/Test.Recovery.psm1' }
    )
    'start-if-stopped' = @(
        @{ Name = 'Start-VirtualizationServiceIfStopped'; Source = 'driver' }
        @{ Name = 'Get-YurunaRefreshGateState'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Set-YurunaRefreshGate'; Source = 'test/modules/Test.SingleInstance.psm1' }
    )
    'restart-if-hung'  = @(
        @{ Name = 'Restart-UtmApplication'; Source = 'driver' }
        @{ Name = 'Resume-YurunaServiceVM'; Source = 'driver' }
        @{ Name = 'Resolve-UtmctlExecutable'; Source = 'driver' }
        @{ Name = 'Set-MacUtmctlLink'; Source = 'test/modules/Test.HostCondition.Mac.psm1' }
        @{ Name = 'Get-YurunaServiceVmIdentitySet'; Source = 'test/modules/Test.ServiceCensus.psm1' }
        @{ Name = 'Enter-YurunaServiceOperationLockSet'; Source = 'test/modules/Test.ServiceCensus.psm1' }
        @{ Name = 'Exit-YurunaServiceOperationLockSet'; Source = 'test/modules/Test.ServiceCensus.psm1' }
        @{ Name = 'Get-YurunaServiceIntent'; Source = 'test/modules/Test.ServiceCensus.psm1' }
        @{ Name = 'Test-YurunaServiceVmRunning'; Source = 'test/modules/Test.ServiceVm.psm1' }
        @{ Name = 'Restore-YurunaServiceVM'; Source = 'test/modules/Test.ServiceVm.psm1' }
        @{ Name = 'Get-YurunaRunnerSnapshot'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'New-YurunaRunnerReclaimPlan'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Compare-YurunaRunnerReclaimPlan'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Get-YurunaRefreshGateState'; Source = 'test/modules/Test.SingleInstance.psm1' }
        @{ Name = 'Set-YurunaRefreshGate'; Source = 'test/modules/Test.SingleInstance.psm1' }
    )
}
# Commands the worker needs before any rung, and the module each must come
# from. A fresh -NoProfile process resolves every row after loading the
# module set; ExecutingOnly rows are not needed by a read-only preview.
$script:HostRefreshRequiredCommand = @(
    @{ Name = 'Get-HostType'; Module = 'Test.HostDetection'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Test-LibvirtGroupReExecNeeded'; Module = 'Test.HostDetection'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Invoke-LibvirtGroupReExecIfNeeded'; Module = 'Test.HostDetection'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Initialize-YurunaHost'; Module = 'Test.HostBootstrap'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Read-TestConfig'; Module = 'Test.Config'; Stage = 'Startup'; ExecutingOnly = $true }
    @{ Name = 'ConvertFrom-Yaml'; Module = 'powershell-yaml'; Stage = 'Startup'; ExecutingOnly = $true }
    @{ Name = 'Write-OuterLog'; Module = 'Test.OuterLog'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Write-YurunaStateFileJson'; Module = 'Test.StateFile'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Enter-YurunaSingleFlightLock'; Module = 'Test.SingleFlightLock'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Exit-YurunaSingleFlightLock'; Module = 'Test.SingleFlightLock'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Test-YurunaSingleFlightLockOwned'; Module = 'Test.SingleFlightLock'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaLockRank'; Module = 'Test.SingleFlightLock'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaSingleFlightLockQualification'; Module = 'Test.SingleFlightLock'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Write-YurunaCriticalRecord'; Module = 'Test.CriticalRecord'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Read-YurunaCriticalRecord'; Module = 'Test.CriticalRecord'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Invoke-BoundedNativeCommand'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Test-BoundedNativeResultComplete'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'New-YurunaDeadline'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'New-YurunaDeadlineFromExpiry'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaDeadlineRemainingMs'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaDeadlineBoundedSeconds'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Wait-YurunaDeadlineInterval'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaPrivateStateRoot'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaCurrentOwnerId'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-YurunaPathOwnerId'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Resolve-YurunaCanonicalPath'; Module = 'Yuruna.Common'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Get-PwshExePath'; Module = 'Test.InnerSpawn'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Confirm-HostRefreshIntent'; Module = 'Test.HostRefreshIntent'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Save-HostRefreshRecoveryRecord'; Module = 'Test.HostRefreshIntent'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Complete-HostRefreshAttempt'; Module = 'Test.HostRefreshIntent'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Invoke-HostRefreshWorker'; Module = 'Test.HostRefresh'; Stage = 'Startup'; ExecutingOnly = $false }
    @{ Name = 'Test-VirtualizationResponsive'; Module = 'Yuruna.Host'; Stage = 'Driver'; ExecutingOnly = $false }
)
# The refresh module set, dependencies before dependents, and what it leaves
# out on purpose: the worker never loads the outer loop (it brings the
# unpruned tree kill), never writes cycle events or a failure record, and
# lets the service modules import their own helper module.
$script:HostRefreshModuleSet = @(
    'Test.HostContract.psm1', 'Test.YurunaDir.psm1', 'Test.Config.psm1', 'Test.StateFile.psm1', 'Test.OuterLog.psm1',
    'Test.SingleFlightLock.psm1', 'Test.CriticalRecord.psm1', 'Test.SingleInstance.psm1', 'Test.InnerSpawn.psm1',
    'Test.Recovery.psm1', 'Test.ServiceCensus.psm1', 'Test.ServiceVm.psm1', 'Test.HostRefreshIntent.psm1', 'Test.HostRefresh.psm1'
)
$script:HostRefreshExcludedModule = [ordered]@{
    'Test.RunnerOuterLoop.psm1'      = 'tree-kill-helper'
    'Test.Log.psm1'                  = 'no-cycle-events'
    'Test.EventSchema.psm1'          = 'no-cycle-events'
    'Test.SequenceFailureState.psm1' = 'no-failure-record'
    'Test.ExtensionService.psm1'     = 'imported-by-dependents'
}
$script:HostRefreshVerdictExitCode = @{
    'repaired' = 0; 'already-healthy' = 0; 'preview' = 0; 'disposed' = 0
    'refused' = 1; 'failed' = 1
    'partial' = 2; 'still-unresponsive' = 2; 'abandoned' = 2
}
$script:HostRefreshOperatorFixableReason = @('permission-denied', 'no-session', 'missing-client')
$script:HostRefreshPublicPhase = @('queued', 'starting', 'claimed', 'capturing', 'probing', 'climbing', 'converging', 'reporting', 'terminal')
$script:HostRefreshPublicState = @('queued', 'running', 'recovery_pending', 'completed', 'refused', 'abandoned')
$script:HostRefreshPublicChannel = @('local', 'listener', 'remote', 'automatic')
$script:HostRefreshPublicVerdict = @('repaired', 'already_healthy', 'refused', 'failed', 'partial', 'still_unresponsive', 'abandoned', 'preview', 'disposed')
$script:HostRefreshPublicAction = @('resume_request', 'start_runner', 'grant_automation', 'gui_session', 'dispose_obligations', 'elevate', 'install_client')
$script:HostRefreshReasonCodeLimit = 24
# The rendered reason of every unavailable-rung code, one catalog key each.
$script:HostRefreshRungReasonKey = @{
    'runner-restart-unqualified' = 'runner.host_refresh_rung_reason_runner_restart_unqualified'
    'gui-launch-unqualified' = 'runner.host_refresh_rung_reason_gui_launch_unqualified'
    'vmms-start-unqualified' = 'runner.host_refresh_rung_reason_vmms_start_unqualified'
    'utm-restart-unqualified' = 'runner.host_refresh_rung_reason_utm_restart_unqualified'
    'daemon-layout-unqualified' = 'runner.host_refresh_rung_reason_daemon_layout_unqualified'
    'provider-recipe-missing' = 'runner.host_refresh_rung_reason_provider_recipe_missing'
    'broker-recipe-missing' = 'runner.host_refresh_rung_reason_broker_recipe_missing'
    'modular-daemon-recipe-missing' = 'runner.host_refresh_rung_reason_modular_daemon_recipe_missing'
    'settings-recipe-unsafe' = 'runner.host_refresh_rung_reason_settings_recipe_unsafe'
    'package-recovery-unqualified' = 'runner.host_refresh_rung_reason_package_recovery_unqualified'
    'unsupported-on-platform' = 'runner.host_refresh_rung_reason_unsupported_on_platform'
    'no-reboot-supervision' = 'runner.host_refresh_rung_reason_no_reboot_supervision'
    'not-implemented' = 'runner.host_refresh_rung_reason_not_implemented'
    'lock-unqualified' = 'runner.host_refresh_rung_reason_lock_unqualified'
}
# The next-step line of every operator action.
$script:HostRefreshActionKey = @{
    'resume-request' = 'runner.host_refresh_action_resume_request'
    'start-runner' = 'runner.host_refresh_action_start_runner'
    'grant-automation' = 'runner.host_refresh_action_grant_automation'
    'gui-session' = 'runner.host_refresh_action_gui_session'
    'dispose-obligations' = 'runner.host_refresh_action_dispose_obligations'
    'elevate' = 'runner.host_refresh_action_elevate'
    'install-client' = 'runner.host_refresh_action_install_client'
}
$script:HostRefreshControlName = @(
    'control.step-pause', 'control.cycle-pause', 'control.pause', 'control.lab-hold', 'lab-hold.json',
    'control.lab-hold-release', 'control.cycle-restart', 'break-active.json'
)

# --- REGION: Small private helpers
function Get-HostRefreshCommand {
    <#
    .SYNOPSIS
        Resolve a command by name at call time; an alias resolves to its
        target. $null when absent.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.CommandType -eq 'Alias' -and $command.ResolvedCommand) { return $command.ResolvedCommand }
    return $command
}

function Test-HostRefreshCommandParameter {
    <#
    .SYNOPSIS
        True when a resolvable command declares a parameter.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Parameter)
    $command = Get-HostRefreshCommand -Name $Name
    if (-not $command) { return $false }
    try { return [bool]($command.Parameters -and $command.Parameters.ContainsKey($Parameter)) } catch { return $false }
}

function Get-HostRefreshRepoRoot {
    <#
    .SYNOPSIS
        The repository root this module belongs to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-HostRefreshUtcText {
    <#
    .SYNOPSIS
        Now, as ISO-8601 UTC text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [DateTime]::UtcNow.ToString('o')
}

function Add-HostRefreshReasonCode {
    <#
    .SYNOPSIS
        Append a private reason token to a worker state once.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [AllowEmptyString()][string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return }
    $token = $Code.ToLowerInvariant()
    if (-not $State.ReasonCodes.Contains($token)) { $State.ReasonCodes.Add($token) }
}

function Get-HostRefreshProcessIdentity {
    <#
    .SYNOPSIS
        pid and start time (Unix ms) of a process, or $null when it cannot be
        read.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        return [ordered]@{ pid = $ProcessId; startTimeUnixMs = [long][DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds() }
    } catch {
        return $null
    }
}

# --- REGION: Ladder declaration
function Get-VirtualizationRepairRung {
    <#
    .SYNOPSIS
        The complete repair ladder for a host type, as a pure declaration.
    .DESCRIPTION
        Every rung is returned, unavailable ones included, so a caller and
        the UI can always show the whole ladder and why each closed rung is
        closed. Available means this module can execute the rung on this
        platform today: the declaration says so, an executor exists, the
        lifetime lock's exclusion is qualified on the platform (every rung
        above the probe mutates something), and for reclaim the runner
        protocol is qualified there too. Nothing here probes the live host;
        dynamic prerequisites (is the runner dead, is a desktop session
        present) are the worker's, at the moment it climbs.
    .PARAMETER HostType
        The long form Get-HostType returns.
    .OUTPUTS
        One row per rung: Name; Order; Destructive; RequiresElevation;
        RequiresSession; EstimatedSeconds; Available; UnavailableCode;
        UnavailableReason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v')]
        [string]$HostType
    )
    $platform = $script:HostRefreshPlatform[$HostType]
    $lockQualified = $false
    try { $lockQualified = [bool](Get-YurunaSingleFlightLockQualification -Platform $platform).PlatformQualified } catch { $lockQualified = $false }
    $runnerQualified = $false
    if (Get-HostRefreshCommand -Name 'Get-YurunaRunnerProtocolCapability') {
        try { $runnerQualified = [bool](Get-YurunaRunnerProtocolCapability -Platform $script:HostRefreshRunnerPlatform[$HostType]).Available } catch { $runnerQualified = $false }
    }
    foreach ($row in $script:HostRefreshRungCatalog[$HostType]) {
        $code = [string]$script:HostRefreshRungStatus[$HostType][$row.Name]
        if ($code -eq 'available') {
            $executor = $script:HostRefreshRungExecutor[$row.Name]
            if (-not $executor -or -not (Get-Command -Name $executor -CommandType Function -ErrorAction SilentlyContinue)) { $code = 'not-implemented' }
            elseif ($row.Order -ge 1 -and -not $lockQualified) { $code = 'lock-unqualified' }
            elseif ($row.Name -eq 'reclaim' -and -not $runnerQualified) { $code = 'runner-restart-unqualified' }
        }
        $available = ($code -eq 'available')
        [pscustomobject][ordered]@{
            Name              = [string]$row.Name
            Order             = [int]$row.Order
            Destructive       = [bool]$row.Destructive
            RequiresElevation = [bool]$row.RequiresElevation
            RequiresSession   = [bool]$row.RequiresSession
            EstimatedSeconds  = [int]$row.EstimatedSeconds
            Available         = $available
            UnavailableCode   = if ($available) { $null } else { $code }
            UnavailableReason = if ($available) { $null } else { Format-YurunaOperatorMessage -Key $script:HostRefreshRungReasonKey[$code] }
        }
    }
}

function Get-HostRefreshRungCeiling {
    <#
    .SYNOPSIS
        The highest rung order a request may climb to.
    .DESCRIPTION
        restart covers orders 0-4 and full 0-6; reboot belongs to no tier.
        MaxRung only lowers the tier ceiling, never raises it.
    .PARAMETER HostType
        Long host type.
    .PARAMETER Tier
        restart or full.
    .PARAMETER MaxRung
        Optional rung name.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason; TierCeilingOrder; CeilingOrder; CeilingName }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Tier,
        [string]$MaxRung
    )
    $record = [ordered]@{ Valid = $false; Reason = $null; TierCeilingOrder = -1; CeilingOrder = -1; CeilingName = $null }
    if ($HostType -notin $script:HostRefreshHostTypes) { $record.Reason = 'unsupported-host'; return [pscustomobject]$record }
    if (-not $script:HostRefreshTierCeiling.ContainsKey($Tier)) { $record.Reason = 'unknown-tier'; return [pscustomobject]$record }
    $tierOrder = [int]$script:HostRefreshTierCeiling[$Tier]
    $ceiling = $tierOrder
    $rows = $script:HostRefreshRungCatalog[$HostType]
    if ($MaxRung) {
        $named = @($rows | Where-Object { $_.Name -ceq $MaxRung })
        if ($named.Count -eq 0) { $record.Reason = 'unknown-rung'; $record.TierCeilingOrder = $tierOrder; return [pscustomobject]$record }
        $ceiling = [Math]::Min($tierOrder, [int]$named[0].Order)
    }
    $record.Valid = $true
    $record.Reason = 'ok'
    $record.TierCeilingOrder = $tierOrder
    $record.CeilingOrder = $ceiling
    $record.CeilingName = [string](@($rows | Where-Object { $_.Order -eq $ceiling })[0].Name)
    return [pscustomobject]$record
}

function Get-HostRefreshProtocolVersion {
    <#
    .SYNOPSIS
        The refresh protocol version the checkout declares, compared with the
        one this code implements.
    .DESCRIPTION
        test/host-refresh.protocol-version is one ASCII line; the macOS
        bootstrap reads the same file before it dispatches here, so both
        sides agree on what the entry point accepts.
    .PARAMETER RepoRoot
        Defaults to this module's repository.
    .OUTPUTS
        [pscustomobject] @{ Valid; Version; Expected; Reason ok|missing|unreadable|malformed|mismatch; Path }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RepoRoot)
    if (-not $RepoRoot) { $RepoRoot = Get-HostRefreshRepoRoot }
    $path = Join-Path $RepoRoot 'test/host-refresh.protocol-version'
    $record = [ordered]@{ Valid = $false; Version = $null; Expected = $script:HostRefreshProtocolVersion; Reason = $null; Path = $path }
    if (-not [System.IO.File]::Exists($path)) { $record.Reason = 'missing'; return [pscustomobject]$record }
    $text = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -gt 64) { $record.Reason = 'malformed'; return [pscustomobject]$record }
        $text = [System.Text.Encoding]::ASCII.GetString($bytes).Trim()
    } catch {
        $record.Reason = 'unreadable'
        return [pscustomobject]$record
    }
    $version = 0
    if ($text -notmatch '^[0-9]{1,6}$' -or -not [int]::TryParse($text, [ref]$version)) { $record.Reason = 'malformed'; return [pscustomobject]$record }
    $record.Version = $version
    if ($version -ne $script:HostRefreshProtocolVersion) { $record.Reason = 'mismatch'; return [pscustomobject]$record }
    $record.Valid = $true
    $record.Reason = 'ok'
    return [pscustomobject]$record
}

function Get-HostRefreshCapability {
    <#
    .SYNOPSIS
        The compact refresh capability summary a listener advertises.
    .DESCRIPTION
        Wire spelling, at most a few hundred bytes: protocol, availability,
        ceiling (the highest available rung of orders 1-4), reason and state.
        Pure apart from reading the protocol file and one lock-free journal
        read; it never calls a driver or a native command and never throws.
        The listener adds the remote field itself.
    .PARAMETER HostType
        Long host type.
    .PARAMETER RepoRoot
        Defaults to this module's repository.
    .PARAMETER JournalPath
        Defaults to the private journal path (never creating anything).
    .OUTPUTS
        [ordered] @{ protocol; availability; ceiling; reason; state }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostType,
        [string]$RepoRoot,
        [string]$JournalPath
    )
    $summary = [ordered]@{ protocol = $script:HostRefreshProtocolVersion; availability = 'unavailable'; ceiling = ''; reason = ''; state = 'unknown' }
    try {
        $read = if ($JournalPath) { Read-HostRefreshJournal -JournalPath $JournalPath } else { Read-HostRefreshJournal }
        switch ($read.Status) {
            'absent' { $summary.state = 'idle' }
            { $_ -in @('ok', 'recovered-previous') } {
                $blocking = $null
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                foreach ($request in $read.Journal.requests) {
                    $state = [string]$request['state']
                    $armed = @($request['obligations'] | Where-Object { [string]$_['status'] -eq 'armed' }).Count
                    $queuedLive = ($state -eq 'queued') -and ($now -lt [long]$request['createdUnixMs'] -or ($now - [long]$request['createdUnixMs']) -lt 1800000)
                    if ($state -eq 'running' -or $queuedLive) { $blocking = 'active'; break }
                    if ($state -eq 'recovery-pending' -or ($state -eq 'abandoned' -and $armed -gt 0)) { $blocking = 'recovery_pending' }
                }
                $summary.state = if ($blocking) { $blocking } else { 'idle' }
            }
            default { $summary.state = 'unknown' }
        }
        if ($HostType -notin $script:HostRefreshHostTypes) { $summary.reason = 'unsupported_host'; return $summary }
        $protocol = Get-HostRefreshProtocolVersion -RepoRoot $RepoRoot
        if (-not $protocol.Valid) { $summary.reason = 'protocol_unreadable'; return $summary }
        if ($read.Status -notin @('ok', 'recovered-previous', 'absent')) { $summary.reason = 'journal_unreadable'; return $summary }
        $best = @(Get-VirtualizationRepairRung -HostType $HostType | Where-Object { $_.Available -and $_.Order -ge 1 -and $_.Order -le 4 } |
                Sort-Object Order -Descending)
        if ($best.Count -eq 0) { $summary.reason = 'no_qualified_rung'; return $summary }
        $summary.availability = 'available'
        $summary.ceiling = [string]$best[0].Name
        return $summary
    } catch {
        Write-Verbose "Get-HostRefreshCapability: $($_.Exception.Message)"
        return [ordered]@{ protocol = $script:HostRefreshProtocolVersion; availability = 'unavailable'; ceiling = ''; reason = 'capability_unavailable'; state = 'unknown' }
    }
}

# --- REGION: Budget
function New-HostRefreshBudget {
    <#
    .SYNOPSIS
        The whole-invocation time budget, on the boot-relative tick clock.
    .DESCRIPTION
        Total expiry is at most 915 s from now and pre-admission expiry at
        most 60 s from now and never after the total. A supplied expiry
        (from a relaunch or a launcher) can only shorten either one; values
        above the Int32 range are ordinary [long] ticks.
    .PARAMETER ExpiryTick
        A total expiry tick received from a parent process.
    .PARAMETER PreAdmissionExpiryTick
        A pre-admission expiry tick received from a parent process.
    .PARAMETER ClockTicks
        Injected clock for tests.
    .OUTPUTS
        [pscustomobject] Yuruna.HostRefreshBudget
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [long]$ExpiryTick,
        [long]$PreAdmissionExpiryTick,
        [scriptblock]$ClockTicks
    )
    $clock = if ($ClockTicks) { $ClockTicks } else { { [Environment]::TickCount64 } }
    $now = [long](& $clock)
    $maxTotal = $now + $script:HostRefreshBudgetMs.Total
    $total = $maxTotal
    $clamped = $false
    if ($PSBoundParameters.ContainsKey('ExpiryTick')) {
        if ($ExpiryTick -gt $maxTotal) { $clamped = $true } else { $total = $ExpiryTick }
    }
    $pre = [Math]::Min($now + $script:HostRefreshBudgetMs.PreAdmission, $total)
    if ($PSBoundParameters.ContainsKey('PreAdmissionExpiryTick')) {
        if ($PreAdmissionExpiryTick -gt $pre) { $clamped = $true } else { $pre = $PreAdmissionExpiryTick }
    }
    return [pscustomobject]@{
        PSTypeName             = 'Yuruna.HostRefreshBudget'
        StartTick              = $now
        TotalExpiryTick        = [long]$total
        PreAdmissionExpiryTick = [long]$pre
        AdmittedTick           = $null
        ClockTicks             = $clock
        Clamped                = $clamped
    }
}

function Set-HostRefreshBudgetAdmitted {
    <#
    .SYNOPSIS
        A copy of a budget that records the admission instant.
    .PARAMETER Budget
        The budget from New-HostRefreshBudget.
    .OUTPUTS
        [pscustomobject] Yuruna.HostRefreshBudget
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory record; the input is not modified.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Budget)
    $now = [long](& $Budget.ClockTicks)
    return [pscustomobject]@{
        PSTypeName             = 'Yuruna.HostRefreshBudget'
        StartTick              = [long]$Budget.StartTick
        TotalExpiryTick        = [long]$Budget.TotalExpiryTick
        PreAdmissionExpiryTick = [long]$Budget.PreAdmissionExpiryTick
        AdmittedTick           = $now
        ClockTicks             = $Budget.ClockTicks
        Clamped                = [bool]$Budget.Clamped
    }
}

function Get-HostRefreshPhaseDeadline {
    <#
    .SYNOPSIS
        The deadline of one phase, carved from the invocation budget.
    .DESCRIPTION
        PreAdmission: the pre-admission expiry. Ladder: 600 s after
        admission, never past the total less the convergence and reporting
        reserves. Convergence: 240 s from its start, never past the total
        less the reporting reserve. Reporting: 15 s from its start, never
        past the total.
    .PARAMETER Budget
        The budget.
    .PARAMETER Phase
        PreAdmission, Ladder, Convergence or Reporting.
    .PARAMETER StartTick
        The phase start; defaults to now.
    .OUTPUTS
        [pscustomobject] a Yuruna.Deadline
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Budget,
        [Parameter(Mandatory)][ValidateSet('PreAdmission', 'Ladder', 'Convergence', 'Reporting')][string]$Phase,
        [long]$StartTick
    )
    $clock = $Budget.ClockTicks
    $start = if ($PSBoundParameters.ContainsKey('StartTick')) { $StartTick } else { [long](& $clock) }
    $total = [long]$Budget.TotalExpiryTick
    $expiry = switch ($Phase) {
        'PreAdmission' { [long]$Budget.PreAdmissionExpiryTick }
        'Ladder' {
            $admitted = if ($null -ne $Budget.AdmittedTick) { [long]$Budget.AdmittedTick } else { $start }
            [Math]::Min($admitted + $script:HostRefreshBudgetMs.Ladder, $total - $script:HostRefreshBudgetMs.Convergence - $script:HostRefreshBudgetMs.Reporting)
        }
        'Convergence' { [Math]::Min($start + $script:HostRefreshBudgetMs.Convergence, $total - $script:HostRefreshBudgetMs.Reporting) }
        'Reporting' { [Math]::Min($start + $script:HostRefreshBudgetMs.Reporting, $total) }
    }
    return (New-YurunaDeadlineFromExpiry -ExpiryTick ([long]$expiry) -ClockTicks $clock)
}

# --- REGION: Verdict and exit adapter
function Get-HostRefreshExitCode {
    <#
    .SYNOPSIS
        The process exit code of a verdict: 0 converged or previewed, 1
        refused or failed, 2 incomplete. An unknown verdict is 1.
    .PARAMETER Verdict
        The verdict token.
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Verdict)
    if ($script:HostRefreshVerdictExitCode.ContainsKey($Verdict)) { return [int]$script:HostRefreshVerdictExitCode[$Verdict] }
    return 1
}

function Get-HostRefreshVerdict {
    <#
    .SYNOPSIS
        The verdict of an attempt from its facts; the first matching rule
        wins.
    .DESCRIPTION
         1. Preview -> preview
         2. Disposed -> disposed
         3. Refused before any mutation -> refused
         4. Attempts exhausted -> abandoned
         5. Execution error with nothing mutated and nothing armed -> failed
         6. Nothing mutated and the final probe Undetermined for a reason an
            operator fixes (permission-denied, no-session, missing-client)
            -> refused, with an operator action
         7. Final probe taken and not Responsive -> still-unresponsive
         8. An armed obligation outstanding, an unconverged expectation, an
            expired deadline, or an execution error after a mutation ->
            partial
         9. Mutated -> repaired
        10. Otherwise -> already-healthy
    .PARAMETER Facts
        Preview, Disposed, Refused, AttemptsExhausted, ExecutionError,
        Mutated, FinalProbeState, FinalProbeReason, ArmedOutstanding,
        UnconvergedExpectation, DeadlineExpired.
    .OUTPUTS
        [pscustomobject] @{ Verdict; ExitCode; State; ReasonCodes }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Facts)
    $armed = [int]$Facts['ArmedOutstanding']
    $mutated = [bool]$Facts['Mutated']
    $probeState = [string]$Facts['FinalProbeState']
    $probeReason = [string]$Facts['FinalProbeReason']
    $codes = [System.Collections.Generic.List[string]]::new()
    $verdict = if ([bool]$Facts['Preview']) { 'preview' }
    elseif ([bool]$Facts['Disposed']) { 'disposed' }
    elseif ([bool]$Facts['Refused']) { 'refused' }
    elseif ([bool]$Facts['AttemptsExhausted']) { 'abandoned' }
    elseif ([bool]$Facts['ExecutionError'] -and -not $mutated -and $armed -eq 0) { 'failed' }
    elseif (-not $mutated -and $probeState -eq 'Undetermined' -and $probeReason -in $script:HostRefreshOperatorFixableReason) { $codes.Add("probe-$probeReason"); 'refused' }
    elseif ($probeState -and $probeState -ne 'Responsive') { 'still-unresponsive' }
    elseif ($armed -gt 0 -or [int]$Facts['UnconvergedExpectation'] -gt 0 -or [bool]$Facts['DeadlineExpired'] -or [bool]$Facts['ExecutionError']) { 'partial' }
    elseif ($mutated) { 'repaired' }
    else { 'already-healthy' }
    $state = switch ($verdict) {
        'preview' { '' }
        'disposed' { '' }
        'refused' { if (-not $mutated -and $armed -eq 0) { 'refused' } elseif ($armed -gt 0) { 'recovery-pending' } else { 'completed' } }
        'abandoned' { 'abandoned' }
        default { if ($armed -gt 0) { 'recovery-pending' } else { 'completed' } }
    }
    return [pscustomobject]@{ Verdict = $verdict; ExitCode = (Get-HostRefreshExitCode -Verdict $verdict); State = $state; ReasonCodes = [string[]]$codes.ToArray() }
}

# --- REGION: Wire projection
function ConvertTo-HostRefreshWireCode {
    <#
    .SYNOPSIS
        A private hyphenated token in its wire spelling: lowercase, hyphens
        as underscores.
    .DESCRIPTION
        Private records keep hyphenated tokens; everything that crosses the
        listener, aggregator, pool-control or UI boundary is underscored.
        This is the only place the conversion happens.
    .PARAMETER Value
        The token.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.ToLowerInvariant().Replace('-', '_')
}

function ConvertTo-HostRefreshPublicState {
    <#
    .SYNOPSIS
        The allowlisted public projection of a worker snapshot.
    .DESCRIPTION
        Only the listed fields are copied, each validated against its enum or
        shape; everything else -- paths, pids, VM names, probe diagnostics,
        commands, tokens -- is dropped. Tokens are converted to their wire
        spelling. The runtime directory is served, so this is the only shape
        that ever lands there.
    .PARAMETER Snapshot
        A dictionary with any of: requestId, generation, attempt, channel,
        phase, state, heartbeatUtc, startedUtc, updatedUtc, step, remainingBudgetMs,
        reasonCodes, reportDegraded, mutated, verdict, operatorAction,
        terminalUtc.
    .OUTPUTS
        [ordered] schema-1 public state.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
    $text = { param($Value) if ($null -eq $Value) { '' } else { [string]$Value } }
    $enum = {
        param($Value, [string[]]$Allowed, [string]$Default)
        $wire = ConvertTo-HostRefreshWireCode -Value (& $text $Value)
        if ($wire -in $Allowed) { $wire } else { $Default }
    }
    $instant = {
        param($Value)
        $candidate = & $text $Value
        if ($candidate -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$') { $candidate } else { '' }
    }
    $requestId = & $text $Snapshot['requestId']
    if ($requestId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { $requestId = '' }
    $generation = & $text $Snapshot['generation']
    if ($generation -cnotmatch '^[0-9a-f]{32}$') { $generation = '' }
    $attempt = 0
    [void][int]::TryParse((& $text $Snapshot['attempt']), [ref]$attempt)
    $step = $Snapshot['step']
    $stepRecord = [ordered]@{ index = 0; count = 0; name = ''; boundMs = [long]0 }
    if ($step -is [System.Collections.IDictionary]) {
        $index = 0; $count = 0; $bound = [long]0
        [void][int]::TryParse((& $text $step['index']), [ref]$index)
        [void][int]::TryParse((& $text $step['count']), [ref]$count)
        [void][long]::TryParse((& $text $step['boundMs']), [ref]$bound)
        $name = & $text $step['name']
        if ($name -cnotmatch '^[a-z][a-z-]{0,31}$') { $name = '' }
        $stepRecord = [ordered]@{ index = [Math]::Max(0, $index); count = [Math]::Max(0, $count); name = $name; boundMs = [Math]::Max([long]0, $bound) }
    }
    $remaining = [long]0
    [void][long]::TryParse((& $text $Snapshot['remainingBudgetMs']), [ref]$remaining)
    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @($Snapshot['reasonCodes'])) {
        if ($null -eq $code) { continue }
        $wire = ConvertTo-HostRefreshWireCode -Value ([string]$code)
        if ($wire -cmatch '^[a-z0-9][a-z0-9_.]{0,63}$' -and -not $codes.Contains($wire)) { $codes.Add($wire) }
        if ($codes.Count -ge $script:HostRefreshReasonCodeLimit) { break }
    }
    return [ordered]@{
        schemaVersion     = 1
        requestId         = $requestId
        generation        = $generation
        attempt           = [Math]::Max(0, $attempt)
        channel           = (& $enum $Snapshot['channel'] $script:HostRefreshPublicChannel 'local')
        phase             = (& $enum $Snapshot['phase'] $script:HostRefreshPublicPhase 'starting')
        state             = (& $enum $Snapshot['state'] $script:HostRefreshPublicState 'running')
        heartbeatUtc      = (& $instant $Snapshot['heartbeatUtc'])
        startedUtc        = (& $instant $Snapshot['startedUtc'])
        updatedUtc        = (& $instant $Snapshot['updatedUtc'])
        step              = $stepRecord
        remainingBudgetMs = [Math]::Max([long]0, $remaining)
        reasonCodes       = [string[]]$codes.ToArray()
        reportDegraded    = [bool]$Snapshot['reportDegraded']
        mutated           = [bool]$Snapshot['mutated']
        verdict           = (& $enum $Snapshot['verdict'] $script:HostRefreshPublicVerdict '')
        operatorAction    = (& $enum $Snapshot['operatorAction'] $script:HostRefreshPublicAction '')
        terminalUtc       = (& $instant $Snapshot['terminalUtc'])
    }
}

# --- REGION: Progress publisher
# The heartbeat loop runs in its own runspace and only ever writes the latest
# projection the main thread handed it. Both it and the terminal write hold
# WriteGate, and the terminal write sets Released first, so no heartbeat can
# land after the terminal record.
$script:HostRefreshPublisherLoop = @'
param($Sync)
while ($true) {
    $null = $Sync.Wake.WaitOne([int][Math]::Min(1000, [int]$Sync.PeriodMs))
    $Sync.WriteGate.Wait()
    try {
        if ($Sync.Released) { break }
        $now = [Environment]::TickCount64
        $due = ([long]$Sync.Seq -ne [long]$Sync.LastWrittenSeq) -or (($now - [long]$Sync.LastWriteTick) -ge ([long]$Sync.PeriodMs - 1000))
        if ($due) {
            $snapshot = $null
            $seq = [long]0
            if ($Sync.StateGate.Wait(2000)) {
                try {
                    $snapshot = [ordered]@{}
                    foreach ($key in @($Sync.State.Keys)) { $snapshot[$key] = $Sync.State[$key] }
                    $seq = [long]$Sync.Seq
                } finally { $null = $Sync.StateGate.Release() }
            }
            if ($null -ne $snapshot) {
                $snapshot['heartbeatUtc'] = [DateTime]::UtcNow.ToString('o')
                $snapshot['remainingBudgetMs'] = [Math]::Max([long]0, [long]$Sync.ExpiryTick - $now)
                $written = $false
                try { $written = [bool](Write-YurunaStateFileJson -Path $Sync.Path -InputObject $snapshot -Depth 6 -Confirm:$false) } catch { $written = $false }
                if ($written) {
                    $Sync.LastWrittenSeq = $seq
                    $Sync.LastWriteTick = $now
                    $Sync.WriteCount = [int]$Sync.WriteCount + 1
                } else {
                    $Sync.Degraded = $true
                }
            }
        }
        if ($Sync.Stop) { break }
    } finally {
        $null = $Sync.WriteGate.Release()
    }
}
'@

function Start-HostRefreshProgressPublisher {
    <#
    .SYNOPSIS
        Start the one serialized writer of an attempt's public progress file,
        with a heartbeat at least every PeriodMilliseconds.
    .DESCRIPTION
        The initial projection is written before this returns. A failed write
        marks the publisher degraded and never throws: progress is best
        effort and the private journal stays authoritative.
    .PARAMETER Path
        <runtime>/host-refresh.state.json.
    .PARAMETER Initial
        The initial snapshot (see ConvertTo-HostRefreshPublicState).
    .PARAMETER ExpiryTick
        The budget's total expiry, for remainingBudgetMs.
    .PARAMETER PeriodMilliseconds
        Heartbeat period.
    .PARAMETER WriterModulePath
        Test seam: the module that provides Write-YurunaStateFileJson to the
        heartbeat runspace.
    .OUTPUTS
        [pscustomobject] Yuruna.HostRefreshPublisher
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Initial,
        [Parameter(Mandatory)][long]$ExpiryTick,
        [ValidateRange(1000, 60000)][int]$PeriodMilliseconds = 5000,
        [Parameter(DontShow)][string]$WriterModulePath
    )
    $raw = [ordered]@{}
    foreach ($key in $Initial.Keys) { $raw[[string]$key] = $Initial[$key] }
    $now = Get-HostRefreshUtcText
    if (-not $raw['startedUtc']) { $raw['startedUtc'] = $now }
    $raw['heartbeatUtc'] = $now
    $raw['updatedUtc'] = $now
    $sync = [hashtable]::Synchronized(@{
            Raw = $raw; State = (ConvertTo-HostRefreshPublicState -Snapshot $raw); Seq = [long]1; LastWrittenSeq = [long]0
            LastWriteTick = [long]0; WriteCount = 0; Released = $false; Stop = $false; Degraded = $false
            StateGate = [System.Threading.SemaphoreSlim]::new(1, 1); WriteGate = [System.Threading.SemaphoreSlim]::new(1, 1)
            Wake = [System.Threading.AutoResetEvent]::new($false); Path = $Path; ExpiryTick = $ExpiryTick; PeriodMs = $PeriodMilliseconds
            DegradedLogged = $false
        })
    $publisher = [pscustomobject]@{ PSTypeName = 'Yuruna.HostRefreshPublisher'; Sync = $sync; PowerShell = $null; Runspace = $null; Handle = $null; Started = $false }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_publish'))) { return $publisher }
    $first = $false
    try {
        $state = $sync.State
        $state['remainingBudgetMs'] = [Math]::Max([long]0, $ExpiryTick - [Environment]::TickCount64)
        $first = [bool](Write-YurunaStateFileJson -Path $Path -InputObject $state -Depth 6 -Confirm:$false)
    } catch { $first = $false }
    if ($first) { $sync.LastWrittenSeq = [long]1; $sync.LastWriteTick = [Environment]::TickCount64; $sync.WriteCount = 1 } else { $sync.Degraded = $true }
    try {
        $modulePath = if ($WriterModulePath) { $WriterModulePath } else { Join-Path $PSScriptRoot 'Test.StateFile.psm1' }
        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $initialState.ImportPSModule(@($modulePath))
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
        $runspace.Open()
        $shell = [System.Management.Automation.PowerShell]::Create()
        $shell.Runspace = $runspace
        $null = $shell.AddScript($script:HostRefreshPublisherLoop).AddArgument($sync)
        $publisher.PowerShell = $shell
        $publisher.Runspace = $runspace
        $publisher.Handle = $shell.BeginInvoke()
        $publisher.Started = $true
    } catch {
        Write-Verbose "Start-HostRefreshProgressPublisher: heartbeat runspace unavailable: $($_.Exception.Message)"
        $sync.Degraded = $true
    }
    return $publisher
}

function Update-HostRefreshProgress {
    <#
    .SYNOPSIS
        Merge a change into the published progress and wake the writer.
    .PARAMETER Publisher
        From Start-HostRefreshProgressPublisher.
    .PARAMETER Change
        Snapshot fields to change.
    .OUTPUTS
        [bool] $false when the publisher was already stopped or its state
        gate did not open within 2 s.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Publisher,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Change
    )
    if ($null -eq $Publisher -or $null -eq $Publisher.Sync) { return $false }
    if (-not $PSCmdlet.ShouldProcess([string]$Publisher.Sync.Path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_publish'))) { return $false }
    $sync = $Publisher.Sync
    if (-not $sync.StateGate.Wait(2000)) { return $false }
    try {
        if ($sync.Released) { return $false }
        foreach ($key in $Change.Keys) { $sync.Raw[[string]$key] = $Change[$key] }
        $now = Get-HostRefreshUtcText
        $sync.Raw['heartbeatUtc'] = $now
        $sync.Raw['updatedUtc'] = $now
        $sync.State = ConvertTo-HostRefreshPublicState -Snapshot $sync.Raw
        $sync.Seq = [long]$sync.Seq + 1
    } finally {
        $null = $sync.StateGate.Release()
    }
    if (-not $Publisher.Started) {
        # No heartbeat runspace: write inline so progress still advances.
        try { if (-not (Write-YurunaStateFileJson -Path $sync.Path -InputObject $sync.State -Depth 6 -Confirm:$false)) { $sync.Degraded = $true } } catch { $sync.Degraded = $true }
    } else {
        $null = $sync.Wake.Set()
    }
    return $true
}

function Stop-HostRefreshProgressPublisher {
    <#
    .SYNOPSIS
        Stop the heartbeat, then write the terminal projection last.
    .DESCRIPTION
        The terminal write holds the same gate as the heartbeat and marks the
        publisher released first, so no heartbeat can overwrite the terminal
        record. When the gate cannot be taken in time the publisher is still
        released and the terminal write is reported as not done.
    .PARAMETER Publisher
        From Start-HostRefreshProgressPublisher.
    .PARAMETER Terminal
        Snapshot fields of the terminal record (phase terminal, verdict ...).
    .PARAMETER TimeoutMilliseconds
        Longest wait for the writer.
    .OUTPUTS
        [pscustomobject] @{ TerminalWritten; ReportDegraded }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Publisher,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Terminal,
        [ValidateRange(0, 60000)][int]$TimeoutMilliseconds = 5000
    )
    if ($null -eq $Publisher -or $null -eq $Publisher.Sync) { return [pscustomobject]@{ TerminalWritten = $false; ReportDegraded = $true } }
    $sync = $Publisher.Sync
    if (-not $PSCmdlet.ShouldProcess([string]$sync.Path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_publish'))) {
        return [pscustomobject]@{ TerminalWritten = $false; ReportDegraded = [bool]$sync.Degraded }
    }
    $sync.Stop = $true
    $null = $sync.Wake.Set()
    $haveWrite = $sync.WriteGate.Wait($TimeoutMilliseconds)
    $haveState = $sync.StateGate.Wait($TimeoutMilliseconds)
    $sync.Released = $true
    $final = $null
    try {
        foreach ($key in $Terminal.Keys) { $sync.Raw[[string]$key] = $Terminal[$key] }
        $now = Get-HostRefreshUtcText
        $sync.Raw['heartbeatUtc'] = $now
        $sync.Raw['updatedUtc'] = $now
        if (-not $sync.Raw['terminalUtc']) { $sync.Raw['terminalUtc'] = $now }
        $sync.Raw['phase'] = 'terminal'
        $sync.Raw['remainingBudgetMs'] = [Math]::Max([long]0, [long]$sync.ExpiryTick - [Environment]::TickCount64)
        if ($sync.Degraded) { $sync.Raw['reportDegraded'] = $true }
        $final = ConvertTo-HostRefreshPublicState -Snapshot $sync.Raw
        $sync.State = $final
    } finally {
        if ($haveState) { $null = $sync.StateGate.Release() }
    }
    $written = $false
    if ($haveWrite) {
        try { $written = [bool](Write-YurunaStateFileJson -Path $sync.Path -InputObject $final -Depth 6 -Confirm:$false) } catch { $written = $false }
        finally { $null = $sync.WriteGate.Release() }
    }
    if ($Publisher.Handle) {
        try {
            if ($Publisher.Handle.AsyncWaitHandle.WaitOne(2000)) {
                try { $null = $Publisher.PowerShell.EndInvoke($Publisher.Handle) } catch { $null = $_ }
                try { $Publisher.PowerShell.Dispose() } catch { $null = $_ }
                try { $Publisher.Runspace.Dispose() } catch { $null = $_ }
            } else {
                try { $null = $Publisher.PowerShell.BeginStop($null, $null) } catch { $null = $_ }
            }
        } catch { $null = $_ }
    }
    if (-not $written) { $sync.Degraded = $true }
    return [pscustomobject]@{ TerminalWritten = $written; ReportDegraded = [bool]$sync.Degraded }
}

function Publish-HostRefreshQueuedState {
    <#
    .SYNOPSIS
        Publish the queued projection for a request a listener just
        launched.
    .DESCRIPTION
        Written once, before the worker claims anything, so a browser that
        polls right after its request sees the request id. The check and the
        write both happen under the journal's admission lock, and only while
        the journal still holds the request as queued. A worker claims under
        that same lock and publishes only after its claim, so this write can
        never land on top of anything the worker published, its terminal
        record included. A request that is already claimed returns $true (the
        worker owns the projection); an unknown request, a busy admission
        lock or an unreadable private root publishes nothing and returns
        $false.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER RequestId
        The launched request.
    .PARAMETER Channel
        listener or remote.
    .PARAMETER AdmissionWaitMilliseconds
        Wait for the admission lock.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('listener', 'remote')][string]$Channel,
        [ValidateRange(0, 60000)][int]$AdmissionWaitMilliseconds = 1000
    )
    $path = Join-Path $RuntimeDir 'host-refresh.state.json'
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_publish'))) { return $false }
    $lockPath = Get-YurunaHostRefreshAdmissionLockPath -NoCreate
    if (-not $lockPath) { return $false }
    $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds $AdmissionWaitMilliseconds -Rank (Get-YurunaLockRank -Name Admission) `
        -Metadata @{ purpose = 'host-refresh-queued-projection' }
    if (-not $lock.Held) {
        Write-Verbose "Publish-HostRefreshQueuedState: admission lock not held ($($lock.Reason)); the worker publishes instead."
        return $false
    }
    try {
        $request = Read-YurunaHostRefreshRequest -RequestId $RequestId
        if (-not $request) { return $false }
        if ([string]$request['state'] -ne 'queued') { return $true }
        try {
            if ([System.IO.File]::Exists($path) -and ([System.IO.FileInfo]::new($path)).Length -le 65536) {
                $current = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($current -is [System.Collections.IDictionary] -and [string]$current['requestId'] -ceq $RequestId -and [string]$current['phase'] -ne 'queued') { return $true }
            }
        } catch {
            Write-Verbose "Publish-HostRefreshQueuedState: existing projection unreadable: $($_.Exception.Message)"
        }
        $now = Get-HostRefreshUtcText
        $projection = ConvertTo-HostRefreshPublicState -Snapshot @{
            requestId = $RequestId; generation = ''; attempt = 0; channel = $Channel; phase = 'queued'; state = 'queued'
            heartbeatUtc = $now; startedUtc = $now; updatedUtc = $now; step = @{ index = 0; count = 0; name = ''; boundMs = 0 }
            remainingBudgetMs = 0; reasonCodes = @(); reportDegraded = $false; mutated = $false; verdict = ''; operatorAction = ''; terminalUtc = ''
        }
        return [bool](Write-YurunaStateFileJson -Path $path -InputObject $projection -Depth 6 -Confirm:$false)
    } finally {
        Exit-YurunaSingleFlightLock -Lock $lock
    }
}

# --- REGION: Logging
function Write-HostRefreshLog {
    <#
    .SYNOPSIS
        Write one operator line: console always, outer.log when executing.
    .DESCRIPTION
        The message is rendered once from its catalog key. outer.log is served
        publicly, so a line that carries a manual command or a private path
        passes -ConsoleOnly. A preview never writes outer.log.
    .PARAMETER Key
        Catalog key.
    .PARAMETER Arguments
        Placeholder values.
    .PARAMETER Level
        Information, Warning or Error.
    .PARAMETER Preview
        Console only.
    .PARAMETER ConsoleOnly
        Never write outer.log.
    .OUTPUTS
        None; the line goes to the Information, Warning or Error stream.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{},
        [ValidateSet('Information', 'Warning', 'Error')][string]$Level = 'Information',
        [switch]$Preview,
        [switch]$ConsoleOnly
    )
    $text = Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments
    switch ($Level) {
        'Warning' { Write-Warning -Message $text }
        'Error' { Write-Error -Message $text -ErrorAction Continue }
        default { Write-Information -MessageData $text -Tags 'host-refresh' }
    }
    if ($Preview -or $ConsoleOnly -or [string]::IsNullOrWhiteSpace($env:YURUNA_RUNTIME_DIR)) { return }
    if (Get-HostRefreshCommand -Name 'Write-OuterLog') {
        try { Write-OuterLog -Message $text } catch { Write-Verbose "Write-HostRefreshLog: outer.log write failed: $($_.Exception.Message)" }
    }
}

function Write-HostRefreshSummary {
    <#
    .SYNOPSIS
        The human summary of a worker result, on the console and (executing)
        in outer.log.
    .PARAMETER Result
        A Yuruna.HostRefreshResult.
    .PARAMETER Preview
        Console only.
    .OUTPUTS
        None; every line goes through Write-HostRefreshLog.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]$Result,
        [switch]$Preview
    )
    $log = { param([string]$Key, [hashtable]$Arguments = @{}, [switch]$ConsoleOnly) Write-HostRefreshLog -Key $Key -Arguments $Arguments -Preview:$Preview -ConsoleOnly:$ConsoleOnly }
    $plan = $Result.plan
    $hostType = if ($Result.hostType) { [string]$Result.hostType } elseif ($plan) { [string]$plan.hostType } else { '' }
    & $log 'runner.host_refresh_summary_header' @{ mode = $(if ($Preview) { 'preview' } else { 'execute' }); hostType = $hostType }
    $probe = if ($Result.finalProbe) { $Result.finalProbe } else { $Result.initialProbe }
    if ($probe) { & $log 'runner.host_refresh_summary_probe' @{ state = "$($probe.state)"; reason = "$($probe.reason)"; elapsedMs = "$($probe.elapsedMs)" } }
    if ($Result.runnerStatus) { & $log 'runner.host_refresh_summary_runner' @{ status = "$($Result.runnerStatus)" } }
    if ($Result.context) {
        & $log 'runner.host_refresh_summary_context' @{ runtimeDir = "$($Result.context.RuntimeDir)"; configPath = "$($Result.context.ConfigPath)"; configSource = "$($Result.context.ConfigSource)" } -ConsoleOnly
    }
    if ($plan) {
        & $log 'runner.host_refresh_summary_ladder' @{ ceiling = "$($plan.ceiling)" }
        foreach ($rung in @($plan.rungs)) {
            if (-not $rung.inCeiling) { & $log 'runner.host_refresh_summary_rung_above_ceiling' @{ order = "$($rung.order)"; name = "$($rung.name)" } }
            elseif ($rung.available) { & $log 'runner.host_refresh_summary_rung_available' @{ order = "$($rung.order)"; name = "$($rung.name)" } }
            else { & $log 'runner.host_refresh_summary_rung_unavailable' @{ order = "$($rung.order)"; name = "$($rung.name)"; reason = "$($rung.unavailableReason)" } }
        }
        if ($plan.activeRequest) {
            & $log 'runner.host_refresh_summary_active_request' @{ requestId = "$($plan.activeRequest.requestId)"; state = "$($plan.activeRequest.state)"; attempt = "$($plan.activeRequest.attempt)" }
        }
        $consider = @($plan.rungs | Where-Object { $_.wouldConsider } | ForEach-Object { $_.name })
        if ($consider.Count -gt 0) { & $log 'runner.host_refresh_preview_would_consider' @{ rungs = ($consider -join ', ') } }
        if ($plan.groupRelaunch -and $plan.groupRelaunch.Needed) { & $log 'runner.host_refresh_preview_group_relaunch' @{ reason = "$($plan.groupRelaunch.Reason)" } }
        & $log 'runner.host_refresh_preview_notice'
    } else {
        foreach ($rung in @($Result.rungs)) {
            & $log 'runner.host_refresh_summary_rung_result' @{ order = "$($rung.order)"; name = "$($rung.name)"; outcome = "$($rung.outcome)"; reason = "$($rung.reason)" }
        }
        & $log 'runner.host_refresh_summary_verdict' @{ verdict = "$($Result.verdict)"; requestId = "$($Result.requestId)"; attempt = "$($Result.attempt)"; state = "$($Result.state)" }
        foreach ($obligation in @($Result.obligations | Where-Object { $_.status -eq 'armed' })) {
            & $log 'runner.host_refresh_summary_obligation' @{ obligation = "$($obligation.id)" }
        }
    }
    if ($Result.operatorAction) {
        $arguments = @{}
        switch ([string]$Result.operatorAction) {
            'dispose-obligations' { $arguments = @{ obligations = (@($Result.obligations | Where-Object { $_.status -eq 'armed' } | ForEach-Object { $_.id }) -join ',') } }
            'elevate' { $arguments = @{ rung = "$($Result.operatorActionRung)" } }
            'install-client' { $arguments = @{ client = "$($Result.operatorActionClient)" } }
        }
        $actionKey = $script:HostRefreshActionKey[[string]$Result.operatorAction]
        if ($actionKey) { & $log $actionKey $arguments }
    }
    foreach ($line in @($Result.operatorInstruction)) {
        if ($line) { & $log 'runner.host_refresh_operator_instruction' @{ instruction = "$line" } -ConsoleOnly }
    }
}

# --- REGION: Command closure, module set, relaunch and worker argv
function Get-HostRefreshModuleSet {
    <#
    .SYNOPSIS
        The refresh module set, in import order, or the modules it leaves out
        on purpose.
    .PARAMETER Excluded
        Emit the excluded modules as { Name; Reason } rows instead.
    .OUTPUTS
        [string] module file names, or rows with -Excluded.
    #>
    [CmdletBinding()]
    [OutputType([string], [pscustomobject])]
    param([switch]$Excluded)
    if ($Excluded) {
        foreach ($name in $script:HostRefreshExcludedModule.Keys) { [pscustomobject]@{ Name = [string]$name; Reason = [string]$script:HostRefreshExcludedModule[$name] } }
        return
    }
    foreach ($name in $script:HostRefreshModuleSet) { [string]$name }
}

function Get-HostRefreshRequiredCommand {
    <#
    .SYNOPSIS
        The commands the worker needs, with the module each must come from.
    .PARAMETER HostType
        Long host type; required for the Driver stage and for rungs.
    .PARAMETER Stage
        Startup or Driver; both when omitted.
    .PARAMETER Rung
        Rung names whose executor commands to include.
    .PARAMETER Preview
        Leave out commands only an executing run needs.
    .OUTPUTS
        Rows { Name; Module; Stage; Rung; Source } where Source is the
        repository-relative file that must define and export the command.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$HostType,
        [ValidateSet('Startup', 'Driver')][string]$Stage,
        [string[]]$Rung,
        [switch]$Preview
    )
    $driverSource = if ($HostType -and $HostType -in $script:HostRefreshHostTypes) { 'host/' + ($HostType -replace '^host\.', '') + '/modules/Yuruna.Host.psm1' } else { $null }
    foreach ($row in $script:HostRefreshRequiredCommand) {
        if ($Stage -and $row.Stage -ne $Stage) { continue }
        if ($Preview -and $row.ExecutingOnly) { continue }
        $source = if ($row.Module -eq 'Yuruna.Host') { $driverSource } else { $null }
        [pscustomobject]@{ Name = [string]$row.Name; Module = [string]$row.Module; Stage = [string]$row.Stage; Rung = $null; Source = $source }
    }
    foreach ($name in @($Rung)) {
        if (-not $name -or -not $script:HostRefreshRungRequiredCommand.Contains($name)) { continue }
        foreach ($row in $script:HostRefreshRungRequiredCommand[$name]) {
            $isDriver = ($row.Source -eq 'driver')
            $module = if ($isDriver) { 'Yuruna.Host' } else { [System.IO.Path]::GetFileNameWithoutExtension([string]$row.Source) }
            $source = if ($isDriver) { $driverSource } else { [string]$row.Source }
            [pscustomobject]@{ Name = [string]$row.Name; Module = $module; Stage = 'Driver'; Rung = [string]$name; Source = $source }
        }
    }
}

function Assert-HostRefreshCommandSet {
    <#
    .SYNOPSIS
        Check that every command a stage needs resolves in the calling session.
    .DESCRIPTION
        A module missing from the set only warns when the set is imported;
        this is what makes the worker fail closed on it.
    .PARAMETER HostType
        Long host type.
    .PARAMETER Stage
        Startup or Driver.
    .PARAMETER Rung
        Rung names whose executor commands to include.
    .PARAMETER Preview
        Leave out commands only an executing run needs.
    .OUTPUTS
        [pscustomobject] @{ Complete; Missing [string[]]; MissingModule [string[]] }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$HostType,
        [Parameter(Mandatory)][ValidateSet('Startup', 'Driver')][string]$Stage,
        [string[]]$Rung,
        [switch]$Preview
    )
    $missing = [System.Collections.Generic.List[string]]::new()
    $missingModule = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @(Get-HostRefreshRequiredCommand -HostType $HostType -Stage $Stage -Rung $Rung -Preview:$Preview)) {
        if (-not (Get-HostRefreshCommand -Name $row.Name)) {
            if (-not $missing.Contains($row.Name)) { $missing.Add($row.Name); $missingModule.Add($row.Module) }
        }
    }
    return [pscustomobject]@{ Complete = ($missing.Count -eq 0); Missing = [string[]]$missing.ToArray(); MissingModule = [string[]]$missingModule.ToArray() }
}

function New-HostRefreshRelaunchParameter {
    <#
    .SYNOPSIS
        The bound parameters to forward through the libvirt group relaunch,
        plus the budget's expiry ticks.
    .DESCRIPTION
        The relaunched child recomputes its remaining time from the same
        boot-relative ticks, so the budget is never reset by a relaunch. Only
        values that survive the command-text round trip are forwarded:
        strings, numbers, booleans, enums, switches and string arrays. A
        dictionary or object value is refused before anything relaunches.
    .PARAMETER BoundParameters
        The entry script's $PSBoundParameters.
    .PARAMETER Budget
        The invocation budget.
    .OUTPUTS
        [hashtable]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory dictionary only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)]$Budget
    )
    $copy = @{}
    foreach ($key in @($BoundParameters.Keys)) {
        $name = [string]$key
        $value = $BoundParameters[$key]
        if ($null -eq $value -or $value -is [System.Management.Automation.SwitchParameter] -or $value -is [string] -or
            $value -is [char] -or $value -is [ValueType]) {
            $copy[$name] = $value
            continue
        }
        if ($value -is [System.Collections.IDictionary] -or $value -isnot [System.Collections.IEnumerable]) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_relaunch_parameter_unsupported' -Arguments @{ name = "$name"; type = "$($value.GetType().FullName)" })
        }
        $items = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $value) {
            if ($item -is [string] -or $item -is [ValueType]) { $items.Add([string]$item); continue }
            $typeName = if ($null -eq $item) { 'null' } else { $item.GetType().FullName }
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_relaunch_parameter_unsupported' -Arguments @{ name = "$name"; type = "$typeName" })
        }
        $copy[$name] = [string[]]$items.ToArray()
    }
    $copy['DeadlineTickMs'] = [long]$Budget.TotalExpiryTick
    $copy['PreAdmissionDeadlineTickMs'] = [long]$Budget.PreAdmissionExpiryTick
    return $copy
}

function New-HostRefreshWorkerArgumentList {
    <#
    .SYNOPSIS
        The argument vector that launches a worker for a queued request.
    .DESCRIPTION
        Script arguments only by default; -IncludeInterpreterArgument puts
        -NoLogo -NoProfile -NonInteractive -File <entry> in front for a
        caller that launches pwsh itself. Every parameter name is checked
        against the entry script's own metadata, so a vector built for an
        older or newer entry point is refused instead of silently absorbed.
        The vector never carries policy: tier, ceiling, force, hard stop and
        service selections come only from the private request.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER RequestId
        The queued request id.
    .PARAMETER Budget
        The invocation budget whose ticks the worker inherits.
    .PARAMETER IncludeInterpreterArgument
        Prepend the pwsh interpreter flags and -File <entry>.
    .PARAMETER ScriptArgumentOnly
        Script arguments only (the default), stated explicitly.
    .OUTPUTS
        [string] elements.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory argument list only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)]$Budget,
        [switch]$IncludeInterpreterArgument,
        [switch]$ScriptArgumentOnly
    )
    if ($IncludeInterpreterArgument -and $ScriptArgumentOnly) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_worker_argument_invalid' -Arguments @{ name = 'ScriptArgumentOnly' })
    }
    $entry = Join-Path $RepoRoot 'test/lab/Invoke-HostRefresh.ps1'
    $command = $null
    try { $command = Get-Command -CommandType ExternalScript -Name $entry -ErrorAction Stop } catch { $command = $null }
    if (-not $command) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_worker_argument_invalid' -Arguments @{ name = 'Invoke-HostRefresh.ps1' }) }
    foreach ($name in @('RequestId', 'DeadlineTickMs', 'PreAdmissionDeadlineTickMs')) {
        $resolved = $null
        try { $resolved = $command.ResolveParameter($name) } catch { $resolved = $null }
        if (-not $resolved -or $resolved.Name -cne $name) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_refresh_worker_argument_invalid' -Arguments @{ name = "$name" })
        }
    }
    if ($IncludeInterpreterArgument) { '-NoLogo'; '-NoProfile'; '-NonInteractive'; '-File'; [string]$entry }
    '-RequestId'
    $RequestId
    '-DeadlineTickMs'
    ([string][long]$Budget.TotalExpiryTick)
    '-PreAdmissionDeadlineTickMs'
    ([string][long]$Budget.PreAdmissionExpiryTick)
}

# --- REGION: Listener start
function Start-HostRefreshStatusService {
    <#
    .SYNOPSIS
        Bring the status listener back through its refresh-safe start mode.
    .DESCRIPTION
        Runs Start-StatusService.ps1 -RefreshSafe as a bounded child and reads
        its private result file; stdout is never parsed. That mode never
        kills a port owner, never restarts a live listener and never sweeps
        control state, so a repair cannot take away the operator's controls
        by starting the listener. Binding permissions remain a bounded
        refusal when the host cannot reserve the requested listener prefix.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER RuntimeDir
        The owning runtime directory.
    .PARAMETER Port
        The listener port; 0 means the listener is disabled.
    .PARAMETER ResultPath
        A path under the private work directory.
    .PARAMETER Deadline
        The convergence deadline.
    .OUTPUTS
        [pscustomobject] @{ Outcome; Reason; Pid; StartTimeUnixMs; ShaMatches }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][ValidateRange(0, 65535)][int]$Port,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)]$Deadline
    )
    $result = [ordered]@{ Outcome = 'unavailable'; Reason = $null; Pid = $null; StartTimeUnixMs = $null; ShaMatches = $null }
    if ($Port -eq 0) { $result.Outcome = 'disabled'; $result.Reason = 'disabled'; return [pscustomobject]$result }
    $script = Join-Path $RepoRoot 'test/service/Start-StatusService.ps1'
    $command = $null
    try { $command = Get-Command -CommandType ExternalScript -Name $script -ErrorAction Stop } catch { $command = $null }
    if (-not $command -or -not $command.Parameters.ContainsKey('RefreshSafe')) { $result.Reason = 'refresh-safe-mode-missing'; return [pscustomobject]$result }
    $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 120
    if ($null -eq $cap) { $result.Outcome = 'deadline-exhausted'; $result.Reason = 'deadline-exhausted'; return [pscustomobject]$result }
    if (-not $PSCmdlet.ShouldProcess("$Port", (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_listener'))) { $result.Reason = 'preview'; return [pscustomobject]$result }
    $pwsh = if (Get-HostRefreshCommand -Name 'Get-PwshExePath') { Get-PwshExePath } else { (Get-Process -Id $PID).Path }
    try { if ([System.IO.File]::Exists($ResultPath)) { [System.IO.File]::Delete($ResultPath) } } catch { $null = $_ }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script, '-RefreshSafe', '-Port', "$Port", '-ResultPath', $ResultPath,
        '-DeadlineTickMs', "$([long]$Deadline.ExpiryTick)")
    $native = Invoke-BoundedNativeCommand -FilePath $pwsh -ArgumentList $arguments -TimeoutSeconds $cap -Deadline $Deadline `
        -Environment @{ YURUNA_RUNTIME_DIR = $RuntimeDir; YURUNA_NONINTERACTIVE = '1' }
    $document = $null
    try {
        if ([System.IO.File]::Exists($ResultPath) -and ([System.IO.FileInfo]::new($ResultPath)).Length -le 65536) {
            $document = [System.IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
    } catch { $document = $null }
    $known = @('existing-ready', 'started', 'existing-unresponsive', 'unknown-owner', 'port-conflict', 'port-privilege-required',
        'start-timeout', 'admission-busy', 'launch-failed', 'generation-failed', 'invalid-invocation')
    if ($document -is [System.Collections.IDictionary] -and [string]$document['outcome'] -in $known) {
        $result.Outcome = [string]$document['outcome']
        $result.Reason = if ($document['reason']) { [string]$document['reason'] } else { [string]$document['outcome'] }
        $result.Pid = $document['pid']
        $result.StartTimeUnixMs = $document['startTimeUnixMs']
        $result.ShaMatches = $document['shaMatches']
        return [pscustomobject]$result
    }
    $result.Reason = if ($native.TimedOut -or $native.DeadlineExhausted) { 'start-timeout' } elseif (-not $native.Started) { 'launch-failed' } else { 'result-unreadable' }
    return [pscustomobject]$result
}

# --- REGION: Context and identity
function Resolve-HostRefreshCanonicalPath {
    <#
    .SYNOPSIS
        The canonical form of a path (links resolved), or the lexical full
        path when it cannot be resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-YurunaCanonicalPath -Path $Path
    if ($resolved.Resolved) { return [string]$resolved.Path }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-HostRefreshRunnerRecord {
    <#
    .SYNOPSIS
        Classify a runner pid record without launching anything: AliveOwned,
        DeadOrRecycled, Unknown or Missing.
    .DESCRIPTION
        Used only when the runner-protocol classifier is not loaded. A live
        pid is AliveOwned only when its start time matches the start sidecar;
        a live pid without a readable sidecar is Unknown, because a pid alone
        is never identity. A start time that differs is a recycled pid, so
        the recorded process is dead.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$PidFile, [string]$StartFile)
    $record = [ordered]@{ State = 'Missing'; Pid = $null; StartTimeUnixMs = $null; PidFile = $PidFile; StartFile = $StartFile }
    if (-not [System.IO.File]::Exists($PidFile)) { return [pscustomobject]$record }
    $processId = 0
    try { [void][int]::TryParse(([System.IO.File]::ReadAllText($PidFile)).Trim(), [ref]$processId) } catch { $processId = 0 }
    if ($processId -le 0) { $record.State = 'Unknown'; return [pscustomobject]$record }
    $record.Pid = $processId
    $recorded = $null
    if ($StartFile -and [System.IO.File]::Exists($StartFile)) {
        try { $recorded = [long][DateTimeOffset]::Parse(([System.IO.File]::ReadAllText($StartFile)).Trim(), [System.Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() } catch { $recorded = $null }
    }
    $record.StartTimeUnixMs = $recorded
    $live = Get-HostRefreshProcessIdentity -ProcessId $processId
    $exists = $true
    try { $null = [System.Diagnostics.Process]::GetProcessById($processId) } catch [System.ArgumentException] { $exists = $false } catch { $exists = $true }
    if (-not $exists) { $record.State = 'DeadOrRecycled'; return [pscustomobject]$record }
    if ($null -eq $live -or $null -eq $recorded) { $record.State = 'Unknown'; return [pscustomobject]$record }
    $record.State = if ([Math]::Abs([long]$live.startTimeUnixMs - $recorded) -le 2000) { 'AliveOwned' } else { 'DeadOrRecycled' }
    return [pscustomobject]$record
}

function Get-HostRefreshRunnerView {
    <#
    .SYNOPSIS
        The runner's outer, cycle, inner and listener records, and its launch
        record, from the runner-protocol snapshot when it is loaded.
    .PARAMETER RuntimeDir
        The owning runtime directory.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER Deadline
        Bounds the process-table read.
    .PARAMETER CallerOuter
        The resident outer that launched this worker, when known.
    .OUTPUTS
        [pscustomobject] @{ Source; Outer; Cycle; Inner; Server; LaunchRecord; Snapshot; CallerOuter }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Deadline,
        [System.Collections.IDictionary]$CallerOuter
    )
    $view = [ordered]@{ Source = 'fallback'; Outer = $null; Cycle = $null; Inner = $null; Server = $null; LaunchRecord = $null; Snapshot = $null; CallerOuter = $null }
    $asRecord = {
        param($Row, [string]$DefaultState)
        if ($null -eq $Row) { return [pscustomobject]@{ State = $DefaultState; Pid = $null; StartTimeUnixMs = $null; PidFile = $null; Fingerprint = $null } }
        $startTime = $null
        foreach ($name in @('RecordedStartTimeUnixMs', 'LiveStartTimeUnixMs', 'StartTimeUnixMs')) {
            if ($Row.PSObject.Properties[$name] -and $null -ne $Row.$name) { $startTime = [long]$Row.$name; break }
        }
        [pscustomobject]@{
            State = [string]$Row.State; Pid = $Row.Pid; StartTimeUnixMs = $startTime
            PidFile = if ($Row.PSObject.Properties['PidFile']) { $Row.PidFile } else { $null }
            Fingerprint = if ($Row.PSObject.Properties['Fingerprint']) { $Row.Fingerprint } else { $null }
        }
    }
    $snapshot = $null
    if (Get-HostRefreshCommand -Name 'Get-YurunaRunnerSnapshot') {
        try { $snapshot = Get-YurunaRunnerSnapshot -RuntimeDir $RuntimeDir -RepoRoot $RepoRoot -WorkerPid $PID -Deadline $Deadline } catch {
            Write-Verbose "Get-HostRefreshRunnerView: snapshot failed: $($_.Exception.Message)"
            $snapshot = $null
        }
    }
    if ($snapshot) {
        $view.Source = 'snapshot'
        $view.Snapshot = $snapshot
        $view.Outer = & $asRecord $snapshot.Outer 'Unknown'
        $view.Cycle = & $asRecord $snapshot.Cycle 'Missing'
        $view.Inner = & $asRecord $snapshot.Inner 'Missing'
        $view.Server = & $asRecord $snapshot.Server 'Missing'
        $view.LaunchRecord = $snapshot.LaunchRecord
    } else {
        $view.Outer = Get-HostRefreshRunnerRecord -PidFile (Join-Path $RuntimeDir 'runner.pid') -StartFile (Join-Path $RuntimeDir 'runner.start')
        $view.Cycle = [pscustomobject]@{ State = 'Missing'; Pid = $null; StartTimeUnixMs = $null; PidFile = $null; Fingerprint = $null }
        $view.Inner = Get-HostRefreshRunnerRecord -PidFile (Join-Path $RuntimeDir 'inner.pid') -StartFile (Join-Path $RuntimeDir 'inner.start')
        $view.Server = Get-HostRefreshRunnerRecord -PidFile (Join-Path $RuntimeDir 'server.pid')
        if (Get-HostRefreshCommand -Name 'Read-YurunaRunnerLaunchRecord') {
            try { $view.LaunchRecord = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir } catch { $view.LaunchRecord = $null }
        }
    }
    if (-not $view.LaunchRecord) { $view.LaunchRecord = [pscustomobject]@{ Found = $false; Valid = $false; Record = $null; Reason = 'reader-missing'; Path = $null } }
    if ($CallerOuter -and $CallerOuter['pid']) {
        $view.CallerOuter = [ordered]@{ pid = [int]$CallerOuter['pid']; startTimeUnixMs = $CallerOuter['startTimeUnixMs'] }
    } elseif ($view.Outer.State -eq 'AliveOwned' -and $view.Outer.Pid) {
        # An outer in this worker's own ancestor chain is the caller: never
        # reclaimed, never restarted.
        $walk = $PID
        for ($depth = 0; $depth -lt 32; $depth++) {
            $parent = $null
            try { $parent = ([System.Diagnostics.Process]::GetProcessById($walk)).Parent } catch { $parent = $null }
            if ($null -eq $parent -or $parent.Id -le 1) { break }
            if ($parent.Id -eq [int]$view.Outer.Pid) { $view.CallerOuter = [ordered]@{ pid = [int]$view.Outer.Pid; startTimeUnixMs = $view.Outer.StartTimeUnixMs }; break }
            $walk = $parent.Id
        }
    }
    return [pscustomobject]$view
}

function Get-HostRefreshIdentityRefusal {
    <#
    .SYNOPSIS
        Why this process may not act for the operator at all: root-refused,
        identity-unknown, or '' when it may.
    .DESCRIPTION
        One rule for the identity check and for every step that would create
        private state before it: a root process that kept the operator's HOME
        (sudo -E, or a sudoers policy that preserves HOME) would otherwise
        leave $HOME/.yuruna owned by root, and every later run by the operator
        would then fail the private root's owner check.
    .OUTPUTS
        [pscustomobject] @{ Refusal; Current }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $current = Get-YurunaCurrentOwnerId
    $refusal = ''
    if (-not $current.Resolved) { $refusal = 'identity-unknown' }
    elseif (-not $IsWindows -and $current.IsRoot) { $refusal = 'root-refused' }
    return [pscustomobject]@{ Refusal = $refusal; Current = $current }
}

function Resolve-HostRefreshContext {
    <#
    .SYNOPSIS
        Resolve and canonicalize the runtime directory, configuration,
        repository and private-state paths a repair runs against.
    .DESCRIPTION
        Runtime directory, first match: the request's recorded runtime (which
        must equal YURUNA_RUNTIME_DIR when that is set), YURUNA_RUNTIME_DIR,
        the runtime registered as this account's owner, <TestRoot>/status/
        runtime. It must already exist; it is never created.

        Configuration, first match: an explicit path (refused when a valid
        runner launch record names a different one), the recovery record's
        path on a retry, the runner's launch record, the source path recorded
        in the runtime's configuration snapshot envelopes (several distinct
        sources are narrowed to the live runner's own envelope and otherwise
        refused), <TestRoot>/test.config.yml. A recorded source that no
        longer exists is refused rather than guessed.

        A preview creates nothing and reports what it found in Observation.
        Nothing is created for an identity that will be refused (root, or
        one that cannot be established): the context is unresolved with
        Reason identity-refused, and the private root is only observed.
    .PARAMETER Paths
        The Initialize-YurunaEntryPoint bundle.
    .PARAMETER HostType
        Long host type.
    .PARAMETER ConfigPath
        An explicit configuration path.
    .PARAMETER RequestRuntimeDir
        The runtime directory a queued request recorded.
    .PARAMETER RecoveryConfigPath
        The configuration a retried request captured.
    .PARAMETER Preview
        Observe only.
    .PARAMETER NoConfig
        Resolve the runtime and the private state only. Recording a
        disposition touches only the journal and the runner gate, so a
        configuration that is ambiguous or gone must not block it.
    .PARAMETER Deadline
        The pre-admission deadline.
    .OUTPUTS
        [pscustomobject] context record; see Resolved and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [string]$HostType,
        [string]$ConfigPath,
        [string]$RequestRuntimeDir,
        [string]$RecoveryConfigPath,
        [switch]$Preview,
        [switch]$NoConfig,
        [Parameter(Mandatory)]$Deadline
    )
    $observation = [System.Collections.Generic.List[string]]::new()
    $context = [ordered]@{
        Resolved = $false; Reason = $null; HostType = $HostType; RepoRoot = $null; TestRoot = $null; ModulesDir = $null
        RuntimeDir = $null; RuntimeSource = $null; ConfigPath = $null; ConfigSource = $null; LaunchRecord = $null
        PrivateRoot = $null; PrivateRootReason = $null; JournalPath = $null; LifetimeLockPath = $null; AdmissionLockPath = $null
        PublicStatePath = $null; OwnerMatches = $true; HomeVerified = 'unverified'; LockQualified = $false; LockQualification = $null
        Observation = $null; ConfigCandidateCount = 0; RegisteredRuntimeDir = $null; RecordedConfigPath = $null
    }
    $finish = {
        param([string]$Reason)
        $context.Reason = $Reason
        $context.Resolved = ($Reason -eq 'ok')
        $context.Observation = [string[]]$observation.ToArray()
        [pscustomobject]$context
    }
    if (Test-YurunaDeadlineExpired -Deadline $Deadline) { return (& $finish 'deadline-exhausted') }
    $context.RepoRoot = Resolve-HostRefreshCanonicalPath -Path ([string]$Paths['RepoRoot'])
    $context.TestRoot = Resolve-HostRefreshCanonicalPath -Path ([string]$Paths['TestRoot'])
    $context.ModulesDir = Resolve-HostRefreshCanonicalPath -Path ([string]$Paths['ModulesDir'])

    $journalRead = Read-HostRefreshJournal
    $registered = $null
    if ($journalRead.Status -in @('ok', 'recovered-previous') -and $journalRead.Journal.owner -is [System.Collections.IDictionary]) {
        $registered = [string]$journalRead.Journal.owner['runtimeDir']
        $context.RegisteredRuntimeDir = $registered
    }
    $candidate = $null
    $envRuntime = [string]$env:YURUNA_RUNTIME_DIR
    if ($RequestRuntimeDir) {
        if ($envRuntime -and (Resolve-HostRefreshCanonicalPath -Path $envRuntime) -ne (Resolve-HostRefreshCanonicalPath -Path $RequestRuntimeDir)) {
            $context.RuntimeDir = $RequestRuntimeDir
            return (& $finish 'runtime-mismatch')
        }
        $candidate = $RequestRuntimeDir; $context.RuntimeSource = 'request'
    } elseif ($envRuntime) {
        $candidate = $envRuntime; $context.RuntimeSource = 'environment'
    } elseif ($registered) {
        $candidate = $registered; $context.RuntimeSource = 'owner-registration'
    } else {
        $candidate = Join-Path $context.TestRoot 'status/runtime'; $context.RuntimeSource = 'default'
    }
    $context.RuntimeDir = Resolve-HostRefreshCanonicalPath -Path $candidate
    if (-not [System.IO.Directory]::Exists($context.RuntimeDir)) { return (& $finish 'runtime-missing') }
    if ($registered -and (Resolve-HostRefreshCanonicalPath -Path $registered) -ne $context.RuntimeDir) {
        $context.OwnerMatches = $false
        return (& $finish 'runtime-owner-mismatch')
    }
    $context.PublicStatePath = Join-Path $context.RuntimeDir 'host-refresh.state.json'

    # Private root: created and secured when executing, observed in preview.
    $served = [System.Collections.Generic.List[string]]::new()
    $served.Add($context.RepoRoot); $served.Add($context.RuntimeDir)
    if ($env:YURUNA_LOG_DIR) { $served.Add([string]$env:YURUNA_LOG_DIR) }
    # A HOME that differs from the account's recorded home gives a second
    # lock namespace for the same hypervisor, so it disables every
    # disruptive rung; it does not stop a probe or a verified no-op.
    $homeCheck = Get-HostRefreshPrivateRoot -NoCreate -VerifyHome -ServedRoot $served.ToArray()
    $context.HomeVerified = [string]$homeCheck.HomeVerified
    if ($context.HomeVerified -ne 'verified') { $observation.Add("home-$($context.HomeVerified)") }
    $observeOnly = [bool]$Preview
    if (-not $observeOnly) {
        # The identity is settled before anything is created, never after.
        $identityRefusal = [string](Get-HostRefreshIdentityRefusal).Refusal
        if ($identityRefusal) {
            $observation.Add("identity-$identityRefusal")
            return (& $finish 'identity-refused')
        }
    }
    $root = Get-HostRefreshPrivateRoot -NoCreate:$observeOnly -ServedRoot $served.ToArray()
    $context.PrivateRootReason = [string]$root.Reason
    if ($root.Resolved) {
        $context.PrivateRoot = [string]$root.Path
        $context.JournalPath = Get-YurunaHostRefreshRequestPath -NoCreate:$observeOnly
        $context.LifetimeLockPath = Get-YurunaHostRefreshLockPath -NoCreate:$observeOnly
        $context.AdmissionLockPath = Get-YurunaHostRefreshAdmissionLockPath -NoCreate:$observeOnly
    } else {
        $observation.Add("private-root-$($root.Reason)")
        if (-not $observeOnly) { return (& $finish 'private-root-unavailable') }
    }
    $qualificationPath = if ($context.PrivateRoot) { $context.PrivateRoot } else { $HOME }
    try {
        $qualification = Get-YurunaSingleFlightLockQualification -Path $qualificationPath
        $context.LockQualified = [bool]$qualification.Qualified
        $context.LockQualification = [string]$qualification.Reason
    } catch { $context.LockQualification = 'unknown-filesystem' }
    if ($NoConfig) { return (& $finish 'ok') }

    # Configuration.
    $launch = $null
    if (Get-HostRefreshCommand -Name 'Read-YurunaRunnerLaunchRecord') {
        try { $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $context.RuntimeDir } catch { $launch = $null }
    }
    $context.LaunchRecord = $launch
    $launchConfig = $null
    if ($launch -and $launch.Valid -and $launch.Record) {
        $parameters = $launch.Record.parameters
        if ($parameters -is [System.Collections.IDictionary] -and $parameters['ConfigPath']) { $launchConfig = Resolve-HostRefreshCanonicalPath -Path ([string]$parameters['ConfigPath']) }
        elseif ($parameters -and $parameters.PSObject.Properties['ConfigPath'] -and $parameters.ConfigPath) { $launchConfig = Resolve-HostRefreshCanonicalPath -Path ([string]$parameters.ConfigPath) }
    }
    if ($ConfigPath) {
        $context.ConfigPath = Resolve-HostRefreshCanonicalPath -Path $ConfigPath
        $context.ConfigSource = 'explicit'
        if (-not [System.IO.File]::Exists($context.ConfigPath)) { return (& $finish 'config-missing') }
        if ($launchConfig -and $launchConfig -ne $context.ConfigPath) {
            $context.RecordedConfigPath = $launchConfig
            $observation.Add('launch-record-config-differs')
            return (& $finish 'config-conflict')
        }
        return (& $finish 'ok')
    }
    if ($RecoveryConfigPath) {
        $context.ConfigPath = Resolve-HostRefreshCanonicalPath -Path $RecoveryConfigPath
        $context.ConfigSource = 'recovery-record'
        if (-not [System.IO.File]::Exists($context.ConfigPath)) { return (& $finish 'config-missing') }
        return (& $finish 'ok')
    }
    if ($launchConfig) {
        $context.ConfigPath = $launchConfig
        $context.ConfigSource = 'launch-record'
        if (-not [System.IO.File]::Exists($context.ConfigPath)) { return (& $finish 'config-missing') }
        return (& $finish 'ok')
    }
    $envelopes = [System.Collections.Generic.List[object]]::new()
    try {
        $files = @([System.IO.Directory]::GetFiles($context.RuntimeDir, '.test.config.snapshot.*.json') | Sort-Object | Select-Object -First 64)
        foreach ($file in $files) {
            try {
                $info = [System.IO.FileInfo]::new($file)
                if ($info.LinkTarget -or $info.Length -gt 4194304) { continue }
                $envelope = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($envelope -isnot [System.Collections.IDictionary]) { continue }
                $source = [string]$envelope['sourcePath']
                $config = $envelope['config']
                if ($source -notmatch '(?i)\.ya?ml$') { continue }
                if (($source -replace '\\', '/') -match '(?i)/test/extension/') { continue }
                if ($config -isnot [System.Collections.IDictionary] -or -not $config.Contains('testCycle') -or -not $config.Contains('statusService')) { continue }
                $envelopes.Add([pscustomobject]@{ Source = (Resolve-HostRefreshCanonicalPath -Path $source); PublisherPid = $envelope['publisherPid'] })
            } catch {
                Write-Verbose "Resolve-HostRefreshContext: snapshot envelope '$file' skipped: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Verbose "Resolve-HostRefreshContext: snapshot envelopes unreadable: $($_.Exception.Message)"
    }
    $sources = @($envelopes | ForEach-Object { $_.Source } | Sort-Object -Unique)
    $context.ConfigCandidateCount = $sources.Count
    if ($sources.Count -gt 1) {
        $outer = Get-HostRefreshRunnerRecord -PidFile (Join-Path $context.RuntimeDir 'runner.pid') -StartFile (Join-Path $context.RuntimeDir 'runner.start')
        if ($outer.State -eq 'AliveOwned') {
            $sources = @($envelopes | Where-Object { "$($_.PublisherPid)" -eq "$($outer.Pid)" } | ForEach-Object { $_.Source } | Sort-Object -Unique)
        }
        if ($sources.Count -ne 1) {
            $context.ConfigSource = 'snapshot-envelope'
            return (& $finish 'config-ambiguous')
        }
    }
    if ($sources.Count -eq 1) {
        $context.ConfigPath = [string]$sources[0]
        $context.ConfigSource = 'snapshot-envelope'
        if (-not [System.IO.File]::Exists($context.ConfigPath)) { return (& $finish 'config-missing') }
        return (& $finish 'ok')
    }
    $context.ConfigPath = Resolve-HostRefreshCanonicalPath -Path (Join-Path $context.TestRoot 'test.config.yml')
    $context.ConfigSource = 'default'
    if (-not [System.IO.File]::Exists($context.ConfigPath)) { return (& $finish 'config-missing') }
    return (& $finish 'ok')
}

function Get-HostRefreshOperatorIdentity {
    <#
    .SYNOPSIS
        Who this worker runs as, and whether that identity may repair this
        runtime.
    .DESCRIPTION
        Refuses root on Unix, a runtime directory owned by another account,
        and any identity it cannot establish (an unknown identity is a
        refusal, not absence). On macOS the session kind decides whether rungs
        that need the desktop session may run; a remote or unknown session
        can still run passive steps.
    .PARAMETER HostType
        Long host type.
    .PARAMETER RuntimeDir
        The owning runtime directory.
    .PARAMETER Deadline
        Bounds the session probe.
    .OUTPUTS
        [pscustomobject] @{ Allowed; Reason; OwnerId; UserName; IsRoot; Elevated;
        SessionKind; GuiAllowed; RuntimeOwnerMatches }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)]$Deadline
    )
    $identity = [ordered]@{
        Allowed = $false; Reason = $null; OwnerId = $null; UserName = $null; IsRoot = $false; Elevated = $false
        SessionKind = 'NotApplicable'; GuiAllowed = $false; RuntimeOwnerMatches = $false
    }
    $who = Get-HostRefreshIdentityRefusal
    $current = $who.Current
    if ($who.Refusal -eq 'identity-unknown') { $identity.Reason = 'identity-unknown'; return [pscustomobject]$identity }
    $identity.OwnerId = [string]$current.OwnerId
    $identity.UserName = [string]$current.UserName
    $identity.IsRoot = [bool]$current.IsRoot
    $identity.Elevated = [bool]$current.Elevated
    if ($who.Refusal -eq 'root-refused') { $identity.Reason = 'root-refused'; return [pscustomobject]$identity }
    if ($RuntimeDir -and [System.IO.Directory]::Exists($RuntimeDir)) {
        $owner = Get-YurunaPathOwnerId -Path $RuntimeDir
        if (-not $owner.Resolved) { $identity.Reason = 'identity-unknown'; return [pscustomobject]$identity }
        $ownerMatches = ([string]$owner.OwnerId -ceq $identity.OwnerId)
        # An elevated Windows token creates directories owned by the
        # Administrators group rather than by the user.
        if (-not $ownerMatches -and $IsWindows -and $identity.Elevated -and [string]$owner.OwnerId -eq 'S-1-5-32-544') { $ownerMatches = $true }
        $identity.RuntimeOwnerMatches = $ownerMatches
        if (-not $ownerMatches) { $identity.Reason = 'runtime-owner-mismatch'; return [pscustomobject]$identity }
    }
    if ($HostType -eq 'host.macos.utm') {
        $kind = 'Unknown'
        if (Get-HostRefreshCommand -Name 'Get-MacSessionKind') {
            $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 5
            if ($null -ne $seconds) {
                try { $kind = [string](Get-MacSessionKind -TimeoutSeconds $seconds) } catch { $kind = 'Unknown' }
            }
        }
        $identity.SessionKind = if ($kind -in @('Aqua', 'Remote', 'Unknown')) { $kind } else { 'Unknown' }
        $identity.GuiAllowed = ($identity.SessionKind -eq 'Aqua')
    }
    $identity.Allowed = $true
    $identity.Reason = 'ok'
    return [pscustomobject]$identity
}

# --- REGION: Worker: probe, capture and rungs
function New-HostRefreshSyntheticProbe {
    <#
    .SYNOPSIS
        An Undetermined probe record for a probe that could not run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$HostType, [Parameter(Mandatory)][string]$Reason)
    return [pscustomobject]@{
        PSTypeName = 'Yuruna.VirtualizationProbe'; schemaVersion = 1; hostType = $HostType; state = 'Undetermined'; reason = $Reason
        started = $false; timedOut = $false; deadlineExhausted = ($Reason -eq 'deadline-exhausted'); corroborated = $false
        observedUtc = (Get-HostRefreshUtcText); observedTick = [Environment]::TickCount64; elapsedMs = [long]0
        evidence = [pscustomobject]@{}; diagnostic = ''
    }
}

function Invoke-HostRefreshProbeRung {
    <#
    .SYNOPSIS
        Rung 0: one bounded, read-only hypervisor probe.
    .DESCRIPTION
        On macOS the probe may be asked to corroborate a timeout (a second
        probe after the consent-dialog window plus a recorded Automation
        grant for this sender) and is given the recorded subjects; a
        responsive probe records its subject. A missing probe command or a
        probe that throws is Undetermined, which authorizes nothing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Deadline,
        [switch]$Corroborate
    )
    $hostType = [string]$State.HostType
    if (-not (Get-HostRefreshCommand -Name 'Test-VirtualizationResponsive')) { return (New-HostRefreshSyntheticProbe -HostType $hostType -Reason 'provider-error') }
    if ((Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) { return (New-HostRefreshSyntheticProbe -HostType $hostType -Reason 'deadline-exhausted') }
    $arguments = @{ Deadline = $Deadline }
    if ($hostType -eq 'host.macos.utm') {
        if ($Corroborate -and -not $State.Preview -and (Test-HostRefreshCommandParameter -Name 'Test-VirtualizationResponsive' -Parameter 'Corroborate')) { $arguments.Corroborate = $true }
        if (Test-HostRefreshCommandParameter -Name 'Test-VirtualizationResponsive' -Parameter 'RecordedAutomationSubject') {
            $arguments.RecordedAutomationSubject = [string[]]@(Get-YurunaHostRefreshAutomationSubject)
        }
        if (Test-HostRefreshCommandParameter -Name 'Test-VirtualizationResponsive' -Parameter 'IncludeInventory') { $arguments.IncludeInventory = $true }
    }
    $probe = $null
    try { $probe = Test-VirtualizationResponsive @arguments } catch {
        Write-Verbose "Invoke-HostRefreshProbeRung: probe threw: $($_.Exception.Message)"
        $probe = $null
    }
    if ($null -eq $probe -or -not $probe.PSObject.Properties['state']) { return (New-HostRefreshSyntheticProbe -HostType $hostType -Reason 'provider-error') }
    if (-not $State.Preview -and $hostType -eq 'host.macos.utm' -and [string]$probe.state -eq 'Responsive' -and
        $probe.PSObject.Properties['automationSubject'] -and $probe.automationSubject) {
        try { $null = Add-YurunaHostRefreshAutomationSubject -Subject ([string]$probe.automationSubject) -Confirm:$false } catch { $null = $_ }
    }
    return $probe
}

function Invoke-HostRefreshReclaimRung {
    <#
    .SYNOPSIS
        Rung 1: stop proven-owned runner work and clean its dead records.
    .DESCRIPTION
        Builds the reclaim plan from one process-table snapshot, waits a
        short settle and requires the re-snapshot to agree (a new child or a
        changed root means the runner is not quiescent, and nothing is
        signaled). Only AliveOwned roots are signaled, inner before cycle
        before outer, each revalidated right before its signal; a caller
        outer is protected. An inner confirmed gone has its break marker
        archived; records of positively dead generations are removed by
        fingerprint. The restart happens only in convergence.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Deadline
    )
    $outcome = [ordered]@{ Outcome = 'skipped'; Reason = $null; Mutated = $false }
    $context = $State.Context
    $planArguments = @{ WorkerPid = $PID }
    if ($State.RunnerView.CallerOuter) {
        $planArguments.PreserveOuter = $true
        if (Test-HostRefreshCommandParameter -Name 'New-YurunaRunnerReclaimPlan' -Parameter 'ProtectedPid') { $planArguments.ProtectedPid = [int[]]@([int]$State.RunnerView.CallerOuter['pid']) }
    }
    $before = Get-YurunaRunnerSnapshot -RuntimeDir $context.RuntimeDir -RepoRoot $context.RepoRoot -WorkerPid $PID -Deadline $Deadline
    $plan = New-YurunaRunnerReclaimPlan -Snapshot $before @planArguments
    if (@($plan.Refusals).Count -gt 0) { $outcome.Reason = 'runner-liveness-unknown'; return [pscustomobject]$outcome }
    $null = Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 1000
    $after = Get-YurunaRunnerSnapshot -RuntimeDir $context.RuntimeDir -RepoRoot $context.RepoRoot -WorkerPid $PID -Deadline $Deadline
    $settled = New-YurunaRunnerReclaimPlan -Snapshot $after @planArguments
    $comparison = Compare-YurunaRunnerReclaimPlan -Before $plan -After $settled
    if (-not $comparison.Quiescent) { $outcome.Reason = 'runner-not-quiescent'; return [pscustomobject]$outcome }
    if (@($settled.Refusals).Count -gt 0) { $outcome.Reason = 'runner-liveness-unknown'; return [pscustomobject]$outcome }
    $roots = @($settled.Roots)
    $reclaimed = @{ outer = $null; cycle = $null; inner = $null }
    if ($roots.Count -gt 0) {
        $stop = Stop-YurunaRunnerProcessTarget -Plan $settled -Deadline $Deadline -Confirm:$false
        $signaled = @($stop.Targets | Where-Object { [string]$_.Action -notin @('already-exited', 'recycled-skipped', 'skipped-unverifiable', 'skipped-deadline', 'whatif') })
        if ($signaled.Count -gt 0) { $outcome.Mutated = $true }
        foreach ($root in $roots) {
            $role = ([string]$root.Role).ToLowerInvariant()
            if ($reclaimed.ContainsKey($role)) { $reclaimed[$role] = [ordered]@{ pid = $root.Pid; startTimeUnixMs = $root.StartTimeUnixMs } }
        }
        $State.Reclaimed = $reclaimed
        if (-not $stop.Converged) {
            $outcome.Outcome = 'failed'
            $outcome.Reason = if ($stop.DeadlineExhausted) { 'deadline-exhausted' } else { 'runner-stop-unconverged' }
            return [pscustomobject]$outcome
        }
    }
    $final = Get-YurunaRunnerSnapshot -RuntimeDir $context.RuntimeDir -RepoRoot $context.RepoRoot -WorkerPid $PID -Deadline $Deadline
    $innerGone = ([string]$final.Inner.State -in @('DeadOrRecycled', 'Missing'))
    if ($innerGone -and [System.IO.File]::Exists((Join-Path $context.RuntimeDir 'break-active.json')) -and (Get-HostRefreshCommand -Name 'Resolve-StaleBreakActive')) {
        $archived = Resolve-StaleBreakActive -RuntimeDir $context.RuntimeDir -Confirm:$false
        if ($archived) { $outcome.Mutated = $true; Add-HostRefreshReasonCode -State $State -Code 'break-marker-archived' }
    }
    $records = @(
        @{ Record = $final.Inner; StartFile = Join-Path $context.RuntimeDir 'inner.start' }
    )
    if (-not $State.RunnerView.CallerOuter) { $records += @{ Record = $final.Outer; StartFile = Join-Path $context.RuntimeDir 'runner.start' } }
    foreach ($entry in $records) {
        $record = $entry.Record
        if ($null -eq $record -or [string]$record.State -ne 'DeadOrRecycled' -or -not $record.PSObject.Properties['Fingerprint'] -or -not $record.Fingerprint) { continue }
        $removal = Remove-YurunaRunnerRecordGeneration -PidFile ([string]$record.PidFile) -StartFile ([string]$entry.StartFile) -Fingerprint ([string]$record.Fingerprint) -Confirm:$false
        if ($removal.Removed) { $outcome.Mutated = $true }
    }
    $outcome.Outcome = if ($outcome.Mutated) { 'succeeded' } else { 'skipped' }
    $outcome.Reason = if ($outcome.Mutated) { 'reclaimed' } else { 'nothing-to-reclaim' }
    return [pscustomobject]$outcome
}

function Invoke-HostRefreshStartIfStoppedRung {
    <#
    .SYNOPSIS
        Rung 2: start the hypervisor service when it is positively stopped.
    .DESCRIPTION
        The driver re-detects the service layout and unit states itself right
        before acting and starts only positively stopped units; a refusal
        changes nothing and is a skip. A start whose outcome is unknown may
        have acted and counts as a mutation. A refused elevation's exact
        command is printed on the console only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Deadline
    )
    $outcome = [ordered]@{ Outcome = 'skipped'; Reason = $null; Mutated = $false }
    $dependents = [string[]]@($State.RecoverySetRows | ForEach-Object { [string]$_.VMName } | Where-Object { $_ })
    $result = Start-VirtualizationServiceIfStopped -Deadline $Deadline -DependentVMName $dependents -Confirm:$false
    $reason = [string]$result.reason
    foreach ($action in @($result.actions)) {
        if ([string]$action.reason -eq 'elevation-refused' -and $action.command) {
            $State.OperatorAction = 'elevate'
            $State.OperatorActionRung = 'start-if-stopped'
            Write-HostRefreshLog -Key 'runner.host_refresh_manual_command' -Arguments @{ command = ((@($action.command) | ForEach-Object { [string]$_ }) -join ' ') } -ConsoleOnly -Level Warning
        }
    }
    $acted = @($result.actions | Where-Object { [string]$_.result -in @('started', 'unknown') }).Count -gt 0
    switch ([string]$result.outcome) {
        'started' { $outcome.Outcome = 'succeeded'; $outcome.Mutated = $true }
        'already-running' { $outcome.Outcome = 'succeeded' }
        'refused' { $outcome.Outcome = 'skipped' }
        'unavailable' { $outcome.Outcome = 'skipped' }
        'preview' { $outcome.Outcome = 'skipped' }
        'failed' { $outcome.Outcome = 'failed'; $outcome.Mutated = $acted }
        default { $outcome.Outcome = 'failed'; $outcome.Mutated = $true; if (-not $reason) { $reason = 'postcondition-unknown' } }
    }
    $outcome.Reason = if ($reason) { $reason } else { [string]$result.outcome }
    return [pscustomobject]$outcome
}

function Invoke-HostRefreshRestartIfHungRung {
    <#
    .SYNOPSIS
        Rung 3 on macOS: quit and relaunch a hung UTM.
    .DESCRIPTION
        Warns that restarting UTM can suspend running guests first. The
        driver refuses unless the evidence is a corroborated Unresponsive
        timeout observed within the last two minutes. A hard stop of UTM and
        its helpers is only ever passed for a local request that asked for it
        explicitly. Any outcome other than a refusal means the quit request
        was sent. Other platforms have no executor recipe.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Deadline
    )
    $outcome = [ordered]@{ Outcome = 'skipped'; Reason = $null; Mutated = $false }
    if ($State.HostType -ne 'host.macos.utm') { $outcome.Reason = 'unsupported-on-platform'; return [pscustomobject]$outcome }
    Write-HostRefreshLog -Key 'runner.host_refresh_disruption_warning' -Level Warning
    $hardStop = [bool]$State.RequestPolicy['allowHardStop'] -and ($State.Channel -eq 'local')
    $restart = Restart-UtmApplication -Evidence $State.LastProbe -Deadline $Deadline -AllowHardStop:$hardStop -Confirm:$false
    switch ([string]$restart.Outcome) {
        'restarted' { $outcome.Outcome = 'succeeded'; $outcome.Mutated = $true }
        'refused' { $outcome.Outcome = 'skipped' }
        'preview' { $outcome.Outcome = 'skipped' }
        default { $outcome.Outcome = 'failed'; $outcome.Mutated = $true }
    }
    $outcome.Reason = if ($restart.Reason) { [string]$restart.Reason } else { [string]$restart.Outcome }
    if ($restart.HardStopUsed) { Add-HostRefreshReasonCode -State $State -Code 'hard-stop-used' }
    return [pscustomobject]$outcome
}

function Get-HostRefreshControlSnapshot {
    <#
    .SYNOPSIS
        Presence and content hash of every operator control in the runtime
        directory.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    foreach ($name in $script:HostRefreshControlName) {
        $path = Join-Path $RuntimeDir $name
        $present = [System.IO.File]::Exists($path)
        $hash = $null
        if ($present) {
            try {
                $info = [System.IO.FileInfo]::new($path)
                if ($info.Length -le 1048576) { $hash = ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($path)))).ToLowerInvariant() }
            } catch { $hash = $null }
        }
        [ordered]@{ name = $name; present = $present; sha256 = $hash }
    }
}

function ConvertTo-HostRefreshServiceKey {
    <#
    .SYNOPSIS
        A service key in the obligation-id shape, or '' when it has none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Key)
    $normalized = (([string]$Key).ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if ($normalized -cmatch '^[a-z0-9][a-z0-9-]{0,62}$') { return $normalized }
    return ''
}

function Invoke-HostRefreshCapture {
    <#
    .SYNOPSIS
        Capture what this repair must restore and persist it before the first
        disruption.
    .DESCRIPTION
        Controls, the runner's records and launch record, the listener
        setting, the managed services under the Repair policy (captured
        identities, restore and leave-stopped sets) and the forwarders. The
        recovery record is a critical write; when it cannot be saved nothing
        is mutated. Service evidence that cannot be gathered is recorded as
        such, and every guest-disrupting rung then refuses.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Deadline)
    $context = $State.Context
    $view = $State.RunnerView
    $config = $null
    if (Get-HostRefreshCommand -Name 'Read-TestConfig') {
        try { $config = Read-TestConfig -Path $context.ConfigPath } catch { $config = $null }
    }
    $listenerEnabled = $false
    $listenerPort = 8080
    if ($config -is [System.Collections.IDictionary] -and $config['statusService'] -is [System.Collections.IDictionary]) {
        $listenerEnabled = [bool]$config['statusService']['enabled']
        if ($config['statusService']['port']) { $listenerPort = [int]$config['statusService']['port'] }
    }
    $noStatusService = $false
    $cleanExit = $null
    $launch = $view.LaunchRecord
    if ($launch -and $launch.Valid -and $launch.Record) {
        $record = $launch.Record
        $parameters = if ($record -is [System.Collections.IDictionary]) { $record['parameters'] } else { $record.parameters }
        if ($parameters -is [System.Collections.IDictionary]) { $noStatusService = [bool]$parameters['NoStatusService'] }
        elseif ($parameters) { $noStatusService = [bool]$parameters.NoStatusService }
        $cleanExit = if ($record -is [System.Collections.IDictionary]) { $record['cleanExit'] } else { $record.cleanExit }
    }
    $State.Listener = [ordered]@{ enabled = ($listenerEnabled -and -not $noStatusService); port = $listenerPort; state = [string]$view.Server.State }
    $State.CleanExit = $cleanExit
    $controls = @(Get-HostRefreshControlSnapshot -RuntimeDir $context.RuntimeDir)
    $State.ControlsPresent = @($controls | Where-Object { $_.present }).Count -gt 0

    # Service evidence under the Repair policy.
    $services = [object[]]@()
    $recoveryKeys = [string[]]@(); $leaveKeys = [string[]]@(); $unresolvedKeys = [string[]]@()
    $State.ServiceVerdict = $null
    $State.RecoverySetRows = [object[]]@()
    $State.ServiceEvidenceReason = 'service-evidence-unavailable'
    if ((Get-HostRefreshCommand -Name 'Test-YurunaServiceVmRunning')) {
        try {
            $identityRows = $null
            $identitySet = $null
            if (Get-HostRefreshCommand -Name 'Get-YurunaServiceVmIdentitySet') {
                $identityArguments = @{ RuntimeDir = $context.RuntimeDir; HostType = $State.HostType; Deadline = $Deadline }
                if (Test-HostRefreshCommandParameter -Name 'Get-YurunaServiceVmIdentitySet' -Parameter 'ResolveProvider') { $identityArguments.ResolveProvider = $true }
                $identitySet = Get-YurunaServiceVmIdentitySet @identityArguments
                $identityRows = [object[]]@($identitySet.Rows)
            }
            $verdictArguments = @{ UnknownMeans = 'Repair'; HypervisorProbe = $State.LastProbe; HostType = $State.HostType; RuntimeDir = $context.RuntimeDir; Deadline = $Deadline }
            if ($null -ne $identityRows) { $verdictArguments.Identity = $identityRows }
            # Rows alone lose the set-level disagreement between the manifest
            # roster and the hard-coded service names; without it the Repair
            # policy cannot refuse on an unexplained roster difference.
            if ($identitySet -and (Test-HostRefreshCommandParameter -Name 'Test-YurunaServiceVmRunning' -Parameter 'RosterDisagreement')) {
                $verdictArguments.RosterDisagreement = [string[]]@($identitySet.RosterDisagreement)
            }
            $policy = $State.RequestPolicy
            if ($State.Channel -eq 'local') {
                $verdictArguments.AllowOperatorSelection = $true
                if (@($policy['restoreServiceVmName']).Count -gt 0) { $verdictArguments.RestoreServiceVmName = [string[]]@($policy['restoreServiceVmName']) }
                if (@($policy['leaveStoppedServiceVmName']).Count -gt 0) { $verdictArguments.LeaveStoppedServiceVmName = [string[]]@($policy['leaveStoppedServiceVmName']) }
            }
            $verdict = Test-YurunaServiceVmRunning @verdictArguments
            $State.ServiceVerdict = $verdict
            $services = [object[]]@($verdict.Services)
            $State.RecoverySetRows = [object[]]@($verdict.RecoverySet)
            $recoveryKeys = [string[]]@($verdict.RecoverySet | ForEach-Object { [string]$_.Key })
            $leaveKeys = [string[]]@($verdict.LeaveStoppedSet | ForEach-Object { [string]$_.Key })
            $unresolvedKeys = [string[]]@($verdict.UnresolvedSet | ForEach-Object { [string]$_.Key })
            $State.ServiceEvidenceReason = if ($verdict.Satisfied) { 'satisfied' } elseif ($verdict.Refusal) { [string]$verdict.Refusal } else { 'service-evidence-incomplete' }
        } catch {
            Write-Verbose "Invoke-HostRefreshCapture: service evidence failed: $($_.Exception.Message)"
            $State.ServiceEvidenceReason = 'service-evidence-unavailable'
        }
    }
    $forwarders = [object[]]@()
    $forwardersCaptured = $false
    if (Get-HostRefreshCommand -Name 'Get-PortMapTarget') {
        try { $forwarders = [object[]]@(Get-PortMapTarget -Deadline $Deadline); $forwardersCaptured = $true } catch { $forwardersCaptured = $false }
    }
    $configHash = $null
    try { $configHash = ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($context.ConfigPath)))).ToLowerInvariant() } catch { $configHash = $null }
    $asIdentity = { param($Record) if ($null -eq $Record) { $null } else { [ordered]@{ state = [string]$Record.State; pid = $Record.Pid; startTimeUnixMs = $Record.StartTimeUnixMs } } }
    $recovery = [ordered]@{
        hostType = $State.HostType; repoRoot = $context.RepoRoot; runtimeDir = $context.RuntimeDir; configPath = $context.ConfigPath; configSha256 = $configHash
        probe = [ordered]@{ state = [string]$State.LastProbe.state; reason = [string]$State.LastProbe.reason; observedUtc = [string]$State.LastProbe.observedUtc }
        controls = [object[]]$controls
        runner = [ordered]@{
            outer = (& $asIdentity $view.Outer); cycle = (& $asIdentity $view.Cycle); inner = (& $asIdentity $view.Inner); server = (& $asIdentity $view.Server)
            callerOuter = $view.CallerOuter; launchRecordFound = [bool]$launch.Found; launchRecordValid = [bool]$launch.Valid
            cleanExit = $cleanExit; noStatusService = $noStatusService
        }
        listener = $State.Listener
        services = $services; recoverySet = $recoveryKeys; leaveStoppedSet = $leaveKeys; unresolvedSet = $unresolvedKeys
        serviceEvidence = $State.ServiceEvidenceReason
        forwarders = $forwarders; forwardersCaptured = $forwardersCaptured
        servicesSummary = [ordered]@{ count = $services.Count; restoreRequired = $recoveryKeys.Count; unresolved = $unresolvedKeys.Count; evidence = $State.ServiceEvidenceReason }
    }
    $obligations = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $State.RecoverySetRows) {
        $key = ConvertTo-HostRefreshServiceKey -Key ([string]$row.Key)
        if (-not $key) { continue }
        $obligations.Add([ordered]@{ id = "service:$key"; kind = 'service'; target = $key; required = $true })
        $advertised = $null
        if ($row.PSObject.Properties['Identity'] -and $row.Identity) {
            $identityRow = $row.Identity
            $advertised = if ($identityRow -is [System.Collections.IDictionary]) { $identityRow['Advertised'] } elseif ($identityRow.PSObject.Properties['Advertised']) { $identityRow.Advertised } else { $null }
        }
        $url = if ($advertised -is [System.Collections.IDictionary]) { [string]$advertised['Url'] } elseif ($advertised) { [string]$advertised.Url } else { '' }
        if ($url) { $obligations.Add([ordered]@{ id = "endpoint:$key"; kind = 'endpoint'; target = $key; required = $true }) }
    }
    if (-not $view.CallerOuter -and ([string]$view.Outer.State -in @('AliveOwned', 'DeadOrRecycled'))) { $obligations.Add([ordered]@{ id = 'runner'; kind = 'runner'; target = 'runner'; required = $true }) }
    if ($State.Listener.enabled) { $obligations.Add([ordered]@{ id = 'listener'; kind = 'listener'; target = 'listener'; required = $true }) }
    if ($State.ControlsPresent) { $obligations.Add([ordered]@{ id = 'controls'; kind = 'controls'; target = 'controls'; required = $true }) }
    $save = Save-HostRefreshRecoveryRecord -RequestId $State.RequestId -Generation $State.Generation -Recovery $recovery -Obligation ([object[]]$obligations.ToArray()) -Confirm:$false
    $State.RecoverySaved = [bool]$save.Saved
    if (-not $save.Saved) { Add-HostRefreshReasonCode -State $State -Code 'recovery-record-unwritable'; return $false }
    if (-not $save.FirstCapture) {
        # A retry keeps the original recovery set and obligations.
        $stored = Read-YurunaHostRefreshRequest -RequestId $State.RequestId
        if ($stored -and $stored['recovery'] -is [System.Collections.IDictionary]) {
            $storedKeys = [string[]]@($stored['recovery']['recoverySet'])
            $originalRows = @($stored['recovery']['services'] | Where-Object { $_ -and ([string]$_['Key']) -in $storedKeys })
            $State.RecoverySetRows = [object[]]@($originalRows | ForEach-Object { [pscustomobject]$_ })
            if ($stored['recovery']['listener'] -is [System.Collections.IDictionary]) { $State.Listener = $stored['recovery']['listener'] }
        }
    }
    return $true
}

function Get-HostRefreshRungObligation {
    <#
    .SYNOPSIS
        The obligations a rung may disrupt, armed right before it acts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Rung)
    switch ($Rung) {
        'reclaim' {
            if (-not $State.RunnerView.CallerOuter -and [string]$State.RunnerView.Outer.State -in @('AliveOwned', 'DeadOrRecycled')) { 'runner' }
            if ($State.ControlsPresent) { 'controls' }
        }
        'restart-if-hung' {
            foreach ($row in $State.RecoverySetRows) {
                $key = ConvertTo-HostRefreshServiceKey -Key ([string]$row.Key)
                if (-not $key) { continue }
                "service:$key"
                $advertised = $null
                if ($row.PSObject.Properties['Identity'] -and $row.Identity) {
                    $advertised = if ($row.Identity -is [System.Collections.IDictionary]) { $row.Identity['Advertised'] } elseif ($row.Identity.PSObject.Properties['Advertised']) { $row.Identity.Advertised } else { $null }
                }
                $url = if ($advertised -is [System.Collections.IDictionary]) { [string]$advertised['Url'] } elseif ($advertised) { [string]$advertised.Url } else { '' }
                if ($url) { "endpoint:$key" }
            }
        }
    }
}

function Set-HostRefreshWorkerObligation {
    <#
    .SYNOPSIS
        Arm or discharge obligations in the journal and mirror them locally.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ObligationId,
        [Parameter(Mandatory)][ValidateSet('armed', 'discharged')][string]$Status,
        [string]$Evidence
    )
    $ids = [string[]]@($ObligationId | Where-Object { $_ })
    if ($ids.Count -eq 0) { return $true }
    if (-not $PSCmdlet.ShouldProcess($State.RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$($State.RequestId)" }))) { return $false }
    $arguments = @{ RequestId = $State.RequestId; Generation = $State.Generation; ObligationId = $ids; State = $Status; Confirm = $false }
    if ($Evidence) { $arguments.Evidence = $Evidence }
    $save = Set-HostRefreshObligationState @arguments
    if (-not $save.Saved) { return $false }
    foreach ($id in $ids) { $State.Obligations[$id] = $Status }
    return $true
}

function Close-HostRefreshGate {
    <#
    .SYNOPSIS
        Close the runner refresh gate before the attempt's first mutation.
    .DESCRIPTION
        While the gate is closed no runner spawns or pulls. A gate held by
        another request, or one that cannot be read or written, refuses the
        mutation (fail closed).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.GateClosed) { return $true }
    if (-not (Get-HostRefreshCommand -Name 'Set-YurunaRefreshGate') -or -not (Get-HostRefreshCommand -Name 'Get-YurunaRefreshGateState')) { return $false }
    if (-not $PSCmdlet.ShouldProcess($State.RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$($State.RequestId)" }))) { return $false }
    $gate = $null
    try { $gate = Get-YurunaRefreshGateState -RuntimeDir $State.Context.RuntimeDir } catch { $gate = $null }
    if ($null -eq $gate -or [string]$gate.State -eq 'unknown') { return $false }
    # The write is a compare-and-set on the generation just read; a released
    # gate still carries its last generation.
    $arguments = @{
        State = 'closed'; RequestId = $State.RequestId; Attempt = [int]$State.Attempt; RuntimeDir = $State.Context.RuntimeDir
        ExpectedGeneration = [string]$gate.Generation; Confirm = $false
    }
    if ([string]$gate.State -ne 'open' -and [string]$gate.RequestId -cne $State.RequestId) { return $false }
    $set = $null
    try { $set = Set-YurunaRefreshGate @arguments } catch { $set = $null }
    if ($null -eq $set -or -not $set.Written) { return $false }
    $State.GateClosed = $true
    $State.GateGeneration = [string]$set.Generation
    return $true
}

function Test-HostRefreshRungApplicable {
    <#
    .SYNOPSIS
        Whether a rung applies to the current evidence, and why not.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Rung, [switch]$Prediction)
    $no = { param([string]$Reason) [pscustomobject]@{ Apply = $false; Reason = $Reason } }
    $probe = $State.LastProbe
    $probeState = [string]$probe.state
    $probeReason = [string]$probe.reason
    if (-not $Prediction) {
        if (-not $State.DisruptionAllowed) { return (& $no $State.DisruptionRefusal) }
        $closure = Assert-HostRefreshCommandSet -HostType $State.HostType -Stage Driver -Rung @($Rung.Name)
        if (-not $closure.Complete) { return (& $no 'command-missing') }
    }
    if ($probeState -eq 'Undetermined' -and $probeReason -in $script:HostRefreshOperatorFixableReason) { return (& $no "probe-$probeReason") }
    if ($Rung.RequiresSession -and -not $State.Identity.GuiAllowed) { return (& $no 'no-session') }
    switch ([string]$Rung.Name) {
        'reclaim' {
            $outer = [string]$State.RunnerView.Outer.State
            if ($outer -eq 'Unknown') { return (& $no 'runner-liveness-unknown') }
            if ($outer -eq 'AliveOwned' -and $State.RequestPolicy['force'] -and -not $State.RunnerView.CallerOuter) { return [pscustomobject]@{ Apply = $true; Reason = 'force' } }
            if ($outer -eq 'DeadOrRecycled' -or [string]$State.RunnerView.Inner.State -eq 'DeadOrRecycled') { return [pscustomobject]@{ Apply = $true; Reason = 'dead-runner-records' } }
            $runnerAlive = ($outer -eq 'AliveOwned') -or ([string]$State.RunnerView.Inner.State -eq 'AliveOwned')
            if ($runnerAlive -and $probeState -ne 'Responsive') {
                foreach ($later in @($State.Rungs | Where-Object { $_.Order -gt 1 -and $_.Order -le $State.Ceiling.CeilingOrder -and $_.Available -and $_.Destructive })) {
                    $check = Test-HostRefreshRungApplicable -State $State -Rung $later -Prediction
                    if ($check.Apply) { return [pscustomobject]@{ Apply = $true; Reason = 'quiesce-before-restart' } }
                }
            }
            return (& $no 'runner-not-in-the-way')
        }
        'start-if-stopped' {
            if ($probeState -ne 'Unresponsive' -or $probeReason -ne 'app-stopped') { return (& $no 'not-app-stopped') }
            return [pscustomobject]@{ Apply = $true; Reason = 'app-stopped' }
        }
        'restart-if-hung' {
            if ($probeState -ne 'Unresponsive' -or $probeReason -ne 'timeout') { return (& $no 'not-unresponsive-timeout') }
            if ($State.HostType -eq 'host.macos.utm' -and -not [bool]$probe.corroborated) { return (& $no 'timeout-uncorroborated') }
            if ($Prediction) { return [pscustomobject]@{ Apply = $true; Reason = 'corroborated-timeout' } }
            if (-not $State.RecoverySaved) { return (& $no 'recovery-record-missing') }
            if (-not $State.ServiceVerdict -or -not [bool]$State.ServiceVerdict.Satisfied) { return (& $no 'service-set-unresolved') }
            if (-not $State.ServiceLocksHeld) { return (& $no 'service-locks-unavailable') }
            return [pscustomobject]@{ Apply = $true; Reason = 'corroborated-timeout' }
        }
        default { return (& $no 'no-executor') }
    }
}

function Test-HostRefreshRunnerQuiescent {
    <#
    .SYNOPSIS
        True when two runner snapshots a short settle apart agree, so no
        runner process is mid-spawn when the hypervisor is disrupted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Deadline)
    try {
        $planArguments = @{ WorkerPid = $PID }
        if ($State.RunnerView.CallerOuter) { $planArguments.PreserveOuter = $true }
        $first = New-YurunaRunnerReclaimPlan -Snapshot (Get-YurunaRunnerSnapshot -RuntimeDir $State.Context.RuntimeDir -RepoRoot $State.Context.RepoRoot -WorkerPid $PID -Deadline $Deadline) @planArguments
        $null = Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 1000
        $second = New-YurunaRunnerReclaimPlan -Snapshot (Get-YurunaRunnerSnapshot -RuntimeDir $State.Context.RuntimeDir -RepoRoot $State.Context.RepoRoot -WorkerPid $PID -Deadline $Deadline) @planArguments
        $comparison = Compare-YurunaRunnerReclaimPlan -Before $first -After $second
        return ([bool]$comparison.Quiescent -and @($second.Roots).Count -eq 0)
    } catch {
        return $false
    }
}

function Add-HostRefreshRungResult {
    <#
    .SYNOPSIS
        Record a rung outcome with its reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Rung,
        [Parameter(Mandatory)][ValidateSet('attempted', 'succeeded', 'failed', 'skipped')][string]$Outcome,
        [AllowEmptyString()][string]$Reason
    )
    $State.RungResults.Add([pscustomobject]@{ name = [string]$Rung.Name; order = [int]$Rung.Order; outcome = $Outcome; reason = [string]$Reason })
    if ($Outcome -eq 'skipped' -and $Reason -and $Reason -notin @('outside-ceiling', 'hypervisor-responsive')) { Add-HostRefreshReasonCode -State $State -Code $Reason }
}

function Invoke-HostRefreshLadder {
    <#
    .SYNOPSIS
        Climb the ladder from rung 1 up to the ceiling, re-probing after
        every attempted rung and stopping once the hypervisor answers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $ladder = $State.LadderDeadline
    $rows = @($State.Rungs | Sort-Object Order)
    $index = 0
    foreach ($rung in $rows) {
        $index++
        if ($rung.Order -eq 0) { continue }
        if ($rung.Order -gt $State.Ceiling.CeilingOrder) { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'outside-ceiling'; continue }
        if (-not $rung.Available) { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason "unavailable-$($rung.UnavailableCode)"; continue }
        if ([string]$State.LastProbe.state -eq 'Responsive' -and $rung.Name -ne 'reclaim') { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'hypervisor-responsive'; continue }
        if ($rung.Name -eq 'restart-if-hung' -and $State.HostType -eq 'host.macos.utm' -and -not [bool]$State.LastProbe.corroborated -and
            [string]$State.LastProbe.reason -eq 'timeout') {
            # The restart needs fresh corroborated evidence; the latest probe
            # may predate the earlier rungs.
            $State.LastProbe = Invoke-HostRefreshProbeRung -State $State -Deadline $ladder -Corroborate
        }
        $applicable = Test-HostRefreshRungApplicable -State $State -Rung $rung
        if (-not $applicable.Apply) { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason $applicable.Reason; continue }
        if ($rung.Name -eq 'restart-if-hung' -and -not (Test-HostRefreshRunnerQuiescent -State $State -Deadline $ladder)) {
            Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'runner-not-quiescent'; continue
        }
        if (-not (Test-YurunaSingleFlightLockOwned -Lock $State.Lock)) {
            Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'lock-lost'
            $State.ExecutionError = $true
            break
        }
        if ((Get-YurunaDeadlineRemainingMs -Deadline $ladder) -lt 1000) {
            Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'deadline-exhausted'
            $State.DeadlineExpired = $true
            break
        }
        if ($rung.RequiresSession -and $State.HostType -eq 'host.macos.utm') {
            $identity = Get-HostRefreshOperatorIdentity -HostType $State.HostType -RuntimeDir $State.Context.RuntimeDir -Deadline $ladder
            if (-not $identity.GuiAllowed) { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'no-session'; continue }
        }
        if (-not (Close-HostRefreshGate -State $State -Confirm:$false)) { Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'gate-unavailable'; continue }
        $arm = [string[]]@(Get-HostRefreshRungObligation -State $State -Rung $rung.Name)
        if ($arm.Count -gt 0 -and -not (Set-HostRefreshWorkerObligation -State $State -ObligationId $arm -Status armed -Confirm:$false)) {
            Add-HostRefreshRungResult -State $State -Rung $rung -Outcome skipped -Reason 'recovery-record-unwritable'; continue
        }
        $boundMs = [long](Get-YurunaDeadlineRemainingMs -Deadline $ladder)
        $null = Update-HostRefreshProgress -Publisher $State.Publisher -Change @{ phase = 'climbing'; step = @{ index = $index; count = $rows.Count; name = [string]$rung.Name; boundMs = $boundMs } } -Confirm:$false
        Write-HostRefreshLog -Key 'runner.host_refresh_rung_started' -Arguments @{ name = [string]$rung.Name; remainingSeconds = "$([long]($boundMs / 1000))" }
        $executor = $script:HostRefreshRungExecutor[$rung.Name]
        $execution = & $executor -State $State -Deadline $ladder
        if ($execution.Mutated) { $State.Mutated = $true }
        Add-HostRefreshRungResult -State $State -Rung $rung -Outcome ([string]$execution.Outcome) -Reason ([string]$execution.Reason)
        $State.LastProbe = Invoke-HostRefreshProbeRung -State $State -Deadline $ladder
        Write-HostRefreshLog -Key 'runner.host_refresh_rung_finished' -Arguments @{ name = [string]$rung.Name; outcome = [string]$execution.Outcome; state = [string]$State.LastProbe.state; reason = [string]$State.LastProbe.reason }
    }
}

function Invoke-HostRefreshServiceConvergence {
    <#
    .SYNOPSIS
        Bring back the services this attempt disrupted, and discharge each
        obligation only on verified health.
    .DESCRIPTION
        A service whose newest explicit intent is to stay stopped is disposed
        rather than resumed. On macOS each captured guest gets one resume
        through the saved-state path, then observation only: a failed resume
        never falls back to a cold boot that would delete the saved state.
        Elsewhere the ordinary restore start runs once, then the same
        observation. A service without verified health, or whose published
        endpoint could not be verified, keeps its obligation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Deadline)
    $armedServices = @($State.Obligations.Keys | Where-Object { $_ -like 'service:*' -and $State.Obligations[$_] -eq 'armed' })
    if ($armedServices.Count -eq 0) { return }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $State.RecoverySetRows) {
        $key = ConvertTo-HostRefreshServiceKey -Key ([string]$row.Key)
        if (-not $key -or "service:$key" -notin $armedServices) { continue }
        if (Get-HostRefreshCommand -Name 'Get-YurunaServiceIntent') {
            try {
                $intent = Get-YurunaServiceIntent -Key ([string]$row.Key)
                $captured = if ($row.PSObject.Properties['IntentGeneration']) { [long]$row.IntentGeneration } else { [long]0 }
                if ([string]$intent.DesiredState -eq 'stopped' -and [long]$intent.Generation -gt $captured) {
                    $ids = [string[]]@("service:$key", "endpoint:$key" | Where-Object { $State.Obligations[$_] -eq 'armed' })
                    $disposition = Set-HostRefreshObligationDisposition -ObligationId $ids -Actor 'superseded-by-operator-intent' -RequestId $State.RequestId -Confirm:$false
                    foreach ($id in @($disposition.Disposed)) { $State.Obligations[$id] = 'disposed' }
                    Add-HostRefreshReasonCode -State $State -Code 'superseded-by-operator-intent'
                    continue
                }
            } catch { Write-Verbose "Invoke-HostRefreshServiceConvergence: intent read failed: $($_.Exception.Message)" }
        }
        $rows.Add($row)
    }
    if ($rows.Count -eq 0) { return }
    $identities = [object[]]@($rows | ForEach-Object { if ($_.PSObject.Properties['Identity'] -and $_.Identity) { $_.Identity } else { $_ } })
    $restoreArguments = @{ Identity = $identities; Deadline = $Deadline; HypervisorProbe = $State.FinalProbe; ProbeRunning = $true; Confirm = $false }
    if ($State.ServiceLocks -and $State.ServiceLocksHeld) { $restoreArguments.OperationLock = $State.ServiceLocks }
    if ($State.HostType -eq 'host.macos.utm') {
        $names = [string[]]@($rows | ForEach-Object { [string]$_.VMName } | Where-Object { $_ })
        if ($names.Count -gt 0 -and (Get-HostRefreshCommand -Name 'Resume-YurunaServiceVM')) {
            $resumeArguments = @{ VMName = $names; Deadline = $Deadline; Confirm = $false }
            foreach ($switchName in @('NoDialogWatchdog', 'Detailed')) { if (Test-HostRefreshCommandParameter -Name 'Resume-YurunaServiceVM' -Parameter $switchName) { $resumeArguments[$switchName] = $true } }
            try { $null = @(Resume-YurunaServiceVM @resumeArguments) } catch { Add-HostRefreshReasonCode -State $State -Code 'service-resume-failed' }
        }
        $restoreArguments.ObserveOnly = $true
        $observed = @(Restore-YurunaServiceVM @restoreArguments)
    } else {
        $null = @(Restore-YurunaServiceVM @restoreArguments)
        $restoreArguments.ObserveOnly = $true
        $observed = @(Restore-YurunaServiceVM @restoreArguments)
    }
    foreach ($record in $observed) {
        $key = ConvertTo-HostRefreshServiceKey -Key ([string]$record.Key)
        if (-not $key) { continue }
        $obligation = if ($record.PSObject.Properties['Obligation']) { [string]$record.Obligation } else { if ($record.Healthy) { 'none' } else { 'health-unverified' } }
        if ([bool]$record.Healthy -and $obligation -eq 'none') {
            $null = Set-HostRefreshWorkerObligation -State $State -ObligationId @("service:$key") -Status discharged -Evidence 'health-verified' -Confirm:$false
        } else {
            Add-HostRefreshReasonCode -State $State -Code 'service-unverified'
            Write-HostRefreshLog -Key 'runner.host_refresh_service_unverified' -Arguments @{ key = $key; outcome = [string]$record.Outcome } -Level Warning
        }
        $endpointState = if ($record.PSObject.Properties['ConsumerEndpointState']) { [string]$record.ConsumerEndpointState } else { 'not-checked' }
        if ($State.Obligations["endpoint:$key"] -eq 'armed') {
            if ($endpointState -eq 'verified') {
                $null = Set-HostRefreshWorkerObligation -State $State -ObligationId @("endpoint:$key") -Status discharged -Evidence 'endpoint-verified' -Confirm:$false
            } else {
                Add-HostRefreshReasonCode -State $State -Code "endpoint-$endpointState"
            }
        }
    }
}

function Get-HostRefreshRunnerRestartRefusal {
    <#
    .SYNOPSIS
        Why this attempt may not restart the runner, or '' when it may.
    .DESCRIPTION
        A restart launches a detached runner and hands it the gate, which is
        exactly what the reclaim rung's availability qualifies: a lock whose
        exclusion holds on this platform, and a runner protocol whose process
        table, detached launch and handoff ran against real processes here.
        The same attempt must also hold the disruption precondition (a
        qualified lock file system and a verified HOME, so one account has
        one lock namespace). A dead runner is therefore reported for the
        operator to start wherever reclaim is unavailable, rather than
        restarted by a launch path nobody qualified there. Where reclaim
        needs the desktop session (a restarted runner drives UTM), so does
        the restart.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.DisruptionAllowed) {
        if ($State.DisruptionRefusal) { return [string]$State.DisruptionRefusal }
        return 'disruption-unqualified'
    }
    $reclaim = @($State.Rungs | Where-Object { [string]$_.Name -eq 'reclaim' })
    if ($reclaim.Count -eq 0 -or -not [bool]$reclaim[0].Available) { return 'runner-restart-unqualified' }
    if ([bool]$reclaim[0].RequiresSession -and -not [bool]$State.Identity.GuiAllowed) { return 'no-session' }
    return ''
}

function Invoke-HostRefreshRunnerConvergence {
    <#
    .SYNOPSIS
        Leave the runner running: park a caller outer behind a handoff, or
        restart a reclaimed or dead runner from its launch record.
    .DESCRIPTION
        A caller outer (the automatic channel's resident loop, or an outer in
        this worker's ancestry) is never reclaimed or restarted; after a
        responsive final probe it resumes on its own and, when this attempt
        closed the gate, through a resident-outer handoff. A reclaimed runner,
        or a dead one whose launch record shows it did not exit cleanly, is
        restarted through the refresh-resume protocol, which preserves every
        operator control and reports readiness only once the whole chain is
        verified. Without a valid launch record, or where the restart is not
        qualified (see Get-HostRefreshRunnerRestartRefusal), the operator
        starts it. A restart that launched anything is a mutation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)]$Deadline)
    $view = $State.RunnerView
    if ($view.CallerOuter) {
        $State.RunnerReadiness = 'caller-parked'
        if ($State.GateClosed -and (Get-HostRefreshCommand -Name 'New-YurunaRunnerHandoffToken')) {
            $onReady = if (@($State.Obligations.Keys | Where-Object { $State.Obligations[$_] -eq 'armed' }).Count -gt 0) { 'recovery-pending' } else { 'released' }
            try {
                $token = New-YurunaRunnerHandoffToken -RequestId $State.RequestId -Attempt ([int]$State.Attempt) -RuntimeDir $State.Context.RuntimeDir `
                    -Purpose 'resident-outer' -DesignatedOuter ([pscustomobject]@{ Pid = [int]$view.CallerOuter['pid']; StartTimeUnixMs = $view.CallerOuter['startTimeUnixMs'] }) `
                    -OnReady $onReady -ExpiresInMilliseconds 300000 -ExpectedGeneration $State.GateGeneration -Confirm:$false
                if ($token.Issued) {
                    $State.Handoff = [ordered]@{ tokenId = [string]$token.TokenId; purpose = 'resident-outer'; requestId = $State.RequestId }
                    $State.GateGeneration = [string]$token.Generation
                    $State.GateLeftInHandoff = $true
                } else {
                    Add-HostRefreshReasonCode -State $State -Code 'handoff-not-issued'
                }
            } catch { Add-HostRefreshReasonCode -State $State -Code 'handoff-not-issued' }
        }
        return
    }
    $outer = [string]$view.Outer.State
    $armedRunner = ($State.Obligations['runner'] -eq 'armed')
    $launch = $view.LaunchRecord
    $cleanExit = $State.CleanExit
    $restartNeeded = $armedRunner -or ($outer -in @('DeadOrRecycled', 'Missing') -and $launch -and $launch.Valid -and $cleanExit -ne $true)
    if (-not $restartNeeded) {
        if ($outer -eq 'AliveOwned') { $State.RunnerReadiness = 'not-needed' }
        elseif ($outer -eq 'Missing') { $State.RunnerReadiness = 'not-needed' }
        elseif ($outer -eq 'DeadOrRecycled') {
            $State.RunnerReadiness = 'not-ready'
            if (-not ($launch -and $launch.Valid)) { $State.OperatorAction = 'start-runner'; $State.UnconvergedExpectation++; Add-HostRefreshReasonCode -State $State -Code 'launch-record-missing' }
        } else {
            $State.RunnerReadiness = 'unknown'
            $State.UnconvergedExpectation++
        }
        return
    }
    if (-not ($launch -and $launch.Valid)) {
        $State.RunnerReadiness = 'not-ready'
        $State.OperatorAction = 'start-runner'
        $State.UnconvergedExpectation++
        Add-HostRefreshReasonCode -State $State -Code 'launch-record-missing'
        return
    }
    # Checked on the restoration path too: an obligation armed by an earlier
    # attempt does not qualify a launch this host cannot perform now.
    $restartRefusal = Get-HostRefreshRunnerRestartRefusal -State $State
    if ($restartRefusal) {
        $State.RunnerReadiness = 'not-ready'
        $State.OperatorAction = 'start-runner'
        $State.UnconvergedExpectation++
        Add-HostRefreshReasonCode -State $State -Code $restartRefusal
        Write-HostRefreshLog -Key 'runner.host_refresh_runner_not_ready' -Arguments @{ reason = $restartRefusal } -Level Warning
        return
    }
    if (-not (Get-HostRefreshCommand -Name 'Invoke-YurunaRunnerRefreshResume') -or -not (Close-HostRefreshGate -State $State -Confirm:$false)) {
        $State.RunnerReadiness = 'not-ready'
        $State.OperatorAction = 'start-runner'
        $State.UnconvergedExpectation++
        Add-HostRefreshReasonCode -State $State -Code 'runner-resume-unavailable'
        return
    }
    if (-not $armedRunner) {
        if (-not (Set-HostRefreshWorkerObligation -State $State -ObligationId @('runner') -Status armed -Confirm:$false)) {
            $State.RunnerReadiness = 'not-ready'
            $State.UnconvergedExpectation++
            Add-HostRefreshReasonCode -State $State -Code 'recovery-record-unwritable'
            return
        }
    }
    $onReady = if (@($State.Obligations.Keys | Where-Object { $_ -ne 'runner' -and $_ -ne 'controls' -and $State.Obligations[$_] -eq 'armed' }).Count -gt 0) { 'recovery-pending' } else { 'released' }
    $reclaimed = if ($State.Reclaimed) { $State.Reclaimed } else { @{ outer = $null; cycle = $null; inner = $null } }
    $resume = $null
    try {
        $resume = Invoke-YurunaRunnerRefreshResume -LaunchRecord $launch.Record -RequestId $State.RequestId -Attempt ([int]$State.Attempt) `
            -RuntimeDir $State.Context.RuntimeDir -RepoRoot $State.Context.RepoRoot -ExpectedGateGeneration $State.GateGeneration `
            -Reclaimed $reclaimed -PrivateDirectory $State.WorkDir -Deadline $Deadline -OnReady $onReady -Confirm:$false
    } catch {
        Write-Verbose "Invoke-HostRefreshRunnerConvergence: resume threw: $($_.Exception.Message)"
        $resume = $null
    }
    # A refusal or a preview launches nothing, and neither does a resume that
    # never issued its handoff token (the gate is left unchanged). Anything
    # else may have started a runner, and a throw may have happened after the
    # launch, so both count as a mutation.
    $launchedNothing = $resume -and ([string]$resume.Outcome -in @('refused', 'preview') -or [string]$resume.GateState -eq 'unchanged')
    if (-not $launchedNothing) { $State.Mutated = $true }
    if ($resume -and $resume.GateGeneration) { $State.GateGeneration = [string]$resume.GateGeneration }
    if ($resume -and [string]$resume.GateState -in @('released', 'recovery-pending', 'handoff')) { $State.GateLeftInHandoff = $true }
    if ($resume -and [string]$resume.Outcome -eq 'ready') {
        $State.RunnerReadiness = 'restarted-ready'
        $discharge = [System.Collections.Generic.List[string]]::new()
        $discharge.Add('runner')
        if ($State.Obligations['controls'] -eq 'armed') { $discharge.Add('controls') }
        $null = Set-HostRefreshWorkerObligation -State $State -ObligationId $discharge.ToArray() -Status discharged -Evidence 'runner-ready' -Confirm:$false
        return
    }
    $State.RunnerReadiness = 'not-ready'
    $State.OperatorAction = 'resume-request'
    $reason = if ($resume) { "runner-$($resume.Outcome)" } else { 'runner-resume-failed' }
    Add-HostRefreshReasonCode -State $State -Code $reason
    Write-HostRefreshLog -Key 'runner.host_refresh_runner_not_ready' -Arguments @{ reason = $reason } -Level Warning
}

function Invoke-HostRefreshConvergence {
    <#
    .SYNOPSIS
        Converge after the ladder, on one convergence deadline: fresh final
        probe first, and resume nothing unless it answers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $deadline = Get-HostRefreshPhaseDeadline -Budget $State.Budget -Phase Convergence
    $State.ConvergenceDeadline = $deadline
    $null = Update-HostRefreshProgress -Publisher $State.Publisher -Change @{ phase = 'converging'; step = @{ index = 0; count = 0; name = ''; boundMs = [long](Get-YurunaDeadlineRemainingMs -Deadline $deadline) } } -Confirm:$false
    $State.FinalProbe = Invoke-HostRefreshProbeRung -State $State -Deadline $deadline
    if ([string]$State.FinalProbe.state -ne 'Responsive') {
        Write-HostRefreshLog -Key 'runner.host_refresh_convergence_skipped' -Arguments @{ state = [string]$State.FinalProbe.state; reason = [string]$State.FinalProbe.reason } -Level Warning
        if ($State.RunnerView.CallerOuter) { $State.RunnerReadiness = 'not-ready' }
        return
    }
    try { Invoke-HostRefreshServiceConvergence -State $State -Deadline $deadline } catch {
        Add-HostRefreshReasonCode -State $State -Code 'service-convergence-error'
        Write-Verbose "Invoke-HostRefreshConvergence: services: $($_.Exception.Message)"
    }
    if ($State.HostType -eq 'host.macos.utm' -and (Get-HostRefreshCommand -Name 'Resolve-UtmctlExecutable')) {
        try {
            $resolution = Resolve-UtmctlExecutable
            if ([string]$resolution.Source -eq 'bundle' -and (Get-HostRefreshCommand -Name 'Set-MacUtmctlLink')) { $null = Set-MacUtmctlLink -Deadline $deadline -Confirm:$false }
        } catch { Add-HostRefreshReasonCode -State $State -Code 'utmctl-link-failed' }
    }
    $listenerArmed = ($State.Obligations['listener'] -eq 'armed')
    # The listener is brought back whenever it is enabled and could be down.
    # The refresh-safe start never restarts or kills a live listener, so the
    # only start skipped is one for a listener this attempt observed alive
    # and did nothing to disturb: that start could only answer existing-ready,
    # at the cost of a child process.
    $listenerEnabled = [bool]($State.Listener -and [bool]$State.Listener['enabled'])
    $serverState = if ($State.RunnerView -and $State.RunnerView.Server) { [string]$State.RunnerView.Server.State } else { '' }
    $listenerProvenUp = ($serverState -eq 'AliveOwned') -and -not $State.Mutated -and -not $State.RestorationOnly -and -not $listenerArmed
    if ($listenerEnabled -and -not $listenerProvenUp) {
        $resultPath = if ($State.WorkDir) { Join-Path $State.WorkDir "status-start.$($State.RequestId).json" } else { $null }
        if ($resultPath) {
            try {
                $listener = Start-HostRefreshStatusService -RepoRoot $State.Context.RepoRoot -RuntimeDir $State.Context.RuntimeDir -Port ([int]$State.Listener['port']) -ResultPath $resultPath -Deadline $deadline -Confirm:$false
                if ([string]$listener.Outcome -eq 'started') { $State.Mutated = $true }
                if ([string]$listener.Outcome -in @('existing-ready', 'started')) {
                    if ($listenerArmed) { $null = Set-HostRefreshWorkerObligation -State $State -ObligationId @('listener') -Status discharged -Evidence ([string]$listener.Outcome) -Confirm:$false }
                } else {
                    Add-HostRefreshReasonCode -State $State -Code "listener-$($listener.Outcome)"
                    $State.UnconvergedExpectation++
                }
            } catch {
                Add-HostRefreshReasonCode -State $State -Code 'listener-start-error'
                $State.UnconvergedExpectation++
            }
        }
    }
    try { Invoke-HostRefreshRunnerConvergence -State $State -Deadline $deadline } catch {
        Add-HostRefreshReasonCode -State $State -Code 'runner-convergence-error'
        $State.UnconvergedExpectation++
        Write-Verbose "Invoke-HostRefreshConvergence: runner: $($_.Exception.Message)"
    }
    if (Test-YurunaDeadlineExpired -Deadline $deadline) {
        $State.DeadlineExpired = $true
        Write-HostRefreshLog -Key 'runner.host_refresh_deadline_exhausted' -Arguments @{ phase = 'converging' } -Level Warning
    }
}

function Set-HostRefreshFinalGate {
    <#
    .SYNOPSIS
        Never leave the gate closed after the worker exits: released when no
        obligation is outstanding, recovery-pending otherwise, untouched when
        a handoff already owns it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.GateClosed -or $State.GateLeftInHandoff) { return }
    if (-not $PSCmdlet.ShouldProcess($State.RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$($State.RequestId)" }))) { return }
    $armed = @($State.Obligations.Keys | Where-Object { $State.Obligations[$_] -eq 'armed' }).Count
    $target = if ($armed -gt 0) { 'recovery-pending' } else { 'released' }
    try {
        $set = Set-YurunaRefreshGate -State $target -RequestId $State.RequestId -Attempt ([int]$State.Attempt) -RuntimeDir $State.Context.RuntimeDir `
            -ExpectedGeneration $State.GateGeneration -Confirm:$false
        if ($set.Written) { $State.GateGeneration = [string]$set.Generation } else { Add-HostRefreshReasonCode -State $State -Code 'gate-release-failed' }
    } catch {
        Add-HostRefreshReasonCode -State $State -Code 'gate-release-failed'
    }
}

function Get-HostRefreshOperatorAction {
    <#
    .SYNOPSIS
        The one next step an operator should take, from the final evidence.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Verdict)
    if ($State.OperatorAction) { return [string]$State.OperatorAction }
    $probe = if ($State.FinalProbe) { $State.FinalProbe } else { $State.LastProbe }
    $reason = if ($probe) { [string]$probe.reason } else { '' }
    switch ($reason) {
        'permission-denied' {
            if ($State.HostType -eq 'host.macos.utm') { return 'grant-automation' }
            if (-not $State.OperatorActionRung) { $State.OperatorActionRung = 'probe' }
            return 'elevate'
        }
        'no-session' { return 'gui-session' }
        'missing-client' { $State.OperatorActionClient = if ($State.HostType -eq 'host.macos.utm') { 'utmctl' } elseif ($State.HostType -eq 'host.ubuntu.kvm') { 'virsh' } else { 'Hyper-V' }; return 'install-client' }
    }
    if ($Verdict -eq 'abandoned') { return 'dispose-obligations' }
    if (@($State.Obligations.Keys | Where-Object { $State.Obligations[$_] -eq 'armed' }).Count -gt 0) { return 'resume-request' }
    return $null
}

function New-HostRefreshWorkerResult {
    <#
    .SYNOPSIS
        The Yuruna.HostRefreshResult record of a worker state.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$State)
    $probeView = { param($Probe) if ($null -eq $Probe) { $null } else { [pscustomobject]@{ state = [string]$Probe.state; reason = [string]$Probe.reason; elapsedMs = [long]$Probe.elapsedMs; corroborated = [bool]$Probe.corroborated; observedUtc = [string]$Probe.observedUtc } } }
    return [pscustomobject]@{
        PSTypeName           = 'Yuruna.HostRefreshResult'
        phase                = [string]$State.Phase
        hostType             = [string]$State.HostType
        requestId            = [string]$State.RequestId
        attempt              = [int]$State.Attempt
        generation           = [string]$State.Generation
        state                = [string]$State.StateName
        verdict              = [string]$State.Verdict
        exitCode             = [int]$State.ExitCode
        mutated              = [bool]$State.Mutated
        initialProbe         = (& $probeView $State.InitialProbe)
        finalProbe           = (& $probeView $State.FinalProbe)
        rungs                = [object[]]$State.RungResults.ToArray()
        obligations          = [object[]]@($State.Obligations.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ id = [string]$_; status = [string]$State.Obligations[$_] } })
        operatorAction       = $State.OperatorActionFinal
        operatorActionRung   = $State.OperatorActionRung
        operatorActionClient = $State.OperatorActionClient
        operatorInstruction  = [string[]]@($State.OperatorInstruction)
        reasonCodes          = [string[]]$State.ReasonCodes.ToArray()
        reportDegraded       = [bool]$State.ReportDegraded
        runnerReadiness      = [string]$State.RunnerReadiness
        runnerStatus         = if ($State.RunnerView) { [string]$State.RunnerView.Outer.State } else { $null }
        handoff              = $State.Handoff
        context              = $State.Context
        plan                 = $State.Plan
    }
}

function Invoke-HostRefreshPreviewPlan {
    <#
    .SYNOPSIS
        The read-only plan: what an executing run would find and consider.
    .DESCRIPTION
        One probe (never corroborating, so no second probe waits out a
        dialog window), the runner records, the unresolved request, the
        ceiling, each rung's availability and predicted applicability, the
        group relaunch decision and, on macOS, the utmctl link state from its
        own resolver. Nothing is created, locked, written or reserved; on KVM
        the start rung is predicted by its driver's own read-only preview.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $context = $State.Context
    $deadline = Get-HostRefreshPhaseDeadline -Budget $State.Budget -Phase PreAdmission
    $State.LastProbe = Invoke-HostRefreshProbeRung -State $State -Deadline $deadline
    $State.InitialProbe = $State.LastProbe
    if ($context.RuntimeDir -and [System.IO.Directory]::Exists([string]$context.RuntimeDir)) {
        $State.RunnerView = Get-HostRefreshRunnerView -RuntimeDir $context.RuntimeDir -RepoRoot $context.RepoRoot -Deadline $deadline
    }
    $active = $null
    if ($context.JournalPath) { $active = Get-HostRefreshActiveRequest -JournalPath $context.JournalPath }
    $rungs = [System.Collections.Generic.List[object]]::new()
    foreach ($rung in @($State.Rungs | Sort-Object Order)) {
        $inCeiling = ($rung.Order -le $State.Ceiling.CeilingOrder)
        $predicted = $null
        $consider = $false
        if ($rung.Order -ge 1 -and $inCeiling -and $rung.Available -and $State.RunnerView) {
            $check = Test-HostRefreshRungApplicable -State $State -Rung $rung -Prediction
            $predicted = $check.Reason
            $consider = [bool]$check.Apply -and ([string]$State.LastProbe.state -ne 'Responsive' -or $rung.Name -eq 'reclaim')
        }
        $driverPreview = $null
        if ($rung.Name -eq 'start-if-stopped' -and $State.HostType -eq 'host.ubuntu.kvm' -and $rung.Available -and $inCeiling -and
            (Get-HostRefreshCommand -Name 'Start-VirtualizationServiceIfStopped')) {
            try {
                $preview = Start-VirtualizationServiceIfStopped -Deadline $deadline -WhatIf:$true -Confirm:$false
                $driverPreview = [pscustomobject]@{ outcome = [string]$preview.outcome; reason = [string]$preview.reason; layout = [string]$preview.layout }
            } catch { $driverPreview = [pscustomobject]@{ outcome = 'unknown'; reason = 'preview-failed'; layout = 'unknown' } }
        }
        $rungs.Add([pscustomobject]@{
                name = [string]$rung.Name; order = [int]$rung.Order; available = [bool]$rung.Available; unavailableCode = $rung.UnavailableCode
                unavailableReason = $rung.UnavailableReason; inCeiling = $inCeiling; wouldConsider = $consider; predicted = $predicted; driverPreview = $driverPreview
            })
    }
    $group = $null
    if (Get-HostRefreshCommand -Name 'Test-LibvirtGroupReExecNeeded') {
        try { $group = Test-LibvirtGroupReExecNeeded -HostType $State.HostType } catch { $group = [pscustomobject]@{ Needed = $false; Reason = 'probe-failed' } }
    }
    $utmctl = $null
    if ($State.HostType -eq 'host.macos.utm' -and (Get-HostRefreshCommand -Name 'Resolve-UtmctlExecutable')) {
        try {
            $resolution = Resolve-UtmctlExecutable
            $utmctl = [pscustomobject]@{ source = [string]$resolution.Source; linkOnPath = [bool]$resolution.LinkOnPath; bundlePresent = [bool]$resolution.BundlePresent }
        } catch { $utmctl = $null }
    }
    $runnerRecord = { param($Record) if ($null -eq $Record) { 'Unknown' } else { [string]$Record.State } }
    $State.Plan = [pscustomobject]@{
        PSTypeName    = 'Yuruna.HostRefreshPreview'
        phase         = 'preview'
        hostType      = [string]$State.HostType
        tier          = [string]$State.RequestPolicy['tier']
        ceiling       = [string]$State.Ceiling.CeilingName
        context       = [pscustomobject]@{
            resolved = [bool]$context.Resolved; reason = [string]$context.Reason; runtimeDir = $context.RuntimeDir; runtimeSource = $context.RuntimeSource
            configPath = $context.ConfigPath; configSource = $context.ConfigSource; observation = [string[]]@($context.Observation)
            lockQualified = [bool]$context.LockQualified; homeVerified = [string]$context.HomeVerified
        }
        identity      = [pscustomobject]@{ allowed = [bool]$State.Identity.Allowed; reason = [string]$State.Identity.Reason; sessionKind = [string]$State.Identity.SessionKind }
        probe         = [pscustomobject]@{ state = [string]$State.LastProbe.state; reason = [string]$State.LastProbe.reason; elapsedMs = [long]$State.LastProbe.elapsedMs; timedOut = [bool]$State.LastProbe.timedOut }
        runner        = if ($State.RunnerView) { [pscustomobject]@{ outer = (& $runnerRecord $State.RunnerView.Outer); inner = (& $runnerRecord $State.RunnerView.Inner); cycle = (& $runnerRecord $State.RunnerView.Cycle); source = [string]$State.RunnerView.Source } } else { $null }
        activeRequest = if ($active) { [pscustomobject]@{ requestId = [string]$active['requestId']; state = [string]$active['state']; attempt = [int]$active['attempt'] } } else { $null }
        rungs         = [object[]]$rungs.ToArray()
        groupRelaunch = $group
        utmctl        = $utmctl
        verdict       = 'preview'
        exitCode      = 0
    }
    $State.Verdict = 'preview'
    $State.ExitCode = 0
    $State.Phase = 'preview'
}

function Invoke-HostRefreshWorker {
    <#
    .SYNOPSIS
        Run one host-refresh attempt (or its read-only preview) end to end.
    .DESCRIPTION
        Executing order: identity and context refusals; the Windows hop exit
        and the startup handshake; the lifetime lock; the claim; the progress
        publisher; the service-key locks when a guest-disrupting rung is in
        reach; rung 0; the recovery record, persisted before any mutation; a
        restoration-only pass for a retry that still owes restoration; the
        healthy-cycle gate; the ladder; then, in finally, convergence on one
        deadline, the final gate state, the verdict, the journal, the
        terminal projection and the lock releases, each in its own guard so
        a cleanup failure never masks the verdict or skips a release.

        Nothing prompts, and every native call is bounded by a phase deadline
        carved from the invocation budget.
    .PARAMETER Context
        From Resolve-HostRefreshContext.
    .PARAMETER Budget
        From New-HostRefreshBudget.
    .PARAMETER Identity
        From Get-HostRefreshOperatorIdentity.
    .PARAMETER Mode
        New, Claim, Resume or Dispose.
    .PARAMETER Policy
        New only: Tier, MaxRung, Force, AllowHardStop, RestoreServiceVmName,
        LeaveStoppedServiceVmName.
    .PARAMETER RequestId
        Claim: the queued request. Resume: optional.
    .PARAMETER DisposeObligation
        Dispose: the obligation ids to record as handled.
    .PARAMETER Preview
        Read-only plan; nothing is created, locked or written.
    .PARAMETER RungDeclaration
        Test seam: the rung rows to use instead of the declaration.
    .OUTPUTS
        [pscustomobject] Yuruna.HostRefreshResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Budget,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][ValidateSet('New', 'Claim', 'Resume', 'Dispose')][string]$Mode,
        [System.Collections.IDictionary]$Policy,
        [string]$RequestId,
        [string[]]$DisposeObligation,
        [switch]$Preview,
        [object[]]$RungDeclaration
    )
    $hostType = [string]$Context.HostType
    $State = @{
        Context = $Context; Budget = $Budget; Identity = $Identity; Mode = $Mode; Preview = [bool]$Preview; HostType = $hostType
        RequestId = $RequestId; Generation = $null; Attempt = 0; Channel = 'local'; Phase = 'starting'; StateName = ''
        Verdict = 'failed'; ExitCode = 1; Mutated = $false; ExecutionError = $false; DeadlineExpired = $false; UnconvergedExpectation = 0
        ReasonCodes = [System.Collections.Generic.List[string]]::new(); RungResults = [System.Collections.Generic.List[object]]::new()
        Obligations = @{}; OperatorAction = $null; OperatorActionFinal = $null; OperatorActionRung = $null; OperatorActionClient = $null; OperatorInstruction = @()
        RunnerReadiness = 'unknown'; Handoff = $null; ReportDegraded = $false; Plan = $null
        InitialProbe = $null; LastProbe = $null; FinalProbe = $null; RunnerView = $null; Lock = $null; ServiceLocks = $null; ServiceLocksHeld = $false
        Publisher = $null; GateClosed = $false; GateGeneration = $null; GateLeftInHandoff = $false; Reclaimed = $null
        RecoverySaved = $false; RecoverySetRows = [object[]]@(); ServiceVerdict = $null; Listener = $null; CleanExit = $null; ControlsPresent = $false
        DisruptionAllowed = $false; DisruptionRefusal = $null; WorkDir = $null; RestorationOnly = $false
        RequestPolicy = @{ tier = 'restart'; maxRung = $null; force = $false; allowHardStop = $false; restoreServiceVmName = @(); leaveStoppedServiceVmName = @() }
    }
    if ($Policy) { foreach ($key in $Policy.Keys) { $State.RequestPolicy[([string]$key).Substring(0, 1).ToLowerInvariant() + ([string]$key).Substring(1)] = $Policy[$key] } }
    $State.Rungs = if ($RungDeclaration) { [object[]]$RungDeclaration } elseif ($hostType -in $script:HostRefreshHostTypes) { [object[]]@(Get-VirtualizationRepairRung -HostType $hostType) } else { [object[]]@() }
    $State.Ceiling = Get-HostRefreshRungCeiling -HostType $hostType -Tier ([string]$State.RequestPolicy['tier']) -MaxRung ([string]$State.RequestPolicy['maxRung'])
    if (-not $State.Ceiling.Valid) { $State.Ceiling = [pscustomobject]@{ Valid = $false; Reason = $State.Ceiling.Reason; TierCeilingOrder = 0; CeilingOrder = 0; CeilingName = 'probe' } }
    $refuse = {
        param([string]$Reason, [string]$Key = 'runner.host_refresh_refused', [hashtable]$Arguments)
        Add-HostRefreshReasonCode -State $State -Code $Reason
        $State.Verdict = 'refused'
        $State.ExitCode = 1
        $State.Phase = 'terminal'
        $State.StateName = 'refused'
        $logArguments = if ($Arguments) { $Arguments } else { @{ reason = $Reason } }
        Write-HostRefreshLog -Key $Key -Arguments $logArguments -Level Warning
        $State.OperatorActionFinal = Get-HostRefreshOperatorAction -State $State -Verdict 'refused'
    }

    if ($Preview) {
        Invoke-HostRefreshPreviewPlan -State $State
        return (New-HostRefreshWorkerResult -State $State)
    }
    if (-not $PSCmdlet.ShouldProcess("$RequestId", (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        $State.Verdict = 'preview'; $State.ExitCode = 0; $State.Phase = 'preview'
        return (New-HostRefreshWorkerResult -State $State)
    }

    # refusals before any lock
    $preAdmission = Get-HostRefreshPhaseDeadline -Budget $Budget -Phase PreAdmission
    if (-not $Identity.Allowed) {
        & $refuse ([string]$Identity.Reason) 'runner.host_refresh_identity_refused' @{ identity = "$($Identity.UserName)"; reason = "$($Identity.Reason)"; runtimeDir = "$($Context.RuntimeDir)" }
        # Root, or an identity nobody can name, never writes private state: a
        # journal write could create the operator's private root owned by the
        # wrong account. The queued request then expires or is relaunched.
        $mayWrite = [string]$Identity.Reason -notin @('root-refused', 'identity-unknown')
        if ($mayWrite -and $Mode -eq 'Claim' -and $RequestId) { $null = Stop-HostRefreshQueuedRequest -RequestId $RequestId -Reason worker-refused -Detail ([string]$Identity.Reason) -Confirm:$false }
        return (New-HostRefreshWorkerResult -State $State)
    }
    if (-not $Context.Resolved) {
        $reasonKey = switch ([string]$Context.Reason) {
            'config-ambiguous' { 'runner.host_refresh_config_ambiguous' }
            'config-missing' { 'runner.host_refresh_config_missing' }
            'config-conflict' { 'runner.host_refresh_config_conflict' }
            'runtime-missing' { 'runner.host_refresh_runtime_missing' }
            'runtime-owner-mismatch' { 'runner.host_refresh_runtime_owner_mismatch' }
            'private-root-unavailable' { 'runner.host_refresh_private_root_unavailable' }
            default { 'runner.host_refresh_refused' }
        }
        $arguments = @{
            reason = "$($Context.Reason)"; count = "$($Context.ConfigCandidateCount)"; runtimeDir = "$($Context.RuntimeDir)"; configPath = "$($Context.ConfigPath)"
            recordedPath = "$($Context.RecordedConfigPath)"; registeredRuntimeDir = "$($Context.RegisteredRuntimeDir)"
        }
        if ($reasonKey -eq 'runner.host_refresh_private_root_unavailable') { $arguments = @{ reason = "$($Context.PrivateRootReason)" } }
        & $refuse ([string]$Context.Reason) $reasonKey $arguments
        if ($Mode -eq 'Claim' -and $RequestId -and $Context.Reason -ne 'private-root-unavailable') { $null = Stop-HostRefreshQueuedRequest -RequestId $RequestId -Reason worker-refused -Detail ([string]$Context.Reason) -Confirm:$false }
        return (New-HostRefreshWorkerResult -State $State)
    }
    $State.WorkDir = Get-HostRefreshPrivateWorkDir

    # The Windows hop exit and the startup handshake, before any lock.
    if ($env:YURUNA_DETACH_HOP_PID) {
        if (-not (Get-HostRefreshCommand -Name 'Wait-YurunaDetachedHopExit')) {
            & $refuse 'hop-wait-unavailable'
            return (New-HostRefreshWorkerResult -State $State)
        }
        $hop = Wait-YurunaDetachedHopExit -Deadline $preAdmission
        if (-not $hop.Exited) {
            & $refuse 'launcher-still-running' 'runner.host_refresh_launcher_wait_timeout' @{ launcherPid = "$($env:YURUNA_DETACH_HOP_PID)"; waitedSeconds = "$([long]((Get-HostRefreshPhaseDeadline -Budget $Budget -Phase PreAdmission).ExpiryTick - $Budget.StartTick) / 1000)"; requestId = "$RequestId" }
            return (New-HostRefreshWorkerResult -State $State)
        }
    }
    if ($env:YURUNA_DETACH_HANDSHAKE -and $RequestId -and (Get-HostRefreshCommand -Name 'Write-YurunaDetachedHandshake')) {
        try { $null = Write-YurunaDetachedHandshake -RequestId $RequestId -Confirm:$false } catch { Add-HostRefreshReasonCode -State $State -Code 'handshake-unwritten' }
    }

    # lifetime lock
    $remaining = [long](Get-YurunaDeadlineRemainingMs -Deadline $preAdmission)
    $wait = if ($Mode -in @('Claim', 'Resume') -and $RequestId) { [int][Math]::Min($remaining, 60000) } else { [int][Math]::Min($remaining, 1500) }
    $lock = Enter-YurunaSingleFlightLock -Path $Context.LifetimeLockPath -WaitMilliseconds ([Math]::Max(0, $wait)) -Rank (Get-YurunaLockRank -Name HostOperation) `
        -Deadline $preAdmission -Metadata @{ purpose = 'host-refresh'; requestId = "$RequestId" }
    if (-not $lock.Held) {
        & $refuse 'lock-busy' 'runner.host_refresh_lock_busy' @{ reason = "$($lock.Reason)" }
        return (New-HostRefreshWorkerResult -State $State)
    }
    $State.Lock = $lock
    try {
        $State.DisruptionAllowed = [bool]$Context.LockQualified -and ([string]$Context.HomeVerified -eq 'verified')
        $State.DisruptionRefusal = if (-not $Context.LockQualified) { 'lock-unqualified' } elseif ([string]$Context.HomeVerified -ne 'verified') { 'home-unverified' } else { $null }

        # dispose
        if ($Mode -eq 'Dispose') {
            $actor = if ($Identity.UserName) { [string]$Identity.UserName } else { [Environment]::UserName }
            $disposition = Set-HostRefreshObligationDisposition -ObligationId $DisposeObligation -Actor $actor -Confirm:$false
            $State.RequestId = [string]$disposition.RequestId
            foreach ($id in @($disposition.Disposed)) {
                $State.Obligations[$id] = 'disposed'
                Write-HostRefreshLog -Key 'runner.host_refresh_obligation_disposed' -Arguments @{ obligation = $id; requestId = "$($disposition.RequestId)"; actor = $actor }
            }
            foreach ($id in @($disposition.Unknown)) {
                Write-HostRefreshLog -Key 'runner.host_refresh_obligation_unknown' -Arguments @{ obligation = $id; requestId = "$($disposition.RequestId)" } -Level Warning
            }
            if ($disposition.Saved -and @($disposition.Disposed).Count -gt 0 -and @($disposition.Unknown).Count -eq 0) {
                $State.Verdict = 'disposed'; $State.ExitCode = 0; $State.StateName = [string]$disposition.State
                if ([int]$disposition.RemainingOutstanding -eq 0 -and (Get-HostRefreshCommand -Name 'Get-YurunaRefreshGateState')) {
                    try {
                        $gate = Get-YurunaRefreshGateState -RuntimeDir $Context.RuntimeDir
                        if ([string]$gate.State -eq 'recovery-pending' -and [string]$gate.RequestId -ceq $State.RequestId -and (Get-HostRefreshCommand -Name 'Set-YurunaRefreshGate')) {
                            $null = Set-YurunaRefreshGate -State released -RequestId $State.RequestId -Attempt ([int]$gate.Attempt) -RuntimeDir $Context.RuntimeDir -ExpectedGeneration ([string]$gate.Generation) -Confirm:$false
                        }
                    } catch { Add-HostRefreshReasonCode -State $State -Code 'gate-release-failed' }
                }
            } else {
                Add-HostRefreshReasonCode -State $State -Code 'obligation-unknown'
                $State.Verdict = 'refused'; $State.ExitCode = 1
            }
            $State.Phase = 'terminal'
            return (New-HostRefreshWorkerResult -State $State)
        }

        # claim
        $worker = [ordered]@{
            pid = $PID; startTimeUnixMs = (Get-HostRefreshProcessIdentity -ProcessId $PID).startTimeUnixMs; ownerId = [string]$Identity.OwnerId
            parent = $null
            budget = [ordered]@{ totalExpiryTick = [long]$Budget.TotalExpiryTick; preAdmissionExpiryTick = [long]$Budget.PreAdmissionExpiryTick; clamped = [bool]$Budget.Clamped }
        }
        try {
            $parentProcess = ([System.Diagnostics.Process]::GetProcessById($PID)).Parent
            if ($parentProcess) { $worker.parent = Get-HostRefreshProcessIdentity -ProcessId $parentProcess.Id }
        } catch { $worker.parent = $null }
        $newId = if ($Mode -eq 'New') { New-YurunaHostRefreshRequestId } else { $RequestId }
        $claimArguments = @{ LifetimeLock = $lock; Mode = $Mode; Worker = $worker; RuntimeDir = $Context.RuntimeDir; RepoRoot = $Context.RepoRoot; HostType = $hostType; Confirm = $false }
        if ($newId) { $claimArguments.RequestId = $newId }
        if ($Mode -eq 'New') {
            $claimArguments.Policy = $State.RequestPolicy
            $claimArguments.Context = @{ configPath = $Context.ConfigPath }
        }
        $claim = Confirm-HostRefreshIntent @claimArguments
        if (-not $claim.Accepted) {
            if ($claim.Reason -eq 'refused-terminal' -and $claim.StoredVerdict) {
                $State.RequestId = $newId
                $State.Verdict = [string]$claim.StoredVerdict
                $State.ExitCode = Get-HostRefreshExitCode -Verdict $State.Verdict
                $State.Phase = 'terminal'
                Add-HostRefreshReasonCode -State $State -Code 'request-terminal'
                return (New-HostRefreshWorkerResult -State $State)
            }
            if ($claim.Reason -eq 'refused-attempts-exhausted') {
                $State.RequestId = if ($claim.Request) { [string]$claim.Request['requestId'] } else { $newId }
                $State.Verdict = 'abandoned'; $State.ExitCode = 2; $State.Phase = 'terminal'; $State.StateName = 'abandoned'
                $State.OperatorActionFinal = 'dispose-obligations'
                Add-HostRefreshReasonCode -State $State -Code 'attempts-exhausted'
                return (New-HostRefreshWorkerResult -State $State)
            }
            if ($claim.Reason -eq 'refused-no-request' -and $Mode -eq 'Resume') {
                & $refuse 'refused-no-request' 'runner.host_refresh_resume_none' @{}
                return (New-HostRefreshWorkerResult -State $State)
            }
            $active = if ($claim.Request) { $claim.Request } else { $null }
            & $refuse ([string]$claim.Reason) 'runner.host_refresh_request_refused' @{
                requestId = "$newId"; reason = "$($claim.Reason)"; activeRequestId = if ($active) { "$($active['requestId'])" } else { '' }
                state = if ($active) { "$($active['state'])" } else { '' }
            }
            if ($claim.Reason -eq 'refused-active-other-request') { $State.OperatorActionFinal = 'resume-request' }
            return (New-HostRefreshWorkerResult -State $State)
        }
        $request = $claim.Request
        $State.RequestId = [string]$request['requestId']
        $State.Generation = [string]$claim.Generation
        $State.Attempt = [int]$claim.Attempt
        $State.Channel = [string]$request['channel']
        $State.RestorationOnly = [bool]$claim.RestorationOnly
        foreach ($key in @($request['policy'].Keys)) { $State.RequestPolicy[[string]$key] = $request['policy'][$key] }
        foreach ($obligation in @($request['obligations'])) { if ($obligation) { $State.Obligations[[string]$obligation['id']] = [string]$obligation['status'] } }
        $State.Ceiling = Get-HostRefreshRungCeiling -HostType $hostType -Tier ([string]$State.RequestPolicy['tier']) -MaxRung ([string]$State.RequestPolicy['maxRung'])
        if ($Mode -eq 'Resume') { Write-HostRefreshLog -Key 'runner.host_refresh_resume_started' -Arguments @{ requestId = $State.RequestId; attempt = "$($State.Attempt)"; mode = $(if ($State.RestorationOnly) { 'restoration-only' } else { 'retry' }) } }
        $Budget = Set-HostRefreshBudgetAdmitted -Budget $Budget
        $State.Budget = $Budget
        $State.LadderDeadline = Get-HostRefreshPhaseDeadline -Budget $Budget -Phase Ladder
        $State.Phase = 'claimed'
        $callerOuter = $null
        if ($request['context'] -is [System.Collections.IDictionary] -and $request['context']['callerOuter'] -is [System.Collections.IDictionary]) { $callerOuter = $request['context']['callerOuter'] }
        $State.Publisher = Start-HostRefreshProgressPublisher -Path $Context.PublicStatePath -ExpiryTick ([long]$Budget.TotalExpiryTick) -Initial @{
            requestId = $State.RequestId; generation = $State.Generation; attempt = $State.Attempt; channel = $State.Channel; phase = 'claimed'; state = 'running'
            step = @{ index = 0; count = @($State.Rungs).Count; name = ''; boundMs = [long](Get-YurunaDeadlineRemainingMs -Deadline $State.LadderDeadline) }
            reasonCodes = @(); reportDegraded = $false; mutated = $false; verdict = ''; operatorAction = ''; terminalUtc = ''
        } -Confirm:$false

        try {
            # service-key locks, when a guest-disrupting rung is in reach
            $guestRungs = @($State.Rungs | Where-Object { $_.Available -and $_.Destructive -and $_.Order -le $State.Ceiling.CeilingOrder })
            if ($guestRungs.Count -gt 0 -or $State.RestorationOnly) {
                if ((Get-HostRefreshCommand -Name 'Enter-YurunaServiceOperationLockSet') -and (Get-HostRefreshCommand -Name 'Get-YurunaServiceVmRoster')) {
                    $keys = [string[]]@(Get-YurunaServiceVmRoster | ForEach-Object { [string]$_.Key } | Where-Object { $_ })
                    $lockDeadline = New-YurunaDeadline -Parent $State.LadderDeadline -TotalMilliseconds 30000
                    try {
                        $State.ServiceLocks = Enter-YurunaServiceOperationLockSet -Key $keys -Deadline $lockDeadline -WaitMilliseconds ([int][Math]::Min(30000, (Get-YurunaDeadlineRemainingMs -Deadline $lockDeadline))) -Purpose 'host-refresh' -Confirm:$false
                        $State.ServiceLocksHeld = [bool]$State.ServiceLocks.Held
                    } catch { $State.ServiceLocksHeld = $false }
                }
                if (-not $State.ServiceLocksHeld) { Add-HostRefreshReasonCode -State $State -Code 'service-locks-unavailable' }
            }

            # rung 0
            $null = Update-HostRefreshProgress -Publisher $State.Publisher -Change @{ phase = 'probing' } -Confirm:$false
            $State.LastProbe = Invoke-HostRefreshProbeRung -State $State -Deadline $State.LadderDeadline -Corroborate
            $State.InitialProbe = $State.LastProbe
            $State.RungResults.Add([pscustomobject]@{ name = 'probe'; order = 0; outcome = 'succeeded'; reason = [string]$State.LastProbe.reason })

            # capture
            $null = Update-HostRefreshProgress -Publisher $State.Publisher -Change @{ phase = 'capturing' } -Confirm:$false
            $State.RunnerView = Get-HostRefreshRunnerView -RuntimeDir $Context.RuntimeDir -RepoRoot $Context.RepoRoot -Deadline $State.LadderDeadline -CallerOuter $callerOuter
            if ($hostType -eq 'host.macos.utm' -and [string]$State.LastProbe.reason -eq 'permission-denied' -and (Get-HostRefreshCommand -Name 'Get-MacOperatorGrant') -and (Get-HostRefreshCommand -Name 'Get-MacOperatorGrantInstruction')) {
                try { $State.OperatorInstruction = [string[]]@(Get-MacOperatorGrantInstruction -Grant @(Get-MacOperatorGrant -Id AutomationUtm)[0]) } catch { $State.OperatorInstruction = @() }
            }
            if (-not (Invoke-HostRefreshCapture -State $State -Deadline $State.LadderDeadline)) {
                & $refuse 'recovery-record-unwritable'
                $State.RefusedBeforeMutation = $true
            } elseif ($State.RestorationOnly) {
                Add-HostRefreshReasonCode -State $State -Code 'restoration-only'
            } else {
                $outerState = [string]$State.RunnerView.Outer.State
                $cleanExit = $State.CleanExit
                $launchValid = [bool]($State.RunnerView.LaunchRecord -and $State.RunnerView.LaunchRecord.Valid)
                $healthyRunner = ($outerState -eq 'AliveOwned') -or ($outerState -eq 'Missing' -and -not ($launchValid -and $cleanExit -ne $true))
                if ([string]$State.LastProbe.state -eq 'Responsive' -and $healthyRunner -and -not [bool]$State.RequestPolicy['force']) {
                    Write-HostRefreshLog -Key 'runner.host_refresh_verified_noop'
                    Add-HostRefreshReasonCode -State $State -Code 'verified-noop'
                    $State.NoOp = $true
                } else {
                    $null = Update-HostRefreshProgress -Publisher $State.Publisher -Change @{ phase = 'climbing' } -Confirm:$false
                    Invoke-HostRefreshLadder -State $State
                }
            }
        } catch {
            $State.ExecutionError = $true
            Add-HostRefreshReasonCode -State $State -Code 'execution-error'
            Write-HostRefreshLog -Key 'runner.host_refresh_unexpected_error' -Arguments @{ phase = "$($State.Phase)"; message = "$($_.Exception.Message)" } -Level Warning -ConsoleOnly
        } finally {
            # convergence, verdict, journal, terminal projection
            try {
                $needsConvergence = -not $State.RefusedBeforeMutation -and -not $State.NoOp -and
                    ($State.Mutated -or $State.RestorationOnly -or @($State.Obligations.Keys | Where-Object { $State.Obligations[$_] -eq 'armed' }).Count -gt 0 -or
                    ([string]$State.RunnerView.Outer.State -in @('DeadOrRecycled', 'Missing', 'Unknown')))
                if ($needsConvergence) { Invoke-HostRefreshConvergence -State $State }
                elseif (-not $State.FinalProbe) { $State.FinalProbe = $State.LastProbe }
            } catch {
                $State.ExecutionError = $true
                Add-HostRefreshReasonCode -State $State -Code 'convergence-error'
            }
            try { Set-HostRefreshFinalGate -State $State -Confirm:$false } catch { Add-HostRefreshReasonCode -State $State -Code 'gate-release-failed' }
            $armedCount = @($State.Obligations.Keys | Where-Object { $State.Obligations[$_] -eq 'armed' }).Count
            if (-not $State.FinalProbe -and -not $State.RefusedBeforeMutation) { $State.UnconvergedExpectation++ }
            if (Test-YurunaDeadlineExpired -Deadline $State.LadderDeadline) {
                if (@($State.RungResults | Where-Object { $_.reason -eq 'deadline-exhausted' }).Count -gt 0) { $State.DeadlineExpired = $true }
            }
            if ($State.DeadlineExpired) { Add-HostRefreshReasonCode -State $State -Code 'deadline-exhausted' }
            $facts = @{
                Preview = $false; Disposed = $false; Refused = [bool]$State.RefusedBeforeMutation; AttemptsExhausted = $false
                ExecutionError = [bool]$State.ExecutionError; Mutated = [bool]$State.Mutated
                FinalProbeState = if ($State.FinalProbe) { [string]$State.FinalProbe.state } else { $null }
                FinalProbeReason = if ($State.FinalProbe) { [string]$State.FinalProbe.reason } else { $null }
                ArmedOutstanding = $armedCount; UnconvergedExpectation = [int]$State.UnconvergedExpectation; DeadlineExpired = [bool]$State.DeadlineExpired
            }
            $verdict = Get-HostRefreshVerdict -Facts $facts
            foreach ($code in @($verdict.ReasonCodes)) { Add-HostRefreshReasonCode -State $State -Code $code }
            $State.Verdict = [string]$verdict.Verdict
            $State.OperatorActionFinal = Get-HostRefreshOperatorAction -State $State -Verdict $State.Verdict
            $completion = $null
            try {
                $completion = Complete-HostRefreshAttempt -RequestId $State.RequestId -Generation $State.Generation -Verdict $State.Verdict -Mutated ([bool]$State.Mutated) `
                    -ReasonCode ([string[]]$State.ReasonCodes.ToArray()) -RungResult ([object[]]$State.RungResults.ToArray()) -OperatorAction ([string]$State.OperatorActionFinal) `
                    -FinalProbe $State.FinalProbe -RunnerReadiness $State.RunnerReadiness -Handoff $State.Handoff -GateGeneration ([string]$State.GateGeneration) -Confirm:$false
            } catch { $completion = $null }
            if ($null -eq $completion -or -not $completion.Saved) {
                Add-HostRefreshReasonCode -State $State -Code 'journal-unwritable'
                if ($State.Verdict -in @('repaired', 'already-healthy')) { $State.Verdict = 'partial' }
                $State.StateName = [string]$verdict.State
            } else {
                $State.StateName = [string]$completion.State
            }
            $State.ExitCode = Get-HostRefreshExitCode -Verdict $State.Verdict
            $State.Phase = 'terminal'
            try {
                $stop = Stop-HostRefreshProgressPublisher -Publisher $State.Publisher -Confirm:$false -Terminal @{
                    phase = 'terminal'; state = $State.StateName; verdict = $State.Verdict; mutated = [bool]$State.Mutated
                    reasonCodes = [string[]]$State.ReasonCodes.ToArray(); operatorAction = [string]$State.OperatorActionFinal; terminalUtc = (Get-HostRefreshUtcText)
                    step = @{ index = 0; count = 0; name = ''; boundMs = 0 }
                }
                $State.ReportDegraded = [bool]$stop.ReportDegraded
                if ($State.ReportDegraded) { Write-HostRefreshLog -Key 'runner.host_refresh_progress_degraded' -Level Warning }
            } catch { $State.ReportDegraded = $true }
            try { if ($State.ServiceLocks -and (Get-HostRefreshCommand -Name 'Exit-YurunaServiceOperationLockSet')) { Exit-YurunaServiceOperationLockSet -Context $State.ServiceLocks } } catch { Add-HostRefreshReasonCode -State $State -Code 'service-lock-release-failed' }
        }
        return (New-HostRefreshWorkerResult -State $State)
    } finally {
        try { Exit-YurunaSingleFlightLock -Lock $lock } catch { $null = $_ }
    }
}

Export-ModuleMember -Function Get-VirtualizationRepairRung, Get-HostRefreshRungCeiling, Get-HostRefreshProtocolVersion, Get-HostRefreshCapability, `
    New-HostRefreshBudget, Set-HostRefreshBudgetAdmitted, Get-HostRefreshPhaseDeadline, Get-HostRefreshVerdict, Get-HostRefreshExitCode, `
    ConvertTo-HostRefreshWireCode, ConvertTo-HostRefreshPublicState, Start-HostRefreshProgressPublisher, Update-HostRefreshProgress, `
    Stop-HostRefreshProgressPublisher, Publish-HostRefreshQueuedState, Write-HostRefreshLog, Write-HostRefreshSummary, Resolve-HostRefreshContext, `
    Get-HostRefreshOperatorIdentity, Get-HostRefreshRequiredCommand, Assert-HostRefreshCommandSet, Get-HostRefreshModuleSet, `
    New-HostRefreshRelaunchParameter, New-HostRefreshWorkerArgumentList, Start-HostRefreshStatusService, Invoke-HostRefreshWorker
