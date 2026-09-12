<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42bc0016-f193-426d-a72c-0c102ad1e5f2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest archive project docker pester
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
    Verify guest archive and development-container failures remain failures.
.DESCRIPTION
    Runs extracted Windows guest bootstrap blocks and a temporary copy of the
    project development launcher with mocked network, archive, Git, and Docker
    commands. No VM, network endpoint, or real container is contacted.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $projectRoot = Join-Path (Split-Path -Parent $repoRoot) 'yuruna-project'
    $script:ProjectAvailable = Test-Path (Join-Path $projectRoot 'example/website/components/frontend/website/docker-run-dev.ps1')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    $script:UpdateSource = Get-Content (Join-Path $script:RepoRoot 'guest/windows.11/windows.11.update.ps1') -Raw
    $script:DevSource = Join-Path $script:ProjectRoot 'example/website/components/frontend/website/docker-run-dev.ps1'
    $nativeExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $script:HadNativeExitCode = $null -ne $nativeExitCode
    $script:InitialNativeExitCode = if ($script:HadNativeExitCode) { $nativeExitCode.Value } else { $null }
    function Get-UpdateBlock {
        param([string]$Start, [string]$End)
        $begin = $script:UpdateSource.IndexOf($Start)
        $finish = $script:UpdateSource.IndexOf($End, $begin + $Start.Length)
        $text = $script:UpdateSource.Substring($begin, $finish - $begin)
        # Inject only fixture paths and coordinates; retain the production control flow.
        $text = $text.Replace('$env:USERPROFILE', '$script:FixtureProfile').Replace('$env:TEMP', '$script:FixtureProfile')
        $text = $text.Replace('$env:YURUNA_STATUS_SERVICE_IP', '$script:FixtureAddress').Replace('$env:YURUNA_STATUS_SERVICE_PORT', '$script:FixturePort')
        [scriptblock]::Create($text)
    }
    function tar.exe { }
    function git { }
    function docker { }
}
Describe 'Windows guest archive failure handling' {
    BeforeEach {
        $script:FixtureProfile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:FixtureProfile
        $script:FixtureAddress = '192.0.2.10'
        $script:FixturePort = '8080'
        $script:yurunaRoot = Join-Path $script:FixtureProfile 'yuruna'
        $script:frameworkUrl = 'https://fixture.invalid/framework'
        $script:projectUrl = 'https://fixture.invalid/project'
        Mock Invoke-WebRequest { }
        Mock tar.exe {
            $destination = $args[3]
            Set-Content (Join-Path $destination 'partial.txt') 'partial archive'
            $global:LASTEXITCODE = 2
        }
        Mock git {
            $destination = $args[-1]
            $null = New-Item -ItemType Directory $destination -Force
            Set-Content (Join-Path $destination 'complete.txt') 'complete checkout'
            $global:LASTEXITCODE = 0
        }
    }
    It 'cleans a failed early extraction instead of announcing it as available' {
        $block = Get-UpdateBlock '# --- REGION: Early yuruna framework extraction' '# --- REGION: Disable services that may suspend'
        $output = & $block
        Test-Path $yurunaRoot | Should -BeFalse
        ($output -join "`n") | Should -Not -Match 'Yuruna framework available'
    }
    It 'falls back to bounded git after a failed framework extraction' {
        $block = Get-UpdateBlock '# --- REGION: Materialize the yuruna framework and project repos' '$yurunaProject ='
        & $block | Out-Null
        Should -Invoke git -Times 1 -Exactly
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'http.lowSpeedLimit=1024' -and $args -contains 'http.lowSpeedTime=60' }
        Test-Path (Join-Path $yurunaRoot 'partial.txt') | Should -BeFalse
    }
    It 'rejects partial project extraction before bounded git fallback' {
        $block = Get-UpdateBlock '$yurunaProject =' '# --- REGION: Clean up temporary files'
        $null = New-Item -ItemType Directory $yurunaRoot
        & $block | Out-Null
        Should -Invoke git -Times 1 -Exactly
        Should -Invoke git -Times 1 -ParameterFilter { $args -contains 'http.lowSpeedLimit=1024' -and $args -contains 'http.lowSpeedTime=60' }
        Test-Path (Join-Path $yurunaRoot 'project/partial.txt') | Should -BeFalse
    }
}
Describe 'Development container launch failure handling' -Skip:(-not $script:ProjectAvailable) {
    BeforeEach {
        $script:FixtureScriptFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:FixtureScriptFolder
        $script:FixtureScript = Join-Path $script:FixtureScriptFolder 'docker-run-dev.ps1'
        Copy-Item $script:DevSource $script:FixtureScript
        Set-Content (Join-Path $script:FixtureScriptFolder 'copy-pfx.ps1') 'Write-Output "certificate copied"'
        $script:StartDirectory = (Get-Location).Path
        Mock docker { $global:LASTEXITCODE = 0 }
    }
    AfterEach { Set-Location $script:StartDirectory }
    It 'does not launch an old image after a failed build' {
        Mock docker { $global:LASTEXITCODE = 17 } -ParameterFilter { $args[0] -eq 'build' }
        { & $script:FixtureScript | Out-Null } | Should -Throw '*build*'
        Should -Invoke docker -Times 0 -ParameterFilter { $args[0] -eq 'run' }
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'restores the caller directory when certificate preparation fails' {
        Set-Content (Join-Path $script:FixtureScriptFolder 'copy-pfx.ps1') 'throw "certificate missing"'
        { & $script:FixtureScript | Out-Null } | Should -Throw '*certificate missing*'
        Should -Invoke docker -Times 0
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'reports container failure and restores the caller directory' {
        Mock docker { $global:LASTEXITCODE = 19 } -ParameterFilter { $args[0] -eq 'run' }
        { & $script:FixtureScript | Out-Null } | Should -Throw '*run*'
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
    It 'retains the normal build and run flow' {
        & $script:FixtureScript | Out-Null
        Should -Invoke docker -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'build' }
        Should -Invoke docker -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'run' }
        (Get-Location).Path | Should -BeExactly $script:StartDirectory
    }
}

AfterAll {
    if ($script:HadNativeExitCode) {
        Set-Variable -Name LASTEXITCODE -Scope Global -Value $script:InitialNativeExitCode
    } else {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
}
