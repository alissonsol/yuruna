<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42e5f6a7-8b9c-4d0e-af1a-2b3c4d5e6f7a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh request intent pester
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
    The host-refresh request journal: claim, retry and abandonment under the
    lifetime lock; admission decisions for every channel; expiry and
    tombstones against an injected clock; start-cycle reservations in both
    orders; legacy import; recovery records, obligations and dispositions;
    a real two-process admission race. Every case runs against a scratch
    private root on disk, never the operator's.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRefresh, Test.HostRefreshIntent | Remove-Module -Force -ErrorAction SilentlyContinue
    $script:IntentPath = Join-Path $here 'Test.HostRefreshIntent.psm1'
    # One instance of each primitive, shared by this suite and the module
    # under test: a lock the suite takes must be the one the module checks.
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module $script:IntentPath -Force -Global -DisableNameChecking
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Created = [System.Collections.Generic.List[string]]::new()
    # One temp directory per run (TMPDIR decides where), removed in AfterAll.
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'yuruna-host-refresh-intent'
    $script:Created.Add($script:ScratchBase)

    # The runner gate reader the admission path resolves by name. A test
    # controls its answer; removing it simulates a runner protocol that is
    # not loaded.
    $script:TestGate = @{ State = 'open'; RequestId = $null; Generation = '' }
    $gate = $script:TestGate
    ${function:global:Get-YurunaRefreshGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ State = $gate.State; RequestId = $gate.RequestId; Generation = $gate.Generation; Reason = 'test' }
    }.GetNewClosure()

    function Set-TestGate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: changes what the stubbed gate reader answers.')]
        param([string]$State = 'open', [string]$RequestId, [string]$Generation = '')
        $script:TestGate.State = $State
        $script:TestGate.RequestId = if ($RequestId) { $RequestId } else { $null }
        $script:TestGate.Generation = $Generation
    }

    function New-IntentHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch home and points the module at it.')]
        param()
        $dir = Join-Path $script:ScratchBase ('intent-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $runtime = Join-Path $dir 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $script:Created.Add($dir)
        & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $dir
        Set-TestGate
        [pscustomobject]@{ Home = $dir; Runtime = $runtime; Root = (Join-Path $dir '.yuruna/host-refresh') }
    }

    function Enter-TestLifetimeLock {
        param()
        Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
    }

    function Get-TestWorker {
        param([int]$ProcessId = $PID, [long]$StartTimeUnixMs = -1)
        $start = if ($StartTimeUnixMs -ge 0) { $StartTimeUnixMs } else { [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds() }
        @{ pid = $ProcessId; startTimeUnixMs = $start; ownerId = '1001'; parent = $null }
    }

    function Get-TestJournal {
        param()
        $read = Read-HostRefreshJournal
        $read.Journal
    }

    function Get-TestClock {
        param([DateTimeOffset]$At)
        $value = $At
        { $value }.GetNewClosure()
    }
}

AfterAll {
    Remove-Item -LiteralPath Function:\Get-YurunaRefreshGateState -ErrorAction SilentlyContinue
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

Describe 'paths and ids' {
    It 'creates nothing under -NoCreate and resolves the private files once created' {
        $fixture = New-IntentHome
        Assert-Null (Get-YurunaHostRefreshRequestPath -NoCreate) 'no root yet'
        Assert-Null (Get-YurunaHostRefreshLockPath -NoCreate)
        Assert-Null (Get-YurunaHostRefreshAdmissionLockPath -NoCreate)
        Assert-Null (Get-HostRefreshPrivateWorkDir -NoCreate)
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna')) 'a -NoCreate getter must not create the root'
        $journal = Get-YurunaHostRefreshRequestPath
        Assert-Equal (Join-Path $fixture.Root 'host-refresh.journal') $journal
        Assert-Equal (Join-Path $fixture.Root 'host-refresh.lock') (Get-YurunaHostRefreshLockPath)
        Assert-Equal (Join-Path $fixture.Root 'host-refresh.admission.lock') (Get-YurunaHostRefreshAdmissionLockPath)
        Assert-Equal (Join-Path $fixture.Root 'work') (Get-HostRefreshPrivateWorkDir)
        Assert-True ([IO.Directory]::Exists((Join-Path $fixture.Root 'work')))
        Assert-False ([IO.File]::Exists($journal)) 'the getter never creates the leaf'
    }

    It 'mints lowercase 8-4-4-4-12 ids that the authorization module accepts, with the same pattern' {
        $id = New-YurunaHostRefreshRequestId
        Assert-Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' $id
        $mine = & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshRequestIdPattern }
        $authModule = Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.HostRefreshAuth.psm1') -PassThru -Force -DisableNameChecking
        try {
            $theirs = & $authModule { $script:HostRefreshRequestIdPattern }
            Assert-StringEqual $theirs $mine 'the private copy must stay identical to the authorization module pattern'
            Assert-True (Test-YurunaHostRefreshRequestId -RequestId $id)
        } finally { Remove-Module $authModule -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the rung table private copy identical to the ladder declaration' {
        $mine = & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshRungOrder }
        $declared = & {
            $module = Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.HostRefresh.psm1') -PassThru -Force -DisableNameChecking
            try { @(Get-VirtualizationRepairRung -HostType host.ubuntu.kvm) } finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
        }
        Assert-Equal 8 $declared.Count
        foreach ($row in $declared) { Assert-Equal $row.Order $mine[$row.Name] "order of $($row.Name)" }
        Assert-Equal @($declared.Name).Count @($mine.Keys).Count
    }

    It 'retains tombstones longer than twice the longest remote proof lifetime plus skew' {
        $retentionMs = & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshTombstoneRetentionMs }
        Assert-True ($retentionMs -ge 2 * (300 + 60) * 1000)
    }
}

Describe 'Confirm-HostRefreshIntent: new local requests' {
    It 'accepts a new request under the lifetime lock, registers the owner and records the attempt' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-True $claim.Accepted
            Assert-Equal 'accepted-new' $claim.Reason
            Assert-Equal 1 $claim.Attempt
            Assert-Match '^[0-9a-f]{32}$' $claim.Generation
            $journal = Get-TestJournal
            Assert-Equal $fixture.Runtime $journal.owner['runtimeDir']
            $request = @($journal.requests)[0]
            Assert-Equal 'running' $request['state']
            Assert-Equal 'local' $request['channel']
            Assert-Equal 'restart-broker' $request['policy']['maxRung'] 'the ceiling is stored as the effective rung name'
            Assert-True ($journal.tombstones -is [System.Collections.IList]) 'zero tombstones stay a list'
            Assert-Equal 0 $journal.tombstones.Count
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'refuses without the lifetime lock held' {
        $fixture = New-IntentHome
        $claim = Confirm-HostRefreshIntent -LifetimeLock $null -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
            -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
        Assert-False $claim.Accepted
        Assert-Equal 'refused-lifetime-lock-not-held' $claim.Reason
    }

    It 'refuses a different request while one is unresolved, and admits it once the first completes' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $first = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $first -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $second = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
                -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-False $second.Accepted
            Assert-Equal 'refused-active-other-request' $second.Reason
            Assert-Equal $first $second.Request['requestId']
            $done = Complete-HostRefreshAttempt -RequestId $first -Generation $claim.Generation -Verdict 'already-healthy' -Mutated $false `
                -ReasonCode @('verified-noop') -RungResult @() -Confirm:$false
            Assert-True $done.Saved
            Assert-Equal 'completed' $done.State
            $third = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
                -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-True $third.Accepted
            $journal = Get-TestJournal
            Assert-Equal 1 $journal.tombstones.Count 'one tombstone is still a list of one'
            Assert-Equal $first $journal.tombstones[0]['requestId']
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'refuses a runtime other than the registered owner' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
                -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Complete-HostRefreshAttempt -RequestId $claim.Request['requestId'] -Generation $claim.Generation -Verdict 'already-healthy' -Mutated $false -ReasonCode @() -RungResult @() -Confirm:$false
            $other = Join-Path $fixture.Home 'other-runtime'
            $null = New-Item -ItemType Directory -Path $other
            $refused = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
                -Worker (Get-TestWorker) -RuntimeDir $other -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-False $refused.Accepted
            Assert-Equal 'refused-owner-mismatch' $refused.Reason
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }
}

Describe 'Confirm-HostRefreshIntent: retries, restoration and abandonment' {
    It 'retries the same request with an incremented attempt, restoration-only once an obligation is armed, and abandons after three' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $first = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $saved = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $first.Generation -Recovery @{ probe = @{ state = 'Unresponsive' } } `
                -Obligation @(@{ id = 'runner'; kind = 'runner'; target = 'runner' }) -Confirm:$false
            Assert-True $saved.Saved
            Assert-True $saved.FirstCapture
            $retry = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'accepted-retry' $retry.Reason 'a crashed worker with nothing armed is a plain retry'
            Assert-Equal 2 $retry.Attempt
            Assert-False $retry.RestorationOnly
            $armed = Set-HostRefreshObligationState -RequestId $id -Generation $retry.Generation -ObligationId @('runner') -State armed -Confirm:$false
            Assert-True $armed.Saved
            $observation = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $retry.Generation -Recovery @{ probe = @{ state = 'Responsive' } } -Obligation @() -Confirm:$false
            Assert-False $observation.FirstCapture 'a retry never replaces the original capture'
            $third = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Resume -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'accepted-restoration-retry' $third.Reason
            Assert-True $third.RestorationOnly
            Assert-Equal 3 $third.Attempt
            $fourth = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-False $fourth.Accepted
            Assert-Equal 'refused-attempts-exhausted' $fourth.Reason
            $request = Read-YurunaHostRefreshRequest -RequestId $id
            Assert-Equal 'abandoned' $request['state']
            Assert-Equal 'armed' (@($request['obligations'] | Where-Object { $_['id'] -eq 'runner' })[0]['status']) 'abandonment keeps the obligation'
            Assert-Equal 1 @($request['recovery']['observations']).Count
            Assert-Equal 'Unresponsive' $request['recovery']['probe']['state'] 'the original capture is kept'
            Assert-NotNull (Get-HostRefreshActiveRequest) 'an abandoned request with an armed obligation still blocks new work'
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'returns the stored verdict to a duplicate worker of a terminal request and replays nothing' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'repaired' -Mutated $true -ReasonCode @() -RungResult @() -Confirm:$false
            $again = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-False $again.Accepted
            Assert-Equal 'refused-terminal' $again.Reason
            Assert-Equal 'repaired' $again.StoredVerdict
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'derives the request state from the obligations, never from the verdict alone' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $claim.Generation -Recovery @{} `
                -Obligation @(@{ id = 'service:caching-proxy'; kind = 'service'; target = 'caching-proxy' }, @{ id = 'listener'; kind = 'listener'; target = 'listener' }) -Confirm:$false
            $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('service:caching-proxy') -State armed -Confirm:$false
            $done = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'failed' -Mutated $true -ReasonCode @('execution-error') `
                -RungResult @([pscustomobject]@{ name = 'restart-if-hung'; order = 3; outcome = 'failed'; reason = 'x' }) -OperatorAction 'resume-request' -Confirm:$false
            Assert-Equal 'recovery-pending' $done.State 'an armed obligation keeps the request recovery-pending whatever the verdict'
            $disposition = Set-HostRefreshObligationDisposition -ObligationId @('service:caching-proxy', 'listener') -Actor 'ytest' -Confirm:$false
            Assert-Equal 'service:caching-proxy' (@($disposition.Disposed) -join ',')
            Assert-Equal 'listener' (@($disposition.Unknown) -join ',') 'a pending obligation was never disrupted and cannot be disposed'
            Assert-Equal 0 $disposition.RemainingOutstanding
            Assert-Equal 'completed' $disposition.State
            $request = Read-YurunaHostRefreshRequest -RequestId $id
            Assert-Equal 'ytest' (@($request['obligations'] | Where-Object { $_['id'] -eq 'service:caching-proxy' })[0]['disposedBy'])
            $result = Get-HostRefreshResult -RequestId $id
            Assert-True $result.Found
            Assert-Equal 'failed' $result.Verdict
            Assert-Equal 1 $result.ExitCode
            Assert-True $result.Mutated
            Assert-Equal 0 @($result.OutstandingObligation).Count
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'keeps a running request open when its own live worker disposes the last obligation, and closes a crashed worker''s' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $claim.Generation -Recovery @{} -Obligation @(@{ id = 'service:stash'; kind = 'service'; target = 'stash' }) -Confirm:$false
            $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('service:stash') -State armed -Confirm:$false
            $own = Set-HostRefreshObligationDisposition -ObligationId @('service:stash') -Actor 'superseded-by-operator-intent' -RequestId $id -Confirm:$false
            Assert-Equal 'service:stash' (@($own.Disposed) -join ',')
            Assert-Equal 0 $own.RemainingOutstanding
            Assert-Equal 'running' $own.State 'the live worker is mid-attempt and completes it itself'
            $later = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('runner') -State armed -Confirm:$false
            Assert-True $later.Saved 'the attempt still writes under its generation'
            $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('runner') -State discharged -Confirm:$false
            $done = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'repaired' -Mutated $true -ReasonCode @() -RungResult @() -Confirm:$false
            Assert-Equal 'completed' $done.State
            Assert-Equal 'repaired' (Read-YurunaHostRefreshRequest -RequestId $id)['verdict']
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }

        $crashed = New-IntentHome
        $goneInfo = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $goneInfo.UseShellExecute = $false
        $goneInfo.CreateNoWindow = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')) { $goneInfo.ArgumentList.Add($argument) }
        $gone = [System.Diagnostics.Process]::Start($goneInfo)
        try {
            if (-not $gone.WaitForExit(10000)) { $gone.Kill(); throw 'The disposable worker did not exit within its bound.' }
            $gonePid = $gone.Id
        } finally { $gone.Dispose() }
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker -ProcessId $gonePid -StartTimeUnixMs 1000) `
                -RuntimeDir $crashed.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Save-HostRefreshRecoveryRecord -RequestId $id -Generation $claim.Generation -Recovery @{} -Obligation @(@{ id = 'service:stash'; kind = 'service'; target = 'stash' }) -Confirm:$false
            $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('service:stash') -State armed -Confirm:$false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        $disposed = Set-HostRefreshObligationDisposition -ObligationId @('service:stash') -Actor 'ytest' -Confirm:$false
        Assert-Equal 'completed' $disposed.State 'a crashed worker''s request closes once nothing is owed'
        Assert-Null (Get-HostRefreshActiveRequest) 'nothing blocks new work any more'
    }

    It 'refuses an obligation write for a stale generation' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $id = New-YurunaHostRefreshRequestId
            $null = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId $id -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $stale = Set-HostRefreshObligationState -RequestId $id -Generation ('0' * 32) -ObligationId @('runner') -State armed -Confirm:$false
            Assert-False $stale.Saved
            Assert-Equal 'generation-mismatch' $stale.Reason
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'refuses the claim, leaving the journal bytes unchanged, when the critical write does not commit' {
        $fixture = New-IntentHome
        $lock = Enter-TestLifetimeLock
        try {
            $null = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } `
                -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $path = Get-YurunaHostRefreshRequestPath
            $before = [IO.File]::ReadAllBytes($path)
            Mock -ModuleName Test.HostRefreshIntent Write-YurunaCriticalRecord { [pscustomobject]@{ Committed = $false; Generation = 0; Reason = 'io-error'; FlushesConfirmed = $false } }
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Resume -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-False $claim.Accepted
            Assert-Equal 'refused-journal-unavailable' $claim.Reason
            Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]][IO.File]::ReadAllBytes($path)))
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }
}

Describe 'Request-HostRefreshAdmission: decisions' {
    It 'spawns a new id as a queued request, then answers already-claimed while its launcher may still run' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $first = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'spawn' $first.Decision
        Assert-Equal 'queued' $first.State
        Assert-Equal 'restart-broker' $first.Ceiling
        $request = Read-YurunaHostRefreshRequest -RequestId $id
        Assert-Equal 'listener' $request['channel']
        Assert-Equal $PID $request['launch']['requesterPid']
        $again = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'already-claimed' $again.Decision 'the requester is alive and may still be launching'
        $explicit = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -MaxRung restart-broker -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'already-claimed' $explicit.Decision 'an explicit ceiling equal to the tier ceiling is the same policy'
    }

    It 'does not launch a second refresh while a detached Windows worker has not recorded its identity' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.windows.hyper-v -Confirm:$false
        $launch = [pscustomobject]@{ Platform = 'Windows'; LauncherPid = $PID; LauncherStartTimeUnixMs = 1L; FinalPid = $null; FinalStartTimeUnixMs = $null; Handshake = $null }
        Assert-True (Set-HostRefreshLaunchOutcome -RequestId $id -Outcome started -Launch $launch -Confirm:$false).Saved
        $again = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.windows.hyper-v -Confirm:$false
        Assert-Equal 'already-claimed' $again.Decision 'the dead hop is not the detached worker'
    }

    It 'makes a failed launch retryable with the same id' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        $outcome = Set-HostRefreshLaunchOutcome -RequestId $id -Outcome launch-failed -Confirm:$false
        Assert-True $outcome.Saved
        $retry = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'spawn' $retry.Decision
        Assert-Equal 'launch-not-running' $retry.Reason
        $other = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'busy' $other.Decision 'a queued request, launch-failed included, keeps the host'
        Assert-Equal 'host-refresh' $other.ActiveKind
        Assert-Equal $id $other.ActiveRequestId
    }

    It 'answers policy-mismatch for the same id with another ceiling or channel, even after completion' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -MaxRung start-if-stopped -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'policy-mismatch' (Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -MaxRung reclaim -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
        Assert-Equal 'policy-mismatch' (Request-HostRefreshAdmission -RequestId $id -Channel remote -Tier restart -MaxRung start-if-stopped -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
        $lock = Enter-TestLifetimeLock
        try {
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'accepted-claim' $claim.Reason
            $null = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'already-healthy' -Mutated $false -ReasonCode @() -RungResult @() -Confirm:$false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        $completed = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -MaxRung start-if-stopped -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'completed' $completed.Decision
        Assert-Equal 'already-healthy' $completed.Verdict
        Assert-Equal 'policy-mismatch' (Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
    }

    It 'answers stored for a refused request and never recreates it' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel remote -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        $stopped = Stop-HostRefreshQueuedRequest -RequestId $id -Reason operator-canceled -Confirm:$false
        Assert-True $stopped.Stopped
        $replay = Request-HostRefreshAdmission -RequestId $id -Channel remote -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'stored' $replay.Decision
        Assert-Equal 'refused' $replay.State
    }

    It 'spawns a running request whose worker is positively dead, and not one whose worker is alive or unknown' {
        $cases = @(
            @{ Start = 1L; Want = 'spawn'; Why = 'a live pid with another start time is a recycled pid' }
            @{ Start = -1L; Want = 'already-claimed'; Why = 'this process is alive' }
            @{ Start = 0L; Want = 'already-claimed'; Why = 'a record without a start time is unknown, treated as alive' }
        )
        foreach ($case in $cases) {
            $loop = New-IntentHome
            $id = New-YurunaHostRefreshRequestId
            $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $loop.Runtime -HostType host.ubuntu.kvm -Confirm:$false
            $lock = Enter-TestLifetimeLock
            try {
                $worker = Get-TestWorker -StartTimeUnixMs $case.Start
                if ($case.Start -eq 0) { $worker.startTimeUnixMs = $null }
                $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker $worker -RuntimeDir $loop.Runtime `
                    -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
                Assert-True $claim.Accepted
            } finally { Exit-YurunaSingleFlightLock -Lock $lock }
            $decision = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $loop.Runtime -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal $case.Want $decision.Decision $case.Why
        }
    }

    It 'spawns a recovery-pending request again with its id' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        $lock = Enter-TestLifetimeLock
        try {
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Set-HostRefreshObligationState -RequestId $id -Generation $claim.Generation -ObligationId @('runner') -State armed -Confirm:$false
            $null = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'partial' -Mutated $true -ReasonCode @() -RungResult @() -Confirm:$false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        $decision = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'spawn' $decision.Decision
        Assert-Equal 'recovery-pending' $decision.State
        $other = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'busy' $other.Decision
    }

    It 'follows the runner gate: busy while it is closed, unavailable when it is unreadable or its reader is missing' {
        $fixture = New-IntentHome
        Set-TestGate -State handoff -RequestId 'aaaaaaaa-0000-4000-8000-000000000001' -Generation 'x'
        $busy = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'busy' $busy.Decision
        Assert-Equal 'gate-handoff' $busy.Reason
        Set-TestGate -State unknown
        Assert-Equal 'unavailable' (Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
        $saved = ${function:global:Get-YurunaRefreshGateState}
        Remove-Item -LiteralPath Function:\Get-YurunaRefreshGateState
        try {
            $missing = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'unavailable' $missing.Decision
            Assert-Equal 'gate-reader-missing' $missing.Reason
        } finally { ${function:global:Get-YurunaRefreshGateState} = $saved }
    }

    It 'answers unavailable for a corrupt or newer journal, and for a runtime other than the owner' {
        $fixture = New-IntentHome
        $path = Get-YurunaHostRefreshRequestPath
        [IO.File]::WriteAllText($path, 'not a record')
        $corrupt = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'unavailable' $corrupt.Decision
        Assert-Match '^journal-' $corrupt.Reason
        Assert-Equal 'corrupt' (Read-HostRefreshJournal).Status
        Remove-Item -LiteralPath $path
        $null = Write-YurunaCriticalRecord -Path $path -Kind 'host-refresh.request-journal' -Payload @{ schemaVersion = 3 } -ExpectedGeneration 0 -Confirm:$false
        Assert-Equal 'unknown-version' (Read-HostRefreshJournal).Status
        Assert-Equal 'unavailable' (Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
    }

    It 'computes a decision under a held lock without writing, and refuses a lock it does not hold' {
        $fixture = New-IntentHome
        $null = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        $generation = (Read-HostRefreshJournal).Generation
        $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshAdmissionLockPath) -Rank (Get-YurunaLockRank -Name Admission) -WaitMilliseconds 2000
        try {
            $decision = Get-HostRefreshAdmissionDecision -RequestId (New-YurunaHostRefreshRequestId) -Channel automatic -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -AdmissionLock $lock
            Assert-Equal 'busy' $decision.Decision
            $admitted = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel automatic -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -AdmissionLock $lock -Confirm:$false
            Assert-Equal 'busy' $admitted.Decision 'a caller-held lock is used, not re-entered'
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-Equal $generation (Read-HostRefreshJournal).Generation 'a decision writes nothing'
        $foreign = Get-HostRefreshAdmissionDecision -RequestId (New-YurunaHostRefreshRequestId) -Channel automatic -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -AdmissionLock ([pscustomobject]@{ Held = $true; Handle = $null })
        Assert-Equal 'unavailable' $foreign.Decision
        Assert-Equal 'admission-lock-not-held' $foreign.Reason
    }

    It 'rejects a full tier and malformed ids at binding' {
        $fixture = New-IntentHome
        Assert-Throw { Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier full -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false }
        Assert-Throw { Request-HostRefreshAdmission -RequestId ([Guid]::NewGuid().ToString('N')) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false }
        Assert-Throw { Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId).ToUpperInvariant() -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false }
    }
}

Describe 'expiry, tombstones and the journal cap' {
    It 'expires an unclaimed queued request after 30 minutes, keeps its tombstone and answers stored' {
        $fixture = New-IntentHome
        $t0 = [DateTimeOffset]::new(2031, 5, 1, 12, 0, 0, [TimeSpan]::Zero)
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0) -Confirm:$false
        $early = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddMinutes(29)) -Confirm:$false
        Assert-Equal 'already-claimed' $early.Decision
        $late = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddMinutes(31)) -Confirm:$false
        Assert-Equal 'stored' $late.Decision
        $request = Read-YurunaHostRefreshRequest -RequestId $id
        Assert-Equal 'refused' $request['state']
        Assert-True (@($request['reasonCodes']) -contains 'request-expired')
        $new = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddMinutes(32)) -Confirm:$false
        Assert-Equal 'spawn' $new.Decision 'an expired request no longer holds the host'
    }

    It 'never expires or prunes anything when the clock runs behind' {
        $fixture = New-IntentHome
        $t0 = [DateTimeOffset]::new(2031, 5, 1, 12, 0, 0, [TimeSpan]::Zero)
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0) -Confirm:$false
        $behind = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddDays(-3)) -Confirm:$false
        Assert-Equal 'already-claimed' $behind.Decision 'a clock behind the creation time counts as age zero'
        $null = Stop-HostRefreshQueuedRequest -RequestId $id -Reason operator-canceled -UtcNow (Get-TestClock $t0) -Confirm:$false
        $null = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddDays(-10)) -Confirm:$false
        Assert-NotNull (@((Get-TestJournal).tombstones | Where-Object { $_['requestId'] -eq $id })[0])
        $null = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -UtcNow (Get-TestClock $t0.AddDays(2)) -Confirm:$false
        Assert-Null (@((Get-TestJournal).tombstones | Where-Object { $_['requestId'] -eq $id })[0]) 'an expired tombstone is pruned once the clock is past its retention'
    }

    It 'refuses admission with journal-full at the tombstone cap' {
        $fixture = New-IntentHome
        $path = Get-YurunaHostRefreshRequestPath
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $tombstones = foreach ($i in 1..512) {
            [ordered]@{ requestId = ('{0:x8}-0000-4000-8000-000000000000' -f $i); state = 'completed'; verdict = 'already-healthy'; policyHash = 'x'
                terminalUtc = ''; terminalUnixMs = $now; retainUntilUtc = ''; retainUntilUnixMs = $now + 86400000 }
        }
        $payload = [ordered]@{ schemaVersion = 2; writtenUtc = ''; owner = $null; requests = @(); reservations = @(); tombstones = [object[]]$tombstones }
        $null = Write-YurunaCriticalRecord -Path $path -Kind 'host-refresh.request-journal' -Payload $payload -ExpectedGeneration 0 -MaxBytes 4194304 -Confirm:$false
        $full = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'unavailable' $full.Decision
        Assert-Equal 'journal-full' $full.Reason
    }

    It 'keeps the full records of the last eight terminal requests' {
        $fixture = New-IntentHome
        foreach ($i in 1..10) {
            $id = New-YurunaHostRefreshRequestId
            $null = Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
            $null = Stop-HostRefreshQueuedRequest -RequestId $id -Reason operator-canceled -Confirm:$false
        }
        $journal = Get-TestJournal
        Assert-Equal 8 $journal.requests.Count
        Assert-Equal 10 $journal.tombstones.Count
    }
}

Describe 'legacy request import' {
    It 'imports the pre-journal request file as a tombstone once, and renames it instead of deleting it' {
        $fixture = New-IntentHome
        $null = Get-YurunaHostRefreshRequestPath
        $legacyId = [Guid]::NewGuid().ToString('N')
        $legacy = Join-Path $fixture.Root 'host-refresh.request.json'
        [IO.File]::WriteAllText($legacy, (@{ RequestId = $legacyId; Policy = @{ Tier = 'restart' }; State = 'completed'; Verdict = 'partial'; Attempt = 1 } | ConvertTo-Json -Compress))
        $read = Read-HostRefreshJournal
        Assert-Equal 'absent' $read.Status
        Assert-Equal 'legacy-unimported' $read.Reason
        $null = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-False ([IO.File]::Exists($legacy))
        Assert-True ([IO.File]::Exists((Join-Path $fixture.Root 'host-refresh.request.v1.json')))
        $tombstone = @((Get-TestJournal).tombstones | Where-Object { $_['requestId'] -eq $legacyId })
        Assert-Equal 1 $tombstone.Count
        Assert-Equal 'completed' $tombstone[0]['state']
        Assert-Equal 'partial' $tombstone[0]['verdict']
    }
}

Describe 'start-cycle reservations' {
    It 'makes a refresh busy while a reservation is held, and a reservation busy while a refresh is queued' {
        $fixture = New-IntentHome
        $operation = New-YurunaHostRefreshRequestId
        $reserved = Request-HostRefreshStartCycleReservation -OperationId $operation -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-Equal 'reserved' $reserved.Decision
        $refresh = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'busy' $refresh.Decision
        Assert-Equal 'start-cycle' $refresh.ActiveKind
        Assert-Equal $operation $refresh.ActiveRequestId
        $lock = Enter-TestLifetimeLock
        try {
            $preview = Confirm-HostRefreshStartCycleReservation -OperationId $operation -Generation $reserved.Generation -LifetimeLock $lock -Worker @{ pid = $PID; startTimeUnixMs = (Get-TestWorker).startTimeUnixMs } -WhatIf
            Assert-False $preview.Valid
            Assert-Equal 'preview' $preview.Reason
            Assert-Equal 'queued' @((Get-TestJournal).reservations)[0]['state'] 'a preview claims nothing'
            $confirm = Confirm-HostRefreshStartCycleReservation -OperationId $operation -Generation $reserved.Generation -LifetimeLock $lock -Worker @{ pid = $PID; startTimeUnixMs = (Get-TestWorker).startTimeUnixMs } -Confirm:$false
            Assert-True $confirm.Valid
            Assert-Equal 'running' @((Get-TestJournal).reservations)[0]['state']
            $newRefresh = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode New -RequestId (New-YurunaHostRefreshRequestId) -Policy @{ Tier = 'restart' } -Worker (Get-TestWorker) `
                -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'refused-start-cycle-active' $newRefresh.Reason
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-False (Complete-HostRefreshStartCycleReservation -OperationId $operation -Generation ('f' * 32) -Confirm:$false).Cleared 'only the matching generation clears'
        Assert-True (Complete-HostRefreshStartCycleReservation -OperationId $operation -Generation $reserved.Generation -Confirm:$false).Cleared
        $id = New-YurunaHostRefreshRequestId
        Assert-Equal 'spawn' (Request-HostRefreshAdmission -RequestId $id -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false).Decision
        $blocked = Request-HostRefreshStartCycleReservation -OperationId (New-YurunaHostRefreshRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-Equal 'busy' $blocked.Decision
        Assert-Equal 'host-refresh' $blocked.ActiveKind
    }

    It 'lets the detached Windows worker claim after its unacknowledged launch hop exits' {
        $fixture = New-IntentHome
        $operation = New-YurunaHostRefreshRequestId
        $reserved = Request-HostRefreshStartCycleReservation -OperationId $operation -RuntimeDir $fixture.Runtime -Confirm:$false
        $launch = [pscustomobject]@{ Platform = 'Windows'; LauncherPid = $PID; LauncherStartTimeUnixMs = 1L; FinalPid = $null; FinalStartTimeUnixMs = $null }
        Assert-True (Set-HostRefreshStartCycleLaunch -OperationId $operation -Generation $reserved.Generation -Outcome started -Launch $launch -Confirm:$false).Saved
        $lock = Enter-TestLifetimeLock
        try {
            $claim = Confirm-HostRefreshStartCycleReservation -OperationId $operation -Generation $reserved.Generation -LifetimeLock $lock -Worker (Get-TestWorker) -Confirm:$false
            Assert-True $claim.Valid $claim.Reason
            Assert-Equal 'running' @((Get-TestJournal).reservations)[0]['state']
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    It 'still clears a reservation after both acknowledged Windows identities are positively dead' {
        $fixture = New-IntentHome
        $operation = New-YurunaHostRefreshRequestId
        $reserved = Request-HostRefreshStartCycleReservation -OperationId $operation -RuntimeDir $fixture.Runtime -Confirm:$false
        $launch = [pscustomobject]@{ Platform = 'Windows'; LauncherPid = $PID; LauncherStartTimeUnixMs = 1L; FinalPid = $PID; FinalStartTimeUnixMs = 1L }
        Assert-True (Set-HostRefreshStartCycleLaunch -OperationId $operation -Generation $reserved.Generation -Outcome started -Launch $launch -Confirm:$false).Saved
        $next = Request-HostRefreshStartCycleReservation -OperationId (New-YurunaHostRefreshRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-Equal 'reserved' $next.Decision 'acknowledged dead workers do not retain the host'
        Assert-Equal 1 (Get-TestJournal).reservations.Count
    }

    It 'removes a reservation whose launch failed, and is busy while the runner gate is closed' {
        $fixture = New-IntentHome
        $operation = New-YurunaHostRefreshRequestId
        $reserved = Request-HostRefreshStartCycleReservation -OperationId $operation -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-True (Set-HostRefreshStartCycleLaunch -OperationId $operation -Generation $reserved.Generation -Outcome launch-failed -Confirm:$false).Saved
        Assert-Equal 0 (Get-TestJournal).reservations.Count
        Set-TestGate -State recovery-pending -RequestId 'aaaaaaaa-0000-4000-8000-000000000001' -Generation 'g'
        $gated = Request-HostRefreshStartCycleReservation -OperationId (New-YurunaHostRefreshRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-Equal 'busy' $gated.Decision
        Assert-Equal 'gate-recovery-pending' $gated.Reason
    }

    It 'clears a reservation whose requesting process died, by identity, and keeps a live one however old' {
        $fixture = New-IntentHome
        $script = @"
Import-Module '$($script:IntentPath)' -DisableNameChecking
& (Get-Module Test.HostRefreshIntent) { param(`$h) `$script:HostRefreshHomePath = `$h } '$($fixture.Home)'
function global:Get-YurunaRefreshGateState { param([string]`$RuntimeDir) [pscustomobject]@{ State = 'open'; RequestId = `$null; Generation = ''; Reason = 'test' } }
`$r = Request-HostRefreshStartCycleReservation -OperationId '4242aaaa-0000-4000-8000-000000000009' -RuntimeDir '$($fixture.Runtime)' -Confirm:`$false
if (`$r.Decision -eq 'reserved') { exit 0 } else { exit 3 }
"@
        $child = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script) -PassThru -Wait
        Assert-Equal 0 $child.ExitCode 'the child reserved the host'
        Assert-Equal 1 (Get-TestJournal).reservations.Count
        $refresh = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
        Assert-Equal 'spawn' $refresh.Decision 'the dead requester was cleared by identity'
        $null = Stop-HostRefreshQueuedRequest -RequestId $refresh.RequestId -Reason operator-canceled -Confirm:$false
        $live = Request-HostRefreshStartCycleReservation -OperationId (New-YurunaHostRefreshRequestId) -RuntimeDir $fixture.Runtime -Confirm:$false
        Assert-Equal 'reserved' $live.Decision
        $later = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm `
            -UtcNow (Get-TestClock ([DateTimeOffset]::UtcNow.AddDays(30))) -Confirm:$false
        Assert-Equal 'busy' $later.Decision 'age never clears a reservation whose owner is alive'
    }
}

Describe 'two processes racing for admission' {
    It 'admits exactly one of two simultaneous new requests, every time' {
        foreach ($round in 1..5) {
            $fixture = New-IntentHome
            $barrier = Join-Path $fixture.Home 'go'
            $children = foreach ($n in 1..2) {
                $out = Join-Path $fixture.Home "result.$n.txt"
                $script = @"
Import-Module '$($script:IntentPath)' -DisableNameChecking
& (Get-Module Test.HostRefreshIntent) { param(`$h) `$script:HostRefreshHomePath = `$h } '$($fixture.Home)'
function global:Get-YurunaRefreshGateState { param([string]`$RuntimeDir) [pscustomobject]@{ State = 'open'; RequestId = `$null; Generation = ''; Reason = 'test' } }
`$null = Get-YurunaHostRefreshAdmissionLockPath
while (-not [IO.File]::Exists('$barrier')) { Start-Sleep -Milliseconds 5 }
`$r = Request-HostRefreshAdmission -RequestId (New-YurunaHostRefreshRequestId) -Channel listener -Tier restart -RuntimeDir '$($fixture.Runtime)' -HostType host.ubuntu.kvm -AdmissionWaitMilliseconds 5000 -Confirm:`$false
[IO.File]::WriteAllText('$out', `$r.Decision)
"@
                Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script) -PassThru
            }
            Start-Sleep -Milliseconds 3000
            [IO.File]::WriteAllText($barrier, 'go')
            foreach ($child in $children) { $null = $child.WaitForExit(60000) }
            $decisions = @(1..2 | ForEach-Object { [IO.File]::ReadAllText((Join-Path $fixture.Home "result.$_.txt")) } | Sort-Object)
            Assert-Equal 'busy,spawn' ($decisions -join ',') "round $round"
        }
    }
}

Describe 'recovery record, caller acknowledgment and results' {
    It 'records a caller acknowledgment and reports the outcome by id and generation' {
        $fixture = New-IntentHome
        $id = New-YurunaHostRefreshRequestId
        $null = Request-HostRefreshAdmission -RequestId $id -Channel automatic -Tier restart -MaxRung start-if-stopped -RuntimeDir $fixture.Runtime -HostType host.ubuntu.kvm `
            -Context @{ configPath = '/x/test.config.yml'; callerOuter = @{ pid = 4242; startTimeUnixMs = 1 } } -Confirm:$false
        $lock = Enter-TestLifetimeLock
        try {
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $id -Worker (Get-TestWorker) -RuntimeDir $fixture.Runtime -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            $null = Complete-HostRefreshAttempt -RequestId $id -Generation $claim.Generation -Verdict 'repaired' -Mutated $true -ReasonCode @('reclaimed') -RungResult @() `
                -FinalProbe ([pscustomobject]@{ state = 'Responsive'; reason = 'responsive' }) -RunnerReadiness caller-parked -Handoff @{ tokenId = ('a' * 32); purpose = 'resident-outer' } -Confirm:$false
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Assert-True (Set-HostRefreshCallerAck -RequestId $id -Readiness ready -CallerPid 4242 -CallerStartTimeUnixMs 1 -Confirm:$false).Saved
        $request = Read-YurunaHostRefreshRequest -RequestId $id
        Assert-Equal 'ready' $request['callerAck']['readiness']
        Assert-Equal '/x/test.config.yml' $request['context']['configPath']
        $result = Get-HostRefreshResult -RequestId $id -Generation $claim.Generation
        Assert-True $result.Found
        Assert-Equal 'automatic' $result.Channel
        Assert-Equal 'Responsive' $result.FinalProbeState
        Assert-Equal 'caller-parked' $result.RunnerReadiness
        Assert-Equal 'resident-outer' $result.Handoff['purpose']
        Assert-Equal 0 $result.ExitCode
        Assert-False (Get-HostRefreshResult -RequestId $id -Generation ('0' * 32)).Found 'another generation is not this outcome'
    }
}

Describe 'automation grant subjects' {
    It 'records subjects, refuses an unverified one, updates duplicates and keeps the newest 32' {
        $null = New-IntentHome
        Assert-Equal 0 @(Get-YurunaHostRefreshAutomationSubject).Count
        Assert-False (Add-YurunaHostRefreshAutomationSubject -Subject 'uid=unknown;app=pwsh' -Confirm:$false).Saved
        foreach ($i in 1..34) { $null = Add-YurunaHostRefreshAutomationSubject -Subject "uid=501;app=$i" -Confirm:$false }
        $null = Add-YurunaHostRefreshAutomationSubject -Subject 'uid=501;app=34' -Confirm:$false
        $subjects = @(Get-YurunaHostRefreshAutomationSubject)
        Assert-Equal 32 $subjects.Count
        Assert-False ($subjects -contains 'uid=501;app=1')
        Assert-Equal 'uid=501;app=34' $subjects[-1]
        Assert-Equal 1 @($subjects | Where-Object { $_ -eq 'uid=501;app=34' }).Count
    }
}
