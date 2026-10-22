<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42ad5782-14c1-45bd-8f19-ea58d1b6d0f4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test source mirror generation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.SourceSelection.psm1') -Force
    Import-Module powershell-yaml -Force
    $script:repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:head = ([string](& git -C $script:repo rev-parse HEAD)).Trim()
    $script:generation = ('a' * 32) + ':1'
    $configAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repo 'test/Test-Config.ps1'), [ref]$null, [ref]$null)
    $freshness = $configAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'Test-RepoFreshness -Label "framework'
    }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
    $script:frameworkFreshness = [scriptblock]::Create(@'
param($gitSourceGate, $Config)
$RepoRoot = 'fixture'
function Test-RepoFreshness { param($Label, $Path) return 'legacy-fetch-called' }
'@ + "`n" + $freshness.Extent.Text)
}

Describe 'Source configuration snapshot and cycle handoff' {
    BeforeEach {
        $script:configPath = Join-Path $TestDrive 'test.config.yml'
        $script:recordPath = Join-Path $TestDrive 'source-selection.json'
        $script:installedPath = Join-Path $TestDrive 'installed-sources.json'
        $script:priorProxy = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        @{
            repositories=@{frameworkUrl='https://github.com/example/framework';projectUrl='https://github.com/example/project'}
            vmStart=@{cachingProxyIp='192.168.50.4'}
        } | ConvertTo-Yaml | Set-Content $script:configPath
        Mock Get-YurunaPrivateStatePath -ModuleName Test.SourceSelection { param($Name) @{ Resolved=$true;Path=$(if ($Name -eq 'installed-sources.json') { $script:installedPath } else { $script:recordPath }) } }
        Mock Get-CachingProxyServiceStateIp -ModuleName Test.SourceSelection { '192.168.50.8' }
        Mock Read-YurunaPoolManifest -ModuleName Test.SourceSelection { $null }
    }
    AfterEach { $env:YURUNA_CACHING_PROXY_SERVICE_IP = $script:priorProxy }

    It 'reads defaults and a configured proxy before a template write' {
        $before = [IO.File]::ReadAllBytes($script:configPath)
        $snapshot = Get-GitSourceConfiguration -ConfigPath $script:configPath
        $snapshot.context.mode | Should -Be 'prefer'
        $snapshot.context.url | Should -Be 'http://192.168.50.4'
        @($snapshot.context.verificationPublicKeys).Count | Should -Be 0
        [IO.File]::ReadAllBytes($script:configPath) | Should -BeExactly $before
    }

    It 'gives an explicit URL precedence over every discovered address' {
        'repositories: {mirror: {url: "http://192.168.50.1:8000"}}' | Set-Content $script:configPath
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.168.50.7'
        (Get-GitSourceConfiguration -ConfigPath $script:configPath).context.url | Should -Be 'http://192.168.50.1:8000'
    }

    It 'uses environment then persisted state when no proxy address is configured' {
        '{}' | Set-Content $script:configPath
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = '2001:db8::7'
        (Get-GitSourceConfiguration -ConfigPath $script:configPath).context.url | Should -Be 'http://[2001:db8::7]'
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        (Get-GitSourceConfiguration -ConfigPath $script:configPath).context.url | Should -Be 'http://192.168.50.8'
        Should -Invoke Get-CachingProxyServiceStateIp -ModuleName Test.SourceSelection -Times 1 -ParameterFilter { $ReadOnly }
    }

    It 'accepts pool URL assignments without enrolling pool trust or policy' {
        Mock Read-YurunaPoolManifest -ModuleName Test.SourceSelection { @{repositories=@{frameworkUrl='https://github.com/pool/framework';projectUrl='https://github.com/pool/project';mirror=@{mode='off';verificationPublicKeys=@('untrusted')}}} }
        $snapshot = Get-GitSourceConfiguration -ConfigPath $script:configPath
        $snapshot.projectUrl | Should -Be 'https://github.com/pool/project'
        $snapshot.context.mode | Should -Be 'prefer'
        @($snapshot.context.verificationPublicKeys).Count | Should -Be 0
    }

    It 'rejects malformed host configuration without making source requests' {
        'repositories: {mirror: {verificationPublicKeys: ["bad"]}}' | Set-Content $script:configPath
        { Get-GitSourceConfiguration -ConfigPath $script:configPath } | Should -Throw '*mirror-key-invalid*'
    }

    It 'records actual installed HEAD without inventing origin confirmation' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $installed.selectedSha | Should -BeExactly $script:head
        $installed.verification | Should -Be 'not-applicable'
        $installed.originCheckedAt | Should -BeNullOrEmpty
        Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false | Should -BeTrue
        $record = Read-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath
        $record.framework.selectedSha | Should -BeExactly $script:head
    }

    It 'rejects a record for another generation or configuration path' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $null = Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false
        { Read-GitSourceHandoff -CycleGeneration (('b' * 32)+':2') -RepoRoot $script:repo -ConfigPath $script:configPath } | Should -Throw '*source-handoff-identity-mismatch*'
        { Read-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath ($script:configPath+'.other') } | Should -Throw '*source-handoff-identity-mismatch*'
    }

    It 'rejects evidence for a different installed HEAD' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $installed.selectedSha = 'f' * 40
        $null = Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false
        { Read-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath } | Should -Throw '*source-handoff-head-mismatch*'
    }

    It 'selects the project once and reuses the immutable choice on another gate call' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $null = Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false
        $script:acceptedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('O')
        Mock Resolve-GitSourceSelection -ModuleName Test.SourceSelection { @{success=$true;selectedSha=('c'*40);source='origin';verification='origin-direct';repository='example/project';ref='HEAD';acceptedAt=$script:acceptedAt} }
        Mock Test-GitSourceSelection -ModuleName Test.SourceSelection { @{success=$true} }
        $first = Invoke-GitSourceGate -RepoRoot $script:repo -ConfigPath $script:configPath -CycleGeneration $script:generation
        $second = Invoke-GitSourceGate -RepoRoot $script:repo -ConfigPath $script:configPath -CycleGeneration $script:generation
        $second.project.selectedSha | Should -BeExactly $first.project.selectedSha
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.SourceSelection -Times 1
        $record = Read-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath
        ([DateTimeOffset]$record.projectAcceptedAt) | Should -Be ([DateTimeOffset]::Parse($script:acceptedAt))
        $first.skipGitHubProbe | Should -BeTrue
        $second.skipGitHubProbe | Should -BeTrue
        Should -Invoke Test-GitSourceSelection -ModuleName Test.SourceSelection -Times 1 -ParameterFilter { $AcceptedAt -eq [DateTimeOffset]::Parse($script:acceptedAt) }
    }

    It 'uses the same source selection for canonical SSH GitHub URLs' -ForEach @(
        @{Url='git@github.com:example/project.git'}, @{Url='ssh://git@github.com/example/project.git'}
    ) {
        @{repositories=@{projectUrl=$Url}} | ConvertTo-Yaml | Set-Content $script:configPath
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $null = Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false
        Mock Resolve-GitSourceSelection -ModuleName Test.SourceSelection { @{success=$true;repository='example/project';selectedSha=('c'*40);source='mirror';verification='mirror-fresh';ref='HEAD'} }
        $result = Invoke-GitSourceGate -RepoRoot $script:repo -ConfigPath $script:configPath -CycleGeneration $script:generation
        $result.project.verification | Should -Be 'mirror-fresh'
        $result.skipGitHubProbe | Should -BeTrue
        Should -Invoke Resolve-GitSourceSelection -ModuleName Test.SourceSelection -Times 1 -ParameterFilter { $RepositoryUrl -ceq $Url -and $Operation -eq 'Gate' }
    }

    It 'uses the gate budget without fetching framework objects' {
        '{}' | Set-Content $script:configPath
        Mock Get-GitRepositoryUpdateTarget -ModuleName Test.SourceSelection { @{Success=$true;Skipped=$true;Revision=$script:head;SourceSelection=$null} }
        $result = Invoke-GitSourceGate -RepoRoot $script:repo -ConfigPath $script:configPath
        $result.frameworkSkipped | Should -BeTrue
        Should -Invoke Get-GitRepositoryUpdateTarget -ModuleName Test.SourceSelection -Times 1 -ParameterFilter {
            $Operation -eq 'Gate' -and $NoFetch -and ($DeadlineUtc-[DateTimeOffset]::UtcNow).TotalSeconds -le 45
        }
    }

    It 'retains private proof but drops incidental output and URL credentials in the generation record' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        $installed.repository = 'https://user:fixture-secret@example.invalid/framework.git'
        $installed.fetchUrl = $installed.repository
        $installed.detail = 'fixture-secret'
        $installed.attempts = @(@{error='fixture-secret'})
        $installed.proof = @{nonce='retained-nonce';receipt='retained-receipt'}
        $null = Write-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath -Framework $installed -Confirm:$false
        $text = [IO.File]::ReadAllText($script:recordPath)
        $text | Should -Not -Match 'fixture-secret|"attempts"|"detail"'
        $record = Read-GitSourceHandoff -CycleGeneration $script:generation -RepoRoot $script:repo -ConfigPath $script:configPath
        $record.framework.repository | Should -BeExactly 'https://example.invalid/framework.git'
        $record.framework.proof.receipt | Should -BeExactly 'retained-receipt'
    }

    It 'refuses to overwrite installed provenance with evidence for another commit' {
        $installed = Get-InstalledGitSourceSelection -RepoRoot $script:repo
        Write-InstalledGitSource -RepoRoot $script:repo -Kind framework -Selection $installed -Confirm:$false | Should -BeTrue
        $before = [IO.File]::ReadAllBytes($script:installedPath)
        $installed.selectedSha = 'f' * 40
        { Write-InstalledGitSource -RepoRoot $script:repo -Kind framework -Selection $installed -Confirm:$false } | Should -Throw '*source-provenance-head-mismatch*'
        [IO.File]::ReadAllBytes($script:installedPath) | Should -BeExactly $before
    }

    It 'uses actual upstream eligibility for legacy freshness (<Case>)' -ForEach @(
        @{Case='GitHub checkout with a configured local URL';Actual='https://github.com/example/framework';Configured='file:///operator/framework.git';Skipped=$false;Expected=0},
        @{Case='SSH checkout with a blank configured URL';Actual='git@github.com:example/framework.git';Configured='';Skipped=$false;Expected=0},
        @{Case='intentional no-pull installed snapshot';Actual='file:///operator/framework.git';Configured='file:///operator/framework.git';Skipped=$true;Expected=0},
        @{Case='non-GitHub checkout with a configured GitHub URL';Actual='file:///operator/framework.git';Configured='https://github.com/example/framework';Skipped=$false;Expected=1}
    ) {
        $gate = @{frameworkUrl=$Actual;frameworkSkipped=$Skipped}
        @(& (Get-Module Test.SourceSelection) $script:frameworkFreshness $gate @{repositories=@{frameworkUrl=$Configured}}).Count | Should -Be $Expected
    }
}
