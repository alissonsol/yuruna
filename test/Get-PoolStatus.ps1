<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42c6d7e8-f9a0-4b12-8c34-6d7e8f9a0123
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
    Read-only: show pools, members, desiredState, and assigned test-sets from the
    intent store.
.DESCRIPTION
    Pool admin CLI (read-only -- never writes/commits). Clones/pulls the intent
    store and prints each pool's membership + desiredState + testSets. Live host
    health is on the Grafana pool dashboard (the aggregator); this reports the
    authored INTENT.
.PARAMETER PoolId
    Optional: restrict output to one pool.
.EXAMPLE
    ./Get-PoolStatus.ps1
    ./Get-PoolStatus.ps1 -PoolId lab
#>

[CmdletBinding()]
param(
    [string]$PoolId,
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

$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.'
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)"; exit $ExitFailure }

$doc   = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pools = @($doc['pools'] | Where-Object { $_ -is [System.Collections.IDictionary] })
if ($PoolId) { $pools = @($pools | Where-Object { [string]$_['poolId'] -eq $PoolId }) }
if ($pools.Count -eq 0) {
    Write-Information "No pools defined$(if ($PoolId) { " matching '$PoolId'" })." -InformationAction Continue
    exit $ExitOk
}

foreach ($p in $pools) {
    $members = @($p['members'])
    $sets    = @($p['testSets'] | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object { [string]$_['name'] })
    Write-Information "" -InformationAction Continue
    Write-Information ("Pool {0} ({1})  desiredState={2}" -f $p['poolId'], $(if ($p['displayName']) { $p['displayName'] } else { '-' }), $(if ($p['desiredState']) { $p['desiredState'] } else { 'run' })) -InformationAction Continue
    Write-Information ("  members ({0}): {1}" -f $members.Count, $(if ($members.Count) { $members -join ', ' } else { '(none)' })) -InformationAction Continue
    Write-Information ("  testSets: {0}" -f $(if ($sets.Count) { $sets -join ', ' } else { '(none)' })) -InformationAction Continue
}
exit $ExitOk
