<#PSScriptInfo
.VERSION 2026.11.16
.GUID 423a6cde-29dc-4785-ab44-40941cf303ec
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence wait step pester
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
    Hold Wait-ForText to the text a step itself put on screen: what stood
    there when the step began never satisfies its wait.
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

Describe 'Wait-ForText -SinceStepStart ignores what was already on screen' {
    # The fixture is the shape that makes this necessary: a rotation prompt whose
    # wording, once normalization folds it, is carried whole by the prompt
    # standing above it -- "Current password:" supplies every character of a
    # "...ew password:" pattern, in order and close together. Ungated, the wait
    # returns true on its first poll against a screen where the prompt it is
    # waiting for has not been printed -- and the caller then types a secret into
    # a terminal PAM has not yet switched out of echo.
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
                # Scripted frames, one per poll, last one repeating -- but the
                # MATCH itself is the real Test-OCRMatch over the real fixture
                # text. A stub that returned a scripted boolean would prove
                # nothing about the tolerance this gate exists to contain.
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                param($ImagePath, $Pattern, $FreshMatchTailLines, [switch]$NoSegmentMatch)
                $i = [Math]::Min($script:TextProbe.Poll, $script:TextProbe.Frames.Count - 1)
                $text = [string]$script:TextProbe.Frames[$i]
                $script:TextProbe.Poll++
                $forMatch = if ($FreshMatchTailLines -gt 0 -and $text) {
                    (($text -split "`n") | Select-Object -Last $FreshMatchTailLines) -join "`n"
                } else { $text }
                $matched = $false
                foreach ($p in $Pattern) { if ($forMatch -and (Test-OCRMatch -Text $forMatch -Pattern $p -NoSegmentMatch:$NoSegmentMatch)) { $matched = $true; break } }
                return @{ Match = $matched; AnyText = $text; EngineResults = [ordered]@{ scripted = @{ Text = $text; Matched = $matched } } }
            }
            function Reset-TextProbeState {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
                param([string]$ScreenDir, [string[]]$Frames)
                $script:TextProbe = @{ ScreenDir = $ScreenDir; Poll = 0; Frames = $Frames }
                return $script:TextProbe
            }
        }

        $script:alreadyOnScreen = @(
            'You are required to change your password immediately (administrator enforced)'
            'Changing password for testuser.'
            'Current password:'
        ) -join "`n"
        $script:promptPrinted = $script:alreadyOnScreen + "`nNew password:"
    }

    BeforeEach {
        $script:textDir = New-YurunaTestTempDir -Prefix 'yuruna-wft'
    }

    AfterEach {
        Remove-YurunaTestTempDir $script:textDir
    }

    It 'exposes the parameter as a bool the sequence handler can splat' {
        $p = (Get-Command Wait-ForText).Parameters
        Assert-True ($p.ContainsKey('SinceStepStart')) 'Wait-ForText must accept the step-start gate'
        Assert-Equal -Expected 'Boolean' -Actual $p['SinceStepStart'].ParameterType.Name -Because 'the sequence schema carries a boolean'
    }

    It 'ungated, prose already on screen satisfies the prompt pattern (the behavior the gate exists to stop)' {
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $false) `
            'the tolerant matcher finds the pattern in the banner, on a screen where the prompt was never printed'
    }

    It 'waits for a genuine prompt through installer frames (fresh=<Fresh>, since=<Since>)' -TestCases @(
        @{ Fresh = $false; Since = $false }, @{ Fresh = $true; Since = $false },
        @{ Fresh = $false; Since = $true }, @{ Fresh = $true; Since = $true }
    ) {
        param($Fresh, $Since)
        $installer = "passwd --expire amisad-core-admin`nsed -i ... /target/etc/login.defs"
        $frames = @('booting', $installer, $installer, 'amisad-core login: _')
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames $frames -Pattern 'amisad-core login:' `
            -Since $Since -Fresh $Fresh -NoSegmentMatch -TimeoutSeconds 8)
        $polls = & (Get-Module Test.SequenceEngine) { $script:TextProbe.Poll }
        Assert-Equal -Expected 4 -Actual $polls -Because 'neither the live, filtered, nor accumulated installer text is a prompt'
    }

    It 'does not assemble a prompt from words in different captured frames' {
        $frames = @('passwd --expire amisad-core-admin', 'sed -i ... /target/etc/login.defs', 'amisad-core login: _')
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames $frames -Pattern 'amisad-core login:' `
            -Since $false -NoSegmentMatch -TimeoutSeconds 6)
        $polls = & (Get-Module Test.SequenceEngine) { $script:TextProbe.Poll }
        Assert-Equal -Expected 3 -Actual $polls -Because 'cross-frame accumulation must use the same bounded matching policy'
    }

    It 'gated, the same screen never satisfies the wait and it times out normally' {
        Assert-False (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $true) `
            'nothing was printed after the step began, so there is no evidence to match'
    }

    It 'gated, matches as soon as the guest prints the prompt on a new line' {
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen, $script:promptPrinted) -Pattern @('ew password:') -Since $true) `
            'a line absent from the baseline is exactly what the wait is for'
    }

    It 'gated, matches a prompt that arrived before its own first frame when the previous wait handed on a baseline' {
        # The console answers faster than the poll interval: PAM prints the next
        # prompt within milliseconds of the keystroke that earned it, so by the
        # time this wait takes its first frame the prompt is already sitting
        # there. Reading the baseline off that frame buries the prompt in it,
        # and since a guest prints each prompt exactly once the wait can then
        # only time out. Seeded from what the PREVIOUS wait matched, the prompt
        # is new and the wait returns.
        $null = & (Get-Module Test.SequenceEngine) { param($d, $f) Reset-TextProbeState -ScreenDir $d -Frames $f } `
            $script:textDir @($script:alreadyOnScreen)
        Clear-CarriedConsoleBaseline
        Assert-True ([bool](Wait-ForText -VMName 'vm-01' -Pattern @('urrent password:') -TimeoutSeconds 4 -PollSeconds 1 `
            -WarningAction SilentlyContinue -InformationAction SilentlyContinue)) `
            'the first wait matches and hands its screen on'

        # No Clear between the two: this is the continuation the carry exists for.
        $null = & (Get-Module Test.SequenceEngine) { param($d, $f) Reset-TextProbeState -ScreenDir $d -Frames $f } `
            $script:textDir @($script:promptPrinted)
        Assert-True ([bool](Wait-ForText -VMName 'vm-01' -Pattern @('ew password:') -TimeoutSeconds 4 -PollSeconds 1 `
            -SinceStepStart:$true -WarningAction SilentlyContinue -InformationAction SilentlyContinue)) `
            'the prompt is absent from the handed-on screen, so it is new evidence even though it is on this wait''s first frame'
    }

    It 'gated, a baseline is handed on at most once, so a later wait is not seeded by a stale screen' {
        $null = & (Get-Module Test.SequenceEngine) { param($d, $f) Reset-TextProbeState -ScreenDir $d -Frames $f } `
            $script:textDir @($script:alreadyOnScreen)
        Clear-CarriedConsoleBaseline
        $null = Wait-ForText -VMName 'vm-01' -Pattern @('urrent password:') -TimeoutSeconds 4 -PollSeconds 1 `
            -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Assert-True ($null -ne (Get-CarriedConsoleBaseline -VMName 'vm-01')) 'the match recorded a baseline'
        Assert-True ($null -eq (Get-CarriedConsoleBaseline -VMName 'vm-01')) 'reading it consumed it'
    }

    It 'gated, a baseline is never handed to a different guest' {
        $null = & (Get-Module Test.SequenceEngine) { param($d, $f) Reset-TextProbeState -ScreenDir $d -Frames $f } `
            $script:textDir @($script:alreadyOnScreen)
        Clear-CarriedConsoleBaseline
        $null = Wait-ForText -VMName 'vm-01' -Pattern @('urrent password:') -TimeoutSeconds 4 -PollSeconds 1 `
            -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Assert-True ($null -eq (Get-CarriedConsoleBaseline -VMName 'vm-02')) `
            'one guest console can never describe another'
    }

    It 'gated, a screen that was unreadable on the first frame still matches later text' {
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames @('', 'New password:') -Pattern @('ew password:') -Since $true) `
            'an empty baseline degrades to an ordinary wait rather than to one that can never match'
    }

    It 'keeps testing anti-patterns against the WHOLE frame, including the baseline' {
        Assert-False (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $true `
            -FailurePattern @('administrator enforced')) 'the wait aborts'
        $signal = [string](Get-SequenceFailureState).WaitForTextMatchedFailurePattern
        Assert-Equal -Expected 'administrator enforced' -Actual $signal `
            -Because 'a rejection already on screen when the step started is still a rejection'
    }

    It 'still records the whole frame in the failure artifacts on a gated timeout' {
        $null = Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $true
        $tail = [string](Get-SequenceFailureState).WaitForTextOcrTail
        Assert-True ($tail.Contains('administrator enforced')) `
            'the gate narrows what is MATCHED, never what the operator is shown'
    }

    It 'composes with a tail-confined match: both filters narrow, neither widens' {
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen, $script:promptPrinted) -Pattern @('ew password:') -Since $true -Fresh $true) `
            'a new line at the bottom passes both'
        Assert-False (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $true -Fresh $true) `
            'no new line passes neither'
    }

    It 'leaves a tail-confined match alone when the gate is off' {
        Assert-True (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($script:alreadyOnScreen) -Pattern @('ew password:') -Since $false -Fresh $true) `
            'the existing window is unchanged by a gate nobody asked for'
    }

    It 'records a visible installer stage during a tail-confined login wait' {
        $frame = "start: subiquity/Mirror/cmd-apt-config: curtin command apt-config`nstart: subiquity/Network/_send_update: CHANGE eth0"
        Assert-False (Invoke-GatedWait -ScreenDir $script:textDir -Frames @($frame) -Pattern @('yuuser26 login:') -Since $false -Fresh $true -TimeoutSeconds 2)
        $failure = Get-SequenceFailureState
        Assert-Equal -Expected 'start: subiquity/Mirror/cmd-apt-config' -Actual $failure.WaitForTextInstallerStage
        $failure.WaitForTextOutputStaticSeconds | Should -BeGreaterOrEqual 1
        $failure.WaitForTextConsoleSignalsMeasured | Should -BeFalse
    }
}
