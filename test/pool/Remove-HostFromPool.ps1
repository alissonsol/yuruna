<#PSScriptInfo
.VERSION 2026.09.30
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
.PARAMETER Exclude
    Remove the host from every pool and persist an auto-enrollment exclusion.
    PoolId may be omitted; the exclusion also applies to an already-unpooled host.
.PARAMETER HostId
    Stable hostId to remove (runtime/host.uuid, 42-prefixed 32-hex). The GUID-dashed
    spelling every panel and UI reveals a full id in is accepted too, so a value
    copied off one works as pasted.
.EXAMPLE
    ./Remove-HostFromPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567
.EXAMPLE
    ./Remove-HostFromPool.ps1 -PoolId lab -HostId 42abcdef-0123-4567-89ab-cdef01234567
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Pool')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Pool')]
    [Parameter(ParameterSetName = 'Exclude')][string]$PoolId,
    [Parameter(Mandatory, ParameterSetName = 'Exclude')][switch]$Exclude,
    [Parameter(Mandatory)][string]$HostId,
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

# --- REGION: Validate the arguments
$canonicalHostId = ConvertTo-YurunaHostId -Value $HostId
if (-not $canonicalHostId) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_793bb6d734b490d5' -Arguments @{ hostId = "$HostId" }) -ErrorAction Continue
    exit $ExitFailure
}
$HostId = $canonicalHostId
# The spelling every line below shows the operator, which is the one the
# dashboard and the pool-control UI reveal a full id in; $HostId itself stays
# the canonical key the store is read and written with.
$shownHostId = Format-YurunaHostId -HostId $HostId

# --- REGION: Open the intent store
$open = Open-YurunaPoolAdminStore -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$changed = $false
if ($Exclude) {
    $selectedPools = @($doc['pools'])
} else {
    $pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
    if (-not $pool) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_610916ed46dbb06b' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue; exit $ExitFailure }
    $selectedPools = @($pool)
}
foreach ($pool in $selectedPools) {
    $members = @($pool['members'])
    if ($members -contains $HostId) {
        $pool['members'] = @($members | Where-Object { $_ -ne $HostId })
        $changed = $true
    }
}
if ($Exclude) {
    if ($doc['autoEnrollment'] -isnot [System.Collections.IDictionary]) { $doc['autoEnrollment'] = [ordered]@{} }
    $excluded = @($doc['autoEnrollment']['excluded'] | Where-Object { $_ })
    if ($excluded -notcontains $HostId) {
        $doc['autoEnrollment']['excluded'] = @($excluded) + @($HostId)
        $changed = $true
    }
}
if (-not $changed) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5938fa2155471b2b' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
    exit $ExitOk
}

# --- REGION: Save, commit and push
$message = if ($Exclude) { "pool: exclude $HostId from auto-enrollment" } else { "pool: remove $HostId from $PoolId" }
$pub = Publish-YurunaPoolDocChange -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message $message -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_49dca05bbccf311f' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
exit $ExitOk
