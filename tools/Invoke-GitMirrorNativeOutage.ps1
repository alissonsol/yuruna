<#PSScriptInfo
.VERSION 2026.10.22
.GUID 422479fd-5b54-4d62-b01f-3b7e571dd9dc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Measure the real outer runner recovering from six minutes without GitHub.
.DESCRIPTION
    The disposable target must already contain the frozen candidate, a complete
    valid host configuration and a runnable project. A live HTTP Git fixture
    changes transport state without changing child environment or any ref.
    Configuration, pause, recovery and streak observations come from the actual
    runner. A missing pause or missing recovery fails the drill.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$UpstreamsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$FrameworkTree,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'The wall-clock drill requires an explicitly disposable native host.' }
$root = Split-Path -Parent $PSScriptRoot
$target = [IO.Path]::GetFullPath($TargetRoot)
if ($target -ceq [IO.Path]::GetFullPath($root)) { throw 'The running candidate source cannot be the disposable target.' }
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Outage evidence already exists; preserve prior observations.' }
Import-Module (Join-Path $root 'test/modules/Test.SourceSelection.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'test/modules/Test.HostGit.psm1') -DisableNameChecking
$snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
if ($snapshot.context.mode -cne 'off') { throw 'The no-mirror outage drill requires explicit off mode in its disposable configuration.' }
if ((Get-GitMirrorRepository $snapshot.projectUrl) -cne 'alissonsol/yuruna-project') { throw 'The outage drill requires the prepared public project origin.' }
$initialHead = [string](& git -C $target rev-parse HEAD)
$initialTree = [string](& git -C $target rev-parse 'HEAD^{tree}')
if ($LASTEXITCODE -or $initialTree.Trim() -cne $FrameworkTree) { throw 'The disposable target does not contain the frozen candidate.' }
$upstreams = Get-Content -Raw -LiteralPath $UpstreamsPath | ConvertFrom-Json -AsHashtable
$repositories = @{}
$initialRefs = @{}
foreach ($entry in $upstreams.repositories) {
    $slug = Get-GitMirrorRepository $entry.canonicalUrl
    if ($slug -notin @('alissonsol/yuruna', 'alissonsol/yuruna-project') -or $repositories.ContainsKey($slug)) { throw 'Unexpected prepared origin identity.' }
    $repositories[$slug] = $entry.localPath
    $initialRefs[$slug] = ([string](& git -C $entry.localPath rev-parse refs/heads/main)).Trim()
    if ($LASTEXITCODE -or $initialRefs[$slug] -cne $entry.candidateCommit) { throw 'Prepared origin changed before the outage.' }
}
if ($repositories.Count -ne 2 -or $initialHead.Trim() -cne $initialRefs['alissonsol/yuruna']) { throw 'The wall-clock drill requires both frozen public origins and the selected candidate commit.' }
$work = "$output.files"
if (Test-Path -LiteralPath $work) { throw 'Outage working evidence already exists.' }
[IO.Directory]::CreateDirectory($work) | Out-Null
$runtime = Join-Path $work runtime
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$control = Join-Path $work control.json
$traffic = Join-Path $work traffic.json
$fixtureConfig = Join-Path $work fixture.json
$runnerLog = Join-Path $work runner.stdout.log
$runnerError = Join-Path $work runner.stderr.log
$runner = $null; $relay = $null; $outStream = $null; $errorStream = $null
$outCopy = $null; $errorCopy = $null; $relayErrors = $null
$configHash = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash
$observations = [Collections.Generic.List[object]]::new()
$result = [ordered]@{
    schema = 'yuruna.git-mirror.native-outage/v1'; passed = $false; failure = ''
    outageSeconds = 0; recoverySeconds = 0; preambleStreakBefore = 0; preambleStreakAfter = 0
    originalCommit = $initialHead.Trim(); finalCommit = ''; refsUnchanged = $false
    configPreserved = $false; observations = @(); traffic = $null
}

function Set-NativeOutageMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only this explicitly disposable drill control file.')]
    [CmdletBinding()]
    param([ValidateSet('healthy', 'reset')][string]$Mode)
    [IO.File]::WriteAllText("$control.next", (ConvertTo-Json @{ mode = $Mode } -Compress))
    [IO.File]::Move("$control.next", $control, $true)
}

function New-NativeOutageLogStream {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates only an owned drill log, refusing an existing file.')]
    [CmdletBinding()]
    [OutputType([IO.FileStream])]
    param([Parameter(Mandatory)][string]$Path)
    # A live reader must see short diagnostics before the child exits.
    return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite, 1, [IO.FileOptions]::Asynchronous)
}

function Read-NativeOutageLog {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-NativeRunnerState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $record = @{ state = ''; since = ''; failureClass = ''; streak = 0; observedAt = [DateTimeOffset]::UtcNow.ToString('o') }
    try {
        $state = Get-Content -Raw -LiteralPath (Join-Path $runtime runner.state.json) -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        $record.state = [string]$state.current
        if ($state.ContainsKey('since')) { $record.since = [string]$state.since }
        $status = Get-Content -Raw -LiteralPath (Join-Path $runtime status.json) -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if ($status.runnerFault) { $record.failureClass = [string]$status.runnerFault.failureClass }
    } catch { Write-Verbose $_.Exception.Message }
    $streakPath = Join-Path $runtime runner.preambleStall.json
    if (Test-Path -LiteralPath $streakPath) {
        $streak = Get-Content -Raw -LiteralPath $streakPath | ConvertFrom-Json -AsHashtable
        $record.streak = [int]$streak.streak
    }
    return $record
}

try {
    Set-NativeOutageMode healthy
    [IO.File]::WriteAllText($fixtureConfig, (ConvertTo-Json @{ repositories = $repositories; controlPath = $control; evidencePath = $traffic }))
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command python3 -CommandType Application).Source)
    foreach ($argument in @((Join-Path $PSScriptRoot git_mirror_outage_fixture.py), '--config', $fixtureConfig, '--exit-on-stdin-close')) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
    $relay = [Diagnostics.Process]::Start($start)
    $relayErrors = $relay.StandardError.ReadToEndAsync()
    $ready = $relay.StandardOutput.ReadLineAsync()
    if (-not $ready.Wait(10000) -or -not $ready.Result) { throw 'The controlled Git origin did not become ready.' }
    $endpoint = $ready.Result | ConvertFrom-Json -AsHashtable
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $target 'test/Start-TestRunner.ps1'),
            '-ConfigPath', [IO.Path]::GetFullPath($ConfigPath), '-NoStatusService', '-NoGitPull', '-logLevel', 'Verbose', '-Verbose')) { $start.ArgumentList.Add($argument) }
    $start.WorkingDirectory = $target
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
    $start.Environment['YURUNA_RUNTIME_DIR'] = $runtime
    $start.Environment['YURUNA_LOG_DIR'] = Join-Path $work logs
    $start.Environment['YURUNA_GITHUB_PROBE_ENDPOINT'] = $endpoint.probeEndpoint
    $count = if ($start.Environment['GIT_CONFIG_COUNT']) { [int]$start.Environment['GIT_CONFIG_COUNT'] } else { 0 }
    # Replace only fixture URL rewrite keys in the child. Other process Git
    # settings survive, and no host-level or global Git file is changed.
    for ($i = 0; $i -lt $count; $i++) {
        $key = $start.Environment["GIT_CONFIG_KEY_$i"]
        $value = $start.Environment["GIT_CONFIG_VALUE_$i"]
        if ($key -match '^url\..+\.insteadOf$' -and $value.StartsWith('https://github.com/', [StringComparison]::Ordinal)) {
            $suffix = $value.Substring('https://github.com/'.Length)
            $start.Environment["GIT_CONFIG_KEY_$i"] = "url.$($endpoint.baseURL.TrimEnd('/'))/$suffix.insteadOf"
        }
    }
    foreach ($pair in @(@("url.$($endpoint.baseURL.TrimEnd('/'))/.insteadOf", 'https://github.com/'),
            @('http.lowSpeedLimit', '1'), @('http.lowSpeedTime', '1'), @('credential.helper', ''))) {
        $start.Environment["GIT_CONFIG_KEY_$count"] = $pair[0]
        $start.Environment["GIT_CONFIG_VALUE_$count"] = $pair[1]
        $count++
    }
    $start.Environment['GIT_CONFIG_COUNT'] = [string]$count
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $start.Environment.Remove('GH_TOKEN') | Out-Null
    $start.Environment.Remove('GITHUB_TOKEN') | Out-Null
    $start.Environment['GH_CONFIG_DIR'] = Join-Path $work empty-gh
    [IO.Directory]::CreateDirectory($start.Environment['GH_CONFIG_DIR']) | Out-Null
    $outStream = New-NativeOutageLogStream -Path $runnerLog
    $errorStream = New-NativeOutageLogStream -Path $runnerError
    $runner = [Diagnostics.Process]::Start($start)
    $runner.StandardInput.Close()
    $outCopy = $runner.StandardOutput.BaseStream.CopyToAsync($outStream)
    $errorCopy = $runner.StandardError.BaseStream.CopyToAsync($errorStream)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(180)
    do {
        if ($runner.HasExited) { throw 'The real outer runner exited before starting its first cycle.' }
        $state = Read-NativeRunnerState
        if ($state.state -ceq 'in-cycle') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if ($state.state -cne 'in-cycle') { throw 'The real outer runner did not start a cycle within three minutes.' }
    $result.preambleStreakBefore = $state.streak
    Set-NativeOutageMode reset
    $outageStarted = [DateTimeOffset]::UtcNow
    $pauseObserved = $false
    do {
        if ($runner.HasExited) { throw 'The real outer runner exited during the outage.' }
        $state = Read-NativeRunnerState
        if ($observations.Count -eq 0 -or $observations[-1].state -cne $state.state -or
            $observations[-1].failureClass -cne $state.failureClass) { $observations.Add($state) }
        if ($state.state -ceq 'paused' -and $state.failureClass -ceq 'config_gate_failed') { $pauseObserved = $true }
        if ($state.streak -ne $result.preambleStreakBefore) { throw 'The network gate outage changed the preamble-stall streak.' }
        Start-Sleep -Milliseconds 250
    } while (([DateTimeOffset]::UtcNow - $outageStarted).TotalSeconds -lt 360)
    if (-not $pauseObserved) { throw 'No actual configuration-gate network hold was observed during six minutes.' }
    # Restore during a new hold, not at the 120+240-second natural boundary.
    # Otherwise normal pause expiry could masquerade as source recovery.
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(180)
    do {
        if ($runner.HasExited) { throw 'The real outer runner exited before the recovery observation.' }
        $state = Read-NativeRunnerState
        if ($state.state -ceq 'paused' -and $state.failureClass -ceq 'config_gate_failed' -and $state.since -and
            [DateTimeOffset]::Parse($state.since) -ge $outageStarted.AddSeconds(360)) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if ($state.state -cne 'paused' -or -not $state.since -or [DateTimeOffset]::Parse($state.since) -lt $outageStarted.AddSeconds(360)) {
        throw 'A fresh network hold was not observed after the six-minute outage.'
    }
    $result.outageSeconds = ([DateTimeOffset]::UtcNow - $outageStarted).TotalSeconds
    $priorLog = Read-NativeOutageLog -Path $runnerLog
    $priorRecoveryCount = [regex]::Matches($priorLog, [regex]::Escape('Repository access recovered; ending the transient network hold.')).Count
    Set-NativeOutageMode healthy
    $restored = [DateTimeOffset]::UtcNow
    $deadline = $restored.AddSeconds(60)
    $recovered = $false
    do {
        if ($runner.HasExited) { throw 'The real outer runner exited before source recovery.' }
        $state = Read-NativeRunnerState
        $log = Read-NativeOutageLog -Path $runnerLog
        if ([regex]::Matches($log, [regex]::Escape('Repository access recovered; ending the transient network hold.')).Count -gt $priorRecoveryCount) {
            $recovered = $true
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $result.recoverySeconds = ([DateTimeOffset]::UtcNow - $restored).TotalSeconds
    $result.preambleStreakAfter = $state.streak
    $observations.Add($state)
    if (-not $recovered -or $state.streak -ne $result.preambleStreakBefore) { throw 'The actual network hold did not recover within the thirty-second poll plus bounded probe.' }
    $result.passed = $true
} catch { $result.failure = $_.Exception.Message }
finally {
    Set-NativeOutageMode healthy
    if ($runner) {
        if (-not $runner.HasExited) { $runner.Kill($true); $null = $runner.WaitForExit(5000) }
        if ($outCopy) { $null = $outCopy.Wait(2000) }
        if ($errorCopy) { $null = $errorCopy.Wait(2000) }
        $runner.Dispose()
    }
    if ($relay) {
        $relay.StandardInput.Close()
        if (-not $relay.WaitForExit(5000)) { $relay.Kill($true); $null = $relay.WaitForExit(5000) }
        if ($relayErrors -and $relayErrors.Wait(2000) -and $relayErrors.Result) {
            [IO.File]::WriteAllText((Join-Path $work relay.stderr.log), $relayErrors.Result)
        }
        $relay.Dispose()
    }
    if ($outStream) { $outStream.Dispose() }
    if ($errorStream) { $errorStream.Dispose() }
    $result.finalCommit = ([string](& git -C $target rev-parse HEAD)).Trim()
    $result.refsUnchanged = $result.finalCommit -ceq $result.originalCommit
    foreach ($slug in $initialRefs.Keys) {
        $head = ([string](& git -C $repositories[$slug] rev-parse refs/heads/main)).Trim()
        if ($LASTEXITCODE -or $head -cne $initialRefs[$slug]) { $result.refsUnchanged = $false }
    }
    $result.configPreserved = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash -ceq $configHash
    if (-not $result.refsUnchanged -or -not $result.configPreserved) {
        $result.passed = $false; $result.failure += ' A repository ref or the operator configuration changed.'
    }
    if (Test-Path -LiteralPath $traffic) { $result.traffic = Get-Content -Raw -LiteralPath $traffic | ConvertFrom-Json -AsHashtable }
    if (-not $result.traffic -or $result.traffic.resetRequests -lt 1 -or $result.traffic.completedRequests -lt 1) {
        $result.passed = $false; $result.failure += ' Real failed and successful Git requests were not both observed.'
    }
    $result.observations = $observations.ToArray()
    [IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 15) + "`n", [Text.UTF8Encoding]::new($false))
}
if (-not $result.passed) { throw $result.failure }
Write-Output $output
