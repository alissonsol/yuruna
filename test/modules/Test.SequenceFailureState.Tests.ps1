<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42da4d2b-cbcd-4c6d-b4e8-973686da3b1a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry failure pester
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
    Pester coverage for the actionability enrichment in
    New-SequenceFailureRecord (Test.SequenceFailureState.psm1): the repro
    block, sequenceName, classificationSource, reason, and the inner-cause /
    replay-boundary fields on crash records.
.DESCRIPTION
    Throw-based assertions (Pester 5+). Get-SequenceAction
    is stubbed globally so the builder resolves deterministic classifications
    independent of the live verb registry; the stub is removed at file end.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceFailureState.psm1'
$evtPath    = Join-Path $here 'Test.EventSchema.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module $evtPath    -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Deterministic verb registry: waitForText resolves, anything else is unknown.
# Dot-sourced into the module under test rather than defined globally: the
# builder resolves the name from its own session state first, and the stub dies
# with the module instead of outliving the file. A global function cannot be
# taken back -- Remove-Item on function: from inside a Pester block
# reports success and leaves the command in place -- so a global stub would
# shadow the real registry for every later file in the shared runspace.
. (Get-Module Test.SequenceFailureState) {
    function Get-SequenceAction {
        param([string]$Name)
        if ($Name -eq 'waitForText') {
            return [pscustomobject]@{ FailureClass = 'ocr_timeout'; Severity = 'hard'; SuggestedRecoveries = @('reconnect') }
        }
        # An input verb: a failed send is the retryable host_io_blocked.
        if ($Name -eq 'inputText') {
            return [pscustomobject]@{ FailureClass = 'host_io_blocked'; Severity = 'soft'; SuggestedRecoveries = @('retry_immediately') }
        }
        # The start verb: a start or resize that failed is provisioning_failure.
        if ($Name -eq 'startVm') {
            return [pscustomobject]@{ FailureClass = 'provisioning_failure'; Severity = 'hard'; SuggestedRecoveries = @('retry_immediately') }
        }
        return $null
    }
}

function Reset-FailState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: seeds the in-memory failure-state slots to a known baseline; no external state.')]
    param()
    $f = Get-SequenceFailureState
    $f.LastFailureLabel = 'waitForText: "login prompt"'
    $f.LastFailureDescription = 'OCR: yt2sqluser@'
    $f.LastFailedAction = 'waitForText'
    $f.LastFailedStepNumber = 3
    $f.LastFailedStepInvocationId = ''
    $f.LastFailedSequenceInvocationId = ''
    $f.OriginatingStepInvocationId = ''
    $f.OriginatingSequenceInvocationId = ''
    $f.StepProgressAdvisory = $null
    $f.LastSucceededStepNumber = 2
    $f.LastInnerFailedAction = $null
    $f.LastInnerFailureClass = $null
    $f.LastInnerSeverity = $null
    $f.LastInnerSuggestedRecoveries = [string[]]@()
    $f.WaitForTextMatchedFailurePattern = $null
    $f.WaitForTextOcrTail = $null
    $f.WaitForTextPatternsSought = [string[]]@()
    # Cleared here too, or a test that sets it leaves every later test in this
    # file reclassified as a flooded console -- the failure mode this baseline
    # exists to prevent.
    $f.WaitForTextConsoleFlood = $null
    # Same reasoning: a staged-input verdict left set would reclassify every
    # later failure in this file as input_lost.
    $f.StepInputLost = $null
    $f.StepHostInputFault = $null
    $f.StepLauncherRejection = $null
    $f.StepAptIndexMismatch = $null
    # A proof left set would let every later record claim its step did nothing.
    $f.StepEffect = $null
    $f.StepDeployResult = $null
    # Same reasoning as the flood slot: a test that sets either of these would
    # otherwise leave every later test in this file reporting a parked console or
    # an operator hold it never had.
    $f.WaitForTextConsoleStaticSeconds = 0
    $f.WaitForTextInstallerStage = ''
    $f.WaitForTextInstallerStageSeconds = 0
    # And the qualifier on those two slots, for the same reason: a test that
    # clears it would leave every later test in this file publishing nulls.
    $f.WaitForTextConsoleSignalsMeasured = $true
    $f.LastPauseRelease = $null
    # Same reasoning again: a test that records a livelock or a blank console
    # would otherwise leave every later record carrying it.
    $f.WaitForTextGuestLivelock = $null
    $f.WaitForTextConsoleSecondOpinion = $null
    $f.WaitForTextGuestLivelocked = $false
    $f.WaitForTextKernelStallEnd = $null
    $f.WaitForTextBlankScreenSeconds = 0
    # A kernel reading left set would be claimed by every later record whose
    # step it names.
    $f.StepGuestKernelFault = $null
    # A step start left set would open a host-address window for every later
    # record in this file.
    $f.LastFailedStepStartedUtc = $null
    return $f
}

# The builder derives sequenceName with [System.IO.Path]::GetFileNameWithoutExtension,
# which splits only on the running platform's separator -- a backslash is an
# ordinary filename character on Linux/macOS. The path the engine hands it is
# always a local one, so build the fixture with the native separator and the
# basename resolves the same everywhere.
$script:seqPath = @('C:', 'repo', 'project', 'example',
    'workload.guest.ubuntu.server.24.k8s.text-to-sql.test.yml') -join [System.IO.Path]::DirectorySeparatorChar

}

Describe 'progress observations remain advisory' {
    It 'combines static output and an unresponsive transport without allowing a restart' {
        $r = Get-GuestProgressAdvisory -OutputStaticSeconds 200 -SshResponsiveness unresponsive
        $r.Verdict | Should -Be 'progress-suspect'
        $r.HeartbeatAgeSeconds | Should -BeNullOrEmpty
        $r.AutomaticRecoveryAllowed | Should -BeFalse
    }
    It 'does not treat a quiet console or a single trapped processor as proof of lost progress' {
        (Get-GuestProgressAdvisory -OutputStaticSeconds 400 -HeartbeatAgeSeconds 10 -SshResponsiveness responsive).Verdict | Should -Be 'insufficient-evidence'
        (Get-GuestProgressAdvisory).Verdict | Should -Be unavailable
        (Get-GuestProgressAdvisory -OutputStaticSeconds 20 -HeartbeatAgeSeconds 10 -SshResponsiveness responsive).Verdict | Should -Be 'no-stall-evidence'
    }
    It 'combines a stale heartbeat with SSH failure and keeps missing console evidence unknown' {
        $r = Get-GuestProgressAdvisory -HeartbeatAgeSeconds 180 -SshResponsiveness unresponsive
        $r.Verdict | Should -Be 'progress-suspect'
        $r.OutputStaticSeconds | Should -BeNullOrEmpty
        $r.Signals | Should -Contain 'stale-recorder-heartbeat'
        $r.AutomaticRecoveryAllowed | Should -BeFalse
    }
    It 'lists a guest clock anomaly as a signal without scoring it as a stall' {
        $r = Get-GuestProgressAdvisory -HeartbeatAgeSeconds 10 -SshResponsiveness responsive `
            -ClockWarningCodes @('cpu-idle-exceeds-boot-uptime', 'clock-evidence-incomplete', 'cpu-idle-exceeds-boot-uptime')
        $r.Verdict | Should -Be 'insufficient-evidence'
        $r.Signals | Should -Contain 'guest-clock-anomaly'
        @($r.ClockWarnings) | Should -Be @('cpu-idle-exceeds-boot-uptime')
        $r.AutomaticRecoveryAllowed | Should -BeFalse
    }
    It 'keeps progress-suspect when a clock anomaly joins a stale heartbeat and a dead transport' {
        $r = Get-GuestProgressAdvisory -HeartbeatAgeSeconds 256 -SshResponsiveness unresponsive -ClockWarningCodes @('cpu-idle-exceeds-boot-uptime')
        $r.Verdict | Should -Be 'progress-suspect'
        $r.Signals | Should -Contain 'guest-clock-anomaly'
        $r.Signals | Should -Contain 'ssh-unresponsive'
    }
    It 'stays unavailable when nothing was measured and only incomplete clock evidence exists' {
        (Get-GuestProgressAdvisory -ClockWarningCodes @()).Verdict | Should -Be unavailable
        (Get-GuestProgressAdvisory -ClockWarningCodes @('clock-evidence-incomplete')).Verdict | Should -Be unavailable
        @((Get-GuestProgressAdvisory -ClockWarningCodes @('clock-evidence-incomplete')).ClockWarnings).Count | Should -Be 0
    }
    It 'lists a guest kernel fault as a signal without scoring it as a stall' {
        $r = Get-GuestProgressAdvisory -HeartbeatAgeSeconds 10 -SshResponsiveness responsive -KernelFaultKinds @('soft-lockup', 'rcu-stall', 'soft-lockup')
        $r.Verdict | Should -Be 'insufficient-evidence'
        $r.Signals | Should -Contain 'guest-kernel-fault'
        @($r.KernelFaults) | Should -Be @('soft-lockup', 'rcu-stall')
        $r.AutomaticRecoveryAllowed | Should -BeFalse
        $suspect = Get-GuestProgressAdvisory -OutputStaticSeconds 1604 -HeartbeatAgeSeconds 1648 -SshResponsiveness unresponsive -KernelFaultKinds @('soft-lockup')
        $suspect.Verdict | Should -Be 'progress-suspect'
        @((Get-GuestProgressAdvisory -HeartbeatAgeSeconds 10 -SshResponsiveness responsive).KernelFaults).Count | Should -Be 0
    }
}

Describe 'the guest kernel''s own reports in the failure record' {
    BeforeAll {
        function New-KernelReading {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory fixture; changes no state.')]
            param([string]$StepInvocationId)
            [ordered]@{
                stepInvocationId = $StepInvocationId
                serial = [ordered]@{ source = 'serial'; boots = 1; records = 120; kernelRecords = 9; faultRecords = 3
                    kinds = [string[]]@('rcu-stall', 'soft-lockup'); largestStallJiffies = 263625318; bytesRead = 4000; truncated = $false }
                recorder = $null
            }
        }
    }
    It 'carries the failing step''s reading into the record and onto the event' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'leaf'
        $f.StepGuestKernelFault = New-KernelReading -StepInvocationId 'leaf'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $reading = $r.File.context.causeDetail.guestKernelFault
        $reading.serial.faultRecords | Should -Be 3
        $reading.serial.largestStallJiffies | Should -Be 263625318
        $reading.Contains('stepInvocationId') | Should -BeFalse -Because 'the record names its step once, at its top level'
        $r.Event.causeGuestKernelFault | Should -Be 'rcu-stall,soft-lockup'
        $r.Event.guestKernelFault.serial.bytesRead | Should -Be 4000
        $r.File.failureClass | Should -Be 'ocr_timeout' -Because 'the reading is evidence for the reader, not a reclassification'
        $violations = Test-CycleEventSchema -Record $r.Event
        @($violations).Count | Should -Be 0 -Because "the event still validates; got: $($violations -join '; ')"
    }
    It 'keeps a retried attempt''s reading for the record its wrapper writes' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'wrapper'
        $f.OriginatingStepInvocationId = 'leaf'
        $f.OriginatingSequenceInvocationId = 'nested'
        $f.StepGuestKernelFault = New-KernelReading -StepInvocationId 'leaf'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $r.File.context.causeDetail.guestKernelFault.serial.faultRecords | Should -Be 3
        $r.Event.causeGuestKernelFault | Should -Be 'rcu-stall,soft-lockup'
    }
    It 'keeps a recorder stall that may predate the step in the reading but out of what the step showed' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'leaf'
        $reading = New-KernelReading -StepInvocationId 'leaf'
        $reading.serial.kinds = [string[]]@()
        $reading.recorder = [ordered]@{ source = 'recorder'; faultRecords = 2; kinds = [string[]]@('hung-task', 'rcu-stall'); firstStallSampleIndex = 0; mayPredateStep = $true }
        $f.StepGuestKernelFault = $reading
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $r.File.context.causeDetail.guestKernelFault.recorder.mayPredateStep | Should -BeTrue
        $r.Event.causeGuestKernelFault | Should -Be '' -Because 'a report from before the step is not this step''s'
        @(Get-GuestKernelFaultKind -Reading $reading).Count | Should -Be 0
        $reading.recorder.mayPredateStep = $false
        @(Get-GuestKernelFaultKind -Reading $reading) | Should -Be @('hung-task', 'rcu-stall')
    }
    It 'drops a reading another step left behind' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'leaf'
        $f.StepGuestKernelFault = New-KernelReading -StepInvocationId 'earlier'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $r.File.context.causeDetail.guestKernelFault | Should -BeNullOrEmpty
        $r.Event.causeGuestKernelFault | Should -Be ''
    }
    It 'keeps the field present and null when no source was read' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $r.File.context.causeDetail.Contains('guestKernelFault') | Should -BeTrue
        $r.File.context.causeDetail.guestKernelFault | Should -BeNullOrEmpty
        $r.Event.causeGuestKernelFault | Should -Be ''
    }
}

Describe 'the host''s own address moves in the failure record' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.HostAddressBeacon.psm1') -Force -DisableNameChecking
        $script:savedMoveEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:moveRuntimeDir = New-YurunaTestTempDir -Prefix 'yrn-fail-move'
        $env:YURUNA_RUNTIME_DIR = $script:moveRuntimeDir
        function Add-MoveRow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: appends a beacon row to a throwaway runtime dir.')]
            param([datetime]$AtUtc, [string]$From, [string]$To)
            Write-HostAddressChangeRecord -RuntimeDir $script:moveRuntimeDir -Previous $From -Current $To `
                -ChangedAtUtc $AtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    AfterAll {
        Restore-YurunaTestEnvironment -Saved $script:savedMoveEnvironment
        Remove-YurunaTestTempDir $script:moveRuntimeDir
    }
    It 'reports no reading when the beacon left no record' {
        $f = Reset-FailState
        $f.LastFailedStepStartedUtc = [datetime]::UtcNow.AddMinutes(-5)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $r.File.context.causeDetail.Contains('hostAddressChanges') | Should -BeTrue
        $null -eq $r.File.context.causeDetail.hostAddressChanges | Should -BeTrue -Because 'unmeasured is not a host that held its address'
        $r.Event.causeHostAddressChange | Should -Be ''
    }
    It 'carries the move that fell inside the step, and only that one, into the record and onto the event' {
        # The shape of a host whose DHCP lease expired mid-step: the guest fetched
        # from the address the host had when the step started and failed with a
        # plain script error. The record names the move beside the symptom.
        $now = [datetime]::UtcNow
        Add-MoveRow -AtUtc $now.AddMinutes(-30) -From '192.168.7.89' -To '192.168.7.136'
        Add-MoveRow -AtUtc $now.AddMinutes(-2) -From '192.168.7.136' -To '192.168.7.108'
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'leaf'
        $f.LastFailedStepStartedUtc = $now.AddMinutes(-5)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
        $moves = @($r.File.context.causeDetail.hostAddressChanges)
        $moves.Count | Should -Be 1 -Because 'the move 30 minutes ago predates the step'
        $moves[0].previous | Should -Be '192.168.7.136'
        $moves[0].current | Should -Be '192.168.7.108'
        $r.Event.causeHostAddressChange | Should -Match '^192\.168\.7\.136 -> 192\.168\.7\.108 at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $r.File.failureClass | Should -Be 'ocr_timeout' -Because 'the move is evidence for the reader, not a reclassification'
        $violations = Test-CycleEventSchema -Record $r.Event
        @($violations).Count | Should -Be 0 -Because "the event still validates; got: $($violations -join '; ')"
    }
    It 'opens the window at the cycle start when no step start was recorded, and an empty list is a host that held its address' {
        Add-MoveRow -AtUtc ([datetime]::UtcNow.AddMinutes(-30)) -From '192.168.7.89' -To '192.168.7.136'
        [void](Reset-FailState)
        $savedGlobal = Save-YurunaTestGlobal -Name '__YurunaCycleStartUtc'
        Set-YurunaTestGlobal -Value @{ __YurunaCycleStartUtc = [datetime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
        try {
            $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 13
            $null -eq $r.File.context.causeDetail.hostAddressChanges | Should -BeFalse -Because 'the beacon record was read over the cycle window'
            @($r.File.context.causeDetail.hostAddressChanges).Count | Should -Be 0
            $r.Event.causeHostAddressChange | Should -Be ''
        } finally { Restore-YurunaTestGlobal -Saved $savedGlobal }
    }
}

Describe 'New-SequenceFailureRecord actionability enrichment (step)' {
    It 'preserves nested processor evidence through every production failure-file serializer' {
        $f = Reset-FailState
        $f.WaitForTextGuestLivelock = [pscustomobject]@{
            Verdict='not-livelocked'
            ProcessorWindow=@{
                SampleCount=21
                Processors=@(@{
                    Processor='1'
                    Counters=@{
                        '% Hypervisor Run Time'=@{ Status='present'; Average=89.55; SampleCount=21; UnavailableSampleCount=0 }
                        'SysReg Accesses/sec'=@{ Status='unavailable'; Average=$null; SampleCount=0; UnavailableSampleCount=21 }
                    }
                })
                CounterCapabilities=@(@{ Counter='SysReg Accesses/sec'; Status='absent'; Reason='not published' })
            }
        }
        $record = New-SequenceFailureRecord -Reason step -VMName v -GuestKey g -HostType h -SequencePath $script:seqPath -LogDir d
        $serializers = @(foreach ($module in @('Test.SequenceEngine.psm1', 'Test.RunnerInnerLoop.psm1')) {
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $here $module), [ref]$null, [ref]$null)
            foreach ($command in $ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'ConvertTo-Json'
            }, $true)) {
                $pipeline = $command.Parent
                if ($pipeline.Extent.Text -notmatch '^\$(?:failRec\.File|rec(?:\.File)?)\s*\|') { continue }
                [pscustomobject]@{
                    Source = "$module`:$($command.Extent.StartLineNumber)"
                    Text = $pipeline.Extent.Text.Replace($pipeline.PipelineElements[0].Extent.Text, '$args[0]')
                }
            }
        })
        $serializers.Count | Should -BeGreaterOrEqual 5
        foreach ($serializer in $serializers) {
            $json = & ([scriptblock]::Create($serializer.Text)) $record.File
            $roundTrip = $json | ConvertFrom-Json -AsHashtable
            $window = $roundTrip.context.causeDetail.guestLivelock.processorWindow
            $window.Processors[0].Counters['% Hypervisor Run Time'].Average | Should -Be 89.55 -Because $serializer.Source
            $missing = $window.Processors[0].Counters['SysReg Accesses/sec']
            $missing.Status | Should -Be unavailable -Because $serializer.Source
            $missing.ContainsKey('Average') | Should -BeTrue -Because $serializer.Source
            $missing.Average | Should -BeNullOrEmpty -Because $serializer.Source
            $window.CounterCapabilities[0].Status | Should -Be absent -Because $serializer.Source
        }
    }

    It 'retains failed invocation IDs and processor evidence even without a livelock' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'failed-step'
        $f.LastFailedSequenceInvocationId = 'failed-sequence'
        $f.WaitForTextGuestLivelock = [pscustomobject]@{
            Verdict='not-livelocked'; ProcessorWindow=@{ SampleCount=21; Processors=@(@{ Processor='1'; HypervisorRunPercent=89.55 }) }
        }
        $r = New-SequenceFailureRecord -Reason step -VMName v -GuestKey g -HostType h -SequencePath $script:seqPath -LogDir d
        $r.File.stepInvocationId | Should -Be 'failed-step'
        $r.Event.sequenceInvocationId | Should -Be 'failed-sequence'
        $r.File.originatingStepInvocationId | Should -Be 'failed-step'
        $r.Event.originatingSequenceInvocationId | Should -Be 'failed-sequence'
        $r.File.context.causeDetail.guestLivelock.processorWindow.SampleCount | Should -Be 21
        $r.Event.guestProcessorWindow.Processors[0].Processor | Should -Be '1'
        $r.Event.causeGuestLivelocked | Should -BeFalse
    }
    It 'says why a wait on a wedged guest kernel ended before its deadline, and nothing for any other wait' {
        $f = Reset-FailState
        $f.WaitForTextKernelStallEnd = [ordered]@{ processors = [string[]]@('0'); noInterruptsServicedSeconds = 1305
            noInterruptsServicedSinceUtc = '2026-10-29T08:56:28.0000000Z'; kinds = [string[]]@('rcu-stall'); waitedSeconds = 1290 }
        $r = New-SequenceFailureRecord -Reason step -VMName v -GuestKey g -HostType h -SequencePath $script:seqPath -LogDir d
        $roundTrip = $r.File | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $end = $roundTrip.context.causeDetail.guestKernelStallEnd
        @($end.processors) | Should -Be @('0')
        $end.noInterruptsServicedSeconds | Should -Be 1305
        @($end.kinds) | Should -Be @('rcu-stall')
        $end.waitedSeconds | Should -Be 1290
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName v -GuestKey g -HostType h -SequencePath $script:seqPath -LogDir d
        $r.File.context.causeDetail.Contains('guestKernelStallEnd') | Should -BeTrue -Because 'the field is always present, so absence never reads as a missing producer'
        $r.File.context.causeDetail.guestKernelStallEnd | Should -BeNullOrEmpty
    }
    It 'carries sequenceName, reason, classificationSource and a repro block' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'k8s.text-to-sql' -GuestKey 'guest.ubuntu.server.24' -HostType 'host.windows.hyper-v' -SequencePath $script:seqPath -LogDir 'C:\cyc' -TotalSteps 11
        Assert-Equal -Expected 'workload.guest.ubuntu.server.24.k8s.text-to-sql.test' -Actual $r.File.sequenceName -Because 'sequenceName from path basename'
        Assert-Equal -Expected 'step' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'verb-registry' -Actual $r.File.classificationSource -Because 'resolved verb -> verb-registry'
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'class from stubbed registry'
        Assert-True ($null -ne $r.File.repro) 'repro block present'
        Assert-Equal -Expected 3 -Actual $r.File.repro.resumeFromStep -Because 'resumeFromStep = file-local failing step'
        Assert-Equal -Expected 'Debug-TestSequence' -Actual $r.File.repro.entrypoint -Because 'entrypoint'
    }
    It 'builds a repro command that omits -StartStep (chain-global vs file-local trap)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Match -Pattern 'Debug-TestSequence\.ps1' -Actual $r.File.repro.command -Because 'command runs Debug-TestSequence'
        Assert-Match -Pattern '-SequenceName "workload\.guest\.ubuntu\.server\.24\.k8s\.text-to-sql\.test"' -Actual $r.File.repro.command -Because 'names the failing sequence'
        Assert-True ($r.File.repro.command -notmatch '-StartStep') 'command must NOT contain -StartStep'
    }
    It 'strips shell-breaking characters from the repro command (no copy-paste injection)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm";rm -rf /"' -GuestKey 'g$(whoami)' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        $cmd = $r.File.repro.command
        Assert-True ($cmd -notmatch '\$') 'no $ (interpolation) survives sanitizing'
        Assert-True ($cmd -notmatch '";')  'no quote-then-command breakout survives sanitizing'
        # Only the 6 argument-wrapping quotes remain (3 quoted args x 2) -- the
        # two injected quotes were stripped.
        Assert-Equal -Expected 6 -Actual (@($cmd.ToCharArray() | Where-Object { $_ -eq '"' }).Count) -Because 'only wrapping quotes remain'
        Assert-True ($cmd -match '-VMName ') 'still emits a -VMName arg'
    }
    It 'mirrors the actionability fields onto the flat event (incl reproCommand)' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected $r.File.repro.command -Actual $r.Event.reproCommand -Because 'event reproCommand == file repro.command'
        Assert-Equal -Expected $r.File.sequenceName  -Actual $r.Event.sequenceName -Because 'event sequenceName'
        Assert-Equal -Expected 'verb-registry'       -Actual $r.Event.classificationSource -Because 'event classificationSource'
    }
    It 'emits an event that passes the cycle event schema validator' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event must validate; got: $($violations -join '; ')"
    }
}

Describe 'New-SequenceFailureRecord classificationSource discrimination' {
    It 'reports unresolved-verb (and unknown class) when the verb has no registration' {
        $f = Reset-FailState
        $f.LastFailedAction = 'no_such_verb'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unresolved-verb' -Actual $r.File.classificationSource -Because 'unresolved verb'
        Assert-Equal -Expected 'unknown' -Actual $r.File.failureClass -Because 'unknown class for unresolved verb'
    }
    It 'reports pattern-match when a hard-block OCR pattern fired' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'kernel panic'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern-match' -Actual $r.File.classificationSource -Because 'pattern-match source'
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass -Because 'reclassified to pattern_matched_failure'
    }
    It 'swaps the recovery hint to pause_and_inspect when reclassifying' {
        # The recoveries must move with the class. The registry's hint describes
        # the verb's DEFAULT failure -- for the timeout-style verbs that is
        # something worth retrying -- but a matched failure pattern is the
        # opposite case: the guest announced its own failure, so a retry only
        # re-runs a command already known to fail. The stub registry hands
        # waitForText a 'reconnect' hint, so this asserts the reclassification
        # REPLACES a registry hint rather than merely appending to an empty one.
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
        $sugg = @($r.File.suggestedRecoveries)
        Assert-Equal -Expected 1 -Actual $sugg.Count -Because "expected only pause_and_inspect; got: $($sugg -join ', ')"
        Assert-Equal -Expected 'pause_and_inspect' -Actual $sugg[0]
    }
    It 'reclassifies a flooded console instead of calling it a missing pattern' {
        # ocr_timeout's recoveries assume the pattern never printed, so they
        # restart the guest and wait again -- which reruns whatever was filling
        # the console. The two failures have different owners: a missing pattern
        # points at the guest script that should have printed it, a flooded
        # console points at whatever is overwriting the surface it would have
        # been read from.
        $f = Reset-FailState
        $f.WaitForTextConsoleFlood = "console filled with a repeating line while seeking 'Continue with autoinstall?'"
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'console_flooded' -Actual $r.File.failureClass -Because 'a flood is not an absent pattern'
        $sugg = @($r.File.suggestedRecoveries)
        Assert-Equal -Expected 1 -Actual $sugg.Count -Because "expected only pause_and_inspect; got: $($sugg -join ', ')"
        Assert-Equal -Expected 'pause_and_inspect' -Actual $sugg[0]
        Assert-True ($r.File.context.causeDetail.consoleFlood -like '*repeating line*') `
            'the evidence has to ride along, or the class is an assertion the artifact cannot support'
    }

    It 'records how long the console content sat unchanged' {
        # The flood detail alone cannot separate a console still filling from one
        # frozen on text that scrolled by earlier -- repeats are counted within a
        # single frame, so both read as a flood. Only the second is a guest parked
        # on something, and only the second can be unblocked by answering it.
        $f = Reset-FailState
        $f.WaitForTextConsoleFlood = "console filled with a repeating line while seeking 'Continue with autoinstall?'"
        $f.WaitForTextConsoleStaticSeconds = 840
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 840 -Actual $r.File.context.causeDetail.consoleStaticSeconds `
            -Because 'a wall of text that stopped moving is the evidence that the guest is waiting, not working'
    }

    It 'records the observed installer stage and its age without claiming completion' {
        $f = Reset-FailState
        $f.WaitForTextInstallerStage = 'start: subiquity/Mirror/cmd-apt-config'
        $f.WaitForTextInstallerStageSeconds = 1625
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'start: subiquity/Mirror/cmd-apt-config' -Actual $r.File.context.causeDetail.installerStage
        Assert-Equal -Expected 1625 -Actual $r.File.context.causeDetail.installerStageUnchangedSeconds
        Assert-Equal -Expected $r.File.context.causeDetail.installerStage -Actual $r.Event.causeInstallerStage
    }

    It 'reports the console fields as unmeasured, not as zero, when the wait never looked' {
        # A wait confined to the console tail runs neither console-shape tracker,
        # so both slots hold their initializers -- the same 0 and '' a measured,
        # moving, non-repeating console produces. Published as numbers they assert
        # something about the screen that nothing observed, and the reader who
        # trusts them goes looking for a guest that was working the whole time.
        $f = Reset-FailState
        $f.WaitForTextConsoleSignalsMeasured = $false
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('consoleStaticSeconds')) 'the field must always be present'
        Assert-True ($r.File.context.causeDetail.Contains('consoleFlood')) 'the field must always be present'
        Assert-True ($null -eq $r.File.context.causeDetail.consoleStaticSeconds) `
            'an unmeasured screen must not read as a screen measured at zero'
        Assert-True ($null -eq $r.File.context.causeDetail.consoleFlood) `
            'an unevaluated flood check must not read as a screen found non-repetitive'
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'not measuring the screen is not a reclassification'
    }

    It 'carries an operator hold released before the failing step' {
        # The pause gate holds the runner, not the guest: a VM keeps running and
        # printing through a hold, so a prompt printed during one is gone from the
        # screen the resumed step then has to read. A record that omits the hold
        # sends the reader looking for a guest fault that never happened.
        $f = Reset-FailState
        $f.LastPauseRelease = @{ releasedAtUtc = '2026-08-22T10:56:48Z'; heldSeconds = 1650; label = '[sequence start]'; pauseScope = 'step' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 1650 -Actual $r.File.context.causeDetail.pauseBeforeStepSeconds -Because 'the hold is part of the cause'
        Assert-Equal -Expected '2026-08-22T10:56:48Z' -Actual $r.File.context.causeDetail.pauseReleasedAtUtc -Because 'when it ended places it against the step'
    }

    It 'leaves the pause and static fields at zero, not absent, with no hold' {
        # Same contract the flood field is held to: always present, so a consumer
        # never has to tell "no hold" from "this record predates the gate".
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('pauseBeforeStepSeconds')) 'the field must always be present'
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.pauseBeforeStepSeconds
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.pauseReleasedAtUtc
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.consoleStaticSeconds
    }

    It 'ranks a matched failure pattern above a flooded console' {
        # A guest that announced its own failure in words outranks an inference
        # drawn from the shape of the screen -- the words are direct evidence and
        # the shape is circumstantial.
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $f.WaitForTextConsoleFlood = 'console filled with a repeating line'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
    }

    It 'classifies a staged command whose guard never closed as input_lost' {
        # The payload never ran, so the class carries retry guidance: replaying
        # the step cannot repeat work. A flooded console is the reading a frozen
        # echo would otherwise produce, so the specific cause has to win over it.
        $f = Reset-FailState
        $f.StepInputLost = $true
        $f.WaitForTextConsoleFlood = 'console filled with a repeating line'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'input_lost' -Actual $r.File.failureClass
        Assert-Equal -Expected 'retry_with_backoff' -Actual @($r.File.suggestedRecoveries)[0]
    }

    It 'ranks a matched failure pattern above input_lost' {
        # A guest that printed its own failure ran the payload, so the input was
        # not the cause and the class must not claim it was.
        $f = Reset-FailState
        $f.StepInputLost = $true
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
    }

    It 'records a launcher refusal beside the matched pattern without changing the class' {
        # The refusal names what the keyboard delivered; the class still says the
        # step's failure sentinel matched.
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'NONZERO SCRIPT EXIT:'
        $f.StepLauncherRejection = [ordered]@{ code = 'YFE_GUI_ENCODING'; attempt = 2; receivedChars = 1069; expectedChars = 1068
            receivedSha256 = 'b' * 64; expectedSha256 = 'c' * 64; payloadState = 'NOT_PREPARED' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
        $rejection = $r.File.context.causeDetail.launcherRejection
        Assert-Equal -Expected 'YFE_GUI_ENCODING' -Actual $rejection.code
        Assert-Equal -Expected 1069 -Actual $rejection.receivedChars
        Assert-Equal -Expected 1068 -Actual $rejection.expectedChars
        Assert-Equal -Expected 'NOT_PREPARED' -Actual $rejection.payloadState
        Assert-Equal -Expected 'YFE_GUI_ENCODING' -Actual $r.Event.causeLauncherRejection
    }

    It 'leaves the launcher refusal empty when nothing was refused' {
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('launcherRejection')) 'the field must always be present'
        Assert-True ($null -eq $r.File.context.causeDetail.launcherRejection) 'and null without a refusal'
        Assert-Equal -Expected '' -Actual $r.Event.causeLauncherRejection
    }

    It 'records an apt index mismatch beside script_error, naming the index and the proxy' {
        # The script failed, so the class stays; the field says the fix is in the
        # cache or at the origin rather than in the script.
        $f = Reset-FailState
        $url = 'https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-arm64/Packages.bz2'
        $f.StepAptIndexMismatch = [ordered]@{ kind = 'unexpected-size'; url = $url; receivedBytes = [long]68994; expectedBytes = [long]68759
            server = '192.168.7.42:3129'; releaseFileCreated = 'Wed, 21 Oct 2026 08:17:46 +0000'; occurrences = 5
            proxyCopy = 'HTTP/1.1 200 OK;Age: 33000'; proxyPurgeStatus = 200 }
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        $mismatch = $r.File.context.causeDetail.aptIndexMismatch
        Assert-Equal -Expected 'unexpected-size' -Actual $mismatch.kind
        Assert-Equal -Expected $url -Actual $mismatch.url
        Assert-Equal -Expected 68994 -Actual $mismatch.receivedBytes
        Assert-Equal -Expected 68759 -Actual $mismatch.expectedBytes
        Assert-Equal -Expected '192.168.7.42:3129' -Actual $mismatch.server
        Assert-Equal -Expected 5 -Actual $mismatch.occurrences
        Assert-Equal -Expected 200 -Actual $mismatch.proxyPurgeStatus
        Assert-Equal -Expected $url -Actual $r.Event.causeAptIndexMismatch
    }

    It 'leaves the apt index mismatch empty when apt reported none' {
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('aptIndexMismatch')) 'the field must always be present'
        Assert-True ($null -eq $r.File.context.causeDetail.aptIndexMismatch) 'and null without a mismatch'
        Assert-Equal -Expected '' -Actual $r.Event.causeAptIndexMismatch
    }

    It 'leaves the flood field empty, not absent, on an ordinary failure' {
        # A consumer must never have to tell "not flooded" from "this record
        # predates the check".
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-True ($r.File.context.causeDetail.Contains('consoleFlood')) 'the field must always be present'
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.consoleFlood
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'no flood means no reclassification'
    }

    It 'keeps the registry recovery hint when no pattern matched' {
        # The counterpart: with no failure pattern, nothing is reclassified and
        # the verb's own hint must survive untouched. Without this, a swap that
        # fired unconditionally would look correct in the test above.
        $null = Reset-FailState
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass
        Assert-Equal -Expected 'verb-registry' -Actual $r.File.classificationSource
        Assert-Equal -Expected 'reconnect' -Actual (@($r.File.suggestedRecoveries)[0]) -Because 'the registry hint is preserved'
    }
}

Describe 'New-SequenceFailureRecord OCR causeDetail' {
    It 'surfaces the OCR tail + sought patterns in the step record context and flat on the event' {
        $f = Reset-FailState
        $f.WaitForTextOcrTail = 'yt2sqluser@host:~$'
        $f.WaitForTextPatternsSought = [string[]]@('login prompt', 'Not listed?')
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.File.context.causeDetail.ocrTail -Because 'nested ocrTail'
        Assert-Equal -Expected 2 -Actual (@($r.File.context.causeDetail.patternsSought).Count) -Because 'nested patternsSought count'
        Assert-Equal -Expected 'yt2sqluser@host:~$' -Actual $r.Event.causeOcrTail -Because 'flat event ocr tail mirrors context'
        Assert-Equal -Expected 2 -Actual (@($r.Event.causePatternsSought).Count) -Because 'flat event patterns count'
    }
    It 'defaults to empty (array, not null) when no wait cause was captured' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected '' -Actual $r.Event.causeOcrTail -Because 'empty ocr tail'
        Assert-Equal -Expected 0 -Actual (@($r.Event.causePatternsSought).Count) -Because 'empty patterns array (not null)'
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event still validates; got: $($violations -join '; ')"
    }
    It 'says the console went blank instead of leaving the screen fields empty' {
        $f = Reset-FailState
        $f.WaitForTextPatternsSought = [string[]]@('Continue with autoinstall?')
        $f.WaitForTextBlankScreenSeconds = 1690
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 17
        Assert-Equal -Expected 1690 -Actual $r.File.context.causeDetail.blankScreenSeconds
        Assert-Equal -Expected 1690 -Actual $r.Event.causeBlankScreenSeconds
        Assert-Equal -Expected 'Continue with autoinstall?' -Actual @($r.File.context.causeDetail.patternsSought)[0]
    }
    It 'carries the hypervisor livelock verdict into the record and flat on the event' {
        $f = Reset-FailState
        $f.WaitForTextGuestLivelocked = $true
        $f.WaitForTextGuestLivelock = [pscustomobject]@{
            Verdict = 'livelocked'; LivelockedSeconds = 1230; MinimumSeconds = 300; VirtualProcessors = 1
            GuestRunPercent = 4.8; HypervisorRunPercent = 94.1; InterceptsPerSecond = 3690000
            InterceptBreakdown = [ordered]@{ 'SysReg Accesses/sec' = 3600000 }; DominantIntercept = 'SysReg Accesses/sec'
            SampleCount = 83; NewestSampleUtc = '2026-10-06T17:39:27.0000000Z'; Detail = 'd'; Reason = ''
        }
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 17
        $livelock = $r.File.context.causeDetail.guestLivelock
        Assert-Equal -Expected 'livelocked' -Actual $livelock.verdict
        Assert-Equal -Expected 1230 -Actual $livelock.livelockedSeconds
        Assert-Equal -Expected 'SysReg Accesses/sec' -Actual $livelock.dominantIntercept
        Assert-True ($r.Event.causeGuestLivelocked) 'the flat event must say the guest was livelocked'
        Assert-Equal -Expected 1230 -Actual $r.Event.causeGuestLivelockedSeconds
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event still validates; got: $($violations -join '; ')"
        Assert-Equal -Expected 'guest_kernel_stalled' -Actual $r.File.failureClass -Because 'every virtual processor held in the hypervisor for the whole window is a wedged guest kernel'
    }
    It 'keeps the livelock field present and null when no host recording was read' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 17
        Assert-True ($r.File.context.causeDetail.Contains('guestLivelock')) 'the field must always be present'
        Assert-True ($null -eq $r.File.context.causeDetail.guestLivelock) 'not measured must not read as measured and found running'
        Assert-True (-not $r.Event.causeGuestLivelocked) 'no verdict is not a livelock'
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.blankScreenSeconds
    }
    It 'omits causeDetail from a crash record context but keeps the flat event fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-True (-not $r.File.context.Contains('causeDetail')) 'crash context has no causeDetail'
        Assert-True ($r.Event.Contains('causeOcrTail')) 'crash event keeps the uniform flat field'
    }
}

Describe 'New-SequenceFailureRecord crash record backfill' {
    It 'reports reason=crash / classificationSource=crash and carries replay boundary + inner fields' {
        [void](Reset-FailState)
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $r = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-Equal -Expected 'crash' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'crash' -Actual $r.File.classificationSource -Because 'classificationSource'
        Assert-True ($r.File.Contains('lastSucceededStepNumber')) 'crash record carries replay boundary'
        Assert-Equal -Expected 2 -Actual $r.File.lastSucceededStepNumber -Because 'replay boundary value'
        Assert-True ($r.File.Contains('innerActionVerb')) 'crash record carries inner-cause slot'
        Assert-True ($null -ne $r.File.repro) 'crash record still has a repro block'
    }
}

Describe 'New-InfraFailureRecord (infra-stage failures)' {
    It 'builds a schema-v2 record with reason=infra / classificationSource=infra-stage' {
        $r = New-InfraFailureRecord -Stage 'New-VM' -FailureClass 'provisioning_failure' -Severity 'hard' -GuestKey 'guest.x' -VMName 'vm1' -HostType 'host.windows.hyper-v' -ErrorMessage 'define failed'
        Assert-Equal -Expected 2 -Actual $r.File.schemaVersion -Because 'schema v2'
        Assert-Equal -Expected 'infra' -Actual $r.File.reason -Because 'reason'
        Assert-Equal -Expected 'infra-stage' -Actual $r.File.classificationSource -Because 'classificationSource'
        Assert-Equal -Expected 'provisioning_failure' -Actual $r.File.failureClass -Because 'class'
        Assert-Equal -Expected 'New-VM' -Actual $r.File.actionVerb -Because 'stage as actionVerb'
        Assert-Equal -Expected 0 -Actual $r.File.stepNumber -Because 'no step for an infra stage'
        Assert-True (@($r.File.suggestedRecoveries) -is [array]) 'suggestedRecoveries is an array'
    }
    It 'preserves missing-service discovery evidence in the record and event' {
        $failures = @(@{ area = 'stash-service'; address = ''; endpoint = 'http://pool/extension-hosts?area=stash-service'
            outcome = 'no-host'; detail = '404 -- no live host'; attempt = 4 })
        $r = New-InfraFailureRecord -Stage 'Resolve-StashService' -FailureClass 'lab_dependency_down' `
            -ErrorMessage 'Stash service is unavailable' -DependencyFailures $failures
        $disk = $r.File | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $disk.context.dependencyFailures.Count | Should -Be 1
        $disk.context.dependencyFailures[0].area | Should -Be 'stash-service'
        $disk.context.dependencyFailures[0].endpoint | Should -Be $failures[0].endpoint
        $disk.context.dependencyFailures[0].detail | Should -Be '404 -- no live host'
        $r.Event.dependencyFailures[0].outcome | Should -Be 'no-host'
        @(Test-CycleEventSchema -Record $r.Event).Count | Should -Be 0
    }

    It 'emits an event that passes the cycle event schema validator (in-enum class)' {
        foreach ($cls in 'provisioning_failure','bootstrap_sync','plan_invalid','network_timeout') {
            $r = New-InfraFailureRecord -Stage 'GitPull' -FailureClass $cls -GuestKey '(bootstrap)' -ErrorMessage 'x'
            $v = Test-CycleEventSchema -Record $r.Event
            Assert-Equal -Expected 0 -Actual (@($v).Count) -Because "event for $cls must validate; got: $($v -join '; ')"
        }
    }

    # What the machine held when it refused is recoverable from nothing else the
    # cycle keeps -- those numbers exist only in the instant of the call -- so a
    # driver that measured them has to get them into the record and onto the
    # stream, and the file nests them while the event carries them flat.
    It 'carries a measured host memory position into the record and the event' {
        $reading = @{ availableMb = 1192; committedBytes = 46236958720; commitLimitBytes = 48257269760
                      commitAvailableBytes = 2020311040; source = 'Win32_OperatingSystem' }
        $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' `
            -VMName 'vm1' -HostType 'host.windows.hyper-v' -ErrorMessage 'refused' -HostMemory $reading
        $block = $r.File.context['hostMemory']
        Assert-NotNull $block 'a measured reading must reach the record'
        foreach ($key in 'availableMb', 'committedBytes', 'commitLimitBytes', 'commitAvailableBytes', 'source') {
            Assert-True ($block.Contains($key)) "the nested block must state $key"
        }
        Assert-Equal -Expected 'Win32_OperatingSystem' -Actual $block['source'] -Because 'the reading names where it came from'
        Assert-Equal -Expected 1192 -Actual $r.Event['hostAvailableMb'] -Because 'flat event field'
        Assert-Equal -Expected 46236958720 -Actual $r.Event['hostCommittedBytes'] -Because 'flat event field'
        Assert-Equal -Expected 48257269760 -Actual $r.Event['hostCommitLimitBytes'] -Because 'flat event field'
        Assert-Equal -Expected 2020311040 -Actual $r.Event['hostCommitAvailableBytes'] -Because 'flat event field'
        # A commit figure overflows Int32 on any host worth measuring, so the
        # width is part of the contract rather than an implementation detail.
        Assert-True ($r.Event['hostCommittedBytes'] -is [long]) 'byte counts must be Int64'
        $roundTrip = $r.File | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        Assert-Equal -Expected 48257269760 -Actual $roundTrip.context.hostMemory.commitLimitBytes `
            -Because 'the reading has to survive the serialization the record is stored and read through'
    }

    # ABSENT, never zeroed: a zeroed reading is indistinguishable from a measured
    # one, and a fabricated memory figure reads as a measurement. The drivers
    # that cannot measure their host state nothing at all.
    It 'preserves storage evidence and unavailable measurements in file and event JSON' {
        $storage = @{ status = 'insufficient'; timestamp = '2026-10-18T21:18:01Z'; errorCode = '0x80070070'; volumes = @(@{ volume = 'C:'; freeBytes = 10GB; requiredBytes = 14GB }, @{ volume = 'D:'; freeBytes = $null; requiredBytes = 2GB }); vms = @(@{ name = 'core'; runtimePath = 'C:\\VMs\\core'; startupMemoryBytes = 12GB }) }
        $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -VMName 'core' -HostStorage $storage
        $file = $r.File | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $eventRecord = $r.Event | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        foreach ($reading in @($file.context.hostStorage, $eventRecord.hostStorage)) {
            $reading.status | Should -Be 'insufficient'
            $reading.errorCode | Should -Be '0x80070070'
            $reading.volumes[0].requiredBytes | Should -Be 14GB
            $reading.volumes[1].freeBytes | Should -BeNullOrEmpty
            $reading.vms[0].name | Should -Be 'core'
        }
        @(Test-CycleEventSchema -Record $r.Event).Count | Should -Be 0
    }

    It 'omits storage evidence when no host measurement was supplied' {
        foreach ($reading in @($null, @{})) {
            $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -HostStorage $reading
            $r.File.context.Contains('hostStorage') | Should -BeFalse
            $r.Event.Contains('hostStorage') | Should -BeFalse
        }
    }

    It 'states no host memory at all when the driver could not measure it' {
        $cases = @(
            @{ Label = 'no argument'; Reading = $null; Pass = $false },
            @{ Label = 'an explicit null'; Reading = $null; Pass = $true },
            @{ Label = 'an empty reading'; Reading = @{}; Pass = $true },
            @{ Label = 'a partial reading with no commit limit'; Reading = @{ availableMb = 1192 }; Pass = $true }
        )
        foreach ($case in $cases) {
            $r = if ($case.Pass) {
                New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' -ErrorMessage 'refused' -HostMemory $case.Reading
            } else {
                New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' -ErrorMessage 'refused'
            }
            Assert-False ($r.File.context.Contains('hostMemory')) "$($case.Label): the record must carry no hostMemory block"
            foreach ($field in 'hostAvailableMb', 'hostCommittedBytes', 'hostCommitLimitBytes', 'hostCommitAvailableBytes') {
                Assert-False ($r.Event.Contains($field)) "$($case.Label): the event must not carry $field"
            }
        }
    }

    It 'emits an event that still validates with the host memory fields on it' {
        $reading = @{ availableMb = 1192; committedBytes = 46236958720; commitLimitBytes = 48257269760
                      commitAvailableBytes = 2020311040; source = 'Win32_PerfRawData_PerfOS_Memory' }
        $r = New-InfraFailureRecord -Stage 'Start-VM' -FailureClass 'provisioning_failure' -GuestKey 'guest.x' `
            -ErrorMessage 'refused' -HostMemory $reading
        $v = @(Test-CycleEventSchema -Record $r.Event)
        Assert-Equal -Expected 0 -Actual $v.Count -Because "a measured reading must not make the event invalid; got: $($v -join '; ')"
    }
}

Describe 'Orchestration preserves child dependency failures' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.Orchestrator.psm1'), [ref]$null, [ref]$null)
        $policy = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '-not $ok -and $env:YURUNA_LOG_DIR'
        }, $true)
        $script:InheritChildFailure = [scriptblock]::Create($policy.Extent.Text)
        function Copy-CycleFailureRecord { param([string]$LogDir) $null = $LogDir; $script:MirroredFailures++ }
    }
    It 'uses the child evidence only for a <Case> failure record' -TestCases @(
        @{ Case = 'fresh'; AgeSeconds = 1; ExpectedClass = 'lab_dependency_down'; ExpectedMessage = 'stash-service: 404 -- no live host'; ExpectedCopies = 1 }
        @{ Case = 'stale'; AgeSeconds = 30; ExpectedClass = 'unknown'; ExpectedMessage = 'Host action exited 1'; ExpectedCopies = 0 }
    ) {
        param($Case, $AgeSeconds, $ExpectedClass, $ExpectedMessage, $ExpectedCopies)
        $savedLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        try {
            $env:YURUNA_LOG_DIR = Join-Path $TestDrive $Case
            New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force | Out-Null
            $path = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
            @{ failureClass = 'lab_dependency_down'; description = 'stash-service: 404 -- no live host'
                context = @{ dependencyFailures = @(@{ area = 'stash-service'; outcome = 'no-host'; detail = '404 -- no live host' }) } } |
                ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddSeconds(-$AgeSeconds))
            $entryStartUtc = [datetime]::UtcNow.AddSeconds(-5)
            $ok = $false
            $reason = 'Host action exited 1'
            $inheritedClass = 'unknown'
            $inheritedDependencies = @()
            $null = @($entryStartUtc, $ok) # Read by the production policy scriptblock.
            $script:MirroredFailures = 0
            . $script:InheritChildFailure
            $inheritedClass | Should -Be $ExpectedClass
            $reason | Should -Be $ExpectedMessage
            $script:MirroredFailures | Should -Be $ExpectedCopies
            $inheritedDependencies.Count | Should -Be $ExpectedCopies
        } finally { Restore-YurunaTestEnvironment -Saved $savedLogDir }
    }
}

Describe 'Orchestration dependency record integration' {
    BeforeAll {
        foreach ($module in 'Test.SequenceFailureState.psm1', 'Test.StateFile.psm1', 'Test.Log.psm1', 'Test.RunnerInnerLoop.psm1') {
            Import-Module (Join-Path $PSScriptRoot $module) -Global -DisableNameChecking
        }
        . (Get-Module Test.RunnerInnerLoop) {
            function Send-CycleEventSafely {
                param([hashtable]$EventRecord)
                $EventRecord | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $env:YURUNA_LOG_DIR 'parent-event.json')
            }
        }
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.Orchestrator.psm1'), [ref]$null, [ref]$null)
        $policy = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '-not $ok -and $env:YURUNA_LOG_DIR'
        }, $true)
        $publish = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-CycleInfraFailure' -and $node.Extent.Text.Contains('$inheritedClass')
        }, $true)
        $script:InheritDependency = [scriptblock]::Create($policy.Extent.Text)
        $script:PublishDependency = [scriptblock]::Create($publish.Extent.Text)
    }
    AfterAll { Remove-Module Test.RunnerInnerLoop -Force -ErrorAction SilentlyContinue }
    It 'preserves the child record, its cycle mirror, and the parent event evidence' {
        $savedLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $savedGlobals = Save-YurunaTestGlobal -Name '__YurunaCycleFolder'
        try {
            $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'dependency-integration'
            $env:YURUNA_RUNTIME_DIR = $env:YURUNA_LOG_DIR
            $folder = Join-Path $env:YURUNA_LOG_DIR 'cycle'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $folder }
            $dependency = @{ area = 'stash-service'; endpoint = 'http://pool/extension-hosts?area=stash-service'
                outcome = 'no-host'; detail = '404 -- no live host'; attempt = 4 }
            $child = New-InfraFailureRecord -Stage 'Resolve-StashService' -FailureClass 'lab_dependency_down' `
                -ErrorMessage 'stash-service: 404 -- no live host' -DependencyFailures @($dependency)
            $path = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
            $child.File | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
            $entryStartUtc = [datetime]::UtcNow.AddSeconds(-5)
            $ok = $false; $reason = 'Host action exited 1'; $inheritedClass = 'unknown'; $inheritedDependencies = @()
            $entryVmName = ''; $HostType = 'host.windows.hyper-v'; $e = @{ name = 'initialize-lab' }
            $null = @($entryStartUtc, $ok, $reason, $inheritedClass, $inheritedDependencies, $entryVmName, $HostType, $e)
            . $script:InheritDependency
            . $script:PublishDependency
            $disk = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
            $mirror = Get-Content -Raw -LiteralPath (Join-Path $folder 'last_failure.json') | ConvertFrom-Json -AsHashtable
            $parentEvent = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_LOG_DIR 'parent-event.json') | ConvertFrom-Json -AsHashtable
            $disk.action | Should -Be 'Resolve-StashService'
            $disk.context.dependencyFailures[0].detail | Should -Be '404 -- no live host'
            $mirror.context.dependencyFailures[0].endpoint | Should -Be $dependency.endpoint
            $parentEvent.failureClass | Should -Be 'lab_dependency_down'
            $parentEvent.dependencyFailures[0].detail | Should -Be '404 -- no live host'
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedLog
            Restore-YurunaTestEnvironment -Saved $savedRuntime
            Restore-YurunaTestGlobal -Saved $savedGlobals
        }
    }
}

Describe 'A guest that never reached the stopped state' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global }
    It 'is filed as vm_not_stopped, carrying the observed state and the first silence' {
        [void](Reset-FailState)
        $f = Get-SequenceFailureState
        $f.StepVmNotStopped = @{ observedState = 'running'; waitedSeconds = 180; requestedAtUtc = '2026-10-12T21:54:57Z'; action = 'startVm' }
        $f.FirstGuestSilenceUtc = '2026-10-12T21:53:53Z'
        $f.FirstGuestSilenceSource = 'sshExec: transport dropped mid-command'
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.windows.hyper-v' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 19
        Assert-Equal -Expected 'vm_not_stopped' -Actual $r.File.failureClass -Because 'nothing was started, so the registry class for the verb does not describe the fault'
        Assert-False ((Get-FailureClassRoute -FailureClass $r.File.failureClass).UnattendedRetry) 'waiting again unattended for an ignored shutdown is not a repair'
        Assert-True ($r.File.suggestedRecoveries -notcontains 'retry_immediately') 'waiting again for an ignored shutdown is not a recovery'
        Assert-Equal -Expected 'running' -Actual $r.File.context.causeDetail.vmState -Because 'the host state at the deadline'
        Assert-Equal -Expected 180 -Actual $r.File.context.causeDetail.vmStateWaitedSeconds -Because 'how long the step waited'
        Assert-Equal -Expected '2026-10-12T21:53:53Z' -Actual $r.File.context.causeDetail.firstGuestSilenceUtc -Because 'the earliest symptom, not the step that gave up'
        Assert-Equal -Expected 'running' -Actual $r.Event.causeVmState -Because 'the event mirrors the state'
        Assert-Equal -Expected 180 -Actual $r.Event.causeVmStateWaitedSeconds -Because 'the event mirrors the wait'
        Assert-Equal -Expected 'sshExec: transport dropped mid-command' -Actual $r.Event.firstGuestSilenceSource -Because 'the event names the observer'
        $f.StepVmNotStopped = $null; $f.FirstGuestSilenceUtc = $null; $f.FirstGuestSilenceSource = $null
    }
    It 'leaves the state fields empty for a failure that waited on nothing' {
        [void](Reset-FailState)
        $f = Get-SequenceFailureState
        $f.StepVmNotStopped = $null; $f.FirstGuestSilenceUtc = $null; $f.FirstGuestSilenceSource = $null
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 11
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.File.failureClass -Because 'the registry class stands when no stopped-wait failed'
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.vmState -Because 'always present, empty when unobserved'
        Assert-Equal -Expected 0 -Actual $r.File.context.causeDetail.vmStateWaitedSeconds
        Assert-Equal -Expected '' -Actual $r.File.context.causeDetail.firstGuestSilenceUtc
    }
    # An install that powers the VM off at its end is waited for by startVm
    # with installPowerOff; no shutdown was requested, so a wait that never saw
    # the power-off is the install not finishing.
    It 'files an install that never powered off as the start verb''s provisioning failure, keeping the observed state' {
        $f = Reset-FailState
        $f.LastFailedAction = 'startVm'
        $f.StepVmNotStopped = @{ observedState = 'running'; waitedSeconds = 2400; requestedAtUtc = ''; action = 'startVm'; installPowerOff = $true }
        try {
            $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.macos.utm' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 19
            $r.File.failureClass | Should -BeExactly 'provisioning_failure' -Because 'no shutdown was requested, so none was ignored'
            $r.Event.failureClass | Should -BeExactly 'provisioning_failure'
            $r.File.context.causeDetail.vmState | Should -BeExactly 'running' -Because 'the host state at the deadline is still the evidence'
            $r.File.context.causeDetail.vmStateWaitedSeconds | Should -Be 2400
            (Get-FailureClassRoute -FailureClass $r.File.failureClass).UnattendedRetry | Should -BeFalse
        } finally { $f.StepVmNotStopped = $null }
    }
    It 'still files a start whose requested shutdown never came as vm_not_stopped' {
        $f = Reset-FailState
        $f.LastFailedAction = 'startVm'
        $f.StepVmNotStopped = @{ observedState = 'running'; waitedSeconds = 120; requestedAtUtc = '2026-10-12T21:54:57Z'; action = 'startVm' }
        try {
            $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.windows.hyper-v' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 19
            $r.File.failureClass | Should -BeExactly 'vm_not_stopped'
        } finally { $f.StepVmNotStopped = $null }
    }
    It 'is documented as vm_not_stopped wherever a doc names the class of a stop that never came' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $read = { param([string]$Relative) [IO.File]::ReadAllText((Join-Path $repoRoot $Relative)) }
        $schema = & $read 'docs/failure-schema.md'
        $schemaPtBr = & $read 'docs/pt-BR/failure-schema.md'
        $flows = & $read 'docs/design/03-data-flows.md'
        $lifecycle = & $read 'docs/design/04-lifecycle-state.md'
        $sequences = & $read 'docs/test-sequences.md'
        $schema | Should -Match '(?m)^\| `vmState` / .*The class is then `vm_not_stopped`'
        $schemaPtBr | Should -Match '(?m)^\| `vmState` / .*A classe passa a ser `vm_not_stopped`'
        $flows | Should -Match ([regex]::Escape('a guest that ignores the request fails as `vm_not_stopped` with that evidence'))
        $lifecycle | Should -Match ([regex]::Escape('`Start-GuestOS` fails as `vm_not_stopped`'))
        $sequences | Should -Match 'When the VM never reports stopped, the step fails as\s+`vm_not_stopped`'
        $sequences | Should -Match 'absent fails as\s+`provisioning_failure`'
        $schema | Should -Not -Match 'The class is then `wait_timeout`'
        $schemaPtBr | Should -Not -Match 'passa a ser `wait_timeout`'
        $flows | Should -Not -Match ([regex]::Escape('fails as `wait_timeout` with that evidence'))
        $lifecycle | Should -Not -Match ([regex]::Escape('`Start-GuestOS` fails as `wait_timeout`'))
        $sequences | Should -Not -Match 'the step fails as\s+`wait_timeout`'
    }
}

# A wedged guest kernel was filed under whatever the waiting verb registered --
# wait_timeout for a fetch, ocr_timeout for a screen wait -- so its retries
# spent the budget real step timeouts need, and a screen wait on it was never
# retried unattended at all.
Describe 'A wait that ended on a wedged guest kernel' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global
        function New-KernelStallEnd {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: returns an in-memory reading.')]
            [OutputType([System.Collections.Specialized.OrderedDictionary])]
            param()
            return [ordered]@{ basis = 'no-interrupts-serviced'; processors = [string[]]@('1'); noInterruptsServicedSeconds = 210
                noInterruptsServicedSinceUtc = '2026-10-29T08:56:28.0000000Z'; kinds = [string[]]@('rcu-stall')
                outputStaticSeconds = 240; recorderUploadAgeSeconds = 230; waitedSeconds = 311 }
        }
        function New-LivelockVerdict {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: returns an in-memory verdict.')]
            [OutputType([pscustomobject])]
            param([int]$VirtualProcessors)
            return [pscustomobject]@{
                Verdict = 'livelocked'; LivelockedSeconds = 345; MinimumSeconds = 300; VirtualProcessors = $VirtualProcessors
                GuestRunPercent = 3.1; HypervisorRunPercent = 95.2; InterceptsPerSecond = 3500000
                InterceptBreakdown = [ordered]@{}; DominantIntercept = 'SysReg Accesses/sec'; SampleCount = 70
                NewestSampleUtc = '2026-10-29T09:01:30.0000000Z'; Detail = 'd'; Reason = ''; ProcessorWindow = $null
            }
        }
        function New-StalledRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory failure record.')]
            [OutputType([hashtable])]
            param()
            return New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.windows.hyper-v' `
                -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 9
        }
    }
    It 'files a kernel-stall end under guest_kernel_stalled' {
        $f = Reset-FailState
        $f.WaitForTextKernelStallEnd = New-KernelStallEnd
        $r = New-StalledRecord
        $r.File.failureClass | Should -BeExactly 'guest_kernel_stalled'
        $r.Event.failureClass | Should -BeExactly 'guest_kernel_stalled'
        @($r.File.suggestedRecoveries) | Should -Contain 'retry_with_backoff'
        $r.File.context.causeDetail.guestKernelStallEnd.basis | Should -BeExactly 'no-interrupts-serviced'
        $r.File.docUrl | Should -BeLike '*#failure-class-guest_kernel_stalled'
        @(Test-CycleEventSchema -Record $r.Event).Count | Should -Be 0 -Because 'the class is in the canonical enum'
    }
    It 'files a wait whose host reading held every processor in the hypervisor' {
        $f = Reset-FailState
        $f.WaitForTextGuestLivelock = New-LivelockVerdict -VirtualProcessors 2
        $f.WaitForTextGuestLivelocked = $true
        $r = New-StalledRecord
        $r.File.failureClass | Should -BeExactly 'guest_kernel_stalled'
        $r.Event.causeGuestLivelocked | Should -BeTrue
        $r.Event.causeGuestLivelockedSeconds | Should -Be 345
    }
    It 'files an unregistered verb''s stall under the class' {
        $f = Reset-FailState
        $f.LastFailedAction = 'fetchAndExecute'
        $f.WaitForTextKernelStallEnd = New-KernelStallEnd
        $r = New-StalledRecord
        $r.File.failureClass | Should -BeExactly 'guest_kernel_stalled' -Because 'the wait''s own evidence names the cause whatever the verb registered'
    }
    It 'outranks the console flood a wedged kernel prints' {
        $f = Reset-FailState
        $f.WaitForTextConsoleFlood = 'rcu: INFO: rcu_sched self-detected stall on CPU (38 of 48 lines)'
        $f.WaitForTextKernelStallEnd = New-KernelStallEnd
        $r = New-StalledRecord
        $r.File.failureClass | Should -BeExactly 'guest_kernel_stalled'
        $r.File.context.causeDetail.consoleFlood | Should -Match 'rcu_sched' -Because 'the flood stays in the record as evidence'
    }
    It 'keeps the guest''s own failure statement first' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'FAILED'
        $f.WaitForTextKernelStallEnd = New-KernelStallEnd
        (New-StalledRecord).File.failureClass | Should -BeExactly 'pattern_matched_failure'
    }
    It 'leaves a display-only verdict to the verb''s class' {
        $f = Reset-FailState
        $verdict = New-LivelockVerdict -VirtualProcessors 0
        $verdict | Add-Member -NotePropertyName ConsoleSecondOpinion -NotePropertyValue ([pscustomobject]@{ Verdict = 'guest-wedged'; Detail = 'frames identical' })
        $f.WaitForTextGuestLivelock = $verdict
        $f.WaitForTextGuestLivelocked = $true
        $f.WaitForTextConsoleSecondOpinion = $verdict.ConsoleSecondOpinion
        (New-StalledRecord).File.failureClass | Should -BeExactly 'ocr_timeout' -Because 'an inactive display with a busy emulator does not identify a kernel defect'
    }
    It 'leaves a guest clock anomaly on its own to the verb''s class' {
        $f = Reset-FailState
        $f.StepProgressAdvisory = Get-GuestProgressAdvisory -SshResponsiveness responsive -ClockWarningCodes @('cpu-idle-exceeds-boot-uptime')
        (New-StalledRecord).File.failureClass | Should -BeExactly 'ocr_timeout' -Because 'a clock that jumped is never a stall signal on its own'
    }
}

Describe 'Independent console observations survive failure serialization' {
    It 'retains a busy inactive VM as evidence without granting recovery' {
        $f = Reset-FailState
        $f.WaitForTextConsoleSecondOpinion = [pscustomobject]@{
            Verdict = 'guest-wedged'; Detail = 'Independent VNC frames are identical; QEMU remains busy.'
            ObservedAtUtc = '2026-10-21T11:19:48Z'; VMName = 'vm1'; VMState = 'running'
            QemuPid = 4321; VncPort = 5983; IntervalSeconds = 5
            FirstFrameSha256 = 'ABC'; SecondFrameSha256 = 'ABC'; FramesChanged = $false
            FirstCpuSeconds = 100.0; SecondCpuSeconds = 139.1; CpuPercent = 782.0
        }
        $f.StepProgressAdvisory = Get-GuestProgressAdvisory -OutputStaticSeconds 2485
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.macos.utm' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 19
        $disk = $r.File | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $eventRecord = $r.Event | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $disk.context.causeDetail.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
        $disk.context.causeDetail.consoleSecondOpinion.QemuPid | Should -Be 4321
        $disk.context.causeDetail.consoleSecondOpinion.CpuPercent | Should -Be 782.0
        $disk.context.causeDetail.consoleSecondOpinion.FramesChanged | Should -BeFalse
        $eventRecord.consoleSecondOpinion | ConvertTo-Json -Compress | Should -Be ($disk.context.causeDetail.consoleSecondOpinion | ConvertTo-Json -Compress)
        $disk.context.causeDetail.progressAdvisory.automaticRecoveryAllowed | Should -BeFalse
        $disk.failureClass | Should -Be 'ocr_timeout'
    }
    It 'preserves unavailable readings as null rather than idle measurements' {
        $f = Reset-FailState
        $f.WaitForTextConsoleSecondOpinion = [pscustomobject]@{ Verdict = 'unavailable'; Detail = 'VNC unavailable'; CpuPercent = $null; FramesChanged = $null }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -HostType 'host.macos.utm' -SequencePath $script:seqPath -LogDir 'd'
        $disk = $r.File | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $disk.context.causeDetail.consoleSecondOpinion.Verdict | Should -Be 'unavailable'
        $disk.context.causeDetail.consoleSecondOpinion.ContainsKey('CpuPercent') | Should -BeTrue
        $disk.context.causeDetail.consoleSecondOpinion.CpuPercent | Should -BeNullOrEmpty
        $disk.context.causeDetail.consoleSecondOpinion.FramesChanged | Should -BeNullOrEmpty
    }
    It 'distinguishes no independent probe from a probe with unavailable measurements' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd'
        $r.File.context.causeDetail.Contains('consoleSecondOpinion') | Should -BeTrue
        $r.File.context.causeDetail.consoleSecondOpinion | Should -BeNullOrEmpty
        $r.Event.ContainsKey('consoleSecondOpinion') | Should -BeTrue
        $r.Event.consoleSecondOpinion | Should -BeNullOrEmpty
    }
}

# Drop the module the stub was dot-sourced into, so nothing this file defined is
# visible to the files that run after it in the shared runspace.
AfterAll {
    Remove-Module Test.SequenceFailureState -Force -ErrorAction SilentlyContinue
}

# A run its supervisor could not account for was filed as
# instrumentation_failure, which is retried unattended as safe to repeat.
Describe 'A guest run that was lost' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global }
    It 'has its own class, routed to a restore rather than an unattended re-run' {
        [void](Reset-FailState)
        $f = Get-SequenceFailureState
        $f.StepGuestRunLost = $true
        try {
            $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.ubuntu.kvm' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 3
            Assert-Equal -Expected 'guest_run_lost' -Actual $r.File.failureClass
            Assert-True ($r.File.suggestedRecoveries -contains 'restart_from_snapshot') 'a restore is the recovery'
            $route = Get-FailureClassRoute -FailureClass $r.File.failureClass
            Assert-False ($route.UnattendedRetry -or $route.WarmResume) 'a lost run is neither retried unattended nor resumed in place'
        } finally { $f.StepGuestRunLost = $null }
    }
}


Describe 'A step whose handler proved it did nothing' {
    It 'carries the proof and its source for the step that published it' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'step-a'
        $f.StepEffect = [ordered]@{ effect = 'none-proven'; source = 'address-unresolved'; stepInvocationId = 'step-a' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'none-proven' -Actual $r.File.stepEffect
        Assert-Equal -Expected 'address-unresolved' -Actual $r.File.stepEffectSource
        Assert-Equal -Expected 'none-proven' -Actual $r.Event.stepEffect -Because 'the event mirrors the record'
        $f.StepEffect = $null
    }
    It 'ignores the proof of a step other than the one that failed' {
        # A retry wrapper fails after its inner step published a proof: the
        # inner step did nothing, but the wrapper may have run other steps.
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'wrapper'
        $f.StepEffect = [ordered]@{ effect = 'none-proven'; source = 'no-source-served'; stepInvocationId = 'inner' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unknown' -Actual $r.File.stepEffect
        Assert-Equal -Expected '' -Actual $r.File.stepEffectSource
        $f.StepEffect = $null
    }
    It 'lets a matched failure pattern outrank the proof' {
        $f = Reset-FailState
        $f.LastFailedStepInvocationId = 'step-a'
        $f.WaitForTextMatchedFailurePattern = 'FAILED'
        $f.StepEffect = [ordered]@{ effect = 'none-proven'; source = 'address-unresolved'; stepInvocationId = 'step-a' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'guest.ubuntu.server.24' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unknown' -Actual $r.File.stepEffect -Because 'the guest announced its own failure, so it ran'
        $f.StepEffect = $null; $f.WaitForTextMatchedFailurePattern = $null
    }
    It 'reports nothing proven when no handler published a proof, and on a crash' {
        [void](Reset-FailState)
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'unknown' -Actual $r.File.stepEffect
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $c = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        Assert-Equal -Expected 'unknown' -Actual $c.File.stepEffect
        Assert-Equal -Expected '' -Actual $c.File.stepEffectSource
    }
}

Describe 'A send the host can never make' {
    BeforeAll {
        function Set-InputFaultState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: seeds the in-memory failure-state slots; no external state.')]
            param([string]$Kind, [string]$FaultStep = 'step-a')
            $f = Reset-FailState
            $f.LastFailedAction = 'inputText'
            $f.LastFailedStepInvocationId = 'step-a'
            $f.StepHostInputFault = [ordered]@{ action = 'Send-Text'; stepInvocationId = $FaultStep; kind = $Kind
                reason = $(if ($Kind -eq 'deterministic') { 'unmappable-character' } else { 'write-failed' })
                transport = 'VNC'; detail = 'U+00E9 at 4'; delivered = 0; total = 9 }
            return $f
        }
    }
    It 'files text the input path has no key for as plan_invalid, with the fault in the record' {
        $f = Set-InputFaultState -Kind deterministic
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'plan_invalid' -Actual $r.File.failureClass -Because 'every retry would fail the same way'
        Assert-Equal -Expected 'pause_and_inspect' -Actual @($r.File.suggestedRecoveries)[0]
        $fault = $r.File.context.causeDetail.hostInputFault
        Assert-Equal -Expected 'unmappable-character' -Actual $fault.reason
        Assert-Equal -Expected 'U+00E9 at 4' -Actual $fault.detail
        Assert-Equal -Expected 9 -Actual $fault.total
        Assert-Equal -Expected 'unmappable-character' -Actual $r.Event.causeHostInputFault -Because 'the event mirrors the record'
        Assert-True (Test-StepHostInputFaultDeterministic) 'the retry verb reads the same verdict'
        $f.StepHostInputFault = $null
    }
    It 'keeps the retryable class for a transient fault, and still records it' {
        $f = Set-InputFaultState -Kind transient
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'host_io_blocked' -Actual $r.File.failureClass
        Assert-Equal -Expected 'write-failed' -Actual $r.File.context.causeDetail.hostInputFault.reason
        Assert-False (Test-StepHostInputFaultDeterministic) 'a closed connection may clear on the next attempt'
        $f.StepHostInputFault = $null
    }
    It 'ignores a fault another step recorded' {
        $f = Set-InputFaultState -Kind deterministic -FaultStep 'inner'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'host_io_blocked' -Actual $r.File.failureClass
        Assert-True ($null -eq $r.File.context.causeDetail.hostInputFault) 'only the failing step''s own send counts'
        Assert-Equal -Expected '' -Actual $r.Event.causeHostInputFault
        Assert-False (Test-StepHostInputFaultDeterministic) 'nor for the retry verb'
        $f.StepHostInputFault = $null
    }
    It 'gives way to a matched failure pattern' {
        $f = Set-InputFaultState -Kind deterministic
        $f.WaitForTextMatchedFailurePattern = 'FAILED'
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
        $f.StepHostInputFault = $null; $f.WaitForTextMatchedFailurePattern = $null
    }
    It 'emits an event that passes the cycle event schema validator' {
        $f = Set-InputFaultState -Kind deterministic
        $r = New-SequenceFailureRecord -Reason step -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        $violations = Test-CycleEventSchema -Record $r.Event
        Assert-Equal -Expected 0 -Actual (@($violations).Count) -Because "event must validate; got: $($violations -join '; ')"
        $f.StepHostInputFault = $null
    }
}

Describe 'A deploy that reported its own failure class' {
    It 'is filed under that class, from the deploy result' {
        $f = Reset-FailState
        $f.StepDeployResult = @{ failureClass = 'plan_invalid'; deployFailureClass = 'chart_invalid'; errorMessage = 'lint failed' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'plan_invalid' -Actual $r.File.failureClass
        Assert-Equal -Expected 'deploy-result' -Actual $r.File.classificationSource
        Assert-Equal -Expected @('pause_and_inspect') -Actual @($r.File.suggestedRecoveries)
        $f.StepDeployResult = $null
    }
    It 'suggests a backed-off retry for a deploy that could not reach what it needed' {
        $f = Reset-FailState
        $f.StepDeployResult = @{ failureClass = 'network_timeout'; deployFailureClass = 'cluster_unreachable'; errorMessage = '' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'network_timeout' -Actual $r.File.failureClass
        Assert-True ($r.File.suggestedRecoveries -contains 'retry_with_backoff') 'the class''s own recovery'
        $f.StepDeployResult = $null
    }
    It 'gives way to a matched failure pattern' {
        $f = Reset-FailState
        $f.WaitForTextMatchedFailurePattern = 'FAILED'
        $f.StepDeployResult = @{ failureClass = 'plan_invalid'; deployFailureClass = 'chart_invalid'; errorMessage = '' }
        $r = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        Assert-Equal -Expected 'pattern_matched_failure' -Actual $r.File.failureClass
        $f.StepDeployResult = $null; $f.WaitForTextMatchedFailurePattern = $null
    }
}

Describe 'Every failure record links its class''s documentation' {
    It 'carries docUrl on step, crash and infra records and their events' {
        [void](Reset-FailState)
        $step = New-SequenceFailureRecord -Reason step -VMName 'vm1' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5
        # The schema link and the anchor are joined here: a literal link with a
        # placeholder for its anchor reads to the anchor gate as a broken pointer.
        $schema = 'https://yuruna.link/42820e91'
        $step.File.docUrl | Should -BeExactly ($schema + '#failure-class-' + $step.File.failureClass)
        $step.Event.docUrl | Should -BeExactly $step.File.docUrl
        $err = $null
        try { throw 'boom' } catch { $err = $_ }
        $crash = New-SequenceFailureRecord -Reason crash -VMName 'v' -GuestKey 'g' -HostType 'h' -SequencePath $script:seqPath -LogDir 'd' -TotalSteps 5 -CrashError $err
        $crash.File.docUrl | Should -BeExactly ($schema + '#failure-class-' + $crash.File.failureClass)
        $infra = New-InfraFailureRecord -Stage 'GetImage' -FailureClass 'source_integrity' -Severity 'hard' -GuestKey 'g' -VMName 'vm1' -ErrorMessage 'checksum' -HostType 'h'
        $infra.File.docUrl | Should -BeExactly 'https://yuruna.link/42820e91#failure-class-source_integrity'
        $infra.Event.docUrl | Should -BeExactly $infra.File.docUrl
    }
}

Describe 'The failure-state slots are declared once, with a lifetime' {
    It 'declares every slot once, each with a known lifetime' {
        $slots = @(Get-SequenceFailureSlot)
        Assert-True ($slots.Count -gt 40) "only $($slots.Count) slots declared"
        $duplicates = @($slots | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
        Assert-Equal -Expected 0 -Actual $duplicates.Count -Because "declared twice: $($duplicates -join ', ')"
        foreach ($slot in $slots) { Assert-True ($slot.Lifetime -in 'sequence', 'step', 'wait', 'gate', 'process') "$($slot.Name): $($slot.Lifetime)" }
        $store = Get-SequenceFailureState
        foreach ($slot in $slots) { Assert-True ($store.Contains($slot.Name)) "the live store lacks $($slot.Name)" }
    }

    It 'nests the resets: a sequence clears step and wait slots, a step clears wait slots, a wait only its own' {
        $byLifetime = @{}
        foreach ($slot in Get-SequenceFailureSlot) { $byLifetime[$slot.Lifetime] = $slot.Name }
        foreach ($case in @(
                @{ Reset = 'wait';     Cleared = @('wait');                     Kept = @('step', 'sequence', 'gate', 'process') }
                @{ Reset = 'step';     Cleared = @('wait', 'step');             Kept = @('sequence', 'gate', 'process') }
                @{ Reset = 'sequence'; Cleared = @('wait', 'step', 'sequence'); Kept = @('gate', 'process') })) {
            $state = [ordered]@{}
            foreach ($lifetime in $byLifetime.Keys) { $state[$byLifetime[$lifetime]] = 'stale' }
            Reset-SequenceFailureSlot -Lifetime $case.Reset -State $state
            foreach ($lifetime in $case.Cleared) {
                Assert-True ($state[$byLifetime[$lifetime]] -ne 'stale') "a $($case.Reset) reset must clear the $lifetime slot $($byLifetime[$lifetime])"
            }
            foreach ($lifetime in $case.Kept) {
                Assert-Equal -Expected 'stale' -Actual $state[$byLifetime[$lifetime]] -Because "a $($case.Reset) reset leaves the $lifetime slot to its owner"
            }
        }
    }

    It 'puts every slot back to the value a fresh store holds, with a new array each time' {
        $fresh = [ordered]@{}
        Reset-SequenceFailureSlot -Lifetime sequence -State $fresh
        $first = $fresh.WaitForTextPatternsSought
        Assert-True ($first -is [string[]]) 'the array slots stay [string[]], so the record renders a JSON array'
        $first += 'sought'
        $again = [ordered]@{}
        Reset-SequenceFailureSlot -Lifetime sequence -State $again
        Assert-Equal -Expected 0 -Actual $again.WaitForTextPatternsSought.Count -Because 'no two resets share an array'
        Assert-Equal -Expected 0 -Actual $again.LastFailedStepNumber
        Assert-Equal -Expected $true -Actual $again.WaitForTextConsoleSignalsMeasured
        Assert-Equal -Expected '' -Actual $again.LastFailedStepInvocationId
    }

    It 'keeps live failure state across a re-import and seeds a slot the store lacks' {
        $store = Get-SequenceFailureState
        $savedLabel = $store.LastFailureLabel
        $savedSlot = $store.StepInputLost
        try {
            $store.LastFailureLabel = 'live label'
            $store.Remove('StepInputLost')
            Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.SequenceFailureState.psm1') -Force -DisableNameChecking
            $after = Get-SequenceFailureState
            Assert-True ([object]::ReferenceEquals($store, $after)) 'callers cache the store by reference'
            Assert-Equal -Expected 'live label' -Actual $after.LastFailureLabel
            Assert-True ($after.Contains('StepInputLost')) 'a declared slot the store lacked is seeded'
        } finally {
            $store.LastFailureLabel = $savedLabel
            $store.StepInputLost = $savedSlot
        }
    }

    It 'names only declared slots in the modules that read and write the store' {
        # The store is a dictionary: a misspelled slot is silently a new one,
        # written by one module and never read by the record.
        $declared = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-SequenceFailureSlot | ForEach-Object Name), [StringComparer]::Ordinal)
        $here = Split-Path -Parent $PSCommandPath
        $unknown = foreach ($file in 'Test.SequenceEngine.psm1', 'Test.SequenceHandler.psm1', 'Test.SequenceFailureState.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $here $file), [ref]$null, [ref]$null)
            $uses = $ast.FindAll({ param($n)
                ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    ($n.Expression.VariablePath.UserPath -ceq 'script:Fail' -or
                        ($file -eq 'Test.SequenceFailureState.psm1' -and $n.Expression.VariablePath.UserPath -cin @('fail', 'State')))) -or
                ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and
                    $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Target.VariablePath.UserPath -in @('script:Fail', 'Store') -and
                    $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst])
            }, $true)
            foreach ($use in $uses) {
                $name = if ($use -is [System.Management.Automation.Language.IndexExpressionAst]) { $use.Index.Value } else { $use.Member.Value }
                if (-not $declared.Contains($name)) { "${file}:$($use.Extent.StartLineNumber) $name" }
            }
        }
        Assert-Equal -Expected 0 -Actual @($unknown).Count -Because "undeclared slots: $(@($unknown) -join '; ')"
    }
}

Describe 'A failed wait leaves its evidence through one writer' {
    BeforeEach {
        # Wildcard characters in the folder and the VM name: a copy by -Path
        # reads them as a pattern and copies nothing.
        $script:EvidenceRoot = Join-Path $TestDrive 'screens[1]'
        $script:EvidenceLog = Join-Path $TestDrive 'log'
        $null = New-Item -ItemType Directory -Path $script:EvidenceRoot, $script:EvidenceLog -Force
        $script:EvidenceFrame = Join-Path $script:EvidenceRoot 'raw_1.png'
        [IO.File]::WriteAllBytes($script:EvidenceFrame, [byte[]](1, 2, 3))
        $script:EvidenceState = [ordered]@{}
        Reset-SequenceFailureSlot -Lifetime sequence -State $script:EvidenceState
    }

    It 'copies the frame and the text beside the record, even under wildcard characters, and keeps the last 1200 characters' {
        $text = ('x' * 1300) + 'tail'
        Save-WaitFailureEvidence -State $script:EvidenceState -LogDir $script:EvidenceLog -VMName 'vm[1]' -CapturePath $script:EvidenceFrame `
            -OcrText $text -Pattern 'login:' -LivelockVerdict ([pscustomobject]@{ Verdict = 'livelocked' }) 6>$null
        Assert-True (Test-Path -LiteralPath (Join-Path $script:EvidenceLog 'failure_screenshot_vm[1].png')) 'the frame is copied'
        Assert-Equal -Expected $text -Actual (Get-Content -LiteralPath (Join-Path $script:EvidenceLog 'failure_ocr_vm[1].txt') -Raw).TrimEnd()
        Assert-Equal -Expected 1200 -Actual $script:EvidenceState.WaitForTextOcrTail.Length
        Assert-True ($script:EvidenceState.WaitForTextOcrTail.EndsWith('tail')) 'the record keeps the end of the text'
        Assert-Equal -Expected 'login:' -Actual (@($script:EvidenceState.WaitForTextPatternsSought) -join ',')
        Assert-True $script:EvidenceState.WaitForTextGuestLivelocked 'the verdict is recorded'
    }

    It 'records what was sought on a console that read blank, and writes no text file' {
        Save-WaitFailureEvidence -State $script:EvidenceState -LogDir $script:EvidenceLog -VMName 'vm1' -CapturePath $script:EvidenceFrame -OcrText '' -Pattern 'login:' 6>$null
        Assert-Equal -Expected 'login:' -Actual (@($script:EvidenceState.WaitForTextPatternsSought) -join ',')
        Assert-False (Test-Path -LiteralPath (Join-Path $script:EvidenceLog 'failure_ocr_vm1.txt')) 'no text, no text file'
        Assert-True ($null -eq $script:EvidenceState.WaitForTextOcrTail) 'no text, no tail'
    }

    It 'leaves the sought patterns alone for a wait that sought no text' {
        $script:EvidenceState.WaitForTextPatternsSought = [string[]]@('earlier')
        Save-WaitFailureEvidence -State $script:EvidenceState -LogDir $script:EvidenceLog -VMName 'vm1' -CapturePath $script:EvidenceFrame -OcrText 'stopping' 6>$null
        Assert-Equal -Expected 'earlier' -Actual (@($script:EvidenceState.WaitForTextPatternsSought) -join ',')
        Assert-Equal -Expected 'stopping' -Actual $script:EvidenceState.WaitForTextOcrTail
    }

    It 'is the only writer of the failure frame and text in the sequence modules' {
        $here = Split-Path -Parent $PSCommandPath
        foreach ($file in 'Test.SequenceEngine.psm1', 'Test.SequenceHandler.psm1') {
            $text = Get-Content -Raw -LiteralPath (Join-Path $here $file)
            Assert-False ($text -match 'failure_ocr_') "$file writes failure_ocr_ itself"
            Assert-False ($text -match 'Copy-Item[^\r\n]*failure_screenshot_|failure_screenshot_[^\r\n]*\r?\n\s*Copy-Item') "$file copies a failure frame itself"
            Assert-True ($text -match 'Save-WaitFailureEvidence -State \$script:Fail') "$file must use the shared writer"
        }
    }
}
