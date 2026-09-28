<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42be3895-85a7-48d1-b55d-aeffcd674ec0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh worker orchestration pester
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

<#
.SYNOPSIS
    Invoke-HostRefreshWorker end to end, in process, against a scratch private
    root: every driver, service-evidence and runner-protocol command is a
    stand-in that records its calls, so each case asserts the order of
    actions, the verdict and exit code, what was mutated, the journal's state
    and obligations and the public terminal record -- and that nothing it
    must not do was ever called.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRefresh, Test.HostRefreshIntent, Yuruna.Host, default | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefreshIntent.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefresh.psm1') -Force -Global -DisableNameChecking
    $script:Created = [System.Collections.Generic.List[string]]::new()
    # One temp directory per run (TMPDIR decides where), removed in AfterAll.
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'yuruna-host-refresh-worker'
    $script:Created.Add($script:ScratchBase)
    $script:Log = [System.Collections.Generic.List[string]]::new()
    $script:Captured = @{}

    # Stand-ins for commands this module resolves by name and does not
    # import: a mock needs a command, with the real parameter names, to
    # exist before it can replace it. They are declarations only (every
    # call is mocked), so they are built from text rather than analyzed as
    # functions whose parameters go unused. The gate reader answers open:
    # admission in the journal module resolves it globally, while the
    # runner-protocol module is loaded only inside Test.HostRefresh here.
    $standIns = @'
function global:Test-VirtualizationResponsive { param([int]$TimeoutSeconds, $Deadline, [switch]$Corroborate, [int]$DialogWindowSeconds, [string[]]$RecordedAutomationSubject, [switch]$IncludeInventory) }
function global:Start-VirtualizationServiceIfStopped { [CmdletBinding(SupportsShouldProcess)] param([int]$TimeoutSeconds, $Deadline, [string[]]$DependentVMName) }
function global:Restart-UtmApplication { [CmdletBinding(SupportsShouldProcess)] param($Evidence, $Deadline, [int]$QuitWaitSeconds, [int]$LaunchWaitSeconds, [switch]$AllowHardStop) }
function global:Resume-YurunaServiceVM { [CmdletBinding(SupportsShouldProcess)] param([string[]]$VMName, [int]$TimeoutSeconds, $Deadline, [switch]$NoDialogWatchdog, [switch]$Detailed) }
function global:Resolve-UtmctlExecutable { param() }
function global:Set-MacUtmctlLink { [CmdletBinding(SupportsShouldProcess)] param($Deadline) }
function global:Get-MacSessionKind { param([int]$TimeoutSeconds) }
function global:Get-MacOperatorGrant { param([string]$Id) }
function global:Get-MacOperatorGrantInstruction { param($Grant, [switch]$Compact) }
function global:Get-PortMapTarget { param($Deadline) }
function global:Get-YurunaServiceVmRoster { param([string[]]$Key) }
function global:Get-YurunaServiceVmIdentitySet { param([string]$RuntimeDir, [string]$HostType, [switch]$ResolveProvider, $Deadline) }
function global:Test-YurunaServiceVmRunning { param([object[]]$Identity, [string]$UnknownMeans, $HypervisorProbe, [string]$RuntimeDir, [string]$HostType, [string[]]$RestoreServiceVmName, [string[]]$LeaveStoppedServiceVmName, [switch]$AllowOperatorSelection, $Deadline) }
function global:Restore-YurunaServiceVM { [CmdletBinding(SupportsShouldProcess)] param([object[]]$Identity, $Deadline, $HypervisorProbe, [switch]$ProbeRunning, [switch]$ObserveOnly, $OperationLock) }
function global:Get-YurunaServiceIntent { param([string]$Key) }
function global:Enter-YurunaServiceOperationLockSet { [CmdletBinding(SupportsShouldProcess)] param([string[]]$Key, $Deadline, [int]$WaitMilliseconds, [string]$Purpose) }
function global:Exit-YurunaServiceOperationLockSet { param($Context) }
function global:Read-TestConfig { param([string]$Path) }
function global:Resolve-StaleBreakActive { [CmdletBinding(SupportsShouldProcess)] param([string]$RuntimeDir) }
function global:Get-YurunaRefreshGateState { param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot) $null = $RuntimeDir, $TokenId, $PrivateRoot; [pscustomobject]@{ State = 'open'; RequestId = $null; Generation = ''; Reason = 'test' } }
'@
    . ([scriptblock]::Create($standIns))

    function New-ScratchDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch directory under the private test area.')]
        param([string]$Prefix = 'worker')
        $dir = Join-Path $script:ScratchBase ($Prefix + '-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script:Created.Add($dir)
        $dir
    }

    function New-TestProbe {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory probe record.')]
        param([string]$State = 'Responsive', [string]$Reason = 'responsive', [bool]$Corroborated = $false, [string]$HostType = 'host.ubuntu.kvm')
        [pscustomobject]@{
            PSTypeName = 'Yuruna.VirtualizationProbe'; schemaVersion = 1; hostType = $HostType; state = $State; reason = $Reason
            started = $true; timedOut = ($Reason -eq 'timeout'); deadlineExhausted = $false; corroborated = $Corroborated
            observedUtc = [DateTime]::UtcNow.ToString('o'); observedTick = [Environment]::TickCount64; elapsedMs = 12
            evidence = [pscustomobject]@{}; diagnostic = 'private diagnostic text'; automationSubject = 'uid=501;app=pwsh'
        }
    }

    function New-TestRung {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory rung row.')]
        param([string]$Name, [int]$Order, [bool]$Available, [string]$Code, [bool]$Destructive = $false, [bool]$RequiresSession = $false)
        [pscustomobject]@{
            Name = $Name; Order = $Order; Destructive = $Destructive; RequiresElevation = $false; RequiresSession = $RequiresSession; EstimatedSeconds = 30
            Available = $Available; UnavailableCode = if ($Available) { $null } else { $Code }; UnavailableReason = if ($Available) { $null } else { $Code }
        }
    }

    function Get-KvmRung {
        param()
        @(
            New-TestRung -Name probe -Order 0 -Available $true
            New-TestRung -Name reclaim -Order 1 -Available $true
            New-TestRung -Name start-if-stopped -Order 2 -Available $true
            New-TestRung -Name restart-if-hung -Order 3 -Available $false -Code daemon-layout-unqualified -Destructive $true
            New-TestRung -Name restart-broker -Order 4 -Available $false -Code modular-daemon-recipe-missing -Destructive $true
            New-TestRung -Name reapply-settings -Order 5 -Available $false -Code settings-recipe-unsafe -Destructive $true
            New-TestRung -Name reinstall -Order 6 -Available $false -Code unsupported-on-platform -Destructive $true
            New-TestRung -Name reboot -Order 7 -Available $false -Code no-reboot-supervision -Destructive $true
        )
    }

    function Get-MacRung {
        param()
        @(
            New-TestRung -Name probe -Order 0 -Available $true
            New-TestRung -Name reclaim -Order 1 -Available $true -RequiresSession $true
            New-TestRung -Name start-if-stopped -Order 2 -Available $false -Code gui-launch-unqualified -RequiresSession $true
            New-TestRung -Name restart-if-hung -Order 3 -Available $true -Destructive $true -RequiresSession $true
            New-TestRung -Name restart-broker -Order 4 -Available $false -Code broker-recipe-missing -Destructive $true -RequiresSession $true
            New-TestRung -Name reapply-settings -Order 5 -Available $false -Code settings-recipe-unsafe -Destructive $true -RequiresSession $true
            New-TestRung -Name reinstall -Order 6 -Available $false -Code package-recovery-unqualified -Destructive $true -RequiresSession $true
            New-TestRung -Name reboot -Order 7 -Available $false -Code no-reboot-supervision -Destructive $true
        )
    }

    function New-TestServiceRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory service row.')]
        param([string]$Key, [string]$VMName, [string]$Url = '')
        $identity = [pscustomobject]@{ Key = $Key; VMName = $VMName; HostingMode = 'vm'; HealthPort = 3000; DisplayName = $Key; Advertised = [pscustomobject]@{ Url = $Url } }
        [pscustomobject]@{ Key = $Key; VMName = $VMName; State = 'Running'; Disposition = 'restore-required'; IntentGeneration = 1; Identity = $identity }
    }

    # One scenario per case; the stand-ins read it.
    function New-TestScenario {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds the in-memory scenario the stand-ins read.')]
        param(
            [string]$HostType = 'host.ubuntu.kvm',
            [object[]]$Probe = @(@{ State = 'Responsive'; Reason = 'responsive' }),
            [string]$Outer = 'AliveOwned', [string]$Inner = 'Missing',
            [bool]$LaunchValid = $true, $CleanExit = $false,
            [object[]]$Service = @(), [bool]$ServicesSatisfied = $true, [bool]$ServiceLocksHeld = $true,
            [string]$ResumeOutcome = 'ready', [bool]$GateWritable = $true, [bool]$Quiescent = $true, [string]$Server = 'Missing'
        )
        $queue = [System.Collections.Generic.Queue[hashtable]]::new()
        foreach ($row in $Probe) { $queue.Enqueue($row) }
        $script:Log.Clear()
        $script:Captured = @{ ProbeDeadline = [System.Collections.Generic.List[object]]::new() }
        $script:Scenario = @{
            HostType = $HostType; Probes = $queue; Runner = @{ Outer = $Outer; Inner = $Inner; Cycle = 'Missing'; Server = $Server }
            LaunchValid = $LaunchValid; CleanExit = $CleanExit; Services = [object[]]$Service; ServicesSatisfied = $ServicesSatisfied
            ServiceLocksHeld = $ServiceLocksHeld; ResumeOutcome = $ResumeOutcome; GateWritable = $GateWritable; Quiescent = $Quiescent
            Gate = @{ State = 'open'; RequestId = $null; Generation = '' }; Intent = @{}; StartResult = $null; RestartThrows = $false
            SessionKind = 'Aqua'; RestartOutcome = 'restarted'; Healthy = $true; EndpointState = 'verified'; ListenerEnabled = $false
            ListenerOutcome = 'existing-ready'
        }
    }

    function New-TestSnapshotRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory runner record.')]
        param([string]$State, [int]$ProcessId, [string]$File)
        [pscustomobject]@{ State = $State; Pid = $ProcessId; RecordedStartTimeUnixMs = 1000; LiveStartTimeUnixMs = 1000; PidFile = $File; Fingerprint = "fp-$ProcessId" }
    }

    function Set-WorkerMock {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: registers Pester mocks for the current block.')]
        param()
        Mock -ModuleName Test.HostRefresh Test-VirtualizationResponsive {
            $script:Log.Add('probe' + $(if ($Corroborate) { ':corroborate' } else { '' }))
            $script:Captured.ProbeDeadline.Add($Deadline)
            if ($script:Scenario.ProbeDelayMs) { Start-Sleep -Milliseconds $script:Scenario.ProbeDelayMs; $script:Scenario.ProbeDelayMs = 0 }
            $next = if ($script:Scenario.Probes.Count -gt 1) { $script:Scenario.Probes.Dequeue() } else { $script:Scenario.Probes.Peek() }
            New-TestProbe -State $next.State -Reason $next.Reason -Corroborated ([bool]$next.Corroborated) -HostType $script:Scenario.HostType
        }
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerSnapshot {
            $script:Log.Add('snapshot')
            $runner = $script:Scenario.Runner
            $launch = [pscustomobject]@{
                Found = $script:Scenario.LaunchValid; Valid = $script:Scenario.LaunchValid; Reason = 'test'; Path = $null
                Record = if ($script:Scenario.LaunchValid) { @{ parameters = @{ ConfigPath = '/x.yml'; NoStatusService = $false }; cleanExit = $script:Scenario.CleanExit } } else { $null }
            }
            [pscustomobject]@{
                Outer = (New-TestSnapshotRecord -State $runner.Outer -ProcessId 4101 -File (Join-Path $RuntimeDir 'runner.pid'))
                Cycle = (New-TestSnapshotRecord -State $runner.Cycle -ProcessId 4102 -File $null)
                Inner = (New-TestSnapshotRecord -State $runner.Inner -ProcessId 4103 -File (Join-Path $RuntimeDir 'inner.pid'))
                Server = (New-TestSnapshotRecord -State $runner.Server -ProcessId 4104 -File $null)
                LaunchRecord = $launch
            }
        }
        Mock -ModuleName Test.HostRefresh New-YurunaRunnerReclaimPlan {
            $script:Captured.PreserveOuter = [bool]$PreserveOuter
            $roots = foreach ($role in @('Inner', 'Cycle', 'Outer')) {
                if ($role -eq 'Outer' -and $PreserveOuter) { continue }
                $record = $Snapshot.$role
                if ($record.State -eq 'AliveOwned') { [pscustomobject]@{ Pid = $record.Pid; StartTimeUnixMs = 1000; Role = $role } }
            }
            $refusals = foreach ($role in @('Inner', 'Outer')) {
                if ($role -eq 'Outer' -and $PreserveOuter) { continue }
                if ($Snapshot.$role.State -in @('Unknown', 'AliveOther')) { [pscustomobject]@{ Role = $role; State = $Snapshot.$role.State; Reason = 'test' } }
            }
            [pscustomobject]@{ Roots = [object[]]@($roots); Refusals = [object[]]@($refusals); Reclaimable = (@($roots).Count -gt 0); Target = $null }
        }
        Mock -ModuleName Test.HostRefresh Compare-YurunaRunnerReclaimPlan { [pscustomobject]@{ Quiescent = $script:Scenario.Quiescent; NewPid = @(); GonePid = @(); ChangedRoot = @() } }
        Mock -ModuleName Test.HostRefresh Stop-YurunaRunnerProcessTarget {
            $script:Log.Add('stop-runner')
            foreach ($root in @($Plan.Roots)) { $script:Scenario.Runner[$root.Role] = 'DeadOrRecycled' }
            [pscustomobject]@{ Converged = $true; Targets = [object[]]@($Plan.Roots | ForEach-Object { [pscustomobject]@{ Pid = $_.Pid; Action = 'exited-after-term' } }); Survivors = @(); DeadlineExhausted = $false }
        }
        Mock -ModuleName Test.HostRefresh Remove-YurunaRunnerRecordGeneration { $script:Log.Add('remove-record'); [pscustomobject]@{ Removed = $true; Reason = 'removed' } }
        Mock -ModuleName Test.HostRefresh Get-YurunaRefreshGateState {
            $gate = $script:Scenario.Gate
            [pscustomobject]@{ State = $gate.State; RequestId = $gate.RequestId; Generation = $gate.Generation; Attempt = 1; Reason = 'test' }
        }
        Mock -ModuleName Test.HostRefresh Set-YurunaRefreshGate {
            $script:Log.Add("gate:$State")
            if (-not $script:Scenario.GateWritable) { return [pscustomobject]@{ Written = $false; Generation = $null; Reason = 'lock-busy' } }
            if ([string]$ExpectedGeneration -ne [string]$script:Scenario.Gate.Generation) { return [pscustomobject]@{ Written = $false; Generation = $null; Reason = 'generation-mismatch' } }
            $generation = [Guid]::NewGuid().ToString('N')
            $script:Scenario.Gate = @{ State = $(if ($State -eq 'released') { 'open' } else { $State }); RequestId = $RequestId; Generation = $generation }
            [pscustomobject]@{ Written = $true; Generation = $generation; Reason = 'written' }
        }
        Mock -ModuleName Test.HostRefresh New-YurunaRunnerHandoffToken {
            $script:Log.Add("handoff:$Purpose")
            $script:Captured.DesignatedOuter = $DesignatedOuter
            $script:Scenario.Gate.State = 'handoff'
            [pscustomobject]@{ Issued = $true; TokenId = ('t' * 32); Generation = ('h' * 32); Reason = 'issued' }
        }
        Mock -ModuleName Test.HostRefresh Invoke-YurunaRunnerRefreshResume {
            $script:Log.Add('resume-runner')
            $script:Captured.OnReady = $OnReady
            # A refusal or a preview issues no handoff token, so the gate is
            # left as it was.
            $outcome = $script:Scenario.ResumeOutcome
            $gateState = if ($outcome -eq 'ready') { 'released' } elseif ($outcome -in @('refused', 'preview')) { 'unchanged' } else { 'recovery-pending' }
            if ($gateState -ne 'unchanged') { $script:Scenario.Gate.State = 'open' }
            [pscustomobject]@{ Outcome = $outcome; Reason = 'test'; GateState = $gateState; GateGeneration = $(if ($gateState -eq 'unchanged') { $ExpectedGateGeneration } else { 'r' * 32 }) }
        }
        Mock -ModuleName Test.HostRefresh Read-YurunaRunnerLaunchRecord { [pscustomobject]@{ Found = $script:Scenario.LaunchValid; Valid = $script:Scenario.LaunchValid; Record = @{ cleanExit = $script:Scenario.CleanExit } } }
        Mock -ModuleName Test.HostRefresh Start-VirtualizationServiceIfStopped {
            $script:Log.Add('start-service' + $(if ($PesterBoundParameters.ContainsKey('WhatIf') -and $PesterBoundParameters['WhatIf']) { ':whatif' } else { '' }))
            $script:Captured.DependentVMName = [string[]]@($DependentVMName)
            if ($script:Scenario.StartResult) { return $script:Scenario.StartResult }
            [pscustomobject]@{ outcome = 'started'; reason = 'started'; layout = 'monolithic'; actions = @() }
        }
        Mock -ModuleName Test.HostRefresh Restart-UtmApplication {
            $script:Log.Add('restart-utm')
            $script:Captured.AllowHardStop = [bool]$AllowHardStop
            if ($script:Scenario.RestartThrows) { throw 'UTM restart failed' }
            [pscustomobject]@{ Outcome = $script:Scenario.RestartOutcome; Reason = $script:Scenario.RestartOutcome; HardStopUsed = $false }
        }
        Mock -ModuleName Test.HostRefresh Resume-YurunaServiceVM { $script:Log.Add('resume-vm'); $script:Captured.ResumeNames = [string[]]@($VMName) }
        Mock -ModuleName Test.HostRefresh Resolve-UtmctlExecutable { [pscustomobject]@{ Source = 'path'; LinkOnPath = $true; BundlePresent = $true } }
        Mock -ModuleName Test.HostRefresh Set-MacUtmctlLink { $script:Log.Add('link') }
        Mock -ModuleName Test.HostRefresh Get-MacSessionKind { $script:Scenario.SessionKind }
        Mock -ModuleName Test.HostRefresh Get-MacOperatorGrant { [pscustomobject]@{ Id = 'AutomationUtm' } }
        Mock -ModuleName Test.HostRefresh Get-MacOperatorGrantInstruction { @('Open the Automation privacy pane') }
        Mock -ModuleName Test.HostRefresh Get-PortMapTarget { }
        Mock -ModuleName Test.HostRefresh Get-YurunaServiceVmRoster { [pscustomobject]@{ Key = 'caching-proxy' }; [pscustomobject]@{ Key = 'stash' } }
        Mock -ModuleName Test.HostRefresh Get-YurunaServiceVmIdentitySet { [pscustomobject]@{ Rows = [object[]]@($script:Scenario.Services | ForEach-Object { $_.Identity }) } }
        Mock -ModuleName Test.HostRefresh Test-YurunaServiceVmRunning {
            $script:Log.Add('service-verdict')
            $script:Captured.AllowOperatorSelection = [bool]$AllowOperatorSelection
            $script:Captured.RestoreServiceVmName = [string[]]@($RestoreServiceVmName)
            $rows = [object[]]$script:Scenario.Services
            [pscustomobject]@{
                Satisfied = $script:Scenario.ServicesSatisfied; Refusal = $(if ($script:Scenario.ServicesSatisfied) { '' } else { 'service-evidence-incomplete' })
                Services = $rows; RecoverySet = $rows; LeaveStoppedSet = @(); UnresolvedSet = @()
            }
        }
        Mock -ModuleName Test.HostRefresh Restore-YurunaServiceVM {
            $script:Log.Add('restore:' + $(if ($ObserveOnly) { 'observe' } else { 'start' }))
            foreach ($row in @($Identity)) {
                [pscustomobject]@{ Key = $row.Key; VMName = $row.VMName; Healthy = $script:Scenario.Healthy; Outcome = 'running'
                    Obligation = $(if ($script:Scenario.Healthy) { 'none' } else { 'health-unverified' }); ConsumerEndpointState = $script:Scenario.EndpointState }
            }
        }
        Mock -ModuleName Test.HostRefresh Get-YurunaServiceIntent {
            $intent = $script:Scenario.Intent[$Key]
            if ($intent) { $intent } else { [pscustomobject]@{ DesiredState = 'running'; Generation = 1 } }
        }
        Mock -ModuleName Test.HostRefresh Enter-YurunaServiceOperationLockSet { $script:Log.Add('service-locks'); [pscustomobject]@{ Held = $script:Scenario.ServiceLocksHeld; Keys = [string[]]$Key; Token = 'k' } }
        Mock -ModuleName Test.HostRefresh Exit-YurunaServiceOperationLockSet { $script:Log.Add('service-unlock') }
        Mock -ModuleName Test.HostRefresh Read-TestConfig { @{ testCycle = @{}; statusService = @{ enabled = $script:Scenario.ListenerEnabled; port = 8080 } } }
        Mock -ModuleName Test.HostRefresh Resolve-StaleBreakActive { $script:Log.Add('break') }
        Mock -ModuleName Test.HostRefresh Start-HostRefreshStatusService { $script:Log.Add('listener'); [pscustomobject]@{ Outcome = $script:Scenario.ListenerOutcome; Reason = $script:Scenario.ListenerOutcome } }
    }

    function New-TestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch runtime and home for one case.')]
        param([string]$HostType = 'host.ubuntu.kvm', [string]$HomeVerified = 'verified', [bool]$LockQualified = $true, [string]$PublicStatePath)
        $dir = New-ScratchDir
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } (Join-Path $dir 'home')
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'home') -Force
        $runtime = Join-Path $dir 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $config = Join-Path $dir 'test.config.yml'
        [IO.File]::WriteAllText($config, "testCycle: {}`nstatusService:`n  enabled: false`n")
        [pscustomobject]@{
            Resolved = $true; Reason = 'ok'; HostType = $HostType; RepoRoot = $script:RepoRoot; TestRoot = (Join-Path $script:RepoRoot 'test')
            ModulesDir = (Join-Path $script:RepoRoot 'test/modules'); RuntimeDir = $runtime; RuntimeSource = 'environment'
            ConfigPath = $config; ConfigSource = 'explicit'; LaunchRecord = $null; PrivateRoot = (Join-Path $dir 'home/.yuruna/host-refresh')
            PrivateRootReason = 'ok'; JournalPath = (Get-YurunaHostRefreshRequestPath); LifetimeLockPath = (Get-YurunaHostRefreshLockPath)
            AdmissionLockPath = (Get-YurunaHostRefreshAdmissionLockPath)
            PublicStatePath = $(if ($PublicStatePath) { $PublicStatePath } else { Join-Path $runtime 'host-refresh.state.json' })
            OwnerMatches = $true; HomeVerified = $HomeVerified; LockQualified = $LockQualified; LockQualification = 'qualified'
            Observation = [string[]]@(); ConfigCandidateCount = 0; RegisteredRuntimeDir = $null; RecordedConfigPath = $null
        }
    }

    function New-TestIdentity {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory identity record.')]
        param([bool]$GuiAllowed = $false, [bool]$Allowed = $true, [string]$Reason = 'ok')
        [pscustomobject]@{ Allowed = $Allowed; Reason = $Reason; OwnerId = '1001'; UserName = 'tester'; IsRoot = $false; Elevated = $false
            SessionKind = $(if ($GuiAllowed) { 'Aqua' } else { 'NotApplicable' }); GuiAllowed = $GuiAllowed; RuntimeOwnerMatches = $true }
    }

    function Invoke-TestWorker {
        param(
            $Context, [string]$Mode = 'New', [hashtable]$Policy = @{ tier = 'restart' }, [object[]]$Rung, $Identity, $Budget,
            [string]$RequestId, [string[]]$DisposeObligation, [switch]$Preview
        )
        if (-not $Identity) { $Identity = New-TestIdentity -GuiAllowed ($Context.HostType -eq 'host.macos.utm') }
        if (-not $Budget) { $Budget = New-HostRefreshBudget }
        if (-not $Rung) { $Rung = if ($Context.HostType -eq 'host.macos.utm') { Get-MacRung } else { Get-KvmRung } }
        $arguments = @{ Context = $Context; Budget = $Budget; Identity = $Identity; Mode = $Mode; RungDeclaration = $Rung; Preview = $Preview; Confirm = $false }
        if ($Mode -eq 'New') { $arguments.Policy = $Policy }
        if ($RequestId) { $arguments.RequestId = $RequestId }
        if ($DisposeObligation) { $arguments.DisposeObligation = $DisposeObligation }
        Invoke-HostRefreshWorker @arguments -InformationAction SilentlyContinue -WarningAction SilentlyContinue
    }

    function Get-TerminalProjection {
        param($Context)
        [IO.File]::ReadAllText($Context.PublicStatePath) | ConvertFrom-Json -AsHashtable
    }

    function Get-LogIndex {
        param([string]$Name)
        $script:Log.IndexOf($Name)
    }
}

AfterAll {
    # Scratch directories first, so a failure removing a stand-in can never
    # leave them behind.
    foreach ($dir in $script:Created) { try { Remove-YurunaTestTempDir $dir } catch { $null = $_ } }
    foreach ($name in @('Test-VirtualizationResponsive', 'Start-VirtualizationServiceIfStopped', 'Restart-UtmApplication', 'Resume-YurunaServiceVM', 'Resolve-UtmctlExecutable',
            'Set-MacUtmctlLink', 'Get-MacSessionKind', 'Get-MacOperatorGrant', 'Get-MacOperatorGrantInstruction', 'Get-PortMapTarget', 'Get-YurunaServiceVmRoster',
            'Get-YurunaServiceVmIdentitySet', 'Test-YurunaServiceVmRunning', 'Restore-YurunaServiceVM', 'Get-YurunaServiceIntent', 'Enter-YurunaServiceOperationLockSet',
            'Exit-YurunaServiceOperationLockSet', 'Read-TestConfig', 'Resolve-StaleBreakActive', 'Get-YurunaRefreshGateState')) {
        try { Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
}

Describe 'healthy hosts' {
    BeforeEach { Set-WorkerMock }

    It 'returns a verified no-op for a responsive hypervisor and a live runner, changing nothing' {
        New-TestScenario -Outer AliveOwned
        $context = New-TestContext
        $result = Invoke-TestWorker -Context $context
        Assert-Equal 'already-healthy' $result.verdict
        Assert-Equal 0 $result.exitCode
        Assert-False $result.mutated
        foreach ($forbidden in @('stop-runner', 'start-service', 'restart-utm', 'resume-vm', 'resume-runner', 'gate:closed')) { Assert-False ($script:Log.Contains($forbidden)) "no $forbidden" }
        $request = Read-YurunaHostRefreshRequest -RequestId $result.requestId
        Assert-Equal 'completed' $request['state']
        $projection = Get-TerminalProjection -Context $context
        Assert-Equal 'terminal' $projection['phase']
        Assert-Equal 'already_healthy' $projection['verdict']
        Assert-Equal 'completed' $projection['state']
        Assert-False ((Get-Content -Raw -LiteralPath $context.PublicStatePath).Contains('private diagnostic')) 'the probe diagnostic never reaches the public file'
    }

    It 'with -Force reclaims and restarts a healthy runner, and never touches the hypervisor' {
        New-TestScenario -Outer AliveOwned
        $context = New-TestContext
        $result = Invoke-TestWorker -Context $context -Policy @{ tier = 'restart'; force = $true }
        Assert-Equal 'repaired' $result.verdict
        Assert-True $result.mutated
        Assert-True ((Get-LogIndex 'gate:closed') -ge 0 -and (Get-LogIndex 'gate:closed') -lt (Get-LogIndex 'stop-runner')) 'the gate closes before the first signal'
        Assert-True ((Get-LogIndex 'stop-runner') -lt (Get-LogIndex 'resume-runner'))
        Assert-False ($script:Log.Contains('start-service'))
        Assert-Equal 'restarted-ready' $result.runnerReadiness
        Assert-Equal 'discharged' (@($result.obligations | Where-Object { $_.id -eq 'runner' })[0].status)
    }
}

Describe 'dead and unknown runners' {
    BeforeEach { Set-WorkerMock }

    It 'cleans a dead runner''s records and restarts it from its launch record' {
        New-TestScenario -Outer DeadOrRecycled -Inner DeadOrRecycled -CleanExit $false
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'repaired' $result.verdict
        Assert-True ($script:Log.Contains('remove-record'))
        Assert-False ($script:Log.Contains('stop-runner')) 'a dead runner has nothing to signal'
        Assert-True ((Get-LogIndex 'remove-record') -lt (Get-LogIndex 'resume-runner'))
    }

    It 'reports partial with start-runner and restarts nothing when there is no launch record' {
        New-TestScenario -Outer DeadOrRecycled -LaunchValid $false
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'partial' $result.verdict
        Assert-Equal 2 $result.exitCode
        Assert-Equal 'start-runner' $result.operatorAction
        Assert-False ($script:Log.Contains('resume-runner'))
    }

    It 'treats a runner that exited cleanly as healthy' {
        New-TestScenario -Outer Missing -CleanExit $true
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'already-healthy' $result.verdict
        Assert-False ($script:Log.Contains('resume-runner'))
    }

    It 'never signals a runner whose liveness is unknown, and reports it unconverged' {
        New-TestScenario -Outer Unknown
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-False ($script:Log.Contains('stop-runner'))
        Assert-Equal 'runner-liveness-unknown' (@($result.rungs | Where-Object { $_.name -eq 'reclaim' })[0].reason)
        Assert-Equal 'partial' $result.verdict
        Assert-False $result.mutated
    }
}

Describe 'restarting a runner that is not running' {
    BeforeEach { Set-WorkerMock }

    It 'restarts a runner that never exited cleanly, and reports it as a repair' {
        New-TestScenario -Outer Missing -CleanExit $false
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'runner-not-in-the-way' (@($result.rungs | Where-Object { $_.name -eq 'reclaim' })[0].reason) 'reclaim had nothing to stop'
        Assert-True ($script:Log.Contains('resume-runner'))
        Assert-Equal 'restarted-ready' $result.runnerReadiness
        Assert-True $result.mutated 'starting a runner changes the host'
        Assert-Equal 'repaired' $result.verdict
        Assert-Equal 0 $result.exitCode
        Assert-Equal 'completed' (Read-YurunaHostRefreshRequest -RequestId $result.requestId)['state']
    }

    It 'counts a refused restart, which launched nothing, as no change' {
        New-TestScenario -Outer Missing -CleanExit $false -ResumeOutcome refused
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-True ($script:Log.Contains('resume-runner'))
        Assert-False $result.mutated
        Assert-Equal 'not-ready' $result.runnerReadiness
        Assert-Equal 'partial' $result.verdict
    }

    It 'never restarts a runner while the home directory or the lock file system is unverified' {
        foreach ($case in @(
                @{ Context = @{ HomeVerified = 'mismatch' }; Reason = 'home-unverified' }
                @{ Context = @{ LockQualified = $false }; Reason = 'lock-unqualified' }
            )) {
            New-TestScenario -Outer DeadOrRecycled -CleanExit $false
            $contextArguments = $case.Context
            $result = Invoke-TestWorker -Context (New-TestContext @contextArguments)
            foreach ($forbidden in @('resume-runner', 'gate:closed', 'remove-record', 'stop-runner')) { Assert-False ($script:Log.Contains($forbidden)) "$($case.Reason): no $forbidden" }
            Assert-Equal 'partial' $result.verdict $case.Reason
            Assert-Equal 2 $result.exitCode
            Assert-Equal 'start-runner' $result.operatorAction
            Assert-Equal 'not-ready' $result.runnerReadiness
            Assert-True (@($result.reasonCodes) -contains $case.Reason) $case.Reason
            Assert-False $result.mutated
        }
    }

    It 'never restarts a runner on a host whose declaration leaves reclaim unavailable' {
        New-TestScenario -HostType host.macos.utm -Outer Missing -CleanExit $false
        Mock -ModuleName Test.HostRefresh Get-YurunaRunnerProtocolCapability { [pscustomobject]@{ Available = $false } }
        $declaration = @(Get-VirtualizationRepairRung -HostType host.macos.utm)
        Assert-False (@($declaration | Where-Object { $_.Name -eq 'reclaim' })[0].Available) 'an unqualified runner protocol keeps reclaim closed'
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm) -Rung $declaration
        foreach ($forbidden in @('resume-runner', 'gate:closed', 'stop-runner')) { Assert-False ($script:Log.Contains($forbidden)) "no $forbidden" }
        Assert-Equal 'partial' $result.verdict
        Assert-Equal 'start-runner' $result.operatorAction
        Assert-True (@($result.reasonCodes) -contains 'runner-restart-unqualified')
    }

    It 'never restarts a runner that needs the desktop session from a remote session' {
        New-TestScenario -HostType host.macos.utm -Outer Missing -CleanExit $false
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm) -Identity (New-TestIdentity -GuiAllowed $false)
        Assert-False ($script:Log.Contains('resume-runner'))
        Assert-Equal 'start-runner' $result.operatorAction
        Assert-True (@($result.reasonCodes) -contains 'no-session')
    }

    It 'leaves an armed runner obligation to the operator when a retry may no longer restart it' {
        New-TestScenario -Outer AliveOwned -ResumeOutcome failed
        $context = New-TestContext
        $first = Invoke-TestWorker -Context $context -Policy @{ tier = 'restart'; force = $true }
        Assert-Equal 'recovery-pending' (Read-YurunaHostRefreshRequest -RequestId $first.requestId)['state']
        New-TestScenario -Outer Missing -CleanExit $false
        $script:Scenario.Gate = @{ State = 'recovery-pending'; RequestId = $first.requestId; Generation = 'p' * 32 }
        $retryContext = $context.PSObject.Copy()
        $retryContext.HomeVerified = 'mismatch'
        $retry = Invoke-TestWorker -Context $retryContext -Mode Resume
        Assert-Equal $first.requestId $retry.requestId
        Assert-False ($script:Log.Contains('resume-runner')) 'an obligation armed earlier does not qualify the launch now'
        Assert-Equal 'start-runner' $retry.operatorAction
        Assert-True (@($retry.reasonCodes) -contains 'home-unverified')
        Assert-Equal 'armed' (@($retry.obligations | Where-Object { $_.id -eq 'runner' })[0].status)
        Assert-Equal 'recovery-pending' (Read-YurunaHostRefreshRequest -RequestId $first.requestId)['state']
    }
}

Describe 'the listener during convergence' {
    BeforeEach { Set-WorkerMock }

    It 'starts an enabled listener that is not running, and counts a start as a change' {
        New-TestScenario -Outer Missing -CleanExit $false -Server Missing
        $script:Scenario.ListenerEnabled = $true
        $script:Scenario.ListenerOutcome = 'started'
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-True ((Get-LogIndex 'listener') -ge 0 -and (Get-LogIndex 'listener') -lt (Get-LogIndex 'resume-runner')) 'the listener is brought back before the runner'
        Assert-True $result.mutated
        Assert-Equal 'repaired' $result.verdict
    }

    It 'starts a down listener even when nothing else in the attempt changed' {
        New-TestScenario -Outer Unknown -Server DeadOrRecycled
        $script:Scenario.ListenerEnabled = $true
        $script:Scenario.ListenerOutcome = 'started'
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-True ($script:Log.Contains('listener'))
        Assert-True $result.mutated
    }

    It 'leaves a listener it observed alive alone when nothing else changed' {
        New-TestScenario -Outer Unknown -Server AliveOwned
        $script:Scenario.ListenerEnabled = $true
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-False ($script:Log.Contains('listener'))
        Assert-False $result.mutated
    }
}

Describe 'hypervisor rungs on KVM' {
    BeforeEach { Set-WorkerMock }

    It 'reports still-unresponsive, changing nothing, when no rung applies to a timeout' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'timeout' }) -Outer AliveOwned
        $context = New-TestContext
        $result = Invoke-TestWorker -Context $context
        Assert-Equal 'still-unresponsive' $result.verdict
        Assert-Equal 2 $result.exitCode
        Assert-False $result.mutated
        Assert-False ($script:Log.Contains('start-service')) 'the start rung applies only to a stopped service'
        Assert-False ($script:Log.Contains('stop-runner')) 'no later restart rung needs the runner out of the way'
        Assert-Equal 'not-app-stopped' (@($result.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].reason)
        Assert-Equal 'completed' (Read-YurunaHostRefreshRequest -RequestId $result.requestId)['state']
        foreach ($rung in @($result.rungs | Where-Object { $_.outcome -eq 'skipped' })) { Assert-True ([bool]$rung.reason) "$($rung.name) records why it was skipped" }
    }

    It 'starts a positively stopped service with the captured dependent VMs, re-probes and releases the gate' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer AliveOwned `
            -Service @((New-TestServiceRow -Key caching-proxy -VMName yuruna-caching-proxy), (New-TestServiceRow -Key stash -VMName yuruna-stash))
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'repaired' $result.verdict
        Assert-Equal 'yuruna-caching-proxy,yuruna-stash' ($script:Captured.DependentVMName -join ',')
        Assert-True ((Get-LogIndex 'gate:closed') -lt (Get-LogIndex 'start-service'))
        Assert-True ($script:Log.Contains('gate:released')) 'nothing outstanding: the gate is released, never left closed'
        Assert-False ($script:Log.Contains('stop-runner'))
        $afterStart = $script:Log.IndexOf('start-service')
        Assert-True ($script:Log.IndexOf('probe', $afterStart) -gt $afterStart) 're-probed after the rung'
    }

    It 'skips the start rung on an elevation refusal, prints the command on the console only and asks for elevation' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned
        $script:Scenario.StartResult = [pscustomobject]@{ outcome = 'refused'; reason = 'elevation-refused'; layout = 'monolithic'
            actions = @([pscustomobject]@{ target = 'libvirtd.service'; reason = 'elevation-refused'; result = 'refused'; command = @('systemctl', '--no-ask-password', 'start', 'libvirtd.service') }) }
        $context = New-TestContext
        $runtimeBackup = @{ Present = (Test-Path Env:YURUNA_RUNTIME_DIR); Value = $env:YURUNA_RUNTIME_DIR }
        $env:YURUNA_RUNTIME_DIR = $context.RuntimeDir
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.OuterLog.psm1') -Global -DisableNameChecking
        try { $result = Invoke-TestWorker -Context $context } finally {
            if ($runtimeBackup.Present) { $env:YURUNA_RUNTIME_DIR = $runtimeBackup.Value } else { Remove-Item -LiteralPath Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        }
        Assert-Equal 'elevate' $result.operatorAction
        Assert-Equal 'skipped' (@($result.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].outcome)
        Assert-Equal 'still-unresponsive' $result.verdict
        $outer = Get-Content -Raw -LiteralPath (Join-Path $context.RuntimeDir 'outer.log')
        Assert-False ($outer.Contains('--no-ask-password')) 'a manual command never reaches the served outer.log'
    }

    It 'refuses every mutating rung while the repair lock or the home directory is unverified' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer DeadOrRecycled
        $result = Invoke-TestWorker -Context (New-TestContext -HomeVerified 'mismatch')
        Assert-False ($script:Log.Contains('start-service'))
        Assert-False ($script:Log.Contains('remove-record'))
        Assert-Equal 'home-unverified' (@($result.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].reason)
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned
        $unqualified = Invoke-TestWorker -Context (New-TestContext -LockQualified $false)
        Assert-Equal 'lock-unqualified' (@($unqualified.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].reason)
    }

    It 'skips a mutating rung when the runner gate cannot be closed' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned -GateWritable $false
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-False ($script:Log.Contains('start-service'))
        Assert-Equal 'gate-unavailable' (@($result.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].reason)
    }

    It 'hands every native-facing call a deadline no later than its phase, and stops climbing once the ladder is spent' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned
        $script:Scenario.ProbeDelayMs = 2200
        $budget = New-HostRefreshBudget -ExpiryTick ([Environment]::TickCount64 + 257500)
        $ladderExpiry = [long]$budget.TotalExpiryTick - 255000
        $result = Invoke-TestWorker -Context (New-TestContext) -Budget $budget
        Assert-True ($script:Captured.ProbeDeadline.Count -ge 1)
        Assert-True ([long]$script:Captured.ProbeDeadline[0].ExpiryTick -le $ladderExpiry) 'the first probe runs on the ladder deadline'
        foreach ($deadline in $script:Captured.ProbeDeadline) { Assert-True ([long]$deadline.ExpiryTick -le $budget.TotalExpiryTick - 15000) 'no call outlives the reporting reserve' }
        Assert-Equal 'deadline-exhausted' (@($result.rungs | Where-Object { $_.name -eq 'start-if-stopped' })[0].reason)
        Assert-False ($script:Log.Contains('start-service')) 'no rung starts with less than a second left'
        Assert-True (@($result.reasonCodes) -contains 'deadline-exhausted')
        Assert-Equal 2 $result.exitCode
    }

    It 'issues no probe at all when the ladder has less than a second left' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned
        $budget = New-HostRefreshBudget -ExpiryTick ([Environment]::TickCount64 + 255500)
        $result = Invoke-TestWorker -Context (New-TestContext) -Budget $budget
        Assert-Equal 'deadline-exhausted' $result.initialProbe.reason
        Assert-False ($script:Log.Contains('start-service'))
    }
}

Describe 'the macOS restart rung through the declaration seam' {
    BeforeEach { Set-WorkerMock }

    It 'captures, arms, reclaims, restarts UTM once without a hard stop, resumes each guest once, observes, then restarts the runner' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer AliveOwned -Inner AliveOwned `
            -Service @((New-TestServiceRow -Key caching-proxy -VMName yuruna-caching-proxy -Url 'http://192.168.64.2:3000'), (New-TestServiceRow -Key stash -VMName yuruna-stash))
        $context = New-TestContext -HostType host.macos.utm
        $result = Invoke-TestWorker -Context $context
        Assert-Equal 'repaired' $result.verdict
        Assert-Equal 0 $result.exitCode
        Assert-False $script:Captured.AllowHardStop 'a hard stop needs an explicit local request'
        $order = @('gate:closed', 'stop-runner', 'restart-utm', 'resume-vm', 'restore:observe', 'resume-runner')
        for ($i = 1; $i -lt $order.Count; $i++) {
            Assert-True ((Get-LogIndex $order[$i - 1]) -ge 0 -and (Get-LogIndex $order[$i - 1]) -lt (Get-LogIndex $order[$i])) "$($order[$i - 1]) before $($order[$i])"
        }
        Assert-Equal 1 @($script:Log | Where-Object { $_ -eq 'resume-vm' }).Count 'each guest gets one resume'
        Assert-False ($script:Log.Contains('restore:start')) 'macOS never falls back to a cold start'
        Assert-Equal 'yuruna-caching-proxy,yuruna-stash' ($script:Captured.ResumeNames -join ',')
        Assert-True ($script:Log.Contains('probe:corroborate'))
        $obligations = @{}
        foreach ($row in $result.obligations) { $obligations[$row.id] = $row.status }
        foreach ($id in @('service:caching-proxy', 'endpoint:caching-proxy', 'service:stash', 'runner')) { Assert-Equal 'discharged' $obligations[$id] $id }
        Assert-Equal 'completed' (Read-YurunaHostRefreshRequest -RequestId $result.requestId)['state']
    }

    It 'passes a hard stop only for a local request that asked for it' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $null = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm) -Policy @{ tier = 'restart'; allowHardStop = $true }
        Assert-True $script:Captured.AllowHardStop
    }

    It 'refuses with the grant-automation action and no disruption on an Automation denial' {
        New-TestScenario -HostType host.macos.utm -Probe @(@{ State = 'Undetermined'; Reason = 'permission-denied' }) -Outer AliveOwned
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-Equal 'refused' $result.verdict
        Assert-Equal 1 $result.exitCode
        Assert-Equal 'grant-automation' $result.operatorAction
        Assert-Equal 'Open the Automation privacy pane' (@($result.operatorInstruction) -join '')
        foreach ($forbidden in @('stop-runner', 'restart-utm', 'resume-vm')) { Assert-False ($script:Log.Contains($forbidden)) $forbidden }
    }

    It 'skips every rung that needs the desktop session from a remote session' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout) -Outer AliveOwned -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm) -Identity (New-TestIdentity -GuiAllowed $false)
        Assert-Equal 'no-session' (@($result.rungs | Where-Object { $_.name -eq 'restart-if-hung' })[0].reason)
        Assert-Equal 'no-session' (@($result.rungs | Where-Object { $_.name -eq 'reclaim' })[0].reason)
        Assert-False ($script:Log.Contains('restart-utm'))
    }

    It 'refuses the restart when the service locks are not held, and still reclaims' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout) -Outer AliveOwned -ServiceLocksHeld $false -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-True ($script:Log.Contains('stop-runner'))
        Assert-False ($script:Log.Contains('restart-utm'))
        Assert-Equal 'service-locks-unavailable' (@($result.rungs | Where-Object { $_.name -eq 'restart-if-hung' })[0].reason)
    }

    It 'refuses the restart while the service set is unresolved, and while the runner is not quiescent' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout) -Outer Missing -CleanExit $true -ServicesSatisfied $false -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $unresolved = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-Equal 'service-set-unresolved' (@($unresolved.rungs | Where-Object { $_.name -eq 'restart-if-hung' })[0].reason)
        New-TestScenario -HostType host.macos.utm -Probe @($timeout) -Outer Missing -CleanExit $true -Quiescent $false -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $busy = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-Equal 'runner-not-quiescent' (@($busy.rungs | Where-Object { $_.name -eq 'restart-if-hung' })[0].reason)
        Assert-False ($script:Log.Contains('restart-utm'))
    }

    It 'still converges in finally after the restart throws, and leaves the request recovery-pending' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $false }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.RestartThrows = $true
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-True (@($result.reasonCodes) -contains 'execution-error')
        Assert-NotNull $result.finalProbe 'convergence ran and took a final probe'
        Assert-False ($script:Log.Contains('resume-vm')) 'nothing is resumed into an unresponsive hypervisor'
        Assert-Equal 'recovery-pending' (Read-YurunaHostRefreshRequest -RequestId $result.requestId)['state']
        Assert-Equal 'resume-request' $result.operatorAction
        Assert-True ($script:Log.Contains('gate:recovery-pending')) 'an outstanding obligation leaves the gate recovery-pending, never closed'
    }

    It 'disposes a service a newer operator stop intent covers instead of resuming it' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $true `
            -Service @((New-TestServiceRow -Key stash -VMName yuruna-stash), (New-TestServiceRow -Key caching-proxy -VMName yuruna-caching-proxy))
        $script:Scenario.Intent['stash'] = [pscustomobject]@{ DesiredState = 'stopped'; Generation = 7 }
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-Equal 'disposed' (@($result.obligations | Where-Object { $_.id -eq 'service:stash' })[0].status)
        Assert-Equal 'yuruna-caching-proxy' ($script:Captured.ResumeNames -join ',')
        Assert-True (@($result.reasonCodes) -contains 'superseded-by-operator-intent')
    }

    It 'keeps writing under its own attempt after disposing its only service, and still restarts the runner' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $false `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.Intent['stash'] = [pscustomobject]@{ DesiredState = 'stopped'; Generation = 7 }
        $result = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm)
        Assert-Equal 'disposed' (@($result.obligations | Where-Object { $_.id -eq 'service:stash' })[0].status)
        Assert-True ($script:Log.Contains('resume-runner')) 'the runner obligation still arms after the disposition'
        Assert-False (@($result.reasonCodes) -contains 'recovery-record-unwritable')
        Assert-Equal 'discharged' (@($result.obligations | Where-Object { $_.id -eq 'runner' })[0].status)
        Assert-Equal 'repaired' $result.verdict
        $request = Read-YurunaHostRefreshRequest -RequestId $result.requestId
        Assert-Equal 'completed' $request['state']
        Assert-Equal 'repaired' $request['verdict'] 'the worker, not the disposition, closed the request'
    }
}

Describe 'refusals and failures around the attempt' {
    BeforeEach { Set-WorkerMock }

    It 'refuses before any mutation when the recovery record cannot be saved' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer AliveOwned
        Mock -ModuleName Test.HostRefresh Save-HostRefreshRecoveryRecord { [pscustomobject]@{ Saved = $false; Durable = $false; Reason = 'io-error'; FirstCapture = $false } }
        $result = Invoke-TestWorker -Context (New-TestContext)
        Assert-Equal 'refused' $result.verdict
        Assert-Equal 1 $result.exitCode
        Assert-False ($script:Log.Contains('start-service'))
        Assert-False ($script:Log.Contains('gate:closed'))
    }

    It 'completes the repair with reporting degraded when progress cannot be written' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer AliveOwned
        $context = New-TestContext -PublicStatePath (Join-Path (New-ScratchDir) 'missing/host-refresh.state.json')
        $result = Invoke-TestWorker -Context $context
        Assert-Equal 'repaired' $result.verdict
        Assert-True $result.reportDegraded
    }

    It 'downgrades a success to partial when the journal cannot record it, and still releases the lock' {
        New-TestScenario -Outer AliveOwned
        $context = New-TestContext
        Mock -ModuleName Test.HostRefresh Complete-HostRefreshAttempt { [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = 'io-error' } }
        $result = Invoke-TestWorker -Context $context
        Assert-Equal 'partial' $result.verdict
        Assert-True (@($result.reasonCodes) -contains 'journal-unwritable')
        $lock = Enter-YurunaSingleFlightLock -Path $context.LifetimeLockPath -WaitMilliseconds 1000
        try { Assert-True $lock.Held 'the lifetime lock was released' } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'refuses with lock-busy while another repair holds the lifetime lock, writing nothing' {
        New-TestScenario -Outer AliveOwned
        $context = New-TestContext
        $held = Enter-YurunaSingleFlightLock -Path $context.LifetimeLockPath -Rank (Get-YurunaLockRank -Name HostOperation)
        try {
            $result = Invoke-TestWorker -Context $context
            Assert-Equal 'refused' $result.verdict
            Assert-True (@($result.reasonCodes) -contains 'lock-busy')
            Assert-Equal 'absent' (Read-HostRefreshJournal).Status
        } finally { Exit-YurunaSingleFlightLock -Lock $held }
    }

    It 'closes a queued request as refused when the launched worker''s identity is refused' {
        New-TestScenario
        $context = New-TestContext
        $id = '4242aaaa-0000-4000-8000-00000000000a'
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $context.RuntimeDir -HostType host.ubuntu.kvm -Confirm:$false
        $result = Invoke-TestWorker -Context $context -Mode Claim -RequestId $id -Identity (New-TestIdentity -Allowed $false -Reason 'runtime-owner-mismatch')
        Assert-Equal 'refused' $result.verdict
        $request = Read-YurunaHostRefreshRequest -RequestId $id
        Assert-Equal 'refused' $request['state']
        Assert-True (@($request['reasonCodes']) -contains 'runtime-owner-mismatch')
    }

    It 'writes no private state at all for root or an identity it cannot name, leaving the queued request for a retry' {
        foreach ($reason in @('root-refused', 'identity-unknown')) {
            New-TestScenario
            $context = New-TestContext
            $id = New-YurunaHostRefreshRequestId
            $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $context.RuntimeDir -HostType host.ubuntu.kvm -Confirm:$false
            $before = (Read-HostRefreshJournal).Generation
            $result = Invoke-TestWorker -Context $context -Mode Claim -RequestId $id -Identity (New-TestIdentity -Allowed $false -Reason $reason)
            Assert-Equal 'refused' $result.verdict $reason
            Assert-True (@($result.reasonCodes) -contains $reason)
            Assert-Equal 'queued' (Read-YurunaHostRefreshRequest -RequestId $id)['state'] "$reason leaves the request queued"
            Assert-Equal $before (Read-HostRefreshJournal).Generation "$reason wrote nothing to the journal"
            Assert-False ($script:Log.Contains('probe')) "$reason probes nothing"
        }
    }
}

Describe 'channels, retries and dispositions' {
    BeforeEach { Set-WorkerMock }

    It 'takes a claimed request''s policy from the journal, never from the caller, and grants service selection only locally' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $context = New-TestContext -HostType host.macos.utm
        $id = '4242aaaa-0000-4000-8000-00000000000b'
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $context.RuntimeDir -HostType host.macos.utm -Confirm:$false
        $result = Invoke-TestWorker -Context $context -Mode Claim -RequestId $id
        Assert-Equal $id $result.requestId
        Assert-False $script:Captured.AllowOperatorSelection 'a listener request carries no service selection'
        Assert-False $script:Captured.AllowHardStop
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $null = Invoke-TestWorker -Context (New-TestContext -HostType host.macos.utm) -Policy @{ tier = 'restart'; restoreServiceVmName = @('yuruna-stash') }
        Assert-True $script:Captured.AllowOperatorSelection
        Assert-Equal 'yuruna-stash' ($script:Captured.RestoreServiceVmName -join ',')
    }

    It 'preserves the caller outer on the automatic channel: parked, never restarted, with a resident-outer handoff' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, $timeout, @{ State = 'Responsive'; Reason = 'responsive' }) -Outer AliveOwned -Inner AliveOwned `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $context = New-TestContext -HostType host.macos.utm
        $id = '4242aaaa-0000-4000-8000-00000000000c'
        $null = Request-HostRefreshAdmission -RequestId $id -Channel automatic -Tier restart -RuntimeDir $context.RuntimeDir -HostType host.macos.utm `
            -Context @{ callerOuter = @{ pid = 4101; startTimeUnixMs = 1000 } } -Confirm:$false
        $result = Invoke-TestWorker -Context $context -Mode Claim -RequestId $id
        Assert-True $script:Captured.PreserveOuter
        Assert-False ($script:Log.Contains('resume-runner')) 'a caller outer is never restarted'
        Assert-True ($script:Log.Contains('handoff:resident-outer'))
        Assert-Equal 4101 $script:Captured.DesignatedOuter.Pid
        Assert-Equal 'caller-parked' $result.runnerReadiness
        Assert-Equal 'resident-outer' $result.handoff['purpose']
        Assert-False ($script:Log.Contains('gate:released')) 'the handoff owns the gate'
        $stored = Get-HostRefreshResult -RequestId $id
        Assert-Equal 'caller-parked' $stored.RunnerReadiness
        Assert-Equal 'Responsive' $stored.FinalProbeState
    }

    It 'resumes a recovery-pending request as restoration only, with no new disruption' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $false }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.RestartThrows = $true
        $context = New-TestContext -HostType host.macos.utm
        $first = Invoke-TestWorker -Context $context
        Assert-Equal 'recovery-pending' (Read-YurunaHostRefreshRequest -RequestId $first.requestId)['state']
        New-TestScenario -HostType host.macos.utm -Probe @(@{ State = 'Responsive'; Reason = 'responsive' }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.Gate = @{ State = 'recovery-pending'; RequestId = $first.requestId; Generation = 'p' * 32 }
        $second = Invoke-TestWorker -Context $context -Mode Resume
        Assert-Equal $first.requestId $second.requestId
        Assert-Equal 2 $second.attempt
        Assert-False ($script:Log.Contains('restart-utm'))
        Assert-False ($script:Log.Contains('stop-runner'))
        Assert-True ($script:Log.Contains('restore:observe'))
        Assert-Equal 'completed' (Read-YurunaHostRefreshRequest -RequestId $first.requestId)['state']
        Assert-Equal 0 $second.exitCode
    }

    It 'abandons a request past three attempts and keeps what it owes' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $false }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.RestartThrows = $true
        $context = New-TestContext -HostType host.macos.utm
        $first = Invoke-TestWorker -Context $context
        foreach ($i in 2..3) {
            New-TestScenario -HostType host.macos.utm -Probe @(@{ State = 'Unresponsive'; Reason = 'timeout' }) -Outer Missing -CleanExit $true
            $null = Invoke-TestWorker -Context $context -Mode Resume
        }
        New-TestScenario -HostType host.macos.utm -Probe @(@{ State = 'Unresponsive'; Reason = 'timeout' }) -Outer Missing -CleanExit $true
        $last = Invoke-TestWorker -Context $context -Mode Resume
        Assert-Equal 'abandoned' $last.verdict
        Assert-Equal 2 $last.exitCode
        Assert-Equal 'dispose-obligations' $last.operatorAction
        $request = Read-YurunaHostRefreshRequest -RequestId $first.requestId
        Assert-Equal 'abandoned' $request['state']
        Assert-Equal 'armed' (@($request['obligations'] | Where-Object { $_['id'] -eq 'service:stash' })[0]['status'])
    }

    It 'records an audited disposition, releases a recovery-pending gate, and refuses an unknown obligation' {
        $timeout = @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $true }
        New-TestScenario -HostType host.macos.utm -Probe @($timeout, @{ State = 'Unresponsive'; Reason = 'timeout'; Corroborated = $false }) -Outer Missing -CleanExit $true `
            -Service @(New-TestServiceRow -Key stash -VMName yuruna-stash)
        $script:Scenario.RestartThrows = $true
        $context = New-TestContext -HostType host.macos.utm
        $first = Invoke-TestWorker -Context $context
        $script:Scenario.Gate = @{ State = 'recovery-pending'; RequestId = $first.requestId; Generation = 'p' * 32 }
        $unknown = Invoke-TestWorker -Context $context -Mode Dispose -DisposeObligation @('listener')
        Assert-Equal 'refused' $unknown.verdict
        $disposed = Invoke-TestWorker -Context $context -Mode Dispose -DisposeObligation @('service:stash')
        Assert-Equal 'disposed' $disposed.verdict
        Assert-Equal 0 $disposed.exitCode
        Assert-True ($script:Log.Contains('gate:released'))
        $request = Read-YurunaHostRefreshRequest -RequestId $first.requestId
        Assert-Equal 'completed' $request['state']
        Assert-Equal 'tester' (@($request['obligations'] | Where-Object { $_['id'] -eq 'service:stash' })[0]['disposedBy'])
    }
}

Describe 'preview' {
    BeforeEach { Set-WorkerMock }

    It 'plans without locking, writing or reserving anything' {
        New-TestScenario -Probe @(@{ State = 'Unresponsive'; Reason = 'app-stopped' }) -Outer DeadOrRecycled
        $dir = New-ScratchDir
        $homeDir = Join-Path $dir 'home'
        $null = New-Item -ItemType Directory -Path $homeDir
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $homeDir
        $runtime = Join-Path $dir 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime
        $context = [pscustomobject]@{
            Resolved = $true; Reason = 'ok'; HostType = 'host.ubuntu.kvm'; RepoRoot = $script:RepoRoot; RuntimeDir = $runtime; RuntimeSource = 'environment'
            ConfigPath = '/nonexistent.yml'; ConfigSource = 'explicit'; JournalPath = $null; LifetimeLockPath = $null; PublicStatePath = (Join-Path $runtime 'host-refresh.state.json')
            HomeVerified = 'verified'; LockQualified = $true; Observation = [string[]]@('private-root-absent')
        }
        $result = Invoke-TestWorker -Context $context -Preview
        Assert-Equal 'preview' $result.verdict
        Assert-Equal 0 $result.exitCode
        Assert-Equal 'preview' $result.plan.phase
        Assert-Equal 'Yuruna.HostRefreshPreview' $result.plan.PSObject.TypeNames[0]
        Assert-True ($script:Log.Contains('start-service:whatif')) 'the KVM start rung is predicted by its own read-only preview'
        foreach ($forbidden in @('gate:closed', 'stop-runner', 'remove-record', 'resume-runner', 'service-locks')) { Assert-False ($script:Log.Contains($forbidden)) $forbidden }
        Assert-False ($script:Log.Contains('probe:corroborate')) 'a preview never waits out a dialog window'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $homeDir -Force).Count 'no private root was created'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $runtime -Force).Count 'nothing was published'
        $reclaim = @($result.plan.rungs | Where-Object { $_.name -eq 'reclaim' })[0]
        Assert-True $reclaim.wouldConsider
        Assert-Equal 'dead-runner-records' $reclaim.predicted
    }
}
