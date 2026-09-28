<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4227f6df-0fe0-4a7d-b85b-64c7c2f5ede7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner integration host-refresh pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    The real runner chain -- Start-TestRunner.ps1, Invoke-TestCycleRunner.ps1
    and the inner -- across three real processes: every operator option
    reaching the inner, a refresh resume that keeps the operator's controls
    and admits only its preflight chain, and the real inner's preflight.
.DESCRIPTION
    Each case runs a copy of the working tree under a private directory, with
    a private HOME (so the private state root is the test's own), a private
    runtime and log directory, and stand-in git and sudo on a private PATH.
    The copy's inner is a capture stub whose param block is the real inner's
    own, so a drift in that block is caught; it records what it was given and
    parks until the test releases it. The real-inner case uses an unmodified
    copy and ends the handoff as recovery-pending, so no ordinary cycle -- and
    no VM command -- can start. The suite kills only the process trees it
    started.
#>

BeforeDiscovery {
    $script:CanRunChain = $IsLinux -and [bool](Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)
    $script:KvmHost = $false
    if ($script:CanRunChain) {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostDetection.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $script:KvmHost = ((Get-HostType) -eq 'host.ubuntu.kvm') -and [bool](Get-Command virsh -CommandType Application -ErrorAction SilentlyContinue)
    }
}

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $script:Here
    $script:Pwsh = [Environment]::ProcessPath
    $script:Started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:RequestId = '6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f'

    function New-ChainTree {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: copies the working tree into a private temp directory.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([switch]$StubInner)
        $base = New-YurunaTestTempDir -Prefix 'yrn-chain'
        $tree = Join-Path $base 'tree'
        Push-Location -LiteralPath $script:RepoRoot
        try {
            $files = @(git ls-files --cached --others --exclude-standard -- automation globalization host 'test/modules' 'test/*.ps1' 'test/*.yml*' 'test/sequences' 'test/status' 'test/service' VERSION 2>$null)
        } finally { Pop-Location }
        foreach ($relative in $files) {
            $source = Join-Path $script:RepoRoot $relative
            if (-not [System.IO.File]::Exists($source)) { continue }
            $target = Join-Path $tree $relative
            $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [System.IO.File]::Copy($source, $target, $true)
        }
        $f = @{
            Base = $base; Tree = $tree; Home = (Join-Path $base 'home'); Runtime = (Join-Path $base 'runtime'); Log = (Join-Path $base 'log')
            Bin = (Join-Path $base 'bin'); GitLog = (Join-Path $base 'git.log'); Config = (Join-Path $base 'custom.config.yml')
        }
        $null = New-Item -ItemType Directory -Path $f.Home, $f.Runtime, $f.Log, $f.Bin -Force
        Copy-Item -LiteralPath (Join-Path $tree 'test/test.config.yml.template') -Destination $f.Config
        [System.IO.File]::WriteAllText((Join-Path $f.Bin 'git'), "#!/bin/bash`nprintf '%s\n' ""`$*"" >> '$($f.GitLog)'`nexit 0`n")
        [System.IO.File]::WriteAllText((Join-Path $f.Bin 'sudo'), "#!/bin/bash`nexit 0`n")
        foreach ($name in @('git', 'sudo')) { [IO.File]::SetUnixFileMode((Join-Path $f.Bin $name), [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
        if ($StubInner) {
            $innerPath = Join-Path $tree 'test/modules/Invoke-TestRunnerInnerLoop.ps1'
            $real = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/modules/Invoke-TestRunnerInnerLoop.ps1')
            $body = @'

$capture = Join-Path $env:YURUNA_RUNTIME_DIR ('stub-capture.' + [DateTime]::UtcNow.Ticks + '.json')
$bound = [ordered]@{}
foreach ($key in $PSBoundParameters.Keys) {
    $value = $PSBoundParameters[$key]
    $bound[$key] = if ($value -is [System.Management.Automation.SwitchParameter]) { $value.IsPresent } else { $value }
}
[ordered]@{
    bound          = $bound
    configPath     = $ConfigPath
    pid            = $PID
    parentPid      = (Get-Process -Id $PID).Parent.Id
    relaunch       = $env:YURUNA_RUNNER_RELAUNCH
    nonInteractive = $env:YURUNA_NONINTERACTIVE
    generation     = $env:YURUNA_CYCLE_GENERATION
    preflight      = $env:YURUNA_REFRESH_PREFLIGHT
    token          = $env:YURUNA_REFRESH_HANDOFF_TOKEN
    barrier        = $env:YURUNA_REFRESH_BARRIER
    commandLine    = @([Environment]::GetCommandLineArgs())
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $capture -Encoding utf8NoBOM
$release = Join-Path $env:YURUNA_RUNTIME_DIR 'stub.release'
$until = [DateTime]::UtcNow.AddSeconds(240)
while (-not (Test-Path -LiteralPath $release) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
Remove-Item -LiteralPath $release -Force -ErrorAction SilentlyContinue
exit 0
'@
            [System.IO.File]::WriteAllText($innerPath, "#requires -version 7`n" + $real.ParamBlock.Extent.Text + "`n" + $body)
        }
        return $f
    }

    function Start-ChainRunner {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts the copied runner under private state; the suite kills its tree.')]
        [CmdletBinding()]
        [OutputType([System.Diagnostics.Process])]
        param([hashtable]$F, [string[]]$Arguments, [switch]$Relative)
        # -Relative is the documented launch: from the checkout root, naming
        # the script by a relative path.
        $scriptArgument = if ($Relative) { 'test/Start-TestRunner.ps1' } else { Join-Path $F.Tree 'test/Start-TestRunner.ps1' }
        $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/bash')
        foreach ($a in @('-c', 'exec "$@" >"$CHAIN_OUT" 2>"$CHAIN_ERR" </dev/null', 'chain', $script:Pwsh, '-NoProfile', '-NonInteractive', '-File',
            $scriptArgument) + $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = if ($Relative) { $F.Tree } else { $F.Base }
        $psi.Environment['PATH'] = "$($F.Bin):$(Split-Path -Parent $script:Pwsh):$($env:PATH)"
        $psi.Environment['HOME'] = $F.Home
        $psi.Environment['PSModulePath'] = $env:PSModulePath
        $psi.Environment['YURUNA_SG_RELAUNCH'] = '1'
        $psi.Environment['YURUNA_RUNTIME_DIR'] = $F.Runtime
        $psi.Environment['YURUNA_LOG_DIR'] = $F.Log
        $psi.Environment['CHAIN_OUT'] = Join-Path $F.Base "runner.$([guid]::NewGuid().ToString('N')).out"
        $psi.Environment['CHAIN_ERR'] = Join-Path $F.Base "runner.$([guid]::NewGuid().ToString('N')).err"
        foreach ($name in @('YURUNA_CONFIG_PATH', 'YURUNA_RUNNER_RELAUNCH', 'YURUNA_CACHING_PROXY_SERVICE_IP', 'YURUNA_STATUS_PUBLIC_URL')) { [void]$psi.Environment.Remove($name) }
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Started.Add($process)
        return $process
    }

    function Wait-Capture {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([hashtable]$F, [int]$Index = 0, [int]$Seconds = 180, [System.Diagnostics.Process]$Runner)
        $until = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $until) {
            $files = @(Get-ChildItem -LiteralPath $F.Runtime -Filter 'stub-capture.*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($files.Count -gt $Index) {
                Start-Sleep -Milliseconds 200
                return (Get-Content -LiteralPath $files[$Index].FullName -Raw | ConvertFrom-Json)
            }
            if ($Runner -and $Runner.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        return $null
    }

    function Get-ChainDiagnostic {
        [CmdletBinding()]
        [OutputType([string])]
        param([hashtable]$F)
        $text = @(Get-ChildItem -LiteralPath $F.Base -Filter 'runner.*' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"
        $outer = Join-Path $F.Runtime 'outer.log'
        if (Test-Path -LiteralPath $outer) { $text += "`n" + (Get-Content -LiteralPath $outer -Raw) }
        $plain = ($text -replace "`e\[[0-9;?]*[A-Za-z]", '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        if ($plain.Length -gt 3000) { $plain = $plain.Substring($plain.Length - 3000) }
        return $plain
    }

    function Initialize-ChainPrivateRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates the private root under the test HOME with owner-only modes.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([hashtable]$F)
        $root = Join-Path $F.Home '.yuruna/host-refresh'
        $null = New-Item -ItemType Directory -Path $root -Force
        foreach ($dir in @((Join-Path $F.Home '.yuruna'), $root)) { [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
        return $root
    }

    function New-ChainHandoff {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: closes the test gate and issues a handoff on it.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([hashtable]$F, [string]$Root, [hashtable]$Reclaimed = @{})
        $gate = Get-YurunaRefreshGateState -RuntimeDir $F.Runtime -PrivateRoot $Root
        $closed = Set-YurunaRefreshGate -State closed -RequestId $script:RequestId -Attempt 1 -RuntimeDir $F.Runtime `
            -ExpectedGeneration ([string]$gate.Generation) -Reclaimed $Reclaimed -PrivateRoot $Root -Confirm:$false
        if (-not $closed.Written) { throw "gate not closed: $($closed.Reason)" }
        $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $F.Runtime -Purpose new-outer `
            -ExpiresInMilliseconds 600000 -ExpectedGeneration $closed.Generation -Reclaimed $Reclaimed -PrivateRoot $Root -Confirm:$false
        if (-not $token.Issued) { throw "handoff not issued: $($token.Reason)" }
        return $token
    }

    function Start-PwshStandIn {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a disposable stand-in process the suite kills in AfterAll.')]
        [CmdletBinding()]
        [OutputType([System.Diagnostics.Process])]
        param([string]$Command)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($a in @('-NoProfile', '-NonInteractive', '-Command', $Command)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Started.Add($process)
        return $process
    }

    function Get-DeadProcessIdentity {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param()
        $p = Start-PwshStandIn -Command 'Start-Sleep -Milliseconds 300'
        $start = $p.StartTime.ToUniversalTime()
        $p.WaitForExit()
        return @{ Pid = $p.Id; Start = $start }
    }
}

AfterAll {
    foreach ($p in @($script:Started)) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch { $null = $_ } }
}

Describe 'Case A: every operator option crosses outer -> cycle -> inner' -Skip:(-not $script:CanRunChain) {
    It 'binds all six options in the real inner param block, with no pull and no status service' {
        $f = New-ChainTree -StubInner
        $runner = $null
        try {
            $runner = Start-ChainRunner -F $f -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService', '-NoConfigGate', '-CycleDelaySeconds', '7', '-logLevel', 'Debug')
            $seen = Wait-Capture -F $f -Runner $runner
            Assert-NotNull $seen (Get-ChainDiagnostic -F $f)
            Assert-Equal -Expected $f.Config -Actual $seen.configPath
            foreach ($name in @('NoGitPull', 'NoStatusService', 'NoConfigGate')) {
                Assert-True ([bool]$seen.bound.$name) "$name reached the inner"
            }
            Assert-Equal -Expected 7 -Actual ([int]$seen.bound.CycleDelaySeconds)
            Assert-Equal -Expected 'Debug' -Actual $seen.bound.logLevel
            Assert-Equal -Expected '1' -Actual $seen.relaunch
            Assert-Equal -Expected '1' -Actual $seen.nonInteractive
            Assert-True (@($seen.commandLine) -contains '-NonInteractive') 'the inner runs -NonInteractive'
            Assert-Match -Pattern '^[0-9a-f]{32}:1$' -Actual ([string]$seen.generation)
            Assert-True ([string]::IsNullOrEmpty($seen.preflight)) 'an ordinary cycle carries no preflight'
            $cycleRecord = Get-Content -LiteralPath (Join-Path $f.Runtime 'runner.cycle.json') -Raw | ConvertFrom-Json
            Assert-Equal -Expected $seen.parentPid -Actual $cycleRecord.pid -Because 'runner.cycle.json names the inner''s parent'
            Assert-Equal -Expected $runner.Id -Actual $cycleRecord.outerPid
            Assert-Equal -Expected "$($runner.Id)" -Actual (Get-Content -LiteralPath (Join-Path $f.Runtime 'runner.pid') -Raw).Trim()
            $gitCalls = if (Test-Path -LiteralPath $f.GitLog) { Get-Content -LiteralPath $f.GitLog -Raw } else { '' }
            Assert-False ($gitCalls -match '(^|\s)(pull|fetch)(\s|$)') "no pull or fetch under -NoGitPull: $gitCalls"
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'server.pid')) 'no status service under -NoStatusService'
            $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $f.Runtime -PrivateRoot (Join-Path $f.Home '.yuruna/host-refresh')
            Assert-True $launch.Valid "launch record ($($launch.Reason))"
            $p = $launch.Record['parameters']
            Assert-Equal -Expected $f.Config -Actual $p['ConfigPath']
            Assert-True ($p['NoGitPull'] -and $p['NoStatusService'] -and $p['NoConfigGate']) 'switches recorded'
            Assert-Equal -Expected 7 -Actual $p['CycleDelaySeconds']
            Assert-Equal -Expected 'Debug' -Actual $p['logLevel']
        } finally {
            if ($runner -and -not $runner.HasExited) { $runner.Kill($true) }
            Remove-YurunaTestTempDir $f.Base
        }
    }
}

Describe 'Case A2: a runner started by a relative path from its checkout is that checkout''s' -Skip:(-not $script:CanRunChain) {
    It 'classifies the documented `pwsh test/Start-TestRunner.ps1` launch as AliveOwned and plans its reclaim' {
        $f = New-ChainTree -StubInner
        $runner = $null
        try {
            $root = Initialize-ChainPrivateRoot -F $f
            $runner = Start-ChainRunner -F $f -Relative -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService', '-NoConfigGate')
            $seen = Wait-Capture -F $f -Runner $runner
            Assert-NotNull $seen (Get-ChainDiagnostic -F $f)
            $commandLine = ((Get-Content -LiteralPath "/proc/$($runner.Id)/cmdline" -Raw) -replace [char]0, ' ').Trim()
            Assert-Match -Pattern ' test/Start-TestRunner\.ps1( |$)' -Actual $commandLine -Because 'the runner was started by a relative path'
            $snapshot = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $f.Tree -PrivateRoot $root
            Assert-Equal -Expected 'AliveOwned' -Actual $snapshot.Outer.State -Because "outer: $($snapshot.Outer.Reason)"
            Assert-Equal -Expected 'AliveOwned' -Actual $snapshot.Cycle.State -Because "cycle: $($snapshot.Cycle.Reason)"
            $plan = New-YurunaRunnerReclaimPlan -Snapshot $snapshot
            Assert-True $plan.Reclaimable "no refusal ($(@($plan.Refusals | ForEach-Object { "$($_.Role):$($_.Reason)" }) -join ','))"
            Assert-True (@($plan.Roots | Where-Object { $_.Role -eq 'outer' -and $_.Pid -eq $runner.Id }).Count -eq 1) 'the outer is a reclaim root'
        } finally {
            if ($runner -and -not $runner.HasExited) { $runner.Kill($true) }
            Remove-YurunaTestTempDir $f.Base
        }
    }
}

Describe 'Case B: a refresh resume keeps the controls and admits only its preflight chain' -Skip:(-not $script:CanRunChain) {
    It 'removes only the reclaimed runner record, runs the preflight with the token, then the barrier cycle after release' {
        $f = New-ChainTree -StubInner
        $runner = $null
        try {
            $root = Initialize-ChainPrivateRoot -F $f
            $dead = Get-DeadProcessIdentity
            Set-Content -LiteralPath (Join-Path $f.Runtime 'runner.pid') -Value "$($dead.Pid)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $f.Runtime 'runner.start') -Value $dead.Start.ToString('o') -Encoding utf8NoBOM
            foreach ($name in @('control.cycle-pause', 'control.lab-hold')) { Set-Content -LiteralPath (Join-Path $f.Runtime $name) -Value 'x' -Encoding utf8NoBOM }
            $token = New-ChainHandoff -F $f -Root $root -Reclaimed @{ outer = @{ pid = $dead.Pid; startTimeUnixMs = ([DateTimeOffset]$dead.Start).ToUnixTimeMilliseconds() } }
            $runner = Start-ChainRunner -F $f -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService', '-NoConfigGate',
                '-RefreshResume', '-RefreshHandoffToken', $token.TokenId)
            $preflight = Wait-Capture -F $f -Runner $runner
            Assert-NotNull $preflight (Get-ChainDiagnostic -F $f)
            Assert-Equal -Expected '1' -Actual $preflight.preflight
            Assert-Equal -Expected $token.TokenId -Actual $preflight.token
            Assert-Equal -Expected "$($runner.Id)" -Actual (Get-Content -LiteralPath (Join-Path $f.Runtime 'runner.pid') -Raw).Trim() -Because 'the dead generation was removed and replaced'
            foreach ($name in @('control.cycle-pause', 'control.lab-hold')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$name survived the resumed startup"
            }
            $gate = Get-YurunaRefreshGateState -RuntimeDir $f.Runtime -PrivateRoot $root
            $done = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict released -ExpectedGeneration ([string]$gate.Generation) -PrivateRoot $root -Confirm:$false
            Assert-True $done.Completed "handoff completed ($($done.Reason))"
            Set-Content -LiteralPath (Join-Path $f.Runtime 'stub.release') -Value 'go' -Encoding utf8NoBOM
            $barrier = Wait-Capture -F $f -Index 1 -Runner $runner
            Assert-NotNull $barrier (Get-ChainDiagnostic -F $f)
            Assert-Equal -Expected $script:RequestId -Actual $barrier.barrier -Because 'the first ordinary cycle carries the barrier'
            Assert-True ([string]::IsNullOrEmpty($barrier.preflight)) 'no preflight after the release'
            foreach ($name in @('control.cycle-pause', 'control.lab-hold')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$name is still left for its consumer"
            }
        } finally {
            if ($runner -and -not $runner.HasExited) { $runner.Kill($true) }
            Remove-YurunaTestTempDir $f.Base
        }
    }
    It 'refuses to take over a live runner record, acknowledging the failure, and leaves that runner alive' {
        $f = New-ChainTree -StubInner
        $standIn = $null
        try {
            $root = Initialize-ChainPrivateRoot -F $f
            $standIn = Start-PwshStandIn -Command 'Start-Sleep -Seconds 120'
            Start-Sleep -Milliseconds 500
            Set-Content -LiteralPath (Join-Path $f.Runtime 'runner.pid') -Value "$($standIn.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $f.Runtime 'runner.start') -Value $standIn.StartTime.ToUniversalTime().ToString('o') -Encoding utf8NoBOM
            # The live runner's own state, mid-cycle: a refused resume must not
            # rewrite it or narrate a crash it never had.
            $statePath = Join-Path $f.Runtime 'runner.state.json'
            $liveState = '{"current":"in-cycle","since":"2026-09-25T00:00:00Z","runId":"live-runner","writerPid":' + $standIn.Id + ',"history":[]}'
            [System.IO.File]::WriteAllText($statePath, $liveState)
            $token = New-ChainHandoff -F $f -Root $root
            $runner = Start-ChainRunner -F $f -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService', '-NoConfigGate',
                '-RefreshResume', '-RefreshHandoffToken', $token.TokenId)
            Assert-True ($runner.WaitForExit(180000)) 'the resumed runner exits'
            Assert-Equal -Expected 1 -Actual $runner.ExitCode -Because (Get-ChainDiagnostic -F $f)
            $ack = Get-Content -LiteralPath (Join-Path $root "runner-handoff.$($token.TokenId).ack.json") -Raw | ConvertFrom-Json
            Assert-Equal -Expected 'failed' -Actual $ack.state
            Assert-Equal -Expected 'other-runner' -Actual $ack.failureReason
            Assert-False $standIn.HasExited 'the live runner was not touched'
            Assert-Equal -Expected "$($standIn.Id)" -Actual (Get-Content -LiteralPath (Join-Path $f.Runtime 'runner.pid') -Raw).Trim() -Because 'its record was not deleted'
            Assert-Equal -Expected $liveState -Actual ([System.IO.File]::ReadAllText($statePath)) -Because 'the live runner''s state was not reset'
        } finally {
            if ($standIn -and -not $standIn.HasExited) { $standIn.Kill() }
            Remove-YurunaTestTempDir $f.Base
        }
    }
}

Describe 'Case D: a startup refusal ends the launch record cleanly' -Skip:(-not $script:CanRunChain) {
    It 'marks the record ended with a clean exit when the config gate refuses the start' {
        $f = New-ChainTree -StubInner
        $runner = $null
        try {
            $root = Initialize-ChainPrivateRoot -F $f
            # A stand-in gate script that refuses every configuration.
            [System.IO.File]::WriteAllText((Join-Path $f.Tree 'test/Test-Config.ps1'),
                "[CmdletBinding()]`nparam([switch]`$SkipSend, [string]`$ConfigPath, [switch]`$ExpectStorageConfigured)`nexit 1`n")
            $runner = Start-ChainRunner -F $f -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService')
            Assert-True ($runner.WaitForExit(180000)) 'the refused runner exits'
            Assert-Equal -Expected 1 -Actual $runner.ExitCode -Because (Get-ChainDiagnostic -F $f)
            $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $f.Runtime -PrivateRoot $root
            Assert-True $launch.Valid "launch record ($($launch.Reason))"
            Assert-Equal -Expected $runner.Id -Actual ([int]$launch.Record['runner']['pid']) -Because 'the record is this runner''s'
            Assert-True ([bool]$launch.Record['cleanExit']) 'a refusal is an orderly exit, not a crash to restart'
            Assert-NotNull $launch.Record['endedUtc']
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $f.Runtime -Filter 'stub-capture.*.json' -ErrorAction SilentlyContinue).Count -Because 'no cycle ran'
        } finally {
            if ($runner -and -not $runner.HasExited) { $runner.Kill($true) }
            Remove-YurunaTestTempDir $f.Base
        }
    }
}

Describe 'Case C: the real inner runs only its preflight and acknowledges it' -Skip:(-not $script:KvmHost) {
    It 'acknowledges from the final ancestry, parks, and exits without any ordinary cycle work' {
        $f = New-ChainTree
        $runner = $null
        try {
            $root = Initialize-ChainPrivateRoot -F $f
            $token = New-ChainHandoff -F $f -Root $root
            $runner = Start-ChainRunner -F $f -Arguments @('-ConfigPath', $f.Config, '-NoGitPull', '-NoStatusService', '-NoConfigGate',
                '-RefreshResume', '-RefreshHandoffToken', $token.TokenId)
            $ready = Wait-YurunaRunnerReadiness -TokenId $token.TokenId -Deadline (New-YurunaDeadline -TotalMilliseconds 240000) -PrivateRoot $root
            Assert-True ($ready.State -in @('ready', 'failed')) "acknowledged: $($ready.State) $($ready.Reason) $(Get-ChainDiagnostic -F $f)"
            if ($ready.State -eq 'failed') {
                Assert-Match -Pattern '^probe-' -Actual ([string]$ready.Reason) -Because 'only the host probe itself may fail here'
            }
            # Recovery-pending, never released: the chain must not reach an
            # ordinary cycle on this host.
            $gate = Get-YurunaRefreshGateState -RuntimeDir $f.Runtime -PrivateRoot $root
            $null = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict recovery-pending -ExpectedGeneration ([string]$gate.Generation) -PrivateRoot $root -Confirm:$false
            $outerLog = Join-Path $f.Runtime 'outer.log'
            $until = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $until -and -not ((Test-Path -LiteralPath $outerLog) -and ((Get-Content -LiteralPath $outerLog -Raw) -match 'refresh preflight finished'))) {
                Start-Sleep -Milliseconds 500
            }
            Assert-Match -Pattern 'refresh preflight finished' -Actual (Get-Content -LiteralPath $outerLog -Raw)
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'status.json')) 'a preflight writes no status document'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'host.registration.json')) 'a preflight registers nothing'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.start')) 'the inner published its start record'
        } finally {
            if ($runner -and -not $runner.HasExited) { $runner.Kill($true) }
            Remove-YurunaTestTempDir $f.Base
        }
    }
}
