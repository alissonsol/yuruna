<#PSScriptInfo
.VERSION 2026.09.18
.GUID 421a5b0c-c7c1-4612-9a9e-d61b0c836775
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
    test/pool/Test-PoolIntent.ps1 -IntentGitUrl /var/lib/yuruna/pool-intent.git
#>

[CmdletBinding()]
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

# --- REGION: Open the intent store
$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_7dd0aa845d3a93ea') -ErrorAction Continue
    exit $ExitFailure
}
$open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
if (-not $open.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5080fa98b3c9b51c' -Arguments @{ intentGitUrl = "$($t.IntentGitUrl)"; error = "$($open.Error)" }) -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Report
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
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_fe2c5d57673db03c' -Arguments @{ h = "$h"; h2 = "$($seen[$h])"; thisPool = "$thisPool" })
                    $dupes++
                } else { $seen[$h] = $thisPool }
            }
        }
        if ($dupes -eq 0) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_eb9468440861e598') -InformationAction Continue }
        else { $failures += $dupes }

        # The auto-enrollment target pool must carry NO test-set. This is the
        # AUTHORITATIVE check: the CLI refuses and the UI disables, but only
        # this one catches a hand-edited file or a store written by an older
        # release. It is a cross-field constraint (a pool named by ANOTHER
        # field), which JSON Schema cannot express.
        #
        # A violation FAILS rather than being silently stripped: stripping it
        # would change what a lab is running without anyone deciding to.
        $targetPoolId = if ($poolsDoc['autoEnrollment']) { [string]$poolsDoc['autoEnrollment']['targetPoolId'] } else { '' }
        if ($targetPoolId) {
            $violations = 0
            foreach ($p in @($poolsDoc['pools'])) {
                if ($p -isnot [System.Collections.IDictionary]) { continue }
                if ([string]$p['poolId'] -ne $targetPoolId) { continue }
                if ($p['testSet']) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_331c67920b1a4f01' -Arguments @{ targetPoolId = "$targetPoolId" })
                    $violations++
                }
            }
            if ($violations -eq 0) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f4ce3623f58ca8ac' -Arguments @{ targetPoolId = "$targetPoolId" }) -InformationAction Continue }
            else { $failures += $violations }
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4b7f2e4a23f336a0' -Arguments @{ message = "$($_.Exception.Message)" })
        $failures++
    }
}

Write-Information "" -InformationAction Continue
if ($failures -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b11e32378aff0234') -InformationAction Continue
    exit $ExitOk
}
Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b85e68a82dd79259' -Arguments @{ failures = "$failures" })
exit $ExitFailure
