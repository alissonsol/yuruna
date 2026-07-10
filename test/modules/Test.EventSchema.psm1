<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f8a7b6-c5d4-4e83-9210-3f4a5b6c7d81
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna telemetry schema ndjson
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
    Schema validator for cycle.events.ndjson records, applied at the
    emit site so drift is caught before it lands on disk.

.DESCRIPTION
    Every NDJSON record goes through Send-CycleEventSafely in
    Test.Log.psm1. Without validation, a typo in a field name
    (`stpNumber` instead of `stepNumber`) or a bad type
    (`stepNumber = "5"` instead of int 5) lands in the stream and
    only surfaces when a downstream consumer's joins start returning
    zero rows. The validator catches both classes immediately:

      * Required fields missing -> the event is malformed at the source
      * Typed fields with wrong type -> the consumer's schema-on-read
        will reject silently; we surface here loudly.

    Policy: NEVER REJECT a bad record. The cycle never fails because
    its telemetry was malformed. On a violation, the validator:

      1. Logs a Write-Warning naming the bad fields + event type.
      2. Emits a synthetic `schema_violation` NDJSON event carrying
         the violation list + the offending record's `event` name
         (NOT the full payload, to avoid duplicating the suspect data
         in two places on disk).

    Both writes go through Write-CycleNdjsonEvent so a consumer that
    polls cycle.events.ndjson sees:

      {"event":"schema_violation","violations":[...],"badEvent":"step_end"}
      {"event":"step_end","stpNumber":5,...}     <-- the original, as-emitted

    Schema scope: cross-cutting envelope fields only (timestamp +
    event, plus per-cycle correlation keys). Event-specific payload
    fields (durationMs, actionVerb, etc.) are typed when present but
    optional -- this keeps the schema small and lets new events add
    fields without a schema migration.
#>

# The canonical FailureClass/Severity enums live in the leaf taxonomy module so
# a new class lands in exactly one place. This validator derives its enum
# mirrors from it; the Register-SequenceAction ValidateSet keeps a guarded
# literal copy only because a ValidateSet attribute arg must be a constant
# expression.
Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global

# Required envelope fields. Every NDJSON record MUST carry these or
# the entire row is unparseable by a streaming consumer.
$script:RequiredField = @('timestamp', 'event')

# Per-field type expectations. Keys are field names; values declare
# the expected type ('string', 'int', 'bool', 'array', 'int-or-null',
# 'hashtable'). Fields absent from this table are accepted as-is
# (event-specific payload fields don't need to enroll).
$script:TypedField = @{
    timestamp           = 'string'
    event               = 'string'
    cycleId             = 'string'
    runId               = 'string'
    cycleFolder         = 'string'
    cycleNumber         = 'int'
    stepNumber          = 'int'
    totalSteps          = 'int'
    actionVerb          = 'string'
    ok                  = 'bool'
    durationMs          = 'int-or-null'
    failureClass        = 'string'
    severity            = 'string'
    suggestedRecoveries = 'array'
    vmName              = 'string'
    guestKey            = 'string'
    hostType            = 'string'
    action              = 'string'
    description         = 'string'
    sequenceName        = 'string'
    sequencePath        = 'string'
    classificationSource = 'string'
    reproCommand        = 'string'
    causeOcrTail        = 'string'
    causePatternsSought = 'array'
    error               = 'string'
    reason              = 'string'
    pid                 = 'int'
    hostname            = 'string'
    handler             = 'string'
    snapshotId          = 'string'
    runnerState         = 'string'
    fromState           = 'string'
    toState             = 'string'
}

# FailureClass / Severity enums, sourced from the canonical Test.FailureTaxonomy
# module (not re-declared here). A failureClass value outside this set is flagged
# because every downstream consumer (last_failure.json schema v2, the remediation
# dispatcher) routes on the enum and a typo would silently fall through to
# 'unknown'.
$script:FailureClassEnum = Get-FailureClassEnum
$script:SeverityEnum     = Get-SeverityEnum

# Runner-state enum mirror -- kept in sync with the StateEnum in
# Test.RunnerState.psm1's $script:StateEnum. A value outside this
# set on `runnerState` / `fromState` / `toState` is flagged because
# downstream consumers (state-machine dashboards, watchdog logic)
# branch on the enum and would silently mis-classify on drift.
$script:RunnerStateEnum = @(
    'idle', 'cycle-start', 'in-cycle', 'cycle-end', 'fault', 'paused'
)

function Test-CycleEventSchema {
    <#
    .SYNOPSIS
        Validate a single NDJSON event record. Returns the violations
        as an array of strings (empty when the record passes).
    .DESCRIPTION
        Checks (a) required fields present, (b) typed fields match
        expected types, (c) enum-valued fields (failureClass, severity)
        match the canonical set. Unknown fields are accepted -- the
        schema is intentionally OPEN so a new event type can introduce
        fields without amending this file in lockstep.
    .OUTPUTS
        [string[]] Empty array when the record is valid; otherwise one
        line per violation, formatted for Write-Warning consumption.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Record
    )
    $violations = @()
    foreach ($req in $script:RequiredField) {
        if (-not $Record.Contains($req)) {
            $violations += "missing required field '$req'"
        }
    }
    foreach ($key in $Record.Keys) {
        if (-not $script:TypedField.ContainsKey($key)) { continue }
        $expected = $script:TypedField[$key]
        $value    = $Record[$key]
        $ok = switch ($expected) {
            'string'       { $value -is [string] }
            'int'          { ($value -is [int]) -or ($value -is [long]) }
            'bool'         { $value -is [bool] }
            # $null is accepted as a valid empty array because PowerShell's
            # if-pipeline flattens both single-element AND empty arrays out
            # of an if-statement's output; `[string[]]$x = if (...) { @() }`
            # yields $null on the empty branch even though the emitter's
            # intent was "no entries". Treating $null as an empty array in
            # the validator is the durable fix -- emission sites that hit
            # the trap stay valid without needing to be hunted down one
            # at a time. A truly missing field (key absent from the
            # hashtable) is still caught by the required-field loop above.
            'array'        { ($null -eq $value) -or ($value -is [array]) -or ($value -is [System.Collections.IList]) }
            'hashtable'    { $value -is [System.Collections.IDictionary] }
            'int-or-null'  { ($null -eq $value) -or ($value -is [int]) -or ($value -is [long]) }
            default        { $true }
        }
        if (-not $ok) {
            $actual = if ($null -eq $value) { 'null' } else { $value.GetType().Name }
            $violations += "field '$key' expected $expected but got $actual"
        }
    }
    if ($Record.Contains('failureClass') -and ($Record['failureClass'] -is [string])) {
        if (-not ($script:FailureClassEnum -contains [string]$Record['failureClass'])) {
            $violations += "failureClass '$($Record['failureClass'])' is not in the canonical enum"
        }
    }
    if ($Record.Contains('severity') -and ($Record['severity'] -is [string])) {
        if (-not ($script:SeverityEnum -contains [string]$Record['severity'])) {
            $violations += "severity '$($Record['severity'])' is not one of: $($script:SeverityEnum -join ', ')"
        }
    }
    foreach ($stateField in @('runnerState', 'fromState', 'toState')) {
        if ($Record.Contains($stateField) -and ($Record[$stateField] -is [string])) {
            if (-not ($script:RunnerStateEnum -contains [string]$Record[$stateField])) {
                $violations += "$stateField '$($Record[$stateField])' is not one of: $($script:RunnerStateEnum -join ', ')"
            }
        }
    }
    return $violations
}

function Get-CycleEventSchemaDescriptor {
    <#
    .SYNOPSIS
        Returns the live schema definition as a hashtable. Read-only
        contract for dashboards / CI / introspection tooling that
        wants to know which fields are required and what the typed
        contract is, without re-deriving it from Test-CycleEventSchema's
        switch.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        RequiredField    = @($script:RequiredField)
        TypedField       = $script:TypedField.Clone()
        FailureClassEnum = @($script:FailureClassEnum)
        SeverityEnum     = @($script:SeverityEnum)
        RunnerStateEnum  = @($script:RunnerStateEnum)
    }
}

Export-ModuleMember -Function Test-CycleEventSchema, Get-CycleEventSchemaDescriptor
