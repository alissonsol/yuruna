<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42661f19-ab56-40f2-a9f7-2065d442903c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test setup loglevel pester
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
    Structural Pester guard: install/setup.ps1 takes -logLevel, and the level it
    resolves reaches every script it starts.
.DESCRIPTION
    A setup run is one parent and a dozen children in their own pwsh processes.
    PowerShell preference variables stop at the process boundary, so the level
    travels as $env:YURUNA_LOG_LEVEL (published by Resolve-LogLevel, applied by
    Use-LogLevelFromEnv) -- and as an explicit argument across the Windows
    elevated relaunch, which RunAs builds through the AppInfo service without
    carrying this process's environment.

    That makes the chain silently breakable from either end: a child that stops
    calling Use-LogLevelFromEnv goes quiet at -logLevel Debug, and a relaunch
    that stops forwarding the argument drops the level at exactly the point a
    Windows run starts doing the work worth watching. Both failures look like
    "the flag did nothing", which is indistinguishable from a run that had
    nothing to say. Asserted here, on source text and AST, so neither needs a
    full bring-up to catch.

    See docs/loglevels.md for the cascade itself.
    Run: Invoke-Pester -Path test/modules/Test.SetupLogLevel.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$setup    = Join-Path $repoRoot 'install/setup.ps1'

function Assert-True { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-ScriptAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

$setupAst = Get-ScriptAst -Path $setup
$setupSrc = Get-Content -LiteralPath $setup -Raw

# Every repo script install/setup.ps1 starts in a child pwsh. Read from the
# Invoke-RepoScript / Invoke-ServiceVMReset call sites rather than listed by
# hand, so a step added to the setup is held to the same contract without
# anyone remembering to add it here.
function Get-SetupChildScriptName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($literal in $Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)) {
        $value = $literal.Value
        if ($value -match '^[A-Za-z]+-[A-Za-z0-9]+\.ps1$' -and -not $names.Contains($value)) {
            $names.Add($value)
        }
    }
    return $names.ToArray()
}

Describe 'setup -logLevel -- the parameter exists and carries the whole cascade' {

    It 'declares -logLevel over the five canonical levels' {
        $param = $setupAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'logLevel' }
        Assert-True ($null -ne $param) 'install/setup.ps1 must take -logLevel'
        $validate = $param.Attributes |
            Where-Object { $_.TypeName.Name -match '^ValidateSet$' } | Select-Object -First 1
        Assert-True ($null -ne $validate) '-logLevel must be constrained by a ValidateSet, so a typo fails at bind time'
        $values = @($validate.PositionalArguments | ForEach-Object { $_.Value })
        foreach ($level in 'Error', 'Warning', 'Information', 'Verbose', 'Debug') {
            Assert-True ($values -contains $level) "the ValidateSet must offer '$level'"
        }
    }

    It 'resolves through the shared cascade rather than its own preference edits' {
        Assert-True ($setupSrc -match 'Test\.LogLevel\\Resolve-LogLevel') `
            'the level must come from Test.LogLevel (which is what publishes $env:YURUNA_LOG_LEVEL); a private cascade would reach no child'
    }

    It 'forwards the resolved level across the Windows elevated relaunch' {
        # The relaunch is the one hop the environment does not survive: RunAs
        # builds the process through the AppInfo service.
        Assert-True ($setupSrc -match "relaunchArgs \+= @\('-logLevel'") `
            'the elevated run must be given the level as an argument, like it is given -LogPath'
    }

    It 'records the level in the run log header' {
        Assert-True ($setupSrc -match "log level\s*:") `
            'a transcript missing what someone expected has to say which level produced it'
    }
}

Describe 'setup -logLevel -- every script the setup starts honours the inherited level' {

    It 'each child script calls Use-LogLevelFromEnv' {
        $missing = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($name in (Get-SetupChildScriptName -Ast $setupAst)) {
            $path = Join-Path $repoRoot (Join-Path 'test' $name)
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $checked++
            if ((Get-Content -LiteralPath $path -Raw) -notmatch 'Use-LogLevelFromEnv') {
                $missing.Add($name)
            }
        }
        Assert-True ($checked -ge 8) "expected to find the setup's child scripts under test/; found $checked"
        Assert-True ($missing.Count -eq 0) `
            "these scripts run under setup.ps1 but ignore `$env:YURUNA_LOG_LEVEL, so -logLevel Debug leaves them silent: $($missing -join ', ')"
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
