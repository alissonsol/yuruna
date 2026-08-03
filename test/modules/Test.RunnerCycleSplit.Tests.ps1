<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42b9d4e1-7c53-4a08-8bd6-0f92e5a37c14
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner cycle split pester
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
    Guards the once-per-runner / once-per-cycle boundary.
.DESCRIPTION
    Running a cycle in its own process is what lets an edit take effect without
    restarting the runner, but three startup routines become actively destructive
    if they run per cycle, and each fails silently rather than loudly:

      * the single-instance pidfile dance -- a child matches the same command-line
        pattern as its parent, so it classifies the parent as a competing runner
        and stops it;
      * the boot-recovery sweep -- it clears control.step-pause / control.cycle-pause,
        so an operator's pause would be dropped at every cycle boundary and the
        status-UI pause buttons would appear to do nothing;
      * runner-state initialization -- a fresh runId per cycle breaks run continuity
        on the event stream.

    These assert the boundary from the source AST, so a later edit that moves one of
    them into the per-cycle path fails here instead of on a live lab host.
#>

$ErrorActionPreference = 'Stop'
$testRoot   = Split-Path -Parent $PSScriptRoot
$cycleFile  = Join-Path $testRoot 'Invoke-TestCycleRunner.ps1'
$outerFile  = Join-Path $testRoot 'Invoke-TestRunner.ps1'
$loopModule = Join-Path $PSScriptRoot 'Test.RunnerOuterLoop.psm1'

Import-Module $loopModule -Force -DisableNameChecking

function Get-CommandNameList {
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
}

Describe 'Per-cycle runner never performs once-per-runner startup' {
    $cycleCommands = Get-CommandNameList -Path $cycleFile
    $outerCommands = Get-CommandNameList -Path $outerFile

    It 'does not run the single-instance pidfile dance (it would stop its own parent)' {
        ($cycleCommands -contains 'Get-RunnerInstanceState') | Should -Be $false
        ($cycleCommands -contains 'Write-RunnerPidFile')     | Should -Be $false
        ($cycleCommands -contains 'Stop-StaleRunner')        | Should -Be $false
    }
    It 'does not run boot recovery (it would clear the operator pause flags every cycle)' {
        ($cycleCommands -contains 'Invoke-YurunaBootRecovery') | Should -Be $false
    }
    It 'does not re-initialize runner state (it would mint a new runId per cycle)' {
        ($cycleCommands -contains 'Initialize-RunnerState') | Should -Be $false
    }
    It 'leaves all three with the long-lived runner' {
        ($outerCommands -contains 'Get-RunnerInstanceState')   | Should -Be $true
        ($outerCommands -contains 'Invoke-YurunaBootRecovery')  | Should -Be $true
        ($outerCommands -contains 'Initialize-RunnerState')     | Should -Be $true
    }
    It 'spawns the cycle runner rather than the inner runner directly' {
        (Get-Content $outerFile -Raw) | Should -Match 'Invoke-TestCycleRunner\.ps1'
    }
}

Describe 'Cycle outcomes are reported, not acted on, inside the cycle' {
    $cycleFnText = (Get-Command Invoke-RunnerOuterCycle).Definition

    It 'never sleeps inside the cycle (the caller owns every wait, so Ctrl+C stays observable)' {
        # A Start-Sleep here runs where the operator's Ctrl+C flag does not exist,
        # so it could not be cut short. The loop holds the waits instead.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($cycleFnText, [ref]$null, [ref]$null)
        $sleeps = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep'
        }, $true))
        $sleeps.Count | Should -Be 0
    }
    It 'reports drain instead of flipping a shutdown flag the caller cannot see' {
        $cycleFnText | Should -Match "Outcome = 'drain'"
    }
}

Describe 'The cycle process keeps its console clean' {
    # The cycle runs in a child spawned -NoNewWindow, so it writes to the SAME
    # console as the runner that prints one line per finished cycle. Anything
    # the child leaves on the success stream lands between those lines, and the
    # bool-returning state writers are the easy way to do it by accident: the
    # value looks discarded at the call site and prints a bare "True".
    $boolReturningWriter = @('Write-YurunaStateFile', 'Write-YurunaStateFileJson')

    function Get-UncapturedCall {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Both parameters ARE used -- Path as the parse target, Name inside the FindAll predicate the analyzer does not follow.')]
        param([string]$Path, [string[]]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $Name
        }, $true) | Where-Object {
            $pipeline = $_.Parent
            # More than one element means it is piped onward (Out-Null and friends).
            if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
                $pipeline.PipelineElements.Count -gt 1) { return $false }
            # A pipeline sitting directly in a statement block emits; anywhere else
            # -- an assignment, a return, a condition, [void](...) -- consumes it.
            $pipeline.Parent -is [System.Management.Automation.Language.NamedBlockAst] -or
            $pipeline.Parent -is [System.Management.Automation.Language.StatementBlockAst]
        } | ForEach-Object { "$($_.GetCommandName()) at line $($_.Extent.StartLineNumber)" })
    }

    It 'leaves no state-writer boolean on the cycle runner''s success stream' {
        $leaks = Get-UncapturedCall -Path $cycleFile -Name $boolReturningWriter
        $leaks -join '; ' | Should -Be ''
    }
    It 'leaves no state-writer boolean on the outer runner''s success stream' {
        $leaks = Get-UncapturedCall -Path $outerFile -Name $boolReturningWriter
        $leaks -join '; ' | Should -Be ''
    }
}

Describe 'Wait-OuterInterruptible' {
    It 'returns immediately when shutdown is already requested' {
        $state = @{ Requested = $true }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cut = Wait-OuterInterruptible -Seconds 30 -ShutdownState $state
        $sw.Stop()
        $cut | Should -Be $true
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
    }
    It 'sleeps in slices small enough to notice a shutdown mid-wait' {
        $state = @{ Requested = $false }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cut = Wait-OuterInterruptible -Seconds 2 -ShutdownState $state -SliceSeconds 1
        $sw.Stop()
        $cut | Should -Be $false
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 1
    }
}

Describe 'The inner spawn inherits the console rather than a pipe' {
    # The cycle process reaches the inner runner through the call operator, and
    # PowerShell decides the inner's stdout from what happens to the ENCLOSING
    # function's success stream: let it reach the host and the inner inherits the
    # console; capture it anywhere up the chain and PowerShell has to create an
    # anonymous pipe and read it to EOF. EOF -- not the inner's exit -- is then what
    # releases the cycle. The inner spawns the status service, which inherits a
    # duplicate of that write end and holds it for its whole unbounded life, so the
    # cycle never returns: the inner logs "about to exit with code 0" and
    # "[outer cycle N] outer runner back in control" never follows. One cycle
    # passes and the runner starts no more. Observed on a live Hyper-V host with
    # the cycle process blocked 44 minutes past a passing cycle, released within a
    # second of killing the status service.
    #
    # Windows only: the POSIX branch of Start-StatusService.ps1 detaches through
    # `bash -c "... </dev/null >/dev/null 2>err &"`, whose redirections replace the
    # descriptors outright, so nothing crosses the exec and no Linux/macOS host in
    # the pool ever showed this.
    #
    # Defined in BeforeAll, not at file scope: Pester 5 runs an It in a scope that
    # cannot see file-scope functions (five tests above this one already fail that
    # way when the file is run through Invoke-Pester directly).
    BeforeAll {
        function Invoke-HandleLeakFixture {
            <#
            .SYNOPSIS
                Rebuild the cycle -> inner -> status-service topology in a temp dir
                and report whether the cycle process returned once the inner exited.
            .DESCRIPTION
                parent.ps1 stands in for Invoke-TestCycleRunner.ps1: it calls a
                function that &-spawns child.ps1 (the inner). child.ps1
                Start-Process-spawns grandchild.ps1 with all three streams
                redirected -- the shape Start-StatusService.ps1 uses on Windows,
                and the shape that makes CreateProcess pass bInheritHandles=TRUE,
                so the grandchild inherits every inheritable handle the inner holds
                INCLUDING the stdout it was handed. Redirecting the grandchild's
                own three streams does not opt it out of that. Then child.ps1 exits
                while the grandchild keeps running.

                -Capture reads the function's value off the SUCCESS STREAM. That is
                the only difference between the two cases, and the whole point.
            .OUTPUTS
                [bool] -- $true when the parent exited inside the timeout.
            #>
            param([switch]$Capture, [int]$TimeoutSeconds = 6, [int]$GrandchildSeconds = 25)

            $pwshExe = [Environment]::ProcessPath
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna leak ' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $parent = $null
            try {
                Set-Content -LiteralPath (Join-Path $dir 'grandchild.ps1') -Encoding utf8 -Value @'
param([string]$PidFile, [int]$Seconds)
Set-Content -LiteralPath $PidFile -Value $PID
Start-Sleep -Seconds $Seconds
'@
                Set-Content -LiteralPath (Join-Path $dir 'child.ps1') -Encoding utf8 -Value @'
param([string]$Dir, [string]$PwshExe, [int]$Seconds)
$stdin = Join-Path $Dir 'in.empty'
[System.IO.File]::WriteAllBytes($stdin, [byte[]]@())
Start-Process -FilePath $PwshExe -WindowStyle Hidden `
    -ArgumentList '-NoProfile', '-File', ('"' + (Join-Path $Dir 'grandchild.ps1') + '"'),
                  '-PidFile', ('"' + (Join-Path $Dir 'gc.pid') + '"'), '-Seconds', "$Seconds" `
    -RedirectStandardInput  $stdin `
    -RedirectStandardOutput (Join-Path $Dir 'gc.out') `
    -RedirectStandardError  (Join-Path $Dir 'gc.err') | Out-Null
'inner done'
'@
                Set-Content -LiteralPath (Join-Path $dir 'parent.ps1') -Encoding utf8 -Value @'
param([string]$Dir, [string]$PwshExe, [int]$Seconds, [switch]$Capture)
function Invoke-Cycle {
    & $PwshExe -NoProfile -File (Join-Path $Dir 'child.ps1') -Dir $Dir -PwshExe $PwshExe -Seconds $Seconds
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE }
}
if ($Capture) { $result = Invoke-Cycle; $null = $result } else { Invoke-Cycle }
'@
                $argList = @('-NoProfile', '-File', ('"' + (Join-Path $dir 'parent.ps1') + '"'),
                             '-Dir', ('"' + $dir + '"'), '-PwshExe', ('"' + $pwshExe + '"'),
                             '-Seconds', "$GrandchildSeconds")
                if ($Capture) { $argList += '-Capture' }
                $parent = Start-Process -FilePath $pwshExe -ArgumentList $argList -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput (Join-Path $dir 'parent.out') `
                    -RedirectStandardError  (Join-Path $dir 'parent.err')
                return [bool]$parent.WaitForExit($TimeoutSeconds * 1000)
            } finally {
                # The grandchild outlives the timeout on purpose, so the wedge is
                # unambiguous; reap it (and a parent still blocked on the pipe)
                # rather than leaving either behind.
                $gcPidFile = Join-Path $dir 'gc.pid'
                if (Test-Path -LiteralPath $gcPidFile) {
                    $gcPid = try { [int](Get-Content -LiteralPath $gcPidFile -Raw).Trim() } catch { 0 }
                    if ($gcPid) { Stop-Process -Id $gcPid -Force -ErrorAction SilentlyContinue }
                }
                if ($parent -and -not $parent.HasExited) {
                    Stop-Process -Id $parent.Id -Force -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'wedges past the inner''s exit when the cycle result is read off the success stream' -Skip:(-not $IsWindows) {
        Invoke-HandleLeakFixture -Capture | Should -Be $false
    }
    It 'returns as soon as the inner exits when the success stream reaches the host' -Skip:(-not $IsWindows) {
        Invoke-HandleLeakFixture | Should -Be $true
    }
}

Describe 'The cycle result travels out of band' {
    # Self-contained Its (paths re-derived here, no Describe-scope fixture) so they
    # hold under Pester 4 and 5 -- same reason as the spaced-path test below.
    It 'never assigns or pipes Invoke-RunnerOuterCycle in the cycle runner' {
        # Guards the fix for the wedge above from the source: the call has to sit
        # bare in a statement block. An assignment, a pipe, a return, or a
        # [void](...) around it all re-create the pipe and re-wedge every Hyper-V
        # host in the pool after exactly one passing cycle.
        $cycleScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-TestCycleRunner.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($cycleScript, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Invoke-RunnerOuterCycle'
        }, $true))
        # A missing call would pass the capture check vacuously, which is the one
        # way this guard could go quiet without the contract actually holding.
        $calls.Count | Should -BeGreaterThan 0
        $captured = @($calls | Where-Object {
            $pipeline = $_.Parent
            if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
                $pipeline.PipelineElements.Count -gt 1) { return $true }
            -not ($pipeline.Parent -is [System.Management.Automation.Language.NamedBlockAst] -or
                  $pipeline.Parent -is [System.Management.Automation.Language.StatementBlockAst])
        } | ForEach-Object { "line $($_.Extent.StartLineNumber)" })
        $captured -join '; ' | Should -Be ''
    }
    It 'reads the outcome back through the module instead' {
        $cycleScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-TestCycleRunner.ps1'
        (Get-Content -LiteralPath $cycleScript -Raw) | Should -Match 'Get-LastOuterCycleResult'
    }
    It 'records the result of the cycle it just ran' {
        $state = @{
            RepoRoot = (Split-Path -Parent $PSScriptRoot); ConfigPath = 'x'; InnerScript = 'x'; PwshExe = 'pwsh'
            ArgList = @(); ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }
            NoGitPull = $false; FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1
            OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
            StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
        }
        # A failed pull is the cheapest real return path -- no spawn, no watchdog.
        Mock -CommandName Invoke-OuterGitPull -MockWith { $false } -ModuleName Test.RunnerOuterLoop
        $returned = Invoke-RunnerOuterCycle -State $state -Cycle 1
        $recorded = Get-LastOuterCycleResult
        $recorded.Outcome  | Should -Be $returned.Outcome
        $recorded.ExitCode | Should -Be $returned.ExitCode
    }
}

Describe 'Cycle dispatch' {
    It 'falls back to running in-process when no cycle script is configured' {
        # Keeps the loop working if the script is missing, at the cost of the reload.
        $state = @{
            CycleScript = ''
            RepoRoot = $testRoot; ConfigPath = 'x'; InnerScript = 'x'; PwshExe = 'pwsh'
            ArgList = @(); ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }
            NoGitPull = $true; FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1
            OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
            StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
        }
        Mock -CommandName Invoke-RunnerOuterCycle -MockWith {
            [pscustomobject]@{ Outcome = 'completed'; ExitCode = 7 }
        } -ModuleName Test.RunnerOuterLoop
        $r = Invoke-OuterCycleDispatch -State $state -Cycle 1
        $r.Outcome  | Should -Be 'completed'
        $r.ExitCode | Should -Be 7
    }
    It 'quotes a cycle-script path that contains spaces' {
        # Start-Process joins -ArgumentList with spaces and does NOT quote, so an
        # unquoted C:\Users\Yuruna Test\...\Invoke-TestCycleRunner.ps1 is re-split by
        # CreateProcess and the child pwsh reports "The argument 'C:\Users\Yuruna' is
        # not recognized as the name of a script file" and exits 64 -- which the outer
        # reads as a failed cycle, so a host whose path has a space never runs one.
        # Self-contained (no Describe-scope fixture) so it holds under Pester 4 and 5.
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna cycle ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $spacedScript = Join-Path $dir 'Invoke-TestCycleRunner.ps1'
        Set-Content -LiteralPath $spacedScript -Value '# spawn fixture' -Encoding utf8
        $priorRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $dir
        try {
            Mock -CommandName Start-Process -MockWith {
                [pscustomobject]@{ Id = $PID; HasExited = $true; ExitCode = 0 }
            } -ModuleName Test.RunnerOuterLoop
            $state = @{
                CycleScript = $spacedScript
                PwshExe     = 'pwsh'
                ShutdownState = @{ Requested = $false }
            }
            $r = Invoke-OuterCycleDispatch -State $state -Cycle 3
            $r.ExitCode | Should -Be 0
            Assert-MockCalled -CommandName Start-Process -ModuleName Test.RunnerOuterLoop -Exactly -Times 1 -Scope It -ParameterFilter {
                $i = [array]::IndexOf([object[]]$ArgumentList, '-File')
                $i -ge 0 -and ([string]$ArgumentList[$i + 1]) -like '"* *"'
            }
        } finally {
            $env:YURUNA_RUNTIME_DIR = $priorRuntimeDir
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
