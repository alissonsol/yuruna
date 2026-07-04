<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42b5c6d7-e8f9-4a01-8b23-5c6d7e8f9012
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
    Pool admin CLI. This is the ONLY pool field the runner acts on today: every
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
    ./Set-PoolDesiredState.ps1 -PoolId lab -State paused
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][ValidateSet('run', 'paused', 'drain')][string]$State,
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

$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.'
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)"; exit $ExitFailure }

$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if (-not $pool) { Write-Error "Pool '$PoolId' not found. Create it first: ./New-Pool.ps1 -PoolId $PoolId"; exit $ExitFailure }
$pool['desiredState'] = $State

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $PoolId desiredState=$State" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) { Write-Warning $pub.Error }

Write-Information "Pool '$PoolId' desiredState set to '$State'. Members reconcile on their next cycle pull." -InformationAction Continue
exit $ExitOk
