<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42f56ee0-83ba-488d-ab51-753cfedca196
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test windows runner native host-refresh
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
    Windows runner protocol checks against disposable native PowerShell
    process trees, real CIM identities, single-PID termination and a private
    handoff journal. No host runner, service or virtual machine is touched.
#>

Describe 'Windows native runner protocol' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script:Here = Split-Path -Parent $PSCommandPath
        Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $script:Here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $script:Here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $script:Here 'Test.InnerSpawn.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $script:Here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
        $script:Work = New-YurunaTestTempDir -Prefix 'yrn-windows-protocol'
        $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
        $script:RequestId = '3c57992d-b1ad-4281-9a0e-d6df042bff3f'
        $script:Worker = Join-Path $script:Work 'native-tree.ps1'
        [IO.File]::WriteAllText($script:Worker, @'
param([string]$Capture, [string]$Node = 'root', [int]$Depth = 0, [int]$FanOut = 1)
$ErrorActionPreference = 'Stop'
$children = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
try {
    if ($Depth -gt 0) {
        for ($i = 0; $i -lt $FanOut; $i++) {
            $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
            foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Capture', $Capture, '-Node', "$Node-$i", '-Depth', "$($Depth - 1)", '-FanOut', "$FanOut")) { $psi.ArgumentList.Add($arg) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $children.Add([Diagnostics.Process]::Start($psi))
        }
    }
    $record = @{ pid = $PID; startTimeUnixMs = ([DateTimeOffset](Get-Process -Id $PID).StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() }
    $path = Join-Path $Capture "$Node.json"
    [IO.File]::WriteAllText("$path.tmp", ($record | ConvertTo-Json -Compress))
    [IO.File]::Move("$path.tmp", $path)
    Start-Sleep -Seconds 120
} finally {
    foreach ($child in $children) { try { if (-not $child.HasExited) { $child.Kill($true) } } catch { } }
}
'@)

        function Start-NativeRunnerTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: launches bounded disposable children in the suite temporary directory.')]
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([int]$Depth = 0, [int]$FanOut = 1)
            $capture = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory($capture)
            $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
            foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $script:Worker, '-Capture', $capture, '-Depth', "$Depth", '-FanOut', "$FanOut")) { $psi.ArgumentList.Add($arg) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $process = [Diagnostics.Process]::Start($psi)
            $script:Spawned.Add($process)
            $expected = 0
            for ($level = 0; $level -le $Depth; $level++) { $expected += [int][Math]::Pow($FanOut, $level) }
            $until = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $files = @([IO.Directory]::GetFiles($capture, '*.json'))
                if ($files.Count -eq $expected) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $until)
            Assert-Equal $expected $files.Count 'every owned process published its identity'
            $nodes = @{}
            foreach ($file in $files) {
                $row = [IO.File]::ReadAllText($file) | ConvertFrom-Json
                $nodes[[IO.Path]::GetFileNameWithoutExtension($file)] = $row
                if ($row.pid -ne $process.Id) { $script:Spawned.Add((Get-Process -Id $row.pid -ErrorAction Stop)) }
            }
            return [pscustomobject]@{ Process = $process; Nodes = $nodes; Capture = $capture }
        }

        function Get-NativeReclaimPlan {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([Parameter(Mandatory)]$Tree, [int[]]$ExcludedPid = @())
            $ids = @($Tree.Nodes.Values | ForEach-Object { [int]$_.pid })
            $table = Get-YurunaProcessTable -ProcessId $ids
            Assert-True $table.Complete "native CIM table completed: $($table.Error)"
            $roots = @([pscustomobject]@{ Pid = $Tree.Process.Id; StartTimeUnixMs = $Tree.Nodes.root.startTimeUnixMs; Role = 'inner' })
            $targets = Resolve-YurunaRunnerProcessTarget -ProcessTable $table.Rows -VerifiedRoot $roots -ExcludedPid $ExcludedPid
            return [pscustomobject]@{ Roots = $roots; Target = $targets; Table = $table }
        }

        function New-NativeHandoffRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a private journal and runtime under the suite temporary directory.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()
            $base = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $runtime = Join-Path $base 'runtime'
            $private = Join-Path $base 'private'
            $null = [IO.Directory]::CreateDirectory($runtime)
            $null = [IO.Directory]::CreateDirectory($private)
            return @{ Runtime = $runtime; Private = $private }
        }
    }

    AfterAll {
        foreach ($process in $script:Spawned) {
            try { if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) } } catch { $null = $_ }
            $process.Dispose()
        }
        Remove-YurunaTestTempDir $script:Work
    }

    Describe 'Windows native runner process identities and reclamation' {
        It 'reads the actual CIM parent, session and creation time of owned PowerShell children' {
            $tree = Start-NativeRunnerTree -Depth 1
            $ids = @($tree.Nodes.Values | ForEach-Object { [int]$_.pid })
            $table = Get-YurunaProcessTable -ProcessId $ids
            Assert-True $table.Complete "CIM completed: $($table.Error)"
            Assert-Equal 'cim' $table.Source
            Assert-Equal 2 $table.Rows.Count 'the PID filter excludes unrelated processes'
            foreach ($row in $table.Rows) {
                $process = Get-Process -Id $row.Pid -ErrorAction Stop
                $expectedStart = ([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
                Assert-True ([Math]::Abs($row.StartTimeUnixMs - $expectedStart) -le 2000) 'CIM creation time agrees with the kernel process handle'
                Assert-Equal ([string]$process.SessionId) ([string]$row.OwnerId)
            }
            $root = @($table.Rows | Where-Object Pid -eq $tree.Process.Id)[0]
            $child = @($table.Rows | Where-Object Pid -eq $tree.Nodes.'root-0'.pid)[0]
            Assert-Equal $PID $root.ParentPid
            Assert-Equal $tree.Process.Id $child.ParentPid
        }

        It 'revalidates and terminates an owned child before its parent using the native single-PID path' {
            $tree = Start-NativeRunnerTree -Depth 1
            $plan = Get-NativeReclaimPlan -Tree $tree
            $result = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -GraceMilliseconds 300 -Confirm:$false
            Assert-True $result.Converged 'the native termination path stopped every planned target'
            Assert-Equal "$($tree.Nodes.'root-0'.pid),$($tree.Process.Id)" ((@($result.Targets) | ForEach-Object Pid) -join ',') 'child first, then parent'
            Assert-True (@($result.Targets | Where-Object Action -notin @('exited-after-term', 'exited-after-kill', 'already-exited')).Count -eq 0) 'all targets exited'
        }

        It 'leaves an excluded child alive when reclaiming its parent and sibling' {
            $tree = Start-NativeRunnerTree -Depth 1 -FanOut 2
            $excluded = [int]$tree.Nodes.'root-1'.pid
            $result = Stop-YurunaRunnerProcessTarget -Plan (Get-NativeReclaimPlan -Tree $tree -ExcludedPid @($excluded)) `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -GraceMilliseconds 300 -Confirm:$false
            Assert-True $result.Converged
            Assert-False (@($result.Targets | ForEach-Object Pid) -contains $excluded) 'the excluded child was not targeted'
            Assert-NotNull (Get-Process -Id $excluded -ErrorAction SilentlyContinue) 'terminating the parent did not kill an excluded descendant'
        }

        It 'refuses a mismatched creation time without signaling the process occupying that PID' {
            $tree = Start-NativeRunnerTree
            $plan = Get-NativeReclaimPlan -Tree $tree
            foreach ($row in $plan.Target.Descendants) { $row.StartTimeUnixMs -= 60000 }
            $result = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -Confirm:$false
            Assert-Equal 'recycled-skipped' (@($result.Targets)[0].Action)
            Assert-False $tree.Process.HasExited 'the real native identity lookup rejected the stale generation'
        }

        It 'leaves owned processes running after WhatIf or an exhausted deadline' {
            $tree = Start-NativeRunnerTree
            $plan = Get-NativeReclaimPlan -Tree $tree
            $preview = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -WhatIf
            Assert-Equal 'whatif' (@($preview.Targets)[0].Action)
            $expired = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 0) -Confirm:$false
            Assert-Equal 'skipped-deadline' (@($expired.Targets)[0].Action)
            Assert-False $tree.Process.HasExited
        }
    }

    Describe 'Windows native readiness handoff' {
        It 'restarts a stand-in runner through the real Windows hop and completes its live three-process handoff' {
            $paths = New-NativeHandoffRoot
            $repo = Join-Path $script:Work ('repo-' + [guid]::NewGuid().ToString('N'))
            $testDir = Join-Path $repo 'test'
            $null = [IO.Directory]::CreateDirectory($testDir)
            $streams = Join-Path $paths.Private 'work'
            $null = [IO.Directory]::CreateDirectory($streams)
            $fixturePath = Join-Path $testDir 'native.json'
            $fixture = @{ modules = $script:Here; runtime = $paths.Runtime; private = $paths.Private; capture = $testDir }
            [IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json))
            $body = @'
$ErrorActionPreference = 'Stop'
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native.json') -Raw | ConvertFrom-Json
Import-Module (Join-Path $fixture.modules '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $fixture.modules 'Test.InnerSpawn.psm1') -DisableNameChecking
Import-Module (Join-Path $fixture.modules 'Test.SingleInstance.psm1') -DisableNameChecking
if ($Role -eq 'outer') {
    $wait = Wait-YurunaDetachedHopExit -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
    if (-not $wait.Exited) { throw "hop did not exit: $($wait.Reason)" }
}
$identity = @{ pid = $PID; startTimeUnixMs = Get-YurunaProcessStartUnixMs -ProcessId $PID }
$identityPath = Join-Path $fixture.capture "$Role.json"
[IO.File]::WriteAllText("$identityPath.tmp", ($identity | ConvertTo-Json))
[IO.File]::Move("$identityPath.tmp", $identityPath)
if ($Role -eq 'cycle') {
    [IO.File]::WriteAllText((Join-Path $fixture.runtime 'runner.cycle.json'), (@{ schemaVersion = 1; pid = $PID; startTimeUnixMs = $identity.startTimeUnixMs; cycle = 1 } | ConvertTo-Json))
} else {
    $stem = if ($Role -eq 'outer') { 'runner' } else { 'inner' }
    [IO.File]::WriteAllText((Join-Path $fixture.runtime "$stem.pid"), [string]$PID)
    [IO.File]::WriteAllText((Join-Path $fixture.runtime "$stem.start"), [DateTimeOffset]::FromUnixTimeMilliseconds($identity.startTimeUnixMs).UtcDateTime.ToString('o'))
}
$admitted = Test-YurunaRunnerHandoffToken -TokenId $RefreshHandoffToken -Role $Role -RuntimeDir $fixture.runtime -PrivateRoot $fixture.private
if (-not $admitted.Valid) { throw "role $Role refused: $($admitted.Reason)" }
if ($Role -eq 'inner') {
    $chain = @{}
    foreach ($name in @('outer', 'cycle', 'inner')) { $chain[$name] = Get-Content -LiteralPath (Join-Path $fixture.capture "$name.json") -Raw | ConvertFrom-Json -AsHashtable }
    $written = Write-YurunaRunnerReadinessAck -TokenId $RefreshHandoffToken -Role inner -State ready -Chain $chain -RuntimeDir $fixture.runtime -PrivateRoot $fixture.private -Confirm:$false
    if (-not $written) { throw 'readiness acknowledgment was not written' }
} else {
    $nextRole = if ($Role -eq 'outer') { 'cycle' } else { 'inner' }
    $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'native-chain.ps1'), '-Role', $nextRole, '-RefreshHandoffToken', $RefreshHandoffToken)) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $null = [Diagnostics.Process]::Start($psi)
}
Start-Sleep -Seconds 120
'@
            $runner = Join-Path $testDir 'Start-TestRunner.ps1'
            $real = Get-YurunaTestFileAst -Path (Join-Path $script:Here '../Start-TestRunner.ps1')
            [IO.File]::WriteAllText($runner, "#requires -version 7`n" + $real.ParamBlock.Extent.Text + "`n`$Role = 'outer'`n" + $body)
            [IO.File]::WriteAllText((Join-Path $testDir 'native-chain.ps1'), "param([string]`$Role, [string]`$RefreshHandoffToken)`n" + $body)
            $config = Join-Path $repo 'runner.config.yml'
            [IO.File]::WriteAllText($config, "x: 1`n")
            $record = Write-YurunaRunnerLaunchRecord -ScriptPath $runner -BoundParameters ([ordered]@{}) -ResolvedConfigPath $config -RuntimeDir $paths.Runtime `
                -RepoRoot $repo -WorkingDirectory $repo -ForwardEnvironment @{} -AllowedEnvironmentName @('YURUNA_LOG_LEVEL') -PrivateRoot $paths.Private -Confirm:$false
            Assert-True $record.Written "launch record: $($record.Reason)"
            $closed = Set-YurunaRefreshGate -State closed -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -ExpectedGeneration '' -PrivateRoot $paths.Private -OwnerPid $PID -Confirm:$false
            try {
                $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $paths.Runtime -PrivateRoot $paths.Private
                $result = Invoke-YurunaRunnerRefreshResume -LaunchRecord $launch -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -RepoRoot $repo `
                    -ExpectedGateGeneration $closed.Generation -Reclaimed @{} -PrivateDirectory $streams -Deadline (New-YurunaDeadline -TotalMilliseconds 60000) -PrivateRoot $paths.Private -Confirm:$false
                $detail = ''
                if ($result.Outcome -ne 'ready') {
                    try { $detail = [IO.File]::ReadAllText((Join-Path $streams "runner.$($script:RequestId).err")) } catch { $detail = 'worker capture is still open' }
                }
                Assert-Equal 'ready' $result.Outcome "native detached handoff: $($result.Reason) $detail"
                Assert-Equal 'released' $result.GateState
                Assert-Equal 'open' (Get-YurunaRefreshGateState -RuntimeDir $paths.Runtime -PrivateRoot $paths.Private).State
            } finally {
                foreach ($name in @('outer', 'cycle', 'inner')) {
                    $path = Join-Path $testDir "$name.json"
                    if (-not [IO.File]::Exists($path)) { continue }
                    $identity = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                    $process = Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
                    if ($process -and [Math]::Abs(([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() - $identity.startTimeUnixMs) -le 2000) {
                        $script:Spawned.Add($process)
                    }
                }
            }
        }

        It 'accepts a real three-process ancestry and rejects a mismatched inner identity' {
            $tree = Start-NativeRunnerTree -Depth 2
            $paths = New-NativeHandoffRoot
            $chain = @{
                outer = @{ pid = $tree.Nodes.root.pid; startTimeUnixMs = $tree.Nodes.root.startTimeUnixMs }
                cycle = @{ pid = $tree.Nodes.'root-0'.pid; startTimeUnixMs = $tree.Nodes.'root-0'.startTimeUnixMs }
                inner = @{ pid = $tree.Nodes.'root-0-0'.pid; startTimeUnixMs = $tree.Nodes.'root-0-0'.startTimeUnixMs }
            }
            foreach ($role in @('outer', 'inner')) {
                $stem = if ($role -eq 'outer') { 'runner' } else { 'inner' }
                [IO.File]::WriteAllText((Join-Path $paths.Runtime "$stem.pid"), [string]$chain[$role].pid)
                [IO.File]::WriteAllText((Join-Path $paths.Runtime "$stem.start"), [DateTimeOffset]::FromUnixTimeMilliseconds($chain[$role].startTimeUnixMs).UtcDateTime.ToString('o'))
            }
            [IO.File]::WriteAllText((Join-Path $paths.Runtime 'runner.cycle.json'), (@{ schemaVersion = 1; pid = $chain.cycle.pid; startTimeUnixMs = $chain.cycle.startTimeUnixMs; cycle = 1 } | ConvertTo-Json))
            $closed = Set-YurunaRefreshGate -State closed -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -ExpectedGeneration '' -PrivateRoot $paths.Private -OwnerPid $PID -Confirm:$false
            Assert-True $closed.Written "closed gate: $($closed.Reason)"
            $token = New-YurunaRunnerHandoffToken -RequestId $script:RequestId -Attempt 1 -RuntimeDir $paths.Runtime -Purpose new-outer -ExpiresInMilliseconds 60000 `
                -ExpectedGeneration $closed.Generation -PrivateRoot $paths.Private -Confirm:$false
            Assert-True $token.Issued
            $null = Write-YurunaRunnerReadinessAck -TokenId $token.TokenId -Role inner -State ready -Chain $chain -PreservedControl @('control.cycle-pause') `
                -RuntimeDir $paths.Runtime -PrivateRoot $paths.Private -Confirm:$false
            $ready = Wait-YurunaRunnerReadiness -TokenId $token.TokenId -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -PrivateRoot $paths.Private
            Assert-Equal 'ready' $ready.State "native chain: $($ready.Reason)"
            $chain.inner = $chain.cycle
            $null = Write-YurunaRunnerReadinessAck -TokenId $token.TokenId -Role inner -State ready -Chain $chain -RuntimeDir $paths.Runtime -PrivateRoot $paths.Private -Confirm:$false
            $mismatch = Wait-YurunaRunnerReadiness -TokenId $token.TokenId -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -PrivateRoot $paths.Private
            Assert-Equal 'identity-mismatch' $mismatch.State
            $completed = Complete-YurunaRunnerHandoff -TokenId $token.TokenId -Verdict recovery-pending -ExpectedGeneration $token.Generation -PrivateRoot $paths.Private -Confirm:$false
            Assert-True $completed.Completed
            Assert-Equal 'recovery-pending' $completed.State
        }
    }
}
