<#PSScriptInfo
.VERSION 2026.07.22
.GUID 429d1e7a-2c84-4f61-9a05-7e6d2b8c4f13
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test tesseract ocr pester
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
    Structural Pester guards on Test.Tesseract.psm1's OCR invocation shape and
    the Find-Tesseract Linux fallback.
.DESCRIPTION
    The two OCR entry points (Invoke-TesseractOcr, Get-TesseractWordBox) must:
      * invoke tesseract exactly once -- a second invocation to fetch stderr can
        diverge from the first (the image may change or be deleted between runs)
        and doubles the process spawn;
      * pin $PSNativeCommandUseErrorActionPreference = $false so a non-zero
        tesseract exit reaches the explicit exit-code branch instead of throwing
        a bare NativeCommandExitException on PS 7.4+ under EAP=Stop; and
      * surface tesseract's own stderr in the thrown message so a failure is
        diagnosable.
    Find-Tesseract must carry a Linux filesystem fallback for parity with its
    Windows/macOS branches, so a tesseract present on disk but absent from a
    stripped-down PATH is still located.

    Assertions are on the parsed AST -- an IfStatementAst conditioned on the real
    variable, an AssignmentStatementAst RHS, a ThrowStatementAst that references
    the variable -- NOT a substring of the extent text, so a comment that merely
    mentions $IsLinux / $errMsg / the preference cannot keep a guard green after
    the underlying code is removed. No tesseract binary or host I/O is required.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Tesseract.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FunctionName)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    $func = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $func) { throw "Function '$FunctionName' not found in $Path" }
    return $func
}

# Count `& $VarName ...` invocations inside a function via the AST, so a
# regression that re-adds a second tesseract call is caught structurally.
function Get-VarInvocationCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Counting '& `$$VarName' invocations"
    $calls = $FuncAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $n.CommandElements.Count -ge 1 -and
        $n.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.CommandElements[0].VariablePath.UserPath -eq $VarName
    }, $true)
    return @($calls).Count
}

# True iff the function contains an AssignmentStatementAst that sets
# $PSNativeCommandUseErrorActionPreference to $false (a real assignment, not a
# comment mention of the pin).
function Test-FunctionPinsNativeEap {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst)
    $assigns = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assigns) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $a.Left.VariablePath.UserPath -eq 'PSNativeCommandUseErrorActionPreference' -and
            $a.Right.Extent.Text.Trim() -eq '$false') {
            return $true
        }
    }
    return $false
}

# True iff the function assigns $VarName AND references it inside a throw, i.e.
# the thrown failure message carries that variable's content (here: partitioned
# stderr), not merely a bare exit code.
function Test-FunctionAssignsAndThrowsVar {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Checking that '$VarName' is assigned and referenced in a throw"
    $assigned = $FuncAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $VarName
    }, $true)
    if (@($assigned).Count -eq 0) { return $false }
    $throws = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)
    foreach ($t in $throws) {
        $ref = $t.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $VarName
        }, $true)
        if (@($ref).Count -gt 0) { return $true }
    }
    return $false
}

# Returns the body (StatementBlockAst) of the first if-branch whose condition
# references $VarName, or $null. Proves a real branch exists, distinct from a
# comment that names the variable.
function Get-IfBranchBodyOnVar {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.Ast])]
    param([Parameter(Mandatory)]$FuncAst, [Parameter(Mandatory)][string]$VarName)
    Write-Verbose "Searching for an if-branch conditioned on '$VarName'"
    $ifs = $FuncAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    foreach ($if in $ifs) {
        foreach ($clause in $if.Clauses) {
            $cond = $clause.Item1
            $hit = $cond.FindAll({
                param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $VarName
            }, $true)
            if (@($hit).Count -gt 0) { return $clause.Item2 }
        }
    }
    return $null
}

# True iff the AST subtree contains a string constant equal to $Value.
function Test-AstContainsStringConstant {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Value)
    Write-Verbose "Searching AST for string constant '$Value'"
    $hits = $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $Value
    }, $true)
    return (@($hits).Count -gt 0)
}

# The parsed function ASTs are built at file scope, above the first Describe. A
# Describe body is evaluated during the discovery pass and its scope is torn
# down before any It runs, so an AST captured inside one arrives at the
# assertions as $null; only file-level declarations that precede the first
# Describe are still in scope during the run pass.
$invokeAst  = Get-FunctionAst -Path $modulePath -FunctionName 'Invoke-TesseractOcr'
$wordboxAst = Get-FunctionAst -Path $modulePath -FunctionName 'Get-TesseractWordBox'
$findAst    = Get-FunctionAst -Path $modulePath -FunctionName 'Find-Tesseract'

Describe 'Test.Tesseract OCR invocations are single-pass, EAP-guarded, and diagnosable' {

    It 'Invoke-TesseractOcr invokes tesseract exactly once (no stderr re-run)' {
        Assert-Equal -Expected 1 -Actual (Get-VarInvocationCount -FuncAst $invokeAst -VarName 'tesseractExe') -Because `
            'a second invocation to capture stderr can diverge from the first and doubles the process spawn.'
    }
    It 'Get-TesseractWordBox invokes tesseract exactly once' {
        Assert-Equal -Expected 1 -Actual (Get-VarInvocationCount -FuncAst $wordboxAst -VarName 'tesseractExe') -Because `
            'the TSV path must not re-run tesseract to fetch stderr.'
    }
    It 'Invoke-TesseractOcr pins the native-command EAP via a real assignment' {
        Assert-True (Test-FunctionPinsNativeEap -FuncAst $invokeAst) -Because `
            'without $PSNativeCommandUseErrorActionPreference = $false a non-zero exit throws NativeCommandExitException on PS 7.4+ and bypasses the exit-code branch.'
    }
    It 'Get-TesseractWordBox pins the native-command EAP via a real assignment' {
        Assert-True (Test-FunctionPinsNativeEap -FuncAst $wordboxAst) -Because `
            'the TSV path shares the same EAP=Stop exposure as Invoke-TesseractOcr.'
    }
    It 'Invoke-TesseractOcr surfaces tesseract stderr in the thrown message' {
        Assert-True (Test-FunctionAssignsAndThrowsVar -FuncAst $invokeAst -VarName 'errMsg') -Because `
            'a failure must carry tesseract stderr, not just an exit code.'
    }
    It 'Get-TesseractWordBox surfaces tesseract stderr in the thrown message' {
        Assert-True (Test-FunctionAssignsAndThrowsVar -FuncAst $wordboxAst -VarName 'errMsg') -Because `
            'the bare exit-code throw is not diagnosable; the partitioned stderr must be included.'
    }
}

Describe 'Find-Tesseract has a real Linux filesystem-fallback branch' {

    It 'branches on $IsLinux (a real if-branch, not a comment mention)' {
        Assert-True ($null -ne (Get-IfBranchBodyOnVar -FuncAst $findAst -VarName 'IsLinux')) -Because `
            'Linux needs a filesystem fallback for parity with the Windows/macOS branches.'
    }
    It 'probes /usr/bin/tesseract inside the $IsLinux branch' {
        $body = Get-IfBranchBodyOnVar -FuncAst $findAst -VarName 'IsLinux'
        Assert-True ($null -ne $body -and (Test-AstContainsStringConstant -Ast $body -Value '/usr/bin/tesseract')) -Because `
            'the Linux branch must probe the standard package install path.'
    }
}
