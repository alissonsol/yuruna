<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4258b834-1062-42d9-98d6-f3e2b1ac55f0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -Version 7
BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Driver = Join-Path $script:Root 'tools/Initialize-GitMirrorNativeInstall.ps1'
    $script:Recipes = (Get-Content (Join-Path $script:Root 'test/fixtures/git-mirror/native-install-recipes.json') -Raw | ConvertFrom-Json -AsHashtable).recipes
    function Invoke-NativeInstallFixture {
        param([string]$Action = 'Prepare', [string]$Mode = 'Main', [switch]$WithoutConsent, [string[]]$ExtraArguments = @())
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $script:CopiedDriver, '-Action', $Action,
            '-Mode', $Mode, '-TargetRoot', $script:Target, '-OldRoot', $script:Old, '-StatePath', $script:State,
            '-RuntimeDir', (Join-Path $script:State runtime), '-ConfigPath', $script:Config,
            '-ConfigSourcePath', $script:ConfigSource)
        if (-not $WithoutConsent) { $arguments += '-DisposableTarget' }
        $arguments += $ExtraArguments
        $output = & (Get-Process -Id $PID).Path @arguments 2>&1 | Out-String
        return @{ ExitCode=$LASTEXITCODE; Output=$output }
    }
    function Initialize-LifecycleModuleFixture {
        $modules = Join-Path $script:Candidate 'test/modules'
        $null = New-Item -ItemType Directory -Path $modules, (Join-Path $script:Candidate automation) -Force
        foreach ($name in @('Test.SingleInstance', 'Test.StateFile', 'Test.SingleFlightLock', 'Test.CriticalRecord',
                'Test.InnerSpawn', 'Test.ConfigSync', 'Test.ConfigNaming', 'Test.Catalog', 'Test.Locale')) {
            Copy-Item (Join-Path $script:Root "test/modules/$name.psm1") $modules
        }
        foreach ($name in @('Yuruna.Common', 'Yuruna.Globalization')) {
            Copy-Item (Join-Path $script:Root "automation/$name.psm1") (Join-Path $script:Candidate automation)
        }
        $globalization = Join-Path $script:Candidate globalization
        $null = New-Item -ItemType Directory -Path $globalization, (Join-Path $globalization manifests), (Join-Path $globalization generated) -Force
        Copy-Item (Join-Path $script:Root 'globalization/locale-manifest.json') $globalization
        Copy-Item (Join-Path $script:Root 'globalization/manifests/catalog-set.json') (Join-Path $globalization manifests)
        Copy-Item (Join-Path $script:Root 'globalization/generated/powershell') (Join-Path $globalization generated) -Recurse
        Copy-Item (Join-Path $script:Root 'test/test.config.yml.template') (Join-Path $script:Target 'test/test.config.yml.template')
    }
}

Describe 'Native installer fixture preparation' {
    BeforeEach {
        $script:Fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Candidate = Join-Path $script:Fixture candidate
        $script:Old = Join-Path $script:Fixture old
        $script:Target = Join-Path $script:Fixture target
        $script:State = Join-Path $script:Fixture state
        $script:Config = Join-Path $script:Target 'test/operator.config.yml'
        $script:ConfigSource = Join-Path $script:Fixture operator.yml
        $null = New-Item -ItemType Directory -Path $script:Candidate, $script:Old, $script:Target, $script:State,
            (Join-Path $script:Candidate tools), (Join-Path $script:Candidate 'test/fixtures/git-mirror') -Force
        $script:CopiedDriver = Join-Path $script:Candidate 'tools/Initialize-GitMirrorNativeInstall.ps1'
        Copy-Item $script:Driver $script:CopiedDriver
        & git init -q $script:Old
        & git -C $script:Old -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
        if ($LASTEXITCODE) { throw 'Could not create native installer Git fixture.' }
        $script:OldCommit = ([string](& git -C $script:Old rev-parse HEAD)).Trim()
        # The driver is unchanged; a disposable candidate contract binds its
        # disposable old source, avoiding downloads in the ordinary test suite.
        @{ schema='yuruna.git-mirror.public-fixture/v1'; release='fixture'; commit=$script:OldCommit } |
            ConvertTo-Json | Set-Content (Join-Path $script:Candidate 'test/fixtures/git-mirror/public-2026.10.18.2.json')
        @{ schema='yuruna.git-mirror.disposable-target/v1'; targetRoot=$script:Target } |
            ConvertTo-Json | Set-Content (Join-Path $script:State disposable-target.json)
        [IO.File]::WriteAllText($script:ConfigSource, "repositories:`n  projectUrl: file:///operator/project`nlogLevel: Warning`n")
    }

    It 'prepares exact old main with the non-default selected config and canonical upstream' {
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Be 0 -Because $result.Output
        ([string](& git -C $script:Target rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        ([string](& git -C $script:Target branch --show-current)).Trim() | Should -BeExactly main
        ([string](& git -C $script:Target config branch.main.merge)).Trim() | Should -BeExactly refs/heads/main
        ([string](& git -C $script:Target remote get-url origin)).Trim() | Should -BeExactly https://github.com/alissonsol/yuruna.git
        (Get-Content $script:Config -Raw) | Should -BeExactly (Get-Content $script:ConfigSource -Raw)
        ([string](& git -C $script:Old rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
    }
    It 'prepares a real detached public pin' {
        $result = Invoke-NativeInstallFixture -Mode Pin
        $result.ExitCode | Should -Be 0 -Because $result.Output
        ([string](& git -C $script:Target rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        & git -C $script:Target symbolic-ref -q HEAD | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
    It 'holds the controlled origin at the old commit until the explicit advance to the frozen candidate' {
        $prepared = Invoke-NativeInstallFixture -ExtraArguments '-AutomaticOrigin'
        $prepared.ExitCode | Should -Be 0 -Because $prepared.Output
        $controlled = Join-Path $script:State adoption-origin.git
        ([string](& git -C $controlled rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        $upstream = Join-Path $script:Fixture prepared-upstream
        & git clone -q $script:Old $upstream
        & git -C $upstream checkout -q -B main
        [IO.File]::WriteAllText((Join-Path $upstream VERSION), "prepared`n")
        & git -C $upstream add VERSION
        & git -C $upstream -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm prepared
        if ($LASTEXITCODE) { throw 'Could not advance the disposable candidate.' }
        $candidate = ([string](& git -C $upstream rev-parse HEAD)).Trim()
        $tree = ([string](& git -C $upstream rev-parse 'HEAD^{tree}')).Trim()
        $previousCount = $env:GIT_CONFIG_COUNT
        $index = if ($previousCount) { [int]$previousCount } else { 0 }
        $keyName = "GIT_CONFIG_KEY_$index"
        $valueName = "GIT_CONFIG_VALUE_$index"
        $previousKey = [Environment]::GetEnvironmentVariable($keyName)
        $previousValue = [Environment]::GetEnvironmentVariable($valueName)
        try {
            [Environment]::SetEnvironmentVariable($keyName, "url.$([uri]::new($upstream).AbsoluteUri).insteadOf")
            [Environment]::SetEnvironmentVariable($valueName, 'https://github.com/alissonsol/yuruna.git')
            $env:GIT_CONFIG_COUNT = [string]($index + 1)
            $advanced = Invoke-NativeInstallFixture -Action AdvanceOrigin -ExtraArguments @('-CandidateTree', $tree)
            $advanced.ExitCode | Should -Be 0 -Because $advanced.Output
        } finally {
            $env:GIT_CONFIG_COUNT = $previousCount
            [Environment]::SetEnvironmentVariable($keyName, $previousKey)
            [Environment]::SetEnvironmentVariable($valueName, $previousValue)
        }
        ([string](& git -C $controlled rev-parse refs/heads/main)).Trim() | Should -BeExactly $candidate
        ([string](& git -C $script:Target rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        ([string](& git -C $script:Old rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        $record = Get-Content (Join-Path $script:State advance.json) -Raw | ConvertFrom-Json -AsHashtable
        $record.candidateTree | Should -BeExactly $tree
        $record.candidateCommit | Should -BeExactly $candidate
    }
    It 'leaves a fresh target empty for the signed installer' {
        $script:Config = Join-Path $script:Target 'test/test.config.yml'
        $result = Invoke-NativeInstallFixture -Mode Fresh
        $result.ExitCode | Should -Be 0 -Because $result.Output
        @(Get-ChildItem $script:Target -Force).Count | Should -Be 0
        Test-Path (Join-Path $script:State runtime) | Should -BeTrue
    }
    It 'forces the actual non-fast-forward path with a target-only local commit' {
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        $result = Invoke-NativeInstallFixture -Action Diverge
        $result.ExitCode | Should -Be 0 -Because $result.Output
        ([string](& git -C $script:Target rev-parse HEAD)).Trim() | Should -Not -BeExactly $script:OldCommit
        ([string](& git -C $script:Target rev-parse HEAD^)).Trim() | Should -BeExactly $script:OldCommit
        ([string](& git -C $script:Old rev-parse HEAD)).Trim() | Should -BeExactly $script:OldCommit
        Test-Path (Join-Path $script:Old qualification-local-change.txt) | Should -BeFalse
    }
    It 'refuses a nonempty target without removing existing work' {
        $sentinel = Join-Path $script:Target operator.txt
        [IO.File]::WriteAllText($sentinel, 'keep')
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'empty disposable target'
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly keep
    }
    It 'requires the explicit consent switch even with a valid marker' {
        $result = Invoke-NativeInstallFixture -WithoutConsent
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'requires -DisposableTarget'
        @(Get-ChildItem $script:Target -Force).Count | Should -Be 0
    }
    It 'refuses a marker naming another target' {
        @{ schema='yuruna.git-mirror.disposable-target/v1'; targetRoot=$script:Old } |
            ConvertTo-Json | Set-Content (Join-Path $script:State disposable-target.json)
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'marker does not match'
        @(Get-ChildItem $script:Target -Force).Count | Should -Be 0
    }
    It 'refuses protected source and configuration paths' {
        $script:Config = Join-Path $script:Old test.config.yml
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'configuration must belong'
        Test-Path $script:Config | Should -BeFalse
    }
    It 'rejects an old checkout that differs from the frozen fixture commit' {
        & git -C $script:Old -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm changed
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'not the frozen public fixture'
        @(Get-ChildItem $script:Target -Force).Count | Should -Be 0
    }
    It 'requires a non-default operator value for the preservation observation' {
        [IO.File]::WriteAllText($script:ConfigSource, "repositories:`n  projectUrl: https://github.com/alissonsol/yuruna-project.git`n")
        $result = Invoke-NativeInstallFixture
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'non-default operator project URL'
        @(Get-ChildItem $script:Target -Force).Count | Should -Be 0
    }
    It 'measures the actual repository identity and flags a recovery checkout' {
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        Initialize-LifecycleModuleFixture
        $observed = Invoke-NativeInstallFixture -Action Observe
        $observed.ExitCode | Should -Be 0 -Because $observed.Output
        $first = Get-Content (Join-Path $script:State observed.json) -Raw | ConvertFrom-Json -AsHashtable
        $first.repositoryIdentityPreserved | Should -BeTrue
        $first.noRecoveryCheckout | Should -BeTrue
        $first.runnerAlive | Should -BeFalse
        & git -C $script:Target remote set-url origin file:///changed/operator
        $null = New-Item -ItemType Directory -Path ($script:Target + '.backup.fixture')
        $observed = Invoke-NativeInstallFixture -Action Observe
        $observed.ExitCode | Should -Be 0 -Because $observed.Output
        $second = Get-Content (Join-Path $script:State observed.json) -Raw | ConvertFrom-Json -AsHashtable
        $second.repositoryIdentityPreserved | Should -BeFalse
        $second.noRecoveryCheckout | Should -BeFalse
        $second.recoveryCheckoutCount | Should -Be 1
    }
    It 'detects a changed operator value against a production configuration snapshot' {
        $script:Config = Join-Path $script:Target 'test/test.config.yml'
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        Initialize-LifecycleModuleFixture
        Import-Module (Join-Path $script:Root 'test/modules/Test.SingleInstance.psm1') -DisableNameChecking
        $snapshot = Join-Path $script:State 'capture/state.json'
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $script:Target `
            -RuntimeDir (Join-Path $script:State runtime) -PrivateRoot (Join-Path $script:State private) -SnapshotPath $snapshot
        $first = Invoke-NativeInstallFixture -Action Observe -ExtraArguments @('-SnapshotPath', $snapshot)
        $first.ExitCode | Should -Be 0 -Because $first.Output
        (Get-Content (Join-Path $script:State observed.json) -Raw | ConvertFrom-Json).configurationValuesPreserved | Should -BeTrue
        [IO.File]::WriteAllText($script:Config, ([IO.File]::ReadAllText($script:Config).Replace('logLevel: Warning', 'logLevel: Error')))
        $second = Invoke-NativeInstallFixture -Action Observe -ExtraArguments @('-SnapshotPath', $snapshot)
        $second.ExitCode | Should -Be 0 -Because $second.Output
        (Get-Content (Join-Path $script:State observed.json) -Raw | ConvertFrom-Json).configurationValuesPreserved | Should -BeFalse
    }
    It 'enrolls a validated provisioning export with a prior-value report and preserves operator values' {
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        Initialize-LifecycleModuleFixture
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try { $public = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) } finally { $rsa.Dispose() }
        Import-Module (Join-Path $script:Root 'test/modules/Test.ConfigSync.psm1') -DisableNameChecking
        $keyId = Get-ConfigMirrorKeyId -Value $public
        $export = Join-Path $script:State export.json
        @{publicKey=$public; keyId=$keyId} | ConvertTo-Json | Set-Content $export
        $before = Get-Content $script:Config -Raw
        $result = Invoke-NativeInstallFixture -Action Enroll -ExtraArguments @('-MirrorKeyExportPath', $export, '-MirrorUrl', 'http://127.0.0.1:8765', '-MirrorMode', 'fallback')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'repositories.mirror.verificationPublicKeys:.* -> '
        $current = Get-Content $script:Config -Raw | ConvertFrom-Yaml
        $current.repositories.projectUrl | Should -BeExactly file:///operator/project
        $current.logLevel | Should -BeExactly Warning
        $current.repositories.mirror.mode | Should -BeExactly fallback
        @($current.repositories.mirror.verificationPublicKeys) | Should -Contain $public
        $backup = @(Get-ChildItem $script:State -Filter enrollment-*.yml)
        $backup.Count | Should -Be 1
        (Get-Content $backup[0].FullName -Raw) | Should -BeExactly $before
        $record = Get-Content (Join-Path $script:State enrollment.json) -Raw | ConvertFrom-Json -AsHashtable
        $record.keyId | Should -BeExactly $keyId
        $record.keyEnrolled | Should -BeTrue
        $record.operatorValuesPreserved | Should -BeTrue
        # Reports expose fingerprints, never the raw key or unrelated config.
        (Get-Content (Join-Path $script:State enrollment.json) -Raw) | Should -Not -Match ([regex]::Escape($public))
    }
    It 'rejects a mismatched export without rewriting the selected config' {
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        Initialize-LifecycleModuleFixture
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try { $public = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) } finally { $rsa.Dispose() }
        $export = Join-Path $script:State export.json
        @{publicKey=$public; keyId=('0' * 64)} | ConvertTo-Json | Set-Content $export
        $before = Get-FileHash $script:Config
        $result = Invoke-NativeInstallFixture -Action Enroll -ExtraArguments @('-MirrorKeyExportPath', $export, '-MirrorUrl', 'http://127.0.0.1:8765')
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'fingerprint is invalid'
        (Get-FileHash $script:Config).Hash | Should -BeExactly $before.Hash
        Test-Path (Join-Path $script:State enrollment.json) | Should -BeFalse
    }
    It 'refuses to manufacture clean-stop evidence when there is no real runner' {
        (Invoke-NativeInstallFixture).ExitCode | Should -Be 0
        Initialize-LifecycleModuleFixture
        $result = Invoke-NativeInstallFixture -Action Drain -ExtraArguments @('-SnapshotPath', (Join-Path $script:State clean-state.json))
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'live production runner'
        Test-Path (Join-Path $script:State clean-stop.json) | Should -BeFalse
        Test-Path (Join-Path $script:State clean-state.json) | Should -BeFalse
    }
}

Describe 'Frozen native install recipes' {
    It 'covers every required installer upgrade, setup, rollback and Aqua platform row exactly once' {
        $contract = Get-Content (Join-Path $script:Root 'test/fixtures/git-mirror/qualification-contract.json') -Raw | ConvertFrom-Json -AsHashtable
        $required = @($contract.rows | Where-Object { $_.id -match '^GM-UPG-|^GM-FRESH-SETUP-|^GM-ROLLBACK$|^GM-UTM-AQUA$' })
        $script:Recipes.Count | Should -Be $required.Count
        foreach ($row in $required) {
            @($script:Recipes | Where-Object { $_.id -ceq $row.id -and $_.platform -ceq $row.platform }).Count | Should -Be 1
        }
    }
    It 'uses the resident old runner and real updater before the target refresh on public main' {
        foreach ($recipe in $script:Recipes | Where-Object id -EQ GM-UPG-PUBLIC-MAIN) {
            $resident = @($recipe.commands | Where-Object { $_.ContainsKey('background') -and $_.background })
            $resident.Count | Should -Be 1
            $resident[0].source | Should -Be target
            $resident[0].stage | Should -Be setup
            $resident[0].arguments | Should -Not -Contain '-NoGitPull'
            $resident[0].frameworkOriginPath | Should -Be '${StatePath}/adoption-origin.git'
            $update = @($recipe.commands | Where-Object { $_.arguments -contains 'AdvanceOrigin' })
            $update.Count | Should -Be 1
            $wait = @($recipe.commands | Where-Object { $_.arguments -contains 'WaitAdoption' })
            $wait.Count | Should -Be 1
            [array]::IndexOf($recipe.commands, $update[0]) | Should -BeLessThan ([array]::IndexOf($recipe.commands, $wait[0]))
            @($recipe.commands | Where-Object { $_.source -ceq 'target' -and $_.path -ceq 'test/lab/Invoke-HostRefresh.ps1' -and $_.arguments -contains '-Force' }).Count | Should -Be 1
            @($recipe.observations | Where-Object kind -EQ process-replaced).Count | Should -Be 1
        }
    }
    It 'invokes signed installers and preserves stopped-runner evidence before explicit activation' {
        foreach ($recipe in $script:Recipes | Where-Object id -EQ GM-UPG-STOPPED-RUNNER) {
            @($recipe.commands | Where-Object source -EQ installer).Count | Should -Be 1
            $stopped = @($recipe.commands | Where-Object { $_.arguments -contains '-ExpectStopped' })[0]
            $start = @($recipe.commands | Where-Object path -EQ test/lab/Start-RecordedTestRunner.ps1)[0]
            [array]::IndexOf($recipe.commands, $stopped) | Should -BeLessThan ([array]::IndexOf($recipe.commands, $start))
            @($recipe.observations | Where-Object { $_.property -eq 'runnerAlive' -and $_.expected -eq $false }).Count | Should -Be 1
            $drain = @($recipe.commands | Where-Object { $_.arguments -contains 'Drain' })[0]
            $verify = @($recipe.commands | Where-Object { $_.arguments -contains 'VerifyCleanStop' })[0]
            [array]::IndexOf($recipe.commands, $drain) | Should -BeLessThan ([array]::IndexOf($recipe.commands, $verify))
            @($recipe.observations | Where-Object property -EQ cleanExitPreserved).Count | Should -Be 1
        }
    }
    It 'requires real old and new installed gates and explicit re-enrollment for rollback' {
        foreach ($recipe in $script:Recipes | Where-Object id -EQ GM-ROLLBACK) {
            @($recipe.commands | Where-Object source -EQ installer).Count | Should -Be 3
            @($recipe.commands | Where-Object { $_.arguments -contains 'OldRollback' }).Count | Should -Be 1
            @($recipe.commands | Where-Object { $_.arguments -contains 'NewRollback' }).Count | Should -Be 1
            @($recipe.commands | Where-Object { $_.arguments -contains 'Enroll' }).Count | Should -Be 2
            @($recipe.observations | Where-Object { $_.expected -is [string] -and $_.expected -ceq 'mirror-untrusted' }).Count | Should -Be 1
        }
    }
    It 'keeps incomplete native observations ineligible for qualification' {
        foreach ($recipe in $script:Recipes | Where-Object { $_.id -like 'GM-FRESH-SETUP-*' -or $_.id -eq 'GM-UPG-RECLONE-PRESERVE' }) {
            $recipe.coverage | Should -BeExactly diagnostic-only
            $recipe.remaining | Should -Not -BeNullOrEmpty
        }
    }
    It 'contains no bypassed configuration gate or clean-exit manipulation' {
        foreach ($recipe in $script:Recipes) {
            foreach ($command in $recipe.commands) {
                $command.arguments | Should -Not -Contain '-NoConfigGate'
                $command.arguments | Should -Not -Contain '-SkipPreflight'
                ($command | ConvertTo-Json -Depth 6) | Should -Not -Match 'cleanExit|RefreshHandoffToken|SSH_CONNECTION'
            }
        }
    }
    It 'cleans up replacements through the same marked disposable target' {
        foreach ($recipe in $script:Recipes) {
            @($recipe.cleanupCommands).Count | Should -Be 1
            $recipe.cleanupCommands[0].arguments | Should -Contain StopFixture
            $recipe.cleanupCommands[0].arguments | Should -Contain '-DisposableTarget'
            $recipe.cleanupCommands[0].arguments | Should -Contain '${TargetRoot}'
        }
    }
}
