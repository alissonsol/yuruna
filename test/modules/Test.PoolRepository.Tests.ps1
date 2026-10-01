<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42d2a293-af6c-4dd9-a606-42daae4a745b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool admin repositories migration pester
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
    Functional coverage for a pool's framework and project repositories:
    Set-PoolRepository.ps1, ConvertTo-PoolIntentSchemaV3,
    Update-PoolIntentSchema.ps1, and what Test-PoolIntent.ps1 and
    Get-PoolIntent.ps1 report about them.
.DESCRIPTION
    Every CLI runs as a child pwsh against a real local bare store seeded by
    New-YurunaPoolIntentStore, and every assertion reads what was pushed to that
    store. Nothing is stubbed: the clone, the schema validation, the commit and
    the push are the ones an operator runs. Output is matched only on check ids,
    parameter names and script names, which every locale keeps verbatim.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:PoolDir = Join-Path (Split-Path -Parent $here) 'pool'
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.PoolAdmin.psm1') -Force -Global -DisableNameChecking
    Import-Module powershell-yaml -Force

    # The CLIs resolve their runtime directory from this variable; pointing it
    # at TestDrive keeps every child process off the operator's own runtime.
    $script:PriorRuntimeDir = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $null = New-Item -ItemType Directory -Force -Path $env:YURUNA_RUNTIME_DIR

    $script:Guid1 = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
    $script:Guid2 = '42b1b2c3-d4e5-4f60-8a1b-2c3d4e5f6072'
    $script:Fw    = 'https://example.invalid/framework.git'
    $script:Proj  = 'https://example.invalid/project.git'

    function Invoke-PoolCli {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Name, [string[]]$ArgumentList = @())
        $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:PoolDir $Name) @ArgumentList 2>&1
        # Strip ANSI styling so the text is safe to match and to report.
        $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($text -replace "`e\[[0-9;]*m", '') }
    }

    function New-PoolStoreFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates only isolated test fixtures under TestDrive.')]
        [CmdletBinding()]
        param([System.Collections.IDictionary]$Pools, [string]$Library)
        $root  = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $store = Join-Path $root 'store.git'
        $null = New-YurunaPoolIntentStore -Path $store -Confirm:$false
        if ($Pools -or $Library) {
            $seed = Join-Path $root 'seed'
            & git clone --quiet -- $store $seed 2>&1 | Out-Null
            $utf8 = [Text.UTF8Encoding]::new($false)
            if ($Pools)   { [IO.File]::WriteAllText((Join-Path $seed 'pools.yml'), (ConvertTo-Yaml $Pools), $utf8) }
            if ($Library) { [IO.File]::WriteAllText((Join-Path $seed 'test-sets.yml'), $Library, $utf8) }
            & git -C $seed add -A 2>&1 | Out-Null
            & git -C $seed -c user.name=fixture -c user.email=fixture@yuruna.local commit --quiet -m 'fixture' 2>&1 | Out-Null
            & git -C $seed push --quiet origin HEAD:main 2>&1 | Out-Null
        }
        return [pscustomobject]@{ Store = $store; Clone = (Join-Path $root 'clone') }
    }

    function Get-StoreHead { param($Fixture) return ((& git -C $Fixture.Store rev-parse main 2>$null) -join '') }
    function Get-StoreSubject { param($Fixture) return ((& git -C $Fixture.Store log -1 --format=%s main 2>$null) -join '') }
    function Get-StorePoolDocument { param($Fixture) return (((& git -C $Fixture.Store show 'main:pools.yml' 2>$null) -join "`n") | ConvertFrom-Yaml -Ordered) }
    function Test-StoreHasFile {
        param($Fixture, [string]$Name)
        $null = & git -C $Fixture.Store cat-file -e "main:$Name" 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    function Get-FixturePool {
        param($Doc, [string]$PoolId)
        return (@($Doc['pools']) | Where-Object { [string]$_['poolId'] -ceq $PoolId } | Select-Object -First 1)
    }
    function Get-V3PoolDocument {
        param([switch]$LabRepositories, [switch]$TargetRepositories)
        $lab = [ordered]@{ poolId = 'lab'; poolGuid = $script:Guid1; displayName = 'Lab'; members = @(); desiredState = 'run' }
        if ($LabRepositories) { $lab['repositories'] = [ordered]@{ frameworkUrl = 'https://example.invalid/old-framework.git'; projectUrl = 'https://example.invalid/old-project.git' } }
        $target = [ordered]@{ poolId = 'default'; poolGuid = $script:Guid2; displayName = ''; members = @(); desiredState = 'run' }
        if ($TargetRepositories) { $target['repositories'] = [ordered]@{ frameworkUrl = $script:Fw; projectUrl = $script:Proj } }
        return [ordered]@{ schemaVersion = 3; pools = @($lab, $target); autoEnrollment = [ordered]@{ enabled = $true; targetPoolId = 'default' } }
    }
    function Get-V2PoolDocument {
        $lab = [ordered]@{
            poolId = 'lab'; poolGuid = $script:Guid1; displayName = 'Lab'; members = @()
            testSet = [ordered]@{ name = 'lab-set'; frameworkUrl = $script:Fw; projectUrl = $script:Proj; sequences = @('one') }
            desiredState = 'run'
        }
        $target = [ordered]@{ poolId = 'default'; poolGuid = $script:Guid2; members = @()
            testSet = [ordered]@{ name = 'target-set'; frameworkUrl = $script:Fw; projectUrl = $script:Proj } }
        return [ordered]@{ schemaVersion = 2; pools = @($lab, $target); autoEnrollment = [ordered]@{ enabled = $true; targetPoolId = 'default' } }
    }
    $script:Library = "schemaVersion: 1`ntestSets:`n  - name: lab-set`n    frameworkUrl: $($script:Fw)`n    projectUrl: $($script:Proj)`n"
}

AfterAll {
    if ($null -eq $script:PriorRuntimeDir) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    else { $env:YURUNA_RUNTIME_DIR = $script:PriorRuntimeDir }
}

Describe 'Set-PoolRepository.ps1 sets and clears a pool''s repositories' {
    It 'sets the trimmed pair on the pool and commits it' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'lab', '-FrameworkUrl', " $($script:Fw) ", '-ProjectUrl', "$($script:Proj)`t", '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0 -Because 'a valid pair is accepted'
        $lab = Get-FixturePool (Get-StorePoolDocument $f) 'lab'
        $lab['repositories']['frameworkUrl'] | Should -BeExactly $script:Fw
        $lab['repositories']['projectUrl'] | Should -BeExactly $script:Proj
        Get-StoreSubject $f | Should -BeExactly 'pool: set repositories on lab'
    }
    It 'replaces a pair the pool already carries' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument -LabRepositories)
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'lab', '-FrameworkUrl', $script:Fw, '-ProjectUrl', $script:Proj, '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        $lab = Get-FixturePool (Get-StorePoolDocument $f) 'lab'
        $lab['repositories']['frameworkUrl'] | Should -BeExactly $script:Fw
        $lab['repositories']['projectUrl'] | Should -BeExactly $script:Proj
    }
    It 'clears the pair with -Clear' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument -LabRepositories)
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'lab', '-Clear', '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        (Get-FixturePool (Get-StorePoolDocument $f) 'lab').Contains('repositories') | Should -BeFalse
        Get-StoreSubject $f | Should -BeExactly 'pool: clear repositories on lab'
    }
    It 'treats -Clear on a pool without repositories as done, with no commit' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'lab', '-Clear', '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        Get-StoreHead $f | Should -BeExactly $before
    }
    It 'refuses a single URL and leaves the store untouched' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'lab', '-FrameworkUrl', $script:Fw, '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Not -Be 0
        Get-StoreHead $f | Should -BeExactly $before
    }
    It 'refuses the unsafe FrameworkUrl <Case> and leaves the store untouched' -ForEach @(
        @{ Case = 'with inner whitespace'; Arguments = @('-FrameworkUrl', 'https://example.invalid/a b') }
        @{ Case = 'with a control character'; Arguments = @('-FrameworkUrl', "https://example.invalid/a$([char]7)b") }
        @{ Case = 'that is only whitespace'; Arguments = @('-FrameworkUrl', '   ') }
        @{ Case = 'that starts with a dash after trimming'; Arguments = @('-FrameworkUrl', ' -x') }
        @{ Case = 'that starts with a dash'; Arguments = @('-FrameworkUrl:-x') }
    ) {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' (@('-PoolId', 'lab') + $Arguments + @('-ProjectUrl', $script:Proj, '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone))
        $run.Code | Should -Not -Be 0
        $run.Text | Should -Match 'FrameworkUrl'
        Get-StoreHead $f | Should -BeExactly $before
    }
    It 'refuses an unknown pool' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'nope', '-FrameworkUrl', $script:Fw, '-ProjectUrl', $script:Proj, '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Not -Be 0
        Get-StoreHead $f | Should -BeExactly $before
    }
    It 'refuses to set repositories on the auto-enrollment target pool, however its id is cased' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument)
        $before = Get-StoreHead $f
        foreach ($typed in @('default', 'DEFAULT')) {
            $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', $typed, '-FrameworkUrl', $script:Fw, '-ProjectUrl', $script:Proj, '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
            $run.Code | Should -Not -Be 0 -Because "-PoolId $typed names the target pool"
            $run.Text | Should -Match 'Set-PoolRepository\.ps1'
        }
        Get-StoreHead $f | Should -BeExactly $before
    }
    It 'clears repositories the auto-enrollment target pool should not carry' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument -TargetRepositories)
        $run = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'default', '-Clear', '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        (Get-FixturePool (Get-StorePoolDocument $f) 'default').Contains('repositories') | Should -BeFalse
    }
}

Describe 'ConvertTo-PoolIntentSchemaV3 upgrades a pools document in place' {
    It 'moves a v2 testSet pair to repositories in the same position and drops the rest' {
        $doc = Get-V2PoolDocument
        $doc['pools'] += [ordered]@{ poolId = 'half'; poolGuid = '42c1b2c3-d4e5-4f60-8a1b-2c3d4e5f6073'
            testSet = [ordered]@{ name = 'half'; frameworkUrl = $script:Fw; projectUrl = ' ' }; testSets = @('legacy') }
        $out = ConvertTo-PoolIntentSchemaV3 -Doc $doc
        [object]::ReferenceEquals($out, $doc) | Should -BeTrue -Because 'the document is upgraded in place'
        $doc['schemaVersion'] | Should -Be 3
        $lab = Get-FixturePool $doc 'lab'
        @($lab.Keys) -join ',' | Should -BeExactly 'poolId,poolGuid,displayName,members,repositories,desiredState'
        $lab['repositories']['frameworkUrl'] | Should -BeExactly $script:Fw
        $lab['repositories']['projectUrl'] | Should -BeExactly $script:Proj
        $half = Get-FixturePool $doc 'half'
        $half.Contains('repositories') | Should -BeFalse -Because 'a pair with an empty URL is not a pair'
        $half.Contains('testSet') | Should -BeFalse
        $half.Contains('testSets') | Should -BeFalse
        (Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml').Ok | Should -BeTrue
    }
    It 'adds schemaVersion 3 as the first key when the document has none' {
        $doc = [ordered]@{ pools = @() }
        $null = ConvertTo-PoolIntentSchemaV3 -Doc $doc
        @($doc.Keys)[0] | Should -BeExactly 'schemaVersion'
        $doc['schemaVersion'] | Should -Be 3
    }
    It 'is idempotent and leaves a v3 document unchanged' {
        $doc = Get-V2PoolDocument
        $once = ConvertTo-Yaml (ConvertTo-PoolIntentSchemaV3 -Doc $doc)
        ConvertTo-Yaml (ConvertTo-PoolIntentSchemaV3 -Doc $doc) | Should -BeExactly $once
        $v3 = Get-V3PoolDocument -LabRepositories
        $before = ConvertTo-Yaml $v3
        ConvertTo-Yaml (ConvertTo-PoolIntentSchemaV3 -Doc $v3) | Should -BeExactly $before
    }
    It 'leaves a newer or a non-integer schemaVersion untouched' {
        foreach ($version in @(4, 'two')) {
            $doc = Get-V2PoolDocument
            $doc['schemaVersion'] = $version
            $before = ConvertTo-Yaml $doc
            ConvertTo-Yaml (ConvertTo-PoolIntentSchemaV3 -Doc $doc) | Should -BeExactly $before
        }
    }
    It 'keeps a one-pool list a list through Read-YurunaPoolsDoc' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $one = [ordered]@{ schemaVersion = 2; pools = @([ordered]@{ poolId = 'lab'; poolGuid = $script:Guid1
            testSet = [ordered]@{ name = 'x'; frameworkUrl = $script:Fw; projectUrl = $script:Proj } }) }
        [IO.File]::WriteAllText((Join-Path $dir 'pools.yml'), (ConvertTo-Yaml $one), [Text.UTF8Encoding]::new($false))
        $doc = Read-YurunaPoolsDoc -IntentDir $dir
        $doc['schemaVersion'] | Should -Be 3
        ($doc | ConvertTo-Json -Depth 10 -Compress) | Should -Match '"pools":\[\{'
        (Get-FixturePool $doc 'lab')['repositories']['projectUrl'] | Should -BeExactly $script:Proj
    }
}

Describe 'Update-PoolIntentSchema.ps1 migrates a store once' {
    BeforeAll {
        $script:Migrated = New-PoolStoreFixture -Pools (Get-V2PoolDocument) -Library $script:Library
        $script:SeedHead = Get-StoreHead $script:Migrated
    }
    It 'migrates a v2 store, deletes test-sets.yml and commits once' {
        $run = Invoke-PoolCli 'Update-PoolIntentSchema.ps1' @('-IntentGitUrl', $script:Migrated.Store, '-IntentDir', $script:Migrated.Clone)
        $run.Code | Should -Be 0
        Get-StoreSubject $script:Migrated | Should -BeExactly 'Migrate pool intent to schemaVersion 3'
        ((& git -C $script:Migrated.Store rev-parse 'main~1' 2>$null) -join '') | Should -BeExactly $script:SeedHead -Because 'exactly one commit'
        Test-StoreHasFile $script:Migrated 'test-sets.yml' | Should -BeFalse
        $doc = Get-StorePoolDocument $script:Migrated
        $doc['schemaVersion'] | Should -Be 3
        $lab = Get-FixturePool $doc 'lab'
        $lab['repositories']['projectUrl'] | Should -BeExactly $script:Proj
        $lab.Contains('testSet') | Should -BeFalse
        # A target pool that carried a pair keeps it: the migration never
        # decides what a lab runs. Test-PoolIntent.ps1 reports it instead.
        (Get-FixturePool $doc 'default').Contains('repositories') | Should -BeTrue
    }
    It 'reports a second run as already current and commits nothing' {
        $before = Get-StoreHead $script:Migrated
        $run = Invoke-PoolCli 'Update-PoolIntentSchema.ps1' @('-IntentGitUrl', $script:Migrated.Store, '-IntentDir', $script:Migrated.Clone)
        $run.Code | Should -Be 0
        Get-StoreHead $script:Migrated | Should -BeExactly $before
    }
    It 'removes a leftover test-sets.yml from a v3 store under its own commit subject' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument -LabRepositories) -Library $script:Library
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Update-PoolIntentSchema.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        Get-StoreSubject $f | Should -BeExactly 'pool: remove test-sets.yml' -Because 'the version did not move'
        ((& git -C $f.Store rev-parse 'main~1' 2>$null) -join '') | Should -BeExactly $before -Because 'exactly one commit'
        Test-StoreHasFile $f 'test-sets.yml' | Should -BeFalse
        $doc = Get-StorePoolDocument $f
        $doc['schemaVersion'] | Should -Be 3
        (Get-FixturePool $doc 'lab')['repositories']['projectUrl'] | Should -BeExactly 'https://example.invalid/old-project.git'
    }
    It 'refuses a store at a newer schemaVersion' {
        $doc = Get-V3PoolDocument
        $doc['schemaVersion'] = 4
        $f = New-PoolStoreFixture -Pools $doc
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Update-PoolIntentSchema.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Not -Be 0
        Get-StoreHead $f | Should -BeExactly $before
    }
}

Describe 'Test-PoolIntent.ps1 judges pools.yml as stored' {
    It 'reports a v2 store once, as a schema-version failure' {
        $f = New-PoolStoreFixture -Pools (Get-V2PoolDocument)
        $run = Invoke-PoolCli 'Test-PoolIntent.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Not -Be 0
        $run.Text | Should -Match 'schema-version'
        $run.Text | Should -Match 'Update-PoolIntentSchema\.ps1'
        $run.Text | Should -Not -Match 'target-pool-no-repositories' -Because 'the v3 target-pool rule is not judged on a v2 store'
    }
    It 'fails repositories on the auto-enrollment target pool, and passes once they are cleared' {
        $f = New-PoolStoreFixture -Pools (Get-V3PoolDocument -TargetRepositories)
        $run = Invoke-PoolCli 'Test-PoolIntent.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Not -Be 0
        $run.Text | Should -Match 'target-pool-no-repositories'
        $cleared = Invoke-PoolCli 'Set-PoolRepository.ps1' @('-PoolId', 'default', '-Clear', '-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $cleared.Code | Should -Be 0
        $again = Invoke-PoolCli 'Test-PoolIntent.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $again.Code | Should -Be 0
        $again.Text | Should -Match 'target-pool-no-repositories'
    }
}

Describe 'Get-PoolIntent.ps1 emits the v3 shape' {
    It 'shows a v2 store''s pairs as repositories, with no library and the auto-enrollment policy' {
        $f = New-PoolStoreFixture -Pools (Get-V2PoolDocument) -Library $script:Library
        $before = Get-StoreHead $f
        $run = Invoke-PoolCli 'Get-PoolIntent.ps1' @('-IntentGitUrl', $f.Store, '-IntentDir', $f.Clone)
        $run.Code | Should -Be 0
        $json = $run.Text | ConvertFrom-Json -AsHashtable
        $json['ok'] | Should -BeTrue
        $json.ContainsKey('testSets') | Should -BeFalse
        $json['autoEnrollment']['targetPoolId'] | Should -BeExactly 'default'
        $lab = @($json['pools'] | Where-Object { $_['poolId'] -ceq 'lab' })[0]
        $lab['repositories']['frameworkUrl'] | Should -BeExactly $script:Fw
        $lab.ContainsKey('testSet') | Should -BeFalse
        Get-StoreHead $f | Should -BeExactly $before -Because 'a read never writes the store'
    }
}
