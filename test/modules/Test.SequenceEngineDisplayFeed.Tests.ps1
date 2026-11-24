<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42f1f050-661d-4116-8e5d-61e3f969b3fe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence wait display capture pester
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
    Hold how Wait-ForText treats the display feed itself: a display the
    emulator keeps reporting inactive, and the grace a capture repair earns.
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

Describe 'Wait-ForText ends on a display the emulator keeps reporting inactive' {
    BeforeAll {
        . (Get-Module Test.SequenceEngine) {
            function Get-EnabledOcrProvider { return @('scripted') }
            function Get-CycleScreenDir {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($script:DisplayProbe.ScreenDir, 'Ensure cycle screen dir exists')
                return $script:DisplayProbe.ScreenDir
            }
            function Get-VMScreenshot {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $OutFile, $HostType)
                Set-Content -LiteralPath $OutFile -Value ('png{0}' -f $script:DisplayProbe.Poll) -NoNewline
                return $true
            }
            function Test-CombinedOcrMatch {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($ImagePath, $Pattern, $FreshMatchTailLines, [switch]$NoSegmentMatch)
                $i = $script:DisplayProbe.Poll % $script:DisplayProbe.Frames.Count
                $text = [string]$script:DisplayProbe.Frames[$i]
                $script:DisplayProbe.Poll++
                return @{ Match = $false; AnyText = $text; EngineResults = [ordered]@{ scripted = @{ Text = $text; Matched = $false } } }
            }
            # No host recording: the hypervisor verdict must not be what ends these waits.
            function Get-GuestLivelockVerdict {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $Since)
                return $null
            }
            function Get-VMConsoleSecondOpinion {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real host-driver probe so the caller binds.')]
                param($VMName, $IntervalSeconds)
                $script:DisplayProbe.OpinionReads++
                return [pscustomobject]@{ Verdict = $script:DisplayProbe.Opinion; Detail = "scripted $($script:DisplayProbe.Opinion)"; CpuPercent = 1082.0 }
            }
            $script:DisplayOpinionStub = ${function:Get-VMConsoleSecondOpinion}
            function Reset-DisplayProbeState {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
                param([string]$ScreenDir, [string[]]$Frames, [string]$Opinion)
                $script:DisplayProbe = @{ ScreenDir = $ScreenDir; Poll = 0; Frames = $Frames; Opinion = $Opinion; OpinionReads = 0 }
            }
            $script:SavedDisplayInactiveLivelockSeconds = $script:DisplayInactiveLivelockSeconds
            $script:DisplayInactiveLivelockSeconds = 2
        }
        $script:inactive = 'Display output is not active.'
        function Invoke-DisplayWait {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: drives the function under test against scripted frames.')]
            param([string[]]$Frames, [string]$Opinion, [int]$TimeoutSeconds, [switch]$EndOnGuestLivelock)
            & (Get-Module Test.SequenceEngine) { param($d, $f, $o) Reset-DisplayProbeState -ScreenDir $d -Frames $f -Opinion $o } $script:probeDir $Frames $Opinion
            Clear-CarriedConsoleBaseline
            return [bool](Wait-ForText -VMName 'vm-01' -Pattern @('amisad-edge-a login:') -TimeoutSeconds $TimeoutSeconds -PollSeconds 1 `
                -EndOnGuestLivelock:$EndOnGuestLivelock -WarningAction SilentlyContinue -InformationAction SilentlyContinue)
        }
        function Get-DisplayProbeValue { param([string]$Name) & (Get-Module Test.SequenceEngine) { param($n) $script:DisplayProbe[$n] } $Name }
        function Get-DisplayFailSlot { param([string]$Name) & (Get-Module Test.SequenceEngine) { param($n) $script:Fail[$n] } $Name }
    }
    AfterAll {
        & (Get-Module Test.SequenceEngine) {
            $script:DisplayInactiveLivelockSeconds = $script:SavedDisplayInactiveLivelockSeconds
            Remove-Item -Path Function:\Get-VMConsoleSecondOpinion -ErrorAction SilentlyContinue
        }
    }
    BeforeEach {
        $script:probeDir = New-YurunaTestTempDir -Prefix 'yuruna-wfd'
    }
    AfterEach { Remove-YurunaTestTempDir $script:probeDir }

    It 'ends the wait once the whole window shows no display and the second opinion finds the guest wedged' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-DisplayWait -Frames @($script:inactive) -Opinion 'guest-wedged' -TimeoutSeconds 60 -EndOnGuestLivelock | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'the cold restart must not wait out the remaining budget'
        (Get-DisplayFailSlot 'WaitForTextGuestLivelocked') | Should -BeTrue
        $verdict = Get-DisplayFailSlot 'WaitForTextGuestLivelock'
        $verdict.Verdict | Should -Be 'livelocked'
        $verdict.LivelockedSeconds | Should -BeGreaterOrEqual 2
        $verdict.MinimumSeconds | Should -Be 2
        (Get-DisplayFailSlot 'WaitForTextConsoleSecondOpinion').Verdict | Should -Be 'guest-wedged'
        Get-DisplayProbeValue 'OpinionReads' | Should -Be 1 -Because 'the failure record reuses the reading that ended the wait'
    }
    It 'keeps waiting when the second opinion does not find the guest wedged' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-DisplayWait -Frames @($script:inactive) -Opinion 'guest-static' -TimeoutSeconds 4 -EndOnGuestLivelock | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 3.5
        (Get-DisplayFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse -Because 'an inactive display alone never authorizes a reset'
    }
    It 'needs every frame of the window to show no display' {
        Invoke-DisplayWait -Frames @($script:inactive, 'booting') -Opinion 'guest-wedged' -TimeoutSeconds 5 -EndOnGuestLivelock | Should -BeFalse
        (Get-DisplayFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
        Get-DisplayProbeValue 'OpinionReads' | Should -Be 0 -Because 'a frame with other content restarts the run'
    }
    It 'leaves a wait that did not ask to end on a livelock on its full budget' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-DisplayWait -Frames @($script:inactive) -Opinion 'guest-wedged' -TimeoutSeconds 4 | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 3.5
        (Get-DisplayFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
        Get-DisplayProbeValue 'OpinionReads' | Should -Be 0
    }
    It 'leaves hosts without an independent framebuffer read on their full budget' {
        & (Get-Module Test.SequenceEngine) { Remove-Item -Path Function:\Get-VMConsoleSecondOpinion }
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Invoke-DisplayWait -Frames @($script:inactive) -Opinion 'guest-wedged' -TimeoutSeconds 4 -EndOnGuestLivelock | Should -BeFalse
            $clock.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 3.5
            (Get-DisplayFailSlot 'WaitForTextGuestLivelocked') | Should -BeFalse
        } finally {
            . (Get-Module Test.SequenceEngine) { Set-Item -Path Function:\Get-VMConsoleSecondOpinion -Value $script:DisplayOpinionStub }
        }
    }
}

Describe 'Wait-ForText pays a capture repair''s grace only for a feed that moved' {
    BeforeAll {
        . (Get-Module Test.SequenceEngine) {
            function Get-EnabledOcrProvider { return @('scripted') }
            function Get-CycleScreenDir {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($script:RepairProbe.ScreenDir, 'Ensure cycle screen dir exists')
                return $script:RepairProbe.ScreenDir
            }
            function Get-VMScreenshot {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $OutFile, $HostType)
                $body = if ($script:RepairProbe.FrameMoves) { 'png{0}' -f $script:RepairProbe.Poll } else { 'png-frozen' }
                Set-Content -LiteralPath $OutFile -Value $body -NoNewline
                return $true
            }
            function Test-CombinedOcrMatch {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($ImagePath, $Pattern, $FreshMatchTailLines, [switch]$NoSegmentMatch)
                $script:RepairProbe.Poll++
                return @{ Match = $false; AnyText = ''; EngineResults = [ordered]@{ scripted = @{ Text = ''; Matched = $false } } }
            }
            function Get-GuestLivelockVerdict {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($VMName, $Since)
                return $null
            }
            function Repair-VncConnection {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real primitive so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName, $HostType)
                $null = $PSCmdlet.ShouldProcess($VMName, 'stub reset')
                $script:RepairProbe.VncRepairs++
                return [pscustomobject]@{ Attempted = $true; Effective = $true; Mechanism = 'vnc-input-handle' }
            }
            function Repair-ScreenshotRing {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real primitive so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($VMName, 'stub clear')
                $script:RepairProbe.RingRepairs++
                return [pscustomobject]@{ Attempted = $true; Effective = $true; Mechanism = 'screenshot-ring' }
            }
            function Reset-RepairProbe {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
                param([string]$ScreenDir, [bool]$FrameMoves)
                $script:RepairProbe = @{ ScreenDir = $ScreenDir; FrameMoves = $FrameMoves; Poll = 0; VncRepairs = 0; RingRepairs = 0 }
            }
        }
        function Invoke-RepairWait {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: drives the function under test against scripted frames.')]
            param([bool]$FrameMoves, [switch]$ExpectBlankConsole)
            & (Get-Module Test.SequenceEngine) { param($d, $m) Reset-RepairProbe -ScreenDir $d -FrameMoves $m } $script:repairDir $FrameMoves
            Clear-CarriedConsoleBaseline
            $blank = if ($ExpectBlankConsole) { @{ ExpectBlankConsole = $true } } else { @{} }
            $stream = Wait-ForText -VMName 'vm-01' -Pattern @('login:') -TimeoutSeconds 6 -PollSeconds 1 @blank -InformationAction SilentlyContinue 3>&1
            return @($stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        }
        function Get-RepairProbe { param([string]$Name) & (Get-Module Test.SequenceEngine) { param($n) $script:RepairProbe[$n] } $Name }
    }
    BeforeEach {
        $script:repairDir = New-YurunaTestTempDir -Prefix 'yuruna-wfr'
    }
    AfterEach { Remove-YurunaTestTempDir $script:repairDir }

    It 'grants nothing for a repair the next frames show did not reach the feed, and keeps the run-up frames' {
        $warnings = Invoke-RepairWait -FrameMoves $false
        (Get-RepairProbe 'VncRepairs') | Should -BeGreaterOrEqual 1 -Because 'four blank polls still ask for the repair'
        (Get-RepairProbe 'RingRepairs') | Should -Be 0 -Because 'the ring holds the frames a failure is read against'
        ($warnings -join "`n") | Should -Not -Match 'degradation grace' -Because 'a frozen feed keeps its normal budget'
        @(Get-ChildItem -LiteralPath $script:repairDir -Filter 'raw_*.png').Count | Should -BeGreaterThan 1
    }
    It 'grants the grace once a frame after the repair differs' {
        $warnings = Invoke-RepairWait -FrameMoves $true
        ($warnings -join "`n") | Should -Match '\+\d+s degradation grace'
    }
    It 'leaves a blank console alone on a step that expects one, and still records how long it stayed blank' {
        # A login wait that follows an install reboot or a cold restart starts
        # on a console that shows nothing until getty prints. The step says so,
        # and the self-heal that reads a blank run as a stale feed stays off for
        # it; a step without the declaration keeps the repair.
        $null = Invoke-RepairWait -FrameMoves $false
        (Get-RepairProbe 'VncRepairs') | Should -BeGreaterOrEqual 1 -Because 'a step that did not declare a blank console still asks for the repair'
        $null = Invoke-RepairWait -FrameMoves $false -ExpectBlankConsole
        (Get-RepairProbe 'VncRepairs') | Should -Be 0 -Because 'blank frames are the declared run-up, not a stale feed'
        (Get-RepairProbe 'RingRepairs') | Should -Be 0
        (& (Get-Module Test.SequenceEngine) { $script:Fail.WaitForTextBlankScreenSeconds }) | Should -BeGreaterOrEqual 3 `
            -Because 'the timeout record still names the blank run, which is what tells a dead feed from a slow boot'
    }
}
