<#PSScriptInfo
.VERSION 2026.09.27
.GUID 420a4a34-c1ef-485b-9c87-3ba17e1a4250
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host identity seed pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

BeforeAll {
    $script:PreviousRuntime = $env:YURUNA_RUNTIME_DIR
    $script:PreviousSeed = $env:YURUNA_HOST_ID_SEED
    $env:YURUNA_HOST_ID_SEED = $null
    $script:SeedModule = Import-Module (Join-Path $PSScriptRoot 'Test.HostIdentitySeed.psm1') -PassThru -DisableNameChecking
    # Override only the hardware boundary in the real module. Neither caller
    # may import a second copy or bypass the shared lazy policy.
    & $script:SeedModule {
        $script:SeedCalls = 0
        $script:SeedFails = $false
        function script:Get-HostIdentitySeedUuid {
            param([switch]$AllowSudo)
            $script:SeedCalls++
            if (-not $AllowSudo) { throw 'The noninteractive sudo policy was omitted.' }
            if ($script:SeedFails) { throw 'Hardware key unavailable.' }
            return '42abcdef0123456789abcdef01234567'
        }
    }
    Import-Module (Join-Path $PSScriptRoot 'Test.Perf.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -DisableNameChecking
}

AfterAll {
    $env:YURUNA_RUNTIME_DIR = $script:PreviousRuntime
    $env:YURUNA_HOST_ID_SEED = $script:PreviousSeed
}

Describe 'Shared lazy host identity policy' {
    It 'imports both callers without reading hardware' {
        (& $script:SeedModule { $script:SeedCalls }) | Should -Be 0
    }

    It 'gives both identity writers the same seed and retains a persisted id' {
        foreach ($command in 'Get-PerfHostUuid', 'Get-YurunaHostId') {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive $command
            & $command | Should -Be '42abcdef0123456789abcdef01234567'
            $file = Join-Path $env:YURUNA_RUNTIME_DIR 'host.uuid'
            [IO.File]::WriteAllText($file, '42ffffffffffffffffffffffffffffff')
            & $command | Should -Be '42ffffffffffffffffffffffffffffff'
        }
        (& $script:SeedModule { $script:SeedCalls }) | Should -Be 2
    }

    It 'honors random override without reading hardware' {
        $calls = & $script:SeedModule { $script:SeedCalls }
        $env:YURUNA_HOST_ID_SEED = 'random'
        try {
            Resolve-SeededHostId | Should -BeNullOrEmpty
            (& $script:SeedModule { $script:SeedCalls }) | Should -Be $calls
        } finally { $env:YURUNA_HOST_ID_SEED = $null }
    }

    It 'allows random fallback if hardware derivation throws' {
        & $script:SeedModule { $script:SeedFails = $true }
        try {
            Resolve-SeededHostId | Should -BeNullOrEmpty
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'unavailable'
            Get-YurunaHostId | Should -Match '^42[0-9a-f]{30}$'
        } finally { & $script:SeedModule { $script:SeedFails = $false } }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
