<#PSScriptInfo
.VERSION 2026.09.30
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
    runs under Pester 5+ with throw-based assertions.
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
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restore-SequenceSnapshot'
        }, $true)
        Assert-True (@($restoreCalls).Count -ge 1) 'expected the shared snapshot restore call to guard'

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

Describe 'explicit character pacing' {
    It 'uses the default only when the step omits its delay' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-SequenceCharDelay'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        foreach ($case in @(
            @{ Step = @{}; Expected = 25 }
            @{ Step = @{ charDelayMs = 0 }; Expected = 0 }
            @{ Step = @{ charDelayMs = 7 }; Expected = 7 }
        )) {
            $actual = Resolve-SequenceCharDelay -Context @{ Step = $case.Step; DefaultCharDelayMs = 25 }
            Assert-Equal -Expected $case.Expected -Actual $actual -Because 'zero is a valid explicit delay'
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

Describe 'waitForTextWithNudge preserves one OCR deadline' {
    It 'forwards the normal wait parameters and the periodic nudge controls to Wait-ForText' {
        $handler = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'waitForTextWithNudge'
        $t = $handler.Extent.Text
        Assert-True ($t -match 'Wait-ForText') 'the action must use the ordinary wall-clock OCR wait'
        Assert-True ($t -match '-NudgeKey\s+\$nudgeKey') 'the key must reach Wait-ForText'
        Assert-True ($t -match '-NudgeIntervalSeconds\s+\$nudgeInterval') 'the interval must reach Wait-ForText'
        Assert-True ($t -match '-FailurePattern\s+\$p\.failurePatterns') 'installer crash patterns must retain fast-fail behavior'
        $answerHandler = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'waitForAndEnter'
        Assert-True ($answerHandler.Extent.Text -match 'skipInputPattern') 'a boot recovery must be able to recognize a later state without typing'
        Assert-True ($answerHandler.Extent.Text -match 'Get-LastWaitVerdict') 'the skip decision must inspect the frame that satisfied the wait'
        Assert-True ($answerHandler.Extent.Text -match 'Test-OCRMatch') 'skipInputPattern must use the ordinary OCR matcher'

        # The VM-level recovery belongs to retry, not to the OCR verb: it must
        # run only between attempts and only for the measured ARM64 Hyper-V
        # pre-login timeout. Folded into this existing case so suite counts do
        # not drift merely because the recovery gained a structural guard.
        $retry = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'retry'
        $rt = $retry.Extent.Text
        Assert-True ($rt -match '\$attempt\s+-lt\s+\$maxAttempts') 'VM recovery must be unreachable after the final attempt'
        Assert-True ($rt -match "restartVmBeforeRetry") 'retry must read the explicit recovery mode'
        Assert-True ($rt -match "arm64HyperVColdPowerCycle") 'retry must require the narrow ARM64 Hyper-V mode'
        Assert-True ($rt -match 'Test-Arm64HyperVColdPowerCycleMode') 'retry must delegate host/architecture policy to the testable gate'
        Assert-True ($rt -match "LastFailedAction\s+-eq\s+'waitForTextWithNudge'") 'the login recovery must still require a nudged login wait'
        Assert-True ($rt -match 'WaitForTextMatchedFailurePattern') 'a matched installer failure must not be restarted'
        Assert-True ($rt -match 'WaitForTextConsoleFlood') 'a flooding console must not be restarted'
        Assert-True ($rt -match 'stepsAfterVmRestart') 'the live-ISO boot recovery must run only after a real VM restart'

        $errs = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$errs)
        Assert-Equal -Expected 0 -Actual @($errs).Count -Because 'the sequence handler module must parse'
        $modeGate = $moduleAst.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Test-Arm64HyperVColdPowerCycleMode'
            }, $true)
        Assert-True ($null -ne $modeGate) 'the native host/architecture gate must exist'
        Assert-True ($modeGate.Extent.Text -match "host\.windows\.hyper-v") 'the mode must be restricted to Hyper-V'
        Assert-True ($modeGate.Extent.Text -match 'RuntimeInformation\]::OSArchitecture') 'the gate must use native architecture, not an emulated process environment variable'
        $coldRestart = $moduleAst.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-Arm64HyperVColdPowerCycle'
            }, $true)
        Assert-True ($null -ne $coldRestart) 'the bounded cold-restart helper must exist'
        $ct = $coldRestart.Extent.Text
        foreach ($command in 'Get-VMState', 'Stop-VMForce', 'Start-VM', 'Restart-VMConsole') {
            Assert-True ($ct -match [regex]::Escape($command)) "cold restart must require and invoke $command"
        }
        Assert-True ($ct.IndexOf('Stop-VMForce') -lt $ct.IndexOf('$startResult = Start-VM')) 'the running VM must be force-stopped before it is started'
        Assert-True ($ct -match '\$startRecord\.success') 'the start record success field must be validated'
        Assert-True ($ct -match "-ne\s+'stopped'") 'the stop postcondition must be verified'
        Assert-True ($ct -match "-ne\s+'running'") 'the start postcondition must be verified'

        # Exercise the helper's successful contract path with stateful stubs;
        # the three full cycles cover integration, while this pins call order
        # even when none of those cycles happens to reproduce the host wedge.
        . ([scriptblock]::Create($coldRestart.Extent.Text))
        $script:coldRestartCall = [Collections.Generic.List[string]]::new()
        Set-Item -LiteralPath Function:\Get-VMState -Value {
            param([string]$VMName)
            $null = $VMName
            if ($script:coldRestartCall -contains 'start') { return 'running' }
            if ($script:coldRestartCall -contains 'stop') { return 'stopped' }
            return 'running'
        }
        Set-Item -LiteralPath Function:\Stop-VMForce -Value {
            param([string]$VMName, [int]$StopTimeoutSeconds, [switch]$Confirm)
            $null = $VMName, $StopTimeoutSeconds, $Confirm
            $script:coldRestartCall.Add('stop'); return $true
        }
        Set-Item -LiteralPath Function:\Start-VM -Value {
            param([string]$VMName, [switch]$Confirm)
            $null = $VMName, $Confirm
            $script:coldRestartCall.Add('start'); return @{ success = $true }
        }
        Set-Item -LiteralPath Function:\Restart-VMConsole -Value {
            param([string]$VMName, [switch]$Confirm)
            $null = $VMName, $Confirm
            $script:coldRestartCall.Add('console'); return $true
        }
        Set-Item -LiteralPath Function:\Repair-ScreenshotRing -Value {
            param([string]$VMName, [switch]$Confirm)
            $null = $VMName, $Confirm
            $script:coldRestartCall.Add('ring'); return $true
        }
        try {
            $restarted = Invoke-Arm64HyperVColdPowerCycle -Context @{ VMName = 'test-vm' }
            Assert-True $restarted 'a fully confirmed stop/start/console path must succeed'
            Assert-Equal -Expected 'stop,start,console,ring' -Actual ($script:coldRestartCall -join ',') `
                -Because 'cold recovery order is stop, start, fresh console, fresh screenshot ring'
        } finally {
            foreach ($functionName in 'Get-VMState', 'Stop-VMForce', 'Start-VM', 'Restart-VMConsole', 'Repair-ScreenshotRing', 'Invoke-Arm64HyperVColdPowerCycle') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            Remove-Variable -Name coldRestartCall -Scope Script -ErrorAction SilentlyContinue
        }

        # Capability preflight must walk the recovery-only branch too. Exercise
        # the private walker directly so an action used only after a VM restart
        # cannot bypass host-I/O/OCR validation.
        $capabilityPath = Join-Path $here 'Test.Capability.psm1'
        $capabilityAst = [System.Management.Automation.Language.Parser]::ParseFile($capabilityPath, [ref]$null, [ref]$errs)
        $actionWalker = $capabilityAst.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Add-SequenceActionFromStep'
            }, $true)
        . ([scriptblock]::Create($actionWalker.Extent.Text))
        try {
            $verbs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $fixtureSteps = @([ordered]@{
                    action = 'retry'
                    steps = @([ordered]@{ action = 'waitForTextWithNudge' })
                    stepsAfterVmRestart = @([ordered]@{ action = 'waitForAndEnter' })
                })
            Add-SequenceActionFromStep -Steps $fixtureSteps -Verbs $verbs
            Assert-True ($verbs.Contains('waitForAndEnter')) 'capability preflight missed the recovery-only action'
        } finally {
            Remove-Item -LiteralPath Function:\Add-SequenceActionFromStep -ErrorAction SilentlyContinue
        }

        # The restart must clear the canonical cycle ring, not the retired
        # screen-<vm> path. Resolve a real fixture through Get-CycleScreenDir's
        # seam and prove only PNG frames are removed.
        $screenshotProviderPath = Join-Path $here 'Test.ScreenshotProvider.psm1'
        $screenshotProviderAst = [System.Management.Automation.Language.Parser]::ParseFile($screenshotProviderPath, [ref]$null, [ref]$errs)
        $repairRing = $screenshotProviderAst.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Repair-ScreenshotRing'
            }, $true)
        . ([scriptblock]::Create($repairRing.Extent.Text))
        $ringFixture = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-ring-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $ringFixture -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $ringFixture 'frame.png'), [byte[]](1, 2, 3))
        [IO.File]::WriteAllText((Join-Path $ringFixture 'frame.txt'), 'keep')
        $script:ringResolverCalled = $false
        Set-Item -LiteralPath Function:\Get-CycleScreenDir -Value {
            param([string]$VMName, [switch]$Confirm)
            $null = $VMName, $Confirm
            $script:ringResolverCalled = $true
            return $ringFixture
        }
        Set-Item -LiteralPath Function:\Format-YurunaOperatorMessage -Value { param($Key) $Key }
        try {
            Assert-True (Repair-ScreenshotRing -VMName 'test-vm' -Confirm:$false) 'canonical ring repair must succeed'
            Assert-True $script:ringResolverCalled 'ring repair must use Get-CycleScreenDir'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $ringFixture 'frame.png'))) 'stale PNG survived ring repair'
            Assert-True (Test-Path -LiteralPath (Join-Path $ringFixture 'frame.txt')) 'ring repair removed a non-frame sidecar'
        } finally {
            foreach ($functionName in 'Get-CycleScreenDir', 'Format-YurunaOperatorMessage', 'Repair-ScreenshotRing') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $ringFixture -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name ringResolverCalled -Scope Script -ErrorAction SilentlyContinue
        }

        # Exercise the retry handler itself: one failed pre-login timeout must
        # cold-cycle, run boot recovery, and then make the next attempt. A
        # failurePattern must take the ordinary retry path without a power cut.
        $runtimeFixture = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-retry-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runtimeFixture -Force | Out-Null
        $savedRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $savedFailVariable = Get-Variable -Name Fail -Scope Script -ErrorAction SilentlyContinue
        $savedFailValue = if ($savedFailVariable) { $savedFailVariable.Value } else { $null }
        $env:YURUNA_RUNTIME_DIR = $runtimeFixture
        $script:retryCall = [Collections.Generic.List[string]]::new()
        $script:Fail = [ordered]@{
            LastFailureLabel = $null; LastFailureDescription = $null
            LastFailedAction = $null; LastFailedStepNumber = 0
            WaitForTextMatchedFailurePattern = $null
            WaitForTextConsoleFlood = $null
        }
        Set-Item -LiteralPath Function:\Test-Arm64HyperVColdPowerCycleMode -Value { return $true }
        Set-Item -LiteralPath Function:\Invoke-Arm64HyperVColdPowerCycle -Value {
            param([hashtable]$Context)
            $null = $Context
            $script:retryCall.Add('cold'); return $true
        }
        Set-Item -LiteralPath Function:\Get-SequenceAction -Value {
            param([string]$Name)
            $null = $Name
            return [ordered]@{ FailureClass = 'ocr_timeout'; Severity = 'soft'; SuggestedRecoveries = @('retry_immediately') }
        }
        Set-Item -LiteralPath Function:\Get-PollDelay -Value { param([int]$Attempt) $null = $Attempt; return 0 }
        Set-Item -LiteralPath Function:\Format-YurunaOperatorMessage -Value {
            param($Key, $FormatValues, $FormatBindings, $Arguments)
            $null = $FormatValues, $FormatBindings, $Arguments
            return [string]$Key
        }
        Set-Item -LiteralPath Function:\Send-CycleEventSafely -Value { param($EventRecord) $null = $EventRecord }
        $script:failWithPattern = $false
        $invokeStepBlock = {
            param($Steps, $ParentOrdinal, $ParentAction, $ParentAttempt)
            $null = $ParentOrdinal, $ParentAction, $ParentAttempt
            $action = [string]@($Steps)[0]['action']
            if ($action -eq 'waitForAndEnter') {
                $script:retryCall.Add('recovery')
                return $true
            }
            $script:retryCall.Add('attempt')
            $attemptCount = @($script:retryCall | Where-Object { $_ -eq 'attempt' }).Count
            if ($script:failWithPattern -or $attemptCount -eq 1) {
                $script:Fail.LastFailedAction = 'waitForTextWithNudge'
                $script:Fail.LastFailureLabel = 'login wait'
                $script:Fail.WaitForTextMatchedFailurePattern = $script:failWithPattern ? 'install_fail.crash' : $null
                return $false
            }
            return $true
        }
        $retryContext = @{
            Step = [ordered]@{
                maxAttempts = 2
                restartVmBeforeRetry = 'arm64HyperVColdPowerCycle'
                steps = @([ordered]@{ action = 'waitForTextWithNudge' })
                stepsAfterVmRestart = @([ordered]@{ action = 'waitForAndEnter' })
            }
            InvokeStepBlock = $invokeStepBlock
            StepNum = 2; StepCount = 5; Description = 'pre-login retry'
            VMName = 'test-vm'; HostType = 'host.windows.hyper-v'
        }
        try {
            $retryHandler = $retry.ScriptBlock.GetScriptBlock()
            Assert-True (& $retryHandler $retryContext) 'the second attempt should pass after cold boot recovery'
            Assert-Equal -Expected 'attempt,cold,recovery,attempt' -Actual ($script:retryCall -join ',') `
                -Because 'cold restart and boot recovery belong strictly between attempts'

            $script:retryCall.Clear()
            $script:failWithPattern = $true
            $script:Fail.WaitForTextMatchedFailurePattern = $null
            Assert-True (-not (& $retryHandler $retryContext)) 'two matched installer failures must exhaust the retry'
            Assert-Equal -Expected 'attempt,attempt' -Actual ($script:retryCall -join ',') `
                -Because 'an explicit installer failure must never power-cycle the VM'
        } finally {
            foreach ($functionName in 'Test-Arm64HyperVColdPowerCycleMode', 'Invoke-Arm64HyperVColdPowerCycle',
                'Get-SequenceAction', 'Get-PollDelay', 'Format-YurunaOperatorMessage', 'Send-CycleEventSafely') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            $env:YURUNA_RUNTIME_DIR = $savedRuntimeDir
            Remove-Item -LiteralPath $runtimeFixture -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name retryCall, failWithPattern -Scope Script -ErrorAction SilentlyContinue
            if ($savedFailVariable) { $script:Fail = $savedFailValue }
            else { Remove-Variable -Name Fail -Scope Script -ErrorAction SilentlyContinue }
        }
    }
    It 'rejects an incomplete nudge configuration before starting OCR' {
        $handler = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'waitForTextWithNudge'
        Assert-True ($handler.Extent.Text -match 'IsNullOrWhiteSpace\(\$nudgeKey\)') 'an empty key must fail validation'
        Assert-True ($handler.Extent.Text -match '\$nudgeInterval\s+-lt\s+1') 'a zero/negative interval must fail validation'
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

Describe 'Initial ARM64 Hyper-V installer recovery' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        $script:bootHandlerModule = Get-Module Test.SequenceHandler
        $script:bootRetryHandler = (Get-SequenceAction -Name retry).Handler
        . $script:bootHandlerModule {
            $script:BootModeGate = ${function:Test-Arm64HyperVColdPowerCycleMode}
            function Test-Arm64HyperVColdPowerCycleMode {
                param($Mode, $HostType)
                return (& $script:BootModeGate -Mode $Mode -HostType $HostType -Architecture $script:BootStub.Architecture)
            }
            function Invoke-Arm64HyperVColdPowerCycle {
                $script:BootStub.Calls.Add('cold')
                $script:BootStub.HeartbeatAtRestart = Test-Path -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat')
                return $script:BootStub.RestartOk
            }
            function Save-StepFailureEvidence {
                $script:BootStub.Calls.Add('evidence')
                return 'attempt-evidence'
            }
            function Get-PollDelay { return 0 }
            function Send-CycleEventSafely {
                param($EventRecord)
                $script:BootStub.Events.Add($EventRecord)
            }
            $script:BootInvokeSteps = {
                param($Steps)
                $script:BootStub.Calls.Add('attempt')
                $script:BootStub.Attempts++
                $script:BootStub.SeenSteps.Add(@($Steps)[0])
                $script:Fail.LastFailedAction = 'waitForAndEnter'
                $script:Fail.LastFailureLabel = 'installer confirmation timeout'
                $script:Fail.WaitForTextGuestBootStalled = $script:BootStub.Stalled
                $script:Fail.WaitForTextOcrTail = $script:BootStub.OcrTail
                $script:Fail.WaitForTextMatchedFailurePattern = $script:BootStub.FailurePattern
                $script:Fail.WaitForTextConsoleFlood = $script:BootStub.Flood
                return ($script:BootStub.Attempts -ge $script:BootStub.SuccessAttempt)
            }
        }
    }
    BeforeEach {
        $script:bootSavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $TestDrive
        $script:bootStub = & $script:bootHandlerModule {
            $script:BootStub = @{
                Architecture = 'Arm64'; RestartOk = $true; Stalled = $true
                OcrTail = 'Begin: Running /scripts/casper-bottom ... Setting up console keyboard...'
                FailurePattern = $null; Flood = $null; SuccessAttempt = 2; Attempts = 0
                Calls = [Collections.Generic.List[string]]::new()
                Events = [Collections.Generic.List[object]]::new()
                SeenSteps = [Collections.Generic.List[object]]::new()
                HeartbeatAtRestart = $false
            }
            return $script:BootStub
        }
        $script:bootContext = @{
            Step = @{
                maxAttempts = 5; restartVmBeforeRetry = 'arm64HyperVInstallerBoot'
                steps = @(@{ action = 'waitForAndEnter'; pattern = 'Continue with autoinstall?'; text = 'yes'; timeoutSeconds = 1800 })
            }
            InvokeStepBlock = (& $script:bootHandlerModule { $script:BootInvokeSteps })
            StepNum = 1; StepCount = 17; Description = 'installer boot'
            VMName = 'test-vm'; HostType = 'host.windows.hyper-v'
        }
    }
    AfterEach { $env:YURUNA_RUNTIME_DIR = $script:bootSavedRuntime }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'saves evidence before one cold restart, then succeeds' {
        (& $script:bootRetryHandler $script:bootContext) | Should -BeTrue
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,cold,attempt'
        $script:bootStub.HeartbeatAtRestart | Should -BeTrue
        $script:bootStub.SeenSteps[0].failurePatterns | Should -Contain 'install_fail.crash'
        $script:bootContext.Step.steps[0].ContainsKey('failurePatterns') | Should -BeFalse
        $script:bootStub.Events[0].evidencePath | Should -BeExactly 'attempt-evidence'
    }
    It 'stops after two unsuccessful attempts even if configured for five' {
        $script:bootStub.SuccessAttempt = 99
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,cold,attempt,evidence'
        $script:bootStub.Events[-1].attempt | Should -Be 2
    }
    It 'does not replay the prompt on <Architecture> <Provider>' -TestCases @(
        @{ Architecture = 'X64'; Provider = 'host.windows.hyper-v' }
        @{ Architecture = 'X86'; Provider = 'host.windows.hyper-v' }
        @{ Architecture = 'Arm64'; Provider = 'host.ubuntu.kvm' }
        @{ Architecture = 'Arm64'; Provider = 'host.macos.utm' }
    ) {
        param($Architecture, $Provider)
        $script:bootStub.Architecture = $Architecture
        $script:bootContext.HostType = $Provider
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:bootStub.SeenSteps[0].ContainsKey('failurePatterns') | Should -BeFalse
        $script:bootStub.SeenSteps[0].timeoutSeconds | Should -Be 1800
    }
    It 'does not restart or retry for <Reason>' -TestCases @(
        @{ Reason = 'missing or moving-frame evidence'; Field = 'Stalled'; Value = $false }
        @{ Reason = 'installer error'; Field = 'FailurePattern'; Value = 'install_fail.crash' }
        @{ Reason = 'console flood'; Field = 'Flood'; Value = 'repeating error' }
        @{ Reason = 'language menu'; Field = 'OcrTail'; Value = 'Bahasa Indonesia' }
        @{ Reason = 'login prompt'; Field = 'OcrTail'; Value = 'yuhost26 login:' }
    ) {
        param($Reason, $Field, $Value)
        $null = $Reason
        $script:bootStub[$Field] = $Value
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:bootStub.Events[-1].attempt | Should -Be 1
    }
    It 'does not continue after an unsuccessful cold restart' {
        $script:bootStub.RestartOk = $false
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,cold'
    }
    It 'never restarts a successful first attempt' {
        $script:bootStub.SuccessAttempt = 1
        (& $script:bootRetryHandler $script:bootContext) | Should -BeTrue
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt'
    }
    It 'rejects <Reason> before any input or restart' -TestCases @(
        @{ Reason = 'credential action'; Field = 'action'; Value = 'passwdPrompt' }
        @{ Reason = 'sensitive input'; Field = 'sensitive'; Value = $true }
        @{ Reason = 'another prompt'; Field = 'pattern'; Value = 'Password:' }
        @{ Reason = 'another answer'; Field = 'text'; Value = 'secret' }
    ) {
        param($Reason, $Field, $Value)
        $null = $Reason
        $script:bootContext.Step.steps[0][$Field] = $Value
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        $script:bootStub.Calls.Count | Should -Be 0
    }
}
