<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4226ec4a-0d3b-407b-80ff-4b853f0a15cc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner watchdog identity pid pester
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
    Guards on the watchdog's PID-identity check: it tells the armed inner apart
    from an unrelated process that later reused its PID, and both the disarm and
    the kill decisions honor that identity.
.DESCRIPTION
    Behavioral: the predicate returned by Get-WatchdogInnerIdentityScript (the ONE
    definition the watchdog job rebuilds via [scriptblock]::Create) is true only for
    a live process whose StartTime matches the recorded arm-time value -- the same
    PID with a different StartTime (a reused PID), a gone PID, and an empty recorded
    start are all not-the-same-inner.

    Structural (AST, so a comment cannot satisfy a guard): the watchdog captures the
    inner StartTime at arm ($innerStartUtc), both the disarm and the kill decisions
    are gated on the identity predicate (& $sameInner), and Stop-Process fires only
    inside an identity-gated branch -- so a reused PID is neither mistaken for a live
    inner nor killed. Keyed on AST nodes; all fail if the identity gating is removed.

    The throw-free Should assertions run under Pester 5.x.
#>

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$modPath = Join-Path $here 'Test.RunnerWatchdog.psm1'
Import-Module $modPath -Force

# Unqualified and above the first Describe: an It block resolves a plain file-scope
# name through its parent scope chain, but a $script:-qualified one binds to the test
# framework's own script scope and reads back $null once the run phase starts.
$script:IdentitySb = [scriptblock]::Create((Get-WatchdogInnerIdentityScript))

# --- REGION: https://yuruna.link/42d69dfa-0015
function Get-ModuleAst {
    return Get-YurunaTestFileAst -Path $modPath
}

function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    return (Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $Name)
}

# Count of if-statement conditions whose text matches $Pattern (AST nodes only).
function Get-IfConditionMatchCount {
    param($Ast, [string]$Pattern)
    $pat = $Pattern
    $c = 0
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) { if ($clause.Item1.Extent.Text -match $pat) { $c++ } }
    }
    $c
}

function Get-AssignmentCount {
    param($Ast, [string]$Lhs)
    $wl = $Lhs
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $wl
    }, $true)).Count
}

# True when EVERY kill (a Stop-Process, or a call of the rebuilt tree kill
# `& $treeKill`) sits inside an if-condition matching $Pattern (i.e. the kill
# is identity-gated), and at least one exists.
function Test-StopProcessGatedBy {
    param($Ast, [string]$Pattern)
    $pat = $Pattern
    $stops = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        ($n.GetCommandName() -eq 'Stop-Process' -or $n.CommandElements[0].Extent.Text -eq '$treeKill')
    }, $true))
    if ($stops.Count -lt 1) { return $false }
    foreach ($sp in $stops) {
        $p = $sp.Parent; $gated = $false
        while ($p) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst] -and
                ($p.Clauses[0].Item1.Extent.Text -match $pat)) { $gated = $true; break }
            $p = $p.Parent
        }
        if (-not $gated) { return $false }
    }
    return $true
}

}

Describe 'Get-WatchdogInnerIdentityScript predicate distinguishes a reused PID' {
    It 'is true for a live process whose recorded StartTime matches' {
        $start = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        (& $script:IdentitySb $PID $start) | Should -Be $true
    }
    It 'is false for the SAME live PID with a different StartTime (a reused PID)' {
        (& $script:IdentitySb $PID '2000-01-01T00:00:00.0000000Z') | Should -Be $false
    }
    It 'is false for an exited PID' {
        # -WindowStyle is a Windows-only Start-Process parameter: any other
        # edition throws NotSupportedException on it, and the child there has
        # no window to hide anyway.
        $spawn = @{
            FilePath     = [System.Environment]::ProcessPath
            ArgumentList = @('-NoProfile', '-Command', 'exit')
            PassThru     = $true
        }
        if ($IsWindows) { $spawn.WindowStyle = 'Hidden' }
        $proc = Start-Process @spawn
        $proc.WaitForExit()
        (& $script:IdentitySb $proc.Id '2026-01-01T00:00:00.0000000Z') | Should -Be $false
    }
    It 'is false when no arm-time start was recorded (identity unprovable)' {
        (& $script:IdentitySb $PID '') | Should -Be $false
    }
}

Describe 'Watchdog gates disarm and kill on the armed identity' {
    It 'captures the inner StartTime at arm time' {
        (Get-AssignmentCount -Ast (Get-ModuleAst) -Lhs '$innerStartUtc') | Should -BeGreaterOrEqual 1
    }
    It 'wires the shared identity predicate into the watchdog' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Get-WatchdogInnerIdentityScript') | Should -BeGreaterOrEqual 1
    }
    It 'gates both the disarm and the kill decisions on the identity predicate' {
        (Get-IfConditionMatchCount -Ast (Get-ModuleAst) -Pattern 'sameInner') | Should -BeGreaterOrEqual 2
    }
    It 'kills only inside an identity-gated branch (never an unrelated reused PID)' {
        (Test-StopProcessGatedBy -Ast (Get-ModuleAst) -Pattern 'sameInner') | Should -Be $true
    }
    It 'kills with the shared process-tree kill and carries no tree walk of its own' {
        # A second copy of the walk drifted from the takeover's: no TERM grace,
        # and a different idea of which processes belong to the tree.
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Get-YurunaProcessTreeKillScript') | Should -BeGreaterOrEqual 1
        $text = (Get-ModuleAst).Extent.Text
        $text | Should -Not -Match '/bin/ps\b'
        $text | Should -Not -Match '\btaskkill\b'
    }
}

# Local time moves by an hour at a daylight-saving change, and a heartbeat age
# taken from it killed a healthy inner each spring. The job reads the
# heartbeat's UTC write time and measures the rest on a monotonic clock.
# The watchdog waited up to 180 s for the inner to record itself, the window in
# which a wedged start-up ran unguarded; the cycle process now records the inner
# it started.
Describe 'The cycle process records the inner it starts' {
    It 'writes inner.start and then inner.pid for the started process before waiting on it' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $here 'Test.RunnerOuterLoop.psm1')
        $text = $ast.Extent.Text
        $start = $text.IndexOf('[Diagnostics.Process]::Start($innerStart)')
        $record = $text.IndexOf('Write-YurunaProcessStartRecord -Path $innerStartFile -ProcessId $innerProcess.Id', $start)
        $pidWrite = $text.IndexOf('Write-YurunaStateFile -Path $innerPidFile -Content ([string]$innerProcess.Id)', $start)
        $wait = $text.IndexOf('$innerProcess.WaitForExit()', $start)
        $start | Should -BeGreaterThan 0
        $record | Should -BeGreaterThan $start
        $pidWrite | Should -BeGreaterThan $record
        $wait | Should -BeGreaterThan $pidWrite
    }
}

Describe 'Watchdog measures heartbeat staleness without local wall-clock time' {
    It 'reads no local write time and subtracts no Get-Date' {
        $ast = Get-ModuleAst
        $localStamp = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Member.Value -eq 'LastWriteTime' }, $true))
        $localStamp.Count | Should -Be 0
        $wallSubtraction = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Minus -and
            $n.Left.Extent.Text -match '^\(\s*Get-Date\s*\)$' }, $true))
        $wallSubtraction.Count | Should -Be 0
        (Get-CommandInvokeCount -Ast $ast -Name 'Get-Date') | Should -BeGreaterOrEqual 1 -Because 'log stamps still use it; only the arithmetic moved'
    }
}

Describe 'Watchdog records a proven stop for the current attempt' {
    It 'persists the armed identity, phase and timeout before stopping a stale child' {
        $dir = Join-Path $TestDrive 'watchdog-stop'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $child = $null; $watchdog = $null
        try {
            $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
            $start.UseShellExecute = $false
            foreach ($arg in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 45')) { $start.ArgumentList.Add($arg) }
            $child = [Diagnostics.Process]::Start($start)
            Set-Content -LiteralPath (Join-Path $dir 'inner.pid') -Value $child.Id
            Set-Content -LiteralPath (Join-Path $dir 'runner.phase') -Value 'config-gate'
            Set-Content -LiteralPath (Join-Path $dir 'runner.stepHeartbeat') -Value 'stale'
            (Get-Item -LiteralPath (Join-Path $dir 'runner.stepHeartbeat')).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-30)
            $watchdog = Start-Watchdog -StepTimeoutSeconds 20 -PreambleTimeoutSeconds 1 -PollSeconds 1 -RuntimeDir $dir -CycleGeneration 'runner:2' -Confirm:$false
            $null = Wait-Job -Job $watchdog -Timeout 15
            $watchdog.State | Should -Be 'Completed'
            $record = Get-Content -Raw -LiteralPath (Join-Path $dir 'runner.watchdog-kill.json') | ConvertFrom-Json
            $record.failureClass | Should -Be 'preamble_stall'
            $record.phase | Should -Be 'config-gate'
            $record.attemptGeneration | Should -Be 'runner:2'
            $record.innerPid | Should -Be $child.Id
            $record.timeoutSeconds | Should -Be 1
            $record.stepHeartbeatAgeSeconds | Should -BeGreaterThan 20
            $child.WaitForExit(5000) | Should -BeTrue
        } finally {
            if ($watchdog) { Stop-Watchdog -Job $watchdog -Confirm:$false }
            if ($child) { if (-not $child.HasExited) { $child.Kill($true) }; $child.Dispose() }
        }
    }
}
