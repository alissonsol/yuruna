<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42117e6a-8e6c-4f6c-9d1a-2b8f9a0c7d3e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service vm unknown observe-only host-refresh pester
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
    Restore-YurunaServiceVM's 'unknown' handling and -ObserveOnly mode.
    Separate file from Test.ServiceVm.Tests.ps1 on purpose: those cases
    depend on NO Get-VMState/Start-VM being resolvable at all (the
    no-host-driver path), and this file defines fake ones globally for its
    own cases -- keeping them apart means neither suite can leak state into
    the other through Pester's shared per-file runspace.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -DisableNameChecking -Global

    # Minimal fakes standing in for a per-host driver, resolved by
    # Restore-YurunaServiceVM via Get-Command exactly as a real one would be.
    $script:FakeState = @{}
    function global:Get-VMState {
        param([string]$VMName)
        if ($script:FakeState.ContainsKey($VMName)) { return $script:FakeState[$VMName] }
        return 'absent'
    }
    $script:StartCalls = [System.Collections.Generic.List[string]]::new()
    function global:Start-VM {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Fake driver signature matches the real Start-VM contract; -Confirm is accepted and ignored, same as the fake never mutating anything real.')]
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([hashtable])]
        param([string]$VMName)
        if (-not $PSCmdlet.ShouldProcess($VMName, 'Fake start')) { return @{ success = $false; errorMessage = 'WhatIf' } }
        $script:StartCalls.Add($VMName)
        $script:FakeState[$VMName] = 'running'
        return @{ success = $true; errorMessage = $null }
    }
}

AfterAll {
    Remove-Item function:global:Get-VMState -ErrorAction SilentlyContinue
    Remove-Item function:global:Start-VM -ErrorAction SilentlyContinue
}

Describe 'Restore-YurunaServiceVM -- unknown state never authorizes a start' {
    BeforeEach {
        $script:FakeState = @{}
        $script:StartCalls.Clear()
    }

    It 'reports state-unknown, and never calls Start-VM, for a service whose probe could not be confirmed' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:FakeState[$svc.VMName] = 'unknown'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'state-unknown'
        $r[0].Healthy | Should -Be $false
        $script:StartCalls.Count | Should -Be 0 -Because 'a denied or timed-out probe must never be treated as registered-and-stopped'
    }

    It 'still starts a genuinely stopped VM normally' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:FakeState[$svc.VMName] = 'stopped'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'started'
        $script:StartCalls | Should -Contain $svc.VMName
    }

    It 'leaves a running service alone' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:FakeState[$svc.VMName] = 'running'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -Confirm:$false)
        $r[0].Outcome | Should -Be 'running'
        $script:StartCalls.Count | Should -Be 0
    }
}

Describe 'Restore-YurunaServiceVM -ObserveOnly -- never starts anything' {
    BeforeEach {
        $script:FakeState = @{}
        $script:StartCalls.Clear()
    }

    It 'reports the confirmed stopped state without starting it' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:FakeState[$svc.VMName] = 'stopped'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -ObserveOnly -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'stopped'
        $script:StartCalls.Count | Should -Be 0 -Because 'ObserveOnly must never call Start-VM'
    }

    It 'still reports absent and state-unknown as themselves, not as stopped' {
        $svcs = @(Get-YurunaServiceVmRoster)
        $script:FakeState[$svcs[0].VMName] = 'absent'
        $script:FakeState[$svcs[1].VMName] = 'unknown'

        $r0 = @(Restore-YurunaServiceVM -Key $svcs[0].Key -ObserveOnly -Confirm:$false)
        $r0[0].Outcome | Should -Be 'absent'
        $r1 = @(Restore-YurunaServiceVM -Key $svcs[1].Key -ObserveOnly -Confirm:$false)
        $r1[0].Outcome | Should -Be 'state-unknown'
        $script:StartCalls.Count | Should -Be 0
    }

    It 'never calls Start-VM across the whole roster, whatever state each service is in' {
        $svcs = @(Get-YurunaServiceVmRoster)
        $states = @('absent', 'unknown', 'stopped', 'running')
        for ($i = 0; $i -lt $svcs.Count; $i++) { $script:FakeState[$svcs[$i].VMName] = $states[$i % $states.Count] }

        $r = @(Restore-YurunaServiceVM -ObserveOnly -Confirm:$false)
        $r.Count | Should -Be $svcs.Count
        $script:StartCalls.Count | Should -Be 0 -Because 'ObserveOnly is a pure read across the entire roster, never a mutation'
    }
}
