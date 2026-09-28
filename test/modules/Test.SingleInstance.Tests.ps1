<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42645f00-faa2-428e-bbc3-6249194cf5b0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner pidfile single-instance pester
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
    Pester coverage for Test.SingleInstance.psm1: the None / Self / Stale /
    OtherRunner classification of a prior pidfile, the StartTime-sidecar
    identity precedence over the cmdline regex, the compare-and-set pidfile
    write that decides a two-runner race, the stale-runner takeover, and the
    strict AliveOwned / AliveOther / DeadOrRecycled / Unknown / Missing
    classifier with its generation-exact record removal.
.DESCRIPTION
    Every case is exercised against real processes -- a live child, a child
    that has already exited -- rather than a stubbed Get-Process, because the
    classification IS the platform lookup. Misclassifying a live runner as
    Stale lets two runners fight over the same VMs; misclassifying an unrelated
    process as OtherRunner kills an innocent PID.

    Throw-based assertions rather than Should.
    Run: pwsh -NoProfile -File test/modules/Test.SingleInstance.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# --- REGION: https://yuruna.link/42d69dfa-0015
function Start-TestChildProcess {
    <#
    .SYNOPSIS
        Spawn a windowless pwsh child running -Command $Command; returns the
        Process. The pwsh hosting this run is used verbatim so the child never
        depends on PATH resolution.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: spawns a short-lived child process the caller kills; no ShouldProcess surface needed.')]
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Mandatory)][string]$Command)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-Command')
    $psi.ArgumentList.Add($Command)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # StartTime is the identity the sidecar cross-check compares against, so
    # wait until the OS has actually published the process.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 50
    }
    return $p
}

function Get-TestSleeperProcess {
    <#
    .SYNOPSIS
        A live child process that is NOT a runner, parked long enough for the
        classification calls to inspect it.
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param()
    return (Start-TestChildProcess -Command 'Start-Sleep -Seconds 90')
}

function Get-TestDeadPid {
    <#
    .SYNOPSIS
        The PID of a child process that has already exited.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $p = Start-TestChildProcess -Command 'exit 0'
    $p.WaitForExit()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 50
    }
    return $p.Id
}

function Get-TestProcessStartIso {
    <#
    .SYNOPSIS
        The StartTime sidecar value Write-RunnerPidFile would record for a PID,
        optionally skewed to probe the 2s tolerance window.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [double]$SkewSeconds = 0
    )
    return (Get-Process -Id $ProcessId).StartTime.ToUniversalTime().AddSeconds($SkewSeconds).ToString('o')
}

$TempRoot = [System.IO.Path]::GetTempPath()

$StateDir = Join-Path $TempRoot ('yuruna-si-state-' + [guid]::NewGuid().ToString('N'))
$script:StatePidFile = Join-Path $StateDir 'runner.pid'
$script:StateStartFile = Join-Path $StateDir 'runner.start'

$WriteDir = Join-Path $TempRoot ('yuruna-si-write-' + [guid]::NewGuid().ToString('N'))
$script:WritePidFile = Join-Path $WriteDir 'runner.pid'
$script:WriteStartFile = Join-Path $WriteDir 'runner.start'

$StopDir = Join-Path $TempRoot ('yuruna-si-stop-' + [guid]::NewGuid().ToString('N'))
$script:StopCleanupScript = Join-Path $StopDir 'Remove-TestVMFiles.ps1'
$script:StopCleanupMarker = Join-Path $StopDir 'cleanup-ran.txt'
$script:StopEmptyDir = Join-Path $TempRoot ('yuruna-si-empty-' + [guid]::NewGuid().ToString('N'))

}

Describe 'Get-RunnerInstanceState' {
    BeforeAll { $null = New-Item -ItemType Directory -Path $StateDir -Force }
    AfterAll { Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { Remove-Item -LiteralPath $script:StatePidFile, $script:StateStartFile -Force -ErrorAction SilentlyContinue }

    It 'reports None when no pidfile exists' {
        $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
        Assert-Equal -Expected 'None' -Actual $s.status
        Assert-Equal -Expected 0 -Actual $s.pid
        Assert-Equal -Expected 'none' -Actual $s.identityVia
    }
    It 'reports Stale for a pidfile that holds no usable PID' {
        foreach ($junk in @('garbage', '', '0', '-5')) {
            Set-Content -LiteralPath $script:StatePidFile -Value $junk -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
            Assert-Equal -Expected 'Stale' -Actual $s.status -Because "a pidfile holding '$junk' is stale, not a live runner"
            Assert-Equal -Expected 0 -Actual $s.pid
        }
    }
    It 'reports Self when the pidfile holds this process' {
        Set-Content -LiteralPath $script:StatePidFile -Value "$PID" -Encoding utf8NoBOM
        $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
        Assert-Equal -Expected 'Self' -Actual $s.status -Because 'a runner must never try to take itself over'
        Assert-Equal -Expected $PID -Actual $s.pid
    }
    It 'reports Stale when the recorded PID is gone' {
        $deadPid = Get-TestDeadPid
        Set-Content -LiteralPath $script:StatePidFile -Value "$deadPid" -Encoding utf8NoBOM
        $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
        Assert-Equal -Expected 'Stale' -Actual $s.status
        Assert-Equal -Expected $deadPid -Actual $s.pid -Because 'the dead PID is still reported so the caller can log it'
        Assert-Equal -Expected 'none' -Actual $s.identityVia
    }
    It 'reports Stale for a live process that is not a runner' {
        # PID reuse: the pidfile survived, but the OS handed the number to some
        # unrelated process. Taking THAT over would kill an innocent process.
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
            Assert-Equal -Expected 'Stale' -Actual $s.status
            Assert-Equal -Expected 'none' -Actual $s.identityVia
            Assert-True ([bool]$s.cmdline) 'the cmdline it rejected is reported for diagnosis'
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'reports OtherRunner when the cmdline matches the identity regex' {
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'Start-Sleep'
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status
            Assert-Equal -Expected 'cmdline' -Actual $s.identityVia
            Assert-Equal -Expected $sleeper.Id -Actual $s.pid
            Assert-True ($s.cmdline -match 'Start-Sleep') 'the whole cmdline is captured, not truncated to the terminal width'
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'takes over a stranded inner runner with the default identity regex' {
        # The default regex matches Start-TestRunner.ps1 AND
        # Invoke-TestRunnerInnerLoop.ps1, so an orphaned inner is reclaimed too.
        $inner = Start-TestChildProcess -Command 'Start-Sleep -Seconds 90 # Invoke-TestRunnerInnerLoop.ps1'
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($inner.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status
            Assert-Equal -Expected 'cmdline' -Actual $s.identityVia
        } finally {
            if (-not $inner.HasExited) { $inner.Kill() }
        }
    }
    It 'prefers the StartTime sidecar over the cmdline regex' {
        # The sidecar works from any launch shape, including a bare interactive
        # pwsh whose argv carries no script name at all.
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $script:StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id) -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'never-matches-anything'
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status
            Assert-Equal -Expected 'startTime' -Actual $s.identityVia -Because 'the sidecar decides identity before the regex is consulted'

            # 1.5s of skew is inside the tolerance that absorbs round-trip
            # precision loss.
            Set-Content -LiteralPath $script:StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id -SkewSeconds 1.5) -Encoding utf8NoBOM
            $near = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'never-matches-anything'
            Assert-Equal -Expected 'OtherRunner' -Actual $near.status
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'rejects a sidecar whose StartTime belongs to a different process' {
        # Beyond the tolerance the sidecar is not this process: fall back to the
        # cmdline regex, and with no match the occupant is Stale.
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $script:StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id -SkewSeconds 30) -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'never-matches-anything'
            Assert-Equal -Expected 'Stale' -Actual $s.status

            $s2 = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'Start-Sleep'
            Assert-Equal -Expected 'OtherRunner' -Actual $s2.status -Because 'the cmdline fallback still gets its say'
            Assert-Equal -Expected 'cmdline' -Actual $s2.identityVia
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'falls back to the cmdline regex when the sidecar is unparseable' {
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $script:StateStartFile -Value 'not-a-timestamp' -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $script:StatePidFile -RunnerStartFile $script:StateStartFile -CmdLinePattern 'Start-Sleep'
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status -Because 'a corrupt sidecar degrades to the older identity path, it does not throw'
            Assert-Equal -Expected 'cmdline' -Actual $s.identityVia
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
}

Describe 'Write-RunnerPidFile' {
    BeforeAll { $null = New-Item -ItemType Directory -Path $WriteDir -Force }
    AfterAll { Remove-Item -LiteralPath $WriteDir -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { Remove-Item -LiteralPath $script:WritePidFile, $script:WriteStartFile -Force -ErrorAction SilentlyContinue }

    It 'publishes the pidfile and its StartTime sidecar' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile)
        Assert-Equal -Expected "$PID" -Actual (Get-Content -Raw -LiteralPath $script:WritePidFile).Trim()

        $recorded = [DateTimeOffset]::Parse((Get-Content -Raw -LiteralPath $script:WriteStartFile).Trim()).UtcDateTime
        $live = (Get-Process -Id $PID).StartTime.ToUniversalTime()
        Assert-True ([Math]::Abs(($recorded - $live).TotalSeconds) -le 2) 'the sidecar records this process StartTime'
    }
    It 'writes a pair the reader classifies as Self' {
        $null = Write-RunnerPidFile -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile
        $s = Get-RunnerInstanceState -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile
        Assert-Equal -Expected 'Self' -Actual $s.status
    }
    It 'loses the race instead of clobbering an existing pidfile' {
        # CreateNew + FileShare.None makes the write a compare-and-set: two
        # operators launching at the same moment cannot both believe they won.
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile)
        $winner = (Get-Content -Raw -LiteralPath $script:WritePidFile).Trim()

        $second = Write-RunnerPidFile -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $second -Because 'the loser must be told it lost'
        Assert-Equal -Expected $winner -Actual (Get-Content -Raw -LiteralPath $script:WritePidFile).Trim() -Because "the winner's pidfile survives the loser"
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $WriteDir -Filter '*.tmp').Count -Because 'the loser cleans up its staged sidecar'
    }
    It 'writes the pidfile even when no sidecar path is supplied' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $script:WritePidFile)
        Assert-Equal -Expected "$PID" -Actual (Get-Content -Raw -LiteralPath $script:WritePidFile).Trim()
        Assert-True (-not (Test-Path -LiteralPath $script:WriteStartFile)) 'no sidecar is written when none was asked for'
    }
    It 'writes nothing under -WhatIf' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $script:WritePidFile -RunnerStartFile $script:WriteStartFile -WhatIf)
        Assert-True (-not (Test-Path -LiteralPath $script:WritePidFile)) 'a -WhatIf write must not create the pidfile'
    }
}

Describe 'Stop-StaleRunner' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $StopDir -Force
        $null = New-Item -ItemType Directory -Path $script:StopEmptyDir -Force
        # Stand-in for Remove-TestVMFiles.ps1: records the -Prefix it was
        # handed, so the takeover's orphan-VM sweep is observable.
        @(
            "param([string]`$Prefix = '(none)')"
            "Set-Content -LiteralPath '$script:StopCleanupMarker' -Value `$Prefix -Encoding utf8NoBOM"
            'exit 0'
        ) -join [Environment]::NewLine | Set-Content -LiteralPath $script:StopCleanupScript -Encoding utf8NoBOM
    }
    AfterAll {
        Remove-Item -LiteralPath $StopDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:StopEmptyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Remove-Item -LiteralPath $script:StopCleanupMarker -Force -ErrorAction SilentlyContinue }

    It 'stops the prior occupant and clears orphan VMs with the given prefix' {
        $victim = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $victim.Id -TestRoot $StopDir -CleanupPrefix 'unit-' -Confirm:$false
            Assert-True (-not (Get-Process -Id $victim.Id -ErrorAction SilentlyContinue)) 'the prior runner is gone'
            Assert-True (Test-Path -LiteralPath $script:StopCleanupMarker) 'the orphan-VM sweep ran'
            Assert-Equal -Expected 'unit-' -Actual (Get-Content -Raw -LiteralPath $script:StopCleanupMarker).Trim()
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }
    It 'defaults the cleanup prefix to the test- VM prefix' {
        $victim = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $victim.Id -TestRoot $StopDir -Confirm:$false
            Assert-Equal -Expected 'test-' -Actual (Get-Content -Raw -LiteralPath $script:StopCleanupMarker).Trim()
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }
    It 'still clears orphan VMs when the PID is already gone' {
        # The operator killed the runner by hand; the VMs it stranded are still
        # there and the next cycle would fight them.
        Stop-StaleRunner -ProcessId (Get-TestDeadPid) -TestRoot $StopDir -CleanupPrefix 'gone-' -Confirm:$false
        Assert-Equal -Expected 'gone-' -Actual (Get-Content -Raw -LiteralPath $script:StopCleanupMarker).Trim()
    }
    It 'does not throw when there is no cleanup script to run' {
        # Best-effort by contract: a caller racing the kill needs progress, not
        # a bail-out.
        Stop-StaleRunner -ProcessId (Get-TestDeadPid) -TestRoot $script:StopEmptyDir -Confirm:$false
        Assert-True (-not (Test-Path -LiteralPath $script:StopCleanupMarker)) 'nothing to sweep, nothing swept'
    }
    It 'kills nothing and cleans nothing under -WhatIf' {
        $survivor = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $survivor.Id -TestRoot $StopDir -WhatIf
            Assert-True ([bool](Get-Process -Id $survivor.Id -ErrorAction SilentlyContinue)) 'a -WhatIf takeover must not kill the process'
            Assert-True (-not (Test-Path -LiteralPath $script:StopCleanupMarker)) 'a -WhatIf takeover must not sweep VMs'
        } finally {
            if (-not $survivor.HasExited) { $survivor.Kill() }
        }
    }
}

Describe 'Get-YurunaProcessIdentityState (injected tables)' {
    BeforeAll {
        function New-IdentityTable {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory process table; no system state.')]
            param([object[]]$Rows = @(), [switch]$Incomplete)
            [pscustomobject]@{ Complete = -not $Incomplete; Platform = 'Linux'; Rows = $Rows }
        }
        function New-IdentityRow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory process row; no system state.')]
            param([int]$ProcessId, [Nullable[long]]$Start = 50000, [string]$CommandLine = 'pwsh', [string]$Owner = '1001')
            [pscustomobject]@{ Pid = $ProcessId; ParentPid = 1; StartTimeUnixMs = $Start; CommandLine = $CommandLine; OwnerId = $Owner }
        }
        $script:Self = New-IdentityRow -ProcessId 10 -Owner '1001'
    }

    It 'classifies this process as AliveOwned by self' {
        $s = Get-YurunaProcessIdentityState -ProcessId 10 -ProcessTable (New-IdentityTable) -SelfPid 10
        Assert-Equal -Expected 'AliveOwned' -Actual $s.State
        Assert-Equal -Expected 'self' -Actual $s.IdentityVia
    }
    It 'reads absence from a complete table as DeadOrRecycled and from an incomplete one as Unknown' {
        Assert-Equal -Expected 'DeadOrRecycled' -Actual (Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable (New-IdentityTable) -SelfPid 1).State
        $u = Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable (New-IdentityTable -Incomplete) -SelfPid 1
        Assert-Equal -Expected 'Unknown' -Actual $u.State
        Assert-Equal -Expected 'table-incomplete' -Actual $u.Reason
    }
    It 'is Unknown when the live start time cannot be read' {
        $s = Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable (New-IdentityTable -Rows @((New-IdentityRow -ProcessId 20 -Start $null))) -RecordedStartTimeUnixMs 50000 -SelfPid 1
        Assert-Equal -Expected 'start-unreadable' -Actual $s.Reason
    }
    It 'reads a start time beyond the tolerance as a recycled PID' {
        $table = New-IdentityTable -Rows @((New-IdentityRow -ProcessId 20 -Start 90000))
        $s = Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 1
        Assert-Equal -Expected 'DeadOrRecycled' -Actual $s.State
        Assert-Equal -Expected 'start-mismatch' -Actual $s.Reason
        $near = Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -RecordedStartTimeUnixMs 88500 -SelfPid 1
        Assert-Equal -Expected 'AliveOwned' -Actual $near.State -Because '1.5 s is inside the tolerance'
    }
    It 'never proves ownership from a record write time; a start after the write is a recycle' {
        $table = New-IdentityTable -Rows @((New-IdentityRow -ProcessId 20 -Start ([DateTimeOffset]::new(2026, 9, 25, 10, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds())))
        $before = [datetime]::SpecifyKind([datetime]'2026-09-25T09:00:00', [DateTimeKind]::Utc)
        $after  = [datetime]::SpecifyKind([datetime]'2026-09-25T11:00:00', [DateTimeKind]::Utc)
        Assert-Equal -Expected 'started-after-record' -Actual (Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -RecordWrittenUtc $before -SelfPid 1).Reason
        $plausible = Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -RecordWrittenUtc $after -SelfPid 1
        Assert-Equal -Expected 'Unknown' -Actual $plausible.State
        Assert-Equal -Expected 'no-exact-identity' -Actual $plausible.Reason
        Assert-Equal -Expected 'no-exact-identity' -Actual (Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -SelfPid 1).Reason
    }
    It 'reads another owner, a non-designated identity and another checkout as AliveOther' {
        $rows = @($script:Self, (New-IdentityRow -ProcessId 20 -Owner '999'), (New-IdentityRow -ProcessId 21),
            (New-IdentityRow -ProcessId 22 -CommandLine 'pwsh -File /other/test/Start-TestRunner.ps1'))
        $table = New-IdentityTable -Rows $rows
        Assert-Equal -Expected 'other-owner' -Actual (Get-YurunaProcessIdentityState -ProcessId 20 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 10).Reason
        $designated = Get-YurunaProcessIdentityState -ProcessId 21 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 10 `
            -ExpectedIdentity ([pscustomobject]@{ Pid = 21; StartTimeUnixMs = [long]70000 })
        Assert-Equal -Expected 'not-designated' -Actual $designated.Reason
        $checkout = Get-YurunaProcessIdentityState -ProcessId 22 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 10 -ExpectedScriptPath @('/repo/test/Start-TestRunner.ps1')
        Assert-Equal -Expected 'AliveOther' -Actual $checkout.State
        Assert-Equal -Expected 'other-checkout' -Actual $checkout.Reason
    }
    It 'resolves a runner script named by a relative path against the process working directory' {
        $expected = @('/repo/test/Start-TestRunner.ps1')
        $cases = @(
            @{ Argv = @('pwsh', '-NoProfile', 'test/Start-TestRunner.ps1'); Cwd = '/repo'; State = 'AliveOwned'; Reason = 'start-time' }
            @{ Argv = @('pwsh', './test/Start-TestRunner.ps1'); Cwd = '/repo'; State = 'AliveOwned'; Reason = 'start-time' }
            @{ Argv = @('pwsh', '-File', 'Start-TestRunner.ps1'); Cwd = '/repo/test'; State = 'AliveOwned'; Reason = 'start-time' }
            @{ Argv = @('pwsh', '-File', '../repo/test/Start-TestRunner.ps1'); Cwd = '/elsewhere'; State = 'AliveOwned'; Reason = 'start-time' }
            @{ Argv = @('pwsh', '-Command', "& './test/Start-TestRunner.ps1'"); Cwd = '/repo'; State = 'AliveOwned'; Reason = 'start-time' }
            @{ Argv = @('pwsh', 'test/Start-TestRunner.ps1'); Cwd = '/other'; State = 'AliveOther'; Reason = 'other-checkout' }
            @{ Argv = @('pwsh', 'test/Start-TestRunner.ps1'); Cwd = $null; State = 'Unknown'; Reason = 'script-path-unresolved' }
        )
        foreach ($case in $cases) {
            $row = [pscustomobject]@{ Pid = 30; ParentPid = 1; StartTimeUnixMs = [long]50000; CommandLine = ($case.Argv -join ' ')
                Argv = [string[]]$case.Argv; OwnerId = '1001'; WorkingDirectory = $case.Cwd }
            $s = Get-YurunaProcessIdentityState -ProcessId 30 -ProcessTable (New-IdentityTable -Rows @($script:Self, $row)) `
                -RecordedStartTimeUnixMs 50000 -SelfPid 10 -ExpectedScriptPath $expected
            $label = "argv '$($case.Argv -join ' ')' from '$($case.Cwd)'"
            Assert-Equal -Expected $case.State -Actual $s.State -Because $label
            Assert-Equal -Expected $case.Reason -Actual $s.Reason -Because $label
        }
    }
    It 'accepts the identity a launch record attests however the command line names the script' {
        $row = [pscustomobject]@{ Pid = 31; ParentPid = 1; StartTimeUnixMs = [long]50000; CommandLine = 'pwsh test/Start-TestRunner.ps1'
            Argv = [string[]]@('pwsh', 'test/Start-TestRunner.ps1'); OwnerId = '1001'; WorkingDirectory = $null }
        $table = New-IdentityTable -Rows @($script:Self, $row)
        $classify = { param($Attested) Get-YurunaProcessIdentityState -ProcessId 31 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 10 `
            -ExpectedScriptPath @('/repo/test/Start-TestRunner.ps1') -AttestedIdentity $Attested }
        Assert-Equal -Expected 'script-path-unresolved' -Actual (& $classify $null).Reason
        $attested = & $classify ([pscustomobject]@{ Pid = 31; StartTimeUnixMs = [long]50500 })
        Assert-Equal -Expected 'AliveOwned' -Actual $attested.State
        Assert-Equal -Expected 'launch-record' -Actual $attested.Reason
        Assert-Equal -Expected 'Unknown' -Actual (& $classify ([pscustomobject]@{ Pid = 31; StartTimeUnixMs = [long]90000 })).State -Because 'an attestation for another start time proves nothing'
        Assert-Equal -Expected 'Unknown' -Actual (& $classify ([pscustomobject]@{ Pid = 32; StartTimeUnixMs = [long]50000 })).State -Because 'an attestation for another PID proves nothing'
        $foreign = [pscustomobject]@{ Pid = 31; ParentPid = 1; StartTimeUnixMs = [long]50000; CommandLine = 'pwsh'; OwnerId = '999' }
        $otherOwner = Get-YurunaProcessIdentityState -ProcessId 31 -ProcessTable (New-IdentityTable -Rows @($script:Self, $foreign)) -RecordedStartTimeUnixMs 50000 -SelfPid 10 `
            -AttestedIdentity ([pscustomobject]@{ Pid = 31; StartTimeUnixMs = [long]50000 })
        Assert-Equal -Expected 'other-owner' -Actual $otherOwner.Reason -Because 'an attestation never overrides another owner'
    }
    It 'accepts a bare interactive pwsh whose start time matches the record' {
        $table = New-IdentityTable -Rows @($script:Self, (New-IdentityRow -ProcessId 23 -CommandLine 'pwsh'))
        $s = Get-YurunaProcessIdentityState -ProcessId 23 -ProcessTable $table -RecordedStartTimeUnixMs 50000 -SelfPid 10 -ExpectedScriptPath @('/repo/test/Start-TestRunner.ps1')
        Assert-Equal -Expected 'AliveOwned' -Actual $s.State
        Assert-Equal -Expected 'start-time' -Actual $s.IdentityVia
    }
}

Describe 'Get-YurunaRunnerRecordState and Remove-YurunaRunnerRecordGeneration (real stand-ins)' {
    BeforeAll {
        $script:RecordDir = New-YurunaTestTempDir -Prefix 'yrn-si-record'
        $script:RecPid = Join-Path $script:RecordDir 'runner.pid'
        $script:RecStart = Join-Path $script:RecordDir 'runner.start'
    }
    AfterAll { Remove-YurunaTestTempDir $script:RecordDir }
    BeforeEach { Remove-Item -LiteralPath $script:RecPid, $script:RecStart -Force -ErrorAction SilentlyContinue }

    It 'is Missing without a pidfile' {
        Assert-Equal -Expected 'Missing' -Actual (Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart).State
    }
    It 'is Unknown for an empty or malformed pidfile, and leaves the file in place' {
        foreach ($junk in @('', 'abc', '-4')) {
            Set-Content -LiteralPath $script:RecPid -Value $junk -Encoding utf8NoBOM -NoNewline
            $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart
            Assert-Equal -Expected 'Unknown' -Actual $s.State -Because "a pidfile holding '$junk' proves nothing"
            Assert-Equal -Expected 'record-malformed' -Actual $s.Reason
            Assert-True (Test-Path -LiteralPath $script:RecPid) 'an unproven record is never deleted'
        }
    }
    It 'is AliveOwned for a live process whose start record matches, DeadOrRecycled when it does not' {
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $script:RecPid -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $script:RecStart -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id) -Encoding utf8NoBOM
            $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart
            Assert-Equal -Expected 'AliveOwned' -Actual $s.State
            Assert-NotNull $s.Fingerprint
            Set-Content -LiteralPath $script:RecStart -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id -SkewSeconds 30) -Encoding utf8NoBOM
            Assert-Equal -Expected 'DeadOrRecycled' -Actual (Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart).State
            Set-Content -LiteralPath $script:RecStart -Value 'not-a-time' -Encoding utf8NoBOM
            Assert-Equal -Expected 'start-record-malformed' -Actual (Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart).Reason
            Set-Content -LiteralPath $script:RecStart -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id) -Encoding utf8NoBOM
            $designated = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart -ExpectedIdentity ([pscustomobject]@{ Pid = 1; StartTimeUnixMs = [long]1 })
            Assert-Equal -Expected 'AliveOther' -Actual $designated.State
            $incomplete = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart `
                -ProcessTable ([pscustomobject]@{ Complete = $false; Platform = 'Linux'; Rows = @() })
            Assert-Equal -Expected 'Unknown' -Actual $incomplete.State
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'is DeadOrRecycled for a process that has exited' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        Assert-Equal -Expected 'DeadOrRecycled' -Actual (Get-YurunaRunnerRecordState -PidFile $script:RecPid).State
    }
    It 'is AliveOther for a live runner of another checkout' -Skip:$IsWindows {
        $other = Start-TestChildProcess -Command 'Start-Sleep -Seconds 90 # /elsewhere/test/Start-TestRunner.ps1'
        try {
            Set-Content -LiteralPath $script:RecPid -Value "$($other.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $script:RecStart -Value (Get-TestProcessStartIso -ProcessId $other.Id) -Encoding utf8NoBOM
            $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart -ExpectedScriptPath @('/repo/test/Start-TestRunner.ps1')
            Assert-Equal -Expected 'AliveOther' -Actual $s.State
            Assert-Equal -Expected 'other-checkout' -Actual $s.Reason
        } finally {
            if (-not $other.HasExited) { $other.Kill() }
        }
    }
    It 'classifies a runner started by a relative path as its own checkout''s, through a link too, and another checkout''s as other' -Skip:(-not $IsLinux) {
        $base = New-YurunaTestTempDir -Prefix 'yrn-si-relative'
        try {
            foreach ($name in @('mine', 'other')) {
                $null = New-Item -ItemType Directory -Path (Join-Path $base "$name/test") -Force
                Set-Content -LiteralPath (Join-Path $base "$name/test/Start-TestRunner.ps1") -Value 'Start-Sleep -Seconds 90' -Encoding utf8NoBOM
            }
            $link = Join-Path $base 'link'
            $null = New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $base 'mine')
            foreach ($spelling in @('test/Start-TestRunner.ps1', './test/Start-TestRunner.ps1')) {
                $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                foreach ($a in @('-NoProfile', '-NonInteractive', $spelling)) { $psi.ArgumentList.Add($a) }
                $psi.WorkingDirectory = Join-Path $base 'mine'
                $psi.UseShellExecute = $false
                $runner = [System.Diagnostics.Process]::Start($psi)
                try {
                    $until = [DateTime]::UtcNow.AddSeconds(10)
                    while (-not (Get-Process -Id $runner.Id -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
                    Set-Content -LiteralPath $script:RecPid -Value "$($runner.Id)" -Encoding utf8NoBOM
                    Set-Content -LiteralPath $script:RecStart -Value (Get-TestProcessStartIso -ProcessId $runner.Id) -Encoding utf8NoBOM
                    foreach ($pair in @(@{ Root = 'mine'; State = 'AliveOwned' }, @{ Root = 'link'; State = 'AliveOwned' }, @{ Root = 'other'; State = 'AliveOther' })) {
                        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart `
                            -ExpectedScriptPath @((Join-Path $base "$($pair.Root)/test/Start-TestRunner.ps1"))
                        Assert-Equal -Expected $pair.State -Actual $s.State -Because "'$spelling' started in mine, judged against $($pair.Root) ($($s.Reason))"
                    }
                } finally {
                    if (-not $runner.HasExited) { $runner.Kill() }
                }
            }
        } finally {
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
            Remove-YurunaTestTempDir $base
        }
    }
    It 'removes exactly the generation it classified, with its start file' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        Set-Content -LiteralPath $script:RecStart -Value '2026-01-01T00:00:00.0000000Z' -Encoding utf8NoBOM
        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart
        Assert-Equal -Expected 'DeadOrRecycled' -Actual $s.State
        $r = Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -StartFile $script:RecStart -Fingerprint $s.Fingerprint -Confirm:$false
        Assert-Equal -Expected 'removed' -Actual $r.Reason
        Assert-False (Test-Path -LiteralPath $script:RecPid) 'the pidfile is gone'
        Assert-False (Test-Path -LiteralPath $script:RecStart) 'its start file is gone'
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $script:RecordDir -Filter '*.reclaim.tmp').Count
    }
    It 'refuses when the record changed after classification, touching nothing' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid
        Set-Content -LiteralPath $script:RecPid -Value '424242' -Encoding utf8NoBOM
        $r = Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -Fingerprint $s.Fingerprint -Confirm:$false
        Assert-Equal -Expected 'changed' -Actual $r.Reason
        Assert-Equal -Expected '424242' -Actual (Get-Content -LiteralPath $script:RecPid -Raw).Trim()
    }
    It 'restores a record replaced between the check and the rename' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid
        Mock -ModuleName Test.SingleInstance Get-YurunaFileFingerprintPart -ParameterFilter { $Path -like '*.reclaim.tmp' } -MockWith { 'a-new-writer' }
        $r = Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -Fingerprint $s.Fingerprint -Confirm:$false
        Assert-Equal -Expected 'restored' -Actual $r.Reason
        Assert-True (Test-Path -LiteralPath $script:RecPid) 'the new generation is back in place'
    }
    It 'puts back a start file that belongs to a new owner' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        Set-Content -LiteralPath $script:RecStart -Value '2026-01-01T00:00:00.0000000Z' -Encoding utf8NoBOM
        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid -StartFile $script:RecStart
        $startLeaf = Split-Path -Leaf $script:RecStart
        Mock -ModuleName Test.SingleInstance Get-YurunaFileFingerprintPart -ParameterFilter { $Path -like "*$startLeaf.*.reclaim.tmp" } -MockWith { 'a-new-owner' }
        $r = Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -StartFile $script:RecStart -Fingerprint $s.Fingerprint -Confirm:$false
        Assert-Equal -Expected 'removed' -Actual $r.Reason
        Assert-True (Test-Path -LiteralPath $script:RecStart) 'the start file of a new owner is never deleted'
    }
    It 'removes nothing under -WhatIf, and reports a missing record' {
        Set-Content -LiteralPath $script:RecPid -Value "$(Get-TestDeadPid)" -Encoding utf8NoBOM
        $s = Get-YurunaRunnerRecordState -PidFile $script:RecPid
        $r = Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -Fingerprint $s.Fingerprint -WhatIf
        Assert-Equal -Expected 'preview' -Actual $r.Reason
        Assert-True (Test-Path -LiteralPath $script:RecPid) 'a preview removes nothing'
        Remove-Item -LiteralPath $script:RecPid -Force
        Assert-Equal -Expected 'missing' -Actual (Remove-YurunaRunnerRecordGeneration -PidFile $script:RecPid -Fingerprint $s.Fingerprint -Confirm:$false).Reason
    }
}

Describe 'Start record and cycle record' {
    BeforeAll { $script:CycleDir = New-YurunaTestTempDir -Prefix 'yrn-si-cycle' }
    AfterAll { Remove-YurunaTestTempDir $script:CycleDir }

    It 'writes inner.start in the runner.start shape, and nothing under -WhatIf' {
        $path = Join-Path $script:CycleDir 'inner.start'
        Assert-False (Write-YurunaProcessStartRecord -Path $path -WhatIf) 'a preview writes nothing'
        Assert-False (Test-Path -LiteralPath $path) 'nothing was written'
        Assert-True (Write-YurunaProcessStartRecord -Path $path -Confirm:$false) 'written'
        $recorded = [DateTimeOffset]::Parse((Get-Content -LiteralPath $path -Raw).Trim()).UtcDateTime
        Assert-True ([Math]::Abs(($recorded - (Get-Process -Id $PID).StartTime.ToUniversalTime()).TotalSeconds) -le 2) 'this process start time'
    }
    It 'records the spawned cycle process and classifies it from that record' {
        $cycle = Get-TestSleeperProcess
        try {
            Assert-True (Write-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir -Process $cycle -Cycle 7 -CycleGeneration ('a' * 32 + ':7') -Confirm:$false) 'written'
            $doc = Get-Content -LiteralPath (Join-Path $script:CycleDir 'runner.cycle.json') -Raw | ConvertFrom-Json
            Assert-Equal -Expected $cycle.Id -Actual $doc.pid
            Assert-Equal -Expected $PID -Actual $doc.outerPid
            Assert-Equal -Expected ('a' * 32 + ':7') -Actual $doc.cycleGeneration
            $read = Read-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir
            Assert-Equal -Expected 'AliveOwned' -Actual $read.State
            Assert-Equal -Expected 7 -Actual $read.Cycle
            Assert-False (Clear-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir -ProcessId ($cycle.Id + 1) -Confirm:$false) 'another PID never clears the record'
            $cycle.Kill(); $cycle.WaitForExit()
            Assert-Equal -Expected 'DeadOrRecycled' -Actual (Read-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir).State
            Assert-True (Clear-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir -ProcessId $cycle.Id -Confirm:$false) 'cleared by its own PID'
            Assert-Equal -Expected 'Missing' -Actual (Read-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir).State
        } finally {
            if (-not $cycle.HasExited) { $cycle.Kill() }
        }
    }
    It 'is Unknown for a malformed cycle record' {
        Set-Content -LiteralPath (Join-Path $script:CycleDir 'runner.cycle.json') -Value '{"schemaVersion":1,"pid":"x"}' -Encoding utf8NoBOM
        Assert-Equal -Expected 'Unknown' -Actual (Read-YurunaRunnerCycleRecord -RuntimeDir $script:CycleDir).State
        Remove-Item -LiteralPath (Join-Path $script:CycleDir 'runner.cycle.json') -Force
    }
}
