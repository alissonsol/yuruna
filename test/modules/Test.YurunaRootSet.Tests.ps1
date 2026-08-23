<#PSScriptInfo
.VERSION 2026.08.23
.GUID 42a0c011-c5f6-4739-968e-b876a31dcd75
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation rootset pester
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
    Structural Pester guard: the project/config root-resolution prelude is defined
    once in Yuruna.LogLevel.psm1 (Resolve-YurunaRootSet) and the five main
    entrypoints delegate to it.
.DESCRIPTION
    yuruna.ps1 and the four Set-*/Invoke-Clear entrypoints each open-coded the same
    root-resolution prelude -- resolve yuruna_root, default + Resolve-Path the
    project root (guarding missing/ambiguous), resolve config/<subfolder> (same
    guard), and export the three Env: items. That block is now Resolve-YurunaRootSet
    in Yuruna.LogLevel.psm1, called BEFORE the Yuruna.* module eviction (the resolver
    lives in the leaf that the eviction later sweeps up). These guards assert the
    resolver exists + is exported, each entrypoint delegates to it, and none still
    inlines the raw project-root Resolve-Path guard. Source-text only. Runs under
    Pester 4.10.1.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'
$script:module   = Join-Path $autoDir 'Yuruna.LogLevel.psm1'
$script:entrypoints = 'yuruna','Set-Component','Set-Resource','Set-Workload','Invoke-Clear'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'yuruna-rootset -- root resolution lives once, called before the eviction' {
    It 'Yuruna.LogLevel defines and exports Resolve-YurunaRootSet' {
        $src = Get-Content -LiteralPath $script:module -Raw
        Assert-True ($src -match '(?m)^function Resolve-YurunaRootSet\b') 'Resolve-YurunaRootSet must be defined'
        Assert-True (($src -split "`n" | Where-Object { $_ -match 'Export-ModuleMember' }) -match 'Resolve-YurunaRootSet') 'must be exported'
    }
    It 'the raw project-root Resolve-Path guard lives in exactly one place -- the resolver' {
        $needle = '$resolved_root = Resolve-Path -LiteralPath $project_root'
        $inModule = ([regex]::Matches((Get-Content -LiteralPath $script:module -Raw), [regex]::Escape('Resolve-Path -LiteralPath $ProjectRoot'))).Count
        Assert-True ($inModule -eq 1) "the resolver must own the one project-root Resolve-Path, found $inModule"
        foreach ($e in $script:entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            $n = ([regex]::Matches($src, [regex]::Escape($needle))).Count
            Assert-True ($n -eq 0) "$e must not inline the project-root guard, found $n"
        }
    }
    It 'each entrypoint delegates to Resolve-YurunaRootSet before the eviction' {
        foreach ($e in $script:entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            $callIdx  = $src.IndexOf('Resolve-YurunaRootSet -ScriptRoot $PSScriptRoot')
            $evictIdx = $src.IndexOf('Get-Module Yuruna.* | Remove-Module')
            Assert-True ($callIdx -ge 0) "$e must call Resolve-YurunaRootSet"
            Assert-True ($evictIdx -ge 0) "$e must still evict Yuruna.* modules"
            Assert-True ($callIdx -lt $evictIdx) "$e must call the resolver BEFORE the eviction (else the resolver's own module is already gone)"
        }
    }
}
