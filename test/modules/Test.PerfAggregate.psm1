<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b4d827-01c6-44d5-935b-fca352ec41b3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test performance
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

function ConvertTo-PerfUtc {
    <#
    .SYNOPSIS
        Normalize a JSON timestamp without a culture-dependent DateTime round trip.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime().ToString('o')
    } catch { return $null }
}

function ConvertTo-PerfInteger {
    <#
    .SYNOPSIS
        Read a nonnegative integer from incomplete or older performance rows.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowNull()]$Value, [long]$Default = 0)
    $number = 0L
    if ([long]::TryParse([string]$Value, [ref]$number) -and $number -ge 0) { return $number }
    return [long]$Default
}

function ConvertTo-PerfSequenceAggregate {
    <#
    .SYNOPSIS
        Group performance rows by sequence invocation, counting enclosing work once.
    .DESCRIPTION
        Schema 2 carries an invocation identity. Older rows can be split when the
        chronological top-level ordinal restarts; that inference cannot distinguish
        concurrent runs or recover a boundary with no completed top-level step.
        Children remain available for the timeline and retry history. Their failures
        never replace the enclosing retry's final outcome.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]]$Row = @())
    $groups = @{}
    foreach ($item in $Row) {
        if (-not $item.sequenceName -or -not $item.cycleStartUtc) { continue }
        $cycle = ConvertTo-PerfUtc $item.cycleStartUtc
        if (-not $cycle) { continue }
        $start = ConvertTo-PerfUtc $item.startedAtUtc
        $end = ConvertTo-PerfUtc $item.endedAtUtc
        $startMs = $null; $endMs = $null
        if ($start -and $end) {
            $startMs = [DateTimeOffset]::Parse($start, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
            $endMs = [DateTimeOffset]::Parse($end, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
            if ($endMs -lt $startMs) { $startMs = $null; $endMs = $null }
        }
        $entry = [ordered]@{
            ordinal = (ConvertTo-PerfInteger $item.stepOrdinal)
            occurrence = (ConvertTo-PerfInteger $item.stepOccurrence -Default 1)
            name = [string]$item.stepName
            kind = [string]$item.stepKind
            durationMs = (ConvertTo-PerfInteger $item.durationMs)
            outcome = [string]$item.outcome
            parentOrdinal = (ConvertTo-PerfInteger $item.parentStepOrdinal)
            parentAction = [string]$item.parentAction
            parentAttempt = (ConvertTo-PerfInteger $item.parentAttempt)
            startedMs = $startMs
            endedMs = $endMs
            startedAtUtc = $start
            endedAtUtc = $end
            stepInvocationId = [string]$item.stepInvocationId
        }
        foreach ($field in 'diagnosticOutcome', 'checkpointSourceStepInvocationId') {
            if ($item.$field) { $entry[$field] = [string]$item.$field }
        }
        if ($item.evidenceCaptureDurationMs) { $entry.evidenceCaptureDurationMs = ConvertTo-PerfInteger $item.evidenceCaptureDurationMs }
        $hostKey = if ($item.hostUuid) { [string]$item.hostUuid } else { [string]$item.hostname }
        $key = @($hostKey, $cycle, [string]$item.sequenceName) | ConvertTo-Json -Compress
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [Collections.Generic.List[object]]::new() }
        $groups[$key].Add(@{ row = $item; step = $entry; cycle = $cycle })
    }

    $sequences = @{}
    foreach ($group in $groups.Values) {
        $ordered = @($group | Sort-Object -Stable @{ Expression = { if ($null -eq $_.step.startedMs) { [long]::MaxValue } else { $_.step.startedMs } } },
            @{ Expression = { $_.step.endedMs }; Descending = $true })
        $runs = @{}
        $legacyRun = 0
        $lastOrdinal = -1L
        foreach ($record in $ordered) {
            $item = $record.row; $step = $record.step
            $id = [string]$item.sequenceInvocationId
            $source = 'recorded'
            if (-not $id) {
                $source = 'legacy-inferred'
                if ($legacyRun -eq 0 -or ($step.parentOrdinal -eq 0 -and $step.ordinal -le $lastOrdinal)) {
                    $legacyRun++
                    $lastOrdinal = -1L
                }
                if ($step.parentOrdinal -eq 0) { $lastOrdinal = $step.ordinal }
                $id = "legacy-$legacyRun"
            }
            $runKey = "$source|$id"
            if (-not $runs.ContainsKey($runKey)) {
                $runs[$runKey] = [ordered]@{
                    cycleStartUtc = ([DateTimeOffset]::Parse($record.cycle, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
                    cycleStartedAtUtc = (ConvertTo-PerfUtc $item.cycleStartedAtUtc)
                    hostUuid = [string]$item.hostUuid
                    hostPlatform = [string]$item.hostPlatform
                    guestKey = [string]$item.guestKey
                    vmName = [string]$item.vmName
                    sequenceInvocationId = $id
                    invocationIdentitySource = $source
                    durationMs = 0L
                    elapsedMs = $null
                    stepCount = 0
                    failCount = 0
                    retryFailureCount = 0
                    diagnosticIncompleteCount = 0
                    incompleteStepCount = 0
                    invocationStartedAtUtc = $step.startedAtUtc
                    steps = [Collections.Generic.List[object]]::new()
                }
            }
            $agg = $runs[$runKey]
            $step.sequenceInvocationId = $id
            $agg.steps.Add($step)
            if ($step.parentOrdinal -eq 0) {
                $agg.durationMs += $step.durationMs
                $agg.stepCount++
                if ($step.outcome -in @('fail', 'timeout')) { $agg.failCount++ }
            } elseif ($step.outcome -in @('fail', 'timeout')) { $agg.retryFailureCount++ }
            if ($step.diagnosticOutcome -and $step.diagnosticOutcome -ne 'complete') { $agg.diagnosticIncompleteCount++ }
        }
        foreach ($agg in $runs.Values) {
            $timed = @($agg.steps | Where-Object { $null -ne $_.startedMs -and $null -ne $_.endedMs })
            if ($timed.Count -eq $agg.steps.Count -and $timed.Count -gt 0) {
                $agg.elapsedMs = [long](($timed.endedMs | Measure-Object -Maximum).Maximum - ($timed.startedMs | Measure-Object -Minimum).Minimum)
            }
            # A killed enclosing action may never emit its final row. Keep this
            # absence visible instead of reporting the remaining child rows as a pass.
            $top = @($agg.steps | Where-Object { $_.parentOrdinal -eq 0 })
            foreach ($child in @($agg.steps | Where-Object { $_.parentOrdinal -gt 0 })) {
                $container = @($top | Where-Object {
                    if ($null -eq $_.startedMs -or $null -eq $child.startedMs) { $_.ordinal -eq $child.parentOrdinal }
                    else { $_.startedMs -le $child.startedMs -and $_.endedMs -ge $child.endedMs }
                })
                if ($container.Count -eq 0) { $agg.incompleteStepCount++ }
            }
            $agg.steps = @($agg.steps)
            $seq = [string]$group[0].row.sequenceName
            if (-not $sequences.ContainsKey($seq)) { $sequences[$seq] = [Collections.Generic.List[object]]::new() }
            $sequences[$seq].Add($agg)
        }
    }
    foreach ($seq in @($sequences.Keys)) {
        $sequences[$seq] = @($sequences[$seq] | Sort-Object @{ Expression = { [string]$_.cycleStartedAtUtc } },
            @{ Expression = { [string]$_.invocationStartedAtUtc } }, @{ Expression = { [string]$_.sequenceInvocationId } })
    }
    return $sequences
}

function Find-PerfCheckpoint {
    <#
    .SYNOPSIS
        Match a checkpoint to its execution, using time only for untagged legacy data.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [AllowEmptyCollection()][object[]]$Sidecar = @())
    if ($Step.checkpointSourceStepInvocationId) { return $null }
    foreach ($candidate in $Sidecar) {
        if ($candidate.Consumed) { continue }
        if ($candidate.StepInvocationId -or $candidate.SequenceInvocationId) {
            if ($candidate.StepInvocationId -and $candidate.SequenceInvocationId -and
                $candidate.StepInvocationId -eq $Step.stepInvocationId -and
                $candidate.SequenceInvocationId -eq $Step.sequenceInvocationId) { return $candidate }
            continue
        }
        $start = ConvertTo-PerfUtc $Step.startedAtUtc
        $end = ConvertTo-PerfUtc $Step.endedAtUtc
        $received = ConvertTo-PerfUtc $candidate.ReceivedAt
        if (-not $start -or -not $end -or -not $received) { continue }
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $instant = [DateTimeOffset]::Parse($received, $culture)
        if ($instant -ge [DateTimeOffset]::Parse($start, $culture) -and
            $instant -le [DateTimeOffset]::Parse($end, $culture)) { return $candidate }
    }
    return $null
}

Export-ModuleMember -Function ConvertTo-PerfSequenceAggregate, Find-PerfCheckpoint
