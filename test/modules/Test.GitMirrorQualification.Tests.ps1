<#PSScriptInfo
.VERSION 2026.10.22
.GUID 421020da-84c1-40cb-8831-6d1e4c24a63f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepositoryRoot 'tools/GitMirror.Qualification.psm1') -Force
    $script:Framework = Join-Path $TestDrive framework
    $script:Project = Join-Path $TestDrive project
    foreach ($root in @($script:Framework, $script:Project)) {
        $null = New-Item -ItemType Directory -Path $root
        & git -C $root init --quiet --initial-branch=main
        if ($LASTEXITCODE) { throw 'Could not create candidate fixture.' }
    }
    foreach ($relative in @(
            'test/fixtures/git-mirror/qualification-contract.json',
            'test/fixtures/git-mirror/public-2026.10.18.2.json',
            'test/fixtures/git-mirror/native-service-recipes.json',
            'tools/GitMirror.Qualification.psm1', 'tools/Invoke-GitMirrorQualification.ps1',
            'tools/GitMirror.NativeQualification.psm1', 'tools/Invoke-GitMirrorNativeQualification.ps1',
            'tools/Test-GitMirrorNativeService.ps1',
            'tools/Invoke-GitMirrorNativeWorker.ps1', 'tools/git_mirror_native_worker.py',
            'tools/Initialize-GitMirrorNativeInstall.ps1',
            'tools/Invoke-GitMirrorNativeRoute.ps1', 'tools/Invoke-GitMirrorNativeGuest.ps1',
            'tools/Invoke-GitMirrorNativeOutage.ps1', 'tools/git_mirror_outage_fixture.py',
            'tools/Invoke-GitMirrorNativeOrigins.ps1', 'tools/git_mirror_native_origins.py',
            'tools/Invoke-GitMirrorNativeProvision.ps1', 'tools/git_mirror_native_rotation.py',
            'tools/Test-GitMirrorQualification.ps1', 'tools/git_mirror_http_fixture.py', 'host/vmconfig/caching-proxy-service.base.user-data',
            'test/modules/Test.HostGit.psm1', 'test/extension/caching-proxy-service/gitmirror.go',
            'install/ubuntu.kvm.sh', 'install/macos.utm.sh', 'install/windows.hyper-v.ps1',
            'install/install.sha256', 'install/install.sha256.sig')) {
        $destination = Join-Path $script:Framework $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $destination
    }
    $contractFixture = Get-Content -Raw (Join-Path $script:Framework 'test/fixtures/git-mirror/qualification-contract.json') | ConvertFrom-Json -AsHashtable
    $contractFixture.nativeRecipePaths = @('test/fixtures/git-mirror/native-service-recipes.json')
    [IO.File]::WriteAllText((Join-Path $script:Framework 'test/fixtures/git-mirror/qualification-contract.json'), ($contractFixture | ConvertTo-Json -Depth 20))
    $recipeFixture = @{
        schema = 'yuruna.git-mirror.native-recipes/v1'
        recipes = @($contractFixture.rows | ForEach-Object {
                @{ id = $_.id; platform = $_.platform
                    commands = @(@{ source = 'candidate'; path = 'disposable-fixture.ps1'; arguments = @(); timeoutSeconds = 1 })
                    observations = @(@{ name = 'measuredFixture'; kind = 'json'; path = 'fixture.json'; property = 'passed'; expected = $true })
                }
                })
    }
    [IO.File]::WriteAllText((Join-Path $script:Framework 'test/fixtures/git-mirror/native-service-recipes.json'), ($recipeFixture | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllText((Join-Path $script:Project 'project.txt'), 'candidate project')
    foreach ($root in @($script:Framework, $script:Project)) {
        & git -C $root add .
        if ($LASTEXITCODE) { throw 'Could not stage candidate fixture.' }
    }
    $script:IdentityArguments = @{
        FrameworkRoot = $script:Framework; ProjectRoot = $script:Project
        SourceFrameworkCommit = ('a' * 40); SourceProjectCommit = ('b' * 40)
    }
    $script:ManifestPath = Join-Path $TestDrive candidate.json
    $script:Candidate = New-GitMirrorCandidate @script:IdentityArguments -OutputPath $script:ManifestPath
    $script:Contract = Get-GitMirrorQualificationContract -FrameworkRoot $script:Framework
    $script:ArtifactPath = Join-Path $TestDrive native.log
    [IO.File]::WriteAllText($script:ArtifactPath, 'Disposable validator fixture, not live qualification.')
    $script:ArtifactHash = (Get-FileHash $script:ArtifactPath).Hash.ToLowerInvariant()
    foreach ($row in $script:Contract.rows) {
        $recipe = $script:Contract.nativeRecipes | Where-Object { $_.id -ceq $row.id -and $_.platform -ceq $row.platform }
        $execution = @{
            schema = 'yuruna.git-mirror.native-execution/v1'; candidateId = $script:Candidate.candidateId
            id = $row.id; platform = $row.platform; recipeHash = Get-GitMirrorJsonHash $recipe; failure = ''; durationSeconds = 361
            commands = @(@{ source = 'candidate'; path = 'disposable-fixture.ps1'; sourceHash = 'a' * 64; timedOut = $false; exitCode = 0
                    commandHash = Get-GitMirrorJsonHash $recipe.commands[0]
                    stdoutSha256 = $script:ArtifactHash; stderrSha256 = $script:ArtifactHash })
            observations = @(@{ name = 'measuredFixture'; kind = 'json'; passed = $true; after = @{ value = $true } })
        }
        [IO.File]::WriteAllText((Join-Path $TestDrive "$($row.id)-$($row.platform).json"), ($execution | ConvertTo-Json -Depth 20))
    }
    function New-QualificationEvidenceFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates only an in-memory disposable evidence object.')]
        param()
        $identity = $script:Candidate.identity | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        return @{
            schema = 'yuruna.git-mirror.qualification/v1'
            candidateId = $script:Candidate.candidateId
            identity = $identity
            rows = @($script:Contract.rows | ForEach-Object {
                    $path = "$($_.id)-$($_.platform).json"
                    $hash = (Get-FileHash (Join-Path $TestDrive $path)).Hash.ToLowerInvariant()
                    @{ id = $_.id; platform = $_.platform; phase = $_.phase; result = 'pass'
                        sessionKind = 'Aqua'; refreshVerdict = 'restarted'; durationSeconds = 361
                        executionSha256 = $hash
                        artifacts = @(@{ path = 'native.log'; sha256 = $script:ArtifactHash }, @{ path = $path; sha256 = $hash }) }
                })
        }
    }
    function Test-EvidenceFixture {
        param([hashtable]$Evidence)
        Test-GitMirrorQualificationEvidence -Candidate $script:Candidate -Contract $script:Contract `
            -Evidence $Evidence -EvidenceDirectory $TestDrive
    }
}

Describe 'Git mirror qualification binds the final candidate and every required native row' {
    It 'has one executable catalog recipe for every required native platform row' {
        $actual = Get-GitMirrorQualificationContract $script:RepositoryRoot
        foreach ($row in $actual.rows) {
            $matching = @($actual.nativeRecipes | Where-Object {
                    $_.id -ceq $row.id -and $_.platform -in @('*', $row.platform)
                })
            $matching.Count | Should -Be 1 -Because "$($row.id)/$($row.platform) requires one frozen recipe"
            @($matching[0].commands).Count | Should -BeGreaterThan 0
            @($matching[0].observations).Count | Should -BeGreaterThan 0
        }
    }

    It 'freezes healthy prepared origins and their cleanup only for the provision rows that use the existing proxy' {
        $actual = Get-GitMirrorQualificationContract $script:RepositoryRoot
        foreach ($id in @('GM-FRESH-LAB-JOIN', 'GM-ROTATE-KEY')) {
            $recipe = $actual.nativeRecipes | Where-Object id -CEQ $id
            $recipe.commands[0].path | Should -BeExactly 'tools/Invoke-GitMirrorNativeOrigins.ps1'
            $recipe.commands[0].stage | Should -BeExactly setup
            $recipe.cleanupCommands[-1].arguments | Should -Contain Restore
        }
        foreach ($id in @('GM-PROXY-OWNER-FIRST', 'GM-PROXY-OLD-CHECKOUT', 'GM-PROXY-NO-STATUS-SERVICE')) {
            $recipe = $actual.nativeRecipes | Where-Object id -CEQ $id
            @($recipe.commands | Where-Object path -CEQ 'tools/Invoke-GitMirrorNativeOrigins.ps1').Count | Should -Be 0
        }
    }

    It 'keeps source fingerprints identical across native process cultures' {
        $previous = [Globalization.CultureInfo]::CurrentCulture
        try {
            $value = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($key in @('Z', 'a', 'A', 'i', 'I', [string][char]0x131, [string][char]0x130)) { $value[$key] = $key }
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
            $first = Get-GitMirrorJsonHash $value
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Get-GitMirrorJsonHash $value | Should -BeExactly $first
        } finally { [Globalization.CultureInfo]::CurrentCulture = $previous }
    }

    It 'freezes the prepared staged trees and installer artifacts without a commit' {
        $script:Candidate.status | Should -Be 'prepared-not-qualified'
        $script:Candidate.artifacts.Count | Should -Be 7
        (Test-GitMirrorCandidate @script:IdentityArguments -CandidateManifestPath $script:ManifestPath).candidateId |
            Should -Be $script:Candidate.candidateId
    }

    It 'refuses source identities changed after preparation' {
        $parameters = $script:IdentityArguments.Clone()
        $parameters.SourceFrameworkCommit = 'c' * 40
        { Test-GitMirrorCandidate @parameters -CandidateManifestPath $script:ManifestPath } | Should -Throw '*current inputs*'
    }

    It 'refuses a changed frozen artifact and does not overwrite it on preparation retry' {
        $file = Join-Path $TestDrive $script:Candidate.artifacts[0].path
        $saved = [IO.File]::ReadAllBytes($file)
        try {
            [IO.File]::WriteAllText($file, 'altered')
            { New-GitMirrorCandidate @script:IdentityArguments -OutputPath $script:ManifestPath } | Should -Throw '*artifact changed*'
            [IO.File]::ReadAllText($file) | Should -Be 'altered'
        } finally { [IO.File]::WriteAllBytes($file, $saved) }
    }

    It 'refuses substituted installer bytes even when the saved artifact hashes are recomputed' {
        $manifest = Get-Content -Raw $script:ManifestPath | ConvertFrom-Json -AsHashtable
        $artifact = $manifest.artifacts | Where-Object { $_.path.EndsWith('/ubuntu.kvm.sh') }
        $file = Join-Path $TestDrive $artifact.path
        $saved = [IO.File]::ReadAllBytes($file)
        try {
            [IO.File]::WriteAllText($file, 'substituted installer')
            $artifact.sha256 = (Get-FileHash $file).Hash.ToLowerInvariant()
            $manifest.candidateId = Get-GitMirrorJsonHash ([ordered]@{ identity = $manifest.identity; artifacts = $manifest.artifacts })
            $altered = Join-Path $TestDrive altered.json
            [IO.File]::WriteAllText($altered, ($manifest | ConvertTo-Json -Depth 30))
            { Test-GitMirrorCandidate @script:IdentityArguments -CandidateManifestPath $altered } | Should -Throw '*staged installer*'
        } finally { [IO.File]::WriteAllBytes($file, $saved) }
    }

    It 'refuses substituted archive contents even when the saved artifact hashes are recomputed' {
        $manifest = Get-Content -Raw $script:ManifestPath | ConvertFrom-Json -AsHashtable
        $artifact = $manifest.artifacts | Where-Object { $_.path.EndsWith('/project.tar') }
        $file = Join-Path $TestDrive $artifact.path
        $saved = [IO.File]::ReadAllBytes($file)
        try {
            $frameworkArchive = $manifest.artifacts | Where-Object { $_.path.EndsWith('/framework.tar') }
            Copy-Item -LiteralPath (Join-Path $TestDrive $frameworkArchive.path) -Destination $file -Force
            $artifact.sha256 = (Get-FileHash $file).Hash.ToLowerInvariant()
            $manifest.candidateId = Get-GitMirrorJsonHash ([ordered]@{ identity = $manifest.identity; artifacts = $manifest.artifacts })
            $altered = Join-Path $TestDrive altered-archive.json
            [IO.File]::WriteAllText($altered, ($manifest | ConvertTo-Json -Depth 30))
            { Test-GitMirrorCandidate @script:IdentityArguments -CandidateManifestPath $altered } | Should -Throw '*Archive*'
        } finally { [IO.File]::WriteAllBytes($file, $saved) }
    }

    It 'accepts complete disposable evidence for exactly the independent candidate' {
        (Test-EvidenceFixture (New-QualificationEvidenceFixture)).status | Should -Be 'qualified'
    }

    It 'refuses caller-authored pass rows without measured native execution records' {
        $evidence = New-QualificationEvidenceFixture
        $evidence.rows[0].Remove('executionSha256')
        { Test-EvidenceFixture $evidence } | Should -Throw '*execution*'
    }

    It 'checks measured <Field> even when an execution artifact claims a pass and is rehashed' -ForEach @(
        @{ Field = 'duration' }, @{ Field = 'observation' }
    ) {
        $evidence = New-QualificationEvidenceFixture
        $artifact = $evidence.rows[0].artifacts[1]
        $path = Join-Path $TestDrive $artifact.path
        $saved = [IO.File]::ReadAllBytes($path)
        try {
            $execution = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
            if ($Field -ceq 'duration') { $execution.durationSeconds = 1 }
            else { $execution.observations[0].after.value = $false }
            [IO.File]::WriteAllText($path, ($execution | ConvertTo-Json -Depth 20))
            $artifact.sha256 = (Get-FileHash $path).Hash.ToLowerInvariant()
            $evidence.rows[0].executionSha256 = $artifact.sha256
            { Test-EvidenceFixture $evidence } | Should -Throw '*execution*'
        } finally { [IO.File]::WriteAllBytes($path, $saved) }
    }

    It 'rejects <Mutation> evidence' -ForEach @(
        @{ Mutation = 'missing row' }, @{ Mutation = 'duplicate row' }, @{ Mutation = 'wrong candidate' },
        @{ Mutation = 'wrong fixture' }, @{ Mutation = 'stale fingerprint' }, @{ Mutation = 'wrong tree' },
        @{ Mutation = 'skipped row' }, @{ Mutation = 'failed row' }, @{ Mutation = 'unavailable row' },
        @{ Mutation = 'wrong phase' }, @{ Mutation = 'no artifacts' }, @{ Mutation = 'altered artifact' },
        @{ Mutation = 'unsafe path' }, @{ Mutation = 'missing Aqua activation' }, @{ Mutation = 'short outage' }
    ) {
        $evidence = New-QualificationEvidenceFixture
        switch ($Mutation) {
            'missing row' { $evidence.rows = @($evidence.rows | Select-Object -Skip 1) }
            'duplicate row' { $evidence.rows += $evidence.rows[0] }
            'wrong candidate' { $evidence.candidateId = 'c' * 64 }
            'wrong fixture' { $evidence.identity.fixture.commit = 'c' * 40 }
            'stale fingerprint' { $evidence.identity.fingerprint = 'c' * 64 }
            'wrong tree' { $evidence.identity.trees.framework = 'c' * 40 }
            'skipped row' { $evidence.rows[0].result = 'skipped' }
            'failed row' { $evidence.rows[0].result = 'fail' }
            'unavailable row' { $evidence.rows[0].result = 'unavailable' }
            'wrong phase' { $evidence.rows[0].phase = 99 }
            'no artifacts' { $evidence.rows[0].artifacts = @() }
            'altered artifact' { $evidence.rows[0].artifacts[0].sha256 = 'c' * 64 }
            'unsafe path' { $evidence.rows[0].artifacts[0].path = '../native.log' }
            'missing Aqua activation' { ($evidence.rows | Where-Object id -EQ 'GM-UTM-AQUA').sessionKind = 'Remote' }
            'short outage' { @($evidence.rows | Where-Object id -EQ 'GM-OUTAGE-6MIN-NO-CONTENT')[0].durationSeconds = 359 }
        }
        { Test-EvidenceFixture $evidence } | Should -Throw
    }

    It 'keeps all shipped phases and native platform combinations in the checked-in contract' {
        @($script:Contract.requiredPhases) | Should -Be @(0, 1, 2, 3)
        @($script:Contract.rows.platform | Sort-Object -Unique) | Should -Be @('linux-x64', 'macos-arm64', 'windows-arm64', 'windows-x64')
        $script:Contract.fixture.commit | Should -Be '160bbb0855b3c304ad61ab45c02b7ef7c042721d'
    }
}

Describe 'Native qualification executes identified production commands and measures their results' {
    BeforeAll {
        Import-Module (Join-Path $script:RepositoryRoot 'tools/GitMirror.NativeQualification.psm1') -Force
        $script:NativeRoot = Join-Path $TestDrive native-command-fixture
        $null = New-Item -ItemType Directory -Path $script:NativeRoot
        $script:NativeContext = @{
            roots = @{ candidate = $script:NativeRoot; old = $script:NativeRoot; target = $script:NativeRoot; installer = $script:NativeRoot }
            variables = @{ TargetRoot = $script:NativeRoot; Value = 'literal $(touch forbidden) `quoted`' }
            environment = @{ COMPlus_MultiCoreJitMinNumCpus = 'FFFFFFFF' }
            frameworkTree = 'b' * 40; fixtureCommit = 'a' * 40
            background = [Collections.Generic.List[object]]::new()
        }
        [IO.File]::WriteAllText((Join-Path $script:NativeRoot probe.ps1), 'param([string]$Value) [Console]::Out.Write($Value); [Console]::Error.Write("diagnostic")')
        [IO.File]::WriteAllText((Join-Path $script:NativeRoot wait.ps1), 'Start-Sleep -Seconds 30')
    }

    It 'passes literal arguments without a shell and records actual exit and output' {
        $command = @{ source = 'candidate'; path = 'probe.ps1'; arguments = @('-Value', '${Value}'); timeoutSeconds = 5 }
        $result = Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 1
        $result.exitCode | Should -Be 0
        $result.timedOut | Should -BeFalse
        [IO.File]::ReadAllText($result.stdout) | Should -BeExactly $script:NativeContext.variables.Value
        [IO.File]::ReadAllText($result.stderr) | Should -BeExactly 'diagnostic'
        $result.sourceHash | Should -BeExactly (Get-FileHash (Join-Path $script:NativeRoot probe.ps1)).Hash.ToLowerInvariant()
    }

    It 'kills an actual stalled command within its bounded process deadline' {
        $command = @{ source = 'candidate'; path = 'wait.ps1'; arguments = @(); timeoutSeconds = 1 }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 2
        $result.timedOut | Should -BeTrue
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
        Get-Process -Id $result.processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'owns a background resident process until its explicit cleanup' {
        $command = @{ source = 'old'; path = 'wait.ps1'; arguments = @(); timeoutSeconds = 5; background = $true }
        $result = Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 3
        try {
            Get-Process -Id $result.processId | Should -Not -BeNullOrEmpty
            $script:NativeContext.background.Count | Should -Be 1
        } finally { Stop-GitMirrorNativeCommand $script:NativeContext -Confirm:$false }
        Get-Process -Id $result.processId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $script:NativeContext.background.Count | Should -Be 0
    }

    It 'refuses an entry point outside its identified source' {
        $command = @{ source = 'candidate'; path = '../escape.ps1'; arguments = @(); timeoutSeconds = 1 }
        { Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 4 } | Should -Throw '*relative production*'
    }

    It 'refuses undeclared path substitutions without evaluating them' {
        { Expand-GitMirrorNativeValue '${Missing}' @{} } | Should -Throw '*Unknown native recipe variable*'
    }

    It 'measures configuration preservation and detects a changed file' {
        $file = Join-Path $script:NativeRoot config.yml
        [IO.File]::WriteAllText($file, 'project: file:///operator-project')
        $observation = @{ kind = 'file-preserved'; path = $file }
        $before = Get-GitMirrorNativeObservation $observation $script:NativeContext
        $same = Get-GitMirrorNativeObservation $observation $script:NativeContext
        Test-GitMirrorNativeObservation $observation $before $same $script:NativeContext | Should -BeTrue
        [IO.File]::WriteAllText($file, 'project: replaced')
        $changed = Get-GitMirrorNativeObservation $observation $script:NativeContext
        Test-GitMirrorNativeObservation $observation $before $changed $script:NativeContext | Should -BeFalse
    }

    It 'verifies signed installer bytes before allowing an installer command' {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try {
            $key = Join-Path $script:NativeRoot public.pem
            [IO.File]::WriteAllText($key, $rsa.ExportSubjectPublicKeyInfoPem())
            $installer = Join-Path $script:NativeRoot ubuntu.kvm.sh
            [IO.File]::WriteAllText($installer, '#!/bin/sh')
            $hash = (Get-FileHash $installer).Hash.ToLowerInvariant()
            $bytes = [Text.Encoding]::UTF8.GetBytes("$hash  ubuntu.kvm.sh`n")
            [IO.File]::WriteAllBytes((Join-Path $script:NativeRoot install.sha256), $bytes)
            [IO.File]::WriteAllBytes((Join-Path $script:NativeRoot install.sha256.sig),
                $rsa.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
            { Test-GitMirrorInstallerSignature $script:NativeRoot $key ubuntu.kvm.sh } | Should -Not -Throw
            [IO.File]::WriteAllText($installer, 'substituted')
            { Test-GitMirrorInstallerSignature $script:NativeRoot $key ubuntu.kvm.sh } | Should -Throw '*signed manifest*'
        } finally { $rsa.Dispose() }
    }

    It 'changes only the controlled framework routes in a real resident child environment' {
        $state = Join-Path $script:NativeRoot state
        $origin = Join-Path $state adoption.git
        $null = New-Item -ItemType Directory -Path $state -Force
        & git init --bare --quiet $origin
        $LASTEXITCODE | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $script:NativeRoot routing.ps1),
            '@{ framework=$env:GIT_CONFIG_KEY_0; frameworkBare=$env:GIT_CONFIG_KEY_1; project=$env:GIT_CONFIG_KEY_2; count=$env:GIT_CONFIG_COUNT } | ConvertTo-Json -Compress')
        $context = $script:NativeContext.Clone()
        $context.variables = $script:NativeContext.variables.Clone()
        $context.variables.StatePath = $state
        $context.environment = @{
            GIT_CONFIG_COUNT = '3'
            GIT_CONFIG_KEY_0 = 'url.file:///candidate.insteadOf'; GIT_CONFIG_VALUE_0 = 'https://github.com/alissonsol/yuruna.git'
            GIT_CONFIG_KEY_1 = 'url.file:///candidate.insteadOf'; GIT_CONFIG_VALUE_1 = 'https://github.com/alissonsol/yuruna'
            GIT_CONFIG_KEY_2 = 'url.file:///project.insteadOf'; GIT_CONFIG_VALUE_2 = 'https://github.com/alissonsol/yuruna-project.git'
        }
        $command = @{ source = 'candidate'; path = 'routing.ps1'; arguments = @(); timeoutSeconds = 5; frameworkOriginPath = '${StatePath}/adoption.git' }
        $result = Invoke-GitMirrorNativeCommand $command $context $script:NativeRoot 5
        $result.exitCode | Should -Be 0
        $observed = Get-Content -Raw -LiteralPath $result.stdout | ConvertFrom-Json
        $expected = 'url.' + [Uri]::new($origin).AbsoluteUri + '.insteadOf'
        $observed.framework | Should -BeExactly $expected
        $observed.frameworkBare | Should -BeExactly $expected
        $observed.project | Should -BeExactly 'url.file:///project.insteadOf'
        $observed.count | Should -Be '3'
        $context.environment.GIT_CONFIG_KEY_0 | Should -BeExactly 'url.file:///candidate.insteadOf'
    }

    It 'refuses a controlled framework origin outside the disposable scenario state' {
        $context = $script:NativeContext.Clone()
        $context.variables = $script:NativeContext.variables.Clone()
        $context.variables.StatePath = Join-Path $script:NativeRoot state
        $command = @{ source = 'candidate'; path = 'probe.ps1'; arguments = @(); timeoutSeconds = 5; frameworkOriginPath = $script:NativeRoot }
        { Invoke-GitMirrorNativeCommand $command $context $script:NativeRoot 6 } | Should -Throw '*inside the disposable scenario*'
    }

    It 'refuses service mutations without an explicit disposable-target acknowledgment' {
        $path = Join-Path $script:RepositoryRoot 'tools/Test-GitMirrorNativeService.ps1'
        { & $path -Repository example/repo -OutputPath (Join-Path $TestDrive forbidden.json) } |
            Should -Throw '*explicitly disposable*'
        Test-Path (Join-Path $TestDrive forbidden.json) | Should -BeFalse
    }

    It 'records a real expected installer refusal and rejects background exit-code exceptions' {
        [IO.File]::WriteAllText((Join-Path $script:NativeRoot refusal.ps1), 'exit 4')
        $command = @{ source = 'candidate'; path = 'refusal.ps1'; arguments = @(); timeoutSeconds = 5; expectedExitCodes = @(4) }
        $result = Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 7
        $result.exitCode | Should -Be 4
        $result.expectedExitCodes | Should -Contain 4
        $command.background = $true
        { Invoke-GitMirrorNativeCommand $command $script:NativeContext $script:NativeRoot 8 } | Should -Throw '*foreground*'
    }
}

Describe 'Focused release suites cannot pass with missing discovery or lost tests' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tools/Invoke-CrossRepoGate.ps1'), [ref]$null, [ref]$null)
        $helper = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Get-FocusedPesterCompleteness'
            }, $true)
        if (-not $helper) { throw 'Focused gate has no positive-discovery and count-floor guard.' }
        . ([scriptblock]::Create($helper.Extent.Text))
    }

    It 'rejects <Loss>' -ForEach @(
        @{ Loss = 'empty discovery'; Counts = @{ 'a.Tests.ps1' = 0; 'b.Tests.ps1' = 0 }; Skipped = 0 },
        @{ Loss = 'omitted required suite'; Counts = @{ 'a.Tests.ps1' = 2 }; Skipped = 0 },
        @{ Loss = 'lost case'; Counts = @{ 'a.Tests.ps1' = 1; 'b.Tests.ps1' = 1 }; Skipped = 0 },
        @{ Loss = 'skipped required case'; Counts = @{ 'a.Tests.ps1' = 2; 'b.Tests.ps1' = 1 }; Skipped = 1 }
    ) {
        @(Get-FocusedPesterCompleteness -RequiredPath @('a.Tests.ps1', 'b.Tests.ps1') -Counts $Counts `
            -Floors @{ 'a.Tests.ps1' = 2; 'b.Tests.ps1' = 1 } -IncompleteCount $Skipped).Count | Should -BeGreaterThan 0
    }

    It 'accepts every required suite at its count floor with no skipped cases' {
        @(Get-FocusedPesterCompleteness -RequiredPath @('a.Tests.ps1', 'b.Tests.ps1') `
            -Counts @{ 'a.Tests.ps1' = 2; 'b.Tests.ps1' = 1 } `
            -Floors @{ 'a.Tests.ps1' = 2; 'b.Tests.ps1' = 1 } -IncompleteCount 0).Count | Should -Be 0
    }
}
