<#PSScriptInfo
.VERSION 2026.07.21
.GUID 421f2a9e-4b6d-4e83-9a5c-2d8e1f0b3c47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner circuit-breaker guest-quarantine
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

# Guest quarantine / circuit breaker. Persists a per-guest consecutive-failure
# count keyed by failureClass in runner.quarantine.json (sibling of
# runner.gating.json, same runtime dir, surviving the single-cycle inner
# respawn). After N failures of the SAME class a guest is quarantined and
# skipped for up to M cycles or until a framework/project commit changes -- so
# a deterministically-broken guest stops burning a full provision+deploy every
# cycle, while a flaky guest that fails differently each time is never trapped.
# Keeping the class in the streak is deliberate: only a repeating, identical
# failure is "deterministic"; a different class each time is noise, not a stuck
# guest. The decision core is pure (no I/O) so it is unit-testable; the file
# read/write and the guest_quarantined event emit are thin wrappers. Leaf
# module: the two emit/persist dependencies (Send-CycleEventSafely,
# Write-YurunaStateFileJson) are resolved at call time and Get-Command-guarded,
# so load order among the runner modules does not matter.

$script:GuestQuarantineFileName = 'runner.quarantine.json'

function Get-GuestQuarantineUtcNow {
    <#
    .SYNOPSIS
        ISO-8601 UTC 'Z' timestamp matching the telemetry event envelope format.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command Get-UtcTimestamp -ErrorAction SilentlyContinue) { return [string](Get-UtcTimestamp) }
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function New-GuestQuarantineState {
    <#
    .SYNOPSIS
        A fresh, empty quarantine-state object: { guests = @{} }.
    .OUTPUTS
        [hashtable] with a single 'guests' hashtable keyed by guestKey.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh state hashtable; changes no externally observable state.')]
    param()
    return @{ guests = @{} }
}

function Get-GuestQuarantineDecision {
    <#
    .SYNOPSIS
        Decide, without side effects, whether a guest should be skipped this
        cycle: 'none' (run it), 'skip' (quarantined, budget remains), or
        'release' (a new commit or an exhausted skip budget re-admits it).
    .DESCRIPTION
        Pure: reads $State and returns the decision plus the intended state
        change (Action) for the caller to apply, so the counting logic stays
        testable independent of the file I/O.
    .OUTPUTS
        [hashtable] Skip [bool], Reason [string], Action ('none'|'skip'|'release'),
        SkipCyclesRemaining [int] (the value to persist on an 'skip').
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit
    )
    if (-not ($State.guests -is [System.Collections.IDictionary]) -or -not $State.guests.Contains($GuestKey)) {
        return @{ Skip = $false; Reason = 'not-tracked'; Action = 'none' }
    }
    $e = $State.guests[$GuestKey]
    if (-not [bool]$e.quarantined) {
        return @{ Skip = $false; Reason = 'not-quarantined'; Action = 'none' }
    }
    $curFw = if ($null -eq $GitCommit) { '' } else { [string]$GitCommit }
    $curPj = if ($null -eq $ProjectGitCommit) { '' } else { [string]$ProjectGitCommit }
    $qFw = [string]$e.quarantinedAtCommit
    $qPj = [string]$e.quarantinedAtProjectCommit
    # A new framework OR project commit may carry the fix -> release and re-test.
    # An empty current commit (discovery failed) is not treated as "changed".
    if (($curFw -ne '' -and $curFw -ne $qFw) -or ($curPj -ne '' -and $curPj -ne $qPj)) {
        return @{ Skip = $false; Reason = 'released-new-commit'; Action = 'release' }
    }
    if ([int]$e.skipCyclesRemaining -le 0) {
        # Skip budget spent -> re-admit and re-probe; a still-broken guest simply
        # re-quarantines after another N same-class failures.
        return @{ Skip = $false; Reason = 'released-budget-exhausted'; Action = 'release' }
    }
    return @{ Skip = $true; Reason = 'quarantined'; Action = 'skip'; SkipCyclesRemaining = ([int]$e.skipCyclesRemaining - 1) }
}

function Add-GuestQuarantineFailure {
    <#
    .SYNOPSIS
        Record a guest failure of the given class into $State (mutated in place):
        extend the same-class streak (or reset it on a class change), and trip
        quarantine once the streak reaches -FailuresToQuarantine.
    .OUTPUTS
        [hashtable] NewlyQuarantined [bool], ConsecutiveFailures [int],
        FailureClass [string] (normalised, 'unknown' when blank).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowNull()][string]$FailureClass,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit,
        [Parameter(Mandatory)][int]$FailuresToQuarantine,
        [Parameter(Mandatory)][int]$SkipCycles
    )
    $fc = if ([string]::IsNullOrWhiteSpace($FailureClass)) { 'unknown' } else { [string]$FailureClass }
    if (-not ($State.guests -is [System.Collections.IDictionary])) { $State.guests = @{} }
    if (-not $State.guests.Contains($GuestKey)) {
        $State.guests[$GuestKey] = @{
            failureClass               = ''
            consecutiveFailures        = 0
            quarantined                = $false
            quarantinedAtCommit        = ''
            quarantinedAtProjectCommit = ''
            skipCyclesRemaining        = 0
            quarantinedAtUtc           = ''
        }
    }
    $e = $State.guests[$GuestKey]
    if ([string]$e.failureClass -eq $fc) {
        $e.consecutiveFailures = [int]$e.consecutiveFailures + 1
    } else {
        $e.failureClass = $fc
        $e.consecutiveFailures = 1
    }
    $newly = $false
    if (-not [bool]$e.quarantined -and [int]$e.consecutiveFailures -ge $FailuresToQuarantine) {
        $e.quarantined                = $true
        $e.quarantinedAtCommit        = if ($null -eq $GitCommit) { '' } else { [string]$GitCommit }
        $e.quarantinedAtProjectCommit = if ($null -eq $ProjectGitCommit) { '' } else { [string]$ProjectGitCommit }
        $e.skipCyclesRemaining        = $SkipCycles
        $e.quarantinedAtUtc           = (Get-GuestQuarantineUtcNow)
        $newly = $true
    }
    return @{ NewlyQuarantined = $newly; ConsecutiveFailures = [int]$e.consecutiveFailures; FailureClass = $fc }
}

function Clear-GuestQuarantineEntry {
    <#
    .SYNOPSIS
        Drop a guest's quarantine record from $State (mutated in place). Called
        on a clean pass so a recovered guest starts each streak from zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$GuestKey
    )
    if ($State.guests -is [System.Collections.IDictionary] -and $State.guests.Contains($GuestKey)) {
        $State.guests.Remove($GuestKey)
    }
}

function New-GuestQuarantineEvent {
    <#
    .SYNOPSIS
        Build the schema-valid guest_quarantined NDJSON event envelope. Blank
        context fields are dropped so the typed-string schema check passes.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] the event record.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory builder: returns a fresh event hashtable; changes no externally observable state.')]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowNull()][string]$VmName,
        [AllowNull()][string]$FailureClass,
        [int]$ConsecutiveFailures,
        [int]$SkipCycles,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit,
        [AllowNull()][string]$HostType
    )
    $emit = [ordered]@{
        timestamp              = (Get-GuestQuarantineUtcNow)
        event                  = 'guest_quarantined'
        guestKey               = [string]$GuestKey
        failureClass           = if ([string]::IsNullOrWhiteSpace($FailureClass)) { 'unknown' } else { [string]$FailureClass }
        consecutiveFailures    = [int]$ConsecutiveFailures
        skipCycles             = [int]$SkipCycles
        quarantinedUntilCommit = if ($null -eq $GitCommit) { '' } else { [string]$GitCommit }
    }
    if ($ProjectGitCommit) { $emit['quarantinedUntilProjectCommit'] = [string]$ProjectGitCommit }
    if ($VmName)           { $emit['vmName']   = [string]$VmName }
    if ($HostType)         { $emit['hostType'] = [string]$HostType }
    return $emit
}

function Read-GuestQuarantineState {
    <#
    .SYNOPSIS
        Load runner.quarantine.json into a normalised state hashtable, with a
        soft parse fallback (a corrupt/partial file resets to empty, warns once).
    .OUTPUTS
        [hashtable] the quarantine state (see New-GuestQuarantineState).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return (New-GuestQuarantineState) }
    try {
        $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $state = New-GuestQuarantineState
        if ($obj -is [System.Collections.IDictionary] -and $obj.Contains('guests') -and $obj['guests'] -is [System.Collections.IDictionary]) {
            foreach ($k in @($obj['guests'].Keys)) {
                $src = $obj['guests'][$k]
                if ($src -is [System.Collections.IDictionary]) {
                    $state.guests[[string]$k] = @{
                        failureClass               = [string]$src['failureClass']
                        consecutiveFailures        = [int]($src['consecutiveFailures'] ?? 0)
                        quarantined                = [bool]($src['quarantined'] ?? $false)
                        quarantinedAtCommit        = [string]$src['quarantinedAtCommit']
                        quarantinedAtProjectCommit = [string]$src['quarantinedAtProjectCommit']
                        skipCyclesRemaining        = [int]($src['skipCyclesRemaining'] ?? 0)
                        quarantinedAtUtc           = [string]$src['quarantinedAtUtc']
                    }
                }
            }
        }
        return $state
    } catch {
        Write-Warning "Could not parse $Path (resetting guest-quarantine state): $($_.Exception.Message)"
        return (New-GuestQuarantineState)
    }
}

function Save-GuestQuarantineState {
    <#
    .SYNOPSIS
        Persist the quarantine state to runner.quarantine.json (atomic,
        -WithBom, matching the runner.gating.json sibling). Best-effort: a write
        failure warns and returns $false rather than failing the cycle.
    .OUTPUTS
        [bool] $true on success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )
    $State['savedAt'] = (Get-GuestQuarantineUtcNow)
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return [bool](Write-YurunaStateFileJson -Path $Path -InputObject $State -Depth 6 -Compress:$false -WithBom)
    }
    # Fallback for when Test.StateFile is not loaded (e.g. isolated unit runs):
    # a BOM-less UTF-8 write, non-atomic but sufficient off the runner path.
    try {
        $json = $State | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Warning "Could not write $Path`: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-GuestQuarantineGate {
    <#
    .SYNOPSIS
        Cycle-start gate for one guest: read runner.quarantine.json, decide
        skip/run/release, persist the applied change, and report whether to skip.
    .OUTPUTS
        [hashtable] Skip [bool], Reason [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit
    )
    $path = Join-Path $RuntimeDir $script:GuestQuarantineFileName
    $state = Read-GuestQuarantineState -Path $path
    $d = Get-GuestQuarantineDecision -State $state -GuestKey $GuestKey -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit
    switch ($d.Action) {
        'release' {
            Clear-GuestQuarantineEntry -State $state -GuestKey $GuestKey
            [void](Save-GuestQuarantineState -Path $path -State $state)
        }
        'skip' {
            $state.guests[$GuestKey].skipCyclesRemaining = [int]$d.SkipCyclesRemaining
            [void](Save-GuestQuarantineState -Path $path -State $state)
        }
        default { }
    }
    return @{ Skip = [bool]$d.Skip; Reason = [string]$d.Reason }
}

function Register-GuestQuarantineOutcome {
    <#
    .SYNOPSIS
        Post-iteration hook for one guest: fold a pass or fail into
        runner.quarantine.json and, when a failure newly trips quarantine, emit
        the guest_quarantined NDJSON event.
    .OUTPUTS
        [hashtable] NewlyQuarantined [bool], ConsecutiveFailures [int],
        FailureClass [string], QuarantinedUntilCommit [string].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail')][string]$Outcome,
        [AllowNull()][string]$FailureClass,
        [AllowNull()][string]$VmName,
        [AllowNull()][string]$GitCommit,
        [AllowNull()][string]$ProjectGitCommit,
        [AllowNull()][string]$HostType,
        [int]$FailuresToQuarantine = 3,
        [int]$SkipCycles = 5
    )
    $path = Join-Path $RuntimeDir $script:GuestQuarantineFileName
    $state = Read-GuestQuarantineState -Path $path
    if ($Outcome -eq 'pass') {
        Clear-GuestQuarantineEntry -State $state -GuestKey $GuestKey
        [void](Save-GuestQuarantineState -Path $path -State $state)
        return @{ NewlyQuarantined = $false; ConsecutiveFailures = 0; FailureClass = ''; QuarantinedUntilCommit = '' }
    }
    $r = Add-GuestQuarantineFailure -State $state -GuestKey $GuestKey -FailureClass $FailureClass `
        -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit `
        -FailuresToQuarantine $FailuresToQuarantine -SkipCycles $SkipCycles
    [void](Save-GuestQuarantineState -Path $path -State $state)
    if ($r.NewlyQuarantined -and (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue)) {
        $ev = New-GuestQuarantineEvent -GuestKey $GuestKey -VmName $VmName -FailureClass $r.FailureClass `
            -ConsecutiveFailures $r.ConsecutiveFailures -SkipCycles $SkipCycles `
            -GitCommit $GitCommit -ProjectGitCommit $ProjectGitCommit -HostType $HostType
        Send-CycleEventSafely -EventRecord ([hashtable]$ev)
    }
    return @{
        NewlyQuarantined       = [bool]$r.NewlyQuarantined
        ConsecutiveFailures    = [int]$r.ConsecutiveFailures
        FailureClass           = [string]$r.FailureClass
        QuarantinedUntilCommit = if ($null -eq $GitCommit) { '' } else { [string]$GitCommit }
    }
}

Export-ModuleMember -Function `
    New-GuestQuarantineState, Get-GuestQuarantineDecision, Add-GuestQuarantineFailure, `
    Clear-GuestQuarantineEntry, New-GuestQuarantineEvent, Read-GuestQuarantineState, `
    Save-GuestQuarantineState, Invoke-GuestQuarantineGate, Register-GuestQuarantineOutcome
