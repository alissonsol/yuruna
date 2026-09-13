<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42d9a6c1-58b7-4f0e-9a2e-7c1f6b0d4e33
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence handler console pester
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
    Pester coverage for the blind-answer path of waitForAndEnter
    (Invoke-BlindAnswer in Test.SequenceHandler.psm1).
.DESCRIPTION
    A prompt printed once and never reprinted outlives its own text on screen:
    the guest goes on waiting for input long after the question has scrolled
    away, and no further waiting recovers it. Answering it anyway is only safe
    while the screen says the guest is parked rather than busy, and only worth
    reporting as success once something proves the answer was consumed. Both
    halves of that contract are asserted here.

    Behavioral, not AST: the module's own helpers are stubbed inside its session
    state (they are called unqualified, so a stub defined in the module shadows
    the real one) and the handler is driven through the action registry the
    engine dispatches against. Throw-based assertions, Pester 3.4 / 5+.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SequenceHandler.psm1') -Force -DisableNameChecking -Global

# Stubs live in the module's own session state so the unqualified calls inside
# Invoke-BlindAnswer resolve to them. Their recording goes in one hashtable that
# also lives in module scope: an It body cannot see that scope directly, but it
# holds a reference to the same object once Reset-BlindState hands it back, so
# the assertions read what the stubs wrote without a single global.
. (Get-Module Test.SequenceHandler) {
    function Get-LastWaitVerdict { return $script:BlindStub.Verdict }

    function Invoke-TypeDrainEnter {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub: the signature has to match the real helper so the caller binds; only Text is recorded.')]
        param($Context, $Text, $DelaySeconds, $CharDelayMs, $Activity, [switch]$ShellEscape)
        $script:BlindStub.Typed += @([string]$Text)
        return $script:BlindStub.TypeOk
    }

    function Wait-ForConsoleChange {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub: the signature has to match the real function so the caller binds; only BaselineText is recorded.')]
        param($VMName, $HostType, $BaselineText, $TimeoutSeconds, $PollSeconds)
        $script:BlindStub.ChangeBaseline = [string]$BaselineText
        $script:BlindStub.ChangeCalls++
        return $script:BlindStub.ChangeOk
    }

    function Get-LastConsoleChangeVerdict { return $script:BlindStub.ChangeVerdict }

    function Wait-ForText {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub: the signature has to match the real function so the caller binds; only Pattern and TimeoutSeconds are recorded.')]
        param($HostType, $VMName, $Pattern, $TimeoutSeconds, $PollSeconds, $FreshMatch,
              $FreshMatchTailLines, $FailurePattern, [bool]$SinceStepStart)
        $script:BlindStub.WaitPatterns += @(,@($Pattern))
        $script:BlindStub.WaitTimeouts += @([int]$TimeoutSeconds)
        if ($script:BlindStub.WaitResults.Count -gt 0) {
            $next = $script:BlindStub.WaitResults[0]
            $script:BlindStub.WaitResults = @($script:BlindStub.WaitResults | Select-Object -Skip 1)
            return $next
        }
        return $false
    }

    function Reset-BlindStubState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
        param()
        $script:BlindStub = @{
            Typed          = @()
            TypeOk         = $true
            ChangeOk       = $true
            ChangeCalls    = 0
            ChangeBaseline = ''
            WaitPatterns   = @()
            WaitTimeouts   = @()
            WaitResults    = @()
            ChangeVerdict  = @{
                Changed        = $false
                Readable       = $true
                Polls          = 18
                Captures       = 18
                Reads          = 18
                TimeoutSeconds = 90
            }
            Verdict        = @{
                Matched              = $false
                Flooded              = $true
                DominantLine         = 'subiquity/Network/_send_update:'
                ConsoleStaticSeconds = 100
                ConsoleRestartsUsed  = 2
                ElapsedSeconds       = 120
                ConsoleText          = 'start: subiquity/Network/_send_update: CHANGE eth0'
            }
        }
        return $script:BlindStub
    }
}

function Reset-BlindState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: reseeds the in-memory recording bag the stubs write to; no external state.')]
    param()
    return (& (Get-Module Test.SequenceHandler) { Reset-BlindStubState })
}

function Get-BlindContext {
    param([hashtable]$Step)
    return @{
        Step               = $Step
        Vars               = @{}
        ExpandVariable     = { param($Value, $Vars) $null = $Vars; $Value }
        ShowSensitive      = $true
        HostType           = 'host.windows.hyper-v'
        VMName             = 'test-guest.ubuntu.server.24-01'
        GuestKey           = 'guest.ubuntu.server.24'
        DefaultCharDelayMs = 10
        DefaultPollSeconds = 5
        DefaultTimeoutSeconds = 180
    }
}

function Invoke-BlindAnswerUnderTest {
    # Advanced function on purpose: -WarningVariable is what lets a caller assert
    # on the WORDING, and the wording is the finding in the unreadable-console
    # case -- the bool is $false either way.
    [CmdletBinding()]
    param([hashtable]$Context, [string[]]$Patterns)
    return (& (Get-Module Test.SequenceHandler) { param($c, $p) Invoke-BlindAnswer -Context $c -Patterns $p } $Context $Patterns)
}
}

Describe 'Invoke-BlindAnswer refuses to type at a console that is still moving' {
    It 'sends nothing while the content keeps changing' {
        # A guest that is still printing is still working, and its console may be
        # read by something other than the prompt this step was written for.
        # Typing into that is the one case where a stray answer can do harm.
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleStaticSeconds = 10
        $stub.Verdict.ElapsedSeconds       = 120
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result -Because 'a moving console is not a parked guest'
        Assert-Equal -Expected 0 -Actual $stub.Typed.Count -Because 'nothing may be typed at a live console'
    }

    It 'sends nothing when the screen has no text at all' {
        # A blank screen is a capture-path problem; Wait-ForText owns that case,
        # and typing at it would prove nothing either way.
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleText = ''
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result
        Assert-Equal -Expected 0 -Actual $stub.Typed.Count
    }
}

Describe 'Invoke-BlindAnswer refuses a screen the step declares off limits' {
    BeforeAll {
        # Ubuntu's language menu, as the failure capture actually OCR'd it --
        # transcription errors included. It is static and it moves when typed
        # at, so it passes both of the blind path's own tests while being the
        # one screen the answer must never reach: the menu is what an installer
        # shows when autoinstall did not engage, so the prompt is not live and
        # no answer can be consumed. Built in BeforeAll, not in the Describe
        # body: a Describe body runs at discovery, and a fixture left there is
        # $null by the time an It reads it -- which reads as a pass on every
        # assertion that expects a refusal.
        $script:LanguageMenu = @(
            'Use UP, DOMN and ENTER keys to select your language.'
            '[ Asturianu +]'
            '[ Bahasa Indonesia +]'
            '[ Catala +]'
            '[ Deutsch +]'
            '[ English (UK) >]'
        ) -join "`n"
    }

    It 'reads a language menu fixture that is actually present' {
        # Guards the three assertions below: an empty fixture would send them
        # down the no-text-on-screen path and pass for the wrong reason.
        Assert-Equal -Expected $true -Actual ([bool]$script:LanguageMenu)
        Assert-Equal -Expected $true -Actual ($script:LanguageMenu -match 'Bahasa Indonesia')
    }

    It 'types nothing when the console shows the declared screen' {
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleText = $script:LanguageMenu
        $ctx = Get-BlindContext -Step @{
            text = 'yes'; blindAfterSeconds = 120; blindSkipPattern = 'Bahasa Indonesia'
        }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result -Because 'the prompt is not live on that screen'
        Assert-Equal -Expected 0 -Actual $stub.Typed.Count -Because 'the answer must not reach an interactive menu'
        Assert-Equal -Expected 0 -Actual $stub.ChangeCalls -Because 'no answer was sent, so nothing may be confirmed'
    }

    It 'still answers the same parked console when no screen is declared' {
        # Without the declaration the behavior is unchanged, so the guard adds a
        # refusal rather than narrowing the recovery everywhere else.
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleText = $script:LanguageMenu
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $true -Actual $result
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count
    }

    It 'answers normally when the declared screen is not the one on console' {
        $stub = Reset-BlindState
        $ctx = Get-BlindContext -Step @{
            text = 'yes'; blindAfterSeconds = 120; blindSkipPattern = 'Bahasa Indonesia'
        }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $true -Actual $result -Because 'the scrolled-away prompt is still the case this exists for'
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count
    }

    It 'accepts a list of screens' {
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleText = $script:LanguageMenu
        $ctx = Get-BlindContext -Step @{
            text = 'yes'; blindAfterSeconds = 120
            blindSkipPattern = @('GNU GRUB', 'Bahasa Indonesia')
        }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result
        Assert-Equal -Expected 0 -Actual $stub.Typed.Count
    }
}

Describe 'Invoke-BlindAnswer answers a parked console and requires proof' {
    It 'types the answer once and reports success when the console moves on' {
        $stub = Reset-BlindState
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $true -Actual $result -Because 'the console moving again is the answer being consumed'
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count -Because 'the answer is sent once, not repeated'
        Assert-Equal -Expected 'yes' -Actual $stub.Typed[0]
        Assert-Equal -Expected 'start: subiquity/Network/_send_update: CHANGE eth0' -Actual $stub.ChangeBaseline `
            -Because 'the screen as it stood before the answer is what the change is measured against'
    }

    It 'reports failure when nothing on the console changes' {
        # Sent-but-unconsumed is not success: the step must go on to fail on its
        # own terms rather than report an answer nothing received.
        $stub = Reset-BlindState
        $stub.ChangeOk = $false
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count
    }

    It 'does not blame the guest when the console could not be read' {
        # $false covers two opposite consoles. Saying the answer "was not what the
        # guest was waiting for" is a claim about the guest, and a confirmation
        # that read no frame at all is in no position to make it -- it sends the
        # reader of this log after the guest instead of after the capture path.
        $stub = Reset-BlindState
        $stub.ChangeOk = $false
        $stub.ChangeVerdict.Readable = $false
        $stub.ChangeVerdict.Reads    = 0
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $warnings = $null
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?') `
            -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $result -Because 'unconfirmed is still not success'
        $text = ($warnings | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($text -match 'could not be read') "the warning must name the reader as the thing that failed; got: $text"
        Assert-True ($text -notmatch 'not what the guest was waiting for') `
            "an unreadable console proves nothing about what the guest wanted; got: $text"
    }

    It 'does blame the answer when a readable console held still' {
        # The other side of the same contract: where the reader worked, a console
        # that never moved IS evidence, and the wording has to keep saying so.
        $stub = Reset-BlindState
        $stub.ChangeOk = $false
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $warnings = $null
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?') `
            -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $result
        $text = ($warnings | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($text -match 'not what the guest was waiting for') "a read console that held still is a real verdict; got: $text"
    }

    It 'reports failure without confirming when the answer could not be typed' {
        $stub = Reset-BlindState
        $stub.TypeOk = $false
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120 }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $false -Actual $result
        Assert-Equal -Expected 0 -Actual $stub.ChangeCalls -Because 'nothing was sent, so there is nothing to confirm'
    }

    It 'prefers an explicit confirmPattern over the console-change probe' {
        # Where a guest's next screen is known, matching it is stronger evidence
        # than "something changed".
        $stub = Reset-BlindState
        $stub.WaitResults = @($true)
        $ctx = Get-BlindContext -Step @{ text = 'yes'; blindAfterSeconds = 120; confirmPattern = 'Installing system' }
        $result = Invoke-BlindAnswerUnderTest -Context $ctx -Patterns @('Continue with autoinstall?')
        Assert-Equal -Expected $true -Actual $result
        Assert-Equal -Expected 0 -Actual $stub.ChangeCalls -Because 'the pattern replaces the change probe, it does not add to it'
        Assert-Equal -Expected 'Installing system' -Actual $stub.WaitPatterns[0][0]
    }
}

Describe 'waitForAndEnter spends its budget around the blind answer' {
    It 'answers after the first window and does not type the answer twice' {
        # The blind path has already sent the text; falling through to the normal
        # type-and-Enter tail would send it a second time, which at a prompt that
        # has moved on lands wherever the guest is reading next.
        $stub = Reset-BlindState
        $stub.WaitResults = @($false)
        $handler = (Get-SequenceAction -Name 'waitForAndEnter').Handler
        $ctx = Get-BlindContext -Step @{ pattern = 'Continue with autoinstall?'; text = 'yes'; timeoutSeconds = 900; blindAfterSeconds = 120 }
        $result = & $handler $ctx
        Assert-Equal -Expected $true -Actual $result
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count -Because 'the answer the blind path sent is the answer the step needed'
        Assert-Equal -Expected 120 -Actual $stub.WaitTimeouts[0] -Because 'the first window is blindAfterSeconds, not the whole budget'
    }

    It 'spends the rest of the budget on the wait when the answer was not warranted' {
        # A guest that is merely slow must still get the time the step allows;
        # the split budget is not a shortened one.
        $stub = Reset-BlindState
        $stub.Verdict.ConsoleStaticSeconds = 0
        $stub.WaitResults = @($false, $true)
        $handler = (Get-SequenceAction -Name 'waitForAndEnter').Handler
        $ctx = Get-BlindContext -Step @{ pattern = 'Continue with autoinstall?'; text = 'yes'; timeoutSeconds = 900; blindAfterSeconds = 120 }
        $result = & $handler $ctx
        Assert-Equal -Expected $true -Actual $result
        Assert-Equal -Expected 2 -Actual $stub.WaitTimeouts.Count -Because 'the wait resumes after the blind path declines'
        Assert-True ($stub.WaitTimeouts[1] -gt 700) `
            "the resumed wait gets what is left of the budget; got $($stub.WaitTimeouts[1])s"
        Assert-Equal -Expected 1 -Actual $stub.Typed.Count -Because 'the normal path types the answer once, after the match'
    }

    It 'runs one wait for the whole budget when blindAfterSeconds is not set' {
        # The knob is opt-in: a step without it must behave exactly as before.
        $stub = Reset-BlindState
        $stub.WaitResults = @($true)
        $handler = (Get-SequenceAction -Name 'waitForAndEnter').Handler
        $ctx = Get-BlindContext -Step @{ pattern = 'login:'; text = 'yes'; timeoutSeconds = 900 }
        $result = & $handler $ctx
        Assert-Equal -Expected $true -Actual $result
        Assert-Equal -Expected 1 -Actual $stub.WaitTimeouts.Count
        Assert-Equal -Expected 900 -Actual $stub.WaitTimeouts[0]
    }
}
