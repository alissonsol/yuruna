<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42a4b5c6-d7e8-4f90-8a12-4b5c6d7e8f90
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
    Assign the pool's single test-set (a framework/project repo pair) in the intent store.
.DESCRIPTION
    Pool admin CLI. Sets the pool's one `testSet` (name + frameworkUrl +
    projectUrl), replacing any previous assignment. A pooled runner overrides its
    own repositories.frameworkUrl / repositories.projectUrl with these for the
    cycle and runs the assigned project's own test.runner.yml. GH_TOKEN is NOT
    part of the test-set -- it stays host-local (never in pool intent).
.PARAMETER PoolId
    Target pool id.
.PARAMETER Name
    Test-set name (operator label; also the dashboard/UI display name).
.PARAMETER FrameworkUrl
    Yuruna framework repo URL each pooled host clones for the cycle.
.PARAMETER ProjectUrl
    Project repo URL each pooled host tests.
.EXAMPLE
    ./Set-PoolTestSet.ps1 -PoolId lab -Name example -FrameworkUrl https://github.com/alissonsol/yuruna -ProjectUrl https://github.com/alissonsol/yuruna-project
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$PoolId,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$FrameworkUrl,
    [Parameter(Mandatory)][string]$ProjectUrl,
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

if ($Name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
    Write-Error "Test-set name '$Name' is invalid (lowercase alphanumeric start; letters, digits, '.', '_', '-')."
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

# The auto-enrolment target pool can NEVER carry a test-set. Hosts arrive there
# automatically, without anyone choosing it for them, so assigning a project
# here would silently repoint every auto-enrolled host in the lab on its next
# cycle -- the single largest blast radius in the whole pool layer.
#
# Bound to autoEnrollment.targetPoolId rather than the literal 'default', so
# renaming the target carries the protection with it. This lives in code
# because it is a cross-field constraint that JSON Schema cannot express;
# Test-PoolIntent.ps1 re-checks it as the authoritative validator.
$targetPoolId = if ($doc -is [System.Collections.IDictionary] -and $doc['autoEnrollment']) { [string]$doc['autoEnrollment']['targetPoolId'] } else { '' }
if ($targetPoolId -and $PoolId -eq $targetPoolId) {
    Write-Error @"
'$PoolId' is the auto-enrolment target pool and cannot carry a test-set.
  Hosts land there automatically and keep running their own projectUrl; assigning one
  here would silently repoint every auto-enrolled host in the lab.
  To give these hosts a project, create another pool and assign the hosts to it:
    ./New-Pool.ps1 -PoolId <name>
    ./Add-HostToPool.ps1 -PoolId <name> -HostId <hostId>
    ./Set-PoolTestSet.ps1 -PoolId <name> -Name $Name -FrameworkUrl $FrameworkUrl -ProjectUrl $ProjectUrl
"@
    exit $ExitFailure
}

# Exactly one test-set per pool: set (replace) it. Drop any legacy testSets[].
$action = if ($pool.Contains('testSet') -and $pool['testSet']) { 'update' } else { 'set' }
if ($pool.Contains('testSets')) { $pool.Remove('testSets') }
$pool['testSet'] = [ordered]@{ name = $Name; frameworkUrl = $FrameworkUrl; projectUrl = $ProjectUrl }

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "pools.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $action test-set $Name on $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)"
    exit $ExitFailure
}

Write-Information "Test-set '$Name' set on pool '$PoolId' (frameworkUrl=$FrameworkUrl, projectUrl=$ProjectUrl)." -InformationAction Continue
exit $ExitOk
