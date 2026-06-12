<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42d6f5e4-b3a2-4c91-8076-2e3f4a5b6c92
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
    handler's failure mode. Before this module nothing consumed the
    enum -- an operator (or a future autonomous loop) had to grep the
    free-text error and guess what to do. This dispatcher closes the
    loop:

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
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
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
    # Emit a NDJSON breadcrumb so a stream consumer follows the
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

Export-ModuleMember -Function Register-RecoveryHandler, Get-RecoveryHandler, Get-RegisteredFailureClass, Clear-RecoveryHandler, Invoke-Remediation, Register-BuiltinRecoveryHandler, Get-RecoveryRecommendationName
