<#PSScriptInfo
.VERSION 2026.10.30
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
    Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.DriverSource.psm1') -Force -DisableNameChecking
    $script:Contract = (Get-YurunaHostContractVerb) + @('Resolve-HostTag', 'Resolve-CacheHostIp', 'Save-CachedHttpUri')
    $script:ProviderSources = @{}
    foreach ($provider in 'windows.hyper-v', 'macos.utm', 'ubuntu.kvm') {
        # The whole driver, part files included where the root loads them.
        $script:ProviderSources[$provider] = @{ Text = (Get-YurunaDriverText -Driver $provider); Ast = (Get-YurunaDriverAst -Driver $provider) }
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

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'host/Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
    # The contract returns its verb list as one array object.
    $verbs = Get-YurunaHostContractVerb
    $script:ContractVerbCase = @($verbs | ForEach-Object { @{ Name = $_ } })
}

Describe 'Host contract signatures agree across providers' {
    BeforeAll {
        # Optional parameters only some providers take, each with why. A
        # shared caller must not pass one unconditionally; a new divergence
        # fails until it is listed here with its reason.
        $script:PlatformParameter = @{
            'Stop-VMForce|Deadline'                         = 'UTM: a shared deadline across its utmctl stop and poll'
            'Add-PortMap|RuntimeDir'                        = 'Hyper-V: the runtime folder its port-map record lives in'
            'Remove-PortMap|RuntimeDir'                     = 'Hyper-V: the runtime folder its port-map record lives in'
            'Get-GuestReachableHostIp|SettleTimeoutSeconds' = 'Hyper-V: a just-created External vSwitch needs time to take an address'
            'Get-GuestReachableHostIp|NetworkMode'          = 'UTM: shared NAT and bridged guests reach the host at different addresses'
            'Set-HostProxy|NetworkService'                  = 'UTM: macOS proxy settings are per network service'
            'Remove-HostProxy|NetworkService'               = 'UTM: macOS proxy settings are per network service'
            'Test-VirtualizationResponsive|Corroborate'     = 'UTM: the lifecycle-verb probe the pre-cycle gate asks for'
            'Test-VirtualizationResponsive|DialogWindowSeconds' = 'UTM: the consent-dialog window of the lifecycle probe'
            'Test-VirtualizationResponsive|RecordedAutomationSubject' = 'UTM: the Apple Events subject recorded at setup'
            'Test-VirtualizationResponsive|IncludeInventory' = 'UTM: the VM listing the probe can return'
            'Test-VirtualizationResponsive|LifecycleProbe'  = 'UTM: the lifecycle-verb probe the pre-cycle gate asks for'
            'Test-VirtualizationResponsive|LifecycleProbePrefix' = 'UTM: the VM names the lifecycle probe may use'
            'Test-VirtualizationResponsive|LifecycleRetryWindowSeconds' = 'UTM: the retry window of the lifecycle probe'
        }
        $script:Signature = @{}
        $verbs = Get-YurunaHostContractVerb
        foreach ($provider in $script:ProviderSources.Keys) {
            foreach ($name in $verbs) {
                $definition = $script:ProviderSources[$provider].Ast.Find({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
                $parameters = @{}
                foreach ($parameter in @($definition.Body.ParamBlock.Parameters | Where-Object { $_ })) {
                    $mandatory = [bool]($parameter.Attributes | Where-Object {
                            $_.TypeName.Name -eq 'Parameter' -and @($_.NamedArguments.ArgumentName) -contains 'Mandatory' })
                    $parameters[$parameter.Name.VariablePath.UserPath] = @{ Mandatory = $mandatory; Type = [string]$parameter.StaticType.FullName }
                }
                $script:Signature["$provider|$name"] = $parameters
            }
        }
    }
    It '<Name> takes the same mandatory parameters, of the same types, on every provider' -ForEach $script:ContractVerbCase {
        $providers = @($script:ProviderSources.Keys | Sort-Object)
        $all = @($providers | ForEach-Object { $script:Signature["$_|$Name"].Keys } | Sort-Object -Unique)
        foreach ($parameter in $all) {
            $rows = @($providers | ForEach-Object { $script:Signature["$_|$Name"][$parameter] })
            $present = @($rows | Where-Object { $_ })
            if ($present.Count -lt $providers.Count) {
                $script:PlatformParameter.ContainsKey("$Name|$parameter") | Should -BeTrue -Because "-$parameter of $Name exists on only some providers and is not a listed platform parameter"
                @($present | Where-Object { $_.Mandatory }).Count | Should -Be 0 -Because "a parameter only some providers take cannot be mandatory ($Name -$parameter)"
                continue
            }
            @($present | ForEach-Object { $_.Mandatory } | Sort-Object -Unique).Count | Should -Be 1 -Because "$Name -$parameter is mandatory on some providers only"
            @($present | ForEach-Object { $_.Type } | Sort-Object -Unique).Count | Should -Be 1 -Because "$Name -$parameter has different types across providers"
        }
    }
    It 'lists only platform parameters that still exist' {
        foreach ($key in $script:PlatformParameter.Keys) {
            $name, $parameter = $key -split '\|'
            @($script:ProviderSources.Keys | Where-Object { $script:Signature["$_|$name"].ContainsKey($parameter) }).Count | Should -BeGreaterThan 0 -Because "$key is listed but no provider takes it"
        }
    }
}
