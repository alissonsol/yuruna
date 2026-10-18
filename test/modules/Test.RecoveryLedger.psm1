<#PSScriptInfo
.VERSION 2026.10.18
.GUID 425779d7-e711-456a-80b5-6b5e2f85b853
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery ledger attempt-budget action-registry
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
    The durable record that bounds what the runner may repair on its own: an
    append-only attempt ledger, the registry of repairs, and the protocol that
    runs one of them.
.DESCRIPTION
    A repair that fails leaves the machine no worse than before only if the
    runner remembers having tried it. A counter in the outer loop's memory is
    reset by the restart that very often follows a failure, so a deterministic
    fault that outlives a restart would be retried without bound. This module
    keeps that memory in recovery.ledger.ndjson under the runtime directory and
    derives every decision from the file, so a new process reading the same file
    reaches the same answer.

    Three rules shape the code:

      * Write before act. The 'started' line is appended and flushed before an
        action runs; if it cannot be written the action does not run. No durable
        record, no repair.
      * Fail closed. A ledger that exists but cannot be read counts as an
        exhausted budget, never as an empty one.
      * Nothing escapes. An exception in any registered scriptblock is a failed
        step with a reason, not an unhandled error, so a faulty repair cannot
        take the outer loop down with it.

    The design record is dev-only/design/recovery-contract.md (sections 6 and 7).
    Callers wrap results of the array-returning functions in @(...): the
    functions emit their elements and a lone element would otherwise unroll.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryContract.psm1') -Force -DisableNameChecking -Global

# --- REGION: Constants
$script:LedgerFileName = 'recovery.ledger.ndjson'
$script:LedgerSchemaVersion = 1
# Rewritten once it passes this size, so a steady stream of failures cannot grow
# the file without bound.
$script:LedgerCompactBytes = 262144
$script:LedgerKeepDays = 7
# An attempt budget expires on its own after this long, so a fault that was
# fixed by hand does not leave a repair locked out until the next pass.
$script:AttemptWindowHours = 24
# A 'started' line with no terminal line is another process still working until
# it is this old; after that the process is assumed dead.
$script:AbandonAfterMinutes = 10
$script:IoRetries = 3
$script:IoRetryDelayMs = 50
# A record carries pointers to its evidence, not the evidence itself; the cap
# keeps one line, and so the file, small.
$script:LineEvidenceMax = 20
$script:MaxAbandonPasses = 10
# Appending in .NET tracks its own end-of-file offset, so two processes that
# append at once overwrite each other's lines without either seeing an error.
# Every write to the ledger therefore holds this companion file open exclusively;
# the holder keeps it for one append or one compaction, so a writer waits for it
# in IoRetryDelayMs steps, at most this many.
$script:GuardFileName = 'recovery.ledger.guard'
$script:GuardWaitSteps = 40
$script:RecordKeyOrder = @('v', 'at', 'kind', 'phase', 'scope', 'attemptId', 'fingerprint', 'failureClass', 'action', 'attempt', 'generation', 'reason', 'evidence')

# Registration order is the planning order, so the registry must be ordered:
# the default comparer builds an ordered dictionary, the Ordinal one does not.
$script:RecoveryActionRegistry = New-YurunaRegistry -Name 'RecoveryAction' -AnchorVar 'YurunaRecoveryActions' -Comparer 'OrdinalIgnoreCase'

# --- REGION: Time and value helpers
function ConvertTo-RecoveryTimestamp {
    <#
    .SYNOPSIS
        The canonical UTC text for a moment: yyyy-MM-ddTHH:mm:ssZ.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Time)
    return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-RecoveryDateTime {
    <#
    .SYNOPSIS
        A UTC moment from a DateTime or from canonical text; $null for anything else.
    #>
    [CmdletBinding()]
    [OutputType([datetime], [object])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -isnot [string]) { return $null }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-RecoveryPlainValue {
    <#
    .SYNOPSIS
        A parsed ledger value with every DateTime turned back into canonical text.
    .DESCRIPTION
        ConvertFrom-Json, even with -AsHashtable, turns any string that looks like
        an ISO timestamp into a DateTime, nested values included. A reader that
        compared such a value to the text it was written as would never match, so
        everything that leaves the ledger is text again.
    #>
    [CmdletBinding()]
    [OutputType([object], [hashtable], [object[]])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return (ConvertTo-RecoveryTimestamp -Time $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in @($Value.Keys)) { $copy[$key] = ConvertTo-RecoveryPlainValue -Value $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-RecoveryPlainValue -Value $item)) }
        return , $items.ToArray()
    }
    return $Value
}

function Protect-RecoveryLedgerValue {
    <#
    .SYNOPSIS
        A value ready to be written: every string passed through the contract
        module's redaction, every DateTime made canonical text.
    .DESCRIPTION
        Reasons and evidence notes are copied from command output, which can carry
        a URL with embedded credentials. The ledger is kept for diagnosis and may
        be read or copied off the machine, so the text is scrubbed on the way in.
        Every string is treated as free text, because a field added later should
        be covered by default rather than by remembering to list it.
    #>
    [CmdletBinding()]
    [OutputType([object], [System.Collections.Specialized.OrderedDictionary], [object[]])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (ConvertTo-RecoverySafeText -Text $Value) }
    if ($Value -is [datetime]) { return (ConvertTo-RecoveryTimestamp -Time $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = Protect-RecoveryLedgerValue -Value $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((Protect-RecoveryLedgerValue -Value $item)) }
        return , $items.ToArray()
    }
    return $Value
}

function Get-RecoveryFieldText {
    <#
    .SYNOPSIS
        A field of a dictionary as text, or '' when the dictionary lacks it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Source,
        [Parameter(Mandatory)][string]$Key
    )
    if ($Source -is [System.Collections.IDictionary] -and $Source.Contains($Key) -and $null -ne $Source[$Key]) { return [string]$Source[$Key] }
    return ''
}

# --- REGION: The ledger file
function Get-RecoveryLedgerPath {
    <#
    .SYNOPSIS
        Where the ledger lives under a runtime directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    return (Join-Path $RuntimeDir $script:LedgerFileName)
}

function Read-RecoveryLedgerEntry {
    <#
    .SYNOPSIS
        The parsed lines of the ledger with their position and original text.
    .DESCRIPTION
        Entries carry Index (file order), Line (the text as stored), Record (the
        parsed hashtable, its top level made text), At (a UTC DateTime) and the
        text of the fields the accounting reads -- Kind, Phase, AttemptId, Action,
        Fingerprint, Scope -- taken once here so the loops that count do not each
        look them up again. A line that is not a JSON object, or whose kind or
        time is unusable, cannot take part in any accounting and is counted in
        Skipped; so is the fragment a torn write leaves. Readable is $false when
        the file exists but cannot be read, which callers must treat as
        "unknown", never as "empty".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = Get-RecoveryLedgerPath -RuntimeDir $RuntimeDir
    $empty = [pscustomobject]@{ Entries = @(); Skipped = 0; Readable = $true }
    if (Test-Path -LiteralPath $path -PathType Container) {
        return [pscustomobject]@{ Entries = @(); Skipped = 0; Readable = $false }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $empty }
    # Opened so that a read never blocks an appender or a compaction, and is never
    # blocked by one. A byte order mark that an editor added is honored: left in the
    # text it would make the first line unreadable, and that line may be the one
    # that spent an attempt.
    $text = $null
    for ($try = 0; $try -le $script:IoRetries; $try++) {
        if ($try -gt 0) { Start-Sleep -Milliseconds $script:IoRetryDelayMs }
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $text = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true).ReadToEnd() } finally { $stream.Dispose() }
            break
        } catch [System.IO.FileNotFoundException] {
            return $empty
        } catch [System.IO.IOException] {
            Write-Verbose "Read-RecoveryLedgerEntry: read attempt $($try + 1) failed: $($_.Exception.Message)"
        } catch {
            Write-Verbose "Read-RecoveryLedgerEntry: the ledger cannot be read: $($_.Exception.Message)"
            break
        }
    }
    if ($null -eq $text) { return [pscustomobject]@{ Entries = @(); Skipped = 0; Readable = $false } }

    $entries = [Collections.Generic.List[object]]::new()
    $skipped = 0
    $index = 0
    foreach ($line in ($text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        $parsed = $null
        try { $parsed = $trimmed | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop } catch { $parsed = $null }
        if ($parsed -isnot [System.Collections.IDictionary]) { $skipped++; continue }
        # Assigned in two steps: an if expression would unroll a one-element array into
        # its element.
        $record = @{}
        foreach ($key in $parsed.Keys) {
            $value = $parsed[$key]
            if ($value -is [datetime]) { $value = ConvertTo-RecoveryTimestamp -Time $value }
            $record[$key] = $value
        }
        $kind = [string]$record['kind']
        $at = ConvertTo-RecoveryDateTime -Value $record['at']
        if ($kind.Length -eq 0 -or $null -eq $at) { $skipped++; continue }
        $entries.Add([pscustomobject]@{
                Index = $index; Line = $trimmed; Record = $record; At = $at
                Kind = $kind; Phase = [string]$record['phase']; AttemptId = [string]$record['attemptId']
                Action = [string]$record['action']; Fingerprint = [string]$record['fingerprint']; Scope = [string]$record['scope']
            })
        $index++
    }
    return [pscustomobject]@{ Entries = $entries; Skipped = $skipped; Readable = $true }
}

function Read-RecoveryLedger {
    <#
    .SYNOPSIS
        Every usable record of the ledger in file order, and how many lines were
        skipped.
    .DESCRIPTION
        Records are hashtables whose 'at' is always canonical text. Skipped counts
        the lines that did not parse into a record -- a torn last write, a stray
        edit -- and is reported rather than fatal. Readable is $false when the file
        exists but could not be read.
    .OUTPUTS
        pscustomobject: Records (hashtable[]), Skipped (int), Readable (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $read = Read-RecoveryLedgerEntry -RuntimeDir $RuntimeDir
    $records = [Collections.Generic.List[hashtable]]::new()
    foreach ($entry in $read.Entries) { $records.Add((ConvertTo-RecoveryPlainValue -Value $entry.Record)) }
    return [pscustomobject]@{ Records = @($records); Skipped = [int]$read.Skipped; Readable = [bool]$read.Readable }
}

function Lock-RecoveryLedger {
    <#
    .SYNOPSIS
        Takes the exclusive writer guard of the ledger; returns the open stream to
        dispose when the write is done, or $null when the guard could not be had.
    .DESCRIPTION
        The guard is a companion file opened with no sharing, so a second writer in
        another process waits for it instead of appending over the first. The
        operating system releases it when the holder's handle closes, including
        when the holder dies, so a crash never leaves it taken. A missing runtime
        directory is not worth waiting for and answers $null at once.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream], [object])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $guardPath = Join-Path $RuntimeDir $script:GuardFileName
    for ($step = 0; $step -le $script:GuardWaitSteps; $step++) {
        if ($step -gt 0) { Start-Sleep -Milliseconds $script:IoRetryDelayMs }
        try {
            return [IO.FileStream]::new($guardPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [System.IO.DirectoryNotFoundException] {
            Write-Verbose "Lock-RecoveryLedger: the runtime directory is missing: $($_.Exception.Message)"
            return $null
        } catch [System.IO.IOException] {
            Write-Verbose "Lock-RecoveryLedger: the guard is held by another writer (step $step)."
        } catch {
            Write-Verbose "Lock-RecoveryLedger: the guard cannot be opened: $($_.Exception.Message)"
            return $null
        }
    }
    Write-Verbose "Lock-RecoveryLedger: the guard was still held after $($script:GuardWaitSteps) waits."
    return $null
}

function Add-RecoveryLedgerRecord {
    <#
    .SYNOPSIS
        Appends one record to the ledger; $true only when the line is on disk.
    .DESCRIPTION
        Stamps v and at when the record lacks them, redacts every string, and
        writes one UTF-8 (no BOM) line with a single flushed append, holding the
        writer guard so that no other process appends at the same moment. A
        sharing violation on the ledger is retried a few times; any other failure
        returns $false at once. It never throws: the caller treats $false as "no
        durable record" and does not act.

        When the file does not end in a newline -- a torn write -- the new line
        starts with one, so a good record is never glued onto the fragment and
        lost with it.
    .PARAMETER Record
        The record. It needs a non-empty 'kind'; the caller's object is not
        modified.
    .PARAMETER Now
        For tests; defaults to the current time.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [datetime]$Now
    )
    try {
        if ((Get-RecoveryFieldText -Source $Record -Key 'kind').Length -eq 0) {
            Write-Verbose 'Add-RecoveryLedgerRecord: not written, the record has no kind.'
            return $false
        }
        $stamp = if ($PSBoundParameters.ContainsKey('Now')) { $Now.ToUniversalTime() } else { [datetime]::UtcNow }
        $line = [ordered]@{}
        $line['v'] = if ($Record.Contains('v') -and $null -ne $Record['v']) { $Record['v'] } else { $script:LedgerSchemaVersion }
        $at = if ($Record.Contains('at')) { ConvertTo-RecoveryDateTime -Value $Record['at'] } else { $null }
        $line['at'] = ConvertTo-RecoveryTimestamp -Time $(if ($null -ne $at) { $at } else { $stamp })
        foreach ($key in $script:RecordKeyOrder) {
            if ($key -ceq 'v' -or $key -ceq 'at' -or -not $Record.Contains($key)) { continue }
            $line[$key] = Protect-RecoveryLedgerValue -Value $Record[$key]
        }
        foreach ($key in $Record.Keys) {
            if (-not $line.Contains([string]$key)) { $line[[string]$key] = Protect-RecoveryLedgerValue -Value $Record[$key] }
        }
        if ($line.Contains('evidence') -and $line['evidence'] -is [object[]] -and $line['evidence'].Count -gt $script:LineEvidenceMax) {
            $line['evidence'] = [object[]]@($line['evidence'] | Select-Object -First $script:LineEvidenceMax)
        }
        $json = $line | ConvertTo-Json -Compress -Depth 6
    } catch {
        Write-Verbose "Add-RecoveryLedgerRecord: the record could not be prepared: $($_.Exception.Message)"
        return $false
    }

    $path = Get-RecoveryLedgerPath -RuntimeDir $RuntimeDir
    for ($try = 0; $try -le $script:IoRetries; $try++) {
        if ($try -gt 0) { Start-Sleep -Milliseconds $script:IoRetryDelayMs }
        $guard = Lock-RecoveryLedger -RuntimeDir $RuntimeDir
        if ($null -eq $guard) {
            Write-Verbose 'Add-RecoveryLedgerRecord: not written, the writer guard could not be taken.'
            return $false
        }
        try {
            $prefix = if (Test-RecoveryLedgerTornTail -Path $path) { "`n" } else { '' }
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($prefix + $json + "`n")
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
            break
        } catch [System.IO.DirectoryNotFoundException] {
            Write-Verbose "Add-RecoveryLedgerRecord: the runtime directory is missing: $($_.Exception.Message)"
            return $false
        } catch [System.IO.IOException] {
            Write-Verbose "Add-RecoveryLedgerRecord: write attempt $($try + 1) failed: $($_.Exception.Message)"
            if ($try -ge $script:IoRetries) { return $false }
        } catch {
            Write-Verbose "Add-RecoveryLedgerRecord: the ledger cannot be written: $($_.Exception.Message)"
            return $false
        } finally {
            $guard.Dispose()
        }
    }

    try {
        if (([IO.FileInfo]::new($path)).Length -gt $script:LedgerCompactBytes) {
            $null = Compress-RecoveryLedger -RuntimeDir $RuntimeDir -Now $stamp
        }
    } catch {
        Write-Verbose "Add-RecoveryLedgerRecord: compaction failed: $($_.Exception.Message)"
    }
    return $true
}

function Test-RecoveryLedgerTornTail {
    <#
    .SYNOPSIS
        Whether the file exists, is not empty, and does not end in a newline.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -eq 0) { return $false }
        $null = $stream.Seek(-1, [IO.SeekOrigin]::End)
        return ($stream.ReadByte() -ne 10)
    } finally { $stream.Dispose() }
}

function Compress-RecoveryLedger {
    <#
    .SYNOPSIS
        Rewrites an oversized ledger without what no decision can need any more;
        $true only when it replaced the file.
    .DESCRIPTION
        Keeps the lines of the last seven days, every attempt that never reached a
        terminal line (the next invocation still has to close it), and the latest
        'resolved' line of each scope. The replacement is the atomic temp-file and
        rename of Write-YurunaStateFile. The writer guard is held from the read to
        the rename, so a line appended meanwhile by another process is not lost;
        if the guard cannot be had the file is left as it is.
    .PARAMETER ThresholdBytes
        The file is left alone at or below this size.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [datetime]$Now,
        [ValidateRange(0, 1073741824)][int]$ThresholdBytes = $script:LedgerCompactBytes
    )
    $path = Get-RecoveryLedgerPath -RuntimeDir $RuntimeDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try { $size = ([IO.FileInfo]::new($path)).Length } catch { return $false }
    if ($size -le $ThresholdBytes) { return $false }
    $nowUtc = if ($PSBoundParameters.ContainsKey('Now')) { $Now.ToUniversalTime() } else { [datetime]::UtcNow }
    $cutoff = $nowUtc.AddDays(-$script:LedgerKeepDays)
    $guard = Lock-RecoveryLedger -RuntimeDir $RuntimeDir
    if ($null -eq $guard) {
        Write-Verbose 'Compress-RecoveryLedger: left alone, the writer guard could not be taken.'
        return $false
    }
    try {
        $read = Read-RecoveryLedgerEntry -RuntimeDir $RuntimeDir
        if (-not $read.Readable) { return $false }

        $terminal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $read.Entries) {
            if ($entry.Kind -ceq 'attempt' -and $entry.Phase -cne 'started') { $null = $terminal.Add($entry.AttemptId) }
        }
        $latestResolved = @{}
        foreach ($entry in $read.Entries) {
            if ($entry.Kind -cne 'resolved') { continue }
            $key = Get-RecoveryResolvedKey -Scope $entry.Scope -Fingerprint $entry.Fingerprint
            if (-not $latestResolved.ContainsKey($key) -or $entry.At -ge $latestResolved[$key].At) { $latestResolved[$key] = $entry }
        }

        $kept = [Collections.Generic.List[string]]::new()
        foreach ($entry in $read.Entries) {
            $retain = ($entry.At -ge $cutoff)
            if (-not $retain -and $entry.Kind -ceq 'attempt' -and $entry.Phase -ceq 'started' -and -not $terminal.Contains($entry.AttemptId)) { $retain = $true }
            if (-not $retain -and $entry.Kind -ceq 'resolved' -and
                $latestResolved[(Get-RecoveryResolvedKey -Scope $entry.Scope -Fingerprint $entry.Fingerprint)].Index -eq $entry.Index) { $retain = $true }
            if ($retain) { $kept.Add($entry.Line) }
        }
        if ($kept.Count -eq @($read.Entries).Count -and $read.Skipped -eq 0) { return $false }
        $content = if ($kept.Count -gt 0) { ($kept -join "`n") + "`n" } else { '' }
        return [bool](Write-YurunaStateFile -Path $path -Content $content -Confirm:$false)
    } finally {
        $guard.Dispose()
    }
}

function Get-RecoveryResolvedKey {
    <#
    .SYNOPSIS
        The scope a 'resolved' line belongs to: 'all', or one per fingerprint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Scope,
        [AllowEmptyString()][string]$Fingerprint
    )
    if ($Scope -ceq 'fingerprint') { return 'fingerprint:' + $Fingerprint }
    return $Scope
}

function Complete-RecoveryFingerprint {
    <#
    .SYNOPSIS
        Records that the failure is over: a pass re-arms every repair budget.
    .DESCRIPTION
        Appends a 'resolved' line. Without a fingerprint the scope is 'all', which
        is what a passing cycle writes; with one, only that fingerprint's budgets
        restart.
    .OUTPUTS
        [bool] $true when the line is on disk.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$Fingerprint = '',
        [string]$Generation = '',
        [datetime]$Now
    )
    $record = [ordered]@{
        kind        = 'resolved'
        scope       = $(if ($Fingerprint) { 'fingerprint' } else { 'all' })
        fingerprint = $Fingerprint
        generation  = $Generation
    }
    if ($PSBoundParameters.ContainsKey('Now')) { return (Add-RecoveryLedgerRecord -RuntimeDir $RuntimeDir -Record $record -Now $Now) }
    return (Add-RecoveryLedgerRecord -RuntimeDir $RuntimeDir -Record $record)
}

# --- REGION: Attempt accounting
function Get-RecoveryAttemptSummary {
    <#
    .SYNOPSIS
        The full accounting for one fingerprint and action, including the record of
        the newest unfinished attempt.
    .DESCRIPTION
        Used counts the 'started' lines newer than both the latest 'resolved' line
        that covers the fingerprint (scope 'all', or the fingerprint itself) and
        the attempt window. Two lines stamped in the same second are ordered by
        their position in the file. A ledger that cannot be read reports an
        exhausted budget.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][int]$MaxAttempts,
        [Parameter(Mandatory)][datetime]$Now
    )
    $summary = @{
        Used = 0; MaxAttempts = $MaxAttempts; Exhausted = $false
        UnfinishedAttemptId = ''; UnfinishedAgeMinutes = [double]0; LastAttemptAtUtc = ''
        LedgerReadable = $true; UnfinishedRecord = $null
    }
    $read = Read-RecoveryLedgerEntry -RuntimeDir $RuntimeDir
    if (-not $read.Readable) {
        $summary.Exhausted = $true
        $summary.LedgerReadable = $false
        return $summary
    }
    $nowUtc = $Now.ToUniversalTime()
    $windowStart = $nowUtc.AddHours(-$script:AttemptWindowHours)

    $terminal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resolved = $null
    foreach ($entry in $read.Entries) {
        if ($entry.Kind -ceq 'attempt') {
            if ($entry.Phase -cne 'started') { $null = $terminal.Add($entry.AttemptId) }
        } elseif ($entry.Kind -ceq 'resolved') {
            $covers = ($entry.Scope -ceq 'all') -or ($entry.Scope -ceq 'fingerprint' -and $entry.Fingerprint -ceq $Fingerprint)
            if ($covers -and ($null -eq $resolved -or $entry.At -gt $resolved.At -or ($entry.At -eq $resolved.At -and $entry.Index -gt $resolved.Index))) { $resolved = $entry }
        }
    }

    $counted = 0
    $last = $null
    $unfinished = $null
    foreach ($entry in $read.Entries) {
        if ($entry.Kind -cne 'attempt' -or $entry.Phase -cne 'started') { continue }
        if ($entry.Action -ine $Action -or $entry.Fingerprint -cne $Fingerprint) { continue }
        if (-not $terminal.Contains($entry.AttemptId) -and
            ($null -eq $unfinished -or $entry.At -gt $unfinished.At -or ($entry.At -eq $unfinished.At -and $entry.Index -gt $unfinished.Index))) { $unfinished = $entry }
        $afterResolved = ($null -eq $resolved) -or ($entry.At -gt $resolved.At) -or ($entry.At -eq $resolved.At -and $entry.Index -gt $resolved.Index)
        if ($entry.At -gt $windowStart -and $afterResolved) {
            $counted++
            if ($null -eq $last -or $entry.At -ge $last.At) { $last = $entry }
        }
    }
    $summary.Used = $counted
    $summary.Exhausted = ($counted -ge $MaxAttempts)
    if ($null -ne $last) { $summary.LastAttemptAtUtc = ConvertTo-RecoveryTimestamp -Time $last.At }
    if ($null -ne $unfinished) {
        $summary.UnfinishedAttemptId = $unfinished.AttemptId
        $summary.UnfinishedAgeMinutes = [math]::Max([double]0, ($nowUtc - $unfinished.At).TotalMinutes)
        $summary.UnfinishedRecord = $unfinished.Record
    }
    return $summary
}

function Get-RecoveryAttemptState {
    <#
    .SYNOPSIS
        How many attempts a repair has used for a failure, and whether another
        process may still be running one. Read-only.
    .DESCRIPTION
        Used is the number of 'started' lines for the fingerprint and action newer
        than the latest 'resolved' line that covers the fingerprint and newer than
        24 hours. Exhausted is Used at or above MaxAttempts, and is also $true when
        the ledger exists but cannot be read, so an unknown history never grants
        attempts. UnfinishedAttemptId and UnfinishedAgeMinutes describe the newest
        'started' line that has no later line for its attempt; this function only
        reports it, and the invoke path is what records it as abandoned.
        LastAttemptAtUtc is the time of the newest attempt that Used counts.
    .OUTPUTS
        Ordered hashtable: Used, MaxAttempts, Exhausted, UnfinishedAttemptId,
        UnfinishedAgeMinutes, LastAttemptAtUtc, LedgerReadable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint,
        [Parameter(Mandatory)][string]$Action,
        [ValidateRange(0, 1000)][int]$MaxAttempts = 2,
        [datetime]$Now
    )
    $stamp = if ($PSBoundParameters.ContainsKey('Now')) { $Now } else { [datetime]::UtcNow }
    $summary = Get-RecoveryAttemptSummary -RuntimeDir $RuntimeDir -Fingerprint $Fingerprint -Action $Action -MaxAttempts $MaxAttempts -Now $stamp
    return [ordered]@{
        Used                 = [int]$summary.Used
        MaxAttempts          = [int]$summary.MaxAttempts
        Exhausted            = [bool]$summary.Exhausted
        UnfinishedAttemptId  = [string]$summary.UnfinishedAttemptId
        UnfinishedAgeMinutes = [double]$summary.UnfinishedAgeMinutes
        LastAttemptAtUtc     = [string]$summary.LastAttemptAtUtc
        LedgerReadable       = [bool]$summary.LedgerReadable
    }
}

# --- REGION: The registry of repairs
function Register-RecoveryAction {
    <#
    .SYNOPSIS
        Adds a repair to the registry, or replaces the one of the same name.
    .DESCRIPTION
        The registry is anchored in the session, so re-importing this module keeps
        the registrations; registering a name again replaces the entry and keeps
        its place in the planning order.

        Applies receives the typed result and answers a boolean. The other four
        scriptblocks receive the context as their first argument and return a
        hashtable with Ok, Reason (a short kebab-case token) and Evidence (items
        from New-RecoveryEvidence). Only a boolean $true in Ok counts as success.
        The rollback also receives the action's own result as its second argument.
    .PARAMETER Name
        Lowercase snake_case; it is the key of the budget in the ledger.
    .PARAMETER Applies
        param($Result): $true when the repair is relevant to the typed result. An
        exception counts as $false, and so does anything but a boolean $true.
    .PARAMETER Precondition
        Decides whether the repair may run now. Must not change anything.
    .PARAMETER Postcondition
        Proves the action worked. Runs after the action and is retried.
    .PARAMETER Rollback
        Undoes a partial action when the action or its postcondition failed.
    .PARAMETER MaxAttempts
        A cap for this repair that can only lower the caller's budget; 0 leaves
        the caller's budget as it is.
    .PARAMETER PostconditionRetries
        How many more times a failing postcondition is evaluated.
    .PARAMETER PostconditionDelaySeconds
        The wait between two evaluations of the postcondition.
    .PARAMETER SkipsFailurePause
        Whether the caller may skip its failure pause after this repair applied.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registry mutation in session memory; nothing outside the process changes.')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]*(_[a-z0-9]+)*$', Options = [System.Text.RegularExpressions.RegexOptions]::None)][string]$Name,
        [string]$Description = '',
        [Parameter(Mandatory)][scriptblock]$Applies,
        [Parameter(Mandatory)][scriptblock]$Precondition,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Postcondition,
        [scriptblock]$Rollback,
        [ValidateRange(0, 1000)][int]$MaxAttempts = 0,
        [ValidateRange(0, 20)][int]$PostconditionRetries = 0,
        [ValidateRange(0, 300)][int]$PostconditionDelaySeconds = 0,
        [bool]$SkipsFailurePause = $false
    )
    $entry = [ordered]@{
        Name                      = $Name
        Description               = $Description
        Applies                   = $Applies
        Precondition              = $Precondition
        Action                    = $Action
        Postcondition             = $Postcondition
        Rollback                  = $Rollback
        MaxAttempts               = $MaxAttempts
        PostconditionRetries      = $PostconditionRetries
        PostconditionDelaySeconds = $PostconditionDelaySeconds
        SkipsFailurePause         = $SkipsFailurePause
    }
    & $script:RecoveryActionRegistry.Register $Name $entry
}

function Get-RecoveryAction {
    <#
    .SYNOPSIS
        The registered repair of that name, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$Name)
    return (& $script:RecoveryActionRegistry.Get $Name)
}

function Get-RegisteredRecoveryAction {
    <#
    .SYNOPSIS
        The names of every registered repair, in registration order.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @($script:RecoveryActionRegistry.Store[0].Keys)
}

function Clear-RecoveryAction {
    <#
    .SYNOPSIS
        Removes one registered repair, or all of them. Tests only.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registry mutation in session memory; nothing outside the process changes.')]
    param([string]$Name)
    if ($Name) {
        $store = $script:RecoveryActionRegistry.Store[0]
        if ($store.Contains($Name)) { $store.Remove($Name) }
        return
    }
    & $script:RecoveryActionRegistry.Clear
}

function Get-RecoveryPlan {
    <#
    .SYNOPSIS
        The registered repairs relevant to a typed result, in registration order.
    .DESCRIPTION
        A repair is relevant when its Applies block returns exactly $true. A block
        that throws, or answers with anything else, is not relevant: planning must
        never be the thing that fails a cycle, and a truthy string is not consent.
    .PARAMETER ExcludeAction
        Names to leave out; names that are not registered are ignored.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [string[]]$ExcludeAction = @()
    )
    $excluded = @($ExcludeAction | Where-Object { $_ })
    $names = [Collections.Generic.List[string]]::new()
    foreach ($name in @($script:RecoveryActionRegistry.Store[0].Keys)) {
        if ($name -in $excluded) { continue }
        $entry = Get-RecoveryAction -Name $name
        if ($null -eq $entry) { continue }
        $verdict = $false
        try {
            $answer = @(& $entry['Applies'] $Result)
            $verdict = ($answer.Count -gt 0) -and ($answer[-1] -is [bool]) -and $answer[-1]
        } catch {
            Write-Verbose "Get-RecoveryPlan: Applies for '$name' threw: $($_.Exception.Message)"
        }
        if ($verdict) { $names.Add([string]$entry['Name']) }
    }
    return @($names)
}

# --- REGION: Running a repair
function New-RecoveryOutcome {
    <#
    .SYNOPSIS
        The shape Invoke-RecoveryAction and Invoke-RecoveryForResult return.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure constructor; it changes no state.')]
    param(
        [AllowEmptyString()][string]$Action = '',
        [Parameter(Mandatory)][string]$Decision,
        [Parameter(Mandatory)][string]$RecoveryState,
        [int]$Attempt = 0,
        [AllowEmptyString()][string]$AttemptId = '',
        [AllowEmptyString()][string]$Reason = '',
        [object[]]$Evidence = @(),
        [bool]$SkipFailurePause = $false
    )
    return [ordered]@{
        Action           = $Action
        Decision         = $Decision
        RecoveryState    = $RecoveryState
        Attempt          = $Attempt
        AttemptId        = $AttemptId
        Reason           = $Reason
        Evidence         = @($Evidence)
        SkipFailurePause = $SkipFailurePause
    }
}

function Invoke-RecoveryStep {
    <#
    .SYNOPSIS
        Runs one registered scriptblock and reduces whatever it did to
        Ok, Reason, Evidence and the raw result.
    .DESCRIPTION
        An exception becomes a failed step whose reason starts with the step name
        and 'threw'; a block that returns nothing usable is 'no-result'. Only a
        boolean $true in Ok counts as success. Nothing escapes this function.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Block,
        [Parameter(Mandatory)][object[]]$ArgumentList
    )
    try {
        $output = @(& $Block @ArgumentList)
        $candidate = $null
        foreach ($item in $output) {
            if ($item -is [System.Collections.IDictionary]) {
                if ($item.Contains('Ok')) { $candidate = $item }
            } elseif ($null -ne $item -and $null -ne $item.PSObject.Properties['Ok']) {
                $candidate = $item
            }
        }
        if ($null -eq $candidate) {
            return [ordered]@{ Ok = $false; Reason = 'no-result'; Evidence = @(); Raw = @{ Ok = $false; Reason = 'no-result' } }
        }
        $read = { param($Name) if ($candidate -is [System.Collections.IDictionary]) { $candidate[$Name] } else { $candidate.$Name } }
        $ok = & $read 'Ok'
        return [ordered]@{
            Ok       = (($ok -is [bool]) -and $ok)
            Reason   = (ConvertTo-RecoverySafeText -Text (& $read 'Reason'))
            Evidence = @(@(& $read 'Evidence') | Where-Object { $_ -is [System.Collections.IDictionary] })
            Raw      = $candidate
        }
    } catch {
        $reason = ConvertTo-RecoverySafeText -Text "$Step-threw: $($_.Exception.Message)"
        return [ordered]@{ Ok = $false; Reason = $reason; Evidence = @(); Raw = @{ Ok = $false; Reason = $reason } }
    }
}

function Get-RecoveryEventDecision {
    <#
    .SYNOPSIS
        The decision a ledger phase stands for in the recovery_action event.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Phase)
    switch ($Phase) {
        'started'         { return 'pending' }
        'succeeded'       { return 'applied' }
        'declined'        { return 'declined' }
        'exhausted'       { return 'exhausted' }
        'abandoned'       { return 'abandoned' }
        default           { return 'failed' }
    }
}

function Send-RecoveryActionEvent {
    <#
    .SYNOPSIS
        Emits the recovery_action event for a ledger line, when an event writer is
        loaded. Never fails the caller.
    .DESCRIPTION
        failureClass is omitted when empty, and when it is one of the runner's own
        fault classes: the event schema checks the field against the shared failure
        taxonomy, and neither is a member of it. The ledger line keeps the class
        either way.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Append-only telemetry pass-through; no destructive operation.')]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Line)
    try {
        if (-not (Get-Command -Name Send-CycleEventSafely -ErrorAction SilentlyContinue)) { return }
        $eventRecord = [ordered]@{
            timestamp   = [string]$Line['at']
            event       = 'recovery_action'
            action      = [string]$Line['action']
            decision    = (Get-RecoveryEventDecision -Phase ([string]$Line['phase']))
            phase       = [string]$Line['phase']
            fingerprint = [string]$Line['fingerprint']
            attempt     = [int]$Line['attempt']
            attemptId   = [string]$Line['attemptId']
            generation  = [string]$Line['generation']
            reason      = [string]$Line['reason']
        }
        $failureClass = [string]$Line['failureClass']
        if ($failureClass -and $failureClass -cnotin @(Get-RunnerFaultClassEnum)) { $eventRecord['failureClass'] = $failureClass }
        Send-CycleEventSafely -EventRecord ([hashtable]$eventRecord)
    } catch {
        Write-Verbose "Send-RecoveryActionEvent: the event was not delivered: $($_.Exception.Message)"
    }
}

function Write-RecoveryAttemptLine {
    <#
    .SYNOPSIS
        Appends one attempt line built from a template and emits its event;
        $true when the line is on disk.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Template,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][datetime]$At,
        [AllowEmptyString()][string]$Reason = '',
        [object[]]$Evidence = @()
    )
    $line = [ordered]@{
        kind         = 'attempt'
        phase        = $Phase
        attemptId    = [string]$Template['AttemptId']
        fingerprint  = [string]$Template['Fingerprint']
        failureClass = [string]$Template['FailureClass']
        action       = [string]$Template['Action']
        attempt      = [int]$Template['Attempt']
        generation   = [string]$Template['Generation']
        reason       = $Reason
        evidence     = @($Evidence)
    }
    if (-not (Add-RecoveryLedgerRecord -RuntimeDir ([string]$Template['RuntimeDir']) -Record $line -Now $At)) { return $false }
    $line['at'] = ConvertTo-RecoveryTimestamp -Time $At
    Send-RecoveryActionEvent -Line $line
    return $true
}

function Invoke-RecoveryAction {
    <#
    .SYNOPSIS
        Runs one registered repair under the ledger protocol and says what
        happened.
    .DESCRIPTION
        The order is fixed, and every step after the first is skipped by a refusal:

          1. close the books on attempts whose process died (an unfinished attempt
             older than ten minutes gets one 'abandoned' line);
          2. budget: a spent budget writes 'exhausted' and stops;
          3. an unfinished attempt younger than ten minutes may still be running
             in another process: 'declined' with reason attempt-in-progress;
          4. precondition: not ok writes 'declined' and stops;
          5. the 'started' line is written and flushed -- if that fails nothing
             runs (Decision ledger-unavailable);
          6. action, then the postcondition, retried as registered;
          7. ok writes 'succeeded'; anything else runs the rollback when one is
             registered ('rolled-back' or 'rollback-failed'), then writes 'failed'
             and 'escalated'.

        An exception in any block is a failed step with a reason, never an
        unhandled error. The context handed to the blocks is a copy of the
        caller's with Result, AttemptId, Attempt, Generation, Fingerprint and
        RuntimeDir set; Generation and Fingerprint come from the context when it
        carries them, otherwise from the typed result in Context.Result.
    .PARAMETER MaxAttempts
        The caller's budget; a repair registered with a lower cap uses that.
    .PARAMETER Now
        For tests. Without it every line is stamped with the time it is written.
    .OUTPUTS
        Ordered hashtable: Action, Decision (applied, declined, failed, exhausted,
        ledger-unavailable, unknown-action), RecoveryState, Attempt, AttemptId,
        Reason, Evidence, SkipFailurePause.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [ValidateRange(0, 1000)][int]$MaxAttempts = 2,
        [datetime]$Now
    )
    $entry = Get-RecoveryAction -Name $Name
    if ($null -eq $entry) {
        return (New-RecoveryOutcome -Action $Name -Decision 'unknown-action' -RecoveryState 'none' -Reason 'unknown-action')
    }
    $actionName = [string]$entry['Name']
    $budget = if ([int]$entry['MaxAttempts'] -gt 0) { [math]::Min($MaxAttempts, [int]$entry['MaxAttempts']) } else { $MaxAttempts }
    $fixedNow = if ($PSBoundParameters.ContainsKey('Now')) { $Now.ToUniversalTime() } else { $null }
    $clock = { if ($null -ne $fixedNow) { $fixedNow } else { [datetime]::UtcNow } }.GetNewClosure()

    $result = if ($Context.Contains('Result') -and $Context['Result'] -is [System.Collections.IDictionary]) { $Context['Result'] } else { $null }
    $generation = Get-RecoveryFieldText -Source $Context -Key 'Generation'
    if (-not $generation) { $generation = Get-RecoveryFieldText -Source $result -Key 'cycleGeneration' }
    $fingerprint = Get-RecoveryFieldText -Source $Context -Key 'Fingerprint'
    if (-not $fingerprint) { $fingerprint = Get-RecoveryFieldText -Source $result -Key 'fingerprint' }
    $failureClass = Get-RecoveryFieldText -Source $Context -Key 'FailureClass'
    if (-not $failureClass) { $failureClass = Get-RecoveryFieldText -Source $result -Key 'failureClass' }

    $attemptId = [guid]::NewGuid().ToString('N')
    $template = @{
        RuntimeDir = $RuntimeDir; AttemptId = $attemptId; Attempt = 0; Action = $actionName
        Fingerprint = $fingerprint; FailureClass = $failureClass; Generation = $generation
    }
    $refuse = {
        param([string]$Phase, [string]$Decision, [string]$State, [int]$Attempt, [string]$Reason, [object[]]$Evidence)
        $template['Attempt'] = $Attempt
        $null = Write-RecoveryAttemptLine -Template $template -Phase $Phase -At (& $clock) -Reason $Reason -Evidence $Evidence
        return (New-RecoveryOutcome -Action $actionName -Decision $Decision -RecoveryState $State -Attempt $Attempt -AttemptId $attemptId -Reason $Reason -Evidence $Evidence)
    }

    # An attempt whose process died stays "unfinished" forever unless somebody
    # records it. Doing that before the budget check means it is recorded exactly
    # once, even when the budget is already spent.
    $summary = $null
    for ($pass = 0; $pass -lt $script:MaxAbandonPasses; $pass++) {
        $summary = Get-RecoveryAttemptSummary -RuntimeDir $RuntimeDir -Fingerprint $fingerprint -Action $actionName -MaxAttempts $budget -Now (& $clock)
        if (-not $summary.LedgerReadable -or -not $summary.UnfinishedAttemptId -or $summary.UnfinishedAgeMinutes -le $script:AbandonAfterMinutes) { break }
        $stale = $summary.UnfinishedRecord
        $staleTemplate = @{
            RuntimeDir = $RuntimeDir; AttemptId = $summary.UnfinishedAttemptId; Action = $actionName
            Attempt = $(try { [int]$stale['attempt'] } catch { 0 })
            Fingerprint = $fingerprint; FailureClass = (Get-RecoveryFieldText -Source $stale -Key 'failureClass')
            Generation = (Get-RecoveryFieldText -Source $stale -Key 'generation')
        }
        if (-not (Write-RecoveryAttemptLine -Template $staleTemplate -Phase 'abandoned' -At (& $clock) -Reason 'abandoned-unfinished')) { break }
    }
    if (-not $summary.LedgerReadable) {
        return (New-RecoveryOutcome -Action $actionName -Decision 'ledger-unavailable' -RecoveryState 'declined' -AttemptId $attemptId -Reason 'ledger-unavailable')
    }
    $used = [int]$summary.Used
    if ($summary.Exhausted) {
        return (& $refuse 'exhausted' 'exhausted' 'exhausted' $used 'budget-exhausted' @())
    }
    if ($summary.UnfinishedAttemptId -and $summary.UnfinishedAgeMinutes -le $script:AbandonAfterMinutes) {
        return (& $refuse 'declined' 'declined' 'declined' $used 'attempt-in-progress' @())
    }

    $attemptNumber = $used + 1
    $template['Attempt'] = $attemptNumber
    $ctx = @{}
    foreach ($key in $Context.Keys) { $ctx[$key] = $Context[$key] }
    $ctx['AttemptId'] = $attemptId
    $ctx['Attempt'] = $attemptNumber
    $ctx['Generation'] = $generation
    $ctx['Fingerprint'] = $fingerprint
    $ctx['RuntimeDir'] = $RuntimeDir
    if ($null -ne $fixedNow) { $ctx['Now'] = $fixedNow }

    $pre = Invoke-RecoveryStep -Step 'precondition' -Block $entry['Precondition'] -ArgumentList @($ctx)
    if (-not $pre.Ok) {
        $reason = if ($pre.Reason) { $pre.Reason } else { 'precondition-declined' }
        return (& $refuse 'declined' 'declined' 'declined' $used $reason $pre.Evidence)
    }
    # The line that makes the attempt countable is on disk before anything is
    # changed: a crash from here on is an unfinished attempt, never an invisible one.
    if (-not (Write-RecoveryAttemptLine -Template $template -Phase 'started' -At (& $clock) -Reason $pre.Reason -Evidence $pre.Evidence)) {
        return (New-RecoveryOutcome -Action $actionName -Decision 'ledger-unavailable' -RecoveryState 'declined' -Attempt $used -AttemptId $attemptId -Reason 'ledger-unavailable' -Evidence $pre.Evidence)
    }

    $evidence = [Collections.Generic.List[object]]::new()
    $evidence.AddRange([object[]]@($pre.Evidence))
    $act = Invoke-RecoveryStep -Step 'action' -Block $entry['Action'] -ArgumentList @($ctx)
    $evidence.AddRange([object[]]@($act.Evidence))
    $failure = $null
    if (-not $act.Ok) {
        $failure = if ($act.Reason) { $act.Reason } else { 'action-failed' }
    } else {
        $post = $null
        $tries = 1 + [int]$entry['PostconditionRetries']
        for ($i = 0; $i -lt $tries; $i++) {
            if ($i -gt 0 -and [int]$entry['PostconditionDelaySeconds'] -gt 0) { Start-Sleep -Seconds ([int]$entry['PostconditionDelaySeconds']) }
            $post = Invoke-RecoveryStep -Step 'postcondition' -Block $entry['Postcondition'] -ArgumentList @($ctx)
            if ($post.Ok) { break }
        }
        $evidence.AddRange([object[]]@($post.Evidence))
        if (-not $post.Ok) { $failure = if ($post.Reason) { $post.Reason } else { 'postcondition-failed' } }
    }

    if ($null -eq $failure) {
        $reason = if ($post.Reason) { $post.Reason } else { 'ok' }
        $null = Write-RecoveryAttemptLine -Template $template -Phase 'succeeded' -At (& $clock) -Reason $reason -Evidence $evidence
        return (New-RecoveryOutcome -Action $actionName -Decision 'applied' -RecoveryState 'applied' -Attempt $attemptNumber -AttemptId $attemptId -Reason $reason -Evidence $evidence -SkipFailurePause ([bool]$entry['SkipsFailurePause']))
    }

    if ($entry['Rollback'] -is [scriptblock]) {
        $back = Invoke-RecoveryStep -Step 'rollback' -Block $entry['Rollback'] -ArgumentList @($ctx, $act.Raw)
        $evidence.AddRange([object[]]@($back.Evidence))
        $phase = if ($back.Ok) { 'rolled-back' } else { 'rollback-failed' }
        $backReason = if ($back.Reason) { $back.Reason } elseif ($back.Ok) { 'ok' } else { 'rollback-failed' }
        $null = Write-RecoveryAttemptLine -Template $template -Phase $phase -At (& $clock) -Reason $backReason -Evidence $back.Evidence
    }
    $null = Write-RecoveryAttemptLine -Template $template -Phase 'failed' -At (& $clock) -Reason $failure -Evidence $evidence
    $null = Write-RecoveryAttemptLine -Template $template -Phase 'escalated' -At (& $clock) -Reason $failure
    return (New-RecoveryOutcome -Action $actionName -Decision 'failed' -RecoveryState 'failed' -Attempt $attemptNumber -AttemptId $attemptId -Reason $failure -Evidence $evidence)
}

function Invoke-RecoveryForResult {
    <#
    .SYNOPSIS
        Plans the repairs that fit a typed result and, when automatic recovery is
        on, tries them in order until one applies.
    .DESCRIPTION
        With Enabled false nothing is written to the ledger, and nothing runs: the
        answer is RecoveryState 'advised' with the names of the repairs that would
        have been tried, or 'none' when no repair fits. With Enabled true the plan
        is tried in registration order and stops at the first repair that applied.
        When none applied, the answer is the decision of the most serious kind:
        exhausted and failed outrank declined, and among equals the later one wins.
    .PARAMETER ExcludeAction
        Repairs to leave out of the plan, for a caller that runs one of them later
        by name.
    .OUTPUTS
        Ordered hashtable with the fields of Invoke-RecoveryAction plus Advised
        (the names the plan holds) and Decisions (every individual result, in the
        order they ran).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][bool]$Enabled,
        [ValidateRange(0, 1000)][int]$MaxAttempts = 2,
        [string[]]$ExcludeAction = @(),
        [datetime]$Now
    )
    $plan = @(Get-RecoveryPlan -Result $Result -ExcludeAction $ExcludeAction)
    # The returned object is a copy: Decisions lists the individual results, and
    # the one that decided the outcome must not contain itself.
    $finish = {
        param($Outcome, [object[]]$Decisions)
        $final = [ordered]@{}
        foreach ($key in $Outcome.Keys) { $final[$key] = $Outcome[$key] }
        $final['Advised'] = [string[]]@($plan)
        $final['Decisions'] = @($Decisions)
        return $final
    }
    if (-not $Enabled) {
        $state = if ($plan.Count -gt 0) { 'advised' } else { 'none' }
        $reason = if ($plan.Count -gt 0) { 'automatic-recovery-off' } else { 'no-applicable-action' }
        return (& $finish (New-RecoveryOutcome -Decision $state -RecoveryState $state -Reason $reason) @())
    }
    if ($plan.Count -eq 0) {
        return (& $finish (New-RecoveryOutcome -Decision 'none' -RecoveryState 'none' -Reason 'no-applicable-action') @())
    }

    $decisions = [Collections.Generic.List[object]]::new()
    foreach ($name in $plan) {
        $ctx = @{}
        foreach ($key in $Context.Keys) { $ctx[$key] = $Context[$key] }
        $ctx['Result'] = $Result
        $invokeArgs = @{ Name = $name; Context = $ctx; RuntimeDir = $RuntimeDir; MaxAttempts = $MaxAttempts }
        if ($PSBoundParameters.ContainsKey('Now')) { $invokeArgs['Now'] = $Now }
        $outcome = Invoke-RecoveryAction @invokeArgs
        $decisions.Add($outcome)
        if ($outcome['Decision'] -ceq 'applied') { return (& $finish $outcome $decisions) }
    }
    $rank = @{ 'failed' = 2; 'exhausted' = 2; 'declined' = 1; 'ledger-unavailable' = 1 }
    $chosen = $null
    foreach ($outcome in $decisions) {
        $weight = if ($rank.ContainsKey([string]$outcome['Decision'])) { [int]$rank[[string]$outcome['Decision']] } else { 0 }
        if ($null -eq $chosen -or $weight -ge $chosen.Weight) { $chosen = [pscustomobject]@{ Weight = $weight; Outcome = $outcome } }
    }
    return (& $finish $chosen.Outcome $decisions)
}

Export-ModuleMember -Function Get-RecoveryLedgerPath, Add-RecoveryLedgerRecord, Read-RecoveryLedger, Get-RecoveryAttemptState, `
    Complete-RecoveryFingerprint, Compress-RecoveryLedger, Register-RecoveryAction, Get-RecoveryAction, `
    Get-RegisteredRecoveryAction, Clear-RecoveryAction, Get-RecoveryPlan, Invoke-RecoveryAction, Invoke-RecoveryForResult
