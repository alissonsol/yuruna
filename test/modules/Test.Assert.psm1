<#PSScriptInfo
.VERSION 2026.08.19
.GUID 423d6743-1531-4ed7-b6b3-7d5bf06035c0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester assert scaffold
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
    One assertion vocabulary and one set of test scaffolds for every Pester
    suite in the repo.
.DESCRIPTION
    296 hand-rolled Assert-* definitions across 151 of 182 suites is the tax on
    every behavioral test the harness wants next, and it compounds: the count
    was 234 when it was first measured, because each new suite copies the
    helpers from a neighbour. This module is the one place they live.

    WHY Assert-Equal AND Assert-StringEqual ARE SEPARATE EXPORTS. The suites had
    drifted into three incompatible semantics for one name:

      * 91 suites compared by value      -- `$Expected -ne $Actual`
      * 14 suites compared string-coerced -- `"$Expected" -ne "$Actual"`
      *  4 suites additionally inverted the parameter order, so a positional
        call meant the opposite of what it meant everywhere else

    The two semantics are NOT separated by type strictness, which is the
    intuitive but wrong reading: `1 -ne '1'` is false, because PowerShell
    coerces the right operand to the left operand's type, so both forms accept
    it. Measured, they diverge in exactly these ways -- leading zeros,
    surrounding whitespace and float rendering (`1` vs `'01'`, `1.0` vs
    `'1.0'`) are equal by value and different as strings; `$null` against an
    empty string is the reverse; and, sharpest of all, `-ne` on ARRAYS filters
    element-wise rather than comparing, so value comparison REJECTS two
    identical arrays that string comparison accepts.

    That array behavior is why the coercing callers move to Assert-StringEqual
    rather than being folded into Assert-Equal: a suite comparing two collections
    through the coercing helper passes today and would begin failing under value
    semantics, for a reason that has nothing to do with the code under test.

    Parameter ALIASES carry the historical spellings (-Value for -Actual,
    -Expected for -NotExpected, -Action for -Script, -Findings for -Finding).
    That is deliberate: it lets ~2,800 existing call sites keep working
    untouched, so the migration is "delete the local copy, import this" rather
    than a rewrite of every assertion in the repo.

    Assertions throw rather than using Pester's Should. The suites were written
    that way so they also run as plain scripts, and preserving it keeps the
    migration behavior-preserving.
#>

Set-StrictMode -Version Latest

# --- REGION: Assertions

function Assert-True {
    <#
    .SYNOPSIS
    Fails unless the condition is truthy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Condition,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if (-not $Condition) { throw "Expected true. $Because" }
}

function Assert-False {
    <#
    .SYNOPSIS
    Fails unless the condition is falsy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Condition,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($Condition) { throw "Expected false. $Because" }
}

function Assert-Equal {
    <#
    .SYNOPSIS
    Fails unless the two values are equal BY VALUE. Use Assert-StringEqual when
    the comparison is deliberately between string renderings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Expected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" }
}

function Assert-StringEqual {
    <#
    .SYNOPSIS
    Fails unless the two values render to the same string. Distinct from
    Assert-Equal so that a deliberate coercion is visible at the call site
    rather than hidden in a local helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Expected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-NotEqual {
    <#
    .SYNOPSIS
    Fails when the two values are equal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Expected')]$NotExpected,
        [Parameter(Position = 1)]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($NotExpected -eq $Actual) { throw "Expected NOT [$NotExpected]. $Because" }
}

function Assert-Null {
    <#
    .SYNOPSIS
    Fails unless the value is $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Value')]$Actual,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($null -ne $Actual) { throw "Expected null, got [$Actual]. $Because" }
}

function Assert-NotNull {
    <#
    .SYNOPSIS
    Fails when the value is $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Value')]$Actual,
        [Parameter(Position = 1)][string]$Because = ''
    )
    if ($null -eq $Actual) { throw "Expected a value, got null. $Because" }
}

function Assert-Match {
    <#
    .SYNOPSIS
    Fails unless the value matches the regular expression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Pattern,
        [Parameter(Position = 1)][string]$Actual,
        [Parameter(Position = 2)][string]$Because = ''
    )
    if ($Actual -notmatch $Pattern) { throw "Expected [$Actual] to match '$Pattern'. $Because" }
}

function Assert-Throw {
    <#
    .SYNOPSIS
    Fails unless the scriptblock throws, optionally requiring the message to
    match a pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('Action')][scriptblock]$Script,
        [Parameter(Position = 1)][string]$Match = '',
        [Parameter(Position = 2)][string]$Because = ''
    )
    $threw = $false
    try {
        & $Script
    } catch {
        $threw = $true
        if ($Match -and ($_.Exception.Message -notmatch $Match)) {
            throw "Threw, but message '$($_.Exception.Message)' did not match '$Match'. $Because"
        }
    }
    if (-not $threw) { throw "Expected a throw. $Because" }
}

function Assert-NoFinding {
    <#
    .SYNOPSIS
    Fails when a collected finding list is non-empty, reporting every entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][Alias('Findings')][string[]]$Finding,
        [Parameter(Position = 1)][string]$Because = ''
    )
    $list = @($Finding | Where-Object { $_ })
    if ($list.Count -gt 0) { throw ("$Because`n  " + ($list -join "`n  ")) }
}

# --- REGION: Scaffolds

function Get-YurunaTestRepoRoot {
    <#
    .SYNOPSIS
    The repository root, from the calling suite's own location.
    .DESCRIPTION
    The suites derived this 12 different ways across 63 assignments, two
    spellings accounting for most of them and returning the same path. -Depth
    exists because the suites do not all sit at the same level: those under
    test/modules/ are two below the root, and host/modules/ is two as well, but
    a suite added elsewhere would not be -- so the walk is stated, not assumed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SuiteDirectory,
        [int]$Depth = 2
    )
    $path = $SuiteDirectory
    for ($i = 0; $i -lt $Depth; $i++) { $path = Split-Path -Parent $path }
    (Resolve-Path -LiteralPath $path).Path
}

function New-YurunaTestTempDir {
    <#
    .SYNOPSIS
    A fresh, empty, uniquely-named temp directory for one test case.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway directory under the temp path; there is nothing for an operator to confirm.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Prefix = 'yuruna-test')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $dir
    $dir
}

function Remove-YurunaTestTempDir {
    <#
    .SYNOPSIS
    Removes a directory created by New-YurunaTestTempDir, never throwing.
    .DESCRIPTION
    Cleanup runs in a finally block, where a throw would replace the real test
    failure with a tidying-up error and hide what actually went wrong.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes only a directory this module created under the temp path.')]
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][string]$Path)
    if (-not $Path) { return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-YurunaTestFileAst {
    <#
    .SYNOPSIS
    Parses a PowerShell file and returns its AST, throwing on a parse error.
    .DESCRIPTION
    39 suites hand-rolled this, and the ones that omitted the error check
    reported a confusing downstream failure instead of naming the file that
    would not parse.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
    $ast
}

function Get-YurunaTestFunctionAst {
    <#
    .SYNOPSIS
    Returns the named function's AST from a file, or $null when it is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )
    $ast = Get-YurunaTestFileAst -Path $Path
    $wanted = $Name
    $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
        }.GetNewClosure(), $true) | Select-Object -First 1
}

Export-ModuleMember -Function `
    Assert-True, Assert-False, Assert-Equal, Assert-StringEqual, Assert-NotEqual, `
    Assert-Null, Assert-NotNull, Assert-Match, Assert-Throw, Assert-NoFinding, `
    Get-YurunaTestRepoRoot, New-YurunaTestTempDir, Remove-YurunaTestTempDir, `
    Get-YurunaTestFileAst, Get-YurunaTestFunctionAst
