<#PSScriptInfo
.VERSION 2026.11.05
.GUID 423554c6-d34a-4bb8-a631-4fae2bad86da
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver utm helpers
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

# --- REGION: macOS/UTM host helpers
# --- REGION: Remove-UtmBundleWithRetry
function Remove-UtmBundleWithRetry {
    <#
    .SYNOPSIS
        Removes a UTM .utm bundle from disk with retry-on-EACCES.

    .DESCRIPTION
        After `utmctl delete`, UTM.app (and its QEMUHelper.xpc) can hold file
        handles on bundle contents for a few seconds -- most commonly on the
        mmap'd sparse disk.img or on efi_vars.fd. A single-shot
        `Remove-Item -Recurse -Force` during that window fails with "Access
        to the path '...' is denied" even though the bundle is deregistered
        and would remove cleanly moments later.

        Retries with 2,4,6,8s backoff (~20s total), absorbing the handle-
        release race. Returns $true on success (or if the bundle was already
        gone), $false if all retries fail.

    .PARAMETER Path
        Filesystem path of the .utm bundle directory to remove.

    .PARAMETER MaxAttempts
        Number of removal attempts before giving up (default 5).

    .OUTPUTS
        [bool] $true on success, $false on persistent failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 5
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'host.operator_458ed1226109f7ab' -Arguments @{ maxAttempts = "$MaxAttempts" }))) {
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if ($attempt -gt 1) {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_433ccfae8929f757' -Arguments @{ attempt = "$attempt"; path = "$Path" }) -InformationAction Continue
            }
            return $true
        } catch {
            if ($attempt -ge $MaxAttempts) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_09ab019cee710514' -Arguments @{ path = "$Path"; maxAttempts = "$MaxAttempts"; message = "$($_.Exception.Message)" })
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5320270963cb858b')
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_521642cda75605a9')
                Write-Warning "    lsof +D '$Path'"
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3d7dd16f8eeb04cc')
                return $false
            }
            $sleepSeconds = 2 * $attempt
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bd1b3169db53710a' -Arguments @{ attempt = "$attempt"; maxAttempts = "$MaxAttempts"; path = "$Path"; message = "$($_.Exception.Message)"; sleepSeconds = "${sleepSeconds}" })
            Start-Sleep -Seconds $sleepSeconds
        }
    }
    return $false
}

<#
.SYNOPSIS
    Compiles, self-signs, and runs an embedded Swift helper that uses the
    Virtualization framework.

.DESCRIPTION
    The Virtualization framework's restore-image and installer APIs
    (VZMacOSRestoreImage.fetchLatestSupported, VZMacOSRestoreImage.load,
    VZMacOSInstaller.install) only connect to the system installation
    service when the calling binary carries the
    `com.apple.security.virtualization` entitlement.

    Running a helper via the `swift <file>` interpreter produces an
    ad-hoc-signed binary with NO entitlements, so every one of those
    calls fails with VZErrorDomain "Unable to connect to installation
    service" (code 10004 for load, 10001 for the catalog fetch).

    This helper does the entitled equivalent:
      1. writes $Source to a real `.swift` file (swiftc keys off the
         extension; New-TemporaryFile's `.tmp` would be rejected),
      2. compiles it with `swiftc`,
      3. self-signs the executable with an entitlements plist granting
         `com.apple.security.virtualization` (ad-hoc `-` identity -- the
         entitlement needs no provisioning profile on macOS),
      4. runs it with $ArgumentList, merging stderr into stdout the same
         way `& swift ... 2>&1` did.

    Each merged output line is surfaced live as the helper produces it
    (the pipeline streams object-by-object) AND collected into the return
    value. By default a line is echoed via
    Write-Information -InformationAction Continue; pass -LineHandler to
    intercept instead -- e.g. New-VM.ps1 routes the 15-25 min restore's
    "Restore progress: N%" lines into a Write-Progress bar.

    On compile or codesign failure the diagnostic text is returned and
    $LASTEXITCODE is left non-zero (set by swiftc/codesign), so callers
    keep the existing `if ($LASTEXITCODE -ne 0)` pattern unchanged. On
    success $LASTEXITCODE reflects the helper binary's own exit code.

.PARAMETER Source
    Swift source text to compile and run.

.PARAMETER ArgumentList
    Arguments passed to the compiled helper binary.

.PARAMETER LineHandler
    Optional scriptblock invoked once per merged output line, with the
    line (a string) as its single argument. When supplied it replaces the
    default Write-Information echo; the line is still added to the return
    value either way.
#>
function Invoke-EntitledSwift {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string[]]$ArgumentList = @(),
        [scriptblock]$LineHandler
    )

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-vzswift-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $srcFile = Join-Path $tmpDir 'helper.swift'
        $exeFile = Join-Path $tmpDir 'helper'
        $entFile = Join-Path $tmpDir 'vz.entitlements'
        Set-Content -LiteralPath $srcFile -Value $Source

        $compileOut = & swiftc $srcFile -o $exeFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @('swiftc compile failed:') + $compileOut
        }

        Set-Content -LiteralPath $entFile -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
'@

        $signOut = & codesign --force --sign - --entitlements $entFile $exeFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @('codesign (com.apple.security.virtualization) failed:') + $signOut
        }

        # Surface each line as the helper produces it (the pipeline streams
        # object-by-object) and also emit it as the function's return
        # value. -LineHandler, when given, takes over the live display.
        return (& $exeFile @ArgumentList 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($LineHandler) { & $LineHandler $line }
            else { Write-Information $line -InformationAction Continue }
            $line
        })
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Helper tools this driver runs, under the spelling each call site has always
# used: a bare name resolves on PATH, an absolute path pins the system copy.
# One table so every call reaches the bounded runner the same way, and so a
# test can point an entry at a stand-in executable.
$script:UtmHostTool = @{
    'arp'        = '/usr/sbin/arp'
    'dscl'       = '/usr/bin/dscl'
    'id'         = '/usr/bin/id'
    'ifconfig'   = '/sbin/ifconfig'
    'kill'       = '/bin/kill'
    'killall'    = 'killall'
    'launchctl'  = 'launchctl'
    'log'        = '/usr/bin/log'
    'open'       = 'open'
    'osascript'  = 'osascript'
    'pgrep'      = 'pgrep'
    'plistbuddy' = '/usr/libexec/PlistBuddy'
    'plutil'     = 'plutil'
    'ps'         = '/bin/ps'
    'qemu-img'   = 'qemu-img'
    'sudo'       = 'sudo'
}
# The literal is the last resort only: the host-condition module is the one
# definition, and it is reached whenever its import above succeeded.
$script:UtmctlBundlePath = if (Get-Command -Name 'Get-MacUtmctlBundlePath' -CommandType Function -ErrorAction SilentlyContinue) {
    Get-MacUtmctlBundlePath
} else {
    '/Applications/UTM.app/Contents/MacOS/utmctl'
}
# Cached only after a successful read: the uid of this process cannot change,
# but a failed read must be retried rather than remembered.
$script:UtmCurrentUid = $null
$script:UtmStatePollMilliseconds       = 500
$script:UtmStartSettlePollMilliseconds = 1000
$script:UtmDeleteRetryDelaySeconds     = 3
$script:UtmRestartEvidenceMaxAgeMs     = 120000
$script:UtmHardStopWaitMilliseconds    = 5000
$script:UtmPreferenceFlushSettleMilliseconds = 500
# Rename-VM's own waits: for UTM to exit after the quit, for it to be observed
# after the relaunch, and for the renamed VM to surface.
$script:UtmRenameQuitWaitSeconds       = 30
$script:UtmRenameLaunchWaitSeconds     = 30
$script:UtmRenameSurfaceWaitMilliseconds = 30000
$script:UtmHelperProcessPattern        = 'QEMUHelper'
# What the helper census matches in a command line (pgrep -f, an extended
# regex): the helper's XPC bundle directory. The QEMU process a helper starts
# runs from inside that bundle under another name, so a match on the process
# name alone would miss it; text that only mentions the word, such as a log
# file named after the helper, does not match.
$script:UtmHelperCommandPattern        = '/QEMUHelper[.]xpc/|^QEMUHelper( |$)'
$script:UtmNotFoundPattern             = 'not found'
$script:UtmSharedLeasePath             = '/var/db/dhcpd_leases'
# See https://yuruna.link/42e220c4-0004
$script:UtmAppleEventReasonPattern = [ordered]@{
    'permission-denied' = '-1743\b|Not authorized to send Apple events'
    'timeout'           = '-1712\b|AppleEvent timed out'
    'no-session'        = 'does not work from SSH'
    # -609 (connectionInvalid) is the Apple Event transport reporting that the
    # target process went away while the event was pending: from utmctl it is
    # what a UTM.app that crashed or was replaced mid-request looks like. It is
    # its own row because the next request usually reaches a relaunched UTM,
    # and whether that one still acts on lifecycle verbs is the question the
    # start retry has to answer separately.
    'connection-invalid' = '-609\b|connection is invalid'
    'provider-error'    = 'OSStatus error|couldn.t be completed|Error from event|Apple ?Event'
}

<#
.SYNOPSIS
    The result shape of a helper call that was never launched because its
    deadline had no usable time left.
#>
function Get-UtmNotLaunchedResult {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Tool = '')
    return @{
        ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $false
        DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 0
        DeadlineExhausted = $true; Tool = $Tool
    }
}

<#
.SYNOPSIS
    $true only for a bounded result whose output can be believed in full.
.DESCRIPTION
    A result that timed out, did not finish draining, was cut at the capture
    cap, could not be killed, or was never launched says nothing complete
    about the tool's answer. A missing key reads as $false.
#>
function Test-UtmBoundedResultComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][hashtable]$Result)
    return (Test-BoundedNativeResultComplete -Result $Result)
}

<#
.SYNOPSIS
    Run one of this driver's helper tools under a wall-clock cap.
.DESCRIPTION
    Each of these tools talks to a system service (launchd, opendirectoryd,
    cfprefsd, the process table) that can stop answering, and none carries a
    timeout of its own. The cap is the smaller of -TimeoutSeconds and what the
    optional deadline has left; with under one second left nothing is launched
    and the result says DeadlineExhausted.

    sudo is accepted only with -n as its first argument, so no call through
    here can wait on a password prompt nobody can see.
.PARAMETER Tool
    Key in $script:UtmHostTool.
.PARAMETER ArgumentList
    Arguments passed verbatim.
.PARAMETER TimeoutSeconds
    The call's own cap.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER Environment
    Extra environment variables for the child only.
.OUTPUTS
    [hashtable] the Invoke-BoundedNativeCommand keys plus DeadlineExhausted and Tool.
#>
function Invoke-UtmHostTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('arp', 'dscl', 'id', 'ifconfig', 'kill', 'killall', 'launchctl', 'log', 'osascript', 'pgrep', 'plistbuddy', 'plutil', 'ps', 'qemu-img', 'sudo')]
        [string]$Tool,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 10,
        $Deadline,
        [hashtable]$Environment
    )
    if ($Tool -eq 'sudo' -and ($ArgumentList.Count -eq 0 -or $ArgumentList[0] -ne '-n')) {
        throw [System.ArgumentException]::new((Format-YurunaOperatorMessage -Key 'exceptions.host_utm_sudo_requires_noninteractive'))
    }
    $cap = $TimeoutSeconds
    if ($Deadline) {
        $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling $TimeoutSeconds
        if ($null -eq $bounded) { return (Get-UtmNotLaunchedResult -Tool $Tool) }
        $cap = [int]$bounded
    }
    $invoke = @{ FilePath = [string]$script:UtmHostTool[$Tool]; ArgumentList = $ArgumentList; TimeoutSeconds = $cap }
    if ($Environment) { $invoke['Environment'] = $Environment }
    $result = Invoke-BoundedNativeCommand @invoke
    $result['DeadlineExhausted'] = $false
    $result['Tool'] = $Tool
    return $result
}

<#
.SYNOPSIS
    Launch a tool whose job is to start an application, and wait only for
    the launch to be acknowledged.
.DESCRIPTION
    `open` hands the application to LaunchServices and returns; the
    application it starts must outlive this call. The tree-killing bounded
    runner is therefore the wrong primitive: on a timeout it would kill the
    very process it was asked to start. This waits at most
    -AcknowledgeSeconds for `open` itself to exit, never kills anything, and
    leaves a launcher that did not return to finish on its own. Standard
    input is closed so the launcher cannot wait on a terminal; output is
    captured only when the launcher has exited.
.PARAMETER Tool
    Key in $script:UtmHostTool; only launchers are accepted.
.PARAMETER ArgumentList
    Arguments passed verbatim.
.PARAMETER AcknowledgeSeconds
    How long to wait for the launcher to exit.
.OUTPUTS
    [pscustomobject] Started, Acknowledged, ExitCode, StdOut, StdErr, ProcessId, ElapsedMs.
#>
function Start-UtmDetachedLaunch {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('open')][string]$Tool,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 60)][int]$AcknowledgeSeconds = 10
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $record = [ordered]@{ Started = $false; Acknowledged = $false; ExitCode = $null; StdOut = ''; StdErr = ''; ProcessId = 0; ElapsedMs = 0 }
    $file = [string]$script:UtmHostTool[$Tool]
    if (-not $PSCmdlet.ShouldProcess("$file $($ArgumentList -join ' ')", (Format-YurunaOperatorMessage -Key 'host.utm_detached_launch_action' -Arguments @{ tool = "$Tool" }))) {
        $record.ElapsedMs = $stopwatch.ElapsedMilliseconds
        return [pscustomobject]$record
    }
    $resolved = (Get-Command -CommandType Application -Name $file -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $resolved -and (Test-Path -LiteralPath $file -PathType Leaf)) { $resolved = $file }
    if (-not $resolved) {
        Write-Verbose "Start-UtmDetachedLaunch: '$file' was not found."
        $record.ElapsedMs = $stopwatch.ElapsedMilliseconds
        return [pscustomobject]$record
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new($resolved)
    foreach ($argument in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Verbose "Start-UtmDetachedLaunch: could not start '$resolved': $($_.Exception.Message)"
        $record.ElapsedMs = $stopwatch.ElapsedMilliseconds
        return [pscustomobject]$record
    }
    $record.Started   = $true
    $record.ProcessId = $proc.Id
    try { $proc.StandardInput.Close() } catch { $null = $_ }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $false
    try { $exited = $proc.WaitForExit([int]($AcknowledgeSeconds * 1000)) } catch { $exited = $false }
    if ($exited) {
        $record.Acknowledged = $true
        $record.ExitCode     = [int]$proc.ExitCode
        # The launched application can inherit these streams and hold them
        # open, so only output that already reached end of file is read; an
        # unfinished read task is never waited on past this short bound.
        if ($outTask.Wait(500)) { $record.StdOut = [string]$outTask.GetAwaiter().GetResult() }
        if ($errTask.Wait(500)) { $record.StdErr = [string]$errTask.GetAwaiter().GetResult() }
        try { $proc.Dispose() } catch { $null = $_ }
    }
    $record.ElapsedMs = $stopwatch.ElapsedMilliseconds
    return [pscustomobject]$record
}

<#
.SYNOPSIS
    Sleep for an interval, never past a deadline; $true while time remains.
#>
function Wait-UtmInterval {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateRange(0, 3600000)][int]$Milliseconds,
        $Deadline
    )
    if ($Deadline) { return (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds $Milliseconds) }
    if ($Milliseconds -gt 0) { Start-Sleep -Milliseconds $Milliseconds }
    return $true
}

<#
.SYNOPSIS
    A deadline of -Milliseconds that never ends later than -Parent (less
    -ReserveMilliseconds), on the parent's clock.
#>
function Get-UtmChildDeadline {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][long]$Milliseconds,
        $Parent,
        [long]$ReserveMilliseconds = 0
    )
    if ($Parent) { return (New-YurunaDeadline -Parent $Parent -TotalMilliseconds ([Math]::Max([long]0, $Milliseconds)) -ReserveMilliseconds ([Math]::Max([long]0, $ReserveMilliseconds))) }
    return (New-YurunaDeadline -TotalMilliseconds ([Math]::Max([long]0, $Milliseconds)))
}

<#
.SYNOPSIS
    Diagnostic text for private logs: control and ANSI sequences removed,
    whitespace collapsed, at most 1024 characters.
#>
function ConvertTo-UtmDiagnosticText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = [regex]::Replace($Text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    $clean = [regex]::Replace($clean, '[\x00-\x1F\x7F]', ' ')
    $clean = ([regex]::Replace($clean, '\s{2,}', ' ')).Trim()
    if ($clean.Length -gt 1024) { $clean = $clean.Substring(0, 1024) }
    return $clean
}

<#
.SYNOPSIS
    The numeric uid of this process, or $null when it cannot be read.
#>
function Get-UtmCurrentUid {
    [CmdletBinding()]
    [OutputType([string])]
    param($Deadline)
    if ($script:UtmCurrentUid) { return [string]$script:UtmCurrentUid }
    $read = Invoke-UtmHostTool -Tool 'id' -ArgumentList @('-u') -TimeoutSeconds 5 -Deadline $Deadline
    if (-not (Test-UtmBoundedResultComplete -Result $read) -or $read.ExitCode -ne 0) { return $null }
    $uid = "$($read.StdOut)".Trim()
    if ($uid -notmatch '^\d+$') { return $null }
    $script:UtmCurrentUid = $uid
    return $uid
}

<#
.SYNOPSIS
    The owner, start time and command line of one process, read in a single
    bounded `ps` call.
.DESCRIPTION
    The three fields together identify a process instance: a pid alone can be
    recycled by an unrelated process, and the start time is what tells the
    two apart. The locale is pinned so the start time prints in the same
    fixed English form every time it is compared.
.OUTPUTS
    [pscustomobject] ProcessId, Found, Uid, StartText, Command, Reason
    ('found' | 'not-found' | 'timeout' | 'failed' | 'unparsed' | 'deadline-exhausted').
#>
function Get-UtmProcessIdentity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        $Deadline
    )
    $record = [ordered]@{ ProcessId = $ProcessId; Found = $false; Uid = $null; StartText = ''; Command = ''; Reason = 'failed' }
    $read = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-o', 'uid=,lstart=,command=', '-p', "$ProcessId") `
        -TimeoutSeconds 5 -Deadline $Deadline -Environment @{ LC_ALL = 'C'; LC_MESSAGES = 'C' }
    if ($read.DeadlineExhausted) {
        $record.Reason = 'deadline-exhausted'
    } elseif ($read.TimedOut) {
        $record.Reason = 'timeout'
    } elseif (Test-UtmBoundedResultComplete -Result $read) {
        $line = @("$($read.StdOut)" -split "`r?`n" | Where-Object { "$_".Trim() }) | Select-Object -First 1
        if ($read.ExitCode -ne 0 -and -not $line) {
            $record.Reason = 'not-found'
        } elseif ("$line" -match '^\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d{1,2}\s+\d{1,2}:\d{2}:\d{2}\s+\d{4})\s+(\S.*?)\s*$') {
            $record.Found     = $true
            $record.Uid       = $Matches[1]
            $record.StartText = ($Matches[2] -replace '\s+', ' ')
            $record.Command   = $Matches[3]
            $record.Reason    = 'found'
        } else {
            $record.Reason = 'unparsed'
        }
    }
    return [pscustomobject]$record
}

<#
.SYNOPSIS
    Classify utmctl output against the Apple Event wording table; returns
    the reason token of the first matching row, or 'none'.
#>
function Get-UtmAppleEventReason {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'none' }
    foreach ($key in $script:UtmAppleEventReasonPattern.Keys) {
        if ($Text -match $script:UtmAppleEventReasonPattern[$key]) { return [string]$key }
    }
    return 'none'
}

<#
.SYNOPSIS
    The correlation key under which an Automation grant is recorded.
.DESCRIPTION
    macOS records an Automation grant for the responsible application, so a
    grant observed from one process says nothing about a process launched
    from somewhere else. The key combines the uid with what the process
    publishes about the application that started it. It is a correlation
    key, not proof: only a recorded responsive round trip from a process
    with the same key counts as evidence of a grant. A key built while the
    uid could not be read starts 'uid=unknown;' and never qualifies (see
    Test-UtmAutomationSubjectQualified): every process whose uid read failed
    would share it.
#>
function Get-UtmAutomationSubject {
    [CmdletBinding()]
    [OutputType([string])]
    param($Deadline)
    $uid = Get-UtmCurrentUid -Deadline $Deadline
    $uidText = if ($uid) { $uid } else { 'unknown' }
    return "uid=$uidText;bundle=$($env:__CFBundleIdentifier);term=$($env:TERM_PROGRAM)"
}

<#
.SYNOPSIS
    Whether an Automation subject can stand for a recorded grant: it names a
    numeric uid and appears in the recorded list.
.DESCRIPTION
    A subject built without a uid ('uid=unknown;...') is the same string for
    every process whose uid read failed, whoever it ran as, so it never
    qualifies, even when an earlier failed read put that string on the list.
#>
function Test-UtmAutomationSubjectQualified {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Subject,
        [AllowNull()][AllowEmptyCollection()][string[]]$RecordedSubject
    )
    if ([string]::IsNullOrEmpty($Subject) -or $Subject -notmatch '^uid=\d+;') { return $false }
    return [bool](@($RecordedSubject) -ccontains $Subject)
}

<#
.SYNOPSIS
    The GUI-session kind of this process ('Aqua', 'Remote' or 'Unknown'),
    bounded by the deadline.
#>
function Get-UtmProbeSessionKind {
    [CmdletBinding()]
    [OutputType([string])]
    param($Deadline)
    $cap = 5
    if ($Deadline) {
        $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 5
        if ($null -eq $bounded) { return 'Unknown' }
        $cap = [int]$bounded
    }
    # A copy of the host-condition module without the bounded form would run
    # launchctl with no cap at all; that question is left unanswered instead.
    $sessionCommand = Get-Command -Name 'Get-MacSessionKind' -CommandType Function -ErrorAction SilentlyContinue
    if (-not $sessionCommand -or -not $sessionCommand.Parameters.ContainsKey('TimeoutSeconds')) { return 'Unknown' }
    $kind = "$(Get-MacSessionKind -TimeoutSeconds $cap)"
    if ($kind -in @('Aqua', 'Remote', 'Unknown')) { return $kind }
    return 'Unknown'
}

<#
.SYNOPSIS
    Locate utmctl: on PATH first, then the copy inside UTM.app.
.DESCRIPTION
    UTM installs its command line inside the app bundle and nothing puts it
    on PATH, so a host with UTM correctly installed can lack the link. A
    missing link must read as "the link is missing", never as "UTM is not
    here": a caller that concluded the latter could restart a healthy UTM.
    Pure lookup -- no native call, and it never repairs the link.
.OUTPUTS
    [pscustomobject] Path (full path or $null), Source ('path' | 'bundle' |
    'missing'), LinkOnPath, BundlePath, BundlePresent.
#>
function Resolve-UtmctlExecutable {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $onPath = Get-Command -Name 'utmctl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $bundlePath = [string]$script:UtmctlBundlePath
    $bundlePresent = $false
    if ($bundlePath) {
        try { $bundlePresent = [System.IO.FileInfo]::new($bundlePath).Exists } catch { $bundlePresent = $false }
    }
    $path = $null
    $source = 'missing'
    if ($onPath) { $path = [string]$onPath.Source; $source = 'path' }
    elseif ($bundlePresent) { $path = $bundlePath; $source = 'bundle' }
    return [pscustomobject]@{
        PSTypeName    = 'Yuruna.UtmctlResolution'
        Path          = $path
        Source        = $source
        LinkOnPath    = [bool]$onPath
        BundlePath    = $bundlePath
        BundlePresent = $bundlePresent
    }
}
