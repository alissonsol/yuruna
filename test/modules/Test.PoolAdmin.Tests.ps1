<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42f4a5b6-c7d8-4e90-8f12-4a5b6c7d8e90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool admin pester
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
    Pester coverage for the no-network pieces of Test.PoolAdmin.psm1: schema
    validation of in-memory docs (against the real test/schemas/*.yml), the
    default-empty pools doc, and pool lookup by id. The git clone/commit/push are
    integration-verified against a real bare repo.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolAdmin.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Null  { param($Actual, [string]$Because = '') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: throwaway temp dir the It block deletes in its finally.')]
    [CmdletBinding()] [OutputType([string])] param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-pooladmin-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $d
    return $d
}

# Fixtures live at file scope, above the first Describe: a Describe body runs during
# the discovery pass and its variables are torn down before any It executes, so a doc
# declared inside the Describe would reach the assertion as $null.
$LookupDoc = [ordered]@{ schemaVersion = 1; pools = @(
    [ordered]@{ poolId = 'lab' }, [ordered]@{ poolId = 'prod' }
) }

Describe 'Test-YurunaPoolDocValid (schema validation)' {
    It 'accepts a valid pools doc' {
        $doc = [ordered]@{ schemaVersion = 1; pools = @(
            [ordered]@{ poolId = 'lab'; members = @('42abcdef0123456789abcdef01234567'); desiredState = 'run' }
        ) }
        $r = Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml'
        Assert-True $r.Ok "valid doc should pass: $($r.Errors -join '; ')"
    }
    It 'rejects a bad poolId and an unknown desiredState' {
        $bad = [ordered]@{ schemaVersion = 1; pools = @([ordered]@{ poolId = 'NOT VALID'; desiredState = 'banana' }) }
        $r = Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml'
        # Only assert when Test-Json is present (older PS degrades to parse-only Ok).
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            Assert-False $r.Ok 'bad poolId / desiredState must fail'
        }
    }
    It 'rejects a missing required field (schemaVersion)' {
        $bad = [ordered]@{ pools = @() }
        $r = Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml'
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            Assert-False $r.Ok 'missing schemaVersion must fail'
        }
    }
    It 'validates a test-set doc' {
        $ts = [ordered]@{ schemaVersion = 1; name = 'smoke'; sequences = @('a.install'); requiredGuests = @('guest.ubuntu.server.24') }
        $r = Test-YurunaPoolDocValid -Doc $ts -SchemaName 'test-set.schema.yml'
        Assert-True $r.Ok "valid test-set should pass: $($r.Errors -join '; ')"
    }
}

Describe 'Read-YurunaPoolsDoc (default-empty)' {
    It 'returns a fresh empty doc when pools.yml is absent' {
        $d = New-TempDir
        try {
            $doc = Read-YurunaPoolsDoc -IntentDir $d
            Assert-Equal -Expected 1 -Actual $doc['schemaVersion'] -Because 'default schemaVersion'
            Assert-Equal -Expected 0 -Actual @($doc['pools']).Count -Because 'default empty pools'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'round-trips a written pools.yml' {
        $d = New-TempDir
        try {
            $doc = [ordered]@{ schemaVersion = 1; pools = @([ordered]@{ poolId = 'lab'; members = @(); desiredState = 'run' }) }
            $yaml = ConvertTo-Yaml $doc
            [System.IO.File]::WriteAllText((Join-Path $d 'pools.yml'), $yaml, [System.Text.UTF8Encoding]::new($false))
            $back = Read-YurunaPoolsDoc -IntentDir $d
            Assert-Equal -Expected 'lab' -Actual (Get-YurunaPoolFromDoc -Doc $back -PoolId 'lab').poolId -Because 'lab present after round-trip'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-YurunaPoolFromDoc (lookup by id)' {
    It 'finds an existing pool' { Assert-Equal -Expected 'prod' -Actual (Get-YurunaPoolFromDoc -Doc $LookupDoc -PoolId 'prod').poolId -Because 'prod found' }
    It 'returns null for a missing pool' { Assert-Null (Get-YurunaPoolFromDoc -Doc $LookupDoc -PoolId 'nope') 'missing -> null' }
}

Describe 'Resolve-YurunaPoolAdminTarget (defaults)' {
    It 'defaults IntentDir under the runtime dir' {
        $t = Resolve-YurunaPoolAdminTarget -IntentGitUrl 'http://p/i.git' -IntentDir ''
        Assert-Equal -Expected 'http://p/i.git' -Actual $t.IntentGitUrl -Because 'url passthrough'
        Assert-True ($t.IntentDir -match 'pool-intent-admin$') 'default clone dir'
    }
}
