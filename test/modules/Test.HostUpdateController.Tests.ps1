<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4252ba0e-8842-420d-b24b-8ad8834b6ea2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update controller snapshot pester
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
    The host controller and its snapshot: staging, current and rejected;
    the controller lock and the ok marker; claim, phases, drain, runner
    plan, restore, recovering, release and takeover; continuation from the
    journal after an interruption at every phase boundary; and the public
    state it projects.
.DESCRIPTION
    The controller is the one process a host update does not kill, so a
    rule it gets wrong is not fixed by the update it runs. Its functions run
    in this process against a scratch private root (the journal module's
    home seam), an injected clock and a stand-in step launcher that writes
    scripted result files; the step contract itself is also exercised with
    real detached stand-in processes. No runner, listener or real private
    root is touched.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The private state root and the runner gate resolve under $HOME; a scratch
    # home keeps this suite and every process it starts off the operator's own.
    $script:TestHome = Enter-YurunaTestHome
    Get-Module Test.HostUpdate, Test.HostOperationJournal | Remove-Module -Force -ErrorAction SilentlyContinue
    # One instance of each primitive, shared by this suite and the module
    # under test: a lock or a gate the suite reads must be the module's.
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostOperationJournal.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostUpdate.psm1') -Force -Global -DisableNameChecking
    $script:BypassRoot = Join-Path $HOME '.yuruna/host-repair'
    # The root a call that bypassed its seam would reach under the scratch
    # home; what the controller could write is compared, and every name.
    $script:BypassRootListing = {
        if (-not (Test-Path -LiteralPath $script:BypassRoot)) { return '<absent>' }
        @(Get-ChildItem -LiteralPath $script:BypassRoot -Force | Sort-Object Name | ForEach-Object {
                if ($_.Name -match '^(host-controller|host-repair\.|runner-gate|runner-launch|runner-handoff|work)') { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" } else { $_.Name }
            }) -join ';'
    }
    $script:BypassRootBefore = & $script:BypassRootListing
    $script:ScratchBase = New-YurunaTestTempDir -Prefix 'hu-controller'
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:CurrentPrivateRoot = $null

    # Admission reads the runner gate by name and with no private root; the
    # suite's reader answers from the scratch root, the module under test
    # keeps its own import of the real reader.
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

    function New-ControllerFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a scratch home, checkout and snapshot.')]
        param([string]$Protocol = '1')
        $dir = Join-Path $script:ScratchBase ('h-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
        $runtime = Join-Path $dir 'runtime'
        $checkout = Join-Path $dir 'checkout'
        foreach ($path in @($runtime, (Join-Path $checkout 'automation'), (Join-Path $checkout 'test/modules'), (Join-Path $checkout 'test/lab'))) {
            $null = New-Item -ItemType Directory -Path $path -Force
        }
        Set-Content -LiteralPath (Join-Path $checkout 'automation/A.psm1') -Value 'function Get-A { 1 }'
        Set-Content -LiteralPath (Join-Path $checkout 'test/modules/B.psm1') -Value 'function Get-B { 2 }'
        Set-Content -LiteralPath (Join-Path $checkout 'test/lab/Invoke-HostUpdateController.ps1') -Value 'param() exit 0'
        [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), $Protocol)
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $dir
        $privateRoot = (Get-HostOperationPrivateRoot).Path
        $script:GateHolder.Root = $privateRoot
        $script:CurrentPrivateRoot = $privateRoot
        $controllerRoot = Get-HostUpdateControllerRoot
        $staged = New-HostUpdateSnapshot -SourceRoot $checkout -ControllerRoot $controllerRoot -Confirm:$false
        Assert-Equal -Expected 'staged' -Actual $staged.Reason 'fixture sanity: the scratch checkout stages'
        $null = Write-HostUpdateControllerCurrent -ControllerRoot $controllerRoot -Current $staged.Hash16 -Previous '' -Checkout $checkout -Confirm:$false
        [pscustomobject]@{ Home = $dir; Runtime = $runtime; Checkout = $checkout; PrivateRoot = $privateRoot; ControllerRoot = $controllerRoot; Snapshot = $staged.Hash16 }
    }

    function New-FakeService {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds stand-in services in memory.')]
        param([Parameter(Mandatory)]$Fixture, [scriptblock]$ShouldStop)
        # One reading seeds both the fake clock and StartMs: two reads can straddle a
        # millisecond, and elapsed-time assertions such as "-ge 300000" then miss by one.
        $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $fake = @{
            Clock = @{ Ms = $startMs; Tick = [Environment]::TickCount64 }
            Plan = @{}; Launches = [System.Collections.Generic.List[object]]::new(); Hang = @{}; Killed = [System.Collections.Generic.List[object]]::new()
            NextPid = 4100000; PrivateRoot = $Fixture.PrivateRoot; Log = [System.Collections.Generic.List[string]]::new()
            Found = [System.Collections.Generic.List[object]]::new(); Pending = @{}
            Writes = [System.Collections.Generic.List[object]]::new(); CrashAt = $null; Crashed = $false; SleepHook = $null; Gate = $script:RealGateReader
            LimitMs = [long]21600000; StartMs = $startMs
            FullReady = $false; ListenerStops = [System.Collections.Generic.List[string]]::new()
            Native = [System.Collections.Generic.List[string]]::new(); NativeExit = @{}; NativeOut = @{}
            ProbeAt = [System.Collections.Generic.List[long]]::new()
        }
        $service = @{
            UtcNow = { [DateTimeOffset]::FromUnixTimeMilliseconds($fake.Clock.Ms) }.GetNewClosure()
            TickMs = { $fake.Clock.Tick }.GetNewClosure()
            Sleep = {
                param([int]$Milliseconds)
                $fake.Clock.Ms += $Milliseconds; $fake.Clock.Tick += $Milliseconds
                if ($fake.Clock.Ms - $fake.StartMs -gt $fake.LimitMs) { throw 'fake clock limit reached' }
                if ($fake.SleepHook) { & $fake.SleepHook $fake }
            }.GetNewClosure()
            StartStep = {
                param($Launch)
                $fake.Launches.Add($Launch)
                $queue = $fake.Plan[$Launch.Step]
                $spec = if ($queue -and $queue.Count -gt 0) { $queue.Dequeue() } else { @{} }
                $childPid = $fake.NextPid; $fake.NextPid++
                if ($spec.HangMs) { $fake.Hang[$childPid] = $fake.Clock.Tick + [long]$spec.HangMs }
                $outcome = if ($spec.Outcome) { $spec.Outcome } else { 'done' }
                if (-not $spec.NoResult) {
                    $result = [ordered]@{
                        schemaVersion = 1; step = $Launch.Step; requestId = $Launch.RequestId; attempt = $Launch.Attempt; outcome = $outcome
                        reason = $spec.Reason; remarks = @($spec.Remarks | Where-Object { $_ }); operatorAction = $spec.Action
                        protocol = if ($null -ne $spec.Protocol) { $spec.Protocol } else { 1 }
                        commit = $spec.Commit; runnerConsole = $spec.Console; reclaimed = $spec.Reclaimed; detail = @{ note = 'stand-in' }
                    }
                    if ($spec.Extra) { foreach ($name in $spec.Extra.Keys) { $result[$name] = $spec.Extra[$name] } }
                    [System.IO.File]::WriteAllText($Launch.ResultPath, ($result | ConvertTo-Json -Depth 6))
                }
                if ($Launch.Step -eq 'start_runner' -and $outcome -eq 'done' -and -not $spec.NoGateOpen) {
                    # The new runner's acknowledgment opens the gate.
                    $gate = & $fake.Gate -RuntimeDir $Launch.Environment.YURUNA_RUNTIME_DIR -PrivateRoot $fake.PrivateRoot
                    if ($gate.State -ne 'open') {
                        $null = Set-YurunaRunnerGate -State released -RequestId ([string]$gate.RequestId) -Attempt 1 -RuntimeDir $Launch.Environment.YURUNA_RUNTIME_DIR `
                            -ExpectedGeneration $gate.Generation -PrivateRoot $fake.PrivateRoot -Confirm:$false
                    }
                }
                [pscustomobject]@{ Launched = $true; Pid = $childPid; StartTimeUnixMs = [long]1; Reason = 'launched' }
            }.GetNewClosure()
            StepLiveness = {
                param($ProcessId, $StartTimeUnixMs)
                $null = $StartTimeUnixMs
                $key = [int]$ProcessId
                if ($fake.Hang.ContainsKey($key) -and $fake.Clock.Tick -lt $fake.Hang[$key]) { return 'alive' }
                # A stand-in child in Pending writes its result as it ends.
                if ($fake.Pending.ContainsKey($key)) { [System.IO.File]::WriteAllText($fake.Pending[$key].Path, $fake.Pending[$key].Text); $fake.Pending.Remove($key) }
                'dead'
            }.GetNewClosure()
            StopStep = { param($ProcessId) $fake.Killed.Add($ProcessId); $fake.Hang.Remove([int]$ProcessId); $fake.Pending.Remove([int]$ProcessId) }.GetNewClosure()
            FindStep = {
                param($Phase, $RequestId)
                foreach ($found in $fake.Found) {
                    if ($found.Phase -eq $Phase -and $found.RequestId -eq $RequestId) { [pscustomobject]@{ Pid = $found.Pid; StartTimeUnixMs = $found.StartTimeUnixMs; Attempt = $found.Attempt } }
                }
            }.GetNewClosure()
            Log = { param([string]$Line) $fake.Log.Add($Line) }.GetNewClosure()
            # No sudo, systemctl or listener is touched: each call is recorded
            # and answers as NativeExit and NativeOut say (0 and no output by
            # default, which is what systemctl lists once every unit is gone).
            SupportedScope = { [string[]]@('restart', 'full') }
            ElevationProbe = { $fake.ProbeAt.Add($fake.Clock.Ms - $fake.StartMs); $fake.FullReady }.GetNewClosure()
            StopListener = { param([string]$RuntimeDir) $fake.ListenerStops.Add($RuntimeDir); $true }.GetNewClosure()
            Native = {
                param($FilePath, $ArgumentList, $TimeoutSeconds)
                $null = $TimeoutSeconds
                $line = (@($FilePath) + @($ArgumentList)) -join ' '
                $fake.Native.Add($line)
                $code = 0
                foreach ($pattern in @($fake.NativeExit.Keys)) { if ($line -like $pattern) { $code = [int]$fake.NativeExit[$pattern] } }
                $out = ''
                foreach ($pattern in @($fake.NativeOut.Keys)) { if ($line -like $pattern) { $out = [string]$fake.NativeOut[$pattern] } }
                @{ ExitCode = $code; TimedOut = $false; StdOut = $out; StdErr = '' }
            }.GetNewClosure()
            OnPhaseWritten = {
                param($Change)
                $fake.Writes.Add($Change)
                if ($fake.CrashAt -and -not $fake.Crashed -and -not $Change.ChildOnly -and $Change.Phase -eq $fake.CrashAt.Phase -and $Change.State -eq $fake.CrashAt.State) {
                    $fake.Crashed = $true
                    throw 'simulated controller kill'
                }
            }.GetNewClosure()
            ShouldStop = $ShouldStop
        }
        $fake.Service = $service
        $fake
    }

    function New-TestStepResultText {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory value or a scoped mock.')]
        param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)][int]$Attempt, [hashtable]$Commit)
        [ordered]@{
            schemaVersion = 1; step = $Step; requestId = $RequestId; attempt = $Attempt; outcome = 'done'; reason = $null; remarks = @()
            operatorAction = $null; protocol = 1; commit = $Commit; detail = @{ note = 'stand-in' }
        } | ConvertTo-Json -Depth 6
    }

    function Add-StepPlan {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: scripts the stand-in step results.')]
        param([Parameter(Mandatory)]$Fake, [Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][hashtable[]]$Spec)
        if (-not $Fake.Plan[$Step]) { $Fake.Plan[$Step] = [System.Collections.Generic.Queue[object]]::new() }
        foreach ($item in $Spec) { $Fake.Plan[$Step].Enqueue($item) }
    }

    function Add-TestUpdate {
        param([Parameter(Mandatory)]$Fixture, [string]$Channel = 'listener', [string]$Drain = 'after-cycle', [int]$DrainSeconds = 7200, [string]$Scope = 'restart', [string]$RequestId)
        $id = if ($RequestId) { $RequestId } else { New-YurunaHostOperationRequestId }
        $admission = Request-HostUpdateAdmission -RequestId $id -Channel $Channel -Scope $Scope -Drain $Drain -DrainSeconds $DrainSeconds `
            -RuntimeDir $Fixture.Runtime -HostType 'host.ubuntu.kvm' -Confirm:$false
        Assert-True ($admission.Decision -in @('queued', 'taken-over')) "fixture sanity: admission queues the update ($($admission.Decision) $($admission.Reason))"
        $id
    }

    function Get-TestRow {
        param([Parameter(Mandatory)][string]$RequestId)
        Get-HostUpdateRequest -RequestId $RequestId
    }

    function Get-TestObligation {
        param([Parameter(Mandatory)][string]$RequestId)
        $row = Get-TestRow -RequestId $RequestId
        $map = @{}
        foreach ($obligation in @($row['obligations'])) { if ($obligation) { $map[[string]$obligation['id']] = [string]$obligation['status'] } }
        $map
    }

    function Get-TestGate {
        param([Parameter(Mandatory)]$Fixture)
        & $script:RealGateReader -RuntimeDir $Fixture.Runtime -PrivateRoot $Fixture.PrivateRoot
    }

    function Get-TestPublicState {
        param([Parameter(Mandatory)]$Fixture)
        $path = Join-Path $Fixture.Runtime 'host-update.state.json'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }

    function New-TestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory value or a scoped mock.')]
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)]$Fake)
        $context = New-HostUpdateControllerContext -ControllerRoot $Fixture.ControllerRoot -Snapshot $Fixture.Snapshot -Checkout $Fixture.Checkout -Service $Fake.Service
        $context.PrivateRoot = $Fixture.PrivateRoot
        $context.RuntimeDir = $Fixture.Runtime
        $context
    }

    function Invoke-TestController {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)]$Fake)
        Invoke-HostUpdateController -Context (New-TestContext -Fixture $Fixture -Fake $Fake)
    }

    function New-StopWhenTerminal {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory value or a scoped mock.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RequestId',
            Justification = 'Captured by the closure it returns.')]
        param([Parameter(Mandatory)][string]$RequestId)
        { param($Context) $null = $Context; $row = Get-HostUpdateRequest -RequestId $RequestId; -not $row -or [string]$row['state'] -in @('completed', 'refused', 'abandoned') }.GetNewClosure()
    }

    function Invoke-TestUpdate {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$RequestId, [scriptblock]$Configure)
        $fake = New-FakeService -Fixture $Fixture -ShouldStop (New-StopWhenTerminal -RequestId $RequestId)
        if ($Configure) { & $Configure $fake }
        $code = Invoke-TestController -Fixture $Fixture -Fake $fake
        [pscustomobject]@{ Exit = $code; Fake = $fake; Row = (Get-TestRow -RequestId $RequestId) }
    }

    function Enter-TestClaim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: claims a scratch row for this process.')]
        param([Parameter(Mandatory)][string]$RequestId, [Parameter(Mandatory)]$Fixture)
        $lock = Enter-YurunaSingleFlightLock -Path (Get-YurunaHostOperationLockPath) -Rank (Get-YurunaLockRank -Name HostOperation) -WaitMilliseconds 2000
        try {
            $start = [long][DateTimeOffset]::new([System.Diagnostics.Process]::GetCurrentProcess().StartTime).ToUnixTimeMilliseconds()
            $claim = Confirm-HostUpdateClaim -RequestId $RequestId -LifetimeLock $lock -ControllerPid $PID -ControllerStartTimeUnixMs $start `
                -Snapshot $Fixture.Snapshot -RepoRoot $Fixture.Checkout -Mode claim -Confirm:$false
            Assert-True $claim.Accepted "fixture sanity: the claim is accepted ($($claim.Reason))"
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
    }

    function Set-TestLaunchRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory value or a scoped mock.')]
        param([Parameter(Mandatory)][bool]$CleanExit)
        $record = [pscustomobject]@{ Found = $true; Valid = $true; Record = @{ cleanExit = $CleanExit }; Reason = $null; Path = $null }
        Mock Read-YurunaRunnerLaunchRecord -ModuleName Test.HostUpdate { $record }.GetNewClosure()
    }
}

AfterAll {
    # The listing is read while $HOME is still the scratch home, and the home
    # is left even when the comparison throws.
    try {
        foreach ($process in $script:Spawned) {
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
        }
        & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
        Remove-Item -LiteralPath Function:\Get-YurunaRunnerGateState -ErrorAction SilentlyContinue
        $after = & $script:BypassRootListing
        Assert-Equal -Expected $script:BypassRootBefore -Actual $after "a call that bypassed its seam neither created nor changed the private root under the suite's home"
    } finally {
        Remove-YurunaTestTempDir -Path $script:ScratchBase
        Exit-YurunaTestHome $script:TestHome
    }
}

Describe 'the snapshot' {
    BeforeAll {
        function New-TestTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a scratch tree.')]
            param()
            $tree = Join-Path $script:ScratchBase ('t-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            foreach ($path in @('automation/sub', 'test/modules', 'test/lab', 'globalization/generated/powershell', 'globalization/manifests', 'docs')) {
                $null = New-Item -ItemType Directory -Path (Join-Path $tree $path) -Force
            }
            Set-Content -LiteralPath (Join-Path $tree 'automation/Yuruna.X.psm1') -Value 'function Get-X { 1 }'
            Set-Content -LiteralPath (Join-Path $tree 'automation/sub/data.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $tree 'test/modules/Test.Y.psm1') -Value 'function Get-Y { 2 }'
            Set-Content -LiteralPath (Join-Path $tree 'test/modules/Test.Y.Tests.ps1') -Value 'Describe x {}'
            Set-Content -LiteralPath (Join-Path $tree 'test/modules/y.test.js') -Value '//'
            Set-Content -LiteralPath (Join-Path $tree 'test/modules/suite-baseline.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $tree 'globalization/generated/powershell/en-US.runner.psd1') -Value '@{}'
            Set-Content -LiteralPath (Join-Path $tree 'globalization/locale-manifest.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $tree 'globalization/manifests/catalog-set.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $tree 'test/lab/Invoke-HostUpdateController.ps1') -Value 'param() exit 0'
            Set-Content -LiteralPath (Join-Path $tree 'test/lab/Other.ps1') -Value 'exit 0'
            Set-Content -LiteralPath (Join-Path $tree 'docs/readme.md') -Value '# x'
            [System.IO.File]::WriteAllText((Join-Path $tree 'test/host-update.protocol-version'), '1')
            $tree
        }
        function New-TestControllerRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a scratch controller root.')]
            param()
            $root = Join-Path $script:ScratchBase ('c-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $null = New-Item -ItemType Directory -Path $root -Force
            $root
        }
    }

    It 'hashes the same tree to the same name and any byte change to another' {
        $tree = New-TestTree
        $first = Get-HostUpdateSnapshotManifest -SourceRoot $tree
        $second = Get-HostUpdateSnapshotManifest -SourceRoot $tree
        Assert-Equal -Expected $first.Hash -Actual $second.Hash
        Assert-Match -Pattern '^[0-9a-f]{16}$' -Actual $first.Hash16
        Assert-Equal -Expected $first.Hash.Substring(0, 16) -Actual $first.Hash16
        $copy = Join-Path $script:ScratchBase ('t-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        Copy-Item -LiteralPath $tree -Destination $copy -Recurse
        Assert-Equal -Expected $first.Hash -Actual (Get-HostUpdateSnapshotManifest -SourceRoot $copy).Hash 'the hash depends on content, not location'
        Add-Content -LiteralPath (Join-Path $tree 'automation/sub/data.json') -Value ' '
        Assert-False ((Get-HostUpdateSnapshotManifest -SourceRoot $tree).Hash -ceq $first.Hash) 'one byte changes the name'
        Remove-Item -LiteralPath (Join-Path $copy 'globalization/locale-manifest.json')
        Assert-False ((Get-HostUpdateSnapshotManifest -SourceRoot $copy).Hash -ceq $first.Hash) 'a removed file changes the name'
    }

    It 'leaves out test files and the baseline' {
        $tree = New-TestTree
        $files = (Get-HostUpdateSnapshotManifest -SourceRoot $tree).Files
        $expected = @('automation/Yuruna.X.psm1', 'automation/sub/data.json', 'globalization/generated/powershell/en-US.runner.psd1',
            'globalization/locale-manifest.json', 'globalization/manifests/catalog-set.json', 'test/host-update.protocol-version',
            'test/lab/Invoke-HostUpdateController.ps1', 'test/modules/Test.Y.psm1')
        Assert-Equal -Expected ($expected -join ',') -Actual ($files -join ',') 'ordinal order; tests, baseline, docs and other lab scripts stay out'
        $before = (Get-HostUpdateSnapshotManifest -SourceRoot $tree).Hash
        Add-Content -LiteralPath (Join-Path $tree 'test/modules/Test.Y.Tests.ps1') -Value '# changed'
        Set-Content -LiteralPath (Join-Path $tree 'test/modules/suite-baseline.json') -Value '{"x":1}'
        Assert-Equal -Expected $before -Actual (Get-HostUpdateSnapshotManifest -SourceRoot $tree).Hash 'a test change does not replace the snapshot'
    }

    It 'stages atomically and refuses a rejected hash' {
        $tree = New-TestTree
        $root = New-TestControllerRoot
        $hash = (Get-HostUpdateSnapshotManifest -SourceRoot $tree).Hash16
        $staged = New-HostUpdateSnapshot -SourceRoot $tree -ControllerRoot $root -Confirm:$false
        Assert-Equal -Expected 'staged' -Actual $staged.Reason
        Assert-Equal -Expected $hash -Actual $staged.Hash16
        Assert-Equal -Expected $hash -Actual (Get-HostUpdateSnapshotManifest -SourceRoot (Join-Path $root "versions/$hash")).Hash16 'the copy hashes to its name'
        Assert-Equal -Expected $hash -Actual ((Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Name) -join ',') 'no staging folder is left behind'
        if (-not $IsWindows) { Assert-Equal -Expected '700' -Actual ([Convert]::ToString([int](Get-Item -LiteralPath (Join-Path $root "versions/$hash")).UnixFileMode, 8)) }
        Assert-Equal -Expected 'exists' -Actual (New-HostUpdateSnapshot -SourceRoot $tree -ControllerRoot $root -Confirm:$false).Reason
        Add-Content -LiteralPath (Join-Path $tree 'automation/Yuruna.X.psm1') -Value '# next'
        $next = (Get-HostUpdateSnapshotManifest -SourceRoot $tree).Hash16
        [System.IO.File]::WriteAllText((Join-Path $root 'rejected'), "$next`n")
        Assert-Equal -Expected ($next) -Actual ((Get-HostUpdateRejected -ControllerRoot $root) -join ',')
        $refused = New-HostUpdateSnapshot -SourceRoot $tree -ControllerRoot $root -Confirm:$false
        Assert-Equal -Expected 'rejected' -Actual $refused.Reason
        Assert-False (Test-Path -LiteralPath (Join-Path $root "versions/$next")) 'a rejected hash is never staged'
    }

    It 'refuses a tree that does not parse' {
        $tree = New-TestTree
        $root = New-TestControllerRoot
        Set-Content -LiteralPath (Join-Path $tree 'test/modules/Test.Y.psm1') -Value 'function Get-Y { '
        $result = New-HostUpdateSnapshot -SourceRoot $tree -ControllerRoot $root -Confirm:$false
        Assert-Equal -Expected 'parse-failed' -Actual $result.Reason
        Assert-Equal -Expected 'test/modules/Test.Y.psm1' -Actual $result.Detail
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath (Join-Path $root 'versions')).Count 'nothing is staged'
        Assert-False (Test-HostUpdateSnapshotParse -SourceRoot $tree).Ok
    }

    It 'writes current by rename and keeps previous' {
        $root = New-TestControllerRoot
        Assert-True (Write-HostUpdateControllerCurrent -ControllerRoot $root -Current '0123456789abcdef' -Previous 'fedcba9876543210' -Checkout '/srv/a b' -Confirm:$false)
        Assert-Equal -Expected "current=0123456789abcdef`nprevious=fedcba9876543210`ncheckout=/srv/a b`n" -Actual ([System.IO.File]::ReadAllText((Join-Path $root 'current')))
        $read = Read-HostUpdateControllerCurrent -ControllerRoot $root
        Assert-Equal -Expected 'fedcba9876543210' -Actual $read.Previous
        Assert-Equal -Expected '/srv/a b' -Actual $read.Checkout
        Assert-True (Write-HostUpdateControllerCurrent -ControllerRoot $root -Current '' -Previous '' -Checkout '/srv/a b' -Confirm:$false) 'an empty current is allowed'
        Assert-False (Write-HostUpdateControllerCurrent -ControllerRoot $root -Current 'not-a-hash' -Previous '' -Checkout '/srv' -Confirm:$false)
        Assert-False (Write-HostUpdateControllerCurrent -ControllerRoot $root -Current '' -Previous '' -Checkout "/srv`nx" -Confirm:$false)
        Assert-Equal -Expected 'current' -Actual ((Get-ChildItem -LiteralPath $root -Name) -join ',') 'no temporary file is left'
    }

    It 'keeps only current and previous' {
        $root = New-TestControllerRoot
        $versions = Join-Path $root 'versions'
        foreach ($name in @('0123456789abcdef', 'fedcba9876543210', 'aaaabbbbccccdddd', 'staging.tmp-999999999', "staging.tmp-$PID", 'not-a-snapshot')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $versions "$name/x") -Force
        }
        $removed = Remove-HostUpdateStaleSnapshot -ControllerRoot $root -Keep @('0123456789abcdef', 'fedcba9876543210') -Confirm:$false
        Assert-Equal -Expected 'aaaabbbbccccdddd,staging.tmp-999999999' -Actual ((@($removed) | Sort-Object) -join ',')
        Assert-Equal -Expected "0123456789abcdef,fedcba9876543210,not-a-snapshot,staging.tmp-$PID" -Actual ((Get-ChildItem -LiteralPath $versions -Name | Sort-Object) -join ',')
    }

    It 'renders a catalog line from a staged snapshot' {
        $root = New-TestControllerRoot
        $staged = New-HostUpdateSnapshot -SourceRoot $script:RepoRoot -ControllerRoot $root -Confirm:$false
        Assert-Equal -Expected 'staged' -Actual $staged.Reason "the checkout stages ($($staged.Detail))"
        $snapshot = Join-Path $root "versions/$($staged.Hash16)"
        Assert-True (Test-Path -LiteralPath (Join-Path $snapshot 'test/lab/Invoke-HostUpdateController.ps1')) 'the controller script is in the snapshot'
        Assert-True (Test-Path -LiteralPath (Join-Path $snapshot 'test/host-update.protocol-version')) 'the protocol number is in the snapshot'
        $probe = Join-Path $script:ScratchBase ('probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        Set-Content -LiteralPath $probe -Value @'
param([string]$Snapshot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Snapshot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
'LINE=' + (Format-YurunaOperatorMessage -Key 'runner.host_repair_other_kind' -Arguments @{ requestId = '00000000-0000-4000-8000-000000000000' })
Import-Module (Join-Path $Snapshot 'test/modules/../extension/pool-aggregator-service/default.psm1') -Global -DisableNameChecking
'RING=' + [string](Get-PoolAggregatorServiceManifest).Endpoints.FrameworkRing
Import-Module (Join-Path $Snapshot 'test/modules/Test.Prelude.psm1') -Global -Force -DisableNameChecking
Initialize-YurunaEntryPointModuleSet -For HostUpdateController -ModulesDir (Join-Path $Snapshot 'test/modules')
'CONTROLLER=' + [bool](Get-Command Invoke-HostUpdateController -ErrorAction SilentlyContinue)
'@
        $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probe, '-Snapshot', $snapshot)) { $info.ArgumentList.Add($argument) }
        $info.Environment['NO_COLOR'] = '1'
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $script:Spawned.Add($process)
        $stderr = $process.StandardError.ReadToEndAsync()
        $text = $process.StandardOutput.ReadToEnd() + $stderr.Result
        Assert-True ($process.WaitForExit(120000)) 'the probe ends'
        Assert-Match -Pattern 'LINE=Invoke-HostRepair: request 00000000-0000-4000-8000-000000000000 is a host update' -Actual $text
        Assert-Match -Pattern 'RING=/\S+' -Actual $text
        Assert-Match -Pattern 'CONTROLLER=True' -Actual $text
    }
}

Describe 'the step contract with stand-in step processes' -Skip:$IsWindows {
    BeforeAll {
        function New-StandInStep {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a stand-in step script.')]
            param([Parameter(Mandatory)][string]$Mode)
            $path = Join-Path $script:ScratchBase ("step-$Mode-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
            Set-Content -LiteralPath $path -Value (@'
param([string]$Step, [string]$RequestId, [int]$Attempt, [string]$ResultPath, [string]$RepoRoot, [int]$ControllerPid)
$mode = '@MODE@'
$write = {
    param([string]$Outcome, [string]$Reason, [string[]]$Remarks, [int]$Code)
    $result = [ordered]@{ schemaVersion = 1; step = $Step; requestId = $RequestId; attempt = $Attempt; outcome = $Outcome; reason = $Reason; remarks = @($Remarks | Where-Object { $_ }); protocol = 1 }
    [System.IO.File]::WriteAllText("$ResultPath.tmp", ($result | ConvertTo-Json))
    [System.IO.File]::Move("$ResultPath.tmp", $ResultPath, $true)
    exit $Code
}
switch ($mode) {
    'exit0' { & $write 'done' $null @() 0 }
    'exit2' { & $write 'done' $null @('ring_held') 2 }
    'exit3' { & $write 'skipped' $null @('listener_disabled') 3 }
    'exit1' { & $write 'failed' 'pull_failed' @() 1 }
    'noresult' { exit 0 }
    'hang' { Start-Sleep -Seconds 600 }
}
'@).Replace('@MODE@', $Mode)
            $path
        }
    }

    It 'maps a stand-in step that exits <Mode> to <Outcome>' -ForEach @(
        @{ Mode = 'exit0'; Outcome = 'done'; Reason = $null; Remarks = ''; Attempts = 1 }
        @{ Mode = 'exit2'; Outcome = 'done'; Reason = $null; Remarks = 'ring_held'; Attempts = 1 }
        @{ Mode = 'exit3'; Outcome = 'skipped'; Reason = $null; Remarks = 'listener_disabled'; Attempts = 1 }
        @{ Mode = 'exit1'; Outcome = 'failed'; Reason = 'pull_failed'; Remarks = ''; Attempts = 1 }
        @{ Mode = 'noresult'; Outcome = 'failed'; Reason = 'step_interrupted'; Remarks = ''; Attempts = 3 }
        @{ Mode = 'hang'; Outcome = 'failed'; Reason = 'step_interrupted'; Remarks = ''; Attempts = 3 }
    ) {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture
        Enter-TestClaim -RequestId $id -Fixture $fixture
        $launched = [System.Collections.Generic.List[object]]::new()
        $context = New-HostUpdateControllerContext -ControllerRoot $fixture.ControllerRoot -Snapshot $fixture.Snapshot -Checkout $fixture.Checkout -Service @{
            Log = { param([string]$Line) $null = $Line }
            StartStep = { param($Launch) $started = & (Get-Module Test.HostUpdate) { param($L) Start-HostUpdateStepProcess -Launch $L -Confirm:$false } $Launch; $launched.Add($started); $started }.GetNewClosure()
        }
        $context.PrivateRoot = $fixture.PrivateRoot
        $context.RuntimeDir = $fixture.Runtime
        $context.CheckoutStepScript = New-StandInStep -Mode $Mode
        $context.Bound['preflight'] = 3
        $step = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $context; Id = $id } { param($Ctx, $Id) Invoke-HostUpdateStepPhase -Context $Ctx -RequestId $Id -Phase 'preflight' }
        Assert-Equal -Expected $Outcome -Actual $step.Outcome
        Assert-Equal -Expected ([string]$Reason) -Actual ([string]$step.Reason)
        Assert-Equal -Expected $Remarks -Actual ($step.Remarks -join ',')
        $entry = (Get-TestRow -RequestId $id)['update']['phases']['preflight']
        Assert-Equal -Expected $Attempts -Actual ([int]$entry['attempts']) 'an interrupted step runs again, three starts in all'
        Assert-Equal -Expected $Outcome -Actual ([string]$entry['outcome'])
        Assert-NotNull $entry['child'] 'the child identity is journaled'
        Assert-Equal -Expected $Attempts -Actual $launched.Count
        foreach ($started in $launched) {
            Assert-True $started.Launched 'the stand-in launches detached'
            Assert-Equal -Expected 'dead' -Actual (Get-YurunaProcessIdentityLiveness -ProcessId $started.Pid -StartTimeUnixMs $started.StartTimeUnixMs) 'no stand-in outlives its bound'
        }
        if ($Remarks) { Assert-Equal -Expected $Remarks -Actual ((Get-TestRow -RequestId $id)['update']['remarks'] -join ',') 'remarks join the update' }
    }
}

Describe 'finding step children by command line' {
    It 'finds only the pwsh child of the step script for this phase and request' {
        $id = New-YurunaHostOperationRequestId
        $other = New-YurunaHostOperationRequestId
        $step = '/srv/checkout/test/lab/Invoke-HostUpdateStep.ps1'
        $table = [pscustomobject]@{ Complete = $true; Rows = @(
                [pscustomobject]@{ Pid = 10; StartTimeUnixMs = 111; Argv = @('/usr/bin/pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $step, '-Step', 'update_source', '-RequestId', $id, '-Attempt', '2', '-ResultPath', '/x', '-RepoRoot', '/srv/checkout') }
                [pscustomobject]@{ Pid = 11; StartTimeUnixMs = 112; Argv = @('bash', '-c', 'set -m; nohup "$@"', 'yuruna-detach', '/srv', '/dev/null', '/usr/bin/pwsh', '-NoLogo', '-File', $step, '-Step', 'update_source', '-RequestId', $id, '-Attempt', '2') }
                [pscustomobject]@{ Pid = 12; StartTimeUnixMs = 113; Argv = @('/usr/bin/pwsh', '-File', $step, '-Step', 'start_runner', '-RequestId', $id, '-Attempt', '1') }
                [pscustomobject]@{ Pid = 13; StartTimeUnixMs = 114; Argv = @('/usr/bin/pwsh', '-File', $step, '-Step', 'update_source', '-RequestId', $other, '-Attempt', '1') }
                [pscustomobject]@{ Pid = 14; StartTimeUnixMs = 115; Argv = @('/usr/bin/pwsh', '-File', '/srv/checkout/test/lab/Other.ps1', '-Step', 'update_source', '-RequestId', $id, '-Attempt', '1') }
                [pscustomobject]@{ Pid = 15; StartTimeUnixMs = 116; Argv = @('/usr/bin/pwsh', '-File', $step, '-Step', 'update_source', '-RequestId', $id, '-Attempt', 'x') }
                [pscustomobject]@{ Pid = 16; StartTimeUnixMs = 117; Argv = @() }
            )
        }
        $found = @(InModuleScope Test.HostUpdate -Parameters @{ Table = $table; Id = $id } { param($Table, $Id) Find-HostUpdateStepProcess -Phase 'update_source' -RequestId $Id -ProcessTable $Table })
        Assert-Equal -Expected '10:111:2' -Actual (($found | ForEach-Object { "$($_.Pid):$($_.StartTimeUnixMs):$($_.Attempt)" }) -join ',') 'the launcher, other steps, other requests and other scripts are not step children'
    }

    It 'finds the step child in rows that carry only a joined command line, as macOS ps and Windows CIM give them' {
        $id = New-YurunaHostOperationRequestId
        $other = New-YurunaHostOperationRequestId
        $step = '/Users/u/git/yuruna/test/lab/Invoke-HostUpdateStep.ps1'
        $lines = @(
            "   10     1    10   501 Mon Nov 23 10:00:00 2026 /usr/local/microsoft/powershell/7/pwsh -NoLogo -NoProfile -NonInteractive -File $step -Step install -RequestId $id -Attempt 2 -ResultPath /x"
            "   11     1    11   501 Mon Nov 23 10:00:00 2026 bash -c set -m; nohup `"`$@`" yuruna-detach /srv /dev/null /usr/local/microsoft/powershell/7/pwsh -File $step -Step install -RequestId $id -Attempt 2"
            "   12     1    12   501 Mon Nov 23 10:00:00 2026 /usr/local/microsoft/powershell/7/pwsh -File $step -Step enable -RequestId $id -Attempt 1"
            "   13     1    13   501 Mon Nov 23 10:00:00 2026 /usr/local/microsoft/powershell/7/pwsh -File $step -Step install -RequestId $other -Attempt 1"
        )
        $rows = @(& (Get-Module Test.SingleInstance) { param($Lines) foreach ($line in $Lines) { ConvertFrom-YurunaPsLine -Line $line } } $lines)
        Assert-Equal -Expected 4 -Actual $rows.Count 'fixture sanity: every ps line parses'
        Assert-Equal -Expected 0 -Actual @($rows | Where-Object { $null -ne $_.Argv }).Count 'fixture sanity: a ps row carries no argument vector'
        # A Windows command line quotes a path with spaces.
        $rows += [pscustomobject]@{ Pid = 20; ParentPid = 1; StartTimeUnixMs = [long]120; OwnerId = '1'; Argv = $null
            CommandLine = "`"C:\Program Files\PowerShell\7\pwsh.exe`" -NoLogo -File `"C:\Users\u\My Repos\yuruna\test\lab\Invoke-HostUpdateStep.ps1`" -Step install -RequestId $id -Attempt 3" }
        $table = [pscustomobject]@{ Complete = $true; Rows = $rows }
        $found = @(InModuleScope Test.HostUpdate -Parameters @{ Table = $table; Id = $id } { param($Table, $Id) Find-HostUpdateStepProcess -Phase 'install' -RequestId $Id -ProcessTable $Table })
        Assert-Equal -Expected '10:2,20:3' -Actual (($found | ForEach-Object { "$($_.Pid):$($_.Attempt)" }) -join ',') 'the pwsh child is found, not its launcher, another step or another request'
        Assert-Equal -Expected ([long]$rows[0].StartTimeUnixMs) -Actual ([long]$found[0].StartTimeUnixMs)
    }

    It 'finds a real detached step child in the process table' -Skip:$IsWindows {
        $dir = Join-Path $script:ScratchBase ('find-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script = Join-Path $dir 'Invoke-HostUpdateStep.ps1'
        Set-Content -LiteralPath $script -Value 'param([string]$Step, [string]$RequestId, [int]$Attempt) Start-Sleep -Seconds 60'
        $id = New-YurunaHostOperationRequestId
        $launch = @{
            ScriptPath = $script; ArgumentList = [string[]]@('-Step', 'start_runner', '-RequestId', $id, '-Attempt', '3'); WorkingDirectory = $dir
            Environment = @{}; StdOutPath = (Join-Path $dir 'out'); StdErrPath = (Join-Path $dir 'err'); PrivateDirectory = $dir
        }
        $started = & (Get-Module Test.HostUpdate) { param($L) Start-HostUpdateStepProcess -Launch $L -Confirm:$false } $launch
        Assert-True $started.Launched "fixture sanity: the stand-in launches ($($started.Reason))"
        try {
            $found = @(InModuleScope Test.HostUpdate -Parameters @{ Id = $id } { param($Id) Find-HostUpdateStepProcess -Phase 'start_runner' -RequestId $Id })
            Assert-Equal -Expected "$($started.Pid):3" -Actual (($found | ForEach-Object { "$($_.Pid):$($_.Attempt)" }) -join ',') 'the child the launch reported is found with its attempt'
            Assert-Equal -Expected 'alive' -Actual (Get-YurunaProcessIdentityLiveness -ProcessId $found[0].Pid -StartTimeUnixMs $found[0].StartTimeUnixMs) 'its start time identifies it'
        } finally {
            $null = Stop-YurunaProcessTree -ProcessId $started.Pid -Confirm:$false
        }
    }
}

Describe 'stopping the listener' -Skip:$IsWindows {
    It 'stops the live listener server.pid names and returns once it has exited' {
        $runtime = Join-Path $script:ScratchBase ('listener-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $runtime -Force
        $service = Join-Path $runtime '.status-service.ps1'
        Set-Content -LiteralPath $service -Value 'Start-Sleep -Seconds 60'
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $service) -PassThru `
            -RedirectStandardOutput (Join-Path $runtime 'out') -RedirectStandardError (Join-Path $runtime 'err')
        $script:Spawned.Add($process)
        $liveStart = [DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds()
        # The service writes its pidfile after it starts; the write time dates it.
        Start-Sleep -Milliseconds 500
        [System.IO.File]::WriteAllText((Join-Path $runtime 'server.pid'), "$($process.Id)")
        $seen = [System.Collections.Generic.List[object]]::new()
        $real = (Get-Module Yuruna.Common).ExportedFunctions['Get-YurunaProcessIdentityLiveness']
        # A closure sees the mocked call's arguments only through a param block of its own.
        Mock Get-YurunaProcessIdentityLiveness -ModuleName Test.HostUpdate {
            param($ProcessId, $StartTimeUnixMs)
            $seen.Add($StartTimeUnixMs)
            & $real -ProcessId $ProcessId -StartTimeUnixMs $StartTimeUnixMs
        }.GetNewClosure()
        $stopped = & (Get-Module Test.HostUpdate) { param($Dir) Stop-HostUpdateListenerProcess -RuntimeDir $Dir -Confirm:$false } $runtime
        Assert-True ($process.WaitForExit(5000)) 'the listener is gone'
        Assert-True $stopped 'the stop reports the listener gone'
        Assert-True ($seen.Count -ge 1) 'its exit is checked by identity'
        foreach ($value in $seen) {
            # A start time of none answers unknown for any live pid: a reused
            # pid would hold the wait to its bound.
            Assert-NotNull $value 'the wait checks the start time the identity check read'
            Assert-True ([Math]::Abs([long]$value - $liveStart) -le 2000) "the start time is the listener's: $value vs $liveStart"
        }
    }
}

Describe 'step children the journal does not name' {
    BeforeEach {
        $script:Fixture = New-ControllerFixture
        $script:Id = Add-TestUpdate -Fixture $script:Fixture
        Enter-TestClaim -RequestId $script:Id -Fixture $script:Fixture
        $script:Fake = New-FakeService -Fixture $script:Fixture
        $script:Context = New-TestContext -Fixture $script:Fixture -Fake $script:Fake
        $script:Work = Join-Path $script:Fixture.ControllerRoot "work/$($script:Id)"
    }

    It 'adopts a live child of a started attempt that has no child recorded instead of launching another' {
        $null = Set-HostUpdatePhase -RequestId $script:Id -ControllerPid $PID -Phase update_source -State started -Confirm:$false
        $childPid = 4199001
        $script:Fake.Found.Add(@{ Phase = 'update_source'; RequestId = $script:Id; Pid = $childPid; StartTimeUnixMs = $script:Fake.Clock.Ms; Attempt = 1 })
        $script:Fake.Hang[$childPid] = $script:Fake.Clock.Tick + 3000
        $script:Fake.Pending[$childPid] = @{ Path = (Join-Path $script:Work 'update_source.1.result.json'); Text = (New-TestStepResultText -Step update_source -RequestId $script:Id -Attempt 1) }
        $step = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateStepPhase -Context $Ctx -RequestId $Id -Phase 'update_source' }
        Assert-Equal -Expected 0 -Actual $script:Fake.Launches.Count 'no second child runs beside the first'
        Assert-Equal -Expected 'done' -Actual $step.Outcome 'the adopted child''s result is read'
        $entry = (Get-TestRow -RequestId $script:Id)['update']['phases']['update_source']
        Assert-Equal -Expected 1 -Actual ([int]$entry['attempts'])
        Assert-Equal -Expected $childPid -Actual ([int]$entry['child']['pid']) 'the adopted child is journaled'
        Assert-True ($script:Fake.Log | Where-Object { $_ -match 'event=step-adopted .*recorded=no' }) 'the adoption is logged'
    }

    It 'adopts the child a launch forked before it reported failure' {
        $fake = $script:Fake
        $resultText = ${function:New-TestStepResultText}
        $script:Context.Service.StartStep = {
            param($Launch)
            $fake.Launches.Add($Launch)
            $childPid = $fake.NextPid; $fake.NextPid++
            $fake.Hang[$childPid] = $fake.Clock.Tick + 3000
            $fake.Pending[$childPid] = @{ Path = $Launch.ResultPath; Text = (& $resultText -Step $Launch.Step -RequestId $Launch.RequestId -Attempt $Launch.Attempt) }
            $fake.Found.Add(@{ Phase = $Launch.Step; RequestId = $Launch.RequestId; Pid = $childPid; StartTimeUnixMs = $fake.Clock.Ms; Attempt = $Launch.Attempt })
            [pscustomobject]@{ Launched = $false; Pid = $null; StartTimeUnixMs = $null; Reason = 'launcher-failed' }
        }.GetNewClosure()
        $step = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateStepPhase -Context $Ctx -RequestId $Id -Phase 'update_source' }
        Assert-Equal -Expected 1 -Actual $fake.Launches.Count 'the forked child is waited for, not launched again'
        Assert-Equal -Expected 'done' -Actual $step.Outcome
        $entry = (Get-TestRow -RequestId $script:Id)['update']['phases']['update_source']
        Assert-Equal -Expected 1 -Actual ([int]$entry['attempts'])
        Assert-Equal -Expected 4100000 -Actual ([int]$entry['child']['pid'])
    }

    It 'ends an unnamed child past its bound and sees it dead before the next attempt' {
        $null = Set-HostUpdatePhase -RequestId $script:Id -ControllerPid $PID -Phase update_source -State started -Confirm:$false
        $childPid = 4199002
        $script:Fake.Found.Add(@{ Phase = 'update_source'; RequestId = $script:Id; Pid = $childPid; StartTimeUnixMs = $script:Fake.Clock.Ms - 400000; Attempt = 1 })
        $script:Fake.Hang[$childPid] = $script:Fake.Clock.Tick + 3600000
        $fake = $script:Fake
        $inner = $script:Context.Service.StartStep
        $order = [System.Collections.Generic.List[string]]::new()
        $script:Context.Service.StartStep = { param($Launch) $order.Add("launch:$($fake.Killed -join '+')"); & $inner $Launch }.GetNewClosure()
        $step = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateStepPhase -Context $Ctx -RequestId $Id -Phase 'update_source' }
        Assert-Equal -Expected "launch:$childPid" -Actual ($order -join ',') 'the old child is ended before the next attempt is launched'
        Assert-Equal -Expected 'done' -Actual $step.Outcome
        Assert-Equal -Expected 2 -Actual ([int](Get-TestRow -RequestId $script:Id)['update']['phases']['update_source']['attempts'])
    }
}

Describe 'the controller' {
    It 'exits 76 while another instance holds the lock' -Skip:$IsWindows {
        $fixture = New-ControllerFixture
        $lockPath = Get-HostUpdateControllerLockPath
        $marker = Join-Path $fixture.Home 'held'
        $holder = Join-Path $script:ScratchBase ('holder-' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
        Set-Content -LiteralPath $holder -Value @"
Import-Module '$(Join-Path $script:RepoRoot 'test/modules/Test.SingleFlightLock.psm1')' -DisableNameChecking
`$lock = Enter-YurunaSingleFlightLock -Path '$lockPath' -WaitMilliseconds 2000
if (`$lock.Held) { Set-Content -LiteralPath '$marker' -Value held; Start-Sleep -Seconds 60 }
"@
        $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $holder)) { $info.ArgumentList.Add($argument) }
        $info.Environment['HOME'] = $fixture.Home
        $info.Environment['NO_COLOR'] = '1'
        $info.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($info)
        $script:Spawned.Add($process)
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-True (Test-Path -LiteralPath $marker) 'fixture sanity: another process holds the controller lock'
        $fake = New-FakeService -Fixture $fixture -ShouldStop { $true }
        Assert-Equal -Expected 76 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.ControllerRoot "versions/$($fixture.Snapshot)/ok")) 'a controller that never ran its loop writes no ok'
        $process.Kill($true)
        $null = $process.WaitForExit(10000)
    }

    It 'creates ok after a journal read, even of a corrupt journal' {
        $fixture = New-ControllerFixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.PrivateRoot 'host-operation.journal'), 'not a journal')
        $fake = New-FakeService -Fixture $fixture -ShouldStop { $true }
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.ControllerRoot "versions/$($fixture.Snapshot)/ok")) 'the snapshot started'
        Assert-True ($fake.Log | Where-Object { $_ -match 'event=started .*journal=corrupt' }) 'the corrupt journal is read as data'
    }

    It 'publishes its state with the snapshot, heartbeat and scopes' {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $null = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        $state = Get-Content -LiteralPath (Join-Path $fixture.Runtime 'host-controller.state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'schemaVersion,snapshot,protocol,pid,startTimeUnixMs,startedUtc,heartbeatUtc,activity,requestId,session,sessionUsable,scopes' -Actual ($state.Keys -join ',')
        Assert-Equal -Expected $fixture.Snapshot -Actual $state['snapshot']
        Assert-Equal -Expected 1 -Actual $state['protocol']
        Assert-Equal -Expected $PID -Actual $state['pid']
        Assert-Equal -Expected 'restart' -Actual $state['scopes']
        Assert-Equal -Expected 'system-unit' -Actual $state['session']
        Assert-True ([bool]$state['sessionUsable'])
    }

    It 'stages a new snapshot and exits 75 when the checkout changed and nothing is claimed' {
        $fixture = New-ControllerFixture
        Add-Content -LiteralPath (Join-Path $fixture.Checkout 'automation/A.psm1') -Value '# newer'
        $newer = (Get-HostUpdateSnapshotManifest -SourceRoot $fixture.Checkout).Hash16
        $fake = New-FakeService -Fixture $fixture
        Assert-Equal -Expected 75 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        $current = Read-HostUpdateControllerCurrent -ControllerRoot $fixture.ControllerRoot
        Assert-Equal -Expected $newer -Actual $current.Current
        Assert-Equal -Expected $fixture.Snapshot -Actual $current.Previous
        Assert-Equal -Expected $fixture.Checkout -Actual $current.Checkout
        Assert-Equal -Expected ((@($fixture.Snapshot, $newer) | Sort-Object) -join ',') -Actual ((Get-ChildItem -LiteralPath (Join-Path $fixture.ControllerRoot 'versions') -Name | Sort-Object) -join ',')
        Assert-True (($fake.Clock.Ms - $fake.StartMs) -ge 300000) 'an idle controller compares every 300 s'
    }

    It 'leaves a queued request queued and marks protocol_mismatch when the new snapshot is rejected' {
        $fixture = New-ControllerFixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.Checkout 'test/host-update.protocol-version'), '2')
        $rejected = (Get-HostUpdateSnapshotManifest -SourceRoot $fixture.Checkout).Hash16
        [System.IO.File]::WriteAllText((Join-Path $fixture.ControllerRoot 'rejected'), "$rejected`n")
        $id = Add-TestUpdate -Fixture $fixture
        $fake = New-FakeService -Fixture $fixture
        $fake.Service.ShouldStop = { param($Context) $null = $Context; $fake.Clock.Ms - $fake.StartMs -ge 12000 }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'queued' -Actual $row['state']
        Assert-Equal -Expected 'protocol_mismatch' -Actual $row['update']['claimBlocked']
        Assert-Equal -Expected 0 -Actual $fake.Launches.Count 'nothing from that checkout is started'
        Assert-Equal -Expected 'queued' -Actual (Get-TestPublicState -Fixture $fixture)['state']
        Assert-Equal -Expected $fixture.Snapshot -Actual (Read-HostUpdateControllerCurrent -ControllerRoot $fixture.ControllerRoot).Current
    }

    It 'refuses a claimed row whose scope it does not run before phase 1' {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        # A host type that runs the restart scope only, as macOS does until
        # the full scope is qualified there.
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure { param($Fake) $Fake.Service.SupportedScope = { [string[]]@('restart') } }
        Assert-Equal -Expected 'refused' -Actual $run.Row['state']
        Assert-Equal -Expected 'refused' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'scope_unavailable' -Actual $run.Row['update']['reason']
        Assert-Equal -Expected 'none' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 0 -Actual @($run.Row['update']['phases'].Keys).Count 'no phase started'
        Assert-Equal -Expected 0 -Actual $run.Fake.Launches.Count
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'runs the six phases and ends updated with the gate open' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            Add-StepPlan -Fake $Fake -Step 'update_source' -Spec @(@{ Commit = @{ before = 'aaaaaaa'; after = 'bbbbbbb' } })
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @(@{ Commit = @{ resident = 'bbbbbbb' }; Console = 'tmux' })
        }
        Assert-Equal -Expected 0 -Actual $run.Exit
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'none' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,start_listener,start_runner' -Actual (($run.Fake.Launches | ForEach-Object { $_.Step }) -join ',')
        Assert-Equal -Expected 'unclean-exit' -Actual $run.Row['update']['runnerPlan']['basis']
        $obligations = Get-TestObligation -RequestId $id
        Assert-Equal -Expected 'discharged' -Actual $obligations['gate']
        Assert-Equal -Expected 'discharged' -Actual $obligations['runner']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected 'terminal' -Actual $public['state']
        Assert-Equal -Expected 'updated' -Actual $public['verdict']
        Assert-Equal -Expected 'bbbbbbb' -Actual $public['commit']['resident']
        Assert-Equal -Expected 'tmux' -Actual $public['runnerConsole']
        Assert-True ([bool]$public['mutated']) 'a source update that moved the checkout mutated the host'
        $launch = $run.Fake.Launches[0]
        Assert-Equal -Expected $fixture.Runtime -Actual $launch.Environment.YURUNA_RUNTIME_DIR 'the step child gets the row runtime directory'
        Assert-Equal -Expected "-Step,preflight,-RequestId,$id,-Attempt,1,-ResultPath,$($launch.ResultPath),-RepoRoot,$($fixture.Checkout)" -Actual ($launch.ArgumentList -join ',')
        Assert-Match -Pattern ([regex]::Escape((Join-Path $fixture.ControllerRoot "work/$id")) + '/preflight\.1\.result\.json$') -Actual $launch.ResultPath
        Assert-Match -Pattern '-ControllerPid' -Actual ($run.Fake.Launches[4].ArgumentList -join ' ')
    }

    It 'ends updated_not_started when the runner was stopped by an operator' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $true
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 'updated_not_started' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'start_runner' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'clean-exit' -Actual $run.Row['update']['runnerPlan']['basis']
        Assert-False (($run.Fake.Launches | ForEach-Object { $_.Step }) -contains 'start_runner') 'no runner is started'
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'refuses with the step reason and action when preflight fails' {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'preflight' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_elevation_missing'; Action = 'provision_elevation' })
        }
        Assert-Equal -Expected 'refused' -Actual $run.Row['state']
        Assert-Equal -Expected 'runner_elevation_missing' -Actual $run.Row['update']['reason']
        Assert-Equal -Expected 'provision_elevation' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'preflight' -Actual (($run.Fake.Launches | ForEach-Object { $_.Step }) -join ',')
        Assert-Null (Get-TestObligation -RequestId $id)['gate'] 'nothing was taken away'
    }

    It 'opens the gate and ends stop_failed when the runner cannot be stopped' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'stop_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_survived'; Reclaimed = @{ inner = @{ pid = 4242; startTimeUnixMs = 99 } } })
        }
        Assert-Equal -Expected 'stop_failed' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'stop_runner_by_hand' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 4242 -Actual ([int]$run.Row['update']['reclaimed']['inner']['pid']) 'stopped identities are journaled whatever the outcome'
        $obligations = Get-TestObligation -RequestId $id
        Assert-Equal -Expected 'disposed' -Actual $obligations['runner']
        Assert-Equal -Expected 'discharged' -Actual $obligations['gate']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'restores after an update_source failure' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'update_source' -Spec @(@{ Outcome = 'failed'; Reason = 'commit_mismatch' })
        }
        Assert-Equal -Expected 'failed_restored' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'commit_mismatch' -Actual $run.Row['update']['reason']
        Assert-Equal -Expected 'read_remarks' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,start_runner' -Actual (($run.Fake.Launches | ForEach-Object { $_.Step }) -join ',') 'restore starts the runner on the checkout as it is'
        Assert-Equal -Expected 'done' -Actual $run.Row['update']['phases']['restore']['outcome']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'records a failed listener start as debt and goes on' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $true
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'start_listener' -Spec @(@{ Outcome = 'failed'; Reason = 'step_interrupted' })
        }
        Assert-Equal -Expected 'updated_not_started' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'listener:start_listener' -Actual (($run.Row['update']['debt'] | ForEach-Object { "$($_['obligation']):$($_['action'])" }) -join ',')
        Assert-Equal -Expected 'start_listener' -Actual (Get-TestPublicState -Fixture $fixture)['debt'][0]['action']
    }

    It 'replaces its snapshot after the source update when the protocol number moved' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $true
        $id = Add-TestUpdate -Fixture $fixture
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $checkout = $fixture.Checkout
        $fake.Service.StartStep = {
            param($Launch)
            if ($Launch.Step -eq 'update_source') { [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '2') }
            $result = [ordered]@{ schemaVersion = 1; step = $Launch.Step; requestId = $Launch.RequestId; attempt = $Launch.Attempt; outcome = 'done'; protocol = if ($Launch.Step -eq 'update_source') { 2 } else { 1 } }
            [System.IO.File]::WriteAllText($Launch.ResultPath, ($result | ConvertTo-Json))
            [pscustomobject]@{ Launched = $true; Pid = 4199999; StartTimeUnixMs = [long]1; Reason = 'launched' }
        }.GetNewClosure()
        $fake.Service.StepLiveness = { param($ProcessId, $StartTimeUnixMs) $null = $ProcessId, $StartTimeUnixMs; 'dead' }
        Assert-Equal -Expected 75 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        $current = Read-HostUpdateControllerCurrent -ControllerRoot $fixture.ControllerRoot
        Assert-False ($current.Current -ceq $fixture.Snapshot) 'the checkout snapshot is current'
        Assert-Equal -Expected $fixture.Snapshot -Actual $current.Previous
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'running' -Actual $row['state'] 'the next controller continues at phase 8'
        Assert-Equal -Expected 'done' -Actual $row['update']['phases']['update_source']['outcome']
        # The next controller runs from the new snapshot and finishes.
        $next = [pscustomobject]@{ Home = $fixture.Home; Runtime = $fixture.Runtime; Checkout = $fixture.Checkout; PrivateRoot = $fixture.PrivateRoot; ControllerRoot = $fixture.ControllerRoot; Snapshot = $current.Current }
        $second = New-FakeService -Fixture $next -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $next -Fake $second)
        Assert-Equal -Expected 'start_listener' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',')
        Assert-Equal -Expected 'updated_not_started' -Actual (Get-TestRow -RequestId $id)['update']['verdict']
    }

    It 'goes recovering when the protocol moved and the new snapshot cannot be staged' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $checkout = $fixture.Checkout
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $fake -Step 'update_source' -Spec @(@{ Protocol = 2 })
        $inner = $fake.Service.StartStep
        $fake.Service.StartStep = {
            param($Launch)
            if ($Launch.Step -eq 'update_source') {
                [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '2')
                Set-Content -LiteralPath (Join-Path $checkout 'test/modules/B.psm1') -Value 'function Get-B {'
            }
            & $inner $Launch
        }.GetNewClosure()
        $fake.SleepHook = {
            param($Fake)
            $null = $Fake
            $row = Get-HostUpdateRequest -RequestId $id
            if ([string]$row['state'] -eq 'recovery-pending' -and -not $row['update']['release']) { $null = Request-HostUpdateRelease -RequestId $id -Actor 'tester' -Confirm:$false }
        }.GetNewClosure()
        $null = Invoke-TestController -Fixture $fixture -Fake $fake
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'released' -Actual $row['update']['verdict'] 'the operation was recovering until released'
        Assert-True ($fake.Log | Where-Object { $_ -match 'event=recovering .*reason=protocol_mismatch' }) 'recovering for the protocol mismatch'
        Assert-Equal -Expected $fixture.Snapshot -Actual (Read-HostUpdateControllerCurrent -ControllerRoot $fixture.ControllerRoot).Current
    }
}

Describe 'the full scope' {
    BeforeAll {
        function Get-TestStepList { param($Run) ($Run.Fake.Launches | ForEach-Object { $_.Step }) -join ',' }
        function Get-TestRuleCall { param($Run) @($Run.Fake.Native | Where-Object { $_ -like 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update' }) }
        $script:UnitListCall = 'sudo -n systemctl list-units*'
        $script:TimerStopCall = 'sudo -n systemctl stop yuruna-host-update-expire.timer'
    }

    It 'runs install and enable between the source update and the listener on KVM, and leaves no rule behind' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # Units systemctl still lists are ended whichever request started them.
            $Fake.NativeOut['sudo -n systemctl list-units*'] = "yuruna-host-update-install-1.service loaded active running stand-in`nyuruna-host-update-enable-1.service loaded inactive dead stand-in`n"
        }
        Assert-Equal -Expected 0 -Actual $run.Exit
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,install,enable,start_listener,start_runner' -Actual (Get-TestStepList -Run $run)
        $obligations = Get-TestObligation -RequestId $id
        Assert-Equal -Expected 'discharged' -Actual $obligations['elevation'] 'the rule is removed after each privileged phase'
        Assert-Equal -Expected 2 -Actual (Get-TestRuleCall -Run $run).Count 'once after install, once after enable'
        Assert-True (@($run.Fake.Native | Where-Object { $_ -like $script:UnitListCall }).Count -ge 2) 'the units are listed after each privileged phase'
        Assert-True ($run.Fake.Native -contains 'sudo -n systemctl stop yuruna-host-update-install-1.service') 'the install unit is ended'
        Assert-True ($run.Fake.Native -contains 'sudo -n systemctl stop yuruna-host-update-enable-1.service') 'the enable unit is ended'
        Assert-True ($run.Fake.Native -contains $script:TimerStopCall) 'a rule that is gone needs its expiry timer no more'
        Assert-Equal -Expected 0 -Actual $run.Fake.ListenerStops.Count 'an unchanged PowerShell leaves the listener up'
    }

    It 'discharges the elevation when systemctl lists no unit left' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        # A unit run with --collect is gone once it ends: the list is empty.
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['elevation']
        Assert-Equal -Expected 0 -Actual @($run.Fake.Native | Where-Object { $_ -like 'sudo -n systemctl stop yuruna-host-update-install*' -or $_ -like 'sudo -n systemctl stop yuruna-host-update-enable*' }).Count 'no unit is left to end'
        Assert-Equal -Expected 0 -Actual @((Get-TestPublicState -Fixture $fixture)['debt']).Count
    }

    It 'keeps the elevation armed as debt when systemctl cannot list the units' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure { param($Fake) $Fake.NativeExit['sudo -n systemctl list-units*'] = 1 }
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['elevation'] 'a unit nobody could list may still run'
        Assert-Equal -Expected 2 -Actual (Get-TestRuleCall -Run $run).Count 'the rule is still removed after each privileged phase'
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected 'elevation' -Actual $public['debt'][0]['obligation']
        Assert-Equal -Expected 'remove_sudo_rule' -Actual $public['debt'][0]['action']
    }

    It 'clears the elevation the next run finds armed after a stop between the <Phase> result and the clear' -Skip:(-not $IsLinux) -ForEach @(
        @{ Phase = 'install'; Steps = 'enable,start_listener,start_runner' }
        @{ Phase = 'enable'; Steps = 'start_listener,start_runner' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $first.CrashAt = @{ Phase = $Phase; State = 'finished' }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first) 'the first controller is interrupted'
        Assert-True $first.Crashed "fixture sanity: the run reached $Phase finished"
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['elevation'] 'fixture sanity: the clear never ran'
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        # How many native calls came before the next step child, so the
        # clear is seen to come from the walk's start and not from a later
        # privileged phase's own clear.
        $launchAt = [System.Collections.Generic.List[int]]::new()
        $inner = $second.Service.StartStep
        $native = $second.Native
        $second.Service.StartStep = { param($Launch) $launchAt.Add($native.Count); & $inner $Launch }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        Assert-Equal -Expected $Steps -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',') 'the finished phase is not run again'
        $firstRemove = [Array]::FindIndex([string[]]@($second.Native), [Predicate[string]] { param($c) $c -eq 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update' })
        Assert-True ($firstRemove -ge 0 -and $firstRemove -lt $launchAt[0]) 'the rule goes before the next phase starts'
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'updated' -Actual $row['update']['verdict']
        $elevation = @($row['obligations'] | Where-Object { $_ -and [string]$_['id'] -eq 'elevation' })[0]
        Assert-Equal -Expected 'discharged' -Actual ([string]$elevation['status'])
        Assert-Equal -Expected 'rule-removed' -Actual ([string]$elevation['evidence'])
        Assert-True (@($second.Native | Where-Object { $_ -like 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update' }).Count -ge 1) 'the next run removes the rule'
        Assert-Equal -Expected 0 -Actual @((Get-TestPublicState -Fixture $fixture)['debt']).Count 'no rule is left as debt'
    }

    It 'restores after a failed install, with the unit ended and the rule removed, and runs no enable' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'install' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_present' })
        }
        Assert-Equal -Expected 'failed_restored' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'runner_present' -Actual $run.Row['update']['reason']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,install,start_runner' -Actual (Get-TestStepList -Run $run) 'restore starts the runner'
        # Windows runs the privileged phases elevated already: no rule, no obligation.
        if ($IsLinux) {
            Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['elevation']
            Assert-True ((Get-TestRuleCall -Run $run).Count -ge 1) 'the rule is removed'
        }
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'restores after a failed enable' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'enable' -Spec @(@{ Outcome = 'failed'; Reason = 'enable_failed' })
        }
        Assert-Equal -Expected 'failed_restored' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'enable_failed' -Actual $run.Row['update']['reason']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,install,enable,start_runner' -Actual (Get-TestStepList -Run $run)
        if ($IsLinux) {
            Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['elevation']
            Assert-Equal -Expected 2 -Actual (Get-TestRuleCall -Run $run).Count 'once after install, once after enable'
        }
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'lists a rule it could not remove as debt' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) $Fake.NativeExit['sudo -n rm -f /etc/sudoers.d/yuruna-host-update'] = 1
        }
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['elevation']
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected 'elevation' -Actual $public['debt'][0]['obligation']
        Assert-Equal -Expected 'remove_sudo_rule' -Actual $public['debt'][0]['action']
        Assert-False ($run.Fake.Native -contains $script:TimerStopCall) 'a rule rm could not remove keeps the timer that removes it'
    }

    It 'passes the enable remark and the install issues through' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            Add-StepPlan -Fake $Fake -Step 'install' -Spec @(@{ Remarks = @('install_issues') })
            Add-StepPlan -Fake $Fake -Step 'enable' -Spec @(@{ Remarks = @('host_settings_unmet') })
        }
        Assert-Equal -Expected 'updated_with_remarks' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'install_issues,host_settings_unmet' -Actual (@((Get-TestPublicState -Fixture $fixture)['remarks']) -join ',')
    }

    It 'stops the listener and exits 75 once when the install changed PowerShell, then goes on in the next run' -Skip:(-not $IsLinux) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $first = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake) Add-StepPlan -Fake $Fake -Step 'install' -Spec @(@{ Extra = @{ pwshChanged = $true } })
        }
        Assert-Equal -Expected 75 -Actual $first.Exit 'every later phase runs on the new PowerShell'
        Assert-Equal -Expected 1 -Actual $first.Fake.ListenerStops.Count
        Assert-Equal -Expected $fixture.Runtime -Actual $first.Fake.ListenerStops[0]
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['listener']
        $public = Get-TestPublicState -Fixture $fixture
        # ConvertFrom-Json turns an ISO time into a DateTime of its own.
        $value = $public['listenerExpectedBackUtc']
        $back = if ($value -is [datetime]) { [DateTimeOffset]::new($value.ToUniversalTime()).ToUnixTimeMilliseconds() } else {
            [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds()
        }
        $ahead = $back - $first.Fake.Clock.Ms
        Assert-True ($ahead -gt 355000 -and $ahead -le 360000) "the bounds of enable and the listener start lie in between: $ahead ms ahead"
        $logText = $first.Fake.Log -join ' '
        Assert-Match -Pattern 'event=listener-stopped' -Actual $logText
        $second = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 0 -Actual $second.Exit
        Assert-Equal -Expected 'enable,start_listener,start_runner' -Actual (Get-TestStepList -Run $second) 'the finished install is not run again'
        Assert-Equal -Expected 0 -Actual $second.Fake.ListenerStops.Count 'a continuation does not stop the listener again'
        Assert-Equal -Expected 'updated' -Actual $second.Row['update']['verdict']
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['listener']
        Assert-Null (Get-TestPublicState -Fixture $fixture)['listenerExpectedBackUtc'] 'the expected time goes once the listener answers'
    }

    It 'ends reboot_required, with the gate open and nothing tried again, when Windows must restart' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            Add-StepPlan -Fake $Fake -Step 'install' -Spec @(@{ Extra = @{ restartRequired = $true } })
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'config_gate_failed'; Action = 'act_at_host' })
        }
        Assert-Equal -Expected 'completed' -Actual $run.Row['state']
        Assert-Equal -Expected 'reboot_required' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'reboot_host' -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'disposed' -Actual (Get-TestObligation -RequestId $id)['runner']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        Assert-Equal -Expected 1 -Actual @($run.Fake.Launches | Where-Object { $_.Step -eq 'start_runner' }).Count 'the start is made once'
    }

    It 'publishes restart,full only while the elevation probe passes, and probes again after ten minutes' {
        $fixture = New-ControllerFixture
        # A finished update gives the controller its runtime directory.
        $null = Invoke-TestUpdate -Fixture $fixture -RequestId (Add-TestUpdate -Fixture $fixture)
        $holder = @{ Fake = $null }
        # Past three intervals: a host that lists full already is not probed
        # on a timer, so no probe follows the one at ten minutes.
        $fake = New-FakeService -Fixture $fixture -ShouldStop { param($Context) $null = $Context; $holder.Fake.Clock.Ms - $holder.Fake.StartMs -ge 1900000 }.GetNewClosure()
        $holder.Fake = $fake
        $fake.SleepHook = { param($F) if ($F.Clock.Ms - $F.StartMs -ge 300000) { $F.FullReady = $true } }
        $null = Invoke-TestController -Fixture $fixture -Fake $fake
        $state = Get-Content -LiteralPath (Join-Path $fixture.Runtime 'host-controller.state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'restart,full' -Actual $state['scopes'] 'a probe that passes later opens the scope without a restart'
        Assert-Equal -Expected '0,600000' -Actual (@($fake.ProbeAt) -join ',') 'one probe at start, one ten minutes later, none on a timer once full is listed'
        $fresh = New-FakeService -Fixture $fixture -ShouldStop { $true }
        $null = Invoke-TestController -Fixture $fixture -Fake $fresh
        $state = Get-Content -LiteralPath (Join-Path $fixture.Runtime 'host-controller.state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Expected 'restart' -Actual $state['scopes'] 'a host whose probe fails offers restart only'
    }

    It 'reads the shim''s result once, journaled before the file goes: <Case>' -ForEach @(
        @{ Case = 'ok'; Text = '{"schemaVersion":1,"reason":"ok"}'; Failed = $false }
        @{ Case = 'failed'; Text = '{"schemaVersion":1,"reason":"failed"}'; Failed = $true }
        @{ Case = 'installer_refused'; Text = '{"schemaVersion":1,"reason":"installer_refused"}'; Failed = $true }
        @{ Case = 'missing'; Text = $null; Failed = $true }
        @{ Case = 'unreadable'; Text = '{"schemaVersion":1,"reason":'; Failed = $true }
    ) {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        Enter-TestClaim -RequestId $id -Fixture $fixture
        $context = New-TestContext -Fixture $fixture -Fake (New-FakeService -Fixture $fixture)
        # The controller that exits 77 leaves the phase started; the shim
        # writes its result and consumes the request before it starts the next.
        $null = Set-HostUpdatePhase -RequestId $id -ControllerPid $PID -Phase upgrade_pwsh -State started -Confirm:$false
        $resultPath = Join-Path $fixture.ControllerRoot 'pwsh-upgrade.result'
        if ($null -ne $Text) { [System.IO.File]::WriteAllText($resultPath, $Text) }
        $upgrade = { param($Ctx, $RequestId) Invoke-HostUpdatePwshUpgrade -Context $Ctx -RequestId $RequestId }
        # A journal write that fails ends the controller before the outcome is
        # recorded, as a kill there would: a pid that no longer owns the row.
        $context.ControllerPid = 1
        $stopped = $null
        try { $null = & (Get-Module Test.HostUpdate) $upgrade $context $id } catch { $stopped = $_.Exception.Message }
        Assert-Match -Pattern 'journal-write-failed' -Actual ([string]$stopped) 'fixture sanity: the outcome write failed'
        Assert-Equal -Expected 'started' -Actual ([string](Get-TestRow -RequestId $id)['update']['phases']['upgrade_pwsh']['state'])
        if ($null -ne $Text) { Assert-True ([System.IO.File]::Exists($resultPath)) 'the result stays until its outcome is journaled' }
        $context.ControllerPid = $PID
        $run = & (Get-Module Test.HostUpdate) $upgrade $context $id
        Assert-Equal -Expected 'done' -Actual $run.Outcome
        Assert-Null $run.Exit 'a started upgrade is read, never handed to the shim again'
        $entry = (Get-TestRow -RequestId $id)['update']['phases']['upgrade_pwsh']
        Assert-Equal -Expected 'finished' -Actual ([string]$entry['state'])
        Assert-Equal -Expected 'done' -Actual ([string]$entry['outcome'])
        Assert-Equal -Expected 1 -Actual ([int]$entry['attempts']) 'the phase is never started twice'
        Assert-Equal -Expected $Failed -Actual (@($entry['remarks']) -ccontains 'pwsh_upgrade_failed') 'only an upgrade the shim reports ok has no remark'
        Assert-False ([System.IO.File]::Exists($resultPath)) 'the result goes once its outcome is journaled'
    }

    It 'hands a pending PowerShell upgrade to the shim with exit 77 and reads its result in the next run: <Case>' -Skip:(-not $IsWindows) -ForEach @(
        @{ Case = 'ok'; Failed = $false }
        @{ Case = 'failed'; Failed = $true }
        @{ Case = 'installer_refused'; Failed = $true }
        @{ Case = 'none'; Failed = $true }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        # An access list only Administrators and SYSTEM can write needs an
        # elevated token this suite may not have; the path and hash checks run.
        Mock Test-HostUpdateWindowsAdminOnlyAcl -ModuleName Test.HostUpdate { $true }
        $savedProgramData = Save-YurunaTestEnvironment -Name @('ProgramData')
        try {
            $env:ProgramData = Join-Path $fixture.Home 'programdata'
            $id = Add-TestUpdate -Fixture $fixture -Scope full
            $copyDirectory = Join-Path $env:ProgramData "yuruna/host-update-$id-1"
            $null = New-Item -ItemType Directory -Path $copyDirectory -Force
            $copy = Join-Path $copyDirectory 'windows.hyper-v.ps1'
            [System.IO.File]::WriteAllText($copy, "# stand-in installer`n")
            $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($copy)))
            $requestPath = Join-Path $fixture.ControllerRoot 'pwsh-upgrade.request'
            $resultPath = Join-Path $fixture.ControllerRoot 'pwsh-upgrade.result'
            $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
            Add-StepPlan -Fake $first -Step 'install' -Spec @(@{ Extra = @{ pwshUpgradePending = $true; installerSha256 = $sha } })
            Assert-Equal -Expected 77 -Actual (Invoke-TestController -Fixture $fixture -Fake $first) 'the shim runs the upgrade PowerShell cannot run on itself'
            Assert-Equal -Expected 'preflight,stop_runner,update_source,install' -Actual (($first.Launches | ForEach-Object { $_.Step }) -join ',')
            Assert-Equal -Expected ([System.IO.Path]::GetFullPath($copy)) -Actual ([System.IO.Path]::GetFullPath(([System.IO.File]::ReadAllText($requestPath)).Trim())) 'the request names the copy phase 5 made'
            Assert-Equal -Expected 1 -Actual $first.ListenerStops.Count 'the listener is stopped before the upgrade'
            Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['listener']
            $entry = (Get-TestRow -RequestId $id)['update']['phases']['upgrade_pwsh']
            Assert-Equal -Expected 'started' -Actual ([string]$entry['state'])
            Assert-Equal -Expected 1 -Actual ([int]$entry['attempts'])
            # The shim's part: the result, then the request consumed.
            if ($Case -ne 'none') { [System.IO.File]::WriteAllText($resultPath, (@{ schemaVersion = 1; reason = $Case } | ConvertTo-Json -Compress)) }
            [System.IO.File]::Delete($requestPath)
            $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
            Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
            Assert-Equal -Expected 'enable,start_listener,start_runner' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',')
            Assert-False ([System.IO.File]::Exists($requestPath)) 'no second request is written'
            Assert-Equal -Expected 0 -Actual $second.ListenerStops.Count 'the continuation does not stop the listener again'
            $row = Get-TestRow -RequestId $id
            $entry = $row['update']['phases']['upgrade_pwsh']
            Assert-Equal -Expected 'done' -Actual ([string]$entry['outcome'])
            Assert-Equal -Expected 1 -Actual ([int]$entry['attempts']) 'the upgrade is never started twice'
            Assert-Equal -Expected $Failed -Actual (@($entry['remarks']) -ccontains 'pwsh_upgrade_failed')
            Assert-Equal -Expected ($(if ($Failed) { 'updated_with_remarks' } else { 'updated' })) -Actual $row['update']['verdict']
            Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['listener']
            Assert-False ([System.IO.File]::Exists($resultPath)) 'the result is read once'
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'yuruna') -Filter "host-update-$id-*" -Force).Count 'a terminal update leaves no installer copy'
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedProgramData
        }
    }

    It 'counts the full scope phases of this host in the public state' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $seen = [System.Collections.Generic.List[object]]::new()
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # A closure copies only the variables local to where it is made.
            $inner = $Fake.Service.OnPhaseWritten
            $path = Join-Path $fixture.Runtime 'host-update.state.json'
            $list = $seen
            $Fake.Service.OnPhaseWritten = {
                param($Change)
                & $inner $Change
                $state = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable } else { $null }
                if ($state -and $state['phase'] -and $Change.Phase -eq 'install' -and $Change.State -eq 'started' -and -not $Change.ChildOnly) { $list.Add($state['phase']) }
            }.GetNewClosure()
        }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual $run.Exit ($run.Fake.Log -join ' | ')
        Assert-Equal -Expected 1 -Actual $seen.Count
        $count = if ($IsWindows) { 9 } else { 8 }
        Assert-Equal -Expected 5 -Actual ([int]$seen[0]['index'])
        Assert-Equal -Expected $count -Actual ([int]$seen[0]['count'])
        Assert-Equal -Expected ($(if ($IsWindows) { 3600 } else { 2400 })) -Actual ([int]$seen[0]['bound'])
    }
}

Describe 'the drain' {
    BeforeEach {
        $script:Fixture = New-ControllerFixture
        $script:Id = Add-TestUpdate -Fixture $script:Fixture -DrainSeconds 60
        Enter-TestClaim -RequestId $script:Id -Fixture $script:Fixture
        $script:Fake = New-FakeService -Fixture $script:Fixture
        $script:Context = New-TestContext -Fixture $script:Fixture -Fake $script:Fake
        Mock Get-DiagnosticVmPreservation -ModuleName Test.HostUpdate { $null }
        Mock Get-YurunaOneShotLeaseState -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'Missing' } }
        Mock Test-HostUpdateParkedCycle -ModuleName Test.HostUpdate { $false }
    }

    It 'closes the gate as controller and journals the start once' {
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'AliveOwned' }
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'AliveOwned' } }
        $first = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateDrain -Context $Ctx -RequestId $Id }
        Assert-Equal -Expected 'drain_timeout' -Actual $first.Reason
        $started = [long](Get-TestRow -RequestId $script:Id)['update']['drain']['startedUnixMs']
        $gate = Get-TestGate -Fixture $script:Fixture
        Assert-Equal -Expected 'closed' -Actual $gate.State
        Assert-Equal -Expected 'controller' -Actual $gate.Owner['role']
        Assert-Equal -Expected $PID -Actual ([int]$gate.Owner['pid'])
        Assert-Equal -Expected $script:Id -Actual $gate.RequestId
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $script:Id)['gate']
        $script:Fake.Clock.Ms += 600000; $script:Fake.Clock.Tick += 600000
        $null = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateDrain -Context $Ctx -RequestId $Id }
        Assert-Equal -Expected $started -Actual ([long](Get-TestRow -RequestId $script:Id)['update']['drain']['startedUnixMs']) 'a second entry keeps the journaled start'
        Assert-Equal -Expected 'closed' -Actual (Get-TestGate -Fixture $script:Fixture).State 'closing again under its own id is a re-stamp'
    }

    It 'is done with no resident' {
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'Missing' }
        $result = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateDrain -Context $Ctx -RequestId $Id }
        Assert-Equal -Expected 'done' -Actual $result.Outcome
        $log = Get-Content -LiteralPath (Join-Path $script:Fixture.ControllerRoot "work/$($script:Id)/drain.log")
        Assert-Equal -Expected 1 -Actual @($log).Count
        Assert-Match -Pattern 'resident=Missing done$' -Actual $log
    }

    It 'needs two cycle-free checks after the close' {
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'AliveOwned' }
        $states = [System.Collections.Generic.Queue[string]]::new([string[]]@('AliveOwned', 'Missing', 'AliveOwned', 'DeadOrRecycled', 'Missing', 'AliveOwned'))
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = $states.Dequeue() } }.GetNewClosure()
        $result = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateDrain -Context $Ctx -RequestId $Id }
        Assert-Equal -Expected 'done' -Actual $result.Outcome
        Assert-Equal -Expected 1 -Actual $states.Count 'done at the second consecutive cycle-free check, not the first'
        Assert-Equal -Expected 5 -Actual @(Get-Content -LiteralPath (Join-Path $script:Fixture.ControllerRoot "work/$($script:Id)/drain.log")).Count 'one log line per check'
    }

    It 'counts a parked cycle only with the paused event and the pause flag: <Case>' -ForEach @(
        @{ Case = 'all three'; Flag = $true; Cycle = 'AliveOwned'; LastEvent = '{"event":"sequence_paused","pauseScope":"cycle"}'; Expected = $true }
        @{ Case = 'no pause flag'; Flag = $false; Cycle = 'AliveOwned'; LastEvent = '{"event":"sequence_paused","pauseScope":"cycle"}'; Expected = $false }
        @{ Case = 'another last event'; Flag = $true; Cycle = 'AliveOwned'; LastEvent = '{"event":"sequence_resumed","pauseScope":"cycle"}'; Expected = $false }
        @{ Case = 'a sequence-scope pause'; Flag = $true; Cycle = 'AliveOwned'; LastEvent = '{"event":"sequence_paused","pauseScope":"sequence"}'; Expected = $false }
        @{ Case = 'no live cycle'; Flag = $true; Cycle = 'Missing'; LastEvent = '{"event":"sequence_paused","pauseScope":"cycle"}'; Expected = $false }
    ) {
        $runtime = $script:Fixture.Runtime
        $logDir = Join-Path $script:Fixture.Home 'log'
        $null = New-Item -ItemType Directory -Path (Join-Path $logDir 'cycle-0007.incomplete') -Force
        if ($Flag) { Set-Content -LiteralPath (Join-Path $runtime 'control.cycle-pause') -Value '' }
        Set-Content -LiteralPath (Join-Path $runtime 'status.json') -Value '{"cycleFolderUrl":"log/cycle-0007.incomplete/"}'
        Set-Content -LiteralPath (Join-Path $logDir 'cycle-0007.incomplete/cycle.events.ndjson') -Value @('{"event":"cycle_started"}', $LastEvent)
        $cycleState = $Cycle
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = $cycleState } }.GetNewClosure()
        $launch = @{ environment = @{ YURUNA_LOG_DIR = $logDir } }
        $parked = InModuleScope Test.HostUpdate -Parameters @{ R = $runtime; C = $script:Fixture.Checkout; L = $launch } {
            param($R, $C, $L)
            & (Get-Command Test-HostUpdateParkedCycle -CommandType Function) -RuntimeDir $R -Checkout $C -LaunchRecord $L
        }
        Assert-Equal -Expected $Expected -Actual $parked
    }

    It 'is done after two parked checks' {
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'AliveOwned' }
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'AliveOwned' } }
        Mock Test-HostUpdateParkedCycle -ModuleName Test.HostUpdate { $true }
        $result = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $script:Context; Id = $script:Id } { param($Ctx, $Id) Invoke-HostUpdateDrain -Context $Ctx -RequestId $Id }
        Assert-Equal -Expected 'done' -Actual $result.Outcome
        Should -Invoke Test-HostUpdateParkedCycle -ModuleName Test.HostUpdate -Times 2 -Exactly
    }

    It 'refuses for <Case> and opens the gate' -ForEach @(
        @{ Case = 'a one-shot lease'; Lease = 'Held'; Hold = $false; Reason = 'one_shot_active'; Action = 'end_one_shot' }
        @{ Case = 'a diagnostic hold'; Lease = 'Missing'; Hold = $true; Reason = 'diagnostic_hold'; Action = 'release_diagnostic_hold' }
    ) {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture
        $lease = $Lease
        $hold = $Hold
        Mock Get-YurunaOneShotLeaseState -ModuleName Test.HostUpdate { [pscustomobject]@{ State = $lease } }.GetNewClosure()
        Mock Get-DiagnosticVmPreservation -ModuleName Test.HostUpdate { if ($hold) { @{ schemaVersion = 1; vmName = 'vm1' } } else { $null } }.GetNewClosure()
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'AliveOwned' }
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 'refused' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected $Reason -Actual $run.Row['update']['reason']
        Assert-Equal -Expected $Action -Actual $run.Row['update']['operatorAction']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['gate']
        Assert-Equal -Expected 'preflight' -Actual (($run.Fake.Launches | ForEach-Object { $_.Step }) -join ',') 'nothing is stopped'
    }

    It 'times out from the journaled start after a restart' {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture -DrainSeconds 60
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'AliveOwned' } }
        $counter = @{ Checks = 0; KillAt = 6 }
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate {
            $counter.Checks++
            if ($counter.KillAt -and $counter.Checks -eq $counter.KillAt) { $counter.KillAt = 0; throw 'simulated controller kill' }
            'AliveOwned'
        }.GetNewClosure()
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first) 'the first controller dies mid-drain'
        $checksBefore = $counter.Checks
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $second.Clock.Ms = $first.Clock.Ms; $second.Clock.Tick = $first.Clock.Tick
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'drain_timeout' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'retry_or_drain_now' -Actual $row['update']['operatorAction']
        $secondChecks = $counter.Checks - $checksBefore
        Assert-True ($secondChecks -le 8) "the second controller waits only what is left of 60 s ($secondChecks checks)"
        Assert-True ((($second.Clock.Ms - $second.StartMs) + ($first.Clock.Ms - $first.StartMs)) -lt 120000) 'the bound is not restarted from zero'
        Assert-Equal -Expected 2 -Actual ([int]$row['update']['phases']['drain']['attempts'])
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'goes on at once with now' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Channel local -Drain now
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'AliveOwned' }
        Mock Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'AliveOwned' } }
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'done' -Actual $run.Row['update']['phases']['drain']['outcome']
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.ControllerRoot "work/$id/drain.log")) 'no drain check is made'
        Should -Invoke Read-YurunaRunnerCycleRecord -ModuleName Test.HostUpdate -Times 0 -Exactly
        Assert-Equal -Expected 'resident-alive' -Actual $run.Row['update']['runnerPlan']['basis']
    }
}

Describe 'the runner plan' {
    It 'records once: <Case>' -ForEach @(
        @{ Case = 'inherited runner obligation'; Armed = $true; Resident = 'Missing'; Found = $false; Clean = $false; Start = $true; Basis = 'inherited' }
        @{ Case = 'a resident is running'; Armed = $false; Resident = 'AliveOwned'; Found = $true; Clean = $true; Start = $true; Basis = 'resident-alive' }
        @{ Case = 'no resident, unclean exit'; Armed = $false; Resident = 'DeadOrRecycled'; Found = $true; Clean = $false; Start = $true; Basis = 'unclean-exit' }
        @{ Case = 'no resident, clean exit'; Armed = $false; Resident = 'Missing'; Found = $true; Clean = $true; Start = $false; Basis = 'clean-exit' }
        @{ Case = 'no launch record'; Armed = $false; Resident = 'Missing'; Found = $false; Clean = $false; Start = $false; Basis = 'no-launch-record' }
    ) {
        $resident = $Resident
        $record = [pscustomobject]@{ Found = $Found; Valid = $Found; Record = if ($Found) { @{ cleanExit = $Clean } } else { $null } }
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { $resident }.GetNewClosure()
        Mock Read-YurunaRunnerLaunchRecord -ModuleName Test.HostUpdate { $record }.GetNewClosure()
        $row = @{ requestId = 'x'; runtimeDir = '/srv/runtime'; obligations = @(if ($Armed) { @{ id = 'runner'; status = 'armed' } }) }
        $context = @{ Checkout = '/srv/checkout'; PrivateRoot = '/srv/private' }
        $plan = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $context; Row = $row } { param($Ctx, $Row) Get-HostUpdateRunnerPlan -Context $Ctx -Row $Row }
        Assert-Equal -Expected $Start -Actual $plan.start
        Assert-Equal -Expected $Basis -Actual $plan.basis
    }

    It 'keeps the first record on a second run' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $first.CrashAt = @{ Phase = 'stop_runner'; State = 'started' }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        Assert-Equal -Expected 'unclean-exit' -Actual (Get-TestRow -RequestId $id)['update']['runnerPlan']['basis']
        Set-TestLaunchRecord -CleanExit $true
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'unclean-exit' -Actual $row['update']['runnerPlan']['basis'] 'the start itself can change the launch record; the plan does not follow it'
        Assert-Equal -Expected 'updated' -Actual $row['update']['verdict']
    }
}

Describe 'recovering, release and takeover' {
    It 'enters recovering on a failed start and releases the lifetime lock during the backoff' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $seen = @{ Lock = [System.Collections.Generic.List[string]]::new(); Released = $false; Recovering = $null }
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # Copied into this scope so the hook closure below captures them.
            $id = $id; $seen = $seen
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'config_gate_failed' })
            $Fake.SleepHook = {
                param($F)
                $null = $F
                $row = Get-HostUpdateRequest -RequestId $id
                if ([string]$row['state'] -ne 'recovery-pending' -or $seen.Released) { return }
                if (-not $seen.Recovering) { $seen.Recovering = $row['update']['recovering'] }
                $seen.Lock.Add([string](Get-YurunaSingleFlightLockState -Path (Get-YurunaHostOperationLockPath)).State)
                if ($seen.Lock.Count -ge 3) { $seen.Released = $true; $null = Request-HostUpdateRelease -RequestId $id -Actor 'tester' -Confirm:$false }
            }.GetNewClosure()
        }
        Assert-Equal -Expected 'free,free,free' -Actual ($seen.Lock -join ',') 'host-operation.lock is not held during the backoff'
        Assert-Equal -Expected 'act_at_host' -Actual $seen.Recovering['operatorAction'] 'a refused config gate asks for the host'
        Assert-True ([long]$seen.Recovering['nextUnixMs'] - $run.Fake.StartMs -ge 300000) 'the first attempt is 5 minutes out'
        Assert-Equal -Expected 'released' -Actual $run.Row['update']['verdict']
    }

    It 'retries the start on the backoff with the snapshot step script and ends restored' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            $failed = @{ Outcome = 'failed'; Reason = 'runner_exited' }
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @($failed, $failed.Clone(), $failed.Clone(), $failed.Clone(), @{})
        }
        Assert-Equal -Expected 'updated_with_remarks' -Actual $run.Row['update']['verdict'] 'every phase before the start had passed'
        $steps = @($run.Fake.Launches | ForEach-Object { $_.Step })
        $recover = @(1..4 | ForEach-Object { 'update_source', 'start_runner' })
        Assert-Equal -Expected ((@('preflight', 'stop_runner', 'update_source', 'start_listener', 'start_runner') + $recover) -join ',') -Actual ($steps -join ',') 'recovering has no start limit'
        $recoverSources = @($run.Fake.Launches | Where-Object { $_.Step -eq 'update_source' } | Select-Object -Skip 1)
        foreach ($launch in $recoverSources) { Assert-Match -Pattern ([regex]::Escape($fixture.ControllerRoot) + '/versions/[0-9a-f]{16}/test/lab/Invoke-HostUpdateStep\.ps1$') -Actual $launch.ScriptPath }
        Assert-Equal -Expected 4 -Actual ([int]$run.Row['update']['phases']['recover']['attempts'])
        $minutes = ($run.Fake.Clock.Ms - $run.Fake.StartMs) / 60000
        Assert-True ($minutes -ge 45 -and $minutes -lt 47) "four attempts after 5, 10, 15 and 15 minutes ($minutes)"
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'honors a release mark during the backoff' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # Copied into this scope so the hook closure below captures them.
            $id = $id
            Add-StepPlan -Fake $Fake -Step 'start_listener' -Spec @(@{ Outcome = 'failed'; Reason = 'step_interrupted' })
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_start_timeout' })
            $Fake.SleepHook = {
                param($F)
                $null = $F
                $row = Get-HostUpdateRequest -RequestId $id
                if ([string]$row['state'] -eq 'recovery-pending' -and -not $row['update']['release']) { $null = Request-HostUpdateRelease -RequestId $id -Actor 'operator1' -Confirm:$false }
            }.GetNewClosure()
        }
        Assert-Equal -Expected 'released' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'completed' -Actual $run.Row['state']
        $obligations = @{}
        foreach ($obligation in @($run.Row['obligations'])) { $obligations[[string]$obligation['id']] = $obligation }
        Assert-Equal -Expected 'disposed' -Actual $obligations['runner']['status']
        Assert-Equal -Expected 'operator1' -Actual $obligations['runner']['disposedBy']
        Assert-Equal -Expected 'listener:start_listener' -Actual (($run.Row['update']['debt'] | ForEach-Object { "$($_['obligation']):$($_['action'])" }) -join ',')
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        Assert-True (($run.Fake.Clock.Ms - $run.Fake.StartMs) -lt 300000) 'released before the first attempt'
    }

    It 'stops recovering when superseded' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $state = @{ NewId = $null }
        $fake = New-FakeService -Fixture $fixture
        Add-StepPlan -Fake $fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' })
        $runtime = $fixture.Runtime
        $fake.SleepHook = {
            param($F)
            $null = $F
            if ($state.NewId) { return }
            $row = Get-HostUpdateRequest -RequestId $id
            if ([string]$row['state'] -ne 'recovery-pending') { return }
            $state.NewId = New-YurunaHostOperationRequestId
            $admission = Request-HostUpdateAdmission -RequestId $state.NewId -Channel listener -RuntimeDir $runtime -HostType 'host.ubuntu.kvm' -Confirm:$false
            $state.Decision = $admission.Decision
        }.GetNewClosure()
        $fake.Service.ShouldStop = {
            param($Context) $null = $Context
            if (-not $state.NewId) { return $false }
            $row = Get-HostUpdateRequest -RequestId $state.NewId
            [string]$row['state'] -in @('completed', 'refused')
        }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected 'taken-over' -Actual $state.Decision
        $old = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'superseded' -Actual $old['update']['verdict']
        Assert-Equal -Expected $state.NewId -Actual $old['update']['supersededBy']
        $new = Get-TestRow -RequestId $state.NewId
        Assert-Equal -Expected $id -Actual $new['update']['inheritedFrom']
        Assert-Equal -Expected 'updated' -Actual $new['update']['verdict'] 'the new update starts the inherited runner'
        Assert-Equal -Expected 'unclean-exit' -Actual $new['update']['runnerPlan']['basis'] 'the plan moves with the takeover'
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $state.NewId)['runner']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'restores instead of refusing when a takeover inherited armed obligations' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $state = @{ NewId = $null }
        $fake = New-FakeService -Fixture $fixture
        Add-StepPlan -Fake $fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' })
        Add-StepPlan -Fake $fake -Step 'preflight' -Spec @(@{}, @{ Outcome = 'failed'; Reason = 'one_shot_active'; Action = 'end_one_shot' })
        $runtime = $fixture.Runtime
        $fake.SleepHook = {
            param($F)
            $null = $F
            if ($state.NewId) { return }
            $row = Get-HostUpdateRequest -RequestId $id
            if ([string]$row['state'] -ne 'recovery-pending') { return }
            $state.NewId = New-YurunaHostOperationRequestId
            $null = Request-HostUpdateAdmission -RequestId $state.NewId -Channel listener -RuntimeDir $runtime -HostType 'host.ubuntu.kvm' -Confirm:$false
        }.GetNewClosure()
        $fake.Service.ShouldStop = {
            param($Context) $null = $Context
            if (-not $state.NewId) { return $false }
            [string](Get-HostUpdateRequest -RequestId $state.NewId)['state'] -in @('completed', 'refused')
        }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        $new = Get-TestRow -RequestId $state.NewId
        Assert-Equal -Expected 'failed_restored' -Actual $new['update']['verdict'] 'a touched host is restored, not left stopped'
        Assert-Equal -Expected 'one_shot_active' -Actual $new['update']['reason']
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $state.NewId)['runner']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'claims a takeover under a protocol mismatch straight into recovering and never blocks it' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $state = @{ NewId = $null; Takeover = -1; Decision = $null }
        $fake = New-FakeService -Fixture $fixture
        Add-StepPlan -Fake $fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' })
        $checkout = $fixture.Checkout; $controllerRoot = $fixture.ControllerRoot; $runtime = $fixture.Runtime
        $fake.SleepHook = {
            param($F)
            if ($state.NewId) { return }
            $row = Get-HostUpdateRequest -RequestId $id
            if ([string]$row['state'] -ne 'recovery-pending') { return }
            # The checkout now carries a protocol number whose snapshot is rejected.
            [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '2')
            $rejected = (Get-HostUpdateSnapshotManifest -SourceRoot $checkout).Hash16
            [System.IO.File]::WriteAllText((Join-Path $controllerRoot 'rejected'), "$rejected`n")
            $state.NewId = New-YurunaHostOperationRequestId
            $state.Takeover = $F.Launches.Count
            $state.Decision = (Request-HostUpdateAdmission -RequestId $state.NewId -Channel listener -RuntimeDir $runtime -HostType 'host.ubuntu.kvm' -Confirm:$false).Decision
        }.GetNewClosure()
        $inner = $fake.Service.StartStep
        $fake.Service.StartStep = {
            param($Launch)
            # The recovering pull brings a commit that fixes the protocol number.
            if ($Launch.Step -eq 'update_source' -and $Launch.RequestId -eq $state.NewId) { [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '1') }
            & $inner $Launch
        }.GetNewClosure()
        $fake.Service.ShouldStop = {
            param($Context) $null = $Context
            if (-not $state.NewId) { return $false }
            [string](Get-HostUpdateRequest -RequestId $state.NewId)['state'] -in @('completed', 'refused')
        }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected 'taken-over' -Actual $state.Decision
        $new = Get-TestRow -RequestId $state.NewId
        Assert-Null $new['update']['claimBlocked'] 'a takeover is never left queued behind a protocol mismatch'
        Assert-Equal -Expected 'completed' -Actual $new['state']
        Assert-Equal -Expected 'updated_with_remarks' -Actual $new['update']['verdict'] 'the recovering update started the inherited runner'
        $after = @($fake.Launches | Select-Object -Skip $state.Takeover)
        Assert-Equal -Expected 'update_source,start_listener,start_runner' -Actual (($after | ForEach-Object { $_.Step }) -join ',') 'no phase of the walk runs from the mismatched checkout'
        Assert-Match -Pattern ([regex]::Escape($fixture.ControllerRoot) + '/versions/[0-9a-f]{16}/test/lab/Invoke-HostUpdateStep\.ps1$') -Actual $after[0].ScriptPath
        Assert-True ($fake.Log | Where-Object { $_ -match "event=recovering .*reason=protocol_mismatch .*requestId=$($state.NewId)" -or $_ -match "event=recovering .*requestId=$($state.NewId).*reason=protocol_mismatch" }) 'the takeover recovers for the protocol mismatch'
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $state.NewId)['runner']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'keeps the commit the host had before when a recover attempt pulls again' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            Add-StepPlan -Fake $Fake -Step 'update_source' -Spec @(@{ Commit = @{ before = 'aaaaaaa'; after = 'bbbbbbb' } }, @{ Commit = @{ before = 'bbbbbbb'; after = 'bbbbbbb' } })
            Add-StepPlan -Fake $Fake -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' }, @{})
        }
        Assert-Equal -Expected 'updated_with_remarks' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 'aaaaaaa' -Actual $run.Row['update']['commit']['before'] 'the recover pull does not rewrite where the host started'
        Assert-True ([bool]$run.Row['update']['mutated'])
    }

    It 'starts the listener and ends updated_not_started when a protocol mismatch recovers with no runner planned' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $true
        $id = Add-TestUpdate -Fixture $fixture
        $checkout = $fixture.Checkout
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $fake -Step 'update_source' -Spec @(@{ Protocol = 2 }, @{ Protocol = 1 })
        $inner = $fake.Service.StartStep
        $sources = @{ Count = 0 }
        $fake.Service.StartStep = {
            param($Launch)
            if ($Launch.Step -eq 'update_source') {
                $sources.Count++
                if ($sources.Count -eq 1) {
                    [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '2')
                    Set-Content -LiteralPath (Join-Path $checkout 'test/modules/B.psm1') -Value 'function Get-B {'
                } else {
                    [System.IO.File]::WriteAllText((Join-Path $checkout 'test/host-update.protocol-version'), '1')
                    Set-Content -LiteralPath (Join-Path $checkout 'test/modules/B.psm1') -Value 'function Get-B { 2 }'
                }
            }
            & $inner $Launch
        }.GetNewClosure()
        $null = Invoke-TestController -Fixture $fixture -Fake $fake
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'updated_not_started' -Actual $row['update']['verdict'] 'no runner was started'
        Assert-Equal -Expected 'start_runner' -Actual $row['update']['operatorAction']
        Assert-Equal -Expected 'finished' -Actual $row['update']['phases']['start_listener']['state'] 'phase 8 runs on the way out of recovering'
        Assert-Equal -Expected 'preflight,stop_runner,update_source,update_source,start_listener' -Actual (($fake.Launches | ForEach-Object { $_.Step }) -join ',') 'no runner start step runs'
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
    }

    It 'never writes a verdict while gate is armed' {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture
        Mock Open-HostUpdateGate -ModuleName Test.HostUpdate { 'failed' }
        Mock Get-HostUpdateResidentState -ModuleName Test.HostUpdate { 'Missing' }
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id
        Assert-Equal -Expected 1 -Actual $run.Exit 'the operation stops in place'
        Assert-Equal -Expected 'running' -Actual $run.Row['state']
        Assert-Null $run.Row['update']['verdict']
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['gate']
        Assert-True ($run.Fake.Log | Where-Object { $_ -match 'event=gate-not-opened' }) 'the reason is logged'
    }
}

Describe 'continuation after an interruption' {
    It 'reaches the same end state when interrupted at <Phase> <State>' -ForEach @(
        @{ Phase = 'preflight'; State = 'started'; Path = 'updated' }
        @{ Phase = 'preflight'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'drain'; State = 'started'; Path = 'updated' }
        @{ Phase = 'drain'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'stop_runner'; State = 'started'; Path = 'updated' }
        @{ Phase = 'stop_runner'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'update_source'; State = 'started'; Path = 'updated' }
        @{ Phase = 'update_source'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'start_listener'; State = 'started'; Path = 'updated' }
        @{ Phase = 'start_listener'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'start_runner'; State = 'started'; Path = 'updated' }
        @{ Phase = 'start_runner'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'restore'; State = 'started'; Path = 'restored' }
        @{ Phase = 'restore'; State = 'finished'; Path = 'restored' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        if ($Path -eq 'restored') { Add-StepPlan -Fake $first -Step 'update_source' -Spec @(@{ Outcome = 'failed'; Reason = 'pull_failed' }) }
        $first.CrashAt = @{ Phase = $Phase; State = $State }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first) 'the first controller is interrupted'
        Assert-True $first.Crashed "fixture sanity: the run reached $Phase $State"
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected 'running' -Actual $public['state'] 'the public state shows the interrupted operation'
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        $row = Get-TestRow -RequestId $id
        $expected = if ($Path -eq 'restored') { @{ Verdict = 'failed_restored'; Reason = 'pull_failed' } } else { @{ Verdict = 'updated'; Reason = $null } }
        Assert-Equal -Expected $expected.Verdict -Actual $row['update']['verdict']
        Assert-Equal -Expected ([string]$expected.Reason) -Actual ([string]$row['update']['reason'])
        Assert-Equal -Expected 'completed' -Actual $row['state']
        $obligations = Get-TestObligation -RequestId $id
        Assert-Equal -Expected 'discharged' -Actual $obligations['gate']
        Assert-Equal -Expected 'discharged' -Actual $obligations['runner']
        Assert-Equal -Expected 'unclean-exit' -Actual $row['update']['runnerPlan']['basis']
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected 'terminal' -Actual $public['state']
        Assert-Equal -Expected $expected.Verdict -Actual $public['verdict']
        foreach ($name in @($row['update']['phases'].Keys)) {
            Assert-True ([int]$row['update']['phases'][$name]['attempts'] -le 2) "$name is started at most once more after the interruption"
            Assert-Equal -Expected 'finished' -Actual $row['update']['phases'][$name]['state'] "$name ends finished"
        }
        # The next controller runs only what was not finished: the phase that
        # was started again, then the rest.
        $order = @('preflight', 'drain', 'stop_runner', 'update_source', 'start_listener', 'start_runner')
        $steps = @('preflight', 'stop_runner', 'update_source', 'start_listener', 'start_runner')
        $expectedSteps = if ($Path -eq 'restored') {
            if ($State -eq 'started') { @('start_runner') } else { @() }
        } else {
            $at = [array]::IndexOf($order, $Phase)
            @($steps | Where-Object { $i = [array]::IndexOf($order, $_); $i -gt $at -or ($i -eq $at -and $State -eq 'started') })
        }
        Assert-Equal -Expected ($expectedSteps -join ',') -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',') 'finished phases are not run again'
    }

    It 'reaches the same end state in the full scope when interrupted at <Phase> <State> (<Path>)' -Skip:(-not $IsLinux) -ForEach @(
        @{ Phase = 'install'; State = 'started'; Path = 'updated' }
        @{ Phase = 'install'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'enable'; State = 'started'; Path = 'updated' }
        @{ Phase = 'enable'; State = 'finished'; Path = 'updated' }
        @{ Phase = 'install'; State = 'finished'; Path = 'restored' }
        @{ Phase = 'install'; State = 'finished'; Path = 'pwsh-changed' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        if ($Path -eq 'restored') { Add-StepPlan -Fake $first -Step 'install' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_present' }) }
        if ($Path -eq 'pwsh-changed') { Add-StepPlan -Fake $first -Step 'install' -Spec @(@{ Extra = @{ pwshChanged = $true } }) }
        $first.CrashAt = @{ Phase = $Phase; State = $State }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first) 'the first controller is interrupted'
        Assert-True $first.Crashed "fixture sanity: the run reached $Phase $State"
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        $row = Get-TestRow -RequestId $id
        $expected = if ($Path -eq 'restored') { @{ Verdict = 'failed_restored'; Reason = 'runner_present' } } else { @{ Verdict = 'updated'; Reason = $null } }
        Assert-Equal -Expected $expected.Verdict -Actual $row['update']['verdict']
        Assert-Equal -Expected ([string]$expected.Reason) -Actual ([string]$row['update']['reason'])
        Assert-Equal -Expected 'completed' -Actual $row['state']
        $obligations = Get-TestObligation -RequestId $id
        foreach ($name in @('gate', 'runner', 'elevation')) { Assert-Equal -Expected 'discharged' -Actual $obligations[$name] "$name is discharged" }
        Assert-True ($obligations['listener'] -ne 'armed') 'the listener is not left owed'
        Assert-Equal -Expected 0 -Actual $second.ListenerStops.Count 'a continuation does not stop the listener'
        Assert-Equal -Expected 0 -Actual @((Get-TestPublicState -Fixture $fixture)['debt']).Count
        Assert-Equal -Expected 'open' -Actual (Get-TestGate -Fixture $fixture).State
        foreach ($name in @($row['update']['phases'].Keys)) {
            Assert-True ([int]$row['update']['phases'][$name]['attempts'] -le 2) "$name is started at most once more after the interruption"
            Assert-Equal -Expected 'finished' -Actual $row['update']['phases'][$name]['state'] "$name ends finished"
        }
        $order = @('preflight', 'drain', 'stop_runner', 'update_source', 'install', 'enable', 'start_listener', 'start_runner')
        $steps = @('preflight', 'stop_runner', 'update_source', 'install', 'enable', 'start_listener', 'start_runner')
        $expectedSteps = if ($Path -eq 'restored') { @('start_runner') } else {
            $at = [array]::IndexOf($order, $Phase)
            @($steps | Where-Object { $i = [array]::IndexOf($order, $_); $i -gt $at -or ($i -eq $at -and $State -eq 'started') })
        }
        Assert-Equal -Expected ($expectedSteps -join ',') -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',') 'finished phases are not run again'
    }

    It 'continues a recovering update after a restart' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $first -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' })
        $first.SleepHook = {
            param($F)
            $null = $F
            if ([string](Get-HostUpdateRequest -RequestId $id)['state'] -eq 'recovery-pending') { throw 'simulated controller kill' }
        }.GetNewClosure()
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        Assert-Equal -Expected 'recovery-pending' -Actual (Get-TestRow -RequestId $id)['state']
        Assert-Equal -Expected 'recovering' -Actual (Get-TestPublicState -Fixture $fixture)['state']
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $second.Clock.Ms = $first.Clock.Ms; $second.Clock.Tick = $first.Clock.Tick
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'updated_with_remarks' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'update_source,start_runner' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',')
    }

    It 'starts the listener once in a new boot before it continues a recovering update' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $first -Step 'start_runner' -Spec @(@{ Outcome = 'failed'; Reason = 'runner_exited' })
        $first.SleepHook = {
            param($F)
            $null = $F
            if ([string](Get-HostUpdateRequest -RequestId $id)['state'] -eq 'recovery-pending') { throw 'simulated host restart' }
        }.GetNewClosure()
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        $next = [long](Get-TestRow -RequestId $id)['update']['recovering']['nextUnixMs']
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        # A new boot a minute later: the monotonic clock starts again near zero.
        $second.Clock.Ms = $first.Clock.Ms + 60000; $second.Clock.Tick = 1000
        $times = [System.Collections.Generic.List[long]]::new()
        $inner = $second.Service.StartStep
        $clock = $second.Clock
        $second.Service.StartStep = { param($Launch) $times.Add($clock.Ms); & $inner $Launch }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        Assert-Equal -Expected 'start_listener,update_source,start_runner' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',')
        Assert-True ($times[0] -lt $next) 'the listener starts before the backoff ends, so the page can show the recovering update'
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['listener']
        Assert-Equal -Expected 'updated_with_remarks' -Actual (Get-TestRow -RequestId $id)['update']['verdict']
    }

    It 'starts the listener again when the install stopped it after the start a new boot made, discharging it only if that start <Outcome>' -Skip:(-not $IsLinux) -ForEach @(
        @{ Outcome = 'done'; Listener = 'discharged' }
        @{ Outcome = 'failed'; Listener = 'armed' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $first.CrashAt = @{ Phase = 'install'; State = 'started' }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        # A new boot: the listener is started first, then the install changes
        # PowerShell and stops it again.
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $second.Clock.Ms = $first.Clock.Ms + 60000; $second.Clock.Tick = 1000
        Add-StepPlan -Fake $second -Step 'install' -Spec @(@{ Extra = @{ pwshChanged = $true } })
        Assert-Equal -Expected 75 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        Assert-Equal -Expected 'start_listener,install' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',') 'fixture sanity: the boot block started the listener'
        Assert-Equal -Expected 1 -Actual $second.ListenerStops.Count
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['listener']
        $third = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $third.Clock.Ms = $second.Clock.Ms; $third.Clock.Tick = $second.Clock.Tick
        Add-StepPlan -Fake $third -Step 'start_listener' -Spec @(@{ Outcome = $Outcome; Reason = $(if ($Outcome -eq 'failed') { 'runner_exited' } else { $null }) })
        $atStart = [System.Collections.Generic.List[string]]::new()
        $inner = $third.Service.StartStep
        $third.Service.StartStep = {
            param($Launch)
            if ($Launch.Step -eq 'start_listener') {
                $row = Get-HostUpdateRequest -RequestId $id
                $atStart.Add([string](@($row['obligations'] | Where-Object { $_ -and [string]$_['id'] -eq 'listener' })[0]['status']))
            }
            & $inner $Launch
        }.GetNewClosure()
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $third)
        Assert-Equal -Expected 'enable,start_listener,start_runner' -Actual (($third.Launches | ForEach-Object { $_.Step }) -join ',') 'the listener the install stopped is started again'
        Assert-Equal -Expected 'armed' -Actual ($atStart -join ',') 'the listener is discharged only after its start'
        Assert-Equal -Expected 2 -Actual ([int](Get-TestRow -RequestId $id)['update']['phases']['start_listener']['attempts'])
        Assert-Equal -Expected $Listener -Actual (Get-TestObligation -RequestId $id)['listener']
        Assert-Equal -Expected 0 -Actual $third.ListenerStops.Count
    }

    It 'starts the listener once in a new boot before it continues a restore' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $first -Step 'update_source' -Spec @(@{ Outcome = 'failed'; Reason = 'pull_failed' })
        $first.CrashAt = @{ Phase = 'restore'; State = 'started' }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        Assert-Null (Get-TestObligation -RequestId $id)['listener'] 'fixture sanity: the listener was never armed'
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $second.Clock.Ms = $first.Clock.Ms + 60000; $second.Clock.Tick = 1000
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        Assert-Equal -Expected 'start_listener,start_runner' -Actual (($second.Launches | ForEach-Object { $_.Step }) -join ',')
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'failed_restored' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['listener']
    }

    It 'reads a result the interrupted controller never read instead of running the step again' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $first = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $first -Step 'update_source' -Spec @(@{ Commit = @{ before = 'aaaaaaa'; after = 'bbbbbbb' }; HangMs = 5000 })
        $first.SleepHook = {
            param($F)
            if (@($F.Launches | Where-Object { $_.Step -eq 'update_source' }).Count -gt 0) { throw 'simulated controller kill' }
        }
        Assert-Equal -Expected 1 -Actual (Invoke-TestController -Fixture $fixture -Fake $first)
        Assert-Equal -Expected 'started' -Actual (Get-TestRow -RequestId $id)['update']['phases']['update_source']['state'] 'fixture sanity: the result was never read'
        $second = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-StepPlan -Fake $second -Step 'update_source' -Spec @(@{ Commit = @{ before = 'bbbbbbb'; after = 'bbbbbbb' } })
        Assert-Equal -Expected 0 -Actual (Invoke-TestController -Fixture $fixture -Fake $second)
        Assert-False (($second.Launches | ForEach-Object { $_.Step }) -contains 'update_source') 'the pull that already ran is not run again'
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'updated' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'aaaaaaa' -Actual $row['update']['commit']['before']
        Assert-True ([bool]$row['update']['mutated']) 'the host was changed by the pull'
    }

    It 're-stamps only a closed or recovery-pending gate under its own or inherited id and never a handoff: <Case>' -ForEach @(
        @{ Case = 'closed under its own id'; GateState = 'closed'; Own = 'self'; Expected = 'restamped' }
        @{ Case = 'recovery-pending under the inherited id'; GateState = 'recovery-pending'; Own = 'inherited'; Expected = 'restamped' }
        @{ Case = 'closed under another id'; GateState = 'closed'; Own = 'other'; Expected = 'not-ours' }
        @{ Case = 'open'; GateState = 'released'; Own = 'self'; Expected = 'open' }
    ) {
        $fixture = New-ControllerFixture
        $id = New-YurunaHostOperationRequestId
        $inherited = New-YurunaHostOperationRequestId
        $gateId = switch ($Own) { 'self' { $id } 'inherited' { $inherited } default { New-YurunaHostOperationRequestId } }
        $null = Set-YurunaRunnerGate -State $GateState -RequestId $gateId -Attempt 1 -RuntimeDir $fixture.Runtime -ExpectedGeneration '' -OwnerPid 1 -PrivateRoot $fixture.PrivateRoot -Confirm:$false
        $before = Get-TestGate -Fixture $fixture
        $row = @{ requestId = $id; runtimeDir = $fixture.Runtime; update = @{ inheritedGateRequestId = $inherited } }
        $context = New-TestContext -Fixture $fixture -Fake (New-FakeService -Fixture $fixture)
        $answer = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $context; Row = $row } { param($Ctx, $Row) Update-HostUpdateGateOwner -Context $Ctx -Row $Row -Confirm:$false }
        Assert-Equal -Expected $Expected -Actual $answer
        $after = Get-TestGate -Fixture $fixture
        if ($Expected -eq 'restamped') {
            Assert-Equal -Expected 'controller' -Actual $after.Owner['role']
            Assert-Equal -Expected $PID -Actual ([int]$after.Owner['pid'])
            Assert-Equal -Expected $before.State -Actual $after.State 'the state is kept'
            Assert-Equal -Expected $id -Actual $after.RequestId 'the gate moves to the update that continues it'
        } else {
            Assert-Equal -Expected $before.Generation -Actual $after.Generation 'nothing is written'
        }
    }

    It 'leaves a handoff gate to its acknowledgment' {
        $fixture = New-ControllerFixture
        $context = New-TestContext -Fixture $fixture -Fake (New-FakeService -Fixture $fixture)
        $id = New-YurunaHostOperationRequestId
        Mock Get-HostUpdateGate -ModuleName Test.HostUpdate { [pscustomobject]@{ State = 'handoff'; RequestId = $id; Generation = 'g' } }.GetNewClosure()
        Mock Set-YurunaRunnerGate -ModuleName Test.HostUpdate { throw 'a handoff gate must not be written' }
        $row = @{ requestId = $id; runtimeDir = $fixture.Runtime; update = @{} }
        $answer = InModuleScope Test.HostUpdate -Parameters @{ Ctx = $context; Row = $row } { param($Ctx, $Row) Update-HostUpdateGateOwner -Context $Ctx -Row $Row -Confirm:$false }
        Assert-Equal -Expected 'handoff' -Actual $answer
        Should -Invoke Set-YurunaRunnerGate -ModuleName Test.HostUpdate -Times 0 -Exactly
    }
}

Describe 'the public state' {
    It 'projects the row to the public state with tokens only' {
        $row = @{
            requestId = '0a1b2c3d-0000-4000-8000-00000000000a'; kind = 'host-update'; channel = 'listener'; state = 'running'; runtimeDir = '/home/someone/runtime'
            createdUtc = '2026-11-19T10:00:00.0000000Z'; reasonCodes = @(); terminalUtc = $null
            update = @{
                request = @{ scope = 'restart'; drain = 'after-cycle'; drainSeconds = 7200 }; claimedUtc = '2026-11-19T10:00:01.0000000Z'
                phase = 'drain'; remarks = @('ring_held', '/etc/passwd', 'some prose here'); debt = @(@{ obligation = 'listener'; action = 'start_listener' }, @{ obligation = '/x'; action = 'rm -rf' })
                verdict = 'Updated! see /tmp/log'; operatorAction = 'sudo reboot'; reason = 'token=secret'; mutated = $true
                commit = @{ before = 'ABCDEF1'; after = '0123456789abcdef0123456789abcdef01234567'; resident = '/srv' }
                runnerConsole = 'xterm -e sh'; supersededBy = '../../etc'; phases = @{ drain = @{ result = @{ detail = 'output text' } } }
            }
        }
        $state = ConvertTo-HostUpdatePublicState -Row $row -Now ([DateTimeOffset]::Parse('2026-11-19T10:05:00Z')) -FirstCycle 'maybe'
        $expectedKeys = 'schemaVersion,requestId,scope,channel,state,phase,startedUtc,heartbeatUtc,mutated,listenerExpectedBackUtc,remarks,debt,verdict,operatorAction,reason,commit,runnerConsole,supersededBy,firstCycle,terminalUtc'
        Assert-Equal -Expected $expectedKeys -Actual ($state.Keys -join ',')
        Assert-Equal -Expected 'index,count,name,bound' -Actual ($state.phase.Keys -join ',')
        Assert-Equal -Expected 2 -Actual $state.phase.index
        Assert-Equal -Expected 6 -Actual $state.phase.count
        Assert-Equal -Expected 7200 -Actual $state.phase.bound
        Assert-Equal -Expected 'ring_held' -Actual ($state.remarks -join ',')
        Assert-Equal -Expected 1 -Actual @($state.debt).Count
        foreach ($key in @('verdict', 'operatorAction', 'reason', 'runnerConsole', 'supersededBy', 'firstCycle', 'terminalUtc', 'listenerExpectedBackUtc')) { Assert-Null $state[$key] "$key is not a token" }
        Assert-Null $state.commit.before 'uppercase is not a commit token'
        Assert-Null $state.commit.resident
        Assert-Equal -Expected '0123456789abcdef0123456789abcdef01234567' -Actual $state.commit.after
        $json = $state | ConvertTo-Json -Depth 6 -Compress
        foreach ($forbidden in @('/', 'passwd', 'secret', 'prose', 'output text', 'someone', 'xterm', 'sudo')) {
            Assert-False ($json.Contains($forbidden)) "no value carries '$forbidden'"
        }
    }

    It 'keeps the heartbeat advancing while a stand-in step hangs past 30 s' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $true
        $id = Add-TestUpdate -Fixture $fixture
        $beats = @{ Controller = [System.Collections.Generic.List[string]]::new(); Update = [System.Collections.Generic.List[string]]::new() }
        $runtime = $fixture.Runtime
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # Copied into this scope so the hook closure below captures them.
            $beats = $beats; $runtime = $runtime
            Add-StepPlan -Fake $Fake -Step 'preflight' -Spec @(@{ HangMs = 40000 })
            $Fake.SleepHook = {
                param($F)
                $null = $F
                if (-not ($F.Launches | Where-Object { $_.Step -eq 'preflight' }) -or ($F.Launches | Where-Object { $_.Step -eq 'stop_runner' })) { return }
                foreach ($pair in @(@{ Key = 'Controller'; File = 'host-controller.state.json' }, @{ Key = 'Update'; File = 'host-update.state.json' })) {
                    $beat = (Get-Content -LiteralPath (Join-Path $runtime $pair.File) -Raw | ConvertFrom-Json -AsHashtable)['heartbeatUtc']
                    if (-not $beats[$pair.Key].Contains([string]$beat)) { $beats[$pair.Key].Add([string]$beat) }
                }
            }.GetNewClosure()
        }
        Assert-Equal -Expected 'updated_not_started' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 0 -Actual $run.Fake.Killed.Count 'a step inside its bound is not ended'
        foreach ($key in @('Controller', 'Update')) {
            Assert-True ($beats[$key].Count -ge 7) "the $key heartbeat advances during the 40 s wait ($($beats[$key].Count) values)"
            $times = @($beats[$key] | ForEach-Object { [DateTimeOffset]::Parse($_, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() })
            for ($i = 1; $i -lt $times.Count; $i++) { Assert-True (($times[$i] - $times[$i - 1]) -le 6000) "the $key heartbeat never pauses for more than 5 s" }
        }
    }

    It 'writes the public state at once on every phase change' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture
        $seen = [System.Collections.Generic.List[string]]::new()
        $runtime = $fixture.Runtime
        $run = Invoke-TestUpdate -Fixture $fixture -RequestId $id -Configure {
            param($Fake)
            # Copied into this scope so the hook closure below captures them.
            $seen = $seen; $runtime = $runtime
            $inner = $Fake.Service.OnPhaseWritten
            $Fake.Service.OnPhaseWritten = {
                param($Change)
                & $inner $Change
                if ($Change.ChildOnly) { return }
                $state = Get-Content -LiteralPath (Join-Path $runtime 'host-update.state.json') -Raw | ConvertFrom-Json -AsHashtable
                $seen.Add("$($Change.Phase):$($Change.State):$($state['phase']['name'])")
            }.GetNewClosure()
        }
        Assert-Equal -Expected 'updated' -Actual $run.Row['update']['verdict']
        Assert-Equal -Expected 12 -Actual $seen.Count 'six phases, started and finished'
        foreach ($entry in $seen) {
            $parts = $entry.Split(':')
            Assert-Equal -Expected $parts[0] -Actual $parts[2] "the state file names the phase at once ($entry)"
        }
    }

    It 'publishes queued, protocol_mismatch and request_expired rows: <Case>' -ForEach @(
        @{ Case = 'queued'; Blocked = $false; AgeMinutes = 0; Projected = 'queued'; Verdict = $null; Reason = $null }
        @{ Case = 'expired while blocked'; Blocked = $true; AgeMinutes = 31; Projected = 'terminal'; Verdict = 'refused'; Reason = 'protocol_mismatch' }
        @{ Case = 'expired unclaimed'; Blocked = $false; AgeMinutes = 31; Projected = 'terminal'; Verdict = 'refused'; Reason = 'request_expired' }
    ) {
        $fixture = New-ControllerFixture
        $id = Add-TestUpdate -Fixture $fixture
        if ($Blocked) { $null = Set-HostUpdateClaimBlocked -RequestId $id -Reason protocol_mismatch -Confirm:$false }
        $fake = New-FakeService -Fixture $fixture
        $fake.Clock.Ms += [long]$AgeMinutes * 60000
        if ($AgeMinutes -gt 0) {
            # Any transaction runs housekeeping, which expires the row.
            $null = Request-HostUpdateAdmission -RequestId (New-YurunaHostOperationRequestId) -Channel listener -RuntimeDir $fixture.Runtime -HostType 'host.ubuntu.kvm' `
                -UtcNow $fake.Service.UtcNow -Confirm:$false
            $journal = (Read-HostOperationJournal).Journal
            $journal.requests = [System.Collections.Generic.List[object]]@($journal.requests | Where-Object { $_['requestId'] -ceq $id })
        } else {
            $journal = (Read-HostOperationJournal).Journal
        }
        $context = New-TestContext -Fixture $fixture -Fake $fake
        InModuleScope Test.HostUpdate -Parameters @{ Ctx = $context; J = $journal } { param($Ctx, $J) Publish-HostUpdateIdleProjection -Context $Ctx -Journal $J }
        $public = Get-TestPublicState -Fixture $fixture
        Assert-Equal -Expected $id -Actual $public['requestId']
        Assert-Equal -Expected $Projected -Actual $public['state']
        Assert-Equal -Expected ([string]$Verdict) -Actual ([string]$public['verdict'])
        Assert-Equal -Expected ([string]$Reason) -Actual ([string]$public['reason'])
        Assert-Null $public['phase']
    }
}

Describe 'the controller log a scheduled task keeps' {
    It 'appends each line to the file the Windows shim names, and only there' {
        $log = Join-Path $TestDrive 'controller.log'
        $saved = Save-YurunaTestEnvironment -Name @('YURUNA_HOST_CONTROLLER_LOG')
        try {
            $env:YURUNA_HOST_CONTROLLER_LOG = $log
            Write-HostUpdateControllerLine -Line 'yuruna-host-controller: event=started' 2>$null
            Write-HostUpdateControllerLine -Line 'yuruna-host-controller: event=claimed' 2>$null
            $lines = @(Get-Content -LiteralPath $log)
            Assert-Equal -Expected 2 -Actual $lines.Count
            Assert-Match -Pattern '^\d{4}-\d{2}-\d{2}T\S+ yuruna-host-controller: event=claimed$' -Actual $lines[1]
            $env:YURUNA_HOST_CONTROLLER_LOG = 'relative.log'
            Write-HostUpdateControllerLine -Line 'x' 2>$null
            Assert-False (Test-Path -LiteralPath 'relative.log') 'a relative path is no log file'
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
    }
}

# The macOS rules run here on any host: the host type comes from the context
# or a parameter, every native call goes to a recorder, and no sudo, visudo,
# tmux, screen or launchctl runs.
Describe 'macOS: the declaration, the temporary rule and the permanent entry' {
    BeforeAll {
        function New-NativeRecorder {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory recorder.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Exit', Justification = 'Captured by the closure it returns.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Out', Justification = 'Captured by the closure it returns.')]
            param([hashtable]$Exit = @{}, [hashtable]$Out = @{})
            $record = @{ Calls = [System.Collections.Generic.List[string]]::new(); Texts = [System.Collections.Generic.List[string]]::new(); Modes = [System.Collections.Generic.List[string]]::new() }
            $record.Native = {
                param($FilePath, $ArgumentList, $TimeoutSeconds)
                $null = $TimeoutSeconds
                $line = (@($FilePath) + @($ArgumentList)) -join ' '
                $record.Calls.Add($line)
                # The private text visudo checks is read while it exists.
                if ($FilePath -eq '/usr/sbin/visudo' -and (Test-Path -LiteralPath $ArgumentList[-1])) {
                    $record.Texts.Add([System.IO.File]::ReadAllText($ArgumentList[-1]))
                    if (-not $IsWindows) { $record.Modes.Add([string][int][System.IO.File]::GetUnixFileMode($ArgumentList[-1])) }
                }
                $code = 0
                foreach ($pattern in @($Exit.Keys)) { if ($line -like $pattern) { $code = [int]$Exit[$pattern] } }
                $text = ''
                foreach ($pattern in @($Out.Keys)) { if ($line -like $pattern) { $text = [string]$Out[$pattern] } }
                @{ ExitCode = $code; TimedOut = $false; Started = $true; StdOut = $text; StdErr = '' }
            }.GetNewClosure()
            $record
        }
        $script:RulePath = '/etc/sudoers.d/yuruna-host-update'
        $script:MacRemove = 'sudo -n /bin/rm -f /etc/sudoers.d/yuruna-host-update'
    }

    It 'declares restart and full for every host type, and restart only for an unknown one' {
        foreach ($hostType in @('host.ubuntu.kvm', 'host.windows.hyper-v', 'host.macos.utm')) {
            Assert-Equal -Expected 'restart,full' -Actual ((Get-HostUpdateSupportedScope -HostType $hostType) -join ',') -Because $hostType
        }
        Assert-Equal -Expected 'restart' -Actual ((Get-HostUpdateSupportedScope -HostType 'host.other') -join ',')
        $expected = if ($IsWindows) { 'host.windows.hyper-v' } elseif ($IsMacOS) { 'host.macos.utm' } else { 'host.ubuntu.kvm' }
        Assert-Equal -Expected $expected -Actual (Get-HostUpdateHostType)
    }

    It 'bounds the enable phase at 600 s on macOS and keeps every other bound' {
        $kvm = Get-HostUpdatePhaseBound -HostType 'host.ubuntu.kvm'
        $mac = Get-HostUpdatePhaseBound -HostType 'host.macos.utm'
        $windows = Get-HostUpdatePhaseBound -HostType 'host.windows.hyper-v'
        Assert-Equal -Expected 300 -Actual $kvm['enable']
        Assert-Equal -Expected 600 -Actual $mac['enable']
        Assert-Equal -Expected 2400 -Actual $mac['install']
        Assert-Equal -Expected 3600 -Actual $windows['install']
        Assert-Equal -Expected 300 -Actual $windows['enable']
        foreach ($name in @($kvm.Keys)) {
            if ($name -ne 'enable') { Assert-Equal -Expected $kvm[$name] -Actual $mac[$name] -Because $name }
        }
        $fixture = New-ControllerFixture
        $context = New-HostUpdateControllerContext -ControllerRoot $fixture.ControllerRoot -Snapshot $fixture.Snapshot -Checkout $fixture.Checkout -HostType 'host.macos.utm'
        Assert-Equal -Expected 600 -Actual $context.Bound['enable']
        Assert-Equal -Expected 'host.macos.utm' -Actual $context.HostType
        $row = @{ requestId = '4242aaaa-0000-4000-8000-000000000001'; state = 'running'; update = @{ phase = 'enable'; request = @{ scope = 'full'; drainSeconds = 60 } } }
        $public = ConvertTo-HostUpdatePublicState -Row $row -Now ([DateTimeOffset]::UtcNow) -HostType 'host.macos.utm'
        Assert-Equal -Expected 600 -Actual $public['phase']['bound'] 'the public state names the macOS bound'
        Assert-Equal -Expected 300 -Actual (ConvertTo-HostUpdatePublicState -Row $row -Now ([DateTimeOffset]::UtcNow) -HostType 'host.ubuntu.kvm')['phase']['bound']
    }

    It 'writes the macOS rule with its own expiry through the allowed tee, confirms it uncached, and starts no timer' {
        $work = Join-Path $script:ScratchBase ('rule-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work -Force
        $recorder = New-NativeRecorder
        $before = [DateTimeOffset]::UtcNow
        $rule = Set-HostUpdateSudoRule -Account 'ytest' -ExpirySeconds 2520 -WorkDirectory $work -Native $recorder.Native -HostType 'host.macos.utm' -Confirm:$false
        $after = [DateTimeOffset]::UtcNow
        Assert-True $rule.Written $rule.Reason
        Assert-Equal -Expected 'ok' -Actual $rule.Reason
        $text = Join-Path $work "sudo-rule.$PID"
        Assert-Equal -Expected 3 -Actual $recorder.Calls.Count ($recorder.Calls -join ' | ')
        Assert-Equal -Expected "/usr/sbin/visudo -cf $text" -Actual $recorder.Calls[0]
        Assert-Equal -Expected "/bin/sh -c umask 0227; exec sudo -n /usr/bin/tee `"`$1`" < `"`$2`" > /dev/null sh $($script:RulePath) $text" -Actual $recorder.Calls[1]
        Assert-Equal -Expected 'sudo -n -k true' -Actual $recorder.Calls[2]
        Assert-False ((Test-Path -LiteralPath $text)) 'the private text is removed'
        $match = [regex]::Match($recorder.Texts[0], '\Aytest ALL=\(ALL:ALL\) NOTAFTER=([0-9]{14})Z NOPASSWD: ALL\n\z')
        Assert-True $match.Success "rule text: $($recorder.Texts[0])"
        $notAfter = [DateTimeOffset]::ParseExact($match.Groups[1].Value, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        Assert-True ($notAfter -ge $before.AddSeconds(2519) -and $notAfter -le $after.AddSeconds(2521)) "the expiry is the bound plus the margin from now: $notAfter"
        if (-not $IsWindows) { Assert-Equal -Expected '384' -Actual $recorder.Modes[0] 'the text is private: 0600' }
    }

    It 'removes the macOS rule with exactly the allowed rm when <Case>' -ForEach @(
        @{ Case = 'visudo refuses the text'; Exit = @{ '/usr/sbin/visudo *' = 1 }; Reason = 'visudo-refused'; Removes = $false }
        @{ Case = 'the tee fails'; Exit = @{ '/bin/sh *' = 1 }; Reason = 'write-failed'; Removes = $true }
        @{ Case = 'the uncached confirmation fails'; Exit = @{ 'sudo -n -k true' = 1 }; Reason = 'not-confirmed'; Removes = $true }
    ) {
        $work = Join-Path $script:ScratchBase ('rule-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work -Force
        $recorder = New-NativeRecorder -Exit $Exit
        $rule = Set-HostUpdateSudoRule -Account 'ytest' -ExpirySeconds 720 -WorkDirectory $work -Native $recorder.Native -HostType 'host.macos.utm' -Confirm:$false
        Assert-False $rule.Written
        Assert-Equal -Expected $Reason -Actual $rule.Reason
        Assert-Equal -Expected ([int]$Removes) -Actual @($recorder.Calls | Where-Object { $_ -ceq $script:MacRemove }).Count
        Assert-Equal -Expected 0 -Actual @($recorder.Calls | Where-Object { $_ -match 'systemctl|systemd-run|chmod|^sudo -n rm ' }).Count 'no KVM call on macOS'
    }

    It 'removes the rule on macOS with the one call the entry allows, and on KVM as before' {
        $mac = New-NativeRecorder
        Assert-True (Remove-HostUpdateSudoRule -Native $mac.Native -HostType 'host.macos.utm' -Confirm:$false)
        Assert-Equal -Expected $script:MacRemove -Actual ($mac.Calls -join ' | ')
        $kvm = New-NativeRecorder
        Assert-True (Remove-HostUpdateSudoRule -Native $kvm.Native -HostType 'host.ubuntu.kvm' -Confirm:$false)
        Assert-Equal -Expected 'sudo -n rm -f /etc/sudoers.d/yuruna-host-update | sudo -n systemctl stop yuruna-host-update-expire.timer' -Actual ($kvm.Calls -join ' | ')
        $failed = New-NativeRecorder -Exit @{ 'sudo *' = 1 }
        Assert-False (Remove-HostUpdateSudoRule -Native $failed.Native -HostType 'host.macos.utm' -Confirm:$false)
    }

    It 'writes the KVM rule with the same calls as before when no host type is named on a Linux host' -Skip:(-not $IsLinux) {
        $work = Join-Path $script:ScratchBase ('rule-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work -Force
        $recorder = New-NativeRecorder
        $rule = Set-HostUpdateSudoRule -Account 'ytest' -ExpirySeconds 720 -WorkDirectory $work -Native $recorder.Native -Confirm:$false
        Assert-Equal -Expected 'ok' -Actual $rule.Reason
        $text = Join-Path $work "sudo-rule.$PID"
        $visudo = if ([System.IO.File]::Exists('/usr/sbin/visudo')) { '/usr/sbin/visudo' } else { 'visudo' }
        Assert-Equal -Expected (@(
                "$visudo -cf $text"
                "/bin/sh -c exec sudo -n tee `"`$1`" < `"`$2`" > /dev/null sh $($script:RulePath) $text"
                'sudo -n -k true'
                "sudo -n chmod 0440 $($script:RulePath)"
                'sudo -n systemctl stop yuruna-host-update-expire.timer'
                'sudo -n systemctl reset-failed yuruna-host-update-expire.timer yuruna-host-update-expire.service'
                "sudo -n systemd-run --unit=yuruna-host-update-expire --on-active=720s --timer-property=AccuracySec=1s --quiet /usr/bin/rm -f $($script:RulePath)"
            ) -join ' | ') -Actual ($recorder.Calls -join ' | ')
        Assert-Equal -Expected "ytest ALL=(ALL:ALL) NOPASSWD: ALL`n" -Actual $recorder.Texts[0]
    }

    It 'probes the macOS entry with a comment-only file through the allowed tee and rm, uncached: <Case>' -ForEach @(
        @{ Case = 'both pass'; Exit = @{}; Ready = $true; Calls = 2 }
        @{ Case = 'the tee is refused'; Exit = @{ '/bin/sh *' = 1 }; Ready = $false; Calls = 1 }
        @{ Case = 'the rm is refused'; Exit = @{ 'sudo -n -k /bin/rm *' = 1 }; Ready = $false; Calls = 2 }
    ) {
        $recorder = New-NativeRecorder -Exit $Exit
        Assert-Equal -Expected $Ready -Actual (Test-HostUpdateMacElevationEntry -Native $recorder.Native)
        Assert-Equal -Expected $Calls -Actual $recorder.Calls.Count
        Assert-Equal -Expected "/bin/sh -c umask 0227; printf '# yuruna host update elevation probe\n' | exec sudo -n -k /usr/bin/tee `"`$1`" > /dev/null sh $($script:RulePath)" -Actual $recorder.Calls[0]
        if ($Calls -eq 2) { Assert-Equal -Expected "sudo -n -k /bin/rm -f $($script:RulePath)" -Actual $recorder.Calls[1] }
    }

    It 'renders the permanent entry for an account and refuses an account name sudoers would misread' {
        Assert-Equal -Expected "ytest ALL=(root) NOPASSWD: /usr/bin/tee /etc/sudoers.d/yuruna-host-update, /bin/rm -f /etc/sudoers.d/yuruna-host-update`n" -Actual (Get-HostUpdateAccessEntryText -Account 'ytest')
        $threw = $false
        try { $null = Get-HostUpdateAccessEntryText -Account 'a b' } catch { $threw = $true }
        Assert-True $threw
    }

    It 'installs the permanent entry: <Case>' -ForEach @(
        @{ Case = 'absent'; Exit = @{ 'sudo -n /bin/cat *' = 1 }; Out = @{}; Reason = 'installed'; Detail = $null; Installs = $true; Removes = $false }
        @{ Case = 'the same text'; Exit = @{}; Out = @{ 'sudo -n /bin/cat *' = 'SAME' }; Reason = 'unchanged'; Detail = $null; Installs = $false; Removes = $false }
        @{ Case = 'another text'; Exit = @{}; Out = @{ 'sudo -n /bin/cat *' = "other ALL=(ALL) ALL`n" }; Reason = 'replaced'; Detail = $null; Installs = $true; Removes = $false }
        @{ Case = 'visudo refuses the text'; Exit = @{ 'sudo -n /bin/cat *' = 1; '/usr/sbin/visudo *' = 1 }; Out = @{}; Reason = 'failed'; Detail = 'visudo-refused'; Installs = $false; Removes = $false }
        @{ Case = 'install fails'; Exit = @{ 'sudo -n /bin/cat *' = 1; 'sudo -n /usr/bin/install *' = 1 }; Out = @{}; Reason = 'failed'; Detail = 'install-failed'; Installs = $true; Removes = $false }
        @{ Case = 'visudo refuses the installed file'; Exit = @{ 'sudo -n /bin/cat *' = 1; 'sudo -n /usr/sbin/visudo *' = 1 }; Out = @{}; Reason = 'failed'; Detail = 'installed-check-refused'; Installs = $true; Removes = $true }
    ) {
        $work = Join-Path $script:ScratchBase ('entry-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $work -Force
        $wanted = Get-HostUpdateAccessEntryText -Account 'ytest'
        $answers = @{}
        foreach ($key in $Out.Keys) { $answers[$key] = if ($Out[$key] -eq 'SAME') { $wanted } else { $Out[$key] } }
        $recorder = New-NativeRecorder -Exit $Exit -Out $answers
        $result = Install-HostUpdateAccessEntry -Account 'ytest' -Native $recorder.Native -WorkDirectory $work -Confirm:$false
        Assert-Equal -Expected $Reason -Actual $result.Reason ($recorder.Calls -join ' | ')
        Assert-Equal -Expected $Detail -Actual $result.Detail
        $entry = '/etc/sudoers.d/yuruna-host-update-access'
        Assert-Equal -Expected "sudo -n /bin/cat $entry" -Actual $recorder.Calls[0]
        $install = @($recorder.Calls | Where-Object { $_ -like 'sudo -n /usr/bin/install *' })
        Assert-Equal -Expected ([int]$Installs) -Actual $install.Count
        if ($Installs) {
            Assert-Match -Pattern ('\Asudo -n /usr/bin/install -m 0440 -o root -g wheel ' + [regex]::Escape([System.IO.Path]::Combine($work, 'yuruna-host-update-access')) + '\.[0-9]+\.[0-9a-f]{8} ' + [regex]::Escape($entry) + '\z') -Actual $install[0]
            Assert-Equal -Expected $wanted -Actual $recorder.Texts[0] 'visudo checked the entry text before it was installed'
            if (-not $IsWindows) { Assert-Equal -Expected '384' -Actual $recorder.Modes[0] 'the text is private: 0600' }
        }
        Assert-Equal -Expected ([int]$Removes) -Actual @($recorder.Calls | Where-Object { $_ -ceq "sudo -n /bin/rm -f $entry" }).Count
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $work -Force).Count 'the private text is removed'
    }

    It 'previews and removes the permanent entry' {
        $recorder = New-NativeRecorder
        Assert-Equal -Expected 'preview' -Actual (Install-HostUpdateAccessEntry -Account 'ytest' -Native $recorder.Native -WhatIf).Reason
        Assert-Equal -Expected 0 -Actual $recorder.Calls.Count
        Assert-True (Remove-HostUpdateAccessEntry -Native $recorder.Native -Confirm:$false)
        Assert-Equal -Expected 'sudo -n /bin/rm -f /etc/sudoers.d/yuruna-host-update-access' -Actual ($recorder.Calls -join ' | ')
        $failed = New-NativeRecorder -Exit @{ 'sudo *' = 1 }
        Assert-False (Remove-HostUpdateAccessEntry -Native $failed.Native -Confirm:$false)
    }
}

Describe 'macOS: the elevated work of an install or enable phase' {
    BeforeAll {
        $script:MacRequest = '4242aaaa-0000-4000-8000-000000000001'
        function New-MacRow {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory row.')]
            param([int]$Id, [int]$Parent, [int]$Owner, [string[]]$Argv)
            [pscustomobject]@{ Pid = $Id; ParentPid = $Parent; StartTimeUnixMs = [long](1700000000000 + $Id); OwnerId = $Owner; Argv = $Argv; CommandLine = ($Argv -join ' ') }
        }
        $script:MacTable = [pscustomobject]@{
            Complete = $true
            Rows     = @(
                New-MacRow -Id 100 -Parent 1 -Owner 501 -Argv @('/opt/homebrew/bin/pwsh', '-File', '/u/git/yuruna/test/lab/Invoke-HostUpdateStep.ps1', '-Step', 'install')
                New-MacRow -Id 200 -Parent 100 -Owner 501 -Argv @('/bin/bash', '/u/git/yuruna/install/macos.utm.sh', '--unattended', '--request-id', $script:MacRequest, '--attempt', '1')
                New-MacRow -Id 210 -Parent 200 -Owner 0 -Argv @('sudo', '-n', '/usr/sbin/chown', 'x')
                New-MacRow -Id 211 -Parent 210 -Owner 0 -Argv @('/usr/sbin/chown', 'x')
                New-MacRow -Id 220 -Parent 200 -Owner 501 -Argv @('/opt/homebrew/bin/brew', 'upgrade')
                New-MacRow -Id 300 -Parent 1 -Owner 501 -Argv @('/bin/bash', '/u/git/yuruna/install/macos.utm.sh', '--unattended', '--request-id', '4242aaaa-0000-4000-8000-000000000002', '--attempt', '1')
                New-MacRow -Id 400 -Parent 1 -Owner 501 -Argv @('/opt/homebrew/bin/pwsh', '-NoLogo', '-File', '/u/git/yuruna/test/lab/Enable-TestAutomation.ps1', '-SkipPoolStorage', '-NoOperatorPrompt')
                New-MacRow -Id 410 -Parent 400 -Owner 0 -Argv @('sudo', '-n', '/usr/bin/pmset', '-a', 'sleep', '0')
                New-MacRow -Id 500 -Parent 1 -Owner 501 -Argv @('/opt/homebrew/bin/pwsh', '-File', '/u/git/yuruna/test/lab/Enable-TestAutomation.ps1')
                New-MacRow -Id 600 -Parent 1 -Owner 501 -Argv @('/bin/bash', '/u/git/yuruna/install/macos.utm.sh')
            )
        }
    }

    It 'finds the unattended installer of the request and every Enable run of the checkout without a prompt, descendants included' {
        $table = $script:MacTable
        $work = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Checkout '/u/git/yuruna' -Service @{ ProcessTable = { $table }.GetNewClosure() }
        Assert-Equal -Expected '200:install:False,210:install:True,211:install:True,220:install:False,400:enable:False,410:enable:True' `
            -Actual ((@($work) | Sort-Object ProcessId | ForEach-Object { "$($_.ProcessId):$($_.Kind):$($_.Root)" }) -join ',')
        $order = @(@($work) | ForEach-Object { $_.ProcessId })
        Assert-True ([array]::IndexOf($order, 210) -lt [array]::IndexOf($order, 211)) 'a parent comes before its child'
        Assert-Equal -Expected ([long]1700000000210) -Actual @($work | Where-Object { $_.ProcessId -eq 210 })[0].StartTimeUnixMs
    }

    It 'finds the same work in rows that carry only a joined command line, as macOS ps gives them' {
        $at = 'Mon Nov 23 10:00:00 2026'
        $lines = @(
            "  100     1   100   501 $at /usr/local/microsoft/powershell/7/pwsh -File /Users/u/git/yuruna/test/lab/Invoke-HostUpdateStep.ps1 -Step install"
            "  200   100   100   501 $at /bin/bash /Users/u/git/yuruna/install/macos.utm.sh --unattended --request-id $($script:MacRequest) --attempt 1"
            "  210   200   100     0 $at sudo -n /usr/sbin/chown x"
            "  211   210   100     0 $at /usr/sbin/chown x"
            "  220   200   100   501 $at /opt/homebrew/bin/brew upgrade"
            "  300     1   300   501 $at /bin/bash /Users/u/git/yuruna/install/macos.utm.sh --unattended --request-id 4242aaaa-0000-4000-8000-000000000002 --attempt 1"
            "  400     1   400   501 $at /usr/local/microsoft/powershell/7/pwsh -NoLogo -File /Users/u/git/yuruna/test/lab/Enable-TestAutomation.ps1 -SkipPoolStorage -NoOperatorPrompt"
            "  410   400   400     0 $at sudo -n /usr/bin/pmset -a sleep 0"
            "  500     1   500   501 $at /usr/local/microsoft/powershell/7/pwsh -File /Users/u/git/yuruna/test/lab/Enable-TestAutomation.ps1"
            "  600     1   600   501 $at /bin/bash /Users/u/git/yuruna/install/macos.utm.sh"
        )
        $rows = @(& (Get-Module Test.SingleInstance) { param($Lines) foreach ($line in $Lines) { ConvertFrom-YurunaPsLine -Line $line } } $lines)
        Assert-Equal -Expected $lines.Count -Actual $rows.Count 'fixture sanity: every ps line parses'
        Assert-Equal -Expected 0 -Actual @($rows | Where-Object { $null -ne $_.Argv }).Count 'fixture sanity: a ps row carries no argument vector'
        # A double-quoted run is one token: a path with spaces stays whole.
        $rows += [pscustomobject]@{ Pid = 700; ParentPid = 1; StartTimeUnixMs = [long]1700000000700; OwnerId = '501'; Argv = $null
            CommandLine = '"/usr/local/microsoft/powershell/7/pwsh" -File "/Users/u/My Repos/yuruna/test/lab/Enable-TestAutomation.ps1" -NoOperatorPrompt' }
        $table = [pscustomobject]@{ Complete = $true; Rows = $rows }
        $work = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Checkout '/Users/u/git/yuruna', '/Users/u/My Repos/yuruna' -Service @{ ProcessTable = { $table }.GetNewClosure() }
        Assert-Equal -Expected '200:install:False,210:install:True,211:install:True,220:install:False,400:enable:False,410:enable:True,700:enable:False' `
            -Actual ((@($work) | Sort-Object ProcessId | ForEach-Object { "$($_.ProcessId):$($_.Kind):$($_.Root)" }) -join ',')
        Assert-Equal -Expected ([long]$rows[2].StartTimeUnixMs) -Actual @($work | Where-Object { $_.ProcessId -eq 210 })[0].StartTimeUnixMs
    }

    It 'answers an empty list when nothing runs, and $null when the table is incomplete' {
        $empty = [pscustomobject]@{ Complete = $true; Rows = @($script:MacTable.Rows | Where-Object { $_.Pid -ge 500 }) }
        $none = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Service @{ ProcessTable = { $empty }.GetNewClosure() }
        Assert-NotNull $none 'an empty list is a list'
        Assert-Equal -Expected 0 -Actual @($none).Count
        $partial = [pscustomobject]@{ Complete = $false; Rows = $script:MacTable.Rows }
        Assert-Null (Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Service @{ ProcessTable = { $partial }.GetNewClosure() })
    }

    It 'finds only the Enable runs of the checkout it is given, either Enable script, compared by full path' {
        # An unattended Enable of another checkout, such as a suite that runs
        # the real script, is no work of this update.
        $pwsh = '/opt/homebrew/bin/pwsh'
        $table = [pscustomobject]@{
            Complete = $true
            Rows     = @(
                New-MacRow -Id 400 -Parent 1 -Owner 501 -Argv @($pwsh, '-NoLogo', '-File', '/u/git/yuruna/test/lab/Enable-TestAutomation.ps1', '-SkipPoolStorage', '-NoOperatorPrompt')
                New-MacRow -Id 410 -Parent 400 -Owner 0 -Argv @('sudo', '-n', '/usr/bin/pmset', '-a', 'sleep', '0')
                New-MacRow -Id 450 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/yuruna/host/macos.utm/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
                New-MacRow -Id 500 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/other/test/lab/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
                New-MacRow -Id 510 -Parent 500 -Owner 0 -Argv @('sudo', '-n', '/usr/bin/pmset', '-a', 'sleep', '0')
                New-MacRow -Id 520 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/yuruna2/test/lab/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
                New-MacRow -Id 530 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', 'test/lab/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
                New-MacRow -Id 540 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/yuruna/host/ubuntu.kvm/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
                New-MacRow -Id 550 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/other/host/macos.utm/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
            )
        }
        $work = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Checkout '/u/git/yuruna/' -Service @{ ProcessTable = { $table }.GetNewClosure() }
        Assert-Equal -Expected '400:enable:False,410:enable:True,450:enable:False' `
            -Actual ((@($work) | Sort-Object ProcessId | ForEach-Object { "$($_.ProcessId):$($_.Kind):$($_.Root)" }) -join ',') `
            'another checkout, a checkout whose path only starts the same, a relative path and another host type''s script are left alone'
    }

    It 'finds the Enable runs of a checkout whose path holds a space in rows that carry only the macOS ps command line' {
        $at = 'Mon Nov 23 10:00:00 2026'
        $pwsh = '/usr/local/microsoft/powershell/7/pwsh'
        # ps joins the argument vector with single spaces and no quotes, so
        # each of these paths reads as two tokens.
        $lines = @(
            "  700     1   700   501 $at $pwsh -NoLogo -File /Users/u/My Repos/yuruna/test/lab/Enable-TestAutomation.ps1 -SkipPoolStorage -NoOperatorPrompt"
            "  710   700   700     0 $at sudo -n /usr/bin/pmset -a sleep 0"
            "  720     1   720   501 $at $pwsh -File /Users/u/My Repos/yuruna/host/macos.utm/Enable-TestAutomation.ps1 -NoOperatorPrompt"
            "  730     1   730   501 $at $pwsh -File /Users/u/Other Repos/yuruna/test/lab/Enable-TestAutomation.ps1 -NoOperatorPrompt"
            "  740     1   740   501 $at $pwsh -File /Users/u/My Repos/yuruna-b/test/lab/Enable-TestAutomation.ps1 -NoOperatorPrompt"
            "  750     1   750   501 $at $pwsh -File Repos/yuruna/test/lab/Enable-TestAutomation.ps1 -NoOperatorPrompt"
        )
        $rows = @(& (Get-Module Test.SingleInstance) { param($Lines) foreach ($line in $Lines) { ConvertFrom-YurunaPsLine -Line $line } } $lines)
        Assert-Equal -Expected $lines.Count -Actual $rows.Count 'fixture sanity: every ps line parses'
        Assert-Equal -Expected 0 -Actual @($rows | Where-Object { $null -ne $_.Argv }).Count 'fixture sanity: a ps row carries no argument vector'
        $table = [pscustomobject]@{ Complete = $true; Rows = $rows }
        $work = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Checkout '/Users/u/My Repos/yuruna' -Service @{ ProcessTable = { $table }.GetNewClosure() }
        Assert-Equal -Expected '700:enable:False,710:enable:True,720:enable:False' `
            -Actual ((@($work) | Sort-Object ProcessId | ForEach-Object { "$($_.ProcessId):$($_.Kind):$($_.Root)" }) -join ',')
    }

    It 'takes the checkout of its own module when no checkout is given' {
        $pwsh = '/opt/homebrew/bin/pwsh'
        $own = [System.IO.Path]::Combine($script:RepoRoot, 'test', 'lab', 'Enable-TestAutomation.ps1')
        $table = [pscustomobject]@{
            Complete = $true
            Rows     = @(
                New-MacRow -Id 400 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', $own, '-SkipPoolStorage', '-NoOperatorPrompt')
                New-MacRow -Id 500 -Parent 1 -Owner 501 -Argv @($pwsh, '-File', '/u/git/other/test/lab/Enable-TestAutomation.ps1', '-NoOperatorPrompt')
            )
        }
        $work = Get-HostUpdateMacElevatedWork -RequestId $script:MacRequest -Service @{ ProcessTable = { $table }.GetNewClosure() }
        Assert-Equal -Expected '400' -Actual ((@($work) | ForEach-Object { $_.ProcessId }) -join ',')
    }

    It 'ends test-account members first, then root members through sudo kill, TERM before KILL, start time checked' {
        # 230 and 240 are pids reused since the snapshot: their live start
        # times differ from the recorded ones, so they are no member any more.
        $alive = @{ 200 = 'alive'; 210 = 'alive'; 211 = 'alive'; 220 = 'dead'; 230 = 'alive'; 240 = 'alive' }
        $liveStart = @{ 200 = 1700000000200; 210 = 1700000000210; 211 = 1700000000211; 220 = 1700000000220; 230 = 1700000099230; 240 = 1700000099240 }
        $stopped = [System.Collections.Generic.List[int]]::new()
        $order = [System.Collections.Generic.List[string]]::new()
        $calls = [System.Collections.Generic.List[string]]::new()
        $service = @{
            Liveness    = {
                param($ProcessId, $StartTimeUnixMs)
                if ([long]$StartTimeUnixMs -ne $liveStart[[int]$ProcessId]) { return 'dead' }
                $alive[[int]$ProcessId]
            }.GetNewClosure()
            StopProcess = { param($ProcessId) $stopped.Add($ProcessId); $order.Add("stop $ProcessId"); $alive[[int]$ProcessId] = 'dead' }.GetNewClosure()
            Sleep       = { param($Milliseconds) $null = $Milliseconds }
        }
        $native = {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            $null = $TimeoutSeconds
            $line = (@($FilePath) + @($ArgumentList)) -join ' '
            $calls.Add($line); $order.Add($line)
            # 210 ends on TERM; 211 ignores it and ends on KILL.
            $target = [int]$ArgumentList[-1]
            if ($ArgumentList[-2] -eq '-KILL' -or $target -eq 210) { $alive[$target] = 'dead' }
            @{ ExitCode = 0; TimedOut = $false }
        }.GetNewClosure()
        $work = @(
            [pscustomobject]@{ ProcessId = 200; StartTimeUnixMs = 1700000000200; Kind = 'install'; Root = $false }
            [pscustomobject]@{ ProcessId = 210; StartTimeUnixMs = 1700000000210; Kind = 'install'; Root = $true }
            [pscustomobject]@{ ProcessId = 220; StartTimeUnixMs = 1700000000220; Kind = 'install'; Root = $false }
            [pscustomobject]@{ ProcessId = 211; StartTimeUnixMs = 1700000000211; Kind = 'install'; Root = $true }
            [pscustomobject]@{ ProcessId = 230; StartTimeUnixMs = 1700000000230; Kind = 'install'; Root = $false }
            [pscustomobject]@{ ProcessId = 240; StartTimeUnixMs = 1700000000240; Kind = 'install'; Root = $true }
        )
        Assert-True (Stop-HostUpdateMacElevatedWork -Work $work -Native $native -Service $service -Confirm:$false)
        Assert-Equal -Expected '200' -Actual ($stopped -join ',') 'a member already gone, or whose pid another process now has, is not stopped'
        Assert-Equal -Expected 'stop 200,sudo -n /bin/kill -TERM 210,sudo -n /bin/kill -TERM 211,sudo -n /bin/kill -KILL 211' -Actual ($order -join ',')
        Assert-Equal -Expected 'alive' -Actual $alive[240] 'a reused pid is never signaled through sudo'
    }

    It 'never reads $null or a member that stays alive as gone' {
        Assert-False (Stop-HostUpdateMacElevatedWork -Work $null -Confirm:$false)
        Assert-True (Stop-HostUpdateMacElevatedWork -Work @() -Confirm:$false) 'nothing to end is gone'
        $service = @{ Liveness = { 'alive' }; StopProcess = { param($ProcessId) $null = $ProcessId }; Sleep = { param($Milliseconds) $null = $Milliseconds } }
        $native = { param($FilePath, $ArgumentList, $TimeoutSeconds) $null = $FilePath, $ArgumentList, $TimeoutSeconds; @{ ExitCode = 1; TimedOut = $false } }
        $work = @([pscustomobject]@{ ProcessId = 210; StartTimeUnixMs = 1; Kind = 'install'; Root = $true })
        Assert-False (Stop-HostUpdateMacElevatedWork -Work $work -Native $native -Service $service -Confirm:$false)
    }
}

Describe 'macOS: the controller' {
    BeforeAll {
        function New-MacTestContext {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory context.')]
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)]$Fake, [string]$HostType = 'host.macos.utm')
            $context = New-HostUpdateControllerContext -ControllerRoot $Fixture.ControllerRoot -Snapshot $Fixture.Snapshot -Checkout $Fixture.Checkout -Service $Fake.Service -HostType $HostType
            $context.PrivateRoot = $Fixture.PrivateRoot
            $context.RuntimeDir = $Fixture.Runtime
            $context
        }
        function Get-IdleControllerState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates the default runtime folder of a scratch checkout.')]
            param([Parameter(Mandatory)]$Fixture, [switch]$Prepare)
            # With no journal owner yet the controller publishes into the
            # checkout's default runtime folder.
            $runtime = Join-Path $Fixture.Checkout 'test/status/runtime'
            if ($Prepare) { $null = New-Item -ItemType Directory -Path $runtime -Force; return }
            Get-Content -LiteralPath (Join-Path $runtime 'host-controller.state.json') -Raw | ConvertFrom-Json -AsHashtable
        }
        function Add-MacFake {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: adds stand-in services.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Usable', Justification = 'Captured by the closure it returns.')]
            param([Parameter(Mandatory)]$Fake, $Work = @(), [bool]$Usable = $true)
            $Fake.Work = $Work
            $Fake.WorkStops = [System.Collections.Generic.List[object]]::new()
            $Fake.SeenScopes = [System.Collections.Generic.List[string]]::new()
            $Fake.Service.ElevatedWork = { param($RequestId) $null = $RequestId; $Fake.Work }.GetNewClosure()
            # The marker shares the native call log, so the order of ending
            # the work and removing the rule is observable.
            $Fake.Service.StopElevatedWork = { param($Work, $Native) $null = $Native; $Fake.WorkStops.Add($Work); $Fake.Native.Add('stop-elevated-work'); $true }.GetNewClosure()
            $Fake.Service.SessionProbe = { @{ SessionKind = 'Aqua'; Ssh = $false; Grants = @{}; Usable = $Usable } }.GetNewClosure()
            $inner = $Fake.Service.StartStep
            $Fake.Service.StartStep = {
                param($Launch)
                if ($Launch.Step -eq 'preflight') {
                    $path = Join-Path $Launch.Environment.YURUNA_RUNTIME_DIR 'host-controller.state.json'
                    $Fake.SeenScopes.Add($(if (Test-Path -LiteralPath $path) { [string]((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)['scopes']) } else { '<none>' }))
                }
                & $inner $Launch
            }.GetNewClosure()
        }
        $script:MacRemove = 'sudo -n /bin/rm -f /etc/sudoers.d/yuruna-host-update'
    }

    It 'probes just before it claims a full update and publishes that result before the claim: <Case>' -ForEach @(
        @{ Case = 'the entry starts working after the start'; Answers = @($false, $true); Scopes = 'restart,full' }
        @{ Case = 'the entry goes missing after the start'; Answers = @($true, $false); Scopes = 'restart' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        Get-IdleControllerState -Fixture $fixture -Prepare
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        Add-MacFake -Fake $fake
        # Each probe answers differently and notes whether the row was
        # already claimed when it ran.
        $probe = @{ Count = 0; Claimed = [System.Collections.Generic.List[bool]]::new() }
        $fake.Service.ElevationProbe = {
            $fake.ProbeAt.Add($fake.Clock.Ms - $fake.StartMs)
            $probe.Claimed.Add([bool](Get-HostUpdateQueue).Claimed)
            $answer = $Answers[[Math]::Min($probe.Count, $Answers.Count - 1)]
            $probe.Count++
            $answer
        }.GetNewClosure()
        # The claim's own log line comes before its heartbeat: the state
        # file read there is what was published before the claim.
        $published = [System.Collections.Generic.List[string]]::new()
        $statePath = Join-Path $fixture.Checkout 'test/status/runtime/host-controller.state.json'
        $log = $fake.Service.Log
        $fake.Service.Log = {
            param([string]$Line)
            & $log $Line
            if ($Line -match 'event=claim-claim ') { $published.Add([string]((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable)['scopes'])) }
        }.GetNewClosure()
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected '0,0' -Actual (@($fake.ProbeAt) -join ',') 'one probe at start, one right before the claim'
        Assert-Equal -Expected 'False,False' -Actual ($probe.Claimed -join ',') 'no probe runs while the update is claimed'
        Assert-Equal -Expected $Scopes -Actual ($published -join ',') 'the probe before the claim is published before the claim'
        Assert-Equal -Expected $Scopes -Actual ($fake.SeenScopes -join ',') 'phase 1 reads the probe made before its claim'
    }

    It 'probes a full update whose claim keeps being refused at most once a minute, not on every queue read' {
        $fixture = New-ControllerFixture
        $null = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture
        $holder = @{ Fake = $fake }
        $fake.Service.ShouldStop = { param($Context) $null = $Context; $holder.Fake.Clock.Ms - $holder.Fake.StartMs -ge 130000 }.GetNewClosure()
        $fake.FullReady = $true
        Add-MacFake -Fake $fake
        # A refusal that leaves the row queued, as an owner mismatch does.
        Mock Confirm-HostUpdateClaim -ModuleName Test.HostUpdate { [pscustomobject]@{ Accepted = $false; Reason = 'owner-mismatch'; Row = $null } }
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-True (@($fake.Log | Where-Object { $_ -match 'event=claim-refused ' }).Count -ge 60) 'the claim is tried on every queue read'
        Assert-Equal -Expected '0,0,60000,120000' -Actual (@($fake.ProbeAt) -join ',') 'the start probe, then one before the claim each minute'
    }

    It 'never probes while the journal cannot be read, at start nor on the ten-minute timer: <Case>' -ForEach @(
        @{ Case = 'macOS'; HostType = 'host.macos.utm'; Probes = '' }
        @{ Case = 'KVM probes as before'; HostType = 'host.ubuntu.kvm'; Probes = '0,600000,1200000' }
    ) {
        $fixture = New-ControllerFixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.PrivateRoot 'host-operation.journal'), 'not a journal')
        $fake = New-FakeService -Fixture $fixture
        $holder = @{ Fake = $fake }
        $fake.Service.ShouldStop = { param($Context) $null = $Context; $holder.Fake.Clock.Ms - $holder.Fake.StartMs -ge 1300000 }.GetNewClosure()
        Add-MacFake -Fake $fake
        Get-IdleControllerState -Fixture $fixture -Prepare
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake -HostType $HostType)
        Assert-True ($fake.Log | Where-Object { $_ -match 'event=started .*journal=corrupt' }) 'fixture sanity: the journal reads corrupt'
        Assert-Equal -Expected $Probes -Actual (@($fake.ProbeAt) -join ',') 'a claimed update the journal cannot show may have its rule in force'
        Assert-Equal -Expected 'restart' -Actual (Get-IdleControllerState -Fixture $fixture)['scopes']
    }

    # A fresh host has no journal until its first update is queued, and a
    # missing journal holds no claim, so it must not keep full off the list.
    It 'probes a host with no journal yet, at start and on the ten-minute timer, and lists full: <Case>' -ForEach @(
        @{ Case = 'macOS'; HostType = 'host.macos.utm' }
        @{ Case = 'KVM as before'; HostType = 'host.ubuntu.kvm' }
    ) {
        $fixture = New-ControllerFixture
        $fake = New-FakeService -Fixture $fixture
        $holder = @{ Fake = $fake }
        # The probe fails at start and passes from five minutes on, so only
        # the timer probe can list full; once listed, no timer probe follows.
        $fake.Service.ShouldStop = { param($Context) $null = $Context; $holder.Fake.Clock.Ms - $holder.Fake.StartMs -ge 1300000 }.GetNewClosure()
        $fake.SleepHook = { param($F) if ($F.Clock.Ms - $F.StartMs -ge 300000) { $F.FullReady = $true } }
        Add-MacFake -Fake $fake
        Get-IdleControllerState -Fixture $fixture -Prepare
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake -HostType $HostType)
        Assert-True ($fake.Log | Where-Object { $_ -match 'event=started .*journal=absent' }) 'fixture sanity: no journal exists'
        Assert-Equal -Expected '0,600000' -Actual (@($fake.ProbeAt) -join ',') 'one probe at start, one on the timer'
        Assert-Equal -Expected 'restart,full' -Actual (Get-IdleControllerState -Fixture $fixture)['scopes']
    }

    It 'ends a macOS step child at its bound through StopStep with the host type and the native calls' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-StepPlan -Fake $fake -Step 'install' -Spec @(@{ HangMs = 2500000; NoResult = $true })
        Add-MacFake -Fake $fake -Work @()
        $seen = [System.Collections.Generic.List[object]]::new()
        $inner = $fake.Service.StopStep
        $fake.Service.StopStep = { param($ProcessId, $HostType, $Native) $seen.Add(@($ProcessId, $HostType, $Native)); & $inner $ProcessId }.GetNewClosure()
        $native = $fake.Service.Native
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        $install = @($fake.Launches | Where-Object { $_.Step -eq 'install' })
        Assert-True ($install.Count -ge 1) 'fixture sanity: the install phase ran'
        Assert-True ($seen.Count -ge 1) 'the child that outlived its bound is ended'
        foreach ($call in $seen) {
            Assert-Equal -Expected 'host.macos.utm' -Actual $call[1]
            Assert-True ([object]::ReferenceEquals($call[2], $native)) 'StopStep gets the controller''s native calls, which reach root members'
        }
        Assert-True (@($fake.Log | Where-Object { $_ -match 'event=step-bound-reached ' }).Count -ge 1) 'the install child reached its bound'
    }

    It 'ends a macOS step child with the default StopStep through the tree that includes root members, and the other host types as before' {
        $fixture = New-ControllerFixture
        $context = New-HostUpdateControllerContext -ControllerRoot $fixture.ControllerRoot -Snapshot $fixture.Snapshot -Checkout $fixture.Checkout -HostType 'host.macos.utm'
        # Script scope: a mock body sees its own parameters, not a closure's
        # captures; not named Native, which the mock's parameter would shadow.
        $script:StopStepCalls = [System.Collections.Generic.List[string]]::new()
        $script:GivenNative = { param($FilePath, $ArgumentList, $TimeoutSeconds) $null = $FilePath, $ArgumentList, $TimeoutSeconds; @{ ExitCode = 0 } }
        Mock Stop-HostUpdateMacStepTree -ModuleName Test.HostUpdate { $script:StopStepCalls.Add("mac $ProcessId $([object]::ReferenceEquals($Native, $script:GivenNative))") }
        Mock Stop-YurunaProcessTree -ModuleName Test.HostUpdate { $script:StopStepCalls.Add("tree $ProcessId") }
        & $context.Service.StopStep 4100 'host.macos.utm' $script:GivenNative
        & $context.Service.StopStep 4200 'host.ubuntu.kvm' $script:GivenNative
        & $context.Service.StopStep 4300 'host.windows.hyper-v' $script:GivenNative
        Assert-Equal -Expected 'mac 4100 True,tree 4200,tree 4300' -Actual ($script:StopStepCalls -join ',')
    }

    It 'reads the macOS step tree before it ends it, signals root members through sudo, and ends only the test-account tree without a complete table: <Case>' -ForEach @(
        @{ Case = 'complete'; Complete = $true; Stopped = '4100'; Signals = 'sudo -n /bin/kill -TERM 4102' }
        @{ Case = 'incomplete'; Complete = $false; Stopped = '4100'; Signals = '' }
    ) {
        # Script scope: a mock body sees its own parameters, not a closure's captures.
        $script:TreeState = @{ Complete = $Complete; Rows = [System.Collections.Generic.List[object]]::new(); Stopped = [System.Collections.Generic.List[int]]::new() }
        $state = $script:TreeState
        foreach ($row in @(@(4100, 1, '501'), @(4101, 4100, '501'), @(4102, 4101, '0'), @(4200, 1, '0'))) {
            $state.Rows.Add([pscustomobject]@{ Pid = $row[0]; ParentPid = $row[1]; OwnerId = $row[2]; StartTimeUnixMs = [long](1700000000000 + $row[0]); Argv = $null; CommandLine = 'x' })
        }
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-YurunaProcessTable -ModuleName Test.HostUpdate { [pscustomobject]@{ Complete = $script:TreeState.Complete; Rows = @($script:TreeState.Rows) } }
        Mock Stop-YurunaProcessTree -ModuleName Test.HostUpdate {
            # The test account's tree ends; a root member stays.
            $script:TreeState.Stopped.Add($ProcessId)
            foreach ($id in @($ProcessId, 4101)) { foreach ($row in @($script:TreeState.Rows | Where-Object { $_.Pid -eq $id })) { $null = $script:TreeState.Rows.Remove($row) } }
        }
        $native = {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            $null = $TimeoutSeconds
            $calls.Add(((@($FilePath) + @($ArgumentList)) -join ' '))
            foreach ($row in @($state.Rows | Where-Object { $_.Pid -eq [int]$ArgumentList[-1] })) { $null = $state.Rows.Remove($row) }
            @{ ExitCode = 0; TimedOut = $false }
        }.GetNewClosure()
        & (Get-Module Test.HostUpdate) { param($N) Stop-HostUpdateMacStepTree -ProcessId 4100 -Native $N -Confirm:$false } $native
        Assert-Equal -Expected $Stopped -Actual ($state.Stopped -join ',')
        Assert-Equal -Expected $Signals -Actual ($calls -join ',') 'only the root descendant of the step is signaled through sudo'
    }

    It 'never probes while an update is claimed, and keeps the full scope the last state listed: <Case>' -ForEach @(
        @{ Case = 'macOS, listed'; HostType = 'host.macos.utm'; Seed = 'restart,full'; Scopes = 'restart,full'; Probes = '' }
        @{ Case = 'macOS, not listed'; HostType = 'host.macos.utm'; Seed = 'restart'; Scopes = 'restart'; Probes = '' }
        @{ Case = 'KVM probes as before'; HostType = 'host.ubuntu.kvm'; Seed = 'restart'; Scopes = 'restart,full'; Probes = '0' }
    ) {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        Enter-TestClaim -RequestId $id -Fixture $fixture
        [System.IO.File]::WriteAllText((Join-Path $fixture.Runtime 'host-controller.state.json'), (@{ schemaVersion = 1; scopes = $Seed } | ConvertTo-Json))
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-MacFake -Fake $fake
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake -HostType $HostType)
        Assert-Equal -Expected $Probes -Actual (@($fake.ProbeAt) -join ',')
        Assert-Equal -Expected $Scopes -Actual ($fake.SeenScopes -join ',') 'the continued update reads the scopes the controller published'
        Assert-Equal -Expected 'updated' -Actual (Get-TestRow -RequestId $id)['update']['verdict']
    }

    It 'never probes a host type whose declaration lacks the full scope' {
        $fixture = New-ControllerFixture
        $fake = New-FakeService -Fixture $fixture
        $holder = @{ Fake = $fake }
        $fake.Service.ShouldStop = { param($Context) $null = $Context; $holder.Fake.Clock.Ms - $holder.Fake.StartMs -ge 1300000 }.GetNewClosure()
        $fake.FullReady = $true
        $fake.Service.SupportedScope = { [string[]]@('restart') }
        Add-MacFake -Fake $fake
        Get-IdleControllerState -Fixture $fixture -Prepare
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected '' -Actual (@($fake.ProbeAt) -join ',') 'no probe at start nor every ten minutes'
        $state = Get-IdleControllerState -Fixture $fixture
        Assert-Equal -Expected 'restart' -Actual $state['scopes']
    }

    It 'runs install and enable on macOS, ending their processes before it removes the rule with the allowed rm, and calls no systemctl' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $work = @([pscustomobject]@{ ProcessId = 210; StartTimeUnixMs = 1; Kind = 'install'; Root = $true })
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-MacFake -Fake $fake -Work $work
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'updated' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'preflight,stop_runner,update_source,install,enable,start_listener,start_runner' -Actual (($fake.Launches | ForEach-Object { $_.Step }) -join ',')
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['elevation']
        Assert-Equal -Expected 2 -Actual $fake.WorkStops.Count 'the work found after each privileged phase is ended'
        Assert-Equal -Expected 210 -Actual @($fake.WorkStops[0])[0].ProcessId
        Assert-Equal -Expected "stop-elevated-work,$($script:MacRemove),stop-elevated-work,$($script:MacRemove)" -Actual ($fake.Native -join ',') 'the work is ended before the rule goes; only the allowed rm, once per privileged phase'
    }

    It 'ends on macOS the Enable run of the checkout it runs from, and leaves one of another checkout running' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-MacFake -Fake $fake
        # The context's own ElevatedWork reads this table.
        $null = $fake.Service.Remove('ElevatedWork')
        $pwsh = '/opt/homebrew/bin/pwsh'
        $own = [System.IO.Path]::Combine($fixture.Checkout, 'test', 'lab', 'Enable-TestAutomation.ps1')
        $other = [System.IO.Path]::Combine($fixture.Home, 'other', 'test', 'lab', 'Enable-TestAutomation.ps1')
        $table = [pscustomobject]@{
            Complete = $true
            Rows     = @(
                [pscustomobject]@{ Pid = 400; ParentPid = 1; StartTimeUnixMs = [long]1700000000400; OwnerId = 501; Argv = @($pwsh, '-File', $own, '-SkipPoolStorage', '-NoOperatorPrompt'); CommandLine = '' }
                [pscustomobject]@{ Pid = 500; ParentPid = 1; StartTimeUnixMs = [long]1700000000500; OwnerId = 501; Argv = @($pwsh, '-File', $other, '-SkipPoolStorage', '-NoOperatorPrompt'); CommandLine = '' }
            )
        }
        Mock Get-YurunaProcessTable -ModuleName Test.HostUpdate { $table }.GetNewClosure()
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected 'updated' -Actual (Get-TestRow -RequestId $id)['update']['verdict']
        Assert-Equal -Expected 2 -Actual $fake.WorkStops.Count 'the work is read after each privileged phase'
        Assert-Equal -Expected '400|400' -Actual ((@($fake.WorkStops) | ForEach-Object { (@($_) | ForEach-Object { $_.ProcessId }) -join ',' }) -join '|') `
            'only the Enable of the controller''s checkout is ended'
    }

    It 'keeps the elevation armed as debt on macOS when the process table cannot say what runs, and still removes the rule' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-MacFake -Fake $fake -Work $null
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected 'armed' -Actual (Get-TestObligation -RequestId $id)['elevation']
        Assert-Equal -Expected 0 -Actual $fake.WorkStops.Count
        Assert-Equal -Expected 2 -Actual @($fake.Native | Where-Object { $_ -ceq $script:MacRemove }).Count
        Assert-Equal -Expected 'remove_sudo_rule' -Actual (Get-TestPublicState -Fixture $fixture)['debt'][0]['action']
    }

    It 'restores after a failed install on macOS, ending its processes and removing the rule' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-StepPlan -Fake $fake -Step 'install' -Spec @(@{ Outcome = 'failed'; Reason = 'clt_missing'; Action = 'act_at_host' })
        Add-MacFake -Fake $fake -Work @([pscustomobject]@{ ProcessId = 200; StartTimeUnixMs = 1; Kind = 'install'; Root = $false })
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        $row = Get-TestRow -RequestId $id
        Assert-Equal -Expected 'failed_restored' -Actual $row['update']['verdict']
        Assert-Equal -Expected 'clt_missing' -Actual $row['update']['reason']
        Assert-Equal -Expected 'discharged' -Actual (Get-TestObligation -RequestId $id)['elevation']
        Assert-True ($fake.WorkStops.Count -ge 1)
        Assert-Equal -Expected 0 -Actual @($fake.Native | Where-Object { $_ -match 'systemctl' }).Count
    }

    It 'passes the macOS installer remarks through to the verdict' {
        $fixture = New-ControllerFixture
        Set-TestLaunchRecord -CleanExit $false
        $id = Add-TestUpdate -Fixture $fixture -Scope full
        $fake = New-FakeService -Fixture $fixture -ShouldStop (New-StopWhenTerminal -RequestId $id)
        $fake.FullReady = $true
        Add-StepPlan -Fake $fake -Step 'install' -Spec @(@{ Remarks = @('utm_upgrade_deferred', 'brew_update_failed') })
        Add-MacFake -Fake $fake
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake)
        Assert-Equal -Expected 'updated_with_remarks' -Actual (Get-TestRow -RequestId $id)['update']['verdict']
        Assert-Equal -Expected 'utm_upgrade_deferred,brew_update_failed' -Actual (@((Get-TestPublicState -Fixture $fixture)['remarks']) -join ',')
    }

    It 'publishes the macOS session it runs in and whether it can start a runner: <Case>' -ForEach @(
        @{ Case = 'tmux, usable'; Tmux = '/tmp/tmux-501/yuruna-controller,1,0'; Sty = $null; Reading = @{ Usable = $true }; Session = 'tmux'; Usable = $true; Logged = $false }
        @{ Case = 'screen, a grant denied'; Tmux = $null; Sty = '4242.yuruna-controller'; Reading = @{ Usable = $false }; Session = 'screen'; Usable = $false; Logged = $false }
        @{ Case = 'a terminal, no reading'; Tmux = $null; Sty = $null; Reading = $null; Session = 'terminal'; Usable = $true; Logged = $true }
    ) {
        $saved = Save-YurunaTestEnvironment -Name 'TMUX', 'STY'
        try {
            if ($Tmux) { $env:TMUX = $Tmux } else { Remove-Item -LiteralPath Env:TMUX -ErrorAction SilentlyContinue }
            if ($Sty) { $env:STY = $Sty } else { Remove-Item -LiteralPath Env:STY -ErrorAction SilentlyContinue }
            $fixture = New-ControllerFixture
            $fake = New-FakeService -Fixture $fixture -ShouldStop { $true }
            Add-MacFake -Fake $fake
            $seen = [System.Collections.Generic.List[object]]::new()
            $fake.Service.SessionProbe = { param($HostType, $SnapshotRoot, $Native) $null = $Native; $seen.Add(@($HostType, $SnapshotRoot)); $Reading }.GetNewClosure()
            $context = New-MacTestContext -Fixture $fixture -Fake $fake
            Get-IdleControllerState -Fixture $fixture -Prepare
            $null = Invoke-HostUpdateController -Context $context
            $state = Get-IdleControllerState -Fixture $fixture
            Assert-Equal -Expected $Session -Actual $state['session']
            Assert-Equal -Expected $Usable -Actual $state['sessionUsable']
            Assert-Equal -Expected 1 -Actual $seen.Count 'the session is probed once, at start'
            Assert-Equal -Expected 'host.macos.utm' -Actual $seen[0][0]
            Assert-Equal -Expected $context.SnapshotRoot -Actual $seen[0][1] 'the probe runs from the snapshot'
            Assert-Equal -Expected $Logged -Actual ([bool]($fake.Log | Where-Object { $_ -match 'event=session-probe-unread' }))
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
    }

    It 'keeps system-unit and a usable session off macOS without probing it' {
        $fixture = New-ControllerFixture
        $fake = New-FakeService -Fixture $fixture -ShouldStop { $true }
        Add-MacFake -Fake $fake -Usable $false
        Get-IdleControllerState -Fixture $fixture -Prepare
        $null = Invoke-HostUpdateController -Context (New-MacTestContext -Fixture $fixture -Fake $fake -HostType 'host.ubuntu.kvm')
        $state = Get-IdleControllerState -Fixture $fixture
        Assert-Equal -Expected 'system-unit' -Actual $state['session']
        Assert-True ([bool]$state['sessionUsable'])
    }

    It 'reads the macOS session in a bounded child pwsh that imports from the snapshot: <Case>' -ForEach @(
        @{ Case = 'a reading'; Out = "noise`n{`"SessionKind`":`"Aqua`",`"Ssh`":false,`"Grants`":{},`"Usable`":false}`n"; Exit = 0; TimedOut = $false; Usable = $false }
        @{ Case = 'a timeout'; Out = ''; Exit = 124; TimedOut = $true; Usable = $null }
        @{ Case = 'no JSON'; Out = 'oops'; Exit = 0; TimedOut = $false; Usable = $null }
    ) {
        $calls = [System.Collections.Generic.List[object]]::new()
        $native = { param($FilePath, $ArgumentList, $TimeoutSeconds) $calls.Add(@($FilePath, $ArgumentList, $TimeoutSeconds)); @{ ExitCode = $Exit; TimedOut = $TimedOut; StdOut = $Out } }.GetNewClosure()
        $root = Join-Path $script:ScratchBase "snap'shot"
        $reading = Invoke-HostUpdateMacSessionProbe -SnapshotRoot $root -Native $native
        if ($null -eq $Usable) { Assert-Null $reading } else { Assert-Equal -Expected $Usable -Actual $reading['Usable'] }
        Assert-Equal -Expected 30 -Actual $calls[0][2]
        Assert-Equal -Expected '-NoLogo,-NoProfile,-NonInteractive,-Command' -Actual ((@($calls[0][1]) | Select-Object -First 4) -join ',')
        $command = [string]@($calls[0][1])[4]
        Assert-True ($command.Contains(("'" + (Join-Path $root 'test/modules/Test.HostCondition.Mac.psm1').Replace("'", "''") + "'"))) $command
        Assert-True ($command.Contains('Get-HostUpdateMacSessionReading'))
    }

    It 'reads a macOS session as usable only in the desktop session, without SSH, and with no blocking grant denied: <Case>' -ForEach @(
        @{ Case = 'granted'; Kind = 'Aqua'; Ssh = $false; Grants = @(@{ Id = 'Accessibility'; Blocking = $true; State = 'granted' }); Usable = $true }
        @{ Case = 'unknown is not missing'; Kind = 'Aqua'; Ssh = $false; Grants = @(@{ Id = 'UtmAppData'; Blocking = $true; State = 'unknown' }); Usable = $true }
        @{ Case = 'a blocking grant denied'; Kind = 'Aqua'; Ssh = $false; Grants = @(@{ Id = 'ScreenRecording'; Blocking = $true; State = 'denied' }); Usable = $false }
        @{ Case = 'a grant that does not block denied'; Kind = 'Aqua'; Ssh = $false; Grants = @(@{ Id = 'Other'; Blocking = $false; State = 'denied' }); Usable = $true }
        @{ Case = 'SSH'; Kind = 'Aqua'; Ssh = $true; Grants = @(); Usable = $false }
        @{ Case = 'not the desktop session'; Kind = 'Remote'; Ssh = $false; Grants = @(); Usable = $false }
        @{ Case = 'unknown session'; Kind = 'Unknown'; Ssh = $false; Grants = @(); Usable = $false }
    ) {
        $states = @($Grants | ForEach-Object { [pscustomobject]$_ }) + @([pscustomobject]@{ Id = 'AutomationUtm'; Blocking = $false; State = 'unprobed' })
        $reading = Get-HostUpdateMacSessionReading -Service @{ SessionKind = { $Kind }.GetNewClosure(); SshSession = { $Ssh }.GetNewClosure(); GrantState = { $states }.GetNewClosure() }
        Assert-Equal -Expected $Usable -Actual $reading.Usable
        Assert-Equal -Expected $Kind -Actual $reading.SessionKind
        Assert-Equal -Expected $Ssh -Actual $reading.Ssh
        Assert-False ($reading.Grants.Contains('AutomationUtm')) 'a grant with no silent probe is not read'
        foreach ($grant in $Grants) { Assert-Equal -Expected $grant.State -Actual $reading.Grants[$grant.Id] }
    }
}

Describe 'macOS: the controller session a runner start starts' {
    BeforeAll {
        $script:SessionMarker = 'YURUNA_SESSION_TEST_MARKER'
        function New-SessionFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a scratch controller root and in-memory services.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Captured by the closure it returns.')]
            param([switch]$NoShim, [switch]$NoCurrent, [string]$Kind = 'tmux', [string[]]$Lock = @('free', 'held'), [hashtable]$Exit = @{}, [hashtable]$Out = @{}, [string[]]$TimedOut = @(),
                [string]$SessionKind = 'Aqua', [bool]$Ssh = $false)
            $fixture = New-ControllerFixture
            # The module's own name for the deployed shim: shim.ps1 on a
            # Windows host that runs this suite, shim elsewhere.
            $shim = Get-HostUpdateControllerShimPath
            if (-not $NoShim) { [System.IO.File]::WriteAllText($shim, "#!/bin/sh`n") }
            # A shim without `current` loops looking for a checkout, so a session
            # started then never takes the lock.
            if ($NoCurrent) {
                $current = [System.IO.Path]::Combine($fixture.ControllerRoot, 'current')
                Assert-True ([System.IO.File]::Exists($current)) 'fixture sanity: the controller fixture records current'
                [System.IO.File]::Delete($current)
            }
            $record = @{ Calls = [System.Collections.Generic.List[string]]::new(); Removed = [System.Collections.Generic.List[object]]::new(); Sleeps = 0; LockReads = 0 }
            $path = if ($Kind -eq 'tmux') { '/opt/homebrew/bin/tmux' } elseif ($Kind -eq 'screen') { '/usr/bin/screen' } else { $null }
            $record.Service = @{
                LockState          = { $index = [Math]::Min($record.LockReads, $Lock.Count - 1); $record.LockReads++; $Lock[$index] }.GetNewClosure()
                Sleep              = { param($Milliseconds) $null = $Milliseconds; $record.Sleeps++ }.GetNewClosure()
                SessionKind        = { $SessionKind }.GetNewClosure()
                SshSession         = { $Ssh }.GetNewClosure()
                ResolveMultiplexer = { if ($path) { @{ Kind = $Kind; Path = $path } } else { $null } }.GetNewClosure()
                FindTool           = { param($Name) if ($Name -eq $Kind) { $path } else { $null } }.GetNewClosure()
                Native             = {
                    param($FilePath, $ArgumentList, $TimeoutSeconds, $RemoveEnvironmentVariable)
                    $line = (@($FilePath) + @($ArgumentList)) -join ' '
                    $record.Calls.Add("$line ($TimeoutSeconds s)")
                    $record.Removed.Add(@($RemoveEnvironmentVariable))
                    $code = 0
                    foreach ($pattern in @($Exit.Keys)) { if ($line -like $pattern) { $code = [int]$Exit[$pattern] } }
                    $text = ''
                    foreach ($pattern in @($Out.Keys)) { if ($line -like $pattern) { $text = [string]$Out[$pattern] } }
                    $late = @($TimedOut | Where-Object { $line -like $_ }).Count -gt 0
                    if ($late) { $code = 124 }
                    @{ ExitCode = $code; TimedOut = $late; Started = $true; StdOut = $text; StdErr = '' }
                }.GetNewClosure()
            }
            $record.Fixture = $fixture
            $record.Shim = $shim
            $record
        }
        function Get-SessionLine {
            param([Parameter(Mandatory)][string]$Result, [hashtable]$Arguments = @{})
            & (Get-Module Test.HostUpdate) { param($k, $a) Format-YurunaOperatorMessage -Key $k -Arguments $a } "runner.host_controller_start_$Result" $Arguments
        }
        $script:TmuxAttach = 'tmux -L yuruna-controller attach -t yuruna-controller'
    }

    It 'starts nothing and reports <Result> when <Case>' -ForEach @(
        @{ Case = 'nothing is deployed'; Result = 'not_deployed'; Setup = @{ NoShim = $true } }
        @{ Case = 'no current is recorded'; Result = 'not_deployed'; Setup = @{ NoCurrent = $true } }
        @{ Case = 'the start comes over SSH'; Result = 'not_desktop_session'; Setup = @{ Ssh = $true } }
        @{ Case = 'the session is not the desktop'; Result = 'not_desktop_session'; Setup = @{ SessionKind = 'Remote' } }
        @{ Case = 'the session cannot be told'; Result = 'not_desktop_session'; Setup = @{ SessionKind = 'Unknown' } }
        @{ Case = 'a controller holds the lock'; Result = 'running'; Setup = @{ Lock = @('held') } }
        @{ Case = 'the lock cannot be read'; Result = 'lock_unreadable'; Setup = @{ Lock = @('unknown') } }
        @{ Case = 'there is no multiplexer'; Result = 'no_multiplexer'; Setup = @{ Kind = 'none' } }
    ) {
        $session = New-SessionFixture @Setup
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected $Result -Actual $start.Result
        Assert-Equal -Expected (Get-SessionLine -Result $Result) -Actual $start.Line
        Assert-Equal -Expected 0 -Actual $session.Calls.Count 'no multiplexer is asked'
    }

    It 'reports an existing <Kind> session and creates none' -ForEach @(
        @{ Kind = 'tmux'; Exit = @{}; Out = @{}; Attach = 'tmux -L yuruna-controller attach -t yuruna-controller' }
        @{ Kind = 'screen'; Exit = @{ '/usr/bin/screen -ls' = 1 }; Out = @{ '/usr/bin/screen -ls' = "There is a screen on:`n`t4242.yuruna-controller`t(Detached)`n1 Socket in /tmp/screens/S-ytest.`n" }; Attach = 'screen -r yuruna-controller' }
    ) {
        $session = New-SessionFixture -Kind $Kind -Exit $Exit -Out $Out
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'session_exists' -Actual $start.Result
        Assert-Equal -Expected $Kind -Actual $start.Multiplexer
        Assert-Equal -Expected (Get-SessionLine -Result 'session_exists' -Arguments @{ multiplexer = $Kind; attach = $Attach }) -Actual $start.Line
        Assert-Equal -Expected 1 -Actual $session.Calls.Count ($session.Calls -join ' | ')
        if ($Kind -eq 'tmux') { Assert-Equal -Expected '/opt/homebrew/bin/tmux -L yuruna-controller -f /dev/null has-session -t =yuruna-controller (5 s)' -Actual $session.Calls[0] }
    }

    It 'reports session_unknown when tmux does not answer whether the session exists' {
        $session = New-SessionFixture -TimedOut @('* has-session *')
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'session_unknown' -Actual $start.Result
        Assert-Equal -Expected 1 -Actual $session.Calls.Count 'nothing is created'
    }

    It 'creates the tmux session on its own socket with no runner YURUNA or multiplexer variable, keeps the operator overrides, and waits for the lock' {
        $saved = Save-YurunaTestEnvironment -Name $script:SessionMarker, 'YURUNA_RUNTIME_DIR', 'YURUNA_SKIP_SCREEN_RECORDING_CHECK'
        try {
            Set-Item -LiteralPath "Env:$($script:SessionMarker)" -Value 'leak'
            $env:YURUNA_RUNTIME_DIR = '/tmp/runner-runtime'
            $env:YURUNA_SKIP_SCREEN_RECORDING_CHECK = '1'
            $session = New-SessionFixture -Exit @{ '* has-session *' = 1 } -Lock @('free', 'free', 'free', 'held')
            $start = Start-HostUpdateControllerSession -Service $session.Service
            Assert-Equal -Expected 'started' -Actual $start.Result
            Assert-Equal -Expected 'held' -Actual $start.LockState
            Assert-Equal -Expected 'tmux' -Actual $start.Multiplexer
            Assert-Equal -Expected (Get-SessionLine -Result 'started' -Arguments @{ multiplexer = 'tmux'; attach = $script:TmuxAttach }) -Actual $start.Line
            Assert-Equal -Expected "/opt/homebrew/bin/tmux -L yuruna-controller -f /dev/null new-session -d -s yuruna-controller /bin/sh $($session.Shim) (5 s)" -Actual $session.Calls[1]
            $removed = @($session.Removed[1])
            foreach ($name in @($script:SessionMarker, 'YURUNA_RUNTIME_DIR', 'TMUX', 'TMUX_PANE', 'STY', 'WINDOW')) { Assert-True ($removed -ccontains $name) "$name is removed" }
            Assert-False ($removed -ccontains 'YURUNA_SKIP_SCREEN_RECORDING_CHECK') 'a documented operator override reaches the controller'
            Assert-Equal -Expected 0 -Actual @($removed | Where-Object { $_ -notlike 'YURUNA_*' -and $_ -cnotin @('TMUX', 'TMUX_PANE', 'STY', 'WINDOW') }).Count 'nothing else is removed'
            Assert-Equal -Expected 2 -Actual $session.Sleeps 'the lock is polled every 500 ms until it is held'
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
    }

    It 'creates the screen session detached from the bounded call''s pipes, and ignores a dead entry' {
        $session = New-SessionFixture -Kind screen -Exit @{ '/usr/bin/screen -ls' = 1 } -Out @{ '/usr/bin/screen -ls' = "There is a screen on:`n`t4242.yuruna-controller`t(Dead ???)`n" }
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'started' -Actual $start.Result
        Assert-Equal -Expected "/bin/sh -c exec `"`$@`" </dev/null >/dev/null 2>&1 sh /usr/bin/screen -c /dev/null -dmS yuruna-controller /bin/sh $($session.Shim) (5 s)" -Actual $session.Calls[1]
        Assert-Equal -Expected (Get-SessionLine -Result 'started' -Arguments @{ multiplexer = 'screen'; attach = 'screen -r yuruna-controller' }) -Actual $start.Line
    }

    It 'reports not_held after twenty polls when no controller takes the lock' {
        $session = New-SessionFixture -Exit @{ '* has-session *' = 1 } -Lock @('free')
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'not_held' -Actual $start.Result
        Assert-Equal -Expected 20 -Actual $session.Sleeps
        Assert-Equal -Expected (Get-SessionLine -Result 'not_held' -Arguments @{ multiplexer = 'tmux'; attach = $script:TmuxAttach }) -Actual $start.Line
    }

    It 'reads a create that fails while the session exists as session_exists: two starts at the same moment' {
        $session = New-SessionFixture -Exit @{ '* new-session *' = 1 }
        $probe = @{ Count = 0 }
        $inner = $session.Service.Native
        $session.Service.Native = {
            param($FilePath, $ArgumentList, $TimeoutSeconds, $RemoveEnvironmentVariable)
            $r = & $inner $FilePath $ArgumentList $TimeoutSeconds $RemoveEnvironmentVariable
            # No session at the first look; the other start's exists at the second.
            if (@($ArgumentList) -contains 'has-session') { $probe.Count++; $r.ExitCode = if ($probe.Count -eq 1) { 1 } else { 0 } }
            $r
        }.GetNewClosure()
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'session_exists' -Actual $start.Result
        Assert-Equal -Expected 3 -Actual $session.Calls.Count ($session.Calls -join ' | ')
    }

    It 'reports start_failed when the create times out and no session exists' {
        $session = New-SessionFixture -Exit @{ '* has-session *' = 1 } -TimedOut @('* new-session *')
        $start = Start-HostUpdateControllerSession -Service $session.Service
        Assert-Equal -Expected 'start_failed' -Actual $start.Result
        Assert-Equal -Expected (Get-SessionLine -Result 'start_failed' -Arguments @{ multiplexer = 'tmux' }) -Actual $start.Line
        Assert-Equal -Expected 0 -Actual $session.Sleeps 'no lock watch after a failed create'
    }

    It 'creates the session through the bounded call, whose child sees none of the removed variables (stand-in tmux)' -Skip:$IsWindows {
        $saved = Save-YurunaTestEnvironment -Name $script:SessionMarker, 'TMUX', 'STY', 'YURUNA_SKIP_SCREEN_RECORDING_CHECK'
        try {
            Set-Item -LiteralPath "Env:$($script:SessionMarker)" -Value 'leak'
            $env:YURUNA_SKIP_SCREEN_RECORDING_CHECK = '1'
            $env:TMUX = '/tmp/tmux-501/default,1,0'
            $env:STY = '1.other'
            $session = New-SessionFixture
            $bin = Join-Path $session.Fixture.Home 'bin'
            $null = New-Item -ItemType Directory -Path $bin -Force
            $rec = Join-Path $session.Fixture.Home 'tmux.rec'
            $tmux = Join-Path $bin 'tmux'
            [System.IO.File]::WriteAllText($tmux, "#!/bin/sh`ncase `" `$* `" in *' has-session '*) exit 1 ;; esac`nprintf '%s\n' `"`$*`" > '$rec'`nenv >> '$rec'`nexit 0`n")
            & chmod 755 $tmux
            $session.Service.Remove('Native')
            $session.Service.ResolveMultiplexer = { @{ Kind = 'tmux'; Path = $tmux } }.GetNewClosure()
            $start = Start-HostUpdateControllerSession -Service $session.Service
            Assert-Equal -Expected 'started' -Actual $start.Result
            $lines = Get-Content -LiteralPath $rec
            Assert-Equal -Expected "-L yuruna-controller -f /dev/null new-session -d -s yuruna-controller /bin/sh $($session.Shim)" -Actual $lines[0]
            Assert-Equal -Expected 0 -Actual @($lines | Select-Object -Skip 1 | Where-Object { ($_ -like 'YURUNA_*' -and $_ -notlike 'YURUNA_SKIP_*') -or $_ -like 'TMUX=*' -or $_ -like 'STY=*' }).Count ($lines -join ' | ')
            Assert-Equal -Expected 1 -Actual @($lines | Where-Object { $_ -ceq 'YURUNA_SKIP_SCREEN_RECORDING_CHECK=1' }).Count 'the operator override reaches the session'
            Assert-True (@($lines | Where-Object { $_ -like 'PATH=*' }).Count -eq 1) 'the rest of the environment is kept'
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
        }
    }

    It 'ends the <Kind> session: <Case>' -ForEach @(
        @{ Case = 'tmux has one'; Kind = 'tmux'; Exit = @{}; Out = @{}; Reason = 'ended'; Ended = $true
            Calls = '/opt/homebrew/bin/tmux -L yuruna-controller -f /dev/null has-session -t =yuruna-controller (5 s) | /opt/homebrew/bin/tmux -L yuruna-controller -f /dev/null kill-session -t =yuruna-controller (10 s)' }
        @{ Case = 'tmux has none'; Kind = 'tmux'; Exit = @{ '* has-session *' = 1 }; Out = @{}; Reason = 'absent'; Ended = $true
            Calls = '/opt/homebrew/bin/tmux -L yuruna-controller -f /dev/null has-session -t =yuruna-controller (5 s)' }
        @{ Case = 'tmux cannot kill it'; Kind = 'tmux'; Exit = @{ '* kill-session *' = 1 }; Out = @{}; Reason = 'failed'; Ended = $false; Calls = $null }
        @{ Case = 'screen has two and a dead one'; Kind = 'screen'; Exit = @{ '* -ls' = 1 }
            Out = @{ '* -ls' = "There are screens on:`n`t4242.yuruna-controller`t(Detached)`n`t4243.yuruna-controller`t(Detached)`n`t4244.yuruna-controller`t(Dead ???)`n`t5.other`t(Detached)`n" }
            Reason = 'ended'; Ended = $true
            Calls = '/usr/bin/screen -ls (5 s) | /usr/bin/screen -S 4242.yuruna-controller -X quit (10 s) | /usr/bin/screen -S 4243.yuruna-controller -X quit (10 s)' }
        @{ Case = 'screen has none'; Kind = 'screen'; Exit = @{ '* -ls' = 1 }; Out = @{ '* -ls' = "No Sockets found in /tmp/screens/S-ytest.`n" }; Reason = 'absent'; Ended = $true
            Calls = '/usr/bin/screen -ls (5 s)' }
    ) {
        $session = New-SessionFixture -Kind $Kind -Exit $Exit -Out $Out
        $stop = Stop-HostUpdateControllerSession -Service $session.Service -Confirm:$false
        Assert-Equal -Expected $Reason -Actual $stop.Reason
        Assert-Equal -Expected $Ended -Actual $stop.Ended
        if ($Calls) { Assert-Equal -Expected $Calls -Actual ($session.Calls -join ' | ') }
    }

    It 'ends nothing under -WhatIf' {
        $session = New-SessionFixture
        $stop = Stop-HostUpdateControllerSession -Service $session.Service -WhatIf
        Assert-Equal -Expected 'preview' -Actual $stop.Reason
        Assert-Equal -Expected 0 -Actual $session.Calls.Count
    }

    It 'verifies a macOS deployment without a definition: <Case>' -ForEach @(
        @{ Case = 'ready'; Expected = 'ready' }
        @{ Case = 'no shim'; Expected = 'shim-missing' }
        @{ Case = 'another shim'; Expected = 'shim-differs' }
        @{ Case = 'current names no snapshot'; Expected = 'current-missing' }
    ) {
        $fixture = New-ControllerFixture
        $source = Join-Path $fixture.Checkout 'test/lab/yuruna-host-controller-shim.sh'
        [System.IO.File]::WriteAllText($source, "#!/bin/sh`n# shim`n")
        $shimName = if ($IsWindows) { 'shim.ps1' } else { 'shim' }
        if ($IsWindows) { $source = Join-Path $fixture.Checkout 'test/lab/yuruna-host-controller-shim.ps1'; [System.IO.File]::WriteAllText($source, "# shim`n") }
        $deployed = Join-Path $fixture.ControllerRoot $shimName
        switch ($Expected) {
            'ready' { Copy-Item -LiteralPath $source -Destination $deployed }
            'shim-differs' { [System.IO.File]::WriteAllText($deployed, "#!/bin/sh`n# older`n") }
            'current-missing' {
                Copy-Item -LiteralPath $source -Destination $deployed
                $null = Write-HostUpdateControllerCurrent -ControllerRoot $fixture.ControllerRoot -Current '0123456789abcdef' -Previous '' -Checkout $fixture.Checkout -Confirm:$false
            }
        }
        Assert-Equal -Expected $Expected -Actual (Test-HostUpdateControllerDeployment -RepoRoot $fixture.Checkout -NoDefinition)
        if ($Expected -eq 'ready') {
            Assert-Equal -Expected 'definition-missing' -Actual (Test-HostUpdateControllerDeployment -RepoRoot $fixture.Checkout -Definition 'x' -InstalledDefinition $null) 'the definition form is unchanged'
        }
    }
}
