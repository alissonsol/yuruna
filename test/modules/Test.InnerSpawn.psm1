<#PSScriptInfo
.VERSION 2026.11.23
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

# See https://yuruna.link/4213a0b3-008e

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
        The child exits with the script's own exit code. -Command reports only
        whether its last statement succeeded, so without the exit trailer the
        2 (cannot run), 70 (unrecorded), 75 (degraded) and 78 (configuration) a
        script returns would all reach the caller as 1. The trailer is the one
        the libvirt group relaunch uses: a terminating error still exits 1.
    .PARAMETER ScriptPath
        Absolute path to the .ps1 to run.
    .PARAMETER Parameters
        Hashtable or IDictionary of parameter name -> value. Switch
        parameters are emitted only when present (and IsPresent=$true).
        Bool / int / double values are emitted as PowerShell literals so
        the binder preserves the type.
    .PARAMETER ExcludeParameter
        Names that exist in $Parameters but must not be forwarded, such as
        the outer runner's -HandoffResume and -HandoffToken switches.
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
    $escapedScript = $ScriptPath -replace "['\u2018\u2019]", '$0$0'
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
            $escaped = ("$v") -replace "['\u2018\u2019]", '$0$0'
            $cmdParts += "-$k"
            $cmdParts += "'$escaped'"
        }
    }
    $invocation = $cmdParts -join ' '
    $command = "`$global:LASTEXITCODE = 0; try { $invocation; if (-not `$?) { if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; exit 1 } } catch { Write-Error `$_; exit 1 }; exit 0"
    if ($NonInteractive) {
        return @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command)
    }
    return @('-NoLogo', '-NoProfile', '-Command', $command)
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
             stub, whose path a per-program firewall rule never matches). Absent
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

function Get-YurunaIdentityPlatform {
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

function ConvertTo-YurunaUnixMs {
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
    try { $out.StartTimeUnixMs = ConvertTo-YurunaUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($ProcessId).StartTime) } catch {
        Write-Verbose "Start time of pid $ProcessId unreadable: $($_.Exception.Message)"
    }
    switch (Get-YurunaIdentityPlatform) {
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
    $comparison = if ((Get-YurunaIdentityPlatform) -eq 'Linux') { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
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
    $platform = Get-YurunaIdentityPlatform
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

# --- REGION: Console start
# See https://yuruna.link/42f909ad-002c
# A runner a host update starts runs in a tmux session of its own, on a socket
# the caller names, so an operator can open it. A pane gets the tmux server's
# environment, not the caller's, so the command carries its environment as an
# /usr/bin/env vector, without the names below that a pane must never inherit.
$script:ConsoleUnsetName = @('YURUNA_SG_RELAUNCH', 'YURUNA_RUNNER_RELAUNCH', 'YURUNA_HANDOFF_TOKEN', 'YURUNA_HANDOFF_PREFLIGHT',
    'YURUNA_HANDOFF_BARRIER', 'YURUNA_CYCLE_GENERATION', 'STY', 'TMUX_PANE')
# Where tmux is looked for when it is not on PATH: Homebrew's prefixes on
# Apple silicon and on Intel macOS, which a process that never ran
# `brew shellenv` does not have on its PATH.
$script:ConsoleTmuxCandidate = @('/opt/homebrew/bin/tmux', '/usr/local/bin/tmux')
# sun_path holds 108 bytes on Linux and 104 on macOS; the margin keeps tmux's
# own suffixes inside both.
$script:ConsoleSocketMaxBytes = 100
$script:ConsoleSessionPattern = '\A[A-Za-z0-9._-]{1,64}\z'
$script:ConsoleTimeoutSeconds = 10

function ConvertTo-YurunaShellSingleQuoted {
    <#
    .SYNOPSIS
        One /bin/sh word for a text: single-quoted, each ' written as '\''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return "'" + $Text.Replace("'", "'\''") + "'"
}

function Get-YurunaConsoleSessionArgument {
    <#
    .SYNOPSIS
        The tmux arguments that create a detached console session running one
        command vector, with its environment on the command line.
    .DESCRIPTION
        Several command arguments make tmux execute the vector without a
        shell, and /usr/bin/env execs the last element, so the pane's process
        is the command itself. env runs without -i: the pane keeps the TMUX
        variable tmux sets, which is how the runner's session record learns
        it runs in a multiplexer. No account configuration is read (-f
        /dev/null).
    .PARAMETER SocketPath
        The tmux server socket.
    .PARAMETER SessionName
        The session's name.
    .PARAMETER WorkingDirectory
        The pane's working directory.
    .PARAMETER Environment
        Name/value pairs for the command, in addition to the fixed ones.
    .PARAMETER Vector
        The command and its arguments.
    .OUTPUTS
        [string[]] the arguments after the tmux executable.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment,
        [Parameter(Mandatory)][string[]]$Vector
    )
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @('-S', $SocketPath, '-f', '/dev/null', 'new-session', '-d', '-P', '-F', '#{pane_pid}', '-s', $SessionName,
            '-x', '200', '-y', '50', '-c', $WorkingDirectory, '/usr/bin/env')) { $arguments.Add($item) }
    foreach ($name in $script:ConsoleUnsetName) { $arguments.Add('-u'); $arguments.Add($name) }
    if ($Environment) {
        foreach ($name in @($Environment.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) { $arguments.Add("$name=$([string]$Environment[$name])") }
    }
    foreach ($item in @('YURUNA_NONINTERACTIVE=1', 'YURUNA_DETACH_HANDSHAKE=', 'YURUNA_DETACH_HOP_PID=', 'YURUNA_DETACH_HOP_START=',
            'YURUNA_DETACH_STDOUT=', 'YURUNA_DETACH_STDERR=')) { $arguments.Add($item) }
    foreach ($item in $Vector) { $arguments.Add([string]$item) }
    return [string[]]$arguments.ToArray()
}

function Get-YurunaConsoleTmuxPath {
    <#
    .SYNOPSIS
        The tmux of the console: the first one on PATH, else the first
        executable file among Homebrew's fixed locations, else $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $onPath = (Get-Command -Name tmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($onPath) { return [string]$onPath }
    foreach ($candidate in $script:ConsoleTmuxCandidate) {
        try {
            if ([System.IO.File]::Exists($candidate) -and ([System.IO.File]::GetUnixFileMode($candidate) -band [System.IO.UnixFileMode]::UserExecute)) { return $candidate }
        } catch { Write-Verbose "Get-YurunaConsoleTmuxPath: '$candidate' unreadable: $($_.Exception.Message)" }
    }
    return $null
}

function Invoke-YurunaConsoleTmux {
    <#
    .SYNOPSIS
        One bounded tmux client call on the console socket.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Tmux, [Parameter(Mandatory)][string[]]$ArgumentList, [psobject]$Deadline)
    $call = @{ FilePath = $Tmux; ArgumentList = $ArgumentList; TimeoutSeconds = $script:ConsoleTimeoutSeconds }
    if ($Deadline) { $call.Deadline = $Deadline }
    return (Invoke-BoundedNativeCommand @call)
}

function Read-YurunaConsolePanePid {
    <#
    .SYNOPSIS
        The pane process id a complete tmux answer printed, or 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()][System.Collections.IDictionary]$Result)
    $panePid = 0
    if ((Test-BoundedNativeResultComplete -Result $Result) -and $Result.ExitCode -eq 0) {
        $first = @(([string]$Result.StdOut).Trim() -split '\r?\n')[0]
        if (-not [int]::TryParse(([string]$first).Trim(), [ref]$panePid)) { $panePid = 0 }
    }
    return [Math]::Max($panePid, 0)
}

function Start-YurunaConsoleSession {
    <#
    .SYNOPSIS
        Create the console session for a detached launch, or say that the
        caller must fall back to the launch without a console.
    .DESCRIPTION
        No tmux (on PATH or at a Homebrew location), a socket path tmux
        cannot bind, or a session tmux confirms it did not create:
        Fallback, and the caller launches as it does without a console. A
        failure after which tmux cannot say whether the session exists is
        not a fallback: launching beside a session that may run the command
        would start it twice. A created session has its output copied to the
        log file from then on.
    .OUTPUTS
        [pscustomobject] @{ Created; Fallback; Console tmux|none; ConsoleReason
        created|no-multiplexer|socket-path-too-long|session-not-created|
        console-state-unknown; PanePid; LauncherPid }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Start-YurunaDetachedProcess, after it asked to launch.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SocketPath,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment,
        [Parameter(Mandatory)][string[]]$Vector,
        [psobject]$Deadline
    )
    $answer = {
        param([bool]$Created, [bool]$Fallback, [string]$Console, [string]$Reason, [int]$PanePid, $LauncherPid)
        [pscustomobject]@{ Created = $Created; Fallback = $Fallback; Console = $Console; ConsoleReason = $Reason; PanePid = $PanePid; LauncherPid = $LauncherPid }
    }
    $tmux = Get-YurunaConsoleTmuxPath
    if (-not $tmux) { return (& $answer $false $true 'none' 'no-multiplexer' 0 $null) }
    if ([System.Text.Encoding]::UTF8.GetByteCount($SocketPath) -gt $script:ConsoleSocketMaxBytes) { return (& $answer $false $true 'none' 'socket-path-too-long' 0 $null) }
    $target = "=$SessionName"
    $created = Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList (Get-YurunaConsoleSessionArgument -SocketPath $SocketPath -SessionName $SessionName `
        -WorkingDirectory $WorkingDirectory -Environment $Environment -Vector $Vector)
    $launcherPid = if ($created.ProcessId) { [int]$created.ProcessId } else { $null }
    $panePid = Read-YurunaConsolePanePid -Result $created
    if ($panePid -le 0) {
        $probe = Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList @('-S', $SocketPath, 'has-session', '-t', $target)
        $complete = Test-BoundedNativeResultComplete -Result $probe
        if ($complete -and $probe.ExitCode -eq 0) {
            $panePid = Read-YurunaConsolePanePid -Result (Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList @('-S', $SocketPath, 'list-panes', '-t', $target, '-F', '#{pane_pid}'))
            if ($panePid -le 0) { return (& $answer $false $false 'none' 'console-state-unknown' 0 $launcherPid) }
        } elseif ($complete -and $probe.ExitCode -eq 1 -and [string]$probe.StdErr -match "no server running|can't find session") {
            return (& $answer $false $true 'none' 'session-not-created' 0 $launcherPid)
        } else {
            return (& $answer $false $false 'none' 'console-state-unknown' 0 $launcherPid)
        }
    }
    # tmux runs the pipe-pane command through /bin/sh -c, so the log path is
    # one single-quoted shell word.
    $copy = Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList @('-S', $SocketPath, 'pipe-pane', '-o', '-t', $target,
        "cat >> $(ConvertTo-YurunaShellSingleQuoted -Text $LogPath)")
    if (-not (Test-BoundedNativeResultComplete -Result $copy) -or $copy.ExitCode -ne 0) {
        Write-Verbose "Start-YurunaConsoleSession: the console copy of '$SessionName' did not start (exit $($copy.ExitCode))."
    }
    return (& $answer $true $false 'tmux' 'created' $panePid $launcherPid)
}

function Stop-YurunaConsoleCopy {
    <#
    .SYNOPSIS
        End the copy of a console session's output to its log file, when the
        session still exists; the log stays where it is.
    .PARAMETER ConsoleSocketPath
        The tmux server socket.
    .PARAMETER ConsoleSessionName
        The session's name.
    .PARAMETER Deadline
        Bounds both tmux calls.
    .OUTPUTS
        [bool] $true when the copy was ended.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Ends only the output copy of a session the caller created; the session and its process are untouched.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ConsoleSocketPath, [Parameter(Mandatory)][string]$ConsoleSessionName, [psobject]$Deadline)
    $tmux = Get-YurunaConsoleTmuxPath
    if (-not $tmux) { return $false }
    $target = "=$ConsoleSessionName"
    $probe = Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList @('-S', $ConsoleSocketPath, 'has-session', '-t', $target)
    if (-not (Test-BoundedNativeResultComplete -Result $probe) -or $probe.ExitCode -ne 0) { return $false }
    $stop = Invoke-YurunaConsoleTmux -Tmux $tmux -Deadline $Deadline -ArgumentList @('-S', $ConsoleSocketPath, 'pipe-pane', '-t', $target)
    return ((Test-BoundedNativeResultComplete -Result $stop) -and $stop.ExitCode -eq 0)
}

function Test-YurunaConsoleArgument {
    <#
    .SYNOPSIS
        Validate the console parameters of a detached launch; returns '' when
        valid or the name of the first offending argument.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable]$Console, [Parameter(Mandatory)][string]$PrivateDirectory, [hashtable]$Environment)
    if ((Get-YurunaIdentityPlatform) -eq 'Windows') { return 'ConsoleSocketPath' }
    foreach ($name in @('ConsoleSocketPath', 'ConsoleSessionName', 'ConsoleLogPath')) {
        if ([string]::IsNullOrWhiteSpace([string]$Console[$name])) { return $name }
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Console.ConsoleSocketPath)) { return 'ConsoleSocketPath' }
    if ($Console.ConsoleSessionName -cnotmatch $script:ConsoleSessionPattern) { return 'ConsoleSessionName' }
    if (-not [System.IO.Path]::IsPathFullyQualified($Console.ConsoleLogPath) -or
        -not (Test-YurunaPathInside -Path $Console.ConsoleLogPath -Directory $PrivateDirectory)) { return 'ConsoleLogPath' }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { if ([string]$key -cnotmatch '\A[A-Za-z_][A-Za-z0-9_]*\z') { return 'Environment' } }
    }
    return ''
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

        With the three console parameters (POSIX only; Windows refuses them)
        the worker runs in a detached tmux session instead, its streams in
        the console and copied to -ConsoleLogPath, and FinalPid is the pane's
        process. Without tmux, with a socket path too long to bind, or when
        tmux confirms no session was created, the launch is the one without a
        console, and Console reads none with the reason. When tmux cannot say
        whether the session exists, nothing else is launched and the reason
        is console-state-unknown. Without these parameters the launch and
        its output are unchanged.

        With -ConsoleWindow (Windows only; POSIX refuses it, and so does a
        launch that also names the tmux parameters) the final worker gets a
        console window of its own on the desktop of the launching session:
        the hop starts it visible and redirects nothing, so its streams are
        the console's and Ctrl+C in that window reaches it. Console then
        reads window.
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
    .PARAMETER ConsoleSocketPath
        The tmux server socket of the console.
    .PARAMETER ConsoleSessionName
        The console session's name; never reused.
    .PARAMETER ConsoleLogPath
        Where the console's output is copied, inside -PrivateDirectory.
    .PARAMETER ConsoleWindow
        Give the worker a console window of its own (Windows only).
    .OUTPUTS
        [pscustomobject] @{ Launched; Reason launched|invalid-argument|
        launcher-failed|hop-failed|handshake-timeout|group-not-detached|whatif|
        console-state-unknown; LauncherPid; LauncherStartTimeUnixMs; FinalPid;
        FinalStartTimeUnixMs; Handshake; Platform; Detail }, and with the
        console parameters also Console (tmux or none) and ConsoleReason,
        with -ConsoleWindow Console window.
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
        [psobject]$Deadline,
        [string]$ConsoleSocketPath,
        [string]$ConsoleSessionName,
        [string]$ConsoleLogPath,
        [switch]$ConsoleWindow
    )
    $platform = Get-YurunaIdentityPlatform
    $out = [ordered]@{
        Launched = $false; Reason = $null; LauncherPid = $null; LauncherStartTimeUnixMs = $null
        FinalPid = $null; FinalStartTimeUnixMs = $null; Handshake = $null; Platform = $platform; Detail = $null
    }
    $console = $null
    foreach ($name in @('ConsoleSocketPath', 'ConsoleSessionName', 'ConsoleLogPath')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            if (-not $console) { $console = @{} }
            $console[$name] = [string]$PSBoundParameters[$name]
        }
    }
    if ($console) { $out.Console = 'none'; $out.ConsoleReason = $null }
    $paths = @{
        FilePath = $FilePath; WorkingDirectory = $WorkingDirectory; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath
        StdInPath = if ($StdInPath) { $StdInPath } else { $null }
        HandshakePath = if ($HandshakePath) { $HandshakePath } else { $null }
    }
    $bad = Test-YurunaDetachArgument -Path $paths -PrivateDirectory $PrivateDirectory -ArgumentList $ArgumentList
    if (-not $bad -and $console) { $bad = Test-YurunaConsoleArgument -Console $console -PrivateDirectory $PrivateDirectory -Environment $Environment }
    if (-not $bad -and $ConsoleWindow -and ($platform -ne 'Windows' -or $console)) { $bad = 'ConsoleWindow' }
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
    if ($console) {
        $session = Start-YurunaConsoleSession -SocketPath $console.ConsoleSocketPath -SessionName $console.ConsoleSessionName -LogPath $console.ConsoleLogPath `
            -WorkingDirectory $WorkingDirectory -Environment $Environment -Vector $vector -Deadline $launchDeadline
        $out.Console = $session.Console
        $out.ConsoleReason = $session.ConsoleReason
        $out.LauncherPid = $session.LauncherPid
        if ($session.Created) {
            $out.FinalPid = $session.PanePid
            try { $out.FinalStartTimeUnixMs = ConvertTo-YurunaUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($session.PanePid).StartTime) } catch {
                Write-Verbose "Start-YurunaDetachedProcess: start time of pane pid $($session.PanePid) unreadable: $($_.Exception.Message)"
            }
            $out.Launched = $true
            $out.Reason = 'launched'
            return [pscustomobject]$out
        }
        if (-not $session.Fallback) {
            $out.Reason = 'console-state-unknown'
            return [pscustomobject]$out
        }
        $out.LauncherPid = $null
    }
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
        try { $out.FinalStartTimeUnixMs = ConvertTo-YurunaUnixMs -Value ([System.Diagnostics.Process]::GetProcessById($finalPid).StartTime) } catch {
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
            console          = [bool]$ConsoleWindow
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
        try { $out.LauncherStartTimeUnixMs = ConvertTo-YurunaUnixMs -Value $hop.StartTime } catch { $out.LauncherStartTimeUnixMs = $null }
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
    if ($ConsoleWindow) { $out.Console = 'window' }
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
        A spec with console set starts the worker visible with nothing
        redirected, so it gets a console window of its own.
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
    $jsonOptions = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
    try { $spec = [System.IO.File]::ReadAllText($SpecPath) | ConvertFrom-Json -AsHashtable @jsonOptions -ErrorAction Stop } catch {
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
        $start = @{
            FilePath         = [string]$spec['pwsh']
            ArgumentList     = (ConvertTo-YurunaWindowsCommandLine -Argument @($spec['argumentList']))
            WorkingDirectory = [string]$spec['workingDirectory']
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        if ($spec['console'] -eq $true) {
            # Nothing redirected and not hidden: the worker's console is a
            # window of its own, its streams are that window's, and Ctrl+C
            # there reaches the worker and never this hop's launcher.
            if ($IsWindows) { $start.WindowStyle = 'Normal' }
        } else {
            if (-not [System.IO.File]::Exists($spec['stdin'])) { [System.IO.File]::WriteAllBytes($spec['stdin'], [byte[]]@()) }
            $start.RedirectStandardInput = [string]$spec['stdin']
            $start.RedirectStandardOutput = [string]$spec['stdout']
            $start.RedirectStandardError = [string]$spec['stderr']
            if ($IsWindows) { $start.WindowStyle = 'Hidden' }
        }
        $final = Start-Process @start
        $ack.finalPid = [int]$final.Id
        try { $ack.finalStartTimeUnixMs = ConvertTo-YurunaUnixMs -Value $final.StartTime } catch { $ack.finalStartTimeUnixMs = $null }
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
            $liveStart = ConvertTo-YurunaUnixMs -Value $process.StartTime
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
            try { $start = ConvertTo-YurunaUnixMs -Value $process.StartTime } catch { $start = $null }
            if ($null -ne $start -and [Math]::Abs($start - $HopStartTimeUnixMs) -gt $script:DetachStartToleranceMs) {
                return [pscustomobject]@{ Exited = $true; Reason = 'recycled' }
            }
        }
    } while (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 100)
    return [pscustomobject]@{ Exited = $false; Reason = 'timeout' }
}

Export-ModuleMember -Function New-InnerRunnerArgList, Get-PwshExePath, ConvertTo-YurunaUnixMs, Get-YurunaIdentityPlatform, Start-YurunaDetachedProcess, Invoke-YurunaDetachedHop, `
    ConvertTo-YurunaWindowsCommandLine, Test-YurunaWindowsPathArgument, Write-YurunaDetachedHandshake, `
    Read-YurunaDetachedHandshake, Wait-YurunaDetachedHopExit, Stop-YurunaConsoleCopy
