<#PSScriptInfo
.VERSION 2026.09.27
.GUID 429455f3-1fcb-426b-b968-5462970a2ff5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-log
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

# The timestamped runtime/outer.log writer, in a module of its own so a
# process that must not load the outer loop -- the host-refresh worker, whose
# closure excludes Test.RunnerOuterLoop and its tree-kill helpers -- can
# still write the operator's log. Test.RunnerOuterLoop re-exports it, so every
# caller that resolves Write-OuterLog by name keeps working.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

function Write-OuterLog {
    <#
    .SYNOPSIS
        Append a timestamped line to runtime/outer.log. Survives a
        console-output wedge (observed on Windows: conhost can swallow
        every Write-Output for the entire failure-pause window).
    .DESCRIPTION
        outer.log is written concurrently by the outer loop, the watchdog
        thread job, the inner runner, and the status service, so a lone
        Add-Content can lose the race to another writer's exclusive open (a
        transient Windows sharing violation). The first write is attempted
        immediately -- the common uncontended case is unchanged; only on
        failure does it retry a few times with jittered backoff to ride out
        the contention window. If every attempt fails (a genuinely
        broken/read-only runtime dir, not mere contention) the failure is
        surfaced with a WARNING exactly once per session rather than
        swallowed to Verbose, so a silently vanishing outer.log becomes
        visible; the dedup keeps a persistently broken dir from warning on
        every cycle.

        The log is found through $env:YURUNA_RUNTIME_DIR at call time. When
        that variable is unset the line cannot be placed, so the first such
        call warns once and later ones go to Verbose; the call returns
        instead of throwing. Logging runs in finally blocks and failure
        paths, where an exception would mask the verdict being logged or
        skip the lock release that follows it.
    .PARAMETER Message
        The line to append, without a timestamp.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) {
        if (-not $script:OuterLogRuntimeDirWarned) {
            $script:OuterLogRuntimeDirWarned = $true
            try {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.outer_log_runtime_dir_unset' -Arguments @{ message = "$Message" })
            } catch {
                Write-Verbose "outer.log line dropped (YURUNA_RUNTIME_DIR unset): $Message"
            }
        } else {
            Write-Verbose "outer.log line dropped (YURUNA_RUNTIME_DIR unset): $Message"
        }
        return
    }
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK', [Globalization.CultureInfo]::InvariantCulture)
    # Path.Combine, not Join-Path: Join-Path resolves a drive-qualified path
    # through the provider, and a runtime directory naming a drive that does
    # not exist would raise an error here, outside every try, that a caller
    # running with ErrorActionPreference Stop receives as a throw. The bad
    # path instead fails the write below and takes the warn-once path.
    $logPath = [System.IO.Path]::Combine($runtimeDir, 'outer.log')
    $line = "$stamp $Message"
    $maxAttempts = 4
    $lastErr = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Add-Content -LiteralPath $logPath -Value $line -Encoding utf8 -ErrorAction Stop
            return
        } catch {
            $lastErr = $_
            if ($attempt -lt $maxAttempts) {
                # Jittered backoff so two writers that collided do not re-collide
                # in lockstep on the retry. Sub-second and bounded (worst case a
                # few hundred ms across the attempts) so a contended log never
                # meaningfully delays the loop.
                Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 80)
            }
        }
    }
    # Every attempt failed. Warn ONCE per session (not per cycle) so a broken
    # runtime dir surfaces without spamming the console; further failures still
    # drop to Verbose, which on its own would mask a vanishing outer.log.
    if (-not $script:OuterLogWriteWarned) {
        $script:OuterLogWriteWarned = $true
        try {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4ceb90c3873a42c7' -Arguments @{ logPath = "$logPath"; maxAttempts = "$maxAttempts"; message = "$($lastErr.Exception.Message)" })
        } catch {
            Write-Verbose "outer.log write failed (non-fatal): $($lastErr.Exception.Message)"
        }
    } else {
        Write-Verbose "outer.log write failed (non-fatal): $($lastErr.Exception.Message)"
    }
}

Export-ModuleMember -Function Write-OuterLog
