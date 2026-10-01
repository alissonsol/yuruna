<#PSScriptInfo
.VERSION 2026.09.30
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
    The KVM driver's Test-VirtualizationResponsive probe (record schema 1) and
    the bounded Get-VMState precedence: a denied, timed-out, truncated or
    unrecognized answer is 'unknown', never 'absent'; only a completed
    not-found response is 'absent'.
.DESCRIPTION
    Runs against the real local libvirtd wherever this host has one (read-only:
    `virsh list`, `virsh domstate` of a name that does not exist, and
    `systemctl show`), and against scripted `virsh` stand-ins on a private PATH
    entry for every failure shape, so no case can touch the real daemon's
    state. The unit read the socket classification needs is mocked in module
    scope.
#>

BeforeAll {
    $script:NativeCommandStubs = @()
    foreach ($nativeName in @('systemctl', 'virsh')) {
        if (-not (Get-Command $nativeName -ErrorAction SilentlyContinue)) {
            Set-Item -LiteralPath "Function:global:$nativeName" -Value { $global:LASTEXITCODE = 1 }
            $script:NativeCommandStubs += $nativeName
        }
    }

    # Computed here, inside BeforeAll, not as a top-level discovery-time
    # statement and not read through an It block's -Skip parameter: Pester
    # evaluates -Skip during discovery, before any BeforeAll runs, and a
    # plain top-level $script: assignment does not reliably survive from
    # Pester's discovery pass into its separate run pass either.
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # Three drivers share the module name Yuruna.Host; a second resident copy
    # makes -ModuleName mocks land in the wrong one.
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    $script:KvmModule = Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
    Import-Module $script:KvmModule -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.HostCondition.Linux.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'host/Yuruna.Host.Contract.psm1') -Global -DisableNameChecking

    $script:HasRealLibvirt = $false
    if ($IsLinux -and (Get-Command virsh -CommandType Application -ErrorAction SilentlyContinue)) {
        $live = Invoke-BoundedNativeCommand -FilePath 'virsh' -ArgumentList @('--connect', 'qemu:///system', 'list', '--name') -TimeoutSeconds 15
        $script:HasRealLibvirt = ($live.Started -and -not $live.TimedOut -and $live.ExitCode -eq 0)
    }
    $script:LibvirtdLoaded = $false
    if ($IsLinux -and (Get-Command systemctl -CommandType Application -ErrorAction SilentlyContinue)) {
        $show = Invoke-BoundedNativeCommand -FilePath 'systemctl' -ArgumentList @('show', '--no-pager', '-p', 'LoadState', 'libvirtd.service') -TimeoutSeconds 10
        $script:LibvirtdLoaded = ($show.ExitCode -eq 0 -and "$($show.StdOut)" -match 'LoadState=loaded')
    }

    # A throwaway PATH entry with a scripted `virsh` lets every failure shape
    # run regardless of whether this host has a real libvirtd, without ever
    # touching the real one.
    $script:FakeBinDir = Join-Path ([IO.Path]::GetTempPath()) ("yrn-kvmfake-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:FakeBinDir -Force | Out-Null
    $script:MarkerPath = Join-Path $script:FakeBinDir 'invoked'

    function New-FakeVirsh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the suite-owned temp bin dir that AfterAll removes.')]
        param([string]$Body)
        $shim = Join-Path $script:FakeBinDir 'virsh'
        $prologue = "#!/bin/sh`n: > '$($script:MarkerPath)'`n"
        Set-Content -LiteralPath $shim -Value ($prologue + $Body) -NoNewline -Encoding ascii
        & chmod +x $shim
        Remove-Item -LiteralPath $script:MarkerPath -Force -ErrorAction SilentlyContinue
    }

    function Use-FakeVirsh {
        $env:PATH = "$script:FakeBinDir" + [IO.Path]::PathSeparator + $script:OrigPath
    }

    # Stand-ins for the identity tools the group diagnosis reads. They shadow
    # the real `id`/`getent` for everything on the fake PATH, so each test
    # that plants them removes them again (Remove-FakeGroupTool).
    function New-FakeGroupTool {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the suite-owned temp bin dir that AfterAll removes.')]
        param([string]$Name, [string]$Body)
        $shim = Join-Path $script:FakeBinDir $Name
        Set-Content -LiteralPath $shim -Value ("#!/bin/sh`n" + $Body) -NoNewline -Encoding ascii
        & chmod +x $shim
    }

    function Remove-FakeGroupTool {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: removes only stand-ins it planted in the suite-owned temp bin dir.')]
        param()
        foreach ($name in @('id', 'getent')) {
            Remove-Item -LiteralPath (Join-Path $script:FakeBinDir $name) -Force -ErrorAction SilentlyContinue
        }
    }

    $script:KvmEvidenceKey = @('connection', 'localePinned', 'client', 'socket', 'libvirtGroup', 'exitCode', 'drainTimedOut', 'outputTruncated')
    $script:OrigPath = $env:PATH
}

AfterAll {
    foreach ($nativeName in $script:NativeCommandStubs) { Remove-Item -LiteralPath "Function:global:$nativeName" -ErrorAction SilentlyContinue }

    $env:PATH = $script:OrigPath
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
        $r.evidence.socket | Should -Be 'reachable'
        [datetime]$r.observedUtc | Should -Not -BeNullOrEmpty
    }

    It 'Get-VMState reports absent for a name that genuinely does not exist' {
        if (-not $script:HasRealLibvirt) { Set-ItResult -Skipped -Because 'no reachable libvirtd on this host'; return }
        (Get-VMState -VMName ("definitely-absent-" + [Guid]::NewGuid().ToString('n'))) | Should -Be 'absent'
    }

    It 'detects the daemon layout read-only through systemctl show alone' {
        if (-not $script:LibvirtdLoaded) { Set-ItResult -Skipped -Because 'libvirtd.service is not loaded on this host'; return }
        $script:LayoutCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            $script:LayoutCalls.Add(($FilePath + ' ' + ($ArgumentList -join ' ')))
            # Explicit arguments: a mock body does not receive the caller's
            # $PSBoundParameters, and an empty splat would leave the real
            # function to prompt for its mandatory -FilePath.
            Yuruna.Common\Invoke-BoundedNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList `
                -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        }
        $layout = & (Get-Module Yuruna.Host) { Get-KvmDaemonLayout -TimeoutSeconds 10 }
        $layout.Resolved | Should -BeTrue
        $layout.Units['libvirtd.service'].LoadState | Should -Be 'loaded'
        if ($layout.Units['virtqemud.service'].LoadState -eq 'not-found') {
            $layout.Layout | Should -Be 'monolithic' -Because 'libvirtd.service is loaded and no modular daemon unit exists'
        } else {
            $layout.Layout | Should -BeIn @('monolithic', 'modular', 'mixed', 'unknown')
        }
        $script:LayoutCalls.Count | Should -Be 1
        $script:LayoutCalls[0] | Should -Match '^systemctl show --no-pager -p '
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'Test-VirtualizationResponsive -- record shape and connection pin' -Skip:$IsWindows {
    BeforeEach { $script:OrigPath = $env:PATH }
    AfterEach  { $env:PATH = $script:OrigPath }

    It 'returns a schema-1 record carrying every field and every KVM evidence key' {
        New-FakeVirsh "printf 'vm-a\n'`nexit 0"
        Use-FakeVirsh
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.PSObject.TypeNames | Should -Contain 'Yuruna.VirtualizationProbe'
        $r.schemaVersion | Should -Be 1
        $r.hostType | Should -Be 'host.ubuntu.kvm'
        $r.state | Should -Be 'Responsive'
        $r.corroborated | Should -BeFalse
        $r.deadlineExhausted | Should -BeFalse
        $r.observedTick | Should -BeOfType [long]
        foreach ($name in 'state', 'reason', 'started', 'timedOut', 'deadlineExhausted', 'corroborated', 'observedUtc', 'observedTick', 'elapsedMs', 'evidence', 'diagnostic') {
            $r.PSObject.Properties.Name | Should -Contain $name
        }
        foreach ($key in $script:KvmEvidenceKey) { $r.evidence.PSObject.Properties.Name | Should -Contain $key }
        $r.evidence.connection | Should -Be 'qemu:///system'
        $r.evidence.localePinned | Should -BeTrue
        $r.evidence.client | Should -Be 'present'
        $r.evidence.exitCode | Should -Be 0
    }

    It 'talks to qemu:///system with LC_MESSAGES=C and LC_ALL cleared, even when the caller exports LC_ALL' {
        $argvFile = Join-Path $script:FakeBinDir 'argv'
        $envFile  = Join-Path $script:FakeBinDir 'env'
        New-FakeVirsh ("printf '%s\n' `"`$@`" > '$argvFile'`nprintf 'LC_MESSAGES=%s\nLC_ALL=%s\n' `"`$LC_MESSAGES`" `"`$LC_ALL`" > '$envFile'`nexit 0")
        Use-FakeVirsh
        $priorAll = $env:LC_ALL
        try {
            $env:LC_ALL = 'de_DE.UTF-8'
            $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        } finally {
            if ($null -eq $priorAll) { Remove-Item Env:LC_ALL -ErrorAction SilentlyContinue } else { $env:LC_ALL = $priorAll }
        }
        $r.state | Should -Be 'Responsive'
        $argv = @(Get-Content -LiteralPath $argvFile)
        $argv[0] | Should -Be '--connect'
        $argv[1] | Should -Be 'qemu:///system'
        $argv[2] | Should -Be 'list'
        $environment = @(Get-Content -LiteralPath $envFile)
        $environment | Should -Contain 'LC_MESSAGES=C'
        $environment | Should -Contain 'LC_ALL='
    }

    It 'keeps the private diagnostic under 1024 characters with no control or ANSI characters' {
        $long = 'x' * 3000
        New-FakeVirsh ("printf '\033[31merror: something odd\033[0m\n\ttab\r\n$long\n' 1>&2`nexit 1")
        Use-FakeVirsh
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.reason | Should -Be 'provider-error'
        $r.diagnostic.Length | Should -BeLessOrEqual 1024
        $r.diagnostic | Should -Not -Match '[\x00-\x1F\x7F]'
        $r.diagnostic | Should -Match 'error: something odd'
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'Test-VirtualizationResponsive -- classification (fake virsh)' -Skip:$IsWindows {
    BeforeEach { $script:OrigPath = $env:PATH }
    AfterEach  { $env:PATH = $script:OrigPath }

    It 'reports missing-client, not a false Responsive or a hang, when virsh is not on PATH' {
        $env:PATH = '/nonexistent-yrn-test-path'
        $r = Test-VirtualizationResponsive
        $r.state    | Should -Be 'Undetermined'
        $r.reason   | Should -Be 'missing-client'
        $r.started  | Should -Be $false
        $r.evidence.client | Should -Be 'missing'
    }

    It 'classifies <Wording> as Undetermined/permission-denied, never Responsive or Unresponsive' -ForEach @(
        @{ Wording = 'authentication unavailable (polkit)'; Line = "error: authentication unavailable: no polkit agent available to authenticate action 'org.libvirt.unix.manage'" }
        @{ Wording = 'socket Permission denied'; Line = "error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied" }
        @{ Wording = 'authentication failed'; Line = 'error: authentication failed: access denied by policy' }
        @{ Wording = 'access denied'; Line = "error: access denied: 'connect' denied" }
        @{ Wording = 'not authorized'; Line = 'error: operation not authorized for this user' }
    ) {
        New-FakeVirsh ("echo `"$Line`" 1>&2`nexit 1")
        Use-FakeVirsh
        Mock -ModuleName Yuruna.Host Get-KvmLibvirtGroupEvidence { 'active' }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.state  | Should -Be 'Undetermined'
        $r.reason | Should -Be 'permission-denied'
        $r.evidence.socket | Should -Be 'denied'
    }

    It 'reports the libvirt group standing <Expected> on a permission-denied probe' -ForEach @(
        @{ Expected = 'stale-session'; State = @{ ActiveGroups = @('ytest', 'sudo'); LibvirtMembers = @('alice', 'ytest'); CurrentUser = 'ytest'; Resolved = $true } }
        @{ Expected = 'not-member'; State = @{ ActiveGroups = @('ytest'); LibvirtMembers = @('alice'); CurrentUser = 'ytest'; Resolved = $true } }
        @{ Expected = 'active'; State = @{ ActiveGroups = @('ytest', 'libvirt'); LibvirtMembers = @('ytest'); CurrentUser = 'ytest'; Resolved = $true } }
        @{ Expected = 'unknown'; State = @{ ActiveGroups = @(); LibvirtMembers = @(); CurrentUser = ''; Resolved = $false } }
    ) {
        New-FakeVirsh "echo `"error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied`" 1>&2`nexit 1"
        Use-FakeVirsh
        $script:GroupState = $State
        Mock -ModuleName Yuruna.Host Get-LibvirtGroupState { $script:GroupState }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.reason | Should -Be 'permission-denied'
        $r.evidence.libvirtGroup | Should -Be $Expected
        Should -Invoke -ModuleName Yuruna.Host Get-LibvirtGroupState -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 5 }
    }

    It 'stays inside its own cap when the group reads behind a denied answer never finish (<Bound>)' -ForEach @(
        @{ Bound = 'TimeoutSeconds'; UseDeadline = $false }
        @{ Bound = 'shared deadline'; UseDeadline = $true }
    ) {
        New-FakeVirsh "echo `"error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied`" 1>&2`nexit 1"
        New-FakeGroupTool -Name 'id' -Body 'exec sleep 30'
        New-FakeGroupTool -Name 'getent' -Body 'exec sleep 30'
        Use-FakeVirsh
        try {
            $deadline = $null
            $sw = [Diagnostics.Stopwatch]::StartNew()
            if ($UseDeadline) {
                $deadline = New-YurunaDeadline -TotalMilliseconds 4000
                $r = Test-VirtualizationResponsive -TimeoutSeconds 60 -Deadline $deadline
            } else {
                $r = Test-VirtualizationResponsive -TimeoutSeconds 4
            }
            $sw.Stop()
        } finally {
            Remove-FakeGroupTool
        }
        $r.reason | Should -Be 'permission-denied'
        $r.evidence.libvirtGroup | Should -Be 'unknown'
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
        if ($deadline) { Get-YurunaDeadlineRemainingMs -Deadline $deadline | Should -BeGreaterThan 0 }
    }

    It 'reads a libvirt group that does not exist as not-member, not unknown' {
        New-FakeVirsh "echo `"error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Permission denied`" 1>&2`nexit 1"
        New-FakeGroupTool -Name 'id' -Body "case `"`$1`" in -nG) echo 'ytest sudo' ;; -un) echo 'ytest' ;; *) exit 1 ;; esac"
        New-FakeGroupTool -Name 'getent' -Body 'exit 2'
        Use-FakeVirsh
        try {
            $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        } finally {
            Remove-FakeGroupTool
        }
        $r.reason | Should -Be 'permission-denied'
        $r.evidence.libvirtGroup | Should -Be 'not-member'
    }

    It 'reads a missing control socket with stopped daemon units as Unresponsive/app-stopped (<Cause>)' -ForEach @(
        @{ Cause = 'No such file or directory'; Socket = 'absent' }
        @{ Cause = 'Connection refused'; Socket = 'refused' }
    ) {
        New-FakeVirsh ("echo `"error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': $Cause`" 1>&2`nexit 1")
        Use-FakeVirsh
        Mock -ModuleName Yuruna.Host Get-KvmDaemonLayout {
            [pscustomobject]@{ Layout = 'monolithic'; Resolved = $true; Reason = 'ok'; Units = @{
                'libvirtd.service' = [pscustomobject]@{ LoadState = 'loaded'; ActiveState = 'inactive'; SubState = 'dead'; UnitFileState = 'enabled' }
                'libvirtd.socket'  = [pscustomobject]@{ LoadState = 'loaded'; ActiveState = 'inactive'; SubState = 'dead'; UnitFileState = 'enabled' } } }
        }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.state | Should -Be 'Unresponsive'
        $r.reason | Should -Be 'app-stopped'
        $r.evidence.socket | Should -Be $Socket
        $r.timedOut | Should -BeFalse
    }

    It 'never reads a missing socket as app-stopped while systemd reports the socket unit <Detail>' -ForEach @(
        @{ Detail = 'active'; Resolved = $true; SocketState = 'active' }
        @{ Detail = 'unreadable'; Resolved = $false; SocketState = 'inactive' }
    ) {
        New-FakeVirsh "echo `"error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': Connection refused`" 1>&2`nexit 1"
        Use-FakeVirsh
        $script:LayoutResolved = $Resolved
        $script:SocketActiveState = $SocketState
        Mock -ModuleName Yuruna.Host Get-KvmDaemonLayout {
            [pscustomobject]@{ Layout = ($script:LayoutResolved ? 'monolithic' : 'unknown'); Resolved = $script:LayoutResolved; Reason = 'ok'; Units = @{
                'libvirtd.service' = [pscustomobject]@{ LoadState = 'loaded'; ActiveState = 'inactive'; SubState = 'dead'; UnitFileState = 'enabled' }
                'libvirtd.socket'  = [pscustomobject]@{ LoadState = 'loaded'; ActiveState = $script:SocketActiveState; SubState = 'listening'; UnitFileState = 'enabled' } } }
        }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.state | Should -Be 'Undetermined'
        $r.reason | Should -Be 'provider-error'
    }

    It 'classifies an unrecognized nonzero exit as Undetermined/provider-error' {
        New-FakeVirsh "echo 'error: internal error: something unexpected happened' 1>&2`nexit 1"
        Use-FakeVirsh
        $r = Test-VirtualizationResponsive -TimeoutSeconds 10
        $r.state  | Should -Be 'Undetermined'
        $r.reason | Should -Be 'provider-error'
        $r.evidence.exitCode | Should -Be 1
    }

    It 'reports timeout, not a hang or a false Responsive, when virsh never answers' {
        New-FakeVirsh 'sleep 30'
        Use-FakeVirsh
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 2
        $sw.Stop()
        $r.state    | Should -Be 'Unresponsive'
        $r.reason   | Should -Be 'timeout'
        $r.timedOut | Should -Be $true
        $r.started  | Should -Be $true
        $sw.ElapsedMilliseconds | Should -BeLessThan 6000 -Because 'a wedged control channel must be reported in seconds, not left to the caller''s watchdog'
    }

    It 'never proves success from output a descendant kept open (exit 0, undrained)' {
        New-FakeVirsh "(sleep 8 &)`nexit 0"
        Use-FakeVirsh
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 2
        $sw.Stop()
        $r.state  | Should -Be 'Undetermined'
        $r.reason | Should -Be 'invalid-response'
        $r.evidence.drainTimedOut | Should -BeTrue
        $sw.ElapsedMilliseconds | Should -BeLessThan 6000
    }

    It 'launches nothing and reports deadline-exhausted when the shared deadline has no second left' {
        New-FakeVirsh 'exit 0'
        Use-FakeVirsh
        $r = Test-VirtualizationResponsive -Deadline (New-YurunaDeadline -TotalMilliseconds 500)
        $r.state | Should -Be 'Undetermined'
        $r.reason | Should -Be 'deadline-exhausted'
        $r.deadlineExhausted | Should -BeTrue
        $r.started | Should -BeFalse
        Test-Path -LiteralPath $script:MarkerPath | Should -BeFalse -Because 'a probe with no usable time left must not launch virsh at all'
    }

    It 'never throws: an internal fault becomes Undetermined/provider-error' {
        New-FakeVirsh 'exit 0'
        Use-FakeVirsh
        Mock -ModuleName Yuruna.Host Invoke-VirshBounded { throw 'probe plumbing exploded' }
        $r = Test-VirtualizationResponsive -TimeoutSeconds 5
        $r.state | Should -Be 'Undetermined'
        $r.reason | Should -Be 'provider-error'
        $r.diagnostic | Should -Match 'probe plumbing exploded'
    }

    It 'lets a short shared deadline cap a larger TimeoutSeconds' {
        New-FakeVirsh 'sleep 30'
        Use-FakeVirsh
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-VirtualizationResponsive -TimeoutSeconds 60 -Deadline (New-YurunaDeadline -TotalMilliseconds 2500)
        $sw.Stop()
        $r.reason | Should -Be 'timeout'
        $sw.ElapsedMilliseconds | Should -BeLessThan 7000
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'Get-VMState -- bounded, unknown before absent (fake virsh)' -Skip:$IsWindows {
    BeforeEach { $script:OrigPath = $env:PATH }
    AfterEach  { $env:PATH = $script:OrigPath }

    It 'reads a denied probe as unknown, never absent' {
        New-FakeVirsh "echo 'error: authentication unavailable: could not connect to any' 1>&2`nexit 1"
        Use-FakeVirsh
        (Get-VMState -VMName 'irrelevant') | Should -Be 'unknown' `
            -Because 'callers treat absent as permission to build or reuse a name, so a denied read must never produce it'
    }

    It 'reads a failed hypervisor connection as unknown' {
        New-FakeVirsh "echo 'error: failed to connect to the hypervisor' 1>&2`nexit 1"
        Use-FakeVirsh
        (Get-VMState -VMName 'irrelevant') | Should -Be 'unknown'
    }

    It 'still reads a completed, recognized not-found response as absent' {
        New-FakeVirsh "echo `"error: failed to get domain 'ghost-vm'`" 1>&2`nexit 1"
        Use-FakeVirsh
        (Get-VMState -VMName 'ghost-vm') | Should -Be 'absent'
    }

    It 'maps <Raw> to <Expected>' -ForEach @(
        @{ Raw = 'running'; Expected = 'running' }
        @{ Raw = 'shut off'; Expected = 'stopped' }
        @{ Raw = 'paused'; Expected = 'stopped' }
        @{ Raw = 'crashed'; Expected = 'stopped' }
        @{ Raw = 'some new state'; Expected = 'unknown' }
    ) {
        New-FakeVirsh "printf '$Raw\n\n'`nexit 0"
        Use-FakeVirsh
        (Get-VMState -VMName 'vm-a') | Should -Be $Expected
    }

    It 'reads empty exit-0 output as unknown' {
        New-FakeVirsh 'exit 0'
        Use-FakeVirsh
        (Get-VMState -VMName 'vm-a') | Should -Be 'unknown'
    }

    It 'reads a missing virsh as unknown' {
        $env:PATH = '/nonexistent-yrn-test-path'
        (Get-VMState -VMName 'vm-a') | Should -Be 'unknown'
    }

    It 'answers unknown within its own cap when libvirtd never answers' {
        New-FakeVirsh 'sleep 30'
        Use-FakeVirsh
        $module = Get-Module Yuruna.Host
        $prior = & $module { $script:VirshQueryTimeoutSeconds }
        & $module { $script:VirshQueryTimeoutSeconds = 2 }
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $state = Get-VMState -VMName 'vm-a'
            $sw.Stop()
        } finally {
            & $module { param($Value) $script:VirshQueryTimeoutSeconds = $Value } $prior
        }
        $state | Should -Be 'unknown'
        $sw.ElapsedMilliseconds | Should -BeLessThan 6000
    }

    It 'reports the reason behind each answer' {
        New-FakeVirsh "echo `"error: failed to get domain 'ghost-vm'`" 1>&2`nexit 1"
        Use-FakeVirsh
        $read = & (Get-Module Yuruna.Host) { Get-KvmDomainState -VMName 'ghost-vm' -TimeoutSeconds 5 }
        $read.State | Should -Be 'absent'
        $read.Reason | Should -Be 'not-found'
        New-FakeVirsh "printf 'shut off\n'`nexit 0"
        $read = & (Get-Module Yuruna.Host) { Get-KvmDomainState -VMName 'vm-a' -TimeoutSeconds 5 }
        $read.State | Should -Be 'stopped'
        $read.Raw | Should -Be 'shut off'
        $read.Reason | Should -Be 'observed'
    }
}

Describe 'KVM driver contract surface' {
    It 'exports every contract verb, including the rung-2 start verb' {
        $module = Get-Module Yuruna.Host
        $exported = @($module.ExportedFunctions.Keys)
        $exported | Should -Contain 'Test-VirtualizationResponsive'
        $exported | Should -Contain 'Start-VirtualizationServiceIfStopped'
        Assert-YurunaHostContractCoverage -HostType 'ubuntu.kvm' -Module $module -ExportedFunction $exported -WarningAction SilentlyContinue |
            Should -BeTrue
    }

    It 'keeps the probe read-only and bounded: no ShouldProcess, and a -Deadline parameter' {
        $command = Get-Command -Name Test-VirtualizationResponsive -Module Yuruna.Host
        $command.Parameters.Keys | Should -Contain 'Deadline'
        $command.Parameters.Keys | Should -Not -Contain 'WhatIf'
    }
}

Describe 'Get-LibvirtGroupState -- bounded group reads' {
    BeforeEach {
        # An injected clock makes the shared budget deterministic: each fake
        # read advances it by the time that read would have taken.
        $script:FakeNow = [long]1000000
        $script:GroupCalls = [System.Collections.Generic.List[object]]::new()
        $script:GroupAnswer = @{
            'id -nG'               = @{ ExitCode = 0; StdOut = "ytest sudo users`n" }
            'id -un'               = @{ ExitCode = 0; StdOut = "ytest`n" }
            'getent group libvirt' = @{ ExitCode = 0; StdOut = "libvirt:x:973:alice,ytest`n" }
        }
        Mock -ModuleName Test.HostCondition.Linux New-YurunaDeadline {
            New-YurunaDeadlineFromExpiry -ExpiryTick ($script:FakeNow + $TotalMilliseconds) -ClockTicks { $script:FakeNow }
        }
        Mock -ModuleName Test.HostCondition.Linux Invoke-BoundedNativeCommand {
            $line = ($FilePath + ' ' + ($ArgumentList -join ' '))
            $script:GroupCalls.Add([pscustomobject]@{
                Line = $line; TimeoutSeconds = $TimeoutSeconds; StartTick = $script:FakeNow
                ExpiryTick = $(if ($Deadline) { [long]$Deadline.ExpiryTick } else { $null })
            })
            $answer = $script:GroupAnswer[$line]
            if ($answer -eq 'timeout') {
                $script:FakeNow += [long]$TimeoutSeconds * 1000
                return @{ ExitCode = 124; StdOut = ''; StdErr = ''; TimedOut = $true; Started = $true; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = [long]$TimeoutSeconds * 1000 }
            }
            $script:FakeNow += 20
            return @{ ExitCode = $answer.ExitCode; StdOut = $answer.StdOut; StdErr = ''; TimedOut = $false; Started = $true
                DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 20 }
        }
    }

    It 'reads groups, user and libvirt members through three calls that share one budget' {
        $state = Get-LibvirtGroupState -TimeoutSeconds 3
        $state.Resolved | Should -BeTrue
        $state.CurrentUser | Should -Be 'ytest'
        @($state.ActiveGroups) | Should -Be @('ytest', 'sudo', 'users')
        @($state.LibvirtMembers) | Should -Be @('alice', 'ytest')
        $script:GroupCalls.Count | Should -Be 3
        @($script:GroupCalls.ExpiryTick | Select-Object -Unique) | Should -Be @([long]1003000)
        foreach ($call in $script:GroupCalls) {
            $call.TimeoutSeconds | Should -BeGreaterOrEqual 1
            ([long]$call.TimeoutSeconds * 1000) | Should -BeLessOrEqual ($call.ExpiryTick - $call.StartTick) `
                -Because 'each read may use only what is left of the one budget, never a fresh allowance of its own'
        }
    }

    It 'skips the remaining reads once the budget is spent, and clears Resolved' {
        $script:GroupAnswer['id -nG'] = 'timeout'
        $state = Get-LibvirtGroupState -TimeoutSeconds 3
        $script:GroupCalls.Count | Should -Be 1
        $state.Resolved | Should -BeFalse
        $state.CurrentUser | Should -Be ''
        $state.ActiveGroups -is [object[]] | Should -BeTrue
        @($state.ActiveGroups).Count | Should -Be 0
        $state.LibvirtMembers -is [object[]] | Should -BeTrue
    }

    It 'clears Resolved and leaves the value empty when a read times out' {
        $script:GroupAnswer['getent group libvirt'] = 'timeout'
        $state = Get-LibvirtGroupState -TimeoutSeconds 2
        $state.Resolved | Should -BeFalse
        @($state.LibvirtMembers).Count | Should -Be 0
        $state.CurrentUser | Should -Be 'ytest'
    }

    It 'clears Resolved when a read fails' {
        $script:GroupAnswer['id -un'] = @{ ExitCode = 1; StdOut = '' }
        $state = Get-LibvirtGroupState
        $state.Resolved | Should -BeFalse
        $state.CurrentUser | Should -Be ''
    }

    It 'keeps ActiveGroups and LibvirtMembers arrays when each holds one entry' {
        $script:GroupAnswer['id -nG'] = @{ ExitCode = 0; StdOut = "ytest`n" }
        $script:GroupAnswer['getent group libvirt'] = @{ ExitCode = 0; StdOut = "libvirt:x:973:ytest`n" }
        $state = Get-LibvirtGroupState
        $state.ActiveGroups -is [object[]] | Should -BeTrue
        $state.ActiveGroups.Count | Should -Be 1
        $state.LibvirtMembers -is [object[]] | Should -BeTrue
        $state.LibvirtMembers.Count | Should -Be 1
    }

    It 'reads a libvirt group that does not exist (getent exit 2) as a complete answer with no members' {
        $script:GroupAnswer['getent group libvirt'] = @{ ExitCode = 2; StdOut = '' }
        $state = Get-LibvirtGroupState
        $state.Resolved | Should -BeTrue
        $state.LibvirtMembers -is [object[]] | Should -BeTrue
        $state.LibvirtMembers.Count | Should -Be 0
    }

    It 'still clears Resolved for a getent failure other than a missing key' {
        $script:GroupAnswer['getent group libvirt'] = @{ ExitCode = 1; StdOut = '' }
        (Get-LibvirtGroupState).Resolved | Should -BeFalse
    }
}

Describe 'Assert-LinuxHostConditionSet -- diagnosis under socket activation' {
    BeforeAll {
        if (-not (Get-Command -Name 'Write-HostClockDriftWarning' -ErrorAction SilentlyContinue)) {
            function global:Write-HostClockDriftWarning {
                <# .SYNOPSIS
                    Stand-in for the host-condition facade's clock warning. #>
                [CmdletBinding()] param([string]$HostType) Write-Verbose "clock drift check skipped for $HostType"
            }
            $script:ClockStub = $true
        }
    }
    AfterAll {
        if ($script:ClockStub) { Remove-Item -Path 'Function:\Write-HostClockDriftWarning' -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        $script:ConditionKeys = [System.Collections.Generic.List[string]]::new()
        $script:SocketState = 'active'
        Mock -ModuleName Test.HostCondition.Linux Write-HostClockDriftWarning { }
        Mock -ModuleName Test.HostCondition.Linux Assert-Virtualization { $false }
        Mock -ModuleName Test.HostCondition.Linux Test-Path { $true } -ParameterFilter { $LiteralPath -eq '/dev/kvm' }
        Mock -ModuleName Test.HostCondition.Linux systemctl {
            $unit = @($args)[1]
            if ($unit -eq 'libvirtd') { $global:LASTEXITCODE = 3; 'inactive' }
            else { $global:LASTEXITCODE = 0; $script:SocketState }
        }
        Mock -ModuleName Test.HostCondition.Linux Get-LibvirtGroupState {
            @{ ActiveGroups = @('ytest'); LibvirtMembers = @('ytest'); CurrentUser = 'ytest'; Resolved = $true }
        }
        Mock -ModuleName Test.HostCondition.Linux Format-YurunaOperatorMessage { $script:ConditionKeys.Add($Key); $Key }
    }

    It 'diagnoses the stale group session, not the daemon, when libvirtd idles behind its socket' {
        Assert-LinuxHostConditionSet -HostType 'host.ubuntu.kvm' -ErrorAction SilentlyContinue | Should -BeFalse
        $script:ConditionKeys | Should -Contain 'runner.operator_6086c8f7e49eae24'
        $script:ConditionKeys | Should -Not -Contain 'runner.operator_5bd775f79ee13443'
    }

    It 'gives the generic diagnosis, not "not a member", when the group reads did not finish' {
        Mock -ModuleName Test.HostCondition.Linux Get-LibvirtGroupState {
            @{ ActiveGroups = @(); LibvirtMembers = @(); CurrentUser = ''; Resolved = $false }
        }
        Assert-LinuxHostConditionSet -HostType 'host.ubuntu.kvm' -ErrorAction SilentlyContinue | Should -BeFalse
        $script:ConditionKeys | Should -Contain 'runner.operator_71200c53c662e070'
        $script:ConditionKeys | Should -Not -Contain 'runner.operator_af9331d7fcad1b25'
        $script:ConditionKeys | Should -Not -Contain 'runner.operator_6086c8f7e49eae24'
    }

    It 'still reports "not a member" from a completed read' {
        Mock -ModuleName Test.HostCondition.Linux Get-LibvirtGroupState {
            @{ ActiveGroups = @('ytest'); LibvirtMembers = @(); CurrentUser = 'ytest'; Resolved = $true }
        }
        Assert-LinuxHostConditionSet -HostType 'host.ubuntu.kvm' -ErrorAction SilentlyContinue | Should -BeFalse
        $script:ConditionKeys | Should -Contain 'runner.operator_af9331d7fcad1b25'
    }

    It 'still blames the daemon when neither libvirtd nor its socket runs' {
        $script:SocketState = 'inactive'
        Assert-LinuxHostConditionSet -HostType 'host.ubuntu.kvm' -ErrorAction SilentlyContinue | Should -BeFalse
        $script:ConditionKeys | Should -Contain 'runner.operator_5bd775f79ee13443'
    }
}
