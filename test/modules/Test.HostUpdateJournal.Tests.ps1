<#PSScriptInfo
.VERSION 2026.11.23
.GUID 422f924b-9a3d-47b0-80bd-5a0eadb72ff7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update journal pester
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
    Host updates in the request journal: the protocol file, admission and
    takeover, the controller's claim and continuation, phases, obligations,
    verdicts and tombstones, the release, and every repair reader held to
    the kind filter. Every case runs against a scratch private root on disk
    through the module's home seam, never the operator's.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRepair, Test.HostOperationJournal | Remove-Module -Force -ErrorAction SilentlyContinue
    # One instance of each primitive, shared by this suite and the modules
    # under test: a lock the suite takes must be the one the module checks.
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostOperationJournal.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRepair.psm1') -Force -Global -DisableNameChecking
    $script:Created = [System.Collections.Generic.List[string]]::new()
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'hu-journal'
    $script:Created.Add($script:ScratchBase)
    $script:JournalKind = 'host-operation.request-journal'
    $script:Snapshot = '0123456789abcdef'

    # The runner gate reader admission resolves by name; a test controls
    # its answer.
    $script:TestGate = @{ State = 'open'; RequestId = $null; Generation = '' }
    $gate = $script:TestGate
    ${function:global:Get-YurunaRunnerGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ State = $gate.State; RequestId = $gate.RequestId; Generation = $gate.Generation; Reason = 'test' }
    }.GetNewClosure()

    function Set-TestGate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: changes what the stubbed gate reader answers.')]
        param([string]$State = 'open', [string]$RequestId)
        $script:TestGate.State = $State
        $script:TestGate.RequestId = if ($RequestId) { $RequestId } else { $null }
    }

    function New-JournalHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch home and points the module at it.')]
        param()
        $dir = Join-Path $script:ScratchBase ('h-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
        $runtime = Join-Path $dir 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $script:Created.Add($dir)
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $dir
        Set-TestGate
        [pscustomobject]@{ Home = $dir; Runtime = $runtime; Root = (Join-Path $dir '.yuruna/host-repair') }
    }

    function Add-TestUpdate {
        param([Parameter(Mandatory)]$Fixture, [string]$RequestId, [string]$Channel = 'listener', [string]$Drain = 'after-cycle',
            [int]$DrainSeconds = 7200, [string]$ExpectCommit, [scriptblock]$UtcNow, [string]$Scope = 'restart')
        $id = if ($RequestId) { $RequestId } else { New-YurunaHostOperationRequestId }
        $arguments = @{ RequestId = $id; Channel = $Channel; Scope = $Scope; Drain = $Drain; DrainSeconds = $DrainSeconds; RuntimeDir = $Fixture.Runtime; HostType = 'host.ubuntu.kvm'; Confirm = $false }
        if ($ExpectCommit) { $arguments.ExpectCommit = $ExpectCommit }
        if ($UtcNow) { $arguments.UtcNow = $UtcNow }
        Request-HostUpdateAdmission @arguments
    }

    function Add-TestRepair {
        param([Parameter(Mandatory)]$Fixture, [string]$RequestId, [scriptblock]$UtcNow)
        $id = if ($RequestId) { $RequestId } else { New-YurunaHostOperationRequestId }
        $arguments = @{ RequestId = $id; Channel = 'listener'; Tier = 'restart'; RuntimeDir = $Fixture.Runtime; HostType = 'host.ubuntu.kvm'; Confirm = $false }
        if ($UtcNow) { $arguments.UtcNow = $UtcNow }
        Request-HostRepairAdmission @arguments
    }

    function Enter-TestLifetimeLock {
        param()
        Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
    }

    function Get-OwnStart {
        param([int]$ProcessId = $PID)
        & (Get-Module Test.HostOperationJournal) { param($p) Get-HostOperationProcessStartTime -ProcessId $p } $ProcessId
    }

    function Confirm-TestClaim {
        param([Parameter(Mandatory)][string]$RequestId, [int]$ControllerPid = $PID, [long]$StartTimeUnixMs = -1, [string]$Mode = 'claim')
        $start = if ($StartTimeUnixMs -ge 0) { $StartTimeUnixMs } else { Get-OwnStart -ProcessId $ControllerPid }
        $lock = Enter-TestLifetimeLock
        try {
            Confirm-HostUpdateClaim -RequestId $RequestId -LifetimeLock $lock -ControllerPid $ControllerPid -ControllerStartTimeUnixMs $start `
                -Snapshot $script:Snapshot -RepoRoot $script:RepoRoot -Mode $Mode -Confirm:$false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    function Get-TestJournal {
        param()
        (Read-HostOperationJournal).Journal
    }

    function Get-TestRow {
        param([Parameter(Mandatory)][string]$RequestId)
        $journal = Get-TestJournal
        if (-not $journal) { return $null }
        @($journal.requests | Where-Object { $_['requestId'] -ceq $RequestId })[0]
    }

    function Get-TestTombstone {
        param([Parameter(Mandatory)][string]$RequestId)
        @((Get-TestJournal).tombstones | Where-Object { $_['requestId'] -ceq $RequestId })[0]
    }

    function ConvertTo-TestJson {
        param($Value)
        ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    }

    function Edit-TestJournal {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: rewrites the scratch journal record directly.')]
        param([Parameter(Mandatory)][scriptblock]$Edit)
        $path = Get-YurunaHostRepairRequestPath
        $record = Read-YurunaCriticalRecord -Path $path -Kind $script:JournalKind -MaxBytes 4194304
        if ($record.Status -eq 'missing') {
            $payload = @{ schemaVersion = 2; writtenUtc = $null; owner = $null; requests = @(); reservations = @(); tombstones = @() }
            $generation = [long]0
        } elseif ($record.Status -eq 'ok') {
            $payload = $record.Payload
            $generation = [long]$record.Generation
        } else { throw "fixture journal unreadable: $($record.Status)" }
        & $Edit $payload
        $write = Write-YurunaCriticalRecord -Path $path -Kind $script:JournalKind -Payload $payload -ExpectedGeneration $generation -MaxBytes 4194304 -Confirm:$false
        if (-not $write.Committed) { throw "fixture journal not written: $($write.Reason)" }
    }

    function Add-TestRepairRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: injects a repair row beside a host update, which admission would refuse.')]
        param([Parameter(Mandatory)]$Fixture, [string]$State = 'queued')
        $id = New-YurunaHostOperationRequestId
        $row = & (Get-Module Test.HostOperationJournal) {
            param($RequestId, $Runtime, $State)
            $clock = Get-HostOperationClockValue
            $policy = Get-HostRepairPolicyRecord -Policy @{ tier = 'restart' } -Channel 'listener'
            New-HostRepairRequestRecord -RequestId $RequestId -Channel 'listener' -RuntimeDir $Runtime -HostType 'host.ubuntu.kvm' -Policy $policy -State $State -Clock $clock
        } $id $Fixture.Runtime $State
        Edit-TestJournal -Edit { param($p) $p['requests'] = [object[]](@($p['requests']) + $row) }.GetNewClosure()
        $id
    }

    function Start-TestSleeper {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a disposable process the suite owns and kills.')]
        param()
        $process = [System.Diagnostics.Process]::Start('/bin/sleep', '120')
        $script:Spawned.Add($process)
        $process
    }
}

AfterAll {
    foreach ($process in $script:Spawned) {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { $null = $_ }
    }
    & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
    Remove-Item -LiteralPath Function:\Get-YurunaRunnerGateState -ErrorAction SilentlyContinue
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

Describe 'the host-update protocol file' {
    It 'reads the protocol number without a final newline' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:RepoRoot 'test/host-update.protocol-version'))
        Assert-Equal 1 $bytes.Length 'the tracked file is one byte: no header, no final newline'
        Assert-Equal ([byte][char]'3') $bytes[0]
        Assert-Equal 3 (Get-HostUpdateProtocolVersion -RepoRoot $script:RepoRoot)
        $root = Join-Path $script:ScratchBase ('proto-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'test') -Force
        [IO.File]::WriteAllText((Join-Path $root 'test/host-update.protocol-version'), '7')
        Assert-Equal 7 (Get-HostUpdateProtocolVersion -RepoRoot $root)
        [IO.File]::WriteAllText((Join-Path $root 'test/host-update.protocol-version'), "12`n")
        Assert-Equal 12 (Get-HostUpdateProtocolVersion -RepoRoot $root) 'a trailing newline written by an editor still reads'
    }

    It 'answers -1 for a missing, empty or non-integer file: <Name>' -ForEach @(
        @{ Name = 'missing'; Content = $null }
        @{ Name = 'empty'; Content = '' }
        @{ Name = 'a word'; Content = 'one' }
        @{ Name = 'a fraction'; Content = '1.5' }
        @{ Name = 'a negative number'; Content = '-1' }
        @{ Name = 'too long'; Content = ('1' * 65) }
    ) {
        $root = Join-Path $script:ScratchBase ('proto-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'test') -Force
        if ($null -ne $Content) { [IO.File]::WriteAllText((Join-Path $root 'test/host-update.protocol-version'), $Content) }
        Assert-Equal -1 (Get-HostUpdateProtocolVersion -RepoRoot $root)
    }
}

Describe 'the controller lock and its private directory' {
    It 'resolves both under the private root, creating nothing under -NoCreate, and reads the lock state' {
        $fixture = New-JournalHome
        Assert-Null (Get-HostUpdateControllerLockPath -NoCreate)
        Assert-Null (Get-HostUpdateControllerRoot -NoCreate)
        Assert-Equal 'absent' (Get-HostUpdateControllerLockState) 'no private root yet is absent, never a binding error'
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna'))
        $lockPath = Get-HostUpdateControllerLockPath
        Assert-Equal (Join-Path $fixture.Root 'host-controller.lock') $lockPath
        Assert-Equal (Join-Path $fixture.Root 'host-controller') (Get-HostUpdateControllerRoot)
        Assert-True ([IO.Directory]::Exists((Join-Path $fixture.Root 'host-controller')))
        Assert-Equal 'absent' (Get-HostUpdateControllerLockState) 'no controller ever ran'
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 1500 -Metadata @{ purpose = 'host-controller' }
        try {
            Assert-True $lock.Held
            Assert-Null $lock.Rank 'the controller lock is outside the lock order'
            Assert-Equal 'held' (Get-HostUpdateControllerLockState)
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-Equal 'free' (Get-HostUpdateControllerLockState)
    }
}

Describe 'host-update admission' {
    It 'writes a queued host-update row with the closed request block and a host-update policy hash' {
        $fixture = New-JournalHome
        $id = New-YurunaHostOperationRequestId
        $admission = Add-TestUpdate -Fixture $fixture -RequestId $id -DrainSeconds 600 -ExpectCommit 'abc1234'
        Assert-Equal 'queued' $admission.Decision
        Assert-Equal 'queued' $admission.State
        Assert-Equal $id $admission.RequestId
        $read = Read-HostOperationJournal
        Assert-Equal 'ok' $read.Status 'the schema stays 2'
        Assert-Null $read.Journal.owner 'admission registers no owner; the claim does'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'host-update' $row['kind']
        Assert-Equal 'listener' $row['channel']
        Assert-Equal 'queued' $row['state']
        Assert-Equal $fixture.Runtime $row['runtimeDir']
        Assert-Equal 'host-update' $row['policy']['kind']
        Assert-Null $row['policy']['maxRung'] 'an older reader that indexes a repair policy key reads null'
        $text = 'host-update|restart|after-cycle|600|abc1234'
        $expected = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text)))).ToLowerInvariant()
        Assert-Equal $expected $row['policyHash']
        $update = $row['update']
        Assert-Equal 1 $update['schemaVersion']
        Assert-Equal 'restart' $update['request']['scope']
        Assert-Equal 'after-cycle' $update['request']['drain']
        Assert-Equal 600 $update['request']['drainSeconds']
        Assert-Equal 'abc1234' $update['request']['expectCommit']
        Assert-Equal 'drain,drainSeconds,expectCommit,scope' ((@($update['request'].Keys) | Sort-Object) -join ',') 'the request block is closed'
        Assert-Null $update['controller']
        Assert-Equal 0 @($row['obligations']).Count
        Assert-Equal 0 @($row['attempts']).Count
        $plain = Add-TestUpdate -Fixture $fixture -Channel local -Drain now
        Assert-Equal 'busy' $plain.Decision 'one host update at a time'
    }

    It 'refuses drain now on the <Channel> channel' -ForEach @(
        @{ Channel = 'listener'; Expected = 'policy-invalid' }
        @{ Channel = 'local'; Expected = 'queued' }
    ) {
        $fixture = New-JournalHome
        $id = New-YurunaHostOperationRequestId
        $admission = Add-TestUpdate -Fixture $fixture -RequestId $id -Channel $Channel -Drain now
        Assert-Equal $Expected $admission.Decision
        $row = Get-TestRow -RequestId $id
        if ($Expected -eq 'queued') { Assert-Equal 'now' $row['update']['request']['drain'] }
        else { Assert-Null $row 'a refused policy writes no row' }
    }

    It 'answers an existing id as already-active, completed or policy-mismatch, across kinds' {
        $fixture = New-JournalHome
        $repairId = New-YurunaHostOperationRequestId
        Assert-Equal 'spawn' (Add-TestRepair -Fixture $fixture -RequestId $repairId).Decision
        $null = Stop-HostRepairQueuedRequest -RequestId $repairId -Reason operator-canceled -Confirm:$false
        Assert-Equal 'policy-mismatch' (Add-TestUpdate -Fixture $fixture -RequestId $repairId).Decision 'a repair row under that id is another request'
        $id = New-YurunaHostOperationRequestId
        Assert-Equal 'queued' (Add-TestUpdate -Fixture $fixture -RequestId $id).Decision
        $replay = Add-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal 'already-active' $replay.Decision
        Assert-Equal 'queued' $replay.State
        Assert-Equal 'policy-mismatch' (Add-TestUpdate -Fixture $fixture -RequestId $id -DrainSeconds 900).Decision
        Assert-Equal 'policy-mismatch' (Add-TestUpdate -Fixture $fixture -RequestId $id -Channel local).Decision
        Assert-Equal 'policy-mismatch' (Add-TestRepair -Fixture $fixture -RequestId $id).Decision 'the repair never replays a host update'
        Assert-Null (Get-TestRow -RequestId $id)['launch'] 'the repair wrote no launch onto the host update'
        $claim = Confirm-TestClaim -RequestId $id
        Assert-True $claim.Accepted $claim.Reason
        Assert-Equal 'already-active' (Add-TestUpdate -Fixture $fixture -RequestId $id).Decision
        Assert-True (Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict updated_not_started -OperatorAction start_runner -Confirm:$false).Written
        $done = Add-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal 'completed' $done.Decision
        Assert-Equal 'updated_not_started' $done.Verdict
        Assert-Equal 'completed' $done.State
        Edit-TestJournal -Edit { param($p) $p['requests'] = [object[]]@($p['requests'] | Where-Object { $_['requestId'] -cne $id }) }.GetNewClosure()
        $fromTombstone = Add-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal 'completed' $fromTombstone.Decision 'the tombstone answers once the row is trimmed'
        Assert-Equal 'updated_not_started' $fromTombstone.Verdict
        Assert-Equal 'policy-mismatch' (Add-TestUpdate -Fixture $fixture -RequestId $id -DrainSeconds 900).Decision
        Assert-Equal 'policy-mismatch' (Add-TestRepair -Fixture $fixture -RequestId $id).Decision 'the tombstone keeps its kind'
    }

    It 'answers busy with the kind of the blocking row: <Case>' -ForEach @(
        @{ Case = 'a host update blocks a repair and a start-cycle' }
        @{ Case = 'a recovering repair blocks a host update' }
        @{ Case = 'a start-cycle blocks both' }
        @{ Case = 'a closed gate names its row' }
    ) {
        $fixture = New-JournalHome
        switch ($Case) {
            'a host update blocks a repair and a start-cycle' {
                $id = (Add-TestUpdate -Fixture $fixture).RequestId
                $repair = Add-TestRepair -Fixture $fixture
                Assert-Equal 'busy' $repair.Decision
                Assert-Equal 'host-update' $repair.ActiveKind
                Assert-Equal $id $repair.ActiveRequestId
                $reservation = Request-StartCycleReservation -OperationId (New-YurunaHostOperationRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
                Assert-Equal 'busy' $reservation.Decision
                Assert-Equal 'host-update' $reservation.ActiveKind
            }
            'a recovering repair blocks a host update' {
                $repairId = Add-TestRepairRow -Fixture $fixture -State 'recovery-pending'
                $update = Add-TestUpdate -Fixture $fixture
                Assert-Equal 'busy' $update.Decision
                Assert-Equal 'host-repair' $update.ActiveKind
                Assert-Equal $repairId $update.ActiveRequestId
                Assert-Equal 'recovery-pending' $update.State
            }
            'a start-cycle blocks both' {
                $reserved = Request-StartCycleReservation -OperationId (New-YurunaHostOperationRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
                Assert-Equal 'reserved' $reserved.Decision
                $update = Add-TestUpdate -Fixture $fixture
                Assert-Equal 'busy' $update.Decision
                Assert-Equal 'start-cycle' $update.ActiveKind
                Assert-Equal 'start-cycle' (Add-TestRepair -Fixture $fixture).ActiveKind
            }
            'a closed gate names its row' {
                $id = (Add-TestUpdate -Fixture $fixture).RequestId
                $null = Confirm-TestClaim -RequestId $id
                $null = Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict updated -OperatorAction none -Confirm:$false
                Set-TestGate -State closed -RequestId $id
                $repair = Add-TestRepair -Fixture $fixture
                Assert-Equal 'busy' $repair.Decision
                Assert-Equal 'host-update' $repair.ActiveKind
                Assert-Equal $id $repair.ActiveRequestId
                Assert-Equal 'host-update' (Request-StartCycleReservation -OperationId (New-YurunaHostOperationRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false).ActiveKind
                $update = Add-TestUpdate -Fixture $fixture
                Assert-Equal 'busy' $update.Decision
                Assert-Equal 'host-update' $update.ActiveKind
                Edit-TestJournal -Edit { param($p) $p['requests'] = [object[]]@($p['requests'] | Where-Object { $_['requestId'] -cne $id }) }.GetNewClosure()
                Assert-Equal 'host-update' (Add-TestRepair -Fixture $fixture).ActiveKind 'the tombstone still names the kind'
                Set-TestGate -State closed -RequestId (New-YurunaHostOperationRequestId)
                Assert-Equal 'host-repair' (Add-TestUpdate -Fixture $fixture).ActiveKind 'a gate naming no known row is a repair''s'
            }
        }
    }

    It 'refuses now while another host update is queued or running' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $now = Add-TestUpdate -Fixture $fixture -Channel local -Drain now
        Assert-Equal 'busy' $now.Decision
        Assert-Equal 'host-update' $now.ActiveKind
        Assert-Equal 'queued' $now.State
        $null = Confirm-TestClaim -RequestId $id
        $running = Add-TestUpdate -Fixture $fixture -Channel local -Drain now
        Assert-Equal 'busy' $running.Decision
        Assert-Equal 'running' $running.State
        Assert-Equal 1 @((Get-TestJournal).requests).Count 'nothing was queued beside it'
    }

    It 'takes over a recovering host update in one transaction and marks it superseded' {
        $fixture = New-JournalHome
        $old = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $old
        foreach ($obligation in @('gate', 'runner')) { Assert-True (Set-HostUpdateObligation -RequestId $old -ControllerPid $PID -ObligationId $obligation -State armed -Confirm:$false).Written }
        $null = Set-HostUpdatePhase -RequestId $old -ControllerPid $PID -Phase stop_runner -State started -Plan @{ start = $true; basis = 'resident-alive' } `
            -Reclaimed @{ outer = @{ pid = 4242; startTimeUnixMs = 1000 }; inner = @{ pid = 4343; startTimeUnixMs = 2000 } } -Confirm:$false
        Assert-True (Set-HostUpdateRecovering -RequestId $old -ControllerPid $PID -OperatorAction repair_checkout -Reason runner_start_failed -NextUnixMs 1 -Confirm:$false).Written
        Set-TestGate -State recovery-pending -RequestId $old
        $before = (Read-HostOperationJournal).Generation
        $new = New-YurunaHostOperationRequestId
        $admission = Add-TestUpdate -Fixture $fixture -RequestId $new
        Assert-Equal 'taken-over' $admission.Decision
        Assert-Equal $old $admission.SupersededId
        Assert-Equal 'queued' $admission.State
        Assert-Equal ($before + 1) (Read-HostOperationJournal).Generation 'one transaction'
        $oldRow = Get-TestRow -RequestId $old
        Assert-Equal 'completed' $oldRow['state']
        Assert-Equal 'superseded' $oldRow['verdict']
        Assert-Equal 'superseded' $oldRow['update']['verdict']
        Assert-Equal $new $oldRow['update']['supersededBy']
        foreach ($row in @($oldRow['obligations'])) {
            Assert-Equal 'disposed' $row['status']
            Assert-Equal 'superseded' $row['disposedBy']
        }
        $tombstone = Get-TestTombstone -RequestId $old
        Assert-Equal 'host-update' $tombstone['kind']
        Assert-Equal 'superseded' $tombstone['verdict']
        $newRow = Get-TestRow -RequestId $new
        Assert-Equal 'queued' $newRow['state']
        Assert-Equal 'gate,runner' ((@($newRow['obligations'] | Where-Object { $_['status'] -eq 'armed' } | ForEach-Object { $_['id'] }) | Sort-Object) -join ',')
        Assert-Equal 'resident-alive' $newRow['update']['runnerPlan']['basis']
        Assert-True ([bool]$newRow['update']['runnerPlan']['start'])
        Assert-Equal 4343 $newRow['update']['reclaimed']['inner']['pid'] 'the stopped identities travel with the plan'
        Assert-Equal 4242 $newRow['update']['reclaimed']['outer']['pid']
        Assert-Equal $old $newRow['update']['inheritedFrom']
        Assert-Equal $old $newRow['update']['inheritedGateRequestId']
    }

    It 'never expires a takeover row that holds armed obligations, and keeps it blocking and offered' {
        $fixture = New-JournalHome
        $t0 = [DateTimeOffset]::UtcNow
        $at = { $t0 }.GetNewClosure()
        $later = { $t0.AddMinutes(31) }.GetNewClosure()
        $old = (Add-TestUpdate -Fixture $fixture -UtcNow $at).RequestId
        $null = Confirm-TestClaim -RequestId $old
        foreach ($obligation in @('gate', 'runner')) { $null = Set-HostUpdateObligation -RequestId $old -ControllerPid $PID -ObligationId $obligation -State armed -Confirm:$false }
        $null = Set-HostUpdateRecovering -RequestId $old -ControllerPid $PID -OperatorAction repair_checkout -Reason protocol_mismatch -NextUnixMs 1 -UtcNow $at -Confirm:$false
        Set-TestGate -State recovery-pending -RequestId $old
        $new = New-YurunaHostOperationRequestId
        Assert-Equal 'taken-over' (Add-TestUpdate -Fixture $fixture -RequestId $new -UtcNow $at).Decision
        # Housekeeping runs in every transaction: an admission 31 minutes on
        # would expire an ordinary queued row.
        $third = Add-TestUpdate -Fixture $fixture -UtcNow $later
        Assert-Equal 'busy' $third.Decision 'the takeover row still blocks'
        Assert-Equal $new $third.ActiveRequestId
        $row = Get-TestRow -RequestId $new
        Assert-Equal 'queued' $row['state'] 'a row that owns the closed gate never expires'
        Assert-Equal 0 @($row['reasonCodes']).Count
        $blocking = & (Get-Module Test.HostOperationJournal) { param($r, $ms) Test-HostOperationRequestBlocking -Request $r -NowUnixMs $ms } $row ($t0.AddMinutes(31).ToUnixTimeMilliseconds())
        Assert-True $blocking 'blocking past the queued lifetime'
        Assert-Equal $new (Get-HostUpdateQueue -UtcNow $later).Queued['requestId'] 'a controller that comes back is offered it'
    }

    It 'leaves a recovering host update alone while the gate is closed under another request' {
        $fixture = New-JournalHome
        $old = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $old
        $null = Set-HostUpdateRecovering -RequestId $old -ControllerPid $PID -OperatorAction repair_checkout -Reason runner_start_failed -NextUnixMs 1 -Confirm:$false
        Set-TestGate -State closed -RequestId (New-YurunaHostOperationRequestId)
        $admission = Add-TestUpdate -Fixture $fixture
        Assert-Equal 'busy' $admission.Decision
        Assert-Equal 'host-update' $admission.ActiveKind
        Assert-Equal $old $admission.ActiveRequestId
        Assert-Equal 'recovery-pending' (Get-TestRow -RequestId $old)['state']
    }

    It 'maps every verdict to its terminal state and keeps the verdict in the tombstone: <Verdict>' -ForEach @(
        @{ Verdict = 'refused'; State = 'refused' }
        @{ Verdict = 'drain_timeout'; State = 'completed' }
        @{ Verdict = 'stop_failed'; State = 'completed' }
        @{ Verdict = 'released'; State = 'completed' }
        @{ Verdict = 'superseded'; State = 'completed' }
        @{ Verdict = 'failed_restored'; State = 'completed' }
        @{ Verdict = 'updated_not_started'; State = 'completed' }
        @{ Verdict = 'updated_with_remarks'; State = 'completed' }
        @{ Verdict = 'updated'; State = 'completed' }
    ) {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $done = Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict $Verdict -OperatorAction none -Remarks @('no_git_pull') -Debt @('listener') -Confirm:$false
        Assert-True $done.Written $done.Reason
        Assert-Equal $State $done.State
        $row = Get-TestRow -RequestId $id
        Assert-Equal $State $row['state']
        Assert-Equal $Verdict $row['verdict']
        Assert-Equal $Verdict $row['update']['verdict']
        Assert-Equal 'none' $row['update']['operatorAction']
        Assert-Equal 'no_git_pull' (@($row['update']['remarks']) -join ',')
        Assert-Equal 'start_listener' @($row['update']['debt'])[0]['action']
        $tombstone = Get-TestTombstone -RequestId $id
        Assert-Equal 'host-update' $tombstone['kind']
        Assert-Equal $State $tombstone['state']
        Assert-Equal $Verdict $tombstone['verdict']
        Assert-Equal 'completed' (Add-TestUpdate -Fixture $fixture -RequestId $id).Decision
    }

    It 'writes no verdict while the gate obligation is armed' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId gate -State armed -Confirm:$false
        $refused = Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict updated -OperatorAction none -Confirm:$false
        Assert-False $refused.Written
        Assert-Equal 'gate-armed' $refused.Reason
        Assert-Equal 'running' (Get-TestRow -RequestId $id)['state']
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId gate -State discharged -Evidence gate_open -Confirm:$false
        Assert-True (Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict updated -OperatorAction none -Confirm:$false).Written
    }

    It 'expires an unclaimed host update by housekeeping, keeps its kind in the tombstone and replays it as completed' {
        $fixture = New-JournalHome
        $t0 = [DateTimeOffset]::UtcNow
        $at = { $t0 }.GetNewClosure()
        $later = { $t0.AddMinutes(31) }.GetNewClosure()
        $id = (Add-TestUpdate -Fixture $fixture -UtcNow $at).RequestId
        $other = Add-TestUpdate -Fixture $fixture -UtcNow $later
        Assert-Equal 'queued' $other.Decision 'the expired row no longer blocks'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'refused' $row['state']
        Assert-Equal 'request-expired' (@($row['reasonCodes']) -join ',')
        $tombstone = Get-TestTombstone -RequestId $id
        Assert-Equal 'host-update' $tombstone['kind'] 'the expiry path writes the kind too'
        $replay = Add-TestUpdate -Fixture $fixture -RequestId $id -UtcNow $later
        Assert-Equal 'completed' $replay.Decision 'the same request under the same id is answered from its outcome'
        Assert-Equal 'refused' $replay.State
        Edit-TestJournal -Edit { param($p) $p['requests'] = [object[]]@($p['requests'] | Where-Object { $_['requestId'] -cne $id }) }.GetNewClosure()
        $fromTombstone = Add-TestUpdate -Fixture $fixture -RequestId $id -UtcNow $later
        Assert-Equal 'completed' $fromTombstone.Decision
        Assert-Equal 'refused' $fromTombstone.State
    }

    It 'leaves housekeeping expiry to old and new code alike and reports protocol_mismatch when blocked' {
        $fixture = New-JournalHome
        $t0 = [DateTimeOffset]::UtcNow
        $at = { $t0 }.GetNewClosure()
        $id = (Add-TestUpdate -Fixture $fixture -UtcNow $at).RequestId
        $blocked = Set-HostUpdateClaimBlocked -RequestId $id -Reason protocol_mismatch -UtcNow $at -Confirm:$false
        Assert-True $blocked.Written
        Assert-Equal 'written' $blocked.Reason
        Assert-Equal 'unchanged' (Set-HostUpdateClaimBlocked -RequestId $id -Reason protocol_mismatch -UtcNow $at -Confirm:$false).Reason
        Assert-Equal 'queued' (Get-TestRow -RequestId $id)['state'] 'a blocked row stays queued'
        # The repair's own transaction, as a process with an older module
        # would run it, expires the row with the same rule.
        $repair = Add-TestRepair -Fixture $fixture -UtcNow { $t0.AddMinutes(31) }.GetNewClosure()
        Assert-Equal 'spawn' $repair.Decision
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'refused' $row['state']
        Assert-Equal 'request-expired' (@($row['reasonCodes']) -join ',')
        Assert-Equal 'protocol_mismatch' $row['update']['claimBlocked'] 'the mark survives the expiry, so the public state names the cause'
        Assert-Equal 'host-update' (Get-TestTombstone -RequestId $id)['kind']
        $fixture2 = New-JournalHome
        $plain = (Add-TestUpdate -Fixture $fixture2 -UtcNow $at).RequestId
        $null = Add-TestUpdate -Fixture $fixture2 -UtcNow { $t0.AddMinutes(31) }.GetNewClosure()
        Assert-Null (Get-TestRow -RequestId $plain)['update']['claimBlocked'] 'an unblocked row expires without the mark'
        $claimed = (Add-TestUpdate -Fixture (New-JournalHome)).RequestId
        $null = Confirm-TestClaim -RequestId $claimed
        Assert-Equal 'state-mismatch' (Set-HostUpdateClaimBlocked -RequestId $claimed -Reason protocol_mismatch -Confirm:$false).Reason
    }
}

Describe 'the controller''s claim' {
    It 'continues a claim only when the recorded controller is dead or this process' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $noLock = Confirm-HostUpdateClaim -RequestId $id -LifetimeLock $null -ControllerPid $PID -ControllerStartTimeUnixMs (Get-OwnStart) `
            -Snapshot $script:Snapshot -RepoRoot $script:RepoRoot -Mode claim -Confirm:$false
        Assert-False $noLock.Accepted
        Assert-Equal 'lifetime-lock-not-held' $noLock.Reason
        Assert-Equal 'not-claimed' (Confirm-TestClaim -RequestId $id -Mode continue).Reason 'a queued row is claimed, not continued'
        $sleeper = Start-TestSleeper
        $sleeperStart = Get-OwnStart -ProcessId $sleeper.Id
        $claim = Confirm-TestClaim -RequestId $id -ControllerPid $sleeper.Id -StartTimeUnixMs $sleeperStart
        Assert-True $claim.Accepted $claim.Reason
        Assert-Equal 'accepted-claim' $claim.Reason
        $journal = Get-TestJournal
        Assert-Equal 'host-controller' $journal.owner['ownerId']
        Assert-Equal $fixture.Runtime $journal.owner['runtimeDir']
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'running' $row['state']
        Assert-Equal $sleeper.Id $row['update']['controller']['pid']
        Assert-Equal $script:Snapshot $row['update']['controller']['snapshot']
        Assert-NotNull $row['update']['claimedUtc']
        Assert-True ([long]$row['update']['bootEpochMs'] -gt 0)
        Assert-Equal 'not-queued' (Confirm-TestClaim -RequestId $id).Reason
        Assert-Equal 'controller-alive' (Confirm-TestClaim -RequestId $id -Mode continue).Reason 'a live controller keeps its claim'
        Edit-TestJournal -Edit { param($p) foreach ($r in @($p['requests'])) { if ($r['requestId'] -ceq $id) { $r['update']['controller']['startTimeUnixMs'] = $null } } }.GetNewClosure()
        Assert-Equal 'controller-alive' (Confirm-TestClaim -RequestId $id -Mode continue).Reason 'an unknown identity counts as alive'
        $sleeper.Kill()
        $sleeper.WaitForExit()
        $continue = Confirm-TestClaim -RequestId $id -Mode continue
        Assert-True $continue.Accepted $continue.Reason
        Assert-Equal 'accepted-continue' $continue.Reason
        $again = Confirm-TestClaim -RequestId $id -Mode continue
        Assert-True $again.Accepted 'the recorded controller is this process'
        $row = Get-TestRow -RequestId $id
        Assert-Equal $PID $row['update']['controller']['pid']
        Assert-Equal 0 $row['attempt'] 'a continuation is not an attempt'
        Assert-Equal 0 @($row['attempts']).Count
        $repairId = Add-TestRepairRow -Fixture $fixture
        Assert-Equal 'refused-other-kind' (Confirm-TestClaim -RequestId $repairId).Reason
    }

    It 'reads the claimed and the next queued host update without a lock' {
        $fixture = New-JournalHome
        $empty = Get-HostUpdateQueue
        Assert-Equal 'absent' $empty.Status
        Assert-Null $empty.Claimed
        $t0 = [DateTimeOffset]::UtcNow
        $first = (Add-TestUpdate -Fixture $fixture -UtcNow { $t0 }.GetNewClosure()).RequestId
        $queue = Get-HostUpdateQueue
        Assert-Equal 'ok' $queue.Status
        Assert-Equal $first $queue.Queued['requestId']
        Assert-Null $queue.Claimed
        Assert-Null (Get-HostUpdateQueue -UtcNow { $t0.AddMinutes(31) }.GetNewClosure()).Queued 'an expired row is never offered'
        $null = Confirm-TestClaim -RequestId $first
        $queue = Get-HostUpdateQueue
        Assert-Equal $first $queue.Claimed['requestId']
        Assert-Null $queue.Queued
        Assert-Equal $first (Get-HostUpdateRequest -RequestId $first)['requestId']
        $repairId = Add-TestRepairRow -Fixture $fixture
        Assert-Null (Get-HostUpdateRequest -RequestId $repairId) 'a repair is never read as a host update'
    }
}

Describe 'phases, obligations and ownership' {
    It 'records each phase start as an attempt, the runner plan once and stopped identities without clearing them' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $first = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -Child @{ pid = 77; startTimeUnixMs = 5; expiryTick = 9; bootEpochMs = 3; extra = 'x' } -Confirm:$false
        Assert-True $first.Written $first.Reason
        Assert-Equal 1 $first.Attempts
        Assert-Equal 2 (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -Confirm:$false).Attempts
        Assert-Equal 'outcome-missing' (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State finished -Confirm:$false).Reason
        $finished = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State finished -Outcome done -Remarks @('ring_held') `
            -Result @{ outcome = 'done'; reason = $null; protocol = 1; detail = @{ path = '/secret' }; stdout = 'text' } -Confirm:$false
        Assert-True $finished.Written
        $row = Get-TestRow -RequestId $id
        $entry = $row['update']['phases']['preflight']
        Assert-Equal 2 $entry['attempts']
        Assert-Equal 'finished' $entry['state']
        Assert-Equal 'done' $entry['outcome']
        Assert-Equal 'outcome,protocol' ((@($entry['result'].Keys) | Sort-Object) -join ',') 'only allow-listed scalar result fields reach the journal'
        Assert-Equal 'ring_held' (@($row['update']['remarks']) -join ',')
        Assert-Equal 'preflight' $row['update']['phase']
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase drain -State started -Drain @{ startedUnixMs = 1000 } -Confirm:$false
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase drain -State finished -Outcome done -Drain @{ startedUnixMs = 2000 } -Confirm:$false
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase stop_runner -State started -Plan @{ start = $false; basis = 'clean-exit' } `
            -Reclaimed @{ outer = @{ pid = 10; startTimeUnixMs = 1 }; cycle = $null; inner = @{ pid = 12; startTimeUnixMs = 3 } } -Confirm:$false
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase stop_runner -State finished -Outcome done -Plan @{ start = $true; basis = 'resident-alive' } `
            -Reclaimed @{ outer = $null; cycle = @{ pid = 11; startTimeUnixMs = 2 } } -Commit @{ before = 'abc1234'; after = 'not a sha' } -RunnerConsole none -Mutated -Confirm:$false
        $update = (Get-TestRow -RequestId $id)['update']
        Assert-Equal 1000 $update['drain']['startedUnixMs'] 'the drain start is journaled once'
        Assert-False ([bool]$update['runnerPlan']['start']) 'the first plan is kept'
        Assert-Equal 'clean-exit' $update['runnerPlan']['basis']
        Assert-Equal 10 $update['reclaimed']['outer']['pid'] 'a later null never clears a stopped identity'
        Assert-Equal 11 $update['reclaimed']['cycle']['pid']
        Assert-Equal 12 $update['reclaimed']['inner']['pid']
        Assert-Equal 'abc1234' $update['commit']['before']
        Assert-Null $update['commit']['after']
        Assert-Equal 'none' $update['runnerConsole']
        Assert-True ([bool]$update['mutated'])
        Assert-Equal 'stop_runner' $update['phase']
    }

    It 'records the console of a runner started on Windows, window, as well as tmux and none' -ForEach @(
        @{ Console = 'tmux' }, @{ Console = 'window' }, @{ Console = 'none' }
    ) {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase start_runner -State started -Confirm:$false
        $write = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase start_runner -State finished -Outcome done -RunnerConsole $Console -Confirm:$false
        Assert-True $write.Written $write.Reason
        Assert-Equal $Console (Get-TestRow -RequestId $id)['update']['runnerConsole']
    }

    It 'journals the full scope phases and keeps the install result fields the controller reads' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        foreach ($phase in @('install', 'upgrade_pwsh', 'enable')) {
            Assert-True (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase $phase -State started -Confirm:$false).Written $phase
        }
        $result = [ordered]@{ step = 'install'; attempt = 1; outcome = 'done'; restartRequired = $true; pwshChanged = $false; pwshUpgradePending = $true; detail = @{ log = '/x' } }
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State finished -Outcome done -Remarks @('install_issues') -Result $result -Confirm:$false
        $kept = (Get-TestRow -RequestId $id)['update']['phases']['install']['result']
        Assert-True ([bool]$kept['restartRequired']) 'restartRequired reaches the journal'
        Assert-True ([bool]$kept['pwshUpgradePending']) 'pwshUpgradePending reaches the journal'
        Assert-False ($kept.Contains('detail')) 'the detail stays in the private work folder'
        Assert-Equal 'install_issues' (@((Get-TestRow -RequestId $id)['update']['remarks']) -join ',')
    }

    It 'accepts the macOS reasons and remarks and refuses a token outside the lists' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -Confirm:$false
        $refused = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State finished -Outcome failed -Reason session_unusable -Confirm:$false
        Assert-True $refused.Written $refused.Reason
        Assert-Equal 'session_unusable' (Get-TestRow -RequestId $id)['update']['phases']['preflight']['reason']
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State started -Confirm:$false
        $failed = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State finished -Outcome failed -Reason clt_missing -Confirm:$false
        Assert-True $failed.Written $failed.Reason
        $remarked = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State finished -Outcome done -Remarks @('utm_upgrade_deferred', 'brew_update_failed') -Confirm:$false
        Assert-True $remarked.Written $remarked.Reason
        Assert-Equal 'utm_upgrade_deferred,brew_update_failed' (@((Get-TestRow -RequestId $id)['update']['remarks']) -join ',')
        $threw = $false
        try { $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State finished -Outcome done -Remarks @('utm_quit') -Confirm:$false } catch { $threw = $true }
        Assert-True $threw 'a remark outside the list is refused'
        $threw = $false
        try { $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase install -State finished -Outcome failed -Reason xcode_missing -Confirm:$false } catch { $threw = $true }
        Assert-True $threw 'a reason outside the list is refused'
    }

    It 'says on macOS that a controller the start step found <Result> is between two runs when the lock reads free or absent, and not known when it cannot be read' -ForEach @(
        @{ Result = 'running'; Arguments = @{} }
        @{ Result = 'started'; Arguments = @{ multiplexer = 'tmux'; attach = 'tmux -L yuruna-controller attach -t yuruna-controller' } }
    ) {
        $null = New-JournalHome
        $requestId = '4242aaaa-0000-4000-8000-000000000001'
        $render = { param($Key, $Values) & (Get-Module Test.HostOperationJournal) { param($k, $a) Format-YurunaOperatorMessage -Key $k -Arguments $a } $Key $Values }
        $line = & $render "runner.host_controller_start_$Result" $Arguments
        $start = [pscustomobject]@{ Result = $Result; Line = $line; LockState = 'held'; Multiplexer = $Arguments['multiplexer'] }
        $release = "pwsh test/lab/Invoke-HostUpdate.ps1 -Release $requestId"
        $expected = & $render 'runner.host_update_gate_controller_restarting_macos' @{ requestId = $requestId; release = $release }
        foreach ($lockState in @('free', 'absent')) {
            $text = Format-HostUpdateGateRefusal -RequestId $requestId -LockState $lockState -ControllerStart $start
            Assert-Equal -Expected $expected -Actual $text -Because "lock $lockState"
            Assert-False ($text.Contains($line)) 'the step line that saw a controller is not repeated after a line saying none runs'
        }
        Assert-True ($expected.Contains($release)) 'the release command is named'
        Assert-False ($expected -match 'system service') 'macOS has no service that starts a controller'
        # A lock that cannot be read shows neither a restart nor a missing
        # controller, so the line claims neither.
        $unknown = Format-HostUpdateGateRefusal -RequestId $requestId -LockState unknown -ControllerStart $start
        Assert-Equal -Expected (& $render 'runner.host_update_gate_controller_unknown_macos' @{ requestId = $requestId; release = $release }) -Actual $unknown 'an unreadable lock says the state is not known'
        Assert-True ($unknown.Contains($release)) 'the release command is named when the lock cannot be read'
        Assert-False ($unknown.Contains($line)) 'the step line that saw a controller is not repeated'
        $absent = Format-HostUpdateGateRefusal -RequestId $requestId -LockState free -ControllerStart ([pscustomobject]@{ Result = 'not_held'; Line = 'x'; LockState = 'free'; Multiplexer = 'tmux' })
        Assert-Equal -Expected (& $render 'runner.host_update_gate_controller_absent_macos' @{ requestId = $requestId; result = 'x'; release = $release }) -Actual $absent 'a step that saw no controller is repeated as before'
    }

    It 'keeps when the listener is expected back with the armed listener, also when it was armed before' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $first = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -ListenerExpectedBackUtc '2026-11-22T10:00:00.000Z' -Confirm:$false
        Assert-Equal 'written' $first.Reason
        Assert-Equal '2026-11-22T10:00:00.000Z' ([string](Get-TestRow -RequestId $id)['update']['listenerExpectedBackUtc'])
        $again = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -ListenerExpectedBackUtc '2026-11-22T10:20:00.000Z' -Confirm:$false
        Assert-Equal 'written' $again.Reason 'a later stop moves the time though the obligation was armed'
        Assert-Equal '2026-11-22T10:20:00.000Z' ([string](Get-TestRow -RequestId $id)['update']['listenerExpectedBackUtc'])
        Assert-Equal 'unchanged' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -Confirm:$false).Reason
    }

    # The page shows the stored time while the listener is armed, so a time
    # left from an earlier stop would come back, already past, on a re-arm
    # that has no estimate of its own.
    It 'drops when the listener is expected back once the listener is discharged, and a re-arm with no time keeps none' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -ListenerExpectedBackUtc '2026-11-22T10:00:00.000Z' -Confirm:$false
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State armed -Confirm:$false
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State discharged -Confirm:$false).Reason
        Assert-Equal '2026-11-22T10:00:00.000Z' ([string](Get-TestRow -RequestId $id)['update']['listenerExpectedBackUtc']) 'another obligation leaves the listener time alone'
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State discharged -Evidence listener-ready -Confirm:$false).Reason
        Assert-Null (Get-TestRow -RequestId $id)['update']['listenerExpectedBackUtc'] 'a discharged listener owes no time'
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -Confirm:$false).Reason
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'armed' @($row['obligations'] | Where-Object { $_['id'] -eq 'listener' })[0]['status']
        Assert-Null $row['update']['listenerExpectedBackUtc'] 'a re-arm with no time does not bring the earlier one back'
    }

    It 'drops when the listener is expected back once the listener is disposed' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State armed -ListenerExpectedBackUtc '2026-11-22T10:00:00.000Z' -Confirm:$false
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State disposed -Actor 'operator' -Evidence stop_failed -Confirm:$false).Reason
        Assert-Null (Get-TestRow -RequestId $id)['update']['listenerExpectedBackUtc'] 'a disposed listener owes no time'
    }

    It 'discharges the elevation of a release whose command removed the rule, so it is no debt' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        foreach ($obligation in @('gate', 'runner', 'elevation')) { $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId $obligation -State armed -Confirm:$false }
        $lock = Enter-TestLifetimeLock
        try { $released = Complete-HostUpdateRelease -RequestId $id -Actor 'operator' -LifetimeLock $lock -ElevationCleared -Confirm:$false }
        finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-True $released.Released $released.Reason
        Assert-Equal '' ($released.Debt -join ',')
        $elevation = @((Get-TestRow -RequestId $id)['obligations'] | Where-Object { $_['id'] -eq 'elevation' })[0]
        Assert-Equal 'discharged' $elevation['status']
    }

    It 'leaves the elevation of a release as debt when the rule was not removed' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture -Scope full).RequestId
        $null = Confirm-TestClaim -RequestId $id
        foreach ($obligation in @('gate', 'runner', 'elevation')) { $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId $obligation -State armed -Confirm:$false }
        $lock = Enter-TestLifetimeLock
        try { $released = Complete-HostUpdateRelease -RequestId $id -Actor 'operator' -LifetimeLock $lock -Confirm:$false }
        finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-Equal 'elevation' ($released.Debt -join ',')
        Assert-Equal 'remove_sudo_rule' @((Get-TestRow -RequestId $id)['update']['debt'])[0]['action']
    }

    It 'keeps the first journaled commit before a later source update attempt' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase update_source -State finished -Outcome done -Commit @{ before = 'aaaaaaa'; after = 'bbbbbbb' } -Confirm:$false
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase update_source -State finished -Outcome done -Commit @{ before = 'bbbbbbb'; after = 'ccccccc' } -Confirm:$false
        $commit = (Get-TestRow -RequestId $id)['update']['commit']
        Assert-Equal 'aaaaaaa' $commit['before'] 'the commit the host had before the update is kept'
        Assert-Equal 'ccccccc' $commit['after'] 'after follows the newest attempt'
    }

    It 'records the child of a started phase without counting another attempt' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $child = @{ pid = 77; startTimeUnixMs = 5; expiryTick = 9; bootEpochMs = 3 }
        Assert-Equal 'phase-not-started' (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -ChildOnly -Child $child -Confirm:$false).Reason
        Assert-Null (Get-TestRow -RequestId $id)['update']['phases']['preflight'] 'a refused child write adds no phase'
        Assert-Equal 'child-missing' (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -ChildOnly -Confirm:$false).Reason
        Assert-Equal 1 (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -Confirm:$false).Attempts
        $write = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -ChildOnly -Child $child -Confirm:$false
        Assert-True $write.Written $write.Reason
        Assert-Equal 1 $write.Attempts
        $entry = (Get-TestRow -RequestId $id)['update']['phases']['preflight']
        Assert-Equal 1 $entry['attempts']
        Assert-Equal 'started' $entry['state']
        Assert-Equal 77 $entry['child']['pid']
        Assert-Equal 9 $entry['child']['expiryTick']
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State finished -Outcome done -Confirm:$false
        Assert-Equal 'phase-not-started' (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -ChildOnly -Child $child -Confirm:$false).Reason 'a finished phase takes no child'
    }

    It 'refuses phase and obligation writes from a controller that does not own the row' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        Assert-Equal 'state-mismatch' (Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase preflight -State started -Confirm:$false).Reason 'an unclaimed row takes no phase'
        $null = Confirm-TestClaim -RequestId $id
        $before = ConvertTo-TestJson (Get-TestRow -RequestId $id)
        $stranger = $PID + 1
        Assert-Equal 'not-owner' (Set-HostUpdatePhase -RequestId $id -ControllerPid $stranger -Phase preflight -State started -Confirm:$false).Reason
        Assert-Equal 'not-owner' (Set-HostUpdateObligation -RequestId $id -ControllerPid $stranger -ObligationId gate -State armed -Confirm:$false).Reason
        Assert-Equal 'not-owner' (Set-HostUpdateRecovering -RequestId $id -ControllerPid $stranger -OperatorAction release -Reason runner_exited -NextUnixMs 1 -Confirm:$false).Reason
        Assert-Equal 'not-owner' (Complete-HostUpdate -RequestId $id -ControllerPid $stranger -Verdict updated -OperatorAction none -Confirm:$false).Reason
        Assert-Equal $before (ConvertTo-TestJson (Get-TestRow -RequestId $id)) 'nothing changed'
        $repairId = Add-TestRepairRow -Fixture $fixture -State 'running'
        Assert-Equal 'refused-other-kind' (Set-HostUpdatePhase -RequestId $repairId -ControllerPid $PID -Phase preflight -State started -Confirm:$false).Reason
        Assert-Equal 'refused-other-kind' (Set-HostUpdateObligation -RequestId $repairId -ControllerPid $PID -ObligationId gate -State armed -Confirm:$false).Reason
    }

    It 'arms, discharges and disposes an obligation, adding it when first armed and never changing a disposed one' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        Assert-Equal 'absent' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId listener -State discharged -Confirm:$false).Reason
        Assert-Equal 0 @((Get-TestRow -RequestId $id)['obligations']).Count
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State armed -Confirm:$false).Reason
        Assert-Equal 'unchanged' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State armed -Confirm:$false).Reason
        $row = @((Get-TestRow -RequestId $id)['obligations'])[0]
        Assert-Equal 'runner' $row['id']
        Assert-Equal 'host-update' $row['kind']
        Assert-Equal 'armed' $row['status']
        Assert-Equal 'written' (Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State disposed -Actor 'operator' -Evidence stop_failed -Confirm:$false).Reason
        $disposed = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State armed -Confirm:$false
        Assert-False $disposed.Written
        Assert-Equal 'disposed' $disposed.Reason
        $row = @((Get-TestRow -RequestId $id)['obligations'])[0]
        Assert-Equal 'disposed' $row['status']
        Assert-Equal 'operator' $row['disposedBy']
        Assert-Equal 'stop_failed' $row['evidence']
    }

    It 'marks a recovering update and keeps when it started recovering' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        Assert-True (Set-HostUpdateRecovering -RequestId $id -ControllerPid $PID -OperatorAction repair_checkout -Reason runner_start_failed -NextUnixMs 100 -Confirm:$false).Written
        $first = (Get-TestRow -RequestId $id)['update']['recovering']
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase recover -State started -Confirm:$false
        Assert-True (Set-HostUpdateRecovering -RequestId $id -ControllerPid $PID -OperatorAction act_at_host -Reason config_gate_failed -NextUnixMs 200 -Confirm:$false).Written
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'recovery-pending' $row['state']
        Assert-Equal 'recovering' $row['update']['verdict']
        Assert-Null $row['verdict'] 'recovering is not terminal'
        Assert-Equal $first['sinceUtc'] $row['update']['recovering']['sinceUtc']
        Assert-Equal 1 $row['update']['recovering']['attempts']
        Assert-Equal 200 $row['update']['recovering']['nextUnixMs']
        Assert-Equal 'act_at_host' $row['update']['operatorAction']
    }

    It 'accepts gate and elevation obligation ids in both copies of the pattern' {
        $patterns = foreach ($command in @('Set-HostRepairObligationState', 'Set-HostRepairObligationDisposition')) {
            @((Get-Command $command).Parameters['ObligationId'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] })[0].RegexPattern
        }
        Assert-StringEqual $patterns[0] $patterns[1] 'the two copies stay identical'
        foreach ($id in @('gate', 'elevation', 'runner', 'listener', 'controls', 'service:mirror', 'endpoint:web')) {
            Assert-True ($id -cmatch $patterns[0]) "$id is an obligation id"
        }
        foreach ($id in @('gates', 'Gate', 'elevation:x')) { Assert-False ($id -cmatch $patterns[0]) "$id is not" }
    }
}

Describe 'the release' {
    It 'marks a release once for a running controller and releases without one, listing what is still armed as debt' {
        $fixture = New-JournalHome
        $queued = (Add-TestUpdate -Fixture $fixture).RequestId
        Assert-Equal 'not-releasable' (Request-HostUpdateRelease -RequestId $queued -Actor 'operator' -Confirm:$false).Decision
        Assert-Equal 'not-found' (Request-HostUpdateRelease -RequestId (New-YurunaHostOperationRequestId) -Actor 'operator' -Confirm:$false).Decision
        $null = Confirm-TestClaim -RequestId $queued
        $mark = Request-HostUpdateRelease -RequestId $queued -Actor 'operator' -Confirm:$false
        Assert-Equal 'marked' $mark.Decision
        $requested = (Get-TestRow -RequestId $queued)['update']['release']
        Assert-Equal 'operator' $requested['by']
        Assert-Equal 'marked' (Request-HostUpdateRelease -RequestId $queued -Actor 'someone' -Confirm:$false).Decision
        Assert-Equal 'operator' (Get-TestRow -RequestId $queued)['update']['release']['by'] 'the first mark is kept'
        foreach ($obligation in @('gate', 'runner', 'listener')) { $null = Set-HostUpdateObligation -RequestId $queued -ControllerPid $PID -ObligationId $obligation -State armed -Confirm:$false }
        Assert-Equal 'lifetime-lock-not-held' (Complete-HostUpdateRelease -RequestId $queued -Actor 'operator' -LifetimeLock $null -Confirm:$false).Reason
        $lock = Enter-TestLifetimeLock
        try { $released = Complete-HostUpdateRelease -RequestId $queued -Actor 'operator' -LifetimeLock $lock -Confirm:$false }
        finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-True $released.Released $released.Reason
        Assert-Equal 'listener' ($released.Debt -join ',')
        $row = Get-TestRow -RequestId $queued
        Assert-Equal 'completed' $row['state']
        Assert-Equal 'released' $row['verdict']
        Assert-Equal 'start_listener' @($row['update']['debt'])[0]['action']
        foreach ($obligation in @($row['obligations'] | Where-Object { $_['id'] -in @('gate', 'runner') })) {
            Assert-Equal 'disposed' $obligation['status']
            Assert-Equal 'operator' $obligation['disposedBy']
        }
        Assert-Equal 'terminal' (Request-HostUpdateRelease -RequestId $queued -Actor 'operator' -Confirm:$false).Decision
    }
}

Describe 'the kind filter' {
    It 'holds every journal reader to the kind filter: <Reader>' -ForEach @(
        @{ Reader = 'repair admission under a host-update id' }
        @{ Reader = 'repair admission busy answer' }
        @{ Reader = 'start-cycle reservation' }
        @{ Reader = 'repair claim' }
        @{ Reader = 'repair resume' }
        @{ Reader = 'active-request lookup' }
        @{ Reader = 'blocking lookup default' }
        @{ Reader = 'repair result' }
        @{ Reader = 'launch outcome' }
        @{ Reader = 'queued-request stop' }
        @{ Reader = 'recovery record' }
        @{ Reader = 'obligation state' }
        @{ Reader = 'attempt completion' }
        @{ Reader = 'caller acknowledgment' }
        @{ Reader = 'dispose default selection' }
        @{ Reader = 'repair capability' }
        @{ Reader = 'queued-state projection' }
    ) {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId runner -State armed -Confirm:$false
        $repairId = Add-TestRepairRow -Fixture $fixture -State 'completed'
        $before = ConvertTo-TestJson (Get-TestRow -RequestId $id)
        switch ($Reader) {
            'repair admission under a host-update id' { Assert-Equal 'policy-mismatch' (Add-TestRepair -Fixture $fixture -RequestId $id).Decision }
            'repair admission busy answer' {
                $busy = Add-TestRepair -Fixture $fixture
                Assert-Equal 'busy' $busy.Decision
                Assert-Equal 'host-update' $busy.ActiveKind
            }
            'start-cycle reservation' { Assert-Equal 'host-update' (Request-StartCycleReservation -OperationId (New-YurunaHostOperationRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false).ActiveKind }
            'repair claim' {
                $lock = Enter-TestLifetimeLock
                try {
                    $generationBefore = (Read-HostOperationJournal).Generation
                    $claim = Confirm-HostRepairIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker @{ pid = $PID; startTimeUnixMs = (Get-OwnStart); ownerId = '1'; parent = $null } `
                        -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
                    Assert-Equal 'refused-other-kind' $claim.Reason
                    Assert-Equal $generationBefore (Read-HostOperationJournal).Generation 'nothing written'
                } finally { Exit-YurunaSingleFlightLock -Lock $lock }
            }
            'repair resume' {
                $lock = Enter-TestLifetimeLock
                try {
                    $worker = @{ pid = $PID; startTimeUnixMs = (Get-OwnStart); ownerId = '1'; parent = $null }
                    $resume = Confirm-HostRepairIntent -LifetimeLock $lock -Mode Resume -Worker $worker -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
                    Assert-Equal 'refused-no-request' $resume.Reason 'a resume finds no repair to adopt'
                    $named = Confirm-HostRepairIntent -LifetimeLock $lock -Mode Resume -RequestId $id -Worker $worker -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
                    Assert-Equal 'refused-other-kind' $named.Reason
                } finally { Exit-YurunaSingleFlightLock -Lock $lock }
            }
            'active-request lookup' {
                Assert-Null (Get-HostOperationActiveRequest) 'repairs only by default'
                Assert-Equal $id (Get-HostOperationActiveRequest -Kind any)['requestId']
                Assert-Equal $id (Get-HostOperationActiveRequest -Kind host-update)['requestId']
                $queuedRepair = Add-TestRepairRow -Fixture $fixture -State 'queued'
                Assert-Equal $queuedRepair (Get-HostOperationActiveRequest)['requestId']
            }
            'blocking lookup default' {
                $journal = Get-TestJournal
                $found = & (Get-Module Test.HostOperationJournal) { param($j) Get-HostOperationBlockingRequest -Journal $j -NowUnixMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) } $journal
                Assert-Equal $id $found['requestId'] 'admission and New see a host update block'
            }
            'repair result' {
                Assert-False (Get-HostRepairResult -RequestId $id).Found
                Assert-True (Get-HostRepairResult -RequestId $repairId).Found
                $null = Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict updated -OperatorAction none -Confirm:$false
                Edit-TestJournal -Edit { param($p) $p['requests'] = [object[]]@($p['requests'] | Where-Object { $_['requestId'] -cne $id }) }.GetNewClosure()
                Assert-False (Get-HostRepairResult -RequestId $id).Found 'nor from its tombstone'
                $before = $null
            }
            'launch outcome' { Assert-Equal 'refused-other-kind' (Set-HostRepairLaunchOutcome -RequestId $id -Outcome started -LauncherPid $PID -LauncherStartTimeUnixMs 1 -Confirm:$false).Reason }
            'queued-request stop' {
                $queuedId = (Add-TestUpdate -Fixture (New-JournalHome)).RequestId
                $stop = Stop-HostRepairQueuedRequest -RequestId $queuedId -Reason worker-refused -Detail 'identity-unknown' -Confirm:$false
                Assert-False $stop.Stopped
                Assert-Equal 'queued' (Get-TestRow -RequestId $queuedId)['state']
                $before = $null
            }
            'recovery record' { Assert-Equal 'refused-other-kind' (Save-HostRepairRecoveryRecord -RequestId $id -Generation ('0' * 32) -Recovery @{} -Obligation @() -Confirm:$false).Reason }
            'obligation state' { Assert-Equal 'refused-other-kind' (Set-HostRepairObligationState -RequestId $id -Generation ('0' * 32) -ObligationId @('runner') -State discharged -Confirm:$false).Reason }
            'attempt completion' {
                Assert-Equal 'refused-other-kind' (Complete-HostRepairAttempt -RequestId $id -Generation ('0' * 32) -Verdict repaired -Mutated $false -ReasonCode @() -RungResult @() -Confirm:$false).Reason
            }
            'caller acknowledgment' { Assert-False (Set-HostRepairCallerAck -RequestId $id -Readiness ready -CallerPid $PID -CallerStartTimeUnixMs 1 -Confirm:$false).Saved }
            'dispose default selection' {
                $default = Set-HostRepairObligationDisposition -ObligationId @('runner') -Actor 'operator' -Confirm:$false
                Assert-False $default.Saved
                Assert-Equal 0 @($default.Disposed).Count
                $named = Set-HostRepairObligationDisposition -ObligationId @('runner') -Actor 'operator' -RequestId $id -Confirm:$false
                Assert-False $named.Saved 'an explicit host-update id is refused'
            }
            'repair capability' {
                $journalPath = Get-YurunaHostRepairRequestPath
                Assert-Equal 'idle' (Get-HostRepairCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $journalPath).state 'repair.state reports repairs only'
                $null = Add-TestRepairRow -Fixture $fixture -State 'queued'
                Assert-Equal 'active' (Get-HostRepairCapability -HostType host.ubuntu.kvm -RepoRoot $script:RepoRoot -JournalPath $journalPath).state
            }
            'queued-state projection' {
                $queuedHome = New-JournalHome
                $queuedId = (Add-TestUpdate -Fixture $queuedHome).RequestId
                Assert-False (Publish-HostRepairQueuedState -RuntimeDir $queuedHome.Runtime -RequestId $queuedId -Channel listener -Confirm:$false)
                Assert-False (Test-Path -LiteralPath (Join-Path $queuedHome.Runtime 'host-repair.state.json')) 'no repair projection for a host update'
                $before = $null
            }
        }
        if ($null -ne $before) { Assert-Equal $before (ConvertTo-TestJson (Get-TestRow -RequestId $id)) 'the host-update row is untouched' }
    }

    It 'keeps a host-update row intact through ConvertTo-HostOperationJournal and a rewrite' {
        $fixture = New-JournalHome
        $id = (Add-TestUpdate -Fixture $fixture).RequestId
        $null = Confirm-TestClaim -RequestId $id
        $null = Set-HostUpdateObligation -RequestId $id -ControllerPid $PID -ObligationId gate -State armed -Confirm:$false
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase stop_runner -State finished -Outcome done -Remarks @('ring_held', 'no_git_pull') `
            -Plan @{ start = $true; basis = 'resident-alive' } -Reclaimed @{ outer = @{ pid = 10; startTimeUnixMs = 1 } } -Confirm:$false
        $raw = { (Read-YurunaCriticalRecord -Path (Get-YurunaHostRepairRequestPath) -Kind $script:JournalKind -MaxBytes 4194304).Payload }
        $original = @((& $raw)['requests'] | Where-Object { $_['requestId'] -ceq $id })[0]
        # A rewrite by repair code that knows nothing of host updates.
        $repairId = Add-TestRepairRow -Fixture $fixture -State 'queued'
        Assert-True (Set-HostRepairLaunchOutcome -RequestId $repairId -Outcome launch-failed -Confirm:$false).Saved 'a repair write rewrites the whole journal'
        $rewritten = @((& $raw)['requests'] | Where-Object { $_['requestId'] -ceq $id })[0]
        foreach ($key in @($original.Keys)) {
            if ($key -eq 'policy') { continue }
            Assert-Equal (ConvertTo-TestJson $original[$key]) (ConvertTo-TestJson $rewritten[$key]) "field $key survives"
        }
        Assert-Equal @($original.Keys).Count @($rewritten.Keys).Count 'no field is added or dropped'
        Assert-Equal 'host-update' $rewritten['policy']['kind']
        Assert-Equal 0 @($rewritten['policy']['restoreServiceVmName']).Count 'the injected repair arrays are empty and harmless'
        Assert-Equal 'ring_held,no_git_pull' (@($rewritten['update']['remarks']) -join ',')
    }
}
