<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42f0a42c-b27f-4bec-ab95-98fd930ad13d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lock single-flight host-refresh
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

# A held-open, never-unlinked, cross-process exclusive lock. The handle IS
# the mutex: a second Enter for the same path fails for as long as this
# handle stays open, in this process or any other, and process death
# releases it automatically through OS handle cleanup -- there is no PID
# file to go stale and no unlink to race a concurrent stale-drainer against.
#
# This is the same OpenOrCreate + FileShare.None shape the host-address
# beacon already relies on for hostaddress.beacon.lock. .NET implements
# FileShare.None with flock(LOCK_EX) on Unix, and any other open of the file
# (even a read-only one) takes LOCK_SH, so it conflicts with the holder
# across genuinely separate processes as a single-flight lock requires. An
# environment switch (DOTNET_SYSTEM_IO_DISABLEFILELOCKING) turns that
# locking off silently, so every acquisition verifies exclusion itself
# before reporting the lock as held.
#
# It is NOT copied from the caching-proxy lock (Test.CachingProxyServiceLock
# .psm1): that lock closes its exclusive stream immediately after writing
# the PID, publishes identity in a separate sidecar file, and drains a
# suspected-stale holder by deleting files -- none of which is a lifetime OS
# lock, and its 21600-second forced-age drain would let a live worker's lock
# be stolen out from under it. This module holds one exclusive OS handle for
# the caller's entire operation and never age-drains at all: only a caller
# who can themselves acquire the lock (proving no one else holds it) may
# clear stale metadata, via Clear-YurunaSingleFlightLock.
#
# Ranks order nested acquisitions: the lifetime host-operation lock, then
# service-key locks in ordinal path order, then at most one short lock
# (admission, census merge, runner gate). A request that would wait for a
# longer-lived lock while holding a shorter one is refused without touching
# the disk, which is what keeps two processes from each holding the lock the
# other waits for.

$script:HeldSingleFlightLocks = [System.Collections.Generic.List[object]]::new()
$script:SingleFlightLockRank = [ordered]@{
    HostOperation = 100
    ServiceKey    = 200
    Admission     = 300
    CensusMerge   = 300
    Gate          = 300
}
# Locks at or above this rank are short locks: holding one forbids taking any
# other lock of the same rank, whatever its path.
$script:SingleFlightLockShortRank = 300
# ConvertFrom-Json turns ISO-8601-looking strings into [DateTime] unless told
# not to (-DateKind String, PowerShell 7.5 and later); metadata is handed back
# as the strings the holder wrote.
$script:SingleFlightJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:SingleFlightJsonOption.DateKind = 'String' }
# File systems whose lock exclusion this module's own multi-process suite has
# demonstrated on that platform. Qualifying another one is one entry here,
# after that suite passes on a host that uses it.
$script:SingleFlightLockQualifiedFileSystem = @{
    linux   = @('ext4', 'tmpfs')
    macos   = @('apfs')
    windows = @('NTFS')
}

function Get-YurunaSingleFlightPlatform {
    <#
    .SYNOPSIS
        linux, macos or windows for the current process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Get-YurunaSingleFlightComparison {
    <#
    .SYNOPSIS
        The path comparison of the platform's default file system.
    #>
    [CmdletBinding()]
    [OutputType([System.StringComparison])]
    param()
    if ((Get-YurunaSingleFlightPlatform) -eq 'linux') { return [StringComparison]::Ordinal }
    return [StringComparison]::OrdinalIgnoreCase
}

function Get-YurunaSingleFlightLockKey {
    <#
    .SYNOPSIS
        The canonical path that identifies a lock inside this process, so an
        alias spelling (a symlinked directory) maps to the same entry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $canonical = Resolve-YurunaCanonicalPath -Path $Path
    if ($canonical.Resolved) { return [string]$canonical.Path }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-YurunaSingleFlightFileIdentity {
    <#
    .SYNOPSIS
        "<device>:<inode>" of a Unix path, or $null when unavailable (always
        on Windows, where a held FileShare.None handle already prevents the
        file from being deleted or replaced).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return $null }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $stat = (Get-Item -Force -LiteralPath $Path -ErrorAction Stop).UnixStat
            if ($null -ne $stat) { return ('{0}:{1}' -f $stat.DeviceId, $stat.Inode) }
        } catch { $null = $_ }
        Start-Sleep -Milliseconds 20
    }
    return $null
}

function Get-YurunaSingleFlightProcessStart {
    <#
    .SYNOPSIS
        This process's start time in Unix milliseconds, read once.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    if ($null -eq $script:SingleFlightProcessStartUnixMs) {
        try {
            $start = (Get-Process -Id $PID -ErrorAction Stop).StartTime
            $script:SingleFlightProcessStartUnixMs = [DateTimeOffset]::new($start).ToUnixTimeMilliseconds()
        } catch {
            $script:SingleFlightProcessStartUnixMs = [long]0
        }
    }
    return [long]$script:SingleFlightProcessStartUnixMs
}

function Get-YurunaHeldSingleFlightLockEntry {
    <#
    .SYNOPSIS
        The locks this runspace currently holds, after dropping entries whose
        handle was closed without going through Exit-YurunaSingleFlightLock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    for ($i = $script:HeldSingleFlightLocks.Count - 1; $i -ge 0; $i--) {
        $handle = $script:HeldSingleFlightLocks[$i].Handle
        $open = $false
        try { $open = [bool]$handle.CanWrite } catch { $open = $false }
        if (-not $open) { $script:HeldSingleFlightLocks.RemoveAt($i) }
    }
    foreach ($entry in $script:HeldSingleFlightLocks) { $entry }
}

function ConvertTo-YurunaSingleFlightReason {
    <#
    .SYNOPSIS
        Map an I/O failure kind onto the lock's Reason vocabulary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'sharing-violation' { return 'held-elsewhere' }
        'access-denied'     { return 'access-denied' }
        'parent-missing'    { return 'parent-missing' }
        'not-found'         { return 'parent-missing' }
        'disk-full'         { return 'disk-full' }
        'read-only'         { return 'read-only' }
        default             { return 'io-error' }
    }
}

function Enter-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Acquire an exclusive, held-open, cross-process lock at Path, waiting
        a bounded time for a current holder to release it.
    .DESCRIPTION
        Only contention is waited on. A missing parent directory, denied
        access, a full or read-only disk, or any other I/O failure returns at
        once with its own Reason: retrying a permanent failure only turns it
        into a slow one.

        Same-process reentry is refused with Reason held-by-this-process,
        never silently granted. A caller that legitimately needs to pass
        ownership within one authorized operation threads the lock object
        through and validates it with Test-YurunaSingleFlightLockOwned.

        Any open of the lock file by an observer (a state probe, a metadata
        read) briefly conflicts with an acquirer, so a no-wait Enter can be
        refused by a mere observer. Contenders that must not be refused that
        way pass a wait. Recommended waits: the lifetime host-operation lock
        1500 ms; the admission lock 1000 ms in the listener and 5000 ms
        elsewhere; the census merge lock 1000 ms; service-key locks the time
        left on the operation's own deadline.

        After the open, the lock verifies its own exclusion by attempting a
        second, shared open of the same file: if that succeeds, OS file
        locking is disabled for this process and the lock is released and
        reported as locking-ineffective rather than held.
    .PARAMETER Path
        Full path to the lock file. Its parent directory must already exist
        and be secured by the caller (Get-YurunaPrivateStatePath); this
        function creates only the lock file itself, never directories.
    .PARAMETER Metadata
        Extra fields written into the file once acquired, replacing any
        prior content. The standard fields -- format, version, pid,
        startTimeUnixMs (this process's start), acquiredUnixMs, hostName and
        rank -- are recorded by this function and cannot be overridden;
        generation is the caller's value or a new GUID. Metadata is advisory:
        unreadable by anyone else while the lock is held, and never
        authority to steal or bypass a lock. A metadata write failure does
        not release a lock this call otherwise holds.
    .PARAMETER WaitMilliseconds
        How long to keep retrying while another holder has the lock. 0 makes
        one attempt.
    .PARAMETER PollMilliseconds
        Delay between attempts, with up to half again of random jitter so
        contenders do not retry in lockstep.
    .PARAMETER Deadline
        A shared deadline (New-YurunaDeadline). It can shorten the wait,
        never lengthen it.
    .PARAMETER Rank
        Position in the lock order (Get-YurunaLockRank). Omit for a lock
        outside the order.
    .OUTPUTS
        [pscustomobject] @{ Held; Handle; Reason; Path; WaitedMs; Attempts;
        Generation; Rank; FileIdentity; MetadataWritten; MetadataReason }.
        Held is $true only when the OS handle was actually acquired and its
        exclusion verified; the caller disposes Handle (through
        Exit-YurunaSingleFlightLock) in a finally block. Reason is one of
        acquired, held-elsewhere, held-by-this-process, lock-order-violation,
        reparse-point, parent-missing, access-denied, disk-full, read-only,
        locking-ineffective, locking-unverified or io-error. This function
        never deletes Path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [hashtable]$Metadata,
        [ValidateRange(0, 600000)][int]$WaitMilliseconds = 0,
        [ValidateRange(10, 1000)][int]$PollMilliseconds = 50,
        [ValidateNotNull()][psobject]$Deadline,
        [ValidateRange(1, 1000)][int]$Rank
    )
    $rankValue = if ($PSBoundParameters.ContainsKey('Rank')) { $Rank } else { $null }
    $record = [ordered]@{
        Held = $false; Handle = $null; Reason = $null; Path = $Path; WaitedMs = [long]0; Attempts = 0
        Generation = $null; Rank = $rankValue; FileIdentity = $null; MetadataWritten = $false; MetadataReason = $null
    }
    $comparison = Get-YurunaSingleFlightComparison
    $key = Get-YurunaSingleFlightLockKey -Path $Path
    $held = @(Get-YurunaHeldSingleFlightLockEntry)
    foreach ($entry in $held) {
        if ([string]::Equals([string]$entry.Key, $key, $comparison)) {
            $record.Reason = 'held-by-this-process'
            return [pscustomobject]$record
        }
    }
    if ($null -ne $rankValue) {
        foreach ($entry in $held) {
            if ($null -eq $entry.Rank) { continue }
            $violation = $false
            if ($entry.Rank -gt $rankValue) { $violation = $true }
            elseif ($entry.Rank -eq $rankValue) {
                if ($rankValue -ge $script:SingleFlightLockShortRank) { $violation = $true }
                elseif ([string]::Compare([string]$entry.Key, $key, $comparison) -ge 0) { $violation = $true }
            }
            if ($violation) {
                Write-Verbose "Enter-YurunaSingleFlightLock: '$Path' (rank $rankValue) refused while '$($entry.Path)' (rank $($entry.Rank)) is held."
                $record.Reason = 'lock-order-violation'
                return [pscustomobject]$record
            }
        }
    }
    if ([System.IO.FileInfo]::new($Path).LinkTarget) {
        $record.Reason = 'reparse-point'
        return [pscustomobject]$record
    }

    $waitLimit = [long]$WaitMilliseconds
    if ($PSBoundParameters.ContainsKey('Deadline')) {
        $waitLimit = [Math]::Min($waitLimit, [long](Get-YurunaDeadlineRemainingMs -Deadline $Deadline))
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $handle = $null
    while ($null -eq $handle) {
        $record.Attempts++
        try {
            $handle = [System.IO.FileStream]::new(
                $Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch {
            $kind = Get-YurunaIoFailureKind -Exception $_.Exception
            $record.WaitedMs = $stopwatch.ElapsedMilliseconds
            if ($kind -ne 'sharing-violation') {
                Write-Verbose "Enter-YurunaSingleFlightLock: opening '$Path' failed ($kind): $($_.Exception.Message)"
                $record.Reason = ConvertTo-YurunaSingleFlightReason -Kind $kind
                return [pscustomobject]$record
            }
            $left = $waitLimit - $record.WaitedMs
            if ($left -le 0) {
                $record.Reason = 'held-elsewhere'
                return [pscustomobject]$record
            }
            $jitter = Get-Random -Minimum 0 -Maximum ([int][Math]::Floor($PollMilliseconds / 2) + 1)
            Start-Sleep -Milliseconds ([int][Math]::Min([long]($PollMilliseconds + $jitter), $left))
        }
    }
    $record.WaitedMs = $stopwatch.ElapsedMilliseconds

    # Exclusion is proven, not assumed: a second open of the same file must
    # be refused while this handle is held.
    $selfCheck = 'unverified'
    $probe = $null
    try {
        $probe = [System.IO.FileStream]::new(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $selfCheck = 'ineffective'
    } catch {
        if ((Get-YurunaIoFailureKind -Exception $_.Exception) -eq 'sharing-violation') { $selfCheck = 'ok' }
    } finally {
        if ($null -ne $probe) { try { $probe.Dispose() } catch { $null = $_ } }
    }
    if ($selfCheck -ne 'ok') {
        try { $handle.Dispose() } catch { $null = $_ }
        $record.Reason = if ($selfCheck -eq 'ineffective') { 'locking-ineffective' } else { 'locking-unverified' }
        return [pscustomobject]$record
    }
    # A link swapped in between the pre-open check and the open would leave
    # this handle on the link's target, not on the lock path.
    if ([System.IO.FileInfo]::new($Path).LinkTarget) {
        try { $handle.Dispose() } catch { $null = $_ }
        $record.Reason = 'reparse-point'
        return [pscustomobject]$record
    }
    $record.FileIdentity = Get-YurunaSingleFlightFileIdentity -Path $Path

    $generation = $null
    if ($Metadata -and $Metadata.ContainsKey('generation') -and -not [string]::IsNullOrWhiteSpace([string]$Metadata['generation'])) {
        $generation = [string]$Metadata['generation']
    } else {
        $generation = [Guid]::NewGuid().ToString('N')
    }
    $record.Generation = $generation
    $standard = [ordered]@{
        format          = 'yuruna.lock-metadata'
        version         = 1
        pid             = $PID
        startTimeUnixMs = Get-YurunaSingleFlightProcessStart
        acquiredUnixMs  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        hostName        = [Environment]::MachineName
        rank            = $rankValue
        generation      = $generation
    }
    $document = [ordered]@{}
    if ($Metadata) {
        foreach ($name in @($Metadata.Keys)) {
            $isStandard = $false
            foreach ($standardName in $standard.Keys) {
                if ([string]::Equals([string]$name, [string]$standardName, [StringComparison]::OrdinalIgnoreCase)) { $isStandard = $true; break }
            }
            if (-not $isStandard) { $document["$name"] = $Metadata[$name] }
        }
    }
    foreach ($standardName in $standard.Keys) { $document[$standardName] = $standard[$standardName] }
    $bytes = $null
    try {
        $json = ConvertTo-Json -InputObject $document -Compress -Depth 6 -WarningAction SilentlyContinue
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    } catch {
        $record.MetadataReason = 'serialize-failed'
        Write-Verbose "Enter-YurunaSingleFlightLock: metadata for '$Path' could not be serialized: $($_.Exception.Message)"
    }
    if ($null -ne $bytes) {
        try {
            $handle.SetLength(0)
            $handle.Write($bytes, 0, $bytes.Length)
            $handle.Flush()
            $record.MetadataWritten = $true
            $record.MetadataReason = 'ok'
        } catch {
            # Diagnostics only: a write failure here must not be mistaken
            # for a failure to acquire a lock this call already holds.
            $kind = Get-YurunaIoFailureKind -Exception $_.Exception
            $record.MetadataReason = if ($kind -eq 'disk-full') { 'disk-full' } else { 'io-error' }
            Write-Verbose "Enter-YurunaSingleFlightLock: metadata write failed for '$Path': $($_.Exception.Message)"
        }
    }

    $script:HeldSingleFlightLocks.Add([pscustomobject]@{
            Key = $key; Path = $Path; Handle = $handle; Rank = $rankValue
            Generation = $generation; FileIdentity = $record.FileIdentity
        })
    $record.Held   = $true
    $record.Handle = $handle
    $record.Reason = 'acquired'
    return [pscustomobject]$record
}

function Exit-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Release a lock acquired by Enter-YurunaSingleFlightLock.
    .DESCRIPTION
        Disposes the handle and forgets it, nothing else. Never deletes or
        truncates the file: the lock is the open handle, not the path's
        existence or content, and unlinking here would let a concurrent
        stale-metadata clear (Clear-YurunaSingleFlightLock) or a fresh Enter
        from another process race a recreated inode under the same name
        during release. Safe to call with $null or an already-released lock.
    .PARAMETER Lock
        The object Enter-YurunaSingleFlightLock returned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Lock)
    if ($null -eq $Lock -or $null -eq $Lock.Handle) { return }
    $handle = $Lock.Handle
    try { $handle.Dispose() } catch { $null = $_ }
    for ($i = $script:HeldSingleFlightLocks.Count - 1; $i -ge 0; $i--) {
        if ([object]::ReferenceEquals($script:HeldSingleFlightLocks[$i].Handle, $handle)) {
            $script:HeldSingleFlightLocks.RemoveAt($i)
        }
    }
}

function Get-YurunaSingleFlightLockState {
    <#
    .SYNOPSIS
        Observe a lock without taking it: held, free, absent or unknown.
    .DESCRIPTION
        Opens the file for reading only, never creates it, and never writes.
        A holder's exclusive handle refuses the open, which is what "held"
        means; the last holder's metadata is read only when the lock is free,
        and is advisory, never authority. The probe itself briefly conflicts
        with an acquirer, so an acquirer that must not be refused by an
        observer uses a wait (see Enter-YurunaSingleFlightLock).
    .PARAMETER Path
        The lock file.
    .OUTPUTS
        [pscustomobject] @{ State held|free|absent|unknown; Reason;
        MetadataState ok|empty|malformed|unread; Metadata [hashtable] }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $record = [ordered]@{ State = 'unknown'; Reason = $null; MetadataState = 'unread'; Metadata = $null }
    if ([System.IO.FileInfo]::new($Path).LinkTarget) {
        $record.Reason = 'reparse-point'
        return [pscustomobject]$record
    }
    $comparison = Get-YurunaSingleFlightComparison
    $key = Get-YurunaSingleFlightLockKey -Path $Path
    foreach ($entry in @(Get-YurunaHeldSingleFlightLockEntry)) {
        if ([string]::Equals([string]$entry.Key, $key, $comparison)) {
            $record.State = 'held'
            $record.Reason = 'held-by-this-process'
            return [pscustomobject]$record
        }
    }
    if (-not [System.IO.File]::Exists($Path)) {
        if ([System.IO.Directory]::Exists($Path)) {
            $record.Reason = 'not-a-file'
        } else {
            $record.State = 'absent'
            $record.Reason = 'absent'
        }
        return [pscustomobject]$record
    }
    $stream = $null
    $text = $null
    try {
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $record.State = 'free'
        $record.Reason = 'free'
        if ($stream.Length -gt 65536) {
            $record.MetadataState = 'malformed'
        } else {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
            $text = $reader.ReadToEnd()
        }
    } catch {
        $kind = Get-YurunaIoFailureKind -Exception $_.Exception
        switch ($kind) {
            'sharing-violation' { $record.State = 'held'; $record.Reason = 'held-elsewhere' }
            'not-found'         { $record.State = 'absent'; $record.Reason = 'absent' }
            'parent-missing'    { $record.State = 'absent'; $record.Reason = 'absent' }
            default             { $record.State = 'unknown'; $record.Reason = $kind }
        }
    } finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { $null = $_ } }
    }
    if ($record.State -eq 'free' -and $record.MetadataState -eq 'unread') {
        if ([string]::IsNullOrWhiteSpace($text)) {
            $record.MetadataState = 'empty'
        } else {
            try {
                $jsonOption = $script:SingleFlightJsonOption
                $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop @jsonOption
                if ($parsed -is [System.Collections.IDictionary]) {
                    $record.Metadata = $parsed
                    $record.MetadataState = 'ok'
                } else {
                    $record.MetadataState = 'malformed'
                }
            } catch {
                $record.MetadataState = 'malformed'
            }
        }
    }
    return [pscustomobject]$record
}

function Read-YurunaSingleFlightLockMetadata {
    <#
    .SYNOPSIS
        Best-effort read of the metadata left by the last holder.
    .DESCRIPTION
        Only succeeds when nothing currently holds the lock: a live
        holder's FileShare.None blocks this read too, so "could not read"
        here is the expected, silent outcome while someone else holds the
        lock -- not an error condition to surface. Returns $null on any
        failure, including a missing file, an empty file, unparseable
        content, or a live holder. Get-YurunaSingleFlightLockState reports
        which of those it was.
    .PARAMETER Path
        The lock file.
    .OUTPUTS
        [hashtable] or $null
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is a mass noun, not a collection; there is no singular "metadatum" reading here.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $state = Get-YurunaSingleFlightLockState -Path $Path
    if ($state.State -eq 'free' -and $state.MetadataState -eq 'ok') { return $state.Metadata }
    return $null
}

function Clear-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Clean stale metadata left in a lock file. Never the live lock
        itself, and never on age or heartbeat alone.
    .DESCRIPTION
        There is no forced-drain rule here at all, on purpose: no age or
        heartbeat threshold of any length, including the caching-proxy
        lock's own 21600-second abandoned-age ceiling. Age and heartbeat are
        both advisory-only signals that never evict a live holder on their
        own.

        The only thing this function trusts is that IT can acquire the
        lock: if Enter-YurunaSingleFlightLock succeeds here, nothing else
        currently holds Path, and clearing its content is safe. If Enter
        fails, this function changes nothing and returns $false -- a
        long-lived wedged worker still holding a live lock is an
        operator-visible failure to resolve out of band, not permission for
        this function to run a second operation alongside it.
    .PARAMETER Path
        The lock file.
    .OUTPUTS
        [bool] $true only when this call itself acquired the lock and
        cleared its content; $false when the lock was held by someone else
        (nothing was touched), the clear itself failed, or -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_2e0381db6ffe9be1'))) { return $false }
    $lock = Enter-YurunaSingleFlightLock -Path $Path
    if (-not $lock.Held) { return $false }
    try {
        try {
            $lock.Handle.SetLength(0)
            $lock.Handle.Flush()
        } catch {
            Write-Verbose "Clear-YurunaSingleFlightLock: clear failed for '$Path': $($_.Exception.Message)"
            return $false
        }
        return $true
    } finally {
        Exit-YurunaSingleFlightLock -Lock $lock
    }
}

function Test-YurunaSingleFlightLockOwned {
    <#
    .SYNOPSIS
        $true when a lock object passed in is a live lock this runspace holds.
    .DESCRIPTION
        A nested helper inside one authorized operation receives the lock
        object instead of calling Enter again, and validates it here before
        acting on the authority it represents. The lock must report Held, its
        handle must still be open, and it must be the handle this runspace
        registered. With -Path, the lock must be the one for that path
        (aliases compare by canonical path). When the file identity was
        recorded at acquisition, the path must still name that same file: a
        lock whose file was replaced no longer excludes anyone.
    .PARAMETER Lock
        The object Enter-YurunaSingleFlightLock returned.
    .PARAMETER Path
        The lock file the caller expects this lock to be for.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Lock,
        [string]$Path
    )
    if ($null -eq $Lock -or -not [bool]$Lock.Held -or $null -eq $Lock.Handle) { return $false }
    $entry = $null
    foreach ($candidate in @(Get-YurunaHeldSingleFlightLockEntry)) {
        if ([object]::ReferenceEquals($candidate.Handle, $Lock.Handle)) { $entry = $candidate; break }
    }
    if ($null -eq $entry) { return $false }
    if ($PSBoundParameters.ContainsKey('Path')) {
        $key = Get-YurunaSingleFlightLockKey -Path $Path
        if (-not [string]::Equals([string]$entry.Key, $key, (Get-YurunaSingleFlightComparison))) { return $false }
    }
    if ($entry.FileIdentity) {
        if ([System.IO.FileInfo]::new($entry.Path).LinkTarget) { return $false }
        if (-not [System.IO.File]::Exists($entry.Path)) { return $false }
        $current = Get-YurunaSingleFlightFileIdentity -Path $entry.Path
        if ($current -ne $entry.FileIdentity) { return $false }
    }
    return $true
}

function Get-YurunaLockRank {
    <#
    .SYNOPSIS
        The rank of a named lock in the host-operation lock order.
    .DESCRIPTION
        HostOperation (the lifetime repair lock) 100, then ServiceKey 200
        (several may be held, taken in ordinal path order), then one short
        lock at 300: Admission, CensusMerge or Gate. Two short locks are
        never held together, and no process waits for a longer-lived lock
        while it holds a shorter one.
    .PARAMETER Name
        HostOperation, ServiceKey, Admission, CensusMerge or Gate.
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][ValidateSet('HostOperation', 'ServiceKey', 'Admission', 'CensusMerge', 'Gate')][string]$Name)
    return [int]$script:SingleFlightLockRank[$Name]
}

function Get-YurunaSingleFlightLockQualification {
    <#
    .SYNOPSIS
        Whether this lock's exclusion has been demonstrated for a platform
        and, with -Path, for the file system that holds the path.
    .DESCRIPTION
        Exclusion is a property of the OS and the file system, and it is
        only claimed where this module's multi-process suite has passed:
        ext4 and tmpfs on Linux, APFS on macOS, and NTFS on Windows.
        A network file system is never qualified. Without -Path the answer is the
        platform half alone, usable by a static capability declaration.
    .PARAMETER Path
        A lock path (or its directory); its mount is examined.
    .PARAMETER Platform
        linux, macos or windows; defaults to the current OS.
    .OUTPUTS
        [pscustomobject] @{ Platform; FileSystem; DriveType; PlatformQualified;
        Qualified; Reason qualified|platform-unqualified|filesystem-unqualified|
        network-filesystem|unknown-filesystem }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path,
        [ValidateSet('linux', 'macos', 'windows')][string]$Platform
    )
    if (-not $Platform) { $Platform = Get-YurunaSingleFlightPlatform }
    $declared = @($script:SingleFlightLockQualifiedFileSystem[$Platform])
    $record = [ordered]@{
        Platform = $Platform; FileSystem = $null; DriveType = $null
        PlatformQualified = ($declared.Count -gt 0); Qualified = $false; Reason = $null
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $record.Qualified = $record.PlatformQualified
        $record.Reason = if ($record.PlatformQualified) { 'qualified' } else { 'platform-unqualified' }
        return [pscustomobject]$record
    }
    $drive = Get-YurunaPathDriveInfo -Path $Path
    if ($drive.Resolved) {
        $record.FileSystem = $drive.FileSystem
        $record.DriveType  = $drive.DriveType
    }
    if (-not $record.PlatformQualified) {
        $record.Reason = 'platform-unqualified'
    } elseif ($drive.Resolved -and $drive.DriveType -eq 'Network') {
        $record.Reason = 'network-filesystem'
    } elseif (-not $drive.Resolved -or [string]::IsNullOrWhiteSpace([string]$drive.FileSystem)) {
        $record.Reason = 'unknown-filesystem'
    } elseif (@($declared | Where-Object { [string]::Equals([string]$_, [string]$drive.FileSystem, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        $record.Qualified = $true
        $record.Reason = 'qualified'
    } else {
        $record.Reason = 'filesystem-unqualified'
    }
    return [pscustomobject]$record
}

Export-ModuleMember -Function Enter-YurunaSingleFlightLock, Exit-YurunaSingleFlightLock, Read-YurunaSingleFlightLockMetadata, Clear-YurunaSingleFlightLock, Get-YurunaSingleFlightLockState, Test-YurunaSingleFlightLockOwned, Get-YurunaLockRank, Get-YurunaSingleFlightLockQualification
