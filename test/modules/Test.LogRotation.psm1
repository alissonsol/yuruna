<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42ef9d8b-c7a6-4d34-9182-3d4e5f6a7bc8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna log rotation events vault
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
    Generic byte-bounded log rotation for `Add-Content`-style append
    paths (events.log, vault audit logs, any extension that wants
    a finite append history without rolling its own pump).

.DESCRIPTION
    Per-cycle log-folder rotation runs via `Start-LogFile` ->
    `Invoke-CycleLogRotation`, capping the test/status/log/ directory
    at CYCLE_HISTORY_LIMIT folders. That covers per-cycle artifacts
    but not the cycle-INDEPENDENT append-only files the framework
    keeps for audit + diagnostic purposes:

      * test/status/extension/authentication/events.log   (Write-VaultEvent)
      * any future extension that writes append-only state

    Without bounded rotation, those grow forever and eventually fill
    the disk on a long-running pool host. This module is the single
    primitive for byte-bounded N-file rotation:

        events.log         <- the live file
        events.log.1       <- last rotation
        events.log.2       <- previous
        ...
        events.log.10      <- oldest kept; .11 is dropped

    Constants (LOG_BYTE_LIMIT = 1 MB, LOG_FILE_KEEP = 10) are code-
    level by design, mirroring the FailurePauseMaxSeconds + Cycle-
    HistoryLimit policy: an operator greps + tunes without a config-
    schema migration.

    POLICY: rotation is idempotent and best-effort. The caller
    invokes Invoke-LogRotation right before Add-Content; the helper
    checks the size, shifts archives, returns. Failure cases (FS
    permission, locked file on Windows mid-write) log Verbose and
    return $false; the Add-Content that follows still appends to
    the live file, just past the rotation threshold by the size of
    that one append.

    Anti-flood guard: Test-LogRotationDue caches the last "checked
    at" timestamp on a per-path basis so a high-frequency writer
    (e.g. a tight Write-VaultEvent loop) doesn't run Get-Item on
    every emit. Default re-check window: 60 s.
#>

# Rotation constants. Both are code-level; see top-of-file rationale.
$script:LogByteLimit = 1MB
$script:LogFileKeep  = 10

# Last-checked timestamp cache: keyed on absolute path, value is the
# DateTime of the last Test-LogRotationDue call.
$script:LastChecked = @{}
$script:CheckIntervalSeconds = 60

function Test-LogRotationDue {
    <#
    .SYNOPSIS
        Predicate: is it time to re-check whether $Path needs rotating?
    .DESCRIPTION
        The actual rotation check is cheap (one Get-Item.Length) but
        a high-frequency writer (Write-VaultEvent in a tight loop)
        would still pay it on every event. This predicate caches the
        last check time per-path and returns $false until
        CheckIntervalSeconds has elapsed since the prior $true.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $abs = $Path
    try { $abs = [System.IO.Path]::GetFullPath($Path) } catch { $null = $_ }
    $now = Get-Date
    if ($script:LastChecked.ContainsKey($abs)) {
        $last = $script:LastChecked[$abs]
        if (($now - $last).TotalSeconds -lt $script:CheckIntervalSeconds) {
            return $false
        }
    }
    $script:LastChecked[$abs] = $now
    return $true
}

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Rotate $Path when its size exceeds MaxBytes. Returns $true
        when a rotation happened, $false otherwise (including
        no-file-yet / under-threshold / failed).
    .PARAMETER Path
        Absolute path of the live log file.
    .PARAMETER MaxBytes
        Threshold above which rotation fires. Default
        $script:LogByteLimit (1 MB).
    .PARAMETER MaxArchives
        Maximum number of .1 .. .N archives to retain. Default
        $script:LogFileKeep (10).
    .PARAMETER Force
        Bypass the per-path Test-LogRotationDue throttle. Tests use
        this; production callers should leave it off so the size
        check only runs at intervals.
    .OUTPUTS
        [bool] $true when a rotation happened.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$MaxBytes = $script:LogByteLimit,
        [int]$MaxArchives = $script:LogFileKeep,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not $Force -and -not (Test-LogRotationDue -Path $Path)) { return $false }
    $size = 0
    try { $size = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch {
        Write-Verbose "Invoke-LogRotation: size check failed for $Path : $($_.Exception.Message)"
        return $false
    }
    if ($size -lt $MaxBytes) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, "Rotate (size=$size threshold=$MaxBytes)")) { return $false }
    # Drop the eldest if it exists. Without this, the for-loop below
    # would silently overwrite a file at .N+1 that we'd otherwise want
    # to keep -- but since we cap at MaxArchives, .N+1 is the eldest
    # and gets evicted by policy.
    $eldest = "$Path.$MaxArchives"
    if (Test-Path -LiteralPath $eldest) {
        Remove-Item -LiteralPath $eldest -Force -ErrorAction SilentlyContinue
    }
    # Shift archives: .K -> .K+1 for K from MaxArchives-1 down to 1.
    for ($i = $MaxArchives - 1; $i -ge 1; $i--) {
        $old = "$Path.$i"
        $new = "$Path.$($i + 1)"
        if (Test-Path -LiteralPath $old) {
            try { Move-Item -LiteralPath $old -Destination $new -Force -ErrorAction Stop }
            catch { Write-Verbose "Invoke-LogRotation: shift $old -> $new failed: $($_.Exception.Message)" }
        }
    }
    # Final move: live file becomes .1
    try {
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop
    } catch {
        Write-Verbose "Invoke-LogRotation: rotate live file failed: $($_.Exception.Message)"
        return $false
    }
    return $true
}

function Reset-LogRotationCache {
    <#
    .SYNOPSIS
        Clear the per-path "last checked at" cache. Test fixtures call
        this between scenarios; production callers should not need it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.LogRotation cache', 'Clear')) {
        $script:LastChecked = @{}
    }
}

Export-ModuleMember -Function Invoke-LogRotation, Test-LogRotationDue, Reset-LogRotationCache
