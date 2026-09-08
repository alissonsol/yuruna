<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42c69a51-1c69-4dba-ad62-2dda7b368e9c
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

# Reusable PASS / FAIL / WARN reporter for check-style scripts. Lets
# check scripts (Test-Config, Test-CachingProxyService, future health-checks)
# share the same operator-facing format without copy-pasting the
# counters and Write-Summary banner.
#
# One of THREE Yuruna logger modules with disjoint responsibilities --
# see test/modules/README.md "Three loggers, three jobs" before adding
# helpers here. This module owns ONLY the per-script PASS/FAIL tally +
# Write-Summary banner + Exit-WithSummary helper. Sibling modules:
# Yuruna.Log (stream interceptor) and Test.Log (cycle-filesystem owner).
# Don't add Start-* cycle helpers or cmdlet-wrappers here -- they belong
# in the other two.
#
# Eviction-safe counters: $global:YurunaOutputState anchors the live
# state so Test-Config's helpers and any module that imports this one
# (e.g. Test.ConfigValidator) share the same PASS/FAIL/WARN tally
# regardless of -Force re-imports. See repo-memory
# feedback_module_force_import_evicts_global.md.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; PASS/FAIL/WARN counts must survive -Force re-imports of either Test.Output or its callers (Test.ConfigValidator).')]
param()

if (-not $global:YurunaOutputState) {
    $global:YurunaOutputState = [ordered]@{
        PassCount         = 0
        FailCount         = 0
        WarnCount         = 0
        CurrentSection    = ''
        Failures          = New-Object System.Collections.Generic.List[pscustomobject]
        WarningsBySection = [ordered]@{}
    }
}
# A long-lived shell can hold a $global:YurunaOutputState created by a
# previous import that didn't carry WarningsBySection; backfill the key
# so downstream readers don't NRE on first access.
if (-not $global:YurunaOutputState.Contains('WarningsBySection')) {
    $global:YurunaOutputState['WarningsBySection'] = [ordered]@{}
}
$script:State = $global:YurunaOutputState

function Reset-OutputState {
    <#
    .SYNOPSIS
        Zero the PASS/WARN/FAIL counters and drop the recorded failures.
        Used by tests; production code calls Initialize-OutputState (which
        also zeros) at script entry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('Test.Output counters', 'Reset to zero')) { return }
    $script:State.PassCount = 0
    $script:State.FailCount = 0
    $script:State.WarnCount = 0
    $script:State.CurrentSection = ''
    $script:State.Failures = New-Object System.Collections.Generic.List[pscustomobject]
    $script:State.WarningsBySection = [ordered]@{}
}

function Initialize-OutputState {
    <#
    .SYNOPSIS
        Reset and bind the writer state. Idempotent. Production entry
        point at the top of each check script.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Resets a process-local counter; no externally observable state change.')]
    param()
    Reset-OutputState -Confirm:$false
}

function Get-OutputState {
    <#
    .SYNOPSIS
        Snapshot of the current counters. Read-only; the returned
        IDictionary is a copy so a caller mutating it does not corrupt
        the live state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # WarningsBySection is an [ordered] of section -> List[string]. Returning the
    # live reference would let a caller that mutates the snapshot (adds a section,
    # or .Add()s to a section's list) corrupt the live counter state. Rebuild a
    # fresh ordered dictionary whose values are copied lists so the snapshot is
    # fully isolated -- the copy-safety contract already honored for Failures via
    # @(...).
    $warningsCopy = [ordered]@{}
    foreach ($sectionKey in $script:State.WarningsBySection.Keys) {
        $warningsCopy[$sectionKey] = [System.Collections.Generic.List[string]]::new(
            [System.Collections.Generic.IEnumerable[string]]$script:State.WarningsBySection[$sectionKey])
    }
    return @{
        PassCount         = $script:State.PassCount
        FailCount         = $script:State.FailCount
        WarnCount         = $script:State.WarnCount
        CurrentSection    = $script:State.CurrentSection
        Failures          = @($script:State.Failures)
        WarningsBySection = $warningsCopy
    }
}

function Write-Pass {
    <#
    .SYNOPSIS
        Emit a PASS line and bump the pass counter.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Output "  [PASS] $Message"
    $script:State.PassCount++
}

function Write-Fail {
    <#
    .SYNOPSIS
        Emit a FAIL line, bump the counter, and record the failure under
        the current section. -FullPath is surfaced verbatim in
        Write-Summary's end-of-run failures block so the operator can
        copy-paste the absolute location of the failing file without
        having to re-derive it from the message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$FullPath
    )
    Write-Output "  [FAIL] $Message"
    $script:State.FailCount++
    $script:State.Failures.Add([pscustomobject]@{
        Section  = $script:State.CurrentSection
        Message  = $Message
        FullPath = $FullPath
    })
}

function Write-Warn {
    <#
    .SYNOPSIS
        Emit a WARN line, bump the warn counter, and record the message
        under the current section so Write-Summary's FAILURES block can
        repeat the section's warnings alongside each FAIL entry. Operators
        otherwise had to scroll up to find the warnings a FAIL like
        "see warnings above" was pointing at.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Output "  [WARN] $Message"
    $script:State.WarnCount++
    $section = $script:State.CurrentSection
    if ($section) {
        if (-not $script:State.WarningsBySection.Contains($section)) {
            $script:State.WarningsBySection[$section] = New-Object System.Collections.Generic.List[string]
        }
        $script:State.WarningsBySection[$section].Add($Message)
    }
}

function Write-Info {
    <#
    .SYNOPSIS
        Emit a contextual info line (no counter bump).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Output "        $Message"
}

function Write-Section {
    <#
    .SYNOPSIS
        Mark the start of a section. The label is threaded into every
        subsequent Failure row so the end-of-run block can group them.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Stores the current section label and writes a header line; no externally observable state change.')]
    param([Parameter(Mandatory)][string]$Message)
    $script:State.CurrentSection = $Message
    Write-Output "`n=== $Message ==="
}

function Write-FailureSidecar {
    <#
    .SYNOPSIS
        Write the failures as data, for a parent process that has to act on
        them rather than only show them.
    .DESCRIPTION
        The block below is written for a person. A parent process used to
        recover it by matching the English words in its header and footer,
        which made a sentence a wire format: rewording it -- or running on a
        host that rendered it in another language -- would silently produce a
        parent that found no failures in a child that failed.

        The path arrives in an environment variable rather than a parameter so
        that a caller which does not set it, and every stand-in gate script the
        tests substitute for this one, keep working untouched.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only the file the caller explicitly named in the environment.')]
    [CmdletBinding()]
    param()

    $path = $env:YURUNA_FAILURE_SIDECAR
    if (-not $path) { return }

    $payload = [ordered]@{
        schema    = 'yuruna.preflight-failures/v1'
        failCount = [int]$script:State.FailCount
        warnCount = [int]$script:State.WarnCount
        failures  = @(foreach ($f in $script:State.Failures) {
                [ordered]@{
                    section  = [string]$f.Section
                    message  = [string]$f.Message
                    fullPath = [string]$f.FullPath
                    warnings = @(
                        if ($f.Section -and $script:State.WarningsBySection.Contains($f.Section)) {
                            $script:State.WarningsBySection[$f.Section] | ForEach-Object { [string]$_ }
                        })
                }
            })
    }
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 6),
            [Text.UTF8Encoding]::new($false))
    } catch {
        # The sidecar is a convenience for the parent, not the verdict. A run
        # that could not write it still reports through its exit code and its
        # printed summary, and failing here would turn a reporting problem into
        # a gate failure.
        Write-Verbose "Could not write the failure sidecar to '$path': $($_.Exception.Message)"
    }
}

function Write-Summary {
    <#
    .SYNOPSIS
        End-of-run banner. Always prints the PASS/WARN/FAIL tally; then a
        numbered WARNINGS block (every WARN, grouped by section) when WARN > 0,
        and a numbered FAILURES block (section + message + optional FullPath)
        when FAIL > 0 -- so the operator never has to scroll back through the
        log to find every WARN and FAIL sign.
    #>
    [CmdletBinding()]
    param()
    Write-Output ""
    Write-Output "-----------------------------------------"
    Write-Output ("  PASS: {0,3}   WARN: {1,3}   FAIL: {2,3}" -f $script:State.PassCount, $script:State.WarnCount, $script:State.FailCount)
    Write-Output "-----------------------------------------"
    if ($script:State.WarnCount -gt 0) {
        # Reprint every WARN (grouped by section, in section order) so the
        # operator sees the full advisory list at the end without scrolling the
        # log. WarningsBySection captures every Write-Warn issued inside a
        # section, which is the normal path.
        $allWarns = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($sectionKey in $script:State.WarningsBySection.Keys) {
            foreach ($w in $script:State.WarningsBySection[$sectionKey]) {
                $allWarns.Add([pscustomobject]@{ Section = $sectionKey; Message = $w })
            }
        }
        if ($allWarns.Count -gt 0) {
            Write-Output ""
            Write-Output "========"
            Write-Output "  WARNINGS ($($allWarns.Count)) -- advisory; the cycle can still start:"
            Write-Output "========"
            $wi = 0
            foreach ($wentry in $allWarns) {
                $wi++
                Write-Output ""
                Write-Output ("  [{0}/{1}] in section: {2}" -f $wi, $allWarns.Count, $wentry.Section)
                Write-Output ("        {0}" -f $wentry.Message)
            }
            Write-Output ""
            Write-Output "========"
            Write-Output "  END OF WARNINGS ($($allWarns.Count))"
            Write-Output "========"
        }
    }
    Write-FailureSidecar

    if ($script:State.FailCount -gt 0) {
        Write-Output ""
        Write-Output "========"
        Write-Output "  FAILURES ($($script:State.FailCount)) -- the cycle gate refuses to start until these are resolved:"
        Write-Output "========"
        $i = 0
        foreach ($f in $script:State.Failures) {
            $i++
            Write-Output ""
            Write-Output ("  [{0}/{1}] in section: {2}" -f $i, $script:State.FailCount, $f.Section)
            Write-Output ("        {0}" -f $f.Message)
            if ($f.FullPath) {
                Write-Output ("        File: {0}" -f $f.FullPath)
            }
            if ($f.Section -and $script:State.WarningsBySection.Contains($f.Section)) {
                $sectionWarns = $script:State.WarningsBySection[$f.Section]
                if ($sectionWarns.Count -gt 0) {
                    Write-Output ("        Warnings in this section ({0}):" -f $sectionWarns.Count)
                    foreach ($w in $sectionWarns) {
                        Write-Output ("          [WARN] {0}" -f $w)
                    }
                }
            }
        }
        Write-Output ""
        Write-Output "========"
        Write-Output "  END OF FAILURES ($($script:State.FailCount))"
        Write-Output "========"
    }
}

function Exit-WithSummary {
    <#
    .SYNOPSIS
        Print Write-Summary then exit with the requested code. Centralized
        so every termination path -- including the early exits for missing
        config / YAML parse error / abort-before-network-checks -- always
        ends with the same banner.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Pure exit helper; behavior is identical to PowerShell exit, plus a banner.')]
    param([Parameter(Mandatory, Position=0)][int]$Code)
    Write-Summary
    exit $Code
}

Export-ModuleMember -Function Write-FailureSidecar, Reset-OutputState, Initialize-OutputState, Get-OutputState, Write-Pass, Write-Fail, Write-Warn, Write-Info, Write-Section, Write-Summary, Exit-WithSummary
