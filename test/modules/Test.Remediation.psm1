<#PSScriptInfo
.VERSION 2026.09.24
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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
    'wait_timeout'           = (Format-YurunaOperatorMessage -Key 'remediation.operator_b9e5f8c44bec51fc')
    'network_timeout'        = (Format-YurunaOperatorMessage -Key 'remediation.operator_4046c1f6949f7aad')
    'ip_not_discovered'      = (Format-YurunaOperatorMessage -Key 'remediation.operator_787985aef3c53e0a')
    'host_network_degraded'  = (Format-YurunaOperatorMessage -Key 'remediation.operator_a3827909e7a01825')
    # Backed by a Repair-* primitive that is safe to run twice.
    'instrumentation_failure' = (Format-YurunaOperatorMessage -Key 'remediation.operator_36573af397a13ade')
    'host_io_blocked'         = (Format-YurunaOperatorMessage -Key 'remediation.operator_70fab6da39ee36e1')
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
    if ($PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'remediation.operator_2ad54514c8ca7909'), (Format-YurunaOperatorMessage -Key 'remediation.operator_d009181b9af99707'))) {
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
                Write-Verbose (Format-YurunaOperatorMessage -Key 'remediation.operator_3f388f3f584a1034')
                return $null
            }
            $LastFailurePath = Join-Path $baseDir 'last_failure.json'
        }
        if (-not (Test-Path -LiteralPath $LastFailurePath)) {
            Write-Verbose (Format-YurunaOperatorMessage -Key 'remediation.operator_3b44f5cc88984d87' -Arguments @{ lastFailurePath = "$LastFailurePath" })
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
                throw (Format-YurunaOperatorMessage -Key 'remediation.operator_e0d3c0a00e449780' -Arguments @{ gotType = "$gotType" })
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_11a9174eaa2fbdfe' -Arguments @{ lastFailurePath = "$LastFailurePath"; message = "$($_.Exception.Message)" })
            return @{
                FailureClass   = 'unknown'
                Severity       = 'unknown'
                Recommendation = 'operator_intervention_required'
                Actions        = @((Format-YurunaOperatorMessage -Key 'remediation.operator_00fd2209b1a993b2'), (Format-YurunaOperatorMessage -Key 'remediation.operator_be21fdfe4bad5cf0' -Arguments @{ lastFailurePath = "$LastFailurePath" }))
                Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_442f164764fa5ba8' -Arguments @{ message = "$($_.Exception.Message)" })
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
            Actions        = @((Format-YurunaOperatorMessage -Key 'remediation.operator_ae1a107543e2b1da'), (Format-YurunaOperatorMessage -Key 'remediation.operator_328d54082fe46c95'))
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_676a299116f4813d' -Arguments @{ failureClass = "$failureClass" })
            HandledBy      = '(no handler)'
            AutoApply      = $false
            Source         = $source
        }
    }
    $result = $null
    try {
        $result = & $handler $ctx
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_64f9ab857a412559' -Arguments @{ failureClass = "$failureClass"; message = "$($_.Exception.Message)" })
        $result = @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_dcc4abf58182f0f3' -Arguments @{ message = "$($_.Exception.Message)" })
        }
    }
    if (-not $result -or -not ($result -is [hashtable])) {
        $result = @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_c706cfbe26bfe98c' -Arguments @{ failureClass = "$failureClass" })
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6a2751f0acfb479b' -Arguments @{ failureClass = "$failureClass"; recommendation = "$($result['Recommendation'])" })
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
                Write-Verbose (Format-YurunaOperatorMessage -Key 'remediation.operator_730dca21ad9eda73' -Arguments @{ message = "$($_.Exception.Message)" })
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
    if (-not $PSCmdlet.ShouldProcess('Test.Remediation', (Format-YurunaOperatorMessage -Key 'remediation.operator_229beccf1c8615fb'))) { return }

    Register-RecoveryHandler -FailureClass 'ocr_timeout' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'restart_from_snapshot'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_0ddb7073d12e8400' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f65f2f5b0c183dc5'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_14bd8c7afa68b453'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f170c655d3aa9ec7')
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
            (Format-YurunaOperatorMessage -Key 'remediation.operator_01b3c9512f168859' -Arguments @{ vmName = "$($c.Context.vmName)"; staticSecs = "${staticSecs}" }) +
            $(if ($heldSecs -gt 0) { (Format-YurunaOperatorMessage -Key 'remediation.operator_5d3d876075d1100d' -Arguments @{ heldSecs = "${heldSecs}" }) } else { '' })
        } else {
            (Format-YurunaOperatorMessage -Key 'remediation.operator_9151cc4f3b057b44' -Arguments @{ vmName = "$($c.Context.vmName)" })
        }
        $actions = if ($parked) {
            @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_4155d913c9defc45'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_8f308f9f27537f47'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_6a9db7b61b4925ae'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e058d7d3febce5c7')
            )
        } else {
            @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_3264b63693a7f3a4'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_85eda07f90b4d887'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_cbaa17fc6a5150b0'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_bcb561ae0b2d1afd')
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
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_fbf8a282c16fce06' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_2fa001ad26748ebc'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_bb25c210fa3519d6'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_6ece8bcef4b26107')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'credential_expired' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_b9a49bf4b1c35603' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_38a152014944599f'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_19c29f3d7af84089'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e038808ca34827c4')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'host_io_blocked' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'reconnect'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_abd632fb4ee5d5b1' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_26e79b3ecf42c48e'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_688a7e15ea7edf9c'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_d9a4a3e89d4a670b')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'pattern_matched_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_7c1a5d17f86d77d0' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_443019dfa8dbce7c'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_82a3c5762fc4648e'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_8f9d21c7feb1fbde')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'retry_exhausted' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_d58ebc3333e86c7f' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_ce4ee5bda91552ae'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_25ef3aa3a8d0b7fb'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e24252c37930e352')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'snapshot_restore_failed' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_ec70b244ad9d80d1' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e15a652575a58f85'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_2e1e64b6924ab3ed'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_bf89860e09f2c5b1')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'script_error' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_9f53aeb17d36bf0e' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_bac6cb55b45e16b5'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_2d28084c0bea1d81'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_fe77fdc3a8c79bc8')
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
                Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_644fe260c47d5bf9' -Arguments @{ vmName = "$($c.Context.vmName)" })
                Actions        = @(
                    (Format-YurunaOperatorMessage -Key 'remediation.operator_6fd79eb4d8f46b60'),
                    (Format-YurunaOperatorMessage -Key 'remediation.operator_2aed02135c2ad75f'),
                    (Format-YurunaOperatorMessage -Key 'remediation.operator_db0130b0bf3d4958'),
                    (Format-YurunaOperatorMessage -Key 'remediation.operator_12936401977348b5')
                )
            }
        }
        return @{
            Recommendation = 'retry_immediately'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_1fcd1c46f3e49adb' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @((Format-YurunaOperatorMessage -Key 'remediation.operator_6a7069cdf541164d'))
        }
    }

    Register-RecoveryHandler -FailureClass 'extension_error' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_892877bc74922cba' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_6c024e2aae3f4e0b'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_b0efdbb198fceec5'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_7db5a2977e4790b2')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'instrumentation_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_immediately'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_cc703ba747623c88' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @((Format-YurunaOperatorMessage -Key 'remediation.operator_807e58f44f8a5743'))
        }
    }

    Register-RecoveryHandler -FailureClass 'provisioning_failure' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_d16851977ec6a779' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f0fd4b357ed63f38'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_bb372789b3ee6502'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_dd019d34b72feafc')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'payload_unavailable' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_7a0e1aa474da9a62' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_c00ffc306428603b'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_03c7dac9d2e3c13f'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_16b7173fb133ad34')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'ip_not_discovered' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'retry_with_backoff'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_e54de45d1485fbb7' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_d1f78e9ab1185fe5'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_3d90ab28ad1f16f9'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f9f5cd6dabda9dc0')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'bootstrap_sync' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_9aa0dd33f9cd273a' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_d7f954ed2c939cf9'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_6cf224bfd1008ecc'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_2be2a7b55fde9058')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'elevation_required' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_e344b12d616e0f0a' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_fe73e80924c46670'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_7933966c333f63c7'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_5a4aff635afbeff4')
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
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_4398282a54e50a13' -Arguments @{ detail = "$detail" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_daf1c9bf1f1bad50'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_3f8475af2fbbaf26'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_126f4cf4415d01de'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_9ea01d9a6217232e')
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
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_90d007dd21de718a' -Arguments @{ detail = "$detail" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_663bef65292f201c'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_14e6c2ed2ffe7e89'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f0a29d5f6e38b4ec'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_97b6f714dbde379c')
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
        $verdictText = if ($verdict) { "verdict '$verdict'" } else { (Format-YurunaOperatorMessage -Key 'remediation.operator_31b3d0d03fc33e59') }
        $switchText = if ($switchName) { (Format-YurunaOperatorMessage -Key 'remediation.operator_e54e017fda4a02ac' -Arguments @{ switchName = "$switchName" }) } else { (Format-YurunaOperatorMessage -Key 'remediation.operator_ce6ff8d514d5658f') }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_bb02ee25257cba0d' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_6097b95aeee20519' -Arguments @{ switchText = "$switchText"; verdictText = "$verdictText" }),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_0f0d8db138f68e01'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e893941980e9b648')
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
        $move = if ($prev -and $cur) { (Format-YurunaOperatorMessage -Key 'remediation.operator_6957eec58bdf4cad' -Arguments @{ prev = "$prev"; cur = "$cur" }) } else { '' }
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_b51fc0ab27411fec' -Arguments @{ vmName = "$($c.Context.vmName)"; move = "$move" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_0e19ba1c8c8b7f7b'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_86936d1d16cfffed'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_12710b3d54a09d23')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'project_access_denied' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_2b9a82d1d78b3138' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_377f2e3910815162'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f279084b2eb96f2c'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_713fbd665e5da4bf')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'plan_invalid' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'operator_intervention_required'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_54b0e080b8e528c6' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_4fccd2ceaaf44c3a'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_f4ded9a21116febc'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_c0a439f9f4207624')
            )
        }
    }

    Register-RecoveryHandler -FailureClass 'unknown' -Handler {
        param([hashtable]$c)
        return @{
            Recommendation = 'pause_and_inspect'
            Rationale      = (Format-YurunaOperatorMessage -Key 'remediation.operator_b8bc2c014057ea71' -Arguments @{ vmName = "$($c.Context.vmName)" })
            Actions        = @(
                (Format-YurunaOperatorMessage -Key 'remediation.operator_e59c2d7e4aa9e176'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_26c6f6da9a72b538'),
                (Format-YurunaOperatorMessage -Key 'remediation.operator_b4f9634c3488c4e9')
            )
        }
    }
}

# Module-load: install built-in handlers. Idempotent through the
# registry primitive's Register being a last-writer-wins map.
Register-BuiltinRecoveryHandler -Confirm:$false

Export-ModuleMember -Function Get-AutoRemediationAllowList, Test-AutoRemediationAllowed, Register-RecoveryHandler, Get-RecoveryHandler, Get-RegisteredFailureClass, Clear-RecoveryHandler, Invoke-Remediation, Register-BuiltinRecoveryHandler, Get-RecoveryRecommendationName
