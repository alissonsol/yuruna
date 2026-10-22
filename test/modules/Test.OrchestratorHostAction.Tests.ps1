<#PSScriptInfo
.VERSION 2026.10.22
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
            $null = New-Item -ItemType Directory -Path $path -Force
            & git -C $path init --quiet 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not initialize fixture repository: $path" }
            & git -C $path -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath= commit --allow-empty --quiet -m "Fixture $(Split-Path -Leaf $path)" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not commit fixture repository: $path" }
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
            param([string]$ProjectUrl, [switch]$Nested)
            Invoke-InOrchestrator {
                param($Root, $Url, $IsNested)
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
                    param($GitCommits, $GitCommit)
                    $capture.status = $GitCommits
                    $capture.primarySha = $GitCommit
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
                function Invoke-OrchestratorHostAction { return 0 }
                function Complete-Run { $capture.completed++ }
                function Stop-LogFile { }
                function Start-NestedLogFile { return @{ LogRel = 'nested.log'; LogFile = (Join-Path $Root 'nested.log') } }
                function Register-NestedRunNode {
                    param($StatusPath, $NodeId)
                    $capture.nested = @($StatusPath, $NodeId)
                }
                function Set-NestedRunStatus { }
                function Stop-NestedLogFile { }
                $savedRuntime = $env:YURUNA_RUNTIME_DIR
                $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
                try {
                    $env:YURUNA_RUNTIME_DIR = $runtimeDir
                    $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
                    $config = @{ repositories = @{ frameworkUrl = 'https://github.com/example/framework'; projectUrl = $Url }; vmStart = @{} }
                    $sequence = @{ name = 'suite'; steps = @(@{ action = 'InvokeTestSequence'; sequence = 'host-action' }) }
                    $capture.exitCode = Invoke-OrchestrationSequence -Sequence $sequence -SequencePath (Join-Path $Root 'suite.yml') `
                        -RepoRoot $Root -SequencesDir $Root -TestRoot $Root -HostType 'host.ubuntu.kvm' -Config $config -InformationAction SilentlyContinue
                } finally {
                    $env:YURUNA_RUNTIME_DIR = $savedRuntime
                    $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
                }
                return $capture
            } @($script:ProvenanceRoot, $ProjectUrl, [bool]$Nested)
        }
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
