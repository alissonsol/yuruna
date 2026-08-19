<#PSScriptInfo
.VERSION 2026.08.19
.GUID 427227f6-5537-49d8-bd74-b53ec39ba8f9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence break pester
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
    Structural Pester guard on the `break` action handler in
    Test.SequenceHandler.psm1: snapshot-restore-on-Continue must stay gated
    behind the opt-in `restoreOnContinue` flag.
.DESCRIPTION
    A plain breakpoint pauses and resumes in place. The step's `id` is a pure
    label and must NOT trigger Restore-VMDiskSnapshot + Start-VM on Continue --
    a break id legitimately matches a real snapshot name (the workload's
    requiresSnapshot / loadDiskSnapshot id) without meaning "rewind". The
    restore path is opt-in via `restoreOnContinue: true`.

    This test parses the module (no host I/O), isolates the break handler's
    scriptblock, and asserts the Restore-VMDiskSnapshot call is lexically nested
    inside an `if` whose condition references $restoreOnContinue. AST-only, so it
    runs under OS-bundled Pester 3.4 / Pester 5+ with throw-based assertions.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$script:modulePath = Join-Path $here 'Test.SequenceHandler.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Argument expression following a named parameter on a command call, handling
# both `-P arg` (space) and `-P:arg` (colon) forms.
function Get-NamedArg {
    param([System.Management.Automation.Language.CommandAst]$Call, [string]$Name)
    $els = $Call.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq $Name) {
            if ($el.Argument) { return $el.Argument }
            if ($i + 1 -lt $els.Count) { return $els[$i + 1] }
        }
    }
    return $null
}

# The scriptblock passed to Register-SequenceAction -Name 'break' -Handler { ... }.
function Get-BreakHandlerScriptBlockAst {
    param([string]$Path)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }

    $regs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-SequenceAction'
    }, $true)
    foreach ($call in $regs) {
        $nameArg = Get-NamedArg -Call $call -Name 'Name'
        if ($nameArg -and ($nameArg.Extent.Text.Trim("'`"") -eq 'break')) {
            $handler = Get-NamedArg -Call $call -Name 'Handler'
            if ($handler -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $handler }
        }
    }
    throw "break handler scriptblock not found in $Path"
}

# The scriptblock passed to Register-SequenceAction -Name '<action>' -Handler { ... }.
# Declared above every Describe: file-level code only executes as far as the
# first Describe on the run pass, so a helper defined after one is never
# redefined for the run and is unresolvable from an It body.
function Get-HandlerScriptBlockAst {
    param([string]$Path, [string]$Name)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    $regs = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-SequenceAction'
        }, $true)
    foreach ($call in $regs) {
        $nameArg = Get-NamedArg -Call $call -Name 'Name'
        if ($nameArg -and ($nameArg.Extent.Text.Trim("'`"") -eq $Name)) {
            $handler = Get-NamedArg -Call $call -Name 'Handler'
            if ($handler -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $handler }
        }
    }
    throw "$Name handler scriptblock not found in $Path"
}

# The 'type text -> drain N seconds -> press Enter' tail is shared by the
# single Invoke-TypeDrainEnter helper. A Describe body is evaluated during
# the discovery pass and its scope is discarded before any It runs, so this list
# must be declared at file scope to reach the assertions.
$script:typeDrainEnterVerbs = @('inputTextAndEnter', 'waitForAndEnter', 'passwdPrompt', 'fetchAndExecute')

}

Describe 'break handler gates snapshot-restore behind restoreOnContinue' {
    It 'reads the restoreOnContinue flag from the step' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $script:modulePath
        Assert-True ($handler.Extent.Text -match 'restoreOnContinue') 'handler must consult restoreOnContinue'
    }

    It 'calls Restore-VMDiskSnapshot only inside an if ($restoreOnContinue ...) block' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $script:modulePath
        $restoreCalls = $handler.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restore-VMDiskSnapshot'
        }, $true)
        Assert-True (@($restoreCalls).Count -ge 1) 'expected a Restore-VMDiskSnapshot call to guard'

        foreach ($call in $restoreCalls) {
            $gated = $false
            $node = $call.Parent
            while ($node -and -not ($node -is [System.Management.Automation.Language.ScriptBlockAst] -and $node.Parent -eq $handler)) {
                if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $node.Clauses) {
                        if ($clause.Item1.Extent.Text -match 'restoreOnContinue') { $gated = $true }
                    }
                }
                $node = $node.Parent
            }
            Assert-True $gated "Restore-VMDiskSnapshot at $($call.Extent.StartLineNumber) is not gated by an if referencing restoreOnContinue."
        }
    }
}

Describe 'break handler bounds the wait with an optional wall-clock deadline' {
    It 'consults step.timeoutSeconds / YURUNA_BREAK_MAX_SECONDS and a UtcNow deadline' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $script:modulePath
        $t = $handler.Extent.Text
        Assert-True ($t -match 'YURUNA_BREAK_MAX_SECONDS') 'handler must consult the global break-max env var'
        Assert-True ($t -match 'timeoutSeconds')           'handler must consult step.timeoutSeconds'
        Assert-True ($t -match '\[DateTime\]::UtcNow')     'handler must bound the wait with a UtcNow wall-clock deadline'
    }
    It 'auto-resumes in place on timeout (resumedVia = timeout, so the restore path is skipped)' {
        $handler = Get-BreakHandlerScriptBlockAst -Path $script:modulePath
        Assert-True ($handler.Extent.Text -match "resumedVia\s*=\s*'timeout'") 'a timeout must set resumedVia=timeout (the restore path only fires on continue-button)'
    }
    It 'parses the timeout defensively so a non-numeric value cannot throw and abort the cycle' {
        # The [int] conversion of the (operator-typo-prone, schema-unconstrained)
        # break timeout must sit in a try so a bad value defaults to unbounded
        # rather than escaping the break's soft/return-$false envelope.
        $handler = Get-BreakHandlerScriptBlockAst -Path $script:modulePath
        Assert-True ($handler.Extent.Text -match 'try\s*\{\s*\$breakMaxSeconds\s*=\s*\[int\]') 'the break-timeout [int] parse must be inside a try/catch'
    }
}

Describe 'recoverFromSnapshot log interpolates the failed-step number correctly' {
    It 'wraps LastFailedStepNumber in a subexpression so it is not rendered as literal text' {
        # A bare "$script:Fail.LastFailedStepNumber" in a double-quoted string
        # interpolates only $script:Fail (the hashtable) and appends the literal
        # ".LastFailedStepNumber"; the subexpression $(...) renders the member.
        $src = Get-Content -Raw -LiteralPath $script:modulePath
        Assert-True ($src -match '\$\(\$script:Fail\.LastFailedStepNumber\)') 'the log must use $($script:Fail.LastFailedStepNumber)'
    }
}

Describe 'type-then-Enter verbs share Invoke-TypeDrainEnter (dedup)' {
    # These guard against re-duplication of the type-then-Enter tail and pin the
    # one security-relevant divergence: passwdPrompt types the password LITERALLY
    # (no -ShellEscape), while the command/text verbs shell-escape.
    It 'defines the shared Invoke-TypeDrainEnter helper' {
        $src = Get-Content -Raw -LiteralPath $script:modulePath
        Assert-True ($src -match 'function Invoke-TypeDrainEnter') 'Invoke-TypeDrainEnter must be defined'
    }
    It 'each type-then-Enter verb delegates its tail to Invoke-TypeDrainEnter with no inline drain loop' {
        foreach ($name in $script:typeDrainEnterVerbs) {
            $h = Get-HandlerScriptBlockAst -Path $script:modulePath -Name $name
            $calls = @($h.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-TypeDrainEnter' }, $true))
            Assert-True ($calls.Count -eq 1) "$name must call Invoke-TypeDrainEnter exactly once (found $($calls.Count))"
            Assert-True ($h.Extent.Text -notmatch 'Write-ProgressTick') "$name must not retain an inline drain loop (Write-ProgressTick moved into the helper)"
        }
    }
    It 'passwdPrompt types the password literally (no -ShellEscape); command/text verbs shell-escape' {
        $pw = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'passwdPrompt'
        $pwCall = @($pw.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-TypeDrainEnter' }, $true))[0]
        Assert-True ($pwCall.Extent.Text -notmatch '-ShellEscape') 'passwdPrompt must NOT pass -ShellEscape (the password types literally)'
        foreach ($name in 'inputTextAndEnter', 'waitForAndEnter', 'fetchAndExecute') {
            $h = Get-HandlerScriptBlockAst -Path $script:modulePath -Name $name
            $call = @($h.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-TypeDrainEnter' }, $true))[0]
            Assert-True ($call.Extent.Text -match '-ShellEscape') "$name must pass -ShellEscape"
        }
    }
}

Describe 'Test-GuestPayloadUnavailable (did anything actually run?)' {

    BeforeAll { Import-Module $script:modulePath -Force -DisableNameChecking }

    It 'recognizes the shortages where no source served the script' {
        foreach ($reason in '(no fetch source)', '(fetch failed, wget exit 8)', '(could not create temp file)') {
            $out = "`n    NONZERO SCRIPT EXIT:`n    project/poc/test/x.sh $reason`n"
            Assert-True (Test-GuestPayloadUnavailable -Output $out) "must recognize $reason"
        }
    }

    It 'does NOT claim a payload was missing when the script ran and failed' {
        # This is the case script_error is actually for. Treating it as a shortage
        # would route every genuine guest-script failure to a retry of a command
        # already known to fail.
        $out = "`n    NONZERO SCRIPT EXIT:`n    project/poc/test/x.sh (exit 3)`n"
        Assert-True (-not (Test-GuestPayloadUnavailable -Output $out)) 'a real non-zero script exit is not a missing payload'
    }

    It 'does NOT treat an integrity refusal as a retryable shortage' {
        # Nothing ran here either, but the bytes served did not match the digest
        # the host published. A retry is the one answer that must not be offered.
        $out = "`n    NONZERO SCRIPT EXIT:`n    project/poc/test/x.sh (integrity mismatch -- refusing to run)`n"
        Assert-True (-not (Test-GuestPayloadUnavailable -Output $out)) 'a digest mismatch must not be retried'
    }

    It 'requires the sentinel, so ordinary output mentioning a reason cannot trigger it' {
        Assert-True (-not (Test-GuestPayloadUnavailable -Output 'installing (no fetch source) helper')) 'the sentinel gates the match'
        Assert-True (-not (Test-GuestPayloadUnavailable -Output '')) 'empty output is not a verdict'
        Assert-True (-not (Test-GuestPayloadUnavailable -Output $null)) 'no output is not a verdict'
    }
}
