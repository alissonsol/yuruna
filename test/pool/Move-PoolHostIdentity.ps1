<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42b7c714-750f-4b13-9c64-3f688f1db47d
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
    Move a re-keyed host's pool membership in one intent-store commit.
.DESCRIPTION
    Replaces the old host ID with the new one in pools.yml. If the new ID is
    already assigned to a pool, that assignment wins and the old ID is only
    removed. The auto-enrollment exclusion, if present, follows the new ID.
    An absent old ID is a successful retry. The whole change is saved and
    pushed once, so a failed write cannot leave a half-moved membership.
.PARAMETER OldHostId
    The retired 42-prefixed host ID.
.PARAMETER NewHostId
    The live 42-prefixed host ID.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$OldHostId,
    [Parameter(Mandatory)][string]$NewHostId,
    [string]$IntentGitUrl,
    [string]$IntentDir
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ModulesDir = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
Import-Module powershell-yaml -ErrorAction Stop

# --- REGION: Validate the arguments
$old = ConvertTo-YurunaHostId -Value $OldHostId
$new = ConvertTo-YurunaHostId -Value $NewHostId
if (-not $old -or -not $new -or $old -eq $new) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_793bb6d734b490d5' -Arguments @{ hostId = "$OldHostId -> $NewHostId" }) -ErrorAction Continue
    exit $ExitFailure
}

# --- REGION: Open the intent store
$open = Open-YurunaPoolAdminStore -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
$doc = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$oldPool = $null
$newPool = $null
foreach ($p in @($doc['pools'])) {
    if ($p -isnot [System.Collections.IDictionary]) { continue }
    if (@($p['members']) -contains $old) { $oldPool = $p }
    if (@($p['members']) -contains $new) { $newPool = $p }
}
$changed = $false
if ($oldPool) {
    $members = @($oldPool['members'] | Where-Object { $_ -ne $old })
    if (-not $newPool) { $members = @($members + $new) }
    $oldPool['members'] = $members
    $changed = $true
}
$auto = $doc['autoEnrollment']
if (($auto -is [System.Collections.IDictionary]) -and (@($auto['excluded']) -contains $old)) {
    $excluded = @($auto['excluded'] | Where-Object { $_ -ne $old })
    if ($excluded -notcontains $new) { $excluded = @($excluded + $new) }
    $auto['excluded'] = $excluded
    $changed = $true
}
if (-not $changed) { exit $ExitOk }

# --- REGION: Save, commit and push
$pub = Publish-YurunaPoolDocChange -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message "pool: hand over $old to $new" -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }
exit $ExitOk
