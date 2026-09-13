<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42d41f07-9c3b-4a15-8e62-5b0f3ca9d7e1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos tcc permission accessibility screen-recording pester
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
    Pester coverage for the macOS permissions only an operator can grant: the
    registry that describes them, the single renderer that explains them, and
    the two gates that must never disagree about either.
.DESCRIPTION
    Accessibility, Screen Recording and Automation are held by the terminal
    application and cannot be granted by any script, root included. Two things
    then decide what an operator's morning looks like.

    The first is WHERE they are checked. The pre-cycle config gate and the
    per-cycle assertion are different entry points, and a grant enforced only by
    the second is discovered after the gate has already said the host is ready --
    with a runner waiting, from a message the gate never showed. So the cases
    below pin that the gate walks the WHOLE registry rather than a hand-picked
    subset, and that every Id the runner gates on is in it.

    The second is WHAT they are told. Instructions maintained in two places
    drift, and an operator who follows one set and is refused by the other has
    no way to tell which is stale. So the cases pin that both consumers render
    from Get-MacOperatorGrantInstruction and that neither carries pane wording
    of its own.

    Throw-based assertions (no Should), so the file runs standalone. The
    registry and the renderer are pure text decisions, which is why they can be
    exercised off a Mac; anything that would need a real TCC answer is skipped
    there and says so.
    Run: pwsh -NoProfile -File test/modules/Test.MacOperatorGrant.Tests.ps1
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Mac.psm1') -Force -DisableNameChecking

    $script:MacModulePath   = Join-Path $here 'Test.HostCondition.Mac.psm1'
    $script:TestConfigPath  = Join-Path $repoRoot 'test/Test-Config.ps1'
    $script:TestConfigText  = Get-Content -LiteralPath $script:TestConfigPath -Raw
}

Describe 'the operator-grant registry' {
    It 'describes every field a consumer renders from' {
        $grants = @(Get-MacOperatorGrant)
        Assert-True ($grants.Count -ge 3) "expected the three macOS grants, got $($grants.Count)"
        foreach ($g in $grants) {
            foreach ($field in 'Id', 'Title', 'Pane', 'DeepLink', 'Why', 'EnableStep', 'Relaunch') {
                Assert-True ([bool]"$($g.$field)".Trim()) "grant '$($g.Id)' has no $field, so its instructions would render a blank"
            }
            Assert-Match '^x-apple\.systempreferences:' $g.DeepLink `
                "grant '$($g.Id)' needs a pane URL: the shortcut is what turns 'go find this setting' into a window already on the right row"
            Assert-True ($g.Relaunch -in 'always', 'if-still-denied') `
                "grant '$($g.Id)' has an unrecognized Relaunch value '$($g.Relaunch)'; the renderer decides its wording from it"
        }
    }

    It 'gives every BLOCKING grant a probe that does not prompt' {
        # A blocking grant with no probe can never be satisfied: the gate has no
        # way to observe the fix, so the operator does the work and is refused
        # anyway. Whatever cannot be read without raising a dialog has to be
        # non-blocking, which is the trade the Automation entry makes.
        foreach ($g in @(Get-MacOperatorGrant)) {
            if ($g.Blocking) {
                Assert-NotNull $g.Probe "grant '$($g.Id)' blocks a cycle but cannot be read, so nothing an operator does would clear it"
            }
        }
    }

    It 'reports the skip variable as an override rather than as a grant' {
        $sr = @(Get-MacOperatorGrant -Id 'ScreenRecording')[0]
        $saved = [Environment]::GetEnvironmentVariable($sr.SkipEnvVar)
        try {
            [Environment]::SetEnvironmentVariable($sr.SkipEnvVar, '1')
            $state = @(Get-MacOperatorGrantState -Id 'ScreenRecording')[0]
            Assert-StringEqual 'overridden' $state.State `
                'a forced check has to stay distinguishable from a real grant, or the report claims a permission the host does not have'
        } finally {
            [Environment]::SetEnvironmentVariable($sr.SkipEnvVar, $saved)
        }
    }
}

Describe 'the instruction renderer' {
    It 'names the pane, the shortcut and the application to enable' {
        foreach ($g in @(Get-MacOperatorGrant)) {
            $full = (Get-MacOperatorGrantInstruction -Grant $g) -join "`n"
            Assert-Match ([regex]::Escape($g.Pane))     $full "grant '$($g.Id)': the instructions must say where the setting lives"
            Assert-Match ([regex]::Escape($g.DeepLink)) $full "grant '$($g.Id)': the instructions must carry the pane shortcut"
            Assert-Match 'NOT pwsh|no \+ button' $full `
                "grant '$($g.Id)': the instructions must steer the operator away from listing the shell -- macOS attributes the request to the terminal, so a pwsh entry grants nothing"
        }
    }

    It 'does not claim an unprobed grant is missing' {
        # The Automation entry is reported, never read. A headline asserting it
        # is not granted would be a claim this code cannot support, and an
        # operator who checks the pane and finds it already on stops believing
        # the rest of the report.
        $auto = @(Get-MacOperatorGrant | Where-Object { -not $_.Probe })[0]
        Assert-NotNull $auto 'expected at least one grant that cannot be read without prompting'
        $head = (Get-MacOperatorGrantInstruction -Grant $auto)[0]
        Assert-True ($head -notmatch 'is NOT granted') "an unread grant must not be reported as denied: '$head'"
    }

    It 'keeps the compact form self-contained' {
        # The config gate's FAIL rows carry one string into the end-of-run
        # summary. A compact line that points at the long form leaves the
        # operator reading a summary that tells them to scroll.
        foreach ($g in @(Get-MacOperatorGrant)) {
            $compact = @(Get-MacOperatorGrantInstruction -Grant $g -Compact)
            Assert-Equal 1 $compact.Count "grant '$($g.Id)': the compact form has to be exactly one line"
            Assert-Match ([regex]::Escape($g.Pane)) $compact[0] "grant '$($g.Id)': the compact line still has to name the pane"
        }
    }
}

Describe 'the terminal-application hint' {
    It 'never tells the operator to enable pwsh' {
        $saved = $env:TERM_PROGRAM
        try {
            foreach ($case in @{ In = 'Apple_Terminal'; Out = 'Terminal.app' },
                              @{ In = 'iTerm.app';      Out = 'iTerm.app' },
                              @{ In = 'ghostty';        Out = 'Ghostty' }) {
                $env:TERM_PROGRAM = $case.In
                Assert-StringEqual $case.Out (Get-MacTccSubjectName) "TERM_PROGRAM '$($case.In)' mapped to the wrong application"
            }
            $env:TERM_PROGRAM = ''
            Assert-True ((Get-MacTccSubjectName) -notmatch 'pwsh') 'the fallback must not name the shell'
        } finally {
            $env:TERM_PROGRAM = $saved
        }
    }
}

Describe 'the pre-cycle gate and the per-cycle assertion' {
    It 'both render from the one instruction source' {
        $macText = Get-Content -LiteralPath $script:MacModulePath -Raw
        Assert-Match 'Get-MacOperatorGrantInstruction' $script:TestConfigText `
            'Test-Config must print the shared instructions, not wording of its own'
        Assert-Match 'Get-MacOperatorGrantInstruction' $macText `
            'the per-cycle assertion must print the shared instructions'
    }

    It 'keeps pane wording out of the consumers' {
        # The drift this prevents is silent: a pane renamed in one file and not
        # the other leaves two sets of instructions that are each internally
        # plausible.
        $paneWording = @(Get-MacOperatorGrant | ForEach-Object { $_.Pane })
        foreach ($pane in $paneWording) {
            $hits = @([regex]::Matches($script:TestConfigText, [regex]::Escape($pane))).Count
            Assert-Equal 0 $hits "Test-Config spells out '$pane' itself instead of rendering it from the registry"
        }
    }

    It 'walks the whole registry rather than a hand-picked subset' {
        # A grant added to the registry has to start being reported by the gate
        # without anyone remembering to add it here too -- otherwise the next
        # permission repeats exactly this bug: enforced by the runner, invisible
        # to the gate that runs first.
        Assert-Match 'foreach\s*\(\s*\$\w+\s+in\s+Get-MacOperatorGrantState\s*\)' $script:TestConfigText `
            'the gate must iterate every grant the registry declares'
    }

    It 'gates on Ids the registry actually declares' {
        $macText = Get-Content -LiteralPath $script:MacModulePath -Raw
        $ids = @(Get-MacOperatorGrant).Id
        $asserted = @([regex]::Matches($macText, "Assert-MacOperatorGrant -Id '([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }) | Select-Object -Unique
        Assert-True ($asserted.Count -ge 2) 'expected the runner to gate on at least Accessibility and Screen Recording'
        foreach ($id in $asserted) {
            Assert-True ($ids -contains $id) "the runner gates on '$id', which no registry entry declares -- the gate would silently pass it"
        }
    }
}

Describe 'the host-settings sweep' {
    It 'requests the grants and counts what is still missing' {
        $body = (Get-YurunaTestFunctionAst -Path $script:MacModulePath -Name 'Set-MacHostConditionSet').Extent.Text
        Assert-Match 'Invoke-MacOperatorGrantAssist' $body `
            'Enable-TestAutomation is where an operator is present, so it is where the dialogs get raised'
        Assert-Match 'unmet\.Add' $body `
            'a grant still missing afterwards has to raise the unmet count, or the script exits 0 on a host that cannot run a cycle'
    }

    It 'waits for a click only where somebody can click' {
        # The wait is what turns "run it again to see if it worked" into a
        # confirmed grant. Ungated, it would stall an unattended install for the
        # full timeout per grant on a host where nobody is going to answer.
        $body = (Get-YurunaTestFunctionAst -Path $script:MacModulePath -Name 'Invoke-MacOperatorGrantAssist').Extent.Text
        Assert-Match 'Test-YurunaCanPrompt' $body 'the re-probe loop has to be gated on a reachable operator'
        Assert-Match 'Get-MacSessionKind' $body 'a remote session can neither hold the grant nor raise its dialog, and has to be told so'
    }
}
