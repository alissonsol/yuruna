<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42e5dbd9-8c32-496e-ab48-855a0584ae9c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host automation state pester
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
    The capture must not fall behind the setters.
.DESCRIPTION
    Disable-TestAutomation can only restore what Enable-TestAutomation captured.
    A knob added to Set-<Platform>HostConditionSet without a matching capture
    entry becomes silently unreversible -- the host is changed, Disable reports
    nothing about it, and the operator has no way back short of doing it by hand.

    That failure is invisible at runtime: everything still works, the report
    still looks complete, and only the missing line tells you. So it is asserted
    here instead, statically, against the setter sources themselves. A new write
    fails this test rather than shipping.

    Deliberately source-level rather than behavioral: the macOS and Linux
    readers early-return on the wrong OS, so a runtime comparison could only ever
    check one platform from any one machine. Reading the source checks all three
    from anywhere, which is what CI needs.
#>

BeforeAll {
    $script:ModulesDir  = $PSScriptRoot
    $script:CaptureSrc  = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostAutomationState.psm1') -Raw
    $script:MacSrc      = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostCondition.Mac.psm1') -Raw
    $script:WindowsSrc  = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostCondition.Windows.psm1') -Raw
    $script:LinuxEnable = Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $ModulesDir)) 'host/ubuntu.kvm/Enable-TestAutomation.ps1') -Raw

    # Knobs the plan records as deliberately NOT reversed, so a write to them is
    # expected to have no capture entry. Anything else must be captured.
    $script:NotReversed = @(
        'AutoLogOutDelay'   # captured under its own 'autologout' key, not by name
    )
}

Describe 'the pre-automation capture covers every setter write' {

    Context 'macOS' {
        It 'captures every com.apple.screensaver key the setter writes' {
            $written = [regex]::Matches($MacSrc, "com\.apple\.screensaver'?,?\s*'?([A-Za-z]+)'?") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $written | Should -Not -BeNullOrEmpty
            foreach ($key in $written) {
                $CaptureSrc | Should -Match ([regex]::Escape($key)) -Because "Set-MacHostConditionSet writes com.apple.screensaver $key, so the capture must record it or Disable cannot put it back"
            }
        }

        It 'captures every pmset guard, by reading the same canonical list the setter applies' {
            # Not a copy of the list: the capture enumerates Get-MacPmsetGuardList
            # itself, so a guard added there is captured with no edit here. This
            # asserts that wiring, which is what makes the two unable to drift.
            $CaptureSrc | Should -Match 'Get-MacPmsetGuardList'
        }

        It 'captures displaysleep, sleep and disksleep -- which are written inline, NOT via the guard list' {
            # The trap section 6 of the plan names: a capture driven by the guard list
            # alone would leave a Mac unable to sleep, because these three are
            # written directly.
            foreach ($key in @('displaysleep', 'sleep', 'disksleep')) {
                $CaptureSrc | Should -Match "pmset/\`$scope/\`$key|'$key'" -Because "pmset $key is written inline by the setter"
            }
        }

        It 'captures display sleep for AC and battery separately' {
            # pmset writes -c and -b independently; restoring one value to both
            # loses the machine's battery policy.
            $CaptureSrc | Should -Match "Scope = 'ac'"
            $CaptureSrc | Should -Match "Scope = 'battery'"
        }

        It 'captures both the user and -currentHost domains' {
            $CaptureSrc | Should -Match "screensaver/user/"
            $CaptureSrc | Should -Match "screensaver/currentHost/"
        }

        It 'captures every hot corner and its modifier' {
            foreach ($corner in @('tl', 'tr', 'bl', 'br')) {
                $CaptureSrc | Should -Match "wvous-$corner-corner"
                $CaptureSrc | Should -Match "wvous-$corner-modifier"
            }
        }
    }

    Context 'Windows' {
        It 'captures every registry value the setter writes' {
            $written = [regex]::Matches($WindowsSrc, 'Set-ItemProperty[^\r\n]*?-Name\s+''?([A-Za-z0-9_]+)''?') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $written | Should -Not -BeNullOrEmpty
            foreach ($name in $written) {
                if ($name -in $NotReversed) { continue }
                $CaptureSrc | Should -Match ([regex]::Escape($name)) -Because "Set-WindowsHostConditionSet writes '$name', so the capture must record it"
            }
        }

        It 'captures each powercfg setting the setter changes' {
            $written = [regex]::Matches($WindowsSrc, 'powercfg\s+/SET(?:AC|DC)VALUEINDEX\s+SCHEME_CURRENT\s+(\S+)\s+(\S+)') |
                ForEach-Object { $_.Groups[2].Value } | Sort-Object -Unique
            $written | Should -Not -BeNullOrEmpty
            foreach ($setting in $written) {
                $CaptureSrc | Should -Match ([regex]::Escape($setting)) -Because "the setter writes powercfg $setting, so the capture must record it"
            }
        }

        It 'captures powercfg values for AC and DC separately' {
            $CaptureSrc | Should -Match 'monitor-timeout-\$scheme'
            $CaptureSrc | Should -Match 'CONSOLELOCK-\$scheme'
        }

        It 'selects built-in ICMPv4 rules the same way the setter does' {
            # By protocol filter and IcmpType, not DisplayName. Selecting on the
            # name would miss every rule that does not spell "ICMPv4", and Enable
            # would switch those on with no record to switch them back.
            # Asserted as booleans rather than -Match so a failure reports the
            # claim instead of dumping the whole module source.
            ($CaptureSrc -match 'Get-NetFirewallPortFilter') | Should -BeTrue -Because 'the ICMP capture must select by protocol filter'
            ($CaptureSrc -match "Protocol[^\r\n]*'ICMPv4'")  | Should -BeTrue -Because 'the protocol test must be on the filter, not the rule name'
            ($CaptureSrc -match 'IcmpType')                  | Should -BeTrue -Because 'echo-request (type 8) is what the setter enables'
        }
    }

    Context 'Ubuntu' {
        It 'captures every gsettings key the Enable script writes' {
            $block = [regex]::Match($LinuxEnable, '\$tweaks\s*=\s*@\((?<body>[\s\S]*?)\n\s*\)')
            $block.Success | Should -BeTrue -Because 'the gsettings tweak list should be findable in host/ubuntu.kvm/Enable-TestAutomation.ps1'
            $written = [regex]::Matches($block.Groups['body'].Value, "'([a-z0-9-]+)'\s*,\s*'([^']+)'\s*\)") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $written | Should -Not -BeNullOrEmpty
            foreach ($key in $written) {
                $CaptureSrc | Should -Match ([regex]::Escape($key)) -Because "Enable-TestAutomation sets gsettings '$key', so the capture must record it"
            }
        }

        It 'captures the additive changes so Disable can tell what it added' {
            # Group membership and the $HOME ACL are REMOVED rather than
            # restored, and only when the capture proves Enable added them.
            $CaptureSrc | Should -Match "group/\`$grp"
            $CaptureSrc | Should -Match 'not-a-member'
            $CaptureSrc | Should -Match 'acl/home'
        }

        It 'captures the NTP state and both libvirt units' {
            $CaptureSrc | Should -Match 'timedatectl/ntp'
            foreach ($unit in @('libvirtd', 'virtlogd')) {
                $CaptureSrc | Should -Match ([regex]::Escape($unit))
            }
        }
    }
}

Describe 'the capture file contract' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -Force -DisableNameChecking
        $script:RuntimeDir = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-capture-contract-$PID"
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        $env:YURUNA_RUNTIME_DIR = $RuntimeDir
    }
    AfterAll {
        Remove-Item -LiteralPath $RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
        $env:YURUNA_RUNTIME_DIR = $null
    }

    It 'refuses to overwrite an existing capture' {
        # The rule the whole design rests on: a second Enable must not record the
        # values Enable itself wrote as the operator's.
        $platform = if ($IsWindows) { 'windows.hyper-v' } elseif ($IsMacOS) { 'macos.utm' } else { 'ubuntu.kvm' }
        $first = Save-HostAutomationState -Platform $platform
        $first | Should -Not -BeNullOrEmpty
        $second = Save-HostAutomationState -Platform $platform
        $second | Should -BeNullOrEmpty -Because 'a capture already existed and must be left alone'
    }

    It 'distinguishes "never captured" from "captured as absent"' {
        $state = Read-HostAutomationState
        $state | Should -Not -BeNullOrEmpty
        Get-HostAutomationKnob -State $state -Name 'no/such/knob' | Should -BeNullOrEmpty
    }

    It 'records the platform and a capture timestamp' {
        $state = Read-HostAutomationState
        $state.platform | Should -Not -BeNullOrEmpty
        { [datetime]::Parse($state.capturedUtc) } | Should -Not -Throw
    }
}

Describe 'the teardown steps every host shares' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -Force -DisableNameChecking
        $script:RepoRootForStop = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        # Stands in for the calling script's $PSCmdlet. $true approves every
        # action, $false is what -WhatIf produces.
        function Get-StubCmdlet {
            param([bool]$Approve)
            $stub = [pscustomobject]@{}
            $stub | Add-Member ScriptMethod ShouldProcess ([scriptblock]::Create("param(`$a,`$b) `$$Approve"))
            $stub
        }
    }

    It 'accepts the empty lists a teardown starts with' {
        # Both lists are empty on the first call, and a Mandatory collection
        # parameter rejects an empty one -- which would throw partway through a
        # teardown instead of at its start.
        $restored = [System.Collections.Generic.List[string]]::new()
        $skipped  = [System.Collections.Generic.List[string]]::new()
        {
            Stop-YurunaServiceVMSet -RepoRoot $script:RepoRootForStop `
                -Cmdlet (Get-StubCmdlet -Approve $false) -Restored $restored -Skipped $skipped
        } | Should -Not -Throw
    }

    It 'reports a missing stop script as skipped rather than throwing' {
        # Teardown runs on hosts in unknown states; one service that was never
        # provisioned must not stop the operator disabling the rest.
        $restored = [System.Collections.Generic.List[string]]::new()
        $skipped  = [System.Collections.Generic.List[string]]::new()
        $absent   = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-no-repo-" + [guid]::NewGuid())
        Stop-YurunaServiceVMSet -RepoRoot $absent -Cmdlet (Get-StubCmdlet -Approve $true) `
            -Restored $restored -Skipped $skipped
        $skipped.Count  | Should -Be 4 -Because 'all four service stop scripts are absent there'
        $restored.Count | Should -Be 0
    }

    It 'runs nothing when the caller declines the action' {
        $restored = [System.Collections.Generic.List[string]]::new()
        $skipped  = [System.Collections.Generic.List[string]]::new()
        Stop-YurunaServiceVMSet -RepoRoot $script:RepoRootForStop `
            -Cmdlet (Get-StubCmdlet -Approve $false) -Restored $restored -Skipped $skipped
        $restored.Count | Should -Be 0 -Because 'a declined action must not stop a VM'
    }

    It 'always names the vault as something it did not remove' {
        $out = Write-DisableCommonEpilogue -StateCaptured $false -StopServices $true | Out-String
        $out | Should -Match 'credential vault'
        $out | Should -Match 'Unregister-SecretVault'
    }

    It 'names the service VMs only when it was not asked to stop them' {
        $left = Write-DisableCommonEpilogue -StateCaptured $false -StopServices $false | Out-String
        $left | Should -Match 'caching-proxy'
        $done = Write-DisableCommonEpilogue -StateCaptured $false -StopServices $true | Out-String
        $done | Should -Not -Match 'caching-proxy' -Because 'they were stopped, so they are not a manual step'
    }

    It 'is the only place the three hosts spell the shared teardown out' {
        # The value of the extraction is that a service added to the roster is
        # added once. Three copies of the loop meant a service could keep
        # running after a teardown the operator believed had finished.
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        foreach ($platform in @('ubuntu.kvm', 'windows.hyper-v', 'macos.utm')) {
            $text = Get-Content -LiteralPath (Join-Path $root "host/$platform/Disable-TestAutomation.ps1") -Raw
            $text | Should -Not -Match 'CachingProxyService' -Because "$platform must call Stop-YurunaServiceVMSet"
            $text | Should -Not -Match 'Unregister-SecretVault' -Because "$platform must call Write-DisableCommonEpilogue"
        }
    }
}
