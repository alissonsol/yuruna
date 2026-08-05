<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42a9b8c7-d6e5-4f43-8210-9a8b7c6d5e40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test firewall statusservice pester
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
    Pester coverage for Test.StatusFirewall.psm1: the cross-platform
    Set-YurunaStatusFirewallRule that opens the status-service port so LAN
    clients reach http://<host>:<port>/status/.
.DESCRIPTION
    Throw-based Assert-* helpers (Pester 4.10.1). Every firewall mutation is
    mocked in module scope, so no test ever touches the real host firewall.
    Platform branches are gated on $IsWindows / $IsLinux and only defined where
    they can run; the cross-platform contract block runs everywhere.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.StatusFirewall.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

Describe 'Get-YurunaStatusFirewallRuleName' {
    It 'builds the canonical Windows rule DisplayName' {
        Assert-Equal -Expected 'Yuruna: Allow inbound TCP :8080 (Status service)' -Actual (Get-YurunaStatusFirewallRuleName -Port 8080)
    }
    It 'is port-specific so two ports never collide on one rule' {
        Assert-True ((Get-YurunaStatusFirewallRuleName -Port 8080) -ne (Get-YurunaStatusFirewallRuleName -Port 9090)) 'distinct ports -> distinct names'
    }
}

Describe 'Set-YurunaStatusFirewallRule result contract' {
    It 'returns the documented shape and never throws (self-heal call)' {
        $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive -WhatIf 3>$null 6>$null
        foreach ($p in 'Platform', 'Ensured', 'Changed', 'Blocked', 'Message') {
            Assert-True ($null -ne $r.PSObject.Properties[$p]) "result carries a $p property"
        }
    }
    It 'reports the running platform' {
        $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive -WhatIf 3>$null 6>$null
        $expected = if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'unknown' }
        Assert-Equal -Expected $expected -Actual $r.Platform
    }
    It 'never reports Ensured and Blocked at the same time' {
        $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive -WhatIf 3>$null 6>$null
        Assert-False ($r.Ensured -and $r.Blocked) 'a port is either reachable or blocked, not both'
    }
}

if ($IsWindows) {
    Describe 'Set-YurunaStatusFirewallRule (Windows)' {
        It 'is Ensured with no mutation when the rule already exists, correct and enabled' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { [pscustomobject]@{ DisplayName = 'x'; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' } }
            Mock Get-YurunaRulePortFilter -ModuleName Test.StatusFirewall { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '8080' } }
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $false }  # not even consulted
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True  $r.Ensured 'present + correct + enabled -> Ensured'
            Assert-False $r.Changed 'no mutation needed'
            Assert-False $r.Blocked 'not blocked'
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
        }
        It 'is Blocked (no mutation) when the rule is missing and the process is not elevated' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { $null }
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $false }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 3>$null
            Assert-True  $r.Blocked 'missing rule + unprivileged -> caller should warn'
            Assert-False $r.Ensured 'not reachable'
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
        }
        It 'creates the rule when missing and elevated' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { $null }
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'a rule was created'
            Assert-True $r.Ensured 'now reachable'
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
        }
        It 'rebuilds a rule whose port no longer matches (elevated)' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { [pscustomobject]@{ DisplayName = 'x'; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' } }
            Mock Get-YurunaRulePortFilter -ModuleName Test.StatusFirewall { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '9999' } }  # stale port
            Mock Remove-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'rule rebuilt to the current port'
            Assert-MockCalled -CommandName Remove-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
        }
        It 'enables a correct-but-disabled rule without a full rebuild (elevated)' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { [pscustomobject]@{ DisplayName = 'x'; Enabled = 'False'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' } }
            Mock Get-YurunaRulePortFilter -ModuleName Test.StatusFirewall { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '8080' } }
            Mock Enable-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'rule enabled'
            Assert-MockCalled -CommandName Enable-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
        }
    }
}

if ($IsLinux) {
    Describe 'Set-YurunaStatusFirewallRule (Linux / ufw)' {
        It 'is indeterminate (not Blocked) when ufw is absent -- nftables/iptables are not managed' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { $null }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 4>$null
            Assert-False $r.Ensured 'unknown -> not asserted reachable'
            Assert-False $r.Blocked 'unknown -> not warned'
        }
        It 'is Ensured with no change when ufw is inactive (no inbound DROP)' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall { @{ ExitCode = 0; Output = "Status: inactive`n" } }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 4>$null
            Assert-True  $r.Ensured 'inactive ufw does not drop'
            Assert-False $r.Changed 'nothing added'
        }
        It 'is Ensured with no change when the port is already allowed' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall { @{ ExitCode = 0; Output = "Status: active`n8080/tcp                   ALLOW       Anywhere`n" } }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 4>$null
            Assert-True  $r.Ensured 'already allowed'
            Assert-False $r.Changed 'no add needed'
        }
        It 'adds the allow when ufw is active and the port is not yet allowed' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n22/tcp                     ALLOW       Anywhere`n" } }
                return @{ ExitCode = 0; Output = 'Rule added' }   # the 'allow' call
            }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'ufw allow was added'
            Assert-True $r.Ensured 'now reachable'
        }
        It 'is Blocked when the port is not allowed and the ufw allow fails (unprivileged)' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n22/tcp                     ALLOW       Anywhere`n" } }
                return @{ ExitCode = 1; Output = 'ERROR: You need to be root' }  # allow denied
            }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 3>$null
            Assert-True  $r.Blocked 'active + not allowed + could not fix -> Blocked'
            Assert-False $r.Ensured 'not reachable'
        }
        It 'is indeterminate when ufw status cannot be read (unprivileged, no cached sudo)' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall { @{ ExitCode = 1; Output = 'sudo: a password is required' } }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 4>$null
            Assert-False $r.Ensured 'cannot confirm reachable'
            Assert-False $r.Blocked 'must not warn a healthy host every cycle'
        }
    }
}
