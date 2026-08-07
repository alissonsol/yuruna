<#PSScriptInfo
.VERSION 2026.08.07
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
    (poolId + poolGuid + displayName + desiredState; members/testSet preserved on
    update), schema-validates pools.yml, then commits + pushes. Assign the pool's
    framework/project repo pair with Set-PoolTestSet. Runners PULL this intent
    read-only over HTTP and never write it. Run on the proxy (or with a writable
    -IntentGitUrl) so the push succeeds. See docs/pool-storage.md.
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

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# line above on purpose: an explicit level is the operator's choice and replaces
# this script's own default. $InformationPreference is then re-read from the
# global the cascade writes, because the script-scoped assignment above shadows
# it for the rest of this file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

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
# Creating a pool is the one command that may also create the store it writes
# into. Without this, a writable path that was never seeded -- a NAS pool tier
# mounted straight into networkStorage, a share rebuilt under a new root, any
# route to a fresh pool folder that did not run New-Lab -- fails here with a
# bare `git clone failed (exit 128)` naming nothing that is actually wrong.
# Read-only pool commands deliberately do NOT do this; see the function's notes.
$seed = Initialize-YurunaPoolIntentStorePath -IntentGitUrl $t.IntentGitUrl -Confirm:$false
if (-not $seed.Ok) {
    Write-Error "The pool-intent store ($($t.IntentGitUrl)) does not exist and could not be created: $($seed.Reason)"
    exit $ExitFailure
}
if ($seed.Created) { Write-Information "Seeded a new pool-intent store at $($t.IntentGitUrl)." -InformationAction Continue }

$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)"; exit $ExitFailure }

$doc  = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
$pool = Get-YurunaPoolFromDoc -Doc $doc -PoolId $PoolId
if ($pool -and $IfMissing) {
    Write-Information "Pool '$PoolId' already exists (desiredState=$($pool['desiredState'])); left unchanged (-IfMissing)." -InformationAction Continue
    exit $ExitOk
}
if ($pool) {
    # Only overwrite displayName when the caller actually passed -DisplayName; re-running
    # New-Pool just to change desiredState must not wipe an existing name (members/testSets
    # are already preserved on update).
    if ($PSBoundParameters.ContainsKey('DisplayName')) { $pool['displayName'] = $DisplayName }
    $pool['desiredState'] = $DesiredState
    $action = 'update'
} else {
    # Mint a stable 42-prefixed GUID (the dashboard "Pool ID") once, at creation.
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

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $action $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)"
    exit $ExitFailure
}

Write-Information "Pool '$PoolId' ${action}d (desiredState=$DesiredState)." -InformationAction Continue
exit $ExitOk
