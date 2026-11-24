<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42e6d9c8-1705-43a2-89f3-6013cc25bb54
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking
    # Captured before any Mock: a filtered mock alone fails the calls its
    # filter does not match, and this suite relies on the real command there.
    $script:RealActionHandler = & (Get-Module Test.SequenceEngine) { Get-Command Invoke-SequenceActionHandler }
    Import-Module (Join-Path $PSScriptRoot 'Test.PerfAggregate.psm1') -Force -Global -DisableNameChecking
    $script:PriorRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
    $script:PriorLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'log'
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR -Force
}
AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:PriorRuntime
    Restore-YurunaTestEnvironment -Saved $script:PriorLog
}

Describe 'real sequence execution preserves source positions and current-step causes' {
    BeforeEach {
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { throw 'a fixture must never capture a live VM' }
        Mock Read-SequenceFile -ModuleName Test.SequenceEngine { $script:FixtureSequence }
        $script:FixtureRows = [Collections.Generic.List[object]]::new()
        $rows = $script:FixtureRows
        # What a step writes to the guest's serial console while it runs.
        $serialPath = Join-Path $TestDrive 'fixture-serial.log'
        Register-SequenceAction -Name safetyFixture -ReplaySafety observe -CapturesOwnFailureScreenshot $true -Handler {
            param($context)
            $state = Get-SequenceFailureState
            $rows.Add(@{ Number=$context.StepNum; StepCount=$context.StepCount; RunLost=$state.StepGuestRunLost; Tail=$state.WaitForTextOcrTail; StepInvocationId=$context.StepInvocationId; SequenceInvocationId=$context.SequenceInvocationId })
            if ($context.Step.appendSerial) { [IO.File]::AppendAllText($serialPath, [string]$context.Step.appendSerial) }
            if ($context.Step.seedEvidence) {
                $state.WaitForTextOutputStaticSeconds=200
                $context.ExecutionProfile=@{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-timeout'; timedOut=$true; sshResponsive=$false; recorder=@{heartbeatAgeSeconds=180} }
            }
            if ($context.Step.seedUnreachable) {
                # The client's own connect failure: no harness kill, no log, a dead path.
                $context.ExecutionProfile=@{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-unreachable'; timedOut=$false; transportFailed=$true; transport='unreachable'; sshResponsive=$false
                    recorder=@{ heartbeatAgeSeconds=256; clockAnalysis=@{ comparison='same-boot'; warnings=@(@{ code='cpu-idle-exceeds-boot-uptime'; cpu='cpu0' }) } } }
            }
            if ($context.Step.seedOldCause) { $state.StepGuestRunLost=$true; $state.WaitForTextOcrTail='old OCR text' }
            if ($context.Step.throwNow) { throw 'fixture handler crash' }
            if ($context.Step.seedConsoleEvidence) {
                $state.WaitForTextConsoleSecondOpinion = [pscustomobject]@{ Verdict='guest-wedged'; Detail='independent VNC read'; QemuPid=4321; VncPort=5983; CpuPercent=782; FramesChanged=$false }
            }
            if ($context.Step.seedSilentProcessor) {
                # The host recording's reading at the failed wait: a one-processor
                # guest whose processor serviced no interrupt for 90 seconds.
                $state.WaitForTextGuestLivelock = [pscustomobject]@{ Verdict='not-livelocked'; LivelockedSeconds=90; MinimumSeconds=300; VirtualProcessors=1
                    ProcessorWindow=[pscustomobject]@{ StormedProcessors=@('0'); NoInterruptsServicedProcessors=@()
                        Processors=@([pscustomobject]@{ Processor='0'; Stormed=$true; NoInterruptsServicedSeconds=90 }) } }
            }
            if ($context.Step.children) {
                $childResult = & $context.InvokeStepBlock -Steps $context.Step.children -ParentOrdinal $context.StepNum -ParentAction safetyFixture -ParentAttempt 1
                if ($context.Step.throwAfterChildren) { throw 'fixture outer handler crash' }
                return $childResult
            }
            if ($context.Step.failFirstAttempt) { return $rows.Count -gt 1 }
            return -not [bool]$context.Step.fail
        }.GetNewClosure()
        $script:SequenceFile = Join-Path $TestDrive 'fixture.yml'
        Set-Content $script:SequenceFile 'fixture: mocked parser'
    }
    It 'reads a client-side connect failure as an unresponsive transport and lists the recorder clock anomaly' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedUnreachable=$true;fail=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
        $advisory = $record.context.causeDetail.progressAdvisory
        $advisory.SshResponsiveness | Should -Be unresponsive
        $advisory.Verdict | Should -Be 'progress-suspect'
        $advisory.Signals | Should -Contain 'guest-clock-anomaly'
        $advisory.ClockWarnings | Should -Contain 'cpu-idle-exceeds-boot-uptime'
        $advisory.AutomaticRecoveryAllowed | Should -BeFalse
    }
    It 'files a tapOn step with an invalid option as plan_invalid before anything is captured' {
        $script:CaptureSources = [Collections.Generic.List[string]]::new()
        # The engine's own post-failure capture still runs, with the default
        # frame source, because tapOn saved no frame.
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $script:CaptureSources.Add([string]$Source); $false }
        $script:FixtureSequence = @{ steps = @(@{ action = 'tapOn'; label = 'Next'; match = 'fuzzy' }) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile 3>$null | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
        $record.failureClass | Should -Be 'plan_invalid'
        $record.context.causeDetail.hostInputFault.reason | Should -Be 'invalid-argument'
        $script:CaptureSources | Should -Not -Contain 'window' -Because 'the step fails before its first capture'
    }
    It 'reports resumed steps using their original file positions' {
        $script:FixtureSequence = @{ steps=@(1..5 | ForEach-Object { @{ action='safetyFixture' } }) }
        Invoke-Sequence -HostType 'host.ubuntu.kvm' -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -StartStep 3 -StopStep 4 | Should -BeTrue
        ($script:FixtureRows.Number -join ',') | Should -Be '3,4'
        (@($script:FixtureRows | ForEach-Object { $_.StepCount }) -join ',') | Should -Be '5,5'
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 4
    }
    It 'drops a previous step cause before a later failing action' {
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedOldCause=$true},@{action='safetyFixture';fail=$true}) }
        Invoke-Sequence -HostType 'host.ubuntu.kvm' -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $script:FixtureRows.Count | Should -Be 2
        $script:FixtureRows[1].RunLost | Should -BeNullOrEmpty
        $script:FixtureRows[1].Tail | Should -BeNullOrEmpty
        (Get-SequenceFailureState).LastFailedStepNumber | Should -Be 2
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 1
    }
    It 'records a resumed nested failure against the original outer step' {
        $script:FixtureSequence = @{ steps=@(1..5 | ForEach-Object { @{action='safetyFixture'} }) + @(
            @{action='safetyFixture';children=@(@{action='safetyFixture'},@{action='safetyFixture';fail=$true})}
        ) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -StartStep 5 | Should -BeFalse
        ($script:FixtureRows.Number -join ',') | Should -Be '5,6,1,2'
        (@($script:FixtureRows | ForEach-Object { $_.StepCount }) -join ',') | Should -Be '6,6,2,2'
        (Get-SequenceFailureState).LastFailedStepNumber | Should -Be 6
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 5
    }
    It 'clears transport and OCR causes inherited from a previous sequence' {
        $state = Get-SequenceFailureState
        foreach ($name in @('StepGuestAddressUnresolved','StepGuestTransportLost','StepGuestRunLost','StepGuestPayloadUnavailable',
                'StepVmNotStopped','WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood','WaitForTextConsoleSecondOpinion')) { $state[$name] = 'stale' }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';fail=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        foreach ($name in @('StepGuestAddressUnresolved','StepGuestTransportLost','StepGuestRunLost','StepGuestPayloadUnavailable',
                'StepVmNotStopped','WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood','WaitForTextConsoleSecondOpinion')) { $state[$name] | Should -BeNullOrEmpty }
    }
    It 'preserves capture failures and independent progress observations in step events' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedEvidence=$true;fail=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        Should -Invoke Send-CycleEventSafely -ModuleName Test.SequenceEngine -Times 1 -Exactly -ParameterFilter {
            $EventRecord.event -eq 'step_end' -and $EventRecord.executionEvidence.reasonCode -eq 'profile-ssh-timeout' -and
            $EventRecord.progressAdvisory.Verdict -eq 'progress-suspect' -and -not $EventRecord.progressAdvisory.AutomaticRecoveryAllowed
        }
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unresponsive
    }
    It 'lists a processor the failed wait read as silent on the step''s advisory, leaving its verdict alone' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedSilentProcessor=$true;fail=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
        $advisory = $record.context.causeDetail.progressAdvisory
        $advisory.Signals | Should -Contain 'no-interrupts-serviced'
        $advisory.NoInterruptsServicedSeconds | Should -Be 90
        $advisory.Verdict | Should -Be 'unavailable' -Because 'nothing the verdict reads was measured, and the processor reading is never scored'
        $stepEnd = @($script:FixtureEvents | Where-Object { $_.event -eq 'step_end' -and -not $_.ok })[-1]
        $stepEnd.progressAdvisory.Signals | Should -Contain 'no-interrupts-serviced'
    }
    It 'does not assign a previous passing step ID to a crash before the next invocation' {
        Mock Resolve-YurunaOperatorProjectLabel -ModuleName Test.SequenceEngine {
            param($Entry)
            if ($Entry.throwBeforeInvocation) { throw 'fixture gate crash' }
            return ''
        }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture'},@{action='safetyFixture';throwBeforeInvocation=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $script:FixtureRows.Count | Should -Be 1
        $record.reason | Should -Be crash
        $record.stepInvocationId | Should -Be ''
        $record.originatingStepInvocationId | Should -Be ''
    }
    It 'keeps a failed fetch capture identity and advisory through nested retry wrappers' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        Mock Invoke-SequenceActionHandler -ModuleName Test.SequenceEngine { & $script:RealActionHandler @PesterBoundParameters }
        Mock Invoke-SequenceActionHandler -ModuleName Test.SequenceEngine {
            (Get-SequenceFailureState).WaitForTextOutputStaticSeconds = 200
            $Context.ExecutionProfile = @{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-timeout'; timedOut=$true; sshResponsive=$false; recorder=@{heartbeatAgeSeconds=180} }
            $script:FixtureRows.Add(@{ StepInvocationId=$Context.StepInvocationId; SequenceInvocationId=$Context.SequenceInvocationId })
            return $false
        } -ParameterFilter { $Name -eq 'sshFetchAndExecute' }
        $script:FixtureSequence = @{steps=@(@{action='retry';maxAttempts=1;steps=@(
            @{action='retry';maxAttempts=1;steps=@(@{action='sshFetchAndExecute';script='fixture-fetch.sh'})}
        )})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $wrappers = @($script:FixtureEvents | Where-Object { $_.event -eq 'step_end' -and $_.actionVerb -eq 'retry' })
        $wrappers.Count | Should -Be 2
        $record.stepInvocationId | Should -Be $wrappers[-1].stepInvocationId
        $record.originatingStepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.originatingStepInvocationId | Should -Not -Be $record.stepInvocationId
        $record.originatingSequenceInvocationId | Should -Be $script:FixtureRows[0].SequenceInvocationId
        $record.originatingSequenceInvocationId | Should -Match '^[0-9a-f]{32}$'
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unresponsive
        $record.context.causeDetail.progressAdvisory.HeartbeatAgeSeconds | Should -Be 180
        foreach ($wrapper in $wrappers) {
            $wrapper.originatingStepInvocationId | Should -Be $record.originatingStepInvocationId
            $wrapper.progressAdvisory.Verdict | Should -Be 'progress-suspect'
            $wrapper.progressAdvisory.AutomaticRecoveryAllowed | Should -BeFalse
        }
        $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
        $failure.stepInvocationId | Should -Be $record.stepInvocationId
        $failure.originatingStepInvocationId | Should -Be $record.originatingStepInvocationId
        $failure.progressAdvisory.SshResponsiveness | Should -Be unresponsive
    }
    It 'reads the kernel''s console reports from the failing step''s own start into the record and its events' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        $serial = Join-Path $TestDrive 'fixture-serial.log'
        Set-Content -LiteralPath $serial -Value '' -NoNewline
        # The Hyper-V driver's accessor, over the file the fixture steps append to.
        . (Get-Module Test.SequenceEngine) {
            param($Path)
            $script:FixtureSerialPath = $Path
            function Read-VMSerialCapture {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                if (-not [IO.File]::Exists($script:FixtureSerialPath)) { return $null }
                $bytes = [IO.File]::ReadAllBytes($script:FixtureSerialPath)
                if ($MaxBytes -eq 0) { return [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$bytes.Length; Text = ''; Truncated = $false } }
                $start = [int][math]::Min($FromOffset, $bytes.Length)
                [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$start; Text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Truncated = $false }
            }
        } $serial
        try {
            $earlier = "[  900.000000] watchdog: BUG: soft lockup - CPU#0 stuck for 22s! [earlier:1]`n"
            $current = "[  990.000000] sudo[1]: pam_unix(sudo:session): session closed for user root`n" +
                "[  993.037944] watchdog: BUG: soft lockup - CPU#1 stuck for 26s! [etcd:33180]`n"
            $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';appendSerial=$earlier}, @{action='safetyFixture';appendSerial=$current;fail=$true}) }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
            $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $reading = $record.context.causeDetail.guestKernelFault.serial
            $reading.faultRecords | Should -Be 1 -Because 'the report an earlier step left on the console is not this failure''s'
            $reading.firstFault.text | Should -Match 'etcd:33180'
            $reading.lastNormalRecordUptimeSeconds | Should -Be 990
            $reading.bytesRead | Should -Be ([Text.Encoding]::UTF8.GetByteCount($current))
            $record.context.causeDetail.progressAdvisory.Signals | Should -Contain 'guest-kernel-fault'
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeGuestKernelFault | Should -Be 'soft-lockup'
            $stepEnd = @($script:FixtureEvents | Where-Object { $_.event -eq 'step_end' -and -not $_.ok })[-1]
            $stepEnd.guestKernelFault.serial.faultRecords | Should -Be 1
        } finally {
            . (Get-Module Test.SequenceEngine) {
                Remove-Item -LiteralPath function:\Read-VMSerialCapture -ErrorAction SilentlyContinue
                Remove-Variable -Name FixtureSerialPath -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }
    It 'names a clock jump the console shows during the failing step, in the record and on its event' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        $serial = Join-Path $TestDrive 'fixture-serial.log'
        Set-Content -LiteralPath $serial -Value '' -NoNewline
        # The Hyper-V driver's accessors: the console the step appends to, and
        # a VM created 45 minutes ago.
        . (Get-Module Test.SequenceEngine) {
            param($Path)
            $script:FixtureSerialPath = $Path
            function Read-VMSerialCapture {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                if (-not [IO.File]::Exists($script:FixtureSerialPath)) { return $null }
                $bytes = [IO.File]::ReadAllBytes($script:FixtureSerialPath)
                if ($MaxBytes -eq 0) { return [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$bytes.Length; Text = ''; Truncated = $false } }
                $start = [int][math]::Min($FromOffset, $bytes.Length)
                [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$start; Text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Truncated = $false }
            }
            function Get-VMCreationTime {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                param([string]$VMName)
                return [DateTime]::UtcNow.AddMinutes(-45)
            }
        } $serial
        try {
            $current = "[  272.970974] systemd[1]: systemd-networkd.service: Watchdog timeout (limit 3min)!`n" +
                "[303719.889270] systemd[1]: systemd-logind.service: Watchdog timeout (limit 3min)!`n"
            $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';appendSerial=$current;fail=$true}) }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
            $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $reading = $record.context.causeDetail.guestKernelFault.serial
            @($reading.kinds) | Should -Be @('clock-jump')
            $reading.faultRecords | Should -Be 0 -Because 'the console carried no kernel report, only timestamps that leapt'
            $reading.largestForwardLeap.seconds | Should -Be 303446.918
            @($record.context.causeDetail.progressAdvisory.KernelFaults) | Should -Be @('clock-jump')
            $record.context.causeDetail.progressAdvisory.Signals | Should -Contain 'guest-kernel-fault'
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeGuestKernelFault | Should -Be 'clock-jump'
        } finally {
            . (Get-Module Test.SequenceEngine) {
                Remove-Item -LiteralPath function:\Read-VMSerialCapture, function:\Get-VMCreationTime -ErrorAction SilentlyContinue
                Remove-Variable -Name FixtureSerialPath -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }
    Context 'a login the guest refused, read when a console wait fails' {
        # Each fixture that names a user name also names its loginUser: left
        # unset, Invoke-Sequence derives it through the authentication
        # extension, whose users.yml and event log live in this checkout's
        # test/status/extension folder rather than in TestDrive.
        BeforeEach {
            Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
            $script:FixtureEvents = [Collections.Generic.List[object]]::new()
            Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
            # The file the fixture verb's appendSerial writes to.
            $script:LoginSerialPath = Join-Path $TestDrive 'fixture-serial.log'
            Set-Content -LiteralPath $script:LoginSerialPath -Value '' -NoNewline
            # What login(1) logs on the serial console, and what the screen shows,
            # when it refuses the user name with its first keystroke missing.
            $script:LoginRefusal = "[   23.956775] login[1401]: FAILED LOGIN 1 FROM tty1 FOR uuser26, Authentication failure`r`n"
            $script:LoginScreen = "labguest login: uuser26`nPassword:`nLogin incorrect`nlabguest login:"
            # Every wait times out: the guest logs what the case gives it while the
            # step runs, and the screen is left as the case says.
            Mock Wait-ForText -ModuleName Test.SequenceHandler {
                if ($script:LoginWaitSerial) { [IO.File]::AppendAllText($script:LoginSerialPath, $script:LoginWaitSerial) }
                (Get-SequenceFailureState).WaitForTextOcrTail = $script:LoginWaitScreen
                $false
            }
            # The Windows Hyper-V driver's accessor, over the file the steps append to.
            . (Get-Module Test.SequenceEngine) {
                param($Path)
                $script:FixtureSerialPath = $Path
                function Read-VMSerialCapture {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                        Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                    param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                    if (-not [IO.File]::Exists($script:FixtureSerialPath)) { return $null }
                    $bytes = [IO.File]::ReadAllBytes($script:FixtureSerialPath)
                    if ($MaxBytes -eq 0) { return [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$bytes.Length; Text = ''; Truncated = $false } }
                    $start = [int][math]::Min($FromOffset, $bytes.Length)
                    [pscustomobject]@{ Length = [long]$bytes.Length; Offset = [long]$start; Text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start); Truncated = $false }
                }
            } $script:LoginSerialPath
        }
        AfterEach {
            . (Get-Module Test.SequenceEngine) {
                Remove-Item -LiteralPath function:\Read-VMSerialCapture -ErrorAction SilentlyContinue
                Remove-Variable -Name FixtureSerialPath -Scope Script -ErrorAction SilentlyContinue
            }
        }
        It 'names the user name that lost its first keystroke, in the record and on its event' {
            $script:LoginWaitSerial = $script:LoginRefusal
            $script:LoginWaitScreen = $script:LoginScreen
            $script:FixtureSequence = @{ variables = @{ username = 'yuuser26'; loginUser = 'yuuser26' }; steps = @(@{ action = 'waitForText'; pattern = 'yuuser26@labguest' }) }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
            $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $echo = $record.context.causeDetail.loginEcho
            $echo.expected | Should -BeExactly 'yuuser26'
            $echo.received | Should -BeExactly 'uuser26'
            $echo.source | Should -Be 'serial'
            $echo.lostLeadingCharacters | Should -Be 1
            $record.failureClass | Should -Be ocr_timeout -Because 'the echo names what the guest received; it does not refile the step'
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeLoginEcho | Should -BeExactly 'uuser26 for yuuser26 (serial, 1 leading lost)'
            $failure.failureClass | Should -Be ocr_timeout
        }
        It 'reads the echo when a passwdPrompt failed waiting for its prompt, before it typed' {
            # A first login's shape: the user name lost its first keystroke, login
            # still asked for a password, and the forced-change prompt the next
            # passwdPrompt waits for never came.
            $script:LoginWaitSerial = $script:LoginRefusal
            $script:LoginWaitScreen = $script:LoginScreen
            $script:FixtureSequence = @{ variables = @{ username = 'yuuser26'; loginUser = 'yuuser26'; currentPassword = 'fixture-secret' }
                steps = @(@{ action = 'passwdPrompt'; pattern = @('Current password', 'urrent password:'); sinceStepStart = $true; text = '${currentPassword}' }) }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
            $raw = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw
            $record = $raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $record.context.stepFailurePhase | Should -Be wait
            $echo = $record.context.causeDetail.loginEcho
            $echo.expected | Should -BeExactly 'yuuser26'
            $echo.received | Should -BeExactly 'uuser26'
            $echo.source | Should -Be 'serial'
            $echo.lostLeadingCharacters | Should -Be 1
            $record.failureClass | Should -Be ocr_timeout -Because 'the echo names what the guest received; it does not refile the step'
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeLoginEcho | Should -BeExactly 'uuser26 for yuuser26 (serial, 1 leading lost)'
            $failure.failureClass | Should -Be ocr_timeout
            $raw | Should -Not -Match 'fixture-secret' -Because 'the step''s text is never recorded'
            ($failure | ConvertTo-Json -Depth 8) | Should -Not -Match 'fixture-secret'
        }
        It 'reads no echo for a passwdPrompt that failed while typing its text' {
            # Its wait matched, so what it typed can be on the screen and the
            # serial console: neither is read.
            Mock Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler { $false }
            Mock Wait-ForText -ModuleName Test.SequenceHandler {
                [IO.File]::AppendAllText($script:LoginSerialPath, $script:LoginRefusal)
                (Get-SequenceFailureState).WaitForTextOcrTail = $script:LoginScreen
                $true
            }
            $script:FixtureSequence = @{ variables = @{ username = 'yuuser26'; loginUser = 'yuuser26'; currentPassword = 'fixture-secret' }
                steps = @(@{ action = 'passwdPrompt'; pattern = 'Password:'; text = '${currentPassword}' }) }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
            $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $record.context.stepFailurePhase | Should -Be input
            $record.context.causeDetail.loginEcho | Should -BeNullOrEmpty
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeLoginEcho | Should -Be ''
        }
        It 'reads no echo for <Case>' -ForEach @(
            @{ Case = 'a refusal logged before the failing step began'; Before = $true; Variables = @{ username = 'yuuser26'; loginUser = 'yuuser26' }
                Step = @{ action = 'waitForText'; pattern = 'yuuser26@labguest' } }
            @{ Case = 'a sensitive step'; Before = $false; Variables = @{ username = 'yuuser26'; loginUser = 'yuuser26' }
                Step = @{ action = 'waitForAndEnter'; pattern = 'login:'; text = 'fixture-secret'; sensitive = $true } }
            @{ Case = 'a sequence with no user name'; Before = $false; Variables = $null
                Step = @{ action = 'waitForText'; pattern = 'yuuser26@labguest' } }
        ) {
            if ($Before) {
                # The refusal reached the console during the step before, and the
                # failing wait's screen no longer shows it.
                $script:LoginWaitSerial = ''
                $script:LoginWaitScreen = 'labguest login:'
                $steps = @(@{ action = 'safetyFixture'; appendSerial = $script:LoginRefusal }, $Step)
            } else {
                $script:LoginWaitSerial = $script:LoginRefusal
                $script:LoginWaitScreen = $script:LoginScreen
                $steps = @($Step)
            }
            $script:FixtureSequence = @{ steps = $steps }
            if ($Variables) { $script:FixtureSequence.variables = $Variables }
            Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
            $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
            $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
            $record.context.causeDetail.loginEcho | Should -BeNullOrEmpty
            $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
            $failure.causeLoginEcho | Should -Be ''
        }
    }
    It 'clears a recovered retry leaf before a later failure and a new sequence' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{steps=@(
            @{action='retry';maxAttempts=2;steps=@(@{action='safetyFixture';seedEvidence=$true;failFirstAttempt=$true})},
            @{action='safetyFixture';fail=$true}
        )}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $script:FixtureRows.Count | Should -Be 3
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.originatingStepInvocationId | Should -Be $script:FixtureRows[2].StepInvocationId
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unavailable
        $record.context.causeDetail.progressAdvisory.HeartbeatAgeSeconds | Should -BeNullOrEmpty
        $script:FixtureSequence = @{steps=@(@{action='retry';maxAttempts=1;steps=@(@{action='safetyFixture'})})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeTrue
        (Get-SequenceFailureState).OriginatingStepInvocationId | Should -Be ''
        (Get-SequenceFailureState).OriginatingSequenceInvocationId | Should -Be ''
        (Get-SequenceFailureState).StepProgressAdvisory | Should -BeNullOrEmpty
    }
    It 'keeps the deepest pre-login VM observations in the real nested retry file and event paths' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        $script:FixtureSequence = @{steps=@(@{action='retry';maxAttempts=1;steps=@(
            @{action='retry';maxAttempts=1;steps=@(@{action='safetyFixture';seedConsoleEvidence=$true;fail=$true})}
        )})}
        Invoke-Sequence -HostType host.macos.utm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.context.causeDetail.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
        $record.context.causeDetail.consoleSecondOpinion.QemuPid | Should -Be 4321
        $record.context.causeDetail.consoleSecondOpinion.VncPort | Should -Be 5983
        $record.context.causeDetail.consoleSecondOpinion.CpuPercent | Should -Be 782
        $record.originatingStepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $events = @($script:FixtureEvents | Where-Object { $_.event -in @('step_end','step_failure') })
        $events.Count | Should -Be 4 -Because 'the leaf, both retry wrappers and final failure retain the observation'
        foreach ($entry in $events) {
            $entry.consoleSecondOpinion.Verdict | Should -Be 'guest-wedged'
            $entry.consoleSecondOpinion.CpuPercent | Should -Be 782
            $entry.originatingStepInvocationId | Should -Be $record.originatingStepInvocationId
            $entry.progressAdvisory.SshResponsiveness | Should -Be 'unavailable'
            $entry.progressAdvisory.AutomaticRecoveryAllowed | Should -BeFalse
        }
    }
    It 'restores the outer invocation after a nested success before an outer crash' {
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';children=@(@{action='safetyFixture'});throwAfterChildren=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $script:FixtureRows.Count | Should -Be 2
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.stepInvocationId | Should -Not -Be $script:FixtureRows[1].StepInvocationId
    }
    It 'attributes a distinct outer crash to its own invocation after a failed child' {
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        # The thrown step now takes the step-failure path, which captures the screen.
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';children=@(@{action='safetyFixture';seedEvidence=$true;seedConsoleEvidence=$true;fail=$true});throwAfterChildren=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step -Because 'a handler that throws fails its own step'
        $record.classificationSource | Should -Be 'handler-exception'
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.originatingStepInvocationId | Should -Be $record.stepInvocationId
        $record.originatingStepInvocationId | Should -Not -Be $script:FixtureRows[1].StepInvocationId
        $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
        $failure.progressAdvisory | Should -BeNullOrEmpty
        $failure.consoleSecondOpinion | Should -BeNullOrEmpty -Because 'a distinct outer crash is not the earlier console timeout'
    }
    # A handler that threw skipped the step-failure path: the record named a
    # stand-in verb and step 0, and a retry around the step never saw it fail.
    It 'fails a step whose handler throws, naming the step and its verb' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture'}, @{action='safetyFixture';throwNow=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step
        $record.actionVerb | Should -Be safetyFixture
        $record.stepNumber | Should -Be 2
        $record.failureClass | Should -Be unknown -Because 'an unexpected exception says nothing about the verb''s own class'
        $record.classificationSource | Should -Be 'handler-exception'
        $record.action | Should -BeLike '*the handler threw: fixture handler crash*'
    }
    It 'lets a retry around a throwing step run it again' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='retry';maxAttempts=2;steps=@(@{action='safetyFixture';throwNow=$true})}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
        $script:FixtureRows.Count | Should -Be 2 -Because 'each attempt reached the handler'
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.failureClass | Should -Be retry_exhausted
        $record.innerFailureClass | Should -Be unknown
    }
    # passwdPrompt filed every failure as credential_expired, so a prompt that
    # never appeared read as a rejected password.
    It 'files a passwdPrompt whose prompt never appeared as an OCR timeout, and a failed entry under its own class' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Send-TabNavigation -ModuleName Test.SequenceHandler { }
        $script:FixtureSequence = @{ steps=@(@{action='passwdPrompt';pattern='Password:';text='fixture-secret'}) }
        Mock Wait-ForText -ModuleName Test.SequenceHandler { $false }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.failureClass | Should -Be ocr_timeout -Because 'the screen never showed the prompt'
        $record.context.stepFailurePhase | Should -Be wait
        Mock Wait-ForText -ModuleName Test.SequenceHandler { $true }
        Mock Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler { $false }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -WarningAction SilentlyContinue | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.failureClass | Should -Be credential_expired
        $record.context.stepFailurePhase | Should -Be input
    }
    It 'publishes the OCR sidecar writer to its handler module' {
        (Get-Command Save-OcrSidecar -ErrorAction Stop).ModuleName | Should -Be 'Test.SequenceEngine'
    }
}

Describe 'checkpoint matching reuses already parsed timestamps' {
    It 'parses a step interval once for any number of typed checkpoint candidates' {
        $step = @{ startedAtUtc='2026-09-27T00:00:00Z'; endedAtUtc='2026-09-27T00:00:10Z' }
        $sidecars = @(1..100 | ForEach-Object { @{ ReceivedAt=[datetime]::new(2026,9,26,0,0,0,[DateTimeKind]::Utc); Consumed=$false } })
        $sidecars += @{ ReceivedAt=[datetime]::new(2026,9,27,0,0,5,[DateTimeKind]::Utc); Consumed=$false; Label='match' }
        Mock ConvertTo-PerfUtc -ModuleName Test.PerfAggregate { param($Value) return [string]$Value }
        (Find-PerfCheckpoint -Step $step -Sidecar $sidecars).Label | Should -Be match
        Should -Invoke ConvertTo-PerfUtc -ModuleName Test.PerfAggregate -Times 2 -Exactly
    }
}

Describe 'a sentence step runs through the engine without evaluating its secret twice' {
    # The engine expands every description at run time, so a label that still
    # held the password expression would call the extension a second time and
    # print the password. These cases run the real reader and engine on a
    # sentence login and read every sink the run writes.
    BeforeAll {
        # The first Invoke-Sequence of a process loads the planner, whose load
        # imports the engine again with -Force and replaces the handler and
        # variable modules a mock below was set in. Loading it here keeps those
        # mocks in force when this block runs alone.
        Import-Module (Join-Path $PSScriptRoot 'Test.SequencePlanner.psm1') -Global -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.WarmResume.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.Capability.psm1') -Force -Global -DisableNameChecking
        $script:SentenceRootNumber = 0
        $script:LoginEntry = '  - step: "login ${username} with password ${ext:authentication.GetPassword(${username})}"'

        function Write-SentenceSequence {
            <#
            .SYNOPSIS
                Write the fixture guest sequence with the given component entries.
            #>
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Component)
            $text = "description: sentence fixture`nkeystrokeMechanism: gui`nresource:`n  ubuntu.server.26: []`n" +
                "variables:`n  username: yuuser26`n  loginUser: yuuser26`ncomponent:`n$Component`n"
            [IO.File]::WriteAllText($script:SentenceSequence, $text)
        }

        function Invoke-SentenceRun {
            <#
            .SYNOPSIS
                Run the fixture sequence and return its result with the texts of every sink.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()
            $all = @(Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SentenceSequence 3>$null 6>&1)
            $information = @($all | Select-Object -First ($all.Count - 1) |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n"
            $currentAction = Join-Path $env:YURUNA_RUNTIME_DIR 'current-action.json'
            $currentText = if (Test-Path -LiteralPath $currentAction) { [IO.File]::ReadAllText($currentAction) } else { '' }
            return @{
                Result      = $all[-1]
                Information = $information
                Sink        = @(($script:SentenceEvents | ConvertTo-Json -Depth 8), $information, $currentText)
            }
        }
    }

    BeforeEach {
        $script:SentenceRootNumber++
        $root = Join-Path $TestDrive ('sentence-run{0:D2}' -f $script:SentenceRootNumber)
        $sequences = Join-Path $root 'test/sequences'
        New-Item -ItemType Directory -Path $sequences -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $sequences '_phrases.yml'), @'
phrases:
  login:
    sentence: "login <user> with password <password:secret>"
    screen:
      - action: passwdPrompt
        pattern: "login:"
        text: "<user>"
      - action: passwdPrompt
        pattern: "Password:"
        text: "<password>"
'@)
        $script:SentenceSequence = Join-Path $sequences 'workload.fixture.login.yml'
        $script:SentenceEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:SentenceEvents.Add($EventRecord) }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Wait-ForText -ModuleName Test.SequenceHandler { $true }
        Mock Send-TabNavigation -ModuleName Test.SequenceHandler { }
        Mock Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler { $true }
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-secret' }
        Register-SequenceAction -Name safetyFixture -ReplaySafety observe -CapturesOwnFailureScreenshot $true -Handler { $true }
    }

    It 'runs a sentence login with one extension call and no password in events, log lines or the current action' {
        Write-SentenceSequence -Component $script:LoginEntry
        $run = Invoke-SentenceRun
        Assert-True ($run.Result -eq $true) 'the sentence login must pass'
        Should -Invoke Invoke-ExtensionExpression -ModuleName Test.SequenceVariable -Times 1 -Exactly
        foreach ($text in $run.Sink) {
            Assert-False $text.Contains('fixture-secret') 'a sink holds the password'
            Assert-False $text.Contains('GetPassword') 'a sink holds the password expression'
        }
        Assert-True $run.Information.Contains('login yuuser26 with password *** (1/2)') "information: $($run.Information)"
        Assert-True $run.Information.Contains('(2/2)') "information: $($run.Information)"
    }

    It 'keeps an author description that repeats the password expression from being evaluated' {
        Write-SentenceSequence -Component ($script:LoginEntry + "`n    description: ""Log in with `${ext:authentication.GetPassword(`${username})}""`n    descriptionLocalized:`n      pt-BR: ""Entrar com `${ext:authentication.GetPassword(`${username})}""")
        $run = Invoke-SentenceRun
        Assert-True ($run.Result -eq $true) 'the sentence login must pass'
        Should -Invoke Invoke-ExtensionExpression -ModuleName Test.SequenceVariable -Times 1 -Exactly
        foreach ($text in $run.Sink) {
            Assert-False $text.Contains('fixture-secret') 'a sink holds the password'
            Assert-False $text.Contains('GetPassword') 'a sink holds the password expression'
        }
    }

    It 'records a failed sentence login without the password and names its sentence' {
        Mock Wait-ForText -ModuleName Test.SequenceHandler { -not (($Pattern -join ' ') -match 'Password:') }
        Write-SentenceSequence -Component $script:LoginEntry
        $run = Invoke-SentenceRun
        Assert-True ($run.Result -eq $false) 'the login must fail at the password prompt'
        Should -Invoke Invoke-ExtensionExpression -ModuleName Test.SequenceVariable -Times 0 -Exactly
        $recordText = [IO.File]::ReadAllText((Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'))
        Assert-False $recordText.Contains('fixture-secret') 'the record holds the password'
        Assert-False $recordText.Contains('GetPassword') 'the record holds the password expression'
        $record = $recordText | ConvertFrom-Json
        Assert-StringEqual -Expected 'wait' -Actual $record.context.stepFailurePhase
        Assert-StringEqual -Expected 'passwdPrompt' -Actual $record.actionVerb
        Assert-Equal -Expected 2 -Actual $record.stepNumber
        Assert-True ($record.context.fromStep -ceq 'login ${username} with password ***') "fromStep: $($record.context.fromStep)"
    }

    It 'numbers the steps a sentence generates in file order, as the planner helpers do' {
        Write-SentenceSequence -Component ("  - action: safetyFixture`n" + $script:LoginEntry + "`n  - action: safetyFixture")
        $run = Invoke-SentenceRun
        Assert-True ($run.Result -eq $true) 'the run must pass'
        $ends = @($script:SentenceEvents | Where-Object { $_.event -eq 'step_end' })
        Assert-StringEqual -Expected '1,2,3,4' -Actual (@($ends | ForEach-Object { $_.stepNumber }) -join ',')
        Assert-StringEqual -Expected 'safetyFixture,passwdPrompt,passwdPrompt,safetyFixture' -Actual (@($ends | ForEach-Object { $_.actionVerb }) -join ',')
        Assert-StringEqual -Expected 'safetyFixture,passwdPrompt,passwdPrompt,safetyFixture' -Actual (@(Get-WarmResumeStepAction -Path $script:SentenceSequence) -join ',')
        $stepList = [Collections.Generic.List[object]]::new()
        $null = Get-SequenceActionsUsed -SequencePath $script:SentenceSequence -StepList $stepList
        Assert-StringEqual -Expected '1,2,3,4' -Actual (@($stepList | ForEach-Object { $_.step }) -join ',')
        Assert-StringEqual -Expected 'safetyFixture,passwdPrompt,passwdPrompt,safetyFixture' -Actual (@($stepList | ForEach-Object { $_.action }) -join ',')
    }
}

Describe 'a run takes an in-memory definition, a caller-owned variable table and a continuation' {
    # A workload session runs each operation as one Invoke-Sequence call on a
    # definition it built, with one variable table for the whole session, and
    # must not reset the console between operations. The cases above, which
    # pass none of the three parameters, prove that a cycle's run is unchanged.
    BeforeAll {
        # The first Invoke-Sequence of a process loads the planner, whose load
        # imports the engine again with -Force and replaces the variable module
        # a mock below is set in. Loading it here keeps those mocks in force
        # when this block runs alone.
        Import-Module (Join-Path $PSScriptRoot 'Test.SequencePlanner.psm1') -Global -DisableNameChecking
    }

    BeforeEach {
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Read-SequenceFile -ModuleName Test.SequenceEngine { $script:FixtureSequence }
        $script:ScopeRows = [Collections.Generic.List[object]]::new()
        $rows = $script:ScopeRows
        Register-SequenceAction -Name scopeFixture -ReplaySafety observe -CapturesOwnFailureScreenshot $true -Handler {
            param($context)
            $rows.Add(@{
                    StepNum      = $context.StepNum
                    StepCount    = $context.StepCount
                    SequencePath = $context.SequencePath
                    VMName       = $context.VMName
                    Vars         = $context.Vars
                    VarsCopy     = $context.Vars.Clone()
                    Baseline     = (Get-CarriedConsoleBaseline -VMName $context.VMName)
                })
            if ($context.Step.renameTo) { $context.NewVMName = [string]$context.Step.renameTo }
            return $true
        }.GetNewClosure()
        $script:AbsentPath = Join-Path $TestDrive 'never-written.yml'
    }

    It 'builds the variable table the sequence used to build inline' {
        Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'from-the-extension' }
        $ordered = New-SequenceVariableScope -VMName 'never-a-real-vm' -HostType 'host.fixture' -GuestKey 'guest.fixture' `
            -SequenceVariables ([ordered]@{ first = 'one'; second = '${first}-two'; escaped = 'ab$$cd' }) -EffectiveVariables $null
        Assert-StringEqual 'one-two' $ordered['second'] 'a sequence value did not see the one before it'
        Assert-True ([string]::Equals('ab$cd', [string]$ordered['escaped'], [StringComparison]::Ordinal)) "the escape gave '$($ordered['escaped'])'"
        Assert-StringEqual 'never-a-real-vm' $ordered['vmName']
        Assert-StringEqual 'host.fixture' $ordered['hostType']
        Assert-StringEqual 'guest.fixture' $ordered['guestKey']
        Assert-StringEqual 'never-a-real-vm' $ordered['hostname']

        $override = New-SequenceVariableScope -VMName 'never-a-real-vm' -HostType 'host.fixture' -GuestKey 'guest.fixture' `
            -SequenceVariables ([ordered]@{ token = '${ext:authentication.NewRandomPassword()}' }) `
            -EffectiveVariables ([ordered]@{ token = 'given-by-the-chain'; hostname = 'box.example.test' })
        Should -Invoke Invoke-ExtensionExpression -ModuleName Test.SequenceVariable -Times 0 -Exactly
        Assert-StringEqual 'given-by-the-chain' $override['token']
        Assert-StringEqual 'box' $override['hostLabel'] 'hostLabel is the first label of a dotted hostname'

        $login = New-SequenceVariableScope -VMName 'never-a-real-vm' -HostType 'host.fixture' -GuestKey 'guest.fixture' `
            -SequenceVariables ([ordered]@{ username = 'yuuser26'; loginUser = 'fixture-login' }) -EffectiveVariables $null
        Assert-StringEqual 'fixture-login' $login['loginUser'] 'a loginUser the fixture set was replaced'
    }

    It 'runs an in-memory definition without reading a file' {
        $definition = @{ description = 'in-memory fixture'; steps = [object[]]@(@{ action = 'scopeFixture' }, @{ action = 'scopeFixture' }) }
        $result = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:AbsentPath -Definition $definition
        Assert-True ($result -eq $true) "the run answered '$result'"
        Should -Invoke Read-SequenceFile -ModuleName Test.SequenceEngine -Times 0 -Exactly
        Assert-False (Test-Path -LiteralPath $script:AbsentPath) 'the run wrote the sequence file'
        Assert-StringEqual '1,2' (@($script:ScopeRows | ForEach-Object { $_.StepNum }) -join ',')
        Assert-StringEqual '2,2' (@($script:ScopeRows | ForEach-Object { $_.StepCount }) -join ',')
    }

    It "uses the caller's variable table as it is" {
        $scope = @{ p = 'ab$$cd'; vmName = 'never-a-real-vm'; hostType = 'host.fixture'; guestKey = 'guest.fixture'; hostname = 'never-a-real-vm' }
        $definition = @{ description = 'scope fixture'; steps = [object[]]@(@{ action = 'scopeFixture' }) }
        $result = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:AbsentPath -Definition $definition -VariableScope $scope
        Assert-True ($result -eq $true) "the run answered '$result'"
        Assert-True ([object]::ReferenceEquals($scope, $script:ScopeRows[0].Vars)) 'the handler saw another table'
        Assert-True ([string]::Equals('ab$$cd', [string]$script:ScopeRows[0].VarsCopy['p'], [StringComparison]::Ordinal)) "the handler saw '$($script:ScopeRows[0].VarsCopy['p'])'"
        Assert-True ([string]::Equals('ab$$cd', [string]$scope['p'], [StringComparison]::Ordinal)) 'the run expanded a value of the caller table'
    }

    It "writes a rename into the caller's variable table" {
        $scope = @{ vmName = 'never-a-real-vm'; hostType = 'host.fixture'; guestKey = 'guest.fixture'; hostname = 'never-a-real-vm' }
        $definition = @{ description = 'rename fixture'; steps = [object[]]@(@{ action = 'scopeFixture'; renameTo = 'never-a-real-vm-renamed' }) }
        $result = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:AbsentPath -Definition $definition -VariableScope $scope
        Assert-True ($result -eq $true) "the run answered '$result'"
        Assert-StringEqual 'never-a-real-vm-renamed' $scope['vmName']
        Assert-StringEqual 'never-a-real-vm-renamed' (Get-SequenceFinishedVMName)
    }

    It 'keeps the carried baseline and the console viewer under -Continuation' {
        Set-CarriedConsoleBaseline -VMName 'never-a-real-vm' -Text "login: prompt`nsecond line"
        $definition = @{ description = 'continuation fixture'; steps = [object[]]@(@{ action = 'scopeFixture' }) }
        $result = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:AbsentPath -Definition $definition -Continuation
        Assert-True ($result -eq $true) "the run answered '$result'"
        Assert-NotNull $script:ScopeRows[0].Baseline 'the carried baseline was cleared'
        Should -Invoke Restart-VMConsole -ModuleName Test.SequenceEngine -Times 0 -Exactly
    }

    It 'clears the baseline and restarts the viewer without -Continuation' {
        Set-CarriedConsoleBaseline -VMName 'never-a-real-vm' -Text "login: prompt`nsecond line"
        $definition = @{ description = 'restart fixture'; steps = [object[]]@(@{ action = 'scopeFixture' }) }
        $result = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:AbsentPath -Definition $definition
        Assert-True ($result -eq $true) "the run answered '$result'"
        Assert-Null $script:ScopeRows[0].Baseline 'the carried baseline survived a new run'
        Should -Invoke Restart-VMConsole -ModuleName Test.SequenceEngine -Times 1 -Exactly
    }
}
