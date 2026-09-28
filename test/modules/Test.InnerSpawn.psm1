<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42a27240-9228-4384-9324-f2bcf259469f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Two launch shapes for a fresh child pwsh live here.
#
# New-InnerRunnerArgList builds the -Command vector the runner uses for its
# inner and per-cycle children:
# Why -Command (not -File):
#   pwsh's -File parameter binder coerces every argv token to [string],
#   which breaks [bool]/[int] inner parameters. -Command parses the line
#   as PowerShell so $true/$false/0/1 keep their types.
# Why -NoProfile:
#   $PROFILE in the launching shell can re-set YURUNA_* env vars in the
#   child AFTER the parent's snapshot pinned the right values.
# Why a helper module:
#   Start-TestRunner.ps1, Invoke-TestProject.ps1 and Invoke-TestCycleRunner.ps1
#   all need the same single-quote escaping + -Command construction; duplicated,
#   a quoting-edge-case fix in one would not reach the others.
#
# Start-YurunaDetachedProcess launches a worker that must outlive its
# launcher -- a host-refresh worker, a restarted runner -- with -File, one
# argument per element, -NonInteractive, and all three streams detached from
# the launcher. On POSIX the stream paths travel in the environment and every
# argument is a positional parameter of a fixed `set -m; nohup "$@"` body, so
# no caller value is ever interpolated into shell text; `set -m` rather than
# setsid gives the child its own process group, because macOS has no setsid.
# On Windows a first hop, started without redirected handles, launches the
# final worker with the redirections: a launcher that redirects hands every
# inheritable handle it holds to its child, which is what keeps a caller's
# wait from ever returning.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking

function New-InnerRunnerArgList {
    <#
    .SYNOPSIS
        Build the @('-NoLogo','-NoProfile','-Command', "& '<script>' -A 'b' ...") array used to spawn a child pwsh that runs $ScriptPath with typed parameters.
    .DESCRIPTION
        Escapes single quotes by doubling them. Preserves [bool] / [int] /
        [double] / [SwitchParameter] types by emitting the appropriate
        literal form. The caller invokes pwsh with the returned array:
            & $pwshExe @argList
    .PARAMETER ScriptPath
        Absolute path to the .ps1 to run.
    .PARAMETER Parameters
        Hashtable or IDictionary of parameter name -> value. Switch
        parameters are emitted only when present (and IsPresent=$true).
        Bool / int / double values are emitted as PowerShell literals so
        the binder preserves the type.
    .PARAMETER ExcludeParameter
        Names that exist in $Parameters but must NOT be forwarded -- e.g.
        outer-only switches like -NoConfigGate that the inner does not
        accept.
    .PARAMETER NonInteractive
        Insert -NonInteractive after -NoProfile, so a child that shares the
        launching terminal refuses any prompt instead of blocking on it.
    .OUTPUTS
        [string[]] -- pass with @ splatting to `& $pwshExe`.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Pure builder; no externally observable state change.')]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [string[]]$ExcludeParameter = @(),
        [switch]$NonInteractive
    )
    $escapedScript = $ScriptPath -replace "'", "''"
    $cmdParts = @("& '$escapedScript'")
    foreach ($k in $Parameters.Keys) {
        if ($ExcludeParameter -contains $k) { continue }
        $v = $Parameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $cmdParts += "-$k" }
        } elseif ($v -is [bool]) {
            $cmdParts += "-$k"
            $cmdParts += $(if ($v) { '$true' } else { '$false' })
        } elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
            $cmdParts += "-$k"
            $cmdParts += "$v"
        } else {
            $escaped = ("$v") -replace "'", "''"
            $cmdParts += "-$k"
            $cmdParts += "'$escaped'"
        }
    }
    if ($NonInteractive) {
        return @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ($cmdParts -join ' '))
    }
    return @('-NoLogo', '-NoProfile', '-Command', ($cmdParts -join ' '))
}

function Get-PwshExePath {
    <#
    .SYNOPSIS
        Returns the path of the currently running pwsh binary so a child
        spawn uses the same edition (PS 7.x) as the parent.
    .DESCRIPTION
        Resolution order, most reliable first:
          1. [Environment]::ProcessPath - the real executable image that
             started this process (macOS _NSGetExecutablePath, Linux
             /proc/self/exe, Windows post-alias-resolution path, so it
             never hands back the zero-byte WindowsApps app-execution-alias
             stub -- see feedback_windows_appalias_firewall_trap.md). Absent
             on PS 7.0/7.1 (.NET below 6); the try/catch keeps it null there
             (even under Set-StrictMode) instead of throwing, so resolution
             falls through.
          2. (Get-Process -Id $PID).Path - it equals MainModule.FileName,
             which is null/empty on macOS (no /proc; libproc only best-effort
             populates MainModule) and can throw on protected processes, so it
             is wrapped too. This is the value the rest of the chain exists to
             survive.
          3. $PSHOME/pwsh[.exe] - the install dir of the running runtime,
             always populated under #requires -version 7. Test-Path before
             use so a stale path is never handed to the & call operator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $exe = $null
    try { $exe = [Environment]::ProcessPath } catch { $exe = $null }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        try { $exe = (Get-Process -Id $PID).Path } catch { $exe = $null }
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $leaf      = $IsWindows ? 'pwsh.exe' : 'pwsh'
        $candidate = Join-Path $PSHOME $leaf
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    return $exe
}

# --- REGION: Detached launch
# Identity comparisons across the handshake agree only to within the same
# small start-time window the runner records use.
$script:DetachStartToleranceMs = 2000

# The POSIX launcher body. Fixed text: the working directory and the stdin
# path arrive as $1 and $2, the command vector as the rest, and the stream
# paths through the environment -- nothing a caller supplies is interpolated
# into it. `set -m` puts the background job in its own process group.
$script:DetachShellBody = 'set -m; cd -- "$1" || exit 97; detach_stdin=$2; shift 2; nohup "$@" <"$detach_stdin" >"$YURUNA_DETACH_STDOUT" 2>"$YURUNA_DETACH_STDERR" & echo $!'

function Get-YurunaDetachPlatform {
    <#
    .SYNOPSIS
        Linux, MacOS or Windows for the running process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS) { return 'MacOS' }
    return 'Linux'
}

function Get-YurunaDetachUnixMs {
    <#
    .SYNOPSIS
        A DateTime as Unix milliseconds (UTC).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a time value is named <Name>Ms so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][datetime]$Value)
    $utc = if ($Value.Kind -eq [DateTimeKind]::Utc) { $Value } else { $Value.ToUniversalTime() }
    return [long]([DateTimeOffset]::new([DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc))).ToUnixTimeMilliseconds()
}

function Get-YurunaDetachProcessIdentity {
    <#
    .SYNOPSIS
        { Pid; StartTimeUnixMs; ParentPid; ProcessGroupId; OwnerId } for a
        process, from /proc on Linux, a bounded ps on macOS, CIM on Windows.
    .DESCRIPTION
        The ps and CIM lookups are bounded by 5 s and, when given, by the
        caller's deadline; a spent deadline skips them and leaves those
        fields $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int]$ProcessId = $PID, [psobject]$Deadline)
    $out = [ordered]@{ Pid = $ProcessId; StartTimeUnixMs = $null; ParentPid = $null; ProcessGroupId = $null; OwnerId = $null }
    $seconds = if ($Deadline) { Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 5 } else { 5 }
    try { $out.StartTimeUnixMs = Get-YurunaDetachUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($ProcessId).StartTime) } catch {
        Write-Verbose "Start time of pid $ProcessId unreadable: $($_.Exception.Message)"
    }
    switch (Get-YurunaDetachPlatform) {
        'Linux' {
            try {
                $stat = [System.IO.File]::ReadAllText("/proc/$ProcessId/stat")
                $rest = $stat.Substring($stat.LastIndexOf(')') + 1).Trim() -split '\s+'
                $out.ParentPid = [int]$rest[1]
                $out.ProcessGroupId = [int]$rest[2]
                foreach ($line in [System.IO.File]::ReadAllLines("/proc/$ProcessId/status")) {
                    if ($line -match '^Uid:\s+(\d+)') { $out.OwnerId = $Matches[1]; break }
                }
            } catch {
                Write-Verbose "/proc identity of pid $ProcessId unreadable: $($_.Exception.Message)"
            }
        }
        'MacOS' {
            if (-not $seconds) { break }
            $call = @{ FilePath = '/bin/ps'; ArgumentList = @('-o', 'ppid=,pgid=,uid=', '-p', "$ProcessId"); TimeoutSeconds = $seconds; Environment = @{ LC_ALL = 'C' } }
            if ($Deadline) { $call.Deadline = $Deadline }
            $r = Invoke-BoundedNativeCommand @call
            if ((Test-BoundedNativeResultComplete -Result $r) -and $r.ExitCode -eq 0) {
                $fields = ([string]$r.StdOut).Trim() -split '\s+'
                if ($fields.Count -ge 3) {
                    $out.ParentPid = [int]$fields[0]; $out.ProcessGroupId = [int]$fields[1]; $out.OwnerId = [string]$fields[2]
                }
            }
        }
        'Windows' {
            if (-not $seconds) { break }
            try {
                $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -Property ParentProcessId, SessionId -OperationTimeoutSec $seconds -ErrorAction Stop
                if ($cim) { $out.ParentPid = [int]$cim.ParentProcessId; $out.OwnerId = [string]$cim.SessionId }
            } catch {
                Write-Verbose "CIM identity of pid $ProcessId unreadable: $($_.Exception.Message)"
            }
        }
    }
    return [pscustomobject]$out
}

function Test-YurunaWindowsPathArgument {
    <#
    .SYNOPSIS
        $true when a path argument carries no character Windows forbids in a
        file name position the encoder could not safely pass: ", <, >, |, ?,
        * or NUL.
    .PARAMETER Path
        The path argument.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return ($Path.IndexOfAny([char[]]@('"', '<', '>', '|', '?', '*', [char]0)) -lt 0)
}

function ConvertTo-YurunaWindowsCommandLine {
    <#
    .SYNOPSIS
        Join arguments into one Windows command line that CommandLineToArgvW
        (and the MSVCRT parser) splits back into exactly those arguments.
    .DESCRIPTION
        An argument is quoted when it is empty or contains a space, tab,
        newline or double quote. Inside quotes, backslashes immediately
        before a double quote are doubled and the quote escaped; trailing
        backslashes are doubled so they do not escape the closing quote.
        Other characters, non-ASCII included, pass through unchanged.
        Start-Process joins -ArgumentList elements with spaces and quotes
        nothing, which is why a pre-encoded single string is passed instead.
    .PARAMETER Argument
        The arguments, one per element.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Argument)
    $encoded = foreach ($item in $Argument) {
        $text = [string]$item
        if ($text.Length -gt 0 -and $text.IndexOfAny([char[]]@(' ', "`t", "`n", "`v", '"')) -lt 0) {
            $text
            continue
        }
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq '\') {
                $backslashes++
            } elseif ($ch -eq '"') {
                [void]$builder.Append([char]92, (2 * $backslashes) + 1)
                [void]$builder.Append('"')
                $backslashes = 0
            } else {
                if ($backslashes -gt 0) { [void]$builder.Append([char]92, $backslashes) }
                [void]$builder.Append($ch)
                $backslashes = 0
            }
        }
        if ($backslashes -gt 0) { [void]$builder.Append([char]92, 2 * $backslashes) }
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return (@($encoded) -join ' ')
}

function Test-YurunaPathInside {
    <#
    .SYNOPSIS
        $true when Path lies inside Directory (full paths, same comparison as
        the platform's file system).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Directory)
    $comparison = if ((Get-YurunaDetachPlatform) -eq 'Linux') { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $full.StartsWith($dir + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-YurunaDetachArgument {
    <#
    .SYNOPSIS
        Validate Start-YurunaDetachedProcess paths; returns '' when valid or
        the name of the first offending argument.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Path, [Parameter(Mandatory)][string]$PrivateDirectory, [string[]]$ArgumentList)
    $platform = Get-YurunaDetachPlatform
    if (-not [System.IO.Path]::IsPathFullyQualified($PrivateDirectory) -or -not [System.IO.Directory]::Exists($PrivateDirectory)) { return 'PrivateDirectory' }
    foreach ($name in @('FilePath', 'WorkingDirectory', 'StdOutPath', 'StdErrPath', 'StdInPath', 'HandshakePath')) {
        $value = $Path[$name]
        if ($null -eq $value) { continue }
        if (-not [System.IO.Path]::IsPathFullyQualified($value)) { return $name }
        if ($platform -eq 'Windows' -and -not (Test-YurunaWindowsPathArgument -Path $value)) { return $name }
        $nullDevice = ($platform -ne 'Windows') -and ($value -eq '/dev/null')
        if ($name -in @('StdOutPath', 'StdErrPath', 'StdInPath', 'HandshakePath') -and -not $nullDevice -and
            -not (Test-YurunaPathInside -Path $value -Directory $PrivateDirectory)) {
            return $name
        }
        if ($name -eq 'HandshakePath' -and $nullDevice) { return $name }
    }
    if (-not [System.IO.File]::Exists($Path.FilePath)) { return 'FilePath' }
    if (-not [System.IO.Directory]::Exists($Path.WorkingDirectory)) { return 'WorkingDirectory' }
    if ($platform -eq 'Windows') {
        foreach ($argument in @($ArgumentList)) {
            if ([string]$argument -match "[`0]") { return 'ArgumentList' }
        }
    }
    foreach ($name in @('StdOutPath', 'StdErrPath')) {
        $value = $Path[$name]
        if ($value -eq '/dev/null') { continue }
        try {
            $stream = [System.IO.File]::Open($value, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $stream.Dispose()
        } catch {
            return $name
        }
    }
    return ''
}

function Wait-YurunaDetachHandshakeFile {
    <#
    .SYNOPSIS
        Poll a handshake file until it names the expected PID (when known),
        or the wait ends. Returns the parsed record or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [int]$ExpectedPid, [Parameter(Mandatory)][psobject]$Deadline)
    do {
        if ([System.IO.File]::Exists($Path)) {
            try {
                $doc = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
                if ($doc -and [int]$doc.schemaVersion -eq 1 -and ($ExpectedPid -le 0 -or [int]$doc.pid -eq $ExpectedPid)) { return $doc }
            } catch {
                Write-Verbose "Handshake '$Path' not readable yet: $($_.Exception.Message)"
            }
        }
    } while (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 100)
    return $null
}

function Start-YurunaDetachedProcess {
    <#
    .SYNOPSIS
        Launch a pwsh script as a worker that outlives its launcher, with
        -NonInteractive, closed or redirected stdin, and both output streams
        in private files.
    .DESCRIPTION
        The vector is always <this pwsh> -NoLogo -NoProfile -NonInteractive
        -File <FilePath> <ArgumentList...>, one token per element. The child
        also receives YURUNA_NONINTERACTIVE=1, the -Environment entries and
        YURUNA_DETACH_HANDSHAKE (empty without a handshake path);
        YURUNA_DETACH_HOP_PID and YURUNA_DETACH_HOP_START are emptied so a
        launcher's own values never reach it.

        Every path must be absolute; the stream, stdin and handshake paths
        must lie inside -PrivateDirectory (POSIX also accepts /dev/null for
        the streams and stdin), and on Windows no path may carry a character
        the argument encoder cannot pass. A violation launches nothing.

        POSIX: one bounded `bash -c` runs the fixed body `set -m; nohup "$@"`
        with every value as a positional parameter and the stream paths in
        the environment; the PID it echoes is the final worker. Windows: a
        first hop, started without redirected handles, reads a private spec,
        launches the final worker with the redirections, acknowledges, and
        exits without waiting for it.

        With -WaitForHandshakeMilliseconds the launcher waits for the final
        worker's own handshake and, on POSIX, asserts the worker leads a
        different process group than the launcher (group-not-detached).
    .PARAMETER FilePath
        The script to run.
    .PARAMETER ArgumentList
        Script arguments, one per element.
    .PARAMETER WorkingDirectory
        The worker's working directory.
    .PARAMETER Environment
        Extra environment variables for the worker.
    .PARAMETER StdOutPath
        Private stdout file (/dev/null on POSIX).
    .PARAMETER StdErrPath
        Private stderr file.
    .PARAMETER StdInPath
        Stdin source; /dev/null on POSIX and an empty sentinel on Windows by
        default.
    .PARAMETER PrivateDirectory
        The directory every stream, hop spec and handshake must live in.
    .PARAMETER HandshakePath
        Where the worker writes its identity handshake.
    .PARAMETER WaitForHandshakeMilliseconds
        How long to wait for that handshake; 0 does not wait.
    .PARAMETER Deadline
        Bounds the whole launch.
    .OUTPUTS
        [pscustomobject] @{ Launched; Reason launched|invalid-argument|
        launcher-failed|hop-failed|handshake-timeout|group-not-detached|whatif;
        LauncherPid; LauncherStartTimeUnixMs; FinalPid; FinalStartTimeUnixMs;
        Handshake; Platform; Detail }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [string]$StdInPath,
        [Parameter(Mandatory)][string]$PrivateDirectory,
        [string]$HandshakePath,
        [ValidateRange(0, 600000)][int]$WaitForHandshakeMilliseconds = 0,
        [psobject]$Deadline
    )
    $platform = Get-YurunaDetachPlatform
    $out = [ordered]@{
        Launched = $false; Reason = $null; LauncherPid = $null; LauncherStartTimeUnixMs = $null
        FinalPid = $null; FinalStartTimeUnixMs = $null; Handshake = $null; Platform = $platform; Detail = $null
    }
    $paths = @{
        FilePath = $FilePath; WorkingDirectory = $WorkingDirectory; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath
        StdInPath = if ($StdInPath) { $StdInPath } else { $null }
        HandshakePath = if ($HandshakePath) { $HandshakePath } else { $null }
    }
    $bad = Test-YurunaDetachArgument -Path $paths -PrivateDirectory $PrivateDirectory -ArgumentList $ArgumentList
    if ($bad) {
        $out.Reason = 'invalid-argument'; $out.Detail = $bad
        return [pscustomobject]$out
    }
    if (-not $PSCmdlet.ShouldProcess($FilePath, (Format-YurunaOperatorMessage -Key 'runner.detached_launch_action'))) {
        $out.Reason = 'whatif'
        return [pscustomobject]$out
    }
    $pwsh = Get-PwshExePath
    if (-not $pwsh -or -not [System.IO.File]::Exists($pwsh)) {
        $out.Reason = 'launcher-failed'; $out.Detail = 'pwsh-unresolved'
        return [pscustomobject]$out
    }
    $launchDeadline = if ($Deadline) { New-YurunaDeadline -Parent $Deadline -TotalMilliseconds 10000 } else { New-YurunaDeadline -TotalMilliseconds 10000 }
    $childEnvironment = @{}
    if ($Environment) { foreach ($key in $Environment.Keys) { $childEnvironment[[string]$key] = [string]$Environment[$key] } }
    $childEnvironment['YURUNA_NONINTERACTIVE'] = '1'
    # Always set, empty when this launch has none: a launcher that is itself
    # a detached worker carries its own handshake path and hop identity, and
    # an inherited value would send the new worker to wait on a stale hop and
    # overwrite an older request's handshake. Every reader treats empty as
    # absent; a Windows hop sets its own identity for the final worker.
    $childEnvironment['YURUNA_DETACH_HANDSHAKE'] = if ($HandshakePath) { $HandshakePath } else { '' }
    $childEnvironment['YURUNA_DETACH_HOP_PID'] = ''
    $childEnvironment['YURUNA_DETACH_HOP_START'] = ''
    $childEnvironment['YURUNA_DETACH_STDOUT'] = $StdOutPath
    $childEnvironment['YURUNA_DETACH_STDERR'] = $StdErrPath
    $vector = @($pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FilePath) + @($ArgumentList)
    if ($platform -ne 'Windows') {
        $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $launchDeadline -Ceiling 10
        if (-not $seconds) { $out.Reason = 'launcher-failed'; $out.Detail = 'deadline-exhausted'; return [pscustomobject]$out }
        $stdin = if ($StdInPath) { $StdInPath } else { '/dev/null' }
        $bashArgs = @('-c', $script:DetachShellBody, 'yuruna-detach', $WorkingDirectory, $stdin) + $vector
        $r = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList $bashArgs -TimeoutSeconds $seconds -Environment $childEnvironment -Deadline $launchDeadline
        $out.LauncherPid = if ($r.ProcessId) { [int]$r.ProcessId } else { $null }
        $finalPid = 0
        if (-not (Test-BoundedNativeResultComplete -Result $r) -or $r.ExitCode -ne 0 -or
            -not [int]::TryParse(([string]$r.StdOut).Trim(), [ref]$finalPid) -or $finalPid -le 0) {
            $out.Reason = 'launcher-failed'
            $out.Detail = if ($r.ExitCode -eq 97) { 'working-directory' } elseif (-not $r.Started) { 'bash-unavailable' } else { "exit-$($r.ExitCode)" }
            return [pscustomobject]$out
        }
        $out.FinalPid = $finalPid
        try { $out.FinalStartTimeUnixMs = Get-YurunaDetachUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($finalPid).StartTime) } catch {
            Write-Verbose "Start-YurunaDetachedProcess: start time of pid $finalPid unreadable: $($_.Exception.Message)"
        }
    } else {
        $stdin = if ($StdInPath) { $StdInPath } else { [System.IO.Path]::Combine($PrivateDirectory, 'stdin.empty') }
        $leaf = [guid]::NewGuid().ToString('N')
        $specPath = [System.IO.Path]::Combine($PrivateDirectory, "$leaf.hop.json")
        $spec = [ordered]@{
            schemaVersion    = 1
            pwsh             = $pwsh
            argumentList     = @($vector | Select-Object -Skip 1)
            workingDirectory = $WorkingDirectory
            environment      = $childEnvironment
            stdin            = $stdin
            stdout           = $StdOutPath
            stderr           = $StdErrPath
        }
        if (-not (Write-YurunaStateFileJson -Path $specPath -InputObject $spec -Confirm:$false)) {
            $out.Reason = 'launcher-failed'; $out.Detail = 'spec-unwritable'
            return [pscustomobject]$out
        }
        $modulePath = (Join-Path $PSScriptRoot 'Test.InnerSpawn.psm1').Replace("'", "''")
        $quotedSpec = $specPath.Replace("'", "''")
        $hopCommand = "Import-Module '$modulePath' -DisableNameChecking; exit (Invoke-YurunaDetachedHop -SpecPath '$quotedSpec')"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hopCommand))
        try {
            $hop = Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru -WorkingDirectory $WorkingDirectory `
                -ArgumentList (ConvertTo-YurunaWindowsCommandLine -Argument @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)) -ErrorAction Stop
        } catch {
            $out.Reason = 'launcher-failed'; $out.Detail = 'hop-start-failed'
            return [pscustomobject]$out
        }
        $out.LauncherPid = [int]$hop.Id
        try { $out.LauncherStartTimeUnixMs = Get-YurunaDetachUnixMs -Value $hop.StartTime } catch { $out.LauncherStartTimeUnixMs = $null }
        if ($WaitForHandshakeMilliseconds -gt 0) {
            $ackWait = New-YurunaDeadline -Parent $launchDeadline -TotalMilliseconds $WaitForHandshakeMilliseconds
            $ack = Wait-YurunaDetachHandshakeFile -Path "$specPath.ack.json" -Deadline $ackWait
            if (-not $ack -or -not [bool]$ack.launched) {
                $out.Reason = 'hop-failed'; $out.Detail = if ($ack) { [string]$ack.error } else { 'no-ack' }
                return [pscustomobject]$out
            }
            $out.FinalPid = [int]$ack.finalPid
            $out.FinalStartTimeUnixMs = $ack.finalStartTimeUnixMs
        }
    }
    if ($WaitForHandshakeMilliseconds -gt 0 -and $HandshakePath) {
        $wait = New-YurunaDeadline -TotalMilliseconds $WaitForHandshakeMilliseconds
        if ($Deadline) { $wait = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds $WaitForHandshakeMilliseconds }
        $expected = if ($out.FinalPid) { [int]$out.FinalPid } else { 0 }
        $handshake = Wait-YurunaDetachHandshakeFile -Path $HandshakePath -ExpectedPid $expected -Deadline $wait
        if (-not $handshake) {
            $out.Reason = 'handshake-timeout'
            return [pscustomobject]$out
        }
        $out.Handshake = $handshake
        if ($platform -ne 'Windows') {
            $identityArgs = @{ ProcessId = $PID }
            if ($Deadline) { $identityArgs.Deadline = $Deadline }
            $own = Get-YurunaDetachProcessIdentity @identityArgs
            if ($null -eq $handshake.pgid -or $null -eq $own.ProcessGroupId -or [int]$handshake.pgid -eq [int]$own.ProcessGroupId) {
                $out.Reason = 'group-not-detached'
                return [pscustomobject]$out
            }
        }
    }
    $out.Launched = $true
    $out.Reason = 'launched'
    return [pscustomobject]$out
}

function Invoke-YurunaDetachedHop {
    <#
    .SYNOPSIS
        Body of the Windows first hop: launch the final worker from a private
        spec with its redirections, acknowledge, and return an exit code
        without waiting for the worker.
    .DESCRIPTION
        The hop itself was started without redirected handles, so the final
        worker inherits nothing from the listener. The worker is told the
        hop's identity through YURUNA_DETACH_HOP_PID/_START and waits for it
        to exit before taking any lock. The acknowledgment
        (<spec>.ack.json: hopPid, hopStartTimeUnixMs, finalPid,
        finalStartTimeUnixMs, launched, error) is distinct from the worker's
        own handshake, and the hop never opens the worker's stream files.
    .PARAMETER SpecPath
        The spec Start-YurunaDetachedProcess wrote.
    .OUTPUTS
        [int] 0 when the worker was launched, 1 otherwise.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$SpecPath)
    $ackPath = "$SpecPath.ack.json"
    $self = Get-YurunaDetachProcessIdentity -ProcessId $PID
    $ack = [ordered]@{
        schemaVersion = 1; hopPid = $PID; hopStartTimeUnixMs = $self.StartTimeUnixMs
        finalPid = $null; finalStartTimeUnixMs = $null; launched = $false; error = $null
    }
    $finish = {
        param([int]$Code)
        $null = Write-YurunaStateFileJson -Path $ackPath -InputObject $ack -Confirm:$false
        return $Code
    }
    $spec = $null
    try { $spec = [System.IO.File]::ReadAllText($SpecPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch {
        $ack.error = 'spec-unreadable'
        return (& $finish 1)
    }
    foreach ($key in @('pwsh', 'workingDirectory', 'stdin', 'stdout', 'stderr')) {
        if (-not $spec[$key] -or -not [System.IO.Path]::IsPathFullyQualified([string]$spec[$key])) {
            $ack.error = "spec-invalid-$key"
            return (& $finish 1)
        }
    }
    if ([int]$spec['schemaVersion'] -ne 1) { $ack.error = 'spec-version'; return (& $finish 1) }
    if ($spec['environment'] -is [System.Collections.IDictionary]) {
        foreach ($key in $spec['environment'].Keys) { [Environment]::SetEnvironmentVariable([string]$key, [string]$spec['environment'][$key]) }
    }
    [Environment]::SetEnvironmentVariable('YURUNA_DETACH_HOP_PID', [string]$PID)
    [Environment]::SetEnvironmentVariable('YURUNA_DETACH_HOP_START', [string]$self.StartTimeUnixMs)
    try {
        if (-not [System.IO.File]::Exists($spec['stdin'])) { [System.IO.File]::WriteAllBytes($spec['stdin'], [byte[]]@()) }
        $start = @{
            FilePath               = [string]$spec['pwsh']
            ArgumentList           = (ConvertTo-YurunaWindowsCommandLine -Argument @($spec['argumentList']))
            WorkingDirectory       = [string]$spec['workingDirectory']
            RedirectStandardInput  = [string]$spec['stdin']
            RedirectStandardOutput = [string]$spec['stdout']
            RedirectStandardError  = [string]$spec['stderr']
            PassThru               = $true
            ErrorAction            = 'Stop'
        }
        if ($IsWindows) { $start.WindowStyle = 'Hidden' }
        $final = Start-Process @start
        $ack.finalPid = [int]$final.Id
        try { $ack.finalStartTimeUnixMs = Get-YurunaDetachUnixMs -Value $final.StartTime } catch { $ack.finalStartTimeUnixMs = $null }
        $ack.launched = $true
        return (& $finish 0)
    } catch {
        $ack.error = 'final-start-failed'
        Write-Verbose "Invoke-YurunaDetachedHop: $($_.Exception.Message)"
        return (& $finish 1)
    }
}

function Write-YurunaDetachedHandshake {
    <#
    .SYNOPSIS
        Written by the final worker itself: its PID, start time, process
        group, parent, owner and the request it serves.
    .DESCRIPTION
        The launcher PID is never the worker's identity; this record is. It
        is verified as an exact tuple against a live process, not with the
        loose pidfile-mtime rule.
    .PARAMETER Path
        The handshake file; defaults to YURUNA_DETACH_HANDSHAKE.
    .PARAMETER RequestId
        The request this worker serves.
    .PARAMETER Attempt
        The attempt number.
    .PARAMETER Parent
        A validated parent identity to record.
    .PARAMETER Deadline
        Bounds the identity lookup when the caller has a shared deadline.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$Path = $env:YURUNA_DETACH_HANDSHAKE,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestId,
        [ValidateRange(0, [int]::MaxValue)][int]$Attempt = 0,
        [psobject]$Parent,
        [psobject]$Deadline
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathFullyQualified($Path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.detached_handshake_write_action'))) { return $false }
    $identityArgs = @{ ProcessId = $PID }
    if ($Deadline) { $identityArgs.Deadline = $Deadline }
    $self = Get-YurunaDetachProcessIdentity @identityArgs
    $parentBlock = $null
    if ($Parent) {
        $parentBlock = [ordered]@{ pid = [int]$Parent.Pid; startTimeUnixMs = $Parent.StartTimeUnixMs }
    }
    $record = [ordered]@{
        schemaVersion   = 1
        pid             = $PID
        startTimeUnixMs = $self.StartTimeUnixMs
        pgid            = $self.ProcessGroupId
        ppid            = $self.ParentPid
        ownerId         = $self.OwnerId
        requestId       = $RequestId
        attempt         = $Attempt
        parent          = $parentBlock
        writtenUtc      = [DateTime]::UtcNow.ToString('o')
    }
    return [bool](Write-YurunaStateFileJson -Path $Path -InputObject $record -Confirm:$false)
}

function Read-YurunaDetachedHandshake {
    <#
    .SYNOPSIS
        Verify a worker's handshake as an exact tuple: live PID, matching
        start time, request and attempt.
    .PARAMETER Path
        The handshake file.
    .PARAMETER ExpectedRequestId
        The request the worker must serve.
    .PARAMETER ExpectedAttempt
        The attempt it must serve.
    .PARAMETER ProcessTable
        A Get-YurunaProcessTable result to check liveness against; a
        single-process lookup is used when omitted.
    .OUTPUTS
        [pscustomobject] @{ Valid; Record; Reason ok|missing|unreadable|
        request-mismatch|attempt-mismatch|process-absent|start-mismatch|identity-unknown }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRequestId,
        [Nullable[int]]$ExpectedAttempt,
        [psobject]$ProcessTable
    )
    $fail = { param([string]$Reason, $Record) [pscustomobject]@{ Valid = $false; Record = $Record; Reason = $Reason } }
    if (-not [System.IO.File]::Exists($Path)) { return (& $fail 'missing' $null) }
    $doc = $null
    try { $doc = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop } catch { return (& $fail 'unreadable' $null) }
    if (-not $doc -or [int]$doc.schemaVersion -ne 1 -or [int]$doc.pid -le 0) { return (& $fail 'unreadable' $doc) }
    if ([string]$doc.requestId -ne $ExpectedRequestId) { return (& $fail 'request-mismatch' $doc) }
    if ($null -ne $ExpectedAttempt -and [int]$doc.attempt -ne [int]$ExpectedAttempt) { return (& $fail 'attempt-mismatch' $doc) }
    if ($null -eq $doc.startTimeUnixMs) { return (& $fail 'identity-unknown' $doc) }
    $liveStart = $null
    $alive = $false
    if ($ProcessTable) {
        $row = @($ProcessTable.Rows | Where-Object { [int]$_.Pid -eq [int]$doc.pid }) | Select-Object -First 1
        if ($row) { $alive = $true; $liveStart = $row.StartTimeUnixMs }
        elseif (-not $ProcessTable.Complete) { return (& $fail 'identity-unknown' $doc) }
    } else {
        try {
            $process = [System.Diagnostics.Process]::GetProcessById([int]$doc.pid)
            $alive = -not $process.HasExited
            $liveStart = Get-YurunaDetachUnixMs -Value $process.StartTime
        } catch { $alive = $false }
    }
    if (-not $alive) { return (& $fail 'process-absent' $doc) }
    if ($null -eq $liveStart) { return (& $fail 'identity-unknown' $doc) }
    if ([Math]::Abs([long]$liveStart - [long]$doc.startTimeUnixMs) -gt $script:DetachStartToleranceMs) { return (& $fail 'start-mismatch' $doc) }
    return [pscustomobject]@{ Valid = $true; Record = $doc; Reason = 'ok' }
}

function Wait-YurunaDetachedHopExit {
    <#
    .SYNOPSIS
        Called by a Windows final worker before it takes any lock: wait,
        bounded, for the hop that launched it to exit.
    .PARAMETER HopPid
        Defaults to YURUNA_DETACH_HOP_PID.
    .PARAMETER HopStartTimeUnixMs
        Defaults to YURUNA_DETACH_HOP_START.
    .PARAMETER Deadline
        Bounds the wait.
    .OUTPUTS
        [pscustomobject] @{ Exited; Reason exited|recycled|no-hop|timeout }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$HopPid = $(if ($env:YURUNA_DETACH_HOP_PID -match '^\d+$') { [int]$env:YURUNA_DETACH_HOP_PID } else { 0 }),
        [long]$HopStartTimeUnixMs = $(if ($env:YURUNA_DETACH_HOP_START -match '^\d+$') { [long]$env:YURUNA_DETACH_HOP_START } else { 0 }),
        [Parameter(Mandatory)][psobject]$Deadline
    )
    if ($HopPid -le 0) { return [pscustomobject]@{ Exited = $true; Reason = 'no-hop' } }
    do {
        $process = $null
        try { $process = [System.Diagnostics.Process]::GetProcessById($HopPid) } catch { $process = $null }
        if (-not $process -or $process.HasExited) { return [pscustomobject]@{ Exited = $true; Reason = 'exited' } }
        if ($HopStartTimeUnixMs -gt 0) {
            $start = $null
            try { $start = Get-YurunaDetachUnixMs -Value $process.StartTime } catch { $start = $null }
            if ($null -ne $start -and [Math]::Abs($start - $HopStartTimeUnixMs) -gt $script:DetachStartToleranceMs) {
                return [pscustomobject]@{ Exited = $true; Reason = 'recycled' }
            }
        }
    } while (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 100)
    return [pscustomobject]@{ Exited = $false; Reason = 'timeout' }
}

Export-ModuleMember -Function New-InnerRunnerArgList, Get-PwshExePath, Start-YurunaDetachedProcess, Invoke-YurunaDetachedHop, `
    ConvertTo-YurunaWindowsCommandLine, Test-YurunaWindowsPathArgument, Write-YurunaDetachedHandshake, `
    Read-YurunaDetachedHandshake, Wait-YurunaDetachedHopExit
