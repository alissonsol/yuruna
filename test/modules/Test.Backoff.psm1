<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42f3e8d7-c6b5-4a32-9087-1d2e3f4a5b67
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna backoff retry poll
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
    Shared exponential-backoff helpers for filesystem-state poll loops.

.DESCRIPTION
    Centralizes the poll-delay math used by Invoke-Sequence (step-pause,
    break-wait), Invoke-TestInnerRunner (cycle-pause), and
    Test.SequenceHandler (break-wait inside the break handler). The
    function was previously duplicated verbatim across these three
    files; a tuning change had to land in all three to take effect.

    The jitter (uniform [0, 100) ms) breaks lock-step at the call site
    -- many runners on shared storage polling at synchronised 1 Hz can
    produce a thundering herd that pegs the filesystem; the spread
    keeps polling cost amortised across the pool.
#>

function Get-PollDelay {
    <#
    .SYNOPSIS
        Returns the next poll delay in milliseconds for an exponential-
        backoff filesystem poll loop.

    .DESCRIPTION
        Formula: base = min(59, 2^(n-1)) seconds + uniform [0, 100) ms
        jitter, where n is the 1-indexed attempt number. Caps at 59 s
        so a long-paused cycle still wakes up frequently enough to see
        an operator's resume signal within a minute.

    .PARAMETER Attempt
        1-indexed attempt count. Caller increments after each call.

    .OUTPUTS
        [int] Delay in milliseconds, ready to pass to Start-Sleep -Milliseconds.
    #>
    [OutputType([int])]
    param([int]$Attempt = 1)
    # Cap the exponent so 2^exp never exceeds Int32.MaxValue. Cast to
    # [int] must happen AFTER the Min(59, ...) cap, otherwise a long-
    # running pause whose Attempt counter crosses 32 overflows Int32 at
    # the cast and emits "Cannot convert value '2147483648' to type
    # 'System.Int32'" once per poll iteration.
    $exp    = [Math]::Max(0, $Attempt - 1)
    if ($exp -gt 30) { $exp = 30 }
    $base   = [int][Math]::Min(59, [Math]::Pow(2, $exp))
    if ($base -lt 1) { $base = 1 }
    $jitter = Get-Random -Minimum 0 -Maximum 101
    return ($base * 1000) + $jitter
}

Export-ModuleMember -Function Get-PollDelay
