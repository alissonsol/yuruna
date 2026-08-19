<#PSScriptInfo
.VERSION 2026.08.19
.GUID 422d18ba-e16c-4e00-929c-adfa86bc8abe
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
    Delete a pool from the LAN pool-intent store (pools.yml).
.DESCRIPTION
    Pool admin CLI. Removes the pool with -PoolId. Refuses to delete a pool that
    still has members unless -Force is given, so a host is never silently
    orphaned from a pool it thinks it is in. Schema-validates, then commits +
    pushes. Runners PULL this intent read-only. See docs/pool-admin.md.
.PARAMETER PoolId
    Pool id to delete.
.PARAMETER Force
    Delete even when the pool still has members[].
.EXAMPLE
    ./Remove-Pool.ps1 -PoolId lab
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [switch]$Force,
    [string]$IntentGitUrl,
    [string]$IntentDir
)

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
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.' -ErrorAction Continue
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)" -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) {
    Write-Information "Pool '$PoolId' not found (already absent)." -InformationAction Continue
    exit $ExitOk
}
$members = @($pool['members'])
if ($members.Count -gt 0 -and -not $Force) {
    Write-Error "Pool '$PoolId' still has $($members.Count) member(s). Remove them first (./Remove-HostFromPool.ps1) or pass -Force." -ErrorAction Continue
    exit $ExitFailure
}

$doc['pools'] = @(@($doc['pools']) | Where-Object { -not (($_ -is [System.Collections.IDictionary]) -and ([string]$_['poolId'] -eq $PoolId)) })

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)" -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: delete $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)" -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)" -ErrorAction Continue
    exit $ExitFailure
}

Write-Information "Pool '$PoolId' deleted." -InformationAction Continue
exit $ExitOk
