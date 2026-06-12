<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a4b5c6-d7e8-4f90-8a12-4b5c6d7e8f90
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
    Assign (upsert) a test-set to a pool in the intent store.
.DESCRIPTION
    Pool admin CLI. Adds or updates an entry in the pool's testSets[] (name +
    order + cycleStrategy). This records the assignment in pools.yml; each pooled
    runner executes it on its next cycle. -Name should match a test-sets/<name>.yml
    manifest (existence is checked by Test-PoolIntent.ps1, not here).
.PARAMETER PoolId
    Target pool id.
.PARAMETER Name
    Test-set name (manifest filename stem).
.PARAMETER Order
    Execution order within the pool. Default 0.
.PARAMETER CycleStrategy
    all | round-robin | single. Default all.
.EXAMPLE
    ./Set-PoolTestSet.ps1 -PoolId lab -Name smoke -Order 0 -CycleStrategy all
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][string]$Name,
    [int]$Order = 0,
    [ValidateSet('all', 'round-robin', 'single')][string]$CycleStrategy = 'all',
    [string]$IntentGitUrl,
    [string]$IntentDir
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
Import-Module powershell-yaml -ErrorAction Stop

if ($Name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
    Write-Error "Test-set name '$Name' is invalid (lowercase alphanumeric start; letters, digits, '.', '_', '-')."
    exit $ExitFailure
}

$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.'
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)"; exit $ExitFailure }

$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error "Pool '$PoolId' not found. Create it first: ./New-Pool.ps1 -PoolId $PoolId"; exit $ExitFailure }

$sets = @($pool['testSets'] | Where-Object { $_ -is [System.Collections.IDictionary] })
$existing = $sets | Where-Object { [string]$_['name'] -eq $Name } | Select-Object -First 1
if ($existing) {
    $existing['order']         = $Order
    $existing['cycleStrategy'] = $CycleStrategy
    $action = 'update'
} else {
    $sets = @($sets + ([ordered]@{ name = $Name; order = $Order; cycleStrategy = $CycleStrategy }))
    $pool['testSets'] = $sets
    $action = 'add'
}

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $action test-set $Name on $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) { Write-Warning $pub.Error }

Write-Information "Test-set '$Name' ${action}ed on pool '$PoolId' (order=$Order, cycleStrategy=$CycleStrategy)." -InformationAction Continue
exit $ExitOk
