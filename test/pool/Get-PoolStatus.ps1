<#PSScriptInfo
.VERSION 2026.09.18
.GUID 422c4baa-b4df-4b35-a65a-b6bdf04ee952
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
# The failure paths below pass -ErrorAction Continue: under the strict
# preference above, a bare Write-Error would itself terminate and skip
# the clean exit-code path.
Import-Module powershell-yaml -ErrorAction Stop

# --- REGION: Open the intent store
$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_7dd0aa845d3a93ea') -ErrorAction Continue
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5080fa98b3c9b51c' -Arguments @{ intentGitUrl = "$($t.IntentGitUrl)"; error = "$($open.Error)" }) -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Report
$doc   = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pools = @($doc['pools'] | Where-Object { $_ -is [System.Collections.IDictionary] })
if ($PoolId) { $pools = @($pools | Where-Object { [string]$_['poolId'] -eq $PoolId }) }
if ($pools.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_11ce0062a4d872e8' -Arguments @{ poolId = "$(if ($PoolId) { " matching '$PoolId'" })" }) -InformationAction Continue
    exit $ExitOk
}

foreach ($p in $pools) {
    $members = @($p['members'])
    $ts      = if ($p['testSet'] -is [System.Collections.IDictionary]) { $p['testSet'] } else { $null }
    Write-Information "" -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_fe92e0ad4340efe9' -FormatValues ($p['poolId'], $(if ($p['poolGuid']) { $p['poolGuid'] } else { '-' }), $(if ($p['displayName']) { $p['displayName'] } else { '-' }), $(if ($p['desiredState']) { $p['desiredState'] } else { 'run' })) -FormatBindings @{ poolId = '0'; else = '1'; else2 = '2'; run = '3' }) -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5353aae93ac87aae' -FormatValues ($members.Count, $(if ($members.Count) { $members -join ', ' } else { '(none)' })) -FormatBindings @{ count = '0'; none = '1' }) -InformationAction Continue
    if ($ts) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_41a636e6dabd5864' -FormatValues ([string]$ts['name'], [string]$ts['frameworkUrl'], [string]$ts['projectUrl']) -FormatBindings @{ name = '0'; frameworkUrl = '1'; projectUrl = '2' }) -InformationAction Continue
    } else {
        Write-Information "  testSet: (none)" -InformationAction Continue
    }
}
exit $ExitOk
