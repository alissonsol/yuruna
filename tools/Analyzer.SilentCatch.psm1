<#PSScriptInfo
.VERSION 2026.11.05
.GUID 429b5807-8003-4dea-bd4b-a962d5f7a4df
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lint pssa analyzer-rule catch
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

# A PSScriptAnalyzer rule that PSScriptAnalyzerSettings.psd1 loads through
# CustomRulePath. A catch block whose whole body discards the error -- an empty
# body, or one whose only statement assigns $_ to $null -- hides the failure
# from every log and from every later decision. The rule reads the parsed
# script, never its text, so a catch inside a string (C# handed to Add-Type,
# JavaScript, PowerShell written out for later) is never counted.
#
# The Pester suites (*.Tests.ps1) are exempt. Every other file may hold at most
# the number of such catches listed for it in silent-catch.allowance.json beside
# this module or, for a file under dev-only/, in
# dev-only/tools/silent-catch.allowance.json, which the release strips with the
# files it names. An unlisted file may hold none. The lists only shrink:
# Test.SilentCatchRule fails while an entry differs from what its file holds,
# so the change that fixes a catch also lowers its file's entry.
#
# PSScriptAnalyzer resolves a CustomRulePath against the current location, not
# against the settings file, so the settings are used from the repository
# root; from anywhere else the analyzer stops on the missing rule.

# --- REGION: Find-SilentCatchClause
function Find-SilentCatchClause {
    <#
    .SYNOPSIS
        The catch clauses of a parsed script whose whole body discards the error.
    .DESCRIPTION
        An empty body (a comment is not a statement), or a body whose only
        statement assigns $_ to $null. $PSItem is the same variable as $_.
        Spacing never reaches the syntax tree and the comparisons ignore case,
        so only the shape of the statement counts.
    .PARAMETER Ast
        The parsed script; nested script blocks are searched too.
    .OUTPUTS
        System.Management.Automation.Language.CatchClauseAst
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.CatchClauseAst])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    $Ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CatchClauseAst]) { return $false }
            $body = $node.Body
            if ($body.Traps) { return $false }
            if ($body.Statements.Count -eq 0) { return $true }
            if ($body.Statements.Count -ne 1) { return $false }
            $statement = $body.Statements[0]
            if ($statement -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
                $statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals -or
                $statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
                $statement.Left.VariablePath.UserPath -ne 'null' -or
                $statement.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $false }
            $value = $statement.Right.Expression
            return $value -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $value.VariablePath.UserPath -in @('_', 'PSItem')
        }, $true)
}

# --- REGION: Get-SilentCatchAllowance
function Get-SilentCatchAllowance {
    <#
    .SYNOPSIS
        How many catch blocks that discard the error a repository file may
        still hold, and the list that says so.
    .PARAMETER RelativePath
        The file's path below the repository root, with forward slashes.
    .OUTPUTS
        A [pscustomobject] carrying List (repository-relative) and Count.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RelativePath)

    $list = if ($RelativePath.StartsWith('dev-only/', [StringComparison]::Ordinal)) {
        'dev-only/tools/silent-catch.allowance.json'
    } else { 'tools/silent-catch.allowance.json' }
    $count = 0
    $path = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath $list
    # A list that is absent allows nothing. The private one is absent from the
    # public tree, which carries none of the files it names.
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $entry = (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).files.PSObject.Properties[$RelativePath]
        if ($entry) { $count = [int]$entry.Value }
    }
    return [pscustomobject]@{ List = $list; Count = $count }
}

# --- REGION: Measure-SilentCatch
function Measure-SilentCatch {
    <#
    .SYNOPSIS
        Report the catch blocks that discard the error in a file that holds
        more of them than its allowance.
    .DESCRIPTION
        The rule takes the file's tokens, not a syntax tree: PSScriptAnalyzer
        calls a token rule once per file, but a syntax-tree rule once for
        every node of its type (every script block, for a whole-file verdict),
        each call a pipeline of its own in a runspace pool it builds for that
        file. The tokens carry the whole text, and parsing it again costs less
        than one of those calls.

        A file over its allowance reports each such catch, because fixing any
        one of them brings the file back within it. Text analyzed without a
        file, such as an editor buffer, has no path to look up, so it is held
        to an allowance of none, as is a file outside this repository.
    .PARAMETER TestToken
        The tokens of the analyzed text.
    .OUTPUTS
        One DiagnosticRecord per catch block reported.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.Token[]]$TestToken)

    $start = $TestToken[0].Extent.StartScriptPosition
    $file = $start.File
    if ($file -and [IO.Path]::GetFileName($file) -like '*.Tests.ps1') { return }
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($start.GetFullScript(), $file, [ref]$null, [ref]$null)
    $silent = @(Find-SilentCatchClause -Ast $ast)
    if ($silent.Count -eq 0) { return }

    $relative = $null
    if ($file) {
        $relative = [IO.Path]::GetRelativePath((Split-Path -Parent $PSScriptRoot), $file) -replace '\\', '/'
        if ($relative -eq '..' -or $relative.StartsWith('../', [StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($relative)) { $relative = $null }
    }
    $allowance = if ($relative) { Get-SilentCatchAllowance -RelativePath $relative } else { $null }
    if ($allowance -and $silent.Count -le $allowance.Count) { return }

    foreach ($catch in $silent) {
        $shape = if ($catch.Body.Statements.Count -eq 0) { 'is empty' } else { 'only assigns $_ to $null' }
        $message = "This catch block $shape, which discards the error: write the reason (Write-Verbose or " +
            'Write-Warning), keep the error for a later decision, or rethrow it.'
        if ($allowance) {
            $message += " $relative holds $($silent.Count) such catch block(s) and $($allowance.List) allows " +
                "$($allowance.Count); that list only shrinks."
        }
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
            Message  = $message
            Extent   = $catch.Extent
            RuleName = 'Measure-SilentCatch'
            Severity = 'Warning'
        }
    }
}

# Only the rule is exported: PSScriptAnalyzer runs every exported function that
# takes a syntax tree or tokens as a rule of its own.
Export-ModuleMember -Function Measure-SilentCatch
