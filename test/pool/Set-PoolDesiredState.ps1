<#PSScriptInfo
.VERSION 2026.09.18
.GUID 429e89fa-f380-4a1b-8768-7b52c7f86767
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
    Set a pool's desiredState (run | paused | drain) -- the operator control plane.
.DESCRIPTION
    Pool admin CLI. Sets the field that gates the runner: every
    member pulls the intent each cycle and reconciles. run = cycle normally;
    paused = finish the in-flight cycle then hold (re-checking each ~30s) until
    run returns; drain = stop after the current cycle (the runner process exits;
    re-add + restart to rejoin). In-flight cycles always complete -- pause/drain
    never corrupt an accumulating cycle.
.PARAMETER PoolId
    Target pool id.
.PARAMETER State
    run | paused | drain.
.EXAMPLE
    test/pool/Set-PoolDesiredState.ps1 -PoolId lab -State paused
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][ValidateSet('run', 'paused', 'drain')][string]$State,
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

# --- REGION: Apply the change
$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_945821c2fef42ae6' -Arguments @{ poolId = "$PoolId" }) -ErrorAction Continue; exit $ExitFailure }
$pool['desiredState'] = $State

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_9c27a25b6843707d' -Arguments @{ error = "$($save.Error)" }) -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $PoolId desiredState=$State" -Confirm:$false
if (-not $pub.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_493d8875345272bb' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_d7dcddaba0a5b0ef' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue
    exit $ExitFailure
}

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_59650e3f07b2342b' -Arguments @{ poolId = "$PoolId"; state = "$State" }) -InformationAction Continue
exit $ExitOk
