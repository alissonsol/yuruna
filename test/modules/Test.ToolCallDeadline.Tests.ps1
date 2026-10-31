<#PSScriptInfo
.VERSION 2026.10.31
.GUID 425c4e99-8eb0-4875-95bc-856e3d36c7fc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test deploy tool deadline timeout pester
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
    Holds every deploy tool call to a deadline: a tofu, helm, kubectl or shell
    call that stops answering is killed at its bound, reported as exit 124, and
    ends its phase as tool_timeout instead of waiting for the step watchdog.
.DESCRIPTION
    The tool that never answers is a real child process -- a pwsh that sleeps
    for a minute -- started by a stand-in function for the tool, so the test
    exercises the kill of a process tree, not a mock of it. A case that fails
    to stop the child fails by its own duration check.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Import.Yaml.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Retry.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Result.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Workload.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Resource.psm1') -Force -DisableNameChecking
    # In the environment, where the stand-in tools defined as global functions
    # can read it.
    $script:SavedPwshEntry = Save-YurunaTestEnvironment -Name 'YURUNA_DEADLINE_TEST_PWSH'
    $env:YURUNA_DEADLINE_TEST_PWSH = (Get-Process -Id $PID).Path
    $script:Hang = { & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60' }
    $script:EnvironmentName = @('YURUNA_RETRY_MAX_ATTEMPTS', 'YURUNA_RETRY_DELAY_SECONDS', 'TF_PLUGIN_CACHE_DIR', 'TF_IN_AUTOMATION', 'contextName', 'workFolder', 'resourceName')
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedPwshEntry
}

Describe 'a tool call under a deadline' {
    It 'kills a call that outlives its deadline and reports exit 124 with the stopped line' {
        $outcome = @{}
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $output = @(Invoke-YurunaToolWithDeadline -Label 'hanging tool' -TimeoutSeconds 2 -Outcome $outcome -ScriptBlock $script:Hang 3>$null)
        $elapsed = $watch.Elapsed.TotalSeconds
        Assert-True $outcome.TimedOut 'the call is reported as stopped'
        Assert-Equal 124 $global:LASTEXITCODE
        Assert-True ($elapsed -lt 30) "the child was killed at the deadline, not waited out ($elapsed s)"
        Assert-Match '^hanging tool did not finish within 2 seconds' ([string]$output[-1])
    }

    It 'leaves a call that finishes in time as it was' {
        $outcome = @{}
        $output = @(Invoke-YurunaToolWithDeadline -Label 'quick tool' -TimeoutSeconds 60 -Outcome $outcome -ScriptBlock {
            & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Write-Output done; exit 3'
        })
        Assert-False $outcome.TimedOut
        Assert-Equal 3 $global:LASTEXITCODE
        Assert-StringEqual 'done' ($output -join '|')
    }

    It 'counts a stopped attempt as failed even when the tool then exits zero' {
        $retry = Invoke-WithYurunaRetry -Label 'wrapper' -MaxAttempts 1 -TimeoutSeconds 1 -ScriptBlock {
            & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60'
            $global:LASTEXITCODE = 0
        } 3>$null
        Assert-False $retry.Success
        Assert-True $retry.TimedOut
        Assert-Equal 124 $retry.LastExit
    }

    It 'retries a stopped attempt only for a call without a classifier' -ForEach @(
        @{ Case = 'no classifier'; Classified = $false; Attempts = 2 }
        @{ Case = 'transient classifier'; Classified = $true; Attempts = 1 }
    ) {
        $env:YURUNA_RETRY_DELAY_SECONDS = '1'
        $params = @{ Label = 'stalled fetch'; MaxAttempts = 2; InitialDelaySeconds = 1; JitterFraction = 0; TimeoutSeconds = 1; ScriptBlock = $script:Hang }
        if ($Classified) { $params.ShouldRetry = { param($info) Test-YurunaTransientFailure -Output $info.Output } }
        $retry = Invoke-WithYurunaRetry @params 3>$null 6>$null
        Assert-True $retry.TimedOut $Case
        Assert-Equal $Attempts $retry.Attempts $Case
        Assert-Equal 124 $retry.LastExit
    }
}

Describe 'the bound of a deploy tool call' {
    It 'takes the record bound, then the document bound, then the built-in bound' {
        Assert-Equal 42 (Get-YurunaCommandTimeout -Call 'helm upgrade' -Entry @{ commandTimeoutSeconds = 42 } -GlobalVariables @{ commandTimeoutSeconds = 7 }).Seconds
        Assert-Equal 7 (Get-YurunaCommandTimeout -Call 'helm upgrade' -Entry @{} -GlobalVariables @{ commandTimeoutSeconds = '7' }).Seconds
        $builtIn = Get-YurunaCommandTimeout -Call 'helm upgrade'
        Assert-Equal 1800 $builtIn.Seconds
        Assert-False $builtIn.Configured
        Assert-True $builtIn.Valid
    }

    It 'refuses a configured bound of <Value>' -ForEach @(
        @{ Value = 0 }, @{ Value = 3601 }, @{ Value = -5 }, @{ Value = 'ten' }
    ) {
        $bound = Get-YurunaCommandTimeout -Call 'tofu apply' -Entry @{ commandTimeoutSeconds = $Value }
        Assert-False $bound.Valid
        Assert-Equal 3600 $bound.Seconds 'an invalid value never becomes the bound'
    }

    It 'routes tool_timeout to the class a watchdog-killed hang has' {
        Assert-StringEqual 'wait_timeout' (ConvertTo-CanonicalFailureClass 'tool_timeout')
        $manifest = New-YurunaResultManifest -Success $false -FailureClass 'tool_timeout' -ExitCode 124
        Assert-StringEqual 'tool_timeout' $manifest.failureClass
    }
}

Describe 'a phase ends a stopped tool call as tool_timeout' {
    BeforeEach {
        $script:originalLocation = (Get-Location).Path
        $script:originalEnvironment = Save-YurunaTestEnvironment -Name $script:EnvironmentName
        $env:YURUNA_RETRY_MAX_ATTEMPTS = '1'
    }

    AfterEach {
        Set-Location -LiteralPath $script:originalLocation
        Restore-YurunaTestEnvironment -Saved $script:originalEnvironment
        foreach ($name in 'helm', 'kubectl', 'tofu') { Remove-Item -Path "Function:global:$name" -ErrorAction SilentlyContinue }
    }

    It 'stops a chart install that hangs' {
        $root = Join-Path $TestDrive 'chart'
        $null = New-Item -ItemType Directory -Force -Path "$root/workloads/sample"
        Set-Content -LiteralPath "$root/workloads/sample/Chart.yaml" -Value "apiVersion: v2`nname: sample`nversion: 1.0.0"
        Set-Item -Path Function:global:helm -Value {
            switch ($args[0]) {
                'upgrade' { & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60' }
                'status'  { 'Error: release: not found'; $global:LASTEXITCODE = 1 }
                default   { 'linted'; $global:LASTEXITCODE = 0 }
            }
        }
        $deployment = @{ chart = 'sample'; commandTimeoutSeconds = 2; variables = @{ installName = 'fixture' } }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = & (Get-Module Yuruna.Workload) {
            param($Root, $Deployment)
            Invoke-WorkloadChartDeployment -project_root $Root -config_subfolder 'lab' -contextName 'ctx' -deployment $Deployment -deploymentVars ([ordered]@{}) -workloadsFile 'workloads.yml' -sw ([Diagnostics.Stopwatch]::StartNew())
        } $root $deployment 3>$null 6>$null
        Assert-True ($watch.Elapsed.TotalSeconds -lt 40) 'the install was stopped at its bound'
        Assert-False $result.success
        Assert-StringEqual 'tool_timeout' $result.failureClass
        Assert-Equal 124 $result.exitCode
        $work = "$root/.yuruna/lab/workloads/ctx/fixture"
        Assert-StringEqual '124' (Get-Content -Raw -LiteralPath "$work/helm.rc")
        Assert-Match 'did not finish within 2 seconds' (Get-Content -Raw -LiteralPath "$work/helm.stderr.log")
    }

    It 'stops a kubectl deployment that hangs, configured from globalVariables' {
        $root = Join-Path $TestDrive 'tool'
        $null = New-Item -ItemType Directory -Force -Path "$root/.yuruna/lab/workloads/ctx"
        Set-Item -Path Function:global:kubectl -Value { & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60' }
        $deployment = @{ kubectl = 'apply -f manifest.yml' }
        $result = & (Get-Module Yuruna.Workload) {
            param($Root, $Deployment)
            $kind = Resolve-YurunaDeploymentKind -Deployment $Deployment
            Invoke-WorkloadToolDeployment -kind $kind -project_root $Root -config_subfolder 'lab' -contextName 'ctx' -deployment $Deployment -deploymentVars ([ordered]@{}) -sw ([Diagnostics.Stopwatch]::StartNew()) -GlobalVariables @{ commandTimeoutSeconds = 2 }
        } $root $deployment 3>$null 6>$null
        Assert-False $result.success
        Assert-StringEqual 'tool_timeout' $result.failureClass
        Assert-Equal 124 $result.exitCode
    }

    It 'ends the resources phase as tool_timeout when tofu plan hangs' {
        $root = Join-Path $TestDrive 'resource'
        $null = New-Item -ItemType Directory -Force -Path "$root/config/lab", "$root/resources/sample"
        Set-Content -LiteralPath "$root/resources/sample/main.tf" -Value '# template'
        $yaml = [ordered]@{ globalVariables = @{ project = 'fixture' }; resources = @(@{ name = 'sample'; template = 'sample'; commandTimeoutSeconds = 2 }) }
        Set-Content -LiteralPath "$root/config/lab/resources.yml" -Value (ConvertTo-Yaml $yaml)
        Mock Confirm-ResourceList -ModuleName Yuruna.Resource { $true }
        Set-Item -Path Function:global:tofu -Value {
            if ($args[0] -eq 'plan') { & $env:YURUNA_DEADLINE_TEST_PWSH -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60' }
            $global:LASTEXITCODE = 0
        }
        $result = Publish-ResourceList $root lab 3>$null 6>$null
        Assert-False $result.success
        Assert-StringEqual 'tool_timeout' $result.failureClass
        Assert-Equal 124 $result.exitCode
        Assert-Match 'tofu plan' $result.errorMessage
        $ledger = Get-Content -Raw -LiteralPath (Get-YurunaDeployLedgerPath -ProjectRoot $root -ConfigSubfolder lab) | ConvertFrom-Json -AsHashtable
        Assert-StringEqual 'fail' $ledger.phases.resources.outcome
        Assert-StringEqual 'tool_timeout' $ledger.phases.resources.failureClass
    }
}
