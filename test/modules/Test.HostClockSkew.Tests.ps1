<#PSScriptInfo
.VERSION 2026.08.25
.GUID 42c5e353-0701-44d3-9ece-c8318df10ad6
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

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$sharedFile = Join-Path $here 'Test.HostCondition.psm1'
$script:outerLoopFile = Join-Path $here 'Test.RunnerOuterLoop.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

}

# The three host types this file holds to the same clock contract. The list is
# built at FILE scope because every Describe body is executed while the file is
# being discovered, which happens before any BeforeAll runs: a list assigned in
# BeforeAll is still $null when the foreach that emits the per-host Its reads it,
# so the loop emits no tests at all and its Describe passes without asserting
# anything. Each case then reaches its It through -TestCases for the same
# reason -- discovery's loop variable is gone by the time the body executes, so a
# $case read inside the body would arrive as $null and assert against an empty
# path. Nothing here may have a side effect: discovery builds and discards this
# scope before the first It runs.
$discoveryHere = Split-Path -Parent $PSCommandPath

$discoveryRepoRoot = Split-Path -Parent (Split-Path -Parent $discoveryHere)
$hostClockCases = @(
    @{ HostType   = 'host.windows.hyper-v'
       Path       = (Join-Path $discoveryHere 'Test.HostCondition.Windows.psm1')
       EnablePath = (Join-Path $discoveryRepoRoot 'host/windows.hyper-v/Enable-TestAutomation.ps1')
       AssertFn   = 'Assert-WindowsHostConditionSet'
       SetFn      = 'Set-WindowsHostConditionSet'
       SyncFn     = 'Sync-WindowsHostClock' },
    @{ HostType   = 'host.macos.utm'
       Path       = (Join-Path $discoveryHere 'Test.HostCondition.Mac.psm1')
       EnablePath = (Join-Path $discoveryRepoRoot 'host/macos.utm/Enable-TestAutomation.ps1')
       AssertFn   = 'Assert-MacHostConditionSet'
       SetFn      = 'Set-MacHostConditionSet'
       SyncFn     = 'Sync-MacHostClock' },
    @{ HostType   = 'host.ubuntu.kvm'
       Path       = (Join-Path $discoveryHere 'Test.HostCondition.Linux.psm1')
       EnablePath = (Join-Path $discoveryRepoRoot 'host/ubuntu.kvm/Enable-TestAutomation.ps1')
       AssertFn   = 'Assert-LinuxHostConditionSet'
       SetFn      = 'Set-LinuxHostConditionSet'
       SyncFn     = 'Sync-LinuxHostClock' }
)

# A renamed or moved host-condition module must fail the file loudly here rather
# than let the per-host guards quietly stop covering that platform.
foreach ($hostClockCase in $hostClockCases) {
    if (-not (Test-Path -LiteralPath $hostClockCase.Path)) {
        throw "Host condition module not found for $($hostClockCase.HostType): $($hostClockCase.Path)"
    }
    if (-not (Test-Path -LiteralPath $hostClockCase.EnablePath)) {
        throw "Enable-TestAutomation.ps1 not found for $($hostClockCase.HostType): $($hostClockCase.EnablePath)"
    }
}

# Only these two platforms repair the clock through sudo; Windows elevates a
# different way, so the no-prompt guard below does not apply to it.
$hostClockSudoCases = @($hostClockCases | Where-Object { $_.HostType -in @('host.macos.utm', 'host.ubuntu.kvm') })

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

    foreach ($case in $hostClockCases) {
        It "reports a skewed clock once per cycle: $($case.HostType)" -TestCases @(@{
            HostType = $case.HostType; Path = $case.Path; AssertFn = $case.AssertFn
        }) {
            param([string]$HostType, [string]$Path, [string]$AssertFn)
            $fn = Get-FunctionAst -Path $Path -Name $AssertFn
            Assert-True ($null -ne $fn) "$AssertFn must exist"
            $calls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Write-HostClockDriftWarning'
            }, $true))
            Assert-True ($calls.Count -ge 1) "$HostType must consult the shared clock report"
            # A bare statement, never a condition: the clock must not decide
            # whether this host is allowed to run.
            foreach ($call in $calls) {
                Assert-True ($call.Parent -is [System.Management.Automation.Language.PipelineAst] -and
                             $call.Parent.Parent -is [System.Management.Automation.Language.NamedBlockAst]) `
                    "$HostType must call the clock report as a statement, not gate on it: $($call.Extent.Text)"
            }
        }
    }
}

Describe 'host-clock-skew repair' {

    foreach ($case in $hostClockCases) {
        It "can put its own clock back under NTP discipline: $($case.HostType)" -TestCases @(@{
            Path = $case.Path; SyncFn = $case.SyncFn
        }) {
            param([string]$Path, [string]$SyncFn)
            $fn = Get-FunctionAst -Path $Path -Name $SyncFn
            Assert-True ($null -ne $fn) "$SyncFn must exist"
            # Best-effort by contract: a clock fix needs privileges the
            # caller may not hold, and no caller may be left to throw.
            Assert-True ($fn.Extent.Text -match 'Succeeded') 'must report a Succeeded status rather than throwing'
        }
    }

    It 'registers every host clock-sync path with the dispatcher' -TestCases @(@{ Cases = $hostClockCases }) {
        param($Cases)
        $ast = Get-FileAst -Path $sharedFile
        foreach ($case in $Cases) {
            Assert-True ($ast.Extent.Text -match [regex]::Escape($case.SyncFn)) `
                "$($case.HostType) must register $($case.SyncFn) as its ClockSync capability"
        }
    }

    It 'never blocks an unattended host on a password prompt' -TestCases @(@{ Cases = $hostClockSudoCases }) {
        param($Cases)
        # A sudo prompt in the sync path is a hang, not a failed sync: the
        # runner calls this with no console.
        Assert-True (@($Cases).Count -eq 2) 'both sudo-based host types must reach this guard'
        foreach ($case in $Cases) {
            $fn = Get-FunctionAst -Path $case.Path -Name $case.SyncFn
            $sudoCalls = @($fn.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'sudo'
            }, $true))
            Assert-True ($sudoCalls.Count -ge 1) "$($case.HostType) is expected to need sudo"
            foreach ($call in $sudoCalls) {
                Assert-True ($call.Extent.Text -match 'sudo\s+-n\b') `
                    "$($case.HostType) must call sudo with -n so it can never wait on a prompt: $($call.Extent.Text)"
            }
        }
    }

    It 'never syncs the clock from an unattended cycle' {
        # Every platform's sync is a privileged call. On macOS/Linux it needs
        # a sudo credential nobody is present to type, and `sudo -n` fails
        # rather than hangs -- so per-cycle it could only ever log a failure,
        # once per host, forever. The runner reports the skew instead and
        # leaves the repair to a console that can answer for it.
        $fn = Get-FunctionAst -Path $script:outerLoopFile -Name 'Invoke-RunnerOuterCycle'
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
        # a console that can answer. The promptability question has one
        # canonical spelling (redirected stdin OR stdout, the non-interactive
        # environment contract, and a missing console object all disqualify);
        # a local re-spelling here would pass on a headless run whose stdout is
        # captured, and stall it on a keystroke nobody knows to press.
        $prompts = @($offer.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Read-Host'
        }, $true))
        $gates = @($offer.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Test-YurunaCanPrompt'
        }, $true))
        Assert-True ($prompts.Count -ge 1) 'the fix must be offered, not applied silently'
        Assert-True ($gates.Count -ge 1) `
            'the offer must consult Test-YurunaCanPrompt so it is skipped on a headless run'
        Assert-True ($gates[0].Extent.StartLineNumber -lt $prompts[0].Extent.StartLineNumber) `
            'the promptability gate must run before the question it guards'
        # A gate whose answer is discarded skips nothing, so it has to decide a
        # branch rather than merely appear.
        $gatedIf = @($offer.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            @($n.Clauses | ForEach-Object {
                $_.Item1.FindAll({
                    param($c)
                    $c -is [System.Management.Automation.Language.CommandAst] -and
                    $c.GetCommandName() -eq 'Test-YurunaCanPrompt'
                }, $true)
            }).Count -gt 0
        }, $true))
        Assert-True ($gatedIf.Count -ge 1) `
            'the promptability answer must control a branch, not be evaluated and dropped'
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

    foreach ($case in $hostClockCases) {
        It "keeps the durable fix on the operator-facing host-prep path: $($case.HostType)" -TestCases @(@{
            Path = $case.Path; EnablePath = $case.EnablePath; SetFn = $case.SetFn; SyncFn = $case.SyncFn
        }) {
            param([string]$Path, [string]$EnablePath, [string]$SetFn, [string]$SyncFn)
            # What has to hold is that running Enable-TestAutomation.ps1
            # disciplines the clock. Two shapes do that: the host's
            # Set-*HostConditionSet calls the sync and the script calls that
            # function, or the script calls the sync itself. Requiring only the
            # first shape let one host keep its clock fix inside a function no
            # script ever called -- green, and protecting nothing.
            #
            # Bind to locals so the parameters are referenced in the body:
            # the predicates below capture them, but PSReviewUnusedParameter
            # cannot see a use that occurs only inside a FindAll scriptblock.
            $wantedSync = $SyncFn
            $wantedSet  = $SetFn
            $isCallTo = {
                param($node, $name)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq $name
            }
            $enable = Get-FileAst -Path $EnablePath
            $viaSet = @($enable.FindAll({ param($n) & $isCallTo $n $wantedSet }, $true))
            if ($viaSet.Count -ge 1) {
                $fn = Get-FunctionAst -Path $Path -Name $wantedSet
                Assert-True ($null -ne $fn) `
                    "$EnablePath calls $SetFn, so $SetFn must exist"
                $calls = @($fn.FindAll({ param($n) & $isCallTo $n $wantedSync }, $true))
                Assert-True ($calls.Count -ge 1) `
                    "$SetFn is the host-prep path for this host, so it must discipline the clock"
            } else {
                $direct = @($enable.FindAll({ param($n) & $isCallTo $n $wantedSync }, $true))
                Assert-True ($direct.Count -ge 1) `
                    "no $SetFn call in $EnablePath, so it must call $SyncFn itself"
            }
        }
    }
}
