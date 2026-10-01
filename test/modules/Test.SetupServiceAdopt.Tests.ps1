<#PSScriptInfo
.VERSION 2026.09.30
.GUID 424bfe15-8ad8-42d2-a867-c5ab398deded
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test setup service vm adopt preserve pester
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
    install/setup.ps1's service-VM adoption: a state that could not be
    confirmed, or a service another start or stop is working on, is
    preserved -- the step fails and nothing is torn down.
.DESCRIPTION
    Test-ServiceVMAdoptable, Invoke-ServiceVMEnsure and Invoke-SetupStep are
    taken from the AST of the real installer and defined in this suite's
    scope, so the behavior under test is the shipped code. Everything they
    reach outside themselves -- the restore sweep, the teardown, the child
    script runner and the report writers -- is a recording stand-in, and the
    run's exit is a sentinel exception instead of a process exit.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -DisableNameChecking -Global
    $setupAst = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'install/setup.ps1')
    foreach ($name in @('Test-ServiceVMAdoptable', 'Invoke-ServiceVMEnsure', 'Invoke-SetupStep')) {
        $wanted = $name
        $definition = $setupAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted }.GetNewClosure(), $true) | Select-Object -First 1
        if (-not $definition) { throw "install/setup.ps1 no longer defines $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Stand-ins for everything the three functions reach.
    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments)
        $parts = @($Key)
        if ($Arguments) { foreach ($k in ($Arguments.Keys | Sort-Object)) { $parts += "$k=$($Arguments[$k])" } }
        $parts -join '|'
    }
    function Import-SetupModule { param([string]$Path) $null = $Path }
    function Initialize-YurunaHost { param([string]$RepoRoot, [string]$HostType) $null = $RepoRoot, $HostType; $true }
    function Restore-YurunaServiceVM {
        # No [CmdletBinding()]: the caller's -Confirm:$false lands in $args.
        param([string[]]$Key, [switch]$ProbeRunning)
        $script:Log.Restore.Add([pscustomobject]@{ Key = $Key; ProbeRunning = [bool]$ProbeRunning })
        $script:NextRestore
    }
    function Write-SetupDetail { param([string]$Message) $script:Log.Detail.Add($Message) }
    function Invoke-ServiceVMReset { param([string]$Service, [string]$StopScript) $null = $StopScript; $script:Log.Reset.Add($Service) }
    function Invoke-RepoScript { param([string]$Path, [string[]]$Arguments) $null = $Arguments; $script:Log.Run.Add($Path) }
    function Add-PlannedStep { param([string]$Description) $script:Log.Planned.Add($Description) }
    function Add-SkippedStep { param([string]$Description, [switch]$Quiet) $null = $Quiet; $script:Log.Skipped.Add($Description) }
    function Add-WarnedStep { param([string]$Description) $script:Log.Warned.Add($Description) }
    function Write-SetupLogLine { param([string]$Level, [string]$Message) $null = $Level, $Message }
    function Write-StepOutcome {
        param([string]$Outcome, [string]$Name, [string]$Detail, $Elapsed)
        $null = $Elapsed
        $script:Log.Outcome.Add([pscustomobject]@{ Outcome = $Outcome; Name = $Name; Detail = $Detail })
    }
    function Write-SetupReport { $script:Log.Reported++ }
    function Write-SetupError { param([string]$Message) $script:Log.Errors.Add($Message) }
    function Exit-Setup { param([int]$Code) throw "setup-exit-$Code" }
    function Test-StepPrerequisite { param([string]$Name, [string[]]$Requires, [switch]$DeclinedOnly) $null = $Name, $Requires, $DeclinedOnly; $true }

    function Initialize-SetupFixture {
        $script:Log = @{
            Restore = [System.Collections.Generic.List[object]]::new(); Detail = [System.Collections.Generic.List[string]]::new()
            Reset = [System.Collections.Generic.List[string]]::new(); Run = [System.Collections.Generic.List[string]]::new()
            Planned = [System.Collections.Generic.List[string]]::new(); Skipped = [System.Collections.Generic.List[string]]::new()
            Warned = [System.Collections.Generic.List[string]]::new(); Outcome = [System.Collections.Generic.List[object]]::new()
            Errors = [System.Collections.Generic.List[string]]::new(); Reported = 0
        }
        $script:Facts = @{}
        $script:StepUnmet = [System.Collections.Generic.List[string]]::new()
        $script:Done = [System.Collections.Generic.List[string]]::new()
        $script:Failed = [System.Collections.Generic.List[string]]::new()
        $script:Rebuild = $false
        $script:TestRoot = Join-Path $TestDrive 'test'
        $script:RepoRoot = $TestDrive
        $script:HostType = 'host.macos.utm'
    }
    function New-RestoreRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record only.')]
        [CmdletBinding()]
        param([string]$Outcome, [bool]$Healthy = $false, [string]$ProbeReason = 'responsive', [string]$Message = 'm', [string]$StateBefore = 'running')
        [pscustomobject]@{ Key = 'caching-proxy'; VMName = 'yuruna-caching-proxy-service'; DisplayName = 'Caching-proxy service'; StateBefore = $StateBefore
            Outcome = $Outcome; Healthy = $Healthy; Message = $Message; ProbeReason = $ProbeReason }
    }
}

Describe 'Test-ServiceVMAdoptable preserves what it cannot confirm' {
    BeforeEach { Initialize-SetupFixture }

    It 'preserves a service whose state is <Outcome>, naming the probe reason' -TestCases @(
        @{ Outcome = 'state-unknown'; ProbeReason = 'timeout'; ReasonKey = 'automation.setup_service_vm_reason_state_unknown'; Cause = 'state-unknown' }
        @{ Outcome = 'deadline-exhausted'; ProbeReason = 'deadline-exhausted'; ReasonKey = 'automation.setup_service_vm_reason_state_unknown'; Cause = 'state-unknown' }
        @{ Outcome = 'operation-busy'; ProbeReason = 'responsive'; ReasonKey = 'automation.setup_service_vm_reason_operation_busy'; Cause = 'operation-busy' }
        @{ Outcome = 'lock-unavailable'; ProbeReason = 'responsive'; ReasonKey = 'automation.setup_service_vm_reason_lock_unavailable'; Cause = 'lock-unavailable' }
    ) {
        param($Outcome, $ProbeReason, $ReasonKey, $Cause)
        $script:NextRestore = New-RestoreRecord -Outcome $Outcome -ProbeReason $ProbeReason -StateBefore 'unknown'
        $v = Test-ServiceVMAdoptable -RosterKey 'caching-proxy'
        $v.Adopt | Should -BeFalse
        $v.Preserve | Should -BeTrue
        $v.ProbeReason | Should -Be $ProbeReason
        $v.Reason | Should -BeLike "$ReasonKey*"
        $v.Cause | Should -Be $Cause
        $script:Log.Restore[0].ProbeRunning | Should -BeTrue
    }

    It 'rebuilds a service stopped on purpose, because setup is the explicit start' {
        $script:NextRestore = New-RestoreRecord -Outcome 'intended-stopped' -StateBefore 'stopped'
        $v = Test-ServiceVMAdoptable -RosterKey 'caching-proxy'
        $v.Adopt | Should -BeFalse
        $v.Preserve | Should -BeFalse
        $v.Reason | Should -Be 'automation.setup_service_vm_reason_intended_stopped'
    }

    It 'keeps the existing verdicts for running, started and absent services' {
        $script:NextRestore = New-RestoreRecord -Outcome 'running' -Healthy $true
        (Test-ServiceVMAdoptable -RosterKey 'caching-proxy').Adopt | Should -BeTrue
        $script:NextRestore = New-RestoreRecord -Outcome 'running' -Healthy $false -Message 'silent'
        $silent = Test-ServiceVMAdoptable -RosterKey 'caching-proxy'
        $silent.Adopt | Should -BeFalse
        $silent.Preserve | Should -BeFalse
        $script:NextRestore = New-RestoreRecord -Outcome 'started' -Healthy $true
        (Test-ServiceVMAdoptable -RosterKey 'caching-proxy').Adopt | Should -BeTrue
        $script:NextRestore = New-RestoreRecord -Outcome 'absent' -StateBefore 'absent'
        $absent = Test-ServiceVMAdoptable -RosterKey 'caching-proxy'
        $absent.Adopt | Should -BeFalse
        $absent.Preserve | Should -BeFalse
    }

    It 'returns the preview verdict under -WhatIf without asking the machine anything' {
        $WhatIfPreference = $true
        try {
            $v = Test-ServiceVMAdoptable -RosterKey 'caching-proxy'
        } finally { $WhatIfPreference = $false }
        $v.Adopt | Should -BeFalse
        $v.Preserve | Should -BeFalse
        $script:Log.Restore.Count | Should -Be 0
    }
}

Describe 'Invoke-ServiceVMEnsure fails the step and tears nothing down on a preserved service' {
    BeforeEach { Initialize-SetupFixture }

    It 'fails a critical start step without a teardown, and ends the run' {
        $script:NextRestore = New-RestoreRecord -Outcome 'state-unknown' -ProbeReason 'timeout' -StateBefore 'unknown'
        { Invoke-ServiceVMEnsure -Service 'caching-proxy service' -RosterKey 'caching-proxy' -StopScript 'Stop-CachingProxyServiceVM.ps1' `
                -StartScript 'Start-CachingProxyServiceVM.ps1' -Critical } | Should -Throw 'setup-exit-1'
        $script:Log.Reset.Count | Should -Be 0 -Because 'nothing is stopped, removed or rebuilt'
        $script:Log.Run.Count | Should -Be 0 -Because 'the start script is not run either'
        $script:Facts['caching-proxy'] | Should -Be 'failed' -Because 'dependents must block'
        $fail = @($script:Log.Outcome | Where-Object Outcome -eq 'FAIL')
        $fail.Count | Should -Be 1
        $fail[0].Name | Should -Be 'Start the caching-proxy service VM'
        $fail[0].Detail | Should -Match '^exceptions\.setup_service_vm_preserved\|' -Because 'an unconfirmed state is a hypervisor problem to resolve'
        $fail[0].Detail | Should -Match 'reason=automation\.setup_service_vm_reason_state_unknown\|reason=timeout'
        $script:Log.Reported | Should -Be 1
    }

    It 'fails a non-critical start step for a <Outcome> service, naming a retry rather than a hypervisor fix, and lets the run continue' -TestCases @(
        @{ Outcome = 'operation-busy'; ReasonKey = 'automation.setup_service_vm_reason_operation_busy' }
        @{ Outcome = 'lock-unavailable'; ReasonKey = 'automation.setup_service_vm_reason_lock_unavailable' }
    ) {
        param($Outcome, $ReasonKey)
        $script:NextRestore = New-RestoreRecord -Outcome $Outcome
        $null = Invoke-ServiceVMEnsure -Service 'stash service' -RosterKey 'stash' -StopScript 'Stop-StashServiceVM.ps1' -StartScript 'Start-StashServiceVM.ps1'
        $script:Log.Reset.Count | Should -Be 0
        $script:Log.Run.Count | Should -Be 0
        $script:Facts['stash'] | Should -Be 'failed'
        $fail = @($script:Log.Outcome | Where-Object Outcome -eq 'FAIL')
        $fail.Count | Should -Be 1
        $fail[0].Detail | Should -Match '^exceptions\.setup_service_vm_preserved_retry\|'
        $fail[0].Detail | Should -Match ('reason=' + [regex]::Escape($ReasonKey))
        $script:Log.Errors.Count | Should -Be 0 -Because 'only a critical step ends the run'
    }

    It 'rebuilds a service stopped on purpose: teardown, then the start' {
        $script:NextRestore = New-RestoreRecord -Outcome 'intended-stopped' -StateBefore 'stopped'
        $null = Invoke-ServiceVMEnsure -Service 'stash service' -RosterKey 'stash' -StopScript 'Stop-StashServiceVM.ps1' -StartScript 'Start-StashServiceVM.ps1'
        $script:Log.Reset | Should -Be @('stash service')
        $script:Log.Run.Count | Should -Be 1
        $script:Log.Run[0] | Should -BeLike '*Start-StashServiceVM.ps1'
        $script:Facts['stash'] | Should -Be 'ok'
    }

    It 'still adopts a healthy service with no step at all' {
        $script:NextRestore = New-RestoreRecord -Outcome 'running' -Healthy $true
        $null = Invoke-ServiceVMEnsure -Service 'stash service' -RosterKey 'stash' -StopScript 'Stop-StashServiceVM.ps1' -StartScript 'Start-StashServiceVM.ps1'
        $script:Log.Reset.Count | Should -Be 0
        $script:Log.Run.Count | Should -Be 0
        $script:Facts['stash'] | Should -Be 'ok'
        @($script:Log.Outcome | Where-Object Outcome -eq 'SKIP').Count | Should -Be 1
    }

    It 'plans the rebuild, and runs nothing, under -WhatIf' {
        $WhatIfPreference = $true
        try {
            $null = Invoke-ServiceVMEnsure -Service 'stash service' -RosterKey 'stash' -StopScript 'Stop-StashServiceVM.ps1' -StartScript 'Start-StashServiceVM.ps1'
        } finally { $WhatIfPreference = $false }
        $script:Log.Restore.Count | Should -Be 0
        $script:Log.Run.Count | Should -Be 0
        $script:Log.Planned | Should -Contain 'Start the stash service VM'
    }
}
