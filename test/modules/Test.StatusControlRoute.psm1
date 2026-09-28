<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4296b755-95ac-439b-8cc9-62f9188e5c59
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna status service route host-refresh body-reader worker
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
    Route helpers for the status listener's mutating control routes: the
    bounded body reader, the host-refresh request body and reply mapping, the
    refresh capability summary, and the detached worker plumbing that keeps
    diagnostics and start-cycle off the request loop.
.DESCRIPTION
    The status listener handles one request context at a time, so anything a
    route does synchronously parks every other route, including the read-only
    /status/ and /runtime/status.json that tell an operator whether the host is
    alive. These helpers carry the decisions that must stay cheap and
    deterministic -- is a body complete, is it well formed, which reply does an
    admission record map to, may a worker vector be launched -- as pure
    functions the listener calls between requests and a suite can drive
    without a live socket.

    Imports only the globalization module and the shared primitives: it must
    load in the listener runspace, which never holds a host driver, and a
    driver import there would pull the caching-proxy module and run the host
    contract coverage check inside the request loop.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
# -Global without -Force: the listener runspace calls the deadline helpers too,
# and a -Force here would evict a copy a caller already holds.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking

# The request body a refresh POST may carry. Anything larger is refused one
# byte past the cap, whatever length the client declared or whether it
# declared one at all; a chunked body of unknown length gets no exemption.
$script:HostRefreshBodyMaxBytes = 4096
# Keys a refresh body may carry, compared case-sensitively. Duplicates in any
# casing are refused, so two spellings can never smuggle different values
# past a reader that folds case.
$script:HostRefreshBodyKey = @('requestId', 'tier', 'maxRung')
# Normalized key fragments that name a local-only safety switch. A body that
# names one is refused as forbidden rather than unsupported, because these are
# the settings an HTTP caller must never be able to set, in any spelling.
$script:HostRefreshForbiddenFragment = @('force', 'hardstop', 'allowhardstop', 'restoreservicevm', 'leavestoppedservicevm', 'configpath')
# Canonical lowercase UUID in the 8-4-4-4-12 form; \A and \z because '$' also
# matches before a trailing newline.
$script:StatusRouteRequestIdPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
# A rejected field name is echoed back only in this shape; anything else is
# replaced so a caller cannot make the reply carry arbitrary text.
$script:StatusRouteEchoFieldPattern = '\A[A-Za-z0-9_.-]{1,64}\z'
# Wire codes: lowercase with underscores, bounded, the shape the aggregator
# clamps to. A value outside it is replaced, never passed through.
$script:StatusRouteWirePattern = '\A[a-z][a-z0-9_]{0,47}\z'
$script:StatusRouteRungPattern = '\A[a-z][a-z-]{0,31}\z'
$script:HostRefreshStateUrl = '/runtime/host-refresh.state.json'
$script:StartCycleStateUrl = '/runtime/start-cycle.state.json'
# ExternalScriptInfo keyed by path, reused while the file is unchanged, so a
# validation on every request does not re-parse the script.
$script:StatusWorkerCommandCache = @{}
$script:StatusWorkerStateMaxBytes = 65536

function ConvertTo-StatusRouteWireToken {
    <#
    .SYNOPSIS
        A private token as its wire code: lowercase, hyphens as underscores,
        and '' when the result is not a bounded code.
    .DESCRIPTION
        Private records keep hyphenated tokens; everything that crosses the
        listener boundary is lowercase with underscores. The conversion is the
        one ConvertTo-HostRefreshWireCode applies, repeated here so a reply
        never depends on another module having loaded to be well formed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim().ToLowerInvariant().Replace('-', '_')
    if ($text -cmatch $script:StatusRouteWirePattern) { return $text }
    return ''
}

function Get-StatusRouteField {
    <#
    .SYNOPSIS
        One named field of a record that may be a hashtable or an object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object]$Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $property = $Record.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function New-StatusBoundedBodyRead {
    <#
    .SYNOPSIS
        Start reading a request body without blocking: one asynchronous read
        into a buffer one byte larger than the cap, under an absolute deadline.
    .DESCRIPTION
        The listener's dispatch loop must never park on a body. This issues
        the first ReadAsync and returns at once; Update-StatusBoundedBodyRead
        consumes only reads that have already completed. The buffer is one
        byte larger than MaxBytes so the byte past the cap is observed rather
        than inferred from a declared length a client can omit or falsify.
    .PARAMETER Stream
        The request's input stream.
    .PARAMETER MaxBytes
        The largest body accepted.
    .PARAMETER TimeoutMs
        The absolute time the whole body has, from now. Progress never
        extends it: a client trickling one byte at a time is cut off at the
        same instant as one sending nothing.
    .PARAMETER NowMs
        The current tick ([Environment]::TickCount64); injectable for tests.
    .PARAMETER Tag
        Caller data carried with the read (the request context).
    .OUTPUTS
        [pscustomobject] @{ Status reading|error; Count; MaxBytes; DeadlineMs;
        Task; Bytes; Tag; Buffer; Cancellation; Stream }.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory read record; nothing on disk or in process state outside it changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [ValidateRange(1, 16777216)][int]$MaxBytes = 4096,
        [ValidateRange(1, 60000)][int]$TimeoutMs = 2000,
        [long]$NowMs = [Environment]::TickCount64,
        [object]$Tag
    )
    $read = [pscustomobject]@{
        PSTypeName   = 'Yuruna.StatusBoundedBodyRead'
        Status       = 'reading'
        Count        = 0
        MaxBytes     = $MaxBytes
        DeadlineMs   = [long]($NowMs + $TimeoutMs)
        Task         = $null
        Bytes        = $null
        Tag          = $Tag
        Buffer       = [byte[]]::new($MaxBytes + 1)
        Cancellation = [System.Threading.CancellationTokenSource]::new()
        Stream       = $Stream
    }
    try {
        $read.Task = $Stream.ReadAsync($read.Buffer, 0, $read.Buffer.Length, $read.Cancellation.Token)
    } catch {
        Write-Verbose "New-StatusBoundedBodyRead: the first read could not be issued: $($_.Exception.Message)"
        $read.Status = 'error'
    }
    return $read
}

function Update-StatusBoundedBodyRead {
    <#
    .SYNOPSIS
        Advance a pending body read using only reads that have completed.
    .DESCRIPTION
        Never waits and never touches the result of an unfinished task, which
        would block the calling thread for as long as the client withholds
        bytes. Reads that complete synchronously (bytes already buffered) are
        consumed in a loop. The body is too_large the moment more than
        MaxBytes arrived, complete when the stream reports its end, and
        timeout once NowMs reaches the deadline while a read is still
        outstanding, however much has arrived.

        The deadline is judged only against a read that has not completed.
        The dispatch loop can reach a pending body late -- after serving an
        archive stream or another request's admission -- and a body whose
        every byte and end-of-stream arrived in time is complete, not late:
        after consuming a finished read the next one is issued first, and a
        stream that has already ended answers it synchronously with zero.
        A client still sending past the deadline gains nothing, because the
        read it keeps outstanding is what times out.
    .PARAMETER BodyRead
        The record from New-StatusBoundedBodyRead.
    .PARAMETER NowMs
        The current tick; injectable for tests.
    .OUTPUTS
        [string] reading | complete | too_large | timeout | error. Bytes is set
        on complete.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Advances an in-memory read record; the only I/O is issuing the next read of a stream the caller owns.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][psobject]$BodyRead,
        [long]$NowMs = [Environment]::TickCount64
    )
    while ($BodyRead.Status -eq 'reading') {
        $task = $BodyRead.Task
        if ($null -eq $task) { $BodyRead.Status = 'error'; break }
        if (-not $task.IsCompleted) {
            if ($NowMs -ge $BodyRead.DeadlineMs) { $BodyRead.Status = 'timeout' }
            break
        }
        if ($task.IsFaulted -or $task.IsCanceled) { $BodyRead.Status = 'error'; break }
        $received = [int]$task.Result
        if ($received -le 0) {
            $bytes = [byte[]]::new($BodyRead.Count)
            if ($BodyRead.Count -gt 0) { [Array]::Copy($BodyRead.Buffer, $bytes, $BodyRead.Count) }
            $BodyRead.Bytes = $bytes
            $BodyRead.Status = 'complete'
            break
        }
        $BodyRead.Count += $received
        if ($BodyRead.Count -gt $BodyRead.MaxBytes) { $BodyRead.Status = 'too_large'; break }
        try {
            $BodyRead.Task = $BodyRead.Stream.ReadAsync($BodyRead.Buffer, $BodyRead.Count,
                $BodyRead.Buffer.Length - $BodyRead.Count, $BodyRead.Cancellation.Token)
        } catch {
            Write-Verbose "Update-StatusBoundedBodyRead: the next read could not be issued: $($_.Exception.Message)"
            $BodyRead.Status = 'error'
        }
    }
    return [string]$BodyRead.Status
}

function Get-StatusBoundedBodyReadWait {
    <#
    .SYNOPSIS
        Milliseconds until the earliest pending body read reaches its
        deadline, for the dispatch loop's wait.
    .PARAMETER BodyRead
        The pending reads.
    .PARAMETER NowMs
        The current tick; injectable for tests.
    .OUTPUTS
        [int] 0 or more, or -1 when nothing is pending (wait indefinitely).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$BodyRead,
        [long]$NowMs = [Environment]::TickCount64
    )
    $best = [long]-1
    foreach ($read in @($BodyRead)) {
        if ($null -eq $read -or $read.Status -ne 'reading') { continue }
        $left = [Math]::Max([long]0, [long]$read.DeadlineMs - $NowMs)
        if ($best -lt 0 -or $left -lt $best) { $best = $left }
    }
    if ($best -lt 0) { return -1 }
    return [int][Math]::Min($best, [long][int]::MaxValue)
}

function Close-StatusBoundedBodyRead {
    <#
    .SYNOPSIS
        Release a body read: request cancellation, observe a finished task's
        fault, dispose the cancellation source. Never throws.
    .DESCRIPTION
        Cancellation is only a request; a read already waiting on the socket
        is ended by the connection closing, which the caller arranges by
        replying with KeepAlive off or aborting the response.
    .PARAMETER BodyRead
        The record from New-StatusBoundedBodyRead.
    #>
    [CmdletBinding()]
    param([AllowNull()][psobject]$BodyRead)
    if ($null -eq $BodyRead) { return }
    try { if ($BodyRead.Cancellation) { $BodyRead.Cancellation.Cancel() } } catch { Write-Verbose "Close-StatusBoundedBodyRead: cancel failed: $($_.Exception.Message)" }
    try {
        if ($BodyRead.Task -and $BodyRead.Task.IsCompleted -and $BodyRead.Task.IsFaulted) { $null = $BodyRead.Task.Exception }
    } catch { Write-Verbose "Close-StatusBoundedBodyRead: task fault could not be observed: $($_.Exception.Message)" }
    try { if ($BodyRead.Cancellation) { $BodyRead.Cancellation.Dispose() } } catch { Write-Verbose "Close-StatusBoundedBodyRead: dispose failed: $($_.Exception.Message)" }
    $BodyRead.Buffer = $null
}

function Test-HostRefreshContentType {
    <#
    .SYNOPSIS
        True for application/json with no charset or charset utf-8.
    .PARAMETER ContentType
        The request's Content-Type header value.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$ContentType)
    if ([string]::IsNullOrWhiteSpace($ContentType)) { return $false }
    $parts = @($ContentType.Split(';') | ForEach-Object { $_.Trim() })
    if (-not [string]::Equals($parts[0], 'application/json', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($parameter in @($parts | Select-Object -Skip 1)) {
        if ([string]::IsNullOrEmpty($parameter)) { continue }
        $pair = $parameter.Split('=', 2)
        if ($pair.Count -ne 2) { return $false }
        if (-not [string]::Equals($pair[0].Trim(), 'charset', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $charset = $pair[1].Trim().Trim('"')
        if (-not ([string]::Equals($charset, 'utf-8', [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($charset, 'utf8', [StringComparison]::OrdinalIgnoreCase))) { return $false }
    }
    return $true
}

function ConvertFrom-HostRefreshRequestBody {
    <#
    .SYNOPSIS
        Validate a host-refresh request body against its closed schema.
    .DESCRIPTION
        Strict UTF-8 without a byte-order mark, a JSON object at most four
        levels deep, no comments and no trailing commas. The keys are exactly
        requestId, tier and maxRung, compared case-sensitively; a key naming a
        local-only safety switch (force, hard stop, the service selections,
        a config path) in any spelling is forbidden, and any other key is
        unsupported. Duplicate names in any casing are refused. requestId is
        the canonical lowercase UUID; tier is restart; maxRung is one of the
        allowed rung names.
    .PARAMETER Bytes
        The complete body.
    .PARAMETER AllowedRungName
        Rung names a caller may name as a ceiling (Order 0 through 4).
    .PARAMETER Remote
        A proof-carrying remote caller: every key is required, because the
        proof binds all three.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason ''|invalid_json|unsupported_field|
        forbidden_field|invalid_value; Field; RequestId; Tier; MaxRung;
        RequestIdSupplied }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedRungName,
        [switch]$Remote
    )
    $result = [ordered]@{
        Valid = $false; Reason = ''; Field = ''; RequestId = ''; Tier = ''; MaxRung = ''; RequestIdSupplied = $false
    }
    $refuse = {
        param([string]$Reason, [string]$Field)
        $result.Reason = $Reason
        $result.Field = if ($Field -cmatch $script:StatusRouteEchoFieldPattern) { $Field } elseif ($Field) { 'field' } else { '' }
        [pscustomobject]$result
    }
    if ($Bytes.Length -gt $script:HostRefreshBodyMaxBytes) { return (& $refuse 'invalid_json' '') }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return (& $refuse 'invalid_json' '')
    }
    $text = $null
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    } catch {
        return (& $refuse 'invalid_json' '')
    }
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 4
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $options.AllowTrailingCommas = $false
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
    } catch {
        return (& $refuse 'invalid_json' '')
    }
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return (& $refuse 'invalid_json' '') }
        $properties = @(foreach ($property in $root.EnumerateObject()) { $property })
        foreach ($property in $properties) {
            $normalized = ($property.Name.ToLowerInvariant() -replace '[^a-z0-9]', '')
            foreach ($fragment in $script:HostRefreshForbiddenFragment) {
                if ($normalized.Contains($fragment)) { return (& $refuse 'forbidden_field' $property.Name) }
            }
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $properties) {
            if (-not $seen.Add($property.Name)) { return (& $refuse 'invalid_json' $property.Name) }
        }
        $values = @{}
        foreach ($property in $properties) {
            if ($script:HostRefreshBodyKey -cnotcontains $property.Name) { return (& $refuse 'unsupported_field' $property.Name) }
            if ($property.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                return (& $refuse 'invalid_value' $property.Name)
            }
            $values[$property.Name] = $property.Value.GetString()
        }
        if ($Remote) {
            foreach ($required in $script:HostRefreshBodyKey) {
                if (-not $values.ContainsKey($required)) { return (& $refuse 'invalid_value' $required) }
            }
        }
        if ($values.ContainsKey('requestId')) {
            $candidate = [string]$values['requestId']
            $parsed = [Guid]::Empty
            if ($candidate -cnotmatch $script:StatusRouteRequestIdPattern -or
                -not [Guid]::TryParseExact($candidate, 'D', [ref]$parsed) -or
                -not [string]::Equals($parsed.ToString('D'), $candidate, [StringComparison]::Ordinal)) {
                return (& $refuse 'invalid_value' 'requestId')
            }
            $result.RequestId = $candidate
            $result.RequestIdSupplied = $true
        }
        if ($values.ContainsKey('tier')) {
            if (-not [string]::Equals([string]$values['tier'], 'restart', [StringComparison]::Ordinal)) {
                return (& $refuse 'invalid_value' 'tier')
            }
        }
        $result.Tier = 'restart'
        if ($values.ContainsKey('maxRung')) {
            $rung = [string]$values['maxRung']
            if ($AllowedRungName -cnotcontains $rung) { return (& $refuse 'invalid_value' 'maxRung') }
            $result.MaxRung = $rung
        }
    } finally {
        $document.Dispose()
    }
    $result.Valid = $true
    return [pscustomobject]$result
}

function Get-HostRefreshControlSummary {
    <#
    .SYNOPSIS
        The compact refresh capability /control/control-status advertises.
    .DESCRIPTION
        Copies the capability the refresh module computed, clamps every field
        to the vocabulary the aggregator accepts, applies the listener's own
        refusal (a route dependency it cannot load, a host type it does not
        know) and adds the remote-refresh provisioning state. A missing or
        malformed capability reads as unavailable, never as available: this
        field decides whether a disruptive button is shown.
    .PARAMETER Capability
        The capability record, or $null when it could not be computed.
    .PARAMETER ListenerReady
        Whether every command the route needs resolves in this runspace.
    .PARAMETER ListenerReason
        The wire code to report when the listener is not ready.
    .PARAMETER Remote
        provisioned, missing, invalid or unqualified.
    .OUTPUTS
        [ordered] @{ protocol; availability; ceiling; reason; remote; state },
        at most 256 bytes of compressed JSON.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object]$Capability,
        [Parameter(Mandatory)][bool]$ListenerReady,
        [AllowEmptyString()][string]$ListenerReason = 'listener_dependency_missing',
        [AllowEmptyString()][string]$Remote = 'unqualified'
    )
    $remoteValue = if (@('provisioned', 'missing', 'invalid', 'unqualified') -ccontains $Remote) { $Remote } else { 'unqualified' }
    $summary = [ordered]@{
        protocol     = 1
        availability = 'unavailable'
        ceiling      = ''
        reason       = 'capability_unavailable'
        remote       = $remoteValue
        state        = 'unknown'
    }
    if ($null -ne $Capability) {
        $state = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Capability -Name 'state')
        if (@('idle', 'active', 'recovery_pending', 'unknown') -ccontains $state) { $summary.state = $state }
        $protocolValue = Get-StatusRouteField -Record $Capability -Name 'protocol'
        $availability = [string](Get-StatusRouteField -Record $Capability -Name 'availability')
        $ceiling = [string](Get-StatusRouteField -Record $Capability -Name 'ceiling')
        $reason = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Capability -Name 'reason')
        $protocolNumber = 0
        if (-not [int]::TryParse([string]$protocolValue, [ref]$protocolNumber) -or $protocolNumber -ne 1) {
            $summary.reason = 'protocol_unreadable'
        } elseif ($availability -ceq 'available') {
            if ($ceiling -cmatch $script:StatusRouteRungPattern) {
                $summary.availability = 'available'
                $summary.ceiling = $ceiling
                $summary.reason = ''
            } else {
                $summary.reason = 'no_qualified_rung'
            }
        } elseif ($availability -ceq 'unavailable') {
            $summary.reason = if ($reason) { $reason } else { 'capability_unavailable' }
        }
    }
    if (-not $ListenerReady) {
        $summary.availability = 'unavailable'
        $summary.ceiling = ''
        $listenerCode = ConvertTo-StatusRouteWireToken -Value $ListenerReason
        $summary.reason = if ($listenerCode) { $listenerCode } else { 'listener_dependency_missing' }
    }
    return $summary
}

function Get-HostRefreshAdmissionReply {
    <#
    .SYNOPSIS
        The HTTP reply for a host-refresh admission decision and, when the
        decision was spawn, the launch that followed it.
    .DESCRIPTION
        A pure mapping from the private admission record to the documented
        reply table. Every value in the body is a wire code or an identifier;
        the localized sentence is added by the listener from MessageKey.
          spawn + launched      202 spawned
          spawn + not launched  503 launcher_failed (the request stays queued)
          already-claimed       202 already_claimed
          completed             200 completed, with state and verdict
          busy                  409 busy, with activeKind and activeRequestId
          policy-mismatch       409 request_conflict
          stored                409 request_closed, with state and verdict
          unavailable           503 admission_unavailable
        An unrecognized decision is 500 internal_error.
    .PARAMETER Admission
        The admission record.
    .PARAMETER Launch
        The detached launch result, for the spawn decision.
    .PARAMETER Ceiling
        The ceiling the request asked for, reported when the record has none.
    .PARAMETER StateUrl
        Where the request's progress is published.
    .PARAMETER StartCycleStateUrl
        Where a start-cycle operation's progress is published, for a busy
        reply caused by one.
    .OUTPUTS
        [pscustomobject] @{ StatusCode; Body; MessageKey; MessageArguments;
        Close; RetryAfter }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Admission,
        [AllowNull()][object]$Launch,
        [AllowEmptyString()][string]$Ceiling = '',
        [string]$StateUrl = $script:HostRefreshStateUrl,
        [string]$StartCycleStateUrl = $script:StartCycleStateUrl
    )
    $reply = { param([int]$Status, [System.Collections.IDictionary]$Body, [string]$Key, [hashtable]$Arguments)
        [pscustomobject]@{
            StatusCode = $Status; Body = $Body; MessageKey = $Key
            MessageArguments = if ($Arguments) { $Arguments } else { @{} }
            Close = $false; RetryAfter = ''
        }
    }
    $decision = [string](Get-StatusRouteField -Record $Admission -Name 'Decision')
    $requestId = [string](Get-StatusRouteField -Record $Admission -Name 'RequestId')
    $recordCeiling = [string](Get-StatusRouteField -Record $Admission -Name 'Ceiling')
    $ceilingValue = if ($recordCeiling -cmatch $script:StatusRouteRungPattern) { $recordCeiling } elseif ($Ceiling -cmatch $script:StatusRouteRungPattern) { $Ceiling } else { '' }
    $state = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Admission -Name 'State')
    $verdict = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Admission -Name 'Verdict')
    switch -CaseSensitive ($decision) {
        'spawn' {
            if ($null -ne $Launch -and [bool](Get-StatusRouteField -Record $Launch -Name 'Launched')) {
                return (& $reply 202 ([ordered]@{ ok = $true; requestId = $requestId; action = 'spawned'; ceiling = $ceilingValue; stateUrl = $StateUrl }) '' $null)
            }
            $launchReason = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Launch -Name 'Reason')
            return (& $reply 503 ([ordered]@{ ok = $false; reason = 'launcher_failed'; requestId = $requestId; stateUrl = $StateUrl }) `
                    'status.api_worker_launcher_failed' @{ reason = $(if ($launchReason) { $launchReason } else { 'launcher_failed' }) })
        }
        'already-claimed' {
            return (& $reply 202 ([ordered]@{ ok = $true; requestId = $requestId; action = 'already_claimed'; ceiling = $ceilingValue; stateUrl = $StateUrl }) '' $null)
        }
        'completed' {
            return (& $reply 200 ([ordered]@{ ok = $true; requestId = $requestId; action = 'completed'; state = $state; verdict = $verdict; ceiling = $ceilingValue; stateUrl = $StateUrl }) '' $null)
        }
        'busy' {
            $activeKind = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Admission -Name 'ActiveKind')
            if (@('host_refresh', 'start_cycle') -cnotcontains $activeKind) { $activeKind = 'host_refresh' }
            $activeUrl = if ($activeKind -ceq 'start_cycle') { $StartCycleStateUrl } else { $StateUrl }
            $activeRequestId = [string](Get-StatusRouteField -Record $Admission -Name 'ActiveRequestId')
            return (& $reply 409 ([ordered]@{ ok = $false; reason = 'busy'; activeKind = $activeKind; activeRequestId = $activeRequestId; stateUrl = $activeUrl }) `
                    'status.api_host_refresh_busy' $null)
        }
        'policy-mismatch' {
            return (& $reply 409 ([ordered]@{ ok = $false; reason = 'request_conflict'; requestId = $requestId; stateUrl = $StateUrl }) `
                    'status.api_host_refresh_request_conflict' $null)
        }
        'stored' {
            return (& $reply 409 ([ordered]@{ ok = $false; reason = 'request_closed'; requestId = $requestId; state = $state; verdict = $verdict; stateUrl = $StateUrl }) `
                    'status.api_host_refresh_request_closed' @{ state = $(if ($state) { $state } else { 'unknown' }) })
        }
        'unavailable' {
            $admissionReason = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Admission -Name 'Reason')
            return (& $reply 503 ([ordered]@{ ok = $false; reason = 'admission_unavailable' }) `
                    'status.api_admission_unavailable' @{ reason = $(if ($admissionReason) { $admissionReason } else { 'admission_unavailable' }) })
        }
    }
    return (& $reply 500 ([ordered]@{ ok = $false; reason = 'internal_error' }) 'status.api_internal_error' $null)
}

function Get-StartCycleAdmissionReply {
    <#
    .SYNOPSIS
        The HTTP reply for a start-cycle reservation and the worker launch
        that followed it.
    .DESCRIPTION
          reserved + launched      202 queued, with operationId and stateUrl
          reserved + not launched  503 launcher_failed (the reservation is
                                   removed; nothing was changed)
          busy                     409 busy, with the operation holding the
                                   host (activeKind host_refresh or start_cycle)
          unavailable              503 admission_unavailable
        An unrecognized decision is 500 internal_error.
    .PARAMETER Reservation
        The reservation record.
    .PARAMETER Launch
        The worker launch result, for a reserved decision.
    .PARAMETER OperationId
        The operation the listener minted.
    .PARAMETER StateUrl
        Where start-cycle progress is published.
    .PARAMETER RefreshStateUrl
        Where host-refresh progress is published.
    .OUTPUTS
        [pscustomobject] @{ StatusCode; Body; MessageKey; MessageArguments;
        Close; RetryAfter }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Reservation,
        [AllowNull()][object]$Launch,
        [Parameter(Mandatory)][string]$OperationId,
        [string]$StateUrl = $script:StartCycleStateUrl,
        [string]$RefreshStateUrl = $script:HostRefreshStateUrl
    )
    $reply = { param([int]$Status, [System.Collections.IDictionary]$Body, [string]$Key, [hashtable]$Arguments)
        [pscustomobject]@{
            StatusCode = $Status; Body = $Body; MessageKey = $Key
            MessageArguments = if ($Arguments) { $Arguments } else { @{} }
            Close = $false; RetryAfter = ''
        }
    }
    $decision = [string](Get-StatusRouteField -Record $Reservation -Name 'Decision')
    switch -CaseSensitive ($decision) {
        'reserved' {
            if ($null -ne $Launch -and [bool](Get-StatusRouteField -Record $Launch -Name 'Launched')) {
                return (& $reply 202 ([ordered]@{ ok = $true; action = 'queued'; operationId = $OperationId; stateUrl = $StateUrl }) '' $null)
            }
            $launchReason = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Launch -Name 'Reason')
            return (& $reply 503 ([ordered]@{ ok = $false; reason = 'launcher_failed'; operationId = $OperationId; stateUrl = $StateUrl }) `
                    'status.api_worker_launcher_failed' @{ reason = $(if ($launchReason) { $launchReason } else { 'launcher_failed' }) })
        }
        'busy' {
            $activeKind = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Reservation -Name 'ActiveKind')
            if (@('host_refresh', 'start_cycle') -cnotcontains $activeKind) { $activeKind = 'host_refresh' }
            $activeRequestId = [string](Get-StatusRouteField -Record $Reservation -Name 'ActiveRequestId')
            if ($activeKind -ceq 'start_cycle') {
                return (& $reply 409 ([ordered]@{ ok = $false; reason = 'busy'; activeKind = 'start_cycle'; activeRequestId = $activeRequestId; stateUrl = $StateUrl }) `
                        'status.api_another_start_cycle_request_is_in_progress_3f51d139' $null)
            }
            return (& $reply 409 ([ordered]@{ ok = $false; reason = 'busy'; activeKind = 'host_refresh'; activeRequestId = $activeRequestId; stateUrl = $RefreshStateUrl }) `
                    'status.api_host_refresh_busy' $null)
        }
        'unavailable' {
            $reservationReason = ConvertTo-StatusRouteWireToken -Value (Get-StatusRouteField -Record $Reservation -Name 'Reason')
            return (& $reply 503 ([ordered]@{ ok = $false; reason = 'admission_unavailable' }) `
                    'status.api_admission_unavailable' @{ reason = $(if ($reservationReason) { $reservationReason } else { 'admission_unavailable' }) })
        }
    }
    return (& $reply 500 ([ordered]@{ ok = $false; reason = 'internal_error' }) 'status.api_internal_error' $null)
}

function Test-StatusWorkerArgument {
    <#
    .SYNOPSIS
        Check a worker argument vector against the script it launches, using
        PowerShell's own parameter resolution.
    .DESCRIPTION
        A script launched with pwsh -File binds its arguments after this
        process has let go of them, so a misspelled name that the script
        would absorb or refuse must be caught here. Each -Name token is
        resolved with the script's ResolveParameter and must name one of the
        script's own parameters exactly: no abbreviation, no alias, no common
        parameter, no repetition. A switch takes no value; every other
        parameter takes exactly one non-empty value free of NUL, CR and LF.
        Positional values are refused.
    .PARAMETER ScriptPath
        The worker script.
    .PARAMETER ArgumentList
        The script arguments, one token per element.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason ''|script_missing|unknown_parameter|
        ambiguous_parameter|abbreviated_parameter|missing_value|invalid_value;
        Parameter }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$ArgumentList
    )
    $verdict = { param([string]$Reason, [string]$Parameter)
        [pscustomobject]@{ Valid = ([string]::IsNullOrEmpty($Reason)); Reason = $Reason; Parameter = $Parameter }
    }
    $info = [System.IO.FileInfo]::new($ScriptPath)
    if (-not $info.Exists) { return (& $verdict 'script_missing' '') }
    $stamp = $info.LastWriteTimeUtc.Ticks
    $cached = $script:StatusWorkerCommandCache[$info.FullName]
    $command = $null
    if ($cached -and $cached.Stamp -eq $stamp) {
        $command = $cached.Command
    } else {
        try {
            $command = Get-Command -CommandType ExternalScript -Name $info.FullName -ErrorAction Stop
        } catch {
            return (& $verdict 'script_missing' '')
        }
        $script:StatusWorkerCommandCache[$info.FullName] = @{ Stamp = $stamp; Command = $command }
    }
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ArgumentList = @($ArgumentList)
    $index = 0
    while ($index -lt $ArgumentList.Count) {
        $token = [string]$ArgumentList[$index]
        if (-not $token.StartsWith('-') -or $token.Length -lt 2) { return (& $verdict 'invalid_value' $token) }
        $name = $token.Substring(1)
        if ($name.Contains(':')) { return (& $verdict 'invalid_value' $name) }
        $metadata = $null
        try {
            $metadata = $command.ResolveParameter($name)
        } catch {
            $inner = $_.Exception.InnerException
            $errorId = if ($inner -is [System.Management.Automation.ParameterBindingException]) { [string]$inner.ErrorId } else { '' }
            if ($errorId -eq 'AmbiguousParameter') { return (& $verdict 'ambiguous_parameter' $name) }
            return (& $verdict 'unknown_parameter' $name)
        }
        if ($null -eq $metadata) { return (& $verdict 'unknown_parameter' $name) }
        if ($common -contains $metadata.Name) { return (& $verdict 'unknown_parameter' $name) }
        if (-not [string]::Equals($metadata.Name, $name, [StringComparison]::OrdinalIgnoreCase)) {
            return (& $verdict 'abbreviated_parameter' $name)
        }
        if (-not $seen.Add($metadata.Name)) { return (& $verdict 'invalid_value' $name) }
        $index++
        if ($metadata.SwitchParameter) {
            if ($index -lt $ArgumentList.Count -and -not ([string]$ArgumentList[$index]).StartsWith('-')) {
                return (& $verdict 'invalid_value' $name)
            }
            continue
        }
        if ($index -ge $ArgumentList.Count) { return (& $verdict 'missing_value' $name) }
        $value = [string]$ArgumentList[$index]
        if ([string]::IsNullOrEmpty($value) -or $value.StartsWith('-')) { return (& $verdict 'missing_value' $name) }
        if ($value.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0) { return (& $verdict 'invalid_value' $name) }
        $index++
    }
    return (& $verdict '' '')
}

function Get-StatusWorkerDirectory {
    <#
    .SYNOPSIS
        The private directory a detached listener worker writes its streams,
        state and result into, with its empty stdin sentinel.
    .DESCRIPTION
        Resolved through Get-YurunaPrivateStatePath, which creates the
        subdirectory owner-only and refuses a link, a foreign owner or a
        served tree, so worker transcripts never land where the listener
        serves them. The empty stdin sentinel is what a Windows launch
        redirects stdin from (NUL is not a path Start-Process accepts).
        Transcripts beyond the retention count are pruned, newest kept.
    .PARAMETER Name
        host-diagnostic or start-cycle.
    .PARAMETER RetainTranscript
        How many .out and how many .err files to keep.
    .PARAMETER ServedRoot
        Directories an HTTP server exposes; see Get-YurunaPrivateStateRoot.
    .OUTPUTS
        [pscustomobject] @{ Resolved; Path; StdInPath; Reason }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('host-diagnostic', 'start-cycle')][string]$Name,
        [ValidateRange(1, 100)][int]$RetainTranscript = 10,
        [string[]]$ServedRoot
    )
    $pathArguments = @{ Name = 'stdin.empty'; Subdirectory = $Name }
    if ($PSBoundParameters.ContainsKey('ServedRoot')) { $pathArguments.ServedRoot = $ServedRoot }
    if (-not $PSCmdlet.ShouldProcess($Name, (Format-YurunaOperatorMessage -Key 'runner.status_worker_directory_prepare_action'))) {
        $pathArguments.NoCreate = $true
    }
    $leaf = Get-YurunaPrivateStatePath @pathArguments
    if (-not $leaf.Resolved) {
        return [pscustomobject]@{ Resolved = $false; Path = $null; StdInPath = $null; Reason = [string]$leaf.Reason }
    }
    $directory = Split-Path -Parent $leaf.Path
    if ($pathArguments.ContainsKey('NoCreate')) {
        return [pscustomobject]@{ Resolved = $true; Path = $directory; StdInPath = $leaf.Path; Reason = 'ok' }
    }
    try {
        if (-not [System.IO.File]::Exists($leaf.Path)) { [System.IO.File]::WriteAllBytes($leaf.Path, [byte[]]@()) }
    } catch {
        return [pscustomobject]@{ Resolved = $false; Path = $null; StdInPath = $null; Reason = 'create-failed' }
    }
    foreach ($pattern in @('*.out', '*.err')) {
        try {
            $files = @([System.IO.DirectoryInfo]::new($directory).GetFiles($pattern) |
                    Where-Object { -not $_.LinkTarget } |
                    Sort-Object -Property LastWriteTimeUtc -Descending)
            foreach ($stale in @($files | Select-Object -Skip $RetainTranscript)) {
                try { $stale.Delete() } catch { Write-Verbose "Get-StatusWorkerDirectory: could not prune $($stale.Name): $($_.Exception.Message)" }
            }
        } catch {
            Write-Verbose "Get-StatusWorkerDirectory: transcript listing failed: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Resolved = $true; Path = $directory; StdInPath = $leaf.Path; Reason = 'ok' }
}

function Read-StatusWorkerState {
    <#
    .SYNOPSIS
        A worker's state record, or $null when it is missing, empty, too
        large, not a schema-1 object or not JSON.
    .PARAMETER Path
        The state file.
    .OUTPUTS
        [hashtable] or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $info = [System.IO.FileInfo]::new($Path)
        if (-not $info.Exists -or $info.Length -le 0 -or $info.Length -gt $script:StatusWorkerStateMaxBytes -or $info.LinkTarget) { return $null }
        $text = [System.IO.File]::ReadAllText($Path)
        $state = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
        if ($state -isnot [hashtable]) { return $null }
        if ([string]$state['schemaVersion'] -ne '1') { return $null }
        return $state
    } catch {
        Write-Verbose "Read-StatusWorkerState: $Path is unreadable: $($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-StatusRouteUtc {
    <#
    .SYNOPSIS
        A round-trip ISO-8601 instant as UTC, or $null.
    #>
    [CmdletBinding()]
    [OutputType([Nullable[DateTime]])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Get-HostDiagnosticRouteState {
    <#
    .SYNOPSIS
        What /control/host-diagnostic does now: serve a recent report, serve a
        recent failure, answer pending, or spawn a new run.
    .DESCRIPTION
        The diagnostic runs in a detached single-flight worker, so a request
        never waits for it. A completed run younger than the cooldown is
        served as is; a failed run inside the cooldown is served as its
        failure. A completed run whose report cannot be served -- larger than
        MaxServeBytes (report_too_large), or missing or a link
        (report_unavailable) -- is served as that failure too: it is still the
        run the caller asked for, and answering spawn instead would start a
        new run on every poll until the cooldown passed. A run whose state
        says running is pending until its own deadline plus a grace, after
        which it is presumed dead. A spawn the listener issued inside the
        grace, with no state from that run yet, is also pending, which is
        what throttles a caller that polls faster than a worker starts.
    .PARAMETER WorkDirectory
        The worker directory.
    .PARAMETER NowUtc
        The current instant.
    .PARAMETER CooldownSeconds
        How long a finished run is reused.
    .PARAMETER SpawnGraceSeconds
        How long a spawn or an overdue running state is still presumed alive.
    .PARAMETER LastSpawnUtc
        When this listener last spawned a run.
    .PARAMETER LastSpawnRunId
        The run id of that spawn.
    .PARAMETER MaxServeBytes
        The largest result served.
    .OUTPUTS
        [pscustomobject] @{ Action serve|serve_failure|pending|spawn; RunId;
        ResultPath; FailureReason }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorkDirectory,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [ValidateRange(1, 3600)][int]$CooldownSeconds = 15,
        [ValidateRange(1, 3600)][int]$SpawnGraceSeconds = 15,
        [Nullable[DateTime]]$LastSpawnUtc,
        [AllowEmptyString()][string]$LastSpawnRunId = '',
        [ValidateRange(1, 67108864)][long]$MaxServeBytes = 4194304
    )
    $now = $NowUtc.ToUniversalTime()
    $decision = { param([string]$Action, [string]$RunId, [string]$ResultPath, [string]$FailureReason)
        [pscustomobject]@{ Action = $Action; RunId = $RunId; ResultPath = $ResultPath; FailureReason = $FailureReason }
    }
    $state = Read-StatusWorkerState -Path (Join-Path $WorkDirectory 'state.json')
    $stateRunId = if ($state) { [string]$state['runId'] } else { '' }
    if ($state) {
        $phase = [string]$state['phase']
        $completed = ConvertTo-StatusRouteUtc -Value $state['completedUtc']
        if ($phase -ceq 'completed' -and $null -ne $completed -and ($now - $completed).TotalSeconds -lt $CooldownSeconds -and
            ($now - $completed).TotalSeconds -ge -60) {
            $resultPath = Join-Path $WorkDirectory 'result.txt'
            $result = [System.IO.FileInfo]::new($resultPath)
            if (-not $result.Exists -or $result.LinkTarget) {
                return (& $decision 'serve_failure' $stateRunId '' 'report_unavailable')
            }
            if ($result.Length -gt $MaxServeBytes) {
                return (& $decision 'serve_failure' $stateRunId '' 'report_too_large')
            }
            return (& $decision 'serve' $stateRunId $resultPath '')
        }
        if ($phase -ceq 'failed' -and $null -ne $completed -and ($now - $completed).TotalSeconds -lt $CooldownSeconds -and
            ($now - $completed).TotalSeconds -ge -60) {
            $failure = ConvertTo-StatusRouteWireToken -Value $state['reason']
            return (& $decision 'serve_failure' $stateRunId '' $(if ($failure) { $failure } else { 'failed' }))
        }
        if ($phase -ceq 'running') {
            $deadline = ConvertTo-StatusRouteUtc -Value $state['deadlineUtc']
            if ($null -ne $deadline -and $now -lt $deadline.AddSeconds($SpawnGraceSeconds)) {
                return (& $decision 'pending' $stateRunId '' '')
            }
        }
    }
    if ($null -ne $LastSpawnUtc -and $LastSpawnRunId -and $stateRunId -cne $LastSpawnRunId) {
        $age = ($now - ([DateTime]$LastSpawnUtc).ToUniversalTime()).TotalSeconds
        if ($age -ge 0 -and $age -lt $SpawnGraceSeconds) {
            return (& $decision 'pending' $LastSpawnRunId '' '')
        }
    }
    return (& $decision 'spawn' '' '' '')
}

function New-StatusOperationId {
    <#
    .SYNOPSIS
        A new operation or request id in the canonical lowercase 8-4-4-4-12
        form every refresh channel uses.
    .OUTPUTS
        [string]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new identifier; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [Guid]::NewGuid().ToString('D')
}

function Get-StatusRuntimeKey {
    <#
    .SYNOPSIS
        The first sixteen hex characters of the SHA-256 of the canonical
        runtime directory, so per-runtime private files of two checkouts on one
        host never collide.
    .DESCRIPTION
        The path is lowercased first on macOS and Windows, whose default file
        systems fold case, so two spellings of one directory give one key.
    .PARAMETER RuntimeDir
        The runtime directory.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $canonical = Resolve-YurunaCanonicalPath -Path $RuntimeDir
    $path = if ($canonical.Resolved) { [string]$canonical.Path } else { [System.IO.Path]::GetFullPath($RuntimeDir) }
    $path = $path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($IsMacOS -or $IsWindows) { $path = $path.ToLowerInvariant() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($path))
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()).Substring(0, 16)
}

function Test-StatusPathOutsideServedRoot {
    <#
    .SYNOPSIS
        True when a path lies outside every served directory.
    .DESCRIPTION
        The listener serves the status, runtime and log directories and the
        whole repository by deny-list, so a private record written under any
        of them is public unless its name happens to be denied. Both sides
        are compared canonically (links resolved), and the containment test
        is separator-anchored so a sibling that shares a prefix is not
        mistaken for a child.
    .PARAMETER Path
        The candidate path.
    .PARAMETER ServedRoot
        The served directories.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$ServedRoot
    )
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $resolve = {
        param([string]$Candidate)
        $full = [System.IO.Path]::GetFullPath($Candidate)
        $canonical = Resolve-YurunaCanonicalPath -Path $full
        $value = if ($canonical.Resolved) { [string]$canonical.Path } else { $full }
        $value.TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $target = & $resolve $Path
    foreach ($root in @($ServedRoot)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootPath = & $resolve $root
        if ([string]::Equals($target, $rootPath, $comparison)) { return $false }
        if ($target.StartsWith($rootPath + $separator, $comparison)) { return $false }
    }
    return $true
}

function Get-StatusServerOwnership {
    <#
    .SYNOPSIS
        Who owns the status service a pidfile names: this service, someone
        else, nobody, or unknown.
    .DESCRIPTION
        The refresh-safe start acts on this and never on a looser signal. The
        process-identity classifier is used when it is loaded; otherwise the
        pidfile is read here: an unreadable or malformed file is Unknown, a
        PID with no live process is DeadOrRecycled, and a live process is
        AliveOwned only when Test-PidFileIdentity confirms a PowerShell
        process that predates the pidfile. Unknown and AliveOther are never
        treated as absent: a start that proceeds past them could collide with
        a listener nobody identified.

        server.pid has no start-time sidecar, so the classifier can only date
        it by its write time, and by design a live process that started
        before the write is Unknown (no-exact-identity): a plausible start
        time never proves ownership on its own. Taken as final, that would
        read every healthy server as an unknown owner. Such a process is a
        candidate instead, confirmed by what it runs: a command line naming
        this runtime's generated server script is this service (AliveOwned,
        command-line), one naming anything else is not (AliveOther,
        other-command), and only an unreadable command line falls back to
        Test-PidFileIdentity. A process that started after the write is
        still DeadOrRecycled, as the classifier decided.
    .PARAMETER PidFile
        The service pidfile.
    .PARAMETER ExpectedScriptPath
        The generated server script the owner runs.
    .OUTPUTS
        [pscustomobject] @{ State AliveOwned|AliveOther|DeadOrRecycled|
        Unknown|Missing; Pid; StartTimeUnixMs; Reason }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [Parameter(Mandatory)][string]$ExpectedScriptPath
    )
    $record = { param([string]$State, [int]$ProcessId, [long]$StartTime, [string]$Reason)
        [pscustomobject]@{ State = $State; Pid = $ProcessId; StartTimeUnixMs = $StartTime; Reason = $Reason }
    }
    # The PowerShell check for a candidate whose command line cannot be read:
    # a process that predates the pidfile and runs PowerShell.
    $pidFileIdentity = { param([int]$ProcessId, [long]$StartTime)
        if (-not (Get-Command -Name 'Test-PidFileIdentity' -ErrorAction SilentlyContinue)) {
            return (& $record 'Unknown' $ProcessId $StartTime 'identity-unavailable')
        }
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return (& $record 'DeadOrRecycled' $ProcessId 0 'process-absent') }
        if (Test-PidFileIdentity -PidFile $PidFile -Process $process) {
            return (& $record 'AliveOwned' $ProcessId $StartTime 'pidfile-identity')
        }
        return (& $record 'AliveOther' $ProcessId $StartTime 'identity-mismatch')
    }
    $classifier = Get-Command -Name 'Get-YurunaRunnerRecordState' -ErrorAction SilentlyContinue
    if ($classifier) {
        try {
            $identity = Get-YurunaRunnerRecordState -PidFile $PidFile -MtimeIdentity -ExpectedScriptPath $ExpectedScriptPath
            $state = [string](Get-StatusRouteField -Record $identity -Name 'State')
            if (@('AliveOwned', 'AliveOther', 'DeadOrRecycled', 'Unknown', 'Missing') -cnotcontains $state) { $state = 'Unknown' }
            $identityPid = 0
            $null = [int]::TryParse([string](Get-StatusRouteField -Record $identity -Name 'Pid'), [ref]$identityPid)
            $identityStart = [long]0
            $null = [long]::TryParse([string](Get-StatusRouteField -Record $identity -Name 'LiveStartTimeUnixMs'), [ref]$identityStart)
            $identityReason = [string](Get-StatusRouteField -Record $identity -Name 'Reason')
            if ($state -ceq 'Unknown' -and $identityReason -ceq 'no-exact-identity' -and $identityPid -gt 0) {
                $row = Get-StatusRouteField -Record $identity -Name 'Row'
                $commandLine = [string](Get-StatusRouteField -Record $row -Name 'CommandLine')
                if ([string]::IsNullOrWhiteSpace($commandLine)) {
                    return (& $pidFileIdentity $identityPid $identityStart)
                }
                $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
                if ($commandLine.IndexOf([System.IO.Path]::GetFullPath($ExpectedScriptPath), $comparison) -ge 0) {
                    return (& $record 'AliveOwned' $identityPid $identityStart 'command-line')
                }
                return (& $record 'AliveOther' $identityPid $identityStart 'other-command')
            }
            return (& $record $state $identityPid $identityStart $identityReason)
        } catch {
            return (& $record 'Unknown' 0 0 'classifier-failed')
        }
    }
    $info = [System.IO.FileInfo]::new($PidFile)
    if (-not $info.Exists) { return (& $record 'Missing' 0 0 'no-pidfile') }
    if ($info.LinkTarget -or $info.Length -gt 64) { return (& $record 'Unknown' 0 0 'pidfile-malformed') }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($PidFile).Trim() } catch { return (& $record 'Unknown' 0 0 'pidfile-unreadable') }
    $recordedPid = 0
    if ($text -notmatch '\A[1-9][0-9]{0,9}\z' -or -not [int]::TryParse($text, [ref]$recordedPid)) {
        return (& $record 'Unknown' 0 0 'pidfile-malformed')
    }
    $process = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
    if (-not $process) { return (& $record 'DeadOrRecycled' $recordedPid 0 'process-absent') }
    $startTime = [long]0
    try { $startTime = [DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds() } catch { $startTime = [long]0 }
    return (& $pidFileIdentity $recordedPid $startTime)
}

function Test-StatusRouteCommandSet {
    <#
    .SYNOPSIS
        Whether every command a route calls resolves, with every parameter the
        route passes.
    .DESCRIPTION
        A route that calls a command by a parameter its current definition
        does not declare fails with a binding error on every request. Checking
        the names up front lets the route refuse with a documented reply
        instead, and lets the capability summary stop advertising a route
        that cannot run.
    .PARAMETER Requirement
        Command name -> the parameter names the route passes.
    .OUTPUTS
        [pscustomobject] @{ Ready; Missing [string[]] } where Missing names
        each absent command or Command -Parameter pair.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Requirement)
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Requirement.Keys | Sort-Object)) {
        $command = Get-Command -Name ([string]$name) -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { $missing.Add([string]$name); continue }
        foreach ($parameter in @($Requirement[$name])) {
            if (-not $parameter) { continue }
            if (-not $command.Parameters.ContainsKey([string]$parameter)) { $missing.Add("$name -$parameter") }
        }
    }
    return [pscustomobject]@{ Ready = ($missing.Count -eq 0); Missing = [string[]]$missing.ToArray() }
}

function Get-StartCycleRunnerDecision {
    <#
    .SYNOPSIS
        Whether a start-cycle may spawn a runner, from the runner's state
        observed after cleanup.
    .DESCRIPTION
        Accepts either the process-identity record (State AliveOwned,
        AliveOther, DeadOrRecycled, Unknown, Missing) or the older pidfile
        classification (status None, Self, Stale, OtherRunner). Only positive
        absence authorizes a spawn: a missing pidfile, or a recorded process
        that is positively gone. A live runner is left running (the restart
        request wakes it). Anything unproven -- an unreadable pidfile, a live
        process that cannot be identified, this process -- spawns nothing,
        because a second runner beside a live one is the failure this avoids.
    .PARAMETER State
        The runner state record.
    .PARAMETER ProcessAlive
        For the older classification only: whether the recorded PID is alive
        at the time of the call.
    .OUTPUTS
        [pscustomobject] @{ Decision spawn|restarted|unknown; Reason }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$State,
        [Nullable[bool]]$ProcessAlive
    )
    $decision = { param([string]$Decision, [string]$Reason) [pscustomobject]@{ Decision = $Decision; Reason = $Reason } }
    if ($null -eq $State) { return (& $decision 'unknown' 'runner_unknown') }
    $identity = [string](Get-StatusRouteField -Record $State -Name 'State')
    if ($identity) {
        switch -CaseSensitive ($identity) {
            'AliveOwned' { return (& $decision 'restarted' '') }
            'Missing' { return (& $decision 'spawn' '') }
            'DeadOrRecycled' { return (& $decision 'spawn' '') }
        }
        return (& $decision 'unknown' 'runner_unknown')
    }
    $status = [string](Get-StatusRouteField -Record $State -Name 'status')
    $recordedPid = 0
    $null = [int]::TryParse([string](Get-StatusRouteField -Record $State -Name 'pid'), [ref]$recordedPid)
    switch -CaseSensitive ($status) {
        'OtherRunner' { return (& $decision 'restarted' '') }
        'None' { return (& $decision 'spawn' '') }
        'Stale' {
            if ($recordedPid -gt 0 -and $ProcessAlive -eq $false) { return (& $decision 'spawn' '') }
            return (& $decision 'unknown' 'runner_unknown')
        }
    }
    return (& $decision 'unknown' 'runner_unknown')
}

function Get-StartCycleRunnerArgument {
    <#
    .SYNOPSIS
        The runner arguments a start-cycle spawn reuses from the recorded
        launch, as one token per element.
    .DESCRIPTION
        A runner started with a custom configuration would otherwise come back
        on the defaults when an operator starts a cycle from the page, and a
        different configuration is a different lab. Only the options the
        operator bound explicitly are forwarded, in a fixed order: ConfigPath,
        NoGitPull, NoStatusService, NoConfigGate, CycleDelaySeconds and
        logLevel. A value that is not a plain scalar, or a string carrying a
        line break, stops the conversion and nothing is emitted; the caller
        then validates the vector against the runner script itself.
    .PARAMETER Record
        The launch record payload (parameters and explicitlyBound).
    .OUTPUTS
        [string] elements; capture with @().
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Record)
    if ($null -eq $Record) { return }
    $parameters = Get-StatusRouteField -Record $Record -Name 'parameters'
    $bound = @(Get-StatusRouteField -Record $Record -Name 'explicitlyBound' | ForEach-Object { [string]$_ })
    if ($null -eq $parameters) { return }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('ConfigPath', 'NoGitPull', 'NoStatusService', 'NoConfigGate', 'CycleDelaySeconds', 'logLevel')) {
        if ($bound -notcontains $name) { continue }
        $value = Get-StatusRouteField -Record $parameters -Name $name
        if ($null -eq $value) { continue }
        switch ($name) {
            { $_ -in @('NoGitPull', 'NoStatusService', 'NoConfigGate') } {
                if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
                    if ([bool]$value) { $tokens.Add("-$name") }
                    continue
                }
                return
            }
            'CycleDelaySeconds' {
                $number = 0
                if (-not [int]::TryParse([string]$value, [ref]$number) -or $number -lt 0) { return }
                $tokens.Add("-$name"); $tokens.Add([string]$number)
                continue
            }
            default {
                if ($value -isnot [string] -or [string]::IsNullOrEmpty($value) -or $value.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0) { return }
                $tokens.Add("-$name"); $tokens.Add($value)
            }
        }
    }
    foreach ($token in $tokens) { $token }
}

function Save-StatusLaunchOutcome {
    <#
    .SYNOPSIS
        Record the outcome of a worker launch the listener was admitted to
        make, trying once more when the record does not commit.
    .DESCRIPTION
        An admitted request or reservation carries a pending launch that
        names the listener as its requester, and only the listener can close
        it. Left pending, the listener being alive reads as a launch still in
        progress: the same request answers already-claimed with no worker
        behind it, every other request and every start-cycle answers busy,
        and a start-cycle reservation is never cleared at all (reservations
        are cleared by identity, not by age). So every path out of an
        admission -- launched, refused before the launch, or failed by an
        exception -- records started or launch-failed through here.

        Record writes the outcome and returns an object with Saved. It is
        called with the Argument table and the attempt number (1-based). An
        exception or a Saved that is not true counts as not committed; the
        next attempt waits for the admission lock again. The failures are
        returned for the caller to log: nothing else can be done from inside
        a request.
    .PARAMETER Record
        { param([hashtable]$Argument, [int]$Attempt) ... } returning an
        object with Saved.
    .PARAMETER Argument
        Values Record needs, passed explicitly rather than read from the
        caller's scope.
    .PARAMETER MaxAttempts
        How many times to try; 2 by default.
    .OUTPUTS
        [pscustomobject] @{ Saved; Attempts; Failure [string[]] }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][scriptblock]$Record,
        [hashtable]$Argument = @{},
        [ValidateRange(1, 5)][int]$MaxAttempts = 2
    )
    $failure = [System.Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $answer = @(& $Record $Argument $attempt) | Where-Object { $null -ne $_ } | Select-Object -Last 1
            if ([bool](Get-StatusRouteField -Record $answer -Name 'Saved')) {
                return [pscustomobject]@{ Saved = $true; Attempts = $attempt; Failure = [string[]]$failure.ToArray() }
            }
            $why = [string](Get-StatusRouteField -Record $answer -Name 'Reason')
            $failure.Add(('attempt {0}: not saved ({1})' -f $attempt, $(if ($why) { $why } else { 'no reason' })))
        } catch {
            $failure.Add(('attempt {0}: {1}: {2}' -f $attempt, $_.Exception.GetType().Name, $_.Exception.Message))
        }
    }
    return [pscustomobject]@{ Saved = $false; Attempts = $MaxAttempts; Failure = [string[]]$failure.ToArray() }
}

function Get-StatusWorkerTranscriptStem {
    <#
    .SYNOPSIS
        A transcript stem in a worker directory that no earlier launch's
        stdout or stderr file uses.
    .DESCRIPTION
        A request can be launched more than once under the same stem -- a
        retry after a failed launch, or a relaunch of a request whose worker
        died -- and the earlier launch's transcripts are the evidence of why
        it failed. The stem itself is returned while it is free; otherwise
        the first free <stem>.<n> for n = 2, 3, ..., and past MaxSuffix a
        timestamp suffix.
    .PARAMETER Directory
        The worker directory.
    .PARAMETER Stem
        The preferred stem, for example <requestId>.<attempt>.
    .PARAMETER MaxSuffix
        The largest numeric suffix tried.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')][string]$Stem,
        [ValidateRange(2, 1000)][int]$MaxSuffix = 99
    )
    for ($suffix = 1; $suffix -le $MaxSuffix; $suffix++) {
        $candidate = if ($suffix -eq 1) { $Stem } else { '{0}.{1}' -f $Stem, $suffix }
        $outPath = Join-Path $Directory "$candidate.out"
        $errPath = Join-Path $Directory "$candidate.err"
        if (-not [System.IO.File]::Exists($outPath) -and -not [System.IO.File]::Exists($errPath)) { return $candidate }
    }
    return ('{0}.{1}' -f $Stem, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Get-StartCycleRefusalReason {
    <#
    .SYNOPSIS
        The published start-cycle reason for a reservation the worker could
        not confirm.
    .DESCRIPTION
        Maps the reasons Confirm-HostRefreshStartCycleReservation returns:
          reservation-lost   reservation_lost -- the reservation is gone or
                             belongs to another generation
          admission-busy     busy -- another operation held the admission
                             lock for the whole wait
          anything else      internal_error -- the lifetime lock was not
                             held, the journal or private state could not be
                             read or written, or the confirmation returned
                             nothing
        A refresh cannot become active while the reservation is held (its
        admission answers busy), so no reason means "a refresh took over".
    .PARAMETER ConfirmReason
        The Reason of the confirmation, or '' when it returned nothing.
    .OUTPUTS
        [string] reservation_lost | busy | internal_error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$ConfirmReason)
    switch -CaseSensitive ([string]$ConfirmReason) {
        'reservation-lost' { return 'reservation_lost' }
        'admission-busy' { return 'busy' }
    }
    return 'internal_error'
}

Export-ModuleMember -Function New-StatusBoundedBodyRead, Update-StatusBoundedBodyRead, Get-StatusBoundedBodyReadWait,
    Close-StatusBoundedBodyRead, Test-HostRefreshContentType, ConvertFrom-HostRefreshRequestBody, Get-HostRefreshControlSummary,
    Get-HostRefreshAdmissionReply, Get-StartCycleAdmissionReply, Test-StatusWorkerArgument, Get-StatusWorkerDirectory,
    Get-HostDiagnosticRouteState, Read-StatusWorkerState, New-StatusOperationId, Get-StatusRuntimeKey,
    Test-StatusPathOutsideServedRoot, Get-StatusServerOwnership, Test-StatusRouteCommandSet,
    Get-StartCycleRunnerDecision, Get-StartCycleRunnerArgument, Save-StatusLaunchOutcome, Get-StatusWorkerTranscriptStem,
    Get-StartCycleRefusalReason
