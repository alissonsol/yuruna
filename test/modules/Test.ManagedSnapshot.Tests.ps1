<#PSScriptInfo
.VERSION 2026.09.18
.GUID 427cd801-2a06-4478-aac2-bff9219c1fdb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test snapshot provenance
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
    $module = Import-Module (Join-Path $PSScriptRoot 'Test.SnapshotManifest.psm1') -Force -PassThru -DisableNameChecking
    $runner = Import-Module (Join-Path $PSScriptRoot 'Test.SequenceRunner.psm1') -Force -PassThru -DisableNameChecking
    $script:savedRuntime = $env:YURUNA_RUNTIME_DIR
    & $module {
        function script:Get-VMState { param($VMName) $null = $VMName; $script:FakeState }
        function script:Stop-VMForce {
            [CmdletBinding(SupportsShouldProcess)] [OutputType([bool])] param($VMName)
            if ($PSCmdlet.ShouldProcess($VMName)) { $script:FakeState = 'stopped' }
            return $true
        }
        function script:Remove-VM {
            [CmdletBinding(SupportsShouldProcess)] [OutputType([bool])] param($VMName)
            if ($PSCmdlet.ShouldProcess($VMName)) { $script:RemovedNames += $VMName; $script:FakeState = 'absent' }
            return $true
        }
    }
    & $runner {
        function script:Resolve-NamedSequenceChain { $script:FixturePlan }
        function script:Read-SequenceFile { param($Path) $script:FixtureSequences[$Path] }
        function script:Test-VMDiskSnapshot { $script:FixtureSnapshotPresent }
    }
}

Describe 'managed baseline provenance and invalidation' {
BeforeEach {
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $root -Force
    Set-Content -LiteralPath (Join-Path $root 'baseline.sh') -Value 'version=1'
    $policy = @{ maxAgeHours = 24; rebuildOnMismatch = $true; sourceFiles = @('baseline.sh') }
    $identity = Get-SnapshotSourceIdentity -RepoRoot $root -GuestKey guest.ubuntu.server.26 -Policy $policy `
        -Variables @{ username = 'website'; hostname = 'website'; password = 'do-not-store-this' }
    $null = Write-SnapshotManifest -VMName website -SnapshotId website -HostType host.windows.hyper-v `
        -Extra @{ managedBaseline = $true; sourceIdentity = $identity } -Confirm:$false
    & $module { $script:FakeState = 'running'; $script:RemovedNames = @() }
    $paths = @{}
    $sequences = @{}
    foreach ($name in @('start', 'baseline', 'consumer')) {
        $paths[$name] = Join-Path $root "$name.yml"
        Set-Content -LiteralPath $paths[$name] -Value 'fixture'
        $sequences[$paths[$name]] = @{ steps = @(@{ action = 'fixture' }) }
    }
    $sequences[$paths.consumer].requiresSnapshot = @{ id = 'website' }
    $sequences[$paths.consumer].snapshotPolicy = $policy
    $plan = @{ fullChain = @('start', 'baseline', 'consumer'); chainPaths = $paths
        effectiveVariables = @{ username = 'website'; hostname = 'website' }
        effectiveUsername = 'website'; effectiveHostname = 'website' }
    & $runner { param($Plan, $Sequences) $script:FixturePlan = $Plan; $script:FixtureSequences = $Sequences; $script:FixtureSnapshotPresent = $true } $plan $sequences
}

AfterAll { $env:YURUNA_RUNTIME_DIR = $script:savedRuntime }

    It 'hashes file contents but excludes credentials' {
        ($identity | ConvertTo-Json -Depth 8) | Should -Not -Match 'do-not-store-this'
        Set-Content -LiteralPath (Join-Path $root 'baseline.sh') -Value 'version=2'
        $changed = Get-SnapshotSourceIdentity -RepoRoot $root -GuestKey guest.ubuntu.server.26 -Policy $policy `
            -Variables @{ username = 'website'; hostname = 'website' }
        $changed.identitySha256 | Should -Not -Be $identity.identitySha256
    }

    It 'rejects a missing input instead of silently accepting an incomplete identity' {
        { Get-SnapshotSourceIdentity -RepoRoot $root -GuestKey guest.ubuntu.server.26 `
            -Policy @{ sourceFiles = @('missing.*') } } | Should -Throw
    }

    It 'accepts a fresh baseline with the expected identity' {
        (Test-SnapshotReusePolicy -VMName website -SnapshotId website -HostType host.windows.hyper-v `
            -Policy $policy -SourceIdentity $identity).Status | Should -Be reusable
    }

    It 'expires a baseline at its age limit' {
        (Test-SnapshotReusePolicy -VMName website -SnapshotId website -HostType host.windows.hyper-v `
            -Policy $policy -SourceIdentity $identity -NowUtc ([datetime]::UtcNow.AddHours(25))).Status | Should -Be stale
    }

    It 'rejects non-finite age limits instead of making a permanent baseline' {
        foreach ($limit in @([double]::NaN, [double]::PositiveInfinity)) {
            $policy.maxAgeHours = $limit
            { Test-SnapshotReusePolicy -VMName website -SnapshotId website -HostType host.windows.hyper-v `
                -Policy $policy -SourceIdentity $identity } | Should -Throw
        }
    }

    It 'refuses unrecognized snapshots even when automatic rebuild is selected' {
        $null = Write-SnapshotManifest -VMName website -SnapshotId website -HostType host.windows.hyper-v -Confirm:$false
        Remove-StaleManagedSnapshot -SnapshotId website -HostType host.windows.hyper-v `
            -Policy $policy -SourceIdentity $identity -Confirm:$false | Should -BeFalse
        @(& $module { $script:RemovedNames }).Count | Should -Be 0
    }

    It 'refuses a manifest from another host platform' {
        (Test-SnapshotReusePolicy -VMName website -SnapshotId website -HostType host.ubuntu.kvm `
            -Policy $policy -SourceIdentity $identity).Status | Should -Be refused
    }

    It 'honors WhatIf without touching the persisted VM' {
        $identity.identitySha256 = 'different'
        Remove-StaleManagedSnapshot -SnapshotId website -HostType host.windows.hyper-v `
            -Policy $policy -SourceIdentity $identity -WhatIf | Should -BeFalse
        @(& $module { $script:RemovedNames }).Count | Should -Be 0
    }

    It 'removes only the verified stale baseline and its sidecar before a rebuild' {
        $identity.identitySha256 = 'different'
        Remove-StaleManagedSnapshot -SnapshotId website -HostType host.windows.hyper-v `
            -Policy $policy -SourceIdentity $identity -Confirm:$false | Should -BeTrue
        @(& $module { $script:RemovedNames }) | Should -Be @('website')
        Get-SnapshotManifest -VMName website -SnapshotId website | Should -BeNullOrEmpty
    }

    It 'skips prerequisites only for a verified warm baseline' {
        $result = Resolve-TestSequencePlan -RepoRoot $root -SequencesDir $root -HostType host.windows.hyper-v `
            -SequenceName consumer -OsKey ubuntu.server.26
        $result.warmPath | Should -BeTrue
        $result.chainEntries.Count | Should -Be 1
        $result.chainEntries[0].name | Should -Be consumer
    }

    It 'retains the complete chain when the snapshot does not exist' {
        & $runner { $script:FixtureSnapshotPresent = $false }
        $result = Resolve-TestSequencePlan -RepoRoot $root -SequencesDir $root -HostType host.windows.hyper-v `
            -SequenceName consumer -OsKey ubuntu.server.26
        $result.warmPath | Should -BeFalse
        $result.chainEntries.Count | Should -Be 3
    }

    It 'rebuilds after a source change and never reuses the expired disk' {
        Set-Content -LiteralPath (Join-Path $root 'baseline.sh') -Value 'version=2'
        $result = Resolve-TestSequencePlan -RepoRoot $root -SequencesDir $root -HostType host.windows.hyper-v `
            -SequenceName consumer -OsKey ubuntu.server.26
        $result.resolveFailed | Should -BeFalse
        $result.warmPath | Should -BeFalse
        $result.chainEntries.Count | Should -Be 3
        @(& $module { $script:RemovedNames }) | Should -Be @('website')
    }
}
