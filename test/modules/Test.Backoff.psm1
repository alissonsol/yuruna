<#PSScriptInfo
.VERSION 2026.07.10
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
    Test.SequenceHandler (break-wait inside the break handler). One
    definition here means a tuning change lands once for all three call
    sites instead of having to be kept in sync across copies.

    The jitter (uniform, up to 25% of the current delay, subtracted) breaks
    lock-step at the call site -- many runners on shared storage polling in
    synchronised lock-step can produce a thundering herd that pegs the
    filesystem; scaling the spread to the interval keeps polling cost
    amortised across the pool even at the 59 s cap, where a fixed [0,100) ms
    jitter was ~0.17% of the delay and barely decorrelated anything.
#>

function Get-PollDelay {
    <#
    .SYNOPSIS
        Returns the next poll delay in milliseconds for an exponential-
        backoff filesystem poll loop.

    .DESCRIPTION
        Formula: base = min(59, 2^(n-1)) seconds, minus uniform jitter of
        up to 25% of base, where n is the 1-indexed attempt number. The
        jitter is subtracted so the delay stays within base seconds; the
        59 s cap therefore still wakes a long-paused cycle within a minute
        to see an operator's resume signal, while the spread scales with
        the interval to decorrelate the pool.

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
    # De-sync jitter proportional to the current delay (up to 25% of base*1000
    # ms; base*250 == 25% of base*1000). SUBTRACT it so the delay stays in
    # [base*750, base*1000] ms -- the poll still fires within `base` seconds,
    # preserving the 59 s cap's wake-within-a-minute guarantee, while the spread
    # scales with the interval (a fixed [0,100) ms jitter is negligible once
    # base reaches the cap).
    $jitter = Get-Random -Minimum 0 -Maximum (($base * 250) + 1)
    return ($base * 1000) - $jitter
}

Export-ModuleMember -Function Get-PollDelay
