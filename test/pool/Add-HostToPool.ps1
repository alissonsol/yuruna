<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42236cc8-c3f9-4b02-a1e7-01d2a329be23
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
    Add a host (by stable hostId) to a pool's members[] in the intent store.
.DESCRIPTION
    Pool admin CLI. members[] is the single source of truth for membership: a
    runner finds its own pool by locating its hostId here, and the aggregator
    labels its telemetry accordingly. Idempotent. The HostId is the host's
    runtime/host.uuid (42-prefixed 32-hex). The pool must already exist (New-Pool).
.PARAMETER PoolId
    Target pool id.
.PARAMETER HostId
    Stable hostId to add (runtime/host.uuid, 42-prefixed 32-hex). The GUID-dashed
    spelling every panel and UI reveals a full id in is accepted too, so a value
    copied off one works as pasted.
.PARAMETER MoveExisting
    Remove this host from another pool before adding it to PoolId. Without this
    switch, existing membership in another pool is refused.
.EXAMPLE
    ./Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567
.EXAMPLE
    ./Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef-0123-4567-89ab-cdef01234567
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][string]$HostId,
    [string]$IntentGitUrl,
    [string]$IntentDir,
    [switch]$MoveExisting
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
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_945821c2fef42ae6' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue; exit $ExitFailure }

# One pool per host: reject membership in another pool unless -MoveExisting
# explicitly removes that membership first.
foreach ($p in @($doc['pools'])) {
    if (($p -is [System.Collections.IDictionary]) -and ([string]$p['poolId'] -ne $PoolId) -and (@($p['members']) -contains $HostId)) {
        if ($MoveExisting) {
            $p['members'] = @($p['members'] | Where-Object { $_ -and [string]$_ -ne $HostId })
            continue
        }
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_2cbc230f4adcaeac' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$($p['poolId'])" }) -ErrorAction Continue
        exit $ExitFailure
    }
}

$members = @($pool['members'] | Where-Object { $_ })
if ($members -contains $HostId) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_824e13f7776d01ec' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
    exit $ExitOk
}
$pool['members'] = @($members + $HostId)

# --- REGION: Save, commit and push
$pub = Publish-YurunaPoolDocChange -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message "pool: add $HostId to $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bba4a8e964d8063d' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
exit $ExitOk
