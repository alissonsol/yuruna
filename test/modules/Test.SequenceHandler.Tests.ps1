<#PSScriptInfo
.VERSION 2026.11.23
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

# An unbounded break outlived the step watchdog's bound, and the watchdog killed
# the whole cycle; the break now ends at that bound by itself.
Describe 'break handler ends an unbounded break at the step bound' {
    It 'defaults to testCycle.stepTimeoutSeconds and keeps the heartbeat moving while it holds' {
        $t = (Get-BreakHandlerScriptBlockAst -Path $script:modulePath).Extent.Text
        $t | Should -Match 'testCycle\.stepTimeoutSeconds'
        $t | Should -Match '\$breakMaxSeconds = 2700'
        $loop = $t.Substring($t.IndexOf('while ($true)'))
        $loop.Substring(0, $loop.IndexOf('Start-Sleep -Milliseconds $breakPollMs')) | Should -Match 'breakBeat'
    }
}

# A wait its own timeout bounds read as a wedge once it outlasted the
# watchdog's bound; each finished probe now moves the heartbeat.
Describe 'Wait-VmStopped moves the step heartbeat while it waits' {
    BeforeAll { Import-Module $script:modulePath -Force -DisableNameChecking }
    It 'beats once per probe until the VM stops' {
        # Closures carry the counters, so the stand-ins the module resolves
        # globally need no global variables.
        $counts = @{ probes = 0; beats = 0 }
        Set-Item -Path function:global:Get-VMState -Value ({ param($VMName) $null = $VMName; $counts.probes++; if ($counts.probes -ge 3) { 'stopped' } else { 'running' } }.GetNewClosure())
        Set-Item -Path function:global:Write-RunnerStepHeartbeat -Value ({ $counts.beats++ }.GetNewClosure())
        try {
            Mock -ModuleName Test.SequenceHandler Start-Sleep { }
            $result = InModuleScope Test.SequenceHandler { Wait-VmStopped -Context @{ VMName = 'vm' } -TimeoutSeconds 60 -FrameIntervalSeconds 0 }
            $result.Stopped | Should -BeTrue
            $counts.beats | Should -Be 3
        } finally {
            Remove-Item function:global:Get-VMState, function:global:Write-RunnerStepHeartbeat -ErrorAction SilentlyContinue
        }
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
    It 'forwards the step''s blank-console expectation to Wait-ForText on both pure waits' {
        # A login wait that follows an install reboot or a cold restart starts
        # on a console that shows nothing until getty prints; the step declares
        # that, and the engine's no-text self-heal reads the declaration off
        # the same parameter path as the other wait options.
        foreach ($name in @('waitForText', 'waitForTextWithNudge')) {
            $t = (Get-HandlerScriptBlockAst -Path $script:modulePath -Name $name).Extent.Text
            Assert-True ($t -match '-ExpectBlankConsole:\$p\.expectBlankConsole') "$name must hand the step's expectBlankConsole to Wait-ForText"
        }
        $src = Get-Content -Raw -LiteralPath $script:modulePath
        Assert-True ($src -match 'expectBlankConsole\s*=\s*\$step\.expectBlankConsole\s+-eq\s+\$true') `
            'the shared step-parameter resolver must read the boolean the way it reads the other wait options'
    }

    It 'declares a blank console on the two login waits after a reboot: <Sequence>' -ForEach @(
        @{ Sequence = 'start.guest.ubuntu.server.24.yml' }, @{ Sequence = 'start.guest.ubuntu.server.26.yml' }
        @{ Sequence = 'start.guest.ubuntu.server.24.macos.utm.yml' }, @{ Sequence = 'start.guest.ubuntu.server.26.macos.utm.yml' }
    ) {
        # The UTM copies are held to these files, so a declaration lost from both
        # would pass parity, and the wait would repair a healthy blank console.
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $text = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "test/sequences/$Sequence")
        $declared = [regex]::Matches($text, '(?m)^(\s*)- action: \w+\r?\n(?:\1  .*\r?\n|\s*\r?\n)*?\1  expectBlankConsole: true\b')
        Assert-Equal 2 $declared.Count "$Sequence declares it on the wait after the install and the one after the cold restart"
        foreach ($match in $declared) {
            Assert-Match 'pattern: "\$\{hostLabel\} login:"' $match.Value 'only a login wait starts on a blank console'
        }
    }

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
                $n.Name -eq 'Invoke-SequenceColdPowerCycle'
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
        $legacyColdRestart = $moduleAst.Find({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-Arm64HyperVColdPowerCycle'
            }, $true)
        Assert-True ($null -ne $legacyColdRestart) 'the legacy helper must remain available'
        . ([scriptblock]::Create($legacyColdRestart.Extent.Text))
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
                'Set-VMInstallerMediaFirstBoot', 'Invoke-Arm64HyperVColdPowerCycle', 'Invoke-SequenceColdPowerCycle') {
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
        $ringFixture = New-YurunaTestTempDir -Prefix 'yuruna-ring'
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
            $ring = Repair-ScreenshotRing -VMName 'test-vm' -Confirm:$false
            Assert-True ($ring.Attempted -and $ring.Effective) 'canonical ring repair must remove the frames'
            Assert-Equal -Expected 'screenshot-ring' -Actual $ring.Mechanism
            Assert-True $script:ringResolverCalled 'ring repair must use Get-CycleScreenDir'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $ringFixture 'frame.png'))) 'stale PNG survived ring repair'
            Assert-True (Test-Path -LiteralPath (Join-Path $ringFixture 'frame.txt')) 'ring repair removed a non-frame sidecar'
        } finally {
            foreach ($functionName in 'Get-CycleScreenDir', 'Format-YurunaOperatorMessage', 'Repair-ScreenshotRing') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            Remove-YurunaTestTempDir $ringFixture
            Remove-Variable -Name ringResolverCalled -Scope Script -ErrorAction SilentlyContinue
        }

        # Exercise the retry handler itself: one failed pre-login timeout must
        # cold-cycle, run boot recovery, and then make the next attempt. A
        # failurePattern must take the ordinary retry path without a power cut.
        $runtimeFixture = New-YurunaTestTempDir -Prefix 'yuruna-retry'
        $savedRuntimeDir = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
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

            $script:retryCall.Clear()
            $script:failOcrTail = 'curtin in-target --target=/target -- apt-get install -y iptables-persistent'
            $script:Fail.WaitForTextInstallerStage = 'start: subiquity/Install/install/postinstall/restore_apt_config'
            Assert-True (& $retryHandler $retryContext) 'the attempt after a retained-stage installer-media restart should pass'
            Assert-Equal -Expected 'attempt,cold-dvd,recovery,attempt' -Actual ($script:retryCall -join ',') `
                -Because 'scrolling past the installer marker must not select the partly installed target disk'
        } finally {
            foreach ($functionName in 'Test-Arm64HyperVColdPowerCycleMode', 'Invoke-Arm64HyperVColdPowerCycle',
                'Get-SequenceAction', 'Get-PollDelay', 'Format-YurunaOperatorMessage', 'Send-CycleEventSafely') {
                Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
            }
            Restore-YurunaTestEnvironment -Saved $savedRuntimeDir
            Remove-YurunaTestTempDir $runtimeFixture
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

Describe 'Get-GuestAptIndexMismatch (which cached apt index disagreed with its InRelease)' {

    BeforeAll { Import-Module $script:modulePath -Force -DisableNameChecking }

    It 'names the index, the sizes, the proxy and what apt_retry did about it' {
        # The shape the macOS UTM guests logged when the caching proxy held an
        # InRelease beside an arm64 index from a later Docker publish.
        $url = 'https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-arm64/Packages.bz2'
        $out = @(
            "[   4.077] Err:7 https://download.docker.com/linux/ubuntu noble/stable arm64 Packages"
            "[   4.512] E: Failed to fetch $url  File has unexpected size (68990 != 68750). Mirror sync in progress? [IP: 192.168.7.42 3129]"
            "[   4.512]    Release file created at: Wed, 21 Oct 2026 08:17:00 +0000"
            "[   4.520] !! apt_retry: proxy copy of ${url}: HTTP/1.1 200 OK;Age: 33000;X-Cache: HIT from cache"
            "[   4.530] !! apt_retry: asked the caching proxy to PURGE ${url}: HTTP 200"
            "[ 108.866] E: Failed to fetch $url  File has unexpected size (68994 != 68759). Mirror sync in progress? [IP: 192.168.7.42 3129]"
            "[ 108.866]    Release file created at: Wed, 21 Oct 2026 08:17:46 +0000"
        ) -join "`n"
        $m = Get-GuestAptIndexMismatch -Output $out
        Assert-Equal -Expected 'unexpected-size' -Actual $m.kind
        Assert-Equal -Expected $url -Actual $m.url
        # The last attempt is the one the step failed on.
        Assert-Equal -Expected 68994 -Actual $m.receivedBytes
        Assert-Equal -Expected 68759 -Actual $m.expectedBytes
        Assert-Equal -Expected '192.168.7.42:3129' -Actual $m.server
        Assert-Equal -Expected 'Wed, 21 Oct 2026 08:17:46 +0000' -Actual $m.releaseFileCreated
        Assert-Equal -Expected 2 -Actual $m.occurrences
        Assert-Equal -Expected 'HTTP/1.1 200 OK;Age: 33000;X-Cache: HIT from cache' -Actual $m.proxyCopy
        Assert-Equal -Expected 200 -Actual $m.proxyPurgeStatus
    }

    It 'recognizes a hash mismatch, which names no sizes and often no server' {
        $out = "E: Failed to fetch http://ports.ubuntu.com/ubuntu-ports/dists/noble/main/dep11/Components-arm64.yml.gz  Hash Sum mismatch`n   Hashes of expected file:"
        $m = Get-GuestAptIndexMismatch -Output $out
        Assert-Equal -Expected 'hash-sum-mismatch' -Actual $m.kind
        Assert-Equal -Expected 'http://ports.ubuntu.com/ubuntu-ports/dists/noble/main/dep11/Components-arm64.yml.gz' -Actual $m.url
        Assert-True ($null -eq $m.receivedBytes -and $null -eq $m.expectedBytes) 'a hash mismatch states no sizes'
        Assert-Equal -Expected '' -Actual $m.server
        Assert-True ($null -eq $m.proxyPurgeStatus) 'nothing was purged'
    }

    It 'returns nothing for an apt failure that is not an index mismatch' {
        # A plain fetch failure is an outage, not a stale pair, and naming one
        # would send the operator to the cache for nothing.
        $out = "E: Failed to fetch https://download.docker.com/linux/ubuntu/dists/noble/InRelease  Could not connect to 192.168.7.42:3129"
        Assert-True ($null -eq (Get-GuestAptIndexMismatch -Output $out)) 'a connect failure is not a mismatch'
        Assert-True ($null -eq (Get-GuestAptIndexMismatch -Output '')) 'empty output names nothing'
        Assert-True ($null -eq (Get-GuestAptIndexMismatch -Output $null)) 'no output names nothing'
    }
}

Describe 'Get-GuestAptUpdateStall (which apt-get update attempts the per-attempt bound killed)' {

    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        # The shape of a guest log from an update.sh whose apt-get update the
        # 300-second bound killed twice: every line arrives twice, from two
        # writers whose clocks differ by about a second, and apt fetches one
        # origin's InRelease files one at a time, so most of them sit at Ign.
        $script:killedTwice = @(
            '# Yuruna fetch-and-execute log'
            '# script:    guest/ubuntu.server.26/ubuntu.server.26.update.sh'
            '# ---'
            '[  25.757] ==== Update system packages ===='
            '[  40.691] Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[  41.749] Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[  86.034] Ign:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[  87.092] Ign:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 100.715] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 101.773] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 161.780] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 162.838] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 209.138] Err:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 209.138]   Connection failed [IP: 192.0.2.10 3128]'
            '[ 210.195] Err:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 210.197]   Connection failed [IP: 192.0.2.10 3128]'
            '[ 222.839] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 223.902] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 284.882] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 285.942] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 326.039] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 327.103] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 326.050] YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"attempt","attempt":1,"maxAttempts":2,"rc":124,"permanent":false}'
            '[ 326.231] !! apt_retry: sleeping 10s before retry (backoff 10s, jittered)'
            '[ 336.263] >> apt_retry: attempt 2/2 for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 337.327] >> apt_retry: attempt 2/2 for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 363.276] Hit:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 364.338] Hit:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 396.616] Ign:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 397.678] Ign:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 457.688] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 458.752] Ign:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 518.756] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 519.816] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 535.468] Hit:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 536.529] Hit:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 583.725] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 584.783] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 636.496] !! apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 636.504] YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"outcome","outcome":"exhausted","attempt":2,"maxAttempts":2,"rc":124}'
            '[ 636.505] !! apt_retry: all 2 attempts exhausted for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '# exit code: 124'
            '[ 637.569] !! apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 637.620]     NONZERO SCRIPT EXIT:'
        ) -join "`n"
    }

    It 'names the attempts, the bound, the server apt named and the source the last attempt still waited on' {
        $s = Get-GuestAptUpdateStall -Output $script:killedTwice
        Assert-Equal -Expected '1,2' -Actual (@($s.stalledAttempts) -join ',')
        Assert-Equal -Expected 2 -Actual $s.maxAttempts
        Assert-Equal -Expected 300 -Actual $s.boundSeconds
        Assert-Equal -Expected 124 -Actual $s.rc
        Assert-Equal -Expected '192.0.2.10:3128' -Actual $s.server
        Assert-Equal -Expected 'archive.ubuntu.com/ubuntu resolute-backports' -Actual (@($s.pendingSources) -join '|')
        Assert-Equal -Expected 0 -Actual @($s.failedSources).Count -Because 'the security index answered in the second attempt'
        Assert-Equal -Expected 'attempt 1,2 of 2 killed at 300s (rc=124) via 192.0.2.10:3128; pending archive.ubuntu.com/ubuntu resolute-backports' -Actual $s.summary
    }

    It 'reads the sources of the last killed attempt only' {
        # An index the first attempt reached can be the one the second never got.
        $out = @(
            '[  77.186] Ign:1 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[  77.186] Ign:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 200.315] Err:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 200.315]   Connection failed [IP: 192.0.2.10 3128]'
            '[ 234.051] Hit:1 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 234.124] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 294.187] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 317.179] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            '[ 325.214] >> apt_retry: attempt 2/2 for: sudo env apt-get update'
            '[ 385.797] Ign:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 385.798] Ign:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 386.985] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 447.041] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 508.917] Err:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 508.917]   Connection failed [IP: 192.0.2.10 3128]'
            '[ 625.382] !! apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
        ) -join "`n"
        $s = Get-GuestAptUpdateStall -Output $out
        Assert-Equal -Expected 'archive.ubuntu.com/ubuntu resolute|archive.ubuntu.com/ubuntu resolute-backports' -Actual (@($s.pendingSources) -join '|')
        Assert-Equal -Expected 'security.ubuntu.com/ubuntu resolute-security' -Actual (@($s.failedSources) -join '|')
        Assert-Match -Pattern '; failed security\.ubuntu\.com/ubuntu resolute-security$' -Actual $s.summary
    }

    It 'counts a stall line the late writer repeats after the next banner once, and keeps that attempt open' {
        $out = @(
            '[ 10.000] Ign:1 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 20.000] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            '[ 21.000] >> apt_retry: attempt 2/2 for: sudo env apt-get update'
            '[ 21.100] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            '[ 40.000] Ign:1 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 50.000] !! apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=137): sudo env apt-get update'
        ) -join "`n"
        $s = Get-GuestAptUpdateStall -Output $out
        Assert-Equal -Expected '1,2' -Actual (@($s.stalledAttempts) -join ',')
        Assert-Equal -Expected 137 -Actual $s.rc -Because 'the KILL backstop ended the last attempt'
        Assert-Equal -Expected 'archive.ubuntu.com/ubuntu resolute-backports' -Actual (@($s.pendingSources) -join '|')
    }

    It 'takes only the stall lines from OCR text, through OCR damage and a wrapped line' {
        # Two engines read one frame: the first turned 300s into SOOS, which
        # names no bound, and dropped the underscore the second also dropped.
        $ocr = @(
            '!! apt_retrg: attempt. 1/2 stalled; killed bg the SOOS per-attempt. bound (rc=124): sudo env apt-get. update'
            'Err: 2 http://securitg.ubuntu.com/ubuntu resolute-security InRelease'
            'connection failed [IP: 132.0.2.10 312B]'
            'I aptretry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteract ive DEBIANPRIORITY=critical apt-get unde'
            'Err:2 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            'Connection failed [IP: 192.0.2.10 3128]'
            'NONZERO SCRIPT EXIT'
        ) -join "`n"
        $s = Get-GuestAptUpdateStall -Output $ocr -FromOcr
        Assert-Equal -Expected '2' -Actual (@($s.stalledAttempts) -join ',')
        Assert-Equal -Expected 300 -Actual $s.boundSeconds
        Assert-Equal -Expected '' -Actual $s.server -Because 'an address read off the screen can be damaged'
        Assert-Equal -Expected 0 -Actual (@($s.pendingSources).Count + @($s.failedSources).Count)
        Assert-Equal -Expected 'attempt 2 of 2 killed at 300s (rc=124)' -Actual $s.summary
        $wrapped = Get-GuestAptUpdateStall -FromOcr -Output "Il apt_retry: attempt 2/2 stalled; killed by the 300s per-att`nempt bound (rc=124): sudo env apt-get update"
        Assert-Equal -Expected 'attempt 2 of 2 killed at 300s (rc=124)' -Actual $wrapped.summary
    }

    It 'reads no cause from a kill of an earlier attempt on screen, where nothing shows how the update ended' {
        $s = Get-GuestAptUpdateStall -FromOcr -Output 'apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
        Assert-True ($null -eq $s) 'the next attempt may have succeeded, which apt_retry prints nothing for'
    }

    It 'reads a digit OCR took from another script as no number, without throwing' {
        # A recognizer created from the user's profile languages can return
        # fullwidth or Arabic-Indic digits, which an [int] cast refuses.
        $fullwidthOne = [char]0xFF11; $fullwidthTwo = [char]0xFF12; $fullwidthThree = [char]0xFF13; $arabicIndicTwo = [char]0x0662
        foreach ($text in @(
                "apt_retry: attempt $fullwidthTwo/2 stalled; killed by the 300s per-attempt bound (rc=124)"
                "apt_retry: attempt 2/$arabicIndicTwo stalled; killed by the 300s per-attempt bound (rc=124)"
                "apt_retry: attempt 2/2 stalled; killed by the ${fullwidthThree}00s per-attempt bound (rc=124)"
                "apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=${fullwidthOne}24)")) {
            Assert-True ($null -eq (Get-GuestAptUpdateStall -FromOcr -Output $text)) "no reading from: $text"
        }
        # Another engine's ASCII copy of the same frame still reads.
        $frame = "apt_retry: attempt $fullwidthTwo/2 stalled; killed by the 300s per-attempt bound (rc=124)`n" +
            'apt_retry: attempt 2/2 stalled; killed by the 300s per-attempt bound (rc=124)'
        Assert-Equal -Expected 'attempt 2 of 2 killed at 300s (rc=124)' -Actual (Get-GuestAptUpdateStall -FromOcr -Output $frame).summary
    }

    It 'reads no cause from a kill the next attempt recovered from, when <Case> failed the script later' -TestCases @(
        @{ Case = 'a package transaction'; Later = @(
                '[ 902.411] !! apt_retry: all 5 attempts exhausted for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y'
                '[ 903.473] !! apt_retry: all 5 attempts exhausted for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y'
                '# exit code: 100') },
        @{ Case = 'the project clone'; Later = @(
                '[ 480.100] project git clone failed after 3 attempts'
                '[ 481.162] project git clone failed after 3 attempts'
                '# exit code: 1') }
    ) {
        param($Case, $Later)
        $null = $Case
        # apt_retry prints nothing when an attempt succeeds: here the second
        # attempt fetched every index the first one never finished.
        $out = (@(
            '[  25.757] ==== Update system packages ===='
            '[ 284.882] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 285.942] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 326.039] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 327.103] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 326.231] !! apt_retry: sleeping 10s before retry (backoff 10s, jittered)'
            '[ 336.263] >> apt_retry: attempt 2/2 for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 337.327] >> apt_retry: attempt 2/2 for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
            '[ 340.276] Hit:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 341.338] Hit:1 http://security.ubuntu.com/ubuntu resolute-security InRelease'
            '[ 340.616] Hit:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 341.678] Hit:2 http://archive.ubuntu.com/ubuntu resolute InRelease'
            '[ 341.688] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 342.750] Hit:3 http://archive.ubuntu.com/ubuntu resolute-updates InRelease'
            '[ 341.756] Hit:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 342.818] Hit:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 342.100] Reading package lists...'
            '[ 343.162] Reading package lists...'
        ) + $Later) -join "`n"
        Assert-True ($null -eq (Get-GuestAptUpdateStall -Output $out)) 'an update that recovered did not fail the script'
    }

    It 'reads the kill as the cause when apt_retry closed the update as failed (<Case>)' -TestCases @(
        @{ Case = 'attempts exhausted after a failed last attempt'; Max = 2; Closing = @(
                '[ 326.231] !! apt_retry: sleeping 10s before retry (backoff 10s, jittered)'
                '[ 336.263] >> apt_retry: attempt 2/2 for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
                '[ 398.512] Err:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
                '[ 398.512]   Could not connect to archive.ubuntu.com:80, connection timed out'
                '[ 640.112] !! apt_retry: attempt 2/2 failed (rc=100): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update'
                '[ 640.130] !! apt_retry: all 2 attempts exhausted for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update') },
        @{ Case = 'the retry window closed'; Max = 9; Closing = @(
                '[ 326.240] !! apt_retry: the 1200s retry window closed after 1 attempt(s) for: sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update') }
    ) {
        param($Case, $Max, $Closing)
        $null = $Case
        $out = (@(
            '[ 284.882] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            "[ 326.039] !! apt_retry: attempt 1/$Max stalled; killed by the 300s per-attempt bound (rc=124): sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt-get update"
        ) + $Closing) -join "`n"
        $s = Get-GuestAptUpdateStall -Output $out
        Assert-Equal -Expected '1' -Actual (@($s.stalledAttempts) -join ',')
        Assert-Equal -Expected "attempt 1 of $Max killed at 300s (rc=124); pending archive.ubuntu.com/ubuntu resolute-backports" -Actual $s.summary
    }

    It 'returns nothing for an apt failure no bound killed, and leaves an index mismatch to its own reading' {
        $url = 'https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-arm64/Packages.bz2'
        $out = @(
            "[   4.512] E: Failed to fetch $url  File has unexpected size (68990 != 68750). Mirror sync in progress? [IP: 192.0.2.10 3129]"
            '[   4.600] !! apt_retry: attempt 1/2 failed (rc=100): sudo env apt-get update'
        ) -join "`n"
        Assert-True ($null -eq (Get-GuestAptUpdateStall -Output $out)) 'a failed attempt is not a stalled one'
        Assert-Equal -Expected $url -Actual (Get-GuestAptIndexMismatch -Output $out).url
        Assert-True ($null -eq (Get-GuestAptUpdateStall -Output '')) 'empty output names nothing'
        Assert-True ($null -eq (Get-GuestAptUpdateStall -Output $null -FromOcr)) 'no output names nothing'
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
        $script:bootSavedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
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
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:bootSavedRuntime }
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
        $script:bootStub.SeenSteps[0].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse -Because 'the installer confirmation restarts only on the proofs its own guard reads'
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

Describe 'Provider-neutral login-wait cold recovery' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        $script:coldModule = Get-Module Test.SequenceHandler
        $script:coldHandler = (Get-SequenceAction -Name retry).Handler
        . $script:coldModule {
            function Get-PollDelay { return 0 }
            function Send-CycleEventSafely { param($EventRecord) $script:ColdStub.Events.Add($EventRecord) }
            function Save-StepFailureEvidence {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([string])]
                param($VMName, $Label, $DiagnosticRecord, $StepStartedUtc)
                $null = $Label, $PSCmdlet.ShouldProcess($VMName, 'Record fixture evidence')
                $script:ColdStub.Diagnostic = $DiagnosticRecord
                $script:ColdStub.EvidenceStepStartedUtc = $StepStartedUtc
                $script:ColdStub.Calls.Add('evidence')
                if (-not $script:ColdStub.EvidenceAvailable) { return }
                return 'failed-attempt'
            }
            function Get-VMState {
                param($VMName)
                $null = $VMName
                if ($script:ColdStub.Failure -eq 'initial-state') { return 'unknown' }
                return $script:ColdStub.State
            }
            function Stop-VMForce {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param($VMName, $StopTimeoutSeconds)
                $null = $PSCmdlet.ShouldProcess($VMName, 'Record fixture stop')
                $script:ColdStub.StopBudget = $StopTimeoutSeconds
                $script:ColdStub.Calls.Add('stop')
                if ($script:ColdStub.Failure -eq 'stop') { return $false }
                if ($script:ColdStub.Failure -ne 'stop-state') { $script:ColdStub.State = 'stopped' }
                return $true
            }
            function Start-VM {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([hashtable], [bool])]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($VMName, 'Record fixture start')
                $script:ColdStub.Calls.Add('start')
                if ($script:ColdStub.Failure -eq 'start') { return @{success=$false} }
                if ($script:ColdStub.Failure -eq 'start-record') { return $true }
                if ($script:ColdStub.Failure -ne 'start-state') { $script:ColdStub.State = 'running' }
                return @{success=$true}
            }
            function Restart-VMConsole {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($VMName, 'Record fixture refresh')
                $script:ColdStub.Calls.Add('console')
                return $script:ColdStub.Failure -ne 'console'
            }
            function Repair-ScreenshotRing {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($VMName, 'Record fixture ring repair')
                $script:ColdStub.Calls.Add('ring')
                return $true
            }
            $script:ColdInvokeSteps = {
                param($Steps)
                $script:ColdStub.Seen.Add(@($Steps))
                if (-not @($Steps | Where-Object action -EQ waitForTextWithNudge).Count) {
                    $script:ColdStub.Calls.Add('recovery'); return $true
                }
                $script:ColdStub.Calls.Add('attempt')
                $script:ColdStub.Attempts++
                if ($script:ColdStub.Attempts -ge $script:ColdStub.SuccessAttempt) { return $true }
                $script:Fail.LastFailedAction = $script:ColdStub.FailedAction
                $script:Fail.StepFailurePhase = $script:ColdStub.FailurePhase
                $script:Fail.LastFailureLabel = 'login timeout'
                $script:Fail.WaitForTextOcrTail = $script:ColdStub.OcrTail
                $script:Fail.WaitForTextMatchedFailurePattern = $script:ColdStub.Pattern
                $script:Fail.WaitForTextConsoleFlood = $script:ColdStub.Flood
                $script:Fail.WaitForTextConsoleSecondOpinion = if ($script:ColdStub.EmitOpinion) { @{Verdict='guest-wedged';VMState='running';CpuPercent=1080} } else { $null }
                $script:Fail.WaitForTextDisplayStallEnd = $script:ColdStub.DisplayStall
                $script:Fail.WaitForTextKernelStallEnd = $script:ColdStub.KernelStallEnd
                $script:Fail.WaitForTextGuestLivelock = $script:ColdStub.Livelock
                $script:Fail.WaitForTextInstallerStage = $script:ColdStub.InstallerStage
                $script:Fail.WaitForTextInstallerStageSeconds = $script:ColdStub.InstallerStageSeconds
                $script:Fail.LastFailedStepStartedUtc = $script:ColdStub.StepStartedUtc
                return $false
            }
        }
    }
    BeforeEach {
        $script:coldStub = & $script:coldModule {
            $script:ColdStub = @{Calls=[Collections.Generic.List[string]]::new();Events=[Collections.Generic.List[object]]::new();State='running';Failure='';Attempts=0;SuccessAttempt=2;OcrTail='Display output is not active.';Pattern=$null;Flood=$null;EmitOpinion=$true;EvidenceAvailable=$true
                DisplayStall=$null;Seen=[Collections.Generic.List[object]]::new();FailedAction='waitForTextWithNudge';FailurePhase='wait'
                KernelStallEnd=$null;Livelock=$null;InstallerStage='';InstallerStageSeconds=0;StepStartedUtc=$null;EvidenceStepStartedUtc=$null}
            return $script:ColdStub
        }
        $script:coldContext = @{
            Step=@{maxAttempts=3;restartVmBeforeRetry='coldPowerCycle';steps=@(
                @{action='pressKey';name='Enter'}, @{action='waitForSeconds';seconds=2},
                @{action='waitForTextWithNudge';pattern='guest login:';nudgeKey='Enter';nudgeIntervalSeconds=60}
            );stepsAfterVmRestart=@(@{action='waitForSeconds';seconds=15})}
            InvokeStepBlock=(& $script:coldModule {$script:ColdInvokeSteps})
            StepNum=2;StepCount=16;Description='installed login';VMName='test-vm';HostType='host.macos.utm'
        }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'cold-restarts <Provider> <Architecture> after preserving failure evidence' -ForEach @(
        @{Provider='host.windows.hyper-v';Architecture='X64'}, @{Provider='host.windows.hyper-v';Architecture='Arm64'},
        @{Provider='host.ubuntu.kvm';Architecture='X64'}, @{Provider='host.macos.utm';Architecture='Arm64'}
    ) {
        $script:coldContext.HostType = $Provider
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,stop,start,console,ring,recovery,attempt'
        $script:coldStub.StopBudget | Should -Be 20
        $script:coldStub.Diagnostic.consoleSecondOpinion.Verdict | Should -BeExactly 'guest-wedged'
        $script:coldStub.Diagnostic.vmState | Should -BeExactly 'running'
        $script:coldStub.Diagnostic.captureStartupSnapshot | Should -BeTrue
        $script:coldStub.Events[0].consoleSecondOpinion.CpuPercent | Should -Be 1080
        $script:coldContext.ColdPowerCycleResult.outcome | Should -BeExactly 'succeeded'
        $script:coldContext.ColdPowerCycleResult.initialState | Should -BeExactly 'running'
        $script:coldContext.ColdPowerCycleResult.stoppedState | Should -BeExactly 'stopped'
        $script:coldContext.ColdPowerCycleResult.runningState | Should -BeExactly 'running'
    }
    It 'fails closed on <Failure> without replaying the attempt' -ForEach @(
        @{Failure='initial-state';Calls='attempt,evidence';Phase='initial-state';Reason='vm-not-running'},
        @{Failure='stop';Calls='attempt,evidence,stop';Phase='stop-request';Reason='force-stop-failed'},
        @{Failure='stop-state';Calls='attempt,evidence,stop';Phase='stopped-state';Reason='stop-unconfirmed'},
        @{Failure='start';Calls='attempt,evidence,stop,start';Phase='start-request';Reason='start-failed'},
        @{Failure='start-record';Calls='attempt,evidence,stop,start';Phase='start-request';Reason='start-failed'},
        @{Failure='start-state';Calls='attempt,evidence,stop,start';Phase='running-state';Reason='start-unconfirmed'},
        @{Failure='console';Calls='attempt,evidence,stop,start,console';Phase='console';Reason='console-reconnect-failed'}
    ) {
        $script:coldStub.Failure = $Failure
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly $Calls
        $script:coldStub.Attempts | Should -Be 1
        $script:coldContext.ColdPowerCycleResult.outcome | Should -BeExactly 'failed'
        $script:coldContext.ColdPowerCycleResult.phase | Should -BeExactly $Phase
        $script:coldContext.ColdPowerCycleResult.reasonCode | Should -BeExactly $Reason
        $script:coldStub.Events[-1].event | Should -BeExactly 'retry_vm_restart'
        $script:coldStub.Events[-1].recovery.reasonCode | Should -BeExactly $Reason
    }
    It 'refuses unfinished installer recovery on <Provider> before touching the VM' -ForEach @(
        @{Provider='host.macos.utm'}, @{Provider='host.ubuntu.kvm'}
    ) {
        $script:coldContext.HostType = $Provider
        $script:coldStub.OcrTail = 'start: subiquity/Install/install/curtin_install'
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:coldStub.Events[-2].reason | Should -BeExactly 'installer-media-selection-unsupported'
        $script:coldStub.Events[-2].requiredCommand | Should -BeExactly 'Set-VMInstallerMediaFirstBoot'
    }
    It 'refuses unfinished installer recovery on <Provider> after the marker <Change>' -ForEach @(
        @{Provider='host.ubuntu.kvm';Change='scrolls away';Tail='curtin in-target --target=/target -- apt-get install -y iptables-persistent'},
        @{Provider='host.ubuntu.kvm';Change='becomes unreadable';Tail=''},
        @{Provider='host.macos.utm';Change='scrolls away';Tail='curtin in-target --target=/target -- apt-get install -y iptables-persistent'},
        @{Provider='host.macos.utm';Change='becomes unreadable';Tail=''}
    ) {
        $script:coldContext.HostType = $Provider
        $script:coldStub.OcrTail = $Tail
        $script:coldStub.InstallerStage = 'start: subiquity/Install/install/postinstall/restore_apt_config'
        $script:coldStub.InstallerStageSeconds = 107
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:coldStub.Attempts | Should -Be 1
        $script:coldStub.Events[0].installerRunning | Should -BeTrue
        $script:coldStub.Events[0].installerStage | Should -BeExactly $script:coldStub.InstallerStage
        $script:coldStub.Events[-2].reason | Should -BeExactly 'installer-media-selection-unsupported'
        $script:coldStub.Events[-2].requiredCommand | Should -BeExactly 'Set-VMInstallerMediaFirstBoot'
        @($script:coldStub.Events | Where-Object event -EQ 'retry_vm_restart').Count | Should -Be 0
    }
    It 'requires installer-media selection before starting a guest with a retained installer stage (selection succeeds: <SelectionSucceeds>)' -ForEach @(
        @{SelectionSucceeds=$true}, @{SelectionSucceeds=$false}
    ) {
        . $script:coldModule {
            function Set-VMInstallerMediaFirstBoot {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($VMName, 'Record fixture installer selection')
                $script:ColdStub.Calls.Add('media')
                $script:ColdStub.State | Should -BeExactly 'stopped'
                return $script:ColdStub.SelectionSucceeds
            }
        }
        try {
            $script:coldContext.HostType = 'host.windows.hyper-v'
            $script:coldStub.SelectionSucceeds = $SelectionSucceeds
            $script:coldStub.OcrTail = 'curtin in-target --target=/target -- apt-get install -y iptables-persistent'
            $script:coldStub.InstallerStage = 'start: subiquity/Install/install/postinstall/restore_apt_config'
            (& $script:coldHandler $script:coldContext) | Should -Be $SelectionSucceeds
            $expectedCalls = if ($SelectionSucceeds) { 'attempt,evidence,stop,media,start,console,ring,recovery,attempt' } else { 'attempt,evidence,stop,media' }
            ($script:coldStub.Calls -join ',') | Should -BeExactly $expectedCalls
            $script:coldStub.Events[0].installerRunning | Should -BeTrue
            if (-not $SelectionSucceeds) {
                $script:coldContext.ColdPowerCycleResult.reasonCode | Should -BeExactly 'installer-media-selection-failed'
            }
        } finally {
            & $script:coldModule { Remove-Item -LiteralPath Function:\Set-VMInstallerMediaFirstBoot }
        }
    }
    It 'does not restart or replay an explicit installer error' {
        $script:coldStub.Pattern = 'install_fail.crash'
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
    }
    It 'rejects credential replay before executing any step' {
        $script:coldContext.Step.steps = @(@{action='passwdPrompt';pattern='Password:';text='not-a-real-password'}) + $script:coldContext.Step.steps
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        $script:coldStub.Calls.Count | Should -Be 0
    }
    It 'cold-restarts an untyped retype-password wait and replays from login' {
        $script:coldContext.Step.steps += @(
            @{action='passwdPrompt';pattern='guest login:';text='user'},
            @{action='passwdPrompt';pattern='Password:';text='old'},
            @{action='passwdPrompt';pattern=@('Current password','urrent password:');text='old'},
            @{action='passwdPrompt';pattern='New password';text='new'},
            @{action='passwdPrompt';pattern=@('Retype new password','etype new password:');text='new'}
        )
        $script:coldStub.FailedAction = 'passwdPrompt'
        $script:coldStub.DisplayStall = @{driver='virtio_gpu';reports=8;spanSeconds=30.9;consoleUnchangedSeconds=30}
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,stop,start,console,ring,recovery,attempt'
        $first = @($script:coldStub.Seen[0])
        $second = @($script:coldStub.Seen[-1])
        @($first | Where-Object action -EQ 'passwdPrompt').Count | Should -Be 5
        @($first | Where-Object action -EQ 'passwdPrompt' | Where-Object { -not $_.endWaitOnDisplayStall }).Count | Should -Be 0
        $second[2].pattern | Should -BeExactly 'guest login:'
        $second[-1].pattern | Should -Be @('Retype new password','etype new password:')
        $script:coldContext.Step.steps[-1].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse
        @($script:coldStub.Events | Where-Object event -EQ 'retry_vm_restart')[0].guestDisplayStall.driver | Should -BeExactly 'virtio_gpu'
    }
    It 'does not replay the password flow after <Case>' -ForEach @(
        @{Case='the current prompt began typing';Phase='input';Stall=$true;Pattern=''},
        @{Case='an ordinary password timeout';Phase='wait';Stall=$false;Pattern=''},
        @{Case='an explicit password rejection';Phase='wait';Stall=$true;Pattern='passwords do not match'}
    ) {
        $script:coldContext.Step.steps += @(
            @{action='passwdPrompt';pattern='guest login:';text='user'},
            @{action='passwdPrompt';pattern='Password:';text='old'},
            @{action='passwdPrompt';pattern=@('Current password','urrent password:');text='old'},
            @{action='passwdPrompt';pattern='New password';text='new'},
            @{action='passwdPrompt';pattern=@('Retype new password','etype new password:');text='new'}
        )
        $script:coldStub.FailedAction = 'passwdPrompt'
        $script:coldStub.FailurePhase = $Phase
        $script:coldStub.Pattern = $Pattern
        $script:coldStub.DisplayStall = if ($Stall) { @{driver='hyperv_drm';reports=8} } else { $null }
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        @($script:coldStub.Events | Where-Object event -EQ 'retry_suppressed')[0].reason | Should -BeExactly 'login-wait-failure-not-restartable'
    }
    It 'refuses a password flow that could replay work after the confirming entry' {
        $script:coldContext.Step.steps += @(
            @{action='passwdPrompt';pattern='guest login:';text='user'},
            @{action='passwdPrompt';pattern='Password:';text='old'},
            @{action='passwdPrompt';pattern=@('Current password','urrent password:');text='old'},
            @{action='passwdPrompt';pattern='New password';text='new'},
            @{action='passwdPrompt';pattern=@('Retype new password','etype new password:');text='new'},
            @{action='waitForTextWithNudge';pattern='guest login:';nudgeKey='Enter';nudgeIntervalSeconds=60}
        )
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        $script:coldStub.Calls.Count | Should -Be 0
    }
    It 'rejects unsafe recovery <Reason> before executing any step' -ForEach @(
        @{Reason='credential input';Action='passwdPrompt';Sensitive=$false;Skips=@('Bahasa Indonesia','subiquity/Install/install/configure_apt','subiquity/Install/install/curtin_install')},
        @{Reason='sensitive boot input';Action='waitForAndEnter';Sensitive=$true;Skips=@('Bahasa Indonesia','subiquity/Install/install/configure_apt','subiquity/Install/install/curtin_install')},
        @{Reason='blind answer at a later installer stage';Action='waitForAndEnter';Sensitive=$false;Skips=@('Bahasa Indonesia')}
    ) {
        $script:coldContext.Step.stepsAfterVmRestart = @(@{
            action=$Action;sensitive=$Sensitive;text='yes';noSegmentMatch=$true;blindAfterSeconds=120;blindSkipPattern=$Skips
            pattern=@('Continue with autoinstall?','guest login:','subiquity/Install/install/configure_apt','subiquity/Install/install/curtin_install')
            skipInputPattern=@('guest login:','subiquity/Install/install/configure_apt','subiquity/Install/install/curtin_install')
        })
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        $script:coldStub.Calls.Count | Should -Be 0
        $script:coldStub.Events[0].reason | Should -BeExactly 'cold-power-cycle-unsafe-step-shape'
        $script:coldStub.Events[0].timestamp | Should -Not -BeNullOrEmpty
    }
    It 'caps provider-neutral recovery at three attempts' {
        $script:coldContext.Step.maxAttempts = 99
        $script:coldStub.SuccessAttempt = 99
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        $script:coldStub.Attempts | Should -Be 3
        @($script:coldStub.Calls | Where-Object {$_ -eq 'stop'}).Count | Should -Be 2
    }
    It 'preserves ordinary retry capture without native startup diagnostics' {
        $script:coldContext.Step.restartVmBeforeRetry = ''
        $script:coldStub.EmitOpinion = $false
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,attempt'
        $script:coldStub.Diagnostic | Should -BeNullOrEmpty
    }
    It 'retains an ordinary wait opinion without authorizing native startup capture' {
        $script:coldContext.Step.restartVmBeforeRetry = ''
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,attempt'
        $script:coldStub.Diagnostic.consoleSecondOpinion.Verdict | Should -BeExactly 'guest-wedged'
        $script:coldStub.Diagnostic.captureStartupSnapshot | Should -BeFalse
        $script:coldStub.Diagnostic.captureStartupSnapshot | Should -BeOfType ([bool])
    }
    It 'refuses a generic power cycle when failure evidence cannot be preserved' {
        $script:coldStub.EvidenceAvailable = $false
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence'
        $script:coldStub.Events[-2].reason | Should -BeExactly 'startup-diagnostics-unavailable'
    }
    It 'hands the login wait a copy that also ends on a display stall, and leaves the recovery steps and the declared step alone' {
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        $attemptSteps = @($script:coldStub.Seen[0])
        $attemptSteps[2].endWaitOnDisplayStall | Should -BeTrue
        $attemptSteps[0].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse -Because 'only the login wait can be ended and restarted'
        @($script:coldStub.Seen[1])[0].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse -Because 'a post-restart recovery wait has no further restart behind it'
        $script:coldContext.Step.steps[2].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse
    }
    It 'cold-restarts after a login wait that ended on a display stall and names the stall on the attempt and restart records' {
        $script:coldStub.DisplayStall = [ordered]@{ driver = 'hyperv_drm'; reports = 16; spanSeconds = 74.752; consoleUnchangedSeconds = 30; waitedSeconds = 95 }
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence,stop,start,console,ring,recovery,attempt'
        $attemptEvent = @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_attempt' })[0]
        $attemptEvent.guestDisplayStall.driver | Should -BeExactly 'hyperv_drm'
        $attemptEvent.guestDisplayStall.reports | Should -Be 16
        $restartEvent = @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_vm_restart' })[0]
        $restartEvent.ok | Should -BeTrue
        $restartEvent.guestDisplayStall.driver | Should -BeExactly 'hyperv_drm'
    }
    It 'preserves the display-stall class through real retry exhaustion' {
        $script:coldStub.SuccessAttempt = 99
        $script:coldStub.DisplayStall = @{driver='hyperv_drm';reports=8;spanSeconds=30;consoleUnchangedSeconds=30}
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        $terminal = @($script:coldStub.Events | Where-Object event -EQ 'retry_exhausted')
        $terminal.Count | Should -Be 1
        $terminal[0].failureClass | Should -BeExactly 'guest_display_stalled'
        & $script:coldModule { $script:Fail.LastInnerFailureClass } | Should -BeExactly 'guest_display_stalled'
        @(& $script:coldModule { $script:Fail.LastInnerSuggestedRecoveries }) | Should -Be @('restart_from_snapshot', 'pause_and_inspect')
    }
    It 'records no display stall on an ordinary login timeout' {
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_attempt' })[0].guestDisplayStall | Should -BeNullOrEmpty
        @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_vm_restart' })[0].guestDisplayStall | Should -BeNullOrEmpty
    }
    It 'names the attempt''s kernel-stall end, its processors and the installer stage when recovery is refused' {
        Import-Module (Join-Path $PSScriptRoot 'Test.EventSchema.psm1') -Force -DisableNameChecking
        # A two-processor guest whose wait ended on processor 1 servicing no
        # interrupt, with processor 0 in the storm shape too.
        $script:coldStub.KernelStallEnd = [ordered]@{ basis = 'no-interrupts-serviced'; processors = [string[]]@('1'); noInterruptsServicedSeconds = 195
            kinds = [string[]]@('rcu-stall'); outputStaticSeconds = 230; recorderUploadAgeSeconds = $null; waitedSeconds = 442 }
        $script:coldStub.Livelock = [pscustomobject]@{ Verdict = 'not-livelocked'; LivelockedSeconds = 0; VirtualProcessors = 0
            ProcessorWindow = [pscustomobject]@{ StormedProcessors = @('0', '1'); NoInterruptsServicedProcessors = @('1')
                Processors = @([pscustomobject]@{ Processor = '0'; Stormed = $true; NoInterruptsServicedSeconds = 0 }
                    [pscustomobject]@{ Processor = '1'; Stormed = $true; NoInterruptsServicedSeconds = 195 }) } }
        $script:coldStub.InstallerStage = 'start: subiquity/Install/install/postinstall/restore_apt_config'
        $script:coldStub.InstallerStageSeconds = 250
        (& $script:coldHandler $script:coldContext) | Should -BeFalse
        ($script:coldStub.Calls -join ',') | Should -BeExactly 'attempt,evidence' -Because 'an unfinished installation cannot restart without installer-media selection'
        $attemptEvent = @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_attempt' })[0]
        $attemptEvent.guestKernelStallEnd.basis | Should -BeExactly 'no-interrupts-serviced'
        $attemptEvent.guestKernelStallEnd.waitedSeconds | Should -Be 442
        @($attemptEvent.stormedProcessors) | Should -Be @('0', '1')
        $attemptEvent.noInterruptsServicedProcessors -is [array] | Should -BeTrue -Because 'a one-processor list stays a list on the event'
        @($attemptEvent.noInterruptsServicedProcessors) | Should -Be @('1')
        $attemptEvent.longestNoInterruptsServicedSeconds | Should -Be 195
        $attemptEvent.installerStage | Should -BeExactly 'start: subiquity/Install/install/postinstall/restore_apt_config'
        $attemptEvent.installerStageUnchangedSeconds | Should -Be 250
        $attemptEvent.installerRunning | Should -BeTrue
        $script:coldStub.Events[-2].reason | Should -BeExactly 'installer-media-selection-unsupported'
        $attemptEvent.failureClass | Should -BeExactly 'ocr_timeout' -Because 'the attempt keeps the verb''s class'
        @(Test-CycleEventSchema -Record $attemptEvent) | Should -BeNullOrEmpty
    }
    It 'records an unmeasured processor window as null and no installer stage as empty' {
        Import-Module (Join-Path $PSScriptRoot 'Test.EventSchema.psm1') -Force -DisableNameChecking
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        $attemptEvent = @($script:coldStub.Events | Where-Object { $_.event -eq 'retry_attempt' })[0]
        foreach ($field in 'guestKernelStallEnd', 'stormedProcessors', 'noInterruptsServicedProcessors', 'longestNoInterruptsServicedSeconds') {
            $attemptEvent.ContainsKey($field) | Should -BeTrue -Because "$field is always present, so absence never reads as a missing producer"
            $attemptEvent[$field] | Should -BeNullOrEmpty
        }
        $attemptEvent.installerStage | Should -BeExactly ''
        $attemptEvent.installerStageUnchangedSeconds | Should -Be 0
        @(Test-CycleEventSchema -Record $attemptEvent) | Should -BeNullOrEmpty
    }
    It 'hands the evidence snapshot the failed step''s start' {
        $script:coldStub.StepStartedUtc = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        (& $script:coldHandler $script:coldContext) | Should -BeTrue
        $script:coldStub.EvidenceStepStartedUtc | Should -Be ([datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc))
    }
}

Describe 'A password prompt distinguishes an untyped display stall from an input failure' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        . (Get-Module Test.SequenceHandler) {
            function Wait-ForText {
                param($HostType, $VMName, $Pattern, $TimeoutSeconds, $PollSeconds, $FreshMatch, $FreshMatchTailLines,
                    [switch]$SinceStepStart, [switch]$NoSegmentMatch, $FailurePattern, [switch]$EndOnDisplayStall)
                $null = $HostType, $VMName, $Pattern, $TimeoutSeconds, $PollSeconds, $FreshMatch, $FreshMatchTailLines,
                    $SinceStepStart, $NoSegmentMatch, $FailurePattern, $EndOnDisplayStall
                throw 'The password wait must be mocked.'
            }
        }
        $script:passwordHandler = (Get-SequenceAction -Name passwdPrompt).Handler
    }
    BeforeEach {
        Mock Wait-ForText -ModuleName Test.SequenceHandler { return $false }
        Mock Send-TabNavigation -ModuleName Test.SequenceHandler { }
        Mock Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler { return $false }
        $script:passwordContext = @{
            Step=@{pattern='Retype new password';text='fixture-password';endWaitOnDisplayStall=$true}
            Vars=@{};ExpandVariable={param($value,$variables) $null=$variables; $value}
            DefaultTimeoutSeconds=60;DefaultPollSeconds=1;HostType='host.macos.utm';VMName='test-vm';ShowSensitive=$false
        }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'passes the display-stall switch to its wait and types nothing when that wait fails' {
        (& $script:passwordHandler $script:passwordContext) | Should -BeFalse
        Should-Invoke Wait-ForText -ModuleName Test.SequenceHandler -Times 1 -Exactly -ParameterFilter { $EndOnDisplayStall }
        Should-Invoke Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler -Times 0 -Exactly
        & (Get-Module Test.SequenceHandler) { $script:Fail.StepFailurePhase } | Should -BeExactly 'wait'
    }
    It 'records the input phase once the prompt has started typing' {
        Mock Wait-ForText -ModuleName Test.SequenceHandler { return $true }
        (& $script:passwordHandler $script:passwordContext) | Should -BeFalse
        Should-Invoke Invoke-TypeDrainEnter -ModuleName Test.SequenceHandler -Times 1 -Exactly
        & (Get-Module Test.SequenceHandler) { $script:Fail.StepFailurePhase } | Should -BeExactly 'input'
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
        $seen[1].endWaitOnDisplayStall | Should -BeTrue
        $script:loginContext.Step.steps[1].ContainsKey('endWaitOnGuestLivelock') | Should -BeFalse
        $script:loginContext.Step.steps[1].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse
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
        $seen[1].ContainsKey('endWaitOnDisplayStall') | Should -BeFalse
    }
    It 'turns the step flag into the Wait-ForText switch, and nothing at all without it' {
        $context = @{ Step = @{ pattern = 'x'; endWaitOnGuestLivelock = $true }; Vars = @{}; ExpandVariable = { param($v) $v }; DefaultTimeoutSeconds = 5; DefaultPollSeconds = 1 }
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        $p.livelockExit.EndOnGuestLivelock | Should -BeTrue
        $context.Step.Remove('endWaitOnGuestLivelock')
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        $p.livelockExit.Count | Should -Be 0
    }
    It 'turns the display-stall flag into its own Wait-ForText switch' {
        $context = @{ Step = @{ pattern = 'x'; endWaitOnGuestLivelock = $true; endWaitOnDisplayStall = $true }; Vars = @{}; ExpandVariable = { param($v) $v }; DefaultTimeoutSeconds = 5; DefaultPollSeconds = 1 }
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        $p.livelockExit.EndOnGuestLivelock | Should -BeTrue
        $p.livelockExit.EndOnDisplayStall | Should -BeTrue
        $context.Step.Remove('endWaitOnGuestLivelock')
        $p = & $script:loginHandlerModule { param($c) Resolve-WaitForTextStepParam -Context $c } $context
        @($p.livelockExit.Keys) | Should -Be @('EndOnDisplayStall')
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

# See https://yuruna.link/42885ada-0014
Describe 'startVm waits for an install''s own power-off' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        $script:startStub = @{ State = 'running'; Calls = [Collections.Generic.List[string]]::new() }
        # Dot-sourced into the module, as the stopVm stubs above are, so they
        # shadow the host contract for this module only.
        . (Get-Module Test.SequenceHandler) {
            function Get-VMState {
                param([string]$VMName)
                $null = $VMName
                return $script:StartStub.State
            }
            function Start-VM {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([hashtable])]
                param([string]$VMName)
                if (-not $PSCmdlet.ShouldProcess($VMName, 'stub start')) { return @{ success = $false } }
                $script:StartStub.Calls.Add('start')
                return @{ success = $true; errorMessage = $null }
            }
        }
        & (Get-Module Test.SequenceHandler) { $script:StartStub = $args[0] } $script:startStub
        $script:startHandler = (Get-SequenceAction -Name startVm).Handler
        $script:startContext = @{
            Step = @{}
            StepNum = 2; StepCount = 20; Description = 'Wait for the install to power off, then cold-start the installed system'
            VMName = 'test-vm'; HostType = 'host.macos.utm'; GuestKey = 'guest.ubuntu.server.26'
            LogDir = $TestDrive; ScreenshotDir = $TestDrive
            ExpandVariable = { param($v) $v }; Vars = @{}
        }
    }
    BeforeEach {
        $script:startStub.State = 'running'; $script:startStub.Calls.Clear()
        $script:startContext.Step = @{ timeoutSeconds = 1; frameIntervalSeconds = 0; installPowerOff = $true }
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped = $null; $state.FirstGuestSilenceUtc = $null; $state.FirstGuestSilenceSource = $null
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'files an install that never powered off without calling the guest silent' {
        (& $script:startHandler $script:startContext) | Should -BeFalse
        $script:startStub.Calls.Count | Should -Be 0 -Because 'a VM still installing must not be started again'
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped.installPowerOff | Should -BeTrue -Because 'the failure filing reads this to keep the start verb''s provisioning_failure'
        $state.StepVmNotStopped.action | Should -BeExactly 'startVm'
        $state.StepVmNotStopped.observedState | Should -BeExactly 'running'
        [int]$state.StepVmNotStopped.waitedSeconds | Should -BeGreaterOrEqual 1
        $state.FirstGuestSilenceUtc | Should -BeNullOrEmpty -Because 'an installer still drawing its own screen is not a guest that stopped answering'
        $state.FirstGuestSilenceSource | Should -BeNullOrEmpty
    }
    It 'cold-starts the VM once the install powered itself off' {
        $script:startStub.State = 'stopped'
        (& $script:startHandler $script:startContext) | Should -BeTrue
        ($script:startStub.Calls -join ',') | Should -BeExactly 'start'
        (Get-SequenceFailureState).StepVmNotStopped | Should -BeNullOrEmpty
    }
    It 'ends the wait on a declared failure pattern and files it as a pattern match' {
        $frame = Join-Path $TestDrive 'installer-error.png'
        Set-Content -LiteralPath $frame -Value 'png'
        Mock -ModuleName Test.SequenceHandler Save-GuestConsoleFrame {
            @{ Path = $frame; Text = 'finish: subiquity/Error/run'; AllText = "== tesseract ==`nAn error occurred. PRESS ENTER to start a shell"; Hash = 'h' }
        }.GetNewClosure()
        $script:startContext.Step = @{ timeoutSeconds = 30; frameIntervalSeconds = 1; installPowerOff = $true
            failurePatterns = @('install_fail.crash', 'Press enter to start a shell') }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        (& $script:startHandler $script:startContext) | Should -BeFalse
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'an installer waiting at a shell will never power off, so the deadline must not be spent'
        $script:startStub.Calls.Count | Should -Be 0 -Because 'a failed install must not be started again'
        $state = Get-SequenceFailureState
        $state.WaitForTextMatchedFailurePattern | Should -BeExactly 'Press enter to start a shell' -Because 'the match is read across every OCR engine and ignores case'
        $state.StepVmNotStopped | Should -BeNullOrEmpty -Because 'this is an installer that reported its failure, not a VM that never stopped'
        $state.FirstGuestSilenceUtc | Should -BeNullOrEmpty
    }
    It 'keeps waiting while no frame shows a declared failure pattern' {
        Mock -ModuleName Test.SequenceHandler Save-GuestConsoleFrame {
            @{ Path = ''; Text = 'installing'; AllText = 'installing'; Hash = 'h' }
        }
        $script:startContext.Step = @{ timeoutSeconds = 2; frameIntervalSeconds = 1; installPowerOff = $true; failurePatterns = 'Press enter to start a shell' }
        (& $script:startHandler $script:startContext) | Should -BeFalse
        $state = Get-SequenceFailureState
        $state.WaitForTextMatchedFailurePattern | Should -BeNullOrEmpty
        $state.StepVmNotStopped.installPowerOff | Should -BeTrue -Because 'with no match the wait ends at the deadline as before'
    }
    It 'still marks a guest that ignored a requested shutdown as silent' {
        $script:startContext.Step = @{ timeoutSeconds = 1; frameIntervalSeconds = 0 }
        (& $script:startHandler $script:startContext) | Should -BeFalse
        $state = Get-SequenceFailureState
        $state.StepVmNotStopped.Contains('installPowerOff') | Should -BeFalse -Because 'a step that requested the shutdown is filed as a guest that ignored it'
        $state.FirstGuestSilenceUtc | Should -Not -BeNullOrEmpty
        $state.FirstGuestSilenceSource | Should -Match '^startVm:'
    }
}

Describe 'saveDiskSnapshot carries the guest''s SSH host key pin to its new name' {
    # The save renames the working VM to the snapshot id. The guest keeps its
    # host keys, so its pin has to follow it: the pin left under the id by a
    # guest of an earlier cycle refuses the renamed guest at the next SSH step.
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        $script:saveStub = @{ Ok = $true; Moves = [Collections.Generic.List[string]]::new() }
        . (Get-Module Test.SequenceHandler) {
            function Save-VMDiskSnapshot {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([bool])]
                param([string]$VMName, [string]$Id)
                if (-not $PSCmdlet.ShouldProcess("$VMName/$Id", 'stub snapshot save')) { return $false }
                return $script:SaveStub.Ok
            }
            function Move-GuestHostKeyPin {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$VMName, [string]$NewVMName)
                if ($PSCmdlet.ShouldProcess($NewVMName, 'stub pin move')) { $script:SaveStub.Moves.Add("$VMName>$NewVMName") }
            }
            function Write-SnapshotManifest {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([string])]
                param([string]$VMName, [string]$SnapshotId, [string]$HostType, [hashtable]$Extra)
                $null = $HostType, $Extra
                if (-not $PSCmdlet.ShouldProcess("$VMName/$SnapshotId", 'stub manifest write')) { return '' }
                return 'manifest.json'
            }
        }
        & (Get-Module Test.SequenceHandler) { $script:SaveStub = $args[0] } $script:saveStub
        $script:saveHandler = (Get-SequenceAction -Name saveDiskSnapshot).Handler
    }
    BeforeEach {
        $script:saveStub.Ok = $true; $script:saveStub.Moves.Clear()
        $script:saveContext = @{
            Step = @{ id = 'amisad-build' }; VMName = 'test-guest.ubuntu.server.24-01'; HostType = 'host.ubuntu.kvm'
            ExpandVariable = { param($v) $v }; Vars = @{}
        }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'moves the pin from the build name to the snapshot id when the save renames the VM' {
        (& $script:saveHandler $script:saveContext 6>$null) | Should -BeTrue
        $script:saveContext.NewVMName | Should -BeExactly 'amisad-build'
        @($script:saveStub.Moves) | Should -BeExactly @('test-guest.ubuntu.server.24-01>amisad-build')
    }

    It 'leaves the pins alone when the save fails or keeps the name' {
        $script:saveStub.Ok = $false
        (& $script:saveHandler $script:saveContext 6>$null) | Should -BeFalse
        $script:saveContext.VMName = 'amisad-build'
        $script:saveStub.Ok = $true
        (& $script:saveHandler $script:saveContext 6>$null) | Should -BeTrue
        $script:saveStub.Moves.Count | Should -Be 0
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

Describe 'The ssh verbs publish their proof that a failed step did nothing' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        # Dot-sourced into the module so the stubs shadow the transport for this
        # module only and die with it in AfterAll.
        . (Get-Module Test.SequenceHandler) {
            function Invoke-GuestSsh {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($VMName, $GuestKey, $Command, $TimeoutSeconds, $TransportRetryCount, $DetachToken)
                return $script:SshProofResult
            }
            function Get-FetchExecutionContext {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($Context, $CommandLine)
                return @{ Command = [string]$CommandLine; Launch = [string]$CommandLine }
            }
            function Save-FetchExecutionEvidence {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($Context, $Succeeded, $ElapsedSeconds)
            }
            function Get-GuestRunToken { return 'fixture-token' }
        }
        function Set-SshProofResult {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: sets the stub result inside the module under test.')]
            param([hashtable]$Result)
            & (Get-Module Test.SequenceHandler) { $script:SshProofResult = $args[0] } $Result
        }
        $script:proofContext = @{
            Step = @{ command = 'run.sh'; timeoutSeconds = 5; detach = $false }; Vars = @{}
            ExpandVariable = { param($Value, $Vars) $null = $Vars; $Value }
            DefaultTimeoutSeconds = 5; ShowSensitive = $false; VMName = 'vm1'; GuestKey = 'guest.ubuntu.server.24'
            StepInvocationId = 'step-1'; SequenceInvocationId = 'seq-1'; StepNum = 3; SequencePath = 'x.yml'
        }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }
    BeforeEach { (Get-SequenceFailureState).StepEffect = $null }

    It 'sshExec proves nothing ran when ssh never opened a session' {
        Set-SshProofResult @{ success = $false; exitCode = -2; output = 'the command never ran'; addressResolved = $false; transportLost = $false }
        $ok = & (Get-SequenceAction -Name sshExec).Handler $script:proofContext 3>$null
        Assert-False $ok 'the step fails'
        $proof = (Get-SequenceFailureState).StepEffect
        Assert-Equal -Expected 'none-proven' -Actual $proof.effect
        Assert-Equal -Expected 'address-unresolved' -Actual $proof.source
        Assert-Equal -Expected 'step-1' -Actual $proof.stepInvocationId -Because 'the proof names the step that published it'
    }
    It 'sshExec proves nothing for a status the guest reported' {
        # The bare name was dialed and a far end answered: the command ran.
        Set-SshProofResult @{ success = $false; exitCode = 3; output = 'STASH UNREACHABLE'; addressResolved = $false; transportLost = $false }
        $null = & (Get-SequenceAction -Name sshExec).Handler $script:proofContext 3>$null
        Assert-True ($null -eq (Get-SequenceFailureState).StepEffect) 'a status from the guest is no proof'
    }
    It 'sshFetchAndExecute proves nothing ran when no source served the script' {
        Set-SshProofResult @{ success = $false; exitCode = 1; output = 'NONZERO SCRIPT EXIT: 1 (no fetch source)'; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        $proof = (Get-SequenceFailureState).StepEffect
        Assert-Equal -Expected 'none-proven' -Actual $proof.effect
        Assert-Equal -Expected 'no-source-served' -Actual $proof.source
    }
    It 'sshFetchAndExecute files the class a deploy entry point reported' {
        (Get-SequenceFailureState).StepDeployResult = $null
        $line = 'YURUNA_RESULT {"success":false,"failureClass":"chart_invalid","canonicalFailureClass":"plan_invalid","errorMessage":"lint failed"}'
        Set-SshProofResult @{ success = $false; exitCode = 1; output = "transcript`n$line`nNONZERO SCRIPT EXIT: 1"; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        $deploy = (Get-SequenceFailureState).StepDeployResult
        Assert-Equal -Expected 'plan_invalid' -Actual $deploy.failureClass
        Assert-Equal -Expected 'chart_invalid' -Actual $deploy.deployFailureClass
        Assert-Equal -Expected 'lint failed' -Actual $deploy.errorMessage
        (Get-SequenceFailureState).StepDeployResult = $null
    }
    It 'reads no deploy result from a malformed, unknown or non-canonical record' {
        $reader = & (Get-Module Test.SequenceHandler) { ${function:Get-GuestDeployResult} }
        foreach ($text in @('', 'YURUNA_RESULT {not json', 'YURUNA_RESULT {"canonicalFailureClass":"unknown"}',
                'YURUNA_RESULT {"canonicalFailureClass":"cluster_unreachable"}', '  YURUNA_RESULT {"canonicalFailureClass":"plan_invalid"}')) {
            Assert-True ($null -eq (& $reader -Output $text)) "no result from: $text"
        }
        $last = & $reader -Output ("YURUNA_RESULT {`"canonicalFailureClass`":`"plan_invalid`"}`nYURUNA_RESULT {`"canonicalFailureClass`":`"network_timeout`"}")
        Assert-Equal -Expected 'network_timeout' -Actual $last.failureClass -Because 'the last record is the run''s own'
    }
    It 'sshFetchAndExecute proves nothing for a script that ran and failed' {
        Set-SshProofResult @{ success = $false; exitCode = 1; output = 'NONZERO SCRIPT EXIT: 1'; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        Assert-True ($null -eq (Get-SequenceFailureState).StepEffect) 'a script that ran is no proof'
    }
    It 'sshFetchAndExecute records the apt-get update stall its output shows, sources included' {
        # The session output is the guest's own bytes, so it names the sources.
        $output = @(
            'Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '!! apt_retry: attempt 1/1 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            'NONZERO SCRIPT EXIT: 124'
        ) -join "`n"
        Set-SshProofResult @{ success = $false; exitCode = 124; output = $output; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        $stall = (Get-SequenceFailureState).StepAptUpdateStall
        Assert-Equal -Expected 'attempt 1 of 1 killed at 300s (rc=124); pending archive.ubuntu.com/ubuntu resolute-backports' -Actual $stall.summary
        Set-SshProofResult @{ success = $false; exitCode = 1; output = 'NONZERO SCRIPT EXIT: 1'; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        Assert-True ($null -eq (Get-SequenceFailureState).StepAptUpdateStall) 'the next failure without a stall clears the reading'
    }
    It 'sshFetchAndExecute records no apt-get update stall the next attempt recovered from' {
        $output = @(
            'Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '!! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            '>> apt_retry: attempt 2/2 for: sudo env apt-get update'
            'Hit:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            'project git clone failed after 3 attempts'
            'NONZERO SCRIPT EXIT: 1'
        ) -join "`n"
        Set-SshProofResult @{ success = $false; exitCode = 1; output = $output; addressResolved = $true; transportLost = $false; runLost = $false }
        $null = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $script:proofContext 3>$null
        Assert-True ($null -eq (Get-SequenceFailureState).StepAptUpdateStall) 'the step failed after the update recovered'
    }
}

# A guest that accepts connections but never answers ends the last detached
# re-attach of a step at the re-attach's own cap. Each module on the way has
# its own unit cases; this one carries that single result through all three --
# the transport, the verb's failure slots and the record's classification --
# because a slot the verb stops setting would leave every unit case green and
# file the step as script_error, whose pause never ends early.
Describe 'A detached step whose last re-attach its own cap cut off is filed as a lost transport' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        Import-Module (Join-Path (Split-Path -Parent $script:modulePath) 'Test.Ssh.psm1') -Force -DisableNameChecking -Global
        # Only the command line and the evidence file around the transport are
        # stood in; the verb reaches the real Invoke-GuestSsh.
        . (Get-Module Test.SequenceHandler) {
            function Get-FetchExecutionContext {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($Context, $CommandLine)
                return @{ Command = [string]$CommandLine; Launch = [string]$CommandLine }
            }
            function Save-FetchExecutionEvidence {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($Context, $Succeeded, $ElapsedSeconds)
            }
            function Get-GuestRunToken { return 'fixture-token' }
        }
    }
    AfterAll {
        Remove-Module Test.SequenceHandler -Force
        Remove-Module Test.Ssh -Force -ErrorAction SilentlyContinue
    }

    It 'files network_timeout with the reconnect recoveries, not the verb''s script_error' {
        Mock Get-GuestSshUser -ModuleName Test.Ssh { 'fixture-user' }
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { 'fixture-key' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { '127.0.0.1' }
        $script:AttachCalls = 0
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            $script:AttachCalls++
            # The first session drops; the re-attach then hears nothing from
            # the guest's supervisor before its own cap.
            if ($script:AttachCalls -eq 1) {
                return @{ Started = $true; ExitCode = 255; StdOut = ''; StdErr = 'Timeout, server 127.0.0.1 not responding.' }
            }
            return @{ Started = $true; ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true }
        }
        & (Get-Module Test.SequenceFailureState) { Reset-SequenceFailureSlot -Lifetime sequence }
        $context = @{
            Step = @{ command = 'run.sh'; timeoutSeconds = 5 }; Vars = @{}
            ExpandVariable = { param($Value, $Vars) $null = $Vars; $Value }
            DefaultTimeoutSeconds = 5; ShowSensitive = $false; VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'
            StepInvocationId = 'step-1'; SequenceInvocationId = 'seq-1'; StepNum = 3; SequencePath = 'x.yml'
        }
        $ok = & (Get-SequenceAction -Name sshFetchAndExecute).Handler $context 3>$null
        Assert-False $ok 'the step fails'
        Assert-Equal -Expected 2 -Actual $script:AttachCalls -Because 'the launch and one re-attach both ran through the real transport'
        $fail = Get-SequenceFailureState
        Assert-True ([bool]$fail.StepGuestTransportLost) 'the verb keeps the transport''s verdict for the record'
        # What the engine stamps on the state when a step's handler returns false.
        $fail.LastFailedAction = 'sshFetchAndExecute'
        $fail.LastFailureLabel = 'sshFetchAndExecute: "run.sh"'
        $fail.LastFailedStepNumber = 3
        try {
            $record = New-SequenceFailureRecord -Reason step -VMName 'fixture-vm' -GuestKey 'guest.ubuntu.server.26' -HostType 'host.ubuntu.kvm' `
                -SequencePath 'x.yml' -LogDir $TestDrive -TotalSteps 5
            Assert-Equal -Expected 'network_timeout' -Actual $record.File.failureClass
            Assert-Equal -Expected 'reconnect,retry_with_backoff' -Actual (@($record.File.suggestedRecoveries) -join ',')
        } finally { & (Get-Module Test.SequenceFailureState) { Reset-SequenceFailureSlot -Lifetime sequence } }
    }
}

Describe 'A typed command is acknowledged by what the console says' {
    BeforeAll { Import-Module $script:modulePath -Force -DisableNameChecking -Global }
    AfterAll { Remove-Module Test.SequenceHandler -Force }
    It 'does not take a cursor blink, which changes only the raw frame, for an echo' {
        $before = @{ Text = 'user@vm:~$ '; Hash = 'A' }
        $blink = @{ Text = "user@vm:~`$  "; Hash = 'B' }
        Test-GuestConsoleFrameChanged -Before $before -After $blink | Should -BeFalse
        $echo = @{ Text = 'user@vm:~$ echo hello'; Hash = 'C' }
        Test-GuestConsoleFrameChanged -Before $before -After $echo | Should -BeTrue
    }
    It 'falls back to the raw frame for a console the OCR could not read' {
        Test-GuestConsoleFrameChanged -Before @{ Text = ''; Hash = 'A' } -After @{ Text = ''; Hash = 'B' } | Should -BeTrue
        Test-GuestConsoleFrameChanged -Before @{ Text = ''; Hash = 'A' } -After @{ Text = ''; Hash = 'A' } | Should -BeFalse
    }
}

Describe 'retry stops on a send the host can never make' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.SequenceFailureState.psm1') -Force -DisableNameChecking -Global
        $script:InputRetryHandler = (Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'retry').ScriptBlock.GetScriptBlock()
    }
    BeforeEach {
        $script:InputRuntime = New-YurunaTestTempDir -Prefix 'yuruna-retry-input'
        $script:SavedInputRuntimeDir = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:InputRuntime
        $script:InputAttempts = 0
        $script:InputEvents = [Collections.Generic.List[object]]::new()
        $script:InputFaultKind = 'deterministic'
        $script:Fail = [ordered]@{
            LastFailureLabel = $null; LastFailureDescription = $null; LastFailedAction = $null; LastFailedStepNumber = 0
            LastFailedStepInvocationId = ''; StepHandlerError = $null; StepHostInputFault = $null
            WaitForTextMatchedFailurePattern = $null; WaitForTextConsoleFlood = $null
        }
        Set-Item -LiteralPath Function:\Test-Arm64HyperVColdPowerCycleMode -Value { return $false }
        Set-Item -LiteralPath Function:\Get-SequenceAction -Value {
            param([string]$Name)
            $null = $Name
            return [ordered]@{ FailureClass = 'host_io_blocked'; Severity = 'soft'; SuggestedRecoveries = @('retry_immediately') }
        }
        Set-Item -LiteralPath Function:\Get-PollDelay -Value { param([int]$Attempt) $null = $Attempt; return 0 }
        Set-Item -LiteralPath Function:\Format-YurunaOperatorMessage -Value {
            param($Key, $FormatValues, $FormatBindings, $Arguments)
            $null = $FormatValues, $FormatBindings, $Arguments
            return [string]$Key
        }
        Set-Item -LiteralPath Function:\Send-CycleEventSafely -Value { param($EventRecord) $script:InputEvents.Add($EventRecord) }
        $script:InputContext = @{
            Step = [ordered]@{ maxAttempts = 3; steps = @([ordered]@{ action = 'inputText' }) }
            InvokeStepBlock = {
                param($Steps, $ParentOrdinal, $ParentAction, $ParentAttempt)
                $null = $Steps, $ParentOrdinal, $ParentAction, $ParentAttempt
                $script:InputAttempts++
                $script:Fail.LastFailedAction = 'inputText'
                $script:Fail.LastFailureLabel = 'inputText'
                $script:Fail.LastFailedStepInvocationId = "leaf-$($script:InputAttempts)"
                $script:Fail.StepHostInputFault = [ordered]@{ action = 'Send-Text'; stepInvocationId = "leaf-$($script:InputAttempts)"
                    kind = $script:InputFaultKind; reason = 'unmappable-character'; transport = 'VNC'; detail = 'U+00E9 at 0'; delivered = 0; total = 1 }
                return $false
            }
            StepNum = 4; StepCount = 9; Description = 'type the password'; VMName = 'test-vm'; HostType = 'host.macos.utm'
        }
    }
    AfterEach {
        foreach ($functionName in 'Test-Arm64HyperVColdPowerCycleMode', 'Get-SequenceAction', 'Get-PollDelay',
            'Format-YurunaOperatorMessage', 'Send-CycleEventSafely') {
            Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
        }
        Restore-YurunaTestEnvironment -Saved $script:SavedInputRuntimeDir
        Remove-YurunaTestTempDir $script:InputRuntime
    }

    It 'makes one attempt and files the inner cause as plan_invalid' {
        Assert-False (& $script:InputRetryHandler $script:InputContext) 'the retry must fail'
        Assert-Equal -Expected 1 -Actual $script:InputAttempts -Because 'the next attempt would fail the same way'
        Assert-Equal -Expected 'plan_invalid' -Actual $script:Fail.LastInnerFailureClass
        Assert-Equal -Expected 'pause_and_inspect' -Actual @($script:Fail.LastInnerSuggestedRecoveries)[0]
        $exhausted = @($script:InputEvents | Where-Object { $_.event -eq 'retry_exhausted' })
        Assert-Equal -Expected 'deterministic-input-fault' -Actual $exhausted[0].retrySuppressionReason
        Assert-True ($script:Fail.LastFailureLabel -match 'deterministic-input-fault') "the label says why: $($script:Fail.LastFailureLabel)"
    }

    It 'keeps retrying a transient fault with the verb''s class' {
        $script:InputFaultKind = 'transient'
        Assert-False (& $script:InputRetryHandler $script:InputContext) 'the retry must fail'
        Assert-Equal -Expected 3 -Actual $script:InputAttempts
        Assert-Equal -Expected 'host_io_blocked' -Actual $script:Fail.LastInnerFailureClass
    }
}

Describe 'retry does not replay a click that may have landed' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.SequenceFailureState.psm1') -Force -DisableNameChecking -Global
        $script:ClickRetryHandler = (Get-HandlerScriptBlockAst -Path $script:modulePath -Name 'retry').ScriptBlock.GetScriptBlock()
    }
    BeforeEach {
        $script:ClickRuntime = New-YurunaTestTempDir -Prefix 'yuruna-retry-click'
        $script:SavedClickRuntimeDir = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:ClickRuntime
        $script:ClickAttempts = 0
        $script:ClickEvents = [Collections.Generic.List[object]]::new()
        $script:ClickFaultReason = 'delivery-unknown'
        $script:ClickFaultDelivered = -1
        $script:Fail = [ordered]@{
            LastFailureLabel = $null; LastFailureDescription = $null; LastFailedAction = $null; LastFailedStepNumber = 0
            LastFailedStepInvocationId = ''; StepHandlerError = $null; StepHostInputFault = $null
            WaitForTextMatchedFailurePattern = $null; WaitForTextConsoleFlood = $null
        }
        Set-Item -LiteralPath Function:\Test-Arm64HyperVColdPowerCycleMode -Value { return $false }
        Set-Item -LiteralPath Function:\Get-SequenceAction -Value {
            param([string]$Name)
            $null = $Name
            return [ordered]@{ FailureClass = 'ocr_timeout'; Severity = 'hard'; SuggestedRecoveries = @('restart_from_snapshot') }
        }
        Set-Item -LiteralPath Function:\Get-PollDelay -Value { param([int]$Attempt) $null = $Attempt; return 0 }
        Set-Item -LiteralPath Function:\Format-YurunaOperatorMessage -Value {
            param($Key, $FormatValues, $FormatBindings, $Arguments)
            $null = $FormatValues, $FormatBindings, $Arguments
            return [string]$Key
        }
        Set-Item -LiteralPath Function:\Send-CycleEventSafely -Value { param($EventRecord) $script:ClickEvents.Add($EventRecord) }
        $script:ClickContext = @{
            Step = [ordered]@{ maxAttempts = 3; steps = @([ordered]@{ action = 'tapOn'; label = 'Next' }) }
            InvokeStepBlock = {
                param($Steps, $ParentOrdinal, $ParentAction, $ParentAttempt)
                $null = $Steps, $ParentOrdinal, $ParentAction, $ParentAttempt
                $script:ClickAttempts++
                $script:Fail.LastFailedAction = 'tapOn'
                $script:Fail.LastFailureLabel = 'tapOn'
                $script:Fail.LastFailedStepInvocationId = "leaf-$($script:ClickAttempts)"
                $script:Fail.StepHostInputFault = [ordered]@{ action = 'Send-Click'; stepInvocationId = "leaf-$($script:ClickAttempts)"
                    kind = 'transient'; reason = $script:ClickFaultReason; transport = 'KVM'; detail = 'press 1: fixture'
                    delivered = $script:ClickFaultDelivered; total = 2 }
                return $false
            }
            StepNum = 4; StepCount = 9; Description = 'press Next'; VMName = 'test-vm'; HostType = 'host.ubuntu.kvm'
        }
    }
    AfterEach {
        foreach ($functionName in 'Test-Arm64HyperVColdPowerCycleMode', 'Get-SequenceAction', 'Get-PollDelay',
            'Format-YurunaOperatorMessage', 'Send-CycleEventSafely') {
            Remove-Item -LiteralPath "Function:\$functionName" -ErrorAction SilentlyContinue
        }
        Restore-YurunaTestEnvironment -Saved $script:SavedClickRuntimeDir
        Remove-YurunaTestTempDir $script:ClickRuntime
    }

    It 'makes one attempt when the delivery is unknown' {
        Assert-False (& $script:ClickRetryHandler $script:ClickContext) 'the retry must fail'
        Assert-Equal -Expected 1 -Actual $script:ClickAttempts -Because 'another attempt could click twice'
        $exhausted = @($script:ClickEvents | Where-Object { $_.event -eq 'retry_exhausted' })
        Assert-Equal -Expected 'uncertain-click-delivery' -Actual $exhausted[0].retrySuppressionReason
        Assert-True ($script:Fail.LastFailureLabel -match 'uncertain-click-delivery') "the label says why: $($script:Fail.LastFailureLabel)"
    }

    It 'makes one attempt when part of a double click landed' {
        $script:ClickFaultReason = 'send-failed'
        $script:ClickFaultDelivered = 2
        Assert-False (& $script:ClickRetryHandler $script:ClickContext) 'the retry must fail'
        Assert-Equal -Expected 1 -Actual $script:ClickAttempts -Because 'the first press and release reached the guest'
    }

    It 'keeps retrying a click that sent nothing' {
        $script:ClickFaultReason = 'send-failed'
        $script:ClickFaultDelivered = 0
        Assert-False (& $script:ClickRetryHandler $script:ClickContext) 'the retry must fail'
        Assert-Equal -Expected 3 -Actual $script:ClickAttempts
    }
}

Describe 'the sequence schema types the blank-console expectation on the pure waits' {
    # The declaration is a step key the engine honors, so the schema carries it
    # as a boolean on the verbs that forward it: a misspelled value is a schema
    # violation, not an accepted key the engine then reads as false.
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $schemaPath = Join-Path (Split-Path -Parent $here) 'schemas/sequence.schema.yml'
        $script:schemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        function ConvertTo-WaitSequenceJson {
            param([string]$Action, $ExpectBlankConsole)
            $step = [ordered]@{ action = $Action; pattern = 'login:'; expectBlankConsole = $ExpectBlankConsole }
            if ($Action -eq 'waitForTextWithNudge') { $step.nudgeKey = 'Enter'; $step.nudgeIntervalSeconds = 60 }
            return ([ordered]@{
                description = 'schema probe'; keystrokeMechanism = 'gui'
                resource = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
                component = @($step)
            } | ConvertTo-Json -Depth 32)
        }
    }
    It 'accepts expectBlankConsole: true on <Action> and rejects a non-boolean value' -TestCases @(
        @{ Action = 'waitForText' }, @{ Action = 'waitForTextWithNudge' }
    ) {
        param($Action)
        Assert-True (Test-Json -Json (ConvertTo-WaitSequenceJson -Action $Action -ExpectBlankConsole $true) -Schema $script:schemaJson -ErrorAction SilentlyContinue) `
            "a $Action step may declare expectBlankConsole: true"
        Assert-False (Test-Json -Json (ConvertTo-WaitSequenceJson -Action $Action -ExpectBlankConsole 'yes') -Schema $script:schemaJson -ErrorAction SilentlyContinue) `
            "a $Action step with a non-boolean expectBlankConsole is a schema violation"
    }
}

Describe 'the sequence schema types the install power-off wait on startVm' {
    # The UTM Ubuntu start sequences opt into the install's own power-off with
    # this key; the engine reads it as a boolean, so a misspelled value is a
    # schema violation rather than an opt-in the engine then reads as false.
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $schemaPath = Join-Path (Split-Path -Parent $here) 'schemas/sequence.schema.yml'
        $script:startSchemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        function ConvertTo-StartVmSequenceJson {
            param($InstallPowerOff)
            return ([ordered]@{
                description = 'schema probe'; keystrokeMechanism = 'gui'
                resource = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
                component = @([ordered]@{ action = 'startVm'; timeoutSeconds = 2400; frameIntervalSeconds = 30; installPowerOff = $InstallPowerOff })
            } | ConvertTo-Json -Depth 32)
        }
    }
    It 'types installPowerOff on startVm as a boolean' {
        Assert-True (Test-Json -Json (ConvertTo-StartVmSequenceJson -InstallPowerOff $true) -Schema $script:startSchemaJson -ErrorAction SilentlyContinue) `
            'a startVm step may declare installPowerOff: true'
        Assert-False (Test-Json -Json (ConvertTo-StartVmSequenceJson -InstallPowerOff 'yes') -Schema $script:startSchemaJson -ErrorAction SilentlyContinue) `
            'a startVm step with a non-boolean installPowerOff is a schema violation'
    }
    It 'types failurePatterns on startVm as a pattern or a pattern list' {
        function ConvertTo-FailurePatternSequenceJson {
            param($FailurePatterns)
            return ([ordered]@{
                description = 'schema probe'; keystrokeMechanism = 'gui'
                resource = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
                component = @([ordered]@{ action = 'startVm'; timeoutSeconds = 2400; failurePatterns = $FailurePatterns })
            } | ConvertTo-Json -Depth 32)
        }
        Assert-True (Test-Json -Json (ConvertTo-FailurePatternSequenceJson -FailurePatterns @('Press enter to start a shell')) -Schema $script:startSchemaJson -ErrorAction SilentlyContinue) `
            'a startVm step may declare failure patterns'
        Assert-False (Test-Json -Json (ConvertTo-FailurePatternSequenceJson -FailurePatterns 7) -Schema $script:startSchemaJson -ErrorAction SilentlyContinue) `
            'a failure pattern must be text'
    }
}

# A wait that reads no text leaves the log root's failure_ocr_<vm>.txt as an
# earlier wait wrote it; the attempt's evidence must not pass that text off as
# its own screen.
Describe 'A failed retry attempt keeps only OCR text its own step read' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        # The real evidence writer, found by the handler the way a runner finds it.
        $script:ocrLoadedLog = -not (Get-Module Test.Log)
        if ($script:ocrLoadedLog) { Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Global -DisableNameChecking }
        $script:ocrModule = Get-Module Test.SequenceHandler
        $script:ocrHandler = (Get-SequenceAction -Name retry).Handler
        . $script:ocrModule {
            function Get-PollDelay { return 0 }
            function Send-CycleEventSafely { param($EventRecord) $null = $EventRecord }
            $script:OcrInvokeSteps = {
                param($Steps)
                $null = $Steps
                $script:OcrAttempts++
                if ($script:OcrAttempts -ge 2) { return $true }
                $script:Fail.LastFailedAction = 'waitForTextWithNudge'
                $script:Fail.LastFailureLabel = 'login timeout'
                $script:Fail.WaitForTextOcrTail = $null
                $script:Fail.LastFailedStepStartedUtc = [DateTime]::UtcNow.AddMinutes(-10)
                return $false
            }
        }
    }
    BeforeEach {
        & $script:ocrModule { $script:OcrAttempts = 0 }
        $script:ocrSaved = @{ Globals = (Save-YurunaTestGlobal -Name '__YurunaCycleFolder')
            Environment = (Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR', 'YURUNA_RUNTIME_DIR') }
        $script:ocrCycle = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ocrCycle 'log') -Force
        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $script:ocrCycle }
        $env:YURUNA_LOG_DIR = Join-Path $script:ocrCycle 'log'
        $env:YURUNA_RUNTIME_DIR = $script:ocrCycle
    }
    AfterEach {
        Restore-YurunaTestGlobal -Saved $script:ocrSaved.Globals
        Restore-YurunaTestEnvironment -Saved $script:ocrSaved.Environment
    }
    AfterAll {
        Remove-Module Test.SequenceHandler -Force
        if ($script:ocrLoadedLog) { Remove-Module Test.Log -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a note instead of an earlier wait''s text' {
        $stale = Join-Path $env:YURUNA_LOG_DIR 'failure_ocr_test-vm.txt'
        Set-Content -LiteralPath $stale -Value 'start: subiquity/Install/install/curtin_install from an earlier wait'
        [IO.File]::SetLastWriteTimeUtc($stale, [DateTime]::UtcNow.AddMinutes(-30))
        $context = @{
            Step = @{ maxAttempts = 2; steps = @(@{ action = 'waitForTextWithNudge'; pattern = 'guest login:'; nudgeKey = 'Enter'; nudgeIntervalSeconds = 60 }) }
            InvokeStepBlock = (& $script:ocrModule { $script:OcrInvokeSteps })
            StepNum = 18; StepCount = 19; Description = 'post-provision login'; VMName = 'test-vm'; HostType = 'host.windows.hyper-v'
        }
        (& $script:ocrHandler $context) | Should -BeTrue
        $copied = Join-Path $script:ocrCycle 'test-vm/failed_step18-attempt1/failure_ocr.txt'
        Test-Path -LiteralPath $copied | Should -BeTrue
        $text = Get-Content -Raw -LiteralPath $copied
        $text | Should -Not -Match 'curtin_install' -Because 'the attempt read no text, so an earlier wait''s screen is not its evidence'
        $text | Should -Match 'No OCR text from this attempt'
    }
}

Describe 'retry keeps a page step''s own class' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking
        $script:pageRetry = (Get-SequenceAction -Name retry).Handler
        $script:pageFail = Get-SequenceFailureState
        # What the engine's step block does for a page step that failed in its
        # transport: the leaf files its account, then names itself the failure.
        $script:pageLeaf = {
            param($Steps)
            $null = $Steps
            $script:pageFail.LastFailedStepInvocationId = 'leaf'
            Set-StepWebFailure -Context @{ StepInvocationId = 'leaf'; Step = @{ action = 'webClick' } } -Kind transport -Dispatched $true
            $script:pageFail.LastFailedAction = 'webClick'
            $script:pageFail.OriginatingStepInvocationId = 'leaf'
            $script:pageFail.OriginatingSequenceInvocationId = 'seq'
            return $false
        }
        $script:newPageContext = {
            param([scriptblock]$Leaf)
            return @{
                Step = @{ action = 'retry'; maxAttempts = 1; steps = @(@{ action = 'webClick' }) }
                StepNum = 4; StepCount = 9; VMName = 'vm1'; HostType = 'host.ubuntu.kvm'; Description = 'retry page'
                StepInvocationId = 'wrapper'; InvokeStepBlock = $Leaf
            }
        }
    }
    BeforeEach {
        $script:pageSaved = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $script:pageRuntime = New-YurunaTestTempDir -Prefix 'yuruna-retry-page'
        $env:YURUNA_RUNTIME_DIR = $script:pageRuntime
        Reset-SequenceFailureSlot -Lifetime sequence
    }
    AfterEach {
        Reset-SequenceFailureSlot -Lifetime sequence
        Restore-YurunaTestEnvironment -Saved $script:pageSaved
        Remove-YurunaTestTempDir $script:pageRuntime
    }
    AfterAll {
        Remove-Module Test.SequenceHandler -Force
    }

    It 'carries the account''s class as the inner cause' {
        $ctx = & $script:newPageContext $script:pageLeaf
        $ok = & $script:pageRetry $ctx 3>$null 6>$null
        Assert-False $ok 'the only attempt failed'
        Assert-StringEqual -Expected 'network_timeout' -Actual ([string]$script:pageFail.LastInnerFailureClass) -Because 'the account names the class, not the verb''s web_step_failed'
        Assert-StringEqual -Expected 'reconnect,retry_with_backoff' -Actual (@($script:pageFail.LastInnerSuggestedRecoveries) -join ',')
    }
    It 'keeps it through a retry nested in another' {
        $nested = {
            param($Steps)
            $null = & $script:pageLeaf $Steps
            # An inner retry that gave up: it names itself the failure and
            # leaves the account and the originating id in place.
            $script:pageFail.LastFailedAction = 'retry'
            $script:pageFail.LastFailedStepInvocationId = 'inner-wrapper'
            return $false
        }
        $ctx = & $script:newPageContext $nested
        $ok = & $script:pageRetry $ctx 3>$null 6>$null
        Assert-False $ok 'the only attempt failed'
        Assert-StringEqual -Expected 'network_timeout' -Actual ([string]$script:pageFail.LastInnerFailureClass)
    }
    It 'leaves the registered class when the leaf gave no account' {
        $bare = {
            param($Steps)
            $null = $Steps
            $script:pageFail.LastFailedStepInvocationId = 'leaf'
            $script:pageFail.LastFailedAction = 'webClick'
            $script:pageFail.OriginatingStepInvocationId = 'leaf'
            $script:pageFail.OriginatingSequenceInvocationId = 'seq'
            return $false
        }
        $ctx = & $script:newPageContext $bare
        $ok = & $script:pageRetry $ctx 3>$null 6>$null
        Assert-False $ok 'the only attempt failed'
        Assert-StringEqual -Expected 'web_step_failed' -Actual ([string]$script:pageFail.LastInnerFailureClass)
        Assert-StringEqual -Expected 'pause_and_inspect' -Actual (@($script:pageFail.LastInnerSuggestedRecoveries) -join ',')
    }
}

# The SSH start sequences of Ubuntu Server meet a guest whose seed expired the
# account's password; a key login then runs no command until it changes. The
# readiness wait, the rotation and the address lookup are stood in inside the
# module, so these cases drive only the verb's own decisions.
Describe 'sshWaitReady rotates an expired password once when the step carries both password fields' {
    BeforeAll {
        Import-Module $script:modulePath -Force -DisableNameChecking -Global
        . (Get-Module Test.SequenceHandler) {
            function Wait-SshReady {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                param($VMName, $GuestKey, $TimeoutSeconds, $PollSeconds, $OnExpiredLogin)
                $script:WaitCalls.Add([string]$OnExpiredLogin)
                $answer = $script:WaitAnswers.Dequeue()
                # A wait that outlasts the step's budget leaves the rotation or set none.
                if ($answer.sleepMs) { Start-Sleep -Milliseconds ([int]$answer.sleepMs) }
                $script:StandInReadiness = @{ cause = $answer.cause }
                return $answer.ok
            }
            function Get-LastSshReadiness { return $script:StandInReadiness }
            function Get-GuestSshUser { return 'fixture' }
            function Invoke-GuestSshPasswordRotation {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
                    Justification = 'Stub of a function that types vault passwords into a guest.')]
                param($VMName, $GuestKey, $CurrentPassword, $NewPassword, $TimeoutSeconds)
                $script:RotationCalls.Add(@{ Current = $CurrentPassword; New = $NewPassword; TimeoutSeconds = $TimeoutSeconds })
                return $script:RotationAnswer
            }
            function Set-GuestSshPassword {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real function so the caller binds.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
                    Justification = 'Stub of a function that writes a vault password to a guest.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Stub: records the call and changes nothing.')]
                param($VMName, $GuestKey, $NewPassword, $TimeoutSeconds)
                $script:SetCalls.Add(@{ New = $NewPassword; TimeoutSeconds = $TimeoutSeconds })
                return $script:SetAnswer
            }
        }
        $script:rotationCurrent = 'Fixture-Current-7351'
        $script:rotationNew = 'Fixture-New-9024'
        function Set-RotationStandIn {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: sets the stand-in answers inside the module under test.')]
            param([object[]]$Wait, [hashtable]$Rotation, [hashtable]$Set = @{ Ok = $true; Code = ''; Detail = '' })
            & (Get-Module Test.SequenceHandler) {
                param($Wait, $Rotation, $Set)
                $script:WaitCalls = [System.Collections.Generic.List[string]]::new()
                $script:WaitAnswers = [System.Collections.Generic.Queue[object]]::new()
                foreach ($answer in $Wait) { $script:WaitAnswers.Enqueue($answer) }
                $script:RotationCalls = [System.Collections.Generic.List[hashtable]]::new()
                $script:RotationAnswer = $Rotation
                $script:SetCalls = [System.Collections.Generic.List[hashtable]]::new()
                $script:SetAnswer = $Set
            } $Wait $Rotation $Set
            (Get-SequenceFailureState).StepGuestChange = $null
        }
        function Get-RotationStandIn {
            return (& (Get-Module Test.SequenceHandler) { @{ Wait = @($script:WaitCalls); Rotation = @($script:RotationCalls); Set = @($script:SetCalls) } }) +
                @{ GuestChange = (Get-SequenceFailureState).StepGuestChange }
        }
        function Get-RotationContext {
            param([hashtable]$Fields)
            $step = [ordered]@{ action = 'sshWaitReady'; timeoutSeconds = 30 }
            foreach ($key in $Fields.Keys) { $step[$key] = $Fields[$key] }
            return @{
                Step = $step; StepNum = 9; StepCount = 17
                Vars = @{ username = 'fixture'; currentPassword = $script:rotationCurrent; newPassword = $script:rotationNew }
                ExpandVariable = { param($Value, $Vars) $map = $Vars; [regex]::Replace([string]$Value, '\$\{([^}]+)\}', { param($m) [string]$map[$m.Groups[1].Value] }) }
                DefaultTimeoutSeconds = 30; DefaultPollSeconds = 5; ShowSensitive = $false; VMName = 'vm1'; GuestKey = 'guest.ubuntu.server.26'
                StepInvocationId = 'step-9'; SequenceInvocationId = 'seq-1'; SequencePath = 'start.guest.ubuntu.server.26.ssh.yml'
            }
        }
        $script:bothFields = @{ currentPassword = '${currentPassword}'; newPassword = '${newPassword}' }
        $script:expired = @{ ok = $false; cause = 'password_expired' }
        $script:ready = @{ ok = $true; cause = 'ready' }
    }
    AfterAll { Remove-Module Test.SequenceHandler -Force }

    It 'rotates once on the first expired answer and goes on waiting' {
        Set-RotationStandIn -Wait @($script:expired, $script:ready) -Rotation @{ Ok = $true; Code = ''; Detail = '' }
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $script:bothFields) 6>$null
        Assert-True $ok 'the wait after the rotation reached a shell'
        $seen = Get-RotationStandIn
        Assert-StringEqual -Expected 'Return,Fail' -Actual ($seen.Wait -join ',') -Because 'the first expiry returns for the rotation, a second one fails'
        Assert-Equal 1 $seen.Rotation.Count 'one rotation'
        Assert-StringEqual -Expected $script:rotationCurrent -Actual $seen.Rotation[0].Current
        Assert-StringEqual -Expected $script:rotationNew -Actual $seen.Rotation[0].New
        Assert-True ($seen.Rotation[0].TimeoutSeconds -ge 1 -and $seen.Rotation[0].TimeoutSeconds -le 30) 'the rotation shares the step budget'
        Assert-Equal 0 $seen.Set.Count 'the rotation already put the new password in place'
    }

    It 'waits exactly as before without the two fields' {
        Set-RotationStandIn -Wait @($script:expired) -Rotation $null
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields @{}) 6>$null
        Assert-False $ok 'the expired guest never became ready'
        $seen = Get-RotationStandIn
        Assert-StringEqual -Expected '' -Actual ($seen.Wait -join ',') -Because 'the wait keeps its default policy'
        Assert-Equal 1 $seen.Wait.Count 'one wait'
        Assert-Equal 0 $seen.Rotation.Count 'no rotation'
        Assert-Equal 0 $seen.Set.Count 'no set'
    }

    It 'sets nothing on a guest that reaches a shell without the two fields' {
        Set-RotationStandIn -Wait @($script:ready) -Rotation $null
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields @{}) 6>$null
        Assert-True $ok 'the guest reached a shell'
        $seen = Get-RotationStandIn
        Assert-Equal 1 $seen.Wait.Count 'one wait'
        Assert-Equal 0 $seen.Rotation.Count 'no rotation'
        Assert-Equal 0 $seen.Set.Count 'no set'
    }

    # A replayed step meets a guest whose password is no longer expired, and a
    # later step stores newPassword in the vault: the step passes only once the
    # guest has that password too.
    It 'sets the new password once when the login reaches a shell without expiry' {
        Set-RotationStandIn -Wait @($script:ready) -Rotation $null
        $information = @()
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $script:bothFields) 6>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { $information += [string]$_.MessageData } else { $_ } }
        Assert-True $ok 'the password is in place'
        $seen = Get-RotationStandIn
        Assert-Equal 1 $seen.Wait.Count 'one wait'
        Assert-Equal 0 $seen.Rotation.Count 'nothing to rotate'
        Assert-Equal 1 $seen.Set.Count 'one set'
        Assert-StringEqual -Expected $script:rotationNew -Actual $seen.Set[0].New
        Assert-True ($seen.Set[0].TimeoutSeconds -ge 1 -and $seen.Set[0].TimeoutSeconds -le 30) 'the set shares the step budget'
        Assert-StringEqual -Expected (Format-YurunaOperatorMessage -Key 'runner.ssh_password_set' -Arguments @{ user = 'fixture'; vmName = 'vm1' }) -Actual ($information -join "`n")
    }

    # The verb stays 'observe', so the rotation or set it ran is recorded as
    # the step's own change to the guest, by step number (the context's 9).
    It 'records the guest change of <Case>' -TestCases @(
        @{ Case = 'a set that passed'; Wait = 'ready'; Rotation = $null; Set = @{ Ok = $true; Code = ''; Detail = ''; Dispatched = $true }; Change = 'applied' }
        @{ Case = 'a set that failed after the client started'; Wait = 'ready'; Rotation = $null; Set = @{ Ok = $false; Code = 'chpasswd-failed'; Detail = ''; Dispatched = $true }; Change = 'uncertain' }
        @{ Case = 'a set sudo refused'; Wait = 'ready'; Rotation = $null; Set = @{ Ok = $false; Code = 'sudo-refused'; Detail = ''; Dispatched = $true }; Change = '' }
        @{ Case = 'a set that never started'; Wait = 'ready'; Rotation = $null; Set = @{ Ok = $false; Code = 'ssh-missing'; Detail = ''; Dispatched = $false }; Change = '' }
        @{ Case = 'a rotation that passed'; Wait = 'expired,ready'; Rotation = @{ Ok = $true; Code = ''; Detail = ''; Answered = 3 }; Set = $null; Change = 'applied' }
        @{ Case = 'a rotation refused after the last answer'; Wait = 'expired'; Rotation = @{ Ok = $false; Code = 'refused'; Detail = ''; Answered = 3 }; Set = $null; Change = 'uncertain' }
        @{ Case = 'a rotation whose probe found the password still expired'; Wait = 'expired'; Rotation = @{ Ok = $false; Code = 'still-expired'; Detail = ''; Answered = 3 }; Set = $null; Change = '' }
        @{ Case = 'a rotation stopped before the new password'; Wait = 'expired'; Rotation = @{ Ok = $false; Code = 'unexpected-prompt'; Detail = ''; Answered = 1 }; Set = $null; Change = '' }
    ) {
        param($Case, $Wait, $Rotation, $Set, $Change)
        $null = $Case
        $answers = @(foreach ($name in $Wait -split ',') { if ($name -eq 'expired') { $script:expired } else { $script:ready } })
        Set-RotationStandIn -Wait $answers -Rotation $Rotation -Set $Set
        $null = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $script:bothFields) 6>$null 3>$null
        $recorded = (Get-RotationStandIn).GuestChange
        $actual = if ($null -eq $recorded) { '' } else { [string]$recorded['9'] }
        Assert-StringEqual -Expected $Change -Actual $actual -Because 'the change recorded for step 9'
    }

    It 'records no guest change without the two fields' {
        Set-RotationStandIn -Wait @($script:ready) -Rotation $null
        $null = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields @{}) 6>$null
        Assert-Null (Get-RotationStandIn).GuestChange
    }

    # With the step's budget spent the call still runs, with no time, so that
    # the function itself reports and records how it ended.
    It 'still calls the set with no time left when the wait spent the budget' {
        $fields = $script:bothFields.Clone()
        $fields.timeoutSeconds = 2
        Set-RotationStandIn -Wait @(@{ ok = $true; cause = 'ready'; sleepMs = 2200 }) -Rotation $null -Set @{ Ok = $false; Code = 'timeout'; Detail = ''; Dispatched = $false }
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $fields) 6>$null 3>$null
        Assert-False $ok 'no time was left to set the password'
        $seen = Get-RotationStandIn
        Assert-Equal 1 $seen.Set.Count 'the set was called'
        Assert-Equal 0 ([int]$seen.Set[0].TimeoutSeconds) 'with no time left'
        Assert-Null $seen.GuestChange
    }

    It 'still calls the rotation with no time left when the wait spent the budget' {
        $fields = $script:bothFields.Clone()
        $fields.timeoutSeconds = 2
        Set-RotationStandIn -Wait @(@{ ok = $false; cause = 'password_expired'; sleepMs = 2200 }) -Rotation @{ Ok = $false; Code = 'timeout'; Detail = ''; Answered = 0 }
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $fields) 6>$null 3>$null
        Assert-False $ok 'no time was left to rotate the password'
        $seen = Get-RotationStandIn
        Assert-Equal 1 $seen.Rotation.Count 'the rotation was called'
        Assert-Equal 0 ([int]$seen.Rotation[0].TimeoutSeconds) 'with no time left'
        Assert-Null $seen.GuestChange
    }

    It 'fails a set the guest refused, names it, and keeps both passwords out of everything it wrote' {
        Set-RotationStandIn -Wait @($script:ready) -Rotation $null -Set @{ Ok = $false; Code = 'sudo-refused'; Detail = 'sudo: a password is required' }
        $context = Get-RotationContext -Fields $script:bothFields
        $warnings = @()
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler $context 6>$null 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } else { $_ } }
        Assert-False $ok 'a password the guest never received must not pass the step'
        Assert-Equal 1 (Get-RotationStandIn).Set.Count 'one set'
        Assert-Equal 1 (Get-RotationStandIn).Wait.Count 'no wait after a failed set'
        Assert-StringEqual -Expected (Format-YurunaOperatorMessage -Key 'runner.ssh_password_set_failed' -Arguments @{
                user = 'fixture'; vmName = 'vm1'; code = 'sudo-refused'; detail = 'sudo: a password is required' }) -Actual ($warnings -join "`n")
        $state = Get-SequenceFailureState
        $state.LastFailureLabel = Get-SequenceActionFailureLabel -Step $context.Step -Vars $context.Vars -ExpandVariable $context.ExpandVariable -VMName vm1 -GuestKey $context.GuestKey
        $state.LastFailedAction = 'sshWaitReady'
        $state.LastFailedStepNumber = 9
        $state.LastFailedStepInvocationId = 'step-9'
        try {
            $record = New-SequenceFailureRecord -Reason step -VMName vm1 -GuestKey $context.GuestKey -HostType host.ubuntu.kvm -SequencePath $context.SequencePath -LogDir $TestDrive -TotalSteps 17
            $text = (ConvertTo-Json -InputObject $record.File -Depth 12) + (ConvertTo-Json -InputObject $record.Event -Depth 12) + ($warnings -join "`n")
            Assert-False $text.Contains($script:rotationCurrent) 'the current password leaked'
            Assert-False $text.Contains($script:rotationNew) 'the new password leaked'
        } finally {
            Reset-SequenceFailureSlot -Lifetime sequence
        }
    }

    It 'fails after a second expired answer without rotating again' {
        Set-RotationStandIn -Wait @($script:expired, $script:expired) -Rotation @{ Ok = $true; Code = ''; Detail = '' }
        $warnings = @()
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $script:bothFields) 6>$null 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } else { $_ } }
        Assert-False $ok 'the password is still expired'
        Assert-Equal 1 (Get-RotationStandIn).Rotation.Count 'one rotation'
        Assert-StringEqual -Expected (Format-YurunaOperatorMessage -Key 'runner.ssh_password_still_expired' -Arguments @{ user = 'fixture'; vmName = 'vm1' }) -Actual ($warnings -join "`n")
    }

    It 'fails a rotation the guest refused and names it' {
        Set-RotationStandIn -Wait @($script:expired) -Rotation @{ Ok = $false; Code = 'refused'; Detail = 'passwd: Authentication token manipulation error' }
        $warnings = @()
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields $script:bothFields) 6>$null 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } else { $_ } }
        Assert-False $ok 'the rotation failed'
        Assert-Equal 1 (Get-RotationStandIn).Wait.Count 'no wait after a failed rotation'
        Assert-StringEqual -Expected (Format-YurunaOperatorMessage -Key 'runner.ssh_password_rotation_failed' -Arguments @{
                user = 'fixture'; vmName = 'vm1'; code = 'refused'; detail = 'passwd: Authentication token manipulation error' }) -Actual ($warnings -join "`n")
    }

    It 'fails a step that names only <Field> before it waits' -TestCases @(
        @{ Field = 'currentPassword' }, @{ Field = 'newPassword' }
    ) {
        param($Field)
        Set-RotationStandIn -Wait @() -Rotation $null
        $ok = & (Get-SequenceAction -Name sshWaitReady).Handler (Get-RotationContext -Fields @{ $Field = "`${$Field}" }) 3>$null
        Assert-False $ok 'one password cannot rotate anything'
        Assert-Equal 0 (Get-RotationStandIn).Wait.Count 'nothing waited'
    }

    It 'keeps both passwords out of the failure record, the label and the warnings' {
        Set-RotationStandIn -Wait @($script:expired) -Rotation @{ Ok = $false; Code = 'refused'; Detail = 'Retype new password: ***' }
        $context = Get-RotationContext -Fields $script:bothFields
        $warnings = @()
        $null = & (Get-SequenceAction -Name sshWaitReady).Handler $context 6>$null 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } }
        $state = Get-SequenceFailureState
        $state.LastFailureLabel = Get-SequenceActionFailureLabel -Step $context.Step -Vars $context.Vars -ExpandVariable $context.ExpandVariable -VMName vm1 -GuestKey $context.GuestKey
        $state.LastFailedAction = 'sshWaitReady'
        $state.LastFailedStepNumber = 9
        $state.LastFailedStepInvocationId = 'step-9'
        try {
            $record = New-SequenceFailureRecord -Reason step -VMName vm1 -GuestKey $context.GuestKey -HostType host.ubuntu.kvm -SequencePath $context.SequencePath -LogDir $TestDrive -TotalSteps 17
            $text = (ConvertTo-Json -InputObject $record.File -Depth 12) + (ConvertTo-Json -InputObject $record.Event -Depth 12) + ($warnings -join "`n")
            Assert-False $text.Contains($script:rotationCurrent) 'the current password leaked'
            Assert-False $text.Contains($script:rotationNew) 'the new password leaked'
            Assert-StringEqual -Expected 'sshWaitReady' -Actual ([string]$record.File.action)
        } finally {
            Reset-SequenceFailureSlot -Lifetime sequence
        }
    }
}

Describe 'the sequence schema takes the sshWaitReady password fields only together' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $schemaPath = Join-Path (Split-Path -Parent $here) 'schemas/sequence.schema.yml'
        $script:rotationSchemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        function ConvertTo-RotationSequenceJson {
            param([hashtable]$Fields)
            $step = [ordered]@{ action = 'sshWaitReady'; timeoutSeconds = 2400 }
            foreach ($key in $Fields.Keys) { $step[$key] = $Fields[$key] }
            return ([ordered]@{
                description = 'schema probe'; keystrokeMechanism = 'ssh'
                resource = [ordered]@{ 'ubuntu.server.26' = @() }
                component = @($step)
            } | ConvertTo-Json -Depth 32)
        }
    }
    It 'accepts both fields or neither, and refuses <Case>' -TestCases @(
        @{ Case = 'currentPassword alone'; Fields = @{ currentPassword = '${currentPassword}' } }
        @{ Case = 'newPassword alone'; Fields = @{ newPassword = '${newPassword}' } }
        @{ Case = 'a password that is not text'; Fields = @{ currentPassword = 7; newPassword = '${newPassword}' } }
    ) {
        param($Case, $Fields)
        Assert-True (Test-Json -Json (ConvertTo-RotationSequenceJson -Fields @{ currentPassword = '${currentPassword}'; newPassword = '${newPassword}' }) -Schema $script:rotationSchemaJson -ErrorAction SilentlyContinue) `
            'a step may carry both password fields'
        Assert-True (Test-Json -Json (ConvertTo-RotationSequenceJson -Fields @{}) -Schema $script:rotationSchemaJson -ErrorAction SilentlyContinue) `
            'a step may carry neither'
        Assert-False (Test-Json -Json (ConvertTo-RotationSequenceJson -Fields $Fields) -Schema $script:rotationSchemaJson -ErrorAction SilentlyContinue) `
            "a step with $Case is a schema violation"
    }
}
