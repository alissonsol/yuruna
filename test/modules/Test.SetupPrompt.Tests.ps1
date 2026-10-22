<#PSScriptInfo
.VERSION 2026.10.22
.GUID 421b14e8-b8b1-46e2-825f-79867b90bd73
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna setup nas prompt pester
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
    $setupPath = Join-Path $repoRoot 'install/setup.ps1'
    $setupAst = Get-YurunaTestFileAst -Path $setupPath
    $commonAst = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'automation/Yuruna.Common.psm1')
    foreach ($source in @(
        @{ Ast = $setupAst; Names = @('Read-Text', 'Read-Choice', 'Get-Answer', 'Get-DecisionSource',
            'Resolve-SetupNasStorageTier', 'Test-SetupAnswerSet', 'Initialize-SetupNasCredential') },
        @{ Ast = $commonAst; Names = @('Assert-YurunaPromptable') }
    )) {
        foreach ($wanted in $source.Names) {
            $name = $wanted
            $definition = $source.Ast.FindAll({ param($n)
                $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
            }.GetNewClosure(), $true) | Select-Object -First 1
            if (-not $definition) { throw "The production script no longer defines $wanted" }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    # Execute the shipped questionnaire and validation together. Only external
    # input, config reads and vault writes are replaced: a helper-only test would
    # miss a required question whose actual caller forgot the required flag.
    $start = $setupAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$setupType'
    } | Select-Object -First 1
    $end = $setupAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if ($answerProblems.Count')
    } | Select-Object -First 1
    if (-not $start -or -not $end) { throw 'The setup questionnaire or its validation could not be located.' }
    $setupText = [IO.File]::ReadAllText($setupPath)
    $script:Questionnaire = [scriptblock]::Create($setupText.Substring($start.Extent.StartOffset, $end.Extent.EndOffset - $start.Extent.StartOffset))
    $credentialStep = $setupAst.FindAll({ param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Extent.Text.StartsWith("if (`$storageKind -eq 'nas'") -and $n.Extent.Text.Contains('Initialize-SetupNasCredential')
    }, $true) | Select-Object -First 1
    if (-not $credentialStep) { throw 'The setup NAS credential preparation step could not be located.' }
    $script:CredentialStep = [scriptblock]::Create($credentialStep.Extent.Text)

    function Write-SetupMessage { param([AllowEmptyString()][string]$Message = '') $script:Messages.Add($Message) }
    function Write-SetupLogLine { param([string]$Level, [AllowEmptyString()][string]$Message = '') $script:Messages.Add("${Level}: $Message") }
    function Write-SetupDetail { param([string]$Message) $script:Messages.Add($Message) }
    function Write-SetupWarning { param([string]$Message) $script:Messages.Add($Message) }
    function Write-SetupError { param([string]$Message) $script:Messages.Add($Message) }
    function Format-YurunaOperatorMessage { param([string]$Key, [hashtable]$Arguments) $null = $Arguments; $Key }
    function Add-SetupDecision { param([string]$Name, $Value, [string]$Source) $null = $Name, $Value, $Source }
    function Exit-Setup { param([int]$Code) throw "setup-exit-$Code" }
    function Import-SetupModule { param([string]$Name) $null = $Name }
    function Import-Extension { param([string]$Area, [switch]$RequireSingle) $null = $Area, $RequireSingle; $script:AuthenticationImports++; 'default' }
    function Read-TestConfig { param([string]$Path, [switch]$NoCache) $null = $Path, $NoCache; $script:Config }
    function Test-YurunaCanPrompt { $script:CanPrompt }
    function Read-Host {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Recording input boundary prevents actual terminal reads and exercises the shipped questionnaire with queued replies.')]
        param([string]$Prompt, [switch]$AsSecureString)
        $script:Reads.Add([pscustomobject]@{ Prompt = $Prompt; Secure = [bool]$AsSecureString })
        if ($script:Replies.Count -eq 0) { return $null }
        $reply = $script:Replies.Dequeue()
        if ($null -eq $reply) { return $null }
        if (-not $AsSecureString) { return [string]$reply }
        $secure = [Security.SecureString]::new()
        foreach ($character in ([string]$reply).ToCharArray()) { $secure.AppendChar($character) }
        return $secure
    }
    function Get-YurunaMachineCredential { param([string]$LogicalUser) [string]$script:Stored[$LogicalUser] }
    function Get-EffectiveUser { param([string]$LogicalUser) $null = $LogicalUser; @{ vaultKey = '' } }
    function Set-UserVaultKey {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Fixture accepts production common parameters and writes no external state.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$LogicalUser, [string]$VaultKey)
        $null = $LogicalUser, $VaultKey
    }
    function Set-Password {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Recording stand-in matches the existing vault API with synthetic fixture values.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Recording stand-in matches the existing vault API with synthetic fixture values.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Fixture accepts production common parameters and writes no external state.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Username, [string]$NewPassword)
        $script:Saved.Add(@{ Username = $Username; Value = $NewPassword })
    }
    function Initialize-PromptFixture {
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Reads = [Collections.Generic.List[object]]::new()
        $script:Replies = [Collections.Generic.Queue[object]]::new()
        $script:Saved = [Collections.Generic.List[object]]::new()
        $script:Stored = @{}
        $script:AuthenticationImports = 0
        $script:CanPrompt = $true
        $script:Unattended = $false
        $script:Answers = $null
        $script:Config = [ordered]@{ networkStorage = [ordered]@{
            poolStorageNetworkPath = '//ypool-nas/work'; poolStorageNetworkUser = 'yuruna-pool'; poolStorageLocalPath = '/custom/pool'
            stashStorageNetworkPath = ''; stashStorageNetworkUser = ''; stashStorageLocalPath = ''
        } }
        $script:FixtureConfigPath = Join-Path $TestDrive 'test.config.yml'
        [IO.File]::WriteAllText($script:FixtureConfigPath, '# Fixture existence; Read-TestConfig supplies the parsed document.')
    }
    function Invoke-QuestionnaireFixture {
        param([switch]$PrepareCredentials)
        $ConfigPath = $script:FixtureConfigPath
        $TestRoot = Join-Path $TestDrive 'test'
        $HostType = 'host.ubuntu.kvm'
        $DefaultProjectUrl = 'https://example.invalid/project'
        $AnswerFile = if ($script:Unattended) { 'fixture-answers.yml' } else { '' }
        $answers = $script:Answers
        $nasCredentialError = ''
        # The extracted production statements consume these through dynamic scope.
        $null = $ConfigPath, $TestRoot, $HostType, $DefaultProjectUrl, $AnswerFile, $answers
        . $script:Questionnaire
        if ($PrepareCredentials) { . $script:CredentialStep }
        [pscustomobject]@{ PoolPath = $storageNetworkPath; StashPath = $storageStashNetworkPath
            PoolUser = $storageNetworkUser; StashUser = $storageStashNetworkUser; Tiers = @($nasStorageTiers)
            Problems = @($answerProblems); CredentialError = $nasCredentialError; LabName = $labName }
    }
}

Describe 'setup NAS questionnaire recovery' {
    BeforeEach { Initialize-PromptFixture }
    It 'reasks an empty stash path immediately and reaches secure credential preparation' {
        foreach ($reply in @('2', '2', '2', '//ypool-nas/work/yuruna.pool', '', '', '//ystash-nas/work/yuruna.stash', '', '', 'fixture-pool-password', 'fixture-stash-password')) {
            $script:Replies.Enqueue($reply)
        }
        $result = Invoke-QuestionnaireFixture -PrepareCredentials
        Assert-Equal '//ypool-nas/work/yuruna.pool' $result.PoolPath
        Assert-Equal '//ystash-nas/work/yuruna.stash' $result.StashPath
        Assert-Equal 0 $result.Problems.Count
        Assert-Equal '' $result.CredentialError
        Assert-Equal 1 $script:AuthenticationImports
        Assert-Equal 2 @($script:Reads | Where-Object Secure).Count
        Assert-Equal 2 $script:Saved.Count
        Assert-True ($script:Reads[5].Prompt -like '*stash*')
        Assert-Equal $script:Reads[5].Prompt $script:Reads[6].Prompt 'the same required field is retried before later questions'
        Assert-True (($script:Messages -join "`n") -match 'stashNetworkPath.*required') 'the rejected answer explains what is required'
        Assert-False (($script:Messages -join "`n") -match 'fixture-(pool|stash)-password') 'credentials never enter the questionnaire log'
    }
    It 'rejects whitespace for a missing stash path without changing an existing pool default' {
        foreach ($reply in @('2', '', '', '', '', '  ', '//archive/stash', '', '')) { $script:Replies.Enqueue($reply) }
        $result = Invoke-QuestionnaireFixture
        Assert-Equal '//ypool-nas/work' $result.PoolPath 'Enter keeps an operator-configured pool path'
        Assert-Equal '//archive/stash' $result.StashPath
        Assert-Equal 0 $result.Problems.Count
        Assert-Equal 9 $script:Reads.Count
    }
    It 'recovers an empty pool share at its question before asking for the pool account' {
        $script:Config.networkStorage.poolStorageNetworkPath = ''
        foreach ($reply in @('2', '2', '2', '', '//ypool-nas/work/yuruna.pool', '', '//ystash-nas/work/yuruna.stash', '', '')) { $script:Replies.Enqueue($reply) }
        $result = Invoke-QuestionnaireFixture
        Assert-Equal '//ypool-nas/work/yuruna.pool' $result.PoolPath
        Assert-Equal '//ystash-nas/work/yuruna.stash' $result.StashPath
        Assert-Equal $script:Reads[3].Prompt $script:Reads[4].Prompt 'the pool path is retried before the account question'
        Assert-Equal 0 $result.Problems.Count
    }
    It 'keeps configured pool and stash coordinates when Enter accepts each nonempty default' {
        $script:Config.networkStorage.stashStorageNetworkPath = '//archive/operator-stash'
        $script:Config.networkStorage.stashStorageNetworkUser = 'operator-stash'
        foreach ($reply in @('2', '', '', '', '', '', '', '')) { $script:Replies.Enqueue($reply) }
        $result = Invoke-QuestionnaireFixture
        Assert-Equal '//ypool-nas/work' $result.PoolPath
        Assert-Equal '//archive/operator-stash' $result.StashPath
        Assert-Equal 'operator-stash' $result.StashUser
        Assert-Equal '/custom/pool' $result.Tiers[0].LocalPath
        Assert-Equal 8 $script:Reads.Count
        Assert-Equal 0 $result.Problems.Count
    }
    It 'uses an older answer file with stash coordinates already stored on this machine without prompting' {
        $script:Unattended = $true; $script:CanPrompt = $false
        $script:Config.networkStorage.stashStorageNetworkPath = '//archive/existing-stash'
        $script:Config.networkStorage.stashStorageNetworkUser = 'existing-stash'
        $script:Answers = [ordered]@{ setup = [ordered]@{ type = 'lab'; runTests = $false }; storage = [ordered]@{
            kind = 'nas'; networkPath = '//pool/custom'; networkUser = 'custom-pool'; onFailure = 'stop'
        }; lab = [ordered]@{ name = 'fixture-lab' } }
        $result = Invoke-QuestionnaireFixture
        Assert-Equal '//archive/existing-stash' $result.StashPath
        Assert-Equal 'existing-stash' $result.StashUser
        Assert-Equal 0 $script:Reads.Count
        Assert-Equal 0 $result.Problems.Count
    }
    It 'names a missing unattended stash answer without attempting a terminal read' {
        $script:Unattended = $true; $script:CanPrompt = $false
        $script:Answers = [ordered]@{ setup = [ordered]@{ type = 'lab'; runTests = $false }; storage = [ordered]@{
            kind = 'nas'; networkPath = '//pool/custom'; networkUser = 'custom-pool'; onFailure = 'stop'
        }; lab = [ordered]@{ name = 'fixture-lab' } }
        Assert-Throw { Invoke-QuestionnaireFixture } 'storage.stashNetworkPath'
        Assert-Equal 0 $script:Reads.Count
        Assert-Equal 0 $script:AuthenticationImports
    }
}

Describe 'setup prompt boundaries' {
    BeforeEach { Initialize-PromptFixture }
    It 'retries a required account until it receives a nonblank answer' {
        $script:Replies.Enqueue(''); $script:Replies.Enqueue('  '); $script:Replies.Enqueue('operator-account')
        $result = Read-Text -Question 'NAS account' -Required -ConfigKey 'storage.networkUser'
        Assert-Equal 'operator-account' $result
        Assert-Equal 3 $script:Reads.Count
    }
    It 'allows Enter to retain a nonempty required default' {
        $script:Replies.Enqueue('')
        Assert-Equal '//nas/existing' (Read-Text -Question 'NAS share' -Default '//nas/existing' -Required -ConfigKey 'storage.networkPath')
        Assert-Equal 1 $script:Reads.Count
    }
    It 'continues allowing an empty answer to an optional text question' {
        $script:Replies.Enqueue('')
        Assert-Equal '' (Read-Text -Question 'Optional text')
        Assert-Equal 1 $script:Reads.Count
    }
    It 'does not read text from a captured or noninteractive terminal' {
        $script:CanPrompt = $false
        Assert-Throw { Read-Text -Question 'NAS share' -Required -ConfigKey 'storage.networkPath' } '-AnswerFile.*storage.networkPath'
        Assert-Equal 0 $script:Reads.Count
    }
    It 'does not read a numbered choice from a captured or noninteractive terminal' {
        $script:CanPrompt = $false
        Assert-Throw { Read-Choice -Question 'Setup type' -Default 'lab' -Option @(@{ Label = 'Lab'; Value = 'lab' }) -ConfigKey 'setup.type' } '-AnswerFile.*setup.type'
        Assert-Equal 0 $script:Reads.Count
    }
    It 'retains unattended numbered defaults without asking a noninteractive terminal' {
        $script:Unattended = $true; $script:CanPrompt = $false
        Assert-Equal 'lab' (Read-Choice -Question 'Setup type' -Default 'lab' -Option @(@{ Label = 'Lab'; Value = 'lab' }) -ConfigKey 'setup.type')
        Assert-Equal 0 $script:Reads.Count
    }
    It 'reports closed text input after one read without a retry loop' {
        $script:Replies.Enqueue($null)
        Assert-Throw { Read-Text -Question 'NAS share' -Required -ConfigKey 'storage.networkPath' } 'input.*closed.*storage.networkPath'
        Assert-Equal 1 $script:Reads.Count
    }
    It 'reports closed choice input after one read without a retry loop' {
        $script:Replies.Enqueue($null)
        Assert-Throw { Read-Choice -Question 'Setup type' -Default 'lab' -Option @(@{ Label = 'Lab'; Value = 'lab' }) -ConfigKey 'setup.type' } 'input.*closed.*setup.type'
        Assert-Equal 1 $script:Reads.Count
    }
    It 'keeps numbered choice recovery and Enter defaults' {
        $script:Replies.Enqueue('9'); $script:Replies.Enqueue('')
        Assert-Equal 'lab' (Read-Choice -Question 'Setup type' -Default 'lab' -Option @(@{ Label = 'Lab'; Value = 'lab' }) -ConfigKey 'setup.type')
        Assert-Equal 2 $script:Reads.Count
    }
}
