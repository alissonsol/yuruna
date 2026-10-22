<#PSScriptInfo
.VERSION 2026.10.22
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
    Import-Module (Join-Path $PSScriptRoot 'Test.SourceSelection.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryContract.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigPreflight.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Global -DisableNameChecking
    Import-Module powershell-yaml -Force
    $script:Entry = Get-Content (Join-Path $script:Root 'test/Invoke-TestProject.ps1') -Raw
    $script:EntryAst = [Management.Automation.Language.Parser]::ParseInput($script:Entry, [ref]$null, [ref]$null)
    function Invoke-ProjectEntryCheckoutFixture {
        param([bool]$Skip)
        $RepoRoot = $script:FixtureRepo
        $ConfigPath = Join-Path $RepoRoot 'test/test.config.yml'
        $ModulesDir = $PSScriptRoot
        $TestRoot = Join-Path $RepoRoot 'test'
        $projectUrl = $script:ProjectUrl
        $NoConfigGate = $Skip
        $ExitFailure = 1
        $script:RecoverySteps = [Collections.Generic.List[object]]::new()
        # Execute the production source/gate/checkout block; stop before the
        # inner process would start real host/VM work. Its enclosing finally
        # must still restore the caller's generation on every outcome.
        $start = $script:Entry.IndexOf('# --- REGION: Source selection')
        if ($start -lt 0) { $start = $script:Entry.IndexOf('# --- REGION: Pre-cycle config gate') }
        $end = $script:Entry.IndexOf('# --- REGION: Step 3: spawn one inner cycle', $start)
        $owner = $script:EntryAst.Find({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
                $node.Body.Extent.Text.Contains('$gate = Invoke-ConfigGate')
        }, $true)
        if ($owner) {
            $prefix = $script:Entry.Substring($start, $owner.Extent.StartOffset - $start)
            $bodyStart = $owner.Body.Extent.StartOffset + 1
            $body = $script:Entry.Substring($bodyStart, $end - $bodyStart)
            $cleanup = $owner.Finally.Extent.Text
            $code = $prefix + "`ntry {`n" + $body + "`n} finally " + $cleanup
        } else { $code = $script:Entry.Substring($start, $end - $start) }
        $null = @($RepoRoot, $ConfigPath, $ModulesDir, $TestRoot, $projectUrl, $NoConfigGate, $ExitFailure)
        & ([scriptblock]::Create($code))
    }
}

Describe 'One-shot project runner source handoff' {
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
        Mock Invoke-ConfigGate {
            param($Skip)
            if (-not $Skip) {
                $null = Invoke-GitSourceGate -RepoRoot $script:FixtureRepo -ConfigPath (Join-Path $script:FixtureRepo 'test/test.config.yml') -CycleGeneration $env:YURUNA_CYCLE_GENERATION
            }
            # Upstream advances after the gate has selected its commit.
            [IO.File]::WriteAllText((Join-Path $script:Origin 'VERSION'), "advanced`n")
            & git -C $script:Origin commit -qam advanced
            @{ passed=$true; skipped=[bool]$Skip }
        }
        function Stop-WithReason {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Fixture exit interception only throws; it changes no external state.')]
            param($Code, $Step, $Reason)
            throw "$Step ($Code): $Reason"
        }
        Mock Format-YurunaOperatorMessage { '' }
    }
    AfterEach {
        $env:YURUNA_CYCLE_GENERATION = $script:PriorGeneration
        $env:GIT_CONFIG_COUNT = $script:OriginalConfigCount
        [Environment]::SetEnvironmentVariable($script:ConfigKey, $script:OriginalKey)
        [Environment]::SetEnvironmentVariable($script:ConfigValue, $script:OriginalValue)
    }

    It 'clones the selected pin and persists actual provenance with bypass=<Skip>' -ForEach @(
        @{ Skip=$false }, @{ Skip=$true }
    ) {
        Invoke-ProjectEntryCheckoutFixture -Skip $Skip
        (Get-Content (Join-Path $script:FixtureRepo 'project/VERSION') -Raw).Trim() | Should -Be selected
        ([string](& git -C (Join-Path $script:FixtureRepo 'project') rev-parse HEAD)).Trim() | Should -BeExactly $script:Pin
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json -AsHashtable
        $record.cycleGeneration | Should -Match '^[a-f0-9]{32}:1$'
        $record.framework.verification | Should -Be not-applicable
        $record.project.selectedSha | Should -BeExactly $script:Pin
        (Get-Content $script:InstalledPath -Raw | ConvertFrom-Json -AsHashtable).project.selectedSha | Should -BeExactly $script:Pin
        $env:YURUNA_CYCLE_GENERATION | Should -Be (('f' * 32) + ':99')
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.SourceSelection -Times 1
    }
    It 'restores the caller generation when the checkout fails and never records installed provenance' {
        Mock Invoke-CycleCheckoutStep { @{Ok=$false;Skipped=$false;ErrorMessage='fixture failed'} }
        { Invoke-ProjectEntryCheckoutFixture -Skip $false } | Should -Throw '*fixture failed*'
        $env:YURUNA_CYCLE_GENERATION | Should -Be (('f' * 32) + ':99')
        Test-Path $script:InstalledPath | Should -BeFalse
    }
}
