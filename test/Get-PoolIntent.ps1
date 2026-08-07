<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42d4e5f6-a7b8-4c90-8123-4e5f6a7b8c9d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Emit the pool intent (pools + test-set library) as JSON. Read-only.
.DESCRIPTION
    Backs the pool-control service UI's data reads. Clones/pulls the intent store and
    writes a single JSON object to stdout: { ok, pools:[...], testSets:[...] }
    (the pools from pools.yml and the named-triple library from test-sets.yml).
    Never writes the store. On any error, emits { ok:false, error:"..." } and
    exits non-zero so the caller can surface it.
.EXAMPLE
    ./Get-PoolIntent.ps1 -IntentGitUrl /var/lib/yuruna/pool-intent.git
#>

[CmdletBinding()]
param(
    [string]$IntentGitUrl,
    [string]$IntentDir
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
Import-Module powershell-yaml -ErrorAction Stop

function Write-JsonResult { param($Obj) [Console]::Out.WriteLine(($Obj | ConvertTo-Json -Depth 12 -Compress)) }

try {
    $t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
    if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
        Write-JsonResult ([ordered]@{ ok = $false; error = 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.' })
        exit $ExitFailure
    }
    $open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
    if (-not $open.Ok) {
        Write-JsonResult ([ordered]@{ ok = $false; error = "Could not open the intent store: $($open.Error)" })
        exit $ExitFailure
    }
    $doc = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
    $libPath = Join-Path $t.IntentDir 'test-sets.yml'
    $testSets = @()
    if (Test-Path -LiteralPath $libPath) {
        $lib = Get-Content -Raw -LiteralPath $libPath | ConvertFrom-Yaml -Ordered
        if ($lib -is [System.Collections.IDictionary]) { $testSets = @($lib['testSets']) }
    }
    # autoEnrollment is projected alongside pools/testSets because this CLI is
    # the ONLY read path the pool-control service has into intent. Without it
    # the sweep cannot see `excluded[]` -- the list that stops it re-adding a
    # host an operator deliberately removed -- and the operator and a 60-second
    # timer would fight forever. Emitted as an empty object when absent so a
    # consumer never has to distinguish "missing" from "unset".
    $autoEnrollment = if ($doc -is [System.Collections.IDictionary] -and $doc['autoEnrollment']) { $doc['autoEnrollment'] } else { [ordered]@{} }
    Write-JsonResult ([ordered]@{ ok = $true; pools = @($doc['pools']); testSets = $testSets; autoEnrollment = $autoEnrollment })
    exit $ExitOk
} catch {
    Write-JsonResult ([ordered]@{ ok = $false; error = $_.Exception.Message })
    exit $ExitFailure
}
