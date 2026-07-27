<#PSScriptInfo
.VERSION 2026.07.26
.GUID 4258d7b3-f0cd-4067-93af-fd6942a23808
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host clock ntp pester
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
    Guard: a host whose clock is not disciplined must be refused a cycle on
    every host type, the skew it is judged on must be measured correctly,
    and the runner must try to fix it where fixing is safe.
.DESCRIPTION
    Every hypervisor here seeds a guest's clock from the host at power-on.
    A host that has drifted therefore starts every VM equally wrong, and
    the guest's own NTP client steps it to real time seconds into the boot
    -- landing in the middle of whatever that guest is bringing up. A
    Kubernetes guest survives the step looking healthy from every angle
    except the one that matters: pods Running but never Ready, Services
    with no endpoints, every NodePort refusing, while a curl straight at
    the pod IP answers 200. The cost of missing it is a whole cycle spent
    before anything suspects the clock.

    The arithmetic is tested for real against a local NTP responder --
    NTP's 1900 epoch and big-endian timestamps are exactly the kind of
    thing that inverts silently and reports a healthy zero. The wiring
    (three gates, three sync paths, the runner's cycle-boundary attempt)
    is tested at the source level: exercising it needs three hosts, root
    on each, and a drifted clock, and what it protects against is a check
    being dropped.
    Run: Invoke-Pester -Path test/modules/Test.HostClockSkew.Tests.ps1
#>

$here      = Split-Path -Parent $PSCommandPath
$sharedFile = Join-Path $here 'Test.HostCondition.psm1'
$hostFiles  = [ordered]@{
    'host.windows.hyper-v' = Join-Path $here 'Test.HostCondition.Windows.psm1'
    'host.macos.utm'       = Join-Path $here 'Test.HostCondition.Mac.psm1'
    'host.ubuntu.kvm'      = Join-Path $here 'Test.HostCondition.Linux.psm1'
}
$assertFn = @{
    'host.windows.hyper-v' = 'Assert-WindowsHostConditionSet'
    'host.macos.utm'       = 'Assert-MacHostConditionSet'
    'host.ubuntu.kvm'      = 'Assert-LinuxHostConditionSet'
}
$syncFn = @{
    'host.windows.hyper-v' = 'Sync-WindowsHostClock'
    'host.macos.utm'       = 'Sync-MacHostClock'
    'host.ubuntu.kvm'      = 'Sync-LinuxHostClock'
}
$outerLoopFile = Join-Path $here 'Test.RunnerOuterLoop.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $sharedFile -Force -DisableNameChecking

# Parse once per file; the tests read function bodies out of the AST so
# comments and strings can never be mistaken for calls.
$script:AstCache = @{}
function Get-FileAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Path IS used -- as the cache key and the parse target.')]
    param([string]$Path)
    if (-not $script:AstCache.ContainsKey($Path)) {
        $script:AstCache[$Path] = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }
    return $script:AstCache[$Path]
}

function Get-FunctionAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    param([string]$Path, [string]$Name)
    return (Get-FileAst -Path $Path).FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
}

# One-shot NTP responder on loopback: answers a single request with a
# transmit timestamp $OffsetSeconds BEHIND now, so a correct probe reports
# the host as that many seconds ahead.
#
# The socket is bound by the CALLER and handed in already listening
# (ThreadJob shares this process, so the live object crosses intact). A
# responder that binds inside the job races the probe, and a datagram sent
# to a not-yet-bound loopback port draws an ICMP port-unreachable that
# fails the receive instantly -- which reads exactly like "no time server
# answered" and turns this into a flaky test of the wrong thing.
function Get-FakeNtpResponderJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Both variables arrive through -ArgumentList into the job param() block; the analyzer does not follow that path.')]
    param([System.Net.Sockets.UdpClient]$Listener, [double]$OffsetSeconds)
    return Start-ThreadJob -ScriptBlock {
        param($Listener, $OffsetSeconds)
        try {
            $Listener.Client.ReceiveTimeout = 15000
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            [void]$Listener.Receive([ref]$remote)
            $reply = [byte[]]::new(48)
            $reply[0] = 0x1C   # leap 0, version 3, mode 4 (server)
            $span = ([datetime]::UtcNow.AddSeconds(-$OffsetSeconds)) - [datetime]::new(1900, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $whole = [uint32][math]::Floor($span.TotalSeconds)
            $frac  = [uint32][math]::Min(4294967295, [math]::Floor(($span.TotalSeconds - $whole) * 4294967296.0))
            $wholeBytes = [System.BitConverter]::GetBytes($whole); [array]::Reverse($wholeBytes)
            $fracBytes  = [System.BitConverter]::GetBytes($frac);  [array]::Reverse($fracBytes)
            [array]::Copy($wholeBytes, 0, $reply, 40, 4)
            [array]::Copy($fracBytes,  0, $reply, 44, 4)
            [void]$Listener.Send($reply, $reply.Length, $remote)
        } finally {
            $Listener.Dispose()
        }
    } -ArgumentList $Listener, $OffsetSeconds
}

# Bind :0 and read back the port the stack handed out.
function Get-LoopbackUdpListener {
    $listener = [System.Net.Sockets.UdpClient]::new(0)
    return @{
        Listener = $listener
        Port     = ([System.Net.IPEndPoint]$listener.Client.LocalEndPoint).Port
    }
}

Describe 'host-clock-skew measurement' {

    It 'reports a host that is ahead of the reference as a positive skew' {
        $bound = Get-LoopbackUdpListener
        $job   = Get-FakeNtpResponderJob -Listener $bound.Listener -OffsetSeconds 300
        try {
            $skew = Get-HostClockSkew -TimeServer '127.0.0.1' -Port $bound.Port -TimeoutMilliseconds 5000
            Assert-True ($null -ne $skew) 'a responding server must yield a measurement'
            # Tolerance covers the round trip and the responder's own scheduling.
            Assert-True ([math]::Abs($skew - 300) -lt 5) "expected ~+300s, got $skew"
        } finally {
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a host that is behind the reference as a negative skew' {
        $bound = Get-LoopbackUdpListener
        $job   = Get-FakeNtpResponderJob -Listener $bound.Listener -OffsetSeconds -300
        try {
            $skew = Get-HostClockSkew -TimeServer '127.0.0.1' -Port $bound.Port -TimeoutMilliseconds 5000
            Assert-True ($null -ne $skew) 'a responding server must yield a measurement'
            Assert-True ([math]::Abs($skew + 300) -lt 5) "expected ~-300s, got $skew"
        } finally {
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns nothing -- not zero -- when no time server answers' {
        # An isolated lab must read as unmeasured; a 0 here would let an
        # unreachable network pass for a disciplined clock. Bind the port
        # only to learn one nothing is listening on, then release it.
        $bound = Get-LoopbackUdpListener
        $bound.Listener.Dispose()
        $skew = Get-HostClockSkew -TimeServer '127.0.0.1' -Port $bound.Port -TimeoutMilliseconds 700
        Assert-True ($null -eq $skew) "expected null for an unanswered probe, got '$skew'"
    }

    It 'publishes the same limit the gate enforces' {
        $limit = Get-HostClockSkewLimit
        Assert-True ($limit -gt 0) 'the limit must be a positive number of seconds'
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Assert-HostClock'
        Assert-True ($fn.Extent.Text -match 'YurunaMaxHostClockSkewSeconds') `
            'the gate must default to the same constant the limit accessor returns'
    }
}

Describe 'host-clock-skew gate' {

    It 'leaves an unmeasurable clock alone rather than failing the gate' {
        # No time server is reachable on an air-gapped host; that must not
        # be the thing that stops it from running.
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Assert-HostClock'
        Assert-True ($fn.Extent.Text -match '\$null -eq \$skew') 'the gate must branch on an unmeasured clock'
        $returns = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true))
        Assert-True (@($returns | Where-Object { $_.Extent.Text -match 'return\s+\$false' }).Count -ge 1) `
            'a skewed clock must fail the gate, not just warn'
    }

    foreach ($entry in $hostFiles.GetEnumerator()) {
        $ht   = $entry.Key
        $path = $entry.Value
        It "refuses a cycle on a skewed clock: $ht" {
            $fn = Get-FunctionAst -Path $path -Name $assertFn[$ht]
            Assert-True ($null -ne $fn) "$($assertFn[$ht]) must exist"
            $calls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Assert-HostClock'
            }, $true))
            Assert-True ($calls.Count -ge 1) "$ht must consult the shared clock gate"
        }
    }
}

Describe 'host-clock-skew repair' {

    foreach ($entry in $hostFiles.GetEnumerator()) {
        $ht   = $entry.Key
        $path = $entry.Value
        It "can put its own clock back under NTP discipline: $ht" {
            $fn = Get-FunctionAst -Path $path -Name $syncFn[$ht]
            Assert-True ($null -ne $fn) "$($syncFn[$ht]) must exist"
            # Best-effort by contract: a clock fix needs privileges the
            # caller may not hold, and no caller may be left to throw.
            Assert-True ($fn.Extent.Text -match 'Succeeded') 'must report a Succeeded status rather than throwing'
        }
    }

    It 'registers every host clock-sync path with the dispatcher' {
        $ast = Get-FileAst -Path $sharedFile
        foreach ($ht in $hostFiles.Keys) {
            Assert-True ($ast.Extent.Text -match [regex]::Escape($syncFn[$ht])) `
                "$ht must register $($syncFn[$ht]) as its ClockSync capability"
        }
    }

    It 'never blocks an unattended host on a password prompt' {
        # A sudo prompt in the sync path is a hang, not a failed sync: the
        # runner calls this with no console.
        foreach ($ht in @('host.macos.utm', 'host.ubuntu.kvm')) {
            $fn = Get-FunctionAst -Path $hostFiles[$ht] -Name $syncFn[$ht]
            $sudoCalls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'sudo'
            }, $true))
            Assert-True ($sudoCalls.Count -ge 1) "$ht is expected to need sudo"
            foreach ($call in $sudoCalls) {
                Assert-True ($call.Extent.Text -match 'sudo\s+-n\b') `
                    "$ht must call sudo with -n so it can never wait on a prompt: $($call.Extent.Text)"
            }
        }
    }

    It 'tries to sync the clock at the cycle boundary, and only warns when it cannot' {
        # The per-cycle work moved into Invoke-RunnerOuterCycle so it can run in a
        # fresh process each cycle; the clock sync went with it, still ahead of the
        # spawn. Follow the code rather than pinning the function it used to live in.
        $fn = Get-FunctionAst -Path $outerLoopFile -Name 'Invoke-RunnerOuterCycle'
        Assert-True ($null -ne $fn) 'the per-cycle function must exist'
        $syncCalls = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Sync-HostClock'
        }, $true))
        Assert-True ($syncCalls.Count -ge 1) 'the outer loop must attempt a clock sync'

        # Before the spawn: correcting a drifted host STEPS its clock, and a
        # step while guests are running is the exact fault this prevents.
        # Start-Watchdog is the first call of the spawn phase, so it marks
        # the line the sync has to stay above.
        $spawn = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Start-Watchdog'
        }, $true))
        Assert-True ($spawn.Count -ge 1) 'the spawn phase must still arm the watchdog (anchor for this ordering check)'
        $spawnLine = ($spawn | Measure-Object -Property { $_.Extent.StartLineNumber } -Minimum).Minimum
        Assert-True ($syncCalls[0].Extent.StartLineNumber -lt $spawnLine) `
            'the clock sync must happen before the inner is spawned, never mid-cycle'

        # Warn-only: no `return`/`continue`/`throw` may hang off the failure.
        $enclosing = $syncCalls[0].Extent.StartLineNumber
        $aborts = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
        }, $true) | Where-Object {
            $_.Extent.StartLineNumber -ge $enclosing -and $_.Extent.StartLineNumber -le ($enclosing + 12)
        })
        Assert-True ($aborts.Count -eq 0) 'a failed clock sync must not abort the cycle'
    }
}

Describe 'host-clock-skew reporting' {

    It 'reports the clock in Test-Config and offers the fix interactively' {
        $configPath = Join-Path (Split-Path -Parent $here) 'Test-Config.ps1'
        $ast = Get-FileAst -Path $configPath
        Assert-True ($ast.Extent.Text -match 'Write-Section "Host clock"') 'Test-Config must report the host clock'
        $offer = Get-FunctionAst -Path $configPath -Name 'Invoke-HostClockSyncOffer'
        Assert-True ($null -ne $offer) 'Test-Config must offer to fix a skewed clock'
        # The offer is the operator's decision, and the unattended config
        # gate runs this same file -- so it must ask, and only when asked to
        # a console that can answer.
        Assert-True ($offer.Extent.Text -match 'Read-Host')      'the fix must be offered, not applied silently'
        Assert-True ($offer.Extent.Text -match 'UserInteractive') 'the offer must be skipped on a headless run'
    }
}
