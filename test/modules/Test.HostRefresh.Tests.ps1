<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4253a1e0-9103-4f16-8461-710adf91da65
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh rung declaration pester
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
    Get-VirtualizationRepairRung: a pure, host-neutral declaration. No
    driver import, no native calls -- every case here can and does run on
    any platform.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.HostRefresh.psm1') -Force -DisableNameChecking
    $script:AllHostTypes = @('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v')
    $script:ExpectedNames = @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung',
        'restart-broker', 'reapply-settings', 'reinstall', 'reboot')
}

Describe 'Get-VirtualizationRepairRung -- shape and completeness' {
    It 'returns all eight rungs, in Order, for every supported host type' {
        foreach ($hostType in $script:AllHostTypes) {
            $rungs = @(Get-VirtualizationRepairRung -HostType $hostType)
            $rungs.Count | Should -Be 8 -Because "$hostType must declare every rung, including unavailable ones"
            @($rungs.Name) | Should -Be $script:ExpectedNames
            @($rungs.Order) | Should -Be @(0, 1, 2, 3, 4, 5, 6, 7)
        }
    }

    It 'never unrolls to a scalar for a single-element intermediate use' {
        # The classic PowerShell trap: a caller who forgets @(...) around a
        # one-rung filter gets a bare pscustomobject instead of an array,
        # and .Count on it silently reads a property that does not exist as
        # $null rather than throwing.
        $rungs = @(Get-VirtualizationRepairRung -HostType 'host.macos.utm')
        $probeOnly = @($rungs | Where-Object { $_.Name -eq 'probe' })
        $probeOnly.Count | Should -Be 1
        $probeOnly[0].Name | Should -Be 'probe'
    }

    It 'refuses an unrecognized host type rather than silently returning nothing' {
        { Get-VirtualizationRepairRung -HostType 'host.not-a-real-platform' } | Should -Throw
    }

    It 'every row carries all eight declared fields with the right types' {
        foreach ($hostType in $script:AllHostTypes) {
            foreach ($rung in @(Get-VirtualizationRepairRung -HostType $hostType)) {
                $rung.Name              | Should -BeOfType [string]
                $rung.Order             | Should -BeOfType [int]
                $rung.Destructive       | Should -BeOfType [bool]
                $rung.RequiresElevation | Should -BeOfType [bool]
                $rung.RequiresSession   | Should -BeOfType [bool]
                $rung.EstimatedSeconds  | Should -BeOfType [int]
                $rung.Available         | Should -BeOfType [bool]
                if (-not $rung.Available) {
                    $rung.UnavailableReason | Should -Not -BeNullOrEmpty -Because "$hostType/$($rung.Name) is marked unavailable and must say why"
                } else {
                    $rung.UnavailableReason | Should -BeNullOrEmpty -Because "$hostType/$($rung.Name) is marked available and should carry no leftover reason"
                }
            }
        }
    }
}

Describe 'Get-VirtualizationRepairRung -- v1 availability matches the reviewed plan' {
    It 'rung 0 (probe) is available and never destructive, on every platform' {
        foreach ($hostType in $script:AllHostTypes) {
            $probe = @(Get-VirtualizationRepairRung -HostType $hostType | Where-Object { $_.Name -eq 'probe' })[0]
            $probe.Available    | Should -Be $true
            $probe.Destructive  | Should -Be $false
        }
    }

    It 'rungs 3 and above are unavailable everywhere until their own evidence gates pass' {
        foreach ($hostType in $script:AllHostTypes) {
            $highRungs = @(Get-VirtualizationRepairRung -HostType $hostType | Where-Object { $_.Order -ge 3 })
            $highRungs.Count | Should -Be 5
            foreach ($rung in $highRungs) {
                $rung.Available | Should -Be $false -Because "$hostType/$($rung.Name) has no validated live-host evidence in this repository yet"
            }
        }
    }

    It 'rung 7 (reboot) is unavailable on every platform: no automatic supervision across a reboot exists' {
        foreach ($hostType in $script:AllHostTypes) {
            $reboot = @(Get-VirtualizationRepairRung -HostType $hostType | Where-Object { $_.Name -eq 'reboot' })[0]
            $reboot.Available | Should -Be $false
        }
    }
}
