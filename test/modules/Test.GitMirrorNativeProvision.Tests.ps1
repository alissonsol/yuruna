<#PSScriptInfo
.VERSION 2026.10.22
.GUID 427590e3-65ad-4212-b7b6-6765e23d2c4d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    function Invoke-ProvisionGuard {
        param([switch]$WithoutConsent)
        $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $script:root tools/Invoke-GitMirrorNativeProvision.ps1),
            '-Scenario','GM-PROXY-OWNER-FIRST','-TargetRoot',$script:target,'-OldRoot',(Join-Path $TestDrive old),
            '-UpstreamsPath',(Join-Path $TestDrive upstreams.json),'-CandidateTree',('a'*40),'-ProfilePath',$script:profilePath,
            '-OutputPath',(Join-Path $TestDrive observed.json))
        if (-not $WithoutConsent) { $arguments += '-DisposableTarget' }
        $output = & ([Environment]::ProcessPath) @arguments 2>&1 | Out-String
        return @{exitCode=$LASTEXITCODE;output=$output}
    }
}

Describe 'Native provisioning preserves operator control before any mutation' {
    BeforeEach {
        $script:target=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:state=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory $script:target,$script:state
        $script:profilePath=Join-Path $TestDrive profile.json
        $script:settings=@{schema='yuruna.git-mirror.native-provision/v1';statePath=$script:state;proxyUrl='http://192.0.2.10';vmName='qualification-proxy'}
        $script:settings | ConvertTo-Json | Set-Content $script:profilePath
        @{schema='yuruna.git-mirror.disposable-target/v1';targetRoot=$script:target} | ConvertTo-Json | Set-Content (Join-Path $script:state disposable-target.json)
    }
    It 'requires explicit disposable-host acknowledgement before reading configuration' {
        $result=Invoke-ProvisionGuard -WithoutConsent
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'requires -DisposableTarget'
        @(Get-ChildItem $script:target -Force).Count | Should -Be 0
    }
    It 'refuses an existing checkout without deleting or moving it' {
        $sentinel=Join-Path $script:target operator.txt
        [IO.File]::WriteAllText($sentinel,'keep operator data')
        $result=Invoke-ProvisionGuard
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'empty target'
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'keep operator data'
    }
    It 'requires a marker that names this exact target' {
        @{schema='yuruna.git-mirror.disposable-target/v1';targetRoot=(Join-Path $TestDrive different)} | ConvertTo-Json | Set-Content (Join-Path $script:state disposable-target.json)
        $result=Invoke-ProvisionGuard
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'marker does not match'
        @(Get-ChildItem $script:target -Force).Count | Should -Be 0
    }
    It 'refuses to use the candidate source as its target' {
        $script:target=$script:root
        $result=Invoke-ProvisionGuard
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'separate from source'
    }
    It 'rejects credentials in the proxy URL without echoing them' {
        $script:settings.proxyUrl='http://user:sentinel-password@192.0.2.10'
        $script:settings | ConvertTo-Json | Set-Content $script:profilePath
        $result=Invoke-ProvisionGuard
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'credential-free origin'
        $result.output | Should -Not -Match 'sentinel-password'
    }
    It 'refuses a production VM name before loading host management modules' {
        $script:settings.vmName='yuruna-caching-proxy-service'
        $script:settings | ConvertTo-Json | Set-Content $script:profilePath
        $result=Invoke-ProvisionGuard
        $result.exitCode | Should -Not -Be 0
        $result.output | Should -Match 'qualification-prefixed VM'
        @(Get-ChildItem $script:target -Force).Count | Should -Be 0
    }
}

Describe 'Linux service fixture controls retain independent recovery state' {
    # These controls run inside the Linux proxy VM. Windows hosts execute the
    # PowerShell SSH controller; they never import Linux pwd, grp or fcntl.
    It 'preserves real key files and safely bounds origin archive imports' -Skip:$IsWindows {
        $python=Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1
        foreach ($file in @('test_git_mirror_native_rotation.py','test_git_mirror_native_origins.py')) {
            $output = & $python.Source (Join-Path $script:root "tools/$file") 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $output | Should -Match 'OK'
        }
    }
}
