<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42c869eb-bcb1-4640-9d26-b9f3f7fbc926
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
    test/pool/Set-PoolTestSet.ps1 -PoolId lab -Name example -FrameworkUrl https://github.com/alissonsol/yuruna -ProjectUrl https://github.com/alissonsol/yuruna-project
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
if ($Name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_37e7a76a3661cead' -Arguments @{ name = "$Name" }) -ErrorAction Continue
    exit $ExitFailure
}

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

# The auto-enrollment target pool can NEVER carry a test-set. Hosts arrive there
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
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f1dc62bfb0f61720' -Arguments @{ poolId = "$PoolId"; name = "$Name"; frameworkUrl = "$FrameworkUrl"; projectUrl = "$ProjectUrl" }) -ErrorAction Continue
    exit $ExitFailure
}

# Exactly one test-set per pool: set (replace) it. Drop any legacy testSets[].
$action = if ($pool.Contains('testSet') -and $pool['testSet']) { 'update' } else { 'set' }
if ($pool.Contains('testSets')) { $pool.Remove('testSets') }
$pool['testSet'] = [ordered]@{ name = $Name; frameworkUrl = $FrameworkUrl; projectUrl = $ProjectUrl }

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_9c27a25b6843707d' -Arguments @{ error = "$($save.Error)" }) -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: $action test-set $Name on $PoolId" -Confirm:$false
if (-not $pub.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_493d8875345272bb' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_d7dcddaba0a5b0ef' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue
    exit $ExitFailure
}

Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c11b4fa818b922ab' -Arguments @{ name = "$Name"; poolId = "$PoolId"; frameworkUrl = "$FrameworkUrl"; projectUrl = "$ProjectUrl" }) -InformationAction Continue
exit $ExitOk
