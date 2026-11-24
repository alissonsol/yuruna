<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42d5eca1-96fc-489c-8979-a63cfc5af2f5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload session runtime
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

# The runtime side of a workload authoring session: the one refusal builder of
# the worker, the engine load, session start and end with the one-shot lease
# and the owner cycle, ownership checks, and the replay of a sequence through
# a nested Debug-TestSequence.ps1 child. Every engine, planner and status
# function is called by name after Import-WorkloadEngineModule has loaded it;
# importing the engine or the planner from here would replace the engine
# module under a running session.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -DisableNameChecking

# The path bundle of the engine load; set once per worker process.
$script:WorkloadEnginePaths = $null

$script:WorkloadGuestKeyPattern = '^guest\.[a-z0-9]+(?:[.-][a-z0-9]+)*$'
$script:WorkloadVmNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
$script:WorkloadSequencePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$'
$script:WorkloadVariableKeyPattern = '^[A-Za-z_][A-Za-z0-9_]{0,63}$'

function New-WorkloadRefusal {
    <#
    .SYNOPSIS
        The one refusal shape of the worker: ok false, a stable code and its rendered message.
    .DESCRIPTION
        Every call site passes the code and its catalog key as quoted literals,
        so the code registry and the slice map find both.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a value; changes nothing.')]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{}
    )
    return [ordered]@{
        ok    = $false
        error = [ordered]@{
            code    = $Code
            message = (Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments)
        }
    }
}

function Import-WorkloadEngineModule {
    <#
    .SYNOPSIS
        Loads the engine once per worker process and returns the path bundle.
    .DESCRIPTION
        The order matters. The secret filter is switched on and an inherited
        transcript directory is dropped before the engine loads, so no engine
        output escapes the filter. The planner loads after the engine, so the
        first Invoke-Sequence call does not replace the engine module. The verb
        registry is initialized once, before any session holds state in the
        engine. The worker is an owner and never a nested run, and nothing
        below an MCP server may prompt. A second call returns the stored bundle.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string]$ConfigPath)
    if ($null -ne $script:WorkloadEnginePaths) { return $script:WorkloadEnginePaths }
    $env:YURUNA_NONINTERACTIVE = '1'
    Remove-Item -LiteralPath Env:\YURUNA_CYCLE_CONTEXT -ErrorAction SilentlyContinue
    $env:YURUNA_SECRET_FILTER = '1'
    $env:YURUNA_CHILD_TRANSCRIPT_DIR = $null
    Import-Module (Join-Path $PSScriptRoot 'Test.Prelude.psm1') -Global
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
    $env:YURUNA_CONFIG_PATH = $paths.ConfigPath
    $savedVerbose = $global:VerbosePreference
    try {
        $global:VerbosePreference = 'SilentlyContinue'
        Initialize-YurunaEntryPointModuleSet -For Sequence -ModulesDir $paths.ModulesDir
        $logModule = Join-Path $paths.RepoRoot 'automation/Yuruna.Log.psm1'
        if (Test-Path -LiteralPath $logModule -PathType Leaf) { Import-Module $logModule -Global -Force }
        Import-Module (Join-Path $paths.ModulesDir 'Test.SequenceRunner.psm1') -Global -Force
        Import-Module (Join-Path $paths.ModulesDir 'Test.Orchestrator.psm1') -Global -Force
    } finally {
        $global:VerbosePreference = $savedVerbose
    }
    Initialize-SequenceEngineRegistry -ModulesDir $paths.ModulesDir -Confirm:$false
    Import-Module (Join-Path $paths.ModulesDir 'Test.Ssh.psm1') -Global
    $script:WorkloadEnginePaths = $paths
    return $paths
}

function Test-WorkloadPatternValue {
    # Private: a value matches a pattern case-sensitively and holds no line feed.
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Pattern)
    if ($null -eq $Value -or $Value.Contains("`n")) { return $false }
    return ($Value -cmatch $Pattern)
}

function Get-WorkloadStrippedSequenceName {
    # Private: a sequence name without a trailing .yml or .yaml.
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Sequence)
    if ([string]::IsNullOrEmpty($Sequence)) { return '' }
    if ($Sequence.EndsWith('.yaml', [StringComparison]::Ordinal)) { return $Sequence.Substring(0, $Sequence.Length - 5) }
    if ($Sequence.EndsWith('.yml', [StringComparison]::Ordinal)) { return $Sequence.Substring(0, $Sequence.Length - 4) }
    return $Sequence
}

function Test-WorkloadSessionArgument {
    <#
    .SYNOPSIS
        Checks the arguments of a session start or a replay again; returns $null or a refusal.
    .DESCRIPTION
        The front end's schemas bound the same arguments, but a .NET pattern's
        final $ also matches before a trailing line feed, so a value with a line
        feed passes there and is refused here. Only the arguments given are
        checked. Patterns are matched case-sensitively.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [AllowEmptyString()][string]$GuestKey,
        [AllowEmptyString()][string]$VMName,
        [AllowEmptyString()][AllowNull()][string]$Sequence,
        [AllowNull()][System.Collections.IDictionary]$Variables
    )
    if ($PSBoundParameters.ContainsKey('GuestKey') -and
        (-not (Test-WorkloadPatternValue -Value $GuestKey -Pattern $script:WorkloadGuestKeyPattern) -or $GuestKey.Length -gt 64)) {
        return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                tool = $Tool; name = 'guestKey'; pattern = '^guest\.[a-z0-9]+(?:[.-][a-z0-9]+)*$, at most 64 characters' })
    }
    if ($PSBoundParameters.ContainsKey('VMName') -and -not (Test-WorkloadPatternValue -Value $VMName -Pattern $script:WorkloadVmNamePattern)) {
        return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                tool = $Tool; name = 'vmName'; pattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' })
    }
    if ($PSBoundParameters.ContainsKey('Sequence') -and -not [string]::IsNullOrEmpty($Sequence)) {
        $stripped = Get-WorkloadStrippedSequenceName -Sequence $Sequence
        if ($Sequence.Contains("`n") -or -not (Test-WorkloadPatternValue -Value $stripped -Pattern $script:WorkloadSequencePattern)) {
            return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                    tool = $Tool; name = 'sequence'; pattern = 'empty, or ^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$ after a trailing .yml or .yaml is removed' })
        }
    }
    if ($null -ne $Variables) {
        if ($Variables.Count -gt 64) {
            return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                    tool = $Tool; name = 'variables'; pattern = 'at most 64 entries' })
        }
        foreach ($key in @($Variables.Keys)) {
            $keyText = [string]$key
            if (-not (Test-WorkloadPatternValue -Value $keyText -Pattern $script:WorkloadVariableKeyPattern)) {
                return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                        tool = $Tool; name = "variables.$keyText"; pattern = '^[A-Za-z_][A-Za-z0-9_]{0,63}$' })
            }
            $item = $Variables[$key]
            $valid = ($item -is [string] -and $item.Length -le 4096) -or $item -is [int] -or $item -is [long] -or
                $item -is [double] -or $item -is [decimal] -or $item -is [bool]
            if (-not $valid) {
                return (New-WorkloadRefusal -Code 'workload_argument_invalid' -Key 'runner.workload_argument_invalid' -Arguments @{
                        tool = $Tool; name = "variables.$keyText"; pattern = 'a string of at most 4096 characters, a number or a boolean' })
            }
        }
    }
    return $null
}

function Exit-WorkloadSessionLease {
    # Private: give back the one-shot lease this process holds, for a refused start.
    $null = Exit-YurunaOneShotLease -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
}

function Start-WorkloadSessionRuntime {
    <#
    .SYNOPSIS
        Claims the runtime, attaches to a running VM and opens the owner cycle of a session.
    .DESCRIPTION
        Returns ok with the session hashtable and the other running VMs, or a
        refusal. It attaches only to a VM that is running, runs no admission
        sweep and stops no VM. The owner cycle is registered after every check
        that can refuse, so a refused start never resets status.json or opens a
        cycle folder. Every refusal after the claim gives the lease back.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Claims the one-shot lease and registers the owner cycle of a session the caller asked to start.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cycle-folder handle Start-LogFile sets for the owner cycle this session registers.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$GuestKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$VMName,
        [AllowEmptyString()][AllowNull()][string]$Sequence = '',
        [AllowNull()][System.Collections.IDictionary]$Variables = @{}
    )
    $tool = 'workload_session_start'
    $argumentRefusal = Test-WorkloadSessionArgument -Tool $tool -GuestKey $GuestKey -VMName $VMName -Sequence $Sequence -Variables $Variables
    if ($null -ne $argumentRefusal) { return $argumentRefusal }
    $Sequence = Get-WorkloadStrippedSequenceName -Sequence $Sequence

    $hostType = Get-HostType
    if ($null -eq $hostType) {
        return (New-WorkloadRefusal -Code 'workload_host_unsupported' -Key 'runner.workload_host_unsupported' -Arguments @{ tool = $tool })
    }
    if (-not (Test-GuestFolder -RepoRoot $Paths.RepoRoot -HostType $hostType -GuestKey $GuestKey)) {
        $guestFolder = Join-Path $Paths.RepoRoot (Join-Path (Get-HostFolder $hostType) $GuestKey)
        return (New-WorkloadRefusal -Code 'workload_guest_unknown' -Key 'runner.workload_guest_unknown' -Arguments @{
                tool = $tool; guestKey = $GuestKey; hostType = $hostType; folder = $guestFolder })
    }
    if ((Test-ElevationRequired -HostType $hostType) -and -not (Test-IsAdministrator)) {
        return (New-WorkloadRefusal -Code 'workload_elevation_required' -Key 'runner.workload_elevation_required' -Arguments @{ tool = $tool; hostType = $hostType })
    }
    # The worker cannot relaunch itself under sg: its pipes to the front end
    # belong to this process.
    if ((Test-LibvirtGroupReExecNeeded -HostType $hostType).Needed) {
        return (New-WorkloadRefusal -Code 'workload_libvirt_group_missing' -Key 'runner.workload_libvirt_group_missing' -Arguments @{ tool = $tool })
    }
    $config = Read-TestConfig -Path $Paths.ConfigPath
    if ($null -eq $config) {
        return (New-WorkloadRefusal -Code 'workload_config_unreadable' -Key 'runner.workload_config_unreadable' -Arguments @{ tool = $tool; configPath = [string]$Paths.ConfigPath })
    }
    try {
        $null = Initialize-YurunaHost -RepoRoot $Paths.RepoRoot -HostType $hostType
    } catch {
        return (New-WorkloadRefusal -Code 'workload_host_driver_failed' -Key 'runner.workload_host_driver_failed' -Arguments @{ tool = $tool; message = $_.Exception.Message })
    }
    try {
        $w = $null
        $e = $null
        $verdict = Get-HostConditionVerdict -HostType $hostType -WarningVariable w -ErrorVariable e 3>$null 2>$null
        if (-not $verdict.Passed) {
            $lines = [Collections.Generic.List[string]]::new()
            $lines.Add([string]$verdict.Detail)
            foreach ($record in @($w) + @($e)) { if ($null -ne $record) { $lines.Add([string]$record) } }
            return (New-WorkloadRefusal -Code 'workload_host_not_ready' -Key 'runner.workload_host_not_ready' -Arguments @{
                    tool = $tool; condition = [string]$verdict.Condition; detail = ($lines -join "`n") })
        }
    } catch {
        return (New-WorkloadRefusal -Code 'workload_host_not_ready' -Key 'runner.workload_host_not_ready' -Arguments @{
                tool = $tool; condition = 'unnamed'; detail = $_.Exception.Message })
    }

    $lease = $null
    $claimed = Initialize-YurunaOneShotEntryPoint -CallerName 'Invoke-WorkloadSession' -Confirm:$false -InformationVariable lease 6>$null
    if (-not $claimed) {
        $leaseLines = @($lease | ForEach-Object { [string]$_.MessageData })
        return (New-WorkloadRefusal -Code 'workload_runtime_owned' -Key 'runner.workload_runtime_owned' -Arguments @{ tool = $tool; detail = ($leaseLines -join "`n") })
    }

    $session = $null
    try {
        # Without its start record other processes read the lease as Unknown,
        # and Start-TestRunner.ps1 starts over an Unknown lease.
        $leaseStart = Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.start'
        if (-not (Test-Path -LiteralPath $leaseStart -PathType Leaf)) {
            Exit-WorkloadSessionLease
            return (New-WorkloadRefusal -Code 'workload_lease_incomplete' -Key 'runner.workload_lease_incomplete' -Arguments @{
                    tool = $tool; leasePath = (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid') })
        }

        $vmState = [string](Get-VMState -VMName $VMName)
        if ($vmState -eq 'absent') {
            Exit-WorkloadSessionLease
            return (New-WorkloadRefusal -Code 'workload_vm_absent' -Key 'runner.workload_vm_absent' -Arguments @{ tool = $tool; vmName = $VMName })
        }
        if ($vmState -eq 'stopped') {
            Exit-WorkloadSessionLease
            return (New-WorkloadRefusal -Code 'workload_vm_stopped' -Key 'runner.workload_vm_stopped' -Arguments @{ tool = $tool; vmName = $VMName })
        }
        if ($vmState -ne 'running') {
            Exit-WorkloadSessionLease
            return (New-WorkloadRefusal -Code 'workload_vm_unknown' -Key 'runner.workload_vm_unknown' -Arguments @{ tool = $tool; vmName = $VMName })
        }

        $osKey = $GuestKey.Substring('guest.'.Length)
        $path = ''
        $doc = $null
        if ($Sequence) {
            $resolved = $null
            try {
                $resolved = Resolve-SequencePath -SequencesDir $Paths.SequencesDir -Name $Sequence -HostType $hostType -RepoRoot $Paths.RepoRoot
            } catch {
                Exit-WorkloadSessionLease
                return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
            }
            if ($null -eq $resolved) {
                $searchList = Format-SequenceSearchList -Item (Get-SequenceSearchPath -SequencesDir $Paths.SequencesDir -Name $Sequence -HostType $hostType -RepoRoot $Paths.RepoRoot)
                Exit-WorkloadSessionLease
                return (New-WorkloadRefusal -Code 'workload_sequence_not_found' -Key 'runner.workload_sequence_not_found' -Arguments @{ tool = $tool; sequence = $Sequence; list = [string]$searchList })
            }
            $path = [string]$resolved
            try {
                $doc = Read-SequenceFile -Path $path
            } catch {
                Exit-WorkloadSessionLease
                return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
            }
            if (-not ($doc -is [System.Collections.IDictionary] -and $doc.Contains('baseline') -and $doc.Contains('steps') -and
                    $doc['baseline'] -is [System.Collections.IDictionary] -and $doc['baseline'].Contains($osKey))) {
                Exit-WorkloadSessionLease
                return (New-WorkloadRefusal -Code 'workload_sequence_not_guest' -Key 'runner.workload_sequence_not_guest' -Arguments @{ tool = $tool; sequence = $Sequence; osKey = $osKey })
            }
        }

        $sourceVariables = [ordered]@{}
        if ($null -ne $doc -and $doc.Contains('variables') -and $doc['variables'] -is [System.Collections.IDictionary]) {
            foreach ($key in @($doc['variables'].Keys)) { $sourceVariables[$key] = $doc['variables'][$key] }
        }
        $runtimeDir = $env:YURUNA_RUNTIME_DIR
        $session = @{
            SessionId          = $SessionId
            Folder             = $Folder
            HostType           = $hostType
            GuestKey           = $GuestKey
            OsKey              = $osKey
            VMName             = $VMName
            RepoRoot           = $Paths.RepoRoot
            TestRoot           = $Paths.TestRoot
            SequencesDir       = $Paths.SequencesDir
            ConfigPath         = $Paths.ConfigPath
            Config             = $config
            RuntimeDir         = $runtimeDir
            StatusPath         = (Join-Path $runtimeDir 'status.json')
            CycleStartUtc      = $null
            CycleNumber        = $null
            CycleFolder        = $null
            SourceSequence     = $Sequence
            SourceSequencePath = $path
            SourceVariables    = $sourceVariables
            OverrideVariables  = $(if ($null -ne $Variables) { $Variables } else { @{} })
            State              = 'attached'
            DetachReason       = ''
            ReplayCounter      = 0
            ActiveReplay       = $null
        }

        $scopeArguments = @{ Session = $session }
        if ($path) { $scopeArguments.Sequence = $path }
        if ($null -ne $Variables -and $Variables.Count -gt 0) { $scopeArguments.Variables = $Variables }
        $scope = $null
        try {
            $scope = Initialize-WorkloadVariableScope @scopeArguments
        } catch {
            Exit-WorkloadSessionLease
            return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
        }
        if ($scope -is [System.Collections.IDictionary] -and $scope.Contains('ok') -and $scope['ok'] -eq $false) {
            Exit-WorkloadSessionLease
            return $scope
        }

        $null = Clear-StaleControlState -Scope Startup -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false

        $env:YURUNA_CYCLE_GENERATION = New-CycleGeneration
        $registration = Register-StandaloneCycle -StatusFilePath $session.StatusPath -HostType $hostType -Config $config `
            -RepoRoot $Paths.RepoRoot -TestRoot $Paths.TestRoot -GuestList @($GuestKey) -StepNames @('Session')
        $session.CycleStartUtc = $registration.CycleStartUtc
        $session.CycleNumber = $registration.CycleNumber
        $session.CycleFolder = [string]$global:__YurunaCycleFolder
        Set-GuestVMName -GuestKey $GuestKey -VMName $VMName -Confirm:$false
        Set-GuestTopLevel -GuestKey $GuestKey -TopLevel 'workload-session' -Confirm:$false
        Set-GuestStatus -GuestKey $GuestKey -Status 'running' -Confirm:$false
        Set-StepStatus -GuestKey $GuestKey -StepName 'Session' -Status 'running' -Confirm:$false

        # The sweep stays in the replay child, which runs admission with the
        # attached VM as the exception; session start only reports.
        $admission = Get-VmAdmission -ExceptVmName $VMName -MaxProbes 1 -ProbeDelaySeconds 0
        $others = [string[]]@($admission.Occupants | Where-Object { $_ } | ForEach-Object { [string]$_ })
        return [ordered]@{ ok = $true; Session = $session; OtherRunningVms = $others }
    } catch {
        $startError = $_.Exception.Message
        if ($null -ne $session -and $session.CycleFolder) {
            $null = Stop-WorkloadSessionRuntime -Session $session -Reason 'error'
        } else {
            Exit-WorkloadSessionLease
        }
        return (New-WorkloadRefusal -Code 'workload_start_failed' -Key 'runner.workload_start_failed' -Arguments @{ tool = $tool; message = $startError })
    }
}

function Test-WorkloadSessionOwnership {
    <#
    .SYNOPSIS
        Whether this worker still holds the runtime its session claimed.
    .DESCRIPTION
        The lease has no heartbeat, and Start-TestRunner.ps1 starts over a
        lease it reads as Unknown, so a session checks before it drives the VM
        that its lease file still names this process and that no runner is up.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Session)
    $pidFile = Join-Path ([string]$Session.RuntimeDir) 'oneshot.pid'
    $text = $null
    try {
        $text = [IO.File]::ReadAllText($pidFile)
    } catch {
        Write-Verbose "The lease file '$pidFile' cannot be read: $($_.Exception.Message)"
        return @{ Owned = $false; Reason = 'lease-missing' }
    }
    if ($text.Trim() -ne "$PID") { return @{ Owned = $false; Reason = 'lease-replaced' } }
    $runner = Get-RunnerInstanceState -RunnerPidFile (Join-Path ([string]$Session.RuntimeDir) 'runner.pid') `
        -RunnerStartFile (Join-Path ([string]$Session.RuntimeDir) 'runner.start')
    if ($runner -and [string]$runner.status -eq 'OtherRunner') { return @{ Owned = $false; Reason = 'runner-active' } }
    return @{ Owned = $true; Reason = 'ok' }
}

function Get-WorkloadSessionRefusal {
    <#
    .SYNOPSIS
        The refusal for a call that needs an attached VM or the runtime; $null when none applies.
    .DESCRIPTION
        The two codes stand once, here. Saving passes neither switch, so a
        detached session can still save its journal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Tool,
        [switch]$NeedsVm,
        [switch]$NeedsOwnership
    )
    if ($NeedsVm -and [string]$Session.State -ne 'attached') {
        return (New-WorkloadRefusal -Code 'workload_session_detached' -Key 'runner.workload_session_detached' -Arguments @{ tool = $Tool; reason = [string]$Session.DetachReason })
    }
    if ($NeedsOwnership) {
        $ownership = Test-WorkloadSessionOwnership -Session $Session
        if (-not $ownership.Owned) {
            return (New-WorkloadRefusal -Code 'workload_ownership_lost' -Key 'runner.workload_ownership_lost' -Arguments @{ tool = $Tool; reason = [string]$ownership.Reason })
        }
    }
    return $null
}

function Set-WorkloadReplayNodeStatus {
    # Private: mark a nested node of the owner cycle; a failure is reported and swallowed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes the status of one nested node of the owner cycle.')]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$NodeId,
        [Parameter(Mandatory)][string]$Status,
        [string]$ErrorMessage = ''
    )
    try {
        Set-NestedRunStatus -StatusPath $Session.StatusPath -NodeId $NodeId -Status $Status -ErrorMessage $ErrorMessage -Confirm:$false
    } catch {
        Write-Verbose "The nested node '$NodeId' was not set to '$Status': $($_.Exception.Message)"
    }
}

function Start-WorkloadReplay {
    <#
    .SYNOPSIS
        Starts the replay of a sequence's own steps as a nested Debug-TestSequence.ps1 child.
    .DESCRIPTION
        Returns ok with the replay handle, or a refusal that leaves the session
        as it was. The child runs nested in the owner cycle, on the attached VM,
        from the named sequence's first own step, with -NoProjectClone; it
        writes its completion record and its logs under the cycle folder,
        never in the session folder. Once the child started it is never left
        without an owner: an exception after the start stops it, marks the
        exception with WorkloadReplayChildStarted and rethrows it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts the replay child process a client asked for.')]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sequence,
        [Parameter(Mandatory)][string]$OperationId,
        [ValidateRange(60, 43200)][int]$TimeoutSeconds = 7200,
        [string]$ScriptPath = ''
    )
    $tool = 'workload_run_sequence'
    if (-not $ScriptPath) { $ScriptPath = Join-Path ([string]$Session.TestRoot) 'Debug-TestSequence.ps1' }
    $refusal = Get-WorkloadSessionRefusal -Session $Session -Tool $tool -NeedsVm -NeedsOwnership
    if ($null -ne $refusal) { return $refusal }

    $argumentRefusal = Test-WorkloadSessionArgument -Tool $tool -Sequence $Sequence
    if ($null -ne $argumentRefusal) { return $argumentRefusal }
    $Sequence = Get-WorkloadStrippedSequenceName -Sequence $Sequence
    $sequencePath = $null
    try {
        $sequencePath = Resolve-SequencePath -SequencesDir $Session.SequencesDir -Name $Sequence -HostType $Session.HostType -RepoRoot $Session.RepoRoot
    } catch {
        return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
    }
    if ($null -eq $sequencePath) {
        $searchList = Format-SequenceSearchList -Item (Get-SequenceSearchPath -SequencesDir $Session.SequencesDir -Name $Sequence -HostType $Session.HostType -RepoRoot $Session.RepoRoot)
        return (New-WorkloadRefusal -Code 'workload_sequence_not_found' -Key 'runner.workload_sequence_not_found' -Arguments @{ tool = $tool; sequence = $Sequence; list = [string]$searchList })
    }
    $doc = $null
    try {
        $doc = Read-SequenceFile -Path $sequencePath
    } catch {
        return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
    }
    # An orchestration sequence would reach an admission sweep with no exception.
    if ((Test-IsOrchestrationSequence -Sequence $doc) -or
        -not ($doc -is [System.Collections.IDictionary] -and $doc.Contains('baseline') -and $doc.Contains('steps') -and
            $doc['baseline'] -is [System.Collections.IDictionary] -and $doc['baseline'].Contains([string]$Session.OsKey))) {
        return (New-WorkloadRefusal -Code 'workload_sequence_not_guest' -Key 'runner.workload_sequence_not_guest' -Arguments @{ tool = $tool; sequence = $Sequence; osKey = [string]$Session.OsKey })
    }

    $vmState = [string](Get-VMState -VMName $Session.VMName)
    if ($vmState -ne 'running') {
        $Session.State = 'detached'
        $Session.DetachReason = "vm-$vmState"
        return (Get-WorkloadSessionRefusal -Session $Session -Tool $tool -NeedsVm)
    }

    # The last check before the child starts: planning can remove a stale
    # managed snapshot.
    $planWarning = $null
    $planInformation = $null
    $plan = $null
    try {
        $plan = Resolve-TestSequencePlan -RepoRoot $Session.RepoRoot -SequencesDir $Session.SequencesDir -HostType $Session.HostType `
            -SequenceName $Sequence -OsKey $Session.OsKey -WarningVariable planWarning -InformationVariable planInformation
    } catch {
        return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $_.Exception.Message })
    }
    if ($null -eq $plan -or $plan.resolveFailed) {
        $planMessage = (@($planWarning | ForEach-Object { [string]$_.Message }) | Where-Object { $_ }) -join '; '
        if (-not $planMessage) {
            $planMessage = (@($planInformation | ForEach-Object { ([string]$_.MessageData).Trim() }) | Where-Object { $_ }) -join '; '
        }
        if (-not $planMessage) { $planMessage = $Sequence }
        return (New-WorkloadRefusal -Code 'workload_plan_invalid' -Key 'runner.workload_plan_invalid' -Arguments @{ tool = $tool; sequence = $Sequence; message = $planMessage })
    }
    # A replay runs the named sequence's own steps and never repeats its
    # prerequisites against a VM that already exists. The planner builds the
    # entries with New-Object, and @() over that wrapped generic list throws
    # "Argument types do not match" on PowerShell 7.6; a cast does not.
    $entries = [object[]]$plan.chainEntries
    $startStep = [int]$entries[$entries.Count - 1].globalStart

    $null = Repair-VncConnection -VMName $Session.VMName -HostType $Session.HostType -Confirm:$false
    $null = Reset-WorkloadSurface -Session $Session -Reason 'replay-start'

    $Session.ReplayCounter++
    $replayId = 'r{0:D4}' -f $Session.ReplayCounter
    $invocationId = [guid]::NewGuid().ToString('N')
    $parentNode = "$($Session.GuestKey)/$replayId"
    $childNode = "$parentNode/$Sequence"
    $nestedFolder = Join-Path (Join-Path ([string]$Session.CycleFolder) 'nested') ($childNode -replace '[^A-Za-z0-9._-]', '_')
    $replayFolder = Join-Path ([string]$Session.CycleFolder) 'workload-replay'
    if (-not (Test-Path -LiteralPath $replayFolder -PathType Container)) { $null = New-Item -ItemType Directory -Path $replayFolder -Force }
    $sidecarPath = Join-Path $replayFolder "$replayId.completion.json"
    if (Test-Path -LiteralPath $sidecarPath) { Remove-Item -LiteralPath $sidecarPath -Force }
    $outputLogPath = Join-Path $replayFolder "$replayId.out.log"
    $errorLogPath = Join-Path $replayFolder "$replayId.err.log"

    Register-NestedRunNode -StatusPath $Session.StatusPath -NodeId $parentNode -ParentId $Session.GuestKey -Name "$replayId $Sequence" `
        -Kind 'sequence' -CycleStartUtc ([string]$Session.CycleStartUtc) -Confirm:$false

    # ProcessStartInfo.Environment copies the environment when it is first
    # read, so the context is published before the start information exists.
    Publish-CycleContext -CycleStartUtc ([string]$Session.CycleStartUtc) -StatusPath $Session.StatusPath -RootCycleFolder ([string]$Session.CycleFolder) `
        -CycleNumber ([int]$Session.CycleNumber) -ParentId $parentNode -Confirm:$false
    try {
        $outStream = [IO.FileStream]::new($outputLogPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $errStream = [IO.FileStream]::new($errorLogPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $psi = [Diagnostics.ProcessStartInfo]::new((Test.InnerSpawn\Get-PwshExePath))
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $Session.RepoRoot
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ScriptPath, '-SequenceName', $Sequence, '-GuestKey', $Session.GuestKey,
            '-VMName', $Session.VMName, '-StartStep', "$startStep",
            '-ConfigPath', $Session.ConfigPath, '-NoProjectClone')
        foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
        $psi.Environment['YURUNA_SEQUENCE_COMPLETION_SIDECAR'] = $sidecarPath
        $psi.Environment['YURUNA_SEQUENCE_INVOCATION_ID'] = $invocationId
        $process = $null
        try {
            $process = [Diagnostics.Process]::Start($psi)
        } catch {
            $spawnError = $_.Exception.Message
            $outStream.Dispose()
            $errStream.Dispose()
            Set-WorkloadReplayNodeStatus -Session $Session -NodeId $parentNode -Status 'fail'
            return (New-WorkloadRefusal -Code 'workload_replay_spawn_failed' -Key 'runner.workload_replay_spawn_failed' -Arguments @{ tool = $tool; message = $spawnError })
        }
        $startedUtc = [DateTime]::UtcNow
        try {
            $process.StandardInput.Close()
            $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
            $errTask = $process.StandardError.BaseStream.CopyToAsync($errStream)
            Register-WorkloadOwnedProcess -SessionDir $Session.Folder -ProcessId $process.Id `
                -StartTicks $process.StartTime.ToUniversalTime().Ticks -Role 'replay'
            $replay = @{
                ReplayId      = $replayId
                InvocationId  = $invocationId
                OperationId   = $OperationId
                Sequence      = $Sequence
                SequencePath  = [string]$sequencePath
                StartStep     = $startStep
                Process       = $process
                ChildPid      = $process.Id
                OutStream     = $outStream
                ErrStream     = $errStream
                OutTask       = $outTask
                ErrTask       = $errTask
                OutputLogPath = $outputLogPath
                ErrorLogPath  = $errorLogPath
                SidecarPath   = $sidecarPath
                ParentNodeId  = $parentNode
                ChildNodeId   = $childNode
                NestedFolder  = $nestedFolder
                StartedUtc    = $startedUtc
                DeadlineUtc   = $startedUtc.AddSeconds($TimeoutSeconds)
                StopReason    = ''
            }
            $Session.ActiveReplay = $replay
            return [ordered]@{ ok = $true; Replay = $replay }
        } catch {
            $_.Exception.Data['WorkloadReplayChildStarted'] = $true
            try {
                Stop-YurunaProcessTree -ProcessId $process.Id -GraceMilliseconds 5000 -Confirm:$false
            } catch {
                Write-Verbose "The replay child $($process.Id) was not stopped: $($_.Exception.Message)"
            }
            $process.Dispose()
            $outStream.Dispose()
            $errStream.Dispose()
            $Session.ActiveReplay = $null
            Set-WorkloadReplayNodeStatus -Session $Session -NodeId $parentNode -Status 'fail'
            throw
        }
    } finally {
        Clear-CycleContext -Confirm:$false
    }
}

function Read-WorkloadReplayRecord {
    # Private: the completion record of a replay and its state.
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Replay)
    if (-not (Test-Path -LiteralPath $Replay.SidecarPath -PathType Leaf)) { return @{ State = 'missing'; Record = $null } }
    $record = $null
    try {
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Replay.SidecarPath)) -AsHashtable -DateKind String
    } catch {
        Write-Verbose "The completion record '$($Replay.SidecarPath)' is not JSON: $($_.Exception.Message)"
        return @{ State = 'unreadable'; Record = $null }
    }
    if ($record -isnot [System.Collections.IDictionary]) { return @{ State = 'unreadable'; Record = $null } }
    if (-not ([string]$record['schema'] -ceq 'yuruna.sequence-completion/v1') -or
        -not ([string]$record['invocationId'] -ceq [string]$Replay.InvocationId)) {
        return @{ State = 'mismatch'; Record = $null }
    }
    return @{ State = 'matched'; Record = $record }
}

function Get-WorkloadReplayVerdict {
    # Private: the verdict and effect of a completed replay.
    [OutputType([hashtable])]
    param([string]$StopReason, $ExitCode, [string]$RecordState, $Record)
    if ($StopReason -eq 'timed-out') { return @{ Verdict = 'timed-out'; Effect = 'uncertain' } }
    if ($StopReason -in @('canceled', 'session-end')) { return @{ Verdict = 'canceled'; Effect = 'uncertain' } }
    $matched = $RecordState -eq 'matched'
    $outcome = if ($matched) { [string]$Record['outcome'] } else { '' }
    if ($null -ne $ExitCode -and [int]$ExitCode -eq 0) {
        if (-not $matched -or $outcome -eq 'pass') { return @{ Verdict = 'passed'; Effect = 'applied' } }
        return @{ Verdict = 'failed'; Effect = 'uncertain' }
    }
    if ($matched) {
        if ($outcome -eq 'not-run') { return @{ Verdict = 'cannot-run'; Effect = 'none-proven' } }
        return @{ Verdict = 'failed'; Effect = 'uncertain' }
    }
    if ($null -ne $ExitCode -and [int]$ExitCode -eq 2) { return @{ Verdict = 'cannot-run'; Effect = 'uncertain' } }
    return @{ Verdict = 'failed'; Effect = 'uncertain' }
}

function Complete-WorkloadReplay {
    # Private: finish the active replay and build its result (Get-WorkloadReplayResult step list).
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [datetime]$NowUtc = [DateTime]::UtcNow,
        [switch]$ChildAlive
    )
    $replay = $Session.ActiveReplay
    $drained = $false
    try {
        $drained = [Threading.Tasks.Task]::WaitAll(@($replay.OutTask, $replay.ErrTask), 5000)
    } catch {
        Write-Verbose "The output of replay $($replay.ReplayId) was not drained: $($_.Exception.Message)"
        $drained = $false
    }
    $exited = $false
    $exitCode = $null
    try {
        $exited = $replay.Process.HasExited
        if ($exited) { $exitCode = $replay.Process.ExitCode }
    } catch {
        Write-Verbose "The exit of replay $($replay.ReplayId) cannot be read: $($_.Exception.Message)"
    }
    $replay.Process.Dispose()
    $replay.OutStream.Dispose()
    $replay.ErrStream.Dispose()
    if ($exited) {
        try {
            Unregister-WorkloadOwnedProcess -SessionDir $Session.Folder -ProcessId $replay.ChildPid
        } catch {
            Write-Verbose "The replay child $($replay.ChildPid) stays listed: $($_.Exception.Message)"
        }
    }

    $recordRead = Read-WorkloadReplayRecord -Replay $replay
    $verdict = Get-WorkloadReplayVerdict -StopReason ([string]$replay.StopReason) -ExitCode $exitCode -RecordState $recordRead.State -Record $recordRead.Record

    $failure = $null
    $failurePath = Join-Path ([string]$replay.NestedFolder) 'last_failure.json'
    if (Test-Path -LiteralPath $failurePath -PathType Leaf) {
        try {
            $failure = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($failurePath)) -AsHashtable -DateKind String
        } catch {
            Write-Verbose "The failure record of replay $($replay.ReplayId) is not JSON: $($_.Exception.Message)"
        }
    }

    Set-WorkloadReplayNodeStatus -Session $Session -NodeId $replay.ParentNodeId -Status $(if ($verdict.Verdict -eq 'passed') { 'pass' } else { 'fail' })
    if ($verdict.Verdict -in @('timed-out', 'canceled')) {
        Set-WorkloadReplayNodeStatus -Session $Session -NodeId $replay.ChildNodeId -Status 'fail' -ErrorMessage $verdict.Verdict
    }

    $oldName = [string]$Session.VMName
    $vmState = ''
    if ($ChildAlive) {
        $Session.State = 'detached'
        $Session.DetachReason = 'replay-child-alive'
        $vmState = [string](Get-VMState -VMName $oldName)
    } else {
        $candidates = [Collections.Generic.List[string]]::new()
        if ($recordRead.State -eq 'matched') {
            $finished = [string]$recordRead.Record['finishedVmName']
            if ($finished -and $finished -ne $oldName -and (Test-WorkloadPatternValue -Value $finished -Pattern $script:WorkloadVmNamePattern)) {
                $candidates.Add($finished)
            }
        }
        $candidates.Add($oldName)
        $target = $null
        foreach ($candidate in $candidates) {
            if ([string](Get-VMState -VMName $candidate) -eq 'running') { $target = $candidate; break }
        }
        if ($null -eq $target) {
            $vmState = [string](Get-VMState -VMName $oldName)
            $Session.State = 'detached'
            $Session.DetachReason = "vm-$vmState"
        } else {
            $vmState = 'running'
            $Session.VMName = $target
            try {
                if ($target -ne $oldName) { Set-GuestVMName -GuestKey $Session.GuestKey -VMName $target -Confirm:$false }
                Clear-ProvenGuestAddress -Confirm:$false
                foreach ($name in @($oldName, $target) | Select-Object -Unique) {
                    $null = Repair-VncConnection -VMName $name -HostType $Session.HostType -Confirm:$false
                }
            } catch {
                Write-Verbose "The guest connection after replay $($replay.ReplayId) was not reset: $($_.Exception.Message)"
            }
            try {
                $scope = Initialize-WorkloadVariableScope -Session $Session
                if ($scope -is [System.Collections.IDictionary] -and $scope.Contains('ok') -and $scope['ok'] -eq $false) {
                    $Session.State = 'detached'
                    $Session.DetachReason = 'variable-scope'
                }
            } catch {
                Write-Verbose "The variable table after replay $($replay.ReplayId) was not rebuilt: $($_.Exception.Message)"
                $Session.State = 'detached'
                $Session.DetachReason = 'variable-scope'
            }
            $null = Reset-WorkloadSurface -Session $Session -Reason 'replay'
        }
    }

    $Session.ActiveReplay = $null
    return [ordered]@{
        verdict          = $verdict.Verdict
        effect           = $verdict.Effect
        exitCode         = $exitCode
        sequence         = $replay.Sequence
        sequencePath     = $replay.SequencePath
        startStep        = $replay.StartStep
        replayId         = $replay.ReplayId
        invocationId     = $replay.InvocationId
        operationId      = $replay.OperationId
        recordState      = $recordRead.State
        completionRecord = $recordRead.Record
        reason           = $(if ($recordRead.State -eq 'matched') { [string]$recordRead.Record['reason'] } else { '' })
        vmName           = [string]$Session.VMName
        vmRenamed        = ([string]$Session.VMName -ne $oldName)
        vmState          = $vmState
        sessionState     = [string]$Session.State
        failure          = $failure
        outputTruncated  = (-not $drained)
        durationSeconds  = [int][math]::Floor(($NowUtc - $replay.StartedUtc).TotalSeconds)
        childStopped     = (-not $ChildAlive)
    }
}

function Get-WorkloadReplayResult {
    <#
    .SYNOPSIS
        The result of the active replay once it ended or passed its deadline; $null while it runs.
    .DESCRIPTION
        Never blocks longer than the bounded drain of the child's output. The
        result names no path of an unfiltered artifact; its failure is the raw
        record of the nested folder, which the handler replaces by the filtered
        view before anything leaves the worker.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    $replay = $Session.ActiveReplay
    if ($null -eq $replay) { return $null }
    if ($replay.Process.HasExited) { return (Complete-WorkloadReplay -Session $Session -NowUtc $NowUtc) }
    if ($NowUtc -ge $replay.DeadlineUtc) { return (Stop-WorkloadReplay -Session $Session -Reason 'timed-out') }
    return $null
}

function Stop-WorkloadReplay {
    <#
    .SYNOPSIS
        Stops the active replay child and returns the replay's result.
    .DESCRIPTION
        A child still alive after the stop leaves the session detached with the
        reason replay-child-alive: the VM name stays and nothing is rebuilt.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops the replay child process the session started.')]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][ValidateSet('canceled', 'timed-out', 'session-end')][string]$Reason
    )
    $replay = $Session.ActiveReplay
    if ($null -eq $replay) { return $null }
    $replay.StopReason = $Reason
    try {
        Stop-YurunaProcessTree -ProcessId $replay.ChildPid -GraceMilliseconds 5000 -Confirm:$false
    } catch {
        Write-Verbose "The replay child $($replay.ChildPid) was not signaled: $($_.Exception.Message)"
    }
    $ended = $false
    try {
        $ended = $replay.Process.WaitForExit(10000)
    } catch {
        Write-Verbose "The exit of replay child $($replay.ChildPid) was not observed: $($_.Exception.Message)"
    }
    return (Complete-WorkloadReplay -Session $Session -ChildAlive:(-not $ended))
}

function Stop-WorkloadSessionRuntime {
    <#
    .SYNOPSIS
        Ends a session: stops a replay, closes the owner cycle and gives the lease back.
    .DESCRIPTION
        The VM is not stopped. Only the reason error closes the owner cycle as
        failed. Each step runs on its own, so one that fails does not keep the
        lease. The returned CycleFolder is the folder after Stop-LogFile renamed
        it, '' when no cycle was registered.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Releases the one-shot lease and closes the owner cycle of the session.')]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [ValidateSet('ended', 'client-disconnect', 'error')][string]$Reason = 'ended'
    )
    $cycleFolder = [string]$Session.CycleFolder
    $closedFolder = {
        param([string]$Folder)
        if (-not $Folder) { return '' }
        $suffix = '.incomplete'
        if ($Folder.EndsWith($suffix, [StringComparison]::Ordinal)) {
            $renamed = $Folder.Substring(0, $Folder.Length - $suffix.Length)
            if (Test-Path -LiteralPath $renamed -PathType Container) { return $renamed }
        }
        return $Folder
    }
    if ([string]$Session.State -eq 'ended') { return @{ Released = $false; CycleFolder = (& $closedFolder $cycleFolder) } }
    $released = $false
    try {
        if ($null -ne $Session.ActiveReplay) {
            try {
                $null = Stop-WorkloadReplay -Session $Session -Reason 'session-end'
            } catch {
                Write-Verbose "The replay was not stopped at session end: $($_.Exception.Message)"
            }
        }
        try {
            $null = Reset-WorkloadSurface -Session $Session -Reason 'session-end'
        } catch {
            Write-Verbose "The surfaces were not reset at session end: $($_.Exception.Message)"
        }
        if ($cycleFolder) {
            $failed = $Reason -eq 'error'
            $status = if ($failed) { 'fail' } else { 'pass' }
            try {
                Set-StepStatus -GuestKey $Session.GuestKey -StepName 'Session' -Status $status -Confirm:$false
                Set-GuestStatus -GuestKey $Session.GuestKey -Status $status -Confirm:$false
                $maxHistory = 30
                $config = $Session.Config
                if ($config -is [System.Collections.IDictionary] -and $config.testCycle -is [System.Collections.IDictionary] -and
                    $config.testCycle.recentDisplayCount) {
                    $maxHistory = [int]$config.testCycle.recentDisplayCount
                }
                Complete-Run -OverallStatus $status -MaxHistoryRuns $maxHistory
            } catch {
                Write-Verbose "The owner cycle status was not closed: $($_.Exception.Message)"
            }
            try {
                Stop-LogFile -Outcome $(if ($failed) { 'aborted' } else { 'pass' }) -Reason "workload session ended ($Reason)" -Confirm:$false
            } catch {
                Write-Verbose "The owner cycle log was not closed: $($_.Exception.Message)"
            }
        }
        try {
            Clear-CycleContext -Confirm:$false
            Clear-GuestSshUserOverride
        } catch {
            Write-Verbose "The cycle context or the SSH user override was not cleared: $($_.Exception.Message)"
        }
    } finally {
        try {
            $released = [bool](Exit-YurunaOneShotLease -RuntimeDir $Session.RuntimeDir -Confirm:$false)
        } catch {
            Write-Verbose "The one-shot lease was not released: $($_.Exception.Message)"
        }
        $Session.State = 'ended'
    }
    return @{ Released = $released; CycleFolder = (& $closedFolder $cycleFolder) }
}

Export-ModuleMember -Function New-WorkloadRefusal, Import-WorkloadEngineModule, Test-WorkloadSessionArgument, `
    Start-WorkloadSessionRuntime, Test-WorkloadSessionOwnership, Get-WorkloadSessionRefusal, `
    Start-WorkloadReplay, Get-WorkloadReplayResult, Stop-WorkloadReplay, Stop-WorkloadSessionRuntime
