<#PSScriptInfo
.VERSION 2026.09.27
.GUID 428f620a-6793-4a91-af55-61a1a07b3e6c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test component registry credential pester
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
    $repoRoot = Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $repoRoot 'automation/Import.Yaml.psm1') -Force
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Component.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    function New-ComponentExecutionFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates isolated component fixtures beneath TestDrive.')]
        [CmdletBinding()]
        param([string]$Root, [string]$Build = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global', [string]$Pre = '', [string]$Post = '')
        $null = New-Item -ItemType Directory -Force -Path "$Root/config/lab", "$Root/components/sample"
        Set-Content -LiteralPath "$Root/components/sample/Dockerfile" -Value 'FROM scratch'
        $yaml = @{
            globalVariables = @{
                buildCommand = $Build; tagCommand = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'
                pushCommand = 'Set-Content -LiteralPath "$env:componentPushMarker" -Value pushed'
                preProcessor = $Pre; postProcessor = $Post
            }
            components = @(@{ project = 'sample' })
        }
        Set-Content -LiteralPath "$Root/config/lab/components.yml" -Value (ConvertTo-Yaml $yaml)
    }
}

Describe 'component command execution' {
    BeforeEach {
        $script:originalLocation = (Get-Location).Path
        $script:originalExit = $global:LASTEXITCODE
        $script:originalEnvironment = @{}
        foreach ($item in Get-ChildItem Env:) { $script:originalEnvironment[$item.Name] = $item.Value }
        $script:originalDocker = Get-Item Function:global:docker -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        $env:componentPasswordCapture = Join-Path $TestDrive ('password-' + [guid]::NewGuid().ToString('N'))
        $env:componentPushMarker = Join-Path $TestDrive ('pushed-' + [guid]::NewGuid().ToString('N'))
        $env:componentLoginExit = '0'
        $env:registryName = 'testRegistry'
        [Environment]::SetEnvironmentVariable('testRegistry.registryLocation', 'harbor.example.com/team/image')
        $env:YURUNA_REGISTRY_USERNAME = 'fixture-user'
        $env:YURUNA_REGISTRY_PASSWORD = 'a secret; $value $(throw "must not execute")'
        $env:YURUNA_DOCKER_HUB_USERNAME = 'fixture-user'
        $env:YURUNA_DOCKER_HUB_PASSWORD = 'hub secret; $value $(throw "must not execute")'
        Set-Item -Path Function:global:docker -Value {
            $input | Set-Content -LiteralPath $env:componentPasswordCapture
            $global:LASTEXITCODE = [int]$env:componentLoginExit
            if ($global:LASTEXITCODE -eq 0) { 'Login Succeeded' } else { 'Login denied' }
        }
        Mock Confirm-ComponentList -ModuleName Yuruna.Component { $true }
    }

    AfterEach {
        Set-Location -LiteralPath $script:originalLocation
        $global:LASTEXITCODE = $script:originalExit
        if ($null -ne $script:originalDocker) { Set-Item -Path Function:global:docker -Value $script:originalDocker.ScriptBlock }
        else { Remove-Item Function:global:docker -ErrorAction SilentlyContinue }
        foreach ($item in Get-ChildItem Env:) {
            if (-not $script:originalEnvironment.ContainsKey($item.Name)) { Remove-Item -LiteralPath "Env:$($item.Name)" }
        }
        foreach ($name in $script:originalEnvironment.Keys) { Set-Item -LiteralPath "Env:$name" -Value $script:originalEnvironment[$name] }
    }

    It 'passes credential data to login without interpreting or logging it for <Registry>' -ForEach @(
        @{ Registry = 'harbor.example.com/team/image'; PasswordVariable = 'YURUNA_REGISTRY_PASSWORD' }
        @{ Registry = 'docker.io/team/image'; PasswordVariable = 'YURUNA_DOCKER_HUB_PASSWORD' }
    ) {
        $root = Join-Path $TestDrive ($PasswordVariable.ToLowerInvariant())
        New-ComponentExecutionFixture -Root $root
        [Environment]::SetEnvironmentVariable('testRegistry.registryLocation', $Registry)
        $secret = [Environment]::GetEnvironmentVariable($PasswordVariable)
        $result = Publish-ComponentList $root lab
        Assert-True $result.success $result.errorMessage
        Assert-StringEqual $secret (Get-Content -LiteralPath $env:componentPasswordCapture)
        Assert-True (Test-Path -LiteralPath $env:componentPushMarker)
        $log = Get-Content -Raw -LiteralPath "$root/.yuruna/lab/components/docker.stderr.log"
        Assert-False ($log.Contains($secret)) 'registry credentials must not be written into diagnostics'
        Assert-True ($log.Contains('[registryLogin[sample]] <command withheld>'))
    }

    It 'does not push after failed login and keeps its failure diagnostics free of credentials' {
        $root = Join-Path $TestDrive 'login-failure'
        New-ComponentExecutionFixture -Root $root
        $env:componentLoginExit = '42'
        $result = Publish-ComponentList $root lab
        Assert-False $result.success
        Assert-Equal 42 $result.exitCode
        Assert-False (Test-Path -LiteralPath $env:componentPushMarker)
        Assert-False ($result.errorMessage.Contains($env:YURUNA_REGISTRY_PASSWORD))
        Assert-False ((Get-Content -Raw -LiteralPath "$root/.yuruna/lab/components/docker.stderr.log").Contains($env:YURUNA_REGISTRY_PASSWORD))
    }

    It 'restores the caller location after a failing <Phase>' -ForEach @(
        @{ Phase = 'preProcessor'; Pre = 'Set-Variable -Name LASTEXITCODE -Value 41 -Scope Global'; Build = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'; Post = '' }
        @{ Phase = 'build'; Pre = ''; Build = 'Set-Variable -Name LASTEXITCODE -Value 42 -Scope Global'; Post = '' }
        @{ Phase = 'postProcessor'; Pre = ''; Build = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'; Post = 'Set-Variable -Name LASTEXITCODE -Value 43 -Scope Global' }
    ) {
        $root = Join-Path $TestDrive $Phase
        New-ComponentExecutionFixture -Root $root -Build $Build -Pre $Pre -Post $Post
        $result = Publish-ComponentList $root lab
        Assert-False $result.success
        Assert-StringEqual $script:originalLocation (Get-Location).Path
    }

    It 'restores the caller location after a command throws' {
        $root = Join-Path $TestDrive 'exception'
        New-ComponentExecutionFixture -Root $root -Build 'throw "fixture failure"'
        Assert-Throw { Publish-ComponentList $root lab } -Match 'fixture failure'
        Assert-StringEqual $script:originalLocation (Get-Location).Path
    }
}
