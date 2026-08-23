<#PSScriptInfo
.VERSION 2026.08.23
.GUID 426aeda1-aa39-4af4-ab2d-2e9d00f2ca45
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# --- REGION: https://yuruna.link/test/harness#testconfig-role-pyramid

# Pre-cycle config gate: spawn Test-Config.ps1 in a fresh pwsh so an
# Out-Of-Order ::Stop / early exit inside Test-Config can't unwind the
# caller's eternal loop. -SkipSend is mandatory in this gating context:
# the notification path inside Test-Config is a smoke test, and
# delivering an email on every outer relaunch / dev iteration would
# flood the subscribers["config.smoke"] list.
#
# Centralizing the gate here keeps Start-TestRunner outer-startup,
# Debug-TestSequence, and Invoke-TestProject agreeing on the same gate semantics --
# a new gate parameter reaches every caller from one place instead of
# drifting between near-identical copy-pastes.

function Invoke-ConfigGate {
    <#
    .SYNOPSIS
        Run Test-Config.ps1 as a pre-cycle gate. Returns a hashtable
        with `passed` and `exitCode`. Caller decides whether to bail.
    .PARAMETER TestRoot
        Directory containing Test-Config.ps1.
    .PARAMETER ConfigPath
        Path to test.config.yml to validate.
    .PARAMETER Skip
        If true, return passed=$true without running anything (caller
        passed -NoConfigGate or similar bypass).
    .PARAMETER SkipReason
        What to name as the bypass in the SKIPPED line, so a reader can tell an
        operator's deliberate -NoConfigGate from a structural bypass such as a
        nested run inheriting its owner's verdict. Ignored unless -Skip.
    .PARAMETER CallerName
        Short label used in the banner so the operator sees which entry
        point owned the gate failure ('Start-TestRunner', 'Debug-TestSequence',
        'Invoke-TestProject').
    .PARAMETER ExpectStorageConfigured
        Tells the gate that shared storage was supposed to have been configured
        before it ran, so an unconfigured networkStorage pool tier is a FAILURE
        rather than the "no NAS here, that is fine" it means to an operator who
        never asked for one. Only a caller that just tried to configure storage
        knows this, so it is passed in rather than inferred.
    .OUTPUTS
        @{ passed = [bool]; exitCode = [int]; skipped = [bool]; lines = [string[]]
           failureLines = [string[]] }

        `failureLines` is the FAILURES excerpt this function also writes to the
        console, empty on every passing or skipped path. It is returned as well
        as written because the console write goes out on the INFORMATION stream,
        and a caller that redirects stream 6 -- as a runner that files each
        step's narration into a log rather than onto the screen -- silently takes
        this with it. Such a caller re-emits these lines on a stream it keeps, so
        the operator still learns WHY the gate refused; without the field it
        would have to re-parse the transcript to find out.

        `lines` is the child's full transcript, on every path INCLUDING success.
        This is the one step whose whole job is to describe the machine, and a
        green verdict is not the same as nothing to say: the WARN lines naming an
        unreachable server, a missing vault credential or a skipped active
        pre-flight are exactly what a reader needs when the next step fails. A
        caller that wants a silent green simply ignores the field; one that keeps
        a run log should file it there.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Skip,
        [string]$SkipReason = '-NoConfigGate',
        [string]$CallerName = 'Test',
        [switch]$ExpectStorageConfigured
    )
    # Created before the first return so every exit path carries the same shape.
    # A key that exists on some returns and not others is a null dereference
    # waiting for the day someone puts Set-StrictMode on a caller.
    $capturedLines = [System.Collections.Generic.List[string]]::new()
    $gateScript = Join-Path $TestRoot 'Test-Config.ps1'
    if (-not (Test-Path -LiteralPath $gateScript)) {
        Write-Warning "[$CallerName] Pre-cycle config gate skipped: $gateScript not found."
        return @{ passed = $true; exitCode = 0; skipped = $true; lines = $capturedLines.ToArray(); failureLines = @() }
    }
    if ($Skip) {
        Write-Information "[$CallerName] Pre-cycle config gate SKIPPED ($SkipReason)." -InformationAction Continue
        return @{ passed = $true; exitCode = 0; skipped = $true; lines = $capturedLines.ToArray(); failureLines = @() }
    }
    # Hidden-mode invocation: Test-Config's ~80-line transcript is captured
    # silently and reaches the CONSOLE only when the gate fails (the failures
    # block is re-emitted under the gate-failed banner below), so a green gate
    # shows the operator nothing -- matching every other pre-flight check in the
    # harness. It is returned to the caller either way; see .OUTPUTS.
    # The capture includes 2>&1 so child stderr joins the same list and the
    # FAILURES-block extractor sees the full transcript whichever stream
    # Test-Config wrote to.
    # Resolve the running pwsh via the shared, macOS-hardened resolver: a
    # bare (Get-Process -Id $PID).Path is null on macOS (no /proc) and a
    # null child-pwsh path makes the spawn below throw. The Sequence entry
    # point loads this gate WITHOUT Test.InnerSpawn, so import it on demand;
    # -Global avoids the nested-import global-eviction class
    # (feedback_module_force_import_evicts_global.md). The call is module-
    # qualified because the Windows host module exports a same-named
    # Get-PwshExePath with different semantics.
    if (-not (Get-Module -Name 'Test.InnerSpawn')) {
        Import-Module (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1') -Global -Force -DisableNameChecking -Verbose:$false
    }
    $pwshExe = Test.InnerSpawn\Get-PwshExePath
    # Only appended when asked for: the argument vector is a contract with
    # Test-Config.ps1, and an unconditional flag would also have to be understood
    # by every stand-in gate script a test substitutes for it.
    $gateArgument = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $gateScript,
                      '-SkipSend', '-ConfigPath', $ConfigPath)
    if ($ExpectStorageConfigured) { $gateArgument += '-ExpectStorageConfigured' }
    # --- REGION: https://yuruna.link/memory#why-the-preflight-gate-child-gets-empty-pipeline-stdin-plus--noninteractive
    @() | & $pwshExe @gateArgument 2>&1 |
        ForEach-Object { [void]$capturedLines.Add("$_") }
    $gateExit = $LASTEXITCODE
    if ($gateExit -ne 0) {
        # Pull the FAILURES block (the section between the "FAILURES (N) --"
        # header and the matching "END OF FAILURES (N)" footer, including
        # the === banner lines around them) so we can repeat it under the
        # gate-failed banner. Test.Output's Write-Summary already includes
        # per-section WARN messages there, so this single excerpt carries
        # the full reason chain (FAIL + the warnings it pointed at).
        # Collected as it is written so what the caller gets back and what the
        # console showed cannot drift apart.
        $failureLines = [System.Collections.Generic.List[string]]::new()
        $startIdx = -1
        $endIdx = -1
        for ($i = 0; $i -lt $capturedLines.Count; $i++) {
            if ($startIdx -lt 0 -and $capturedLines[$i] -match 'FAILURES \(\d+\) -- ') {
                $startIdx = if ($i -gt 0 -and $capturedLines[$i-1] -match '^={5,}$') { $i - 1 } else { $i }
            }
            if ($capturedLines[$i] -match 'END OF FAILURES \(\d+\)') {
                $endIdx = if (($i + 1) -lt $capturedLines.Count -and $capturedLines[$i+1] -match '^={5,}$') { $i + 1 } else { $i }
                break
            }
        }
        Write-Warning ""
        Write-Warning "========"
        Write-Warning "  [$CallerName] Pre-cycle config gate FAILED (Test-Config.ps1 exit $gateExit)."
        Write-Warning "========"
        if ($startIdx -ge 0) {
            # If the closing footer was missed (truncated output, child
            # crash mid-print), surface from the header to the end of
            # capture rather than swallowing the partial block.
            $blockEnd = if ($endIdx -gt $startIdx) { $endIdx } else { $capturedLines.Count - 1 }
            Write-Information "" -InformationAction Continue
            for ($i = $startIdx; $i -le $blockEnd; $i++) {
                Write-Information $capturedLines[$i] -InformationAction Continue
                [void]$failureLines.Add($capturedLines[$i])
            }
        } else {
            # Test-Config exited non-zero without producing a FAILURES
            # block (e.g. a crash before Exit-WithSummary). Surface the
            # last few captured lines so the operator has a starting
            # point instead of an opaque "gate failed".
            $tail = $capturedLines | Select-Object -Last 20
            if ($tail.Count -gt 0) {
                Write-Information "" -InformationAction Continue
                $tailHeader = "Test-Config did not emit a FAILURES block. Last $($tail.Count) lines of its output:"
                Write-Information $tailHeader -InformationAction Continue
                [void]$failureLines.Add($tailHeader)
                foreach ($t in $tail) {
                    Write-Information $t -InformationAction Continue
                    [void]$failureLines.Add($t)
                }
            }
        }
        Write-Warning ""
        Write-Warning "========"
        Write-Warning "  Bypass for ad-hoc / in-progress edits: -NoConfigGate on the entry point."
        Write-Warning "  Re-validate directly:                  pwsh test/Test-Config.ps1"
        Write-Warning "========"
        return @{ passed = $false; exitCode = $gateExit; skipped = $false; lines = $capturedLines.ToArray(); failureLines = $failureLines.ToArray() }
    }
    # Silent on success -- the cycle/sequence flow that follows is the
    # operator's signal that the gate cleared. A "gate PASSED" line here
    # would just be noise stacked above the rest of the entry-point banner.
    # The transcript still goes back to the caller, which can file it somewhere
    # a reader will find it later without spending a line of console now.
    return @{ passed = $true; exitCode = 0; skipped = $false; lines = $capturedLines.ToArray(); failureLines = @() }
}

Export-ModuleMember -Function Invoke-ConfigGate
