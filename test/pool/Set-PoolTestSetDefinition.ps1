<#PSScriptInfo
.VERSION 2026.09.12
.GUID 423f5481-df7c-4b50-bc42-b39e3fe0b5d1
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
    Pool admin CLI (backs the pool-control service "Test sets" page). A test-set is a
    framework/project repo PAIR: {name, frameworkUrl, projectUrl}. This upserts
    (or, with -Delete, removes) an entry in test-sets.yml, schema-validates, then
    commits + pushes. GH_TOKEN is NEVER stored here -- it stays host-local.
    Assigning a library test-set to a pool is done with test/pool/Set-PoolTestSet.ps1.
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
    Write-Error "Test-set name '$Name' is invalid (lowercase alphanumeric start; letters, digits, '.', '_', '-')." -ErrorAction Continue
    exit $ExitFailure
}
if (-not $Delete) {
    if ([string]::IsNullOrWhiteSpace($FrameworkUrl) -or [string]::IsNullOrWhiteSpace($ProjectUrl)) {
        Write-Error "Upsert requires -FrameworkUrl and -ProjectUrl (or pass -Delete to remove)." -ErrorAction Continue
        exit $ExitFailure
    }
}

# --- REGION: Open the intent store
$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error 'No intent store URL. Pass -IntentGitUrl or set pool.intentGitUrl in test.config.yml.' -ErrorAction Continue
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error "Could not open the intent store ($($t.IntentGitUrl)): $($open.Error)" -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Apply the change
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

# --- REGION: Save, commit and push
$save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'test-sets.yml' -Doc $doc -SchemaName 'pool-test-sets.schema.yml' -Confirm:$false
if (-not $save.Ok) { Write-Error "test-sets.yml validation/write failed: $($save.Error)" -ErrorAction Continue; exit $ExitFailure }
$pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "test-set: $action $Name" -Confirm:$false
if (-not $pub.Ok) { Write-Error "Commit failed: $($pub.Error)" -ErrorAction Continue; exit $ExitFailure }
if (-not $pub.Pushed) {
    Write-Error "Committed locally but NOT pushed to the remote -- the change is not durable and a later admin command will discard it: $($pub.Error)" -ErrorAction Continue
    exit $ExitFailure
}

Write-Information "Test-set '$Name' ${action} in the library." -InformationAction Continue
exit $ExitOk
