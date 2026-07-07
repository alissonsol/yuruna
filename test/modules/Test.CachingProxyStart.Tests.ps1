<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42a3b4c5-d6e7-4f89-8a01-2b3c4d5e6f70
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cachingproxy deadline lastexitcode pester
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
    Structural (AST) guards on Start-CachingProxy.ps1's UTM wait loops and its
    child-script ($GetImageScript / $NewVMScript) exit-code gates.
.DESCRIPTION
    Start-CachingProxy.ps1 builds a VM and exits, so it is not invoked in-process
    here; the tests parse it and assert the required SHAPE via AST nodes rather
    than raw source text, so a code comment cannot satisfy a guard.

    Pinned invariants:
      * The UTM register (30 s) and start-transition (15 s) waits loop on a
        [DateTime]::UtcNow deadline rather than an iteration counter (an $i-bounded
        for loop drifts past the stated timeout by the per-call utmctl latency).
        The bounded start-RETRY loop ($attempt -le 3) is a count, not a timer, and
        is intentionally left as a for loop.
      * The exit-code gates after & $GetImageScript / & $NewVMScript reset
        $LASTEXITCODE to $null before the call and test $null -ne $LASTEXITCODE,
        so a child .ps1 that ends on a cmdlet (no native command) does not
        false-fail on stale/absent $LASTEXITCODE.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here
$startCp = Join-Path $testDir 'Start-CachingProxy.ps1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-Ast {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

function Get-ForConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# Text of every if-statement condition (AST nodes only -- comments excluded).
function Get-IfConditionText {
    param($Ast)
    $texts = @()
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { $texts += $clause.Item1.Extent.Text }
    }
    $texts
}

# Count of `$LASTEXITCODE = $null` assignments (AssignmentStatementAst).
function Get-LastExitResetCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$LASTEXITCODE' -and
        $n.Right.Extent.Text -eq '$null'
    }, $true)).Count
}

Describe 'Start-CachingProxy.ps1 bounds the UTM waits by wall-clock' {
    It 'loops the register + start waits on a UtcNow deadline, not an $i iteration counter' {
        $ast = Get-Ast $startCp
        $utcWhiles = @(Get-WhileConditionText -Ast $ast | Where-Object { $_ -match 'UtcNow' })
        Assert-True ($utcWhiles.Count -ge 2) "the register + start waits both gate on [DateTime]::UtcNow; found $($utcWhiles.Count)"
        # Scoped to a timeout literal (-lt 30 / -lt 15) so this catches a reverted
        # iteration-counted TIME wait specifically, without false-failing a
        # legitimate fixed-count for loop (e.g. `for ($i -lt 3)`) or the retained
        # `$attempt -le 3` retry.
        $timeWaitFor = @(Get-ForConditionText -Ast $ast | Where-Object { $_ -match '-lt\s+(30|15)\b' })
        Assert-True ($timeWaitFor.Count -eq 0) "no UTM time wait is left as an iteration-counted for loop (a -lt 30/15 bound); found: $($timeWaitFor -join ' | ')"
    }
}

Describe 'Start-CachingProxy.ps1 gates child scripts on a reset $LASTEXITCODE' {
    It 'resets $LASTEXITCODE to $null before the child call and tests it null-safely' {
        $ast = Get-Ast $startCp
        Assert-True ((Get-LastExitResetCount -Ast $ast) -ge 2) 'both & $GetImageScript / & $NewVMScript are preceded by $LASTEXITCODE = $null'
        $nullSafe = @(Get-IfConditionText -Ast $ast | Where-Object { $_ -match '\$null -ne \$LASTEXITCODE' })
        Assert-True ($nullSafe.Count -ge 2) "both child-script gates use a null-safe `$null -ne `$LASTEXITCODE test; found $($nullSafe.Count)"
    }
}
