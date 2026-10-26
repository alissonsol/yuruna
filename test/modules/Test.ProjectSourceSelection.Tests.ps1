<#PSScriptInfo
.VERSION 2026.10.26
.GUID 42adb3a3-d392-473c-9950-ce00a1d52620
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test project entrypoint source selection
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:Root 'automation/Yuruna.Globalization.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SourceSelection.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -Force
    $script:EntryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'test/Invoke-TestProject.ps1'), [ref]$null, [ref]$null)

    # What a cycle does before its inner refreshes the project: the cycle
    # process binds the installed framework, then the inner's configuration
    # gate (unless bypassed) selects the project pin for the generation.
    function Initialize-CycleSourceFixture {
        param([bool]$Gate)
        $configPath = Join-Path $script:FixtureRepo 'test/test.config.yml'
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:FixtureRepo
        if (-not (Write-GitSourceHandoff -RepoRoot $script:FixtureRepo -ConfigPath $configPath -CycleGeneration $env:YURUNA_CYCLE_GENERATION -Framework $installed -Confirm:$false)) {
            throw 'fixture handoff write failed'
        }
        if ($Gate) { $null = Invoke-GitSourceGate -RepoRoot $script:FixtureRepo -ConfigPath $configPath -CycleGeneration $env:YURUNA_CYCLE_GENERATION }
        # Upstream advances after the gate has selected its commit.
        [IO.File]::WriteAllText((Join-Path $script:Origin 'VERSION'), "advanced`n")
        & git -C $script:Origin commit -qam advanced
        return (Read-GitSourceHandoff -RepoRoot $script:FixtureRepo -ConfigPath $configPath -CycleGeneration $env:YURUNA_CYCLE_GENERATION)
    }
    function Invoke-CycleRefreshFixture {
        param($Handoff)
        $installed = Read-InstalledGitSource -RepoRoot $script:FixtureRepo
        $acceptedAt = if ($Handoff.project) { $Handoff.projectAcceptedAt } else { $null }
        return (Invoke-CycleProjectRefresh -RepoRoot $script:FixtureRepo -ProjectUrl $script:ProjectUrl -SourceSelection $Handoff.project `
            -SelectionAcceptedAt $acceptedAt -SourceContext $script:Context -InstalledProvenance $installed.project)
    }
}

# A one-shot project run did its own gate and checkout and then spawned the
# inner with -NoProjectClone, outside the runner's watchdog, ceiling and
# cycle-end hooks. The run is now one runner cycle, whose inner refreshes the
# project the way every runner cycle does; these cases hold that refresh to
# the pin the cycle's gate selected.
Describe 'The cycle refreshes the project from the pin its gate selected' {
    BeforeEach {
        $script:FixtureRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Origin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:RecordPath = Join-Path $TestDrive 'handoff.json'
        $script:InstalledPath = Join-Path $TestDrive 'installed.json'
        Remove-Item $script:RecordPath, $script:InstalledPath -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FixtureRepo 'test'), $script:Origin -Force
        foreach ($path in $script:FixtureRepo, $script:Origin) {
            & git init -q $path
            & git -C $path config user.name Fixture
            & git -C $path config user.email fixture@example.invalid
            [IO.File]::WriteAllText((Join-Path $path 'VERSION'), "selected`n")
            & git -C $path add .
            & git -C $path commit -qm selected
            if ($LASTEXITCODE -ne 0) { throw 'Could not initialize project fixture.' }
        }
        & git -C $script:FixtureRepo remote add origin https://github.com/fixture/framework.git
        $script:Pin = ([string](& git -C $script:Origin rev-parse HEAD)).Trim()
        $script:ProjectUrl = 'https://github.com/fixture/project.git'
        $script:Context = @{ mode='off'; url=''; verificationPublicKeys=@(); mirrorOnlyMaxAgeSeconds=604800 }
        @{ repositories=@{projectUrl=$script:ProjectUrl; mirror=@{mode='off'}} } | ConvertTo-Yaml |
            Set-Content (Join-Path $script:FixtureRepo 'test/test.config.yml')
        $script:PriorGeneration = $env:YURUNA_CYCLE_GENERATION
        $env:YURUNA_CYCLE_GENERATION = ('f' * 32) + ':99'
        $script:OriginalConfigCount = $env:GIT_CONFIG_COUNT
        $script:ConfigIndex = if ($env:GIT_CONFIG_COUNT) { [int]$env:GIT_CONFIG_COUNT } else { 0 }
        $script:ConfigKey = "GIT_CONFIG_KEY_$($script:ConfigIndex)"
        $script:ConfigValue = "GIT_CONFIG_VALUE_$($script:ConfigIndex)"
        $script:OriginalKey = [Environment]::GetEnvironmentVariable($script:ConfigKey)
        $script:OriginalValue = [Environment]::GetEnvironmentVariable($script:ConfigValue)
        [Environment]::SetEnvironmentVariable($script:ConfigKey, "url.$($script:Origin.Replace('\','/')).insteadOf")
        [Environment]::SetEnvironmentVariable($script:ConfigValue, $script:ProjectUrl)
        $env:GIT_CONFIG_COUNT = [string]($script:ConfigIndex + 1)
        Mock Get-YurunaPrivateStatePath -ModuleName Test.SourceSelection {
            param($Name)
            @{ Resolved=$true; Path=$(if ($Name -eq 'installed-sources.json') { $script:InstalledPath } else { $script:RecordPath }) }
        }
        Mock Get-GitSourceConfiguration -ModuleName Test.SourceSelection {
            @{ context=$script:Context; projectUrl=$script:ProjectUrl; frameworkUrl='https://github.com/fixture/framework.git' }
        }
        Mock Get-GitRepositoryUpdateTarget -ModuleName Test.SourceSelection { @{Success=$true;Skipped=$true;SourceSelection=$null} }
        Mock Resolve-GitSourceSelection -ModuleName Test.SourceSelection {
            @{
                success=$true; repository='fixture/project'; ref='HEAD'; selectedSha=$script:Pin
                fetchRef=$script:Pin; fetchUrl=$script:ProjectUrl; source='origin'; verification='not-applicable'
                fallbackReason=''; failureClass=''
                resolvedDefaultBranch='refs/heads/main'; acceptedAt=[DateTimeOffset]::UtcNow.ToString('O')
            }
        }
        Mock Format-YurunaOperatorMessage { '' }
    }
    AfterEach {
        $env:YURUNA_CYCLE_GENERATION = $script:PriorGeneration
        $env:GIT_CONFIG_COUNT = $script:OriginalConfigCount
        [Environment]::SetEnvironmentVariable($script:ConfigKey, $script:OriginalKey)
        [Environment]::SetEnvironmentVariable($script:ConfigValue, $script:OriginalValue)
    }
    It 'clones the gate''s pin after the tip moved and records the actual provenance' {
        $handoff = Initialize-CycleSourceFixture -Gate $true
        $step = Invoke-CycleRefreshFixture -Handoff $handoff
        $step.Ok | Should -BeTrue
        (Get-Content (Join-Path $script:FixtureRepo 'project/VERSION') -Raw).Trim() | Should -Be selected
        ([string](& git -C (Join-Path $script:FixtureRepo 'project') rev-parse HEAD)).Trim() | Should -BeExactly $script:Pin
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json -AsHashtable
        $record.framework.verification | Should -Be not-applicable
        $record.project.selectedSha | Should -BeExactly $script:Pin
        (Get-Content $script:InstalledPath -Raw | ConvertFrom-Json -AsHashtable).project.selectedSha | Should -BeExactly $script:Pin
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.SourceSelection -Times 1
    }
    It 'selects the tip once itself when the gate was bypassed' {
        Mock Resolve-GitSourceSelection -ModuleName Test.HostGit {
            @{
                success=$true; repository='fixture/project'; ref='HEAD'; selectedSha=$script:Pin
                fetchRef=$script:Pin; fetchUrl=$script:ProjectUrl; source='origin'; verification='not-applicable'
                fallbackReason=''; failureClass=''
                resolvedDefaultBranch='refs/heads/main'; acceptedAt=[DateTimeOffset]::UtcNow.ToString('O')
            }
        }
        $handoff = Initialize-CycleSourceFixture -Gate $false
        $handoff.project | Should -BeNullOrEmpty
        $step = Invoke-CycleRefreshFixture -Handoff $handoff
        $step.Ok | Should -BeTrue
        ([string](& git -C (Join-Path $script:FixtureRepo 'project') rev-parse HEAD)).Trim() | Should -BeExactly $script:Pin
        (Get-Content $script:InstalledPath -Raw | ConvertFrom-Json -AsHashtable).project.selectedSha | Should -BeExactly $script:Pin
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.HostGit -Times 1
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.SourceSelection -Times 0
    }
    It 'never records installed provenance when the checkout fails' {
        Mock Invoke-CycleCheckoutStep -ModuleName Test.RunnerInnerLoop { [pscustomobject]@{ Ok=$false; Skipped=$false; ErrorMessage='fixture failed'; SourceSelection=@{ selectedSha=$script:Pin } } }
        $handoff = Initialize-CycleSourceFixture -Gate $true
        $step = Invoke-CycleRefreshFixture -Handoff $handoff
        $step.Ok | Should -BeFalse
        $step.ErrorMessage | Should -Be 'fixture failed'
        Test-Path $script:InstalledPath | Should -BeFalse
    }
}

Describe 'Invoke-TestProject runs one runner cycle' {
    It 'dispatches through the runner and restores the caller''s generation on every outcome' {
        $commands = @($script:EntryAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        $names = @($commands | ForEach-Object { $_.GetCommandName() })
        $names | Should -Contain 'Invoke-OuterCycleDispatch'
        $names | Should -Contain 'Get-OneShotCycleExitCode'
        foreach ($inline in 'Invoke-CycleCheckoutStep', 'Update-ProjectClone', 'Invoke-GitSourceGate', 'Invoke-ConfigGate', 'Invoke-RunnerOuterCycle', 'New-InnerRunnerArgList') {
            $names | Should -Not -Contain $inline -Because "the cycle's own processes own $inline"
        }
        $dispatch = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-OuterCycleDispatch' })[0]
        $owner = $dispatch.Parent
        while ($owner -and $owner -isnot [Management.Automation.Language.TryStatementAst]) { $owner = $owner.Parent }
        $owner | Should -Not -BeNullOrEmpty
        $owner.Finally.Extent.Text | Should -Match '\$env:YURUNA_CYCLE_GENERATION = \$previousGeneration'
        $state = $script:EntryAst.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$cycleState' }, $true)
        $state.Right.Extent.Text | Should -Match 'CycleScript\s+= Join-Path \$ModulesDir ''Invoke-TestCycleRunner\.ps1'''
        $state.Right.Extent.Text | Should -Match 'NoGitPull\s+= \$true'
        $state.Right.Extent.Text | Should -Match 'CycleGeneration = \$env:YURUNA_CYCLE_GENERATION'
    }
}
