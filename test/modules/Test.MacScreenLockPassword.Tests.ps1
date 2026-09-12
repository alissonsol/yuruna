<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42e93b58-71a4-4c60-b3d7-2f8a1e604c93
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos sysadminctl screenlock password pester
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
    The macOS account password that `sysadminctl -screenLock` demands is never
    typed where it can be seen, and never placed where it can be read.
.DESCRIPTION
    The unified screen lock is the one host setting root cannot apply: it is
    backed by a secure-keyring entry, so sysadminctl wants the ACCOUNT password
    on top of sudo. `-password -` makes it read that password from stdin with a
    plain stream read -- no tcsetattr, so nothing turns terminal echo off. Hand
    that prompt to a person and they watch their own password appear in the
    clear and stay in the scrollback, and in any transcript of the run.

    Two shapes are wrong and both are the obvious thing to write:

      * letting a human answer sysadminctl's prompt (visible on screen);
      * passing `-password <plaintext>` (visible in `ps` to every account on
        the machine, for as long as the call runs).

    The shape that is neither is a masked read piped into the stdin sysadminctl
    is already reading, which is what Set-MacScreenLockState does and what these
    cases pin -- including for the copy-paste command the warnings print, which
    is followed more often than the code path is taken.

    Throw-based assertions (no Should), so the file runs standalone. Everything
    here is a property of the source text and of one pure string, which is why
    it runs off a Mac.
    Run: pwsh -NoProfile -File test/modules/Test.MacScreenLockPassword.Tests.ps1
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.Mac.psm1') -Force -DisableNameChecking

    $script:MacModulePath = Join-Path $here 'Test.HostCondition.Mac.psm1'
    $script:DisablePath   = Join-Path $repoRoot 'host/macos.utm/Disable-TestAutomation.ps1'
    $script:RepoRootPath  = $repoRoot

    function Get-MacFunctionText {
        param([string]$Name)
        $fn = Get-YurunaTestFunctionAst -Path $script:MacModulePath -Name $Name
        if (-not $fn) { return '' }
        return $fn.Extent.Text
    }
}

Describe 'Set-MacScreenLockState' {
    It 'pipes the password instead of leaving sysadminctl to read the terminal' {
        $body = Get-MacFunctionText -Name 'Set-MacScreenLockState'
        Assert-Match 'Read-Host[^\r\n]*-AsSecureString' $body `
            'the password has to be read by something that masks it'
        Assert-Match '\$plain\s*\|\s*&\s*sudo' $body `
            'it has to reach sysadminctl down the pipe; an unpiped call leaves its prompt reading the tty, where every character is echoed'
    }

    It 'never puts the password in argv' {
        # `ps` is world-readable. A password on the command line is visible to
        # every account on the machine for as long as the call runs, which is a
        # wider exposure than the screen it would have replaced.
        $body = Get-MacFunctionText -Name 'Set-MacScreenLockState'
        Assert-Match "-password['\`" ]" $body 'expected the -password flag in the invocation'
        Assert-True ($body -notmatch '-password[''" ]+\$') `
            'the password is being passed as an argument, where ps would show it'
    }

    It 'cleans up the terminal and the unmanaged copy on every exit path' {
        $body = Get-MacFunctionText -Name 'Set-MacScreenLockState'
        Assert-Match 'finally' $body 'a terminal left with echo off outlives the script, so the restore cannot sit on the success path'
        Assert-Match 'stty echo' $body 'echo has to be turned back on'
        Assert-Match 'ZeroFreeBSTR' $body 'the unmanaged copy of the password has to be wiped'
        $finallyBlock = ([regex]::Match($body, '(?s)finally\s*\{(.*)\}\s*\}\s*$')).Groups[1].Value
        Assert-Match 'stty echo'    $finallyBlock 'the echo restore has to be inside the finally'
        Assert-Match 'ZeroFreeBSTR' $finallyBlock 'the wipe has to be inside the finally'
    }

    It 'reports "nobody could be asked" as its own outcome' {
        # Distinct from a refused password: one needs an operator at the
        # machine, the other needs a different password. Collapsing them sends
        # the reader to the wrong remedy.
        $saved = $env:YURUNA_NONINTERACTIVE
        try {
            $env:YURUNA_NONINTERACTIVE = '1'
            $r = Set-MacScreenLockState -State 'off'
            Assert-False $r.Attempted 'an unattended run must not claim it tried'
            Assert-Match 'person' $r.Output 'the reason has to say what is missing'
        } finally {
            $env:YURUNA_NONINTERACTIVE = $saved
        }
    }
}

Describe 'the copy-paste command the warnings print' {
    It 'reads the password invisibly and pipes it' {
        $cmd = Get-MacScreenLockManualCommand -State 'off'
        Assert-Match 'read -rs' $cmd 'the operator''s own typing has to be silent too'
        Assert-Match '\|\s*sudo sysadminctl' $cmd 'the value has to arrive on stdin, not at sysadminctl''s own prompt'
        Assert-Match 'unset ' $cmd 'the shell variable should not outlive the command'
    }

    It 'works in zsh, which is the default shell on macOS' {
        # `read -p` is the bash spelling. In zsh -p means "read from the
        # coprocess", so the bash-shaped one-liner does not fail loudly there --
        # it silently reads the wrong source. printf + `read -rs` is identical
        # in both shells.
        $cmd = Get-MacScreenLockManualCommand -State 'off'
        Assert-True ($cmd -notmatch 'read\s+-\w*p') "the printed command uses zsh-hostile 'read -p': $cmd"
        Assert-Match "printf 'macOS account password: '" $cmd 'the prompt has to come from printf so both shells show it'
    }

    It 'carries the state it was asked about' {
        Assert-Match '-screenLock 300 ' (Get-MacScreenLockManualCommand -State '300') `
            'a restore prints a delay, not a hard-coded off'
    }
}

Describe 'every caller' {
    It 'routes through the shared helper' {
        $sweep = Get-MacFunctionText -Name 'Set-MacHostConditionSet'
        Assert-Match 'Set-MacScreenLockState' $sweep 'Enable-TestAutomation''s sweep must not run sysadminctl itself'
        $disable = Get-Content -LiteralPath $script:DisablePath -Raw
        Assert-Match 'Set-MacScreenLockState' $disable 'Disable-TestAutomation must not run sysadminctl itself'
    }

    It 'leaves no unpiped sysadminctl -screenLock call anywhere in the tree' {
        # The regression is easy to reintroduce, because the unpiped form is
        # shorter and appears to work -- the password is accepted, it is merely
        # also displayed.
        #
        # Invocations, read from the AST -- not matching lines. Comment-based
        # help quotes the wrong form on purpose, and the copy-paste one-liner is
        # a string literal, so a line scan reports both and the guard gets
        # muted. A CommandAst is a thing that actually runs.
        #
        # The test for "piped" is structural: the invocation must not be the
        # first element of its pipeline. Something ahead of it in the pipeline
        # IS its stdin, which is the whole difference between a password that is
        # fed in and one that a person types at an unmasked prompt.
        $suspects = [System.Collections.Generic.List[string]]::new()
        $files = Get-ChildItem -LiteralPath $script:RepoRootPath -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](project|dev-only)[\\/]' }
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if ("$raw" -notmatch 'sysadminctl') { continue }
            try { $ast = Get-YurunaTestFileAst -Path $f.FullName } catch { continue }
            $commands = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst]
                }, $true)
            foreach ($c in $commands) {
                # The command's OWN tokens. A CommandAst's extent swallows any
                # scriptblock passed to it, so `Restore-Knob -Apply { ... }`
                # matches on whatever its body happens to mention -- prose about
                # this very trap included. String constants inside the elements
                # are collected too, or the argument-array spelling
                # (`-Argument @('sysadminctl', '-screenLock', ...)`) slips past,
                # and that is the exact shape this guard exists for.
                $tokens = [System.Collections.Generic.List[string]]::new()
                foreach ($el in $c.CommandElements) {
                    if ($el -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
                    $tokens.Add($el.Extent.Text)
                    foreach ($s in $el.FindAll({ param($n)
                                $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                            }, $true)) { $tokens.Add($s.Value) }
                }
                if ($tokens -notcontains 'sysadminctl') { continue }
                if ($tokens -notcontains '-screenLock') { continue }
                if ($tokens -notcontains '-password')   { continue }

                $pipeline = $c.Parent -as [System.Management.Automation.Language.PipelineAst]
                $fedFromPipe = $pipeline -and $pipeline.PipelineElements.Count -gt 1 -and
                               -not [object]::ReferenceEquals($pipeline.PipelineElements[0], $c)
                # Invoke-YurunaSudo -InputText feeds the child's stdin without a
                # pipeline, and is as safe as one.
                if ($fedFromPipe -or $tokens -contains '-InputText') { continue }
                $suspects.Add("$($f.Name):$($c.Extent.StartLineNumber): $(($c.Extent.Text -split "`n")[0].Trim())")
            }
        }
        Assert-Equal 0 $suspects.Count "sysadminctl is being handed -password with nothing feeding its stdin, so its prompt reads the terminal and echoes:`n  $($suspects -join "`n  ")"
    }
}
