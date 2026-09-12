<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42e5b8b9-d9cd-4ae5-92e1-a3fd96227e6c
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
    Remove a host (by stable hostId) from a pool's members[].
.DESCRIPTION
    Pool admin CLI. Removing a host from members[] stops the aggregator labeling
    its telemetry under this pool. To GRACEFULLY retire a running host, set its
    desiredState to drain first (Set-PoolDesiredState) so it finishes its cycle
    and stops, THEN remove it here. Idempotent.

    Distinct from Remove-PoolHost, which purges a stale host outright: it deletes
    the host's NAS identity record and archived cycle folders, strips it from EVERY
    pool, and evicts it from the aggregator's live view.
.PARAMETER PoolId
    Target pool id.
.PARAMETER HostId
    Stable hostId to remove (runtime/host.uuid, 42-prefixed 32-hex). The GUID-dashed
    spelling every panel and UI reveals a full id in is accepted too, so a value
    copied off one works as pasted.
.EXAMPLE
    ./Remove-HostFromPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567
.EXAMPLE
    ./Remove-HostFromPool.ps1 -PoolId lab -HostId 42abcdef-0123-4567-89ab-cdef01234567
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][string]$HostId,
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

# --- REGION: Validate the arguments
$canonicalHostId = ConvertTo-YurunaHostId -Value $HostId
if (-not $canonicalHostId) {
    Write-Error "HostId '$HostId' is invalid (expected the host's runtime/host.uuid: '42' + 30 hex, with or without the dashboard's GUID dashes)." -ErrorAction Continue
    exit $ExitFailure
}
$HostId = $canonicalHostId
# The spelling every line below shows the operator, which is the one the
# dashboard and the pool-control UI reveal a full id in; $HostId itself stays
# the canonical key the store is read and written with.
$shownHostId = Format-YurunaHostId -HostId $HostId

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
if (-not $pool) { Write-Error "Pool '$PoolId' not found." -ErrorAction Continue; exit $ExitFailure }

$members = @($pool['members'])
if ($members -notcontains $HostId) {
    Write-Information "Host $shownHostId is not a member of '$PoolId' (no change)." -InformationAction Continue
    exit $ExitOk
}
$pool['members'] = @($members | Where-Object { $_ -ne $HostId })

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)" -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: remove $HostId from $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)" -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)" -ErrorAction Continue
    exit $ExitFailure
}

Write-Information "Removed $shownHostId from pool '$PoolId'." -InformationAction Continue
exit $ExitOk
