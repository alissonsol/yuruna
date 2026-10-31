<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42741ee4-f795-4b5e-ab28-a68625394829
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test resource state teardown pester
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
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Resource.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Clear.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # Captured before any Mock: a filtered mock alone fails the calls its
    # filter does not match, and this suite relies on the real command there.
    $script:RealSaveResourceOutput = & (Get-Module Yuruna.Resource) { Get-Command Save-ResourceOutput }
    $script:RealGetCommand = Get-Command Get-Command -CommandType Cmdlet

    function New-StateSafetyFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates isolated test fixtures beneath TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Root, [System.Collections.IDictionary]$Variables = @{})
        $null = New-Item -ItemType Directory -Force -Path "$Root/config/lab", "$Root/resources/sample"
        Set-Content -LiteralPath "$Root/resources/sample/main.tf" -Value '# template'
        $yaml = [ordered]@{
            globalVariables = $Variables
            resources = @(@{ name = 'sample'; template = 'sample'; variables = @{ localLabel = '$env:stateSafetySource' } })
        }
        Set-Content -LiteralPath "$Root/config/lab/resources.yml" -Value (ConvertTo-Yaml $yaml)
        return "$Root/.yuruna/lab/resources/sample"
    }

    function Get-StateSafetySnapshot {
        param([string]$Root)
        $snapshot = @{}
        foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
            $snapshot[[IO.Path]::GetRelativePath($Root, $item.FullName)] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($item.FullName))
        }
        return $snapshot
    }
}

Describe 'resource state survives failed provisioning and teardown' {
    BeforeEach {
        $script:originalLocation = (Get-Location).Path
        $script:originalExit = $global:LASTEXITCODE
        $script:originalEnvironment = Save-YurunaTestEnvironment -All
        $env:stateSafetySource = 'local-value'
        & (Get-Module Yuruna.Resource) { $script:globalVariables = [ordered]@{} }
        Mock Confirm-ResourceList -ModuleName Yuruna.Resource { $true }
        Mock Confirm-ResourceList -ModuleName Yuruna.Clear { $true }
        Mock Invoke-TofuInitWithRetry -ModuleName Yuruna.Resource { @{ Success = $true; Attempts = 1; LastExit = 0 } }
        Mock Invoke-WithYurunaRetry -ModuleName Yuruna.Resource {
            param($Label)
            if ($Label -like 'tofu apply*') {
                Set-Content -LiteralPath './terraform.tfstate' -Value '{"resources":[{"name":"created"}]}'
                return @{ LastExit = 0; LastOutput = @('applied') }
            }
            if ($Label -like 'tofu plan*') { return @{ LastExit = 0; LastOutput = @('planned') } }
            return @{ LastExit = 0; LastOutput = @('{"id":{"value":"sample-id","type":"string"}}') }
        }
    }

    AfterEach {
        Set-Location -LiteralPath $script:originalLocation
        $global:LASTEXITCODE = $script:originalExit
        Restore-YurunaTestEnvironment -Saved $script:originalEnvironment -RemoveOthers
    }

    # Every second run was refused once a folder had been initialized, and the
    # refusal's advice -- clear first -- destroyed the resources it found.
    It 'initializes an initialized resource again, keeping its state and providers' {
        $root = Join-Path $TestDrive 'reinitialized'
        $work = New-StateSafetyFixture -Root $root
        $null = New-Item -ItemType Directory -Force -Path "$work/.terraform", "$work.new"
        Set-Content -LiteralPath "$work/.terraform/providers" -Value 'fetched providers'
        foreach ($name in @('terraform.tfstate', 'terraform.tfstate.backup')) { Set-Content -LiteralPath "$work/$name" -Value "original $name" }
        Set-Content -LiteralPath "$work.new/partial" -Value 'an earlier staging'
        $before = Get-StateSafetySnapshot -Root $work
        $result = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $true
        Assert-True $result.success 'the initialization runs again'
        $after = Get-StateSafetySnapshot -Root $work
        foreach ($key in 'terraform.tfstate', 'terraform.tfstate.backup', '.terraform/providers') { Assert-StringEqual $before[$key] $after[$key] $key }
        Assert-False (Test-Path -LiteralPath "$work.new") 'the earlier staging folder is gone'
        Should -Invoke Invoke-TofuInitWithRetry -ModuleName Yuruna.Resource -Times 1 -Exactly
    }

    # A run id drawn again at every run renamed the resources, so the second run
    # created a second set beside the first.
    It 'keeps the run id an earlier run recorded, and draws one only for a first run' {
        $root = Join-Path $TestDrive 'run-id'
        $null = New-StateSafetyFixture -Root $root -Variables ([ordered]@{ runId = '$(-join ((97..122) | Get-Random -Count 6 | %{[char]$_}))' })
        $first = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $true
        Assert-True $first.success 'fixture sanity: the first initialization'
        Assert-Match -Pattern '^[a-z]{6}$' -Actual $env:runId -Because 'a first run draws a run id'
        Set-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value (ConvertTo-Yaml ([ordered]@{ globalVariables = [ordered]@{ runId = 'kept' } }))
        $second = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $true
        Assert-True $second.success 'the second initialization'
        Assert-StringEqual 'kept' $env:runId 'the recorded run id'
        Assert-StringEqual 'kept' (& (Get-Module Yuruna.Resource) { [string]$script:globalVariables['runId'] }) 'and the globals the apply pass records'
    }

    It 'carries local state, its backup, custom state and workspace state through template staging' {
        $root = Join-Path $TestDrive 'state-copy'
        $work = New-StateSafetyFixture -Root $root
        $null = New-Item -ItemType Directory -Force -Path "$work/terraform.tfstate.d/workspace"
        foreach ($name in @('terraform.tfstate', 'terraform.tfstate.backup', 'custom.tfstate', 'terraform.tfstate.d/workspace/terraform.tfstate')) {
            Set-Content -LiteralPath "$work/$name" -Value "state $name"
        }
        $before = Get-StateSafetySnapshot -Root $work
        $result = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $true
        Assert-True $result.success
        $after = Get-StateSafetySnapshot -Root $work
        foreach ($key in $before.Keys) { Assert-StringEqual $before[$key] $after[$key] $key }
    }

    It 'expands globals once and leaves dollar-bearing resolved values intact on both passes' {
        $root = Join-Path $TestDrive 'variables'
        $env:stateSafetySecret = 'Xy$9zQ$abc$(throw 123)'
        $work = New-StateSafetyFixture -Root $root -Variables @{ adminPassword = '$env:stateSafetySecret' }
        foreach ($initializing in @($true, $false)) {
            $result = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $initializing
            Assert-True $result.success
            Assert-StringEqual $env:stateSafetySecret $env:adminPassword
            $vars = Get-Content -Raw -LiteralPath "$work/terraform.tfvars.json" | ConvertFrom-Json
            Assert-StringEqual $env:stateSafetySecret ([string]$vars.adminPassword) 'resolved dollars must be stored verbatim'
            Assert-StringEqual 'local-value' ([string]$vars.localLabel) 'resource-level expressions still expand'
        }
    }

    It 'registers a partial apply before it can fail and retains earlier resource entries' {
        $root = Join-Path $TestDrive 'partial'
        $work = New-StateSafetyFixture -Root $root
        $output = "$root/config/lab/resources.output.yml"
        Set-Content -LiteralPath $output -Value (ConvertTo-Yaml @{ globalVariables = @{}; earlier = @{ id = @{ value = 'old' } } })
        Mock Invoke-WithYurunaRetry -ModuleName Yuruna.Resource {
            param($Label)
            if ($Label -like 'tofu apply*') {
                $registered = ConvertFrom-File '../../../../config/lab/resources.output.yml'
                if (-not $registered.Contains('sample')) { throw 'resource was not registered before apply' }
                Set-Content -LiteralPath './terraform.tfstate' -Value '{"resources":[{"name":"partial"}]}'
                return @{ LastExit = 1; LastOutput = @('apply failed') }
            }
            throw 'unexpected output call after failed apply'
        }
        Assert-Throw { Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $false } -Match 'tofu apply'
        Assert-True (Test-Path -LiteralPath "$work/terraform.tfstate")
        $manifest = ConvertFrom-File $output
        Assert-True $manifest.Contains('sample')
        Assert-True $manifest.Contains('earlier')
        Assert-Equal 0 $manifest.sample.Count
    }

    It 'keeps a successful apply discoverable when outputs fail or are empty' -ForEach @(
        @{ OutputExit = 1; OutputBody = 'output failed' }
        @{ OutputExit = 0; OutputBody = '{}' }
    ) {
        $root = Join-Path $TestDrive "output-$OutputExit"
        $work = New-StateSafetyFixture -Root $root
        Mock Invoke-WithYurunaRetry -ModuleName Yuruna.Resource {
            param($Label)
            if ($Label -like 'tofu apply*') {
                Set-Content -LiteralPath './terraform.tfstate' -Value '{"resources":[{"name":"created"}]}'
                return @{ LastExit = 0; LastOutput = @('applied') }
            }
            return @{ LastExit = $OutputExit; LastOutput = @($OutputBody) }
        }
        Assert-Throw { Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $false }
        Assert-True (Test-Path -LiteralPath "$work/terraform.tfstate")
        Assert-True (ConvertFrom-File "$root/config/lab/resources.output.yml").Contains('sample')
    }

    It 'refuses a malformed existing ownership manifest without overwriting it' -ForEach @(
        @{ Case = 'scalar'; Body = 'previous-resource' }
        @{ Case = 'sequence'; Body = '- previous-resource' }
        @{ Case = 'empty'; Body = '' }
        @{ Case = 'empty-map'; Body = '{}' }
    ) {
        $root = Join-Path $TestDrive "invalid-manifest-$Case"
        $null = New-StateSafetyFixture -Root $root
        $output = "$root/config/lab/resources.output.yml"
        [IO.File]::WriteAllText($output, $Body)
        Assert-Throw { Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $false }
        Assert-StringEqual $Body ([IO.File]::ReadAllText($output))
        Assert-StringEqual $script:originalLocation (Get-Location).Path
        Should -Invoke Invoke-TofuInitWithRetry -ModuleName Yuruna.Resource -Times 0 -Exactly
    }

    It 'restores location and retains ownership if a manifest save fails' -ForEach @(
        @{ FailAtOutput = $false }
        @{ FailAtOutput = $true }
    ) {
        $root = Join-Path $TestDrive "manifest-save-$FailAtOutput"
        $work = New-StateSafetyFixture -Root $root
        $output = "$root/config/lab/resources.output.yml"
        Set-Content -LiteralPath $output -Value (ConvertTo-Yaml @{ globalVariables = @{}; earlier = @{ id = 'retained' } })
        # Leave the other saves real: registration failure must prevent apply,
        # while an output save failure must retain its already-written owner.
        Mock Save-ResourceOutput -ModuleName Yuruna.Resource { & $script:RealSaveResourceOutput @PesterBoundParameters }
        Mock Save-ResourceOutput -ModuleName Yuruna.Resource { throw 'manifest storage unavailable' } -ParameterFilter {
            $Resources.Contains('sample') -and (($null -ne $Resources['sample'].id) -eq $FailAtOutput)
        }
        Assert-Throw { Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $false } -Match 'manifest storage unavailable'
        Assert-StringEqual $script:originalLocation (Get-Location).Path
        $saved = ConvertFrom-File $output
        Assert-StringEqual 'retained' $saved.earlier.id
        Assert-Equal $FailAtOutput $saved.Contains('sample')
        Assert-Equal $FailAtOutput (Test-Path -LiteralPath "$work/terraform.tfstate")
        $applyCount = if ($FailAtOutput) { 1 } else { 0 }
        Should -Invoke Invoke-WithYurunaRetry -ModuleName Yuruna.Resource -Times $applyCount -Exactly -ParameterFilter { $Label -like 'tofu apply*' }
    }

    It 'replaces the ownership placeholder without duplicate YAML keys' {
        $root = Join-Path $TestDrive 'success'
        $null = New-StateSafetyFixture -Root $root
        $result = Publish-ResourceListHelper -project_root $root -config_subfolder lab -isInitialization $false
        Assert-True $result.success
        $output = "$root/config/lab/resources.output.yml"
        Assert-StringEqual 'sample-id' (ConvertFrom-File $output).sample.id.value
        Assert-Equal 1 @([regex]::Matches((Get-Content -Raw -LiteralPath $output), '(?m)^sample:')).Count
    }

    It 'preserves resource state when tofu cannot be resolved despite a stale successful exit code' {
        $root = Join-Path $TestDrive 'missing-tool'
        $work = New-StateSafetyFixture -Root $root
        $null = New-Item -ItemType Directory -Force -Path $work
        Set-Content -LiteralPath "$work/terraform.tfstate" -Value 'live state'
        $savedPassword = 'saved$literal$(throw 123)'
        Set-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value (ConvertTo-Yaml @{ globalVariables = @{ adminPassword = $savedPassword }; sample = @{} })
        Mock Get-Command -ModuleName Yuruna.Clear { & $script:RealGetCommand @PesterBoundParameters }
        Mock Get-Command -ModuleName Yuruna.Clear { $null } -ParameterFilter { $Name -eq 'tofu' }
        $global:LASTEXITCODE = 0
        $result = Clear-Configuration $root lab 3>$null
        Assert-False $result
        Assert-StringEqual $savedPassword $env:adminPassword
        Assert-StringEqual 'live state' (Get-Content -LiteralPath "$work/terraform.tfstate")
    }

    # A kill between the two moves of the folder swap leaves the state only in
    # <resource>.old: Set-Resource restored it, but a clear saw no folder and
    # left the resources the state describes running.
    It 'destroys from the state a broken swap left in .old' {
        $root = Join-Path $TestDrive 'old-only'
        $work = New-StateSafetyFixture -Root $root
        $null = New-Item -ItemType Directory -Force -Path "$work.old"
        Set-Content -LiteralPath "$work.old/terraform.tfstate" -Value 'live state'
        Set-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value (ConvertTo-Yaml @{ globalVariables = @{}; sample = @{} })
        $script:DestroyedIn = $null
        Set-Item -Path Function:global:tofu -Value { $script:DestroyedIn = (Get-Location).Path; $global:LASTEXITCODE = 0; 'destroyed' }
        try {
            Mock Get-Command -ModuleName Yuruna.Clear { & $script:RealGetCommand @PesterBoundParameters }
            Mock Get-Command -ModuleName Yuruna.Clear { @{ Source = 'tofu' } } -ParameterFilter { $Name -eq 'tofu' }
            $result = Clear-Configuration $root lab
            Assert-True $result 'the destroy ran'
            Assert-StringEqual ([IO.Path]::GetFullPath($work)) ([IO.Path]::GetFullPath($script:DestroyedIn)) 'from the recovered folder'
            Assert-False (Test-Path -LiteralPath "$work.old") 'nothing is left in .old'
        } finally { Remove-Item -Path Function:global:tofu -ErrorAction SilentlyContinue }
    }

    It 'preserves state and restores location when the resolved executable cannot start' {
        $root = Join-Path $TestDrive 'failed-launch'
        $work = New-StateSafetyFixture -Root $root
        $null = New-Item -ItemType Directory -Force -Path $work
        Set-Content -LiteralPath "$work/terraform.tfstate" -Value 'live state'
        Set-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value (ConvertTo-Yaml @{ globalVariables = @{}; sample = @{} })
        Mock Get-Command -ModuleName Yuruna.Clear { @{ Source = 'missing-tofu-executable-for-test' } } -ParameterFilter { $Name -eq 'tofu' }
        $global:LASTEXITCODE = 0
        $result = Clear-Configuration $root lab
        Assert-False $result
        Assert-True (Test-Path -LiteralPath "$work/terraform.tfstate")
        Assert-StringEqual $script:originalLocation (Get-Location).Path
    }
}
