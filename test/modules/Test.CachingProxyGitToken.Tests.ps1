<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d72ff5-6cb1-4b14-bcba-89b71d42a68f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching-proxy git-mirror github token pester
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

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.CachingProxyService.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:English = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'globalization/catalogs/en-US/runner.json') -Raw | ConvertFrom-Json -AsHashtable).messages
    & (Get-Module Test.CachingProxyService) {
        # Define the provider boundaries without loading an actual provider or
        # touching this checkout's vault. Every test replaces these with mocks.
        function script:Import-Extension { param($Area, [switch]$RequireSingle) $null = $Area, $RequireSingle; throw 'Unexpected authentication import' }
        function script:Get-EffectiveUser { param($LogicalUser) $null = $LogicalUser; throw 'Unexpected mapping read' }
        function script:Test-VaultEntry { param($VaultKey) $null = $VaultKey; throw 'Unexpected vault read' }
        function script:Get-Password { param($Username) $null = $Username; throw 'Token generation is forbidden' }
        function script:Set-Password {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fixture boundary never writes to a real provider.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Fixture matches the existing vault API using synthetic values.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Fixture matches the existing vault API using synthetic values.')]
            [CmdletBinding()]
            param($Username, $NewPassword)
            $null = $Username, $NewPassword
            throw 'Unexpected vault write'
        }
        function script:Set-UserVaultKey {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Fixture boundary never writes to a real provider.')]
            [CmdletBinding(SupportsShouldProcess)]
            param($LogicalUser, $VaultKey)
            $null = $LogicalUser, $VaultKey
            throw 'Unexpected mapping write'
        }
    }
    $startAst = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/service/Start-CachingProxyServiceVM.ps1')
    $tokenStep = $startAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Initialize-CachingProxyGitMirrorToken')
    } | Select-Object -First 1
    $relaunch = $startAst.EndBlock.Statements | Where-Object {
        $_.Extent.Text.StartsWith('Invoke-LibvirtGroupReExecIfNeeded ')
    } | Select-Object -First 1
    $adopt = $startAst.FindAll({ param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if (-not $ForceRebuild)')
    }, $true) | Select-Object -First 1
    $script:StartDecisions = if ($tokenStep -and $relaunch) { [scriptblock]::Create($tokenStep.Extent.Text + "`n" + $relaunch.Extent.Text) } else { $null }
    $script:AdoptCondition = if ($adopt) { [scriptblock]::Create($adopt.Clauses[0].Item1.Extent.Text) } else { $null }

    function Invoke-TokenStartFixture {
        [CmdletBinding()]
        param()
        if (-not $script:StartDecisions -or -not $script:AdoptCondition) {
            throw 'Start-CachingProxyServiceVM is missing token configuration or its lifecycle decisions.'
        }
        $ForceRebuild = $false
        function Get-HostType { 'host.ubuntu.kvm' }
        function Invoke-LibvirtGroupReExecIfNeeded {
            param([string]$HostType, [string]$ScriptPath, $BoundParameters)
            $null = $HostType, $ScriptPath
            $script:RelaunchCalls++
            $script:ForwardedRebuild = [bool]$BoundParameters['ForceRebuild']
        }
        . $script:StartDecisions
        [pscustomobject]@{ ForceRebuild = [bool]$ForceRebuild; AdoptAllowed = [bool](& $script:AdoptCondition) }
    }
}

Describe 'optional GitHub mirror token configuration' {
    BeforeEach {
        $script:PreviousRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
        $script:CanPrompt = $true
        $script:Reply = ''
        $script:Reads = [Collections.Generic.List[object]]::new()
        $script:Events = [Collections.Generic.List[string]]::new()
        $script:Entries = @{}
        $script:Mappings = @{}
        $script:Failure = ''
        $script:ForwardedRebuild = $false
        $script:RelaunchCalls = 0
        $script:Reports = [Collections.Generic.List[object]]::new()
        Mock Test-YurunaCanPrompt -ModuleName Test.CachingProxyService { $script:CanPrompt }
        Mock Read-Host -ModuleName Test.CachingProxyService {
            param($Prompt, [switch]$AsSecureString)
            $script:Reads.Add(@{ Prompt = $Prompt; Secure = [bool]$AsSecureString })
            if ($null -eq $script:Reply) { return $null }
            $secure = [Security.SecureString]::new()
            foreach ($character in $script:Reply.ToCharArray()) { $secure.AppendChar($character) }
            return $secure
        }
        Mock Import-Module -ModuleName Test.CachingProxyService { $script:Events.Add('module') }
        Mock Import-Extension -ModuleName Test.CachingProxyService {
            if ($script:Failure -eq 'import') { throw "Provider leaked $script:Reply" }
            $script:Events.Add('provider'); 'default'
        }
        Mock Get-EffectiveUser -ModuleName Test.CachingProxyService {
            param($LogicalUser)
            if ($script:Failure -eq 'metadata') { throw "Provider leaked $script:Reply" }
            @{ vaultKey = [string]$script:Mappings[$LogicalUser] }
        }
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService {
            param($VaultKey)
            $script:Entries.ContainsKey($VaultKey) -and -not [string]::IsNullOrEmpty($script:Entries[$VaultKey].password)
        }
        Mock Get-Password -ModuleName Test.CachingProxyService { throw 'Optional tokens must never be auto-generated or retrieved for comparison.' }
        Mock Set-Password -ModuleName Test.CachingProxyService {
            if ($script:Failure -eq 'write') { throw "Provider leaked $NewPassword" }
            $previous = if ($script:Entries.ContainsKey($Username)) { $script:Entries[$Username].password } else { '' }
            $script:Entries[$Username] = @{ password = $NewPassword; previousPassword = $previous }
            $script:Events.Add("write:$Username")
        }
        Mock Set-UserVaultKey -ModuleName Test.CachingProxyService {
            param($LogicalUser, $VaultKey)
            if ($script:Failure -eq 'mapping') { throw "Provider leaked $script:Reply" }
            $script:Mappings[$LogicalUser] = $VaultKey
            $script:Events.Add("map:$LogicalUser"); $true
        }
        Mock Format-YurunaOperatorMessage -ModuleName Test.CachingProxyService {
            param($Key, $Arguments)
            $message = [string]$script:English[$Key].message
            if (-not $message) { throw "Missing English message $Key" }
            if ($Arguments) { foreach ($keyName in $Arguments.Keys) { $message = $message.Replace("{$keyName}", [string]$Arguments[$keyName]) } }
            $message
        }
        Mock Write-Information -ModuleName Test.CachingProxyService {
            param($MessageData)
            $script:Reports.Add(@{ Message = [string]$MessageData; Writes = @($script:Events | Where-Object { $_ -like 'write:*' }).Count })
        }
    }
    AfterEach { $env:YURUNA_RUNTIME_DIR = $script:PreviousRuntime }

    It 'keeps anonymous access on Enter without initializing the authentication provider' {
        $result = @(Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 1 $result.Count 'the return stream contains only one boolean'
        Assert-False $result[0]
        Assert-True ($result[0] -is [bool])
        Assert-Equal 1 $script:Reads.Count
        Assert-True $script:Reads[0].Secure
        Assert-Equal 0 $script:Events.Count
    }
    It 'keeps stored authentication on Enter without reading or rewriting the token' {
        $script:Mappings['github-mirror-token'] = 'operator.github'
        $script:Entries['operator.github'] = @{ password = 'fixture-old-token' }
        Assert-False (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 'fixture-old-token' $script:Entries['operator.github'].password
        Assert-Equal 0 $script:Events.Count
        Should -Invoke Get-Password -ModuleName Test.CachingProxyService -Times 0 -Exactly
    }
    It 'treats closed optional input as preserving current authentication' {
        $script:Reply = $null
        Assert-False (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 1 $script:Reads.Count
        Assert-Equal 0 $script:Events.Count
    }
    It 'never reads input or initializes authentication when no operator can prompt' {
        $script:CanPrompt = $false
        Assert-False (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 0 $script:Reads.Count
        Assert-Equal 0 $script:Events.Count
    }
    It 'does not prompt or write under WhatIf' {
        Assert-False (Initialize-CachingProxyGitMirrorToken -WhatIf)
        Assert-Equal 0 $script:Reads.Count
        Assert-Equal 0 $script:Events.Count
    }
    It 'preserves an operator vault mapping and reports masked replacement before writing' {
        $script:Reply = 'fixture-new-token'
        $script:Mappings['github-mirror-token'] = 'operator.github'
        $script:Entries['operator.github'] = @{ password = 'fixture-old-token' }
        Assert-True (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 'operator.github' $script:Mappings['github-mirror-token']
        Assert-Equal 'fixture-new-token' $script:Entries['operator.github'].password
        Assert-Equal 'fixture-old-token' $script:Entries['operator.github'].previousPassword
        $replacement = @($script:Reports | Where-Object { $_.Message -like '*stored token*->*operator-supplied token*' })
        Assert-Equal 1 $replacement.Count
        Assert-Equal 0 $replacement[0].Writes 'the replacement report precedes the provider write'
        Assert-True (($script:Reports.Message -join "`n") -like '*15 minutes*discards the warm cache*')
        Assert-False (($script:Reports.Message -join "`n") -match 'fixture-(old|new)-token')
        Should -Invoke Set-UserVaultKey -ModuleName Test.CachingProxyService -Times 0 -Exactly
        Should -Invoke Get-Password -ModuleName Test.CachingProxyService -Times 0 -Exactly
    }
    It 'stores an explicit token under the logical key and publishes a nonempty mapping' {
        $script:Reply = 'fixture-new-token'
        Assert-True (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 'github-mirror-token' $script:Mappings['github-mirror-token']
        Assert-Equal 'fixture-new-token' $script:Entries['github-mirror-token'].password
        Assert-True (($script:Events -join ',') -like '*write:github-mirror-token,map:github-mirror-token*')
    }
    It 'preserves a padded custom vault key exactly through token storage and protected seed generation' {
        $script:Reply = 'fixture-padded-token'
        $script:Mappings['github-mirror-token'] = ' operator.github '
        $script:Entries[' operator.github '] = @{ password = 'fixture-old-token' }
        Assert-True (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Assert-Equal 'fixture-padded-token' $script:Entries[' operator.github '].password
        Assert-False $script:Entries.ContainsKey('operator.github') 'the writer must use the same untrimmed key as the seed reader'
        Should -Invoke Set-UserVaultKey -ModuleName Test.CachingProxyService -Times 0 -Exactly
        Mock Get-Password -ModuleName Test.CachingProxyService {
            param($Username)
            $key = if ($script:Mappings[$Username]) { $script:Mappings[$Username] } else { $Username }
            $script:Entries[$key].password
        }
        $seed = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:RepoRoot -Config @{}
        Assert-Equal 'fixture-padded-token' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seed.TokenBase64)))
    }
    It 'requests application even when the explicit token equals the host vault entry' {
        $script:Reply = 'fixture-same-token'
        $script:Mappings['github-mirror-token'] = 'github-mirror-token'
        $script:Entries['github-mirror-token'] = @{ password = 'fixture-same-token' }
        Assert-True (Initialize-CachingProxyGitMirrorToken -Confirm:$false) 'a host vault value is not evidence that the VM uses that value'
        Should -Invoke Get-Password -ModuleName Test.CachingProxyService -Times 0 -Exactly
    }
    It 'makes the explicit token available through the real protected seed generator' {
        $script:Reply = 'fixture-seed-token'
        Assert-True (Initialize-CachingProxyGitMirrorToken -Confirm:$false)
        Mock Get-Password -ModuleName Test.CachingProxyService {
            param($Username)
            $key = if ($script:Mappings[$Username]) { $script:Mappings[$Username] } else { $Username }
            $script:Entries[$key].password
        }
        $seed = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:RepoRoot -Config @{}
        Assert-Equal 'fixture-seed-token' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seed.TokenBase64)))
        Assert-False (($script:Reports.Message -join "`n") -match 'fixture-seed-token')
    }
    It 'rejects a token containing <Label> without provider access or secret output' -TestCases @(
        @{ Label = 'space'; Value = 'fixture bad-token' }, @{ Label = 'newline'; Value = "fixture`nbad-token" },
        @{ Label = 'control character'; Value = "fixture`0bad-token" }, @{ Label = 'double quote'; Value = 'fixture"bad-token' },
        @{ Label = 'single quote'; Value = "fixture'bad-token" }, @{ Label = 'backslash'; Value = 'fixture\bad-token' }
    ) {
        param($Label, $Value)
        $null = $Label
        $script:Reply = $Value
        $failure = ''
        try { Initialize-CachingProxyGitMirrorToken -Confirm:$false } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*unsupported characters*')
        Assert-False $failure.Contains($Value)
        Assert-Equal 0 $script:Events.Count
        Assert-False (($script:Reports.Message -join "`n").Contains($Value))
    }
    It 'sanitizes a provider failure during <Phase> without reporting success' -TestCases @(
        @{ Phase = 'import' }, @{ Phase = 'metadata' }, @{ Phase = 'write' }, @{ Phase = 'mapping' }
    ) {
        param($Phase)
        $script:Reply = 'fixture-private-token'
        $script:Failure = $Phase
        $failure = ''
        try { Initialize-CachingProxyGitMirrorToken -Confirm:$false } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*Could not configure*')
        Assert-False ($failure -like '*fixture-private-token*')
        Assert-False (($script:Reports.Message -join "`n") -like '*fixture-private-token*')
    }
    It 'forwards a supplied-token rebuild through the actual Start script relaunch and adoption decisions' {
        $script:Reply = 'fixture-new-token'
        $result = Invoke-TokenStartFixture
        Assert-True $result.ForceRebuild
        Assert-True $script:ForwardedRebuild 'the noninteractive libvirt child must retain the requested rebuild'
        Assert-False $result.AdoptAllowed 'a healthy VM must not preserve its old baked authentication'
    }
    It 'retains the actual Start script adoption path when Enter preserves authentication' {
        $result = Invoke-TokenStartFixture
        Assert-False $result.ForceRebuild
        Assert-False $script:ForwardedRebuild
        Assert-True $result.AdoptAllowed
        Assert-Equal 0 $script:Events.Count
    }
    It 'stops the actual Start script before relaunch or adoption when storing the explicit token fails' {
        $script:Reply = 'fixture-private-token'
        $script:Failure = 'write'
        Assert-Throw { Invoke-TokenStartFixture } 'Could not configure'
        Assert-Equal 0 $script:RelaunchCalls
        Assert-False $script:ForwardedRebuild
        Assert-False (($script:Reports.Message -join "`n") -match 'fixture-private-token')
    }
}
