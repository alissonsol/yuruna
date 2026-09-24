<#PSScriptInfo
.VERSION 2026.09.24
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


# A held-open, never-unlinked, cross-process exclusive lock. The handle IS
# the mutex: a second Enter for the same path fails for as long as this
# handle stays open, in this process or any other, and process death
# releases it automatically through OS handle cleanup -- there is no PID
# file to go stale and no unlink to race a concurrent stale-drainer against.
#
# This is the same OpenOrCreate + FileShare.None shape the host-address
# beacon already relies on for hostaddress.beacon.lock, verified empirically
# on this runtime (Linux, PowerShell 7.6.5 / .NET 9): FileShare.None is
# backed by real OS-level advisory locking (flock), not merely tracked
# inside one process, so it holds across genuinely separate processes as a
# single-flight lock requires. It also blocks a read-only open from a
# second process while held, so a live holder's metadata cannot be
# inspected from outside; that is intentional, not a bug to work around --
# see Read-YurunaSingleFlightLockMetadata.
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

function Enter-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Acquire an exclusive, held-open, cross-process lock at Path.
    .DESCRIPTION
        Same-PID reentry is refused, not silently granted: FileShare.None
        blocks even a second FileStream open from the SAME process against
        that inode, so calling Enter twice for a path this process already
        holds returns Held=$false both times, never a silent no-op. A
        caller that legitimately needs to pass ownership within one
        authorized operation does so by threading the already-open lock
        object through, not by calling Enter again.
    .PARAMETER Path
        Full path to the lock file. Its parent directory must already exist
        and be secured by the caller (see Get-YurunaPrivateStateRoot in
        automation/Yuruna.Common.psm1); this function does not create or
        harden directories, only the lock file itself.
    .PARAMETER Metadata
        Written into the file once acquired, replacing any prior content: a
        hashtable the caller controls (a generation UUID, PID and numeric
        startTimeUnixMs are the fields section 4 requires; this function does
        not impose a shape). Advisory only, and unreadable by anyone else
        while held (verified: FileShare.None also blocks a read-only open
        from a second process on this runtime) -- never treat this content,
        even after later reading it back post-release, as authority to
        steal or bypass a lock. A metadata write failure does not release a
        lock this call otherwise legitimately holds.
    .OUTPUTS
        [pscustomobject] @{ Held; Handle; Reason; Path }. Held is $true only
        when the OS handle was actually acquired. The caller closes Handle
        (via Exit-YurunaSingleFlightLock, or directly) in a finally block --
        disposing it is what releases the lock. This function never deletes
        Path, on acquisition, on failure, or anywhere else.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Metadata
    )
    $handle = $null
    try {
        $handle = [System.IO.FileStream]::new(
            $Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        return [pscustomobject]@{ Held = $false; Handle = $null; Reason = 'held-elsewhere'; Path = $Path }
    } catch [System.UnauthorizedAccessException] {
        return [pscustomobject]@{ Held = $false; Handle = $null; Reason = 'access-denied'; Path = $Path }
    } catch {
        Write-Verbose "Enter-YurunaSingleFlightLock: unexpected failure opening '$Path': $($_.Exception.Message)"
        return [pscustomobject]@{ Held = $false; Handle = $null; Reason = 'error'; Path = $Path }
    }
    if ($Metadata) {
        try {
            $json  = $Metadata | ConvertTo-Json -Compress -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $handle.SetLength(0)
            $handle.Write($bytes, 0, $bytes.Length)
            $handle.Flush()
        } catch {
            # Diagnostics only: a write failure here must not be mistaken
            # for a failure to acquire a lock this call already holds.
            Write-Verbose "Enter-YurunaSingleFlightLock: metadata write failed for '$Path': $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Held = $true; Handle = $handle; Reason = 'acquired'; Path = $Path }
}

function Exit-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Release a lock acquired by Enter-YurunaSingleFlightLock.
    .DESCRIPTION
        Disposes the handle and nothing else. Never deletes or truncates
        the file: the lock is the open handle, not the path's existence or
        content, and unlinking here would let a concurrent stale-metadata
        clear (Clear-YurunaSingleFlightLock) or a fresh Enter from another
        process race a recreated inode under the same name during release.
        Safe to call with $null or an already-released lock.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Lock)
    if ($null -eq $Lock -or $null -eq $Lock.Handle) { return }
    try { $Lock.Handle.Dispose() } catch { $null = $_ }
}

function Read-YurunaSingleFlightLockMetadata {
    <#
    .SYNOPSIS
        Best-effort read of the metadata left by the last holder.
    .DESCRIPTION
        Only succeeds when nothing currently holds the lock: a live
        holder's FileShare.None blocks this read too, by design and as
        verified on this runtime, so "could not read" here is the expected,
        silent outcome while someone else holds the lock -- not an error
        condition to surface. Returns $null on any failure, including a
        missing file, an empty file, unparseable content, or a live holder.
    .OUTPUTS
        [hashtable] or $null
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is a mass noun, not a collection; there is no singular "metadatum" reading here.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Clear-YurunaSingleFlightLock {
    <#
    .SYNOPSIS
        Clean stale metadata left in a lock file. Never the live lock
        itself, and never on age or heartbeat alone.
    .DESCRIPTION
        There is no forced-drain rule here at all, on purpose: not the
        prior plan's 1800-second rule, which never shipped, and not the
        caching-proxy lock's own 21600-second abandoned-age ceiling. Age
        and heartbeat are both advisory-only signals that never evict a
        live holder on their own.

        The only thing this function trusts is that IT can acquire the
        lock: if Enter-YurunaSingleFlightLock succeeds here, nothing else
        currently holds Path, and clearing its content is safe. If Enter
        fails, this function changes nothing and returns $false -- a
        long-lived wedged worker still holding a live lock is an
        operator-visible failure to resolve out of band, not permission for
        this function to run a second operation alongside it.
    .OUTPUTS
        [bool] $true only when this call itself acquired the lock and
        cleared its content; $false when the lock was held by someone else
        (nothing was touched) or the clear itself failed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $lock = Enter-YurunaSingleFlightLock -Path $Path
    if (-not $lock.Held) { return $false }
    try {
        if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_2e0381db6ffe9be1'))) { return $false }
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

Export-ModuleMember -Function Enter-YurunaSingleFlightLock, Exit-YurunaSingleFlightLock, Read-YurunaSingleFlightLockMetadata, Clear-YurunaSingleFlightLock
