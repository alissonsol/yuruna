<#PSScriptInfo
.VERSION 2026.10.18.1
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
    Validate every file in the pool configuration store against its schema. Read-only.
.DESCRIPTION
    See https://yuruna.link/42010605-0004.
.EXAMPLE
    test/pool/Test-PoolConfiguration.ps1 -ConfigurationGitUrl /var/lib/yuruna/pool-configuration.git
#>

[CmdletBinding()]
param(
    [string]$ConfigurationGitUrl,
    [string]$ConfigurationDir
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Log level from environment
# See https://yuruna.link/42162449-0004
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

# --- REGION: Open the configuration store
$open = Open-YurunaPoolAdminStore -ConfigurationGitUrl $ConfigurationGitUrl -ConfigurationDir $ConfigurationDir -Confirm:$false
$t = $open.Target
if (-not $open.Ok) { Write-Error $open.Error -ErrorAction Continue; exit $ExitFailure }

# --- REGION: Report
$failures = 0
# pools.yml is REQUIRED: an absent one must not read as success -- the runners
# pull whatever is committed, so a missing pools.yml would silently leave the
# pool unconfigured. guests.compatibility.yml is optional
# (Test-YurunaPoolConfigurationFile SKIPs it when absent).
$poolsPath = Join-Path $t.ConfigurationDir 'pools.yml'
# The version is read raw, never through Read-YurunaPoolsDoc: that path upgrades
# in memory, so an outdated store would read as current. An absent
# schemaVersion reads as 2, the rule ConvertTo-PoolConfigurationSchemaV4 applies. A
# file that is missing or will not parse is left to Test-YurunaPoolConfigurationFile.
$storedVersion = $null
if (Test-Path -LiteralPath $poolsPath) {
    try {
        $stored = Get-Content -Raw -LiteralPath $poolsPath | ConvertFrom-Yaml -Ordered
        if ($stored -is [System.Collections.IDictionary]) { $storedVersion = if ($stored.Contains('schemaVersion')) { $stored['schemaVersion'] } else { 2 } }
    } catch { $storedVersion = $null }
}
$storedIsInteger = ($storedVersion -is [int]) -or ($storedVersion -is [long])
$schemaOutdated  = $storedIsInteger -and ($storedVersion -lt 4)
$schemaCurrent   = $storedIsInteger -and ($storedVersion -eq 4)
if ($schemaOutdated) {
    # One finding that names the fix. Validating an outdated store against the
    # v4 schema, or checking the v4 target-pool rule on it, would only restate
    # the same cause as a second failure or pass vacuously.
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.pool_configuration_schema_outdated' -Arguments @{ found = "$storedVersion"; expected = 4 })
    $failures++
} elseif (-not (Test-YurunaPoolConfigurationFile -Path $poolsPath -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required)) { $failures++ }
if (-not (Test-YurunaPoolConfigurationFile -Path (Join-Path $t.ConfigurationDir 'guests.compatibility.yml') -SchemaName 'guests.compatibility.schema.yml' -Label 'guests.compatibility.yml')) { $failures++ }

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

        # See https://yuruna.link/42010605-0004
        $targetPoolId = if ($poolsDoc['autoEnrollment']) { [string]$poolsDoc['autoEnrollment']['targetPoolId'] } else { '' }
        if ($schemaCurrent -and $targetPoolId) {
            $violations = 0
            foreach ($p in @($poolsDoc['pools'])) {
                if ($p -isnot [System.Collections.IDictionary]) { continue }
                if ([string]$p['poolId'] -ne $targetPoolId) { continue }
                if ($p.Contains('repositories')) {
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
