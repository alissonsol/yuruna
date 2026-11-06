<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42213d20-67de-42c8-8f4a-9f107b0b9088
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner takeover process-tree console pester
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
    Pester coverage for the single-instance takeover killing a whole process
    tree, and for a cycle child that aborts on the way in not being scored as a
    failed cycle.
.DESCRIPTION
    Both guards exist for the same incident: a takeover killed only the runner
    PID, its children kept the operator's terminal, two processes then fought
    over the same tty, and the console fault that followed was recorded as a
    test FAIL.

    The tree kill is exercised against REAL processes -- a parent that spawns a
    child, both sleeping -- because the whole point is what the operating system
    does with the children, which a mock cannot tell us. The classification is
    driven through the module's own state so no process is needed.

    Everything shared lives in BeforeAll: under Pester 5+ an It block cannot see
    file-scope functions or variables.
    Run: Invoke-Pester -Path test/modules/Test.RunnerTakeover.Tests.ps1
#>

BeforeAll {
Import-Module (Join-Path $PSScriptRoot 'Test.RunnerOuterLoop.psm1') -Global -DisableNameChecking
    $repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path $repo 'modules/Test.SingleInstance.psm1') -Force -DisableNameChecking

    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    # A parent sh that spawns a child sleep and then sleeps itself. Returns both
    # PIDs. The child is what a naive single-PID kill leaves behind.
    function Start-TestProcessTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A test fixture that starts two throwaway sleeps and kills them in the same test; a confirmation prompt would only stall an unattended suite.')]
        param()
        $dir    = New-YurunaTestTempDir -Prefix 'yuruna-tree'
        $marker = Join-Path $dir 'child.pid'
        # A script FILE, not -c with an inline program: Start-Process joins
        # ArgumentList with spaces and quotes nothing, so an inline shell
        # program is re-split on its own spaces and sh runs only the first word.
        $shPath = Join-Path $dir 'tree.sh'
        Set-Content -LiteralPath $shPath -Value @(
            'sleep 300 &'
            "echo `$! > '$marker'"
            'sleep 300'
        ) -Encoding ascii
        $parent = Start-Process -FilePath '/bin/sh' -ArgumentList @($shPath) -PassThru -RedirectStandardOutput '/dev/null'
        $childPid = 0
        for ($i = 0; $i -lt 40 -and $childPid -le 0; $i++) {
            Start-Sleep -Milliseconds 100
            if (Test-Path -LiteralPath $marker) {
                try { $childPid = [int]((Get-Content -LiteralPath $marker -Raw).Trim()) } catch { $childPid = 0 }
            }
        }
        Remove-YurunaTestTempDir $dir
        return [pscustomobject]@{ ParentPid = $parent.Id; ChildPid = $childPid }
    }

    # Runs a /bin/sh program from a script file and waits for the PIDs it
    # writes into the named marker files (a marker's path is passed to the
    # program as `$M_<name>`). Returns the parent PID and a name -> PID map.
    function Start-TestScriptTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A test fixture that starts throwaway sleeps and kills them in the same test; a confirmation prompt would only stall an unattended suite.')]
        param([string[]]$Lines, [string[]]$Markers, [int]$WaitMilliseconds = 4000)
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-tree'
        $exports = @(foreach ($name in $Markers) { "M_$name='$(Join-Path $dir "$name.pid")'; export M_$name" })
        $shPath = Join-Path $dir 'tree.sh'
        Set-Content -LiteralPath $shPath -Value (@($exports) + @($Lines)) -Encoding ascii
        $parent = Start-Process -FilePath '/bin/sh' -ArgumentList @($shPath) -PassThru -RedirectStandardOutput '/dev/null'
        $pids = @{}
        $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline -and $pids.Count -lt $Markers.Count) {
            Start-Sleep -Milliseconds 100
            foreach ($name in $Markers) {
                if ($pids.ContainsKey($name)) { continue }
                $marker = Join-Path $dir "$name.pid"
                if (Test-Path -LiteralPath $marker) {
                    $value = 0
                    if ([int]::TryParse(([string](Get-Content -LiteralPath $marker -Raw)).Trim(), [ref]$value) -and $value -gt 0) { $pids[$name] = $value }
                }
            }
        }
        return [pscustomobject]@{ ParentPid = $parent.Id; Pids = $pids; Dir = $dir }
    }

    function Test-PidAlive {
        param([int]$ProcessId)
        if ($ProcessId -le 0) { return $false }
        return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
}

Describe 'Stop-YurunaProcessTree' {

    It 'kills the children, not just the named process' -Skip:$IsWindows {
        # The actual incident: the runner died, its inner survived holding the
        # terminal, and the next runner inherited a tty it had to share.
        $tree = Start-TestProcessTree
        Assert-True ($tree.ChildPid -gt 0) 'the fixture must have produced a real child to orphan.'
        Assert-True (Test-PidAlive $tree.ChildPid) 'child is alive before the kill.'

        Stop-YurunaProcessTree -ProcessId $tree.ParentPid -GraceMilliseconds 500 -Confirm:$false
        Start-Sleep -Milliseconds 800

        Assert-True (-not (Test-PidAlive $tree.ParentPid)) 'the named process must be gone.'
        Assert-True (-not (Test-PidAlive $tree.ChildPid)) 'the CHILD must be gone too -- leaving it is the whole defect.'
    }

    It 'kills grandchildren too, with no switch to ask for them' -Skip:$IsWindows {
        # A cycle is usually wedged below the inner runner (a capture, an OCR
        # engine, an ssh): a kill that stopped at direct children left those.
        $tree = Start-TestScriptTree -Markers @('child', 'grandchild') -Lines @(
            '/bin/sh -c ''sleep 300 & echo $! > "$M_grandchild"; sleep 300'' &'
            'echo $! > "$M_child"'
            'sleep 300'
        )
        try {
            Assert-True ($tree.Pids.Count -eq 2) 'the fixture must have produced a child and a grandchild.'
            Stop-YurunaProcessTree -ProcessId $tree.ParentPid -GraceMilliseconds 500 -Confirm:$false
            Start-Sleep -Milliseconds 500
            Assert-True (-not (Test-PidAlive $tree.ParentPid)) 'the named process must be gone.'
            Assert-True (-not (Test-PidAlive $tree.Pids['child'])) 'the child must be gone.'
            Assert-True (-not (Test-PidAlive $tree.Pids['grandchild'])) 'the GRANDCHILD must be gone too.'
        } finally {
            foreach ($id in @($tree.Pids.Values) + $tree.ParentPid) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            Remove-YurunaTestTempDir $tree.Dir
        }
    }

    It 'kills a process that ignores TERM, with the children it started during the grace' -Skip:$IsWindows {
        # The parent answers TERM by starting new work two levels down; that
        # work did not exist when the tree was first read.
        $tree = Start-TestScriptTree -Markers @('started', 'late') -Lines @(
            'trap ''/bin/sh -c "sleep 300 & echo \$! > \"$M_late\"; sleep 300" &'' TERM'
            'echo $$ > "$M_started"'
            'while :; do sleep 0.2; done'
        ) -WaitMilliseconds 2000
        try {
            Stop-YurunaProcessTree -ProcessId $tree.ParentPid -GraceMilliseconds 1500 -Confirm:$false
            Start-Sleep -Milliseconds 500
            $late = 0
            $marker = Join-Path $tree.Dir 'late.pid'
            if (Test-Path -LiteralPath $marker) { $late = [int]([string](Get-Content -LiteralPath $marker -Raw)).Trim() }
            Assert-True ($late -gt 0) 'the TERM handler must have started its late work during the grace.'
            Assert-True (-not (Test-PidAlive $tree.ParentPid)) 'the TERM-ignoring parent must be killed.'
            Assert-True (-not (Test-PidAlive $late)) 'the late grandchild must be killed too.'
        } finally {
            Stop-Process -Id $tree.ParentPid -Force -ErrorAction SilentlyContinue
            $marker = Join-Path $tree.Dir 'late.pid'
            if (Test-Path -LiteralPath $marker) { Stop-Process -Id ([int]([string](Get-Content -LiteralPath $marker -Raw)).Trim()) -Force -ErrorAction SilentlyContinue }
            Remove-YurunaTestTempDir $tree.Dir
        }
    }

    It 'is the same kill when its text is rebuilt in a separate process, as the watchdog does' -Skip:$IsWindows {
        $tree = Start-TestScriptTree -Markers @('child', 'grandchild') -Lines @(
            '/bin/sh -c ''sleep 300 & echo $! > "$M_grandchild"; sleep 300'' &'
            'echo $! > "$M_child"'
            'sleep 300'
        )
        try {
            $text = Get-YurunaProcessTreeKillScript
            $rootPid = $tree.ParentPid
            $job = Start-Job -ScriptBlock { & ([scriptblock]::Create($using:text)) $using:rootPid 500 }
            $null = Wait-Job -Job $job -Timeout 30
            Remove-Job -Job $job -Force
            Start-Sleep -Milliseconds 300
            Assert-True (-not (Test-PidAlive $tree.ParentPid)) 'the root must be gone.'
            Assert-True (-not (Test-PidAlive $tree.Pids['grandchild'])) 'the grandchild must be gone.'
        } finally {
            foreach ($id in @($tree.Pids.Values) + $tree.ParentPid) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            Remove-YurunaTestTempDir $tree.Dir
        }
    }

    It 'refuses to kill the calling process' {
        # A guard worth having explicitly: this runs inside a runner, and a
        # pidfile naming our own PID must never be actioned.
        Stop-YurunaProcessTree -ProcessId $PID -GraceMilliseconds 100 -Confirm:$false
        Assert-True (Test-PidAlive $PID) 'still here.'
    }

    It 'is a no-op for a PID that is not a process' {
        Stop-YurunaProcessTree -ProcessId 0 -Confirm:$false
        Stop-YurunaProcessTree -ProcessId -1 -Confirm:$false
        Assert-True $true 'no throw.'
    }
}

Describe 'Cycle abort classification' {

    It 'treats a fast non-zero exit with no reported outcome as aborted, not failed' {
        # The signature of the incident: the child died in seconds because its
        # console broke, wrote no outcome, and the old code printed
        # "Cycle NNNN - FAIL", pointing the operator at tests that never ran.
        $ranForSeconds = 4
        $reportedOutcome = $false
        $childExit = 1
        $aborted = Test-YurunaCycleAborted -ReportedOutcome $reportedOutcome -ChildExit $childExit -RanForSeconds $ranForSeconds
        Assert-True $aborted 'a four-second unexplained death is not a cycle verdict.'
    }

    It 'keeps the verdict for a cycle that actually ran and then failed' {
        $ranForSeconds = 900
        $reportedOutcome = $false
        $childExit = 1
        $aborted = Test-YurunaCycleAborted -ReportedOutcome $reportedOutcome -ChildExit $childExit -RanForSeconds $ranForSeconds
        Assert-True (-not $aborted) 'a real failure that ran for minutes must keep its FAIL -- the threshold exists to protect that.'
    }

    It 'keeps the verdict when the child reported an outcome, however fast it was' {
        $ranForSeconds = 2
        $reportedOutcome = $true
        $childExit = 1
        $aborted = Test-YurunaCycleAborted -ReportedOutcome $reportedOutcome -ChildExit $childExit -RanForSeconds $ranForSeconds
        Assert-True (-not $aborted) 'a child that reported for itself is believed; the reclassification is only for silence.'
    }

    It 'leaves a successful fast cycle alone' {
        $ranForSeconds = 3
        $reportedOutcome = $false
        $childExit = 0
        $aborted = Test-YurunaCycleAborted -ReportedOutcome $reportedOutcome -ChildExit $childExit -RanForSeconds $ranForSeconds
        Assert-True (-not $aborted) 'exit 0 is a pass, not an abort.'
    }
}
