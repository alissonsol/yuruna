<#PSScriptInfo
.VERSION 2026.09.27
.GUID 429a9b8e-d547-4b8a-8e37-5d6306ea49b7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service vm policy preserve repair installer parity pester
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
    Test-YurunaServiceVmRunning and Resolve-YurunaServiceVmPolicy: the
    Preserve policy's parity with the installer's own gate, the evidence
    rules, and the Repair policy's matrix.
.DESCRIPTION
    Parity is behavioral on both sides. The installer's is_service_vm_running
    is lifted out of install/macos.utm.sh with the constants and the bounded
    status helper it reads, and run under bash against a stand-in utmctl, a
    stand-in pgrep and a stand-in nc. The PowerShell side runs the real
    macOS driver's state classification against the same stand-in utmctl,
    with the hypervisor probe the macOS driver would report for that world,
    through Test-YurunaServiceVmRunning -UnknownMeans Preserve. Every arm of
    the installer's case statement has a fixture row, and a row where the
    installer preserves must preserve in PowerShell too.

    The Repair matrix drives the pure policy function directly.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:DriverPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.ServiceCensus.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -DisableNameChecking -Global

    $script:ServiceVm = @(
        [pscustomobject]@{ Key = 'caching-proxy'; VMName = 'yuruna-caching-proxy-service'; DisplayName = 'Caching-proxy service'; HealthPort = 3128 }
        [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = 80 }
        [pscustomobject]@{ Key = 'pool-control'; VMName = 'yuruna-pool-control-service'; DisplayName = 'Pool-control service'; HealthPort = 80 }
        [pscustomobject]@{ Key = 'download-agent'; VMName = 'yuruna-download-agent-service'; DisplayName = 'Download-agent service'; HealthPort = 80 }
    )

    function New-EvidenceRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory evidence row only.')]
        [CmdletBinding()]
        param(
            [string]$Key = 'stash', [string]$State = 'Unknown', [string]$Reason = 'timeout', [string]$VMName,
            [string]$HostingMode = 'vm', [string]$Ambiguity = '', [string]$DesiredState = '', [bool]$CensusPositive = $false,
            $ServiceAnswered = $null, [bool]$StateFromRecord = $true, [string]$Source = 'manifest+hard-coded'
        )
        if (-not $VMName) { $VMName = "yuruna-$Key-service" }
        [pscustomobject]@{
            Key = $Key; VMName = $VMName; DisplayName = $Key; HealthPort = 80; Source = $Source; VMNameSource = 'manifest-default'
            HostingMode = $HostingMode; Ambiguity = $Ambiguity; State = $State; RawState = ''; Reason = $Reason
            StateFromRecord = $StateFromRecord; ServiceAnswered = $ServiceAnswered; CensusPositive = $CensusPositive
            CensusAgeSeconds = if ($CensusPositive) { 120 } else { $null }; EvidenceLifetimeSeconds = 86400; EvidenceOrigin = 'default'
            DesiredState = $DesiredState; IntentGeneration = 0; IntentResult = ''; Identity = $null
        }
    }
    $script:Responsive = [pscustomobject]@{ State = 'Responsive'; Reason = 'responsive'; Probed = $true; ElapsedMs = 5 }
    $script:Qualified = [pscustomobject]@{ HostType = 'host.test'; StoreQualified = $true; PassiveCorroborationQualified = $true; EvidenceUsableForRepair = $true; UnavailableReason = '' }
    $script:Unqualified = Get-YurunaServiceCensusCapability -HostType 'host.macos.utm'
}

BeforeDiscovery {
    $all = { param([string]$Status) @($Status, $Status, $Status, $Status) }
    $one = { param([string]$Status) @('stopped', $Status, 'stopped', 'stopped') }
    # Utmctl: path | bundle | none. Launch: ok | fails. Arm: the installer
    # case-statement alternatives the row exercises.
    $script:Worlds = @(
        @{ Name = 'squid answers at the persisted proxy address'; Squid = $true; Utm = $true; Utmctl = 'path'; Status = (& $all 'started'); Arm = @() }
        @{ Name = 'squid answers while UTM is not running'; Squid = $true; Utm = $false; Utmctl = 'path'; Status = (& $all 'stopped'); Arm = @() }
        @{ Name = 'UTM is not running'; Squid = $false; Utm = $false; Utmctl = 'path'; Status = (& $all 'started'); Arm = @() }
        @{ Name = 'UTM runs and no utmctl exists'; Squid = $false; Utm = $true; Utmctl = 'none'; Status = (& $all 'stopped'); Arm = @() }
        @{ Name = 'only the bundle utmctl exists and every VM is stopped'; Squid = $false; Utm = $true; Utmctl = 'bundle'; Status = (& $all 'stopped'); Arm = @('stopped') }
        @{ Name = 'every VM is stopped'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $all 'stopped'); Arm = @('stopped') }
        @{ Name = 'no service VM is registered'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $all 'not-found'); Arm = @('*"not found"*') }
        @{ Name = 'stopped and unregistered VMs mixed'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = @('stopped', 'not-found', 'not-found', 'stopped'); Arm = @('stopped', '*"not found"*') }
        @{ Name = 'one VM started'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'started'); Arm = @('started') }
        @{ Name = 'one VM paused'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'paused'); Arm = @('paused') }
        @{ Name = 'one VM suspended'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'suspended'); Arm = @('suspended') }
        @{ Name = 'Apple Events denied for one VM'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'denied'); Arm = @('*OSStatus*', '*"-1743"*') }
        @{ Name = 'utmctl refuses from SSH'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'ssh'); Arm = @('*"does not work from SSH"*') }
        @{ Name = 'an Apple Event error without an OSStatus code'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'apple-event'); Arm = @('*"Apple Event"*') }
        @{ Name = 'a status call that printed nothing'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'empty'); Arm = @('""') }
        @{ Name = 'an unrecognized status answer'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = (& $one 'garbled'); Arm = @('*') }
        @{ Name = 'a status call that never returns'; Squid = $false; Utm = $true; Utmctl = 'path'; Status = @('hang', 'stopped', 'stopped', 'stopped'); Arm = @() }
        @{ Name = 'a status call that cannot be launched'; Squid = $false; Utm = $true; Utmctl = 'path'; Launch = 'fails'; Status = (& $all 'stopped'); Arm = @() }
        # The macOS probe reports a missing client before it looks at the
        # process table, so without any utmctl PowerShell cannot tell that
        # UTM is down and preserves; the installer's pgrep can.
        @{ Name = 'UTM is not running and no utmctl exists'; Squid = $false; Utm = $false; Utmctl = 'none'; Status = (& $all 'stopped'); Arm = @(); PowerShellMoreConservative = $true }
    )
}

Describe 'Preserve parity with the installer''s service gate (install/macos.utm.sh)' {
    BeforeAll {
        $script:Bash = (Get-Command -Name bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $installerText = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'install/macos.utm.sh')
        # The same function extraction Test.UtmServiceVmSuspend pins, plus the
        # constants and the bounded status helper the gate reads: lifting only
        # the gate would leave them unset, and set -u would fail on the first.
        $script:Gate = [regex]::Match($installerText, '(?ms)^is_service_vm_running\(\).*?\n\}').Value
        $helper = [regex]::Match($installerText, '(?ms)^yuruna_utmctl_status\(\).*?\n\}').Value
        $constants = foreach ($pattern in @('^UTM_APP=.*$', '^UTMCTL_BUNDLE=.*$', '^SERVICE_VM_DETECT_REASON=.*$', '^YURUNA_SERVICE_VM_NAME=\(.*\)$', '^UTMCTL_STATUS_TIMEOUT_SECONDS=\d+$')) {
            $m = [regex]::Match($installerText, "(?m)$pattern")
            if (-not $m.Success) { throw "installer constant not found: $pattern" }
            $m.Value
        }
        $script:Lifted = ($constants -join "`n") + "`n" + $helper + "`n" + $script:Gate
        $script:StatusText = @{
            'started'     = @{ Out = 'started'; Err = ''; Exit = 0 }
            'paused'      = @{ Out = 'paused'; Err = ''; Exit = 0 }
            'suspended'   = @{ Out = 'suspended'; Err = ''; Exit = 0 }
            'stopped'     = @{ Out = 'stopped'; Err = ''; Exit = 0 }
            'not-found'   = @{ Out = 'Error: Virtual machine not found.'; Err = ''; Exit = 1 }
            'denied'      = @{ Out = ''; Err = 'Error from event: The operation could not be completed. (OSStatus error -1743.)'; Exit = 0 }
            'ssh'         = @{ Out = ''; Err = 'Error: utmctl does not work from SSH sessions.'; Exit = 1 }
            'apple-event' = @{ Out = ''; Err = 'Error: Apple Event handler failed.'; Exit = 1 }
            'empty'       = @{ Out = ''; Err = ''; Exit = 0 }
            'garbled'     = @{ Out = 'something nobody expected'; Err = ''; Exit = 0 }
            'hang'        = @{ Hang = $true }
        }
        function Write-UtmctlStandIn {
            param([string]$Path, [string[]]$Status, [bool]$Executable = $true)
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('#!/bin/sh')
            $lines.Add('[ "$1" = status ] || exit 0')
            $lines.Add('case "$2" in')
            for ($i = 0; $i -lt $script:ServiceVm.Count; $i++) {
                $answer = $script:StatusText[$Status[$i]]
                $lines.Add("  $($script:ServiceVm[$i].VMName))")
                if ($answer.Hang) { $lines.Add('    exec sleep 30 ;;'); continue }
                $body = ''
                if ($answer.Out) { $body += "printf '%s\n' '$($answer.Out)'; " }
                if ($answer.Err) { $body += "printf '%s\n' '$($answer.Err)' >&2; " }
                $lines.Add("    ${body}exit $($answer.Exit) ;;")
            }
            $lines.Add('esac')
            $lines.Add('echo "Error: Virtual machine not found."; exit 1')
            [System.IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n")
            if ($Executable) { & chmod 755 $Path } else { & chmod 644 $Path }
        }

        function Invoke-InstallerGate {
            param([hashtable]$World, [string]$Root)
            $bin = Join-Path $Root 'bash-bin'; $tmp = Join-Path $Root 'bash-tmp'; $checkout = Join-Path $Root 'checkout'
            $null = New-Item -ItemType Directory -Force -Path $bin, $tmp, (Join-Path $checkout 'test/status/runtime')
            [System.IO.File]::WriteAllText((Join-Path $checkout 'test/status/runtime/yuruna-caching-proxy-service.yml'), "ipAddress: 127.0.0.1`n")
            $bundle = Join-Path $Root 'UTM.app/Contents/MacOS/utmctl'
            if ($World.Utmctl -eq 'path') { Write-UtmctlStandIn -Path (Join-Path $bin 'utmctl') -Status $World.Status }
            if ($World.Utmctl -eq 'bundle') {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bundle)
                Write-UtmctlStandIn -Path $bundle -Status $World.Status
            }
            $tmpDir = if ($World.Launch -eq 'fails') { Join-Path $Root 'no-such-tmp' } else { $tmp }
            $pgrep = if ($World.Utm) { 0 } else { 1 }
            $nc = if ($World.Squid) { 0 } else { 1 }
            $body = @"
set -uo pipefail
$($script:Lifted)
UTMCTL_BUNDLE='$bundle'
UTMCTL_STATUS_TIMEOUT_SECONDS=1
YURUNA_DIR='$checkout'
pgrep() { return $pgrep; }
nc() { return $nc; }
is_service_vm_running
echo "RC=`$?"
echo "REASON=`$SERVICE_VM_DETECT_REASON"
"@
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Bash)
            $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($body)
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
            $psi.Environment['PATH'] = "${bin}:/usr/bin:/bin"
            $psi.Environment['TMPDIR'] = $tmpDir
            $process = [System.Diagnostics.Process]::Start($psi)
            $out = $process.StandardOutput.ReadToEndAsync()
            $null = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw 'the lifted installer gate did not finish' }
            $rc = [regex]::Match($out.Result, '(?m)^RC=(\d+)').Groups[1].Value
            [pscustomobject]@{ Preserve = ($rc -eq '0'); Reason = [regex]::Match($out.Result, '(?m)^REASON=(.*)$').Groups[1].Value }
        }

        function Invoke-PowerShellPreserve {
            param([hashtable]$World, [string]$Root)
            $bin = Join-Path $Root 'ps-bin'
            $null = New-Item -ItemType Directory -Force -Path $bin
            # The driver resolves the bundle's utmctl when none is on PATH; this
            # host has no bundle, so the stand-in goes on PATH for either spelling.
            if ($World.Utmctl -in @('path', 'bundle')) {
                Write-UtmctlStandIn -Path (Join-Path $bin 'utmctl') -Status $World.Status -Executable:($World.Launch -ne 'fails')
            }
            $probe = if ($World.Utmctl -eq 'none') { [pscustomobject]@{ state = 'Undetermined'; reason = 'missing-client'; elapsedMs = 1 } }
                     elseif (-not $World.Utm) { [pscustomobject]@{ state = 'Unresponsive'; reason = 'app-stopped'; elapsedMs = 1 } }
                     else { [pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 1 } }
            $listener = $null
            $identity = foreach ($vm in $script:ServiceVm) {
                [pscustomobject]@{ Key = $vm.Key; VMName = $vm.VMName; DisplayName = $vm.DisplayName; HealthPort = $vm.HealthPort; HostingMode = 'vm' }
            }
            if ($World.Squid) {
                $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $listener.Start()
                $identity[0] | Add-Member -NotePropertyName Advertised -NotePropertyValue ([pscustomobject]@{
                        Address = '127.0.0.1'; Port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; Url = ''; Origin = 'cp-state' })
            }
            $savedPath = $env:PATH
            try {
                $env:PATH = "${bin}:/usr/bin:/bin"
                $verdict = Test-YurunaServiceVmRunning -Identity $identity -UnknownMeans Preserve -HostType 'host.macos.utm' -HypervisorProbe $probe `
                    -StateRoot (Join-Path $Root 'no-root') -RuntimeDir (Join-Path $Root 'no-runtime') -Deadline (New-YurunaDeadline -TotalMilliseconds 6000)
            } finally {
                $env:PATH = $savedPath
                if ($listener) { $listener.Stop() }
            }
            return $verdict
        }

        Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    }
    AfterAll {
        Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    }

    It 'has a fixture row for every alternative of the installer''s case statement' -ForEach @(@{ Covered = [string[]]@($script:Worlds | ForEach-Object { $_.Arm } | ForEach-Object { $_ }) }) {
        $script:Gate | Should -Not -BeNullOrEmpty
        $case = [regex]::Match($script:Gate, '(?ms)case "\$status" in(.*?)\n\s*esac').Groups[1].Value
        $alternatives = foreach ($m in [regex]::Matches($case, '(?m)^\s*([^\s#][^)\n]*)\)\s*$')) {
            $m.Groups[1].Value.Split('|') | ForEach-Object { $_.Trim() }
        }
        @($alternatives).Count | Should -BeGreaterOrEqual 10
        foreach ($alternative in $alternatives) {
            $Covered | Should -Contain $alternative -Because "the installer arm '$alternative' needs a parity row"
        }
    }

    It 'preserves in PowerShell wherever the installer preserves, and agrees exactly on consistent evidence: <Name>' -ForEach $script:Worlds {
        if (-not $script:Bash) { Set-ItResult -Skipped -Because 'bash is not installed on this host, so the installer gate cannot run'; return }
        $root = Join-Path $TestDrive ('world-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $root -Force
        $installer = Invoke-InstallerGate -World $_ -Root $root
        $verdict = Invoke-PowerShellPreserve -World $_ -Root $root
        if ($installer.Preserve) {
            $verdict.Preserve | Should -BeTrue -Because "the installer preserved ($($installer.Reason)), so PowerShell may not be less conservative"
        }
        if ($_.PowerShellMoreConservative) {
            $installer.Preserve | Should -BeFalse
            $verdict.Preserve | Should -BeTrue
        } else {
            $verdict.Preserve | Should -Be $installer.Preserve -Because "installer: '$($installer.Reason)'"
        }
        $verdict.Satisfied | Should -BeTrue -Because 'the Preserve policy reports; it never refuses'
    }
}

Describe 'evidence rules' {
    BeforeAll {
        Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
        $script:Fake = @{ State = @{}; Calls = [System.Collections.Generic.List[string]]::new(); Probe = $null }
        function global:Get-VMState {
            param([string]$VMName)
            $script:Fake.Calls.Add($VMName)
            if ($script:Fake.State.ContainsKey($VMName)) { return $script:Fake.State[$VMName] }
            return 'absent'
        }
        function global:Test-VirtualizationResponsive {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in with the driver''s signature.')]
            param([int]$TimeoutSeconds = 20, $Deadline)
            if ($script:Fake.Probe) { return $script:Fake.Probe }
            [pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 1 }
        }
        $script:Identity = foreach ($vm in $script:ServiceVm) { [pscustomobject]@{ Key = $vm.Key; VMName = $vm.VMName; DisplayName = $vm.DisplayName; HealthPort = $vm.HealthPort; HostingMode = 'vm' } }
        $script:Root = Join-Path $TestDrive 'evidence-root'
        $null = New-Item -ItemType Directory -Path $script:Root -Force
    }
    AfterAll {
        foreach ($name in @('Get-VMState', 'Test-VirtualizationResponsive')) { Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        $script:Fake.State = @{}
        $script:Fake.Calls.Clear()
        $script:Fake.Probe = $null
    }

    It 'turns stopped and absent into Unknown when the hypervisor did not answer' {
        foreach ($vm in $script:ServiceVm) { $script:Fake.State[$vm.VMName] = 'stopped' }
        $script:Fake.Probe = [pscustomobject]@{ state = 'Undetermined'; reason = 'timeout'; elapsedMs = 20000 }
        $v = Test-YurunaServiceVmRunning -Identity $script:Identity -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe
        foreach ($row in $v.Services) {
            $row.State | Should -Be 'Unknown'
            $row.Reason | Should -Be 'timeout'
            $row.Preserve | Should -BeTrue
        }
        $script:Fake.Calls.Count | Should -Be 0
    }

    It 'reads app-stopped as every guest stopped on macOS only' {
        $script:Fake.Probe = [pscustomobject]@{ state = 'Unresponsive'; reason = 'app-stopped'; elapsedMs = 3 }
        $mac = Test-YurunaServiceVmRunning -Identity $script:Identity -HostType 'host.macos.utm' -StateRoot $script:Root -NoServiceProbe
        @($mac.Services | ForEach-Object State | Sort-Object -Unique) | Should -Be @('Stopped')
        $mac.Preserve | Should -BeFalse -Because 'no guest runs without UTM'
        foreach ($hostType in @('host.ubuntu.kvm', 'host.windows.hyper-v')) {
            $other = Test-YurunaServiceVmRunning -Identity $script:Identity -HostType $hostType -StateRoot $script:Root -NoServiceProbe
            @($other.Services | ForEach-Object State | Sort-Object -Unique) | Should -Be @('Unknown') -Because "a stopped daemon on $hostType does not prove its guests are off"
        }
    }

    It 'maps positively recognized states in a responsive pass' {
        $script:Fake.State['yuruna-caching-proxy-service'] = 'running'
        $script:Fake.State['yuruna-stash-service'] = 'stopped'
        $script:Fake.State['yuruna-pool-control-service'] = 'absent'
        $script:Fake.State['yuruna-download-agent-service'] = 'unknown'
        $v = Test-YurunaServiceVmRunning -Identity $script:Identity -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe
        $byKey = @{}; foreach ($row in $v.Services) { $byKey[$row.Key] = $row }
        $byKey['caching-proxy'].State | Should -Be 'Running'
        $byKey['caching-proxy'].Reason | Should -Be 'responsive'
        $byKey['stash'].State | Should -Be 'Stopped'
        $byKey['stash'].Preserve | Should -BeFalse
        $byKey['pool-control'].State | Should -Be 'Absent'
        $byKey['download-agent'].State | Should -Be 'Unknown'
        $byKey['download-agent'].Reason | Should -Be 'unclassified'
        $v.Hypervisor.Probed | Should -BeTrue
        $v.Hypervisor.State | Should -Be 'Responsive'
    }

    It 'preserves a macOS stopped reading that did not come from the structured record' {
        $script:Fake.State['yuruna-stash-service'] = 'stopped'
        $v = Test-YurunaServiceVmRunning -Identity @($script:Identity[1]) -HostType 'host.macos.utm' -StateRoot $script:Root -NoServiceProbe
        $v.Services[0].State | Should -Be 'Stopped'
        $v.Services[0].Preserve | Should -BeTrue -Because 'the raw word behind it may have been paused or suspended'
    }

    It 'without a probe, takes running as running and nothing else, and Repair refuses' {
        Remove-Item -Path 'Function:\Test-VirtualizationResponsive' -Force -ErrorAction SilentlyContinue
        try {
            $script:Fake.State['yuruna-caching-proxy-service'] = 'running'
            $script:Fake.State['yuruna-stash-service'] = 'stopped'
            $v = Test-YurunaServiceVmRunning -Identity $script:Identity -UnknownMeans Repair -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe
            $byKey = @{}; foreach ($row in $v.Services) { $byKey[$row.Key] = $row }
            $byKey['caching-proxy'].State | Should -Be 'Running'
            $byKey['stash'].State | Should -Be 'Unknown'
            $byKey['stash'].Reason | Should -Be 'unclassified'
            $v.Hypervisor.Probed | Should -BeFalse
            $v.Satisfied | Should -BeFalse
            $v.Refusal | Should -Be 'hypervisor-probe-unavailable'
        } finally {
            function global:Test-VirtualizationResponsive {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in with the driver''s signature.')]
                param([int]$TimeoutSeconds = 20, $Deadline)
                if ($script:Fake.Probe) { return $script:Fake.Probe }
                [pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 1 }
            }
        }
    }

    It 'carries the roster disagreement of a whole identity set passed as -Identity' {
        $set = [pscustomobject]@{ PSTypeName = 'Yuruna.ServiceVmIdentitySet'; SchemaVersion = 1; CapturedUnixMs = 0; RosterAgreement = $false
            RosterDisagreement = [string[]]@('hard-coded-only:yuruna-extra-service'); Rows = [object[]]$script:Identity }
        foreach ($vm in $script:ServiceVm) { $script:Fake.State[$vm.VMName] = 'running' }
        $v = Test-YurunaServiceVmRunning -Identity @($set) -UnknownMeans Repair -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe
        @($v.Services).Count | Should -Be 4
        $v.Refusal | Should -Be 'roster-disagreement'
    }

    It 'derives the roster disagreement from rows passed alone, from the roster each one records' {
        foreach ($vm in $script:ServiceVm) { $script:Fake.State[$vm.VMName] = 'running' }
        $agreed = @($script:Identity | ForEach-Object {
                $copy = $_.PSObject.Copy()
                $copy | Add-Member -NotePropertyName Source -NotePropertyValue 'manifest+hard-coded' -Force
                $copy
            })
        $repair = { param([object[]]$Rows) Test-YurunaServiceVmRunning -Identity $Rows -UnknownMeans Repair -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe }
        (& $repair $agreed).Refusal | Should -Be '' -Because 'rows both rosters name agree'
        $drifted = @($agreed | ForEach-Object { $_.PSObject.Copy() })
        $drifted[3].Source = 'hard-coded'
        $v = & $repair $drifted
        $v.Refusal | Should -Be 'roster-disagreement'
        $v.RefusalKeys | Should -Contain $drifted[3].Key
        $roundTrip = @(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $drifted -Depth 5) -AsHashtable)
        (& $repair $roundTrip).Refusal | Should -Be 'roster-disagreement' -Because 'rows read back from JSON keep the roster they came from'
        (& $repair $script:Identity).Refusal | Should -Be '' -Because 'a row that records no roster says nothing about either list'
        $explicit = Test-YurunaServiceVmRunning -Identity $drifted -RosterDisagreement @() -UnknownMeans Repair -HostType 'host.ubuntu.kvm' -StateRoot $script:Root -NoServiceProbe
        $explicit.Refusal | Should -Be '' -Because 'a disagreement the caller passes is the one that counts'
    }

    It 'asks each advertised endpoint once, in parallel, within two seconds' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $rows = @(
                [pscustomobject]@{ Key = 'caching-proxy'; VMName = 'yuruna-caching-proxy-service'; HealthPort = 3128; HostingMode = 'vm'
                    Advertised = [pscustomobject]@{ Address = '127.0.0.1'; Port = $port; Url = ''; Origin = 'cp-state' } }
                [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; HealthPort = 80; HostingMode = 'vm'
                    Advertised = [pscustomobject]@{ Address = '192.0.2.1'; Port = 80; Url = ''; Origin = 'marker' } }
            )
            $script:Fake.State['yuruna-caching-proxy-service'] = 'stopped'
            $script:Fake.State['yuruna-stash-service'] = 'stopped'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $v = Test-YurunaServiceVmRunning -Identity $rows -HostType 'host.ubuntu.kvm' -StateRoot $script:Root
            $sw.Stop()
        } finally { $listener.Stop() }
        $sw.ElapsedMilliseconds | Should -BeLessOrEqual 4000
        ($v.Services | Where-Object Key -eq 'caching-proxy').ServiceAnswered | Should -BeTrue
        ($v.Services | Where-Object Key -eq 'caching-proxy').Preserve | Should -BeTrue -Because 'an answering service is not quit out from under'
        ($v.Services | Where-Object Key -eq 'stash').ServiceAnswered | Should -BeFalse
    }
}

Describe 'the Repair policy matrix' {
    It 'restores a running guest and leaves a positively stopped or suspended one' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence @(
            New-EvidenceRow -Key 'caching-proxy' -State 'Running' -Reason 'responsive'
            New-EvidenceRow -Key 'stash' -State 'Stopped' -Reason 'responsive'
            New-EvidenceRow -Key 'pool-control' -State 'Suspended' -Reason 'responsive'
            New-EvidenceRow -Key 'download-agent' -State 'Absent' -Reason 'not-found'
        )
        $v.Satisfied | Should -BeTrue
        $v.Refusal | Should -Be ''
        @($v.RecoverySet | ForEach-Object Key) | Should -Be @('caching-proxy')
        @($v.LeaveStoppedSet | ForEach-Object Key) | Should -Be @('stash', 'pool-control')
        ($v.Services | Where-Object Key -eq 'download-agent').Disposition | Should -Be 'not-deployed'
        ,$v.RecoverySet | Should -BeOfType [object[]] -Because 'a one-element recovery set stays an array'
    }

    It 'restores an unknown guest on a fresh corroborated census answer only where the capability allows it' {
        $row = New-EvidenceRow -Key 'stash' -State 'Unknown' -Reason 'timeout' -CensusPositive $true
        $allowed = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Qualified -Evidence @($row)
        $allowed.Satisfied | Should -BeTrue
        $allowed.Services[0].Disposition | Should -Be 'restore-required'
        $allowed.Services[0].Evidence | Should -Be 'census'
        $allowed.Services[0].EvidenceAgeSeconds | Should -Be 120
        $denied = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.macos.utm' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence @($row)
        $denied.Satisfied | Should -BeFalse
        $denied.Refusal | Should -Be 'service-evidence-incomplete'
        $denied.Services[0].Disposition | Should -Be 'unresolved'
    }

    It 'refuses when evidence covers only the caching proxy and three services are unknown' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Qualified -Evidence @(
            New-EvidenceRow -Key 'caching-proxy' -State 'Unknown' -CensusPositive $true
            New-EvidenceRow -Key 'stash' -State 'Unknown'
            New-EvidenceRow -Key 'pool-control' -State 'Unknown'
            New-EvidenceRow -Key 'download-agent' -State 'Unknown'
        )
        $v.Satisfied | Should -BeFalse
        $v.Refusal | Should -Be 'service-evidence-incomplete'
        @($v.RefusalKeys) | Should -Be @('stash', 'pool-control', 'download-agent')
        @($v.UnresolvedSet).Count | Should -Be 3
    }

    It 'never restores a guest stopped on purpose, and never treats a host process as a guest' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence @(
            New-EvidenceRow -Key 'stash' -State 'Running' -Reason 'responsive' -DesiredState 'stopped'
            New-EvidenceRow -Key 'download-agent' -State 'Absent' -Reason 'not-found' -DesiredState 'stopped'
            New-EvidenceRow -Key 'pool-control' -State 'HostProcess' -HostingMode 'host-process'
        )
        $v.Satisfied | Should -BeTrue
        @($v.RecoverySet).Count | Should -Be 0
        ($v.Services | Where-Object Key -eq 'stash').Disposition | Should -Be 'intended-stopped'
        ($v.Services | Where-Object Key -eq 'download-agent').Disposition | Should -Be 'intended-stopped'
        ($v.Services | Where-Object Key -eq 'pool-control').Disposition | Should -Be 'not-a-guest'
    }

    It 'refuses an ambiguous identity and a roster disagreement' {
        $ambiguous = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence @(
            New-EvidenceRow -Key 'stash' -State 'Running' -Ambiguity 'conflicting-identity'
        )
        $ambiguous.Refusal | Should -Be 'service-identity-ambiguous'
        @($ambiguous.RefusalKeys) | Should -Be @('stash')
        $drift = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified `
            -RosterDisagreement @('hard-coded-only:yuruna-extra-service') -Evidence @(New-EvidenceRow -Key 'stash' -State 'Running')
        $drift.Refusal | Should -Be 'roster-disagreement'
    }

    It 'refuses operator selections from a channel that may not make them' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified `
            -RestoreServiceVmName @('yuruna-stash-service') -Evidence @(New-EvidenceRow -Key 'stash' -State 'Unknown')
        $v.Satisfied | Should -BeFalse
        $v.Refusal | Should -Be 'operator-selection-not-permitted'
        $v.Services[0].Disposition | Should -Be 'unresolved' -Because 'a refused selection selects nothing'
    }

    It 'refuses overlapping and unknown selections' {
        $rows = @(New-EvidenceRow -Key 'stash' -State 'Unknown'; New-EvidenceRow -Key 'pool-control' -State 'Unknown')
        (Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -AllowOperatorSelection `
            -RestoreServiceVmName @('yuruna-stash-service') -LeaveStoppedServiceVmName @('yuruna-stash-service') -Evidence $rows).Refusal | Should -Be 'operator-selection-invalid'
        (Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -AllowOperatorSelection `
            -RestoreServiceVmName @('not-a-captured-vm') -Evidence $rows).Refusal | Should -Be 'operator-selection-invalid'
    }

    It 'rejects a selection whose spelling differs only by case' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -AllowOperatorSelection `
            -RestoreServiceVmName 'Yuruna-Stash-Service' -Evidence @(New-EvidenceRow -Key stash)
        $v.Satisfied | Should -BeFalse
        $v.Refusal | Should -Be 'operator-selection-invalid'
        $v.Services[0].Disposition | Should -Be 'unresolved'
    }

    It 'keeps distinct case-sensitive names separate when applying selections' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -AllowOperatorSelection `
            -RestoreServiceVmName 'yuruna-stash-service' -LeaveStoppedServiceVmName 'Yuruna-Stash-Service' -Evidence @(
                New-EvidenceRow -Key stash -VMName 'yuruna-stash-service'
                New-EvidenceRow -Key other -VMName 'Yuruna-Stash-Service'
            )
        $v.Satisfied | Should -BeTrue
        ($v.Services | Where-Object Key -eq stash).Disposition | Should -Be 'restore-required'
        ($v.Services | Where-Object Key -eq other).Disposition | Should -Be 'leave-stopped'
    }

    It 'accepts a local selection that covers every unknown guest' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -AllowOperatorSelection `
            -RestoreServiceVmName @('yuruna-stash-service') -LeaveStoppedServiceVmName @('yuruna-pool-control-service') -Evidence @(
            New-EvidenceRow -Key 'stash' -State 'Unknown'
            New-EvidenceRow -Key 'pool-control' -State 'Unknown'
            New-EvidenceRow -Key 'caching-proxy' -State 'Stopped' -Reason 'responsive'
        )
        $v.Satisfied | Should -BeTrue
        ($v.Services | Where-Object Key -eq 'stash').Disposition | Should -Be 'restore-required'
        ($v.Services | Where-Object Key -eq 'stash').Evidence | Should -Be 'operator-selection'
        ($v.Services | Where-Object Key -eq 'pool-control').Disposition | Should -Be 'leave-stopped'
        ($v.Services | Where-Object Key -eq 'caching-proxy').Disposition | Should -Be 'leave-stopped' -Because 'a positively stopped guest stays stopped unless selected'
    }

    It 'refuses without a hypervisor probe, on an unreadable census, on a spent deadline, and on an empty roster' {
        $noProbe = [pscustomobject]@{ State = ''; Reason = 'unclassified'; Probed = $false; ElapsedMs = 0 }
        (Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $noProbe -Capability $script:Unqualified `
            -Evidence @(New-EvidenceRow -Key 'stash' -State 'Running')).Refusal | Should -Be 'hypervisor-probe-unavailable'
        (Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -CensusValid $false `
            -Evidence @(New-EvidenceRow -Key 'stash' -State 'Unknown')).Refusal | Should -Be 'census-unavailable'
        (Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified `
            -Evidence @(New-EvidenceRow -Key 'stash' -State 'Unknown' -Reason 'deadline-exhausted')).Refusal | Should -Be 'deadline-exhausted'
        $empty = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence @()
        $empty.Satisfied | Should -BeFalse -Because 'an empty roster is no evidence that nothing needs restoring'
        $empty.Refusal | Should -Be 'service-evidence-incomplete'
    }

    It 'never refuses under the Preserve policy, and ignores selections there' {
        $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Preserve -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified `
            -RestoreServiceVmName @('yuruna-stash-service') -Evidence @(New-EvidenceRow -Key 'stash' -State 'Unknown'; New-EvidenceRow -Key 'pool-control' -State 'Stopped' -Reason 'responsive')
        $v.Satisfied | Should -BeTrue
        $v.Refusal | Should -Be ''
        $v.Preserve | Should -BeTrue
        ($v.Services | Where-Object Key -eq 'stash').Disposition | Should -Be 'unresolved'
    }

    It 'emits typed rows with every contract field for zero, one and many services' {
        foreach ($count in @(0, 1, 3)) {
            $rows = @(for ($i = 0; $i -lt $count; $i++) { New-EvidenceRow -Key "svc$i" -State 'Running' -Reason 'responsive' })
            $v = Resolve-YurunaServiceVmPolicy -UnknownMeans Repair -HostType 'host.test' -Hypervisor $script:Responsive -Capability $script:Unqualified -Evidence $rows
            ,$v.Services | Should -BeOfType [object[]]
            @($v.Services).Count | Should -Be $count
            ,$v.RefusalKeys | Should -BeOfType [string[]]
            foreach ($row in $v.Services) {
                foreach ($field in @('Key', 'VMName', 'DisplayName', 'HealthPort', 'Source', 'VMNameSource', 'HostingMode', 'State', 'RawState', 'Reason',
                        'ServiceAnswered', 'Evidence', 'EvidenceAgeSeconds', 'EvidenceLifetimeSeconds', 'EvidenceOrigin', 'DesiredState', 'IntentGeneration',
                        'IntentResult', 'Preserve', 'Disposition', 'Identity')) {
                    $row.PSObject.Properties.Name | Should -Contain $field
                }
            }
        }
    }
}
