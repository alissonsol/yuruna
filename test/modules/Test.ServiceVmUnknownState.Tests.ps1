<#PSScriptInfo
.VERSION 2026.09.30
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
    Restore-YurunaServiceVM against a stand-in host driver: unknown states,
    probe reasons, stop intents, operation locks, captured identities, the
    shared deadline and the -ObserveOnly convergence check.
.DESCRIPTION
    Separate file from Test.ServiceVm.Tests.ps1 on purpose: those cases
    depend on NO Get-VMState/Start-VM being resolvable at all (the
    no-host-driver path), and this file defines fake ones globally for its
    own cases -- keeping them apart means neither suite can leak state into
    the other through Pester's shared per-file runspace.

    Every case uses a private state root and runtime directory, an injected
    clock that only moves when the injected sleeper is called, and fake
    driver verbs that record their calls; nothing reaches a real hypervisor,
    the operator's private root or a real service.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.ServiceCensus.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -DisableNameChecking -Global

    # Minimal fakes standing in for a per-host driver, resolved by
    # Restore-YurunaServiceVM via Get-Command exactly as a real one would be.
    $script:Fake = @{
        State      = @{}
        Ip         = @{}
        StateCalls = [System.Collections.Generic.List[string]]::new()
        StartCalls = [System.Collections.Generic.List[string]]::new()
        IpCalls    = [System.Collections.Generic.List[string]]::new()
        ProbeCalls = 0
        Probe      = $null
        StartSets  = 'running'
    }
    function global:Get-VMState {
        param([string]$VMName)
        $script:Fake.StateCalls.Add($VMName)
        if ($script:Fake.State.ContainsKey($VMName)) { return $script:Fake.State[$VMName] }
        return 'absent'
    }
    function global:Start-VM {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Fake driver signature matches the real Start-VM contract; -Confirm is accepted and ignored, same as the fake never mutating anything real.')]
        [CmdletBinding(SupportsShouldProcess)]
        [OutputType([hashtable])]
        param([string]$VMName)
        if (-not $PSCmdlet.ShouldProcess($VMName, 'Fake start')) { return @{ success = $false; errorMessage = 'WhatIf' } }
        $script:Fake.StartCalls.Add($VMName)
        if ($script:Fake.StartSets) { $script:Fake.State[$VMName] = $script:Fake.StartSets }
        return @{ success = $true; errorMessage = $null }
    }
    function global:Get-VMIp {
        param([string]$VMName)
        $script:Fake.IpCalls.Add($VMName)
        if ($script:Fake.Ip.ContainsKey($VMName)) { return $script:Fake.Ip[$VMName] }
        return ''
    }
    function global:Test-VirtualizationResponsive {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Fake probe signature matches the driver contract; the bound values are not needed to answer.')]
        param([int]$TimeoutSeconds = 20, $Deadline)
        $script:Fake.ProbeCalls++
        if ($script:Fake.Probe) { return $script:Fake.Probe }
        return [pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 5 }
    }

    function New-FakeClock {
        # A clock that only moves when the injected sleeper is called, so a
        # bounded wait is measured in simulated milliseconds, not real ones.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory clock only.')]
        [CmdletBinding()]
        param()
        $box = @{ Now = [long]5000000; Slept = [long]0; Sleeps = 0; OnSleep = $null }
        [pscustomobject]@{
            Box   = $box
            Clock = { $box.Now }.GetNewClosure()
            Sleep = {
                param([int]$Milliseconds)
                $box.Now += $Milliseconds
                $box.Slept += $Milliseconds
                $box.Sleeps++
                if ($box.OnSleep) { & $box.OnSleep $box.Sleeps }
            }.GetNewClosure()
        }
    }

    function New-PrivateRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture: builds private state under TestDrive only.')]
        [CmdletBinding()]
        param()
        $root = Join-Path $TestDrive ('root-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $root -Force
        $runtime = Join-Path $root 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        [pscustomobject]@{ StateRoot = $root; RuntimeDir = $runtime }
    }

    function Get-FreeLoopbackPort {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
    }

    function Test-LoopbackAddressReachable {
        # Linux and Windows answer for all of 127.0.0.0/8; macOS configures only
        # 127.0.0.1 on lo0, so a guest address such as 127.0.0.2 never connects.
        param([Parameter(Mandatory)][string]$Address)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 0)
        $listener.Start()
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            try { return ($client.ConnectAsync($Address, ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port).Wait(2000) -and $client.Connected) }
            catch { return $false }
            finally { $client.Dispose() }
        } finally { $listener.Stop() }
    }
}

AfterAll {
    foreach ($name in @('Get-VMState', 'Start-VM', 'Get-VMIp', 'Test-VirtualizationResponsive', 'Get-VMStateRecord',
            'Get-HostType', 'Get-VMPassiveAddressContext', 'Get-VMPassiveAddress')) {
        Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Restore-YurunaServiceVM -- unknown state never authorizes a start' {
    BeforeEach {
        $script:Fake.State = @{}
        $script:Fake.Ip = @{}
        $script:Fake.Probe = $null
        $script:Fake.ProbeCalls = 0
        $script:Fake.StartSets = 'running'
        $script:Fake.StateCalls.Clear()
        $script:Fake.StartCalls.Clear()
        Remove-Item -Path 'Function:\Get-VMStateRecord' -Force -ErrorAction SilentlyContinue
        $script:Env = New-PrivateRoot
        $script:Time = New-FakeClock
    }

    It 'reports state-unknown, and never calls Start-VM, for a service whose probe could not be confirmed' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:Fake.State[$svc.VMName] = 'unknown'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'state-unknown'
        $r[0].Healthy | Should -Be $false
        $r[0].Obligation | Should -Be 'state-unresolved'
        $script:Fake.StartCalls.Count | Should -Be 0 -Because 'a denied or timed-out probe must never be treated as registered-and-stopped'
    }

    It 'still starts a genuinely stopped VM normally' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:Fake.State[$svc.VMName] = 'stopped'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -HealthTimeoutSeconds 0 -StateRoot $script:Env.StateRoot `
                -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'started'
        $r[0].ProbeReason | Should -Be 'responsive'
        $script:Fake.StartCalls | Should -Contain $svc.VMName
    }

    It 'leaves a running service alone' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:Fake.State[$svc.VMName] = 'running'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'running'
        $r[0].ProbeReason | Should -Be 'responsive'
        $r[0].HypervisorState | Should -Be 'Responsive'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'carries the <Reason> probe reason on every row and reads no VM state when the hypervisor is <State>' -TestCases @(
        @{ State = 'Unresponsive'; Reason = 'timeout' }
        @{ State = 'Undetermined'; Reason = 'permission-denied' }
        @{ State = 'Undetermined'; Reason = 'missing-client' }
    ) {
        param($State, $Reason)
        $script:Fake.Probe = [pscustomobject]@{ state = $State; reason = $Reason; elapsedMs = 20000 }
        foreach ($svc in @(Get-YurunaServiceVmRoster)) { $script:Fake.State[$svc.VMName] = 'stopped' }

        $r = @(Restore-YurunaServiceVM -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r.Count | Should -Be @(Get-YurunaServiceVmRoster).Count
        foreach ($row in $r) {
            $row.Outcome | Should -Be 'state-unknown'
            $row.ProbeReason | Should -Be $Reason
            $row.HypervisorState | Should -Be $State
        }
        $script:Fake.StateCalls.Count | Should -Be 0 -Because 'a wedged or denied control channel is not asked once per service'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'honors a denial on the per-VM record even after a green hypervisor probe' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        function global:Get-VMStateRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Fake record signature matches the driver; the bound values are not needed to answer.')]
            param([string]$VMName, $Deadline, [int]$TimeoutSeconds = 20)
            [pscustomobject]@{ VMName = $VMName; State = 'unknown'; RawState = ''; Registration = 'Unknown'; Reason = 'permission-denied'; ExitCode = 0; ElapsedMs = 3 }
        }
        try {
            $r = @(Restore-YurunaServiceVM -Key $svc.Key -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $r[0].Outcome | Should -Be 'state-unknown'
            $r[0].ProbeReason | Should -Be 'permission-denied'
            $r[0].HypervisorState | Should -Be 'Responsive'
            $script:Fake.StartCalls.Count | Should -Be 0
        } finally {
            Remove-Item -Path 'Function:\Get-VMStateRecord' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not start a service whose newest intent is an explicit stop' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName $svc.VMName -Operation Stop -Script 'fixture' -StateRoot $script:Env.StateRoot -Confirm:$false
        $op.Proceed | Should -BeTrue
        $null = Exit-YurunaServiceOperation -Context $op -Result failed -FinalState 'stopped' -Confirm:$false
        $script:Fake.State[$svc.VMName] = 'stopped'

        $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'intended-stopped'
        $r[0].DesiredState | Should -Be 'stopped'
        $r[0].IntentGeneration | Should -Be $op.Generation
        $script:Fake.StartCalls.Count | Should -Be 0 -Because 'a failed stop is still a request to stay down'
    }

    It 'reports operation-busy, and starts nothing, while the service lock is held' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $held = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
        $held.Held | Should -BeTrue
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $r[0].Outcome | Should -Be 'operation-busy'
            $script:Fake.StartCalls.Count | Should -Be 0
        } finally {
            Exit-YurunaServiceOperationLockSet -Context $held
        }
    }

    It 'reports lock-unavailable, not operation-busy, and starts nothing, when the lock file cannot be opened' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        # A directory where the lock file belongs cannot be opened as one:
        # no other operation holds anything.
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Env.StateRoot 'service-operation.stash.lock') -Force
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'lock-unavailable'
        $r[0].Obligation | Should -Be 'state-unresolved'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'proceeds unserialized only when no private root exists, never from one it cannot trust' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $missing = Join-Path $TestDrive ('no-root-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $r = @(Restore-YurunaServiceVM -Key 'stash' -HealthTimeoutSeconds 0 -StateRoot $missing -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Outcome | Should -Be 'started' -Because 'without any root no stop can have been recorded, and the sweep must still self-heal'
        Test-Path -LiteralPath $missing | Should -BeFalse -Because 'the sweep creates no root'
        if ($IsWindows) { Set-ItResult -Skipped -Because 'creating a directory link needs a privilege the suite does not assume on Windows'; return }
        $script:Fake.State[$svc.VMName] = 'stopped'
        $script:Fake.StartCalls.Clear()
        $link = Join-Path $TestDrive ('linked-root-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $script:Env.StateRoot
        $untrusted = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $link -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $untrusted[0].Outcome | Should -Be 'lock-unavailable' -Because 'a root that exists but cannot be used may hold a stop request'
        $untrusted[0].Obligation | Should -Be 'state-unresolved'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'starts nothing when the census cannot be read under the lock' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $record = Join-Path $script:Env.StateRoot 'service-census.record'
        foreach ($damage in @('file', 'directory')) {
            $script:Fake.State[$svc.VMName] = 'stopped'
            $script:Fake.StartCalls.Clear()
            Remove-Item -LiteralPath $record -Recurse -Force -ErrorAction SilentlyContinue
            if ($damage -eq 'file') { [System.IO.File]::WriteAllText($record, "not a record`n") } else { $null = New-Item -ItemType Directory -Path $record -Force }
            $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $r[0].Outcome | Should -Be 'state-unknown' -Because "a $damage in place of the census may hide a stop request"
            $r[0].Obligation | Should -Be 'state-unresolved'
            $script:Fake.StartCalls.Count | Should -Be 0
        }
    }

    It 'names the stop, not the pending start, when a pending start leaves a stop in force' {
        Mock -ModuleName Test.ServiceVm Format-YurunaOperatorMessage { "$Key|$(if ($Arguments) { $Arguments['operation'] })" }
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $stop = Enter-YurunaServiceOperation -Key 'stash' -VMName $svc.VMName -Operation Stop -Script 'fixture' -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $stop -Result confirmed -FinalState 'absent' -Confirm:$false
        # A start that has not finished: its intent stays pending, and the
        # stop's desired state stays in force until it is confirmed.
        $start = Enter-YurunaServiceOperation -Key 'stash' -VMName $svc.VMName -Operation Start -Script 'fixture' -StateRoot $script:Env.StateRoot -Confirm:$false
        Exit-YurunaServiceOperationLockSet -Context $start.LockSet
        $script:Fake.State[$svc.VMName] = 'stopped'
        # Evidence read before either request was recorded.
        $before = Read-YurunaServiceCensus -StateRoot (New-PrivateRoot).StateRoot
        $r = @(Restore-YurunaServiceVM -Key 'stash' -Census $before -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'intended-stopped'
        $r[0].Message | Should -Be 'runner.service_restore_intended_stopped|stop'
        $r[0].IntentGeneration | Should -Be $start.Generation
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'starts under a caller''s lock set that covers the key, and refuses one that does not' {
        $stash = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$stash.VMName] = 'stopped'
        $covering = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
        try {
            $ok = @(Restore-YurunaServiceVM -Key 'stash' -OperationLock $covering -HealthTimeoutSeconds 0 -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
            $ok[0].Outcome | Should -Be 'started'
        } finally { Exit-YurunaServiceOperationLockSet -Context $covering }

        $script:Fake.State[$stash.VMName] = 'stopped'
        $script:Fake.StartCalls.Clear()
        $other = Enter-YurunaServiceOperationLockSet -Key @('pool-control') -StateRoot $script:Env.StateRoot -Confirm:$false
        try {
            $refused = @(Restore-YurunaServiceVM -Key 'stash' -OperationLock $other -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $refused[0].Outcome | Should -Be 'operation-unowned'
            $script:Fake.StartCalls.Count | Should -Be 0
        } finally { Exit-YurunaServiceOperationLockSet -Context $other }
    }

    It 'drives a captured custom VM name, never the default for its key' {
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'custom-stash-7'; DisplayName = 'Stash service'; HealthPort = 80; HostingMode = 'vm' })
        $script:Fake.State['custom-stash-7'] = 'stopped'
        $r = @(Restore-YurunaServiceVM -Identity $identity -HealthTimeoutSeconds 0 -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].VMName | Should -Be 'custom-stash-7'
        $r[0].Outcome | Should -Be 'started'
        $script:Fake.StateCalls | Should -Contain 'custom-stash-7'
        $script:Fake.StateCalls | Should -Not -Contain 'yuruna-stash-service'
        $script:Fake.StartCalls | Should -Be @('custom-stash-7')
    }

    It 'accepts identity rows read back from JSON as hashtables' {
        $json = ConvertTo-Json -InputObject @(@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = 80; HostingMode = 'vm' }) -Depth 5
        $rows = @(ConvertFrom-Json -InputObject $json -AsHashtable)
        $script:Fake.State['yuruna-stash-service'] = 'running'
        $r = @(Restore-YurunaServiceVM -Identity $rows -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'running'
    }

    It 'accepts verdict rows as identity, keeping the endpoint they captured' {
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'custom-stash-9'; DisplayName = 'Stash service'; HealthPort = 80; HostingMode = 'vm'
                Advertised = [pscustomobject]@{ Address = '10.0.0.9'; Port = 80; Url = ''; Origin = 'marker' } })
        $script:Fake.State['custom-stash-9'] = 'running'
        $verdict = Test-YurunaServiceVmRunning -Identity $identity -UnknownMeans Repair -HostType 'host.ubuntu.kvm' -StateRoot $script:Env.StateRoot -NoServiceProbe
        @($verdict.RecoverySet).Count | Should -Be 1
        $json = ConvertTo-Json -InputObject @($verdict.RecoverySet) -Depth 10
        $roundTrip = @(ConvertFrom-Json -InputObject $json -AsHashtable)
        foreach ($rows in @(@($verdict.RecoverySet), $roundTrip)) {
            $script:Fake.StateCalls.Clear()
            $r = @(Restore-YurunaServiceVM -Identity $rows -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $r.Count | Should -Be 1
            $r[0].VMName | Should -Be 'custom-stash-9'
            $r[0].Outcome | Should -Be 'running'
            $script:Fake.StateCalls | Should -Contain 'custom-stash-9'
        }
    }

    It 'reports a host-process deployment as not-a-guest without asking the hypervisor about it' {
        $identity = @([pscustomobject]@{
                Key = 'pool-control'; VMName = 'yuruna-pool-control-service'; DisplayName = 'Pool-control service'; HealthPort = 80
                HostingMode = 'host-process'; HostProcess = [pscustomobject]@{ Pid = 4242; Port = 8090; Verified = $true }
            })
        $r = @(Restore-YurunaServiceVM -Identity $identity -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'not-a-guest'
        $r[0].HostingMode | Should -Be 'host-process'
        $script:Fake.StateCalls | Should -Not -Contain 'yuruna-pool-control-service'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'reports deadline-exhausted, calling no driver verb at all, when the deadline is already spent' {
        $expired = New-YurunaDeadline -TotalMilliseconds 0
        $r = @(Restore-YurunaServiceVM -Deadline $expired -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r.Count | Should -Be @(Get-YurunaServiceVmRoster).Count
        foreach ($row in $r) { $row.Outcome | Should -Be 'deadline-exhausted' }
        $script:Fake.ProbeCalls | Should -Be 0
        $script:Fake.StateCalls.Count | Should -Be 0
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'ends the start poll at the deadline under the injected clock' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $script:Fake.StartSets = $null
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StartTimeoutSeconds 30 -HealthTimeoutSeconds 0 -StateRoot $script:Env.StateRoot `
                -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Outcome | Should -Be 'start-timeout'
        $script:Time.Box.Slept | Should -BeLessOrEqual 30000 -Because 'no sleep runs past the start window'
        $script:Time.Box.Slept | Should -BeGreaterOrEqual 28000
    }

    It 'ends the health wait at the shared deadline, which caps the per-call window' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $deadline = New-YurunaDeadline -TotalMilliseconds 40000 -ClockTicks $script:Time.Clock
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StartTimeoutSeconds 10 -HealthTimeoutSeconds 90 -Deadline $deadline `
                -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Outcome | Should -Be 'started'
        $r[0].Healthy | Should -BeFalse
        $r[0].Obligation | Should -Be 'health-unverified'
        $script:Time.Box.Slept | Should -BeLessOrEqual 40000 -Because 'the whole pass fits the shared deadline, not the 90-second health window'
    }

    It 'previews without taking a lock or starting anything' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $before = @(Get-ChildItem -LiteralPath $script:Env.StateRoot -Force | ForEach-Object Name)
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -WhatIf)
        $r[0].Outcome | Should -Be 'start-failed'
        $r[0].Message | Should -Be 'WhatIf'
        $after = @(Get-ChildItem -LiteralPath $script:Env.StateRoot -Force | ForEach-Object Name)
        ($after -join ',') | Should -Be ($before -join ',') -Because 'a preview creates no lock file and no census'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'emits one typed record per service for zero, one and many services' {
        @(Restore-YurunaServiceVM -Identity @() -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false).Count | Should -Be 0
        $one = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $one.Count | Should -Be 1
        $one[0] | Should -BeOfType [pscustomobject]
        $many = @(Restore-YurunaServiceVM -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $many.Count | Should -Be @(Get-YurunaServiceVmRoster).Count
        foreach ($row in $many) {
            $row | Should -BeOfType [pscustomobject]
            foreach ($field in @('Key', 'VMName', 'DisplayName', 'StateBefore', 'Outcome', 'Healthy', 'Message', 'ProbeReason', 'HypervisorState',
                    'DesiredState', 'IntentGeneration', 'HostingMode', 'Address', 'ConsumerEndpoint', 'ConsumerEndpointState', 'Obligation', 'ElapsedMs')) {
                $row.PSObject.Properties.Name | Should -Contain $field
            }
        }
    }
}

Describe 'Restore-YurunaServiceVM -ObserveOnly -- never starts anything' {
    BeforeEach {
        $script:Fake.State = @{}
        $script:Fake.Ip = @{}
        $script:Fake.Probe = $null
        $script:Fake.ProbeCalls = 0
        $script:Fake.StartSets = 'running'
        $script:Fake.StateCalls.Clear()
        $script:Fake.StartCalls.Clear()
        $script:Fake.IpCalls.Clear()
        $script:Env = New-PrivateRoot
        $script:Time = New-FakeClock
    }

    It 'reports the confirmed stopped state without starting it' {
        $svc = @(Get-YurunaServiceVmRoster)[0]
        $script:Fake.State[$svc.VMName] = 'stopped'

        $r = @(Restore-YurunaServiceVM -Key $svc.Key -ObserveOnly -HealthTimeoutSeconds 9 -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'stopped'
        $r[0].Obligation | Should -Be 'health-unverified'
        $script:Fake.StartCalls.Count | Should -Be 0 -Because 'ObserveOnly must never call Start-VM'
        $script:Time.Box.Slept | Should -BeLessOrEqual 9000
    }

    It 'still reports absent and state-unknown as themselves, not as stopped' {
        $svcs = @(Get-YurunaServiceVmRoster)
        $script:Fake.State[$svcs[0].VMName] = 'absent'
        $script:Fake.State[$svcs[1].VMName] = 'unknown'

        $r0 = @(Restore-YurunaServiceVM -Key $svcs[0].Key -ObserveOnly -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r0[0].Outcome | Should -Be 'absent'
        $r1 = @(Restore-YurunaServiceVM -Key $svcs[1].Key -ObserveOnly -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r1[0].Outcome | Should -Be 'state-unknown'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'never calls Start-VM across the whole roster, whatever state each service is in' {
        $svcs = @(Get-YurunaServiceVmRoster)
        $states = @('absent', 'unknown', 'stopped', 'running')
        for ($i = 0; $i -lt $svcs.Count; $i++) { $script:Fake.State[$svcs[$i].VMName] = $states[$i % $states.Count] }

        $r = @(Restore-YurunaServiceVM -ObserveOnly -HealthTimeoutSeconds 6 -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r.Count | Should -Be $svcs.Count
        $script:Fake.StartCalls.Count | Should -Be 0 -Because 'ObserveOnly is a pure read across the entire roster, never a mutation'
    }

    It 'waits for a resumed guest whose listener comes up after a few polls, within the deadline' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $script:Time.Box.OnSleep = { param($count) if ($count -eq 3) { $listener.Start() } }.GetNewClosure()
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm' })
        $script:Fake.State['yuruna-stash-service'] = 'running'
        $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.1'
        try {
            $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 60 -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        } finally { $listener.Stop() }
        $r[0].Outcome | Should -Be 'running'
        $r[0].Healthy | Should -BeTrue
        $r[0].Address | Should -Be '127.0.0.1'
        $r[0].ConsumerEndpointState | Should -Be 'not-advertised'
        $r[0].Obligation | Should -Be 'none'
        $script:Time.Box.Sleeps | Should -BeGreaterOrEqual 3
    }

    It 'never reports a silent resumed guest healthy: health-unverified at the deadline' {
        $port = Get-FreeLoopbackPort
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm' })
        $script:Fake.State['yuruna-stash-service'] = 'running'
        $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.1'
        $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 30 -StateRoot $script:Env.StateRoot `
                -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Healthy | Should -BeFalse
        $r[0].Obligation | Should -Be 'health-unverified'
        $script:Time.Box.Slept | Should -BeLessOrEqual 30000
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'leaves an obligation, and repairs nothing, when no address can be resolved' {
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = 80; HostingMode = 'vm' })
        $script:Fake.State['yuruna-stash-service'] = 'running'
        $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 12 -StateRoot $script:Env.StateRoot `
                -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Healthy | Should -BeFalse
        $r[0].Address | Should -Be ''
        $r[0].Obligation | Should -Be 'health-unverified'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'flags a stale advertisement even while the old forwarder still accepts connections' {
        if (-not (Test-LoopbackAddressReachable -Address '127.0.0.2')) { Set-ItResult -Skipped -Because 'this host does not answer 127.0.0.2 (macOS configures only 127.0.0.1 on lo0)'; return }
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $listener.Start()
        try {
            # The guest re-leased to 127.0.0.2; the advertised endpoint is a
            # host forwarder still pointing at the old 127.0.0.3. The forwarder
            # port accepts (the listener answers every loopback address), which
            # is exactly what must not be read as proof.
            $identity = @([pscustomobject]@{
                    Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm'
                    Advertised = [pscustomobject]@{ Address = '127.0.0.1'; Port = $port; Url = "http://127.0.0.1:$port"; Origin = 'marker' }
                    Forwarders = @([pscustomobject]@{ HostPort = $port; TargetAddress = '127.0.0.3'; TargetPort = 80; OwnerPid = 1; OwnerVerified = $true; Origin = 'forwarder-pidfile' })
                    ForwardersCaptured = $true
                })
            $script:Fake.State['yuruna-stash-service'] = 'running'
            $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.2'
            $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 10 -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        } finally { $listener.Stop() }
        $r[0].Healthy | Should -BeTrue
        $r[0].ConsumerEndpointState | Should -Be 'stale-advertisement'
        $r[0].Obligation | Should -Be 'endpoint-repoint-required'
        $r[0].ConsumerEndpoint | Should -Be "127.0.0.1:$port"
    }

    It 'leaves a forwarder it cannot tie to an owner unchecked, never stale' {
        if (-not (Test-LoopbackAddressReachable -Address '127.0.0.2')) { Set-ItResult -Skipped -Because 'this host does not answer 127.0.0.2 (macOS configures only 127.0.0.1 on lo0)'; return }
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
        $listener.Start()
        try {
            # The advertised endpoint is this host's own, the forwarder table
            # was captured, and the forwarder on that port has an owner nobody
            # could verify: it may be the very one that reaches the guest.
            $identity = @([pscustomobject]@{
                    Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm'
                    Advertised = [pscustomobject]@{ Address = '127.0.0.1'; Port = $port; Url = "http://127.0.0.1:$port"; Origin = 'marker' }
                    Forwarders = @([pscustomobject]@{ HostPort = $port; TargetAddress = '127.0.0.2'; TargetPort = 80; OwnerPid = 1; OwnerVerified = $false; Origin = 'forwarder-pidfile' })
                    ForwardersCaptured = $true
                })
            $script:Fake.State['yuruna-stash-service'] = 'running'
            $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.2'
            $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 10 -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        } finally { $listener.Stop() }
        $r[0].Healthy | Should -BeTrue
        $r[0].ConsumerEndpointState | Should -Be 'not-checked'
        $r[0].Obligation | Should -Be 'endpoint-unverified'
    }

    It 'resolves addresses through the passive resolver under the deadline, and runs the full lookup only while it fits' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $script:Passive = @{ Address = '127.0.0.1'; Reason = 'ok'; Calls = 0 }
        function global:Get-VMPassiveAddressContext {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in with the driver''s signature; the deadline is not needed to answer.')]
            param([AllowNull()]$Deadline)
            [pscustomobject]@{ PSTypeName = 'Yuruna.PassiveAddressContext'; ArpMap = @{}; ArpReason = 'injected' }
        }
        function global:Get-VMPassiveAddress {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in with the driver''s signature; context and deadline are not needed to answer.')]
            param([string]$VMName, $Context, $Deadline)
            $script:Passive.Calls++
            [pscustomobject]@{ VMName = $VMName; Address = $script:Passive.Address; Reason = $script:Passive.Reason }
        }
        $identity = @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm' })
        $script:Fake.State['yuruna-stash-service'] = 'running'
        $observe = {
            param([int]$Seconds)
            $clock = New-FakeClock
            @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds $Seconds -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $clock.Clock -SleepMilliseconds $clock.Sleep -Confirm:$false)
        }
        try {
            $found = & $observe 10
            $found[0].Healthy | Should -BeTrue
            $found[0].Address | Should -Be '127.0.0.1'
            $script:Fake.IpCalls.Count | Should -Be 0 -Because 'the passive resolver answered'
            $script:Passive.Calls | Should -BeGreaterOrEqual 1
            $script:Passive.Address = $null
            $script:Passive.Reason = 'arp-miss'
            $short = & $observe 10
            $short[0].Address | Should -Be ''
            $short[0].Obligation | Should -Be 'health-unverified'
            $script:Fake.IpCalls.Count | Should -Be 0 -Because 'the full lookup''s worst case does not fit a ten-second window'
            # The full lookup names the guest; its listener is down, so every
            # poll is a prompt refusal.
            $listener.Stop()
            $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.1'
            $long = & $observe 90
            $long[0].Address | Should -Be '127.0.0.1'
            $long[0].Healthy | Should -BeFalse
            $script:Fake.IpCalls.Count | Should -Be 1 -Because 'the full lookup runs while its worst case fits, and its answer is kept'
        } finally {
            $listener.Stop()
            foreach ($name in @('Get-VMPassiveAddressContext', 'Get-VMPassiveAddress')) { Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'verifies an advertised endpoint that is the fresh address and answers' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        try {
            $identity = @([pscustomobject]@{
                    Key = 'stash'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = $port; HostingMode = 'vm'
                    Advertised = [pscustomobject]@{ Address = '127.0.0.1'; Port = $port; Url = ''; Origin = 'marker' }
                })
            $script:Fake.State['yuruna-stash-service'] = 'running'
            $script:Fake.Ip['yuruna-stash-service'] = '127.0.0.1'
            $r = @(Restore-YurunaServiceVM -Identity $identity -ObserveOnly -HealthTimeoutSeconds 10 -StateRoot $script:Env.StateRoot `
                    -RuntimeDir $script:Env.RuntimeDir -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        } finally { $listener.Stop() }
        $r[0].ConsumerEndpointState | Should -Be 'verified'
        $r[0].Obligation | Should -Be 'none'
    }
}

Describe 'Restore-YurunaServiceVM -- a stopped hypervisor app is no evidence of a registered guest' {
    BeforeAll {
        # The app-stopped reading means every guest is off only on macOS,
        # where no guest runs without UTM.
        function global:Get-HostType { 'host.macos.utm' }
    }
    AfterAll {
        Remove-Item -Path 'Function:\Get-HostType' -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:Fake.State = @{}
        $script:Fake.Ip = @{}
        $script:Fake.Probe = [pscustomobject]@{ state = 'Unresponsive'; reason = 'app-stopped'; elapsedMs = 3 }
        $script:Fake.ProbeCalls = 0
        $script:Fake.StartSets = 'running'
        $script:Fake.StateCalls.Clear()
        $script:Fake.StartCalls.Clear()
        $script:Fake.IpCalls.Clear()
        Remove-Item -Path 'Function:\Get-VMStateRecord' -Force -ErrorAction SilentlyContinue
        $script:Env = New-PrivateRoot
        $script:Time = New-FakeClock
    }

    It 'reports a guest this host never built as absent, reading each guest once and starting nothing' {
        $roster = @(Get-YurunaServiceVmRoster)
        $r = @(Restore-YurunaServiceVM -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r.Count | Should -Be $roster.Count
        foreach ($row in $r) {
            $row.Outcome | Should -Be 'absent'
            $row.Obligation | Should -Be 'none'
            $row.ProbeReason | Should -Be 'app-stopped'
            $row.HypervisorState | Should -Be 'Unresponsive'
        }
        $script:Fake.StartCalls.Count | Should -Be 0 -Because 'absent is not this host''s job, whatever the app state'
        $script:Fake.StateCalls.Count | Should -Be $roster.Count -Because 'each guest is read on its own before anything could start it'
    }

    It 'starts a guest whose own reading shows it registered and stopped' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'stopped'
        $r = @(Restore-YurunaServiceVM -Key 'stash' -HealthTimeoutSeconds 0 -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Outcome | Should -Be 'started'
        $script:Fake.StartCalls | Should -Be @($svc.VMName)
    }

    It 'reports state-unknown, and starts nothing, when the guest''s own reading cannot be classified' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $script:Fake.State[$svc.VMName] = 'unknown'
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'state-unknown'
        $r[0].ProbeReason | Should -Be 'unclassified'
        $r[0].Obligation | Should -Be 'state-unresolved'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'names a guest the structured record positively does not know as not-found' {
        function global:Get-VMStateRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Fake record signature matches the driver; the bound values are not needed to answer.')]
            param([string]$VMName, $Deadline, [int]$TimeoutSeconds = 20)
            [pscustomobject]@{ VMName = $VMName; State = 'absent'; RawState = ''; Registration = 'Absent'; Reason = 'not-found'; ExitCode = 1; ElapsedMs = 4 }
        }
        try {
            $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
            $r[0].Outcome | Should -Be 'absent'
            $r[0].ProbeReason | Should -Be 'not-found'
            $script:Fake.StartCalls.Count | Should -Be 0
        } finally {
            Remove-Item -Path 'Function:\Get-VMStateRecord' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reads nothing for a guest stopped on purpose' {
        $svc = @(Get-YurunaServiceVmRoster -Key 'stash')[0]
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName $svc.VMName -Operation Stop -Script 'fixture' -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -FinalState 'absent' -Confirm:$false
        $r = @(Restore-YurunaServiceVM -Key 'stash' -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false)
        $r[0].Outcome | Should -Be 'intended-stopped'
        $script:Fake.StateCalls.Count | Should -Be 0 -Because 'a stop request is answer enough, and the read would launch the app'
        $script:Fake.StartCalls.Count | Should -Be 0
    }

    It 'reports absent under -ObserveOnly without waiting out the observe window' {
        $r = @(Restore-YurunaServiceVM -Key 'stash' -ObserveOnly -HealthTimeoutSeconds 30 -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir `
                -ClockTicks $script:Time.Clock -SleepMilliseconds $script:Time.Sleep -Confirm:$false)
        $r[0].Outcome | Should -Be 'absent'
        $script:Time.Box.Slept | Should -Be 0
        $script:Fake.StartCalls.Count | Should -Be 0
    }
}
