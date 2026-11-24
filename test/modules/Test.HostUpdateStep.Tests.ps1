<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42868239-781f-4ddc-aaee-46ec6e6ae1bc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update step console tmux pester
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
    The step children of a host update: the prologue every step shares, the
    preflight refusals (on macOS the session and the published full scope),
    the runner stop without the quiescence refusal, the source update a
    follower holds, the install and enable phases (KVM's unit, macOS's child
    work, Windows' copy), the listener start, the runner start that is safe
    to repeat, and the runner's console in tmux with its fallback.
.DESCRIPTION
    A step runs where the runner and the listener are stopped and started, so
    a rule it gets wrong costs the host its runner. The steps run in this
    process against a scratch private root (the journal module's home seam)
    and, for the entry script and the source update, as spawned pwsh processes
    with a scratch HOME and nothing else of this session's environment. The
    runner, its processes and tmux are stand-ins: disposable processes this
    suite starts and ends, and a tmux script on a private PATH that records
    its arguments and answers per scenario. No runner, listener, multiplexer
    or real private root is touched.
#>

# The steps publish the host identity on $global:__YurunaHostId, the channel
# the entry points use, so the suite reads it there and restores it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The host identity channel under test is a global the steps set; the suite saves and restores it.')]
param()

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The private state root and the runner gate resolve under $HOME; a scratch
    # home keeps this suite and every process it starts off the operator's own.
    $script:TestHome = Enter-YurunaTestHome
    Get-Module Test.HostUpdateStep, Test.HostUpdate, Test.HostRepair, Test.HostOperationJournal | Remove-Module -Force -ErrorAction SilentlyContinue
    # One instance of each primitive, shared by this suite and the module
    # under test: a gate or a journal row the suite reads must be the module's.
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    foreach ($name in @('Test.StateFile', 'Test.SingleFlightLock', 'Test.CriticalRecord', 'Test.InnerSpawn', 'Test.SingleInstance', 'Test.DiagnosticPreservation',
            'Test.YurunaDir', 'Test.Config', 'Test.RunnerElevation', 'Test.HostOperationJournal', 'Test.HostRepair', 'Test.HostUpdate', 'Test.HostUpdateStep')) {
        Import-Module (Join-Path $here "$name.psm1") -Force -Global -DisableNameChecking
    }
    $script:BypassRoot = Join-Path $HOME '.yuruna/host-repair'
    # The root a call that bypassed its seam would reach under the scratch
    # home; what the steps could write is compared, and every name.
    $script:BypassRootListing = {
        if (-not (Test-Path -LiteralPath $script:BypassRoot)) { return '<absent>' }
        @(Get-ChildItem -LiteralPath $script:BypassRoot -Force | Sort-Object Name | ForEach-Object {
                if ($_.Name -match '^(host-controller|host-repair\.|runner-gate|runner-launch|runner-handoff|work)') { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" } else { $_.Name }
            }) -join ';'
    }
    $script:BypassRootBefore = & $script:BypassRootListing
    $script:SavedEnvironment = Save-YurunaTestEnvironment -All
    $script:SavedGlobal = Save-YurunaTestGlobal -Name @('__YurunaHostId')
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'hu-step'
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:StandInPidFiles = [System.Collections.Generic.List[string]]::new()
    $script:Pwsh = [Environment]::ProcessPath
    # Mock bodies read their state from this scope: a closure would not see
    # the parameters Pester binds for the call.
    $script:RealPrivateRoot = (Get-Module Test.HostOperationJournal).ExportedFunctions['Get-HostOperationPrivateRoot']
    $script:MockSeen = @{}

    # Admission reads the runner gate by name and with no private root; the
    # suite's reader answers from the scratch root, the modules under test
    # keep their own import of the real reader.
    $script:RealGateReader = (Get-Module Test.SingleInstance).ExportedFunctions['Get-YurunaRunnerGateState']
    $realReader = $script:RealGateReader
    $holder = @{}
    $script:GateHolder = $holder
    ${function:global:Get-YurunaRunnerGateState} = {
        param([string]$RuntimeDir, [string]$TokenId, [string]$PrivateRoot)
        $null = $TokenId
        $root = if ($PrivateRoot) { $PrivateRoot } else { $holder.Root }
        & $realReader -RuntimeDir $RuntimeDir -PrivateRoot $root
    }.GetNewClosure()

    function New-StepFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch home, runtime, checkout and request.')]
        param([string]$ExpectCommit, [string]$Checkout, [string]$Scope = 'restart', [string]$HostType = 'host.ubuntu.kvm')
        $dir = Join-Path $script:ScratchBase ('h-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $runtime = Join-Path $dir 'runtime'
        if (-not $Checkout) {
            $Checkout = Join-Path $dir 'checkout'
            $null = New-Item -ItemType Directory -Path (Join-Path $Checkout 'test/modules') -Force
        }
        $null = New-Item -ItemType Directory -Path $runtime -Force
        [System.IO.File]::WriteAllText((Join-Path $runtime 'host.uuid'), '42c0ffee-0000-4000-8000-000000000001')
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $dir
        $privateRoot = (Get-HostOperationPrivateRoot).Path
        $script:GateHolder.Root = $privateRoot
        $controllerRoot = Get-HostUpdateControllerRoot
        $requestId = New-YurunaHostOperationRequestId
        $admission = @{ RequestId = $requestId; Channel = 'local'; Scope = $Scope; Drain = 'after-cycle'; DrainSeconds = 7200; RuntimeDir = $runtime; HostType = $HostType; Confirm = $false }
        if ($ExpectCommit) { $admission.ExpectCommit = $ExpectCommit }
        $admitted = Request-HostUpdateAdmission @admission
        Assert-True ($admitted.Decision -eq 'queued') "fixture sanity: admission queues the update ($($admitted.Decision) $($admitted.Reason))"
        $work = New-HostUpdatePrivateDirectory -Parent (New-HostUpdatePrivateDirectory -Parent $controllerRoot -Name 'work' -Confirm:$false) -Name $requestId -Confirm:$false
        [pscustomobject]@{
            Home = $dir; Runtime = $runtime; Checkout = $Checkout; PrivateRoot = $privateRoot; ControllerRoot = $controllerRoot
            RequestId = $requestId; Work = $work
        }
    }

    function Enter-TestClaim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: claims a scratch row for this process, as a controller does.')]
        param([Parameter(Mandatory)]$Fixture)
        $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
        try {
            $start = [long][DateTimeOffset]::new([System.Diagnostics.Process]::GetCurrentProcess().StartTime).ToUnixTimeMilliseconds()
            $claim = Confirm-HostUpdateClaim -RequestId $Fixture.RequestId -LifetimeLock $lock -ControllerPid $PID -ControllerStartTimeUnixMs $start `
                -Snapshot '0123456789abcdef' -RepoRoot $Fixture.Checkout -Mode claim -Confirm:$false
            Assert-True $claim.Accepted "fixture sanity: the claim is accepted ($($claim.Reason))"
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    function Invoke-TestStep {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Step, [int]$Attempt = 1, [int]$ControllerPid = 0, [string]$RuntimeDir)
        $env:YURUNA_RUNTIME_DIR = if ($PSBoundParameters.ContainsKey('RuntimeDir')) { $RuntimeDir } else { $Fixture.Runtime }
        $resultPath = Join-Path $Fixture.Work "$Step.$Attempt.result.json"
        $call = @{ Step = $Step; RequestId = $Fixture.RequestId; Attempt = $Attempt; ResultPath = $resultPath; RepoRoot = $Fixture.Checkout }
        if ($ControllerPid -gt 0) { $call.ControllerPid = $ControllerPid }
        $returned = Invoke-HostUpdateStep @call
        $file = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        [pscustomobject]@{ Returned = $returned; File = $file; Exit = (Get-HostUpdateStepExitCode -Result $returned) }
    }

    function Get-TreeListing {
        param([Parameter(Mandatory)][string]$Path)
        @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) -join ';'
    }

    function Use-VerifiedHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a scoped mock.')]
        param()
        # A scratch HOME is never the account's home; the home check itself
        # is the repair's and keeps its own suite.
        Mock Get-HostOperationPrivateRoot -ModuleName Test.HostUpdateStep {
            $call = @{}
            foreach ($key in $PesterBoundParameters.Keys) { if ($key -ne 'VerifyHome') { $call[$key] = $PesterBoundParameters[$key] } }
            $answer = & $script:RealPrivateRoot @call
            if ($PesterBoundParameters.ContainsKey('VerifyHome')) { $answer.HomeVerified = 'verified' }
            $answer
        }
    }

    function Set-TestLaunchRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a scoped mock.')]
        param([bool]$Found = $true, [bool]$Valid = $true, [bool]$CleanExit = $false, [hashtable]$Parameters = @{}, [hashtable]$Environment = @{})
        $record = [pscustomobject]@{
            Found = $Found; Valid = $Valid; Reason = $(if ($Valid) { 'ok' } else { 'unsupported-version' }); Path = $null
            Record = @{ cleanExit = $CleanExit; parameters = $Parameters; environment = $Environment }
        }
        $script:LaunchRecordAnswer = $record
        Mock Read-YurunaRunnerLaunchRecord -ModuleName Test.HostUpdateStep { $script:LaunchRecordAnswer }
    }

    function Start-StandInProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a disposable stand-in process the suite ends itself.')]
        param([Parameter(Mandatory)][string]$ScriptPath, [string]$Body = 'while true; do sleep 1; done')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $ScriptPath) -Force
        [System.IO.File]::WriteAllText($ScriptPath, "$Body`n")
        $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/bash')
        $psi.ArgumentList.Add($ScriptPath)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Spawned.Add($process)
        $process
    }

    function Write-TestRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a pid record and its start sidecar in a scratch runtime.')]
        param([Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Stem, [Parameter(Mandatory)][System.Diagnostics.Process]$Process)
        $start = (Get-Process -Id $Process.Id).StartTime.ToUniversalTime().ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $Runtime "$Stem.start"), $start)
        [System.IO.File]::WriteAllText((Join-Path $Runtime "$Stem.pid"), "$($Process.Id)")
    }

    function Wait-TestCondition {
        param([Parameter(Mandatory)][scriptblock]$Condition, [int]$TimeoutMilliseconds = 20000)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return [bool](& $Condition)
    }

    function Test-ProcessGone {
        param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
        $Process.Refresh()
        return $Process.HasExited
    }

    function Start-TestStepProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a step child of this suite with a scratch HOME and nothing else of this session.')]
        param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string[]]$ArgumentList, [Parameter(Mandatory)][string]$HomePath, [string]$RuntimeDir)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($item in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $ArgumentList) { $psi.ArgumentList.Add($item) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment.Clear()
        $psi.Environment['HOME'] = $HomePath
        $psi.Environment['PATH'] = [string]$script:SavedEnvironment['PATH']
        $psi.Environment['TMPDIR'] = [System.IO.Path]::GetTempPath()
        $psi.Environment['NO_COLOR'] = '1'
        $psi.Environment['DOTNET_EnableDiagnostics'] = '0'
        if ($RuntimeDir) { $psi.Environment['YURUNA_RUNTIME_DIR'] = $RuntimeDir }
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Spawned.Add($process)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(240000)) { $process.Kill($true); throw 'the step child did not end inside four minutes' }
        $process.WaitForExit()
        [pscustomobject]@{ Exit = $process.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result }
    }

    function New-StandInTmux {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in tmux on a private PATH.')]
        param([Parameter(Mandatory)][string]$Scenario)
        $dir = Join-Path $script:ScratchBase ('tmux-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $body = @'
#!/bin/bash
dir="$YRN_TMUX_STANDIN"
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$dir/argv.log"
scenario=$(cat "$dir/scenario")
args=("$@"); sub=""; i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in -S|-f) i=$((i+2));; *) sub="${args[$i]}"; i=$((i+1)); break;; esac
done
case "$sub" in
new-session)
  case "$scenario" in
  created)
    sleep 300 </dev/null >/dev/null 2>&1 &
    echo $! >> "$dir/pids"; echo $!; exit 0;;
  run)
    while [ $i -lt ${#args[@]} ]; do
      if [ "${args[$i]}" = "-c" ]; then wd="${args[$((i+1))]}"; i=$((i+2)); break; fi
      i=$((i+1))
    done
    ( cd "$wd" && exec "${args[@]:$i}" ) </dev/null >"$dir/pane.out" 2>&1 &
    echo $! >> "$dir/pids"; echo $!; exit 0;;
  *) echo "create failed" >&2; exit 1;;
  esac;;
has-session)
  case "$scenario" in
  none) echo "no server running on /tmp/x/runner-console.sock" >&2; exit 1;;
  exists|created|run) exit 0;;
  odd) echo "lost server" >&2; exit 1;;
  *) echo "protocol version mismatch" >&2; exit 2;;
  esac;;
list-panes)
  sleep 300 </dev/null >/dev/null 2>&1 &
  echo $! >> "$dir/pids"; echo $!; exit 0;;
pipe-pane) exit 0;;
esac
exit 0
'@
        [System.IO.File]::WriteAllText((Join-Path $dir 'tmux'), $body.Replace("`r`n", "`n"))
        & chmod +x (Join-Path $dir 'tmux')
        [System.IO.File]::WriteAllText((Join-Path $dir 'scenario'), $Scenario)
        $script:StandInPidFiles.Add((Join-Path $dir 'pids'))
        $env:YRN_TMUX_STANDIN = $dir
        $env:PATH = "$dir$([System.IO.Path]::PathSeparator)$($script:SavedEnvironment['PATH'])"
        $dir
    }

    function Get-StandInCall {
        # The calls the stand-in tmux recorded, one string[] per call, in a
        # list so a single call is not unrolled into its arguments.
        param([Parameter(Mandatory)][string]$Dir)
        $calls = [System.Collections.Generic.List[object]]::new()
        $log = Join-Path $Dir 'argv.log'
        if (Test-Path -LiteralPath $log) {
            foreach ($line in [System.IO.File]::ReadAllLines($log)) { $calls.Add([string[]]@($line.TrimEnd([char]31).Split([char]31))) }
        }
        return , $calls
    }

    function Get-StandInSubcommandList {
        param([Parameter(Mandatory)][string]$Dir)
        $calls = Get-StandInCall -Dir $Dir
        return (@($calls | ForEach-Object { Get-StandInSubcommand -Call $_ }) -join ',')
    }

    function Get-StandInSubcommand {
        param([Parameter(Mandatory)][string[]]$Call)
        for ($i = 0; $i -lt $Call.Count; $i++) {
            if ($Call[$i] -in @('-S', '-f')) { $i++; continue }
            return $Call[$i]
        }
        return ''
    }

    function Stop-StandInSpawned {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: ends the processes the stand-in tmux started for this suite.')]
        param()
        foreach ($file in $script:StandInPidFiles) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                $value = 0
                if ([int]::TryParse($line.Trim(), [ref]$value) -and $value -gt 0) {
                    try { (Get-Process -Id $value -ErrorAction Stop).Kill($true) } catch { $null = $_ }
                }
            }
        }
    }

    function New-StandInRunnerRepo {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a scratch checkout whose runner script has the real parameters.')]
        param([Parameter(Mandatory)][string]$Body)
        $repo = Join-Path $script:ScratchBase ('repo-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'test') -Force
        $real = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1')
        [System.IO.File]::WriteAllText((Join-Path $repo 'test/Start-TestRunner.ps1'), "#requires -version 7`n" + $real.ParamBlock.Extent.Text + "`n" + $Body + "`n")
        [System.IO.File]::WriteAllText((Join-Path $repo 'runner.config.yml'), "x: 1`n")
        $repo
    }
}

AfterAll {
    # The listing is read while $HOME is still the scratch home, and the home
    # is left even when a restore or the comparison throws.
    try {
        foreach ($process in $script:Spawned) {
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
        }
        Stop-StandInSpawned
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers
        Restore-YurunaTestGlobal -Saved $script:SavedGlobal
        & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
        Remove-Item -LiteralPath Function:\Get-YurunaRunnerGateState -ErrorAction SilentlyContinue
        Assert-Equal -Expected $script:BypassRootBefore -Actual (& $script:BypassRootListing) "a call that bypassed its seam neither created nor changed the private root under the suite's home"
    } finally {
        Remove-YurunaTestTempDir -Path $script:ScratchBase
        Exit-YurunaTestHome $script:TestHome
    }
}

Describe 'the prologue and the preflight' {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'refuses before any change for <Case>' -ForEach @(
        @{ Case = 'a lock file system without exclusion'; Reason = 'lock_unqualified'; Action = 'act_at_host'; Setup = {
                param($F) $null = $F
                Use-VerifiedHome
                Mock Get-YurunaSingleFlightLockQualification -ModuleName Test.HostUpdateStep { [pscustomobject]@{ Qualified = $false; Reason = 'filesystem-unqualified' } }
            } }
        @{ Case = 'a home that is not the account''s'; Reason = 'home_unverified'; Action = 'act_at_host'; Setup = { param($F) $null = $F } }
        @{ Case = 'a held one-shot lease'; Reason = 'one_shot_active'; Action = 'end_one_shot'; Setup = {
                param($F)
                Use-VerifiedHome
                $holder = Start-StandInProcess -ScriptPath (Join-Path $F.Home 'oneshot.sh')
                Write-TestRecord -Runtime $F.Runtime -Stem 'oneshot' -Process $holder
            } }
        @{ Case = 'a VM kept for diagnosis'; Reason = 'diagnostic_hold'; Action = 'release_diagnostic_hold'; Setup = {
                param($F)
                Use-VerifiedHome
                [System.IO.File]::WriteAllText((Join-Path $F.Runtime 'diagnostic-preserve.json'), '{"schemaVersion":1,"vmName":"guest-a"}')
            } }
        @{ Case = 'a launch record that does not validate when a start is expected'; Reason = 'launch_record_invalid'; Action = 'start_runner'; Setup = {
                param($F) $null = $F
                Use-VerifiedHome
                Set-TestLaunchRecord -Valid $false -CleanExit $false
                Mock Test-RunnerElevationReady -ModuleName Test.HostUpdateStep { $true }
            } }
        @{ Case = 'a runner elevation that is not ready'; Reason = 'runner_elevation_missing'; Action = 'provision_elevation'; Setup = {
                param($F) $null = $F
                Use-VerifiedHome
                Set-TestLaunchRecord -CleanExit $false
                Mock Test-RunnerElevationReady -ModuleName Test.HostUpdateStep { $false }
            } }
    ) {
        $fixture = New-StepFixture
        & $Setup $fixture
        $before = Get-TreeListing -Path $fixture.Home
        $rowBefore = (Get-HostUpdateRequest -RequestId $fixture.RequestId) | ConvertTo-Json -Depth 12
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected $Action -Actual $run.File['operatorAction']
        Assert-Equal -Expected 1 -Actual $run.Exit
        # The result file and the mtime of the work folder that holds it are
        # the step's only output.
        $own = @((Join-Path $fixture.Work 'preflight.1.result.json'), $fixture.Work)
        $isOwn = { param($Line) @($own | Where-Object { $Line.StartsWith("$_|", [StringComparison]::Ordinal) }).Count -gt 0 }
        $after = (Get-TreeListing -Path $fixture.Home).Split(';') | Where-Object { -not (& $isOwn $_) }
        $expected = $before.Split(';') | Where-Object { $_ -and -not (& $isOwn $_) }
        Assert-Equal -Expected ($expected -join ';') -Actual (@($after | Where-Object { $_ }) -join ';') 'nothing but the result file changed'
        Assert-Equal -Expected $rowBefore -Actual ((Get-HostUpdateRequest -RequestId $fixture.RequestId) | ConvertTo-Json -Depth 12) 'the step never writes the journal'
    }

    It 'passes on a host that can take the update, with a start expected' {
        $fixture = New-StepFixture
        Use-VerifiedHome
        Set-TestLaunchRecord -CleanExit $false
        $script:MockSeen = @{ Count = 0 }
        Mock Test-RunnerElevationReady -ModuleName Test.HostUpdateStep { $script:MockSeen.Count++; $true }
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
        Assert-True ([bool]$run.File['detail']['startExpected']) 'an unclean last exit expects a start'
        Assert-Equal -Expected 1 -Actual $script:MockSeen.Count 'the elevation the resumed start needs is probed'
        Assert-Equal -Expected 0 -Actual $run.Exit
        Assert-Equal -Expected '42c0ffee-0000-4000-8000-000000000001' -Actual $global:__YurunaHostId 'the host identity is published as the runner publishes it'
    }

    It 'refuses a full scope <Case>' -ForEach @(
        @{ Case = 'on a host without the elevation the install needs'; Ready = $false; Outcome = 'failed' }
        @{ Case = 'never on a host that has it'; Ready = $true; Outcome = 'done' }
    ) {
        $fixture = New-StepFixture -Scope full
        Use-VerifiedHome
        Set-TestLaunchRecord -CleanExit $true
        $script:MockSeen = @{ Ready = $Ready }
        Mock Test-HostUpdateFullScopeReady -ModuleName Test.HostUpdateStep { $script:MockSeen.Ready }
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected $Outcome -Actual $run.File['outcome']
        if (-not $Ready) {
            Assert-Equal -Expected 'runner_elevation_missing' -Actual $run.File['reason'] 'a KVM request reads the elevation probe, on any host'
            Assert-Equal -Expected 'provision_elevation' -Actual $run.File['operatorAction']
        }
    }

    # The runner a macOS update starts inherits the controller's session; a
    # session that cannot start it must refuse here, before phase 2 drains
    # and phase 3 stops a runner that could not come back.
    It 'refuses session_unusable on macOS before any other runner check, and records the reading' -Skip:$IsWindows {
        $fixture = New-StepFixture -HostType 'host.macos.utm'
        Use-VerifiedHome
        Set-TestLaunchRecord -Valid $false -CleanExit $false
        Mock Get-HostUpdateMacSessionReading -ModuleName Test.HostUpdateStep {
            @{ SessionKind = 'Aqua'; Ssh = $false; Grants = [ordered]@{ ScreenRecording = 'denied'; Accessibility = 'granted' }; Usable = $false }
        }
        $before = Get-TreeListing -Path $fixture.Runtime
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected 'session_unusable' -Actual $run.File['reason'] 'the session is read before the launch record'
        Assert-Equal -Expected 'act_at_host' -Actual $run.File['operatorAction']
        Assert-Equal -Expected 'Aqua' -Actual $run.File['detail']['session']['kind']
        Assert-Equal -Expected 'denied' -Actual $run.File['detail']['session']['grants']['ScreenRecording']
        Assert-False ([bool]$run.File['detail']['session']['usable'])
        Assert-Equal -Expected $before -Actual (Get-TreeListing -Path $fixture.Runtime) 'nothing in the runtime changed'
    }

    It 'passes the session check on macOS when the reading is <Case>' -ForEach @(
        @{ Case = 'usable'; Throw = $false; Usable = $true; Detail = 'Aqua' }
        @{ Case = 'unavailable'; Throw = $true; Usable = $true; Detail = 'unread' }
    ) -Skip:$IsWindows {
        $fixture = New-StepFixture -HostType 'host.macos.utm'
        Use-VerifiedHome
        Set-TestLaunchRecord -CleanExit $true
        $script:MockSeen = @{ Throw = $Throw }
        Mock Get-HostUpdateMacSessionReading -ModuleName Test.HostUpdateStep {
            if ($script:MockSeen.Throw) { throw 'Get-MacSessionKind is not loaded' }
            @{ SessionKind = 'Aqua'; Ssh = $false; Grants = [ordered]@{ UtmAppData = 'unknown' }; Usable = $true }
        }
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
        $read = $run.File['detail']['session']
        Assert-Equal -Expected $Detail -Actual $(if ($read -is [System.Collections.IDictionary]) { $read['kind'] } else { $read })
    }

    It 'never reads the macOS session for a <HostType> request' -ForEach @(
        @{ HostType = 'host.ubuntu.kvm' }
        @{ HostType = 'host.windows.hyper-v' }
    ) {
        $fixture = New-StepFixture -HostType $HostType
        Use-VerifiedHome
        Set-TestLaunchRecord -CleanExit $true
        $script:MockSeen = @{ Count = 0 }
        Mock Get-HostUpdateMacSessionReading -ModuleName Test.HostUpdateStep { $script:MockSeen.Count++; @{ Usable = $false } }
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Count
        Assert-Null $run.File['detail']['session']
    }

    # The probe writes the temporary rule's own path, so a step child never
    # makes it on macOS: it reads what the controller published before the
    # claim, and runs no sudo.
    It 'reads the full scope on macOS from the controller''s published state (<Case>), without probing' -ForEach @(
        @{ Case = 'full listed'; State = '{"schemaVersion":1,"scopes":"restart,full"}'; Outcome = 'done' }
        @{ Case = 'restart only'; State = '{"schemaVersion":1,"scopes":"restart"}'; Outcome = 'failed' }
        @{ Case = 'a scope that only starts with full'; State = '{"schemaVersion":1,"scopes":"restart,fuller"}'; Outcome = 'failed' }
        @{ Case = 'no state'; State = $null; Outcome = 'failed' }
        @{ Case = 'an unreadable state'; State = '{"scopes":'; Outcome = 'failed' }
    ) -Skip:$IsWindows {
        $fixture = New-StepFixture -Scope full -HostType 'host.macos.utm'
        Use-VerifiedHome
        Set-TestLaunchRecord -CleanExit $true
        if ($null -ne $State) { [System.IO.File]::WriteAllText((Join-Path $fixture.Runtime 'host-controller.state.json'), $State) }
        $script:MockSeen = @{ Probe = 0; Native = 0 }
        Mock Get-HostUpdateMacSessionReading -ModuleName Test.HostUpdateStep { @{ SessionKind = 'Aqua'; Ssh = $false; Grants = @{}; Usable = $true } }
        Mock Test-HostUpdateFullScopeReady -ModuleName Test.HostUpdateStep { $script:MockSeen.Probe++; $true }
        Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdateStep { $script:MockSeen.Native++; @{ ExitCode = 0; TimedOut = $false } }
        Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdate { $script:MockSeen.Native++; @{ ExitCode = 0; TimedOut = $false } }
        $run = Invoke-TestStep -Fixture $fixture -Step preflight
        Assert-Equal -Expected $Outcome -Actual $run.File['outcome']
        if ($Outcome -eq 'failed') {
            Assert-Equal -Expected 'scope_unavailable' -Actual $run.File['reason']
            Assert-Equal -Expected 'provision_elevation' -Actual $run.File['operatorAction']
        }
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Probe 'the step child makes no elevation probe on macOS'
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Native 'and runs no native call for it'
    }

    It 'fails <Reason> from the entry script and writes the result it exits with' -ForEach @(
        @{ Reason = 'runtime_unresolved'; Break = 'runtime' }
        @{ Reason = 'host_identity_unresolved'; Break = 'uuid' }
    ) {
        $fixture = New-StepFixture
        $runtime = $fixture.Runtime
        if ($Break -eq 'runtime') { $runtime = Join-Path $fixture.Home 'no-such-runtime' }
        else { Remove-Item -LiteralPath (Join-Path $fixture.Runtime 'host.uuid') }
        $resultPath = Join-Path $fixture.Work 'preflight.1.result.json'
        $child = Start-TestStepProcess -ScriptPath (Join-Path $script:RepoRoot 'test/lab/Invoke-HostUpdateStep.ps1') -HomePath $fixture.Home -RuntimeDir $runtime `
            -ArgumentList @('-Step', 'preflight', '-RequestId', $fixture.RequestId, '-Attempt', '1', '-ResultPath', $resultPath, '-RepoRoot', $fixture.Checkout)
        Assert-Equal -Expected 1 -Actual $child.Exit -Because "stderr: $($child.StdErr)"
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'failed' -Actual $result['outcome']
        Assert-Equal -Expected $Reason -Actual $result['reason']
        Assert-Equal -Expected 1 -Actual ([int]$result['schemaVersion'])
        Assert-Equal -Expected $fixture.RequestId -Actual $result['requestId']
        if ($Break -eq 'uuid') { Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Runtime 'host.uuid')) 'a host identity is never minted' }
        else { Assert-False (Test-Path -LiteralPath $runtime) 'a runtime directory is never defaulted or created' }
    }

    It 'writes nothing for a result path outside the request''s work folder' {
        $fixture = New-StepFixture
        $env:YURUNA_RUNTIME_DIR = $fixture.Runtime
        $outside = Join-Path $fixture.Home 'elsewhere.json'
        $returned = Invoke-HostUpdateStep -Step preflight -RequestId $fixture.RequestId -Attempt 1 -ResultPath $outside -RepoRoot $fixture.Checkout 2>$null
        Assert-Null $returned
        Assert-False (Test-Path -LiteralPath $outside) 'no result is written where the controller does not read'
        Assert-Equal -Expected 1 -Actual (Get-HostUpdateStepExitCode -Result $returned)
    }
}

Describe 'the runner stop' -Skip:$IsWindows {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'stops owned runner processes without the quiescence refusal and returns them by role in reclaimed' {
        $fixture = New-StepFixture
        $pause = Join-Path $fixture.Runtime 'control.cycle-pause'
        [System.IO.File]::WriteAllText($pause, 'operator pause')
        $outer = Start-StandInProcess -ScriptPath (Join-Path $fixture.Checkout 'test/Start-TestRunner.ps1')
        # A busy inner: a new child every few hundred milliseconds, so two
        # snapshots never agree and the repair's reclaim would refuse.
        $inner = Start-StandInProcess -ScriptPath (Join-Path $fixture.Checkout 'test/modules/Invoke-TestRunnerInnerLoop.ps1') -Body 'while true; do sleep 0.2; done'
        Write-TestRecord -Runtime $fixture.Runtime -Stem 'runner' -Process $outer
        Write-TestRecord -Runtime $fixture.Runtime -Stem 'inner' -Process $inner
        $run = Invoke-TestStep -Fixture $fixture -Step stop_runner
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
        Assert-True (Wait-TestCondition { (Test-ProcessGone -Process $outer) -and (Test-ProcessGone -Process $inner) }) 'both stand-ins are stopped'
        Assert-Equal -Expected $outer.Id -Actual ([int]$run.File['reclaimed']['outer']['pid'])
        Assert-Equal -Expected $inner.Id -Actual ([int]$run.File['reclaimed']['inner']['pid'])
        Assert-Null $run.File['reclaimed']['cycle'] 'no cycle record, no cycle identity'
        Assert-NotNull $run.File['reclaimed']['inner']['startTimeUnixMs']
        Assert-True (@($run.File['detail']['stopped']).Count -ge 2) 'what was stopped is in the detail'
        Assert-Equal -Expected 'operator pause' -Actual ([System.IO.File]::ReadAllText($pause)) 'pauses are left as they are'
    }

    It 'fails runner_identity_unknown on an Unknown record and signals nothing' {
        $fixture = New-StepFixture
        $bystander = Start-StandInProcess -ScriptPath (Join-Path $fixture.Checkout 'test/Start-TestRunner.ps1')
        [System.IO.File]::WriteAllText((Join-Path $fixture.Runtime 'runner.pid'), 'not-a-pid')
        Write-TestRecord -Runtime $fixture.Runtime -Stem 'inner' -Process $bystander
        $run = Invoke-TestStep -Fixture $fixture -Step stop_runner
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected 'runner_identity_unknown' -Actual $run.File['reason']
        Assert-Equal -Expected 'stop_runner_by_hand' -Actual $run.File['operatorAction']
        Assert-False (Test-ProcessGone -Process $bystander) 'an unknown record stops the whole step before any signal'
    }

    It 'keeps a host update''s own command and steps out of the reclaim walk' {
        $repo = '/srv/checkout'
        $row = { param([int]$P, [int]$Parent, [string]$Line) [pscustomobject]@{ Pid = $P; ParentPid = $Parent; CommandLine = $Line; OwnerId = '1000'; StartTimeUnixMs = [long]1 } }
        $table = [pscustomobject]@{ Platform = 'Linux'; Complete = $true; Rows = @(
                (& $row 10 1 'pwsh -File /srv/checkout/test/Start-TestRunner.ps1')
                (& $row 11 1 'pwsh -NoLogo -File /srv/checkout/test/lab/Invoke-HostUpdateStep.ps1 -Step start_runner')
                (& $row 12 1 'pwsh -File /srv/checkout/test/lab/Invoke-HostUpdate.ps1 -Release x')
                (& $row 99 1 'pwsh worker')
            )
        }
        $set = Get-YurunaRunnerExclusionSet -ProcessTable $table -RepoRoot $repo -RuntimeDir '/srv/runtime' -WorkerPid 99 -CurrentOwnerId '1000'
        Assert-True (@($set.ExcludedPid) -contains 11) 'a step child is never signaled'
        Assert-True (@($set.ExcludedPid) -contains 12) 'the host command is never signaled'
        Assert-False (@($set.ExcludedPid) -contains 10) 'the runner stays a target'
        Assert-Equal -Expected 'host-update' -Actual (@($set.Evidence | Where-Object { $_.Pid -eq 11 })[0].Role)
    }
}

Describe 'the source update' -Skip:$IsWindows {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    BeforeAll {
        function New-TestCheckout {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a scratch origin with a newer commit and a checkout behind it.')]
            param([string]$Protocol = '1')
            $origin = New-YurunaTestGitRepository -Prefix 'hu-origin' -File @{ 'README.md' = "one`n"; 'test/host-update.protocol-version' = $Protocol }
            $first = ([string](Invoke-YurunaTestGit -Path $origin -Argument @('rev-parse', 'HEAD') | Select-Object -Last 1)).Trim()
            $checkout = Join-Path $script:ScratchBase ('co-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = Invoke-YurunaTestGit -Path $script:ScratchBase -Argument @('clone', '--quiet', $origin, $checkout)
            Set-YurunaTestGitIdentity -Path $checkout
            [System.IO.File]::WriteAllText((Join-Path $origin 'README.md'), "two`n")
            $null = Invoke-YurunaTestGit -Path $origin -Argument @('commit', '--quiet', '-am', 'newer')
            $null = Invoke-YurunaTestGit -Path $checkout -Argument @('fetch', '--quiet', 'origin')
            [pscustomobject]@{ Origin = $origin; Checkout = $checkout; First = $first }
        }
    }

    It 'leaves a follower''s checkout where it is when started from an empty environment' {
        $repo = New-TestCheckout
        $fixture = New-StepFixture -Checkout $repo.Checkout
        # The pool's ring names another host as its canary, and no aggregator
        # address is known: a follower holds and never installs the tip.
        [System.IO.File]::WriteAllText((Join-Path $fixture.Runtime 'pool.state.json'),
            '{"poolId":"pool-a","frameworkRing":{"canaryMembers":["42ffffff-0000-4000-8000-000000000009"],"requiredPasses":1}}')
        # From a staged snapshot, as a recovering update runs it: the step's
        # code is the snapshot's and the checkout is only -RepoRoot.
        $staged = New-HostUpdateSnapshot -SourceRoot $script:RepoRoot -ControllerRoot $fixture.ControllerRoot -Confirm:$false
        Assert-True ($staged.Reason -in @('staged', 'exists')) "the checkout stages a snapshot ($($staged.Reason) $($staged.Detail))"
        $step = Join-Path $fixture.ControllerRoot "versions/$($staged.Hash16)/test/lab/Invoke-HostUpdateStep.ps1"
        $resultPath = Join-Path $fixture.Work 'update_source.1.result.json'
        $child = Start-TestStepProcess -ScriptPath $step -HomePath $fixture.Home -RuntimeDir $fixture.Runtime `
            -ArgumentList @('-Step', 'update_source', '-RequestId', $fixture.RequestId, '-Attempt', '1', '-ResultPath', $resultPath, '-RepoRoot', $repo.Checkout)
        Assert-Equal -Expected 2 -Actual $child.Exit -Because "done with a remark; stderr: $($child.StdErr)"
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'done' -Actual $result['outcome']
        Assert-True (@($result['remarks']) -contains 'ring_held') "the hold is a remark ($(@($result['remarks']) -join ','))"
        Assert-Equal -Expected $repo.First -Actual ([string](Invoke-YurunaTestGit -Path $repo.Checkout -Argument @('rev-parse', 'HEAD') | Select-Object -Last 1)).Trim() 'HEAD did not move'
        Assert-Equal -Expected $repo.First -Actual $result['commit']['before']
        Assert-Equal -Expected $repo.First -Actual $result['commit']['after']
        $ring = Get-Content -LiteralPath (Join-Path $fixture.Runtime 'framework-ring.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'follower' -Actual $ring['role'] 'the ring read the runtime directory and the host identity the step set'
    }

    It 'skips with no_git_pull for a NoGitPull launch record and never pulls' {
        $fixture = New-StepFixture
        Set-TestLaunchRecord -Parameters @{ NoGitPull = $true }
        $pulls = @{ Count = 0 }
        ${function:global:Invoke-OuterGitPull} = { param([string]$RepoRoot, [string]$ConfigPath) $null = $RepoRoot, $ConfigPath; $pulls.Count++; $true }.GetNewClosure()
        try { $run = Invoke-TestStep -Fixture $fixture -Step update_source } finally { Remove-Item -LiteralPath Function:\Invoke-OuterGitPull -ErrorAction SilentlyContinue }
        Assert-Equal -Expected 'skipped' -Actual $run.File['outcome']
        Assert-Equal -Expected 'no_git_pull' -Actual (@($run.File['remarks']) -join ',')
        Assert-Equal -Expected 3 -Actual $run.Exit
        Assert-Equal -Expected 0 -Actual $pulls.Count
    }

    It 'fails <Reason> and reports the checkout''s protocol number' -ForEach @(
        @{ Reason = 'commit_mismatch'; Pulled = $true; Expect = 'deadbeef' }
        @{ Reason = 'pull_failed'; Pulled = $false; Expect = $null }
        @{ Reason = $null; Pulled = $true; Expect = 'first' }
    ) {
        $repo = New-TestCheckout -Protocol '7'
        $expect = if ($Expect -eq 'first') { $repo.First.Substring(0, 12) } else { $Expect }
        $fixture = New-StepFixture -Checkout $repo.Checkout -ExpectCommit $expect
        Set-TestLaunchRecord -Parameters @{ ConfigPath = (Join-Path $fixture.Home 'runner.config.yml') } -Environment @{ YURUNA_LOG_LEVEL = 'Verbose'; YURUNA_RUNTIME_DIR = '/elsewhere' }
        $seen = @{}
        $pulled = $Pulled
        ${function:global:Invoke-OuterGitPull} = {
            param([string]$RepoRoot, [string]$ConfigPath)
            $seen.RepoRoot = $RepoRoot; $seen.ConfigPath = $ConfigPath; $seen.Level = $env:YURUNA_LOG_LEVEL; $seen.Runtime = $env:YURUNA_RUNTIME_DIR; $seen.Config = $env:YURUNA_CONFIG_PATH
            $pulled
        }.GetNewClosure()
        try { $run = Invoke-TestStep -Fixture $fixture -Step update_source } finally { Remove-Item -LiteralPath Function:\Invoke-OuterGitPull -ErrorAction SilentlyContinue }
        Assert-Equal -Expected 7 -Actual ([int]$run.File['protocol']) 'the checkout''s protocol number'
        Assert-Equal -Expected $repo.Checkout -Actual $seen.RepoRoot
        Assert-Equal -Expected (Join-Path $fixture.Home 'runner.config.yml') -Actual $seen.ConfigPath 'the runner''s recorded configuration'
        Assert-Equal -Expected (Join-Path $fixture.Home 'runner.config.yml') -Actual $seen.Config 'children resolve the same configuration'
        Assert-Equal -Expected 'Verbose' -Actual $seen.Level 'the runner''s forwarded environment is restored'
        Assert-Equal -Expected $fixture.Runtime -Actual $seen.Runtime 'the runtime directory is the request''s, never the record''s copy'
        Assert-Equal -Expected $repo.First -Actual $run.File['commit']['before']
        if ($Reason) {
            Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
            Assert-Equal -Expected $Reason -Actual $run.File['reason']
            Assert-Equal -Expected 'repair_checkout' -Actual $run.File['operatorAction']
        } else {
            Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
            Assert-Equal -Expected 0 -Actual $run.Exit
        }
    }
}

Describe 'the listener start' {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'skips the listener when the launch record says NoStatusService' {
        $fixture = New-StepFixture
        Set-TestLaunchRecord -Parameters @{ NoStatusService = $true }
        Mock Read-TestConfig -ModuleName Test.HostUpdateStep { @{ statusService = @{ enabled = $true; port = 8123 } } }
        $script:MockSeen = @{ Count = 0 }
        Mock Start-HostOperationStatusService -ModuleName Test.HostUpdateStep { $script:MockSeen.Count++; [pscustomobject]@{ Outcome = 'started'; Reason = 'started' } }
        $run = Invoke-TestStep -Fixture $fixture -Step start_listener
        Assert-Equal -Expected 'skipped' -Actual $run.File['outcome']
        Assert-Equal -Expected 'listener_disabled' -Actual (@($run.File['remarks']) -join ',')
        Assert-Null $run.File['reason'] 'listener_disabled is a remark, not a reason'
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Count
    }

    It 'passes ReplaceWedged and the configured port, and fails on an <Outcome> listener' -ForEach @(
        @{ Outcome = 'started'; Expected = 'done' }
        @{ Outcome = 'existing-ready'; Expected = 'done' }
        @{ Outcome = 'existing-unresponsive'; Expected = 'failed' }
    ) {
        $fixture = New-StepFixture
        Set-TestLaunchRecord -Parameters @{ ConfigPath = '/srv/runner.config.yml' }
        $script:MockSeen = @{ Outcome = $Outcome; Listener = @{} }
        Mock Read-TestConfig -ModuleName Test.HostUpdateStep { $script:MockSeen.ConfigPath = $PesterBoundParameters['Path']; @{ statusService = @{ enabled = $true; port = 8123 } } }
        Mock Start-HostOperationStatusService -ModuleName Test.HostUpdateStep {
            foreach ($key in $PesterBoundParameters.Keys) { $script:MockSeen.Listener[$key] = $PesterBoundParameters[$key] }
            [pscustomobject]@{ Outcome = $script:MockSeen.Outcome; Reason = $script:MockSeen.Outcome }
        }
        $seen = $script:MockSeen.Listener
        $run = Invoke-TestStep -Fixture $fixture -Step start_listener
        Assert-Equal -Expected $Expected -Actual $run.File['outcome']
        Assert-Equal -Expected '/srv/runner.config.yml' -Actual $script:MockSeen.ConfigPath 'the runner''s recorded configuration decides'
        Assert-True ([bool]$seen['ReplaceWedged']) 'a host update replaces an owned, silent, wedged listener'
        Assert-Equal -Expected 8123 -Actual ([int]$seen['Port'])
        Assert-Equal -Expected $fixture.Runtime -Actual $seen['RuntimeDir']
        Assert-Equal -Expected $fixture.Work -Actual (Split-Path -Parent ([string]$seen['ResultPath'])) 'the listener result stays in the private work folder'
        Assert-Equal -Expected "listener_$Outcome" -Actual $run.File['detail']['listener']
    }
}

Describe 'the install and enable phases on KVM' -Skip:(-not $IsLinux) {
    BeforeAll {
        # Every sudo, systemctl, visudo and shell call of the phase, in both
        # modules, lands here: nothing reaches the host's sudo. A call whose
        # line matches a key of Exit answers that code, a key of StdOut that
        # text, and a pattern of TimedOut reports the call ended at its bound;
        # the bound each call was given is kept beside its line. The stand-in
        # unit of the installer writes the record an installer would.
        function Use-NativeStandIn {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: scoped mocks.')]
            param([hashtable]$Exit = @{}, [hashtable]$StdOut = @{}, [string[]]$TimedOut = @(), [System.Collections.IDictionary]$Record, [string]$StateHome)
            $script:MockSeen = @{
                Calls = [System.Collections.Generic.List[string]]::new(); Timeouts = [System.Collections.Generic.List[object]]::new()
                Exit = $Exit; StdOut = $StdOut; TimedOut = $TimedOut; Record = $Record; StateHome = $StateHome
            }
            $body = {
                $line = (@($PesterBoundParameters['FilePath']) + @($PesterBoundParameters['ArgumentList'])) -join ' '
                $script:MockSeen.Calls.Add($line)
                $script:MockSeen.Timeouts.Add($PesterBoundParameters['TimeoutSeconds'])
                if ($script:MockSeen.Record -and $line -match '--unit=yuruna-host-update-install-\d+ ') {
                    $dir = Join-Path $script:MockSeen.StateHome 'yuruna'
                    $null = New-Item -ItemType Directory -Path $dir -Force
                    [IO.File]::WriteAllText((Join-Path $dir 'install-result.json'), ($script:MockSeen.Record | ConvertTo-Json -Depth 4))
                }
                $code = 0
                foreach ($pattern in @($script:MockSeen.Exit.Keys)) { if ($line -like $pattern) { $code = [int]$script:MockSeen.Exit[$pattern] } }
                $text = ''
                foreach ($pattern in @($script:MockSeen.StdOut.Keys)) { if ($line -like $pattern) { $text = [string]$script:MockSeen.StdOut[$pattern] } }
                $late = @($script:MockSeen.TimedOut | Where-Object { $line -like $_ }).Count -gt 0
                @{ ExitCode = $(if ($late) { 124 } else { $code }); TimedOut = $late; StdOut = $text; StdErr = '' }
            }
            Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdate $body
            Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdateStep $body
        }
        function New-PrivilegedFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch checkout.')]
            param([switch]$Unmarked)
            $fixture = New-StepFixture
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Checkout 'install'), (Join-Path $fixture.Checkout 'test/lab') -Force
            $marker = if ($Unmarked) { '' } else { "YURUNA_UNATTENDED_PROTOCOL_VERSION=1`n" }
            [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'install/ubuntu.kvm.sh'), "#!/bin/bash`n$marker")
            [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'test/lab/Enable-TestAutomation.ps1'), 'exit 0')
            $env:XDG_STATE_HOME = Join-Path $fixture.Home 'state'
            $fixture
        }
        function New-InstallRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory record.')]
            param([Parameter(Mandatory)]$Fixture, [int]$Attempt = 1, [string]$Outcome = 'succeeded', [string]$Reason, [string[]]$Issues = @(), $PwshUpgrade = $null)
            [ordered]@{
                schema = 1; installer = 'ubuntu.kvm'; outcome = $Outcome; exitCode = $(if ($Outcome -eq 'failed') { 1 } else { 0 }); issues = $Issues
                requestId = $Fixture.RequestId; attempt = $Attempt; unattended = $true; reason = $(if ($Reason) { $Reason } else { $null })
                pwshUpgrade = $PwshUpgrade; restartRequired = $false
            }
        }
        $script:RuleWrite = 'sudo -n tee "$1" < "$2" > /dev/null'
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'refuses an installer that carries no unattended marker, before any sudo call' {
        $fixture = New-PrivilegedFixture -Unmarked
        Use-NativeStandIn
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected 'installer_unmarked' -Actual $run.File['reason']
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Calls.Count
    }

    It 'writes the rule after visudo, confirms it uncached, starts its timer, runs the installer in its unit and ends both' {
        $fixture = New-PrivilegedFixture
        Use-NativeStandIn -StateHome $env:XDG_STATE_HOME -Record (New-InstallRecord -Fixture $fixture -Outcome 'succeeded-with-issues' -Issues @('Below the tested baseline') `
                -PwshUpgrade ([ordered]@{ from = '7.7.0'; to = '7.7.1'; pending = $false }))
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 'install_issues' -Actual (@($run.File['remarks']) -join ',')
        Assert-True ([bool]$run.File['pwshChanged']) 'a PowerShell the installer moved in place is reported'
        $calls = $script:MockSeen.Calls
        $index = { param([string]$Pattern) for ($i = 0; $i -lt $calls.Count; $i++) { if ($calls[$i] -like $Pattern) { return $i } }; -1 }
        $visudo = & $index '*visudo -cf *'
        $tee = & $index "*$($script:RuleWrite)* /etc/sudoers.d/yuruna-host-update *"
        $confirm = & $index 'sudo -n -k true'
        $timer = & $index 'sudo -n systemd-run --unit=yuruna-host-update-expire --on-active=2520s *'
        $unit = & $index 'sudo -n systemd-run --unit=yuruna-host-update-install-1 *'
        $stop = & $index 'sudo -n systemctl stop yuruna-host-update-install-1'
        $remove = & $index 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update'
        Assert-True ($visudo -ge 0 -and $visudo -lt $tee) 'visudo checks the text before it is written'
        Assert-True ($tee -lt $confirm -and $confirm -lt $timer -and $timer -lt $unit) ('the order: ' + ($calls -join ' | '))
        Assert-True ($unit -lt $stop -and $stop -lt $remove) 'the unit ends and the rule goes after the work'
        Assert-True ($calls[$timer] -like '* /usr/bin/rm -f /etc/sudoers.d/yuruna-host-update') 'root removes the rule at the bound'
        $user = [Environment]::UserName
        Assert-Match -Pattern ([regex]::Escape("--uid=$user --wait --collect --quiet --property=StandardInput=null")) -Actual $calls[$unit]
        Assert-Match -Pattern ([regex]::Escape("--setenv YURUNA_DIR=$($fixture.Checkout)")) -Actual $calls[$unit]
        Assert-Match -Pattern ([regex]::Escape("--setenv YURUNA_RUNTIME_DIR=$($fixture.Runtime)")) -Actual $calls[$unit]
        Assert-Match -Pattern ([regex]::Escape("-- /bin/bash $(Join-Path $fixture.Checkout 'install/ubuntu.kvm.sh') --unattended --request-id $($fixture.RequestId) --attempt 1")) -Actual $calls[$unit]
        Assert-True ([bool]$run.File['detail']['ruleRemoved']) ''
    }

    It 'fails <Reason> and starts no unit when the rule <Case>' -ForEach @(
        @{ Case = 'is refused by visudo'; Exit = @{ '*visudo -cf *' = 1 }; Reason = 'elevation_rule_refused'; Rule = 'visudo-refused'; Removed = $false }
        @{ Case = 'is not confirmed'; Exit = @{ 'sudo -n -k true' = 1 }; Reason = 'elevation_rule_refused'; Rule = 'not-confirmed'; Removed = $true }
        @{ Case = 'gets no timer'; Exit = @{ 'sudo -n systemd-run --unit=yuruna-host-update-expire *' = 1 }; Reason = 'elevation_rule_refused'; Rule = 'timer-failed'; Removed = $true }
    ) {
        $fixture = New-PrivilegedFixture
        Use-NativeStandIn -Exit $Exit
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected $Rule -Actual $run.File['detail']['rule']
        Assert-Equal -Expected 0 -Actual @($script:MockSeen.Calls | Where-Object { $_ -like '*--unit=yuruna-host-update-install-*' }).Count 'the work is not started'
        Assert-Equal -Expected $Removed -Actual (@($script:MockSeen.Calls | Where-Object { $_ -eq 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update' }).Count -gt 0) 'a written rule is removed again'
    }

    It 'passes on the installer''s reason token and fails installer_failed without a record of this attempt' -ForEach @(
        @{ Record = 'runner_present'; Reason = 'runner_present'; Action = 'stop_runner_by_hand' }
        @{ Record = 'something_new'; Reason = 'installer_failed'; Action = 'read_remarks' }
        @{ Record = 'other-attempt'; Reason = 'installer_failed'; Action = 'read_remarks' }
    ) {
        $fixture = New-PrivilegedFixture
        $record = if ($Record -eq 'other-attempt') { New-InstallRecord -Fixture $fixture -Attempt 7 } else { New-InstallRecord -Fixture $fixture -Outcome 'failed' -Reason $Record }
        Use-NativeStandIn -StateHome $env:XDG_STATE_HOME -Record $record
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected $Action -Actual $run.File['operatorAction']
    }

    It 'ends the units of earlier attempts before it starts another' {
        $fixture = New-PrivilegedFixture
        $listed = "yuruna-host-update-install-1.service loaded active running /bin/bash`nyuruna-host-update-install-2.service loaded failed failed /bin/bash`n"
        Use-NativeStandIn -StateHome $env:XDG_STATE_HOME -Record (New-InstallRecord -Fixture $fixture -Attempt 3) -StdOut @{ 'sudo -n systemctl list-units *' = $listed }
        $run = Invoke-TestStep -Fixture $fixture -Step install -Attempt 3
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 'sudo -n systemctl list-units --all --plain --no-legend --no-pager yuruna-host-update-install-*.service yuruna-host-update-enable-*.service' `
            -Actual $script:MockSeen.Calls[0]
        Assert-Equal -Expected 'sudo -n systemctl stop yuruna-host-update-install-1.service' -Actual $script:MockSeen.Calls[1]
        Assert-Equal -Expected 'sudo -n systemctl stop yuruna-host-update-install-2.service' -Actual $script:MockSeen.Calls[2]
    }

    # Unit names carry phase and attempt only, so a unit an earlier update
    # left alive (its release kept the stop as debt) would otherwise run as
    # root beside the new installer, or hold the very name the new unit needs.
    It 'stops <Left>, left by another update, before it starts its own unit' -ForEach @(
        @{ Left = 'yuruna-host-update-install-1.service' }
        @{ Left = 'yuruna-host-update-enable-4.service' }
    ) {
        $fixture = New-PrivilegedFixture
        Use-NativeStandIn -StateHome $env:XDG_STATE_HOME -Record (New-InstallRecord -Fixture $fixture) -StdOut @{ 'sudo -n systemctl list-units *' = "$Left loaded active running /bin/bash`n" }
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        $calls = @($script:MockSeen.Calls)
        $stop = [Array]::IndexOf($calls, "sudo -n systemctl stop $Left")
        $tee = [Array]::FindIndex($calls, [Predicate[string]] { param($c) $c -like "*$($script:RuleWrite)*" })
        $unit = [Array]::FindIndex($calls, [Predicate[string]] { param($c) $c -like 'sudo -n systemd-run --unit=yuruna-host-update-install-1 *' })
        Assert-True ($stop -ge 0 -and $stop -lt $tee -and $tee -lt $unit) ('the leftover is stopped before the rule and the unit: ' + ($calls -join ' | '))
    }

    It 'fails <Step> without starting work when <Case>' -ForEach @(
        @{ Step = 'install'; Reason = 'installer_failed'; Case = 'systemctl cannot list the units'; Exit = @{ 'sudo -n systemctl list-units *' = 1 }; StdOut = @{} }
        @{ Step = 'enable'; Reason = 'enable_failed'; Case = 'systemctl cannot list the units'; Exit = @{ 'sudo -n systemctl list-units *' = 1 }; StdOut = @{} }
        @{ Step = 'install'; Reason = 'installer_failed'; Case = 'a leftover unit does not stop'; Exit = @{ 'sudo -n systemctl stop yuruna-host-update-enable-4.service' = 1 }
            StdOut = @{ 'sudo -n systemctl list-units *' = "yuruna-host-update-enable-4.service loaded active running /bin/bash`n" } }
    ) {
        $fixture = New-PrivilegedFixture
        Use-NativeStandIn -Exit $Exit -StdOut $StdOut
        $run = Invoke-TestStep -Fixture $fixture -Step $Step
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected 'earlier-unit-alive' -Actual $run.File['detail']['work']['reason']
        Assert-False ([bool]$run.File['detail']['work']['ran']) 'the work did not run'
        Assert-Equal -Expected 0 -Actual @($script:MockSeen.Calls | Where-Object { $_ -like "*$($script:RuleWrite)*" -or $_ -like "*--unit=yuruna-host-update-$Step-*" }).Count `
            ('no rule is written and no unit started: ' + ($script:MockSeen.Calls -join ' | '))
    }

    # The controller ends the step child at the phase's bound; the step
    # writes its result only after the unit's stop, the rule's removal and
    # the timer's stop, so a work wait that leaves them too little time loses
    # the result and turns a timed-out attempt into an interrupted one.
    It 'keeps the cleanup after a timed-out <Step> inside the step budget' -ForEach @(
        @{ Step = 'install'; Reason = 'installer_failed' }
        @{ Step = 'enable'; Reason = 'enable_failed' }
    ) {
        $fixture = New-PrivilegedFixture
        $work = "sudo -n systemd-run --unit=yuruna-host-update-$Step-1 *"
        Use-NativeStandIn -TimedOut @($work)
        $run = Invoke-TestStep -Fixture $fixture -Step $Step
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-True ([bool]$run.File['detail']['work']['timedOut']) 'the wait is reported as timed out'
        Assert-True ([bool]$run.File['detail']['ruleRemoved']) 'the rule is removed after the timeout'
        $calls = @($script:MockSeen.Calls)
        $timeouts = @($script:MockSeen.Timeouts)
        $at = [Array]::FindIndex($calls, [Predicate[string]] { param($c) $c -like $work })
        Assert-True ($at -ge 0) ('the work started: ' + ($calls -join ' | '))
        Assert-Match -Pattern ([regex]::Escape('--property=TimeoutStopSec=15s')) -Actual $calls[$at] 'the unit escalates to SIGKILL well inside its stop bound'
        $after = @(($at + 1)..($calls.Count - 1))
        Assert-Equal -Expected "sudo -n systemctl stop yuruna-host-update-$Step-1|sudo -n rm -f /etc/sudoers.d/yuruna-host-update|sudo -n systemctl stop yuruna-host-update-expire.timer" `
            -Actual (@($after | ForEach-Object { $calls[$_] }) -join '|') 'the cleanup after the wait'
        $cleanup = [int](@($after | ForEach-Object { [int]$timeouts[$_] }) | Measure-Object -Sum).Sum
        $budget = [int]((& (Get-Module Test.HostUpdateStep) { $script:HostUpdateStepBudgetMs })[$Step] / 1000)
        Assert-True ([int]$timeouts[$at] -le $budget - 70) "the work waits $($timeouts[$at]) s of a $budget s budget"
        Assert-True ([int]$timeouts[$at] + $cleanup -lt $budget) "the work's $($timeouts[$at]) s and the cleanup's $cleanup s fit the $budget s budget"
    }

    It 'runs Enable-TestAutomation -SkipPoolStorage -NoOperatorPrompt and maps exit <Code> to <Outcome>' -ForEach @(
        @{ Code = 0; Outcome = 'done'; Remarks = ''; Reason = $null }
        @{ Code = 2; Outcome = 'done'; Remarks = 'host_settings_unmet'; Reason = $null }
        @{ Code = 1; Outcome = 'failed'; Remarks = ''; Reason = 'enable_failed' }
    ) {
        $fixture = New-PrivilegedFixture
        Use-NativeStandIn -Exit @{ 'sudo -n systemd-run --unit=yuruna-host-update-enable-1 *' = $Code }
        $run = Invoke-TestStep -Fixture $fixture -Step enable
        Assert-Equal -Expected $Outcome -Actual $run.File['outcome']
        Assert-Equal -Expected $Remarks -Actual (@($run.File['remarks']) -join ',')
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        $unit = @($script:MockSeen.Calls | Where-Object { $_ -like 'sudo -n systemd-run --unit=yuruna-host-update-enable-1 *' })[0]
        Assert-Match -Pattern ([regex]::Escape("-File $(Join-Path $fixture.Checkout 'test/lab/Enable-TestAutomation.ps1') -SkipPoolStorage -NoOperatorPrompt")) -Actual $unit
        Assert-True (@($script:MockSeen.Calls) -contains 'sudo -n systemd-run --unit=yuruna-host-update-expire --on-active=420s --timer-property=AccuracySec=1s --quiet /usr/bin/rm -f /etc/sudoers.d/yuruna-host-update') 'the enable rule expires at 300 s plus the margin'
    }
}

# The macOS rules are chosen by the request's host type, so they run here on
# any POSIX host. Every native call (sudo, visudo, the rule's shell) lands in
# the stand-in, as on KVM; the work the step starts and the process table of
# the phase's processes are stand-ins too, so no sudo, installer or
# Enable-TestAutomation runs. The real child start and the end of its tree
# have their own Describe below.
Describe 'the install and enable phases on macOS' -Skip:$IsWindows {
    BeforeAll {
        function Use-MacStandIn {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: scoped mocks.')]
            param(
                [hashtable]$Exit = @{}, [System.Collections.IDictionary]$Record, [string]$StateHome, [int]$WorkExit = 0, [switch]$WorkTimedOut,
                [switch]$WorkNotStarted, [object[]]$Earlier = @(), [switch]$EarlierUnknown, [bool]$StopResult = $true,
                [AllowNull()][object[]]$AfterRule, [switch]$AfterRuleUnknown, [object[]]$Late = @(), [switch]$LateUnknown, [bool]$LateStopResult = $true
            )
            # The process table answers by what has happened so far: before
            # the rule is written (Earlier), once it is written and before the
            # work starts (AfterRule, by default what Earlier found), and after
            # the work (Late, the end-of-phase sweep).
            if (-not $PSBoundParameters.ContainsKey('AfterRule')) { $AfterRule = $Earlier }
            $script:MockSeen = @{
                Calls = [System.Collections.Generic.List[string]]::new(); Exit = $Exit; Record = $Record; StateHome = $StateHome; Work = $null; RuleText = $null
                WorkExit = $WorkExit; WorkTimedOut = [bool]$WorkTimedOut; WorkNotStarted = [bool]$WorkNotStarted; Earlier = $Earlier
                EarlierUnknown = [bool]$EarlierUnknown; StopResult = $StopResult; AfterRule = $AfterRule
                AfterRuleUnknown = [bool]$AfterRuleUnknown; Late = $Late; LateUnknown = [bool]$LateUnknown; LateStopResult = $LateStopResult
            }
            $native = {
                $line = (@($PesterBoundParameters['FilePath']) + @($PesterBoundParameters['ArgumentList'])) -join ' '
                $script:MockSeen.Calls.Add($line)
                if ($line -like '/usr/sbin/visudo -cf *') { $script:MockSeen.RuleText = [IO.File]::ReadAllText(@($PesterBoundParameters['ArgumentList'])[1]) }
                $code = 0
                foreach ($pattern in @($script:MockSeen.Exit.Keys)) { if ($line -like $pattern) { $code = [int]$script:MockSeen.Exit[$pattern] } }
                @{ ExitCode = $code; TimedOut = $false; StdOut = ''; StdErr = '' }
            }
            Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdate $native
            Mock Invoke-HostUpdateNative -ModuleName Test.HostUpdateStep $native
            Mock Get-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep {
                $calls = @($script:MockSeen.Calls)
                $script:MockSeen.Calls.Add("find-work $($PesterBoundParameters['RequestId'])")
                if ($calls -contains 'work') {
                    if ($script:MockSeen.LateUnknown) { return $null }
                    return , [object[]]$script:MockSeen.Late
                }
                if (@($calls | Where-Object { $_ -like $script:MacRuleWrite }).Count -gt 0) {
                    if ($script:MockSeen.AfterRuleUnknown) { return $null }
                    return , [object[]]$script:MockSeen.AfterRule
                }
                if ($script:MockSeen.EarlierUnknown) { return $null }
                , [object[]]$script:MockSeen.Earlier
            }
            Mock Stop-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep {
                $work = $PesterBoundParameters['Work']
                if ($null -eq $work) {
                    $script:MockSeen.Calls.Add('stop-work unknown')
                    return $false
                }
                $members = @($work | Where-Object { $_ })
                $script:MockSeen.Calls.Add("stop-work $($members.Count)$(if ($members.Count) { ' ' + (@($members | ForEach-Object { $_.ProcessId }) -join ',') })")
                if ($members.Count -eq 0) { return $true }
                if (@($script:MockSeen.Calls) -contains 'work') { return $script:MockSeen.LateStopResult }
                $script:MockSeen.StopResult
            }
            Mock Invoke-HostUpdateStepChildWork -ModuleName Test.HostUpdateStep {
                $script:MockSeen.Work = @{}
                foreach ($key in $PesterBoundParameters.Keys) { $script:MockSeen.Work[$key] = $PesterBoundParameters[$key] }
                $script:MockSeen.Calls.Add('work')
                if ($script:MockSeen.Record) {
                    $dir = Join-Path $script:MockSeen.StateHome 'yuruna'
                    $null = New-Item -ItemType Directory -Path $dir -Force
                    [IO.File]::WriteAllText((Join-Path $dir 'install-result.json'), ($script:MockSeen.Record | ConvertTo-Json -Depth 4))
                }
                $late = $script:MockSeen.WorkTimedOut
                [pscustomobject]@{ Started = -not $script:MockSeen.WorkNotStarted; ExitCode = $(if ($late) { 124 } else { $script:MockSeen.WorkExit }); TimedOut = $late }
            }
        }
        function New-MacFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch checkout.')]
            param([switch]$Unmarked, [switch]$KvmOnly)
            $fixture = New-StepFixture -HostType 'host.macos.utm' -Scope full
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Checkout 'install'), (Join-Path $fixture.Checkout 'test/lab') -Force
            $marker = if ($Unmarked) { "YURUNA_REPAIR_PROTOCOL_VERSION=1`n" } else { "YURUNA_UNATTENDED_PROTOCOL_VERSION=1`n" }
            if ($KvmOnly) { [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'install/ubuntu.kvm.sh'), "#!/bin/bash`nYURUNA_UNATTENDED_PROTOCOL_VERSION=1`n") }
            else { [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'install/macos.utm.sh'), "#!/bin/bash`n$marker") }
            [IO.File]::WriteAllText((Join-Path $fixture.Checkout 'test/lab/Enable-TestAutomation.ps1'), 'exit 0')
            $env:XDG_STATE_HOME = Join-Path $fixture.Home 'state'
            $fixture
        }
        function New-MacInstallRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory record.')]
            param([Parameter(Mandatory)]$Fixture, [int]$Attempt = 1, [string]$Outcome = 'succeeded', [string]$Reason, [string[]]$Issues = @(), [string[]]$Remarks = @(), $PwshUpgrade = $null)
            [ordered]@{
                schema = 1; installer = 'macos.utm'; outcome = $Outcome; exitCode = $(if ($Outcome -eq 'failed') { 1 } else { 0 }); step = 'Homebrew'; issues = $Issues
                requestId = $Fixture.RequestId; attempt = $Attempt; unattended = $true; reason = $(if ($Reason) { $Reason } else { $null })
                pwshUpgrade = $PwshUpgrade; restartRequired = $false; remarks = $Remarks
            }
        }
        function Get-CallIndex {
            param([Parameter(Mandatory)][string]$Pattern)
            $calls = @($script:MockSeen.Calls)
            for ($i = 0; $i -lt $calls.Count; $i++) { if ($calls[$i] -like $Pattern) { return $i } }
            return -1
        }
        $script:MacRuleWrite = '/bin/sh -c umask 0227; exec sudo -n /usr/bin/tee "$1" < "$2" > /dev/null sh /etc/sudoers.d/yuruna-host-update *'
        $script:MacRuleRemove = 'sudo -n /bin/rm -f /etc/sudoers.d/yuruna-host-update'
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'refuses <Case>, before any sudo call' -ForEach @(
        @{ Case = 'a macOS installer that carries no unattended marker'; KvmOnly = $false }
        @{ Case = 'a checkout whose only marked installer is the KVM one'; KvmOnly = $true }
    ) {
        $fixture = New-MacFixture -Unmarked:(-not $KvmOnly) -KvmOnly:$KvmOnly
        Use-MacStandIn
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected 'installer_unmarked' -Actual $run.File['reason']
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Calls.Count ($script:MockSeen.Calls -join ' | ')
    }

    It 'writes a rule that ends by its own date, confirms it uncached, runs the installer as a child and ends its leftovers before the rule goes' {
        $fixture = New-MacFixture
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record (New-MacInstallRecord -Fixture $fixture)
        $env:YURUNA_REPAIR = '1'
        $before = [DateTimeOffset]::UtcNow
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason']); calls $($script:MockSeen.Calls -join ' | ')"
        $visudo = Get-CallIndex '/usr/sbin/visudo -cf *'
        $tee = Get-CallIndex $script:MacRuleWrite
        $confirm = Get-CallIndex 'sudo -n -k true'
        $work = Get-CallIndex 'work'
        $sweep = [Array]::LastIndexOf([string[]]@($script:MockSeen.Calls), 'stop-work 0')
        $remove = Get-CallIndex $script:MacRuleRemove
        Assert-True (0 -le $visudo -and $visudo -lt $tee -and $tee -lt $confirm -and $confirm -lt $work) ('the order: ' + ($script:MockSeen.Calls -join ' | '))
        Assert-True ($work -lt $sweep -and $sweep -lt $remove) 'what the work left is ended while the rule is in force, then the rule goes'
        Assert-Equal -Expected $remove -Actual ($script:MockSeen.Calls.Count - 1) 'removing the rule is the last native call'
        Assert-Equal -Expected 0 -Actual @($script:MockSeen.Calls | Where-Object { $_ -match 'systemctl|systemd-run|chmod|\btee\b.*-access' }).Count 'no unit, no timer, no chmod'
        $user = [Environment]::UserName
        Assert-Match -Pattern ('\A' + [regex]::Escape("$user ALL=(ALL:ALL) NOTAFTER=") + '(\d{14})Z' + [regex]::Escape(' NOPASSWD: ALL') + '\n\z') -Actual $script:MockSeen.RuleText
        $notAfter = [DateTimeOffset]::ParseExact(([regex]::Match($script:MockSeen.RuleText, 'NOTAFTER=(\d{14})Z').Groups[1].Value), 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $seconds = ($notAfter - $before).TotalSeconds
        Assert-True ($seconds -ge 2519 -and $seconds -le 2530) "the rule ends at the install bound of 2400 s plus 120 s ($seconds s)"
        $w = $script:MockSeen.Work
        Assert-Equal -Expected '/bin/bash' -Actual $w['FilePath']
        Assert-Equal -Expected ((@((Join-Path $fixture.Checkout 'install/macos.utm.sh'), '--unattended', '--request-id', $fixture.RequestId, '--attempt', '1')) -join ' ') -Actual (@($w['ArgumentList']) -join ' ')
        Assert-Equal -Expected $fixture.RequestId -Actual $w['RequestId']
        Assert-Equal -Expected $fixture.Checkout -Actual $w['WorkingDirectory']
        Assert-Equal -Expected (Join-Path $fixture.Work 'install.1.work.log') -Actual $w['LogPath'] 'the work''s output stays in the request''s private folder'
        $environment = $w['Environment']
        foreach ($pair in @{ YURUNA_DIR = $fixture.Checkout; YURUNA_RUNTIME_DIR = $fixture.Runtime; YURUNA_NONINTERACTIVE = '1'; NONINTERACTIVE = '1'; SUDO_ASKPASS = '/usr/bin/false'; HOMEBREW_NO_INSTALL_CLEANUP = '1' }.GetEnumerator()) {
            Assert-Equal -Expected $pair.Value -Actual $environment[$pair.Key] $pair.Key
        }
        Assert-True ($environment['PATH'].StartsWith('/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:', [StringComparison]::Ordinal)) "Homebrew's prefixes come first ($($environment['PATH']))"
        Assert-Equal -Expected 'YURUNA_INSTALL_LOG,YURUNA_REFRESH,YURUNA_REPAIR' -Actual ((@($w['RemoveEnvironmentVariable']) | Sort-Object) -join ',') 'the repair''s and the attended installer''s switches are not inherited'
        Assert-True ([bool]$run.File['detail']['ruleRemoved'])
        Assert-True ([bool]$run.File['detail']['workStopped'])
        Assert-Equal -Expected 'ok' -Actual $run.File['detail']['rule']
    }

    It 'keeps the cleanup after a timed-out <Step> inside the macOS step budget' -ForEach @(
        @{ Step = 'install'; Reason = 'installer_failed'; Budget = 2340 }
        @{ Step = 'enable'; Reason = 'enable_failed'; Budget = 580 }
    ) {
        $fixture = New-MacFixture
        Use-MacStandIn -WorkTimedOut
        $run = Invoke-TestStep -Fixture $fixture -Step $Step
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-True ([bool]$run.File['detail']['work']['timedOut'])
        Assert-True ([bool]$run.File['detail']['ruleRemoved']) 'the rule is removed after the timeout'
        Assert-True ((Get-CallIndex 'work') -lt (Get-CallIndex $script:MacRuleRemove)) ''
        $waited = [int]$script:MockSeen.Work['TimeoutSeconds']
        Assert-True ($waited -le $Budget - 90 -and $waited -ge $Budget - 100) "the work waits $waited s of a $Budget s budget, 90 s kept for the cleanup"
    }

    It 'passes on the installer''s reason <Record> as <Reason> with <Action>' -ForEach @(
        @{ Record = 'clt_missing'; Reason = 'clt_missing'; Action = 'act_at_host' }
        @{ Record = 'not_provisioned'; Reason = 'not_provisioned'; Action = 'read_remarks' }
        @{ Record = 'not_elevated'; Reason = 'not_elevated'; Action = 'provision_elevation' }
        @{ Record = 'session_unusable'; Reason = 'installer_failed'; Action = 'read_remarks' }
    ) {
        $fixture = New-MacFixture
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record (New-MacInstallRecord -Fixture $fixture -Outcome 'failed' -Reason $Record) -WorkExit 1
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected $Action -Actual $run.File['operatorAction']
    }

    It 'lifts the record''s known remark tokens, keeps install_issues for issues and reports a PowerShell moved in place' {
        $fixture = New-MacFixture
        $record = New-MacInstallRecord -Fixture $fixture -Outcome 'succeeded-with-issues' -Issues @('UTM 4.6 is older than the cask (4.7); upgrade it at the host') `
            -Remarks @('utm_upgrade_deferred', 'brew_update_failed', 'not_a_token', 'utm_upgrade_deferred') -PwshUpgrade ([ordered]@{ from = '7.7.0'; to = '7.7.1'; pending = $false })
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record $record
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 'install_issues,utm_upgrade_deferred,brew_update_failed' -Actual (@($run.File['remarks']) -join ',')
        Assert-Equal -Expected 2 -Actual $run.Exit 'done with remarks'
        Assert-True ([bool]$run.File['pwshChanged']) 'the controller then restarts on the new runtime'
        Assert-False ([bool]$run.File['pwshUpgradePending']) 'nothing waits for an upgrade on macOS'
    }

    It 'reads no remarks from a record without them' {
        $fixture = New-MacFixture
        $record = New-MacInstallRecord -Fixture $fixture
        $record.Remove('remarks')
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record $record
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 0 -Actual @($run.File['remarks']).Count
        Assert-Equal -Expected 0 -Actual $run.Exit
    }

    It 'fails elevation_rule_refused and starts no work when the rule <Case>' -ForEach @(
        @{ Case = 'is refused by visudo'; Exit = @{ '/usr/sbin/visudo -cf *' = 1 }; Rule = 'visudo-refused'; Removed = $false }
        @{ Case = 'cannot be written'; Exit = @{ '/bin/sh -c umask 0227*' = 1 }; Rule = 'write-failed'; Removed = $true }
        @{ Case = 'is not confirmed'; Exit = @{ 'sudo -n -k true' = 1 }; Rule = 'not-confirmed'; Removed = $true }
    ) {
        $fixture = New-MacFixture
        Use-MacStandIn -Exit $Exit
        $run = Invoke-TestStep -Fixture $fixture -Step install
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected 'elevation_rule_refused' -Actual $run.File['reason']
        Assert-Equal -Expected 'provision_elevation' -Actual $run.File['operatorAction']
        Assert-Equal -Expected $Rule -Actual $run.File['detail']['rule']
        Assert-Equal -Expected -1 -Actual (Get-CallIndex 'work') 'the work is not started'
        Assert-Equal -Expected $Removed -Actual ((Get-CallIndex $script:MacRuleRemove) -ge 0) 'a written rule is removed again'
    }

    It 'ends the work an earlier attempt left under the new rule, before it starts its own' {
        $fixture = New-MacFixture
        $left = @([pscustomobject]@{ ProcessId = 4242; StartTimeUnixMs = 1; Kind = 'install'; Root = $false }, [pscustomobject]@{ ProcessId = 4243; StartTimeUnixMs = 2; Kind = 'install'; Root = $true })
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record (New-MacInstallRecord -Fixture $fixture -Attempt 2) -Earlier $left
        $run = Invoke-TestStep -Fixture $fixture -Step install -Attempt 2
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected "find-work $($fixture.RequestId)" -Actual $script:MockSeen.Calls[0] 'the leftovers are read first'
        $confirm = Get-CallIndex 'sudo -n -k true'
        $stop = Get-CallIndex 'stop-work 2 4242,4243'
        Assert-True ($confirm -lt $stop -and $stop -lt (Get-CallIndex 'work')) ('a root leftover needs the rule to be ended: ' + ($script:MockSeen.Calls -join ' | '))
    }

    It 'reads the leftovers again once the rule is in force and ends what they started while the rule was written' {
        $fixture = New-MacFixture
        $installer = [pscustomobject]@{ ProcessId = 4242; StartTimeUnixMs = 1; Kind = 'install'; Root = $false }
        $forked = [pscustomobject]@{ ProcessId = 4244; StartTimeUnixMs = 3; Kind = 'install'; Root = $true }
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record (New-MacInstallRecord -Fixture $fixture -Attempt 2) -Earlier @($installer) -AfterRule @($installer, $forked)
        $run = Invoke-TestStep -Fixture $fixture -Step install -Attempt 2
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        $calls = @($script:MockSeen.Calls)
        $confirm = Get-CallIndex 'sudo -n -k true'
        $work = Get-CallIndex 'work'
        $read = @(for ($i = $confirm + 1; $i -lt $work; $i++) { if ($calls[$i] -ceq "find-work $($fixture.RequestId)") { $i } })
        Assert-Equal -Expected 1 -Actual $read.Count ('the table is read again between the confirmation and the work: ' + ($calls -join ' | '))
        $stop = Get-CallIndex 'stop-work 2 4242,4244'
        Assert-True ($read[0] -lt $stop -and $stop -lt $work) ('a root process forked while the rule was written is ended before the work starts: ' + ($calls -join ' | '))
        Assert-Equal -Expected -1 -Actual (Get-CallIndex 'stop-work 1 *') 'the list read before the rule is not the one ended'
    }

    It 'fails <Step> without starting work when <Case>, and removes a rule it wrote' -ForEach @(
        @{ Step = 'install'; Reason = 'installer_failed'; Case = 'the process table cannot say what an earlier attempt left'; Unknown = $true; AfterRuleUnknown = $false; Detail = 'earlier-work-unknown' }
        @{ Step = 'install'; Reason = 'installer_failed'; Case = 'the process table cannot say it once the rule is in force'; Unknown = $false; AfterRuleUnknown = $true; Detail = 'earlier-work-unknown' }
        @{ Step = 'enable'; Reason = 'enable_failed'; Case = 'the work an earlier attempt left does not end'; Unknown = $false; AfterRuleUnknown = $false; Detail = 'earlier-work-alive' }
    ) {
        $fixture = New-MacFixture
        $left = @([pscustomobject]@{ ProcessId = 4242; StartTimeUnixMs = 1; Kind = 'enable'; Root = $true })
        Use-MacStandIn -Earlier $left -EarlierUnknown:$Unknown -AfterRuleUnknown:$AfterRuleUnknown -StopResult $false
        $run = Invoke-TestStep -Fixture $fixture -Step $Step
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected 'provision_elevation' -Actual $run.File['operatorAction']
        Assert-Equal -Expected $Detail -Actual $run.File['detail']['work']['reason']
        Assert-Equal -Expected -1 -Actual (Get-CallIndex 'work') 'the work did not run'
        if ($Unknown) { Assert-Equal -Expected -1 -Actual (Get-CallIndex $script:MacRuleWrite) 'no rule is written' }
        else {
            Assert-True ((Get-CallIndex $script:MacRuleRemove) -gt (Get-CallIndex $script:MacRuleWrite)) 'the rule written to end the leftover is removed'
            Assert-Equal -Expected ($script:MockSeen.Calls.Count - 1) -Actual (Get-CallIndex $script:MacRuleRemove) 'removing the rule is the last native call'
        }
        if ($AfterRuleUnknown) { Assert-Equal -Expected -1 -Actual (Get-CallIndex 'stop-work 1 *') 'nothing is ended from the list read before the rule' }
    }

    It 'fails <Step> as <Reason> when the work does not start, and removes the rule' -ForEach @(
        @{ Step = 'install'; Reason = 'installer_failed' }
        @{ Step = 'enable'; Reason = 'enable_failed' }
    ) {
        $fixture = New-MacFixture
        Use-MacStandIn -WorkNotStarted
        $run = Invoke-TestStep -Fixture $fixture -Step $Step
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected 'provision_elevation' -Actual $run.File['operatorAction']
        Assert-False ([bool]$run.File['detail']['work']['ran'])
        Assert-Null $run.File['detail']['work']['exitCode']
        Assert-Equal -Expected 'work-not-started' -Actual $run.File['detail']['work']['reason']
        Assert-True ((Get-CallIndex 'work') -gt (Get-CallIndex 'sudo -n -k true')) 'the start was tried under the rule'
        Assert-Equal -Expected ($script:MockSeen.Calls.Count - 1) -Actual (Get-CallIndex $script:MacRuleRemove) 'the rule is removed, last'
        Assert-True ([bool]$run.File['detail']['ruleRemoved'])
    }

    It 'ends what the work left at the end of the phase, before the rule goes, when <Case>' -ForEach @(
        @{ Case = 'the members end'; LateUnknown = $false; LateStopResult = $true; Stopped = $true }
        @{ Case = 'a member does not end'; LateUnknown = $false; LateStopResult = $false; Stopped = $false }
        @{ Case = 'the process table cannot say what runs'; LateUnknown = $true; LateStopResult = $true; Stopped = $false }
    ) {
        $fixture = New-MacFixture
        $late = @([pscustomobject]@{ ProcessId = 5000; StartTimeUnixMs = 7; Kind = 'install'; Root = $true }, [pscustomobject]@{ ProcessId = 5001; StartTimeUnixMs = 8; Kind = 'install'; Root = $false })
        Use-MacStandIn -StateHome $env:XDG_STATE_HOME -Record (New-MacInstallRecord -Fixture $fixture) -Late $late -LateUnknown:$LateUnknown -LateStopResult $LateStopResult
        $run = Invoke-TestStep -Fixture $fixture -Step install
        $calls = @($script:MockSeen.Calls)
        $work = Get-CallIndex 'work'
        $remove = Get-CallIndex $script:MacRuleRemove
        $read = [Array]::LastIndexOf([string[]]$calls, "find-work $($fixture.RequestId)")
        Assert-True ($work -lt $read -and $read -lt $remove) ('the table is read after the work, while the rule is in force: ' + ($calls -join ' | '))
        $sweep = if ($LateUnknown) { [Array]::LastIndexOf([string[]]$calls, 'stop-work unknown') } else { [Array]::LastIndexOf([string[]]$calls, 'stop-work 2 5000,5001') }
        Assert-True ($read -lt $sweep -and $sweep -lt $remove) ('what the table named is handed to the stop before the rule goes: ' + ($calls -join ' | '))
        Assert-Equal -Expected ($calls.Count - 1) -Actual $remove 'removing the rule is the last native call'
        Assert-Equal -Expected $Stopped -Actual ([bool]$run.File['detail']['workStopped'])
        Assert-True ([bool]$run.File['detail']['ruleRemoved']) 'the rule is removed whatever the sweep found'
    }

    It 'runs Enable-TestAutomation -SkipPoolStorage -NoOperatorPrompt under a rule that ends at 600 s plus the margin, and maps exit <Code> to <Outcome>' -ForEach @(
        @{ Code = 0; Outcome = 'done'; Remarks = ''; Reason = $null }
        @{ Code = 2; Outcome = 'done'; Remarks = 'host_settings_unmet'; Reason = $null }
        @{ Code = 1; Outcome = 'failed'; Remarks = ''; Reason = 'enable_failed' }
    ) {
        $fixture = New-MacFixture
        Use-MacStandIn -WorkExit $Code
        $before = [DateTimeOffset]::UtcNow
        $run = Invoke-TestStep -Fixture $fixture -Step enable
        Assert-Equal -Expected $Outcome -Actual $run.File['outcome']
        Assert-Equal -Expected $Remarks -Actual (@($run.File['remarks']) -join ',')
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        $w = $script:MockSeen.Work
        Assert-Match -Pattern ([regex]::Escape("-File $(Join-Path $fixture.Checkout 'test/lab/Enable-TestAutomation.ps1') -SkipPoolStorage -NoOperatorPrompt")) -Actual (@($w['ArgumentList']) -join ' ')
        Assert-Equal -Expected 'pwsh' -Actual ([IO.Path]::GetFileNameWithoutExtension([string]$w['FilePath']))
        Assert-Equal -Expected 'enable.1.work.log' -Actual (Split-Path -Leaf $w['LogPath'])
        Assert-Equal -Expected '/usr/bin/false' -Actual $w['Environment']['SUDO_ASKPASS'] 'the enable phase runs with the macOS environment too'
        Assert-Equal -Expected $fixture.Runtime -Actual $w['Environment']['YURUNA_RUNTIME_DIR']
        $notAfter = [DateTimeOffset]::ParseExact(([regex]::Match($script:MockSeen.RuleText, 'NOTAFTER=(\d{14})Z').Groups[1].Value), 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $seconds = ($notAfter - $before).TotalSeconds
        Assert-True ($seconds -ge 719 -and $seconds -le 730) "the enable rule ends at 600 s plus 120 s ($seconds s)"
        Assert-Equal -Expected 580 -Actual ([int]((& (Get-Module Test.HostUpdateStep) { Get-HostUpdateStepBudget -Step enable -HostType 'host.macos.utm' }) / 1000)) 'the macOS enable budget'
        Assert-Equal -Expected 280 -Actual ([int]((& (Get-Module Test.HostUpdateStep) { Get-HostUpdateStepBudget -Step enable -HostType 'host.ubuntu.kvm' }) / 1000)) 'the KVM enable budget is unchanged'
    }
}

# The child the macOS branch starts, with real processes: its environment,
# its streams and the end of its tree at the bound. Root members and their
# sudo kill are the controller module's, with their own suite; here every
# member runs as the test account.
Describe 'the macOS work child' -Skip:$IsWindows {
    BeforeAll {
        function New-ChildWorkCase {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a scratch checkout with a stand-in installer.')]
            param([Parameter(Mandatory)][string]$Body)
            $dir = Join-Path $script:ScratchBase ('cw-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path (Join-Path $dir 'install'), (Join-Path $dir 'work') -Force
            $installer = Join-Path $dir 'install/macos.utm.sh'
            [IO.File]::WriteAllText($installer, "#!/bin/bash`n$Body`n")
            [pscustomobject]@{ Dir = $dir; Installer = $installer; Log = (Join-Path $dir 'work/install.1.work.log'); RequestId = [Guid]::NewGuid().ToString() }
        }
        function Invoke-ChildWork {
            param([Parameter(Mandatory)]$Case, [int]$TimeoutSeconds = 60)
            $script:MockSeen.Native = [System.Collections.Generic.List[string]]::new()
            $native = { param($FilePath, $ArgumentList) $script:MockSeen.Native.Add((@($FilePath) + @($ArgumentList)) -join ' '); @{ ExitCode = 0; TimedOut = $false } }
            & (Get-Module Test.HostUpdateStep) {
                param($Case, $TimeoutSeconds, $Native)
                Invoke-HostUpdateStepChildWork -RequestId $Case.RequestId -FilePath '/bin/bash' -ArgumentList @($Case.Installer, '--unattended', '--request-id', $Case.RequestId, '--attempt', '1') `
                    -Environment (Get-HostUpdateStepMacEnvironment -Environment @{ YURUNA_DIR = $Case.Dir; YURUNA_NONINTERACTIVE = '1' }) `
                    -RemoveEnvironmentVariable $script:HostUpdateStepMacRemoveName -WorkingDirectory $Case.Dir -LogPath $Case.Log -TimeoutSeconds $TimeoutSeconds -Native $Native
            } $Case $TimeoutSeconds $native
        }
        function Read-ChildPid {
            param([Parameter(Mandatory)]$Case)
            $file = Join-Path $Case.Dir 'child.pid'
            if (-not (Wait-TestCondition { (Test-Path -LiteralPath $file) -and ([IO.File]::ReadAllText($file)).Trim() })) { throw 'the stand-in installer wrote no child pid' }
            [int]([IO.File]::ReadAllText($file)).Trim()
        }
        function Test-PidGone {
            param([Parameter(Mandatory)][int]$ProcessId)
            try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $false } catch { return $true }
        }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'runs the program with standard input closed, its output in the log, the macOS environment and its exit code' {
        $case = New-ChildWorkCase -Body @'
printf 'argv=%s\n' "$*"
printf 'cwd=%s\n' "$PWD"
printf 'repair=%s refresh=%s log=%s\n' "${YURUNA_REPAIR-unset}" "${YURUNA_REFRESH-unset}" "${YURUNA_INSTALL_LOG-unset}"
printf 'dir=%s nonint=%s askpass=%s cleanup=%s\n' "$YURUNA_DIR" "$NONINTERACTIVE" "$SUDO_ASKPASS" "$HOMEBREW_NO_INSTALL_CLEANUP"
printf 'path=%s\n' "$PATH"
if read -r line; then echo 'stdin=data'; else echo 'stdin=eof'; fi
echo 'to stderr' >&2
exit 3
'@
        $env:YURUNA_REPAIR = '1'; $env:YURUNA_REFRESH = '1'; $env:YURUNA_INSTALL_LOG = '/tmp/elsewhere.log'
        $r = Invoke-ChildWork -Case $case
        Assert-True $r.Started
        Assert-Equal -Expected 3 -Actual $r.ExitCode
        Assert-False $r.TimedOut
        $log = [IO.File]::ReadAllText($case.Log)
        Assert-Match -Pattern ([regex]::Escape("argv=--unattended --request-id $($case.RequestId) --attempt 1")) -Actual $log
        Assert-Match -Pattern ([regex]::Escape("cwd=$($case.Dir)")) -Actual $log
        Assert-Match -Pattern 'repair=unset refresh=unset log=unset' -Actual $log 'the switches of the repair and the attended installer are not inherited'
        Assert-Match -Pattern ([regex]::Escape("dir=$($case.Dir) nonint=1 askpass=/usr/bin/false cleanup=1")) -Actual $log
        Assert-Match -Pattern '(?m)^path=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:' -Actual $log
        Assert-Match -Pattern '(?m)^stdin=eof$' -Actual $log 'nothing can be read from standard input'
        Assert-Match -Pattern '(?m)^to stderr$' -Actual $log 'standard error goes to the log too'
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Native.Count
    }

    It 'ends the phase''s processes at the bound, a grandchild included, and reports a timeout' {
        $case = New-ChildWorkCase -Body 'echo $$ > "$(dirname "$0")/../installer.pid"; sleep 300 & echo $! > "$(dirname "$0")/../child.pid"; wait'
        # The real process table, narrowed to this request's installer, so an
        # unattended Enable-TestAutomation another suite runs beside this one
        # is never touched. The real stop runs too; what the table named and
        # what was left right after the stop are recorded, because the
        # child's own Kill fallback would end this test-account tree even if
        # the table had named nothing, and only the table reaches root
        # members on a Mac.
        $script:MockSeen = @{
            Real     = (Get-Module Test.HostUpdate).ExportedFunctions['Get-HostUpdateMacElevatedWork']
            RealStop = (Get-Module Test.HostUpdate).ExportedFunctions['Stop-HostUpdateMacElevatedWork']
            Found    = $null; Stopped = $null; AliveAfterStop = $null
        }
        Mock Get-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep {
            $found = & $script:MockSeen.Real -RequestId $PesterBoundParameters['RequestId']
            if ($null -eq $found) { return $null }
            $script:MockSeen.Found = @($found | Where-Object { $_.Kind -ceq 'install' })
            , [object[]]$script:MockSeen.Found
        }
        Mock Stop-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep {
            $script:MockSeen.Stopped = & $script:MockSeen.RealStop -Work $PesterBoundParameters['Work'] -Native $PesterBoundParameters['Native'] -Confirm:$false
            # Liveness is read as the stop reads it (pid and start time from
            # the table), so a child not yet reaped is not counted alive.
            $script:MockSeen.AliveAfterStop = @(foreach ($member in @($PesterBoundParameters['Work'] | Where-Object { $_ })) {
                    $state = & (Get-Module Test.HostUpdate) { param($Member) Get-HostUpdateProcessLiveness -ProcessId $Member.ProcessId -StartTimeUnixMs $Member.StartTimeUnixMs } $member
                    if ($state -ne 'dead') { "$($member.ProcessId)=$state" }
                })
            $script:MockSeen.Stopped
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ChildWork -Case $case -TimeoutSeconds 2
        $child = Read-ChildPid -Case $case
        $installer = [int]([IO.File]::ReadAllText((Join-Path $case.Dir 'installer.pid'))).Trim()
        $script:StandInPidFiles.Add((Join-Path $case.Dir 'child.pid'))
        Assert-True $r.TimedOut
        Assert-Equal -Expected 124 -Actual $r.ExitCode
        Assert-True ($watch.Elapsed.TotalSeconds -lt 60) "the end of the tree is bounded ($($watch.Elapsed.TotalSeconds) s)"
        $named = @($script:MockSeen.Found | ForEach-Object { "$($_.ProcessId):$($_.Kind):$([bool]$_.Root)" } | Sort-Object)
        Assert-Equal -Expected ((@("$($installer):install:False", "$($child):install:False") | Sort-Object) -join ',') -Actual ($named -join ',') 'the table names the installer by its arguments and its child as a descendant'
        Assert-True ([bool]$script:MockSeen.Stopped) 'the stop confirms every member gone'
        Assert-Equal -Expected 0 -Actual @($script:MockSeen.AliveAfterStop).Count "the stop itself ended the tree, before any fallback (left: $(@($script:MockSeen.AliveAfterStop) -join ','))"
        Assert-True (Wait-TestCondition -TimeoutMilliseconds 10000 { Test-PidGone -ProcessId $child }) 'the installer''s own child is ended with it'
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Native.Count 'no member runs as root, so no sudo kill'
    }

    It 'ends the child''s tree as the test account when the process table cannot say what runs' {
        $case = New-ChildWorkCase -Body 'sleep 300 & echo $! > "$(dirname "$0")/../child.pid"; wait'
        $script:MockSeen = @{ Stops = 0 }
        Mock Get-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep { $null }
        Mock Stop-HostUpdateMacElevatedWork -ModuleName Test.HostUpdateStep { $script:MockSeen.Stops++; $false }
        $r = Invoke-ChildWork -Case $case -TimeoutSeconds 2
        $child = Read-ChildPid -Case $case
        $script:StandInPidFiles.Add((Join-Path $case.Dir 'child.pid'))
        Assert-True $r.TimedOut
        Assert-Equal -Expected 0 -Actual $script:MockSeen.Stops 'nothing is stopped from an unknown table'
        Assert-True (Wait-TestCondition -TimeoutMilliseconds 10000 { Test-PidGone -ProcessId $child }) 'the child''s tree is ended all the same'
    }

    It 'reports a program that could not start' {
        $case = New-ChildWorkCase -Body 'exit 0'
        $r = & (Get-Module Test.HostUpdateStep) {
            param($Case)
            Invoke-HostUpdateStepChildWork -RequestId $Case.RequestId -FilePath '/bin/bash' -WorkingDirectory (Join-Path $Case.Dir 'no-such-folder') -LogPath $Case.Log -TimeoutSeconds 5
        } $case
        Assert-False $r.Started
        Assert-Null $r.ExitCode
    }
}

# The copy is made owned by Administrators, which only an elevated token may
# name as owner; the step runs elevated on Windows, and the Windows suites run
# from an elevated shell (docs/test-harness.md), so a missing token fails here.
Describe 'the install phase on Windows' -Skip:(-not $IsWindows) {
    BeforeAll {
        # LOCALAPPDATA and ProgramData point into a scratch folder, so the
        # installer record and the copy the phase makes never reach the
        # host's own; the work is a stand-in that writes the record an
        # installer would, so no installer runs.
        function New-WindowsInstallFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch checkout and redirects two folders of this process.')]
            param()
            $dir = Join-Path $script:ScratchBase ('w-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $env:LOCALAPPDATA = Join-Path $dir 'local'
            $env:ProgramData = Join-Path $dir 'programdata'
            $checkout = Join-Path $dir 'checkout'
            $null = New-Item -ItemType Directory -Path (Join-Path $checkout 'install'), $env:LOCALAPPDATA, $env:ProgramData -Force
            $installer = Join-Path $checkout 'install\windows.hyper-v.ps1'
            [IO.File]::WriteAllText($installer, "param()`r`n`$script:YurunaUnattendedProtocolVersion = 1`r`nexit 0`r`n")
            $requestId = [Guid]::NewGuid().ToString()
            [pscustomobject]@{
                Installer = $installer; RequestId = $requestId
                Context   = @{
                    Step = 'install'; RequestId = $requestId; Attempt = 1; RepoRoot = $checkout; RuntimeDir = (Join-Path $dir 'runtime'); WorkDirectory = $dir
                    Deadline = New-YurunaDeadline -TotalMilliseconds 120000
                }
            }
        }
        function Invoke-WindowsInstall {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
            $script:MockSeen = @{ Record = $Record; Calls = [System.Collections.Generic.List[string]]::new() }
            $native = {
                param($FilePath, $ArgumentList, $TimeoutSeconds)
                $null = $TimeoutSeconds
                $script:MockSeen.Calls.Add((@($FilePath) + @($ArgumentList)) -join ' ')
                $dir = Join-Path $env:LOCALAPPDATA 'yuruna'
                $null = New-Item -ItemType Directory -Path $dir -Force
                [IO.File]::WriteAllText((Join-Path $dir 'install-result.json'), ($script:MockSeen.Record | ConvertTo-Json -Depth 4))
                @{ ExitCode = 0; TimedOut = $false; StdOut = ''; StdErr = '' }
            }
            & (Get-Module Test.HostUpdateStep) {
                param($Context, $Native)
                $result = New-HostUpdateStepResult -Step install -RequestId $Context.RequestId -Attempt $Context.Attempt
                Invoke-HostUpdateStepInstall -Context $Context -Result $result -Native $Native
                $result
            } $Fixture.Context $native
        }
        function New-WindowsInstallRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory record.')]
            param([Parameter(Mandatory)]$Fixture, [int]$Attempt = 1, [bool]$Pending)
            [ordered]@{
                schema = 1; installer = 'windows.hyper-v'; outcome = 'succeeded'; exitCode = 0; issues = @()
                requestId = $Fixture.RequestId; attempt = $Attempt; unattended = $true; reason = $null
                pwshUpgrade = [ordered]@{ from = '7.6.9'; to = '7.7.0'; pending = $Pending }; restartRequired = $false
            }
        }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    It 'runs a copy only Administrators and SYSTEM can change, with the hash of the checkout''s installer, and reports an upgrade <Case>' -ForEach @(
        @{ Case = 'that waits'; Pending = $true }
        @{ Case = 'that does not wait'; Pending = $false }
    ) {
        $fixture = New-WindowsInstallFixture
        $result = Invoke-WindowsInstall -Fixture $fixture -Record (New-WindowsInstallRecord -Fixture $fixture -Pending $Pending)
        Assert-Equal -Expected 'done' -Actual $result['outcome']
        $dir = Join-Path $env:ProgramData "yuruna\host-update-$($fixture.RequestId)-1"
        $copy = Join-Path $dir 'windows.hyper-v.ps1'
        Assert-True (Test-Path -LiteralPath $copy -PathType Leaf) "the copy is at '$copy'"
        $hash = (Get-FileHash -LiteralPath $fixture.Installer -Algorithm SHA256).Hash
        Assert-Equal -Expected $hash -Actual (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash 'the copy is the checkout''s installer'
        Assert-Equal -Expected $hash -Actual $result['installerSha256'] 'the result carries the hash the upgrade checks again'
        Assert-True (Test-HostUpdateWindowsAdminOnlyAcl -Path $dir) 'only Administrators and SYSTEM can write the copy''s folder'
        Assert-Equal -Expected 'S-1-5-32-544' -Actual (Get-Acl -LiteralPath $dir).GetOwner([Security.Principal.SecurityIdentifier]).Value 'Administrators own the folder, not the account that made it'
        Assert-False ([bool]([IO.DirectoryInfo]::new($dir).LinkTarget)) 'the folder is not a link'
        Assert-Equal -Expected 1 -Actual $script:MockSeen.Calls.Count
        Assert-Match -Pattern ([regex]::Escape("-File $copy -Unattended -YurunaDir $($fixture.Context.RepoRoot) -RequestId $($fixture.RequestId) -Attempt 1")) -Actual $script:MockSeen.Calls[0]
        Assert-Equal -Expected $Pending -Actual ([bool]$result['pwshUpgradePending'])
    }

    It 'fails installer_failed on a record of another attempt' {
        $fixture = New-WindowsInstallFixture
        $result = Invoke-WindowsInstall -Fixture $fixture -Record (New-WindowsInstallRecord -Fixture $fixture -Attempt 7 -Pending $true)
        Assert-Equal -Expected 'failed' -Actual $result['outcome']
        Assert-Equal -Expected 'installer_failed' -Actual $result['reason']
        Assert-Equal -Expected 'read_remarks' -Actual $result['operatorAction']
        Assert-Equal -Expected 'missing' -Actual $result['detail']['record']
        Assert-False ([bool]$result['pwshUpgradePending']) 'no upgrade waits on a record that is not this attempt''s'
    }
}

Describe 'the runner start' -Skip:$IsWindows {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    BeforeAll {
        function Set-TestResume {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a scoped mock that records the start it was asked for.')]
            param([Parameter(Mandatory)][hashtable]$Seen, [Parameter(Mandatory)][hashtable]$Answer, $Fixture)
            $script:MockSeen = @{ Seen = $Seen; Answer = $Answer; Fixture = $Fixture }
            Mock Invoke-YurunaRunnerHandoffResume -ModuleName Test.HostUpdateStep {
                $record = $script:MockSeen.Seen
                $record.Count = [int]$record.Count + 1
                foreach ($key in $PesterBoundParameters.Keys) { $record[$key] = $PesterBoundParameters[$key] }
                $at = $script:MockSeen.Fixture
                if ($at) { $record.Gate = & $script:RealGateReader -RuntimeDir $at.Runtime -PrivateRoot $at.PrivateRoot }
                [pscustomobject]$script:MockSeen.Answer
            }
        }
    }

    It 'treats a live resident with an open gate as done' {
        $fixture = New-StepFixture
        $resident = Start-StandInProcess -ScriptPath (Join-Path $fixture.Checkout 'test/Start-TestRunner.ps1')
        Write-TestRecord -Runtime $fixture.Runtime -Stem 'runner' -Process $resident
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = 'ready' }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-True ([bool]$run.File['detail']['already']) 'an earlier attempt succeeded and only its record was lost'
        Assert-Equal -Expected 0 -Actual $seen.Count 'nothing is started beside a live resident'
        Assert-False (Test-ProcessGone -Process $resident) 'the resident is left running'
    }

    It 'closes the gate again and revokes a stale handoff before starting' {
        $fixture = New-StepFixture
        $closed = Set-YurunaRunnerGate -State closed -RequestId $fixture.RequestId -Attempt 1 -RuntimeDir $fixture.Runtime -ExpectedGeneration '' `
            -OwnerPid $PID -OwnerRole controller -PrivateRoot $fixture.PrivateRoot -Confirm:$false
        $stale = New-YurunaRunnerHandoffToken -RequestId $fixture.RequestId -Attempt 1 -RuntimeDir $fixture.Runtime -Purpose new-outer -ExpiresInMilliseconds 120000 `
            -ExpectedGeneration $closed.Generation -PrivateRoot $fixture.PrivateRoot -Confirm:$false
        Assert-True $stale.Issued "fixture sanity: a handoff an interrupted attempt left ($($stale.Reason))"
        # A resident that read the gate open just before it closed.
        $resident = Start-StandInProcess -ScriptPath (Join-Path $fixture.Checkout 'test/Start-TestRunner.ps1')
        Write-TestRecord -Runtime $fixture.Runtime -Stem 'runner' -Process $resident
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Fixture $fixture -Answer @{ Outcome = 'ready'; Reason = 'ready'; Console = 'tmux'; ConsoleReason = 'created'; ConsolePid = 4242; OuterPid = 4243 }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -Attempt 2 -ControllerPid $PID
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
        Assert-Equal -Expected 0 -Actual $run.Exit 'a console is no remark'
        Assert-Equal -Expected 'tmux' -Actual $run.File['runnerConsole']
        Assert-Equal -Expected 1 -Actual $seen.Count
        Assert-Equal -Expected 'closed' -Actual $seen.Gate.State 'the start found the gate closed again, not in the old handoff'
        Assert-Equal -Expected $fixture.RequestId -Actual $seen.Gate.RequestId
        Assert-Equal -Expected 'controller' -Actual ([string]$seen.Gate.Owner['role'])
        Assert-Equal -Expected $seen.Gate.Generation -Actual $seen['ExpectedGateGeneration'] 'the generation is read at use'
        Assert-False (Test-YurunaRunnerHandoffToken -TokenId $stale.TokenId -Role outer -RuntimeDir $fixture.Runtime -PrivateRoot $fixture.PrivateRoot).Valid 'the stale handoff is revoked'
        Assert-True (Test-ProcessGone -Process $resident) 'a live resident under the closed gate is stopped first'
        Assert-Equal -Expected $resident.Id -Actual ([int]$run.File['reclaimed']['outer']['pid'])
        Assert-Equal -Expected "runner-$($fixture.RequestId)-2" -Actual $seen['ConsoleSessionName'] 'the session carries the request and the attempt'
        Assert-Equal -Expected (Join-Path $fixture.ControllerRoot 'runner-console.sock') -Actual $seen['ConsoleSocketPath']
        Assert-Equal -Expected (Join-Path $fixture.Work 'console.2.log') -Actual $seen['ConsoleLogPath']
        Assert-Equal -Expected $fixture.Work -Actual $seen['PrivateDirectory']
        Assert-Equal -Expected 'released' -Actual $seen['OnReady']
        Assert-Equal -Expected 4242 -Actual ([int]$run.File['detail']['resume']['panePid'])
        Assert-Equal -Expected 4243 -Actual ([int]$run.File['detail']['resume']['outerPid'])
    }

    It 'maps <Outcome>/<Why> to <Reason>' -ForEach @(
        @{ Outcome = 'timeout'; Why = 'deadline'; Reason = 'runner_start_timeout'; Action = 'repair_checkout'; Console = 'tmux' }
        @{ Outcome = 'launch-failed'; Why = 'runner-exited'; Reason = 'runner_exited'; Action = 'repair_checkout'; Console = 'tmux' }
        @{ Outcome = 'launch-failed'; Why = 'console-state-unknown'; Reason = 'console_state_unknown'; Action = 'act_at_host'; Console = 'none' }
        @{ Outcome = 'failed'; Why = 'config-gate-failed'; Reason = 'config_gate_failed'; Action = 'act_at_host'; Console = 'tmux' }
        @{ Outcome = 'refused'; Why = 'launch-record-missing'; Reason = 'runner_start_failed'; Action = 'repair_checkout'; Console = $null }
        @{ Outcome = 'identity-mismatch'; Why = 'outer-mismatch'; Reason = 'runner_start_failed'; Action = 'repair_checkout'; Console = 'tmux' }
    ) {
        $fixture = New-StepFixture
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = $Outcome; Reason = $Why; Console = $Console }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'failed' -Actual $run.File['outcome']
        Assert-Equal -Expected $Reason -Actual $run.File['reason']
        Assert-Equal -Expected $Action -Actual $run.File['operatorAction']
        Assert-Equal -Expected $Outcome -Actual $run.File['detail']['resume']['outcome'] 'the start''s own outcome stays in the detail'
        Assert-Equal -Expected 1 -Actual $run.Exit
    }

    It 'starts without a console and reports runner_console_unavailable when there is none' {
        $fixture = New-StepFixture
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = 'ready'; Reason = 'ready'; Console = 'none'; ConsoleReason = 'no-multiplexer' }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 'none' -Actual $run.File['runnerConsole']
        Assert-Equal -Expected 'runner_console_unavailable' -Actual (@($run.File['remarks']) -join ',') 'a missing console never fails the update'
        Assert-Equal -Expected 2 -Actual $run.Exit
        Assert-Equal -Expected 'no-multiplexer' -Actual $run.File['detail']['resume']['consoleReason']
    }

    It 'records a console window, which is no remark' {
        $fixture = New-StepFixture
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = 'ready'; Reason = 'ready'; Console = 'window'; ConsolePid = 4242 }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'done' -Actual $run.File['outcome']
        Assert-Equal -Expected 'window' -Actual $run.File['runnerConsole']
        Assert-Equal -Expected 0 -Actual @($run.File['remarks']).Count
        Assert-Equal -Expected 0 -Actual $run.Exit
    }

    It 'carries the phase-3 inner identity into the handoff token' {
        $fixture = New-StepFixture
        Enter-TestClaim -Fixture $fixture
        $inner = [ordered]@{ pid = 31337; startTimeUnixMs = [long]1700000000123 }
        $null = Set-HostUpdatePhase -RequestId $fixture.RequestId -ControllerPid $PID -Phase stop_runner -State started -Confirm:$false
        $write = Set-HostUpdatePhase -RequestId $fixture.RequestId -ControllerPid $PID -Phase stop_runner -State finished -Outcome done `
            -Reclaimed ([ordered]@{ outer = [ordered]@{ pid = 31336; startTimeUnixMs = [long]1700000000000 }; cycle = $null; inner = $inner }) -Confirm:$false
        Assert-True $write.Written "fixture sanity: phase 3 journaled its stop ($($write.Reason))"
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = 'ready'; Console = 'tmux' }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'done' -Actual $run.File['outcome'] -Because "reason $($run.File['reason'])"
        Assert-Equal -Expected 31337 -Actual ([int]$seen['Reclaimed']['inner']['pid']) 'the resumed runner can archive the stale break marker'
        Assert-Equal -Expected 1700000000123 -Actual ([long]$seen['Reclaimed']['inner']['startTimeUnixMs'])
        Assert-Equal -Expected 31336 -Actual ([int]$seen['Reclaimed']['outer']['pid'])
        Assert-Null $run.File['reclaimed']['inner'] 'this attempt stopped nothing itself'
    }

    It 'refuses gate_busy for a gate another request holds and starts nothing' {
        $fixture = New-StepFixture
        $null = Set-YurunaRunnerGate -State closed -RequestId (New-YurunaHostOperationRequestId) -Attempt 1 -RuntimeDir $fixture.Runtime -ExpectedGeneration '' `
            -OwnerPid $PID -PrivateRoot $fixture.PrivateRoot -Confirm:$false
        $seen = @{ Count = 0 }
        Set-TestResume -Seen $seen -Answer @{ Outcome = 'ready' }
        $run = Invoke-TestStep -Fixture $fixture -Step start_runner -ControllerPid $PID
        Assert-Equal -Expected 'gate_busy' -Actual $run.File['reason']
        Assert-Equal -Expected 0 -Actual $seen.Count
    }
}

Describe 'the console start' -Skip:$IsWindows {
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers }

    BeforeAll {
        function New-ConsoleCase {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a private folder and a stand-in worker under the suite temp dir.')]
            param()
            $private = Join-Path $script:ScratchBase ('p-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path $private -Force
            $marker = Join-Path $private 'worker.ran'
            $worker = Join-Path $private 'worker.ps1'
            [System.IO.File]::WriteAllText($worker, "[System.IO.File]::WriteAllText('$($marker.Replace("'", "''"))', [string]`$PID)`nStart-Sleep -Seconds 30`n")
            # The socket is only a name to the stand-in; a short one keeps
            # every case but the long-path one under the bind limit.
            [pscustomobject]@{ Private = $private; Worker = $worker; Marker = $marker; Socket = "/tmp/yhu-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).sock" }
        }

        function Start-ConsoleLaunch {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: launches a disposable stand-in worker the suite ends itself.')]
            param([Parameter(Mandatory)]$Case, [hashtable]$Environment = @{}, [string]$Session = 'runner-test-1', [string]$LogPath, [string]$Socket, [string[]]$ArgumentList = @('-Flag', 'value with space'))
            $launch = @{
                FilePath = $Case.Worker; ArgumentList = $ArgumentList; WorkingDirectory = $Case.Private; Environment = $Environment
                StdOutPath = '/dev/null'; StdErrPath = (Join-Path $Case.Private 'worker.err'); PrivateDirectory = $Case.Private
                ConsoleSocketPath = $(if ($Socket) { $Socket } else { $Case.Socket }); ConsoleSessionName = $Session
                ConsoleLogPath = $(if ($LogPath) { $LogPath } else { Join-Path $Case.Private 'console.1.log' }); Confirm = $false
            }
            $result = Start-YurunaDetachedProcess @launch
            if ($result.FinalPid -and $result.Console -ne 'tmux') {
                try { $script:Spawned.Add([System.Diagnostics.Process]::GetProcessById([int]$result.FinalPid)) } catch { $null = $_ }
            }
            $result
        }
    }

    It 'builds the session command from a launch record: env vector, unset list, working directory, pwsh vector' {
        $case = New-ConsoleCase
        $tmux = New-StandInTmux -Scenario created
        $repo = New-StandInRunnerRepo -Body 'exit 0'
        $runtime = Join-Path $case.Private 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $forward = @{ YURUNA_RUNTIME_DIR = $runtime; YURUNA_LOG_DIR = (Join-Path $case.Private 'log'); YURUNA_CONFIG_PATH = (Join-Path $repo 'runner.config.yml'); YURUNA_LOG_LEVEL = 'Verbose' }
        $written = Write-YurunaRunnerLaunchRecord -ScriptPath (Join-Path $repo 'test/Start-TestRunner.ps1') -BoundParameters ([ordered]@{}) -ResolvedConfigPath (Join-Path $repo 'runner.config.yml') `
            -RuntimeDir $runtime -RepoRoot $repo -WorkingDirectory $repo -ForwardEnvironment $forward -AllowedEnvironmentName @($forward.Keys) -PrivateRoot $case.Private -Confirm:$false
        Assert-True $written.Written "fixture sanity: launch record ($($written.Reason))"
        $record = (Read-YurunaRunnerLaunchRecord -RuntimeDir $runtime -PrivateRoot $case.Private).Record
        $environment = @{}
        foreach ($key in $record['environment'].Keys) { $environment[[string]$key] = [string]$record['environment'][$key] }
        $token = 'a' * 32
        $arguments = @(New-YurunaRunnerResumeArgumentList -Record $record -TokenId $token)
        $runner = Join-Path $repo 'test/Start-TestRunner.ps1'
        $result = Start-YurunaDetachedProcess -FilePath $runner -ArgumentList $arguments -WorkingDirectory ([string]$record['workingDirectory']) -Environment $environment `
            -StdOutPath '/dev/null' -StdErrPath (Join-Path $case.Private 'runner.err') -PrivateDirectory $case.Private -ConsoleSocketPath $case.Socket `
            -ConsoleSessionName 'runner-r-1' -ConsoleLogPath (Join-Path $case.Private 'console.1.log') -Confirm:$false
        Assert-True $result.Launched "launched ($($result.Reason) $($result.Detail))"
        Assert-Equal -Expected 'tmux' -Actual $result.Console
        Assert-Equal -Expected 'created' -Actual $result.ConsoleReason
        $calls = Get-StandInCall -Dir $tmux
        $create = @($calls | Where-Object { (Get-StandInSubcommand -Call $_) -eq 'new-session' })[0]
        $expected = @('-S', $case.Socket, '-f', '/dev/null', 'new-session', '-d', '-P', '-F', '#{pane_pid}', '-s', 'runner-r-1', '-x', '200', '-y', '50', '-c', $repo,
            '/usr/bin/env', '-u', 'YURUNA_SG_RELAUNCH', '-u', 'YURUNA_RUNNER_RELAUNCH', '-u', 'YURUNA_HANDOFF_TOKEN', '-u', 'YURUNA_HANDOFF_PREFLIGHT',
            '-u', 'YURUNA_HANDOFF_BARRIER', '-u', 'YURUNA_CYCLE_GENERATION', '-u', 'STY', '-u', 'TMUX_PANE')
        foreach ($name in @($environment.Keys | Sort-Object -CaseSensitive)) { $expected += "$name=$($environment[$name])" }
        $expected += @('YURUNA_NONINTERACTIVE=1', 'YURUNA_DETACH_HANDSHAKE=', 'YURUNA_DETACH_HOP_PID=', 'YURUNA_DETACH_HOP_START=', 'YURUNA_DETACH_STDOUT=', 'YURUNA_DETACH_STDERR=',
            $script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner) + $arguments
        Assert-Equal -Expected ($expected -join "`n") -Actual ($create -join "`n") 'one argument per element, no shell'
        Assert-True ($environment.Count -ge 4) 'the recorded environment is on the command line'
        Assert-True ((@($create) -join ' ') -match 'YURUNA_LOG_LEVEL=Verbose') 'a recorded entry is passed through'
        $stdout = Get-Content -LiteralPath (Join-Path $tmux 'pids') | Select-Object -First 1
        Assert-Equal -Expected ([int]$stdout) -Actual ([int]$result.FinalPid) 'the pane pid is the final pid'
        Assert-NotNull $result.FinalStartTimeUnixMs
    }

    It 'falls back to the detached launch with no tmux on PATH or at a Homebrew location' {
        $case = New-ConsoleCase
        $env:PATH = (@($env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'tmux')) }) -join [System.IO.Path]::PathSeparator)
        $saved = & (Get-Module Test.InnerSpawn) { $script:ConsoleTmuxCandidate }
        & (Get-Module Test.InnerSpawn) { param($p) $script:ConsoleTmuxCandidate = $p } @((Join-Path $case.Private 'no-such/tmux'))
        try { $result = Start-ConsoleLaunch -Case $case } finally { & (Get-Module Test.InnerSpawn) { param($p) $script:ConsoleTmuxCandidate = $p } $saved }
        Assert-True $result.Launched "launched without a console ($($result.Reason) $($result.Detail))"
        Assert-Equal -Expected 'none' -Actual $result.Console
        Assert-Equal -Expected 'no-multiplexer' -Actual $result.ConsoleReason
        Assert-True (Wait-TestCondition { Test-Path -LiteralPath $case.Marker }) 'the worker ran'
        Assert-Equal -Expected ([string]$result.FinalPid) -Actual ([System.IO.File]::ReadAllText($case.Marker)) 'the final pid is the worker'
    }

    # A process that never ran `brew shellenv` (a controller session, a step
    # child) has no Homebrew prefix on its PATH, where macOS's tmux is.
    It 'uses a tmux at a Homebrew location when none is on PATH, and PATH first when both are' {
        $case = New-ConsoleCase
        $tmux = New-StandInTmux -Scenario created
        $env:PATH = (@($script:SavedEnvironment['PATH'] -split [System.IO.Path]::PathSeparator | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'tmux')) }) -join [System.IO.Path]::PathSeparator)
        $saved = & (Get-Module Test.InnerSpawn) { $script:ConsoleTmuxCandidate }
        $notExecutable = Join-Path $case.Private 'plain/tmux'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $notExecutable) -Force
        [System.IO.File]::WriteAllText($notExecutable, "#!/bin/sh`nexit 1`n")
        & (Get-Module Test.InnerSpawn) { param($p) $script:ConsoleTmuxCandidate = $p } @((Join-Path $case.Private 'absent/tmux'), $notExecutable, (Join-Path $tmux 'tmux'))
        try {
            $result = Start-ConsoleLaunch -Case $case
            Assert-True $result.Launched "launched ($($result.Reason) $($result.Detail))"
            Assert-Equal -Expected 'tmux' -Actual $result.Console 'the tmux at the fixed location made the console'
            Assert-Equal -Expected 'new-session,pipe-pane' -Actual (Get-StandInSubcommandList -Dir $tmux)
            $other = New-StandInTmux -Scenario created
            Assert-Equal -Expected (Join-Path $other 'tmux') -Actual (& (Get-Module Test.InnerSpawn) { Get-YurunaConsoleTmuxPath }) 'a tmux on PATH comes first'
        } finally { & (Get-Module Test.InnerSpawn) { param($p) $script:ConsoleTmuxCandidate = $p } $saved }
    }

    It 'falls back only when tmux confirms the session does not exist' {
        $case = New-ConsoleCase
        $tmux = New-StandInTmux -Scenario none
        $fallback = Start-ConsoleLaunch -Case $case
        Assert-True $fallback.Launched "launched ($($fallback.Reason))"
        Assert-Equal -Expected 'none' -Actual $fallback.Console
        Assert-Equal -Expected 'session-not-created' -Actual $fallback.ConsoleReason
        Assert-True (Wait-TestCondition { Test-Path -LiteralPath $case.Marker }) 'the worker ran without a console'
        Assert-Equal -Expected 'new-session,has-session' -Actual (Get-StandInSubcommandList -Dir $tmux)
        $existing = New-ConsoleCase
        $tmux2 = New-StandInTmux -Scenario exists
        $adopted = Start-ConsoleLaunch -Case $existing
        Assert-True $adopted.Launched
        Assert-Equal -Expected 'tmux' -Actual $adopted.Console 'a session tmux says exists is the console'
        $listed = Get-Content -LiteralPath (Join-Path $tmux2 'pids') | Select-Object -First 1
        Assert-Equal -Expected ([int]$listed) -Actual ([int]$adopted.FinalPid) 'its pane pid is read from tmux'
        Assert-False (Wait-TestCondition -TimeoutMilliseconds 3000 { Test-Path -LiteralPath $existing.Marker }) 'nothing is launched beside it'
    }

    It 'fails the attempt when tmux cannot say whether the session exists (<Scenario>)' -ForEach @(
        @{ Scenario = 'unknown' }
        @{ Scenario = 'odd' }
    ) {
        $case = New-ConsoleCase
        $null = New-StandInTmux -Scenario $Scenario
        $result = Start-ConsoleLaunch -Case $case
        Assert-False $result.Launched
        Assert-Equal -Expected 'console-state-unknown' -Actual $result.Reason
        Assert-False (Wait-TestCondition -TimeoutMilliseconds 3000 { Test-Path -LiteralPath $case.Marker }) 'no second runner beside a session that may exist'
    }

    It 'falls back when the socket path is too long, without asking tmux' {
        $case = New-ConsoleCase
        $tmux = New-StandInTmux -Scenario created
        $long = '/tmp/' + ('s' * 92) + '.sock'
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($long) -gt 100) 'fixture sanity: past the bind limit'
        $result = Start-ConsoleLaunch -Case $case -Socket $long
        Assert-True $result.Launched
        Assert-Equal -Expected 'none' -Actual $result.Console
        Assert-Equal -Expected 'socket-path-too-long' -Actual $result.ConsoleReason
        Assert-Equal -Expected 0 -Actual (Get-StandInCall -Dir $tmux).Count
        Assert-True (Wait-TestCondition { Test-Path -LiteralPath $case.Marker }) 'the worker ran without a console'
    }

    It 'quotes a console log path that contains a space or a quote for the pipe-pane shell' {
        $case = New-ConsoleCase
        $tmux = New-StandInTmux -Scenario created
        $log = Join-Path $case.Private "it's a log `$HOME.log"
        $result = Start-ConsoleLaunch -Case $case -LogPath $log
        Assert-True $result.Launched
        $calls = Get-StandInCall -Dir $tmux
        $pipe = @($calls | Where-Object { (Get-StandInSubcommand -Call $_) -eq 'pipe-pane' })[0]
        Assert-Equal -Expected "-S|$($case.Socket)|pipe-pane|-o|-t|=runner-test-1" -Actual (($pipe | Select-Object -First 6) -join '|')
        $command = $pipe[-1]
        Assert-Equal -Expected ("cat >> '" + $log.Replace("'", "'\''") + "'") -Actual $command
        $echo = & /bin/sh -c ($command.Replace('cat >> ', 'printf %s '))
        Assert-Equal -Expected $log -Actual $echo 'the shell reads the path back as one word, unexpanded'
        Assert-Equal -Expected 'ConsoleLogPath' -Actual (Start-ConsoleLaunch -Case $case -LogPath (Join-Path $script:ScratchBase 'outside.log')).Detail 'the log stays in the private folder'
        Assert-Equal -Expected 'ConsoleSessionName' -Actual (Start-ConsoleLaunch -Case $case -Session 'bad name').Detail
    }

    It 'reports the pane pid as the final pid and copies output until the readiness wait ends' {
        $tmux = New-StandInTmux -Scenario run
        $env:YURUNA_SG_RELAUNCH = '1'
        $repo = New-StandInRunnerRepo -Body @'
$seen = @{ pid = $PID; sg = [Environment]::GetEnvironmentVariable('YURUNA_SG_RELAUNCH'); nonInteractive = $env:YURUNA_NONINTERACTIVE; runtime = $env:YURUNA_RUNTIME_DIR; cwd = (Get-Location).Path }
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'pane.json'), ($seen | ConvertTo-Json))
'runner console line'
exit 1
'@
        $base = Join-Path $script:ScratchBase ('rr-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $root = Join-Path $base 'private'
        $runtime = Join-Path $base 'runtime'
        $work = Join-Path $root 'work'
        $null = New-Item -ItemType Directory -Path $root, $runtime, $work -Force
        $config = Join-Path $repo 'runner.config.yml'
        $written = Write-YurunaRunnerLaunchRecord -ScriptPath (Join-Path $repo 'test/Start-TestRunner.ps1') -BoundParameters ([ordered]@{}) -ResolvedConfigPath $config `
            -RuntimeDir $runtime -RepoRoot $repo -WorkingDirectory $repo -ForwardEnvironment @{ YURUNA_RUNTIME_DIR = $runtime } -AllowedEnvironmentName @('YURUNA_RUNTIME_DIR') `
            -PrivateRoot $root -Confirm:$false
        Assert-True $written.Written "fixture sanity: launch record ($($written.Reason))"
        $requestId = New-YurunaHostOperationRequestId
        $closed = Set-YurunaRunnerGate -State closed -RequestId $requestId -Attempt 1 -RuntimeDir $runtime -ExpectedGeneration '' -OwnerPid $PID -OwnerRole controller -PrivateRoot $root -Confirm:$false
        $socket = "/tmp/yhu-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).sock"
        $log = Join-Path $work 'console.1.log'
        $r = Invoke-YurunaRunnerHandoffResume -LaunchRecord (Read-YurunaRunnerLaunchRecord -RuntimeDir $runtime -PrivateRoot $root) -RequestId $requestId -Attempt 1 `
            -RuntimeDir $runtime -RepoRoot $repo -ExpectedGateGeneration $closed.Generation -Reclaimed @{} -PrivateDirectory $work `
            -Deadline (New-YurunaDeadline -TotalMilliseconds 90000) -PrivateRoot $root -ConsoleSocketPath $socket -ConsoleSessionName "runner-$requestId-1" -ConsoleLogPath $log -Confirm:$false
        Assert-Equal -Expected 'launch-failed' -Actual $r.Outcome -Because "a start that dies before acknowledging ends the wait at once ($($r.Reason))"
        Assert-Equal -Expected 'runner-exited' -Actual $r.Reason 'the pane pid is the process the wait watched'
        Assert-Equal -Expected 'tmux' -Actual $r.Console
        Assert-Equal -Expected 'recovery-pending' -Actual $r.GateState
        $pane = Get-Content -LiteralPath (Join-Path $repo 'test/pane.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected ([int]$pane['pid']) -Actual ([int]$r.ConsolePid) 'the reported pane pid is the runner itself: env execs pwsh'
        Assert-Null $pane['sg'] 'the libvirt re-exec marker never reaches the pane'
        Assert-Equal -Expected '1' -Actual $pane['nonInteractive']
        Assert-Equal -Expected $runtime -Actual $pane['runtime'] 'the recorded environment reaches the pane'
        Assert-Equal -Expected $repo -Actual $pane['cwd'] 'the recorded working directory'
        Assert-Equal -Expected 'new-session,pipe-pane,has-session,pipe-pane' -Actual (Get-StandInSubcommandList -Dir $tmux) 'the copy starts with the session and stops after the wait'
        $stop = (Get-StandInCall -Dir $tmux)[-1]
        Assert-Equal -Expected "-S|$socket|pipe-pane|-t|=runner-$requestId-1" -Actual ($stop -join '|') 'pipe-pane without a command ends the copy'
    }

    It 'leaves the launch byte-identical without console parameters' {
        $case = New-ConsoleCase
        $script:MockSeen = @{}
        Mock Invoke-BoundedNativeCommand -ModuleName Test.InnerSpawn {
            foreach ($key in $PesterBoundParameters.Keys) { $script:MockSeen[$key] = $PesterBoundParameters[$key] }
            @{ ExitCode = 0; StdOut = "999999`n"; StdErr = ''; Started = $true; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; ExitObserved = $true; ProcessId = 1 }
        }
        $seen = $script:MockSeen
        $result = Start-YurunaDetachedProcess -FilePath $case.Worker -ArgumentList @('-A', 'b c') -WorkingDirectory $case.Private -Environment @{ YURUNA_X = 'y' } `
            -StdOutPath '/dev/null' -StdErrPath (Join-Path $case.Private 'w.err') -PrivateDirectory $case.Private -Confirm:$false
        $body = 'set -m; cd -- "$1" || exit 97; detach_stdin=$2; shift 2; nohup "$@" <"$detach_stdin" >"$YURUNA_DETACH_STDOUT" 2>"$YURUNA_DETACH_STDERR" & echo $!'
        Assert-Equal -Expected 'bash' -Actual $seen['FilePath']
        $vector = @('-c', $body, 'yuruna-detach', $case.Private, '/dev/null', $script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $case.Worker, '-A', 'b c')
        Assert-Equal -Expected ($vector -join "`n") -Actual (@($seen['ArgumentList']) -join "`n")
        $environment = @($seen['Environment'].Keys | Sort-Object -CaseSensitive) -join ','
        Assert-Equal -Expected 'YURUNA_DETACH_HANDSHAKE,YURUNA_DETACH_HOP_PID,YURUNA_DETACH_HOP_START,YURUNA_DETACH_STDERR,YURUNA_DETACH_STDOUT,YURUNA_NONINTERACTIVE,YURUNA_X' -Actual $environment
        Assert-Equal -Expected 999999 -Actual ([int]$result.FinalPid)
        Assert-Equal -Expected 'Launched,Reason,LauncherPid,LauncherStartTimeUnixMs,FinalPid,FinalStartTimeUnixMs,Handshake,Platform,Detail' `
            -Actual (@($result.PSObject.Properties.Name) -join ',') 'no console fields without the console'
    }
}

Describe 'the console a started runner gets' {
    It 'is a window of its own on Windows and a tmux session elsewhere' {
        $module = Get-Module Test.HostUpdateStep
        if (-not $module) { $module = Import-Module (Join-Path $PSScriptRoot 'Test.HostUpdateStep.psm1') -PassThru -DisableNameChecking }
        $context = @{ ControllerRoot = '/c'; RequestId = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90'; Attempt = 3; WorkDirectory = '/w' }
        $windows = & $module { param($c) Get-HostUpdateStepConsoleArgument -Context $c -Platform Windows } $context
        Assert-Equal -Expected 'ConsoleWindow' -Actual (@($windows.Keys) -join ',')
        Assert-True $windows.ConsoleWindow
        $posix = & $module { param($c) Get-HostUpdateStepConsoleArgument -Context $c -Platform Posix } $context
        Assert-Equal -Expected 'ConsoleLogPath,ConsoleSessionName,ConsoleSocketPath' -Actual ((@($posix.Keys) | Sort-Object) -join ',')
        Assert-Equal -Expected 'runner-0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90-3' -Actual $posix.ConsoleSessionName
        Assert-Equal -Expected ([System.IO.Path]::Combine('/c', 'runner-console.sock')) -Actual $posix.ConsoleSocketPath
    }
}
