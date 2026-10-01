<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42f71118-c871-4ce5-99f5-744301324e82
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ssh timeout diagnostics pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

<#
.SYNOPSIS
    Real native subprocess and SSH contract coverage for bounded diagnostics.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Force -DisableNameChecking
    $script:Pwsh = (Get-Process -Id $PID).Path
    # Compile outside tight timing assertions; compilation is charged to the
    # first caller's budget just like executable discovery and startup.
    $null = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -TimeoutSeconds 10
}

Describe 'Native SSH subprocess lifecycle' {
    It 'accepts long provisioning budgets without changing successful command completion' {
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -TimeoutSeconds 7200
        $r.ExitCode | Should -Be 0
        (Test-BoundedNativeResultComplete -Result $r) | Should -BeTrue
    }

    It 'captures UTF-8 stdout and stderr independently of the host culture' {
        $writer = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::Write([string][char]0x00e9 + [char]0x4e2d); [Console]::Error.Write([string][char]0x05e9 + [char]0x03bb); exit 7'
        $before = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', $writer) -TimeoutSeconds 10 -StreamEncoding ([Text.Encoding]::UTF8)
            $r.ExitCode | Should -Be 7
            $r.StdOut | Should -Be ([string][char]0x00e9 + [char]0x4e2d)
            $r.StdErr | Should -Be ([string][char]0x05e9 + [char]0x03bb)
            (Test-BoundedNativeResultComplete -Result $r) | Should -BeTrue
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $before }
    }

    It 'retains partial output and reaps each of several timed-out clients' {
        foreach ($attempt in 1..3) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 2 -ArgumentList @('-NoProfile', '-Command', '[Console]::Write("partial-out"); [Console]::Error.Write("partial-err"); Start-Sleep 30')
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            $r.TimedOut | Should -BeTrue
            $r.KillFailed | Should -BeFalse
            $r.StdOut | Should -Be 'partial-out'
            $r.StdErr | Should -Be 'partial-err'
            Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'drains large output on both streams while retaining finite buffers' {
        $writer = '$block = "x" * 8192; for ($i = 0; $i -lt 200; $i++) { [Console]::Write($block); [Console]::Error.Write($block) }; exit 0'
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', $writer) -TimeoutSeconds 15 -MaxCapturedChars 4096
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        $r.DrainTimedOut | Should -BeFalse
        $r.OutputTruncated | Should -BeTrue
        $r.StdOut.Length | Should -Be 4096
        $r.StdErr.Length | Should -Be 4096
    }

    It 'returns partial output when an exited parent leaves inherited pipes open' {
        $launcher = @'
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = (Get-Process -Id $PID).Path
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep 20')) { [void]$psi.ArgumentList.Add($argument) }
$child = [Diagnostics.Process]::Start($psi)
[Console]::WriteLine($child.Id)
[Console]::Error.Write('partial-inherited')
[Environment]::Exit(0)
'@
        $r = $null
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-Command', $launcher) -TimeoutSeconds 3
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 4
            $r.ExitCode | Should -Be 0
            $r.TimedOut | Should -BeFalse
            $r.DrainTimedOut | Should -BeTrue
            $r.StdErr | Should -Be 'partial-inherited'
        } finally {
            if ($r -and $r.StdOut.Trim() -match '^\d+$') {
                $child = Get-Process -Id ([int]$r.StdOut.Trim()) -ErrorAction SilentlyContinue
                if ($child -and $child.Path -eq $script:Pwsh) { $child.Kill() }
            }
        }
    }

    It 'returns at the deadline when tree cleanup never completes and still stops the direct client' {
        $script:PendingKill = [Threading.Tasks.TaskCompletionSource[bool]]::new()
        Mock Invoke-BoundedNativeTreeKill -ModuleName Yuruna.Common { return ,$script:PendingKill.Task }
        $r = $null
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 2 -ArgumentList @('-NoProfile', '-Command', '[Console]::Write("before-kill"); Start-Sleep 30')
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            $r.TimedOut | Should -BeTrue
            $r.KillFailed | Should -BeTrue
            $r.CleanupPending | Should -BeTrue
            $r.StdOut | Should -Be 'before-kill'
            $reap = [Diagnostics.Stopwatch]::StartNew()
            while ((Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue) -and $reap.Elapsed.TotalSeconds -lt 2) { Start-Sleep -Milliseconds 25 }
            Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            $script:PendingKill.TrySetResult($true) | Out-Null
            if ($r) {
                $remaining = Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue
                if ($remaining -and $remaining.Path -eq $script:Pwsh) { $remaining.Kill() }
            }
        }
    }

    It 'returns a complete command result even when asynchronous disposal remains pending' {
        $script:PendingDispose = [Threading.Tasks.TaskCompletionSource[bool]]::new()
        Mock Invoke-BoundedNativeCleanup -ModuleName Yuruna.Common {
            param($Process, $Cancellation, $KillTask)
            $null = [Yuruna.NativeCleanup]::DisposeAsync($Process, $Cancellation, $KillTask)
            return ,$script:PendingDispose.Task
        }
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 2 -ArgumentList @('-NoProfile', '-Command', '[Console]::Write("finished")')
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            $r.ExitCode | Should -Be 0
            $r.StdOut | Should -Be 'finished'
            $r.CleanupPending | Should -BeTrue
            (Test-BoundedNativeResultComplete -Result $r) | Should -BeTrue
        } finally { $script:PendingDispose.TrySetResult($true) | Out-Null }
    }
}

Describe 'Invoke-GuestSsh bounded result contract' {
    BeforeEach {
        $script:SshNativeResult = @{ Started = $true; ExitCode = 0; StdOut = "one`ntwo`n"; StdErr = ''; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh { return $script:SshNativeResult }
        $script:SshArguments = @{ VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'; User = 'fixture-user'; ResolvedAddress = '127.0.0.1'; PrivateKeyPath = 'fixture-key'; Command = 'true'; TimeoutSeconds = 5; AddressWaitSeconds = 0 }
    }

    It 'retains ordinary output and exit status, passing UTF-8 and an output cap' {
        $r = Invoke-GuestSsh @script:SshArguments
        $r.success | Should -BeTrue
        $r.output | Should -Be "one`ntwo"
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ssh' -and $StreamEncoding.WebName -eq 'utf-8' -and $MaxCapturedChars -eq 67108864 }
    }

    It 'rejects an oversized detached command before starting ssh on Windows' -Skip:(-not $IsWindows) {
        $script:SshArguments.Command = 'x' * 20000
        $result = Invoke-GuestSsh @script:SshArguments -DetachToken fixture-token -WarningAction SilentlyContinue
        $result.success | Should -BeFalse
        $result.exitCode | Should -Be 125
        $result.output | Should -BeExactly 'YFE_SSH_COMMAND_TOO_LONG'
        $result.transportLost | Should -BeFalse
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 0 -Exactly
    }

    It 'keeps a maximum-size fetch context below the detached Windows command bound' {
        $encoded = [Convert]::ToBase64String([byte[]]::new(4096))
        $command = "printf '%s' '$encoded' | yfe --prepare 0123456789a 4096 $('a' * 64); yfe 0123456789a bash -c true"
        $wrapped = Get-GuestRunWrapperCommand -Token fixture-token -FromLine 0 -BudgetSeconds 3600 -Command $command
        $wrapped.Length | Should -BeLessThan 30000
    }

    It 'retains partial timeout evidence when requested and exposes invariant timeout flags' {
        $script:SshNativeResult.TimedOut = $true
        $script:SshNativeResult.StdErr = 'partial-error'
        $r = Invoke-GuestSsh @script:SshArguments -PreservePartialOutputOnTimeout -WarningAction SilentlyContinue
        $r.success | Should -BeFalse
        $r.timedOut | Should -BeTrue
        $r.exitCode | Should -Be -1
        $r.output | Should -Match 'one\s+two'
        $r.output | Should -Match 'partial-error'
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $MaxCapturedChars -eq 524288 }
    }

    It 'applies an explicit capture limit over the partial-output default and keeps output longer than that default' {
        $script:SshNativeResult.StdOut = [string]::new([char]120, 600000)
        $r = Invoke-GuestSsh @script:SshArguments -PreservePartialOutputOnTimeout -MaxCapturedChars 16777216
        $r.success | Should -BeTrue
        $r.output.Length | Should -Be 600000
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $MaxCapturedChars -eq 16777216 }
    }

    It 'rejects a capture limit the bounded runner would refuse before starting ssh' {
        { Invoke-GuestSsh @script:SshArguments -MaxCapturedChars 100 } | Should -Throw
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 0 -Exactly
    }

    It 'does not publish partial timeout output unless requested' {
        $script:SshNativeResult.TimedOut = $true
        $r = Invoke-GuestSsh @script:SshArguments -WarningAction SilentlyContinue
        $r.timedOut | Should -BeTrue
        $r.output | Should -Not -Match 'one|two'
    }

    It 'treats an inherited-pipe timeout as incomplete even if the direct client exited successfully' {
        $script:SshNativeResult.DrainTimedOut = $true
        $r = Invoke-GuestSsh @script:SshArguments -PreservePartialOutputOnTimeout -WarningAction SilentlyContinue
        $r.success | Should -BeFalse
        $r.timedOut | Should -BeTrue
        $r.drainTimedOut | Should -BeTrue
        $r.output | Should -Match 'one\s+two'
    }

    It 'does not classify truncated output as complete or replay a detached command' {
        $script:SshNativeResult.OutputTruncated = $true
        $r = Invoke-GuestSsh @script:SshArguments -DetachToken fixture-token -WarningAction SilentlyContinue
        $r.success | Should -BeFalse
        $r.outputTruncated | Should -BeTrue
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly
    }

    It 'preserves a detached payload exit status distinct from the client transport status' {
        $script:SshNativeResult.ExitCode = 255
        $script:SshNativeResult.StdErr = 'YURUNA_RUN_START token=fixture-token; YURUNA_RUN_EXIT rc=7 lines=2'
        $r = Invoke-GuestSsh @script:SshArguments -DetachToken fixture-token
        $r.success | Should -BeFalse
        $r.exitCode | Should -Be 7
        $r.linesConsumed | Should -Be 2
        $r.output | Should -Be "one`ntwo"
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly
    }

    It 'reattaches a detached payload from complete lines without replaying partial output' {
        $script:AttachCalls = 0
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '127.0.0.1' }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            $script:AttachCalls++
            if ($script:AttachCalls -eq 1) {
                return @{ Started = $true; ExitCode = 255; StdOut = "one`npartial"; StdErr = 'YURUNA_RUN_START token=fixture-token' }
            }
            return @{ Started = $true; ExitCode = 0; StdOut = "two`n"; StdErr = 'YURUNA_RUN_EXIT rc=0 lines=2' }
        }
        $r = Invoke-GuestSsh @script:SshArguments -DetachToken fixture-token -WarningAction SilentlyContinue
        $r.success | Should -BeTrue
        $r.output | Should -Be "one`ntwo"
        $r.linesConsumed | Should -Be 2
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $ArgumentList[-1] -match '--from-line 1 ' }
    }

    It 'retains banked lines when a later detached attachment times out' -TestCases @(
        @{ Preserve = $false }, @{ Preserve = $true }
    ) {
        param($Preserve)
        $script:AttachCalls = 0
        Mock Get-GuestAddress -ModuleName Test.Ssh { '127.0.0.1' }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            $script:AttachCalls++
            if ($script:AttachCalls -eq 1) {
                return @{ Started=$true; ExitCode=255; StdOut="banked-one`nbanked-two`nunfinished"; StdErr='YURUNA_RUN_START token=fixture-token' }
            }
            return @{ Started=$true; ExitCode=-1; StdOut='later-partial'; StdErr=''; TimedOut=$true }
        }
        $r = Invoke-GuestSsh @script:SshArguments -DetachToken fixture-token -PreservePartialOutputOnTimeout:$Preserve -WarningAction SilentlyContinue
        $r.success | Should -BeFalse
        $r.timedOut | Should -BeTrue
        $r.detachToken | Should -Be 'fixture-token'
        $r.linesConsumed | Should -Be 2
        $r.output | Should -Match "^banked-one`nbanked-two`n"
        $r.output | Should -Not -Match 'unfinished'
        ($r.output -match 'later-partial') | Should -Be $Preserve
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 2 -Exactly
    }

    It 'reports launch failure independently from a timeout and retains the external detail' {
        $script:SshNativeResult.Started = $false
        $script:SshNativeResult.StartError = 'fixture-start-error'
        $r = Invoke-GuestSsh @script:SshArguments -WarningAction SilentlyContinue
        $r.success | Should -BeFalse
        $r.timedOut | Should -BeFalse
        $r.output | Should -Match 'fixture-start-error'
    }
}
