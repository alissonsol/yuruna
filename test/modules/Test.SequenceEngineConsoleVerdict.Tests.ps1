<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42537e6e-eae7-4348-92a0-0f4b4ed492a0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence wait hypervisor console pester
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
    Hold what a timed-out Wait-ForText records about the console: the
    hypervisor's verdict, a blank screen, and a guest that stopped moving.
.DESCRIPTION
    Part of the sequence engine suites: Test.SequenceEngine.Tests.ps1 holds
    their setup and says what they protect.

    Run through tools/_InvokeOneSuite.ps1 and inspect its NUnit result file.
#>

BeforeAll {
    # These cases wait out real timeouts, so they sit in a file of their own
    # and run beside the other sequence engine suites. The setup is the
    # BeforeAll of Test.SequenceEngine.Tests.ps1, parsed and run as that file,
    # so one block serves them all.
    $suite = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.SequenceEngine.Tests.ps1'), [ref]$null, [ref]$null)
    $script:SharedBlock = @{}
    foreach ($statement in @($suite.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] })) {
        $command = $statement.PipelineElements[0]
        if ($command -is [Management.Automation.Language.CommandAst] -and $command.GetCommandName() -in 'BeforeAll', 'AfterAll') {
            $script:SharedBlock[$command.GetCommandName()] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    . $script:SharedBlock['BeforeAll']
    # Wait-ForText keeps its frame history through Test.Log, which the runner
    # has loaded by the time a sequence waits, so the suite loads it too.
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Global -DisableNameChecking -WarningAction SilentlyContinue
}

Describe 'Wait-ForText records the hypervisor verdict and a blank console' {
    BeforeAll {
        . (Get-Module Test.SequenceEngine) {
            function Get-EnabledOcrProvider { return @('scripted') }
            function Get-CycleScreenDir {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($script:TextProbe.ScreenDir, 'Ensure cycle screen dir exists')
                return $script:TextProbe.ScreenDir
            }
            function Get-VMScreenshot {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $OutFile, $HostType)
                Set-Content -LiteralPath $OutFile -Value ('png{0}' -f $script:TextProbe.Poll) -NoNewline
                return $true
            }
            function Test-CombinedOcrMatch {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($ImagePath, $Pattern, $FreshMatchTailLines, [switch]$NoSegmentMatch)
                $i = [Math]::Min($script:TextProbe.Poll, $script:TextProbe.Frames.Count - 1)
                $text = [string]$script:TextProbe.Frames[$i]
                $script:TextProbe.Poll++
                return @{ Match = $false; AnyText = $text; EngineResults = [ordered]@{ scripted = @{ Text = $text; Matched = $false } } }
            }
            # The host recording is the outer runner's; the verdict it would
            # give is scripted per example.
            function Get-GuestLivelockVerdict {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $Since)
                $script:TextProbe.VerdictReads++
                $script:TextProbe.Since = $Since
                $script:TextProbe.SinceSeen += @(,$Since)
                return $script:TextProbe.Livelock
            }
            function Reset-LivelockProbeState {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
                param([string]$ScreenDir, [string[]]$Frames, $Livelock)
                $script:TextProbe = @{ ScreenDir = $ScreenDir; Poll = 0; Frames = $Frames; Livelock = $Livelock; VerdictReads = 0; Since = $null; SinceSeen = @() }
            }
        }
        $script:livelocked = [pscustomobject]@{ Verdict = 'livelocked'; LivelockedSeconds = 420; Detail = '1 virtual processor(s) pinned' }
        function Invoke-ScriptedWait {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: drives the function under test against scripted frames.')]
            param([string[]]$Frames, $Livelock, [int]$TimeoutSeconds, [switch]$EndOnGuestLivelock, [switch]$EndOnDisplayStall, $GuestLivelockSinceUtc, [string]$GuestRecorderPath)
            & (Get-Module Test.SequenceEngine) { param($d, $f, $l) Reset-LivelockProbeState -ScreenDir $d -Frames $f -Livelock $l } $script:probeDir $Frames $Livelock
            Clear-CarriedConsoleBaseline
            $bound = @{}
            if ($null -ne $GuestLivelockSinceUtc) { $bound.GuestLivelockSinceUtc = $GuestLivelockSinceUtc }
            if ($GuestRecorderPath) { $bound.GuestRecorderPath = $GuestRecorderPath }
            if ($EndOnDisplayStall) { $bound.EndOnDisplayStall = $true }
            return [bool](Wait-ForText -VMName 'vm-01' -Pattern @('Continue with autoinstall?') -TimeoutSeconds $TimeoutSeconds -PollSeconds 1 `
                -EndOnGuestLivelock:$EndOnGuestLivelock -WarningAction SilentlyContinue -InformationAction SilentlyContinue @bound)
        }
        function Get-ProbeSinceSeen { & (Get-Module Test.SequenceEngine) { , @($script:TextProbe.SinceSeen) } }
        function Get-ProbeFailSlot { param([string]$Name) & (Get-Module Test.SequenceEngine) { param($n) $script:Fail[$n] } $Name }
    }
    BeforeEach {
        $script:probeDir = New-YurunaTestTempDir -Prefix 'yuruna-wfl'
    }
    AfterEach { Remove-YurunaTestTempDir $script:probeDir }

    It 'ends the wait at once on a livelocked guest when the caller asked' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ScriptedWait -Frames @('') -Livelock $script:livelocked -TimeoutSeconds 60 -EndOnGuestLivelock | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'the verdict is read before the first capture, not at the deadline'
        (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeTrue
        (Get-ProbeFailSlot 'WaitForTextGuestLivelock').LivelockedSeconds | Should -Be 420
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.Poll } | Should -Be 0
    }
    It 'reads the verdict only for readings taken since this wait began' {
        $before = [DateTime]::UtcNow
        Invoke-ScriptedWait -Frames @('') -Livelock $script:livelocked -TimeoutSeconds 60 -EndOnGuestLivelock | Should -BeFalse
        $since = & (Get-Module Test.SequenceEngine) { $script:TextProbe.Since }
        $since | Should -BeGreaterOrEqual $before -Because 'a previous boot in the recording must not end this wait'
    }
    It 'records on timeout the verdict its early-end checks judged' {
        $running = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running' }
        $before = [DateTime]::UtcNow
        Invoke-ScriptedWait -Frames @('booting') -Livelock $running -TimeoutSeconds 3 -EndOnGuestLivelock | Should -BeFalse
        $seen = Get-ProbeSinceSeen
        $seen.Count | Should -Be 2 -Because 'one check at the start and one when the wait times out'
        $seen[0] | Should -BeGreaterOrEqual $before
        $seen[1] | Should -Be $seen[0] -Because 'the recorded verdict must judge the same readings the early end did'
    }
    It 'takes the caller''s livelock bound when a step waits in several calls' {
        $stepStart = [DateTime]::UtcNow.AddSeconds(-120)
        Invoke-ScriptedWait -Frames @('') -Livelock $script:livelocked -TimeoutSeconds 60 -EndOnGuestLivelock -GuestLivelockSinceUtc $stepStart | Should -BeFalse
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.Since } | Should -Be $stepStart
    }
    It 'waits out its budget without the switch and still records the verdict' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ScriptedWait -Frames @('booting') -Livelock $script:livelocked -TimeoutSeconds 3 | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 2.5
        (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeTrue
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.VerdictReads } | Should -Be 1 -Because 'a caller that did not ask is never polled, only told at the end'
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.Since } | Should -BeNullOrEmpty -Because 'a wait that does not act on the verdict records the whole recording window'
    }
    It 'does not end early on a guest the hypervisor sees running' {
        $running = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running' }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ScriptedWait -Frames @('booting') -Livelock $running -TimeoutSeconds 3 -EndOnGuestLivelock | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 2.5
        (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
    }
    It 'records the hypervisor verdict when a failure pattern ends the wait' {
        $running = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running'; ProcessorWindow = @{ StormedProcessors = @('1') } }
        & (Get-Module Test.SequenceEngine) { param($d, $f, $l) Reset-LivelockProbeState -ScreenDir $d -Frames $f -Livelock $l } `
            $script:probeDir @('NONZERO SCRIPT EXIT: guest/shared/ubuntu.k8s.sh (exit 1)') $running
        Clear-CarriedConsoleBaseline
        $before = [DateTime]::UtcNow
        Wait-ForText -VMName 'vm-01' -Pattern @('FETCHED AND EXECUTED:') -FailurePattern @('NONZERO SCRIPT EXIT:') -TimeoutSeconds 20 -PollSeconds 1 `
            -WarningAction SilentlyContinue -InformationAction SilentlyContinue | Should -BeFalse
        (Get-ProbeFailSlot 'WaitForTextMatchedFailurePattern') | Should -Be 'NONZERO SCRIPT EXIT:'
        (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
        @((Get-ProbeFailSlot 'WaitForTextGuestLivelock').ProcessorWindow.StormedProcessors) | Should -Be @('1') `
            -Because 'a script that gave up on the console still carries the processor window of its wait'
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.VerdictReads } | Should -Be 1
        & (Get-Module Test.SequenceEngine) { $script:TextProbe.Since } | Should -BeGreaterOrEqual $before -Because 'the pattern path judges the readings of this wait'
    }
    It 'records how long the console read blank and what it was seeking' {
        Invoke-ScriptedWait -Frames @('') -Livelock $null -TimeoutSeconds 3 | Should -BeFalse
        (Get-ProbeFailSlot 'WaitForTextBlankScreenSeconds') | Should -BeGreaterOrEqual 1
        @(Get-ProbeFailSlot 'WaitForTextPatternsSought') | Should -Be @('Continue with autoinstall?')
        (Get-ProbeFailSlot 'WaitForTextGuestLivelock') | Should -BeNullOrEmpty -Because 'no host recording is not a verdict'
    }
    It 'resets the blank run when a frame carries text' {
        Invoke-ScriptedWait -Frames @('', '', 'yuhost26 login: _') -Livelock $null -TimeoutSeconds 4 | Should -BeFalse
        (Get-ProbeFailSlot 'WaitForTextBlankScreenSeconds') | Should -Be 0
    }

    Context 'a guest kernel that wedged with one processor silent' {
        BeforeAll {
            # The Hyper-V driver's serial accessor, scripted inside the engine.
            # The capture ends at 5000 bytes when the wait marks it.
            . (Get-Module Test.SequenceEngine) {
                function Read-VMSerialCapture {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                        Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                    param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                    if ($MaxBytes -ne 0) { $script:KernelStallSerialReads += @($FromOffset) }
                    return [pscustomobject]@{ Length = 5000L; Offset = $FromOffset; Text = $script:KernelStallSerialText; Truncated = $false; Replaced = $false }
                }
            }
            $script:rcuStall = @(
                '[  962.456816] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:'
                '[  962.479483] rcu: rcu_preempt kthread starved for 60024 jiffies! g234369 f0x2 RCU_GP_WAIT_FQS(5) ->state=0x0 ->cpu=1'
            ) -join "`n"
            function Set-KernelStallSerial {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory console; no external state.')]
                param([string]$Text)
                & (Get-Module Test.SequenceEngine) { param($t) $script:KernelStallSerialText = $t; $script:KernelStallSerialReads = @() } $Text
            }
            # Processor 0 serviced no interrupt for the given run; processor 1 kept running.
            function New-SilentProcessorVerdict {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test helper: returns an in-memory verdict.')]
                param([int]$Seconds)
                return [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running'
                    ProcessorWindow = [pscustomobject]@{ Processors = @(
                        [pscustomobject]@{ Processor = '0'; NoInterruptsServicedSeconds = $Seconds; NoInterruptsServicedSinceUtc = '2026-10-29T08:56:28.0000000Z' }
                        [pscustomobject]@{ Processor = '1'; NoInterruptsServicedSeconds = 0; NoInterruptsServicedSinceUtc = '' }) } }
            }
        }
        AfterAll {
            . (Get-Module Test.SequenceEngine) { Remove-Item -LiteralPath function:\Read-VMSerialCapture -ErrorAction SilentlyContinue }
        }

        It 'ends at once on a processor silent three minutes and a kernel stall reported since the wait began' {
            Set-KernelStallSerial -Text $script:rcuStall
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-ScriptedWait -Frames @('Pulling 192.168.7.42:5000/dotnet/sdk:10.0') -Livelock (New-SilentProcessorVerdict -Seconds 1305) -TimeoutSeconds 60 -EndOnGuestLivelock | Should -BeFalse
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'the wedge is judged before the first capture, not at the deadline'
            $end = Get-ProbeFailSlot 'WaitForTextKernelStallEnd'
            $end.basis | Should -Be 'no-interrupts-serviced'
            @($end.processors) | Should -Be @('0')
            $end.noInterruptsServicedSeconds | Should -Be 1305
            $end.noInterruptsServicedSinceUtc | Should -Be '2026-10-29T08:56:28.0000000Z'
            @($end.kinds) | Should -Be @('rcu-kthread-starved', 'rcu-stall')
            $end.waitedSeconds | Should -BeLessThan 15
            @(& (Get-Module Test.SequenceEngine) { $script:KernelStallSerialReads }) | Should -Be @(5000) -Because 'only what reached the console after the wait began can end it'
            (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse -Because 'the other processor still ran, and the record keeps the verdict that was judged'
            @((Get-ProbeFailSlot 'WaitForTextGuestLivelock').ProcessorWindow.Processors)[0].NoInterruptsServicedSeconds | Should -Be 1305
        }

        It 'waits out its budget on a silent processor when the console holds no kernel report' {
            Set-KernelStallSerial -Text '[  900.000000] systemd[1]: Started session-3.scope.'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-ScriptedWait -Frames @('booting') -Livelock (New-SilentProcessorVerdict -Seconds 1305) -TimeoutSeconds 3 -EndOnGuestLivelock | Should -BeFalse
            $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 2.5
            Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty
        }

        It 'waits out its budget on a kernel report when no processor has been silent three minutes' {
            Set-KernelStallSerial -Text $script:rcuStall
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-ScriptedWait -Frames @('booting') -Livelock (New-SilentProcessorVerdict -Seconds 150) -TimeoutSeconds 3 -EndOnGuestLivelock | Should -BeFalse
            $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 2.5
            Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty
        }

        It 'never ends early for a caller that did not ask' {
            Set-KernelStallSerial -Text $script:rcuStall
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-ScriptedWait -Frames @('booting') -Livelock (New-SilentProcessorVerdict -Seconds 1305) -TimeoutSeconds 3 | Should -BeFalse
            $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 2.5
            Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty
        }

        Context 'with every processor still servicing interrupts' {
            BeforeAll {
                # Short enough for a guest's silence to pass the threshold within
                # an example, with the host recording read every second so a
                # check follows each poll of the console.
                & (Get-Module Test.SequenceEngine) {
                    $script:SavedKernelStallSilentSeconds = $script:KernelStallSilentSeconds
                    $script:SavedGuestLivelockCheckSeconds = $script:GuestLivelockCheckSeconds
                    $script:KernelStallSilentSeconds = 2
                    $script:GuestLivelockCheckSeconds = 1
                }
                # A Kubernetes workload's console when its guest went silent, and
                # the hung-task reports its kernel printed while both processors
                # kept servicing interrupts.
                $script:lastWords = "== [push (website)] phase end exit=0 outcome=completed ==`n=== Set-Workload ==="
                $script:hungTask = @(
                    '[ 1230.187000] INFO: task kworker/u8:0:12 blocked for more than 121 seconds.'
                    '[ 1230.194000] INFO: task kube-controller:33152 blocked for more than 121 seconds.'
                ) -join "`n"
                $script:servicing = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running'
                    ProcessorWindow = [pscustomobject]@{ Processors = @(
                        [pscustomobject]@{ Processor = '0'; NoInterruptsServicedSeconds = 0; NoInterruptsServicedSinceUtc = '' }
                        [pscustomobject]@{ Processor = '1'; NoInterruptsServicedSeconds = 0; NoInterruptsServicedSinceUtc = '' }) } }
                # The guest recorder's upload as the status service leaves it,
                # last written the given number of seconds ago.
                function New-RecorderUpload {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                        Justification = 'Test helper: writes a fixture file into the example''s temp folder.')]
                    param([int]$AgeSeconds)
                    $path = Join-Path $script:probeDir 'execution.system.diagnostic.step-10.txt'
                    Set-Content -LiteralPath $path -Value "kernelUploadSchema=1`nuploadCreatedUtc=2026-11-02T12:53:55Z" -NoNewline
                    (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-$AgeSeconds)
                    return $path
                }
                function Get-KernelStallSerialRead { & (Get-Module Test.SequenceEngine) { $script:KernelStallSerialReads } }
            }
            AfterAll {
                & (Get-Module Test.SequenceEngine) {
                    $script:KernelStallSilentSeconds = $script:SavedKernelStallSilentSeconds
                    $script:GuestLivelockCheckSeconds = $script:SavedGuestLivelockCheckSeconds
                }
            }

            It 'ends on a kernel report once the console and the guest recorder have both been silent past the threshold' {
                Set-KernelStallSerial -Text $script:hungTask
                $upload = New-RecorderUpload -AgeSeconds 1255
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @($script:lastWords) -Livelock $script:servicing -TimeoutSeconds 60 -EndOnGuestLivelock -GuestRecorderPath $upload | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'the wait ends once the console has been static past the threshold, not at the deadline'
                $end = Get-ProbeFailSlot 'WaitForTextKernelStallEnd'
                $end.basis | Should -Be 'guest-silent'
                @($end.processors).Count | Should -Be 0 -Because 'every processor kept servicing interrupts'
                $end.noInterruptsServicedSeconds | Should -BeNullOrEmpty
                $end.noInterruptsServicedSinceUtc | Should -BeNullOrEmpty
                @($end.kinds) | Should -Be @('hung-task')
                $end.outputStaticSeconds | Should -BeGreaterOrEqual 2
                $end.recorderUploadAgeSeconds | Should -BeGreaterOrEqual 1255
                $end.waitedSeconds | Should -BeLessThan 20
                @(Get-KernelStallSerialRead) | Should -Be @(5000) -Because 'only a report that reached the console after the wait began can end it'
                (Get-ProbeFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
            }

            It 'waits out its budget on a silent guest whose console holds no kernel report' {
                Set-KernelStallSerial -Text '[ 1181.116000] systemd[1]: Started session-3.scope.'
                $upload = New-RecorderUpload -AgeSeconds 1255
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @($script:lastWords) -Livelock $script:servicing -TimeoutSeconds 6 -EndOnGuestLivelock -GuestRecorderPath $upload | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5.5
                Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty -Because 'silence alone never ends a wait'
                @(Get-KernelStallSerialRead).Count | Should -BeGreaterThan 0 -Because 'the guest was silent long enough for its console to be read'
            }

            It 'waits out its budget on a kernel report while the console keeps changing' {
                Set-KernelStallSerial -Text $script:hungTask
                $upload = New-RecorderUpload -AgeSeconds 1255
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @(1..40 | ForEach-Object { "Pushing layer $_ of 40" }) -Livelock $script:servicing -TimeoutSeconds 6 -EndOnGuestLivelock -GuestRecorderPath $upload | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5.5
                Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty -Because 'a console that keeps changing is a guest still working'
                @(Get-KernelStallSerialRead).Count | Should -Be 0
            }

            It 'waits out its budget on a kernel report and a static console when the caller names no recorder upload' {
                Set-KernelStallSerial -Text $script:hungTask
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @($script:lastWords) -Livelock $script:servicing -TimeoutSeconds 6 -EndOnGuestLivelock | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5.5
                Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty -Because 'a payload can run quietly for minutes, so a static console alone is not silence'
                @(Get-KernelStallSerialRead).Count | Should -Be 0
            }

            It 'does not end on a kernel report while the guest recorder still reaches the host, or before its first upload' {
                Set-KernelStallSerial -Text $script:hungTask
                # Written ahead of the host's clock, so a pause in this process
                # cannot age it past the shortened threshold.
                $fresh = New-RecorderUpload -AgeSeconds -600
                $absent = Join-Path $script:probeDir 'execution.system.diagnostic.not-uploaded.txt'
                foreach ($path in $fresh, $absent) {
                    & (Get-Module Test.SequenceEngine) { param($v, $p)
                        Get-GuestKernelStallEnd -VMName 'vm-01' -LivelockVerdict $v -SerialMark 5000 -OutputStaticSeconds 1325 -RecorderPath $p } $script:servicing $path |
                        Should -BeNullOrEmpty -Because "a recorder upload at '$path' is no evidence the guest went silent"
                }
                @(Get-KernelStallSerialRead).Count | Should -Be 0
            }

            It 'names the processor that stopped servicing interrupts when it and a silent guest both hold, and keeps the silence readings' {
                Set-KernelStallSerial -Text $script:hungTask
                $upload = New-RecorderUpload -AgeSeconds 1255
                $end = & (Get-Module Test.SequenceEngine) { param($v, $p)
                    Get-GuestKernelStallEnd -VMName 'vm-01' -LivelockVerdict $v -SerialMark 5000 -OutputStaticSeconds 1325 -RecorderPath $p } (New-SilentProcessorVerdict -Seconds 1305) $upload
                $end.basis | Should -Be 'no-interrupts-serviced'
                @($end.processors) | Should -Be @('0')
                $end.noInterruptsServicedSeconds | Should -Be 1305
                $end.noInterruptsServicedSinceUtc | Should -Be '2026-10-29T08:56:28.0000000Z'
                @($end.kinds) | Should -Be @('hung-task')
                $end.outputStaticSeconds | Should -Be 1325
                $end.recorderUploadAgeSeconds | Should -BeGreaterOrEqual 1255
            }
        }
    }

    Context 'a guest whose display driver stopped presenting frames' {
        BeforeAll {
            # The driver's serial accessor, scripted inside the engine. The
            # capture ends at 5000 bytes when the wait marks it.
            . (Get-Module Test.SequenceEngine) {
                function Read-VMSerialCapture {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                        Justification = 'Stub: the signature has to match the driver accessor so the caller binds.')]
                    param([string]$VMName, [long]$FromOffset = 0, [int]$MaxBytes = 4194304)
                    if ($MaxBytes -ne 0) { $script:DisplayStallSerialReads += @($FromOffset) }
                    return [pscustomobject]@{ Length = 5000L; Offset = $FromOffset; Text = $script:DisplayStallSerialText; Truncated = $false; Replaced = $false }
                }
            }
            # An installed guest's serial console on the ARM64 Hyper-V lab
            # host, from the login that met the forced password change to the
            # eighth timed-out commit. The screen kept the password
            # prompt it showed when the stall began; the guest ran on, and getty
            # restarted behind the frozen frame.
            $script:stalledDisplay = @(
                '[   49.997279] login[1350]: pam_unix(login:account): expired password for user yuuser26 (root enforced)'
                '[   54.673810] systemd[1]: systemd-timedated.service: Deactivated successfully.'
                '[   59.933095] chronyd[1130]: Backward time jump detected!'
                '[   59.933114] chronyd[1130]: Can''t synchronise: no selectable sources (0 unreachable sources)'
                '[   59.933859] systemd[1]: getty@tty1.service: Deactivated successfully.'
                '[   71.096573] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[   71.096579] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CRTC:36:crtc-0] commit wait timed out'
                '[   75.006111] CRON[1386]: pam_unix(cron:session): session opened for user root(uid=0) by root(uid=0)'
                '[   75.009248] CRON[1388]: (root) CMD (cd / && run-parts --report /etc/cron.hourly)'
                '[   75.013249] CRON[1386]: pam_unix(cron:session): session closed for user root'
                '[   81.975652] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[   81.975659] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [PLANE:34:plane-0] commit wait timed out'
                '[   82.171131] systemd[1]: getty@tty1.service: Scheduled restart job, restart counter is at 1.'
                '[   82.174119] systemd[1]: Started getty@tty1.service - Getty on tty1.'
                '[   93.624892] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[   93.624913] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CRTC:36:crtc-0] commit wait timed out'
                '[  103.864576] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[  103.864582] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [PLANE:34:plane-0] commit wait timed out'
                '[  114.108569] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[  114.108590] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CRTC:36:crtc-0] commit wait timed out'
                '[  124.345149] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[  124.345177] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CONNECTOR:38:Virtual-1] commit wait timed out'
                '[  134.584651] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[  134.584659] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [PLANE:34:plane-0] commit wait timed out'
                '[   96.901972] systemd[1]: Starting yuruna-host-locate.service - Refresh Yuruna host coordinates if the host has changed address...'
                '[  127.136533] systemd[1]: yuruna-host-locate.service: start operation timed out. Terminating.'
                '[  134.782177] systemd[1]: yuruna-host-locate.service: Main process exited, code=killed, status=15/TERM'
                '[  134.782235] systemd[1]: yuruna-host-locate.service: Failed with result ''timeout''.'
                '[  134.784135] systemd[1]: Failed to start yuruna-host-locate.service - Refresh Yuruna host coordinates if the host has changed address.'
                '[  145.848582] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out'
                '[  145.848588] hyperv_drm 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CRTC:36:crtc-0] commit wait timed out'
            ) -join "`n"
            $script:frozenScreen = "You are required to change your password immediately (administrator enforced).`nChanging password for yuuser26.`nCurrent password:`nNew password:"
            function New-DisplayStallLine {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test helper: returns console text.')]
                param([double[]]$Uptime, [string]$Driver = 'hyperv_drm')
                return (@(foreach ($at in $Uptime) {
                    '[{0,12:F6}] {1} 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* flip_done timed out' -f $at, $Driver
                    '[{0,12:F6}] {1} 5620e0c7-8062-4dce-aeb7-520c7ef76171: [drm] *ERROR* [CRTC:36:crtc-0] commit wait timed out' -f ($at + 0.00001), $Driver
                }) -join "`n")
            }
            function Set-DisplayStallSerial {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory console; no external state.')]
                param([string]$Text)
                & (Get-Module Test.SequenceEngine) { param($t) $script:DisplayStallSerialText = $t; $script:DisplayStallSerialReads = @() } $Text
            }
            function Get-DisplayStallSerialRead { & (Get-Module Test.SequenceEngine) { $script:DisplayStallSerialReads } }
            function Get-DisplayStallEnd {
                param([Nullable[int]]$ConsoleUnchangedSeconds)
                & (Get-Module Test.SequenceEngine) { param($s) Get-GuestDisplayStallEnd -VMName 'vm-01' -SerialMark 5000 -ConsoleUnchangedSeconds $s } $ConsoleUnchangedSeconds
            }
        }
        AfterAll {
            . (Get-Module Test.SequenceEngine) { Remove-Item -LiteralPath function:\Read-VMSerialCapture -ErrorAction SilentlyContinue }
        }

        It 'names the stalled driver from a lab guest''s serial console once the console has been unchanged thirty seconds' {
            Set-DisplayStallSerial -Text $script:stalledDisplay
            $end = Get-DisplayStallEnd -ConsoleUnchangedSeconds 30
            $end.driver | Should -Be 'hyperv_drm'
            $end.reports | Should -Be 16
            $end.firstUptimeSeconds | Should -Be 71.097
            $end.lastUptimeSeconds | Should -Be 145.849
            $end.spanSeconds | Should -Be 74.752
            $end.newestRecordUptimeSeconds | Should -Be 145.849
            $end.consoleUnchangedSeconds | Should -Be 30
            $end.text | Should -Match 'flip_done timed out$'
            @(Get-DisplayStallSerialRead) | Should -Be @(5000) -Because 'only what reached the console after the wait began can end it'
        }

        It 'ends a frozen console on the virtio GPU page-flip stalls used by UTM and KVM' {
            Set-DisplayStallSerial -Text (New-DisplayStallLine -Uptime @(71.1, 81.4, 91.7, 102.0) -Driver 'virtio_gpu')
            $end = Get-DisplayStallEnd -ConsoleUnchangedSeconds 30
            $end.driver | Should -BeExactly 'virtio_gpu'
            $end.reports | Should -Be 8
            $end.spanSeconds | Should -Be 30.9
        }

        It 'ends nothing on <Case>' -TestCases @(
            @{ Case = 'one commit that timed out, as a mode set can leave'; Uptime = @(71.1); Driver = 'hyperv_drm'; After = '' }
            @{ Case = 'three timed-out commits inside twenty seconds'; Uptime = @(71.1, 76.1, 81.1); Driver = 'hyperv_drm'; After = '' }
            @{ Case = 'a stall that stopped while the guest kept printing'; Uptime = @(71.1, 81.4, 91.7, 102.0); Driver = 'hyperv_drm'
                After = '[  160.500000] systemd[1]: Started session-3.scope - Session 3 of User yuuser26.' }
            @{ Case = 'a display driver no wait ends on'; Uptime = @(71.1, 81.4, 91.7, 102.0); Driver = 'unsupported_drm'; After = '' }
            @{ Case = 'a stall that began in a boot before the newest'; Uptime = @(71.1, 81.4, 91.7, 102.0); Driver = 'hyperv_drm'
                After = "[    2.321686] systemd-modules-load[98]: Module 'i2c_dev' is built in`n[   22.529439] systemd[1]: Starting systemd-user-sessions.service - Permit User Sessions..." }
        ) {
            param($Case, $Uptime, $Driver, $After)
            $text = New-DisplayStallLine -Uptime $Uptime -Driver $Driver
            if ($After) { $text += "`n$After" }
            Set-DisplayStallSerial -Text $text
            Get-DisplayStallEnd -ConsoleUnchangedSeconds 1325 | Should -BeNullOrEmpty -Because "$Case is no display that stopped presenting frames"
        }

        It 'does not read the serial console before the console has been unchanged thirty seconds, or when nothing measured it' {
            Set-DisplayStallSerial -Text $script:stalledDisplay
            Get-DisplayStallEnd -ConsoleUnchangedSeconds 29 | Should -BeNullOrEmpty
            Get-DisplayStallEnd -ConsoleUnchangedSeconds $null | Should -BeNullOrEmpty
            @(Get-DisplayStallSerialRead).Count | Should -Be 0
        }

        Context 'inside a wait' {
            BeforeAll {
                # Short enough for the console to pass the threshold within an
                # example, with the check run every second so one follows each
                # poll of the console. The report count and span keep their
                # shipped values, which the replayed console has to meet.
                & (Get-Module Test.SequenceEngine) {
                    $script:SavedDisplayStallEndSeconds = $script:DisplayStallEndSeconds
                    $script:SavedDisplayGuestLivelockCheckSeconds = $script:GuestLivelockCheckSeconds
                    $script:DisplayStallEndSeconds = 2
                    $script:GuestLivelockCheckSeconds = 1
                }
                $script:running = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; Detail = 'running' }
            }
            AfterAll {
                & (Get-Module Test.SequenceEngine) {
                    $script:DisplayStallEndSeconds = $script:SavedDisplayStallEndSeconds
                    $script:GuestLivelockCheckSeconds = $script:SavedDisplayGuestLivelockCheckSeconds
                }
            }

            It 'ends the wait on a frozen <Shape> screen and records why' -TestCases @(
                @{ Shape = 'readable'; Frame = "Changing password for yuuser26.`nCurrent password:`nNew password:" }
                @{ Shape = 'blank'; Frame = '' }
            ) {
                param($Shape, $Frame)
                Set-DisplayStallSerial -Text $script:stalledDisplay
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @($Frame) -Livelock $null -TimeoutSeconds 60 -EndOnDisplayStall | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because "a $Shape screen that stopped changing ends the wait, not the deadline"
                $end = Get-ProbeFailSlot 'WaitForTextDisplayStallEnd'
                $end.driver | Should -Be 'hyperv_drm'
                $end.reports | Should -Be 16
                $end.consoleUnchangedSeconds | Should -BeGreaterOrEqual 2
                $end.waitedSeconds | Should -BeLessThan 20
                Get-ProbeFailSlot 'WaitForTextKernelStallEnd' | Should -BeNullOrEmpty -Because 'a display stall is no kernel fault'
            }

            It 'waits out its budget on a display stall while the console keeps changing, without reading the serial console' {
                Set-DisplayStallSerial -Text $script:stalledDisplay
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @(1..40 | ForEach-Object { "Unpacking layer $_ of 40" }) -Livelock $null -TimeoutSeconds 6 -EndOnDisplayStall | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5.5
                Get-ProbeFailSlot 'WaitForTextDisplayStallEnd' | Should -BeNullOrEmpty -Because 'a console that keeps changing is a display that still presents frames'
                @(Get-DisplayStallSerialRead).Count | Should -Be 0
            }

            It 'never ends early on a display stall for a caller that did not ask, even one that ends on a livelock' {
                Set-DisplayStallSerial -Text $script:stalledDisplay
                $clock = [Diagnostics.Stopwatch]::StartNew()
                Invoke-ScriptedWait -Frames @($script:frozenScreen) -Livelock $script:running -TimeoutSeconds 6 -EndOnGuestLivelock | Should -BeFalse
                $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 5.5
                Get-ProbeFailSlot 'WaitForTextDisplayStallEnd' | Should -BeNullOrEmpty -Because 'the stall stays a diagnostic for a wait without a cold restart behind it'
            }
        }
    }
}
