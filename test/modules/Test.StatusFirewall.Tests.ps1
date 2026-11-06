<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4241baeb-2bf8-4508-8226-252c7f0dd6ac
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
    Throw-based Assert-* helpers (Pester 5.x). Every firewall mutation is
    mocked in module scope, so no test ever touches the real host firewall.
    Platform branches are gated on $IsWindows / $IsLinux and only defined where
    they can run; the cross-platform contract block runs everywhere.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.StatusFirewall.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Runs a fixture script in a child pwsh. Its output reaches assertion
# messages, which land in the NUnit XML, where the escape sequence of a
# colored WARNING line or a stray control character truncates the report.
function Invoke-FixtureScript {
    param([Parameter(Mandatory)][string]$Path)
    $lines = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Path 2>&1 | ForEach-Object {
            [regex]::Replace([regex]::Replace("$_", '\x1b\[[0-9;?]*[ -/]*[@-~]', ''), '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
        })
    return @{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

}

Describe 'Get-YurunaStatusFirewallRuleName' {
    It 'builds the canonical Windows rule DisplayName' {
        Assert-Equal -Expected 'Yuruna: Allow inbound TCP :8080 (Status service)' -Actual (Get-YurunaStatusFirewallRuleName -Port 8080)
    }
    It 'is port-specific so two ports never collide on one rule' {
        Assert-True ((Get-YurunaStatusFirewallRuleName -Port 8080) -ne (Get-YurunaStatusFirewallRuleName -Port 9090)) 'distinct ports -> distinct names'
    }
}

Describe 'Get-YurunaStatusFirewallRuleComment' {
    It 'is printable ASCII without a quote character, which ufw refuses in a comment' {
        $comment = Get-YurunaStatusFirewallRuleComment
        # No edge space either: 'ufw status' ends the rule's line with it.
        Assert-Match '^[!-~]([ -~]*[!-~])?$' $comment 'printable ASCII, no leading or trailing space'
        Assert-False ($comment -match "['""]") "no quote character: $comment"
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
            Should -Invoke -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
        }
        It 'is Blocked (no mutation) when the rule is missing and the process is not elevated' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { $null }
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $false }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 3>$null
            Assert-True  $r.Blocked 'missing rule + unprivileged -> caller should warn'
            Assert-False $r.Ensured 'not reachable'
            Should -Invoke -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
        }
        It 'creates the rule when missing and elevated' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { $null }
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'a rule was created'
            Assert-True $r.Ensured 'now reachable'
            Should -Invoke -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
        }
        It 'rebuilds a rule whose port no longer matches (elevated)' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { [pscustomobject]@{ DisplayName = 'x'; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' } }
            Mock Get-YurunaRulePortFilter -ModuleName Test.StatusFirewall { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '9999' } }  # stale port
            Mock Remove-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'rule rebuilt to the current port'
            Should -Invoke -CommandName Remove-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
            Should -Invoke -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
        }
        It 'enables a correct-but-disabled rule without a full rebuild (elevated)' {
            Mock Get-NetFirewallRule -ModuleName Test.StatusFirewall { [pscustomobject]@{ DisplayName = 'x'; Enabled = 'False'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' } }
            Mock Get-YurunaRulePortFilter -ModuleName Test.StatusFirewall { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '8080' } }
            Mock Enable-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock New-NetFirewallRule -ModuleName Test.StatusFirewall {}
            Mock Test-YurunaHostElevated -ModuleName Test.StatusFirewall { $true }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'rule enabled'
            Should -Invoke -CommandName Enable-NetFirewallRule -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It
            Should -Invoke -CommandName New-NetFirewallRule -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It
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
        It 'marks the rule it adds with the framework comment, passed as one argument' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n22/tcp                     ALLOW       Anywhere`n" } }
                return @{ ExitCode = 0; Output = 'Rule added' }
            }
            $r = Set-YurunaStatusFirewallRule -Port 8080 6>$null
            Assert-True $r.Changed 'the rule was added'
            # The teardown removes only rules that carry this comment.
            $expected = "ufw|allow|8080/tcp|comment|$(Get-YurunaStatusFirewallRuleComment)"
            Should -Invoke -CommandName Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall -Times 1 -Exactly -Scope It -ParameterFilter {
                (@($CommandLine | Select-Object -Last 5) -join '|') -ceq $expected
            }
        }
        It 'adds nothing over an allow rule it did not mark, which ufw would relabel as its own' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n8443/tcp                   ALLOW       Anywhere                  `n" } }
                return @{ ExitCode = 0; Output = 'Rule updated' }
            }
            $r = Set-YurunaStatusFirewallRule -Port 8443 4>$null
            Assert-True  $r.Ensured 'the operator rule already allows the port'
            Assert-False $r.Changed 'nothing was added'
            Should -Invoke -CommandName Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It -ParameterFilter { $CommandLine -contains 'allow' }
        }
        It 'leaves a <Case> on its port, which ufw would replace with its own rule' -ForEach @(
            @{ Case = 'DENY rule'; Line = '8080/tcp                   DENY        Anywhere' }
            @{ Case = 'REJECT rule'; Line = '8080/tcp                   REJECT      Anywhere' }
            @{ Case = 'LIMIT rule'; Line = '8080/tcp                   LIMIT       Anywhere' }
            @{ Case = 'rule for IPv6 only'; Line = '8080/tcp (v6)              ALLOW       Anywhere (v6)' }
        ) {
            # ufw replaces a rule that differs from an added one only by its
            # action, log type or comment, so adding here would turn an
            # operator's rule into a marked one the teardown later removes.
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n$Line`n" } }
                return @{ ExitCode = 0; Output = 'Rule updated' }
            }
            $r = Set-YurunaStatusFirewallRule -Port 8080 -NonInteractive 4>$null
            Should -Invoke -CommandName Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall -Times 0 -Exactly -Scope It -ParameterFilter { $CommandLine -contains 'allow' }
            Assert-False $r.Changed 'nothing was added or replaced'
            Assert-False $r.Ensured 'the port is not open to every LAN client'
            Assert-True  $r.Blocked 'an existing rule decides the port, and the caller says so'
            Assert-Match ([regex]::Escape($Line.Trim())) $r.Message 'the message quotes the rule it left'
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
        It 'words its ufw outcomes for any port, since the config service port goes through it too' {
            Mock Get-Command -ModuleName Test.StatusFirewall -ParameterFilter { $Name -eq 'ufw' } { [pscustomobject]@{ Name = 'ufw' } }
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall { @{ ExitCode = 1; Output = 'sudo: a password is required' } }
            $unread = Set-YurunaStatusFirewallRule -Port 8443 -NonInteractive 4>$null
            Mock Invoke-YurunaFirewallNative -ModuleName Test.StatusFirewall {
                param($CommandLine)
                if ($CommandLine -contains 'status') { return @{ ExitCode = 0; Output = "Status: active`n22/tcp                     ALLOW       Anywhere`n" } }
                return @{ ExitCode = 0; Output = 'Rule added' }
            }
            $added = Set-YurunaStatusFirewallRule -Port 8443 6>$null
            Assert-True $added.Changed 'the fixture reached the allow'
            foreach ($message in @($unread.Message, $added.Message)) {
                Assert-Match ':8443' $message 'the outcome names the port it is about'
                Assert-False ($message -match '(?i)status') "an outcome for the config service port names no status service: $message"
            }
        }
    }
}

Describe 'Firewall native argument preservation' {
    It 'passes a single argument as one complete native token' {
        InModuleScope Test.StatusFirewall {
            $result = Invoke-YurunaFirewallNative -CommandLine @((Get-Process -Id $PID).Path, '-Version')
            Assert-Equal 0 $result.ExitCode
            Assert-Match 'PowerShell 7' $result.Output
        }
    }
}

Describe 'Start-ConfigService reports a config-port rule it could not apply' {
    # Host setup opens the config service port only where it manages the
    # firewall (ufw on Ubuntu KVM), and the launcher is a no-op while the
    # service stays up, so a launch that cannot confirm the port is open is
    # the operator's notice before a service guest's NAS mount fails against
    # it. That step is sliced out of the launcher and run with the helper stood
    # in by a module that answers a chosen result, so the proof holds on every
    # platform and touches no firewall.
    BeforeAll {
        $script:LauncherSource = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) '../service/Start-ConfigService.ps1')
        # The launcher renders its warning through the message catalog, which
        # the real script imports above the sliced region.
        $script:GlobalizationModule = Join-Path (Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)) 'automation/Yuruna.Globalization.psm1'
        function Invoke-ConfigPortFirewallSlice {
            param([bool]$Ensured, [bool]$Blocked, [string]$Message)
            $start = $script:LauncherSource.IndexOf('# --- REGION: Open the host firewall (best-effort)', [StringComparison]::Ordinal)
            $end = if ($start -ge 0) { $script:LauncherSource.IndexOf('# --- REGION: Launch the server as a detached process', $start, [StringComparison]::Ordinal) } else { -1 }
            if ($start -lt 0 -or $end -le $start) { throw 'the launcher no longer frames its firewall step between the two region markers' }
            # The Linux branch is the one under test; the fixture takes it on
            # every platform and skips the Windows one.
            $body = $script:LauncherSource.Substring($start, $end - $start).Replace('if ($IsLinux)', 'if ($true)').Replace('if ($IsWindows)', 'if ($false)')
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'service'), (Join-Path $root 'modules')
            $stub = @(
                'function Set-YurunaStatusFirewallRule {'
                '    param([int]$Port, [switch]$NonInteractive)'
                '    $null = $NonInteractive'
                "    [pscustomobject]@{ Platform = 'Linux'; Ensured = `$$Ensured; Changed = `$false; Blocked = `$$Blocked; Message = `"fixture: $Message :`$Port`" }"
                '}'
                'Export-ModuleMember -Function Set-YurunaStatusFirewallRule'
            )
            [IO.File]::WriteAllText((Join-Path $root 'modules/Test.StatusFirewall.psm1'), ($stub -join "`n") + "`n")
            $fixture = Join-Path $root 'service/Start-ConfigService.fixture.ps1'
            [IO.File]::WriteAllText($fixture, "Import-Module '$script:GlobalizationModule' -DisableNameChecking`n`$Port = 8443`n" + $body + "`nexit 0`n")
            return Invoke-FixtureScript -Path $fixture
        }
    }

    It 'warns above Verbose when <Case>' -ForEach @(
        @{ Case = 'ufw could not be read without a cached sudo credential'; Ensured = $false; Blocked = $false; Message = 'could not query ufw' }
        @{ Case = 'ufw refused the allow';                                  Ensured = $false; Blocked = $true;  Message = 'ufw allow failed' }
        @{ Case = 'ufw is absent';                                          Ensured = $false; Blocked = $false; Message = 'ufw not found; nftables/iptables are not managed' }
        @{ Case = 'the helper failed';                                      Ensured = $false; Blocked = $false; Message = 'Set-YurunaStatusFirewallRule: fixture fault' }
    ) {
        $run = Invoke-ConfigPortFirewallSlice -Ensured $Ensured -Blocked $Blocked -Message $Message
        Assert-Equal 0 $run.ExitCode "the firewall step never fails a launch; output: $($run.Lines -join ' | ')"
        Assert-Equal 1 @($run.Lines | Where-Object { $_ -match "WARNING:.*fixture: $Message :8443" }).Count "the launcher warns with the helper's own message; output: $($run.Lines -join ' | ')"
        # The helper serves the status port too, so the launcher's own words
        # have to say which service the closed port starves.
        $framing = @($run.Lines | Where-Object { $_ -match 'WARNING:' } | ForEach-Object { $_.Replace("fixture: $Message :8443", '') })
        Assert-Equal 1 @($framing | Where-Object { $_ -match 'config service' -and $_ -match ':8443' }).Count "the warning names the config service and its port; output: $($run.Lines -join ' | ')"
        Assert-Equal 0 @($framing | Where-Object { $_ -match '(?i)status' }).Count "the warning does not describe the config port as the status port; output: $($run.Lines -join ' | ')"
    }

    It 'stays quiet when the port is already reachable' {
        $run = Invoke-ConfigPortFirewallSlice -Ensured $true -Blocked $false -Message 'already allowed'
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 0 @($run.Lines | Where-Object { $_ -match 'WARNING:' }).Count "a reachable port raises no warning; output: $($run.Lines -join ' | ')"
    }
}

Describe 'Ubuntu KVM host setup manages the config service port beside the status port' {
    # Service guests fetch their NAS credential from the config service, and
    # an active ufw refuses the launcher's unprivileged attempt to open its
    # port, so the elevated host setup has to open it and the restore has to
    # take it back. Each script's firewall step is sliced out and run in a
    # child process against a configuration seeded with non-default ports,
    # through the real configuration reader and the config service's own port
    # decision; recorders stand in for the firewall, so no rule is touched.
    BeforeAll {
        $script:SliceRepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)
        Import-Module (Join-Path $script:SliceRepoRoot 'test/modules/Test.Prelude.psm1') -Force -DisableNameChecking
        $script:SeededConfig = "statusService:`n  port: 18080`nconfigService:`n  port: 19443`n"

        function Get-HostSetupFirewallSlice {
            param([string]$Script)
            $path = Join-Path $script:SliceRepoRoot "host/ubuntu.kvm/$Script"
            $source = [IO.File]::ReadAllText($path)
            $start = $source.IndexOf('# --- REGION: Status-service LAN reachability (host firewall)', [StringComparison]::Ordinal)
            $end = if ($start -ge 0) { $source.IndexOf('# --- REGION: Host clock', $start, [StringComparison]::Ordinal) } else { -1 }
            if ($start -lt 0 -or $end -le $start) { throw "$Script no longer frames its firewall step between the two region markers" }
            return @{ Path = $path; Body = $source.Substring($start, $end - $start) }
        }

        function New-HostSetupSliceRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds a tree under TestDrive, which Pester removes.')]
            param([string]$ConfigText)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $modules = Join-Path $root 'test/modules'
            $null = New-Item -ItemType Directory -Path $modules, (Join-Path $root 'bin')
            [IO.File]::WriteAllText((Join-Path $root 'test/test.config.yml'), $ConfigText)
            # The scripts import their modules from the repository root they
            # run under; these re-export the real reader and port decision.
            foreach ($proxy in @(@{ Name = 'Test.Config'; Function = 'Read-TestConfig' }, @{ Name = 'Test.Prelude'; Function = 'Resolve-ConfigServiceStart' })) {
                $real = Join-Path $script:SliceRepoRoot "test/modules/$($proxy.Name).psm1"
                [IO.File]::WriteAllText((Join-Path $modules "$($proxy.Name).psm1"), "Import-Module '$real' -Force -DisableNameChecking`nExport-ModuleMember -Function $($proxy.Function)`n")
            }
            return $root
        }

        function Invoke-HostSetupSlice {
            param([string]$Root, [string[]]$Text)
            $fixture = Join-Path $Root 'fixture.ps1'
            [IO.File]::WriteAllText($fixture, ($Text -join "`n") + "`nexit 0`n")
            $run = Invoke-FixtureScript -Path $fixture
            $log = Join-Path $Root 'calls.log'
            $run.Calls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
            return $run
        }

        function Invoke-EnableFirewallSlice {
            param([string]$ConfigText)
            $root = New-HostSetupSliceRoot -ConfigText $ConfigText
            $log = Join-Path $root 'calls.log'
            [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.StatusFirewall.psm1'), (@(
                'function Set-YurunaStatusFirewallRule {'
                '    param([int]$Port, [switch]$NonInteractive)'
                "    [IO.File]::AppendAllText('$log', ""rule|`$Port|nonInteractive=`$([bool]`$NonInteractive)``n"")"
                "    [pscustomobject]@{ Platform = 'Linux'; Ensured = `$true; Changed = `$true; Blocked = `$false; Message = ""fixture rule :`$Port"" }"
                '}'
                'Export-ModuleMember -Function Set-YurunaStatusFirewallRule'
            ) -join "`n") + "`n")
            $slice = Get-HostSetupFirewallSlice -Script 'Enable-TestAutomation.ps1'
            return Invoke-HostSetupSlice -Root $root -Text @(
                "`$ErrorActionPreference = 'Stop'"
                "Import-Module '$(Join-Path $script:SliceRepoRoot 'automation/Yuruna.Globalization.psm1')' -DisableNameChecking"
                "`$RepoRoot = '$root'"
                (Get-YurunaTestFunctionAst -Path $slice.Path -Name 'Invoke-Step').Extent.Text
                $slice.Body
            )
        }

        function Invoke-DisableFirewallSlice {
            param([string]$ConfigText, [switch]$WithUfw, [string]$StatusOutput = '', [int]$StatusExitCode = 0, [int]$DeleteExitCode = 0, [switch]$WithWhatIf)
            $root = New-HostSetupSliceRoot -ConfigText $ConfigText
            $bin = Join-Path $root 'bin'
            # Only presence matters: Invoke-YurunaSudo is the recorder, so
            # this stand-in is found on PATH and never run.
            if ($WithUfw -and $IsWindows) { [IO.File]::WriteAllText((Join-Path $bin 'ufw.cmd'), "@exit /b 0`r`n") }
            elseif ($WithUfw) {
                [IO.File]::WriteAllText((Join-Path $bin 'ufw'), "#!/bin/sh`nexit 0`n")
                & chmod +x (Join-Path $bin 'ufw')
            }
            $log = Join-Path $root 'calls.log'
            # The recorder answers 'ufw status' from a file, so the fixture
            # script carries the text without quoting it.
            $statusFile = Join-Path $root 'ufw-status.txt'
            [IO.File]::WriteAllText($statusFile, $StatusOutput)
            $deleteOutput = if ($DeleteExitCode -eq 0) { 'Rule deleted' } else { 'ERROR: fixture refused the delete' }
            $slice = Get-HostSetupFirewallSlice -Script 'Disable-TestAutomation.ps1'
            return Invoke-HostSetupSlice -Root $root -Text @(
                '[CmdletBinding(SupportsShouldProcess)] param()'
                if ($WithWhatIf) { '$WhatIfPreference = $true' }
                "`$ErrorActionPreference = 'Stop'"
                "Import-Module '$(Join-Path $script:SliceRepoRoot 'automation/Yuruna.Globalization.psm1')' -DisableNameChecking"
                "`$RepoRoot = '$root'"
                "Import-Module (Join-Path `$RepoRoot 'test/modules/Test.Config.psm1') -Force -DisableNameChecking"
                "Import-Module (Join-Path `$RepoRoot 'test/modules/Test.Prelude.psm1') -Force -DisableNameChecking"
                "Import-Module '$(Join-Path $script:SliceRepoRoot 'test/modules/Test.StatusFirewall.psm1')' -Force -DisableNameChecking"
                "`$env:PATH = '$bin'"
                '$restored = [System.Collections.Generic.List[string]]::new()'
                '$skipped = [System.Collections.Generic.List[string]]::new()'
                'function Invoke-YurunaSudo {'
                '    param([string[]]$Argument, [switch]$TolerateBlocked)'
                '    $null = $TolerateBlocked'
                "    [IO.File]::AppendAllText('$log', 'sudo|' + ((`$Argument | Select-Object -Skip 1) -join ' ') + ""``n"")"
                "    if (`$Argument -contains 'status') { return @{ ExitCode = $StatusExitCode; Blocked = `$false; Output = [IO.File]::ReadAllText('$statusFile') } }"
                "    return @{ ExitCode = $DeleteExitCode; Blocked = `$false; Output = '$deleteOutput' }"
                '}'
                $slice.Body
                'foreach ($line in $restored) { "restored|$line" }'
                'foreach ($line in $skipped) { "skipped|$line" }'
            )
        }

        # 'ufw status' as ufw 0.36 prints it: each rule's To, Action and From
        # padded as '%-26s %-12s%-26s', then ' # <comment>' when it has one.
        function Format-UfwStatus {
            param([hashtable[]]$Rule)
            $header = @('Status: active', '', ('{0,-26} {1,-12}{2}' -f 'To', 'Action', 'From'), ('{0,-26} {1,-12}{2}' -f '--', '------', '----'))
            $rows = @($Rule | ForEach-Object { '{0,-26} {1,-12}{2,-26}{3}' -f $_.To, 'ALLOW', $_.From, $(if ($_.Comment) { " # $($_.Comment)" }) })
            return (($header + $rows) -join "`n") + "`n"
        }
    }

    It 'opens configService.port beside statusService.port for <Case>' -ForEach @(
        @{ Case = 'non-default ports seeded in the configuration'; Seeded = $true }
        @{ Case = 'a configuration without a configService node'; Seeded = $false }
    ) {
        $configText = if ($Seeded) { $script:SeededConfig } else { "statusService:`n  port: 18080`n" }
        # Without a configured port, the one the config service itself starts on.
        $configPort = if ($Seeded) { 19443 } else { (Resolve-ConfigServiceStart -Config $null).Port }
        $run = Invoke-EnableFirewallSlice -ConfigText $configText
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the firewall step never fails host setup; $detail"
        Assert-Equal 2 @($run.Calls).Count "one rule per service port; $detail"
        Assert-Equal 1 @($run.Calls | Where-Object { $_ -eq 'rule|18080|nonInteractive=False' }).Count "the status port keeps its rule; $detail"
        Assert-Equal 1 @($run.Calls | Where-Object { $_ -eq "rule|$configPort|nonInteractive=False" }).Count "the config port goes through the same elevated helper call; $detail"
        Assert-Equal 1 @($run.Lines | Where-Object { $_ -match "status firewall: fixture rule :18080" }).Count "the status outcome is reported; $detail"
        Assert-Equal 1 @($run.Lines | Where-Object { $_ -match "config service firewall: fixture rule :$configPort" }).Count "the config outcome is reported under its own name; $detail"
    }

    It 'removes the config service rule beside the status rule' {
        $marker = Get-YurunaStatusFirewallRuleComment
        $status = Format-UfwStatus -Rule @(
            @{ To = '18080/tcp'; From = 'Anywhere'; Comment = $marker }
            @{ To = '19443/tcp'; From = 'Anywhere'; Comment = $marker }
            @{ To = '18080/tcp (v6)'; From = 'Anywhere (v6)'; Comment = $marker }
            @{ To = '19443/tcp (v6)'; From = 'Anywhere (v6)'; Comment = $marker }
        )
        $run = Invoke-DisableFirewallSlice -ConfigText $script:SeededConfig -WithUfw -StatusOutput $status
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the restore step never fails; $detail"
        foreach ($port in @(18080, 19443)) {
            # With the comment, ufw deletes only the rule that carries it.
            Assert-Equal 1 @($run.Calls | Where-Object { $_ -eq "sudo|--force delete allow $port/tcp comment $marker" }).Count "ufw deletes the $port rule; $detail"
            Assert-Equal 1 @($run.Lines | Where-Object { $_ -eq "restored|ufw rule removed: allow $port/tcp" }).Count "the report lists the $port rule as removed; $detail"
        }
    }

    It 'removes only the marked rule and reports each unmarked one with the command that removes it' {
        $marker = Get-YurunaStatusFirewallRuleComment
        # The status port holds the framework's rule and an operator's rule
        # for one subnet; the config port holds a rule as older versions added
        # it, with no comment.
        $status = Format-UfwStatus -Rule @(
            @{ To = '18080/tcp'; From = 'Anywhere'; Comment = $marker }
            @{ To = '18080/tcp'; From = '192.168.7.0/24' }
            @{ To = '19443/tcp'; From = 'Anywhere' }
            @{ To = '18080/tcp (v6)'; From = 'Anywhere (v6)'; Comment = $marker }
            @{ To = '19443/tcp (v6)'; From = 'Anywhere (v6)' }
        )
        $run = Invoke-DisableFirewallSlice -ConfigText $script:SeededConfig -WithUfw -StatusOutput $status
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the restore step never fails; $detail"
        $deletes = @($run.Calls | Where-Object { $_ -like 'sudo|--force delete *' })
        Assert-Equal 1 $deletes.Count "only the marked rule is deleted; $detail"
        Assert-Equal "sudo|--force delete allow 18080/tcp comment $marker" $deletes[0] "the marked rule goes, named with its comment so ufw can delete no other; $detail"
        Assert-Equal 1 @($run.Lines | Where-Object { $_ -eq 'restored|ufw rule removed: allow 18080/tcp' }).Count "the report lists the marked rule as removed; $detail"
        $left = @($run.Lines | Where-Object { $_ -like 'skipped|*' })
        Assert-Equal 2 $left.Count "each unmarked rule is reported once; $detail"
        $marked = [regex]::Escape("no '$marker' comment")
        Assert-Equal 1 @($left | Where-Object { $_ -match "^skipped\|ufw allow from 192\.168\.7\.0/24 to any port 18080 proto tcp \(.*$marked.*; to remove it: sudo ufw delete allow from 192\.168\.7\.0/24 to any port 18080 proto tcp\)$" }).Count "the operator's rule on the status port is left, with the command that removes it; $detail"
        Assert-Equal 1 @($left | Where-Object { $_ -match "^skipped\|ufw allow 19443/tcp \(.*$marked.*older Yuruna version.*; to remove it: sudo ufw delete allow 19443/tcp\)$" }).Count "the unmarked config port rule is left, saying an older version may have added it; $detail"
    }

    It 'removes a marked rule on a port that is no longer configured' {
        $marker = Get-YurunaStatusFirewallRuleComment
        $status = Format-UfwStatus -Rule @(
            @{ To = '8080/tcp'; From = 'Anywhere'; Comment = $marker }
            @{ To = '8080/tcp (v6)'; From = 'Anywhere (v6)'; Comment = $marker }
        )
        $run = Invoke-DisableFirewallSlice -ConfigText $script:SeededConfig -WithUfw -StatusOutput $status
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the restore step never fails; $detail"
        $deletes = @($run.Calls | Where-Object { $_ -like 'sudo|--force delete *' })
        Assert-Equal 1 $deletes.Count "one rule is deleted; $detail"
        Assert-Equal "sudo|--force delete allow 8080/tcp comment $marker" $deletes[0] "the rule from before the port changed goes; $detail"
        Assert-Equal 1 @($run.Lines | Where-Object { $_ -eq 'restored|ufw rule removed: allow 8080/tcp' }).Count "the report lists it as removed; $detail"
        Assert-Equal 0 @($run.Lines | Where-Object { $_ -like 'skipped|*' }).Count "no rule is left on the configured ports; $detail"
    }

    It 'keeps its handling when <Case>' -ForEach @(
        @{ Case = 'ufw status cannot be read'; StatusExitCode = 1; DeleteExitCode = 0; WhatIf = $false; Deletes = 0
            Report = @('skipped|ufw allow 18080/tcp (could not read ufw status: ERROR: You need to be root to run this script)', 'skipped|ufw allow 19443/tcp (could not read ufw status: ERROR: You need to be root to run this script)') }
        @{ Case = 'the delete fails'; StatusExitCode = 0; DeleteExitCode = 1; WhatIf = $false; Deletes = 1
            Report = @('skipped|ufw allow 18080/tcp (delete failed: ERROR: fixture refused the delete)') }
        @{ Case = 'it runs under -WhatIf'; StatusExitCode = 0; DeleteExitCode = 0; WhatIf = $true; Deletes = 0; Report = @() }
    ) {
        $status = if ($StatusExitCode -ne 0) { 'ERROR: You need to be root to run this script' }
                  else { Format-UfwStatus -Rule @(@{ To = '18080/tcp'; From = 'Anywhere'; Comment = (Get-YurunaStatusFirewallRuleComment) }) }
        $run = Invoke-DisableFirewallSlice -ConfigText $script:SeededConfig -WithUfw -StatusOutput $status -StatusExitCode $StatusExitCode -DeleteExitCode $DeleteExitCode -WithWhatIf:$WhatIf
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the restore step never fails; $detail"
        Assert-Equal $Deletes @($run.Calls | Where-Object { $_ -like 'sudo|--force delete *' }).Count "delete calls; $detail"
        $actual = @($run.Lines | Where-Object { $_ -like 'restored|*' -or $_ -like 'skipped|*' })
        Assert-StringEqual ($Report -join ' || ') ($actual -join ' || ') "the report; $detail"
        if ($WhatIf) {
            Assert-Equal 1 @($run.Lines | Where-Object { $_ -match '^What if: .*ufw allow 18080/tcp' }).Count "-WhatIf names the rule it would remove; $detail"
        }
    }

    It 'reports both rules as left in place when ufw is not installed' {
        $run = Invoke-DisableFirewallSlice -ConfigText $script:SeededConfig
        $detail = "calls: $($run.Calls -join ' | '); output: $($run.Lines -join ' | ')"
        Assert-Equal 0 $run.ExitCode "the restore step never fails; $detail"
        Assert-Equal 0 @($run.Calls).Count "nothing is elevated without ufw; $detail"
        foreach ($port in @(18080, 19443)) {
            Assert-Equal 1 @($run.Lines | Where-Object { $_ -eq "skipped|ufw allow $port/tcp (ufw is not installed)" }).Count "the report names the $port rule it could not remove; $detail"
        }
    }
}
