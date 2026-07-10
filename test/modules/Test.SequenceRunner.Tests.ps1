<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f8c3d6-1a4b-4e29-9c70-5d8e1f2a3b40
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
    Structural Pester guard on Test.SequenceRunner.psm1's two value-returning
    functions (Resolve-TestSequencePlan, Invoke-TestSequenceChain): neither may
    emit Write-Output.
.DESCRIPTION
    Both functions return a hashtable that the caller captures
    (`$plan = Resolve-TestSequencePlan`, `$result = Invoke-TestSequenceChain`).
    A Write-Output inside either joins its status strings to that hashtable on
    the pipeline, turning the return into an object[]; a later member access such
    as `$plan.chainEntries` then enumerates and unwraps a single warm-path entry
    to a bare object, which fails the chain runner's [IList] parameter binding.
    Status must therefore go through Write-Information. This is the pipeline-
    pollution trap class (feedback_powershell_writeoutput_pipeline_pollution).

    AST-only -- no host I/O -- so it runs under OS-bundled Pester 3.4 / Pester 5+
    with throw-based assertions.
#>

$here               = Split-Path -Parent $PSCommandPath
$modulePath         = Join-Path $here 'Test.SequenceRunner.psm1'
$testSequenceScript = Join-Path (Split-Path -Parent $here) 'Test-Sequence.ps1'

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

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

Describe 'Test.SequenceRunner value-returning functions avoid Write-Output' {
    It 'Resolve-TestSequencePlan emits no Write-Output (return value is captured into $plan)' {
        Assert-Equal -Expected 0 -Actual (Get-FunctionWriteOutputCount -Path $modulePath -FunctionName 'Resolve-TestSequencePlan') -Because `
            'Write-Output would pollute the returned hashtable into an object[].'
    }
    It 'Invoke-TestSequenceChain emits no Write-Output (return value is captured into $result)' {
        Assert-Equal -Expected 0 -Actual (Get-FunctionWriteOutputCount -Path $modulePath -FunctionName 'Invoke-TestSequenceChain') -Because `
            'Write-Output would pollute the returned hashtable into an object[].'
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

# Find the argument expression passed to a named parameter of the (single)
# Invoke-TestSequenceChain call in a script, handling both `-P $x` (space) and
# `-P:$x` (colon) forms.
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

Describe 'Test-Sequence.ps1 passes ChainEntries without an @() wrap' {
    It 'forwards the bare $ChainEntries variable (an @() wrap breaks the [IList] bind)' {
        $arg = Get-CallArgumentAst -Path $testSequenceScript -Command 'Invoke-TestSequenceChain' -ParameterName 'ChainEntries'
        Assert-True ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) `
            "Expected a bare variable, got $($arg.GetType().Name). Wrapping the planner List in @() yields an array a Mandatory [IList] parameter rejects with 'Argument types do not match'."
    }
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

Describe 'Resolve-TestSequencePlan snapshot probe distinguishes absent from could-not-determine' {
    $planText = Get-FunctionText -Path $modulePath -FunctionName 'Resolve-TestSequencePlan'

    It 'retries the Test-VMDiskSnapshot probe instead of swallowing the first exception' {
        Assert-True ($planText -match 'Test-VMDiskSnapshot') 'the snapshot probe is present'
        Assert-True ($planText -match '\$probeAttempt') 'the probe runs inside a retry loop'
    }
    It 'fails the plan loudly on an undetermined probe rather than assuming cold' {
        Assert-True ($planText -match 'Write-Warning') 'an undetermined probe surfaces a warning, not just Write-Verbose'
        Assert-True ($planText -notmatch 'assuming cold path') 'a swallowed probe exception must not silently fall through to the cold path'
    }
}
