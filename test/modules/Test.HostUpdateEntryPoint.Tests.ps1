<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42e90f6c-0b72-4240-a71f-926777e3e0da
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update entry-point pester
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
    test/lab/Invoke-HostUpdate.ps1 in fresh -NoProfile processes, each with a
    scratch HOME and runtime directory: the module closure of its set, a
    request with no controller, a queued local request with drain now, busy
    and scope refusals, and the three release paths (refused while a
    controller runs the update, marked while it recovers, done by the
    command when no controller runs, which first waits out a live step child
    or PowerShell upgrade and ends the elevated units and the sudo rule
    through a stand-in sudo before it opens the gate; on macOS, taken from
    the update's host type, it ends the update's installer, found by its
    arguments, and removes the rule with the one rm the permanent entry
    allows). Also the capability
    the listener and
    the command read before admitting an update. The suite plays the
    controller itself: it holds the controller lock and writes the journal
    through the module's home seam. The only processes ever signaled are the
    ones a test started itself.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module Test.HostRepair, Test.HostOperationJournal | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostOperationJournal.psm1') -Force -Global -DisableNameChecking
    $script:Entry = Join-Path $script:RepoRoot 'test/lab/Invoke-HostUpdate.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:UserName = [Environment]::UserName
    $script:Snapshot = '0123456789abcdef'
    $script:Created = [System.Collections.Generic.List[string]]::new()
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:Locks = [System.Collections.Generic.List[object]]::new()
    $script:ScratchBase = (Resolve-YurunaCanonicalPath -Path (New-YurunaTestTempDir -Prefix 'yuruna-host-update-entry')).Path
    $script:Created.Add($script:ScratchBase)
    $script:ParentModulePath = $env:PSModulePath

    # Admission in this process reads the runner gate by name; the suite
    # keeps it open. The child processes read the real gate under their own
    # scratch HOME.
    ${function:global:Get-YurunaRunnerGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $RuntimeDir, $TokenId, $PrivateRoot
        [pscustomobject]@{ State = 'open'; RequestId = $null; Generation = ''; Reason = 'test' }
    }

    function New-EntryEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates scratch directories and points the journal module at them.')]
        param()
        $base = Join-Path $script:ScratchBase ('ep-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
        $script:Created.Add($base)
        $layout = [ordered]@{}
        foreach ($name in @('home', 'runtime', 'tmp', 'work', 'pwsh-cache', 'pwsh-data', 'pwsh-config')) {
            $layout[$name] = Join-Path $base $name
            $null = New-Item -ItemType Directory -Path $layout[$name] -Force
        }
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $layout.home
        $environment = @{
            HOME = $layout.home; YURUNA_RUNTIME_DIR = $layout.runtime; TMPDIR = $layout.tmp
            XDG_CACHE_HOME = $layout.'pwsh-cache'; XDG_DATA_HOME = $layout.'pwsh-data'; XDG_CONFIG_HOME = $layout.'pwsh-config'
            PSModulePath = $script:ParentModulePath; POWERSHELL_TELEMETRY_OPTOUT = '1'; POWERSHELL_UPDATECHECK = 'Off'
            DOTNET_EnableDiagnostics = '0'; NO_COLOR = '1'; USER = $script:UserName
        }
        [pscustomobject]@{ Base = $base; Home = $layout.home; Runtime = $layout.runtime; Work = $layout.work; Environment = $environment
            Root = (Join-Path $layout.home '.yuruna/host-repair') }
    }

    function Start-EntryProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts a disposable process the suite owns.')]
        param([Parameter(Mandatory)]$Fixture, [string[]]$Argument = @(), [string]$Command)
        $info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($token in @('-NoLogo', '-NoProfile', '-NonInteractive')) { $info.ArgumentList.Add($token) }
        if ($Command) { $info.ArgumentList.Add('-Command'); $info.ArgumentList.Add($Command) }
        else { $info.ArgumentList.Add('-File'); $info.ArgumentList.Add($script:Entry); foreach ($token in $Argument) { $info.ArgumentList.Add($token) } }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardInput = $true
        $info.UseShellExecute = $false
        $info.WorkingDirectory = $Fixture.Work
        foreach ($name in @('YURUNA_SG_RELAUNCH', 'YURUNA_NONINTERACTIVE', 'YURUNA_LOG_DIR', 'YURUNA_DETACH_HANDSHAKE', 'YURUNA_DETACH_HOP_PID', 'YURUNA_DETACH_HOP_START',
                'YURUNA_HANDOFF_TOKEN', 'YURUNA_HANDOFF_PREFLIGHT', 'YURUNA_HANDOFF_BARRIER', 'YURUNA_CYCLE_GENERATION')) { $null = $info.Environment.Remove($name) }
        foreach ($key in $Fixture.Environment.Keys) { $info.Environment[$key] = [string]$Fixture.Environment[$key] }
        $process = [System.Diagnostics.Process]::Start($info)
        $process.StandardInput.Close()
        $script:Spawned.Add($process)
        [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    }

    function Wait-EntryProcess {
        param([Parameter(Mandatory)]$Started, [int]$TimeoutSeconds = 120)
        if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $Started.Process.Kill($true) } catch { $null = $_ }
            throw "the entry process did not finish within $TimeoutSeconds s"
        }
        $Started.Process.WaitForExit()
        $text = ([string]$Started.Out.Result + "`n" + [string]$Started.Err.Result) -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        [pscustomobject]@{ ExitCode = $Started.Process.ExitCode; Output = $text }
    }

    function Invoke-EntryProcess {
        param([Parameter(Mandatory)]$Fixture, [string[]]$Argument = @(), [string]$Command, [int]$TimeoutSeconds = 120)
        Wait-EntryProcess -Started (Start-EntryProcess -Fixture $Fixture -Argument $Argument -Command $Command) -TimeoutSeconds $TimeoutSeconds
    }

    function Enter-TestControllerLock {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: holds the scratch controller lock as a stand-in controller.')]
        param()
        $lock = Enter-YurunaSingleFlightLock -Path (Get-HostUpdateControllerLockPath) -WaitMilliseconds 2000 -Metadata @{ purpose = 'host-controller'; snapshot = $script:Snapshot }
        Assert-True $lock.Held "the stand-in controller lock: $($lock.Reason)"
        $script:Locks.Add($lock)
        $lock
    }

    function Exit-TestLock {
        param($Lock)
        if ($Lock -and $Lock.Held) { Exit-YurunaSingleFlightLock -Lock $Lock }
        $null = $script:Locks.Remove($Lock)
    }

    function Add-TestUpdate {
        param([Parameter(Mandatory)]$Fixture, [string]$Channel = 'listener', [string]$Scope = 'restart',
            [string]$HostType = $(if ($IsWindows) { 'host.windows.hyper-v' } else { 'host.ubuntu.kvm' }))
        $id = New-YurunaHostOperationRequestId
        $admission = Request-HostUpdateAdmission -RequestId $id -Channel $Channel -Scope $Scope -RuntimeDir $Fixture.Runtime -HostType $HostType -Confirm:$false
        Assert-Equal 'queued' $admission.Decision $admission.Reason
        $id
    }

    function Add-TestClaim {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][int]$ControllerPid, [long]$StartTimeUnixMs = 1, [string]$Scope = 'restart',
            [string]$HostType = $(if ($IsWindows) { 'host.windows.hyper-v' } else { 'host.ubuntu.kvm' }))
        $id = Add-TestUpdate -Fixture $Fixture -Scope $Scope -HostType $HostType
        $lifetime = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
        try {
            $claim = Confirm-HostUpdateClaim -RequestId $id -LifetimeLock $lifetime -ControllerPid $ControllerPid -ControllerStartTimeUnixMs $StartTimeUnixMs `
                -Snapshot $script:Snapshot -RepoRoot $script:RepoRoot -Mode claim -Confirm:$false
            Assert-True $claim.Accepted $claim.Reason
        } finally { Exit-YurunaSingleFlightLock -Lock $lifetime }
        $id
    }

    function Get-TestRow {
        param([Parameter(Mandatory)][string]$RequestId)
        $journal = (Read-HostOperationJournal).Journal
        if (-not $journal) { return $null }
        @($journal.requests | Where-Object { $_['requestId'] -ceq $RequestId })[0]
    }

    function Get-OwnStart {
        param()
        [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds()
    }

    # Gate reads and writes in a child process: the gate module resolves the
    # private root from HOME, and this process's HOME is the operator's.
    function Invoke-GateCommand {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Body)
        $command = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($script:RepoRoot)/automation/Yuruna.Globalization.psm1' -DisableNameChecking
Import-Module '$($script:RepoRoot)/test/modules/Test.SingleInstance.psm1' -Global -DisableNameChecking 3>`$null
`$runtime = '$($Fixture.Runtime)'
$Body
"@
        $run = Invoke-EntryProcess -Fixture $Fixture -Command $command
        $line = @($run.Output -split "`n" | Where-Object { $_.StartsWith('GATE:') })[0]
        Assert-NotNull $line "the gate command answered: $($run.Output)"
        $line.Substring(5).Trim()
    }

    function Close-TestGate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: closes the scratch runner gate as a stand-in controller.')]
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$OwnerPid)
        Invoke-GateCommand -Fixture $Fixture -Body @"
`$gate = Get-YurunaRunnerGateState -RuntimeDir `$runtime
`$write = Set-YurunaRunnerGate -State closed -RequestId '$RequestId' -Attempt 1 -RuntimeDir `$runtime -ExpectedGeneration ([string]`$gate.Generation) -OwnerPid $OwnerPid -OwnerRole controller -Confirm:`$false
'GATE:' + [bool]`$write.Written + '|' + (Get-YurunaRunnerGateState -RuntimeDir `$runtime).State
"@
    }

    function Get-TestGateState {
        param([Parameter(Mandatory)]$Fixture)
        Invoke-GateCommand -Fixture $Fixture -Body "'GATE:' + (Get-YurunaRunnerGateState -RuntimeDir `$runtime).State"
    }

    # A stand-in sudo first on the child's PATH. Each call is recorded with
    # the state of the runner gate record at that moment, so a test can tell
    # whether an elevated step ran before or after the gate opened. It
    # answers the calls of a release by pattern and refuses anything else;
    # it never runs a command itself, so no real sudo is ever reached.
    function New-TestSudoStub {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in executable into the scratch directory.')]
        param([Parameter(Mandatory)]$Fixture, [ValidateRange(0, 255)][int]$UnitStopExit = 0)
        $bin = Join-Path $Fixture.Base 'bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $log = Join-Path $Fixture.Base 'sudo.log'
        $record = Join-Path $Fixture.Root 'runner-gate.record'
        $text = @"
#!/bin/sh
record=`$(cat '$record' 2>/dev/null)
case "`$record" in
    *'"state":"released"'*) seen=released ;;
    *'"state":"closed"'*) seen=closed ;;
    *) seen=other ;;
esac
printf '%s|%s\n' "`$seen" "`$*" >> '$log'
case "`$*" in
    '-n systemctl list-units --all --plain --no-legend --no-pager '*) printf '%s\n' 'yuruna-host-update-install-1.service loaded active running host update install'; exit 0 ;;
    '-n systemctl stop yuruna-host-update-install-1.service') exit $UnitStopExit ;;
    '-n rm -f /etc/sudoers.d/yuruna-host-update') exit 0 ;;
    '-n systemctl stop yuruna-host-update-expire.timer') exit 0 ;;
esac
exit 1
"@
        $path = Join-Path $bin 'sudo'
        [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"))
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $Fixture.Environment['PATH'] = $bin + [IO.Path]::PathSeparator + $env:PATH
        [pscustomobject]@{ Log = $log }
    }

    function Get-TestSudoCall {
        param([Parameter(Mandatory)]$Stub)
        if (-not [IO.File]::Exists($Stub.Log)) { return [string[]]@() }
        [string[]]@([IO.File]::ReadAllLines($Stub.Log) | Where-Object { $_ })
    }

    function Add-TestElevatedClaim {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][int]$ControllerPid, [string[]]$Obligation = @('gate', 'runner', 'elevation'),
            [string]$HostType = $(if ($IsWindows) { 'host.windows.hyper-v' } else { 'host.ubuntu.kvm' }))
        $id = Add-TestClaim -Fixture $Fixture -ControllerPid $ControllerPid -Scope full -HostType $HostType
        foreach ($name in $Obligation) {
            $armed = Set-HostUpdateObligation -RequestId $id -ControllerPid $ControllerPid -ObligationId $name -State armed -Confirm:$false
            Assert-True $armed.Written "$name armed: $($armed.Reason)"
        }
        $id
    }

    # The process table and the process ends of a macOS release, injected
    # through the -Service seams of Get-HostUpdateMacElevatedWork and
    # Stop-HostUpdateMacElevatedWork. The release reads only the rows written
    # here, and ending a member only marks it stopped, so it never reads or
    # signals a process of this host: an Enable-TestAutomation -NoOperatorPrompt
    # that another suite runs at the same moment has the shape the release
    # ends. With a request id the table holds that update's unattended
    # installer, as the test account, with one child. Each call is recorded.
    function New-TestMacProcessSeam {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes stand-in state into the scratch directory.')]
        param([Parameter(Mandatory)]$Fixture, [string]$RequestId, [System.Collections.IDictionary]$Enable = @{})
        $stopped = Join-Path $Fixture.Base 'stopped'
        $null = New-Item -ItemType Directory -Path $stopped -Force
        $log = Join-Path $Fixture.Base 'process.log'
        $installerPid = 2147470001
        $childPid = 2147470002
        $rows = '@()'
        if ($RequestId) {
            [IO.File]::WriteAllText((Join-Path $Fixture.Base 'installer.pid'), "$installerPid")
            $rows = "@([pscustomobject]@{ Pid = $installerPid; ParentPid = 1; StartTimeUnixMs = 1700000000000; OwnerId = '501'; CommandLine = ''; " +
                "Argv = @('/bin/sh', '/Users/test/git/yuruna/install/macos.utm.sh', '--unattended', '--request-id', '$RequestId', '--attempt', '1') }, " +
                "[pscustomobject]@{ Pid = $childPid; ParentPid = $installerPid; StartTimeUnixMs = 1700000000100; OwnerId = '501'; CommandLine = ''; " +
                "Argv = @('/opt/homebrew/bin/brew', 'upgrade') })"
        }
        # Each Enable run is a row in the shape macOS ps gives: the joined
        # command line only.
        if ($Enable.Count -gt 0) {
            $enableRows = @(foreach ($entry in $Enable.GetEnumerator()) {
                    "[pscustomobject]@{ Pid = $($entry.Key); ParentPid = 1; StartTimeUnixMs = 1700000000200; OwnerId = '501'; Argv = `$null; " +
                    "CommandLine = '/usr/local/microsoft/powershell/7/pwsh -NoLogo -NoProfile -NonInteractive -File $($entry.Value) -SkipPoolStorage -NoOperatorPrompt' }"
                })
            $rows = "(@($rows) + @(" + ($enableRows -join ', ') + "))"
        }
        $preamble = @"
`$global:PSDefaultParameterValues['Get-HostUpdateMacElevatedWork:Service'] = @{
    ProcessTable = { [IO.File]::AppendAllText('$log', "table``n"); [pscustomobject]@{ Complete = `$true; Rows = $rows } }
}
`$global:PSDefaultParameterValues['Stop-HostUpdateMacElevatedWork:Service'] = @{
    Liveness    = { param(`$ProcessId, `$StartTimeUnixMs) if ([IO.File]::Exists([IO.Path]::Combine('$stopped', "`$ProcessId"))) { 'dead' } else { 'alive' } }
    StopProcess = { param(`$ProcessId) [IO.File]::AppendAllText('$log', "stop `$ProcessId``n"); [IO.File]::WriteAllText([IO.Path]::Combine('$stopped', "`$ProcessId"), '') }
    Sleep       = { param([int]`$Milliseconds) }
}
"@
        [pscustomobject]@{ Preamble = $preamble; Log = $log; InstallerPid = $installerPid; ChildPid = $childPid }
    }

    function Get-TestMacProcessCall {
        param([Parameter(Mandatory)]$Seam)
        if (-not [IO.File]::Exists($Seam.Log)) { return [string[]]@() }
        [string[]]@([IO.File]::ReadAllLines($Seam.Log) | Where-Object { $_ })
    }

    # The release under the seam: the host command runs in a child whose
    # defaults hand the stand-ins to both functions.
    function Invoke-TestMacRelease {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)]$Seam, [Parameter(Mandatory)][string]$RequestId)
        Invoke-EntryProcess -Fixture $Fixture -Command ($Seam.Preamble + "`n& '$($script:Entry)' -Release '$RequestId'`nexit `$LASTEXITCODE`n")
    }

    # A real process of this suite with the shape of an unattended
    # Enable-TestAutomation of no update here (argv[0] pwsh, the script's
    # name and -NoOperatorPrompt), started through a shell that exits at
    # once so that it is nobody's child here. The release must leave it
    # running: the proof that the seam keeps it off this host's table.
    function Start-TestEnableDecoy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts a disposable process the suite owns.')]
        param([Parameter(Mandatory)]$Fixture)
        $dir = Join-Path $Fixture.Base 'decoy'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script = Join-Path $dir 'Enable-TestAutomation.ps1'
        $pidFile = Join-Path $dir 'decoy.pid'
        $inner = "printf '%s\n' `"`$`$`" > '$pidFile'; sleep 120; :"
        $info = [System.Diagnostics.ProcessStartInfo]::new('/bin/bash')
        foreach ($token in @('-c', 'exec -a pwsh /bin/bash -c "$1" decoy "$2" -NoOperatorPrompt > /dev/null 2>&1 &', 'sh', $inner, $script)) { $info.ArgumentList.Add($token) }
        $info.UseShellExecute = $false
        $launcher = [System.Diagnostics.Process]::Start($info)
        $launcher.WaitForExit()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [IO.File]::Exists($pidFile) -or -not ([IO.File]::ReadAllText($pidFile).Trim())) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'fixture sanity: the decoy did not start' }
            Start-Sleep -Milliseconds 50
        }
        [pscustomobject]@{ Pid = [int]([IO.File]::ReadAllText($pidFile).Trim()); Script = $script }
    }

    function Test-TestEnableDecoyAlive {
        param([Parameter(Mandatory)]$Decoy)
        $cmdline = "/proc/$($Decoy.Pid)/cmdline"
        if (-not [IO.File]::Exists($cmdline)) { return $false }
        try { $text = [IO.File]::ReadAllText($cmdline) } catch { return $false }
        # A pid the system gave to another process, or a zombie, is not it.
        $text.Contains($Decoy.Script)
    }

    function Stop-TestEnableDecoy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: ends the disposable process the suite started.')]
        param([Parameter(Mandatory)]$Decoy)
        # Only the decoy and its sleep, which nothing else parents.
        if (Test-TestEnableDecoyAlive -Decoy $Decoy) {
            & pkill -KILL -P $Decoy.Pid 2>$null
            Stop-Process -Id $Decoy.Pid -Force -ErrorAction SilentlyContinue
        }
    }

    # The stand-in sudo of a macOS release: each call is recorded with the
    # runner gate's state and whether the stand-in installer is still alive,
    # so a test can tell that the installer ended while the rule was still in
    # force. It answers only the one rm the permanent entry allows.
    function New-TestMacSudoStub {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in executable into the scratch directory.')]
        param([Parameter(Mandatory)]$Fixture, [ValidateRange(0, 255)][int]$RuleExit = 0)
        $bin = Join-Path $Fixture.Base 'bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $log = Join-Path $Fixture.Base 'sudo.log'
        $record = Join-Path $Fixture.Root 'runner-gate.record'
        $pidFile = Join-Path $Fixture.Base 'installer.pid'
        $stopped = Join-Path $Fixture.Base 'stopped'
        $text = @"
#!/bin/sh
record=`$(cat '$record' 2>/dev/null)
case "`$record" in
    *'"state":"released"'*) seen=released ;;
    *'"state":"closed"'*) seen=closed ;;
    *) seen=other ;;
esac
installer=none
if [ -s '$pidFile' ]; then
    if [ -e "$stopped/`$(cat '$pidFile')" ]; then installer=gone; else installer=alive; fi
fi
printf '%s|%s|installer=%s\n' "`$seen" "`$*" "`$installer" >> '$log'
case "`$*" in
    '-n /bin/rm -f /etc/sudoers.d/yuruna-host-update') exit $RuleExit ;;
esac
exit 1
"@
        $path = Join-Path $bin 'sudo'
        [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"))
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $Fixture.Environment['PATH'] = $bin + [IO.Path]::PathSeparator + $env:PATH
        [pscustomobject]@{ Log = $log }
    }
}

AfterAll {
    foreach ($lock in @($script:Locks)) { if ($lock -and $lock.Held) { Exit-YurunaSingleFlightLock -Lock $lock } }
    foreach ($process in $script:Spawned) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
    }
    & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
    Remove-Item -LiteralPath Function:\Get-YurunaRunnerGateState -ErrorAction SilentlyContinue
    foreach ($dir in $script:Created) { Remove-YurunaTestTempDir $dir }
}

# The fixtures hold POSIX locks across processes and run under a scratch HOME.
Describe 'the host command' -Skip:$IsWindows {

    It 'loads only the modules of its set and resolves every command it calls in a clean process' {
        $fixture = New-EntryEnvironment
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Entry, [ref]$null, [ref]$null)
        $own = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        $called = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $_ -match '^[A-Za-z]+-[A-Za-z]+$' -and $own -notcontains $_ } | Sort-Object -Unique)
        $command = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($script:RepoRoot)/automation/Yuruna.Globalization.psm1' -DisableNameChecking
Import-Module '$($script:RepoRoot)/test/modules/Test.Prelude.psm1' -Global -Force -DisableNameChecking
`$paths = Initialize-YurunaEntryPoint -ScriptRoot '$($script:RepoRoot)/test/lab' -InsideSubfolder
Initialize-YurunaEntryPointModuleSet -For HostUpdate -ModulesDir `$paths.ModulesDir 3>`$null
foreach (`$name in @('$($called -join "','")')) {
    `$c = Get-Command `$name -ErrorAction SilentlyContinue | Select-Object -First 1
    'CMD:{0}|{1}' -f `$name, `$(if (`$c) { [string]`$c.CommandType } else { 'MISSING' })
}
foreach (`$m in @(Get-Module | Where-Object { `$_.Name -like 'Test.*' })) { 'MOD:' + `$m.Name }
"@
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        $missing = @($run.Output -split "`n" | Where-Object { $_ -like 'CMD:*|MISSING*' })
        Assert-NoFinding $missing "every command the host command calls resolves: $($run.Output)"
        Assert-True (@($run.Output -split "`n" | Where-Object { $_ -like 'CMD:*' }).Count -eq $called.Count) 'every called command was checked'
        # The set and what its modules import themselves, and nothing else.
        $prelude = [IO.File]::ReadAllText((Join-Path $here 'Test.Prelude.psm1'))
        Assert-True ($prelude -match "(?s)\n\s+HostUpdate = @\((.*?)\)") 'the HostUpdate set is declared'
        $set = @([regex]::Matches($Matches[1], "'(Test\.[A-Za-z]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value })
        $closure = [System.Collections.Generic.HashSet[string]]::new([string[]](@($set) + 'Test.Prelude'))
        $queue = [System.Collections.Generic.Queue[string]]::new([string[]](@($set) + 'Test.Prelude'))
        $sources = @((Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1'), (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1'))
        while ($queue.Count -gt 0 -or $sources.Count -gt 0) {
            $file = if ($sources.Count -gt 0) { $sources[0]; $sources = @($sources | Select-Object -Skip 1) } else { Join-Path $here ($queue.Dequeue() + '.psm1') }
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file), "(Test\.[A-Za-z]+(?:\.[A-Za-z]+)?)\.psm1")) {
                $name = $match.Groups[1].Value
                if ([IO.File]::Exists((Join-Path $here "$name.psm1")) -and $closure.Add($name)) { $queue.Enqueue($name) }
            }
        }
        $loaded = @($run.Output -split "`n" | Where-Object { $_ -like 'MOD:*' } | ForEach-Object { $_.Substring(4).Trim() })
        Assert-True ($loaded.Count -ge $set.Count) "loaded $($loaded -join ', ')"
        Assert-NoFinding @($loaded | Where-Object { -not $closure.Contains($_) } | ForEach-Object { "$_ is loaded but not in the set or imported by it" }) 'the module closure'
        Assert-True ($loaded -notcontains 'Test.RunnerOuterLoop') 'the outer loop and its tree kills are never loaded'
    }

    It 'refuses controller_absent with nobody on the lock, and creates no private root' {
        $fixture = New-EntryEnvironment
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Scope', 'restart')
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'Invoke-HostUpdate' $run.Output
        Assert-Match '\babsent\b' $run.Output 'the lock state is named'
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna')) 'no private root is created'
        Exit-TestLock -Lock (Enter-TestControllerLock)
        $free = Invoke-EntryProcess -Fixture $fixture -Argument @('-Drain', 'now')
        Assert-Equal 1 $free.ExitCode $free.Output
        Assert-Match '\bfree\b' $free.Output
        Assert-Equal 'absent' (Read-HostOperationJournal).Status 'nothing was queued'
    }

    It 'queues a local row with drain now, and lowercases the expected commit' {
        $fixture = New-EntryEnvironment
        $lock = Enter-TestControllerLock
        try {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Drain', 'now', '-DrainSeconds', '600', '-ExpectCommit', 'ABCDEF1')
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 0 $run.ExitCode $run.Output
        $queue = Get-HostUpdateQueue
        Assert-NotNull $queue.Queued 'one host update is queued'
        $row = $queue.Queued
        Assert-Match ([regex]::Escape([string]$row['requestId'])) $run.Output 'the request id is printed'
        Assert-Match ([regex]::Escape((Join-Path $fixture.Runtime 'host-update.state.json'))) $run.Output 'the progress file is named'
        Assert-Match ([regex]::Escape('tmux -S ' + (Join-Path $fixture.Root 'host-controller/runner-console.sock') + ' attach')) $run.Output 'the attach command is named'
        Assert-Equal 'local' $row['channel']
        Assert-Equal 'queued' $row['state']
        Assert-Equal $fixture.Runtime $row['runtimeDir']
        Assert-Equal 'now' $row['update']['request']['drain']
        Assert-Equal 600 ([int]$row['update']['request']['drainSeconds'])
        Assert-Equal 'abcdef1' $row['update']['request']['expectCommit']
        Assert-Equal 'restart' $row['update']['request']['scope']
    }

    It 'refuses now while another update waits (busy)' {
        $fixture = New-EntryEnvironment
        $waiting = Add-TestUpdate -Fixture $fixture
        $lock = Enter-TestControllerLock
        try {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Drain', 'now')
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'host-update' $run.Output 'the active kind is named'
        Assert-Match ([regex]::Escape($waiting)) $run.Output 'the active request is named'
        Assert-Equal 1 @((Read-HostOperationJournal).Journal.requests).Count 'nothing else was queued'
    }

    It 'refuses scope full that the controller does not list' {
        $fixture = New-EntryEnvironment
        $lock = Enter-TestControllerLock
        try {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Scope', 'full')
            $state = [ordered]@{ schemaVersion = 1; heartbeatUtc = [DateTime]::UtcNow.ToString('o'); sessionUsable = $true; scopes = 'restart,full' }
            [IO.File]::WriteAllText((Join-Path $fixture.Runtime 'host-controller.state.json'), ($state | ConvertTo-Json -Compress))
            $listed = Invoke-EntryProcess -Fixture $fixture -Argument @('-Scope', 'full')
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match '\bfull\b' $run.Output
        Assert-Equal 0 $listed.ExitCode "a scope the controller lists is queued: $($listed.Output)"
        Assert-Equal 'full' (Get-HostUpdateQueue).Queued['update']['request']['scope']
        Assert-Equal 1 @((Read-HostOperationJournal).Journal.requests).Count 'the refused request was never queued'
    }

    It 'refuses an unknown switch, a drain other than now and a malformed release id, and writes nothing' {
        $fixture = New-EntryEnvironment
        foreach ($arguments in @(@('-Drain', 'after-cycle'), @('-Scope', 'everything'), @('-DrainSeconds', '59'), @('-ExpectCommit', 'main'),
                @('-Release', 'not-a-uuid'), @('-Release', '4242AAAA-0000-4000-8000-000000000001'), @('-Bogus'))) {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument $arguments
            Assert-NotEqual 0 $run.ExitCode "arguments $($arguments -join ' ')"
        }
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Home '.yuruna'))
    }

    It 'refuses release of a claimed update while a controller holds its lock, naming the controller from the row' {
        $fixture = New-EntryEnvironment
        $id = Add-TestClaim -Fixture $fixture -ControllerPid 4242
        $lock = Enter-TestControllerLock
        try {
            $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match ([regex]::Escape($id)) $run.Output
        Assert-Match '\b4242\b' $run.Output 'the controller pid comes from the row''s update.controller.pid'
        Assert-Equal 'running' (Get-TestRow -RequestId $id)['state'] 'the claimed update is untouched'
        Assert-Null (Get-TestRow -RequestId $id)['update']['release']
    }

    It 'refuses release of an unknown, a queued and an ended update' {
        $fixture = New-EntryEnvironment
        $queued = Add-TestUpdate -Fixture $fixture
        $unknown = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', (New-YurunaHostOperationRequestId))
        Assert-Equal 1 $unknown.ExitCode $unknown.Output
        Assert-Match 'not-found' $unknown.Output
        $waiting = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $queued)
        Assert-Equal 1 $waiting.ExitCode $waiting.Output
        Assert-Match 'not-claimed' $waiting.Output
        Assert-Equal 'queued' (Get-TestRow -RequestId $queued)['state']
    }

    It 'marks a recovering update for release when a controller runs, and reports the verdict the controller writes' {
        $fixture = New-EntryEnvironment
        $id = Add-TestClaim -Fixture $fixture -ControllerPid $PID -StartTimeUnixMs (Get-OwnStart)
        $recovering = Set-HostUpdateRecovering -RequestId $id -ControllerPid $PID -OperatorAction repair_checkout -Reason runner_start_failed `
            -NextUnixMs ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 600000) -Confirm:$false
        Assert-True $recovering.Written $recovering.Reason
        $lock = Enter-TestControllerLock
        try {
            $started = Start-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
            $wait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($wait.Elapsed.TotalSeconds -lt 45 -and -not ((Get-TestRow -RequestId $id)['update']['release'] -is [System.Collections.IDictionary])) { Start-Sleep -Milliseconds 200 }
            $mark = (Get-TestRow -RequestId $id)['update']['release']
            Assert-True ($mark -is [System.Collections.IDictionary]) 'the command wrote the release mark'
            Assert-Equal 'host-command' $mark['by']
            Assert-Equal 'recovery-pending' (Get-TestRow -RequestId $id)['state'] 'the command leaves the verdict to the running controller'
            # The stand-in controller honors the mark, as the real one does at its next check.
            $done = Complete-HostUpdate -RequestId $id -ControllerPid $PID -Verdict released -OperatorAction none -Confirm:$false
            Assert-True $done.Written $done.Reason
            $run = Wait-EntryProcess -Started $started
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Match ([regex]::Escape($id)) $run.Output
        Assert-Match '\breleased\b' $run.Output 'the verdict the controller wrote is reported'
    }

    It 'releases an update whose controller is gone: opens the gate, writes released with debt' {
        $fixture = New-EntryEnvironment
        $gone = 2147480000
        $id = Add-TestClaim -Fixture $fixture -ControllerPid $gone
        foreach ($obligation in @('gate', 'runner', 'listener')) {
            $armed = Set-HostUpdateObligation -RequestId $id -ControllerPid $gone -ObligationId $obligation -State armed -Confirm:$false
            Assert-True $armed.Written "$obligation armed: $($armed.Reason)"
        }
        $closed = Invoke-GateCommand -Fixture $fixture -Body @"
`$gate = Get-YurunaRunnerGateState -RuntimeDir `$runtime
`$write = Set-YurunaRunnerGate -State closed -RequestId '$id' -Attempt 1 -RuntimeDir `$runtime -ExpectedGeneration ([string]`$gate.Generation) -OwnerPid $gone -OwnerRole controller -Confirm:`$false
'GATE:' + [bool]`$write.Written + '|' + (Get-YurunaRunnerGateState -RuntimeDir `$runtime).State
"@
        Assert-Equal 'True|closed' $closed 'the fixture gate is closed under the update'
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Match ([regex]::Escape($id)) $run.Output
        Assert-Match '\blistener\b' $run.Output 'the debt is reported'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'completed' $row['state']
        Assert-Equal 'released' $row['update']['verdict']
        Assert-Equal 'listener' (@($row['update']['debt'] | ForEach-Object { $_['obligation'] }) -join ',')
        foreach ($obligation in @('gate', 'runner')) {
            $entry = @($row['obligations'] | Where-Object { $_['id'] -eq $obligation })[0]
            Assert-Equal 'disposed' $entry['status'] $obligation
            Assert-Equal 'host-command' $entry['disposedBy'] $obligation
        }
        Assert-Equal 'open' (Invoke-GateCommand -Fixture $fixture -Body "'GATE:' + (Get-YurunaRunnerGateState -RuntimeDir `$runtime).State") 'the gate is open again'
        Assert-Equal 'free' (Get-HostUpdateControllerLockState) 'the command released the controller lock it held'
    }

    It 'refuses release while a recorded step child of a started phase is alive, and opens no gate' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestSudoStub -Fixture $fixture
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone -Obligation @('gate', 'runner')
        # This process stands in for the step child: alive, with the start
        # time the liveness check reads.
        $started = Set-HostUpdatePhase -RequestId $id -ControllerPid $gone -Phase install -State started -Child @{ pid = $PID; startTimeUnixMs = (Get-OwnStart) } -Confirm:$false
        Assert-True $started.Written $started.Reason
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone) 'the fixture gate is closed under the update'
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'step-alive' $run.Output
        Assert-Equal 'closed' (Get-TestGateState -Fixture $fixture) 'the gate stays closed while the step child runs'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'running' $row['state']
        Assert-Null $row['update']['verdict']
        Assert-Equal 'free' (Get-HostUpdateControllerLockState) 'the refusal released the controller lock it held'
        # The same phase whose child is gone no longer holds the release.
        $dead = Set-HostUpdatePhase -RequestId $id -ControllerPid $gone -Phase install -State started -ChildOnly -Child @{ pid = 2147480001; startTimeUnixMs = 1 } -Confirm:$false
        Assert-True $dead.Written $dead.Reason
        $again = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 0 $again.ExitCode $again.Output
        Assert-Equal 'released' (Get-TestRow -RequestId $id)['update']['verdict']
        Assert-Equal 'open' (Get-TestGateState -Fixture $fixture)
        Assert-Equal 0 (Get-TestSudoCall -Stub $sudo).Count 'nothing is elevated while the elevation obligation is not armed'
    }

    It 'ends the units of a privileged phase and removes the sudo rule before it opens the gate' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestSudoStub -Fixture $fixture
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone) 'the fixture gate is closed under the update'
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 0 $run.ExitCode $run.Output
        $expected = @(
            'closed|-n systemctl list-units --all --plain --no-legend --no-pager yuruna-host-update-install-*.service yuruna-host-update-enable-*.service'
            'closed|-n systemctl stop yuruna-host-update-install-1.service'
            'closed|-n rm -f /etc/sudoers.d/yuruna-host-update'
            'closed|-n systemctl stop yuruna-host-update-expire.timer'
        )
        Assert-Equal ($expected -join "`n") ((Get-TestSudoCall -Stub $sudo) -join "`n") 'every elevated step ran, in order, while the gate was still closed'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'released' $row['update']['verdict']
        Assert-Equal 'discharged' @($row['obligations'] | Where-Object { $_['id'] -eq 'elevation' })[0]['status'] 'the rule and the units are gone'
        Assert-Equal '' (@($row['update']['debt'] | ForEach-Object { $_['obligation'] }) -join ',')
        Assert-Equal 'open' (Get-TestGateState -Fixture $fixture)
    }

    It 'ends the units and removes the sudo rule even when the gate cannot be opened' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestSudoStub -Fixture $fixture
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone
        # A gate another update holds is never opened under this one.
        $other = New-YurunaHostOperationRequestId
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $other -OwnerPid $gone)
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'gate-not-opened' $run.Output
        $calls = Get-TestSudoCall -Stub $sudo
        Assert-Equal 1 @($calls | Where-Object { $_ -ceq 'closed|-n systemctl stop yuruna-host-update-install-1.service' }).Count ($calls -join "`n")
        Assert-Equal 1 @($calls | Where-Object { $_ -ceq 'closed|-n rm -f /etc/sudoers.d/yuruna-host-update' }).Count ($calls -join "`n")
        Assert-Equal 'closed' (Get-TestGateState -Fixture $fixture)
        Assert-Equal 'running' (Get-TestRow -RequestId $id)['state'] 'a refused release writes no verdict'
    }

    It 'removes the sudo rule when a unit does not stop, and leaves the elevation as debt' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestSudoStub -Fixture $fixture -UnitStopExit 1
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone)
        $run = Invoke-EntryProcess -Fixture $fixture -Argument @('-Release', $id)
        Assert-Equal 0 $run.ExitCode $run.Output
        $calls = Get-TestSudoCall -Stub $sudo
        Assert-Equal 1 @($calls | Where-Object { $_ -ceq 'closed|-n systemctl stop yuruna-host-update-install-1.service' }).Count ($calls -join "`n")
        Assert-Equal 1 @($calls | Where-Object { $_ -ceq 'closed|-n rm -f /etc/sudoers.d/yuruna-host-update' }).Count 'the rule goes although the unit did not stop'
        Assert-Match '\belevation\b' $run.Output 'the debt is reported'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'released' $row['update']['verdict']
        Assert-Equal 'elevation' (@($row['update']['debt'] | ForEach-Object { $_['obligation'] }) -join ',')
        Assert-Equal 'open' (Get-TestGateState -Fixture $fixture)
    }

    # The host type comes from the update's row, so these run the macOS
    # release on any host. The process table and the process ends are
    # stand-ins, so no process of this host is ever read or signaled, and
    # sudo is a stand-in.
    It 'on macOS ends the update''s installer, then removes the rule with the one rm the entry allows, before it opens the gate' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestMacSudoStub -Fixture $fixture
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone -HostType 'host.macos.utm'
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone) 'the fixture gate is closed under the update'
        $seam = New-TestMacProcessSeam -Fixture $fixture -RequestId $id
        $decoy = Start-TestEnableDecoy -Fixture $fixture
        try {
            Assert-True (Test-TestEnableDecoyAlive -Decoy $decoy) 'fixture sanity: the decoy runs'
            $run = Invoke-TestMacRelease -Fixture $fixture -Seam $seam -RequestId $id
            Assert-Equal 0 $run.ExitCode $run.Output
            Assert-True (Test-TestEnableDecoyAlive -Decoy $decoy) 'a release in this suite never reaches a process outside its own table'
            Assert-Equal "table`nstop $($seam.InstallerPid)`nstop $($seam.ChildPid)" ((Get-TestMacProcessCall -Seam $seam) -join "`n") `
                'the table is read once, then the installer of the update and its child are ended'
            Assert-Equal 'closed|-n /bin/rm -f /etc/sudoers.d/yuruna-host-update|installer=gone' ((Get-TestSudoCall -Stub $sudo) -join "`n") `
                'one elevated call, the rm the entry allows, after the installer ended and while the gate was still closed; no systemctl'
            $row = Get-TestRow -RequestId $id
            Assert-Equal 'released' $row['update']['verdict']
            Assert-Equal 'discharged' @($row['obligations'] | Where-Object { $_['id'] -eq 'elevation' })[0]['status'] 'the installer and the rule are gone'
            Assert-Equal '' (@($row['update']['debt'] | ForEach-Object { $_['obligation'] }) -join ',')
            Assert-Equal 'open' (Get-TestGateState -Fixture $fixture)
        } finally { Stop-TestEnableDecoy -Decoy $decoy }
    }

    It 'on macOS leaves the elevation as debt when the rule cannot be removed, and still opens the gate' {
        $fixture = New-EntryEnvironment
        $sudo = New-TestMacSudoStub -Fixture $fixture -RuleExit 1
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone -HostType 'host.macos.utm'
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone)
        $seam = New-TestMacProcessSeam -Fixture $fixture
        $run = Invoke-TestMacRelease -Fixture $fixture -Seam $seam -RequestId $id
        Assert-Equal 0 $run.ExitCode $run.Output
        Assert-Equal 'table' ((Get-TestMacProcessCall -Seam $seam) -join "`n") 'the stand-in table was read and nothing was ended'
        Assert-Equal 'closed|-n /bin/rm -f /etc/sudoers.d/yuruna-host-update|installer=none' ((Get-TestSudoCall -Stub $sudo) -join "`n") 'no installer ran, the rm was tried once'
        Assert-Match '\belevation\b' $run.Output 'the debt is reported'
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'released' $row['update']['verdict']
        Assert-Equal 'elevation' (@($row['update']['debt'] | ForEach-Object { $_['obligation'] }) -join ',')
        Assert-Equal 'open' (Get-TestGateState -Fixture $fixture)
    }

    It 'on macOS ends only the Enable run of <Case>, and leaves those of other checkouts running' -ForEach @(
        @{ Case = 'the checkout the controller ran the update from'; Names = 'controller'; Expected = 2147470011 }
        @{ Case = 'the checkout the runner was started from'; Names = 'runner'; Expected = 2147470012 }
        @{ Case = 'the command''s own checkout when nothing names one'; Names = 'none'; Expected = 2147470013 }
    ) {
        $fixture = New-EntryEnvironment
        $null = New-TestMacSudoStub -Fixture $fixture
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone -HostType 'host.macos.utm'
        Assert-Equal 'True|closed' (Close-TestGate -Fixture $fixture -RequestId $id -OwnerPid $gone)
        if ($Names -eq 'controller') {
            $controllerRoot = Get-HostUpdateControllerRoot
            [IO.File]::WriteAllText((Join-Path $controllerRoot 'current'), "current=$($script:Snapshot)`nprevious=`ncheckout=/Users/test/git/yuruna-a`n")
        }
        if ($Names -eq 'runner') {
            $written = Invoke-GateCommand -Fixture $fixture -Body @"
`$write = Write-YurunaRunnerLaunchRecord -ScriptPath '$($script:RepoRoot)/test/Start-TestRunner.ps1' -BoundParameters @{} -ResolvedConfigPath '$($fixture.Work)/test.config.yml' ``
    -RuntimeDir `$runtime -RepoRoot '/Users/test/git/yuruna-b' -WorkingDirectory '$($fixture.Work)' -ForwardEnvironment @{} -AllowedEnvironmentName @() -Confirm:`$false
'GATE:' + [string]`$write.Reason
"@
            Assert-Equal 'written' $written 'fixture sanity: the launch record names the runner''s checkout'
        }
        $enable = [ordered]@{
            2147470011 = '/Users/test/git/yuruna-a/test/lab/Enable-TestAutomation.ps1'
            2147470012 = '/Users/test/git/yuruna-b/host/macos.utm/Enable-TestAutomation.ps1'
            2147470013 = "$($script:RepoRoot)/test/lab/Enable-TestAutomation.ps1"
            2147470014 = '/Users/test/git/other/test/lab/Enable-TestAutomation.ps1'
        }
        $seam = New-TestMacProcessSeam -Fixture $fixture -RequestId $id -Enable $enable
        $run = Invoke-TestMacRelease -Fixture $fixture -Seam $seam -RequestId $id
        Assert-Equal 0 $run.ExitCode $run.Output
        $stops = @(Get-TestMacProcessCall -Seam $seam | Where-Object { $_ -like 'stop *' } | Sort-Object)
        Assert-Equal ((@("stop $($seam.InstallerPid)", "stop $($seam.ChildPid)", "stop $Expected") | Sort-Object) -join ',') ($stops -join ',') `
            'the update''s installer and the one Enable of the checkout it names are ended; no other Enable is'
        Assert-Equal 'discharged' @((Get-TestRow -RequestId $id)['obligations'] | Where-Object { $_['id'] -eq 'elevation' })[0]['status']
    }
}

# On Windows HOME does not move $HOME, so the child sets $HOME itself before
# it runs the command, and stops unless the modules then resolve the scratch
# home: the case never reads or writes the operator's private root. The shim
# result it looks for is under %ProgramData%; the case writes none.
Describe 'the host command on Windows' -Skip:(-not $IsWindows) {

    It 'refuses release while the PowerShell upgrade the shim runs may still be at work, and opens no gate' {
        $fixture = New-EntryEnvironment
        $gone = 2147480000
        $id = Add-TestElevatedClaim -Fixture $fixture -ControllerPid $gone -Obligation @('gate', 'runner', 'listener')
        $started = Set-HostUpdatePhase -RequestId $id -ControllerPid $gone -Phase upgrade_pwsh -State started -Confirm:$false
        Assert-True $started.Written $started.Reason
        $command = @"
Set-Variable -Name HOME -Value '$($fixture.Home)' -Scope Global -Force
Import-Module '$($script:RepoRoot)/automation/Yuruna.Common.psm1' -Global -Force -DisableNameChecking 3>`$null
if ((& (Get-Module Yuruna.Common) { `$HOME }) -cne '$($fixture.Home)') { 'HOME-NOT-REDIRECTED'; exit 3 }
& '$($script:Entry)' -Release '$id'
exit `$LASTEXITCODE
"@
        $run = Invoke-EntryProcess -Fixture $fixture -Command $command
        Assert-Equal 1 $run.ExitCode $run.Output
        Assert-Match 'pwsh-upgrade-running' $run.Output
        $row = Get-TestRow -RequestId $id
        Assert-Equal 'running' $row['state']
        Assert-Null $row['update']['verdict']
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'runner-gate.record')) 'the refusal comes before any gate write'
    }
}

Describe 'the capability the listener and the command read' -Skip:$IsWindows {

    It 'reads <Case>' -ForEach @(
        @{ Case = 'idle with no journal'; Seed = 'none'; Expected = 'idle' }
        @{ Case = 'active for a queued update'; Seed = 'queued'; Expected = 'active' }
        @{ Case = 'active for a claimed update'; Seed = 'claimed'; Expected = 'active' }
        @{ Case = 'recovering for a recovery-pending update'; Seed = 'recovering'; Expected = 'recovering' }
    ) {
        $fixture = New-EntryEnvironment
        if ($Seed -eq 'queued') { $null = Add-TestUpdate -Fixture $fixture }
        if ($Seed -in @('claimed', 'recovering')) {
            $id = Add-TestClaim -Fixture $fixture -ControllerPid $PID -StartTimeUnixMs (Get-OwnStart)
            if ($Seed -eq 'recovering') {
                $null = Set-HostUpdateRecovering -RequestId $id -ControllerPid $PID -OperatorAction repair_checkout -Reason runner_start_failed -NextUnixMs 1 -Confirm:$false
            }
        }
        $capability = Get-HostUpdateCapability -RepoRoot $script:RepoRoot -RuntimeDir $fixture.Runtime
        Assert-Equal $Expected $capability.UpdateState
        Assert-Equal ([int][IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/host-update.protocol-version'))) $capability.Protocol
        $expectedLock = if ($Seed -eq 'none') { 'absent' } else { 'absent', 'free' }
        Assert-True ($capability.LockState -in $expectedLock) "lock $($capability.LockState)"
    }

    It 'reads the lock as held only while a controller holds it' {
        $fixture = New-EntryEnvironment
        $lock = Enter-TestControllerLock
        try {
            $null = $fixture
            Assert-Equal 'held' (& $script:Pwsh -NoProfile -NonInteractive -Command "Import-Module '$($script:RepoRoot)/test/modules/Test.HostOperationJournal.psm1' -DisableNameChecking; & (Get-Module Test.HostOperationJournal) { param(`$h) `$script:HostOperationHomePath = `$h } '$($fixture.Home)'; Get-HostUpdateControllerLockState")
        } finally { Exit-TestLock -Lock $lock }
        Assert-Equal 'free' (Get-HostUpdateControllerLockState)
    }

    It 'takes the controller state only while its heartbeat is fresh' {
        $fixture = New-EntryEnvironment
        $statePath = Join-Path $fixture.Runtime 'host-controller.state.json'
        $now = [DateTimeOffset]::new(2026, 11, 19, 12, 0, 0, [TimeSpan]::Zero)
        $clock = { $now }.GetNewClosure()
        foreach ($case in @(@{ Age = 5; Fresh = $true }, @{ Age = 30; Fresh = $true }, @{ Age = 31; Fresh = $false })) {
            $state = [ordered]@{ schemaVersion = 1; heartbeatUtc = $now.AddSeconds(-$case.Age).UtcDateTime.ToString('o'); sessionUsable = $true; scopes = 'restart' }
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress))
            $capability = Get-HostUpdateCapability -RepoRoot $script:RepoRoot -RuntimeDir $fixture.Runtime -UtcNow $clock
            Assert-Equal $case.Fresh ($null -ne $capability.ControllerState) "a heartbeat $($case.Age) s old"
        }
        foreach ($text in @('not json', '{"heartbeatUtc":"yesterday"}', '[]', '')) {
            [IO.File]::WriteAllText($statePath, $text)
            Assert-Null (Get-HostUpdateCapability -RepoRoot $script:RepoRoot -RuntimeDir $fixture.Runtime -UtcNow $clock).ControllerState "'$text' counts as absent"
        }
        Remove-Item -LiteralPath $statePath
        Assert-Null (Get-HostUpdateCapability -RepoRoot $script:RepoRoot -RuntimeDir $fixture.Runtime).ControllerState
    }

    It 'reads an unreadable journal as unknown' {
        $fixture = New-EntryEnvironment
        $null = Add-TestUpdate -Fixture $fixture
        foreach ($leaf in @('host-operation.journal', 'host-operation.journal.prev')) { [IO.File]::WriteAllText((Join-Path $fixture.Root $leaf), 'not a record') }
        $capability = Get-HostUpdateCapability -RepoRoot $script:RepoRoot -RuntimeDir $fixture.Runtime
        Assert-Equal 'unknown' $capability.UpdateState
        Assert-True ($capability.JournalStatus -notin @('ok', 'absent', 'recovered-previous')) "journal $($capability.JournalStatus)"
    }
}
