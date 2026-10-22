<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42e62d38-20d8-4171-9157-427b737d6f11
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test configuration network causes
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

BeforeAll {
    $script:CauseRepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $script:CauseRepoRoot = Split-Path -Parent $script:CauseRepoRoot
    Import-Module (Join-Path $PSScriptRoot 'Test.GitOutageFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.RunnerOuterLoop.psm1') -DisableNameChecking
    Import-Module powershell-yaml -DisableNameChecking
    $script:CauseRoot = Join-Path $TestDrive 'validator-checkout'
    $null = New-Item -ItemType Directory -Force $script:CauseRoot
    # Run the complete validator in a disposable checkout. Its config and
    # extension-state writers must never touch the developer's runtime.
    $files = & git -C $script:CauseRepoRoot ls-files --cached --others --exclude-standard -- automation globalization global host/modules test/modules test/extension test/schemas test/Test-Config.ps1 test/test.config.yml.template
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate validator fixture sources.' }
    foreach ($relative in $files) {
        $destination = Join-Path $script:CauseRoot $relative
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::Copy((Join-Path $script:CauseRepoRoot $relative), $destination, $true)
    }
    function Invoke-CauseGate {
        param([string]$ProjectUrl)
        $configPath = Join-Path $script:CauseRoot 'test/test.config.yml'
        $template = [IO.File]::ReadAllText((Join-Path $script:CauseRoot 'test/test.config.yml.template'))
        $config = ConvertFrom-Yaml -Yaml $template -Ordered
        $config.repositories.projectUrl = $ProjectUrl
        $config.pool.enabled = $false
        [IO.File]::WriteAllText($configPath, (ConvertTo-Yaml $config))
        $sidecar = Join-Path $script:CauseRoot 'failure-sidecar.json'
        $previous = $env:YURUNA_FAILURE_SIDECAR
        try {
            $env:YURUNA_FAILURE_SIDECAR = $sidecar
            $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $script:CauseRoot 'test/Test-Config.ps1') -ConfigPath $configPath -SkipSend 2>&1
            $exitCode = $LASTEXITCODE
        } finally { $env:YURUNA_FAILURE_SIDECAR = $previous }
        if (-not (Test-Path -LiteralPath $sidecar)) { throw ("Gate wrote no sidecar (exit {0}): {1}" -f $exitCode, ($output -join "`n")) }
        return Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json -AsHashtable
    }
}

Describe 'Real configuration gate causes under a controlled outage' {
    It 'records project transport and direct TCP failures as transient with independent endpoints' {
        $fixture = New-GitOutageFixture
        try {
            $record = Invoke-CauseGate -ProjectUrl 'https://github.com/fixture/project.git'
            $project = @($record.failures | Where-Object { $_.cause -eq 'git-transport-failed' })
            $tcp = @($record.failures | Where-Object { $_.cause -eq 'github-tcp-failed' })
            $project.Count | Should -Be 1 -Because ($record | ConvertTo-Json -Depth 20 -Compress)
            $tcp.Count | Should -Be 1 -Because ($record | ConvertTo-Json -Depth 20 -Compress)
            $project[0].class | Should -Be 'network_timeout'
            $tcp[0].class | Should -Be 'network_timeout'
            $record.diagnostics.githubConnectivity.hostName | Should -Be '127.0.0.1'
            $record.diagnostics.githubConnectivity.port | Should -Be ([uri]$fixture.ProbeEndpoint).Port
            $record.diagnostics.githubConnectivity.endpointOverride | Should -BeTrue
            $record.diagnostics.githubConnectivity.attempts[0].outcome | Should -Be 'refused'
            Test-RunnerConfigGateNetworkOnly -Gate @{ failures = @($project[0], $tcp[0]) } | Should -BeTrue
        } finally { Remove-GitOutageFixture -Fixture $fixture }
    }

    It 'keeps authentication denial out of the network-only class' {
        $fixture = New-GitOutageFixture -Mode Unauthorized
        try {
            $record = Invoke-CauseGate -ProjectUrl 'https://github.com/fixture/denied.git'
            $denied = @($record.failures | Where-Object { $_.cause -eq 'git-access-denied' })
            $denied.Count | Should -Be 1 -Because ($record | ConvertTo-Json -Depth 20 -Compress)
            $denied[0].class | Should -Be 'project_access_denied'
            Test-RunnerConfigGateNetworkOnly -Gate @{ failures = $denied } | Should -BeFalse
        } finally { Remove-GitOutageFixture -Fixture $fixture }
    }

    It 'keeps missing local project configuration out of the network-only class' {
        $fixture = New-GitOutageFixture -Mode Reset
        try {
            $record = Invoke-CauseGate -ProjectUrl (Join-Path $TestDrive 'missing-project')
            $invalid = @($record.failures | Where-Object { $_.cause -eq 'project-config-invalid' })
            $invalid.Count | Should -Be 1
            $invalid[0].class | Should -Be 'bootstrap_sync'
            Test-RunnerConfigGateNetworkOnly -Gate @{ failures = $invalid } | Should -BeFalse
        } finally { Remove-GitOutageFixture -Fixture $fixture }
    }

    It 'appends Git overrides and restores every process environment value on disposal' {
        $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_CONFIG_KEY_1', 'GIT_CONFIG_VALUE_1', 'YURUNA_GITHUB_PROBE_ENDPOINT')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'core.abbrev'
            $env:GIT_CONFIG_VALUE_0 = '12'
            $env:GIT_CONFIG_KEY_1 = 'previous-unused-key'
            $env:GIT_CONFIG_VALUE_1 = 'previous-unused-value'
            $env:YURUNA_GITHUB_PROBE_ENDPOINT = 'http://127.0.0.1:1234'
            $fixture = New-GitOutageFixture -Mode Reset
            try {
                $env:GIT_CONFIG_COUNT | Should -Be '4'
                (& git config core.abbrev) | Should -Be '12'
                $env:GIT_CONFIG_KEY_1 | Should -Be "url.$($fixture.GitEndpoint).insteadOf"
            } finally { Remove-GitOutageFixture -Fixture $fixture }
            $env:GIT_CONFIG_COUNT | Should -Be '1'
            $env:GIT_CONFIG_KEY_1 | Should -Be 'previous-unused-key'
            $env:GIT_CONFIG_VALUE_1 | Should -Be 'previous-unused-value'
            $env:YURUNA_GITHUB_PROBE_ENDPOINT | Should -Be 'http://127.0.0.1:1234'
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }

    It 'redirects the inner diagnostic through the same independent TCP endpoint' {
        Import-Module (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1') -DisableNameChecking
        $fixture = New-GitOutageFixture -Mode Reset
        try {
            $result = & (Get-Module Test.RunnerInnerLoop) { Get-GitHubConnectivityDiagnostic }
            $result.DnsOk | Should -BeTrue
            $result.TcpOk | Should -BeFalse
            $result.HostName | Should -Be '127.0.0.1'
            $result.Port | Should -Be ([uri]$fixture.ProbeEndpoint).Port
            $result.EndpointOverride | Should -BeTrue
        } finally { Remove-GitOutageFixture -Fixture $fixture }
    }
}
