<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42a6ed9f-c626-4fda-9037-997b94337522
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test deploy phase ledger retry pester
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

<#
.SYNOPSIS
    Holds the deploy phase ledger to its contract: a retry after a later phase
    failed runs again only what it must, and never skips a phase whose inputs
    changed or whose outputs are gone.
.DESCRIPTION
    The first Describe drives Invoke-YurunaDeployPhase with phases that only
    count their runs; the second holds the output checks of the resources and
    components phases; the last runs the real components publisher twice
    around a failed workloads phase.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Import.Yaml.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Result.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Resource.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Component.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.DeployLedger.psm1') -Force -Global -DisableNameChecking

    function New-LedgerFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates isolated fixtures beneath TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Name)
        $root = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Force -Path "$root/config/lab"
        foreach ($phase in 'resources', 'components', 'workloads') { Set-Content -LiteralPath "$root/config/lab/$phase.yml" -Value "phase: $phase" }
        $script:Runs = @{ resources = 0; components = 0; workloads = 0 }
        $script:OutputsPresent = $true
        return $root
    }

    # One phase through the ledger, with the inputs and output check the real
    # publishers pass in their shape: the workloads phase has neither.
    function Invoke-LedgerPhase {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Pass and Throw are read by the Operation scriptblock the ledger invokes from this scope.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Phase,
            [bool]$Pass = $true,
            [scriptblock]$Throw
        )
        $parameters = @{
            ProjectRoot = $Root; ConfigSubfolder = 'lab'; Phase = $Phase
            Operation   = {
                $script:Runs[$Phase]++
                if ($Throw) { & $Throw }
                New-YurunaResultManifest -Success $Pass -FailureClass $(if ($Pass) { 'ok' } else { 'tool_failed' })
            }
        }
        if ($Phase -ne 'workloads') {
            $parameters.InputPath = [ordered]@{ "config/$Phase.yml" = "$Root/config/lab/$Phase.yml" }
            $parameters.OutputTest = { param($Evidence) $null = $Evidence; $script:OutputsPresent }
            $parameters.Evidence = { @{ recorded = $true } }
        }
        return (Invoke-YurunaDeployPhase @parameters 6>$null)
    }

    function Read-LedgerFixture {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Root)
        $path = Get-YurunaDeployLedgerPath -ProjectRoot $Root -ConfigSubfolder lab
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable)
    }
}

Describe 'the deploy phase ledger' {
    It 'runs every phase of a run with no ledger, and the last pass ends the run' {
        $root = New-LedgerFixture -Name 'clean'
        foreach ($phase in 'resources', 'components', 'workloads') {
            $result = Invoke-LedgerPhase -Root $root -Phase $phase
            Assert-True $result.success
            Assert-False $result.skipped $phase
        }
        Assert-Equal 1 $script:Runs.resources
        Assert-Equal 1 $script:Runs.components
        Assert-Equal 1 $script:Runs.workloads
        Assert-Null (Read-LedgerFixture -Root $root) 'the ledger is gone once the workloads phase passed'
    }

    It 'reuses the earlier passes on a retry after the workloads phase failed' {
        $root = New-LedgerFixture -Name 'retry'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $null = Invoke-LedgerPhase -Root $root -Phase components
        $failed = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        Assert-False $failed.success
        Assert-StringEqual 'fail' (Read-LedgerFixture -Root $root).phases.workloads.outcome
        foreach ($phase in 'resources', 'components') {
            $reused = Invoke-LedgerPhase -Root $root -Phase $phase
            Assert-True $reused.success $phase
            Assert-True $reused.skipped "$phase is reused"
            Assert-Equal 1 $script:Runs[$phase] "$phase did not run again"
        }
        $retried = Invoke-LedgerPhase -Root $root -Phase workloads
        Assert-True $retried.success
        Assert-Equal 2 $script:Runs.workloads
        Assert-Null (Read-LedgerFixture -Root $root)
    }

    It 'runs a phase again when its inputs changed' {
        $root = New-LedgerFixture -Name 'changed-input'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $null = Invoke-LedgerPhase -Root $root -Phase components
        $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        Set-Content -LiteralPath "$root/config/lab/resources.yml" -Value 'phase: resources, edited'
        $resources = Invoke-LedgerPhase -Root $root -Phase resources
        $components = Invoke-LedgerPhase -Root $root -Phase components
        Assert-False $resources.skipped 'the edited phase runs'
        Assert-Equal 2 $script:Runs.resources
        Assert-True $components.skipped 'a phase whose own inputs did not change is still reused'
    }

    It 'runs a phase again when its recorded outputs are gone' {
        $root = New-LedgerFixture -Name 'outputs-gone'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        $script:OutputsPresent = $false
        $result = Invoke-LedgerPhase -Root $root -Phase resources
        Assert-False $result.skipped
        Assert-Equal 2 $script:Runs.resources
    }

    It 'forgets the phases a retry skipped when that retry fails again' {
        $root = New-LedgerFixture -Name 'second-failure'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $null = Invoke-LedgerPhase -Root $root -Phase components
        $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        Assert-True (Invoke-LedgerPhase -Root $root -Phase resources).skipped
        Assert-True (Invoke-LedgerPhase -Root $root -Phase components).skipped
        $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        $ledger = Read-LedgerFixture -Root $root
        Assert-False $ledger.phases.ContainsKey('resources') 'the skipped passes are forgotten'
        Assert-False (Invoke-LedgerPhase -Root $root -Phase resources).skipped
        Assert-False (Invoke-LedgerPhase -Root $root -Phase components).skipped
        Assert-Equal 2 $script:Runs.resources
        Assert-Equal 2 $script:Runs.components
    }

    It 'runs a phase again when no later phase failed after it' {
        $root = New-LedgerFixture -Name 'no-failure'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $again = Invoke-LedgerPhase -Root $root -Phase resources
        Assert-False $again.skipped 'a run again with nothing failed is an ordinary run'
        Assert-Equal 2 $script:Runs.resources
    }

    It 'ignores a ledger it cannot read' -ForEach @(
        @{ Case = 'not JSON'; Body = 'not json {' }
        @{ Case = 'another schema'; Body = '{"schema":"other","phases":{}}' }
    ) {
        $root = New-LedgerFixture -Name ("unreadable-" + ($Case -replace ' ', '-'))
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
        Set-Content -LiteralPath (Get-YurunaDeployLedgerPath -ProjectRoot $root -ConfigSubfolder lab) -Value $Body
        $result = Invoke-LedgerPhase -Root $root -Phase resources
        Assert-True $result.success
        Assert-False $result.skipped $Case
        Assert-StringEqual 'pass' (Read-LedgerFixture -Root $root).phases.resources.outcome 'a new ledger replaces it'
    }

    It 'turns a tool call stopped at its deadline into a tool_timeout failure' {
        $root = New-LedgerFixture -Name 'timeout'
        $result = Invoke-LedgerPhase -Root $root -Phase components -Throw { throw [System.TimeoutException]::new('docker push was stopped') }
        Assert-False $result.success
        Assert-StringEqual 'tool_timeout' $result.failureClass
        Assert-Equal 124 $result.exitCode
        Assert-StringEqual 'docker push was stopped' $result.errorMessage
        Assert-StringEqual 'tool_timeout' (Read-LedgerFixture -Root $root).phases.components.failureClass
    }

    It 'records a phase that throws as failed and lets the throw through' {
        $root = New-LedgerFixture -Name 'throws'
        $null = Invoke-LedgerPhase -Root $root -Phase resources
        Assert-Throw { Invoke-LedgerPhase -Root $root -Phase components -Throw { throw 'state unreadable' } } -Match 'state unreadable'
        $ledger = Read-LedgerFixture -Root $root
        Assert-StringEqual 'fail' $ledger.phases.components.outcome
        Assert-True (Invoke-LedgerPhase -Root $root -Phase resources).skipped 'the failure lets the earlier pass be reused'
    }

    It 'never reuses a phase whose inputs pass the hashing limits' {
        $root = New-LedgerFixture -Name 'limits'
        $ledgerModule = Get-Module Yuruna.DeployLedger
        $limit = & $ledgerModule { $script:InputHashFileLimit }
        & $ledgerModule { $script:InputHashFileLimit = 0 }
        try {
            $null = Invoke-LedgerPhase -Root $root -Phase resources
            $null = Invoke-LedgerPhase -Root $root -Phase workloads -Pass $false
            Assert-False (Invoke-LedgerPhase -Root $root -Phase resources).skipped
        } finally { & $ledgerModule { param($Value) $script:InputHashFileLimit = $Value } $limit }
    }

    It 'hashes inputs by label, relative path and content, not by location' {
        foreach ($copy in 'a', 'b') {
            $null = New-Item -ItemType Directory -Force -Path "$TestDrive/hash-$copy/tree/sub"
            Set-Content -LiteralPath "$TestDrive/hash-$copy/tree/sub/file.txt" -Value 'same'
            Set-Content -LiteralPath "$TestDrive/hash-$copy/tree/Top.txt" -Value 'same'
        }
        $hashA = Get-YurunaDeployInputHash -Phase resources -InputPath @{ tree = "$TestDrive/hash-a/tree" }
        $hashB = Get-YurunaDeployInputHash -Phase resources -InputPath @{ tree = "$TestDrive/hash-b/tree" }
        Assert-StringEqual $hashA $hashB 'two copies of one tree hash the same'
        Assert-NotEqual $hashA (Get-YurunaDeployInputHash -Phase components -InputPath @{ tree = "$TestDrive/hash-a/tree" }) 'the phase is part of the hash'
        Set-Content -LiteralPath "$TestDrive/hash-b/tree/sub/file.txt" -Value 'changed'
        Assert-NotEqual $hashA (Get-YurunaDeployInputHash -Phase resources -InputPath @{ tree = "$TestDrive/hash-b/tree" }) 'content'
        Set-Content -LiteralPath "$TestDrive/hash-b/tree/sub/file.txt" -Value 'same'
        Rename-Item -LiteralPath "$TestDrive/hash-b/tree/Top.txt" -NewName 'top2.txt'
        Assert-NotEqual $hashA (Get-YurunaDeployInputHash -Phase resources -InputPath @{ tree = "$TestDrive/hash-b/tree" }) 'name'
        Set-Content -LiteralPath "$TestDrive/empty.txt" -Value '' -NoNewline
        Assert-NotEqual (Get-YurunaDeployInputHash -Phase resources -InputPath @{ file = "$TestDrive/empty.txt" }) (Get-YurunaDeployInputHash -Phase resources -InputPath @{ file = "$TestDrive/absent.txt" }) 'a missing input is not an empty one'
    }
}

Describe 'the output checks of the reusable phases' {
    It 'holds a resources pass to its output file and each work folder''s state' {
        $root = Join-Path $TestDrive 'resource-outputs'
        $work = "$root/.yuruna/lab/resources/sample"
        $null = New-Item -ItemType Directory -Force -Path "$root/config/lab", $work
        Set-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value (ConvertTo-Yaml ([ordered]@{ globalVariables = @{ runId = 'abc' }; sample = @{ id = @{ value = 'x' } }; unfinished = @{} }))
        Set-Content -LiteralPath "$work/.workfolder.complete" -Value 'done' -Force
        Set-Content -LiteralPath "$work/terraform.tfstate" -Value '{}'
        $evidence = & (Get-Module Yuruna.Resource) { param($Root) Get-ResourceOutputEvidence -ProjectRoot $Root -ConfigSubfolder lab } $root
        Assert-StringEqual 'sample' (@($evidence.workFolders) -join ',') 'a placeholder of an unfinished apply has no state to check'
        $present = { & (Get-Module Yuruna.Resource) { param($Root, $Evidence) Test-ResourceOutputPresent -ProjectRoot $Root -ConfigSubfolder lab -Evidence $Evidence } $root $evidence }
        Assert-True (& $present) 'intact'
        Remove-Item -LiteralPath "$work/terraform.tfstate"
        Assert-False (& $present) 'state gone'
        $null = New-Item -ItemType Directory -Force -Path "$work/.terraform"
        Set-Content -LiteralPath "$work/.terraform/terraform.tfstate" -Value '{"backend":{}}' -Force
        Assert-True (& $present) 'a remote backend record stands for the state'
        Remove-Item -LiteralPath "$work/.workfolder.complete" -Force
        Assert-False (& $present) 'an unfinished staging'
        Set-Content -LiteralPath "$work/.workfolder.complete" -Value 'done' -Force
        Add-Content -LiteralPath "$root/config/lab/resources.output.yml" -Value 'edited: true'
        Assert-False (& $present) 'the output file changed'
    }

    It 'reads the pushed image from docker push output and nothing else' {
        $digest = 'sha256:' + ('ab' * 32)
        $docker = "The push refers to repository [localhost:5000/website/website]`n5f70bf18a086: Pushed`nlatest: digest: $digest size: 1784`n"
        $image = & (Get-Module Yuruna.Component) { param($Text) Get-ComponentPushedImage -Text $Text } $docker
        Assert-StringEqual "localhost:5000/website/website@$digest" $image
        foreach ($other in @("Copying blob 5f70bf18a086 done`nWriting manifest to image destination", 'The push refers to repository [localhost:5000/x]', '')) {
            Assert-Null (& (Get-Module Yuruna.Component) { param($Text) Get-ComponentPushedImage -Text $Text } $other) $other
        }
    }

    It 'confirms pushed images through the registry and refuses on any doubt' {
        try {
            $env:ledgerDockerLog = Join-Path $TestDrive 'docker-calls.log'
            Set-Item -Path Function:global:docker -Value { Add-Content -LiteralPath $env:ledgerDockerLog -Value ($args -join ' '); $global:LASTEXITCODE = [int]$env:ledgerProbeExit }
            $probe = { param($Reference) & (Get-Module Yuruna.Component) { param($Reference) Test-ComponentImagePresent -Reference $Reference } $Reference }
            $env:ledgerProbeExit = '0'
            Assert-True (& $probe @('localhost:5000/a@sha256:1', 'localhost:5000/b@sha256:2'))
            $calls = @(Get-Content -LiteralPath $env:ledgerDockerLog)
            Assert-StringEqual 'manifest inspect --insecure localhost:5000/a@sha256:1' $calls[0]
            Assert-Equal 2 $calls.Count
            $env:ledgerProbeExit = '1'
            Assert-False (& $probe @('localhost:5000/a@sha256:1')) 'the registry does not have it'
            Assert-False (& $probe @()) 'nothing recorded'
        } finally {
            Remove-Item -Path Function:global:docker -ErrorAction SilentlyContinue
            Remove-Item -Path Env:ledgerProbeExit, Env:ledgerDockerLog -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the components publisher around a failed workloads phase' {
    BeforeEach {
        $script:originalLocation = (Get-Location).Path
        $script:originalEnvironment = Save-YurunaTestEnvironment -All
        $env:ledgerBuildLog = Join-Path $TestDrive ('builds-' + [guid]::NewGuid().ToString('N'))
        Mock Confirm-ComponentList -ModuleName Yuruna.Component { $true }
        Set-Item -Path Function:global:docker -Value { $global:LASTEXITCODE = [int]$env:ledgerProbeExit }
    }

    AfterEach {
        Set-Location -LiteralPath $script:originalLocation
        Remove-Item -Path Function:global:docker -ErrorAction SilentlyContinue
        Restore-YurunaTestEnvironment -Saved $script:originalEnvironment -RemoveOthers
    }

    It 'rebuilds only when the pushed image is no longer in the registry (probe exit <ProbeExit>)' -ForEach @(
        @{ ProbeExit = 0; Builds = 1; Skipped = $true }
        @{ ProbeExit = 1; Builds = 2; Skipped = $false }
    ) {
        $root = Join-Path $TestDrive "components-$ProbeExit"
        $null = New-Item -ItemType Directory -Force -Path "$root/config/lab", "$root/components/sample"
        Set-Content -LiteralPath "$root/components/sample/Dockerfile" -Value 'FROM scratch'
        $digest = 'sha256:' + ('cd' * 32)
        $yaml = @{
            globalVariables = @{
                # Expanded by the publisher before it runs them, so a literal
                # $global:LASTEXITCODE would read as its current value.
                buildCommand = 'Add-Content -LiteralPath $env:ledgerBuildLog -Value built; Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'
                tagCommand   = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'
                pushCommand  = "'The push refers to repository [localhost:5000/sample/sample]'; 'latest: digest: $digest size: 528'; Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global"
            }
            components = @(@{ project = 'sample' })
        }
        Set-Content -LiteralPath "$root/config/lab/components.yml" -Value (ConvertTo-Yaml $yaml)
        $first = Publish-ComponentList $root lab 6>$null
        Assert-True $first.success $first.errorMessage
        $ledger = Get-Content -Raw -LiteralPath (Get-YurunaDeployLedgerPath -ProjectRoot $root -ConfigSubfolder lab) | ConvertFrom-Json -AsHashtable
        Assert-StringEqual "localhost:5000/sample/sample@$digest" (@($ledger.phases.components.evidence.images) -join ',')
        $null = Invoke-YurunaDeployPhase -ProjectRoot $root -ConfigSubfolder lab -Phase workloads -Operation { New-YurunaResultManifest -Success $false -FailureClass 'tool_failed' }
        $env:ledgerProbeExit = "$ProbeExit"
        $second = Publish-ComponentList $root lab 6>$null
        Assert-True $second.success $second.errorMessage
        Assert-Equal $Skipped ([bool]$second.skipped)
        Assert-Equal $Builds @(Get-Content -LiteralPath $env:ledgerBuildLog).Count
    }
}
