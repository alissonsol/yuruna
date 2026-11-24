<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4255e922-6e0f-46be-9842-6fd1970b1543
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update shim pester
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
    The host controller's sh shim: what it does on each controller exit,
    its backoff, the rejection of a snapshot that never starts, the choice
    of a snapshot when current cannot be used, and a stop passed on to the
    controller.
.DESCRIPTION
    The shim is the one layer no host update replaces, so a wrong rule here
    stays on a host until an operator runs Enable-TestAutomation again. Each
    case copies the real shim into a scratch controller root and runs it as
    `sh <root>/shim`, with stand-ins on a private PATH: pwsh exits with the
    scripted codes and records its arguments, sleep and date record and
    answer at once. Only processes this suite started are signaled.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:ShimSource = Join-Path $script:RepoRoot 'test/lab/yuruna-host-controller-shim.sh'
    $script:Started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:Fixtures = [System.Collections.Generic.List[string]]::new()
    $script:Hash = '0123456789abcdef'
    $script:Previous = 'fedcba9876543210'
    $script:Other = 'aaaabbbbccccdddd'

    function New-ShimFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a scratch controller root and stand-ins.')]
        param(
            [string[]]$Plan = @(),
            [string[]]$DatePlan = @('1000'),
            [string]$Current = '',
            [string]$Previous = '',
            [string]$Checkout = '/srv/checkout',
            [string[]]$Snapshot = @(),
            [string[]]$WithOk = @(),
            [string[]]$Rejected = @(),
            [switch]$NoCurrentFile,
            [string]$CurrentText,
            [string]$System = 'Linux'
        )
        $base = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N').Substring(0, 10))
        $root = Join-Path $base 'host controller'
        $bin = Join-Path $base 'bin'
        $rec = Join-Path $base 'rec'
        foreach ($dir in @($root, $bin, $rec, (Join-Path $root 'versions'))) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $script:Fixtures.Add($base)
        foreach ($snap in $Snapshot) { $null = New-Item -ItemType Directory -Path (Join-Path $root "versions/$snap/test/lab") -Force }
        foreach ($snap in $WithOk) { Set-Content -LiteralPath (Join-Path $root "versions/$snap/ok") -Value 'ok' -NoNewline }
        if ($Rejected.Count -gt 0) { [System.IO.File]::WriteAllText((Join-Path $root 'rejected'), (($Rejected | ForEach-Object { "$_`n" }) -join '')) }
        if ($CurrentText) { [System.IO.File]::WriteAllText((Join-Path $root 'current'), $CurrentText) }
        elseif (-not $NoCurrentFile) { [System.IO.File]::WriteAllText((Join-Path $root 'current'), "current=$Current`nprevious=$Previous`ncheckout=$Checkout`n") }
        Copy-Item -LiteralPath $script:ShimSource -Destination (Join-Path $root 'shim')
        [System.IO.File]::WriteAllText((Join-Path $rec 'pwsh.plan'), (($Plan | ForEach-Object { "$_`n" }) -join ''))
        [System.IO.File]::WriteAllText((Join-Path $rec 'date.plan'), (($DatePlan | ForEach-Object { "$_`n" }) -join ''))
        $pwsh = @'
#!/bin/sh
REC='@REC@'
printf '%s\n' "$*" >> "$REC/pwsh.argv"
n=$(cat "$REC/pwsh.count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$REC/pwsh.count"
line=$(sed -n "${n}p" "$REC/pwsh.plan")
snap=
root=
while [ $# -gt 0 ]; do
    case $1 in
        -Snapshot) snap=$2; shift ;;
        -ControllerRoot) root=$2; shift ;;
    esac
    shift
done
case " $line " in
    *" ok "*) : > "$root/versions/$snap/ok" ;;
esac
set -- $line
case $1 in
    ''|hang)
        trap 'echo term >> "$REC/pwsh.term"; exit 0' TERM
        echo "$$" > "$REC/pwsh.pid"
        while :; do /bin/sleep 0.1; done
        ;;
    ignore)
        trap 'echo term >> "$REC/pwsh.term"' TERM
        echo "$$" > "$REC/pwsh.pid"
        while :; do /bin/sleep 0.1; done
        ;;
esac
exit "$1"
'@
        $sleep = @'
#!/bin/sh
printf '%s\n' "$1" >> '@REC@/sleep.log'
/bin/sleep 0.02
exit 0
'@
        $date = @'
#!/bin/sh
REC='@REC@'
n=$(cat "$REC/date.count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$REC/date.count"
value=$(sed -n "${n}p" "$REC/date.plan")
if [ -z "$value" ]; then value=$(tail -n 1 "$REC/date.plan"); fi
printf '%s\n' "$value"
'@
        # The shim's macOS rule reads uname: every case names the system it
        # stands for, whatever system runs the suite.
        $uname = @'
#!/bin/sh
printf '%s\n' '@SYSTEM@'
'@
        foreach ($tool in @(@{ Name = 'pwsh'; Body = $pwsh }, @{ Name = 'sleep'; Body = $sleep }, @{ Name = 'date'; Body = $date }, @{ Name = 'uname'; Body = $uname })) {
            $path = Join-Path $bin $tool.Name
            [System.IO.File]::WriteAllText($path, $tool.Body.Replace('@REC@', $rec).Replace('@SYSTEM@', $System).Replace("`r`n", "`n"))
            & chmod 755 $path
        }
        [pscustomobject]@{ Root = $root; Bin = $bin; Rec = $rec; Process = $null; StdErr = $null }
    }

    function Start-Shim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts the shim under test in a scratch root.')]
        param([Parameter(Mandatory)]$Fixture)
        $info = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
        $info.ArgumentList.Add((Join-Path $Fixture.Root 'shim'))
        $info.UseShellExecute = $false
        $info.RedirectStandardError = $true
        $info.RedirectStandardOutput = $true
        $info.Environment['PATH'] = "$($Fixture.Bin):/usr/bin:/bin"
        $process = [System.Diagnostics.Process]::Start($info)
        $script:Started.Add($process)
        $Fixture.Process = $process
        $Fixture.StdErr = $process.StandardError.ReadToEndAsync()
        $null = $process.StandardOutput.ReadToEndAsync()
        $Fixture
    }

    function Get-RecordLine {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name)
        $path = Join-Path $Fixture.Rec $Name
        if (-not (Test-Path -LiteralPath $path)) { return , [string[]]@() }
        , [string[]]@(Get-Content -LiteralPath $path | Where-Object { $_ -ne '' })
    }

    function Wait-ShimCondition {
        param([Parameter(Mandatory)][scriptblock]$Condition, [int]$TimeoutSeconds = 20)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (& $Condition) { return $true }
            Start-Sleep -Milliseconds 50
        }
        return [bool](& $Condition)
    }

    function Stop-Shim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: signals only the shim this suite started.')]
        param([Parameter(Mandatory)]$Fixture)
        $process = $Fixture.Process
        if (-not $process.HasExited) { & /bin/kill -TERM $process.Id }
        $exited = $process.WaitForExit(40000)
        Assert-True $exited 'the shim ends after a stop signal'
        $process.ExitCode
    }

    function Get-SnapshotStarted {
        param([Parameter(Mandatory)]$Fixture)
        $lines = Get-RecordLine -Fixture $Fixture -Name 'pwsh.argv'
        , [string[]]@($lines | ForEach-Object { [regex]::Match($_, '-Snapshot ([0-9a-f]{16})').Groups[1].Value })
    }
}

AfterAll {
    foreach ($process in $script:Started) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { $null = $_ }
    }
    # A stand-in controller outlives its shim when a case fails before its
    # stop; it records its pid, and is ended only while its command line
    # still names this suite's fixture.
    foreach ($base in $script:Fixtures) {
        $pidFile = Join-Path $base 'rec/pwsh.pid'
        $standIn = 0
        if (-not (Test-Path -LiteralPath $pidFile) -or -not [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$standIn)) { continue }
        $process = Get-Process -Id $standIn -ErrorAction SilentlyContinue
        if ($process -and [string]$process.CommandLine -like "*$base*") {
            try { Stop-Process -Id $standIn -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
}

Describe 'the host controller shim' -Skip:$IsWindows {
    It 'starts the current snapshot again at once on 75' {
        $fixture = New-ShimFixture -Plan @('75', '75') -Current $script:Hash -Snapshot @($script:Hash) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'three controller starts'
        $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        Assert-Equal -Expected 0 -Actual (Stop-Shim -Fixture $fixture)
        Assert-Equal -Expected "$($script:Hash),$($script:Hash),$($script:Hash)" -Actual ((Get-SnapshotStarted -Fixture $fixture) -join ',')
        Assert-Equal -Expected 0 -Actual $waits.Count 'no wait between starts after 75'
        $argv = (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv')[0]
        Assert-Match -Pattern '^-NoLogo -NoProfile -NonInteractive -File .*/versions/0123456789abcdef/test/lab/Invoke-HostUpdateController\.ps1 -ControllerRoot .* -Snapshot 0123456789abcdef -Checkout /srv/checkout$' -Actual $argv
    }

    It 'waits 30 s on 76 without counting a death' {
        $fixture = New-ShimFixture -Plan @('76', '76', '76', '76') -Current $script:Hash -Snapshot @($script:Hash) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'five controller starts'
        $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected '30,30,30,30' -Actual ($waits -join ',')
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'rejected')) 'four 76 exits without ok reject nothing'
        Assert-Equal -Expected 5 -Actual @((Get-SnapshotStarted -Fixture $fixture) | Where-Object { $_ -eq $script:Hash }).Count
    }

    It 'backs off 10, 20, 40, 60, 60 and resets after a five-minute run' {
        $fixture = New-ShimFixture -Plan @('1 ok', '1', '1', '1', '1', '1') -Current $script:Hash -Snapshot @($script:Hash) `
            -DatePlan @('1000', '1001', '1002', '1003', '1004', '1005', '1006', '1007', '1008', '1009', '1010', '1310') | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'seven controller starts'
        $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected 7 -Actual (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count
        Assert-Equal -Expected '10,20,40,60,60,10' -Actual ($waits -join ',')
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'rejected')) 'a snapshot that created ok is never rejected'
    }

    It 'rejects a snapshot after three deaths without ok and returns to previous' {
        $fixture = New-ShimFixture -Plan @('1', '1', '1') -Current $script:Hash -Previous $script:Previous -Snapshot @($script:Hash, $script:Previous) `
            -WithOk @($script:Previous) -DatePlan @('1000') | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'a fourth start after the rejection'
        $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected "$($script:Hash),$($script:Hash),$($script:Hash),$($script:Previous)" -Actual ((Get-SnapshotStarted -Fixture $fixture) -join ',')
        Assert-Equal -Expected $script:Hash -Actual ((Get-Content -LiteralPath (Join-Path $fixture.Root 'rejected')) -join ',')
        $current = Get-Content -LiteralPath (Join-Path $fixture.Root 'current')
        Assert-Equal -Expected "current=$($script:Previous)" -Actual $current[0]
        Assert-Equal -Expected 'checkout=/srv/checkout' -Actual $current[2]
        Assert-Equal -Expected '10,20,40' -Actual ($waits -join ',')
        Assert-Match -Pattern 'rejected, back to fedcba9876543210' -Actual $fixture.StdErr.Result
    }

    It 'does not restart a rejected first snapshot: <Case>' -ForEach @(
        @{ Case = 'no other snapshot waits 60 s'; Other = $false }
        @{ Case = 'another snapshot with ok starts'; Other = $true }
    ) {
        $snapshots = @($script:Hash); $ok = @()
        if ($Other) { $snapshots += $script:Other; $ok += $script:Other }
        $fixture = New-ShimFixture -Plan @('1', '1', '1') -Current $script:Hash -Previous '' -Snapshot $snapshots -WithOk $ok | ForEach-Object { Start-Shim -Fixture $_ }
        if ($Other) {
            Assert-True (Wait-ShimCondition { (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count -ge 4 }) 'the other snapshot starts'
        } else {
            Assert-True (Wait-ShimCondition { (Get-RecordLine -Fixture $fixture -Name 'sleep.log') -contains '60' }) 'the shim waits 60 s'
        }
        $null = Stop-Shim -Fixture $fixture
        $started = Get-SnapshotStarted -Fixture $fixture
        Assert-Equal -Expected 3 -Actual @($started | Where-Object { $_ -eq $script:Hash }).Count 'the rejected snapshot never starts a fourth time'
        if ($Other) { Assert-Equal -Expected $script:Other -Actual $started[3] } else { Assert-Equal -Expected 3 -Actual $started.Count }
        Assert-Equal -Expected 'current=' -Actual (Get-Content -LiteralPath (Join-Path $fixture.Root 'current'))[0]
        Assert-Equal -Expected $script:Hash -Actual ((Get-Content -LiteralPath (Join-Path $fixture.Root 'rejected')) -join ',')
    }

    It 'skips a current that is listed in rejected' {
        $fixture = New-ShimFixture -Plan @() -Current $script:Hash -Snapshot @($script:Hash, $script:Other) -WithOk @($script:Hash, $script:Other) `
            -Rejected @($script:Hash) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'a controller starts'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected $script:Other -Actual ((Get-SnapshotStarted -Fixture $fixture) -join ',')
    }

    It 'starts the newest snapshot with ok when current is unreadable' {
        $fixture = New-ShimFixture -Plan @() -CurrentText "current=not-a-hash`nprevious=`ncheckout=/srv/checkout`n" -Snapshot @($script:Hash, $script:Other, $script:Previous) `
            -WithOk @($script:Hash, $script:Other)
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $fixture.Root "versions/$($script:Hash)/ok"), [DateTime]::UtcNow.AddMinutes(-10))
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $fixture.Root "versions/$($script:Other)/ok"), [DateTime]::UtcNow.AddMinutes(-1))
        $null = Start-Shim -Fixture $fixture
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'a controller starts'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected $script:Other -Actual ((Get-SnapshotStarted -Fixture $fixture) -join ',') 'the newest ok wins; a snapshot without ok is never a fallback'
    }

    It 'waits 60 s when no snapshot has ok' {
        $fixture = New-ShimFixture -Plan @() -Current $script:Hash -Snapshot @($script:Other) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { (Get-RecordLine -Fixture $fixture -Name 'sleep.log').Count -ge 2 }) 'the shim waits and looks again'
        Assert-Equal -Expected 0 -Actual (Stop-Shim -Fixture $fixture)
        Assert-Equal -Expected 0 -Actual (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count 'no controller starts'
        Assert-True (@(Get-RecordLine -Fixture $fixture -Name 'sleep.log' | Where-Object { $_ -ne '60' }).Count -eq 0) 'every wait is 60 s'
    }

    It 'forwards TERM to the controller and waits at most 30 s: <Case>' -ForEach @(
        @{ Case = 'a controller that ends'; Mode = 'hang' }
        @{ Case = 'a controller that ignores the stop'; Mode = 'ignore' }
    ) {
        $fixture = New-ShimFixture -Plan @($Mode) -Current $script:Hash -Snapshot @($script:Hash) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'the controller runs'
        $controller = [int](Get-Content -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') -Raw).Trim()
        $before = (Get-RecordLine -Fixture $fixture -Name 'sleep.log').Count
        Assert-Equal -Expected 0 -Actual (Stop-Shim -Fixture $fixture)
        Assert-True (Wait-ShimCondition { (Get-RecordLine -Fixture $fixture -Name 'pwsh.term').Count -ge 1 } -TimeoutSeconds 5) 'the controller got TERM'
        $all = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        $waits = @($all | Select-Object -Skip $before)
        if ($Mode -eq 'ignore') {
            try {
                Assert-Equal -Expected 30 -Actual $waits.Count 'thirty one-second polls, then the shim leaves it'
                Assert-True (@($waits | Where-Object { $_ -ne '1' }).Count -eq 0) 'each poll is one second'
                Assert-NotNull (Get-Process -Id $controller -ErrorAction SilentlyContinue) 'the shim never kills the controller'
            } finally {
                Stop-Process -Id $controller -Force -ErrorAction SilentlyContinue
            }
        } else {
            Assert-True ($waits.Count -lt 30) 'a controller that ends is not waited for longer'
        }
    }

    It 'exits on a 76 from the first controller it started on macOS, and only then' -ForEach @(
        @{ Case = 'first start on macOS'; System = 'Darwin'; Plan = @('76'); Exits = $true }
        @{ Case = 'a later start on macOS'; System = 'Darwin'; Plan = @('1 ok', '76', '76'); Exits = $false }
        @{ Case = 'first start on Linux'; System = 'Linux'; Plan = @('76', '76'); Exits = $false }
    ) {
        $fixture = New-ShimFixture -Plan $Plan -Current $script:Hash -Snapshot @($script:Hash) -System $System | ForEach-Object { Start-Shim -Fixture $_ }
        if ($Exits) {
            Assert-True ($fixture.Process.WaitForExit(20000)) 'the shim ends by itself'
            Assert-Equal -Expected 0 -Actual $fixture.Process.ExitCode
            Assert-Equal -Expected 1 -Actual (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count 'no second controller is started'
            Assert-Equal -Expected 0 -Actual (Get-RecordLine -Fixture $fixture -Name 'sleep.log').Count 'no wait before it ends'
            Assert-Match -Pattern 'first start; leaving it to the shim that owns it' -Actual $fixture.StdErr.Result
        } else {
            Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'the shim starts a controller again after the 76'
            $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
            Assert-Equal -Expected 0 -Actual (Stop-Shim -Fixture $fixture)
            Assert-True ($waits -contains '30') 'a 76 waits 30 s'
            Assert-Equal -Expected ($Plan.Count + 1) -Actual (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count
        }
    }

    It 'treats 77 like any other exit' {
        $fixture = New-ShimFixture -Plan @('77') -Current $script:Hash -Snapshot @($script:Hash) | ForEach-Object { Start-Shim -Fixture $_ }
        Assert-True (Wait-ShimCondition { Test-Path -LiteralPath (Join-Path $fixture.Rec 'pwsh.pid') }) 'the controller starts again'
        $waits = Get-RecordLine -Fixture $fixture -Name 'sleep.log'
        $null = Stop-Shim -Fixture $fixture
        Assert-Equal -Expected 2 -Actual (Get-RecordLine -Fixture $fixture -Name 'pwsh.argv').Count
        Assert-Equal -Expected '10' -Actual ($waits -join ',') 'the ordinary 10 s backoff'
        Assert-Match -Pattern 'exited with 77' -Actual $fixture.StdErr.Result
    }
}

# The Windows shim runs under Windows PowerShell on a host, and every rule it
# keeps is plain PowerShell, so it is driven here on any platform: each case
# dot-sources the real shim in a child pwsh, replaces its pause and its clock
# with recorders, and starts a stand-in controller at the snapshot's path that
# exits with the scripted codes. The stand-in raises the stop file when its
# plan runs out, which is how each case ends.
Describe 'the Windows host controller shim' {
    BeforeAll {
        $script:WindowsShim = Join-Path $script:RepoRoot 'test/lab/yuruna-host-controller-shim.ps1'
        $script:Pwsh = (Get-Process -Id $PID).Path

        function New-WindowsShimFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a scratch controller root and a stand-in controller.')]
            param(
                [string[]]$Plan = @(),
                [long[]]$EpochPlan = @(1000),
                [string]$Current = '',
                [string]$Previous = '',
                [string[]]$Snapshot = @(),
                [string[]]$WithOk = @(),
                [string[]]$Rejected = @(),
                [switch]$NoCurrentFile,
                [string]$CurrentText,
                [string]$UpgradeRequest = ''
            )
            $base = Join-Path $TestDrive ('w' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
            $root = Join-Path $base 'host controller'
            $rec = Join-Path $base 'rec'
            $upgrade = Join-Path $base 'programdata'
            foreach ($dir in @($root, $rec, $upgrade, (Join-Path $root 'versions'))) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $script:Fixtures.Add($base)
            $standIn = @'
param([string]$ControllerRoot, [string]$Snapshot, [string]$Checkout)
$rec = Join-Path (Split-Path -Parent $ControllerRoot) 'rec'
Add-Content -LiteralPath (Join-Path $rec 'controller.argv') -Value "$Snapshot|$Checkout|$env:YURUNA_HOST_CONTROLLER_LOG"
$count = 0
$countPath = Join-Path $rec 'controller.count'
if (Test-Path -LiteralPath $countPath) { $count = [int](Get-Content -LiteralPath $countPath -Raw) }
$count++
Set-Content -LiteralPath $countPath -Value $count -NoNewline
$plan = @(Get-Content -LiteralPath (Join-Path $rec 'controller.plan'))
if ($count -gt $plan.Count) { Set-Content -LiteralPath (Join-Path $ControllerRoot 'stop') -Value ''; exit 0 }
$step = $plan[$count - 1].Split(' ')
if ($step -contains 'ok') { Set-Content -LiteralPath (Join-Path $ControllerRoot "versions/$Snapshot/ok") -Value 'ok' }
if ($step[0] -eq 'hang') {
    Set-Content -LiteralPath (Join-Path $rec 'controller.pid') -Value $PID -NoNewline
    Set-Content -LiteralPath (Join-Path $ControllerRoot 'stop') -Value ''
    while ($true) { Start-Sleep -Milliseconds 100 }
}
exit ([int]$step[0])
'@
            foreach ($snap in $Snapshot) {
                $lab = Join-Path $root "versions/$snap/test/lab"
                $null = New-Item -ItemType Directory -Path $lab -Force
                [System.IO.File]::WriteAllText((Join-Path $lab 'Invoke-HostUpdateController.ps1'), $standIn)
            }
            foreach ($snap in $WithOk) { Set-Content -LiteralPath (Join-Path $root "versions/$snap/ok") -Value 'ok' -NoNewline }
            if ($Rejected.Count -gt 0) { [System.IO.File]::WriteAllText((Join-Path $root 'rejected'), (($Rejected | ForEach-Object { "$_`n" }) -join '')) }
            if ($CurrentText) { [System.IO.File]::WriteAllText((Join-Path $root 'current'), $CurrentText) }
            elseif (-not $NoCurrentFile) { [System.IO.File]::WriteAllText((Join-Path $root 'current'), "current=$Current`nprevious=$Previous`ncheckout=C:\srv\checkout`n") }
            if ($UpgradeRequest) { [System.IO.File]::WriteAllText((Join-Path $root 'pwsh-upgrade.request'), $UpgradeRequest.Replace('@UPGRADE@', $upgrade)) }
            [System.IO.File]::WriteAllText((Join-Path $rec 'controller.plan'), (($Plan | ForEach-Object { "$_`n" }) -join ''))
            [System.IO.File]::WriteAllText((Join-Path $rec 'epoch.plan'), (($EpochPlan | ForEach-Object { "$_`n" }) -join ''))
            $installer = @'
param([switch]$Unattended, [switch]$UpgradePowerShell)
Add-Content -LiteralPath '@REC@/upgrade.argv' -Value "$Unattended|$UpgradePowerShell"
exit 3
'@
            [System.IO.File]::WriteAllText((Join-Path $upgrade 'windows.hyper-v.ps1'), $installer.Replace('@REC@', $rec))
            return [pscustomobject]@{ Base = $base; Root = $root; Rec = $rec; Upgrade = $upgrade }
        }

        function Invoke-WindowsShim {
            param([Parameter(Mandatory)]$Fixture)
            $driver = @'
. '@SHIM@' -ControllerRoot '@ROOT@' -PwshPath '@PWSH@' -WindowsPowerShellPath '@PWSH@' -UpgradeRoot '@UPGRADE@'
$script:EpochIndex = 0
# Records each wait the shim makes, and raises the stop file at the eighth,
# so a rule that would wait forever still ends the case.
function Wait-ShimPause {
    param([int]$Seconds)
    if (Test-ShimStop) { return $true }
    Add-Content -LiteralPath '@REC@/pause.log' -Value $Seconds
    if (@(Get-Content -LiteralPath '@REC@/pause.log').Count -ge 8) { Set-Content -LiteralPath (Join-Path $script:Root 'stop') -Value '' }
    return $false
}
function Get-ShimEpoch {
    $plan = @(Get-Content -LiteralPath '@REC@/epoch.plan')
    $value = if ($script:EpochIndex -lt $plan.Count) { $plan[$script:EpochIndex] } else { $plan[-1] }
    $script:EpochIndex++
    return [long]$value
}
Invoke-Shim
'@
            $text = $driver.Replace('@SHIM@', $script:WindowsShim.Replace("'", "''")).Replace('@ROOT@', $Fixture.Root.Replace("'", "''")).Replace('@PWSH@', $script:Pwsh)
            $text = $text.Replace('@UPGRADE@', $Fixture.Upgrade).Replace('@REC@', $Fixture.Rec)
            $path = Join-Path $Fixture.Base 'driver.ps1'
            [System.IO.File]::WriteAllText($path, $text)
            $info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $path)) { $info.ArgumentList.Add($a) }
            $info.UseShellExecute = $false
            $info.RedirectStandardError = $true
            $info.RedirectStandardOutput = $true
            $process = [System.Diagnostics.Process]::Start($info)
            $script:Started.Add($process)
            $err = $process.StandardError.ReadToEndAsync()
            $null = $process.StandardOutput.ReadToEndAsync()
            Assert-True ($process.WaitForExit(120000)) 'the shim ends once its stand-in raises the stop file'
            return [pscustomobject]@{ ExitCode = $process.ExitCode; StdErr = $err.Result }
        }

        function Get-WindowsShimRecord {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name)
            $path = Join-Path $Fixture.Rec $Name
            if (-not (Test-Path -LiteralPath $path)) { return , [string[]]@() }
            , [string[]]@(Get-Content -LiteralPath $path | Where-Object { $_ -ne '' })
        }

        function Get-WindowsShimStarted {
            param([Parameter(Mandatory)]$Fixture)
            $lines = Get-WindowsShimRecord -Fixture $Fixture -Name 'controller.argv'
            , [string[]]@(foreach ($line in $lines) { $line.Split('|')[0] })
        }

        function Get-WindowsShimLog {
            param([Parameter(Mandatory)]$Fixture)
            $path = Join-Path $Fixture.Root 'shim.log'
            if (-not (Test-Path -LiteralPath $path)) { return '' }
            return [System.IO.File]::ReadAllText($path)
        }
    }

    It 'stays 7-bit ASCII and uses nothing PowerShell 7 added' {
        $bytes = [System.IO.File]::ReadAllBytes($script:WindowsShim)
        Assert-Equal -Expected 0 -Actual @($bytes | Where-Object { $_ -gt 127 }).Count 'Windows PowerShell reads a file without a BOM as ANSI'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WindowsShim, [ref]$tokens, [ref]$errors)
        Assert-Equal -Expected 0 -Actual @($errors).Count
        $seven = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] -or $n -is [System.Management.Automation.Language.PipelineChainAst] -or
                    ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($n.Operator)" -eq 'QuestionQuestion') }, $true))
        Assert-Equal -Expected 0 -Actual $seven.Count 'no ternary, pipeline chain or null-coalescing operator'
        Assert-False ((Get-Content -LiteralPath $script:WindowsShim -Raw) -match '#requires\s+-version\s+7') 'no requirement of PowerShell 7'
    }

    It 'starts the current snapshot again at once on 75, and names the controller log' {
        $fixture = New-WindowsShimFixture -Plan @('75', '75') -Current $script:Hash -Snapshot @($script:Hash)
        $run = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.ExitCode $run.StdErr
        Assert-Equal -Expected "$($script:Hash),$($script:Hash),$($script:Hash)" -Actual ((Get-WindowsShimStarted -Fixture $fixture) -join ',')
        Assert-Equal -Expected 0 -Actual (Get-WindowsShimRecord -Fixture $fixture -Name 'pause.log').Count 'no pause between starts after 75'
        $first = (Get-WindowsShimRecord -Fixture $fixture -Name 'controller.argv')[0].Split('|')
        Assert-Equal -Expected 'C:\srv\checkout' -Actual $first[1] 'the checkout reaches the controller as one argument'
        Assert-Equal -Expected (Join-Path $fixture.Root 'controller.log') -Actual $first[2]
    }

    It 'waits 30 s on 76 without counting a death' {
        $fixture = New-WindowsShimFixture -Plan @('76', '76', '76', '76') -Current $script:Hash -Snapshot @($script:Hash)
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected '30,30,30,30' -Actual ((Get-WindowsShimRecord -Fixture $fixture -Name 'pause.log') -join ',')
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'rejected')) 'four 76 exits without ok reject nothing'
    }

    It 'backs off 10, 20, 40, 60, 60 and resets after a five-minute run' {
        $fixture = New-WindowsShimFixture -Plan @('1 ok', '1', '1', '1', '1', '1') -Current $script:Hash -Snapshot @($script:Hash) `
            -EpochPlan @(1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1310)
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected 7 -Actual (Get-WindowsShimStarted -Fixture $fixture).Count
        Assert-Equal -Expected '10,20,40,60,60,10' -Actual ((Get-WindowsShimRecord -Fixture $fixture -Name 'pause.log') -join ',')
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'rejected')) 'a snapshot that created ok is never rejected'
    }

    It 'rejects a snapshot after three deaths without ok and returns to previous' {
        $fixture = New-WindowsShimFixture -Plan @('1', '1', '1') -Current $script:Hash -Previous $script:Previous -Snapshot @($script:Hash, $script:Previous) -WithOk @($script:Previous)
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected "$($script:Hash),$($script:Hash),$($script:Hash),$($script:Previous)" -Actual ((Get-WindowsShimStarted -Fixture $fixture) -join ',')
        Assert-Equal -Expected $script:Hash -Actual ((Get-Content -LiteralPath (Join-Path $fixture.Root 'rejected')) -join ',')
        $current = Get-Content -LiteralPath (Join-Path $fixture.Root 'current')
        Assert-Equal -Expected "current=$($script:Previous)" -Actual $current[0]
        Assert-Equal -Expected 'checkout=C:\srv\checkout' -Actual $current[2]
        Assert-Match -Pattern 'rejected, back to fedcba9876543210' -Actual (Get-WindowsShimLog -Fixture $fixture)
    }

    It 'skips a rejected current and starts the newest snapshot with ok' {
        $fixture = New-WindowsShimFixture -Plan @('75') -Current $script:Hash -Snapshot @($script:Hash, $script:Other) -WithOk @($script:Hash, $script:Other) -Rejected @($script:Hash)
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected $script:Other -Actual (Get-WindowsShimStarted -Fixture $fixture)[0]
    }

    It 'starts the newest snapshot with ok when current is unreadable' {
        $fixture = New-WindowsShimFixture -Plan @('75') -CurrentText "current=not-a-hash`ncheckout=C:\srv\checkout`n" -Snapshot @($script:Hash, $script:Other) -WithOk @($script:Other)
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected "$($script:Other),$($script:Other)" -Actual ((Get-WindowsShimStarted -Fixture $fixture) -join ',')
        Assert-Match -Pattern 'current snapshot unusable; starting aaaabbbbccccdddd' -Actual (Get-WindowsShimLog -Fixture $fixture)
    }

    It 'waits 60 s when <Case>' -ForEach @(
        @{ Case = 'no snapshot has ok'; NoCurrent = $false; Log = 'no snapshot to start' }
        @{ Case = 'no checkout is recorded'; NoCurrent = $true; Log = 'no checkout recorded' }
    ) {
        $fixture = if ($NoCurrent) { New-WindowsShimFixture -NoCurrentFile -Snapshot @($script:Hash) -WithOk @($script:Hash) }
        else { New-WindowsShimFixture -Current $script:Hash -Snapshot @($script:Hash) -Rejected @($script:Hash) }
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected 0 -Actual (Get-WindowsShimStarted -Fixture $fixture).Count 'nothing starts'
        Assert-Equal -Expected '60,60,60,60,60,60,60,60' -Actual ((Get-WindowsShimRecord -Fixture $fixture -Name 'pause.log') -join ',')
        Assert-Match -Pattern $Log -Actual (Get-WindowsShimLog -Fixture $fixture)
    }

    It 'honors a stop asked before the first start' {
        $fixture = New-WindowsShimFixture -Plan @('75') -Current $script:Hash -Snapshot @($script:Hash)
        Set-Content -LiteralPath (Join-Path $fixture.Root 'stop') -Value ''
        $null = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected 0 -Actual (Get-WindowsShimStarted -Fixture $fixture).Count
    }

    It 'ends a running controller alone on a stop and exits' {
        $fixture = New-WindowsShimFixture -Plan @('hang') -Current $script:Hash -Snapshot @($script:Hash)
        $run = Invoke-WindowsShim -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.ExitCode $run.StdErr
        $controller = [int](Get-Content -LiteralPath (Join-Path $fixture.Rec 'controller.pid') -Raw).Trim()
        Assert-True ($null -eq (Get-Process -Id $controller -ErrorAction SilentlyContinue)) 'the controller was ended'
        Assert-Match -Pattern 'stop: ending controller' -Actual (Get-WindowsShimLog -Fixture $fixture)
    }

    It 'runs the requested upgrade on 77 and starts the controller at once: <Case>' -ForEach @(
        @{ Case = 'an installer in the upgrade root'; Request = '@UPGRADE@/windows.hyper-v.ps1'; Reason = 'failed'; Ran = $true }
        @{ Case = 'an installer outside it'; Request = '/tmp/elsewhere/windows.hyper-v.ps1'; Reason = 'installer_refused'; Ran = $false }
        @{ Case = 'no request'; Request = ''; Reason = 'request_missing'; Ran = $false }
    ) {
        $fixture = New-WindowsShimFixture -Plan @('77', '75') -Current $script:Hash -Snapshot @($script:Hash) -UpgradeRequest $Request
        $null = Invoke-WindowsShim -Fixture $fixture
        $result = Get-Content -LiteralPath (Join-Path $fixture.Root 'pwsh-upgrade.result') -Raw | ConvertFrom-Json
        Assert-Equal -Expected $Reason -Actual $result.reason
        Assert-Equal -Expected $Ran -Actual ((Get-WindowsShimRecord -Fixture $fixture -Name 'upgrade.argv').Count -eq 1)
        if ($Ran) {
            Assert-Equal -Expected 'True|True' -Actual (Get-WindowsShimRecord -Fixture $fixture -Name 'upgrade.argv')[0] 'the installer runs -Unattended -UpgradePowerShell'
            Assert-Equal -Expected 3 -Actual $result.exitCode
        }
        Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Root 'pwsh-upgrade.request')) 'the request is used once'
        Assert-Equal -Expected 3 -Actual (Get-WindowsShimStarted -Fixture $fixture).Count 'the controller starts again after the upgrade, whatever it did'
        Assert-Equal -Expected 0 -Actual (Get-WindowsShimRecord -Fixture $fixture -Name 'pause.log').Count 'no backoff after 77'
    }
}
