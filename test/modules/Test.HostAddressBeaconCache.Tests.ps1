<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42daa1e0-4503-4661-8ae0-fcc1c9318aaf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host address beacon cache network pester
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
    Verify the beacon resolves its own address again only on a network
    change or an aged-out answer, not on every 15 s tick.
.DESCRIPTION
    Get-BeaconClockUtc is the module's own time seam, mocked here so age
    comparisons are driven by a value this file controls rather than a race
    against the real clock. [YurunaNetworkChange]::Version is a real,
    process-wide static counter with no reset of its own, so each test
    reads it once at the top (Reset-BeaconAddressState) and only asserts
    relative movement afterward, never an absolute value.

    A resolver passed as -Resolve is invoked from inside the module, across
    a module boundary a plain closure does not survive: a mutable
    [pscustomobject] captured by .GetNewClosure() is used everywhere a
    resolver needs to count its own calls, matching the fixture shape
    Test.GuestAddressChurn.Tests.ps1 already uses for the same reason.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.HostAddressBeacon.psm1') -Force -DisableNameChecking
    $script:BeaconScriptPath = Join-Path $PSScriptRoot 'Invoke-HostAddressBeacon.ps1'

    function Reset-BeaconAddressState {
        <# .SYNOPSIS
            Clears the kept answer and syncs the kept change version to the
            real counter's current value, so a test starts with no pending
            staleness from an earlier test's Bump() calls.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Resets in-memory module state for test isolation; there is nothing for an operator to confirm.')]
        param()
        InModuleScope Test.HostAddressBeacon {
            Set-Variable -Name BeaconAddress -Value '' -Scope Script
            Set-Variable -Name BeaconAddressResolvedUtc -Value ([datetime]::MinValue) -Scope Script
            Set-Variable -Name BeaconAddressChangeVersion -Value ([YurunaNetworkChange]::Version) -Scope Script
        }
    }

    function New-CountingResolver {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds a scriptblock and counter in memory; there is nothing for an operator to confirm.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Answer IS used -- inside the .GetNewClosure() scriptblock, which the analyzer does not follow.')]
        param([string]$Answer)
        $state = [pscustomobject]@{ Calls = 0 }
        $script = { $state.Calls++; $Answer }.GetNewClosure()
        return [pscustomobject]@{ Script = $script; State = $state }
    }
}

Describe 'Get-BeaconHostAddress resolves on change or on age, not on every call' {
    BeforeEach {
        Reset-BeaconAddressState
        $script:Clock = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Mock Get-BeaconClockUtc -ModuleName Test.HostAddressBeacon { $script:Clock }
    }

    It '8 calls inside a 120 s window resolve the address once' {
        $r = New-CountingResolver -Answer '203.0.113.5'
        for ($i = 0; $i -lt 8; $i++) {
            $script:Clock = $script:Clock.AddSeconds(10)
            $null = Get-BeaconHostAddress -Resolve $r.Script
        }
        $r.State.Calls | Should -Be 1
    }

    It 'resolves again once the kept answer is older than MaxAgeSeconds' {
        $r = New-CountingResolver -Answer '203.0.113.5'
        $null = Get-BeaconHostAddress -Resolve $r.Script -MaxAgeSeconds 120
        $r.State.Calls | Should -Be 1
        $script:Clock = $script:Clock.AddSeconds(121)
        $null = Get-BeaconHostAddress -Resolve $r.Script -MaxAgeSeconds 120
        $r.State.Calls | Should -Be 2
    }

    It 'resolves again as soon as the network-change counter advances' {
        $r = New-CountingResolver -Answer '203.0.113.5'
        $null = Get-BeaconHostAddress -Resolve $r.Script
        $r.State.Calls | Should -Be 1
        $null = Get-BeaconHostAddress -Resolve $r.Script
        $r.State.Calls | Should -Be 1 -Because 'nothing changed yet, and the answer is not even 1 second old'
        [YurunaNetworkChange]::Bump()
        $null = Get-BeaconHostAddress -Resolve $r.Script
        $r.State.Calls | Should -Be 2
    }

    It 'never caches an empty answer' {
        $r = New-CountingResolver -Answer ''
        1..3 | ForEach-Object { $null = Get-BeaconHostAddress -Resolve $r.Script }
        $r.State.Calls | Should -Be 3
    }

    It 'propagates a resolver that throws, and keeps no address behind it' {
        { Get-BeaconHostAddress -Resolve { throw 'fixture-resolver-failure' } } | Should -Throw '*fixture-resolver-failure*'
        $r = New-CountingResolver -Answer '203.0.113.9'
        $after = Get-BeaconHostAddress -Resolve $r.Script
        $after | Should -Be '203.0.113.9'
        $r.State.Calls | Should -Be 1 -Because 'the failed attempt must not have left a cached answer the next call could serve instead of retrying'
    }
}

Describe 'the beacon loop and its static source' {
    It 'passes the resolved address to Invoke-HostAddressBeaconTick -CurrentAddress' {
        $ast = Get-YurunaTestFileAst -Path $script:BeaconScriptPath
        $assign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$current' }, $true)
        $assign | Should -Not -BeNullOrEmpty -Because 'the loop no longer resolves the address into $current'
        $tickCall = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-HostAddressBeaconTick' }, $true)
        $tickCall | Should -Not -BeNullOrEmpty
        (Get-YurunaTestCommandArgumentAst -Command $tickCall -Name 'CurrentAddress').Extent.Text | Should -Be '$current'
    }
    It 'resolves through the cached Get-BeaconHostAddress, not Get-BestHostIp on every tick' {
        $text = Get-Content -Raw -LiteralPath $script:BeaconScriptPath
        $text | Should -Match '\$current\s*=\s*\[string\]\(Get-BeaconHostAddress\)'
        $text | Should -Not -Match '\$current\s*=\s*\[string\]\(Get-BestHostIp\)'
    }
}
