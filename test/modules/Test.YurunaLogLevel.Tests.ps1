<#PSScriptInfo
.VERSION 2026.07.21
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
# The test/host tree carries its own cascade (Set-LogLevelPreference et al.) with
# extra duties -- ProgressPreference save/restore and $env:YURUNA_LOG_LEVEL
# publication -- that the automation leaf deliberately omits. The two modules sit
# in separate directory trees with disjoint consumers, so folding one into the
# other would couple the trees; the rank table is duplicated on purpose. This
# parity guard is what keeps the duplication honest.
$testCascade = Join-Path $here 'Test.LogLevel.psm1'
$entrypoints = 'yuruna','Set-Component','Set-Resource','Set-Workload','Invoke-Clear',
               'Test-Configuration','Test-Requirement','Test-Runtime','Get-SystemDiagnostic'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Extract the log-level rank table (name -> integer) from a module's source by
# AST -- the one hashtable whose keys are exactly the five level names. Reading
# it structurally (rather than importing) avoids any load-time side effect and
# works across both spellings in use (a plain @{} and an [ordered]@{}).
function Get-LogLevelRankTableFromSource {
    param([Parameter(Mandatory)][string]$Path)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "Parse errors in ${Path}: $($parseErrors[0].Message)" }
    $levelNames = @('Error', 'Warning', 'Information', 'Verbose', 'Debug')
    $table = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
        Where-Object {
            $keys = @($_.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim() })
            @($levelNames | Where-Object { $keys -contains $_ }).Count -eq $levelNames.Count
        } | Select-Object -First 1
    if (-not $table) { throw "No log-level rank table found in $Path" }
    $map = [ordered]@{}
    foreach ($pair in $table.KeyValuePairs) {
        $map[$pair.Item1.Extent.Text.Trim()] = [int]$pair.Item2.Extent.Text.Trim()
    }
    return $map
}

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

Describe 'yuruna-loglevel -- the automation leaf and the test/host cascade agree on the rank table' {
    It 'both rank tables map the same level names to the same numeric ranks' {
        $automationRank = Get-LogLevelRankTableFromSource -Path $module
        $testRank       = Get-LogLevelRankTableFromSource -Path $testCascade
        # Same set of keys.
        $automationKeys = @($automationRank.Keys | Sort-Object)
        $testKeys       = @($testRank.Keys | Sort-Object)
        Assert-True (($automationKeys -join ',') -eq ($testKeys -join ',')) `
            "rank-table level names diverge: automation=[$($automationKeys -join ',')] test=[$($testKeys -join ',')]"
        # Same numeric rank for every key.
        foreach ($name in $automationKeys) {
            Assert-True ($automationRank[$name] -eq $testRank[$name]) `
                "rank for '$name' diverges: automation=$($automationRank[$name]) test=$($testRank[$name])"
        }
    }

    It 'the ranks are the canonical Error<Warning<Information<Verbose<Debug order' {
        $automationRank = Get-LogLevelRankTableFromSource -Path $module
        $expected = [ordered]@{ Error = 1; Warning = 2; Information = 3; Verbose = 4; Debug = 5 }
        foreach ($name in $expected.Keys) {
            Assert-True ($automationRank[$name] -eq $expected[$name]) `
                "'$name' rank is $($automationRank[$name]), expected $($expected[$name])"
        }
    }
}
