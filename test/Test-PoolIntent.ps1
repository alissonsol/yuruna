<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42d7e8f9-a0b1-4c23-8d45-7e8f9a0b1234
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin validation ci-gate
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
    Validate every file in the pool intent store against its schema. Read-only.
.DESCRIPTION
    Pool admin CLI / CI gate. Clones/pulls the intent store and validates
    pools.yml, every test-sets/*.yml, and guests.compatibility.yml (when present)
    against test/schemas/*. Exit 0 when all valid, 1 on any error. Never writes.
    Run before relying on freshly-authored intent (the runners pull whatever is
    committed, so a malformed file would silently misconfigure the whole pool).
.EXAMPLE
    ./Test-PoolIntent.ps1 -IntentGitUrl /var/lib/yuruna/pool-intent.git
#>

[CmdletBinding()]
param(
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

$failures = 0
# pools.yml is REQUIRED: an absent one must not read as success -- the runners
# pull whatever is committed, so a missing pools.yml would silently leave the
# pool unconfigured. guests.compatibility.yml and the test-sets are optional
# (Test-YurunaPoolIntentFile SKIPs them when absent).
if (-not (Test-YurunaPoolIntentFile -Path (Join-Path $t.IntentDir 'pools.yml') -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required)) { $failures++ }
if (-not (Test-YurunaPoolIntentFile -Path (Join-Path $t.IntentDir 'guests.compatibility.yml') -SchemaName 'guests.compatibility.schema.yml' -Label 'guests.compatibility.yml')) { $failures++ }
$tsDir = Join-Path $t.IntentDir 'test-sets'
if (Test-Path -LiteralPath $tsDir) {
    foreach ($f in @(Get-ChildItem -Path $tsDir -Filter '*.yml' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-YurunaPoolIntentFile -Path $f.FullName -SchemaName 'test-set.schema.yml' -Label "test-sets/$($f.Name)")) { $failures++ }
    }
}

Write-Information "" -InformationAction Continue
if ($failures -eq 0) {
    Write-Information 'Pool intent: all files schema-valid.' -InformationAction Continue
    exit $ExitOk
}
Write-Warning "Pool intent: $failures file(s) FAILED validation."
exit $ExitFailure
