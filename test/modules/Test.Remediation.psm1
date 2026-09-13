<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42bd6583-4d45-42df-b3b7-3411df4c5af9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna remediation autonomous failure-class
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
    Failure-class-to-recovery dispatcher. The keystone of autonomous
    self-heal: reads last_failure.json, routes on `failureClass`, and
    returns an actionable recommendation produced by the handler
    registered for that class.

.DESCRIPTION
    The FailureClass enum (Test.SequenceAction.psm1) classifies every
    handler's failure mode. Without this dispatcher nothing consumes
    the enum -- an operator (or a future autonomous loop) has to grep
    the free-text error and guess what to do. This dispatcher closes
    the loop:

      1. Invoke-Remediation reads last_failure.json from $YURUNA_LOG_DIR
         (or an explicit path).
      2. Looks up a registered handler for the failure's `failureClass`.
      3. Calls the handler with the failure payload + a small context
         (vmName, guestKey, hostType pulled from the payload).
      4. Returns the handler's recommendation hashtable so the caller
         can act on it.

    POLICY: handlers are ADVISORY by design. They return what the
    caller / operator SHOULD do, not what they DID. A future iteration
    can flip individual handlers to act directly (calling
    Repair-VncConnection, Wait-SshReady, Restore-VMDiskSnapshot) once
    the autonomous loop's blast radius is bounded. Today the safer
    contract is: dispatcher tells you the next step; caller decides.

    Built-in handlers cover every value in the FailureClass enum so
    last_failure.json is never observed without a routing target.
    External modules can override or extend via Register-RecoveryHandler.

    The registry uses the shared New-YurunaRegistry primitive so it
    appears in Get-YurunaRegistryDirectory alongside SequenceAction /
    HostIO / OcrProvider -- autonomous tooling enumerates every
    routing surface through one API.

    Every dispatch emits a `remediation_recommended` NDJSON event
    carrying (failureClass, recommendation, severity, handledBy) so
    a streaming consumer follows what the dispatcher chose without
    parsing the recommendation object.
#>

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global
# Test.StateFile gives the atomic, no-BOM JSON writer used to persist the
# recommendation as a durable cycle artifact. Imported here (not guarded at
# the call site) so the write-back is always available wherever the
# dispatcher runs.
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking -Global

$script:RemediationRegistry = New-YurunaRegistry -Name 'Remediation' -AnchorVar 'YurunaRemediationHandlers' -Comparer 'OrdinalIgnoreCase'

# Recommendation taxonomy. The handler-returned hashtable's
# `Recommendation` field MUST be one of these so a streaming consumer
# can pivot on a small finite set instead of free-text matching.
$script:RecommendationEnum = @(
    'retry_immediately',
    'retry_with_backoff',
    'restart_from_snapshot',
    'reconnect',
    'pause_and_inspect',
    'operator_intervention_required',
    'escalate'
)

# --- REGION: Auto-remediation policy
#
# WHICH failures the runner may retry without an operator, and HOW MANY times.
# The list lives here, beside the registry that classifies failures, because
# keeping it beside the registry prevents the set that CLASSIFIES a failure
# from drifting away from the set that may ACT on one. In particular, all
# classes whose handlers recommend a harmless retry must be represented here.
#
# A class earns a place here only when retrying is the whole repair and a
# repeat is harmless. Everything else -- a bad plan, a missing payload, an
# expired vault, a full disk -- stays advisory, because retrying it either
# cannot help or destroys the evidence an operator needs.
#
# credential_expired is deliberately absent: an expired vault stays advisory.
# No production path calls the available re-authentication primitive, and the
# class's registered handler asks for an operator rather than a retry.
# Membership does not dispatch a repair in any case; its only
# effect is to end the post-failure pause early, which is the wrong answer for
# a credential nobody has fixed yet.
$script:AutoRemediationAllowList = [ordered]@{
    # The transient four: the condition is external and usually gone by the
    # next attempt, so the retry IS the repair.
    'wait_timeout'           = 'a step exceeded its budget; the next attempt starts from a clean cycle'
    'network_timeout'        = 'a transport stall, not a wrong answer'
    'ip_not_discovered'      = 'the guest had no lease YET; a later cycle usually finds one'
    'host_network_degraded'  = 'the host lost its own path; nothing in the cycle can fix it, and it recovers'
    # Backed by a Repair-* primitive that is safe to run twice.
    'instrumentation_failure' = 'Repair-ScreenshotRing restores capture; a repeat is idempotent'
    'host_io_blocked'         = 'Repair-VncConnection reconnects the console; reconnecting twice is harmless'
}

function Get-AutoRemediationAllowList {
    <#
    .SYNOPSIS
        The failure classes the runner may retry unattended, each with the
        reason it qualifies.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return $script:AutoRemediationAllowList
}

function Test-AutoRemediationAllowed {
    <#
    .SYNOPSIS
        Whether this failure class may be retried without an operator.
    .DESCRIPTION
        The single question the outer loop asks before ending a failure pause
        early. An unknown or unregistered class answers $false: a class nobody
        has classified is exactly the one that should stop and be looked at.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$FailureClass)
    if ([string]::IsNullOrWhiteSpace($FailureClass)) { return $false }
    return $script:AutoRemediationAllowList.Contains($FailureClass)
}

function Register-RecoveryHandler {
    <#
    .SYNOPSIS
        Bind a handler scriptblock to a failureClass.
    .DESCRIPTION
        The handler receives a single hashtable argument with two keys:
          Failure  - the parsed last_failure.json payload
          Context  - shorthand pulled from the payload:
                       vmName, guestKey, hostType, stepNumber,
                       actionVerb, severity, suggestedRecoveries
        and MUST return a hashtable with at minimum:
          Recommendation  one of the values in $script:RecommendationEnum
          Rationale       short human-readable string
        Optional fields:
          Actions         [string[]] ordered ops the caller should run
          HandledBy       handler identifier (auto-set from FailureClass)
          AutoApply       [bool] true when the handler also performed
                          the action (e.g. an integration that flips
                          from advisory to active mode)
    .PARAMETER FailureClass
        Value from the canonical FailureClass enum (see
        Test.SequenceAction.psm1 ValidateSet). Registering for a
        value outside the enum is allowed -- the enum is enforced at
        emit, not at registration -- but a streaming consumer that
        doesn't know about the new class will fall back to 'unknown'.
    .PARAMETER Handler
        Scriptblock signature: `param([hashtable]$ctx) ...` returning
        the recommendation hashtable.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter',
        '', Justification = 'Parameters are stored in the registry, not used by this function body.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Registry mutation; the rule is satisfied by the registry primitive.')]
    param(
        [Parameter(Mandatory)][string]$FailureClass,
        [Parameter(Mandatory)][scriptblock]$Handler
    )
    & $script:RemediationRegistry.Register $FailureClass $Handler
}

function Get-RecoveryHandler {
    <#
    .SYNOPSIS
        Returns the scriptblock registered for a failureClass, or $null.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)][string]$FailureClass)
    return (& $script:RemediationRegistry.Get $FailureClass)
}

function Get-RegisteredFailureClass {
    <#
    .SYNOPSIS
        Names of every failureClass with a registered handler.
    .DESCRIPTION
        Lets a startup capability matrix flag a gap (an enum value
        with no handler) before the cycle hits one and falls back to
        'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:RemediationRegistry.Store[0].Keys)
}

function Get-RecoveryRecommendationName {
    <#
    .SYNOPSIS
        The canonical recovery-recommendation vocabulary. Every handler's
        `Recommendation` and every verb's SuggestedRecoveries hint must be one
        of these, so the dispatch contract type-checks end to end -- a verb
        suggesting a token the dispatcher can't route on is a contract gap.
    #>
    [OutputType([string[]])]
    param()
    return $script:RecommendationEnum
}

function Clear-RecoveryHandler {
    <#
    .SYNOPSIS
        Drop every registration. Tests only; production code relies on
        -Force re-import to refresh.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.Remediation registry', 'Clear all handlers')) {
        & $script:RemediationRegistry.Clear
        Register-BuiltinRecoveryHandler
    }
}

function Invoke-Remediation {
    <#
    .SYNOPSIS
        Read last_failure.json and dispatch to the registered handler
        for its failureClass.
    .PARAMETER LastFailurePath
        Path to last_failure.json. Defaults to
        "$env:YURUNA_LOG_DIR/last_failure.json".
    .PARAMETER FailureRecord
        Direct injection of a pre-parsed failure hashtable. Lets a
        caller route on a failure observed in-memory (e.g. the cycle
        engine right after emitting last_failure.json) without a
        re-read.
    .OUTPUTS
        Hashtable with: FailureClass, Severity, Recommendation, Actions,
        Rationale, HandledBy, AutoApply, Source (file path or '(inline)').
        Returns $null when there's no failure record to act on.

        Side effect: writes a durable last_remediation.json next to the
        failure record (or in $env:YURUNA_LOG_DIR) so the dispatcher's
        DECISION persists with the cycle, not only on the transient NDJSON
        event. The write is advisory-only -- it records what SHOULD happen,
        it never performs the recommended action.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the $global:__YurunaRunId cycle-identity channel to stamp the persisted record; never assigns it.')]
    param(
        [string]$LastFailurePath,
        [hashtable]$FailureRecord
    )
    $source = '(inline)'
    if (-not $FailureRecord) {
        if (-not $LastFailurePath) {
            $baseDir = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { $null }
            if (-not $baseDir) {
                Write-Verbose "Invoke-Remediation: no YURUNA_LOG_DIR and no -LastFailurePath; nothing to do."
                return $null
            }
            $LastFailurePath = Join-Path $baseDir 'last_failure.json'
        }
        if (-not (Test-Path -LiteralPath $LastFailurePath)) {
            Write-Verbose "Invoke-Remediation: $LastFailurePath not present; nothing to do."
            return $null
        }
        $source = $LastFailurePath
        try {
            $raw = Get-Content -Raw -LiteralPath $LastFailurePath -ErrorAction Stop
            $FailureRecord = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            # Valid JSON that is not an object still parses: a bare string / number
            # / array / bool, or most subtly a literal `null`. The [hashtable]
            # parameter type coerces-and-throws for the scalar/array cases, but a
            # JSON `null` assigns cleanly as $null and would then hit a null-method
            # exception at the first .Contains() below (past this try/catch).
            # Validate explicitly so any non-object routes to the same parse-error
            # fallback rather than relying on the coercion quirk.
            if ($FailureRecord -isnot [System.Collections.IDictionary]) {
                $gotType = if ($null -eq $FailureRecord) { 'null' } else { $FailureRecord.GetType().Name }
                throw "last_failure.json parsed to a non-object ($gotType); expected a JSON object."
            }
        } catch {
            Write-Warning "Invoke-Remediation: could not parse $LastFailurePath ($($_.Exception.Message))"
            return @{
                FailureClass   = 'unknown'
                Severity       = 'unknown'
                Recommendation = 'operator_intervention_required'
                Actions        = @('inspect last_failure.json manually', "verify $LastFailurePath is valid JSON")
                Rationale      = "last_failure.json could not be parsed: $($_.Exception.Message)"
                HandledBy      = '(parse-error fallback)'
                AutoApply      = $false
                Source         = $LastFailurePath
            }
        }
    }
    $failureClass = if ($FailureRecord.Contains('failureClass')) { [string]$FailureRecord['failureClass'] } else { 'unknown' }
    if (-not $failureClass) { $failureClass = 'unknown' }
    $severity = if ($FailureRecord.Contains('severity')) { [string]$FailureRecord['severity'] } else { 'unknown' }
    $suggested = if ($FailureRecord.Contains('suggestedRecoveries')) { @($FailureRecord['suggestedRecoveries']) } else { @() }

    # Read a field from the record's top level, falling back to its nested
    # `context` block: last_failure.json keeps sequencePath / matchedFailurePattern
    # under context, while an inline engine record has them flat. One lookup
    # covers both shapes.
    $recField = {
        param($Name)
        if ($FailureRecord.Contains($Name) -and $FailureRecord[$Name]) { return $FailureRecord[$Name] }
        if ($FailureRecord.Contains('context') -and ($FailureRecord['context'] -is [System.Collections.IDictionary]) -and
            $FailureRecord['context'].Contains($Name) -and $FailureRecord['context'][$Name]) {
            return $FailureRecord['context'][$Name]
        }
        return $null
    }

    # causeDetail lives one level below context; give it its own reader rather
    # than widening $recField, whose two-level search would otherwise start
    # returning nested values for names that also exist at the top.
    $causeField = {
        param($Name)
        $ctxNode = if ($FailureRecord.Contains('context')) { $FailureRecord['context'] } else { $null }
        if ($ctxNode -is [System.Collections.IDictionary] -and $ctxNode.Contains('causeDetail') -and
            ($ctxNode['causeDetail'] -is [System.Collections.IDictionary]) -and $ctxNode['causeDetail'].Contains($Name)) {
            return $ctxNode['causeDetail'][$Name]
        }
        return 0
    }

    # Inner-cause routing. An exhausted `retry` reports the outer class
    # 'retry_exhausted', which masks the deepest verb's actionable cause the
    # record preserved in innerFailureClass. Route on the inner class when it is
    # present AND has its own registered handler, so the recommendation targets
    # the real failure instead of the generic retry wrapper. Severity /
    # suggestedRecoveries follow the routed class; the outer class is preserved as
    # $routedFromClass (surfaced as RoutedFromFailureClass / outerFailureClass) so
    # the audit trail still shows the masking.
    $routedFromClass = $null
    $innerClass = if ($FailureRecord.Contains('innerFailureClass') -and $FailureRecord['innerFailureClass']) { [string]$FailureRecord['innerFailureClass'] } else { '' }
    # Skip a self-equal inner class ($innerClass -ne $failureClass): routing to
    # the same class is a no-op that would only emit a misleading "routed" audit.
    if ($failureClass -eq 'retry_exhausted' -and $innerClass -and $innerClass -ne $failureClass -and (Get-RecoveryHandler -FailureClass $innerClass)) {
        $routedFromClass = $failureClass
        $failureClass    = $innerClass
        # Severity follows the routed class: use the recorded innerSeverity, else
        # 'unknown'. Never inherit the outer value -- it is the retry wrapper's
        # severity, not the inner cause's, so pairing it with the inner class
        # would desync the (class, severity) the consumer routes/gates on.
        $severity = if ($FailureRecord.Contains('innerSeverity') -and $FailureRecord['innerSeverity']) { [string]$FailureRecord['innerSeverity'] } else { 'unknown' }
        if ($FailureRecord.Contains('innerSuggestedRecoveries')) {
            $suggested = @($FailureRecord['innerSuggestedRecoveries'])
        }
    }

    $reproField   = & $recField 'repro'
    $reproCommand = if ($reproField -is [System.Collections.IDictionary] -and $reproField.Contains('command')) {
        [string]$reproField['command']
    } elseif ($FailureRecord.Contains('reproCommand')) {
        [string]$FailureRecord['reproCommand']
    } else { '' }

    $ctx = @{
        Failure = $FailureRecord
        Context = @{
            vmName               = if ($FailureRecord.Contains('vmName'))         { [string]$FailureRecord['vmName'] }       else { $null }
            guestKey             = if ($FailureRecord.Contains('guestKey'))       { [string]$FailureRecord['guestKey'] }     else { $null }
            hostType             = if ($FailureRecord.Contains('hostType'))       { [string]$FailureRecord['hostType'] }     else { $null }
            stepNumber           = if ($FailureRecord.Contains('stepNumber'))     { [int]$FailureRecord['stepNumber'] }      else { 0 }
            actionVerb           = if ($FailureRecord.Contains('actionVerb'))     { [string]$FailureRecord['actionVerb'] }   else { $null }
            severity             = $severity
            suggestedRecoveries  = $suggested
            failureClass         = $failureClass
            # Enriched routing context (forwarded so a handler can act/repro
            # without re-reading last_failure.json). Empty string, never $null,
            # so a handler can string-test without a null guard.
            outerFailureClass     = if ($routedFromClass) { $routedFromClass } else { '' }
            sequenceName          = [string](& $recField 'sequenceName')
            sequencePath          = [string](& $recField 'sequencePath')
            matchedFailurePattern = [string](& $recField 'matchedFailurePattern')
            innerFailureClass     = $innerClass
            reproCommand          = $reproCommand
            # causeDetail signals a handler needs to tell apart screens that look
            # identical in the class alone: how long the console content sat
            # unchanged, and whether an operator hold ended just before the step.
            # Zero when absent, so a handler can compare without a null guard.
            consoleStaticSeconds   = [int](& $causeField 'consoleStaticSeconds')
            # ...and whether that zero is a reading. A wait that confined its match
            # to the console tail never measures the console's shape and records
            # the field as null, which is not the same screen as one measured at
            # zero. The int above stays an int (handlers compare it without a null
            # guard); this carries the bit it cannot. A field missing entirely
            # reads through $causeField as 0, so it stays 'measured' and a record
            # without the field behaves exactly as it does today.
            consoleStaticMeasured  = ($null -ne (& $causeField 'consoleStaticSeconds'))
            pauseBeforeStepSeconds = [int](& $causeField 'pauseBeforeStepSeconds')
        }
    }
    $handler = Get-RecoveryHandler -FailureClass $failureClass
    if (-not $handler) {
        $handler = Get-RecoveryHandler -FailureClass 'unknown'
    }
    if (-not $handler) {
        return @{
            FailureClass   = $failureClass
            Severity       = $severity
            Recommendation = 'operator_intervention_required'
            Actions        = @('register a handler via Register-RecoveryHandler', "or fall through to 'unknown' which currently has no handler either")
            Rationale      = "No handler registered for failureClass '$failureClass' and no 'unknown' fallback present."
            HandledBy      = '(no handler)'
            AutoApply      = $false
            Source         = $source
        }
    }
    $result = $null
    try {
        $result = & $handler $ctx
    } catch {
        Write-Warning "Invoke-Remediation: handler for '$failureClass' threw ($($_.Exception.Message)); falling back to operator_intervention_required."
        $result = @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "Handler threw: $($_.Exception.Message)"
        }
    }
    if (-not $result -or -not ($result -is [hashtable])) {
        $result = @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "Handler for '$failureClass' returned a non-hashtable result."
        }
    }
    if (-not $result.Contains('Recommendation')) { $result['Recommendation'] = 'operator_intervention_required' }
    if (-not $result.Contains('Rationale'))      { $result['Rationale']      = '' }
    if (-not $result.Contains('Actions'))        { $result['Actions']        = @() }
    if (-not $result.Contains('AutoApply'))      { $result['AutoApply']      = $false }
    if (-not $result.Contains('HandledBy'))      { $result['HandledBy']      = "builtin/$failureClass" }
    # Output-side contract check: a handler (most likely an external one) that
    # returns a Recommendation outside the canonical vocabulary would emit a
    # token no caller can route on. Coerce to operator_intervention_required so
    # the loop always lands on a known recommendation.
    if ($script:RecommendationEnum -notcontains [string]$result['Recommendation']) {
        Write-Warning "Invoke-Remediation: handler for '$failureClass' returned Recommendation '$($result['Recommendation'])' outside the recovery vocabulary; coercing to operator_intervention_required."
        $result['Recommendation'] = 'operator_intervention_required'
    }
    $result['FailureClass'] = $failureClass
    $result['Severity']     = $severity
    $result['Source']       = $source
    # When the dispatcher routed past a retry wrapper to the inner cause, keep
    # the outer class visible so the audit trail shows what was masked.
    if ($routedFromClass) { $result['RoutedFromFailureClass'] = $routedFromClass }
    # Emit an NDJSON breadcrumb so a stream consumer follows the
    # dispatcher's decision. Schema-validated through Send-CycleEventSafely.
    # Optional context fields (vmName / guestKey / hostType / actionVerb)
    # are only attached when the originating failure carried them; null
    # values are dropped so the typed-string schema check passes cleanly.
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
        $emit = [ordered]@{
            timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event          = 'remediation_recommended'
            failureClass   = $failureClass
            severity       = $severity
            recommendation = [string]$result['Recommendation']
            handledBy      = [string]$result['HandledBy']
            autoApply      = [bool]$result['AutoApply']
            source         = [string]$source
        }
        if ($routedFromClass) { $emit['outerFailureClass'] = [string]$routedFromClass }
        foreach ($key in @('vmName', 'guestKey', 'hostType', 'actionVerb', 'sequenceName')) {
            $val = $ctx.Context[$key]
            if ($val) { $emit[$key] = [string]$val }
        }
        Send-CycleEventSafely -EventRecord ([hashtable]$emit)
    }
    # Persist the recommendation as a durable, self-contained record beside
    # last_failure.json. The NDJSON event above is a transient breadcrumb and
    # the verb's suggestedRecoveries is only a HINT; this file is the
    # dispatcher's authoritative DECISION on disk, so a filesystem-polling
    # consumer (dashboard, pool-aggregator service, a later autonomous loop) reads it
    # without tailing the stream. It lands in the runtime log dir; Stop-LogFile
    # archives it into the per-cycle folder and the pool copy carries it along.
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        $targetDir = if ($source -and $source -ne '(inline)' -and (Test-Path -LiteralPath $source)) {
            Split-Path -Parent $source
        } elseif ($env:YURUNA_LOG_DIR) {
            $env:YURUNA_LOG_DIR
        } else { $null }
        if ($targetDir -and (Test-Path -LiteralPath $targetDir -PathType Container)) {
            $record = [ordered]@{
                schemaVersion  = 1
                timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                # The record lands in the log ROOT, which outlives any single
                # cycle, so whoever archives it into a cycle folder cannot tell a
                # record THIS cycle produced from one an earlier cycle left
                # behind -- and presence alone reads as "this cycle was
                # diagnosed". Stamp the producing run so the archive matches on
                # identity; a record with no stamp is treated as inherited.
                runId          = if ($global:__YurunaRunId) { [string]$global:__YurunaRunId } else { '' }
                failureClass   = $failureClass
                severity       = $severity
                recommendation = [string]$result['Recommendation']
                rationale      = [string]$result['Rationale']
                actions        = @($result['Actions'])
                handledBy      = [string]$result['HandledBy']
                autoApply      = [bool]$result['AutoApply']
                source         = [string]$source
            }
            if ($routedFromClass) { $record['outerFailureClass'] = [string]$routedFromClass }
            # Correlation fields, attached only when the failure carried them so
            # the typed-string consumer never sees a null.
            foreach ($key in @('vmName', 'guestKey', 'hostType', 'stepNumber', 'actionVerb', 'sequenceName')) {
                $val = $ctx.Context[$key]
                if ($null -ne $val -and "$val" -ne '') { $record[$key] = $val }
            }
            try {
                $null = Write-YurunaStateFileJson -Path (Join-Path $targetDir 'last_remediation.json') -InputObject $record -Confirm:$false
            } catch {
                Write-Verbose "Invoke-Remediation: could not write last_remediation.json: $($_.Exception.Message)"
            }
        }
    }
    return $result
}

function Register-BuiltinRecoveryHandler {
    <#
    .SYNOPSIS
        Install the default handler for every value in the FailureClass
        enum. Advisory-only: handlers return recommendations, never
        mutate state. The module-load entry point calls this once.
    .DESCRIPTION
        Each handler's rationale references the failing verb's intent
        so an operator reading `remediation_recommended` events can
        cross-reference back to the sequence YAML without an extra
        lookup.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('Test.Remediation', 'Register built-in recovery handlers')) { return }

    Register-RecoveryHandler -FailureClass 'ocr_timeout' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'restart_from_snapshot'
            Rationale      = "ocr_timeout on $($c.Context.vmName): the screen never reached the expected state. Most often the workload diverged from the recorded path; replay from a clean snapshot rather than guessing how to recover in place."
            Actions        = @(
                'Restore the last known-good snapshot for the VM',
                'Re-run the sequence from the failing step',
                "If the failure repeats, capture screen+OCR artifacts under the cycle folder and pause for inspection"
            )
        }
    }

    # Deliberately NOT restart_from_snapshot, which is what ocr_timeout above
    # recommends. The two look alike in the record -- a wait that ended without
    # its pattern -- but the assumption behind replaying from a snapshot is that
    # the screen diverged from the recorded path and a clean run will follow it
    # again. Here the screen never became readable: something filled the console
    # faster than the pattern could be matched off it, and a replay reproduces
    # that at the same rate. The console content is the evidence and a person has
    # to read it, so this class stops rather than spending another full timeout.
    Register-RecoveryHandler -FailureClass 'console_flooded' -Handler {
        param([hashtable]$c)
        # Two screens reach this class. One is still moving: a line repeating
        # faster than the pattern can be read off it, where the answer is to fix
        # what is repeating. The other stopped moving a long time ago and only
        # LOOKS like a flood, because the repeat count is measured within a single
        # frame -- a wall of already-scrolled text on a guest that is waiting for
        # something. Naming a churning network on the second sends the reader
        # after a fault that is not there, so the static reading decides which
        # cause is described.
        $staticSecs = [int]$c.Context.consoleStaticSeconds
        $heldSecs   = [int]$c.Context.pauseBeforeStepSeconds
        # A static reading of zero is only evidence when a static reading was
        # taken. Where the wait confined its match to the console tail it ran no
        # content-static tracker at all, and treating that absence as "the screen
        # kept moving" would name a churning network on a guest that may simply
        # be parked. Unmeasured falls to the moving-console text, which asks the
        # reader to look at what is repeating -- the safe reading, because it
        # sends nobody to answer a prompt nothing established was there.
        $parked     = [bool]$c.Context.consoleStaticMeasured -and $staticSecs -gt 0
        $rationale = if ($parked) {
            "console_flooded on $($c.Context.vmName): the wait ran its full budget against a screen whose content had not changed for ${staticSecs}s -- a wall of text that scrolled by earlier, not a console still filling. A guest printing nothing is a guest waiting for something, and a prompt it printed once before this wait began would look exactly like this." +
            $(if ($heldSecs -gt 0) { " An operator hold of ${heldSecs}s ended just before this step: the guest kept running through it, so anything it printed and does not reprint is off the screen the step then had to read." } else { '' })
        } else {
            "console_flooded on $($c.Context.vmName): the wait ran its full budget against a console that was overwriting itself with one repeating line, so the pattern could not be read off it whether or not the guest ever printed it. This is not a guest that failed to reach the expected state -- it is a screen that could not be read, and replaying it floods the same screen again. What is repeating names the cause: a link or DHCP event churning the installer's network model, a service restart loop, or a kernel message storm."
        }
        $actions = if ($parked) {
            @(
                'Read causeDetail.consoleStaticSeconds and consoleFlood in last_failure.json -- a long static run with a repeating dominant line is a parked guest, not a live flood',
                'Open the guest console and answer what it is waiting on; a prompt that is off screen is still live and still reading input',
                'Where the step is a waitForAndEnter, blindAfterSeconds lets it answer that prompt itself on the next run',
                'Re-run the sequence from the failing step only after the guest is moving again'
            )
        } else {
            @(
                'Read causeDetail.consoleFlood in last_failure.json for the dominant line and its share of the screen',
                'Fix what is repeating rather than re-running the wait -- a longer timeout cannot make a self-overwriting surface readable',
                'Where the flood is installer-phase network churn, confirm the guest is getting a DHCP lease at all',
                'Only then re-run the sequence from the failing step'
            )
        }
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = $rationale
            Actions        = $actions
        }
    }

    Register-RecoveryHandler -FailureClass 'network_timeout' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = "network_timeout on $($c.Context.vmName): SSH / probe never reached ready. Typically transient -- a brief backoff (5-30 s) clears it without operator action."
            Actions        = @(
                'Wait 5-30 s with jitter (see Get-PollDelay)',
                'Re-attempt the failing network probe / Wait-SshReady',
                "If retries exhaust, fall through to operator_intervention_required"
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'credential_expired' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "credential_expired on $($c.Context.vmName): a vault-managed password no longer matches what the guest expects. The vault almost certainly needs to be refreshed before the next cycle can pass."
            Actions        = @(
                "Inspect test/status/extension/authentication/vault.yml for the affected guest",
                "Reset the guest's password (or rotate the vault entry) before retrying",
                "Re-run the sequence after the vault is consistent"
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'host_io_blocked' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'reconnect'
            Rationale      = "host_io_blocked on $($c.Context.vmName): Send-Key / Send-Text / Send-Click could not deliver to the guest. The transport handle (VNC socket, Hyper-V keyboard CIM) likely went stale."
            Actions        = @(
                'Disconnect-VNC for the affected VM',
                'Force the next Send-* to re-handshake',
                "If reconnect fails twice, fall through to operator_intervention_required"
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'pattern_matched_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = "pattern_matched_failure on $($c.Context.vmName): fetchAndExecute saw the failure-end-tag. The wrapper script itself reported a failure; auto-retry would just re-trigger it."
            Actions        = @(
                "Open the cycle folder's last-fetch-and-execute.log",
                'Diagnose the underlying script error',
                'Resume manually after the root cause is fixed'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'retry_exhausted' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "retry_exhausted on $($c.Context.vmName): the retry verb already used up its budget. Auto-retrying more would just keep failing."
            Actions        = @(
                'Inspect the innerFailureClass field in last_failure.json for the deepest cause',
                'Address that underlying failure',
                'Re-run the cycle once the root cause is resolved'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'snapshot_restore_failed' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "snapshot_restore_failed on $($c.Context.vmName): the snapshot subsystem itself is broken. Auto-recovery cannot proceed without a working restore primitive."
            Actions        = @(
                'List snapshots for the VM (Get-VMCheckpoint / virsh snapshot-list / utmctl)',
                'Confirm the named snapshot exists and is consistent',
                'If missing, take a fresh baseline snapshot and re-run the sequence'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'script_error' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = "script_error on $($c.Context.vmName): an SSH-driven command returned non-zero. Auto-retry would loop on the same script bug."
            Actions        = @(
                'Inspect the cycle folder for last-fetch-and-execute.log or sshExec stderr',
                'Fix the underlying script',
                'Resume the cycle once the script is correct'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'wait_timeout' -Handler {
        param([hashtable]$c)
        # Two verbs reach this class and they need opposite advice. A bare wait
        # is independent of guest state, so retrying it costs nothing. A
        # fetchAndExecute timeout means a script was still running in the guest
        # when the marker deadline passed -- usually blocked on a package mirror
        # -- so the useful move is a backoff (give the upstream time to recover)
        # rather than an immediate re-run that races the same stall.
        if ($c.Context.actionVerb -eq 'fetchAndExecute') {
            return @{
                Recommendation = 'retry_with_backoff'
                Rationale      = "wait_timeout on $($c.Context.vmName): the fetchAndExecute completion marker never appeared, so the guest script was still running (or wedged) at the deadline -- most often blocked on a slow or stalled package mirror. No failure tag was printed, so this is not a script-reported error; a backoff commonly clears it."
                Actions        = @(
                    "Open the cycle folder's last-fetch-and-execute.log and check where it stops -- a log with no '# exit code:' trailer means the script never returned",
                    'Check the NETWORK section of the guest diagnostic for stalled or slow package-mirror origins',
                    'Back off, then re-run the failing step (the guest install scripts are idempotent)',
                    'If it stalls at the same URL every cycle, treat it as an upstream mirror outage rather than a guest fault'
                )
            }
        }
        return @{
            Recommendation = 'retry_immediately'
            Rationale      = "wait_timeout on $($c.Context.vmName): waitForSeconds elapsed without an observable change. The wait is independent of guest state; an immediate retry is safe."
            Actions        = @('Re-run the failing wait step.')
        }
    }

    Register-RecoveryHandler -FailureClass 'extension_error' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = "extension_error on $($c.Context.vmName): a callExtension invocation threw. Auto-retry risks looping on the same extension bug or burning credentials."
            Actions        = @(
                "Identify the failing extension area (authentication, notification, etc.)",
                "Inspect that area's default.psm1 + .contract.yml",
                'Fix the extension and re-run the cycle'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'instrumentation_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_immediately'
            Rationale      = "instrumentation_failure on $($c.Context.vmName): takeScreenshot / saveSystemDiagnostic failed transiently. The cycle's observable state is unaffected; one immediate retry typically clears it."
            Actions        = @('Re-attempt the failing instrumentation step.')
        }
    }

    Register-RecoveryHandler -FailureClass 'provisioning_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = "provisioning_failure on $($c.Context.vmName): the host hypervisor could not define / boot / reach-running the VM. Often transient (insufficient-resources right after a prior teardown, KVP/IP late to populate) and clears on the next cycle after a backoff."
            Actions        = @(
                'Confirm the prior cycle freed host CPU / memory (no orphaned VM holding resources)',
                'Check the host hypervisor service + free disk for the VM store',
                'Retry the cycle; if it reproduces deterministically, treat as operator_intervention_required'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'payload_unavailable' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = "payload_unavailable on $($c.Context.vmName): the guest ran the fetch wrapper and no source served the script, so nothing executed -- there is no script here to debug, and no guest state to distrust. The usual cause is a host that renumbered under DHCP while this guest still held the old address; the guest re-asks the pool directory and normally recovers within seconds."
            Actions        = @(
                'Retry after a short backoff -- the host is usually reachable again by the next attempt',
                'If it persists, check that this host publishes its address to the pool directory and that the guest can reach that directory',
                'Where the log also shows the GitHub fallback returning 404: that leg cannot serve a private repository without a token, so the host is the only working source and its reachability is the whole problem'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'ip_not_discovered' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = "ip_not_discovered on $($c.Context.vmName): no host-side probe could name an address for the guest, so the step never reached it. Address discovery rests on caches that age out and daemons that publish late, so the same call usually answers seconds later. Distinct from network_timeout, where an address WAS found and the path to it failed, and from host_network_degraded, which does not clear on its own."
            Actions        = @(
                'Retry after a short backoff -- the address usually appears with no operator action',
                'If it persists, confirm the guest booted and its NIC is attached to the expected network',
                'Check the host-side lease / neighbor source the driver reads for a stale or missing entry'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'bootstrap_sync' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "bootstrap_sync on $($c.Context.vmName): a git fetch/clone of the framework or project repo failed for a non-network reason (divergence, auth, or a dirty working tree). A pure network blip is classified upstream as network_timeout and retried; this class is the non-transient remainder."
            Actions        = @(
                'Inspect the framework + project repo working trees for divergence or local edits',
                'Verify the git remote credentials / token are still valid',
                'Reconcile the repo, then re-run the cycle'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'elevation_required' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "elevation_required on $($c.Context.vmName): a command needed sudo and no operator was present to supply a password. sudo reads the password from /dev/tty, so this cannot be answered by the runner, by a retry, or from a remote session -- and a host in this state would otherwise stall mid-cycle while the dashboard still showed the last cycle green. Fixing it needs console access, exactly like a network fault does."
            Actions        = @(
                'On the console, install the runner drop-in: the failure message carries the exact /etc/sudoers.d/yuruna-runner rule',
                'Validate it with visudo -cf before relying on it -- an invalid drop-in breaks sudo for every command',
                'Re-launch test/Start-TestRunner.ps1; its startup elevation gate confirms the host before the first cycle'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'pool_storage_full' -Handler {
        param([hashtable]$c)
        # The record's description carries the measured free-vs-required figures;
        # quote it so the operator sees the actual shortfall rather than being told
        # to go and measure it themselves.
        $detail = ''
        if ($c.Failure -and $c.Failure.description) { $detail = " Reported: $($c.Failure.description)" }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "pool_storage_full: the pool share has no room left for this host's cycle results, so the cycle's output could not be archived. Nothing the runner can do changes that -- it has no archives of its own to delete, and the next cycle only produces more to store. In move mode the share holds the ONLY copy of a cycle's results, so archiving is not optional and cycles stay paused until there is room.$detail"
            Actions        = @(
                "Delete old cycle archives on the share under hosts/<hostId>/test-cycles/ -- they are immutable folders, so removing whole ones is safe",
                'Retire dead hosts with test/pool/Remove-PoolHost.ps1, which also removes their archive root (including any pre-unification one)',
                'Check what else shares the volume: the guest-image download pool under images/ is usually the largest tenant',
                'The runner re-checks before each cycle and resumes on its own once there is room; a config edit or a new commit ends the pause immediately'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'lab_dependency_down' -Handler {
        param([hashtable]$c)
        # The record's description names which services, how long the runner
        # waited, and where each was last seen answering. Quote it: the last-seen
        # address is what tells the operator whether the service moved or died,
        # and re-deriving it means repeating the whole hold by hand.
        $detail = ''
        if ($c.Failure -and $c.Failure.description) { $detail = " Reported: $($c.Failure.description)" }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "lab_dependency_down: a lab service this host had been reaching stopped answering, and the cycle already held for it -- re-probing on backoff for up to sixteen hours -- before recording this. So an automated retry has provably been tried at the only scale that could have worked, and the next cycle would spend the same hours to reach the same answer. The service also need not live on this host: under a pool it is normally a VM somebody else owns, which is why this is not a host fault and not a guest fault.$detail"
            Actions        = @(
                'Start the named service where it belongs: test/service/Start-<Service>VM.ps1 on its host, and confirm /healthz answers from there',
                'A service that moved rather than died needs nothing here -- discovery re-asks every attempt, so the next cycle finds the new address on its own',
                'To run without it, pin an address with $env:YURUNA_EXTENSION_HOST_<AREA>, or set testCycle.labHealth.enabled to false to stop holding for any service',
                'The hold is not the cycle budget: an operator who knows the outage is permanent ends it from the status page rather than waiting it out'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'host_network_degraded' -Handler {
        param([hashtable]$c)
        # The failing record MAY carry the host-network detail (which switch, and
        # which verdict the driver's classifier returned). Both are optional:
        # read them off the raw record and degrade to generic wording, so this
        # handler never depends on a producer that has not filled them in.
        $rec = if ($c.Failure -is [System.Collections.IDictionary]) { $c.Failure } else { @{} }
        $verdict = if ($rec.Contains('hostNetworkVerdict') -and $rec['hostNetworkVerdict']) { [string]$rec['hostNetworkVerdict'] } else { '' }
        $switchName = if ($rec.Contains('hostNetworkSwitch') -and $rec['hostNetworkSwitch']) { [string]$rec['hostNetworkSwitch'] } else { '' }
        $verdictText = if ($verdict) { "verdict '$verdict'" } else { 'the recorded verdict' }
        $switchText = if ($switchName) { "the external switch '$switchName'" } else { "the host's external switch" }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "host_network_degraded on $($c.Context.vmName): the guest-network path the HOST provides is broken, not this guest. A virtual switch object outlives its uplink binding across a host reboot, so the switch still exists and every host check still passes while nothing attached to it forwards -- each guest can only report its own symptom. Retrying, on this cycle or a later one, attaches the next guest to the same carrier-less bridge, so this class never enters the transient retry allow-lists and is not counted toward a per-guest quarantine streak."
            Actions        = @(
                "On the host console, inspect $switchText ($verdictText): Get-VMSwitch, then Get-NetAdapter for the description it names",
                "Restore the binding the verdict points at -- Set-VMSwitch -Name <switch> -NetAdapterName <nic> for a lost uplink, or -AllowManagementOS `$true for a missing management vNIC -- knowing it briefly interrupts the host's own network",
                'Until it is restored, guests keep provisioning on the NAT fallback switch and reach the host only through its port-forwarders'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'dhcp_identity_unbounded' -Handler {
        param([hashtable]$c)
        # The record carries the two addresses; quoting them is what turns this
        # from a claim into something an operator can check against the server's
        # own lease table without reproducing anything.
        $rec = if ($c.Failure -is [System.Collections.IDictionary]) { $c.Failure } else { @{} }
        $prev = if ($rec.Contains('previousAddress')) { [string]$rec['previousAddress'] } else { '' }
        $cur  = if ($rec.Contains('currentAddress'))  { [string]$rec['currentAddress'] }  else { '' }
        $move = if ($prev -and $cur) { " It moved $prev -> $cur." } else { '' }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "dhcp_identity_unbounded on $($c.Context.vmName): this guest was rebuilt under the identity it is supposed to keep, and the DHCP server handed it a DIFFERENT address anyway.$move A guest whose address is not a function of its identity spends one address per build, and every abandoned one stays allocated for the whole lease -- so the pool drains at a rate set by the lease time rather than by how many machines exist, and guests eventually boot with no IPv4 at all. Retrying cannot help: the next build asks the same question and gets another new address, so this never enters the transient retry allow-lists."
            Actions        = @(
                'Confirm the seed carried the pin: network-config on the cidata seed must reach the guest, since a pin applied after boot is a lease too late',
                "Check the server's lease table for this guest's MAC -- two live leases on one MAC means it is keying on a client-id the guest is still varying",
                'If the pin is present and the address still moves, the server is not keying on client-id: give this guest a reservation, or shorten the lease so the waste recycles'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'project_access_denied' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "project_access_denied on $($c.Context.vmName): the pool assigned this host a projectUrl its git credential cannot read (private repo, or a token without access). No retry can succeed -- the credential is host-local and the assignment was made elsewhere -- so this never enters the backoff. Distinct from bootstrap_sync, where the host's OWN project failed to clone: here the fix belongs to whoever assigned the pool's test-set."
            Actions        = @(
                "Grant this host's GH_TOKEN read access to the assigned projectUrl",
                'Or reassign the pool to a test-set whose project every member can read',
                'The pool-control board flags the pool and lists the blocked hosts'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'plan_invalid' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = "plan_invalid on $($c.Context.vmName): the cycle plan is ambiguous or unsatisfiable (duplicate sequence, a backend the host lacks, or a missing host/<host>/<guest> folder). A config error, not auto-remediable."
            Actions        = @(
                'Inspect project/test/test.runner.yml for duplicate or malformed entries',
                'Confirm the host/<host>/<guest> folder exists for every planned guest',
                'Confirm the host provides every backend the plan requires, then re-run'
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'unknown' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = "unknown failure on $($c.Context.vmName): the failing verb did not register a FailureClass. Until classification lands, an operator needs eyes on the cycle artifacts to decide."
            Actions        = @(
                'Open the cycle folder for the failing run',
                'Review last_failure.json + manifest.json + cycle.events.ndjson',
                'Classify the failure mode and consider adding a FailureClass to the verb'
            )
        }
    }
}

# Module-load: install built-in handlers. Idempotent through the
# registry primitive's Register being a last-writer-wins map.
Register-BuiltinRecoveryHandler -Confirm:$false

Export-ModuleMember -Function Get-AutoRemediationAllowList, Test-AutoRemediationAllowed, Register-RecoveryHandler, Get-RecoveryHandler, Get-RegisteredFailureClass, Clear-RecoveryHandler, Invoke-Remediation, Register-BuiltinRecoveryHandler, Get-RecoveryRecommendationName
