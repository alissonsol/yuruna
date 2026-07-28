<#PSScriptInfo
.VERSION 2026.07.28
.GUID 42c3d4e5-f6a7-4b89-8012-3d4e5f6a7b8c
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
    Create/update or delete a named test-set in the pool-intent test-set library (test-sets.yml).
.DESCRIPTION
    Pool admin CLI (backs the Pool control "Test sets" page). A test-set is a
    framework/project repo PAIR: {name, frameworkUrl, projectUrl}. This upserts
    (or, with -Delete, removes) an entry in test-sets.yml, schema-validates, then
    commits + pushes. GH_TOKEN is NEVER stored here -- it stays host-local.
    Assigning a library test-set to a pool is done with Set-PoolTestSet.ps1.
.PARAMETER Name
    Test-set name (the label; lowercase alphanumeric start).
.PARAMETER FrameworkUrl
    Framework repo URL (required unless -Delete).
.PARAMETER ProjectUrl
    Project repo URL (required unless -Delete).
.PARAMETER Delete
    Remove the named test-set from the library instead of upserting.
.EXAMPLE
    ./Set-PoolTestSetDefinition.ps1 -Name example -FrameworkUrl https://github.com/alissonsol/yuruna -ProjectUrl https://github.com/alissonsol/yuruna-project
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$FrameworkUrl,
    [string]$ProjectUrl,
    [switch]$Delete,
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
if (-not $Delete) {
    if ([string]::IsNullOrWhiteSpace($FrameworkUrl) -or [string]::IsNullOrWhiteSpace($ProjectUrl)) {
        Write-Error "Upsert requires -FrameworkUrl and -ProjectUrl (or pass -Delete to remove)."
        exit $ExitFailure
    }
}

$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.'
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)"; exit $ExitFailure }

# Read the test-set library (default-empty when absent).
$libPath = Join-Path $t.IntentDir 'test-sets.yml'
$doc = if (Test-Path -LiteralPath $libPath) {
    $d = Get-Content -Raw -LiteralPath $libPath | ConvertFrom-Yaml -Ordered
    if ($d -is [System.Collections.IDictionary]) { $d } else { [ordered]@{ schemaVersion = 1; testSets = @() } }
} else { [ordered]@{ schemaVersion = 1; testSets = @() } }
if (-not $doc.Contains('schemaVersion')) { $doc['schemaVersion'] = 1 }
if (-not $doc.Contains('testSets') -or $null -eq $doc['testSets']) { $doc['testSets'] = @() }

$sets = @(@($doc['testSets']) | Where-Object { $_ -is [System.Collections.IDictionary] })
if ($Delete) {
    $doc['testSets'] = @($sets | Where-Object { [string]$_['name'] -ne $Name })
    $action = 'delete'
} else {
    $sets = @($sets | Where-Object { [string]$_['name'] -ne $Name })
    $doc['testSets'] = @($sets + ([ordered]@{ name = $Name; frameworkUrl = $FrameworkUrl; projectUrl = $ProjectUrl }))
    $action = 'set'
}

$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'test-sets.yml' -Doc $doc -SchemaName 'pool-test-sets.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "test-sets.yml validation/write failed: $($save.Error)"; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "test-set: $action $Name" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)"; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)"
    exit $ExitFailure
}

Write-Information "Test-set '$Name' ${action} in the library." -InformationAction Continue
exit $ExitOk
