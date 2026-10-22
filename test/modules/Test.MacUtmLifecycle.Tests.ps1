<#PSScriptInfo
.VERSION 2026.10.22
.GUID 421bcd14-05b3-497a-86ea-db4eb3a90148
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm lifecycle rename resume watchdog pester
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
    The macOS driver's UTM application primitives, Rename-VM on top of them,
    the dialog-watchdog identity check, and the deadline-bound start, resume,
    power-off and force-stop paths.
.DESCRIPTION
    Behavior, not source text: every case runs the real driver against the
    stand-in macOS host from Test.MacUtmFakeHost and asserts on what the
    stand-ins were asked to do, in which order, and what they were never
    asked to do. The cases run on any POSIX host; Windows skips them because
    the stand-ins are /bin/sh scripts, and says so.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DriverPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.MacUtmFakeHost.psm1') -Force -Global -DisableNameChecking
    $script:Driver = Get-MacUtmFakeDriver
    $script:CanShim = -not $IsWindows
    if ($script:CanShim) {
        $script:FakeRoot = Join-Path ([IO.Path]::GetTempPath()) ("yrn-maclife-" + [guid]::NewGuid().ToString('N'))
        $script:Fake = New-MacUtmFakeHost -Root $script:FakeRoot
    }
    function Use-FakeHost {
        param([string]$SessionKind = 'Aqua', [string]$Utmctl = 'path')
        Exit-MacUtmFakeHost -FakeHost $script:Fake
        Enter-MacUtmFakeHost -FakeHost $script:Fake -SessionKind $SessionKind -Utmctl $Utmctl
    }
    function Invoke-InDriver {
        param([scriptblock]$Body, [object[]]$Argument = @())
        return (& $script:Driver $Body @Argument)
    }
    function Get-Call { param([string]$Tool) return @(Get-MacUtmFakeCall -FakeHost $script:Fake -Tool $Tool) }
    function Get-CallIndex {
        param([string]$Pattern, [int]$After = -1)
        $calls = @(Get-MacUtmFakeCall -FakeHost $script:Fake)
        for ($i = $After + 1; $i -lt $calls.Count; $i++) { if ($calls[$i] -like $Pattern) { return $i } }
        return -1
    }
    function Set-State {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the fake host state directory.')]
        [CmdletBinding()]
        param([string]$Key, [string]$Value)
        Set-MacUtmFakeState -FakeHost $script:Fake -Key $Key -Value $Value
    }
    function Get-Evidence {
        param([string]$State = 'Unresponsive', [string]$Reason = 'timeout', [bool]$Corroborated = $true, [long]$AgeMs = 0)
        return [pscustomobject]@{ state = $State; reason = $Reason; corroborated = $Corroborated; observedTick = ([Environment]::TickCount64 - $AgeMs) }
    }
    $script:Skip = 'the stand-in tools are POSIX shell scripts'
    function Add-FakeCrashReport {
        param([string]$Name, [int]$AgeMinutes = 5, [int]$Bytes = 64)
        $dir = Join-Path $script:Fake.Home 'Library/Logs/DiagnosticReports'
        $null = New-Item -ItemType Directory -Force -Path $dir
        $path = Join-Path $dir $Name
        [System.IO.File]::WriteAllText($path, ('x' * $Bytes))
        [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddMinutes(-$AgeMinutes))
        return $path
    }
}

AfterAll {
    if ($script:Fake) { Remove-MacUtmFakeHost -FakeHost $script:Fake }
}

Describe 'UTM console activation result' {
    It 'reports <Case> accurately without treating a failed activation as a repaired console' -TestCases @(
        @{ Case = 'success'; Started = $true; TimedOut = $false; ExitCode = 0; OutputTruncated = $false; Expected = $true }
        @{ Case = 'launch failure'; Started = $false; TimedOut = $false; ExitCode = -1; OutputTruncated = $false; Expected = $false }
        @{ Case = 'timeout'; Started = $true; TimedOut = $true; ExitCode = -1; OutputTruncated = $false; Expected = $false }
        @{ Case = 'Apple Event rejection'; Started = $true; TimedOut = $false; ExitCode = 1; OutputTruncated = $false; Expected = $false }
        @{ Case = 'incomplete output'; Started = $true; TimedOut = $false; ExitCode = 0; OutputTruncated = $true; Expected = $false }
    ) {
        param($Case, $Started, $TimedOut, $ExitCode, $OutputTruncated, $Expected)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:DriverPath, [ref]$null, [ref]$errors)
        $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restart-UtmConsole' }, $true)
        $reading = @{ Started = $Started; TimedOut = $TimedOut; ExitCode = $ExitCode; OutputTruncated = $OutputTruncated; DrainTimedOut = $false; KillFailed = $false }
        $result = & {
            param($Source, $Reading)
            $activationReading = $Reading
            function Invoke-UtmHostTool {
                param($Tool, $ArgumentList, $TimeoutSeconds)
                Assert-StringEqual 'osascript' $Tool
                Assert-Equal 10 $TimeoutSeconds
                Assert-True ($ArgumentList[-1] -eq 'tell application "UTM" to activate') 'only the UTM repaint operation is requested'
                return $activationReading
            }
            function Test-UtmBoundedResultComplete {
                param($Result)
                return (Test-BoundedNativeResultComplete -Result $Result)
            }
            . ([scriptblock]::Create($Source))
            Restart-UtmConsole -VMName 'test-guest.ubuntu.server.26-01' -Confirm:$false
        } $functionAst.Extent.Text $reading
        Assert-Equal $Expected $result -Because $Case
    }
}

Describe 'UTM application primitives (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'Stop-UtmApplication quits gracefully without a single signal' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        $r = Stop-UtmApplication -QuitWaitSeconds 2 -Confirm:$false
        Assert-True $r.Stopped
        Assert-StringEqual 'quit' $r.Outcome
        Assert-True $r.QuitSent
        Assert-True ($r.HelperPidBefore -contains 610) 'the helpers seen before the quit are reported'
        Assert-Equal 0 (Get-Call 'kill').Count -Because 'a quit that was honored needs no signal'
    }

    It 'Stop-UtmApplication leaves UTM and helpers intact without -AllowHardStop' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        Set-State 'quit.mode' 'ignore'
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $r.Stopped
        Assert-StringEqual 'partial' $r.Outcome
        Assert-Equal 0 (Get-Call 'kill').Count
        Assert-True ($r.RemainingUtmPid -contains 600 -and $r.RemainingHelperPid -contains 610) 'what remains is reported'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Proc '610')) 'the helper was left running'
    }

    It 'Stop-UtmApplication -AllowHardStop signals UTM first and helpers last, KILL only for survivors' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 611 -Name 'QEMUHelper'
        # Another user's processes are never listed nor signaled.
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 700 -Name 'UTM' -Uid '502'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 710 -Name 'QEMUHelper' -Uid '502'
        Set-State 'quit.mode' 'ignore'
        Set-State 'kill.mode' 'survive-term'
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-True $r.Stopped
        Assert-StringEqual 'hard-stopped' $r.Outcome
        $kills = Get-Call 'kill'
        Assert-StringEqual 'kill -TERM 600|kill -KILL 600|kill -TERM 610|kill -KILL 610|kill -TERM 611|kill -KILL 611' ($kills -join '|')
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Proc '700')) "another user's UTM is untouched"
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Proc '710')) "another user's helper is untouched"
        Assert-Equal 6 @($r.Signal | Where-Object { $_.Result -eq 'sent' }).Count
    }

    It 'Stop-UtmApplication sends only TERM when that is enough' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-State 'quit.mode' 'ignore'
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'hard-stopped' $r.Outcome
        Assert-StringEqual 'kill -TERM 600' ((Get-Call 'kill') -join '|')
    }

    It 'Stop-UtmApplication does not signal a pid whose identity changed after capture' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-State 'quit.mode' 'ignore'
        # The capture reads one start time, the revalidation another: the pid
        # now belongs to a different process instance.
        Set-State 'ps.start.600.queue' "Thu Sep 25 01:00:00 2026`nFri Sep 26 02:00:00 2026"
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 0 (Get-Call 'kill').Count -Because 'an identity that changed is never signaled'
        Assert-StringEqual 'skipped-identity' (@($r.Signal)[0].Result)
        Assert-StringEqual 'partial' $r.Outcome
    }

    It 'Stop-UtmApplication -AllowHardStop never signals a same-user process that only looks like UTM or a helper (<Quit>)' -TestCases @(
        @{ Quit = 'app-only'; Kills = '' }
        @{ Quit = 'ignore';   Kills = 'kill -TERM 600' }
    ) {
        param($Quit, $Kills)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        # Names the helper only in an argument: never a census match at all.
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 620 -Name 'tail' -Command '/usr/bin/tail -f /Users/op/Library/Logs/QEMUHelper.log'
        # Carries the helper bundle path in an argument: listed, not signaled.
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 621 -Name 'less' -Command '/usr/bin/less /Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/Info.plist'
        # Shares UTM's process name, not its executable.
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 630 -Name 'utm' -Command '/opt/tools/utm --serve'
        Set-State 'quit.mode' $Quit
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual $Kills ((Get-Call 'kill') -join '|') -Because 'only the process running UTM itself is ever signaled'
        foreach ($id in 620, 621, 630) {
            Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Proc "$id")) "pid $id is untouched"
        }
        Assert-False ($r.HelperPidBefore -contains 620) 'a log file named after the helper is not a helper'
        $skipped = @($r.Signal | Where-Object { $_.Result -eq 'skipped-identity' } | ForEach-Object { $_.ProcessId })
        Assert-True ($skipped -contains 621 -and $skipped -contains 630) "the look-alikes are reported as skipped ($($skipped -join ','))"
        Assert-StringEqual 'partial' $r.Outcome -Because 'a listed process that could not be stopped is not a confirmed stop'
    }

    It 'Stop-UtmApplication -AllowHardStop reads every identity before the first signal and stops the QEMU process inside the helper bundle' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 612 -Name 'QEMULauncher' `
            -Command '/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher /Applications/UTM.app/Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu -L /x'
        Set-State 'quit.mode' 'ignore'
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'hard-stopped' $r.Outcome
        Assert-StringEqual 'kill -TERM 600|kill -TERM 610|kill -TERM 612' ((Get-Call 'kill') -join '|') -Because 'UTM first, the helpers last'
        $firstSignal = Get-CallIndex 'kill *'
        foreach ($id in 600, 610, 612) {
            $read = Get-CallIndex "ps -o uid=,lstart=,command= -p $id"
            Assert-True ($read -ge 0 -and $read -lt $firstSignal) "pid $id was read before the first signal"
        }
    }

    It 'Stop-UtmApplication reports an identity it cannot read as unreadable and signals nothing: <Case>' -TestCases @(
        @{ Case = 'the first reading'; Queue = 'garble' }
        @{ Case = 'the revalidation';  Queue = "ok`ngarble" }
    ) {
        param($Case, $Queue)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-State 'quit.mode' 'ignore'
        Set-State 'ps.queue' $Queue
        $r = Stop-UtmApplication -QuitWaitSeconds 1 -AllowHardStop -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 0 (Get-Call 'kill').Count -Because $Case
        Assert-StringEqual 'skipped-unreadable' (@($r.Signal)[0].Result) $Case
        Assert-StringEqual 'partial' $r.Outcome $Case
    }

    It 'Stop-UtmApplication -FlushPreferenceCache flushes once, after the processes are gone' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Stop-UtmApplication -QuitWaitSeconds 2 -FlushPreferenceCache -Confirm:$false
        Assert-True $r.PreferenceCacheFlushed
        Assert-Equal 1 (Get-Call 'killall').Count
        $quitAt = Get-CallIndex 'osascript -e tell application "UTM" to quit'
        $flushAt = Get-CallIndex 'killall cfprefsd'
        Assert-True ($quitAt -ge 0 -and $flushAt -gt $quitAt) 'the flush follows the confirmed quit'
    }

    It 'Stop-UtmApplication skips the flush as root' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-MacUtmFakeUid -FakeHost $script:Fake -Uid '0'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM' -Uid '0'
        $r = Stop-UtmApplication -QuitWaitSeconds 2 -FlushPreferenceCache -Confirm:$false -WarningAction SilentlyContinue
        Assert-True $r.Stopped
        Assert-False $r.PreferenceCacheFlushed
        Assert-Equal 0 (Get-Call 'killall').Count -Because "root's killall would reach every user's cfprefsd"
    }

    It 'Stop-UtmApplication refuses before the quit when the census cannot be read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'pgrep.mode' 'fail'
        $r = Stop-UtmApplication -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'refused' $r.Outcome
        Assert-Equal 0 (Get-Call 'osascript').Count
    }

    It 'Stop-UtmApplication and Start-UtmApplication run nothing under -WhatIf' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Assert-StringEqual 'preview' (Stop-UtmApplication -WhatIf).Outcome
        Assert-StringEqual 'preview' (Start-UtmApplication -WhatIf).Outcome
        Assert-Equal 0 (Get-MacUtmFakeCall -FakeHost $script:Fake).Count
    }

    It 'Start-UtmApplication skips the flush, not the launch, when the census cannot be read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        # Only the first census read fails; the post-launch reads answer.
        Set-State 'pgrep.queue' 'fail'
        $r = Start-UtmApplication -LaunchWaitSeconds 2 -FlushPreferenceCache -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 0 (Get-Call 'killall').Count -Because 'an unknown census may hide a running UTM'
        Assert-False $r.PreferenceCacheFlushed
        Assert-StringEqual 'open -a UTM' ((Get-Call 'open') -join '|')
        Assert-StringEqual 'launched' $r.Outcome
    }

    It 'Start-UtmApplication leaves a running UTM alone' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Start-UtmApplication -FlushPreferenceCache -Confirm:$false
        Assert-StringEqual 'already-running' $r.Outcome
        Assert-True $r.Started
        Assert-Equal 0 (Get-Call 'open').Count
        Assert-Equal 0 (Get-Call 'killall').Count -Because 'nothing is flushed when nothing is launched'
    }

    It 'Start-UtmApplication launches once and confirms UTM for this user' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $r = Start-UtmApplication -LaunchWaitSeconds 2 -Confirm:$false
        Assert-StringEqual 'launched' $r.Outcome
        Assert-True $r.Started
        Assert-True $r.Acknowledged
        Assert-True ($r.UtmPid.Count -eq 1) 'the new UTM pid is reported'
        Assert-StringEqual 'open -a UTM' ((Get-Call 'open') -join '|')
    }

    It 'Start-UtmApplication reports a launch it never observed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'open.mode' 'noproc'
        $r = Start-UtmApplication -LaunchWaitSeconds 1 -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'not-observed' $r.Outcome
        Assert-False $r.Started
        Assert-True $r.Acknowledged
    }

    It 'Start-UtmApplication -RequireGuiSession refuses <Case> without launching' -TestCases @(
        @{ Case = 'a remote session'; Session = 'Remote'; Uid = '501'; Reason = 'no-session' }
        @{ Case = 'root';             Session = 'Aqua';   Uid = '0';   Reason = 'root' }
    ) {
        param($Case, $Session, $Uid, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Use-FakeHost -SessionKind $Session
        Set-MacUtmFakeUid -FakeHost $script:Fake -Uid $Uid
        $r = Start-UtmApplication -RequireGuiSession -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'refused' $r.Outcome $Case
        Assert-StringEqual $Reason $r.Reason $Case
        Assert-Equal 0 (Get-Call 'open').Count -Because $Case
    }

    It 'Start-UtmApplication never kills a launch that does not return' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'open.mode' 'hang'
        $deadline = New-YurunaDeadline -TotalMilliseconds 3000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Start-UtmApplication -Deadline $deadline -LaunchWaitSeconds 5 -Confirm:$false -WarningAction SilentlyContinue
        Assert-True ($sw.Elapsed.TotalSeconds -lt 6) 'bounded by the deadline'
        Assert-False $r.Acknowledged
        Assert-StringEqual 'not-observed' $r.Outcome
        $spawned = @([IO.File]::ReadAllLines((Join-Path $script:Fake.State 'spawned')) | Where-Object { $_ })
        Assert-True ($spawned.Count -ge 1) 'the stand-in launcher recorded itself'
        $launcher = Get-Process -Id ([int]$spawned[-1]) -ErrorAction SilentlyContinue
        Assert-NotNull $launcher 'the launcher was left running, not killed'
        Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    }

    It 'Restart-UtmApplication refuses evidence that does not permit disruption: <Case>' -TestCases @(
        @{ Case = 'undetermined';    State = 'Undetermined'; Reason = 'timeout';           Corroborated = $false; Age = 0 }
        @{ Case = 'denied';          State = 'Undetermined'; Reason = 'permission-denied'; Corroborated = $false; Age = 0 }
        @{ Case = 'uncorroborated';  State = 'Unresponsive'; Reason = 'timeout';           Corroborated = $false; Age = 0 }
        @{ Case = 'stale';           State = 'Unresponsive'; Reason = 'timeout';           Corroborated = $true;  Age = 200000 }
        @{ Case = 'app-stopped';     State = 'Unresponsive'; Reason = 'app-stopped';       Corroborated = $false; Age = 0 }
    ) {
        param($Case, $State, $Reason, $Corroborated, $Age)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Restart-UtmApplication -Evidence (Get-Evidence -State $State -Reason $Reason -Corroborated $Corroborated -AgeMs $Age) -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'refused' $r.Outcome $Case
        Assert-Equal 0 (Get-MacUtmFakeCall -FakeHost $script:Fake).Count -Because "$Case must touch nothing"
    }

    It 'Restart-UtmApplication restarts on fresh corroborated evidence, without flushing' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        $r = Restart-UtmApplication -Evidence (Get-Evidence) -QuitWaitSeconds 2 -LaunchWaitSeconds 2 -Confirm:$false
        Assert-StringEqual 'restarted' $r.Outcome
        Assert-False $r.HardStopUsed
        Assert-True ($r.HelperPidBefore -contains 610) 'the collateral is reported'
        Assert-Equal 0 (Get-Call 'killall').Count -Because 'a restart never flushes preferences'
        Assert-Equal 0 (Get-Call 'kill').Count
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 0 (Get-Call 'utmctl').Count -Because 'guests are not resumed here'
    }

    It 'Restart-UtmApplication stops short of the relaunch when the stop is partial' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        Set-State 'quit.mode' 'app-only'
        $r = Restart-UtmApplication -Evidence (Get-Evidence) -QuitWaitSeconds 1 -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'partial' $r.Outcome
        Assert-Equal 0 (Get-Call 'open').Count -Because 'no relaunch next to orphaned helpers'
        Assert-Equal 0 (Get-Call 'kill').Count -Because 'no hard stop without -AllowHardStop'
    }

    It 'Restart-UtmApplication refuses a remote session after valid evidence' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Use-FakeHost -SessionKind 'Remote'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $r = Restart-UtmApplication -Evidence (Get-Evidence) -Confirm:$false -WarningAction SilentlyContinue
        Assert-StringEqual 'refused' $r.Outcome
        Assert-StringEqual 'no-session' $r.Reason
        Assert-Equal 0 (Get-Call 'osascript').Count
    }
}

Describe 'Save-UtmControlSnapshot (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) {
            Reset-MacUtmFakeHost -FakeHost $script:Fake
            Enter-MacUtmFakeHost -FakeHost $script:Fake
            $script:SnapshotDir = Join-Path $script:Fake.Root ("snapshot-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Force -Path $script:SnapshotDir
            # Crash reports live in the fake home, which the reset keeps.
            Remove-Item -LiteralPath (Join-Path $script:Fake.Home 'Library/Logs/DiagnosticReports') -Recurse -Force -ErrorAction SilentlyContinue
            $script:SavedEnvironment = @{
                Context = $env:YURUNA_CYCLE_CONTEXT; LogDir = $env:YURUNA_LOG_DIR
                Folder = Get-Variable -Name '__YurunaCycleFolder' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            }
            $env:YURUNA_CYCLE_CONTEXT = ''
            $env:YURUNA_LOG_DIR = ''
            Set-Variable -Name '__YurunaCycleFolder' -Scope Global -Value $null -Force
        }
    }
    AfterEach {
        if ($script:CanShim) {
            $env:YURUNA_CYCLE_CONTEXT = $script:SavedEnvironment.Context
            $env:YURUNA_LOG_DIR = $script:SavedEnvironment.LogDir
            Set-Variable -Name '__YurunaCycleFolder' -Scope Global -Value $script:SavedEnvironment.Folder -Force
            Exit-MacUtmFakeHost -FakeHost $script:Fake
        }
    }
    It 'records the census, the listing, recent crash reports and the log excerpt' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM' -StartText 'Wed Oct 15 06:39:04 2026'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 601 -Name 'QEMUHelper'
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'amisad-edge-a' -Status 'stopped'
        $null = Add-FakeCrashReport -Name 'UTM-2026-10-15-063905.ips' -AgeMinutes 3
        $null = Add-FakeCrashReport -Name 'QEMUHelper-2026-10-15-063906.ips' -AgeMinutes 4
        $null = Add-FakeCrashReport -Name 'UTM-2026-09-01-000000.ips' -AgeMinutes 600
        $null = Add-FakeCrashReport -Name 'Safari-2026-10-15-063907.ips' -AgeMinutes 1
        $r = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'test-capture' -Confirm:$false } @($script:SnapshotDir)
        Assert-True $r.Written $r.Reason
        Assert-True (Test-Path -LiteralPath $r.Path) 'the snapshot file exists'
        $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
        Assert-StringEqual 'yuruna.utm-control-snapshot/v1' $record.schema
        Assert-StringEqual 'test-capture' $record.trigger
        Assert-StringEqual 'running' $record.application.state
        Assert-True (@($record.application.utmPid) -contains 600) 'the UTM pid is in the census'
        Assert-True (@($record.application.helperPid) -contains 601) 'the helper pid is in the census'
        $utm = @($record.processes | Where-Object { $_.pid -eq 600 })
        Assert-Equal 1 $utm.Count
        Assert-StringEqual 'Wed Oct 15 06:39:04 2026' $utm[0].startText 'the start time is what tells a relaunch'
        Assert-Match 'amisad-edge-a' $record.listing.text 'the raw listing is kept'
        $names = @($record.crashReports | ForEach-Object { $_.name })
        Assert-True ($names -contains 'UTM-2026-10-15-063905.ips') 'a recent UTM report is named'
        Assert-True ($names -contains 'QEMUHelper-2026-10-15-063906.ips') 'a recent helper report is named'
        Assert-True (-not ($names -contains 'UTM-2026-09-01-000000.ips')) 'an old report is outside the window'
        Assert-True (-not ($names -contains 'Safari-2026-10-15-063907.ips')) 'an unrelated report is not ours'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:SnapshotDir 'utm-crash-reports.test-capture/UTM-2026-10-15-063905.ips')) 'the recent report was copied'
        Assert-Equal 2 $record.unifiedLog.lines
        Assert-True (Test-Path -LiteralPath $record.unifiedLog.path) 'the log excerpt was written'
        Assert-Equal 1 @(Get-Call 'log' | Where-Object { $_ -like 'log show --last 30m*' }).Count -Because 'one bounded log show over the window'
        Assert-Equal 0 @($record.problems).Count -Because "nothing failed: $($record.problems -join '; ')"
        Assert-Null $record.screenshot 'no VM named, no screenshot'
    }

    It 'names the crash report it did not copy, keeping the newest few and nothing large' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        foreach ($i in 1..4) { $null = Add-FakeCrashReport -Name "UTM-2026-10-15-06390$i.ips" -AgeMinutes (10 - $i) }
        $null = Add-FakeCrashReport -Name 'UTM-2026-10-15-063900.ips' -AgeMinutes 1 -Bytes (3MB)
        $r = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'many' -Confirm:$false } @($script:SnapshotDir)
        $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
        Assert-Equal 5 @($record.crashReports).Count
        Assert-Equal 3 @($record.crashReports | Where-Object { $_.copied }).Count -Because 'the newest three small ones are copied'
        $large = @($record.crashReports | Where-Object { $_.name -eq 'UTM-2026-10-15-063900.ips' })[0]
        Assert-False $large.copied 'the large one is named only'
    }

    It 'resolves the cycle folder from the published cycle context, then the log root, and writes nothing without either' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $none = Invoke-InDriver { Save-UtmControlSnapshot -Trigger 'nowhere' -Confirm:$false }
        Assert-False $none.Written
        Assert-StringEqual 'no-output-directory' $none.Reason
        $cycle = Join-Path $script:SnapshotDir 'cycle'
        $null = New-Item -ItemType Directory -Force -Path $cycle
        $env:YURUNA_CYCLE_CONTEXT = (@{ rootCycleFolder = $cycle } | ConvertTo-Json -Compress)
        $fromContext = Invoke-InDriver { Save-UtmControlSnapshot -Trigger 'context' -Confirm:$false }
        Assert-True $fromContext.Written
        Assert-StringEqual (Join-Path $cycle 'utm-control-snapshot.context.json') $fromContext.Path
        $env:YURUNA_CYCLE_CONTEXT = ''
        $env:YURUNA_LOG_DIR = $script:SnapshotDir
        $fromRoot = Invoke-InDriver { Save-UtmControlSnapshot -Trigger 'root' -Confirm:$false }
        Assert-StringEqual $script:SnapshotDir $fromRoot.Directory
        $env:YURUNA_CYCLE_CONTEXT = (@{ rootCycleFolder = (Join-Path $script:SnapshotDir 'gone') } | ConvertTo-Json -Compress)
        $stale = Invoke-InDriver { Save-UtmControlSnapshot -Trigger 'stale' -Confirm:$false }
        Assert-StringEqual $script:SnapshotDir $stale.Directory 'a cycle folder no longer on disk is skipped'
    }

    It 'records a log tool that <Case> instead of throwing, within its bound' -TestCases @(
        @{ Case = 'fails'; Mode = 'fail'; TimedOut = $false }
        @{ Case = 'hangs'; Mode = 'hang'; TimedOut = $true }
    ) {
        param($Case, $Mode, $TimedOut)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-State 'log.mode' $Mode
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'log' -LogTimeoutSeconds 1 -Confirm:$false } @($script:SnapshotDir)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 8) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-True $r.Written "the snapshot is still written when the log tool $Case"
        $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
        Assert-Equal $TimedOut $record.unifiedLog.timedOut -Because $Case
        Assert-StringEqual '' $record.unifiedLog.path "no excerpt file when the tool $Case"
    }

    It 'previews under -WhatIf and writes nothing' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $r = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'preview' -WhatIf } @($script:SnapshotDir)
        Assert-False $r.Written
        Assert-StringEqual 'preview' $r.Reason
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:SnapshotDir -File).Count
        Assert-Equal 0 (Get-Call 'utmctl').Count -Because 'nothing was asked'
    }

    It 'captures the named VM through the contract screenshot verb and records a verb that fails' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $original = Invoke-InDriver { ${function:Get-VMScreenshot} }
        try {
            Invoke-InDriver { Set-Item -Path 'function:script:Get-VMScreenshot' -Value { param([string]$VMName, [string]$Source = 'frame', [string]$OutFile) $null = @($VMName, $Source); [System.IO.File]::WriteAllBytes($OutFile, [byte[]]@(137, 80, 78, 71)); return $true } }
            $r = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'shot' -VMName 'amisad-edge-a' -Confirm:$false } @($script:SnapshotDir)
            $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
            Assert-StringEqual 'captured' $record.screenshot.outcome
            Assert-True (Test-Path -LiteralPath $record.screenshot.path) 'the screenshot file exists'
            Invoke-InDriver { Set-Item -Path 'function:script:Get-VMScreenshot' -Value { param([string]$VMName, [string]$Source = 'frame', [string]$OutFile) $null = @($VMName, $Source, $OutFile); throw 'no display' } }
            $failed = Invoke-InDriver { param($d) Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'noshot' -VMName 'amisad-edge-a' -Confirm:$false } @($script:SnapshotDir)
            $failedRecord = Get-Content -Raw -LiteralPath $failed.Path | ConvertFrom-Json -AsHashtable
            Assert-StringEqual 'failed' $failedRecord.screenshot.outcome
            Assert-True ([bool](@($failedRecord.problems) -match 'screenshot')) 'the failure is in the record'
            Assert-True $failed.Written 'the snapshot is still written'
        } finally {
            Invoke-InDriver { param($f) Set-Item -Path 'function:script:Get-VMScreenshot' -Value $f } @($original)
        }
    }
    It 'omits the screenshot when a shared startup diagnostic budget must stay bounded' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        $original = Invoke-InDriver { ${function:Get-VMScreenshot} }
        try {
            Invoke-InDriver {
                $script:SkippedSnapshotCalls = 0
                Set-Item -Path 'function:script:Get-VMScreenshot' -Value {
                    param([string]$VMName, [string]$Source = 'frame', [string]$OutFile)
                    $null = @($VMName, $Source, $OutFile)
                    $script:SkippedSnapshotCalls++
                    throw 'the unbounded screenshot path must never be called'
                }
            }
            $r = Invoke-InDriver {
                param($d)
                Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'startup-timeout' -VMName 'amisad-edge-a' `
                    -SkipScreenshot -Deadline (New-YurunaDeadline -TotalMilliseconds 30000) -Confirm:$false
            } @($script:SnapshotDir)
            Assert-True $r.Written 'the other diagnostic evidence is still retained'
            $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
            Assert-StringEqual 'skipped' $record.screenshot.outcome
            Assert-StringEqual '' $record.screenshot.path
            Assert-Equal 0 (Invoke-InDriver { $script:SkippedSnapshotCalls }) -Because 'the screenshot ignores the shared deadline'
            Assert-True ($null -ne $record.listing) 'bounded VM listing is retained'
            Assert-True ($null -ne $record.unifiedLog) 'bounded native log evidence is retained'
        } finally {
            Invoke-InDriver { param($f) Set-Item -Path 'function:script:Get-VMScreenshot' -Value $f } @($original)
        }
    }
}

Describe 'Rename-VM on the UTM primitives (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) {
            Reset-MacUtmFakeHost -FakeHost $script:Fake
            Enter-MacUtmFakeHost -FakeHost $script:Fake
            $display = Invoke-InDriver { Get-VncDisplayForVm -VMName 'test-dst' }
            Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'test-src' -Status 'stopped' -WithBundle -Display $display
            Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Status 'started'
            Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
            Set-State 'rename.from' 'test-src'
            Set-State 'watchdog.mode' 'live'
        }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'captures, quits, edits, flushes, relaunches and resumes in that order' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-True $ok 'the rename surfaced'
        $listAt   = Get-CallIndex 'utmctl list'
        $quitAt   = Get-CallIndex 'osascript -e tell application "UTM" to quit'
        $flush1   = Get-CallIndex 'killall cfprefsd' $quitAt
        $nameAt   = Get-CallIndex 'PlistBuddy -c Set :Information:Name test-dst*'
        $regAt    = Get-CallIndex 'PlistBuddy -c Set :Registry:*:Name test-dst*'
        $flush2   = Get-CallIndex 'killall cfprefsd' $regAt
        $openAt   = Get-CallIndex 'open -a UTM'
        $resumeAt = Get-CallIndex 'utmctl start yuruna-stash-service'
        Assert-True ($listAt -ge 0 -and $listAt -lt $quitAt) 'the capture precedes the quit'
        Assert-True ($flush1 -gt $quitAt -and $flush1 -lt $nameAt) 'the post-quit flush precedes the edits'
        Assert-True ($nameAt -lt $regAt) 'bundle name, then registry'
        Assert-True ($flush2 -gt $regAt -and $flush2 -lt $openAt) 'the pre-relaunch flush follows the edits'
        Assert-True ($openAt -lt $resumeAt) 'the resume follows the relaunch'
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
        Assert-Equal 0 (Get-Call 'kill' | Where-Object { $_ -notlike 'kill -TERM *' }).Count -Because 'a quit that was honored is never escalated'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Home 'yuruna/guest.nosync/test-dst.utm')) 'the bundle moved'
    }

    It 'reverts, flushes, relaunches once and resumes once when the registry edit fails' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'plistbuddy.fail' ':Registry:'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Home 'yuruna/guest.nosync/test-src.utm')) 'the bundle was renamed back'
        Assert-Equal 2 (Get-Call 'killall').Count -Because 'the registry may hold a partial edit, so it is re-read'
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
    }

    It 'relaunches once without a pre-relaunch flush when the bundle Name edit fails' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'plistbuddy.fail' 'Set :Information:Name test-dst'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Home 'yuruna/guest.nosync/test-src.utm')) 'the bundle was renamed back'
        Assert-Equal 1 (Get-Call 'killall').Count -Because 'only the post-quit flush'
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
    }

    It 'relaunches once without a pre-relaunch flush when the bundle rename fails' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $store = Join-Path $script:Fake.Home 'yuruna/guest.nosync'
        # A read-only parent makes the directory rename fail after the quit.
        & chmod 555 $store
        try {
            $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        } finally { & chmod 755 $store }
        Assert-False $ok
        Assert-Equal 0 (Get-Call 'PlistBuddy' | Where-Object { $_ -like '*Set *' }).Count -Because 'no edit follows a failed rename'
        Assert-Equal 1 (Get-Call 'killall').Count -Because 'only the post-quit flush'
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
    }

    It 'does not quit UTM when the running list cannot be read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'list.mode' 'deny'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-Equal 0 (Get-Call 'osascript').Count -Because 'quitting with an empty capture would strand every service'
        Assert-Equal 0 (Get-Call 'open').Count
    }

    It 'edits nothing and resumes nothing new when the census refuses the stop' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'pgrep.mode' 'fail'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-Equal 0 (Get-Call 'osascript').Count
        Assert-Equal 0 (Get-Call 'open').Count -Because 'the quit was never sent, so there is nothing to relaunch'
        Assert-Equal 0 (Get-Call 'PlistBuddy' | Where-Object { $_ -like '*Set *' }).Count
    }

    It 'edits nothing when UTM and its helpers survive the quit and the hard stop' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 610 -Name 'QEMUHelper'
        Set-State 'quit.mode' 'ignore'
        Set-State 'kill.mode' 'survive'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-Equal 0 (Get-Call 'PlistBuddy' | Where-Object { $_ -like '*Set *' }).Count
        Assert-True (Test-Path -LiteralPath (Join-Path $script:Fake.Home 'yuruna/guest.nosync/test-src.utm')) 'the bundle is where it was'
        Assert-True (@(Get-Call 'kill' | Where-Object { $_ -like 'kill -TERM 600' }).Count -eq 1) 'UTM was signaled'
        $utmTerm = Get-CallIndex 'kill -TERM 600'
        $helperTerm = Get-CallIndex 'kill -TERM 610'
        Assert-True ($utmTerm -ge 0 -and $helperTerm -gt $utmTerm) 'helpers last'
    }

    It 'does not resume when the relaunch is not confirmed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'open.mode' 'noproc'
        $null = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 1 (Get-Call 'open').Count
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count -Because 'services resume only after a confirmed relaunch'
    }

    It 'still refuses on an unconfirmed source or destination state' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'status.mode' 'deny-exit0'
        $ok = Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue
        Assert-False $ok
        Assert-Equal 0 (Get-Call 'osascript').Count
    }
}

Describe 'UTM dialog watchdog identity (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'records the spawned watchdog and stops it after verifying it' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'watchdog.mode' 'live'
        Start-UtmDialogWatchdog -Confirm:$false
        $paths = Invoke-InDriver { @($script:WatchdogPidFile, $script:WatchdogIdentityPath) }
        Assert-True (Test-Path -LiteralPath $paths[0]) 'the pid file is written'
        Assert-True (Test-Path -LiteralPath $paths[1]) 'the identity record is written'
        $record = Get-Content -Raw -LiteralPath $paths[1] | ConvertFrom-Json
        Assert-Equal 1 $record.schemaVersion
        Assert-StringEqual '501' $record.uid
        Assert-StringEqual ("$(Get-Content -Raw -LiteralPath $paths[0])".Trim()) "$($record.pid)"
        Stop-UtmDialogWatchdog -Confirm:$false
        Assert-Equal 1 (Get-Call 'kill' | Where-Object { $_ -eq "kill -TERM $($record.pid)" }).Count
        Assert-False (Test-Path -LiteralPath $paths[0]) 'the pid file is cleared once the watchdog is gone'
        Assert-False (Test-Path -LiteralPath $paths[1]) 'so is the identity record'
    }

    It 'leaves alone <Case>' -TestCases @(
        @{ Case = 'a recycled pid';          Uid = '501'; Command = 'script'; Sidecar = $true;  Start = 'Fri Sep 26 02:00:00 2026'; Signaled = $false }
        @{ Case = "another user's process";  Uid = '502'; Command = 'script'; Sidecar = $false; Start = 'Thu Sep 25 01:00:00 2026'; Signaled = $false }
        @{ Case = 'an unrelated command';    Uid = '501'; Command = 'other';  Sidecar = $false; Start = 'Thu Sep 25 01:00:00 2026'; Signaled = $false }
        @{ Case = 'nothing: a legacy record'; Uid = '501'; Command = 'script'; Sidecar = $false; Start = 'Thu Sep 25 01:00:00 2026'; Signaled = $true }
    ) {
        param($Case, $Uid, $Command, $Sidecar, $Start, $Signaled)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Invoke-InDriver { @($script:WatchdogPidFile, $script:WatchdogIdentityPath, $script:WatchdogScriptPath) }
        $cmd = if ($Command -eq 'script') { "/usr/bin/osascript $($paths[2])" } else { '/usr/bin/some-other-tool' }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 800 -Name 'osascript' -Uid $Uid -StartText $Start -Command $cmd
        [IO.File]::WriteAllText($paths[0], "800`n")
        if ($Sidecar) {
            [IO.File]::WriteAllText($paths[1], (@{ schemaVersion = 1; pid = 800; uid = '501'; startText = 'Thu Sep 25 01:00:00 2026'; scriptPath = $paths[2] } | ConvertTo-Json -Compress))
        }
        Stop-UtmDialogWatchdog -Confirm:$false -WarningAction SilentlyContinue
        $signals = @(Get-Call 'kill')
        Assert-Equal ([int]$Signaled) $signals.Count -Because $Case
        Assert-Equal (-not $Signaled) (Test-Path -LiteralPath (Join-Path $script:Fake.Proc '800')) -Because "$Case process survives unless verified"
    }

    It 'keeps its records when the identity cannot be read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $paths = Invoke-InDriver { @($script:WatchdogPidFile, $script:WatchdogScriptPath) }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 800 -Name 'osascript' -Command "/usr/bin/osascript $($paths[1])"
        [IO.File]::WriteAllText($paths[0], "800`n")
        Set-State 'ps.queue' 'hang'
        Stop-UtmDialogWatchdog -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 0 (Get-Call 'kill').Count
        Assert-True (Test-Path -LiteralPath $paths[0]) 'an unverified record is kept for the next stop'
    }

    It 'starts no second watchdog while the first cannot be verified (<Mode>)' -TestCases @(@{ Mode = 'hang' }, @{ Mode = 'garble' }) {
        param($Mode)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'watchdog.mode' 'live'
        Start-UtmDialogWatchdog -Confirm:$false
        $paths = Invoke-InDriver { @($script:WatchdogPidFile, $script:WatchdogIdentityPath) }
        $first = "$(Get-Content -Raw -LiteralPath $paths[0])".Trim()
        $record = Get-Content -Raw -LiteralPath $paths[1]
        try {
            # The next identity read does not answer usably.
            Set-State 'ps.queue' $Mode
            Start-UtmDialogWatchdog -Confirm:$false -WarningAction SilentlyContinue
            Assert-StringEqual $first "$(Get-Content -Raw -LiteralPath $paths[0])".Trim() -Because 'the pid file still names the first watchdog'
            Assert-StringEqual $record (Get-Content -Raw -LiteralPath $paths[1]) -Because 'and so does its identity record'
            Assert-Equal 1 @(Get-Call 'osascript' | Where-Object { $_ -notlike 'osascript -*' }).Count -Because 'exactly one watchdog was ever spawned'
            Assert-Equal 0 (Get-Call 'kill').Count
            Assert-NotNull (Get-Process -Id ([int]$first) -ErrorAction SilentlyContinue) 'the first watchdog is still the one running'
        } finally {
            # A readable identity again: the ordinary verified stop ends it.
            Set-MacUtmFakeState -FakeHost $script:Fake -Key 'ps.queue' -Remove
            Stop-UtmDialogWatchdog -Confirm:$false -WarningAction SilentlyContinue
        }
        Assert-False (Test-Path -LiteralPath $paths[0]) 'the next verified stop still finds and stops it'
    }

    It 'removes a leftover identity record only when not previewing' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $identity = Invoke-InDriver { $script:WatchdogIdentityPath }
        [IO.File]::WriteAllText($identity, '{"schemaVersion":1,"pid":800}')
        Stop-UtmDialogWatchdog -WhatIf
        Assert-True (Test-Path -LiteralPath $identity) '-WhatIf changes nothing'
        Stop-UtmDialogWatchdog -Confirm:$false
        Assert-False (Test-Path -LiteralPath $identity) 'a record without a pid file is dropped'
        Assert-Equal 0 (Get-MacUtmFakeCall -FakeHost $script:Fake).Count -Because 'no process was read or signaled'
    }
}

Describe 'Deadline-bound start, resume and power-off (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'Invoke-UtmVMStartWithRetry: <Case>' -TestCases @(
        @{ Case = 'unconfirmed state starts nothing'; Registered = $true;  Status = 'deny-exit0'; Start = '';             Kind = 'unresolved'; Starts = 0; Success = $false }
        @{ Case = 'never registered starts nothing';   Registered = $false; Status = '';           Start = '';             Kind = 'absent';     Starts = 0; Success = $false }
        @{ Case = 'stopped then running';              Registered = $true;  Status = '';           Start = '';             Kind = 'none';       Starts = 1; Success = $true }
        @{ Case = 'unknown after the start';           Registered = $true;  Status = '';           Start = 'fail-unknown'; Kind = 'unresolved'; Starts = 1; Success = $false }
        @{ Case = 'QEMU death is not retried';         Registered = $true;  Status = '';           Start = 'qemu';         Kind = 'qemu';       Starts = 1; Success = $false }
        @{ Case = 'refused on every attempt';          Registered = $true;  Status = '';           Start = 'deny';         Kind = 'apple-event'; Starts = 2; Success = $false }
    ) {
        param($Case, $Registered, $Status, $Start, $Kind, $Starts, $Success)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        if ($Registered) { Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'suspended' }
        if ($Status) { Set-State 'status.mode' $Status }
        if ($Start) { Set-State 'start.mode' $Start }
        $r = Invoke-InDriver { Invoke-UtmVMStartWithRetry -VMName 'svc' -MaxAttempts 2 -SettleSeconds 1 -BackoffSeconds 0 -Confirm:$false -InformationAction SilentlyContinue }
        Assert-StringEqual $Kind $r.kind $Case
        Assert-Equal $Success $r.success -Because $Case
        Assert-Equal $Starts (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count -Because $Case
        if (-not $Success) { Assert-True ([bool]$r.errorMessage) "$Case carries a reason" }
    }

    It 'Invoke-UtmVMStartWithRetry carries controlHung and the Apple Event row in every record' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'stopped'
        $r = Invoke-InDriver { Invoke-UtmVMStartWithRetry -VMName 'svc' -MaxAttempts 1 -SettleSeconds 1 -BackoffSeconds 0 -Confirm:$false -InformationAction SilentlyContinue }
        Assert-True $r.success
        Assert-True ($r.Contains('controlHung') -and -not $r.controlHung) 'a start that took is not a hung channel'
        Assert-StringEqual 'none' $r.appleEventReason
    }

    It 'Invoke-UtmVMStartWithRetry ends after two consecutive control-channel timeouts (<Case>)' -TestCases @(
        @{ Case = 'Apple Event timeouts';           Queue = "timeout-text`ntimeout-text";              Reason = 'timeout' }
        @{ Case = 'a lost connection then a timeout'; Queue = "conninvalid`ntimeout-text";              Reason = 'timeout' }
        @{ Case = 'two lost connections';           Queue = "conninvalid`nconninvalid";                Reason = 'connection-invalid' }
    ) {
        param($Case, $Queue, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'stopped'
        Set-State 'start.queue' $Queue
        $r = Invoke-InDriver { Invoke-UtmVMStartWithRetry -VMName 'svc' -MaxAttempts 5 -SettleSeconds 1 -BackoffSeconds 0 -Confirm:$false -InformationAction SilentlyContinue }
        Assert-False $r.success $Case
        Assert-StringEqual 'apple-event' $r.kind $Case
        Assert-True $r.controlHung "$Case is a hung channel"
        Assert-StringEqual $Reason $r.appleEventReason $Case
        Assert-Equal 2 $r.attempts -Because "$Case stops at the second"
        Assert-Equal 2 @(Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count -Because "$Case issues no third start"
        Assert-Match 'Invoke-HostRefresh' $r.errorMessage 'the message names the repair'
    }

    It 'Invoke-UtmVMStartWithRetry resets the streak on an answer, even a refusal' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'stopped'
        Set-State 'start.queue' "timeout-text`ndeny`ntimeout-text"
        $r = Invoke-InDriver { Invoke-UtmVMStartWithRetry -VMName 'svc' -MaxAttempts 3 -SettleSeconds 1 -BackoffSeconds 0 -Confirm:$false -InformationAction SilentlyContinue }
        Assert-False $r.success
        Assert-StringEqual 'apple-event' $r.kind
        Assert-False $r.controlHung 'a denial in between is an answer from UTM'
        Assert-Equal 3 @(Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count -Because 'every attempt ran'
    }

    It 'Invoke-UtmVMStartWithRetry returns inside its shared deadline' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'stopped'
        Set-State 'start.mode' 'drop'
        $deadline = New-YurunaDeadline -TotalMilliseconds 3000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-InDriver { param($d) Invoke-UtmVMStartWithRetry -VMName 'svc' -MaxAttempts 5 -SettleSeconds 2 -BackoffSeconds 5 -Deadline $d -Confirm:$false -InformationAction SilentlyContinue } @($deadline)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4.5) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-False $r.success
    }

    It 'Resume-YurunaServiceVM shares one deadline across services' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $deadline = New-YurunaDeadline -TotalMilliseconds 3000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $records = @(Resume-YurunaServiceVM -VMName @('ghost-a', 'ghost-b') -TimeoutSeconds 60 -Deadline $deadline -NoDialogWatchdog -Detailed -Confirm:$false -WarningAction SilentlyContinue)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4.5) "one shared reserve, not one per service ($($sw.Elapsed.TotalSeconds) s)"
        Assert-Equal 2 $records.Count
        foreach ($record in $records) {
            Assert-True ($record.Outcome -in @('absent', 'deadline-exhausted')) "$($record.VMName): $($record.Outcome)"
        }
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
    }

    It 'Resume-YurunaServiceVM -NoDialogWatchdog starts no watchdog' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'suspended'
        $failed = @(Resume-YurunaServiceVM -VMName 'svc' -TimeoutSeconds 10 -NoDialogWatchdog -Confirm:$false)
        Assert-Equal 0 $failed.Count
        Assert-Equal 0 (Get-Call 'osascript').Count
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start svc' }).Count
    }

    It 'Resume-YurunaServiceVM leaves the saved state byte-identical after a refused start' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'suspended' -WithBundle -VmState 'saved-ram-bytes'
        Set-State 'start.mode' 'deny'
        $vmstate = Join-Path $script:Fake.Home 'yuruna/guest.nosync/svc.utm/Data/vmstate'
        $before = (Get-FileHash -LiteralPath $vmstate).Hash
        $records = @(Resume-YurunaServiceVM -VMName 'svc' -TimeoutSeconds 3 -NoDialogWatchdog -Detailed -Confirm:$false -WarningAction SilentlyContinue)
        Assert-True ($records[0].Outcome -in @('start-failed', 'unresolved')) "a refused start is not a resume ($($records[0].Outcome))"
        Assert-True (@(Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start svc' }).Count -ge 1) 'the start was attempted'
        Assert-StringEqual $before (Get-FileHash -LiteralPath $vmstate).Hash
        Assert-Equal 0 (Get-Call 'open').Count -Because 'no cold boot through Start-UtmVM'
    }

    It 'Resume-YurunaServiceVM starts only from a positive stopped reading' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'suspended'
        Set-State 'status.mode' 'deny-exit0'
        $records = @(Resume-YurunaServiceVM -VMName 'svc' -TimeoutSeconds 3 -NoDialogWatchdog -Detailed -Confirm:$false -WarningAction SilentlyContinue)
        Assert-StringEqual 'unknown' $records[0].Outcome
        Assert-StringEqual 'permission-denied' $records[0].Reason
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl start*' }).Count
    }

    It 'Resume-YurunaServiceVM -Detailed emits one typed record per VM' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Assert-Equal 0 @(Resume-YurunaServiceVM -VMName @() -Detailed -Confirm:$false).Count
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc-a' -Status 'started'
        $one = @(Resume-YurunaServiceVM -VMName 'svc-a' -TimeoutSeconds 5 -NoDialogWatchdog -Detailed -Confirm:$false)
        Assert-Equal 1 $one.Count
        Assert-StringEqual 'Yuruna.ServiceVmResume' $one[0].PSObject.TypeNames[0]
        Assert-StringEqual 'running' $one[0].Outcome
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc-b' -Status 'suspended'
        $many = @(Resume-YurunaServiceVM -VMName @('svc-a', 'svc-b') -TimeoutSeconds 5 -NoDialogWatchdog -Detailed -Confirm:$false)
        Assert-Equal 2 $many.Count
        Assert-StringEqual 'running|resumed' (($many | ForEach-Object { $_.Outcome }) -join '|')
    }

    It 'Resume-YurunaServiceVM never cold-boots or touches saved state' {
        $fn = Get-YurunaTestFunctionAst -Path $script:DriverPath -Name 'Resume-YurunaServiceVM'
        $commands = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Assert-True ($commands -notcontains 'Start-UtmVM') 'no Start-UtmVM'
        Assert-True ($commands -notcontains 'Start-VM') 'no Start-VM'
        Assert-True ($fn.Extent.Text -cnotmatch 'vmstate') 'no saved-state path'
        foreach ($call in @('Start-UtmDialogWatchdog', 'Stop-UtmDialogWatchdog')) {
            $sites = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $call }, $true))
            Assert-True ($sites.Count -ge 1) "$call is still called"
            foreach ($site in $sites) {
                $guard = $site.Parent
                while ($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
                Assert-True ($guard -and $guard.Clauses[0].Item1.Extent.Text -match 'NoDialogWatchdog') "$call is gated by -NoDialogWatchdog"
            }
        }
    }

    It 'Wait-UtmVMPoweredOff kills once, on a positive running reading, and then sees the disks free' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started' -WithBundle -DiskCount 2
        Assert-True (Wait-UtmVMPoweredOff -VMName 'svc' -TimeoutSeconds 4) 'powered off and unlocked'
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc --kill' }).Count
        Assert-Equal 2 (Get-Call 'qemu-img').Count -Because 'each disk lock is checked'
    }

    It 'Wait-UtmVMPoweredOff never kills on an unconfirmed state and never reports it off' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started' -WithBundle -DiskCount 1
        Set-State 'status.mode' 'deny-exit0'
        Assert-False (Wait-UtmVMPoweredOff -VMName 'svc' -TimeoutSeconds 3)
        Assert-True ((Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl status*' }).Count -ge 1) 'the state was read'
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -like 'utmctl stop*' }).Count
    }

    It 'Wait-UtmVMPoweredOff gives up within the shorter of its budget and the deadline' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started' -WithBundle -DiskCount 1
        Set-State 'stop.mode' 'ignore'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert-False (Wait-UtmVMPoweredOff -VMName 'svc' -TimeoutSeconds 30 -Deadline (New-YurunaDeadline -TotalMilliseconds 1500))
        Assert-True ($sw.Elapsed.TotalSeconds -lt 3.5) "the deadline wins ($($sw.Elapsed.TotalSeconds) s)"
    }

    It 'Wait-UtmVMPoweredOff waits for a held disk lock' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'stopped' -WithBundle -DiskCount 1
        Set-State 'qemuimg.locked' '1'
        Assert-False (Wait-UtmVMPoweredOff -VMName 'svc' -TimeoutSeconds 2)
        Assert-True ((Get-Call 'qemu-img').Count -ge 1) 'the lock was probed'
    }

    It 'Confirm-UtmVMStarted accepts only a positive running state' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started'
        Assert-True (@(Confirm-UtmVMStarted -VMName 'svc' -TimeoutSeconds 2)[-1]) 'running is running'
        Set-State 'status.mode' 'notrunning'
        Clear-MacUtmFakeCall -FakeHost $script:Fake
        Assert-False (Confirm-UtmVMStarted -VMName 'svc' -TimeoutSeconds 2 -WarningAction SilentlyContinue) '"not running" is not running'
        Assert-True ((Get-Call 'utmctl').Count -ge 1) 'the state was read'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert-False (Confirm-UtmVMStarted -VMName 'svc' -TimeoutSeconds 60 -Deadline (New-YurunaDeadline -TotalMilliseconds 1000) -WarningAction SilentlyContinue)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 3) 'the deadline wins'
    }

    It 'Stop-VM requests guest shutdown without using UTM default force-stop' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started'
        Assert-True (Stop-VM -VMName 'svc' -ShutdownTimeoutSeconds 1 -NoForce -Confirm:$false)
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc --request' }).Count
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc' -or $_ -like '*--kill*' }).Count
    }

    It 'Stop-VM leaves an ignored guest shutdown running without force escalation' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started'
        Set-State 'stop.mode' 'ignore'
        Assert-False (Stop-VM -VMName 'svc' -ShutdownTimeoutSeconds 1 -NoForce -Confirm:$false)
        Assert-StringEqual 'running' (Get-VMState -VMName 'svc')
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc --request' }).Count
        Assert-Equal 0 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc' -or $_ -like '*--kill*' }).Count
    }

    It 'Stop-VMForce is bounded by -StopTimeoutSeconds and trusts only a clean answer' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started'
        Assert-True (Stop-VMForce -VMName 'svc' -Confirm:$false) 'a clean kill'
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc --kill' }).Count
        Set-State 'stop.mode' 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert-False (Stop-VMForce -VMName 'svc' -StopTimeoutSeconds 1 -Confirm:$false -WarningAction SilentlyContinue)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Set-State 'stop.mode' 'deny'
        Assert-False (Stop-VMForce -VMName 'svc' -Confirm:$false) 'a denial at exit 0 is not a kill'
    }

    It 'Stop-VMForce spends only a short slice of its cap on the dialog-watchdog stop' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'svc' -Status 'started'
        # A recorded watchdog whose identity read never answers, and a kill
        # that never returns: each would take its whole allowance.
        $paths = Invoke-InDriver { @($script:WatchdogPidFile, $script:WatchdogScriptPath) }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 800 -Name 'osascript' -Command "/usr/bin/osascript $($paths[1])"
        [IO.File]::WriteAllText($paths[0], "800`n")
        Set-State 'ps.mode' 'hang'
        Set-State 'stop.mode' 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert-False (Stop-VMForce -VMName 'svc' -StopTimeoutSeconds 4 -Confirm:$false -WarningAction SilentlyContinue)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 5.5) "one allowance for the whole call ($($sw.Elapsed.TotalSeconds) s)"
        Assert-Equal 1 (Get-Call 'utmctl' | Where-Object { $_ -eq 'utmctl stop svc --kill' }).Count -Because 'the kill is still attempted'
        Assert-Equal 0 (Get-Call 'kill').Count -Because 'an unverified watchdog is never signaled'
    }
}
