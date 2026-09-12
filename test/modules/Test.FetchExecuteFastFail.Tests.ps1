<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42746513-f859-4478-b773-07a4c13848b4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence fetchandexecute console keystroke pester
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
    Guards the fast-fail that stands between a console-typed fetchAndExecute
    command and a full timeout spent waiting for a completion marker that can
    never arrive.
.DESCRIPTION
    A fetchAndExecute command line is delivered one key event per character
    into a guest whose input layer can drop and reorder them. When that
    damages the command word, bash answers "No such file or directory" in
    about a second and nothing else ever happens -- no wrapper, no script, no
    sentinel, no marker. The wait, seeing only the absence of its marker, has
    no reason to stop before its deadline.

    The guard is the shell's own refusal, read for the first seconds after
    Enter and only then. The window is the whole design: those same strings
    are routine output from a healthy script, so as permanent anti-patterns
    they would abort good runs.

    Reading the console echo BEFORE Enter looks like the more complete answer
    and is not available: the verdict that would have to judge it reports
    'corrupt' on healthy Hyper-V and UTM consoles, so gating submission on it
    fails runs that were fine. What the guest says after Enter is evidence
    about the guest; what OCR says about a console echo is mostly evidence
    about OCR.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.FetchExecuteFastFail.Tests.ps1
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$handlerPsm = Join-Path $here 'Test.SequenceHandler.psm1'
$enginePsm  = Join-Path $here 'Test.SequenceEngine.psm1'

Import-Module (Join-Path $here 'Test.OcrMatch.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Fixtures live at file scope: a Describe body runs during discovery and its
# variables are gone before any It executes.

$script:handlerText = Get-Content -Raw $handlerPsm
$script:engineText  = Get-Content -Raw $enginePsm
$script:schemaText  = Get-Content -Raw (Join-Path (Split-Path -Parent $here) 'schemas/sequence.schema.yml')

# A captured console after the transport damaged the command word in flight:
# the three characters of 'lib' arrived after the eight that should have
# followed them, and 'fetc' never arrived at all, so what bash was handed was
# '/usr/local/yuruna//libh-and-execute.sh'. Everything else -- the envelope,
# the payload argument -- landed intact. Reproduced ASCII-only; the OCR of a
# real frame also invents non-ASCII glyphs that cannot live in a source file,
# and none of them fall in the region these assertions read.
$script:RejectedEcho = @'
amisad-build-admin@amisad-build:~$ EXEC_REQUIRE_SHA256=1 E_SHA=a2bcd14a931f2b73 E_RETRY_SHA=59e0118a59c56486
E_FB_REPO=alissonsol/yuruna E_FB_REF=7eab4ead7f5d /usr/local/yuruna//libh-and-execute.sh guest/ubuntu.server.24/
ubuntu.server.24.update.sh
-bash: /usr/local/yuruna//libh-and-execute.sh: No such file or directory
amisad-build-admin@amisad-build:~$
'@

# The same step going well: the command echoes, the wrapper announces the
# fetch, and the payload starts talking. Nothing here may trip a fast-fail.
$script:HealthyEcho = @'
amisad-build-admin@amisad-build:~$ EXEC_REQUIRE_SHA256=1 E_SHA=a2bcd14a931f2b73 E_RETRY_SHA=59e0118a59c56486
E_FB_REPO=alissonsol/yuruna E_FB_REF=7eab4ead7f5d /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/
ubuntu.server.24.update.sh
FETCHING: guest/ubuntu.server.24/ubuntu.server.24.update.sh
Get:1 http://archive.ubuntu.com/ubuntu noble InRelease [256 kB]
Reading package lists... Done
'@

# A healthy step several seconds in, doing the loudest thing a step does: a
# container build restoring web assets. Nothing here is a shell refusal, and
# the shell that would have issued one accepted its command line long ago.
#
# This screen is kept verbatim because it, and not merely a screen of its
# size, satisfies "No such file or directory" through the matcher's unbounded
# strategy -- the one asking only whether each word of the pattern turns up
# SOMEWHERE. Normalization folds each word to a short token, and the tokens
# are then supplied by text that has nothing to do with any of the words:
# 'No' by a run of hex inside a sha256 digest, 'such' by a line OCR garbled
# beyond reading, 'file' by "profile", 'or' by "WORKDIR", and only
# 'directory' by an actual directory. Thin out any of those five and the
# coincidence stops reproducing, which is the point -- it never needed a
# screen that said anything like the pattern.
#
# Reproduced ASCII-only, garbled line included: that line is what a real
# frame's noise looks like, and it is load-bearing here.
$script:BuildFloodEcho = @'
#4 transferring context: 359B done
#4 DONE 0.0s
#S WehsrenLidrcdteald opzboxd une
#5 DONE 0.0s
#6 [base 1/2] FROM localhost:5000/dotnet/aspnet:10.0@sha256:7fdba0abo2ebda03988f15a5ec83873f9504lebd51ae1dd4aed1daad
#6 DONE 0.1s
#8 [base 2/2] WORKDIR /app
#8 DONE 0.7s
#15 [build 7/9] RUN dotnet tool install -g Microsoft.Web.LibraryManager.Cli
#15 1.292 Tools directory '/root/.dotnet/tools' is not currently on the PATH environment variable.
#15 1.292 If you are using bash, you can add it to your profile by running the following command:
#15 1.293 Tool 'microsoft.web.librarymanager.cli' (version '3.0.114') was successfully installed.
#16 [build 8/9] RUN ~/.dotnet/tools/libman restore
#16 0.689 Restoring library twitter-bootstrap@5.3.8...
#16 0.695 Downloading file https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.8/css/bootstrap-grid.css...
#16 0.696 Downloading file https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.8/css/bootstrap-grid.min.css...
#16 0.797 Downloading file https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/5.3.8/css/bootstrap-reboot.min.css...
'@

# The fetchAndExecute branch of the step schema, isolated from its neighbors so
# a field declared on a different action cannot satisfy an assertion here.
$m = [regex]::Match($script:schemaText, '(?s)const:\s*fetchAndExecute\b(.*?)(?=\n      - if:)')
$script:schemaFetchBranch = if ($m.Success) { $m.Groups[1].Value } else { '' }

# Wait-ForText's signature read from the engine source rather than from a
# loaded command, so the assertion holds without importing the engine and the
# host I/O it expects.
$waitAst = ([System.Management.Automation.Language.Parser]::ParseFile($enginePsm, [ref]$null, [ref]$null)).FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ForText' }, $true) |
    Select-Object -First 1
$script:waitForTextParams = if ($waitAst) {
    @($waitAst.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
} else { @() }
}

Describe 'Shell-rejection fast-fail: the captured failure' {

    It 'matches the shell refusal on the frame the transport actually produced' {
        # The anchor of this file. If this stops matching, a damaged command
        # word goes back to costing the step its entire timeout.
        Assert-True (Test-OCRMatch -Text $script:RejectedEcho -Pattern 'No such file or directory') `
            'The shell refusing the typed command must be readable on the console frame.'
    }

    It 'is the signal the wrapper sentinel cannot give' {
        # The pre-existing fast-fail is printed BY the wrapper, so it proves
        # the wrapper ran. On this frame nothing ran, which is exactly why a
        # second, differently-sourced signal has to exist.
        Assert-True (-not (Test-OCRMatch -Text $script:RejectedEcho -Pattern 'NONZERO SCRIPT EXIT:')) `
            'A command the shell never started cannot print the wrapper sentinel.'
    }

    It 'stays silent on a healthy fetch' {
        foreach ($p in @('No such file or directory', 'command not found')) {
            Assert-True (-not (Test-OCRMatch -Text $script:HealthyEcho -Pattern $p)) `
                "A healthy console must not match the shell-rejection pattern '$p'."
        }
    }

    It 'stays silent on a healthy step whose own output is dense' {
        # The anti-pattern side of the anchor above. A step that reaches a
        # noisy build inside the window must not have its own output read as
        # the shell refusing to start it: the run was working, and a match
        # here ends it as a hard failure with the guest still building.
        foreach ($p in @('No such file or directory', 'command not found')) {
            Assert-True (-not (Test-OCRMatch -Text $script:BuildFloodEcho -Pattern $p -NoSegmentMatch)) `
                "A healthy build screen must not read as the shell refusal '$p'."
        }
    }

    It 'reads the refusal off one line rather than off the whole screen' {
        # Why the strategy is dropped rather than the pattern retuned: the
        # evidence a shell refusal leaves is one contiguous line, so the
        # bounded strategies lose nothing, while the unbounded one is the only
        # thing that can answer yes to a screen that never said it.
        Assert-True (Test-OCRMatch -Text $script:RejectedEcho -Pattern 'No such file or directory' -NoSegmentMatch) `
            'The refusal must still match when only the line-bounded strategies are allowed.'
        Assert-True (Test-OCRMatch -Text $script:BuildFloodEcho -Pattern 'No such file or directory') `
            'Without the restriction the same screen matches -- which is the reason the restriction exists.'
    }

    It 'matches the early set with the unbounded strategy disabled' {
        # The wiring, in the engine, where the early set is consulted.
        Assert-True ($script:engineText -match '-NoSegmentMatch:') `
            'The anti-pattern check must pass -NoSegmentMatch for the early set.'
    }

    It 'carries both of the shell refusals' {
        $decl = [regex]::Match($script:handlerText, '(?s)\$script:ShellRejectedCommandPattern\s*=\s*@\((.*?)\)')
        Assert-True $decl.Success 'The shell-rejection set is declared as one named constant.'
        foreach ($p in @('command not found', 'No such file or directory')) {
            Assert-True ($decl.Groups[1].Value.Contains($p)) "The set must carry '$p'."
        }
    }
}

Describe 'Shell-rejection fast-fail: the window' {

    It 'gives Wait-ForText a separate, time-bounded anti-pattern channel' {
        # A parsed signature, not a text search: the handler passes these by
        # name, so a rename that broke the pair would fail here first.
        Assert-True ($script:waitForTextParams.Count -gt 0) 'Wait-ForText is parseable from the engine source.'
        foreach ($name in @('EarlyFailurePattern', 'EarlyFailureSeconds')) {
            Assert-True ($script:waitForTextParams -contains $name) "Wait-ForText must accept -$name."
        }
    }

    It 'consults the early set only while the window is open' {
        # The gate itself. Without the elapsed comparison the strings become
        # permanent anti-patterns and a healthy script printing either one
        # kills its own step.
        Assert-True ($script:engineText -match '\$EarlyFailurePattern\.Count -gt 0 -and \$elapsed -le \$EarlyFailureSeconds') `
            'The early anti-patterns must be gated on elapsed time inside the poll loop.'
    }

    It 'bounds the window to seconds, not to the wait' {
        $decl = [regex]::Match($script:handlerText, '\$script:ShellRejectionWindowSeconds\s*=\s*(\d+)')
        Assert-True $decl.Success 'The window is a named constant.'
        $seconds = [int]$decl.Groups[1].Value
        Assert-True ($seconds -gt 0 -and $seconds -le 60) `
            "The window must be long enough for several OCR polls and far short of a payload run; got ${seconds}s."
    }

    It 'keeps the shell-rejection set out of the overridable failure patterns' {
        # A step overriding failurePatterns is saying something about its own
        # script. It must not thereby give up the harness reading whether the
        # command line was accepted at all.
        Assert-True ($script:handlerText -match '-EarlyFailurePattern \$script:ShellRejectedCommandPattern') `
            'The rejection set reaches Wait-ForText through the early channel.'
        Assert-True (-not ($script:handlerText -match '\$failPatterns\s*=\s*@\(\$script:ShellRejectedCommandPattern')) `
            'The rejection set must not be merged into the step-overridable failure patterns.'
    }
}

Describe 'The typed line is submitted unconditionally' {

    It 'gates Enter on nothing but the keystrokes having been sent' {
        # Reading the echo back and refusing to submit on a bad verdict fails
        # healthy runs on every host whose console the verdict misreads, which
        # is most of them. The type-drain-Enter path therefore holds no
        # screen-state check at all, and this pins that.
        $body = [regex]::Match($script:handlerText, '(?s)function Invoke-TypeDrainEnter \{(.*?)\n\}')
        Assert-True $body.Success 'Invoke-TypeDrainEnter is locatable.'
        foreach ($forbidden in @('EchoVerdict', 'VerifyEcho', 'CtrlU')) {
            Assert-True (-not ($body.Groups[1].Value -match $forbidden)) `
                "The typing path must not branch on '$forbidden'; submission is not conditional on a screen read."
        }
    }
}

Describe 'failurePatterns on fetchAndExecute' {

    It 'reads the same field name every other pattern-bearing verb reads' {
        Assert-True ($script:handlerText -match '\$rawFail\s*=\s*\$c\.Step\.failurePatterns') `
            'The verb reads Step.failurePatterns.'
        Assert-True (-not ($script:handlerText -match '\$c\.Step\.failPattern\b')) `
            'The singular spelling, which no schema branch ever declared, is gone.'
    }

    It 'accepts a bare string as well as an array' {
        # patternOrArray is what every other verb accepts; a verb that took
        # only one of the two shapes would make the schema mean two things.
        Assert-True ($script:handlerText -match '(?s)\$rawFail -is \[System\.Collections\.IEnumerable\] -and \$rawFail -isnot \[string\]') `
            'Both the string and the array shape are expanded.'
    }

    It 'is declared on the fetchAndExecute schema branch' {
        Assert-True ($script:schemaFetchBranch.Length -gt 0) 'The fetchAndExecute branch is locatable in the schema.'
        Assert-True ($script:schemaFetchBranch -match 'failurePatterns') `
            'An overridable field the verb honors must be declared where sequence authors look for it.'
        Assert-True ($script:schemaFetchBranch -match 'patternOrArray') `
            'It is declared with the shared pattern-or-array shape.'
    }
}
