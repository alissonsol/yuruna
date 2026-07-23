<#PSScriptInfo
.VERSION 2026.07.22
.GUID 422aa14c-4ea9-404d-a5eb-6069c11a61fe
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
    write that decides a two-runner race, and the stale-runner takeover.
.DESCRIPTION
    Every case is exercised against real processes -- a live child, a child
    that has already exited -- rather than a stubbed Get-Process, because the
    classification IS the platform lookup. Misclassifying a live runner as
    Stale lets two runners fight over the same VMs; misclassifying an unrelated
    process as OtherRunner kills an innocent PID.

    Throw-based assertions rather than Should.
    Run: pwsh -NoProfile -File test/modules/Test.SingleInstance.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Helpers and path fixtures live at FILE scope, above the first Describe: a
# Describe body runs during discovery and its variables and functions are
# discarded before any It executes, and the run pass stops descending top-level
# statements at the first Describe. Only the PATHS are computed here -- the
# directories, files and child processes they name are side effects, and the
# file body runs twice (discovery, then run), so the creation itself stays
# inside BeforeAll / It bodies.

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
$StatePidFile = Join-Path $StateDir 'runner.pid'
$StateStartFile = Join-Path $StateDir 'runner.start'

$WriteDir = Join-Path $TempRoot ('yuruna-si-write-' + [guid]::NewGuid().ToString('N'))
$WritePidFile = Join-Path $WriteDir 'runner.pid'
$WriteStartFile = Join-Path $WriteDir 'runner.start'

$StopDir = Join-Path $TempRoot ('yuruna-si-stop-' + [guid]::NewGuid().ToString('N'))
$StopCleanupScript = Join-Path $StopDir 'Remove-TestVMFiles.ps1'
$StopCleanupMarker = Join-Path $StopDir 'cleanup-ran.txt'
$StopEmptyDir = Join-Path $TempRoot ('yuruna-si-empty-' + [guid]::NewGuid().ToString('N'))

Describe 'Get-RunnerInstanceState' {
    BeforeAll { $null = New-Item -ItemType Directory -Path $StateDir -Force }
    AfterAll { Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { Remove-Item -LiteralPath $StatePidFile, $StateStartFile -Force -ErrorAction SilentlyContinue }

    It 'reports None when no pidfile exists' {
        $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
        Assert-Equal -Expected 'None' -Actual $s.status
        Assert-Equal -Expected 0 -Actual $s.pid
        Assert-Equal -Expected 'none' -Actual $s.identityVia
    }
    It 'reports Stale for a pidfile that holds no usable PID' {
        foreach ($junk in @('garbage', '', '0', '-5')) {
            Set-Content -LiteralPath $StatePidFile -Value $junk -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
            Assert-Equal -Expected 'Stale' -Actual $s.status -Because "a pidfile holding '$junk' is stale, not a live runner"
            Assert-Equal -Expected 0 -Actual $s.pid
        }
    }
    It 'reports Self when the pidfile holds this process' {
        Set-Content -LiteralPath $StatePidFile -Value "$PID" -Encoding utf8NoBOM
        $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
        Assert-Equal -Expected 'Self' -Actual $s.status -Because 'a runner must never try to take itself over'
        Assert-Equal -Expected $PID -Actual $s.pid
    }
    It 'reports Stale when the recorded PID is gone' {
        $deadPid = Get-TestDeadPid
        Set-Content -LiteralPath $StatePidFile -Value "$deadPid" -Encoding utf8NoBOM
        $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
        Assert-Equal -Expected 'Stale' -Actual $s.status
        Assert-Equal -Expected $deadPid -Actual $s.pid -Because 'the dead PID is still reported so the caller can log it'
        Assert-Equal -Expected 'none' -Actual $s.identityVia
    }
    It 'reports Stale for a live process that is not a runner' {
        # PID reuse: the pidfile survived, but the OS handed the number to some
        # unrelated process. Taking THAT over would kill an innocent process.
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
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
            Set-Content -LiteralPath $StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'Start-Sleep'
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status
            Assert-Equal -Expected 'cmdline' -Actual $s.identityVia
            Assert-Equal -Expected $sleeper.Id -Actual $s.pid
            Assert-True ($s.cmdline -match 'Start-Sleep') 'the whole cmdline is captured, not truncated to the terminal width'
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'takes over a stranded inner runner with the default identity regex' {
        # The default regex matches Invoke-TestRunner.ps1 AND
        # Invoke-TestInnerRunner.ps1, so an orphaned inner is reclaimed too.
        $inner = Start-TestChildProcess -Command 'Start-Sleep -Seconds 90 # Invoke-TestInnerRunner.ps1'
        try {
            Set-Content -LiteralPath $StatePidFile -Value "$($inner.Id)" -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile
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
            Set-Content -LiteralPath $StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id) -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'never-matches-anything'
            Assert-Equal -Expected 'OtherRunner' -Actual $s.status
            Assert-Equal -Expected 'startTime' -Actual $s.identityVia -Because 'the sidecar decides identity before the regex is consulted'

            # 1.5s of skew is inside the tolerance that absorbs round-trip
            # precision loss.
            Set-Content -LiteralPath $StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id -SkewSeconds 1.5) -Encoding utf8NoBOM
            $near = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'never-matches-anything'
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
            Set-Content -LiteralPath $StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $StateStartFile -Value (Get-TestProcessStartIso -ProcessId $sleeper.Id -SkewSeconds 30) -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'never-matches-anything'
            Assert-Equal -Expected 'Stale' -Actual $s.status

            $s2 = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'Start-Sleep'
            Assert-Equal -Expected 'OtherRunner' -Actual $s2.status -Because 'the cmdline fallback still gets its say'
            Assert-Equal -Expected 'cmdline' -Actual $s2.identityVia
        } finally {
            if (-not $sleeper.HasExited) { $sleeper.Kill() }
        }
    }
    It 'falls back to the cmdline regex when the sidecar is unparseable' {
        $sleeper = Get-TestSleeperProcess
        try {
            Set-Content -LiteralPath $StatePidFile -Value "$($sleeper.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath $StateStartFile -Value 'not-a-timestamp' -Encoding utf8NoBOM
            $s = Get-RunnerInstanceState -RunnerPidFile $StatePidFile -RunnerStartFile $StateStartFile -CmdLinePattern 'Start-Sleep'
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
    BeforeEach { Remove-Item -LiteralPath $WritePidFile, $WriteStartFile -Force -ErrorAction SilentlyContinue }

    It 'publishes the pidfile and its StartTime sidecar' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile)
        Assert-Equal -Expected "$PID" -Actual (Get-Content -Raw -LiteralPath $WritePidFile).Trim()

        $recorded = [DateTimeOffset]::Parse((Get-Content -Raw -LiteralPath $WriteStartFile).Trim()).UtcDateTime
        $live = (Get-Process -Id $PID).StartTime.ToUniversalTime()
        Assert-True ([Math]::Abs(($recorded - $live).TotalSeconds) -le 2) 'the sidecar records this process StartTime'
    }
    It 'writes a pair the reader classifies as Self' {
        $null = Write-RunnerPidFile -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile
        $s = Get-RunnerInstanceState -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile
        Assert-Equal -Expected 'Self' -Actual $s.status
    }
    It 'loses the race instead of clobbering an existing pidfile' {
        # CreateNew + FileShare.None makes the write a compare-and-set: two
        # operators launching at the same moment cannot both believe they won.
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile)
        $winner = (Get-Content -Raw -LiteralPath $WritePidFile).Trim()

        $second = Write-RunnerPidFile -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $second -Because 'the loser must be told it lost'
        Assert-Equal -Expected $winner -Actual (Get-Content -Raw -LiteralPath $WritePidFile).Trim() -Because "the winner's pidfile survives the loser"
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $WriteDir -Filter '*.tmp').Count -Because 'the loser cleans up its staged sidecar'
    }
    It 'writes the pidfile even when no sidecar path is supplied' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $WritePidFile)
        Assert-Equal -Expected "$PID" -Actual (Get-Content -Raw -LiteralPath $WritePidFile).Trim()
        Assert-True (-not (Test-Path -LiteralPath $WriteStartFile)) 'no sidecar is written when none was asked for'
    }
    It 'writes nothing under -WhatIf' {
        Assert-Equal -Expected $true -Actual (Write-RunnerPidFile -RunnerPidFile $WritePidFile -RunnerStartFile $WriteStartFile -WhatIf)
        Assert-True (-not (Test-Path -LiteralPath $WritePidFile)) 'a -WhatIf write must not create the pidfile'
    }
}

Describe 'Stop-StaleRunner' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $StopDir -Force
        $null = New-Item -ItemType Directory -Path $StopEmptyDir -Force
        # Stand-in for Remove-TestVMFiles.ps1: records the -Prefix it was
        # handed, so the takeover's orphan-VM sweep is observable.
        @(
            "param([string]`$Prefix = '(none)')"
            "Set-Content -LiteralPath '$StopCleanupMarker' -Value `$Prefix -Encoding utf8NoBOM"
            'exit 0'
        ) -join [Environment]::NewLine | Set-Content -LiteralPath $StopCleanupScript -Encoding utf8NoBOM
    }
    AfterAll {
        Remove-Item -LiteralPath $StopDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StopEmptyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Remove-Item -LiteralPath $StopCleanupMarker -Force -ErrorAction SilentlyContinue }

    It 'stops the prior occupant and clears orphan VMs with the given prefix' {
        $victim = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $victim.Id -TestRoot $StopDir -CleanupPrefix 'unit-' -Confirm:$false
            Assert-True (-not (Get-Process -Id $victim.Id -ErrorAction SilentlyContinue)) 'the prior runner is gone'
            Assert-True (Test-Path -LiteralPath $StopCleanupMarker) 'the orphan-VM sweep ran'
            Assert-Equal -Expected 'unit-' -Actual (Get-Content -Raw -LiteralPath $StopCleanupMarker).Trim()
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }
    It 'defaults the cleanup prefix to the test- VM prefix' {
        $victim = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $victim.Id -TestRoot $StopDir -Confirm:$false
            Assert-Equal -Expected 'test-' -Actual (Get-Content -Raw -LiteralPath $StopCleanupMarker).Trim()
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }
    It 'still clears orphan VMs when the PID is already gone' {
        # The operator killed the runner by hand; the VMs it stranded are still
        # there and the next cycle would fight them.
        Stop-StaleRunner -ProcessId (Get-TestDeadPid) -TestRoot $StopDir -CleanupPrefix 'gone-' -Confirm:$false
        Assert-Equal -Expected 'gone-' -Actual (Get-Content -Raw -LiteralPath $StopCleanupMarker).Trim()
    }
    It 'does not throw when there is no cleanup script to run' {
        # Best-effort by contract: a caller racing the kill needs progress, not
        # a bail-out.
        Stop-StaleRunner -ProcessId (Get-TestDeadPid) -TestRoot $StopEmptyDir -Confirm:$false
        Assert-True (-not (Test-Path -LiteralPath $StopCleanupMarker)) 'nothing to sweep, nothing swept'
    }
    It 'kills nothing and cleans nothing under -WhatIf' {
        $survivor = Get-TestSleeperProcess
        try {
            Stop-StaleRunner -ProcessId $survivor.Id -TestRoot $StopDir -WhatIf
            Assert-True ([bool](Get-Process -Id $survivor.Id -ErrorAction SilentlyContinue)) 'a -WhatIf takeover must not kill the process'
            Assert-True (-not (Test-Path -LiteralPath $StopCleanupMarker)) 'a -WhatIf takeover must not sweep VMs'
        } finally {
            if (-not $survivor.HasExited) { $survivor.Kill() }
        }
    }
}
