<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42b4d8d1-37cf-4d00-a46b-5ef05b3f5c62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation loglevel pester
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
    Structural Pester guard: the logLevel cascade is defined once in
    Yuruna.LogLevel.psm1 and every automation entrypoint delegates to it.
.DESCRIPTION
    Nine automation scripts each open-coded the identical 6-statement cascade
    (a $_logRank map + four $global:*Preference assignments). That block is now
    Set-YurunaLogLevel in Yuruna.LogLevel.psm1 (a stateless leaf, imported
    -Global -Force at the top of each entrypoint before it evicts + re-imports the
    Yuruna.* operation modules). These guards assert the helper exists + is
    exported, every entrypoint imports the leaf and calls Set-YurunaLogLevel, and
    none still inlines the raw $_logRank cascade. Source-text only. Runs under
    Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'
$module   = Join-Path $autoDir 'Yuruna.LogLevel.psm1'
$entrypoints = 'yuruna','Set-Component','Set-Resource','Set-Workload','Invoke-Clear',
               'Test-Configuration','Test-Requirement','Test-Runtime','Get-SystemDiagnostic'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'yuruna-loglevel -- the logLevel cascade lives once in the Yuruna.LogLevel leaf' {
    It 'Yuruna.LogLevel defines and exports Set-YurunaLogLevel' {
        $src = Get-Content -LiteralPath $module -Raw
        Assert-True ($src -match '(?m)^function Set-YurunaLogLevel\b') 'Set-YurunaLogLevel must be defined'
        Assert-True (($src -split "`n" | Where-Object { $_ -match 'Export-ModuleMember' }) -match 'Set-YurunaLogLevel') 'must be exported'
    }
    It 'the cascade (the $_logRank map + 4 $global preference assigns) exists in exactly one place -- the helper' {
        # The raw $_logRank assignment must appear once (in the helper) and in none of the entrypoints.
        $inHelper = ([regex]::Matches((Get-Content -LiteralPath $module -Raw), [regex]::Escape('$rank = @{ Error = 1'))).Count
        Assert-True ($inHelper -eq 1) "the helper must hold the one cascade table, found $inHelper"
        foreach ($e in $entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            $n = ([regex]::Matches($src, [regex]::Escape('$_logRank = @{ Error=1'))).Count
            Assert-True ($n -eq 0) "$e must not inline the cascade table, found $n"
        }
    }
    It 'every entrypoint imports the leaf and delegates to Set-YurunaLogLevel' {
        foreach ($e in $entrypoints) {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            Assert-True ($src -match "Import-Module[^\n]*Yuruna\.LogLevel\.psm1") "$e must import Yuruna.LogLevel"
            $n = ([regex]::Matches($src, [regex]::Escape('Set-YurunaLogLevel -LogLevel $logLevel'))).Count
            Assert-True ($n -eq 1) "$e must call Set-YurunaLogLevel once, found $n"
        }
    }
}
