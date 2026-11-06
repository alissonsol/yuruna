<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42cdd325-97d4-41ad-8d67-4e3593a0e961
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver lifecycle dialog watchdog
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

# --- REGION: VM lifecycle helpers
# UTM-internal helpers consumed by Yuruna.Host's contract entry points
# below. Not part of the test-facing host driver contract; test code
# calls the contract verbs (New-VM / Start-VM / ...) which delegate here.

# --- REGION: UTM dialog watchdog
# Background osascript that clicks accept buttons on UTM dialogs every ~2 s
# (custom-args import warning, intermittent QEMU "Invalid argument"). PID
# kept at $HOME/yuruna/image/utm-dialog-watchdog.pid.

$script:WatchdogPidFile      = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.pid"
$script:WatchdogScriptPath   = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.applescript"
$script:WatchdogLogPath      = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.log"
# Beside the plain pid file: the uid, start time and script of the process
# that was spawned, so a later stop can tell that process from an unrelated
# one that inherited its pid.
$script:WatchdogIdentityPath = Join-Path $HOME "yuruna/image/utm-dialog-watchdog.identity.json"
$script:WatchdogInterpreterPath = '/usr/bin/osascript'

<#
.SYNOPSIS
    Stop the background osascript watchdog that auto-clicks UTM dialogs,
    only after proving the recorded pid is still that watchdog.
.DESCRIPTION
    The pid file outlives the process it names, and pids are reused, so a
    bare kill of the recorded pid can hit anything. The recorded pid is
    signaled only when it exists, belongs to this user, runs the watchdog
    script, and -- when the identity record written at spawn is present --
    has the start time recorded there. A process that fails those checks is
    left alone with a warning. The records are removed once the watchdog is
    confirmed gone or the pid is shown to belong to something else; they
    are kept when the check itself could not complete, so a later stop can
    try again.
.PARAMETER Deadline
    Optional deadline (New-YurunaDeadline) bounding the identity reads and
    the signal.
#>
function Stop-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param($Deadline)
    $clearRecords = {
        Remove-Item -LiteralPath $script:WatchdogPidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:WatchdogIdentityPath -Force -ErrorAction SilentlyContinue
    }
    $hasPidFile = Test-Path -LiteralPath $script:WatchdogPidFile
    if (-not $hasPidFile -and -not (Test-Path -LiteralPath $script:WatchdogIdentityPath)) { return }
    # Even removing a stale identity record is a change -WhatIf must not make.
    $target = if ($hasPidFile) { $script:WatchdogPidFile } else { $script:WatchdogIdentityPath }
    if (-not $PSCmdlet.ShouldProcess($target, (Format-YurunaOperatorMessage -Key 'host.operator_9037cbd3068bafc8'))) { return }
    if (-not $hasPidFile) { & $clearRecords; return }
    $pidText = "$(Get-Content -LiteralPath $script:WatchdogPidFile -Raw -ErrorAction SilentlyContinue)".Trim()
    $watchdogPid = 0
    if (-not [int]::TryParse($pidText, [ref]$watchdogPid) -or $watchdogPid -le 0) { & $clearRecords; return }
    $recorded = $null
    if (Test-Path -LiteralPath $script:WatchdogIdentityPath) {
        try { $recorded = Get-Content -LiteralPath $script:WatchdogIdentityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $recorded = $null }
    }
    $unverified = {
        param([string]$Reason)
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_dialog_watchdog_unverified' -Arguments @{ processId = "$watchdogPid"; pidFile = "$script:WatchdogPidFile"; reason = "$Reason" })
    }
    $identity = Get-UtmProcessIdentity -ProcessId $watchdogPid -Deadline $Deadline
    if (-not $identity.Found) {
        if ($identity.Reason -eq 'not-found') { & $clearRecords; return }
        & $unverified $identity.Reason
        return
    }
    $uid = Get-UtmCurrentUid -Deadline $Deadline
    if (-not $uid) { & $unverified 'uid-unknown'; return }
    $mismatch = if ($identity.Uid -ne $uid) { 'owner-mismatch' }
                elseif (-not $identity.Command.Contains([string]$script:WatchdogScriptPath)) { 'command-mismatch' }
                elseif ($recorded -and ("$($recorded.pid)" -ne "$watchdogPid" -or "$($recorded.startText)" -ne $identity.StartText)) { 'start-time-mismatch' }
                else { '' }
    if ($mismatch) {
        # The recorded watchdog is gone and its pid now belongs to another
        # process: that process is left alone and the stale records dropped.
        & $unverified $mismatch
        & $clearRecords
        return
    }
    $null = Invoke-UtmHostTool -Tool 'kill' -ArgumentList @('-TERM', "$watchdogPid") -TimeoutSeconds 5 -Deadline $Deadline
    $exitWait = Get-UtmChildDeadline -Milliseconds 2000 -Parent $Deadline
    do {
        $after = Get-UtmProcessIdentity -ProcessId $watchdogPid -Deadline $Deadline
        if (-not $after.Found -and $after.Reason -eq 'not-found') { & $clearRecords; return }
    } while (Wait-UtmInterval -Milliseconds 100 -Deadline $exitWait)
    Write-Verbose "Stop-UtmDialogWatchdog: pid $watchdogPid was signaled but had not exited within 2 s; its records are kept for the next stop."
}

<#
.SYNOPSIS
    Spawn a background osascript watchdog that auto-clicks UTM dialogs.
.DESCRIPTION
    Detached on purpose -- the watchdog must outlive this call -- so it is
    launched with Start-Process, never through the tree-killing bounded
    runner. After the spawn its identity (pid, uid, start time, script) is
    written beside the pid file, so Stop-UtmDialogWatchdog can later prove
    the pid is still this watchdog before signaling it.

    A previous watchdog that the stop could not confirm gone keeps its
    records, and then no second one is started: overwriting the pid file
    would leave the first one -- an endless loop clicking UTM's affirmative
    buttons -- running with nothing left that could find and stop it.
#>
function Start-UtmDialogWatchdog {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_1e72e0f10e85d00c'), 'Start')) { return }
    Stop-UtmDialogWatchdog
    if (Test-Path -LiteralPath $script:WatchdogPidFile) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_dialog_watchdog_start_skipped' -Arguments @{ pidFile = "$script:WatchdogPidFile" })
        return
    }
    $stateDir = Split-Path -Parent $script:WatchdogPidFile
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Title-only clicks cannot identify a sheet's intent. Keep the affirmative
    # allowlist narrow and arm the watchdog only around the launch it unblocks.
    # See https://yuruna.link/42885ada-0011
    $asScript = @'
set acceptLabels to {"Continue", "OK", "Okay", "Run", "Open", "Allow"}
repeat
    try
        tell application "System Events"
            tell process "UTM"
                set candidates to {}
                try
                    repeat with w in (every window)
                        repeat with s in (every sheet of w)
                            set end of candidates to s
                        end repeat
                    end repeat
                end try
                try
                    repeat with d in (every window whose subrole is "AXDialog")
                        set end of candidates to d
                    end repeat
                end try
                repeat with c in candidates
                    try
                        repeat with b in (every button of c)
                            if (title of b) is in acceptLabels then
                                click b
                                exit repeat
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        end tell
    end try
    delay 2
end repeat
'@
    Set-Content -LiteralPath $script:WatchdogScriptPath -Value $asScript -NoNewline
    $proc = Start-Process -FilePath $script:WatchdogInterpreterPath `
        -ArgumentList @($script:WatchdogScriptPath) `
        -RedirectStandardOutput $script:WatchdogLogPath `
        -RedirectStandardError  "$($script:WatchdogLogPath).stderr" `
        -PassThru
    $proc.Id | Set-Content -LiteralPath $script:WatchdogPidFile
    Write-Debug "      UTM dialog watchdog started (pid $($proc.Id))"
    Write-UtmDialogWatchdogIdentity -ProcessId $proc.Id
}

<#
.SYNOPSIS
    Record the just-spawned watchdog's identity beside its pid file.
.DESCRIPTION
    Written only when the process could be read: a record with a guessed
    start time would make a later stop refuse the real watchdog. Without a
    record the stop falls back to the uid and script-path checks alone.
    Written to a temporary file and moved into place, without a BOM, so a
    reader never sees half a record.
#>
function Write-UtmDialogWatchdogIdentity {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([void])]
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not $PSCmdlet.ShouldProcess($script:WatchdogIdentityPath, (Format-YurunaOperatorMessage -Key 'host.utm_dialog_watchdog_identity_action'))) { return }
    $identity = $null
    $readWait = New-YurunaDeadline -TotalMilliseconds 2000
    do {
        $identity = Get-UtmProcessIdentity -ProcessId $ProcessId
        if ($identity.Found -or $identity.Reason -ne 'not-found') { break }
    } while (Wait-UtmInterval -Milliseconds 100 -Deadline $readWait)
    # A record left by an earlier watchdog would describe the wrong process.
    Remove-Item -LiteralPath $script:WatchdogIdentityPath -Force -ErrorAction SilentlyContinue
    if (-not $identity -or -not $identity.Found) {
        Write-Verbose "Start-UtmDialogWatchdog: pid $ProcessId could not be read back ($($identity.Reason)); no identity record written."
        return
    }
    $record = [ordered]@{
        schemaVersion = 1
        pid           = $ProcessId
        uid           = $identity.Uid
        startText     = $identity.StartText
        scriptPath    = [string]$script:WatchdogScriptPath
        ownerPid      = $PID
        createdUtc    = [DateTime]::UtcNow.ToString('o')
    }
    $temp = "$($script:WatchdogIdentityPath).$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($temp, ($record | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $script:WatchdogIdentityPath -Force
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Verbose "Start-UtmDialogWatchdog: identity record not written: $($_.Exception.Message)"
    }
}

# --- REGION: UTM VM lifecycle primitives
# --- REGION: Confirm-UtmVMCreated
function Confirm-UtmVMCreated {
    <#
    .SYNOPSIS
        Returns true if a UTM .utm bundle exists for the given VM.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPlist = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (Test-Path $configPlist) {
        Write-Output "Verified: $configPlist"
        return $true
    }
    # Write-Warning (not Write-Error) for this expected-negative outcome so the [bool] contract
    # holds under a caller's ErrorActionPreference=Stop instead of throwing a terminating error.
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ac705056e60985ac' -Arguments @{ configPlist = "$configPlist" })
    return $false
}

<#
.SYNOPSIS
    Classify a bounded `utmctl status <vm>` result into a VM state, the raw
    status word, registration evidence and a reason token.
.DESCRIPTION
    Precedence, first match wins:
      1. never launched (missing client), deadline exhausted, timed out, or
         output not fully drained/captured -> unknown / Unknown;
      2. Apple Event text anywhere in the output (denial, timeout, SSH
         session, other OSStatus) -> unknown / Unknown, even at exit 0 --
         utmctl exits 0 on a denial, so the exit code proves nothing here;
      3. nonzero exit naming the VM as not found -> absent / Absent;
      4. any other nonzero exit -> unknown / Unknown;
      5. exit 0: 'started' -> running; 'paused', 'suspended' or 'stopped'
         -> stopped; a transitional word -> unknown but Registered; anything
         else -> unknown.
    'absent' is the answer callers treat as permission to build or reuse a
    name, so nothing short of a completed not-found answer produces it.
#>
function ConvertFrom-UtmctlStatusResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Result)
    $emit = {
        param([string]$State, [string]$Registration, [string]$Reason, [string]$RawState)
        [pscustomobject]@{ State = $State; RawState = $RawState; Registration = $Registration; Reason = $Reason }
    }
    if ($Result['DeadlineExhausted']) { return (& $emit 'unknown' 'Unknown' 'deadline-exhausted' '') }
    if (-not $Result['Started'])      { return (& $emit 'unknown' 'Unknown' 'missing-client' '') }
    if ($Result['TimedOut'])          { return (& $emit 'unknown' 'Unknown' 'timeout' '') }
    if ($Result['DrainTimedOut'] -or $Result['OutputTruncated'] -or $Result['KillFailed']) {
        return (& $emit 'unknown' 'Unknown' 'invalid-response' '')
    }
    $text = "$($Result['StdOut'])`n$($Result['StdErr'])"
    $appleEvent = Get-UtmAppleEventReason -Text $text
    if ((Get-UtmStartFailureKind -Text $text) -eq 'apple-event' -or $appleEvent -ne 'none') {
        $reason = if ($appleEvent -ne 'none') { $appleEvent } else { 'provider-error' }
        return (& $emit 'unknown' 'Unknown' $reason '')
    }
    if ([int]$Result['ExitCode'] -ne 0) {
        if ($text -match $script:UtmNotFoundPattern) { return (& $emit 'absent' 'Absent' 'not-found' '') }
        return (& $emit 'unknown' 'Unknown' 'invalid-response' '')
    }
    $raw = (@("$($Result['StdOut'])" -split "`r?`n" | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 1)
    $raw = "$raw".ToLowerInvariant()
    switch -Regex ($raw) {
        '^started$'                               { return (& $emit 'running' 'Registered' 'observed' $raw) }
        '^(paused|suspended|stopped)$'            { return (& $emit 'stopped' 'Registered' 'observed' $raw) }
        '^(starting|stopping|pausing|resuming)$'  { return (& $emit 'unknown' 'Registered' 'observed' $raw) }
        '^$'                                      { return (& $emit 'unknown' 'Unknown' 'invalid-response' '') }
        default                                   { return (& $emit 'unknown' 'Registered' 'invalid-response' $raw) }
    }
}

<#
.SYNOPSIS
    Classify a bounded `utmctl list` result: whether it is a listing this
    driver recognizes, and its rows.
.DESCRIPTION
    `utmctl list` is fixed-column: a 'UUID Status Name' header, then one row
    per VM anchored on the 36-character UUID, so a name containing spaces is
    kept whole. A listing is recognized only with the header or at least one
    row; empty or unrecognized output is an invalid response, never "no VMs",
    because a failed listing and an empty one must not look alike.
.OUTPUTS
    [pscustomobject] Recognized, Reason ('listed' or a failure token),
    HeaderSeen, Row [object[]] {Uuid; Status; Name}, UnrecognizedLineCount.
#>
function ConvertFrom-UtmctlListResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Result)
    $emit = {
        param([bool]$Recognized, [string]$Reason, [bool]$HeaderSeen, [object[]]$Row, [int]$Unrecognized)
        [pscustomobject]@{
            Recognized = $Recognized; Reason = $Reason; HeaderSeen = $HeaderSeen
            Row = [object[]]@($Row); UnrecognizedLineCount = $Unrecognized
        }
    }
    if ($Result['DeadlineExhausted']) { return (& $emit $false 'deadline-exhausted' $false @() 0) }
    if (-not $Result['Started'])      { return (& $emit $false 'missing-client' $false @() 0) }
    if ($Result['TimedOut'])          { return (& $emit $false 'timeout' $false @() 0) }
    if ($Result['DrainTimedOut'] -or $Result['OutputTruncated'] -or $Result['KillFailed']) {
        return (& $emit $false 'invalid-response' $false @() 0)
    }
    $appleEvent = Get-UtmAppleEventReason -Text "$($Result['StdOut'])`n$($Result['StdErr'])"
    if ($appleEvent -ne 'none') { return (& $emit $false $appleEvent $false @() 0) }
    if ([int]$Result['ExitCode'] -ne 0) { return (& $emit $false 'invalid-response' $false @() 0) }
    $headerSeen = $false
    $unrecognized = 0
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ("$($Result['StdOut'])" -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^-+$') { continue }
        if ($trimmed -match '^UUID\s+Status\s+Name$') { $headerSeen = $true; continue }
        if ($trimmed -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
            $rows.Add([pscustomobject]@{ Uuid = $Matches[1]; Status = $Matches[2]; Name = $Matches[3].Trim() })
            continue
        }
        $unrecognized++
    }
    if (-not $headerSeen -and $rows.Count -eq 0) { return (& $emit $false 'invalid-response' $false @() $unrecognized) }
    return (& $emit $true 'listed' $headerSeen $rows.ToArray() $unrecognized)
}

<#
.SYNOPSIS
    The inventory record shape shared by Get-UtmRunningVmInventory and the
    responsiveness probe.
#>
function ConvertTo-UtmInventoryRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Parsed)
    $rows = [object[]]@($Parsed.Row)
    $running = [string[]]@($rows | Where-Object { "$($_.Status)" -eq 'started' } | ForEach-Object { [string]$_.Name })
    return [pscustomobject]@{
        PSTypeName            = 'Yuruna.UtmInventory'
        Listed                = [bool]$Parsed.Recognized
        Reason                = [string]$Parsed.Reason
        HeaderSeen            = [bool]$Parsed.HeaderSeen
        Row                   = $rows
        Name                  = $running
        UnrecognizedLineCount = [int]$Parsed.UnrecognizedLineCount
    }
}

<#
.SYNOPSIS
    Structured registration evidence: 'Registered', 'Absent', or 'Unknown'.
.DESCRIPTION
    A call that never returned, or a denied/unrecognized nonzero exit, says
    nothing about registration: reporting it as 'Absent' sends a caller off
    to create a VM that exists, or to delete a registration the probe simply
    could not read. Only a completed response that names the VM as not found
    is 'Absent'. Read from the same classified record as Get-VMState, so the
    two can never disagree about one answer.
#>
function Get-UtmVMRegistrationState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    return [string](Get-VMStateRecord -VMName $VMName).Registration
}

<#
.SYNOPSIS
    True when UTM still holds a registration for the named VM; a boolean
    compatibility wrapper over Get-UtmVMRegistrationState.
.DESCRIPTION
    `utmctl status` exits 0 for every VM UTM knows about regardless of run
    state, and non-zero only when the name resolves to nothing, so it answers
    "is this name still registered" on its own. That makes it the check a
    delete has to be judged by -- `utmctl delete` does not report its own
    outcome reliably (see Remove-UtmVMRegistration).

    $true for 'Registered', $false for 'Absent'. 'Unknown' is a terminating
    classified error, never a silent $false: a denied or timed-out probe
    collapsed to boolean absence is exactly the bug that let a wedged host
    read as one with nothing registered. A caller that must not treat
    Unknown as failure calls Get-UtmVMRegistrationState directly instead of
    this wrapper.
.OUTPUTS
    [bool] $true when UTM still lists the name.
#>
function Test-UtmVMRegistered {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    switch (Get-UtmVMRegistrationState -VMName $VMName) {
        'Registered' { return $true }
        'Absent'     { return $false }
        default {
            throw [System.InvalidOperationException]::new(
                (Format-YurunaOperatorMessage -Key 'exceptions.host_ede3d2a333ea0452' -Arguments @{ vMName = "$VMName" }))
        }
    }
}

<#
.SYNOPSIS
    Deregister a VM from UTM, confirming by probe that the name is really gone.

.DESCRIPTION
    `utmctl delete` exits 0 even when it deleted nothing: it prints the reason
    ("Error from event: The operation couldn't be completed. (OSStatus error
    -2700.) '<name>.utm' couldn't be removed.") on stdout and still returns
    success. An exit-code check therefore reads a total failure as a clean
    delete, so every attempt here is judged by re-probing the registration.

    The case that cannot resolve itself is a registration whose bundle is
    missing from disk. UTM deletes a VM by moving its bundle to the trash, so
    with nothing at the recorded path the delete fails identically on every
    future attempt and the name stays registered indefinitely. That is not
    cosmetic: the name still answers `utmctl status`, so the sequence engine's
    reuse check treats it as an existing VM, skips creation, and hands a
    bundle-less name to Start-VM, which can only fail. Recreating an empty
    bundle directory at the expected path gives the trash-move something to
    operate on and the deregistration completes.

.PARAMETER MaxAttempts
    Delete attempts before giving up. The bundle-restore path needs a second
    pass by construction: the first attempt is what reveals the delete did not
    take.

.OUTPUTS
    [bool] $true when the name is no longer registered with UTM.
#>
function Remove-UtmVMRegistration {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$MaxAttempts = 3
    )
    # Reads registration through the structured probe throughout, never the
    # throwing boolean wrapper: only a positive 'Absent' may report success,
    # and 'Unknown' must refuse rather than fall into either the delete loop
    # or a placeholder-bundle restore meant for a registration proven still
    # there.
    $initial = Get-UtmVMRegistrationState -VMName $VMName
    if ($initial -eq 'Absent') { return $true }
    if ($initial -eq 'Unknown') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_42b86b87ff2eaef3' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_b0f525825afab689'))) { return $false }

    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $placeholderPath = $null
    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            # Bounded, and judged only by the re-probe below: the verb exits 0
            # whether or not it deleted anything, and a delete that timed out
            # has an unknown effect that only a fresh registration read settles.
            $delete = Invoke-UtmctlLifecycle -Verb 'delete' -VMName $VMName -Quiet
            $state = Get-UtmVMRegistrationState -VMName $VMName
            if ($state -eq 'Absent') { return $true }
            if ($delete.Text) { Write-Verbose "utmctl delete '$VMName' (attempt $attempt): $($delete.Text)" }
            if ($state -eq 'Unknown') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c86b25c8af7f4942' -Arguments @{ vMName = "$VMName"; attempt = "$attempt" })
            } elseif (-not (Test-Path -LiteralPath $utmBundle)) {
                # Two ways the bundle can be missing, and only this one -- the
                # name is STILL positively registered -- means the delete
                # genuinely failed on a bundle UTM cannot find to trash.
                Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_f412d26264dfbdd1' -Arguments @{ vMName = "$VMName"; utmBundle = "$utmBundle" }) -InformationAction Continue
                $null = New-Item -Path $utmBundle -ItemType Directory -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $utmBundle) { $placeholderPath = $utmBundle }
                continue
            }
            if ($attempt -lt $MaxAttempts -and $script:UtmDeleteRetryDelaySeconds -gt 0) { Start-Sleep -Seconds $script:UtmDeleteRetryDelaySeconds }
        }
        return ((Get-UtmVMRegistrationState -VMName $VMName) -eq 'Absent')
    } finally {
        # A placeholder that outlived a still-failing delete would be read as a
        # real bundle by anything sizing or inventorying the VM store, so it is
        # only allowed to persist when it is about to become the deleted VM's
        # trashed bundle. Guarded on emptiness so a bundle that reappeared
        # underneath (a concurrent New-VM for the same name) is never removed.
        if ($placeholderPath -and (Test-Path -LiteralPath $placeholderPath) -and
            -not (Get-ChildItem -LiteralPath $placeholderPath -Recurse -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $placeholderPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Stop, delete, and remove the UTM bundle for the given VM.
#>
function Remove-UtmTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_12924e738438f274'))) { return $false }
    $stop = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName
    if ($stop.OutcomeKnown -and $stop.ExitCode -eq 0 -and $stop.FailureKind -eq 'none') {
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_ad3787aa98e176ba' -Arguments @{ vMName = "$VMName" }) -InformationAction Continue
    }
    # See https://yuruna.link/42e220c4-0004
    # Confirm power-off and released disk locks before unregistering the bundle.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_69569daab01168ea' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    if (-not (Remove-UtmVMRegistration -VMName $VMName -Confirm:$false)) {
        # See https://yuruna.link/42e220c4-0004
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b393323b168a09a' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    Write-Verbose "Deleted UTM VM from registry: $VMName"
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (Test-Path $utmBundle) {
        if (Remove-UtmBundleWithRetry -Path $utmBundle) {
            Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_fdce3f3a724deacc' -Arguments @{ utmBundle = "$utmBundle" }) -InformationAction Continue
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_16a11cbfeabe41ff' -Arguments @{ utmBundle = "$utmBundle" })
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Classify what `utmctl start` printed: an Apple Event transport failure, a
    QEMU failure, or nothing wrong. Returns 'apple-event', 'qemu' or 'none'.

.DESCRIPTION
    utmctl exits 0 for both failure classes, and the two need opposite
    responses. An Apple Event error (an OSStatus code, "Error from event")
    means UTM.app did not ACT on the request: the VM was never launched, it is
    exactly as it was, and the same call issued moments later routinely
    succeeds. A QEMU error means the VM DID launch and its process then died --
    a port it cannot bind, a missing disk -- which no amount of repeating will
    change.

    Reporting the first as the second sends the reader to the VM layer for a
    fault that never reached it, and tells them to rebuild a VM that is fine.

    The Apple Event side is any row of the driver's one wording table
    ($script:UtmAppleEventReasonPattern), so a denial, a timeout, an SSH
    session and a generic OSStatus failure are all recognized here exactly as
    the state and responsiveness probes recognize them.
#>
function Get-UtmStartFailureKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    # QEMU first: a message naming QEMU is about the VM process even if an
    # Apple Event phrase appears alongside it.
    if ($Text -match 'QEMU error|QEMU exited from an error') { return 'qemu' }
    if ((Get-UtmAppleEventReason -Text $Text) -ne 'none') { return 'apple-event' }
    return 'none'
}

<#
.SYNOPSIS
    Start a UTM VM and confirm it by POLLING STATE, retrying a few times.
    Returns @{ success; errorMessage; attempts; kind }.

.DESCRIPTION
    `utmctl start` is not a trustworthy report of its own outcome. It exits 0
    while UTM is still ingesting a bundle and drops the request; it exits 0 and
    prints an Apple Event error when UTM never acted on it; and it exits 0 for a
    VM whose QEMU then dies. The VM's state afterwards is the only answer that
    means anything, so every attempt here is judged by polling Get-VMState
    rather than by the verb's exit code or its output.

    Retrying is the point of this function. An Apple Event failure leaves the
    VM untouched, and the same start issued seconds later normally works -- so a
    single attempt turns a momentary refusal into an outage that lasts until an
    operator types the command by hand, taking every guest that consumes the
    service down with it for as long as that takes.

    A QEMU failure is deliberately NOT retried. The VM launched and its process
    died; repeating that only multiplies the delay before the caller finds out
    something is really wrong.

    Each attempt first OBSERVES, within its settle window, until the VM shows
    a positive state: 'running' ends the call as a success, 'stopped' permits
    exactly one start, a VM still not registered at the end of the window
    moves on to the next attempt without a start, and a state that stays
    unconfirmed (denied, timed out, unrecognized, still transitioning) returns
    'unresolved' without a start. An earlier positive reading never
    authorizes a later start: issuing `utmctl start` into an unconfirmed state
    risks acting twice on a VM already coming up.

    A start whose own call timed out has an unknown effect; it is never
    replayed on its exit code. The settle poll that follows is the fresh
    postcondition, and the next attempt re-observes before it may start again.

    Two consecutive starts that UTM did not act on because the control
    channel itself failed -- the call waited out the Apple Event timeout
    (-1712), the connection to UTM.app was invalidated (-609), or the bounded
    call never returned -- end the loop early with kind 'apple-event' and
    controlHung=$true, whatever MaxAttempts says. A UTM that answers state
    queries but holds every lifecycle verb to its timeout does not recover
    between attempts; each further attempt only adds the timeout to the
    outage, and the caller needs the verdict, not the delay. A single such
    failure is still retried, because a momentary refusal does recover.

    With -Deadline every wait, backoff, state read and start is bounded by
    what that shared deadline has left, on top of -- never instead of --
    MaxAttempts and SettleSeconds.

    The dialog watchdog is the caller's business, not this function's: some
    callers hold one open across a longer sequence, and Start-UtmDialogWatchdog
    stops any predecessor, so starting one here would kill theirs.

.PARAMETER MaxAttempts
    Start attempts before giving up. Attempts after the first are spaced by a
    pause that grows with the attempt number.

.PARAMETER SettleSeconds
    How long one attempt observes before starting, and how long it waits for
    the VM to reach 'running' afterwards, before that attempt is judged.

.PARAMETER BackoffSeconds
    Base of the pause between attempts.

.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).

.OUTPUTS
    [hashtable] success, errorMessage, attempts, kind ('none' | 'qemu' |
    'apple-event' | 'unresolved' | 'absent'), controlHung ([bool]: the loop
    ended on two consecutive control-channel failures) and appleEventReason
    (the wording-table row of the last Apple Event failure, or 'none').
#>
function Invoke-UtmVMStartWithRetry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$MaxAttempts    = 3,
        [int]$SettleSeconds  = 20,
        [int]$BackoffSeconds = 5,
        $Deadline
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5e0073f7baaa6926'))) {
        return @{ success = $false; errorMessage = 'WhatIf'; attempts = 0; kind = 'none'; controlHung = $false; appleEventReason = 'none' }
    }
    $attemptCap = [Math]::Max(1, $MaxAttempts)
    $settleMs   = [long][Math]::Max(1, $SettleSeconds) * 1000
    $lastError  = ''
    $lastKind   = 'none'
    $lastAppleEventReason = 'none'
    # Consecutive starts the control channel itself failed; reset by any
    # attempt that UTM answered, even with a refusal.
    $controlStreak = 0
    $startsIssued = 0
    # Reads the state until one of $Until is observed or $Window ends. The
    # window only paces the polling; each read is bounded by the shared
    # deadline (or its own cap), because a read bounded by a window's last
    # fraction of a second could never be issued. A read the deadline had no
    # time for never replaces an answer already obtained.
    $observe = {
        param($Window, [string[]]$Until, $Limit)
        $reading = $null
        do {
            $next = Get-VMStateRecord -VMName $VMName -Deadline $Limit
            if (-not $reading -or $next.Reason -ne 'deadline-exhausted') { $reading = $next }
            if ($Until -contains $reading.State) { break }
        } while (Wait-UtmInterval -Milliseconds $script:UtmStartSettlePollMilliseconds -Deadline $Window)
        return $reading
    }
    $unresolved = {
        param([string]$Message, [int]$Attempt)
        return @{ success = $false; attempts = $Attempt; kind = 'unresolved'; errorMessage = $Message; controlHung = $false; appleEventReason = $lastAppleEventReason }
    }
    for ($attempt = 1; $attempt -le $attemptCap; $attempt++) {
        if ($Deadline -and (Test-YurunaDeadlineExpired -Deadline $Deadline)) {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_dc12e47845da9820' -Arguments @{ vMName = "$VMName" }) ($attempt - 1))
        }
        $before = & $observe (Get-UtmChildDeadline -Milliseconds $settleMs -Parent $Deadline) @('running', 'stopped') $Deadline
        if ($before.State -eq 'running') {
            return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none'; controlHung = $false; appleEventReason = 'none' }
        }
        if ($before.State -eq 'absent') { continue }
        if ($before.State -ne 'stopped') {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_5cde67d59ac2073f' -Arguments @{ vMName = "$VMName"; attempt = "$attempt" }) $attempt)
        }
        if ($startsIssued -gt 0) {
            $pauseMs = [long]$BackoffSeconds * 1000 * ($attempt - 1)
            if ($Deadline) { $pauseMs = [Math]::Min($pauseMs, [long](Get-YurunaDeadlineRemainingMs -Deadline $Deadline)) }
            Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_a1a6059aaacffcb8' -Arguments @{ vMName = "$VMName"; state = "$($before.RawState)"; attempt = "$attempt"; attemptCap = "$attemptCap"; pause = "$([int][Math]::Floor($pauseMs / 1000))" }) -InformationAction Continue
            if ($pauseMs -gt 0) { $null = Wait-UtmInterval -Milliseconds ([int][Math]::Min($pauseMs, 3600000)) -Deadline $Deadline }
        }

        $start = Invoke-UtmctlLifecycle -Verb 'start' -VMName $VMName -Deadline $Deadline -Quiet
        if ($start.DeadlineExhausted) {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_dc12e47845da9820' -Arguments @{ vMName = "$VMName" }) $attempt)
        }
        $startsIssued++
        $text = [string]$start.Text
        if ($text) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_4d8f5df44a5acae0' -Arguments @{ text = "$text" }) -InformationAction Continue }
        $lastKind = [string]$start.FailureKind
        $lastAppleEventReason = if ($lastKind -eq 'apple-event') { Get-UtmAppleEventReason -Text $text } else { 'none' }
        # A denial or a generic provider error is an answer from UTM; only a
        # request the channel never completed counts toward the streak.
        $controlFailed = (-not $start.OutcomeKnown) -or ($lastAppleEventReason -in @('timeout', 'connection-invalid'))
        $controlStreak = if ($controlFailed) { $controlStreak + 1 } else { 0 }
        $lastError = if (-not $start.OutcomeKnown) {
            Format-YurunaOperatorMessage -Key 'host.utmctl_lifecycle_timeout' -Arguments @{ verb = 'start'; vmName = "$VMName"; timeoutSeconds = "$($start.TimeoutSeconds)" }
        } elseif ($start.ExitCode -ne 0) {
            if ($text) { Format-YurunaOperatorMessage -Key 'host.utm_start_exit_detail' -Arguments @{ exitCode = "$($start.ExitCode)"; text = "$text" } }
            else { Format-YurunaOperatorMessage -Key 'host.utm_start_exit_code' -Arguments @{ exitCode = "$($start.ExitCode)" } }
        } elseif ($lastKind -ne 'none') { $text } else { '' }

        # See https://yuruna.link/42e220c4-0004
        $settle = Get-UtmChildDeadline -Milliseconds $settleMs -Parent $Deadline
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_b0d08bfb4f337561' -Arguments @{ vMName = "$VMName" }) $attempt)
        }
        $after = & $observe $settle @('running') $Deadline
        if ($after.State -eq 'running') {
            return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none'; controlHung = $false; appleEventReason = 'none' }
        }
        if ($lastKind -eq 'qemu') {
            return @{ success = $false; attempts = $attempt; kind = 'qemu'; controlHung = $false; appleEventReason = 'none'
                      errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_d2824e1687d3fb3f' -Arguments @{ vMName = "$VMName"; lastError = "$lastError" }) }
        }
        if ($controlStreak -ge 2) {
            return @{ success = $false; attempts = $attempt; kind = 'apple-event'; controlHung = $true; appleEventReason = $lastAppleEventReason
                      errorMessage = (Format-YurunaOperatorMessage -Key 'host.utm_start_control_hung' -Arguments @{ vmName = "$VMName"; attempts = "$attempt"; lastError = "$lastError" }) }
        }
        if ($after.State -ne 'stopped' -and $after.State -ne 'absent') {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_5cde67d59ac2073f' -Arguments @{ vMName = "$VMName"; attempt = "$attempt" }) $attempt)
        }
    }
    if ($startsIssued -eq 0) {
        return @{ success = $false; attempts = $attemptCap; kind = 'absent'; controlHung = $false; appleEventReason = 'none'
                  errorMessage = (Format-YurunaOperatorMessage -Key 'host.utm_start_absent_observed' -Arguments @{ vmName = "$VMName"; waitSeconds = "$([int]($settleMs / 1000))"; attempt = "$attemptCap" }) }
    }
    $detail = if ($lastKind -eq 'apple-event') {
        Format-YurunaOperatorMessage -Key 'host.utm_start_not_acted' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap"; lastError = "$lastError" }
    } elseif ($lastError) {
        Format-YurunaOperatorMessage -Key 'host.utm_start_not_running' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap"; lastError = "$lastError" }
    } else {
        Format-YurunaOperatorMessage -Key 'host.utm_start_dropped' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap" }
    }
    return @{ success = $false; errorMessage = $detail; attempts = $attemptCap; kind = $lastKind; controlHung = $false; appleEventReason = $lastAppleEventReason }
}

<#
.SYNOPSIS
    Cold-start a UTM VM (clears stale vmstate and spawns dialog watchdog).
#>
function Start-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        # Called after the VNC display is reserved, before UTM can power on.
        [scriptblock]$BeforeLaunch
    )
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        # See https://yuruna.link/42e5cdfd-0003
        switch (Get-UtmVMRegistrationState -VMName $VMName) {
            'Registered' {
                return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_d389bec5f4a68d26' -Arguments @{ vMName = "$VMName"; utmBundle = "$utmBundle" }) }
            }
            'Unknown' {
                return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_0d8dc260f5da53ac' -Arguments @{ utmBundle = "$utmBundle"; vMName = "$VMName" }) }
            }
            default {
                return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_4b2811cd5d4abd27' -Arguments @{ utmBundle = "$utmBundle" }) }
            }
        }
    }
    try {
        if ($PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_13ef318fcba6de6e'))) {
            # New-VM can already have started the installer. Reusing that VM
            # must not rewrite its active VNC configuration or clear vmstate.
            if ((Get-VMStateRecord -VMName $VMName).State -eq 'running') {
                if ($BeforeLaunch) { $null = & $BeforeLaunch }
                return @{ success = $true; errorMessage = $null; kind = 'none'; controlHung = $false }
            }
            $vmstatePath = Join-Path $utmBundle "Data/vmstate"
            if (Test-Path $vmstatePath) {
                Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
                # Progress on the information stream, never the success stream:
                # this function returns a status record, and anything written to
                # output becomes part of that return. A caller checking
                # `$result -is [hashtable]` then sees an Object[] and skips its
                # own failure check, so a VM that never started reports success.
                Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_76b79a689aa25a38' -Arguments @{ vMName = "$VMName" }) -InformationAction Continue
            }
            # See https://yuruna.link/42e5cdfd-0003
            $wantDisplay = Find-FreeVncDisplay `
                -Preferred (Get-VncDisplayForVm -VMName $VMName) `
                -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $VMName)
            if ($wantDisplay -lt 0) {
                return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_239ba3e5aec356be' -Arguments @{ vMName = "$VMName" }) }
            }
            if (-not (Test-VncDisplayInBundle -VMName $VMName -Display $wantDisplay)) {
                if (Set-VncDisplayInBundle -VMName $VMName -Display $wantDisplay -Confirm:$false) {
                    Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_645bdc6defb51655' -Arguments @{ vMName = "$VMName"; wantDisplay = "$wantDisplay"; wantDisplay2 = "$(5900 + $wantDisplay)" }) -InformationAction Continue
                } else {
                    if ($BeforeLaunch) {
                        return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_d3e7833e5fc51e09' -Arguments @{ vMName = "$VMName" }) }
                    }
                    # Not fatal on its own: the bundle may still hold a usable
                    # display. Say so, because a screenshot aimed at the stale
                    # port would otherwise capture another VM's framebuffer.
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d3e7833e5fc51e09' -Arguments @{ vMName = "$VMName" })
                }
            }
            if ($BeforeLaunch) { $null = & $BeforeLaunch }
            Start-UtmDialogWatchdog
            # Detached: `open` hands the bundle to UTM and returns, and UTM
            # must outlive this call, so only the acknowledgment is bounded.
            $null = Start-UtmDetachedLaunch -Tool 'open' -ArgumentList @($utmBundle) -Confirm:$false
            # See https://yuruna.link/42e5cdfd-0003
            $start = Invoke-UtmVMStartWithRetry -VMName $VMName -Confirm:$false
            if (-not $start.success) {
                # The kind travels with the record so a caller can tell a
                # control channel that stopped acting (retrying is pointless
                # until UTM is restarted) from a VM that refused to come up.
                if ($start.controlHung) {
                    $null = Save-UtmControlSnapshot -Trigger 'start-control-hung' -VMName $VMName -Confirm:$false
                }
                $hostKind = if ($start.controlHung) { 'unresponsive' } else { 'tool' }
                return @{ success = $false; errorMessage = $start.errorMessage; kind = [string]$start.kind
                          controlHung = [bool]$start.controlHung; appleEventReason = [string]$start.appleEventReason
                          failureClass = [string](New-YurunaHostResult -Kind $hostKind).failureClass }
            }
        }
        return @{ success = $true; errorMessage = $null; kind = 'none'; controlHung = $false }
    } catch {
        return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_3f0823f611b21152' -Arguments @{ vMName = "$VMName"; value = "$_" }) }
    }
}

<#
.SYNOPSIS
    Request a guest operating system shutdown via utmctl.
#>
function Stop-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_ec02730efdb72c13'))) { return $true }
    Stop-UtmDialogWatchdog
    # Bare utmctl stop defaults to forced power-off and can lose guest writes.
    $stop = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName -Request
    if ($stop.OutcomeKnown -and $stop.ExitCode -eq 0) {
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_ad3787aa98e176ba' -Arguments @{ vMName = "$VMName" }) -InformationAction Continue
        Start-Sleep -Seconds 2
        return $true
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_56dca8fbb7ddb723' -Arguments @{ vMName = "$VMName"; lASTEXITCODE = "$($stop.ExitCode)" })
    return $false
}

<#
.SYNOPSIS
    Poll the VM state until it is positively 'running', within one deadline.
.DESCRIPTION
    One deadline, the smaller of -TimeoutSeconds and what -Deadline has left,
    bounds every state read and every pause. Only a positive 'running' state
    counts: a text match over raw output would also accept "not running".
.PARAMETER TimeoutSeconds
    This call's own budget.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
#>
function Confirm-UtmVMStarted {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 120,
        $Deadline
    )
    $wait = Get-UtmChildDeadline -Milliseconds ([long][Math]::Max(0, $TimeoutSeconds) * 1000) -Parent $Deadline
    while (-not (Test-YurunaDeadlineExpired -Deadline $wait)) {
        if ((Get-VMStateRecord -VMName $VMName -Deadline $wait).State -eq 'running') {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ebad947b6ac44dfe' -Arguments @{ vMName = "$VMName" })
            return $true
        }
        $null = Wait-UtmInterval -Milliseconds $script:UtmStartSettlePollMilliseconds -Deadline $wait
    }
    # Write-Warning (not Write-Error) for this expected-negative timeout so the [bool] contract
    # holds under a caller's ErrorActionPreference=Stop instead of throwing a terminating error.
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6d178454089aa5b0' -Arguments @{ vMName = "$VMName"; timeoutSeconds = "${TimeoutSeconds}" })
    return $false
}

<#
.SYNOPSIS
    Block until the VM's QEMU process is gone and every qcow2 disk is
    unlocked, so a following qemu-img snapshot create/apply is safe.
.DESCRIPTION
    `utmctl stop` (default --force) returns when the power-off *event* is
    sent, not when QEMUHelper has exited and released the qcow2. A
    qemu-img snapshot -c/-a that runs while the helper is still alive
    races its in-memory L1/L2 tables: the helper flushes its own
    (un-reverted) view on exit and silently clobbers the change, so the
    revert "succeeds" yet the guest resumes the pre-revert disk. This
    waits that window out -- polling `utmctl status` to drive a hard
    `--kill` escalation if the power-off stalls, and gating success on the
    write lock actually being free. `qemu-img info` WITHOUT -U fails while
    any process holds the lock, so a clean exit on every disk is the
    unambiguous "safe to mutate" signal (a bare status check is not: a
    'suspended'/'paused' guest still holds the lock).

    One deadline -- the smaller of -TimeoutSeconds and what -Deadline has
    left -- bounds every state read, the kill, every lock probe and every
    pause. A state that cannot be read counts as NOT powered off, and the
    kill is sent only on a positive running/paused/suspended reading after
    half the budget: an unanswered probe is no reason to kill a VM.
.PARAMETER TimeoutSeconds
    This call's own budget.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [bool] $true once powered off and every disk is unlocked; $false on
    timeout.
#>
function Wait-UtmVMPoweredOff {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        $Deadline
    )
    $dataDir  = "$HOME/yuruna/guest.nosync/$VMName.utm/Data"
    $budgetMs = [long][Math]::Max(0, $TimeoutSeconds) * 1000
    $wait     = Get-UtmChildDeadline -Milliseconds $budgetMs -Parent $Deadline
    # Escalation point: the moment half of this call's own budget remains.
    $escalateAtRemainingMs = [long]((Get-YurunaDeadlineRemainingMs -Deadline $wait) / 2)
    $killIssued = $false
    $reading = $null
    while (-not (Test-YurunaDeadlineExpired -Deadline $wait)) {
        $next = Get-VMStateRecord -VMName $VMName -Deadline $wait
        # Once no call fits in what remains, the last real answer stands.
        if ($next.Reason -eq 'deadline-exhausted') {
            $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $wait
            continue
        }
        $reading = $next
        $holdsDisk = ($reading.State -eq 'running') -or ($reading.RawState -in @('paused', 'suspended'))
        # Drive the kill escalation off a POSITIVE reading: the default
        # power-off event is near-instant, but a stalled (or suspended) guest
        # never frees the lock on its own. After half the budget, force-kill
        # the process so the qcow2 is released deterministically.
        if ($holdsDisk -and -not $killIssued -and (Get-YurunaDeadlineRemainingMs -Deadline $wait) -le $escalateAtRemainingMs) {
            $null = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName -Kill -Deadline $wait
            $killIssued = $true
        }
        # See https://yuruna.link/42e220c4-0004
        if (($reading.State -eq 'stopped' -and -not $holdsDisk) -or $reading.State -eq 'absent') {
            $allFree = $true
            foreach ($disk in @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)) {
                $lockProbe = Invoke-UtmHostTool -Tool 'qemu-img' -ArgumentList @('info', $disk.FullName) -TimeoutSeconds 30 -Deadline $wait
                if (-not (Test-UtmBoundedResultComplete -Result $lockProbe) -or $lockProbe.ExitCode -ne 0) { $allFree = $false; break }
            }
            if ($allFree) { return $true }
        }
        $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $wait
    }
    return $false
}

<#
.SYNOPSIS
    The `utmctl list` inventory as a record that tells a failed listing
    apart from an empty one.
.DESCRIPTION
    A listing that timed out, was denied, came from a missing client or did
    not parse is Listed=$false with the reason; only a recognized listing is
    Listed=$true, and only then does an empty Name mean nothing is running.
    Callers that must tell the two apart (Rename-VM's pre-quit capture, the
    concurrency guard, the responsiveness probe) read this record rather than
    Get-RunningVmName.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER TimeoutSeconds
    This call's own cap.
.OUTPUTS
    [pscustomobject] Listed, Reason ('listed' | 'missing-client' | 'timeout' |
    'permission-denied' | 'no-session' | 'provider-error' | 'invalid-response'
    | 'deadline-exhausted'), HeaderSeen, Row [object[]] {Uuid; Status; Name},
    Name [string[]] (rows whose Status is 'started'), UnrecognizedLineCount.
#>
function Get-UtmRunningVmInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $Deadline,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20
    )
    $resolver = Resolve-UtmctlExecutable
    $listing = if ($resolver.Source -eq 'missing') {
        @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $false; DeadlineExhausted = $false }
    } else {
        Invoke-UtmctlProbe -Arguments @('list') -TimeoutSeconds $TimeoutSeconds -UtmctlPath $resolver.Path -Deadline $Deadline
    }
    return (ConvertTo-UtmInventoryRecord -Parsed (ConvertFrom-UtmctlListResult -Result $listing))
}

<#
.SYNOPSIS
    Return the names of every UTM VM whose `utmctl list` Status is
    `started`. Emits nothing when none are running, when utmctl is missing,
    or when utmctl errors. Cheap (single `utmctl list` call).

.DESCRIPTION
    utmctl list columns are UUID, Status, Name. A caller that must tell
    "none running" from "could not ask" uses Get-UtmRunningVmInventory
    instead: this wrapper emits nothing in both cases.
#>
function Get-RunningVmName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # See https://yuruna.link/42e220c4-0004
    $inventory = Get-UtmRunningVmInventory
    if (-not $inventory.Listed) { return }
    foreach ($name in $inventory.Name) { if ($name) { $name } }
}

<#
.SYNOPSIS
    Run a read-only utmctl subcommand under a wall-clock cap.
.DESCRIPTION
    utmctl is an Apple Events client: every call is a round trip to UTM.app,
    and it carries no timeout of its own. When UTM.app stops answering -- host
    memory pressure, a consent dialog nobody is present to click, an app that
    has simply wedged -- the call does not fail, it waits. The enumeration
    probes here run in the cycle preamble, which is watched for progress, so an
    unbounded wait costs the whole cycle rather than one unanswered question.

    Read-only subcommands ONLY (`list`, `status`, `ip-address`). The lifecycle
    verbs go through Invoke-UtmctlLifecycle, which has caps sized for them and
    reports an unknown outcome instead of this probe's relaunch advice.
.PARAMETER Arguments
    The utmctl argument vector, passed verbatim.
.PARAMETER TimeoutSeconds
    Wall-clock cap. Twenty seconds is far past what a healthy UTM needs for an
    enumeration and far short of what the watchdog allows a preamble.
.PARAMETER UtmctlPath
    The executable to run. Defaults to what Resolve-UtmctlExecutable finds,
    and to the bare name when it finds nothing, so a missing client still
    returns a not-started result rather than an error.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline); with under one second
    left nothing is launched and the result says DeadlineExhausted.
.PARAMETER Quiet
    Suppress the timeout warning, for a caller that classifies the timeout
    itself.
.OUTPUTS
    [hashtable] as returned by Invoke-BoundedNativeCommand, plus
    DeadlineExhausted.
#>
function Invoke-UtmctlProbe {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20,
        [string]$UtmctlPath,
        $Deadline,
        [switch]$Quiet
    )
    if (-not $UtmctlPath) {
        $UtmctlPath = (Resolve-UtmctlExecutable).Path
        if (-not $UtmctlPath) { $UtmctlPath = 'utmctl' }
    }
    $cap = $TimeoutSeconds
    if ($Deadline) {
        $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling $TimeoutSeconds
        if ($null -eq $bounded) { return (Get-UtmNotLaunchedResult -Tool 'utmctl') }
        $cap = [int]$bounded
    }
    $outcome = Invoke-BoundedNativeCommand -FilePath $UtmctlPath -ArgumentList $Arguments -TimeoutSeconds $cap
    $outcome['DeadlineExhausted'] = $false
    if ($outcome.TimedOut -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c58ea69de806b447' -Arguments @{ join = "$($Arguments -join ' ')"; timeoutSeconds = "${cap}" })
    }
    return $outcome
}

<#
.SYNOPSIS
    Return $true only when utmctl can actually talk to UTM.app right now.
.DESCRIPTION
    Under host memory pressure UTM.app stops answering Apple Events, and
    utmctl surfaces that as "The operation couldn't be completed. (OSStatus
    error -1712.)" (errAETimeout) -- sometimes with a zero exit code and an
    otherwise-empty listing. An exit-code check alone therefore can't tell
    "no VMs running" from "couldn't ask UTM.app", so a caller that reads an
    empty running-set as a verified-clean host would false-pass. Match the
    timeout signature explicitly so "couldn't verify" stays distinguishable
    from "confirmed clear".

    The wedge has a third shape beyond a slow answer and an error string: no
    answer at all. Bounding the call is what turns that one into a verdict --
    without it this function is the thing that hangs, and "couldn't verify"
    never gets returned to anybody.
.OUTPUTS
    [bool] $true when utmctl responded; $false when utmctl is missing,
    exited non-zero, timed out, or UTM.app reported an Apple Event timeout.
#>
function Test-UtmctlResponsive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) { return $false }
    $outcome = Invoke-UtmctlProbe -Arguments @('list')
    if ($outcome.TimedOut -or $outcome.ExitCode -ne 0) { return $false }
    $combined = "$($outcome.StdOut)`n$($outcome.StdErr)"
    if ($combined -match 'OSStatus error|couldn.t be completed') { return $false }
    return $true
}

<#
.SYNOPSIS
    Refuse the cycle start when any UTM VM other than $ExceptVmName is
    currently `started`. Writes a multi-line actionable warning naming
    each offender + the exact `utmctl stop` command, then returns $false.
    Returns $true on success (no concurrent VMs).

.DESCRIPTION
    On some macOS versions UTM vmnet-shared assigns a separate host-side
    bridge per vmnet "session" (bridge100, bridge101, ...); guests on
    different bridges don't route to each other or to the host's vmnet
    gateway, so the cloud-init host-proxy URL baked into seed.iso (from the
    first bridge's host IP) becomes unreachable and the cycle fails at its
    first fetch-and-execute step with "Connection timed out". This helper
    is invoked at cycle start (Debug-TestSequence.ps1 and Invoke-TestRunnerInnerLoop.ps1)
    to refuse the cycle before any test bundle is created, so the operator
    can stop the offender(s) and re-run.

    On macOS 26, every vmnet-shared VM observed instead shares ONE bridge
    (bridge100 / 192.168.64.1) and all guests route to each other directly
    -- so the split does not occur there. The guard stays for older hosts
    where it still can, but these names never trip the refusal:
      * the service VMs (Get-YurunaServiceVmName) -- infrastructure meant to run
        alongside cycles, and consumed BY them. Test guests take squid from the
        caching proxy and, on the shared bridge, reach it directly at its
        192.168.64.x IP; the build uploads to the stash service; the configuration store
        is served by pool-control. A running service is a dependency, not an
        offender, and refusing over one blocks the cycle on something it needs.
      * $ExceptVmName -- the dev-loop case where Debug-TestSequence is re-invoked
        against a VM the operator left running for inspection.

.PARAMETER ExceptVmName
    Optional. A single VM name to exclude from the running-VM list
    before the refuse check. Typically the cycle's target test VM.
#>
function Assert-NoConcurrentUtmVm {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ExceptVmName)
    # See https://yuruna.link/42e5cdfd-0004
    if (-not (Test-UtmctlResponsive)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c2034aca8b66df6c')
        return $true
    }
    # The listing itself can still fail after the responsiveness check passed
    # (a denial or a timeout on this second call); a failed listing is the same
    # "could not check" as an unresponsive utmctl, never an empty running set.
    $inventory = Get-UtmRunningVmInventory
    if (-not $inventory.Listed) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c2034aca8b66df6c')
        return $true
    }
    # The service VMs are infrastructure designed to coexist with test cycles;
    # never let one count as a concurrent offender (see .DESCRIPTION). Shared with
    # Stop-ConcurrentVM's exemption list, because a name exempt from one guard and
    # not the other is worse than being absent from both: the first guard stops
    # the service, and the second still refuses the cycle over it.
    $alwaysAllow = @(Get-YurunaServiceVmName)
    $running = @($inventory.Name | Where-Object { $_ -and $alwaysAllow -notcontains $_ })
    if ($ExceptVmName) {
        $running = @($running | Where-Object { $_ -ne $ExceptVmName })
    }
    if ($running.Count -eq 0) { return $true }
    Write-Warning "========"
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_500559b43c00e9b5')
    foreach ($vm in $running) { Write-Warning "   - $vm" }
    Write-Warning ""
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_304b5f00f0993a84')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_126b9e222d96af9b')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3fe3cd93d9d34a34')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9e142fdec39e7972')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_90bd2a836a6aaeff')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1e843c81eb019b8e')
    foreach ($vm in $running) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_dd2f6150f71e2f9e' -Arguments @{ vm = "$vm" }) }
    Write-Warning ""
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_afea0597f2c66720' -Arguments @{ join = "$($alwaysAllow -join ', ')" })
    if ($ExceptVmName) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_aee40e2e224cb007' -Arguments @{ exceptVmName = "$ExceptVmName" })
    }
    Write-Warning "========"
    return $false
}

<#
.SYNOPSIS
    Activate the UTM application window (Metal repaint nudge).
#>
function Restart-UtmConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5ca701631669fb6d'))) { return $false }
    # Bounded: the activate is an Apple Event, and a UTM that stopped
    # answering would otherwise hold the repaint nudge forever.
    $activation = Invoke-UtmHostTool -Tool 'osascript' -ArgumentList @('-e', 'tell application "UTM" to activate') -TimeoutSeconds 10
    # A failed Apple Event cannot establish that the display was refreshed.
    # Recovery callers must retain that uncertainty rather than replay input.
    if (-not (Test-UtmBoundedResultComplete -Result $activation) -or $activation.ExitCode -ne 0) { return $false }
    Start-Sleep -Seconds 1
    Write-Verbose "    Activated UTM window for '$VMName' (display repaint)"
    return $true
}

<#
.SYNOPSIS
    Run a utmctl lifecycle verb -- start, stop, stop --kill or delete --
    under a wall-clock cap.
.DESCRIPTION
    These verbs are Apple Event round trips like every other utmctl call, and
    a wedged UTM holds them just as long, but they legitimately take longer
    than an enumeration: the default caps are start 300 s, stop 120 s,
    stop --kill 60 s and delete 120 s, each shortened to what -Deadline has
    left. With under one second left nothing is launched.

    OutcomeKnown is $true only when the call ran to completion with its
    output fully read. A call that timed out has an unknown effect -- UTM may
    have acted on it -- so a caller seeing OutcomeKnown=$false re-reads the
    VM state and never replays the verb on the strength of an exit code.

    No ShouldProcess here: every caller gates its own mutation.
.PARAMETER Verb
    'start', 'stop' or 'delete'.
.PARAMETER VMName
    The VM the verb acts on.
.PARAMETER Kill
    With 'stop' only: `utmctl stop --kill`, which ends the VM process instead
    of sending the power-off event.
.PARAMETER Request
    With 'stop' only: `utmctl stop --request`, which asks the guest operating
    system to shut down and flush its filesystems. Mutually exclusive with Kill.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER TimeoutSeconds
    Replaces the verb's default cap.
.PARAMETER Quiet
    Suppress the timeout and deadline warnings, for a caller that reports
    the outcome itself.
.OUTPUTS
    [hashtable] the Invoke-BoundedNativeCommand keys plus Verb, VMName, Kill,
    TimeoutSeconds, DeadlineExhausted, OutcomeKnown, FailureKind ('qemu' |
    'apple-event' | 'none') and Text (the non-empty output lines joined).
#>
function Invoke-UtmctlLifecycle {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'stop', 'delete')][string]$Verb,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(ParameterSetName = 'Kill')][switch]$Kill,
        [Parameter(ParameterSetName = 'Request')][switch]$Request,
        $Deadline,
        [ValidateRange(1, 600)][int]$TimeoutSeconds,
        [switch]$Quiet
    )
    if ($Kill -and $Verb -ne 'stop') {
        throw [System.ArgumentException]::new((Format-YurunaOperatorMessage -Key 'exceptions.host_utmctl_kill_requires_stop' -Arguments @{ verb = "$Verb" }))
    }
    $cap = if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds }
           elseif ($Verb -eq 'start') { 300 }
           elseif ($Kill) { 60 }
           else { 120 }
    $argv = @($Verb, $VMName)
    if ($Kill) { $argv += '--kill' }
    if ($Request) { $argv += '--request' }
    if ($Deadline) {
        $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling $cap
        if ($null -eq $bounded) {
            $result = Get-UtmNotLaunchedResult -Tool 'utmctl'
            $result['Verb'] = $Verb; $result['VMName'] = $VMName; $result['Kill'] = [bool]$Kill; $result['TimeoutSeconds'] = 0
            $result['OutcomeKnown'] = $false; $result['FailureKind'] = 'none'; $result['Text'] = ''
            if (-not $Quiet) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.utmctl_lifecycle_deadline' -Arguments @{ verb = "$Verb"; vmName = "$VMName" })
            }
            return $result
        }
        $cap = [int]$bounded
    }
    $utmctl = (Resolve-UtmctlExecutable).Path
    if (-not $utmctl) { $utmctl = 'utmctl' }
    $result = Invoke-BoundedNativeCommand -FilePath $utmctl -ArgumentList $argv -TimeoutSeconds $cap
    $result['DeadlineExhausted'] = $false
    $result['Verb'] = $Verb
    $result['VMName'] = $VMName
    $result['Kill'] = [bool]$Kill
    $result['TimeoutSeconds'] = $cap
    $result['OutcomeKnown'] = [bool](Test-UtmBoundedResultComplete -Result $result)
    $text = (@("$($result.StdOut)`n$($result.StdErr)" -split "`r?`n" | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '; ')
    $result['Text'] = $text
    $result['FailureKind'] = Get-UtmStartFailureKind -Text $text
    if ($result.TimedOut -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utmctl_lifecycle_timeout' -Arguments @{ verb = "$Verb"; vmName = "$VMName"; timeoutSeconds = "$cap" })
    }
    return $result
}

<#
.SYNOPSIS
    The pids of this user's processes that `pgrep` matches, or a reason the
    question could not be answered.
.DESCRIPTION
    Always scoped with -U to the given uid: an unscoped match would reach
    another operator's UTM or QEMU helpers. Exit 1 with no output is a
    positive "none"; any other failure is not evidence of absence.
.OUTPUTS
    [pscustomobject] Reason ('ok' | 'probe-timeout' | 'probe-failed' |
    'deadline-exhausted'), ProcessId [int[]].
#>
function Get-UtmUserProcessId {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Uid,
        [Parameter(Mandatory)][string[]]$Match,
        $Deadline
    )
    $found = Invoke-UtmHostTool -Tool 'pgrep' -ArgumentList (@('-U', $Uid) + $Match) -TimeoutSeconds 10 -Deadline $Deadline
    $reason = 'probe-failed'
    $ids = [System.Collections.Generic.List[int]]::new()
    if ($found.DeadlineExhausted) { $reason = 'deadline-exhausted' }
    elseif ($found.TimedOut) { $reason = 'probe-timeout' }
    elseif (Test-UtmBoundedResultComplete -Result $found) {
        $lines = @("$($found.StdOut)" -split "`r?`n" | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($found.ExitCode -eq 1 -and $lines.Count -eq 0) {
            $reason = 'ok'
        } elseif ($found.ExitCode -eq 0) {
            $reason = 'ok'
            foreach ($line in $lines) {
                $value = 0
                if ([int]::TryParse($line, [ref]$value) -and $value -gt 0) { $ids.Add($value) } else { $reason = 'probe-failed' }
            }
        }
    }
    return [pscustomobject]@{ Reason = $reason; ProcessId = [int[]]$ids.ToArray() }
}

<#
.SYNOPSIS
    Whether UTM and its VM helper processes are running for this user,
    without sending an Apple Event.
.DESCRIPTION
    Two bounded `pgrep -U <uid>` reads: UTM by exact process name, and the
    QEMU helpers by the helper bundle path in their command line. Absence is
    claimed only when both answer "none"; a read that failed or timed out
    makes the state 'unknown', because repeated unknown discovery never
    proves a process stopped. A listed pid is a candidate, not an identity:
    anything that signals one checks its executable first
    (Test-UtmProcessExecutableKind). No
    utmctl call is made: sending an Apple Event to a UTM that is not running
    can launch it.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] State ('running' | 'absent' | 'unknown'), Reason
    ('observed' | 'not-running' | 'uid-unknown' | 'probe-failed' |
    'probe-timeout' | 'deadline-exhausted'), Uid, UtmPid [int[]],
    HelperPid [int[]], ObservedUtc, ElapsedMs. 'running' means at least one
    UTM or helper process exists for this user.
#>
function Get-UtmApplicationState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $emit = {
        param([string]$State, [string]$Reason, $Uid, [int[]]$UtmPid, [int[]]$HelperPid)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmApplicationState'
            State = $State; Reason = $Reason; Uid = $Uid
            UtmPid = [int[]]@($UtmPid); HelperPid = [int[]]@($HelperPid)
            ObservedUtc = $observedUtc; ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        return (& $emit 'unknown' 'deadline-exhausted' $null @() @())
    }
    $uid = Get-UtmCurrentUid -Deadline $Deadline
    if (-not $uid) { return (& $emit 'unknown' 'uid-unknown' $null @() @()) }
    $app = Get-UtmUserProcessId -Uid $uid -Match @('-i', '-x', 'UTM') -Deadline $Deadline
    if ($app.Reason -ne 'ok') { return (& $emit 'unknown' $app.Reason $uid @() @()) }
    $helper = Get-UtmUserProcessId -Uid $uid -Match @('-f', $script:UtmHelperCommandPattern) -Deadline $Deadline
    if ($helper.Reason -ne 'ok') { return (& $emit 'unknown' $helper.Reason $uid $app.ProcessId @()) }
    if ($app.ProcessId.Count -gt 0 -or $helper.ProcessId.Count -gt 0) {
        return (& $emit 'running' 'observed' $uid $app.ProcessId $helper.ProcessId)
    }
    return (& $emit 'absent' 'not-running' $uid @() @())
}

<#
.SYNOPSIS
    Whether this process may stop or start UTM: a GUI (Aqua) session, a
    known non-root uid, and a same-user process census that answered.
.DESCRIPTION
    UTM is a per-user GUI application. From an SSH or background session a
    launch does not reach the operator's desktop, root reaches every user's
    processes, and without a census nothing proves which processes are this
    user's. Each of those refuses rather than guesses.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] Ok, Reason ('ok' | 'no-session' | 'root' | 'uid-unknown'
    | 'census-unknown' | 'deadline-exhausted'), SessionKind, Uid, AppState
    (the Get-UtmApplicationState record, $null when not reached).
#>
function Get-UtmControlPrerequisite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $emit = {
        param([bool]$Ok, [string]$Reason, [string]$SessionKind, $Uid, $AppState)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmControlPrerequisite'
            Ok = $Ok; Reason = $Reason; SessionKind = $SessionKind; Uid = $Uid; AppState = $AppState
        }
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        return (& $emit $false 'deadline-exhausted' 'Unknown' $null $null)
    }
    $session = Get-UtmProbeSessionKind -Deadline $Deadline
    if ($session -ne 'Aqua') { return (& $emit $false 'no-session' $session $null $null) }
    $uid = Get-UtmCurrentUid -Deadline $Deadline
    if (-not $uid) { return (& $emit $false 'uid-unknown' $session $null $null) }
    if ($uid -eq '0') { return (& $emit $false 'root' $session $uid $null) }
    $app = Get-UtmApplicationState -Deadline $Deadline
    if ($app.State -eq 'unknown') {
        $reason = if ($app.Reason -eq 'deadline-exhausted') { 'deadline-exhausted' } else { 'census-unknown' }
        return (& $emit $false $reason $session $uid $app)
    }
    return (& $emit $true 'ok' $session $uid $app)
}

<#
.SYNOPSIS
    Flush this user's preference cache so the next reader sees the plist
    files as they are on disk; $true when the flush ran.
.DESCRIPTION
    `killall cfprefsd` as a regular user reaches only that user's daemon,
    which relaunches on demand. As root it would reach every user's, so root
    is refused. An unknown uid is refused for the same reason.
#>
function Invoke-UtmPreferenceFlush {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Operation,
        $Deadline
    )
    $uid = Get-UtmCurrentUid -Deadline $Deadline
    if (-not $uid) { return $false }
    if ($uid -eq '0') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_flush_skipped_root' -Arguments @{ operation = "$Operation" })
        return $false
    }
    $flush = Invoke-UtmHostTool -Tool 'killall' -ArgumentList @('cfprefsd') -TimeoutSeconds 10 -Deadline $Deadline
    $null = Wait-UtmInterval -Milliseconds $script:UtmPreferenceFlushSettleMilliseconds -Deadline $Deadline
    # Exit 1 means no cfprefsd was running for this user: nothing was cached.
    return [bool]((Test-UtmBoundedResultComplete -Result $flush) -and $flush.ExitCode -in @(0, 1))
}

<#
.SYNOPSIS
    Whether a `ps` command line runs UTM's own executable ('app') or one of
    its QEMU helper executables ('helper').
.DESCRIPTION
    Judged on the executable -- the first token of the command line -- never
    on the arguments, because the census that proposes a pid matches command
    text any same-user process can carry (`tail -f QEMUHelper.log`). UTM is
    an executable named exactly UTM, as UTM.app's own binary is; a helper is
    one inside the QEMUHelper XPC bundle, which also covers the QEMU process
    the helper starts under another name, or one named exactly QEMUHelper.
    An install path containing a space splits the first token and fails the
    check: such a process is left alone, never signaled on a guess.
#>
function Test-UtmProcessExecutableKind {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory)][ValidateSet('app', 'helper')][string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $executable = @($Command.Trim() -split '\s+', 2)[0]
    $name = @($executable -split '/')[-1]
    if ($Kind -eq 'app') { return [bool]($name -ceq 'UTM') }
    return [bool]($name -ceq [string]$script:UtmHelperProcessPattern -or
        $executable.Contains('/QEMUHelper.xpc/', [System.StringComparison]::Ordinal))
}

<#
.SYNOPSIS
    Signal one of this user's processes, TERM then KILL, revalidating its
    identity immediately before each signal.
.DESCRIPTION
    The pid was captured earlier and may have exited and been reused by an
    unrelated process since. Its uid, start time and command line must still
    equal the captured baseline right before every signal, or it is not
    signaled. An identity that cannot be read at all is not signaled either,
    and is reported as unreadable rather than as changed. Emits one record
    per signal decision; Result is 'sent', 'failed', 'skipped-identity' or
    'skipped-unreadable'.
#>
function Stop-UtmOwnedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Baseline,
        [Parameter(Mandatory)][string]$ProcessName,
        $Deadline
    )
    $processId = [int]$Baseline.ProcessId
    if (-not $PSCmdlet.ShouldProcess("$ProcessName ($processId)", (Format-YurunaOperatorMessage -Key 'host.utm_app_signal_action'))) { return }
    foreach ($signal in @('TERM', 'KILL')) {
        $now = Get-UtmProcessIdentity -ProcessId $processId -Deadline $Deadline
        if (-not $now.Found) {
            if ($now.Reason -ne 'not-found') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_identity_unreadable' -Arguments @{ operation = 'Stop-UtmApplication'; processName = "$ProcessName"; processId = "$processId"; reason = "$($now.Reason)" })
                [pscustomobject]@{ ProcessId = $processId; ProcessName = $ProcessName; Signal = $signal; Result = 'skipped-unreadable' }
            }
            return
        }
        if ($now.Uid -ne $Baseline.Uid -or $now.StartText -ne $Baseline.StartText -or $now.Command -ne $Baseline.Command) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_identity_changed' -Arguments @{ processId = "$processId"; processName = "$ProcessName" })
            [pscustomobject]@{ ProcessId = $processId; ProcessName = $ProcessName; Signal = $signal; Result = 'skipped-identity' }
            return
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_hard_stop_signal' -Arguments @{ signal = "$signal"; processName = "$ProcessName"; processId = "$processId" })
        $sent = Invoke-UtmHostTool -Tool 'kill' -ArgumentList @("-$signal", "$processId") -TimeoutSeconds 5 -Deadline $Deadline
        $result = if ((Test-UtmBoundedResultComplete -Result $sent) -and $sent.ExitCode -eq 0) { 'sent' } else { 'failed' }
        [pscustomobject]@{ ProcessId = $processId; ProcessName = $ProcessName; Signal = $signal; Result = $result }
        if ($result -ne 'sent') { return }
        $exitWait = Get-UtmChildDeadline -Milliseconds $script:UtmHardStopWaitMilliseconds -Parent $Deadline
        do {
            $after = Get-UtmProcessIdentity -ProcessId $processId -Deadline $Deadline
            if (-not $after.Found -and $after.Reason -eq 'not-found') { return }
        } while (Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $exitWait)
    }
}

<#
.SYNOPSIS
    Ask UTM to quit and wait, boundedly, until UTM and its VM helpers are
    gone for this user.
.DESCRIPTION
    Quitting UTM is not harmless: UTM saves the state of every running VM on
    the way out, and a VM that was 'started' comes back 'suspended'. Without
    -AllowHardStop this only sends the quit request and waits; UTM or helpers
    that remain are reported as 'partial' and left intact. With
    -AllowHardStop the remaining processes are signaled -- UTM first, the
    QEMU helpers last, TERM then KILL. Before the first signal every one of
    them is read once and must be this user's UTM or helper executable; each
    signal then revalidates uid, start time and command line against that
    reading. Killing a helper powers its guest off uncleanly, so only an
    explicit local caller passes it.

    Every process discovery is scoped to this user. A census that cannot be
    read refuses before the quit is sent.

    -FlushPreferenceCache flushes this user's preference cache once UTM is
    confirmed gone, so edits to UTM's plist files are not shadowed by stale
    daemon state; it is skipped as root.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER QuitWaitSeconds
    How long to wait for UTM and its helpers to exit after the quit request.
.PARAMETER AllowHardStop
    Signal what remains after the wait. Local, explicit callers only.
.PARAMETER FlushPreferenceCache
    Flush the preference cache after a confirmed stop.
.OUTPUTS
    [pscustomobject] Stopped, Outcome ('already-stopped' | 'quit' |
    'hard-stopped' | 'partial' | 'refused' | 'deadline-exhausted' |
    'preview'), Reason, QuitSent, Signal [object[]] {ProcessId; ProcessName;
    Signal; Result}, RemainingUtmPid [int[]], RemainingHelperPid [int[]],
    HelperPidBefore [int[]], PreferenceCacheFlushed, ElapsedMs.
#>
function Stop-UtmApplication {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        $Deadline,
        [ValidateRange(1, 600)][int]$QuitWaitSeconds = 30,
        [switch]$AllowHardStop,
        [switch]$FlushPreferenceCache
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $signals = [System.Collections.Generic.List[object]]::new()
    $finish = {
        param([bool]$Stopped, [string]$Outcome, [string]$Reason, [bool]$QuitSent, [int[]]$RemainingUtm, [int[]]$RemainingHelper, [int[]]$HelperBefore, [bool]$Flushed)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmStopResult'
            Stopped = $Stopped; Outcome = $Outcome; Reason = $Reason; QuitSent = $QuitSent
            Signal = [object[]]$signals.ToArray()
            RemainingUtmPid = [int[]]@($RemainingUtm); RemainingHelperPid = [int[]]@($RemainingHelper)
            HelperPidBefore = [int[]]@($HelperBefore); PreferenceCacheFlushed = $Flushed
            ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    if (-not $PSCmdlet.ShouldProcess('UTM', (Format-YurunaOperatorMessage -Key 'host.utm_app_quit_action'))) {
        return (& $finish $false 'preview' 'preview' $false @() @() @() $false)
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false @() @() @() $false)
    }
    $before = Get-UtmApplicationState -Deadline $Deadline
    if ($before.State -eq 'unknown') {
        if ($before.Reason -eq 'deadline-exhausted') {
            return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false @() @() @() $false)
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_census_unknown' -Arguments @{ operation = 'Stop-UtmApplication'; reason = "$($before.Reason)" })
        return (& $finish $false 'refused' 'census-unknown' $false @() @() @() $false)
    }
    $helperBefore = [int[]]@($before.HelperPid)
    if ($before.State -eq 'absent') {
        $flushed = if ($FlushPreferenceCache) { Invoke-UtmPreferenceFlush -Operation 'Stop-UtmApplication' -Deadline $Deadline } else { $false }
        return (& $finish $true 'already-stopped' 'already-stopped' $false @() @() $helperBefore $flushed)
    }

    $quit = Invoke-UtmHostTool -Tool 'osascript' -ArgumentList @('-e', 'tell application "UTM" to quit') -TimeoutSeconds $QuitWaitSeconds -Deadline $Deadline
    # The wait for UTM to exit starts once the quit request has returned.
    $wait = Get-UtmChildDeadline -Milliseconds ([long]$QuitWaitSeconds * 1000) -Parent $Deadline
    if ($quit.DeadlineExhausted) {
        return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false $before.UtmPid $before.HelperPid $helperBefore $false)
    }
    if (-not $quit.Started) {
        return (& $finish $false 'refused' 'quit-not-sent' $false $before.UtmPid $before.HelperPid $helperBefore $false)
    }
    # The quit wait only paces the census; each read is bounded by the caller's
    # deadline (or its own cap), and a read that deadline had no time for
    # never replaces the last real census.
    $current = $before
    do {
        $next = Get-UtmApplicationState -Deadline $Deadline
        if ($next.Reason -ne 'deadline-exhausted') { $current = $next }
        if ($current.State -eq 'absent') { break }
    } while (Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $wait)

    if ($current.State -ne 'absent' -and $AllowHardStop) {
        # See https://yuruna.link/42e220c4-0004
        $uid = Get-UtmCurrentUid -Deadline $Deadline
        $candidates = @(
            foreach ($id in @($current.UtmPid))    { [pscustomobject]@{ ProcessId = [int]$id; ProcessName = 'UTM'; Kind = 'app' } }
            foreach ($id in @($current.HelperPid)) { [pscustomobject]@{ ProcessId = [int]$id; ProcessName = $script:UtmHelperProcessPattern; Kind = 'helper' } }
        )
        $targets = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $candidates) {
            $baseline = Get-UtmProcessIdentity -ProcessId $candidate.ProcessId -Deadline $Deadline
            $skip = ''
            if (-not $baseline.Found) {
                if ($baseline.Reason -eq 'not-found') { continue }
                $skip = 'skipped-unreadable'
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_identity_unreadable' -Arguments @{ operation = 'Stop-UtmApplication'; processName = "$($candidate.ProcessName)"; processId = "$($candidate.ProcessId)"; reason = "$($baseline.Reason)" })
            } elseif (-not $uid -or $baseline.Uid -ne $uid) {
                $skip = 'skipped-identity'
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_identity_changed' -Arguments @{ processId = "$($candidate.ProcessId)"; processName = "$($candidate.ProcessName)" })
            } elseif (-not (Test-UtmProcessExecutableKind -Command $baseline.Command -Kind $candidate.Kind)) {
                $skip = 'skipped-identity'
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_executable_mismatch' -Arguments @{ processId = "$($candidate.ProcessId)"; processName = "$($candidate.ProcessName)" })
            }
            if ($skip) {
                $signals.Add([pscustomobject]@{ ProcessId = $candidate.ProcessId; ProcessName = $candidate.ProcessName; Signal = 'TERM'; Result = $skip })
                continue
            }
            $targets.Add([pscustomobject]@{ Baseline = $baseline; ProcessName = $candidate.ProcessName })
        }
        foreach ($target in $targets) {
            foreach ($decision in @(Stop-UtmOwnedProcess -Baseline $target.Baseline -ProcessName $target.ProcessName -Deadline $Deadline -Confirm:$false)) {
                $signals.Add($decision)
            }
        }
        $final = Get-UtmApplicationState -Deadline $Deadline
        if ($final.Reason -ne 'deadline-exhausted') { $current = $final }
    }

    $sentAny = @($signals | Where-Object { $_.Result -eq 'sent' }).Count -gt 0
    if ($current.State -eq 'absent') {
        $flushed = if ($FlushPreferenceCache) { Invoke-UtmPreferenceFlush -Operation 'Stop-UtmApplication' -Deadline $Deadline } else { $false }
        $outcome = if ($sentAny) { 'hard-stopped' } else { 'quit' }
        $reason  = if ($sentAny) { 'hard-stop-confirmed' } else { 'quit-confirmed' }
        return (& $finish $true $outcome $reason $true @() @() $helperBefore $flushed)
    }
    $utmLeft = [int[]]@($current.UtmPid)
    $helperLeft = [int[]]@($current.HelperPid)
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_quit_not_confirmed' -Arguments @{ waitSeconds = "$QuitWaitSeconds"; utmCount = "$($utmLeft.Count)"; helperCount = "$($helperLeft.Count)" })
    $reason = if ($current.State -eq 'unknown') { 'census-unknown' } else { 'processes-remain' }
    return (& $finish $false 'partial' $reason $true $utmLeft $helperLeft $helperBefore $false)
}

<#
.SYNOPSIS
    Launch UTM for this user with `open -a UTM` and confirm, boundedly, that
    a UTM process appeared.
.DESCRIPTION
    A UTM already running for this user is left alone ('already-running').
    UTM helpers without UTM are refused: relaunching UTM next to orphaned
    guests is not a state this driver has a tested answer for.

    The launch is detached -- `open` hands UTM to LaunchServices and returns
    -- so only its acknowledgment is bounded and nothing it started is ever
    killed. Started means the launch was acknowledged AND UTM was then
    observed for this user; a launch that was not acknowledged, or after
    which no UTM appeared, is 'not-observed' and its effect is unknown.

    -RequireGuiSession enforces Get-UtmControlPrerequisite first: a launch
    from an SSH or background session, as root, or without a same-user
    census is refused and `open` is not run.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER LaunchWaitSeconds
    How long to wait for UTM to appear after the launch.
.PARAMETER FlushPreferenceCache
    Flush this user's preference cache before launching; skipped, with a
    warning, when the census could not say whether UTM is running.
.PARAMETER RequireGuiSession
    Refuse unless the control prerequisites hold.
.OUTPUTS
    [pscustomobject] Started, Outcome ('already-running' | 'launched' |
    'launch-failed' | 'not-observed' | 'refused' | 'deadline-exhausted' |
    'preview'), Reason, Acknowledged, LaunchExitCode, UtmPid [int[]],
    PreferenceCacheFlushed, ElapsedMs.
#>
function Start-UtmApplication {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        $Deadline,
        [ValidateRange(1, 600)][int]$LaunchWaitSeconds = 30,
        [switch]$FlushPreferenceCache,
        [switch]$RequireGuiSession
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $finish = {
        param([bool]$Started, [string]$Outcome, [string]$Reason, [bool]$Acknowledged, $ExitCode, [int[]]$UtmPid, [bool]$Flushed)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmStartResult'
            Started = $Started; Outcome = $Outcome; Reason = $Reason; Acknowledged = $Acknowledged
            LaunchExitCode = $ExitCode; UtmPid = [int[]]@($UtmPid); PreferenceCacheFlushed = $Flushed
            ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    if (-not $PSCmdlet.ShouldProcess('UTM', (Format-YurunaOperatorMessage -Key 'host.utm_app_launch_action'))) {
        return (& $finish $false 'preview' 'preview' $false $null @() $false)
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false $null @() $false)
    }
    if ($RequireGuiSession) {
        $prerequisite = Get-UtmControlPrerequisite -Deadline $Deadline
        if (-not $prerequisite.Ok) {
            if ($prerequisite.Reason -eq 'deadline-exhausted') {
                return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false $null @() $false)
            }
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_control_refused' -Arguments @{ operation = 'Start-UtmApplication'; reason = "$($prerequisite.Reason)" })
            return (& $finish $false 'refused' $prerequisite.Reason $false $null @() $false)
        }
        $before = $prerequisite.AppState
    } else {
        $before = Get-UtmApplicationState -Deadline $Deadline
    }
    if (@($before.UtmPid).Count -gt 0) {
        return (& $finish $true 'already-running' 'already-running' $false $null $before.UtmPid $false)
    }
    if (@($before.HelperPid).Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_control_refused' -Arguments @{ operation = 'Start-UtmApplication'; reason = 'helpers-without-app' })
        return (& $finish $false 'refused' 'helpers-without-app' $false $null @() $false)
    }
    # An unknown census has no pids in it, which is not the same as nothing
    # running. The launch itself is harmless next to a running UTM; the flush
    # is not, because a running UTM writes its in-memory preferences back
    # over the edits the flush was meant to expose.
    $flushed = $false
    if ($FlushPreferenceCache) {
        if ($before.State -eq 'unknown') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_flush_skipped_census' -Arguments @{ operation = 'Start-UtmApplication'; reason = "$($before.Reason)" })
        } else {
            $flushed = Invoke-UtmPreferenceFlush -Operation 'Start-UtmApplication' -Deadline $Deadline
        }
    }
    $ackSeconds = 10
    if ($Deadline) {
        $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 10
        if ($null -eq $bounded) { return (& $finish $false 'deadline-exhausted' 'deadline-exhausted' $false $null @() $flushed) }
        $ackSeconds = [int]$bounded
    }
    $launch = Start-UtmDetachedLaunch -Tool 'open' -ArgumentList @('-a', 'UTM') -AcknowledgeSeconds $ackSeconds -Confirm:$false
    if (-not $launch.Started) {
        return (& $finish $false 'launch-failed' 'launcher-missing' $false $null @() $flushed)
    }
    if ($launch.Acknowledged -and $launch.ExitCode -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_launch_refused' -Arguments @{ exitCode = "$($launch.ExitCode)"; detail = "$(ConvertTo-UtmDiagnosticText -Text "$($launch.StdOut) $($launch.StdErr)")" })
        return (& $finish $false 'launch-failed' 'launch-refused' $true $launch.ExitCode @() $flushed)
    }
    $wait = Get-UtmChildDeadline -Milliseconds ([long]$LaunchWaitSeconds * 1000) -Parent $Deadline
    $after = $before
    do {
        $next = Get-UtmApplicationState -Deadline $Deadline
        if ($next.Reason -ne 'deadline-exhausted') { $after = $next }
        if (@($after.UtmPid).Count -gt 0) { break }
    } while (Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $wait)
    $observed = @($after.UtmPid).Count -gt 0
    if ($observed -and $launch.Acknowledged) {
        return (& $finish $true 'launched' 'launched' $true $launch.ExitCode $after.UtmPid $flushed)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_launch_not_observed' -Arguments @{ waitSeconds = "$LaunchWaitSeconds"; acknowledged = "$($launch.Acknowledged)"; exitCode = "$($launch.ExitCode)" })
    $reason = if (-not $launch.Acknowledged) { 'launch-unacknowledged' } else { 'not-observed' }
    return (& $finish $false 'not-observed' $reason $launch.Acknowledged $launch.ExitCode $after.UtmPid $flushed)
}

<#
.SYNOPSIS
    Quit and relaunch UTM, only on fresh, corroborated evidence that its
    control channel is hung.
.DESCRIPTION
    Restarting UTM suspends every running guest (or, with -AllowHardStop,
    powers helpers off), so it is permitted only by a probe record that is
    Unresponsive/timeout, corroborated, and observed within the last two
    minutes. Anything else -- a denial, a missing session, an uncorroborated
    timeout, stale evidence -- refuses before anything is touched.

    The control prerequisites are checked again immediately before acting.
    The stop keeps a reserve for the relaunch, and the relaunch runs only
    after the stop is confirmed; a stop that did not complete leaves UTM and
    its helpers as they are and reports 'partial'. Preferences are never
    flushed and guests are never resumed here: restoring them belongs to the
    caller's convergence step. HelperPidBefore is the only collateral this
    function can state as fact; it never reports an invented guest list.
.PARAMETER Evidence
    A Test-VirtualizationResponsive record.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER QuitWaitSeconds
    Passed to Stop-UtmApplication.
.PARAMETER LaunchWaitSeconds
    Passed to Start-UtmApplication.
.PARAMETER AllowHardStop
    Passed to Stop-UtmApplication; local, explicit callers only.
.OUTPUTS
    [pscustomobject] Outcome ('restarted' | 'partial' | 'refused' |
    'deadline-exhausted' | 'preview'), Reason, Prerequisite, Stop, Start,
    HardStopUsed, HelperPidBefore [int[]], ElapsedMs.
#>
function Restart-UtmApplication {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Evidence,
        $Deadline,
        [ValidateRange(1, 600)][int]$QuitWaitSeconds = 60,
        [ValidateRange(1, 600)][int]$LaunchWaitSeconds = 60,
        [switch]$AllowHardStop
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $finish = {
        param([string]$Outcome, [string]$Reason, $Prerequisite, $Stop, $Start, [int[]]$HelperBefore)
        $hardStop = $false
        if ($Stop) { $hardStop = @($Stop.Signal | Where-Object { $_.Result -eq 'sent' }).Count -gt 0 }
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmRestartResult'
            Outcome = $Outcome; Reason = $Reason; Prerequisite = $Prerequisite; Stop = $Stop; Start = $Start
            HardStopUsed = $hardStop; HelperPidBefore = [int[]]@($HelperBefore); ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    $state = "$($Evidence.state)"
    $evidenceReason = "$($Evidence.reason)"
    $ageMs = [long]::MaxValue
    if ($null -ne $Evidence -and $null -ne $Evidence.observedTick) {
        $ageMs = [long](Get-UtmClockTick -Deadline $Deadline) - [long]$Evidence.observedTick
    }
    $qualifies = ($state -eq 'Unresponsive') -and ($evidenceReason -eq 'timeout') -and [bool]$Evidence.corroborated -and
        ($ageMs -ge 0) -and ($ageMs -le $script:UtmRestartEvidenceMaxAgeMs)
    if (-not $qualifies) {
        $ageText = if ($ageMs -eq [long]::MaxValue) { 'unknown' } else { "$ageMs" }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_restart_evidence_refused' -Arguments @{ state = "$state"; reason = "$evidenceReason"; ageMs = "$ageText"; maxAgeSeconds = "$([int]($script:UtmRestartEvidenceMaxAgeMs / 1000))" })
        return (& $finish 'refused' 'evidence-refused' $null $null $null @())
    }
    if (-not $PSCmdlet.ShouldProcess('UTM', (Format-YurunaOperatorMessage -Key 'host.utm_app_restart_action'))) {
        return (& $finish 'preview' 'preview' $null $null $null @())
    }
    # The relaunch needs its own time after the stop; reserve it up front so a
    # stop that uses its whole budget cannot leave UTM down with nothing left
    # to bring it back.
    $launchReserveMs = [long]([Math]::Min($LaunchWaitSeconds, 30) + 15) * 1000
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt ($launchReserveMs + 2000)) {
        return (& $finish 'deadline-exhausted' 'deadline-exhausted' $null $null $null @())
    }
    $prerequisite = Get-UtmControlPrerequisite -Deadline $Deadline
    if (-not $prerequisite.Ok) {
        if ($prerequisite.Reason -eq 'deadline-exhausted') {
            return (& $finish 'deadline-exhausted' 'deadline-exhausted' $prerequisite $null $null @())
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_app_control_refused' -Arguments @{ operation = 'Restart-UtmApplication'; reason = "$($prerequisite.Reason)" })
        return (& $finish 'refused' $prerequisite.Reason $prerequisite $null $null @())
    }
    $helperBefore = [int[]]@($prerequisite.AppState.HelperPid)
    $stopDeadline = if ($Deadline) {
        Get-UtmChildDeadline -Milliseconds ([long]$QuitWaitSeconds * 1000 + 60000) -Parent $Deadline -ReserveMilliseconds $launchReserveMs
    } else { $null }
    $stop = Stop-UtmApplication -Deadline $stopDeadline -QuitWaitSeconds $QuitWaitSeconds -AllowHardStop:$AllowHardStop -Confirm:$false
    if (-not $stop.Stopped) {
        $outcome = switch ($stop.Outcome) { 'deadline-exhausted' { 'deadline-exhausted' } 'refused' { 'refused' } default { 'partial' } }
        return (& $finish $outcome "stop-$($stop.Outcome)" $prerequisite $stop $null $helperBefore)
    }
    $start = Start-UtmApplication -Deadline $Deadline -LaunchWaitSeconds $LaunchWaitSeconds -RequireGuiSession -Confirm:$false
    if ($start.Started) {
        return (& $finish 'restarted' 'restarted' $prerequisite $stop $start $helperBefore)
    }
    return (& $finish 'partial' "start-$($start.Outcome)" $prerequisite $stop $start $helperBefore)
}

<#
.SYNOPSIS
    The current tick on the deadline's clock, or on the process clock when
    there is no deadline.
#>
function Get-UtmClockTick {
    [CmdletBinding()]
    [OutputType([long])]
    param($Deadline)
    if ($Deadline -and $Deadline.ClockTicks) { return [long](& $Deadline.ClockTicks) }
    return [long][Environment]::TickCount64
}

<#
.SYNOPSIS
    Where host-side evidence for the running cycle belongs, or $null when no
    cycle is running.
.DESCRIPTION
    An explicit directory wins. Otherwise the cycle folder is read from the
    YURUNA_CYCLE_CONTEXT handle the framework publishes to the child processes
    of a host action, then from the runner's own cycle-folder handle, then the
    shared log root. A directory that is named but no longer on disk is
    skipped: the cycle is over, and writing it back would recreate a folder
    nothing collects.
#>
function Get-UtmEvidenceDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_CYCLE_CONTEXT)) {
        try {
            $context = $env:YURUNA_CYCLE_CONTEXT | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $root = if ($context -is [System.Collections.IDictionary]) { [string]$context['rootCycleFolder'] } else { '' }
            if ($root -and (Test-Path -LiteralPath $root -PathType Container)) { return $root }
        } catch {
            Write-Verbose "Get-UtmEvidenceDirectory: unreadable cycle context: $($_.Exception.Message)"
        }
    }
    $folder = Get-Variable -Name '__YurunaCycleFolder' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($folder -and (Test-Path -LiteralPath ([string]$folder) -PathType Container)) { return [string]$folder }
    if ($env:YURUNA_LOG_DIR -and (Test-Path -LiteralPath $env:YURUNA_LOG_DIR -PathType Container)) { return $env:YURUNA_LOG_DIR }
    return $null
}

<#
.SYNOPSIS
    Record what UTM's control channel looked like at the moment a request
    went unanswered, in the cycle folder, for the reader who was not there.
.DESCRIPTION
    A lifecycle verb that UTM did not act on leaves nothing behind: the
    transcript shows the OSStatus text, and the state of UTM.app itself --
    whether it crashed and relaunched, which helper processes survived, what
    the unified log said in the minutes before -- is gone by the time anyone
    reads the failure. This writes that evidence while it still exists:

      - the same-user UTM and QEMU helper census, each pid with its start
        time and command line (a UTM pid or start time that differs from the
        one the cycle began with is a crash-and-relaunch);
      - one bounded `utmctl list`, raw, so the query path's answer is on
        record beside the verb that hung;
      - the crash reports under ~/Library/Logs/DiagnosticReports written in
        the window, named and copied (the newest few, size-capped);
      - a bounded `log show` excerpt for the UTM, QEMUHelper and utmctl
        processes over the window;
      - with -VMName, a screenshot of that VM's display, for a guest that was
        started but never reported;
      - with -VMName and a bundle that carries the console devices, the QEMU
        monitor's answers to info status, info cpus and info registers -a
        (qemu-monitor.<trigger>.txt, Save-UtmQemuMonitorCapture) and the
        newest part of the guest's serial console log
        (serial-console.<trigger>.log, Save-UtmSerialConsoleTail). Both are
        read right after the census: they describe the guest, they are gone
        once the VM restarts, and the slower UTM readings after them could
        otherwise spend the shared deadline first.

    Every read is bounded and every failure is recorded in the snapshot
    rather than thrown; with no cycle folder to write into nothing is
    written and the result says so. The files are named after -Trigger so a
    second capture in the same cycle for a different reason does not replace
    the first.
.PARAMETER OutputDirectory
    Where to write. Default: the running cycle's folder (Get-UtmEvidenceDirectory).
.PARAMETER Trigger
    A short token naming why the snapshot was taken; part of the file names.
.PARAMETER VMName
    The VM the failed request concerned, for the screenshot and the guest's
    monitor and serial console readings.
.PARAMETER LogWindowMinutes
    How far back the unified-log excerpt and the crash-report scan reach.
.PARAMETER LogTimeoutSeconds
    Cap for the `log show` call, which can be slow on a loaded host.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER SkipScreenshot
    Omit the screenshot for automatic startup evidence collection. The screenshot
    contract does not consume the shared deadline; retained failure frames remain
    available while the native control probes stay within their bounded budget.
.OUTPUTS
    [pscustomobject] Written, Reason, Directory, Path, Record.
#>
function Save-UtmControlSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$OutputDirectory,
        [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,63}$')][string]$Trigger = 'operator',
        [AllowEmptyString()][string]$VMName = '',
        [ValidateRange(1, 1440)][int]$LogWindowMinutes = 30,
        [ValidateRange(1, 600)][int]$LogTimeoutSeconds = 60,
        $Deadline,
        [switch]$SkipScreenshot
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ Written = $false; Reason = ''; Directory = ''; Path = ''; Record = $null }
    $directory = Get-UtmEvidenceDirectory -Explicit $OutputDirectory
    if (-not $directory) {
        $result.Reason = 'no-output-directory'
        return [pscustomobject]$result
    }
    $result.Directory = $directory
    if (-not $PSCmdlet.ShouldProcess($directory, (Format-YurunaOperatorMessage -Key 'host.utm_control_snapshot_action' -Arguments @{ trigger = "$Trigger" }))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $record = [ordered]@{
        schema           = 'yuruna.utm-control-snapshot/v1'
        observedUtc      = [DateTime]::UtcNow.ToString('o')
        trigger          = $Trigger
        vmName           = $VMName
        sessionKind      = 'Unknown'
        application      = $null
        processes        = @()
        listing          = $null
        crashReports     = @()
        unifiedLog       = $null
        screenshot       = $null
        qemuMonitor      = $null
        serialConsole    = $null
        problems         = @()
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    $cap = {
        param([string]$Text, [int]$Length)
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        if ($Text.Length -le $Length) { return $Text }
        return $Text.Substring(0, $Length)
    }
    try {
        try { $record.sessionKind = [string](Get-UtmProbeSessionKind -Deadline $Deadline) } catch { $problems.Add("session: $($_.Exception.Message)") }
        $app = $null
        try {
            $app = Get-UtmApplicationState -Deadline $Deadline
            $record.application = [ordered]@{
                state = [string]$app.State; reason = [string]$app.Reason; uid = [string]$app.Uid
                utmPid = [int[]]@($app.UtmPid); helperPid = [int[]]@($app.HelperPid); observedUtc = [string]$app.ObservedUtc
            }
        } catch { $problems.Add("census: $($_.Exception.Message)") }
        $processes = [System.Collections.Generic.List[object]]::new()
        if ($app) {
            foreach ($processId in @(@($app.UtmPid) + @($app.HelperPid) | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
                try {
                    $identity = Get-UtmProcessIdentity -ProcessId $processId -Deadline $Deadline
                    $processes.Add([ordered]@{
                        pid = [int]$processId; found = [bool]$identity.Found; reason = [string]$identity.Reason
                        startText = [string]$identity.StartText; command = (& $cap ([string]$identity.Command) 400)
                    })
                } catch { $problems.Add("process ${processId}: $($_.Exception.Message)") }
            }
        }
        $record.processes = @($processes)
        if (-not [string]::IsNullOrWhiteSpace($VMName)) {
            try {
                $console = Get-UtmConsolePortFromBundle -VMName $VMName -Deadline $Deadline
                $record.qemuMonitor = Save-UtmQemuMonitorCapture -VMName $VMName -Port $console.Monitor -OutputDirectory $directory -Trigger $Trigger -Deadline $Deadline
                if ($record.qemuMonitor.outcome -eq 'failed') { $problems.Add("qemu monitor: $($record.qemuMonitor.reason)") }
            } catch { $problems.Add("qemu monitor: $($_.Exception.Message)") }
            try {
                $record.serialConsole = Save-UtmSerialConsoleTail -VMName $VMName -OutputDirectory $directory -Trigger $Trigger
                if ($record.serialConsole.outcome -eq 'failed') { $problems.Add("serial console: $($record.serialConsole.reason)") }
            } catch { $problems.Add("serial console: $($_.Exception.Message)") }
        }
        try {
            $listing = Invoke-UtmctlProbe -Arguments @('list') -TimeoutSeconds 20 -Deadline $Deadline -Quiet
            $record.listing = [ordered]@{
                started = [bool]$listing['Started']; exitCode = [int]$listing['ExitCode']; timedOut = [bool]$listing['TimedOut']
                outputTruncated = [bool]$listing['OutputTruncated']; elapsedMs = [long]$listing['ElapsedMs']
                text = (& $cap "$($listing['StdOut'])`n$($listing['StdErr'])".Trim() 8192)
            }
        } catch { $problems.Add("listing: $($_.Exception.Message)") }
        # Crash reports: named always, copied while small, so the snapshot
        # stays a few files and the originals remain where macOS put them.
        $since = [DateTime]::UtcNow.AddMinutes(-$LogWindowMinutes)
        $reportDir = Join-Path $HOME 'Library/Logs/DiagnosticReports'
        $reports = [System.Collections.Generic.List[object]]::new()
        try {
            if (Test-Path -LiteralPath $reportDir -PathType Container) {
                $copied = 0
                $files = @(Get-ChildItem -LiteralPath $reportDir -File -ErrorAction Stop |
                    Where-Object { $_.Name -match '^(UTM|QEMUHelper|qemu)' -and $_.LastWriteTimeUtc -ge $since } |
                    Sort-Object LastWriteTimeUtc -Descending)
                foreach ($file in $files) {
                    $entry = [ordered]@{ name = $file.Name; sizeBytes = [long]$file.Length; modifiedUtc = $file.LastWriteTimeUtc.ToString('o'); copied = $false }
                    if ($copied -lt 3 -and $file.Length -le 2MB) {
                        try {
                            $copyDir = Join-Path $directory "utm-crash-reports.$Trigger"
                            if (-not (Test-Path -LiteralPath $copyDir)) { $null = New-Item -ItemType Directory -Force -Path $copyDir }
                            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $copyDir $file.Name) -Force -ErrorAction Stop
                            $entry.copied = $true
                            $copied++
                        } catch { $problems.Add("crash report $($file.Name): $($_.Exception.Message)") }
                    }
                    $reports.Add($entry)
                }
            }
        } catch { $problems.Add("crash reports: $($_.Exception.Message)") }
        $record.crashReports = @($reports)
        try {
            $predicate = 'process == "UTM" OR process == "QEMUHelper" OR process == "utmctl"'
            $show = Invoke-UtmHostTool -Tool 'log' -ArgumentList @('show', '--last', "${LogWindowMinutes}m", '--style', 'compact', '--predicate', $predicate) `
                -TimeoutSeconds $LogTimeoutSeconds -Deadline $Deadline
            $logText = [string]$show['StdOut']
            $logPath = Join-Path $directory "utm-log-show.$Trigger.txt"
            if ($show['Started'] -and -not [string]::IsNullOrWhiteSpace($logText)) {
                [System.IO.File]::WriteAllText($logPath, $logText, [System.Text.UTF8Encoding]::new($false))
            } else { $logPath = '' }
            $record.unifiedLog = [ordered]@{
                started = [bool]$show['Started']; exitCode = [int]$show['ExitCode']; timedOut = [bool]$show['TimedOut']
                outputTruncated = [bool]$show['OutputTruncated']; deadlineExhausted = [bool]$show['DeadlineExhausted']
                lines = @($logText -split "`r?`n" | Where-Object { $_ }).Count; path = $logPath
                stderr = (& $cap ([string]$show['StdErr']).Trim() 1024)
            }
        } catch { $problems.Add("unified log: $($_.Exception.Message)") }
        if (-not [string]::IsNullOrWhiteSpace($VMName)) {
            $shotPath = Join-Path $directory "utm-control-snapshot.$Trigger.$VMName.png"
            $shot = [ordered]@{ vmName = $VMName; path = ''; outcome = 'not-attempted' }
            if ($SkipScreenshot) {
                $shot.outcome = 'skipped'
            } else {
                try {
                    $null = Get-VMScreenshot -VMName $VMName -OutFile $shotPath -ErrorAction Stop
                    if (Test-Path -LiteralPath $shotPath -PathType Leaf) { $shot.path = $shotPath; $shot.outcome = 'captured' } else { $shot.outcome = 'not-captured' }
                } catch { $shot.outcome = 'failed'; $problems.Add("screenshot: $($_.Exception.Message)") }
            }
            $record.screenshot = $shot
        }
    } catch {
        $problems.Add("snapshot: $($_.Exception.Message)")
    }
    $record.problems = @($problems)
    $record['elapsedMs'] = [long]$stopwatch.ElapsedMilliseconds
    $result.Record = [pscustomobject]$record
    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $directory }
        $path = Join-Path $directory "utm-control-snapshot.$Trigger.json"
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $record -Depth 8), [System.Text.UTF8Encoding]::new($false))
        $result.Path = $path
        $result.Written = $true
        $result.Reason = 'written'
    } catch {
        $result.Reason = "write-failed: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}
