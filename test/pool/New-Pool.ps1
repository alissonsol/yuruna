<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42509e7a-733b-48f3-a663-0952f4326255
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
    Create or update a pool in the LAN pool-intent store (pools.yml).
.DESCRIPTION
    Pool admin CLI. Clones/pulls the WRITABLE intent repo, upserts a pool entry
    (poolId + poolGuid + displayName + desiredState; members and repositories are
    preserved on update), schema-validates pools.yml, then commits + pushes. Set
    the pool's framework and project repositories with Set-PoolRepository.ps1.
    Runners PULL this intent read-only over HTTP and never write it. Run on the
    proxy (or with a writable -IntentGitUrl) so the push succeeds. See
    docs/pool-storage.md.
.PARAMETER PoolId
    DNS-label-safe pool id (the immutable Loki/Prometheus label).
.PARAMETER IntentGitUrl
    Writable URL/path of the bare intent repo. Defaults to pool.intentGitUrl from
    test.config.yml.
.PARAMETER IntentDir
    Local working clone. Defaults to <runtime>/pool-intent-admin.
.PARAMETER IfMissing
    Create the pool only when it does not exist yet; leave an existing one
    exactly as it is and exit 0. For callers that ENSURE a pool rather than
    author one -- setup.ps1 runs on every re-run, and without this the plain
    upsert would reset a pool an operator had deliberately set to 'paused' or
    'drain' back to the -DesiredState default on each pass.
.EXAMPLE
    ./New-Pool.ps1 -PoolId lab -DisplayName 'Lab pool' -IntentGitUrl /var/lib/yuruna/pool-intent.git
.EXAMPLE
    ./New-Pool.ps1 -PoolId default -IfMissing
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [string]$DisplayName = '',
    [ValidateSet('run', 'paused', 'drain')][string]$DesiredState = 'run',
    [string]$IntentGitUrl,
    [string]$IntentDir,
    [switch]$IfMissing
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default. $InformationPreference
# is re-read afterwards because the script-scoped assignment above shadows the
# global the cascade writes.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

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

# --- REGION: Validate the arguments
if ($PoolId -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_627006c4c8c7c0a8' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue
    exit $ExitFailure
}

# --- REGION: Open the intent store
$open = Open-YurunaPoolAdminStore -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if ($pool -and $IfMissing) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a7d432e9c0cf6e77' -Arguments @{ poolId = "$PoolId"; desiredState = "$($pool['desiredState'])" }) -InformationAction Continue
    exit $ExitOk
}
if ($pool) {
    # Only overwrite displayName when the caller actually passed -DisplayName; re-running
    # New-Pool just to change desiredState must not wipe an existing name (members and
    # repositories are already preserved on update).
    if ($PSBoundParameters.ContainsKey('DisplayName')) { $pool['displayName'] = $DisplayName }
    $pool['desiredState'] = $DesiredState
    $action = 'update'
} else {
    # Mint a stable 42-prefixed pool GUID once, at creation.
    $poolGuid = '42' + ([guid]::NewGuid().ToString()).Substring(2)
    $doc['pools'] = @(@($doc['pools']) + ([ordered]@{
        poolId       = $PoolId
        poolGuid     = $poolGuid
        displayName  = $DisplayName
        members      = @()
        desiredState = $DesiredState
    }))
    $action = 'create'
}

# --- REGION: Save, commit and push
$pub = Publish-YurunaPoolDocChange -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message "pool: $action $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }

Write-Information "Pool '$PoolId' ${action}d (desiredState=$DesiredState)." -InformationAction Continue
exit $ExitOk
