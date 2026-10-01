<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4265d6db-e190-47e6-b2ae-7119aa42d885
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh automatic trigger pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    The automatic host-refresh policy in Test.HostRefreshTrigger.psm1.
.DESCRIPTION
    Covers the platform declaration, the evidence classification, the
    evidence file across the inner/outer boundary, the persisted timeout
    count, the UTC-day budget ledger, the knob and pool readers, admission,
    the synchronous worker launch and the post-dispatch decision, plus the
    call sequence the resident loop runs around one dispatch.

    Nothing here touches the operator's state: the streak file and ledger
    paths are redirected into a per-suite temporary directory, the repair
    journal and worker interfaces are stand-ins, clocks are injected, and the
    only processes started are disposable stand-ins this suite owns. The
    critical-record writer and the single-flight lock are the real ones.

    No case asserts rendered English: log lines are asserted by catalog key
    through a mocked logger or a mocked Format-YurunaOperatorMessage.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    try { Import-Module powershell-yaml -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }
    Import-Module (Join-Path $here 'Test.Config.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Get-Module -Name 'Test.HostRefreshTrigger' | Remove-Module -Force
    $script:ModulePath = Join-Path $here 'Test.HostRefreshTrigger.psm1'
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:SuiteTemp = New-YurunaTestTempDir -Prefix 'hr-trigger'
    $script:Instance = 'a' * 32
    $script:RequestId = '3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b'

    # Stand-ins for the repair-journal and worker interfaces this module
    # resolves by name. Their parameter lists follow the declared interface,
    # so a call the real functions would refuse to bind is refused here too.
    function global:Get-YurunaHostRefreshAdmissionLockPath {
        [CmdletBinding()] [OutputType([string])] param([switch]$NoCreate)
        if ($NoCreate) { return $null }
        return $null
    }
    function global:New-YurunaHostRefreshRequestId { [CmdletBinding()] [OutputType([string])] param() [guid]::NewGuid().ToString('D') }
    function global:Get-HostRefreshAdmissionDecision {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$RequestId, [string]$Channel, [string]$Tier, [string]$MaxRung, [string]$RuntimeDir, [string]$HostType, $AdmissionLock, $UtcNow)
        $null = $Channel, $Tier, $MaxRung, $RuntimeDir, $HostType, $AdmissionLock, $UtcNow
        [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId }
    }
    function global:Request-HostRefreshAdmission {
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([pscustomobject])]
        param([string]$RequestId, [string]$Channel, [string]$Tier, [string]$MaxRung, [string]$RuntimeDir, [string]$HostType,
            [hashtable]$Context, $AdmissionLock, [int]$AdmissionWaitMilliseconds, $UtcNow)
        $null = $Channel, $Tier, $MaxRung, $RuntimeDir, $HostType, $Context, $AdmissionLock, $AdmissionWaitMilliseconds, $UtcNow
        $null = $PSCmdlet.ShouldProcess($RequestId)
        [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId }
    }
    function global:Set-HostRefreshLaunchOutcome {
        [CmdletBinding(SupportsShouldProcess)] [OutputType([pscustomobject])] param([string]$RequestId, [string]$Outcome, $Launch)
        $null = $Outcome, $Launch
        $null = $PSCmdlet.ShouldProcess($RequestId)
        [pscustomobject]@{ Saved = $true; Reason = 'saved' }
    }
    function global:Stop-HostRefreshQueuedRequest {
        [CmdletBinding(SupportsShouldProcess)] [OutputType([pscustomobject])] param([string]$RequestId, [string]$Reason)
        $null = $Reason
        $null = $PSCmdlet.ShouldProcess($RequestId)
        [pscustomobject]@{ Stopped = $true; State = 'refused' }
    }
    function global:Get-HostRefreshActiveRequest {
        [CmdletBinding()] [OutputType([hashtable])] param([string]$JournalPath)
        if ($JournalPath) { return $null }
        return $null
    }
    # The same record shape the journal's reader returns: CompletedUtc is the
    # request's terminal time (unset while an obligation keeps it
    # recovery-pending), LastAttemptEndedUtc the newest attempt's end.
    function global:Get-HostRefreshResult {
        [CmdletBinding()] [OutputType([pscustomobject])] param([string]$RequestId, [string]$Generation)
        $null = $Generation
        [pscustomobject]@{
            Found = $false; RequestId = $RequestId; Channel = $null; Generation = $null; Attempt = 0; State = $null
            Verdict = $null; ExitCode = $null; Mutated = $false; FinalProbeState = $null; RunnerReadiness = 'unknown'
            Handoff = $null; CompletedUtc = $null; LastAttemptEndedUtc = $null; OutstandingObligation = [string[]]@(); OperatorAction = $null
        }
    }
    function global:Get-YurunaRefreshGateState {
        [CmdletBinding()] [OutputType([pscustomobject])] param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ SchemaVersion = 1; State = 'open'; SpawnAllowed = $true; PreflightAllowed = $false; Reason = 'no-gate' }
    }
    function global:New-HostRefreshBudget {
        [CmdletBinding()] [OutputType([pscustomobject])] param([long]$ExpiryTick, [long]$PreAdmissionExpiryTick, [scriptblock]$ClockTicks)
        $null = $ExpiryTick, $PreAdmissionExpiryTick, $ClockTicks
        [pscustomobject]@{ PSTypeName = 'Yuruna.HostRefreshBudget'; TotalExpiryTick = [long]915000 }
    }
    function global:New-HostRefreshWorkerArgumentList {
        [CmdletBinding()] [OutputType([string])] param([string]$RepoRoot, [string]$RequestId, $Budget, [switch]$IncludeInterpreterArgument)
        $null = $Budget
        $prefix = if ($IncludeInterpreterArgument) { @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'test/lab/Invoke-HostRefresh.ps1')) } else { @() }
        $prefix + @('-RequestId', $RequestId, '-DeadlineTickMs', '1915000', '-PreAdmissionDeadlineTickMs', '1060000')
    }
    $script:StubNames = @(
        'Get-YurunaHostRefreshAdmissionLockPath', 'New-YurunaHostRefreshRequestId', 'Get-HostRefreshAdmissionDecision',
        'Request-HostRefreshAdmission', 'Set-HostRefreshLaunchOutcome', 'Stop-HostRefreshQueuedRequest',
        'Get-HostRefreshActiveRequest', 'Get-HostRefreshResult', 'New-HostRefreshBudget', 'New-HostRefreshWorkerArgumentList',
        'Get-YurunaRefreshGateState')

    function New-CaseDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a throwaway directory under the suite temp root.')]
        [CmdletBinding()]
        param([string]$Name = 'case')
        $dir = Join-Path $script:SuiteTemp ("$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $dir
    }
    function New-Row {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture; nothing changes.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$Outcome = 'state-unknown', [AllowNull()][string]$ProbeReason, [string]$VMName = 'svc-vm')
        $row = [ordered]@{ Key = 'caching-proxy'; VMName = $VMName; Outcome = $Outcome; Healthy = $false }
        if ($PSBoundParameters.ContainsKey('ProbeReason')) { $row.ProbeReason = $ProbeReason }
        [pscustomobject]$row
    }
    function New-Generation {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture; nothing changes.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([int]$Cycle, [string]$Instance = $script:Instance)
        "${Instance}:$Cycle"
    }
    function Set-TestUtc {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a DateTime value; nothing changes.')]
        [CmdletBinding()]
        [OutputType([datetime])]
        param([string]$Text)
        [datetime]::SpecifyKind([datetime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), 'Utc')
    }
    function Write-EvidenceFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes a fixture file in a case directory.')]
        [CmdletBinding()]
        param([string]$RuntimeDir, [hashtable]$Record)
        Set-Content -LiteralPath (Join-Path $RuntimeDir 'runner.refresh-evidence.json') -Value ($Record | ConvertTo-Json -Depth 5) -NoNewline
    }
    function New-Accounting {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture; nothing changes.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$Outcome = 'completed', [bool]$Counted = $true, [int]$Streak = 2, [bool]$Reset = $false, [string]$Verdict = 'fault')
        [pscustomobject]@{
            Outcome = $Outcome; Counted = $Counted; Reset = $Reset; Streak = $Streak; StreakPersisted = $true; Reason = 'counted'
            Evidence = [pscustomobject]@{ Matched = $true; Reason = 'matched'; Verdict = $Verdict; Phase = 'service-vm-restore'
                ProbeReasons = [string[]]@('timeout'); ObservedUtc = '2026-09-25T10:00:00.0000000Z' }
        }
    }
    function New-QualifiedSupport {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture; nothing changes.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$HostType = 'host.macos.utm')
        [pscustomobject]@{ HostType = $HostType; Available = $true; Qualified = $true; Reason = 'available'; Tier = 'restart'; MaxRung = 'restart-if-hung' }
    }
    function New-ResultRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture; nothing changes.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [string]$Verdict = 'repaired',
            [string]$State = 'completed',
            [string]$EndedUtc = '2026-09-25T10:05:00.0000000Z',
            [AllowNull()]$Handoff = $null
        )
        # A request left recovery-pending has ended its attempt but has no
        # terminal time; a completed one has both, written together.
        @{
            Found = $true; RequestId = $null; Channel = 'automatic'; Generation = ('b' * 32); Attempt = 1; State = $State
            Verdict = $Verdict; ExitCode = $null; Mutated = $true; FinalProbeState = 'Responsive'; RunnerReadiness = 'caller-parked'
            Handoff = $Handoff; CompletedUtc = $(if ($State -eq 'recovery-pending') { $null } else { $EndedUtc }); LastAttemptEndedUtc = $EndedUtc
            OutstandingObligation = [string[]]@(); OperatorAction = $null
        }
    }
    function Get-OwnStartTime {
        [CmdletBinding()]
        [OutputType([long])]
        param()
        & (Get-Module Test.HostRefreshTrigger) { Get-HostRefreshAutoProcessStartTime }
    }
    function New-DecisionState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes fixture files in a case directory.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([int]$Threshold = 2, [string]$Protocol = '1', [int]$Cycle = 5)
        $dir = New-CaseDir -Name 'decision'
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'test') -Force
        if ($Protocol) { Set-Content -LiteralPath (Join-Path $dir 'test/host-refresh.protocol-version') -Value $Protocol }
        $config = Join-Path $dir 'test.config.yml'
        Set-Content -LiteralPath $config -Value "testCycle:`n  autoRefreshAfterStalls: $Threshold`n"
        @{
            ConfigPath = $config; RepoRoot = $dir; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }
            RunnerInstanceId = $script:Instance; CycleGeneration = (New-Generation -Cycle $Cycle)
        }
    }
    function Clear-LoggedOnce {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Resets a test-visible module cache.')]
        [CmdletBinding()]
        param()
        & (Get-Module Test.HostRefreshTrigger) { $script:HostRefreshAutoLoggedOnce.Clear() }
    }
    function Get-SourceCodeToken {
        [CmdletBinding()]
        [OutputType([System.Management.Automation.Language.Token])]
        param([string]$Path)
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $tokens | Where-Object { $_.Kind -ne 'Comment' }
    }
}

AfterAll {
    foreach ($name in $script:StubNames) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue }
    Remove-YurunaTestTempDir $script:SuiteTemp
}

Describe 'Get-HostRefreshAutoTriggerSupport -- platform declaration' {
    It 'declares every platform unqualified, with its own reason, and loads no rung table' {
        Mock -ModuleName Test.HostRefreshTrigger Resolve-HostRefreshAutoCommand { throw 'must not be read for an unqualified platform' } -ParameterFilter { $Name -contains 'Get-VirtualizationRepairRung' }
        $expected = @{ 'host.macos.utm' = 'awaiting-native-qualification'; 'host.ubuntu.kvm' = 'platform-unqualified'; 'host.windows.hyper-v' = 'platform-unqualified' }
        foreach ($hostType in $expected.Keys) {
            $s = Get-HostRefreshAutoTriggerSupport -HostType $hostType
            $s.Available | Should -BeFalse
            $s.Qualified | Should -BeFalse
            $s.Reason | Should -Be $expected[$hostType]
            $s.Tier | Should -Be 'restart'
            $s.MaxRung | Should -BeNullOrEmpty
        }
        Should -Invoke Resolve-HostRefreshAutoCommand -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly -ParameterFilter { $Name -contains 'Get-VirtualizationRepairRung' }
    }

    It 'reports an unknown or empty host type as unsupported' {
        (Get-HostRefreshAutoTriggerSupport -HostType '').Reason | Should -Be 'unsupported-host'
        (Get-HostRefreshAutoTriggerSupport -HostType 'host.plan9').Reason | Should -Be 'unsupported-host'
    }

    Context 'a platform declared qualified' {
        BeforeAll {
            & (Get-Module Test.HostRefreshTrigger) { $script:HostRefreshAutoQualification['host.ubuntu.kvm'] = @{ Qualified = $true; Reason = 'qualified' } }
        }
        AfterAll {
            & (Get-Module Test.HostRefreshTrigger) { $script:HostRefreshAutoQualification['host.ubuntu.kvm'] = @{ Qualified = $false; Reason = 'platform-unqualified' } }
        }
        It 'uses the highest available restart-tier rung as the ceiling and ignores rungs above Order 4' {
            $rows = @(
                [pscustomobject]@{ Name = 'probe'; Order = 0; Available = $true }
                [pscustomobject]@{ Name = 'reclaim'; Order = 1; Available = $true }
                [pscustomobject]@{ Name = 'start-if-stopped'; Order = 2; Available = $true }
                [pscustomobject]@{ Name = 'restart-if-hung'; Order = 3; Available = $false }
                [pscustomobject]@{ Name = 'reapply-settings'; Order = 5; Available = $true }
            )
            $s = Get-HostRefreshAutoTriggerSupport -HostType 'host.ubuntu.kvm' -Rung $rows
            $s.Available | Should -BeTrue
            $s.Reason | Should -Be 'available'
            $s.MaxRung | Should -Be 'start-if-stopped'
        }
        It 'is unavailable when only the probe rung is available, or when the declaration is empty' {
            $probeOnly = @([pscustomobject]@{ Name = 'probe'; Order = 0; Available = $true }, [pscustomobject]@{ Name = 'reclaim'; Order = 1; Available = $false })
            (Get-HostRefreshAutoTriggerSupport -HostType 'host.ubuntu.kvm' -Rung $probeOnly).Reason | Should -Be 'no-available-restart-rung'
            (Get-HostRefreshAutoTriggerSupport -HostType 'host.ubuntu.kvm' -Rung @()).Reason | Should -Be 'rung-declaration-missing'
        }
    }
}

Describe 'ConvertTo-HostRefreshAutoEvidence -- what counts as a hypervisor fault' {
    It 'classifies an empty or null sweep as none' {
        foreach ($sweep in @($null, @())) {
            $e = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult $sweep
            $e.Verdict | Should -Be 'none'
            $e.ServiceCount | Should -Be 0
            , $e.ProbeReasons | Should -BeOfType [string[]]
            $e.ProbeReasons.Count | Should -Be 0
        }
    }
    It 'classifies one timed-out, unreadable service as fault, with a one-element typed reason list' {
        $e = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row -ProbeReason 'timeout')
        $e.Verdict | Should -Be 'fault'
        $e.TimeoutCount | Should -Be 1
        , $e.ProbeReasons | Should -BeOfType [string[]]
        $e.ProbeReasons.Count | Should -Be 1
        $e.ProbeReasons[0] | Should -Be 'timeout'
    }
    It 'classifies any responsive answer as responsive, even beside timeouts' {
        (ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row -Outcome 'running' -ProbeReason 'responsive')).Verdict | Should -Be 'responsive'
        $mixed = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @((New-Row -ProbeReason 'timeout'), (New-Row -Outcome 'running' -ProbeReason 'responsive'))
        $mixed.Verdict | Should -Be 'responsive'
        $mixed.TimeoutCount | Should -Be 1
        $mixed.ResponsiveCount | Should -Be 1
        ($mixed.ProbeReasons -join ',') | Should -Be 'responsive,timeout'
    }
    It 'never counts a denial, a missing client, no session, unrecognized output or an unprobed row' {
        foreach ($reason in 'permission-denied', 'missing-client', 'no-session', 'invalid-response', 'not-probed', 'provider-error') {
            (ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row -ProbeReason $reason)).Verdict | Should -Be 'none' -Because $reason
        }
    }
    It 'treats a row without a probe reason as unclassified, counting in neither direction' {
        $e = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row)
        $e.Verdict | Should -Be 'none'
        $e.ProbeReasons | Should -Be @('unclassified')
    }
    It 'counts a timeout only on a row whose state could not be read' {
        (ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row -Outcome 'deadline-exhausted' -ProbeReason 'timeout')).Verdict | Should -Be 'none'
    }
    It 'counts every timed-out service and accepts parsed dictionaries as rows' {
        $rows = @(1..3 | ForEach-Object { @{ Outcome = 'state-unknown'; ProbeReason = 'timeout' } })
        $e = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult $rows
        $e.Verdict | Should -Be 'fault'
        $e.TimeoutCount | Should -Be 3
        $e.ServiceCount | Should -Be 3
        $e.ProbeReasons | Should -Be @('timeout')
    }
    It 'maps a reason that is not a token to unclassified so no free text reaches the served file' {
        (ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult @(New-Row -ProbeReason 'Timed out: see /home/x')).ProbeReasons | Should -Be @('unclassified')
    }
}

Describe 'Write-/Read-HostRefreshAutoEvidence -- the file across the process boundary' {
    BeforeEach {
        $script:Rt = New-CaseDir -Name 'runtime'
        $script:EvidencePath = Join-Path $script:Rt 'runner.refresh-evidence.json'
    }

    It 'writes nothing for a malformed or empty generation' {
        foreach ($generation in '', 'nope', "$('A' * 32):1", "$($script:Instance):0") {
            Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $generation -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false |
                Should -BeFalse -Because "generation '$generation'"
        }
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'writes nothing for a phase outside the allowlist' {
        Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'git-pull' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false |
            Should -BeFalse
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'writes nothing when the runtime directory is missing, and never throws' {
        Write-HostRefreshAutoEvidence -RuntimeDir (Join-Path $script:Rt 'gone') -Generation (New-Generation 1) -Phase 'service-vm-restore' -Confirm:$false | Should -BeFalse
        Write-HostRefreshAutoEvidence -RuntimeDir '' -Generation (New-Generation 1) -Phase 'service-vm-restore' -Confirm:$false | Should -BeFalse
    }
    It 'names a write failure by a token, never by the exception text' {
        $script:Reasons = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.HostRefreshTrigger Write-YurunaStateFileJson { throw [System.UnauthorizedAccessException]::new('denied /home/someone/private') }
        Mock -ModuleName Test.HostRefreshTrigger Format-YurunaOperatorMessage {
            if ($Key -eq 'runner.host_refresh_evidence_write_failed') { $script:Reasons.Add([string]$Arguments['reason']) }
            "KEY:$Key"
        }
        Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false -WarningAction SilentlyContinue |
            Should -BeFalse
        $script:Reasons | Should -Be @('system.unauthorizedaccessexception')
    }
    It 'writes nothing under -WhatIf' {
        Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -WhatIf |
            Should -BeFalse
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'round-trips a matched record carrying tokens and counts only' {
        $clock = { Set-TestUtc '2026-09-25T10:11:12' }
        Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 7) -Phase 'service-vm-restore' `
            -ServiceRestoreResult @(New-Row -ProbeReason 'timeout' -VMName 'secret-service-vm') -HostType 'host.macos.utm' `
            -HostId '42ABCDEF0123456789abcdef01234567' -NowUtc $clock -Confirm:$false | Should -BeTrue
        $text = Get-Content -LiteralPath $script:EvidencePath -Raw
        $text | Should -Not -Match 'secret-service-vm'
        $doc = $text | ConvertFrom-Json -AsHashtable
        ($doc.Keys | Sort-Object) -join ',' | Should -Be 'generation,hostId,hostType,kind,observedUtc,phase,probeReasons,responsiveCount,schemaVersion,serviceCount,timeoutCount,verdict,writerPid'
        $doc.hostId | Should -Be '42abcdef0123456789abcdef01234567'
        $read = Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 7)
        $read.Matched | Should -BeTrue
        $read.Reason | Should -Be 'matched'
        $read.Verdict | Should -Be 'fault'
        $read.Phase | Should -Be 'service-vm-restore'
        , $read.ProbeReasons | Should -BeOfType [string[]]
        $read.ProbeReasons | Should -Be @('timeout')
        $read.ObservedUtc | Should -Be '2026-09-25T10:11:12.0000000Z'
        Test-Path -LiteralPath $script:EvidencePath | Should -BeTrue -Because 'a read without -Consume leaves the file'
    }
    It 'drops a host type or host id of the wrong shape' {
        Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 2) -Phase 'service-vm-restore' -HostType 'host.evil' -HostId '../../etc' -Confirm:$false | Should -BeTrue
        $doc = Get-Content -LiteralPath $script:EvidencePath -Raw | ConvertFrom-Json -AsHashtable
        $doc.hostType | Should -Be ''
        $doc.hostId | Should -Be ''
    }
    It 'rejects and consumes a file for another cycle' {
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $read = Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 4) -Consume -Confirm:$false
        $read.Matched | Should -BeFalse
        $read.Reason | Should -Be 'generation-mismatch'
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'consumes a matched file' {
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Phase 'service-vm-restore' -Confirm:$false
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Consume -Confirm:$false).Matched | Should -BeTrue
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'reports corrupt JSON as unreadable and still consumes it' {
        Set-Content -LiteralPath $script:EvidencePath -Value '{ not json'
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Consume -Confirm:$false).Reason | Should -Be 'unreadable'
        Test-Path -LiteralPath $script:EvidencePath | Should -BeFalse
    }
    It 'reports a newer schema, a disallowed phase and an unknown verdict' {
        $base = @{ schemaVersion = 1; kind = 'host-refresh-evidence'; generation = (New-Generation 9); phase = 'service-vm-restore'; verdict = 'fault'; probeReasons = @('timeout') }
        $case = $base.Clone(); $case.schemaVersion = 2
        Write-EvidenceFile -RuntimeDir $script:Rt -Record $case
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 9)).Reason | Should -Be 'schema'
        $case = $base.Clone(); $case.phase = 'git-pull'
        Write-EvidenceFile -RuntimeDir $script:Rt -Record $case
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 9)).Reason | Should -Be 'phase-not-allowlisted'
        $case = $base.Clone(); $case.verdict = 'maybe'
        Write-EvidenceFile -RuntimeDir $script:Rt -Record $case
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 9)).Reason | Should -Be 'verdict-invalid'
    }
    It 'reports a missing file and a missing runtime directory as missing' {
        (Read-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1)).Reason | Should -Be 'missing'
        (Read-HostRefreshAutoEvidence -RuntimeDir '' -Generation (New-Generation 1)).Reason | Should -Be 'missing'
    }
}

Describe 'Update-HostRefreshAutoEvidence -- the persisted timeout count' {
    BeforeEach {
        $script:Rt = New-CaseDir -Name 'runtime'
        $script:Streak = Join-Path (New-CaseDir -Name 'private') 'host-refresh.auto-streak.json'
        $script:Clock = { Set-TestUtc '2026-09-25T12:00:00' }
    }

    It 'counts a completed cycle with fault evidence once per generation' {
        $gen = New-Generation 1
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $first = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Outcome 'completed' -StreakPath $script:Streak -NowUtc $script:Clock -Confirm:$false
        $first.Counted | Should -BeTrue
        $first.Streak | Should -Be 1
        $first.StreakPersisted | Should -BeTrue
        $first.Reason | Should -Be 'counted'
        Test-Path -LiteralPath (Join-Path $script:Rt 'runner.refresh-evidence.json') | Should -BeFalse
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $again = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Outcome 'completed' -StreakPath $script:Streak -NowUtc $script:Clock -Confirm:$false
        $again.Counted | Should -BeFalse
        $again.Reason | Should -Be 'already-counted'
        $again.Streak | Should -Be 1
        $doc = Get-Content -LiteralPath $script:Streak -Raw | ConvertFrom-Json -AsHashtable
        $doc.kind | Should -Be 'host-refresh-auto-streak'
        $doc.lastCountedGeneration | Should -Be $gen
        @($doc.lastProbeReasons) | Should -Be @('timeout')
    }

    It 'never counts or resets on an outcome other than completed, and still consumes the file' {
        $gen = New-Generation 1
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $null = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $gen -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $before = Get-Content -LiteralPath $script:Streak -Raw
        $cycle = 2
        foreach ($outcome in 'cycle-aborted', 'spawn-failed', 'pull-error', 'paused', 'drain', 'shutdown', 'storage-full', 'refresh-gated', 'refresh-preflight') {
            foreach ($verdictRow in @((New-Row -ProbeReason 'timeout'), (New-Row -Outcome 'running' -ProbeReason 'responsive'))) {
                $g = New-Generation $cycle
                $cycle++
                $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $g -Phase 'service-vm-restore' -ServiceRestoreResult @($verdictRow) -Confirm:$false
                $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $g -Outcome $outcome -StreakPath $script:Streak -Confirm:$false
                $r.Counted | Should -BeFalse -Because $outcome
                $r.Reset | Should -BeFalse -Because $outcome
                $r.Streak | Should -Be 1 -Because $outcome
                $r.Reason | Should -Be 'not-completed'
                Test-Path -LiteralPath (Join-Path $script:Rt 'runner.refresh-evidence.json') | Should -BeFalse -Because "$outcome consumes the file"
            }
        }
        Get-Content -LiteralPath $script:Streak -Raw | Should -Be $before
    }

    It 'resets the count on a responsive observation and keeps it on no evidence' {
        foreach ($c in 1, 2) {
            $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation $c) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
            $null = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation $c) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        }
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'permission-denied') -Confirm:$false
        $none = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 3) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $none.Streak | Should -Be 2
        $none.Reason | Should -Be 'no-fault-evidence'
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 4) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -Outcome 'running' -ProbeReason 'responsive') -Confirm:$false
        $reset = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 4) -Outcome 'completed' -StreakPath $script:Streak -NowUtc $script:Clock -Confirm:$false
        $reset.Reset | Should -BeTrue
        $reset.Streak | Should -Be 0
        (Get-Content -LiteralPath $script:Streak -Raw | ConvertFrom-Json -AsHashtable).streak | Should -Be 0
    }

    It 'restarts a corrupt count at zero and rewrites it' {
        Set-Content -LiteralPath $script:Streak -Value '{"schemaVersion":1,"kind":"host-refresh-auto-streak","streak":"lots"}'
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $r.Streak | Should -Be 1
        $r.Counted | Should -BeTrue
        (Get-Content -LiteralPath $script:Streak -Raw | ConvertFrom-Json -AsHashtable).streak | Should -Be 1
    }

    It 'keeps the count across a runner restart with a new instance id' {
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $null = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $restarted = New-Generation -Cycle 1 -Instance ('b' * 32)
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $restarted -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        (Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation $restarted -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false).Streak | Should -Be 2
    }

    It 'never counts a file written for another cycle' {
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 2) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $r.Counted | Should -BeFalse
        $r.Reason | Should -Be 'generation-mismatch'
        Test-Path -LiteralPath $script:Streak | Should -BeFalse
    }

    It 'counts nothing when the private root is unavailable' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoStatePath { $null }
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -ProbeReason 'timeout') -Confirm:$false
        $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Outcome 'completed' -Confirm:$false
        $r.Counted | Should -BeFalse
        $r.StreakPersisted | Should -BeFalse
        $r.Reason | Should -Be 'private-root-unavailable'
    }

    It 'creates no private state for a responsive host that never counted' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoStatePath { $null }
        $null = Write-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Phase 'service-vm-restore' -ServiceRestoreResult @(New-Row -Outcome 'running' -ProbeReason 'responsive') -Confirm:$false
        $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Outcome 'completed' -Confirm:$false
        $r.Reset | Should -BeFalse
        Should -Invoke Get-HostRefreshAutoStatePath -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly -ParameterFilter { -not $NoCreate }
    }

    It 'reports a failed count write as not counted' {
        Mock -ModuleName Test.HostRefreshTrigger Write-YurunaStateFileJson { $false }
        Set-Content -LiteralPath (Join-Path $script:Rt 'runner.refresh-evidence.json') -Value (@{ schemaVersion = 1; kind = 'host-refresh-evidence'; generation = (New-Generation 1); phase = 'service-vm-restore'; verdict = 'fault'; probeReasons = @('timeout') } | ConvertTo-Json)
        $r = Update-HostRefreshAutoEvidence -RuntimeDir $script:Rt -Generation (New-Generation 1) -Outcome 'completed' -StreakPath $script:Streak -Confirm:$false
        $r.Counted | Should -BeFalse
        $r.Reason | Should -Be 'streak-unwritable'
    }
}

Describe 'Test-HostRefreshAutoBudgetAvailable -- the UTC-day rule' {
    It 'is available on an empty ledger' {
        $r = Test-HostRefreshAutoBudgetAvailable -Reservation @() -NowUtc (Set-TestUtc '2026-09-25T10:00:00')
        $r.Available | Should -BeTrue
        $r.UtcDay | Should -Be '2026-09-25'
    }
    It 'uses the day once it has a reservation, up to the last second of that UTC day' {
        $row = @{ utcDay = '2026-09-25'; reservedUtc = '2026-09-25T00:00:05.0000000Z' }
        (Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc (Set-TestUtc '2026-09-25T10:00:00')).Reason | Should -Be 'daily-budget-used'
        (Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc (Set-TestUtc '2026-09-25T23:59:59')).Reason | Should -Be 'daily-budget-used'
    }
    It 'rolls over at 00:00:00Z' {
        $row = @{ utcDay = '2026-09-25'; reservedUtc = '2026-09-25T23:59:59.0000000Z' }
        $r = Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc (Set-TestUtc '2026-09-26T00:00:00')
        $r.Available | Should -BeTrue
        $r.UtcDay | Should -Be '2026-09-26'
    }
    It 'reads an unspecified or local clock value as the instant it names, not shifted by the host offset' {
        $row = @{ utcDay = '2026-09-25'; reservedUtc = '2026-09-25T23:59:59.0000000Z' }
        $unspecified = [datetime]::new(2026, 9, 26, 0, 0, 0, [DateTimeKind]::Unspecified)
        (Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc $unspecified).Available | Should -BeTrue
        $local = [datetime]::SpecifyKind([datetime]::new(2026, 9, 26, 0, 0, 0), [DateTimeKind]::Utc).ToLocalTime()
        (Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc $local).UtcDay | Should -Be '2026-09-26'
    }
    It 'refuses when the clock went backwards' {
        (Test-HostRefreshAutoBudgetAvailable -Reservation @(@{ utcDay = '2026-09-26'; reservedUtc = '2026-09-26T01:00:00Z' }) -NowUtc (Set-TestUtc '2026-09-25T10:00:00')).Reason |
            Should -Be 'clock-rollback'
        (Test-HostRefreshAutoBudgetAvailable -Reservation @(@{ utcDay = '2026-09-24'; reservedUtc = '2026-09-25T10:05:01Z' }) -NowUtc (Set-TestUtc '2026-09-25T10:00:00')).Reason |
            Should -Be 'clock-rollback'
        (Test-HostRefreshAutoBudgetAvailable -Reservation @(@{ utcDay = '2026-09-24'; reservedUtc = '2026-09-25T10:04:59Z' }) -NowUtc (Set-TestUtc '2026-09-25T10:00:00')).Available |
            Should -BeTrue -Because 'within the skew allowance'
    }
    It 'fails closed on a row it cannot parse' {
        foreach ($row in @(@{ utcDay = '25/09/2026'; reservedUtc = '2026-09-25T00:00:00Z' }, @{ utcDay = '2026-09-25' }, 'junk')) {
            (Test-HostRefreshAutoBudgetAvailable -Reservation @($row) -NowUtc (Set-TestUtc '2026-09-27T10:00:00')).Reason | Should -Be 'malformed-reservation'
        }
    }
}

Describe 'The budget ledger -- reservation, outcome and failure modes' {
    BeforeEach {
        $dir = New-CaseDir -Name 'ledger'
        $script:Budget = Join-Path $dir 'host-refresh.auto-budget.record'
        $script:LockPath = Join-Path $dir 'host-refresh.admission.lock'
        $script:Now = Set-TestUtc '2026-09-25T10:00:00'
        $script:Lock = Enter-YurunaSingleFlightLock -Path $script:LockPath -WaitMilliseconds 1000 -Rank (Get-YurunaLockRank -Name Admission)
    }
    AfterEach { Exit-YurunaSingleFlightLock -Lock $script:Lock }

    It 'reads a missing ledger as empty' {
        $b = Get-HostRefreshAutoBudget -BudgetPath $script:Budget
        $b.Status | Should -Be 'missing'
        @($b.Reservations).Count | Should -Be 0
    }
    It 'writes a reservation through the critical record and refuses a second one the same day' {
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Written | Should -BeTrue
        $r.UtcDay | Should -Be '2026-09-25'
        $b = Get-HostRefreshAutoBudget -BudgetPath $script:Budget
        $b.Status | Should -Be 'ok'
        $rows = @($b.Reservations)
        $rows.Count | Should -Be 1
        $rows[0].requestId | Should -Be $script:RequestId
        $rows[0].utcDay | Should -Be '2026-09-25'
        $rows[0].outcome | Should -BeNullOrEmpty
        $second = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId ([guid]::NewGuid().ToString('D')) -Generation (New-Generation 5) -HostType 'host.macos.utm' -NowUtc $script:Now.AddHours(1) -Confirm:$false
        $second.Written | Should -BeFalse
        $second.Reason | Should -Be 'daily-budget-used'
    }
    It 'refuses without the admission lock held' {
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock ([pscustomobject]@{ Held = $true; Handle = $null }) -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Reason | Should -Be 'admission-lock-not-held'
        Test-Path -LiteralPath $script:Budget | Should -BeFalse
    }
    It 'reports a failed critical write as unwritable' {
        Mock -ModuleName Test.HostRefreshTrigger Write-YurunaCriticalRecord { [pscustomobject]@{ Committed = $false; Reason = 'disk-full' } }
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Written | Should -BeFalse
        $r.Reason | Should -Be 'budget-unwritable'
    }
    It 'prunes only rows older than the retention period and keeps the ledger bounded' {
        $rows = @(100..599 | ForEach-Object {
                $day = $script:Now.Date.AddDays(-$_)
                [ordered]@{ utcDay = $day.ToString('yyyy-MM-dd'); reservedUtc = $day.AddHours(3).ToString('o'); requestId = [guid]::NewGuid().ToString('D'); generation = ''; hostType = 'host.macos.utm'; outcome = 'partial'; outcomeUtc = $null }
            })
        $seed = Write-YurunaCriticalRecord -Path $script:Budget -Kind 'host-refresh-auto-budget' -Payload ([ordered]@{ schemaVersion = 1; kind = 'host-refresh-auto-budget'; reservations = $rows }) -ExpectedGeneration 0 -Confirm:$false
        $seed.Committed | Should -BeTrue
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Written | Should -BeTrue
        $after = @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations)
        $after.Count | Should -Be 302 -Because 'days 100..400 ago stay (301 rows) and today is added'
        $oldest = ($after | ForEach-Object { $_.utcDay } | Sort-Object | Select-Object -First 1)
        $oldest | Should -Be $script:Now.Date.AddDays(-400).ToString('yyyy-MM-dd')
    }
    It 'never prunes or overrides a future row: the ledger refuses and stays unchanged' {
        $future = [ordered]@{ utcDay = '2026-10-01'; reservedUtc = '2026-10-01T01:00:00.0000000Z'; requestId = [guid]::NewGuid().ToString('D'); generation = ''; hostType = 'host.macos.utm'; outcome = $null; outcomeUtc = $null }
        $null = Write-YurunaCriticalRecord -Path $script:Budget -Kind 'host-refresh-auto-budget' -Payload ([ordered]@{ schemaVersion = 1; kind = 'host-refresh-auto-budget'; reservations = @($future) }) -ExpectedGeneration 0 -Confirm:$false
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Reason | Should -Be 'clock-rollback'
        @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations).Count | Should -Be 1
    }
    It 'reads a damaged ledger, a ledger of another shape and an unreadable path as unavailable' {
        Set-Content -LiteralPath $script:Budget -Value 'garbage'
        (Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Status | Should -Be 'corrupt'
        Remove-Item -LiteralPath $script:Budget -Force
        $null = Write-YurunaCriticalRecord -Path $script:Budget -Kind 'host-refresh-auto-budget' -Payload @{ schemaVersion = 1; kind = 'something-else'; reservations = @() } -ExpectedGeneration 0 -Confirm:$false
        (Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Status | Should -Be 'corrupt'
        $dirPath = Join-Path (Split-Path -Parent $script:Budget) 'as-directory.record'
        $null = New-Item -ItemType Directory -Path $dirPath
        (Get-HostRefreshAutoBudget -BudgetPath $dirPath).Status | Should -Be 'unreadable'
        $r = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $script:Lock -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        $r.Reason | Should -Be 'budget-unreadable'
    }
    It 'reports a missing critical-record writer as writer-unavailable' {
        Mock -ModuleName Test.HostRefreshTrigger Resolve-HostRefreshAutoCommand {
            [pscustomobject]@{ Resolved = $false; Reason = 'dependency-missing:Test.CriticalRecord'; Module = 'Test.CriticalRecord'; Command = 'Read-YurunaCriticalRecord' }
        } -ParameterFilter { $Name -contains 'Read-YurunaCriticalRecord' }
        (Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Status | Should -Be 'writer-unavailable'
    }
    It 'records an outcome on the reservation row without freeing the day' {
        Exit-YurunaSingleFlightLock -Lock $script:Lock
        $held = Enter-YurunaSingleFlightLock -Path $script:LockPath -WaitMilliseconds 1000 -Rank (Get-YurunaLockRank -Name Admission)
        $null = Add-HostRefreshAutoReservation -BudgetPath $script:Budget -AdmissionLock $held -RequestId $script:RequestId -Generation (New-Generation 4) -HostType 'host.macos.utm' -NowUtc $script:Now -Confirm:$false
        Exit-YurunaSingleFlightLock -Lock $held
        Set-HostRefreshAutoReservationOutcome -BudgetPath $script:Budget -RequestId $script:RequestId -Verdict 'partial' -NowUtc $script:Now.AddMinutes(20) -AdmissionLockPath $script:LockPath -Confirm:$false |
            Should -BeTrue
        $rows = @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations)
        $rows.Count | Should -Be 1
        $rows[0].outcome | Should -Be 'partial'
        (Test-HostRefreshAutoBudgetAvailable -Reservation $rows -NowUtc $script:Now.AddHours(2)).Reason | Should -Be 'daily-budget-used'
        Set-HostRefreshAutoReservationOutcome -BudgetPath $script:Budget -RequestId ([guid]::NewGuid().ToString('D')) -Verdict 'failed' -NowUtc $script:Now -AdmissionLockPath $script:LockPath -Confirm:$false |
            Should -BeFalse
        $script:Lock = $null
    }
}

Describe 'Get-HostRefreshAutoThreshold -- the knob, the pool override and the floor' {
    BeforeAll {
        function New-KnobConfig {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes a throwaway config fixture.')]
            [CmdletBinding()]
            param([string]$Body)
            $p = Join-Path (New-CaseDir -Name 'config') 'test.config.yml'
            Set-Content -LiteralPath $p -Value $Body
            $p
        }
    }
    It 'reads the local value, treats a missing key as off and raises 1 to 2' {
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 3") | Should -Be 3
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  cycleDelaySeconds: 30") | Should -Be 0
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 0") | Should -Be 0
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 1") | Should -Be 2
    }
    It 'lets a pool override win both ways, including a fleet-wide 0' {
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 0") -PoolTestCycleOverride @{ autoRefreshAfterStalls = 2 } | Should -Be 2
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 2") -PoolTestCycleOverride @{ autoRefreshAfterStalls = 0 } | Should -Be 0
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 0") -PoolTestCycleOverride @{ autoRefreshAfterStalls = 1 } | Should -Be 2
    }
    It 'ignores an invalid pool value' {
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 3") -PoolTestCycleOverride @{ autoRefreshAfterStalls = 'lots' } | Should -Be 3
        Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: 3") -PoolTestCycleOverride @{ autoRefreshAfterStalls = -2 } | Should -Be 3
    }
    It 'turns an invalid or negative local value off with a keyed warning' {
        Mock -ModuleName Test.HostRefreshTrigger Format-YurunaOperatorMessage { "KEY:$Key" }
        foreach ($bad in 'two', '-1', '2.5') {
            $warnings = @(Get-HostRefreshAutoThreshold -ConfigPath (New-KnobConfig "testCycle:`n  autoRefreshAfterStalls: $bad") 3>&1)
            $value = @($warnings | Where-Object { $_ -is [int] })
            $value | Should -Be @(0) -Because $bad
            @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and $_.Message -eq 'KEY:runner.host_refresh_auto_knob_invalid' }).Count |
                Should -Be 1 -Because $bad
        }
    }
    It 'is off for a config that cannot be read' {
        Get-HostRefreshAutoThreshold -ConfigPath (Join-Path $script:SuiteTemp 'no-such.yml') | Should -Be 0
        Get-HostRefreshAutoThreshold -ConfigPath '' | Should -Be 0
    }
}

Describe 'Get-HostRefreshAutoPoolContext -- the pulled pool intent' {
    AfterEach {
        Remove-Item -LiteralPath 'Function:\Sync-YurunaPoolIntent', 'Function:\Resolve-YurunaPoolDesiredState', 'Function:\Get-YurunaPoolConfig' -ErrorAction SilentlyContinue
    }
    It 'is run for a host with no pool sync loaded' {
        $c = Get-HostRefreshAutoPoolContext
        $c.DesiredState | Should -Be 'run'
        $c.Source | Should -Be 'no-pool-sync'
    }
    It 'is unknown when the pull throws' {
        function global:Sync-YurunaPoolIntent { [CmdletBinding()] [OutputType([hashtable])] param() throw 'network' }
        function global:Resolve-YurunaPoolDesiredState { [CmdletBinding()] [OutputType([string])] param($Pool) $null = $Pool; 'run' }
        $c = Get-HostRefreshAutoPoolContext
        $c.DesiredState | Should -Be 'unknown'
        $c.Source | Should -Be 'error'
    }
    It 'is unknown when pool sync is on but the pull produced no pool record for this host' {
        function global:Sync-YurunaPoolIntent { [CmdletBinding()] [OutputType([hashtable])] param() $null }
        function global:Resolve-YurunaPoolDesiredState { [CmdletBinding()] [OutputType([string])] param($Pool) $null = $Pool; 'run' }
        function global:Get-YurunaPoolConfig { [CmdletBinding()] [OutputType([pscustomobject])] param($Config, [switch]$IgnoreEnabled) $null = $Config, $IgnoreEnabled; [pscustomobject]@{ Enabled = $true; IntentGitUrl = 'http://p/i.git' } }
        $c = Get-HostRefreshAutoPoolContext
        $c.DesiredState | Should -Be 'unknown' -Because 'the runner cycles as a single host, but an unattended restart cannot tell a paused fleet from an unreadable one'
        $c.Source | Should -Be 'no-pool-record'
    }
    It 'is run when pool sync is off in the configuration' {
        function global:Sync-YurunaPoolIntent { [CmdletBinding()] [OutputType([hashtable])] param() $null }
        function global:Resolve-YurunaPoolDesiredState { [CmdletBinding()] [OutputType([string])] param($Pool) $null = $Pool; 'run' }
        function global:Get-YurunaPoolConfig { [CmdletBinding()] [OutputType([pscustomobject])] param($Config, [switch]$IgnoreEnabled) if ($Config -or $IgnoreEnabled) { return $null }; return $null }
        $c = Get-HostRefreshAutoPoolContext
        $c.DesiredState | Should -Be 'run'
        $c.Source | Should -Be 'no-pool-sync'
    }
    It 'returns the desired state and the pool testCycle map' {
        function global:Sync-YurunaPoolIntent { [CmdletBinding()] [OutputType([hashtable])] param() @{ desiredState = 'paused'; config = @{ testCycle = @{ autoRefreshAfterStalls = 2 } } } }
        function global:Resolve-YurunaPoolDesiredState { [CmdletBinding()] [OutputType([string])] param($Pool) [string]$Pool['desiredState'] }
        $c = Get-HostRefreshAutoPoolContext
        $c.DesiredState | Should -Be 'paused'
        $c.Source | Should -Be 'pull'
        $c.TestCycleOverride['autoRefreshAfterStalls'] | Should -Be 2
    }
}

Describe 'Request-HostRefreshAutoAttempt -- budget, decision, reservation, request under one lock' {
    BeforeEach {
        $dir = New-CaseDir -Name 'admission'
        $script:Budget = Join-Path $dir 'host-refresh.auto-budget.record'
        $script:LockPath = Join-Path $dir 'host-refresh.admission.lock'
        $script:Runtime = New-CaseDir -Name 'runtime'
        $script:Now = Set-TestUtc '2026-09-25T10:00:00'
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:Seen = @{}
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoStatePath { $script:Budget }
        Mock -ModuleName Test.HostRefreshTrigger Get-YurunaHostRefreshAdmissionLockPath { $script:LockPath }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAdmissionDecision {
            $script:Order.Add('decision')
            $script:Seen.DecisionLockOwned = Test-YurunaSingleFlightLockOwned -Lock $AdmissionLock
            [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId }
        }
        Mock -ModuleName Test.HostRefreshTrigger Request-HostRefreshAdmission {
            $script:Order.Add('request')
            $script:Seen.Bound = @($PSBoundParameters.Keys)
            $script:Seen.Channel = $Channel
            $script:Seen.Tier = $Tier
            $script:Seen.Context = $Context
            $script:Seen.ReservationFirst = (@((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations | Where-Object { $_.requestId -eq $RequestId }).Count -eq 1)
            [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId }
        }
        $script:Call = @{
            HostType = 'host.macos.utm'; Generation = (New-Generation 6); Streak = 2; MaxRung = 'restart-if-hung'
            RuntimeDir = $script:Runtime; ConfigPath = '/cfg/test.config.yml'
            CallerOuter = @{ Pid = 4242; StartTimeUnixMs = [long]1790000000000 }
            Evidence = (New-Accounting).Evidence; NowUtc = $script:Now; AdmissionWaitMs = 300
        }
    }

    It 'reserves the day before creating the request, and passes no policy of its own' {
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Admitted | Should -BeTrue
        $r.RequestId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        ($script:Order -join ',') | Should -Be 'decision,request'
        $script:Seen.DecisionLockOwned | Should -BeTrue
        $script:Seen.ReservationFirst | Should -BeTrue
        $script:Seen.Channel | Should -Be 'automatic'
        $script:Seen.Tier | Should -Be 'restart'
        foreach ($forbidden in 'Force', 'AllowHardStop', 'Policy', 'RestoreServiceVmName', 'LeaveStoppedServiceVmName') {
            $script:Seen.Bound | Should -Not -Contain $forbidden
        }
        $script:Seen.Context.callerOuter.pid | Should -Be 4242
        $script:Seen.Context.callerOuter.startTimeUnixMs | Should -Be 1790000000000
        $script:Seen.Context.configPath | Should -Be '/cfg/test.config.yml'
        $script:Seen.Context.trigger.generation | Should -Be (New-Generation 6)
        $script:Seen.Context.trigger.phase | Should -Be 'service-vm-restore'
        $script:Seen.Context.trigger.streak | Should -Be 2
        , $script:Seen.Context.trigger.probeReasons | Should -BeOfType [string[]]
        @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations)[0].requestId | Should -Be $r.RequestId
    }

    It 'refuses a second attempt the same UTC day without asking for admission' {
        $null = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $script:Order.Clear()
        $script:Call.NowUtc = $script:Now.AddHours(5)
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Admitted | Should -BeFalse
        $r.Reason | Should -Be 'daily-budget-used'
        $script:Order.Count | Should -Be 0
    }

    It 'consumes no budget when another request is active' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAdmissionDecision { [pscustomobject]@{ Decision = 'busy'; ActiveRequestId = 'x' } }
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Reason | Should -Be 'host-refresh-active'
        Test-Path -LiteralPath $script:Budget | Should -BeFalse
        Should -Invoke Request-HostRefreshAdmission -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
    }

    It 'creates no request when the reservation cannot be written' {
        Mock -ModuleName Test.HostRefreshTrigger Write-YurunaCriticalRecord { [pscustomobject]@{ Committed = $false; Reason = 'io-error' } }
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Admitted | Should -BeFalse
        $r.Reason | Should -Be 'budget-unwritable'
        Should -Invoke Request-HostRefreshAdmission -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
    }

    It 'keeps the day used when the request write fails after the reservation' {
        Mock -ModuleName Test.HostRefreshTrigger Request-HostRefreshAdmission { [pscustomobject]@{ Decision = 'unavailable'; Reason = 'journal-unwritable' } }
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Admitted | Should -BeFalse
        $r.Reason | Should -Be 'request-write-failed'
        @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations).Count | Should -Be 1
    }

    It 'refuses on a damaged ledger and on a malformed row' {
        Set-Content -LiteralPath $script:Budget -Value 'garbage'
        (Request-HostRefreshAutoAttempt @script:Call -Confirm:$false).Reason | Should -Be 'budget-unreadable'
        Remove-Item -LiteralPath $script:Budget -Force
        $null = Write-YurunaCriticalRecord -Path $script:Budget -Kind 'host-refresh-auto-budget' -Payload @{ schemaVersion = 1; kind = 'host-refresh-auto-budget'; reservations = @(@{ utcDay = 'yesterday' }) } -ExpectedGeneration 0 -Confirm:$false
        (Request-HostRefreshAutoAttempt @script:Call -Confirm:$false).Reason | Should -Be 'malformed-reservation'
    }

    It 'refuses a malformed generation, an empty ceiling and an unset runtime directory before touching anything' {
        $c = $script:Call.Clone(); $c.Generation = 'x'
        (Request-HostRefreshAutoAttempt @c -Confirm:$false).Reason | Should -Be 'generation-invalid'
        $c = $script:Call.Clone(); $c.MaxRung = ''
        (Request-HostRefreshAutoAttempt @c -Confirm:$false).Reason | Should -Be 'no-available-restart-rung'
        $c = $script:Call.Clone(); $c.RuntimeDir = ''
        (Request-HostRefreshAutoAttempt @c -Confirm:$false).Reason | Should -Be 'runtime-dir-unset'
        Test-Path -LiteralPath $script:Budget | Should -BeFalse
    }

    It 'names the missing dependency instead of throwing' {
        Mock -ModuleName Test.HostRefreshTrigger Resolve-HostRefreshAutoCommand {
            [pscustomobject]@{ Resolved = $false; Reason = 'dependency-missing:Test.HostRefreshIntent'; Module = 'Test.HostRefreshIntent'; Command = 'Request-HostRefreshAdmission' }
        } -ParameterFilter { $Name -contains 'Request-HostRefreshAdmission' }
        $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
        $r.Reason | Should -Be 'dependency-missing:Test.HostRefreshIntent'
        $r.MissingCommand | Should -Be 'Request-HostRefreshAdmission'
    }

    It 'names the refresh-gate reader the journal admission needs, instead of a bare admission refusal' {
        $saved = (Get-Command -Name Get-YurunaRefreshGateState -CommandType Function).ScriptBlock
        $module = Get-Module Test.HostRefreshTrigger
        $savedPath = & $module { $script:HostRefreshAutoModulePath['Test.SingleInstance'] }
        try {
            Remove-Item -LiteralPath 'Function:\Get-YurunaRefreshGateState' -ErrorAction SilentlyContinue
            & $module { $script:HostRefreshAutoModulePath['Test.SingleInstance'] = Join-Path $PSScriptRoot 'absent.psm1' }
            $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
            $r.Admitted | Should -BeFalse
            $r.Reason | Should -Be 'dependency-missing:Test.SingleInstance'
            $r.MissingCommand | Should -Be 'Get-YurunaRefreshGateState'
            Test-Path -LiteralPath $script:Budget | Should -BeFalse
            $script:Order.Count | Should -Be 0
        } finally {
            & $module { param($Path) $script:HostRefreshAutoModulePath['Test.SingleInstance'] = $Path } $savedPath
            Set-Item -Path 'Function:global:Get-YurunaRefreshGateState' -Value $saved
        }
    }

    It 'writes nothing under -WhatIf' {
        $r = Request-HostRefreshAutoAttempt @script:Call -WhatIf
        $r.Reason | Should -Be 'preview'
        Test-Path -LiteralPath $script:Budget | Should -BeFalse
    }

    It 'reports admission-busy while another process holds the admission lock' {
        $ready = Join-Path $script:SuiteTemp ("holder-ready-" + [guid]::NewGuid().ToString('N'))
        $release = Join-Path $script:SuiteTemp ("holder-release-" + [guid]::NewGuid().ToString('N'))
        $lockModule = Join-Path $here 'Test.SingleFlightLock.psm1'
        $holderScript = @"
Import-Module '$lockModule' -DisableNameChecking
`$l = Enter-YurunaSingleFlightLock -Path '$($script:LockPath)' -WaitMilliseconds 1000
if (-not `$l.Held) { exit 3 }
Set-Content -LiteralPath '$ready' -Value 'held'
`$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath '$release') -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 50 }
Exit-YurunaSingleFlightLock -Lock `$l
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderScript))
        $holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -PassThru
        try {
            $wait = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $wait -and -not $holder.HasExited) { Start-Sleep -Milliseconds 50 }
            Test-Path -LiteralPath $ready | Should -BeTrue -Because 'the stand-in holder took the lock'
            $r = Request-HostRefreshAutoAttempt @script:Call -Confirm:$false
            $r.Admitted | Should -BeFalse
            $r.Reason | Should -Be 'admission-busy'
            Test-Path -LiteralPath $script:Budget | Should -BeFalse
            $script:Order.Count | Should -Be 0
        } finally {
            Set-Content -LiteralPath $release -Value 'go'
            if (-not $holder.WaitForExit(15000)) { $holder.Kill() }
        }
    }
}

Describe 'Invoke-HostRefreshAutoWorker -- the synchronous, bounded launch' {
    BeforeAll {
        function New-FakeProcess {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory stand-in object; nothing changes.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([int]$ExitAfterWaits = 1, [int]$ExitCode = 0, [switch]$Never)
            $p = [pscustomobject]@{ Id = 31337; Waits = 0; KillCalls = [System.Collections.Generic.List[object]]::new(); Exited = $false; Code = $ExitCode; Limit = $ExitAfterWaits; NeverExit = [bool]$Never }
            $p | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $this.Exited }
            $p | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { $this.Code }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param([int]$Milliseconds)
                $null = $Milliseconds
                $this.Waits++
                if (-not $this.NeverExit -and $this.Waits -ge $this.Limit) { $this.Exited = $true }
                $this.Exited
            }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($EntireTree) $this.KillCalls.Add($EntireTree); $this.Exited = $true }
            $p
        }
    }
    BeforeEach {
        $script:Started = [System.Collections.Generic.List[object]]::new()
        $script:Budget = New-HostRefreshBudget
        $script:SavedNonInteractive = $env:YURUNA_NONINTERACTIVE
        Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($null -eq $script:SavedNonInteractive) { Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue }
        else { $env:YURUNA_NONINTERACTIVE = $script:SavedNonInteractive }
    }

    It 'launches the internal vector only, one element per argument, non-interactive, and restores the environment' {
        $script:Fake = New-FakeProcess -ExitAfterWaits 2 -ExitCode 0
        $starter = { param($FilePath, $ArgumentList) $script:Started.Add([pscustomobject]@{ File = $FilePath; Args = @($ArgumentList); NonInteractive = $env:YURUNA_NONINTERACTIVE }); $script:Fake }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot '/srv/Yuruna Test/repo' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter $starter -Confirm:$false
        $r.Launched | Should -BeTrue
        $r.Reason | Should -Be 'exited'
        $r.ExitCode | Should -Be 0
        $r.WorkerPid | Should -Be 31337
        $script:Started.Count | Should -Be 1
        $call = $script:Started[0]
        $call.File | Should -Be 'pwsh'
        $call.NonInteractive | Should -Be '1'
        $call.Args[0..3] -join ' ' | Should -Be '-NoLogo -NoProfile -NonInteractive -File'
        $call.Args[4] | Should -Be (Join-Path '/srv/Yuruna Test/repo' 'test/lab/Invoke-HostRefresh.ps1') -Because 'a list element needs no quoting and must carry none'
        $call.Args | Should -Contain '-RequestId'
        $call.Args | Should -Contain $script:RequestId
        foreach ($token in $call.Args) { $token | Should -Not -Match '(?i)force|hardstop' }
        $env:YURUNA_NONINTERACTIVE | Should -BeNullOrEmpty -Because 'the variable was unset before the launch'
    }

    It 'restores a caller value of YURUNA_NONINTERACTIVE' {
        $env:YURUNA_NONINTERACTIVE = 'caller'
        $script:Fake = New-FakeProcess
        $null = Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { $script:Fake } -Confirm:$false
        $env:YURUNA_NONINTERACTIVE | Should -Be 'caller'
    }

    It 'stops only its own worker, once, through the handle, when it overruns' {
        $script:Fake = New-FakeProcess -Never
        $script:Ticks = 0L
        $clock = { $script:Ticks += 400000; $script:Ticks }
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { $script:Fake } -ClockTicks $clock -Confirm:$false
        $r.TimedOut | Should -BeTrue
        $r.Killed | Should -BeTrue
        $r.Reason | Should -Be 'worker-timeout'
        $script:Fake.KillCalls.Count | Should -Be 1
        $script:Fake.KillCalls[0] | Should -BeFalse -Because 'Kill($false) stops the worker, never its process tree'
        Should -Invoke Write-HostRefreshAutoLog -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $Key -eq 'runner.host_refresh_auto_worker_timeout' }
    }

    It 'keeps waiting through a shutdown request and says so once' {
        $script:Fake = New-FakeProcess -ExitAfterWaits 4 -ExitCode 2
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ShutdownState @{ Requested = $true } -ProcessStarter { $script:Fake } -Confirm:$false
        $r.ExitCode | Should -Be 2
        $r.TimedOut | Should -BeFalse
        $script:Fake.KillCalls.Count | Should -Be 0
        Should -Invoke Write-HostRefreshAutoLog -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $Key -eq 'runner.host_refresh_auto_waiting_on_worker' }
    }

    It 'reports a start failure as launch-failed' {
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { throw 'no such file' } -Confirm:$false
        $r.Launched | Should -BeFalse
        $r.Reason | Should -Be 'launch-failed'
        Should -Invoke Write-HostRefreshAutoLog -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $Key -eq 'runner.host_refresh_auto_worker_launch_failed' }
    }

    It 'refuses a vector that carries a policy switch, and launches nothing' {
        Mock -ModuleName Test.HostRefreshTrigger New-HostRefreshWorkerArgumentList { @('-NoLogo', '-File', '/r/x.ps1', '-RequestId', $RequestId, '-AllowHardStop') }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { throw 'must not start' } -Confirm:$false
        $r.Reason | Should -Be 'worker-argv-refused'
        $r.Launched | Should -BeFalse
    }

    It 'refuses when the entry script does not accept the internal parameters' {
        Mock -ModuleName Test.HostRefreshTrigger New-HostRefreshWorkerArgumentList { throw 'RequestId is not a parameter of the entry script' }
        (Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { throw 'must not start' } -Confirm:$false).Reason |
            Should -Be 'worker-protocol-mismatch'
    }

    It 'launches nothing under -WhatIf' {
        (Invoke-HostRefreshAutoWorker -RepoRoot '/r' -PwshExe 'pwsh' -RequestId $script:RequestId -Budget $script:Budget -ProcessStarter { throw 'must not start' } -WhatIf).Reason |
            Should -Be 'preview'
    }

    It 'runs a real stand-in worker under a path with spaces and returns its exit code' {
        $dir = New-CaseDir -Name 'stand in'
        $entry = Join-Path $dir 'test/lab/Invoke-HostRefresh.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry) -Force
        $marker = Join-Path $dir 'ran.txt'
        Set-Content -LiteralPath $entry -Value "param([string]`$RequestId, [long]`$DeadlineTickMs, [long]`$PreAdmissionDeadlineTickMs)`nSet-Content -LiteralPath '$marker' -Value `"`$RequestId `$env:YURUNA_NONINTERACTIVE`"`nexit 3"
        $r = Invoke-HostRefreshAutoWorker -RepoRoot $dir -PwshExe (Get-Process -Id $PID).Path -RequestId $script:RequestId -Budget $script:Budget -Confirm:$false
        $r.Reason | Should -Be 'exited'
        $r.ExitCode | Should -Be 3
        (Get-Content -LiteralPath $marker -Raw).Trim() | Should -Be "$($script:RequestId) 1"
    }

    It 'keeps a real stand-in running through a SIGINT, on the handle it was started with' -Skip:([bool]$IsWindows) {
        $dir = New-CaseDir -Name 'sigint'
        $entry = Join-Path $dir 'test/lab/Invoke-HostRefresh.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry) -Force
        $pidFile = Join-Path $dir 'worker.pid'
        $sent = Join-Path $dir 'sent'
        $done = Join-Path $dir 'done'
        Set-Content -LiteralPath $entry -Value (@(
                'param([string]$RequestId, [long]$DeadlineTickMs, [long]$PreAdmissionDeadlineTickMs)'
                "Set-Content -LiteralPath '$pidFile' -Value `$PID"
                "`$deadline = [DateTime]::UtcNow.AddSeconds(30)"
                "while (-not (Test-Path -LiteralPath '$sent') -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 100 }"
                'Start-Sleep -Milliseconds 1500'
                "Set-Content -LiteralPath '$done' -Value 'finished'"
                'exit 5'
            ) -join "`n")
        # A disposable signaler sends SIGINT to the worker's own pid -- what a
        # terminal Ctrl+C delivers to every process in its foreground group.
        $signalerInfo = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
        $signalerInfo.UseShellExecute = $false
        foreach ($argument in @('-c', 'i=0; while [ ! -s "$1" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; kill -INT "$(cat "$1")" && touch "$2"', 'signaler', $pidFile, $sent)) {
            $signalerInfo.ArgumentList.Add($argument)
        }
        $signaler = [System.Diagnostics.Process]::Start($signalerInfo)
        try {
            $r = Invoke-HostRefreshAutoWorker -RepoRoot $dir -PwshExe (Get-Process -Id $PID).Path -RequestId $script:RequestId -Budget $script:Budget -TimeoutSeconds 60 -Confirm:$false
            Test-Path -LiteralPath $sent | Should -BeTrue -Because 'the signal was delivered'
            $r.Reason | Should -Be 'exited'
            $r.ExitCode | Should -Be 5 -Because 'a worker that SIGINT stopped would not reach its own exit'
            (Get-Content -LiteralPath $done -Raw).Trim() | Should -Be 'finished'
            [int](Get-Content -LiteralPath $pidFile -Raw) | Should -Be $r.WorkerPid -Because 'the shell replaced itself, so the handle is the worker'
        } finally {
            if (-not $signaler.WaitForExit(5000)) { $signaler.Kill() }
        }
    }

    It 'stops a real overrunning stand-in without touching the process it started' {
        $dir = New-CaseDir -Name 'overrun'
        $entry = Join-Path $dir 'test/lab/Invoke-HostRefresh.ps1'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry) -Force
        $script:ChildPidFile = Join-Path $dir 'child.pid'
        Set-Content -LiteralPath $entry -Value (@(
                'param([string]$RequestId, [long]$DeadlineTickMs, [long]$PreAdmissionDeadlineTickMs)'
                '$sleepCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Start-Sleep -Seconds 60"))'
                '$c = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @("-NoProfile", "-EncodedCommand", $sleepCommand) -PassThru'
                "Set-Content -LiteralPath '$($script:ChildPidFile)' -Value `$c.Id"
                'Start-Sleep -Seconds 60'
            ) -join "`n")
        $script:Origin = [System.Environment]::TickCount64
        $clock = { $elapsed = [System.Environment]::TickCount64 - $script:Origin; if (Test-Path -LiteralPath $script:ChildPidFile) { $elapsed + 10000000 } else { $elapsed } }
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        $r = Invoke-HostRefreshAutoWorker -RepoRoot $dir -PwshExe (Get-Process -Id $PID).Path -RequestId $script:RequestId -Budget $script:Budget -TimeoutSeconds 60 -ClockTicks $clock -Confirm:$false
        $grandchild = $null
        try {
            $r.TimedOut | Should -BeTrue
            $r.Killed | Should -BeTrue
            Get-Process -Id $r.WorkerPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the worker itself was stopped'
            $grandchild = [int](Get-Content -LiteralPath $script:ChildPidFile -Raw)
            Get-Process -Id $grandchild -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'Kill($false) leaves the worker''s own children alone'
        } finally {
            if ($grandchild) { Stop-Process -Id $grandchild -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Invoke-HostRefreshAutoDecision -- the post-dispatch decision' {
    BeforeEach {
        Clear-LoggedOnce
        $script:Log = [System.Collections.Generic.List[string]]::new()
        $script:Workers = [System.Collections.Generic.List[hashtable]]::new()
        $script:Recorded = [System.Collections.Generic.List[string]]::new()
        $script:Now = Set-TestUtc '2026-09-25T10:00:00'
        $script:Result = New-ResultRecord
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { $script:Log.Add($Key) }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'pull' } }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshActiveRequest { $null }
        Mock -ModuleName Test.HostRefreshTrigger Request-HostRefreshAutoAttempt {
            $script:Log.Add('admission')
            [pscustomobject]@{ Admitted = $true; RequestId = $script:RequestId; Reason = 'admitted'; UtcDay = '2026-09-25'; MissingCommand = '' }
        }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshResult {
            $copy = $script:Result.Clone()
            if (-not $copy.RequestId) { $copy.RequestId = $RequestId }
            [pscustomobject]$copy
        }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoStatePath { '/unused/host-refresh.auto-budget.record' }
        Mock -ModuleName Test.HostRefreshTrigger Set-HostRefreshAutoReservationOutcome { $script:Recorded.Add("$RequestId=$Verdict"); $true }
        $script:Worker = { param($Parameter) $script:Log.Add('worker'); $script:Workers.Add($Parameter); [pscustomobject]@{ Launched = $true; ExitCode = 0; TimedOut = $false; Reason = 'exited' } }
        $script:Clock = { $script:Now }
    }

    It 'is disabled at threshold 0 and pulls no pool state for a cycle without fresh evidence' {
        $state = New-DecisionState -Threshold 0
        $d = Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch failure -Accounting (New-Accounting -Counted $false) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'disabled'
        Should -Invoke Get-HostRefreshAutoPoolContext -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
        $script:Workers.Count | Should -Be 0
    }

    It 'lets a pool override engage a host whose own config is off' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{ autoRefreshAfterStalls = 2 }; Source = 'pull' } }
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState -Threshold 0) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Threshold | Should -Be 2
        $d.Action | Should -Be 'attempted'
    }

    It 'is unavailable on every host type under the shipped declaration, said once per reason' {
        foreach ($hostType in 'host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v') {
            $support = Get-HostRefreshAutoTriggerSupport -HostType $hostType
            foreach ($n in 1, 2) {
                $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle $n -Branch failure -Accounting (New-Accounting) -Support $support -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
                $d.Action | Should -Be 'unavailable'
                $d.Reason | Should -Be $support.Reason
            }
        }
        @($script:Log | Where-Object { $_ -eq 'runner.host_refresh_auto_unavailable' }).Count | Should -Be 2 -Because 'two distinct reasons, each said once'
        $script:Workers.Count | Should -Be 0
        Should -Invoke Request-HostRefreshAutoAttempt -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
    }

    It 'refuses while the pool is paused, draining or unknown, without reserving' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = $script:Desired; TestCycleOverride = @{}; Source = 'pull' } }
        foreach ($desired in 'paused', 'drain', 'unknown') {
            $script:Desired = $desired
            $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Action | Should -Be 'refused'
            $d.Reason | Should -Be "pool-$desired"
        }
        Should -Invoke Request-HostRefreshAutoAttempt -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
    }

    It 'refuses while a shutdown is pending' {
        $state = New-DecisionState
        $state.ShutdownState.Requested = $true
        $d = Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Reason | Should -Be 'shutdown-requested'
        $script:Workers.Count | Should -Be 0
    }

    It 'is unavailable when the protocol file differs from this module or is missing' {
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState -Protocol '2') -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Reason |
            Should -Be 'protocol-mismatch'
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState -Protocol '') -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
            Should -Be 'unavailable'
    }

    It 'is below threshold for a count under it, and for a count at it without fresh evidence' {
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting -Streak 1) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'below-threshold'
        $d.Reason | Should -Be 'streak-below-threshold'
        $script:Log | Should -Contain 'runner.host_refresh_auto_evidence_counted'
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch success -Accounting (New-Accounting -Counted $false -Streak 5 -Verdict 'none') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'below-threshold'
        $d.Reason | Should -Be 'no-fresh-evidence'
        $script:Workers.Count | Should -Be 0
    }

    It 'does nothing for a gated dispatch or an outcome other than completed' {
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
            Should -Be 'none'
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting -Outcome 'storage-full') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
            Should -Be 'none'
        $script:Workers.Count | Should -Be 0
    }

    It 'admits, logs, then runs the worker; a repair on the failure branch skips the pause' {
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'attempted'
        $d.Verdict | Should -Be 'repaired'
        $d.RequestId | Should -Be $script:RequestId
        $d.SkipFailurePause | Should -BeTrue
        $order = @($script:Log | Where-Object { $_ -in 'admission', 'runner.host_refresh_auto_starting', 'worker', 'runner.host_refresh_auto_finished' })
        ($order -join ',') | Should -Be 'admission,runner.host_refresh_auto_starting,worker,runner.host_refresh_auto_finished'
        $script:Workers[0].RequestId | Should -Be $script:RequestId
        $script:Workers[0].Keys | Should -Not -Contain 'AllowHardStop'
        $script:Recorded | Should -Be @("$($script:RequestId)=repaired")
        $script:Log | Should -Not -Contain 'runner.host_refresh_auto_operator_action'
    }

    It 'keeps the failure pause for a repair on the success branch' {
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch success -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).SkipFailurePause |
            Should -BeFalse
    }

    It 'keeps the backoff and asks for an operator on failed, partial and refused' {
        foreach ($verdict in 'failed', 'partial', 'refused', 'still-unresponsive') {
            $script:Result.Verdict = $verdict
            $script:Log.Clear()
            $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Verdict | Should -Be $verdict
            $d.SkipFailurePause | Should -BeFalse
            $script:Log | Should -Contain 'runner.host_refresh_auto_operator_action'
        }
        @($script:Recorded).Count | Should -Be 4
    }

    It 'passes the handoff through for the outer to complete, whatever the verdict' {
        $script:Result = New-ResultRecord -Verdict 'partial'
        $script:Result.Handoff = @{ tokenId = ('c' * 32); purpose = 'resident-outer' }
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Handoff.tokenId | Should -Be ('c' * 32)
        $d.Handoff.purpose | Should -Be 'resident-outer'
        $d.Handoff.RequestId | Should -Be $script:RequestId -Because 'the outer completing the handoff needs the request it belongs to'
        $script:Result.Handoff = [pscustomobject]@{ tokenId = ('e' * 32); purpose = 'resident-outer'; requestId = 'kept-as-recorded' }
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Handoff.RequestId |
            Should -Be 'kept-as-recorded'
        $script:Result.Handoff = @{}
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Handoff |
            Should -BeNullOrEmpty
    }

    It 'believes a recovery-pending result by its attempt end, and keeps its resident-outer handoff' {
        $script:Result = New-ResultRecord -Verdict 'partial' -State 'recovery-pending' -Handoff @{ tokenId = ('c' * 32); purpose = 'resident-outer' }
        $script:Result.OutstandingObligation = [string[]]@('service:caching-proxy')
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'attempted'
        $d.Verdict | Should -Be 'partial'
        $d.Reason | Should -Be 'matched'
        $d.SkipFailurePause | Should -BeFalse
        $d.Handoff.tokenId | Should -Be ('c' * 32)
        $d.Handoff.purpose | Should -Be 'resident-outer'
        $d.Handoff.RequestId | Should -Be $script:RequestId
        $script:Recorded | Should -Be @("$($script:RequestId)=partial")
        $script:Log | Should -Not -Contain 'runner.host_refresh_auto_verdict_mismatch'
    }

    It 'still passes the handoff through when the result is stale' {
        $script:Result = New-ResultRecord -Verdict 'partial' -State 'recovery-pending' -EndedUtc '2026-09-25T09:00:00.0000000Z' -Handoff @{ tokenId = ('c' * 32); purpose = 'resident-outer' }
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Verdict | Should -Be 'failed'
        $d.Reason | Should -Be 'stale-result'
        $d.Handoff.tokenId | Should -Be ('c' * 32) -Because 'a gate left in handoff holds every spawn until the outer completes it'
    }

    It 'falls back to the terminal time for a record that keeps no attempt' {
        $script:Result.LastAttemptEndedUtc = $null
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Verdict | Should -Be 'repaired'
        $d.Reason | Should -Be 'matched'
    }

    It 'treats a result that does not match the launch as failed' {
        $cases = @(
            @{ Name = 'result-missing'; Change = { $script:Result.Found = $false } }
            @{ Name = 'request-mismatch'; Change = { $script:Result.RequestId = [guid]::NewGuid().ToString('D') } }
            @{ Name = 'channel-mismatch'; Change = { $script:Result.Channel = 'local' } }
            @{ Name = 'stale-result'; Change = { $script:Result.CompletedUtc = '2026-09-25T09:00:00.0000000Z'; $script:Result.LastAttemptEndedUtc = '2026-09-25T09:00:00.0000000Z' } }
            @{ Name = 'stale-result'; Change = { $script:Result.LastAttemptEndedUtc = '2026-09-25T09:00:00.0000000Z' } }
            @{ Name = 'stale-result'; Change = { $script:Result.CompletedUtc = $null; $script:Result.LastAttemptEndedUtc = $null } }
            @{ Name = 'readiness-mismatch'; Change = { $script:Result.RunnerReadiness = 'restarted-ready' } }
            @{ Name = 'probe-not-responsive'; Change = { $script:Result.FinalProbeState = 'Undetermined' } }
        )
        foreach ($case in $cases) {
            $script:Result = New-ResultRecord
            & $case.Change
            $script:Log.Clear()
            $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Verdict | Should -Be 'failed' -Because $case.Name
            $d.Reason | Should -Be $case.Name
            $d.SkipFailurePause | Should -BeFalse -Because $case.Name
            $script:Log | Should -Contain 'runner.host_refresh_auto_verdict_mismatch'
        }
    }

    It 'reports a worker overrun and a failed launch as their own verdicts' {
        $timeoutWorker = { param($Parameter) $null = $Parameter; [pscustomobject]@{ Launched = $true; TimedOut = $true; Killed = $true; Reason = 'worker-timeout' } }
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $timeoutWorker -NowUtc $script:Clock -Confirm:$false).Verdict |
            Should -Be 'worker-timeout'
        Mock -ModuleName Test.HostRefreshTrigger Set-HostRefreshLaunchOutcome { [pscustomobject]@{ Saved = $true } }
        $failedWorker = { param($Parameter) $null = $Parameter; [pscustomobject]@{ Launched = $false; TimedOut = $false; Reason = 'launch-failed' } }
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $failedWorker -NowUtc $script:Clock -Confirm:$false).Verdict |
            Should -Be 'launch-failed'
        Should -Invoke Set-HostRefreshLaunchOutcome -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'launch-failed' }
    }

    It 'refuses a missing or foreign generation' {
        $state = New-DecisionState
        $state.Remove('CycleGeneration')
        (Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Reason |
            Should -Be 'generation-missing'
        $state = New-DecisionState
        $state.CycleGeneration = New-Generation -Cycle 5 -Instance ('d' * 32)
        (Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Reason |
            Should -Be 'generation-mismatch'
    }

    It 'reports a missing dependency once and never throws' {
        Mock -ModuleName Test.HostRefreshTrigger Request-HostRefreshAutoAttempt {
            [pscustomobject]@{ Admitted = $false; RequestId = $null; Reason = 'dependency-missing:Test.HostRefreshIntent'; UtcDay = '2026-09-25'; MissingCommand = 'Request-HostRefreshAdmission' }
        }
        foreach ($n in 1, 2) {
            $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle $n -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Action | Should -Be 'unavailable'
        }
        @($script:Log | Where-Object { $_ -eq 'runner.host_refresh_auto_dependency_missing' }).Count | Should -Be 1
    }

    It 'turns an unexpected failure into Action error instead of throwing into the loop' {
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoThreshold { throw 'boom' }
        $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
        $d.Action | Should -Be 'error'
        $d.SkipFailurePause | Should -BeFalse
        $script:Log | Should -Contain 'runner.host_refresh_auto_error'
    }

    It 'decides nothing under -WhatIf' {
        (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -WhatIf).Reason |
            Should -Be 'preview'
        $script:Workers.Count | Should -Be 0
    }

    Context 'resuming an interrupted automatic request' {
        BeforeEach {
            $script:OwnStart = Get-OwnStartTime
            $script:Active = @{ requestId = $script:RequestId; channel = 'automatic'; state = 'recovery-pending'; attempt = 1
                createdUtc = '2026-09-25T09:00:00.0000000Z'
                context = @{ configPath = '/cfg/test.config.yml'; callerOuter = @{ pid = $PID; startTimeUnixMs = $script:OwnStart }; trigger = $null }
                attempts = @(@{ attempt = 1; finishedUtc = '2026-09-25T09:54:59.0000000Z'; worker = @{ pid = 999999; startTimeUnixMs = 1 } })
                obligations = @(@{ id = 'service:caching-proxy'; status = 'armed' }) }
            Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshActiveRequest { $script:Active }
        }
        It 'relaunches the same request for restoration, with no new reservation, on any branch' {
            $d = Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated' -Counted $false) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Action | Should -Be 'resumed'
            $d.RequestId | Should -Be $script:RequestId
            $script:Workers[0].RequestId | Should -Be $script:RequestId
            $script:Log | Should -Contain 'runner.host_refresh_auto_resuming'
            Should -Invoke Request-HostRefreshAutoAttempt -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
        }
        It 'waits for the spacing interval, and treats a future timestamp as age zero' {
            $script:Active.attempts = @(@{ attempt = 1; finishedUtc = '2026-09-25T09:55:01.0000000Z' })
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            $script:Active.attempts = @(@{ attempt = 1; finishedUtc = '2026-09-26T09:00:00.0000000Z' })
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            $script:Workers.Count | Should -Be 0
        }
        It 'stops at the attempt cap, and never resumes a request of another channel' {
            $script:Active.attempt = 3
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            $script:Active.attempt = 1
            $script:Active.channel = 'local'
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            $script:Workers.Count | Should -Be 0
        }
        It 'never resumes a request recorded for another runner process, and says so once' {
            foreach ($caller in @(
                    @{ pid = $PID + 100000; startTimeUnixMs = $script:OwnStart },
                    @{ pid = $PID; startTimeUnixMs = $script:OwnStart - 60000 })) {
                $script:Active.context.callerOuter = $caller
                Clear-LoggedOnce
                $script:Log.Clear()
                foreach ($n in 5, 6) {
                    (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle $n -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                        Should -Be 'none'
                }
                @($script:Log | Where-Object { $_ -eq 'runner.host_refresh_auto_resume_caller_changed' }).Count | Should -Be 1
            }
            $script:Workers.Count | Should -Be 0
        }
        It 'resumes a request that recorded no caller, which the worker finds through its own ancestry' {
            $script:Active.context.callerOuter = $null
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'resumed'
        }
        It 'resumes a running request only once its recorded worker is positively dead' {
            $script:Active.state = 'running'
            $script:Active.attempts = @(@{ attempt = 1; claimedUtc = '2026-09-25T09:30:00.0000000Z'; worker = @{ pid = $PID; startTimeUnixMs = $script:OwnStart } })
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none' -Because 'the recorded worker is alive'
            $script:Active.attempts[0].worker = @{ pid = $PID; startTimeUnixMs = $null }
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 6 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none' -Because 'a worker without a start time is unknown, which counts as alive'
            $script:Workers.Count | Should -Be 0
            $script:Active.attempts[0].worker = @{ pid = $PID; startTimeUnixMs = $script:OwnStart - 3600000 }
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 7 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'resumed' -Because 'a pid with another start time is a recycled pid: the recorded worker is gone'
            $script:Workers.Count | Should -Be 1
        }
        It 'with the knob at 0 resumes only a request that restores, and says once why it leaves the other' {
            $state = New-DecisionState -Threshold 0
            (Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'resumed' -Because 'an armed obligation makes the run restoration only'
            $script:Active.state = 'queued'
            $script:Active.obligations = @()
            $script:Active.attempts = @()
            $script:Active.createdUtc = '2026-09-25T09:00:00.0000000Z'
            foreach ($n in 6, 7) {
                (Invoke-HostRefreshAutoDecision -State $state -Cycle $n -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                    Should -Be 'none'
            }
            $script:Workers.Count | Should -Be 1
            @($script:Log | Where-Object { $_ -eq 'runner.host_refresh_auto_resume_disabled' }).Count | Should -Be 1
            $d = Invoke-HostRefreshAutoDecision -State $state -Cycle 8 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false
            $d.Action | Should -Be 'disabled'
            $script:Workers.Count | Should -Be 1
        }
        It 'holds a resume while the pool is not run or a shutdown is pending' {
            Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'paused'; TestCycleOverride = @{}; Source = 'pull' } }
            (Invoke-HostRefreshAutoDecision -State (New-DecisionState) -Cycle 5 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'pull' } }
            $state = New-DecisionState
            $state.ShutdownState.Requested = $true
            (Invoke-HostRefreshAutoDecision -State $state -Cycle 6 -Branch gated -Accounting (New-Accounting -Outcome 'refresh-gated') -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc $script:Clock -Confirm:$false).Action |
                Should -Be 'none'
            $script:Workers.Count | Should -Be 0
        }
    }
}

Describe 'A day of automatic attempts through the real admission and ledger' {
    BeforeEach {
        Clear-LoggedOnce
        $dir = New-CaseDir -Name 'day'
        $script:Budget = Join-Path $dir 'host-refresh.auto-budget.record'
        $script:LockPath = Join-Path $dir 'host-refresh.admission.lock'
        $script:Launches = [System.Collections.Generic.List[string]]::new()
        $script:Now = Set-TestUtc '2026-09-25T10:00:00'
        $script:SavedRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = New-CaseDir -Name 'runtime'
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'pull' } }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoStatePath { $script:Budget }
        Mock -ModuleName Test.HostRefreshTrigger Get-YurunaHostRefreshAdmissionLockPath { $script:LockPath }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshResult {
            $record = New-ResultRecord -Verdict 'partial' -State 'recovery-pending' -EndedUtc $script:Now.AddMinutes(5).ToString('o')
            $record.RequestId = $RequestId
            [pscustomobject]$record
        }
        $script:Worker = { param($Parameter) $script:Launches.Add($Parameter.RequestId); [pscustomobject]@{ Launched = $true; ExitCode = 2; TimedOut = $false; Reason = 'exited' } }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntimeDir) { Remove-Item -LiteralPath 'Env:YURUNA_RUNTIME_DIR' -ErrorAction SilentlyContinue }
        else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir }
    }

    It 'consumes the day on a failed attempt, records its outcome, and refuses the next one that day' {
        $state = New-DecisionState
        $first = Invoke-HostRefreshAutoDecision -State $state -Cycle 5 -Branch failure -Accounting (New-Accounting) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc { $script:Now } -Confirm:$false
        $first.Action | Should -Be 'attempted'
        $first.Verdict | Should -Be 'partial'
        $first.SkipFailurePause | Should -BeFalse
        $rows = @((Get-HostRefreshAutoBudget -BudgetPath $script:Budget).Reservations)
        $rows.Count | Should -Be 1
        $rows[0].requestId | Should -Be $first.RequestId
        $rows[0].outcome | Should -Be 'partial'
        $state.CycleGeneration = New-Generation 6
        $script:Now = $script:Now.AddHours(3)
        $second = Invoke-HostRefreshAutoDecision -State $state -Cycle 6 -Branch failure -Accounting (New-Accounting -Streak 3) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc { $script:Now } -Confirm:$false
        $second.Action | Should -Be 'refused'
        $second.Reason | Should -Be 'daily-budget-used'
        $script:Launches.Count | Should -Be 1
        $script:Now = Set-TestUtc '2026-09-26T00:00:01'
        $state.CycleGeneration = New-Generation 7
        (Invoke-HostRefreshAutoDecision -State $state -Cycle 7 -Branch failure -Accounting (New-Accounting -Streak 4) -Support (New-QualifiedSupport) -WorkerInvoker $script:Worker -NowUtc { $script:Now } -Confirm:$false).Action |
            Should -Be 'attempted' -Because 'the next UTC day has its own attempt'
        $script:Launches.Count | Should -Be 2
    }
}

Describe 'The verdict and resume reads against the real repair journal' {
    # The journal, admission lock and budget ledger are the real ones, in a
    # child process whose HOME is a throwaway directory, so the private root
    # of the account running the suite is never read or written.
    It 'reads a recovery-pending partial attempt as partial, keeps its resident-outer handoff and resumes it for restoration' {
        $caseHome = New-CaseDir -Name 'journal-home'
        $runtime = Join-Path $caseHome 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $out = Join-Path $caseHome 'result.json'
        $child = Join-Path $caseHome 'child.ps1'
        Set-Content -LiteralPath $child -Value @'
param([string]$Modules, [string]$Runtime, [string]$RepoRoot, [string]$Out)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Modules 'Test.SingleInstance.psm1') -DisableNameChecking -Global
Import-Module (Join-Path $Modules 'Test.HostRefreshIntent.psm1') -DisableNameChecking -Global
Import-Module (Join-Path $Modules 'Test.HostRefreshTrigger.psm1') -DisableNameChecking
$trigger = Get-Module Test.HostRefreshTrigger
$ownStart = & $trigger { Get-HostRefreshAutoProcessStartTime }
$evidence = [pscustomobject]@{ Matched = $true; Phase = 'service-vm-restore'; ProbeReasons = [string[]]@('timeout'); ObservedUtc = [datetime]::UtcNow.ToString('o') }
$launchUtc = [datetime]::UtcNow
$admitted = Request-HostRefreshAutoAttempt -HostType 'host.ubuntu.kvm' -Generation (('a' * 32) + ':7') -Streak 2 -MaxRung 'start-if-stopped' `
    -RuntimeDir $Runtime -ConfigPath (Join-Path $Runtime 'test.config.yml') -CallerOuter @{ Pid = $PID; StartTimeUnixMs = $ownStart } -Evidence $evidence -Confirm:$false
$lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshLockPath) -WaitMilliseconds 2000 -Rank (Get-YurunaLockRank -Name HostOperation)
$worker = @{ pid = $PID; startTimeUnixMs = $ownStart; ownerId = [string][System.Environment]::UserName; parent = $null }
$claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $admitted.RequestId -Worker $worker -RuntimeDir $Runtime -RepoRoot $RepoRoot -HostType 'host.ubuntu.kvm' -Confirm:$false
$saved = Save-HostRefreshRecoveryRecord -RequestId $admitted.RequestId -Generation $claim.Generation -Recovery @{ capturedUtc = [datetime]::UtcNow.ToString('o') } `
    -Obligation @(@{ id = 'service:caching-proxy'; kind = 'service'; target = 'caching-proxy'; required = $true }) -Confirm:$false
$armed = Set-HostRefreshObligationState -RequestId $admitted.RequestId -Generation $claim.Generation -ObligationId 'service:caching-proxy' -State armed -Confirm:$false
$completed = Complete-HostRefreshAttempt -RequestId $admitted.RequestId -Generation $claim.Generation -Verdict partial -Mutated $true -ReasonCode @('service-not-restored') `
    -RungResult @() -FinalProbe @{ state = 'Responsive'; reason = 'responsive' } -RunnerReadiness caller-parked -Handoff @{ tokenId = ('c' * 32); purpose = 'resident-outer' } -Confirm:$false
Exit-YurunaSingleFlightLock -Lock $lock
$stored = Get-HostRefreshResult -RequestId $admitted.RequestId
$verdict = & $trigger { param($Id, $At) Get-HostRefreshAutoVerdict -RequestId $Id -LaunchUtc $At } $admitted.RequestId $launchUtc
$early = & $trigger { param($At) Get-HostRefreshAutoResumeCandidate -NowUtc $At } ([datetime]::UtcNow)
$later = & $trigger { param($At) Get-HostRefreshAutoResumeCandidate -NowUtc $At } ([datetime]::UtcNow.AddMinutes(6))
[ordered]@{
    Home = [string]$HOME; Admitted = [bool]$admitted.Admitted; AdmitReason = [string]$admitted.Reason; RequestId = [string]$admitted.RequestId
    Claimed = [bool]$claim.Accepted; RecoverySaved = [bool]$saved.Saved; Armed = [bool]$armed.Saved; CompletedState = [string]$completed.State
    StoredState = [string]$stored.State; StoredCompletedUtc = [string]$stored.CompletedUtc; StoredEnded = [string]$stored.LastAttemptEndedUtc
    Verdict = [string]$verdict.Verdict; Matched = [bool]$verdict.Matched; Reason = [string]$verdict.Reason
    HandoffToken = [string]$verdict.Handoff['tokenId']; HandoffPurpose = [string]$verdict.Handoff['purpose']; HandoffRequest = [string]$verdict.Handoff['RequestId']
    EarlyEligible = [bool]$early.Eligible; EarlyReason = [string]$early.Reason
    LaterEligible = [bool]$later.Eligible; LaterReason = [string]$later.Reason; LaterRestoration = [bool]$later.Restoration; LaterState = [string]$later.State
} | ConvertTo-Json | Set-Content -LiteralPath $Out
'@
        $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $child, '-Modules', $here, '-Runtime', $runtime, '-RepoRoot', $script:RepoRoot, '-Out', $out)) {
            $info.ArgumentList.Add($argument)
        }
        $info.UseShellExecute = $false
        $info.RedirectStandardError = $true
        $info.RedirectStandardOutput = $true
        $info.Environment['HOME'] = $caseHome
        $info.Environment['USERPROFILE'] = $caseHome
        $process = [System.Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) { $process.Kill($true); throw 'the journal child did not finish' }
        $null = $stdout.Wait(5000), $stderr.Wait(5000)
        $errText = ($stderr.Result -replace '\x1b\[[0-9;]*[A-Za-z]', '').Trim()
        Test-Path -LiteralPath $out | Should -BeTrue -Because "the child wrote its result (stderr: $($errText.Substring(0, [Math]::Min(400, $errText.Length))))"
        $r = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $r.Home | Should -Be $caseHome
        $r.Admitted | Should -BeTrue -Because $r.AdmitReason
        $r.Claimed | Should -BeTrue
        $r.RecoverySaved | Should -BeTrue
        $r.Armed | Should -BeTrue
        $r.CompletedState | Should -Be 'recovery-pending'
        $r.StoredState | Should -Be 'recovery-pending'
        $r.StoredCompletedUtc | Should -BeNullOrEmpty -Because 'an armed obligation keeps the request open, with no terminal time'
        $r.StoredEnded | Should -Not -BeNullOrEmpty
        $r.Verdict | Should -Be 'partial'
        $r.Matched | Should -BeTrue
        $r.Reason | Should -Be 'matched'
        $r.HandoffToken | Should -Be ('c' * 32)
        $r.HandoffPurpose | Should -Be 'resident-outer'
        $r.HandoffRequest | Should -Be $r.RequestId
        $r.EarlyEligible | Should -BeFalse
        $r.EarlyReason | Should -Be 'spacing'
        $r.LaterEligible | Should -BeTrue -Because $r.LaterReason
        $r.LaterRestoration | Should -BeTrue
        $r.LaterState | Should -Be 'recovery-pending'
        Test-Path -LiteralPath (Join-Path $caseHome '.yuruna/host-refresh/host-refresh.auto-budget.record') | Should -BeTrue
    }
}

Describe 'Stop-HostRefreshAutoQueuedRequest -- a queued automatic request does not outlive a drain' {
    BeforeEach {
        $script:Active = @{ requestId = $script:RequestId; channel = 'automatic'; state = 'queued'; attempt = 0 }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshActiveRequest { $script:Active }
        Mock -ModuleName Test.HostRefreshTrigger Stop-HostRefreshQueuedRequest { [pscustomobject]@{ Stopped = $true; State = 'refused' } }
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
    }
    It 'withdraws an unclaimed automatic request with the drain reason' {
        Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Cycle 9 -Confirm:$false | Should -BeTrue
        Should -Invoke Stop-HostRefreshQueuedRequest -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $RequestId -eq $script:RequestId -and $Reason -eq 'pool-drain' }
        Should -Invoke Write-HostRefreshAutoLog -ModuleName Test.HostRefreshTrigger -Times 1 -Exactly -ParameterFilter { $Key -eq 'runner.host_refresh_auto_queued_revoked' }
    }
    It 'leaves a claimed, a foreign-channel or an absent request alone' {
        $script:Active.state = 'running'
        Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Confirm:$false | Should -BeFalse
        $script:Active.state = 'queued'
        $script:Active.channel = 'listener'
        Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Confirm:$false | Should -BeFalse
        $script:Active = $null
        Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Confirm:$false | Should -BeFalse
        Should -Invoke Stop-HostRefreshQueuedRequest -ModuleName Test.HostRefreshTrigger -Times 0 -Exactly
    }
}

Describe 'The resident-loop call sequence around a dispatch' {
    # The runner files apply these calls; this replays their order against a
    # stand-in dispatch that writes the evidence the way the inner does, so
    # the module's side of the protocol is proven independently of them.
    BeforeAll {
        function Invoke-CallSiteReplay {
            [CmdletBinding()]
            param([hashtable]$State, [object[]]$Script, [string]$RuntimeDir, [string]$StreakPath)
            $log = [System.Collections.Generic.List[object]]::new()
            if ([string]$State['RunnerInstanceId'] -cnotmatch '^[0-9a-f]{32}$') { $State.RunnerInstanceId = [guid]::NewGuid().ToString('N') }
            $cycle = 0
            foreach ($step in $Script) {
                $cycle++
                $State.CycleGeneration = "$($State.RunnerInstanceId):$cycle"
                if ($step.Rows) {
                    $null = Write-HostRefreshAutoEvidence -RuntimeDir $RuntimeDir -Generation $State.CycleGeneration -Phase 'service-vm-restore' -ServiceRestoreResult $step.Rows -Confirm:$false
                }
                $accounting = Update-HostRefreshAutoEvidence -RuntimeDir $RuntimeDir -Generation $State.CycleGeneration -Outcome $step.Outcome -StreakPath $StreakPath -Confirm:$false
                $entry = [ordered]@{ Cycle = $cycle; Generation = $State.CycleGeneration; Outcome = $step.Outcome; Streak = $accounting.Streak
                    Leftover = (Test-Path -LiteralPath (Join-Path $RuntimeDir 'runner.refresh-evidence.json')); Branch = $null; Action = $null; Pause = $null; Revoked = $false }
                if ($step.Outcome -eq 'drain') { $entry.Revoked = Stop-HostRefreshAutoQueuedRequest -Reason pool-drain -Cycle $cycle -Confirm:$false; $log.Add([pscustomobject]$entry); break }
                $branch = if ($step.Outcome -eq 'refresh-gated') { 'gated' } elseif ($step.Outcome -ne 'completed') { $null } elseif ($step.ExitCode -eq 0) { 'success' } else { 'failure' }
                if ($branch) {
                    $auto = Invoke-HostRefreshAutoDecision -State $State -Cycle $cycle -Branch $branch -Accounting $accounting -Confirm:$false
                    $entry.Branch = $branch
                    $entry.Action = $auto.Action
                    if ($branch -eq 'failure') { $entry.Pause = if ($auto.SkipFailurePause) { 'skipped' } else { 'paused' } }
                }
                $log.Add([pscustomobject]$entry)
            }
            $log
        }
    }
    BeforeEach {
        Clear-LoggedOnce
        $script:Rt = New-CaseDir -Name 'loop-runtime'
        $script:StreakFile = Join-Path (New-CaseDir -Name 'loop-private') 'host-refresh.auto-streak.json'
        Mock -ModuleName Test.HostRefreshTrigger Write-HostRefreshAutoLog { }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoPoolContext { [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'pull' } }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshActiveRequest { [pscustomobject]@{ requestId = $script:RequestId; channel = 'automatic'; state = 'queued'; attempt = 0 } }
        Mock -ModuleName Test.HostRefreshTrigger Stop-HostRefreshQueuedRequest { [pscustomobject]@{ Stopped = $true; State = 'refused' } }
        Mock -ModuleName Test.HostRefreshTrigger Get-HostRefreshAutoTriggerSupport { New-QualifiedSupport }
        Mock -ModuleName Test.HostRefreshTrigger Request-HostRefreshAutoAttempt {
            [pscustomobject]@{ Admitted = $true; RequestId = $script:RequestId; Reason = 'admitted'; UtcDay = '2026-09-25'; MissingCommand = '' }
        }
        Mock -ModuleName Test.HostRefreshTrigger Invoke-HostRefreshAutoRun {
            [pscustomobject]@{ Action = 'attempted'; Reason = 'matched'; Streak = $Streak; Threshold = 2; RequestId = $RequestId; Verdict = 'repaired'
                SkipFailurePause = ($Branch -eq 'failure'); Handoff = $null }
        }
    }

    It 'mints one generation per cycle, consumes every file, counts only completed cycles and skips the pause on a repair' {
        $state = New-DecisionState
        $state.Remove('RunnerInstanceId')
        $timeout = @(New-Row -ProbeReason 'timeout')
        $steps = @(
            @{ Outcome = 'completed'; ExitCode = 0; Rows = $timeout }
            @{ Outcome = 'cycle-aborted'; ExitCode = 1; Rows = $timeout }
            @{ Outcome = 'completed'; ExitCode = 1; Rows = $timeout }
            @{ Outcome = 'drain'; ExitCode = 0; Rows = $timeout }
        )
        $log = @(Invoke-CallSiteReplay -State $state -Script $steps -RuntimeDir $script:Rt -StreakPath $script:StreakFile)
        $log.Count | Should -Be 4
        @($log | ForEach-Object { $_.Generation.Split(':')[0] } | Select-Object -Unique).Count | Should -Be 1
        @($log.Generation | Select-Object -Unique).Count | Should -Be 4
        $log | ForEach-Object { $_.Leftover | Should -BeFalse -Because "cycle $($_.Cycle) consumed its file" }
        ($log.Streak -join ',') | Should -Be '1,1,2,2'
        $log[0].Branch | Should -Be 'success'
        $log[0].Action | Should -Be 'below-threshold'
        $log[1].Branch | Should -BeNullOrEmpty
        $log[2].Branch | Should -Be 'failure'
        $log[2].Action | Should -Be 'attempted'
        $log[2].Pause | Should -Be 'skipped'
        $log[3].Revoked | Should -BeTrue
    }
}

Describe 'Invoke-RunnerOuterLoop -- the applied call sites' {
    # Runs only once the resident loop calls into this module. Every trigger
    # function is mocked, so the case proves the wiring -- the generation per
    # cycle, the branch per outcome, the pause skip -- and nothing it does can
    # reach the private state of the account running the suite.
    BeforeAll {
        $script:OuterLoopPath = Join-Path $here 'Test.RunnerOuterLoop.psm1'
        $script:CallSitesPresent = (Get-Content -LiteralPath $script:OuterLoopPath -Raw) -match 'Invoke-HostRefreshAutoDecision'
        if ($script:CallSitesPresent) {
            Import-Module (Join-Path $here 'Test.OuterLog.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
            Import-Module $script:OuterLoopPath -Force -Global -DisableNameChecking
        }
    }
    AfterEach { Remove-Item -LiteralPath 'Function:\Set-RunnerState' -ErrorAction SilentlyContinue }
    It 'hands each completed cycle its own generation and branch, and skips the failure pause on a repair' {
        if (-not $script:CallSitesPresent) {
            Set-ItResult -Skipped -Because 'the resident loop in this tree does not call Invoke-HostRefreshAutoDecision yet'
            return
        }
        $runtime = New-CaseDir -Name 'outer-runtime'
        $savedRuntime = $env:YURUNA_RUNTIME_DIR
        $savedLog = $env:YURUNA_LOG_DIR
        $env:YURUNA_RUNTIME_DIR = $runtime
        $env:YURUNA_LOG_DIR = $runtime
        try {
            $script:Branches = [System.Collections.Generic.List[string]]::new()
            $script:Generations = [System.Collections.Generic.List[string]]::new()
            $script:Accounted = [System.Collections.Generic.List[string]]::new()
            $script:States = [System.Collections.Generic.List[string]]::new()
            function global:Set-RunnerState {
                [CmdletBinding(SupportsShouldProcess)] param([string]$To, [string]$Reason)
                $null = $Reason
                if ($PSCmdlet.ShouldProcess($To)) { $script:States.Add($To) }
            }
            Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
            Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha0' }
            Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
            Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
            Mock -ModuleName Test.RunnerOuterLoop Test-OuterNewCommitsAvailable { $false }
            Mock -ModuleName Test.RunnerOuterLoop Update-HostRefreshAutoEvidence {
                $script:Accounted.Add("$Generation/$Outcome")
                [pscustomobject]@{ Outcome = $Outcome; Evidence = $null; Counted = $true; Reset = $false; Streak = 2; StreakPersisted = $true; Reason = 'counted' }
            }
            Mock -ModuleName Test.RunnerOuterLoop Stop-HostRefreshAutoQueuedRequest { $false }
            Mock -ModuleName Test.RunnerOuterLoop Invoke-HostRefreshAutoDecision {
                $script:Branches.Add($Branch)
                [pscustomobject]@{ Action = 'attempted'; Reason = ''; Streak = 2; Threshold = 2; RequestId = $script:RequestId; Verdict = 'repaired'
                    SkipFailurePause = ($Branch -eq 'failure'); Handoff = $null }
            }
            Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
                $script:Generations.Add([string]$State.CycleGeneration)
                $n = $script:Generations.Count
                if ($n -ge 3) { $State.ShutdownState['Requested'] = $true }
                $code = if ($n -eq 2) { 1 } else { 0 }
                [pscustomobject]@{ Outcome = 'completed'; ExitCode = $code; CycleGeneration = $State.CycleGeneration }
            }
            $config = Join-Path $runtime 'test.config.yml'
            Set-Content -LiteralPath $config -Value "testCycle:`n  autoRefreshAfterStalls: 2`n"
            $null = @(Invoke-RunnerOuterLoop -State @{
                    CycleScript = ''; RepoRoot = $runtime; ConfigPath = $config; InnerScript = 'x'; PwshExe = 'pwsh'; ArgList = @()
                    ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }; NoGitPull = $true
                    FailurePauseMaxSeconds = 2; FailureCommitPollSeconds = 1; OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
                    StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
                } 3>$null 6>$null)
            ($script:Branches -join ',') | Should -Be 'success,failure,success'
            @($script:Generations | Where-Object { $_ -cmatch '^[0-9a-f]{32}:[1-9][0-9]*$' }).Count | Should -Be 3
            @($script:Generations | Select-Object -Unique).Count | Should -Be 3
            @($script:Generations | ForEach-Object { $_.Split(':')[0] } | Select-Object -Unique).Count | Should -Be 1
            ($script:Accounted -join ',') | Should -Be (($script:Generations | ForEach-Object { "$_/completed" }) -join ',')
            $script:States | Should -Not -Contain 'paused' -Because 'a repair on the failure branch skips the failure pause'
        } finally {
            $env:YURUNA_RUNTIME_DIR = $savedRuntime
            $env:YURUNA_LOG_DIR = $savedLog
        }
    }
}

Describe 'Source guards' {
    BeforeAll {
        $script:Tokens = Get-SourceCodeToken -Path $script:ModulePath
        $script:Words = @($script:Tokens | ForEach-Object { if ($_.Kind -in 'StringLiteral', 'StringExpandable') { $_.Value } else { $_.Text } })
    }
    It 'never reads the operator restart flag, the preamble-stall state or status.json' {
        foreach ($forbidden in 'control.cycle-restart', 'runner.preambleStall.json', 'status.json') {
            @($script:Words | Where-Object { "$_" -like "*$forbidden*" }).Count | Should -Be 0 -Because $forbidden
        }
    }
    It 'never registers a recovery handler, never tree-kills and never asks for a hard stop' {
        foreach ($forbidden in 'Register-RecoveryHandler', 'Stop-ProcessTree', 'Stop-YurunaProcessTree', 'Stop-Process', 'taskkill', 'AllowHardStop') {
            @($script:Words | Where-Object { "$_" -ieq $forbidden -or "$_" -ieq "-$forbidden" }).Count | Should -Be 0 -Because $forbidden
        }
        (Get-Content -LiteralPath $script:ModulePath -Raw) | Should -Not -Match 'Kill\(\s*\$true\s*\)'
    }
    It 'writes operator text only through the Information and Warning streams' {
        @($script:Words | Where-Object { "$_" -ieq 'Write-Output' -or "$_" -ieq 'Write-Host' }).Count | Should -Be 0
    }
    It 'imports only Globalization and Test.StateFile at load time, neither with -Force' {
        $ast = Get-YurunaTestFileAst -Path $script:ModulePath
        $topImports = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^Import-Module' })
        $topImports.Count | Should -Be 2
        $topImports | ForEach-Object { $_.Extent.Text | Should -Not -Match '-Force' }
        ($topImports[0].Extent.Text) | Should -Match 'Yuruna\.Globalization\.psm1'
        ($topImports[1].Extent.Text) | Should -Match 'Test\.StateFile\.psm1'
    }
}

Describe 'Test-Config.ps1 -- the autoRefreshAfterStalls check' {
    # The check is lifted out of the script by its AST and run with stand-in
    # Write-Pass / Write-Warn helpers, so the real script's other checks (host
    # probes, notification sends) never run here.
    BeforeAll {
        $testConfig = Join-Path $script:RepoRoot 'test/Test-Config.ps1'
        $ast = Get-YurunaTestFileAst -Path $testConfig
        $checks = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -match 'Contains\("autoRefreshAfterStalls"\)'
                }, $true))
        $checks.Count | Should -Be 1
        $script:KnobCheck = [scriptblock]::Create($checks[0].Extent.Text)
        function Invoke-KnobCheck {
            [CmdletBinding()]
            [OutputType([string])]
            param([AllowNull()]$Value, [string]$HostType = 'host.macos.utm', [switch]$Missing)
            $said = [System.Collections.Generic.List[string]]::new()
            $Config = @{ testCycle = @{} }
            if (-not $Missing) { $Config.testCycle.autoRefreshAfterStalls = $Value }
            $ModulesDir = $here
            function Write-Pass { param([string]$Message) $said.Add("PASS $Message") }
            function Write-Warn { param([string]$Message) $said.Add("WARN $Message") }
            function Format-YurunaOperatorMessage { param([string]$Key, [hashtable]$Arguments) $null = $Arguments; "KEY:$Key" }
            $null = $Config, $ModulesDir, $HostType
            . $script:KnobCheck
            $said
        }
    }
    It 'reports a value that is not a whole number instead of throwing' {
        $said = @(Invoke-KnobCheck -Value 'two')
        $said | Should -Be @('WARN KEY:runner.host_refresh_auto_value_not_integer')
    }
    It 'keeps the negative-value warning' {
        @(Invoke-KnobCheck -Value -1) | Should -Be @('WARN KEY:runner.operator_fffaa1debcc46863')
    }
    It 'passes 0 without an availability warning' {
        @(Invoke-KnobCheck -Value 0) | Should -Be @("PASS 'testCycle.autoRefreshAfterStalls' = 0")
    }
    It 'warns that 1 is raised to 2 and that this host cannot act on it' {
        $said = @(Invoke-KnobCheck -Value 1 -HostType 'host.macos.utm')
        $said[0] | Should -Be "PASS 'testCycle.autoRefreshAfterStalls' = 1"
        $said | Should -Contain 'WARN KEY:runner.host_refresh_auto_threshold_raised'
        $said | Should -Contain 'WARN KEY:runner.host_refresh_auto_unavailable_on_host'
    }
    It 'warns that an unqualified platform does not act, on every host type' {
        foreach ($hostType in 'host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v') {
            @(Invoke-KnobCheck -Value 2 -HostType $hostType) | Should -Contain 'WARN KEY:runner.host_refresh_auto_unavailable_on_host'
        }
    }
    It 'skips the availability warning when the host type is unknown' {
        @(Invoke-KnobCheck -Value 2 -HostType '') | Should -Be @("PASS 'testCycle.autoRefreshAfterStalls' = 2")
    }
    It 'keeps the missing-key warning' {
        @(Invoke-KnobCheck -Missing) | Should -Be @('WARN KEY:runner.operator_677303e3823afe8d')
    }
}
