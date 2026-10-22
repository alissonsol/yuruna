<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42b8c3e5-1f7a-4d96-a2c8-6e0b9d4f1a37
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test temp housekeeping runtime ipc sweep leak pester
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
    What the hosts leave in their temp folders, and what removes it: the .NET
    runtime entries of killed processes, the harness's own stale temp names,
    the bounded transcript folder, the shell installers' temp registry, the
    guest's per-step recorder folders, the per-suite temp containment, and the
    finally blocks that keep seed and capture files from outliving a failure.
.DESCRIPTION
    The sweeps run against real FIFOs, Unix sockets, files and folders in a
    private root, with a fake /proc where liveness is the question, so they
    run on any POSIX host and never touch the host's own temp entries. Windows
    skips the POSIX cases and says so.
#>
BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.LogLevel.psm1') -Force -Global -DisableNameChecking
    $script:Posix = -not $IsWindows
    $script:PosixSkip = 'FIFOs, Unix sockets and /proc are POSIX'

    function New-ShortRoot {
        <#
        .SYNOPSIS
            A private root directly under /tmp: a Unix socket path is capped
            near 104 bytes on macOS, and the suite's own temp folder is deeper.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a private folder it removes itself.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $root = '/tmp/yrn-th-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $null = New-Item -ItemType Directory -Force -Path $root
        return $root
    }
    function New-Fifo {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a fixture inside a throwaway test folder.')]
        [CmdletBinding()]
        param([string]$Path)
        & mkfifo $Path
        if (-not (Test-Path -LiteralPath $Path)) { throw "mkfifo did not create $Path" }
    }
    # .NET unlinks a socket file when the socket that bound it is disposed, so
    # the fixtures stay open until teardown -- as a killed process's socket
    # file outlives it with nothing left to unlink it.
    $script:OpenSockets = [System.Collections.Generic.List[System.Net.Sockets.Socket]]::new()
    function New-UnixSocketFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a fixture inside a throwaway test folder.')]
        [CmdletBinding()]
        param([string]$Path)
        $socket = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Unspecified)
        $socket.Bind([System.Net.Sockets.UnixDomainSocketEndPoint]::new($Path))
        $script:OpenSockets.Add($socket)
    }
    function Close-UnixSocketFile {
        foreach ($socket in $script:OpenSockets) { try { $socket.Dispose() } catch { $null = $_ } }
        $script:OpenSockets.Clear()
    }
    function Set-FakeProcess {
        <#
        .SYNOPSIS
            Write a /proc/<pid>/stat line whose field 22 is the start time.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes into a private fake procfs.')]
        [CmdletBinding()]
        param([string]$ProcRoot, [int]$ProcessId, [string]$StartTime, [string]$Command = 'pwsh', [int]$ThreadGroupId)
        $dir = Join-Path $ProcRoot "$ProcessId"
        $null = New-Item -ItemType Directory -Force -Path $dir
        # Field 3 is the state, fields 4..21 are filler, field 22 is the start time.
        $filler = (4..21 | ForEach-Object { '0' }) -join ' '
        [IO.File]::WriteAllText((Join-Path $dir 'stat'), "$ProcessId ($Command) S $filler $StartTime 0 0`n")
        # A thread of another process answers under its own id with that process's Tgid.
        $tgid = if ($ThreadGroupId) { $ThreadGroupId } else { $ProcessId }
        [IO.File]::WriteAllText((Join-Path $dir 'status'), "Name:`t$Command`nState:`tS (sleeping)`nTgid:`t$tgid`nPid:`t$ProcessId`n")
    }
}

Describe 'Get-YurunaRuntimeIpcEntry' {
    It 'reads <Name> as <Kind> owned by <ProcessId>' -TestCases @(
        @{ Name = 'clr-debug-pipe-2480717-47474996-in'; Kind = 'clr-debug-pipe'; ProcessId = 2480717; Key = '47474996' }
        @{ Name = 'clr-debug-pipe-2480717-47474996-out'; Kind = 'clr-debug-pipe'; ProcessId = 2480717; Key = '47474996' }
        @{ Name = 'dotnet-diagnostic-2480717-47474996-socket'; Kind = 'dotnet-diagnostic'; ProcessId = 2480717; Key = '47474996' }
        @{ Name = 'CoreFxPipe_PSHost.DD5CA48B.2480717.None.pwsh'; Kind = 'pshost-pipe'; ProcessId = 2480717; Key = $null }
    ) {
        param($Name, $Kind, $ProcessId, $Key)
        $entry = Get-YurunaRuntimeIpcEntry -Name $Name
        Assert-StringEqual $Kind $entry.Kind
        Assert-Equal $ProcessId $entry.ProcessId
        if ($Key) { Assert-StringEqual $Key $entry.Key } else { Assert-Null $entry.Key }
        if ($Kind -eq 'pshost-pipe') { Assert-StringEqual 'pwsh' $entry.ProcessName } else { Assert-Null $entry.ProcessName }
    }

    It 'ignores <Name>' -TestCases @(
        @{ Name = 'CoreFxPipe_PSES_bt5fv0ou.so5' }
        @{ Name = 'clr-debug-pipe-abc-123-in' }
        @{ Name = 'dotnet-diagnostic-0-1-socket' }
        @{ Name = 'dotnet-diagnostic-12-34-socket.bak' }
        @{ Name = 'yuruna-status-bounce-12.log' }
    ) {
        param($Name)
        Assert-Null (Get-YurunaRuntimeIpcEntry -Name $Name) "$Name is not a runtime entry"
    }
}

Describe 'Get-YurunaRuntimeIpcOwnerState' {
    BeforeAll { if ($script:Posix) { $script:Proc = Join-Path $TestDrive 'proc'; $null = New-Item -ItemType Directory -Force -Path $script:Proc } }

    It 'reads a pid with no /proc entry as dead' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900001 -Key '5' -ProcRoot $script:Proc -Platform linux)
    }

    It 'reads a live pid with the same start time as alive, and a different one as a recycled pid' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900002 -StartTime '47474996'
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900002 -Key '47474996' -ProcRoot $script:Proc -Platform linux)
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900002 -Key '12345' -ProcRoot $script:Proc -Platform linux)
    }

    It 'finds the start time after a command name that holds spaces and parentheses' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900003 -StartTime '777' -Command 'odd (name) x'
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900003 -Key '777' -ProcRoot $script:Proc -Platform linux)
    }

    It 'never guesses: an unkeyed live pid and an unreadable /proc both count as alive' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900004 -StartTime '1'
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900004 -Key $null -ProcRoot $script:Proc -Platform linux)
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900005 -Key '1' -ProcRoot (Join-Path $TestDrive 'no-proc') -Platform linux)
    }

    It 'reads a pid that now names a thread of another process as dead' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        # /proc/<tid>/stat exists for every thread, so the stat file alone
        # would keep a dead owner's entries forever.
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900006 -StartTime '5' -Command 'ThreadPoolForeg' -ThreadGroupId 900000
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900006 -Key '5' -ProcRoot $script:Proc -Platform linux)
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900006 -ProcessName 'pwsh' -ProcRoot $script:Proc -Platform linux)
    }

    It 'reads a host pipe owner by its program: the same program is alive, another one on the pid is dead' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900007 -StartTime '7' -Command 'pwsh'
        Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900008 -StartTime '8' -Command 'code'
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900007 -ProcessName 'pwsh' -ProcRoot $script:Proc -Platform linux)
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId 900008 -ProcessName 'pwsh' -ProcRoot $script:Proc -Platform linux)
    }

    It 'asks the process table elsewhere: this process is alive, an exited one is dead' {
        $child = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru
        $child.WaitForExit()
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId $PID -Platform macos)
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId $child.Id -Platform macos)
    }

    It 'asks the process table elsewhere for the program name too' {
        $name = (Get-Process -Id $PID).ProcessName
        Assert-StringEqual 'alive' (Get-YurunaRuntimeIpcOwnerState -ProcessId $PID -ProcessName $name -Platform macos)
        Assert-StringEqual 'dead' (Get-YurunaRuntimeIpcOwnerState -ProcessId $PID -ProcessName 'another-program' -Platform macos)
    }
}

Describe 'Test-YurunaProcessNameMatch' {
    It 'reads <Observed> against <Expected> as <Match>' -TestCases @(
        @{ Observed = 'pwsh'; Expected = 'pwsh'; Match = $true }
        @{ Observed = 'code'; Expected = 'pwsh'; Match = $false }
        @{ Observed = 'pws'; Expected = 'pwsh'; Match = $false }
        @{ Observed = 'averyveryverylo'; Expected = 'averyveryverylongname'; Match = $true }
        @{ Observed = 'averyveryverylongname'; Expected = 'averyveryverylo'; Match = $true }
        @{ Observed = 'averyveryverylX'; Expected = 'averyveryverylongname'; Match = $false }
        @{ Observed = ''; Expected = 'pwsh'; Match = $true }
    ) {
        param($Observed, $Expected, $Match)
        Assert-Equal $Match (Test-YurunaProcessNameMatch -Observed $Observed -Expected $Expected)
    }
}

Describe 'Remove-YurunaOrphanedRuntimeIpc' {
    BeforeEach {
        if ($script:Posix) {
            $script:Root = New-ShortRoot
            $script:Proc = Join-Path $script:Root 'proc'
            $null = New-Item -ItemType Directory -Force -Path $script:Proc
            # Dead: no /proc entry.
            New-Fifo (Join-Path $script:Root 'clr-debug-pipe-900101-11-in')
            New-Fifo (Join-Path $script:Root 'clr-debug-pipe-900101-11-out')
            New-UnixSocketFile (Join-Path $script:Root 'dotnet-diagnostic-900101-11-socket')
            New-UnixSocketFile (Join-Path $script:Root 'CoreFxPipe_PSHost.DD5CA48B.900101.None.pwsh')
            # Alive, same start time.
            Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900102 -StartTime '22'
            New-Fifo (Join-Path $script:Root 'clr-debug-pipe-900102-22-in')
            New-UnixSocketFile (Join-Path $script:Root 'dotnet-diagnostic-900102-22-socket')
            New-UnixSocketFile (Join-Path $script:Root 'CoreFxPipe_PSHost.DD5CA48B.900102.None.pwsh')
            # A recycled pid: alive, but started at another time.
            Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900103 -StartTime '99'
            New-UnixSocketFile (Join-Path $script:Root 'dotnet-diagnostic-900103-33-socket')
            # Host pipes of recycled pids: one is now a thread of another
            # process, the other runs another program.
            Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900105 -StartTime '5' -Command 'DelayedTaskSche' -ThreadGroupId 900100
            New-UnixSocketFile (Join-Path $script:Root 'CoreFxPipe_PSHost.DD5CA48B.900105.None.pwsh')
            Set-FakeProcess -ProcRoot $script:Proc -ProcessId 900106 -StartTime '6' -Command 'code'
            New-UnixSocketFile (Join-Path $script:Root 'CoreFxPipe_PSHost.DD5CA48B.900106.None.pwsh')
            # Not the runtime's, whatever the name says, and unrelated names.
            [IO.File]::WriteAllText((Join-Path $script:Root 'clr-debug-pipe-900101-11-in.txt'), 'x')
            [IO.File]::WriteAllText((Join-Path $script:Root 'dotnet-diagnostic-900104-44-socket'), 'a regular file')
            New-UnixSocketFile (Join-Path $script:Root 'CoreFxPipe_PSES_abcdefgh.ijk')
        }
    }
    AfterEach {
        if ($script:Posix -and $script:Root) {
            Close-UnixSocketFile
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes the entries of dead and recycled owners and keeps the rest' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        $r = Remove-YurunaOrphanedRuntimeIpc -TempRoot @($script:Root) -ProcRoot $script:Proc -Platform linux -Confirm:$false
        Assert-True $r.Applicable
        Assert-Equal 7 $r.Removed -Because 'four of the dead owner and three of recycled pids'
        Assert-Equal 3 $r.KeptAlive
        Assert-Equal 1 $r.SkippedForeign -Because 'a regular file is not the runtime''s'
        Assert-Equal 0 $r.Failed
        Assert-Equal 2 $r.ByKind['clr-debug-pipe']
        Assert-Equal 2 $r.ByKind['dotnet-diagnostic']
        Assert-Equal 3 $r.ByKind['pshost-pipe']
        $left = @(Get-ChildItem -LiteralPath $script:Root -Force -File | ForEach-Object Name | Sort-Object)
        $expected = @('CoreFxPipe_PSES_abcdefgh.ijk', 'CoreFxPipe_PSHost.DD5CA48B.900102.None.pwsh', 'clr-debug-pipe-900101-11-in.txt',
            'clr-debug-pipe-900102-22-in', 'dotnet-diagnostic-900102-22-socket', 'dotnet-diagnostic-900104-44-socket') | Sort-Object
        Assert-StringEqual ($expected -join '|') ($left -join '|')
    }

    It 'removes nothing under -WhatIf' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        $before = @(Get-ChildItem -LiteralPath $script:Root -Force -File).Count
        $r = Remove-YurunaOrphanedRuntimeIpc -TempRoot @($script:Root) -ProcRoot $script:Proc -Platform linux -WhatIf
        Assert-Equal 0 $r.Removed
        Assert-Equal $before @(Get-ChildItem -LiteralPath $script:Root -Force -File).Count
    }

    It 'stops at its cap and leaves the rest for the next call' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because $script:PosixSkip; return }
        $first = Remove-YurunaOrphanedRuntimeIpc -TempRoot @($script:Root) -ProcRoot $script:Proc -Platform linux -MaxEntries 2 -Confirm:$false
        Assert-Equal 2 $first.Examined
        $rest = Remove-YurunaOrphanedRuntimeIpc -TempRoot @($script:Root) -ProcRoot $script:Proc -Platform linux -Confirm:$false
        Assert-Equal 7 ($first.Removed + $rest.Removed) -Because 'two calls remove what one would'
    }

    It 'has nothing to do on Windows, where the runtime uses named pipes' {
        $r = Remove-YurunaOrphanedRuntimeIpc -TempRoot @($TestDrive) -Platform windows -Confirm:$false
        Assert-False $r.Applicable
        Assert-Equal 0 $r.Examined
    }
}

Describe 'Remove-YurunaStaleTempEntry' {
    BeforeEach {
        $script:Stale = Join-Path $TestDrive ('stale-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $script:Stale
        $g32 = 'abcdef0123456789abcdef0123456789'
        $script:Harness = @(
            "seed_amisad-core_0042", "seed_amisad-core_k3vq0d5m.x2c", "yuruna-browser-profile-$g32", "yuruna-gotest-$g32", "yrn-suite-0123456789ab",
            "yrn-parser-follow-123456789", "yuruna-localization-$($g32)$($g32).lock", "yuruna-status-bounce-4242.log.err",
            "yuruna-squid-ca.pem", "yuruna-dhcp-test-guest-01.etl", "yrn-go-0123456789ab",
            "yuruna-fae-recorder.ATLa2gnP", "yuruna-fae-profile.Q1w2E3", "yrn-run-0123456789ab")
        foreach ($name in $script:Harness) {
            $path = Join-Path $script:Stale $name
            if ($name -match '\.(lock|err|pem|etl)$|^yuruna-fae-profile\.') { [IO.File]::WriteAllText($path, 'x') }
            else { $null = New-Item -ItemType Directory -Force -Path (Join-Path $path 'inner'); [IO.File]::WriteAllText((Join-Path $path 'inner/f'), 'x') }
        }
        # Names the sweep must never take, however old they are.
        $script:Kept = @('yuruna-a11y-generated', 'yuruna-a11y-chrome.log', 'yuruna-lint-regressions.log', 'yuruna-investigation-x',
            'yuruna-transcripts', ('yuruna-host-performance-20261015T101010Z-' + $g32 + '.zip'), 'seed_notes.txt', 'tmpQ1W2E3.tmp')
        foreach ($name in $script:Kept) {
            $path = Join-Path $script:Stale $name
            if ($name -match '\.\w{3}$') { [IO.File]::WriteAllText($path, 'not a transcript') } else { $null = New-Item -ItemType Directory -Force -Path $path }
        }
        $transcript = "**********************`nPowerShell transcript start`nStart time: 20261015101010`n**********************`n"
        [IO.File]::WriteAllText((Join-Path $script:Stale 'tmpA1B2C3.tmp'), $transcript)
        $script:Later = [datetime]::UtcNow.AddHours(13)
    }

    It 'removes every harness name and unnamed transcript past its age, and nothing else' {
        # A run master whose run still holds the lock is kept, however old it is;
        # once the lock is released the master is a leftover like any other.
        $master = Join-Path $script:Stale 'yrn-run-fedcba987654'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $master 'yrn-suite-0123456789ab')
        $lock = [IO.File]::Open((Join-Path $master 'run.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $r = Remove-YurunaStaleTempEntry -TempRoot @($script:Stale) -Now $script:Later -Confirm:$false
            Assert-Equal ($script:Harness.Count + 1) $r.Removed -Because 'each harness entry and the old transcript'
            Assert-Equal 0 $r.Failed
            Assert-Equal 1 $r.ByKind['unnamed-transcript']
            Assert-Equal 1 $r.KeptLive -Because 'the master of a live run is left alone'
            $left = @(Get-ChildItem -LiteralPath $script:Stale -Force | ForEach-Object Name | Sort-Object)
            Assert-StringEqual ((@($script:Kept) + 'yrn-run-fedcba987654' | Sort-Object) -join '|') ($left -join '|')
        } finally { $lock.Dispose() }
        $after = Remove-YurunaStaleTempEntry -TempRoot @($script:Stale) -Now $script:Later -Confirm:$false
        Assert-Equal 1 $after.ByKind['run-temp'] -Because 'the master of a run that has exited is removed'
        Assert-False (Test-Path -LiteralPath $master) 'nothing of it is left'
    }

    It 'keeps entries younger than the age' {
        $r = Remove-YurunaStaleTempEntry -TempRoot @($script:Stale) -Confirm:$false
        Assert-Equal 0 $r.Removed
        Assert-Equal ($script:Harness.Count + 1) $r.KeptYoung
    }

    It 'removes nothing under -WhatIf' {
        $r = Remove-YurunaStaleTempEntry -TempRoot @($script:Stale) -Now $script:Later -WhatIf
        Assert-Equal 0 $r.Removed
        Assert-Equal ($script:Harness.Count + $script:Kept.Count + 1) @(Get-ChildItem -LiteralPath $script:Stale -Force).Count
    }

    It 'removes a link by its name and never reaches into its target' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because 'a symbolic link needs privilege on Windows'; return }
        $target = Join-Path $TestDrive ('link-target-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $target
        [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'keep')
        $link = Join-Path $script:Stale 'yuruna-gpg-0123456789abcdef0123456789abcdef'
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $target
        $null = Remove-YurunaStaleTempEntry -TempRoot @($script:Stale) -Now $script:Later -Confirm:$false
        Assert-False (Test-Path -LiteralPath $link) 'the link is gone'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'keep.txt')) 'what it pointed at is untouched'
    }
}

Describe 'New-YurunaSeedDirectory' {
    It 'creates a distinct, empty seed folder in the temp folder on every call' {
        $first = New-YurunaSeedDirectory -VMName 'amisad-core'
        $second = New-YurunaSeedDirectory -VMName 'amisad-core'
        try {
            Assert-True ($first -ne $second) 'each build gets its own folder'
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            foreach ($path in $first, $second) {
                Assert-True ([IO.Directory]::Exists($path)) "$path exists"
                Assert-Equal 0 @(Get-ChildItem -LiteralPath $path -Force).Count -Because "$path starts empty"
                Assert-Match '^seed_amisad-core_' (Split-Path -Leaf $path) 'the name carries the VM'
                Assert-Equal $tempRoot ([IO.Path]::GetFullPath((Split-Path -Parent $path)).TrimEnd('\', '/')) -Because 'it sits in the temp folder'
            }
            # The New-VM scripts that call it run on Windows, where the sweep has to know the name.
            if ($IsWindows) { Assert-Match (Get-YurunaStaleTempPattern)['seed'].Pattern (Split-Path -Leaf $first) 'the temp sweep recognizes it' }
        } finally {
            Remove-Item -LiteralPath $first, $second -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'The harness temp-name table' {
    It 'names, for every row, a source that still creates it' {
        $table = Get-YurunaStaleTempPattern
        Assert-True ($table.Count -ge 20) 'the table lists the harness names'
        foreach ($row in $table.Keys) {
            $entry = $table[$row]
            $source = Join-Path $script:RepoRoot $entry.Source
            Assert-True (Test-Path -LiteralPath $source) "$row names $($entry.Source), which exists"
            Assert-True ([IO.File]::ReadAllText($source).Contains($entry.Literal)) "$($entry.Source) still contains '$($entry.Literal)' for $row"
            Assert-True ($entry.Pattern.StartsWith('^') -and $entry.Pattern.EndsWith('$')) "$row matches whole names only"
        }
    }

    It 'never matches a name kept on purpose' {
        $table = Get-YurunaStaleTempPattern
        foreach ($name in @('yuruna-transcripts', 'yuruna-a11y-generated', 'yuruna-a11y-chrome.log', 'yuruna-winrt-ocr-abc.ps1',
                'yuruna-vision-ocr-abc.bin', 'yuruna-host-performance-20261015T101010Z-0123456789abcdef0123456789abcdef.zip',
                'yuruna-last-fetch-and-execute.log', 'yuruna-ytest')) {
            $hit = @($table.Keys | Where-Object { $name -match $table[$_].Pattern })
            Assert-Equal 0 $hit.Count -Because "$name matched $($hit -join ', ')"
        }
    }
}

Describe 'Get-YurunaTempRoot' {
    It 'lists the process temp folder, and /tmp on Unix, each once' {
        $roots = @(Get-YurunaTempRoot)
        $temp = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar)
        Assert-True ($roots -contains $temp) "the process temp folder is a root ($($roots -join ', '))"
        if ($script:Posix) { Assert-True ($roots -contains '/tmp' -or $temp -eq '/tmp') '/tmp is a root' }
        Assert-Equal @($roots | Select-Object -Unique).Count $roots.Count
    }
}

Describe 'Default transcripts are kept in a bounded folder' {
    It 'keeps the newest files and names the next one there' {
        $root = Join-Path $TestDrive 'transcripts'
        $null = New-Item -ItemType Directory -Force -Path $root
        foreach ($i in 1..5) {
            $f = Join-Path $root ("transcript-2026101{0}T000000000Z-aaaaaaa{0}.log" -f $i)
            [IO.File]::WriteAllText($f, "t$i")
            [IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddMinutes(-10 + $i))
        }
        $next = New-YurunaDefaultTranscriptPath -Retention 3 -Root $root
        Assert-Match '^transcript-\d{8}T\d{9}Z-[0-9a-f]{8}\.log$' (Split-Path -Leaf $next)
        Assert-StringEqual $root (Split-Path -Parent $next)
        $left = @(Get-ChildItem -LiteralPath $root -File | ForEach-Object Name | Sort-Object)
        Assert-Equal 2 $left.Count -Because 'the new one makes three'
        Assert-True ($left -contains 'transcript-20261015T000000000Z-aaaaaaa5.log' -and $left -contains 'transcript-20261014T000000000Z-aaaaaaa4.log') 'the newest are kept'
    }

    It 'falls back to a named file beside an unusable folder' {
        $blocker = Join-Path $TestDrive 'not-a-folder'
        [IO.File]::WriteAllText($blocker, 'x')
        $next = New-YurunaDefaultTranscriptPath -Root $blocker
        Assert-Match '^yuruna-transcript-' (Split-Path -Leaf $next)
    }

    It 'still honors a caller-named path and puts an unnamed one in the folder' {
        $named = Join-Path $TestDrive 'named-transcript.log'
        $saved = $env:YURUNA_TRANSCRIPT_PATH
        try {
            $env:YURUNA_TRANSCRIPT_PATH = $named
            Assert-StringEqual $named (Resolve-YurunaTranscriptPath)
            Assert-StringEqual '' "$env:YURUNA_TRANSCRIPT_PATH" 'the variable is consumed'
            $default = Resolve-YurunaTranscriptPath
            Assert-StringEqual 'yuruna-transcripts' (Split-Path -Leaf (Split-Path -Parent $default))
            Assert-True ((Split-Path -Leaf $default) -notmatch '^tmp') 'no anonymous tmp file'
        } finally { $env:YURUNA_TRANSCRIPT_PATH = $saved }
    }
}

Describe 'The shell installers register every temp path for their exit trap' {
    BeforeAll {
        $script:Installers = @('install/ubuntu.kvm.sh', 'install/macos.utm.sh')
        $script:RegistryText = @{}
        foreach ($installer in $script:Installers) {
            $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $installer))
            $script:RegistryText[$installer] = Get-YurunaTestShellFunction -Text $text -Name @('yuruna_track_tmp', 'yuruna_cleanup_tmp_paths')
        }
    }

    It 'carries the same registry in both installers' {
        Assert-StringEqual $script:RegistryText['install/ubuntu.kvm.sh'] $script:RegistryText['install/macos.utm.sh']
    }

    It 'removes what the run and a failing subshell registered, under set -u with nothing registered too' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because 'the installers run under bash'; return }
        $body = @"
set -euo pipefail
$($script:RegistryText['install/ubuntu.kvm.sh'])
YURUNA_TMP_PATHS=()
yuruna_cleanup_tmp_paths
a="`$(mktemp -d)"; yuruna_track_tmp "`$a"; touch "`$a/f"
b="`$(mktemp)"; yuruna_track_tmp "`$b"
echo "A=`$a"; echo "B=`$b"
( YURUNA_TMP_PATHS=(); trap yuruna_cleanup_tmp_paths EXIT; c="`$(mktemp -d)"; yuruna_track_tmp "`$c"; echo "C=`$c"; exit 3 ) || true
trap yuruna_cleanup_tmp_paths EXIT
exit 5
"@
        $r = Invoke-YurunaTestShell -Body $body
        Assert-Equal 5 $r.ExitCode -Because "the run ends with its own code ($($r.Output))"
        $paths = @([regex]::Matches([string]$r.Output, '(?m)^[ABC]=(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
        Assert-Equal 3 $paths.Count -Because "three paths were registered ($($r.Output))"
        foreach ($path in $paths) { Assert-False (Test-Path -LiteralPath $path) "$path is gone" }
    }

    It 'registers every mktemp, or names why one needs no registration' {
        $exempt = @{
            '_yuruna_logfifo='     = 'the log FIFO is unlinked as soon as it is opened'
            'YURUNA_STATUS_BACKUP=' = 'removed by name in yuruna_install_cleanup and restore_test_status'
            'probe="$(mktemp -d)"' = 'removed on the next line, with nothing between that can exit'
            'TRAVERSE_PROBE='      = 'under $HOME, not the temp folder, and removed after the probe'
            'out="$(mktemp '       = 'yuruna_utmctl_status runs in a command substitution; it removes the file on both of its paths'
        }
        foreach ($installer in $script:Installers) {
            $lines = [IO.File]::ReadAllLines((Join-Path $script:RepoRoot $installer))
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '\$\(mktemp' -or $lines[$i] -match '^\s*#') { continue }
                $reason = @($exempt.Keys | Where-Object { $lines[$i].Contains($_) })
                if ($reason.Count) { continue }
                $window = ($lines[$i..([Math]::Min($i + 4, $lines.Count - 1))] -join "`n")
                Assert-Match 'yuruna_track_tmp' $window "${installer}:$($i + 1) registers its temp path: $($lines[$i].Trim())"
            }
        }
    }

    It 'cleans incomplete installer captures and retains completed recovery capsules outside temp' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because 'the installers run under bash'; return }
        foreach ($installer in $script:Installers) {
            foreach ($failCapture in @(0, 1)) {
                $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $null = New-Item -ItemType Directory -Path $root, "$root/tmp", "$root/checkout" -Force
                $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $installer))
                $capture = Get-YurunaTestShellFunction -Text $text -Name capture_installer_state
                $capture = $capture.Replace('$HOME/.yuruna/installer-state', "$root/recovery")
                $body = @"
set -euo pipefail
$($script:RegistryText[$installer])
$capture
YURUNA_TMP_PATHS=()
YURUNA_INSTALLER_STATE_DIR=""
YURUNA_INSTALLER_STATE_RETAINED=0
YURUNA_DIR='$root/checkout'
export TMPDIR='$root/tmp'
pwsh() { :; }
log() { :; }
die() { exit 5; }
invoke_yuruna_installer_state() { echo '{}' > "`$YURUNA_INSTALLER_STATE_DIR/state.json"; return $failCapture; }
trap 'p="`$YURUNA_INSTALLER_STATE_DIR"; yuruna_cleanup_tmp_paths; if [[ -d "`$p" ]]; then echo "RETAINED=`$p"; else echo REMOVED; fi' EXIT
capture_installer_state
"@
                $result = Invoke-YurunaTestShell -Body $body
                if ($failCapture) {
                    Assert-Equal 5 $result.ExitCode -Because 'capture failure stops the installer'
                    Assert-Match '(?m)^REMOVED$' $result.Output 'the incomplete capsule is removed by the exit trap'
                } else {
                    Assert-Equal 0 $result.ExitCode -Because 'completed capture succeeds'
                    Assert-Match ('(?m)^RETAINED=' + [regex]::Escape("$root/recovery/")) $result.Output 'restart state lives in private recovery storage, not OS-prunable temp'
                }
            }
        }
    }
}

Describe 'A guest step removes the recorder folder and profile of the step before it' {
    BeforeAll {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'automation/fetch-and-execute.sh'))
        $script:PruneFunction = Get-YurunaTestShellFunction -Text $text -Name @('fae_prune_prior_invocation')
    }

    It 'removes the paths the previous log names, and only paths of that exact shape' {
        if (-not $script:Posix) { Set-ItResult -Skipped -Because 'the guest script runs under bash'; return }
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
        $recorder = "/tmp/yuruna-fae-recorder.T$suffix"
        $profileTrace = "/tmp/yuruna-fae-profile.T$suffix"
        $decoy = "/tmp/yuruna-fae-recorder-decoy-$suffix"
        $log = Join-Path $TestDrive 'last-fae.log'
        try {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $recorder 'samples')
            [IO.File]::WriteAllText($profileTrace, 'trace')
            $null = New-Item -ItemType Directory -Force -Path $decoy
            [IO.File]::WriteAllText($log, ((@(
                    '# Yuruna fetch-and-execute log'
                    "# recorder: $recorder"
                    "# profile:   $profileTrace"
                    "# recorder: $decoy"
                    '# recorder: /tmp/yuruna-fae-recorder.x/../../etc'
                    '# recorder: unavailable (timeout command absent)'
                ) -join "`n") + "`n"))
            $r = Invoke-YurunaTestShell -Body "set -euo pipefail`n$($script:PruneFunction)`nfae_prune_prior_invocation '$log'`nfae_prune_prior_invocation '$TestDrive/no-such.log'`necho done"
            Assert-Equal 0 $r.ExitCode -Because $r.Output
            Assert-False (Test-Path -LiteralPath $recorder) 'the previous recorder folder is gone'
            Assert-False (Test-Path -LiteralPath $profileTrace) 'the previous profile is gone'
            Assert-True (Test-Path -LiteralPath $decoy) 'a path of another shape is left alone'
        } finally {
            Remove-Item -LiteralPath $recorder, $profileTrace, $decoy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'A suite run directly gets a temp folder of its own' {
    It 'points the suite and its children at it, disables runtime diagnostics, and removes it afterwards' {
        $fixture = Join-Path $TestDrive 'Fixture.Tests.ps1'
        $record = Join-Path $TestDrive 'record.json'
        $xml = Join-Path $TestDrive 'fixture.xml'
        Set-Content -LiteralPath $fixture -Encoding utf8NoBOM -Value @"
Describe 'leaks on purpose' {
    It 'writes into the temp folder itself and through a child' {
        `$temp = [IO.Path]::GetTempPath()
        `$own = Join-Path `$temp 'left-by-the-suite.txt'
        Set-Content -LiteralPath `$own -Value 'x'
        `$child = & ([Environment]::ProcessPath) -NoProfile -Command '`$p = Join-Path ([IO.Path]::GetTempPath()) "left-by-a-child.txt"; Set-Content -LiteralPath `$p -Value y; `$p'
        [ordered]@{ Temp = `$temp; Own = `$own; Child = ([string]`$child).Trim(); Diagnostics = `$env:DOTNET_EnableDiagnostics; Marker = `$env:YURUNA_TEST_TEMP_ROOT } |
            ConvertTo-Json | Set-Content -LiteralPath '$record'
        1 | Should -Be 1
    }
}
"@
        $saved = $env:YURUNA_TEST_TEMP_ROOT
        try {
            # Run as an operator would: outside any suite runner.
            $env:YURUNA_TEST_TEMP_ROOT = ''
            $null = & ([Environment]::ProcessPath) -NoProfile -File (Join-Path $script:RepoRoot 'tools/_InvokeOneSuite.ps1') -Suite $fixture -Xml $xml 2>&1
            Assert-Equal 0 $LASTEXITCODE -Because 'the shim ran the fixture'
        } finally { $env:YURUNA_TEST_TEMP_ROOT = $saved }
        $seen = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
        $folder = $seen.Temp.TrimEnd([IO.Path]::DirectorySeparatorChar)
        Assert-Match '^yrn-suite-[0-9a-f]{12}$' (Split-Path -Leaf $folder) 'the suite saw a folder of its own'
        Assert-StringEqual $folder $seen.Marker.TrimEnd([IO.Path]::DirectorySeparatorChar) 'and was told which one'
        Assert-True ($seen.Child.StartsWith($folder)) 'a child the suite started inherited it'
        Assert-StringEqual '0' $seen.Diagnostics 'runtime diagnostics are off for the suite and its children'
        Assert-False (Test-Path -LiteralPath $seen.Own) 'what the suite left is gone'
        Assert-False (Test-Path -LiteralPath $seen.Child) 'what its child left is gone'
        Assert-False (Test-Path -LiteralPath $folder) 'the folder itself is gone'
    }
}

Describe 'Temp files with secrets or large captures are removed on every path' {
    It 'wraps the seed folder of <Script> in a try whose finally removes it' -TestCases @(
        @{ Script = 'host/windows.hyper-v/guest.amazon.linux.2023/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/guest.caching-proxy-service/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/guest.download-agent-service/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/guest.pool-control-service/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/guest.stash-service/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/guest.windows.11/New-VM.ps1' }
        @{ Script = 'host/windows.hyper-v/modules/New-UbuntuServerVM.ps1' }
    ) {
        param($Script)
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot $Script)
        $assignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$SeedDir' }, $true)
        Assert-NotNull $assignment "$Script names its seed folder"
        $try = $assignment.Parent
        while ($try -and $try -isnot [System.Management.Automation.Language.TryStatementAst]) { $try = $try.Parent }
        Assert-NotNull $try "$Script creates the seed folder inside a try"
        Assert-NotNull $try.Finally "$Script has a finally for it"
        if ($Script -eq 'host/windows.hyper-v/guest.caching-proxy-service/New-VM.ps1') {
            Assert-Match '\$SeedDir\s*=\s*\$seedWorkspace\.Source' $assignment.Extent.Text "$Script renders into the protected workspace source"
            Assert-Match '\$seedWorkspace\s*=\s*New-CachingProxySeedWorkspace' $try.Body.Extent.Text "$Script creates its protected workspace inside the try"
            Assert-Match 'Remove-CachingProxySeedWorkspace -Workspace \$seedWorkspace' $try.Finally.Extent.Text "$Script disposes that same protected workspace in finally"
            $cleanup = Get-YurunaTestFunctionAst -Path (Join-Path $script:RepoRoot 'host/modules/Yuruna.CachingProxySeed.psm1') -Name 'Remove-CachingProxySeedWorkspace'
            Assert-Match 'Remove-Item -LiteralPath \$Workspace\.Root -Recurse -Force' $cleanup.Extent.Text 'the helper removes the containing source and image staging tree'
        } else {
            Assert-Match 'Remove-Item -LiteralPath \$SeedDir -Recurse' $try.Finally.Extent.Text "$Script removes the seed in that finally"
        }
    }

    It 'removes the <Function> temp files of <Driver> in a finally' -TestCases @(
        @{ Driver = 'host/windows.hyper-v/modules/Yuruna.Host.psm1'; Function = 'Save-VMSerialCapture'; Removes = 'claimed.LogPath' }
        @{ Driver = 'host/windows.hyper-v/modules/Yuruna.Host.psm1'; Function = 'Save-VMDhcpCapture'; Removes = 'claimed.EtlPath' }
        @{ Driver = 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'; Function = 'Save-VMDhcpCapture'; Removes = 'claimed.PcapPath' }
    ) {
        param($Driver, $Function, $Removes)
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $script:RepoRoot $Driver) -Name $Function
        Assert-NotNull $fn "$Driver defines $Function"
        $try = $fn.Body.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $false)
        Assert-NotNull $try "$Function has a try with a finally"
        Assert-Match ('Remove-Item -LiteralPath \$' + [regex]::Escape($Removes)) $try.Finally.Extent.Text "$Function removes the file in its finally"
        Assert-True ($try.Body.Extent.Text -notmatch ('Remove-Item -LiteralPath \$capture\.' + ($Removes -replace '^claimed\.', ''))) 'and no longer only on its success path'
    }

    It 'gives every host download its own CA file and removes it, a failed download included' {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking
        $ca = Join-Path $TestDrive 'yuruna-squid-ca-0123456789abcdef0123456789abcdef.pem'
        [IO.File]::WriteAllText($ca, 'cert')
        Mock -ModuleName Yuruna.HostDownload Get-CacheProxyForHostDownload { @{ Proxy = 'http://127.0.0.1:1'; CaPemPath = $ca } }.GetNewClosure()
        Mock -ModuleName Yuruna.HostDownload Invoke-HttpsViaSquidBump { throw 'the download failed' }
        Assert-Throw { Save-CachedHttpUri -Uri 'https://example.invalid/x' -OutFile (Join-Path $TestDrive 'x') -ResolveCacheHostIp { '127.0.0.1' } -InformationAction SilentlyContinue }
        Assert-False (Test-Path -LiteralPath $ca) 'the CA file does not outlive the failed download'
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1'))
        Assert-True ($source -notmatch "'yuruna-squid-ca\.pem'") 'no shared fixed name another download could delete underneath'
    }
}
