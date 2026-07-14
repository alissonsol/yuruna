<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42dd3adb-5661-4d45-87ae-9a393fc5404f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation bugfix pester
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
    Structural Pester guard on two entrypoint bug fixes: Invoke-Clear.ps1 must
    exit 1 on a Clear-Configuration failure, and Test-Configuration.ps1 must
    resolve its roots via the robust Resolve-YurunaRootSet instead of the older
    -Path / IsNullOrEmpty prelude.
.DESCRIPTION
    Bug 1: Invoke-Clear.ps1's failure branch printed the transcript but did not
    `exit 1`, so a bash `set -e` wrapper missed a Clear-Configuration failure. The
    branch must now exit 1 (matching `yuruna.ps1 clear` and the Set-* wrappers).
    Bug 2: Test-Configuration.ps1 open-coded a less-robust root prelude
    (Resolve-Path -Path -> wildcard expansion; IsNullOrEmpty -> no ambiguity check),
    accepting a wildcard/multi-match project path. It must now delegate to
    Resolve-YurunaRootSet (-LiteralPath + Count ambiguity guard). Source-text only.
    Runs under Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'entrypoint-bugfixes' {
    It 'Bug 1: the bool-tail entrypoints exit 1 on failure (Invoke-Clear, Test-Configuration, Test-Requirement)' {
        foreach ($e in 'Invoke-Clear','Test-Configuration','Test-Requirement') {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            Assert-True ($src -match '(?s)if \(-Not \$result\) \{[^}]*\bexit 1\b') `
                "$e failure branch must exit 1 so bash set -e sees the failure"
        }
    }
    It 'Bug 2: Test-Configuration.ps1 resolves roots via Resolve-YurunaRootSet' {
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Test-Configuration.ps1') -Raw
        Assert-True ($src -match 'Resolve-YurunaRootSet -ScriptRoot \$PSScriptRoot') `
            'Test-Configuration must delegate root resolution to the shared resolver'
    }
    It 'Bug 2: Test-Configuration.ps1 no longer uses the wildcard-expanding -Path guard' {
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Test-Configuration.ps1') -Raw
        Assert-True (-not ($src -match 'Resolve-Path -Path \$project_root')) `
            'the -Path (wildcard-expanding) project-root resolve must be gone'
        Assert-True (-not ($src -match 'IsNullOrEmpty\(\$resolved_root\)')) `
            'the IsNullOrEmpty guard (no ambiguity detection) must be gone'
    }
    It 'every entrypoint scopes the module eviction to Yuruna.* (no all-module Get-Module | Remove-Module)' {
        foreach ($e in 'yuruna','Set-Component','Set-Resource','Set-Workload','Invoke-Clear','Test-Configuration','Test-Requirement') {
            $src = Get-Content -LiteralPath (Join-Path $autoDir "$e.ps1") -Raw
            if ($src -match 'Get-Module.*\| Remove-Module') {
                Assert-True (-not ($src -match 'Get-Module \| Remove-Module')) "$e must not evict ALL modules"
                Assert-True ($src -match 'Get-Module Yuruna\.\* \| Remove-Module') "$e must scope the eviction to Yuruna.*"
            }
        }
    }
}
