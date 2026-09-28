<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42228108-7cf2-409b-8ae4-1bb3028f378f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner pidfile single-instance
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
    Shared single-instance pidfile guard for the runner trio, plus the process
    identity, reclamation and refresh-handoff protocol every runner process and
    the host-refresh worker agree on.
.DESCRIPTION
    Outer ([test/Start-TestRunner.ps1](../Start-TestRunner.ps1)) and
    inner ([test/modules/Invoke-TestRunnerInnerLoop.ps1](Invoke-TestRunnerInnerLoop.ps1))
    share one pidfile guard here instead of each carrying a near-identical
    hand-rolled copy that drifts when a per-platform fix lands -- the
    [BSD `ps -ww` truncation trap](../../docs/test-harness.md), for
    instance, is fixed once for both.

    Both entry points call into this module. The pidfile contract:

    - Get-RunnerInstanceState  : Inspect <RuntimeDir>/runner.pid +
                                 runner.start; classify the prior
                                 occupant as None / Self / Stale /
                                 OtherRunner.
    - Stop-StaleRunner         : Force-stop a prior occupant identified
                                 as OtherRunner, wait up to 10 s for
                                 exit, then run Remove-TestVMFiles.ps1
                                 with the default 'test-' prefix so the
                                 next cycle isn't fighting orphan VMs.
    - Write-RunnerPidFile      : Atomically publish runner.pid +
                                 runner.start (StartTime sidecar) so
                                 Start-StatusService's /control/runner-
                                 status endpoint can cross-check PID
                                 reuse without seeing a torn write.

    Identity precedence is StartTime sidecar first (works from any launch
    shape, including the macOS/Linux interactive `pwsh` REPL where argv
    is bare `pwsh`), with the cmdline regex as the fallback for a pidfile
    that carries no sidecar.

    The refresh protocol is stricter than the takeover above, because a host
    refresh must never kill or unlink anything it has not proven it owns:

    - Process identity : one process table per decision (Linux /proc, macOS
      bounded `ps`, Windows CIM), and a five-way classifier -- AliveOwned,
      AliveOther, DeadOrRecycled, Unknown, Missing -- where a PID alone, an
      unreadable command line or a plausible start time never proves
      ownership. A record is removed only as the exact generation proven dead.
    - Reclamation : roots come only from AliveOwned records (inner, cycle,
      outer); the status server, beacon, service scripts and the worker's own
      ancestry are pruned or protected before the tree is expanded; every
      signal is preceded by a fresh identity check and targets a single PID,
      never a tree kill, a process group or a port owner.
    - Refresh gate : a per-user critical record under the private state root
      that holds every runner spawn and pull site while a repair is in
      progress, and fails closed when it cannot be read. A handoff token opens
      only the preflight spawn of the designated replacement chain, which
      acknowledges readiness before the gate releases.
    - Launch record : the six operator options a runner was started with,
      validated against the runner script's own parameter metadata, so a
      refresh restarts the runner with the configuration it had, never one
      derived from a command line.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -DisableNameChecking
function Get-RunnerInstanceState {
    <#
    .SYNOPSIS
        Classify the existing runner.pid + runner.start pair, if any.
    .OUTPUTS
        [hashtable] with:
          status      'None' | 'Self' | 'Stale' | 'OtherRunner'
          pid         [int] PID from the file (0 when missing)
          identityVia 'startTime' | 'cmdline' | 'none'
          cmdline     [string] cmdline match (when identityVia=cmdline)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunnerPidFile,
        [string]$RunnerStartFile,
        # Cmdline regex applied as the identity fallback. Outer matches
        # both "Start-TestRunner.ps1" and "Invoke-TestRunnerInnerLoop.ps1"
        # so a stranded inner that owns the pidfile is also taken over;
        # inner restricts to "Start-TestRunner.ps1" so it never targets a
        # sibling inner. "Invoke-TestCycleRunner.ps1" is deliberately not
        # matched -- the outer owns the pidfile across its per-cycle children.
        [string]$CmdLinePattern = '(?:Start-TestRunner|Invoke-TestRunnerInnerLoop)\.ps1'
    )
    if (-not (Test-Path -LiteralPath $RunnerPidFile)) {
        return @{ status='None'; pid=0; identityVia='none'; cmdline=$null }
    }
    $filePid = 0
    try { $filePid = [int]((Get-Content -LiteralPath $RunnerPidFile -Raw -ErrorAction Stop).Trim()) } catch { $filePid = 0 }
    if ($filePid -le 0) {
        return @{ status='Stale'; pid=0; identityVia='none'; cmdline=$null }
    }
    if ($filePid -eq $PID) {
        return @{ status='Self'; pid=$filePid; identityVia='none'; cmdline=$null }
    }
    $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
    if (-not $proc) {
        return @{ status='Stale'; pid=$filePid; identityVia='none'; cmdline=$null }
    }
    # Identity precedence: StartTime sidecar first (forgery-resistant,
    # works regardless of launch shape), cmdline regex fallback.
    if ($RunnerStartFile -and (Test-Path -LiteralPath $RunnerStartFile)) {
        try {
            $recorded   = (Get-Content -LiteralPath $RunnerStartFile -Raw -ErrorAction Stop).Trim()
            $recordedDt = [DateTimeOffset]::Parse($recorded).UtcDateTime
            $liveDt     = $proc.StartTime.ToUniversalTime()
            # 2s tolerance: ToString('o') is sub-microsecond on .NET but
            # DateTimeOffset.Parse + StartTime can lose precision across
            # the round-trip on some kernels. Wide enough to absorb that
            # without admitting a different process.
            if ([Math]::Abs(($recordedDt - $liveDt).TotalSeconds) -le 2) {
                return @{ status='OtherRunner'; pid=$filePid; identityVia='startTime'; cmdline=$null }
            }
        } catch {
            Write-Verbose "runner.start cross-check failed: $($_.Exception.Message)"
        }
    }
    $cmd = $null
    if ($IsWindows) {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$filePid" -ErrorAction SilentlyContinue).CommandLine
    } elseif ($IsMacOS -or $IsLinux) {
        # `-ww` forces unlimited column width. Without it, BSD/macOS ps
        # truncates `args` to the controlling terminal's columns (or 80
        # if there's no TTY), hiding the trailing Start-TestRunner.ps1
        # token and breaking the regex match.
        $cmd = & '/bin/ps' -ww -p $filePid -o args= 2>$null
    }
    if ($cmd -and $cmd -match $CmdLinePattern) {
        return @{ status='OtherRunner'; pid=$filePid; identityVia='cmdline'; cmdline=[string]$cmd }
    }
    return @{ status='Stale'; pid=$filePid; identityVia='none'; cmdline=[string]$cmd }
}

function Stop-YurunaProcessTree {
    <#
    .SYNOPSIS
        Stop a process and everything it spawned, politely first.
    .DESCRIPTION
        Defined here rather than imported: this module is the single-instance
        guard both runner entry points load before anything else, and pulling in
        the outer loop's module for one helper would drag the whole runner
        machinery into a path that runs before a runner exists.

        Children first, then the parent. A parent killed first has its children
        re-parented to init, which dissolves the process group that a group signal
        would have reached -- so the sweep has to happen while the parent is still
        holding them together.

        TERM, a grace period, then KILL. TERM is what lets a shell-hosted child
        restore the terminal it was drawing on; going straight to KILL leaves the
        console in whatever mode the victim had it in, which is how a takeover
        corrupts the terminal it is taking over. KILL still follows, because a
        wedged process that ignores TERM is exactly the case a takeover exists for.

        Best-effort throughout: every signal is advisory, a process may exit
        between the check and the signal, and a takeover that cannot kill
        something must still continue to the VM cleanup.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [int]$GraceMilliseconds = 2000
    )
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }
    if (-not $PSCmdlet.ShouldProcess("PID $ProcessId", (Format-YurunaOperatorMessage -Key 'runner.operator_ed5c9d2fcb476c82'))) { return }
    try {
        if ($IsWindows) {
            # taskkill /T walks the tree itself; there is no separate TERM.
            & taskkill /PID $ProcessId /T /F 2>&1 | Out-Null
            return
        }
        # Full path for kill: `kill` is also a PowerShell alias for Stop-Process,
        # which would target the wrong thing wherever the alias wins name
        # resolution.
        & pkill -TERM -P $ProcessId 2>&1 | Out-Null
        & '/bin/kill' -TERM $ProcessId 2>&1 | Out-Null
        $waited = 0
        while ($waited -lt $GraceMilliseconds) {
            if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
            $waited += 250
        }
        & pkill -KILL -P $ProcessId 2>&1 | Out-Null
        & '/bin/kill' -KILL $ProcessId 2>&1 | Out-Null
    } catch {
        Write-Verbose "Stop-YurunaProcessTree($ProcessId) swallowed: $($_.Exception.Message)"
    }
}

function Stop-StaleRunner {
    <#
    .SYNOPSIS
        Force-stop an OtherRunner, wait for exit, then run
        Remove-TestVMFiles.ps1 to clear orphan VMs.
    .DESCRIPTION
        Best-effort: stop and cleanup failures are warnings, not throws.
        A caller racing the kill (operator clicks "Start cycle" while a
        runner is still up) needs the call to make progress rather than
        bail.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$TestRoot,
        [string]$CleanupPrefix = 'test-',
        [int]$WaitForExitMs = 10000,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    if (-not $PSCmdlet.ShouldProcess("PID $ProcessId", (Format-YurunaOperatorMessage -Key 'runner.operator_fad7deaf725b8e6e'))) { return }
    # The TREE, not the PID. A runner spawns its cycle process, that spawns the
    # inner, and every one of them inherits the terminal (they are started
    # -NoNewWindow). Killing only the runner leaves those children alive, holding
    # the console the NEW runner is about to write to -- and two processes on one
    # terminal is not a cosmetic problem: each side's cursor-position query
    # (ESC[6n) gets its reply consumed by the other, so the report text leaks into
    # the output as stray ";1R" and the side that asked fails the read. PowerShell
    # answers a failed console read with Environment.FailFast, which kills the
    # process outright. The orphaned inner also keeps driving VMs with nothing
    # supervising it.
    #
    # TERM before KILL, and children before the parent: a parent killed first
    # re-parents its children to init and loses the group that would have reached
    # them. The grace period is what lets the old runner put the terminal back the
    # way it found it; the KILL sweep afterwards is for whatever ignored TERM.
    Stop-YurunaProcessTree -ProcessId $ProcessId -GraceMilliseconds 2000
    # The inner publishes its own pidfile, which is the one handle on a child that
    # survived a re-parent (its group is gone, so no group signal can find it).
    if ($RuntimeDir) {
        $innerPidFile = Join-Path $RuntimeDir 'inner.pid'
        if (Test-Path -LiteralPath $innerPidFile) {
            $innerState = Get-YurunaRunnerRecordState -PidFile $innerPidFile `
                -StartFile (Join-Path $RuntimeDir 'inner.start') `
                -ExpectedScriptPath (Join-Path $TestRoot 'Invoke-TestRunnerInnerLoop.ps1')
            if ($innerState.State -eq 'AliveOwned' -and $innerState.Pid -ne $PID) {
                Write-Verbose "Stop-StaleRunner: verified inner.pid $($innerState.Pid) outlived its runner; stopping it too."
                Stop-YurunaProcessTree -ProcessId $innerState.Pid -GraceMilliseconds 1000
            }
        }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitForExitMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    # Surface a runner that outlived the kill: the takeover assumes the PID is gone before it
    # clears orphan VMs, so a survivor means the new cycle may contend with the old one.
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7715a1f636ef1c06' -Arguments @{ processId = "$ProcessId"; waitForExitMs = "${WaitForExitMs}" })
    }
    $cleanup = Join-Path $TestRoot 'Remove-TestVMFiles.ps1'
    if (Test-Path -LiteralPath $cleanup) {
        try {
            & pwsh -NoProfile -File $cleanup -Prefix $CleanupPrefix
            if ($LASTEXITCODE -ne 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_83d11753023f2934' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_98db2cfbd3b1f192' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    }
}

function Write-RunnerPidFile {
    <#
    .SYNOPSIS
        Publish runner.pid + runner.start so /control/runner-status can
        cross-check the live runner without a torn read.
    .DESCRIPTION
        Atomic-create with exclusive share. Two concurrent operators
        launching Start-TestRunner.ps1 at the same moment otherwise
        both pass Get-RunnerInstanceState's check (both see "None")
        and both write their PID via plain Set-Content, leaving the
        loser's file overwritten and neither knowing the other won
        the takeover. CreateNew + FileShare.None turns the write into
        a compare-and-set: the loser's open throws and signals the
        race.

        Order matters: pidfile (with exclusive lock) first, sidecar
        second. A reader that races us sees either "no pidfile"
        (returns 'None') or "pidfile + sidecar" (returns 'OtherRunner')
        -- never a pidfile without its StartTime sidecar.

        Returns $true on successful write, $false when another runner
        won the race (caller should treat the loss the same way as
        Get-RunnerInstanceState returning 'OtherRunner' on the next
        retry path).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'ShouldProcess gates the actual writes; this attribute is for the wrapper.')]
    param(
        [Parameter(Mandatory)][string]$RunnerPidFile,
        [string]$RunnerStartFile
    )
    if (-not $PSCmdlet.ShouldProcess($RunnerPidFile, (Format-YurunaOperatorMessage -Key 'runner.operator_afdc01326460cb2c'))) { return $true }
    # Atomic-write contract for the pidfile + StartTime sidecar pair:
    # the reader must never see a pidfile without its sidecar, or it
    # falls back to cmdline regex on a stale identity and may
    # misattribute. Sequence:
    #
    #   1. Compute startIso and write to a per-PID `.tmp` next to
    #      RunnerStartFile so a concurrent runner's tmp can't collide.
    #   2. CreateNew + FileShare.None on the pidfile -- this is the
    #      compare-and-set that decides the race.
    #   3. On win: Move-Item .tmp -> RunnerStartFile (atomic rename
    #      on same-volume NTFS / ext4 / APFS).
    #   4. On loss: delete the orphan .tmp and return $false; the
    #      caller treats this the same as Get-RunnerInstanceState
    #      returning 'OtherRunner'.
    #
    # The only remaining unprotected window is between (2) and (3) --
    # ~one rename syscall.
    $startIso = $null
    if ($RunnerStartFile) {
        try {
            $startIso = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        } catch {
            Write-Verbose "Could not compute runner.start StartTime (non-fatal): $($_.Exception.Message)"
        }
    }
    $startTmp = $null
    if ($RunnerStartFile -and $startIso) {
        $startTmp = "$RunnerStartFile.$PID.tmp"
        try {
            [System.IO.File]::WriteAllText($startTmp, $startIso, [System.Text.UTF8Encoding]::new($false))
        } catch {
            Write-Verbose "Could not stage runner.start tmp (non-fatal; sidecar will be skipped): $($_.Exception.Message)"
            $startTmp = $null
        }
    }
    # Open with CreateNew + FileShare.None so a concurrent open from
    # another runner fails with IOException. Any pre-existing pidfile
    # at this point is a logic error in the caller -- Get-RunnerInstanceState
    # + the Remove-Item that follows should have cleared it.
    $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$PID)
    try {
        $fs = [System.IO.File]::Open($RunnerPidFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        } finally {
            $fs.Dispose()
        }
    } catch [System.IO.IOException] {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_56b13207e8b9d8fb' -Arguments @{ message = "$($_.Exception.Message)" })
        if ($startTmp -and (Test-Path -LiteralPath $startTmp)) {
            Remove-Item -LiteralPath $startTmp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    if ($startTmp -and (Test-Path -LiteralPath $startTmp)) {
        try {
            Move-Item -LiteralPath $startTmp -Destination $RunnerStartFile -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Could not rename runner.start tmp into place (non-fatal; identity fallback will use cmdline regex): $($_.Exception.Message)"
            Remove-Item -LiteralPath $startTmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Resolve-YurunaRunnerProcessTarget {
    <#
    .SYNOPSIS
        Pure: given a snapshot process table and a set of verified runner
        identities, compute which processes are safe to signal, in what
        order, and which subtrees are excluded and why.
    .DESCRIPTION
        Takes no live process query itself -- ProcessTable is a snapshot the
        caller already captured, so this function is deterministic and
        testable without spawning or signaling anything. It never touches a
        real process; it only decides.

        Exclusions are pruned BEFORE their descendants are ever walked: an
        excluded PID's whole subtree is skipped, so a verified status-server
        or beacon process is never reached even through a grandchild the
        caller's own record does not separately know about. Descendants
        come back in post order -- every process's children appear before
        it, and a verified root itself appears only after its own subtree
        -- which is what "signal inner work before outer work" means in
        practice: the deepest live descendants of a root are always
        upstream of that root in the returned list.

        A protected PID is the opposite of an excluded one: the node itself
        is never signaled, but its subtree is still walked. The worker's own
        ancestry and a caller outer that must survive are protected rather
        than excluded, because a shared ancestor (a tmux server, a login
        shell) must not prune a runner that happens to sit below it.

        Reentrant safe: a PID reachable from two different verified roots
        (an unusual but possible shape) is expanded and returned only once.
    .PARAMETER ProcessTable
        [object[]] snapshot rows, each carrying at least Pid, ParentPid,
        StartTimeUnixMs; CommandLine/Executable are accepted but not
        required by this function itself (a caller's own identity checks
        may already have consumed them before calling this).
    .PARAMETER VerifiedRoot
        [object[]] identities this caller has already confirmed by exact
        PID plus start time (or, for a bare-argv interactive outer, a
        registered-ownership record it trusts some other way): each row
        carries Pid, an optional StartTimeUnixMs (omit only when the
        caller has no start-time evidence at all and accepts PID-only
        risk), and a free-form Role label used only in Reasons.
    .PARAMETER ExcludedPid
        [int[]] PIDs verified as status-server/beacon/bootstrap processes.
        Each one's entire subtree is pruned before expansion.
    .PARAMETER ProtectedPid
        [int[]] PIDs that are never signaled themselves while their
        subtrees are still expanded.
    .OUTPUTS
        [pscustomobject] @{ Roots; Descendants; Exclusions; Protected;
        Reasons; ReasonRecords }.
        Roots is the [int[]] PIDs actually accepted as verified roots (a
        supplied root that failed its own identity check is not in here).
        Descendants is the full pruned, post-ordered signal list -- the
        actual ProcessTable rows, not just PIDs -- including each accepted,
        unprotected root at the end of its own subtree. Reasons is a
        [string[]] diagnostic trail for private logs: one entry per root
        that was rejected, per subtree that was pruned and per protected
        node. ReasonRecords carries the same events as data rows
        { Pid; Role; Code } with Code root-missing, root-start-mismatch,
        root-excluded, subtree-excluded or protected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ProcessTable,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VerifiedRoot,
        [int[]]$ExcludedPid = @(),
        [int[]]$ProtectedPid = @()
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $reasonRecords = [System.Collections.Generic.List[object]]::new()
    $byPid = @{}
    foreach ($row in $ProcessTable) { $byPid[[int]$row.Pid] = $row }
    $childrenOf = @{}
    foreach ($row in $ProcessTable) {
        $parentPid = [int]$row.ParentPid
        if (-not $childrenOf.ContainsKey($parentPid)) {
            $childrenOf[$parentPid] = [System.Collections.Generic.List[object]]::new()
        }
        $childrenOf[$parentPid].Add($row)
    }

    $excludedSet  = [System.Collections.Generic.HashSet[int]]::new([int[]]@($ExcludedPid))
    $protectedSet = [System.Collections.Generic.HashSet[int]]::new([int[]]@($ProtectedPid))
    $acceptedRoots = [System.Collections.Generic.List[int]]::new()
    $descendants   = [System.Collections.Generic.List[object]]::new()
    $visited       = [System.Collections.Generic.HashSet[int]]::new()

    function Test-YurunaRunnerIdentityMatch {
        param($Row, $Verified)
        if ([int]$Row.Pid -ne [int]$Verified.Pid) { return $false }
        if ($null -eq $Verified.StartTimeUnixMs) { return $true }
        if ($null -eq $Row.StartTimeUnixMs) { return $false }
        return ([Math]::Abs([int64]$Row.StartTimeUnixMs - [int64]$Verified.StartTimeUnixMs) -le 2000)
    }

    function Expand-YurunaRunnerSubtree {
        param([int]$TargetPid, [string]$Role)
        if ($visited.Contains($TargetPid)) { return }
        [void]$visited.Add($TargetPid)
        if ($excludedSet.Contains($TargetPid)) {
            $reasons.Add("pid $TargetPid excluded: verified status-server/beacon/bootstrap process; subtree pruned before expansion")
            $reasonRecords.Add([pscustomobject]@{ Pid = $TargetPid; Role = $Role; Code = 'subtree-excluded' })
            return
        }
        if ($childrenOf.ContainsKey($TargetPid)) {
            foreach ($child in $childrenOf[$TargetPid]) {
                $parentStart = $byPid[$TargetPid].StartTimeUnixMs
                if ($null -ne $parentStart -and ($null -eq $child.StartTimeUnixMs -or
                    [long]$child.StartTimeUnixMs -lt ([long]$parentStart - $script:StartToleranceMs))) {
                    $reasons.Add("pid $($child.Pid): child identity is missing or predates its current parent; subtree pruned")
                    $reasonRecords.Add([pscustomobject]@{ Pid = [int]$child.Pid; Role = 'descendant'; Code = 'child-start-mismatch' })
                    continue
                }
                Expand-YurunaRunnerSubtree -TargetPid ([int]$child.Pid) -Role 'descendant'
            }
        }
        if ($byPid.ContainsKey($TargetPid)) {
            if ($protectedSet.Contains($TargetPid)) {
                $reasons.Add("pid $TargetPid ($Role) protected: never signaled; its subtree is still expanded")
                $reasonRecords.Add([pscustomobject]@{ Pid = $TargetPid; Role = $Role; Code = 'protected' })
            } else {
                $descendants.Add($byPid[$TargetPid])
            }
        }
    }

    foreach ($verified in $VerifiedRoot) {
        $row = $byPid[[int]$verified.Pid]
        if (-not $row) {
            $reasons.Add("pid $($verified.Pid) ($($verified.Role)): not present in the process table; nothing to signal")
            $reasonRecords.Add([pscustomobject]@{ Pid = [int]$verified.Pid; Role = [string]$verified.Role; Code = 'root-missing' })
            continue
        }
        if (-not (Test-YurunaRunnerIdentityMatch -Row $row -Verified $verified)) {
            $reasons.Add("pid $($verified.Pid) ($($verified.Role)): a different process now holds this PID (start-time mismatch); refusing to treat it as the verified root")
            $reasonRecords.Add([pscustomobject]@{ Pid = [int]$verified.Pid; Role = [string]$verified.Role; Code = 'root-start-mismatch' })
            continue
        }
        if ($excludedSet.Contains([int]$verified.Pid)) {
            $reasons.Add("pid $($verified.Pid) ($($verified.Role)): explicitly excluded; not accepted as a root")
            $reasonRecords.Add([pscustomobject]@{ Pid = [int]$verified.Pid; Role = [string]$verified.Role; Code = 'root-excluded' })
            continue
        }
        [void]$acceptedRoots.Add([int]$verified.Pid)
        Expand-YurunaRunnerSubtree -TargetPid ([int]$verified.Pid) -Role ([string]$verified.Role)
    }

    return [pscustomobject]@{
        Roots         = $acceptedRoots.ToArray()
        Descendants   = $descendants.ToArray()
        Exclusions    = @($excludedSet)
        Protected     = @($protectedSet)
        Reasons       = $reasons.ToArray()
        ReasonRecords = $reasonRecords.ToArray()
    }
}

# --- REGION: Process table
# One snapshot per decision. A listing that could not be completed is never
# read as an empty one: Complete $false means nothing is proven absent, and
# every consumer below turns "absent from an incomplete table" into Unknown.

# Start times from different sources (the /proc arithmetic, .NET's
# Process.StartTime, an ISO string written by Write-RunnerPidFile, macOS
# lstart at one-second resolution) agree only to within a small window, the
# same window Get-RunnerInstanceState has always applied. Wider would admit a
# recycled PID; narrower would reject a genuine owner.
$script:StartToleranceMs = 2000
$script:LinuxClockTicks  = $null

function ConvertTo-YurunaUnixMs {
    <#
    .SYNOPSIS
        A DateTime as Unix milliseconds (UTC), the unit every identity record
        in this module uses.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Ms so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][datetime]$Value)
    $utc = if ($Value.Kind -eq [DateTimeKind]::Utc) { $Value } else { $Value.ToUniversalTime() }
    return [long]([DateTimeOffset]::new([DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc))).ToUnixTimeMilliseconds()
}

function Get-YurunaIdentityPlatform {
    <#
    .SYNOPSIS
        Linux, MacOS or Windows for the running process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS) { return 'MacOS' }
    return 'Linux'
}

function Get-YurunaIdentityComparison {
    <#
    .SYNOPSIS
        Path comparison for command-line and runtime-path matching: ordinal
        on Linux, case-insensitive on macOS and Windows.
    #>
    [CmdletBinding()]
    [OutputType([System.StringComparison])]
    param([string]$Platform)
    if (-not $Platform) { $Platform = Get-YurunaIdentityPlatform }
    if ($Platform -eq 'Linux') { return [StringComparison]::Ordinal }
    return [StringComparison]::OrdinalIgnoreCase
}

function Get-YurunaLinuxClockTick {
    <#
    .SYNOPSIS
        USER_HZ for /proc start-time arithmetic, from one bounded
        `getconf CLK_TCK` per process; 100 when it cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([psobject]$Deadline)
    if ($script:LinuxClockTicks) { return [int]$script:LinuxClockTicks }
    $ticks = 100
    $settled = $false
    try {
        $seconds = if ($Deadline) { Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 5 } else { 5 }
        if ($seconds) {
            $call = @{ FilePath = 'getconf'; ArgumentList = @('CLK_TCK'); TimeoutSeconds = $seconds }
            if ($Deadline) { $call.Deadline = $Deadline }
            $r = Invoke-BoundedNativeCommand @call
            $parsed = 0
            if ((Test-BoundedNativeResultComplete -Result $r) -and $r.ExitCode -eq 0 -and
                [int]::TryParse(([string]$r.StdOut).Trim(), [ref]$parsed) -and $parsed -gt 0) {
                $ticks = $parsed
            }
            # A tool that ran (or could not be started at all) settles the
            # answer for this process; a call cut short by the deadline does not.
            $settled = -not $r.TimedOut -and -not $r.DeadlineExhausted
        }
    } catch {
        Write-Verbose "getconf CLK_TCK unavailable; assuming 100: $($_.Exception.Message)"
        $settled = $true
    }
    if ($settled) { $script:LinuxClockTicks = $ticks }
    return $ticks
}

function ConvertFrom-YurunaProcStat {
    <#
    .SYNOPSIS
        Parse /proc/<pid>/stat. Fields are counted after the LAST ')' because
        the command name can itself contain spaces and parentheses.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $open  = $Text.IndexOf('(')
    $close = $Text.LastIndexOf(')')
    if ($open -lt 1 -or $close -lt $open) { return $null }
    $rest = $Text.Substring($close + 1).Trim() -split '\s+'
    if ($rest.Count -lt 20) { return $null }
    $procId = 0; $parentPid = 0; $group = 0; $startTicks = [long]0
    if (-not [int]::TryParse($Text.Substring(0, $open).Trim(), [ref]$procId)) { return $null }
    if (-not [int]::TryParse($rest[1], [ref]$parentPid)) { return $null }
    if (-not [int]::TryParse($rest[2], [ref]$group)) { return $null }
    if (-not [long]::TryParse($rest[19], [ref]$startTicks)) { return $null }
    return @{
        Pid            = $procId
        Comm           = $Text.Substring($open + 1, $close - $open - 1)
        State          = $rest[0]
        ParentPid      = $parentPid
        ProcessGroupId = $group
        StartTicks     = $startTicks
    }
}

function Get-YurunaLinuxBootTime {
    <#
    .SYNOPSIS
        btime (seconds since the epoch at boot) from <ProcRoot>/stat, or $null.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$ProcRoot)
    try {
        foreach ($line in [System.IO.File]::ReadAllLines([System.IO.Path]::Combine($ProcRoot, 'stat'))) {
            if ($line -match '^btime\s+(\d+)') { return [long]$Matches[1] }
        }
    } catch {
        Write-Verbose "btime unreadable under '$ProcRoot': $($_.Exception.Message)"
    }
    return $null
}

function Get-YurunaLinuxProcessRow {
    <#
    .SYNOPSIS
        One process-table row from /proc, or $null when the PID is gone, is a
        zombie, or its stat record cannot be parsed (Parsed $false).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ProcRoot,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][Nullable[long]]$BootTime,
        [Parameter(Mandatory)][int]$ClockTicks
    )
    $dir = [System.IO.Path]::Combine($ProcRoot, $Name)
    $statText = $null
    try { $statText = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($dir, 'stat')) } catch { return @{ Gone = $true } }
    $stat = ConvertFrom-YurunaProcStat -Text $statText
    if (-not $stat) { return @{ Gone = $false; Parsed = $false } }
    # A zombie has exited; only its parent's wait is outstanding. It owns
    # nothing a reclaim could stop, so it reads as absent.
    if ($stat.State -in @('Z', 'X', 'x')) { return @{ Gone = $true } }
    $uid = $null
    try {
        foreach ($line in [System.IO.File]::ReadAllLines([System.IO.Path]::Combine($dir, 'status'))) {
            if ($line -match '^Uid:\s+(\d+)') { $uid = $Matches[1]; break }
        }
    } catch { $uid = $null }
    $argv = $null
    $commandLine = ''
    try {
        $bytes = [System.IO.File]::ReadAllBytes([System.IO.Path]::Combine($dir, 'cmdline'))
        if ($bytes.Length -gt 0) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimEnd([char]0)
            $argv = [string[]]($text -split [char]0)
            $commandLine = $argv -join ' '
        } else {
            $argv = [string[]]@()
        }
    } catch { $argv = $null }
    $exe = $null
    try { $exe = [System.IO.FileInfo]::new([System.IO.Path]::Combine($dir, 'exe')).LinkTarget } catch { $exe = $null }
    if (-not $exe) { $exe = if ($argv -and $argv.Count -gt 0) { $argv[0] } else { $stat.Comm } }
    # The working directory resolves a script named by a relative path
    # (`pwsh test/Start-TestRunner.ps1`). pwsh never moves its process working
    # directory on Set-Location, so this is still the directory it was
    # launched from. Another user's link is unreadable and stays $null.
    $cwd = $null
    try { $cwd = [System.IO.FileInfo]::new([System.IO.Path]::Combine($dir, 'cwd')).LinkTarget } catch { $cwd = $null }
    $start = $null
    if ($null -ne $BootTime) {
        $start = [long](([long]$BootTime * 1000) + [Math]::Floor(([double]$stat.StartTicks * 1000.0) / $ClockTicks))
    }
    return @{
        Gone   = $false
        Parsed = $true
        Row    = [pscustomobject]@{
            Pid             = [int]$stat.Pid
            ParentPid       = [int]$stat.ParentPid
            StartTimeUnixMs = [Nullable[long]]$start
            Executable      = [string]$exe
            CommandLine     = $commandLine
            Argv            = $argv
            OwnerId         = $uid
            ProcessGroupId  = [Nullable[int]]$stat.ProcessGroupId
            WorkingDirectory = if ($cwd) { [string]$cwd } else { $null }
        }
    }
}

function ConvertFrom-YurunaPsLine {
    <#
    .SYNOPSIS
        Parse one line of `ps -o pid=,ppid=,pgid=,uid=,lstart=,command=` run
        under LC_ALL=C and TZ=UTC0.
    .DESCRIPTION
        lstart is `ddd MMM d HH:mm:ss yyyy` with the day space-padded, at one
        second resolution -- inside the start-time tolerance.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $pattern = '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}:\d{2})\s+(\d{4})(?:\s(.*))?$'
    if ($Line -notmatch $pattern) { return $null }
    $start = [datetime]::MinValue
    $stamp = "$($Matches[5]) $($Matches[6]) $($Matches[7]) $($Matches[8])"
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetime]::TryParseExact($stamp, 'MMM d H:mm:ss yyyy', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$start)) {
        return $null
    }
    $command = if ($null -ne $Matches[9]) { [string]$Matches[9] } else { '' }
    $first = ($command.Trim() -split '\s+', 2)[0]
    return [pscustomobject]@{
        Pid             = [int]$Matches[1]
        ParentPid       = [int]$Matches[2]
        StartTimeUnixMs = [Nullable[long]](ConvertTo-YurunaUnixMs -Value $start)
        Executable      = $first
        CommandLine     = $command
        Argv            = $null
        OwnerId         = [string]$Matches[4]
        ProcessGroupId  = [Nullable[int]][int]$Matches[3]
        WorkingDirectory = $null
    }
}

function ConvertFrom-YurunaCimProcess {
    <#
    .SYNOPSIS
        One Win32_Process instance as a process-table row. OwnerId is the
        session id: Win32_Process carries no cheap owner.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][psobject]$Instance)
    $start = $null
    if ($Instance.CreationDate -is [datetime]) { $start = ConvertTo-YurunaUnixMs -Value $Instance.CreationDate }
    return [pscustomobject]@{
        Pid             = [int]$Instance.ProcessId
        ParentPid       = [int]$Instance.ParentProcessId
        StartTimeUnixMs = [Nullable[long]]$start
        Executable      = [string]$Instance.ExecutablePath
        CommandLine     = [string]$Instance.CommandLine
        Argv            = $null
        OwnerId         = if ($null -ne $Instance.SessionId) { [string]$Instance.SessionId } else { $null }
        ProcessGroupId  = $null
        WorkingDirectory = $null
    }
}

function Get-YurunaProcessTable {
    <#
    .SYNOPSIS
        One bounded snapshot of the process table, or of selected PIDs.
    .DESCRIPTION
        Linux reads /proc directly: stat for parent, group and start ticks
        (converted with btime and USER_HZ), status for the real uid, cmdline
        split on NUL, and the cwd link. A PID that vanishes mid-read is
        skipped. macOS runs one
        bounded `ps` under LC_ALL=C and TZ=UTC0; a timed-out, truncated,
        failed or unparseable listing is incomplete. Windows queries
        Win32_Process with an operation timeout.

        Complete $false means nothing is proven absent: a failed or partial
        listing is never mistaken for an empty one, and every consumer turns
        an absent row in an incomplete table into Unknown.

        Reading /proc/<pid>/cmdline can block on a process stuck in the
        kernel holding its memory map; the deadline is checked between rows,
        but a single read is bounded only by the kernel.
    .PARAMETER Deadline
        Shared deadline; the table stops early (incomplete) when it expires.
    .PARAMETER TimeoutSeconds
        Own bound when no deadline is given, and a ceiling under one.
    .PARAMETER Platform
        Linux, MacOS or Windows. Defaults to the running OS; tests set it to
        drive a parser on any host.
    .PARAMETER ProcRoot
        /proc on Linux; tests point it at a fixture tree.
    .PARAMETER PsPath
        ps on macOS; tests point it at a stand-in.
    .PARAMETER CimQuery
        Windows: replaces the Win32_Process query. Receives the WQL filter
        ($null for every process) and the timeout in seconds.
    .PARAMETER ProcessId
        Restrict the snapshot to these PIDs; Complete then speaks only for them.
    .OUTPUTS
        [pscustomobject] @{ Complete; Platform; Source; CapturedUtc; ElapsedMs;
        Rows; Error }. Each row is { Pid; ParentPid; StartTimeUnixMs;
        Executable; CommandLine; Argv; OwnerId; ProcessGroupId;
        WorkingDirectory }; WorkingDirectory is read on Linux only and is
        $null where it cannot be.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [psobject]$Deadline,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 10,
        [ValidateSet('Linux', 'MacOS', 'Windows')][string]$Platform,
        [string]$ProcRoot = '/proc',
        [string]$PsPath = '/bin/ps',
        [scriptblock]$CimQuery,
        [int[]]$ProcessId
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $Platform) { $Platform = Get-YurunaIdentityPlatform }
    $own = if ($Deadline) {
        New-YurunaDeadline -Parent $Deadline -TotalMilliseconds ([long]$TimeoutSeconds * 1000)
    } else {
        New-YurunaDeadline -TotalMilliseconds ([long]$TimeoutSeconds * 1000)
    }
    $result = [ordered]@{
        Complete = $false; Platform = $Platform; Source = $null
        CapturedUtc = [DateTime]::UtcNow.ToString('o'); ElapsedMs = [long]0; Rows = @(); Error = $null
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    $filter = @($ProcessId | Where-Object { $_ -gt 0 })
    try {
        switch ($Platform) {
            'Linux' {
                $result.Source = 'proc'
                $bootTime = Get-YurunaLinuxBootTime -ProcRoot $ProcRoot
                $clock = Get-YurunaLinuxClockTick -Deadline $own
                $complete = $true
                if ($null -eq $bootTime) { $complete = $false; $result.Error = 'btime-unreadable' }
                $names = if ($PSBoundParameters.ContainsKey('ProcessId')) {
                    @($filter | ForEach-Object { [string]$_ })
                } else {
                    @([System.IO.Directory]::EnumerateDirectories($ProcRoot) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
                }
                foreach ($name in $names) {
                    if ($name -notmatch '^\d+$') { continue }
                    if (Test-YurunaDeadlineExpired -Deadline $own) {
                        $complete = $false
                        $result.Error = 'deadline-exhausted'
                        break
                    }
                    $read = Get-YurunaLinuxProcessRow -ProcRoot $ProcRoot -Name $name -BootTime $bootTime -ClockTicks $clock
                    if ($read.Gone) { continue }
                    if (-not $read.Parsed) {
                        $complete = $false
                        $result.Error = "stat-unparseable:$name"
                        continue
                    }
                    $rows.Add($read.Row)
                }
                $result.Complete = $complete
            }
            'MacOS' {
                $result.Source = 'ps'
                $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $own -Ceiling 600
                if (-not $seconds) { $result.Error = 'deadline-exhausted'; break }
                $psArgs = @('-axww', '-o', 'pid=,ppid=,pgid=,uid=,lstart=,command=')
                if ($PSBoundParameters.ContainsKey('ProcessId')) {
                    if ($filter.Count -eq 0) { $result.Complete = $true; break }
                    $psArgs = @('-ww', '-o', 'pid=,ppid=,pgid=,uid=,lstart=,command=', '-p', ($filter -join ','))
                }
                $r = Invoke-BoundedNativeCommand -FilePath $PsPath -ArgumentList $psArgs -TimeoutSeconds $seconds `
                    -Environment @{ LC_ALL = 'C'; TZ = 'UTC0' } -Deadline $own
                if (-not (Test-BoundedNativeResultComplete -Result $r)) {
                    $result.Error = if ($r.TimedOut) { 'timeout' } elseif (-not $r.Started) { 'ps-unavailable' } else { 'output-incomplete' }
                    break
                }
                $emptyMatch = $PSBoundParameters.ContainsKey('ProcessId') -and $r.ExitCode -eq 1 -and
                    [string]::IsNullOrWhiteSpace([string]$r.StdOut) -and [string]::IsNullOrWhiteSpace([string]$r.StdErr)
                if ($r.ExitCode -ne 0 -and -not $emptyMatch) { $result.Error = "ps-exit-$($r.ExitCode)"; break }
                $bad = 0
                foreach ($line in ([string]$r.StdOut -split "`r?`n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $row = ConvertFrom-YurunaPsLine -Line $line
                    if ($row) { $rows.Add($row) } else { $bad++ }
                }
                if ($bad -gt 0) { $result.Error = "unparseable-lines:$bad"; break }
                $result.Complete = $true
            }
            'Windows' {
                $result.Source = 'cim'
                $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $own -Ceiling 600
                if (-not $seconds) { $result.Error = 'deadline-exhausted'; break }
                $wql = $null
                if ($PSBoundParameters.ContainsKey('ProcessId')) {
                    if ($filter.Count -eq 0) { $result.Complete = $true; break }
                    $wql = (@($filter | ForEach-Object { "ProcessId=$_" }) -join ' OR ')
                }
                $query = if ($CimQuery) { $CimQuery } else {
                    {
                        param($Filter, $TimeoutSec)
                        $cim = @{
                            ClassName           = 'Win32_Process'
                            Property            = @('ProcessId', 'ParentProcessId', 'CreationDate', 'CommandLine', 'ExecutablePath', 'SessionId')
                            OperationTimeoutSec = $TimeoutSec
                            ErrorAction         = 'Stop'
                        }
                        if ($Filter) { $cim.Filter = $Filter }
                        Get-CimInstance @cim
                    }
                }
                foreach ($instance in @(& $query $wql $seconds)) {
                    if ($null -eq $instance) { continue }
                    $rows.Add((ConvertFrom-YurunaCimProcess -Instance $instance))
                }
                $result.Complete = -not (Test-YurunaDeadlineExpired -Deadline $own)
                if (-not $result.Complete) { $result.Error = 'deadline-exhausted' }
            }
        }
    } catch {
        $result.Complete = $false
        $result.Error = "table-failed: $($_.Exception.Message)"
    }
    $result.Rows = $rows.ToArray()
    $result.ElapsedMs = [long]$stopwatch.ElapsedMilliseconds
    return [pscustomobject]$result
}

function Get-YurunaProcessStartUnixMs {
    <#
    .SYNOPSIS
        A live process's start time in Unix ms, from the same source the
        process table uses on this platform; $null when unreadable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Ms so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([long])]
    param([int]$ProcessId = $PID, [psobject]$Deadline)
    if ((Get-YurunaIdentityPlatform) -eq 'Linux') {
        $lookup = @{ ProcessId = @($ProcessId); TimeoutSeconds = 5 }
        if ($Deadline) { $lookup.Deadline = $Deadline }
        $table = Get-YurunaProcessTable @lookup
        $row = @($table.Rows | Where-Object { $_.Pid -eq $ProcessId }) | Select-Object -First 1
        if ($row -and $null -ne $row.StartTimeUnixMs) { return [long]$row.StartTimeUnixMs }
    }
    try {
        return (ConvertTo-YurunaUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($ProcessId).StartTime))
    } catch {
        return $null
    }
}

function Get-YurunaProcessLiveIdentity {
    <#
    .SYNOPSIS
        Default single-PID lookup for signal-time revalidation:
        { Alive; StartTimeUnixMs; ParentPid; Known }.
    .DESCRIPTION
        Bounded by 5 s and, when given, by the caller's deadline, so a slow
        ps on macOS never carries a signal loop past its own budget.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][int]$ProcessId, [psobject]$Deadline)
    $lookup = @{ ProcessId = @($ProcessId); TimeoutSeconds = 5 }
    if ($Deadline) { $lookup.Deadline = $Deadline }
    $table = Get-YurunaProcessTable @lookup
    $row = @($table.Rows | Where-Object { $_.Pid -eq $ProcessId }) | Select-Object -First 1
    if ($row) {
        return [pscustomobject]@{ Alive = $true; StartTimeUnixMs = $row.StartTimeUnixMs; ParentPid = $row.ParentPid; Known = $true }
    }
    return [pscustomobject]@{ Alive = $false; StartTimeUnixMs = $null; ParentPid = $null; Known = [bool]$table.Complete }
}

# --- REGION: Process identity
function Test-YurunaCommandLineNamesPath {
    <#
    .SYNOPSIS
        $true when a command line names a path, in either separator spelling.
        Substring matching over-approximates, which only ever errs toward
        keeping a process alive.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$CommandLine,
        [AllowEmptyString()][string]$Path,
        [System.StringComparison]$Comparison = [StringComparison]::Ordinal
    )
    if ([string]::IsNullOrEmpty($CommandLine) -or [string]::IsNullOrEmpty($Path)) { return $false }
    foreach ($spelling in @($Path, $Path.Replace('\', '/'), $Path.Replace('/', '\'))) {
        if ($CommandLine.IndexOf($spelling, $Comparison) -ge 0) { return $true }
    }
    return $false
}

function ConvertTo-YurunaComparableScriptPath {
    <#
    .SYNOPSIS
        A script path in the form two spellings of one file compare equal
        in: symbolic links resolved when the path belongs to this host's
        platform, separators unified otherwise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [string]$Platform)
    if (-not $Platform) { $Platform = Get-YurunaIdentityPlatform }
    if ($Platform -ne (Get-YurunaIdentityPlatform)) {
        # Another platform's path cannot be resolved here: collapse . and ..
        # lexically so a relative spelling still meets its absolute one.
        $segments = [System.Collections.Generic.List[string]]::new()
        foreach ($part in ($Path -split '[\\/]')) {
            if ($part -eq '.' -or ($part -eq '' -and $segments.Count -gt 0)) { continue }
            if ($part -eq '..') { if ($segments.Count -gt 1) { $segments.RemoveAt($segments.Count - 1) }; continue }
            $segments.Add($part)
        }
        return ($segments -join '/')
    }
    try {
        $canonical = Resolve-YurunaCanonicalPath -Path $Path
        if ($canonical.Resolved -and $canonical.Path) { return [string]$canonical.Path }
        return [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $Path
    }
}

function Get-YurunaCommandLineScriptVerdict {
    <#
    .SYNOPSIS
        Which runner script a process's command line runs, judged against the
        expected paths: expected, other, unresolved or none.
    .DESCRIPTION
        A literal mention of an expected path is expected. Otherwise every
        argument token that ends in a runner script name is resolved: an
        absolute token as written, a relative one (`pwsh
        test/Start-TestRunner.ps1`, a `./test/...` shebang launch) against the
        process working directory. Both sides are compared with symbolic
        links resolved, so a checkout reached through a link still matches.
        Any token that resolves to an expected path is expected; a token that
        resolves elsewhere is other; a relative token without a readable
        working directory is unresolved; a command line naming no runner
        script is none.
    .PARAMETER Row
        A process-table row.
    .PARAMETER ExpectedScriptPath
        The script paths this runtime's owner runs.
    .PARAMETER Platform
        The platform the table was read on.
    .OUTPUTS
        [string] expected, other, unresolved or none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][psobject]$Row,
        [Parameter(Mandatory)][string[]]$ExpectedScriptPath,
        [string]$Platform
    )
    if (-not $Platform) { $Platform = Get-YurunaIdentityPlatform }
    $comparison = Get-YurunaIdentityComparison -Platform $Platform
    $commandLine = [string]$Row.CommandLine
    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($ExpectedScriptPath | Where-Object { $_ })) {
        if (Test-YurunaCommandLineNamesPath -CommandLine $commandLine -Path $path -Comparison $comparison) { return 'expected' }
        foreach ($spelling in @([string]$path, (ConvertTo-YurunaComparableScriptPath -Path $path -Platform $Platform))) {
            if ($spelling -and -not $expected.Contains($spelling)) { $expected.Add($spelling) }
        }
    }
    $leaves = @(@('Start-TestRunner.ps1', 'Invoke-TestCycleRunner.ps1', 'Invoke-TestRunnerInnerLoop.ps1') +
        @($ExpectedScriptPath | ForEach-Object { [System.IO.Path]::GetFileName(([string]$_).Replace('\', '/')) } | Where-Object { $_ }) |
        Select-Object -Unique)
    $argvProperty = $Row.PSObject.Properties['Argv']
    $cwdProperty = $Row.PSObject.Properties['WorkingDirectory']
    $cwd = if ($cwdProperty -and $cwdProperty.Value) { [string]$cwdProperty.Value } else { $null }
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($argvProperty -and $null -ne $argvProperty.Value -and @($argvProperty.Value).Count -gt 0) {
        # A whole argv element keeps a path with spaces intact; its
        # whitespace pieces find a path inside a -Command string.
        foreach ($element in @($argvProperty.Value)) {
            $text = [string]$element
            if (-not $text) { continue }
            $candidates.Add($text)
            foreach ($piece in ($text -split '\s+')) { $candidates.Add($piece) }
        }
    } else {
        # A joined command line (ps, CIM): double-quoted runs are one token.
        foreach ($match in [regex]::Matches($commandLine, '"([^"]*)"|(\S+)')) {
            $candidates.Add($(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }))
        }
    }
    $trim = [char[]]@([char]34, [char]39, [char]96, ';', ',', '(', ')', '&', '|', '{', '}')
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $token = ([string]$candidate).Trim().Trim($trim)
        if (-not $token -or $tokens.Contains($token)) { continue }
        foreach ($leaf in $leaves) {
            if (-not $token.EndsWith($leaf, $comparison)) { continue }
            $before = $token.Length - $leaf.Length - 1
            if ($before -lt 0 -or $token[$before] -in @([char]'/', [char]'\')) { $tokens.Add($token); break }
        }
    }
    $other = 0
    $unresolved = 0
    foreach ($token in $tokens) {
        $rooted = $token.StartsWith('/') -or $token.StartsWith('\') -or ($token -match '^[A-Za-z]:[\\/]')
        $full = $null
        if ($rooted) {
            $full = $token
        } elseif ($cwd) {
            $full = if ($Platform -eq (Get-YurunaIdentityPlatform)) { [System.IO.Path]::GetFullPath($token, $cwd) } else { $cwd.TrimEnd('/', '\') + '/' + $token }
        } else {
            $unresolved++
            continue
        }
        $comparable = ConvertTo-YurunaComparableScriptPath -Path $full -Platform $Platform
        foreach ($candidate in @($full, $comparable)) {
            foreach ($path in $expected) {
                if ([string]::Equals($candidate, $path, $comparison) -or [string]::Equals($candidate.Replace('\', '/'), $path.Replace('\', '/'), $comparison)) {
                    return 'expected'
                }
            }
        }
        $other++
    }
    if ($other -gt 0) { return 'other' }
    if ($unresolved -gt 0) { return 'unresolved' }
    return 'none'
}

function Get-YurunaProcessIdentityState {
    <#
    .SYNOPSIS
        Classify one PID against a process table: AliveOwned, AliveOther,
        DeadOrRecycled or Unknown.
    .DESCRIPTION
        Rules, in order:
          1. The PID is this process: AliveOwned (self).
          2. Absent from a complete table: DeadOrRecycled (process-absent);
             from an incomplete one: Unknown (table-incomplete).
          3. The row has no start time: Unknown (start-unreadable).
          4. A recorded start time that differs beyond the tolerance:
             DeadOrRecycled (start-mismatch).
          5. No recorded start but a record write time: a process started
             after the record was written is DeadOrRecycled
             (started-after-record); otherwise Unknown (no-exact-identity),
             because a plausible start time never proves ownership.
          6. After a start-time match: another owner is AliveOther
             (other-owner); a different designated identity is AliveOther
             (not-designated); the identity an owner-only launch record
             attests is AliveOwned (launch-record); a command line whose
             runner script resolves -- absolute, or relative to the process
             working directory -- to a path other than the expected ones is
             AliveOther (other-checkout), and one that names a runner script
             by a relative path no working directory can resolve is Unknown
             (script-path-unresolved); otherwise AliveOwned (start-time). A
             record in this runtime directory written by a process whose
             exact start time matches is that runtime's owner, so a bare
             interactive pwsh argv still qualifies.
    .PARAMETER ProcessId
        The PID to classify.
    .PARAMETER ProcessTable
        A Get-YurunaProcessTable result.
    .PARAMETER RecordedStartTimeUnixMs
        The start time the record carries (runner.start, inner.start, a
        cycle record, a gate owner).
    .PARAMETER RecordWrittenUtc
        When the record was written (pidfile mtime); used only without a
        recorded start time.
    .PARAMETER ExpectedScriptPath
        Exact runner script paths this runtime's owner runs.
    .PARAMETER ExpectedIdentity
        { Pid; StartTimeUnixMs } a caller designated.
    .PARAMETER AttestedIdentity
        { Pid; StartTimeUnixMs } that an owner-only record (the runner's
        launch record) attests runs one of the expected scripts. A live row
        matching it is the owner however its command line spells the script.
    .PARAMETER CurrentOwnerId
        The owner id (uid or session) of this user; defaults to this
        process's own row.
    .PARAMETER SelfPid
        This process's PID.
    .OUTPUTS
        [pscustomobject] @{ State; Pid; RecordedStartTimeUnixMs;
        LiveStartTimeUnixMs; IdentityVia; Reason; Row }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][psobject]$ProcessTable,
        [Nullable[long]]$RecordedStartTimeUnixMs,
        [Nullable[datetime]]$RecordWrittenUtc,
        [string[]]$ExpectedScriptPath,
        [psobject]$ExpectedIdentity,
        [psobject]$AttestedIdentity,
        [string]$CurrentOwnerId,
        [int]$SelfPid = $PID
    )
    $out = [ordered]@{
        State = 'Unknown'; Pid = $ProcessId; RecordedStartTimeUnixMs = $RecordedStartTimeUnixMs
        LiveStartTimeUnixMs = $null; IdentityVia = 'none'; Reason = $null; Row = $null
    }
    if ($ProcessId -eq $SelfPid) {
        $out.State = 'AliveOwned'; $out.IdentityVia = 'self'; $out.Reason = 'self'
        return [pscustomobject]$out
    }
    $rows = @($ProcessTable.Rows)
    $row = $null
    foreach ($candidate in $rows) { if ([int]$candidate.Pid -eq $ProcessId) { $row = $candidate; break } }
    if (-not $row) {
        if ($ProcessTable.Complete) { $out.State = 'DeadOrRecycled'; $out.Reason = 'process-absent' }
        else { $out.State = 'Unknown'; $out.Reason = 'table-incomplete' }
        return [pscustomobject]$out
    }
    $out.Row = $row
    $out.LiveStartTimeUnixMs = $row.StartTimeUnixMs
    if ($null -eq $row.StartTimeUnixMs) {
        $out.Reason = 'start-unreadable'
        return [pscustomobject]$out
    }
    $live = [long]$row.StartTimeUnixMs
    if ($null -ne $RecordedStartTimeUnixMs) {
        if ([Math]::Abs($live - [long]$RecordedStartTimeUnixMs) -gt $script:StartToleranceMs) {
            $out.State = 'DeadOrRecycled'; $out.Reason = 'start-mismatch'
            return [pscustomobject]$out
        }
        $out.IdentityVia = 'start-time'
    } elseif ($null -ne $RecordWrittenUtc) {
        $writtenMs = ConvertTo-YurunaUnixMs -Value ([datetime]$RecordWrittenUtc)
        if ($live -gt ($writtenMs + $script:StartToleranceMs)) {
            $out.State = 'DeadOrRecycled'; $out.Reason = 'started-after-record'
        } else {
            $out.Reason = 'no-exact-identity'
        }
        return [pscustomobject]$out
    } else {
        $out.Reason = 'no-exact-identity'
        return [pscustomobject]$out
    }

    if (-not $PSBoundParameters.ContainsKey('CurrentOwnerId')) {
        foreach ($candidate in $rows) {
            if ([int]$candidate.Pid -eq $SelfPid) { $CurrentOwnerId = [string]$candidate.OwnerId; break }
        }
    }
    if ($CurrentOwnerId -and $null -ne $row.OwnerId -and [string]$row.OwnerId -ne $CurrentOwnerId) {
        $out.State = 'AliveOther'; $out.Reason = 'other-owner'
        return [pscustomobject]$out
    }
    if ($ExpectedIdentity) {
        $expectedStart = $ExpectedIdentity.StartTimeUnixMs
        $samePid = ([int]$ExpectedIdentity.Pid -eq $ProcessId)
        $sameStart = ($null -ne $expectedStart) -and ([Math]::Abs($live - [long]$expectedStart) -le $script:StartToleranceMs)
        if (-not ($samePid -and $sameStart)) {
            $out.State = 'AliveOther'; $out.Reason = 'not-designated'
            return [pscustomobject]$out
        }
    }
    if ($AttestedIdentity -and $null -ne $AttestedIdentity.StartTimeUnixMs -and [int]$AttestedIdentity.Pid -eq $ProcessId -and
        [Math]::Abs($live - [long]$AttestedIdentity.StartTimeUnixMs) -le $script:StartToleranceMs) {
        $out.State = 'AliveOwned'
        $out.Reason = 'launch-record'
        return [pscustomobject]$out
    }
    $commandLine = [string]$row.CommandLine
    if ($ExpectedScriptPath -and -not [string]::IsNullOrEmpty($commandLine)) {
        switch (Get-YurunaCommandLineScriptVerdict -Row $row -ExpectedScriptPath $ExpectedScriptPath -Platform $ProcessTable.Platform) {
            'other' {
                $out.State = 'AliveOther'; $out.Reason = 'other-checkout'
                return [pscustomobject]$out
            }
            'unresolved' {
                $out.State = 'Unknown'; $out.Reason = 'script-path-unresolved'
                return [pscustomobject]$out
            }
            default { }
        }
    }
    $out.State = 'AliveOwned'
    $out.Reason = 'start-time'
    return [pscustomobject]$out
}

function Get-YurunaRunnerRecordFingerprint {
    <#
    .SYNOPSIS
        '<pid-part>.<start-part>': SHA-256 over each file's bytes, length and
        last-write time, so a removal can prove it deletes the generation it
        classified. Each half is verifiable on its own.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [string]$StartFile
    )
    $pidPart   = Get-YurunaFileFingerprintPart -Path $PidFile
    $startPart = Get-YurunaFileFingerprintPart -Path $StartFile
    if ($null -eq $pidPart -or $null -eq $startPart) { return $null }
    return "$pidPart.$startPart"
}

function Get-YurunaFileFingerprintPart {
    <#
    .SYNOPSIS
        Hex SHA-256 of one file's length, last-write ticks and bytes;
        'absent' for no file; $null when it exists but cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists($Path)) { return 'absent' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ticks = [System.IO.File]::GetLastWriteTimeUtc($Path).Ticks
        $header = [System.Text.Encoding]::ASCII.GetBytes("$($bytes.Length):${ticks}:")
        $buffer = [byte[]]::new($header.Length + $bytes.Length)
        [Array]::Copy($header, 0, $buffer, 0, $header.Length)
        [Array]::Copy($bytes, 0, $buffer, $header.Length, $bytes.Length)
        return ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($buffer))).ToLowerInvariant()
    } catch {
        return $null
    }
}

function Get-YurunaRunnerRecordState {
    <#
    .SYNOPSIS
        Classify a runner pidfile record (runner.pid, inner.pid, server.pid)
        into AliveOwned, AliveOther, DeadOrRecycled, Unknown or Missing.
    .DESCRIPTION
        A missing pidfile is Missing. An unreadable, empty or non-numeric one
        is Unknown and is never deleted -- that also covers a new writer
        caught between its create and its write. A start file that exists but
        cannot be parsed is Unknown. The fingerprint is taken before
        classification, so Remove-YurunaRunnerRecordGeneration can prove it
        deletes the same generation.
    .PARAMETER PidFile
        The pidfile.
    .PARAMETER StartFile
        Its start-time sidecar (runner.start, inner.start).
    .PARAMETER MtimeIdentity
        Use the pidfile's own last-write time when no sidecar exists (service
        pidfiles): a genuine owner started before it wrote the file.
    .PARAMETER ExpectedScriptPath
        See Get-YurunaProcessIdentityState.
    .PARAMETER ExpectedIdentity
        See Get-YurunaProcessIdentityState.
    .PARAMETER AttestedIdentity
        See Get-YurunaProcessIdentityState.
    .PARAMETER ProcessTable
        A snapshot to classify against; one is built when omitted.
    .OUTPUTS
        [pscustomobject] the identity record plus PidFile, StartFile and
        Fingerprint.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [string]$StartFile,
        [switch]$MtimeIdentity,
        [string[]]$ExpectedScriptPath,
        [psobject]$ExpectedIdentity,
        [psobject]$AttestedIdentity,
        [psobject]$ProcessTable
    )
    $fingerprint = Get-YurunaRunnerRecordFingerprint -PidFile $PidFile -StartFile $StartFile
    $base = [ordered]@{
        State = 'Unknown'; Pid = 0; RecordedStartTimeUnixMs = $null; LiveStartTimeUnixMs = $null
        IdentityVia = 'none'; Reason = $null; Row = $null
        PidFile = $PidFile; StartFile = $StartFile; Fingerprint = $fingerprint
    }
    if ([System.IO.FileInfo]::new($PidFile).LinkTarget) {
        $base.Reason = 'record-link'
        return [pscustomobject]$base
    }
    if (-not [System.IO.File]::Exists($PidFile)) {
        $base.State = 'Missing'; $base.Reason = 'record-missing'
        return [pscustomobject]$base
    }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($PidFile) } catch {
        $base.Reason = 'record-unreadable'
        return [pscustomobject]$base
    }
    $recordPid = 0
    if ($null -eq $fingerprint -or -not [int]::TryParse(([string]$text).Trim(), [ref]$recordPid) -or $recordPid -le 0) {
        $base.Reason = if ($null -eq $fingerprint) { 'record-unreadable' } else { 'record-malformed' }
        return [pscustomobject]$base
    }
    $base.Pid = $recordPid
    $recordedStart = $null
    if ($StartFile -and [System.IO.File]::Exists($StartFile)) {
        try {
            $startText = ([System.IO.File]::ReadAllText($StartFile)).Trim()
            $recordedStart = ConvertTo-YurunaUnixMs -Value ([DateTimeOffset]::Parse($startText, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime)
        } catch {
            $base.Reason = 'start-record-malformed'
            return [pscustomobject]$base
        }
    }
    $written = $null
    if ($MtimeIdentity -and $null -eq $recordedStart) {
        try { $written = [System.IO.File]::GetLastWriteTimeUtc($PidFile) } catch { $written = $null }
    }
    $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
    $identity = @{ ProcessId = $recordPid; ProcessTable = $table }
    if ($null -ne $recordedStart) { $identity.RecordedStartTimeUnixMs = [long]$recordedStart }
    if ($null -ne $written) { $identity.RecordWrittenUtc = $written }
    if ($ExpectedScriptPath) { $identity.ExpectedScriptPath = $ExpectedScriptPath }
    if ($ExpectedIdentity) { $identity.ExpectedIdentity = $ExpectedIdentity }
    if ($AttestedIdentity) { $identity.AttestedIdentity = $AttestedIdentity }
    $state = Get-YurunaProcessIdentityState @identity
    foreach ($key in @('State', 'Pid', 'RecordedStartTimeUnixMs', 'LiveStartTimeUnixMs', 'IdentityVia', 'Reason', 'Row')) {
        $base[$key] = $state.$key
    }
    return [pscustomobject]$base
}

function Remove-YurunaRunnerRecordGeneration {
    <#
    .SYNOPSIS
        Remove a runner record only as the exact generation a classification
        proved dead or recycled.
    .DESCRIPTION
        The caller passes the Fingerprint of a Get-YurunaRunnerRecordState
        result that returned DeadOrRecycled; this function does not classify
        and never removes anything else. The pidfile is renamed aside first
        and its bytes re-verified, so a new writer that replaced it between
        the check and the rename gets its record restored rather than
        deleted. The start file is verified the same way: one written by a
        new owner after the pidfile moved aside is put back.
    .PARAMETER PidFile
        The pidfile to remove.
    .PARAMETER StartFile
        Its start-time sidecar.
    .PARAMETER Fingerprint
        From the classification that proved the generation dead.
    .OUTPUTS
        [pscustomobject] @{ Removed; Reason removed|changed|missing|io-error|restored|preview }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [string]$StartFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint
    )
    $done = { param([bool]$Removed, [string]$Reason) [pscustomobject]@{ Removed = $Removed; Reason = $Reason } }
    if (-not [System.IO.File]::Exists($PidFile)) { return (& $done $false 'missing') }
    $parts = $Fingerprint -split '\.', 2
    if ($parts.Count -ne 2 -or [string]::IsNullOrEmpty($parts[0])) { return (& $done $false 'changed') }
    $current = Get-YurunaRunnerRecordFingerprint -PidFile $PidFile -StartFile $StartFile
    if ($current -ne $Fingerprint) { return (& $done $false 'changed') }
    if (-not $PSCmdlet.ShouldProcess($PidFile, (Format-YurunaOperatorMessage -Key 'runner.runner_record_remove_action'))) {
        return (& $done $false 'preview')
    }
    $aside = "$PidFile.$([guid]::NewGuid().ToString('N')).reclaim.tmp"
    try {
        [System.IO.File]::Move($PidFile, $aside, $false)
    } catch {
        Write-Verbose "Remove-YurunaRunnerRecordGeneration: could not move '$PidFile' aside: $($_.Exception.Message)"
        return (& $done $false 'io-error')
    }
    if ((Get-YurunaFileFingerprintPart -Path $aside) -ne $parts[0]) {
        try {
            [System.IO.File]::Move($aside, $PidFile, $false)
            return (& $done $false 'restored')
        } catch {
            Write-Verbose "Remove-YurunaRunnerRecordGeneration: a changed record could not be restored from '$aside': $($_.Exception.Message)"
            return (& $done $false 'io-error')
        }
    }
    try { [System.IO.File]::Delete($aside) } catch {
        Write-Verbose "Remove-YurunaRunnerRecordGeneration: '$aside' not deleted: $($_.Exception.Message)"
        return (& $done $false 'io-error')
    }
    if ($StartFile -and [System.IO.File]::Exists($StartFile)) {
        $startAside = "$StartFile.$([guid]::NewGuid().ToString('N')).reclaim.tmp"
        try {
            [System.IO.File]::Move($StartFile, $startAside, $false)
            if ((Get-YurunaFileFingerprintPart -Path $startAside) -eq $parts[1]) {
                [System.IO.File]::Delete($startAside)
            } else {
                [System.IO.File]::Move($startAside, $StartFile, $false)
            }
        } catch {
            Write-Verbose "Remove-YurunaRunnerRecordGeneration: start file '$StartFile' left in place: $($_.Exception.Message)"
        }
    }
    return (& $done $true 'removed')
}

function Write-YurunaProcessStartRecord {
    <#
    .SYNOPSIS
        Write this process's start time as an ISO-8601 UTC string, the same
        shape as runner.start (inner.start uses it).
    .DESCRIPTION
        Written atomically before the matching pidfile, so a reader never
        sees a new PID beside an old start time.
    .PARAMETER Path
        The start-record file.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.process_start_record_write_action'))) { return $false }
    try {
        $iso = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    } catch {
        Write-Verbose "Write-YurunaProcessStartRecord: own start time unreadable: $($_.Exception.Message)"
        return $false
    }
    return [bool](Write-YurunaStateFile -Path $Path -Content $iso -Confirm:$false)
}

function Get-YurunaRunnerCycleRecordPath {
    <#
    .SYNOPSIS
        <RuntimeDir>/runner.cycle.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    return [System.IO.Path]::Combine($RuntimeDir, 'runner.cycle.json')
}

function Write-YurunaRunnerCycleRecord {
    <#
    .SYNOPSIS
        Record the per-cycle process the outer just spawned, so the cycle is
        identified from its parent's own record of it, never by a basename.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER Process
        The Start-Process -PassThru object (Id, StartTime).
    .PARAMETER Cycle
        The outer's cycle counter.
    .PARAMETER CycleGeneration
        The outer-issued <runnerInstanceId>:<cycle> generation.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][psobject]$Process,
        [Parameter(Mandatory)][int]$Cycle,
        [AllowEmptyString()][string]$CycleGeneration
    )
    $path = Get-YurunaRunnerCycleRecordPath -RuntimeDir $RuntimeDir
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.cycle_record_write_action'))) { return $false }
    $childPid = [int]$Process.Id
    $childStart = $null
    try {
        if ($Process.PSObject.Properties['StartTime'] -and $Process.StartTime -is [datetime]) {
            $childStart = ConvertTo-YurunaUnixMs -Value $Process.StartTime
        }
    } catch { $childStart = $null }
    if ($null -eq $childStart) { $childStart = Get-YurunaProcessStartUnixMs -ProcessId $childPid }
    $record = [ordered]@{
        schemaVersion         = 1
        pid                   = $childPid
        startTimeUnixMs       = $childStart
        cycle                 = $Cycle
        cycleGeneration       = if ($CycleGeneration) { $CycleGeneration } else { $null }
        outerPid              = $PID
        outerStartTimeUnixMs  = Get-YurunaProcessStartUnixMs -ProcessId $PID
        writtenUtc            = [DateTime]::UtcNow.ToString('o')
    }
    return [bool](Write-YurunaStateFileJson -Path $path -InputObject $record -Confirm:$false)
}

function Clear-YurunaRunnerCycleRecord {
    <#
    .SYNOPSIS
        Remove runner.cycle.json once the cycle it names has exited, and only
        when it still names that PID.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER ProcessId
        The cycle PID the caller spawned.
    .OUTPUTS
        [bool] $true when the record was removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][int]$ProcessId
    )
    $path = Get-YurunaRunnerCycleRecordPath -RuntimeDir $RuntimeDir
    if (-not [System.IO.File]::Exists($path)) { return $false }
    try {
        $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ([int]$doc.pid -ne $ProcessId) { return $false }
    } catch {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.cycle_record_clear_action'))) { return $false }
    try { [System.IO.File]::Delete($path); return $true } catch { return $false }
}

function Read-YurunaRunnerCycleRecord {
    <#
    .SYNOPSIS
        Read runner.cycle.json and classify the cycle process it names.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER ProcessTable
        A snapshot to classify against; one is built when omitted.
    .OUTPUTS
        [pscustomobject] the identity record plus Path, Cycle,
        CycleGeneration, OuterPid and OuterStartTimeUnixMs. A missing file is
        State Missing; an unreadable one is Unknown.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [psobject]$ProcessTable
    )
    $path = Get-YurunaRunnerCycleRecordPath -RuntimeDir $RuntimeDir
    $base = [ordered]@{
        State = 'Unknown'; Pid = 0; RecordedStartTimeUnixMs = $null; LiveStartTimeUnixMs = $null
        IdentityVia = 'none'; Reason = $null; Row = $null
        Path = $path; Cycle = $null; CycleGeneration = $null; OuterPid = $null; OuterStartTimeUnixMs = $null
    }
    if (-not [System.IO.File]::Exists($path)) {
        $base.State = 'Missing'; $base.Reason = 'record-missing'
        return [pscustomobject]$base
    }
    $doc = $null
    try { $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop } catch {
        $base.Reason = 'record-unreadable'
        return [pscustomobject]$base
    }
    $cyclePid = 0
    if ($null -eq $doc -or -not [int]::TryParse([string]$doc.pid, [ref]$cyclePid) -or $cyclePid -le 0 -or [int]$doc.schemaVersion -ne 1) {
        $base.Reason = 'record-malformed'
        return [pscustomobject]$base
    }
    $base.Pid = $cyclePid
    $base.Cycle = $doc.cycle
    $base.CycleGeneration = $doc.cycleGeneration
    $base.OuterPid = $doc.outerPid
    $base.OuterStartTimeUnixMs = $doc.outerStartTimeUnixMs
    if ($null -eq $doc.startTimeUnixMs) {
        $base.Reason = 'no-exact-identity'
        return [pscustomobject]$base
    }
    $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
    $state = Get-YurunaProcessIdentityState -ProcessId $cyclePid -ProcessTable $table -RecordedStartTimeUnixMs ([long]$doc.startTimeUnixMs)
    foreach ($key in @('State', 'Pid', 'RecordedStartTimeUnixMs', 'LiveStartTimeUnixMs', 'IdentityVia', 'Reason', 'Row')) {
        $base[$key] = $state.$key
    }
    return [pscustomobject]$base
}

# --- REGION: Reclamation
function Get-YurunaRunnerExclusionSet {
    <#
    .SYNOPSIS
        Pure: the PIDs a reclaim must never signal (subtree pruned) and the
        PIDs it must never signal itself (subtree still walked).
    .DESCRIPTION
        Excluded: the worker; any process whose command line names this
        runtime's generated status server, the address beacon, a service
        script, the installer, the refresh entry point, the listener's
        diagnostic and start-cycle workers, or the pool drain and push
        forwarders; the status and config server pidfile owners when their
        record is AliveOwned or Unknown (uncertainty protects); any process
        of another owner. On Windows the server and beacon are Start-Process
        children of the inner or cycle process, so they are pruned here by
        identity, before the tree is expanded, even when server.pid is gone.

        Protected: the worker's ancestor chain, walked by parent until PID 0
        or 1, a missing row or a loop -- the sg relaunch and every hop above
        the worker survive.
    .PARAMETER ProcessTable
        A Get-YurunaProcessTable result.
    .PARAMETER RepoRoot
        The checkout the runner runs from.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER WorkerPid
        The reclaiming process.
    .PARAMETER ServerRecord
        Get-YurunaRunnerRecordState for server.pid.
    .PARAMETER ConfigServerRecord
        Get-YurunaRunnerRecordState for config-server.pid.
    .PARAMETER CurrentOwnerId
        This user's owner id; defaults to the worker's row.
    .OUTPUTS
        [pscustomobject] @{ ExcludedPid; ProtectedPid; Evidence } with
        Evidence rows { Pid; Role; Rule }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][psobject]$ProcessTable,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [int]$WorkerPid = $PID,
        [psobject]$ServerRecord,
        [psobject]$ConfigServerRecord,
        [string]$CurrentOwnerId
    )
    $rows = @($ProcessTable.Rows)
    $byPid = @{}
    foreach ($row in $rows) { $byPid[[int]$row.Pid] = $row }
    $comparison = Get-YurunaIdentityComparison -Platform $ProcessTable.Platform
    $excluded  = [System.Collections.Generic.List[int]]::new()
    $protected = [System.Collections.Generic.List[int]]::new()
    $evidence  = [System.Collections.Generic.List[object]]::new()
    $addExcluded = {
        param([int]$ExcludedProcessId, [string]$Role, [string]$Rule)
        if (-not $excluded.Contains($ExcludedProcessId)) { $excluded.Add($ExcludedProcessId) }
        $evidence.Add([pscustomobject]@{ Pid = $ExcludedProcessId; Role = $Role; Rule = $Rule })
    }
    & $addExcluded $WorkerPid 'worker' 'worker'

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($RepoRoot, (Resolve-YurunaCanonicalPath -Path $RepoRoot).Path)) {
        if ($candidate -and -not $roots.Contains($candidate)) { $roots.Add($candidate) }
    }
    $runtimes = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($RuntimeDir, (Resolve-YurunaCanonicalPath -Path $RuntimeDir).Path)) {
        if ($candidate -and -not $runtimes.Contains($candidate)) { $runtimes.Add($candidate) }
    }
    $patterns = [System.Collections.Generic.List[object]]::new()
    foreach ($runtime in $runtimes) {
        $patterns.Add(@{ Path = [System.IO.Path]::Combine($runtime, '.status-service.ps1'); Role = 'status-server' })
    }
    foreach ($root in $roots) {
        foreach ($entry in @(
            @{ Rel = 'test/modules/Invoke-HostAddressBeacon.ps1';   Role = 'beacon' },
            @{ Rel = 'test/service/';                               Role = 'service-script' },
            @{ Rel = 'install/';                                    Role = 'installer' },
            @{ Rel = 'test/lab/Invoke-HostRefresh.ps1';             Role = 'refresh-worker' },
            @{ Rel = 'test/modules/Invoke-HostDiagnosticWorker.ps1'; Role = 'listener-worker' },
            @{ Rel = 'test/modules/Invoke-StartCycleWorker.ps1';    Role = 'listener-worker' },
            @{ Rel = 'test/modules/Invoke-PoolStorageDrain.ps1';    Role = 'pool-drain' },
            @{ Rel = 'test/modules/Invoke-PoolPushForwarder.ps1';   Role = 'pool-push' }
        )) {
            $patterns.Add(@{ Path = ($root.TrimEnd('/', '\') + '/' + $entry.Rel); Role = $entry.Role })
        }
    }
    if (-not $PSBoundParameters.ContainsKey('CurrentOwnerId') -and $byPid.ContainsKey($WorkerPid)) {
        $CurrentOwnerId = [string]$byPid[$WorkerPid].OwnerId
    }
    foreach ($row in $rows) {
        $commandLine = [string]$row.CommandLine
        foreach ($pattern in $patterns) {
            if (Test-YurunaCommandLineNamesPath -CommandLine $commandLine -Path $pattern.Path -Comparison $comparison) {
                & $addExcluded ([int]$row.Pid) $pattern.Role 'command-line'
                break
            }
        }
        if ($CurrentOwnerId -and $null -ne $row.OwnerId -and [string]$row.OwnerId -ne $CurrentOwnerId) {
            & $addExcluded ([int]$row.Pid) 'other-owner' 'owner'
        }
    }
    foreach ($pair in @(@{ Record = $ServerRecord; Role = 'status-server' }, @{ Record = $ConfigServerRecord; Role = 'config-server' })) {
        $record = $pair.Record
        if ($record -and [int]$record.Pid -gt 0 -and $record.State -in @('AliveOwned', 'Unknown')) {
            & $addExcluded ([int]$record.Pid) $pair.Role "pidfile-$($record.State.ToLowerInvariant())"
        }
    }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $cursor = $byPid[$WorkerPid]
    while ($cursor) {
        $parentPid = [int]$cursor.ParentPid
        if ($parentPid -le 1 -or -not $seen.Add($parentPid)) { break }
        if (-not $protected.Contains($parentPid)) { $protected.Add($parentPid) }
        $evidence.Add([pscustomobject]@{ Pid = $parentPid; Role = 'worker-ancestor'; Rule = 'ancestor' })
        $cursor = $byPid[$parentPid]
    }
    return [pscustomobject]@{
        ExcludedPid  = $excluded.ToArray()
        ProtectedPid = $protected.ToArray()
        Evidence     = $evidence.ToArray()
    }
}

function Get-YurunaLaunchRecordIdentity {
    <#
    .SYNOPSIS
        The runner identity a valid launch record attests, as
        { Pid; StartTimeUnixMs }, when its recorded script is one of the
        expected paths; $null otherwise.
    .DESCRIPTION
        The launch record lives under the owner-only private root and is
        written by Start-TestRunner.ps1 itself, from its own script path and
        process identity, after it wins the pidfile. It therefore names the
        runner of this runtime even when the command line spells the script
        relative to a working directory that cannot be read.
    .PARAMETER LaunchRecord
        A Read-YurunaRunnerLaunchRecord result.
    .PARAMETER ExpectedScriptPath
        The runner script paths of this checkout.
    .OUTPUTS
        [pscustomobject] @{ Pid; StartTimeUnixMs } or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][psobject]$LaunchRecord, [Parameter(Mandatory)][string[]]$ExpectedScriptPath)
    if (-not $LaunchRecord -or -not $LaunchRecord.Valid -or -not ($LaunchRecord.Record -is [System.Collections.IDictionary])) { return $null }
    $record = $LaunchRecord.Record
    $runner = $record['runner']
    if (-not ($runner -is [System.Collections.IDictionary]) -or $null -eq $runner['pid'] -or [int]$runner['pid'] -le 0 -or $null -eq $runner['startTimeUnixMs']) {
        return $null
    }
    $scriptPath = [string]$record['scriptPath']
    if (-not $scriptPath) { return $null }
    $comparison = Get-YurunaIdentityComparison
    $recorded = ConvertTo-YurunaComparableScriptPath -Path $scriptPath
    foreach ($path in @($ExpectedScriptPath | Where-Object { $_ })) {
        if ([string]::Equals($recorded, (ConvertTo-YurunaComparableScriptPath -Path $path), $comparison)) {
            return [pscustomobject]@{ Pid = [int]$runner['pid']; StartTimeUnixMs = [long]$runner['startTimeUnixMs'] }
        }
    }
    return $null
}

function Get-YurunaRunnerSnapshot {
    <#
    .SYNOPSIS
        One consistent view of a runtime's runner records, classified against
        a single process table.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER RepoRoot
        The checkout.
    .PARAMETER WorkerPid
        The reclaiming process (excluded, its ancestry protected).
    .PARAMETER Deadline
        Bounds the process table.
    .PARAMETER ProcessTable
        A table to use instead of building one.
    .PARAMETER PrivateRoot
        See Read-YurunaRunnerLaunchRecord.
    .OUTPUTS
        [pscustomobject] @{ SchemaVersion; CapturedUtc; RuntimeDir; RepoRoot;
        Table; Outer; Cycle; Inner; Server; ConfigServer; LaunchRecord;
        Exclusions }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$WorkerPid = $PID,
        [psobject]$Deadline,
        [psobject]$ProcessTable,
        [string]$PrivateRoot
    )
    $table = if ($ProcessTable) { $ProcessTable } elseif ($Deadline) { Get-YurunaProcessTable -Deadline $Deadline } else { Get-YurunaProcessTable }
    $runtimePath = { param([string]$Leaf) [System.IO.Path]::Combine($RuntimeDir, $Leaf) }
    # Both spellings of the checkout, as the exclusion set uses: a runner
    # started through a symbolic link names the linked path.
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($RepoRoot, (Resolve-YurunaCanonicalPath -Path $RepoRoot).Path)) {
        if ($candidate -and -not $roots.Contains([string]$candidate)) { $roots.Add([string]$candidate) }
    }
    $outerScripts = @($roots | ForEach-Object { [System.IO.Path]::Combine($_, 'test', 'Start-TestRunner.ps1') })
    $innerScripts = @($roots | ForEach-Object { [System.IO.Path]::Combine($_, 'test', 'modules', 'Invoke-TestRunnerInnerLoop.ps1') })
    $launchArgs = @{ RuntimeDir = $RuntimeDir }
    if ($PrivateRoot) { $launchArgs.PrivateRoot = $PrivateRoot }
    $launch = Read-YurunaRunnerLaunchRecord @launchArgs
    $outerArgs = @{
        PidFile = (& $runtimePath 'runner.pid'); StartFile = (& $runtimePath 'runner.start')
        ExpectedScriptPath = $outerScripts; ProcessTable = $table
    }
    $attested = Get-YurunaLaunchRecordIdentity -LaunchRecord $launch -ExpectedScriptPath $outerScripts
    if ($attested) { $outerArgs.AttestedIdentity = $attested }
    $outer = Get-YurunaRunnerRecordState @outerArgs
    $cycle = Read-YurunaRunnerCycleRecord -RuntimeDir $RuntimeDir -ProcessTable $table
    $inner = Get-YurunaRunnerRecordState -PidFile (& $runtimePath 'inner.pid') -StartFile (& $runtimePath 'inner.start') `
        -ExpectedScriptPath $innerScripts -ProcessTable $table
    $server = Get-YurunaRunnerRecordState -PidFile (& $runtimePath 'server.pid') -MtimeIdentity `
        -ExpectedScriptPath @((& $runtimePath '.status-service.ps1')) -ProcessTable $table
    $configServer = Get-YurunaRunnerRecordState -PidFile (& $runtimePath 'config-server.pid') -MtimeIdentity -ProcessTable $table
    $exclusions = Get-YurunaRunnerExclusionSet -ProcessTable $table -RepoRoot $RepoRoot -RuntimeDir $RuntimeDir `
        -WorkerPid $WorkerPid -ServerRecord $server -ConfigServerRecord $configServer
    return [pscustomobject]@{
        SchemaVersion = 1
        CapturedUtc   = [DateTime]::UtcNow.ToString('o')
        RuntimeDir    = $RuntimeDir
        RepoRoot      = $RepoRoot
        Table         = $table
        Outer         = $outer
        Cycle         = $cycle
        Inner         = $inner
        Server        = $server
        ConfigServer  = $configServer
        LaunchRecord  = $launch
        Exclusions    = $exclusions
    }
}

function New-YurunaRunnerReclaimPlan {
    <#
    .SYNOPSIS
        Pure: turn a snapshot into signal roots (inner, cycle, outer) and the
        pruned, ordered target list.
    .DESCRIPTION
        Only AliveOwned records become roots. An Unknown or AliveOther record
        adds a refusal; the caller decides between partial and refused, and
        the plan never promotes one. An incomplete process table is itself a
        refusal. -PreserveOuter protects the outer (the resident outer that
        called the repair survives; its children do not).
    .PARAMETER Snapshot
        A Get-YurunaRunnerSnapshot result.
    .PARAMETER PreserveOuter
        Never signal the outer.
    .PARAMETER WorkerPid
        The reclaiming process.
    .PARAMETER ProtectedPid
        Extra PIDs never signaled themselves.
    .OUTPUTS
        [pscustomobject] @{ Roots; ProtectedPid; ExcludedPid; Target;
        Refusals; Reclaimable }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: builds an in-memory plan; the signals are sent by Stop-YurunaRunnerProcessTarget, which asks.')]
    param(
        [Parameter(Mandatory)][psobject]$Snapshot,
        [switch]$PreserveOuter,
        [int]$WorkerPid = $PID,
        [int[]]$ProtectedPid = @()
    )
    $roots = [System.Collections.Generic.List[object]]::new()
    $refusals = [System.Collections.Generic.List[object]]::new()
    if (-not $Snapshot.Table.Complete) {
        $refusals.Add([pscustomobject]@{ Role = 'table'; State = 'Unknown'; Reason = 'table-incomplete' })
    }
    foreach ($pair in @(@{ Role = 'inner'; Record = $Snapshot.Inner }, @{ Role = 'cycle'; Record = $Snapshot.Cycle }, @{ Role = 'outer'; Record = $Snapshot.Outer })) {
        $record = $pair.Record
        if (-not $record) { continue }
        switch ($record.State) {
            'AliveOwned' {
                if ([int]$record.Pid -eq $WorkerPid) { break }
                $roots.Add([pscustomobject]@{ Pid = [int]$record.Pid; StartTimeUnixMs = $record.LiveStartTimeUnixMs; Role = $pair.Role })
            }
            'Unknown'    { $refusals.Add([pscustomobject]@{ Role = $pair.Role; State = 'Unknown'; Reason = [string]$record.Reason }) }
            'AliveOther' { $refusals.Add([pscustomobject]@{ Role = $pair.Role; State = 'AliveOther'; Reason = [string]$record.Reason }) }
            default { }
        }
    }
    $protected = [System.Collections.Generic.List[int]]::new()
    foreach ($p in @($Snapshot.Exclusions.ProtectedPid) + @($ProtectedPid)) {
        if ($null -ne $p -and -not $protected.Contains([int]$p)) { $protected.Add([int]$p) }
    }
    if ($PreserveOuter -and $Snapshot.Outer -and [int]$Snapshot.Outer.Pid -gt 0 -and -not $protected.Contains([int]$Snapshot.Outer.Pid)) {
        $protected.Add([int]$Snapshot.Outer.Pid)
    }
    $excluded = @($Snapshot.Exclusions.ExcludedPid | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    $target = Resolve-YurunaRunnerProcessTarget -ProcessTable @($Snapshot.Table.Rows) -VerifiedRoot $roots.ToArray() `
        -ExcludedPid $excluded -ProtectedPid $protected.ToArray()
    return [pscustomobject]@{
        Roots        = $roots.ToArray()
        ProtectedPid = $protected.ToArray()
        ExcludedPid  = [int[]]$excluded
        Target       = $target
        Refusals     = $refusals.ToArray()
        Reclaimable  = ($refusals.Count -eq 0)
    }
}

function Compare-YurunaRunnerReclaimPlan {
    <#
    .SYNOPSIS
        Pure: the re-snapshot check before a hypervisor step. A new child, a
        changed or new root, or a change in refusals means not quiescent.
    .PARAMETER Before
        The plan the decision was made on.
    .PARAMETER After
        A plan from a fresh snapshot.
    .OUTPUTS
        [pscustomobject] @{ Quiescent; NewPid; GonePid; ChangedRoot }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][psobject]$Before,
        [Parameter(Mandatory)][psobject]$After
    )
    $beforePid = @($Before.Target.Descendants | ForEach-Object { [int]$_.Pid })
    $afterPid  = @($After.Target.Descendants | ForEach-Object { [int]$_.Pid })
    $newPid  = @($afterPid | Where-Object { $beforePid -notcontains $_ })
    $gonePid = @($beforePid | Where-Object { $afterPid -notcontains $_ })
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($role in @('inner', 'cycle', 'outer')) {
        $b = @($Before.Roots | Where-Object { $_.Role -eq $role }) | Select-Object -First 1
        $a = @($After.Roots | Where-Object { $_.Role -eq $role }) | Select-Object -First 1
        if (-not $b -and -not $a) { continue }
        if (-not $b -or -not $a -or [int]$a.Pid -ne [int]$b.Pid -or
            ($null -ne $a.StartTimeUnixMs -and $null -ne $b.StartTimeUnixMs -and [Math]::Abs([long]$a.StartTimeUnixMs - [long]$b.StartTimeUnixMs) -gt $script:StartToleranceMs)) {
            # A root that merely exited is gone, not a new risk.
            if ($b -and -not $a) { continue }
            $changed.Add($role)
        }
    }
    if ([bool]$Before.Reclaimable -ne [bool]$After.Reclaimable -or @($After.Refusals).Count -gt @($Before.Refusals).Count) {
        $changed.Add('refusals')
    }
    return [pscustomobject]@{
        Quiescent   = ($newPid.Count -eq 0 -and $changed.Count -eq 0)
        NewPid      = [int[]]$newPid
        GonePid     = [int[]]$gonePid
        ChangedRoot = $changed.ToArray()
    }
}

function Send-YurunaProcessSignal {
    <#
    .SYNOPSIS
        One bounded signal to one PID: TERM/KILL through /bin/kill on POSIX,
        taskkill without /T or /F and Stop-Process on Windows.
    .OUTPUTS
        [pscustomobject] @{ Sent; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][ValidateSet('TERM', 'KILL')][string]$Signal,
        [Parameter(Mandatory)][psobject]$Deadline
    )
    $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 10
    if (-not $seconds) { return [pscustomobject]@{ Sent = $false; Reason = 'deadline-exhausted' } }
    if ($IsWindows) {
        if ($Signal -eq 'KILL') {
            try {
                Stop-Process -Id $ProcessId -Force -ErrorAction Stop -Confirm:$false
                return [pscustomobject]@{ Sent = $true; Reason = 'sent' }
            } catch {
                return [pscustomobject]@{ Sent = $false; Reason = 'signal-failed' }
            }
        }
        $r = Invoke-BoundedNativeCommand -FilePath 'taskkill' -ArgumentList @('/PID', "$ProcessId") -TimeoutSeconds $seconds -Deadline $Deadline
    } else {
        $r = Invoke-BoundedNativeCommand -FilePath '/bin/kill' -ArgumentList @("-$Signal", "$ProcessId") -TimeoutSeconds $seconds -Deadline $Deadline
    }
    if ((Test-BoundedNativeResultComplete -Result $r) -and $r.ExitCode -eq 0) {
        return [pscustomobject]@{ Sent = $true; Reason = 'sent' }
    }
    $reason = if ($r.DeadlineExhausted) { 'deadline-exhausted' } elseif ($r.TimedOut) { 'signal-timeout' } else { 'signal-failed' }
    return [pscustomobject]@{ Sent = $false; Reason = $reason }
}

function Stop-YurunaRunnerProcessTarget {
    <#
    .SYNOPSIS
        Signal a reclaim plan's targets one PID at a time, inner work first,
        revalidating identity before every signal.
    .DESCRIPTION
        For each target row in plan order: revalidate (alive, same start
        time); TERM (POSIX /bin/kill, Windows taskkill without /T or /F);
        wait the grace period inside the deadline; revalidate again; KILL
        (POSIX /bin/kill -KILL, Windows Stop-Process on the single PID);
        confirm exit. A row without a start time is never signaled. A PID
        that now belongs to another process is skipped and left alive.

        Never a tree kill, a process-group signal or a port-based kill, and
        never a record deletion: the stale records are removed afterwards,
        and only as the generations proven dead.
    .PARAMETER Plan
        A New-YurunaRunnerReclaimPlan result.
    .PARAMETER Deadline
        Shared deadline; targets left when it expires are skipped-deadline.
    .PARAMETER GraceMilliseconds
        Wait after TERM.
    .PARAMETER ForceWaitMilliseconds
        Wait after KILL.
    .PARAMETER ProcessLookup
        Test seam: PID -> { Alive; StartTimeUnixMs }. The default lookup is
        bounded by -Deadline.
    .OUTPUTS
        [pscustomobject] @{ Converged; Targets; Survivors; DeadlineExhausted;
        ElapsedMs }. Target rows { Pid; Role; StartTimeUnixMs; Action; Signal;
        ElapsedMs; Reason } with Action already-exited, recycled-skipped,
        skipped-unverifiable, exited-after-term, exited-after-kill, survived,
        skipped-deadline or whatif.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][psobject]$Deadline,
        [ValidateRange(0, 600000)][int]$GraceMilliseconds = 5000,
        [ValidateRange(0, 600000)][int]$ForceWaitMilliseconds = 5000,
        [scriptblock]$ProcessLookup
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # The default lookup reads $Deadline from this function's scope when it
    # runs, so each revalidation is bounded by the shared deadline.
    $lookup = if ($ProcessLookup) { $ProcessLookup } else { { param([int]$TargetPid) Get-YurunaProcessLiveIdentity -ProcessId $TargetPid -Deadline $Deadline } }
    $roleOf = @{}
    foreach ($root in @($Plan.Roots)) { $roleOf[[int]$root.Pid] = [string]$root.Role }
    $targets = [System.Collections.Generic.List[object]]::new()
    $exhausted = $false
    $sameProcess = {
        param($Live, $Expected)
        if (-not $Live) { return 'unverifiable' }
        if (-not $Live.Alive) {
            # An absence reported from an incomplete lookup proves nothing.
            if ($Live.PSObject.Properties['Known'] -and -not $Live.Known) { return 'unverifiable' }
            return 'gone'
        }
        if ($null -eq $Live.StartTimeUnixMs) { return 'unverifiable' }
        if ([Math]::Abs([long]$Live.StartTimeUnixMs - [long]$Expected) -gt $script:StartToleranceMs) { return 'recycled' }
        return 'same'
    }
    $waitGone = {
        param([int]$TargetPid, [long]$Expected, [int]$Milliseconds)
        $limit = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds $Milliseconds
        do {
            $verdict = & $sameProcess (& $lookup $TargetPid) $Expected
            if ($verdict -ne 'same') { return $verdict }
        } while (Wait-YurunaDeadlineInterval -Deadline $limit -Milliseconds 100)
        return (& $sameProcess (& $lookup $TargetPid) $Expected)
    }
    foreach ($row in @($Plan.Target.Descendants)) {
        $targetStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $targetPid = [int]$row.Pid
        $entry = [ordered]@{
            Pid = $targetPid; Role = if ($roleOf.ContainsKey($targetPid)) { $roleOf[$targetPid] } else { 'descendant' }
            StartTimeUnixMs = $row.StartTimeUnixMs; Action = $null; Signal = $null; ElapsedMs = [long]0; Reason = $null
        }
        if ($null -eq $row.StartTimeUnixMs) {
            $entry.Action = 'skipped-unverifiable'; $entry.Reason = 'start-unreadable'
        } elseif (Test-YurunaDeadlineExpired -Deadline $Deadline) {
            $entry.Action = 'skipped-deadline'; $entry.Reason = 'deadline-exhausted'; $exhausted = $true
        } elseif (-not $PSCmdlet.ShouldProcess("PID $targetPid ($($entry.Role))", (Format-YurunaOperatorMessage -Key 'runner.runner_process_signal_action' -Arguments @{ signal = 'TERM' }))) {
            $entry.Action = 'whatif'; $entry.Reason = 'preview'
        } else {
            $expected = [long]$row.StartTimeUnixMs
            $before = & $sameProcess (& $lookup $targetPid) $expected
            if ($before -eq 'gone') {
                $entry.Action = 'already-exited'; $entry.Reason = 'process-absent'
            } elseif ($before -eq 'recycled') {
                $entry.Action = 'recycled-skipped'; $entry.Reason = 'start-mismatch'
            } elseif ($before -eq 'unverifiable') {
                $entry.Action = 'skipped-unverifiable'; $entry.Reason = 'start-unreadable'
            } else {
                $entry.Signal = 'TERM'
                $term = Send-YurunaProcessSignal -ProcessId $targetPid -Signal 'TERM' -Deadline $Deadline
                $afterTerm = & $waitGone $targetPid $expected $GraceMilliseconds
                if ($afterTerm -eq 'gone') {
                    $entry.Action = 'exited-after-term'; $entry.Reason = $term.Reason
                } elseif ($afterTerm -eq 'recycled') {
                    $entry.Action = 'recycled-skipped'; $entry.Reason = 'start-mismatch'
                } elseif ($afterTerm -eq 'unverifiable') {
                    # Identity can no longer be proven, so no stronger signal follows.
                    $entry.Action = 'skipped-unverifiable'; $entry.Reason = 'identity-lost'
                } elseif (Test-YurunaDeadlineExpired -Deadline $Deadline) {
                    $entry.Action = 'skipped-deadline'; $entry.Reason = 'deadline-exhausted'; $exhausted = $true
                } else {
                    $entry.Signal = 'KILL'
                    $kill = Send-YurunaProcessSignal -ProcessId $targetPid -Signal 'KILL' -Deadline $Deadline
                    $afterKill = & $waitGone $targetPid $expected $ForceWaitMilliseconds
                    if ($afterKill -eq 'gone') {
                        $entry.Action = 'exited-after-kill'; $entry.Reason = $kill.Reason
                    } elseif ($afterKill -eq 'recycled') {
                        $entry.Action = 'recycled-skipped'; $entry.Reason = 'start-mismatch'
                    } else {
                        $entry.Action = 'survived'
                        $entry.Reason = if ($kill.Sent) { 'still-running' } else { $kill.Reason }
                        if (Test-YurunaDeadlineExpired -Deadline $Deadline) { $exhausted = $true }
                    }
                }
            }
        }
        $entry.ElapsedMs = [long]$targetStopwatch.ElapsedMilliseconds
        Write-Verbose "Stop-YurunaRunnerProcessTarget: pid $targetPid ($($entry.Role)) -> $($entry.Action) ($($entry.Reason))"
        $targets.Add([pscustomobject]$entry)
    }
    $survivorActions = @('survived', 'skipped-deadline', 'skipped-unverifiable', 'whatif')
    $survivors = @($targets | Where-Object { $_.Action -in $survivorActions } | ForEach-Object { [int]$_.Pid })
    return [pscustomobject]@{
        Converged         = ($survivors.Count -eq 0)
        Targets           = $targets.ToArray()
        Survivors         = [int[]]$survivors
        DeadlineExhausted = $exhausted
        ElapsedMs         = [long]$stopwatch.ElapsedMilliseconds
    }
}

# --- REGION: Refresh gate
# One gate per user, under the private state root, because a hypervisor
# repair disrupts every runtime this user owns. The record is a critical
# record (checksummed, generation-numbered, previous generation retained),
# written only under runner-gate.lock; readers are lock-free. Anything that
# cannot be read holds every spawn: an orphaned or damaged gate stays closed
# until a resume or a disposition resolves it, never on age.
$script:GateRecordName   = 'runner-gate.record'
$script:GateLockName     = 'runner-gate.lock'
$script:GateKind         = 'runner-gate'
$script:LaunchKind       = 'runner-launch'
$script:ProtocolVersion  = 1
# A reader whose boot epoch differs by more than this treats a handoff token
# as expired: the tick counter the expiry is measured on restarted.
$script:BootEpochSlackMs = 120000
$script:RunnerOptionName = @('ConfigPath', 'NoGitPull', 'NoStatusService', 'NoConfigGate', 'CycleDelaySeconds', 'logLevel')
$script:RunnerTransportName = @('RefreshResume', 'RefreshHandoffToken')

function Get-YurunaBootEpochMs {
    <#
    .SYNOPSIS
        Wall-clock Unix ms at boot as seen now: UtcNow minus TickCount64.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Ms so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [Environment]::TickCount64)
}

function Resolve-YurunaRefreshStateRoot {
    <#
    .SYNOPSIS
        The private state root for refresh records: an explicitly given,
        already-resolved directory, or Get-YurunaPrivateStateRoot.
    .OUTPUTS
        [pscustomobject] @{ Resolved; Path; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$PrivateRoot,
        [switch]$NoCreate
    )
    if ($PrivateRoot) {
        $info = [System.IO.DirectoryInfo]::new($PrivateRoot)
        if ($info.LinkTarget) { return [pscustomobject]@{ Resolved = $false; Path = $PrivateRoot; Reason = 'reparse-point' } }
        if (-not $info.Exists) { return [pscustomobject]@{ Resolved = $false; Path = $PrivateRoot; Reason = 'absent' } }
        return [pscustomobject]@{ Resolved = $true; Path = $info.FullName; Reason = 'ok' }
    }
    $root = if ($NoCreate) { Get-YurunaPrivateStateRoot -NoCreate } else { Get-YurunaPrivateStateRoot }
    return [pscustomobject]@{ Resolved = [bool]$root.Resolved; Path = $root.Path; Reason = [string]$root.Reason }
}

function Get-YurunaCanonicalRuntimeDir {
    <#
    .SYNOPSIS
        The canonical spelling of a runtime directory, for comparison and for
        the runtime key.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $canonical = Resolve-YurunaCanonicalPath -Path $RuntimeDir
    $path = if ($canonical.Resolved -and $canonical.Path) { [string]$canonical.Path } else { [System.IO.Path]::GetFullPath($RuntimeDir) }
    return $path.TrimEnd('/', '\')
}

function Test-YurunaSameRuntimeDir {
    <#
    .SYNOPSIS
        $true when two runtime directory spellings name the same directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return [string]::Equals((Get-YurunaCanonicalRuntimeDir -RuntimeDir $Left), (Get-YurunaCanonicalRuntimeDir -RuntimeDir $Right), (Get-YurunaIdentityComparison))
}

function Get-YurunaRuntimeKey {
    <#
    .SYNOPSIS
        The runtime key: the first 16 lowercase hex characters of SHA-256 over
        the canonical runtime-dir path (lowercased first on macOS and
        Windows), used to name per-runtime private files.
    .PARAMETER RuntimeDir
        The runtime directory.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = Get-YurunaCanonicalRuntimeDir -RuntimeDir $RuntimeDir
    if ((Get-YurunaIdentityPlatform) -ne 'Linux') { $path = $path.ToLowerInvariant() }
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($path))
    return ([System.Convert]::ToHexString($hash)).ToLowerInvariant().Substring(0, 16)
}

function Read-YurunaRefreshGateRecord {
    <#
    .SYNOPSIS
        Lock-free read of the gate record: { Status ok|missing|unreadable|
        unsupported; Payload; Generation; Path; Detail }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Root)
    $path = [System.IO.Path]::Combine($Root, $script:GateRecordName)
    $out = [ordered]@{ Status = 'missing'; Payload = $null; Generation = [long]0; Path = $path; Detail = $null }
    # Neither generation present is a clean "no gate", answered without
    # loading the record reader at every spawn site.
    if (-not [System.IO.File]::Exists($path) -and -not [System.IO.File]::Exists("$path.prev") -and
        -not [System.IO.FileInfo]::new($path).LinkTarget) {
        return [pscustomobject]$out
    }
    $read = Read-YurunaCriticalRecord -Path $path -Kind $script:GateKind
    switch ($read.Status) {
        'missing' { return [pscustomobject]$out }
        'ok' {
            $payload = $read.Payload
            $out.Generation = [long]$read.Generation
            $schema = 0; $protocol = 0
            [void][int]::TryParse([string]$payload['schemaVersion'], [ref]$schema)
            [void][int]::TryParse([string]$payload['protocolVersion'], [ref]$protocol)
            if ($schema -ne 1 -or $protocol -gt $script:ProtocolVersion -or $protocol -lt 1) {
                $out.Status = 'unsupported'
                $out.Detail = "schema $schema protocol $protocol"
                return [pscustomobject]$out
            }
            $out.Status = 'ok'
            $out.Payload = $payload
            return [pscustomobject]$out
        }
        default {
            $out.Status = if ($read.Status -in @('unsupported-version', 'kind-mismatch')) { 'unsupported' } else { 'unreadable' }
            $out.Detail = [string]$read.Status
            return [pscustomobject]$out
        }
    }
}

function Get-YurunaRefreshGateState {
    <#
    .SYNOPSIS
        Read-only view of the host-refresh runner gate. Creates nothing.
    .DESCRIPTION
        No private root, no gate record, or a released gate: open. A closed,
        recovery-pending or handoff gate holds every spawn. A record that
        cannot be read, or carries a newer schema, is unknown and holds every
        spawn too (fail closed). A gate file present under a root that fails
        the private-root checks is unknown as well: nothing written there can
        be trusted, and nothing proves it absent.

        PreflightAllowed is $true only for a handoff whose token matches
        -TokenId, has not expired, was issued in this boot, and names this
        runtime directory. Orphaned means the gate is not open and its owner
        is positively dead or recycled.
    .PARAMETER RuntimeDir
        This runner's runtime directory; defaults to YURUNA_RUNTIME_DIR.
    .PARAMETER TokenId
        A handoff token this process carries.
    .PARAMETER PrivateRoot
        An already-resolved private state root; defaults to the per-user one.
    .PARAMETER Deadline
        Bounds the owner lookup (5 s at most) when the caller has a shared
        deadline.
    .OUTPUTS
        [pscustomobject] @{ SchemaVersion; State open|closed|handoff|
        recovery-pending|unknown; SpawnAllowed; PreflightAllowed; RequestId;
        Attempt; Generation; Purpose; Owner; OwnerState; Orphaned; Reason;
        Path; RuntimeDir; ExpiresTick; DesignatedOuter; OnReady; Reclaimed;
        ReasonCode }. Owner is the recorded { pid; startTimeUnixMs; role }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowEmptyString()][string]$TokenId,
        [string]$PrivateRoot,
        [psobject]$Deadline
    )
    $out = [ordered]@{
        SchemaVersion = 1; State = 'open'; SpawnAllowed = $true; PreflightAllowed = $false
        RequestId = $null; Attempt = $null; Generation = ''; Purpose = $null
        Owner = $null; OwnerState = $null; Orphaned = $false; Reason = 'no-gate'; Path = $null
        RuntimeDir = $null; ExpiresTick = $null; DesignatedOuter = $null; OnReady = $null
        Reclaimed = $null; ReasonCode = $null
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) {
        if ($root.Reason -in @('absent', 'no-home')) { return [pscustomobject]$out }
        $textual = if ($PrivateRoot) { $PrivateRoot } elseif ($HOME) { [System.IO.Path]::Combine($HOME, '.yuruna', 'host-refresh') } else { $null }
        $gateFile = if ($textual) { [System.IO.Path]::Combine($textual, $script:GateRecordName) } else { $null }
        $out.Path = $gateFile
        if ($gateFile -and ([System.IO.File]::Exists($gateFile) -or [System.IO.File]::Exists("$gateFile.prev"))) {
            $out.State = 'unknown'; $out.SpawnAllowed = $false; $out.Reason = 'private-root-unsafe'
        }
        return [pscustomobject]$out
    }
    $read = Read-YurunaRefreshGateRecord -Root $root.Path
    $out.Path = $read.Path
    if ($read.Status -eq 'missing') { return [pscustomobject]$out }
    if ($read.Status -ne 'ok') {
        $out.State = 'unknown'; $out.SpawnAllowed = $false
        $out.Reason = if ($read.Status -eq 'unsupported') { 'unsupported-schema' } else { 'unreadable' }
        return [pscustomobject]$out
    }
    $gate = $read.Payload
    $out.RequestId  = $gate['requestId']
    $out.Attempt    = $gate['attempt']
    $out.Generation = [string]$gate['generation']
    $out.RuntimeDir = $gate['runtimeDir']
    $out.Reclaimed  = $gate['reclaimed']
    $out.ReasonCode = $gate['reasonCode']
    switch ([string]$gate['state']) {
        'released'         { $out.State = 'open'; $out.SpawnAllowed = $true; $out.Reason = 'released' }
        'closed'           { $out.State = 'closed'; $out.SpawnAllowed = $false; $out.Reason = 'closed' }
        'recovery-pending' { $out.State = 'recovery-pending'; $out.SpawnAllowed = $false; $out.Reason = 'recovery-pending' }
        'handoff'          { $out.State = 'handoff'; $out.SpawnAllowed = $false; $out.Reason = 'handoff' }
        default            { $out.State = 'unknown'; $out.SpawnAllowed = $false; $out.Reason = 'unsupported-state' }
    }
    $handoff = $gate['handoff']
    if ($out.State -eq 'handoff' -and $handoff) {
        $out.Purpose = $handoff['purpose']
        $out.ExpiresTick = $handoff['expiresTick']
        $out.DesignatedOuter = $handoff['designatedOuter']
        $out.OnReady = $handoff['onReady']
        if ($TokenId) {
            $verdict = Test-YurunaRefreshTokenWindow -Handoff $handoff -TokenId $TokenId
            $runtimeMatch = (-not $RuntimeDir) -or (Test-YurunaSameRuntimeDir -Left $RuntimeDir -Right ([string]$gate['runtimeDir']))
            $out.PreflightAllowed = ($verdict -eq 'ok') -and $runtimeMatch
        }
    }
    if ($out.State -ne 'open') {
        $owner = $gate['owner']
        $out.Owner = $owner
        if ($owner -and $owner['pid']) {
            $ownerPid = [int]$owner['pid']
            $lookup = @{ ProcessId = @($ownerPid); TimeoutSeconds = 5 }
            if ($Deadline) { $lookup.Deadline = $Deadline }
            $table = Get-YurunaProcessTable @lookup
            $identity = @{ ProcessId = $ownerPid; ProcessTable = $table; SelfPid = -1 }
            if ($null -ne $owner['startTimeUnixMs']) { $identity.RecordedStartTimeUnixMs = [long]$owner['startTimeUnixMs'] }
            $out.OwnerState = (Get-YurunaProcessIdentityState @identity).State
        } else {
            $out.OwnerState = 'Unknown'
        }
        # A live handoff is not orphaned while its token can still be used;
        # the designated chain may be about to acknowledge.
        $tokenLive = ($out.State -eq 'handoff') -and $handoff -and
            ((Test-YurunaRefreshTokenWindow -Handoff $handoff -TokenId ([string]$handoff['tokenId'])) -eq 'ok')
        $out.Orphaned = ($out.OwnerState -eq 'DeadOrRecycled') -and -not $tokenLive
    }
    return [pscustomobject]$out
}

function Test-YurunaRefreshTokenWindow {
    <#
    .SYNOPSIS
        ok, token-mismatch, boot-changed or expired for a handoff block.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Handoff,
        [AllowEmptyString()][string]$TokenId
    )
    if (-not $Handoff) { return 'not-handoff' }
    if (-not $TokenId -or -not [string]::Equals([string]$Handoff['tokenId'], $TokenId, [StringComparison]::Ordinal)) { return 'token-mismatch' }
    $boot = $Handoff['bootEpochMs']
    if ($null -eq $boot -or [Math]::Abs((Get-YurunaBootEpochMs) - [long]$boot) -gt $script:BootEpochSlackMs) { return 'boot-changed' }
    if ($null -eq $Handoff['expiresTick'] -or [Environment]::TickCount64 -ge [long]$Handoff['expiresTick']) { return 'expired' }
    return 'ok'
}

function Test-YurunaRefreshSpawnAllowed {
    <#
    .SYNOPSIS
        Exactly one [bool]: may this process spawn or pull now?
    .DESCRIPTION
        $true when the gate is open; with -TokenId, also when the gate is in
        a handoff that token's preflight chain may pass.
    .PARAMETER RuntimeDir
        See Get-YurunaRefreshGateState.
    .PARAMETER TokenId
        See Get-YurunaRefreshGateState.
    .PARAMETER PrivateRoot
        See Get-YurunaRefreshGateState.
    .PARAMETER Deadline
        See Get-YurunaRefreshGateState.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowEmptyString()][string]$TokenId,
        [string]$PrivateRoot,
        [psobject]$Deadline
    )
    $call = @{ RuntimeDir = $RuntimeDir }
    if ($TokenId) { $call.TokenId = $TokenId }
    if ($PrivateRoot) { $call.PrivateRoot = $PrivateRoot }
    if ($Deadline) { $call.Deadline = $Deadline }
    $gate = Get-YurunaRefreshGateState @call
    return [bool]($gate.SpawnAllowed -or $gate.PreflightAllowed)
}

function Invoke-YurunaRefreshGateTransaction {
    <#
    .SYNOPSIS
        Read, decide and write the gate under runner-gate.lock.
    .DESCRIPTION
        The lock is a short lock (rank Gate) held only for this read, compare
        and write, taken with a bounded wait and never while waiting for any
        other lock. Decide receives the current payload (or $null) and returns
        @{ Write = [bool]; Payload; Reason }.
    .OUTPUTS
        [pscustomobject] @{ Done; Reason; Detail; Payload }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][scriptblock]$Decide
    )
    $lock = Enter-YurunaSingleFlightLock -Path ([System.IO.Path]::Combine($Root, $script:GateLockName)) `
        -WaitMilliseconds 2000 -Rank (Get-YurunaLockRank -Name Gate)
    if (-not $lock.Held) {
        $reason = if ($lock.Reason -in @('held-elsewhere', 'held-by-this-process', 'lock-order-violation')) { 'lock-busy' } else { 'write-failed' }
        return [pscustomobject]@{ Done = $false; Reason = $reason; Detail = [string]$lock.Reason; Payload = $null }
    }
    try {
        $path = [System.IO.Path]::Combine($Root, $script:GateRecordName)
        $read = Read-YurunaCriticalRecord -Path $path -Kind $script:GateKind
        if ($read.Status -notin @('ok', 'missing')) {
            return [pscustomobject]@{ Done = $false; Reason = 'unreadable'; Detail = [string]$read.Status; Payload = $null }
        }
        $current = if ($read.Status -eq 'ok') { $read.Payload } else { $null }
        if ($current) {
            $schema = 0
            [void][int]::TryParse([string]$current['schemaVersion'], [ref]$schema)
            if ($schema -ne 1) {
                return [pscustomobject]@{ Done = $false; Reason = 'unreadable'; Detail = "schema $schema"; Payload = $null }
            }
        }
        $decision = & $Decide $current
        if (-not $decision.Write) {
            return [pscustomobject]@{ Done = $false; Reason = [string]$decision.Reason; Detail = $null; Payload = $current }
        }
        $write = Write-YurunaCriticalRecord -Path $path -Kind $script:GateKind -Payload $decision.Payload `
            -ExpectedGeneration ([long]$read.Generation) -Confirm:$false
        if (-not $write.Committed) {
            return [pscustomobject]@{ Done = $false; Reason = 'write-failed'; Detail = [string]$write.Reason; Payload = $current }
        }
        return [pscustomobject]@{ Done = $true; Reason = 'written'; Detail = $null; Payload = $decision.Payload }
    } finally {
        Exit-YurunaSingleFlightLock -Lock $lock
    }
}

function ConvertTo-YurunaIdentityPayload {
    <#
    .SYNOPSIS
        { pid; startTimeUnixMs } from any { Pid; StartTimeUnixMs } shape, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Identity)
    if ($null -eq $Identity) { return $null }
    $idPid = if ($Identity -is [System.Collections.IDictionary]) {
        if ($Identity.Contains('pid')) { $Identity['pid'] } else { $Identity['Pid'] }
    } else { $Identity.Pid }
    $idStart = if ($Identity -is [System.Collections.IDictionary]) {
        if ($Identity.Contains('startTimeUnixMs')) { $Identity['startTimeUnixMs'] } else { $Identity['StartTimeUnixMs'] }
    } else { $Identity.StartTimeUnixMs }
    if ($null -eq $idPid -or [int]$idPid -le 0) { return $null }
    return @{ pid = [int]$idPid; startTimeUnixMs = if ($null -ne $idStart) { [long]$idStart } else { $null } }
}

function ConvertTo-YurunaReclaimedPayload {
    <#
    .SYNOPSIS
        The reclaimed { outer; cycle; inner } block, each an identity or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Reclaimed)
    $out = @{ outer = $null; cycle = $null; inner = $null }
    if ($null -eq $Reclaimed) { return $out }
    foreach ($role in @('outer', 'cycle', 'inner')) {
        $value = if ($Reclaimed -is [System.Collections.IDictionary]) { $Reclaimed[$role] } else { $Reclaimed.$role }
        $out[$role] = ConvertTo-YurunaIdentityPayload -Identity $value
    }
    return $out
}

function Set-YurunaRefreshGate {
    <#
    .SYNOPSIS
        Close, release, or mark recovery-pending the host-refresh runner gate.
    .DESCRIPTION
        A compare-and-set on the gate's generation under runner-gate.lock,
        then a critical write. -ExpectedGeneration is the Generation the
        caller read (empty when there was no gate); a missing gate matches an
        empty one. Closing revokes any outstanding handoff token. The lock
        wait is bounded at 2 s; a busy lock is lock-busy, and the caller
        refuses the disruptive step it guarded.
    .PARAMETER State
        closed, recovery-pending or released.
    .PARAMETER RequestId
        The host-refresh request.
    .PARAMETER Attempt
        The request's attempt number.
    .PARAMETER RuntimeDir
        The owning runtime directory.
    .PARAMETER ExpectedGeneration
        The gate generation the caller read.
    .PARAMETER Reclaimed
        { outer; cycle; inner } identities the attempt reclaimed.
    .PARAMETER ReasonCode
        A private reason token recorded with the transition.
    .PARAMETER OwnerPid
        The owning worker.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Written; Generation; Reason written|
        generation-mismatch|lock-busy|private-root-unavailable|write-failed|preview }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('closed', 'recovery-pending', 'released')][string]$State,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$Attempt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuntimeDir,
        [AllowEmptyString()][string]$ExpectedGeneration,
        [hashtable]$Reclaimed,
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')][string]$ReasonCode,
        [int]$OwnerPid = $PID,
        [string]$PrivateRoot
    )
    $result = [ordered]@{ Written = $false; Generation = $null; Reason = $null }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.refresh_gate_write_action' -Arguments @{ state = $State }))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot
    if (-not $root.Resolved) {
        $result.Reason = 'private-root-unavailable'
        return [pscustomobject]$result
    }
    $newGeneration = [guid]::NewGuid().ToString('N')
    $ownerStart = Get-YurunaProcessStartUnixMs -ProcessId $OwnerPid
    $canonicalRuntime = Get-YurunaCanonicalRuntimeDir -RuntimeDir $RuntimeDir
    $hasReclaimed = $PSBoundParameters.ContainsKey('Reclaimed')
    # Invoked by Invoke-YurunaRefreshGateTransaction as a callee of this
    # function, so it reads this function's parameters and locals through
    # PowerShell's dynamic scoping; a GetNewClosure copy would lose the
    # module's private helpers.
    $decide = {
        param($Current)
        $currentGeneration = if ($Current) { [string]$Current['generation'] } else { '' }
        if ([string]$ExpectedGeneration -ne $currentGeneration) { return @{ Write = $false; Reason = 'generation-mismatch' } }
        $reclaimedBlock = if ($hasReclaimed) {
            ConvertTo-YurunaReclaimedPayload -Reclaimed $Reclaimed
        } elseif ($Current -and $Current['reclaimed']) {
            ConvertTo-YurunaReclaimedPayload -Reclaimed $Current['reclaimed']
        } else {
            ConvertTo-YurunaReclaimedPayload -Reclaimed $null
        }
        $payload = [ordered]@{
            schemaVersion   = 1
            protocolVersion = $script:ProtocolVersion
            generation      = $newGeneration
            requestId       = $RequestId
            attempt         = $Attempt
            state           = $State
            owner           = @{ pid = $OwnerPid; startTimeUnixMs = $ownerStart; role = 'worker' }
            runtimeDir      = $canonicalRuntime
            reclaimed       = $reclaimedBlock
            handoff         = $null
            reasonCode      = if ($ReasonCode) { $ReasonCode } else { $null }
            updatedUtc      = [DateTime]::UtcNow.ToString('o')
        }
        return @{ Write = $true; Payload = $payload }
    }
    $tx = Invoke-YurunaRefreshGateTransaction -Root $root.Path -Decide $decide
    if ($tx.Done) {
        # Every transition here clears the handoff, revoking its token.
        $null = Remove-YurunaStaleReadinessAck -Root $root.Path -Confirm:$false
        $result.Written = $true
        $result.Generation = $newGeneration
        $result.Reason = 'written'
    } else {
        $result.Reason = if ($tx.Reason -eq 'unreadable') { 'write-failed' } else { $tx.Reason }
        Write-Verbose "Set-YurunaRefreshGate: not written ($($tx.Reason) $($tx.Detail))."
    }
    return [pscustomobject]$result
}

# --- REGION: Handoff token and readiness
function Get-YurunaAckPath {
    <#
    .SYNOPSIS
        <PrivateRoot>/runner-handoff.<tokenId>.ack.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$TokenId)
    return [System.IO.Path]::Combine($Root, "runner-handoff.$TokenId.ack.json")
}

function Remove-YurunaStaleReadinessAck {
    <#
    .SYNOPSIS
        Delete every readiness acknowledgment except the one for -KeepTokenId.
    .DESCRIPTION
        The gate holds at most one handoff per user, so an acknowledgment for
        any other token has no waiter: its token was completed, revoked by a
        new close, or expired and replaced. Without this they accumulate in
        the private root, one per refresh. Only regular files named exactly
        runner-handoff.<32 hex>.ack.json are touched; a link is left alone.
    .PARAMETER Root
        The private state root.
    .PARAMETER KeepTokenId
        The token whose acknowledgment stays, if any.
    .OUTPUTS
        [int] the number of files removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Root, [AllowEmptyString()][string]$KeepTokenId)
    $removed = 0
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($Root, 'runner-handoff.*.ack.json')) {
            $name = [System.IO.Path]::GetFileName($file)
            if ($name -cnotmatch '^runner-handoff\.([0-9a-f]{32})\.ack\.json$') { continue }
            if ($KeepTokenId -and $Matches[1] -eq $KeepTokenId) { continue }
            $info = [System.IO.FileInfo]::new($file)
            if ($info.LinkTarget) { continue }
            if (-not $PSCmdlet.ShouldProcess($file, (Format-YurunaOperatorMessage -Key 'runner.readiness_ack_remove_action'))) { continue }
            try { $info.Delete(); $removed++ } catch { Write-Verbose "Readiness acknowledgment '$file' not removed: $($_.Exception.Message)" }
        }
    } catch {
        Write-Verbose "Readiness acknowledgments under '$Root' not listed: $($_.Exception.Message)"
    }
    return $removed
}

function New-YurunaRunnerHandoffToken {
    <#
    .SYNOPSIS
        Move the gate from closed (or recovery-pending) to handoff with a
        fresh 128-bit token that admits only the designated preflight chain.
    .DESCRIPTION
        The token is an identifier, not a credential: its authority is the
        owner-only gate record, so seeing it in an argument vector grants
        nothing to another account, which has a different home. A
        resident-outer token designates the caller outer by PID and start
        time and records that outer as the gate's owner, so the gate is not
        read as orphaned once the worker has exited. -OnReady decides what a
        successful completion leaves: released, or recovery-pending when
        obligations remain outstanding.
    .PARAMETER RequestId
        The host-refresh request (must match the gate's).
    .PARAMETER Attempt
        The attempt number.
    .PARAMETER RuntimeDir
        The runtime the preflight chain must run in.
    .PARAMETER Purpose
        new-outer (the worker starts a runner) or resident-outer (the caller
        outer continues).
    .PARAMETER ExpiresInMilliseconds
        Token lifetime.
    .PARAMETER ExpectedGeneration
        The gate generation the caller read.
    .PARAMETER DesignatedOuter
        { Pid; StartTimeUnixMs } of the resident outer.
    .PARAMETER Reclaimed
        { outer; cycle; inner } identities the attempt reclaimed.
    .PARAMETER OnReady
        released or recovery-pending.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Issued; TokenId; Generation; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$Attempt,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuntimeDir,
        [Parameter(Mandatory)][ValidateSet('new-outer', 'resident-outer')][string]$Purpose,
        [Parameter(Mandatory)][ValidateRange(1, 86400000)][long]$ExpiresInMilliseconds,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedGeneration,
        [psobject]$DesignatedOuter,
        [hashtable]$Reclaimed,
        [ValidateSet('released', 'recovery-pending')][string]$OnReady = 'released',
        [string]$PrivateRoot
    )
    $result = [ordered]@{ Issued = $false; TokenId = $null; Generation = $null; Reason = $null }
    $designated = ConvertTo-YurunaIdentityPayload -Identity $DesignatedOuter
    if ($Purpose -eq 'resident-outer' -and ($null -eq $designated -or $null -eq $designated.startTimeUnixMs)) {
        $result.Reason = 'designated-outer-required'
        return [pscustomobject]$result
    }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_issue_action' -Arguments @{ purpose = $Purpose }))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot
    if (-not $root.Resolved) {
        $result.Reason = 'private-root-unavailable'
        return [pscustomobject]$result
    }
    $tokenId = [guid]::NewGuid().ToString('N')
    $newGeneration = [guid]::NewGuid().ToString('N')
    $canonicalRuntime = Get-YurunaCanonicalRuntimeDir -RuntimeDir $RuntimeDir
    $hasReclaimed = $PSBoundParameters.ContainsKey('Reclaimed')
    $decide = {
        param($Current)
        if (-not $Current) { return @{ Write = $false; Reason = 'no-gate' } }
        if ([string]$Current['generation'] -ne [string]$ExpectedGeneration) { return @{ Write = $false; Reason = 'generation-mismatch' } }
        if ([string]$Current['state'] -notin @('closed', 'recovery-pending')) { return @{ Write = $false; Reason = 'not-closed' } }
        if ([string]$Current['requestId'] -ne $RequestId) { return @{ Write = $false; Reason = 'request-mismatch' } }
        $owner = $Current['owner']
        if ($Purpose -eq 'resident-outer') {
            $owner = @{ pid = $designated.pid; startTimeUnixMs = $designated.startTimeUnixMs; role = 'resident-outer' }
        }
        $reclaimedBlock = if ($hasReclaimed) {
            ConvertTo-YurunaReclaimedPayload -Reclaimed $Reclaimed
        } else {
            ConvertTo-YurunaReclaimedPayload -Reclaimed $Current['reclaimed']
        }
        $payload = [ordered]@{
            schemaVersion   = 1
            protocolVersion = $script:ProtocolVersion
            generation      = $newGeneration
            requestId       = $RequestId
            attempt         = $Attempt
            state           = 'handoff'
            owner           = $owner
            runtimeDir      = $canonicalRuntime
            reclaimed       = $reclaimedBlock
            handoff         = [ordered]@{
                tokenId         = $tokenId
                purpose         = $Purpose
                designatedOuter = $designated
                onReady         = $OnReady
                expiresTick     = [long]([Environment]::TickCount64 + $ExpiresInMilliseconds)
                bootEpochMs     = Get-YurunaBootEpochMs
                issuedUtc       = [DateTime]::UtcNow.ToString('o')
            }
            reasonCode      = 'handoff-issued'
            updatedUtc      = [DateTime]::UtcNow.ToString('o')
        }
        return @{ Write = $true; Payload = $payload }
    }
    $tx = Invoke-YurunaRefreshGateTransaction -Root $root.Path -Decide $decide
    if ($tx.Done) {
        $null = Remove-YurunaStaleReadinessAck -Root $root.Path -KeepTokenId $tokenId -Confirm:$false
        $result.Issued = $true
        $result.TokenId = $tokenId
        $result.Generation = $newGeneration
        $result.Reason = 'issued'
    } else {
        $result.Reason = $tx.Reason
    }
    return [pscustomobject]$result
}

function Test-YurunaRunnerHandoffToken {
    <#
    .SYNOPSIS
        Validate a handoff token at one process boundary of the preflight
        chain.
    .DESCRIPTION
        Common checks: the gate is a readable handoff for this token, issued
        in this boot, unexpired, for this runtime directory. Per role:
          outer -- a resident-outer token must designate this process (PID
                   and start time);
          cycle -- this process's parent is the runner.pid owner, which is
                   AliveOwned;
          inner -- this process's parent is the cycle process runner.cycle.json
                   names, with a matching start time.
    .PARAMETER TokenId
        The token.
    .PARAMETER Role
        outer, cycle or inner.
    .PARAMETER RuntimeDir
        This process's runtime directory.
    .PARAMETER ProcessTable
        A snapshot to check parentage against.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason ok|no-gate|not-handoff|token-mismatch|
        expired|boot-changed|runtime-mismatch|parent-mismatch|not-designated|
        unreadable; RequestId; Attempt; Generation; Purpose; Reclaimed;
        ExpiresTick; DesignatedOuter; OnReady }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TokenId,
        [Parameter(Mandatory)][ValidateSet('outer', 'cycle', 'inner')][string]$Role,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [psobject]$ProcessTable,
        [string]$PrivateRoot
    )
    $out = [ordered]@{
        Valid = $false; Reason = $null; RequestId = $null; Attempt = $null; Generation = $null; Purpose = $null
        Reclaimed = $null; ExpiresTick = $null; DesignatedOuter = $null; OnReady = $null
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) {
        $out.Reason = if ($root.Reason -in @('absent', 'no-home')) { 'no-gate' } else { 'unreadable' }
        return [pscustomobject]$out
    }
    $read = Read-YurunaRefreshGateRecord -Root $root.Path
    if ($read.Status -eq 'missing') { $out.Reason = 'no-gate'; return [pscustomobject]$out }
    if ($read.Status -ne 'ok') { $out.Reason = 'unreadable'; return [pscustomobject]$out }
    $gate = $read.Payload
    $handoff = $gate['handoff']
    $out.RequestId = $gate['requestId']
    $out.Attempt = $gate['attempt']
    $out.Generation = [string]$gate['generation']
    $out.Reclaimed = $gate['reclaimed']
    if ([string]$gate['state'] -ne 'handoff' -or -not $handoff) { $out.Reason = 'not-handoff'; return [pscustomobject]$out }
    $out.Purpose = $handoff['purpose']
    $out.ExpiresTick = $handoff['expiresTick']
    $out.DesignatedOuter = $handoff['designatedOuter']
    $out.OnReady = $handoff['onReady']
    $window = Test-YurunaRefreshTokenWindow -Handoff $handoff -TokenId $TokenId
    if ($window -ne 'ok') { $out.Reason = $window; return [pscustomobject]$out }
    if (-not (Test-YurunaSameRuntimeDir -Left $RuntimeDir -Right ([string]$gate['runtimeDir']))) {
        $out.Reason = 'runtime-mismatch'
        return [pscustomobject]$out
    }
    switch ($Role) {
        'outer' {
            if ([string]$handoff['purpose'] -eq 'resident-outer') {
                $designated = $handoff['designatedOuter']
                $ownStart = Get-YurunaProcessStartUnixMs -ProcessId $PID
                if (-not $designated -or [int]$designated['pid'] -ne $PID -or $null -eq $ownStart -or $null -eq $designated['startTimeUnixMs'] -or
                    [Math]::Abs([long]$designated['startTimeUnixMs'] - [long]$ownStart) -gt $script:StartToleranceMs) {
                    $out.Reason = 'not-designated'
                    return [pscustomobject]$out
                }
            }
        }
        'cycle' {
            $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
            $self = @($table.Rows | Where-Object { [int]$_.Pid -eq $PID }) | Select-Object -First 1
            $outer = Get-YurunaRunnerRecordState -PidFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.pid')) `
                -StartFile ([System.IO.Path]::Combine($RuntimeDir, 'runner.start')) -ProcessTable $table
            if (-not $self -or $outer.State -ne 'AliveOwned' -or [int]$self.ParentPid -ne [int]$outer.Pid) {
                $out.Reason = 'parent-mismatch'
                return [pscustomobject]$out
            }
        }
        'inner' {
            $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
            $self = @($table.Rows | Where-Object { [int]$_.Pid -eq $PID }) | Select-Object -First 1
            $cycle = Read-YurunaRunnerCycleRecord -RuntimeDir $RuntimeDir -ProcessTable $table
            if (-not $self -or $cycle.State -ne 'AliveOwned' -or [int]$self.ParentPid -ne [int]$cycle.Pid) {
                $out.Reason = 'parent-mismatch'
                return [pscustomobject]$out
            }
        }
    }
    $out.Valid = $true
    $out.Reason = 'ok'
    return [pscustomobject]$out
}

function Get-YurunaRunnerChainIdentity {
    <#
    .SYNOPSIS
        The recorded { outer; cycle; inner } identities in a runtime directory,
        as { pid; startTimeUnixMs } or $null each.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $chain = @{ outer = $null; cycle = $null; inner = $null }
    $pair = @{ outer = @('runner.pid', 'runner.start'); inner = @('inner.pid', 'inner.start') }
    foreach ($role in @('outer', 'inner')) {
        $pidFile = [System.IO.Path]::Combine($RuntimeDir, $pair[$role][0])
        $startFile = [System.IO.Path]::Combine($RuntimeDir, $pair[$role][1])
        try {
            $recordPid = [int](([System.IO.File]::ReadAllText($pidFile)).Trim())
            $start = $null
            if ([System.IO.File]::Exists($startFile)) {
                $start = ConvertTo-YurunaUnixMs -Value ([DateTimeOffset]::Parse(([System.IO.File]::ReadAllText($startFile)).Trim(), [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime)
            }
            if ($recordPid -gt 0) { $chain[$role] = @{ pid = $recordPid; startTimeUnixMs = $start } }
        } catch {
            Write-Verbose "Chain identity: $($pair[$role][0]) unreadable: $($_.Exception.Message)"
        }
    }
    try {
        $doc = [System.IO.File]::ReadAllText((Get-YurunaRunnerCycleRecordPath -RuntimeDir $RuntimeDir)) | ConvertFrom-Json -ErrorAction Stop
        if ([int]$doc.pid -gt 0) { $chain.cycle = @{ pid = [int]$doc.pid; startTimeUnixMs = $doc.startTimeUnixMs } }
    } catch {
        Write-Verbose "Chain identity: runner.cycle.json unreadable: $($_.Exception.Message)"
    }
    return $chain
}

function Write-YurunaRunnerReadinessAck {
    <#
    .SYNOPSIS
        Publish the preflight chain's readiness acknowledgment for a token.
    .DESCRIPTION
        Written atomically (no BOM) as <PrivateRoot>/runner-handoff.<tokenId>.ack.json,
        and only while the gate holds a handoff for that token (anything else
        has no waiter and returns $false). It names the final identities of the chain -- this process for its
        role, the rest from the runtime records -- the request and gate
        generation, the probe verdict and the operator controls present at
        acknowledgment. The waiting side proves liveness separately.
    .PARAMETER TokenId
        The handoff token.
    .PARAMETER Role
        outer (failure acknowledgments at startup) or inner (the preflight).
    .PARAMETER State
        ready or failed.
    .PARAMETER FailureReason
        token-invalid, other-runner, runner-record-unknown, elevation-refused,
        config-gate-failed, yaml-missing, config-unreadable, host-type-unknown,
        driver-import-failed, probe-unavailable, probe-unresponsive,
        probe-undetermined or pidfile-lost.
    .PARAMETER Probe
        The probe record ({ state; reason; elapsedMs } are kept).
    .PARAMETER Chain
        { outer; cycle; inner } identities; defaults to this process plus the
        runtime records.
    .PARAMETER PreservedControl
        Operator control files present at acknowledgment.
    .PARAMETER RuntimeDir
        The runtime directory; defaults to YURUNA_RUNTIME_DIR.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$TokenId,
        [Parameter(Mandatory)][ValidateSet('outer', 'inner')][string]$Role,
        [Parameter(Mandatory)][ValidateSet('ready', 'failed')][string]$State,
        [ValidateSet('token-invalid', 'other-runner', 'runner-record-unknown', 'elevation-refused', 'config-gate-failed',
            'yaml-missing', 'config-unreadable', 'host-type-unknown', 'driver-import-failed', 'probe-unavailable',
            'probe-unresponsive', 'probe-undetermined', 'pidfile-lost')][string]$FailureReason,
        [psobject]$Probe,
        [hashtable]$Chain,
        [string[]]$PreservedControl = @(),
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$PrivateRoot
    )
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) { return $false }
    $path = Get-YurunaAckPath -Root $root.Path -TokenId $TokenId
    # Only the handoff the gate currently holds has a waiter; an
    # acknowledgment for any other token would be a stray private file.
    $gate = Read-YurunaRefreshGateRecord -Root $root.Path
    if ($gate.Status -ne 'ok' -or -not $gate.Payload['handoff'] -or [string]$gate.Payload['handoff']['tokenId'] -ne $TokenId) {
        Write-Verbose "Write-YurunaRunnerReadinessAck: the gate holds no handoff for this token; nothing written."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.readiness_ack_write_action'))) { return $false }
    $requestId = $gate.Payload['requestId']
    $generation = [string]$gate.Payload['generation']
    $identities = if ($Chain) {
        @{
            outer = ConvertTo-YurunaIdentityPayload -Identity $Chain['outer']
            cycle = ConvertTo-YurunaIdentityPayload -Identity $Chain['cycle']
            inner = ConvertTo-YurunaIdentityPayload -Identity $Chain['inner']
        }
    } elseif ($RuntimeDir) { Get-YurunaRunnerChainIdentity -RuntimeDir $RuntimeDir } else { @{ outer = $null; cycle = $null; inner = $null } }
    if (-not $Chain) {
        $identities[$Role] = @{ pid = $PID; startTimeUnixMs = (Get-YurunaProcessStartUnixMs -ProcessId $PID) }
    }
    $probeBlock = $null
    if ($Probe) {
        $probeBlock = [ordered]@{ state = [string]$Probe.state; reason = [string]$Probe.reason; elapsedMs = $Probe.elapsedMs }
    }
    $ack = [ordered]@{
        schemaVersion     = 1
        tokenId           = $TokenId
        requestId         = $requestId
        generation        = $generation
        role              = $Role
        state             = $State
        failureReason     = if ($FailureReason) { $FailureReason } else { $null }
        outer             = $identities.outer
        cycle             = $identities.cycle
        inner             = $identities.inner
        runtimeDir        = if ($RuntimeDir) { Get-YurunaCanonicalRuntimeDir -RuntimeDir $RuntimeDir } else { $null }
        probe             = $probeBlock
        preservedControls = @($PreservedControl)
        writtenUtc        = [DateTime]::UtcNow.ToString('o')
        writtenTick       = [Environment]::TickCount64
    }
    if (-not (Write-YurunaStateFileJson -Path $path -InputObject $ack -Confirm:$false)) { return $false }
    # A completion between the check above and this write has already
    # removed the acknowledgments it knew of; re-read the gate so this one
    # does not outlive the handoff it answers.
    $after = Read-YurunaRefreshGateRecord -Root $root.Path
    if ($after.Status -ne 'ok' -or -not $after.Payload['handoff'] -or [string]$after.Payload['handoff']['tokenId'] -ne $TokenId) {
        try { [System.IO.File]::Delete($path) } catch { Write-Verbose "Write-YurunaRunnerReadinessAck: late acknowledgment '$path' not removed: $($_.Exception.Message)" }
        return $false
    }
    return $true
}

function Read-YurunaRunnerReadinessAck {
    <#
    .SYNOPSIS
        The parsed acknowledgment for a token, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$TokenId)
    $path = Get-YurunaAckPath -Root $Root -TokenId $TokenId
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try {
        $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $doc -or [string]$doc.tokenId -ne $TokenId -or [int]$doc.schemaVersion -ne 1) { return $null }
    return $doc
}

function Test-YurunaAckIdentity {
    <#
    .SYNOPSIS
        $true when an acknowledged identity equals an expected one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Acked, [AllowNull()]$Expected)
    if (-not $Acked -or -not $Expected) { return $false }
    $ackedPid = [int]$Acked.pid
    $expectedPid = if ($Expected -is [System.Collections.IDictionary]) { [int]$Expected['pid'] } else { [int]$Expected.pid }
    $ackedStart = $Acked.startTimeUnixMs
    $expectedStart = if ($Expected -is [System.Collections.IDictionary]) { $Expected['startTimeUnixMs'] } else { $Expected.startTimeUnixMs }
    if ($ackedPid -le 0 -or $ackedPid -ne $expectedPid) { return $false }
    if ($null -eq $ackedStart -or $null -eq $expectedStart) { return $false }
    return ([Math]::Abs([long]$ackedStart - [long]$expectedStart) -le $script:StartToleranceMs)
}

function Test-YurunaLiveChain {
    <#
    .SYNOPSIS
        Prove from a fresh table that an acknowledged chain is alive and
        linked: inner <- cycle <- outer, each matching its runtime record.
    .OUTPUTS
        [string] ok or the first identity that failed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][psobject]$Ack, [Parameter(Mandatory)][psobject]$Table)
    if (-not $Table.Complete) { return 'table-incomplete' }
    $runtime = [string]$Ack.runtimeDir
    if (-not $runtime) { return 'runtime-missing' }
    $recorded = Get-YurunaRunnerChainIdentity -RuntimeDir $runtime
    $rowOf = @{}
    foreach ($row in @($Table.Rows)) { $rowOf[[int]$row.Pid] = $row }
    foreach ($role in @('inner', 'cycle', 'outer')) {
        $acked = $Ack.$role
        if (-not $acked) { return "$role-missing" }
        if (-not (Test-YurunaAckIdentity -Acked $acked -Expected $recorded[$role])) { return "$role-record-mismatch" }
        $row = $rowOf[[int]$acked.pid]
        if (-not $row -or $null -eq $row.StartTimeUnixMs -or
            [Math]::Abs([long]$row.StartTimeUnixMs - [long]$acked.startTimeUnixMs) -gt $script:StartToleranceMs) {
            return "$role-not-alive"
        }
    }
    if ([int]$rowOf[[int]$Ack.inner.pid].ParentPid -ne [int]$Ack.cycle.pid) { return 'inner-parent-mismatch' }
    if ([int]$rowOf[[int]$Ack.cycle.pid].ParentPid -ne [int]$Ack.outer.pid) { return 'cycle-parent-mismatch' }
    return 'ok'
}

function Wait-YurunaRunnerReadiness {
    <#
    .SYNOPSIS
        Wait for a token's readiness acknowledgment and verify it.
    .DESCRIPTION
        A failed acknowledgment returns at once. A ready one is accepted only
        after a fresh table proves the chain: the inner alive and matching
        inner.pid/inner.start, its parent the cycle runner.cycle.json names,
        whose parent is the outer runner.pid/runner.start name. Anything else
        is identity-mismatch.

        With -ExpectedCycle, the caller is the resident outer verifying a
        chain it spawned and that has already exited: liveness is replaced by
        the outer's own record of that cycle, so the acknowledgment must name
        this outer (or -ExpectedOuter) and exactly that cycle.
    .PARAMETER TokenId
        The handoff token.
    .PARAMETER Deadline
        How long to wait.
    .PARAMETER PollMilliseconds
        Poll interval.
    .PARAMETER TableProvider
        Test seam: returns a process table.
    .PARAMETER ExpectedCycle
        { Pid; StartTimeUnixMs } of the cycle the resident outer spawned.
    .PARAMETER ExpectedOuter
        { Pid; StartTimeUnixMs }; defaults to this process.
    .PARAMETER WatchProcess
        { Pid; StartTimeUnixMs } of the process that must produce the
        acknowledgment (the restarted runner). When it is proven gone -- or
        its PID now belongs to another process -- with no acknowledgment
        written, the wait ends at once as exited instead of running out the
        deadline.
    .PARAMETER ProcessLookup
        Test seam for -WatchProcess: PID -> { Alive; StartTimeUnixMs; Known }.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ State ready|failed|timeout|identity-mismatch|
        exited; Ack; Reason; ElapsedMs }. exited occurs only with
        -WatchProcess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'TokenId, TableProvider, ExpectedCycle and ExpectedOuter are read by the evaluate block the poll loop invokes, which the analyzer does not follow.')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$TokenId,
        [Parameter(Mandatory)][psobject]$Deadline,
        [ValidateRange(10, 60000)][int]$PollMilliseconds = 500,
        [scriptblock]$TableProvider,
        [psobject]$ExpectedCycle,
        [psobject]$ExpectedOuter,
        [psobject]$WatchProcess,
        [scriptblock]$ProcessLookup,
        [string]$PrivateRoot
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $finish = {
        param([string]$State, $Ack, [string]$Reason)
        [pscustomobject]@{ State = $State; Ack = $Ack; Reason = $Reason; ElapsedMs = [long]$stopwatch.ElapsedMilliseconds }
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) { return (& $finish 'timeout' $null 'private-root-unavailable') }
    # One read of the acknowledgment: a verdict, or $null to keep waiting.
    $evaluate = {
        $ack = Read-YurunaRunnerReadinessAck -Root $root.Path -TokenId $TokenId
        if (-not $ack) { return $null }
        if ([string]$ack.state -eq 'failed') { return (& $finish 'failed' $ack ([string]$ack.failureReason)) }
        if ([string]$ack.state -ne 'ready') { return $null }
        if ($ExpectedCycle) {
            $outer = if ($ExpectedOuter) { ConvertTo-YurunaIdentityPayload -Identity $ExpectedOuter } else {
                @{ pid = $PID; startTimeUnixMs = (Get-YurunaProcessStartUnixMs -ProcessId $PID -Deadline $Deadline) }
            }
            if (-not (Test-YurunaAckIdentity -Acked $ack.outer -Expected $outer)) { return (& $finish 'identity-mismatch' $ack 'outer-mismatch') }
            if (-not (Test-YurunaAckIdentity -Acked $ack.cycle -Expected (ConvertTo-YurunaIdentityPayload -Identity $ExpectedCycle))) {
                return (& $finish 'identity-mismatch' $ack 'cycle-mismatch')
            }
            if (-not $ack.inner -or [int]$ack.inner.pid -le 0) { return (& $finish 'identity-mismatch' $ack 'inner-missing') }
            return (& $finish 'ready' $ack 'ok')
        }
        $table = if ($TableProvider) { & $TableProvider } else { Get-YurunaProcessTable -Deadline $Deadline }
        $chain = Test-YurunaLiveChain -Ack $ack -Table $table
        if ($chain -eq 'ok') { return (& $finish 'ready' $ack 'ok') }
        return (& $finish 'identity-mismatch' $ack $chain)
    }
    $watched = ConvertTo-YurunaIdentityPayload -Identity $WatchProcess
    $lookup = if ($ProcessLookup) { $ProcessLookup } else { { param([int]$TargetPid) Get-YurunaProcessLiveIdentity -ProcessId $TargetPid -Deadline $Deadline } }
    # Gone only when proven: an incomplete lookup keeps waiting.
    $watchedGone = {
        $live = & $lookup ([int]$watched.pid)
        if (-not $live) { return $false }
        if (-not $live.Alive) { return (-not $live.PSObject.Properties['Known'] -or [bool]$live.Known) }
        return ($null -ne $watched.startTimeUnixMs -and $null -ne $live.StartTimeUnixMs -and
            [Math]::Abs([long]$live.StartTimeUnixMs - [long]$watched.startTimeUnixMs) -gt $script:StartToleranceMs)
    }
    do {
        $verdict = & $evaluate
        if ($verdict) { return $verdict }
        if ($watched -and (& $watchedGone)) {
            # The process may have acknowledged just before it exited.
            $verdict = & $evaluate
            if ($verdict) { return $verdict }
            return (& $finish 'exited' $null 'runner-exited')
        }
    } while (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds $PollMilliseconds)
    return (& $finish 'timeout' $null 'ack-timeout')
}

function Complete-YurunaRunnerHandoff {
    <#
    .SYNOPSIS
        End a handoff: revoke the token and leave the gate released or
        recovery-pending.
    .DESCRIPTION
        A compare-and-set from handoff to the verdict, clearing the handoff
        block, then removal of that token's acknowledgment. A released verdict
        is downgraded to the gate's recorded onReady (recovery-pending when
        obligations remain). -AsDesignatedOuter is how a resident outer leaves
        the gate after verifying its own preflight chain: allowed only for a
        resident-outer token that designates this process.
    .PARAMETER TokenId
        The token being completed.
    .PARAMETER Verdict
        released or recovery-pending.
    .PARAMETER ExpectedGeneration
        The gate generation the caller read.
    .PARAMETER AsDesignatedOuter
        Complete as the designated resident outer.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Completed; Generation; State; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'ExpectedGeneration is read by the decide block the gate transaction invokes, which the analyzer does not follow.')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$TokenId,
        [Parameter(Mandatory)][ValidateSet('released', 'recovery-pending')][string]$Verdict,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedGeneration,
        [switch]$AsDesignatedOuter,
        [string]$PrivateRoot
    )
    $result = [ordered]@{ Completed = $false; Generation = $null; State = $null; Reason = $null }
    if (-not $PSCmdlet.ShouldProcess($TokenId, (Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_complete_action' -Arguments @{ verdict = $Verdict }))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) { $result.Reason = 'private-root-unavailable'; return [pscustomobject]$result }
    $newGeneration = [guid]::NewGuid().ToString('N')
    $ownStart = if ($AsDesignatedOuter) { Get-YurunaProcessStartUnixMs -ProcessId $PID } else { $null }
    $decide = {
        param($Current)
        if (-not $Current) { return @{ Write = $false; Reason = 'no-gate' } }
        if ([string]$Current['generation'] -ne [string]$ExpectedGeneration) { return @{ Write = $false; Reason = 'generation-mismatch' } }
        $handoff = $Current['handoff']
        if ([string]$Current['state'] -ne 'handoff' -or -not $handoff) { return @{ Write = $false; Reason = 'not-handoff' } }
        if ([string]$handoff['tokenId'] -ne $TokenId) { return @{ Write = $false; Reason = 'token-mismatch' } }
        if ($AsDesignatedOuter) {
            $designated = $handoff['designatedOuter']
            if ([string]$handoff['purpose'] -ne 'resident-outer' -or -not $designated -or [int]$designated['pid'] -ne $PID -or
                $null -eq $ownStart -or $null -eq $designated['startTimeUnixMs'] -or
                [Math]::Abs([long]$designated['startTimeUnixMs'] - [long]$ownStart) -gt $script:StartToleranceMs) {
                return @{ Write = $false; Reason = 'not-designated' }
            }
        }
        $final = $Verdict
        if ($final -eq 'released' -and [string]$handoff['onReady'] -eq 'recovery-pending') { $final = 'recovery-pending' }
        $payload = [ordered]@{}
        foreach ($key in $Current.Keys) { $payload[$key] = $Current[$key] }
        $payload['generation'] = $newGeneration
        $payload['state']      = $final
        $payload['handoff']    = $null
        $payload['reasonCode'] = if ($Verdict -eq 'released') { 'handoff-ready' } else { 'handoff-failed' }
        $payload['updatedUtc'] = [DateTime]::UtcNow.ToString('o')
        return @{ Write = $true; Payload = $payload }
    }
    $tx = Invoke-YurunaRefreshGateTransaction -Root $root.Path -Decide $decide
    if (-not $tx.Done) {
        $result.Reason = $tx.Reason
        return [pscustomobject]$result
    }
    # No handoff remains, so no acknowledgment has a waiter.
    $null = Remove-YurunaStaleReadinessAck -Root $root.Path -Confirm:$false
    $result.Completed = $true
    $result.Generation = $newGeneration
    $result.State = [string]$tx.Payload['state']
    $result.Reason = 'completed'
    return [pscustomobject]$result
}

function Complete-YurunaRunnerExpiredHandoff {
    <#
    .SYNOPSIS
        As the designated resident outer, end a resident-outer handoff whose
        token can no longer be used, leaving the gate recovery-pending.
    .DESCRIPTION
        A resident-outer token records the outer itself as the gate's owner,
        and the worker that issued it has exited, so while the outer lives
        the gate never reads as orphaned and nobody else completes it. When
        the token expires, or the host rebooted since it was issued, before
        the outer dispatched its preflight, the gate would otherwise stay in
        handoff for good. This completes it recovery-pending -- the verdict a
        failed preflight gets -- which Invoke-HostRefresh.ps1 -Resume then
        resolves. A token still inside its window is left alone.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Completed; Reason completed|no-gate|not-handoff|
        not-resident|not-designated|token-live|lock-busy|write-failed|
        unreadable|private-root-unavailable|preview; RequestId; Generation;
        State }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([string]$PrivateRoot)
    $result = [ordered]@{ Completed = $false; Reason = $null; RequestId = $null; Generation = $null; State = $null }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) { $result.Reason = 'private-root-unavailable'; return [pscustomobject]$result }
    $gatePath = [System.IO.Path]::Combine($root.Path, $script:GateRecordName)
    if (-not $PSCmdlet.ShouldProcess($gatePath, (Format-YurunaOperatorMessage -Key 'runner.refresh_handoff_complete_action' -Arguments @{ verdict = 'recovery-pending' }))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $ownStart = Get-YurunaProcessStartUnixMs -ProcessId $PID
    $newGeneration = [guid]::NewGuid().ToString('N')
    $decide = {
        param($Current)
        if (-not $Current) { return @{ Write = $false; Reason = 'no-gate' } }
        $handoff = $Current['handoff']
        if ([string]$Current['state'] -ne 'handoff' -or -not $handoff) { return @{ Write = $false; Reason = 'not-handoff' } }
        if ([string]$handoff['purpose'] -ne 'resident-outer') { return @{ Write = $false; Reason = 'not-resident' } }
        $designated = $handoff['designatedOuter']
        if (-not $designated -or [int]$designated['pid'] -ne $PID -or $null -eq $ownStart -or $null -eq $designated['startTimeUnixMs'] -or
            [Math]::Abs([long]$designated['startTimeUnixMs'] - [long]$ownStart) -gt $script:StartToleranceMs) {
            return @{ Write = $false; Reason = 'not-designated' }
        }
        if ((Test-YurunaRefreshTokenWindow -Handoff $handoff -TokenId ([string]$handoff['tokenId'])) -eq 'ok') {
            return @{ Write = $false; Reason = 'token-live' }
        }
        $payload = [ordered]@{}
        foreach ($key in $Current.Keys) { $payload[$key] = $Current[$key] }
        $payload['generation'] = $newGeneration
        $payload['state']      = 'recovery-pending'
        $payload['handoff']    = $null
        $payload['reasonCode'] = 'handoff-expired'
        $payload['updatedUtc'] = [DateTime]::UtcNow.ToString('o')
        return @{ Write = $true; Payload = $payload }
    }
    $tx = Invoke-YurunaRefreshGateTransaction -Root $root.Path -Decide $decide
    if ($tx.Payload) { $result.RequestId = $tx.Payload['requestId'] }
    if (-not $tx.Done) {
        $result.Reason = $tx.Reason
        return [pscustomobject]$result
    }
    $null = Remove-YurunaStaleReadinessAck -Root $root.Path -Confirm:$false
    $result.Completed = $true
    $result.Reason = 'completed'
    $result.Generation = $newGeneration
    $result.State = 'recovery-pending'
    return [pscustomobject]$result
}

# --- REGION: Launch record
function Get-YurunaLaunchRecordPath {
    <#
    .SYNOPSIS
        <PrivateRoot>/runner-launch.<rtkey>.record.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RuntimeDir)
    return [System.IO.Path]::Combine($Root, "runner-launch.$(Get-YurunaRuntimeKey -RuntimeDir $RuntimeDir).record")
}

function Get-YurunaScriptParameterDefault {
    <#
    .SYNOPSIS
        A script parameter's constant default value, read from its param
        block, or $null when it has none or it is not a constant.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$Name)
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        foreach ($parameter in @($ast.ParamBlock.Parameters)) {
            if ([string]::Equals($parameter.Name.VariablePath.UserPath, $Name, [StringComparison]::OrdinalIgnoreCase) -and $parameter.DefaultValue) {
                return $parameter.DefaultValue.SafeGetValue()
            }
        }
    } catch {
        Write-Verbose "Default for -$Name unreadable from '$ScriptPath': $($_.Exception.Message)"
    }
    return $null
}

function Write-YurunaRunnerLaunchRecord {
    <#
    .SYNOPSIS
        Persist the runner's validated launch specification, so a refresh
        restarts it with the configuration it had.
    .DESCRIPTION
        Written by Start-TestRunner.ps1 after it wins its pidfile. Every
        bound name is accounted for in one of three lists -- the six operator
        options, the refresh transport fields (never recorded), and the
        common parameters -- and any other name aborts the write, so nothing
        is dropped silently. The six options are recorded with their resolved
        values and defaults filled in; the working directory, runtime
        directory and the forwarded YURUNA_* environment are recorded beside
        them, never as parameters. An environment name outside the allow-list
        is a refusal, not a silent drop.
    .PARAMETER ScriptPath
        The runner script ($PSCommandPath).
    .PARAMETER BoundParameters
        Its $PSBoundParameters.
    .PARAMETER ResolvedConfigPath
        The resolved -ConfigPath.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER RepoRoot
        The checkout.
    .PARAMETER WorkingDirectory
        The runner's working directory.
    .PARAMETER ForwardEnvironment
        The forwarded YURUNA_* snapshot.
    .PARAMETER AllowedEnvironmentName
        Names the snapshot may carry.
    .PARAMETER RunnerPid
        The runner process.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Written; Path; Reason written|unaccounted-parameter|
        invalid-parameter|private-root-unavailable|write-failed|preview; Parameter }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)][string]$ResolvedConfigPath,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$ForwardEnvironment,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedEnvironmentName,
        [int]$RunnerPid = $PID,
        [string]$PrivateRoot
    )
    $result = [ordered]@{ Written = $false; Path = $null; Reason = $null; Parameter = $null }
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    foreach ($name in @($BoundParameters.Keys)) {
        if ($script:RunnerOptionName -contains $name -or $script:RunnerTransportName -contains $name -or $common -contains $name) { continue }
        $result.Reason = 'unaccounted-parameter'
        $result.Parameter = [string]$name
        return [pscustomobject]$result
    }
    $environment = [ordered]@{}
    foreach ($name in @($ForwardEnvironment.Keys | Sort-Object)) {
        if ($AllowedEnvironmentName -notcontains $name -or [string]$name -cnotmatch '^YURUNA_[A-Z0-9_]+$') {
            $result.Reason = 'invalid-parameter'
            $result.Parameter = "env:$name"
            return [pscustomobject]$result
        }
        $environment[[string]$name] = [string]$ForwardEnvironment[$name]
    }
    # Keys, not Contains: $PSBoundParameters is a generic dictionary whose
    # Contains is an explicit interface member PowerShell does not call.
    $boundNames = @($BoundParameters.Keys | ForEach-Object { [string]$_ })
    $bound = { param([string]$Name) $boundNames -contains $Name }
    $cycleDelay = if (& $bound 'CycleDelaySeconds') { [int]$BoundParameters['CycleDelaySeconds'] } else { Get-YurunaScriptParameterDefault -ScriptPath $ScriptPath -Name 'CycleDelaySeconds' }
    $parameters = [ordered]@{
        ConfigPath        = $ResolvedConfigPath
        NoGitPull         = [bool]((& $bound 'NoGitPull') -and [bool]$BoundParameters['NoGitPull'])
        NoStatusService   = [bool]((& $bound 'NoStatusService') -and [bool]$BoundParameters['NoStatusService'])
        NoConfigGate      = [bool]((& $bound 'NoConfigGate') -and [bool]$BoundParameters['NoConfigGate'])
        CycleDelaySeconds = if ($null -ne $cycleDelay) { [int]$cycleDelay } else { $null }
        logLevel          = if ((& $bound 'logLevel') -and $BoundParameters['logLevel']) { [string]$BoundParameters['logLevel'] } else { $null }
    }
    $record = [ordered]@{
        schemaVersion         = 1
        runnerProtocolVersion = $script:ProtocolVersion
        scriptPath            = $ScriptPath
        repoRoot              = $RepoRoot
        runtimeDir            = Get-YurunaCanonicalRuntimeDir -RuntimeDir $RuntimeDir
        workingDirectory      = $WorkingDirectory
        runner                = @{ pid = $RunnerPid; startTimeUnixMs = (Get-YurunaProcessStartUnixMs -ProcessId $RunnerPid) }
        parameters            = $parameters
        explicitlyBound       = @($script:RunnerOptionName | Where-Object { & $bound $_ })
        environment           = $environment
        writtenUtc            = [DateTime]::UtcNow.ToString('o')
        endedUtc              = $null
        cleanExit             = $false
    }
    $spec = Test-YurunaRunnerLaunchSpec -Record $record -ScriptPath $ScriptPath
    if (-not $spec.Valid) {
        $result.Reason = 'invalid-parameter'
        $result.Parameter = $spec.Parameter
        return [pscustomobject]$result
    }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.launch_record_write_action'))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot
    if (-not $root.Resolved) { $result.Reason = 'private-root-unavailable'; return [pscustomobject]$result }
    $path = Get-YurunaLaunchRecordPath -Root $root.Path -RuntimeDir $RuntimeDir
    $result.Path = $path
    $current = Read-YurunaCriticalRecord -Path $path -Kind $script:LaunchKind
    $expected = if ($current.Status -eq 'ok') { [long]$current.Generation } elseif ($current.Status -eq 'missing') { [long]0 } else { $null }
    if ($null -eq $expected) {
        # Damaged evidence is never overwritten by the critical writer; a
        # runner refuses nothing over it, it just cannot be restarted by a
        # refresh until the operator removes the damaged record.
        $result.Reason = 'write-failed'
        return [pscustomobject]$result
    }
    $write = Write-YurunaCriticalRecord -Path $path -Kind $script:LaunchKind -Payload $record -ExpectedGeneration $expected -Confirm:$false
    if (-not $write.Committed) { $result.Reason = 'write-failed'; return [pscustomobject]$result }
    $result.Written = $true
    $result.Reason = 'written'
    return [pscustomobject]$result
}

function Complete-YurunaRunnerLaunchRecord {
    <#
    .SYNOPSIS
        Mark this runner's launch record ended; -CleanExit for an orderly exit
        (Ctrl+C, a pool drain, a normal end), so a refresh never restarts a
        runner the operator stopped.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER CleanExit
        The runner is exiting in an orderly way.
    .PARAMETER RunnerPid
        Only a record naming this runner is changed.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [switch]$CleanExit,
        [int]$RunnerPid = $PID,
        [string]$PrivateRoot
    )
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) { return $false }
    $path = Get-YurunaLaunchRecordPath -Root $root.Path -RuntimeDir $RuntimeDir
    $current = Read-YurunaCriticalRecord -Path $path -Kind $script:LaunchKind
    if ($current.Status -ne 'ok') { return $false }
    $payload = $current.Payload
    if (-not $payload['runner'] -or [int]$payload['runner']['pid'] -ne $RunnerPid) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.launch_record_complete_action'))) { return $false }
    $payload['endedUtc'] = [DateTime]::UtcNow.ToString('o')
    $payload['cleanExit'] = [bool]$CleanExit
    $write = Write-YurunaCriticalRecord -Path $path -Kind $script:LaunchKind -Payload $payload -ExpectedGeneration ([long]$current.Generation) -Confirm:$false
    return [bool]$write.Committed
}

function Read-YurunaRunnerLaunchRecord {
    <#
    .SYNOPSIS
        Read the launch record for a runtime directory.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .OUTPUTS
        [pscustomobject] @{ Found; Valid; Record; Reason; Path }. A record
        written for another runtime directory is not valid.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$PrivateRoot
    )
    $out = [ordered]@{ Found = $false; Valid = $false; Record = $null; Reason = $null; Path = $null }
    $root = Resolve-YurunaRefreshStateRoot -PrivateRoot $PrivateRoot -NoCreate
    if (-not $root.Resolved) {
        $out.Reason = if ($root.Reason -in @('absent', 'no-home')) { 'missing' } else { 'private-root-unavailable' }
        return [pscustomobject]$out
    }
    $path = Get-YurunaLaunchRecordPath -Root $root.Path -RuntimeDir $RuntimeDir
    $out.Path = $path
    $read = Read-YurunaCriticalRecord -Path $path -Kind $script:LaunchKind
    if ($read.Status -eq 'missing') { $out.Reason = 'missing'; return [pscustomobject]$out }
    $out.Found = $true
    if ($read.Status -ne 'ok') { $out.Reason = [string]$read.Status; return [pscustomobject]$out }
    $record = $read.Payload
    $out.Record = $record
    $version = 0
    [void][int]::TryParse([string]$record['runnerProtocolVersion'], [ref]$version)
    if ([int]$record['schemaVersion'] -ne 1 -or $version -lt 1 -or $version -gt $script:ProtocolVersion) {
        $out.Reason = 'unsupported-version'
        return [pscustomobject]$out
    }
    if (-not (Test-YurunaSameRuntimeDir -Left $RuntimeDir -Right ([string]$record['runtimeDir']))) {
        $out.Reason = 'runtime-mismatch'
        return [pscustomobject]$out
    }
    if (-not ($record['parameters'] -is [System.Collections.IDictionary])) {
        $out.Reason = 'parameters-missing'
        return [pscustomobject]$out
    }
    $record['explicitlyBound'] = @($record['explicitlyBound'])
    $out.Valid = $true
    $out.Reason = 'ok'
    return [pscustomobject]$out
}

function Test-YurunaRunnerLaunchSpec {
    <#
    .SYNOPSIS
        Validate a launch record against the runner script's own parameter
        metadata.
    .DESCRIPTION
        Every recorded option name is resolved through the script's
        ResolveParameter and must come back with the identical declared name,
        so an abbreviation, an alias or a misspelling is refused. Each value
        must convert to the parameter's type and satisfy its ValidateSet,
        ValidateRange, ValidatePattern and not-null attributes, read from the
        metadata rather than restated here. A newer protocol version than
        this code knows is refused.
    .PARAMETER Record
        The launch record payload (or a Read-YurunaRunnerLaunchRecord result).
    .PARAMETER ScriptPath
        The runner script that will be started.
    .PARAMETER RequireExistingConfig
        The recorded -ConfigPath must name an existing file.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason; Parameter }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][psobject]$Record,
        [Parameter(Mandatory)][string]$ScriptPath,
        [switch]$RequireExistingConfig
    )
    $fail = { param([string]$Reason, [string]$Parameter) [pscustomobject]@{ Valid = $false; Reason = $Reason; Parameter = $Parameter } }
    $payload = $Record
    if ($Record.PSObject.Properties['Valid'] -and $Record.PSObject.Properties['Record']) { $payload = $Record.Record }
    if ($null -eq $payload) { return (& $fail 'record-missing' $null) }
    $get = { param($Object, [string]$Name) if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] } else { $Object.$Name } }
    $version = 0
    [void][int]::TryParse([string](& $get $payload 'runnerProtocolVersion'), [ref]$version)
    if ($version -lt 1 -or $version -gt $script:ProtocolVersion) { return (& $fail 'unsupported-version' $null) }
    $command = $null
    try { $command = Get-Command -CommandType ExternalScript -Name $ScriptPath -ErrorAction Stop } catch {
        return (& $fail 'script-unavailable' $null)
    }
    $recordedScript = [string](& $get $payload 'scriptPath')
    if ($recordedScript) {
        $left = (Resolve-YurunaCanonicalPath -Path $recordedScript).Path
        $right = (Resolve-YurunaCanonicalPath -Path $ScriptPath).Path
        if (-not $left -or -not $right -or -not [string]::Equals($left, $right, (Get-YurunaIdentityComparison))) {
            return (& $fail 'script-mismatch' $null)
        }
    }
    $parameters = & $get $payload 'parameters'
    if ($null -eq $parameters) { return (& $fail 'parameters-missing' $null) }
    $names = if ($parameters -is [System.Collections.IDictionary]) { @($parameters.Keys) } else { @($parameters.PSObject.Properties.Name) }
    foreach ($name in $names) {
        $meta = $null
        try { $meta = $command.ResolveParameter([string]$name) } catch { $meta = $null }
        if (-not $meta -or -not [string]::Equals($meta.Name, [string]$name, [StringComparison]::Ordinal)) {
            return (& $fail 'unknown-parameter' ([string]$name))
        }
        $value = & $get $parameters ([string]$name)
        if ($null -eq $value) { continue }
        if ($meta.SwitchParameter) {
            if ($value -isnot [bool]) { return (& $fail 'invalid-value' ([string]$name)) }
            continue
        }
        $converted = $null
        try { $converted = [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, $meta.ParameterType) } catch {
            return (& $fail 'invalid-value' ([string]$name))
        }
        foreach ($attribute in @($meta.Attributes)) {
            $ok = $true
            if ($attribute -is [System.Management.Automation.ValidateSetAttribute]) {
                $comparison = if ($attribute.IgnoreCase) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
                $ok = @($attribute.ValidValues | Where-Object { $comparison.Equals([string]$_, [string]$converted) }).Count -gt 0
            } elseif ($attribute -is [System.Management.Automation.ValidateRangeAttribute]) {
                if ($null -ne $attribute.MinRange -and $converted -lt $attribute.MinRange) { $ok = $false }
                if ($null -ne $attribute.MaxRange -and $converted -gt $attribute.MaxRange) { $ok = $false }
            } elseif ($attribute -is [System.Management.Automation.ValidatePatternAttribute]) {
                $ok = [regex]::IsMatch([string]$converted, $attribute.RegexPattern, $attribute.Options)
            } elseif ($attribute -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]) {
                $ok = -not [string]::IsNullOrEmpty([string]$converted)
            }
            if (-not $ok) { return (& $fail 'invalid-value' ([string]$name)) }
        }
    }
    if ($RequireExistingConfig) {
        $config = [string](& $get $parameters 'ConfigPath')
        if ([string]::IsNullOrWhiteSpace($config) -or -not [System.IO.File]::Exists($config)) {
            return (& $fail 'config-missing' 'ConfigPath')
        }
    }
    return [pscustomobject]@{ Valid = $true; Reason = 'ok'; Parameter = $null }
}

function New-YurunaRunnerResumeArgumentList {
    <#
    .SYNOPSIS
        The -File argument vector that restarts a runner from its launch
        record in refresh-resume mode.
    .DESCRIPTION
        Emits one [string] per token: -ConfigPath <path>, each true switch
        (a false switch is omitted, which is equivalent for these scripts),
        -CycleDelaySeconds <n>, -logLevel <level> when recorded, then
        -RefreshResume -RefreshHandoffToken <token>. Callers capture with @().
    .PARAMETER Record
        The launch record payload (or a Read-YurunaRunnerLaunchRecord result).
    .PARAMETER TokenId
        The handoff token.
    .OUTPUTS
        [string] elements.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns strings, changes nothing.')]
    param(
        [Parameter(Mandatory)][psobject]$Record,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$TokenId
    )
    $payload = $Record
    if ($Record.PSObject.Properties['Valid'] -and $Record.PSObject.Properties['Record']) { $payload = $Record.Record }
    $parameters = if ($payload -is [System.Collections.IDictionary]) { $payload['parameters'] } else { $payload.parameters }
    $get = { param([string]$Name) if ($parameters -is [System.Collections.IDictionary]) { $parameters[$Name] } else { $parameters.$Name } }
    $config = & $get 'ConfigPath'
    if ($config) { '-ConfigPath'; [string]$config }
    foreach ($switchName in @('NoGitPull', 'NoStatusService', 'NoConfigGate')) {
        if ([bool](& $get $switchName)) { "-$switchName" }
    }
    $delay = & $get 'CycleDelaySeconds'
    if ($null -ne $delay) { '-CycleDelaySeconds'; [string][int]$delay }
    $level = & $get 'logLevel'
    if ($level) { '-logLevel'; [string]$level }
    '-RefreshResume'
    '-RefreshHandoffToken'
    $TokenId
}

# --- REGION: Protocol capability
function Get-YurunaRunnerProtocolCapability {
    <#
    .SYNOPSIS
        Static declaration of where runner reclamation and restart are
        qualified.
    .DESCRIPTION
        Available only where the process table, single-PID signaling, the
        detached launch and the handoff have all run against real processes.
        Linux and macOS exercise their native process tables, /bin/kill,
        the set -m detach and a live three-process readiness handoff against
        disposable stand-ins. Windows exercises CIM identities, single-PID
        termination, the reparent hop and the same live handoff. Enabling a
        platform requires this declaration and recorded native canary evidence.
    .PARAMETER Platform
        Linux, MacOS or Windows; defaults to the running OS.
    .OUTPUTS
        [pscustomobject] @{ ProtocolVersion; Platform; ProcessTable; Signal;
        DetachedLaunch; Handoff; Available; UnavailableReasonKey }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateSet('Linux', 'MacOS', 'Windows')][string]$Platform)
    if (-not $Platform) { $Platform = Get-YurunaIdentityPlatform }
    $normalized = switch ($Platform) { 'linux' { 'Linux' } 'macos' { 'MacOS' } default { 'Windows' } }
    $declaration = @{
        Linux   = @{ ProcessTable = 'tested'; Signal = 'tested'; DetachedLaunch = 'tested'; Handoff = 'tested'; Available = $true; Key = $null }
        MacOS   = @{ ProcessTable = 'tested'; Signal = 'tested'; DetachedLaunch = 'tested'; Handoff = 'tested'; Available = $true; Key = $null }
        Windows = @{ ProcessTable = 'tested'; Signal = 'tested'; DetachedLaunch = 'tested'; Handoff = 'tested'; Available = $true; Key = $null }
    }[$normalized]
    return [pscustomobject]@{
        ProtocolVersion      = $script:ProtocolVersion
        Platform             = $normalized
        ProcessTable         = $declaration.ProcessTable
        Signal               = $declaration.Signal
        DetachedLaunch       = $declaration.DetachedLaunch
        Handoff              = $declaration.Handoff
        Available            = [bool]$declaration.Available
        UnavailableReasonKey = $declaration.Key
    }
}

# --- REGION: Runner restart after a refresh
function Remove-YurunaStaleRunnerStream {
    <#
    .SYNOPSIS
        Prune old runner.<requestId>.out/.err captures from the private work
        directory.
    .DESCRIPTION
        Each restart leaves one capture that the restarted runner holds open
        for its whole life, so they otherwise pile up one per refresh. A file
        goes only when it is older than -MaxAgeDays and is not among the
        -KeepNewest most recently written: a quiet runner that is still alive
        is almost always one of the latest restarts, and a runner that has
        written nothing for that long has little stderr to lose. Links are
        never followed or removed.
    .PARAMETER Directory
        The private work directory.
    .PARAMETER MaxAgeDays
        Minimum age, by last write, of a file that may go.
    .PARAMETER KeepNewest
        How many of the most recent captures always stay.
    .OUTPUTS
        [int] the number of files removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateRange(0, 3650)][int]$MaxAgeDays = 7,
        [ValidateRange(0, 1000)][int]$KeepNewest = 4
    )
    $removed = 0
    try {
        $files = @(foreach ($path in [System.IO.Directory]::EnumerateFiles($Directory, 'runner.*')) {
            $info = [System.IO.FileInfo]::new($path)
            if ($info.Name -match '^runner\..+\.(out|err)$' -and -not $info.LinkTarget) { $info }
        }) | Sort-Object -Property LastWriteTimeUtc -Descending
        $cutoff = [DateTime]::UtcNow.AddDays(-$MaxAgeDays)
        foreach ($info in @($files | Select-Object -Skip $KeepNewest)) {
            if ($info.LastWriteTimeUtc -gt $cutoff) { continue }
            if (-not $PSCmdlet.ShouldProcess($info.FullName, (Format-YurunaOperatorMessage -Key 'runner.runner_stream_remove_action'))) { continue }
            try { $info.Delete(); $removed++ } catch { Write-Verbose "Runner stream '$($info.FullName)' not removed: $($_.Exception.Message)" }
        }
    } catch {
        Write-Verbose "Runner streams under '$Directory' not listed: $($_.Exception.Message)"
    }
    return $removed
}

function Invoke-YurunaRunnerRefreshResume {
    <#
    .SYNOPSIS
        Restart the runner after a host refresh and wait for its verified
        readiness: validate the launch record, issue a new-outer handoff
        token, launch Start-TestRunner.ps1 detached in resume mode, wait for
        the preflight chain's acknowledgment, and complete the handoff.
    .DESCRIPTION
        Refused (nothing launched) when the launch record does not validate
        against the runner script, or its config file is gone. The runner
        starts with the recorded options, working directory and forwarded
        environment, stdout discarded and stderr in the private directory.
        A ready, verified chain completes the handoff released (or the
        gate's onReady); anything else completes it recovery-pending, so the
        gate never stays in handoff after this returns.
    .PARAMETER LaunchRecord
        Read-YurunaRunnerLaunchRecord output (or its Record payload).
    .PARAMETER RequestId
        The host-refresh request.
    .PARAMETER Attempt
        The attempt number.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER RepoRoot
        The checkout whose test/Start-TestRunner.ps1 is started.
    .PARAMETER ExpectedGateGeneration
        The gate generation the worker read.
    .PARAMETER Reclaimed
        { outer; cycle; inner } identities the attempt reclaimed.
    .PARAMETER PrivateDirectory
        Private directory for the launch streams.
    .PARAMETER Deadline
        Bounds the launch and the readiness wait.
    .PARAMETER OnReady
        released or recovery-pending.
    .PARAMETER PrivateRoot
        An already-resolved private state root.
    .PARAMETER ProcessLookup
        Test seam for the launched runner's liveness during the wait.
    .OUTPUTS
        [pscustomobject] @{ Outcome ready|failed|timeout|identity-mismatch|
        launch-failed|refused|preview; Reason; Ack; OuterPid;
        OuterStartTimeUnixMs; PreservedControls; GateGeneration; GateState }.
        A runner that exits before acknowledging is launch-failed with
        reason runner-exited.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][psobject]$LaunchRecord,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$Attempt,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedGateGeneration,
        [Parameter(Mandatory)][hashtable]$Reclaimed,
        [Parameter(Mandatory)][string]$PrivateDirectory,
        [Parameter(Mandatory)][psobject]$Deadline,
        [ValidateSet('released', 'recovery-pending')][string]$OnReady = 'released',
        [string]$PrivateRoot,
        [scriptblock]$ProcessLookup
    )
    $out = [ordered]@{
        Outcome = $null; Reason = $null; Ack = $null; OuterPid = $null; OuterStartTimeUnixMs = $null
        PreservedControls = @(); GateGeneration = $ExpectedGateGeneration; GateState = 'unchanged'
    }
    $scriptPath = [System.IO.Path]::Combine($RepoRoot, 'test', 'Start-TestRunner.ps1')
    $payload = $LaunchRecord
    if ($LaunchRecord.PSObject.Properties['Valid'] -and $LaunchRecord.PSObject.Properties['Record']) {
        if (-not $LaunchRecord.Valid) { $out.Outcome = 'refused'; $out.Reason = "launch-record-$($LaunchRecord.Reason)"; return [pscustomobject]$out }
        $payload = $LaunchRecord.Record
    }
    $spec = Test-YurunaRunnerLaunchSpec -Record $payload -ScriptPath $scriptPath -RequireExistingConfig
    if (-not $spec.Valid) {
        $out.Outcome = 'refused'
        $out.Reason = if ($spec.Parameter) { "$($spec.Reason):$($spec.Parameter)" } else { $spec.Reason }
        return [pscustomobject]$out
    }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.refresh_resume_action'))) {
        $out.Outcome = 'preview'; $out.Reason = 'preview'
        return [pscustomobject]$out
    }
    if (-not (Get-Command Start-YurunaDetachedProcess -ErrorAction SilentlyContinue)) {
        $out.Outcome = 'refused'; $out.Reason = 'detached-launch-unavailable'
        return [pscustomobject]$out
    }
    $rootArgs = @{}
    if ($PrivateRoot) { $rootArgs.PrivateRoot = $PrivateRoot }
    $remaining = [long](Get-YurunaDeadlineRemainingMs -Deadline $Deadline)
    if ($remaining -lt 2000) { $out.Outcome = 'timeout'; $out.Reason = 'deadline-exhausted'; return [pscustomobject]$out }
    $token = New-YurunaRunnerHandoffToken -RequestId $RequestId -Attempt $Attempt -RuntimeDir $RuntimeDir -Purpose 'new-outer' `
        -ExpiresInMilliseconds $remaining -ExpectedGeneration $ExpectedGateGeneration -Reclaimed $Reclaimed -OnReady $OnReady -Confirm:$false @rootArgs
    if (-not $token.Issued) {
        $out.Outcome = 'refused'; $out.Reason = "handoff-$($token.Reason)"
        return [pscustomobject]$out
    }
    $out.GateGeneration = $token.Generation
    $out.GateState = 'handoff'
    $complete = {
        param([string]$Verdict)
        $done = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict $Verdict -ExpectedGeneration $token.Generation -Confirm:$false @rootArgs
        if ($done.Completed) { $out.GateGeneration = $done.Generation; $out.GateState = $done.State }
    }
    $environment = @{}
    $recordedEnvironment = if ($payload -is [System.Collections.IDictionary]) { $payload['environment'] } else { $payload.environment }
    if ($recordedEnvironment -is [System.Collections.IDictionary]) {
        foreach ($name in $recordedEnvironment.Keys) { $environment[[string]$name] = [string]$recordedEnvironment[$name] }
    }
    $workingDirectory = [string]$(if ($payload -is [System.Collections.IDictionary]) { $payload['workingDirectory'] } else { $payload.workingDirectory })
    if (-not $workingDirectory -or -not [System.IO.Directory]::Exists($workingDirectory)) { $workingDirectory = $RepoRoot }
    $null = Remove-YurunaStaleRunnerStream -Directory $PrivateDirectory -Confirm:$false
    $stdout = if ($IsWindows) { [System.IO.Path]::Combine($PrivateDirectory, "runner.$RequestId.out") } else { '/dev/null' }
    $launchDeadline = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds 10000
    # The Windows hop acknowledgment supplies the final PID and creation
    # time. Without it, a runner that exits before readiness is invisible
    # to the waiter's liveness check and consumes the whole repair budget.
    $hopWaitMs = if ($IsWindows) { 10000 } else { 0 }
    $launch = Start-YurunaDetachedProcess -FilePath $scriptPath -ArgumentList @(New-YurunaRunnerResumeArgumentList -Record $payload -TokenId $token.TokenId) `
        -WorkingDirectory $workingDirectory -Environment $environment -StdOutPath $stdout `
        -StdErrPath ([System.IO.Path]::Combine($PrivateDirectory, "runner.$RequestId.err")) `
        -PrivateDirectory $PrivateDirectory -WaitForHandshakeMilliseconds $hopWaitMs -Deadline $launchDeadline -Confirm:$false
    if (-not $launch.Launched) {
        & $complete 'recovery-pending'
        $out.Outcome = 'launch-failed'; $out.Reason = [string]$launch.Reason
        return [pscustomobject]$out
    }
    $waitArgs = @{ TokenId = $token.TokenId; Deadline = $Deadline }
    if ($PrivateRoot) { $waitArgs.PrivateRoot = $PrivateRoot }
    # A runner that dies before acknowledging (a refused start, a module
    # that fails to import) ends the wait at once instead of holding the
    # repair for the rest of its deadline.
    if ($launch.FinalPid) {
        $waitArgs.WatchProcess = [pscustomobject]@{ Pid = [int]$launch.FinalPid; StartTimeUnixMs = $launch.FinalStartTimeUnixMs }
        if ($ProcessLookup) { $waitArgs.ProcessLookup = $ProcessLookup }
    }
    $ready = Wait-YurunaRunnerReadiness @waitArgs
    $out.Ack = $ready.Ack
    if ($ready.Ack) {
        $out.PreservedControls = @($ready.Ack.preservedControls | Where-Object { $_ })
        if ($ready.Ack.outer) { $out.OuterPid = [int]$ready.Ack.outer.pid; $out.OuterStartTimeUnixMs = $ready.Ack.outer.startTimeUnixMs }
    }
    if ($ready.State -eq 'exited') {
        $out.Outcome = 'launch-failed'
        $out.Reason = [string]$ready.Reason
    } else {
        $out.Outcome = $ready.State
        $out.Reason = $ready.Reason
    }
    & $complete ($(if ($ready.State -eq 'ready') { 'released' } else { 'recovery-pending' }))
    return [pscustomobject]$out
}

Export-ModuleMember -Function `
    Get-RunnerInstanceState, Stop-StaleRunner, Write-RunnerPidFile, Stop-YurunaProcessTree, `
    Resolve-YurunaRunnerProcessTarget, Get-YurunaProcessTable, Get-YurunaProcessIdentityState, `
    Get-YurunaProcessStartUnixMs, Get-YurunaRunnerRecordState, Remove-YurunaRunnerRecordGeneration, `
    Write-YurunaProcessStartRecord, Read-YurunaRunnerCycleRecord, Write-YurunaRunnerCycleRecord, `
    Clear-YurunaRunnerCycleRecord, Get-YurunaRunnerExclusionSet, Get-YurunaRunnerSnapshot, `
    New-YurunaRunnerReclaimPlan, Compare-YurunaRunnerReclaimPlan, Stop-YurunaRunnerProcessTarget, `
    Get-YurunaRuntimeKey, Get-YurunaRefreshGateState, Test-YurunaRefreshSpawnAllowed, Set-YurunaRefreshGate, `
    New-YurunaRunnerHandoffToken, Test-YurunaRunnerHandoffToken, Get-YurunaRunnerChainIdentity, `
    Write-YurunaRunnerReadinessAck, Wait-YurunaRunnerReadiness, Complete-YurunaRunnerHandoff, Complete-YurunaRunnerExpiredHandoff, `
    Write-YurunaRunnerLaunchRecord, Complete-YurunaRunnerLaunchRecord, Read-YurunaRunnerLaunchRecord, `
    Test-YurunaRunnerLaunchSpec, New-YurunaRunnerResumeArgumentList, Get-YurunaRunnerProtocolCapability, `
    Invoke-YurunaRunnerRefreshResume
