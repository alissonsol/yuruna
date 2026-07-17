<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42d8e9f0-a1b2-4c34-9d56-7e8f9a0b1c25
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-loop powershell-yaml preflight pester
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
    The outer resilient runner refuses to start when powershell-yaml is unavailable,
    routing the reason through Write-OuterLog, so it does not spin an eternal loop of
    silently-degraded cycles (the cycle planner cannot parse test.runner.yml without it).
.DESCRIPTION
    Invoke-TestRunner.ps1's powershell-yaml pre-flight is a top-level block that exits
    the process, so it is guarded structurally: the pre-flight's IfStatement body must
    contain an exit statement (the bounded, non-interactive refuse-to-start) and a
    Write-OuterLog call (so the reason lands in outer.log, not only the console Warning
    stream). Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$scriptPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'Invoke-TestRunner.ps1')).Path
# The AST is an unqualified file-scope variable: inside an It block a $script: reference
# resolves to the test runner's own script scope, not this file's, so a $script:-qualified
# fixture reaches the assertions as $null.
$errs = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
if ($errs) { throw "Parse errors in Invoke-TestRunner.ps1: $($errs[0].Message)" }

function Get-YamlPreflightIf {
    # The IfStatement whose CONDITION probes powershell-yaml availability via Get-Module.
    param($Ast)
    $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -match 'powershell-yaml' -and
        $n.Clauses[0].Item1.Extent.Text -match 'Get-Module'
    }, $true) | Select-Object -First 1
}
function Get-BodyNodeCount {
    param($Body, [scriptblock]$Predicate)
    @($Body.FindAll($Predicate, $true)).Count
}

Describe 'The outer runner hard-fails on a missing powershell-yaml' {
    It 'has a powershell-yaml availability pre-flight' {
        (Get-YamlPreflightIf -Ast $runnerAst) | Should -Not -BeNullOrEmpty
    }
    It 'refuses to start (the pre-flight body exits) rather than warn and continue' {
        $body = (Get-YamlPreflightIf -Ast $runnerAst).Clauses[0].Item2
        (Get-BodyNodeCount $body { param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }) |
            Should -BeGreaterOrEqual 1
    }
    It 'routes the reason through Write-OuterLog so it lands in outer.log' {
        $body = (Get-YamlPreflightIf -Ast $runnerAst).Clauses[0].Item2
        (Get-BodyNodeCount $body { param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-OuterLog'
        }) | Should -BeGreaterOrEqual 1
    }
    It 'actually exits the process (does not fall through) when powershell-yaml is absent' {
        # Run the extracted pre-flight block in a child pwsh with Get-Module stubbed to
        # report powershell-yaml missing and Write-OuterLog stubbed away. If the block
        # exits, the child returns 1 and the trailing marker never prints; a warn-and-
        # continue block would fall through to the marker and exit 0.
        $blockText = (Get-YamlPreflightIf -Ast $runnerAst).Extent.Text
        $child = @"
function Write-OuterLog { param([Parameter(ValueFromRemainingArguments)]`$a) }
function Get-Module { `$null }
function Get-EntryPointExitCode { param([string]`$Outcome) 1 }
$blockText
Write-Output 'FELL_THROUGH_MARKER'
"@
        $out = & pwsh -NoProfile -Command $child 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -Not -Match 'FELL_THROUGH_MARKER'
    }
}
