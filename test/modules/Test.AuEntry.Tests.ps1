<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42d5e6f7-a8b9-4c01-9d23-ef4a5b6c7d82
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation entrypoint resolve-path literalpath pester
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
    Path-resolution hardening (-LiteralPath plus an explicit single-match count check, so a
    wildcard-metachar folder name is not glob-expanded and a multi-match does not
    false-pass) lives once in the shared Resolve-YurunaRootSet helper; each of the five
    deployment entrypoints delegates to it and scopes its pre-import module eviction to
    Yuruna.* so unrelated modules in a shared session survive.
.DESCRIPTION
    The resolution prelude was hoisted into automation/Yuruna.LogLevel.psm1
    (Resolve-YurunaRootSet), so the AST guards assert the hardened -LiteralPath/count shape
    on that helper's command/comparison nodes, plus that each top-level deploy CLI -- which
    cannot be unit-invoked -- delegates to the helper and keeps a Yuruna.*-scoped eviction.
    One semantic test demonstrates the wildcard-glob hazard the -LiteralPath switch closes.
    Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'
$entrypoints = 'yuruna.ps1', 'Set-Component.ps1', 'Set-Resource.ps1', 'Set-Workload.ps1', 'Invoke-Clear.ps1'

function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
function Get-ResolvePathTargeting {
    # The Resolve-Path CommandAst whose argument references $<TargetVar>.
    param($Ast, [string]$TargetVar)
    $needle = '$' + $TargetVar
    $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Resolve-Path' -and
        $n.Extent.Text.Contains($needle)
    }, $true) | Select-Object -First 1
}
function Test-HasCountNeOne {
    # A '-ne 1' comparison whose left operand is @($<ResolvedVar>).Count.
    param($Ast, [string]$ResolvedVar)
    $needle = '$' + $ResolvedVar
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Ine -and
        $n.Left.Extent.Text.Contains($needle) -and
        $n.Left.Extent.Text -match 'Count'
    }, $true)).Count -ge 1
}
function Get-EvictionGetModule {
    # The Get-Module feeding the Remove-Module eviction pipeline.
    param($Ast)
    $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Get-Module'
    }, $true) | Select-Object -First 1
}

# The parsed ASTs live at file scope because a Describe/Context body is executed during
# test discovery and its variables are discarded before any It runs; only the file's own
# scope is still on the chain when an It executes. The per-entrypoint AST is keyed by file
# name and the key is handed to each It as test-case data, since the discovery-time loop
# variable is likewise gone by then.
$helperAst     = Get-FileAst (Join-Path $autoDir 'Yuruna.LogLevel.psm1')
$entrypointAst = @{}
foreach ($entrypoint in $entrypoints) {
    $entrypointAst[$entrypoint] = Get-FileAst (Join-Path $autoDir $entrypoint)
}

Describe 'Deployment entrypoints delegate hardened path resolution and scope module eviction' {
    Context 'Resolve-YurunaRootSet helper (automation/Yuruna.LogLevel.psm1)' {
        It 'resolves the project root with -LiteralPath (not -Path)' {
            $c = Get-ResolvePathTargeting -Ast $helperAst -TargetVar 'ProjectRoot'
            $c | Should -Not -BeNullOrEmpty
            $c.Extent.Text | Should -Match '-LiteralPath'
            $c.Extent.Text | Should -Not -Match '-Path\s+\$ProjectRoot'
        }
        It 'resolves the config root with -LiteralPath (not -Path)' {
            $c = Get-ResolvePathTargeting -Ast $helperAst -TargetVar 'configRelative'
            $c | Should -Not -BeNullOrEmpty
            $c.Extent.Text | Should -Match '-LiteralPath'
        }
        It 'validates the project resolution resolves to exactly one path' {
            (Test-HasCountNeOne -Ast $helperAst -ResolvedVar 'resolvedRoot') | Should -BeTrue
        }
        It 'validates the config resolution resolves to exactly one path' {
            (Test-HasCountNeOne -Ast $helperAst -ResolvedVar 'configRoot') | Should -BeTrue
        }
    }

    foreach ($name in $entrypoints) {
        Context $name {
            It 'delegates root resolution to Resolve-YurunaRootSet' -TestCases @(@{ EntryName = $name }) {
                param($EntryName)
                $call = $entrypointAst[$EntryName].FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Resolve-YurunaRootSet'
                }, $true) | Select-Object -First 1
                $call | Should -Not -BeNullOrEmpty
            }
            It 'scopes the pre-import module eviction to Yuruna.*' -TestCases @(@{ EntryName = $name }) {
                param($EntryName)
                $gm = Get-EvictionGetModule -Ast $entrypointAst[$EntryName]
                $gm | Should -Not -BeNullOrEmpty
                # The eviction Get-Module must carry a Yuruna.* filter argument, not run bare.
                # Accept either the positional (Get-Module Yuruna.*) or the -Name Yuruna.* form
                # by scanning every element past the command name, so the guard pins the scoping
                # intent rather than one argument position.
                ($gm.CommandElements.Count -ge 2) | Should -BeTrue
                $filtered = @($gm.CommandElements | Select-Object -Skip 1 | Where-Object { $_.Extent.Text -match 'Yuruna' })
                $filtered.Count | Should -BeGreaterOrEqual 1
            }
        }
    }
}

Describe 'The wildcard-glob hazard the -LiteralPath switch closes' {
    It 'a wildcard-metachar folder name resolves under -LiteralPath but globs under -Path' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("auentry-" + [System.Guid]::NewGuid().ToString('N'))
        # A literal folder name containing bracket metacharacters.
        $bracket = Join-Path $root 'proj[1]'
        New-Item -ItemType Directory -Path $bracket -Force | Out-Null
        try {
            $literal = Resolve-Path -LiteralPath $bracket -ErrorAction SilentlyContinue
            $globbed = Resolve-Path -Path      $bracket -ErrorAction SilentlyContinue
            # -LiteralPath finds the exact folder; -Path treats [1] as a character class
            # and (with no sibling matching) resolves to nothing, so an emptiness-only
            # check false-passes while a single-match count check catches it.
            @($literal).Count | Should -Be 1
            $literal.Path     | Should -Be $bracket
            [string]::IsNullOrEmpty($globbed) | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
