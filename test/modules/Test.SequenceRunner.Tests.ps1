<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42b4e120-ffe3-4090-9478-c0444af48a73
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence chain pester
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
    Pester guard on Test.SequenceRunner.psm1's value-returning functions
    (Resolve-TestSequencePlan, Invoke-TestSequenceChain,
    Get-FirstExecutedStepAction): none may emit Write-Output. Plus the
    wrapper-descent behavior Get-FirstExecutedStepAction owns.
.DESCRIPTION
    Both chain functions return a hashtable that the caller captures
    (`$plan = Resolve-TestSequencePlan`, `$result = Invoke-TestSequenceChain`).
    A Write-Output inside either joins its status strings to that hashtable on
    the pipeline, turning the return into an object[]; a later member access such
    as `$plan.chainEntries` then enumerates and unwraps a single warm-path entry
    to a bare object, which fails the chain runner's [IList] parameter binding.
    Status must therefore go through Write-Information. This is the pipeline-
    pollution trap class (feedback_powershell_writeoutput_pipeline_pollution).

    No host I/O -- AST inspection and pure-function calls only -- so it runs under
    OS-bundled Pester 3.4 / Pester 5+ with throw-based assertions.
#>

BeforeAll {
$here               = Split-Path -Parent $PSCommandPath
$modulePath         = Join-Path $here 'Test.SequenceRunner.psm1'
$script:testSequenceScript = Join-Path (Split-Path -Parent $here) 'Debug-TestSequence.ps1'

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
# Get-FirstExecutedStepAction resolves a wrapper step through Get-StepLeadAction.
Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# One chain entry in the shape Resolve-TestSequencePlan returns.
function Get-ChainEntry { param($Steps) @{ sequence = @{ steps = $Steps } } }

function Get-FunctionWriteOutputCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FunctionName)

    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }

    $func = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function '$FunctionName' not found in $Path" }

    $writeOutputs = $func.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Write-Output'
    }, $true)
    return @($writeOutputs).Count
}

# Find the argument expression passed to a named parameter of the (single)
# Invoke-TestSequenceChain call in a script, handling both `-P $x` (space) and
# `-P:$x` (colon) forms.
#
# This helper, Get-FunctionText and the $script:planText fixture below all sit above the
# first Describe: file-level code only executes as far as the first Describe on
# the run pass, and a Describe body is evaluated during discovery with its scope
# discarded before any It runs. A helper or fixture declared after the first
# Describe -- or inside one -- is therefore unresolvable from an It body.
function Get-CallArgumentAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$ParameterName)

    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }

    $call = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Command
    }, $true) | Select-Object -First 1
    if (-not $call) { throw "No '$Command' call found in $Path" }

    $els = $call.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq $ParameterName) {
            if ($el.Argument) { return $el.Argument }
            if ($i + 1 -lt $els.Count) { return $els[$i + 1] }
        }
    }
    throw "No -$ParameterName argument found on the '$Command' call in $Path"
}

function Get-FunctionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FunctionName)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    $func = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function '$FunctionName' not found in $Path" }
    return $func.Extent.Text
}

$script:planText = Get-FunctionText -Path $modulePath -FunctionName 'Resolve-TestSequencePlan'

}

Describe 'Test.SequenceRunner value-returning functions avoid Write-Output' {
    It 'Resolve-TestSequencePlan emits no Write-Output (return value is captured into $plan)' {
        Assert-Equal -Expected 0 -Actual (Get-FunctionWriteOutputCount -Path $modulePath -FunctionName 'Resolve-TestSequencePlan') -Because `
            'Write-Output would pollute the returned hashtable into an object[].'
    }
    It 'Invoke-TestSequenceChain emits no Write-Output (return value is captured into $result)' {
        Assert-Equal -Expected 0 -Actual (Get-FunctionWriteOutputCount -Path $modulePath -FunctionName 'Invoke-TestSequenceChain') -Because `
            'Write-Output would pollute the returned hashtable into an object[].'
    }
    It 'Get-FirstExecutedStepAction emits no Write-Output (return value decides whether the VM is pre-started)' {
        Assert-Equal -Expected 0 -Actual (Get-FunctionWriteOutputCount -Path $modulePath -FunctionName 'Get-FirstExecutedStepAction') -Because `
            'Write-Output would join the returned action name into an object[], and the -eq test against it would stop matching.'
    }
}

Describe 'A failed chain gathers its own evidence' {
    # A failing step leaves a screenshot; the guest diagnostics and the last
    # fetch-and-execute log -- the failing script's own output -- come from
    # Copy-FailureArtifactsToStatusLog, which the runner's inner loop calls on
    # its paths and neither chain caller reaches.
    It 'Save-ChainFailureArtifact routes the capture output away from the success stream' {
        # The capture reports artifacts with Write-Output. Its callers return a
        # hashtable the caller captures, so a bare call would join those strings
        # into it -- the pipeline-pollution trap this file exists to guard.
        $text = Get-FunctionText -Path $modulePath -FunctionName 'Save-ChainFailureArtifact'
        $errs = $null
        $ast  = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in Save-ChainFailureArtifact: $($errs[0].Message)" }
        $call = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                      $n.GetCommandName() -eq 'Copy-FailureArtifactsToStatusLog'
        }, $true) | Select-Object -First 1
        Assert-True ($null -ne $call) 'the wrapper must actually call the capture'
        $pipeline = $call.Parent
        Assert-True ($pipeline -is [System.Management.Automation.Language.PipelineAst]) 'the call should sit in a pipeline'
        Assert-True ($pipeline.PipelineElements.Count -ge 2) `
            'an un-piped call puts the capture''s Write-Output strings into the caller''s return value.'
    }
    It 'both chain callers capture before they report the failure' {
        # The orchestrator runs the cycle; Debug-TestSequence runs the repro
        # command the failure record prints. A guest that failed on either one
        # has the same story to tell.
        $orchestrator = Join-Path $here 'Test.Orchestrator.psm1'
        foreach ($path in @($orchestrator, $script:testSequenceScript)) {
            $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
            if ($errs) { throw "Parse errors in ${path}: $($errs[0].Message)" }
            $calls = $ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                          $n.GetCommandName() -eq 'Save-ChainFailureArtifact'
            }, $true)
            Assert-True (@($calls).Count -ge 1) "$(Split-Path -Leaf $path) must capture a failed chain's artifacts"
        }
    }
}

Describe 'Get-FirstExecutedStepAction reads through wrapper steps' {
    # A sequence may nest its restore inside a `retry` block so a failed attempt
    # replays from known state. The action reaching the guest first is then the
    # wrapper's first inner step, and a caller that stops at the wrapper boots a
    # VM the restore has to stop again.
    It 'descends through a retry wrapper to the restore inside it' {
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-FirstExecutedStepAction -ChainEntries @(
            (Get-ChainEntry @(@{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }, @{ action = 'sshWaitReady' }) }))) -StartStep 1)
    }
    It 'descends through nested wrappers' {
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-FirstExecutedStepAction -ChainEntries @(
            (Get-ChainEntry @(@{ action = 'retry'; steps = @(@{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }) }) }))) -StartStep 1)
    }
    It 'reports a wrapper that wraps nothing by its own name, which matches no restore' {
        # The retry handler fails an empty block itself, so `retry` is what would
        # run; either way it is not `loadDiskSnapshot`, so the VM gets started.
        Assert-Equal -Expected 'retry' -Actual (Get-FirstExecutedStepAction -ChainEntries @(
            (Get-ChainEntry @(@{ action = 'retry' }))) -StartStep 1)
        Assert-Equal -Expected 'retry' -Actual (Get-FirstExecutedStepAction -ChainEntries @(
            (Get-ChainEntry @(@{ action = 'retry'; steps = @() }))) -StartStep 1)
    }
    It 'counts a wrapper as ONE step for -StartStep, matching how the engine numbers it' {
        $entries = @((Get-ChainEntry @(
            @{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }, @{ action = 'sshWaitReady' }) },
            @{ action = 'saveSystemDiagnostic' })))
        Assert-Equal -Expected 'saveSystemDiagnostic' -Actual (Get-FirstExecutedStepAction -ChainEntries $entries -StartStep 2) -Because `
            'the retry block occupies global step 1 no matter how many steps it wraps.'
    }
    It 'resolves across chain entries, not just the first' {
        $entries = @(
            (Get-ChainEntry @(@{ action = 'sshWaitReady' })),
            (Get-ChainEntry @(@{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }) })))
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-FirstExecutedStepAction -ChainEntries $entries -StartStep 2)
    }
}

Describe 'Debug-TestSequence.ps1 resolves the first executed action through the module' {
    It 'defines no local Get-FirstExecutedStepAction (a local copy would shadow the wrapper-aware one)' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:testSequenceScript, [ref]$tokens, [ref]$errs)
        if ($errs) { throw "Parse errors in $($script:testSequenceScript): $($errs[0].Message)" }
        $local = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FirstExecutedStepAction'
        }, $true)
        Assert-Equal -Expected 0 -Actual @($local).Count -Because `
            'a script-local definition wins over the imported one, and a sequence nesting its restore in a retry block would silently go back to pre-starting the VM.'
    }
}

Describe 'Invoke-TestSequenceChain accepts the planner List shape' {
    It 'binds a single-entry List[object] to the [IList] parameter (warm-path shape)' {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add([pscustomobject]@{ name='top'; path='x.yml'; sequence=@{ steps=@(1,2,3) }; stepCount=3; globalStart=1 })
        $plan = [pscustomobject]@{ fullChain=@('a','b','c','d'); effectiveVariables=@{} }
        # Request a window past the only entry so the loop skips it -- no engine
        # call is needed, which isolates the [IList] parameter binding. A single-
        # entry List is the warm path (requiresSnapshot present): the planner
        # returns a List of one, which must bind. Wrapping it in @() would throw
        # "Argument types do not match", so the bug surfaced only on this path.
        $r = Invoke-TestSequenceChain -ChainEntries $list -ChainPlan $plan `
            -StartStep 99 -EffectiveStop 99 -StopStep 0 -ChainTotalSteps 3 `
            -HostType 'h' -GuestKey 'g' -VMName 'orig' -SequenceName 's'
        Assert-True ($r.ok) 'single-entry List binds and the chain completes'
    }
}

Describe 'Debug-TestSequence.ps1 passes ChainEntries without an @() wrap' {
    It 'forwards the bare $ChainEntries variable (an @() wrap breaks the [IList] bind)' {
        $arg = Get-CallArgumentAst -Path $script:testSequenceScript -Command 'Invoke-TestSequenceChain' -ParameterName 'ChainEntries'
        Assert-True ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) `
            "Expected a bare variable, got $($arg.GetType().Name). Wrapping the planner List in @() yields an array a Mandatory [IList] parameter rejects with 'Argument types do not match'."
    }
}

Describe 'Resolve-TestSequencePlan snapshot probe distinguishes absent from could-not-determine' {

    It 'retries the Test-VMDiskSnapshot probe instead of swallowing the first exception' {
        Assert-True ($script:planText -match 'Test-VMDiskSnapshot') 'the snapshot probe is present'
        Assert-True ($script:planText -match '\$probeAttempt') 'the probe runs inside a retry loop'
    }
    It 'fails the plan loudly on an undetermined probe rather than assuming cold' {
        Assert-True ($script:planText -match 'Write-Warning') 'an undetermined probe surfaces a warning, not just Write-Verbose'
        Assert-True ($script:planText -notmatch 'assuming cold path') 'a swallowed probe exception must not silently fall through to the cold path'
    }
}
