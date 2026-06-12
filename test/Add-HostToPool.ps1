<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42e2f3a4-b5c6-4d78-9e01-2f3a4b5c6d7e
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
    Stable hostId to add (runtime/host.uuid, 42-prefixed 32-hex).
.EXAMPLE
    ./Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567
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
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ModulesDir  = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
Import-Module powershell-yaml -ErrorAction Stop

if ($HostId -notmatch '^42[0-9a-fA-F]{30}$') {
    Write-Error "HostId '$HostId' is invalid (expected the host's runtime/host.uuid: '42' + 30 hex)."
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
if (-not $pool) { Write-Error "Pool '$PoolId' not found. Create it first: ./New-Pool.ps1 -PoolId $PoolId"; exit $ExitFailure }

$members = @($pool['members'])
if ($members -contains $HostId) {
    Write-Information "Host $HostId is already a member of '$PoolId' (no change)." -InformationAction Continue
    exit $ExitOk
}
$pool['members'] = @($members + $HostId)

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: add $HostId to $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) { Write-Warning $pub.Error }

Write-Information "Added $HostId to pool '$PoolId'." -InformationAction Continue
exit $ExitOk
