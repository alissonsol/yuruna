<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d688a7-5a4c-4a38-bf7b-1bde823ce93b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna setup storage credentials nas pester
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
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    $setupAst = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'install/setup.ps1')
    foreach ($wanted in @('Resolve-SetupNasStorageTier', 'Set-SetupNasStorageConfig', 'Initialize-SetupNasCredential',
                          'Invoke-SetupNasStorage', 'Initialize-SetupElevation')) {
        $name = $wanted
        $definition = $setupAst.FindAll({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }.GetNewClosure(), $true) | Select-Object -First 1
        if (-not $definition) { throw "setup.ps1 does not define $wanted" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Only the setup functions are real here. OS mounts, sudo, vault writes, and
    # terminal input are recording stand-ins, so the suite cannot change a host.
    function Write-SetupMessage {
        param([AllowEmptyString()][string]$Message = '')
        $script:Messages.Add($Message)
        if ($script:ReportConfigPath -and (Test-Path -LiteralPath $script:ReportConfigPath)) {
            $script:ContentsAtReport.Add([IO.File]::ReadAllText($script:ReportConfigPath))
        }
    }
    function Write-SetupDetail { param([string]$Message) $script:Messages.Add($Message) }
    function Write-SetupWarning { param([string]$Message) $script:Messages.Add($Message) }
    function Write-SetupVerbose { param([string]$Message) $script:Messages.Add($Message) }
    function Format-YurunaOperatorMessage { param([string]$Key, [hashtable]$Arguments) $null = $Arguments; $Key }
    function Import-SetupModule { param([string]$Name) $null = $Name }
    function Get-YurunaMachineCredential { param([string]$LogicalUser) [string]$script:Stored[$LogicalUser] }
    function Get-EffectiveUser { param([string]$LogicalUser) @{ vaultKey = [string]$script:Mapped[$LogicalUser] } }
    function Set-UserVaultKey {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Recording stand-in accepts production common parameters but changes no external state.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$LogicalUser, [string]$VaultKey)
        $script:Mapped[$LogicalUser] = $VaultKey
    }
    function Set-Password {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Recording stand-in accepts production common parameters but changes no external state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Recording stand-in must match the vault API; values are synthetic test fixtures.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Recording stand-in must match the vault API; values are synthetic test fixtures.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Username, [string]$NewPassword)
        $script:Saved.Add(@{ User = $Username; Value = $NewPassword })
    }
    function Read-Host {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Recording stand-in prevents real terminal input and verifies every password prompt is secure.')]
        param([string]$Prompt, [switch]$AsSecureString)
        $script:Prompts.Add(@{ Prompt = $Prompt; Secure = [bool]$AsSecureString })
        if (-not $AsSecureString) { throw 'SMB credentials must use a secure prompt' }
        if ($script:Replies.Count -eq 0) { throw 'Unexpected credential prompt' }
        $secure = [Security.SecureString]::new()
        foreach ($character in $script:Replies.Dequeue().ToCharArray()) { $secure.AppendChar($character) }
        return $secure
    }
    function Test-YurunaCanPrompt { $script:CanPrompt }
    function sudo { $script:SudoCalls.Add(($args -join ' ')); $global:LASTEXITCODE = $script:SudoExitCode }
    function Set-PoolStorageSudoers {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Recording stand-in accepts production common parameters but changes no external state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Recording stand-in must match the sudoers installer API.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([switch]$NonInteractive)
        $script:SudoersCalls.Add([bool]$NonInteractive)
        $script:SudoersResult
    }
    function Connect-YurunaPoolStorage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Recording stand-in accepts production common parameters but changes no external state.')]
        [CmdletBinding(SupportsShouldProcess)]
        param($Config)
        $script:MountCalls.Add($Config)
        return $Config.NetworkUser -ne $script:FailUser
    }
    function Get-PoolStorageLastMountError { 'mount error(13): Permission denied' }
    function Initialize-StorageFixture {
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:ContentsAtReport = [Collections.Generic.List[string]]::new()
        $script:ReportConfigPath = ''
        $script:Stored = @{}
        $script:Mapped = @{}
        $script:Saved = [Collections.Generic.List[object]]::new()
        $script:Prompts = [Collections.Generic.List[object]]::new()
        $script:Replies = [Collections.Generic.Queue[string]]::new()
        $script:CanPrompt = $true
        $script:Unattended = $false
        $script:SudoExitCode = 1
        $script:SudoCalls = [Collections.Generic.List[string]]::new()
        $script:SudoersCalls = [Collections.Generic.List[bool]]::new()
        $script:SudoersResult = @{ Action = 'installed'; Message = 'fixture installed' }
        $script:MountCalls = [Collections.Generic.List[object]]::new()
        $script:FailUser = ''
        $script:Tier = @(
            [pscustomobject]@{ Kind = 'pool'; ConfigPrefix = 'poolStorage'; NetworkPath = '//nas-pool/work/pool'; NetworkUser = 'pool-user'; LocalPath = '/custom/pool' },
            [pscustomobject]@{ Kind = 'stash'; ConfigPrefix = 'stashStorage'; NetworkPath = '//nas-stash/work/stash'; NetworkUser = 'stash-user'; LocalPath = '/custom/stash' }
        )
        $script:Config = [ordered]@{ networkStorage = [ordered]@{
            poolStorageNetworkPath = '//nas-pool/work/pool'; poolStorageNetworkUser = 'pool-user'; poolStorageLocalPath = '/custom/pool'
            stashStorageNetworkPath = '//nas-stash/work/stash'; stashStorageNetworkUser = 'stash-user'; stashStorageLocalPath = '/custom/stash'
            moveLogsToPoolStorage = $false
        }; repositories = @{ projectUrl = 'file:///operator/project' } }
    }
}

Describe 'NAS storage coordinates' {
    BeforeEach { Initialize-StorageFixture }
    It 'keeps existing pool and stash coordinates when no replacement was supplied' {
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm')
        foreach ($i in 0..1) {
            Assert-Equal $script:Tier[$i].NetworkPath $tier[$i].NetworkPath
            Assert-Equal $script:Tier[$i].NetworkUser $tier[$i].NetworkUser
            Assert-Equal $script:Tier[$i].LocalPath $tier[$i].LocalPath
        }
    }
    It 'applies selected replacements while preserving custom local mount points' {
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm' `
            -NetworkPath '//replacement/pool' -NetworkUser 'replacement-pool' `
            -StashNetworkPath '//replacement/stash' -StashNetworkUser 'replacement-stash')
        Assert-Equal '//replacement/pool' $tier[0].NetworkPath
        Assert-Equal 'replacement-pool' $tier[0].NetworkUser
        Assert-Equal '//replacement/stash' $tier[1].NetworkPath
        Assert-Equal 'replacement-stash' $tier[1].NetworkUser
        Assert-Equal '/custom/pool' $tier[0].LocalPath
        Assert-Equal '/custom/stash' $tier[1].LocalPath
        Assert-Equal 'file:///operator/project' $script:Config.repositories.projectUrl
    }
    It 'fills blank mount points using the host platform conventions' {
        $script:Config.networkStorage.poolStorageLocalPath = ''
        $script:Config.networkStorage.stashStorageLocalPath = ''
        foreach ($platform in @('host.ubuntu.kvm', 'host.macos.utm', 'host.windows.hyper-v')) {
            $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType $platform)
            Assert-Equal (Get-ConfigSyncLocalPathDefault -HostType $platform -Tier pool -ServerName nas-pool) $tier[0].LocalPath
            Assert-Equal (Get-ConfigSyncLocalPathDefault -HostType $platform -Tier stash -ServerName nas-stash) $tier[1].LocalPath
        }
    }
    It 'gives two shares on the same NAS distinct conventional mount points' {
        $script:Config.networkStorage.poolStorageNetworkPath = '//nas/pool'
        $script:Config.networkStorage.stashStorageNetworkPath = '//nas/stash'
        $script:Config.networkStorage.poolStorageLocalPath = ''
        $script:Config.networkStorage.stashStorageLocalPath = ''
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm')
        Assert-Equal '/mnt/ypool-nas' $tier[0].LocalPath
        Assert-Equal '/mnt/ystash-nas' $tier[1].LocalPath
    }
    It 'keeps a configured mount point while moving only a colliding default' {
        $script:Config.networkStorage.poolStorageNetworkPath = '//nas/pool'
        $script:Config.networkStorage.stashStorageNetworkPath = '//nas/stash'
        $script:Config.networkStorage.poolStorageLocalPath = '/mnt/nas'
        $script:Config.networkStorage.stashStorageLocalPath = ''
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm')
        Assert-Equal '/mnt/nas' $tier[0].LocalPath
        Assert-Equal '/mnt/ystash-nas' $tier[1].LocalPath
    }
    It 'refuses configured mount collisions without replacing either operator value' {
        $script:Config.networkStorage.stashStorageLocalPath = '/custom/pool'
        Assert-Throw { Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm' } 'poolStorageLocalPath.*stashStorageLocalPath'
        Assert-Equal '/custom/pool' $script:Config.networkStorage.stashStorageLocalPath
    }
    It 'preserves operator values on disk when applying the resolved existing settings' {
        $path = Join-Path $TestDrive 'preserve.yml'
        $original = ConvertTo-Yaml $script:Config
        [IO.File]::WriteAllText($path, $original)
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm')
        $null = Set-SetupNasStorageConfig -ConfigPath $path -Tier $tier
        Assert-Equal $original ([IO.File]::ReadAllText($path))
        Assert-False (Test-Path -LiteralPath "$path.setup-storage.backup") 'no backup or rewrite for an unchanged file'
    }
    It 'reports replacements before writing and preserves comments and unrelated configuration' {
        $path = Join-Path $TestDrive 'replace.yml'
        $original = "# Operator configuration`n" + (ConvertTo-Yaml $script:Config)
        [IO.File]::WriteAllText($path, $original)
        $script:ReportConfigPath = $path
        $tier = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm' -NetworkPath '//new/pool' -StashNetworkPath '//new/stash')
        $null = Set-SetupNasStorageConfig -ConfigPath $path -Tier $tier
        $actual = [IO.File]::ReadAllText($path)
        $doc = ConvertFrom-Yaml $actual
        Assert-Equal '//new/pool' $doc.networkStorage.poolStorageNetworkPath
        Assert-Equal '//new/stash' $doc.networkStorage.stashStorageNetworkPath
        Assert-Equal 'file:///operator/project' $doc.repositories.projectUrl
        Assert-False $doc.networkStorage.moveLogsToPoolStorage 'the storage repair does not change the archival mode'
        Assert-True ($actual.StartsWith('# Operator configuration')) 'operator comments survive'
        Assert-True (($script:Messages -join "`n") -like '*poolStorageNetworkPath: //nas-pool/work/pool -> //new/pool*')
        Assert-True (($script:Messages -join "`n") -like '*stashStorageNetworkPath: //nas-stash/work/stash -> //new/stash*')
        Assert-True ($script:ContentsAtReport.Count -ge 2) 'both replacements are reported before writing'
        foreach ($seen in $script:ContentsAtReport) { Assert-Equal $original $seen 'the report precedes the disk change' }
        Assert-Equal $original ([IO.File]::ReadAllText("$path.setup-storage.backup"))
    }
    It 'does not write or create backups in a preview' {
        $path = Join-Path $TestDrive 'preview.yml'
        $original = ConvertTo-Yaml $script:Config
        [IO.File]::WriteAllText($path, $original)
        $script:Tier[0].NetworkPath = '//new/pool'
        $null = Set-SetupNasStorageConfig -ConfigPath $path -Tier $script:Tier -WhatIf
        Assert-Equal $original ([IO.File]::ReadAllText($path))
        Assert-False (Test-Path -LiteralPath "$path.setup-storage.backup")
    }
}

Describe 'NAS credentials before unattended work' {
    BeforeEach { Initialize-StorageFixture }
    It 'securely requests and stores the two distinct account passwords under their mapped keys' {
        $script:Mapped = @{ 'pool-user' = 'corporate.pool'; 'stash-user' = 'smb.stash-user' }
        $script:Replies.Enqueue('fixture-pool-password')
        $script:Replies.Enqueue('fixture-stash-password')
        Initialize-SetupNasCredential -Tier $script:Tier -Unattended $false
        Assert-Equal 2 $script:Prompts.Count
        Assert-True (@($script:Prompts | Where-Object { -not $_.Secure }).Count -eq 0)
        Assert-Equal 'corporate.pool' $script:Saved[0].User
        Assert-Equal 'smb.stash-user' $script:Saved[1].User
        Assert-Equal 'fixture-pool-password' $script:Saved[0].Value
        Assert-Equal 'fixture-stash-password' $script:Saved[1].Value
        Assert-False (($script:Messages -join "`n") -match 'fixture-(pool|stash)-password') 'passwords never reach reports'
    }
    It 'accepts Enter to keep existing credentials without rewriting the vault' {
        $script:Stored = @{ 'pool-user' = 'fixture-old-pool'; 'stash-user' = 'fixture-old-stash' }
        $script:Replies.Enqueue(''); $script:Replies.Enqueue('')
        Initialize-SetupNasCredential -Tier $script:Tier -Unattended $false
        Assert-Equal 2 $script:Prompts.Count
        Assert-Equal 0 $script:Saved.Count
    }
    It 'allows an operator to replace a stale stored password without changing its direct key' {
        $script:Stored = @{ 'pool-user' = 'fixture-old-pool'; 'stash-user' = 'fixture-old-stash' }
        $script:Replies.Enqueue('fixture-new-pool'); $script:Replies.Enqueue('')
        Initialize-SetupNasCredential -Tier $script:Tier -Unattended $false
        Assert-Equal 1 $script:Saved.Count
        Assert-Equal 'pool-user' $script:Saved[0].User
        Assert-Equal 'fixture-new-pool' $script:Saved[0].Value
    }
    It 'requests a shared account only once' {
        $script:Tier[1].NetworkUser = 'pool-user'
        $script:Replies.Enqueue('fixture-shared-password')
        Initialize-SetupNasCredential -Tier $script:Tier -Unattended $false
        Assert-Equal 1 $script:Prompts.Count
        Assert-Equal 1 $script:Saved.Count
    }
    It 'uses stored credentials unattended without prompts or vault writes' {
        $script:Stored = @{ 'pool-user' = 'fixture-old-pool'; 'stash-user' = 'fixture-old-stash' }
        $script:CanPrompt = $false
        Initialize-SetupNasCredential -Tier $script:Tier -Unattended $true
        Assert-Equal 0 $script:Prompts.Count
        Assert-Equal 0 $script:Saved.Count
    }
    It 'refuses a missing unattended credential without generating or storing a random password' {
        $script:CanPrompt = $false
        Assert-Throw { Initialize-SetupNasCredential -Tier $script:Tier -Unattended $true } 'pool-user'
        Assert-Equal 0 $script:Prompts.Count
        Assert-Equal 0 $script:Saved.Count
    }
    It 'does not prompt in a captured run without an answer file' {
        $script:CanPrompt = $false
        Assert-Throw { Initialize-SetupNasCredential -Tier $script:Tier -Unattended $false } 'pool-user'
        Assert-Equal 0 $script:Prompts.Count
    }
    It 'does not prompt or write credentials in a preview' {
        Initialize-SetupNasCredential -Tier $script:Tier -WhatIf
        Assert-Equal 0 $script:Prompts.Count
        Assert-Equal 0 $script:Saved.Count
    }
}

Describe 'both NAS mounts and their failures' {
    BeforeEach { Initialize-StorageFixture }
    It 'mounts the resolved pool and stash shares' {
        Invoke-SetupNasStorage -Tier $script:Tier
        Assert-Equal 2 $script:MountCalls.Count
        Assert-Equal '//nas-pool/work/pool' $script:MountCalls[0].NetworkPath
        Assert-Equal '//nas-stash/work/stash' $script:MountCalls[1].NetworkPath
    }
    It 'reports the stash path and actual mount error when the second tier fails' {
        $script:FailUser = 'stash-user'
        Assert-Throw { Invoke-SetupNasStorage -Tier $script:Tier } 'stash.*//nas-stash/work/stash.*Permission denied'
        Assert-Equal 2 $script:MountCalls.Count
    }
    It 'stops before mounting when Linux cannot install its noninteractive sudo rule' -Skip:(-not $IsLinux) {
        $script:SudoersResult = @{ Action = 'skipped'; Message = 'sudo is not authorized; run sudo -v' }
        Assert-Throw { Invoke-SetupNasStorage -Tier $script:Tier } 'sudo is not authorized'
        Assert-Equal 0 $script:MountCalls.Count
    }
    It 'applies selected answers on disk before the actual NAS step mounts both shares' {
        $ConfigPath = Join-Path $TestDrive 'wired.yml'
        [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Yaml $script:Config))
        $TestRoot = Join-Path $TestDrive 'test'
        $storageKind = 'nas'; $projectUrl = ''; $nasCredentialError = ''
        $nasStorageTiers = @(Resolve-SetupNasStorageTier -Config $script:Config -HostType 'host.ubuntu.kvm' `
            -NetworkPath '//selected/pool' -StashNetworkPath '//selected/stash')
        # The extracted production actions consume these through dynamic scope.
        $null = $TestRoot, $storageKind, $projectUrl, $nasCredentialError, $nasStorageTiers
        foreach ($namePart in @('Create or refresh test/test.config.yml', 'Mount the NAS share')) {
            $part = $namePart
            $call = $setupAst.FindAll({ param($n)
                $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SetupStep' -and
                $n.Extent.Text.Contains($part)
            }.GetNewClosure(), $true) | Select-Object -First 1
            if ($namePart.StartsWith('Create')) {
                $guard = $call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
                Assert-False (& ([scriptblock]::Create($guard.ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}')))) 'NAS repairs are not skipped when the project URL is unchanged'
            }
            $action = $call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -Last 1
            & ([scriptblock]::Create($action.ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}')))
        }
        $disk = ConvertFrom-Yaml ([IO.File]::ReadAllText($ConfigPath))
        Assert-Equal '//selected/pool' $disk.networkStorage.poolStorageNetworkPath
        Assert-Equal '//selected/stash' $disk.networkStorage.stashStorageNetworkPath
        Assert-Equal 2 $script:MountCalls.Count
        Assert-Equal $disk.networkStorage.poolStorageNetworkPath $script:MountCalls[0].NetworkPath
        Assert-Equal $disk.networkStorage.stashStorageNetworkPath $script:MountCalls[1].NetworkPath
    }
}

Describe 'setup sudo authorization' {
    BeforeEach { Initialize-StorageFixture }
    It 'does not request a native password when the terminal cannot prompt' -Skip:$IsWindows {
        $script:CanPrompt = $false
        $null = Initialize-SetupElevation
        Assert-Equal 1 $script:SudoCalls.Count
        Assert-Equal '-n -v' $script:SudoCalls[0]
    }
    It 'requests sudo directly once when an interactive authorization is needed' -Skip:$IsWindows {
        $null = Initialize-SetupElevation
        Assert-Equal 2 $script:SudoCalls.Count
        Assert-Equal '-n -v' $script:SudoCalls[0]
        Assert-Equal '-v' $script:SudoCalls[1]
    }
    It 'reuses an already authorized terminal without another password prompt' -Skip:$IsWindows {
        $script:SudoExitCode = 0
        Assert-True (Initialize-SetupElevation)
        Assert-Equal 1 $script:SudoCalls.Count
    }
}
