<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42e3dca5-b895-4c27-bb43-907134f1b511
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest mirror pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

BeforeDiscovery {
    $script:CanRunGuestBash = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.FrameworkSource.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    & (Get-Module Test.FrameworkSource) { function script:Invoke-GuestSsh { } }
    $windowsPath = Join-Path $script:RepoRoot 'guest/windows.11/windows.11.update.ps1'
    $windowsAst = [Management.Automation.Language.Parser]::ParseFile($windowsPath, [ref]$null, [ref]$null)
    foreach ($definition in $windowsAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -in @('Invoke-GuestPinnedFramework', 'Invoke-GuestPinnedGitCommand')
            }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
    function Invoke-GuestMirrorFixtureGit {
        param([string]$Path, [string[]]$Arguments)
        $result = @(& git -C $Path @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($result -join ' ')" }
        return ($result -join "`n").Trim()
    }
}

Describe 'Every service seed receives immutable host identity through the shared renderer' {
    It 'renders the <Service> host environment with the actual checkout commit' -ForEach @(
        @{ Service = 'stash' }, @{ Service = 'pool-control' }, @{ Service = 'download-agent' }
    ) {
        Mock -ModuleName Yuruna.CloudInitTemplate Get-YurunaGitHubSource {
            @{ Repo = 'actual/framework'; Ref = ('a' * 40); Token = ''; FrameworkUrl = 'https://github.com/configured/other'; ProjectUrl = '' }
        }
        $seed = Get-Content -Raw (Join-Path $script:RepoRoot "host/vmconfig/$Service-service.base.user-data") | ConvertFrom-Yaml
        $hostFile = @($seed.write_files | Where-Object path -EQ '/etc/yuruna/host.env')
        $hostFile.Count | Should -Be 1
        $base = Join-Path $TestDrive "$Service.seed.yml"
        $overlay = Join-Path $TestDrive "$Service.overlay.yml"
        @{ write_files = $hostFile } | ConvertTo-Yaml | Set-Content -LiteralPath $base
        Set-Content -LiteralPath $overlay -Value '# No host-agent additions are needed for this host.env rendering fixture.'
        $rendered = New-CloudInitUserData -BasePath $base -OverlayPath $overlay -RepoRoot $script:RepoRoot -Replacement @{
            YURUNA_HOST_ID_PLACEHOLDER = 'fixture'
            YURUNA_STATUS_SERVICE_IP_PLACEHOLDER = '192.0.2.1'
            YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER = '8080'
            YURUNA_CACHING_PROXY_SERVICE_IP_PLACEHOLDER = '192.0.2.2'
        } -Confirm:$false
        $content = @((ConvertFrom-Yaml $rendered).write_files | Where-Object path -EQ '/etc/yuruna/host.env')[0].content
        $content | Should -Match '(?m)^YURUNA_GITHUB_REPO=actual/framework$'
        $content | Should -Match '(?m)^YURUNA_GITHUB_REF=a{40}$'
        $content | Should -Not -Match 'PLACEHOLDER|configured/other'
    }
}

Describe 'Service mirror readiness requires the intended full commit' {
    BeforeEach {
        Mock -ModuleName Test.FrameworkSource Invoke-WebRequest { @{ Content = '{"version":"1.2.3"}' } }
    }
    It 'accepts an exact LAN pin and rejects missing or different commit evidence (<Case>)' -ForEach @(
        @{ Case = 'exact'; Commit = ('a' * 40); Source = 'lan-mirror'; Matches = $true }
        @{ Case = 'wrong'; Commit = ('b' * 40); Source = 'lan-mirror'; Matches = $false }
        @{ Case = 'short'; Commit = ('a' * 12); Source = 'lan-mirror'; Matches = $false }
        @{ Case = 'missing'; Commit = ''; Source = 'lan-mirror'; Matches = $false }
        @{ Case = 'legacy public clone'; Commit = ('a' * 40); Source = 'mirror'; Matches = $false }
    ) {
        $script:Marker = "source=$Source`nversion=1.2.3`ncommit=$Commit"
        Mock -ModuleName Test.FrameworkSource Invoke-GuestSsh { @{ success = $true; output = $script:Marker } }
        $result = Test-ServiceVmFrameworkSource -Address 192.0.2.1 -Expected @{ Version = '1.2.3'; Revision = 'aaaaaaaa'; Commit = ('a' * 40) }
        $result.Verified | Should -BeTrue
        $result.Matches | Should -Be $Matches
    }
}

Describe 'Windows standalone framework materialization' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:Upstream = Join-Path $script:Root upstream
        [IO.Directory]::CreateDirectory($script:Upstream) | Out-Null
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('init', '--quiet', '--initial-branch=main')
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('config', 'user.name', 'fixture')
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('config', 'user.email', 'fixture@example.invalid')
        [IO.File]::WriteAllText((Join-Path $script:Upstream VERSION), '1.2.3')
        foreach ($excluded in @('docs', 'dev-only')) {
            [IO.Directory]::CreateDirectory((Join-Path $script:Upstream $excluded)) | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:Upstream "$excluded/private.txt"), 'excluded archive scope')
        }
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('add', '.')
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('commit', '--quiet', '-m', 'pinned')
        $script:Pin = Invoke-GuestMirrorFixtureGit $script:Upstream @('rev-parse', 'HEAD')
        $script:Destination = Join-Path $script:Root installed
        Mock Invoke-GuestPinnedGitCommand {
            $translated = @($Arguments | ForEach-Object {
                if ($_ -match '^https?://') { ([UriBuilder]::new('file', '', -1, $script:Upstream)).Uri.AbsoluteUri } else { $_ }
            })
            & git @translated *> $null
            return $LASTEXITCODE -eq 0
        }
    }
    It 'installs the exact pin from the LAN, with local provenance and archive exclusions' {
        Invoke-GuestPinnedFramework -Destination $script:Destination -Repository example/repo -Revision $script:Pin -MirrorIp 192.0.2.1 -Confirm:$false 6>$null | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Destination '.git') | Should -BeFalse
        Get-Content -Raw (Join-Path $script:Destination '.yuruna-revision') | Should -BeExactly "$($script:Pin)`n"
        Get-Content -Raw (Join-Path $script:Destination '.yuruna-origin') | Should -BeExactly "https://github.com/example/repo.git`n"
        Test-Path (Join-Path $script:Destination docs) | Should -BeFalse
        Test-Path (Join-Path $script:Destination dev-only) | Should -BeFalse
        Should -Invoke Invoke-GuestPinnedGitCommand -Exactly -Times 1 -ParameterFilter {
            $Mirror -and $Arguments -contains 'fetch' -and $Arguments[-1] -eq $script:Pin -and $Deadline -gt [DateTimeOffset]::UtcNow
        }
        Should -Invoke Invoke-GuestPinnedGitCommand -Exactly -Times 0 -ParameterFilter { -not $Mirror }
    }
    It 'keeps the same immutable pin when the LAN transport fails' {
        Mock Invoke-GuestPinnedGitCommand { return $false } -ParameterFilter { $Mirror }
        Invoke-GuestPinnedFramework -Destination $script:Destination -Repository example/repo -Revision $script:Pin -MirrorIp 192.0.2.1 -Confirm:$false 6>$null | Should -BeTrue
        Should -Invoke Invoke-GuestPinnedGitCommand -Exactly -Times 1 -ParameterFilter {
            -not $Mirror -and $Arguments -contains 'fetch' -and $Arguments[-1] -eq $script:Pin -and $Arguments -contains 'https://github.com/example/repo.git'
        }
    }
    It 'preserves an existing checkout without initiating any transport' {
        [IO.Directory]::CreateDirectory($script:Destination) | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Destination operator.txt), 'preserve')
        Invoke-GuestPinnedFramework -Destination $script:Destination -Repository example/repo -Revision $script:Pin -MirrorIp 192.0.2.1 -Confirm:$false | Should -BeFalse
        Get-Content -Raw (Join-Path $script:Destination operator.txt) | Should -BeExactly preserve
        Should -Invoke Invoke-GuestPinnedGitCommand -Exactly -Times 0
    }
    It 'rejects a mismatched full SHA without leaving a usable-looking destination' {
        Invoke-GuestPinnedFramework -Destination $script:Destination -Repository example/repo -Revision ('b' * 40) -MirrorIp 192.0.2.1 -Confirm:$false 6>$null | Should -BeFalse
        Test-Path -LiteralPath $script:Destination | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Filter 'installed.fetch.*').Count | Should -Be 0
    }
    It 'uses the actual host checkout identity in the Windows seed' {
        $null = Invoke-GuestMirrorFixtureGit $script:Upstream @('remote', 'add', 'origin', 'https://github.com/actual/framework.git')
        $automation = Join-Path $script:Upstream automation
        [IO.Directory]::CreateDirectory($automation) | Out-Null
        foreach ($file in @('windows-guest-bootstrap.ps1', 'yuruna-host-locate.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot "automation/$file") -Destination $automation
        }
        $seed = New-WindowsGuestBootstrap -RepoRoot $script:Upstream -FrameworkUrl https://github.com/configured/other.git -ProjectUrl file:///operator/project
        $body = $seed.Files['yuruna-bootstrap.ps1']
        $body | Should -Match '(?m)^YURUNA_GITHUB_REPO=actual/framework$'
        $body | Should -Match "(?m)^YURUNA_GITHUB_REF=$($script:Pin)$"
        $body | Should -Match '(?m)^YURUNA_FRAMEWORK_URL=https://github.com/configured/other.git$'
        $body | Should -Match '(?m)^YURUNA_PROJECT_URL=file:///operator/project$'
    }
}

Describe 'Standalone Git process bounds and native argument transport' {
    It 'passes a path containing spaces as one argument to the actual Git process' {
        $destination = Join-Path $TestDrive 'standalone path with spaces'
        Invoke-GuestPinnedGitCommand -Arguments @('init', '--quiet', $destination) -Mirror -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination '.git') -PathType Container | Should -BeTrue
    }
    It 'does not start a native command after its deadline' {
        $destination = Join-Path $TestDrive expired
        Invoke-GuestPinnedGitCommand -Arguments @('init', '--quiet', $destination) -Mirror -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(-1)) | Should -BeFalse
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
    It 'stops a Git child that exceeds the standalone deadline' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-GuestPinnedGitCommand -Arguments @('-c', 'alias.pause=!sleep 30', 'pause') -Mirror -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(1)) | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 7
    }
}

Describe 'macOS standalone invocation identity' {
    It 'uses <Case> identity and refuses a moving clone when pinned content is unavailable' -ForEach @(
        @{ Case = 'invocation'; InvocationRepo = 'invocation/framework'; InvocationRef = ('a' * 40); ExpectedRepo = 'invocation/framework'; ExpectedRef = ('a' * 40); Failure = '0' }
        @{ Case = 'seed'; InvocationRepo = ''; InvocationRef = ''; ExpectedRepo = 'seed/framework'; ExpectedRef = ('b' * 40); Failure = '0' }
        @{ Case = 'failed invocation'; InvocationRepo = 'invocation/framework'; InvocationRef = ('a' * 40); ExpectedRepo = 'invocation/framework'; ExpectedRef = ('a' * 40); Failure = '1' }
    ) -Skip:(-not $script:CanRunGuestBash) {
        $source = Get-Content -Raw (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh')
        $start = $source.IndexOf('# --- REGION: Materialize the yuruna framework and project repos')
        $end = $source.IndexOf('if [ ! -d "$REAL_HOME/yuruna/project" ]; then', $start)
        $block = $source.Substring($start, $end - $start)
        $prefix = @'
set -euo pipefail
FRAMEWORK_URL=https://configured.invalid/moving
yuruna_materialize_framework_pin() {
    printf '%s %s\n' "$2" "$3" > "$REAL_HOME/calls"
    [ "$FIXTURE_FAILURE" = 0 ] || return 1
    mkdir -p "$1"
    printf 'verified\n' > "$1/VERSION"
}
git() { printf 'unexpected moving clone\n' >> "$REAL_HOME/calls"; return 95; }
'@
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $scriptPath = Join-Path $root mac-materialize.sh
        [IO.File]::WriteAllText($scriptPath, "$prefix`n$block", [Text.UTF8Encoding]::new($false))
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($scriptPath) -TimeoutSeconds 10 -Environment @{
            REAL_HOME = $root; E_FB_REPO = $InvocationRepo; E_FB_REF = $InvocationRef; EXEC_FALLBACK_REPO = ''; EXEC_FALLBACK_REF = ''
            YURUNA_GITHUB_REPO = 'seed/framework'; YURUNA_GITHUB_REF = ('b' * 40); YURUNA_STATUS_SERVICE_IP = ''; YURUNA_STATUS_SERVICE_PORT = ''
            FIXTURE_FAILURE = $Failure
        }
        $result.ExitCode | Should -Be ([int]$Failure) -Because $result.StdErr
        Get-Content -Raw (Join-Path $root calls) | Should -BeExactly "$ExpectedRepo $ExpectedRef`n"
        Test-Path -LiteralPath (Join-Path $root yuruna/VERSION) | Should -Be ($Failure -eq '0')
    }
}
