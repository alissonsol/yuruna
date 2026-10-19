<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42d58adc-cab7-4fe8-b412-b22f9af0785c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host consistency pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

<#
.SYNOPSIS
    Verify matching host contract regions and discoverable function help.
.DESCRIPTION
    Parses every provider and loads isolated function definitions so help can
    be checked without importing a driver or operating a hypervisor.
#>

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $script:RepoRoot 'host/Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
    $script:Contract = (Get-YurunaHostContractVerb) + @('Resolve-HostTag', 'Resolve-CacheHostIp', 'Save-CachedHttpUri')
    $script:ProviderSources = @{}
    foreach ($provider in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
        $path = Join-Path $script:RepoRoot "host/$provider/modules/Yuruna.Host.psm1"
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        if ($errors) { throw "$path does not parse: $($errors[0].Message)" }
        $script:ProviderSources[$provider] = @{ Text = [IO.File]::ReadAllText($path); Ast = $ast }
    }
}

Describe 'Host contract navigation and help' {
    It 'marks every shared contract function directly on <Provider>' -ForEach @(
        @{ Provider = 'windows.hyper-v' }, @{ Provider = 'macos.utm' }, @{ Provider = 'ubuntu.kvm' }
    ) {
        $source = $script:ProviderSources[$Provider]
        foreach ($name in $script:Contract) {
            $definitions = @($source.Ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true))
            $definitions.Count | Should -Be 1 -Because "$Provider exports one implementation of $name"
            $definition = $definitions[0]
            $prefix = $source.Text.Substring(0, $definition.Extent.StartOffset)
            $prefix | Should -Match ('# --- REGION: ' + [regex]::Escape($name) + '\r?\n$')
            $help = $definition.GetHelpContent()
            $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$Provider/$name keeps its existing command help"
            $body = $definition.Body.Extent.Text
            $body | Should -Match '^\{\r?\n[ \t]+<#' -Because 'function help precedes attributes and parameter binding'
        }
    }

    It 'discovers command help for <Name> on <Provider>' -ForEach @(
        @{ Provider = 'windows.hyper-v'; Name = 'New-VM' },
        @{ Provider = 'windows.hyper-v'; Name = 'Start-VM' },
        @{ Provider = 'windows.hyper-v'; Name = 'Stop-VMForce' },
        @{ Provider = 'macos.utm'; Name = 'New-VM' },
        @{ Provider = 'macos.utm'; Name = 'Start-VM' },
        @{ Provider = 'macos.utm'; Name = 'Stop-VMForce' },
        @{ Provider = 'ubuntu.kvm'; Name = 'New-VM' },
        @{ Provider = 'ubuntu.kvm'; Name = 'Start-VM' },
        @{ Provider = 'ubuntu.kvm'; Name = 'Stop-VMForce' }
    ) {
        $definition = $script:ProviderSources[$Provider].Ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        $expected = $definition.GetHelpContent().Synopsis.Trim()
        $actual = & {
            param($DefinitionText, $CommandName)
            . ([scriptblock]::Create($DefinitionText))
            (Get-Help -Name $CommandName -ErrorAction Stop).Synopsis.Trim()
        } $definition.Extent.Text $Name
        $actual | Should -BeExactly $expected
    }
}

Describe 'Shared host setup and helper boundaries' {
    It 'keeps the shared download and provisioning imports in the same marked block' {
        $expected = $null
        foreach ($provider in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            $source = $script:ProviderSources[$provider].Text
            $block = [regex]::Match($source, '(?ms)^# --- REGION: Shared host modules\r?\n(?<block>.*?Yuruna\.HostProvision\.psm1[^\r\n]*)')
            $block.Success | Should -BeTrue -Because "$provider keeps the shared host-module dependencies together"
            $normalized = $block.Groups['block'].Value.Replace('\', '/') -replace '\r\n', "`n"
            if ($null -eq $expected) { $expected = $normalized }
            $normalized | Should -BeExactly $expected -Because 'scope, ordering and documentation are shared across providers'
        }
    }

    It 'keeps the restoration shim identical across providers' {
        $expected = $null
        foreach ($provider in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
            $path = Join-Path $script:RepoRoot "host/$provider/Disable-TestAutomation.ps1"
            $text = [IO.File]::ReadAllText($path)
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $definition = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restore-Knob'
                }, $true)
            $definition | Should -Not -BeNullOrEmpty
            $text.Substring(0, $definition.Extent.StartOffset) | Should -Match '# --- REGION: Restore-Knob\r?\n$'
            $body = $definition.Extent.Text -replace '\r\n', "`n"
            if ($null -eq $expected) { $expected = $body }
            $body | Should -BeExactly $expected -Because 'all platforms pass the captured state and script-bound ShouldProcess through the same shim'
        }
    }
}

Describe 'UTM shared service template' {
    It 'keeps all service hardware templates identical with sizing supplied by the builders' {
        $expected = $null
        foreach ($service in 'caching-proxy-service', 'download-agent-service', 'pool-control-service', 'stash-service') {
            $path = Join-Path $script:RepoRoot "host/macos.utm/guest.$service/config.plist.template"
            $text = [IO.File]::ReadAllText($path) -replace '\r\n', "`n"
            [xml]$text | Should -Not -BeNullOrEmpty
            if ($null -eq $expected) { $expected = $text }
            $text | Should -BeExactly $expected -Because 'VM identity, memory, CPU and network values are injected by the common service builder'
        }
    }
}
