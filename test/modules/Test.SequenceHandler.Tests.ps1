<#PSScriptInfo
.VERSION 2026.10.18.2
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

            # An unfinished install restarts from the installer DVD, chosen
            # while the guest is stopped; the restart requires that choice.
            $script:coldRestartCall.Clear()
            Assert-True (-not (Invoke-Arm64HyperVColdPowerCycle -Context @{ VMName = 'test-vm' } -BootInstallerMedia)) `
                'a host without Set-VMInstallerMediaFirstBoot must refuse an installer-media restart'
            Assert-Equal -Expected '' -Actual ($script:coldRestartCall -join ',') `
                -Because 'the capability check must run before the VM is touched'
            $script:installerBootResult = $true
            Set-Item -LiteralPath Function:\Set-VMInstallerMediaFirstBoot -Value {
                param([string]$VMName, [switch]$Confirm)
                $null = $VMName, $Confirm
                $script:coldRestartCall.Add('dvd'); return $script:installerBootResult
            }
            Assert-True (Invoke-Arm64HyperVColdPowerCycle -Context @{ VMName = 'test-vm' } -BootInstallerMedia) `
                'an installer-media restart must succeed when the DVD is selected'
            Assert-Equal -Expected 'stop,dvd,start,console,ring' -Actual ($script:coldRestartCall -join ',') `
                -Because 'the boot device is chosen after the stop is confirmed and before the start'
            $script:coldRestartCall.Clear()
            $script:installerBootResult = $false
            Assert-True (-not (Invoke-Arm64HyperVColdPowerCycle -Context @{ VMName = 'test-vm' } -BootInstallerMedia)) `
                'an unselectable installer DVD must fail the restart'
            Assert-Equal -Expected 'stop,dvd' -Actual ($script:coldRestartCall -join ',') `
                -Because 'the guest must not start into a target that lacks its late-commands'
        } finally {
            foreach ($functionName in 'Get-VMState', 'Stop-VMForce', 'Start-VM', 'Restart-VMConsole', 'Repair-ScreenshotRing',
                'Set-VMInstallerMediaFirstBoot', 'Invoke-Arm64HyperVColdPowerCycle') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            Remove-Variable -Name coldRestartCall, installerBootResult -Scope Script -ErrorAction SilentlyContinue
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
            param([hashtable]$Context, [switch]$BootInstallerMedia)
            $null = $Context
            $script:retryCall.Add($(if ($BootInstallerMedia) { 'cold-dvd' } else { 'cold' })); return $true
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
        $script:failOcrTail = $null
        $invokeStepBlock = {
            param($Steps, $ParentOrdinal, $ParentAction, $ParentAttempt)
            $null = $ParentOrdinal, $ParentAction, $ParentAttempt
            $action = [string]@($Steps)[0]['action']
            if ($action -eq 'waitForAndEnter') {
                $script:retryCall.Add('recovery')
                $script:recoverySteps = @($Steps)
                return $true
            }
            $script:retryCall.Add('attempt')
            $attemptCount = @($script:retryCall | Where-Object { $_ -eq 'attempt' }).Count
            if ($script:failWithPattern -or $attemptCount -eq 1) {
                $script:Fail.LastFailedAction = 'waitForTextWithNudge'
                $script:Fail.LastFailureLabel = 'login wait'
                $script:Fail.WaitForTextMatchedFailurePattern = $script:failWithPattern ? 'install_fail.crash' : $null
                $script:Fail.WaitForTextOcrTail = $script:failOcrTail
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
            # The post-restart recovery wait can livelock the same way the main
            # wait can; it must end early on the hypervisor's verdict too, on a
            # copy that leaves the declared step alone.
            Assert-True ($script:recoverySteps[0].endWaitOnGuestLivelock) `
                'stepsAfterVmRestart must also end early on a livelocked guest'
            Assert-True (-not $retryContext.Step.stepsAfterVmRestart[0].Contains('endWaitOnGuestLivelock')) `
                'the declared stepsAfterVmRestart step must not be mutated'

            $script:retryCall.Clear()
            $script:failWithPattern = $true
            $script:Fail.WaitForTextMatchedFailurePattern = $null
            Assert-True (-not (& $retryHandler $retryContext)) 'two matched installer failures must exhaust the retry'
            Assert-Equal -Expected 'attempt,attempt' -Actual ($script:retryCall -join ',') `
                -Because 'an explicit installer failure must never power-cycle the VM'

            # A login wait that timed out with the live installer still on
            # screen must restart from the installer DVD, OCR's g-for-q included.
            $script:retryCall.Clear()
            $script:failWithPattern = $false
            $script:Fail.WaitForTextMatchedFailurePattern = $null
            $script:failOcrTail = "finish: subiguity/Install/install/postinstall/install_console-setup`nstart: subiquity/Network/_send_update: CHANGE eth0"
            Assert-True (& $retryHandler $retryContext) 'the attempt after an installer-media restart should pass'
            Assert-Equal -Expected 'attempt,cold-dvd,recovery,attempt' -Actual ($script:retryCall -join ',') `
                -Because 'an unfinished install must not boot its partly installed target disk'
        } finally {
            foreach ($functionName in 'Test-Arm64HyperVColdPowerCycleMode', 'Invoke-Arm64HyperVColdPowerCycle',
                'Get-SequenceAction', 'Get-PollDelay', 'Format-YurunaOperatorMessage', 'Send-CycleEventSafely') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            $env:YURUNA_RUNTIME_DIR = $savedRuntimeDir
            Remove-Item -LiteralPath $runtimeFixture -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name retryCall, failWithPattern, failOcrTail, recoverySteps -Scope Script -ErrorAction SilentlyContinue
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
                $script:Fail.WaitForTextGuestLivelocked = $script:BootStub.Livelocked
                $script:Fail.WaitForTextGuestLivelock = if ($script:BootStub.Livelocked) { [pscustomobject]@{ Verdict = 'livelocked'; LivelockedSeconds = 600 } } else { $null }
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
                FailurePattern = $null; Flood = $null; Livelocked = $false; SuccessAttempt = 2; Attempts = 0
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
                steps = @(@{
                    action = 'waitForAndEnter'
                    pattern = @('Continue with autoinstall?', 'subiquity/Install/install/configure_apt', 'subiquity/Install/install/curtin_install')
                    skipInputPattern = @('subiquity/Install/install/configure_apt', 'subiquity/Install/install/curtin_install')
                    blindSkipPattern = @('Bahasa Indonesia', 'subiquity/Install/install/configure_apt', 'subiquity/Install/install/curtin_install')
                    noSegmentMatch = $true; text = 'yes'; timeoutSeconds = 1800
                })
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
    It 'asks the installer wait to end on a livelock without changing the declared step' {
        (& $script:bootRetryHandler $script:bootContext) | Should -BeTrue
        $script:bootStub.SeenSteps[0].endWaitOnGuestLivelock | Should -BeTrue
        $script:bootContext.Step.steps[0].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
    }
    It 'cold-restarts a livelocked guest whose screen shows <Screen>' -TestCases @(
        @{ Screen = 'nothing at all'; Tail = '' }
        @{ Screen = 'early kernel text'; Tail = '[    3.991418] raid6: neonx8   gen()  3433 MB/s' }
        @{ Screen = 'an installer stage before the confirmation'; Tail = 'start: subiquity/Mirror/cmd-apt-config: curtin command apt-config' }
    ) {
        param($Screen, $Tail)
        $null = $Screen
        $script:bootStub.OcrTail = $Tail
        $script:bootStub.Stalled = $false
        $script:bootStub.Livelocked = $true
        (& $script:bootRetryHandler $script:bootContext) | Should -BeTrue
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,cold,attempt'
        $script:bootStub.Events[0].guestLivelocked | Should -BeTrue
        $script:bootStub.Events[0].guestLivelockedSeconds | Should -Be 600
    }
    It 'does not restart a livelocked guest that shows <Reason>' -TestCases @(
        @{ Reason = 'an installed login prompt'; Field = 'OcrTail'; Value = 'yuhost26 login:'; Expected = 'installed guest login is visible' }
        @{ Reason = 'an installer error'; Field = 'FailurePattern'; Value = 'install_fail.crash'; Expected = 'installer reported a failure pattern' }
        @{ Reason = 'a console flood'; Field = 'Flood'; Value = 'repeating error'; Expected = 'console flood prevents a safe restart' }
    ) {
        param($Reason, $Field, $Value, $Expected)
        $null = $Reason
        $script:bootStub.Livelocked = $true
        $script:bootStub[$Field] = $Value
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:bootStub.Events[-2].reason | Should -BeExactly $Expected
    }
    It 'still needs screen proof when the hypervisor saw no livelock' {
        $script:bootStub.OcrTail = ''
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        $script:bootStub.Events[-2].reason | Should -Match 'boot phase is unproven'
        $script:bootStub.Events[0].guestLivelocked | Should -BeFalse
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
        $script:bootStub.SeenSteps[0].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
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
        $script:bootStub.Events[-2].event | Should -BeExactly 'retry_suppressed'
        $script:bootStub.Events[-2].reason | Should -Not -BeNullOrEmpty
        $script:bootStub.Events[-1].configuredMaxAttempts | Should -Be 5
        $script:bootStub.Events[-1].retrySuppressionReason | Should -BeExactly $script:bootStub.Events[-2].reason
    }
    It 'explains a post-boot installer stage without claiming a second attempt' {
        $script:bootStub.OcrTail = 'start: subiquity/Mirror/cmd-apt-config: curtin command apt-config'
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        ($script:bootStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:bootStub.Events[-2].reason | Should -Match 'beyond the boot phase'
        $script:bootStub.Events[-2].permittedMaxAttempts | Should -Be 2
        $script:bootStub.Events[-1].maxAttempts | Should -Be 1
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
        @{ Reason = 'missing later-state skip'; Field = 'skipInputPattern'; Value = @('subiquity/Install/install/configure_apt') }
        @{ Reason = 'pre-confirmation skip'; Field = 'skipInputPattern'; Value = @('subiquity/Install/install', 'subiquity/Mirror/cmd-apt-config') }
        @{ Reason = 'segment matching'; Field = 'noSegmentMatch'; Value = $false }
    ) {
        param($Reason, $Field, $Value)
        $null = $Reason
        $script:bootContext.Step.steps[0][$Field] = $Value
        (& $script:bootRetryHandler $script:bootContext) | Should -BeFalse
        $script:bootStub.Calls.Count | Should -Be 0
    }
}

Describe 'ARM64 Hyper-V login-wait recovery ends a livelocked wait early' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        $script:loginHandlerModule = Get-Module Test.SequenceHandler
        $script:loginRetryHandler = (Get-SequenceAction -Name retry).Handler
        . $script:loginHandlerModule {
            $script:LoginModeGate = ${function:Test-Arm64HyperVColdPowerCycleMode}
            function Test-Arm64HyperVColdPowerCycleMode {
                param($Mode, $HostType)
                return (& $script:LoginModeGate -Mode $Mode -HostType $HostType -Architecture $script:LoginStub.Architecture)
            }
            function Get-PollDelay { return 0 }
            function Send-CycleEventSafely { param($EventRecord) $null = $EventRecord }
            $script:LoginInvokeSteps = {
                param($Steps)
                $script:LoginStub.SeenSteps = @($Steps)
                return $true
            }
        }
    }
    BeforeEach {
        $script:loginStub = & $script:loginHandlerModule {
            $script:LoginStub = @{ Architecture = 'Arm64'; SeenSteps = @() }
            return $script:LoginStub
        }
        $script:loginContext = @{
            Step = @{
                maxAttempts = 3; restartVmBeforeRetry = 'arm64HyperVColdPowerCycle'
                steps = @(
                    @{ action = 'pressKey'; name = 'Enter' }
                    @{ action = 'waitForTextWithNudge'; pattern = 'yuhost26 login:'; nudgeKey = 'Enter'; nudgeIntervalSeconds = 60; timeoutSeconds = 2400 }
                )
            }
            InvokeStepBlock = (& $script:loginHandlerModule { $script:LoginInvokeSteps })
            StepNum = 2; StepCount = 17; Description = 'installed login'
            VMName = 'test-vm'; HostType = 'host.windows.hyper-v'
        }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'marks only the login wait, on a copy, on native ARM64 Hyper-V' {
        (& $script:loginRetryHandler $script:loginContext) | Should -BeTrue
        $seen = @(& $script:loginHandlerModule { $script:LoginStub.SeenSteps })
        $seen[0].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
        $seen[1].endWaitOnGuestLivelock | Should -BeTrue
        $script:loginContext.Step.steps[1].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
    }
    It 'leaves the wait policy alone where no cold restart follows (<Architecture> <Provider>)' -TestCases @(
        @{ Architecture = 'X64'; Provider = 'host.windows.hyper-v' }
        @{ Architecture = 'Arm64'; Provider = 'host.macos.utm' }
    ) {
        param($Architecture, $Provider)
        & $script:loginHandlerModule { param($a) $script:LoginStub.Architecture = $a } $Architecture
        $script:loginContext.HostType = $Provider
        (& $script:loginRetryHandler $script:loginContext) | Should -BeTrue
        $seen = @(& $script:loginHandlerModule { $script:LoginStub.SeenSteps })
        $seen[1].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
    }
    It 'turns the step flag into the Wait-ForText switch, and nothing at all without it' {
        $context = @{ Step = @{ pattern = 'x'; endWaitOnGuestLivelock = $true }; Vars = @{}; ExpandVariable = { param($v) $v }; DefaultTimeoutSeconds = 5; DefaultPollSeconds = 1 }
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        $p.livelockExit.EndOnGuestLivelock | Should -BeTrue
        $context.Step.Remove('endWaitOnGuestLivelock')
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        $p.livelockExit.Count | Should -Be 0
    }
}

Describe 'stopVm requests the shutdown through the host and observes it' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        $script:stopStub = @{ State = 'running'; StopAfterRequest = $false; Calls = [Collections.Generic.List[string]]::new() }
        # Dot-sourced into the module so the stubs shadow the host contract for
        # this module only and die with it in AfterAll; a global stub would
        # outlive the file in the shared runspace.
        . (Get-Module Test.SequenceHandler) {
            function Get-VMState {
                param([string]$VMName)
                $null = $VMName
                return $script:StopStub.State
            }
            function Stop-VM {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [switch]$Force, [int]$ShutdownTimeoutSeconds, [switch]$NoForce)
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub shutdown request')) { return $false }
                $null = $ShutdownTimeoutSeconds
                $call = 'stop'
                if ($Force) { $call = 'stop-force' } elseif ($NoForce) { $call = 'stop-noforce' }
                $script:StopStub.Calls.Add($call)
                if ($script:StopStub.StopAfterRequest) {
                    $script:StopStub.State = 'stopped'
                    return $true
                }
                return $false
            }
            function Stop-VMForce {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [int]$StopTimeoutSeconds)
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub forced stop')) { return $false }
                $null = $StopTimeoutSeconds
                $script:StopStub.Calls.Add('force')
                $script:StopStub.State = 'stopped'
                return $true
            }
        }
        & (Get-Module Test.SequenceHandler) { $script:StopStub = $args[0] } $script:stopStub
        $script:stopHandler = (Get-SequenceAction -Name stopVm).Handler
        $script:stopContext = @{
            Step = @{ timeoutSeconds = 1; frameIntervalSeconds = 0 }
            StepNum = 15; StepCount = 19; Description = 'Power off after provisioning'
            VMName = 'test-vm'; HostType = 'host.windows.hyper-v'; GuestKey = 'guest.ubuntu.server.26'
            LogDir = $TestDrive; ScreenshotDir = $TestDrive
            ExpandVariable = { param($v) $v }; Vars = @{}
        }
    }
    BeforeEach {
        $script:stopStub.State = 'running'; $script:stopStub.StopAfterRequest = $false; $script:stopStub.Calls.Clear()
        $script:stopContext.Step = @{ timeoutSeconds = 1; frameIntervalSeconds = 0 }
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped = $null; $state.FirstGuestSilenceUtc = $null; $state.FirstGuestSilenceSource = $null
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'is registered as a state-changing verb that times out rather than failing provisioning' {
        $entry = Get-SequenceAction -Name stopVm
        $entry.ReplaySafety | Should -BeExactly 'state-changing'
        $entry.FailureClass | Should -BeExactly 'wait_timeout'
        $entry.SuggestedRecoveries | Should -Not -Contain 'retry_immediately' -Because 'waiting again for an ignored shutdown changes nothing'
    }
    It 'passes once the host reports the VM stopped, without forcing it' {
        $script:stopStub.StopAfterRequest = $true
        (& $script:stopHandler $script:stopContext) | Should -BeTrue
        ($script:stopStub.Calls -join ',') | Should -BeExactly 'stop-noforce'
        (Get-SequenceFailureState).StepVmNotStopped | Should -BeNullOrEmpty
    }
    It 'fails with the observed state when the guest ignores the request and forcing is not allowed' {
        (& $script:stopHandler $script:stopContext) | Should -BeFalse
        $script:stopStub.Calls | Should -Not -Contain 'force'
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped.observedState | Should -BeExactly 'running'
        $state.StepVmNotStopped.action | Should -BeExactly 'stopVm'
        [int]$state.StepVmNotStopped.waitedSeconds | Should -BeGreaterOrEqual 1
        $state.FirstGuestSilenceUtc | Should -Not -BeNullOrEmpty -Because 'an ignored shutdown is the first sign the guest stopped answering'
        $state.FirstGuestSilenceSource | Should -Match '^stopVm:'
    }
    It 'records the evidence, forces the VM off, and continues when forceOnTimeout is set' {
        $script:stopContext.Step.forceOnTimeout = $true
        (& $script:stopHandler $script:stopContext) | Should -BeTrue
        ($script:stopStub.Calls -join ',') | Should -BeExactly 'stop-noforce,force'
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped | Should -BeNullOrEmpty -Because 'a later failure must not be attributed to a wait that was resolved'
        $state.FirstGuestSilenceUtc | Should -Not -BeNullOrEmpty -Because 'the silence marker outlives the forced recovery'
    }
    It 'passes at once for a VM that is already stopped' {
        $script:stopStub.State = 'stopped'
        (& $script:stopHandler $script:stopContext) | Should -BeTrue
        $script:stopStub.Calls.Count | Should -Be 0
    }
}

Describe 'startVm and inputTextAndEnter leave evidence when the guest goes quiet' {
    It 'startVm observes the stopped boundary through the shared wait and records a timeout as not stopped' {
        $h = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'startVm'
        $h.Extent.Text | Should -Match 'Wait-VmStopped' -Because 'the wait captures console frames while it runs'
        $h.Extent.Text | Should -Match 'Save-VmNotStoppedEvidence' -Because 'a guest that never stops must leave its state, frame and counters behind'
        $h.Extent.Text | Should -Match 'Set-HyperVArm64LinuxGuestProcessorCount'
    }
    It 'inputTextAndEnter can require the console to acknowledge what was typed' {
        $h = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'inputTextAndEnter'
        $h.Extent.Text | Should -Match 'acknowledgeWithinSeconds'
        $h.Extent.Text | Should -Match 'StepInputLost\s*=\s*\$true' -Because 'an unacknowledged command is an input_lost failure, not a pass'
        $h.Extent.Text | Should -Match 'Set-GuestSilenceMarker'
    }
    It 'sshExec marks the first silence when its transport drops mid-command' {
        $h = Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'sshExec'
        $h.Extent.Text | Should -Match 'transportLost[\s\S]*Set-GuestSilenceMarker'
    }
}
