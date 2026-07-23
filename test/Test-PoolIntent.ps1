<#PSScriptInfo
.VERSION 2026.07.22
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
    pools.yml (schema v2) and guests.compatibility.yml (when present) against
    test/schemas/*, and enforces the cross-pool invariant that a host belongs to
    at most one pool. Exit 0 when all valid, 1 on any error. Never writes. Run
    before relying on freshly-authored intent (the runners pull whatever is
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
# pool unconfigured. guests.compatibility.yml is optional
# (Test-YurunaPoolIntentFile SKIPs it when absent).
$poolsPath = Join-Path $t.IntentDir 'pools.yml'
if (-not (Test-YurunaPoolIntentFile -Path $poolsPath -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required)) { $failures++ }
if (-not (Test-YurunaPoolIntentFile -Path (Join-Path $t.IntentDir 'guests.compatibility.yml') -SchemaName 'guests.compatibility.schema.yml' -Label 'guests.compatibility.yml')) { $failures++ }

# Cross-pool invariant: a host belongs to AT MOST one pool. The schema cannot
# express this (it spans array elements), so enforce it here.
if (Test-Path -LiteralPath $poolsPath) {
    try {
        $poolsDoc = Get-Content -Raw -LiteralPath $poolsPath | ConvertFrom-Yaml -Ordered
        $seen = @{}
        $dupes = 0
        foreach ($p in @($poolsDoc['pools'])) {
            if ($p -isnot [System.Collections.IDictionary]) { continue }
            $thisPool = [string]$p['poolId']
            foreach ($m in @($p['members'])) {
                $h = [string]$m
                if ($seen.ContainsKey($h)) {
                    Write-Warning "FAIL  member-uniqueness: host $h is in both '$($seen[$h])' and '$thisPool' (a host belongs to at most one pool)."
                    $dupes++
                } else { $seen[$h] = $thisPool }
            }
        }
        if ($dupes -eq 0) { Write-Information 'PASS  member-uniqueness: no host is in more than one pool.' -InformationAction Continue }
        else { $failures += $dupes }
    } catch {
        Write-Warning "FAIL  member-uniqueness: could not parse pools.yml -- $($_.Exception.Message)"
        $failures++
    }
}

Write-Information "" -InformationAction Continue
if ($failures -eq 0) {
    Write-Information 'Pool intent: all files schema-valid.' -InformationAction Continue
    exit $ExitOk
}
Write-Warning "Pool intent: $failures file(s) FAILED validation."
exit $ExitFailure
