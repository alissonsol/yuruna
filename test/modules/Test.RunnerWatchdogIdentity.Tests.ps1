<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e5f6a7-b8c9-4d02-9345-6e7f8a9b0c1d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner watchdog identity pid pester
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
    Guards on the watchdog's PID-identity check: it tells the armed inner apart
    from an unrelated process that later reused its PID, and both the disarm and
    the kill decisions honor that identity.
.DESCRIPTION
    Behavioral: the predicate returned by Get-WatchdogInnerIdentityScript (the ONE
    definition the watchdog job rebuilds via [scriptblock]::Create) is true only for
    a live process whose StartTime matches the recorded arm-time value -- the same
    PID with a different StartTime (a reused PID), a gone PID, and an empty recorded
    start are all not-the-same-inner.

    Structural (AST, so a comment cannot satisfy a guard): the watchdog captures the
    inner StartTime at arm ($innerStartUtc), both the disarm and the kill decisions
    are gated on the identity predicate (& $sameInner), and Stop-Process fires only
    inside an identity-gated branch -- so a reused PID is neither mistaken for a live
    inner nor killed. Keyed on AST nodes; all fail if the identity gating is removed.

    The throw-free Should assertions run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.RunnerWatchdog.psm1'
Import-Module $modPath -Force

# Unqualified and above the first Describe: an It block resolves a plain file-scope
# name through its parent scope chain, but a $script:-qualified one binds to the test
# framework's own script scope and reads back $null once the run phase starts.
$IdentitySb = [scriptblock]::Create((Get-WatchdogInnerIdentityScript))

# --- REGION: AST helpers (file scope; referenced from It blocks)
function Get-ModuleAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
    return $ast
}

function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true)).Count
}

# Count of if-statement conditions whose text matches $Pattern (AST nodes only).
function Get-IfConditionMatchCount {
    param($Ast, [string]$Pattern)
    $pat = $Pattern
    $c = 0
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { if ($clause.Item1.Extent.Text -match $pat) { $c++ } }
    }
    $c
}

function Get-AssignmentCount {
    param($Ast, [string]$Lhs)
    $wl = $Lhs
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $wl
    }, $true)).Count
}

# True when EVERY Stop-Process invocation sits inside an if-condition matching
# $Pattern (i.e. the kill is identity-gated), and at least one exists.
function Test-StopProcessGatedBy {
    param($Ast, [string]$Pattern)
    $pat = $Pattern
    $stops = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-Process'
    }, $true))
    if ($stops.Count -lt 1) { return $false }
    foreach ($sp in $stops) {
        $p = $sp.Parent; $gated = $false
        while ($p) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst] -and
                ($p.Clauses[0].Item1.Extent.Text -match $pat)) { $gated = $true; break }
            $p = $p.Parent
        }
        if (-not $gated) { return $false }
    }
    return $true
}

Describe 'Get-WatchdogInnerIdentityScript predicate distinguishes a reused PID' {
    It 'is true for a live process whose recorded StartTime matches' {
        $start = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        (& $IdentitySb $PID $start) | Should -Be $true
    }
    It 'is false for the SAME live PID with a different StartTime (a reused PID)' {
        (& $IdentitySb $PID '2000-01-01T00:00:00.0000000Z') | Should -Be $false
    }
    It 'is false for an exited PID' {
        $proc = Start-Process -FilePath ([System.Environment]::ProcessPath) `
            -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden
        $proc.WaitForExit()
        (& $IdentitySb $proc.Id '2026-01-01T00:00:00.0000000Z') | Should -Be $false
    }
    It 'is false when no arm-time start was recorded (identity unprovable)' {
        (& $IdentitySb $PID '') | Should -Be $false
    }
}

Describe 'Watchdog gates disarm and kill on the armed identity' {
    It 'captures the inner StartTime at arm time' {
        (Get-AssignmentCount -Ast (Get-ModuleAst) -Lhs '$innerStartUtc') | Should -BeGreaterOrEqual 1
    }
    It 'wires the shared identity predicate into the watchdog' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Get-WatchdogInnerIdentityScript') | Should -BeGreaterOrEqual 1
    }
    It 'gates both the disarm and the kill decisions on the identity predicate' {
        (Get-IfConditionMatchCount -Ast (Get-ModuleAst) -Pattern 'sameInner') | Should -BeGreaterOrEqual 2
    }
    It 'kills only inside an identity-gated branch (never an unrelated reused PID)' {
        (Test-StopProcessGatedBy -Ast (Get-ModuleAst) -Pattern 'sameInner') | Should -Be $true
    }
}
