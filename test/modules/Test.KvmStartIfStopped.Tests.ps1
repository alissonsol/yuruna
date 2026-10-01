<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42c1f2a7-5d3e-4b8a-9e61-7a4f0b2c9d13
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm libvirt systemd start-if-stopped force-stop host-refresh pester
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
    The KVM driver's rung-2 action (Start-VirtualizationServiceIfStopped), its
    bounded and identity-verified Stop-VMForce, and the positive-state
    preconditions of Rename-VM and Assert-Virtualization.
.DESCRIPTION
    Every native call goes through a module-scoped mock of
    Invoke-BoundedNativeCommand that answers from fixture tables (systemctl
    show blocks, virsh answers, sudo outcomes), so no real sudo, systemctl
    start, virsh net-start or kill is ever launched. Time is an injected clock
    advanced by a mocked Start-Sleep, so waits and deadlines are exercised
    without waiting. The force-stop identity check reads a private fake
    process table, never /proc.
#>

BeforeAll {
    $script:NativeCommandStubs = @()
    foreach ($nativeName in @('systemctl', 'virsh')) {
        if (-not (Get-Command $nativeName -ErrorAction SilentlyContinue)) {
            Set-Item -LiteralPath "Function:global:$nativeName" -Value { $global:LASTEXITCODE = 1 }
            $script:NativeCommandStubs += $nativeName
        }
    }

    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $repoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    $script:Module = Get-Module Yuruna.Host
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yrn-kvmstart-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force

    function New-NativeResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture result.')]
        param([int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '', [switch]$TimedOut, [switch]$NotStarted)
        $code = if ($NotStarted) { -1 } elseif ($TimedOut) { 124 } else { $ExitCode }
        return @{ ExitCode = $code; StdOut = $StdOut; StdErr = $StdErr; TimedOut = [bool]$TimedOut; Started = -not $NotStarted
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 3 }
    }

    function New-UnitRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param([string]$Load = 'loaded', [string]$Active = 'active', [string]$Sub = 'running', [string]$File = 'enabled')
        return @{ Load = $Load; Active = $Active; Sub = $Sub; File = $File }
    }

    function Reset-UnitTable {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param()
        $script:Units = @{
            'libvirtd.service'     = New-UnitRow
            'libvirtd.socket'      = New-UnitRow -Sub 'listening'
            'virtlogd.service'     = New-UnitRow
            'virtlogd.socket'      = New-UnitRow -Sub 'listening'
            'virtqemud.service'    = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
            'virtqemud.socket'     = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
            'virtnetworkd.service' = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
            'virtnetworkd.socket'  = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
        }
    }

    function Format-UnitShow {
        param([string[]]$Unit)
        return (@($Unit | ForEach-Object {
                    $row = $script:Units[$_]
                    "Id=$_`nLoadState=$($row.Load)`nActiveState=$($row.Active)`nSubState=$($row.Sub)`nUnitFileState=$($row.File)"
                }) -join "`n`n") + "`n"
    }

    function Invoke-FixtureNative {
        param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
        $remaining = if ($script:Deadline) { Get-YurunaDeadlineRemainingMs -Deadline $script:Deadline } else { [long]::MaxValue }
        $script:Calls.Add([pscustomobject]@{ FilePath = $FilePath; Argv = [string[]]@($ArgumentList); TimeoutSeconds = $TimeoutSeconds; RemainingMs = $remaining })
        switch (Split-Path -Leaf $FilePath) {
            'systemctl' {
                if ($script:SystemctlMissing) { return (New-NativeResult -NotStarted) }
                if ($script:OnShow) { & $script:OnShow }
                return (New-NativeResult -StdOut (Format-UnitShow -Unit @($ArgumentList | Select-Object -Skip 4)))
            }
            'sudo'  { return (& $script:OnSudo -Argv ([string[]]@($ArgumentList))) }
            'virsh' { return (& $script:OnVirsh -Argv ([string[]]@($ArgumentList))) }
        }
        throw "unexpected native call: $FilePath $($ArgumentList -join ' ')"
    }

    function Get-FixtureCall {
        param([string]$Leaf)
        return @($script:Calls | Where-Object { (Split-Path -Leaf $_.FilePath) -eq $Leaf })
    }

    # Default virsh: a domiflist table per VM, net-info from $script:NetActive,
    # net-start flips 'default' to active.
    $script:DefaultOnVirsh = {
        param([string[]]$Argv)
        $argv = @($Argv)
        switch ($argv[2]) {
            'domiflist' {
                $vm = $argv[-1]
                if (-not $script:DomIfList.ContainsKey($vm)) { return (New-NativeResult -ExitCode 1 -StdErr "error: failed to get domain '$vm'") }
                return (New-NativeResult -StdOut $script:DomIfList[$vm])
            }
            'net-info' {
                $net = $argv[3]
                if (-not $script:NetActive.ContainsKey($net)) {
                    return (New-NativeResult -ExitCode 1 -StdErr "error: failed to get network '$net'`nerror: Network not found: no network with matching name '$net'")
                }
                return (New-NativeResult -StdOut "Name:           $net`nUUID:           00000000-0000-0000-0000-000000000000`nActive:         $($script:NetActive[$net])`nPersistent:     yes`n")
            }
            'net-start' {
                $script:NetActive[$argv[3]] = 'yes'
                return (New-NativeResult -StdOut "Network $($argv[3]) started")
            }
        }
        throw "unexpected virsh call: $($argv -join ' ')"
    }

    function Format-DomIfList {
        param([string[]]$Row)
        $lines = @(' Interface   Type      Source            Model    MAC', '---------------------------------------------------------------------')
        return (($lines + @($Row | ForEach-Object { " -           $_   virtio   52:54:00:00:00:01" })) -join "`n") + "`n"
    }

    function Set-FakeProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the suite-owned fake process table under the temp root.')]
        param([int]$ProcessId, [string[]]$Argv)
        $dir = Join-Path $script:ProcRoot "$ProcessId"
        $null = New-Item -ItemType Directory -Path $dir -Force
        [IO.File]::WriteAllBytes((Join-Path $dir 'cmdline'), [Text.Encoding]::UTF8.GetBytes((($Argv -join [char]0) + [char]0)))
    }

    function Invoke-Rung {
        param([hashtable]$Extra = @{})
        return Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false @Extra
    }
}

AfterAll {
    foreach ($nativeName in $script:NativeCommandStubs) { Remove-Item -LiteralPath "Function:global:$nativeName" -ErrorAction SilentlyContinue }

    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Start-VirtualizationServiceIfStopped (KVM rung 2)' {
    BeforeEach {
        Reset-UnitTable
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Tick = [long]5000000
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 120000 -ClockTicks { $script:Tick }
        $script:SystemctlMissing = $false
        $script:OnShow = $null
        $script:DomIfList = @{}
        $script:NetActive = @{ default = 'yes' }
        $script:OnVirsh = $script:DefaultOnVirsh
        # A sudo'd start succeeds and the unit becomes active.
        $script:OnSudo = {
            param([string[]]$Argv)
            $unit = @($Argv)[-1]
            $script:Units[$unit] = New-UnitRow
            New-NativeResult
        }
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-FixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
        Mock -ModuleName Yuruna.Host Start-Sleep { $script:Tick += [long]$Milliseconds }
    }

    It 'reports already-running with no sudo call when every unit is active' {
        $r = Invoke-Rung
        $r.PSObject.TypeNames | Should -Contain 'Yuruna.VirtualizationStartResult'
        $r.schemaVersion | Should -Be 1
        $r.hostType | Should -Be 'host.ubuntu.kvm'
        $r.outcome | Should -Be 'already-running'
        $r.reason | Should -Be 'already-running'
        $r.layout | Should -Be 'monolithic'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        @($r.actions | Where-Object { $_.kind -eq 'unit-start' }).Count | Should -Be 2
    }

    It 'leaves an idle service behind an active socket alone (socket-live)' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $r = Invoke-Rung
        $r.outcome | Should -Be 'already-running'
        $r.reason | Should -Be 'socket-live'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        ($r.actions | Where-Object { $_.target -eq 'libvirtd.service' }).result | Should -Be 'socket-live'
    }

    It 'starts exactly the stopped libvirtd with sudo -n and confirms it with a fresh read' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $r = Invoke-Rung
        $sudo = Get-FixtureCall 'sudo'
        $sudo.Count | Should -Be 1
        ($sudo[0].Argv -join ' ') | Should -Be '-n systemctl --no-ask-password start libvirtd.service'
        $r.outcome | Should -Be 'started'
        $r.reason | Should -Be 'started'
        $row = $r.actions | Where-Object { $_.target -eq 'libvirtd.service' }
        $row.result | Should -Be 'started'
        $row.before | Should -Be 'inactive/dead'
        $row.after | Should -Be 'active/running'
        @($row.command) | Should -Be @('systemctl', '--no-ask-password', 'start', 'libvirtd.service')
    }

    It 'starts virtlogd before libvirtd when both are stopped' {
        foreach ($unit in 'libvirtd.service', 'libvirtd.socket', 'virtlogd.service', 'virtlogd.socket') {
            $script:Units[$unit] = New-UnitRow -Active 'inactive' -Sub 'dead'
        }
        $r = Invoke-Rung
        $sudo = Get-FixtureCall 'sudo'
        $sudo.Count | Should -Be 2
        $sudo[0].Argv[-1] | Should -Be 'virtlogd.service'
        $sudo[1].Argv[-1] | Should -Be 'libvirtd.service'
        $r.outcome | Should -Be 'started'
    }

    It 'refuses with <Reason> and makes zero mutating calls when <Case>' -ForEach @(
        @{ Case = 'the unit is disabled'; Reason = 'unit-disabled'; Unit = 'libvirtd.service'; Row = @{ Load = 'loaded'; Active = 'inactive'; Sub = 'dead'; File = 'disabled' } }
        @{ Case = 'the unit file is masked'; Reason = 'unit-masked'; Unit = 'virtlogd.service'; Row = @{ Load = 'loaded'; Active = 'inactive'; Sub = 'dead'; File = 'masked' } }
        @{ Case = 'the unit is failed'; Reason = 'unit-failed'; Unit = 'libvirtd.service'; Row = @{ Load = 'loaded'; Active = 'failed'; Sub = 'failed'; File = 'enabled' } }
        @{ Case = 'virtlogd is not loaded'; Reason = 'unit-state-unknown'; Unit = 'virtlogd.service'; Row = @{ Load = 'not-found'; Active = 'inactive'; Sub = 'dead'; File = '' } }
    ) {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        if ($Unit -ne 'libvirtd.service') { $script:Units[$Unit] = $Row } else { $script:Units['libvirtd.service'] = $Row }
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be $Reason
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        (Get-FixtureCall 'virsh').Count | Should -Be 0
    }

    It 'refuses a mixed layout as ambiguous without starting anything' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['virtqemud.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'layout-ambiguous'
        $r.layout | Should -Be 'mixed'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'reports a modular layout as unavailable/layout-unqualified with no action' {
        $script:Units['libvirtd.service'] = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
        $script:Units['virtqemud.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $r = Invoke-Rung
        $r.outcome | Should -Be 'unavailable'
        $r.reason | Should -Be 'layout-unqualified'
        $r.layout | Should -Be 'modular'
        $r.actions.Count | Should -Be 0
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'refuses with missing-client when systemctl cannot be launched' {
        $script:SystemctlMissing = $true
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'missing-client'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'waits for an activating unit that settles and reports already-running' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'activating' -Sub 'start'
        $script:ShowCount = 0
        $script:OnShow = {
            $script:ShowCount++
            if ($script:ShowCount -ge 3) { $script:Units['libvirtd.service'] = New-UnitRow }
        }
        $r = Invoke-Rung
        $r.outcome | Should -Be 'already-running'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        $script:ShowCount | Should -Be 3
    }

    It 'refuses a unit that never settles with unit-transitioning inside the settle window' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'deactivating' -Sub 'stop-sigterm'
        $startTick = $script:Tick
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'unit-transitioning'
        ($script:Tick - $startTick) | Should -BeLessOrEqual 15000
        ($script:Tick - $startTick) | Should -BeGreaterOrEqual 14000
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'refuses with elevation-refused on <Wording> and carries the exact command' -ForEach @(
        @{ Wording = 'the sudo-rs refusal'; Text = 'sudo: interactive authentication is required' }
        @{ Wording = 'the classic refusal'; Text = 'sudo: a password is required' }
    ) {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:RefusalText = $Text
        $script:OnSudo = { New-NativeResult -ExitCode 1 -StdErr $script:RefusalText }
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'elevation-refused'
        $row = $r.actions | Where-Object { $_.target -eq 'libvirtd.service' }
        $row.result | Should -Be 'refused'
        @($row.command) | Should -Be @('systemctl', '--no-ask-password', 'start', 'libvirtd.service')
    }

    It 'reads a timed-out start as <Outcome> when the post-read shows <After>' -ForEach @(
        @{ After = 'active'; Outcome = 'started'; Reason = 'started' }
        @{ After = 'inactive'; Outcome = 'unknown'; Reason = 'start-timed-out' }
    ) {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:AfterActive = $After
        $script:OnSudo = {
            if ($script:AfterActive -eq 'active') { $script:Units['libvirtd.service'] = New-UnitRow }
            New-NativeResult -TimedOut
        }
        $r = Invoke-Rung
        $r.outcome | Should -Be $Outcome
        $r.reason | Should -Be $Reason
    }

    It 'reports failed/start-failed for a non-refusal nonzero exit' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:OnSudo = { New-NativeResult -ExitCode 1 -StdErr 'Job for libvirtd.service failed because the control process exited with error code.' }
        $r = Invoke-Rung
        $r.outcome | Should -Be 'failed'
        $r.reason | Should -Be 'start-failed'
    }

    It 'stops after the first failed start and does not start the next unit' {
        foreach ($unit in 'libvirtd.service', 'libvirtd.socket', 'virtlogd.service', 'virtlogd.socket') {
            $script:Units[$unit] = New-UnitRow -Active 'inactive' -Sub 'dead'
        }
        $script:OnSudo = { New-NativeResult -ExitCode 1 -StdErr 'Job failed.' }
        $r = Invoke-Rung
        (Get-FixtureCall 'sudo').Count | Should -Be 1
        $r.outcome | Should -Be 'failed'
        ($r.actions | Where-Object { $_.target -eq 'libvirtd.service' }).result | Should -Be 'skipped'
    }

    It 'previews under -WhatIf with only systemctl show called' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -DependentVMName @('svc-a') -WhatIf
        $r.outcome | Should -Be 'preview'
        ($r.actions | Where-Object { $_.target -eq 'libvirtd.service' }).result | Should -Be 'preview'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        (Get-FixtureCall 'virsh').Count | Should -Be 0
        foreach ($call in $script:Calls) { $call.Argv[0] | Should -Be 'show' }
    }

    It 'makes zero native calls when the deadline is already exhausted' {
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 400 -ClockTicks { $script:Tick }
        $r = Invoke-Rung
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'deadline-exhausted'
        $script:Calls.Count | Should -Be 0
        $r.actions.Count | Should -Be 0
    }

    It 'caps every native call at the ceiling of the remaining time' {
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 7500 -ClockTicks { $script:Tick }
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'activating' -Sub 'start'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:ShowCount = 0
        $script:OnShow = {
            $script:ShowCount++
            if ($script:ShowCount -ge 4) { $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead' }
        }
        $script:DomIfList = @{ 'svc-a' = (Format-DomIfList -Row 'network   default  ') }
        $null = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        $script:Calls.Count | Should -BeGreaterThan 3
        foreach ($call in $script:Calls) {
            $call.TimeoutSeconds | Should -BeGreaterOrEqual 1
            $call.TimeoutSeconds | Should -BeLessOrEqual ([Math]::Ceiling($call.RemainingMs / 1000.0)) -Because "$($call.FilePath) $($call.Argv -join ' ')"
        }
    }

    It 'never throws: a fault before any start is refused, after a start attempt it is unknown' {
        $script:OnShow = { throw 'systemctl exploded' }
        $before = Invoke-Rung
        $before.outcome | Should -Be 'refused'
        $before.reason | Should -Be 'unit-state-unknown'
        (Get-FixtureCall 'sudo').Count | Should -Be 0

        $script:OnShow = $null
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:Units['libvirtd.socket']  = New-UnitRow -Active 'inactive' -Sub 'dead'
        $script:OnSudo = {
            $script:OnShow = { throw 'systemctl exploded after the start' }
            New-NativeResult
        }
        $after = Invoke-Rung
        $after.outcome | Should -Be 'unknown'
        $after.reason | Should -Be 'postcondition-unknown'
    }

    It 'always returns actions as an array of typed rows (zero, one, many)' {
        $script:Units['libvirtd.service'] = New-UnitRow -Load 'not-found' -Active 'inactive' -Sub 'dead' -File ''
        $script:Units['virtqemud.service'] = New-UnitRow -Active 'inactive' -Sub 'dead'
        $zero = Invoke-Rung
        Reset-UnitTable
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead' -File 'disabled'
        $one = Invoke-Rung
        Reset-UnitTable
        $many = Invoke-Rung
        foreach ($case in @(@{ R = $zero; N = 0 }, @{ R = $one; N = 1 }, @{ R = $many; N = 3 })) {
            $case.R.actions.GetType().Name | Should -Be 'Object[]'
            $case.R.actions.Count | Should -Be $case.N
            foreach ($row in $case.R.actions) {
                foreach ($field in 'target', 'kind', 'before', 'after', 'result', 'reason', 'command', 'exitCode', 'timedOut', 'elapsedMs') {
                    $row.PSObject.Properties.Name | Should -Contain $field
                }
                , $row.command | Should -BeOfType [string[]]
            }
        }
    }
}

Describe 'Start-VirtualizationServiceIfStopped -- the default network step' {
    BeforeEach {
        Reset-UnitTable
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Tick = [long]9000000
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 120000 -ClockTicks { $script:Tick }
        $script:SystemctlMissing = $false
        $script:OnShow = $null
        $script:OnSudo = { throw 'no sudo expected in the network step' }
        $script:OnVirsh = $script:DefaultOnVirsh
        $script:DomIfList = @{ 'svc-a' = (Format-DomIfList -Row 'network   default  ') }
        $script:NetActive = @{ default = 'no' }
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-FixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
        Mock -ModuleName Yuruna.Host Start-Sleep { $script:Tick += [long]$Milliseconds }
    }

    It 'starts an inactive default network a dependent VM needs, without sudo' {
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        $starts = @(Get-FixtureCall 'virsh' | Where-Object { $_.Argv -contains 'net-start' })
        $starts.Count | Should -Be 1
        ($starts[0].Argv -join ' ') | Should -Be '--connect qemu:///system net-start default'
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        $r.outcome | Should -Be 'started'
        ($r.actions | Where-Object { $_.kind -eq 'network-start' }).result | Should -Be 'started'
    }

    It 'makes no start call when the default network is already active' {
        $script:NetActive = @{ default = 'yes' }
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        @(Get-FixtureCall 'virsh' | Where-Object { $_.Argv -contains 'net-start' }).Count | Should -Be 0
        $r.outcome | Should -Be 'already-running'
    }

    It 'never starts an inactive network other than default' {
        $script:DomIfList = @{ 'svc-a' = (Format-DomIfList -Row 'network   yuruna-external') }
        $script:NetActive = @{ default = 'no'; 'yuruna-external' = 'no' }
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        @(Get-FixtureCall 'virsh' | Where-Object { $_.Argv -contains 'net-start' }).Count | Should -Be 0
        $row = $r.actions | Where-Object { $_.target -eq 'yuruna-external' }
        $row.result | Should -Be 'skipped'
        $row.reason | Should -Be 'network-not-default'
    }

    It 'records vm-unresolved when the dependent VM cannot be listed' {
        $script:DomIfList = @{}
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-missing') }
        $row = $r.actions | Where-Object { $_.target -eq 'svc-missing' }
        $row.result | Should -Be 'skipped'
        $row.reason | Should -Be 'vm-unresolved'
        @(Get-FixtureCall 'virsh' | Where-Object { $_.Argv -contains 'net-start' }).Count | Should -Be 0
    }

    It 'records network-undefined when default does not exist' {
        $script:NetActive = @{}
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        ($r.actions | Where-Object { $_.kind -eq 'network-start' }).reason | Should -Be 'network-undefined'
    }

    It 'records network-state-unknown and starts nothing when the network state cannot be read' {
        $script:NetActive = @{ default = 'perhaps' }
        $r = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        @(Get-FixtureCall 'virsh' | Where-Object { $_.Argv -contains 'net-start' }).Count | Should -Be 0
        $row = $r.actions | Where-Object { $_.kind -eq 'network-start' }
        $row.result | Should -Be 'unknown'
        $row.reason | Should -Be 'network-state-unknown'
        $row.before | Should -Be 'unknown'
        $r.outcome | Should -Be 'unknown'
        $r.reason | Should -Be 'network-state-unknown'
    }

    It 'makes no network call at all without a dependent VM' {
        $r = Invoke-Rung
        (Get-FixtureCall 'virsh').Count | Should -Be 0
        ($r.actions | Where-Object { $_.kind -eq 'network-start' }).reason | Should -Be 'network-not-required'
    }

    It 'skips the network step while the daemon start is refused' {
        $script:Units['libvirtd.service'] = New-UnitRow -Active 'inactive' -Sub 'dead' -File 'disabled'
        $null = Invoke-Rung -Extra @{ DependentVMName = @('svc-a') }
        (Get-FixtureCall 'virsh').Count | Should -Be 0
    }
}

Describe 'Stop-VMForce (KVM) -- bounded, identity-verified escalation' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Deadline = $null
        $script:Keys = [System.Collections.Generic.List[string]]::new()
        $script:RunDir = Join-Path $script:TempRoot ('run-' + [guid]::NewGuid().ToString('N'))
        $script:ProcRoot = Join-Path $script:TempRoot ('proc-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:RunDir, $script:ProcRoot -Force
        $script:PriorRunDir = & $script:Module { $script:KvmQemuRunDir }
        $script:PriorProcRoot = & $script:Module { $script:KvmProcRoot }
        & $script:Module { param($RunDir, $ProcRoot) $script:KvmQemuRunDir = $RunDir; $script:KvmProcRoot = $ProcRoot } $script:RunDir $script:ProcRoot
        $script:DomState = 'running'
        $script:OnVirsh = {
            param([string[]]$Argv)
            $argv = @($Argv)
            switch ($argv[2]) {
                'destroy'  { return (& $script:OnDestroy) }
                'domstate' { return (New-NativeResult -StdOut "$($script:DomState)`n") }
            }
            throw "unexpected virsh call: $($argv -join ' ')"
        }
        $script:OnDestroy = { New-NativeResult -TimedOut }
        $script:OnSudo = {
            Remove-Item -LiteralPath (Join-Path $script:ProcRoot '4242') -Recurse -Force -ErrorAction SilentlyContinue
            New-NativeResult
        }
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-FixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
        Mock -ModuleName Yuruna.Host Format-YurunaOperatorMessage { $script:Keys.Add($Key); $Key }
    }
    AfterEach {
        & $script:Module { param($RunDir, $ProcRoot) $script:KvmQemuRunDir = $RunDir; $script:KvmProcRoot = $ProcRoot } $script:PriorRunDir $script:PriorProcRoot
    }

    It 'returns $true on a successful destroy without reading the pidfile' {
        $script:OnDestroy = { New-NativeResult }
        Mock -ModuleName Yuruna.Host Get-KvmQemuProcessIdentity { throw 'must not be read' }
        Stop-VMForce -VMName 'vm-a' -Confirm:$false | Should -BeTrue
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        Should -Invoke -ModuleName Yuruna.Host Get-KvmQemuProcessIdentity -Times 0 -Exactly
    }

    It 'returns $true without any kill when libvirt reports the domain shut off after a failed destroy' {
        $script:OnDestroy = { New-NativeResult -ExitCode 1 -StdErr 'error: Failed to destroy domain' }
        $script:DomState = 'shut off'
        Stop-VMForce -VMName 'vm-a' -Confirm:$false | Should -BeTrue
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'kills only a verified qemu process with sudo -n /bin/kill and returns $true once it is gone' {
        $script:DomState = 'running'
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value '4242' -NoNewline
        Set-FakeProcess -ProcessId 4242 -Argv @('/usr/bin/qemu-system-x86_64', '-name', 'guest=vm-a,debug-threads=on', '-S')
        Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 6 -Confirm:$false | Should -BeTrue
        $sudo = Get-FixtureCall 'sudo'
        $sudo.Count | Should -Be 1
        ($sudo[0].Argv -join ' ') | Should -Be '-n /bin/kill -9 4242'
    }

    It 'never signals a recycled process id and warns with the unverified key' {
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value '4242' -NoNewline
        Set-FakeProcess -ProcessId 4242 -Argv @('/usr/bin/python3', 'unrelated.py')
        Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 6 -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        $script:Keys | Should -Contain 'host.kvm_force_stop_pid_unverified'
    }

    It 'never signals the qemu process of a different domain' {
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value '4242' -NoNewline
        Set-FakeProcess -ProcessId 4242 -Argv @('/usr/bin/qemu-system-x86_64', '-name', 'guest=vm-a,,b,debug-threads=on')
        Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 6 -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        (Get-FixtureCall 'sudo').Count | Should -Be 0
    }

    It 'returns $false and names the sudoers remedy when sudo refuses the signal' {
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value '4242' -NoNewline
        Set-FakeProcess -ProcessId 4242 -Argv @('/usr/bin/qemu-system-x86_64', '-name', 'guest=vm-a,debug-threads=on')
        $script:OnSudo = { New-NativeResult -ExitCode 1 -StdErr 'sudo: interactive authentication is required' }
        Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 6 -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        $script:Keys | Should -Contain 'host.kvm_force_stop_signal_refused'
    }

    It 'refuses a pidfile that does not hold a usable process id' {
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value 'not-a-pid' -NoNewline
        Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 4 -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        (Get-FixtureCall 'sudo').Count | Should -Be 0
        $script:Keys | Should -Contain 'host.kvm_force_stop_pidfile_invalid'
    }

    It 'returns within its budget when the process never goes away' {
        Set-Content -LiteralPath (Join-Path $script:RunDir 'vm-a.pid') -Value '4242' -NoNewline
        Set-FakeProcess -ProcessId 4242 -Argv @('/usr/bin/qemu-system-x86_64', '-name', 'guest=vm-a')
        $script:OnSudo = { New-NativeResult }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $result = Stop-VMForce -VMName 'vm-a' -StopTimeoutSeconds 2 -Confirm:$false
        $sw.Stop()
        $result | Should -BeFalse
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
    }

    It 'makes no native call under -WhatIf' {
        Stop-VMForce -VMName 'vm-a' -WhatIf | Should -BeFalse
        $script:Calls.Count | Should -Be 0
    }

    It 'classifies process identity: <Case>' -ForEach @(
        @{ Case = 'escaped comma in the name matches'; Name = 'a,b'; Argv = @('/usr/bin/qemu-system-aarch64', '-name', 'guest=a,,b,debug-threads=on'); Expected = 'match' }
        @{ Case = 'a prefix of an escaped name does not match'; Name = 'a'; Argv = @('/usr/bin/qemu-system-aarch64', '-name', 'guest=a,,b'); Expected = 'mismatch' }
        @{ Case = 'qemu-kvm leaf with a bare name matches'; Name = 'vm-a'; Argv = @('/usr/libexec/qemu-kvm', '-name', 'guest=vm-a'); Expected = 'match' }
        @{ Case = 'an empty command line is gone'; Name = 'vm-a'; Argv = @(); Expected = 'gone' }
    ) {
        if ($Argv.Count -gt 0) { Set-FakeProcess -ProcessId 5151 -Argv $Argv }
        else { $null = New-Item -ItemType Directory -Path (Join-Path $script:ProcRoot '5151') -Force; [IO.File]::WriteAllBytes((Join-Path $script:ProcRoot '5151/cmdline'), [byte[]]@()) }
        $identity = & $script:Module { param($Name) Get-KvmQemuProcessIdentity -ProcessId 5151 -VMName $Name } $Name
        $identity.Identity | Should -Be $Expected
        $gone = & $script:Module { Get-KvmQemuProcessIdentity -ProcessId 6161 -VMName 'vm-a' }
        $gone.Identity | Should -Be 'gone'
    }
}

Describe 'Rename-VM (KVM) -- positive stopped source' {
    BeforeEach {
        $script:VirshCalls = [System.Collections.Generic.List[string]]::new()
        $script:Keys = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Yuruna.Host Invoke-Virsh { $script:VirshCalls.Add(($VirshArgs -join ' ')); $global:LASTEXITCODE = 0; @() }
        Mock -ModuleName Yuruna.Host Format-YurunaOperatorMessage { $script:Keys.Add($Key); $Key }
    }

    It 'refuses without domrename when the source is <State> (<Raw>)' -ForEach @(
        @{ State = 'unknown'; Raw = '' }
        @{ State = 'running'; Raw = 'running' }
        @{ State = 'stopped'; Raw = 'paused' }
        @{ State = 'stopped'; Raw = 'in shutdown' }
        @{ State = 'stopped'; Raw = 'pmsuspended' }
        @{ State = 'stopped'; Raw = 'crashed' }
    ) {
        $script:SourceState = $State
        $script:SourceRaw = $Raw
        Mock -ModuleName Yuruna.Host Get-KvmDomainState {
            if ($VMName -eq 'src') { [pscustomobject]@{ State = $script:SourceState; Raw = $script:SourceRaw; Reason = 'observed' } }
            else { [pscustomobject]@{ State = 'absent'; Raw = ''; Reason = 'not-found' } }
        }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        $script:VirshCalls | Where-Object { $_ -like 'domrename*' } | Should -BeNullOrEmpty
        $script:Keys | Should -Contain 'host.kvm_rename_source_not_stopped'
        Should -Invoke -ModuleName Yuruna.Host Get-KvmDomainState -Times 1 -Exactly -ParameterFilter { $VMName -eq 'src' }
    }

    It 'refuses when the destination is unknown rather than absent' {
        Mock -ModuleName Yuruna.Host Get-KvmDomainState {
            if ($VMName -eq 'src') { [pscustomobject]@{ State = 'stopped'; Raw = 'shut off'; Reason = 'observed' } }
            else { [pscustomobject]@{ State = 'unknown'; Raw = ''; Reason = 'timeout' } }
        }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        $script:VirshCalls | Where-Object { $_ -like 'domrename*' } | Should -BeNullOrEmpty
    }

    It 'renames a positively stopped source onto a positively absent destination' {
        Mock -ModuleName Yuruna.Host Get-KvmDomainState {
            if ($VMName -eq 'src') { [pscustomobject]@{ State = 'stopped'; Raw = 'shut off'; Reason = 'observed' } }
            else { [pscustomobject]@{ State = 'absent'; Raw = ''; Reason = 'not-found' } }
        }
        $prior = & $script:Module { $script:VmRootDir }
        & $script:Module { param($Dir) $script:VmRootDir = $Dir } (Join-Path $script:TempRoot 'no-vms')
        try {
            Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false | Should -BeTrue
        } finally {
            & $script:Module { param($Dir) $script:VmRootDir = $Dir } $prior
        }
        $script:VirshCalls | Should -Contain 'domrename src dst'
    }
}

Describe 'Assert-Virtualization (KVM) -- idle socket activation' {
    BeforeEach {
        Mock -ModuleName Yuruna.Host Test-Path { $true } -ParameterFilter { $LiteralPath -eq '/dev/kvm' }
        $script:SocketState = 'active'
        $script:VirshExit = 0
        Mock -ModuleName Yuruna.Host systemctl {
            $unit = @($args)[1]
            if ($unit -eq 'libvirtd') { $global:LASTEXITCODE = 3; 'inactive' }
            elseif ($unit -eq 'libvirtd.socket') { $global:LASTEXITCODE = 0; $script:SocketState }
            else { $global:LASTEXITCODE = 4; 'unknown' }
        }
        Mock -ModuleName Yuruna.Host virsh { $global:LASTEXITCODE = $script:VirshExit }
    }

    It 'accepts an idle libvirtd behind a listening socket when the virsh round trip succeeds' {
        Assert-Virtualization | Should -BeTrue
    }

    It 'still fails when neither libvirtd nor its socket runs' {
        $script:SocketState = 'inactive'
        Assert-Virtualization | Should -BeFalse
    }

    It 'still fails when the round trip fails behind a listening socket' {
        $script:VirshExit = 1
        Assert-Virtualization | Should -BeFalse
    }
}
