<#PSScriptInfo
.VERSION 2026.10.18.1
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
        param([string]$Root, [string]$Build = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global', [string]$Pre = '', [string]$Post = '', [int]$Timeout = 600)
        $null = New-Item -ItemType Directory -Force -Path "$Root/config/lab", "$Root/components/sample"
        Set-Content -LiteralPath "$Root/components/sample/Dockerfile" -Value 'FROM scratch'
        $yaml = @{
            globalVariables = @{
                buildCommand = $Build; tagCommand = 'Set-Variable -Name LASTEXITCODE -Value 0 -Scope Global'
                pushCommand = 'Set-Content -LiteralPath "$env:componentPushMarker" -Value pushed'
                preProcessor = $Pre; postProcessor = $Post; commandTimeoutSeconds = $Timeout
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
        $script:originalEnvironment = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($item in Get-ChildItem Env:) { $script:originalEnvironment[$item.Name] = $item.Value }
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
        $dockerFolder = Join-Path $TestDrive ('bin-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $dockerFolder
        Set-Content -LiteralPath (Join-Path $dockerFolder 'docker.ps1') -Value @'
$input | Set-Content -LiteralPath $env:componentPasswordCapture
$global:LASTEXITCODE = [int]$env:componentLoginExit
if ($global:LASTEXITCODE -eq 0) { 'Login Succeeded' } else { 'Login denied' }
'@
        $env:PATH = $dockerFolder + [IO.Path]::PathSeparator + $env:PATH
        Mock Confirm-ComponentList -ModuleName Yuruna.Component { $true }
    }

    AfterEach {
        Set-Location -LiteralPath $script:originalLocation
        $global:LASTEXITCODE = $script:originalExit
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
        $result = Publish-ComponentList $root lab
        Assert-False $result.success
        Assert-Equal 1 $result.exitCode
        Assert-True ((Get-Content -Raw -LiteralPath "$root/.yuruna/lab/components/docker.stderr.log").Contains('fixture failure'))
        Assert-StringEqual $script:originalLocation (Get-Location).Path
    }

    It 'preserves preprocessor environment changes and clears stale native exit codes' {
        $root = Join-Path $TestDrive 'environment'
        $env:componentRemoved = 'remove-me'
        New-ComponentExecutionFixture -Root $root -Pre '`$env:componentPrepared = "ready"; Remove-Item Env:componentRemoved' `
            -Build 'if (`$env:componentPrepared -ne "ready" -or `$env:componentRemoved) { throw "lost preprocessor environment" }; "build complete"'
        $global:LASTEXITCODE = 77
        $result = Publish-ComponentList $root lab
        Assert-True $result.success $result.errorMessage
        Assert-StringEqual 'ready' $env:componentPrepared
        Assert-True ([string]::IsNullOrEmpty($env:componentRemoved))
    }

    It 'retains redacted partial output before a blocked command is terminated and stops its children' {
        $root = Join-Path $TestDrive 'blocked'
        $env:componentLiveLog = "$root/.yuruna/lab/components/docker.stderr.log"
        $env:componentObserved = Join-Path $root 'observed.txt'
        $env:componentChildPid = Join-Path $root 'child.pid'
        $build = @'
$child = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -PassThru
Set-Content -LiteralPath $env:componentChildPid -Value $child.Id
[Console]::Out.Write('partial ' + $env:YURUNA_REGISTRY_PASSWORD.Substring(0, 4))
Start-Sleep -Milliseconds 150
[Console]::Out.Write($env:YURUNA_REGISTRY_PASSWORD.Substring(4))
Start-Sleep -Milliseconds 300
$log = Get-Content -Raw -LiteralPath $env:componentLiveLog
if ($log -notmatch 'phase=begin' -or $log -notmatch '(?m)^partial <redacted>' -or $log -match '(?m)^== \[build\[sample\]\] phase=end ' -or $log.Contains($env:YURUNA_REGISTRY_PASSWORD)) { throw 'incremental evidence missing or unredacted' }
Set-Content -LiteralPath $env:componentObserved -Value 'visible while running'
Start-Sleep -Seconds 60
'@
        New-ComponentExecutionFixture -Root $root -Build ($build.Replace('$', '`$')) -Timeout 4
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Publish-ComponentList $root lab
        Assert-False $result.success
        Assert-Equal 124 $result.exitCode
        Assert-True ($watch.Elapsed.TotalSeconds -lt 10) 'phase supervision must bound the call and its cleanup'
        Assert-True (Test-Path -LiteralPath $env:componentObserved) 'begin and partial output must reach disk while the command is still running'
        Assert-False (Test-Path -LiteralPath $env:componentPushMarker)
        $log = Get-Content -Raw -LiteralPath $env:componentLiveLog
        Assert-True ($log -match 'phase=end .*pid=[1-9][0-9]* exit=124 outcome=timed_out killFailed=False')
        Assert-False ($log.Contains($env:YURUNA_REGISTRY_PASSWORD))
        $childPid = [int](Get-Content -LiteralPath $env:componentChildPid)
        $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
        if ($child -and $IsLinux) {
            $state = (Get-Content -LiteralPath "/proc/$childPid/stat" -ErrorAction SilentlyContinue) -replace '^.*\) ', ''
            Assert-True ($state.StartsWith('Z ')) 'a live descendant must not survive a timed-out phase'
        } else { Assert-True ($null -eq $child -or $child.HasExited) }
    }

    It 'rejects invalid command bounds before executing the component' {
        $root = Join-Path $TestDrive 'invalid-bound'
        New-ComponentExecutionFixture -Root $root -Timeout 0
        $result = Publish-ComponentList $root lab
        Assert-False $result.success
        Assert-StringEqual 'config_error' $result.failureClass
        Assert-False (Test-Path -LiteralPath $env:componentPushMarker)
    }


    It 'keeps dictionary command output from wrapping the result manifest' {
        $root = Join-Path $TestDrive 'dictionary'
        New-ComponentExecutionFixture -Root $root -Build '@{ progress = "built" }'
        $results = @(Publish-ComponentList $root lab)
        Assert-Equal 1 $results.Count
        Assert-True ($results[0] -is [Collections.IDictionary])
        Assert-True $results[0].success
    }

    It 'redacts multiline credentials on both streams and at a capture boundary' {
        $root = Join-Path $TestDrive 'redaction-boundary'
        $env:YURUNA_REGISTRY_PASSWORD = 'boundary-secret-' + ('z' * 400)
        $env:YURUNA_DOCKER_HUB_PASSWORD = "multiline-secret-first`nmultiline-secret-last"
        $build = @'
[Console]::Error.Write($env:YURUNA_DOCKER_HUB_PASSWORD.Substring(0, 10))
Start-Sleep -Milliseconds 50
[Console]::Error.WriteLine($env:YURUNA_DOCKER_HUB_PASSWORD.Substring(10))
[Console]::Out.Write('x' * 1048400)
[Console]::Out.Write($env:YURUNA_REGISTRY_PASSWORD)
'@
        New-ComponentExecutionFixture -Root $root -Build ($build.Replace('$', '`$'))
        $result = Publish-ComponentList $root lab -InformationAction SilentlyContinue
        Assert-True $result.success $result.errorMessage
        $log = Get-Content -Raw -LiteralPath "$root/.yuruna/lab/components/docker.stderr.log"
        Assert-False ($log.Contains('boundary-secret-')) 'a credential prefix cut by the capture cap must be withheld'
        Assert-False ($log.Contains('multiline-secret-first'))
        Assert-False ($log.Contains('multiline-secret-last'))
        Assert-True ($log.Contains('<redacted>'))
        Assert-True ($log.Contains('[output truncated at 1048576 characters per stream]'))
    }

    It 'keeps supervision active if an incremental output handler fails' {
        $seen = @{ Count = 0 }
        $handler = { param($Chunk, $Stream) $seen.Count++; $seen.Last = "$Stream$Chunk"; throw 'writer unavailable' }
        $result = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) -TimeoutSeconds 2 `
            -ArgumentList @('-NoProfile', '-Command', 'Write-Output partial; Start-Sleep -Seconds 60') -OutputHandler $handler
        Assert-Equal 1 $seen.Count
        Assert-StringEqual 'writer unavailable' $result.OutputHandlerError
        Assert-True $result.TimedOut
        Assert-False $result.KillFailed
    }


    It 'redacts all overlapping credential occurrences across stream chunks' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../automation/Yuruna.Component.psm1'), [ref]$null, [ref]$null)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Send-ComponentOutput' }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        $captured = [Text.StringBuilder]::new()
        function Write-ComponentOutput { param([string]$Text) [void]$captured.Append($Text) }
        foreach ($case in @(
            @{ Secrets = @('aaaa'); Chunks = @('aaaaaa', 'a', 'a', 'a', 'a') },
            @{ Secrets = @('ABCDEF', 'DEFGHI'); Chunks = @('ABCDEFGHI') }
        )) {
            $secrets = $case.Secrets
            $buffers = @{ stdout = ''; stderr = '' }
            [void]$captured.Clear()
            foreach ($chunk in $case.Chunks) {
                $buffers.stdout += $chunk
                Send-ComponentOutput -Stream stdout
                Assert-True ($buffers.stdout.Length -lt (@($secrets | ForEach-Object Length | Measure-Object -Maximum).Maximum))
            }
            Send-ComponentOutput -Stream stdout -Final
            foreach ($secret in $secrets) { Assert-False ($captured.ToString().Contains($secret)) }
            Assert-True ($captured.ToString().Contains('<redacted>'))
        }
    }

    It 'preserves distinct Unix environment names through a no-op phase' -Skip:$IsWindows {
        $root = Join-Path $TestDrive 'case-sensitive-environment'
        [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://upper.example.invalid')
        [Environment]::SetEnvironmentVariable('http_proxy', 'http://lower.example.invalid')
        New-ComponentExecutionFixture -Root $root
        $result = Publish-ComponentList $root lab
        Assert-True $result.success $result.errorMessage
        Assert-StringEqual 'http://upper.example.invalid' ([Environment]::GetEnvironmentVariable('HTTP_PROXY'))
        Assert-StringEqual 'http://lower.example.invalid' ([Environment]::GetEnvironmentVariable('http_proxy'))
    }

    It 'preserves preprocessor location changes for the build and restores the caller location' {
        $root = Join-Path $TestDrive 'location-side-effect'
        $target = Join-Path $root 'components/sample'
        New-ComponentExecutionFixture -Root $root -Pre "Set-Location -LiteralPath '$target'" `
            -Build "if ((Get-Location).Path -ne '$target') { throw 'lost preprocessor location' }"
        $result = Publish-ComponentList $root lab
        Assert-True $result.success $result.errorMessage
        Assert-StringEqual $script:originalLocation (Get-Location).Path
    }

    It 'redacts expanded command text from debug, information, and failure manifests' {
        $root = Join-Path $TestDrive 'expanded-command-secret'
        $env:YURUNA_REGISTRY_PASSWORD = 'private-expanded-command-value'
        New-ComponentExecutionFixture -Root $root -Build 'throw "$env:YURUNA_REGISTRY_PASSWORD"'
        $yaml = ConvertFrom-File "$root/config/lab/components.yml"
        $yaml.globalVariables['YURUNA_REGISTRY_PASSWORD'] = $env:YURUNA_REGISTRY_PASSWORD
        Set-Content -LiteralPath "$root/config/lab/components.yml" -Value (ConvertTo-Yaml $yaml)
        $emitted = @(Publish-ComponentList $root lab -Debug *>&1)
        $result = @($emitted | Where-Object { $_ -is [Collections.IDictionary] })[-1]
        Assert-False $result.success
        $published = (($emitted | ForEach-Object { [string]$_ }) -join "`n") + $result.errorMessage
        Assert-False ($published.Contains($env:YURUNA_REGISTRY_PASSWORD))
        Assert-True ($published.Contains('<redacted>'))
    }

}
