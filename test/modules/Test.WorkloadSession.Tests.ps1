<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42faa836-16da-4910-b038-e5e248e152f1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload session pester
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
    Pester guard on Test.WorkloadSession.psm1 and the runtime it drives: the
    worker side of the workload MCP server.
.DESCRIPTION
    A workload session runs authored steps against an attached VM through the
    real sequence engine, journals them, keeps registered secrets out of every
    file and result it hands back, owns the runtime with the one-shot lease,
    replays sequences as nested children, and turns a screen into references a
    client can point at. A session that ran a step differently from a replayed
    sequence, dispatched a refused verb, leaked a registered value into its
    journal or a result, left a lease or a replay child behind, or answered an
    earlier snapshot's reference would hand an author a sequence that fails
    when it is replayed, or a secret, with every other check green.

    The file is filled by three parts. The executor, validation, journal and
    secret cases compare an operation with a replay of the same primitives
    through the engine. The ownership, replay and saving cases run the real
    lease and a stand-in replay child that records how it was started. The
    screen surface cases run the real snapshot, matcher and phrase library with
    only the capture and OCR engines stubbed, and the reply-line cases lift the
    functions of the worker shell that frame what crosses the pipe.

    No case needs a VM, a hypervisor or a browser. Cases that start a replay
    child or a sleeper end them before they finish.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The worker modules set environment entries of their own
    # (YURUNA_SECRET_FILTER, YURUNA_NONINTERACTIVE, YURUNA_CONFIG_PATH,
    # YURUNA_CYCLE_GENERATION), so the whole environment is saved and restored.
    $script:SavedEnvironment = Save-YurunaTestEnvironment -All
    # The private state root and the runner gate resolve under $HOME; a scratch
    # home keeps this suite and every process it starts off the operator's own.
    $script:TestHome = Enter-YurunaTestHome

    $script:Root = New-YurunaTestTempDir -Prefix 'yrn-workload'
    foreach ($folder in @('status/runtime', 'status/log', 'sequences', 'session')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Root $folder) -Force
    }
    Set-Content -LiteralPath (Join-Path $script:Root 'test.config.yml') -Value 'testCycle: {}' -Encoding ascii
    $env:YURUNA_RUNTIME_DIR = Join-Path $script:Root 'status/runtime'
    $env:YURUNA_LOG_DIR = Join-Path $script:Root 'status/log'

    Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadProtocol.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.WorkloadSession.psm1') -Force -Global -DisableNameChecking
    # The engine loads once, in the order the worker uses, with the planner
    # after the engine. No block of this file imports the engine, the planner
    # or the prelude again, and none initializes the verb registry.
    $script:EnginePaths = Import-WorkloadEngineModule -ConfigPath (Join-Path $script:Root 'test.config.yml')
    $script:SessionCount = 0
    $script:HostPathCount = 0

    function Initialize-WorkloadTestSession {
        <#
        .SYNOPSIS
            Prepares one case: an attached fixture session, its worker state,
            its variable table, the mask sink and the two fixture verbs.
        .DESCRIPTION
            The session is a plain hashtable, because an ordered one is copied
            when it binds to a [hashtable] parameter and the keys the functions
            set would be lost. The call to Initialize-WorkloadVariableScope is
            the first for the new session, so it enables the secret filter and,
            given -Sequence, runs the chain resolver. The two fixture verbs
            share one handler that records what it saw and obeys the fixture
            fields of its step.
        #>
        param(
            [System.Collections.IDictionary]$Variables = ([ordered]@{ username = 'u1'; loginUser = 'u1' }),
            [string]$Sequence = ''
        )
        Clear-SequenceSecret
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:Events = [System.Collections.Generic.List[object]]::new()
        $script:ProgressSeen = [System.Collections.Generic.List[object]]::new()
        $script:Contexts = [System.Collections.Generic.List[object]]::new()
        $script:MaskAnswer = $true
        # The loop variable is not named $value: Send-WorkloadMask and
        # Register-SequenceSecret take -Value.
        Register-WorkloadMaskSink -ScriptBlock { param($Values) foreach ($maskValue in $Values) { $script:Order.Add("mask:$maskValue") }; $script:MaskAnswer }
        $script:SessionCount++
        $folder = Join-Path (Join-Path $script:Root 'session') ('case-{0:D4}' -f $script:SessionCount)
        $null = New-Item -ItemType Directory -Path $folder -Force
        $script:Session = @{ HostType = 'host.fixture'; GuestKey = 'guest.fixture'; OsKey = 'fixture'; VMName = 'never-a-real-vm'; Folder = $folder
            RepoRoot = $script:Root; SequencesDir = (Join-Path $script:Root 'sequences'); SourceSequence = ''
            SourceSequencePath = ''; State = 'attached'; DetachReason = '' }
        $script:Worker = @{ Session = $script:Session
            Screen = @{ Table = $null; Boxes = @(); Counter = 0; Ordinal = 0 }
            Page = @{ Table = $null; Counter = 0; Ordinal = 0 }
            PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = $null; MaskId = 0 }
        $script:Session.SurfaceState = @{ Screen = $script:Worker.Screen; Page = $script:Worker.Page }
        $scopeArguments = @{ Session = $script:Session; Variables = $Variables }
        if ($Sequence) { $scopeArguments.Sequence = $Sequence }
        $answer = Initialize-WorkloadVariableScope @scopeArguments
        if ($null -ne $answer) { throw "The fixture variable scope was refused: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)" }

        # A closure cannot read this file's $script: variables, so the handler
        # captures the lists of this case as locals.
        $order = $script:Order
        $contexts = $script:Contexts
        $handler = {
            param([hashtable]$Context)
            $order.Add('handler')
            $varsCopy = [ordered]@{}
            if ($Context.Vars -is [System.Collections.IDictionary]) {
                foreach ($key in @($Context.Vars.Keys)) { $varsCopy[$key] = $Context.Vars[$key] }
            }
            $contexts.Add([ordered]@{ StepNum = $Context.StepNum; StepCount = $Context.StepCount; SequencePath = $Context.SequencePath
                    VMName = $Context.VMName; Vars = $varsCopy })
            $fixtureStep = $Context.Step
            if ($fixtureStep.say) {
                Write-Information -MessageData ([string]$fixtureStep.say)
                Write-Warning -Message ([string]$fixtureStep.say)
                Write-Debug -Message ([string]$fixtureStep.say) -Debug
            }
            if ($fixtureStep.ocrTail) { (Get-SequenceFailureState).WaitForTextOcrTail = [string]$fixtureStep.ocrTail }
            if ($fixtureStep.phase) { (Get-SequenceFailureState).StepFailurePhase = [string]$fixtureStep.phase }
            if ($fixtureStep.noEffect) { Set-StepEffectNoneProven -Context $Context -Source 'address-unresolved' }
            if ($fixtureStep.rename) { $Context.NewVMName = [string]$fixtureStep.rename }
            if ($fixtureStep.run) { $null = & $fixtureStep.run }
            if ($fixtureStep.throwNow) { throw 'the fixture handler threw' }
            if ($fixtureStep.returnText) { return 'fixture text' }
            if ($fixtureStep.fail) { return $false }
            return $true
        }.GetNewClosure()
        Register-SequenceAction -Name 'workloadObserve' -Handler $handler -ReplaySafety 'observe' -CapturesOwnFailureScreenshot $true
        Register-SequenceAction -Name 'workloadInput' -Handler $handler -ReplaySafety 'input' -CapturesOwnFailureScreenshot $true
    }

    function Get-WorkloadTestCall {
        <#
        .SYNOPSIS
            The call object the worker shell hands a handler, for the session
            and worker state of the current case.
        #>
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Params,
            [scriptblock]$ShouldStop = { $false }
        )
        return @{ Id = 'r1'; Method = ''; Params = $Params; SessionId = 'test'; SessionDir = $script:Session.Folder; RefBase = 0; ConfigPath = ''
            Worker = $script:Worker; ShouldStop = $ShouldStop
            Progress = { param($Completed, $Total, $Label) $script:ProgressSeen.Add(@($Completed, $Total, $Label)) } }
    }

    # Runs the same primitives the way a saved sequence runs. A case runs the
    # workload operation first and then this block, because each run deletes
    # the other's last_failure.json.
    $script:Replay = {
        param([object[]]$Steps)
        $script:ReplaySteps = [object[]]$Steps
        $replayPath = Join-Path $script:Root 'sequences/replay-fixture.yml'
        # Invoke-Sequence returns $false when its -SequencePath does not exist.
        Set-Content -LiteralPath $replayPath -Value 'fixture: mocked parser' -Encoding ascii
        # A mock body cannot see this block's parameter, hence the script variable.
        Mock Read-SequenceFile -ModuleName Test.SequenceEngine {
            @{ description = 'replay'; steps = $script:ReplaySteps; variables = [ordered]@{ username = 'u1'; loginUser = 'u1' } }
        }
        $script:Events.Clear()
        $null = Invoke-Sequence -HostType host.fixture -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $replayPath
        $recordPath = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
        $record = $null
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            $record = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $recordPath -Raw) -AsHashtable -DateKind String
        }
        return @{ Events = @($script:Events); Record = $record }
    }

    # The projection of a run that an operation and its replay must share.
    $script:Compare = {
        param($Run)
        $steps = @(foreach ($eventRecord in @($Run.Events)) {
                if ([string]$eventRecord['event'] -eq 'step_end') { [ordered]@{ actionVerb = $eventRecord['actionVerb']; ok = $eventRecord['ok'] } }
            })
        $record = $null
        if ($null -ne $Run.Record) {
            $record = [ordered]@{}
            foreach ($field in @('reason', 'failureClass', 'classificationSource', 'actionVerb', 'stepNumber', 'totalSteps', 'stepEffect',
                    'innerFailureClass', 'action', 'description')) {
                $record[$field] = $Run.Record[$field]
            }
        }
        return [ordered]@{ steps = $steps; record = $record }
    }

    # The stand-in replay child. Get-WorkloadTestHostPath copies it to
    # <TestRoot>/Debug-TestSequence.ps1, the default -ScriptPath of a replay.
    # It reads its instructions only from standin.json beside itself.
    $script:StandInPath = Join-Path $script:Root 'standin.Debug-TestSequence.ps1'
    $standInText = @'
#requires -version 7
# Stand-in for test/Debug-TestSequence.ps1, written by Test.WorkloadSession.Tests.ps1.
# It records how the worker started it and plays the outcome standin.json names.
param(
    [Parameter(Mandatory = $true)][string]$SequenceName,
    [int]$StartStep = 1,
    [int]$StopStep = 0,
    [string]$ConfigPath = $null,
    [string]$VMName = $null,
    [string]$GuestKey = $null,
    [switch]$ShowSensitive,
    [switch]$NoConfigGate,
    [switch]$NoStatusService,
    [switch]$NoProjectClone,
    [string]$logLevel
)
$ErrorActionPreference = 'Stop'
$instructions = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'standin.json'))) -AsHashtable -DateKind String
$modulesDir = [string]$instructions['modulesDir']
$context = $null
if ($env:YURUNA_CYCLE_CONTEXT) { $context = ConvertFrom-Json -InputObject $env:YURUNA_CYCLE_CONTEXT -AsHashtable -DateKind String }
$nodeId = $SequenceName
if ($null -ne $context) {
    Import-Module (Join-Path $modulesDir 'Test.Status.psm1') -DisableNameChecking
    $parentId = [string]$context['parentId']
    $nodeId = "$parentId/$SequenceName"
    Register-NestedRunNode -StatusPath ([string]$context['statusPath']) -NodeId $nodeId -ParentId $parentId -Name $SequenceName `
        -Kind guest -CycleStartUtc ([string]$context['cycleStartUtc']) -Confirm:$false
}
Import-Module (Join-Path $modulesDir 'Test.SingleInstance.psm1') -DisableNameChecking
$bound = [ordered]@{}
foreach ($key in @($PSBoundParameters.Keys)) {
    $bound[$key] = if ($PSBoundParameters[$key] -is [switch]) { [bool]$PSBoundParameters[$key] } else { [string]$PSBoundParameters[$key] }
}
$environment = [ordered]@{}
foreach ($entry in @(Get-ChildItem -Path Env: | Where-Object { $_.Name -like 'YURUNA_*' } | Sort-Object Name)) { $environment[$entry.Name] = [string]$entry.Value }
$lease = Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR
$record = [ordered]@{ commandLine = @([Environment]::GetCommandLineArgs()); bound = $bound; environment = $environment
    leaseState = [string]$lease.State; pid = $PID }
# Written under a temporary name and moved, so a reader never sees half a file.
$outPath = Join-Path $PSScriptRoot 'standin.out.json'
[IO.File]::WriteAllText("$outPath.tmp", (ConvertTo-Json -InputObject $record -Depth 6))
Move-Item -LiteralPath "$outPath.tmp" -Destination $outPath -Force

if ($instructions['failureOcrTail'] -and $null -ne $context) {
    $rootFolder = [string]$context['rootCycleFolder']
    if (-not (Test-Path -LiteralPath $rootFolder)) {
        $flipped = if ($rootFolder -match '\.incomplete$') { $rootFolder -replace '\.incomplete$', '' } else { "$rootFolder.incomplete" }
        if (Test-Path -LiteralPath $flipped) { $rootFolder = $flipped }
    }
    $nestedFolder = Join-Path (Join-Path $rootFolder 'nested') ($nodeId -replace '[^A-Za-z0-9._-]', '_')
    $null = New-Item -ItemType Directory -Path $nestedFolder -Force
    $failure = [ordered]@{ reason = 'step-failed'; failureClass = 'wait_timeout'; actionVerb = 'waitForText'; stepNumber = 1; totalSteps = 1
        context = [ordered]@{ causeDetail = [ordered]@{ ocrTail = [string]$instructions['failureOcrTail'] } } }
    [IO.File]::WriteAllText((Join-Path $nestedFolder 'last_failure.json'), (ConvertTo-Json -InputObject $failure -Depth 6))
}

if ($instructions['startSleeper']) {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60')) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.Environment['NO_COLOR'] = '1'
    $sleeper = [Diagnostics.Process]::Start($info)
    $sleeperRecord = [ordered]@{ pid = $sleeper.Id; startTicks = $sleeper.StartTime.ToUniversalTime().Ticks }
    $sleeperPath = Join-Path $PSScriptRoot 'sleeper.json'
    [IO.File]::WriteAllText("$sleeperPath.tmp", (ConvertTo-Json -InputObject $sleeperRecord))
    Move-Item -LiteralPath "$sleeperPath.tmp" -Destination $sleeperPath -Force
}

$sleepSeconds = [int]$instructions['sleepSeconds']
if ($sleepSeconds -gt 0) { Start-Sleep -Seconds $sleepSeconds }

$sidecar = $env:YURUNA_SEQUENCE_COMPLETION_SIDECAR
$recordKind = [string]$instructions['record']
if ($sidecar -and $recordKind -ne 'missing') {
    if ($recordKind -eq 'unreadable') {
        [IO.File]::WriteAllText($sidecar, 'this is not JSON')
    } else {
        $invocationId = if ($recordKind -eq 'mismatch') { [guid]::NewGuid().ToString('N') } else { [string]$env:YURUNA_SEQUENCE_INVOCATION_ID }
        $completion = [ordered]@{ schema = 'yuruna.sequence-completion/v1'; invocationId = $invocationId
            outcome = [string]$instructions['recordOutcome']; finishedVmName = [string]$instructions['finishedVmName'] }
        [IO.File]::WriteAllText($sidecar, (ConvertTo-Json -InputObject $completion))
    }
}
exit ([int]$instructions['exitCode'])
'@
    Set-Content -LiteralPath $script:StandInPath -Value $standInText -Encoding ascii -NoNewline

    function Get-WorkloadTestHostPath {
        <#
        .SYNOPSIS
            Makes the TestRoot and RepoRoot of one case and returns its path
            bundle.
        .DESCRIPTION
            The folder holds copies of the start and workload sequences of
            guest.ubuntu.server.24 with the snippet library they use (with no
            ancestor folder holding test/sequences, the reader looks for the
            snippets only beside the sequence), an empty guest folder of the
            KVM host, the status folders, a test.config.yml and the stand-in
            replay child named Debug-TestSequence.ps1.
        #>
        $script:HostPathCount++
        $testRoot = Join-Path $script:Root ('host-{0:D4}' -f $script:HostPathCount)
        $sequencesDir = Join-Path $testRoot 'sequences'
        $statusDir = Join-Path $testRoot 'status'
        foreach ($folder in @($sequencesDir, (Join-Path $testRoot 'host/ubuntu.kvm/guest.ubuntu.server.24'), (Join-Path $statusDir 'runtime'),
                (Join-Path $statusDir 'log'))) {
            $null = New-Item -ItemType Directory -Path $folder -Force
        }
        $frameworkSequences = Join-Path (Split-Path -Parent $PSScriptRoot) 'sequences'
        foreach ($fileName in @('start.guest.ubuntu.server.24.yml', 'workload.guest.ubuntu.server.24.yml', '_snippets.yml')) {
            Copy-Item -LiteralPath (Join-Path $frameworkSequences $fileName) -Destination (Join-Path $sequencesDir $fileName)
        }
        $configPath = Join-Path $testRoot 'test.config.yml'
        Set-Content -LiteralPath $configPath -Value 'testCycle: {}' -Encoding ascii
        Copy-Item -LiteralPath $script:StandInPath -Destination (Join-Path $testRoot 'Debug-TestSequence.ps1')
        return [ordered]@{ TestRoot = $testRoot; RepoRoot = $testRoot; ModulesDir = $PSScriptRoot; SequencesDir = $sequencesDir
            StatusDir = $statusDir; ConfigPath = $configPath }
    }

    # The engine import leaves the functions of this host's driver in the
    # global scope; a global function defined after it wins over them, also for
    # a call made inside a module, so no block of the file reaches a
    # hypervisor through these two names. A block that reads a VM state or a
    # VM list sets $script:VmState in its own BeforeEach.
    $script:VmState = @{}
    function global:Get-VMState {
        <#
        .SYNOPSIS
            Fixture VM state: the entry of $script:VmState, absent otherwise.
        #>
        param([string]$VMName)
        if ($script:VmState.ContainsKey($VMName)) { return [string]$script:VmState[$VMName] }
        return 'absent'
    }
    function global:Get-VMName {
        <#
        .SYNOPSIS
            Fixture VM list: the names $script:VmState holds, sorted.
        #>
        return @($script:VmState.Keys | Sort-Object)
    }

    function Use-WorkloadTestScreen {
        <#
        .SYNOPSIS
            Sets $script:ScreenBoxes to the word boxes of the given screen lines.
        .DESCRIPTION
            Line k (from 1) has block 1, par 1, line k, y = 32 * (k - 1) and
            h 16; its words, split on spaces, are 8 pixels per character wide
            with 8 pixels between them, starting at x 0, with word counting
            from 1 and conf 96. The loop variables are named unlike the
            parameter, because names ignore case.
        #>
        param([Parameter(Mandatory)][string[]]$Line)
        $boxes = [System.Collections.Generic.List[object]]::new()
        $lineNumber = 0
        foreach ($lineText in $Line) {
            $lineNumber++
            $x = 0
            $wordNumber = 0
            foreach ($wordText in ($lineText -split ' ')) {
                $wordNumber++
                $boxes.Add(@{ text = $wordText; x = $x; y = 32 * ($lineNumber - 1); w = 8 * $wordText.Length; h = 16; conf = 96
                        block = 1; par = 1; line = $lineNumber; word = $wordNumber })
                $x += 8 * $wordText.Length + 8
            }
        }
        $script:ScreenBoxes = $boxes.ToArray()
    }
}

AfterAll {
    Register-WorkloadMaskSink -ScriptBlock $null
    Clear-SequenceSecret
    Disable-SequenceSecretFilter
    Remove-Item -LiteralPath function:\Get-VMState, function:\Get-VMName -ErrorAction SilentlyContinue
    Exit-YurunaTestHome $script:TestHome
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment -RemoveOthers
    Remove-YurunaTestTempDir $script:Root
}

Describe 'a session operation runs its primitives as a replayed sequence runs them' {
    BeforeAll {
        function Get-WorkloadTestPrimitive {
            <#
            .SYNOPSIS
                One fixture primitive of a sentence: a fixture verb with a description,
                a fromStep and the fixture fields of the case.
            #>
            param(
                [ValidateSet('workloadObserve', 'workloadInput')][string]$Verb = 'workloadObserve',
                [System.Collections.IDictionary]$Field = @{},
                [string]$FromStep = 'look around'
            )
            $primitive = [ordered]@{ action = $Verb; description = "Fixture $Verb"; fromStep = $FromStep }
            foreach ($key in @($Field.Keys)) { $primitive[[string]$key] = $Field[$key] }
            return $primitive
        }

        function Invoke-WorkloadTestStep {
            <#
            .SYNOPSIS
                Runs one step.run operation whose sentence the mocked resolver turns
                into the given primitives (a fresh copy of each per call).
            #>
            param(
                [Parameter(Mandatory)][string]$OperationId,
                [Parameter(Mandatory)][object[]]$Primitive,
                [string]$Sentence = 'look around',
                [string]$Intent = 'Run the fixture step',
                [scriptblock]$ShouldStop = { $false }
            )
            $script:FixtureSteps = $Primitive
            Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession {
                foreach ($fixtureStep in $script:FixtureSteps) {
                    $copy = [ordered]@{}
                    foreach ($key in @($fixtureStep.Keys)) { $copy[$key] = $fixtureStep[$key] }
                    $copy
                }
            }
            $params = [ordered]@{ operationId = $OperationId; step = $Sentence; intent = $Intent }
            return (Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params $params -ShouldStop $ShouldStop))
        }

        function Invoke-WorkloadTestAction {
            <#
            .SYNOPSIS
                Runs one action.run operation of a registered verb.
            #>
            param(
                [Parameter(Mandatory)][string]$OperationId,
                [Parameter(Mandatory)][string]$Verb,
                [System.Collections.IDictionary]$Field = ([ordered]@{}),
                [string]$Intent = 'Run the fixture action'
            )
            $params = [ordered]@{ operationId = $OperationId; action = $Verb; fields = $Field; intent = $Intent }
            return (Invoke-WorkloadActionRequest -Call (Get-WorkloadTestCall -Params $params))
        }

        function Read-WorkloadTestFailureRecord {
            <#
            .SYNOPSIS
                last_failure.json of the log folder, or $null when there is none.
            #>
            $recordPath = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
            if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
            return (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $recordPath -Raw) -AsHashtable -DateKind String)
        }

        function Test-WorkloadTestSameProjection {
            <#
            .SYNOPSIS
                Whether an operation and its replay project to the same text, and the two texts.
            #>
            param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)]$ReplayRun)
            $left = ConvertTo-Json -InputObject (& $script:Compare $Operation) -Depth 6 -Compress
            $right = ConvertTo-Json -InputObject (& $script:Compare $ReplayRun) -Depth 6 -Compress
            return @{ Same = [string]::Equals($left, $right, [StringComparison]::Ordinal); Left = $left; Right = $right }
        }

        function New-WorkloadTestBareSession {
            <#
            .SYNOPSIS
                The fixture session literal with its own folder and no Journal key, for
                a case whose first variable call is expected to be refused.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates the folder of one case session under the suite temp root.')]
            param()
            $script:SessionCount++
            $folder = Join-Path (Join-Path $script:Root 'session') ('bare-{0:D4}' -f $script:SessionCount)
            $null = New-Item -ItemType Directory -Path $folder -Force
            return @{ HostType = 'host.fixture'; GuestKey = 'guest.fixture'; OsKey = 'fixture'; VMName = 'never-a-real-vm'; Folder = $folder
                RepoRoot = $script:Root; SequencesDir = (Join-Path $script:Root 'sequences'); SourceSequence = ''
                SourceSequencePath = ''; State = 'attached'; DetachReason = '' }
        }

        $script:SecretVariables = [ordered]@{ username = 'u1'; loginUser = 'u1'; pass = 'S3cr3t-fixture' }
    }

    BeforeEach {
        Initialize-WorkloadTestSession
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:Events.Add($EventRecord) }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Save-WorkloadScreenSnapshot -ModuleName Test.WorkloadSession { [ordered]@{ ok = $true; file = 'screen-0001.txt' } }
        Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession { $null }
    }

    Context 'the executor' {
        It 'runs a passing list with the step events a replayed sequence produces' {
            $make = { @((Get-WorkloadTestPrimitive -Verb workloadObserve), (Get-WorkloadTestPrimitive -Verb workloadInput)) }
            $script:Events.Clear()
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive (& $make)
            $operation = @{ Events = @($script:Events); Record = (Read-WorkloadTestFailureRecord) }
            Assert-Equal 'succeeded' $result.state
            $replayRun = & $script:Replay (& $make)
            $projection = Test-WorkloadTestSameProjection -Operation $operation -ReplayRun $replayRun
            Assert-True $projection.Same "operation $($projection.Left) differs from replay $($projection.Right)"
            Assert-Equal 2 @((& $script:Compare $operation).steps).Count 'two step_end events'
            Assert-Null (& $script:Compare $operation).record
        }

        It 'fails a throwing handler as replay does' {
            $make = { @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ throwNow = $true }) }
            $script:Events.Clear()
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive (& $make)
            $operation = @{ Events = @($script:Events); Record = (Read-WorkloadTestFailureRecord) }
            Assert-Equal 'failed' $result.state
            Assert-NotNull $operation.Record 'the operation wrote a failure record'
            Assert-True ([string]$operation.Record['classificationSource'] -ceq 'handler-exception') "classificationSource was $($operation.Record['classificationSource'])"
            Assert-True ([string]$operation.Record['failureClass'] -ceq 'unknown') "class was $($operation.Record['failureClass'])"
            $replayRun = & $script:Replay (& $make)
            $projection = Test-WorkloadTestSameProjection -Operation $operation -ReplayRun $replayRun
            Assert-True $projection.Same "operation $($projection.Left) differs from replay $($projection.Right)"
        }

        It 'fails a handler that returns a string as replay does' {
            $make = { @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ returnText = $true }) }
            $script:Events.Clear()
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive (& $make)
            $operation = @{ Events = @($script:Events); Record = (Read-WorkloadTestFailureRecord) }
            Assert-Equal 'failed' $result.state
            Assert-NotNull $operation.Record 'the operation wrote a failure record'
            $replayRun = & $script:Replay (& $make)
            $projection = Test-WorkloadTestSameProjection -Operation $operation -ReplayRun $replayRun
            Assert-True $projection.Same "operation $($projection.Left) differs from replay $($projection.Right)"
        }

        It 'runs a nested retry through the engine and keeps the inner class' {
            $make = {
                @([ordered]@{ action = 'retry'; maxAttempts = 1; description = 'Retry the fixture input'
                        steps = @([ordered]@{ action = 'workloadInput'; description = 'Fixture input'; fail = $true }) })
            }
            $script:Events.Clear()
            $script:Session.OperationSeq = 1
            $list = Invoke-WorkloadStepList -Session $script:Session -Steps (& $make) -Seq 1
            $operation = @{ Events = @($script:Events); Record = $list.Record }
            Assert-False $list.Ok 'the retry failed'
            Assert-NotNull $list.Record 'the operation kept the failure record of op-0001'
            Assert-True ([string]$list.Record['failureClass'] -ceq 'retry_exhausted') "class was $($list.Record['failureClass'])"
            $fixtureClass = [string](Get-SequenceAction -Name 'workloadInput').FailureClass
            Assert-True ([string]$list.Record['innerFailureClass'] -ceq $fixtureClass) "inner class was $($list.Record['innerFailureClass']), the fixture's is $fixtureClass"
            $replayRun = & $script:Replay (& $make)
            $projection = Test-WorkloadTestSameProjection -Operation $operation -ReplayRun $replayRun
            Assert-True $projection.Same "operation $($projection.Left) differs from replay $($projection.Right)"
        }

        It 'stops at the first failing primitive and counts the completed ones' {
            $primitives = @((Get-WorkloadTestPrimitive -Verb workloadInput), (Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true }),
                (Get-WorkloadTestPrimitive -Verb workloadInput))
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive $primitives
            Assert-Equal 'failed' $result.state
            Assert-Equal 1 $result.progress.completed
            Assert-Equal 3 $result.progress.total
            Assert-Equal 2 $result.progress.failedAt
            Assert-Equal 2 @($script:Order | Where-Object { $_ -ceq 'handler' }).Count 'the third primitive never ran'
            Assert-True ([string]$result.error.code -ceq 'workload_step_failed') "code was $($result.error.code)"
        }

        It 'reports the effect <Case>' -ForEach @(
            @{ Case = 'of observing primitives that pass'; Steps = @(@{ verb = 'workloadObserve' }, @{ verb = 'workloadObserve' }); Effect = 'none-proven' }
            @{ Case = 'of an input that passes'; Steps = @(@{ verb = 'workloadObserve' }, @{ verb = 'workloadInput' }); Effect = 'applied' }
            @{ Case = 'of a first observing primitive that fails'; Steps = @(@{ verb = 'workloadObserve'; fail = $true }, @{ verb = 'workloadInput' }); Effect = 'none-proven' }
            @{ Case = 'of an input before a failing observation'; Steps = @(@{ verb = 'workloadInput' }, @{ verb = 'workloadObserve'; fail = $true }); Effect = 'applied' }
            @{ Case = 'of an input that fails in its wait'; Steps = @(@{ verb = 'workloadInput'; fail = $true; phase = 'wait' }); Effect = 'none-proven' }
            @{ Case = 'of an input that fails'; Steps = @(@{ verb = 'workloadInput'; fail = $true }); Effect = 'uncertain' }
            @{ Case = 'that the handler proved unchanged'; Steps = @(@{ verb = 'workloadInput'; fail = $true; noEffect = $true }); Effect = 'none-proven' }
        ) {
            $primitives = @(foreach ($caseStep in $Steps) {
                    $fields = [ordered]@{}
                    foreach ($key in @($caseStep.Keys)) { if ($key -ne 'verb') { $fields[$key] = $caseStep[$key] } }
                    Get-WorkloadTestPrimitive -Verb $caseStep.verb -Field $fields
                })
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive $primitives
            Assert-True ([string]$result.effect -ceq $Effect) "effect was $($result.effect), expected $Effect"
        }

        # sshWaitReady stays an observation, so that replaying it in place
        # puts the step's password back; the rotation or set it runs is still a
        # change to the guest, and the operation has to say so.
        It 'reports the effect of an sshWaitReady <Case>' -ForEach @(
            @{ Case = 'that set the password'; Fields = $true; Expired = $false; Set = @{ Ok = $true; Code = ''; Detail = ''; Dispatched = $true }; Effect = 'applied'; State = 'succeeded' }
            @{ Case = 'that rotated the password'; Fields = $true; Expired = $true; Set = $null; Effect = 'applied'; State = 'succeeded' }
            @{ Case = 'whose set failed after the guest may have taken it'; Fields = $true; Expired = $false; Set = @{ Ok = $false; Code = 'chpasswd-failed'; Detail = ''; Dispatched = $true }; Effect = 'uncertain'; State = 'failed' }
            @{ Case = 'whose set sudo refused'; Fields = $true; Expired = $false; Set = @{ Ok = $false; Code = 'sudo-refused'; Detail = ''; Dispatched = $true }; Effect = 'none-proven'; State = 'failed' }
            @{ Case = 'without the password fields'; Fields = $false; Expired = $false; Set = $null; Effect = 'none-proven'; State = 'succeeded' }
        ) {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $script:SshSetAnswer = $Set
            $script:SshWaits = [System.Collections.Generic.Queue[bool]]::new()
            if ($Expired) { $script:SshWaits.Enqueue($false) }
            $script:SshWaits.Enqueue($true)
            Mock Wait-SshReady -ModuleName Test.SequenceHandler { $script:SshWaits.Dequeue() }
            Mock Get-LastSshReadiness -ModuleName Test.SequenceHandler { @{ cause = 'password_expired'; target = '192.0.2.10' } }
            Mock Get-GuestSshUser -ModuleName Test.SequenceHandler { 'u1' }
            Mock Set-GuestSshPassword -ModuleName Test.SequenceHandler { $script:SshSetAnswer }
            Mock Invoke-GuestSshPasswordRotation -ModuleName Test.SequenceHandler { @{ Ok = $true; Code = ''; Detail = ''; Answered = 3 } }
            $stepFields = [ordered]@{ timeoutSeconds = 30 }
            if ($Fields) { $stepFields.currentPassword = '${pass}'; $stepFields.newPassword = '${pass}' }
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'sshWaitReady' -Field $stepFields 3>$null 6>$null
            Assert-True ([string]$result.state -ceq $State) "state was $($result.state), expected $State; $(ConvertTo-Json -InputObject $result.error -Depth 4 -Compress)"
            Assert-True ([string]$result.effect -ceq $Effect) "effect was $($result.effect), expected $Effect"
            $expectedSets = if ($null -ne $Set) { 1 } else { 0 }
            Should -Invoke Set-GuestSshPassword -ModuleName Test.SequenceHandler -Times $expectedSets -Exactly
        }

        It 'does not restart the console viewer for an operation' {
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-Equal 'succeeded' $result.state
            Should -Invoke Restart-VMConsole -ModuleName Test.SequenceEngine -Times 0 -Exactly
        }

        It 'keeps the engine module instance across the first operation' {
            $before = Get-Module -Name Test.SequenceEngine
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $after = Get-Module -Name Test.SequenceEngine
            Assert-Equal 'succeeded' $result.state
            Assert-Equal 1 @($before).Count
            Assert-True ([object]::ReferenceEquals($before, $after)) 'the engine module was replaced by the operation'
        }

        It "cannot inherit the previous operation's failure label on a crash" {
            $first = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadObserve -Field @{ fail = $true }) -Intent 'Fail the first fixture step'
            Assert-Equal 'failed' $first.state
            $firstRecord = Read-WorkloadTestFailureRecord
            Assert-NotNull $firstRecord 'the first operation wrote a failure record'
            $earlierLabel = [string]$firstRecord['action']
            Assert-True ($earlierLabel.Length -gt 0) 'the first record names its action'
            Mock Resolve-YurunaOperatorProjectLabel -ModuleName Test.SequenceEngine { throw 'the label resolver crashed' }
            $second = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true }) -Intent 'Fail the second fixture step'
            Assert-Equal 'failed' $second.state
            $secondRecord = Read-WorkloadTestFailureRecord
            Assert-NotNull $secondRecord 'the crash wrote no failure record'
            Assert-False ([string]$secondRecord['action'] -ceq $earlierLabel) "the crash record carried the earlier label '$earlierLabel'"
            Assert-False ([string]$second.error.message).Contains($earlierLabel) "the answer names the earlier label '$earlierLabel'"
        }
    }

    Context 'variables of a session' {
        It 'resolves variables once for the session' {
            $script:ExtensionCount = 0
            Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { $script:ExtensionCount++; "fixture-next-$($script:ExtensionCount)" }
            Initialize-WorkloadTestSession -Variables ([ordered]@{ username = 'u1'; loginUser = 'u1'; nonce = '${ext:fixture.Next()}' })
            $null = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $null = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-Equal 2 $script:Contexts.Count
            Assert-True ([string]$script:Contexts[0].Vars['nonce'] -ceq 'fixture-next-1') "first operation saw $($script:Contexts[0].Vars['nonce'])"
            Assert-True ([string]$script:Contexts[1].Vars['nonce'] -ceq 'fixture-next-1') "second operation saw $($script:Contexts[1].Vars['nonce'])"
            Should -Invoke Invoke-ExtensionExpression -ModuleName Test.SequenceVariable -Times 1 -Exactly
        }

        It 'lets a client variable win over the chain value and keeps its position' {
            $script:ChainPath = Join-Path $script:Root 'sequences/chain-fixture.yml'
            Mock Resolve-NamedSequenceChain -ModuleName Test.WorkloadSession { @{ effectiveVariables = [ordered]@{ a = '1'; b = '2' } } }
            Initialize-WorkloadTestSession -Sequence $script:ChainPath -Variables ([ordered]@{ b = '3' })
            Assert-Equal 'a,b' (@($script:Session.RawVariables.Keys) -join ',')
            Assert-True ([string]$script:Session.RawVariables['b'] -ceq '3') "b was $($script:Session.RawVariables['b'])"
            Assert-True ([string]$script:Session.RawVariables['a'] -ceq '1') "a was $($script:Session.RawVariables['a'])"
            Should -Invoke Resolve-NamedSequenceChain -ModuleName Test.WorkloadSession -Times 1 -Exactly -ParameterFilter {
                $TopLevelPath -eq $script:ChainPath -and $SequenceName -ceq 'chain-fixture'
            }
        }

        It 'asks the chain resolver and never the planner that can remove a VM' {
            $script:ChainPath = Join-Path $script:Root 'sequences/chain-fixture.yml'
            Mock Resolve-TestSequencePlan -ModuleName Test.WorkloadSession { throw 'the planner must not run' }
            Mock Resolve-NamedSequenceChain -ModuleName Test.WorkloadSession { @{ effectiveVariables = [ordered]@{ a = '1'; b = '2' } } }
            Initialize-WorkloadTestSession -Sequence $script:ChainPath
            $first = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $second = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-Equal 'succeeded' $first.state
            Assert-Equal 'succeeded' $second.state
            Should -Invoke Resolve-NamedSequenceChain -ModuleName Test.WorkloadSession -Times 1 -Exactly
            Should -Invoke Resolve-TestSequencePlan -ModuleName Test.WorkloadSession -Times 0 -Exactly
        }

        It 'refuses a reserved client variable' {
            $bare = New-WorkloadTestBareSession
            $answer = Initialize-WorkloadVariableScope -Session $bare -Variables ([ordered]@{ username = 'u1'; loginUser = 'u1'; vmName = 'other-vm' })
            Assert-False $answer.ok
            Assert-True ([string]$answer.error.code -ceq 'workload_variable_reserved') "code was $($answer.error.code)"
        }

        It 'follows a client override of username into the SSH user' {
            Initialize-WorkloadTestSession -Variables ([ordered]@{ username = 'override-user'; loginUser = 'override-user' })
            Assert-True ([string](Get-GuestSshUser -GuestKey guest.fixture) -ceq 'override-user') "the SSH user was $(Get-GuestSshUser -GuestKey guest.fixture)"
        }

        It 'rebuilds the variables from RawVariables when called again' {
            $null = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $journal = $script:Session.Journal
            Assert-Equal 1 $journal.Count
            Assert-Equal 1 $script:Session.OperationSeq
            $script:Session.VMName = 'renamed'
            $answer = Initialize-WorkloadVariableScope -Session $script:Session
            Assert-Null $answer
            Assert-True ([string]$script:Session.Vars['vmName'] -ceq 'renamed') "vmName was $($script:Session.Vars['vmName'])"
            Assert-True ([object]::ReferenceEquals($journal, $script:Session.Journal)) 'the journal was replaced'
            Assert-Equal 1 $script:Session.Journal.Count
            Assert-Equal 1 $script:Session.OperationSeq
        }

        It 'refuses a client variable named like a secret that is not a reference' {
            $bare = New-WorkloadTestBareSession
            $answer = Initialize-WorkloadVariableScope -Session $bare -Variables ([ordered]@{ username = 'u1'; loginUser = 'u1'; dbPassword = 'hunter22' })
            Assert-False $answer.ok
            Assert-True ([string]$answer.error.code -ceq 'workload_secret_reference_required') "code was $($answer.error.code)"
            Assert-False (ConvertTo-Json -InputObject $answer -Depth 6).Contains('hunter22') 'the refusal echoes the value'
        }

        It 'follows a rename into the next operation' {
            $renamed = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Field @{ rename = 'renamed-vm' })
            Assert-True $renamed.renamed 'the first operation reports the rename'
            $null = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-True ([string]$script:Session.VMName -ceq 'renamed-vm') "the session names $($script:Session.VMName)"
            Assert-True ([string]$script:Session.Vars['vmName'] -ceq 'renamed-vm') "vmName is $($script:Session.Vars['vmName'])"
            Assert-True ([string]$script:Contexts[1].VMName -ceq 'renamed-vm') "the next handler saw $($script:Contexts[1].VMName)"
        }

        It 'gives two operations different detached-run tokens' {
            $null = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $null = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive)
            $tokens = @(foreach ($seen in $script:Contexts) {
                    Get-GuestRunToken -SequencePath ([string]$seen.SequencePath) -StepNumber ([int]$seen.StepNum) -VMName ([string]$seen.VMName)
                })
            Assert-Equal 2 $tokens.Count
            Assert-False ([string]::Equals($tokens[0], $tokens[1], [StringComparison]::Ordinal)) "both operations got the token $($tokens[0])"
        }
    }

    Context 'cancel and pause' {
        It 'cancels on a restart flag it did not write and leaves the flag' {
            $flag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
            Set-Content -LiteralPath $flag -Value 'another writer' -Encoding ascii
            try {
                $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadInput)
                Assert-Equal 'canceled' $result.state
                Assert-Equal 0 $result.progress.completed
                Assert-True ([string]$result.effect -ceq 'none-proven') "effect was $($result.effect)"
                Assert-True ([string]$result.error.code -ceq 'workload_operation_canceled') "code was $($result.error.code)"
                Assert-False ($script:Order -contains 'handler') 'a handler ran'
                $list = Invoke-WorkloadStepList -Session $script:Session -Steps @(Get-WorkloadTestPrimitive -Verb workloadInput) -Seq 99
                Assert-True $list.Canceled 'the direct run was not canceled'
                Assert-Equal 0 $list.Started
                Assert-True (Test-Path -LiteralPath $flag -PathType Leaf) 'the flag of another writer was removed'
            } finally {
                Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
            }
        }

        It 'stops before the next primitive when ShouldStop turns true and removes only its flag' {
            $flag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
            $order = $script:Order
            $stop = { $order.Contains('handler') }.GetNewClosure()
            $primitives = @((Get-WorkloadTestPrimitive -Verb workloadInput), (Get-WorkloadTestPrimitive -Verb workloadInput), (Get-WorkloadTestPrimitive -Verb workloadInput))
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive $primitives -ShouldStop $stop
            Assert-Equal 'canceled' $result.state
            Assert-Equal 'canceled' $result.outcome
            Assert-Equal 1 $result.progress.completed
            Assert-True ([string]$result.effect -ceq 'applied') "effect was $($result.effect)"
            Assert-Equal 1 @($script:Order | Where-Object { $_ -ceq 'handler' }).Count 'the second handler ran'
            Assert-False (Test-Path -LiteralPath $flag) 'the flag the call created was left behind'
        }

        It 'leaves a flag that another writer created while the list ran' {
            $script:RestartFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.cycle-restart'
            $order = $script:Order
            $stop = { $order.Contains('handler') }.GetNewClosure()
            try {
                $primitives = @((Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ run = { [IO.File]::WriteAllText($script:RestartFlag, 'other-writer') } }),
                    (Get-WorkloadTestPrimitive -Verb workloadInput), (Get-WorkloadTestPrimitive -Verb workloadInput))
                $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive $primitives -ShouldStop $stop
                Assert-Equal 'canceled' $result.state
                Assert-Equal 1 @($script:Order | Where-Object { $_ -ceq 'handler' }).Count 'the second handler ran'
                Assert-True (Test-Path -LiteralPath $script:RestartFlag -PathType Leaf) 'the flag of the other writer was removed'
                Assert-True ([IO.File]::ReadAllText($script:RestartFlag) -ceq 'other-writer') 'the flag of the other writer was rewritten'
            } finally {
                Remove-Item -LiteralPath $script:RestartFlag -Force -ErrorAction SilentlyContinue
            }
        }

        It 'holds an operation at the pause gate and runs it once when released' {
            $script:PauseFlag = Join-Path $env:YURUNA_RUNTIME_DIR 'control.step-pause'
            $script:CurrentActionFile = Join-Path $env:YURUNA_RUNTIME_DIR 'current-action.json'
            $script:SleepSeen = [System.Collections.Generic.List[object]]::new()
            Set-Content -LiteralPath $script:PauseFlag -Value 'hold' -Encoding ascii
            Mock Start-Sleep -ModuleName Test.SequenceEngine {
                $code = $null
                if (Test-Path -LiteralPath $script:CurrentActionFile -PathType Leaf) {
                    $code = [string](ConvertFrom-Json -InputObject (Get-Content -LiteralPath $script:CurrentActionFile -Raw) -AsHashtable)['code']
                }
                $script:SleepSeen.Add(@{ Handlers = @($script:Order | Where-Object { $_ -ceq 'handler' }).Count; Code = $code })
                Remove-Item -LiteralPath $script:PauseFlag -Force -ErrorAction SilentlyContinue
            }
            try {
                $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
                Assert-True ($script:SleepSeen.Count -ge 1) 'the gate never slept'
                Assert-Equal 0 $script:SleepSeen[0].Handlers 'the handler ran before the pause was released'
                Assert-True ([string]$script:SleepSeen[0].Code -ceq 'sequence_paused_waiting_resume') "current-action.json held $($script:SleepSeen[0].Code)"
                Assert-Equal 'succeeded' $result.state
                Assert-Equal 1 @($script:Order | Where-Object { $_ -ceq 'handler' }).Count
            } finally {
                Remove-Item -LiteralPath $script:PauseFlag -Force -ErrorAction SilentlyContinue
            }
        }

        It 'refuses an operation when the session is detached or no longer owns the runtime' {
            $script:RefusalCode = ''
            Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession {
                if (-not $script:RefusalCode) { return $null }
                return [ordered]@{ ok = $false; error = [ordered]@{ code = $script:RefusalCode; message = 'fixture refusal' } }
            }
            $known = Invoke-WorkloadTestStep -OperationId 'op-known' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-Equal 'succeeded' $known.state
            $handlersBefore = $script:Order.Count
            $seqBefore = [int]$script:Session.OperationSeq
            $journalBefore = $script:Session.Journal.Count
            foreach ($code in @('workload_session_detached', 'workload_ownership_lost')) {
                $script:RefusalCode = $code
                $result = Invoke-WorkloadTestStep -OperationId "op-$code" -Primitive @(Get-WorkloadTestPrimitive)
                Assert-False $result.ok
                Assert-Equal 'failed' $result.state
                Assert-False $result.dispatched
                Assert-True ([string]$result.effect -ceq 'none-proven') "effect was $($result.effect)"
                Assert-True ([string]$result.error.code -ceq $code) "code was $($result.error.code)"
            }
            Assert-Equal $handlersBefore $script:Order.Count 'a handler ran'
            Assert-Equal $seqBefore $script:Session.OperationSeq
            Assert-Equal $journalBefore $script:Session.Journal.Count
            Should -Invoke Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession -Times 3 -Exactly -ParameterFilter {
                $Tool -ceq 'workload_step' -and $NeedsVm -and $NeedsOwnership
            }
            $again = Invoke-WorkloadTestStep -OperationId 'op-known' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-True ([object]::ReferenceEquals($known, $again)) 'a known operation id was not answered from Results'
            Should -Invoke Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession -Times 3 -Exactly
        }
    }

    Context 'what a session may run' {
        It 'the verbs a session may run are exactly these' {
            Clear-SequenceAction -Confirm:$false
            Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Force -Global -DisableNameChecking
            $expected = @('callExtension', 'fetchAndExecute', 'inputText', 'inputTextAndEnter', 'networkRelease', 'passwdPrompt', 'pressKey',
                'saveGuestClockSnapshot', 'saveSystemDiagnostic', 'sshExec', 'sshFetchAndExecute', 'sshWaitReady', 'takeScreenshot', 'tapOn',
                'waitForAndEnter', 'waitForSeconds', 'waitForText', 'waitForTextWithNudge', 'webClick', 'webClose', 'webExpect', 'webFill',
                'webOpen', 'webPress', 'webSelect')
            $allowed = Get-WorkloadAllowedVerb
            Assert-True ([string]::Equals(($expected -join ','), ($allowed -join ','), [StringComparison]::Ordinal)) "allowed: $($allowed -join ',')"
        }

        It 'refuses <Verb> with <Code>' -ForEach @(
            @{ Verb = 'startVm'; Code = 'workload_verb_denied_vm_state' }
            @{ Verb = 'stopVm'; Code = 'workload_verb_denied_vm_state' }
            @{ Verb = 'saveDiskSnapshot'; Code = 'workload_verb_denied_vm_state' }
            @{ Verb = 'loadDiskSnapshot'; Code = 'workload_verb_denied_vm_state' }
            @{ Verb = 'recoverFromSnapshot'; Code = 'workload_verb_denied_vm_state' }
            @{ Verb = 'break'; Code = 'workload_verb_denied_operator_hold' }
            @{ Verb = 'retry'; Code = 'workload_verb_denied_composite' }
            @{ Verb = 'workloadUnclassified'; Code = 'workload_verb_denied_unclassified' }
            @{ Verb = 'typeAndEnter'; Code = 'workload_verb_alias' }
            @{ Verb = 'WAITFORTEXT'; Code = 'workload_verb_alias' }
            @{ Verb = 'noSuchVerb'; Code = 'workload_verb_unregistered' }
        ) {
            $order = $script:Order
            Register-SequenceAction -Name 'workloadUnclassified' -CapturesOwnFailureScreenshot $true -Handler ({ param([hashtable]$Context) $null = $Context; $order.Add('unclassified handler'); $true }.GetNewClosure())
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb $Verb
            Assert-False $result.ok
            Assert-False $result.dispatched
            Assert-True ([string]$result.error.code -ceq $Code) "code was $($result.error.code)"
            Assert-Match ([regex]::Escape($Verb)) ([string]$result.error.message) 'the message names the verb'
            Assert-Equal 0 $script:Order.Count 'a handler was invoked'
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'refuses a missing required field and names it' {
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'waitForText' -Field ([ordered]@{ timeoutSeconds = 5 })
            Assert-True ([string]$result.error.code -ceq 'workload_field_missing') "code was $($result.error.code)"
            Assert-Match 'pattern' ([string]$result.error.message)
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'refuses a field of the wrong type and names it' {
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'waitForText' -Field ([ordered]@{ pattern = 'x'; timeoutSeconds = 'ten' })
            Assert-True ([string]$result.error.code -ceq 'workload_field_invalid') "code was $($result.error.code)"
            Assert-Match 'timeoutSeconds' ([string]$result.error.message)
            Assert-Match 'integer' ([string]$result.error.message)
        }

        It 'refuses a reserved field' {
            foreach ($field in @('description', 'steps')) {
                $fields = [ordered]@{ seconds = 0 }
                $fields[$field] = 'reserved'
                $result = Invoke-WorkloadTestAction -OperationId "op-$field" -Verb 'waitForSeconds' -Field $fields
                Assert-True ([string]$result.error.code -ceq 'workload_field_reserved') "code for $field was $($result.error.code)"
                Assert-Match $field ([string]$result.error.message)
            }
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'runs with an undeclared field and warns' {
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'waitForSeconds' -Field ([ordered]@{ seconds = 0; timeoutSecond = 5 }) -Intent 'Wait a moment'
            Assert-Equal 'succeeded' $result.state
            Assert-Equal 1 @($result.warnings).Count
            Assert-True ([string]$result.warnings[0].code -ceq 'workload_field_undeclared') "warning was $($result.warnings[0].code)"
        }
    }

    Context 'secret input of a session' {
        It 'refuses a literal in a secret field' {
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'inputText' -Field ([ordered]@{ text = 'xxxx'; sensitive = $true })
            Assert-True ([string]$result.error.code -ceq 'workload_secret_reference_required') "code was $($result.error.code)"
            Assert-Equal 0 $script:Order.Count 'a handler ran'
        }

        It 'refuses passwdPrompt text that is more than one reference' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'passwdPrompt' -Field ([ordered]@{ pattern = 'Password:'; text = 'a${pass}' })
            Assert-True ([string]$result.error.code -ceq 'workload_secret_reference_required') "code was $($result.error.code)"
        }

        It 'refuses an sshWaitReady password that is not one reference, on <Field>' -TestCases @(
            @{ Field = 'currentPassword' }, @{ Field = 'newPassword' }
        ) {
            param($Field)
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $fields = [ordered]@{ currentPassword = '${pass}'; newPassword = '${pass}' }
            $fields[$Field] = 'Literal-fixture-1'
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'sshWaitReady' -Field $fields
            Assert-True ([string]$result.error.code -ceq 'workload_secret_reference_required') "code was $($result.error.code)"
            Assert-Match $Field ([string]$result.error.message) 'the refusal names the field'
            Assert-False (ConvertTo-Json -InputObject $result -Depth 6).Contains('Literal-fixture-1') 'the refusal holds the value'
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'treats the sshWaitReady password references as secret input and registers their variables' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $step = [ordered]@{ action = 'sshWaitReady'; currentPassword = '${pass}'; newPassword = '${ext:authentication.NewRandomPassword()}' }
            $answer = Test-WorkloadSecretInput -Session $script:Session -Tool workload_action -Steps @($step) -ClientText @()
            Assert-Null $answer.Refusal
            Assert-True $answer.SecretInput 'the password fields were not secret input'
            Assert-StringEqual -Expected 'pass' -Actual ($answer.SecretVariable -join ',')
        }

        It 'accepts the login sentence with a literal user name' {
            $library = Get-SequencePhraseLibrary
            $primitives = @(Resolve-StepPhrase -Sentence 'login admin with password ${ext:authentication.GetPassword(${username})}' -Surface screen -Library $library)
            Assert-True ($primitives.Count -gt 0) 'the starter library resolved nothing'
            $answer = Test-WorkloadSecretInput -Session $script:Session -Tool workload_step -Steps $primitives -ClientText @()
            Assert-Null $answer.Refusal
            Assert-True $answer.SecretInput 'the login sentence was not secret input'
        }

        It 'refuses a secret field naming an unknown variable' {
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'inputText' -Field ([ordered]@{ text = '${nope}'; sensitive = $true })
            Assert-True ([string]$result.error.code -ceq 'workload_secret_variable_unknown') "code was $($result.error.code)"
            Assert-Match 'nope' ([string]$result.error.message)
        }

        It 'treats an escaped token as a literal' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'inputText' -Field ([ordered]@{ text = '$${pass}'; sensitive = $true })
            Assert-True ([string]$result.error.code -ceq 'workload_secret_reference_required') "code was $($result.error.code)"
        }

        It 'refuses an intent with a variable token' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'inputText' -Field ([ordered]@{ text = 'a' }) -Intent 'Type ${pass}'
            Assert-True ([string]$result.error.code -ceq 'workload_intent_invalid') "code was $($result.error.code)"
            Assert-False (ConvertTo-Json -InputObject $result -Depth 6).Contains('S3cr3t-fixture') 'the refusal holds the value'
        }

        It 'refuses a request that repeats a registered value without echoing it' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $null = Register-SequenceSecret -Value 'S3cr3t-fixture' -Source 'fixture'
            $result = Invoke-WorkloadTestAction -OperationId 'op-1' -Verb 'inputText' -Field ([ordered]@{ text = 'S3cr3t-fixture' })
            Assert-True ([string]$result.error.code -ceq 'workload_secret_literal') "code was $($result.error.code)"
            Assert-False (ConvertTo-Json -InputObject $result -Depth 6).Contains('S3cr3t-fixture') 'the refusal holds the value'
            Assert-Equal 0 $script:Order.Where({ $_ -ceq 'handler' }).Count 'a handler ran'
        }

        It "registers a secret field's variable and masks it before dispatch" {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $script:SeenSecret = $null
            $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -Field ([ordered]@{ sensitive = $true; text = '${pass}'
                    run = { $script:SeenSecret = Test-SequenceSecretText -Text 'S3cr3t-fixture' } })
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence 'type secret ${pass} and press Enter'
            Assert-Equal 'succeeded' $result.state
            $maskAt = $script:Order.IndexOf('mask:S3cr3t-fixture')
            $handlerAt = $script:Order.IndexOf('handler')
            Assert-True ($maskAt -ge 0) "the value never reached the mask sink: $($script:Order -join ',')"
            Assert-True ($maskAt -lt $handlerAt) "the mask came after the handler: $($script:Order -join ',')"
            Assert-True $script:SeenSecret 'the handler did not see the value registered'
        }

        It 'refuses without dispatch when the mask is not confirmed' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $script:MaskAnswer = $false
            $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -Field ([ordered]@{ sensitive = $true; text = '${pass}' })
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence 'type secret ${pass} and press Enter'
            Assert-True ([string]$result.error.code -ceq 'workload_mask_failed') "code was $($result.error.code)"
            Assert-False ($script:Order -contains 'handler') 'a handler ran'
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'warns when a value registered during the run was not confirmed' {
            $primitive = Get-WorkloadTestPrimitive -Verb workloadObserve -Field ([ordered]@{
                    run = { $script:MaskAnswer = $false; $null = Register-SequenceSecret -Value 'late-value-1' } })
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive)
            Assert-Equal 'succeeded' $result.state
            $unconfirmed = @($result.warnings | Where-Object { [string]$_.code -ceq 'workload_mask_unconfirmed' })
            Assert-Equal 1 $unconfirmed.Count "warnings: $(ConvertTo-Json -InputObject $result.warnings -Depth 4 -Compress)"
        }

        It 'enters the sensitive state before dispatch and never leaves it' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $script:SeenSensitive = $null
            $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -Field ([ordered]@{ sensitive = $true; text = '${pass}'
                    run = { $script:SeenSensitive = [bool]$script:Session.SensitiveState } })
            $first = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence 'type secret ${pass} and press Enter'
            Assert-True $script:SeenSensitive 'the handler ran before the session was sensitive'
            Assert-True $first.sensitiveState
            $later = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-False $later.secretInput 'the later operation had no secret input'
            Assert-True $later.sensitiveState 'the later operation left the sensitive state'
        }

        It 'keeps a registered value out of the result, the session files and the failure view' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -FromStep 'type secret *** and press Enter' -Field ([ordered]@{
                    sensitive = $true; text = '${pass}'; say = 'said S3cr3t-fixture'; ocrTail = 'u1 login: S3cr3t-fixture'; fail = $true })
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence 'type secret ${pass} and press Enter'
            Assert-Equal 'failed' $result.state
            Assert-True ($script:Order -contains 'mask:S3cr3t-fixture') 'the value was never registered'
            Assert-False (ConvertTo-Json -InputObject $result -Depth 12).Contains('S3cr3t-fixture') 'the result holds the value'
            foreach ($fileName in @('journal.ndjson', 'engine.log', 'failure-0001.json')) {
                $filePath = Join-Path $script:Session.Folder $fileName
                Assert-True (Test-Path -LiteralPath $filePath -PathType Leaf) "$fileName was not written"
                Assert-False ([IO.File]::ReadAllText($filePath)).Contains('S3cr3t-fixture') "$fileName holds the value"
            }
            Assert-Match '\*\*\*' ([IO.File]::ReadAllText((Join-Path $script:Session.Folder 'engine.log'))) 'the said text did not reach engine.log masked'
            Assert-False (ConvertTo-Json -InputObject (Get-WorkloadJournalResult -Session $script:Session) -Depth 12).Contains('S3cr3t-fixture') 'the journal result holds the value'
            Assert-False (ConvertTo-Json -InputObject (Get-WorkloadFailureResult -Session $script:Session) -Depth 12).Contains('S3cr3t-fixture') 'the failure result holds the value'
        }

        It 'withholds the screenshot path in the sensitive state' {
            Initialize-WorkloadTestSession -Variables $script:SecretVariables
            $screenshot = Join-Path $env:YURUNA_LOG_DIR 'failure_screenshot_never-a-real-vm.png'
            try {
                [IO.File]::WriteAllBytes($screenshot, [byte[]](1, 2, 3))
                $before = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true })
                Assert-Equal 'failed' $before.state
                Assert-True ([string](Get-WorkloadFailureResult -Session $script:Session).failure.evidence.screenshot -ceq $screenshot) 'the screenshot was not listed before secret input'
                [IO.File]::WriteAllBytes($screenshot, [byte[]](1, 2, 3))
                $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -Field ([ordered]@{ sensitive = $true; text = '${pass}'; fail = $true })
                $after = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @($primitive) -Sentence 'type secret ${pass} and press Enter'
                Assert-Equal 'failed' $after.state
                Assert-True (Test-Path -LiteralPath $screenshot -PathType Leaf) 'the screenshot is gone, so its absence proves nothing'
                Assert-Null (Get-WorkloadFailureResult -Session $script:Session).failure.evidence.screenshot 'the screenshot was listed after secret input'
            } finally {
                Remove-Item -LiteralPath $screenshot -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'the journal and the failure view' {
        It 'journals a passing step once with its tokens intact' {
            Mock Invoke-ExtensionExpression -ModuleName Test.SequenceVariable { 'fixture-pass-1' }
            $sentence = 'login u1 with password ${ext:authentication.GetPassword(${username})}'
            $primitive = Get-WorkloadTestPrimitive -Verb workloadInput -Field ([ordered]@{ sensitive = $true; text = '${ext:authentication.GetPassword(${username})}' })
            $first = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence $sentence
            Assert-Equal 'succeeded' $first.state
            Assert-Equal 1 $script:Session.Journal.Count
            Assert-True ([string]$script:Session.Journal[0]['yaml']).Contains('${ext:authentication.GetPassword(${username})}') "yaml was $($script:Session.Journal[0]['yaml'])"
            $journalFile = Join-Path $script:Session.Folder 'journal.ndjson'
            Assert-Equal 1 @(Get-Content -LiteralPath $journalFile).Count
            $handlers = @($script:Order | Where-Object { $_ -ceq 'handler' }).Count
            $again = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @($primitive) -Sentence $sentence
            Assert-True ([object]::ReferenceEquals($first, $again)) 'the repeated id was not answered from the stored result'
            Assert-Equal $handlers @($script:Order | Where-Object { $_ -ceq 'handler' }).Count 'the repeated id invoked a handler'
            Assert-Equal 1 @(Get-Content -LiteralPath $journalFile).Count 'the repeated id added a line'
            Assert-Equal 1 $script:Session.Journal.Count
        }

        It 'journals a failed operation with its progress and effect and leaves it out of the runnable list' {
            $failed = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @((Get-WorkloadTestPrimitive -Verb workloadInput), (Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true }))
            Assert-Equal 'failed' $failed.state
            $entry = $script:Session.Journal[0]
            Assert-Equal 'failed' $entry['outcome']
            Assert-Equal 1 $entry['completedPrimitives']
            Assert-Equal 2 $entry['failedPrimitive']
            Assert-True ([string]$entry['effect'] -ceq 'applied') "effect was $($entry['effect'])"
            $observed = Invoke-WorkloadTestStep -OperationId 'op-2' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadObserve -Field @{ fail = $true })
            Assert-True ([string]$observed.effect -ceq 'none-proven') "effect was $($observed.effect)"
            Assert-Equal 0 @(Get-WorkloadJournalEntry -Session $script:Session -RunnableOnly).Count
            $journal = Get-WorkloadJournalResult -Session $script:Session
            Assert-Equal 0 $journal.steps
            $changes = @($journal.stateChanges)
            Assert-Equal 1 $changes.Count
            Assert-Equal 1 $changes[0].seq
            Assert-True ([string]$changes[0].effect -ceq 'applied') "effect was $($changes[0].effect)"
        }

        It 'serves the last failure through Get-WorkloadFailureResult' {
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true })
            Assert-Equal 'failed' $result.state
            $record = Read-WorkloadTestFailureRecord
            Assert-NotNull $record
            $served = Get-WorkloadFailureResult -Session $script:Session
            Assert-True $served.ok
            Assert-True ([string]$served.failure.failureClass -ceq [string]$record['failureClass']) "class was $($served.failure.failureClass)"
            Assert-True ([string]$served.failure.evidence.view -ceq (Join-Path $script:Session.Folder 'failure-0001.json')) "view was $($served.failure.evidence.view)"
        }

        It 'keeps the outcome when the snapshot after the action fails' {
            Mock Save-WorkloadScreenSnapshot -ModuleName Test.WorkloadSession { throw 'the capture failed' }
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-Equal 'succeeded' $result.state
            Assert-True ([string]$result.snapshotError -ceq 'workload_capture_failed') "snapshotError was $($result.snapshotError)"
            Assert-True $result.journaled
        }

        It 'answers through the handler names the shell maps' {
            $expected = 'ok,state,outcome,dispatched,operationId,seq,tool,ran,surface,snapshot,events,progress,primitives,effect,journaled,secretInput,sensitiveState,vmName,renamed,warnings,startedAtUtc,endedAtUtc'
            $step = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            $action = Invoke-WorkloadTestAction -OperationId 'op-2' -Verb 'waitForSeconds' -Field ([ordered]@{ seconds = 0 })
            foreach ($answer in @($step, $action)) {
                Assert-True ([string]::Equals($expected, (@($answer.Keys) -join ','), [StringComparison]::Ordinal)) "keys were $(@($answer.Keys) -join ',')"
                Assert-True $answer.ok
                Assert-Equal 'succeeded' $answer.state
                Assert-NotNull $answer.ran
                Assert-Equal 1 $answer.progress.total
                Assert-NotNull $answer.effect
            }
            $script:Worker.Session = $null
            $noStep = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-3'; step = 'look around'; intent = 'Look' }))
            $noAction = Invoke-WorkloadActionRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-4'; action = 'waitForSeconds'; fields = [ordered]@{ seconds = 0 }; intent = 'Wait' }))
            Assert-True ([string]$noStep.error.code -ceq 'workload_no_session') "step answered $($noStep.error.code)"
            Assert-True ([string]$noAction.error.code -ceq 'workload_no_session') "action answered $($noAction.error.code)"
        }

        It 'reports a crash record without cause detail' {
            $view = ConvertTo-WorkloadFailureView -Record ([ordered]@{ reason = 'crash'; failureClass = 'unknown' }) -Session $script:Session
            Assert-Null $view['stepFailurePhase']
            Assert-Null $view['fromStep']
            Assert-Null $view['ocrTail']
            Assert-True ([string]$view['reason'] -ceq 'crash')
        }

        It 'shows the sentence of a failed step in the failure view' {
            $record = [ordered]@{ reason = 'step-failed'; failureClass = 'wait_timeout'; actionVerb = 'inputText'; stepNumber = 1; totalSteps = 1
                transcriptPath = (Join-Path $env:YURUNA_LOG_DIR 'transcript.html'); screenshotPath = (Join-Path $env:YURUNA_LOG_DIR 'raw.png')
                context = [ordered]@{ stepFailurePhase = 'input'; fromStep = 'type secret *** and press Enter'; ocrTextPath = (Join-Path $env:YURUNA_LOG_DIR 'ocr.txt')
                    causeDetail = [ordered]@{ ocrTail = 'tail'; ocrFile = (Join-Path $env:YURUNA_LOG_DIR 'ocr-tail.txt') } } }
            $view = ConvertTo-WorkloadFailureView -Record $record -Session $script:Session
            $keys = @($view.Keys)
            $phaseAt = [array]::IndexOf($keys, 'stepFailurePhase')
            Assert-True ($phaseAt -ge 0) 'the view has no stepFailurePhase'
            Assert-Equal 'fromStep' $keys[$phaseAt + 1]
            Assert-True ([string]$view['fromStep'] -ceq 'type secret *** and press Enter') "fromStep was $($view['fromStep'])"
            Assert-Equal 'view,screenshot' (@($view['evidence'].Keys) -join ',')
            $withoutEvidence = [ordered]@{}
            foreach ($key in $keys) { if ($key -cne 'evidence') { $withoutEvidence[$key] = $view[$key] } }
            $text = ConvertTo-Json -InputObject $withoutEvidence -Depth 8
            foreach ($pathText in @($script:Root, $env:YURUNA_LOG_DIR, 'transcript.html', 'raw.png', 'ocr.txt', 'ocr-tail.txt')) {
                Assert-False $text.Contains($pathText) "the view names the path '$pathText'"
            }
        }

        It 'does not dispatch when the YAML does not read back equal' {
            Mock ConvertFrom-Yaml -ModuleName Test.WorkloadSession { , ([object[]]@([ordered]@{ step = 'a changed step'; on = 'screen'; description = 'Run the fixture step' })) }
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive)
            Assert-True ([string]$result.error.code -ceq 'workload_yaml_mismatch') "code was $($result.error.code)"
            Assert-False ($script:Order -contains 'handler') 'a handler ran'
            Assert-Equal 0 $script:Session.OperationSeq
        }

        It 'round-trips <Text> through the authored YAML' -ForEach @(
            @{ Text = 'yes' }, @{ Text = 'null' }, @{ Text = '123' }, @{ Text = '1e3' }, @{ Text = '' }, @{ Text = ' leading space' }
            @{ Text = "it's" }, @{ Text = 'say "hi"' }, @{ Text = 'a: b' }, @{ Text = '#x' }, @{ Text = "two`nlines" }
            @{ Text = '${ext:a.B(${c})}' }, @{ Text = '$$literal' }
        ) {
            $result = ConvertTo-WorkloadStepYaml -Step ([ordered]@{ action = 'inputText'; text = $Text; description = 'Type the fixture text' })
            Assert-Null $result.Refusal
            Assert-LocalizationYamlCodec
            $back = (ConvertFrom-Yaml -Ordered $result.Text)[0].text
            Assert-True ($back -is [string]) "the text read back as $($back.GetType().FullName)"
            Assert-True ([string]::Equals($Text, $back, [StringComparison]::Ordinal)) "read back '$back'"
        }

        It 'journals an operation whose handler threw after dispatch and lets the exception out' {
            Mock ConvertTo-WorkloadFailureView -ModuleName Test.WorkloadSession { throw 'view' }
            $seqBefore = [int]$script:Session.OperationSeq
            Assert-Throw { $null = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Verb workloadInput -Field @{ fail = $true }) }
            Assert-Equal ($seqBefore + 1) $script:Session.OperationSeq
            $entries = @($script:Session.Journal | Where-Object { [string]$_['operationId'] -ceq 'op-1' })
            Assert-Equal 1 $entries.Count
            Assert-Equal 'failed' $entries[0]['outcome']
            Assert-True ([string]$entries[0]['effect'] -ceq 'uncertain') "effect was $($entries[0]['effect'])"
            Assert-False $entries[0]['runnable']
            $changes = @((Get-WorkloadJournalResult -Session $script:Session).stateChanges)
            Assert-Equal 1 $changes.Count
            Assert-Equal ($seqBefore + 1) $changes[0].seq
        }

        It 'keeps running when a line of engine.log cannot be written' {
            $logPath = Join-Path $script:Session.Folder 'engine.log'
            if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Recurse -Force }
            $null = New-Item -ItemType Directory -Path $logPath
            $result = Invoke-WorkloadTestStep -OperationId 'op-1' -Primitive @(Get-WorkloadTestPrimitive -Field @{ say = 'hello from the fixture' })
            Assert-Equal 'succeeded' $result.state
            Assert-Equal 1 @($script:Order | Where-Object { $_ -ceq 'handler' }).Count
        }
    }
}

Describe 'nothing a session exports holds a registered value' {
    BeforeEach {
        Initialize-WorkloadTestSession -Variables ([ordered]@{ username = 'u1'; loginUser = 'u1'; pass = 'S3cr3t-fixture' })
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:Events.Add($EventRecord) }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession { $null }
        $script:SweepScreenDir = Join-Path $TestDrive 'sweep-screens'
        $null = New-Item -ItemType Directory -Path $script:SweepScreenDir -Force
        Mock Get-CycleScreenDir -ModuleName Test.WorkloadSession { $script:SweepScreenDir }
        Mock Get-VMScreenshot -ModuleName Test.WorkloadSession { [IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3)); $OutFile }
        Mock Get-TesseractWordBox -ModuleName Test.WorkloadSession { , $script:ScreenBoxes }
        Mock Get-EnabledOcrProvider -ModuleName Test.WorkloadSession { 'tesseract' }
    }

    It 'keeps a registered value out of everything the session exports' {
        Use-WorkloadTestScreen -Line 'prompt S3cr3t-fixture'
        $sentence = 'type secret ${pass} and press Enter'
        $script:SweepSteps = @([ordered]@{ action = 'workloadInput'; description = 'Type the secret'; fromStep = 'type secret *** and press Enter'
                sensitive = $true; text = '${pass}' })
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession {
            foreach ($fixtureStep in $script:SweepSteps) {
                $copy = [ordered]@{}
                foreach ($key in @($fixtureStep.Keys)) { $copy[$key] = $fixtureStep[$key] }
                $copy
            }
        }
        $script:Events.Clear()
        $passing = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-pass'; step = $sentence; intent = 'Type the secret' }))
        Assert-Equal 'succeeded' $passing.state
        $script:SweepSteps = @([ordered]@{ action = 'workloadInput'; description = 'Type the secret'; fromStep = 'type secret *** and press Enter'
                sensitive = $true; text = '${pass}'; ocrTail = 'u1 login: S3cr3t-fixture'; fail = $true })
        $failing = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-fail'; step = $sentence; intent = 'Type the secret again' }))
        Assert-Equal 'failed' $failing.state
        $snapshot = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-True $snapshot.ok 'the snapshot failed'

        $files = @(Get-ChildItem -LiteralPath $script:Session.Folder -File -Recurse)
        foreach ($required in @('journal.ndjson', 'engine.log', 'failure-0002.json')) {
            Assert-True (@($files | Where-Object { $_.Name -ceq $required }).Count -eq 1) "$required was not written"
        }
        Assert-True (@($files | Where-Object { $_.Name -like 'screen-*.txt' }).Count -ge 3) 'the snapshots were not written'
        foreach ($file in $files) {
            Assert-False ([IO.File]::ReadAllText($file.FullName)).Contains('S3cr3t-fixture') "$($file.Name) holds the value"
        }
        foreach ($answer in @($passing, $failing, $snapshot, (Get-WorkloadJournalResult -Session $script:Session), (Get-WorkloadFailureResult -Session $script:Session))) {
            Assert-False (ConvertTo-Json -InputObject $answer -Depth 12).Contains('S3cr3t-fixture') 'an exported result holds the value'
        }
        $recordPath = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
        Assert-True (Test-Path -LiteralPath $recordPath -PathType Leaf) 'last_failure.json was not written'
        Assert-False ([IO.File]::ReadAllText($recordPath)).Contains('S3cr3t-fixture') 'last_failure.json holds the value'
        $failureEvents = @($script:Events | Where-Object { [string]$_['event'] -ceq 'step_failure' })
        Assert-True ($failureEvents.Count -ge 1) 'no step_failure event was recorded'
        foreach ($failureEvent in $failureEvents) {
            Assert-False (ConvertTo-Json -InputObject $failureEvent -Depth 12).Contains('S3cr3t-fixture') 'a step_failure event holds the value'
        }
        $passEntry = @($script:Session.Journal | Where-Object { [string]$_['operationId'] -ceq 'op-pass' })[0]
        Assert-True ([string]$passEntry['yaml']).Contains('${pass}') "the passing entry's yaml was $($passEntry['yaml'])"
    }
}

Describe 'the runtime, the replays and the saving of a session' {
    BeforeAll {
        # Captured before any mock, so a filtered mock can call the real command.
        $script:RealStop = & (Get-Module Test.WorkloadRuntime) { Get-Command Stop-YurunaProcessTree }

        # The VM verbs a session must never call; the driver's functions are
        # put back in AfterAll.
        $script:VmVerbCalls = [System.Collections.Generic.List[string]]::new()
        $script:SavedVmVerb = @{}
        foreach ($verbName in @('Stop-VMForce', 'Start-VM')) {
            $existing = Get-Item -LiteralPath "function:\$verbName" -ErrorAction SilentlyContinue
            $script:SavedVmVerb[$verbName] = if ($existing) { $existing.ScriptBlock } else { $null }
        }
        function global:Stop-VMForce {
            <#
            .SYNOPSIS
                Fixture: records a call that would stop a VM.
            #>
            param([Parameter(ValueFromRemainingArguments)][object[]]$Rest)
            $script:VmVerbCalls.Add("Stop-VMForce $($Rest -join ' ')")
        }
        function global:Start-VM {
            <#
            .SYNOPSIS
                Fixture: records a call that would start a VM.
            #>
            param([Parameter(ValueFromRemainingArguments)][object[]]$Rest)
            $script:VmVerbCalls.Add("Start-VM $($Rest -join ' ')")
        }

        # A child that claims the runtime the way a session does, once the go
        # file exists, and holds the lease until the done file exists.
        $script:ClaimScriptText = @'
param([string]$ModulesDir, [string]$GoFile, [string]$ResultFile, [string]$DoneFile)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ModulesDir '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.SingleInstance.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.Prelude.psm1') -Global -DisableNameChecking
$limit = [DateTime]::UtcNow.AddSeconds(120)
while (-not (Test-Path -LiteralPath $GoFile) -and [DateTime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 10 }
$claimed = Initialize-YurunaOneShotEntryPoint -CallerName 'Invoke-WorkloadSession' -Confirm:$false 6>$null
[IO.File]::WriteAllText("$ResultFile.tmp", [string]$claimed)
Move-Item -LiteralPath "$ResultFile.tmp" -Destination $ResultFile -Force
while (-not (Test-Path -LiteralPath $DoneFile) -and [DateTime]::UtcNow -lt $limit) { Start-Sleep -Milliseconds 20 }
Write-Output ([string]$claimed)
'@

        function New-WorkloadTestWorker {
            <#
            .SYNOPSIS
                The worker state of the worker shell, without a session.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: returns a new in-memory worker state.')]
            param()
            return @{ Session = $null
                Screen = @{ Table = $null; Boxes = @(); Counter = 0; Ordinal = 0 }
                Page = @{ Table = $null; Counter = 0; Ordinal = 0 }
                PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = $null; MaskId = 0 }
        }

        function Open-WorkloadTestRuntime {
            <#
            .SYNOPSIS
                Starts a session runtime on the case's host paths; on success the
                session and a worker that holds it become $script:Session and
                $script:Worker.
            #>
            param(
                [string]$Sequence = '',
                [System.Collections.IDictionary]$Variables = @{},
                [string]$VMName = 'test-guest.ubuntu.server.24-01',
                [string]$GuestKey = 'guest.ubuntu.server.24'
            )
            $script:FolderCount++
            $folder = Join-Path $script:Paths.TestRoot ('session-{0:D2}' -f $script:FolderCount)
            $null = New-Item -ItemType Directory -Path $folder -Force
            $r = Start-WorkloadSessionRuntime -Paths $script:Paths -SessionId 'test' -Folder $folder -GuestKey $GuestKey -VMName $VMName `
                -Sequence $Sequence -Variables $Variables
            if ($r['ok'] -eq $true) {
                $script:OpenSessions.Add($r['Session'])
                $script:Worker = New-WorkloadTestWorker
                $script:Worker.Session = $r['Session']
                $r['Session'].SurfaceState = @{ Screen = $script:Worker.Screen; Page = $script:Worker.Page }
                $script:Session = $r['Session']
            }
            return $r
        }

        function Write-WorkloadTestStandIn {
            <#
            .SYNOPSIS
                Writes standin.json for the next start of the stand-in replay
                child and removes what an earlier start of the case left.
            #>
            param([hashtable]$Setting = @{})
            $instructions = [ordered]@{ modulesDir = $PSScriptRoot; exitCode = 0; sleepSeconds = 0; record = 'match'; recordOutcome = 'pass'
                finishedVmName = ''; failureOcrTail = ''; startSleeper = $false }
            foreach ($key in @($Setting.Keys)) { $instructions[$key] = $Setting[$key] }
            foreach ($leftover in @('standin.out.json', 'sleeper.json')) {
                $leftoverPath = Join-Path $script:Paths.TestRoot $leftover
                if (Test-Path -LiteralPath $leftoverPath) { Remove-Item -LiteralPath $leftoverPath -Force }
            }
            [IO.File]::WriteAllText((Join-Path $script:Paths.TestRoot 'standin.json'), (ConvertTo-Json -InputObject $instructions))
        }

        function Read-WorkloadTestStandIn {
            <#
            .SYNOPSIS
                What the stand-in recorded about its start, or $null.
            #>
            param([string]$Name = 'standin.out.json')
            $recordPath = Join-Path $script:Paths.TestRoot $Name
            if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $null }
            return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($recordPath)) -AsHashtable -DateKind String)
        }

        function Wait-WorkloadTestCondition {
            <#
            .SYNOPSIS
                Polls a condition on the real clock; $true once it holds, $false
                when the bound passed.
            #>
            param([Parameter(Mandatory)][scriptblock]$Condition, [int]$Seconds = 30)
            $until = [Environment]::TickCount64 + 1000L * $Seconds
            while ([Environment]::TickCount64 -lt $until) {
                if (& $Condition) { return $true }
                Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 50
            }
            return [bool](& $Condition)
        }

        function Wait-WorkloadTestReplayResult {
            <#
            .SYNOPSIS
                Waits, bounded, for the active replay's child to exit and returns
                the replay result.
            #>
            param([Parameter(Mandatory)][hashtable]$Session, [int]$Seconds = 60)
            $handle = $Session.ActiveReplay
            $null = Wait-WorkloadTestCondition -Seconds $Seconds -Condition { $handle.Process.HasExited }.GetNewClosure()
            return (Get-WorkloadReplayResult -Session $Session)
        }

        function Stop-WorkloadTestProcess {
            <#
            .SYNOPSIS
                Ends a process the case started when it is still that process.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: ends a child process the case started.')]
            param([int]$ProcessId, [long]$StartTicks)
            if ($ProcessId -le 0) { return }
            if (Test-WorkloadProcessIdentity -ProcessId $ProcessId -StartTicks $StartTicks) {
                Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
            }
        }

        function Stop-WorkloadTestSleeper {
            <#
            .SYNOPSIS
                Ends the sleeper the stand-in started, when sleeper.json names one
                that still runs.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: ends the sleeper the stand-in started.')]
            param()
            if ($null -eq $script:Paths) { return }
            $sleeper = Read-WorkloadTestStandIn -Name 'sleeper.json'
            if ($null -ne $sleeper) { Stop-WorkloadTestProcess -ProcessId ([int]$sleeper['pid']) -StartTicks ([long]$sleeper['startTicks']) }
        }

        function Start-WorkloadTestClaimChild {
            <#
            .SYNOPSIS
                Starts one pwsh child that claims the runtime once the go file
                exists; returns the process and its file names.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: starts a child process the case ends itself.')]
            param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$GoFile, [Parameter(Mandatory)][string]$DoneFile)
            $scriptPath = Join-Path $script:Paths.TestRoot 'claim.ps1'
            if (-not (Test-Path -LiteralPath $scriptPath)) { Set-Content -LiteralPath $scriptPath -Value $script:ClaimScriptText -Encoding ascii }
            $resultFile = Join-Path $script:Paths.TestRoot "claim-$Tag.txt"
            $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ModulesDir', $PSScriptRoot, '-GoFile', $GoFile,
                    '-ResultFile', $resultFile, '-DoneFile', $DoneFile)) {
                $info.ArgumentList.Add($argument)
            }
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.Environment['NO_COLOR'] = '1'
            $process = [System.Diagnostics.Process]::Start($info)
            $child = @{ Process = $process; ResultFile = $resultFile; Output = $process.StandardOutput.ReadToEndAsync()
                StartTicks = $process.StartTime.ToUniversalTime().Ticks }
            $script:Children.Add($child)
            return $child
        }

        function Start-WorkloadTestSleeper {
            <#
            .SYNOPSIS
                Starts one pwsh child that sleeps, as another owner of the runtime.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: starts a child process the case ends itself.')]
            param()
            $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60')) { $info.ArgumentList.Add($argument) }
            $info.UseShellExecute = $false
            $info.Environment['NO_COLOR'] = '1'
            $process = [System.Diagnostics.Process]::Start($info)
            $child = @{ Process = $process; StartTicks = $process.StartTime.ToUniversalTime().Ticks }
            $script:Children.Add($child)
            return $child
        }

        function Write-WorkloadTestOwnerFile {
            <#
            .SYNOPSIS
                Writes a pid file and its start record for a live process, as
                its owner would.
            #>
            param([Parameter(Mandatory)][string]$Stem, [Parameter(Mandatory)][System.Diagnostics.Process]$Process)
            $runtimeDir = $env:YURUNA_RUNTIME_DIR
            $null = New-Item -ItemType Directory -Path $runtimeDir -Force
            Set-Content -LiteralPath (Join-Path $runtimeDir "$Stem.pid") -Value "$($Process.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $runtimeDir "$Stem.start") -Encoding utf8NoBOM `
                -Value ($Process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture))
        }

        function Get-WorkloadTestStatus {
            <#
            .SYNOPSIS
                The status document of the case's runtime as a hashtable.
            #>
            return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'status.json'))) -AsHashtable -DateKind String)
        }

        function Get-WorkloadTestReplayCall {
            <#
            .SYNOPSIS
                A sequence.run call for the case's session.
            #>
            param([Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$Sequence, [scriptblock]$ShouldStop = { $false })
            return (Get-WorkloadTestCall -Params ([ordered]@{ operationId = $OperationId; sequence = $Sequence }) -ShouldStop $ShouldStop)
        }
    }

    AfterAll {
        foreach ($verbName in @('Stop-VMForce', 'Start-VM')) {
            Remove-Item -LiteralPath "function:\$verbName" -ErrorAction SilentlyContinue
            if ($null -ne $script:SavedVmVerb[$verbName]) { Set-Item -LiteralPath "function:global:$verbName" -Value $script:SavedVmVerb[$verbName] }
        }
    }

    BeforeEach {
        $script:CaseEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_CYCLE_CONTEXT', 'YURUNA_CYCLE_GENERATION'
        $script:CaseGlobal = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaLogFile', '__YurunaCycleStartUtc', '__YurunaCycleIdentity'
        $script:Paths = Get-WorkloadTestHostPath
        $env:YURUNA_RUNTIME_DIR = Join-Path $script:Paths.StatusDir 'runtime'
        $env:YURUNA_LOG_DIR = Join-Path $script:Paths.StatusDir 'log'
        $script:VmState = @{ 'test-guest.ubuntu.server.24-01' = 'running' }
        $script:FolderCount = 0
        $script:OpenSessions = [System.Collections.Generic.List[object]]::new()
        $script:Children = [System.Collections.Generic.List[object]]::new()
        $script:VmVerbCalls.Clear()
        $script:ScopeCalls = [System.Collections.Generic.List[object]]::new()
        $script:OwnedCalls = [System.Collections.Generic.List[object]]::new()
        $script:SurfaceResets = [System.Collections.Generic.List[string]]::new()
        $script:Session = $null
        $script:Worker = $null

        Mock Get-HostType -ModuleName Test.WorkloadRuntime { 'host.ubuntu.kvm' }
        Mock Initialize-YurunaHost -ModuleName Test.WorkloadRuntime { $true }
        Mock Get-HostConditionVerdict -ModuleName Test.WorkloadRuntime { [pscustomobject]@{ Passed = $true; Condition = ''; Detail = '' } }
        Mock Test-ElevationRequired -ModuleName Test.WorkloadRuntime { $false }
        Mock Test-LibvirtGroupReExecNeeded -ModuleName Test.WorkloadRuntime { [pscustomobject]@{ Needed = $false } }
        Mock Get-VmAdmission -ModuleName Test.WorkloadRuntime {
            $occupants = @($script:VmState.Keys | Where-Object { $_ -ne $ExceptVmName -and $script:VmState[$_] -eq 'running' } | Sort-Object)
            [pscustomobject]@{ State = $(if ($occupants.Count) { 'occupied' } else { 'clear' }); Occupants = $occupants }
        }
        Mock Reset-WorkloadSurface -ModuleName Test.WorkloadRuntime { $script:SurfaceResets.Add([string]$Reason) }
        Mock Register-WorkloadOwnedProcess -ModuleName Test.WorkloadRuntime {
            $script:OwnedCalls.Add([ordered]@{ Verb = 'register'; ProcessId = $ProcessId; StartTicks = $StartTicks; Role = $Role })
        }
        Mock Unregister-WorkloadOwnedProcess -ModuleName Test.WorkloadRuntime {
            $script:OwnedCalls.Add([ordered]@{ Verb = 'unregister'; ProcessId = $ProcessId })
        }
        # The real function would resolve the authentication extension of the
        # copied sequences; this one gives a new session the keys the executor
        # part owns, with their first values.
        Mock Initialize-WorkloadVariableScope -ModuleName Test.WorkloadRuntime {
            $script:ScopeCalls.Add([ordered]@{ Sequence = $Sequence; HasSequence = $PesterBoundParameters.ContainsKey('Sequence')
                    Variables = $Variables; HasVariables = $PesterBoundParameters.ContainsKey('Variables') })
            if (-not $Session.ContainsKey('Journal')) {
                $Session.RawVariables = [ordered]@{}
                $Session.Vars = @{ vmName = [string]$Session.VMName }
                $Session.OperationSeq = 0
                $Session.Journal = [System.Collections.Generic.List[object]]::new()
                $Session.Results = @{}
                $Session.SensitiveState = $false
                $Session.SensitiveSinceSeq = 0
                $Session.LastFailure = $null
                $Session.PhraseLibrary = $null
            }
            return $null
        }
        # Keeps the replay handler and its guest connection away from a hypervisor.
        Mock Repair-VncConnection -ModuleName Test.WorkloadRuntime { $true }
        # The 500 ms pause of the replay handler is a fixed pause; a short real
        # pause keeps a case that waits for a real child from spinning.
        Mock Start-Sleep -ModuleName Test.WorkloadSession { Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 20 }
    }

    AfterEach {
        foreach ($openSession in @($script:OpenSessions)) {
            if ([string]$openSession.State -ne 'ended') {
                try {
                    $null = Stop-WorkloadSessionRuntime -Session $openSession -Reason 'ended'
                } catch {
                    Write-Warning "A session of the case was not ended: $($_.Exception.Message)"
                }
            }
        }
        Stop-WorkloadTestSleeper
        foreach ($child in @($script:Children)) { Stop-WorkloadTestProcess -ProcessId $child.Process.Id -StartTicks $child.StartTicks }
        $null = Exit-YurunaOneShotLease -RuntimeDir (Join-Path $script:Paths.StatusDir 'runtime') -Confirm:$false
        Restore-YurunaTestEnvironment -Saved $script:CaseEnvironment
        Restore-YurunaTestGlobal -Saved $script:CaseGlobal
    }

    Describe 'session start and end own the runtime' {
        It 'claims the lease before any other change and holds it until the session ends' {
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            Assert-Equal -Expected 'Self' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State -Because 'the session holds the lease'
            $null = Stop-WorkloadSessionRuntime -Session $script:Session
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State -Because 'the end gave it back'
        }

        It 'refuses beside <Owner> and holds nothing afterwards' -ForEach @(
            @{ Owner = 'a live runner.pid'; Kind = 'runner' }
            @{ Owner = 'a lease held by a sleeper process'; Kind = 'lease' }
            @{ Owner = 'a lease with an empty pid file'; Kind = 'empty' }
            @{ Owner = 'a closed runner gate'; Kind = 'gate' }
        ) {
            $runtimeDir = $env:YURUNA_RUNTIME_DIR
            $null = New-Item -ItemType Directory -Path $runtimeDir -Force
            $holder = $null
            switch ($Kind) {
                'runner' {
                    $holder = Start-WorkloadTestSleeper
                    Write-WorkloadTestOwnerFile -Stem 'runner' -Process $holder.Process
                }
                'lease' {
                    $holder = Start-WorkloadTestSleeper
                    Write-WorkloadTestOwnerFile -Stem 'oneshot' -Process $holder.Process
                }
                'empty' { [IO.File]::WriteAllText((Join-Path $runtimeDir 'oneshot.pid'), '') }
                'gate' {
                    Mock Get-YurunaRunnerGateState -ModuleName Test.Prelude { [pscustomobject]@{ SpawnAllowed = $false; State = 'closed'; RequestId = 'r' } }
                }
            }
            $before = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $runtimeDir -File)) { $before[$file.Name] = [IO.File]::ReadAllBytes($file.FullName) }

            $r = Open-WorkloadTestRuntime
            Assert-False ($r['ok'] -eq $true) "the start beside $Owner was not refused"
            Assert-Equal -Expected 'workload_runtime_owned' -Actual $r['error']['code']
            if ($null -ne $holder) {
                Assert-Match -Pattern ([regex]::Escape("$($holder.Process.Id)")) -Actual $r['error']['message'] -Because 'the refusal names the holder'
            }
            foreach ($name in @($before.Keys)) {
                $path = Join-Path $runtimeDir $name
                Assert-True (Test-Path -LiteralPath $path) "the other owner's file '$name' was removed"
                Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$before[$name], [byte[]][IO.File]::ReadAllBytes($path))) "the other owner's file '$name' changed"
            }
            $lease = Get-YurunaOneShotLeaseState -RuntimeDir $runtimeDir
            Assert-NotEqual -Expected 'Self' -Actual $lease.State -Because 'a refused start holds nothing'
            if ($Kind -in @('runner', 'gate')) { Assert-Equal -Expected 'Missing' -Actual $lease.State -Because 'the claim was given back' }
            Assert-Equal -Expected 0 -Actual $script:OpenSessions.Count -Because 'no session exists'
        }

        It 'of two simultaneous claims exactly one owns the runtime' {
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
            $goFile = Join-Path $script:Paths.TestRoot 'claim.go'
            $doneFile = Join-Path $script:Paths.TestRoot 'claim.done'
            $first = Start-WorkloadTestClaimChild -Tag 'a' -GoFile $goFile -DoneFile $doneFile
            $second = Start-WorkloadTestClaimChild -Tag 'b' -GoFile $goFile -DoneFile $doneFile
            try {
                Set-Content -LiteralPath $goFile -Value 'go' -Encoding ascii
                $answered = Wait-WorkloadTestCondition -Seconds 120 -Condition { (Test-Path -LiteralPath $first.ResultFile) -and (Test-Path -LiteralPath $second.ResultFile) }.GetNewClosure()
                Assert-True $answered 'both children claimed within 120 s'
                Set-Content -LiteralPath $doneFile -Value 'done' -Encoding ascii
                foreach ($child in @($first, $second)) { Assert-True ($child.Process.WaitForExit(60000)) 'a claim child did not exit' }
                $printed = @(foreach ($child in @($first, $second)) { @(([string]$child.Output.Result).Trim() -split "\r?\n")[-1].Trim() })
                Assert-Equal -Expected 1 -Actual @($printed | Where-Object { $_ -ceq 'True' }).Count -Because "exactly one claim succeeds: $($printed -join ', ')"
                Assert-Equal -Expected 1 -Actual @($printed | Where-Object { $_ -ceq 'False' }).Count -Because "the other claim is refused: $($printed -join ', ')"
            } finally {
                if (-not (Test-Path -LiteralPath $doneFile)) { Set-Content -LiteralPath $doneFile -Value 'done' -Encoding ascii }
            }
        }

        It 'a refused start resets no status document, opens no cycle folder and clears no control flag' {
            $runtimeDir = $env:YURUNA_RUNTIME_DIR
            $null = New-Item -ItemType Directory -Path $runtimeDir -Force
            $null = New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force
            $statusPath = Join-Path $runtimeDir 'status.json'
            $pausePath = Join-Path $runtimeDir 'control.step-pause'
            [IO.File]::WriteAllText($statusPath, '{"fixture":"an earlier cycle"}')
            [IO.File]::WriteAllText($pausePath, 'paused by the operator')
            $statusBytes = [IO.File]::ReadAllBytes($statusPath)
            $pauseBytes = [IO.File]::ReadAllBytes($pausePath)
            $listing = { @(Get-ChildItem -LiteralPath $script:Paths.StatusDir -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object) -join "`n" }
            $runtimeBefore = & $listing
            $script:VmState['test-guest.ubuntu.server.24-01'] = 'stopped'

            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_vm_stopped' -Actual $r['error']['code']
            Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$statusBytes, [byte[]][IO.File]::ReadAllBytes($statusPath))) 'status.json changed'
            Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$pauseBytes, [byte[]][IO.File]::ReadAllBytes($pausePath))) 'the pause flag changed'
            Assert-StringEqual -Expected $runtimeBefore -Actual (& $listing) -Because 'no cycle folder or other file was left'
        }

        It 'releases the lease when a step after the claim throws' {
            Mock Register-StandaloneCycle -ModuleName Test.WorkloadRuntime { throw 'registration fixture failure' }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_start_failed' -Actual $r['error']['code']
            Assert-Match -Pattern 'registration fixture failure' -Actual $r['error']['message']
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'closes the cycle and releases the lease when a step after registration throws' {
            Mock Get-VmAdmission -ModuleName Test.WorkloadRuntime { throw 'admission fixture failure' }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_start_failed' -Actual $r['error']['code']
            $folders = @(Get-ChildItem -LiteralPath $env:YURUNA_LOG_DIR -Directory | ForEach-Object { $_.Name })
            Assert-Equal -Expected 0 -Actual @($folders | Where-Object { $_.EndsWith('.incomplete') }).Count -Because "the cycle folder was renamed: $($folders -join ', ')"
            Assert-True ($folders.Count -ge 1) 'a cycle folder was opened and closed'
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'refuses when the lease is written without its start record' {
            Mock Initialize-YurunaOneShotEntryPoint -ModuleName Test.WorkloadRuntime {
                $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
                Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid') -Value "$PID" -Encoding utf8NoBOM
                $true
            }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_lease_incomplete' -Actual $r['error']['code']
            Assert-False (Test-Path -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid')) 'the lease file is gone'
        }

        It "reports an unready host with the condition and the provider's lines" {
            # The provider's lines are records it writes, not a throw: the
            # error is written as non-terminating whatever preference the
            # runner of this file set, because a throw is the second half.
            Mock Get-HostConditionVerdict -ModuleName Test.WorkloadRuntime {
                Write-Warning 'fixture warning line'
                Write-Error 'fixture error line' -ErrorAction Continue
                [pscustomobject]@{ Passed = $false; Condition = 'fixture-condition'; Detail = 'fixture detail' }
            }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_host_not_ready' -Actual $r['error']['code']
            foreach ($expected in @('fixture-condition', 'fixture detail', 'fixture warning line', 'fixture error line')) {
                Assert-Match -Pattern ([regex]::Escape($expected)) -Actual $r['error']['message'] -Because "the message names '$expected'"
            }
            Mock Get-HostConditionVerdict -ModuleName Test.WorkloadRuntime { throw 'provider fixture crash' }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_host_not_ready' -Actual $r['error']['code']
            Assert-Match -Pattern 'unnamed' -Actual $r['error']['message']
            Assert-Match -Pattern 'provider fixture crash' -Actual $r['error']['message']
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'attaches to a running VM and registers one owner cycle with a Session step' {
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            $s = $r['Session']
            Assert-True ($s -is [hashtable]) "the session is a $($s.GetType().FullName)"
            Assert-False ($s -is [System.Collections.Specialized.OrderedDictionary]) 'the session is not an ordered dictionary'
            foreach ($key in @('SessionId', 'Folder', 'HostType', 'GuestKey', 'OsKey', 'VMName', 'RepoRoot', 'TestRoot', 'SequencesDir', 'ConfigPath',
                    'Config', 'RuntimeDir', 'StatusPath', 'CycleStartUtc', 'CycleNumber', 'CycleFolder', 'SourceSequence', 'SourceSequencePath',
                    'SourceVariables', 'OverrideVariables', 'State', 'DetachReason', 'ReplayCounter', 'ActiveReplay')) {
                Assert-True $s.ContainsKey($key) "the session has no key '$key'"
            }
            Assert-Equal -Expected 'attached' -Actual $s.State
            Assert-Equal -Expected 'test-guest.ubuntu.server.24-01' -Actual $s.VMName
            Assert-Equal -Expected 'ubuntu.server.24' -Actual $s.OsKey
            Assert-Equal -Expected 'host.ubuntu.kvm' -Actual $s.HostType
            Assert-Equal -Expected (Join-Path $env:YURUNA_RUNTIME_DIR 'status.json') -Actual $s.StatusPath
            Assert-True ([string]$s.CycleFolder -and (Test-Path -LiteralPath $s.CycleFolder -PathType Container)) "the cycle folder '$($s.CycleFolder)' exists"
            Assert-NotNull $s.CycleStartUtc 'the cycle start is stored'
            $status = Get-WorkloadTestStatus
            $rows = @($status['guests'] | Where-Object { $_['guestKey'] -eq 'guest.ubuntu.server.24' })
            Assert-Equal -Expected 1 -Actual $rows.Count -Because 'one guest row'
            Assert-Equal -Expected 1 -Actual @($status['guests']).Count -Because 'the owner cycle holds only the session guest'
            Assert-Equal -Expected 'test-guest.ubuntu.server.24-01' -Actual $rows[0]['vmName']
            Assert-Equal -Expected 'workload-session' -Actual $rows[0]['topLevel']
            Assert-Equal -Expected 'running' -Actual $rows[0]['status']
            $steps = @($rows[0]['steps'])
            Assert-Equal -Expected 1 -Actual $steps.Count -Because 'one step'
            Assert-Equal -Expected 'Session' -Actual $steps[0]['name']
            Assert-Equal -Expected 'running' -Actual $steps[0]['status']
        }

        It 'answers a start through the handler and keeps the session in the worker state' {
            Mock Import-WorkloadEngineModule -ModuleName Test.WorkloadSession { $script:Paths }
            $folder = Join-Path $script:Paths.TestRoot 'session-handler'
            $null = New-Item -ItemType Directory -Path $folder -Force
            $refusedWorker = New-WorkloadTestWorker
            $script:VmState['test-guest.ubuntu.server.24-01'] = 'stopped'
            $refused = Invoke-WorkloadSessionStartRequest -Call @{ Id = 'r1'; Method = 'session.start'; SessionId = 'test'; SessionDir = $folder; RefBase = 0
                ConfigPath = $script:Paths.ConfigPath; Worker = $refusedWorker; ShouldStop = { $false }; Progress = { }
                Params = [ordered]@{ guestKey = 'guest.ubuntu.server.24'; vmName = 'test-guest.ubuntu.server.24-01' } }
            Assert-Equal -Expected 'workload_vm_stopped' -Actual $refused['error']['code']
            Assert-Null $refusedWorker.Session 'a refused start leaves no session'

            $script:VmState['test-guest.ubuntu.server.24-01'] = 'running'
            $worker = New-WorkloadTestWorker
            $reply = Invoke-WorkloadSessionStartRequest -Call @{ Id = 'r2'; Method = 'session.start'; SessionId = 'test'; SessionDir = $folder; RefBase = 0
                ConfigPath = $script:Paths.ConfigPath; Worker = $worker; ShouldStop = { $false }; Progress = { }
                Params = [ordered]@{ guestKey = 'guest.ubuntu.server.24'; vmName = 'test-guest.ubuntu.server.24-01' } }
            if ($null -ne $worker.Session) { $script:OpenSessions.Add($worker.Session) }
            Assert-StringEqual -Expected 'ok,vmName,guestKey,hostType,defaultSurface,variables,otherRunningVms' -Actual (@($reply.Keys) -join ',')
            Assert-True ($reply['ok'] -eq $true) 'the start is answered ok'
            Assert-Equal -Expected 'screen' -Actual $reply['defaultSurface']
            Assert-False $reply.Contains('runtimeDir') 'the reply names no runtime folder'
            Assert-NotNull $worker.Session 'the worker keeps the session'
            Assert-Equal -Expected 'test-guest.ubuntu.server.24-01' -Actual $worker.Session.VMName
            Assert-True ([object]::ReferenceEquals($worker.Session.SurfaceState.Screen, $worker.Screen)) 'the session reads the worker screen state'
            Assert-True ([object]::ReferenceEquals($worker.Session.SurfaceState.Page, $worker.Page)) 'the session reads the worker page state'
        }

        It 'refuses <State> without stopping or starting any VM' -ForEach @(
            @{ State = 'absent'; Code = 'workload_vm_absent' }
            @{ State = 'stopped'; Code = 'workload_vm_stopped' }
            @{ State = 'unknown'; Code = 'workload_vm_unknown' }
        ) {
            if ($State -eq 'absent') { $script:VmState.Remove('test-guest.ubuntu.server.24-01') } else { $script:VmState['test-guest.ubuntu.server.24-01'] = $State }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected $Code -Actual $r['error']['code']
            Assert-Equal -Expected 0 -Actual $script:VmVerbCalls.Count -Because "no VM verb ran: $($script:VmVerbCalls -join '; ')"
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'stops no other VM at session start and lists the ones that run' {
            $script:VmState['other-vm-a'] = 'running'
            $script:VmState['other-vm-b'] = 'stopped'
            $script:VmState['other-vm-c'] = 'running'
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            Assert-StringEqual -Expected 'other-vm-a,other-vm-c' -Actual (@($r['OtherRunningVms']) -join ',')
            Should -Invoke Get-VmAdmission -ModuleName Test.WorkloadRuntime -Times 1 -Exactly -ParameterFilter { $ExceptVmName -eq 'test-guest.ubuntu.server.24-01' }
            Assert-Equal -Expected 0 -Actual $script:VmVerbCalls.Count -Because "no VM verb ran: $($script:VmVerbCalls -join '; ')"
            Assert-Equal -Expected 'running' -Actual $script:VmState['other-vm-a']
            Assert-Equal -Expected 'running' -Actual $script:VmState['other-vm-c']
        }

        It "keeps the source file's own variables apart from its prerequisites'" {
            $r = Open-WorkloadTestRuntime -Sequence 'workload.guest.ubuntu.server.24' -Variables ([ordered]@{ zeta = 'z1'; alpha = 'a1'; middle = 'm1' })
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            $s = $r['Session']
            Assert-StringEqual -Expected 'username' -Actual (@($s.SourceVariables.Keys) -join ',') -Because 'only the source file declares username; currentPassword is the prerequisite''s'
            Assert-StringEqual -Expected 'zeta,alpha,middle' -Actual (@($s.OverrideVariables.Keys) -join ',')
            Assert-Equal -Expected 1 -Actual $script:ScopeCalls.Count -Because 'the variable scope is built once'
            $expectedPath = Join-Path $script:Paths.SequencesDir 'workload.guest.ubuntu.server.24.yml'
            Assert-True $script:ScopeCalls[0].HasSequence 'the scope was given the sequence'
            Assert-Equal -Expected $expectedPath -Actual $script:ScopeCalls[0].Sequence
            Assert-Equal -Expected $expectedPath -Actual $s.SourceSequencePath
            Assert-Equal -Expected 'workload.guest.ubuntu.server.24' -Actual $s.SourceSequence
        }

        It 'refuses a sequence that is missing, is an orchestration, or names another guest' {
            Set-Content -LiteralPath (Join-Path $script:Paths.SequencesDir 'suite.orchestration.yml') -Encoding ascii -Value @(
                'description: "Fixture orchestration."', 'steps:', '  - action: InvokeTestSequence', '    sequence: start.guest.ubuntu.server.24')
            $other = ([IO.File]::ReadAllText((Join-Path $script:Paths.SequencesDir 'start.guest.ubuntu.server.24.yml'))).Replace('ubuntu.server.24:', 'ubuntu.server.26:')
            [IO.File]::WriteAllText((Join-Path $script:Paths.SequencesDir 'start.other.fixture.yml'), $other)
            foreach ($case in @(
                    @{ Sequence = 'no.such.sequence'; Code = 'workload_sequence_not_found' }
                    @{ Sequence = 'suite.orchestration'; Code = 'workload_sequence_not_guest' }
                    @{ Sequence = 'start.other.fixture'; Code = 'workload_sequence_not_guest' })) {
                $r = Open-WorkloadTestRuntime -Sequence $case.Sequence
                Assert-Equal -Expected $case.Code -Actual $r['error']['code'] -Because "the sequence '$($case.Sequence)'"
                Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
            }
            Assert-Equal -Expected 0 -Actual $script:OpenSessions.Count
        }

        It 'refuses a guest with no folder, a host that needs elevation and a process without the libvirt group' {
            $r = Open-WorkloadTestRuntime -GuestKey 'guest.no.folder'
            Assert-Equal -Expected 'workload_guest_unknown' -Actual $r['error']['code']
            Mock Test-ElevationRequired -ModuleName Test.WorkloadRuntime { $true }
            Mock Test-IsAdministrator -ModuleName Test.WorkloadRuntime { $false }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_elevation_required' -Actual $r['error']['code']
            Mock Test-ElevationRequired -ModuleName Test.WorkloadRuntime { $false }
            Mock Test-LibvirtGroupReExecNeeded -ModuleName Test.WorkloadRuntime { [pscustomobject]@{ Needed = $true } }
            $r = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_libvirt_group_missing' -Actual $r['error']['code']
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
            Assert-Equal -Expected 0 -Actual $script:OpenSessions.Count
        }

        It 'reports a missing lease, a replaced lease and a live runner record as lost ownership' {
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            $s = $r['Session']
            Assert-True (Test-WorkloadSessionOwnership -Session $s).Owned 'a new session owns its runtime'
            Assert-Null (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_step' -NeedsVm -NeedsOwnership) 'no refusal while owned'
            $pidFile = Join-Path $s.RuntimeDir 'oneshot.pid'
            $own = [IO.File]::ReadAllText($pidFile)
            $holder = Start-WorkloadTestSleeper
            try {
                Remove-Item -LiteralPath $pidFile -Force
                Assert-Equal -Expected 'lease-missing' -Actual (Test-WorkloadSessionOwnership -Session $s).Reason
                Assert-Equal -Expected 'workload_ownership_lost' -Actual (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_step' -NeedsOwnership)['error']['code']
                [IO.File]::WriteAllText($pidFile, "$($holder.Process.Id)")
                Assert-Equal -Expected 'lease-replaced' -Actual (Test-WorkloadSessionOwnership -Session $s).Reason
                Assert-Equal -Expected 'workload_ownership_lost' -Actual (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_step' -NeedsOwnership)['error']['code']
                [IO.File]::WriteAllText($pidFile, $own)
                Write-WorkloadTestOwnerFile -Stem 'runner' -Process $holder.Process
                Assert-Equal -Expected 'runner-active' -Actual (Test-WorkloadSessionOwnership -Session $s).Reason
                Assert-Equal -Expected 'workload_ownership_lost' -Actual (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_step' -NeedsOwnership)['error']['code']
            } finally {
                Remove-Item -LiteralPath (Join-Path $s.RuntimeDir 'runner.pid'), (Join-Path $s.RuntimeDir 'runner.start') -ErrorAction SilentlyContinue
                [IO.File]::WriteAllText($pidFile, $own)
            }
        }

        It 'a killed holder leaves a lease the next start takes over' {
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
            $goFile = Join-Path $script:Paths.TestRoot 'claim.go'
            Set-Content -LiteralPath $goFile -Value 'go' -Encoding ascii
            $holder = Start-WorkloadTestClaimChild -Tag 'holder' -GoFile $goFile -DoneFile (Join-Path $script:Paths.TestRoot 'claim.never')
            Assert-True (Wait-WorkloadTestCondition -Seconds 120 -Condition { Test-Path -LiteralPath $holder.ResultFile }.GetNewClosure()) 'the holder claimed within 120 s'
            Assert-StringEqual -Expected 'True' -Actual ([IO.File]::ReadAllText($holder.ResultFile)) -Because 'the holder owns the runtime'
            $holder.Process.Kill()
            Assert-True ($holder.Process.WaitForExit(30000)) 'the holder ended'
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start after the kill was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            Assert-Equal -Expected 'Self' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'ending a session never removes a lease another process took' {
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            $holder = Start-WorkloadTestSleeper
            Write-WorkloadTestOwnerFile -Stem 'oneshot' -Process $holder.Process
            $end = Stop-WorkloadSessionRuntime -Session $r['Session']
            Assert-False $end.Released 'the session released a lease it did not hold'
            Assert-StringEqual -Expected "$($holder.Process.Id)" -Actual ([IO.File]::ReadAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid')).Trim())
            Assert-Equal -Expected 'Held' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
            Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid'), (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.start') -ErrorAction SilentlyContinue
        }

        It 'ends the cycle once, releases the lease and leaves the VM running' {
            $r = Open-WorkloadTestRuntime
            Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
            $s = $r['Session']
            $openFolder = [string]$s.CycleFolder
            $end = Stop-WorkloadSessionRuntime -Session $s
            Assert-True $end.Released 'the lease was released'
            Assert-False ([string]$end.CycleFolder).EndsWith('.incomplete') "the cycle folder keeps its suffix: $($end.CycleFolder)"
            Assert-True (Test-Path -LiteralPath $end.CycleFolder -PathType Container) 'the closed cycle folder exists'
            if ($openFolder -ne [string]$end.CycleFolder) { Assert-False (Test-Path -LiteralPath $openFolder) 'the open name is gone' }
            Assert-Equal -Expected 'ended' -Actual $s.State
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
            Assert-Equal -Expected 'running' -Actual $script:VmState['test-guest.ubuntu.server.24-01']
            Assert-Equal -Expected 0 -Actual $script:VmVerbCalls.Count -Because "no VM verb ran: $($script:VmVerbCalls -join '; ')"
            $ends = @(Get-Content -LiteralPath (Join-Path $end.CycleFolder 'cycle.events.ndjson') | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable } |
                    Where-Object { $_['event'] -eq 'cycle_end' })
            $statusBytes = [IO.File]::ReadAllBytes((Join-Path $env:YURUNA_RUNTIME_DIR 'status.json'))
            $again = Stop-WorkloadSessionRuntime -Session $s
            Assert-False $again.Released 'a second end releases nothing'
            Assert-Equal -Expected ([string]$end.CycleFolder) -Actual ([string]$again.CycleFolder)
            Assert-Equal -Expected 1 -Actual $ends.Count -Because 'one cycle_end'
            Assert-Equal -Expected 1 -Actual @(Get-Content -LiteralPath (Join-Path $end.CycleFolder 'cycle.events.ndjson') | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable } |
                    Where-Object { $_['event'] -eq 'cycle_end' }).Count -Because 'the second end closed nothing'
            Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$statusBytes, [byte[]][IO.File]::ReadAllBytes((Join-Path $env:YURUNA_RUNTIME_DIR 'status.json')))) 'the second end changed status.json'
        }

        It 'is safe to call twice and after a failed start' {
            $script:VmState['test-guest.ubuntu.server.24-01'] = 'stopped'
            $refused = Open-WorkloadTestRuntime
            Assert-Equal -Expected 'workload_vm_stopped' -Actual $refused['error']['code']
            $worker = New-WorkloadTestWorker
            foreach ($attempt in 1..2) {
                $reply = Invoke-WorkloadSessionEndRequest -Call @{ Params = @{ reason = 'client-request' }; Worker = $worker }
                Assert-True ($reply['ok'] -eq $true) "end $attempt is answered ok"
                Assert-False $reply['released'] "end $attempt released nothing"
                Assert-Equal -Expected '' -Actual $reply['cycleFolder']
            }
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It "maps each end reason to the runtime's reason" {
            $script:EndReasons = [System.Collections.Generic.List[string]]::new()
            Mock Stop-WorkloadSessionRuntime -ModuleName Test.WorkloadSession { $script:EndReasons.Add([string]$Reason); @{ Released = $true; CycleFolder = 'c' } }
            $cases = @(
                @{ Sent = 'client-request'; Mapped = 'ended' }
                @{ Sent = 'client-ended'; Mapped = 'client-disconnect' }
                @{ Sent = 'parent-lost'; Mapped = 'client-disconnect' }
                @{ Sent = 'worker-exit'; Mapped = 'error' }
                @{ Sent = 'idle'; Mapped = 'error' }
                @{ Sent = $null; Mapped = 'error' })
            foreach ($case in $cases) {
                $worker = New-WorkloadTestWorker
                $worker.Session = @{ State = 'attached' }
                $params = if ($null -eq $case.Sent) { @{} } else { @{ reason = $case.Sent } }
                $reply = Invoke-WorkloadSessionEndRequest -Call @{ Params = $params; Worker = $worker }
                Assert-Equal -Expected $case.Mapped -Actual $script:EndReasons[$script:EndReasons.Count - 1] -Because "the reason '$($case.Sent)'"
                Assert-True $reply['released'] 'the reply carries released'
                Assert-Equal -Expected 'c' -Actual $reply['cycleFolder']
                Assert-Null $worker.Session 'the worker forgot the session'
            }
            Assert-Equal -Expected $cases.Count -Actual $script:EndReasons.Count
        }

        It 'closes the owner cycle as failed only for the reason error' {
            foreach ($case in @(@{ Reason = 'ended'; Outcome = 'pass' }, @{ Reason = 'client-disconnect'; Outcome = 'pass' }, @{ Reason = 'error'; Outcome = 'aborted' })) {
                $r = Open-WorkloadTestRuntime
                Assert-True ($r['ok'] -eq $true) "the start was refused: $(ConvertTo-Json -InputObject $r -Depth 6 -Compress)"
                $end = Stop-WorkloadSessionRuntime -Session $r['Session'] -Reason $case.Reason
                $ends = @(Get-Content -LiteralPath (Join-Path $end.CycleFolder 'cycle.events.ndjson') | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable } |
                        Where-Object { $_['event'] -eq 'cycle_end' })
                Assert-Equal -Expected 1 -Actual $ends.Count
                Assert-Equal -Expected $case.Outcome -Actual $ends[0]['outcome'] -Because "the reason '$($case.Reason)'"
            }
            $last = $r['Session']
            Assert-Throw { Stop-WorkloadSessionRuntime -Session $last -Reason 'idle' } -Because 'the parameter refuses another reason'
        }
    }
    Describe 'a replay runs as a nested child of the session' {
        BeforeEach {
            $script:ProgressSeen = [System.Collections.Generic.List[object]]::new()
            $script:Stopped = $null
            $opened = Open-WorkloadTestRuntime
            if ($opened['ok'] -ne $true) { throw "The fixture session was refused: $(ConvertTo-Json -InputObject $opened -Depth 6 -Compress)" }
            $script:ReplaySequence = 'start.guest.ubuntu.server.24'
            $script:ParentNode = 'guest.ubuntu.server.24/r0001'
        }

        It 'starts the replay with the session VM, the guest key, -NoProjectClone and the start step' {
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            $recorded = Read-WorkloadTestStandIn
            $arguments = [string[]]@($recorded['commandLine'])
            $at = [array]::IndexOf($arguments, '-SequenceName')
            Assert-True ($at -ge 0) "the child received no -SequenceName: $($arguments -join ' ')"
            $tail = [string[]]@($arguments[$at..($arguments.Count - 1)])
            $expected = [string[]]@('-SequenceName', 'start.guest.ubuntu.server.24', '-GuestKey', 'guest.ubuntu.server.24', '-VMName', 'test-guest.ubuntu.server.24-01',
                '-StartStep', '1', '-ConfigPath', $script:Paths.ConfigPath, '-NoProjectClone')
            Assert-Equal -Expected $expected.Count -Actual $tail.Count -Because "the arguments from -SequenceName on: $($tail -join ' ')"
            for ($i = 0; $i -lt $expected.Count; $i++) {
                Assert-True ([string]::Equals($expected[$i], $tail[$i], [StringComparison]::Ordinal)) "argument $i is '$($tail[$i])', not '$($expected[$i])'"
            }
        }

        It 'starts at the first step of the named sequence' {
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence 'workload.guest.ubuntu.server.24')
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            $prerequisiteSteps = @((Read-SequenceFile -Path (Join-Path $script:Paths.SequencesDir 'start.guest.ubuntu.server.24.yml'))['steps']).Count
            Assert-True ($prerequisiteSteps -gt 0) 'the prerequisite has steps'
            Assert-StringEqual -Expected ($prerequisiteSteps + 1) -Actual (Read-WorkloadTestStandIn)['bound']['StartStep']
            Assert-Equal -Expected ($prerequisiteSteps + 1) -Actual $result['startStep']
        }

        It 'passes a name, never a path, to the child' {
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence 'start.guest.ubuntu.server.24.yml')
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            Assert-True ([string]::Equals('start.guest.ubuntu.server.24', [string](Read-WorkloadTestStandIn)['bound']['SequenceName'], [StringComparison]::Ordinal)) 'the child got the stripped name'
            $configPath = $script:Paths.ConfigPath
            Assert-Equal -Expected 0 -Actual @([string[]]@((Read-WorkloadTestStandIn)['commandLine']) | Where-Object { $_.EndsWith('.yml') -and $_ -ne $configPath }).Count -Because 'no argument names a sequence file'
        }

        It 'publishes the cycle context to the child and removes it from its own environment' {
            Write-WorkloadTestStandIn
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            $contextText = [string](Read-WorkloadTestStandIn)['environment']['YURUNA_CYCLE_CONTEXT']
            Assert-True ([bool]$contextText) 'the child received a cycle context'
            $context = ConvertFrom-Json -InputObject $contextText -AsHashtable -DateKind String
            Assert-Equal -Expected $script:ParentNode -Actual $context['parentId']
            Assert-Equal -Expected $script:Session.StatusPath -Actual $context['statusPath']
            Assert-True ([string]::IsNullOrEmpty($env:YURUNA_CYCLE_CONTEXT)) 'the worker keeps no cycle context'
        }

        It 'the child sees the lease held by its parent and the parent holds it afterwards' {
            Write-WorkloadTestStandIn
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'Held' -Actual (Read-WorkloadTestStandIn)['leaseState']
            Assert-Equal -Expected 'Self' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        }

        It 'registers the child as an owned process and removes it when the replay completes' {
            Write-WorkloadTestStandIn
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            $childPid = [int](Read-WorkloadTestStandIn)['pid']
            $registered = @($script:OwnedCalls | Where-Object { $_.Verb -eq 'register' })
            $unregistered = @($script:OwnedCalls | Where-Object { $_.Verb -eq 'unregister' })
            Assert-Equal -Expected 1 -Actual $registered.Count
            Assert-Equal -Expected $childPid -Actual $registered[0].ProcessId
            Assert-True ([long]$registered[0].StartTicks -gt 0) 'the start ticks were recorded'
            Assert-Equal -Expected 'replay' -Actual $registered[0].Role
            Assert-Equal -Expected 1 -Actual $unregistered.Count
            Assert-Equal -Expected $childPid -Actual $unregistered[0].ProcessId
        }

        It 'writes the replay files under the owner cycle folder' {
            Write-WorkloadTestStandIn
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            $names = @('r0001.out.log', 'r0001.err.log', 'r0001.completion.json')
            foreach ($name in $names) {
                Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $script:Session.CycleFolder 'workload-replay') $name) -PathType Leaf) "the cycle folder holds $name"
            }
            $sessionFiles = @(Get-ChildItem -LiteralPath $script:Session.Folder -Recurse -File | ForEach-Object { $_.Name })
            Assert-Equal -Expected 0 -Actual @($sessionFiles | Where-Object { $_.StartsWith('replay-') -or $_.EndsWith('.log') -or $_ -like 'r0001*' }).Count -Because "session files: $($sessionFiles -join ', ')"
            $end = Stop-WorkloadSessionRuntime -Session $script:Session
            Assert-False ([string]$end.CycleFolder).EndsWith('.incomplete') 'the cycle folder has its bare name'
            foreach ($name in $names) {
                Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $end.CycleFolder 'workload-replay') $name) -PathType Leaf) "the closed cycle folder holds $name"
            }
        }

        It 'gives every replay its own parent node and nested folder' {
            Write-WorkloadTestStandIn -Setting @{ exitCode = 1; recordOutcome = 'fail'; failureOcrTail = 'first replay failed here' }
            $first = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Write-WorkloadTestStandIn
            $second = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-2' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'r0001' -Actual $first['replayId']
            Assert-Equal -Expected 'r0002' -Actual $second['replayId']
            Assert-Equal -Expected 'failed' -Actual $first['verdict']
            Assert-NotNull $first['failure'] 'the first replay reports its failure'
            Assert-Equal -Expected 'passed' -Actual $second['verdict']
            Assert-Null $second['failure'] 'the second replay does not report the failure of the first'
            $nested = (Get-WorkloadTestStatus)['nested']
            foreach ($node in @('guest.ubuntu.server.24/r0001', 'guest.ubuntu.server.24/r0002')) {
                Assert-True $nested.Contains($node) "status.json holds the node $node"
            }
            Assert-Equal -Expected 'fail' -Actual $nested['guest.ubuntu.server.24/r0001']['status']
            Assert-Equal -Expected 'pass' -Actual $nested['guest.ubuntu.server.24/r0002']['status']
            $nestedRoot = Join-Path $script:Session.CycleFolder 'nested'
            Assert-True (Test-Path -LiteralPath (Join-Path $nestedRoot 'guest.ubuntu.server.24_r0001_start.guest.ubuntu.server.24/last_failure.json')) 'the first failure stays in its own folder'
            Assert-False (Test-Path -LiteralPath (Join-Path $nestedRoot 'guest.ubuntu.server.24_r0002_start.guest.ubuntu.server.24/last_failure.json')) 'the second folder holds no failure'
        }

        It 'takes the verdict from the exit code and the record of this invocation' -ForEach @(
            @{ Row = 'exit 0, matched pass'; Exit = 0; Record = 'match'; Outcome = 'pass'; Stop = ''; Verdict = 'passed'; Effect = 'applied' }
            @{ Row = 'exit 0, no record'; Exit = 0; Record = 'missing'; Outcome = 'pass'; Stop = ''; Verdict = 'passed'; Effect = 'applied' }
            @{ Row = 'exit 0, record of another invocation'; Exit = 0; Record = 'mismatch'; Outcome = 'fail'; Stop = ''; Verdict = 'passed'; Effect = 'applied' }
            @{ Row = 'exit 0, matched fail'; Exit = 0; Record = 'match'; Outcome = 'fail'; Stop = ''; Verdict = 'failed'; Effect = 'uncertain' }
            @{ Row = 'exit 0, matched not-run'; Exit = 0; Record = 'match'; Outcome = 'not-run'; Stop = ''; Verdict = 'failed'; Effect = 'uncertain' }
            @{ Row = 'exit 1, matched not-run'; Exit = 1; Record = 'match'; Outcome = 'not-run'; Stop = ''; Verdict = 'cannot-run'; Effect = 'none-proven' }
            @{ Row = 'exit 1, matched fail'; Exit = 1; Record = 'match'; Outcome = 'fail'; Stop = ''; Verdict = 'failed'; Effect = 'uncertain' }
            @{ Row = 'exit 1, matched pass'; Exit = 1; Record = 'match'; Outcome = 'pass'; Stop = ''; Verdict = 'failed'; Effect = 'uncertain' }
            @{ Row = 'exit 2, record of another invocation'; Exit = 2; Record = 'mismatch'; Outcome = 'not-run'; Stop = ''; Verdict = 'cannot-run'; Effect = 'uncertain' }
            @{ Row = 'exit 2, unreadable record'; Exit = 2; Record = 'unreadable'; Outcome = 'pass'; Stop = ''; Verdict = 'cannot-run'; Effect = 'uncertain' }
            @{ Row = 'exit 3, no record'; Exit = 3; Record = 'missing'; Outcome = 'pass'; Stop = ''; Verdict = 'failed'; Effect = 'uncertain' }
            @{ Row = 'timed out'; Exit = 0; Record = 'match'; Outcome = 'pass'; Stop = 'timed-out'; Verdict = 'timed-out'; Effect = 'uncertain' }
            @{ Row = 'canceled'; Exit = 0; Record = 'match'; Outcome = 'pass'; Stop = 'canceled'; Verdict = 'canceled'; Effect = 'uncertain' }
            @{ Row = 'stopped at session end'; Exit = 0; Record = 'match'; Outcome = 'pass'; Stop = 'session-end'; Verdict = 'canceled'; Effect = 'uncertain' }
        ) {
            $sleep = if ($Stop) { 60 } else { 0 }
            Write-WorkloadTestStandIn -Setting @{ exitCode = $Exit; record = $Record; recordOutcome = $Outcome; sleepSeconds = $sleep }
            $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
            Assert-True ($start['ok'] -eq $true) 'the replay started'
            $handle = $script:Session.ActiveReplay
            $result = switch ($Stop) {
                'timed-out' {
                    $null = Wait-WorkloadTestCondition -Seconds 30 -Condition { Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json') }
                    Get-WorkloadReplayResult -Session $script:Session -NowUtc $handle.DeadlineUtc.AddSeconds(1)
                }
                { $_ -in @('canceled', 'session-end') } {
                    $null = Wait-WorkloadTestCondition -Seconds 30 -Condition { Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json') }
                    Stop-WorkloadReplay -Session $script:Session -Reason $Stop
                }
                default { Wait-WorkloadTestReplayResult -Session $script:Session }
            }
            Assert-NotNull $result "no result for the row '$Row'"
            Assert-True ([string]::Equals($Verdict, [string]$result['verdict'], [StringComparison]::Ordinal)) "row '$Row': the verdict is '$($result['verdict'])'"
            Assert-True ([string]::Equals($Effect, [string]$result['effect'], [StringComparison]::Ordinal)) "row '$Row': the effect is '$($result['effect'])'"
            $expectedState = if ($Record -eq 'match') { 'matched' } else { $Record }
            if (-not $Stop) { Assert-Equal -Expected $expectedState -Actual $result['recordState'] -Because "row '$Row'" }
            Assert-Null $script:Session.ActiveReplay 'the replay is complete'
        }

        It 'ignores a record of another invocation, a stale recovery.result.json and a failure record in the log root' {
            $replayFolder = Join-Path $script:Session.CycleFolder 'workload-replay'
            $null = New-Item -ItemType Directory -Path $replayFolder -Force
            [IO.File]::WriteAllText((Join-Path $replayFolder 'r0001.completion.json'),
                '{"schema":"yuruna.sequence-completion/v1","invocationId":"another-invocation","outcome":"fail","reason":"stale"}')
            [IO.File]::WriteAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'recovery.result.json'), '{"outcome":"fail","failureClass":"wait_timeout","reason":"stale recovery"}')
            $null = New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force
            [IO.File]::WriteAllText((Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'),
                '{"reason":"stale","failureClass":"wait_timeout","context":{"causeDetail":{"ocrTail":"a stale tail"}}}')
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            Assert-Equal -Expected 'matched' -Actual $result['recordState']
            Assert-Null $result['failure'] 'no failure is reported'
            Assert-Null $script:Session.LastFailure 'the session stores no failure'
        }

        It 'returns the replay result without a path of an unfiltered artifact' {
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-StringEqual -Expected ('ok,state,verdict,effect,exitCode,sequence,sequencePath,startStep,replayId,invocationId,operationId,recordState,' +
                'completionRecord,reason,vmName,vmRenamed,vmState,sessionState,failure,outputTruncated,durationSeconds,childStopped') -Actual (@($result.Keys) -join ',')
            foreach ($key in @('failureRecordPath', 'transcriptPath', 'outputLogPath', 'errorLogPath')) { Assert-False $result.Contains($key) "the result has $key" }
            $text = ConvertTo-Json -InputObject $result -Depth 12 -Compress
            Assert-False ($text.Contains('workload-replay')) 'the result names no replay log'
        }

        It 'filters the failure a replay returns for the values the session registered' {
            try {
                Enable-SequenceSecretFilter
                $null = Register-SequenceSecret -Value 'S3cr3t-replay-1'
                Write-WorkloadTestStandIn -Setting @{ exitCode = 1; recordOutcome = 'fail'; failureOcrTail = 'u1 login: S3cr3t-replay-1' }
                $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
                Assert-Equal -Expected 'failed' -Actual $result['verdict']
                $viewPath = Join-Path $script:Session.Folder 'failure-0001.json'
                Assert-True (Test-Path -LiteralPath $viewPath) 'the failure view was written'
                foreach ($text in @((ConvertTo-Json -InputObject $result['failure'] -Depth 12), (ConvertTo-Json -InputObject $script:Session.LastFailure -Depth 12),
                        [IO.File]::ReadAllText($viewPath))) {
                    Assert-False ($text.Contains('S3cr3t-replay-1')) 'the registered value is hidden'
                    Assert-True ($text.Contains('***')) 'the value is replaced by ***'
                }
            } finally {
                Clear-SequenceSecret
            }
        }

        It 'a refused replay takes no sequence number and leaves the sensitive state unchanged' {
            $s = $script:Session
            $s.OperationSeq = 3
            $s.SensitiveState = $false
            $unknown = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence 'no.such.sequence')
            $s.State = 'detached'
            $s.DetachReason = 'fixture'
            $detached = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-2' -Sequence $script:ReplaySequence)
            foreach ($case in @(@{ Result = $unknown; Code = 'workload_sequence_not_found' }, @{ Result = $detached; Code = 'workload_session_detached' })) {
                $r = $case.Result
                Assert-False $r['ok'] 'refused'
                Assert-Equal -Expected 'failed' -Actual $r['state']
                Assert-False $r['dispatched'] 'not dispatched'
                Assert-Equal -Expected 'none-proven' -Actual $r['effect']
                Assert-False $r['journaled'] 'not journaled'
                Assert-Equal -Expected $case.Code -Actual $r['error']['code']
            }
            Assert-Equal -Expected 3 -Actual $s.OperationSeq
            Assert-False $s.SensitiveState 'still not sensitive'
            Assert-Equal -Expected 0 -Actual $s.Journal.Count
            Assert-Equal -Expected 0 -Actual $script:OwnedCalls.Count -Because 'no process was started'
            Assert-Equal -Expected 0 -Actual $s.ReplayCounter
            $s.State = 'attached'
            $s.DetachReason = ''
            Write-WorkloadTestStandIn
            $ran = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-3' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'passed' -Actual $ran['verdict']
            Assert-Equal -Expected 4 -Actual $s.OperationSeq
            Assert-True $s.SensitiveState 'a replay that started makes the session sensitive'
        }

        It 'passes the timeout of the request to the replay and keeps 7200 without one' {
            $script:ReplayTimeouts = [System.Collections.Generic.List[object]]::new()
            Mock Start-WorkloadReplay -ModuleName Test.WorkloadSession {
                $script:ReplayTimeouts.Add(@{ Bound = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); Value = $TimeoutSeconds })
                New-WorkloadRefusal -Code 'workload_sequence_not_found' -Key 'runner.workload_sequence_not_found' -Arguments @{ tool = 'workload_run_sequence'; sequence = 'x'; list = '' }
            }
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; sequence = $script:ReplaySequence; timeoutSeconds = 90 }))
            $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-2'; sequence = $script:ReplaySequence }))
            Assert-Equal -Expected 2 -Actual $script:ReplayTimeouts.Count
            Assert-True $script:ReplayTimeouts[0].Bound 'the timeout was passed'
            Assert-Equal -Expected 90 -Actual $script:ReplayTimeouts[0].Value
            Assert-False $script:ReplayTimeouts[1].Bound 'without a timeout the parameter keeps its default'
        }

        It 'follows a VM rename reported by the child and forgets the proven address' {
            Mock Clear-ProvenGuestAddress -ModuleName Test.WorkloadRuntime { }
            $script:VmState['renamed-guest-01'] = 'running'
            Write-WorkloadTestStandIn -Setting @{ finishedVmName = 'renamed-guest-01' }
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            Assert-Equal -Expected 'renamed-guest-01' -Actual $result['vmName']
            Assert-True $result['vmRenamed'] 'the rename is reported'
            Assert-Equal -Expected 'renamed-guest-01' -Actual $script:Session.VMName
            Assert-Equal -Expected 'attached' -Actual $script:Session.State
            Should -Invoke Clear-ProvenGuestAddress -ModuleName Test.WorkloadRuntime -Times 1 -Exactly
            Assert-Equal -Expected 2 -Actual $script:ScopeCalls.Count -Because 'the variable table was rebuilt for the new name'
        }

        It 'detaches the session when no VM is running after the replay' {
            Write-WorkloadTestStandIn
            $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
            Assert-True ($start['ok'] -eq $true) 'the replay started'
            $script:VmState['test-guest.ubuntu.server.24-01'] = 'stopped'
            $result = Wait-WorkloadTestReplayResult -Session $script:Session
            Assert-Equal -Expected 'detached' -Actual $result['sessionState']
            Assert-Equal -Expected 'stopped' -Actual $result['vmState']
            Assert-Equal -Expected 'detached' -Actual $script:Session.State
            Assert-Equal -Expected 'vm-stopped' -Actual $script:Session.DetachReason
            Assert-Equal -Expected 'workload_session_detached' -Actual (Get-WorkloadSessionRefusal -Session $script:Session -Tool 'workload_step' -NeedsVm)['error']['code']
        }

        It "refuses an orchestration, a host action, an unknown name and another guest's sequence before it starts a process" {
            Set-Content -LiteralPath (Join-Path $script:Paths.SequencesDir 'suite.orchestration.yml') -Encoding ascii -Value @(
                'description: "Fixture orchestration."', 'steps:', '  - action: InvokeTestSequence', '    sequence: start.guest.ubuntu.server.24')
            Set-Content -LiteralPath (Join-Path $script:Paths.SequencesDir 'lab.host.action.yml') -Encoding ascii -Value @(
                'description: "Fixture host action."', 'host:', '  scripts:', '    - Fixture-Lab.ps1')
            $other = ([IO.File]::ReadAllText((Join-Path $script:Paths.SequencesDir 'start.guest.ubuntu.server.24.yml'))).Replace('ubuntu.server.24:', 'ubuntu.server.26:')
            [IO.File]::WriteAllText((Join-Path $script:Paths.SequencesDir 'start.other.fixture.yml'), $other)
            foreach ($case in @(
                    @{ Sequence = 'suite.orchestration'; Code = 'workload_sequence_not_guest' }
                    @{ Sequence = 'lab.host.action'; Code = 'workload_sequence_not_guest' }
                    @{ Sequence = 'no.such.sequence'; Code = 'workload_sequence_not_found' }
                    @{ Sequence = 'start.other.fixture'; Code = 'workload_sequence_not_guest' })) {
                $r = Start-WorkloadReplay -Session $script:Session -Sequence $case.Sequence -OperationId 'op-1'
                Assert-Equal -Expected $case.Code -Actual $r['error']['code'] -Because "the sequence '$($case.Sequence)'"
            }
            Assert-Equal -Expected 0 -Actual $script:OwnedCalls.Count -Because 'no process was started'
            Assert-Equal -Expected 0 -Actual $script:Session.ReplayCounter
            Assert-Null $script:Session.ActiveReplay 'no replay is active'
        }

        It 'refuses when detached and when ownership is lost' {
            $s = $script:Session
            $s.State = 'detached'
            $s.DetachReason = 'fixture'
            Assert-Equal -Expected 'workload_session_detached' -Actual (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_run_sequence' -NeedsVm -NeedsOwnership)['error']['code']
            Assert-Equal -Expected 'workload_session_detached' -Actual (Start-WorkloadReplay -Session $s -Sequence $script:ReplaySequence -OperationId 'op-1')['error']['code']
            $s.State = 'attached'
            $s.DetachReason = ''
            $pidFile = Join-Path $s.RuntimeDir 'oneshot.pid'
            $own = [IO.File]::ReadAllText($pidFile)
            try {
                Remove-Item -LiteralPath $pidFile -Force
                Assert-Equal -Expected 'workload_ownership_lost' -Actual (Get-WorkloadSessionRefusal -Session $s -Tool 'workload_run_sequence' -NeedsVm -NeedsOwnership)['error']['code']
                Assert-Equal -Expected 'workload_ownership_lost' -Actual (Start-WorkloadReplay -Session $s -Sequence $script:ReplaySequence -OperationId 'op-2')['error']['code']
            } finally {
                [IO.File]::WriteAllText($pidFile, $own)
            }
            Assert-Equal -Expected 0 -Actual $script:OwnedCalls.Count -Because 'no process was started'
        }

        It 'says why the chain of a replay could not be planned' {
            foreach ($case in @(
                    @{ Expected = 'snapshot probe failed'; Body = { Write-Warning 'snapshot probe failed'; @{ resolveFailed = $true } } }
                    @{ Expected = 'searched /x'; Body = { Write-Information 'searched /x' -InformationAction Continue; @{ resolveFailed = $true } } }
                    @{ Expected = 'boom'; Body = { throw 'boom' } })) {
                Mock Resolve-TestSequencePlan -ModuleName Test.WorkloadRuntime -MockWith $case.Body
                $r = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1' 3>$null 6>$null
                Assert-Equal -Expected 'workload_plan_invalid' -Actual $r['error']['code']
                Assert-Match -Pattern ([regex]::Escape($case.Expected)) -Actual $r['error']['message'] -Because 'the refusal says why'
            }
            Assert-Equal -Expected 0 -Actual $script:OwnedCalls.Count -Because 'no process was started'
            Assert-Equal -Expected 0 -Actual $script:Session.ReplayCounter
        }

        It 'stops the child tree at the deadline and reports an uncertain effect' {
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60; startSleeper = $true }
            $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
            Assert-True ($start['ok'] -eq $true) 'the replay started'
            $handle = $script:Session.ActiveReplay
            $childPid = $handle.ChildPid
            $childTicks = $handle.Process.StartTime.ToUniversalTime().Ticks
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'sleeper.json') }) 'the stand-in started its sleeper'
            $sleeper = Read-WorkloadTestStandIn -Name 'sleeper.json'
            $result = Get-WorkloadReplayResult -Session $script:Session -NowUtc $handle.DeadlineUtc.AddSeconds(1)
            Assert-Equal -Expected 'timed-out' -Actual $result['verdict']
            Assert-Equal -Expected 'uncertain' -Actual $result['effect']
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { -not (Test-WorkloadProcessIdentity -ProcessId $childPid -StartTicks $childTicks) }.GetNewClosure()) 'the stand-in is gone'
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { -not (Test-WorkloadProcessIdentity -ProcessId ([int]$sleeper['pid']) -StartTicks ([long]$sleeper['startTicks'])) }.GetNewClosure()) 'the sleeper is gone'
        }

        It 'cancel stops the child tree and marks both nested nodes failed' {
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $outPath = Join-Path $script:Paths.TestRoot 'standin.out.json'
            $giveUpAt = [Environment]::TickCount64 + 30000
            $shouldStop = { (Test-Path -LiteralPath $outPath) -or [Environment]::TickCount64 -ge $giveUpAt }.GetNewClosure()
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence -ShouldStop $shouldStop)
            Assert-Equal -Expected 'canceled' -Actual $result['state']
            Assert-Equal -Expected 'canceled' -Actual $result['verdict']
            $entries = @(Get-WorkloadJournalEntry -Session $script:Session)
            Assert-Equal -Expected 1 -Actual $entries.Count
            Assert-Equal -Expected 'workload_run_sequence' -Actual $entries[0]['tool']
            Assert-Equal -Expected 'canceled' -Actual $entries[0]['outcome']
            $nested = (Get-WorkloadTestStatus)['nested']
            Assert-Equal -Expected 'fail' -Actual $nested[$script:ParentNode]['status']
            Assert-Equal -Expected 'fail' -Actual $nested["$($script:ParentNode)/$($script:ReplaySequence)"]['status']
        }

        It 'answers workload_no_session for a replay and a save without a session' {
            $script:Worker = New-WorkloadTestWorker
            $run = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            $save = Invoke-WorkloadSequenceSaveRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ name = 'x'; description = 'x'; resource = @('start.guest.ubuntu.server.24') }))
            Assert-Equal -Expected 'workload_no_session' -Actual $run['error']['code']
            Assert-Equal -Expected 'workload_no_session' -Actual $save['error']['code']
            Assert-Equal -Expected 0 -Actual $script:OwnedCalls.Count -Because 'no process was started'
        }

        It 'reports spawn-failed for a script that cannot start and leaves the session attached' {
            Mock Get-PwshExePath -ModuleName Test.WorkloadRuntime { Join-Path $script:Root 'no-such-pwsh' }
            Write-WorkloadTestStandIn
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            Assert-False $result['ok'] 'the replay failed'
            Assert-Equal -Expected 'failed' -Actual $result['state']
            Assert-False $result['dispatched'] 'not dispatched'
            Assert-Equal -Expected 'none-proven' -Actual $result['effect']
            Assert-False $result['journaled'] 'not journaled'
            Assert-Equal -Expected 'workload_replay_spawn_failed' -Actual $result['error']['code']
            Assert-Equal -Expected 'attached' -Actual $script:Session.State
            Assert-Null $script:Session.ActiveReplay 'no replay is active'
            Assert-Equal -Expected 'fail' -Actual (Get-WorkloadTestStatus)['nested'][$script:ParentNode]['status']
            Assert-Equal -Expected 0 -Actual $script:Session.OperationSeq
            Assert-Equal -Expected 0 -Actual $script:Session.Journal.Count
        }

        It "does not wait for a process that kept the child's output open" {
            Write-WorkloadTestStandIn -Setting @{ exitCode = 3; sleepSeconds = 0; record = 'missing'; startSleeper = $true }
            try {
                $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
                Assert-True ($start['ok'] -eq $true) 'the replay started'
                $handle = $script:Session.ActiveReplay
                Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'sleeper.json') }) 'the sleeper started'
                Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { $handle.Process.HasExited }.GetNewClosure()) 'the stand-in exited'
                $sleeper = Read-WorkloadTestStandIn -Name 'sleeper.json'
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $result = Get-WorkloadReplayResult -Session $script:Session
                $watch.Stop()
                Assert-NotNull $result 'the replay completed'
                Assert-True $result['outputTruncated'] 'the output is reported truncated'
                Assert-True ($watch.Elapsed.TotalSeconds -lt 30) "the result took $($watch.Elapsed.TotalSeconds) s"
                Assert-True (Test-WorkloadProcessIdentity -ProcessId ([int]$sleeper['pid']) -StartTicks ([long]$sleeper['startTicks'])) 'the sleeper still runs'
            } finally {
                Stop-WorkloadTestSleeper
            }
        }

        It 'the handlers keep the engine out of the worker until a session starts and never start the status service, refresh the project or sweep VMs' {
            $forbidden = @('Start-YurunaStatusServiceIfEnabled', 'Invoke-CycleCheckoutStep', 'Update-ProjectClone', 'Invoke-CycleAdmissionStep',
                'Invoke-HostVmAdmission', 'Start-PerfCycle', 'Save-RecoveryResult')
            $moduleSetCalls = 0
            foreach ($path in @((Join-Path $PSScriptRoot 'Test.WorkloadSession.psm1'), (Join-Path $PSScriptRoot 'Test.WorkloadRuntime.psm1'),
                    (Join-Path (Split-Path -Parent $PSScriptRoot) 'service/Invoke-WorkloadSession.ps1'))) {
                $ast = Get-YurunaTestFileAst -Path $path
                $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
                foreach ($command in $commands) {
                    $commandName = $command.GetCommandName()
                    Assert-False ($commandName -in $forbidden) "$path calls $commandName"
                    if ($commandName -eq 'Initialize-YurunaEntryPointModuleSet') {
                        $moduleSetCalls++
                        $parent = $command.Parent
                        while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
                        Assert-True ($null -ne $parent -and $parent.Name -eq 'Import-WorkloadEngineModule') "$path calls Initialize-YurunaEntryPointModuleSet outside Import-WorkloadEngineModule"
                    }
                }
            }
            Assert-True ($moduleSetCalls -ge 1) 'the engine is loaded by Import-WorkloadEngineModule'
        }

        It 'ending the session stops a running replay and closes its logs before the cycle folder is renamed' {
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
            Assert-True ($start['ok'] -eq $true) 'the replay started'
            $handle = $script:Session.ActiveReplay
            $childPid = $handle.ChildPid
            $childTicks = $handle.Process.StartTime.ToUniversalTime().Ticks
            $null = Wait-WorkloadTestCondition -Seconds 30 -Condition { Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json') }
            $end = Stop-WorkloadSessionRuntime -Session $script:Session
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { -not (Test-WorkloadProcessIdentity -ProcessId $childPid -StartTicks $childTicks) }.GetNewClosure()) 'the child is gone'
            Assert-Null $script:Session.ActiveReplay 'no replay is active'
            Assert-Equal -Expected 'fail' -Actual (Get-WorkloadTestStatus)['nested'][$script:ParentNode]['status']
            Assert-False ([string]$end.CycleFolder).EndsWith('.incomplete') 'the cycle folder has its bare name'
            Assert-True (Test-Path -LiteralPath (Join-Path $end.CycleFolder 'workload-replay/r0001.out.log') -PathType Leaf) 'the renamed folder holds the replay log'
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
            Assert-False $handle.OutStream.CanWrite 'the output log is closed'
            Assert-False $handle.ErrStream.CanWrite 'the error log is closed'
        }

        It 'journals a replay whose polling threw as canceled and stops its child' {
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $outPath = Join-Path $script:Paths.TestRoot 'standin.out.json'
            $shouldStop = { if (Test-Path -LiteralPath $outPath) { throw 'the poll fixture threw' }; $false }.GetNewClosure()
            $result = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence -ShouldStop $shouldStop)
            Assert-Equal -Expected 'canceled' -Actual $result['state']
            Assert-Equal -Expected 'canceled' -Actual $result['verdict']
            Assert-Equal -Expected 'uncertain' -Actual $result['effect']
            $entries = @(Get-WorkloadJournalEntry -Session $script:Session)
            Assert-Equal -Expected 1 -Actual $entries.Count
            Assert-Equal -Expected 'workload_run_sequence' -Actual $entries[0]['tool']
            Assert-Equal -Expected 'canceled' -Actual $entries[0]['outcome']
            $childPid = [int](Read-WorkloadTestStandIn)['pid']
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { $null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue) }.GetNewClosure()) 'the child is gone'
            Assert-Null $script:Session.ActiveReplay 'no replay is active'
        }

        It 'answers a repeated sequence.run from the stored result and starts no second child' {
            Write-WorkloadTestStandIn
            $call = Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence
            $first = Invoke-WorkloadSequenceRunRequest -Call $call
            Assert-Equal -Expected 'passed' -Actual $first['verdict']
            Remove-Item -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json') -Force
            $second = Invoke-WorkloadSequenceRunRequest -Call $call
            Assert-True ([string]::Equals((ConvertTo-Json -InputObject $first -Depth 12 -Compress), (ConvertTo-Json -InputObject $second -Depth 12 -Compress),
                    [StringComparison]::Ordinal)) 'the two answers differ'
            Assert-Equal -Expected 1 -Actual $script:Session.ReplayCounter
            Assert-Equal -Expected 1 -Actual $script:Session.OperationSeq
            Assert-Equal -Expected 1 -Actual $script:Session.Journal.Count
            Assert-False (Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json')) 'no second child ran'
        }

        It 'stops the child when it cannot be recorded as an owned process' {
            Mock Stop-YurunaProcessTree -ModuleName Test.WorkloadRuntime { $script:Stopped = $ProcessId; & $script:RealStop @PesterBoundParameters }
            Mock Register-WorkloadOwnedProcess -ModuleName Test.WorkloadRuntime { throw 'disk' }
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $s = $script:Session
            Assert-Throw { Start-WorkloadReplay -Session $s -Sequence $script:ReplaySequence -OperationId 'op-1' } -Match 'disk'
            Assert-True ($script:Stopped -gt 0) 'the child was stopped'
            $stoppedPid = [int]$script:Stopped
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { $null -eq (Get-Process -Id $stoppedPid -ErrorAction SilentlyContinue) }.GetNewClosure()) 'the child is gone'
            Assert-Null $s.ActiveReplay 'no replay is active'
            Assert-Equal -Expected 'fail' -Actual (Get-WorkloadTestStatus)['nested'][$script:ParentNode]['status']
        }

        It 'completes a replay whose output copy faulted' {
            Write-WorkloadTestStandIn
            $start = Start-WorkloadReplay -Session $script:Session -Sequence $script:ReplaySequence -OperationId 'op-1'
            Assert-True ($start['ok'] -eq $true) 'the replay started'
            $handle = $script:Session.ActiveReplay
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { $handle.Process.HasExited }.GetNewClosure()) 'the stand-in exited'
            $handle.OutTask = [Threading.Tasks.Task]::FromException([IO.IOException]::new('x'))
            $result = Get-WorkloadReplayResult -Session $script:Session
            Assert-Equal -Expected 'passed' -Actual $result['verdict']
            Assert-True $result['outputTruncated'] 'a faulted copy counts as truncated'
            Assert-Null $script:Session.ActiveReplay 'the replay is complete'
        }

        It 'counts and journals a replay whose child was stopped at its start' {
            $script:FailOwnedRegister = $true
            Mock Stop-YurunaProcessTree -ModuleName Test.WorkloadRuntime { $script:Stopped = $ProcessId; & $script:RealStop @PesterBoundParameters }
            Mock Register-WorkloadOwnedProcess -ModuleName Test.WorkloadRuntime {
                if ($script:FailOwnedRegister) { throw 'disk' }
                $script:OwnedCalls.Add([ordered]@{ Verb = 'register'; ProcessId = $ProcessId; StartTicks = $StartTicks; Role = $Role })
            }
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $s = $script:Session
            $s.OperationSeq = 3
            $s.SensitiveState = $false
            $caught = $null
            try {
                $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence)
            } catch {
                $caught = $_
            }
            Assert-NotNull $caught 'the handler threw'
            Assert-True ($caught.Exception.Data['WorkloadReplayChildStarted'] -eq $true) 'the exception carries the started mark'
            Assert-Equal -Expected 4 -Actual $s.OperationSeq
            Assert-True $s.SensitiveState 'the session is sensitive'
            $entries = @(Get-WorkloadJournalEntry -Session $s)
            Assert-Equal -Expected 1 -Actual $entries.Count
            Assert-Equal -Expected 'workload_run_sequence' -Actual $entries[0]['tool']
            Assert-Equal -Expected 4 -Actual $entries[0]['seq']
            Assert-Equal -Expected 'failed' -Actual $entries[0]['outcome']
            Assert-Equal -Expected 'uncertain' -Actual $entries[0]['effect']
            $stoppedPid = [int]$script:Stopped
            Assert-True ($stoppedPid -gt 0) 'the child was stopped'
            Assert-True (Wait-WorkloadTestCondition -Seconds 30 -Condition { $null -eq (Get-Process -Id $stoppedPid -ErrorAction SilentlyContinue) }.GetNewClosure()) 'the child is gone'
            Assert-Null $s.ActiveReplay 'no replay is active'

            $null = Stop-WorkloadSessionRuntime -Session $s
            $script:FailOwnedRegister = $false
            Mock Register-NestedRunNode -ModuleName Test.WorkloadRuntime { throw 'status' }
            $opened = Open-WorkloadTestRuntime
            Assert-True ($opened['ok'] -eq $true) 'the second session started'
            $second = $script:Session
            $second.OperationSeq = 3
            Write-WorkloadTestStandIn -Setting @{ sleepSeconds = 60 }
            $caught = $null
            try {
                $null = Invoke-WorkloadSequenceRunRequest -Call (Get-WorkloadTestReplayCall -OperationId 'op-2' -Sequence $script:ReplaySequence)
            } catch {
                $caught = $_
            }
            Assert-NotNull $caught 'the handler threw'
            Assert-False ($caught.Exception.Data['WorkloadReplayChildStarted'] -eq $true) 'no child started'
            Assert-Equal -Expected 3 -Actual $second.OperationSeq
            Assert-Equal -Expected 0 -Actual $second.Journal.Count
            Assert-False (Test-Path -LiteralPath (Join-Path $script:Paths.TestRoot 'standin.out.json')) 'the stand-in never ran'
        }

        It 'journals a replay whose failure view could not be built and lets the exception out' {
            Mock ConvertTo-WorkloadFailureView -ModuleName Test.WorkloadSession { throw 'view' }
            Write-WorkloadTestStandIn -Setting @{ exitCode = 1; recordOutcome = 'fail'; failureOcrTail = 'the view fixture tail' }
            $call = Get-WorkloadTestReplayCall -OperationId 'op-1' -Sequence $script:ReplaySequence
            Assert-Throw { Invoke-WorkloadSequenceRunRequest -Call $call } -Match 'view'
            Assert-Equal -Expected 1 -Actual $script:Session.OperationSeq
            $entries = @(Get-WorkloadJournalEntry -Session $script:Session | Where-Object { $_['operationId'] -ceq 'op-1' })
            Assert-Equal -Expected 1 -Actual $entries.Count
            Assert-Equal -Expected 'workload_run_sequence' -Actual $entries[0]['tool']
            Assert-Equal -Expected 'failed' -Actual $entries[0]['outcome']
            Assert-Equal -Expected 'uncertain' -Actual $entries[0]['effect']
            $changes = @((Get-WorkloadJournalResult -Session $script:Session)['stateChanges'])
            Assert-Equal -Expected 1 -Actual @($changes | Where-Object { $_['tool'] -eq 'workload_run_sequence' }).Count -Because 'the replay is a state change'
            Assert-Null $script:Session.ActiveReplay 'no replay is active'
        }
    }
}

Describe 'the screen surface of a session' {
    BeforeEach {
        Initialize-WorkloadTestSession
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:Events.Add($EventRecord) }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:ScreenDir = Join-Path $TestDrive 'screens'
        $null = New-Item -ItemType Directory -Path $script:ScreenDir -Force
        Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession { $null }
        Mock Get-CycleScreenDir -ModuleName Test.WorkloadSession { $script:ScreenDir }
        Mock Get-VMScreenshot -ModuleName Test.WorkloadSession { [IO.File]::WriteAllBytes($OutFile, [byte[]](1, 2, 3)); $OutFile }
        # The unary comma gives the return form of the real function.
        Mock Get-TesseractWordBox -ModuleName Test.WorkloadSession { , $script:ScreenBoxes }
        Mock Get-EnabledOcrProvider -ModuleName Test.WorkloadSession { 'tesseract' }
    }

    It 'returns the screen as one entry per line with a reference and writes its file' {
        Use-WorkloadTestScreen -Line 'Next', "Don't save"
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-True ($snap.ok -eq $true) "the snapshot failed: $(ConvertTo-Json -InputObject $snap -Depth 6 -Compress)"
        Assert-StringEqual 'screen' $snap.surface
        Assert-Equal 1 $snap.snapshot
        Assert-Equal 2 $snap.entries
        Assert-True ($snap.text.StartsWith('# surface: screen   snapshot: 1   vm: never-a-real-vm', [StringComparison]::Ordinal)) "the header is '$($snap.text)'"
        Assert-True ($snap.text.Contains('- line "Next" [ref=s1]', [StringComparison]::Ordinal)) "the text lacks the Next entry: $($snap.text)"
        Assert-StringEqual (Join-Path $script:Session.Folder 'screen-0001.txt') $snap.file
        $fileText = [IO.File]::ReadAllText($snap.file)
        $entryLines = @($fileText -split "`n" | Where-Object { $_.StartsWith('- line ', [StringComparison]::Ordinal) })
        Assert-Equal 2 $entryLines.Count
        Assert-True ($fileText.Contains('- line "Next" [ref=s1]', [StringComparison]::Ordinal)) "the file lacks the Next entry: $fileText"
        Assert-True ($fileText.Contains('[ref=s2]', [StringComparison]::Ordinal)) "the file lacks the second entry: $fileText"
        $frameCopies = @(Get-ChildItem -LiteralPath $script:Session.Folder -Recurse -File | Where-Object { $_.Name -like '*.png' })
        Assert-Equal 0 $frameCopies.Count
    }

    It 'answers a reference of an earlier snapshot with workload_stale_reference' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $firstIds = @($script:Worker.Screen.Table.Keys)
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $secondIds = @($script:Worker.Screen.Table.Keys)
        $lastFirst = [long]$firstIds[-1].Substring(1)
        Assert-Equal ($lastFirst + 1) ([long]$secondIds[0].Substring(1))
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $firstIds[0] }))
        Assert-False $stale.ok
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
        Assert-True ($stale.error.message.Contains($firstIds[0], [StringComparison]::Ordinal)) "the message does not name $($firstIds[0]): $($stale.error.message)"
        $fresh = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $secondIds[0] }))
        Assert-True ($fresh.ok -eq $true) "the current reference was refused: $(ConvertTo-Json -InputObject $fresh -Depth 6 -Compress)"
    }

    It 'makes the references of the screen stale when a step ran' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $earlierId = @($script:Worker.Screen.Table.Keys)[0]
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadObserve'; description = 'Look at the screen'; fromStep = 'wait for text Next' } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = 'wait for text Next'; intent = 'Look at the screen' }))
        Assert-StringEqual 'succeeded' $ran.state
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $earlierId }))
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
        $stepIds = @([regex]::Matches([IO.File]::ReadAllText($ran.snapshot), '\[ref=(s[0-9]+)\]') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal 2 $stepIds.Count
        Assert-Equal ($stepIds -join ',') (@($script:Worker.Screen.Table.Keys) -join ',')
    }

    It 'drops the reference tables and keeps the counters' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        foreach ($reasonName in @('replay-start', 'replay', 'session-end')) {
            $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
            $script:Worker.Page.Counter = 7
            $script:Worker.Page.Ordinal = 3
            $kept = @($script:Worker.Screen.Counter, $script:Worker.Screen.Ordinal, $script:Worker.Page.Counter, $script:Worker.Page.Ordinal)
            Reset-WorkloadSurface -Session $script:Session -Reason $reasonName
            Assert-Null $script:Worker.Screen.Table "the screen table survived '$reasonName'"
            Assert-Null $script:Worker.Page.Table "the page table survived '$reasonName'"
            Assert-Equal 0 @($script:Worker.Screen.Boxes).Count
            Assert-Equal ($kept -join ',') (@($script:Worker.Screen.Counter, $script:Worker.Screen.Ordinal, $script:Worker.Page.Counter, $script:Worker.Page.Ordinal) -join ',')
            $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
            Assert-StringEqual ('s' + ([long]$kept[0] + 1)) @($script:Worker.Screen.Table.Keys)[0]
        }
        $bare = @{ VMName = 'never-a-real-vm' }
        Reset-WorkloadSurface -Session $bare -Reason 'replay'
        Assert-False $bare.ContainsKey('SurfaceState')
        Assert-Throw { Reset-WorkloadSurface -Session $script:Session -Reason 'idle' }
    }

    It 'answers a reference of a dropped table with workload_stale_reference' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $droppedId = @($script:Worker.Screen.Table.Keys)[0]
        Reset-WorkloadSurface -Session $script:Session -Reason 'replay'
        foreach ($reference in @($droppedId, 'p1')) {
            $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $reference }))
            Assert-False $stale.ok
            Assert-StringEqual 'workload_stale_reference' $stale.error.code
        }
    }

    It 'suggests the sentences that find the one line' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $nextId = @($script:Worker.Screen.Table.Keys | Where-Object { $script:Worker.Screen.Table[$_].Text -ceq 'Next' })[0]
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $nextId }))
        Assert-True ($answer.ok -eq $true) "the suggestion failed: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)"
        Assert-Equal 'wait for text Next|expect text Next|click Next|click button Next' (@($answer.suggestions | ForEach-Object { $_.step }) -join '|')
        foreach ($suggestion in @($answer.suggestions)) { Assert-StringEqual 'screen' $suggestion.on }

        Use-WorkloadTestScreen -Line "Don't save", 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $saveId = @($script:Worker.Screen.Table.Keys | Where-Object { $script:Worker.Screen.Table[$_].Text -ceq "Don't save" })[0]
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $saveId }))
        $library = Get-SequencePhraseLibrary
        $byId = @{}
        foreach ($phrase in @($library.Phrases)) { $byId[[string]$phrase.Id] = $phrase }
        $expected = @(
            Format-StepPhraseSentence -Phrase $byId['wait-for-text'] -Value @{ text = "Don't save" }
            Format-StepPhraseSentence -Phrase $byId['expect-text'] -Value @{ text = "Don't save" }
            Format-StepPhraseSentence -Phrase $byId['click'] -Value @{ label = "Don't save" }
            Format-StepPhraseSentence -Phrase $byId['click-button'] -Value @{ label = "Don't save" }
        )
        $sentences = @($answer.suggestions | ForEach-Object { $_.step })
        Assert-Equal ($expected -join '|') ($sentences -join '|')
        Assert-StringEqual 'click button "Don''t save"' $sentences[-1]
        $resolved = @(Resolve-StepPhrase -Sentence $sentences[-1] -Surface screen -Library $library)
        Assert-Equal 1 $resolved.Count
        Assert-StringEqual 'tapOn' $resolved[0]['action']
        Assert-StringEqual "Don't save" $resolved[0]['label']
        Assert-StringEqual 'word' $resolved[0]['match']
    }

    It 'suggests the primitive with nth when two targets match' {
        Use-WorkloadTestScreen -Line 'Save', 'Cancel', 'Save all'
        foreach ($findText in @('', 'all')) {
            $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen'; find = $findText }))
            $table = $script:Worker.Screen.Table
            Assert-Equal 3 $table.Count
            if ($findText) {
                $inlineEntries = @($snap.text -split "`n" | Where-Object { $_.StartsWith('- ', [StringComparison]::Ordinal) })
                Assert-Equal 1 $inlineEntries.Count
                Assert-True ($inlineEntries[0].StartsWith('- line "Save all"', [StringComparison]::Ordinal)) "the filtered view shows '$($inlineEntries[0])'"
            }
            $saveId = @($table.Keys | Where-Object { $table[$_].Text -ceq 'Save' })[0]
            $saveAllId = @($table.Keys | Where-Object { $table[$_].Text -ceq 'Save all' })[0]

            $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $saveId }))
            $sentences = @($answer.suggestions | Where-Object { $_.Contains('step') } | ForEach-Object { [string]$_.step })
            Assert-Equal 0 @($sentences | Where-Object { $_.StartsWith('click ', [StringComparison]::Ordinal) }).Count
            $primitive = [ordered]@{ action = 'tapOn'; fields = [ordered]@{ label = 'Save'; match = 'word'; nth = 1 } }
            $expectedJson = ConvertTo-Json -InputObject $primitive -Depth 4 -Compress
            $found = @($answer.suggestions | Where-Object { (ConvertTo-Json -InputObject $_ -Depth 4 -Compress) -ceq $expectedJson })
            Assert-Equal 1 $found.Count

            $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $saveAllId }))
            $sentences = @($answer.suggestions | ForEach-Object { [string]$_.step })
            Assert-True ($sentences -ccontains "click 'Save all'") "no click sentence for Save all: $($sentences -join '|')"
            Assert-True ($sentences -ccontains "click button 'Save all'") "no click button sentence for Save all: $($sentences -join '|')"
        }
    }

    It 'keeps references out of the journal and out of the step that ran' {
        Use-WorkloadTestScreen -Line 'Next', 'Cancel'
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        $ids = @($script:Worker.Screen.Table.Keys)
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $ids[0] }))
        $sentence = [string]$answer.suggestions[0].step
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadObserve'; description = 'Wait for Next'; fromStep = 'wait for text Next' } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = $sentence; intent = 'Wait for Next' }))
        Assert-StringEqual 'succeeded' $ran.state
        $entry = @(Get-WorkloadJournalEntry -Session $script:Session)[0]
        $journalLine = [IO.File]::ReadAllText((Join-Path $script:Session.Folder 'journal.ndjson'))
        $texts = @([string]$ran.ran, [string]$entry['yaml'], (ConvertTo-Json -InputObject $entry['authored'] -Depth 6 -Compress), $journalLine)
        foreach ($checked in $texts) {
            Assert-False ($checked.Contains('[ref=', [StringComparison]::Ordinal)) "a reference marker is in: $checked"
            foreach ($id in $ids) {
                Assert-False ($checked -cmatch ('(?<![A-Za-z0-9])' + $id + '(?![0-9])')) "the id $id is in: $checked"
            }
        }
    }

    It 'returns the snapshot path after a step and the text only from workload_snapshot' {
        Use-WorkloadTestScreen -Line 'Next'
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadObserve'; description = 'Look'; fromStep = 'wait for text Next' } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = 'wait for text Next'; intent = 'Look' }))
        Assert-StringEqual 'succeeded' $ran.state
        Assert-False $ran.Contains('text')
        Assert-True ((Split-Path -Leaf ([string]$ran.snapshot)) -cmatch '^screen-[0-9]{4}\.txt$') "the snapshot is '$($ran.snapshot)'"
        Assert-StringEqual $script:Session.Folder (Split-Path -Parent ([string]$ran.snapshot))
        Assert-True (Test-Path -LiteralPath $ran.snapshot -PathType Leaf) "no file at '$($ran.snapshot)'"
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-True ($snap.Contains('text') -and $snap.Contains('file')) "the snapshot keys are $(@($snap.Keys) -join ',')"
    }

    It 'withholds the frame path once the session is sensitive' {
        Use-WorkloadTestScreen -Line 'Next'
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen'; image = $true }))
        Assert-True ($snap.Contains('imagePath')) "no imagePath: $(@($snap.Keys) -join ',')"
        Enter-WorkloadSensitiveState -Session $script:Session -Seq 1
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen'; image = $true }))
        Assert-True ($snap['imageWithheld'] -eq $true) "the image was not withheld: $(@($snap.Keys) -join ',')"
        Assert-False $snap.Contains('imagePath')
    }

    It 'refuses a snapshot when the session is detached' {
        $script:Detached = New-WorkloadRefusal -Code 'workload_session_detached' -Key 'runner.workload_session_detached' -Arguments @{ tool = 'workload_snapshot'; reason = 'vm-stopped' }
        Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession { $script:Detached }
        $answer = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-True ([object]::ReferenceEquals($answer, $script:Detached)) "the refusal was changed: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)"
        Should -Invoke Get-VMScreenshot -ModuleName Test.WorkloadSession -Times 0 -Exactly
    }

    It 'answers workload_capture_failed when no frame was written' {
        Use-WorkloadTestScreen -Line 'Next'
        Mock Get-VMScreenshot -ModuleName Test.WorkloadSession { $OutFile }
        $before = @(Get-ChildItem -LiteralPath $script:Session.Folder -Filter 'screen-*.txt').Count
        $answer = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-False $answer.ok
        Assert-StringEqual 'workload_capture_failed' $answer.error.code
        Assert-Null $script:Worker.Screen.Table
        Assert-Equal $before @(Get-ChildItem -LiteralPath $script:Session.Folder -Filter 'screen-*.txt').Count
    }

    It 'marks a snapshot without word boxes and keeps the text another engine read' {
        Mock Get-TesseractWordBox -ModuleName Test.WorkloadSession { throw 'x' }
        Mock Get-EnabledOcrProvider -ModuleName Test.WorkloadSession { 'tesseract', 'winrt' }
        Mock Invoke-OcrProvider -ModuleName Test.WorkloadSession { 'only winrt read this' }
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-True ($snap.ok -eq $true) "the snapshot failed: $(ConvertTo-Json -InputObject $snap -Depth 6 -Compress)"
        Assert-Equal 1 $snap.entries
        $header = ($snap.text -split "`n")[0]
        Assert-True ($header.Contains('locator: none', [StringComparison]::Ordinal)) "the header is '$header'"
        Assert-True ($snap.text.Contains('- text "only winrt read this" [engine=winrt]', [StringComparison]::Ordinal)) "the text is: $($snap.text)"
        Assert-False ($snap.text.Contains('[ref=', [StringComparison]::Ordinal))
    }

    It 'lists the phrases the session can use and filters them' {
        $listed = Invoke-WorkloadPhraseRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ search = 'login' }))
        Assert-True ($listed.ok -eq $true) "phrases.list failed: $(ConvertTo-Json -InputObject $listed -Depth 6 -Compress)"
        Assert-Equal 1 @($listed.phrases).Count
        $login = @($listed.phrases)[0]
        Assert-StringEqual 'login' $login.id
        Assert-True (@($login.surfaces) -ccontains 'screen') "the surfaces are $(@($login.surfaces) -join ',')"
        $passwordSlot = @($login.slots | Where-Object { $_.name -ceq 'password' })
        Assert-Equal 1 $passwordSlot.Count
        Assert-StringEqual 'secret' $passwordSlot[0].type

        $all = Invoke-WorkloadPhraseRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{}))
        $phraseIds = [string[]]@($all.phrases | ForEach-Object { [string]$_.id })
        $sortedIds = [string[]]$phraseIds.Clone()
        [Array]::Sort($sortedIds, [StringComparer]::Ordinal)
        Assert-Equal ($sortedIds -join ',') ($phraseIds -join ',')
        Assert-Equal $phraseIds.Count $all.total
        Assert-False $all.truncated

        $script:Worker.Session = $null
        $without = Invoke-WorkloadPhraseRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ search = 'login' }))
        Assert-True ($without.ok -eq $true) "phrases.list without a session failed: $(ConvertTo-Json -InputObject $without -Depth 6 -Compress)"
    }

    It 'answers workload_no_session for a snapshot and a suggestion without a session' {
        $script:Worker.Session = $null
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'screen' }))
        Assert-StringEqual 'workload_no_session' $snap.error.code
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = 's1' }))
        Assert-StringEqual 'workload_no_session' $answer.error.code
        Should -Invoke Get-CycleScreenDir -ModuleName Test.WorkloadSession -Times 0 -Exactly
        Should -Invoke Get-VMScreenshot -ModuleName Test.WorkloadSession -Times 0 -Exactly
        Should -Invoke Get-TesseractWordBox -ModuleName Test.WorkloadSession -Times 0 -Exactly
    }
}

Describe 'the reply line of the worker shell' {
    BeforeAll {
        # The functions are lifted from the shell, which cannot be imported:
        # it opens pipes and serves a session when it runs.
        $shellPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'service/Invoke-WorkloadSession.ps1'
        $shellAst = Get-YurunaTestFileAst -Path $shellPath
        $liftedText = foreach ($functionName in @('ConvertTo-WorkloadReplyLine', 'ConvertTo-WorkloadResultFileText', 'ConvertTo-WorkloadProgressLine',
                'Read-WorkloadControlFrame', 'Get-WorkloadOperationMember', 'Write-WorkloadResultFile')) {
            (Get-YurunaTestFunctionAst -Ast $shellAst -Name $functionName).Extent.Text
        }
        . ([scriptblock]::Create($liftedText -join "`n"))
    }

    BeforeEach {
        Initialize-WorkloadTestSession
    }

    It 'withholds a reply the secret filter broke and answers the refusal with its id' {
        $checks = @(
            @{ Secret = '1234'; ReplyId = 'r7'; Answer = ([ordered]@{ ok = $true; snapshot = 1234 }) }
            @{ Secret = 'type'; ReplyId = 'r8'; Answer = ([ordered]@{ ok = $true }) }
            @{ Secret = 'result'; ReplyId = 'r9'; Answer = ([ordered]@{ ok = $true }) }
        )
        foreach ($check in $checks) {
            Clear-SequenceSecret
            $null = Register-SequenceSecret -Value $check.Secret
            $line = ConvertTo-WorkloadReplyLine -Id $check.ReplyId -Result $check.Answer
            $frame = ConvertFrom-WorkloadFrameLine -Line $line
            Assert-StringEqual 'reply' $frame['type']
            Assert-StringEqual $check.ReplyId $frame['id']
            Assert-False $frame['result']['ok']
            Assert-StringEqual 'workload_secret_filter_failed' $frame['result']['error']['code']
        }
    }

    It 'sends a reply the secret filter leaves readable, with the value hidden' {
        $null = Register-SequenceSecret -Value 'S3cr3t-reply'
        $line = ConvertTo-WorkloadReplyLine -Id 'r10' -Result ([ordered]@{ ok = $true; note = 'x S3cr3t-reply y' })
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        Assert-StringEqual 'r10' $frame['id']
        Assert-True ($frame['result']['ok'] -eq $true) "the reply is $line"
        Assert-StringEqual 'x *** y' $frame['result']['note']
        Assert-False ($line.Contains('S3cr3t-reply', [StringComparison]::Ordinal))

        Clear-SequenceSecret
        $null = Register-SequenceSecret -Value 'text'
        $line = ConvertTo-WorkloadReplyLine -Id 'r11' -Result ([ordered]@{ ok = $true; text = 'abc' })
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        Assert-StringEqual 'r11' $frame['id']
        Assert-True ($frame['result']['ok'] -eq $true) "the reply is $line"
        Assert-False ($frame['result'].Contains('text'))
        Assert-StringEqual 'abc' $frame['result']['***']
    }

    It 'writes the refusal into a result file the secret filter broke' {
        $null = Register-SequenceSecret -Value '1234'
        $fileText = ConvertTo-WorkloadResultFileText -Result ([ordered]@{ ok = $true; count = 1234 })
        $parsed = ConvertFrom-Json -InputObject $fileText -AsHashtable -DateKind String -NoEnumerate
        Assert-False $parsed['ok']
        Assert-StringEqual 'workload_secret_filter_failed' $parsed['error']['code']

        Clear-SequenceSecret
        $null = Register-SequenceSecret -Value 'S3cr3t-file'
        $fileText = ConvertTo-WorkloadResultFileText -Result ([ordered]@{ ok = $true; note = 'x S3cr3t-file y' })
        $parsed = ConvertFrom-Json -InputObject $fileText -AsHashtable -DateKind String -NoEnumerate
        Assert-True ($parsed['ok'] -eq $true) "the file text is $fileText"
        Assert-StringEqual 'x *** y' $parsed['note']
        Assert-False ($fileText.Contains('S3cr3t-file', [StringComparison]::Ordinal))
    }

    It 'sends no progress frame the secret filter broke' {
        $null = Register-SequenceSecret -Value 'progress'
        Assert-Null (ConvertTo-WorkloadProgressLine -Id 'r3' -Completed 0 -Total 2 -Label 'a')

        Clear-SequenceSecret
        $null = Register-SequenceSecret -Value 'S3cr3t-label'
        $line = ConvertTo-WorkloadProgressLine -Id 'r3' -Completed 0 -Total 2 -Label 'x S3cr3t-label'
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        Assert-StringEqual 'progress' $frame['type']
        Assert-StringEqual 'r3' $frame['id']
        Assert-Equal 0 $frame['completed']
        Assert-Equal 2 $frame['total']
        Assert-StringEqual 'x ***' $frame['label']

        Clear-SequenceSecret
        $null = Register-SequenceSecret -Value 'type'
        Assert-Null (ConvertTo-WorkloadProgressLine -Id 'r3' -Completed 0 -Total 2 -Label 'a')
    }

    It 'stops reading the request pipe at its end and says stop' {
        $script:Lines = [System.Collections.Generic.Queue[object]]::new()
        $script:ReadsStarted = 0
        foreach ($queued in @('{"type":"cancel","id":"r4"}', '{"type":"mask.ack","id":2}', '{"type":"cancel","id":"r5"}')) {
            $script:Lines.Enqueue([Threading.Tasks.Task]::FromResult[string]($queued))
        }
        $pending = [Threading.Tasks.TaskCompletionSource[string]]::new()
        $script:Lines.Enqueue($pending.Task)
        $channel = @{ Read = $null; MaskAck = 0; ReadNext = { $script:ReadsStarted++; if ($script:Lines.Count -eq 0) { throw 'a read was started after the end of input' }; $script:Lines.Dequeue() } }
        $channel.Read = & $channel.ReadNext
        $state = @{ Session = $null
            Screen = @{ Table = $null; Boxes = @(); Counter = 0; Ordinal = 0 }
            Page = @{ Table = $null; Counter = 0; Ordinal = 0 }
            PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = 'r5'; MaskId = 0 }

        Read-WorkloadControlFrame -Worker $state -Pipe $channel
        Assert-True $state.Stop
        Assert-False $state.ParentLost
        Assert-Equal 2 $channel.MaskAck
        Assert-True ([object]::ReferenceEquals($channel.Read, $pending.Task)) 'the pending read is not the kept task'
        Assert-Equal 4 $script:ReadsStarted

        Read-WorkloadControlFrame -Worker $state -Pipe $channel -WaitMilliseconds 50
        Assert-False $state.ParentLost
        Assert-Equal 2 $channel.MaskAck
        Assert-Equal 4 $script:ReadsStarted

        $pending.SetResult([NullString]::Value)
        Read-WorkloadControlFrame -Worker $state -Pipe $channel
        Read-WorkloadControlFrame -Worker $state -Pipe $channel
        Assert-True $state.ParentLost
        Assert-True $state.Stop
        Assert-Equal 4 $script:ReadsStarted

        $faultedState = @{ Session = $null; PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = $null; MaskId = 0 }
        $faultedChannel = @{ Read = [Threading.Tasks.Task]::FromException[string]([IO.IOException]::new('x')); MaskAck = 0; ReadNext = $channel.ReadNext }
        Read-WorkloadControlFrame -Worker $faultedState -Pipe $faultedChannel -WaitMilliseconds 50
        Assert-True $faultedState.ParentLost
        Assert-Null $faultedChannel.Rejected

        $script:Lines.Clear()
        $script:Lines.Enqueue([Threading.Tasks.Task]::FromResult[string]('{"type":"request","id":"r9","method":"session.end","params":{"reason":"client-request"}}'))
        $script:Lines.Enqueue([Threading.Tasks.Task]::FromResult[string]('not json'))
        $stillPending = [Threading.Tasks.TaskCompletionSource[string]]::new()
        $script:Lines.Enqueue($stillPending.Task)
        $rejectState = @{ Session = $null; PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = $null; MaskId = 0 }
        $rejectChannel = @{ Read = $null; MaskAck = 0; ReadNext = $channel.ReadNext }
        $rejectChannel.Read = & $rejectChannel.ReadNext
        Read-WorkloadControlFrame -Worker $rejectState -Pipe $rejectChannel
        Assert-StringEqual 'r9' $rejectState.PendingEnd['id']
        Assert-True $rejectState.Stop
        Assert-True $rejectState.ParentLost
        Assert-True ($rejectChannel.Rejected -is [string] -and $rejectChannel.Rejected.Length -gt 0) 'the rejected line was not recorded'
        Assert-True ($script:Lines.Count -eq 1 -and [object]::ReferenceEquals($script:Lines.Peek(), $stillPending.Task)) 'a read was started after the rejected line'
    }

    It 'states the effect of an operation whose answer the shell replaces' {
        $member = Get-WorkloadOperationMember -Answer $null -Counted $true
        Assert-Equal 'failed|True|uncertain' ('{0}|{1}|{2}' -f $member.state, $member.dispatched, $member.effect)
        $member = Get-WorkloadOperationMember -Answer $null -Counted $false
        Assert-Equal 'failed|False|none-proven' ('{0}|{1}|{2}' -f $member.state, $member.dispatched, $member.effect)
        $member = Get-WorkloadOperationMember -Answer ([ordered]@{ ok = $true; state = 'succeeded'; dispatched = $true; effect = 'applied' }) -Counted $false
        Assert-Equal 'succeeded|True|applied' ('{0}|{1}|{2}' -f $member.state, $member.dispatched, $member.effect)
        $member = Get-WorkloadOperationMember -Answer ([ordered]@{ ok = $true; state = 'other'; effect = 'other' }) -Counted $true
        Assert-Equal 'failed|True|uncertain' ('{0}|{1}|{2}' -f $member.state, $member.dispatched, $member.effect)

        $null = Register-SequenceSecret -Value '1234'
        $members = [ordered]@{ state = 'succeeded'; dispatched = $true; effect = 'applied' }
        $line = ConvertTo-WorkloadReplyLine -Id 'r12' -Result ([ordered]@{ ok = $true; seq = 1234 }) -Operation $members
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        Assert-StringEqual 'r12' $frame['id']
        Assert-False $frame['result']['ok']
        Assert-StringEqual 'workload_secret_filter_failed' $frame['result']['error']['code']
        Assert-StringEqual 'succeeded' $frame['result']['state']
        Assert-True ($frame['result']['dispatched'] -eq $true) "the reply is $line"
        Assert-StringEqual 'applied' $frame['result']['effect']
        $line = ConvertTo-WorkloadReplyLine -Id 'r12' -Result ([ordered]@{ ok = $true; seq = 1234 })
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        Assert-Equal 'ok,error' (@($frame['result'].Keys) -join ',')
    }

    It 'gives up a result file it cannot replace and leaves no temporary file' {
        Mock Start-Sleep { }
        $resultFolder = Join-Path $TestDrive 'result-files'
        $null = New-Item -ItemType Directory -Path $resultFolder -Force
        $journalFile = Join-Path $resultFolder 'journal.result.json'
        Assert-True (Write-WorkloadResultFile -Path $journalFile -Content '{"ok":true}') 'the journal result file was not written'
        Assert-StringEqual '{"ok":true}' ([IO.File]::ReadAllText($journalFile))
        $failureFile = Join-Path $resultFolder 'failure.result.json'
        $null = New-Item -ItemType Directory -Path $failureFile
        Assert-False (Write-WorkloadResultFile -Path $failureFile -Content '{"ok":true}')
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $resultFolder -Filter '*.tmp').Count
    }
}

Describe 'the page surface of a session' {
    BeforeAll {
        # The engine of the top-level BeforeAll loaded the page verbs; the
        # session module is imported here so its commands exist and can be mocked.
        Import-Module (Join-Path $PSScriptRoot 'Test.WebSession.psm1') -Force -Global -DisableNameChecking

        function New-PageTestEntry {
            <#
            .SYNOPSIS
                One forest entry in the shape Read-WebPageForest returns.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory forest entry.')]
            param(
                [Parameter(Mandatory)][string]$Role,
                [AllowEmptyString()][string]$Name = '',
                [int]$Depth = 1,
                [int]$Backend = 0,
                [hashtable]$Props = @{},
                [AllowNull()]$Value = $null
            )
            return @{ Role = $Role; Name = $Name; Norm = (ConvertTo-WebName -Text $Name); Depth = $Depth; Props = $Props; Value = $Value
                InTextControl = $false; Address = @{ SessionId = 'S1'; BackendNodeId = $Backend; Owners = [object[]]@() } }
        }

        function Get-PageTestLoginForm {
            <#
            .SYNOPSIS
                The login form: heading and title Sign in, a Sign in button and two text fields.
            #>
            param([string]$ButtonName = 'Sign in', [AllowNull()]$FieldValue = $null)
            return @(
                New-PageTestEntry -Role 'RootWebArea' -Name $script:ForestTitle -Depth 0 -Backend 1
                New-PageTestEntry -Role 'heading' -Name 'Sign in' -Depth 1 -Backend 2 -Props @{ level = 1 }
                New-PageTestEntry -Role 'StaticText' -Name 'Sign in' -Depth 2
                New-PageTestEntry -Role 'button' -Name $ButtonName -Depth 1 -Backend 3
                New-PageTestEntry -Role 'textbox' -Name 'Username' -Depth 1 -Backend 4 -Value $FieldValue
                New-PageTestEntry -Role 'textbox' -Name 'Password' -Depth 1 -Backend 5
            )
        }

        function Get-PageTestReference {
            <#
            .SYNOPSIS
                The ids of the current page table whose entry has a role and a name, in order.
            #>
            param([Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Label)
            $table = $script:Worker.Page.Table
            return @($table.Keys | Where-Object { [string]$table[$_].Role -ceq $Role -and [string]$table[$_].Name -ceq $Label })
        }
    }

    BeforeEach {
        Initialize-WorkloadTestSession
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:Events.Add($EventRecord) }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:PageEntry = @{ VMName = 'never-a-real-vm'; Cdp = @{ Page = @{ Url = 'http://localhost:8080/login'; Generation = 3 } } }
        $script:ForestTitle = 'Sign in'
        $script:ForestEntries = { Get-PageTestLoginForm }
        Mock Get-WorkloadSessionRefusal -ModuleName Test.WorkloadSession { $null }
        Mock Save-WorkloadScreenSnapshot -ModuleName Test.WorkloadSession { [ordered]@{ ok = $true; file = 'screen-0001.txt' } }
        Mock Get-GuestWebSession -ModuleName Test.WorkloadSession { $script:PageEntry }
        Mock Test-WebCdpOpen -ModuleName Test.WorkloadSession { $true }
        Mock Read-WebPageForest -ModuleName Test.WorkloadSession {
            $page = $script:PageEntry.Cdp.Page
            @{ Entries = [object[]]@(& $script:ForestEntries); Text = 'Sign in'; Title = $script:ForestTitle; Url = [string]$page.Url
                Generation = [int]$page.Generation; Incomplete = $false; Truncated = $false }
        }
        Mock Close-GuestWebSession -ModuleName Test.WorkloadSession { 0 }
    }

    It 'answers workload_no_page when no page is open' {
        Mock Get-GuestWebSession -ModuleName Test.WorkloadSession { $null }
        $answer = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-False $answer.ok
        Assert-StringEqual 'workload_no_page' $answer.error.code
        Mock Get-GuestWebSession -ModuleName Test.WorkloadSession { $script:PageEntry }
        Mock Test-WebCdpOpen -ModuleName Test.WorkloadSession { $false }
        $answer = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-False $answer.ok
        Assert-StringEqual 'workload_no_page' $answer.error.code
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:Session.Folder -Filter 'page-*.txt').Count
        Should -Invoke Read-WebPageForest -ModuleName Test.WorkloadSession -Times 0 -Exactly
    }

    It 'writes page-0001.txt and keeps the reference counter' {
        $first = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-True ($first.ok -eq $true) "the snapshot failed: $(ConvertTo-Json -InputObject $first -Depth 6 -Compress)"
        Assert-StringEqual 'page' $first.surface
        Assert-Equal 1 $first.snapshot
        Assert-StringEqual 'http://localhost:8080/login' $first.url
        Assert-StringEqual 'Sign in' $first.title
        Assert-True ($first.text.StartsWith('# surface: page   snapshot: 1   url: http://localhost:8080/login   title: Sign in', [StringComparison]::Ordinal)) "the text is: $($first.text)"
        Assert-StringEqual (Join-Path $script:Session.Folder 'page-0001.txt') $first.file
        Assert-True (Test-Path -LiteralPath $first.file -PathType Leaf) "no file at '$($first.file)'"
        $firstIds = @($script:Worker.Page.Table.Keys)
        Assert-True ($firstIds.Count -gt 0) 'the first snapshot has no reference'
        $second = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-StringEqual (Join-Path $script:Session.Folder 'page-0002.txt') $second.file
        $secondIds = @($script:Worker.Page.Table.Keys)
        Assert-Equal ([long]$firstIds[-1].Substring(1) + 1) ([long]$secondIds[0].Substring(1))
    }

    It 'ignores the image argument on the page surface' {
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page'; image = $true }))
        Assert-True ($snap.ok -eq $true) "the snapshot failed: $(ConvertTo-Json -InputObject $snap -Depth 6 -Compress)"
        Assert-False $snap.Contains('imagePath')
        Assert-False $snap.Contains('imageWithheld')
    }

    It 'masks a session secret in a name, a value tag, the title and the URL' {
        $secretText = 'Fixture-Secret-77'
        $null = Register-SequenceSecret -Value $secretText
        $script:ForestTitle = "Welcome $secretText"
        $script:ForestEntries = { Get-PageTestLoginForm -ButtonName 'Send Fixture-Secret-77' -FieldValue 'Fixture-Secret-77' }
        $script:PageEntry.Cdp.Page.Url = "http://localhost:8080/login?token=$secretText"
        $snap = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-True ($snap.ok -eq $true) "the snapshot failed: $(ConvertTo-Json -InputObject $snap -Depth 6 -Compress)"
        $fileText = [IO.File]::ReadAllText($snap.file)
        $replyText = ConvertTo-Json -InputObject $snap -Depth 8
        foreach ($checked in @($fileText, [string]$snap.text)) {
            foreach ($masked in @('- button "Send ***"', '[value="***"]', 'title: Welcome ***', 'url: http://localhost:8080/login?token=***')) {
                Assert-True ($checked.Contains($masked, [StringComparison]::Ordinal)) "'$masked' is not in: $checked"
            }
        }
        Assert-StringEqual 'Welcome ***' $snap.title
        Assert-StringEqual 'http://localhost:8080/login?token=***' $snap.url
        foreach ($checked in @($fileText, $replyText)) {
            Assert-False ($checked.Contains($secretText, [StringComparison]::Ordinal)) "the secret is in: $checked"
        }
    }

    It 'answers a reference of an earlier page snapshot with workload_stale_reference' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $firstId = @($script:Worker.Page.Table.Keys)[0]
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $firstId }))
        Assert-False $stale.ok
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
        Assert-True ($stale.error.message.Contains($firstId, [StringComparison]::Ordinal)) "the message does not name ${firstId}: $($stale.error.message)"
    }

    It 'answers a page reference that a navigation made stale with workload_stale_reference' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $buttonId = @(Get-PageTestReference -Role 'button' -Label 'Sign in')[0]
        $script:PageEntry.Cdp.Page.Generation = 4
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $buttonId }))
        Assert-False $stale.ok
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
    }

    It 'answers a reference whose element is gone with workload_stale_reference' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $buttonId = @(Get-PageTestReference -Role 'button' -Label 'Sign in')[0]
        $script:ForestEntries = { @(Get-PageTestLoginForm | Where-Object { $_.Role -cne 'button' }) }
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $buttonId }))
        Assert-False $stale.ok
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
    }

    It 'answers workload_no_page for a reference when the page has closed' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $buttonId = @(Get-PageTestReference -Role 'button' -Label 'Sign in')[0]
        Mock Test-WebCdpOpen -ModuleName Test.WorkloadSession { $false }
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $buttonId }))
        Assert-False $answer.ok
        Assert-StringEqual 'workload_no_page' $answer.error.code
    }

    It 'drops the page references when the worker resets its surface' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $ids = @($script:Worker.Page.Table.Keys)
        $kept = @($script:Worker.Page.Counter, $script:Worker.Page.Ordinal)
        Reset-WorkloadSurface -Session $script:Session -Reason replay
        $stale = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $ids[0] }))
        Assert-StringEqual 'workload_stale_reference' $stale.error.code
        Assert-Equal ($kept -join ',') (@($script:Worker.Page.Counter, $script:Worker.Page.Ordinal) -join ',')
        $next = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        Assert-Equal 2 $next.snapshot
        Assert-Equal ([long]$ids[-1].Substring(1) + 1) ([long]@($script:Worker.Page.Table.Keys)[0].Substring(1))
    }

    It 'suggests a sentence for a unique element and a primitive with nth for a duplicate' {
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $buttonId = @(Get-PageTestReference -Role 'button' -Label 'Sign in')[0]
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $buttonId }))
        Assert-True ($answer.ok -eq $true) "the suggestion failed: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)"
        Assert-StringEqual 'button' $answer.target.role
        Assert-StringEqual 'Sign in' $answer.target.name
        Assert-StringEqual "click button 'Sign in'" ([string]$answer.suggestions[0].step)
        Assert-StringEqual 'page' ([string]$answer.suggestions[0].on)

        $script:ForestEntries = {
            @(
                New-PageTestEntry -Role 'RootWebArea' -Name 'Items' -Depth 0 -Backend 1
                New-PageTestEntry -Role 'list' -Depth 1 -Backend 2
                New-PageTestEntry -Role 'listitem' -Depth 2 -Backend 3
                New-PageTestEntry -Role 'button' -Name 'Delete' -Depth 3 -Backend 4
                New-PageTestEntry -Role 'listitem' -Depth 2 -Backend 5
                New-PageTestEntry -Role 'button' -Name 'Delete' -Depth 3 -Backend 6
            )
        }
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $deleteIds = @(Get-PageTestReference -Role 'button' -Label 'Delete')
        Assert-Equal 2 $deleteIds.Count
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $deleteIds[1] }))
        Assert-True ($answer.ok -eq $true) "the suggestion failed: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)"
        Assert-Equal 0 @($answer.suggestions | Where-Object { $_.Contains('step') }).Count
        Assert-Equal 1 @($answer.suggestions).Count
        $primitive = [ordered]@{ action = 'webClick'; fields = [ordered]@{ role = 'button'; name = 'Delete'; nth = 2 } }
        Assert-StringEqual (ConvertTo-Json -InputObject $primitive -Depth 4 -Compress) (ConvertTo-Json -InputObject $answer.suggestions[0] -Depth 4 -Compress)
    }

    It 'suggests <Sentence> for a <Role>' -ForEach @(
        @{ Role = 'button'; Label = 'Go'; Sentence = 'click button Go' }
        @{ Role = 'link'; Label = 'Next'; Sentence = 'click link Next' }
        @{ Role = 'textbox'; Label = 'Email'; Sentence = 'fill Email with <text>' }
        @{ Role = 'combobox'; Label = 'Country'; Sentence = 'select <option> in Country' }
        @{ Role = 'checkbox'; Label = 'Agree'; Sentence = 'check Agree|uncheck Agree' }
        @{ Role = 'heading'; Label = 'Welcome'; Sentence = 'expect heading Welcome' }
        @{ Role = 'image'; Label = 'Logo'; Sentence = 'expect text Logo' }
    ) {
        $script:ElementRow = @{ Role = $Role; Label = $Label }
        $script:ForestEntries = {
            @(
                New-PageTestEntry -Role 'RootWebArea' -Name 'Fixture' -Depth 0 -Backend 1
                New-PageTestEntry -Role $script:ElementRow.Role -Name $script:ElementRow.Label -Depth 1 -Backend 2
            )
        }
        $null = Invoke-WorkloadSnapshotRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ surface = 'page' }))
        $elementId = @(Get-PageTestReference -Role $Role -Label $Label)[0]
        $answer = Invoke-WorkloadSuggestRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ ref = $elementId }))
        Assert-True ($answer.ok -eq $true) "the suggestion failed: $(ConvertTo-Json -InputObject $answer -Depth 6 -Compress)"
        $sentences = @($answer.suggestions | Where-Object { $_.Contains('step') } | ForEach-Object { [string]$_.step })
        Assert-StringEqual $Sentence ($sentences -join '|')
        $library = Get-SequencePhraseLibrary
        foreach ($sentenceText in $sentences) {
            $resolved = @(Resolve-StepPhrase -Sentence $sentenceText -Surface page -Library $library)
            Assert-True ($resolved.Count -ge 1) "'$sentenceText' does not resolve on the page surface"
            Assert-True ([string]$resolved[0]['action']).StartsWith('web', [StringComparison]::Ordinal) "'$sentenceText' resolves to $($resolved[0]['action'])"
        }
        foreach ($suggestion in @($answer.suggestions | Where-Object { $_.Contains('step') })) { Assert-StringEqual 'page' ([string]$suggestion.on) }
        $primitives = @($answer.suggestions | Where-Object { $_.Contains('action') })
        if ($Role -ceq 'image') {
            Assert-Equal 1 $primitives.Count
            $expected = [ordered]@{ action = 'webClick'; fields = [ordered]@{ role = 'image'; name = 'Logo' } }
            Assert-StringEqual (ConvertTo-Json -InputObject $expected -Depth 4 -Compress) (ConvertTo-Json -InputObject $primitives[0] -Depth 4 -Compress)
        } else {
            Assert-Equal 0 $primitives.Count
        }
    }

    It 'takes the page snapshot after a page step and reports the navigation' {
        $script:PageRun = {
            $script:PageEntry.Cdp.Page.Generation = [int]$script:PageEntry.Cdp.Page.Generation + 1
            $script:PageEntry.Cdp.Page.Url = 'http://localhost:8080/next?a=1'
        }
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadInput'; description = 'Sign in'; fromStep = "click button 'Sign in'"; run = $script:PageRun } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = "click button 'Sign in'"; on = 'page'; intent = 'Sign in' }))
        Assert-StringEqual 'succeeded' $ran.state
        Assert-StringEqual 'page' $ran.surface
        Assert-StringEqual (Join-Path $script:Session.Folder 'page-0001.txt') ([string]$ran.snapshot)
        Assert-False $ran.Contains('text')
        Assert-StringEqual 'http://localhost:8080/next?a=1' $ran.page.url
        Assert-StringEqual 'Sign in' $ran.page.title
        Assert-StringEqual 'navigated to /next?a=1' (@($ran.events) -join '|')
        Assert-Equal 1 @($ran.events).Count
        $keys = @($ran.Keys)
        Assert-Equal ([array]::IndexOf($keys, 'events') - 1) ([array]::IndexOf($keys, 'page')) -Because 'page stands directly before events'
        Should -Invoke Save-WorkloadScreenSnapshot -ModuleName Test.WorkloadSession -Times 0 -Exactly
        $entry = @(Get-WorkloadJournalEntry -Session $script:Session)[0]
        Assert-StringEqual 'page' ([string]$entry['surface'])
        Assert-True ([string]$entry['yaml']).Contains('on: page') "the yaml is: $($entry['yaml'])"
        Assert-False ([string]$entry['yaml']).Contains('[ref=') "the yaml is: $($entry['yaml'])"
    }

    It 'reports no navigation for a page step that stays on its page' {
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadInput'; description = 'Sign in'; fromStep = "click button 'Sign in'" } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = "click button 'Sign in'"; on = 'page'; intent = 'Sign in' }))
        Assert-StringEqual 'succeeded' $ran.state
        Assert-StringEqual 'page' $ran.surface
        Assert-Equal 0 @($ran.events).Count
    }

    It 'runs a page verb through workload_action as a page operation' {
        $ran = Invoke-WorkloadActionRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; action = 'webExpect'; fields = [ordered]@{ text = 'Sign in' }; intent = 'See the form' }))
        Assert-StringEqual 'failed' $ran.state
        Assert-StringEqual 'page' $ran.surface
        Assert-StringEqual (Join-Path $script:Session.Folder 'page-0001.txt') ([string]$ran.snapshot)
        Assert-StringEqual 'plan_invalid' $ran.error.class
        Assert-StringEqual 'none-proven' $ran.effect
    }

    It 'reports workload_no_page as the snapshot error after webClose' {
        Mock Get-GuestWebSession -ModuleName Test.WorkloadSession { $null }
        $ran = Invoke-WorkloadActionRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; action = 'webClose'; fields = [ordered]@{}; intent = 'Close the page' }))
        Assert-StringEqual 'succeeded' $ran.state
        Assert-Null $ran.snapshot
        Assert-StringEqual 'workload_no_page' $ran.snapshotError
        Assert-True $ran.Contains('page') 'the result has no page member'
        Assert-Null $ran.page
    }

    It 'keeps the screen result without a page member' {
        Mock Resolve-StepPhrase -ModuleName Test.WorkloadSession { [ordered]@{ action = 'workloadObserve'; description = 'Look'; fromStep = 'wait for text Next' } }
        $ran = Invoke-WorkloadStepRequest -Call (Get-WorkloadTestCall -Params ([ordered]@{ operationId = 'op-1'; step = 'wait for text Next'; intent = 'Look' }))
        Assert-StringEqual 'succeeded' $ran.state
        Assert-StringEqual 'screen' $ran.surface
        Assert-False $ran.Contains('page')
    }

    It 'closes the web sessions of the worker' {
        foreach ($expectedReason in @('replay-start', 'replay', 'session-end')) {
            $surface = @{ Screen = @{ Table = @{}; Boxes = @(1) }; Page = @{ Table = @{} } }
            Reset-WorkloadSurface -Session @{ SurfaceState = $surface } -Reason $expectedReason
            Should -Invoke Close-GuestWebSession -ModuleName Test.WorkloadSession -Times 1 -Exactly -ParameterFilter { $All -and $Reason -eq $expectedReason }
            Assert-Null $surface.Screen.Table
            Assert-Null $surface.Page.Table
        }
        Reset-WorkloadSurface -Session @{} -Reason 'session-end'
        Should -Invoke Close-GuestWebSession -ModuleName Test.WorkloadSession -Times 2 -Exactly -ParameterFilter { $All -and $Reason -eq 'session-end' }
    }

    It 'shows the page account in the failure view' {
        $record = [ordered]@{ reason = 'step-failed'; failureClass = 'web_step_failed'; actionVerb = 'webClick'; stepNumber = 1; totalSteps = 1
            context = [ordered]@{ stepFailurePhase = 'input'
                causeDetail = [ordered]@{ hostInputFault = $null; loginEcho = $null
                    web = [ordered]@{ verb = 'webClick'; kind = 'ambiguous'; effect = 'none-proven'; matchCount = 2 } } } }
        $view = ConvertTo-WorkloadFailureView -Record $record -Session $script:Session
        Assert-StringEqual 'ambiguous' ([string]$view['web']['kind'])
        $keys = @($view.Keys)
        $faultAt = [array]::IndexOf($keys, 'hostInputFault')
        Assert-True ($faultAt -ge 0) 'the view has no hostInputFault'
        Assert-StringEqual 'web' $keys[$faultAt + 1]
        $crash = ConvertTo-WorkloadFailureView -Record ([ordered]@{ reason = 'crash'; failureClass = 'unknown' }) -Session $script:Session
        Assert-True $crash.Contains('web') 'the crash view has no web member'
        Assert-Null $crash['web']
    }

    It 'reports the effect the page account proves' {
        $withAccount = {
            param([string]$Effect)
            [ordered]@{ reason = 'step-failed'; failureClass = 'web_step_failed'; stepEffect = 'unknown'
                context = [ordered]@{ causeDetail = [ordered]@{ web = [ordered]@{ verb = 'webClick'; kind = 'not_found'; effect = $Effect } } } }
        }
        foreach ($proven in @('applied', 'uncertain', 'none-proven')) {
            $answer = Get-WorkloadEffectState -Steps @(@{ action = 'workloadInput' }) -Completed 0 -Started 1 -Ok $false -Record (& $withAccount $proven)
            Assert-StringEqual $proven $answer
        }
        $bare = [ordered]@{ reason = 'step-failed'; failureClass = 'web_step_failed'; stepEffect = 'unknown'; context = [ordered]@{ causeDetail = [ordered]@{} } }
        Assert-StringEqual 'uncertain' (Get-WorkloadEffectState -Steps @(@{ action = 'workloadInput' }) -Completed 0 -Started 1 -Ok $false -Record $bare)
        foreach ($proven in @('applied', 'uncertain')) {
            $answer = Get-WorkloadEffectState -Steps @(@{ action = 'workloadObserve' }) -Completed 0 -Started 1 -Ok $false -Record (& $withAccount $proven)
            Assert-StringEqual 'none-proven' $answer
        }
    }

    It 'reports the guest change an observing step''s handler recorded' {
        $observe = @(@{ action = 'workloadObserve' }, @{ action = 'workloadObserve' })
        Assert-StringEqual 'applied' (Get-WorkloadEffectState -Steps $observe -Completed 2 -Started 2 -Ok $true -GuestChange ([ordered]@{ '1' = 'applied' }))
        Assert-StringEqual 'applied' (Get-WorkloadEffectState -Steps $observe -Completed 1 -Started 2 -Ok $false -GuestChange ([ordered]@{ '2' = 'applied' }))
        Assert-StringEqual 'uncertain' (Get-WorkloadEffectState -Steps $observe -Completed 1 -Started 2 -Ok $false -GuestChange ([ordered]@{ '2' = 'uncertain' }))
        Assert-StringEqual 'none-proven' (Get-WorkloadEffectState -Steps $observe -Completed 2 -Started 2 -Ok $true -GuestChange $null)
    }
}
