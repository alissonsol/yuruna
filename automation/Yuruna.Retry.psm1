<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e3a5b6-c7d8-4901-2345-6e7f80910218
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Retry
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
    PowerShell counterpart of automation/yuruna-retry.sh.

.DESCRIPTION
    Mirrors the bash _yuruna_retry contract for PowerShell callers so
    on-host code (Set-Resource tofu init, host-side curl probes, ...)
    shares one retry policy with the guest-side scripts.

    Policy: capped exponential backoff with optional jitter. Defaults
    line up with yuruna-retry.sh (max_attempts=5, delay=10s, *= 2 per
    attempt), with two additions that the bash side does not need:
      * MaxDelaySeconds caps each backoff (default 300s).
      * JitterFraction +/- randomizes each backoff (default 0.25) so a
        burst of parallel callers does not lock-step their retries onto
        the same failure window.

    Defaults can be overridden per call OR via the same env vars the
    bash side honors (YURUNA_RETRY_MAX_ATTEMPTS, YURUNA_RETRY_DELAY),
    so an operator can tune both halves of the system from one place.
    Parity covers those two vars only: the bash side's per-attempt
    stall bound and heal hook (YURUNA_RETRY_STALL_TIMEOUT,
    YURUNA_*_STALL_TIMEOUT, YURUNA_RETRY_HEAL) are guest-side knobs
    built on timeout(1) with no counterpart here.

    Callers that should retry only a subset of failures pass a
    -ShouldRetry predicate. It receives a hashtable
    (@{ Attempt; MaxAttempts; ExitCode; Output; Error }) and returns
    $true to keep retrying or $false to fail fast. Omitting it retries
    on any non-zero exit (the tofu-init contract).
#>

$script:RetryDefaults = @{
    MaxAttempts         = 5
    InitialDelaySeconds = 10
    MaxDelaySeconds     = 300
    JitterFraction      = 0.25
}

# Shared transient-failure classifier: the single source of truth for "is
# this failure worth retrying?" across every network-touching phase.
# What each token covers, why a bare 500 is in the list, and the per-phase
# gating: docs/architecture.md#shared-transient-failure-retry-policy
#
# The codes are matched with word boundaries (\b429\b ... \b504\b) so "HTTP 500"
# matches wherever the code stands alone (mid-line or end-of-line) while "1500"/
# "2500" and other embedded digits do not; the boundaries allow any surrounding
# context (HTTP/status/bare). EOF is likewise a bounded token (\bEOF\b) so a
# standalone transient read -- "unexpected EOF", ": EOF while reading", a
# trailing ": EOF" -- matches, while EOF embedded in an unrelated token (EOFError
# in a stack trace, an EOF-prefixed identifier) does not.
$script:TransientFailurePattern = '(?i)(failed to fetch|i/o timeout|no such host|connection refused|connection reset|client\.timeout|\bEOF\b|TLS handshake|temporary failure|\b(?:429|500|502|503|504)\b|too many requests|error acquiring the state lock|ConditionalCheckFailedException)'

<#
.SYNOPSIS
    Returns a positive integer from the named environment variable, or the
    supplied fallback when the variable is unset or not a positive integer.
#>
function Get-YurunaRetryDefault {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][int]$Fallback
    )
    $raw = [System.Environment]::GetEnvironmentVariable($EnvName)
    if ($raw) {
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    }
    return $Fallback
}

<#
.SYNOPSIS
    Returns the shared transient-failure regex string for callers that match
    output inline instead of calling Test-YurunaTransientFailure.
#>
function Get-YurunaTransientPattern {
    # The regex string, for callers that match inline (e.g. a closure that
    # must run detached in the retry module's scope) rather than calling
    # Test-YurunaTransientFailure.
    [OutputType([string])]
    param()
    return $script:TransientFailurePattern
}

<#
.SYNOPSIS
    Returns $true when the given command output (string or array of lines)
    matches the shared transient-failure pattern and is worth retrying.
#>
function Test-YurunaTransientFailure {
    # $true when command output looks like a transient failure worth
    # retrying. Accepts a string or an array of output lines/records.
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$Output)
    if ($null -eq $Output) { return $false }
    $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
    return ($text -match $script:TransientFailurePattern)
}

# Structured retry telemetry (best-effort). Emits a machine-readable
# retry_attempt / retry_exhausted NDJSON record when this host-side retry runs
# inside a process that also loaded Test.Log; a no-op otherwise (Send-Cycle-
# EventSafely is Get-Command-guarded), so the standalone tofu-init / on-host
# probe paths that don't import Test.Log are unaffected. Private (not exported).
function Send-YurunaRetryEvent {
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$Label,
        [int]$Attempt,
        [int]$MaxAttempts,
        [int]$ExitCode,
        [AllowNull()][Nullable[bool]]$Transient,
        [AllowNull()][Nullable[int]]$SleepSeconds,
        [AllowNull()][Nullable[bool]]$Permanent
    )
    if (-not (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue)) { return }
    $rec = @{
        timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        event       = $EventName
        stack       = 'pwsh'
        description = [string]$Label
        attempt     = [int]$Attempt
        maxAttempts = [int]$MaxAttempts
        exitCode    = [int]$ExitCode
    }
    if ($null -ne $Transient)    { $rec['transient']    = [bool]$Transient }
    if ($null -ne $SleepSeconds) { $rec['sleepSeconds'] = [int]$SleepSeconds }
    if ($null -ne $Permanent)    { $rec['permanent']    = [bool]$Permanent }
    Send-CycleEventSafely -EventRecord $rec
}

<#
.SYNOPSIS
    Runs a scriptblock under capped exponential backoff with optional jitter,
    retrying on non-zero exit (or per the -ShouldRetry predicate) and returning
    a result object describing the outcome.
#>
function Invoke-WithYurunaRetry {
    [OutputType([pscustomobject])]
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts         = 0,
        [int]$InitialDelaySeconds = 0,
        [int]$MaxDelaySeconds     = 0,
        [double]$JitterFraction   = -1,
        [string]$LogPath,
        [string]$RcFile,
        [scriptblock]$OnAttempt,
        [scriptblock]$OnRetry,
        [scriptblock]$ShouldRetry
    )

    if ($MaxAttempts -le 0) {
        $MaxAttempts = Get-YurunaRetryDefault -EnvName 'YURUNA_RETRY_MAX_ATTEMPTS' -Fallback $script:RetryDefaults.MaxAttempts
    }
    if ($InitialDelaySeconds -le 0) {
        $InitialDelaySeconds = Get-YurunaRetryDefault -EnvName 'YURUNA_RETRY_DELAY' -Fallback $script:RetryDefaults.InitialDelaySeconds
    }
    if ($MaxDelaySeconds -le 0)     { $MaxDelaySeconds  = $script:RetryDefaults.MaxDelaySeconds }
    if ($JitterFraction  -lt 0)     { $JitterFraction   = $script:RetryDefaults.JitterFraction }

    $delay      = [int]$InitialDelaySeconds
    $attempt    = 1
    $lastExit   = 0
    $lastOutput = @()
    $lastError  = $null
    $success    = $false

    while ($attempt -le $MaxAttempts) {
        if ($OnAttempt) {
            try { & $OnAttempt @{ Attempt = $attempt; MaxAttempts = $MaxAttempts } } catch { $null = $_ }
        }
        # Reset on $global: so a local assignment here does not shadow the
        # automatic $LASTEXITCODE the scriptblock will update via native
        # exes; reading $global:LASTEXITCODE below for the same reason.
        $global:LASTEXITCODE = 0
        $lastOutput          = @()
        $lastError           = $null
        try {
            $lastOutput = & $ScriptBlock 2>&1
            $lastExit   = if ($null -ne $global:LASTEXITCODE) { [int]$global:LASTEXITCODE } else { 0 }
            if ($lastExit -eq 0) { $success = $true }
        } catch {
            $lastError = $_
            $lastExit  = if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { [int]$global:LASTEXITCODE } else { 1 }
        }

        if ($LogPath) {
            try {
                $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                $header = "== ${stamp} ${Label} attempt ${attempt}/${MaxAttempts} (exit=${lastExit}) =="
                Add-Content -LiteralPath $LogPath -Value $header
                foreach ($line in $lastOutput) {
                    Add-Content -LiteralPath $LogPath -Value ([string]$line)
                }
                if ($lastError) {
                    Add-Content -LiteralPath $LogPath -Value ("[exception] " + $lastError.Exception.Message)
                }
            } catch { $null = $_ }
        }

        if ($success) { break }

        if ($attempt -lt $MaxAttempts) {
            # A predicate lets the caller fail fast on a non-transient error
            # (config typo, NotFound, auth) instead of spending the whole
            # backoff budget on a failure that will never clear. Evaluated
            # only when a retry is still possible so its "not retryable"
            # breadcrumb can't be confused with budget exhaustion. No
            # predicate => retry on any non-zero exit (the tofu-init contract).
            if ($ShouldRetry) {
                # A predicate that THROWS is a bug in the caller's fail-fast
                # test, not evidence the failure is non-transient. Default to
                # retryable so a broken predicate falls back to the no-predicate
                # contract (retry on any non-zero exit) instead of silently
                # converting a retryable failure into a fail-fast; surface the
                # fault so the predicate bug stays diagnosable.
                $retryThis = $true
                try {
                    $retryThis = [bool](& $ShouldRetry @{ Attempt = $attempt; MaxAttempts = $MaxAttempts; ExitCode = $lastExit; Output = $lastOutput; Error = $lastError })
                } catch {
                    Write-Information "!! ${Label}: ShouldRetry predicate threw ($($_.Exception.Message)); treating the failure as retryable"
                }
                if (-not $retryThis) {
                    Write-Information "!! ${Label}: failure not retryable (exit=${lastExit}); failing fast"
                    Send-YurunaRetryEvent -EventName 'retry_exhausted' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Permanent $true
                    break
                }
            }
            $sleep = Get-YurunaRetryBackoff -BaseDelay $delay -MaxDelay $MaxDelaySeconds -JitterFraction $JitterFraction
            Write-Information "!! ${Label}: attempt ${attempt}/${MaxAttempts} failed (exit=${lastExit}); sleeping ${sleep}s before retry"
            Send-YurunaRetryEvent -EventName 'retry_attempt' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Transient ([bool](Test-YurunaTransientFailure -Output $lastOutput)) -SleepSeconds $sleep
            if ($OnRetry) {
                try { & $OnRetry @{ Attempt = $attempt; MaxAttempts = $MaxAttempts; SleepSeconds = $sleep; ExitCode = $lastExit } } catch { $null = $_ }
            }
            Start-Sleep -Seconds $sleep
            $delay = [Math]::Min([int]($delay * 2), $MaxDelaySeconds)
        } else {
            Write-Information "!! ${Label}: all ${MaxAttempts} attempts exhausted (exit=${lastExit})"
            Send-YurunaRetryEvent -EventName 'retry_exhausted' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Permanent $false
        }
        $attempt++
    }

    if ($RcFile) {
        # Exit-code sidecar so the post-mortem diagnostic's rc-scan
        # (Get-SystemDiagnostic derives <tool>.rc from <tool>.stderr.log) finds
        # a result for a tool routed only through this retry helper -- e.g.
        # tofu, which otherwise leaves a .stderr.log with no .rc sibling.
        try { Set-Content -LiteralPath $RcFile -Value "$lastExit" } catch { $null = $_ }
    }
    return [pscustomobject]@{
        Success     = $success
        Attempts    = [Math]::Min($attempt, $MaxAttempts)
        MaxAttempts = $MaxAttempts
        LastExit    = $lastExit
        LastOutput  = $lastOutput
        LastError   = $lastError
        Label       = $Label
    }
}

<#
.SYNOPSIS
    Computes the next backoff delay in seconds, capping the base delay to the
    maximum and applying +/- jitter so parallel callers do not lock-step.
#>
function Get-YurunaRetryBackoff {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$BaseDelay,
        [Parameter(Mandatory)][int]$MaxDelay,
        [Parameter(Mandatory)][double]$JitterFraction
    )
    $capped = [Math]::Min([Math]::Max($BaseDelay, 1), [Math]::Max($MaxDelay, 1))
    if ($JitterFraction -le 0) { return [int]$capped }
    $jitterRange = $capped * $JitterFraction
    $jitter = (Get-Random -Minimum (-1.0 * $jitterRange) -Maximum $jitterRange)
    $result = [int][Math]::Round($capped + $jitter)
    if ($result -lt 1) { $result = 1 }
    if ($result -gt $MaxDelay) { $result = $MaxDelay }
    return $result
}

<#
.SYNOPSIS
    Runs `tofu init -input=false` for the named resource under the shared retry
    policy, returning the Invoke-WithYurunaRetry result object.
#>
function Invoke-TofuInitWithRetry {
    [OutputType([pscustomobject])]
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory)][string]$ResourceName,
        [string]$LogPath,
        [string]$RcFile,
        [int]$MaxAttempts         = 0,
        [int]$InitialDelaySeconds = 0
    )
    $label = "tofu init ($ResourceName)"
    return Invoke-WithYurunaRetry -Label $label -ScriptBlock {
        & tofu init -input=false
    } -MaxAttempts $MaxAttempts -InitialDelaySeconds $InitialDelaySeconds -LogPath $LogPath -RcFile $RcFile
}

Export-ModuleMember -Function 'Invoke-WithYurunaRetry','Invoke-TofuInitWithRetry','Get-YurunaRetryBackoff','Get-YurunaRetryDefault','Get-YurunaTransientPattern','Test-YurunaTransientFailure'
