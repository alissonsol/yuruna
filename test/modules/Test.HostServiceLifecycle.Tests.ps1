<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42b6c7d8-e9f0-4a12-8b34-5c6d7e8f9a01
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service lifecycle pid pester
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
    Structural (AST) guards on the host-service lifecycle entry-point scripts:
    Stop-HostConfigService.ps1, Stop-StatusService.ps1, Start-HostConfigService.ps1,
    and Start-StashServer.ps1.
.DESCRIPTION
    These scripts run top-to-bottom with `exit`/`return` and heavy I/O
    (Import-Module, runtime-dir init, process control), so they are not
    invoked in-process here; instead the tests parse each file and assert the
    required defensive SHAPE via AST nodes (method invocations, command
    arguments, string literals) rather than raw source text -- so a code comment
    cannot satisfy a guard and reformatting cannot break one.

    Pinned invariants:
      * Both Stop-* scripts gate on an [int]::TryParse of the PID file (the parse
        result controls a stale-PID exit) before Get-Process/Stop-Process, and
        pass the typed int (not the raw string) to -Id -- a raw non-numeric
        string reaches -Id and throws a ParameterBindingException that
        -ErrorAction SilentlyContinue does NOT suppress.
      * Start-HostConfigService gates on an [int]::TryParse of the Linux detached
        child's echoed PID and probes Get-Process -Id $bgPidInt right after
        launch, so a PID file is never written for a process that died
        immediately.

    These are structural guards: they verify the required nodes are present and
    correctly shaped/gated, not that the scripts execute correctly end to end.
      * Start-StashServer captures the status-service start decision (rather than
        discarding it) and TCP-probes the status port via BeginConnect, warning
        when the host will not be reachable by the pool aggregator.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$stopHostConfig  = Join-Path $testDir 'Stop-HostConfigService.ps1'
$stopStatus      = Join-Path $testDir 'Stop-StatusService.ps1'
$startHostConfig = Join-Path $testDir 'Start-HostConfigService.ps1'
$startStash      = Join-Path $testDir 'Start-StashServer.ps1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ScriptAst {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

function Get-CommandCall {
    param($Ast, [string]$Name)
    # Bind to a local so the parameter is referenced in the function body itself
    # (the closure below captures it, but PSReviewUnusedParameter cannot see a
    # use that only occurs inside a scriptblock handed to another command).
    $wanted = $Name
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted }, $true))
}

# Text of the argument bound to -Id on a Get-Process/Stop-Process CommandAst.
function Get-IdArgumentText {
    param($CommandAst)
    $els = $CommandAst.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Id') {
            $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
            if ($arg) { return $arg.Extent.Text }
        }
    }
    return $null
}

# Names of every .Method(...) / [Type]::Method(...) invocation in the tree (AST
# InvokeMemberExpressionAst). Comments are not AST nodes, so a phrase inside a
# comment cannot satisfy a membership test against this list.
function Get-InvokedMember {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        ForEach-Object { $_.Member.Extent.Text })
}

# Names of every method invoked INSIDE an if-statement condition. A guard that
# checks membership here verifies the invocation gates a branch (e.g. the
# [int]::TryParse result controls the stale-PID exit), not merely that it appears
# somewhere as a discarded expression.
function Get-IfConditionMember {
    param($Ast)
    $names = @()
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) {
            $names += @($clause.Item1.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
                ForEach-Object { $_.Member.Extent.Text })
        }
    }
    $names
}

# String LITERAL nodes only (excludes comments), so a phrase match cannot be
# satisfied by an unrelated code comment.
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

# True when some assignment binds the named command's result to a REAL variable
# (not the $null / $_ discard idioms, which capture nothing) -- proving the
# result is retained rather than thrown away.
function Test-AssignsFromCommand {
    param($Ast, [string]$Command)
    $wanted = $Command
    foreach ($a in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $lhs = $a.Left
        if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $lhsName = $lhs.VariablePath.UserPath
            if ($lhsName -eq 'null' -or $lhsName -eq '_') { continue }
        }
        foreach ($c in @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            if ($c.GetCommandName() -eq $wanted) { return $true }
        }
    }
    return $false
}

Describe 'Stop-* scripts parse the PID defensively before process control' {
    foreach ($case in @(
        @{ Name = 'Stop-HostConfigService.ps1'; Path = $stopHostConfig },
        @{ Name = 'Stop-StatusService.ps1';     Path = $stopStatus }
    )) {
        It "$($case.Name) gates on [int]::TryParse and passes only the typed int to -Id" {
            $ast = Get-ScriptAst $case.Path
            Assert-True ((Get-InvokedMember -Ast $ast) -contains 'TryParse') 'a real [int]::TryParse invocation guards the PID (a comment does not count)'
            Assert-True ((Get-IfConditionMember -Ast $ast) -contains 'TryParse') 'the [int]::TryParse result gates an if-branch (not an ignored expression)'
            foreach ($cmd in @('Get-Process', 'Stop-Process')) {
                foreach ($call in (Get-CommandCall -Ast $ast -Name $cmd)) {
                    $idText = Get-IdArgumentText -CommandAst $call
                    Assert-True ($idText -eq '$id') "$cmd -Id must use the validated int variable, got '$idText'"
                }
            }
        }
    }
}

Describe 'Start-HostConfigService.ps1 verifies the Linux child survived launch' {
    It 'gates on [int]::TryParse of the echoed PID and probes Get-Process -Id $bgPidInt' {
        $ast = Get-ScriptAst $startHostConfig
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'TryParse') '[int]::TryParse validates the echoed child PID'
        Assert-True ((Get-IfConditionMember -Ast $ast) -contains 'TryParse') 'the [int]::TryParse result gates the survival branch'
        $probes = @(Get-CommandCall -Ast $ast -Name 'Get-Process' |
            Where-Object { (Get-IdArgumentText -CommandAst $_) -eq '$bgPidInt' })
        Assert-True ($probes.Count -ge 1) 'Get-Process -Id $bgPidInt survival probe is present'
    }
}

Describe 'Start-StashServer.ps1 surfaces status-server unreachability' {
    It 'captures the start decision, TCP-probes the status port, and warns on unreachable' {
        $ast = Get-ScriptAst $startStash
        Assert-True (Test-AssignsFromCommand -Ast $ast -Command 'Start-YurunaStatusServiceIfEnabled') 'the start decision is captured in an assignment (not discarded)'
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'BeginConnect') 'the status port is TCP-probed via BeginConnect'
        $warn = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -match 'not appear under Extension hosts' })
        Assert-True ($warn.Count -ge 1) 'a warning literal ties an unreachable status port to Extension-hosts absence'
    }
}
