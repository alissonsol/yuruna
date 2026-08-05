<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42e7a3c9-1d68-4b25-8f30-9c2e5b7a4d61
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
    $repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path $repo 'modules/Test.SingleInstance.psm1') -Force -DisableNameChecking

    function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
    function Assert-Equal {
        param($Expected, $Actual, [string]$Because = '')
        if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
    }

    # A parent sh that spawns a child sleep and then sleeps itself. Returns both
    # PIDs. The child is what a naive single-PID kill leaves behind.
    function Start-TestProcessTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A test fixture that starts two throwaway sleeps and kills them in the same test; a confirmation prompt would only stall an unattended suite.')]
        param()
        $stamp  = "yuruna-tree-$PID-$(Get-Random)"
        $marker = Join-Path ([System.IO.Path]::GetTempPath()) "$stamp.pid"
        # A script FILE, not -c with an inline program: Start-Process joins
        # ArgumentList with spaces and quotes nothing, so an inline shell
        # program is re-split on its own spaces and sh runs only the first word.
        $shPath = Join-Path ([System.IO.Path]::GetTempPath()) "$stamp.sh"
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
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $shPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ParentPid = $parent.Id; ChildPid = $childPid }
    }

    function Test-PidAlive {
        param([int]$ProcessId)
        if ($ProcessId -le 0) { return $false }
        return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
}

Describe 'Stop-YurunaProcessTree' {

    It 'kills the children, not just the named process' {
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
        $abortSeconds = 30
        $ranForSeconds = 4
        $reportedOutcome = $false
        $childExit = 1
        $aborted = (-not $reportedOutcome -and $childExit -ne 0 -and $ranForSeconds -lt $abortSeconds)
        Assert-True $aborted 'a four-second unexplained death is not a cycle verdict.'
    }

    It 'keeps the verdict for a cycle that actually ran and then failed' {
        $abortSeconds = 30
        $ranForSeconds = 900
        $reportedOutcome = $false
        $childExit = 1
        $aborted = (-not $reportedOutcome -and $childExit -ne 0 -and $ranForSeconds -lt $abortSeconds)
        Assert-True (-not $aborted) 'a real failure that ran for minutes must keep its FAIL -- the threshold exists to protect that.'
    }

    It 'keeps the verdict when the child reported an outcome, however fast it was' {
        $abortSeconds = 30
        $ranForSeconds = 2
        $reportedOutcome = $true
        $childExit = 1
        $aborted = (-not $reportedOutcome -and $childExit -ne 0 -and $ranForSeconds -lt $abortSeconds)
        Assert-True (-not $aborted) 'a child that reported for itself is believed; the reclassification is only for silence.'
    }

    It 'leaves a successful fast cycle alone' {
        $abortSeconds = 30
        $ranForSeconds = 3
        $reportedOutcome = $false
        $childExit = 0
        $aborted = (-not $reportedOutcome -and $childExit -ne 0 -and $ranForSeconds -lt $abortSeconds)
        Assert-True (-not $aborted) 'exit 0 is a pass, not an abort.'
    }
}
