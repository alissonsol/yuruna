<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4257205b-1908-49c3-840b-b2b3559b3337
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

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking


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

    Both sides take an optional retry window: -WindowSeconds here, and
    YURUNA_RETRY_WINDOW_SECONDS with YURUNA_RETRY_MAX_DELAY_SECONDS there,
    which the bash wrappers set for a GitHub release URL. A window ends the
    retries once that much time has passed since the first attempt, and the
    attempt count becomes a backstop sized so the window binds first.

    Defaults can be overridden per call OR via the same env vars the
    bash side honors (YURUNA_RETRY_MAX_ATTEMPTS, YURUNA_RETRY_DELAY_SECONDS),
    so an operator can tune both halves of the system from one place.
    Parity covers those two vars only: the bash side's per-attempt
    stall bound and heal hook (YURUNA_RETRY_STALL_TIMEOUT_SECONDS,
    YURUNA_*_STALL_TIMEOUT, YURUNA_RETRY_HEAL) are guest-side knobs
    built on timeout(1) with no counterpart here. The per-attempt bound
    here is the caller's -TimeoutSeconds (Invoke-YurunaToolWithDeadline),
    which every deploy tool call passes.

    Callers that should retry only a subset of failures pass a
    -ShouldRetry predicate. It receives a hashtable
    (@{ Attempt; MaxAttempts; ExitCode; Output; Error; TimedOut }) and returns
    $true to keep retrying or $false to fail fast. Omitting it retries
    on any non-zero exit (the tofu-init contract).
#>

$script:RetryDefaults = @{
    MaxAttempts         = 5
    InitialDelaySeconds = 10
    MaxDelaySeconds     = 300
    JitterFraction      = 0.25
}

# See https://yuruna.link/4213a0b3-0010
$script:TransientFailurePattern = '(?i)(failed to fetch|i/o timeout|no such host|could not resolve host|server misbehaving|connection refused|connection to the server \S+ was refused|connection reset|client\.timeout|\bEOF\b|TLS handshake|temporary failure|\b(?:429|500|502|503|504)\b|too many requests|error acquiring the state lock|ConditionalCheckFailedException|etcdserver: (?:request timed out|leader changed)|the server was unable to return a response in the time allotted|the server is currently unable to handle the request)'

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
    Returns the attempt count that backs a retry window: enough attempts that
    their shortest jittered backoffs alone fill the window, so the window is
    what ends a retry whose every attempt fails. Without a window it returns
    the shared default.
#>
function Get-YurunaRetryWindowAttempt {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$WindowSeconds,
        [Parameter(Mandatory)][int]$InitialDelaySeconds,
        [Parameter(Mandatory)][int]$MaxDelaySeconds,
        [Parameter(Mandatory)][double]$JitterFraction
    )
    if ($WindowSeconds -le 0) { return [int]$script:RetryDefaults.MaxAttempts }
    $delay = [Math]::Max($InitialDelaySeconds, 1)
    $floor = [Math]::Max(1.0 - [Math]::Max($JitterFraction, 0.0), 0.0)
    $slept = 0.0
    $attempts = 1
    while ($slept -lt $WindowSeconds -and $attempts -lt 1000) {
        $capped = [Math]::Min($delay, [Math]::Max($MaxDelaySeconds, 1))
        $slept += [Math]::Max($capped * $floor, 1.0)
        $attempts++
        $delay = [Math]::Min([long]$delay * 2, [int]::MaxValue)
    }
    return [int]$attempts
}

<#
.SYNOPSIS
    Returns the shared transient-failure regex string for callers that match
    output inline -- e.g. a closure that must run detached in the retry module's
    scope -- instead of calling Test-YurunaTransientFailure.
#>
function Get-YurunaTransientPattern {
    [OutputType([string])]
    param()
    return $script:TransientFailurePattern
}

<#
.SYNOPSIS
    Returns $true when the given command output (a string, or an array of
    output lines/records) matches the shared transient-failure pattern and is
    worth retrying.
#>
function Test-YurunaTransientFailure {
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$Output)
    if ($null -eq $Output) { return $false }
    $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
    return ($text -match $script:TransientFailurePattern)
}

# Structured retry telemetry (best-effort). Emits a machine-readable
# retry_attempt / retry_recovered / retry_exhausted NDJSON record when this
# retry runs inside a process that also loaded Test.Log (Send-CycleEventSafely
# is Get-Command-guarded). A guest payload has no cycle stream: under the
# guest's fetch-and-execute.sh, which exports FAE_INVOCATION_SCRIPT to the
# payload, the record goes to stderr as a YURUNA_RETRY marker in the guest
# bash library's shape, and the host publishes it from the step's output or
# execution log. Anywhere else this is a no-op, so the standalone tofu-init /
# on-host probe paths print nothing. Private (not exported).
function Send-YurunaRetryEvent {
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$Label,
        [int]$Attempt,
        [int]$MaxAttempts,
        [int]$ExitCode,
        [AllowNull()][Nullable[bool]]$Transient,
        [AllowNull()][Nullable[int]]$SleepSeconds,
        [AllowNull()][Nullable[bool]]$Permanent,
        [string]$Basis,
        [int]$WindowSeconds,
        [double]$ElapsedSeconds
    )
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
        $rec = @{
            timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event          = $EventName
            stack          = 'pwsh'
            description    = [string]$Label
            attempt        = [int]$Attempt
            maxAttempts    = [int]$MaxAttempts
            exitCode       = [int]$ExitCode
            elapsedSeconds = [int][Math]::Floor($ElapsedSeconds)
        }
        if ($null -ne $Transient)    { $rec['transient']     = [bool]$Transient }
        if ($null -ne $SleepSeconds) { $rec['sleepSeconds']  = [int]$SleepSeconds }
        if ($null -ne $Permanent)    { $rec['permanent']     = [bool]$Permanent }
        if ($Basis)                  { $rec['basis']         = $Basis }
        if ($WindowSeconds -gt 0)    { $rec['windowSeconds'] = $WindowSeconds }
        Send-CycleEventSafely -EventRecord $rec
        return
    }
    if (-not $env:FAE_INVOCATION_SCRIPT) { return }
    # The bash library's vocabulary: attempt records, and one outcome record
    # for a retry that ended without a plain success. An attempt record goes
    # out only where retry_attempt is sent, before a backoff, so the attempt
    # that ended the retry appears only in the outcome record.
    $marker = [ordered]@{ stack = 'pwsh'; label = [string]$Label }
    if ($EventName -ceq 'retry_attempt') {
        $marker['event'] = 'attempt'
    } else {
        $marker['event'] = 'outcome'
        $marker['outcome'] = if ($EventName -ceq 'retry_recovered') { 'recovered' } elseif ($Permanent) { 'permanent' } else { 'exhausted' }
    }
    $marker['attempt'] = [int]$Attempt
    $marker['maxAttempts'] = [int]$MaxAttempts
    $marker['rc'] = [int]$ExitCode
    if ($null -ne $Permanent)    { $marker['permanent']     = [bool]$Permanent }
    if ($null -ne $Transient)    { $marker['transient']     = [bool]$Transient }
    if ($null -ne $SleepSeconds) { $marker['sleepSeconds']  = [int]$SleepSeconds }
    if ($Basis)                  { $marker['basis']         = $Basis }
    if ($WindowSeconds -gt 0)    { $marker['windowSeconds'] = $WindowSeconds }
    $marker['elapsedSeconds'] = [int][Math]::Floor($ElapsedSeconds)
    try { [Console]::Error.WriteLine('YURUNA_RETRY ' + ($marker | ConvertTo-Json -Compress)) }
    catch { Write-Verbose "retry record not written to stderr: $($_.Exception.Message)" }
}

<#
.SYNOPSIS
    Appends one section to a per-tool diagnostic log: a header line, then one
    line for every element of -Line.
.DESCRIPTION
    The whole section reaches the file through a single Add-Content call, so
    the log is opened once however much the tool printed. An append per line
    pays a file open for every line, and on a host that scans files as they are
    opened that turns a two-thousand-line transcript into most of a minute.

    Every element is cast to [string] before it is written. Left to itself
    Add-Content drops a $null element and renders a number in the current
    culture; the cast writes the $null as an empty line and the number the way
    PowerShell prints it, which is what appending [string]$element on its own
    produces.

    Nothing is caught here. A log that cannot be written is reported the way
    an Add-Content written at the call site would report it -- one error
    record, terminating only when the caller's error preference says so -- so
    each caller keeps the handling it already had around its own append.
#>
function Write-YurunaToolLogSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Header,
        [object[]]$Line
    )
    # A function in this module sees the global error preference, never one a
    # caller in another module set in its own scope. Read the caller's, so a
    # caller running under Stop is stopped by a log it cannot write and a
    # caller that silenced errors stays silent, as with an append of its own.
    $errorAction = $ErrorActionPreference
    if (-not $PSBoundParameters.ContainsKey('ErrorAction')) {
        $errorAction = $PSCmdlet.SessionState.PSVariable.GetValue('ErrorActionPreference', $ErrorActionPreference)
    }
    $section = @(
        $Header
        foreach ($entry in $Line) { [string]$entry }
    )
    Add-Content -LiteralPath $LogFile -Value $section -ErrorAction $errorAction
}

<#
.SYNOPSIS
    The values of environment variables whose names mark them as secrets,
    longest first.
.DESCRIPTION
    Deployment variables such as dockerPassword or registryToken are published
    to the environment and reach tool command strings through ${env:<name>}
    expansion, so their values appear in every log line a command string or its
    output is written to. A name counts as a secret when it contains password,
    passwd, passphrase, secret, token, credential, api key, private key or
    access key in any spelling. Values shorter than four characters and the
    literals true, false, null, none, yes and no are left alone: replacing
    "true" everywhere would wreck the log without protecting anything. Longest
    first, so a value that contains another is replaced whole.
#>
function Get-YurunaSecretValue {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $namePattern = '(?i)pass(word|wd|phrase)|secret|token|credential|api[_-]?key|private[_-]?key|access[_-]?key'
    $values = foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $value = [string]$entry.Value
        if ([string]$entry.Key -notmatch $namePattern) { continue }
        if ($value.Length -lt 4 -or $value -in @('true', 'false', 'null', 'none', 'yes', 'no')) { continue }
        $value
    }
    return [string[]]@($values | Select-Object -Unique | Sort-Object -Property Length -Descending)
}

<#
.SYNOPSIS
    Replace every secret value in a text with <redacted>.
.DESCRIPTION
    -SecretValue takes a list from Get-YurunaSecretValue so a caller that
    redacts many lines reads the environment once; without it the current
    environment is read for this call.
#>
function Protect-YurunaSecretText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$SecretValue
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $values = if ($PSBoundParameters.ContainsKey('SecretValue')) { @($SecretValue) } else { Get-YurunaSecretValue }
    foreach ($value in $values) { if ($value) { $Text = $Text.Replace($value, '<redacted>') } }
    return $Text
}

<#
.SYNOPSIS
    The last lines of a tool's output, redacted and bounded, for a failure
    message that has to say why the tool failed.
.DESCRIPTION
    The entry points run at -logLevel Error unless told otherwise, which drops
    the Information lines a failed step prints, and the YURUNA_RESULT line the
    host files the failure from carries only the manifest's errorMessage; a
    message naming the command and not its error leaves nothing to act on.
#>
function Get-YurunaOutputTail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Output,
        [ValidateRange(1, 50)][int]$MaxLines = 5,
        [ValidateRange(40, 4000)][int]$MaxChars = 600,
        [AllowNull()][AllowEmptyCollection()][string[]]$SecretValue
    )
    $lines = @(@($Output) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return '' }
    $values = if ($PSBoundParameters.ContainsKey('SecretValue')) { @($SecretValue) } else { Get-YurunaSecretValue }
    $tail = Protect-YurunaSecretText -Text (@($lines | Select-Object -Last $MaxLines) -join ' | ') -SecretValue $values
    if ($tail.Length -gt $MaxChars) { $tail = '...' + $tail.Substring($tail.Length - ($MaxChars - 3)) }
    return $tail
}

# --- REGION: Tool call deadline
# The watchdog runs in a runspace of its own, so it keeps time while the
# caller's thread is blocked inside the native tool. At the deadline it kills
# every process tree this process started since the call began: the tool runs
# in-process through PowerShell's own native-command handling, which keeps the
# caller's streams, environment and function stand-ins exactly as they were,
# and a dead tool returns control to the caller like any other exit. The start
# time is taken a second early because a process start time read back from the
# system can trail the clock by a few milliseconds.
$script:ToolDeadlineWatchdog = {
    param($ParentId, $StartedUtc, $DueMilliseconds, $State)
    Start-Sleep -Milliseconds $DueMilliseconds
    $State.Fired = $true
    foreach ($process in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($process.Id -eq $ParentId) { continue }
            $parent = $process.Parent
            if ($null -eq $parent -or $parent.Id -ne $ParentId) { continue }
            if ($process.StartTime.ToUniversalTime() -lt $StartedUtc) { continue }
            # Recorded before the kill, so a caller woken by the kill already
            # finds the call marked as stopped.
            $null = $State.Stopped.Add("$($process.Id) $($process.ProcessName)")
            $process.Kill($true)
        } catch {
            $null = $State.Errors.Add($_.Exception.Message)
        }
    }
}

function Enter-YurunaToolDeadline {
    # Enter/Exit rather than Start/Stop with ShouldProcess: an ambient -WhatIf
    # must never disarm the bound a caller was promised.
    param([Parameter(Mandatory)][int]$TimeoutSeconds)
    $state = [hashtable]::Synchronized(@{
        Fired   = $false
        Stopped = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Errors  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    })
    $watchdog = [powershell]::Create()
    $null = $watchdog.AddScript($script:ToolDeadlineWatchdog).
        AddArgument($PID).
        AddArgument([DateTime]::UtcNow.AddSeconds(-1)).
        AddArgument([long]$TimeoutSeconds * 1000).
        AddArgument($state)
    $handle = $watchdog.BeginInvoke()
    return @{ PowerShell = $watchdog; Handle = $handle; State = $state; TimeoutSeconds = $TimeoutSeconds }
}

function Exit-YurunaToolDeadline {
    <#
    .SYNOPSIS
        Disarm a tool deadline; $true when the watchdog stopped the call.
    .DESCRIPTION
        A deadline that passed while no child process was left to stop -- the
        tool exited as it fired, or the work was PowerShell code of the
        caller's own -- did not stop anything, so it does not count.
    #>
    param([Parameter(Mandatory)][hashtable]$Deadline)
    try { $Deadline.PowerShell.Stop() } catch { Write-Verbose "tool deadline watchdog stop: $($_.Exception.Message)" }
    $Deadline.PowerShell.Dispose()
    foreach ($message in @($Deadline.State.Errors)) { Write-Verbose "tool deadline watchdog: $message" }
    return ($Deadline.State.Stopped.Count -gt 0)
}

<#
.SYNOPSIS
    Runs one tool call under a deadline: at the deadline every process the call
    started is killed, the call reports exit code 124 (timeout(1)'s code) and
    -Outcome.TimedOut is set.
.DESCRIPTION
    The scriptblock runs in the caller's pipeline, so its output, redirections,
    environment changes and $LASTEXITCODE reach the caller as they would from a
    direct call. Only external processes can be stopped: work the scriptblock
    does in PowerShell itself runs to its end.

    A stopped call's outcome is unknown -- the tool may have acted before it was
    killed -- so callers treat it as a failure and do not replay a mutation from
    the exit code alone. The output gains one closing line saying the call was
    stopped, and the same line is written as a warning.

    The watchdog stops every child process this process started while the call
    ran, so it belongs in a process that runs one tool call at a time, as the
    deploy phases do; a process that starts other children concurrently (a
    runner with background work) must bound its calls with
    Invoke-BoundedNativeCommand instead.
.PARAMETER Outcome
    Optional hashtable that receives TimedOut ($true/$false) and TimeoutSeconds.
#>
function Invoke-YurunaToolWithDeadline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [hashtable]$Outcome
    )
    if ($Outcome) { $Outcome['TimedOut'] = $false; $Outcome['TimeoutSeconds'] = $TimeoutSeconds }
    $deadline = Enter-YurunaToolDeadline -TimeoutSeconds $TimeoutSeconds
    $stopped = $false
    try {
        & $ScriptBlock
    } finally {
        $stopped = Exit-YurunaToolDeadline -Deadline $deadline
    }
    if ($stopped) {
        if ($Outcome) { $Outcome['TimedOut'] = $true }
        $global:LASTEXITCODE = 124
        $line = Format-YurunaOperatorMessage -Key 'automation.deploy_tool_deadline' -Arguments @{ label = (Protect-YurunaSecretText -Text $Label); seconds = "$TimeoutSeconds" }
        Write-Warning $line
        $line
    }
}

# Built-in bound of each deploy tool call, in seconds. Each is well past the
# call's normal duration, so it ends only a call that stopped making progress:
# an apply that creates a managed cluster runs tens of minutes, and helm's own
# --atomic wait is five minutes on top of the chart fetch and its hooks.
$script:ToolCallDefaultSeconds = @{
    'tofu init'       = 600
    'tofu plan'       = 3600
    'tofu apply'      = 3600
    'tofu output'     = 300
    'tofu destroy'    = 3600
    'helm lint'       = 300
    'helm status'     = 300
    'helm rollback'   = 600
    'helm uninstall'  = 600
    'helm upgrade'    = 1800
    'deployment'      = 1800
    'az account'      = 120
    'image presence'  = 60
}

<#
.SYNOPSIS
    The bound for a deploy tool call: the record's commandTimeoutSeconds, else
    the document's globalVariables.commandTimeoutSeconds, else the call's
    built-in bound.
.DESCRIPTION
    The same key, range and precedence as a component's commandTimeoutSeconds:
    a configured value bounds every tool call made for that record. Valid is
    $false when a configured value is not an integer from 1 through 3600; the
    caller reports that as a configuration error.
.PARAMETER Call
    The tool call, as named in the built-in table ('tofu init', 'helm upgrade',
    'deployment', ...).
.OUTPUTS
    [pscustomobject] @{ Seconds; Configured; Valid }
#>
function Get-YurunaCommandTimeout {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateScript({ $script:ToolCallDefaultSeconds.ContainsKey($_) })][string]$Call,
        [AllowNull()]$Entry,
        [AllowNull()]$GlobalVariables
    )
    $default = [int]$script:ToolCallDefaultSeconds[$Call]
    $raw = $null
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('commandTimeoutSeconds')) { $raw = $Entry['commandTimeoutSeconds'] }
    elseif ($GlobalVariables -is [System.Collections.IDictionary] -and $GlobalVariables.Contains('commandTimeoutSeconds')) { $raw = $GlobalVariables['commandTimeoutSeconds'] }
    if ($null -eq $raw) { return [pscustomobject]@{ Seconds = $default; Configured = $false; Valid = $true } }
    $seconds = 0
    $valid = [int]::TryParse([string]$raw, [ref]$seconds) -and $seconds -ge 1 -and $seconds -le 3600
    if (-not $valid) { $seconds = $default }
    return [pscustomobject]@{ Seconds = $seconds; Configured = $true; Valid = $valid }
}

<#
.SYNOPSIS
    Runs a scriptblock under capped exponential backoff with optional jitter,
    retrying on non-zero exit (or per the -ShouldRetry predicate) and returning
    a result object describing the outcome.
.DESCRIPTION
    With -TimeoutSeconds every attempt runs under Invoke-YurunaToolWithDeadline's
    deadline. A stopped attempt ends with exit code 124 and the stopped line in
    its output, and the result's TimedOut says whether the last attempt was
    stopped. The predicate sees TimedOut too; without one, a stopped attempt is
    retried like any other non-zero exit, and the classifier never matches the
    stopped line, so a classifier-gated call is not retried after a stop.

    With -WindowSeconds, no attempt starts after that much time has passed
    since the first, the last backoff is shortened to end as the window
    closes, and an unset -MaxAttempts comes from Get-YurunaRetryWindowAttempt.
    A run the window ends reports the attempts it made as its allowance, so
    "all N attempts exhausted" stays true.

    -SucceedWhen names the failures that are the completion of an earlier
    attempt: an API server commits a create whose answer is lost to an etcd
    timeout, and the retry is refused as AlreadyExists. It receives the same
    hashtable -ShouldRetry does, and is asked only about a failed attempt that
    was not stopped and is not the first, when an earlier attempt of the same
    command can have acted. A true answer ends the retry as a success: the
    result has Success $true, LastExit 0 and CompletedBy 'already-applied', the
    attempt's log header says so, one operator line says the outcome had
    already been applied, and a retry_recovered event carries the attempt's
    own exit code. A predicate that throws counts as false and is reported;
    the attempt stays the failure it was.
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
        [scriptblock]$ShouldRetry,
        [scriptblock]$SucceedWhen,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 0,
        [ValidateRange(0, 86400)][int]$WindowSeconds = 0
    )

    if ($InitialDelaySeconds -le 0) {
        $InitialDelaySeconds = Get-YurunaRetryDefault -EnvName 'YURUNA_RETRY_DELAY_SECONDS' -Fallback $script:RetryDefaults.InitialDelaySeconds
    }
    if ($MaxDelaySeconds -le 0)     { $MaxDelaySeconds  = $script:RetryDefaults.MaxDelaySeconds }
    if ($JitterFraction  -lt 0)     { $JitterFraction   = $script:RetryDefaults.JitterFraction }
    if ($MaxAttempts -le 0) {
        $MaxAttempts = Get-YurunaRetryDefault -EnvName 'YURUNA_RETRY_MAX_ATTEMPTS' -Fallback (Get-YurunaRetryWindowAttempt -WindowSeconds $WindowSeconds -InitialDelaySeconds $InitialDelaySeconds -MaxDelaySeconds $MaxDelaySeconds -JitterFraction $JitterFraction)
    }
    $allowedAttempts = $MaxAttempts
    $windowClock = [System.Diagnostics.Stopwatch]::StartNew()
    # The label is often the expanded command itself. Redacted once here, it is
    # safe in the log header, the console lines, the events and the result.
    $secretValues = Get-YurunaSecretValue
    $Label = Protect-YurunaSecretText -Text $Label -SecretValue $secretValues

    $delay      = [int]$InitialDelaySeconds
    $attempt    = 1
    $lastExit   = 0
    $lastOutput = @()
    $lastError  = $null
    $success    = $false
    $lastTimedOut = $false
    $completedBy  = $null

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
        $lastTimedOut        = $false
        $deadline = if ($TimeoutSeconds -gt 0) { Enter-YurunaToolDeadline -TimeoutSeconds $TimeoutSeconds } else { $null }
        try {
            $lastOutput = & $ScriptBlock 2>&1
            $lastExit   = if ($null -ne $global:LASTEXITCODE) { [int]$global:LASTEXITCODE } else { 0 }
            if ($lastExit -eq 0) { $success = $true }
        } catch {
            $lastError = $_
            $lastExit  = if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { [int]$global:LASTEXITCODE } else { 1 }
        } finally {
            if ($deadline) { $lastTimedOut = Exit-YurunaToolDeadline -Deadline $deadline }
        }
        if ($lastTimedOut) {
            # The tool was killed, so whatever it printed and returned is not a
            # verdict: even an exit 0 from a tool whose child was stopped counts
            # as a failure of unknown outcome.
            $success  = $false
            $lastExit = 124
            $global:LASTEXITCODE = 124
            $stoppedLine = Format-YurunaOperatorMessage -Key 'automation.deploy_tool_deadline' -Arguments @{ label = $Label; seconds = "$TimeoutSeconds" }
            Write-Warning $stoppedLine
            $lastOutput = @($lastOutput) + $stoppedLine
        }

        if ($SucceedWhen -and -not $success -and -not $lastTimedOut -and $attempt -gt 1) {
            # Asked only once an earlier attempt of the same command has failed
            # and been retried: on the first attempt nothing earlier can have
            # acted, and a stopped attempt's outcome is unknown. A predicate
            # that throws is a bug in the caller's test, not evidence that the
            # outcome was applied, so the attempt stays the failure it was.
            $applied = $false
            try {
                $applied = [bool](& $SucceedWhen @{ Attempt = $attempt; MaxAttempts = $MaxAttempts; ExitCode = $lastExit; Output = $lastOutput; Error = $lastError; TimedOut = $lastTimedOut })
            } catch {
                Write-Information (Format-YurunaOperatorMessage -Key 'automation.retry_succeed_when_threw' -Arguments @{ label = "${Label}"; message = "$($_.Exception.Message)" })
            }
            if ($applied) {
                $completedBy = 'already-applied'
                $success = $true
                Write-Information (Format-YurunaOperatorMessage -Key 'automation.retry_already_applied' -Arguments @{ label = "${Label}"; attempt = "${attempt}"; maxAttempts = "${MaxAttempts}"; lastExit = "${lastExit}" })
                # The event and the log header keep the attempt's own exit
                # code; the result and the sidecar report the command complete.
                Send-YurunaRetryEvent -EventName 'retry_recovered' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Basis $completedBy `
                    -WindowSeconds $WindowSeconds -ElapsedSeconds $windowClock.Elapsed.TotalSeconds
            }
        }

        if ($LogPath) {
            try {
                $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                $state = "exit=${lastExit}"
                if ($completedBy) { $state += "; completedBy=${completedBy}" }
                $header = "== ${stamp} ${Label} attempt ${attempt}/${MaxAttempts} (${state}) =="
                # The attempt is one section: its output can run to thousands
                # of lines, and each separate append would open the log again.
                $lines = @(
                    foreach ($line in $lastOutput) { Protect-YurunaSecretText -Text ([string]$line) -SecretValue $secretValues }
                    if ($lastError) { "[exception] " + (Protect-YurunaSecretText -Text $lastError.Exception.Message -SecretValue $secretValues) }
                )
                Write-YurunaToolLogSection -LogFile $LogPath -Header $header -Line $lines
            } catch { $null = $_ }
        }

        if ($completedBy) {
            $lastExit = 0
            $global:LASTEXITCODE = 0
        }
        if ($success) { break }

        $windowRemaining = 0
        $windowClosed = $false
        if ($WindowSeconds -gt 0) {
            $windowRemaining = [int][Math]::Ceiling($WindowSeconds - $windowClock.Elapsed.TotalSeconds)
            $windowClosed = $windowRemaining -le 0
        }
        if ($attempt -lt $MaxAttempts -and -not $windowClosed) {
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
                    $retryThis = [bool](& $ShouldRetry @{ Attempt = $attempt; MaxAttempts = $MaxAttempts; ExitCode = $lastExit; Output = $lastOutput; Error = $lastError; TimedOut = $lastTimedOut })
                } catch {
                    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_5bb127d98fea6728' -Arguments @{ label = "${Label}"; message = "$($_.Exception.Message)" })
                }
                if (-not $retryThis) {
                    Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_34010bbd70837710' -Arguments @{ label = "${Label}"; lastExit = "${lastExit}" })
                    Send-YurunaRetryEvent -EventName 'retry_exhausted' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Permanent $true `
                        -WindowSeconds $WindowSeconds -ElapsedSeconds $windowClock.Elapsed.TotalSeconds
                    break
                }
            }
            $sleep = Get-YurunaRetryBackoff -BaseDelay $delay -MaxDelay $MaxDelaySeconds -JitterFraction $JitterFraction
            # The last attempt starts as the window closes, not after it.
            if ($WindowSeconds -gt 0 -and $sleep -gt $windowRemaining) { $sleep = $windowRemaining }
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_b33c77878eaa7c77' -Arguments @{ label = "${Label}"; attempt = "${attempt}"; maxAttempts = "${MaxAttempts}"; lastExit = "${lastExit}"; sleep = "${sleep}" })
            Send-YurunaRetryEvent -EventName 'retry_attempt' -Label $Label -Attempt $attempt -MaxAttempts $MaxAttempts -ExitCode $lastExit -Transient ([bool](Test-YurunaTransientFailure -Output $lastOutput)) -SleepSeconds $sleep `
                -WindowSeconds $WindowSeconds -ElapsedSeconds $windowClock.Elapsed.TotalSeconds
            if ($OnRetry) {
                try { & $OnRetry @{ Attempt = $attempt; MaxAttempts = $MaxAttempts; SleepSeconds = $sleep; ExitCode = $lastExit } } catch { $null = $_ }
            }
            Start-Sleep -Seconds $sleep
            $delay = [Math]::Min([int]($delay * 2), $MaxDelaySeconds)
        } else {
            if ($windowClosed) { $allowedAttempts = $attempt }
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_0006b705ae0abd93' -Arguments @{ label = "${Label}"; maxAttempts = "${allowedAttempts}"; lastExit = "${lastExit}" })
            Send-YurunaRetryEvent -EventName 'retry_exhausted' -Label $Label -Attempt $attempt -MaxAttempts $allowedAttempts -ExitCode $lastExit -Permanent $false `
                -WindowSeconds $WindowSeconds -ElapsedSeconds $windowClock.Elapsed.TotalSeconds
            if ($windowClosed) { break }
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
        Attempts    = [Math]::Min($attempt, $allowedAttempts)
        MaxAttempts = $allowedAttempts
        LastExit    = $lastExit
        LastOutput  = $lastOutput
        LastError   = $lastError
        Label       = $Label
        TimedOut    = $lastTimedOut
        CompletedBy = $completedBy
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
.DESCRIPTION
    Each attempt is bounded by -TimeoutSeconds, or by the built-in 'tofu init'
    bound when it is zero. A stopped attempt is retried like any other failed
    one: init only fetches providers and modules, and a fetch that stalled is
    the failure a retry clears.

    Init retries through the same 30-minute window, with backoff capped at
    two minutes, that the guest library gives a GitHub release fetch, unless
    the caller or YURUNA_RETRY_MAX_ATTEMPTS sets the attempt count. It is the
    call that must reach the provider registry and the GitHub releases the
    providers download from, and an attempt that cannot reach them fails
    within seconds on OpenTofu's own client timeout, so five attempts spanned
    only about four minutes. GitHub's release endpoints have answered 504 for
    most of half an hour at a time, which outlasts that.

    A result that did not succeed also carries FetchFailure, the download the
    last attempt reported failing (Get-TofuFetchFailure), so the failure names
    the host that refused it rather than guessing at the registry.
#>
function Invoke-TofuInitWithRetry {
    [OutputType([pscustomobject])]
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory)][string]$ResourceName,
        [string]$LogPath,
        [string]$RcFile,
        [int]$MaxAttempts         = 0,
        [int]$InitialDelaySeconds = 0,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 0
    )
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:ToolCallDefaultSeconds['tofu init'] }
    $label = "tofu init ($ResourceName)"
    $result = Invoke-WithYurunaRetry -Label $label -ScriptBlock {
        & tofu init -input=false
    } -MaxAttempts $MaxAttempts -InitialDelaySeconds $InitialDelaySeconds -MaxDelaySeconds 120 -WindowSeconds 1800 -LogPath $LogPath -RcFile $RcFile -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Success) {
        $result | Add-Member -NotePropertyName FetchFailure -NotePropertyValue (Get-TofuFetchFailure -Output $result.LastOutput)
    }
    return $result
}

<#
.SYNOPSIS
    The download an OpenTofu run reported failing: its URL and the status or
    error tofu gave for it, or $null.
.DESCRIPTION
    tofu draws each error in a box, colors it and wraps its long lines inside
    the box, so a URL and its error can sit on different lines; each paragraph
    of a box is read as one line. A copy that passed through a log keeping
    only printable characters has lost each color code's escape byte, so a
    bare code is removed too. Three forms name the download: Go's client
    error (Get "<url>": <error>), the retrying client's (GET <url> giving up
    after N attempt(s)) and a status the registry client reports (<status>
    returned from <url>, which can name only the host). The last one in the
    output is returned. The URL keeps its scheme, host and path: a release
    download is redirected to a signed URL whose query is a credential.
.OUTPUTS
    [pscustomobject] @{ Url; Error } or $null.
#>
function Get-TofuFetchFailure {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Output)
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    $paragraph = [System.Collections.Generic.List[string]]::new()
    foreach ($text in @(@($Output) | ForEach-Object { [string]$_ -split '\r?\n' })) {
        $line = ($text -replace '\x1b\[[0-9;]*[A-Za-z]|\[[0-9;]*m', '').Trim()
        $boxed = $line -match '^\u2502'
        $content = if ($boxed) { $line -replace '^\u2502\s*', '' } else { $line }
        if ($boxed -and $content) { $paragraph.Add($content); continue }
        if ($paragraph.Count -gt 0) { $diagnostics.Add($paragraph -join ' '); $paragraph.Clear() }
        if (-not $boxed -and $content -notmatch '^[\u2575\u2577]?$') { $diagnostics.Add($content) }
    }
    if ($paragraph.Count -gt 0) { $diagnostics.Add($paragraph -join ' ') }
    $found = $null
    foreach ($diagnostic in $diagnostics) {
        if ($diagnostic -match '\bGet "(?<url>https?://[^"\s]+)":\s*(?<reason>.+)$' -or
            $diagnostic -match '\bGET (?<url>https?://\S+) (?<reason>giving up after \d+ attempt\(s\).*)$' -or
            $diagnostic -match '(?<reason>\b\d{3}(?: [A-Za-z][A-Za-z -]*)?) returned from (?<url>\S+)') {
            $found = @{ url = $Matches['url']; reason = $Matches['reason'] }
        }
    }
    if (-not $found) { return $null }
    $url = $found.url.TrimEnd('.', ',', ';', ':', ')')
    $uri = $null
    if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
        $url = "$($uri.Scheme)://$($uri.Authority)$($uri.AbsolutePath)"
    }
    $reason = $found.reason.Trim()
    if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) }
    $secretValues = Get-YurunaSecretValue
    return [pscustomobject]@{
        Url   = Protect-YurunaSecretText -Text $url -SecretValue $secretValues
        Error = Protect-YurunaSecretText -Text $reason -SecretValue $secretValues
    }
}

Export-ModuleMember -Function 'Invoke-WithYurunaRetry','Invoke-TofuInitWithRetry','Invoke-YurunaToolWithDeadline','Get-YurunaCommandTimeout','Get-YurunaRetryBackoff','Get-YurunaRetryDefault','Get-YurunaTransientPattern','Test-YurunaTransientFailure','Write-YurunaToolLogSection','Get-YurunaSecretValue','Protect-YurunaSecretText','Get-YurunaOutputTail'
