<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42fec9c0-cd2a-40fb-b30b-bf873044d79b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner process reclamation host-refresh pester
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
    Runner reclamation: the process-table builders, the exclusion set, the
    reclaim plan and its re-snapshot comparison, and the signaling that stops
    only revalidated single PIDs.
.DESCRIPTION
    The table builders run against a fixture /proc tree, a stand-in ps on a
    private path and injected CIM rows, so all three parsers are exercised on
    any host; the live table and every signal run against disposable
    stand-in processes this suite spawns and kills itself. Nothing here reads
    or signals the operator's runner.

    The source gates read the reclamation functions, the resumed runner's
    single-instance branch and the refresh entry point by AST: none may reach
    the tree-kill helpers or taskkill /T.
#>

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.CriticalRecord.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.SingleInstance.psm1') -Force -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $script:Here
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-reclaim'
    $script:Spawned = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

    function New-FixtureProcRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds a throwaway /proc tree under the suite temp dir.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([switch]$NoBootTime)
        $root = Join-Path $script:Work ('proc-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        if (-not $NoBootTime) {
            Set-Content -LiteralPath (Join-Path $root 'stat') -Value "cpu  1 2 3`nbtime 1700000000`nprocesses 9" -Encoding ascii
        }
        $tail = @(0..20 | ForEach-Object { '0' }) -join ' '
        function Add-FixtureProcess {
            param([int]$ProcessId, [string]$Comm, [string]$State, [int]$ParentPid, [int]$Group, [long]$StartTicks, [string[]]$Argv, [int]$Uid = 1001)
            $dir = Join-Path $root "$ProcessId"
            $null = New-Item -ItemType Directory -Path $dir -Force
            # Fields after the comm: state ppid pgrp session tty tpgid flags minflt
            # cminflt majflt cmajflt utime stime cutime cstime priority nice
            # num_threads itrealvalue starttime ...
            $fields = @($State, $ParentPid, $Group, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 1, 0, $StartTicks) -join ' '
            [System.IO.File]::WriteAllText((Join-Path $dir 'stat'), "$ProcessId ($Comm) $fields $tail")
            [System.IO.File]::WriteAllText((Join-Path $dir 'status'), "Name:`t$Comm`nUid:`t$Uid`t$Uid`t$Uid`t$Uid`n")
            # An if-expression would unroll an empty byte array to $null.
            $bytes = [byte[]]::new(0)
            if ($Argv.Count -gt 0) { $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Argv -join [char]0) + [char]0) }
            [System.IO.File]::WriteAllBytes((Join-Path $dir 'cmdline'), $bytes)
        }
        Add-FixtureProcess -ProcessId 100 -Comm 'odd) (name here' -State 'S' -ParentPid 1 -Group 100 -StartTicks 12345 -Argv @('/usr/bin/pwsh', '-File', '/repo/test/Start-TestRunner.ps1')
        # A dangling target: only the link text is read, and a cleanup that
        # followed the link could never reach anything through it.
        if (-not $IsWindows) { [System.IO.File]::CreateSymbolicLink((Join-Path $root '100/cwd'), '/fixture/checkout/of/100') | Out-Null }
        Add-FixtureProcess -ProcessId 101 -Comm 'sleep' -State 'S' -ParentPid 100 -Group 100 -StartTicks 20000 -Argv @('sleep')
        Add-FixtureProcess -ProcessId 102 -Comm 'zombie' -State 'Z' -ParentPid 100 -Group 100 -StartTicks 20001 -Argv @()
        Add-FixtureProcess -ProcessId 103 -Comm 'kthread' -State 'S' -ParentPid 2 -Group 0 -StartTicks 1 -Argv @() -Uid 0
        # A pid that vanished between the directory listing and the read.
        $null = New-Item -ItemType Directory -Path (Join-Path $root '104') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'self-not-a-pid') -Force
        return $root
    }

    function New-FakePsScript {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a stand-in ps script under the suite temp dir.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Body, [string]$EnvCapture)
        $path = Join-Path $script:Work ('ps-' + [guid]::NewGuid().ToString('N'))
        $text = "#!/bin/bash`nprintf 'LC_ALL=%s TZ=%s ARGS=%s\n' ""`$LC_ALL"" ""`$TZ"" ""`$*"" > '$EnvCapture'`n$Body`n"
        [System.IO.File]::WriteAllText($path, $text)
        & chmod +x $path
        return $path
    }

    function Start-StandIn {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: spawns a disposable stand-in process the suite kills in AfterAll.')]
        [CmdletBinding()]
        [OutputType([System.Diagnostics.Process])]
        param([Parameter(Mandatory)][string]$Script)
        $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/bash')
        $psi.ArgumentList.Add('-c')
        $psi.ArgumentList.Add($Script)
        $psi.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($psi)
        $script:Spawned.Add($process)
        Start-Sleep -Milliseconds 300
        return $process
    }

    function Get-StandInPlan {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([Parameter(Mandatory)][System.Diagnostics.Process]$Root, [int[]]$ExcludedPid = @())
        $table = Get-YurunaProcessTable
        $row = @($table.Rows | Where-Object { $_.Pid -eq $Root.Id })[0]
        $roots = @([pscustomobject]@{ Pid = $Root.Id; StartTimeUnixMs = $row.StartTimeUnixMs; Role = 'inner' })
        $target = Resolve-YurunaRunnerProcessTarget -ProcessTable $table.Rows -VerifiedRoot $roots -ExcludedPid $ExcludedPid
        return [pscustomobject]@{ Roots = $roots; Target = $target; Table = $table }
    }

    function Get-FunctionCommandName {
        [CmdletBinding()]
        [OutputType([string[]], [object[]])]
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$FunctionName)
        $ast = Get-YurunaTestFileAst -Path $Path
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            if ($FunctionName -notcontains $fn.Name) { continue }
            foreach ($cmd in @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                $text = ($cmd.CommandElements | ForEach-Object { $_.Extent.Text }) -join ' '
                $names.Add("$($cmd.GetCommandName())|$text")
            }
        }
        return , $names.ToArray()
    }
}

AfterAll {
    foreach ($process in @($script:Spawned)) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
    }
    Remove-YurunaTestTempDir $script:Work
}

Describe 'Get-YurunaProcessTable -- Linux /proc parser (fixture tree)' {
    BeforeEach { InModuleScope Test.SingleInstance { $script:LinuxClockTicks = 100 } }

    It 'counts stat fields after the last parenthesis, reads uid and argv, and skips zombies, vanished pids and non-pid dirs' {
        $root = New-FixtureProcRoot
        $t = Get-YurunaProcessTable -Platform Linux -ProcRoot $root
        Assert-True $t.Complete 'a fully read fixture is complete'
        Assert-Equal -Expected 'proc' -Actual $t.Source
        Assert-Equal -Expected 3 -Actual @($t.Rows).Count -Because 'zombie 102, vanished 104 and the non-pid dir are not rows'
        $runner = @($t.Rows | Where-Object Pid -eq 100)[0]
        Assert-Equal -Expected 1 -Actual $runner.ParentPid
        Assert-Equal -Expected 100 -Actual $runner.ProcessGroupId
        Assert-Equal -Expected ([long](1700000000 * 1000 + 123450)) -Actual $runner.StartTimeUnixMs -Because 'btime + starttime/USER_HZ, in ms'
        Assert-Equal -Expected '1001' -Actual $runner.OwnerId
        Assert-True ($runner.Argv -is [string[]]) 'argv stays a string array'
        Assert-Equal -Expected 3 -Actual $runner.Argv.Count
        Assert-Equal -Expected '/usr/bin/pwsh -File /repo/test/Start-TestRunner.ps1' -Actual $runner.CommandLine
        $single = @($t.Rows | Where-Object Pid -eq 101)[0]
        Assert-True ($single.Argv -is [string[]] -and $single.Argv.Count -eq 1) 'a one-element argv is not unrolled'
        $kernel = @($t.Rows | Where-Object Pid -eq 103)[0]
        Assert-Equal -Expected 0 -Actual $kernel.Argv.Count -Because 'an empty cmdline is an empty argv'
        Assert-Equal -Expected 'kthread' -Actual $kernel.Executable -Because 'without argv or a readable exe link the comm names it'
        if (-not $IsWindows) { Assert-Equal -Expected '/fixture/checkout/of/100' -Actual $runner.WorkingDirectory -Because 'the cwd link is the working directory' }
        Assert-Null $single.WorkingDirectory
    }

    It 'is incomplete without btime, and never mistakes that for an empty table' {
        $t = Get-YurunaProcessTable -Platform Linux -ProcRoot (New-FixtureProcRoot -NoBootTime)
        Assert-False $t.Complete 'no boot time: no start times, nothing proven'
        Assert-Equal -Expected 'btime-unreadable' -Actual $t.Error
        Assert-Null @($t.Rows)[0].StartTimeUnixMs
    }

    It 'is incomplete when a stat record cannot be parsed' {
        $root = New-FixtureProcRoot
        [System.IO.File]::WriteAllText((Join-Path $root '101/stat'), 'garbage without parentheses')
        $t = Get-YurunaProcessTable -Platform Linux -ProcRoot $root
        Assert-False $t.Complete 'an unparseable row leaves the table incomplete'
        Assert-Match -Pattern 'stat-unparseable' -Actual $t.Error
    }

    It 'restricts to selected pids, and a selected pid that is absent is proven absent' {
        $root = New-FixtureProcRoot
        $t = Get-YurunaProcessTable -Platform Linux -ProcRoot $root -ProcessId @(101, 999)
        Assert-True $t.Complete 'the selection was read completely'
        Assert-Equal -Expected 1 -Actual @($t.Rows).Count
        Assert-Equal -Expected 101 -Actual @($t.Rows)[0].Pid
    }

    It 'stops early and reports incomplete when the deadline is already spent' {
        $expired = New-YurunaDeadline -TotalMilliseconds 0
        $t = Get-YurunaProcessTable -Platform Linux -ProcRoot (New-FixtureProcRoot) -Deadline $expired
        Assert-False $t.Complete 'an expired deadline proves nothing'
        Assert-Equal -Expected 'deadline-exhausted' -Actual $t.Error
    }
}

Describe 'Get-YurunaProcessTable -- live table on this host' -Skip:$IsWindows {
    It 'reports this process with the start time .NET reports, within the identity tolerance' {
        $t = Get-YurunaProcessTable
        Assert-True $t.Complete 'the live table completes'
        $me = @($t.Rows | Where-Object Pid -eq $PID)[0]
        Assert-NotNull $me
        Assert-Equal -Expected $(if ($IsMacOS) { 'ps' } else { 'proc' }) -Actual $t.Source
        Assert-Equal -Expected ([string](Get-YurunaCurrentOwnerId).OwnerId) -Actual ([string]$me.OwnerId)
        $net = ([DateTimeOffset](Get-Process -Id $PID).StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
        Assert-True ([Math]::Abs($me.StartTimeUnixMs - $net) -le 2000) "start times differ by $($me.StartTimeUnixMs - $net) ms"
    }
    It 'reports a spawned child with this process as its parent' {
        $child = Start-StandIn -Script 'sleep 60'
        try {
            $row = @((Get-YurunaProcessTable -ProcessId @($child.Id)).Rows)[0]
            Assert-Equal -Expected $PID -Actual $row.ParentPid
        } finally {
            $child.Kill($true)
        }
    }
}

Describe 'Get-YurunaRunnerSnapshot -- a runner started by a relative path (real stand-ins)' -Skip:(-not $IsLinux) {
    BeforeAll {
        function New-CheckoutFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: two stand-in checkouts, a link to one, a runtime and a private root under the suite temp dir.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()
            $base = Join-Path $script:Work ('checkout-' + [guid]::NewGuid().ToString('N'))
            foreach ($name in @('mine', 'other')) {
                $null = New-Item -ItemType Directory -Path (Join-Path $base "$name/test") -Force
                Set-Content -LiteralPath (Join-Path $base "$name/test/Start-TestRunner.ps1") -Value 'Start-Sleep -Seconds 120' -Encoding utf8NoBOM
            }
            $f = @{ Base = $base; Mine = (Join-Path $base 'mine'); Other = (Join-Path $base 'other'); Link = (Join-Path $base 'link')
                Runtime = (Join-Path $base 'runtime'); Private = (Join-Path $base 'private') }
            $null = New-Item -ItemType Directory -Path $f.Runtime, $f.Private -Force
            $null = New-Item -ItemType SymbolicLink -Path $f.Link -Target $f.Mine
            return $f
        }
        function Start-RelativeRunner {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: a disposable pwsh stand-in the suite kills in AfterAll.')]
            [CmdletBinding()]
            [OutputType([System.Diagnostics.Process])]
            param([Parameter(Mandatory)][hashtable]$F, [Parameter(Mandatory)][string]$From)
            $psi = [System.Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
            foreach ($a in @('-NoProfile', '-NonInteractive', 'test/Start-TestRunner.ps1')) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory = $From
            $psi.UseShellExecute = $false
            $process = [System.Diagnostics.Process]::Start($psi)
            $script:Spawned.Add($process)
            $until = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 50 }
            Set-Content -LiteralPath (Join-Path $F.Runtime 'runner.pid') -Value "$($process.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $F.Runtime 'runner.start') -Value $process.StartTime.ToUniversalTime().ToString('o') -Encoding utf8NoBOM
            return $process
        }
    }

    It 'owns the documented `pwsh test/Start-TestRunner.ps1` launch, through a linked checkout too, and plans its reclaim' {
        $f = New-CheckoutFixture
        $runner = Start-RelativeRunner -F $f -From $f.Mine
        try {
            foreach ($root in @($f.Mine, $f.Link)) {
                $snapshot = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $root -PrivateRoot $f.Private
                Assert-Equal -Expected 'AliveOwned' -Actual $snapshot.Outer.State -Because "judged against $root ($($snapshot.Outer.Reason))"
                $plan = New-YurunaRunnerReclaimPlan -Snapshot $snapshot
                Assert-True $plan.Reclaimable "no refusal ($(@($plan.Refusals | ForEach-Object { "$($_.Role):$($_.Reason)" }) -join ','))"
                Assert-True (@($plan.Roots | Where-Object { $_.Role -eq 'outer' -and $_.Pid -eq $runner.Id }).Count -eq 1) 'the outer is a root'
            }
            $foreign = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $f.Other -PrivateRoot $f.Private
            Assert-Equal -Expected 'AliveOther' -Actual $foreign.Outer.State
            Assert-Equal -Expected 'other-checkout' -Actual $foreign.Outer.Reason
        } finally {
            $runner.Kill()
            Remove-Item -LiteralPath $f.Link -Force -ErrorAction SilentlyContinue
        }
    }

    It 'owns the runner its launch record attests, even when its command line places it elsewhere' {
        $f = New-CheckoutFixture
        $runner = Start-RelativeRunner -F $f -From $f.Other
        try {
            $before = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $f.Mine -PrivateRoot $f.Private
            Assert-Equal -Expected 'other-checkout' -Actual $before.Outer.Reason -Because 'without a record the command line decides'
            $record = [ordered]@{
                schemaVersion = 1; runnerProtocolVersion = 1; scriptPath = (Join-Path $f.Mine 'test/Start-TestRunner.ps1'); repoRoot = $f.Mine
                runtimeDir = (Resolve-YurunaCanonicalPath -Path $f.Runtime).Path; workingDirectory = $f.Other
                runner = @{ pid = $runner.Id; startTimeUnixMs = (Get-YurunaProcessStartUnixMs -ProcessId $runner.Id) }
                parameters = @{ ConfigPath = 'x' }; explicitlyBound = @(); environment = @{}; writtenUtc = 'x'; endedUtc = $null; cleanExit = $false
            }
            $path = Join-Path $f.Private "runner-launch.$(Get-YurunaRuntimeKey -RuntimeDir $f.Runtime).record"
            $written = Write-YurunaCriticalRecord -Path $path -Kind 'runner-launch' -Payload $record -ExpectedGeneration 0 -Confirm:$false
            Assert-True $written.Committed "launch record written ($($written.Reason))"
            $after = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $f.Mine -PrivateRoot $f.Private
            Assert-True $after.LaunchRecord.Valid "the record reads back ($($after.LaunchRecord.Reason))"
            Assert-Equal -Expected 'AliveOwned' -Actual $after.Outer.State
            Assert-Equal -Expected 'launch-record' -Actual $after.Outer.Reason
            $elsewhere = Get-YurunaRunnerSnapshot -RuntimeDir $f.Runtime -RepoRoot $f.Other -PrivateRoot $f.Private
            Assert-Equal -Expected 'AliveOwned' -Actual $elsewhere.Outer.State -Because 'the command line itself names the other checkout here'
            Assert-Equal -Expected 'start-time' -Actual $elsewhere.Outer.Reason -Because 'the record names a script outside that checkout, so it attests nothing there'
        } finally {
            $runner.Kill()
            Remove-Item -LiteralPath $f.Link -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-YurunaProcessTable -- macOS ps parser (stand-in ps)' -Skip:$IsWindows {
    It 'parses lstart under LC_ALL=C and TZ=UTC0, including a space-padded day' {
        $capture = Join-Path $script:Work 'ps-env.txt'
        $body = @'
printf '  101     1   101   501 Thu Sep 25 03:37:12 2026 /usr/local/bin/pwsh -NoProfile -File /repo/test/Start-TestRunner.ps1\n'
printf '  102   101   101   501 Fri Sep  5 23:01:02 2026 sleep 30\n'
'@
        $t = Get-YurunaProcessTable -Platform MacOS -PsPath (New-FakePsScript -Body $body -EnvCapture $capture)
        Assert-True $t.Complete 'two parseable lines'
        Assert-Equal -Expected 2 -Actual @($t.Rows).Count
        $first = @($t.Rows)[0]
        $expected = ([DateTimeOffset]::new(2026, 9, 25, 3, 37, 12, [TimeSpan]::Zero)).ToUnixTimeMilliseconds()
        Assert-Equal -Expected $expected -Actual $first.StartTimeUnixMs
        Assert-Equal -Expected '501' -Actual $first.OwnerId
        Assert-Equal -Expected 101 -Actual $first.ProcessGroupId
        Assert-Match -Pattern 'Start-TestRunner\.ps1' -Actual $first.CommandLine
        $second = @($t.Rows)[1]
        Assert-Equal -Expected (([DateTimeOffset]::new(2026, 9, 5, 23, 1, 2, [TimeSpan]::Zero)).ToUnixTimeMilliseconds()) -Actual $second.StartTimeUnixMs
        $envSeen = Get-Content -LiteralPath $capture -Raw
        Assert-Match -Pattern 'LC_ALL=C TZ=UTC0' -Actual $envSeen
        Assert-Match -Pattern 'pid=,ppid=,pgid=,uid=,lstart=,command=' -Actual $envSeen
    }
    It 'is incomplete, not empty, when ps hangs past its bound' {
        $t = Get-YurunaProcessTable -Platform MacOS -TimeoutSeconds 2 -PsPath (New-FakePsScript -Body 'sleep 30' -EnvCapture (Join-Path $script:Work 'ps-hang.txt'))
        Assert-False $t.Complete 'a timed-out ps proves nothing'
        Assert-Equal -Expected 'timeout' -Actual $t.Error
    }
    It 'is incomplete when a line does not parse' {
        $t = Get-YurunaProcessTable -Platform MacOS -PsPath (New-FakePsScript -Body "printf 'not a ps line\n'" -EnvCapture (Join-Path $script:Work 'ps-bad.txt'))
        Assert-False $t.Complete 'an unparseable line leaves the table incomplete'
        Assert-Match -Pattern 'unparseable-lines:1' -Actual $t.Error
    }
    It 'is incomplete when ps fails' {
        $t = Get-YurunaProcessTable -Platform MacOS -PsPath (New-FakePsScript -Body 'exit 3' -EnvCapture (Join-Path $script:Work 'ps-fail.txt'))
        Assert-False $t.Complete 'a failed ps proves nothing'
        Assert-Equal -Expected 'ps-exit-3' -Actual $t.Error
    }
}

Describe 'Get-YurunaProcessTable -- Windows CIM parser (injected rows)' {
    It 'maps Win32_Process rows, with the session id as owner' {
        $created = [datetime]::SpecifyKind([datetime]'2026-09-25T10:00:00', [DateTimeKind]::Utc)
        $t = Get-YurunaProcessTable -Platform Windows -CimQuery {
            param($Filter, $TimeoutSec)
            $null = $Filter; $null = $TimeoutSec
            [pscustomobject]@{ ProcessId = 40; ParentProcessId = 4; CreationDate = $created; CommandLine = 'pwsh -File C:\r\test\Start-TestRunner.ps1'; ExecutablePath = 'C:\pwsh.exe'; SessionId = 1 }
        }.GetNewClosure()
        Assert-True $t.Complete 'injected rows complete'
        Assert-Equal -Expected 'cim' -Actual $t.Source
        $row = @($t.Rows)[0]
        Assert-Equal -Expected 40 -Actual $row.Pid
        Assert-Equal -Expected '1' -Actual $row.OwnerId
        Assert-Equal -Expected (([DateTimeOffset]$created).ToUnixTimeMilliseconds()) -Actual $row.StartTimeUnixMs
        Assert-Null $row.ProcessGroupId
    }
    It 'passes a PID filter to the query when PIDs are selected' {
        $seen = @{}
        $null = Get-YurunaProcessTable -Platform Windows -ProcessId @(7, 9) -CimQuery { param($Filter, $TimeoutSec) $null = $TimeoutSec; $seen.Filter = $Filter }.GetNewClosure()
        Assert-Equal -Expected 'ProcessId=7 OR ProcessId=9' -Actual $seen.Filter
    }
    It 'is incomplete when the query throws' {
        $t = Get-YurunaProcessTable -Platform Windows -CimQuery { throw 'CIM unavailable' }
        Assert-False $t.Complete 'a failed query proves nothing'
        Assert-Match -Pattern 'table-failed' -Actual $t.Error
    }
}

Describe 'Get-YurunaRunnerExclusionSet' {
    BeforeAll {
        $script:Rt = '/rt/runtime'
        $script:Repo = '/repo'
        function New-Row {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory process row; no system state.')]
            param([int]$ProcessId, [int]$ParentPid, [string]$CommandLine = 'pwsh', [string]$Owner = '1001')
            [pscustomobject]@{ Pid = $ProcessId; ParentPid = $ParentPid; StartTimeUnixMs = [long]1000; Executable = 'pwsh'; CommandLine = $CommandLine; Argv = $null; OwnerId = $Owner; ProcessGroupId = $null }
        }
        $script:Rows = @(
            (New-Row -ProcessId 30 -ParentPid 1 -CommandLine 'tmux')
            (New-Row -ProcessId 40 -ParentPid 30 -CommandLine 'sg libvirt')
            (New-Row -ProcessId 50 -ParentPid 40 -CommandLine 'pwsh -File /repo/test/lab/Invoke-HostRefresh.ps1')
            (New-Row -ProcessId 60 -ParentPid 20 -CommandLine 'pwsh -File /rt/runtime/.status-service.ps1')
            (New-Row -ProcessId 61 -ParentPid 20 -CommandLine 'pwsh -File /repo/test/modules/Invoke-HostAddressBeacon.ps1')
            (New-Row -ProcessId 62 -ParentPid 1 -CommandLine 'pwsh -File /repo/test/service/Start-StashServiceVM.ps1')
            (New-Row -ProcessId 63 -ParentPid 1 -CommandLine 'pwsh -File /repo/test/Start-TestRunner.ps1' -Owner '999')
            (New-Row -ProcessId 64 -ParentPid 1 -CommandLine 'pwsh -File /other/test/Start-TestRunner.ps1')
            (New-Row -ProcessId 20 -ParentPid 10 -CommandLine "pwsh -Command & '/repo/test/modules/Invoke-TestRunnerInnerLoop.ps1'")
            (New-Row -ProcessId 10 -ParentPid 1 -CommandLine 'pwsh -File /repo/test/modules/Invoke-TestCycleRunner.ps1')
        )
        $script:Table = [pscustomobject]@{ Complete = $true; Platform = 'Linux'; Rows = $script:Rows }
    }

    It 'excludes the worker, the status server and beacon by command line, service scripts and other owners; protects the ancestry' {
        $server = [pscustomobject]@{ Pid = 70; State = 'Unknown' }
        $configServer = [pscustomobject]@{ Pid = 71; State = 'DeadOrRecycled' }
        $x = Get-YurunaRunnerExclusionSet -ProcessTable $script:Table -RepoRoot $script:Repo -RuntimeDir $script:Rt -WorkerPid 50 `
            -ServerRecord $server -ConfigServerRecord $configServer
        foreach ($excluded in @(50, 60, 61, 62, 63, 70)) {
            Assert-True ($x.ExcludedPid -contains $excluded) "pid $excluded is excluded"
        }
        Assert-False ($x.ExcludedPid -contains 71) 'a dead config-server record excludes nothing'
        Assert-False ($x.ExcludedPid -contains 64) 'a runner from another checkout is not an exclusion (it is never a root either)'
        Assert-Equal -Expected '40,30' -Actual (@($x.ProtectedPid) -join ',') -Because 'the sg hop and the shared tmux ancestor are protected, not pruned'
        Assert-True ($x.ExcludedPid -is [int[]]) 'typed int array'
        Assert-True (@($x.Evidence | Where-Object { $_.Pid -eq 70 -and $_.Rule -eq 'pidfile-unknown' }).Count -eq 1) 'uncertainty protects, with its evidence'
    }

    It 'prunes the Windows-shape server and beacon (children of the inner) before expansion' {
        $x = Get-YurunaRunnerExclusionSet -ProcessTable $script:Table -RepoRoot $script:Repo -RuntimeDir $script:Rt -WorkerPid 50
        $snapshot = [pscustomobject]@{
            Table = $script:Table
            Inner = [pscustomobject]@{ State = 'AliveOwned'; Pid = 20; LiveStartTimeUnixMs = [long]1000; Reason = 'start-time' }
            Cycle = [pscustomobject]@{ State = 'AliveOwned'; Pid = 10; LiveStartTimeUnixMs = [long]1000; Reason = 'start-time' }
            Outer = [pscustomobject]@{ State = 'Missing'; Pid = 0; Reason = 'record-missing' }
            Exclusions = $x
        }
        $plan = New-YurunaRunnerReclaimPlan -Snapshot $snapshot -WorkerPid 50
        $targets = @($plan.Target.Descendants | ForEach-Object Pid)
        Assert-Equal -Expected '20,10' -Actual ($targets -join ',') -Because 'the server and beacon under the inner are pruned; inner before cycle'
    }
}

Describe 'New-YurunaRunnerReclaimPlan and Compare-YurunaRunnerReclaimPlan' {
    BeforeAll {
        function New-Snapshot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory runner snapshot; no system state.')]
            param([string]$OuterState = 'AliveOwned', [switch]$ExtraChild, [switch]$Incomplete, [long]$InnerStart = 3000)
            $rows = @(
                [pscustomobject]@{ Pid = 1; ParentPid = 0; StartTimeUnixMs = [long]1000; CommandLine = 'outer' }
                [pscustomobject]@{ Pid = 2; ParentPid = 1; StartTimeUnixMs = [long]2000; CommandLine = 'cycle' }
                [pscustomobject]@{ Pid = 3; ParentPid = 2; StartTimeUnixMs = $InnerStart; CommandLine = 'inner' }
                [pscustomobject]@{ Pid = 4; ParentPid = 3; StartTimeUnixMs = [long]4000; CommandLine = 'virsh' }
            )
            if ($ExtraChild) { $rows += [pscustomobject]@{ Pid = 5; ParentPid = 3; StartTimeUnixMs = [long]5000; CommandLine = 'new child' } }
            [pscustomobject]@{
                Table = [pscustomobject]@{ Complete = -not $Incomplete; Platform = 'Linux'; Rows = $rows }
                Outer = [pscustomobject]@{ State = $OuterState; Pid = 1; LiveStartTimeUnixMs = [long]1000; Reason = 'start-time' }
                Cycle = [pscustomobject]@{ State = 'AliveOwned'; Pid = 2; LiveStartTimeUnixMs = [long]2000; Reason = 'start-time' }
                Inner = [pscustomobject]@{ State = 'AliveOwned'; Pid = 3; LiveStartTimeUnixMs = $InnerStart; Reason = 'start-time' }
                Exclusions = [pscustomobject]@{ ExcludedPid = [int[]]@(); ProtectedPid = [int[]]@(); Evidence = @() }
            }
        }
    }

    It 'roots inner, cycle, outer in that order and signals the deepest work first' {
        $plan = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot) -WorkerPid 99
        Assert-Equal -Expected 'inner,cycle,outer' -Actual ((@($plan.Roots) | ForEach-Object Role) -join ',')
        Assert-Equal -Expected '4,3,2,1' -Actual ((@($plan.Target.Descendants) | ForEach-Object Pid) -join ',')
        Assert-True $plan.Reclaimable 'three owned records, a complete table'
    }
    It 'refuses (never promotes) an Unknown or AliveOther record' {
        $plan = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot -OuterState 'Unknown') -WorkerPid 99
        Assert-False $plan.Reclaimable 'an Unknown outer is a refusal'
        Assert-Equal -Expected 'outer' -Actual @($plan.Refusals)[0].Role
        Assert-False ((@($plan.Roots) | ForEach-Object Role) -contains 'outer') 'the Unknown record is not a root'
        $other = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot -OuterState 'AliveOther') -WorkerPid 99
        Assert-Equal -Expected 'AliveOther' -Actual @($other.Refusals)[0].State
    }
    It 'refuses an incomplete table' {
        $plan = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot -Incomplete) -WorkerPid 99
        Assert-Equal -Expected 'table-incomplete' -Actual @($plan.Refusals)[0].Reason
    }
    It 'protects the outer under -PreserveOuter while still signaling its children' {
        $plan = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot) -PreserveOuter -WorkerPid 99
        Assert-Equal -Expected '4,3,2' -Actual ((@($plan.Target.Descendants) | ForEach-Object Pid) -join ',')
        Assert-True ($plan.ProtectedPid -contains 1) 'the resident outer is protected'
    }
    It 'reads a new child, or a changed root, as not quiescent; a root that merely exited is fine' {
        $before = New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot) -WorkerPid 99
        Assert-True (Compare-YurunaRunnerReclaimPlan -Before $before -After (New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot) -WorkerPid 99)).Quiescent 'identical plans'
        $child = Compare-YurunaRunnerReclaimPlan -Before $before -After (New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot -ExtraChild) -WorkerPid 99)
        Assert-False $child.Quiescent 'a new child appeared'
        Assert-Equal -Expected 5 -Actual @($child.NewPid)[0]
        $changed = Compare-YurunaRunnerReclaimPlan -Before $before -After (New-YurunaRunnerReclaimPlan -Snapshot (New-Snapshot -InnerStart 90000) -WorkerPid 99)
        Assert-False $changed.Quiescent 'the inner root is a different process now'
        Assert-True ($changed.ChangedRoot -contains 'inner') 'the changed role is named'
    }
}

Describe 'Stop-YurunaRunnerProcessTarget against disposable stand-ins' -Skip:$IsWindows {
    It 'signals the child before the parent and converges on TERM' {
        $root = Start-StandIn -Script 'sleep 300 & wait'
        $plan = Get-StandInPlan -Root $root
        $childPid = @($plan.Target.Descendants)[0].Pid
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -GraceMilliseconds 3000 -Confirm:$false
        Assert-True $r.Converged 'both processes are gone'
        Assert-Equal -Expected "$childPid,$($root.Id)" -Actual ((@($r.Targets) | ForEach-Object Pid) -join ',') -Because 'child first, then the root'
        Assert-True (@($r.Targets | Where-Object Action -notin @('exited-after-term', 'already-exited')).Count -eq 0) 'TERM was enough'
    }
    It 'escalates to KILL for a process that ignores TERM' {
        $root = Start-StandIn -Script "trap '' TERM; exec sleep 300"
        $plan = Get-StandInPlan -Root $root
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -GraceMilliseconds 500 -Confirm:$false
        Assert-True $r.Converged 'KILL ended it'
        Assert-Equal -Expected 'exited-after-kill' -Actual @($r.Targets)[0].Action
        Assert-Equal -Expected 'KILL' -Actual @($r.Targets)[0].Signal
    }
    It 'skips a PID recycled just before the signal and leaves that process alive' {
        $root = Start-StandIn -Script 'exec sleep 300'
        $plan = Get-StandInPlan -Root $root
        foreach ($row in $plan.Target.Descendants) { $row.StartTimeUnixMs -= 60000 }
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -Confirm:$false
        Assert-Equal -Expected 'recycled-skipped' -Actual @($r.Targets)[0].Action
        Assert-False $root.HasExited 'the process now at that PID was never signaled'
        $root.Kill($true)
    }
    It 'never reaches an excluded process under the root' {
        $root = Start-StandIn -Script 'sleep 300 & sleep 301 & wait'
        $table = Get-YurunaProcessTable
        $children = @($table.Rows | Where-Object ParentPid -eq $root.Id)
        Assert-Equal -Expected 2 -Actual $children.Count
        $excluded = @($children | Where-Object { $_.CommandLine -match '301' })[0].Pid
        $plan = Get-StandInPlan -Root $root -ExcludedPid @($excluded)
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -GraceMilliseconds 3000 -Confirm:$false
        Assert-True $r.Converged 'every planned target is gone'
        Assert-False (@($r.Targets | ForEach-Object Pid) -contains $excluded) 'the excluded process was never a target'
        $survivor = Get-Process -Id $excluded -ErrorAction SilentlyContinue
        Assert-NotNull $survivor
        Stop-Process -Id $excluded -Force -ErrorAction SilentlyContinue
    }
    It 'skips everything once the deadline is spent' {
        $root = Start-StandIn -Script 'exec sleep 300'
        $plan = Get-StandInPlan -Root $root
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 0) -Confirm:$false
        Assert-Equal -Expected 'skipped-deadline' -Actual @($r.Targets)[0].Action
        Assert-True $r.DeadlineExhausted 'reported'
        Assert-False $r.Converged 'nothing was stopped'
        Assert-False $root.HasExited 'no signal was sent'
        $root.Kill($true)
    }
    It 'signals nothing under -WhatIf' {
        $root = Start-StandIn -Script 'exec sleep 300'
        $plan = Get-StandInPlan -Root $root
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 10000) -WhatIf
        Assert-Equal -Expected 'whatif' -Actual @($r.Targets)[0].Action
        Assert-False $root.HasExited 'a preview signals nothing'
        $root.Kill($true)
    }
    It 'never signals a row without a start time' {
        $plan = [pscustomobject]@{
            Roots  = @()
            Target = [pscustomobject]@{ Descendants = @([pscustomobject]@{ Pid = $PID; ParentPid = 1; StartTimeUnixMs = $null }) }
        }
        $r = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline (New-YurunaDeadline -TotalMilliseconds 5000) -Confirm:$false
        Assert-Equal -Expected 'skipped-unverifiable' -Actual @($r.Targets)[0].Action
        Assert-True ($r.Survivors -contains $PID) 'reported as a survivor'
    }
}

Describe 'Reclamation source gates' {
    It 'the reclamation functions never reach a tree kill, a stale-runner takeover or taskkill /T' {
        $calls = Get-FunctionCommandName -Path (Join-Path $script:Here 'Test.SingleInstance.psm1') -FunctionName @(
            'Get-YurunaRunnerExclusionSet', 'Get-YurunaRunnerSnapshot', 'New-YurunaRunnerReclaimPlan', 'Compare-YurunaRunnerReclaimPlan',
            'Send-YurunaProcessSignal', 'Stop-YurunaRunnerProcessTarget', 'Invoke-YurunaRunnerRefreshResume', 'Remove-YurunaRunnerRecordGeneration')
        Assert-True ($calls.Count -gt 10) 'the functions were found and read'
        $bad = @($calls | Where-Object { $_ -match '^(Stop-YurunaProcessTree|Stop-ProcessTree|Stop-StaleRunner|pkill|killall)\|' -or ($_ -match 'taskkill' -and $_ -match '/T\b') })
        Assert-NoFinding $bad 'forbidden kill paths in the reclamation region'
    }
    It 'the resumed runner''s single-instance branch never takes over or deletes a record by hand' {
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1')
        $branch = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$RefreshResume' -and
            $n.Clauses[0].Item2.Extent.Text -match 'Get-YurunaRunnerRecordState'
        }, $true))
        Assert-Equal -Expected 1 -Actual $branch.Count -Because 'one resume branch in the single-instance region'
        $names = @($branch[0].Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($forbidden in @('Stop-StaleRunner', 'Stop-YurunaProcessTree', 'Stop-ProcessTree', 'Remove-Item', 'Get-RunnerInstanceState')) {
            Assert-False ($names -contains $forbidden) "the resume branch must not call $forbidden"
        }
        Assert-True ($names -contains 'Remove-YurunaRunnerRecordGeneration') 'removal is only ever the proven generation'
    }
    It 'the refresh entry point and its module never name a tree kill or taskkill /T' {
        foreach ($relative in @('test/lab/Invoke-HostRefresh.ps1', 'test/modules/Test.HostRefresh.psm1')) {
            $path = Join-Path $script:RepoRoot $relative
            Assert-True (Test-Path -LiteralPath $path) "the guarded refresh source must exist: $relative"
            $ast = Get-YurunaTestFileAst -Path $path
            $bad = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object {
                $name = $_.GetCommandName()
                $text = $_.Extent.Text
                ($name -in @('Stop-YurunaProcessTree', 'Stop-ProcessTree', 'Stop-StaleRunner')) -or ($name -eq 'taskkill' -and $text -match '/T\b')
            } | ForEach-Object { "$relative line $($_.Extent.StartLineNumber)" })
            Assert-NoFinding $bad "forbidden kill paths in $relative"
        }
    }
}

Describe 'Get-YurunaRunnerProtocolCapability' {
    It 'declares reclamation available on natively qualified Linux, macOS and Windows' {
        foreach ($platform in @('Linux', 'macOS', 'Windows')) {
            $capability = Get-YurunaRunnerProtocolCapability -Platform $platform
            Assert-True $capability.Available "$platform is natively qualified"
            Assert-Equal -Expected 1 -Actual $capability.ProtocolVersion
            Assert-Null $capability.UnavailableReasonKey
            foreach ($component in @('ProcessTable', 'Signal', 'DetachedLaunch', 'Handoff')) {
                Assert-Equal -Expected 'tested' -Actual $capability.$component
            }
        }
        $mac = Get-YurunaRunnerProtocolCapability -Platform macos
        Assert-True ([string]::Equals('MacOS', [string]$mac.Platform, [StringComparison]::Ordinal)) 'the platform name must preserve canonical case'
    }
}
