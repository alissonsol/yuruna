<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42db1be5-194a-4332-86f2-4e34e105d100
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna guest bootstrap pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) { throw 'Run this suite with Pester.' }
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    function Invoke-BashFixture {
        param([string]$Body)
        $scriptPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.sh')
        [IO.File]::WriteAllText($scriptPath, $Body)
        $output = & bash $scriptPath 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Output = $output }
    }
}
Describe 'Guest installer child shells propagate failure' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    It 'stops <Component> after nvm fails on Ubuntu <Version>' -ForEach @(
        @{ Component = 'openclaw'; Version = '24' }, @{ Component = 'openclaw'; Version = '26' },
        @{ Component = 'n8n'; Version = '24' }, @{ Component = 'n8n'; Version = '26' }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot "guest/shared/ubuntu.$Component.sh") -Raw
        $body = [regex]::Match($source, "(?s)bash << 'EOF'\r?\n(.*?)\r?\nEOF").Groups[1].Value
        $body | Should -Not -BeNullOrEmpty
        $nvmDir = Join-Path $TestDrive 'nvm'
        [void](New-Item $nvmDir -ItemType Directory -Force)
        Set-Content (Join-Path $nvmDir 'nvm.sh') 'nvm() { return 23; }'
        $body = $body.Replace('$HOME/.nvm', $nvmDir)
        $prefix = @'
wget_try() { return 0; }
npm() { echo UNEXPECTED_NPM; }
openclaw() { echo UNEXPECTED_OPENCLAW; }
YURUNA_NVM_VERSION=0.40.3
YURUNA_NODE_MAJOR=22
'@
        $result = Invoke-BashFixture ($prefix + "`n" + $body)
        $result.Code | Should -Be 23
        $result.Output | Should -Not -Match 'UNEXPECTED_'
    }
    It 'does not diagnose or launch OpenClaw after onboarding fails' {
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/shared/ubuntu.openclaw.sh') -Raw
        $body = [regex]::Match($source, "(?s)bash << 'EOF'\r?\n(.*?)\r?\nEOF").Groups[1].Value
        $nvmDir = Join-Path $TestDrive 'working-nvm'
        [void](New-Item $nvmDir -ItemType Directory -Force)
        Set-Content (Join-Path $nvmDir 'nvm.sh') 'nvm() { return 0; }'
        $body = $body.Replace('$HOME/.nvm', $nvmDir)
        $prefix = @'
wget_try() { return 0; }
npm() { return 0; }
openclaw() { if [[ "$1" == onboard ]]; then return 29; fi; echo UNEXPECTED_DOCTOR; }
YURUNA_NVM_VERSION=0.40.3
YURUNA_NODE_MAJOR=22
'@
        $result = Invoke-BashFixture ($prefix + "`n" + $body)
        $result.Code | Should -Be 29
        $result.Output | Should -Not -Match 'UNEXPECTED_DOCTOR'
    }
    It 'cleans a unique service build directory when source staging fails for <Service>' -ForEach @(
        @{ Service = 'download-agent-service' }, @{ Service = 'pool-control-service' }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$Service.sh") -Raw
        $source | Should -Match 'BUILD="\$\(yuruna_service_stage "\$SERVER_DIR"'
        $library = Join-Path $script:RepoRoot 'automation/yuruna-service-bringup.sh'
        $server = Join-Path $TestDrive 'extension/service/server'
        $sdk = Join-Path $TestDrive 'extension/extension-sdk'
        [void](New-Item $server -ItemType Directory -Force)
        [void](New-Item $sdk -ItemType Directory -Force)
        [IO.File]::WriteAllText((Join-Path $sdk 'go.mod'), 'module fixture')
        $fixture = @'
set -e
. '__LIBRARY__'
cp() { echo "BUILD_PATH=$(dirname "$4")" >&2; return 31; }
yuruna_service_stage '__SERVER__' '__SERVICE__'
'@.Replace('__LIBRARY__', $library).Replace('__SERVER__', $server).Replace('__SERVICE__', $Service)
        $result = Invoke-BashFixture $fixture
        $result.Code | Should -Be 1
        $path = [regex]::Match($result.Output, 'BUILD_PATH=(.+)').Groups[1].Value.Trim()
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}
Describe 'Guest update network probes retain a bounded single attempt' {
    It 'uses fail-on-HTTP for dotnet and single-try wget probes on <Guest>' -ForEach @(
        @{ Guest = 'ubuntu.server.24' }, @{ Guest = 'ubuntu.server.26' }, @{ Guest = 'amazon.linux.2023' }
    ) {
        # The Ubuntu releases share one workflow; their per-release scripts only verify and run it.
        $shared = $Guest -like 'ubuntu.server.*'
        $code = Get-Content (Join-Path $script:RepoRoot $(if ($shared) { 'guest/shared/ubuntu.code.sh' } else { "guest/$Guest/$Guest.code.sh" })) -Raw
        $dotnet = @($code -split "`n" | Where-Object { $_ -match '^curl_retry .*dotnet-install' })
        $dotnet.Count | Should -Be 1
        $dotnet[0] | Should -Match 'curl_retry -[a-zA-Z]*f'
        $update = Get-Content (Join-Path $script:RepoRoot $(if ($shared) { 'guest/shared/ubuntu.update.sh' } else { "guest/$Guest/$Guest.update.sh" })) -Raw
        $probes = @($update -split "`n" | Where-Object { $_ -match 'wget .*\$(?:LIVECHECK_URL|PROJECT_LIVECHECK_URL|CFG_URL)' })
        $probes.Count | Should -Be 4
        foreach ($probe in $probes) { $probe | Should -Match '--tries=1(?:\s|$)' }
    }
}
