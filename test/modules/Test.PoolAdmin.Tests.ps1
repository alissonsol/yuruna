<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42a44cb3-b163-4c40-bb54-44dd8119924a
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

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolAdmin.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: throwaway temp dir the It block deletes in its finally.')]
    [CmdletBinding()] [OutputType([string])] param()
    return New-YurunaTestTempDir -Prefix 'yrn-pooladmin'
}

# Fixtures live at file scope, above the first Describe: a Describe body runs during
# the discovery pass and its variables are torn down before any It executes, so a doc
# declared inside the Describe would reach the assertion as $null.
$script:LookupDoc = [ordered]@{ schemaVersion = 1; pools = @(
    [ordered]@{ poolId = 'lab' }, [ordered]@{ poolId = 'prod' }
) }

}

Describe 'Test-YurunaPoolDocValid (schema validation)' {
    It 'accepts a valid pools doc' {
        $doc = [ordered]@{ schemaVersion = 4; pools = @(
            [ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; members = @('42abcdef0123456789abcdef01234567'); configuredState = 'run' }
        ) }
        $r = Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml'
        Assert-True $r.Ok "valid doc should pass: $($r.Errors -join '; ')"
    }
    It 'rejects a bad poolId and an unknown configuredState' {
        $bad = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{ poolId = 'NOT VALID'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; configuredState = 'banana' }) }
        $r = Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml'
        # Only assert when Test-Json is present (older PS degrades to parse-only Ok).
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            Assert-False $r.Ok 'bad poolId / configuredState must fail'
        }
    }
    It 'rejects a missing required field (schemaVersion)' {
        $bad = [ordered]@{ pools = @() }
        $r = Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml'
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            Assert-False $r.Ok 'missing schemaVersion must fail'
        }
    }
    It 'names where a violation nested below the first level breaks the schema' {
        if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) { return }
        $bad = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{
            poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
            repositories = [ordered]@{ name = 'p'; frameworkUrl = 'https://x/f'; projectUrl = 'https://x/p' }
        }) }
        $r = Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml'
        Assert-False $r.Ok 'an extra property inside a repositories pair must fail'
        Assert-Match '/pools/0/repositories' ($r.Errors -join '; ') 'the reason names the nested location'
    }
    It 'validates a v4 pool doc with a repositories pair' {
        $good = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{
            poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
            members = @(); repositories = [ordered]@{ frameworkUrl = 'https://x/f'; projectUrl = 'https://x/p' }
        }) }
        $r = Test-YurunaPoolDocValid -Doc $good -SchemaName 'pools.schema.yml'
        Assert-True $r.Ok "valid v4 pool should pass: $($r.Errors -join '; ')"
    }
    It 'rejects a v4 pool doc with a testSet, a half pair, an empty URL or schemaVersion 2' {
        if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) { return }
        $guid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
        $badPools = [ordered]@{
            'testSet'        = [ordered]@{ poolId = 'lab'; poolGuid = $guid; testSet = [ordered]@{ name = 'p'; frameworkUrl = 'https://x/f'; projectUrl = 'https://x/p' } }
            'half pair'      = [ordered]@{ poolId = 'lab'; poolGuid = $guid; repositories = [ordered]@{ frameworkUrl = 'https://x/f' } }
            'empty URL'      = [ordered]@{ poolId = 'lab'; poolGuid = $guid; repositories = [ordered]@{ frameworkUrl = 'https://x/f'; projectUrl = '' } }
            'legacy state'   = [ordered]@{ poolId = 'lab'; poolGuid = $guid; desiredState = 'paused' }
            'dual state'     = [ordered]@{ poolId = 'lab'; poolGuid = $guid; desiredState = 'paused'; configuredState = 'paused' }
            'extra property' = [ordered]@{ poolId = 'lab'; poolGuid = $guid; repositories = [ordered]@{ name = 'p'; frameworkUrl = 'https://x/f'; projectUrl = 'https://x/p' } }
        }
        foreach ($name in @($badPools.Keys)) {
            $bad = [ordered]@{ schemaVersion = 4; pools = @($badPools[$name]) }
            Assert-False (Test-YurunaPoolDocValid -Doc $bad -SchemaName 'pools.schema.yml').Ok "$name must fail"
        }
        foreach ($version in @(2, 3)) {
            Assert-False (Test-YurunaPoolDocValid -Doc ([ordered]@{ schemaVersion = $version; pools = @() }) -SchemaName 'pools.schema.yml').Ok "schemaVersion $version must fail"
        }
    }
}

Describe 'Read-YurunaPoolsDoc (default-empty)' {
    It 'returns a fresh empty doc when pools.yml is absent' {
        $d = New-TempDir
        try {
            $doc = Read-YurunaPoolsDoc -ConfigurationDir $d
            Assert-Equal -Expected 4 -Actual $doc['schemaVersion'] -Because 'default schemaVersion'
            Assert-Equal -Expected 0 -Actual @($doc['pools']).Count -Because 'default empty pools'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'round-trips a written pools.yml' {
        $d = New-TempDir
        try {
            $doc = [ordered]@{ schemaVersion = 1; pools = @([ordered]@{ poolId = 'lab'; members = @(); configuredState = 'run' }) }
            $yaml = ConvertTo-Yaml $doc
            [System.IO.File]::WriteAllText((Join-Path $d 'pools.yml'), $yaml, [System.Text.UTF8Encoding]::new($false))
            $back = Read-YurunaPoolsDoc -ConfigurationDir $d
            Assert-Equal -Expected 'lab' -Actual (Get-YurunaPoolFromDoc -Doc $back -PoolId 'lab').poolId -Because 'lab present after round-trip'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-YurunaPoolFromDoc (lookup by id)' {
    It 'finds an existing pool' { Assert-Equal -Expected 'prod' -Actual (Get-YurunaPoolFromDoc -Doc $script:LookupDoc -PoolId 'prod').poolId -Because 'prod found' }
    It 'returns null for a missing pool' { Assert-Null (Get-YurunaPoolFromDoc -Doc $script:LookupDoc -PoolId 'nope') 'missing -> null' }
}

Describe 'Resolve-YurunaPoolAdminTarget (defaults)' {
    It 'defaults ConfigurationDir under the runtime dir' {
        $t = Resolve-YurunaPoolAdminTarget -ConfigurationGitUrl 'http://p/i.git' -ConfigurationDir ''
        Assert-Equal -Expected 'http://p/i.git' -Actual $t.ConfigurationGitUrl -Because 'url passthrough'
        Assert-True ($t.ConfigurationDir -match 'pool-configuration-admin$') 'default clone dir'
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

Describe 'Initialize-YurunaPoolConfigurationStorePath (seed a writable store that was never created)' {
    It 'seeds a bare store at a local path that carries none' {
        $work = New-TempDir
        try {
            $store = Join-Path $work 'pool-configuration.git'
            $r = Initialize-YurunaPoolConfigurationStorePath -ConfigurationGitUrl $store -Confirm:$false
            Assert-True $r.Ok 'reports success'
            Assert-True $r.Created 'created the store'
            Assert-True (Test-Path -LiteralPath (Join-Path $store 'refs')) 'a bare repository is on disk'
            # A fresh store starts with the current writable schema.
            $doc = & git -C $store show 'main:pools.yml' 2>$null
            Assert-True ("$doc" -match 'schemaVersion:\s*4') 'seeded at schemaVersion 4'
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves an existing store untouched' {
        $work = New-TempDir
        try {
            $store = Join-Path $work 'pool-configuration.git'
            $null = New-YurunaPoolConfigurationStore -Path $store -Confirm:$false
            $before = (& git -C $store rev-parse main 2>$null)
            $r = Initialize-YurunaPoolConfigurationStorePath -ConfigurationGitUrl $store -Confirm:$false
            Assert-True $r.Ok 'reports success'
            Assert-False $r.Created 'did not recreate'
            Assert-Equal -Expected "$before" -Actual "$(& git -C $store rev-parse main 2>$null)" -Because 'history preserved'
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'never tries to create a remote the host does not own' {
        # Ok WITHOUT Created: the caller proceeds to its own clone, whose failure is
        # the honest report for a remote this side cannot reach.
        foreach ($remote in @('http://proxy/pool-configuration.git', 'https://git.example.com/team/configuration.git',
                              'ssh://git@example/pool-configuration.git', 'git@github.com:owner/configuration.git')) {
            $r = Initialize-YurunaPoolConfigurationStorePath -ConfigurationGitUrl $remote -Confirm:$false
            Assert-True  $r.Ok      "remote tolerated: $remote"
            Assert-False $r.Created "nothing created for: $remote"
        }
    }
    It 'reports a blank url rather than seeding somewhere unintended' {
        $r = Initialize-YurunaPoolConfigurationStorePath -ConfigurationGitUrl '   ' -Confirm:$false
        Assert-False $r.Ok 'a blank target is not a store'
        Assert-False $r.Created 'nothing created'
    }
    It 'honors -WhatIf' {
        $work = New-TempDir
        try {
            $store = Join-Path $work 'pool-configuration.git'
            $r = Initialize-YurunaPoolConfigurationStorePath -ConfigurationGitUrl $store -WhatIf
            Assert-False $r.Created 'a preview creates nothing'
            Assert-False (Test-Path -LiteralPath $store) 'nothing on disk'
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
