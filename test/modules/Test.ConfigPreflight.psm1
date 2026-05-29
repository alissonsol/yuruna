<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456723
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

# Test.Config* role pyramid:
#   * Test.Config            — mtime-cached YAML reader (the data layer).
#   * Test.ConfigValidator   — schema + freshness primitives (the rules
#                              layer). Reusable across callers.
#   * Test.ConfigPreflight   — pre-cycle gate that spawns Test-Config.ps1
#                              and refuses the cycle on FAIL items
#                              (this file; the policy layer).
# Rename rationale: the previous name "Test.ConfigGate" hid the role.
# "Preflight" names the *when* (before each cycle) instead of the
# *mechanism* (a gate). The split by role keeps the validation
# primitives reusable while the cycle-spawning policy lives here.

# Pre-cycle config gate: spawn Test-Config.ps1 in a fresh pwsh so an
# Out-Of-Order ::Stop / early exit inside Test-Config can't unwind the
# caller's eternal loop. -SkipSend is mandatory in this gating context:
# the notification path inside Test-Config is a smoke test, and
# delivering an email on every outer relaunch / dev iteration would
# flood the subscribers["config.smoke"] list.
#
# The two call sites (Invoke-TestRunner outer-startup, Test-Sequence dev
# helper, and soon Test-Project too) were copy-paste-equivalent before
# this module; future fixes (e.g. a new gate parameter) now reach all
# callers from one place.

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
    .PARAMETER CallerName
        Short label used in the banner so the operator sees which entry
        point owned the gate failure ('Invoke-TestRunner', 'Test-Sequence',
        'Test-Project').
    .OUTPUTS
        @{ passed = [bool]; exitCode = [int]; skipped = [bool] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Skip,
        [string]$CallerName = 'Test'
    )
    $gateScript = Join-Path $TestRoot 'Test-Config.ps1'
    if (-not (Test-Path -LiteralPath $gateScript)) {
        Write-Warning "[$CallerName] Pre-cycle config gate skipped: $gateScript not found."
        return @{ passed = $true; exitCode = 0; skipped = $true }
    }
    if ($Skip) {
        Write-Information "[$CallerName] Pre-cycle config gate SKIPPED (-NoConfigGate)." -InformationAction Continue
        return @{ passed = $true; exitCode = 0; skipped = $true }
    }
    # Hidden-mode invocation: Test-Config's ~80-line transcript is
    # captured silently and ONLY surfaces if the gate fails (the failures
    # block is re-emitted under the gate-failed banner below). On a green
    # gate the caller sees nothing from this helper -- matches every
    # other pre-flight check in the harness (silent when healthy).
    # The captured stream still includes 2>&1 so child stderr lands in
    # the same list and the FAILURES-block extractor sees the full
    # transcript regardless of which stream Test-Config used.
    $pwshExe = (Get-Process -Id $PID).Path
    $capturedLines = [System.Collections.Generic.List[string]]::new()
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $gateScript -SkipSend -ConfigPath $ConfigPath 2>&1 |
        ForEach-Object { [void]$capturedLines.Add("$_") }
    $gateExit = $LASTEXITCODE
    if ($gateExit -ne 0) {
        # Pull the FAILURES block (the section between the "FAILURES (N) --"
        # header and the matching "END OF FAILURES (N)" footer, including
        # the === banner lines around them) so we can repeat it under the
        # gate-failed banner. Test.Output's Write-Summary already includes
        # per-section WARN messages there, so this single excerpt carries
        # the full reason chain (FAIL + the warnings it pointed at).
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
        Write-Warning "============================================================"
        Write-Warning "  [$CallerName] Pre-cycle config gate FAILED (Test-Config.ps1 exit $gateExit)."
        Write-Warning "============================================================"
        if ($startIdx -ge 0) {
            # If the closing footer was missed (truncated output, child
            # crash mid-print), surface from the header to the end of
            # capture rather than swallowing the partial block.
            $blockEnd = if ($endIdx -gt $startIdx) { $endIdx } else { $capturedLines.Count - 1 }
            Write-Information "" -InformationAction Continue
            for ($i = $startIdx; $i -le $blockEnd; $i++) {
                Write-Information $capturedLines[$i] -InformationAction Continue
            }
        } else {
            # Test-Config exited non-zero without producing a FAILURES
            # block (e.g. a crash before Exit-WithSummary). Surface the
            # last few captured lines so the operator has a starting
            # point instead of an opaque "gate failed".
            $tail = $capturedLines | Select-Object -Last 20
            if ($tail.Count -gt 0) {
                Write-Information "" -InformationAction Continue
                Write-Information "Test-Config did not emit a FAILURES block. Last $($tail.Count) lines of its output:" -InformationAction Continue
                foreach ($t in $tail) { Write-Information $t -InformationAction Continue }
            }
        }
        Write-Warning ""
        Write-Warning "============================================================"
        Write-Warning "  Bypass for ad-hoc / in-progress edits: -NoConfigGate on the entry point."
        Write-Warning "  Re-validate directly:                  pwsh test/Test-Config.ps1"
        Write-Warning "============================================================"
        return @{ passed = $false; exitCode = $gateExit; skipped = $false }
    }
    # Silent on success -- the cycle/sequence flow that follows is the
    # operator's signal that the gate cleared. A "gate PASSED" line here
    # would just be noise stacked above the rest of the entry-point banner.
    return @{ passed = $true; exitCode = 0; skipped = $false }
}

Export-ModuleMember -Function Invoke-ConfigGate
