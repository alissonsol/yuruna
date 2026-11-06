<#PSScriptInfo
.VERSION 2026.11.05
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
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The module under test fills an absent YURUNA_RUNTIME_DIR with the
    # repository's own runtime folder, so the suite puts back what the process held.
    $script:SuiteEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
    $script:ModulesDir  = $PSScriptRoot
    $script:CaptureSrc  = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostAutomationState.psm1') -Raw
    $script:MacSrc      = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostCondition.Mac.psm1') -Raw
    $script:WindowsSrc  = Get-Content -LiteralPath (Join-Path $ModulesDir 'Test.HostCondition.Windows.psm1') -Raw
    $script:LinuxEnable = Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $ModulesDir)) 'host/ubuntu.kvm/Enable-TestAutomation.ps1') -Raw
    $script:LinuxDisable = Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $ModulesDir)) 'host/ubuntu.kvm/Disable-TestAutomation.ps1') -Raw

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
                $CaptureSrc | Should -Match ("\x27" + [regex]::Escape($key) + "\x27") -Because "pmset $key is written inline by the setter"
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
            # The bounded writer keeps the powercfg arguments in a literal array.
            $boundedPattern = 'Write-WindowsPowerSetting\s+-ArgumentList\s+@\(\s*[''"]/SET(?:AC|DC)VALUEINDEX[''"]\s*,\s*' +
                '[''"]SCHEME_CURRENT[''"]\s*,\s*[''"][^''"]+[''"]\s*,\s*[''"]([^''"]+)[''"]'
            $written = @(
                [regex]::Matches($WindowsSrc, 'powercfg\s+/SET(?:AC|DC)VALUEINDEX\s+SCHEME_CURRENT\s+(\S+)\s+(\S+)') |
                    ForEach-Object { $_.Groups[2].Value }
                [regex]::Matches($WindowsSrc, $boundedPattern) |
                    ForEach-Object { $_.Groups[1].Value }
            ) | Sort-Object -Unique
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
        BeforeAll {
            # The names a foreach over $grp walks, taken from the loop whose
            # body carries the marker: Enable's usermod loop, the capture's
            # group/<name> loop and Disable's gpasswd loop.
            function Get-GroupLoopName {
                param([string]$Source, [string]$Marker)
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
                $loop = $ast.FindAll({ param($node)
                        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                        $node.Variable.VariablePath.UserPath -eq 'grp' -and $node.Body.Extent.Text.Contains($Marker)
                    }.GetNewClosure(), $true) | Select-Object -First 1
                if (-not $loop) { throw "no loop over `$grp carries '$Marker'" }
                @($loop.Condition.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                    ForEach-Object { $_.Value })
            }
        }

        It 'captures the membership of every group the Enable script adds' {
            # Disable removes a membership only on the capture's word that the
            # runner was not a member before, so a group Enable adds with no
            # capture entry is one Disable can never take back.
            $added = @(Get-GroupLoopName -Source $LinuxEnable -Marker 'usermod')
            $captured = @(Get-GroupLoopName -Source $CaptureSrc -Marker 'group/')
            $added | Should -Contain 'systemd-journal'
            foreach ($grp in $added) {
                $captured | Should -Contain $grp -Because "Enable adds the runner to '$grp', so the capture must record whether it was a member before"
            }
        }

        It 'has Disable consider every group the Enable script adds' {
            $added = @(Get-GroupLoopName -Source $LinuxEnable -Marker 'usermod')
            $considered = @(Get-GroupLoopName -Source $LinuxDisable -Marker 'gpasswd')
            foreach ($grp in $added) {
                $considered | Should -Contain $grp -Because "Enable adds the runner to '$grp', and Disable is where that is taken back"
            }
        }

        It 'captures every gsettings key the Enable script writes' {
            $LinuxEnable | Should -Match '\$tweaks\s*=\s*Get-LinuxAutomationGsetting'
            $CaptureSrc | Should -Match 'foreach \(\$t in \(Get-LinuxAutomationGsetting\)\)'
            Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -DisableNameChecking
            $written = @(Get-LinuxAutomationGsetting)
            $written.Count | Should -Be 5
            foreach ($entry in $written) {
                $entry.Count | Should -Be 3 -Because 'capture and restore identify the same schema/key used by apply'
                $entry[0] | Should -Match '^org\.gnome\.'
                $entry[1] | Should -Not -BeNullOrEmpty
                $entry[2] | Should -Not -BeNullOrEmpty
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

Describe 'restore descriptions are separate from operating-system selectors' {
    BeforeAll {
        $script:RestoreRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -Global -DisableNameChecking
        Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RestoreRepoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
    }
    It 'renders <Selector> without changing its captured-state key' -TestCases @(
        @{ Path = 'host/windows.hyper-v/Disable-TestAutomation.ps1'; Selector = 'service/W32Time'; English = 'Windows Time service (W32Time)' }
        @{ Path = 'host/macos.utm/Disable-TestAutomation.ps1'; Selector = 'sysadminctl/screenLock'; English = 'sysadminctl unified screen lock' }
    ) {
        param($Path, $Selector, $English)
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RestoreRepoRoot $Path), [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Restore-Knob' -and
                    $node.Extent.Text.Contains("-Name '$Selector'")
                }, $true))
        $calls.Count | Should -Be 1
        $elements = $calls[0].CommandElements
        $descriptionSource = $null
        for ($index = 1; $index -lt $elements.Count - 1; $index++) {
            if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq 'Description') {
                $descriptionSource = $elements[$index + 1].Extent.Text
            }
        }
        $descriptionSource | Should -Match 'Format-YurunaOperatorMessage'
        $adapter = Get-Module Yuruna.Globalization
        $priorContext = & $adapter { $script:OperatorContext }
        try {
            foreach ($locale in @('en-US', 'qps-Ploc')) {
                & $adapter { param($tag) $script:OperatorContext = [pscustomobject]@{ ResolvedTag = $tag } } $locale
                $description = & ([scriptblock]::Create($descriptionSource))
                if ($locale -eq 'en-US') { $description | Should -BeExactly $English }
                else { $description | Should -Not -BeExactly $English }
                $restored = [Collections.Generic.List[string]]::new()
                $skipped = [Collections.Generic.List[string]]::new()
                Invoke-HostKnobRestore -State $null -Name $Selector -Description $description -Apply { throw 'An uncaptured knob must not be applied.' } -Cmdlet ([pscustomobject]@{}) -Restored $restored -Skipped $skipped
                $restored.Count | Should -Be 0
                $skipped.Count | Should -Be 1
                $skipped[0] | Should -BeExactly "$description (not captured)"
            }
        } finally { & $adapter { param($context) $script:OperatorContext = $context } $priorContext }
    }
}

Describe 'the capture file contract' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -Force -DisableNameChecking
        $script:RuntimeDir = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-capture-contract-$PID"
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        $script:ContractEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $RuntimeDir
    }
    AfterAll {
        Remove-Item -LiteralPath $RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
        Restore-YurunaTestEnvironment -Saved $script:ContractEnvironment
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

    It 'records the operating system the settings were applied on' {
        # Without this the harness cannot tell a host that drifted from a host
        # that was upgraded, and the two have different answers: one knob to
        # re-check against a whole set to re-apply.
        $state = Read-HostAutomationState
        $state.os | Should -Not -BeNullOrEmpty
        $state.os.Family | Should -Not -BeNullOrEmpty
    }
}

Describe 'the operating-system drift reading of a capture' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1') -Force -DisableNameChecking
        $script:NowOs = Get-HostOsVersionStamp
        # Only the shape the reader consults; a capture carries more.
        function New-CaptureWithOsMajor {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory capture fixture without changing operating-system state.')]
            param([int]$Major)
            [pscustomobject]@{ os = [pscustomobject]@{ Family = 'macos'; Version = "$Major.0"; Build = ''; Major = $Major } }
        }
    }

    It 'says nothing when the major version has not moved' {
        if ($NowOs.Major -le 0) { Set-ItResult -Skipped -Because 'this host does not report a version to compare against'; return }
        Get-HostAutomationOsDrift -State (New-CaptureWithOsMajor -Major $NowOs.Major) | Should -BeNullOrEmpty
    }

    It 'names the upgrade, and the command that re-applies the settings, when it has' {
        if ($NowOs.Major -le 0) { Set-ItResult -Skipped -Because 'this host does not report a version to compare against'; return }
        # A major of 0 means "cannot tell", so the fixture must stay positive: a host
        # on major 1 is compared against 2 rather than against an impossible 0.
        $wasMajor = if ($NowOs.Major -gt 1) { $NowOs.Major - 1 } else { $NowOs.Major + 1 }
        $drift = Get-HostAutomationOsDrift -State (New-CaptureWithOsMajor -Major $wasMajor)
        $drift | Should -Not -BeNullOrEmpty
        # The remedy travels inside the line: the pre-cycle gate re-emits only
        # its own findings to the console, so a fix written anywhere else never
        # reaches the operator reading a refused cycle.
        $drift | Should -Match 'Enable-TestAutomation'
    }

    It 'stays quiet on a capture that predates the recorded version' {
        # Silence from a capture with no opinion is not agreement. Reading it as
        # a change would warn every host set up before the field existed, once,
        # forever.
        Get-HostAutomationOsDrift -State ([pscustomobject]@{ platform = 'macos.utm' }) | Should -BeNullOrEmpty
        Get-HostAutomationOsDrift -State $null | Should -BeNullOrEmpty
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
        $absentRoot = New-YurunaTestTempDir -Prefix 'yuruna-no-repo'
        try {
            $absent = Join-Path $absentRoot 'repo'
            Stop-YurunaServiceVMSet -RepoRoot $absent -Cmdlet (Get-StubCmdlet -Approve $true) `
                -Restored $restored -Skipped $skipped
            $skipped.Count  | Should -Be 4 -Because 'all four service stop scripts are absent there'
            $restored.Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $absentRoot }
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

Describe 'Ubuntu KVM group membership: Enable adds the runner to systemd-journal, Disable takes back only what Enable added' {
    # Each script's group step is sliced out between its region markers and run
    # in a child process. Stand-ins answer for getent, id and sudo, and the
    # message renderer answers with its key and arguments, so no group on this
    # machine is read or changed and no assertion depends on catalog wording.
    BeforeAll {
        $script:KvmHostDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'host/ubuntu.kvm'

        function Get-GroupStepSlice {
            param([string]$Script, [string]$NextRegion)
            $path = Join-Path $script:KvmHostDir $Script
            $source = [IO.File]::ReadAllText($path)
            $start = $source.IndexOf('# --- REGION: Group membership', [StringComparison]::Ordinal)
            $end = if ($start -ge 0) { $source.IndexOf("# --- REGION: $NextRegion", $start, [StringComparison]::Ordinal) } else { -1 }
            if ($start -lt 0 -or $end -le $start) { throw "$Script no longer frames its group step between two region markers" }
            return @{ Path = $path; Body = $source.Substring($start, $end - $start) }
        }

        # getent answers from a table of /etc/group lines and id from a fixed
        # active-group list. Each sudo stand-in writes one line per call straight
        # to stdout, where the value its caller tests cannot swallow it.
        function Get-GroupFixturePreamble {
            param([hashtable]$Group, [string]$ActiveGroups)
            $rows = @(foreach ($name in $Group.Keys) { "'$name' = '$($Group[$name])'" }) -join '; '
            @'
$ErrorActionPreference = 'Stop'
$env:USER = 'runner'
$groupTable = @{ __ROWS__ }
function Format-YurunaOperatorMessage {
    param([string]$Key, [hashtable]$Arguments = @{})
    $pairs = @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })
    return ((@('MSG', $Key) + $pairs) -join '|')
}
function getent { param($Database, $Name) $null = $Database; $groupTable[$Name] }
function id { '__ACTIVE__' }
'@.Replace('__ROWS__', $rows).Replace('__ACTIVE__', $ActiveGroups)
        }

        function Invoke-GroupFixture {
            param([string[]]$Text)
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            [IO.File]::WriteAllText($fixture, ($Text -join "`n") + "`n")
            $lines = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $fixture 2>&1 | ForEach-Object {
                    [regex]::Replace([regex]::Replace("$_", '\x1b\[[0-9;?]*[ -/]*[@-~]', ''), '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
                })
            return @{ ExitCode = $LASTEXITCODE; Lines = $lines; Text = ($lines -join "`n") }
        }

        function Invoke-EnableGroupStep {
            param([hashtable]$Group, [string]$ActiveGroups, [bool]$SudoSucceeds = $true, [bool]$LibvirtReady = $true)
            $slice = Get-GroupStepSlice -Script 'Enable-TestAutomation.ps1' -NextRegion 'Pool storage and host identity'
            $sudo = @'
$Script:Unmet = [System.Collections.Generic.List[string]]::new()
$libvirtReady = __READY__
function Invoke-HostSudo {
    param([string[]]$Argument)
    [Console]::Out.WriteLine("SUDO|$($Argument -join ' ')")
    return __RESULT__
}
'@.Replace('__READY__', $(if ($LibvirtReady) { '$true' } else { '$false' })).Replace('__RESULT__', $(if ($SudoSucceeds) { '$true' } else { '$false' }))
            Invoke-GroupFixture -Text @(
                (Get-GroupFixturePreamble -Group $Group -ActiveGroups $ActiveGroups)
                $sudo
                (Get-YurunaTestFunctionAst -Path $slice.Path -Name 'Invoke-Step').Extent.Text
                $slice.Body
                '"UNMET|$($Script:Unmet -join ";")"'
            )
        }

        function Invoke-DisableGroupStep {
            param([hashtable]$Group, [hashtable]$Knob)
            $slice = Get-GroupStepSlice -Script 'Disable-TestAutomation.ps1' -NextRegion 'libvirt-qemu search ACL on $HOME'
            $knobs = @{}
            foreach ($name in $Knob.Keys) { $knobs["group/$name"] = @{ name = "membership of $name"; present = $true; value = $Knob[$name] } }
            $stateJson = (@{ knobs = $knobs } | ConvertTo-Json -Depth 4 -Compress).Replace("'", "''")
            $teardown = @'
$state = '__STATE__' | ConvertFrom-Json
$restored = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
function Invoke-YurunaSudo {
    param([string[]]$Argument, [switch]$TolerateBlocked)
    $null = $TolerateBlocked
    [Console]::Out.WriteLine("SUDO|$($Argument -join ' ')")
    return @{ ExitCode = 0; Output = '' }
}
'@.Replace('__STATE__', $stateJson)
            # The real knob reader, imported before the stand-ins so that the
            # renderer the step calls is the stand-in rather than the module's.
            Invoke-GroupFixture -Text @(
                '[CmdletBinding(SupportsShouldProcess)] param()'
                "Import-Module '$(Join-Path $PSScriptRoot 'Test.HostAutomationState.psm1')' -DisableNameChecking"
                (Get-GroupFixturePreamble -Group $Group -ActiveGroups 'runner')
                $teardown
                $slice.Body
                'foreach ($line in $restored) { "RESTORED|$line" }'
                'foreach ($line in $skipped) { "SKIPPED|$line" }'
            )
        }

        $script:MemberGroups = @{ libvirt = 'libvirt:x:119:runner'; kvm = 'kvm:x:993:runner' }
    }

    Context 'Enable' {
        It 'adds the runner to systemd-journal and says that a new login is needed' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner libvirt kvm' -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:' })
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -Be @('SUDO|usermod -aG systemd-journal runner')
            $run.Text | Should -Match ([regex]::Escape('MSG|host.operator_a5c2b328548a1dd1|grp=systemd-journal|uSER=runner'))
            $run.Lines | Should -Contain 'UNMET|'
        }

        It 'records an unmet condition when usermod is refused' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner libvirt kvm' -SudoSucceeds $false -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:other' })
            $run.ExitCode | Should -Be 0 -Because $run.Text
            $run.Text | Should -Match ([regex]::Escape('MSG|host.operator_0a2c942a7a5d733a|grp=systemd-journal|uSER=runner'))
            $run.Lines | Should -Contain "UNMET|runner not in group 'systemd-journal'"
        }

        It 'leaves an existing membership alone' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner libvirt kvm systemd-journal' -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:other,runner' })
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -BeNullOrEmpty
            @($run.Lines | Where-Object { $_ -like '*MSG|*' }) | Should -BeNullOrEmpty
            $run.Lines | Should -Contain 'UNMET|'
        }

        It 'asks for a new login session when the membership is newer than this one' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner libvirt kvm' -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:runner' })
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -BeNullOrEmpty
            $run.Lines | Should -Contain 'MSG|host.kvm_journal_group_session_stale'
            $run.Text | Should -Not -Match ([regex]::Escape('MSG|host.operator_37d4fa1ce9d640c6|grp=systemd-journal')) -Because 'that message is about virsh and virt-install'
        }

        It 'adds the journal group even where the libvirt packages are missing' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner' -LibvirtReady $false -Group @{ 'systemd-journal' = 'systemd-journal:x:101:' }
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -Be @('SUDO|usermod -aG systemd-journal runner')
            $run.Text | Should -Not -Match ([regex]::Escape('MSG|host.operator_1c96d636b10e91f1')) -Because 'the package gate already reported the missing libvirt groups'
        }

        It 'warns, without blaming usermod or libvirt, when the host has no systemd-journal group' {
            $run = Invoke-EnableGroupStep -ActiveGroups 'runner libvirt kvm' -Group $script:MemberGroups
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -BeNullOrEmpty
            $run.Text | Should -Match ([regex]::Escape('MSG|host.kvm_journal_group_missing'))
            $run.Text | Should -Not -Match ([regex]::Escape('MSG|host.operator_1c96d636b10e91f1|grp=systemd-journal'))
        }
    }

    Context 'Disable' {
        It 'removes the systemd-journal membership the capture shows Enable added' {
            $run = Invoke-DisableGroupStep -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:runner' }) -Knob @{ 'systemd-journal' = 'not-a-member' }
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -Be @('SUDO|gpasswd -d runner systemd-journal')
            @($run.Lines | Where-Object { $_ -like "RESTORED|Removed runner from 'systemd-journal'*" }).Count | Should -Be 1
        }

        It 'leaves a systemd-journal membership the capture has no record of' {
            $run = Invoke-DisableGroupStep -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:runner' }) -Knob @{}
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -BeNullOrEmpty
            $run.Lines | Should -Contain "SKIPPED|Membership of 'systemd-journal' (not captured; left as it is)"
        }

        It 'leaves a systemd-journal membership that was there before Enable' {
            $run = Invoke-DisableGroupStep -Group ($script:MemberGroups + @{ 'systemd-journal' = 'systemd-journal:x:101:runner' }) -Knob @{ 'systemd-journal' = 'member' }
            $run.ExitCode | Should -Be 0 -Because $run.Text
            @($run.Lines | Where-Object { $_ -like 'SUDO|*' }) | Should -BeNullOrEmpty
            $run.Lines | Should -Contain "SKIPPED|Membership of 'systemd-journal' (was already 'member' before automation)"
        }
    }
}

AfterAll { Restore-YurunaTestEnvironment -Saved $script:SuiteEnvironment }
