<#PSScriptInfo
.VERSION 2026.09.24
.GUID 421c8f6e-9b0a-4c1d-8e2f-3a4b5c6d7e8f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer cycle option forwarding host-refresh pester
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
    All six operator options (-ConfigPath, -NoGitPull, -NoStatusService,
    -NoConfigGate, -CycleDelaySeconds, -logLevel) actually reach the
    per-cycle child process, not just -Cycle. Before this fix
    Invoke-OuterCycleDispatch passed only -Cycle to Invoke-
    TestCycleRunner.ps1, so every other option silently reverted to that
    script's own defaults on the second and every later cycle.
#>

BeforeAll {
    # $script: prefix throughout, not a bare local: Pester 5 runs each It in
    # a scope that cannot see a plain variable assigned in BeforeAll.
    $script:Here     = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:Here)
    Import-Module (Join-Path $script:Here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $script:Here 'Test.StateFile.psm1')       -Force -DisableNameChecking -Global

    $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("yrn-cycfwd-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-OuterCycleDispatch -- forwards every operator option to the child argv (mocked spawn)' {
    BeforeEach {
        $script:CapturedArgs = $null
        $script:PriorRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:TmpDir
        Mock -CommandName Start-Process -ModuleName Test.RunnerOuterLoop -MockWith {
            $script:CapturedArgs = $ArgumentList
            [pscustomobject]@{ Id = $PID; HasExited = $true; ExitCode = 0 }
        }
    }
    AfterEach {
        $env:YURUNA_RUNTIME_DIR = $script:PriorRuntimeDir
    }

    It 'forwards -ConfigPath, -NoGitPull, -NoStatusService, -NoConfigGate, -CycleDelaySeconds and -logLevel' {
        $state = @{
            CycleScript       = Join-Path $script:TmpDir 'fake-cycle.ps1'
            PwshExe           = 'pwsh'
            ShutdownState     = @{ Requested = $false }
            ConfigPath        = '/tmp/custom.config.yml'
            NoGitPull         = $true
            NoStatusService   = $true
            NoConfigGate      = $true
            CycleDelaySeconds = 5
            LogLevel          = 'Debug'
        }
        Set-Content -LiteralPath $state.CycleScript -Value '# fixture' -Encoding utf8
        $null = Invoke-OuterCycleDispatch -State $state -Cycle 7

        $capturedArgList = [string[]]$script:CapturedArgs
        $capturedArgList | Should -Contain '-ConfigPath'
        ($capturedArgList -join ' ') | Should -Match 'custom\.config\.yml'
        $capturedArgList | Should -Contain '-NoGitPull'
        $capturedArgList | Should -Contain '-NoStatusService'
        $capturedArgList | Should -Contain '-NoConfigGate'
        $capturedArgList | Should -Contain '-CycleDelaySeconds'
        $capturedArgList | Should -Contain '5'
        $capturedArgList | Should -Contain '-logLevel'
        $capturedArgList | Should -Contain 'Debug'
        $capturedArgList | Should -Contain '-Cycle'
        $capturedArgList | Should -Contain '7'
    }

    It 'omits every switch when the State does not set it, rather than passing a false-y literal' {
        $state = @{
            CycleScript   = Join-Path $script:TmpDir 'fake-cycle2.ps1'
            PwshExe       = 'pwsh'
            ShutdownState = @{ Requested = $false }
        }
        Set-Content -LiteralPath $state.CycleScript -Value '# fixture' -Encoding utf8
        $null = Invoke-OuterCycleDispatch -State $state -Cycle 1

        $capturedArgList = [string[]]$script:CapturedArgs
        $capturedArgList | Should -Not -Contain '-NoGitPull'
        $capturedArgList | Should -Not -Contain '-NoStatusService'
        $capturedArgList | Should -Not -Contain '-NoConfigGate'
        $capturedArgList | Should -Not -Contain '-ConfigPath'
        $capturedArgList | Should -Not -Contain '-logLevel'
        $capturedArgList | Should -Be @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + $state.CycleScript + '"'), '-Cycle', '1')
    }
}

Describe 'Real three-process option propagation: outer dispatch -> cycle script -> inner argv' {
    It 'a real Invoke-TestCycleRunner.ps1-shaped script receives and re-forwards -NoConfigGate through New-InnerRunnerArgList' {
        # Not a mock: spawns a real, minimal stand-in for Invoke-TestCycleRunner
        # .ps1 that imports the real Test.InnerSpawn.psm1 and writes out the
        # argv it would hand the inner, so this asserts the actual chain
        # (Invoke-OuterCycleDispatch's argv -> the child's own $PSBoundParameters
        # -> New-InnerRunnerArgList's forwarding) rather than any one link
        # in isolation.
        $priorRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:TmpDir
        $captureFile = Join-Path $script:TmpDir 'inner-argv-capture.txt'
        Remove-Item -LiteralPath $captureFile -ErrorAction SilentlyContinue
        $stubCycleScript = Join-Path $script:TmpDir 'stub-cycle-runner.ps1'
        $innerSpawnModule = Join-Path $script:Here 'Test.InnerSpawn.psm1'
        $stubBody = @"
param(
    [int]`$Cycle = 1,
    [string]`$ConfigPath = `$null,
    [switch]`$NoGitPull,
    [switch]`$NoStatusService,
    [switch]`$NoConfigGate,
    [int]`$CycleDelaySeconds = 30,
    [string]`$logLevel
)
Import-Module '$innerSpawnModule' -Force -DisableNameChecking
`$fakeInner = Join-Path (Split-Path -Parent '$captureFile') 'fake-inner.ps1'
`$argv = New-InnerRunnerArgList -ScriptPath `$fakeInner -Parameters `$PSBoundParameters -ExcludeParameter @('Cycle')
Set-Content -LiteralPath '$captureFile' -Value (`$argv -join "``n") -Encoding utf8
exit 0
"@
        Set-Content -LiteralPath $stubCycleScript -Value $stubBody -Encoding utf8

        $state = @{
            CycleScript       = $stubCycleScript
            PwshExe           = (Get-Process -Id $PID).Path
            ShutdownState     = @{ Requested = $false }
            NoConfigGate      = $true
            CycleDelaySeconds = 9
        }
        if (-not $state.PwshExe) { $state.PwshExe = 'pwsh' }
        $result = Invoke-OuterCycleDispatch -State $state -Cycle 42
        $result.Outcome | Should -Be 'completed'
        $result.ExitCode | Should -Be 0

        (Test-Path -LiteralPath $captureFile) | Should -Be $true -Because 'the stub cycle script must have actually run and captured what it would forward to the inner'
        $capturedArgv = Get-Content -Raw -LiteralPath $captureFile
        $capturedArgv | Should -Match '-NoConfigGate' -Because 'the option travels outer dispatch -> cycle process $PSBoundParameters -> New-InnerRunnerArgList unbroken'
        $capturedArgv | Should -Match '-CycleDelaySeconds'
        $capturedArgv | Should -Match '9'
        $env:YURUNA_RUNTIME_DIR = $priorRuntimeDir
    }
}
