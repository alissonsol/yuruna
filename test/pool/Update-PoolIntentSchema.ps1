<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42ea6545-e599-4ca8-a31d-79584a62e9e0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin migration
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
    Migrate the pool intent store to pools.yml schemaVersion 3, once.
.DESCRIPTION
    Pool admin CLI. Clones/pulls the WRITABLE intent repo and reads pools.yml as
    stored. Below schemaVersion 3 it upgrades the document with
    ConvertTo-PoolIntentSchemaV3: each pool's testSet framework and project URLs
    become its `repositories`, and the testSet name and sequences are dropped. It
    also deletes a leftover test-sets.yml, which nothing reads. It then validates
    pools.yml against test/schemas/pools.schema.yml, commits and pushes. The
    commit subject names what changed: "Migrate pool intent to schemaVersion 3"
    when the stored version moves, or "pool: remove test-sets.yml" when the store
    is already at schemaVersion 3 and only that leftover file goes.

    Idempotent: a store already at schemaVersion 3 with no test-sets.yml is
    reported as already current and left untouched. A store at a NEWER version
    is refused -- update this checkout first. The migration keeps every value
    it finds, including repositories on the auto-enrollment target pool; run
    Test-PoolIntent.ps1 afterwards, which reports that as a violation to clear
    with Set-PoolRepository.ps1 -Clear.

    Every other admin CLI performs the same upgrade in memory and persists it on
    its next write; this script makes the migration an explicit, reviewable
    commit of its own. Run it after every checkout that writes the store (the
    pool-control-service VM included) runs the schemaVersion 3 code: a checkout
    that still validates against schemaVersion 2 refuses to write a v3 store.
.PARAMETER IntentGitUrl
    Writable URL/path of the bare intent repo. Defaults to pool.intentGitUrl from
    test.config.yml.
.PARAMETER IntentDir
    Local working clone. Defaults to <runtime>/pool-intent-admin.
.EXAMPLE
    test/pool/Update-PoolIntentSchema.ps1 -IntentGitUrl /var/lib/yuruna/pool-intent.git
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$IntentGitUrl,
    [string]$IntentDir
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default. $InformationPreference
# is re-read afterwards because the script-scoped assignment above shadows the
# global the cascade writes.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

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

$currentVersion = 3

# --- REGION: Open the intent store
$open = Open-YurunaPoolAdminStore -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Read the stored version
# Raw, never through Read-YurunaPoolsDoc: that path upgrades in memory, so every
# store would read as already current.
$poolsPath   = Join-Path $t.IntentDir 'pools.yml'
$libraryPath = Join-Path $t.IntentDir 'test-sets.yml'
if (-not (Test-Path -LiteralPath $poolsPath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c1ccd779c5d89baf' -Arguments @{ label = 'pools.yml'; path = "$poolsPath" }) -ErrorAction Continue
    exit $ExitFailure
}
try {
    $stored = Get-Content -Raw -LiteralPath $poolsPath | ConvertFrom-Yaml -Ordered
} catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_e0674b7efa2de0b5' -Arguments @{ label = 'pools.yml'; message = "$($_.Exception.Message)" }) -ErrorAction Continue
    exit $ExitFailure
}
if ($stored -isnot [System.Collections.IDictionary]) { $stored = [ordered]@{} }
if (-not $stored.Contains('pools') -or $null -eq $stored['pools']) { $stored['pools'] = @() }
# An absent schemaVersion reads as 2, the rule ConvertTo-PoolIntentSchemaV3 applies.
$storedVersion = if ($stored.Contains('schemaVersion')) { $stored['schemaVersion'] } else { 2 }
$storedIsInteger = ($storedVersion -is [int]) -or ($storedVersion -is [long])
if ($storedIsInteger -and $storedVersion -gt $currentVersion) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.pool_intent_schema_unsupported' -Arguments @{ version = $storedVersion; expected = $currentVersion }) -ErrorAction Continue
    exit $ExitFailure
}
$hasLibrary = Test-Path -LiteralPath $libraryPath
$needsUpgrade = -not ($storedIsInteger -and $storedVersion -eq $currentVersion)
if (-not $needsUpgrade -and -not $hasLibrary) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.pool_intent_schema_already_current' -Arguments @{ version = $currentVersion }) -InformationAction Continue
    exit $ExitOk
}

# --- REGION: Apply the change
# A version this checkout cannot upgrade (not an integer) stays as stored, and
# the schema validation inside Publish-YurunaPoolDocChange then refuses it.
$doc = ConvertTo-PoolIntentSchemaV3 -Doc $stored
if ($hasLibrary) { Remove-Item -LiteralPath $libraryPath -Force }

# --- REGION: Save, commit and push
# Any admin write saves a store at schemaVersion 3 but leaves test-sets.yml in
# place, so a store can reach this point already current; its commit then only
# deletes that file, and the subject says so instead of claiming a migration.
$message = if ($needsUpgrade) { 'Migrate pool intent to schemaVersion 3' } else { 'pool: remove test-sets.yml' }
$pub = Publish-YurunaPoolDocChange -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Message $message -Confirm:$false
if (-not $pub.Ok) { Write-Error $pub.Error -ErrorAction Continue; exit $ExitFailure }

if ($hasLibrary) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.pool_intent_library_removed') -InformationAction Continue }
if ($needsUpgrade) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.pool_intent_schema_migrated' -Arguments @{ from = $storedVersion; to = $currentVersion }) -InformationAction Continue }
exit $ExitOk
