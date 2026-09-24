<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4266a8d2-4adb-4edb-a8b6-0875ae9138c8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm libvirt virsh responsive host-refresh pester
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
    The KVM driver's Test-VirtualizationResponsive probe and the Get-VMState
    precedence fix (a denied/unrecognized nonzero exit is 'unknown', never
    'absent'; only a completed not-found response is 'absent'). Runs against
    the real local libvirtd, not a fake, wherever this host actually has one
    -- unlike the macOS/Windows driver suites, this is genuinely exercised
    on Linux CI.
#>

BeforeAll {
    # Computed here, inside BeforeAll, not as a top-level discovery-time
    # statement and not read through an It block's -Skip parameter: Pester
    # evaluates -Skip during discovery, before any BeforeAll runs, and a
    # plain top-level $script: assignment does not reliably survive from
    # Pester's discovery pass into its separate run pass either. BeforeAll
    # is the one place a $script: variable set here is guaranteed visible to
    # every It in the same file, which is also how the existing
    # Test.UtmGhostRegistration.Tests.ps1 / Test.UtmServiceVmSuspend.Tests
    # .ps1 handle the same constraint.
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:KvmModule = Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
    $script:HasRealLibvirt = $false
    if ($IsLinux -and (Get-Command virsh -ErrorAction SilentlyContinue)) {
        $null = & virsh --connect qemu:///system list --name 2>&1
        $script:HasRealLibvirt = ($LASTEXITCODE -eq 0)
    }
    Import-Module $script:KvmModule -Force -DisableNameChecking -Global -WarningAction SilentlyContinue

    # A throwaway PATH entry with a scripted `virsh` lets the missing-client
    # and denied/unrecognized-failure cases run regardless of whether this
    # host has a real libvirtd, without ever touching the real one.
    $script:FakeBinDir = Join-Path ([IO.Path]::GetTempPath()) ("yrn-kvmfake-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:FakeBinDir -Force | Out-Null

    function New-FakeVirsh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the suite-owned temp bin dir that AfterAll removes.')]
        param([string]$Body)
        $shim = Join-Path $script:FakeBinDir 'virsh'
        Set-Content -LiteralPath $shim -Value ("#!/bin/sh`n" + $Body) -NoNewline -Encoding ascii
        & chmod +x $shim
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:FakeBinDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-VirtualizationResponsive -- real libvirtd on this host' {
    It 'reports Responsive against a genuinely reachable libvirtd' {
        if (-not $script:HasRealLibvirt) { Set-ItResult -Skipped -Because 'no reachable libvirtd on this host'; return }
        $r = Test-VirtualizationResponsive
        $r.state       | Should -Be 'Responsive'
        $r.reason      | Should -Be 'responsive'
        $r.started     | Should -Be $true
        $r.timedOut    | Should -Be $false
        $r.elapsedMs   | Should -BeGreaterOrEqual 0
        [datetime]$r.observedUtc | Should -Not -BeNullOrEmpty
    }

    It 'Get-VMState reports absent for a name that genuinely does not exist' {
        if (-not $script:HasRealLibvirt) { Set-ItResult -Skipped -Because 'no reachable libvirtd on this host'; return }
        (Get-VMState -VMName ("definitely-absent-" + [Guid]::NewGuid().ToString('n'))) | Should -Be 'absent'
    }
}

Describe 'Test-VirtualizationResponsive -- missing client and denied/unrecognized failures (fake virsh)' {
    BeforeEach {
        $script:OrigPath = $env:PATH
    }
    AfterEach {
        $env:PATH = $script:OrigPath
    }

    It 'reports missing-client, not a false Responsive or a hang, when virsh is not on PATH' {
        $env:PATH = '/nonexistent-yrn-test-path'
        $r = Test-VirtualizationResponsive
        $r.state    | Should -Be 'Undetermined'
        $r.reason   | Should -Be 'missing-client'
        $r.started  | Should -Be $false
    }

    It 'classifies a permission-denied nonzero exit as Undetermined, never Responsive or Unresponsive' {
        New-FakeVirsh 'echo "error: authentication unavailable: could not connect to any" 1>&2; exit 1'
        $env:PATH = "$script:FakeBinDir" + [IO.Path]::PathSeparator + $script:OrigPath
        $r = Test-VirtualizationResponsive
        $r.state  | Should -Be 'Undetermined'
        $r.reason | Should -Be 'permission-denied'
    }

    It 'Get-VMState reads a denied probe as unknown, never absent' {
        New-FakeVirsh 'echo "error: authentication unavailable: could not connect to any" 1>&2; exit 1'
        $env:PATH = "$script:FakeBinDir" + [IO.Path]::PathSeparator + $script:OrigPath
        (Get-VMState -VMName 'irrelevant') | Should -Be 'unknown' `
            -Because 'a denied probe collapsed to absent is the exact bug this fix removes: callers treat absent as license to build or reuse a name'
    }

    It 'Get-VMState still reads a genuinely recognized not-found response as absent through the fake' {
        New-FakeVirsh @'
echo "error: failed to get domain 'ghost-vm'" 1>&2
exit 1
'@
        $env:PATH = "$script:FakeBinDir" + [IO.Path]::PathSeparator + $script:OrigPath
        (Get-VMState -VMName 'ghost-vm') | Should -Be 'absent'
    }

    It 'reports timeout, not a hang or a false Responsive, when virsh never answers' {
        New-FakeVirsh 'sleep 30'
        $env:PATH = "$script:FakeBinDir" + [IO.Path]::PathSeparator + $script:OrigPath
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 2
        $sw.Stop()
        $r.state    | Should -Be 'Unresponsive'
        $r.reason   | Should -Be 'timeout'
        $r.timedOut | Should -Be $true
        $sw.ElapsedMilliseconds | Should -BeLessThan 6000 -Because 'a wedged control channel must be reported in seconds, not left to the caller''s watchdog'
    }
}
