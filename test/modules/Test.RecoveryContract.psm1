<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42aaece2-9ccd-4d9f-b467-c4468bc981ba
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery contract typed-result fingerprint outcome
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
    The one result shape every entry point returns, and the small pieces a
    recovery decision is made from: failure fingerprint, redaction, evidence,
    step results, and the persisted result files.
.DESCRIPTION
    Start-TestRunner, Invoke-TestProject and Debug-TestSequence ran the same
    kinds of steps -- refresh the checkout, prove the host is free, decide whether
    a failed sequence may be replayed, record the outcome -- and reported them in
    three shapes, spread over modules of several thousand lines. A recovery
    decision cannot be compared, or audited afterwards, across shapes like that.

    This module holds the shared vocabulary (outcomes, runner fault classes,
    recovery states), the typed result built from it, and the persistence of that
    result. The step functions in the second half wrap the existing
    implementations and return the same step shape, so an entry point composes
    them instead of re-implementing them. The design record is
    dev-only/design/recovery-contract.md; the operator view is in
    docs/failure-schema.md and docs/runner-outer-loop.md.

    Nothing here changes an exit code. Persisting a result is best-effort: a
    failed write is reported and never turns a cycle into a failure.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking -Global

# --- REGION: Vocabulary
# Kept as script arrays so a test can read the exact set a validator enforces.
$script:ResultSchemaVersion = 1
$script:OutcomeEnum       = @('passed', 'failed', 'infrastructure-fault', 'cannot-run', 'aborted')
$script:EntryPointEnum    = @('runner', 'project', 'sequence')
$script:RecoveryStateEnum = @('none', 'advised', 'declined', 'applied', 'failed', 'exhausted', 'escalated')
$script:EvidenceKindEnum  = @('file', 'record', 'event', 'command')
$script:StepEnum          = @('checkout', 'admission', 'replay', 'cycle')
# Faults of the runner itself. They already appear in status.json's
# lastFailure.failureClass; they stay out of the shared failure taxonomy because
# they describe the machinery around a cycle rather than a sequence step, so no
# remediation handler is registered for them.
$script:RunnerFaultClassEnum = @('outcome_unrecorded', 'vm_admission_occupied', 'vm_admission_unknown', 'preamble_stall', 'cycle_killed', 'cycle_spawn_failed')
$script:GenerationPattern = '^[0-9a-f]{32}:[1-9][0-9]{0,8}$'
$script:FingerprintPattern = '^fp1-[0-9a-f]{16}$'
$script:ResultFileName  = 'recovery.result.json'
$script:HistoryFileName = 'recovery.results.ndjson'
$script:HistoryKeepLines = 200
# The history is trimmed only once it passes this, so a steady stream of results
# rewrites the file occasionally instead of on every append.
$script:HistoryTrimAtLines = 240

function Get-RecoveryOutcomeEnum {
    <#
    .SYNOPSIS
        The outcome values a result may carry.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:OutcomeEnum)
}

function Get-RecoveryEntryPointEnum {
    <#
    .SYNOPSIS
        The entry points that produce a result.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:EntryPointEnum)
}

function Get-RecoveryStateEnum {
    <#
    .SYNOPSIS
        The recovery states a result may carry.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:RecoveryStateEnum)
}

function Get-RunnerFaultClassEnum {
    <#
    .SYNOPSIS
        The fault classes that describe the runner rather than a sequence step.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:RunnerFaultClassEnum)
}

function Test-RecoveryFailureClass {
    <#
    .SYNOPSIS
        Whether a token is empty, a shared-taxonomy failure class, or a runner fault class.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$FailureClass)
    if ([string]::IsNullOrEmpty($FailureClass)) { return $true }
    return (($FailureClass -cin @(Get-FailureClassEnum)) -or ($FailureClass -cin $script:RunnerFaultClassEnum))
}

# --- REGION: Redaction
function ConvertTo-RecoverySafeText {
    <#
    .SYNOPSIS
        Free text made safe to persist in a result or the ledger: one line, no
        credentials, bounded length.
    .DESCRIPTION
        Reasons and details are copied from command output (git errors, probe
        failures), and that output can carry a URL with embedded credentials or a
        value somebody pasted into a message. The records are served by the
        status service's runtime mapping and kept for diagnosis, so the text is
        scrubbed on the way in rather than trusted. Three things are removed:
        userinfo in a URL, the value after a key such as password or token, and
        any opaque run of 41 or more letters and digits that contains a digit
        (a generated secret). A 40-character commit id is left alone.
    .PARAMETER Text
        The text; $null reads as empty.
    .PARAMETER MaxLength
        Longest result in characters, ending in three dots when cut.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][object]$Text,
        [ValidateRange(8, 4000)][int]$MaxLength = 300
    )
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ' ')
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    $s = [regex]::Replace($s, '(?i)(\b[a-z][a-z0-9+.\-]*://)[^/\s:@]+(?::[^/\s@]*)?@', '$1***@')
    $s = [regex]::Replace($s, '(?i)\b(password|passwd|pwd|passphrase|token|secret|apikey|api[_-]key|access[_-]key|authorization)(\s*[=:]\s*)(?:bearer\s+)?[^\s,;]+', '$1$2***')
    $s = [regex]::Replace($s, '(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{8,}', 'Bearer ***')
    $s = [regex]::Replace($s, '(?<![A-Za-z0-9+=])(?=[A-Za-z0-9+=]*\d)[A-Za-z0-9+=]{41,}(?![A-Za-z0-9+=])', '***')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength - 3) + '...' }
    return $s
}

# --- REGION: Fingerprint
function Get-FailureFingerprint {
    <#
    .SYNOPSIS
        A stable identity for a kind of failure across cycles and runner restarts.
    .DESCRIPTION
        'fp1-' plus the first 16 hex characters of the SHA-256 of the failure
        class, stage, sequence name and action verb, each trimmed and lowercased.
        Everything that changes per run -- counts, timestamps, VM names, addresses
        -- is deliberately not an input, so the same failure on the next cycle, or
        after a restart, has the same fingerprint and shares one repair budget.
        A failure with no class has nothing to key on and yields ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$FailureClass = '',
        [AllowNull()][AllowEmptyString()][string]$Stage = '',
        [AllowNull()][AllowEmptyString()][string]$SequenceName = '',
        [AllowNull()][AllowEmptyString()][string]$ActionVerb = ''
    )
    $parts = @($FailureClass, $Stage, $SequenceName, $ActionVerb | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    if (-not $parts[0]) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes('fp1|' + ($parts -join '|'))
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return 'fp1-' + (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture) }))
}

# --- REGION: Evidence and step results
function New-RecoveryEvidence {
    <#
    .SYNOPSIS
        One pointer to what backs a result: a file, a record, an event or a command.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor; it changes no state.')]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Ref,
        [AllowEmptyString()][string]$Note = ''
    )
    if ($Kind -cnotin $script:EvidenceKindEnum) {
        throw "New-RecoveryEvidence: kind '$Kind' is not one of: $($script:EvidenceKindEnum -join ', ')."
    }
    return [ordered]@{
        kind = $Kind
        ref  = (ConvertTo-RecoverySafeText -Text $Ref -MaxLength 260)
        note = (ConvertTo-RecoverySafeText -Text $Note -MaxLength 160)
    }
}

function New-RecoveryStepResult {
    <#
    .SYNOPSIS
        The shape every step function returns, so two entry points can be compared
        step by step.
    .PARAMETER Step
        checkout, admission, replay or cycle.
    .PARAMETER Ok
        Whether the step allows the cycle to go on.
    .PARAMETER Skipped
        The step had nothing to do (for example no project URL is configured).
    .PARAMETER FailureClass
        Set only when the step is not Ok.
    .PARAMETER Extra
        Step-specific fields, added after the common ones.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor; it changes no state.')]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][bool]$Ok,
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$FailureClass = '',
        [switch]$Skipped,
        [object[]]$Evidence = @(),
        [hashtable]$Extra = @{}
    )
    if ($Step -cnotin $script:StepEnum) {
        throw "New-RecoveryStepResult: step '$Step' is not one of: $($script:StepEnum -join ', ')."
    }
    if (-not (Test-RecoveryFailureClass -FailureClass $FailureClass)) {
        throw "New-RecoveryStepResult: '$FailureClass' is not a known failure class."
    }
    $row = [ordered]@{
        Step         = $Step
        Ok           = $Ok
        Skipped      = [bool]$Skipped
        FailureClass = $FailureClass
        Reason       = (ConvertTo-RecoverySafeText -Text $Reason)
        Evidence     = @($Evidence | Where-Object { $null -ne $_ })
    }
    foreach ($key in $Extra.Keys) { $row[[string]$key] = $Extra[$key] }
    return [pscustomobject]$row
}

# --- REGION: Cycle generation
function New-CycleGeneration {
    <#
    .SYNOPSIS
        A generation for a one-shot entry point: a new instance id and cycle 1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure generator; it changes no state.')]
    param()
    return ([guid]::NewGuid().ToString('N') + ':1')
}

function Get-CycleGeneration {
    <#
    .SYNOPSIS
        The generation this process runs under: YURUNA_CYCLE_GENERATION when it is
        well formed, otherwise a new one that is exported for everything started
        from here.
    .DESCRIPTION
        The runner issues <runnerInstanceId>:<cycle> and hands it to the inner
        runner in this variable. A one-shot entry point has no runner above it, so
        it mints one and sets the variable, which makes everything it starts share
        the generation its own result names.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets only this process environment variable, by design.')]
    param()
    $current = [string]$env:YURUNA_CYCLE_GENERATION
    if ($current -cmatch $script:GenerationPattern) { return $current }
    $generation = New-CycleGeneration
    $env:YURUNA_CYCLE_GENERATION = $generation
    return $generation
}

# --- REGION: The typed result
function New-RecoveryResult {
    <#
    .SYNOPSIS
        Builds the typed result of a cycle (schema version 1).
    .DESCRIPTION
        Throws on a value outside the vocabulary: that is a defect in the caller,
        found where it is cheapest to fix. Callers that sit on a cycle's exit path
        wrap the call so that a defect here can never change an exit code.
        The fingerprint is computed for every result that has a failure class and
        did not pass.
    .PARAMETER Recovery
        Overrides for the recovery block: state, action, attempt, ledgerId,
        advised. Absent keys keep their defaults (state none).
    .PARAMETER RecordedAtUtc
        For tests; defaults to now.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor; it changes no state.')]
    param(
        [Parameter(Mandatory)][string]$EntryPoint,
        [Parameter(Mandatory)][string]$CycleGeneration,
        [Parameter(Mandatory)][string]$Outcome,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$FailureClass = '',
        [AllowEmptyString()][string]$Stage = '',
        [AllowEmptyString()][string]$SequenceName = '',
        [AllowEmptyString()][string]$ActionVerb = '',
        [AllowEmptyString()][string]$Reason = '',
        [object[]]$Evidence = @(),
        [object[]]$Steps = @(),
        [hashtable]$Recovery = @{},
        [datetime]$RecordedAtUtc = ([datetime]::UtcNow)
    )
    if ($EntryPoint -cnotin $script:EntryPointEnum) { throw "New-RecoveryResult: entry point '$EntryPoint' is not one of: $($script:EntryPointEnum -join ', ')." }
    if ($Outcome -cnotin $script:OutcomeEnum) { throw "New-RecoveryResult: outcome '$Outcome' is not one of: $($script:OutcomeEnum -join ', ')." }
    if ($CycleGeneration -cnotmatch $script:GenerationPattern) { throw "New-RecoveryResult: '$CycleGeneration' is not a cycle generation." }
    if (-not (Test-RecoveryFailureClass -FailureClass $FailureClass)) { throw "New-RecoveryResult: '$FailureClass' is not a known failure class." }
    $state = if ($Recovery.ContainsKey('state')) { [string]$Recovery['state'] } else { 'none' }
    if ($state -cnotin $script:RecoveryStateEnum) { throw "New-RecoveryResult: recovery state '$state' is not one of: $($script:RecoveryStateEnum -join ', ')." }
    foreach ($item in @($Evidence)) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['kind'] -cnotin $script:EvidenceKindEnum) {
            throw 'New-RecoveryResult: every evidence item must come from New-RecoveryEvidence.'
        }
    }
    $stepRows = foreach ($step in @($Steps)) {
        if ($null -eq $step) { continue }
        [ordered]@{
            step         = [string]$step.Step
            ok           = [bool]$step.Ok
            failureClass = [string]$step.FailureClass
            reason       = (ConvertTo-RecoverySafeText -Text $step.Reason)
        }
    }
    $fingerprint = if ($Outcome -ne 'passed') {
        Get-FailureFingerprint -FailureClass $FailureClass -Stage $Stage -SequenceName $SequenceName -ActionVerb $ActionVerb
    } else { '' }
    [string[]]$advised = if ($Recovery.ContainsKey('advised')) { @($Recovery['advised'] | ForEach-Object { [string]$_ }) } else { @() }
    return [ordered]@{
        schemaVersion   = $script:ResultSchemaVersion
        resultId        = [guid]::NewGuid().ToString('N')
        entryPoint      = $EntryPoint
        cycleGeneration = $CycleGeneration
        recordedAtUtc   = $RecordedAtUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        outcome         = $Outcome
        exitCode        = $ExitCode
        failureClass    = $FailureClass
        fingerprint     = $fingerprint
        stage           = (ConvertTo-RecoverySafeText -Text $Stage -MaxLength 80)
        reason          = (ConvertTo-RecoverySafeText -Text $Reason)
        evidence        = @($Evidence)
        steps           = @($stepRows)
        recovery        = [ordered]@{
            state    = $state
            action   = if ($Recovery.ContainsKey('action')) { [string]$Recovery['action'] } else { '' }
            attempt  = if ($Recovery.ContainsKey('attempt')) { [int]$Recovery['attempt'] } else { 0 }
            ledgerId = if ($Recovery.ContainsKey('ledgerId')) { [string]$Recovery['ledgerId'] } else { '' }
            advised  = $advised
        }
    }
}

function Test-RecoveryResult {
    <#
    .SYNOPSIS
        Whether a result (built here or read back from disk) is well formed.
    .OUTPUTS
        pscustomobject: Valid and Problems (strings).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Result)
    $problems = [Collections.Generic.List[string]]::new()
    $doc = $Result
    if ($doc -is [pscustomobject]) {
        $doc = $doc | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
    }
    if ($doc -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{ Valid = $false; Problems = @('the result is not an object') }
    }
    $get = { param([string]$Name) if ($doc.Contains($Name)) { $doc[$Name] } else { $null } }
    if ((& $get 'schemaVersion') -ne $script:ResultSchemaVersion) { $problems.Add('schemaVersion is not 1') }
    if ([string](& $get 'resultId') -cnotmatch '^[0-9a-f]{32}$') { $problems.Add('resultId is not a guid in N format') }
    if ([string](& $get 'entryPoint') -cnotin $script:EntryPointEnum) { $problems.Add('entryPoint is not in the vocabulary') }
    if ([string](& $get 'cycleGeneration') -cnotmatch $script:GenerationPattern) { $problems.Add('cycleGeneration is malformed') }
    # ConvertFrom-Json turns an ISO timestamp into a DateTime; either form is a valid stamp.
    $recordedAt = & $get 'recordedAtUtc'
    if ($recordedAt -isnot [datetime] -and [string]$recordedAt -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { $problems.Add('recordedAtUtc is malformed') }
    if ([string](& $get 'outcome') -cnotin $script:OutcomeEnum) { $problems.Add('outcome is not in the vocabulary') }
    $exit = & $get 'exitCode'
    if ($exit -isnot [int] -and $exit -isnot [long]) { $problems.Add('exitCode is not an integer') }
    $class = [string](& $get 'failureClass')
    if (-not (Test-RecoveryFailureClass -FailureClass $class)) { $problems.Add('failureClass is not a known class') }
    $fp = [string](& $get 'fingerprint')
    if ($fp -and $fp -cnotmatch $script:FingerprintPattern) { $problems.Add('fingerprint is malformed') }
    foreach ($field in 'stage', 'reason') {
        if ((& $get $field) -isnot [string]) { $problems.Add("$field is not text") }
    }
    foreach ($item in @(& $get 'evidence')) {
        if ($item -isnot [System.Collections.IDictionary] -or [string]$item['kind'] -cnotin $script:EvidenceKindEnum) { $problems.Add('an evidence item is malformed') }
    }
    foreach ($item in @(& $get 'steps')) {
        if ($item -isnot [System.Collections.IDictionary] -or [string]$item['step'] -cnotin $script:StepEnum) { $problems.Add('a step row is malformed') }
    }
    $recovery = & $get 'recovery'
    if ($recovery -isnot [System.Collections.IDictionary]) {
        $problems.Add('recovery is not an object')
    } elseif ([string]$recovery['state'] -cnotin $script:RecoveryStateEnum) {
        $problems.Add('recovery.state is not in the vocabulary')
    }
    return [pscustomobject]@{ Valid = ($problems.Count -eq 0); Problems = @($problems) }
}

# --- REGION: Persistence of results
function Get-RecoveryResultPath {
    <#
    .SYNOPSIS
        Where the latest result and the result history live under a runtime directory.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    return [pscustomobject]@{
        Latest  = (Join-Path $RuntimeDir $script:ResultFileName)
        History = (Join-Path $RuntimeDir $script:HistoryFileName)
    }
}

function Write-RecoveryResult {
    <#
    .SYNOPSIS
        Replaces recovery.result.json and appends one line to the history.
    .DESCRIPTION
        Best-effort by design: it returns $false, with a warning, on any failure
        and never throws, because the cycle it describes has already happened and
        a telemetry problem must not change its verdict. A result that fails
        validation is not written.

        The history keeps each result once, as first recorded. A decision made
        after the cycle ended -- a repair, say -- is added to the latest file with
        -LatestOnly, so the history never holds the same result twice.
    .PARAMETER LatestOnly
        Replace recovery.result.json and leave the history alone.
    .OUTPUTS
        [bool] $true when the latest file was replaced.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [switch]$LatestOnly
    )
    try {
        $check = Test-RecoveryResult -Result $Result
        if (-not $check.Valid) {
            Write-Verbose "Write-RecoveryResult: not written, $($check.Problems -join '; ')."
            return $false
        }
        if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) { return $false }
        $paths = Get-RecoveryResultPath -RuntimeDir $RuntimeDir
        if (-not $PSCmdlet.ShouldProcess($paths.Latest, 'record the recovery result')) { return $true }
        $pretty = $Result | ConvertTo-Json -Depth 8
        $line = $Result | ConvertTo-Json -Depth 8 -Compress
        if (-not (Write-YurunaStateFile -Path $paths.Latest -Content $pretty -Confirm:$false)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.recovery_result_write_failed' -Arguments @{ path = "$($paths.Latest)"; reason = 'the file could not be replaced' })
            return $false
        }
        if ($LatestOnly) { return $true }
        try {
            [IO.File]::AppendAllText($paths.History, $line + "`n", [Text.UTF8Encoding]::new($false))
            $lines = @([IO.File]::ReadAllLines($paths.History))
            if ($lines.Count -gt $script:HistoryTrimAtLines) {
                $kept = ($lines | Select-Object -Last $script:HistoryKeepLines) -join "`n"
                $null = Write-YurunaStateFile -Path $paths.History -Content ($kept + "`n") -Confirm:$false
            }
        } catch {
            Write-Verbose "Write-RecoveryResult: history not updated: $($_.Exception.Message)"
        }
        return $true
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.recovery_result_write_failed' -Arguments @{ path = "$RuntimeDir"; reason = "$($_.Exception.Message)" })
        return $false
    }
}

function Read-RecoveryResult {
    <#
    .SYNOPSIS
        The latest persisted result, or $null when absent, unreadable or invalid.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = (Get-RecoveryResultPath -RuntimeDir $RuntimeDir).Latest
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
    } catch {
        Write-Verbose "Read-RecoveryResult: unreadable: $($_.Exception.Message)"
        return $null
    }
    if (-not (Test-RecoveryResult -Result $doc).Valid) { return $null }
    if ($doc['recordedAtUtc'] -is [datetime]) {
        $doc['recordedAtUtc'] = $doc['recordedAtUtc'].ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
    return $doc
}

function Get-RecoveryResultHistory {
    <#
    .SYNOPSIS
        The newest results from the history file, oldest first; lines that do not
        parse are skipped.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [ValidateRange(1, 1000)][int]$Last = 20
    )
    $path = (Get-RecoveryResultPath -RuntimeDir $RuntimeDir).History
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($text in @([IO.File]::ReadAllLines($path) | Select-Object -Last $Last)) {
        try { $rows.Add(($text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)) } catch { Write-Verbose "Get-RecoveryResultHistory: skipped a line that does not parse." }
    }
    return @($rows)
}

# --- REGION: Cycle outcome record
# The cycle process tells the runner that spawned it how the cycle ended through
# runner.cycle.outcome.json, because the exit-code space belongs to the inner runner
# and a sentinel number could be mistaken for a real failure. The record is
# required of every cycle: the runner scores a pass only from one that names its
# generation. Two optional fields ride along when the cycle knows them: the
# failure class and a short redacted detail, which let the runner choose a repair
# without re-deriving the cause from a bare outcome name.

# The exit code for a cycle that exited cleanly but left no usable record. Any
# non-zero value does the job -- the point is that the run stops reading as a pass --
# so this one comes from sysexits (EX_SOFTWARE) instead of the inner runner's own
# code space.
$script:UnrecordedOutcomeExitCode = 70

function Get-UnrecordedOutcomeExitCode {
    <#
    .SYNOPSIS
        The exit code that stands for a cycle whose outcome nothing recorded.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:UnrecordedOutcomeExitCode
}

function Read-CycleOutcomeRecord {
    <#
    .SYNOPSIS
        Reads the outcome record a cycle process leaves behind and says whether
        it can be believed.
    .DESCRIPTION
        A cycle counts as a pass only when the process that ran it left a record
        naming its outcome and exit code, stamped with the generation this runner
        issued. Every other shape -- no file, text that is not a JSON object, a
        field that is absent or the wrong kind, a record from another cycle --
        comes back with Valid = $false and a reason, because a verdict nothing
        recorded cannot be told apart from a cycle that never ran, and treating
        it as a clean completion is the one mistake that hides a broken runner
        behind a green host.

        The optional failureClass and detail fields never decide validity: an
        unknown class or a field of the wrong kind reads as empty.
    .PARAMETER Path
        The runner.cycle.outcome.json location.
    .PARAMETER ExpectedGeneration
        The generation the runner issued for this cycle. Empty when the caller
        issued none (the in-process shape), in which case the stamp is not
        compared; every other field is still required.
    .OUTPUTS
        pscustomobject: Valid, Reason ('ok' | 'missing' | 'malformed' |
        'stale-generation'), Detail, Outcome, ExitCode, CycleGeneration,
        FailureClass, RecordDetail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$ExpectedGeneration = ''
    )
    $verdict = {
        param([bool]$Valid, [string]$Reason, [string]$Detail, [string]$Outcome = '', $ExitCode = $null, [string]$CycleGeneration = '', [string]$FailureClass = '', [string]$RecordDetail = '')
        [pscustomobject]@{
            Valid = $Valid; Reason = $Reason; Detail = $Detail
            Outcome = $Outcome; ExitCode = $ExitCode; CycleGeneration = $CycleGeneration
            FailureClass = $FailureClass; RecordDetail = $RecordDetail
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (& $verdict $false 'missing' 'no outcome file')
    }
    try {
        # -NoEnumerate: a one-element JSON array would otherwise unroll into the
        # object it holds and pass as the record.
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    } catch {
        return (& $verdict $false 'malformed' "unreadable: $($_.Exception.Message)")
    }
    if ($doc -isnot [pscustomobject]) {
        return (& $verdict $false 'malformed' 'not a JSON object')
    }
    $outcome = $doc.PSObject.Properties['outcome']
    if (-not $outcome -or $outcome.Value -isnot [string] -or $outcome.Value -cnotmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') {
        return (& $verdict $false 'malformed' 'outcome is absent or not an outcome name')
    }
    $exit = $doc.PSObject.Properties['exitCode']
    if (-not $exit -or ($exit.Value -isnot [int] -and $exit.Value -isnot [long]) -or
        $exit.Value -lt [int]::MinValue -or $exit.Value -gt [int]::MaxValue) {
        return (& $verdict $false 'malformed' 'exitCode is absent or not an integer')
    }
    $stamp = $doc.PSObject.Properties['cycleGeneration']
    $recordedGeneration = if ($stamp -and $stamp.Value -is [string]) { [string]$stamp.Value } else { '' }
    if ($ExpectedGeneration -and $recordedGeneration -cne $ExpectedGeneration) {
        $found = if ($recordedGeneration) { "'$recordedGeneration'" } else { 'none' }
        return (& $verdict $false 'stale-generation' "record carries generation $found, runner issued '$ExpectedGeneration'")
    }
    $classField = $doc.PSObject.Properties['failureClass']
    $recordedClass = if ($classField -and $classField.Value -is [string] -and (Test-RecoveryFailureClass -FailureClass $classField.Value)) { [string]$classField.Value } else { '' }
    $detailField = $doc.PSObject.Properties['detail']
    $recordedDetail = if ($detailField -and $detailField.Value -is [string]) { ConvertTo-RecoverySafeText -Text $detailField.Value } else { '' }
    return (& $verdict $true 'ok' '' ([string]$outcome.Value) ([int]$exit.Value) $recordedGeneration $recordedClass $recordedDetail)
}

function Read-VmAdmissionRecord {
    <#
    .SYNOPSIS
        The VM-admission refusal the inner recorded for the cycle that just
        ended, or $null.
    .DESCRIPTION
        The inner refuses to start a cycle on a host it cannot show to be free of
        other guests, and leaves only an exit code behind. Alone, that reads as
        "inner exited 2" and sends an operator after the tests for a fault in the
        host. Only a refusal (occupied or unknown) written after the cycle was
        spawned counts: a record from an earlier cycle describes an earlier host.
    .PARAMETER RuntimeDir
        The runtime directory holding vm-admission.json.
    .PARAMETER NotBeforeUtc
        When the cycle was spawned; older records are ignored.
    .OUTPUTS
        [pscustomobject] State (occupied | unknown), Reason, Detail, Occupants;
        $null when there is no current refusal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)][datetime]$NotBeforeUtc
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
    $path = Join-Path $RuntimeDir 'vm-admission.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$doc.state -notin @('occupied', 'unknown')) { return $null }
        $observed = [datetime]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [datetime]::TryParse([string]$doc.observedUtc, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$observed)) { return $null }
        if ($observed -lt $NotBeforeUtc.AddSeconds(-2)) { return $null }
        return [pscustomobject]@{ State = [string]$doc.state; Reason = [string]$doc.reason; Detail = [string]$doc.detail; Occupants = @($doc.occupants) }
    } catch {
        Write-Verbose "Read-VmAdmissionRecord: could not read ${path}: $($_.Exception.Message)"
        return $null
    }
}

function Publish-CycleOutcomeRecord {
    <#
    .SYNOPSIS
        Records the cycle's outcome for the runner that spawned this process and
        returns the exit code the process must use.
    .DESCRIPTION
        The runner scores a cycle from the record this writes, so a success that
        could not be recorded must not leave as one: the record is read back
        through the validator the runner applies, and when it does not verify, a
        clean exit code is replaced by the unrecorded-outcome code. A failing
        exit code is kept as it is -- a failure stays a failure whether or not
        its record landed.

        A cycle that returned without publishing a result is recorded as
        'no-cycle-result' with a failing exit code. Defaulting it to a clean
        completion would report a pass that nothing observed.
    .PARAMETER Result
        An object with Outcome and ExitCode, or $null. FailureClass and Detail,
        when present and non-empty, are recorded beside them.
    .PARAMETER OutcomeFile
        Where the runner reads the record.
    .PARAMETER CycleGeneration
        The generation the runner issued, echoed into the record. Empty when none
        was issued.
    .OUTPUTS
        [int] The exit code for the cycle process.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]$Result,
        [Parameter(Mandatory)][string]$OutcomeFile,
        [AllowNull()][AllowEmptyString()][string]$CycleGeneration = ''
    )
    $hasVerdict = [bool]($Result -and $Result.Outcome -and $null -ne $Result.ExitCode)
    $outcome  = if ($hasVerdict) { [string]$Result.Outcome } else { 'no-cycle-result' }
    $exitCode = if ($hasVerdict) { [int]$Result.ExitCode } else { 1 }
    if (-not $hasVerdict) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.cycle_result_missing')
    }
    $recorded = $false
    try {
        $record = [ordered]@{
            outcome         = $outcome
            exitCode        = $exitCode
            cycleGeneration = if ($CycleGeneration) { $CycleGeneration } else { $null }
        }
        $classProperty = if ($hasVerdict) { $Result.PSObject.Properties['FailureClass'] } else { $null }
        if ($classProperty -and $classProperty.Value -is [string] -and $classProperty.Value -and (Test-RecoveryFailureClass -FailureClass $classProperty.Value)) {
            $record['failureClass'] = [string]$classProperty.Value
        }
        $detailProperty = if ($hasVerdict) { $Result.PSObject.Properties['Detail'] } else { $null }
        if ($detailProperty -and $detailProperty.Value -is [string] -and $detailProperty.Value) {
            $record['detail'] = ConvertTo-RecoverySafeText -Text $detailProperty.Value
        }
        $json = $record | ConvertTo-Json -Compress
        # The write reports failure by returning $false rather than throwing, so
        # the catch below would not see one. The [bool] is consumed here: this
        # process shares its parent's console, and anything left on the success
        # stream prints as a bare value between the caller's per-cycle lines.
        if (Write-YurunaStateFile -Path $OutcomeFile -Content $json -Confirm:$false) {
            $check = Read-CycleOutcomeRecord -Path $OutcomeFile -ExpectedGeneration $CycleGeneration
            $recorded = ($check.Valid -and $check.Outcome -ceq $outcome -and $check.ExitCode -eq $exitCode)
        }
        if (-not $recorded) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_28a938238a1f9f61' -Arguments @{ outcomeFile = "$OutcomeFile" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d1c2444b71ef8fde' -Arguments @{ message = "$($_.Exception.Message)" })
    }
    if (-not $recorded -and $exitCode -eq 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.cycle_success_withheld' -Arguments @{ exitCode = "$($script:UnrecordedOutcomeExitCode)" })
        $exitCode = $script:UnrecordedOutcomeExitCode
    }
    return $exitCode
}

# --- REGION: Facts read from the cycle's own records
function Get-LastFailureFact {
    <#
    .SYNOPSIS
        The fields of last_failure.json that a recovery decision needs, or $null.
    .DESCRIPTION
        Two shapes land in that file: a sequence-step record (sequenceName,
        actionVerb) and an infrastructure-stage record (reason 'infra', the stage
        in context.stage). Both reduce to class, stage, sequence and verb, so the
        fingerprint is built the same way for either. A class outside the
        vocabulary reads as 'unknown' rather than invalidating the result.
    .PARAMETER LogDir
        The log root holding last_failure.json; defaults to YURUNA_LOG_DIR.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$LogDir = $env:YURUNA_LOG_DIR)
    if (-not $LogDir) { return $null }
    $path = Join-Path $LogDir 'last_failure.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
    } catch {
        Write-Verbose "Get-LastFailureFact: $path is unreadable: $($_.Exception.Message)"
        return $null
    }
    if ($record -isnot [System.Collections.IDictionary]) { return $null }
    $context = if ($record['context'] -is [System.Collections.IDictionary]) { $record['context'] } else { @{} }
    $infra = ([string]$record['reason'] -ceq 'infra')
    $stage = if ($context['stage']) { [string]$context['stage'] } elseif ($infra -and $record['action']) { [string]$record['action'] } else { '' }
    $class = [string]$record['failureClass']
    if ($class -and -not (Test-RecoveryFailureClass -FailureClass $class)) { $class = 'unknown' }
    return [pscustomobject]@{
        Path         = $path
        FailureClass = $class
        Stage        = $stage
        SequenceName = [string]$record['sequenceName']
        ActionVerb   = [string]$record['actionVerb']
        Description  = (ConvertTo-RecoverySafeText -Text $record['description'])
        Infra        = $infra
    }
}

# --- REGION: Step functions
function Get-StepExitCode {
    <#
    .SYNOPSIS
        The entry-point exit code for an outcome name, from the shared contract
        when it is loaded and from its documented values otherwise.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][ValidateSet('Ok', 'Failure', 'CannotRun')][string]$Outcome)
    if (Get-Command Get-EntryPointExitCode -ErrorAction SilentlyContinue) { return [int](Get-EntryPointExitCode -Outcome $Outcome) }
    return @{ Ok = 0; Failure = 1; CannotRun = 2 }[$Outcome]
}

function Invoke-CycleCheckoutStep {
    <#
    .SYNOPSIS
        Refreshes <RepoRoot>/project and reports it as a step result.
    .DESCRIPTION
        The one way an entry point refreshes the project checkout. It wraps
        Update-ProjectClone, which clones beside the current checkout, verifies
        the result and swaps it in, so a failed refresh leaves the previous
        checkout in place. The step adds what a recovery decision needs: the
        failure class (bootstrap_sync), the stage name, and the redacted reason.
        ErrorMessage keeps the clone's own text for the caller to show the
        operator.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()][AllowEmptyString()][string]$ProjectUrl = ''
    )
    $clone = $null
    $thrown = ''
    try {
        $clone = Update-ProjectClone -RepoRoot $RepoRoot -ProjectUrl $ProjectUrl -Confirm:$false
    } catch {
        $thrown = $_.Exception.Message
    }
    $ok = [bool]($clone -and $clone.success)
    $skipped = [bool]($clone -and $clone.skipped)
    $message = if ($thrown) { $thrown } elseif ($clone -and $clone.errorMessage) { [string]$clone.errorMessage } else { '' }
    if (-not $ok -and -not $message) { $message = 'the project refresh reported failure without a message' }
    $revision = if ($clone -and $clone.PSObject.Properties['revision']) { [string]$clone.revision } elseif ($clone -is [System.Collections.IDictionary] -and $clone.Contains('revision')) { [string]$clone['revision'] } else { '' }
    return New-RecoveryStepResult -Step checkout -Ok $ok -Skipped:$skipped `
        -FailureClass $(if ($ok) { '' } else { 'bootstrap_sync' }) -Reason $(if ($ok) { '' } else { $message }) `
        -Extra @{ Stage = 'ProjectClone'; Revision = $revision; ErrorMessage = $message }
}

function Invoke-CycleAdmissionStep {
    <#
    .SYNOPSIS
        Stops leftover guests and requires the host to be provably free of
        others, reported as a step result.
    .DESCRIPTION
        Wraps Invoke-HostVmAdmission so the three entry points ask the question
        the same way and exit on the same codes: 0 clear, 1 occupied, 2 (cannot
        run) unknown. The verdict is recorded in vm-admission.json by the wrapped
        function whatever it is.
    .PARAMETER HostType
        The host type string.
    .PARAMETER ExceptVmName
        A VM to leave alone (the dev loop's target).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$HostType = '',
        [AllowNull()][AllowEmptyString()][string]$ExceptVmName = ''
    )
    $admission = Invoke-HostVmAdmission -HostType $HostType -ExceptVmName $ExceptVmName
    $state = [string]$admission.State
    $ok = ($state -ceq 'clear')
    $failureClass = switch ($state) { 'occupied' { 'vm_admission_occupied' } 'unknown' { 'vm_admission_unknown' } default { '' } }
    $exitCode = switch ($state) { 'clear' { Get-StepExitCode -Outcome Ok } 'unknown' { Get-StepExitCode -Outcome CannotRun } default { Get-StepExitCode -Outcome Failure } }
    $reason = if ($ok) { '' } else { "$($admission.Reason): $($admission.Detail)$(if (@($admission.Occupants).Count) { ' (' + (@($admission.Occupants) -join ', ') + ')' })" }
    return New-RecoveryStepResult -Step admission -Ok $ok -FailureClass $failureClass -Reason $reason `
        -Extra @{ Stage = 'VmAdmission'; State = $state; Occupants = @($admission.Occupants); Probes = [int]$admission.Probes; ExitCode = $exitCode }
}

function Resolve-CycleReplayStep {
    <#
    .SYNOPSIS
        Decides whether a failed sequence may be replayed from a checkpoint, as a
        step result.
    .DESCRIPTION
        Wraps Resolve-WarmResumeReplayPlan. Ok means the replay is safe; when it
        is not, Reason is one of no-restore-point, restore-point-missing or
        safety-check-unavailable and the caller keeps the original failure. When
        the planner is not loaded the answer is the last of those: an unanswered
        safety question is not a yes.
    .PARAMETER Decision
        The warm-resume decision (ResumeSequence).
    .PARAMETER Checkpoint
        The checkpoint (ResumeFromStep, FailureClass).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Decision,
        [Parameter(Mandatory)]$Checkpoint,
        [AllowEmptyString()][string]$SequencesDir = '',
        [AllowEmptyString()][string]$HostType = '',
        [AllowEmptyString()][string]$RepoRoot = '',
        [AllowEmptyString()][string]$VMName = ''
    )
    if (-not (Get-Command Resolve-WarmResumeReplayPlan -ErrorAction SilentlyContinue)) {
        return New-RecoveryStepResult -Step replay -Ok $false -Reason 'safety-check-unavailable' `
            -Extra @{ ResumeFromStep = [int]$Checkpoint.ResumeFromStep; BoundaryStep = 0; Rewound = $false; ReplayClass = 'unclassified'; DeclineReason = 'safety-check-unavailable'; Actions = @(); Classes = @() }
    }
    $plan = Resolve-WarmResumeReplayPlan -Decision $Decision -Checkpoint $Checkpoint -SequencesDir $SequencesDir -HostType $HostType -RepoRoot $RepoRoot -VMName $VMName
    $declined = [string]$plan.DeclineReason
    return New-RecoveryStepResult -Step replay -Ok (-not $declined) -Reason $(if ($declined) { $declined } else { 'ok' }) `
        -Extra @{
            ResumeFromStep = [int]$plan.ResumeFromStep; BoundaryStep = [int]$plan.BoundaryStep; Rewound = [bool]$plan.Rewound
            ReplayClass = [string]$plan.ReplayClass; DeclineReason = $declined; Actions = @($plan.Actions); Classes = @($plan.Classes)
        }
}

# --- REGION: Building the result from what an entry point knows
function Get-RecoveryEvidenceFromPath {
    <#
    .SYNOPSIS
        Evidence items for the files that exist among the given (path, note) pairs.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object[]]$Pair)
    $items = foreach ($pair in $Pair) {
        if ($pair.Path -and (Test-Path -LiteralPath $pair.Path -PathType Leaf)) {
            New-RecoveryEvidence -Kind file -Ref ([string]$pair.Path) -Note ([string]$pair.Note)
        }
    }
    return @($items)
}

function ConvertTo-RunnerRecoveryResult {
    <#
    .SYNOPSIS
        The typed result of one runner cycle, from the dispatch result and the
        records the cycle left, or $null for an outcome that is not a verdict.
    .DESCRIPTION
        drain, refresh-gated, refresh-preflight, paused and shutdown say the loop
        did not run a cycle to a conclusion, so they produce no result. Every
        other outcome maps to exactly one of the result outcomes:

          completed, exit 0                 passed
          completed, VM admission refused   cannot-run
          completed, infra stage failed     infrastructure-fault
          completed, any other failure      failed
          outcome-unrecorded / no-cycle-result   infrastructure-fault (outcome_unrecorded)
          cycle-aborted                     aborted (cycle_killed)
          pull-error                        infrastructure-fault (bootstrap_sync, FrameworkPull)
          spawn-failed                      infrastructure-fault (cycle_spawn_failed)
          storage-full                      infrastructure-fault (pool_storage_full)
    .PARAMETER Dispatch
        What Invoke-OuterCycleDispatch returned: Outcome, ExitCode, and the
        optional OutcomeReason, OutcomeDetail, RecordFailureClass, RecordDetail.
    .PARAMETER SpawnedAtUtc
        When the cycle was spawned, so a vm-admission.json older than the cycle
        is not read as its refusal.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Dispatch,
        [Parameter(Mandatory)][string]$CycleGeneration,
        [AllowNull()][AllowEmptyString()][string]$LogDir = $env:YURUNA_LOG_DIR,
        [AllowNull()][AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [datetime]$SpawnedAtUtc = ([datetime]::UtcNow),
        [hashtable]$Recovery = @{}
    )
    $name = [string]$Dispatch.Outcome
    if ($name -in @('drain', 'refresh-gated', 'refresh-preflight', 'paused', 'shutdown')) { return $null }
    $exitCode = [int]$Dispatch.ExitCode
    $property = { param([string]$Key) $p = $Dispatch.PSObject.Properties[$Key]; if ($p -and $null -ne $p.Value) { [string]$p.Value } else { '' } }
    $fact = Get-LastFailureFact -LogDir $LogDir
    $evidence = @()
    $outcome = 'failed'; $class = ''; $stage = ''; $reason = ''; $sequence = ''; $verb = ''
    switch -Exact ($name) {
        'outcome-unrecorded' {
            $outcome = 'infrastructure-fault'; $class = 'outcome_unrecorded'; $stage = 'CycleOutcome'
            $reason = "outcome record $(& $property 'OutcomeReason'): $(& $property 'OutcomeDetail'); child exited $exitCode"
            $evidence = @(Get-RecoveryEvidenceFromPath -Pair @(@{ Path = (Join-Path $RuntimeDir 'runner.cycle.outcome.rejected.json'); Note = 'the rejected record' }))
        }
        'no-cycle-result' {
            $outcome = 'infrastructure-fault'; $class = 'outcome_unrecorded'; $stage = 'CycleOutcome'
            $reason = "the cycle returned no result; child exited $exitCode"
        }
        'cycle-aborted' {
            $outcome = 'aborted'; $class = 'cycle_killed'; $stage = 'CycleStart'
            $reason = "the cycle process exited $exitCode before reporting an outcome"
        }
        'pull-error' {
            $outcome = 'infrastructure-fault'; $class = 'bootstrap_sync'; $stage = 'FrameworkPull'
            $reason = & $property 'RecordDetail'
            if (-not $reason) { $reason = 'the framework repository could not be updated' }
        }
        'spawn-failed' {
            $outcome = 'infrastructure-fault'; $class = 'cycle_spawn_failed'; $stage = 'CycleSpawn'
            $reason = 'the cycle process could not be started'
        }
        'storage-full' {
            $outcome = 'infrastructure-fault'; $class = 'pool_storage_full'; $stage = 'PoolStorage'
            $reason = 'the pool share has no room for this cycle'
        }
        default {
            if ($exitCode -eq 0) {
                $outcome = 'passed'
            } else {
                $refusal = if ($RuntimeDir) { Read-VmAdmissionRecord -RuntimeDir $RuntimeDir -NotBeforeUtc $SpawnedAtUtc } else { $null }
                if ($refusal) {
                    $outcome = 'cannot-run'; $class = "vm_admission_$($refusal.State)"; $stage = 'VmAdmission'
                    $reason = "$($refusal.Reason): $($refusal.Detail)"
                    $evidence = @(Get-RecoveryEvidenceFromPath -Pair @(@{ Path = (Join-Path $RuntimeDir 'vm-admission.json'); Note = 'the admission verdict' }))
                } else {
                    $outcome = if ($fact -and $fact.Infra) { 'infrastructure-fault' } else { 'failed' }
                    $class = if ($fact -and $fact.FailureClass) { $fact.FailureClass } else { 'unknown' }
                    if ($fact) { $stage = $fact.Stage; $sequence = $fact.SequenceName; $verb = $fact.ActionVerb; $reason = $fact.Description }
                    if (-not $reason) { $reason = "inner exited $exitCode" }
                }
            }
        }
    }
    if ($fact -and $outcome -ne 'passed') {
        $evidence = @($evidence) + @(Get-RecoveryEvidenceFromPath -Pair @(@{ Path = $fact.Path; Note = 'the failure record' }))
    }
    return New-RecoveryResult -EntryPoint runner -CycleGeneration $CycleGeneration -Outcome $outcome -ExitCode $exitCode `
        -FailureClass $class -Stage $stage -SequenceName $sequence -ActionVerb $verb -Reason $reason -Evidence $evidence -Recovery $Recovery
}

function ConvertTo-ExitRecoveryResult {
    <#
    .SYNOPSIS
        The typed result of a one-shot entry point (project or sequence), from
        its exit code, the steps it ran and the failure record it left.
    .DESCRIPTION
        A failed step names the cause first: a checkout that failed is an
        infrastructure fault of stage ProjectClone whatever the exit code says, and
        a refused admission is cannot-run. With no failed step, exit 0 is a pass,
        the cannot-run exit code is cannot-run, and anything else is read from
        last_failure.json the way the runner does.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('project', 'sequence')][string]$EntryPoint,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$CycleGeneration = '',
        [object[]]$Steps = @(),
        [AllowEmptyString()][string]$Reason = '',
        [AllowNull()][AllowEmptyString()][string]$LogDir = $env:YURUNA_LOG_DIR,
        [hashtable]$Recovery = @{}
    )
    $generation = if ($CycleGeneration -cmatch $script:GenerationPattern) { $CycleGeneration } else { Get-CycleGeneration }
    $failedStep = @($Steps | Where-Object { $_ -and -not $_.Ok -and -not $_.Skipped }) | Select-Object -First 1
    $fact = Get-LastFailureFact -LogDir $LogDir
    $outcome = 'passed'; $class = ''; $stage = ''; $sequence = ''; $verb = ''; $detail = $Reason
    $evidence = @()
    if ($failedStep) {
        $outcome = if ($failedStep.Step -ceq 'admission') { 'cannot-run' } else { 'infrastructure-fault' }
        $class = [string]$failedStep.FailureClass
        $stage = if ($failedStep.PSObject.Properties['Stage']) { [string]$failedStep.Stage } else { '' }
        if (-not $detail) { $detail = [string]$failedStep.Reason }
    } elseif ($ExitCode -ne 0) {
        $outcome = if ($ExitCode -eq (Get-StepExitCode -Outcome CannotRun)) { 'cannot-run' } elseif ($fact -and $fact.Infra) { 'infrastructure-fault' } else { 'failed' }
        $class = if ($fact -and $fact.FailureClass) { $fact.FailureClass } else { 'unknown' }
        if ($fact) { $stage = $fact.Stage; $sequence = $fact.SequenceName; $verb = $fact.ActionVerb; if (-not $detail) { $detail = $fact.Description } }
        if (-not $detail) { $detail = "exited $ExitCode" }
    }
    if ($fact -and $outcome -ne 'passed') {
        $evidence = @(Get-RecoveryEvidenceFromPath -Pair @(@{ Path = $fact.Path; Note = 'the failure record' }))
    }
    return New-RecoveryResult -EntryPoint $EntryPoint -CycleGeneration $generation -Outcome $outcome -ExitCode $ExitCode `
        -FailureClass $class -Stage $stage -SequenceName $sequence -ActionVerb $verb -Reason $detail -Evidence $evidence -Steps $Steps -Recovery $Recovery
}

function Save-RecoveryResult {
    <#
    .SYNOPSIS
        Builds and persists the result of a one-shot entry point, swallowing every
        error: recording how a run went must never change how it ends.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('project', 'sequence')][string]$EntryPoint,
        [Parameter(Mandatory)][int]$ExitCode,
        [object[]]$Steps = @(),
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    try {
        if (-not $RuntimeDir) { return $false }
        if (-not $PSCmdlet.ShouldProcess($RuntimeDir, 'record the recovery result')) { return $false }
        $result = ConvertTo-ExitRecoveryResult -EntryPoint $EntryPoint -ExitCode $ExitCode -CycleGeneration ([string]$env:YURUNA_CYCLE_GENERATION) -Steps $Steps -Reason $Reason
        return [bool](Write-RecoveryResult -Result $result -RuntimeDir $RuntimeDir -Confirm:$false)
    } catch {
        Write-Verbose "Save-RecoveryResult: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Get-RecoveryOutcomeEnum, Get-RecoveryEntryPointEnum, Get-RecoveryStateEnum, Get-RunnerFaultClassEnum, `
    Test-RecoveryFailureClass, ConvertTo-RecoverySafeText, Get-FailureFingerprint, New-RecoveryEvidence, New-RecoveryStepResult, `
    New-CycleGeneration, Get-CycleGeneration, New-RecoveryResult, Test-RecoveryResult, Get-RecoveryResultPath, `
    Write-RecoveryResult, Read-RecoveryResult, Get-RecoveryResultHistory, `
    Get-UnrecordedOutcomeExitCode, Read-CycleOutcomeRecord, Read-VmAdmissionRecord, Publish-CycleOutcomeRecord, `
    Get-LastFailureFact, Get-StepExitCode, Invoke-CycleCheckoutStep, Invoke-CycleAdmissionStep, Resolve-CycleReplayStep, `
    Get-RecoveryEvidenceFromPath, ConvertTo-RunnerRecoveryResult, ConvertTo-ExitRecoveryResult, Save-RecoveryResult
