<#PSScriptInfo
.VERSION 2026.09.30
.GUID 421beeef-5850-4f6c-9d34-483ec197d700
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh progress publisher pester
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
    The public host-refresh progress file: the heartbeat keeps advancing
    during a long step, the terminal record is always the last write (a slow
    heartbeat can never land after it), a failed write degrades reporting
    without throwing, the projection carries only allowlisted fields, and
    the listener's queued projection is written only while the journal still
    holds its request as queued, so it never replaces a worker's.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRefresh, Test.HostRefreshIntent | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefreshIntent.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostRefresh.psm1') -Force -Global -DisableNameChecking
    $script:Created = [System.Collections.Generic.List[string]]::new()
    # One temp directory per run (TMPDIR decides where), removed in AfterAll.
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'yuruna-host-refresh-progress'
    $script:Created.Add($script:ScratchBase)
    $script:RequestId = '4242aaaa-0000-4000-8000-000000000001'
    $script:Generation = 'a' * 32

    function New-ScratchDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch directory under the private test area.')]
        param()
        $dir = Join-Path $script:ScratchBase ('progress-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script:Created.Add($dir)
        $dir
    }

    function Get-InitialSnapshot {
        param()
        @{
            requestId = $script:RequestId; generation = $script:Generation; attempt = 1; channel = 'local'; phase = 'claimed'; state = 'running'
            step = @{ index = 0; count = 8; name = ''; boundMs = 1000 }; reasonCodes = @(); reportDegraded = $false; mutated = $false
            verdict = ''; operatorAction = ''; terminalUtc = ''
        }
    }

    function Read-Projection {
        param([string]$Path)
        [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    }

    # A heartbeat writer that is slow on purpose, so a heartbeat is in flight
    # when the terminal record is written.
    $script:SlowWriter = Join-Path (New-ScratchDir) 'SlowStateFile.psm1'
    [IO.File]::WriteAllText($script:SlowWriter, @'
function Write-YurunaStateFileJson {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, $InputObject, [int]$Depth = 10, [bool]$Compress = $true, [switch]$WithBom)
    Start-Sleep -Milliseconds 150
    if (-not $PSCmdlet.ShouldProcess($Path, 'write')) { return $true }
    $copy = [ordered]@{}
    foreach ($key in $InputObject.Keys) { $copy[$key] = $InputObject[$key] }
    $copy['writer'] = 'heartbeat'
    $temp = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($copy | ConvertTo-Json -Compress -Depth $Depth))
    [IO.File]::Move($temp, $Path, $true)
    return $true
}
Export-ModuleMember -Function Write-YurunaStateFileJson
'@)
}

AfterAll {
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

Describe 'the heartbeat' {
    It 'keeps advancing, at most every five seconds, while the main thread sleeps through a long step' {
        $path = Join-Path (New-ScratchDir) 'host-refresh.state.json'
        $publisher = Start-HostRefreshProgressPublisher -Path $path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) -Confirm:$false
        try {
            Assert-True $publisher.Started
            $beats = [System.Collections.Generic.List[datetime]]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(12)
            while ([DateTime]::UtcNow -lt $deadline) {
                try {
                    $beat = [DateTime]::Parse((Read-Projection -Path $path)['heartbeatUtc'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
                    if ($beats.Count -eq 0 -or $beats[$beats.Count - 1] -ne $beat) { $beats.Add($beat) }
                } catch { $null = $_ }
                Start-Sleep -Milliseconds 250
            }
            Assert-True ($beats.Count -ge 3) "the heartbeat advanced $($beats.Count) times in 12 s"
            for ($i = 1; $i -lt $beats.Count; $i++) {
                Assert-True (($beats[$i] - $beats[$i - 1]).TotalSeconds -le 6) 'no gap longer than the heartbeat period plus one second'
            }
            $projection = Read-Projection -Path $path
            Assert-True ([long]$projection['remainingBudgetMs'] -gt 0)
        } finally {
            $null = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'already-healthy'; state = 'completed' } -Confirm:$false
        }
    }
}

Describe 'the terminal record' {
    It 'is always the last write, however slow a heartbeat in flight is' {
        foreach ($iteration in 1..50) {
            $path = Join-Path (New-ScratchDir) 'host-refresh.state.json'
            $publisher = Start-HostRefreshProgressPublisher -Path $path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) `
                -PeriodMilliseconds 1000 -WriterModulePath $script:SlowWriter -Confirm:$false
            $null = Update-HostRefreshProgress -Publisher $publisher -Change @{ phase = 'climbing'; step = @{ index = 2; count = 8; name = 'reclaim'; boundMs = 5000 } } -Confirm:$false
            $stop = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'repaired'; state = 'completed'; mutated = $true } -Confirm:$false
            Assert-True $stop.TerminalWritten "iteration $iteration"
            $afterStop = [IO.File]::GetLastWriteTimeUtc($path)
            $projection = Read-Projection -Path $path
            Assert-Equal 'terminal' $projection['phase'] "iteration $iteration"
            Assert-Equal 'repaired' $projection['verdict']
            Assert-False $projection.ContainsKey('writer') 'the terminal record is the main thread''s, not a heartbeat'
            if ($iteration % 10 -eq 0) {
                Start-Sleep -Milliseconds 1500
                Assert-Equal $afterStop ([IO.File]::GetLastWriteTimeUtc($path)) 'nothing writes after the terminal record'
            }
            Assert-False (Update-HostRefreshProgress -Publisher $publisher -Change @{ phase = 'climbing' } -Confirm:$false) 'a stopped publisher accepts no change'
        }
    }
}

Describe 'degraded reporting' {
    It 'marks the publisher degraded and never throws when the file cannot be written' {
        $path = Join-Path (Join-Path (New-ScratchDir) 'missing-dir') 'host-refresh.state.json'
        $publisher = Start-HostRefreshProgressPublisher -Path $path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) -PeriodMilliseconds 1000 -Confirm:$false
        Assert-True $publisher.Sync.Degraded 'the initial write already failed'
        Assert-True (Update-HostRefreshProgress -Publisher $publisher -Change @{ phase = 'probing' } -Confirm:$false) 'progress is still accepted'
        $stop = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'repaired'; state = 'completed' } -Confirm:$false
        Assert-False $stop.TerminalWritten
        Assert-True $stop.ReportDegraded
    }

    It 'returns $false from an update when the state gate does not open' {
        $path = Join-Path (New-ScratchDir) 'host-refresh.state.json'
        $publisher = Start-HostRefreshProgressPublisher -Path $path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) -Confirm:$false
        try {
            $null = $publisher.Sync.StateGate.Wait()
            try {
                Assert-False (Update-HostRefreshProgress -Publisher $publisher -Change @{ phase = 'probing' } -Confirm:$false)
            } finally { $null = $publisher.Sync.StateGate.Release() }
            Assert-True (Update-HostRefreshProgress -Publisher $publisher -Change @{ phase = 'probing' } -Confirm:$false)
        } finally {
            $null = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'already-healthy'; state = 'completed' } -Confirm:$false
        }
    }

    It 'reports degraded in the terminal record once any heartbeat failed' {
        $dir = New-ScratchDir
        $path = Join-Path $dir 'host-refresh.state.json'
        $publisher = Start-HostRefreshProgressPublisher -Path $path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) -Confirm:$false
        $publisher.Sync.Degraded = $true
        $stop = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'repaired'; state = 'completed' } -Confirm:$false
        Assert-True $stop.TerminalWritten
        Assert-True $stop.ReportDegraded
        Assert-True ((Read-Projection -Path $path)['reportDegraded'])
    }
}

Describe 'ConvertTo-HostRefreshPublicState' {
    It 'copies only allowlisted fields, in wire spelling, and drops everything private' {
        $projection = ConvertTo-HostRefreshPublicState -Snapshot @{
            requestId = $script:RequestId; generation = $script:Generation; attempt = 2; channel = 'automatic'; phase = 'converging'; state = 'recovery-pending'
            verdict = 'still-unresponsive'; operatorAction = 'resume-request'; mutated = $true; reportDegraded = $false
            reasonCodes = @('deadline-exhausted', 'Service-Unverified', 'bad code!', $null)
            step = @{ index = 3; count = 8; name = 'restart-if-hung'; boundMs = 12000; command = 'sudo x' }
            diagnostic = 'OSStatus -1743'; runtimeDir = '/home/u/runtime'; pid = 31337; vmName = 'yuruna-caching-proxy'; command = @('kill', '-9')
        }
        Assert-Equal ('schemaVersion,requestId,generation,attempt,channel,phase,state,heartbeatUtc,startedUtc,updatedUtc,step,remainingBudgetMs,' +
            'reasonCodes,reportDegraded,mutated,verdict,operatorAction,terminalUtc') (@($projection.Keys) -join ',')
        Assert-Equal 'recovery_pending' $projection.state
        Assert-Equal 'still_unresponsive' $projection.verdict
        Assert-Equal 'resume_request' $projection.operatorAction
        Assert-Equal 'deadline_exhausted,service_unverified' ($projection.reasonCodes -join ',')
        Assert-Equal 'index,count,name,boundMs' (@($projection.step.Keys) -join ',')
        Assert-Equal 'restart-if-hung' $projection.step.name 'rung names keep their spelling'
        $json = ConvertTo-Json -InputObject $projection -Compress -Depth 5
        foreach ($secret in @('OSStatus', '/home/u', '31337', 'yuruna-caching-proxy', 'kill', 'sudo')) { Assert-False ($json.Contains($secret)) "leaked $secret" }
    }

    It 'caps reason codes at 24, rejects malformed ids and enum values, and stays small' {
        $codes = foreach ($i in 1..40) { "code-$i" }
        $projection = ConvertTo-HostRefreshPublicState -Snapshot @{ requestId = 'NOT-A-UUID'; generation = 'xyz'; channel = 'email'; phase = 'dancing'; state = 'odd'; verdict = 'great'; reasonCodes = $codes }
        Assert-Equal 24 $projection.reasonCodes.Count
        Assert-Equal '' $projection.requestId
        Assert-Equal '' $projection.generation
        Assert-Equal 'local' $projection.channel
        Assert-Equal 'starting' $projection.phase
        Assert-Equal '' $projection.verdict
        Assert-True ((ConvertTo-Json -InputObject $projection -Compress -Depth 5).Length -le 2048)
    }
}

Describe 'Publish-HostRefreshQueuedState' {
    BeforeAll {
        # Admission resolves the runner gate by name; the stand-in answers
        # open so a fresh request is admitted as queued.
        ${function:global:Get-YurunaRefreshGateState} = {
            param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
            $null = $RuntimeDir, $TokenId, $PrivateRoot
            [pscustomobject]@{ State = 'open'; RequestId = $null; Generation = ''; Reason = 'test' }
        }

        function New-QueuedHome {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch home and runtime and points the journal module at them.')]
            param()
            $homeDir = New-ScratchDir
            $runtime = Join-Path $homeDir 'runtime'
            $null = New-Item -ItemType Directory -Path $runtime
            & (Get-Module Test.HostRefreshIntent) { param($h) $script:HostRefreshHomePath = $h } $homeDir
            [pscustomobject]@{ Home = $homeDir; Runtime = $runtime; Path = (Join-Path $runtime 'host-refresh.state.json') }
        }

        function Add-QueuedRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: admits a request into the scratch journal.')]
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$RequestId)
            $admitted = Request-HostRefreshAdmission -RequestId $RequestId -Channel listener -Tier restart -RuntimeDir $Fixture.Runtime -HostType host.ubuntu.kvm -Confirm:$false
            Assert-Equal 'spawn' $admitted.Decision
        }
    }
    AfterAll {
        & (Get-Module Test.HostRefreshIntent) { $script:HostRefreshHomePath = $null }
        Remove-Item -LiteralPath Function:\Get-YurunaRefreshGateState -ErrorAction SilentlyContinue
    }

    It 'writes a queued projection with no generation and no byte-order mark' {
        $fixture = New-QueuedHome
        Add-QueuedRequest -Fixture $fixture -RequestId $script:RequestId
        Assert-True (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $script:RequestId -Channel listener -Confirm:$false)
        $bytes = [IO.File]::ReadAllBytes($fixture.Path)
        Assert-False ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $projection = Read-Projection -Path $fixture.Path
        Assert-Equal 'queued' $projection['phase']
        Assert-Equal 'queued' $projection['state']
        Assert-Equal '' $projection['generation']
        Assert-Equal 0 $projection['attempt']
        Assert-Equal 'listener' $projection['channel']
    }

    It 'never replaces a projection the worker already published for the same request' {
        $fixture = New-QueuedHome
        Add-QueuedRequest -Fixture $fixture -RequestId $script:RequestId
        $publisher = Start-HostRefreshProgressPublisher -Path $fixture.Path -Initial (Get-InitialSnapshot) -ExpiryTick ([Environment]::TickCount64 + 900000) -Confirm:$false
        $null = Stop-HostRefreshProgressPublisher -Publisher $publisher -Terminal @{ verdict = 'repaired'; state = 'completed' } -Confirm:$false
        Assert-True (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $script:RequestId -Channel listener -Confirm:$false)
        Assert-Equal 'terminal' (Read-Projection -Path $fixture.Path)['phase']
        $null = Stop-HostRefreshQueuedRequest -RequestId $script:RequestId -Reason operator-canceled -Confirm:$false
        $next = '4242bbbb-0000-4000-8000-000000000002'
        Add-QueuedRequest -Fixture $fixture -RequestId $next
        Assert-True (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $next -Channel remote -Confirm:$false)
        Assert-Equal 'queued' (Read-Projection -Path $fixture.Path)['phase'] 'a new request replaces an old terminal projection'
    }

    It 'publishes nothing once the journal no longer holds the request as queued, even with no projection on disk' {
        $fixture = New-QueuedHome
        Add-QueuedRequest -Fixture $fixture -RequestId $script:RequestId
        $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
        try {
            $worker = @{ pid = $PID; startTimeUnixMs = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds(); ownerId = '1001'; parent = $null }
            $claim = Confirm-HostRefreshIntent -LifetimeLock $lock -Mode Claim -RequestId $script:RequestId -Worker $worker -RuntimeDir $fixture.Runtime `
                -RepoRoot $script:RepoRoot -HostType host.ubuntu.kvm -Confirm:$false
            Assert-True $claim.Accepted $claim.Reason
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        # The worker claimed under the admission lock and publishes after its
        # claim, so a queued write arriving now could only land on top of the
        # worker's own projection.
        Assert-True (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $script:RequestId -Channel listener -Confirm:$false) 'the worker owns the projection'
        Assert-False ([IO.File]::Exists($fixture.Path)) 'nothing was written for a claimed request'
    }

    It 'publishes nothing for an unknown request or while the admission lock is held' {
        $fixture = New-QueuedHome
        Add-QueuedRequest -Fixture $fixture -RequestId $script:RequestId
        Assert-False (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId '4242cccc-0000-4000-8000-000000000003' -Channel listener -Confirm:$false)
        $held = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostRefreshAdmissionLockPath) -Rank (Get-YurunaLockRank -Name Admission) -WaitMilliseconds 1000
        try {
            Assert-True $held.Held
            Assert-False (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $script:RequestId -Channel listener -AdmissionWaitMilliseconds 0 -Confirm:$false)
        } finally { Exit-YurunaSingleFlightLock -Lock $held }
        Assert-False ([IO.File]::Exists($fixture.Path))
        Assert-True (Publish-HostRefreshQueuedState -RuntimeDir $fixture.Runtime -RequestId $script:RequestId -Channel listener -Confirm:$false) 'published once the lock is free'
    }
}
