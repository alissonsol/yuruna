<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42a70ad0-6755-40db-bc23-11288918bf2c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test storage preflight
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
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigValidator.psm1') -Force -DisableNameChecking
    $script:StorageFixture = @{}
    # Keep the driver stand-in inside the imported module so it cannot shadow
    # a real host driver in another suite sharing this process.
    . (Get-Module Test.ConfigValidator) {
        param($Fixture)
        $script:ProjectStorageFixture = $Fixture
        function Test-VMStorageCapacity {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The stub records the complete driver call through PSBoundParameters.')]
            param($VMName, $StartupMemoryBytes, $AdditionalStorageBytes, $ReserveBytes, $ProvisioningMemoryBytes)
            $script:ProjectStorageFixture.Arguments = @{} + $PSBoundParameters
            if ($script:ProjectStorageFixture.Throw) { throw 'volume probe unavailable' }
            return $script:ProjectStorageFixture.Reading
        }
    } $script:StorageFixture
}

AfterAll {
    Remove-Module Test.ConfigValidator -Force -ErrorAction SilentlyContinue
}

Describe 'Project storage admission' {
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ProjectRoot 'test') -Force
        $script:PolicyPath = Join-Path $script:ProjectRoot 'test/host-storage.requirements.json'
        $script:Policy = @{ schemaVersion = 1; hostType = 'host.windows.hyper-v'; reserveBytes = 2GB; virtualMachines = @(@{ name = 'core'; startupMemoryBytes = 12GB; additionalStorageBytes = 16GB }, @{ name = 'build'; startupMemoryBytes = 0; additionalStorageBytes = 16GB }) }
        $script:StorageFixture.Arguments = $null
        $script:StorageFixture.Reading = @{ allowed = $true; status = 'ready'; reason = 'capacity available'; volumes = @(@{ volume = 'C:'; freeBytes = 60GB; requiredBytes = 46GB }) }
        $script:StorageFixture.Throw = $false
    }

    It 'leaves projects without a storage declaration unchanged' {
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'not-applicable'
        $script:StorageFixture.Arguments | Should -BeNullOrEmpty
    }

    It 'does not apply Windows storage requirements on another host platform' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.ubuntu.kvm'
        $result.status | Should -Be 'not-applicable'
        $script:StorageFixture.Arguments | Should -BeNullOrEmpty
    }

    It 'passes exact per-VM requirements and a disk-only VM to the driver without rewriting policy' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $before = Get-Content -Raw -LiteralPath $script:PolicyPath
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'ready'
        $script:StorageFixture.Arguments.VMName.Count | Should -Be 2
        $script:StorageFixture.Arguments.StartupMemoryBytes.core | Should -Be 12GB
        $script:StorageFixture.Arguments.StartupMemoryBytes.build | Should -Be 0
        $script:StorageFixture.Arguments.AdditionalStorageBytes.build | Should -Be 16GB
        $script:StorageFixture.Arguments.ReserveBytes | Should -Be 2GB
        (Get-Content -Raw -LiteralPath $script:PolicyPath) | Should -BeExactly $before
    }

    It 'returns a known capacity shortage with the original volume evidence' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $script:StorageFixture.Reading = @{ allowed = $false; status = 'insufficient'; reason = 'C: needs 46 GiB'; volumes = @(@{ volume = 'C:'; freeBytes = 10GB; requiredBytes = 46GB }) }
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'insufficient'
        $result.allowed | Should -BeFalse
        $result.hostStorage.volumes[0].freeBytes | Should -Be 10GB
    }

    It 'passes an optional provisioning peak separately from the final topology' {
        $script:Policy.provisioningMemoryBytes = 12GB
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'ready'
        $script:StorageFixture.Arguments.ProvisioningMemoryBytes | Should -Be 12GB
    }

    It 'keeps an unavailable measurement distinct from zero capacity' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $script:StorageFixture.Reading = @{ allowed = $true; status = 'unknown'; reason = 'volume unavailable'; volumes = @(@{ freeBytes = $null }) }
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'unknown'
        $result.hostStorage.volumes[0].freeBytes | Should -BeNullOrEmpty
    }

    It 'retains a failed probe as unavailable instead of claiming a passing measurement' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $script:StorageFixture.Throw = $true
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'unknown'
        $result.reason | Should -Match 'volume probe unavailable'
    }

    It 'reports an unavailable helper without asserting a capacity measurement' {
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        Mock Get-Command -ModuleName Test.ConfigValidator -ParameterFilter { $Name -eq 'Test-VMStorageCapacity' } { $null }
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'unknown'
        $result.allowed | Should -BeTrue
        $result.hostStorage | Should -BeNullOrEmpty
        $script:StorageFixture.Arguments | Should -BeNullOrEmpty
    }

    It 'does not claim to check a provisioning allowance with an older helper' {
        $script:Policy.provisioningMemoryBytes = 12GB
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        Mock Get-Command -ModuleName Test.ConfigValidator -ParameterFilter { $Name -eq 'Test-VMStorageCapacity' } { @{ Parameters = @{} } }
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'unknown'
        $result.reason | Should -Match 'provisioning memory allowance'
        $script:StorageFixture.Arguments | Should -BeNullOrEmpty
    }

    It 'rejects malformed declarations before probing storage' -ForEach @('negative', 'fractional', 'duplicate', 'empty', 'unsupported-schema', 'bad-name', 'negative-provisioning') {
        switch ($_) {
            'negative' { $script:Policy.reserveBytes = -1 }
            'fractional' { $script:Policy.virtualMachines[0].startupMemoryBytes = 1.5 }
            'duplicate' { $script:Policy.virtualMachines[1].name = 'CORE' }
            'empty' { $script:Policy.virtualMachines = @() }
            'unsupported-schema' { $script:Policy.schemaVersion = 2 }
            'bad-name' { $script:Policy.virtualMachines[0].name = '../core' }
            'negative-provisioning' { $script:Policy.provisioningMemoryBytes = -1 }
        }
        $script:Policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PolicyPath
        $result = Test-ProjectHostStorage -ProjectRoot $script:ProjectRoot -HostType 'host.windows.hyper-v'
        $result.status | Should -Be 'invalid'
        $result.allowed | Should -BeFalse
        $script:StorageFixture.Arguments | Should -BeNullOrEmpty
    }
}
