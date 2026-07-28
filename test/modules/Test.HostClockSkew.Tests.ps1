<#PSScriptInfo
.VERSION 2026.07.28
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
    Guard: a host whose clock is not disciplined must say so on every host
    type, the skew it is judged on must be measured correctly, and the
    repair must stay where a console can authorize it.
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

    A cycle only reports it. Every platform's repair is a privileged call
    -- Administrator, or a sudo credential nobody is present to type -- so
    an unattended loop can neither perform it nor stop to ask, and a host
    that refused its own cycles over a clock would run none at all until
    someone noticed. The repair therefore lives in the operator-facing
    paths, which may ask; the cycle measures once and warns.

    The arithmetic is tested for real against a local NTP responder --
    NTP's 1900 epoch and big-endian timestamps are exactly the kind of
    thing that inverts silently and reports a healthy zero. The wiring
    (three report paths, three sync paths, what the runner must NOT do) is
    tested at the source level: exercising it needs three hosts, root on
    each, and a drifted clock, and what it protects against is a check
    being dropped or a privileged call creeping back into the loop.
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

    It 'publishes the same limit the report enforces' {
        $limit = Get-HostClockSkewLimit
        Assert-True ($limit -gt 0) 'the limit must be a positive number of seconds'
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Write-HostClockDriftWarning'
        Assert-True ($fn.Extent.Text -match 'YurunaMaxHostClockSkewSeconds') `
            'the report must default to the same constant the limit accessor returns'
    }
}

Describe 'host-clock-skew reporting on a cycle' {

    It 'says nothing about an unmeasurable clock' {
        # No time server is reachable on an air-gapped host; that is a normal
        # deployment, not a fault to repeat every cycle.
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Write-HostClockDriftWarning'
        Assert-True ($fn.Extent.Text -match '\$null -eq \$skew') 'the report must branch on an unmeasured clock'
    }

    It 'warns without refusing the cycle' {
        # The repair needs a credential the runner cannot obtain, so refusing
        # here would leave a drifted host running nothing at all.
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Write-HostClockDriftWarning'
        $returns = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true))
        Assert-True (@($returns | Where-Object { $_.Extent.Text -match 'return\s+\$(true|false)' }).Count -eq 0) `
            'the report must not hand a caller a pass/fail verdict to gate on'
        Assert-True ($fn.Extent.Text -match 'Write-Warning') 'a drifted clock must still be reported'
    }

    It 'measures at most once per cycle' {
        # A fresh process runs each cycle, and the platform Assert that calls
        # this runs more than once inside one of them. Without the memo the
        # operator reads the same paragraph twice and pays a second NTP round
        # trip for it.
        $fn = Get-FunctionAst -Path $sharedFile -Name 'Write-HostClockDriftWarning'
        Assert-True ($fn.Extent.Text -match '\$script:HostClockReported')  'the report must latch after its first run'
        Assert-True ($fn.Extent.Text -match 'if\s*\(\$script:HostClockReported\)\s*\{\s*return') `
            'the latch must short-circuit before the NTP probe, not after it'
        $ast = Get-FileAst -Path $sharedFile
        Assert-True ($ast.Extent.Text -match '\$script:HostClockReported\s*=\s*\$false') `
            'the latch must be initialized at module scope'
    }

    foreach ($entry in $hostFiles.GetEnumerator()) {
        $ht   = $entry.Key
        $path = $entry.Value
        It "reports a skewed clock once per cycle: $ht" {
            $fn = Get-FunctionAst -Path $path -Name $assertFn[$ht]
            Assert-True ($null -ne $fn) "$($assertFn[$ht]) must exist"
            $calls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Write-HostClockDriftWarning'
            }, $true))
            Assert-True ($calls.Count -ge 1) "$ht must consult the shared clock report"
            # A bare statement, never a condition: the clock must not decide
            # whether this host is allowed to run.
            foreach ($call in $calls) {
                Assert-True ($call.Parent -is [System.Management.Automation.Language.PipelineAst] -and
                             $call.Parent.Parent -is [System.Management.Automation.Language.NamedBlockAst]) `
                    "$ht must call the clock report as a statement, not gate on it: $($call.Extent.Text)"
            }
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

    It 'never syncs the clock from an unattended cycle' {
        # Every platform's sync is a privileged call. On macOS/Linux it needs
        # a sudo credential nobody is present to type, and `sudo -n` fails
        # rather than hangs -- so per-cycle it could only ever log a failure,
        # once per host, forever. The runner reports the skew instead and
        # leaves the repair to a console that can answer for it.
        $fn = Get-FunctionAst -Path $outerLoopFile -Name 'Invoke-RunnerOuterCycle'
        Assert-True ($null -ne $fn) 'the per-cycle function must exist'
        $syncCalls = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -in @('Sync-HostClock', 'Sync-WindowsHostClock', 'Sync-MacHostClock', 'Sync-LinuxHostClock')
        }, $true))
        Assert-True ($syncCalls.Count -eq 0) `
            "the cycle must not attempt a clock sync: $(($syncCalls | ForEach-Object { $_.Extent.Text }) -join '; ')"
    }
}

Describe 'host-clock-skew repair where a console can answer' {

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
        # The sync underneath is `sudo -n` throughout, so an accepted offer
        # dies on "a password is required" unless the cache is primed first.
        $prime = @($offer.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Initialize-SudoCache'
        }, $true))
        $sync = @($offer.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Sync-HostClock'
        }, $true))
        Assert-True ($prime.Count -ge 1) 'an accepted offer must be able to obtain sudo'
        Assert-True ($sync.Count -ge 1)  'an accepted offer must actually sync'
        Assert-True ($prime[0].Extent.StartLineNumber -lt $sync[0].Extent.StartLineNumber) `
            'the sudo cache must be primed before the sync that spends it'
    }

    foreach ($entry in $hostFiles.GetEnumerator()) {
        $ht   = $entry.Key
        $path = $entry.Value
        It "keeps the durable fix on the operator-facing host-prep path: $ht" {
            $setFn = $assertFn[$ht] -replace '^Assert-', 'Set-'
            $fn = Get-FunctionAst -Path $path -Name $setFn
            Assert-True ($null -ne $fn) "$setFn must exist"
            $calls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq $syncFn[$ht]
            }, $true))
            Assert-True ($calls.Count -ge 1) `
                "$setFn (reached from Enable-TestAutomation.ps1) must still discipline the clock"
        }
    }
}
