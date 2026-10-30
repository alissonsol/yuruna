<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42dda4ab-eeef-4463-b75b-b245fb068a0f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test secret redaction workload retry diagnostic pester
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

<#
.SYNOPSIS
    Pins that a deployment secret never reaches a log, an event or a failure
    record through the command string that carries it.
.DESCRIPTION
    Deployment variables are published to the environment and expanded into
    tool command strings. The workload phase used to write that expanded string
    as the header of every <tool>.stderr.log section, as the retry events, as
    the console line of a failure and as the result manifest's error message;
    those files reach cycle folders that the status service serves to the LAN.
    These cases run the real retry helper and the real workload deployment
    against a stand-in kubectl that echoes the secret back, and the diagnostic
    collector's own copy of the rule, which it needs because it runs alone.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'A stand-in for a native tool must be a global function, and the retry events reach a global sink.')]
param()

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Workload.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Retry.psm1') -Force -Global -DisableNameChecking
    $script:Secret = 'Fixture-S3cret-0042'
    $script:EnvironmentName = @('registryPassword', 'fixtureApiKey', 'FIXTURE_FLAG_TOKEN', 'contextName', 'workFolder',
        'YURUNA_RETRY_MAX_ATTEMPTS', 'YURUNA_RETRY_DELAY_SECONDS')
}

Describe 'Get-YurunaSecretValue and Protect-YurunaSecretText' {
    BeforeEach { $script:Saved = Save-YurunaTestEnvironment -Name $script:EnvironmentName }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:Saved }

    It 'collects secret-named values, longest first, and leaves short values and booleans alone' {
        $env:registryPassword = $script:Secret
        $env:fixtureApiKey = 'Fixture-S3cret'
        $env:FIXTURE_FLAG_TOKEN = 'true'
        $values = @(Get-YurunaSecretValue)
        Assert-True ($values -ccontains $script:Secret) 'a password-named value is a secret'
        Assert-True ($values -ccontains 'Fixture-S3cret') 'an api key is a secret'
        Assert-False ($values -ccontains 'true') 'a boolean is not worth redacting'
        Assert-True ([array]::IndexOf($values, $script:Secret) -lt [array]::IndexOf($values, 'Fixture-S3cret')) 'the longer value is replaced first'
        Assert-StringEqual 'login -p <redacted> -k <redacted>-x' (Protect-YurunaSecretText -Text "login -p $script:Secret -k Fixture-S3cret-x")
    }
    It 'passes empty text through unchanged' {
        Protect-YurunaSecretText -Text '' | Should -Be ''
    }
}

Describe 'Invoke-WithYurunaRetry redacts what it logs' {
    BeforeEach {
        $script:Saved = Save-YurunaTestEnvironment -Name $script:EnvironmentName
        $env:registryPassword = $script:Secret
        $global:__RetryEvents = [System.Collections.Generic.List[object]]::new()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEvents.Add($EventRecord) }
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
    }
    AfterEach {
        Remove-Item -Path Function:/Send-CycleEventSafely -ErrorAction SilentlyContinue
        Remove-Variable -Name __RetryEvents -Scope Global -ErrorAction SilentlyContinue
        Restore-YurunaTestEnvironment -Saved $script:Saved
    }

    It 'keeps the secret out of the section header, the captured output and the retry events' {
        $result = Invoke-WithYurunaRetry -Label "docker login -p $script:Secret" -MaxAttempts 2 -InitialDelaySeconds 1 -LogPath $script:Log `
            -ScriptBlock { $global:LASTEXITCODE = 1; "denied for $env:registryPassword" } 6>$null
        Assert-False $result.Success
        $text = [IO.File]::ReadAllText($script:Log)
        Assert-False ($text.Contains($script:Secret)) "the log holds: $text"
        Assert-Match 'docker login -p <redacted> attempt 1/2' $text
        Assert-Match 'denied for <redacted>' $text
        Assert-True ($global:__RetryEvents.Count -ge 1) 'the retry reports its attempts'
        foreach ($record in $global:__RetryEvents) { Assert-False ([string]$record['description']).Contains($script:Secret) 'an event description' }
        Assert-False ([string]$result.Label).Contains($script:Secret) 'the returned label'
    }
}

Describe 'a workload deployment whose command carries a secret' {
    BeforeEach {
        $script:Saved = Save-YurunaTestEnvironment -Name $script:EnvironmentName
        Remove-Item -LiteralPath 'Env:YURUNA_RETRY_MAX_ATTEMPTS', 'Env:YURUNA_RETRY_DELAY_SECONDS' -ErrorAction SilentlyContinue
        $script:OriginalLocation = (Get-Location).Path
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:Root '.yuruna/lab/workloads/fixture-context')
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        # The stand-in echoes its arguments back, as a failing kubectl that
        # prints the command it could not run does.
        function global:kubectl { $global:LASTEXITCODE = 1; "error: cannot run kubectl $($args -join ' ')" }
    }
    AfterEach {
        Remove-Item -Path Function:/kubectl -ErrorAction SilentlyContinue
        Set-Location -LiteralPath $script:OriginalLocation
        Restore-YurunaTestEnvironment -Saved $script:Saved
    }

    It 'writes the secret to no tool log, console line or failure record' {
        $all = @(InModuleScope Yuruna.Workload -Parameters @{ Root = $script:Root; Secret = $script:Secret } {
            $deployment = @{ kubectl = 'create secret generic registry --from-literal=password=${env:registryPassword}' }
            Invoke-WorkloadToolDeployment -kind (Resolve-YurunaDeploymentKind -Deployment $deployment) -project_root $Root `
                -config_subfolder 'lab' -contextName 'fixture-context' -deployment $deployment `
                -deploymentVars ([ordered]@{ registryPassword = $Secret }) -sw ([System.Diagnostics.Stopwatch]::StartNew())
        } 6>&1)
        $information = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $failure = @($all | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
        Assert-NotNull $failure 'the failed deployment returns a manifest'
        Assert-False ([string]$failure.errorMessage).Contains($script:Secret) "the manifest says: $($failure.errorMessage)"
        Assert-Match '<redacted>' ([string]$failure.errorMessage)
        $log = [IO.File]::ReadAllText((Join-Path $script:Root '.yuruna/lab/workloads/fixture-context/kubectl.stderr.log'))
        Assert-False ($log.Contains($script:Secret)) "the tool log holds: $log"
        Assert-Match 'password=<redacted>' $log
        foreach ($line in $information) { Assert-False $line.Contains($script:Secret) "console line: $line" }
    }
}

Describe 'the diagnostic collector redacts the tool logs it prints' {
    BeforeAll {
        $diagnostic = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($diagnostic, [ref]$null, [ref]$null)
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Protect-DiagnosticSecretText' }, $true) | Select-Object -First 1
        Assert-NotNull $found 'the diagnostic script embeds its own redaction'
        $script:DiagnosticRedaction = $found.Extent.Text
    }
    BeforeEach { $script:Saved = Save-YurunaTestEnvironment -Name $script:EnvironmentName }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:Saved }

    It 'replaces environment secrets, secret assignments and token shapes, line by line' {
        $env:registryPassword = $script:Secret
        $run = [scriptblock]::Create($script:DiagnosticRedaction + "`nProtect-DiagnosticSecretText -Line `$args")
        $out = @(& $run "== kubectl create --from-literal=pw=$script:Secret ==" 'REGISTRY_PASSWORD=hunter22' 'token ghp_abcdefghijklmnopqrstuvwxyz0123' 'plain line')
        Assert-Equal 4 $out.Count
        Assert-StringEqual '== kubectl create --from-literal=pw=[REDACTED] ==' $out[0]
        Assert-StringEqual '[REDACTED SECRET ASSIGNMENT]' $out[1]
        Assert-StringEqual 'token [REDACTED]' $out[2]
        Assert-StringEqual 'plain line' $out[3]
    }
}
