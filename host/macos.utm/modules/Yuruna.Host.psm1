<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42bd906d-30b3-44f2-9020-fea9dbf0805f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos utm
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for macOS + UTM. Implements the Yuruna.Host
    driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for macOS + UTM (Apple Silicon and Intel).

.DESCRIPTION
    Self-contained host driver: contract surface plus the UTM/macOS
    helpers it consumes. Cross-host helpers live in
    automation/Yuruna.Common.psm1 and test/modules/Test.Ssh.psm1, imported below.
    Module-qualified calls (e.g. `Yuruna.HostDownload\Save-CachedHttpUri`) appear
    where an external helper shares its name with the contract function
    -- without the qualifier the call would re-enter our own definition
    and recurse.
#>

# --- REGION: Module setup
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:HostTag        = 'host.macos.utm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/macos.utm'

<#
.SYNOPSIS
    Returns this driver's host tag, repairing it if module state was lost.
.DESCRIPTION
    $script: state does not survive this module being -Force re-imported
    (feedback_module_script_state_reset_by_force_reimport). A caller holding
    an already-resolved reference to a contract function keeps running against
    the evicted instance, whose session state has been torn down, and
    $script:HostTag then reads as an empty string.

    That empty string is load-bearing: binding it to the dispatcher's
    -HostType fails with "Cannot bind argument to parameter 'HostType'
    because it is an empty string", so the keystroke types nothing while the
    caller sees only a non-terminating error and carries on. A console line
    left half-typed that way stays in the tty and the next text sent to the
    guest is appended to it, surfacing much later as a command nobody wrote.

    The tag is a compile-time constant for this driver, so resolving it
    through a literal fallback makes the empty binding impossible regardless
    of module lifetime, and restores the variable for any other reader that
    can still reach this scope.
#>
function Resolve-HostTag {
    [OutputType([string])]
    param()
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.macos.utm' }
    return $script:HostTag
}

# The supporting test/modules become callable from our function bodies;
# Export-ModuleMember below decides which of OUR functions become visible
# to test/ orchestration. Yuruna.Host.psm1's exports shadow any same-name
# exports the supporting modules also produce.
# These dependency modules are imported -Global: Yuruna.Host is -Force re-imported
# mid-cycle, and a bare -Force import here lands in Yuruna.Host's nested scope and
# EVICTS the global copy other modules call via qualified names (e.g.
# Test.Ssh\Invoke-GuestSsh) -- feedback_module_force_import_evicts_global.
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global
# Shared squid download / TLS-bump stack -- single source of truth across host drivers.
# The X509 chain-validation callback lives here verbatim; per-driver cache-host
# discovery is injected via the -ResolveCacheHostIp scriptblock (see wrapper below).
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Download-agent client. The Get-Image hooks feature-detect its two functions by
# name, so this import is what decides whether the agent path exists at all on
# this host; without it the agent is silently never consulted.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.DownloadAgent.psm1') -Force -DisableNameChecking -Global
# Shared per-guest provisioning helpers (the New-VM.ps1 child-runner +
# the Get-Image log-line writer) common to all three drivers.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global
# The GUI-session probe and the in-bundle utmctl path come from the macOS
# host-condition module. -Global without -Force: a copy the host-condition
# facade already loaded is reused as is, rather than re-run and reset under
# its other callers every time this driver is re-imported. A long-lived
# process can hold a copy loaded before those two entry points existed; that
# copy is replaced (still -Global, so every caller sees the same one) rather
# than left to fail the driver's first call into it.
Import-Module (Join-Path $script:TestModulesDir 'Test.HostCondition.Mac.psm1') -Global -DisableNameChecking
$macSessionCommand = Get-Command -Name 'Get-MacSessionKind' -CommandType Function -ErrorAction SilentlyContinue
if (-not (Get-Command -Name 'Get-MacUtmctlBundlePath' -CommandType Function -ErrorAction SilentlyContinue) -or
    -not ($macSessionCommand -and $macSessionCommand.Parameters.ContainsKey('TimeoutSeconds'))) {
    Import-Module (Join-Path $script:TestModulesDir 'Test.HostCondition.Mac.psm1') -Global -Force -DisableNameChecking
}
Remove-Variable -Name 'macSessionCommand' -ErrorAction SilentlyContinue
# --- REGION: macOS/UTM host helpers
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
# The one wording table for utmctl's Apple Event failures. utmctl exits 0 on
# most of them and prints the OSStatus text instead, so the text is the only
# evidence, and the ORDER is the classification: a denial (-1743) or timeout
# (-1712) message also carries the generic OSStatus phrasing, so the specific
# rows must be tried before the catch-all. Every wording the repository has
# seen (driver and installer gate) belongs here, each pinned by a fixture.
$script:UtmAppleEventReasonPattern = [ordered]@{
    'permission-denied' = '-1743\b|Not authorized to send Apple events'
    'timeout'           = '-1712\b|AppleEvent timed out'
    'no-session'        = 'does not work from SSH'
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
    if (-not $Result -or -not $Result['Started']) { return $false }
    foreach ($key in 'TimedOut', 'DrainTimedOut', 'OutputTruncated', 'KillFailed', 'DeadlineExhausted') {
        if ($Result[$key]) { return $false }
    }
    return $true
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
        [ValidateSet('arp', 'dscl', 'id', 'ifconfig', 'kill', 'killall', 'launchctl', 'osascript', 'pgrep', 'plistbuddy', 'plutil', 'ps', 'qemu-img', 'sudo')]
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
    $ms = [long]$Milliseconds
    if ($Deadline) { $ms = [Math]::Min($ms, [long](Get-YurunaDeadlineRemainingMs -Deadline $Deadline)) }
    if ($ms -gt 0) { Start-Sleep -Milliseconds ([int]$ms) }
    if ($Deadline) { return (-not (Test-YurunaDeadlineExpired -Deadline $Deadline)) }
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
    $budget = [Math]::Max([long]0, $Milliseconds)
    if ($Parent) {
        $left = [long](Get-YurunaDeadlineRemainingMs -Deadline $Parent) - $ReserveMilliseconds
        $budget = [Math]::Max([long]0, [Math]::Min($budget, $left))
        return (New-YurunaDeadline -TotalMilliseconds $budget -ClockTicks $Parent.ClockTicks)
    }
    return (New-YurunaDeadline -TotalMilliseconds $budget)
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

# --- REGION: Port-map helpers
function Start-CachingProxyServiceForwarder {
    <#
    .SYNOPSIS
        Launches (or stops) the caching-proxy-service TCP forwarder on the Mac host.

    .DESCRIPTION
        Exposes the Shared-NAT caching-proxy-service VM to REMOTE LAN hosts: it binds
        a cache port on the host's LAN IP and tunnels to $CacheIp on the
        192.168.64.0/24 vmnet subnet, so machines elsewhere on the LAN can use
        the cache. Same-Mac UTM guests do NOT need this -- on macOS 26 every
        vmnet-shared VM joins one bridge (192.168.64.1) and guests reach a
        sibling VM's 192.168.64.x IP directly. (An older belief that shared-NAT
        blocks guest-to-guest ARP on 192.168.64.0/24 did not reproduce there.)

        Start-CachingProxyServiceForwarder spawns Start-CachingProxyServiceForwarder.ps1
        as a detached `pwsh` subprocess that binds :3128 on the host and
        tunnels to $CacheIp:3128. Detached so the forwarder outlives
        Start-CachingProxyServiceVM.ps1 (it survives the launcher exiting -- it is
        reparented to launchd -- but any Remove-PortMap still tears it down).

        PID is written to $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid.
        Stop-CachingProxyServiceForwarder reads it and sends SIGTERM.
        Get-CachingProxyServiceForwarder reports liveness without signaling.

        Returns $true when the forwarder is verified listening (Start),
        terminated (Stop), or currently running (Get).

    .PARAMETER CacheIp
        IP of the caching-proxy-service VM (Start-CachingProxyServiceForwarder only). Typically
        192.168.64.X discovered by Start-CachingProxyServiceVM.ps1's subnet probe.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # 0 sentinel -- when unspecified, host port == VM port (the common case;
    # proxy/Grafana/etc.). Split ports kick in for SSH (8022 -> 22) and any
    # other future host:VM remap. Pidfile name uses HOST port (predictable;
    # what `lsof -i :<host>` would show).
    if ($VMPort -eq 0) { $VMPort = $Port }
    # Forwarder script lives at host/macos.utm/Start-CachingProxyServiceForwarder.ps1.
    # Use $script:HostFolder (set at module load) instead of $PSScriptRoot:
    # the module-scoped variable is anchored to the .psm1's directory, so
    # the lookup is independent of how the function is dispatched.
    $forwarderScript = Join-Path $script:HostFolder "Start-CachingProxyServiceForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e22e1a85f32b3a0b' -Arguments @{ forwarderScript = "$forwarderScript" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${VMPort}", (Format-YurunaOperatorMessage -Key 'host.operator_67195d8019562611'))) {
        return $false
    }
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Pidfile/log are PER PORT so concurrent forwarders (squid :3128,
    # Grafana :3000, etc.) never fight over the same path. Port-named
    # files make discovery and selective teardown trivial.
    $pidFile = Join-Path $stateDir "forwarder.$Port.pid"
    $logFile = Join-Path $stateDir "forwarder.$Port.log"

    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_c22cbc5129006aa6' -Arguments @{ port = "${Port}"; cacheIp = "${CacheIp}"; vMPort = "${VMPort}"; proxyTag = "${proxyTag}" }) -InformationAction Continue
    # RedirectStandard* is required: without them pwsh inherits the
    # parent TTY and dies when Start-CachingProxyServiceVM.ps1 exits. The
    # forwarder's own log gets live traffic; stdout/stderr go to files.
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }
    # Ports below 1024 need root on macOS. Spawn via `sudo -E pwsh` when not
    # already root; the caller pre-caches credentials via `sudo -v` so the
    # detached subprocess can bind the port without an interactive tty prompt.
    # sudo exec's pwsh (no fork), so the pidfile PID matches the sudo PID.
    # An unreadable uid is treated as non-root: the sudo -n spawn below then
    # fails fast when root is not reachable, instead of binding as nobody.
    $isRoot = ((Get-UtmCurrentUid) -eq '0')
    $needsSudo = ($Port -lt 1024) -and (-not $isRoot)

    # If the privileged forwarder is already running (root-owned, started by
    # Start-CachingProxyServiceVM.ps1 which called `sudo -v` first), leave it alone.
    # Killing a root process requires sudo credentials that the caller
    # (e.g. Start-TestRunner) may not have cached -- and the correct CacheIp
    # is already baked into the running process. Only restart if crashed.
    if ($needsSudo -and (Get-CachingProxyServiceForwarder -Port $Port)) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_fac89af7ceb85a93' -Arguments @{ port = "${Port}" }) -InformationAction Continue
        return $true
    }

    # A failed stop retains the pidfile and must not start a second listener.
    if (-not (Stop-CachingProxyServiceForwarder -Port $Port -Quiet)) { return $false }

    # -n on the sudo spawn: this is a DETACHED process whose stdout and stderr
    # are redirected to files, so a password prompt would be written to a log
    # and the forwarder would sit there unbound until something noticed. With -n
    # a missing credential fails immediately and the bind wait below reports it.
    $spawnFile = if ($needsSudo) { 'sudo' } else { 'pwsh' }
    $spawnArgs = if ($needsSudo) { @('-n', '-E', 'pwsh') + $procArgs } else { $procArgs }

    try {
        $proc = Start-Process -FilePath $spawnFile `
            -ArgumentList $spawnArgs `
            -RedirectStandardOutput "$stateDir/forwarder.$Port.stdout.log" `
            -RedirectStandardError  "$stateDir/forwarder.$Port.stderr.log" `
            -PassThru
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_368bbdea275958b3' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    # Wait briefly for the listener to bind and the pidfile to be written.
    # 3s is generous; pwsh startup + TcpListener.Start() is sub-second.
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { (Get-Content $pidFile -Raw).Trim() } else { $proc.Id }
                $upMsg = if ($Port -eq $VMPort) {
                    "Forwarder up (pid $actualPid). Guests should use http://192.168.64.1:${Port}"
                } else {
                    "Forwarder up (pid $actualPid): host :${Port} -> ${CacheIp}:${VMPort}"
                }
                Write-Information "  $upMsg" -InformationAction Continue
                return $true
            }
        } catch {
            # Expected while the child is still booting (pwsh startup +
            # TcpListener.Start). Retry until the deadline.
            $null = $_
        } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9b8f576034f602fb' -Arguments @{ id = "$($proc.Id)"; port = "${Port}" })
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0b768b57cdd33d5e' -Arguments @{ stateDir = "$stateDir" })
    # A non-answering child may still be half-bound (listener up, connect
    # racing) or wedged. Tear it down so it is not orphaned holding the
    # port past our return. Prefer the pidfile-driven, identity-verified
    # stop (matches Start-CachingProxyServiceForwarder.ps1, honors root ownership);
    # if the child never wrote its pidfile, signal the spawned pid directly.
    if (Test-Path $pidFile) {
        [void](Stop-CachingProxyServiceForwarder -Port $Port -Quiet)
    } else {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { Write-Verbose "Could not stop orphaned forwarder pid $($proc.Id): $_" }
    }
    return $false
}

<#
.SYNOPSIS
    Terminates the host-side caching-proxy-service TCP forwarder if it is running.

.DESCRIPTION
    Reads $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid and verifies the
    PID belongs to Start-CachingProxyServiceForwarder.ps1 (via /bin/ps -o
    command=) before signaling -- a stale pidfile pointing at an
    unrelated process must NOT be killed. Sends SIGTERM and waits up to
    2s; escalates to SIGKILL if no response. The pidfile is removed on
    every success path and on stale-pidfile detection so the next Start
    call is clean.

.PARAMETER Quiet
    Suppress the informational Write-Output lines. Start-CachingProxyServiceForwarder
    passes this when preflight-stopping a stale forwarder so the happy
    path stays quiet.

.OUTPUTS
    [bool] $true on any exit where the pidfile is in a coherent state
    (process stopped or never running); $false when the recorded pid could
    not be read within its time limit, in which case the pidfile is kept and
    nothing was signaled.
#>
function Stop-CachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) {
        if (-not $Quiet) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_51cfbd5426e42f8d') }
        return $true
    }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2b5a075a69fb02ea' -Arguments @{ pidFile = "$pidFile"; forwarderPid = "$forwarderPid" }) }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    # Verify the process looks like our forwarder before killing.
    # -o command= prints full argv so we can match
    # Start-CachingProxyServiceForwarder.ps1 and avoid killing an unrelated pid
    # that matches a stale pidfile. Bounded: a read that did not finish proves
    # nothing either way, so the pidfile is kept and nothing is signaled.
    $identity = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'command=') -TimeoutSeconds 5
    if (-not (Test-UtmBoundedResultComplete -Result $identity)) {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.forwarder_identity_unverified' -Arguments @{ forwarderPid = "$forwarderPid" }) }
        return $false
    }
    $cmd = "$($identity.StdOut)".Trim()
    if ($identity.ExitCode -ne 0 -or -not $cmd) {
        if (-not $Quiet) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_7934de6bf4f9bbe6' -Arguments @{ forwarderPid = "$forwarderPid" }) }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-CachingProxyServiceForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5c93ad943c43270c' -Arguments @{ forwarderPid = "$forwarderPid"; cmd = "$cmd" }) }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess("pid $forwarderPid (Start-CachingProxyServiceForwarder.ps1)", (Format-YurunaOperatorMessage -Key 'host.operator_378bec0a86550e8e'))) {
        return $false
    }
    if (-not $Quiet) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_0dbaee5477554260' -Arguments @{ forwarderPid = "$forwarderPid" }) }
    # /bin/kill sends SIGTERM (default). PowerShell 7's Stop-Process on
    # Unix maps to Process.Kill() == SIGKILL unconditionally, bypassing
    # graceful shutdown -- hence the external binary for TERM-then-KILL.
    # Port 80's forwarder is root-owned (spawned via sudo); a regular user
    # cannot signal it -- detect and escalate via sudo kill if needed.
    $owner     = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'user=') -TimeoutSeconds 5
    $procOwner = "$($owner.StdOut)".Trim()
    $meIsRoot  = ((Get-UtmCurrentUid) -eq '0')
    $useSudo   = ($procOwner -eq 'root') -and (-not $meIsRoot)
    # Every signal is bounded. Through sudo it always carries -n: this runs
    # inside teardown paths whose console belongs to a caller, and sudo takes
    # its password from /dev/tty regardless of how stdin was set up -- so a
    # cold credential here would stall the teardown on a prompt nobody sees,
    # rather than reporting that root was unavailable.
    $sendSignal = {
        param([string[]]$SignalArgument)
        if ($useSudo) {
            return (Invoke-UtmHostTool -Tool 'sudo' -ArgumentList (@('-n', [string]$script:UtmHostTool['kill']) + $SignalArgument + @("$forwarderPid")) -TimeoutSeconds 5)
        }
        return (Invoke-UtmHostTool -Tool 'kill' -ArgumentList ($SignalArgument + @("$forwarderPid")) -TimeoutSeconds 5)
    }
    $term = & $sendSignal @()
    if ($useSudo -and -not ((Test-UtmBoundedResultComplete -Result $term) -and $term.ExitCode -eq 0) -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7bbd97967255a376' -Arguments @{ forwarderPid = "$forwarderPid" })
    }
    $exitWait = New-YurunaDeadline -TotalMilliseconds 2000
    while (Wait-UtmInterval -Milliseconds 100 -Deadline $exitWait) {
        $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
        if ((Test-UtmBoundedResultComplete -Result $alive) -and $alive.ExitCode -ne 0) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fd3a364b69ecd8d4' -Arguments @{ forwarderPid = "$forwarderPid" }) }
    $kill = & $sendSignal @('-9')
    if ($useSudo -and -not ((Test-UtmBoundedResultComplete -Result $kill) -and $kill.ExitCode -eq 0) -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_157f9a28bfef1ebf' -Arguments @{ forwarderPid = "$forwarderPid" })
    }
    Start-Sleep -Milliseconds 200
    $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
    if (-not (Test-UtmBoundedResultComplete -Result $alive) -or $alive.ExitCode -eq 0) {
        return $false
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Reports whether the host-side caching-proxy-service TCP forwarder is running.

.DESCRIPTION
    Pure observer -- never signals, never removes files. Returns $true
    iff $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid exists, parses as
    an int, and refers to a live process (via /bin/ps). Does NOT verify
    the process is actually our forwarder; Stop-CachingProxyServiceForwarder
    handles that stricter identity check on the write path.

.OUTPUTS
    [bool] $true if the pidfile points at a live process, $false
    otherwise (missing pidfile, malformed content, or dead pid).
#>
function Get-CachingProxyServiceForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port = $(Get-CachingProxyServicePort -Scheme http))
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) { return $false }
    $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
    return [bool]((Test-UtmBoundedResultComplete -Result $alive) -and $alive.ExitCode -eq 0)
}

<#
.SYNOPSIS
    Stop every caching-proxy-service port forwarder the host currently has.

.DESCRIPTION
    Enumerates $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid entries
    and sends SIGTERM to each (SIGKILL escalation per port via
    Stop-CachingProxyServiceForwarder). Missing directory / no pidfiles is a
    no-op; safe to call even when nothing is running.

    The host-contract `Add-PortMap` / `Remove-PortMap` (declared in
    host/Yuruna.Host.Contract.psm1, implemented per platform) dispatch to
    Start-CachingProxyServiceForwarder + this function on macOS.

.OUTPUTS
    [int[]] -- ports whose forwarder was stopped (may be empty).
#>
function Stop-AllCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([switch]$Quiet)
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    if (-not (Test-Path $stateDir)) { return @() }
    $stopped = @()
    # Glob forwarder.<N>.pid; BaseName strips ".pid" so the regex only
    # needs the middle token.
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') {
                $portInt = [int]$matches[1]
                if ($PSCmdlet.ShouldProcess("port $portInt", (Format-YurunaOperatorMessage -Key 'host.operator_36b84d687b0706c6'))) {
                    [void](Stop-CachingProxyServiceForwarder -Port $portInt -Quiet:$Quiet)
                    $stopped += $portInt
                }
            }
        }
    return ,$stopped
}

<#
.SYNOPSIS
    The host port forwarders this driver started, as recorded by their
    pidfiles: host port, target address and port, and whether the pid is
    verified to still be that forwarder.
.DESCRIPTION
    Read-only. Each forwarder.<Port>.pid is read, and the recorded pid's
    command line is read back through one bounded `ps`; OwnerVerified is
    $true only when that command line is the forwarder script, which is also
    where the target address and port are read from. A pidfile whose pid
    cannot be read or no longer runs the forwarder is still reported, with
    OwnerVerified $false, because an unverified mapping is collateral a
    caller must account for rather than silently drop.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline) bounding the reads.
.OUTPUTS
    [pscustomobject] per pidfile: HostPort, TargetAddress, TargetPort,
    OwnerPid, OwnerVerified, Origin ('forwarder-pidfile').
#>
function Get-PortMapTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $stateDir = Join-Path $HOME 'yuruna/image/caching-proxy-service'
    if (-not [System.IO.Directory]::Exists($stateDir)) { return }
    foreach ($file in @([System.IO.Directory]::GetFiles($stateDir, 'forwarder.*.pid') | Sort-Object)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
        if ($name -notmatch '^forwarder\.(\d+)$') { continue }
        $hostPort = [int]$Matches[1]
        $ownerPid = 0
        $pidText = ''
        try { $pidText = [System.IO.File]::ReadAllText($file).Trim() } catch { $pidText = '' }
        [void][int]::TryParse($pidText, [ref]$ownerPid)
        $targetAddress = ''
        $targetPort = 0
        $verified = $false
        if ($ownerPid -gt 0) {
            $read = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$ownerPid", '-o', 'command=') -TimeoutSeconds 5 -Deadline $Deadline
            $command = if ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { "$($read.StdOut)".Trim() } else { '' }
            if ($command -match 'Start-CachingProxyServiceForwarder\.ps1') {
                $verified = $true
                if ($command -match '-CacheIp\s+(\S+)') { $targetAddress = $Matches[1] }
                if ($command -match '-VMPort\s+(\d+)') { $targetPort = [int]$Matches[1] }
                elseif ($command -match '-Port\s+(\d+)') { $targetPort = [int]$Matches[1] }
            }
        }
        [pscustomobject]@{
            PSTypeName    = 'Yuruna.PortMapTarget'
            HostPort      = $hostPort
            TargetAddress = $targetAddress
            TargetPort    = $targetPort
            OwnerPid      = $ownerPid
            OwnerVerified = $verified
            Origin        = 'forwarder-pidfile'
        }
    }
}

# --- REGION: Caching-proxy service IP discovery
function Resolve-CacheHostIp {
    <#
    .SYNOPSIS
        Returns the IP of a reachable caching-proxy-service (probed on :3128), or
        $null when no cache is currently usable. Prefers the direct VM IP
        so SSL-bump (:3129) and the CA endpoint (:80) are also reachable;
        falls back to 127.0.0.1 (host forwarder) for HTTP-only.

    .DESCRIPTION
        Discovery order:
          1. The cache VM IP recorded in the yuruna-caching-proxy-service state
             file (<track>/yuruna-caching-proxy-service.yml, written by
             Start-CachingProxyServiceVM.ps1 with the VM's 192.168.64.X address).
             If reachable, return THIS IP; the caller can hit :80 / :3128
             / :3129 on it directly across Apple Virtualization shared NAT.
          2. 127.0.0.1 -- the local Start-CachingProxyServiceForwarder bridges
             host:3128 -> VM:3128. Useful for HTTP origins; SSL-bump
             (:3129) won't work via the forwarder since only :3128 is
             bridged. Save-CachedHttpUri detects that case via separate
             :3129 probes and falls through to direct download.
    .OUTPUTS
        [string] IPv4 like '192.168.64.5' or '127.0.0.1', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyServicePort -Scheme http
    if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
        if ((Test-IpAddress $externIp) -and (Test-CachingProxyServicePort -IpAddress $externIp -Port $httpPort -TimeoutMs 500)) {
            return $externIp
        }
        return $null
    }
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-IpAddress $ip) -and (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    if (Test-CachingProxyServicePort -IpAddress '127.0.0.1' -Port $httpPort -TimeoutMs 500) {
        return '127.0.0.1'
    }
    return $null
}

<#
.SYNOPSIS
    Download $Uri to $OutFile through the UTM caching-proxy service, falling back to
    a direct fetch when no cache is reachable.
.DESCRIPTION
    Thin driver-local wrapper over the shared download stack. The closure binds
    this driver's Resolve-CacheHostIp (UTM cache discovery) so the shared module
    stays platform-agnostic while still reaching macOS-specific cache lookup.
#>
function Save-CachedHttpUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Yuruna.HostDownload\Save-CachedHttpUri -Uri $Uri -OutFile $OutFile -ResolveCacheHostIp { Resolve-CacheHostIp }
}

# --- REGION: VM lifecycle helpers
# UTM-internal helpers consumed by Yuruna.Host's contract entry points
# above. Not part of the test-facing host driver contract; test code
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
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ad3787aa98e176ba' -Arguments @{ vMName = "$VMName" })
    }
    # Confirm the VM is actually powered off (escalating to `utmctl stop --kill`
    # if the soft stop stalls) and its qcow2/bundle handles are released BEFORE
    # the deregistration -- otherwise the delete runs against a still-locked
    # bundle. Wait-UtmVMPoweredOff drives the same kill-escalation + lock check
    # the snapshot paths use.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_69569daab01168ea' -Arguments @{ vMName = "$VMName" })
    }
    if (-not (Remove-UtmVMRegistration -VMName $VMName -Confirm:$false)) {
        # Leaving the bundle on disk is the point. UTM deletes a VM by moving
        # its bundle to the trash, so removing the files under a registration
        # that survived strands the name in UTM with nothing left to delete --
        # and a stranded name is worse than a stranded bundle, because it still
        # answers `utmctl status` and so reads as a reusable VM to the sequence
        # engine, which then starts a VM that has no disk.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b393323b168a09a' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    Write-Verbose "Deleted UTM VM from registry: $VMName"
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (Test-Path $utmBundle) {
        if (Remove-UtmBundleWithRetry -Path $utmBundle) {
            Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_fdce3f3a724deacc' -Arguments @{ utmBundle = "$utmBundle" })
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
    'apple-event' | 'unresolved' | 'absent').
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
        return @{ success = $false; errorMessage = 'WhatIf'; attempts = 0; kind = 'none' }
    }
    $attemptCap = [Math]::Max(1, $MaxAttempts)
    $settleMs   = [long][Math]::Max(1, $SettleSeconds) * 1000
    $lastError  = ''
    $lastKind   = 'none'
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
        return @{ success = $false; attempts = $Attempt; kind = 'unresolved'; errorMessage = $Message }
    }
    for ($attempt = 1; $attempt -le $attemptCap; $attempt++) {
        if ($Deadline -and (Test-YurunaDeadlineExpired -Deadline $Deadline)) {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_dc12e47845da9820' -Arguments @{ vMName = "$VMName" }) ($attempt - 1))
        }
        $before = & $observe (Get-UtmChildDeadline -Milliseconds $settleMs -Parent $Deadline) @('running', 'stopped') $Deadline
        if ($before.State -eq 'running') {
            return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none' }
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
        $lastError = if (-not $start.OutcomeKnown) {
            Format-YurunaOperatorMessage -Key 'host.utmctl_lifecycle_timeout' -Arguments @{ verb = 'start'; vmName = "$VMName"; timeoutSeconds = "$($start.TimeoutSeconds)" }
        } elseif ($start.ExitCode -ne 0) {
            if ($text) { Format-YurunaOperatorMessage -Key 'host.utm_start_exit_detail' -Arguments @{ exitCode = "$($start.ExitCode)"; text = "$text" } }
            else { Format-YurunaOperatorMessage -Key 'host.utm_start_exit_code' -Arguments @{ exitCode = "$($start.ExitCode)" } }
        } elseif ($lastKind -ne 'none') { $text } else { '' }

        # Polled even when the verb reported an error: a start that printed an
        # Apple Event timeout can still have been carried out, and the state is
        # what settles it.
        # The guard reads the shared deadline, not the settle window: the
        # window only paces polling, and a window of exactly one second is
        # already under a second by the time it is measured, which would
        # refuse every short settle regardless of the time actually left.
        $settle = Get-UtmChildDeadline -Milliseconds $settleMs -Parent $Deadline
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_b0d08bfb4f337561' -Arguments @{ vMName = "$VMName" }) $attempt)
        }
        $after = & $observe $settle @('running') $Deadline
        if ($after.State -eq 'running') {
            return @{ success = $true; errorMessage = $null; attempts = $attempt; kind = 'none' }
        }
        if ($lastKind -eq 'qemu') {
            return @{ success = $false; attempts = $attempt; kind = 'qemu'
                      errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_d2824e1687d3fb3f' -Arguments @{ vMName = "$VMName"; lastError = "$lastError" }) }
        }
        if ($after.State -ne 'stopped' -and $after.State -ne 'absent') {
            return (& $unresolved (Format-YurunaOperatorMessage -Key 'host.operator_5cde67d59ac2073f' -Arguments @{ vMName = "$VMName"; attempt = "$attempt" }) $attempt)
        }
    }
    if ($startsIssued -eq 0) {
        return @{ success = $false; attempts = $attemptCap; kind = 'absent'
                  errorMessage = (Format-YurunaOperatorMessage -Key 'host.utm_start_absent_observed' -Arguments @{ vmName = "$VMName"; waitSeconds = "$([int]($settleMs / 1000))"; attempt = "$attemptCap" }) }
    }
    $detail = if ($lastKind -eq 'apple-event') {
        Format-YurunaOperatorMessage -Key 'host.utm_start_not_acted' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap"; lastError = "$lastError" }
    } elseif ($lastError) {
        Format-YurunaOperatorMessage -Key 'host.utm_start_not_running' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap"; lastError = "$lastError" }
    } else {
        Format-YurunaOperatorMessage -Key 'host.utm_start_dropped' -Arguments @{ vmName = "$VMName"; attempts = "$attemptCap" }
    }
    return @{ success = $false; errorMessage = $detail; attempts = $attemptCap; kind = $lastKind }
}

<#
.SYNOPSIS
    Cold-start a UTM VM (clears stale vmstate and spawns dialog watchdog).
#>
function Start-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $utmBundle)) {
        # Distinguish the two ways the bundle can be missing, from the
        # structured probe rather than the throwing boolean wrapper: still
        # registered means UTM holds a name whose files are gone -- the
        # caller reached here because that name answered the reuse check, so
        # pointing at the path alone would send the reader looking for a VM
        # that was never created, not for the registration that has to be
        # cleared before one can be. Unknown gets its own message: neither
        # "create a VM" nor "clear a registration" advice is warranted when
        # the probe could not establish which situation this is.
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
            # Resolve the VNC display before starting. The display is baked into
            # the bundle when the VM is BUILT, and every guest of a kind is built
            # under the same test-VM name, so a topology that promotes several
            # VMs out of that namespace ends up with all of them pinned to one
            # port -- QEMU then refuses to start every VM after the first with
            # "Failed to find an available port: Address already in use". Prefer
            # the display derived from the VM's CURRENT name (distinct per VM),
            # and exclude what the other bundles already claim so a genuine hash
            # collision falls through to the next free slot.
            #
            # This write only reaches QEMU for a bundle UTM has not loaded yet.
            # UTM reads config.plist when it loads a VM and keeps that copy for
            # the life of the app, so for an already-registered VM the file and
            # the command line diverge silently. Rename-VM does the durable
            # allocation, in the window where it has UTM quit.
            $wantDisplay = Find-FreeVncDisplay `
                -Preferred (Get-VncDisplayForVm -VMName $VMName) `
                -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $VMName)
            if ($wantDisplay -lt 0) {
                return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_239ba3e5aec356be' -Arguments @{ vMName = "$VMName" }) }
            }
            if ((Get-VncDisplayFromBundle -VMName $VMName) -ne $wantDisplay) {
                if (Set-VncDisplayInBundle -VMName $VMName -Display $wantDisplay -Confirm:$false) {
                    Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_645bdc6defb51655' -Arguments @{ vMName = "$VMName"; wantDisplay = "$wantDisplay"; wantDisplay2 = "$(5900 + $wantDisplay)" }) -InformationAction Continue
                } else {
                    # Not fatal on its own: the bundle may still hold a usable
                    # display. Say so, because a screenshot aimed at the stale
                    # port would otherwise capture another VM's framebuffer.
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d3e7833e5fc51e09' -Arguments @{ vMName = "$VMName" })
                }
            }
            Start-UtmDialogWatchdog
            # Detached: `open` hands the bundle to UTM and returns, and UTM
            # must outlive this call, so only the acknowledgment is bounded.
            $null = Start-UtmDetachedLaunch -Tool 'open' -ArgumentList @($utmBundle) -Confirm:$false
            Start-Sleep -Seconds 3
            # Adjudicated by state and retried, because utmctl exits 0 in three
            # different situations that are not success: a request UTM dropped
            # while still ingesting the bundle, a request UTM never acted on
            # (Apple Event error), and a VM whose QEMU died right after launch.
            # Reporting any of them as started buys a dead VM a full sequence of
            # downstream steps before anything notices, and the eventual symptom
            # -- an SSH timeout, a guest asserting on a peer that never came up
            # -- names neither this VM nor this reason.
            $start = Invoke-UtmVMStartWithRetry -VMName $VMName -Confirm:$false
            if (-not $start.success) {
                return @{ success = $false; errorMessage = $start.errorMessage }
            }
        }
        return @{ success = $true; errorMessage = $null }
    } catch {
        return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_3f0823f611b21152' -Arguments @{ vMName = "$VMName"; value = "$_" }) }
    }
}

<#
.SYNOPSIS
    Stop a UTM VM via utmctl.
#>
function Stop-UtmVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_ec02730efdb72c13'))) { return $true }
    Stop-UtmDialogWatchdog
    $stop = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName
    if ($stop.OutcomeKnown -and $stop.ExitCode -eq 0) {
        Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ad3787aa98e176ba' -Arguments @{ vMName = "$VMName" })
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
        # Gate on a positive stopped reading FIRST: if UTM runs QEMU without
        # an enforced write lock, the qemu-img probe below would pass while
        # the process is still alive, so the lock check alone is not
        # sufficient. Status can flip to 'stopped' a beat before QEMUHelper
        # releases the file handle -- qemu-img info WITHOUT -U fails while
        # the lock is held, so a clean exit on every disk is the all-clear.
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
    utmctl list columns are UUID, Status, Name (see
    [[utmctl-list-column-order]] memory note). A caller that must tell "none
    running" from "could not ask" uses Get-UtmRunningVmInventory instead:
    this wrapper emits nothing in both cases.
#>
function Get-RunningVmName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # Emits the names one by one: zero elements for an empty set, N for N.
    # Callers MUST normalize with `@(Get-RunningVmName)` to get a proper
    # array regardless of count. Do NOT use `return ,@($arr)` here: the
    # comma wrapper inverts for empty arrays (caller's @() then receives
    # a 1-element array whose single element is the empty array itself,
    # surfacing as a phantom "running VM" with empty name).
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
        192.168.64.x IP; the build uploads to the stash service; the intent store
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
    # Distinguish "confirmed no concurrent VM" from "couldn't check". If
    # UTM.app is unresponsive (host memory pressure -> Apple Event timeout,
    # OSStatus -1712), utmctl list returns empty and the running-set probe
    # below reads as "nothing running" -- a false all-clear that would let a
    # leftover VM slip past this guard. Surface that instead of silently
    # passing. We still proceed (returning $false here would wedge every cycle
    # on a host whose utmctl is intermittently unresponsive); the warning is
    # the signal, and the per-guest teardown probe is the other backstop.
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
    $null = Invoke-UtmHostTool -Tool 'osascript' -ArgumentList @('-e', 'tell application "UTM" to activate') -TimeoutSeconds 10
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
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'stop', 'delete')][string]$Verb,
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Kill,
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
        # Every remaining process's identity is read once, before the first
        # signal: a helper's baseline read after UTM's own TERM/KILL waits
        # would be seconds younger than the census that listed it. The census
        # is only a candidate list, so each baseline must already be this
        # user's UTM or helper executable; each signal then revalidates
        # against the baseline taken here.
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

# --- REGION: Host proxy helpers
# networksetup is sudo-only for writes. Read paths don't need sudo, so the
# backup capture can happen before the sudo check and surface a clearer
# error if sudo is missing. Marker file at $HOME/.yuruna/host-proxy.managed
# flags "this state was set by yuruna" -- same role as the WinINet
# YurunaProxyManaged registry value.

<#
.SYNOPSIS
    Return the path of the yuruna-managed macOS proxy marker file.
#>
function Get-MacProxyMarkerPath {
    $stateDir = Join-Path $HOME '.yuruna'
    return (Join-Path $stateDir 'host-proxy.managed')
}

<#
.SYNOPSIS
    Returns true if the marker file says yuruna set the macOS proxy.
#>
function Test-MacProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Test-Path -LiteralPath (Get-MacProxyMarkerPath))
}

<#
.SYNOPSIS
    Return the macOS network service for the default-route interface.
#>
function Get-MacActiveNetworkService {
    # `route -n get default` -> default-route interface (en0).
    # `networksetup -listnetworkserviceorder` pairs service names to
    # Device: entries; we match en0 back to "Wi-Fi" / "Ethernet" / etc.
    try {
        $routeOut = & route -n get default 2>$null
        $iface = $null
        foreach ($line in $routeOut) {
            if ($line -match 'interface:\s+(\S+)') { $iface = $matches[1]; break }
        }
        if (-not $iface) { return $null }
        $orderOut = & networksetup -listnetworkserviceorder 2>$null
        $lastService = $null
        foreach ($line in $orderOut) {
            if ($line -match '^\(\d+\)\s+(.+?)\s*$') { $lastService = $matches[1]; continue }
            if ($line -match '^\(Hardware Port:.*Device:\s*([^\)]+)\)') {
                if ($matches[1].Trim() -eq $iface) { return $lastService }
            }
        }
    } catch {
        Write-Verbose "Get-MacActiveNetworkService failed: $($_.Exception.Message)"
    }
    return $null
}

<#
.SYNOPSIS
    Read current macOS networksetup proxy state into a backup hashtable.
#>
function Read-MacProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$NetworkService)
    if (Test-MacProxyIsYurunaManaged) {
        return @{
            platform            = 'macos'
            networkService      = $NetworkService
            webProxy            = @{ Enabled = 'No'; Server = $null; Port = $null }
            secureWebProxy      = @{ Enabled = 'No'; Server = $null; Port = $null }
            bypassDomains       = @()
            yurunaResetSnapshot = $true
        }
    }
    <#
    .SYNOPSIS
        ConvertFrom-NetworksetupBlock.
    #>
    function ConvertFrom-NetworksetupBlock {
        param([string[]]$Lines)
        $h = @{}
        foreach ($line in $Lines) {
            if ($line -match '^\s*(Enabled|Server|Port|Authenticated|Username):\s*(.*)$') {
                $h[$matches[1]] = $matches[2].Trim()
            }
        }
        return $h
    }
    $webOut = & networksetup -getwebproxy       $NetworkService 2>$null
    $sslOut = & networksetup -getsecurewebproxy $NetworkService 2>$null
    $bypOut = & networksetup -getproxybypassdomains $NetworkService 2>$null
    $bypassList = @()
    if ($bypOut -and -not ($bypOut -is [string] -and $bypOut -match "aren't any")) {
        foreach ($line in @($bypOut)) {
            if ($line -match "aren't any") { $bypassList = @(); break }
            $t = "$line".Trim()
            if ($t) { $bypassList += $t }
        }
    }
    return @{
        platform       = 'macos'
        networkService = $NetworkService
        webProxy       = ConvertFrom-NetworksetupBlock -Lines $webOut
        secureWebProxy = ConvertFrom-NetworksetupBlock -Lines $sslOut
        bypassDomains  = $bypassList
    }
}

<#
.SYNOPSIS
    Cache sudo credentials when the current user is not root.
#>
function Invoke-MacElevationIfNeeded {
    if ((Get-UtmCurrentUid) -eq '0') { return }
    # Ask the machine before asking a person: an already-warm credential needs
    # neither the notice nor the prompt, and `sudo -n -v` refreshes it
    # silently. Bounded, so a sudo stuck on name or account lookup reads as
    # "not warm" instead of holding the caller.
    $warm = Invoke-UtmHostTool -Tool 'sudo' -ArgumentList @('-n', '-v') -TimeoutSeconds 10
    if ((Test-UtmBoundedResultComplete -Result $warm) -and $warm.ExitCode -eq 0) { return }
    # sudo reads its password from /dev/tty, which neither a closed stdin nor
    # -NonInteractive can redirect. The proxy teardown paths call this
    # unconditionally and run inside children whose console belongs to a parent,
    # so a bare `sudo -v` there raises a prompt nothing displays and nothing
    # answers, and the step waits forever. Fail with the remedy instead.
    if (-not (Test-YurunaCanPrompt)) {
        throw ((Format-YurunaOperatorMessage -Key 'exceptions.host_ce186b06237fbe4d'))
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_b5a36047ba736ed1')
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_674dd7c6c0448e92')
    }
}

<#
.SYNOPSIS
    Run networksetup with sudo iff not already root.
#>
function Invoke-MacNetworksetup {
    param([string[]]$Arguments)
    if ((Get-UtmCurrentUid) -eq '0') {
        & networksetup @Arguments | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_653d228ea35c1f2c' -Arguments @{ join = "$($Arguments -join ' ')"; lASTEXITCODE = "$LASTEXITCODE" }) }
        return
    }
    # -n, because Invoke-MacElevationIfNeeded has already established that root
    # is reachable and every caller runs a short sequence of these. If the
    # timestamp expires mid-sequence the honest outcome is an exit code: a
    # password prompt here lands on a console the caller may not own, and the
    # operator was told they would be asked once.
    & sudo -n networksetup @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d13b1c09a5291094' -Arguments @{ join = "$($Arguments -join ' ')"; lASTEXITCODE = "$LASTEXITCODE" }) }
}

<#
.SYNOPSIS
    Apply the proxy via networksetup and write the yuruna marker.
#>
function Set-MacHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][hashtable]$ProxyParts,
        [Parameter(Mandatory)][string]$NetworkService
    )
    $h = $ProxyParts.Host; $p = $ProxyParts.Port
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_79c77d5e8acb27cf' -Arguments @{ networkService = "$NetworkService" }), (Format-YurunaOperatorMessage -Key 'host.operator_ed3c547320b2c6d6' -Arguments @{ h = "${h}"; p = "${p}" }))) {
        return
    }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'localhost', '127.0.0.1', '*.local', '169.254/16', '192.168.64.*')
    $markerPath = Get-MacProxyMarkerPath
    $markerDir  = Split-Path -Parent $markerPath
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    Set-Content -LiteralPath $markerPath -Value $NetworkService -NoNewline -Encoding ascii
}

<#
.SYNOPSIS
    Restore macOS networksetup proxy state from the backup hashtable.
#>
function Restore-MacHostProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $svc = [string]$State.networkService
    if (-not $svc) { return }
    $web = $State.webProxy
    $ssl = $State.secureWebProxy
    if ($web.Server -and $web.Port) {
        Invoke-MacNetworksetup @('-setwebproxy', $svc, [string]$web.Server, [string]$web.Port)
    }
    if ($ssl.Server -and $ssl.Port) {
        Invoke-MacNetworksetup @('-setsecurewebproxy', $svc, [string]$ssl.Server, [string]$ssl.Port)
    }
    $webOn = ($web.Enabled -match '^(Yes|On)$')
    $sslOn = ($ssl.Enabled -match '^(Yes|On)$')
    Invoke-MacNetworksetup @('-setwebproxystate',       $svc, ($webOn ? 'on' : 'off'))
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $svc, ($sslOn ? 'on' : 'off'))
    if ($State.bypassDomains -and $State.bypassDomains.Count -gt 0) {
        Invoke-MacNetworksetup (@('-setproxybypassdomains', $svc) + @($State.bypassDomains))
    } else {
        Invoke-MacNetworksetup @('-setproxybypassdomains', $svc, 'Empty')
    }
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Turn web and securewebproxy off without restoring backup.
#>
function Disable-MacHostProxy {
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Aggressively wipe networksetup proxy state and the marker file.
#>
function Remove-MacHostProxy {
    # --- REGION: https://yuruna.link/42d69dfa-0021
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Module-private helper; public Remove-HostProxy gates ShouldProcess.')]
    [CmdletBinding()]
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'Empty')
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

# --- REGION: Screenshot helpers
# UTM-side screenshot capture: VNC framebuffer first (real pixels even when
# UTM's NSWindow stays black), then CGWindowList screencapture -l <id>,
# then bounds-based screencapture -R fallback. Per-VM VNC port (5910..5989)
# derived deterministically from the VM name so producer (config.plist
# template) and consumers (capture, keystrokes) agree without a sidecar.

<#
.SYNOPSIS
    Return a deterministic VNC display number (10..89) from the VM name.
#>
function Get-VncDisplayForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Displays 0..9 reserved for legacy/default callers.
    $h = 0
    foreach ($ch in $VMName.ToCharArray()) {
        $h = (($h * 131) + [int][char]$ch) -band 0x3FFFFFFF
    }
    return ($h % 80) + 10
}

<#
.SYNOPSIS
    A bundle's config.plist as parsed JSON, read through one bounded plutil
    call; Readable is $false when the read did not complete or did not parse.
.DESCRIPTION
    plutil talks to nothing but the file, yet it is still a process that can
    stall on a wedged filesystem, and every caller of this sits on a path
    that must answer in seconds.
#>
function Read-UtmBundleConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        $Deadline
    )
    $read = Invoke-UtmHostTool -Tool 'plutil' -ArgumentList @('-convert', 'json', '-o', '-', $ConfigPath) -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline
    $json = $null
    if ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0 -and "$($read.StdOut)".Trim()) {
        try { $json = "$($read.StdOut)" | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    }
    return [pscustomobject]@{ Readable = [bool]($null -ne $json); Json = $json; Reason = $(if ($read.DeadlineExhausted) { 'deadline-exhausted' } elseif ($read.TimedOut) { 'timeout' } elseif ($null -ne $json) { 'read' } else { 'failed' }) }
}

<#
.SYNOPSIS
    Return the VNC display recorded in the VM bundle's config.plist, or -1
    when the bundle has no -vnc argument (or cannot be read).
.DESCRIPTION
    The bundle is the authority on which port a VM actually listens on:
    the display is written into QEMU's AdditionalArguments when the VM is
    built, and Start-UtmVM may rewrite it to avoid a collision. A caller
    that derived the port from the VM name instead would aim a screenshot
    at whatever else happens to hold that port.
#>
function Get-VncDisplayFromBundle {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return -1 }
    try {
        $config = Read-UtmBundleConfig -ConfigPath $configPath
        if (-not $config.Readable) { return -1 }
        $qemuArgs = @($config.Json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Value shape: 127.0.0.1:<display>[,share=force-shared]
            if ("$($qemuArgs[$i + 1])" -match ':(\d+)') { return [int]$Matches[1] }
        }
    } catch {
        Write-Debug "Get-VncDisplayFromBundle: could not read $configPath`: $($_.Exception.Message)"
    }
    return -1
}

<#
.SYNOPSIS
    Return a VM bundle's network descriptor -- plist path, network mode and
    MAC -- or $null when the host has no such bundle.
.DESCRIPTION
    The bundle is the authority on how a VM is attached and what MAC it
    boots with: both are fixed when it is BUILT, and the guest's seed
    carries addresses derived for them, so what the bundle says -- not what
    this host's uplink would choose today -- is what the running VM is
    actually on. Address discovery reads both together because it needs
    both to pick a rung, and one plutil invocation answers for the pair.
.PARAMETER TimeoutSeconds
    Cap for the plutil read.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] with VMName, PlistPath, Mode ('Bridged' / 'Shared' /
    '' when unreadable), MacAddress ('' when absent) and Readable ($false
    when the plist read did not complete), or $null.
#>
function Get-UtmBundleNetwork {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        $Deadline
    )
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    $mode = ''
    $mac  = ''
    $config = Read-UtmBundleConfig -ConfigPath $configPath -TimeoutSeconds $TimeoutSeconds -Deadline $Deadline
    if ($config.Readable) {
        try {
            $nic  = @($config.Json.Network)[0]
            $mode = "$($nic.Mode)".Trim()
            $mac  = "$($nic.MacAddress)".Trim()
        } catch {
            Write-Debug "Get-UtmBundleNetwork: could not read $configPath`: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        VMName     = $VMName
        PlistPath  = $configPath
        Mode       = $mode
        MacAddress = $mac
        Readable   = [bool]$config.Readable
    }
}

<#
.SYNOPSIS
    Return the network mode recorded in a VM bundle's config.plist
    ('Bridged' / 'Shared'), or '' when the bundle or the key is absent.
.DESCRIPTION
    A caller compares this against what the host's uplink would choose today
    to detect a host that has moved between Wi-Fi and Ethernet since the VM
    was created, and decides whether to forward host ports (Shared) or
    expect a LAN address (Bridged).
#>
function Get-UtmNetworkModeFromBundle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork) { return '' }
    return [string]$bundleNetwork.Mode
}

<#
.SYNOPSIS
    Write $Display into the VM bundle's -vnc QEMU argument. Returns $true
    when the bundle now carries that display.
#>
function Set-VncDisplayInBundle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$Display
    )
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_54d6a4d70cca189d' -Arguments @{ display = "$Display" }))) { return $false }
    try {
        $config = Read-UtmBundleConfig -ConfigPath $configPath
        if (-not $config.Readable) { return $false }
        $qemuArgs = @($config.Json.QEMU.AdditionalArguments)
        for ($i = 0; $i -lt $qemuArgs.Count - 1; $i++) {
            if ("$($qemuArgs[$i])" -ne '-vnc') { continue }
            # Preserve whatever suffix the builder attached (share=force-shared
            # lets the screenshot client attach while the console is open);
            # only the display number changes.
            $suffix = ''
            if ("$($qemuArgs[$i + 1])" -match ':\d+(,.*)$') { $suffix = $Matches[1] }
            $value = "127.0.0.1:${Display}${suffix}"
            $null = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :QEMU:AdditionalArguments:$($i + 1) $value", $configPath) -TimeoutSeconds 10
            return ((Get-VncDisplayFromBundle -VMName $VMName) -eq $Display)
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6877083d4624d081' -Arguments @{ configPath = "$configPath"; message = "$($_.Exception.Message)" })
    }
    return $false
}

<#
.SYNOPSIS
    Write the deterministic MAC for $VMName into that VM bundle's first NIC.
    Returns $true when the bundle now carries that address.
.DESCRIPTION
    See https://yuruna.link/4220a755-000a
    for the address itself. A bundle is normally written at BUILD time with the
    identity its guest keeps for life, and then this rewrite is never needed.
    It exists for the bundle written with the per-kind slot name instead (a
    guest whose sequence declares no hostname of its own): that address belongs
    to the slot, and a promoted bundle sitting on it leaves the next guest built
    under that name asking for one already in use. Rename-VM decides whether it
    applies -- moving a bundle that is already on its own identity re-DHCPs a
    guest whose state may record the address it was built on.

    UTM does not refuse the duplicate the way virt-install does: the VMs build
    and start, and the collision surfaces later as guests on one segment
    answering for each other's address, which reads as a network fault rather
    than a naming one. The bundle is also where the guest's DHCP identity ends
    up, because the seed pins dhcp-identifier to the MAC.

    Only the first NIC is rewritten -- a second interface needs a second
    DISTINCT address, not this one twice.
#>
function Set-GuestMacInBundle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $configPath = "$HOME/yuruna/guest.nosync/$VMName.utm/config.plist"
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    $mac = Get-YurunaGuestMacAddress -VMName $VMName
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_05af7f58bfd72dce' -Arguments @{ mac = "$mac" }))) { return $false }
    try {
        $write = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Network:0:MacAddress $mac", $configPath) -TimeoutSeconds 10
        if (-not (Test-UtmBoundedResultComplete -Result $write) -or $write.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_19d6ab966bbc187c' -Arguments @{ configPath = "$configPath" })
            return $false
        }
        $written = (Get-UtmBundleNetwork -VMName $VMName).MacAddress
        return ($written -and $written -ieq $mac)
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0311eef6cb69b548' -Arguments @{ configPath = "$configPath"; message = "$($_.Exception.Message)" })
    }
    return $false
}

<#
.SYNOPSIS
    $true when nothing is listening on 127.0.0.1:$Port right now.
.DESCRIPTION
    A real bind, not a connect probe: QEMU fails to start when it cannot
    bind, and only a bind tells us whether it will be able to.
#>
function Test-VncPortFree {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { Write-Debug "Test-VncPortFree: listener stop on $Port`: $($_.Exception.Message)" } }
    }
}

<#
.SYNOPSIS
    Return a VNC display in 10..89 whose port is free, preferring $Preferred.
    Returns -1 when every display in the range is taken.
#>
function Find-FreeVncDisplay {
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Preferred = -1, [int[]]$ExcludeDisplays = @())
    # A bind test only sees VMs that are running RIGHT NOW. When the caller
    # is allocating for a fleet whose members are stopped -- or with UTM
    # quit entirely -- every port answers "free" and two VMs happily take
    # the same one. ExcludeDisplays carries the displays already spoken for
    # by other bundles so the choice holds once they all start.
    $excluded = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($d in $ExcludeDisplays) { $null = $excluded.Add([int]$d) }
    if ($Preferred -ge 10 -and $Preferred -le 89 -and
        -not $excluded.Contains($Preferred) -and (Test-VncPortFree -Port (5900 + $Preferred))) {
        return $Preferred
    }
    for ($d = 10; $d -le 89; $d++) {
        if (-not $excluded.Contains($d) -and (Test-VncPortFree -Port (5900 + $d))) { return $d }
    }
    return -1
}

<#
.SYNOPSIS
    Return the VNC displays recorded in every .utm bundle except $ExcludeVMName.
.DESCRIPTION
    The bundles on disk are the only durable record of which display each
    VM will ask QEMU for, so they are what a new allocation has to avoid.
#>
function Get-ClaimedVncDisplay {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([string]$ExcludeVMName)
    $guestDir = "$HOME/yuruna/guest.nosync"
    if (-not (Test-Path -LiteralPath $guestDir)) { return [int[]]@() }
    $displays = @()
    foreach ($bundle in (Get-ChildItem -LiteralPath $guestDir -Filter '*.utm' -Directory -ErrorAction SilentlyContinue)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($bundle.Name)
        if ($name -eq $ExcludeVMName) { continue }
        $display = Get-VncDisplayFromBundle -VMName $name
        if ($display -ge 0) { $displays += $display }
    }
    return [int[]]$displays
}

<#
.SYNOPSIS
    Return the VNC TCP port (5910..5989) for the given VM.
.DESCRIPTION
    The bundle's own -vnc argument wins: Start-UtmVM resolves the display
    at start time, so the name-derived value is only the seed, not the
    answer. Falling back to the hash keeps callers working for a VM that
    has no bundle on this host (or none yet).
#>
function Get-VncPortForVm {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    $fromBundle = Get-VncDisplayFromBundle -VMName $VMName
    if ($fromBundle -ge 0) { return 5900 + $fromBundle }
    return 5900 + (Get-VncDisplayForVm -VMName $VMName)
}

# C# helper for a hot byte-swap loop (BGRX framebuffer -> P6 PPM).
# Pure-PowerShell over a 1920x1080 buffer is multiple seconds; compiled
# version is tens of ms. Idempotent via type-presence check.
if (-not ('YurunaVncPixels' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class YurunaVncPixels {
    public static void BgrxToRgb(byte[] src, byte[] dst, int dstOffset) {
        int n = src.Length / 4;
        for (int i = 0; i < n; i++) {
            int s = i * 4;
            int d = dstOffset + i * 3;
            dst[d]     = src[s + 2]; // R
            dst[d + 1] = src[s + 1]; // G
            dst[d + 2] = src[s];     // B
        }
    }
}
'@
}

<#
.SYNOPSIS
    Read exactly $Count bytes from $Stream into a fresh byte[]. Uses
    Stream.ReadExactly (.NET 7+) so the read loop runs inside the runtime
    instead of being driven from PowerShell -- measured against a 1920x1080
    QEMU VNC capture (7.9 MB payload), the runtime-side loop completes
    in ~150 ms while the PowerShell-side equivalent took ~10.6 s because
    QEMU's RFB encoder emits the pixel rect in many small frames and
    every PowerShell loop iteration paid scriptblock-invocation overhead.
.NOTES
    Stream.ReadExactly throws EndOfStreamException on premature EOF; we
    wrap that to match the previous error-message style for log parity.
#>
function Read-VncScreenshotBuffer {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buf = [byte[]]::new($Count)
    try {
        $Stream.ReadExactly($buf, 0, $Count)
    } catch [System.IO.EndOfStreamException] {
        throw "VNC connection closed before $Count bytes were read"
    }
    return $buf
}

<#
.SYNOPSIS
    Capture a VNC framebuffer to PNG via raw RFB 3.8 protocol.
#>
function Get-VncScreenshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$OutputPath,
        [int]$Port = 5900,
        [int]$TimeoutMs = 5000
    )
    $tcp = $null
    $ppmPath = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect('127.0.0.1', $Port)
        $stream = $tcp.GetStream()
        # RFB 3.8 handshake
        $null = Read-VncScreenshotBuffer -Stream $stream -Count 12
        $stream.Write([System.Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"), 0, 12)
        $countBuf = Read-VncScreenshotBuffer -Stream $stream -Count 1
        $numTypes = [int]$countBuf[0]
        if ($numTypes -eq 0) { throw 'VNC server refused (0 security types offered)' }
        $typesBuf = Read-VncScreenshotBuffer -Stream $stream -Count $numTypes
        if ($typesBuf -notcontains 1) { throw "VNC server does not offer None-auth (got: $($typesBuf -join ','))" }
        $stream.WriteByte(1)
        $secResult = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($secResult[0] -ne 0 -or $secResult[1] -ne 0 -or $secResult[2] -ne 0 -or $secResult[3] -ne 0) {
            throw "VNC security handshake failed"
        }
        $stream.WriteByte(1) # ClientInit shared=1
        $initBuf = Read-VncScreenshotBuffer -Stream $stream -Count 24
        $w = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[1], $initBuf[0]), 0)
        $h = [int][BitConverter]::ToUInt16([byte[]]@($initBuf[3], $initBuf[2]), 0)
        $nameLen = [int][BitConverter]::ToInt32([byte[]]@($initBuf[23], $initBuf[22], $initBuf[21], $initBuf[20]), 0)
        $bpp = [int]$initBuf[4]
        $bigEndian = [int]$initBuf[6]
        if ($nameLen -gt 0) { $null = Read-VncScreenshotBuffer -Stream $stream -Count $nameLen }
        if ($bpp -ne 32)    { throw "Unsupported bpp=$bpp (this capture path assumes 32bpp BGRX)" }
        if ($bigEndian -ne 0) { throw "Unsupported big-endian framebuffer (this path assumes little-endian BGRX)" }
        $req = [byte[]]::new(10)
        $req[0] = 3
        $req[1] = 0
        $req[6] = [byte](($w -shr 8) -band 0xFF); $req[7] = [byte]($w -band 0xFF)
        $req[8] = [byte](($h -shr 8) -band 0xFF); $req[9] = [byte]($h -band 0xFF)
        $stream.Write($req, 0, 10)
        $updHdr = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($updHdr[0] -ne 0) { throw "Expected FramebufferUpdate (0), got message type $($updHdr[0])" }
        $nRects = [int][BitConverter]::ToUInt16([byte[]]@($updHdr[3], $updHdr[2]), 0)
        $fbBytes = $w * $h * 4
        $fb = [byte[]]::new($fbBytes)
        for ($r = 0; $r -lt $nRects; $r++) {
            $rectHdr = Read-VncScreenshotBuffer -Stream $stream -Count 12
            $rx = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[1],  $rectHdr[0]),  0)
            $ry = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[3],  $rectHdr[2]),  0)
            $rw = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[5],  $rectHdr[4]),  0)
            $rh = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[7],  $rectHdr[6]),  0)
            $enc = [BitConverter]::ToInt32([byte[]]@($rectHdr[11], $rectHdr[10], $rectHdr[9], $rectHdr[8]), 0)
            if ($enc -ne 0) { throw "Unsupported VNC encoding $enc for rect $r (need Raw=0)" }
            $rectBytes = $rw * $rh * 4
            if ($rx -eq 0 -and $ry -eq 0 -and $rw -eq $w -and $rh -eq $h) {
                # Full-frame rect (the common case for an initial
                # FramebufferUpdateRequest after a fresh handshake): read
                # straight into $fb so we skip the per-row PowerShell copy
                # loop. Without this fast path, a 1080-row loop of
                # [Array]::Copy in PowerShell takes ~10 s on a 1920x1080
                # framebuffer because each iteration pays scriptblock
                # dispatch overhead -- the bytes arrive in <50 ms, the
                # loop is the bottleneck.
                $stream.ReadExactly($fb, 0, $rectBytes)
            } else {
                # Sub-rect (would occur if we ever sent incremental=1):
                # the row-by-row PowerShell copy is still slow but
                # tolerable because the sub-rect is small. Kept as
                # fallback so the function remains correct under
                # encodings that emit multiple rects.
                $pixels = Read-VncScreenshotBuffer -Stream $stream -Count $rectBytes
                for ($row = 0; $row -lt $rh; $row++) {
                    $srcOff = $row * $rw * 4
                    $dstOff = (($ry + $row) * $w + $rx) * 4
                    [Array]::Copy($pixels, $srcOff, $fb, $dstOff, $rw * 4)
                }
            }
        }
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("P6`n$w $h`n255`n")
        $ppm = [byte[]]::new($headerBytes.Length + $w * $h * 3)
        [Array]::Copy($headerBytes, 0, $ppm, 0, $headerBytes.Length)
        [YurunaVncPixels]::BgrxToRgb($fb, $ppm, $headerBytes.Length)
        $ppmPath = "$OutputPath.ppm"
        [System.IO.File]::WriteAllBytes($ppmPath, $ppm)
        $sipsErr = & sips -s format png $ppmPath --out $OutputPath 2>&1
        if (-not (Test-Path $OutputPath)) {
            Write-Debug "      VNC capture: sips conversion failed: $sipsErr"
            return $false
        }
        return $true
    } catch {
        Write-Debug "      VNC capture failed: $_"
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { Write-Debug "      VNC capture: tcp.Close() failed: $_" } }
        if ($ppmPath -and (Test-Path $ppmPath)) {
            Remove-Item -LiteralPath $ppmPath -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Capture the UTM VM's display (VNC then screencapture fallbacks).
#>
function Get-UtmScreenshot {
    param([string]$VMName, [string]$OutputPath)
    $vncPort = Get-VncPortForVm -VMName $VMName
    if (Get-VncScreenshot -OutputPath $OutputPath -Port $vncPort) {
        Write-Debug "      Captured via VNC (port $vncPort, VM $VMName)"
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    if (-not $script:ScreencaptureChecked) {
        $script:ScreencaptureChecked = $true
        $testFile = Join-Path ([System.IO.Path]::GetTempPath()) "screencapture_test_$PID.png"
        $testErr = & screencapture -x "$testFile" 2>&1
        if (Test-Path $testFile) {
            $fileSize = (Get-Item $testFile).Length
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            if ($fileSize -lt 100) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_63d92a5157f8b436')
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_baea4919b222d9c9')
                $script:ScreencaptureWorks = $false
            } else {
                $script:ScreencaptureWorks = $true
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0b1218dff32f3243' -Arguments @{ testErr = "$testErr" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2401d57af4c6cd28')
            $script:ScreencaptureWorks = $false
        }
    }
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowIdScript = @"
ObjC.import('CoreGraphics');
ObjC.import('CoreFoundation');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        result = '' + ObjC.unwrap(w.kCGWindowNumber);
        break;
    }
}
result;
"@
    $windowIdScript = $windowIdScript -replace '__VMNAME__', $safeVMName
    $windowIdResult = & osascript -l JavaScript -e $windowIdScript 2>&1
    Write-Debug "      CG window ID query: $windowIdResult"
    $captured = $false
    if ($LASTEXITCODE -eq 0 -and "$windowIdResult" -match '^\d+$') {
        $captureErr = & screencapture -x -o -l "$windowIdResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $fileSize = (Get-Item $OutputPath).Length
            if ($fileSize -gt 100) {
                $captured = $true
            } else {
                Write-Debug "      screencapture -l produced small file ($fileSize bytes), trying -R fallback"
                Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Debug "      screencapture -l failed: $captureErr"
        }
    }
    if (-not $captured) {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query: $boundsResult"
        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^\d+,\d+,\d+,\d+$') {
            $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
            if (Test-Path $OutputPath) {
                $captured = $true
                Write-Debug "      Captured via -R (window may include overlapping content)"
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_52bc6c4a54214905' -Arguments @{ boundsResult = "$boundsResult"; captureErr = "$captureErr" })
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_663cbbf805c2b958' -Arguments @{ vMName = "$VMName"; windowIdResult = "$windowIdResult"; boundsResult = "$boundsResult" })
        }
    }
    if ($captured) {
        Write-Debug "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_46fe17589543a111' -Arguments @{ vMName = "$VMName" })
    return $null
}

<#
.SYNOPSIS
    Capture the UTM window with metadata (id, origin, scale) for clicks.
#>
function Get-UtmWindowScreenshot {
    param([string]$VMName, [string]$OutputPath)
    if ($script:ScreencaptureWorks -eq $false) { return $null }
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowScript = @"
ObjC.import('CoreGraphics');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        var id = ObjC.unwrap(w.kCGWindowNumber);
        var b  = ObjC.unwrap(w.kCGWindowBounds);
        result = '' + id + ',' + b.X + ',' + b.Y + ',' + b.Width + ',' + b.Height;
        break;
    }
}
result;
"@
    $windowScript = $windowScript -replace '__VMNAME__', $safeVMName
    $windowResult = & osascript -l JavaScript -e $windowScript 2>&1
    Write-Debug "      CG window query (window+bounds): $windowResult"
    $windowId = 0
    $originX  = 0.0
    $originY  = 0.0
    $pointW   = 0.0
    $pointH   = 0.0
    $cgOk     = $false
    if ($LASTEXITCODE -eq 0 -and "$windowResult" -match '^\d+,-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
        $parts    = "$windowResult".Split(',')
        $windowId = [int]$parts[0]
        $originX  = [double]$parts[1]
        $originY  = [double]$parts[2]
        $pointW   = [double]$parts[3]
        $pointH   = [double]$parts[4]
        $cgOk     = $true
    } else {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query (fallback): $boundsResult"
        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
            $parts   = "$boundsResult".Split(',')
            $originX = [double]$parts[0]
            $originY = [double]$parts[1]
            $pointW  = [double]$parts[2]
            $pointH  = [double]$parts[3]
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4ec0afe642270f86' -Arguments @{ vMName = "$VMName"; windowResult = "$windowResult"; boundsResult = "$boundsResult" })
            return $null
        }
    }
    if ($cgOk) {
        $captureErr = & screencapture -x -o -l "$windowId" "$OutputPath" 2>&1
    } else {
        $region = "{0},{1},{2},{3}" -f $originX, $originY, $pointW, $pointH
        $captureErr = & screencapture -x -R "$region" "$OutputPath" 2>&1
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d8b4fab086012607' -Arguments @{ vMName = "$VMName"; captureErr = "$captureErr" })
        return $null
    }
    $fileSize = (Get-Item $OutputPath).Length
    if ($fileSize -lt 100) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_88b70a1a42a7df41' -Arguments @{ fileSize = "${fileSize}" })
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $fs = [IO.File]::OpenRead($OutputPath)
        try {
            $buf = New-Object byte[] 24
            [void]$fs.Read($buf, 0, 24)
        } finally { $fs.Dispose() }
        $pixelW = ([int]$buf[16] -shl 24) -bor ([int]$buf[17] -shl 16) -bor ([int]$buf[18] -shl 8) -bor [int]$buf[19]
        $pixelH = ([int]$buf[20] -shl 24) -bor ([int]$buf[21] -shl 16) -bor ([int]$buf[22] -shl 8) -bor [int]$buf[23]
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6f6bbc018b383fb2' -Arguments @{ outputPath = "$OutputPath"; value = "$_" })
        return $null
    }
    $scale = if ($pointW -gt 0) { $pixelW / $pointW } else { 1.0 }
    Write-Debug "      UTM window: id=$windowId origin=($originX,$originY) point=${pointW}x${pointH} pixel=${pixelW}x${pixelH} scale=$scale"
    return @{
        ImagePath   = $OutputPath
        WindowId    = $windowId
        OriginX     = $originX
        OriginY     = $originY
        Width       = $pixelW
        Height      = $pixelH
        PointWidth  = $pointW
        PointHeight = $pointH
        Scale       = $scale
    }
}

# --- REGION: VM lifecycle
function New-VM {
    <#
    .SYNOPSIS
        Create a guest VM by running the per-guest New-VM.ps1 script.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-PerGuestNewVm, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyServiceUrl,
        # Planner-cascaded username override; forwarded only when the
        # per-guest script declares -Username (introspected below).
        [string]$Username,
        # Planner-cascaded guest hostname (variables.hostname); same
        # declare-or-drop forwarding rule as -Username.
        [string]$Hostname,
        # Planner-cascaded VM sizing (variables.memoryStartupBytes /
        # variables.cores); same declare-or-drop forwarding rule as -Username.
        [string]$MemoryStartupBytes,
        [string]$Cores,
        # Planner-cascaded nested-virtualization request
        # (variables.exposeVirtualizationExtensions); same declare-or-drop
        # forwarding rule as -Username. Declared for host-contract parity: no
        # UTM guest script consumes it today (Apple's Virtualization framework
        # offers no per-VM nested-virtualization knob), so the dispatcher
        # drops it on the Verbose stream.
        [string]$ExposeVirtualizationExtensions
    )
    # Thin wrapper over the shared per-guest runner; the host subdir is the
    # only platform variable. Splatting $PSBoundParameters preserves the
    # conditional -CachingProxyServiceUrl/-Username/-Hostname/-MemoryStartupBytes/-Cores/
    # -ExposeVirtualizationExtensions
    # forwarding (the runner checks ContainsKey) and propagates -WhatIf/-Confirm.
    Invoke-PerGuestNewVm -HostSubdir 'host/macos.utm' @PSBoundParameters
}

<#
.SYNOPSIS
    Start a guest VM previously created by New-VM.
#>
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef'))) { return @{ success = $false; errorMessage = 'WhatIf' } }
    return Start-UtmVM -VMName $VMName -Confirm:$false
}

<#
.SYNOPSIS
    Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
#>
function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? (Format-YurunaOperatorMessage -Key 'host.operator_872a5355019f83c5') : (Format-YurunaOperatorMessage -Key 'host.operator_156e139837bd477d')))) { return $false }
    if ($Force) { return [bool](Stop-VMForce -VMName $VMName -Confirm:$false) }
    return [bool](Stop-UtmVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Force-stop a UTM VM via `utmctl stop --kill`, bounded by -StopTimeoutSeconds.
.DESCRIPTION
    --kill hard-kills the VM process instead of sending the power-off event,
    so the qcow2 write lock is released without waiting on an ACPI shutdown
    that a busy or mid-reboot guest may ignore. The whole call is bounded by
    -StopTimeoutSeconds (and by -Deadline when one is given). $true only for
    a call that completed, exited 0 and printed no Apple Event failure:
    utmctl exits 0 on a denial, so the exit code alone would report a kill
    that never reached UTM.
.PARAMETER StopTimeoutSeconds
    Cap for the whole call, clamped to 1..600. The dialog-watchdog stop that
    precedes the kill gets a short slice of it -- two seconds at most, half
    the cap at most -- and the kill the whole seconds that remain, never
    fewer than one: a kill that is never attempted helps nobody, so the call
    can end up to a fraction of a second past the cap, not twice the cap.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
#>
function Stop-VMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20,
        $Deadline
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_8ba70db3f3e461cb'))) { return $false }
    $cap = [Math]::Max(1, [Math]::Min(600, $StopTimeoutSeconds))
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-UtmDialogWatchdog -Deadline (Get-UtmChildDeadline -Milliseconds ([Math]::Min([long]2000, [long]$cap * 500)) -Parent $Deadline)
    $killCap = [int][Math]::Max(1, $cap - [Math]::Floor($stopwatch.ElapsedMilliseconds / 1000.0))
    $kill = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName -Kill -TimeoutSeconds $killCap -Deadline $Deadline
    return [bool]($kill.OutcomeKnown -and $kill.ExitCode -eq 0 -and $kill.FailureKind -eq 'none')
}

<#
.SYNOPSIS
    Remove a guest VM and its on-disk artifacts.
#>
function Remove-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_12924e738438f274'))) { return $false }
    return [bool](Remove-UtmTestVM -VMName $VMName -Confirm:$false)
}

<#
.SYNOPSIS
    Return the names of every VM registered with UTM, optionally filtered
    to those starting with one of $Prefix.
.DESCRIPTION
    Host-neutral inventory call (see the contract's VM inventory block).
    Every VM UTM knows about is returned regardless of run state, so a
    caller sweeping by prefix removes stopped leftovers as well as
    running ones.

    THROWS when utmctl cannot reach UTM.app rather than returning an
    empty list. utmctl exits 0 and prints its error to stderr when Apple
    Events are denied (OSStatus -1743, typical from an SSH session or a
    process without Automation access), when a request times out (-1712),
    and for other Apple Event faults besides -- so an exit-code check alone
    reads "cannot ask" as "nothing registered". A sweep that accepted that
    empty list would report a clean host, and the orphan-file pass behind
    it would delete bundles UTM still has registered.

    Matched on ANY Apple Event wording the driver recognizes -- any OSStatus
    code, a denial, a timeout, an SSH session -- rather than an enumerated
    few. The set that can appear here is open, the consequence of missing one
    is deleting a VM's disk, and there is no OSStatus value whose correct
    reading is "believe the empty list". A listing that did not finish
    draining or was cut at the capture cap is incomplete and throws too.
.PARAMETER Prefix
    Zero or more name prefixes. A VM is returned when its name starts
    with any of them. Omit (or pass none) to return every VM.
.OUTPUTS
    [string[]] matching VM names; empty when none match.
#>
function Get-VMName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    $resolver = Resolve-UtmctlExecutable
    if ($resolver.Source -eq 'missing') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_81fb05f8b6924bce')
    }
    $listing = Invoke-UtmctlProbe -Arguments @('list') -UtmctlPath $resolver.Path
    $text = "$($listing.StdOut)`n$($listing.StdErr)".Trim()
    if ($listing.TimedOut) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_76bccb579d55bc73')
    }
    if (-not $listing.Started -or $listing.ExitCode -ne 0 -or $listing.DrainTimedOut -or $listing.OutputTruncated -or
        (Get-UtmStartFailureKind -Text $text) -ne 'none') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_7c4b552da601ab61' -Arguments @{ text = "$text" })
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line -or $line -match '^-+$') { continue }
        # utmctl list is FIXED-COLUMN, not 2+-space delimited: the UUID
        # column is 36 chars plus a single pad space, so splitting on
        # \s{2,} merges UUID and Status into one 44-char field that never
        # matches a UUID and silently yields zero rows. Anchor on the UUID
        # and take the remainder as the name so names containing spaces
        # survive intact.
        if ($line -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
            $name = $matches[3].Trim()
            if ($name) { [void]$names.Add($name) }
        }
    }
    return Select-NameByPrefix -Name $names.ToArray() -Prefix $Prefix
}

<#
.SYNOPSIS
    Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
.DESCRIPTION
    'unknown' covers everything that is not a positively recognized answer:
    no utmctl on PATH or in the UTM bundle, a launch failure, a timeout, a
    denied Apple Event, "does not work from SSH", output that did not finish
    draining, or any other unrecognized answer. Only a completed response
    that names the VM as not found is 'absent'. Callers treat 'absent' as
    license to build or reuse a name (Start-CachingProxyServiceVM.ps1,
    Debug-TestSequence.ps1, Test.Orchestrator, Test.SnapshotManifest,
    Rename-VM's preconditions, Remove-UtmVMRegistration) and
    Restore-YurunaServiceVM treats it as "not built on this host" -- a probe
    UTM merely refused to answer must never produce that, least of all on a
    host whose UTM has stopped answering. Get-VMStateRecord returns the same
    answer with its reason.
#>
function Get-VMState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    return [string](Get-VMStateRecord -VMName $VMName).State
}

<#
.SYNOPSIS
    The VM's state as a record: the state Get-VMState returns, the raw
    status word, registration evidence and the reason.
.DESCRIPTION
    One bounded `utmctl status` call, classified by
    ConvertFrom-UtmctlStatusResult; Get-VMState and
    Get-UtmVMRegistrationState are both read from this record, so the state
    and the registration can never disagree about one answer. With -Deadline
    the call gets at most what the deadline has left, and nothing is
    launched when under one second remains.
.PARAMETER VMName
    The VM to read.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER TimeoutSeconds
    This call's own cap.
.OUTPUTS
    [pscustomobject] VMName, State ('running' | 'stopped' | 'absent' |
    'unknown'), RawState, Registration ('Registered' | 'Absent' | 'Unknown'),
    Reason ('observed' | 'not-found' | 'missing-client' | 'timeout' |
    'permission-denied' | 'no-session' | 'provider-error' | 'invalid-response'
    | 'deadline-exhausted'), ExitCode, ElapsedMs.
#>
function Get-VMStateRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        $Deadline,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $resolver = Resolve-UtmctlExecutable
    $probe = if ($resolver.Source -eq 'missing') {
        @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $false; DeadlineExhausted = $false }
    } else {
        Invoke-UtmctlProbe -Arguments @('status', $VMName) -TimeoutSeconds $TimeoutSeconds -UtmctlPath $resolver.Path -Deadline $Deadline
    }
    $classified = ConvertFrom-UtmctlStatusResult -Result $probe
    return [pscustomobject]@{
        PSTypeName   = 'Yuruna.UtmVMState'
        VMName       = $VMName
        State        = $classified.State
        RawState     = $classified.RawState
        Registration = $classified.Registration
        Reason       = $classified.Reason
        ExitCode     = [int]$probe['ExitCode']
        ElapsedMs    = $stopwatch.ElapsedMilliseconds
    }
}

<#
.SYNOPSIS
    Bounded, structured probe of UTM's control channel (record v1).
.DESCRIPTION
    Evaluated in order, each step bounded by the probe's own deadline (the
    smaller of -TimeoutSeconds and what -Deadline has left):
      1. utmctl on PATH or in the UTM bundle; none -> Undetermined/missing-client.
      2. the GUI session; anything but Aqua -> Undetermined/no-session, and
         utmctl is not invoked (from SSH it can only fail, or hang on a
         consent dialog nobody can see).
      3. the same-user UTM process census, with no Apple Event; positively
         no UTM and no helper -> Unresponsive/app-stopped, and utmctl is not
         invoked (an Apple Event to a UTM that is not running launches it).
      4. `utmctl list`: a recognized listing -> Responsive; Apple Event
         denial (-1743) -> Undetermined/permission-denied; an SSH refusal ->
         no-session; another OSStatus failure -> provider-error; output not
         fully drained or cut at the cap -> invalid-response even at exit 0;
         anything unrecognized -> invalid-response; a cap hit or -1712 -> a
         timeout candidate.
    A timeout is not, by itself, evidence that UTM is hung: an unanswered
    Automation consent dialog blocks the sender and looks exactly like one.
    Without -Corroborate a timeout is Undetermined/timeout. With
    -Corroborate the probe waits out -DialogWindowSeconds, re-reads the
    process census, and probes once more; only a second timeout, with UTM
    positively still running, no Apple Event denial, and this process's
    Automation subject among -RecordedAutomationSubject, is
    Unresponsive/timeout with corroborated=$true. A later denial, a missing
    session or an unclassified answer on the second probe invalidates the
    first. When the deadline cannot fit the window plus one probe the result
    stays Undetermined/timeout.

    Read-only: never writes, never repairs the utmctl link, never throws.
    Diagnostic text goes only to the private 'diagnostic' field.
.PARAMETER TimeoutSeconds
    Cap for each utmctl call.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER Corroborate
    Qualify a timeout as described above.
.PARAMETER DialogWindowSeconds
    How long a consent dialog is given to be answered before the second probe.
.PARAMETER RecordedAutomationSubject
    Automation subjects previously seen to complete a responsive round trip.
.PARAMETER IncludeInventory
    With a Responsive result, attach the parsed listing as 'inventory'.
.OUTPUTS
    [pscustomobject] PSTypeName 'Yuruna.VirtualizationProbe': schemaVersion,
    hostType, state, reason, started, timedOut, deadlineExhausted,
    corroborated, observedUtc, observedTick, elapsedMs, evidence
    {utmctlSource; sessionKind; appState; automationGrant; exitCode;
    drainTimedOut; outputTruncated}, diagnostic, automationSubject,
    inventory.
#>
function Test-VirtualizationResponsive {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20,
        $Deadline,
        [switch]$Corroborate,
        [ValidateRange(0, 600)][int]$DialogWindowSeconds = 120,
        [string[]]$RecordedAutomationSubject = @(),
        [switch]$IncludeInventory
    )
    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $facts = [ordered]@{
        utmctlSource = 'missing'; sessionKind = 'Unknown'; appState = 'unknown'; automationGrant = 'unknown'
        exitCode = -1; drainTimedOut = $false; outputTruncated = $false
        started = $false; timedOut = $false; deadlineExhausted = $false; corroborated = $false
        diagnostic = ''; subject = ''; inventory = $null
    }
    $emit = {
        param([string]$State, [string]$Reason)
        [pscustomobject]@{
            PSTypeName        = 'Yuruna.VirtualizationProbe'
            schemaVersion     = 1
            hostType          = 'host.macos.utm'
            state             = $State
            reason            = $Reason
            started           = [bool]$facts.started
            timedOut          = [bool]$facts.timedOut
            deadlineExhausted = [bool]$facts.deadlineExhausted
            corroborated      = [bool]$facts.corroborated
            observedUtc       = $observedUtc
            observedTick      = [long](Get-UtmClockTick -Deadline $Deadline)
            elapsedMs         = [long]$stopwatch.ElapsedMilliseconds
            evidence          = [pscustomobject]@{
                utmctlSource    = [string]$facts.utmctlSource
                sessionKind     = [string]$facts.sessionKind
                appState        = [string]$facts.appState
                automationGrant = [string]$facts.automationGrant
                exitCode        = [int]$facts.exitCode
                drainTimedOut   = [bool]$facts.drainTimedOut
                outputTruncated = [bool]$facts.outputTruncated
            }
            diagnostic        = ConvertTo-UtmDiagnosticText -Text ([string]$facts.diagnostic)
            automationSubject = [string]$facts.subject
            inventory         = $facts.inventory
        }
    }
    # One bounded utmctl list, classified; returns the probe-level verdict
    # ('responsive', 'timeout', or an Undetermined reason) and records facts.
    $probeOnce = {
        param($Window, [string]$UtmctlPath, [int]$CapSeconds, [bool]$WithInventory)
        $listing = Invoke-UtmctlProbe -Arguments @('list') -TimeoutSeconds $CapSeconds -UtmctlPath $UtmctlPath -Deadline $Window -Quiet
        $facts.timedOut        = $false
        $facts.started         = [bool]$listing['Started']
        $facts.exitCode        = [int]$listing['ExitCode']
        $facts.drainTimedOut   = [bool]$listing['DrainTimedOut']
        $facts.outputTruncated = [bool]$listing['OutputTruncated']
        $facts.diagnostic      = "$($listing['StdOut'])`n$($listing['StdErr'])"
        if ($listing['DeadlineExhausted']) { $facts.deadlineExhausted = $true; return 'deadline-exhausted' }
        if (-not $listing['Started']) { return 'missing-client' }
        if ($listing['TimedOut']) { $facts.timedOut = $true; return 'timeout' }
        $parsed = ConvertFrom-UtmctlListResult -Result $listing
        if ($parsed.Reason -eq 'timeout') { $facts.timedOut = $true; return 'timeout' }
        if (-not $parsed.Recognized) { return [string]$parsed.Reason }
        if ($WithInventory) { $facts.inventory = ConvertTo-UtmInventoryRecord -Parsed $parsed }
        return 'responsive'
    }
    try {
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            $facts.deadlineExhausted = $true
            return (& $emit 'Undetermined' 'deadline-exhausted')
        }
        $resolver = Resolve-UtmctlExecutable
        $facts.utmctlSource = $resolver.Source
        if ($resolver.Source -eq 'missing') { return (& $emit 'Undetermined' 'missing-client') }

        $facts.sessionKind = Get-UtmProbeSessionKind -Deadline $Deadline
        if ($facts.sessionKind -ne 'Aqua') { return (& $emit 'Undetermined' 'no-session') }

        $facts.subject = Get-UtmAutomationSubject -Deadline $Deadline
        if (Test-UtmAutomationSubjectQualified -Subject $facts.subject -RecordedSubject $RecordedAutomationSubject) { $facts.automationGrant = 'recorded' }

        $app = Get-UtmApplicationState -Deadline $Deadline
        $facts.appState = $app.State
        if ($app.State -eq 'absent') { return (& $emit 'Unresponsive' 'app-stopped') }

        $first = & $probeOnce $Deadline $resolver.Path $TimeoutSeconds ([bool]$IncludeInventory)
        if ($first -eq 'responsive') { return (& $emit 'Responsive' 'responsive') }
        if ($first -ne 'timeout') { return (& $emit 'Undetermined' $first) }
        if (-not $Corroborate) { return (& $emit 'Undetermined' 'timeout') }

        # Corroboration needs the whole dialog window and one more probe of
        # at least a second; a deadline that cannot fit both leaves the
        # timeout uncorroborated rather than cutting the window short.
        $windowMs = [long]$DialogWindowSeconds * 1000
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt ($windowMs + 1000)) {
            return (& $emit 'Undetermined' 'timeout')
        }
        if ($windowMs -gt 0) { $null = Wait-UtmInterval -Milliseconds ([int]$windowMs) -Deadline $Deadline }
        $again = Get-UtmApplicationState -Deadline $Deadline
        $facts.appState = $again.State
        if ($again.State -eq 'absent') { return (& $emit 'Unresponsive' 'app-stopped') }
        if ($again.State -ne 'running') { return (& $emit 'Undetermined' 'timeout') }
        $second = & $probeOnce $Deadline $resolver.Path $TimeoutSeconds ([bool]$IncludeInventory)
        if ($second -eq 'responsive') { return (& $emit 'Responsive' 'responsive') }
        if ($second -ne 'timeout') { return (& $emit 'Undetermined' $second) }
        $facts.timedOut = $true
        if ($facts.automationGrant -eq 'recorded') {
            $facts.corroborated = $true
            return (& $emit 'Unresponsive' 'timeout')
        }
        return (& $emit 'Undetermined' 'timeout')
    } catch {
        $facts.diagnostic = "$($_.Exception.Message)"
        return (& $emit 'Undetermined' 'invalid-response')
    }
}

<#
.SYNOPSIS
    Launch UTM for this user only when it is positively not running (the
    start-if-stopped repair for macOS), result record v1.
.DESCRIPTION
    Runs its own detection immediately before acting and never trusts an
    earlier probe: a GUI (Aqua) session, a known non-root uid, and a
    same-user process census that shows neither UTM nor its helpers. UTM
    already running for this user is 'already-running'; anything that cannot
    be established refuses and launches nothing. The launch is
    Start-UtmApplication -RequireGuiSession, whose outcomes map as
    launched -> started, already-running -> already-running, launch-failed
    -> failed, not-observed -> unknown, refused -> refused.

    Under -WhatIf only the bounded read-only detection runs and the outcome
    is 'preview'. Never prompts and never throws. -DependentVMName is
    accepted for the shared signature; UTM has no separate network service
    for it to decide on.
.PARAMETER TimeoutSeconds
    Budget for detection plus the launch wait.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER DependentVMName
    Guests whose restoration depends on this hypervisor; unused on macOS.
.OUTPUTS
    [pscustomobject] PSTypeName 'Yuruna.VirtualizationStartResult':
    schemaVersion, hostType, outcome ('started' | 'already-running' |
    'refused' | 'failed' | 'unknown' | 'unavailable' | 'preview'), reason,
    layout ('not-applicable'), actions [object[]], observedUtc, elapsedMs.
#>
function Start-VirtualizationServiceIfStopped {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        $Deadline,
        [string[]]$DependentVMName = @()
    )
    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $actions = [System.Collections.Generic.List[object]]::new()
    $emit = {
        param([string]$Outcome, [string]$Reason)
        [pscustomobject]@{
            PSTypeName    = 'Yuruna.VirtualizationStartResult'
            schemaVersion = 1
            hostType      = 'host.macos.utm'
            outcome       = $Outcome
            reason        = $Reason
            layout        = 'not-applicable'
            actions       = [object[]]$actions.ToArray()
            observedUtc   = $observedUtc
            elapsedMs     = [long]$stopwatch.ElapsedMilliseconds
        }
    }
    $addAction = {
        param([string]$Kind, [string]$Before, [string]$After, [string]$Result, [string]$Reason, $ExitCode, [bool]$TimedOut, [long]$ElapsedMs)
        $actions.Add([pscustomobject]@{
            target = 'UTM'; kind = $Kind; before = $Before; after = $After; result = $Result; reason = $Reason
            command = [string[]]@('open', '-a', 'UTM'); exitCode = $ExitCode; timedOut = $TimedOut; elapsedMs = $ElapsedMs
        })
    }
    try {
        if ($DependentVMName.Count -gt 0) { Write-Verbose "Start-VirtualizationServiceIfStopped on host.macos.utm: -DependentVMName is not used; UTM has no separate network service." }
        $budget = Get-UtmChildDeadline -Milliseconds ([long]$TimeoutSeconds * 1000) -Parent $Deadline
        if ((Get-YurunaDeadlineRemainingMs -Deadline $budget) -lt 1000) { return (& $emit 'refused' 'deadline-exhausted') }
        # No utmctl on PATH or in the bundle: UTM is not installed where this
        # driver expects it, and `open -a UTM` has nothing to launch.
        if ((Resolve-UtmctlExecutable).Source -eq 'missing') { return (& $emit 'refused' 'missing-client') }
        $prerequisite = Get-UtmControlPrerequisite -Deadline $budget
        $beforeState = if ($prerequisite.AppState) { [string]$prerequisite.AppState.State } else { 'unknown' }
        if (-not $prerequisite.Ok) {
            & $addAction 'app-launch' $beforeState $beforeState 'refused' $prerequisite.Reason $null $false 0
            return (& $emit 'refused' $prerequisite.Reason)
        }
        if (@($prerequisite.AppState.UtmPid).Count -gt 0) {
            & $addAction 'app-launch' 'running' 'running' 'already-running' 'already-running' $null $false 0
            return (& $emit 'already-running' 'already-running')
        }
        if (@($prerequisite.AppState.HelperPid).Count -gt 0) {
            & $addAction 'app-launch' 'running' 'running' 'refused' 'helpers-without-app' $null $false 0
            return (& $emit 'refused' 'helpers-without-app')
        }
        if (-not $PSCmdlet.ShouldProcess('UTM', (Format-YurunaOperatorMessage -Key 'host.utm_app_launch_action'))) {
            & $addAction 'app-launch' 'absent' 'absent' 'preview' 'preview' $null $false 0
            return (& $emit 'preview' 'preview')
        }
        $launchWait = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 600
        if ($null -eq $launchWait) { return (& $emit 'refused' 'deadline-exhausted') }
        $launch = Start-UtmApplication -Deadline $budget -LaunchWaitSeconds ([int]$launchWait) -RequireGuiSession -Confirm:$false -WhatIf:$false
        $afterState = if (@($launch.UtmPid).Count -gt 0) { 'running' } else { 'unknown' }
        $timedOut = ($launch.Outcome -eq 'not-observed')
        switch ($launch.Outcome) {
            'launched' {
                & $addAction 'app-launch' 'absent' 'running' 'started' 'started' $launch.LaunchExitCode $false $launch.ElapsedMs
                return (& $emit 'started' 'started')
            }
            'already-running' {
                & $addAction 'app-launch' 'absent' 'running' 'already-running' 'already-running' $null $false $launch.ElapsedMs
                return (& $emit 'already-running' 'already-running')
            }
            'launch-failed' {
                & $addAction 'app-launch' 'absent' $afterState 'failed' 'start-failed' $launch.LaunchExitCode $false $launch.ElapsedMs
                return (& $emit 'failed' 'start-failed')
            }
            'not-observed' {
                & $addAction 'app-launch' 'absent' $afterState 'unknown' 'not-observed' $launch.LaunchExitCode $timedOut $launch.ElapsedMs
                return (& $emit 'unknown' 'not-observed')
            }
            'deadline-exhausted' {
                & $addAction 'app-launch' 'absent' 'absent' 'refused' 'deadline-exhausted' $null $false $launch.ElapsedMs
                return (& $emit 'refused' 'deadline-exhausted')
            }
            default {
                & $addAction 'app-launch' 'absent' $afterState 'refused' ([string]$launch.Reason) $null $false $launch.ElapsedMs
                return (& $emit 'refused' ([string]$launch.Reason))
            }
        }
    } catch {
        Write-Verbose "Start-VirtualizationServiceIfStopped on host.macos.utm failed: $($_.Exception.Message)"
        return (& $emit 'failed' 'start-failed')
    }
}

<#
.SYNOPSIS
    Bring the named service VMs back to `started` after UTM.app has been
    quit and relaunched. Returns the names that did NOT come back.

.DESCRIPTION
    UTM saves the state of every running VM on its way out, so a VM that
    was `started` before UTM was quit is `suspended` when UTM returns --
    and it stays that way, because nothing resumes it automatically. For
    the service VMs that is not a cosmetic difference: guests take their
    packages through the caching proxy, the build uploads to the stash
    service, and the intent store is served by pool-control, so every one
    of those consumers fails for as long as the service sits suspended.

    `utmctl start` is also the resume verb -- on a suspended VM it
    restores the saved state instead of cold-booting -- so a caller can
    restore the pre-quit set without having to know whether UTM chose to
    suspend or to fully stop each one. That is the only start issued here:
    never Start-UtmVM or Start-VM, which delete the saved state to force a
    cold boot, and nothing here touches the bundle's saved state.

    A start is issued only from a positive 'stopped' reading; 'absent' and
    'unknown' are waited through and then reported, never started.

    Best-effort by design. A caller reaches this only after its own work
    is done, and a service that refuses to come back is something for the
    operator to see, not a reason to report that work as failed.

.PARAMETER VMName
    Names captured (while UTM was still up) as `started`. Empty is fine.

.PARAMETER TimeoutSeconds
    Per-VM budget covering re-registration, the start and its settle.

.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline) for the whole set: each
    VM gets the smaller of -TimeoutSeconds and what remains of it, so
    several services draw on one reserve instead of each adding its own.

.PARAMETER NoDialogWatchdog
    Do not start the UTM dialog watchdog around each start. A caller that
    must not auto-click dialogs passes it; a dialog that then blocks the
    start leaves the service unresolved.

.PARAMETER Detailed
    Emit one record per VM instead of the failed names.

.OUTPUTS
    [string[]] the names that did not return to `started`; empty on full
    success. Callers must normalize with `@(...)`. With -Detailed, one
    [pscustomobject] per VM: VMName, Outcome ('running' | 'resumed' |
    'absent' | 'unknown' | 'start-failed' | 'unresolved' |
    'deadline-exhausted'), Reason, Attempts.
#>
function Resume-YurunaServiceVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]], [pscustomobject])]
    param(
        [string[]]$VMName,
        [int]$TimeoutSeconds = 90,
        $Deadline,
        [switch]$NoDialogWatchdog,
        [switch]$Detailed
    )
    $names = @($VMName | Where-Object { $_ })
    if ($names.Count -eq 0) { return }
    $failed = New-Object System.Collections.Generic.List[string]
    $records = New-Object System.Collections.Generic.List[object]
    $note = {
        param([string]$Name, [string]$Outcome, [string]$Reason, [int]$Attempts)
        $records.Add([pscustomobject]@{ PSTypeName = 'Yuruna.ServiceVmResume'; VMName = $Name; Outcome = $Outcome; Reason = $Reason; Attempts = $Attempts })
        if ($Outcome -notin @('running', 'resumed')) { [void]$failed.Add($Name) }
    }
    foreach ($name in $names) {
        if (-not $PSCmdlet.ShouldProcess($name, (Format-YurunaOperatorMessage -Key 'host.operator_87abce329e878b18'))) { continue }
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_resume_deadline_exhausted' -Arguments @{ name = "$name" })
            & $note $name 'deadline-exhausted' 'deadline-exhausted' 0
            continue
        }
        # One deadline per VM, never later than the shared one: registration,
        # the start and its settle all draw on it.
        $vmDeadline = New-YurunaDeadline -TotalMilliseconds ([long][Math]::Max(0, $TimeoutSeconds) * 1000)
        if ($Deadline) { $vmDeadline = Get-UtmChildDeadline -Milliseconds ([long][Math]::Max(0, $TimeoutSeconds) * 1000) -Parent $Deadline }
        # UTM ingests its library asynchronously after launch, and utmctl
        # cannot address a VM until that finishes -- an immediate start
        # would be answered with "not found" and silently dropped. This
        # waits through BOTH 'absent' (not yet re-registered) and 'unknown'
        # (a probe that could not yet be read -- which a genuinely wedged
        # connection also produces): only a positive 'running' or 'stopped'
        # reading ends the wait, and a start is only ever attempted from a
        # positive 'stopped' reading, never from 'unknown'.
        # A read the deadline had no time left for never replaces an answer
        # already obtained.
        $reading = $null
        while (-not (Test-YurunaDeadlineExpired -Deadline $vmDeadline)) {
            $next = Get-VMStateRecord -VMName $name -Deadline $vmDeadline
            if (-not $reading -or $next.Reason -ne 'deadline-exhausted') { $reading = $next }
            if ($reading.State -eq 'running' -or $reading.State -eq 'stopped') { break }
            $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $vmDeadline
        }
        $state  = if ($reading) { [string]$reading.State } else { 'unknown' }
        $reason = if ($reading) { [string]$reading.Reason } else { 'deadline-exhausted' }
        if ($state -eq 'running') { & $note $name 'running' $reason 0; continue }
        if ($state -eq 'absent') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a986b71028c74af3' -Arguments @{ name = "$name"; timeoutSeconds = "$TimeoutSeconds" })
            & $note $name 'absent' $reason 0
            continue
        }
        if ($state -ne 'stopped') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_dbd4e4ba20849958' -Arguments @{ name = "$name"; timeoutSeconds = "$TimeoutSeconds" })
            & $note $name 'unknown' $reason 0
            continue
        }
        # Only a positive 'stopped' reading reaches here.
        # The watchdog is started HERE rather than left to the caller. The path
        # that leads to a resume quits UTM, and the Stop-VM on the way in reaps
        # any watchdog with it -- so this is the one place a service VM is
        # launched with nothing to dismiss the launch-time custom-QEMU-args
        # confirmation that both service VMs carry, and a start waiting on a
        # modal nobody answers looks exactly like a start that was refused.
        if (-not $NoDialogWatchdog) { Start-UtmDialogWatchdog }
        try {
            # The retry budget is spread ACROSS the VM's deadline rather than
            # added on top of it, so a caller's timeout still means what it
            # says while a momentary refusal now gets the second and third try
            # that a single-shot start never had.
            $remainingMs   = Get-YurunaDeadlineRemainingMs -Deadline $vmDeadline
            $settleSeconds = [Math]::Max(1, [Math]::Min([int]($TimeoutSeconds / 3), [int]($remainingMs / 1000)))
            $start = Invoke-UtmVMStartWithRetry -VMName $name -Confirm:$false `
                -SettleSeconds $settleSeconds -Deadline $vmDeadline
        } finally {
            if (-not $NoDialogWatchdog) { Stop-UtmDialogWatchdog }
        }
        if ($start.success) {
            Write-Verbose "Resume-YurunaServiceVM: '$name' is running again (attempt $($start.attempts))."
            & $note $name 'resumed' 'started' ([int]$start.attempts)
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_126a49ca0c55779b' -Arguments @{ name = "$name"; errorMessage = "$($start.errorMessage)" })
            $outcome = if ($start.kind -eq 'unresolved') { 'unresolved' } else { 'start-failed' }
            & $note $name $outcome ([string]$start.kind) ([int]$start.attempts)
        }
    }
    if ($Detailed) { return $records.ToArray() }
    return $failed.ToArray()
}

<#
.SYNOPSIS
    Rename a stopped UTM VM by editing its .utm bundle and UTM's Registry
    plist while UTM.app is quit.
.DESCRIPTION
    UTM exposes no rename verb in utmctl, and macOS 26 builds mark the
    AppleScript `name` property of `virtual machine` as read-only
    (osascript fails with -10006). The reliable workaround is on-disk
    surgery while UTM is offline:

      1. Quit UTM.app through Stop-UtmApplication (UTM and its QEMUHelper
         children, this user only) so cfprefsd flushes the in-memory
         Registry to its plist on disk, then flush cfprefsd's cache so our
         subsequent edits aren't clobbered.
      2. Rename `<guest.nosync>/<VMName>.utm` -> `<guest.nosync>/<NewName>.utm`.
         The qcow2 disks (including snapshots written by Save-VMDiskSnapshot)
         move with the bundle.
      3. PlistBuddy: set `:Information:Name` in the new bundle's
         config.plist to NewName.
      4. PlistBuddy: set `:Registry:<UUID>:Name` and
         `:Registry:<UUID>:Package:Path` inside
         `~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist`.
      5. Relaunch through Start-UtmApplication, flushing cfprefsd first so
         UTM re-reads our edited plist.
      6. Resume the service VMs that step 1 took down (see below), then poll
         until the new name surfaces.

    Step 1 is not free for the rest of the host. UTM saves the state of
    every VM still running as it terminates, so any service VM that was up
    -- the caching proxy, the stash service, pool-control -- returns as
    `suspended` and stays there. Guests consume those services for the
    whole cycle, so the running set is captured before the quit and
    resumed after the relaunch, exactly once on every path out of this
    function that follows the quit. The capture must be a listing that was
    actually read: when it cannot be read, UTM is not quit at all, because
    quitting with an empty capture would strand every service suspended.
    Services are resumed only after a CONFIRMED relaunch (the launch was
    acknowledged and UTM observed for this user); an unconfirmed relaunch
    names the services left suspended and the commands that resume them.

    The stop passes -AllowHardStop: UTM and helpers that ignore the quit
    are signaled, UTM first and helpers last, each identity revalidated
    right before its signal. A stop that still is not confirmed ends the
    rename before any edit.

    The Package.Bookmark blob is left untouched: macOS file bookmarks
    resolve via catalog inode + volume UUID, so a directory rename within
    the same volume continues to resolve to the new path.

    Requires the VM to be stopped (UTM holds an exclusive lock on the
    bundle while running). Caller (Save-VMDiskSnapshot) handles the stop.
#>
function Rename-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_6d832084f2cb44cf' -Arguments @{ newName = "$NewName" }))) { return $false }
    if ($VMName -eq $NewName) { return $true }
    if ($VMName -match '[/"\\]' -or $NewName -match '[/"\\]') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b3adfc0d608ac6e8' -Arguments @{ vMName = "$VMName"; newName = "$NewName" })
        return $false
    }
    # A positive 'stopped' source and a positive 'absent' destination, never
    # merely "not the value we are refusing on": a denied or timed-out probe
    # now reads as 'unknown' rather than 'absent', so requiring the positive
    # state on both sides -- and refusing outright on 'unknown' -- is what
    # keeps an unanswered probe from reaching the mutation further down.
    $srcState = Get-VMState -VMName $VMName
    if ($srcState -ne 'stopped') {
        switch ($srcState) {
            'absent'  { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_524e2803f12e1efa' -Arguments @{ vMName = "$VMName" }) }
            'running' { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_697963516e07c1d1' -Arguments @{ vMName = "$VMName" }) }
            default   { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_476ac9f4728142ba' -Arguments @{ vMName = "$VMName" }) }
        }
        return $false
    }
    $dstState = Get-VMState -VMName $NewName
    if ($dstState -ne 'absent') {
        if ($dstState -eq 'unknown') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8325345b98bdf237' -Arguments @{ newName = "$NewName" })
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f69adb6b2f614a13' -Arguments @{ newName = "$NewName" })
        }
        return $false
    }

    $guestDir  = "$HOME/yuruna/guest.nosync"
    $srcBundle = Join-Path $guestDir "$VMName.utm"
    $dstBundle = Join-Path $guestDir "$NewName.utm"
    $srcConfig = Join-Path $srcBundle 'config.plist'
    if (-not (Test-Path -LiteralPath $srcConfig)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_15b9626a689d8633' -Arguments @{ srcConfig = "$srcConfig" })
        return $false
    }
    if (Test-Path -LiteralPath $dstBundle) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b89811c24b571c30' -Arguments @{ dstBundle = "$dstBundle" })
        return $false
    }

    # UUID is the only stable key in UTM's Registry; read it from the
    # bundle's own config.plist rather than parsing `defaults` output.
    $uuidRead = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', 'Print :Information:UUID', $srcConfig) -TimeoutSeconds 10
    $uuid = "$($uuidRead.StdOut)$($uuidRead.StdErr)".Trim()
    if (-not (Test-UtmBoundedResultComplete -Result $uuidRead) -or $uuidRead.ExitCode -ne 0 -or $uuid -notmatch '^[0-9A-Fa-f-]{36}$') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5e409de2ac1c55b7' -Arguments @{ srcConfig = "$srcConfig"; uuid = "$uuid" })
        return $false
    }

    $utmPrefs = "$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    if (-not (Test-Path -LiteralPath $utmPrefs)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_76727d9ff6fe99e5' -Arguments @{ utmPrefs = "$utmPrefs" })
        return $false
    }

    # Quitting UTM is collateral damage for every OTHER VM that happens to
    # be running: UTM saves their state on the way out and they come back
    # suspended, not started. The service VMs are the ones that matter --
    # a cycle consumes them from beginning to end -- so record which are up
    # now, while UTM can still be asked, and resume them after the relaunch.
    # A listing that could not be read is not an empty one: quitting on it
    # would resume nothing and strand every service suspended.
    $inventory = Get-UtmRunningVmInventory
    if (-not $inventory.Listed) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_inventory_unavailable' -Arguments @{ reason = "$($inventory.Reason)"; vmName = "$VMName" })
        return $false
    }
    $serviceVmName = @(Get-YurunaServiceVmName)
    $serviceVmToResume = @($inventory.Name | Where-Object { $serviceVmName -contains $_ })

    # Quit UTM so cfprefsd flushes the Registry to disk before our edits;
    # the flush afterwards drops cfprefsd's cache so PlistBuddy reads and
    # writes go straight to the plist file.
    $stop = Stop-UtmApplication -QuitWaitSeconds $script:UtmRenameQuitWaitSeconds -AllowHardStop -FlushPreferenceCache -Confirm:$false
    if ($stop.Outcome -in @('refused', 'deadline-exhausted', 'preview')) {
        # The quit was never sent: UTM is exactly as it was, so there is
        # nothing to relaunch and nothing to resume.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_stop_unconfirmed' -Arguments @{ outcome = "$($stop.Outcome)"; vmName = "$VMName" })
        return $false
    }

    # From here on the quit was sent, so every exit relaunches UTM and resumes
    # the captured services exactly once -- in the finally below, which is
    # scoped to the code after the quit. The preference cache is flushed
    # before the relaunch only once plist edits exist to be re-read.
    $flushOnRelaunch = $false
    $renamed = $false
    try {
        if (-not $stop.Stopped) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_stop_unconfirmed' -Arguments @{ outcome = "$($stop.Outcome)"; vmName = "$VMName" })
            return $false
        }

        try {
            Rename-Item -LiteralPath $srcBundle -NewName "$NewName.utm" -ErrorAction Stop
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5c039b0b7884d16b' -Arguments @{ srcBundle = "$srcBundle"; dstBundle = "$dstBundle"; message = "$($_.Exception.Message)" })
            return $false
        }

        $dstConfig = Join-Path $dstBundle 'config.plist'
        $nameSet = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Information:Name $NewName", $dstConfig) -TimeoutSeconds 10
        if (-not (Test-UtmBoundedResultComplete -Result $nameSet) -or $nameSet.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b6e0da77ab1ba6b5' -Arguments @{ dstConfig = "$dstConfig" })
            try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
            catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
            return $false
        }

        $registryName = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Registry:${uuid}:Name $NewName", $utmPrefs) -TimeoutSeconds 10
        $regExitName = if (Test-UtmBoundedResultComplete -Result $registryName) { [int]$registryName.ExitCode } else { -1 }
        $registryPath = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Registry:${uuid}:Package:Path $dstBundle", $utmPrefs) -TimeoutSeconds 10
        $regExitPath = if (Test-UtmBoundedResultComplete -Result $registryPath) { [int]$registryPath.ExitCode } else { -1 }
        if ($regExitName -ne 0 -or $regExitPath -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_50978cbbff00be18' -Arguments @{ uuid = "$uuid"; regExitName = "$regExitName"; regExitPath = "$regExitPath" })
            # Best-effort revert: undo plist Name + bundle rename so the
            # next cycle sees a coherent state. The Registry may already hold
            # a partial edit, so the relaunch re-reads it from disk.
            $null = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Information:Name $VMName", $dstConfig) -TimeoutSeconds 10
            try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
            catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
            $flushOnRelaunch = $true
            return $false
        }

        # A bundle still holding the address the OLD name derives is holding that
        # NAME's address rather than the guest's, and the name is being vacated --
        # so it moves here, in the same window and for the same reason as the
        # display below: both are per-name values, and this relaunch is the one
        # moment the file is authoritative again. A bundle on any other address was
        # pinned at build time to the identity its guest keeps for life; moving that
        # one re-DHCPs a guest whose own state records the address it has.
        $bundleMac = [string]((Get-UtmBundleNetwork -VMName $NewName).MacAddress)
        if (Test-YurunaGuestMacMatchesName -MacAddress $bundleMac -VMName $VMName) {
            if (-not (Set-GuestMacInBundle -VMName $NewName -Confirm:$false)) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fc7e4d718a95d1a2' -Arguments @{ vMName = "$VMName"; newName = "$NewName" })
            }
        }

        # Re-derive the VNC display for the NEW name, here, while UTM is down.
        # UTM reads a bundle's -vnc argument only when it loads the VM, and
        # loads it once per app launch: a rewrite performed while UTM already
        # holds the VM changes the file without changing the QEMU command
        # line, so the guest still starts on the display it was loaded with.
        # This relaunch is the one moment the file is authoritative again.
        # It matters because bundles are built under a single per-kind test
        # name -- every VM promoted out of that namespace inherits the same
        # display, and only the first of them can bind the port.
        $wantDisplay = Find-FreeVncDisplay `
            -Preferred (Get-VncDisplayForVm -VMName $NewName) `
            -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $NewName)
        if ($wantDisplay -lt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_844a212ddde38874' -Arguments @{ newName = "$NewName"; newName2 = "$(Get-VncDisplayFromBundle -VMName $NewName)" })
        } elseif ((Get-VncDisplayFromBundle -VMName $NewName) -ne $wantDisplay) {
            if (Set-VncDisplayInBundle -VMName $NewName -Display $wantDisplay -Confirm:$false) {
                Write-Verbose "Rename-VM: VNC display for '$NewName' set to $wantDisplay (port $(5900 + $wantDisplay))."
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8e1418fef79d70dd' -Arguments @{ newName = "$NewName"; newName2 = "$(Get-VncDisplayFromBundle -VMName $NewName)" })
            }
        }

        # Force cfprefsd to reload from our edited file on the relaunch.
        $flushOnRelaunch = $true
        $renamed = $true
    } finally {
        $relaunch = Start-UtmApplication -LaunchWaitSeconds $script:UtmRenameLaunchWaitSeconds -FlushPreferenceCache:$flushOnRelaunch -Confirm:$false
        if ($relaunch.Started) {
            # The failed list is NOT discarded. This function's caller judges
            # the rename, and a rename can succeed while the services it took
            # down stay down -- which reads as a passing step that quietly
            # hands every later step, and the next cycle, a host with no cache
            # and no stash. The rename verdict is still the return value; this
            # makes the collateral damage say so at the point it happened.
            $resumeFailed = @(Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
            if ($renamed -and $resumeFailed.Count -gt 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_84987470d9b561d8' -Arguments @{ newName = "$NewName"; count = "$($resumeFailed.Count)"; join = "$($resumeFailed -join ', ')"; join2 = "$(($resumeFailed | ForEach-Object { "utmctl start '$_'" }) -join '; ')" })
            }
        } elseif ($serviceVmToResume.Count -gt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_relaunch_unconfirmed' -Arguments @{ outcome = "$($relaunch.Outcome)"; names = "$($serviceVmToResume -join ', ')"; commands = "$(($serviceVmToResume | ForEach-Object { "utmctl start '$_'" }) -join '; ')" })
        }
    }

    # Only the completed rename reaches here: every failure path returned
    # from inside the try after its relaunch and resume ran. The services
    # were resumed above whether or not the new name surfaces, because the
    # quit took them down either way.
    $surfaceDeadline = New-YurunaDeadline -TotalMilliseconds $script:UtmRenameSurfaceWaitMilliseconds
    $surfaced = $false
    while (-not (Test-YurunaDeadlineExpired -Deadline $surfaceDeadline)) {
        # Only a positive valid state counts as surfaced: an 'unknown' read
        # here (UTM still ingesting, or a denied probe) must keep polling,
        # not be read as "not there yet" and then time out looking identical
        # to a rename that never took.
        $polled = Get-VMState -VMName $NewName
        if ($polled -eq 'running' -or $polled -eq 'stopped') { $surfaced = $true; break }
        $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $surfaceDeadline
    }
    if ($surfaced) { return $true }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_20dac0c25f3fe7a9' -Arguments @{ newName = "$NewName" })
    return $false
}

<#
.SYNOPSIS
    Save a disk-only snapshot of each qcow2 disk in the UTM bundle,
    then attempt to rename the VM (best-effort) so it persists across
    test-cycle cleanup.
.DESCRIPTION
    UTM owns its QEMU process and does not expose a stable QMP/CLI
    snapshot verb, so this contract drops to qemu-img with the VM
    offline. The .utm bundle lives at $HOME/yuruna/guest.nosync/<vm>.utm
    and disks are *.qcow2 under <bundle>/Data/. For multi-disk VMs the
    same Id is written into every qcow2 -- Restore-VMDiskSnapshot
    reverts the same set as a group so the disks stay coherent.

    After a successful snapshot, Rename-VM renames the VM to $Id by
    on-disk surgery (bundle dir + config.plist + UTM Registry) so the
    snapshot survives the next cycle's Remove-TestVMFiles sweep. If the
    rename fails, the qcow2 snapshot is still on disk and can be
    restored manually from the original bundle path.
#>
function Save-VMDiskSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_dd94ac62ae57701c' -Arguments @{ id = "$Id" }))) { return $false }
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5e237b9eea6b9490' -Arguments @{ dataDir = "$dataDir" })
        return $false
    }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_13cb024dfb19c946' -Arguments @{ dataDir = "$dataDir" })
        return $false
    }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_06786a3211f6200f')
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # A snapshot created while the QEMU helper still holds the qcow2 open
    # races its in-memory metadata: qemu-img -c either fails to lock
    # ("Failed to lock byte 100") or captures an inconsistent disk. Block
    # until the process is gone and the write lock is free before -c.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ceeff55becfc6e28' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    foreach ($disk in $disks) {
        # Idempotent overwrite: drop a prior snapshot with the same id
        # if present, then create.
        & qemu-img snapshot -d $Id $disk.FullName 2>&1 | Out-Null
        & qemu-img snapshot -c $Id $disk.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4e18f285f91cd947' -Arguments @{ name = "$($disk.Name)"; lASTEXITCODE = "$LASTEXITCODE" })
            return $false
        }
    }
    if ($VMName -ne $Id) {
        if (-not (Rename-VM -VMName $VMName -NewName $Id -Confirm:$false)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3d4bd722f2cfda09' -Arguments @{ id = "$Id"; utmBundle = "$utmBundle"; vMName = "$VMName" })
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Returns $true when snapshot $Id is present on every qcow2 disk of
    the UTM bundle for $VMName. False on missing bundle, missing
    qemu-img, or any disk lacking the snapshot. Used by Debug-TestSequence's
    requiresSnapshot warm-path probe before deciding whether to walk
    the baseline chain.
#>
function Test-VMDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) { return $false }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) { return $false }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) { return $false }
    foreach ($disk in $disks) {
        # -U (--force-share) so a running QEMU's exclusive lock on the
        # qcow2 doesn't fail this metadata-only read with "Failed to get
        # shared write lock". Test-VMDiskSnapshot is a pure read; it
        # never mutates the disk, so force-share is safe.
        $info = & qemu-img snapshot -l -U $disk.FullName 2>&1
        # `$array -notmatch <rx>` returns the filtered array of NON-matching
        # lines, not a Boolean -- with qemu-img's two header lines that's a
        # non-empty (truthy) array even when the data row matches, so the
        # naive `if (-notmatch)` form always reports "not present" on UTM.
        # Use Where-Object + .Count for an unambiguous count of hits.
        $hits = @($info | Where-Object { $_ -match ("^\s*\d+\s+" + [regex]::Escape($Id) + "\s") })
        if ($hits.Count -eq 0) {
            return $false
        }
    }
    return $true
}

function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Restore every *.qcow2 disk under the UTM VM bundle to snapshot $Id.
    .DESCRIPTION
        Verifies the snapshot exists on every disk first so a typo'd Id
        does not bounce a healthy guest, stops the VM if it is running,
        then applies `qemu-img snapshot -a $Id` per disk. Multi-disk VMs
        must have the snapshot on all disks to stay coherent.
    .OUTPUTS
        [bool] $true on success; $false on any precondition or apply failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_122c73a3a2052796' -Arguments @{ id = "$Id" }))) { return $false }
    $utmBundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $dataDir   = Join-Path $utmBundle 'Data'
    if (-not (Test-Path -LiteralPath $dataDir)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_dec3b9d961011af3' -Arguments @{ dataDir = "$dataDir" })
        return $false
    }
    $disks = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    if ($disks.Count -eq 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2443a2232e97400d' -Arguments @{ dataDir = "$dataDir" })
        return $false
    }
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_67f1fe22f87fb1a8')
        return $false
    }
    # Verify the id exists on every disk before stopping the VM, so a
    # typo on a healthy guest does not bounce it for nothing. Multi-disk
    # VMs must have the snapshot on all disks to stay coherent.
    foreach ($disk in $disks) {
        # -U (--force-share) so a running QEMU's exclusive lock doesn't
        # fail this metadata-only read with "Failed to get shared write
        # lock". This is a verify probe; the actual `qemu-img snapshot
        # -a` apply below runs AFTER the VM is stopped, so there is no
        # risk of read-while-write inconsistency here.
        $info = & qemu-img snapshot -l -U $disk.FullName 2>&1
        # `$array -notmatch <rx>` returns the filtered NON-matching lines,
        # not a Boolean -- qemu-img's two header lines make that array
        # truthy even when the data row matches. Count Where-Object hits
        # explicitly instead.
        $hits = @($info | Where-Object { $_ -match ("^\s*\d+\s+" + [regex]::Escape($Id) + "\s") })
        if ($hits.Count -eq 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b8f92bfb6eae66ac' -Arguments @{ id = "$Id"; name = "$($disk.Name)" })
            return $false
        }
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # The apply below must not race a still-live QEMU helper: it holds the
    # qcow2's L1/L2 tables in memory and flushes its (un-reverted) view on
    # exit, so `qemu-img snapshot -a` exits 0 yet the guest resumes the
    # pre-revert disk -- "continues from where the last run left off"
    # instead of starting from the snapshot. Blocking on a true power-off
    # and lock release is what makes this revert as deterministic as a
    # Hyper-V checkpoint restore. Runs unconditionally because Get-VMState
    # maps 'suspended'/'paused' to 'stopped' yet those still hold the lock.
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c66ee6ced9fa2d77' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    # Removing vmstate at this point mirrors Start-UtmVM's cold-boot
    # prep -- the saved RAM (if any) belongs to the post-snapshot
    # universe and would collide with the reverted disk on next start.
    $vmstatePath = Join-Path $utmBundle 'Data/vmstate'
    if (Test-Path -LiteralPath $vmstatePath) {
        Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
    }
    foreach ($disk in $disks) {
        & qemu-img snapshot -a $Id $disk.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3566f32ac9581467' -Arguments @{ name = "$($disk.Name)"; lASTEXITCODE = "$LASTEXITCODE" })
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Returns true when a console window is open for the given VM.
#>
function Test-VMConsoleOpen {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    # UTM does not expose per-VM window state today; "console open" is
    # approximated by "UTM app process running." VMName is accepted for
    # cross-host parity and surfaced in the debug stream.
    Write-Debug "Test-VMConsoleOpen on host.macos.utm: VMName '$VMName' resolved to UTM-process check (no per-VM window detection)."
    return [bool](Get-Process -Name 'UTM' -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Refresh or re-open the host-side console window for the given VM.
#>
function Restart-VMConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_6e0202c4ffd01c8a'))) { return $false }
    return [bool](Restart-UtmConsole -VMName $VMName -Confirm:$false)
}

# --- REGION: Image
function Get-Image {
    <#
    .SYNOPSIS
        Run the per-guest Get-Image.ps1 to download or refresh the base image.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-GetImage, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    # Thin wrapper over the shared runner; the host subdir is the only platform
    # variable and Get-ImagePath (the per-platform image table) is injected as a
    # CommandInfo resolved in THIS driver's scope so the shared body binds ours.
    Invoke-GetImage -HostSubdir 'host/macos.utm' -ResolveImagePath (Get-Command Get-ImagePath) @PSBoundParameters
}

<#
.SYNOPSIS
    Return the expected on-disk path of the base image for a guest.
#>
function Get-ImagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    # Per-guest paths under $HOME/yuruna/image/ -- not a single-dir pattern;
    # subdir names are part of the legacy convention (amazon.linux.2023,
    # ubuntu.env, windows.env). Keep the explicit table so a typo or new
    # guest fails loud instead of silently composing the wrong path.
    $paths = @{
        'guest.amazon.linux.2023'    = "$HOME/yuruna/image/amazon.linux.2023/host.macos.utm.guest.amazon.linux.2023.qcow2"
        'guest.ubuntu.server.24'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.24.iso"
        'guest.macos.26' = "$HOME/yuruna/image/macos.env/host.macos.utm.guest.macos.26.ipsw"
        'guest.ubuntu.server.26'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.26.iso"
        'guest.windows.11'      = "$HOME/yuruna/image/windows.env/host.macos.utm.guest.windows.11.iso"
    }
    return $paths[$GuestKey]
}

# --- REGION: VM I/O
function Send-Text {
    <#
    .SYNOPSIS
        Type text into the guest VM via gui or ssh mechanism.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui',
        # Required when -Mechanism ssh: maps to the SSH login user via
        # Test.Ssh\Get-GuestSshUser (per-guest test user, ec2-user, root, ...).
        [string]$GuestKey,
        [int]$CharDelayMs = 10,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; current paths
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honor it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on UTM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f4a1977247ebda51')
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; surface .success, not the
        # hashtable itself -- [bool] of a non-null hashtable is always $true
        # (truthy-hashtable trap).
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: Test.SequenceEngine.psm1 has the cross-platform dispatcher and the
    # macOS-specific Send-TextVNC / Send-TextUTM helpers. We import it on
    # demand here (it ships in test/modules/ and the runner already loads
    # it for sequence execution).
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, matching Send-Key below. Re-importing -Force on
        # every call evicts the global Invoke-Sequence (and its nested modules
        # + $script: state) that the outer loop still calls
        # (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport). Paying that per
        # keystroke is not just overhead: it churns the module state that this
        # driver's own -HostType argument is read from, so the very act of
        # typing can disable the keystrokes that follow it.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        # Module-qualified call avoids re-entering OUR Send-Text.
        return [bool](Test.SequenceEngine\Send-Text -HostType (Resolve-HostTag) -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1e2f99261b1a1683' -Arguments @{ sequenceEngine = "$sequenceEngine" })
    return $false
}

<#
.SYNOPSIS
    Send a named key to the guest VM via gui or ssh mechanism.
#>
function Send-Key {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4ffbf7056dde8493')
        return $false
    }
    # Defer to Invoke-Sequence's host-aware dispatcher, which resolves the key
    # name through the key-code registry and picks the VNC or CGEvent backend.
    #
    # Routing a key name through Send-Text instead does NOT work: the
    # character maps cover printable ASCII only, so a control character such
    # as CR is warn-and-skipped by every text backend while the call still
    # reports success -- a key that silently types nothing. Named keys and
    # modifier chords have to go through the key path.
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse: a -Force re-import evicts the global
        # Invoke-Sequence (and its nested modules + $script: state) that the
        # outer loop still calls (feedback_module_force_import_evicts_global,
        # feedback_module_script_state_reset_by_force_reimport), and paying
        # that on every keystroke is pure overhead.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Key -HostType (Resolve-HostTag) -VMName $VMName -KeyName $Key)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c53432cf9b294e69' -Arguments @{ sequenceEngine = "$sequenceEngine" })
    return $false
}

<#
.SYNOPSIS
    Send a mouse click at the given pixel coordinate.
#>
function Send-Click {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bf613f7460bae519' -Arguments @{ vMName = "$VMName"; x = "$X"; y = "$Y" })
    return $false
}

<#
.SYNOPSIS
    Capture a PNG of the VM display from frame or window source.
#>
function Get-VMScreenshot {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if ($Source -eq 'window') {
        return Get-UtmWindowScreenshot -VMName $VMName -OutputPath $OutFile
    }
    return Get-UtmScreenshot -VMName $VMName -OutputPath $OutFile
}

<#
.SYNOPSIS
    Return a host-specific handle for the VM console window.
#>
function Get-VMConsoleHandle {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$VMName)
    # macOS UTM exposes one app-level console; we return the UTM PID and
    # surface the requested VMName in the debug stream until per-VM window
    # handles are wired up.
    Write-Debug "Get-VMConsoleHandle on host.macos.utm: returning UTM app PID for '$VMName' (no per-VM window handle today)."
    $proc = Get-Process -Name 'UTM' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }
    return $proc.Id
}

<#
.SYNOPSIS
    Return the pid of the QEMU process serving the named VM, or 0 when it
    cannot be identified.
.DESCRIPTION
    UTM runs every VM in its own QEMULauncher process and publishes no
    name-to-pid mapping, so the emulator has to be recognized by something
    only that VM owns. The VNC display in the bundle is exactly that:
    Find-FreeVncDisplay refuses to hand one display to two bundles, so
    whoever holds that listening port is that VM's emulator. Matching on
    the process name instead would be ambiguous the moment two VMs run at
    once -- the normal case for a cycle that keeps the service VMs up.
#>
function Get-UtmVMProcessId {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) { return 0 }
    $port = Get-VncPortForVm -VMName $VMName
    if ($port -le 0) { return 0 }
    $listenerPid = & lsof -nP "-iTCP:$port" -sTCP:LISTEN -t 2>$null
    foreach ($line in @($listenerPid)) {
        $candidate = 0
        if ([int]::TryParse("$line".Trim(), [ref]$candidate) -and $candidate -gt 0) { return $candidate }
    }
    return 0
}

<#
.SYNOPSIS
    Say whether a console that never changed was the guest's doing or the
    capture path's.
.DESCRIPTION
    A wait that exhausts its console-reconnect repairs ends on one
    ambiguous fact: every captured frame was byte-identical. That has two
    causes with opposite owners -- a guest that stopped drawing, and a
    capture path that lost the live feed while the guest kept drawing.

    Here the two are separated by reading the emulator rather than the
    screen. Get-VncScreenshot dials QEMU's own VNC server on a fresh
    connection and asks for a non-incremental full-frame update, so it
    holds nothing that could go stale; Get-UtmScreenshot's screencapture
    fallback, which serves whatever the UTM window last painted, can. A
    pair of direct VNC reads that differ therefore means the guest is
    drawing and the wait's frames came from that fallback.

    A matching pair leaves the guest side, and the emulator's CPU time
    then says which kind: a halted guest consumes almost nothing, while
    one wedged mid-boot keeps burning cores against a screen that never
    advances. Those need opposite responses -- restart the VM versus
    capture the guest's state before anything clears it -- so they are
    reported as separate verdicts instead of one 'static'.

    A blinking cursor makes an idle console differ frame to frame, so a
    matching pair is reported as what was observed, never as proof the
    guest is dead.
.OUTPUTS
    [pscustomobject] Verdict 'guest-static' | 'guest-wedged' | 'guest-live'
    | 'unavailable', Detail.
#>
function Get-VMConsoleSecondOpinion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$IntervalSeconds = 5
    )
    # Percent of one core, sustained across the sample window, that counts
    # as "still executing". An idle QEMU answering VNC polls sits in low
    # single digits; a guest spinning on a wedged boot holds a core or more,
    # so anything in between is read as executing rather than halted.
    $executingPercent = 25
    try {
        $state = Get-VMState -VMName $VMName
        if ($state -eq 'absent' -or $state -eq 'unknown') {
            return [pscustomobject]@{ Verdict = 'unavailable'; Detail = (Format-YurunaOperatorMessage -Key 'host.operator_b7d0860a322acd62' -Arguments @{ state = "$state"; vMName = "$VMName" }) }
        }
        if ($state -ne 'running') {
            return [pscustomobject]@{
                Verdict = 'guest-static'
                Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_9ea0a8c951ae7be7' -Arguments @{ state = "$state" })
            }
        }

        $qemuPid = Get-UtmVMProcessId -VMName $VMName
        $port    = Get-VncPortForVm -VMName $VMName
        $readFrame = {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-second-opinion-$PID-$([guid]::NewGuid().ToString('N')).png"
            try {
                if (-not (Get-VncScreenshot -OutputPath $tmp -Port $port)) { return $null }
                return (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
            } catch {
                Write-Debug "Get-VMConsoleSecondOpinion: direct VNC read on $port failed: $($_.Exception.Message)"
                return $null
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
        $readCpu = {
            if ($qemuPid -le 0) { return $null }
            $proc = Get-Process -Id $qemuPid -ErrorAction SilentlyContinue
            if (-not $proc) { return $null }
            return [double]$proc.CPU
        }

        # Frame first, then CPU, so the CPU window is the sleep alone and the
        # percentage is not diluted by the time a framebuffer read costs.
        $firstFrame = & $readFrame
        $firstCpu   = & $readCpu
        Start-Sleep -Seconds $IntervalSeconds
        $secondCpu   = & $readCpu
        $secondFrame = & $readFrame

        $cpuPercent = $null
        $cpuText    = 'the emulator CPU was unreadable'
        if ($null -ne $firstCpu -and $null -ne $secondCpu -and $IntervalSeconds -gt 0) {
            # A pid reused inside the window reads as a negative delta. Drop
            # it rather than publish a percentage taken from two processes.
            $delta = $secondCpu - $firstCpu
            if ($delta -ge 0) {
                $cpuPercent = [math]::Round(($delta / $IntervalSeconds) * 100, 1)
                $cpuText    = "the emulator burned ${cpuPercent}% of one core across the same window"
            }
        }

        if ($firstFrame -and $secondFrame -and $firstFrame -ne $secondFrame) {
            return [pscustomobject]@{
                Verdict = 'guest-live'
                Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_689d94eae42f4fe8' -Arguments @{ port = "$port"; intervalSeconds = "${IntervalSeconds}"; cpuText = "$cpuText" })
            }
        }
        $frameText = if ($firstFrame -and $secondFrame) {
            "direct VNC reads on port $port ${IntervalSeconds}s apart are byte-identical"
        } else {
            "direct VNC reads on port $port were unavailable"
        }
        if ($null -ne $cpuPercent -and $cpuPercent -ge $executingPercent) {
            return [pscustomobject]@{
                Verdict = 'guest-wedged'
                Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_912d123572f4b9c5' -Arguments @{ frameText = "$frameText"; cpuText = "$cpuText" })
            }
        }
        return [pscustomobject]@{
            Verdict = 'guest-static'
            Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_7b4448d951dc6b7c' -Arguments @{ frameText = "$frameText"; cpuText = "$cpuText" })
        }
    } catch {
        return [pscustomobject]@{ Verdict = 'unavailable'; Detail = $_.Exception.Message }
    }
}

# --- REGION: Discovery
function Wait-VMIp {
    <#
    .SYNOPSIS
        Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3,
        # Forwarded so a caller can widen or waive the shared poller's settle
        # window; its default applies when this is not bound.
        [int]$StableForSeconds = 8
    )
    # Get-Command runs in THIS driver's scope, so the shared poller resolves
    # our Get-VMIp; a bare name would resolve in the shared module's scope.
    Invoke-WaitVmIp @PSBoundParameters -ResolveVmIp (Get-Command Get-VMIp)
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.

.DESCRIPTION
    Three rungs, cheapest first. Each answers for a different class of
    guest, and the order is part of the contract: a rung runs only when
    every rung above it declined, so a Shared-NAT guest -- which the lease
    file answers for in milliseconds -- never pays for the LAN sweep a
    bridged guest needs.

      1. utmctl ip-address -- the guest's own report, via qemu-guest-agent.
         Free when it answers and silent for every guest this repo seeds,
         because the seeds do not install the agent.
      2. /var/db/dhcpd_leases -- the lease file of the macOS SHARED-NAT
         DHCP server. Authoritative for a Shared guest, and structurally
         blind to a bridged one, which leases from the LAN router and
         never appears in it.
      3. The bundle's MAC in the host ARP table. The only rung that can see
         a bridged guest, and the reason this chain has three rungs: with
         just the first two, a healthy bridged guest serving traffic is
         indistinguishable from a VM that does not exist, and every caller
         waits out its whole budget against $null.

    Each decline is narrated to the verbose stream naming the rung and why
    it could not answer. Three sources that all return $null otherwise
    report "no address yet" in exactly the same words as "no such VM",
    which is the difference between a 30-second diagnosis and a 30-minute
    one when a run is examined afterwards.

    Safe to call from a polling loop, which is what rung 3 is shaped
    around. A guest that is up and has exchanged traffic with the host
    answers from the ARP table in well under a second; a guest that is
    not running is declined for the cost of one state query; and the ICMP
    sweep -- the only part measured in seconds -- runs at most once per
    minute per VM, so no caller can turn its poll interval into a sweep
    interval.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $ip = Get-UtmAgentReportedIp -VMName $VMName
    if ($ip) { return $ip }
    # Read the bundle once and hand it to both rungs that need it: each
    # would otherwise shell out to plutil for the same file.
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    $ip = Get-UtmSharedLeaseIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    $ip = Get-UtmBridgedGuestIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    Write-Verbose "Get-VMIp: all three rungs declined for '$VMName' (guest agent, shared-NAT lease file, bundle MAC in ARP); each said why above."
    return $null
}

<#
.SYNOPSIS
    Rung 1: the address the guest reports through utmctl, or $null.
.PARAMETER UtmctlLine
    Pre-captured `utmctl ip-address` output. The live command is run when
    this is not bound; supplying it keeps the parsing testable with no VM.
#>
function Get-UtmAgentReportedIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyCollection()][string[]]$UtmctlLine
    )
    $output = $UtmctlLine
    if (-not $PSBoundParameters.ContainsKey('UtmctlLine')) {
        $resolver = Resolve-UtmctlExecutable
        if ($resolver.Source -eq 'missing') {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl is neither on PATH nor in the UTM bundle."
            return $null
        }
        try {
            $probe  = Invoke-UtmctlProbe -Arguments @('ip-address', $VMName) -UtmctlPath $resolver.Path
            $output = @(Get-BoundedNativeOutputLine -Result $probe -IncludeError)
            if ($probe.TimedOut) {
                Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address did not answer within its time limit."
                return $null
            }
            # utmctl exits 0 even when the guest has no agent to ask, writing
            # its complaint to stderr, so the exit code cannot be the test for
            # "an address came back" -- only the parse below can be.
            if ($probe.ExitCode -ne 0) {
                Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address exited $($probe.ExitCode)."
                return $null
            }
        } catch {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address failed: $($_.Exception.Message)"
            return $null
        }
    }
    # Accept either IPv4 or IPv6; exclude loopback (127., ::1)
    # and link-local (169.254., fe80:) for both families. v4 is
    # preferred only by output ordering -- utmctl emits the v4
    # row first today, so callers that expect a connectable
    # address still get one. If only v6 is present, take it.
    $ipPick = ($output -split "`r?`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { Test-IpAddress $_ } |
        Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' } |
        Select-Object -First 1
    if ($ipPick) { return [string]$ipPick }
    Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl reported no usable address (the seeds do not install qemu-guest-agent, so this is the normal answer)."
    return $null
}

<#
.SYNOPSIS
    Rung 2: the guest's address in the macOS shared-NAT lease file, or $null.
.DESCRIPTION
    The DHCP server keys each block on the name the GUEST sent, which is the
    VM name only when no sequence pinned variables.hostname; a pinned hostname
    makes the guest register under that instead. A VM-name lookup therefore
    does not come back empty when a hostname is pinned -- it matches leftover
    blocks filed under the VM name by predecessors and hands back a dead
    address, often on a subnet the host no longer serves, which costs a full
    SSH connect-timeout budget per attempt. Both keys are tried, pinned
    hostname first, and Select-DhcpLeaseIpAddress discards any candidate that
    is not on a live host-interface subnet.

    A guest whose bundle says Bridged is skipped outright. This file belongs
    to the shared-NAT DHCP server; a bridged guest takes its lease from the
    LAN router and cannot legitimately appear here, so any block bearing its
    name is a predecessor's from when the name was last built on Shared NAT.
    Those blocks parse, sit on-link while the vmnet bridge is up, and look
    exactly like a good answer -- returning one would hide the guest's real
    LAN address behind a dead 192.168.64.x for the rest of the run.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER LeaseText
    Pre-captured lease-file text. The live file is read when this is not
    bound; supplying it keeps the selection testable with no guests running.
.PARAMETER OnLinkVerdict
    Forwarded to Select-DhcpLeaseIpAddress, which judges each candidate
    against the host's live interface subnets by default. Supplying a
    verdict fixes that judgment, so a lease fixture reads the same on a
    host that serves the vmnet subnet and on one that does not.
#>
function Get-UtmSharedLeaseIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        [scriptblock]$OnLinkVerdict
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if ($BundleNetwork -and $BundleNetwork.Mode -eq 'Bridged') {
        Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': the bundle is Bridged, so its lease comes from the LAN router and any block under this name belongs to a predecessor."
        return $null
    }
    $content = $LeaseText
    if (-not $PSBoundParameters.ContainsKey('LeaseText')) {
        $leaseFile = '/var/db/dhcpd_leases'
        if (-not (Test-Path $leaseFile)) {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': $leaseFile does not exist (no guest has ever taken a shared-NAT lease on this host)."
            return $null
        }
        try {
            $content = Get-Content $leaseFile -Raw -ErrorAction Stop
        } catch {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': could not read $leaseFile`: $($_.Exception.Message)"
            return $null
        }
    }
    $pinnedHostname = Get-UtmGuestSeedHostname -VMName $VMName
    $leaseNames = @($pinnedHostname)
    if ($pinnedHostname -ne $VMName) { $leaseNames += $VMName }
    $selectArgs = @{ LeaseText = $content; Name = $leaseNames }
    if ($PSBoundParameters.ContainsKey('OnLinkVerdict')) { $selectArgs['OnLinkVerdict'] = $OnLinkVerdict }
    $bestIp = Select-DhcpLeaseIpAddress @selectArgs
    if ($bestIp) { return [string]$bestIp }
    Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': no on-link lease filed under $($leaseNames -join ' or ')."
    return $null
}

<#
.SYNOPSIS
    Rung 3: the guest's bundle MAC matched in the host ARP table, or $null.

.DESCRIPTION
    The rung a bridged guest depends on. It sits on the host's LAN with an
    address from the LAN's own DHCP server, so neither the guest agent nor
    the shared-NAT lease file can name it -- but it answers ARP, and the
    bundle's MAC identifies it unambiguously among everything else on that
    LAN, including a sibling host's identically-named VM.

    Two passes, and the order is the whole reason this is affordable in a
    hot path. The passive pass reads `arp -an` and matches: ~20 ms, and it
    is what steady state costs, because a guest that has exchanged any
    traffic with the host is already in the table. Only when the table has
    nothing does the ICMP sweep run -- a full /24 at 32-way parallelism is
    SECONDS (measured at ~8 s on a 253-address subnet), which is why it is
    one attempt with no retry loop: Get-VMIp is called per cycle by the
    runner and inside Wait-VMIp's poll loop, and a rung that blocked for
    minutes there would be worse than the discovery hole it closes. The
    poll loop is the retry.

    Two further guards bound what the sweep can cost a REPEAT caller, because
    the passive pass only protects a guest that is already on the LAN:

      * a VM that is not RUNNING is never swept for. Nothing powered off
        answers ICMP, so the sweep could only come back empty -- and this is
        the common shape, not an edge case: a bundle outlives its guest, so
        every lookup for a service whose VM is down would otherwise pay full
        price to learn what one state query already knows;
      * an empty sweep is remembered briefly, so a caller polling every few
        seconds through a guest's boot sweeps on a cadence of its own rather
        than once per poll. A found address retires the memo at once, and the
        memo suppresses only the ESCALATION -- the passive read still runs on
        every call, so a guest that appears mid-cooldown is picked up by the
        very next poll at ~20 ms.

    A guest whose bundle says Shared is skipped: it lives on the vmnet
    subnet, not the host's LAN, so the sweep could not match it and rung 2
    already answered for it. A bundle with no readable mode still gets both
    passes -- an unreadable mode is not evidence the guest is on NAT.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER SubnetPrefix
    The dot-terminated /24 to match and, if needed, sweep. Derived from the
    host's own default-route interface when not supplied -- a bridged guest
    is on the host's LAN by construction, so that is where it must be
    looked for, on whatever subnet this host happens to sit on.
.PARAMETER HostIp
    The host's address on that subnet, skipped by the sweep. Derived
    alongside -SubnetPrefix when not supplied.
.PARAMETER ArpLine
    Pre-captured `arp -an` output. The live table is read when this is not
    bound; supplying it keeps the match testable with no guests running.
#>
# How long an empty sweep suppresses the next one, per VM. Long enough that a
# 3-second poll loop cannot turn every poll into a /24 of ICMP, short enough
# that a guest finishing its DHCP exchange is swept for again while the caller
# that wants it is still waiting.
$script:UtmBridgedSweepCooldownSeconds = 60
$script:UtmBridgedSweepMiss = @{}

function Get-UtmBridgedGuestIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [string]$SubnetPrefix,
        [string]$HostIp,
        [AllowEmptyCollection()][string[]]$ArpLine
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if (-not $BundleNetwork) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': no readable .utm bundle on this host, so there is no MAC to match."
        return $null
    }
    if ($BundleNetwork.Mode -eq 'Shared') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle is on Shared NAT, which the lease file answers for; this rung looks on the host's LAN."
        return $null
    }
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $BundleNetwork.MacAddress
    if (-not $macNeedle) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle carries no usable MacAddress."
        return $null
    }
    if (-not ($PSBoundParameters.ContainsKey('SubnetPrefix') -and $PSBoundParameters.ContainsKey('HostIp'))) {
        # One default-route read answers both. Get-HostLanPrefix is
        # Get-BestHostIp plus a regex, so resolving them independently spawns
        # `route` and `ipconfig` twice per call on a path Wait-VMIp polls --
        # and lets the prefix and the host address come from different uplinks
        # when the default route changes between the two reads.
        $lanIp = Get-BestHostIp
        if (-not $PSBoundParameters.ContainsKey('HostIp'))       { $HostIp = $lanIp }
        if (-not $PSBoundParameters.ContainsKey('SubnetPrefix')) { $SubnetPrefix = Get-HostLanPrefix -HostIp $lanIp }
    }
    if (-not $SubnetPrefix) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': this host has no default-route IPv4, so there is no LAN to look on."
        return $null
    }
    if (-not $PSBoundParameters.ContainsKey('ArpLine')) {
        $ArpLine = @(Get-BoundedNativeOutputLine -Result (Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5))
    }
    $ip = Select-ArpIpByMac -ArpLine $ArpLine -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
    if ($ip) {
        # A hit retires any memo: whatever kept the guest off the LAN is over,
        # and the next call must be free to escalate again the moment it is not.
        $script:UtmBridgedSweepMiss.Remove($VMName)
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' resolved '$VMName' to $ip from the host's existing ARP table."
        return [string]$ip
    }

    # Everything below escalates. The guards are ordered by what they cost:
    # the memo is a hashtable read, the state query one utmctl call, the sweep
    # seconds -- so the cheapest thing that can rule the sweep out runs first.
    $lastMiss = $script:UtmBridgedSweepMiss[$VMName]
    if ($lastMiss -and ((Get-Date) - $lastMiss).TotalSeconds -lt $script:UtmBridgedSweepCooldownSeconds) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': a sweep of ${SubnetPrefix}0/24 found nothing $([int]((Get-Date) - $lastMiss).TotalSeconds)s ago and the host's ARP table still has no entry, so another one now would cost seconds to learn the same thing."
        return $null
    }
    $state = Get-VMState -VMName $VMName
    if ($state -ne 'running') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the VM is '$state', not running -- a guest that is not up answers no ICMP, so there is nothing for a sweep to find."
        return $null
    }

    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP': MAC $($BundleNetwork.MacAddress) is not in the host's ARP table yet; sweeping ${SubnetPrefix}0/24 ONCE to populate it (seconds)."
    $swept = Resolve-UtmGuestIpByMac -PlistPath $BundleNetwork.PlistPath -SubnetPrefix $SubnetPrefix -HostIp $HostIp -MaxAttempt 1
    if ($swept) {
        $script:UtmBridgedSweepMiss.Remove($VMName)
        return [string]$swept
    }
    $script:UtmBridgedSweepMiss[$VMName] = Get-Date
    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the sweep of ${SubnetPrefix}0/24 matched no entry carrying MAC $($BundleNetwork.MacAddress). The guest is running but not on this LAN yet; the next $($script:UtmBridgedSweepCooldownSeconds)s of calls read the ARP table without re-sweeping."
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
.DESCRIPTION
    utmctl exposes no MAC, so the bundle is the source: it is where UTM
    records the address the VM boots with, and it is readable whether or
    not the VM is running.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork -or -not $bundleNetwork.MacAddress) {
        Write-Verbose "Get-VMMac on host.macos.utm: no MacAddress in the bundle for '$VMName'."
        return $null
    }
    # Canonical form for the whole harness, so a MAC read on one host compares
    # equal to the same MAC read on another. The `arp -an` notation this host
    # needs is produced at the point of use by ConvertTo-UtmArpMacAddress.
    $canonical = ConvertTo-YurunaMacAddress -MacAddress ([string]$bundleNetwork.MacAddress)
    if ($canonical) { return $canonical }
    return ([string]$bundleNetwork.MacAddress).ToUpperInvariant()
}

<#
.SYNOPSIS
    Refresh the host neighbor cache so a passive MAC lookup can succeed.
.DESCRIPTION
    Contract verb, and deliberately a no-op here. This driver's bridged rung
    already escalates to its own ICMP sweep from inside Get-VMIp, where the
    cooldown memo and the running-state check bound it. Sweeping again from
    outside would duplicate that work while bypassing both guards, so the
    honest implementation is to decline and say why.
.PARAMETER VMName
    Accepted for contract symmetry; unused.
#>
function Update-GuestNeighborCache {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$CooldownSeconds = 60
    )
    $null = $CooldownSeconds
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_80e0ecef6307a2d3'))) { return $false }
    Write-Verbose "Update-GuestNeighborCache on host.macos.utm: no external sweep -- Get-VMIp's bridged rung runs its own bounded, memoized sweep for '$VMName'."
    return $false
}

<#
.SYNOPSIS
    Normalize a MAC to the form `arp -an` prints it, or $null when the
    input is not six hex octets.
.DESCRIPTION
    macOS prints ARP entries lowercase with the leading zero of each octet
    stripped ('0F' -> 'f'), while the bundle stores the canonical
    'E6:01:BC:6D:21:CD'. Comparing the two forms directly never matches, so
    every ARP lookup normalizes through here rather than carrying its own
    copy of the rule.
#>
function ConvertTo-ArpMacNeedle {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $null }
    $octets = @($MacAddress -split ':')
    if ($octets.Count -ne 6) { return $null }
    try {
        return (($octets | ForEach-Object { ([Convert]::ToInt32($_, 16)).ToString('x') }) -join ':')
    } catch {
        Write-Debug "ConvertTo-ArpMacNeedle: '$MacAddress' is not six hex octets: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Return the IPv4 in $SubnetPrefix whose ARP entry carries $MacNeedle,
    or $null when the table holds no such entry.
.DESCRIPTION
    The match is required to be IN the given subnet, not just any ARP entry
    carrying that MAC. `arp -an` lists EVERY interface, so a stale or
    foreign entry with the same MAC (a recreated bundle MAC still cached on
    another NIC) printed first would otherwise be selected -- and, since
    the first match wins, re-selected on every poll, wedging a caller
    against the wrong address until its timeout.

    $SubnetPrefix is dot-terminated (e.g. '192.168.64.'), so the prefix test
    cannot false-match a sibling /24 like 192.168.640.x.
.PARAMETER ArpLine
    Lines as `arp -an` prints them.
#>
function Select-ArpIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArpLine,
        [Parameter(Mandatory)][string]$MacNeedle,
        [Parameter(Mandatory)][string]$SubnetPrefix
    )
    foreach ($line in $ArpLine) {
        if ($line -match '^\? \(([\d.]+)\) at (\S+)' -and
            $matches[2] -eq $MacNeedle -and
            $matches[1].StartsWith($SubnetPrefix)) {
            return [string]$matches[1]
        }
    }
    return $null
}

<#
.SYNOPSIS
    A MAC in canonical 'AA:BB:CC:DD:EE:FF' form, or $null. Accepts the
    zero-stripped lowercase octets `arp -an` prints as well as the bundle's
    two-digit form, so the two compare equal.
#>
function ConvertTo-UtmCanonicalMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $null }
    $octets = @($MacAddress.Trim() -split '[:-]')
    if ($octets.Count -ne 6) { return $null }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($octet in $octets) {
        if ($octet -notmatch '^[0-9A-Fa-f]{1,2}$') { return $null }
        $parts.Add(([Convert]::ToInt32($octet, 16)).ToString('X2'))
    }
    return ($parts -join ':')
}

<#
.SYNOPSIS
    `arp -an` lines as a map of IPv4 address to canonical MAC.
.DESCRIPTION
    An address listed with two different MACs (on two interfaces) cannot
    identify either guest, so it is left out of the map and named in
    Conflict instead; incomplete entries are skipped.
#>
function ConvertFrom-UtmArpLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Line)
    $map = @{}
    $conflict = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in @($Line)) {
        if ("$entry" -notmatch '^\?\s+\(([\d.]+)\)\s+at\s+(\S+)') { continue }
        $address = $Matches[1]
        $mac = ConvertTo-UtmCanonicalMac -MacAddress $Matches[2]
        if (-not $mac -or -not (Test-Ipv4Address $address)) { continue }
        if ($map.ContainsKey($address) -and $map[$address] -ne $mac) { [void]$conflict.Add($address); continue }
        $map[$address] = $mac
    }
    foreach ($address in $conflict) { $map.Remove($address) }
    return [pscustomobject]@{ Map = $map; Conflict = [string[]]@($conflict) }
}

<#
.SYNOPSIS
    The host ARP table, read once through the bounded runner.
.OUTPUTS
    [pscustomobject] Captured, Line [string[]], Reason ('captured' |
    'failed' | 'timeout' | 'deadline-exhausted').
#>
function Get-UtmArpTable {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $read = Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5 -Deadline $Deadline
    $reason = if ($read.DeadlineExhausted) { 'deadline-exhausted' }
              elseif ($read.TimedOut) { 'timeout' }
              elseif ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { 'captured' }
              else { 'failed' }
    $lines = if ($reason -eq 'captured') { [string[]]@(Get-BoundedNativeOutputLine -Result $read) } else { [string[]]@() }
    return [pscustomobject]@{ Captured = ($reason -eq 'captured'); Line = $lines; Reason = $reason }
}

<#
.SYNOPSIS
    This host's IPv4 subnets from one bounded ifconfig read, with a verdict
    closure for on-link tests.
.DESCRIPTION
    The shared subnet parser runs a bare ifconfig when it is not handed the
    text; this reads it once, bounded, and hands it over, so a caller testing
    many candidates makes one bounded call instead of one hidden call each.
    Without a capture the verdict is always 'unknown', never 'offlink'.
.OUTPUTS
    [pscustomobject] Captured, Subnet [object[]], OnLinkVerdict
    ([scriptblock] taking an IPv4 and returning 'onlink' | 'offlink' |
    'unknown'), Reason ('captured' | 'failed' | 'timeout' | 'deadline-exhausted').
#>
function Get-UtmHostSubnetEvidence {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $read = Invoke-UtmHostTool -Tool 'ifconfig' -TimeoutSeconds 5 -Deadline $Deadline
    $reason = if ($read.DeadlineExhausted) { 'deadline-exhausted' }
              elseif ($read.TimedOut) { 'timeout' }
              elseif ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { 'captured' }
              else { 'failed' }
    $subnet = [object[]]@()
    # Assigned, not wrapped in @(): the parser returns its table comma-wrapped,
    # and @() around the call would nest it one level deep.
    if ($reason -eq 'captured') {
        $parsed = Get-HostIpv4Subnet -IfconfigText ([string]$read.StdOut)
        $subnet = [object[]]@($parsed | Where-Object { $_ })
    }
    $verdict = if ($reason -eq 'captured') {
        { param([string]$IpAddress) Get-Ipv4OnLinkVerdict -IpAddress $IpAddress -Subnet $subnet }.GetNewClosure()
    } else {
        { param([string]$IpAddress) $null = $IpAddress; 'unknown' }
    }
    return [pscustomobject]@{ Captured = ($reason -eq 'captured'); Subnet = [object[]]$subnet; OnLinkVerdict = $verdict; Reason = $reason }
}

<#
.SYNOPSIS
    The macOS shared-NAT DHCP lease file's text, read without any native call.
.OUTPUTS
    [pscustomobject] Captured, Text, Reason ('captured' | 'no-file' | 'read-failed').
#>
function Get-UtmSharedLeaseText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $path = [string]$script:UtmSharedLeasePath
    if (-not $path -or -not [System.IO.File]::Exists($path)) {
        return [pscustomobject]@{ Captured = $false; Text = ''; Reason = 'no-file' }
    }
    try {
        return [pscustomobject]@{ Captured = $true; Text = [System.IO.File]::ReadAllText($path); Reason = 'captured' }
    } catch {
        Write-Verbose "Get-UtmSharedLeaseText: could not read $path`: $($_.Exception.Message)"
        return [pscustomobject]@{ Captured = $false; Text = ''; Reason = 'read-failed' }
    }
}

<#
.SYNOPSIS
    The one address in an ARP map carrying a MAC, preferring on-link rows.
.DESCRIPTION
    Rows judged 'offlink' are dropped: `arp -an` lists every interface, and
    a MAC cached on another interface's subnet is not where the guest is.
    One distinct address wins; several are narrowed to the 'onlink' ones,
    and anything still plural is ambiguous rather than a guess.
.OUTPUTS
    [pscustomobject] Address ($null unless exactly one), Reason ('matched' |
    'no-match' | 'ambiguous').
#>
function Select-ArpIpByMacOnLink {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$ArpMap,
        [Parameter(Mandatory)][string]$MacAddress,
        [scriptblock]$OnLinkVerdict
    )
    $candidates = @()
    if ($ArpMap) { $candidates = @($ArpMap.Keys | Where-Object { $ArpMap[$_] -eq $MacAddress } | Sort-Object) }
    $judged = @(foreach ($address in $candidates) {
        $verdict = if ($OnLinkVerdict) { "$(& $OnLinkVerdict $address)" } else { 'unknown' }
        if ($verdict -ne 'offlink') { [pscustomobject]@{ Address = $address; Verdict = $verdict } }
    })
    if ($judged.Count -eq 0) { return [pscustomobject]@{ Address = $null; Reason = 'no-match' } }
    if ($judged.Count -eq 1) { return [pscustomobject]@{ Address = [string]$judged[0].Address; Reason = 'matched' } }
    $onLink = @($judged | Where-Object { $_.Verdict -eq 'onlink' })
    if ($onLink.Count -eq 1) { return [pscustomobject]@{ Address = [string]$onLink[0].Address; Reason = 'matched' } }
    return [pscustomobject]@{ Address = $null; Reason = 'ambiguous' }
}

<#
.SYNOPSIS
    Resolve a guest's address from passive evidence only: its bundle, the
    shared-NAT lease text and the host ARP table.
.DESCRIPTION
    Sends no Apple Event and probes nothing: no utmctl, no guest-agent
    query, no VM state read, no ICMP sweep. The bundle is read through the
    bounded plist reader; the lease text and ARP lines are what the caller
    captured (the ARP table is read here, bounded, only when neither
    -ArpMap nor -ArpLine is given and -ArpUnavailable is not set).

    A lease match is only a candidate: the lease's hardware field is a DHCP
    DUID, not the bundle MAC, so it does not prove which guest holds the
    address. An address is returned only when an ARP row carries the bundle
    MAC; a lease candidate the ARP table agrees with is 'lease-corroborated',
    and one it does not is reported with Address $null.
.PARAMETER VMName
    The guest.
.PARAMETER BundleNetwork
    Get-UtmBundleNetwork output; read here when not supplied.
.PARAMETER ArpLine
    `arp -an` lines already captured.
.PARAMETER ArpMap
    An address-to-MAC map already built (ConvertFrom-UtmArpLine).
.PARAMETER ArpUnavailable
    The caller's ARP capture failed; do not read the table here.
.PARAMETER LeaseText
    The shared-NAT lease file text; without it no lease candidate is formed.
.PARAMETER OnLinkVerdict
    Scriptblock judging an IPv4 'onlink' | 'offlink' | 'unknown'.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] VMName, Address, Source ('arp-mac' |
    'lease-corroborated' | 'lease-candidate' | 'none'), LeaseCandidate,
    MacAddress, MacCorroborated, Mode, Reason ('resolved' | 'no-bundle' |
    'bundle-unreadable' | 'no-mac' | 'lease-uncorroborated' | 'ambiguous-arp'
    | 'arp-unavailable' | 'not-found' | 'deadline-exhausted'), ElapsedMs.
#>
function Resolve-UtmGuestAddressPassive {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [AllowEmptyCollection()][string[]]$ArpLine,
        [hashtable]$ArpMap,
        [switch]$ArpUnavailable,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        [scriptblock]$OnLinkVerdict,
        $Deadline
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $facts = @{ Mode = ''; Mac = ''; Lease = $null }
    $emit = {
        param($Address, [string]$Source, [bool]$Corroborated, [string]$Reason)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmPassiveAddress'
            VMName = $VMName; Address = $Address; Source = $Source; LeaseCandidate = $facts.Lease
            MacAddress = $facts.Mac; MacCorroborated = $Corroborated; Mode = $facts.Mode; Reason = $Reason
            ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) { return (& $emit $null 'none' $false 'deadline-exhausted') }
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName -Deadline $Deadline }
    if (-not $BundleNetwork) { return (& $emit $null 'none' $false 'no-bundle') }
    if ($BundleNetwork.PSObject.Properties['Readable'] -and -not $BundleNetwork.Readable) { return (& $emit $null 'none' $false 'bundle-unreadable') }
    $facts.Mode = [string]$BundleNetwork.Mode
    $mac = ConvertTo-UtmCanonicalMac -MacAddress ([string]$BundleNetwork.MacAddress)
    if (-not $mac) { return (& $emit $null 'none' $false 'no-mac') }
    $facts.Mac = $mac
    $verdict = if ($OnLinkVerdict) { $OnLinkVerdict } else { { param([string]$IpAddress) $null = $IpAddress; 'unknown' } }
    if ($PSBoundParameters.ContainsKey('LeaseText') -and $LeaseText -and $facts.Mode -ne 'Bridged') {
        $facts.Lease = Get-UtmSharedLeaseIp -VMName $VMName -BundleNetwork $BundleNetwork -LeaseText $LeaseText -OnLinkVerdict $verdict
    }
    $map = $null
    if ($ArpUnavailable) { $map = $null }
    elseif ($PSBoundParameters.ContainsKey('ArpMap')) { $map = $ArpMap }
    elseif ($PSBoundParameters.ContainsKey('ArpLine')) { $map = (ConvertFrom-UtmArpLine -Line $ArpLine).Map }
    else {
        $table = Get-UtmArpTable -Deadline $Deadline
        if ($table.Captured) { $map = (ConvertFrom-UtmArpLine -Line $table.Line).Map }
    }
    if ($null -eq $map) {
        if ($facts.Lease) { return (& $emit $null 'lease-candidate' $false 'lease-uncorroborated') }
        return (& $emit $null 'none' $false 'arp-unavailable')
    }
    $selected = Select-ArpIpByMacOnLink -ArpMap $map -MacAddress $mac -OnLinkVerdict $verdict
    if ($selected.Address) {
        $source = if ($facts.Lease -and $facts.Lease -eq $selected.Address) { 'lease-corroborated' } else { 'arp-mac' }
        return (& $emit $selected.Address $source $true 'resolved')
    }
    if ($selected.Reason -eq 'ambiguous') { return (& $emit $null 'none' $false 'ambiguous-arp') }
    if ($facts.Lease) { return (& $emit $null 'lease-candidate' $false 'lease-uncorroborated') }
    return (& $emit $null 'none' $false 'not-found')
}

<#
.SYNOPSIS
    Capture, once per pass, the passive evidence Get-VMPassiveAddress
    resolves guests against: the ARP table, the shared-NAT lease text and
    this host's subnets.
.DESCRIPTION
    No Apple Event and no probe: one bounded `arp -an`, one file read, one
    bounded ifconfig. Each piece can be injected instead (tests, or a caller
    that already holds it), and each reports how it was obtained.
.PARAMETER Deadline
    Shared deadline (New-YurunaDeadline) bounding the captures.
.PARAMETER ArpOnly
    Skip the lease text.
.PARAMETER ArpLine
    Use these `arp -an` lines instead of reading the table.
.PARAMETER LeaseText
    Use this lease text instead of reading the file.
.PARAMETER SubnetEvidence
    Use this Get-UtmHostSubnetEvidence record instead of reading ifconfig.
.OUTPUTS
    [pscustomobject] PSTypeName 'Yuruna.PassiveAddressContext': ArpMap
    ([hashtable] IPv4 -> 'AA:BB:CC:DD:EE:FF'), ArpConflict [string[]],
    ArpReason ('ok' | 'timeout' | 'tool-failed' | 'deadline-exhausted' |
    'injected'), LeaseText, LeaseReason ('captured' | 'no-file' |
    'read-failed' | 'injected' | 'skipped'), SubnetEvidence, ObservedUnixMs.
#>
function Get-VMPassiveAddressContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Deadline,
        [switch]$ArpOnly,
        [AllowEmptyCollection()][string[]]$ArpLine,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        $SubnetEvidence
    )
    $arpMap = @{}
    $arpConflict = [string[]]@()
    if ($PSBoundParameters.ContainsKey('ArpLine')) {
        $parsed = ConvertFrom-UtmArpLine -Line $ArpLine
        $arpMap = $parsed.Map; $arpConflict = $parsed.Conflict; $arpReason = 'injected'
    } else {
        $table = Get-UtmArpTable -Deadline $Deadline
        $arpReason = switch ($table.Reason) { 'captured' { 'ok' } 'timeout' { 'timeout' } 'deadline-exhausted' { 'deadline-exhausted' } default { 'tool-failed' } }
        if ($table.Captured) { $parsed = ConvertFrom-UtmArpLine -Line $table.Line; $arpMap = $parsed.Map; $arpConflict = $parsed.Conflict }
    }
    $leaseReason = 'skipped'
    $leaseValue = ''
    if ($PSBoundParameters.ContainsKey('LeaseText')) {
        $leaseValue = [string]$LeaseText; $leaseReason = 'injected'
    } elseif (-not $ArpOnly) {
        $lease = Get-UtmSharedLeaseText
        $leaseValue = [string]$lease.Text; $leaseReason = [string]$lease.Reason
    }
    if (-not $PSBoundParameters.ContainsKey('SubnetEvidence') -or -not $SubnetEvidence) {
        $SubnetEvidence = Get-UtmHostSubnetEvidence -Deadline $Deadline
    }
    return [pscustomobject]@{
        PSTypeName     = 'Yuruna.PassiveAddressContext'
        ArpMap         = $arpMap
        ArpConflict    = [string[]]$arpConflict
        ArpReason      = $arpReason
        LeaseText      = $leaseValue
        LeaseReason    = $leaseReason
        SubnetEvidence = $SubnetEvidence
        ObservedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

<#
.SYNOPSIS
    One guest's address from a passive evidence context, with no Apple Event.
.DESCRIPTION
    Resolves against a Get-VMPassiveAddressContext record: the bundle is
    read (bounded), everything else comes from the context. Never calls
    utmctl, osascript, Get-VMState, the guest-agent rung, the bridged-guest
    rung or its ICMP sweep. A lease match with no ARP row carrying the
    bundle MAC is 'lease-only' with Address $null: the lease names a
    candidate, not the guest.
.PARAMETER VMName
    The guest.
.PARAMETER Context
    Get-VMPassiveAddressContext output.
.PARAMETER Deadline
    Shared deadline (New-YurunaDeadline) bounding the bundle read.
.OUTPUTS
    [pscustomobject] VMName, Address, Origin ('shared-lease' | 'arp' |
    'none'), BundlePath, BundleMac, NetworkMode ('Shared' | 'Bridged' | ''),
    MacCorroborated, Reason ('ok' | 'no-bundle' | 'no-mac' | 'lease-only' |
    'arp-miss' | 'ambiguous-arp' | 'deadline-exhausted' | 'tool-failed'),
    ElapsedMs.
#>
function Get-VMPassiveAddress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][AllowNull()]$Deadline
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $bundle = $null
    if (-not $Deadline -or (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -ge 1000) {
        $bundle = Get-UtmBundleNetwork -VMName $VMName -Deadline $Deadline
    }
    $resolveArgs = @{ VMName = $VMName; BundleNetwork = $bundle; Deadline = $Deadline }
    if ($Context.ArpReason -in @('ok', 'injected')) { $resolveArgs['ArpMap'] = [hashtable]$Context.ArpMap } else { $resolveArgs['ArpUnavailable'] = $true }
    if ($Context.LeaseReason -in @('captured', 'injected')) { $resolveArgs['LeaseText'] = [string]$Context.LeaseText }
    if ($Context.SubnetEvidence -and $Context.SubnetEvidence.OnLinkVerdict) { $resolveArgs['OnLinkVerdict'] = $Context.SubnetEvidence.OnLinkVerdict }
    $resolved = if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        [pscustomobject]@{ Address = $null; Source = 'none'; MacCorroborated = $false; Mode = ''; MacAddress = ''; Reason = 'deadline-exhausted' }
    } else {
        Resolve-UtmGuestAddressPassive @resolveArgs
    }
    $origin = switch ($resolved.Source) { 'lease-corroborated' { 'shared-lease' } 'arp-mac' { 'arp' } default { 'none' } }
    # An ARP table the context never read because its deadline ran out is a
    # deadline outcome, not a tool failure: the caller's remedy differs.
    $arpMissing = if ($Context.ArpReason -eq 'deadline-exhausted') { 'deadline-exhausted' } else { 'tool-failed' }
    $reason = switch ($resolved.Reason) {
        'resolved'             { 'ok' }
        'lease-uncorroborated' { 'lease-only' }
        'not-found'            { 'arp-miss' }
        'arp-unavailable'      { $arpMissing }
        'bundle-unreadable'    { 'tool-failed' }
        default                { [string]$resolved.Reason }
    }
    return [pscustomobject]@{
        PSTypeName      = 'Yuruna.PassiveAddress'
        VMName          = $VMName
        Address         = $(if ($reason -eq 'ok') { [string]$resolved.Address } else { $null })
        Origin          = $(if ($reason -eq 'ok') { $origin } else { 'none' })
        BundlePath      = $(if ($bundle) { [string]$bundle.PlistPath } else { '' })
        BundleMac       = [string]$resolved.MacAddress
        NetworkMode     = [string]$resolved.Mode
        MacCorroborated = [bool]$resolved.MacCorroborated
        Reason          = $reason
        ElapsedMs       = $stopwatch.ElapsedMilliseconds
    }
}

<#
.SYNOPSIS
    Resolve a freshly-built UTM bundle's current IPv4 by matching its
    config.plist MAC against the host ARP table -- the reliable identity
    signal for both Shared-NAT and bridged VMs.

.DESCRIPTION
    The bundle's MAC (random per build, written to config.plist) is the
    ONLY stable identity for a just-created VM. Discovery by DHCP hostname
    is unsafe: a rebuilt VM reuses the same hostname, so /var/db/dhcpd_leases
    accumulates stale same-named blocks from deleted predecessors, and the
    lease's hw_address is a DHCP DUID (not the link MAC), so it can't
    disambiguate -- a name lookup that runs before THIS VM has DHCP'd locks
    onto a dead predecessor's IP. Matching the MAC in `arp -an` instead
    always returns the live VM, immune to the DHCP race and stale leases.

    Populates the ARP cache by ICMP-sweeping the subnet in parallel (the VM
    answers ICMP from cloud-init early, before squid binds), then matches
    OUR MAC. When -ProbePort > 0, the candidate must also answer that TCP
    port before it is accepted, so the returned IP is one squid is already
    serving on. Polls until found, until -TimeoutMinutes elapses, or until
    -MaxAttempt sweeps have been made.

.PARAMETER PlistPath
    Path to the bundle's config.plist (holds <key>MacAddress</key>).

.PARAMETER SubnetPrefix
    The /24 to sweep, e.g. '192.168.64.' (Shared-NAT) or the host's LAN
    prefix (bridged). Octets 2..254 are pinged.

.PARAMETER HostIp
    Address to skip in the sweep (the host's own IP on that subnet).

.PARAMETER ProbePort
    If > 0, require this TCP port to answer on the MAC-matched IP before
    accepting it (e.g. squid's 3128). 0 = accept on MAC match alone.

.PARAMETER MaxAttempt
    Cap on sweep-and-match rounds. 0 (the default) means "as many as
    -TimeoutMinutes allows" -- the bring-up scripts wait out a whole guest
    boot that way. 1 makes this a single bounded probe that returns in the
    time one sweep takes, which is what a caller in a per-cycle path needs:
    for it the surrounding poll loop is the retry, and blocking here for
    minutes would cost far more than the answer is worth.

.OUTPUTS
    [string] the matched IPv4, or $null on timeout / missing-MAC.
#>
function Resolve-UtmGuestIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PlistPath,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [string]$HostIp,
        [int]$ProbePort = 0,
        [int]$TimeoutMinutes = 15,
        [int]$PollSeconds = 5,
        [int]$MaxAttempt = 0
    )
    if (-not (Test-Path -LiteralPath $PlistPath)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1db4026c87e87900' -Arguments @{ plistPath = "$PlistPath" })
        return $null
    }
    $plistText = Get-Content -Raw -LiteralPath $PlistPath
    if ($plistText -notmatch '<key>MacAddress</key>\s*<string>([0-9A-Fa-f:]+)</string>') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_acad3d911acdf65d' -Arguments @{ plistPath = "$PlistPath" })
        return $null
    }
    $ourMacRaw = $matches[1]
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $ourMacRaw
    if (-not $macNeedle) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_355f6d92ffafef75' -Arguments @{ ourMacRaw = "$ourMacRaw"; plistPath = "$PlistPath" })
        return $null
    }
    Write-Verbose "Resolve-UtmGuestIpByMac: matching MAC $ourMacRaw (needle '$macNeedle') on ${SubnetPrefix}0/24."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $found = $null
    $attempt = 0
    # A do-loop, so one round always happens: -MaxAttempt 1 has to mean
    # "sweep once and answer", and a while-first shape would decide the
    # deadline had passed before ever looking.
    do {
        $attempt++
        # ICMP-sweep the /24 in parallel to populate the host ARP cache.
        # -t 1 keeps packets on-LAN (TTL 1); -W 200 caps per-host wait at
        # 200 ms; ThrottleLimit 32 holds a 253-address sweep to seconds --
        # measured at ~8 s, so this is never on a path that cannot spare it.
        2..254 |
            Where-Object { "$SubnetPrefix$_" -ne $HostIp } |
            ForEach-Object -Parallel {
                $c = "$using:SubnetPrefix$_"
                try { & /sbin/ping -c 1 -W 200 -t 1 $c *>$null } catch { $null = $_ }
            } -ThrottleLimit 32 | Out-Null

        $candidateIp = Select-ArpIpByMac -ArpLine @(Get-BoundedNativeOutputLine -Result (Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5)) `
            -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
        if ($candidateIp) {
            if ($ProbePort -le 0) { $found = $candidateIp; break }
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidateIp, $ProbePort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    $found = $candidateIp
                    break
                }
            } catch {
                Write-Verbose "Resolve-UtmGuestIpByMac: probe ${candidateIp}:${ProbePort} failed: $($_.Exception.Message)"
            } finally { $tcp.Close() }
            Write-Verbose "Resolve-UtmGuestIpByMac: MAC match at $candidateIp but :$ProbePort not listening yet -- waiting."
        }
        if ($MaxAttempt -gt 0 -and $attempt -ge $MaxAttempt) {
            Write-Verbose "Resolve-UtmGuestIpByMac: no match after $attempt attempt(s); the caller asked for at most $MaxAttempt."
            break
        }
        # Sleep only when another round will follow, so a run that is out of
        # budget returns now instead of one poll interval from now.
        if ((Get-Date).AddSeconds($PollSeconds) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $found
}

# --- REGION: Networking
function Get-ExternalNetwork {
    <#
    .SYNOPSIS
        Return the name of the host-side External-type vSwitch or network.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # macOS UTM uses VMnet shared / VZ NAT; there's no operator-managed
    # 'external network' to pick by name. Return the conventional value
    # so callers can compare without branching on host.
    return 'vmnet-shared'
}

<#
.SYNOPSIS
    True when the host's default-route uplink cannot carry a bridged
    guest MAC -- on macOS that is the Wi-Fi hardware port.
.DESCRIPTION
    QEMU bridged networking is unreliable over Wi-Fi: the access point
    commonly drops frames from the VM's locally-administered MAC, so a
    bridged guest never gets a LAN DHCP lease. Callers use this to fall
    back to UTM Shared NAT (192.168.64.x) + host port-forwarders on Wi-Fi-
    only hosts. Returns $false when the default route is Ethernet/USB-
    Ethernet, or when there is no default route at all (the caller surfaces
    the missing-route error on its own bridged path).

    macOS counterpart of host.windows.hyper-v Test-WindowsUplinkNotBridgeable,
    but the criteria differ by hypervisor: vmnet bridges USB Ethernet fine
    (it is plain wired Ethernet here), so only Wi-Fi is rejected -- whereas
    Hyper-V's External vSwitch also rejects USB NICs.
.OUTPUTS
    [bool]
#>
function Test-MacUplinkNotBridgeable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $iface = $null
    foreach ($line in (& '/sbin/route' -n get default 2>$null)) {
        if ($line -match 'interface:\s*(\S+)') { $iface = $matches[1]; break }
    }
    if (-not $iface) { return $false }
    # networksetup -listallhardwareports prints stanzas of the form:
    #   Hardware Port: Wi-Fi
    #   Device: en0
    #   Ethernet Address: ...
    # Collect the Device of every Wi-Fi port, then test the default-route
    # interface for membership.
    $wifiDevices = [System.Collections.Generic.List[string]]::new()
    $portIsWifi  = $false
    foreach ($line in (& '/usr/sbin/networksetup' -listallhardwareports 2>$null)) {
        if ($line -match '^Hardware Port:\s*(.+?)\s*$') {
            $portIsWifi = ($matches[1] -match 'Wi-?Fi')
            continue
        }
        if ($portIsWifi -and $line -match '^Device:\s*(\S+)') {
            $wifiDevices.Add($matches[1])
            $portIsWifi = $false
        }
    }
    return ($wifiDevices -contains $iface)
}

<#
.SYNOPSIS
    Create the host-side External-type vSwitch or network if missing.
#>
function New-ExternalNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess('vmnet-shared', (Format-YurunaOperatorMessage -Key 'host.operator_0da6776e773e7f47'))) { return $null }
    return 'vmnet-shared'
}

<#
.SYNOPSIS
    Returns true if the caching-proxy-service VM is on an External-type network.
.DESCRIPTION
    On macOS the cache VM is built with UTM's QEMU bridged networking on
    an Ethernet default route (see
    host/macos.utm/guest.caching-proxy-service/config.plist.template; Wi-Fi
    hosts fall back to Shared NAT + host forwarders), so it
    rides the host's physical LAN with its own DHCP-assigned IP. That
    is the macOS analog of Hyper-V's Yuruna-External vSwitch path: the
    caller's "no host portproxy needed" fast path applies unconditionally
    on this host. VMName is accepted for cross-host parity (Hyper-V
    consults Get-VMNetworkAdapter); we never look at the VM here.
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    Write-Debug "Test-CacheVMOnExternalNetwork on host.macos.utm: returning `$true for '$VMName' (cache VM is QEMU-bridged to the host's physical NIC)."
    return $true
}

<#
.SYNOPSIS
    Install host to VM port forwarders for the caching-proxy service.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @()
    )
    if (-not $PSCmdlet.ShouldProcess($VMIp, (Format-YurunaOperatorMessage -Key 'host.operator_0c74b58906c540e7' -Arguments @{ join = "$($Port -join ',')" }))) { return $false }
    if (-not (Test-Ipv4Address $VMIp)) {
        # macOS Add-PortMap drives the host-side pwsh forwarders that bind
        # IPv4 sockets to the cache VM. v6 inputs (which Test-IpAddress
        # accepts as operator-facing values elsewhere) are rejected here
        # because the forwarder mechanism currently targets v4.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_88bea28586a2663a' -Arguments @{ vMIp = "$VMIp" })
        return $false
    }
    $proxyProtoSet = @{}
    foreach ($p in $ProxyProtocolPort) { $proxyProtoSet[[int]$p] = $true }
    $remapHostPorts = @{}
    foreach ($k in $PortRemap.Keys) { $remapHostPorts[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if ($remapHostPorts.ContainsKey([int]$p)) { continue }
        $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
    }
    foreach ($k in $remapHostPorts.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remapHostPorts[$k] }
    }
    # Apple VZ shared-NAT path: per-port pwsh TcpListener via Yuruna.Host.psm1's
    # Start-CachingProxyServiceForwarder. Each call is idempotent per port and
    # leaves OTHER ports' forwarders alone -- mid-cycle :3000 refresh
    # MUST NOT disturb the running :3128 forwarder.
    $launched = @()
    $failed = @()
    $attempted = 0
    foreach ($m in $mappings) {
        $useProxy = $proxyProtoSet.ContainsKey([int]$m.HostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)${proxyTag}", (Format-YurunaOperatorMessage -Key 'host.operator_832575bbe1b2f32f'))) { continue }
        $attempted++
        $started = if ($useProxy) {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort -PrependProxyV1
        } else {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort
        }
        if ($started) { $launched += $m.HostPort } else { $failed += $m.HostPort }
    }
    if ($failed.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_68cc3422228bb646' -Arguments @{ join = "$($failed -join ', ')" })
    }
    # Report success only when EVERY attempted forwarder launched. A partial launch reported as
    # success hides a missing forwarder (e.g. :3128 / :3129 / SSH) so downstream guest fetches
    # silently bypass or fail against the cache with no recovery triggered.
    return ($attempted -gt 0 -and $launched.Count -eq $attempted)
}

<#
.SYNOPSIS
    Tear down all yuruna caching-proxy-service port forwarders.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('pwsh forwarders', (Format-YurunaOperatorMessage -Key 'host.operator_f3f37ca41e1f0e2f'))) { return $false }
    $stopped = @(Stop-AllCachingProxyServiceForwarder)
    return ($stopped.Count -gt 0)
}

<#
.SYNOPSIS
    Return the host's best LAN-routable IPv4 for browser-facing URLs.
#>
function Get-BestHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # `route -n get default` -> default-route interface, then
    # `ipconfig getifaddr <iface>` for that interface's IPv4. Skips
    # loopback / utun / VZ bridges (no default route).
    $routeOut = & '/sbin/route' -n get default 2>$null
    $iface = $null
    foreach ($line in $routeOut) {
        if ($line -match 'interface:\s*(\S+)') { $iface = $matches[1]; break }
    }
    if (-not $iface) { return $null }
    $ip = "$( & '/usr/sbin/ipconfig' getifaddr $iface 2>$null )".Trim()
    if (Test-Ipv4Address $ip) { return $ip }
    return $null
}

<#
.SYNOPSIS
    Hands artifacts written by a root-run build back to the operator who
    invoked sudo. Returns $true when ownership was restored. No-op off macOS,
    when not running as root, or when sudo did not name an invoking user.

.DESCRIPTION
    A UTM bundle created under sudo is root-owned, and UTM.app runs as the
    operator -- it cannot open, start, or later delete such a bundle. The
    parents matter as much as the bundle: removing a directory needs write
    permission on the directory ABOVE it, and ~/yuruna/guest.nosync is shared by
    every macOS builder, so one root-run build blocks every later rebuild.
    Restoring the whole tree is therefore the fix; restoring the bundle alone
    repairs this run and breaks the next.

    This is a GUARD, not a license to run these scripts under sudo: root has no
    Aqua session, so `open`, `utmctl` and the osascript dialog watchdog fail
    before ownership is ever reached. The supported invocation is unelevated --
    the scripts request sudo per operation.
#>
function Restore-SudoUserOwnership {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Path)
    if (-not $IsMacOS) { return $false }
    $sudoUser = "$env:SUDO_USER".Trim()
    if (-not $sudoUser -or $sudoUser -eq 'root') { return $false }
    if ((Get-UtmCurrentUid) -ne '0') { return $false }

    # Plain `sudo` (without -E) resets HOME to /var/root, so a build launched
    # that way put every artifact in root's home, where chown cannot help --
    # the operator cannot traverse into it. Say so instead of silently
    # "succeeding" on a tree they will never see.
    $homeRead = Invoke-UtmHostTool -Tool 'dscl' -ArgumentList @('.', '-read', "/Users/$sudoUser", 'NFSHomeDirectory') -TimeoutSeconds 10
    $sudoUserHome = ''
    if ((Test-UtmBoundedResultComplete -Result $homeRead) -and $homeRead.ExitCode -eq 0) {
        $sudoUserHome = ("$($homeRead.StdOut)" -replace '^NFSHomeDirectory:\s*', '').Trim()
    }
    if ($sudoUserHome -and $HOME -and -not $HOME.StartsWith($sudoUserHome)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_82599fffc9de7081' -Arguments @{ hOME = "$HOME"; sudoUserHome = "$sudoUserHome"; sudoUser = "$sudoUser" })
    }

    $restored = $false
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if (-not $PSCmdlet.ShouldProcess($p, (Format-YurunaOperatorMessage -Key 'host.operator_06c9287f29190c68' -Arguments @{ sudoUser = "$sudoUser" }))) { continue }
        & /usr/sbin/chown -R "$sudoUser" $p 2>$null
        if ($LASTEXITCODE -eq 0) { $restored = $true }
        else { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_372aa49990c2bacc' -Arguments @{ p = "$p"; sudoUser = "$sudoUser" }) }
    }
    if ($restored) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_89f0c1507d2b052b' -Arguments @{ sudoUser = "$sudoUser" }) -InformationAction Continue }
    return $restored
}

<#
.SYNOPSIS
    Returns the network mode a UTM service VM must be built with on this host:
    'Bridged' on an Ethernet default route, 'Shared' on a Wi-Fi one.

.DESCRIPTION
    The mode and the address a guest reaches the host at are a matched pair --
    the address only works from the network it was derived for -- so both are
    resolved from this one verdict. Bridged is preferred: the VM takes a LAN
    DHCP lease and peers reach its services at <vm-lan-ip> directly. vmnet
    cannot bridge a Wi-Fi uplink (the AP drops frames from the VM's
    locally-administered MAC), so a Wi-Fi default route falls back to UTM
    Shared NAT and the caller forwards host ports for LAN reach.

    USB Ethernet bridges fine here (it is plain wired Ethernet to vmnet),
    unlike Hyper-V -- so a dongle turns a Wi-Fi laptop into the Bridged case.

.OUTPUTS
    [string] 'Bridged' or 'Shared'.
#>
function Resolve-UtmNetworkMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-MacUplinkNotBridgeable) { return 'Shared' }
    return 'Bridged'
}

<#
.SYNOPSIS
    Returns the host IP a UTM guest reaches the host at, for the network mode
    that guest is attached to.

.DESCRIPTION
    On Apple Virtualization shared NAT -- the mode every install guest uses,
    and the default here -- guests always reach the host at 192.168.64.1, the
    VZ gateway IP set by the framework and not configurable per VM.

    A Bridged guest sits on the LAN instead and cannot reach that gateway at
    all, so it reaches the host at the host's own LAN address. Callers that
    build Bridged VMs (the service VMs, via Resolve-UtmNetworkMode) must pass
    -NetworkMode Bridged or they bake an address the guest cannot route to.
    Returns $null when Bridged is asked for and the host has no LAN address:
    there is no correct answer to fall back to, and an empty value makes the
    caller degrade honestly rather than bake the wrong gateway.

.PARAMETER SwitchName
    Accepted for cross-host contract parity (Hyper-V uses it to choose
    Default Switch vs. External vSwitch); unused on macOS.

.PARAMETER NetworkMode
    The mode the consuming guest is attached to. Defaults to 'Shared', which
    is what every caller that does not build a Bridged VM wants.

.OUTPUTS
    [string] the VZ gateway address, the host's LAN IPv4, or $null.
#>
function Get-GuestReachableHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [ValidateSet('Shared', 'Bridged')][string]$NetworkMode = 'Shared'
    )
    # macOS has no Default Switch / External vSwitch concepts; SwitchName
    # is accepted for cross-host parity and the mode decides the answer.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.macos.utm: -SwitchName '$SwitchName' ignored; the network mode selects the address." }
    if ($NetworkMode -eq 'Bridged') {
        $lanIp = Get-BestHostIp
        if ($lanIp) { return $lanIp }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_133c681126464a2b')
        return $null
    }
    return '192.168.64.1'
}

# --- REGION: Caching-proxy service
function Get-HostLanPrefix {
    <#
    .SYNOPSIS
        Returns the host's LAN /24 prefix (e.g. '192.168.7.') based on the
        default-route interface, or $null when the host has no default route.
    .DESCRIPTION
        This is the /24 a bridged guest is looked for on: it sits on the host's
        LAN by construction, so the host's own default-route subnet is where its
        address must be. (It is NOT consulted by
        Test-CachingProxyServiceAvailable, which is restricted to state-file +
        YURUNA_CACHING_PROXY_SERVICE_IP discovery.) Returns the first three
        octets with a trailing dot so the caller can append "$prefix$octet"
        without further string surgery. /24 is an assumption -- it matches the
        home/office DHCP setups the repo targets; a /23 LAN would silently miss
        half the address space. Acceptable trade-off given the alternative is
        parsing the netmask from `ifconfig` output for what is, in practice, a
        /24 99% of the time.
    .PARAMETER HostIp
        The host address to take the prefix from. Resolved with Get-BestHostIp
        when not supplied; a caller that already has it passes it so the
        default-route lookup (two process spawns) is not repeated.
    .OUTPUTS
        [string] e.g. '192.168.7.' (with trailing dot), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$HostIp)
    if (-not $PSBoundParameters.ContainsKey('HostIp')) { $HostIp = Get-BestHostIp }
    if (-not $HostIp) { return $null }
    if ($HostIp -notmatch '^(\d+\.\d+\.\d+)\.(\d+)$') { return $null }
    return ($matches[1] + '.')
}

<#
.SYNOPSIS
    Probe and return the caching-proxy-service URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_SERVICE_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyServiceState).ipAddress -- the cache VM's
         LAN IP written by Start-CachingProxyServiceVM.ps1 Step 4 (our own VM).

    No LAN scan, no ARP discovery. The previous /24 subnet scan would
    happily lock onto a sibling host's yuruna-caching-proxy-service on the same
    LAN and even persist its IP back into the state file, so Stop-
    CachingProxyService could not actually take the local host out of the
    "cache available" state when a peer was still serving on :3128.
    LAN-wide cache discovery is a separate future feature.

    Returns the cache VM's LAN URL directly -- no host-side forwarder
    layer to fail in between, no VZ-gateway URL gymnastics. This is the
    macOS equivalent of the Hyper-V Yuruna-External vSwitch path: squid
    sees real client IPs at TCP level, remote operators set
    YURUNA_CACHING_PROXY_SERVICE_IP=<cache-lan-ip> and reach the cache directly,
    and other UTM guests on shared-NAT reach the LAN IP through the
    VMnet outbound NAT (same path they use to reach Ubuntu mirrors).
#>
function Test-CachingProxyServiceAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Quiet)
    # Thin wrapper over the shared probe; the only platform variable is the
    # operator verify-command template embedded in the unreachable-cache
    # warning (nc on macOS). The kvm driver keeps its own probe (it omits
    # Format-IpUrlHost's IPv6 bracketing the guests rely on). -Quiet drops the
    # "no cache" diagnostics to verbose for callers that only decorate with a
    # cache URL when one exists.
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'nc -G 2 -z {0} {1}' -Quiet:$Quiet
}

<#
.SYNOPSIS
    Return the cache VM's LAN IP, or $null when none is recorded yet.
.DESCRIPTION
    With Apple Virtualization bridged networking the cache VM gets its
    own DHCP-assigned LAN IP (no VZ-gateway indirection), so the URL
    Test-CachingProxyServiceAvailable returns already carries the real IP. This
    helper exists for callers that want JUST the IP (status service's
    portproxy IP target on Windows; on macOS the result feeds into
    summary lines and YURUNA_CACHING_PROXY_SERVICE_IP hints).
#>
function Get-CachingProxyServiceVmIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-Ipv4Address $ip)) { return $ip }
    return $null
}

# --- REGION: Host config
function Set-HostProxy {
    <#
    .SYNOPSIS
        Promote a proxy URL to the machine-wide host proxy with backup.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProxyUrl,
        [string]$NetworkService
    )
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b8a5ce8d9003b608'), (Format-YurunaOperatorMessage -Key 'host.operator_1d67149dffd75755' -Arguments @{ proxyUrl = "$ProxyUrl" }))) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9a18fc9562c73b34')
    }
    # Idempotent backup: only snapshot BEFORE the first apply, so a
    # repeat Set-HostProxy doesn't overwrite the backup with the
    # squid-promoted state.
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $state = Read-MacProxyState -NetworkService $svc
        $state['timestamp']  = (Get-Date).ToUniversalTime().ToString('o')
        $state['promotedTo'] = $parts.Url
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_e7819cb03343b1e1' -Arguments @{ backupPath = "$backupPath" })
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_d8f19d509742ffe8' -Arguments @{ backupPath = "$backupPath" })
    }
    Set-MacHostProxy -ProxyParts $parts -NetworkService $svc -Confirm:$false
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_ba4025ead45708af' -Arguments @{ svc = "$svc"; url = "$($parts.Url)" })
    return $true
}

<#
.SYNOPSIS
    Restore the host proxy from the saved backup, or disable if none.
#>
function Clear-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b8a5ce8d9003b608'), (Format-YurunaOperatorMessage -Key 'host.operator_ca5c5716704ce8c4'))) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = $null
    if (Test-Path -LiteralPath $backupPath) {
        try {
            $state = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bea0e70f89d3d54c' -Arguments @{ backupPath = "$backupPath"; message = "$($_.Exception.Message)" })
            $state = $null
        }
    }
    if ($state) {
        Invoke-MacElevationIfNeeded
        Restore-MacHostProxy -State $state
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_1b177181d83a9078' -Arguments @{ networkService = "$($state.networkService)" })
    } else {
        try { Invoke-MacElevationIfNeeded } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_62b64e15fd55e2e0' -Arguments @{ message = "$($_.Exception.Message)" })
            return $false
        }
        Disable-MacHostProxy
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_2ddcdf5273a49efa')
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Aggressively wipe every host-proxy reference and the backup file.
#>
function Remove-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$NetworkService)
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_49b535bc8f7577f0'), (Format-YurunaOperatorMessage -Key 'host.operator_0b42b69cacf83715'))) { return $false }
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fac07fa116ddd338')
        return $false
    }
    Remove-MacHostProxy -NetworkService $svc
    # Verify the wipe actually took. networksetup silently ignores invalid
    # service names and `-setwebproxy` re-enables state as a side-effect, so
    # the log line below has to be earned, not asserted. Parse the live
    # state and refuse to claim "wiped" if web/secure web is still Enabled.
    $webProbe = ''
    $sslProbe = ''
    try {
        $webProbe = (& networksetup -getwebproxy        $svc) 2>&1 | Out-String
        $sslProbe = (& networksetup -getsecurewebproxy  $svc) 2>&1 | Out-String
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f32f219fa4e39d9e' -Arguments @{ message = "$($_.Exception.Message)"; svc = "$svc" })
    }
    $webEnabled = ($webProbe -match '(?m)^Enabled:\s*Yes')
    $sslEnabled = ($sslProbe -match '(?m)^Enabled:\s*Yes')
    if ($webEnabled -or $sslEnabled) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_172e01672f44afab' -FormatValues ($svc, $webEnabled, $sslEnabled, $webProbe.TrimEnd(), $sslProbe.TrimEnd()) -FormatBindings @{ svc = '0'; webEnabled = '1'; sslEnabled = '2'; trimEnd = '3'; trimEnd2 = '4' })
        return $false
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_d4f53d6a06fdcc8f' -Arguments @{ svc = "$svc" })
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Return the path of the host-proxy backup JSON.
#>
function Get-HostProxyBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Yuruna.Common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # There is no separate framework probe: host enablement runs through
    # Enable-TestAutomation.ps1 -> Set-MacHostConditionSet, not a module
    # function. UTM's presence + Apple Virtualization availability is
    # the practical signal here.
    return [bool](Test-Path '/Applications/UTM.app')
}

# --- REGION: Exports
Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, Get-VMConsoleSecondOpinion, `
    Wait-VMIp, Get-VMIp, Get-VMMac, Update-GuestNeighborCache, Resolve-UtmGuestIpByMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, Get-HostLanPrefix, Test-MacUplinkNotBridgeable, Resolve-UtmNetworkMode, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    Test-VirtualizationResponsive, Start-VirtualizationServiceIfStopped, `
    `
    Remove-UtmBundleWithRetry, Invoke-EntitledSwift, `
    Start-CachingProxyServiceForwarder, Stop-CachingProxyServiceForwarder, Get-CachingProxyServiceForwarder, Stop-AllCachingProxyServiceForwarder, `
    Test-DownloadAlreadyCurrent, Test-CachingProxyServicePort, Resolve-CacheHostIp, `
    Save-CachedHttpUri, `
    Stop-UtmDialogWatchdog, Start-UtmDialogWatchdog, `
    Confirm-UtmVMCreated, Remove-UtmTestVM, Test-UtmVMRegistered, Get-UtmVMRegistrationState, Remove-UtmVMRegistration, Start-UtmVM, Stop-UtmVM, Confirm-UtmVMStarted, Wait-UtmVMPoweredOff, Restart-UtmConsole, `
    Get-RunningVmName, Test-UtmctlResponsive, Invoke-UtmctlProbe, Assert-NoConcurrentUtmVm, Resume-YurunaServiceVM, `
    Resolve-UtmctlExecutable, Invoke-UtmctlLifecycle, Get-VMStateRecord, Get-UtmRunningVmInventory, `
    Get-UtmApplicationState, Get-UtmControlPrerequisite, Stop-UtmApplication, Start-UtmApplication, Restart-UtmApplication, `
    Get-UtmBundleNetwork, Get-UtmArpTable, Get-UtmHostSubnetEvidence, Get-UtmSharedLeaseText, Resolve-UtmGuestAddressPassive, `
    Get-VMPassiveAddressContext, Get-VMPassiveAddress, Get-PortMapTarget, `
    Get-MacProxyMarkerPath, Test-MacProxyIsYurunaManaged, Get-MacActiveNetworkService, Read-MacProxyState, `
    Invoke-MacElevationIfNeeded, Invoke-MacNetworksetup, `
    Set-MacHostProxy, Restore-MacHostProxy, Disable-MacHostProxy, Remove-MacHostProxy, `
    Get-UtmNetworkModeFromBundle, Restore-SudoUserOwnership, `
    Get-VncDisplayForVm, Get-VncPortForVm, Get-VncDisplayFromBundle, Set-VncDisplayInBundle, Test-VncPortFree, Find-FreeVncDisplay, Get-ClaimedVncDisplay, Get-VncScreenshot, Get-UtmScreenshot, Get-UtmWindowScreenshot, Get-UtmVMProcessId, `
    Set-GuestMacInBundle

# --- REGION: Contract coverage
# Validate actual exports against the common contract after publishing them.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'macos.utm' `
    -Module $ExecutionContext.SessionState.Module -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac','Update-GuestNeighborCache',
    'Get-ExternalNetwork','New-ExternalNetwork','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp','Get-HostLanPrefix',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization',
    'Test-VirtualizationResponsive','Start-VirtualizationServiceIfStopped'
)

# Load-time guard for the cache-download wrapper precedence. The image helpers
# (Save-ImageWithChecksum / Save-UbuntuServerImage) feature-detect Save-CachedHttpUri
# BY NAME and invoke it with only -Uri/-OutFile, so this driver's 2-param wrapper
# must win the command-table slot over the shared 3-param
# Yuruna.HostDownload\Save-CachedHttpUri. If an import-order change flips that
# precedence the cache-discovery closure is dropped and downloads silently bypass
# the squid cache (direct, no error) -- surface that regression loudly here.
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9cd70c93af7ab7e6')
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1f268a9fcff06a4e')
}
