<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42601c3e-5eeb-4426-a6de-7eae54f73aa7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest browser launcher install pester
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
    Prove the two guest-side files of the web channel: the launcher that
    starts, holds and stops the headless browser of a web session, and the
    script that installs Google Chrome in an Ubuntu guest.
.DESCRIPTION
    A launcher that leaves a browser behind its owner, signals a process that
    only shares a recorded pid, or weakens the browser's sandbox, and an
    install script that trusts an unpinned key or adds a source the package
    deletes, are the defects this suite exists for. The launcher runs for real
    with bash against a stand-in browser (a small Python program that listens on
    loopback and writes DevToolsActivePort as the browser does); the install
    script runs with stub functions in place of sudo, apt and curl. Both read
    /proc and GNU tools, so those blocks run on Linux; the text checks run
    everywhere. A missing bash, or python3 on Linux, is a failure that names
    the tool, not a skip.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Force -Global -DisableNameChecking
    $script:Launcher = Join-Path $script:RepoRoot 'automation/yuruna-web-browser.sh'
    $script:InstallScript = Join-Path $script:RepoRoot 'guest/shared/ubuntu.browser.sh'
    if (-not (Get-Command -Name bash -ErrorAction SilentlyContinue)) {
        throw 'bash is not on PATH; install it (Git Bash on Windows) and run this suite again.'
    }
    if ($IsLinux -and -not (Get-Command -Name python3 -ErrorAction SilentlyContinue)) {
        throw 'python3 is not on PATH; the stand-in browser of this suite needs it. Install python3 and run this suite again.'
    }
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-webbrowser'
    $script:Base = Join-Path $script:Work 'b'
    $script:Started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

    # The stand-in browser: it takes its profile folder from --user-data-dir,
    # records its arguments, listens on loopback and writes DevToolsActivePort
    # as the browser does. A copy whose name starts with "retitle" then
    # rewrites its own process title the way Chrome does: every argument of
    # /proc/<pid>/cmdline joined by spaces into one string.
    $standIn = @'
#!/usr/bin/env -S python3 -I
import os, socket, sys, uuid

def retitle():
    with open('/proc/self/stat', 'rb') as f:
        data = f.read()
    fields = data[data.rindex(b')') + 2:].split()
    start, end = int(fields[45]), int(fields[46])
    with open('/proc/self/mem', 'r+b', buffering=0) as mem:
        mem.seek(start)
        area = mem.read(end - start)
        mem.seek(start)
        mem.write(area[:-1].replace(b'\0', b' ') + area[-1:])

profile = None
for arg in sys.argv[1:]:
    if arg.startswith('--user-data-dir='):
        profile = arg[len('--user-data-dir='):]
if not profile:
    sys.exit(2)
with open(os.path.join(profile, 'argv'), 'w') as f:
    f.write('\n'.join(sys.argv[1:]) + '\n')
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(('127.0.0.1', 0))
server.listen(16)
port = server.getsockname()[1]
partial = os.path.join(profile, 'DevToolsActivePort.partial')
with open(partial, 'w') as f:
    f.write('%d\n/devtools/browser/%s' % (port, uuid.uuid4()))
os.rename(partial, os.path.join(profile, 'DevToolsActivePort'))
pending = os.path.basename(sys.argv[0]).startswith('retitle')
while True:
    conn, _ = server.accept()
    conn.close()
    if pending:
        retitle()
        pending = False
'@
    $script:Bin = Join-Path $script:Work 'bin'
    $null = New-Item -ItemType Directory -Path $script:Bin -Force

    function Write-ShimFile {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
        Set-Content -LiteralPath $Path -Value $Text.Replace("`r`n", "`n") -NoNewline -Encoding ascii
        if (-not $IsWindows) { & chmod +x $Path }
    }

    $script:StandIn = Join-Path $script:Bin 'stand-in-browser'
    $script:RetitleStandIn = Join-Path $script:Bin 'retitle-browser'
    $script:Sleeper = Join-Path $script:Bin 'sleeping-browser'
    Write-ShimFile -Path $script:StandIn -Text $standIn
    Write-ShimFile -Path $script:RetitleStandIn -Text $standIn
    Write-ShimFile -Path $script:Sleeper -Text "#!/bin/sh`nsleep 300`n"

    function ConvertFrom-LauncherLine {
        param([AllowNull()][AllowEmptyString()][string]$Text)
        $json = $null
        foreach ($line in ([string]$Text -split "\r?\n")) {
            if ($line -match '^YURUNA_WEB_BROWSER (\{.*\})\s*$') { $json = $Matches[1] }
        }
        if ($null -eq $json) { return $null }
        return (ConvertFrom-Json -InputObject $json -AsHashtable)
    }

    function Invoke-Launcher {
        param([Parameter(Mandatory)][string[]]$Arguments, [string]$Base = $script:Base)
        $result = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList (@($script:Launcher) + $Arguments) `
            -Environment @{ YURUNA_WEB_BASE = $Base } -TimeoutSeconds 30
        return @{
            ExitCode = $result.ExitCode
            Output   = [string]$result.StdOut
            StdErr   = [string]$result.StdErr
            Complete = (Test-BoundedNativeResultComplete $result)
            Result   = (ConvertFrom-LauncherLine -Text $result.StdOut)
        }
    }

    function Start-LauncherHold {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Starts a test child process the case owns and the AfterEach ends.')]
        param([Parameter(Mandatory)][string]$Id)
        $info = [System.Diagnostics.ProcessStartInfo]::new('bash')
        foreach ($argument in @($script:Launcher, 'hold', '--id', $Id)) { $info.ArgumentList.Add($argument) }
        $info.Environment['YURUNA_WEB_BASE'] = $script:Base
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $script:Started.Add($process)
        $errorText = $process.StandardError.ReadToEndAsync()
        $first = $process.StandardOutput.ReadLineAsync()
        if (-not $first.Wait(20000)) { throw "the holder of $Id wrote no line within 20 s" }
        return @{ Process = $process; FirstLine = [string]$first.Result; First = (ConvertFrom-LauncherLine -Text ([string]$first.Result)); ErrorText = $errorText }
    }

    function Wait-LauncherHold {
        param([Parameter(Mandatory)][hashtable]$Holder, [int]$Seconds = 20)
        $exited = $Holder.Process.WaitForExit($Seconds * 1000)
        $rest = ''
        if ($exited) {
            $Holder.Process.WaitForExit()
            $rest = $Holder.Process.StandardOutput.ReadToEnd()
        }
        return @{
            Exited   = $exited
            ExitCode = if ($exited) { $Holder.Process.ExitCode } else { $null }
            Text     = $rest
            Last     = (ConvertFrom-LauncherLine -Text $rest)
        }
    }

    # A pid counts as alive while /proc names it and it is not a zombie.
    function Test-ProcessAlive {
        param([Parameter(Mandatory)][int]$ProcessId)
        $stat = Get-Content -LiteralPath "/proc/$ProcessId/stat" -Raw -ErrorAction SilentlyContinue
        if (-not $stat) { return $false }
        $state = $stat.Substring($stat.LastIndexOf(') ') + 2, 1)
        return ($state -ne 'Z' -and $state -ne 'X')
    }

    function Wait-Condition {
        param([Parameter(Mandatory)][scriptblock]$Condition, [int]$Seconds = 20)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return [bool](& $Condition)
    }

    function Get-SessionFolder {
        param([string]$Base = $script:Base)
        if (-not (Test-Path -LiteralPath $Base)) { return @() }
        return @(Get-ChildItem -LiteralPath $Base -Force -Directory | ForEach-Object Name)
    }
}

AfterAll {
    Remove-YurunaTestTempDir $script:Work
}

Describe 'the browser launcher' -Skip:(-not $IsLinux) {
    AfterEach {
        foreach ($process in $script:Started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $null = $process.WaitForExit(10000)
                }
            } catch {
                Write-Verbose "a process of the case had already ended: $($_.Exception.Message)"
            }
            $process.Dispose()
        }
        $script:Started.Clear()
        $null = Invoke-Launcher -Arguments @('stop', '--all')
        # A browser that a defective stop left behind must not outlive the case.
        foreach ($left in @(& pgrep -f -- "--user-data-dir=$($script:Base)/")) {
            if ($left -match '^\d+$') { & kill -KILL $left 2>$null }
        }
    }

    It 'starts a browser detached from its caller and reports it on one line' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.StdErr
        Assert-True $run.Complete 'the call completed, so the browser holds none of the caller''s pipes'
        Assert-Equal -Expected 1 -Actual @(([string]$run.Output -split "\r?\n") | Where-Object { $_ -like 'YURUNA_WEB_BROWSER *' }).Count
        $r = $run.Result
        Assert-True ($r.ok -eq $true) 'ok'
        Assert-StringEqual -Expected 'started' -Actual $r.event
        Assert-StringEqual -Expected 'a1' -Actual $r.id
        Assert-True ([int]$r.port -gt 0) 'a port above 0'
        Assert-True ([string]$r.wsPath).StartsWith('/devtools/browser/') 'the browser path'
        $browserPid = [int]$r.pid
        Assert-True (Test-ProcessAlive -ProcessId $browserPid) 'the browser runs'
        Assert-StringEqual -Expected "$browserPid" -Actual ((& ps -o sid= -p $browserPid) -join '').Trim() -Because 'the browser leads its own session'
        foreach ($name in 'profile', 't', 'home', 'pid', 'ticks', 'browser.log') {
            Assert-True (Test-Path -LiteralPath (Join-Path $r.dir $name)) "the session folder holds $name"
        }
        Assert-StringEqual -Expected '700' -Actual ((& stat -c '%a' $script:Base) -join '').Trim()
        $argv = @(Get-Content -LiteralPath (Join-Path $r.dir 'profile/argv'))
        foreach ($expected in '--headless=new', '--remote-debugging-port=0', "--user-data-dir=$($r.dir)/profile", '--window-size=1280,800', 'about:blank') {
            Assert-True ($argv -ccontains $expected) "the browser received $expected"
        }
        foreach ($line in $argv) {
            foreach ($weak in '--no-sandbox', '--remote-debugging-address', '--remote-allow-origins', '--lang') {
                Assert-False $line.StartsWith($weak) "the browser received $line"
            }
        }
    }

    It 'keeps the browser while its holder has input and ends it when the input ends' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $holder = Start-LauncherHold -Id 'a1'
        Assert-StringEqual -Expected 'holding' -Actual $holder.First.event
        Assert-True (Test-ProcessAlive -ProcessId ([int]$run.Result.pid)) 'the browser runs while the holder has input'
        $holder.Process.StandardInput.Close()
        $end = Wait-LauncherHold -Holder $holder
        Assert-True $end.Exited 'the holder exited within 20 s'
        Assert-Equal -Expected 0 -Actual $end.ExitCode
        Assert-StringEqual -Expected 'released' -Actual $end.Last.event
        Assert-Equal -Expected 1 -Actual ([int]$end.Last.stopped)
        Assert-False (Test-ProcessAlive -ProcessId ([int]$run.Result.pid)) 'the browser is gone'
        Assert-False (Test-Path -LiteralPath $run.Result.dir) 'the session folder is gone'
    }

    It 'ends the hold with exit 70 when the browser dies' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $holder = Start-LauncherHold -Id 'a1'
        Assert-StringEqual -Expected 'holding' -Actual $holder.First.event
        & kill -KILL ([int]$run.Result.pid)
        $end = Wait-LauncherHold -Holder $holder -Seconds 30
        Assert-True $end.Exited 'the holder exited within 30 s'
        Assert-Equal -Expected 70 -Actual $end.ExitCode
        Assert-StringEqual -Expected 'browser-exited' -Actual $end.Last.event
        Assert-False (Test-Path -LiteralPath $run.Result.dir) 'the session folder is gone'
    }

    It 'refuses to hold a session that does not exist' {
        $run = Invoke-Launcher -Arguments @('hold', '--id', 'none')
        Assert-Equal -Expected 66 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'session-not-found' -Actual $run.Result.kind
    }

    It 'stops the browser when the holder is signaled' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $holder = Start-LauncherHold -Id 'a1'
        Assert-StringEqual -Expected 'holding' -Actual $holder.First.event
        & kill -TERM $holder.Process.Id
        $end = Wait-LauncherHold -Holder $holder
        Assert-True $end.Exited 'the holder exited within 20 s'
        Assert-Equal -Expected 0 -Actual $end.ExitCode
        Assert-StringEqual -Expected 'signaled' -Actual $end.Last.event
        Assert-False (Test-ProcessAlive -ProcessId ([int]$run.Result.pid)) 'the browser is gone'
    }

    It 'ends an earlier session when a new one starts' {
        $first = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $second = Invoke-Launcher -Arguments @('start', '--id', 'a2', '--browser', $script:StandIn)
        Assert-Equal -Expected 0 -Actual $second.ExitCode -Because $second.StdErr
        Assert-False (Test-ProcessAlive -ProcessId ([int]$first.Result.pid)) 'the browser of a1 is gone'
        $folders = @(Get-SessionFolder)
        Assert-Equal -Expected 1 -Actual $folders.Count
        Assert-StringEqual -Expected (Split-Path -Leaf $second.Result.dir) -Actual $folders[0]
    }

    It 'stops by id and reports zero for a second stop' {
        $null = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $stop1 = Invoke-Launcher -Arguments @('stop', '--id', 'a1')
        $stop2 = Invoke-Launcher -Arguments @('stop', '--id', 'a1')
        Assert-Equal -Expected 0 -Actual $stop1.ExitCode
        Assert-Equal -Expected 1 -Actual ([int]$stop1.Result.stopped)
        Assert-Equal -Expected 0 -Actual $stop2.ExitCode
        Assert-Equal -Expected 0 -Actual ([int]$stop2.Result.stopped)
    }

    It 'reports a browser that exits at once' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', '/bin/false')
        Assert-Equal -Expected 70 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'browser-exited' -Actual $run.Result.kind
        Assert-Equal -Expected 0 -Actual (Get-SessionFolder).Count
    }

    It 'gives up at the ready limit and leaves nothing behind' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:Sleeper, '--ready-seconds', '2')
        $watch.Stop()
        Assert-Equal -Expected 75 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'not-ready' -Actual $run.Result.kind
        Assert-True ($watch.Elapsed.TotalSeconds -lt 20) "the start gave up after $($watch.Elapsed.TotalSeconds) s"
        Assert-True (Wait-Condition -Condition { -not (& pgrep -f -- $script:Sleeper) }) 'no process runs the sleeping browser'
        Assert-Equal -Expected 0 -Actual (Get-SessionFolder).Count
    }

    It 'reports a missing browser' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', '/nonexistent/browser')
        Assert-Equal -Expected 127 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'browser-not-found' -Actual $run.Result.kind
    }

    It 'never signals a process that only shares the recorded pid' {
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn)
        $sleeper = [System.Diagnostics.Process]::Start('sleep', '300')
        try {
            Set-Content -LiteralPath (Join-Path $run.Result.dir 'pid') -Value "$($sleeper.Id)" -Encoding ascii
            $stop = Invoke-Launcher -Arguments @('stop', '--id', 'a1')
            Assert-Equal -Expected 0 -Actual $stop.ExitCode
            Assert-True (Test-ProcessAlive -ProcessId $sleeper.Id) 'the process that only shares the pid still runs'
            Assert-False (Test-ProcessAlive -ProcessId ([int]$run.Result.pid)) 'the browser is gone: the sweep by profile argument found it'
        } finally {
            if (-not $sleeper.HasExited) {
                $sleeper.Kill()
                $null = $sleeper.WaitForExit(10000)
            }
            $sleeper.Dispose()
        }
    }

    It 'removes sessions left by another boot' {
        if (-not (Test-Path -LiteralPath $script:Base)) { & mkdir -m 700 $script:Base }
        $old = Join-Path $script:Base 'old1.deadbeef'
        $null = New-Item -ItemType Directory -Path (Join-Path $old 'profile') -Force
        Set-Content -LiteralPath (Join-Path $old 'pid') -Value '1' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $old 'ticks') -Value '1' -Encoding ascii
        $run = Invoke-Launcher -Arguments @('stop', '--all')
        Assert-Equal -Expected 0 -Actual $run.ExitCode
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $script:Base -Force).Count
    }

    It 'rejects <Case> with exit 64' -ForEach @(
        @{ Case = 'start without --id'; Arguments = @('start'); Relative = $false }
        @{ Case = 'an id with a space'; Arguments = @('start', '--id', 'a b'); Relative = $false }
        @{ Case = 'the verb bogus'; Arguments = @('bogus', '--id', 'a1'); Relative = $false }
        @{ Case = 'an id of 17 characters'; Arguments = @('start', '--id', 'abcdefghijklmnopq'); Relative = $false }
        @{ Case = 'a window written with x'; Arguments = @('start', '--id', 'a1', '--window', '1280x800'); Relative = $false }
        @{ Case = 'stop with neither --id nor --all'; Arguments = @('stop'); Relative = $false }
        @{ Case = 'a relative state folder'; Arguments = @('start', '--id', 'a1'); Relative = $true }
    ) {
        $base = if ($Relative) { 'b' } else { $script:Base }
        $run = Invoke-Launcher -Arguments $Arguments -Base $base
        Assert-Equal -Expected 64 -Actual $run.ExitCode -Because $Case
        $lines = @(([string]$run.StdErr -split "\r?\n") | Where-Object { $_ })
        Assert-True (@($lines | Where-Object { $_.StartsWith('yuruna-web-browser: ') }).Count -ge 1) "standard error: $($run.StdErr)"
    }

    It 'refuses a state folder that is a link' {
        $real = Join-Path $script:Work 'real-base'
        $null = New-Item -ItemType Directory -Path $real -Force
        $link = Join-Path $script:Work 'link-base'
        if (-not (Test-Path -LiteralPath $link)) { $null = New-Item -ItemType SymbolicLink -Path $link -Target $real }
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn) -Base $link
        Assert-Equal -Expected 73 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'state-dir-unsafe' -Actual $run.Result.kind
    }

    It 'runs from the staged command form' {
        $startText = InModuleScope Test.WebSession { Get-GuestWebBrowserCommand -Verb start -Id g1 -Window '1280,800' -ReadySeconds 30 }
        $startText += " --browser '$($script:StandIn)'"
        $start = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', $startText) -Environment @{ YURUNA_WEB_BASE = $script:Base } -TimeoutSeconds 30
        $started = ConvertFrom-LauncherLine -Text $start.StdOut
        Assert-Equal -Expected 0 -Actual $start.ExitCode -Because $start.StdErr
        Assert-StringEqual -Expected 'started' -Actual $started.event
        Assert-StringEqual -Expected 'g1' -Actual $started.id
        $holdText = InModuleScope Test.WebSession { Get-GuestWebBrowserCommand -Verb hold -Id g1 }
        $hold = Invoke-BoundedNativeCommand -FilePath 'bash' -ArgumentList @('-c', $holdText) -Environment @{ YURUNA_WEB_BASE = $script:Base } -TimeoutSeconds 30
        $events = @(([string]$hold.StdOut -split "\r?\n") | Where-Object { $_ -like 'YURUNA_WEB_BROWSER *' } | ForEach-Object { (ConvertFrom-LauncherLine -Text $_).event })
        Assert-Equal -Expected 0 -Actual $hold.ExitCode -Because $hold.StdErr
        Assert-StringEqual -Expected 'holding,released' -Actual ($events -join ',')
    }

    It 'reports <Kind> when the browser log names it' -ForEach @(
        @{ Kind = 'sandbox-unavailable'; Says = 'No usable sandbox' }
        @{ Kind = 'socket-path-too-long'; Says = 'Socket path too long' }
    ) {
        $failing = Join-Path $script:Bin "says-$Kind"
        Write-ShimFile -Path $failing -Text "#!/bin/sh`necho '$Says' >&2`nexit 1`n"
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $failing)
        Assert-Equal -Expected 70 -Actual $run.ExitCode
        Assert-StringEqual -Expected $Kind -Actual $run.Result.kind
        Assert-True ([string]$run.Result.detail).Contains($Says) "detail: $($run.Result.detail)"
        Assert-Equal -Expected 0 -Actual (Get-SessionFolder).Count
    }

    It 'refuses a browser path it would have to escape' {
        $spaced = Join-Path $script:Work 'with space'
        $null = New-Item -ItemType Directory -Path $spaced -Force
        $copy = Join-Path $spaced 'browser'
        Copy-Item -LiteralPath $script:StandIn -Destination $copy -Force
        & chmod +x $copy
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $copy)
        Assert-Equal -Expected 64 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'browser-path-unsupported' -Actual $run.Result.kind
        Assert-Equal -Expected 0 -Actual (Get-SessionFolder).Count
    }

    It 'refuses a state folder it cannot create' {
        $file = Join-Path $script:Work 'a-file'
        Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
        $run = Invoke-Launcher -Arguments @('start', '--id', 'a1', '--browser', $script:StandIn) -Base "$file/b"
        Assert-Equal -Expected 73 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'state-dir-unavailable' -Actual $run.Result.kind
    }

    It 'finds and stops a browser that rewrote its process title' {
        # Chrome rewrites its process title once it runs: /proc/<pid>/cmdline then
        # holds all its arguments as one string joined by spaces, with no NUL
        # between them, so the profile argument is no longer a NUL-separated one.
        $run = Invoke-Launcher -Arguments @('start', '--id', 'r1', '--browser', $script:RetitleStandIn)
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.StdErr
        $browserPid = [int]$run.Result.pid
        $retitled = Wait-Condition -Condition {
            $bytes = [System.IO.File]::ReadAllBytes("/proc/$browserPid/cmdline")
            $bytes.Length -gt 1 -and [Array]::IndexOf($bytes, [byte]0) -eq ($bytes.Length - 1)
        }
        Assert-True $retitled 'the stand-in rewrote its title into one string'
        $holder = Start-LauncherHold -Id 'r1'
        Assert-StringEqual -Expected 'holding' -Actual $holder.First.event -Because $holder.FirstLine
        $stop = Invoke-Launcher -Arguments @('stop', '--id', 'r1')
        Assert-Equal -Expected 0 -Actual $stop.ExitCode
        Assert-Equal -Expected 1 -Actual ([int]$stop.Result.stopped)
        Assert-False (Test-ProcessAlive -ProcessId $browserPid) 'the browser is gone'
        $null = Wait-LauncherHold -Holder $holder -Seconds 30
    }
}

Describe 'the launcher text' {
    BeforeAll {
        $script:LauncherText = Get-Content -LiteralPath $script:Launcher -Raw
    }

    It 'gives the browser the documented arguments and none that weaken it' {
        foreach ($flag in '--headless=new', '--user-data-dir=', '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
            '--disable-gpu', '--window-size=', '--disable-background-networking', '--disable-component-update', '--disable-sync',
            '--disable-default-apps', '--disable-breakpad', '--no-pings', '--password-store=basic', '--disable-extensions',
            '--disable-component-extensions-with-background-pages', 'about:blank', 'setsid', 'LANGUAGE=en_US') {
            Assert-True $script:LauncherText.Contains($flag) "the launcher passes $flag"
        }
        foreach ($line in ($script:LauncherText -split "\r?\n")) {
            if ($line.Trim().StartsWith('#')) { continue }
            foreach ($weak in '--no-sandbox', '--remote-allow-origins', '--remote-debugging-address', '--lang', '--proxy-server', '--no-proxy-server') {
                Assert-False $line.Contains($weak) "a line passes ${weak}: $line"
            }
        }
    }

    It 'fits one command line on every host' {
        $length = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Launcher)).Length
        Assert-True ($length -lt 24000) "the launcher is $length base64 characters"
    }
}

Describe 'the browser install script' -Skip:(-not $IsLinux) {
    BeforeAll {
        $scriptText = (Get-Content -LiteralPath $script:InstallScript -Raw).Replace("`r`n", "`n")
        $retryLine = '. /usr/local/lib/yuruna/yuruna-retry.sh'
        if (-not $scriptText.Contains($retryLine)) { throw "the install script no longer sources $retryLine" }
        $stubs = @'
yrn_log() { printf '%s\n' "$*" >> "$YRN_LOG"; }
sudo() {
    if [ "$1" = tee ]; then
        local input
        input=$(cat)
        yrn_log "sudo tee $2 $input"
    else
        yrn_log "sudo $*"
    fi
}
apt_retry() { yrn_log "apt_retry $*"; }
curl_retry() { yrn_log "curl_retry $*"; }
_yuruna_verify_key_fpr() { yrn_log "verify $2"; return "$YRN_VERIFY"; }
gpg() { cat > /dev/null; echo KEYRING; yrn_log "gpg $*"; }
uname() { echo "$YRN_UNAME"; }
dpkg() { echo "$YRN_DEBARCH"; }
dpkg-query() { if [ -n "$YRN_DPKG" ]; then printf '%s' "$YRN_DPKG"; else return 1; fi; }
systemd-detect-virt() { echo kvm; }
timeout() { shift 2; "$@"; }

'@
        $script:InstallBody = $stubs + $scriptText.Replace($retryLine, ':')
        $script:InstallBin = Join-Path $script:Work 'install-bin'
        $null = New-Item -ItemType Directory -Path $script:InstallBin -Force
        Write-ShimFile -Path (Join-Path $script:InstallBin 'google-chrome-stable') -Text @'
#!/bin/sh
if [ "$1" = --version ]; then echo 'Google Chrome 157.0.8103.78'; exit 0; fi
if [ -n "$YRN_BROWSER_FAIL" ]; then exit 1; fi
echo '<html><head></head><body></body></html>'
'@

        function Invoke-InstallCase {
            param([string]$Uname = 'x86_64', [string]$DebArch = 'amd64', [string]$Dpkg = '', [int]$Verify = 0, [switch]$BrowserFails)
            $case = New-YurunaTestTempDir -Prefix 'yrn-browser-install'
            $tmp = Join-Path $case 'tmp'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $log = Join-Path $case 'log'
            $environment = @{
                PATH             = $script:InstallBin + [IO.Path]::PathSeparator + $env:PATH
                TMPDIR           = $tmp
                YRN_LOG          = $log
                YRN_UNAME        = $Uname
                YRN_DEBARCH      = $DebArch
                YRN_DPKG         = $Dpkg
                YRN_VERIFY       = "$Verify"
                YRN_BROWSER_FAIL = $(if ($BrowserFails) { '1' } else { '' })
            }
            try {
                $result = Invoke-YurunaTestShell -Body $script:InstallBody -Environment $environment -TimeoutSeconds 60
                return @{
                    ExitCode = $result.ExitCode
                    Output   = [string]$result.Output
                    Log      = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' })
                    TmpCount = @(Get-ChildItem -LiteralPath $tmp -Force).Count
                }
            } finally {
                Remove-YurunaTestTempDir $case
            }
        }

        function Test-LogHoldsInOrder {
            param([string]$Text, [string[]]$Expected)
            $at = 0
            foreach ($piece in $Expected) {
                $found = $Text.IndexOf($piece, $at, [StringComparison]::Ordinal)
                Assert-True ($found -ge 0) "the log holds '$piece' after position $at; log: $Text"
                $at = $found + $piece.Length
            }
        }
    }

    It 'adds the pinned repository, then installs and checks the browser' {
        $run = Invoke-InstallCase
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        Test-LogHoldsInOrder -Text $run.Log -Expected @(
            'https://dl.google.com/linux/linux_signing_key.pub'
            'EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796'
            '/etc/apt/keyrings/google-linux.gpg'
            '/etc/default/google-chrome'
            'repo_add_once="false"'
            '/etc/apt/sources.list.d/yuruna-google-chrome.list'
            'arch=amd64 signed-by=/etc/apt/keyrings/google-linux.gpg'
            'apt-get update'
            'apt-get install -y --no-install-recommends google-chrome-stable'
        )
        Assert-Match -Pattern '(?m)^Browser: ' -Actual $run.Output
        Assert-Match -Pattern '(?m)^Browser version: Google Chrome 157\.0\.8103\.78' -Actual $run.Output
        Assert-Match -Pattern '(?m)^Browser architecture: amd64' -Actual $run.Output
        Assert-Equal -Expected 0 -Actual $run.TmpCount -Because 'TMPDIR is empty afterwards'
    }

    It 'keeps an installed browser and still checks it' {
        $run = Invoke-InstallCase -Dpkg 'installed'
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        Assert-StringEqual -Expected '' -Actual ([string]$run.Log).Trim()
        Assert-True $run.Output.Contains('google-chrome-stable is installed; keeping it.') $run.Output
        Assert-Match -Pattern '(?m)^Browser: ' -Actual $run.Output
        Assert-Match -Pattern '(?m)^Browser version: ' -Actual $run.Output
        Assert-Match -Pattern '(?m)^Browser architecture: amd64' -Actual $run.Output
    }

    It 'stops before any package work when the key does not match' {
        $run = Invoke-InstallCase -Verify 1
        Assert-Equal -Expected 1 -Actual $run.ExitCode
        Assert-True $run.Output.Contains('NONZERO SCRIPT EXIT: google apt key fingerprint mismatch') $run.Output
        Assert-False $run.Log.Contains('apt-get') "log: $($run.Log)"
        Assert-False $run.Log.Contains('tee') "log: $($run.Log)"
        Assert-Equal -Expected 0 -Actual $run.TmpCount -Because 'TMPDIR is empty afterwards'
    }

    It 'writes the source line for the guest architecture' {
        $run = Invoke-InstallCase -Uname 'aarch64' -DebArch 'arm64'
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because $run.Output
        Assert-Match -Pattern 'yuruna-google-chrome\.list deb \[arch=arm64 ' -Actual $run.Log
        Assert-True $run.Output.Contains('Browser architecture: arm64') $run.Output
    }

    It 'fails when the browser does not render headless' {
        $run = Invoke-InstallCase -BrowserFails
        Assert-Equal -Expected 1 -Actual $run.ExitCode
        Assert-True $run.Output.Contains('NONZERO SCRIPT EXIT: the browser did not render about:blank headless') $run.Output
    }
}

Describe 'the browser install script text' {
    It 'never disables the sandbox, installs no snap and keeps its source file apart from the package''s own' {
        $text = Get-Content -LiteralPath $script:InstallScript -Raw
        Assert-False $text.Contains('--no-sandbox') 'the install script passes --no-sandbox'
        Assert-False $text.Contains('snap install') 'the install script installs a snap'
        Assert-True $text.Contains('yuruna-google-chrome.list') 'the source file is yuruna-google-chrome.list'
        Assert-False $text.Contains('sources.list.d/google-chrome.list') 'the source file is the one the package deletes'
    }
}
