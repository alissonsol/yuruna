<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42785eb2-7793-490d-933e-6ced2c275f4a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner handoff refresh-gate host-refresh pester
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
    The runner side of a host refresh: the refresh gate, the handoff token,
    the readiness acknowledgment, the launch record, strict parameter binding
    on the three runner scripts, the held-control barrier and the inner
    cycle's gate sites.
.DESCRIPTION
    Every gate, token and acknowledgment lives under a private root this
    suite creates, passed explicitly; nothing reads or writes the operator's
    own state. Two-process cases (a gate lock held by another process, a
    live outer/cycle/inner chain, an sg relaunch) use disposable stand-ins.
    Assertions are made on structured fields and catalog keys, never on
    rendered English.
#>

# The inner loop resolves the lab-health gate, the host driver and the git and
# host-condition helpers from the global command table at call time, so the
# recording stubs, and the counters they record into, live in the global scope.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The global command table is the resolution contract under test: the inner loop finds these helpers there, so the recording stubs and their counters straddle that scope.')]
param()

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.InnerSpawn.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.RunnerInnerLoop.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $script:Here
    $script:Pwsh = [Environment]::ProcessPath
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-handoff'
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:RequestId = '6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f'

    function New-TestRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a private root and a runtime directory under the suite temp dir.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param()
        $base = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $base 'private'
        $runtime = Join-Path $base 'runtime'
        $null = New-Item -ItemType Directory -Path $root, $runtime -Force
        return @{ Root = $root; Runtime = $runtime }
    }

    function Close-TestGate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a gate under a private test root.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([hashtable]$T, [int]$OwnerPid = $PID)
        return (Set-YurunaRefreshGate -State closed -RequestId $script:RequestId -Attempt 1 -RuntimeDir $T.Runtime -ExpectedGeneration '' `
            -PrivateRoot $T.Root -OwnerPid $OwnerPid -Confirm:$false)
    }

    function Write-TestGatePayload {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: replaces the gate record under a private test root.')]
        [CmdletBinding()]
        param([hashtable]$T, [hashtable]$Payload)
        $path = Join-Path $T.Root 'runner-gate.record'
        $read = Read-YurunaCriticalRecord -Path $path -Kind 'runner-gate'
        $expected = if ($read.Status -eq 'ok') { [long]$read.Generation } else { [long]0 }
        $w = Write-YurunaCriticalRecord -Path $path -Kind 'runner-gate' -Payload $Payload -ExpectedGeneration $expected -Confirm:$false
        if (-not $w.Committed) { throw "fixture gate not written: $($w.Reason)" }
    }

    function New-TestHandoff {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: closes a private test gate and issues a handoff token on it.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([hashtable]$T, [string]$Purpose = 'new-outer', [psobject]$DesignatedOuter)
        $closed = Close-TestGate -T $T
        $issue = @{ RequestId = $script:RequestId; Attempt = 1; RuntimeDir = $T.Runtime; Purpose = $Purpose; ExpiresInMilliseconds = 120000
            ExpectedGeneration = $closed.Generation; PrivateRoot = $T.Root; Confirm = $false }
        if ($DesignatedOuter) { $issue.DesignatedOuter = $DesignatedOuter }
        return (New-YurunaRunnerHandoffToken @issue)
    }

    function Get-OwnIdentity {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param()
        return [pscustomobject]@{ Pid = $PID; StartTimeUnixMs = (Get-YurunaProcessStartUnixMs -ProcessId $PID) }
    }

    function Start-TestProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a disposable stand-in process the suite kills in AfterAll.')]
        [CmdletBinding()]
        [OutputType([System.Diagnostics.Process])]
        param([string]$FilePath, [string[]]$ArgumentList)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
        foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Spawned.Add($process)
        return $process
    }

    function Wait-TestCondition {
        [CmdletBinding()]
        [OutputType([bool])]
        param([scriptblock]$Condition, [int]$Seconds = 30)
        $until = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $until) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }

    function ConvertTo-TestPlainText {
        [CmdletBinding()]
        [OutputType([string])]
        param([AllowEmptyString()][string]$Text)
        return (($Text -replace "`e\[[0-9;?]*[A-Za-z]", '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    }
}

AfterAll {
    foreach ($p in @($script:Spawned)) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch { $null = $_ } }
    Remove-YurunaTestTempDir $script:Work
}

Describe 'Refresh gate states (Get-YurunaRefreshGateState)' {
    It 'is open with no private root and with no gate record' {
        $t = New-TestRoot
        $absent = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot (Join-Path $t.Root 'missing')
        Assert-Equal -Expected 'open' -Actual $absent.State
        Assert-Equal -Expected 'no-gate' -Actual $absent.Reason
        $empty = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-True $empty.SpawnAllowed 'no gate record holds nothing'
    }
    It 'holds every spawn while closed or recovery-pending, and opens when released' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        Assert-True $closed.Written "closed ($($closed.Reason))"
        Assert-Match -Pattern '^[0-9a-f]{32}$' -Actual $closed.Generation
        $g = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'closed' -Actual $g.State
        Assert-False $g.SpawnAllowed 'closed holds spawns'
        Assert-Equal -Expected $script:RequestId -Actual $g.RequestId
        $allowed = @(Test-YurunaRefreshSpawnAllowed -RuntimeDir $t.Runtime -PrivateRoot $t.Root)
        Assert-Equal -Expected 1 -Actual $allowed.Count -Because 'exactly one value on the success stream'
        Assert-True ($allowed[0] -is [bool] -and -not $allowed[0]) 'a single $false'
        $pending = Set-YurunaRefreshGate -State recovery-pending -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime `
            -ExpectedGeneration $closed.Generation -PrivateRoot $t.Root -Confirm:$false
        Assert-Equal -Expected 'recovery-pending' -Actual (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root).State
        $released = Set-YurunaRefreshGate -State released -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime `
            -ExpectedGeneration $pending.Generation -PrivateRoot $t.Root -Confirm:$false
        $open = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'open' -Actual $open.State
        Assert-Equal -Expected 'released' -Actual $open.Reason
        Assert-Equal -Expected $released.Generation -Actual $open.Generation
    }
    It 'fails closed on an unreadable record and on a newer schema' {
        $t = New-TestRoot
        Set-Content -LiteralPath (Join-Path $t.Root 'runner-gate.record') -Value 'garbage' -Encoding ascii
        $bad = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'unknown' -Actual $bad.State
        Assert-False $bad.SpawnAllowed 'an unreadable gate holds spawns'
        Assert-Equal -Expected 'unreadable' -Actual $bad.Reason
        $t2 = New-TestRoot
        Write-TestGatePayload -T $t2 -Payload @{ schemaVersion = 2; protocolVersion = 1; state = 'released'; generation = 'x' }
        $newer = Get-YurunaRefreshGateState -RuntimeDir $t2.Runtime -PrivateRoot $t2.Root
        Assert-Equal -Expected 'unsupported-schema' -Actual $newer.Reason
        Assert-False $newer.SpawnAllowed 'a newer schema is never read as open'
    }
    It 'reads a gate whose owner is gone as orphaned' {
        $t = New-TestRoot
        $dead = Start-TestProcess -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 500')
        $dead.WaitForExit()
        $null = Close-TestGate -T $t -OwnerPid $dead.Id
        $g = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'DeadOrRecycled' -Actual $g.OwnerState
        Assert-True $g.Orphaned 'a closed gate with a dead owner is orphaned'
        $live = Close-TestGate -T (New-TestRoot)
        Assert-True $live.Written 'written'
    }
    It 'refuses a stale generation, writes nothing under -WhatIf, and reports a busy lock held by another process' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        $stale = Set-YurunaRefreshGate -State released -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime `
            -ExpectedGeneration ('0' * 32) -PrivateRoot $t.Root -Confirm:$false
        Assert-Equal -Expected 'generation-mismatch' -Actual $stale.Reason
        $preview = Set-YurunaRefreshGate -State released -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime `
            -ExpectedGeneration $closed.Generation -PrivateRoot $t.Root -WhatIf
        Assert-Equal -Expected 'preview' -Actual $preview.Reason
        Assert-Equal -Expected 'closed' -Actual (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root).State
        $ready = Join-Path $t.Root 'holder.ready'
        $lockModule = (Join-Path $script:Here 'Test.SingleFlightLock.psm1').Replace("'", "''")
        $holder = Start-TestProcess -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command',
            "Import-Module '$lockModule' -DisableNameChecking; `$l = Enter-YurunaSingleFlightLock -Path '$(Join-Path $t.Root 'runner-gate.lock')' -WaitMilliseconds 5000; if (`$l.Held) { Set-Content -LiteralPath '$ready' -Value 1 }; Start-Sleep -Seconds 20")
        Assert-True (Wait-TestCondition { Test-Path -LiteralPath $ready }) 'the holder took the gate lock'
        $busy = Set-YurunaRefreshGate -State released -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime `
            -ExpectedGeneration $closed.Generation -PrivateRoot $t.Root -Confirm:$false
        Assert-Equal -Expected 'lock-busy' -Actual $busy.Reason
        $holder.Kill($true)
    }
}

Describe 'Handoff token' {
    It 'moves a closed gate to handoff, admits only the matching token from this boot and runtime, and expires' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        $none = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -Purpose new-outer `
            -ExpiresInMilliseconds 60000 -ExpectedGeneration ('1' * 32) -PrivateRoot $t.Root -Confirm:$false
        Assert-Equal -Expected 'generation-mismatch' -Actual $none.Reason
        $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -Purpose new-outer `
            -ExpiresInMilliseconds 60000 -ExpectedGeneration $closed.Generation -PrivateRoot $t.Root -Confirm:$false
        Assert-True $token.Issued "issued ($($token.Reason))"
        Assert-Match -Pattern '^[0-9a-f]{32}$' -Actual $token.TokenId
        $g = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -TokenId $token.TokenId -PrivateRoot $t.Root
        Assert-Equal -Expected 'handoff' -Actual $g.State
        Assert-False $g.SpawnAllowed 'a handoff holds ordinary spawns'
        Assert-True $g.PreflightAllowed 'the matching token admits its preflight'
        Assert-True (Test-YurunaRefreshSpawnAllowed -RuntimeDir $t.Runtime -TokenId $token.TokenId -PrivateRoot $t.Root) 'the preflight site passes'
        Assert-False (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -TokenId ('f' * 32) -PrivateRoot $t.Root).PreflightAllowed 'another token does not'
        Assert-False (Get-YurunaRefreshGateState -RuntimeDir (New-TestRoot).Runtime -TokenId $token.TokenId -PrivateRoot $t.Root).PreflightAllowed 'another runtime does not'
        $outer = Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role outer -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-True $outer.Valid "outer role ($($outer.Reason))"
        Assert-Equal -Expected 'new-outer' -Actual $outer.Purpose
        Assert-Equal -Expected 'token-mismatch' -Actual (Test-YurunaRunnerHandoffToken -TokenId ('e' * 32) -Role outer -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Reason
        Assert-Equal -Expected 'runtime-mismatch' -Actual (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role outer -RuntimeDir (New-TestRoot).Runtime -PrivateRoot $t.Root).Reason
        $t2 = New-TestRoot
        $closed2 = Close-TestGate -T $t2
        $short = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t2.Runtime -Purpose new-outer `
            -ExpiresInMilliseconds 1 -ExpectedGeneration $closed2.Generation -PrivateRoot $t2.Root -Confirm:$false
        Start-Sleep -Milliseconds 50
        Assert-Equal -Expected 'expired' -Actual (Test-YurunaRunnerHandoffToken -TokenId $short.TokenId -Role outer -RuntimeDir $t2.Runtime -PrivateRoot $t2.Root).Reason
    }
    It 'treats a token from another boot as expired' {
        $t = New-TestRoot
        $token = 'c' * 32
        Write-TestGatePayload -T $t -Payload @{
            schemaVersion = 1; protocolVersion = 1; generation = ('d' * 32); requestId = $script:RequestId; attempt = 1; state = 'handoff'
            owner = @{ pid = $PID; startTimeUnixMs = 1; role = 'worker' }; runtimeDir = $t.Runtime
            reclaimed = @{ outer = $null; cycle = $null; inner = $null }
            handoff = @{ tokenId = $token; purpose = 'new-outer'; designatedOuter = $null; onReady = 'released'
                expiresTick = [Environment]::TickCount64 + 600000; bootEpochMs = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [Environment]::TickCount64 - 3600000); issuedUtc = 'x' }
            reasonCode = 'handoff-issued'; updatedUtc = 'x'
        }
        Assert-Equal -Expected 'boot-changed' -Actual (Test-YurunaRunnerHandoffToken -TokenId $token -Role outer -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Reason
        Assert-False (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -TokenId $token -PrivateRoot $t.Root).PreflightAllowed 'a stale-boot token admits nothing'
    }
    It 'admits a resident-outer token only for the designated outer, which alone may complete it as such' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        $me = Get-OwnIdentity
        $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -Purpose resident-outer `
            -ExpiresInMilliseconds 60000 -ExpectedGeneration $closed.Generation -DesignatedOuter $me -OnReady recovery-pending -PrivateRoot $t.Root -Confirm:$false
        Assert-True $token.Issued "issued ($($token.Reason))"
        Assert-True (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role outer -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Valid 'the designated outer'
        $g = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'AliveOwned' -Actual $g.OwnerState -Because 'the designated outer owns the handoff, so the gate is not orphaned when the worker exits'
        $t2 = New-TestRoot
        $closed2 = Close-TestGate -T $t2
        $other = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t2.Runtime -Purpose resident-outer `
            -ExpiresInMilliseconds 60000 -ExpectedGeneration $closed2.Generation -DesignatedOuter ([pscustomobject]@{ Pid = 1; StartTimeUnixMs = [long]1 }) -PrivateRoot $t2.Root -Confirm:$false
        Assert-Equal -Expected 'not-designated' -Actual (Test-YurunaRunnerHandoffToken -TokenId $other.TokenId -Role outer -RuntimeDir $t2.Runtime -PrivateRoot $t2.Root).Reason
        $refused = Complete-YurunaRunnerHandoff -TokenId $other.TokenId -Verdict released -ExpectedGeneration $other.Generation -AsDesignatedOuter -PrivateRoot $t2.Root -Confirm:$false
        Assert-Equal -Expected 'not-designated' -Actual $refused.Reason
        Set-Content -LiteralPath (Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json") -Value '{}' -Encoding utf8NoBOM
        $done = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict released -ExpectedGeneration $token.Generation -AsDesignatedOuter -PrivateRoot $t.Root -Confirm:$false
        Assert-True $done.Completed "completed ($($done.Reason))"
        Assert-Equal -Expected 'recovery-pending' -Actual $done.State -Because 'a released verdict is downgraded to the recorded onReady'
        Assert-False (Test-Path -LiteralPath (Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json")) 'the acknowledgment is removed'
        Assert-Equal -Expected 'not-handoff' -Actual (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role outer -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Reason -Because 'completion revokes the token'
    }
    It 'checks the cycle and inner roles against the recorded parent' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -Purpose new-outer `
            -ExpiresInMilliseconds 60000 -ExpectedGeneration $closed.Generation -PrivateRoot $t.Root -Confirm:$false
        $outerStart = [DateTimeOffset]::new(2026, 9, 25, 1, 0, 0, [TimeSpan]::Zero)
        Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.pid') -Value '4242' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.start') -Value $outerStart.UtcDateTime.ToString('o') -Encoding utf8NoBOM
        @{ schemaVersion = 1; pid = 4343; startTimeUnixMs = 7000; cycle = 1; outerPid = 4242 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.cycle.json') -Encoding utf8NoBOM
        $row = { param($p, $pp, $s) [pscustomobject]@{ Pid = $p; ParentPid = $pp; StartTimeUnixMs = [long]$s; CommandLine = 'pwsh'; OwnerId = '1' } }
        $asCycle = [pscustomobject]@{ Complete = $true; Platform = 'Linux'; Rows = @((& $row $PID 4242 5), (& $row 4242 1 $outerStart.ToUnixTimeMilliseconds())) }
        Assert-True (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role cycle -RuntimeDir $t.Runtime -ProcessTable $asCycle -PrivateRoot $t.Root).Valid 'parent is the recorded outer'
        $wrongParent = [pscustomobject]@{ Complete = $true; Platform = 'Linux'; Rows = @((& $row $PID 99 5), (& $row 4242 1 $outerStart.ToUnixTimeMilliseconds())) }
        Assert-Equal -Expected 'parent-mismatch' -Actual (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role cycle -RuntimeDir $t.Runtime -ProcessTable $wrongParent -PrivateRoot $t.Root).Reason
        $asInner = [pscustomobject]@{ Complete = $true; Platform = 'Linux'; Rows = @((& $row $PID 4343 5), (& $row 4343 4242 7000)) }
        Assert-True (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role inner -RuntimeDir $t.Runtime -ProcessTable $asInner -PrivateRoot $t.Root).Valid 'parent is the recorded cycle'
        $recycled = [pscustomobject]@{ Complete = $true; Platform = 'Linux'; Rows = @((& $row $PID 4343 5), (& $row 4343 4242 99000)) }
        Assert-Equal -Expected 'parent-mismatch' -Actual (Test-YurunaRunnerHandoffToken -TokenId $token.TokenId -Role inner -RuntimeDir $t.Runtime -ProcessTable $recycled -PrivateRoot $t.Root).Reason
    }
}

Describe 'Readiness acknowledgment' {
    It 'writes nothing for a token the gate does not hold' {
        $t = New-TestRoot
        $null = New-TestHandoff -T $t
        Assert-False (Write-YurunaRunnerReadinessAck -TokenId ('9' * 32) -Role outer -State failed -FailureReason 'token-invalid' -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false) 'no waiter, no file'
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $t.Root -Filter '*.ack.json').Count
    }
    It 'returns a failed acknowledgment at once, and times out without one' {
        $t = New-TestRoot
        $token = (New-TestHandoff -T $t).TokenId
        Assert-True (Write-YurunaRunnerReadinessAck -TokenId $token -Role outer -State failed -FailureReason 'yaml-missing' -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false) 'written'
        $failed = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -PrivateRoot $t.Root
        Assert-Equal -Expected 'failed' -Actual $failed.State
        Assert-Equal -Expected 'yaml-missing' -Actual $failed.Reason
        Assert-True ($failed.ElapsedMs -lt 5000) 'no waiting on a failure'
        $timeout = Wait-YurunaRunnerReadiness -TokenId ('b' * 32) -Deadline (New-YurunaDeadline -TotalMilliseconds 600) -PollMilliseconds 100 -PrivateRoot $t.Root
        Assert-Equal -Expected 'timeout' -Actual $timeout.State
    }
    It 'accepts a ready acknowledgment only when a fresh table proves inner <- cycle <- outer' -Skip:$IsWindows {
        $t = New-TestRoot
        $outer = Start-TestProcess -FilePath '/bin/bash' -ArgumentList @('-c', 'bash -c "sleep 120; true" & wait')
        Assert-True (Wait-TestCondition {
            $snapshot = Get-YurunaProcessTable
            $child = @($snapshot.Rows | Where-Object ParentPid -eq $outer.Id)
            return $snapshot.Complete -and $child.Count -eq 1 -and
                @($snapshot.Rows | Where-Object ParentPid -eq $child[0].Pid).Count -eq 1
        }) 'the owned chain is up'
        $table = Get-YurunaProcessTable
        $cycleRow = @($table.Rows | Where-Object ParentPid -eq $outer.Id)[0]
        $innerRow = @($table.Rows | Where-Object ParentPid -eq $cycleRow.Pid)[0]
        $outerRow = @($table.Rows | Where-Object Pid -eq $outer.Id)[0]
        $iso = { param($ms) [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime.ToString('o') }
        Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.pid') -Value "$($outer.Id)" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.start') -Value (& $iso $outerRow.StartTimeUnixMs) -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $t.Runtime 'inner.pid') -Value "$($innerRow.Pid)" -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $t.Runtime 'inner.start') -Value (& $iso $innerRow.StartTimeUnixMs) -Encoding utf8NoBOM
        @{ schemaVersion = 1; pid = $cycleRow.Pid; startTimeUnixMs = $cycleRow.StartTimeUnixMs; cycle = 1 } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $t.Runtime 'runner.cycle.json') -Encoding utf8NoBOM
        $token = (New-TestHandoff -T $t).TokenId
        $chain = @{
            outer = @{ pid = $outer.Id; startTimeUnixMs = $outerRow.StartTimeUnixMs }
            cycle = @{ pid = $cycleRow.Pid; startTimeUnixMs = $cycleRow.StartTimeUnixMs }
            inner = @{ pid = $innerRow.Pid; startTimeUnixMs = $innerRow.StartTimeUnixMs }
        }
        $null = Write-YurunaRunnerReadinessAck -TokenId $token -Role inner -State ready -Chain $chain -PreservedControl @('control.cycle-pause') `
            -Probe ([pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 12 }) -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false
        $ack = Get-Content -LiteralPath (Join-Path $t.Root "runner-handoff.$token.ack.json") -Raw | ConvertFrom-Json
        Assert-Equal -Expected 'control.cycle-pause' -Actual (@($ack.preservedControls) -join ',')
        Assert-Equal -Expected 'Responsive' -Actual $ack.probe.state
        $ready = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -PrivateRoot $t.Root
        Assert-Equal -Expected 'ready' -Actual $ready.State -Because "chain check: $($ready.Reason)"
        $chain.inner = @{ pid = $cycleRow.Pid; startTimeUnixMs = $cycleRow.StartTimeUnixMs }
        $null = Write-YurunaRunnerReadinessAck -TokenId $token -Role inner -State ready -Chain $chain -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false
        $mismatch = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 5000) -PrivateRoot $t.Root
        Assert-Equal -Expected 'identity-mismatch' -Actual $mismatch.State -Because 'the acknowledged inner is not the recorded one'
        $outer.Kill($true)
    }
    It 'lets a resident outer verify an exited chain against the cycle it recorded' {
        $t = New-TestRoot
        $me = Get-OwnIdentity
        $token = (New-TestHandoff -T $t -Purpose resident-outer -DesignatedOuter $me).TokenId
        $cycle = @{ pid = 555; startTimeUnixMs = [long]123456 }
        $null = Write-YurunaRunnerReadinessAck -TokenId $token -Role inner -State ready -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false `
            -Chain @{ outer = @{ pid = $me.Pid; startTimeUnixMs = $me.StartTimeUnixMs }; cycle = $cycle; inner = @{ pid = 556; startTimeUnixMs = [long]123999 } }
        $ok = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 2000) -PrivateRoot $t.Root `
            -ExpectedCycle ([pscustomobject]@{ Pid = 555; StartTimeUnixMs = [long]123456 })
        Assert-Equal -Expected 'ready' -Actual $ok.State
        $bad = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 2000) -PrivateRoot $t.Root `
            -ExpectedCycle ([pscustomobject]@{ Pid = 557; StartTimeUnixMs = [long]123456 })
        Assert-Equal -Expected 'identity-mismatch' -Actual $bad.State
        Assert-Equal -Expected 'cycle-mismatch' -Actual $bad.Reason
    }
}

Describe 'Readiness wait on a launched runner' {
    It 'ends at once when the watched runner is gone without an acknowledgment, and still returns one it left' {
        $t = New-TestRoot
        $token = (New-TestHandoff -T $t).TokenId
        $dead = Start-TestProcess -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0')
        $deadStart = ([DateTimeOffset]$dead.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
        $dead.WaitForExit()
        $watch = [pscustomobject]@{ Pid = $dead.Id; StartTimeUnixMs = $deadStart }
        $gone = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -PollMilliseconds 100 -WatchProcess $watch -PrivateRoot $t.Root
        Assert-Equal -Expected 'exited' -Actual $gone.State
        Assert-Equal -Expected 'runner-exited' -Actual $gone.Reason
        Assert-True ($gone.ElapsedMs -lt 10000) "no waiting out the deadline ($($gone.ElapsedMs) ms)"
        Assert-True (Write-YurunaRunnerReadinessAck -TokenId $token -Role outer -State failed -FailureReason 'config-gate-failed' -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false) 'written'
        $acked = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -PollMilliseconds 100 -WatchProcess $watch -PrivateRoot $t.Root
        Assert-Equal -Expected 'failed' -Actual $acked.State -Because 'an acknowledgment the runner left before exiting wins'
        Assert-Equal -Expected 'config-gate-failed' -Actual $acked.Reason
    }
    It 'keeps waiting while the watched runner lives, and treats a recycled PID as gone' {
        $t = New-TestRoot
        $token = (New-TestHandoff -T $t).TokenId
        $me = Get-OwnIdentity
        $alive = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 700) -PollMilliseconds 100 -WatchProcess $me -PrivateRoot $t.Root
        Assert-Equal -Expected 'timeout' -Actual $alive.State
        $recycled = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -PollMilliseconds 100 `
            -WatchProcess ([pscustomobject]@{ Pid = $PID; StartTimeUnixMs = ([long]$me.StartTimeUnixMs - 600000) }) -PrivateRoot $t.Root
        Assert-Equal -Expected 'exited' -Actual $recycled.State -Because 'this PID now belongs to another start time'
        $unknown = Wait-YurunaRunnerReadiness -TokenId $token -Deadline (New-YurunaDeadline -TotalMilliseconds 500) -PollMilliseconds 100 -WatchProcess $me `
            -ProcessLookup { param([int]$TargetPid) $null = $TargetPid; [pscustomobject]@{ Alive = $false; StartTimeUnixMs = $null; Known = $false } } -PrivateRoot $t.Root
        Assert-Equal -Expected 'timeout' -Actual $unknown.State -Because 'an incomplete lookup proves nothing'
    }
}

Describe 'Restarting a runner that dies before acknowledging (stand-in runner script)' {
    It 'returns launch-failed at once, leaves the gate recovery-pending, and prunes old stream captures' {
        $t = New-TestRoot
        $repo = Join-Path $script:Work ('repo-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'test') -Force
        $runnerScript = Join-Path $repo 'test/Start-TestRunner.ps1'
        $real = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1')
        # The real param block, so the launch record validates; the body is a
        # start that refuses before acknowledging anything.
        [System.IO.File]::WriteAllText($runnerScript, "#requires -version 7`n" + $real.ParamBlock.Extent.Text + "`nexit 1`n")
        $config = Join-Path $repo 'runner.config.yml'
        Set-Content -LiteralPath $config -Value 'x: 1' -Encoding utf8NoBOM
        $written = Write-YurunaRunnerLaunchRecord -ScriptPath $runnerScript -BoundParameters ([ordered]@{}) -ResolvedConfigPath $config `
            -RuntimeDir $t.Runtime -RepoRoot $repo -WorkingDirectory $repo -ForwardEnvironment @{} -AllowedEnvironmentName @('YURUNA_LOG_LEVEL') `
            -PrivateRoot $t.Root -Confirm:$false
        Assert-True $written.Written "launch record ($($written.Reason) $($written.Parameter))"
        $work = Join-Path $t.Root 'work'
        $null = New-Item -ItemType Directory -Path $work -Force
        for ($i = 0; $i -lt 6; $i++) {
            $old = Join-Path $work "runner.old-$i.err"
            Set-Content -LiteralPath $old -Value 'x' -Encoding utf8NoBOM
            [System.IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddDays(-10).AddMinutes(-$i))
        }
        $closed = Close-TestGate -T $t
        $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        $r = Invoke-YurunaRunnerRefreshResume -LaunchRecord $launch -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -RepoRoot $repo `
            -ExpectedGateGeneration $closed.Generation -Reclaimed @{} -PrivateDirectory $work -Deadline (New-YurunaDeadline -TotalMilliseconds 90000) `
            -PrivateRoot $t.Root -Confirm:$false
        Assert-Equal -Expected 'launch-failed' -Actual $r.Outcome -Because "reason $($r.Reason)"
        Assert-Equal -Expected 'runner-exited' -Actual $r.Reason
        Assert-Equal -Expected 'recovery-pending' -Actual $r.GateState
        Assert-Equal -Expected 'recovery-pending' -Actual (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root).State
        $kept = @(Get-ChildItem -LiteralPath $work -Filter 'runner.old-*.err' | ForEach-Object Name | Sort-Object)
        Assert-Equal -Expected 'runner.old-0.err,runner.old-1.err,runner.old-2.err,runner.old-3.err' -Actual ($kept -join ',') -Because 'the four newest old captures stay'
        Assert-True (Test-Path -LiteralPath (Join-Path $work "runner.$($script:RequestId).err")) 'this restart''s own capture exists'
    }
}

Describe 'Native POSIX detached readiness handoff' -Skip:$IsWindows {
    It 'restarts a stand-in runner through the POSIX launcher and completes its live three-process handoff' {
        $paths = New-TestRoot
        $pause = Join-Path $paths.Runtime 'control.cycle-pause'
        [IO.File]::WriteAllText($pause, 'native operator pause')
        $pauseHash = (Get-FileHash -LiteralPath $pause).Hash
        $repo = Join-Path $script:Work ('repo-' + [guid]::NewGuid().ToString('N'))
        $testDir = Join-Path $repo 'test'
        $null = [IO.Directory]::CreateDirectory($testDir)
        $streams = Join-Path $paths.Root 'work'
        $null = [IO.Directory]::CreateDirectory($streams)
        $fixturePath = Join-Path $testDir 'native.json'
        $fixture = @{ modules = $script:Here; runtime = $paths.Runtime; private = $paths.Root; capture = $testDir }
        [IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json))
        $body = @'
$ErrorActionPreference = 'Stop'
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native.json') -Raw | ConvertFrom-Json
Import-Module (Join-Path $fixture.modules '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $fixture.modules 'Test.InnerSpawn.psm1') -DisableNameChecking
Import-Module (Join-Path $fixture.modules 'Test.SingleInstance.psm1') -DisableNameChecking
$identity = @{ pid = $PID; startTimeUnixMs = Get-YurunaProcessStartUnixMs -ProcessId $PID }
$identityPath = Join-Path $fixture.capture "$Role.json"
[IO.File]::WriteAllText("$identityPath.tmp", ($identity | ConvertTo-Json))
[IO.File]::Move("$identityPath.tmp", $identityPath)
if ($Role -eq 'cycle') {
    [IO.File]::WriteAllText((Join-Path $fixture.runtime 'runner.cycle.json'), (@{ schemaVersion = 1; pid = $PID; startTimeUnixMs = $identity.startTimeUnixMs; cycle = 1 } | ConvertTo-Json))
} else {
    $stem = if ($Role -eq 'outer') { 'runner' } else { 'inner' }
    [IO.File]::WriteAllText((Join-Path $fixture.runtime "$stem.pid"), [string]$PID)
    [IO.File]::WriteAllText((Join-Path $fixture.runtime "$stem.start"), [DateTimeOffset]::FromUnixTimeMilliseconds($identity.startTimeUnixMs).UtcDateTime.ToString('o'))
}
$admitted = Test-YurunaRunnerHandoffToken -TokenId $RefreshHandoffToken -Role $Role -RuntimeDir $fixture.runtime -PrivateRoot $fixture.private
if (-not $admitted.Valid) { throw "role $Role refused: $($admitted.Reason)" }
if ($Role -eq 'inner') {
    $chain = @{}
    foreach ($name in @('outer', 'cycle', 'inner')) { $chain[$name] = Get-Content -LiteralPath (Join-Path $fixture.capture "$name.json") -Raw | ConvertFrom-Json -AsHashtable }
    $written = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role inner -State ready -Chain $chain -PreservedControl @('control.cycle-pause') -RuntimeDir $fixture.runtime -PrivateRoot $fixture.private -Confirm:$false
    if (-not $written) { throw 'readiness acknowledgment was not written' }
    Import-Module (Join-Path $fixture.modules 'Test.RunnerInnerLoop.psm1') -DisableNameChecking
    $null = Wait-YurunaHeldControlBarrier -RuntimeDir $fixture.runtime -StepHeartbeatFile (Join-Path $fixture.runtime 'runner.stepHeartbeat') -ShutdownState @{ Requested = $false } -PollDelay { param([int]$Attempt) $null = $Attempt; 100 }
    [IO.File]::WriteAllText((Join-Path $fixture.runtime 'workload-started'), 'unexpected')
} else {
    $nextRole = if ($Role -eq 'outer') { 'cycle' } else { 'inner' }
    $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'native-chain.ps1'), '-Role', $nextRole, '-RefreshHandoffToken', $RefreshHandoffToken)) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $null = [Diagnostics.Process]::Start($psi)
}
Start-Sleep -Seconds 120
'@
        $runner = Join-Path $testDir 'Start-TestRunner.ps1'
        $real = Get-YurunaTestFileAst -Path (Join-Path $script:Here '../Start-TestRunner.ps1')
        [IO.File]::WriteAllText($runner, "#requires -version 7`n" + $real.ParamBlock.Extent.Text + "`n`$Role = 'outer'`n" + $body)
        [IO.File]::WriteAllText((Join-Path $testDir 'native-chain.ps1'), "param([string]`$Role, [string]`$RefreshHandoffToken)`n" + $body)
        $config = Join-Path $repo 'runner.config.yml'
        [IO.File]::WriteAllText($config, "x: 1`n")
        $record = Write-YurunaRunnerLaunchRecord -ScriptPath $runner -BoundParameters ([ordered]@{}) -ResolvedConfigPath $config -RuntimeDir $paths.Runtime `
            -RepoRoot $repo -WorkingDirectory $repo -ForwardEnvironment @{} -AllowedEnvironmentName @('YURUNA_LOG_LEVEL') -PrivateRoot $paths.Root -Confirm:$false
        Assert-True $record.Written "launch record: $($record.Reason)"
        $closed = Set-YurunaRefreshGate -State closed -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -ExpectedGeneration '' -PrivateRoot $paths.Root -OwnerPid $PID -Confirm:$false
        try {
            $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $paths.Runtime -PrivateRoot $paths.Root
            $result = Invoke-YurunaRunnerRefreshResume -LaunchRecord $launch -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -RepoRoot $repo `
                -ExpectedGateGeneration $closed.Generation -Reclaimed @{} -PrivateDirectory $streams -Deadline (New-YurunaDeadline -TotalMilliseconds 60000) -PrivateRoot $paths.Root -Confirm:$false
            $detail = ''
            if ($result.Outcome -ne 'ready') {
                try { $detail = [IO.File]::ReadAllText((Join-Path $streams "runner.$($script:RequestId).err")) } catch { $detail = 'worker capture is still open' }
            }
            Assert-Equal 'ready' $result.Outcome "native detached handoff: $($result.Reason) $detail"
            Assert-Equal 'released' $result.GateState
            Assert-Equal 'open' (Get-YurunaRefreshGateState -RuntimeDir $paths.Runtime -PrivateRoot $paths.Root).State
            Assert-Equal 'control.cycle-pause' (@($result.PreservedControls) -join ',')
            Assert-True (Wait-TestCondition { [IO.File]::Exists((Join-Path $paths.Runtime 'runner.stepHeartbeat')) }) 'the resumed inner reached the held-control barrier'
            Start-Sleep -Milliseconds 300
            Assert-Equal $pauseHash (Get-FileHash -LiteralPath $pause).Hash 'the operator pause is unchanged'
            Assert-False ([IO.File]::Exists((Join-Path $paths.Runtime 'workload-started'))) 'the resumed inner stays parked before workload mutation'
        } finally {
            foreach ($name in @('outer', 'cycle', 'inner')) {
                $path = Join-Path $testDir "$name.json"
                if (-not [IO.File]::Exists($path)) { continue }
                $identity = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                $process = Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
                if ($process -and [Math]::Abs(([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() - $identity.startTimeUnixMs) -le 2000) {
                    $script:Spawned.Add($process)
                }
            }
        }
    }
}

Describe 'Expired resident-outer handoff (Complete-YurunaRunnerExpiredHandoff)' {
    It 'completes an unusable token designating this outer as recovery-pending, keeping this outer as owner' {
        $t = New-TestRoot
        $closed = Close-TestGate -T $t
        $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -Purpose resident-outer `
            -ExpiresInMilliseconds 1 -ExpectedGeneration $closed.Generation -DesignatedOuter (Get-OwnIdentity) -PrivateRoot $t.Root -Confirm:$false
        Set-Content -LiteralPath (Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json") -Value '{}' -Encoding utf8NoBOM
        Start-Sleep -Milliseconds 50
        $preview = Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t.Root -WhatIf
        Assert-Equal -Expected 'preview' -Actual $preview.Reason
        Assert-Equal -Expected 'handoff' -Actual (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root).State
        $done = Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t.Root -Confirm:$false
        Assert-True $done.Completed "completed ($($done.Reason))"
        Assert-Equal -Expected $script:RequestId -Actual $done.RequestId
        $g = Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-Equal -Expected 'recovery-pending' -Actual $g.State
        Assert-Equal -Expected 'handoff-expired' -Actual $g.ReasonCode
        Assert-Equal -Expected $PID -Actual ([int]$g.Owner['pid']) -Because 'the resident outer stays the owner the resume takes over from'
        Assert-False (Test-Path -LiteralPath (Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json")) 'its acknowledgment is removed'
    }
    It 'leaves a live token, another outer''s token and a new-outer token alone' {
        $t = New-TestRoot
        $live = New-TestHandoff -T $t -Purpose resident-outer -DesignatedOuter (Get-OwnIdentity)
        Assert-True $live.Issued "issued ($($live.Reason))"
        Assert-Equal -Expected 'token-live' -Actual (Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t.Root -Confirm:$false).Reason
        Assert-Equal -Expected 'handoff' -Actual (Get-YurunaRefreshGateState -RuntimeDir $t.Runtime -PrivateRoot $t.Root).State
        $t2 = New-TestRoot
        $closed2 = Close-TestGate -T $t2
        $null = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t2.Runtime -Purpose resident-outer -ExpiresInMilliseconds 1 `
            -ExpectedGeneration $closed2.Generation -DesignatedOuter ([pscustomobject]@{ Pid = 1; StartTimeUnixMs = [long]1 }) -PrivateRoot $t2.Root -Confirm:$false
        Start-Sleep -Milliseconds 50
        Assert-Equal -Expected 'not-designated' -Actual (Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t2.Root -Confirm:$false).Reason
        $t3 = New-TestRoot
        $closed3 = Close-TestGate -T $t3
        $null = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t3.Runtime -Purpose new-outer -ExpiresInMilliseconds 1 `
            -ExpectedGeneration $closed3.Generation -PrivateRoot $t3.Root -Confirm:$false
        Start-Sleep -Milliseconds 50
        Assert-Equal -Expected 'not-resident' -Actual (Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t3.Root -Confirm:$false).Reason
        $t4 = New-TestRoot
        Assert-Equal -Expected 'no-gate' -Actual (Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t4.Root -Confirm:$false).Reason
        $null = Close-TestGate -T $t4
        Assert-Equal -Expected 'not-handoff' -Actual (Complete-YurunaRunnerExpiredHandoff -PrivateRoot $t4.Root -Confirm:$false).Reason
    }
}

Describe 'Readiness acknowledgment housekeeping' {
    It 'removes acknowledgments no handoff waits for whenever a token is issued, completed, or the gate is set' {
        $t = New-TestRoot
        $stale = Join-Path $t.Root "runner-handoff.$('1' * 32).ack.json"
        $foreign = Join-Path $t.Root 'runner-handoff.not-a-token.ack.json'
        Set-Content -LiteralPath $stale, $foreign -Value '{}' -Encoding utf8NoBOM
        $token = New-TestHandoff -T $t
        Assert-False (Test-Path -LiteralPath $stale) 'a new token removes a stale acknowledgment'
        Assert-True (Test-Path -LiteralPath $foreign) 'a file of another shape is not touched'
        Assert-True (Write-YurunaRunnerReadinessAck -TokenId $token.TokenId -Role outer -State failed -FailureReason 'yaml-missing' -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false) 'written'
        $own = Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json"
        Assert-True (Test-Path -LiteralPath $own) 'the current token''s acknowledgment stays'
        $done = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict recovery-pending -ExpectedGeneration $token.Generation -PrivateRoot $t.Root -Confirm:$false
        Assert-True $done.Completed "completed ($($done.Reason))"
        Assert-False (Test-Path -LiteralPath $own) 'completion removes it'
        Set-Content -LiteralPath $stale -Value '{}' -Encoding utf8NoBOM
        $null = Set-YurunaRefreshGate -State released -RequestId $script:RequestId -Attempt 1 -RuntimeDir $t.Runtime -ExpectedGeneration $done.Generation -PrivateRoot $t.Root -Confirm:$false
        Assert-False (Test-Path -LiteralPath $stale) 'a gate transition removes it'
    }
    It 'drops an acknowledgment whose handoff was completed while it was being written' {
        $t = New-TestRoot
        $token = New-TestHandoff -T $t
        $script:RaceRoot = $t.Root
        Mock -ModuleName Test.SingleInstance Write-YurunaStateFileJson -ParameterFilter { $Path -like '*.ack.json' } -MockWith {
            [System.IO.File]::WriteAllText($Path, '{}')
            $gatePath = Join-Path $script:RaceRoot 'runner-gate.record'
            $read = Read-YurunaCriticalRecord -Path $gatePath -Kind 'runner-gate'
            $payload = $read.Payload
            $payload['handoff'] = $null
            $payload['state'] = 'recovery-pending'
            $null = Write-YurunaCriticalRecord -Path $gatePath -Kind 'runner-gate' -Payload $payload -ExpectedGeneration ([long]$read.Generation) -Confirm:$false
            $true
        }
        Assert-False (Write-YurunaRunnerReadinessAck -TokenId $token.TokenId -Role outer -State failed -FailureReason 'yaml-missing' -RuntimeDir $t.Runtime -PrivateRoot $t.Root -Confirm:$false) 'nobody waits for it'
        Assert-False (Test-Path -LiteralPath (Join-Path $t.Root "runner-handoff.$($token.TokenId).ack.json")) 'the late acknowledgment was removed'
    }
    It 'prunes old restarted-runner captures beyond the newest, and never a recent one' {
        $dir = Join-Path $script:Work ('streams-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($i in 0..5) {
            $old = Join-Path $dir "runner.r$i.err"
            Set-Content -LiteralPath $old -Value 'x' -Encoding utf8NoBOM
            [System.IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddDays(-30).AddMinutes(-$i))
        }
        Set-Content -LiteralPath (Join-Path $dir 'runner.fresh.out') -Value 'x' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $dir 'unrelated.err') -Value 'x' -Encoding utf8NoBOM
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir 'unrelated.err'), [DateTime]::UtcNow.AddDays(-30))
        $removed = InModuleScope Test.SingleInstance -Parameters @{ Dir = $dir } { param($Dir) Remove-YurunaStaleRunnerStream -Directory $Dir -Confirm:$false }
        Assert-Equal -Expected 3 -Actual $removed
        $left = @(Get-ChildItem -LiteralPath $dir | ForEach-Object Name | Sort-Object)
        Assert-Equal -Expected 'runner.fresh.out,runner.r0.err,runner.r1.err,runner.r2.err,unrelated.err' -Actual ($left -join ',')
    }
}

Describe 'Runner startup order in resume mode (source)' {
    BeforeAll {
        $script:RunnerAst = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1')
        $script:RunnerCommands = @($script:RunnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        function Get-FirstCommandOffset {
            param([string]$Name)
            $call = @($script:RunnerCommands | Where-Object { $_.GetCommandName() -eq $Name }) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
            Assert-NotNull $call "required startup command: $Name"
            return $call.Extent.StartOffset
        }
    }
    It 'resets runtime state before the single-instance guard normally, and only after winning runner.pid when resumed' {
        $assign = @($script:RunnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$runStartupRecovery' }, $true))
        Assert-Equal -Expected 1 -Actual $assign.Count
        $inside = @($assign[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($name in @('Invoke-YurunaBootRecovery', 'Initialize-RunnerState')) {
            Assert-True ($inside -contains $name) "$name runs inside the deferred startup block"
            $outside = @($script:RunnerCommands | Where-Object { $_.GetCommandName() -eq $name -and ($_.Extent.StartOffset -lt $assign[0].Extent.StartOffset -or $_.Extent.StartOffset -gt $assign[0].Extent.EndOffset) })
            Assert-Equal -Expected 0 -Actual $outside.Count -Because "$name is never called outside that block"
        }
        $calls = @($script:RunnerCommands | Where-Object { $_.InvocationOperator -eq 'Ampersand' -and $_.CommandElements[0].Extent.Text -eq '$runStartupRecovery' })
        Assert-Equal -Expected 2 -Actual $calls.Count
        $conditionOf = {
            param($Node)
            $cursor = $Node.Parent
            while ($cursor -and $cursor -isnot [System.Management.Automation.Language.IfStatementAst]) { $cursor = $cursor.Parent }
            if ($cursor) { $cursor.Clauses[0].Item1.Extent.Text } else { '' }
        }
        $normal = @($calls | Where-Object { (& $conditionOf $_) -eq '-not $RefreshResume' })
        $resumed = @($calls | Where-Object { (& $conditionOf $_) -eq '$RefreshResume' })
        Assert-Equal -Expected 1 -Actual $normal.Count
        Assert-Equal -Expected 1 -Actual $resumed.Count
        Assert-True ($normal[0].Extent.StartOffset -lt (Get-FirstCommandOffset 'Get-RunnerInstanceState')) 'a normal start sweeps before its takeover'
        Assert-True ($normal[0].Extent.StartOffset -lt (Get-FirstCommandOffset 'Get-YurunaRunnerRecordState')) 'and before any record classification'
        Assert-True ($resumed[0].Extent.StartOffset -gt (Get-FirstCommandOffset 'Write-RunnerPidFile')) 'a resumed start touches runtime state only after it holds runner.pid'
    }
    It 'marks the launch record a clean exit before every startup refusal that follows it' {
        $written = Get-FirstCommandOffset 'Write-YurunaRunnerLaunchRecord'
        $loop = Get-FirstCommandOffset 'Invoke-RunnerOuterLoop'
        $exits = @($script:RunnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) |
            Where-Object { $_.Extent.StartOffset -gt $written -and $_.Extent.StartOffset -lt $loop })
        Assert-True ($exits.Count -ge 3) "the yaml, elevation and config-gate refusals ($($exits.Count) exits)"
        foreach ($exit in $exits) {
            $block = $exit.Parent
            $marks = @($block.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and
                $n.CommandElements[0].Extent.Text -eq '$completeLaunchRecord' }, $false) | Where-Object { $_.Extent.StartOffset -lt $exit.Extent.StartOffset })
            Assert-Equal -Expected 1 -Actual $marks.Count -Because "the exit at line $($exit.Extent.StartLineNumber) marks the record first"
        }
    }
}

Describe 'Launch record' {
    BeforeAll {
        $script:RunnerScript = Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1'
        $script:Config = Join-Path $script:Work 'launch.config.yml'
        Set-Content -LiteralPath $script:Config -Value 'x: 1' -Encoding utf8NoBOM
        $script:AllowedEnv = @('YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_LOG_LEVEL')
        function Write-TestLaunchRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a launch record under a private test root.')]
            param([hashtable]$T, [System.Collections.IDictionary]$Bound, [hashtable]$Environment = @{ YURUNA_LOG_LEVEL = 'Debug' })
            Write-YurunaRunnerLaunchRecord -ScriptPath $script:RunnerScript -BoundParameters $Bound -ResolvedConfigPath $script:Config `
                -RuntimeDir $T.Runtime -RepoRoot $script:RepoRoot -WorkingDirectory $script:Work -ForwardEnvironment $Environment `
                -AllowedEnvironmentName $script:AllowedEnv -PrivateRoot $T.Root -Confirm:$false
        }
    }

    It 'round-trips the six options, excluding common and refresh parameters' {
        $t = New-TestRoot
        $bound = [ordered]@{ ConfigPath = 'relative.yml'; NoGitPull = [switch]$true; CycleDelaySeconds = 7; logLevel = 'Debug'
            Verbose = [switch]$true; RefreshResume = [switch]$true; RefreshHandoffToken = ('a' * 32) }
        $w = Write-TestLaunchRecord -T $t -Bound $bound
        Assert-True $w.Written "written ($($w.Reason) $($w.Parameter))"
        $r = Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-True $r.Valid "valid ($($r.Reason))"
        $p = $r.Record['parameters']
        Assert-Equal -Expected $script:Config -Actual $p['ConfigPath'] -Because 'the resolved path, not the bound spelling'
        Assert-True ($p['NoGitPull'] -eq $true -and $p['NoStatusService'] -eq $false -and $p['NoConfigGate'] -eq $false) 'switches recorded as booleans'
        Assert-Equal -Expected 7 -Actual $p['CycleDelaySeconds']
        Assert-Equal -Expected 'Debug' -Actual $p['logLevel']
        Assert-Equal -Expected 'ConfigPath,NoGitPull,CycleDelaySeconds,logLevel' -Actual (@($r.Record['explicitlyBound']) -join ',')
        Assert-Equal -Expected 6 -Actual $p.Count -Because 'only the six operator options are parameters'
        Assert-Equal -Expected 'Debug' -Actual $r.Record['environment']['YURUNA_LOG_LEVEL']
        Assert-True (Test-YurunaRunnerLaunchSpec -Record $r -ScriptPath $script:RunnerScript -RequireExistingConfig).Valid 'it validates against the real runner'
        $args2 = @(New-YurunaRunnerResumeArgumentList -Record $r -TokenId ('b' * 32))
        Assert-Equal -Expected "-ConfigPath|$($script:Config)|-NoGitPull|-CycleDelaySeconds|7|-logLevel|Debug|-RefreshResume|-RefreshHandoffToken|$('b' * 32)" -Actual ($args2 -join '|')
        Assert-True ($args2[0] -is [string]) 'string elements'
    }
    It 'reads bound switches from a real $PSBoundParameters dictionary' {
        $t = New-TestRoot
        $capture = { [CmdletBinding()] param([switch]$NoGitPull, [switch]$NoConfigGate, [int]$CycleDelaySeconds) $PSBoundParameters }
        $bound = & $capture -NoGitPull -CycleDelaySeconds 9
        Assert-Equal -Expected 'System.Management.Automation.PSBoundParametersDictionary' -Actual $bound.GetType().FullName -Because 'the real dictionary type'
        $w = Write-TestLaunchRecord -T $t -Bound $bound
        Assert-True $w.Written "written ($($w.Reason))"
        $r = Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-True $r.Record['parameters']['NoGitPull'] 'a bound switch is recorded as true'
        Assert-False $r.Record['parameters']['NoConfigGate'] 'an unbound switch is false'
        Assert-Equal -Expected 9 -Actual $r.Record['parameters']['CycleDelaySeconds']
        Assert-Equal -Expected 'NoGitPull,CycleDelaySeconds' -Actual (@($r.Record['explicitlyBound']) -join ',')
    }
    It 'fills in the declared default delay when the option was not bound' {
        $t = New-TestRoot
        $null = Write-TestLaunchRecord -T $t -Bound ([ordered]@{})
        Assert-Equal -Expected 30 -Actual (Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Record['parameters']['CycleDelaySeconds']
    }
    It 'refuses to write an unaccounted parameter or an environment name outside the allow-list, naming it' {
        $t = New-TestRoot
        $unaccounted = Write-TestLaunchRecord -T $t -Bound ([ordered]@{ Bogus = 1 })
        Assert-Equal -Expected 'unaccounted-parameter' -Actual $unaccounted.Reason
        Assert-Equal -Expected 'Bogus' -Actual $unaccounted.Parameter
        $env = Write-TestLaunchRecord -T $t -Bound ([ordered]@{}) -Environment @{ YURUNA_SECRET_THING = 'x' }
        Assert-Equal -Expected 'invalid-parameter' -Actual $env.Reason
        Assert-Equal -Expected 'env:YURUNA_SECRET_THING' -Actual $env.Parameter
        Assert-Equal -Expected 'missing' -Actual (Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root).Reason -Because 'nothing was written'
    }
    It 'validates a record against the runner''s own parameter metadata' {
        $base = @{ runnerProtocolVersion = 1; scriptPath = $script:RunnerScript; parameters = @{ ConfigPath = $script:Config } }
        $check = { param([hashtable]$Parameters, [int]$Version = 1)
            $record = @{ runnerProtocolVersion = $Version; scriptPath = $script:RunnerScript; parameters = $Parameters }
            Test-YurunaRunnerLaunchSpec -Record $record -ScriptPath $script:RunnerScript -RequireExistingConfig }
        Assert-True (Test-YurunaRunnerLaunchSpec -Record $base -ScriptPath $script:RunnerScript).Valid 'the minimal record'
        Assert-Equal -Expected 'unknown-parameter' -Actual (& $check @{ ConfigPth = $script:Config }).Reason -Because 'a misspelling'
        Assert-Equal -Expected 'unknown-parameter' -Actual (& $check @{ Config = $script:Config }).Reason -Because 'an abbreviation'
        Assert-Equal -Expected 'invalid-value' -Actual (& $check @{ ConfigPath = $script:Config; CycleDelaySeconds = 'abc' }).Reason -Because 'a wrong type'
        Assert-Equal -Expected 'invalid-value' -Actual (& $check @{ ConfigPath = $script:Config; logLevel = 'Loud' }).Reason -Because 'outside the ValidateSet'
        Assert-Equal -Expected 'invalid-value' -Actual (& $check @{ ConfigPath = $script:Config; NoGitPull = 'yes' }).Reason -Because 'a switch is a boolean'
        Assert-Equal -Expected 'config-missing' -Actual (& $check @{ ConfigPath = (Join-Path $script:Work 'gone.yml') }).Reason
        Assert-Equal -Expected 'unsupported-version' -Actual (& $check @{ ConfigPath = $script:Config } 2).Reason
        $other = @{ runnerProtocolVersion = 1; scriptPath = '/elsewhere/test/Start-TestRunner.ps1'; parameters = @{} }
        Assert-Equal -Expected 'script-mismatch' -Actual (Test-YurunaRunnerLaunchSpec -Record $other -ScriptPath $script:RunnerScript).Reason
    }
    It 'marks an orderly exit only on this runner''s own record, and rejects a record copied from another runtime' {
        $t = New-TestRoot
        $null = Write-TestLaunchRecord -T $t -Bound ([ordered]@{})
        Assert-False (Complete-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -CleanExit -RunnerPid 1 -PrivateRoot $t.Root -Confirm:$false) 'another runner''s record is not changed'
        Assert-True (Complete-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -CleanExit -PrivateRoot $t.Root -Confirm:$false) 'marked'
        $r = Read-YurunaRunnerLaunchRecord -RuntimeDir $t.Runtime -PrivateRoot $t.Root
        Assert-True $r.Record['cleanExit'] 'clean exit recorded'
        Assert-NotNull $r.Record['endedUtc']
        $otherRuntime = (New-TestRoot).Runtime
        $key = Get-YurunaRuntimeKey -RuntimeDir $otherRuntime
        Assert-Match -Pattern '^[0-9a-f]{16}$' -Actual $key
        Copy-Item -LiteralPath $r.Path -Destination (Join-Path $t.Root "runner-launch.$key.record")
        Assert-Equal -Expected 'runtime-mismatch' -Actual (Read-YurunaRunnerLaunchRecord -RuntimeDir $otherRuntime -PrivateRoot $t.Root).Reason
    }
}

Describe 'Strict binding on the three runner scripts' {
    BeforeAll {
        $script:Scripts = @(
            (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1'),
            (Join-Path $script:RepoRoot 'test/modules/Invoke-TestCycleRunner.ps1'),
            (Join-Path $script:RepoRoot 'test/modules/Invoke-TestRunnerInnerLoop.ps1')
        )
        function Invoke-TestScript {
            param([string[]]$ArgumentList, [string]$Runtime)
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList $ArgumentList -TimeoutSeconds 120 `
                -Environment @{ YURUNA_RUNTIME_DIR = $Runtime; YURUNA_LOG_DIR = $Runtime; HOME = (Split-Path -Parent $Runtime) }
            return $r
        }
    }
    It 'declares CmdletBinding on each param block' {
        foreach ($path in $script:Scripts) {
            $ast = Get-YurunaTestFileAst -Path $path
            $names = @($ast.ParamBlock.Attributes | ForEach-Object { $_.TypeName.Name })
            Assert-True ($names -contains 'CmdletBinding') "$(Split-Path -Leaf $path) declares CmdletBinding"
        }
    }
    It 'refuses an unknown parameter before doing anything' {
        foreach ($path in $script:Scripts) {
            $t = New-TestRoot
            $r = Invoke-TestScript -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $path, '-Bogus', '1') -Runtime $t.Runtime
            Assert-True ($r.ExitCode -ne 0) "$(Split-Path -Leaf $path) exits non-zero"
            Assert-Match -Pattern 'Bogus' -Actual (ConvertTo-TestPlainText -Text ($r.StdOut + $r.StdErr))
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $t.Runtime -Force).Count -Because "$(Split-Path -Leaf $path) created nothing"
        }
    }
    It 'refuses an extra key in the -Command form the cycle process builds for the inner' {
        $t = New-TestRoot
        $argv = @(New-InnerRunnerArgList -ScriptPath $script:Scripts[2] -Parameters @{ Bogus = 'x' } -NonInteractive)
        $r = Invoke-TestScript -ArgumentList $argv -Runtime $t.Runtime
        Assert-True ($r.ExitCode -ne 0) 'the inner refuses'
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $t.Runtime -Force).Count
    }
    It 'refuses half of the refresh transport pair on the runner' {
        $t = New-TestRoot
        $r = Invoke-TestScript -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script:Scripts[0], '-RefreshResume') -Runtime $t.Runtime
        Assert-Equal -Expected 1 -Actual $r.ExitCode
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $t.Runtime -Force).Count -Because 'refused before any runtime file'
        $bad = Invoke-TestScript -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script:Scripts[0], '-RefreshResume', '-RefreshHandoffToken', 'NOT-HEX') -Runtime $t.Runtime
        Assert-True ($bad.ExitCode -ne 0) 'a malformed token is a binding error'
    }
}

Describe 'Refresh transport through the sg relaunch' -Skip:(-not $IsLinux) {
    It 'forwards -RefreshResume and -RefreshHandoffToken bound through Invoke-LibvirtGroupReExecIfNeeded' {
        $dir = Join-Path $script:Work ('sg-' + [guid]::NewGuid().ToString('N'))
        $bin = Join-Path $dir 'bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $fakes = @{
            'id'     = "#!/usr/bin/env bash`nif [ `"`$1`" = '-nG' ]; then echo 'users kvm'; exit 0; fi`nexit 1`n"
            'getent' = "#!/usr/bin/env bash`nif [ `"`$1`" = 'group' ] && [ `"`$2`" = 'libvirt' ]; then echo `"libvirt:x:973:someone,`$USER`"; exit 0; fi`nexit 2`n"
            'sg'     = "#!/usr/bin/env bash`nshift`n[ `"`$1`" = '-c' ] || exit 97`nexec bash -c `"`$2`"`n"
        }
        foreach ($name in $fakes.Keys) {
            [IO.File]::WriteAllText((Join-Path $bin $name), $fakes[$name])
            [IO.File]::SetUnixFileMode((Join-Path $bin $name), [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        $record = Join-Path $dir 'bound.json'
        $caller = Join-Path $dir 'Invoke-Caller.ps1'
        $modulePath = (Join-Path $script:Here 'Test.HostDetection.psm1').Replace("'", "''")
        Set-Content -LiteralPath $caller -Encoding utf8 -Value @"
[CmdletBinding()]
param([switch]`$RefreshResume, [ValidatePattern('^[0-9a-f]{32}$')][string]`$RefreshHandoffToken, [string]`$ConfigPath)
if (-not `$env:YURUNA_SG_RELAUNCH) {
    Import-Module '$modulePath' -DisableNameChecking
    Invoke-LibvirtGroupReExecIfNeeded -HostType 'host.ubuntu.kvm' -ScriptPath `$PSCommandPath -BoundParameters `$PSBoundParameters
    exit 3
}
[IO.File]::WriteAllText('$($record.Replace("'", "''"))', ([ordered]@{ bound = @(`$PSBoundParameters.Keys | Sort-Object); resume = [bool]`$RefreshResume; token = `$RefreshHandoffToken; config = `$ConfigPath } | ConvertTo-Json -Compress))
exit 7
"@
        $token = 'ab' * 16
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 120 `
            -Environment @{ PATH = "${bin}:$(Split-Path -Parent $script:Pwsh):$($env:PATH)"; USER = [Environment]::UserName } `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "& '$($caller.Replace("'", "''"))' -RefreshResume -RefreshHandoffToken '$token' -ConfigPath 'a b.yml'; exit `$LASTEXITCODE")
        Assert-Equal -Expected 7 -Actual $r.ExitCode -Because (ConvertTo-TestPlainText -Text $r.StdErr)
        $seen = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        Assert-True $seen.resume 'the switch arrived bound'
        Assert-Equal -Expected $token -Actual $seen.token
        Assert-Equal -Expected 'a b.yml' -Actual $seen.config
        Assert-Equal -Expected 'ConfigPath,RefreshHandoffToken,RefreshResume' -Actual (@($seen.bound) -join ',')
    }
}

Describe 'Held-control barrier (Wait-YurunaHeldControlBarrier)' {
    BeforeAll {
        $script:NoDelay = { param([int]$Attempt) $null = $Attempt; 100 }
    }
    AfterEach {
        Remove-Item function:Invoke-LabHealthGate, function:global:Clear-LabHold, function:global:Test-LabHoldReleaseRequested -ErrorAction SilentlyContinue
    }
    It 'parks on each pause flag until its consumer removes it, refreshing the heartbeat, with the guest disk untouched' {
        foreach ($flag in @('control.cycle-pause', 'control.step-pause', 'control.pause')) {
            $t = New-TestRoot
            $flagPath = Join-Path $t.Runtime $flag
            Set-Content -LiteralPath $flagPath -Value 'x' -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $t.Runtime 'control.cycle-restart') -Value 'x' -Encoding utf8NoBOM
            $disk = Join-Path $t.Runtime 'guest.disk'
            [IO.File]::WriteAllBytes($disk, [byte[]](1..64))
            $diskBefore = (Get-FileHash -LiteralPath $disk).Hash
            $diskTime = [IO.File]::GetLastWriteTimeUtc($disk)
            $heartbeat = Join-Path $t.Runtime 'runner.stepHeartbeat'
            $releaser = Start-ThreadJob -ScriptBlock { Start-Sleep -Milliseconds 1500; Remove-Item -LiteralPath $using:flagPath -Force; [DateTime]::UtcNow }
            $b = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile $heartbeat -ShutdownState @{ Requested = $false } `
                -RequestId $script:RequestId -PollDelay $script:NoDelay 6>$null
            $returnedAt = [DateTime]::UtcNow
            $removedAt = Receive-Job -Job $releaser -Wait -AutoRemoveJob
            Assert-Equal -Expected 'released' -Actual $b.Outcome -Because $flag
            Assert-True $b.Held 'it parked'
            Assert-True ($returnedAt -ge $removedAt) 'released only after the consumer removed the flag'
            Assert-True (@($b.Controls) -contains $flag) 'the held control is reported'
            Assert-True (Test-Path -LiteralPath $heartbeat) 'the heartbeat was refreshed'
            Start-Sleep -Milliseconds 150
            Assert-Equal -Expected $diskBefore -Actual (Get-FileHash -LiteralPath $disk).Hash
            Assert-Equal -Expected $diskTime -Actual ([IO.File]::GetLastWriteTimeUtc($disk))
            Assert-True (Test-Path -LiteralPath (Join-Path $t.Runtime 'control.cycle-restart')) 'the restart request is left for its consumer'
        }
    }
    It 'passes straight through with nothing held' {
        $t = New-TestRoot
        $b = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -ShutdownState @{ Requested = $false } -PollDelay $script:NoDelay
        Assert-Equal -Expected 'none' -Actual $b.Outcome
        Assert-False $b.Held 'nothing held'
    }
    It 'hands a lab hold to the lab-health gate, clears a hold the gate finds healthy, honors a release, and reports exhaustion' {
        $t = New-TestRoot
        $hold = Join-Path $t.Runtime 'control.lab-hold'
        Set-Content -LiteralPath $hold -Value 'stash' -Encoding utf8NoBOM
        $global:__barrierGateCalls = 0
        function global:Test-LabHoldReleaseRequested { param($RuntimeDir) $null = $RuntimeDir; $false }
        function global:Invoke-LabHealthGate { param($Label, $Config, $HostType, $Stage) $null = $Label, $Config, $HostType, $Stage; $global:__barrierGateCalls++; @{ Held = $false; Outcome = 'none' } }
        function global:Clear-LabHold { [CmdletBinding(SupportsShouldProcess)] [OutputType([bool])] param($RuntimeDir) if ($PSCmdlet.ShouldProcess($RuntimeDir)) { Remove-Item -LiteralPath (Join-Path $RuntimeDir 'control.lab-hold') -Force }; $true }
        $b = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -ShutdownState @{ Requested = $false } -PollDelay $script:NoDelay 6>$null
        Assert-Equal -Expected 'released' -Actual $b.Outcome
        Assert-Equal -Expected 1 -Actual $global:__barrierGateCalls
        Assert-False (Test-Path -LiteralPath $hold) 'the healthy gate''s hold was cleared'
        Set-Content -LiteralPath $hold -Value 'stash' -Encoding utf8NoBOM
        function global:Test-LabHoldReleaseRequested { param($RuntimeDir) $null = $RuntimeDir; $true }
        $released = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -ShutdownState @{ Requested = $false } -PollDelay $script:NoDelay 6>$null
        Assert-Equal -Expected 'released' -Actual $released.Outcome -Because 'an operator release ends the hold'
        Set-Content -LiteralPath $hold -Value 'stash' -Encoding utf8NoBOM
        function global:Test-LabHoldReleaseRequested { param($RuntimeDir) $null = $RuntimeDir; $false }
        function global:Invoke-LabHealthGate {
            param($Label, $Config, $HostType, $Stage) $null = $Label, $Config, $HostType, $Stage
            $e = [System.Management.Automation.RuntimeException]::new('YurunaLabDependencyDown: gave up')
            $e.Data['YurunaLabDependencyDown'] = $true
            throw $e
        }
        $exhausted = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -ShutdownState @{ Requested = $false } -PollDelay $script:NoDelay 6>$null
        Assert-Equal -Expected 'lab-exhausted' -Actual $exhausted.Outcome
        Assert-True (Test-Path -LiteralPath $hold) 'an exhausted hold is not cleared'
        Remove-Variable __barrierGateCalls -Scope Global -ErrorAction SilentlyContinue
    }
    It 'ends on shutdown' {
        $t = New-TestRoot
        Set-Content -LiteralPath (Join-Path $t.Runtime 'control.pause') -Value 'x' -Encoding utf8NoBOM
        $b = Wait-YurunaHeldControlBarrier -RuntimeDir $t.Runtime -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -ShutdownState @{ Requested = $true } -PollDelay $script:NoDelay
        Assert-Equal -Expected 'shutdown' -Actual $b.Outcome
        Assert-True (Test-Path -LiteralPath (Join-Path $t.Runtime 'control.pause')) 'the pause flag is never deleted here'
    }
}

Describe 'Preflight inner helpers' {
    BeforeEach {
        $script:SavedEnv = @{}
        foreach ($name in @('YURUNA_REFRESH_PREFLIGHT', 'YURUNA_REFRESH_HANDOFF_TOKEN', 'YURUNA_REFRESH_BARRIER')) {
            $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }
    AfterEach {
        foreach ($name in $script:SavedEnv.Keys) {
            if ($null -eq $script:SavedEnv[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
        }
        Remove-Item function:Test-VirtualizationResponsive, function:global:Initialize-YurunaHost, function:global:Write-RunnerPhase -ErrorAction SilentlyContinue
    }
    It 'reads the refresh role from the environment' {
        Assert-Equal -Expected 'normal' -Actual (Get-YurunaRefreshInnerMode -RuntimeDir $script:Work).Mode
        $env:YURUNA_REFRESH_BARRIER = $script:RequestId
        $barrier = Get-YurunaRefreshInnerMode -RuntimeDir $script:Work
        Assert-Equal -Expected 'barrier' -Actual $barrier.Mode
        Assert-Equal -Expected $script:RequestId -Actual $barrier.RequestId
        $env:YURUNA_REFRESH_PREFLIGHT = '1'
        $env:YURUNA_REFRESH_HANDOFF_TOKEN = 'not-a-token'
        $preflight = Get-YurunaRefreshInnerMode -RuntimeDir $script:Work
        Assert-Equal -Expected 'preflight' -Actual $preflight.Mode -Because 'an invalid token is still a preflight, which then acknowledges failure'
        Assert-False $preflight.Token.Valid 'the token did not validate'
    }
    It 'acknowledges each failure class, and ready only on a Responsive probe' {
        $t = New-TestRoot
        Set-Content -LiteralPath (Join-Path $t.Runtime 'control.lab-hold') -Value 'x' -Encoding utf8NoBOM
        $script:Acks = [System.Collections.Generic.List[hashtable]]::new()
        Mock -ModuleName Test.RunnerInnerLoop Write-YurunaRunnerReadinessAck {
            $script:Acks.Add(@{ TokenId = $TokenId; Role = $Role; State = $State; FailureReason = $FailureReason; PreservedControl = @($PreservedControl) })
            $true
        }
        # Not loaded in this process: the host driver import and the phase
        # writer are the inner entry point's; stand-ins resolve globally.
        function global:Initialize-YurunaHost { param($RepoRoot, $HostType) $null = $RepoRoot, $HostType; 'driver' }
        function global:Write-RunnerPhase { param($Phase) $null = $Phase }
        $valid = [pscustomobject]@{ Mode = 'preflight'; TokenId = ('a' * 32); RequestId = $script:RequestId; Purpose = 'new-outer'; Token = [pscustomobject]@{ Valid = $true } }
        $invalid = [pscustomobject]@{ Mode = 'preflight'; TokenId = ('a' * 32); RequestId = $null; Purpose = $null; Token = [pscustomobject]@{ Valid = $false } }
        $deadline = New-YurunaDeadline -TotalMilliseconds 30000
        $run = { param($Mode, $Config, $HostType)
            Invoke-YurunaRefreshPreflight -Mode $Mode -HostType $HostType -RepoRoot $script:RepoRoot -Config $Config `
                -StepHeartbeatFile (Join-Path $t.Runtime 'hb') -Deadline $deadline -RuntimeDir $t.Runtime 6>$null }
        Assert-Equal -Expected 'token-invalid' -Actual (& $run $invalid @{} 'host.ubuntu.kvm').FailureReason
        Assert-Equal -Expected 'config-unreadable' -Actual (& $run $valid $null 'host.ubuntu.kvm').FailureReason
        Assert-Equal -Expected 'host-type-unknown' -Actual (& $run $valid @{} '').FailureReason
        Assert-Equal -Expected 'probe-unavailable' -Actual (& $run $valid @{} 'host.ubuntu.kvm').FailureReason
        function global:Test-VirtualizationResponsive { param($TimeoutSeconds, $Deadline) $null = $TimeoutSeconds, $Deadline; [pscustomobject]@{ state = 'Unresponsive'; reason = 'timeout'; elapsedMs = 5 } }
        Assert-Equal -Expected 'probe-unresponsive' -Actual (& $run $valid @{} 'host.ubuntu.kvm').FailureReason
        function global:Test-VirtualizationResponsive { param($TimeoutSeconds, $Deadline) $null = $TimeoutSeconds, $Deadline; [pscustomobject]@{ state = 'Undetermined'; reason = 'missing-client'; elapsedMs = 5 } }
        Assert-Equal -Expected 'probe-undetermined' -Actual (& $run $valid @{} 'host.ubuntu.kvm').FailureReason
        function global:Test-VirtualizationResponsive { param($TimeoutSeconds, $Deadline) $null = $TimeoutSeconds, $Deadline; [pscustomobject]@{ state = 'Responsive'; reason = 'responsive'; elapsedMs = 5 } }
        $ready = & $run $valid @{} 'host.ubuntu.kvm'
        Assert-Equal -Expected 'ready' -Actual $ready.State
        Assert-True $ready.AckWritten 'acknowledged'
        $last = $script:Acks[$script:Acks.Count - 1]
        Assert-Equal -Expected 'ready' -Actual $last.State
        Assert-Equal -Expected 'inner' -Actual $last.Role
        Assert-True (@($last.PreservedControl) -contains 'control.lab-hold') 'the controls present are acknowledged'
        Assert-Equal -Expected 7 -Actual $script:Acks.Count -Because 'every outcome was acknowledged'
    }
    It 'parks a new-outer preflight until released, revoked or expired; a resident-outer preflight does not park' {
        $hb = Join-Path $script:Work 'park.hb'
        Assert-Equal -Expected 'not-parked' -Actual (Wait-YurunaRefreshRelease -TokenId ('a' * 32) -Purpose 'resident-outer' -StepHeartbeatFile $hb -ShutdownState @{ Requested = $false }).Outcome
        Assert-Equal -Expected 'shutdown' -Actual (Wait-YurunaRefreshRelease -TokenId ('a' * 32) -Purpose 'new-outer' -StepHeartbeatFile $hb -ShutdownState @{ Requested = $true }).Outcome
        $script:GateCalls = 0
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState {
            $script:GateCalls++
            if ($script:GateCalls -lt 3) { [pscustomobject]@{ State = 'handoff'; PreflightAllowed = $true; ExpiresTick = [Environment]::TickCount64 + 60000 } }
            else { [pscustomobject]@{ State = 'open'; PreflightAllowed = $false } }
        }
        Assert-Equal -Expected 'released' -Actual (Wait-YurunaRefreshRelease -TokenId ('a' * 32) -Purpose 'new-outer' -StepHeartbeatFile $hb -ShutdownState @{ Requested = $false } -PollMilliseconds 10).Outcome
        Assert-True (Test-Path -LiteralPath $hb) 'the heartbeat is refreshed while parked'
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'recovery-pending'; PreflightAllowed = $false } }
        Assert-Equal -Expected 'revoked' -Actual (Wait-YurunaRefreshRelease -TokenId ('a' * 32) -Purpose 'new-outer' -StepHeartbeatFile $hb -ShutdownState @{ Requested = $false } -PollMilliseconds 10).Outcome
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'handoff'; PreflightAllowed = $false; ExpiresTick = [long]1 } }
        Assert-Equal -Expected 'expired' -Actual (Wait-YurunaRefreshRelease -TokenId ('a' * 32) -Purpose 'new-outer' -StepHeartbeatFile $hb -ShutdownState @{ Requested = $false } -PollMilliseconds 10).Outcome
    }
}

Describe 'Inner cycle gate sites' {
    BeforeAll {
        function New-InnerState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory cycle State hashtable; no system state.')]
            param([string]$Runtime)
            @{
                RepoRoot = $script:RepoRoot; TestRoot = (Join-Path $script:RepoRoot 'test'); SequencesDir = 'x'; ScreenshotsDir = 'x'
                StatusFile = (Join-Path $Runtime 'status.json'); ConfigPath = 'x'; TemplatePath = 'x'; HostType = 'host.ubuntu.kvm'
                ModulesDir = $script:Here; StartScript = 'x'; StepHeartbeatFile = (Join-Path $Runtime 'hb'); ShutdownState = @{ Requested = $false }
                RunnerCfgState = @{ StopOnFailure = $false; GetImageRefreshSeconds = 1; CycleDelaySeconds = 0 }; Config = @{}
                NoStatusService = $true; NoGitPull = $false; NoProjectClone = $true; CycleDelaySeconds = 0; CachingProxyServiceUrl = $null
            }
        }
    }
    BeforeEach {
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $script:T = New-TestRoot
        $env:YURUNA_RUNTIME_DIR = $script:T.Runtime
        Mock -ModuleName Test.RunnerInnerLoop Initialize-CycleGatingState {
            @{ CycleCount = 4; ConsecutiveCrashes = 0; FailuresBeforeAlert = 3; SuccessesBeforeRearm = 2; ConsecutiveFailures = 2
               ConsecutiveSuccesses = 0; AlertArmed = $true; GatingFile = 'gating.json' }
        }
        $global:__innerCalls = [System.Collections.Generic.List[string]]::new()
        function global:Invoke-GitPull { param($RepoRoot) $null = $RepoRoot; $global:__innerCalls.Add('Invoke-GitPull'); $true }
        function global:Assert-HostConditionSet { param($HostType) $null = $HostType; $global:__innerCalls.Add('Assert-HostConditionSet'); $true }
        function global:Initialize-HostDisplay { param($HostType) $null = $HostType }
        function global:Initialize-HostMetricsExporter { param($HostType) $null = $HostType }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item function:Invoke-GitPull, function:global:Assert-HostConditionSet, function:global:Initialize-HostDisplay, function:global:Initialize-HostMetricsExporter -ErrorAction SilentlyContinue
        Remove-Variable __innerCalls -Scope Global -ErrorAction SilentlyContinue
    }
    It 'ends the cycle at its start, before any host work, while the gate holds; counters untouched' {
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState { [pscustomobject]@{ SpawnAllowed = $false; RequestId = 'r-1'; State = 'closed' } }
        $state = New-InnerState -Runtime $script:T.Runtime
        Invoke-RunnerInnerCycle -State $state 6>$null
        Assert-True $state.RefreshGated 'held'
        Assert-True $state.OverallPassed 'neither a pass nor a failure is recorded'
        Assert-Equal -Expected 2 -Actual $state.ConsecutiveFailures -Because 'the gating counters are untouched'
        Assert-Equal -Expected 0 -Actual $global:__innerCalls.Count -Because 'no host check and no pull ran'
        $sidecar = Get-Content -LiteralPath (Join-Path $script:T.Runtime 'runner.refresh-gated.json') -Raw | ConvertFrom-Json
        Assert-Equal -Expected 'cycle-start' -Actual $sidecar.site
        Assert-Equal -Expected $PID -Actual $sidecar.innerPid
        Assert-Equal -Expected 'r-1' -Actual $sidecar.requestId
    }
    It 'ends the cycle before the pull when the gate closes during the host checks' {
        $script:GateReads = 0
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState {
            $script:GateReads++
            [pscustomobject]@{ SpawnAllowed = ($script:GateReads -lt 2); RequestId = 'r-2'; State = $(if ($script:GateReads -lt 2) { 'open' } else { 'closed' }) }
        }
        $state = New-InnerState -Runtime $script:T.Runtime
        Invoke-RunnerInnerCycle -State $state 6>$null
        Assert-True $state.RefreshGated 'held'
        Assert-Equal -Expected 'Assert-HostConditionSet' -Actual ($global:__innerCalls -join ',') -Because 'the pull never ran'
        Assert-Equal -Expected 'git-pull' -Actual (Get-Content -LiteralPath (Join-Path $script:T.Runtime 'runner.refresh-gated.json') -Raw | ConvertFrom-Json).site
    }
    It 'passes an open gate and writes nothing' {
        Mock -ModuleName Test.RunnerInnerLoop Get-YurunaRefreshGateState { [pscustomobject]@{ SpawnAllowed = $true; RequestId = $null; State = 'open' } }
        Assert-True (Test-YurunaRefreshCycleGate -Site 'cycle-start' -RuntimeDir $script:T.Runtime) 'open'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:T.Runtime 'runner.refresh-gated.json')) 'no sidecar'
    }
    It 'checks the gate before the cycle-start sweep and closes the cycle log there' {
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $script:Here 'Test.RunnerInnerLoop.psm1') -Name 'Invoke-RunnerInnerCycle'
        $calls = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $siteLine = @($calls | Where-Object { $_.GetCommandName() -eq 'Test-YurunaRefreshCycleGate' -and $_.Extent.Text -match 'cycle-start-sweep' })[0].Extent.StartLineNumber
        $sweepLine = @($calls | Where-Object { $_.GetCommandName() -eq 'Remove-CycleStartOrphanVM' })[0].Extent.StartLineNumber
        $pullLine = @($calls | Where-Object { $_.GetCommandName() -eq 'Invoke-GitPull' })[0].Extent.StartLineNumber
        $pullSite = @($calls | Where-Object { $_.GetCommandName() -eq 'Test-YurunaRefreshCycleGate' -and $_.Extent.Text -match "'git-pull'" })[0].Extent.StartLineNumber
        foreach ($offset in @($siteLine, $sweepLine, $pullLine, $pullSite)) { Assert-NotNull $offset 'every ordering anchor must exist' }
        Assert-True ($siteLine -lt $sweepLine) 'the sweep site precedes Remove-CycleStartOrphanVM'
        Assert-True ($pullSite -lt $pullLine) 'the pull site precedes Invoke-GitPull'
        $ifs = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'cycle-start-sweep' }, $true))
        $body = @($ifs[0].Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($name in @('Complete-Run', 'Stop-LogFile')) { Assert-True ($body -contains $name) "the sweep site closes the cycle with $name" }
        $completeRun = @($ifs[0].Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Complete-Run' }, $true))[0]
        $statusIndex = [array]::FindIndex([object[]]$completeRun.CommandElements, [Predicate[object]]{ param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'OverallStatus' })
        Assert-Equal -Expected 'skipped' -Actual $completeRun.CommandElements[$statusIndex + 1].SafeGetValue() -Because 'a held cycle is neither a pass nor a failure in the status history'
    }
}

Describe 'Inner entry script source order' {
    It 'runs the barrier before any VM or control mutation, and ends a preflight before any host registration' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/modules/Invoke-TestRunnerInnerLoop.ps1')
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $first = {
            param([string]$Name)
            $call = @($calls | Where-Object { $_.GetCommandName() -eq $Name }) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
            Assert-NotNull $call "required barrier-order command: $Name"
            return $call.Extent.StartLineNumber
        }
        $barrier = & $first 'Wait-YurunaHeldControlBarrier'
        foreach ($later in @('Update-StashServiceMarkerAddress', 'Assert-HostConditionSet', 'Stop-ConcurrentVM', 'Restore-YurunaServiceVM', 'Clear-StaleControlState')) {
            Assert-True ($barrier -lt (& $first $later)) "the barrier precedes $later"
        }
        $preflightExit = & $first 'Wait-YurunaRefreshRelease'
        foreach ($later in @('Write-HostRegistrationRecord', 'Update-StashServiceMarkerAddress', 'Initialize-YurunaHost', 'Stop-ConcurrentVM')) {
            Assert-True ($preflightExit -lt (& $first $later)) "the preflight ends before $later"
        }
        Assert-True ((& $first 'Write-YurunaProcessStartRecord') -lt (& $first 'Write-YurunaStateFile')) 'inner.start is written before inner.pid'
    }
}
