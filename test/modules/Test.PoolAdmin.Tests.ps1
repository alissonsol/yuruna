<#PSScriptInfo
.VERSION 2026.08.02
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
        $doc = [ordered]@{ schemaVersion = 2; pools = @(
            [ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; members = @('42abcdef0123456789abcdef01234567'); desiredState = 'run' }
        ) }
        $r = Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml'
        Assert-True $r.Ok "valid doc should pass: $($r.Errors -join '; ')"
    }
    It 'rejects a bad poolId and an unknown desiredState' {
        $bad = [ordered]@{ schemaVersion = 2; pools = @([ordered]@{ poolId = 'NOT VALID'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; desiredState = 'banana' }) }
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
    It 'validates a v2 pool doc with a repo-triple testSet' {
        $good = [ordered]@{ schemaVersion = 2; pools = @([ordered]@{
            poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
            members = @(); testSet = [ordered]@{ name = 'p'; frameworkUrl = 'https://x/f'; projectUrl = 'https://x/p' }
        }) }
        $r = Test-YurunaPoolDocValid -Doc $good -SchemaName 'pools.schema.yml'
        Assert-True $r.Ok "valid v2 pool should pass: $($r.Errors -join '; ')"
    }
}

Describe 'Read-YurunaPoolsDoc (default-empty)' {
    It 'returns a fresh empty doc when pools.yml is absent' {
        $d = New-TempDir
        try {
            $doc = Read-YurunaPoolsDoc -IntentDir $d
            Assert-Equal -Expected 2 -Actual $doc['schemaVersion'] -Because 'default schemaVersion'
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

Describe 'ConvertTo-YurunaHostId (operator input normalization)' {
    It 'passes a canonical hostId through unchanged' {
        Assert-Equal -Expected '42abcdef0123456789abcdef01234567' `
            -Actual (ConvertTo-YurunaHostId -Value '42abcdef0123456789abcdef01234567') -Because 'canonical is a no-op'
    }
    It 'accepts the dashboard Host ID column rendering (8-4-4-4-12)' {
        Assert-Equal -Expected '425bed3d40a041c2be882ac911279d50' `
            -Actual (ConvertTo-YurunaHostId -Value '425bed3d-40a0-41c2-be88-2ac911279d50') -Because 'dashes stripped'
    }
    It 'tolerates braces, surrounding whitespace, and uppercase hex' {
        Assert-Equal -Expected '42abcdef0123456789abcdef01234567' `
            -Actual (ConvertTo-YurunaHostId -Value "  {42ABCDEF-0123-4567-89AB-CDEF01234567}`t") -Because 'copy-paste noise stripped, lowercased'
    }
    It 'rejects non-hostId input' {
        foreach ($bad in @('', '   ', $null, 'not-a-uuid', '43abcdef0123456789abcdef01234567',
                           '42abcdef0123456789abcdef0123456', '42abcdef0123456789abcdef012345678',
                           '42abcdefg123456789abcdef01234567')) {
            Assert-Null (ConvertTo-YurunaHostId -Value $bad) "rejects [$bad]"
        }
    }
    It 'does not accept dashes as free padding to the right length' {
        # Stripping happens before the length check, so a 32-char string that is only
        # 32 long BECAUSE of its dashes must still fail.
        Assert-Null (ConvertTo-YurunaHostId -Value '42-abcdef0123456789abcdef0123456') 'short after stripping'
    }
}
