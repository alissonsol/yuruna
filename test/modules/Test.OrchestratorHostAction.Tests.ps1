<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42c7e1a9-5b3d-4f0e-9a6c-2d8f1b7e4a53
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test orchestrator host-action failure-reason pester
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
    A host action that exits non-zero names its cause in the failure reason:
    the orchestrator keeps the action's last lines and quotes its last error
    line instead of reporting only the exit code.
.DESCRIPTION
    The tail keeper and the detail picker are exercised directly, and the
    host-action runner is driven with a real child script so the stderr of a
    failing action reaches the reason exactly as the transcript would show
    it, console color sequences and all.
#>
BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Orchestrator.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
    $script:Orchestrator = Get-Module -Name 'Test.Orchestrator'
    function Invoke-InOrchestrator {
        param([scriptblock]$Body, [object[]]$Argument = @())
        return (& $script:Orchestrator $Body @Argument)
    }
    # The comma keeps the empty list from being unrolled into nothing.
    function Get-FreshTail { return ,([System.Collections.Generic.List[string]]::new()) }
}

Describe 'Add-OrchestratorOutputTail' {
    It 'keeps lines in order, plain, and no more than the limit' {
        $tail = Get-FreshTail
        foreach ($i in 1..45) {
            Invoke-InOrchestrator { param($t, $l) Add-OrchestratorOutputTail -Tail $t -Line $l } @($tail, "line $i")
        }
        Assert-Equal 40 $tail.Count -Because 'the default limit holds'
        Assert-StringEqual 'line 6' $tail[0] 'the oldest lines were dropped first'
        Assert-StringEqual 'line 45' $tail[$tail.Count - 1]
    }

    It 'strips console color sequences and ignores blank lines' {
        $tail = Get-FreshTail
        $colored = "$([char]27)[31;1mWrite-Error: $([char]27)[31;1mRegion edges are not live$([char]27)[0m"
        foreach ($line in @('', '   ', $null, $colored, "`t")) {
            Invoke-InOrchestrator { param($t, $l) Add-OrchestratorOutputTail -Tail $t -Line $l } @($tail, $line)
        }
        Assert-Equal 1 $tail.Count -Because 'only the one line with text is kept'
        Assert-StringEqual 'Write-Error: Region edges are not live' $tail[0]
    }

    It 'honors a caller-chosen limit' {
        $tail = Get-FreshTail
        foreach ($i in 1..5) {
            Invoke-InOrchestrator { param($t, $l) Add-OrchestratorOutputTail -Tail $t -Line $l -Limit 2 } @($tail, "line $i")
        }
        Assert-Equal 2 $tail.Count
        Assert-StringEqual 'line 4' $tail[0]
    }
}

Describe 'Get-OrchestratorHostActionDetail' {
    It 'quotes the last error line without its console prefix' {
        $tail = Get-FreshTail
        foreach ($line in @('===== [amisad-core] exited 0 =====', 'Write-Error: first failure', 'Starting amisad-edge-a + amisad-edge-b.', 'Write-Error: Region edges are not live: amisad-edge-b (UTM would not act)', 'some trailing line')) { $tail.Add($line) }
        $detail = Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t } @(,$tail)
        Assert-StringEqual 'Region edges are not live: amisad-edge-b (UTM would not act)' $detail
    }

    It 'recognizes the <Prefix> prefix' -TestCases @(
        @{ Prefix = 'ERROR: ' }
        @{ Prefix = 'Error: ' }
        @{ Prefix = 'Write-Error:' }
    ) {
        param($Prefix)
        $tail = Get-FreshTail
        $tail.Add('context')
        $tail.Add("${Prefix}the cause")
        $tail.Add('after')
        $detail = Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t } @(,$tail)
        Assert-StringEqual 'the cause' $detail
    }

    It 'falls back to the last line when no line is an error' {
        $tail = Get-FreshTail
        foreach ($line in @('one', 'two', 'the last thing printed')) { $tail.Add($line) }
        Assert-StringEqual 'the last thing printed' (Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t } @(,$tail))
    }

    It 'returns an empty string for no tail at all' {
        Assert-StringEqual '' (Invoke-InOrchestrator { Get-OrchestratorHostActionDetail -Tail $null })
        Assert-StringEqual '' (Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t } @(,(Get-FreshTail)))
    }

    It 'caps the quoted text so a record stays a record' {
        $tail = Get-FreshTail
        $tail.Add('Write-Error: ' + ('x' * 2000))
        $detail = Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t -MaxLength 100 } @(,$tail)
        Assert-Equal 100 $detail.Length
        Assert-True $detail.EndsWith('...') 'the cut is marked'
    }
}

Describe 'Invoke-OrchestratorHostAction keeps what a failing action printed' {
    BeforeAll {
        $script:ActionDir = Join-Path $TestDrive 'host-action'
        $null = New-Item -ItemType Directory -Force -Path $script:ActionDir
        $script:SequencePath = Join-Path $script:ActionDir 'initialize-lab.yml'
        Set-Content -LiteralPath $script:SequencePath -Value 'name: initialize-lab' -Encoding utf8
        @'
Write-Information 'Warm-up on the fixture host.' -InformationAction Continue
Write-Information '===== [amisad-core] exited 0 =====' -InformationAction Continue
Write-Error 'Region edges are not live: amisad-edge-b (UTM would not act on the start request). Stopping before the scenarios.'
exit 1
'@ | Set-Content -LiteralPath (Join-Path $script:ActionDir 'Fail-Lab.ps1') -Encoding utf8
        @'
Write-Information 'all good' -InformationAction Continue
exit 0
'@ | Set-Content -LiteralPath (Join-Path $script:ActionDir 'Pass-Lab.ps1') -Encoding utf8
    }

    It 'returns the exit code and leaves the last error line in the tail' {
        $tail = Get-FreshTail
        $sequence = @{ host = @{ scripts = @('Fail-Lab.ps1') } }
        $exit = Invoke-InOrchestrator { param($s, $p, $t) Invoke-OrchestratorHostAction -Sequence $s -SequencePath $p -Name 'initialize-lab' -OutputTail $t -InformationAction SilentlyContinue } @($sequence, $script:SequencePath, $tail)
        Assert-Equal 1 $exit
        Assert-True ($tail.Count -ge 2) "the tail holds the action's lines ($($tail -join ' | '))"
        $detail = Invoke-InOrchestrator { param($t) Get-OrchestratorHostActionDetail -Tail $t } @(,$tail)
        Assert-Match '^Region edges are not live: amisad-edge-b' $detail 'the cause is quoted without a prefix'
        Assert-True (-not ($detail -match "`e")) 'no console color sequence survives'
    }

    It 'runs the scripts in order and stops at the first non-zero exit' {
        $tail = Get-FreshTail
        $sequence = @{ host = @{ scripts = @('Fail-Lab.ps1', 'Pass-Lab.ps1') } }
        $exit = Invoke-InOrchestrator { param($s, $p, $t) Invoke-OrchestratorHostAction -Sequence $s -SequencePath $p -Name 'initialize-lab' -OutputTail $t -InformationAction SilentlyContinue } @($sequence, $script:SequencePath, $tail)
        Assert-Equal 1 $exit
        Assert-True (-not ($tail -contains 'all good')) 'the second script never ran'
    }

    It 'works without a tail, as every earlier caller did' {
        $sequence = @{ host = @{ script = 'Pass-Lab.ps1' } }
        $exit = Invoke-InOrchestrator { param($s, $p) Invoke-OrchestratorHostAction -Sequence $s -SequencePath $p -Name 'initialize-lab' -InformationAction SilentlyContinue } @($sequence, $script:SequencePath)
        Assert-Equal 0 $exit
    }
}

Describe 'Orchestration cycle repository provenance' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.HostGit.psm1') -Force -Global -DisableNameChecking
        $script:ProvenanceRoot = Join-Path $TestDrive 'orchestration-repositories'
        $script:ProjectRoot = Join-Path $script:ProvenanceRoot 'project'
        foreach ($path in @($script:ProvenanceRoot, $script:ProjectRoot)) {
            $null = New-YurunaTestGitRepository -Path $path -CommitMessage "Fixture $(Split-Path -Leaf $path)"
        }
        & git -C $script:ProjectRoot remote add origin 'https://github.com/example/project.git'
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the fixture project origin.' }
        $script:FrameworkSha = Get-CurrentGitCommit -RepoRoot $script:ProvenanceRoot
        $script:ProjectSha = Get-CurrentGitCommit -RepoRoot $script:ProjectRoot
        Assert-True ($script:FrameworkSha -ne $script:ProjectSha) 'fixture revisions must distinguish framework and project'

        function Invoke-ProvenanceFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Nested test doubles only capture in-memory arguments; they never write status, transcripts, or host state.')]
            [CmdletBinding()]
            param([string]$ProjectUrl, [switch]$Nested, [string]$FrameworkUrl = 'https://github.com/example/framework',
                [int]$ActionExit = 0, [scriptblock]$Seal, [System.Collections.Generic.List[string]]$Order)
            Invoke-InOrchestrator {
                param($Root, $Url, $IsNested, $FrameworkSource, $HostActionExit, $BeforeSealBlock, $CallOrder)
                # Read by the doubles below through dynamic scope.
                $null = $HostActionExit, $CallOrder
                # Boundaries capture the actual owner's payloads while host actions,
                # service probes, transcripts, and status writes remain local doubles.
                $capture = @{ reset = 0; status = @(); log = @(); perf = $null; nested = @(); completed = 0 }
                $runtimeDir = Join-Path $Root 'runtime'
                $nestedContext = if ($IsNested) {
                    @{ statusPath = (Join-Path $runtimeDir 'owner.json'); parentId = 'parent'; rootCycleFolder = $Root; cycleStartUtc = '2026-01-01T00:00:00Z'; cycleNumber = 1 }
                } else { $null }
                function Get-CycleContext { return $nestedContext }
                function Resolve-SequencePath { return (Join-Path $Root 'host-action.yml') }
                function Read-SequenceFile { return @{ host = @{} } }
                function Test-CachingProxyServiceAvailable { return $null }
                function Initialize-YurunaRuntimeDir { return $runtimeDir }
                function Reset-StatusDocumentForCycleStart { $capture.reset++ }
                function Initialize-StatusDocument {
                    param($GitCommits, $GitCommit, $RepoUrl)
                    $capture.status = $GitCommits
                    $capture.primarySha = $GitCommit
                    $capture.repoUrl = $RepoUrl
                    return '2026-01-01T00:00:00Z'
                }
                function Start-LogFile {
                    param($GitCommits)
                    $capture.log = $GitCommits
                    return (Join-Path $Root 'cycle.log')
                }
                function Start-PerfCycle {
                    param($HarnessCommit, $ProjectCommit)
                    $capture.perf = @{ framework = $HarnessCommit; project = $ProjectCommit }
                }
                function Get-CycleNumber { return 1 }
                function Set-GuestTopLevel { }
                function Set-GuestStatus { }
                function Set-StepStatus { }
                function Publish-CycleContext { }
                function Clear-CycleContext { }
                function Write-CycleStepEvent { }
                function Invoke-OrchestratorHostAction { return $HostActionExit }
                function Write-CycleInfraFailure { }
                function Complete-Run { $capture.completed++; if ($null -ne $CallOrder) { $CallOrder.Add('complete') } }
                function Stop-LogFile { if ($null -ne $CallOrder) { $CallOrder.Add('stop') } }
                function Start-NestedLogFile { return @{ LogRel = 'nested.log'; LogFile = (Join-Path $Root 'nested.log') } }
                function Register-NestedRunNode {
                    param($StatusPath, $NodeId)
                    $capture.nested = @($StatusPath, $NodeId)
                }
                function Set-NestedRunStatus { }
                function Stop-NestedLogFile { }
                $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
                $savedCache = Save-YurunaTestEnvironment -Name 'YURUNA_CACHING_PROXY_SERVICE_IP'
                try {
                    $env:YURUNA_RUNTIME_DIR = $runtimeDir
                    $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
                    $config = @{ repositories = @{ frameworkUrl = $FrameworkSource; projectUrl = $Url }; vmStart = @{} }
                    $sequence = @{ name = 'suite'; steps = @(@{ action = 'InvokeTestSequence'; sequence = 'host-action' }) }
                    $sealArgument = @{}
                    if ($BeforeSealBlock) { $sealArgument.BeforeSeal = $BeforeSealBlock }
                    $capture.exitCode = Invoke-OrchestrationSequence -Sequence $sequence -SequencePath (Join-Path $Root 'suite.yml') `
                        -RepoRoot $Root -SequencesDir $Root -TestRoot $Root -HostType 'host.ubuntu.kvm' -Config $config -InformationAction SilentlyContinue @sealArgument
                } finally {
                    Restore-YurunaTestEnvironment -Saved $savedRuntime
                    Restore-YurunaTestEnvironment -Saved $savedCache
                }
                return $capture
            } @($script:ProvenanceRoot, $ProjectUrl, [bool]$Nested, $FrameworkUrl, $ActionExit, $Seal, $Order)
        }
    }

    It 'decides on a failed cycle before it completes and seals the transcript' {
        $order = [System.Collections.Generic.List[string]]::new()
        $seal = { param($Status, $Reason) $order.Add("seal|$Status|$Reason"); 'decision line' }.GetNewClosure()
        $actual = Invoke-ProvenanceFixture -ProjectUrl '' -ActionExit 3 -Seal $seal -Order $order
        Assert-Equal 1 $actual.exitCode 'the seal output must not reach the exit code'
        Assert-Equal 3 $order.Count "one decision, then completion, then the seal: $($order -join ', ')"
        Assert-True ($order[0] -like 'seal|fail|host-action: *') "the decision sees the failure and its reason: $($order[0])"
        Assert-StringEqual 'complete' $order[1]
        Assert-StringEqual 'stop' $order[2]
    }

    It 'hands a passing cycle its status before sealing it' {
        $order = [System.Collections.Generic.List[string]]::new()
        $seal = { param($Status, $Reason) $order.Add("seal|$Status|$Reason") }.GetNewClosure()
        $actual = Invoke-ProvenanceFixture -ProjectUrl '' -Seal $seal -Order $order
        Assert-Equal 0 $actual.exitCode
        Assert-StringEqual 'seal|pass|' $order[0]
    }

    It 'leaves the decision to the owner when nested' {
        $order = [System.Collections.Generic.List[string]]::new()
        $seal = { param($Status, $Reason) $order.Add("seal|$Status|$Reason") }.GetNewClosure()
        $null = Invoke-ProvenanceFixture -ProjectUrl '' -Nested -ActionExit 3 -Seal $seal -Order $order
        Assert-Equal 0 $order.Count 'a nested orchestration neither decides nor seals the cycle'
    }

    It 'completes and seals the cycle although the decision throws' {
        $order = [System.Collections.Generic.List[string]]::new()
        $seal = { param($Status, $Reason) $null = $Status, $Reason; throw 'ledger unreadable' }
        $actual = Invoke-ProvenanceFixture -ProjectUrl '' -ActionExit 3 -Seal $seal -Order $order 3>$null
        Assert-Equal 1 $actual.exitCode
        Assert-StringEqual 'complete,stop' ($order -join ',')
    }

    It 'publishes both repository commits in status and transcript for a <Source> project' -TestCases @(
        @{ Source = 'HTTPS'; ProjectUrl = 'https://github.com/example/project.git' }
        @{ Source = 'SSH'; ProjectUrl = 'git@github.com:example/project.git' }
    ) {
        param($ProjectUrl)
        $actual = Invoke-ProvenanceFixture -ProjectUrl $ProjectUrl
        Assert-Equal 0 $actual.exitCode
        Assert-StringEqual $script:FrameworkSha $actual.primarySha 'the primary log key remains the framework revision'
        foreach ($payload in @('status', 'log')) {
            Assert-Equal 2 $actual[$payload].Count "$payload carries framework and project"
            Assert-StringEqual $script:FrameworkSha $actual[$payload][0].sha 'framework stays first'
            Assert-StringEqual 'https://github.com/example/framework' $actual[$payload][0].repoUrl
            Assert-StringEqual $script:ProjectSha $actual[$payload][1].sha 'project uses the checkout revision'
            Assert-StringEqual 'https://github.com/example/project' $actual[$payload][1].repoUrl 'the project commit link uses a web URL'
        }
        Assert-StringEqual $script:FrameworkSha $actual.perf.framework
        Assert-StringEqual $script:ProjectSha $actual.perf.project
    }

    # The standalone owners published the configured framework URL as typed,
    # so a token written into it reached status.json, which is served without
    # authentication; the runner's own cycles already stripped it.
    It 'publishes the framework URL without the credentials written into it' {
        $actual = Invoke-ProvenanceFixture -ProjectUrl 'https://github.com/example/project.git' -FrameworkUrl 'https://ops:ghp_fixturetoken@github.com/example/framework.git'
        Assert-Equal 0 $actual.exitCode
        Assert-StringEqual 'https://github.com/example/framework' $actual.repoUrl 'the top-level repoUrl carries no userinfo'
        foreach ($payload in @('status', 'log')) {
            Assert-StringEqual 'https://github.com/example/framework' $actual[$payload][0].repoUrl "$payload carries no userinfo"
        }
    }

    It 'resolves a local project source through its origin for the displayed commit link' {
        $actual = Invoke-ProvenanceFixture -ProjectUrl $script:ProjectRoot
        Assert-Equal 2 $actual.status.Count 'a local source still contributes its project commit'
        Assert-StringEqual 'https://github.com/example/project' $actual.status[1].repoUrl
        Assert-StringEqual $script:ProjectSha $actual.status[1].sha
    }

    It 'does not publish a leftover project checkout when no project is configured' {
        $actual = Invoke-ProvenanceFixture -ProjectUrl ''
        Assert-Equal 0 $actual.exitCode
        Assert-Equal 1 $actual.status.Count 'an in-tree run has only framework provenance'
        Assert-Equal 1 $actual.log.Count
    }

    It 'leaves parent cycle provenance and ownership unchanged when nested' {
        $actual = Invoke-ProvenanceFixture -ProjectUrl 'https://github.com/example/project' -Nested
        Assert-Equal 0 $actual.exitCode
        Assert-Equal 0 $actual.reset 'a nested orchestration cannot reset its owner'
        Assert-Equal 0 $actual.status.Count 'a nested orchestration cannot replace repository provenance'
        Assert-Equal 0 $actual.log.Count 'a nested orchestration cannot open an owner transcript'
        Assert-Null $actual.perf 'a nested orchestration cannot start owner performance telemetry'
        Assert-Equal 0 $actual.completed 'a nested orchestration cannot complete its owner'
        Assert-StringEqual (Join-Path $script:ProvenanceRoot 'runtime/owner.json') $actual.nested[0]
        Assert-StringEqual 'parent/suite' $actual.nested[1]
    }
}

# Inner guest sequences of an orchestration ran without the VM sizing their
# variables declared: the orchestrator built New-VM's arguments without the
# MemoryStartupBytes, Cores and ExposeVirtualizationExtensions that
# Debug-TestSequence forwards for the same plan.
Describe 'Orchestration guest VM sizing' {
    It 'forwards the plan''s memory, cores and virtualization extensions to New-VM' {
        $captured = Invoke-InOrchestrator {
            $capture = @{}
            function Test-GuestFolder { return $true }
            function Get-TestVMName { return 'test-sizing' }
            function Resolve-TestSequencePlan {
                return @{ resolveFailed = $false; chainEntries = @(); effectiveUser = $null; effectiveHost = $null; chainTotalSteps = 1
                    warmPath = $false; effectiveMemoryStartupBytes = 8GB; effectiveCores = 4; effectiveExposeVirtualizationExtensions = $true }
            }
            function Clear-GuestSshUserOverride { }
            function Get-VMState { return 'absent' }
            function New-VM {
                [CmdletBinding(SupportsShouldProcess)]
                [OutputType([hashtable])]
                param($GuestKey, $RepoRoot, $VMName, $CachingProxyServiceUrl, $MemoryStartupBytes, $Cores, $ExposeVirtualizationExtensions)
                $capture.called = @($GuestKey, $RepoRoot, $CachingProxyServiceUrl)
                if ($PSCmdlet.ShouldProcess($VMName, 'fixture New-VM')) {
                    $capture.memory = $MemoryStartupBytes; $capture.cores = $Cores; $capture.expose = $ExposeVirtualizationExtensions
                }
                return @{ success = $false; errorMessage = 'fixture stops after New-VM' }
            }
            $run = Invoke-OrchestratorGuestRun -Sequence @{ baseline = @{ 'ubuntu.server.24' = @{} } } -SequencePath 'inner.yml' -Name 'inner' `
                -RepoRoot $TestDrive -SequencesDir $TestDrive -HostType 'host.ubuntu.kvm' -Config @{ vmStart = @{} } -InformationAction SilentlyContinue
            $capture.ok = $run.ok
            return $capture
        }
        Assert-False $captured.ok 'the fixture stops the run at New-VM'
        Assert-Equal 8GB $captured.memory -Because 'variables.memoryStartupBytes reaches New-VM'
        Assert-Equal 4 $captured.cores -Because 'variables.cores reaches New-VM'
        Assert-True ([bool]$captured.expose) 'variables.exposeVirtualizationExtensions reaches New-VM'
    }
}

# An orchestration owns the cycle the runner dispatches it in, and the runner
# took the cycle-start host diagnostic only on the path where it opens the
# cycle itself, so an orchestrated cycle's folder held no host.diagnostic.txt
# and its perf rows no hostInfoHash. Each case runs the dispatch statement
# exactly as its entry point wrote it, against the real orchestrator and the
# real capture; a stub stands in for automation/Get-SystemDiagnostic.ps1.
Describe 'Orchestration cycle-start host diagnostic' {
    BeforeAll {
        $modules = Split-Path -Parent $PSCommandPath
        # The capture belongs to the runner's module; the orchestrator reaches it
        # through the global command table, as it does in the runner's process.
        Import-Module (Join-Path $modules 'Test.RunnerInnerLoop.psm1') -Force -Global -DisableNameChecking
        $script:Dispatch = @{}
        foreach ($entryPoint in @(
                @{ Name = 'runner'; Path = (Join-Path $modules 'Test.RunnerInnerLoop.psm1') }
                @{ Name = 'standalone'; Path = (Join-Path (Split-Path -Parent $modules) 'Debug-TestSequence.ps1') }
            )) {
            $calls = @((Get-YurunaTestFileAst -Path $entryPoint.Path).FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-OrchestrationSequence' }, $true))
            Assert-Equal 1 $calls.Count "fixture sanity: one orchestration dispatch in $($entryPoint.Path)"
            $script:Dispatch[$entryPoint.Name] = $calls[0].Extent.Text
        }

        function Invoke-HostDiagnosticFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Nested test doubles only record their arguments or create folders under the test drive.')]
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Statement, [switch]$Nested, [switch]$NoDiagnosticScript)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $runs = Join-Path $root 'diagnostic-runs.txt'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'automation')
            if (-not $NoDiagnosticScript) {
                # Records each run, then writes the dump and its problem sidecar
                # where automation/Get-SystemDiagnostic.ps1 writes them for -OutFile.
                $stub = @(
                    'param([string]$OutFile)'
                    "Add-Content -LiteralPath '$runs' -Value `$OutFile"
                    'Set-Content -LiteralPath $OutFile -Value ''fixture host state'''
                    'Set-Content -LiteralPath "$OutFile.json" -Value ''{"schema":"yuruna.diagnostic.problems/v1","count":1,"byClass":{"disk":1},"problems":[{"class":"disk","message":"fixture"}]}'''
                )
                Set-Content -LiteralPath (Join-Path $root 'automation/Get-SystemDiagnostic.ps1') -Value $stub -Encoding utf8
            }
            $savedFolder = Save-YurunaTestGlobal -Name '__YurunaCycleFolder'
            $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
            $savedCache = Save-YurunaTestEnvironment -Name 'YURUNA_CACHING_PROXY_SERVICE_IP'
            try {
                $env:YURUNA_RUNTIME_DIR = Join-Path $root 'runtime'
                $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
                $actual = Invoke-InOrchestrator {
                    param($Root, $Text, $IsNested)
                    $capture = @{ Perf = $null; Completed = 0 }
                    $cycleFolder = Join-Path $Root '000001.fixture-cycle'
                    $nestedContext = if ($IsNested) {
                        @{ statusPath = (Join-Path $Root 'owner.json'); parentId = 'parent'; rootCycleFolder = $cycleFolder; cycleStartUtc = '2026-01-01T00:00:00Z'; cycleNumber = 1 }
                    } else { $null }
                    function Get-CycleContext { return $nestedContext }
                    function Resolve-SequencePath { return (Join-Path $Root 'host-action.yml') }
                    function Read-SequenceFile { return @{ host = @{} } }
                    function Test-CachingProxyServiceAvailable { return $null }
                    function Initialize-YurunaRuntimeDir { return $env:YURUNA_RUNTIME_DIR }
                    # The real owner opens the transcript, which publishes the cycle folder.
                    function Register-StandaloneCycle {
                        $null = New-Item -ItemType Directory -Force -Path $cycleFolder
                        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $cycleFolder }
                        return @{ CycleStartUtc = '2026-01-01T00:00:00Z'; CycleNumber = 1; LogFile = (Join-Path $cycleFolder 'cycle.html')
                            FrameworkCommit = 'framework-sha'; ProjectCommit = $null; GitCommits = @() }
                    }
                    function Start-NestedLogFile {
                        $folder = Join-Path $cycleFolder 'nested'
                        $null = New-Item -ItemType Directory -Force -Path $folder
                        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $folder }
                        return @{ LogRel = 'nested/nested.html'; LogFile = (Join-Path $folder 'nested.html') }
                    }
                    function Start-PerfCycle {
                        param($HostDiagnosticPath)
                        $capture.Perf = @{ Path = $HostDiagnosticPath; Existed = [bool]($HostDiagnosticPath -and (Test-Path -LiteralPath $HostDiagnosticPath)) }
                    }
                    function Get-CycleNumber { return 1 }
                    function Set-GuestTopLevel { }
                    function Set-GuestStatus { }
                    function Set-StepStatus { }
                    function Publish-CycleContext { }
                    function Clear-CycleContext { }
                    function Write-CycleStepEvent { }
                    function Invoke-OrchestratorHostAction { return 0 }
                    function Complete-Run { $capture.Completed++ }
                    function Stop-LogFile { }
                    function Register-NestedRunNode { }
                    function Set-NestedRunStatus { }
                    function Stop-NestedLogFile { }
                    # What the dispatch statements read, under the names their entry points use.
                    $orchestrationDoc = $topLevelDoc = @{ name = 'suite'; steps = @(@{ action = 'InvokeTestSequence'; sequence = 'host-action' }) }
                    $orchestrationPath = $SequencePath = Join-Path $Root 'suite.yml'
                    $RepoRoot = $SequencesDir = $TestRoot = $Root
                    $HostType = 'host.ubuntu.kvm'
                    $Config = @{ repositories = @{}; vmStart = @{} }
                    $decideBeforeSeal = { param($Status, $Reason) $null = $Status, $Reason }
                    $ShowSensitive = $false
                    $null = @($orchestrationDoc, $topLevelDoc, $orchestrationPath, $SequencePath, $RepoRoot, $SequencesDir, $TestRoot, $HostType, $Config, $decideBeforeSeal, $ShowSensitive)
                    $streams = @(. ([scriptblock]::Create($Text)) 6>&1 3>&1)
                    $capture.Output = @($streams | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })
                    $capture.Information = @($streams | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
                    $capture.Warnings = @($streams | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message })
                    $capture.Dump = Join-Path $cycleFolder 'host.diagnostic.txt'
                    # The lines a cycle the runner opens itself prints for the same capture.
                    $capture.Lines = @(
                        (Format-YurunaOperatorMessage -Key 'runner.operator_129990a926a40e2a' -Arguments @{ cycleBaseName = (Split-Path -Leaf $cycleFolder) })
                        (Format-YurunaOperatorMessage -Key 'runner.operator_5d4003f8fdb37099' -Arguments @{ diagCount = '1'; diagTally = 'disk=1' })
                    )
                    $capture.MissingScript = Format-YurunaOperatorMessage -Key 'runner.operator_b7880bb57e65b573' -Arguments @{ hostDiagScript = (Join-Path $Root 'automation/Get-SystemDiagnostic.ps1') }
                    return $capture
                } @($root, $Statement, [bool]$Nested)
            } finally {
                Restore-YurunaTestGlobal -Saved $savedFolder
                Restore-YurunaTestEnvironment -Saved $savedRuntime
                Restore-YurunaTestEnvironment -Saved $savedCache
            }
            $actual.Root = $root
            $actual.Runs = @(if (Test-Path -LiteralPath $runs) { Get-Content -LiteralPath $runs })
            return $actual
        }
    }

    It 'writes host.diagnostic.txt into the cycle folder a runner orchestration owns, before the perf log opens' {
        $actual = Invoke-HostDiagnosticFixture -Statement $script:Dispatch.runner
        Assert-Equal 1 $actual.Runs.Count 'an orchestration cycle the runner dispatches takes one cycle-start host diagnostic'
        Assert-StringEqual $actual.Dump $actual.Runs[0] 'the dump is written at the root of the cycle folder'
        Assert-True (Test-Path -LiteralPath $actual.Dump) 'host.diagnostic.txt is in the cycle folder'
        Assert-StringEqual $actual.Dump $actual.Perf.Path 'the perf log hashes that dump'
        Assert-True $actual.Perf.Existed 'the dump exists before the perf log opens over it'
        Assert-Equal 1 $actual.Output.Count "the capture's lines stay out of the exit code: $($actual.Output -join ' | ')"
        Assert-Equal 0 $actual.Output[0]
        foreach ($line in $actual.Lines) {
            Assert-True ($actual.Information -ccontains $line) "the cycle log carries '$line' as a runner cycle's does"
        }
    }

    It 'leaves the capture to the cycle owner when nested' {
        $actual = Invoke-HostDiagnosticFixture -Statement $script:Dispatch.runner -Nested
        Assert-Equal 0 $actual.Runs.Count 'only the owner of the cycle takes it'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $actual.Root -Recurse -Filter 'host.diagnostic.txt').Count 'no second dump anywhere in the cycle'
        Assert-Null $actual.Perf 'a nested orchestration opens no perf log of its own'
    }

    It 'takes none for a standalone Debug-TestSequence run, as for every sequence shape it runs' {
        $actual = Invoke-HostDiagnosticFixture -Statement $script:Dispatch.standalone
        Assert-Equal 0 $actual.Runs.Count 'Debug-TestSequence opens its own cycles without the runner''s cycle-start host diagnostic'
        Assert-False (Test-Path -LiteralPath $actual.Dump) 'no dump in the standalone cycle folder'
        Assert-NotNull $actual.Perf 'the perf log still opens'
        Assert-False $actual.Perf.Existed 'with no dump to hash'
        Assert-Equal 0 $actual.Output[0]
    }

    It 'scopes the switch help to the cycle-start capture' {
        # A standalone run whose guest chain fails still takes the failure-time
        # capture (Save-ChainFailureArtifact), and an owner takes the cycle-start
        # one only when its caller passes the switch, so both exemptions the help
        # states are about the cycle-start capture alone.
        $help = (Get-YurunaTestFunctionAst -Path $script:Orchestrator.Path -Name 'Invoke-OrchestrationSequence').GetHelpContent().Parameters['CAPTUREHOSTDIAGNOSTIC']
        Assert-NotNull $help 'fixture sanity: the switch has parameter help'
        $sentences = @(($help -replace '\s+', ' ').Trim() -split '(?<=\.)\s+')
        $standalone = @($sentences | Where-Object { $_ -match 'standalone' })
        Assert-True ($standalone.Count -gt 0) 'fixture sanity: the help says what a standalone run takes'
        foreach ($sentence in $standalone) {
            Assert-Match 'cycle-start' $sentence 'a standalone run whose guest chain fails still takes the failure-time capture'
        }
        Assert-Match 'host\.diagnostics\.txt' $help 'the help names the failure-time capture the switch leaves alone'
        $nested = @($sentences | Where-Object { $_ -match 'nested' })
        Assert-True ($nested.Count -gt 0) 'fixture sanity: the help says what a nested run takes'
        foreach ($sentence in $nested) {
            Assert-Match '\bonly\b.*\bowner\b' $sentence 'a standalone owner took no cycle-start capture for its nested runs'
        }
    }

    It 'warns and still runs the cycle when the diagnostic script is missing' {
        $actual = Invoke-HostDiagnosticFixture -Statement $script:Dispatch.runner -NoDiagnosticScript
        Assert-True ($actual.Warnings -ccontains $actual.MissingScript) "the missing script is reported: $($actual.Warnings -join ' | ')"
        Assert-False (Test-Path -LiteralPath $actual.Dump) 'nothing was captured'
        Assert-NotNull $actual.Perf 'the perf log still opens'
        Assert-Equal 1 $actual.Completed 'the cycle still runs to completion'
        Assert-Equal 1 $actual.Output.Count
        Assert-Equal 0 $actual.Output[0]
    }
}
