<#PSScriptInfo
.VERSION 2026.09.24
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
$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_7dd0aa845d3a93ea') -ErrorAction Continue
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5080fa98b3c9b51c' -Arguments @{ intentGitUrl = "$($t.IntentGitUrl)"; error = "$($open.Error)" }) -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_945821c2fef42ae6' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue; exit $ExitFailure }

# One pool per host: reject if this hostId is already a member of a DIFFERENT pool.
foreach ($p in @($doc['pools'])) {
    if (($p -is [System.Collections.IDictionary]) -and ([string]$p['poolId'] -ne $PoolId) -and (@($p['members']) -contains $HostId)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_2cbc230f4adcaeac' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$($p['poolId'])" }) -ErrorAction Continue
        exit $ExitFailure
    }
}

$members = @($pool['members'])
if ($members -contains $HostId) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_824e13f7776d01ec' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
    exit $ExitOk
}
$pool['members'] = @($members + $HostId)

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_9c27a25b6843707d' -Arguments @{ error = "$($save.Error)" }) -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: add $HostId to $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_493d8875345272bb' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_d7dcddaba0a5b0ef' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue
    exit $ExitFailure
}

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bba4a8e964d8063d' -Arguments @{ shownHostId = "$shownHostId"; poolId = "$PoolId" }) -InformationAction Continue
exit $ExitOk
