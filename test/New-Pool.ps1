<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42c0b1a2-d3e4-4f56-9a87-6b5c4d3e2f10
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
    (poolId + displayName + desiredState; members/testSets preserved or empty),
    schema-validates pools.yml, then commits + pushes. Runners PULL this intent
    read-only over HTTP and never write it. Run on the proxy (or with a writable
    -IntentGitUrl) so the push succeeds. See docs/pool-storage.md.
.PARAMETER PoolId
    DNS-label-safe pool id (the immutable Loki/Prometheus label).
.PARAMETER IntentGitUrl
    Writable URL/path of the bare intent repo. Defaults to pool.intentGitUrl from
    test.config.yml.
.PARAMETER IntentDir
    Local working clone. Defaults to <runtime>/pool-intent-admin.
.EXAMPLE
    ./New-Pool.ps1 -PoolId lab -DisplayName 'Lab pool' -IntentGitUrl /var/lib/yuruna/pool-intent.git
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [string]$DisplayName = '',
    [ValidateSet('run', 'paused', 'drain')][string]$DesiredState = 'run',
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

if ($PoolId -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
    Write-Error "PoolId '$PoolId' is invalid (DNS-label-safe: lowercase letters, digits, hyphen; must start alphanumeric)."
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
if ($pool) {
    # Only overwrite displayName when the caller actually passed -DisplayName; re-running
    # New-Pool just to change desiredState must not wipe an existing name (members/testSets
    # are already preserved on update).
    if ($PSBoundParameters.ContainsKey('DisplayName')) { $pool['displayName'] = $DisplayName }
    $pool['desiredState'] = $DesiredState
    $action = 'update'
} else {
    $doc['pools'] = @(@($doc['pools']) + ([ordered]@{
        poolId       = $PoolId
        displayName  = $DisplayName
        members      = @()
        testSets     = @()
        desiredState = $DesiredState
    }))
    $action = 'create'
}

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $action $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) { Write-Warning $pub.Error }

Write-Information "Pool '$PoolId' ${action}d (desiredState=$DesiredState)." -InformationAction Continue
exit $ExitOk
