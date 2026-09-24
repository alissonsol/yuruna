<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42871662-c8fc-4b5a-9380-fa9ff5c48ae5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config preflight gate pester
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
    Pester coverage for Test.ConfigPreflight.psm1: the pre-cycle gate that
    spawns Test-Config.ps1 and decides whether the cycle may start.
.DESCRIPTION
    The gate is exercised against a STUB Test-Config.ps1 written into a temp
    dir; no real config is validated and no cycle is started. The stub reads
    its own script (stdout lines / stderr lines / exit code) from the JSON
    file handed to it as -ConfigPath, and records the parameters it was
    invoked with, so the tests can assert both what the gate does with the
    child's transcript and that the child was (or was not) spawned at all.
    Covered: the two bypass paths (no Test-Config.ps1, -Skip), the mandatory
    -SkipSend contract, silence on a green gate, exit-code propagation,
    the FAILURES-block excerpt (including a block written to stderr and a
    block whose footer never arrives), the last-N-lines fallback when there
    is no FAILURES block, and a child that fails with no output at all.
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Run: Invoke-Pester -Path test/modules/Test.ConfigPreflight.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.ConfigPreflight.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Paths only at file scope; the directories and the stub script are created in
# BeforeAll and removed in AfterAll. A standalone run executes this file body
# twice (discovery, then run), so a temp tree built here would be created and
# deleted during discovery and every It would then spawn against a gate script
# that no longer exists. $PID is stable across the two passes.
$preflightRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-configpreflight-tests-$PID"
$script:gateRoot      = Join-Path $preflightRoot 'testroot-with-gate'     # TestRoot that HAS Test-Config.ps1
$script:emptyRoot     = Join-Path $preflightRoot 'testroot-without-gate'  # TestRoot that does NOT
$script:planRoot      = Join-Path $preflightRoot 'plans'                  # the per-test stub scripts

# The stand-in for test/Test-Config.ps1. Invoke-ConfigGate spawns it as
#   pwsh -NoProfile -ExecutionPolicy Bypass -File <gate> -SkipSend -ConfigPath <cfg>
# so it must accept exactly those two parameters. It replays a scripted
# transcript and exit code out of the JSON at -ConfigPath, and records how it
# was called so a test can prove the spawn happened (or did not).
$script:stubGateBody = @'
[CmdletBinding()]
param(
    [switch]$SkipSend,
    [string]$ConfigPath
)
$plan = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
if ($plan.recordPath) {
    $record = [ordered]@{ skipSend = [bool]$SkipSend; configPath = $ConfigPath }
    Set-Content -LiteralPath $plan.recordPath -Value ($record | ConvertTo-Json)
}
if ($plan.sidecar -and $env:YURUNA_FAILURE_SIDECAR) {
    Set-Content -LiteralPath $env:YURUNA_FAILURE_SIDECAR -Value ($plan.sidecar | ConvertTo-Json -Depth 6)
}
if ($null -ne $plan.stdout) { foreach ($line in @($plan.stdout)) { Write-Output $line } }
if ($null -ne $plan.stderr) { foreach ($line in @($plan.stderr)) { [Console]::Error.WriteLine($line) } }
exit ([int]$plan.exit)
'@

# Writes the JSON the stub gate replays, and returns the ConfigPath to hand
# Invoke-ConfigGate plus the RecordPath that proves whether it ran.
function New-GatePlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Stdout = @(),
        [string[]]$Stderr = @(),
        [int]$ExitCode = 0,
        $Sidecar = $null
    )
    $recordPath = Join-Path $Root "$Name.invocation.json"
    $configPath = Join-Path $Root "$Name.config.json"
    if (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }
    $plan = [ordered]@{ recordPath = $recordPath; stdout = $Stdout; stderr = $Stderr; exit = $ExitCode; sidecar = $Sidecar }
    Set-Content -LiteralPath $configPath -Value ($plan | ConvertTo-Json -Depth 5)
    return @{ ConfigPath = $configPath; RecordPath = $recordPath }
}

# Runs the gate with its warning (3) and information (6) streams merged into
# the success stream, then separates the returned hashtable from everything the
# operator would have seen on the console.
function Get-GateOutcome {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Skip,
        [string]$SkipReason,
        [string]$CallerName = 'UnitTest'
    )
    $result = $null
    $shown  = [System.Collections.Generic.List[string]]::new()
    $gateArgument = @{ TestRoot = $TestRoot; ConfigPath = $ConfigPath; Skip = $Skip; CallerName = $CallerName }
    if ($PSBoundParameters.ContainsKey('SkipReason')) { $gateArgument['SkipReason'] = $SkipReason }
    $emitted = @(Invoke-ConfigGate @gateArgument 3>&1 6>&1)
    foreach ($item in $emitted) {
        if ($item -is [hashtable]) { $result = $item } else { [void]$shown.Add("$item") }
    }
    return @{ Result = $result; Text = ($shown -join "`n") }
}

# The shape Test.Output's Write-Summary prints when Test-Config fails: an
# "=" banner, the FAILURES header, the per-failure detail, then the matching
# END OF FAILURES footer between two more banners. The gate's excerpt logic
# keys off exactly this, so the stub reproduces it verbatim.
$script:failuresTranscript = @(
    'Checking config files...',
    'UNRELATED-CHATTER-BEFORE',
    '',
    '========',
    '  FAILURES (2) -- the cycle gate refuses to start until these are resolved:',
    '========',
    '',
    '  [1/2] in section: networkStorage',
    '        poolStorageNetworkPath is not reachable',
    '',
    '  [2/2] in section: repositories',
    '        projectUrl is empty',
    '',
    '========',
    '  END OF FAILURES (2)',
    '========',
    'UNRELATED-CHATTER-AFTER'
)

}

Describe 'Invoke-ConfigGate' {

    BeforeAll {
        foreach ($d in @($script:gateRoot, $script:emptyRoot, $script:planRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $script:gateRoot 'Test-Config.ps1') -Value $script:stubGateBody
    }

    AfterAll {
        Remove-Item -LiteralPath $preflightRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'bypass paths' {

        It 'passes and reports skipped when TestRoot has no Test-Config.ps1' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'absent-gate' -Stdout @('must not run') -ExitCode 9
            $o    = Get-GateOutcome -TestRoot $script:emptyRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $true -Actual $o.Result.passed  -Because 'a harness without the gate script must not be blocked from cycling'
            Assert-Equal -Expected $true -Actual $o.Result.skipped
            Assert-Equal -Expected 0     -Actual $o.Result.exitCode
            Assert-True  ($o.Text -match 'config gate skipped') 'the operator is told the gate did not run'
            Assert-True  (-not (Test-Path -LiteralPath $plan.RecordPath)) 'nothing can be spawned when the gate script is missing'
        }

        It 'passes and reports skipped for -Skip, without spawning Test-Config.ps1 at all' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'skip' -Stdout @('must not run') -ExitCode 9
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -Skip
            Assert-Equal -Expected $true -Actual $o.Result.passed
            Assert-Equal -Expected $true -Actual $o.Result.skipped
            Assert-Equal -Expected 0     -Actual $o.Result.exitCode -Because 'a bypassed gate never carries a child exit code'
            Assert-True  ($o.Text -match 'SKIPPED') 'the bypass is announced, so a green cycle is never mistaken for a validated one'
            Assert-True  (-not (Test-Path -LiteralPath $plan.RecordPath)) '-NoConfigGate must not pay the cost of a child pwsh'
        }
    }

    Context 'green gate' {

        It 'spawns Test-Config.ps1 with -SkipSend and the caller ConfigPath, then says nothing' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'green' -Stdout @('  PASS:  12   WARN:   0   FAIL:   0') -ExitCode 0
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $true  -Actual $o.Result.passed
            Assert-Equal -Expected $false -Actual $o.Result.skipped -Because 'the gate really ran'
            Assert-Equal -Expected 0      -Actual $o.Result.exitCode
            Assert-Equal -Expected ''     -Actual $o.Text -Because 'a green gate is silent: the child transcript is captured, never printed'

            Assert-True (Test-Path -LiteralPath $plan.RecordPath) 'the child pwsh must actually have been spawned'
            $record = Get-Content -Raw -LiteralPath $plan.RecordPath | ConvertFrom-Json
            Assert-Equal -Expected $true -Actual $record.skipSend `
                -Because '-SkipSend is mandatory here: without it every outer relaunch would email the config.smoke subscribers'
            Assert-Equal -Expected $plan.ConfigPath -Actual $record.configPath `
                -Because 'the gate validates the config the caller named, not a default'
        }
    }

    Context 'red gate' {

        It 'fails, propagates the child exit code, and repeats only the FAILURES block' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'red' -Stdout $script:failuresTranscript -ExitCode 7
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -CallerName 'Start-TestRunner'
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-Equal -Expected 7      -Actual $o.Result.exitCode -Because 'the caller reports the child exit code, not a generic 1'
            Assert-Equal -Expected $false -Actual $o.Result.skipped

            Assert-True ($o.Text -match 'Start-TestRunner\] Pre-cycle config gate FAILED') 'the banner names the entry point that owned the failure'
            Assert-True ($o.Text -match 'Test-Config\.ps1 exit 7')
            Assert-True ($o.Text -match 'poolStorageNetworkPath is not reachable') 'the FAILURES detail is repeated under the banner'
            Assert-True ($o.Text -match 'projectUrl is empty')
            Assert-True ($o.Text -match 'END OF FAILURES \(2\)') 'the excerpt runs through the closing footer'
            Assert-True ($o.Text -notmatch 'UNRELATED-CHATTER') 'only the FAILURES block is repeated, not the whole ~80-line child transcript'
            Assert-True ($o.Text -match '-NoConfigGate') 'the bypass hint tells the operator how to proceed on an in-progress edit'
        }

        It 'reads the failures as data when the child reports them that way' {
            # The property this exists for: what the parent recovers no longer
            # depends on a sentence in the child's output surviving unchanged.
            $sidecar = [ordered]@{
                schema    = 'yuruna.preflight-failures/v1'
                failCount = 2
                warnCount = 1
                failures  = @(
                    [ordered]@{ section = 'storage'; message = 'poolStorageNetworkPath is not reachable'
                                fullPath = '/mnt/ypool-nas'; warnings = @('share responded slowly') }
                    [ordered]@{ section = 'project'; message = 'projectUrl is empty'; fullPath = ''; warnings = @() }
                )
            }
            # The printed block is deliberately in another language, and says
            # nothing this assertion looks for. A parent still matching English
            # would report no failures at all for a child that failed.
            $foreign = @('========', '  FALHAS (2) -- o portao recusa:', '========',
                         '  [1/2] secao: storage', '        caminho inacessivel',
                         '========', '  FIM DAS FALHAS (2)', '========')
            $plan = New-GatePlan -Root $script:planRoot -Name 'red-sidecar' -Stdout $foreign -ExitCode 5 -Sidecar $sidecar
            $o = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -CallerName 'Start-TestRunner'

            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-Equal -Expected 5 -Actual $o.Result.exitCode
            Assert-True ($o.Text -match 'poolStorageNetworkPath is not reachable') 'the first failure is reported'
            Assert-True ($o.Text -match 'projectUrl is empty') 'the second failure is reported'
            Assert-True ($o.Text -match 'share responded slowly') 'the warning the failure pointed at travels with it'
            Assert-True ($o.Text -match '/mnt/ypool-nas') 'the path the operator has to look at is reported'
            Assert-True ((@($o.Result.failureLines) -join "`n") -match 'projectUrl is empty') `
                'the returned failure lines come from the data, not from the printed text'
        }

        It 'still reads the printed block from a gate that reports no data' {
            # The bounded fallback. A gate built before the sidecar, and every
            # stand-in a test substitutes for one, reports only what it prints.
            $plan = New-GatePlan -Root $script:planRoot -Name 'red-nosidecar' -Stdout $script:failuresTranscript -ExitCode 7
            $o = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -CallerName 'Start-TestRunner'
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-True ($o.Text -match 'poolStorageNetworkPath is not reachable') 'the printed block is still recovered'
            Assert-True ($o.Text -match 'N-1 stdout compatibility reader') 'using the fallback must be visible'
            Assert-True ($o.Text -match 'release 2026\.11 by 2026-11-30') 'the compatibility reader needs an executable release and calendar deadline'
        }

        It 'finds the FAILURES block even when the child wrote it to stderr' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'red-stderr' -Stderr $script:failuresTranscript -ExitCode 2
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-Equal -Expected 2      -Actual $o.Result.exitCode
            Assert-True  ($o.Text -match 'poolStorageNetworkPath is not reachable') `
                'the 2>&1 capture is what makes the extractor stream-agnostic'
            Assert-True  ($o.Text -notmatch 'did not emit a FAILURES block') 'the block was found, so the tail fallback must not fire'
        }

        It 'surfaces the block through to the end of capture when the footer never arrives' {
            $truncated = @(
                '========',
                '  FAILURES (1) -- the cycle gate refuses to start until these are resolved:',
                '========',
                '',
                '  [1/1] in section: transports',
                '        ssh transport unreachable',
                'TRUNCATED-TAIL-AFTER-CRASH'
            )
            $plan = New-GatePlan -Root $script:planRoot -Name 'red-truncated' -Stdout $truncated -ExitCode 1
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-True  ($o.Text -match 'ssh transport unreachable') 'a partial block is surfaced, not swallowed'
            Assert-True  ($o.Text -match 'TRUNCATED-TAIL-AFTER-CRASH') 'with no footer the excerpt runs to the end of the capture'
        }

        It 'falls back to the last lines of output when the child fails without a FAILURES block' {
            $crash = @('Loading config...', 'System.Exception: the yaml blew up', 'at <ScriptBlock>, line 12')
            $plan  = New-GatePlan -Root $script:planRoot -Name 'red-crash' -Stdout $crash -ExitCode 3
            $o     = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-Equal -Expected 3      -Actual $o.Result.exitCode
            Assert-True  ($o.Text -match 'did not emit a FAILURES block') 'the operator is told why there is no excerpt'
            Assert-True  ($o.Text -match 'Last 3 lines')
            Assert-True  ($o.Text -match 'the yaml blew up') 'a crash before Exit-WithSummary still leaves a starting point'
        }

        It 'still reports the failure when the child produces no output at all' {
            $plan = New-GatePlan -Root $script:planRoot -Name 'red-silent' -ExitCode 4
            $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath
            Assert-Equal -Expected $false -Actual $o.Result.passed
            Assert-Equal -Expected 4      -Actual $o.Result.exitCode
            Assert-True  ($o.Text -match 'Pre-cycle config gate FAILED') 'an opaque child failure still stops the cycle with a banner'
            Assert-True  ($o.Text -notmatch 'Last \d+ lines') 'there is no tail to print, and printing an empty one would be noise'
        }
    }
}

Describe 'One gate per cycle, at the front of it' {
    # The gate reaches the network. Re-running it per nested stage means a
    # remote that stops answering partway through a cycle aborts work that was
    # already succeeding and discards every stage already built -- while a
    # runner that only gates at startup can go on for days without ever
    # re-checking. Once, at the front of each cycle, is the placement that
    # catches a broken config or credential before it costs anything.
    BeforeAll {
        # Owns its own copy of the stub tree: the Describe above removes the
        # shared one in its AfterAll, which runs before this Describe starts.
        foreach ($d in @($script:gateRoot, $script:planRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $script:gateRoot 'Test-Config.ps1') -Value $script:stubGateBody

        $testRootDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $repo        = Split-Path -Parent $testRootDir
        $script:innerText = Get-Content -Raw (Join-Path $repo 'test/modules/Invoke-TestRunnerInnerLoop.ps1')
        $script:seqText   = Get-Content -Raw (Join-Path $repo 'test/Debug-TestSequence.ps1')
        $script:outerText = Get-Content -Raw (Join-Path $repo 'test/Start-TestRunner.ps1')
        $script:projText  = Get-Content -Raw (Join-Path $repo 'test/Invoke-TestProject.ps1')
    }

    AfterAll {
        Remove-Item -LiteralPath $preflightRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'the cycle gates itself, before it touches the host' {
        Assert-True ($script:innerText -match 'Invoke-ConfigGate') `
            'a startup-only gate says nothing about hour nine of an eternal loop'
        $gateAt  = $script:innerText.IndexOf('Invoke-ConfigGate')
        $hostAt  = $script:innerText.IndexOf('$HostType = Get-HostType')
        Assert-True ($gateAt -gt 0 -and $hostAt -gt $gateAt) `
            'gating after the host work has begun is not a pre-flight'
    }

    It 'a nested stage inherits the cycle owner verdict instead of re-gating' {
        Assert-True ($script:seqText -match '\$isNested') `
            'a nested run is one stage of a cycle that already gated this config'
        Assert-True ($script:seqText -match 'Skip:\$gateSkip') `
            'the skip must cover the nested case, not only the operator bypass'
        Assert-True ($script:seqText -match 'SkipReason') `
            'a structural bypass and a deliberate -NoConfigGate must not read alike'
    }

    It 'the bypass reaches the layer that now gates' {
        Assert-True ($script:outerText -notmatch 'OuterOnlyParams') `
            '-NoConfigGate withheld from the inner would re-impose the gate the operator bypassed'
        Assert-True ($script:projText -match 'NoConfigGate\s+= \[switch\]::new\(\$true\)') `
            'the entry point that gates before its own re-clone must not make the cycle gate again'
    }

    It 'names a structural bypass as itself' {
        $plan = New-GatePlan -Root $script:planRoot -Name 'skip-nested' -ExitCode 0
        $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -Skip -SkipReason 'nested run -- the owner cycle already gated it'
        Assert-Equal -Expected $true -Actual $o.Result.skipped
        Assert-True  ($o.Text -match 'nested run') 'a reader must be able to tell WHY nothing was validated here'
        Assert-True  ($o.Text -notmatch '-NoConfigGate') 'reporting an inherited verdict as an operator bypass is a false trail'
    }

    It 'still defaults to naming the operator bypass' {
        $plan = New-GatePlan -Root $script:planRoot -Name 'skip-default' -ExitCode 0
        $o    = Get-GateOutcome -TestRoot $script:gateRoot -ConfigPath $plan.ConfigPath -Skip
        Assert-True ($o.Text -match '-NoConfigGate') 'the unqualified skip is still the operator opting out'
    }
}
