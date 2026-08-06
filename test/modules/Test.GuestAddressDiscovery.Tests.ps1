<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42e7c1a9-5d38-4b64-9a17-6c0f2b8d3e75
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test utm discovery arp bridged pester
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
    The macOS/UTM guest-address chain: the order its rungs run in, and that
    a BRIDGED guest -- invisible to both cheap rungs -- still resolves.
.DESCRIPTION
    WHY THIS EXISTS. A bridged UTM guest is unreachable by either cheap
    source. `utmctl ip-address` needs qemu-guest-agent, which the seeds do
    not install; /var/db/dhcpd_leases belongs to the macOS SHARED-NAT DHCP
    server, and a bridged guest takes its lease from the LAN router and
    never appears in it. A chain with only those two rungs reports a healthy
    guest that is serving traffic exactly as it reports a VM that does not
    exist, and every caller then waits out its whole budget against $null.
    The third rung -- the bundle's MAC matched in the host ARP table -- is
    what closes that, and the cases below pin both halves of it: that it
    answers for the bridged guest, and that it is never reached by a guest
    the cheap rungs can answer for, because it is the only rung that can
    cost seconds.

    HOW IT IS DRIVEN. Every case is fed pre-captured `utmctl ip-address`
    output, lease-file text and `arp -an` lines through the rungs' test
    seams, so no VM, no network and no macOS are required. The rung-order
    cases substitute each rung inside the module's own session state
    (`& $module { function script:... }`), which is the only scope a
    module-private call resolves in; the sweep helper is substituted the
    same way, so a case can assert it was asked for ONE attempt without a
    single packet leaving the host.

    Assertions are plain throws and the Pester harness is shimmed when
    Pester is absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.GuestAddressDiscovery.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.GuestAddressDiscovery.Tests.ps1)
#>

$here            = Split-Path -Parent $PSCommandPath
$DiscoveryRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$DiscoveryModule = Join-Path $DiscoveryRoot 'host/macos.utm/modules/Yuruna.Host.psm1'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Null  { param($Value, [string]$Because = '') if ($null -ne $Value -and "$Value" -ne '') { throw "Expected nothing, got '$Value'. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

# Pester is not installed on every host that runs this repo's scripts, and the
# assertions here are plain throws, so the harness the file needs is three
# functions. Defined only when the real ones are absent; every fixture is
# computed at file scope, so the immediate-run shim and Pester's
# discovery-then-run split observe the same state.
if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function Context  { param([string]$Name, [scriptblock]$Fixture) Write-Output "  Context: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

# The driver under test is the macOS one, but nothing below executes a
# macOS-only code path, so the file is expected to run anywhere. An import
# that fails is a hard stop rather than a skip: a suite that exits 0 without
# having run its cases is worse than no suite at all.
Import-Module $DiscoveryModule -Force -DisableNameChecking -Global -ErrorAction Stop
if (-not (Get-Module Yuruna.Host)) {
    throw "Yuruna.Host (macos.utm) did not load from '$DiscoveryModule'; the guest-address chain cannot be exercised."
}

# --- Fixtures: the shape a bridged service guest actually presents ---

# utmctl exits 0 and complains on stderr when the guest has no agent, so this
# is what a healthy, serving, bridged guest looks like to rung 1.
$UtmctlAgentAbsent = @(
    'Error from event: The operation couldn''t be completed. (OSStatus error -2700.)'
    'The QEMU guest agent is not running or not installed on the guest.'
)
$UtmctlAnswered = @('192.168.7.51', 'fe80::1')

# The lease file the shared-NAT DHCP server keeps. It has no block for the
# bridged guest -- it cannot have one -- but it does carry a same-named block
# from when that name was last built on Shared NAT, which is exactly the
# answer a name lookup would hand back if it were allowed to run.
$LeaseWithStaleSharedBlock = @'
{
	name=yuruna-stash-service
	ip_address=192.168.64.11
	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:79:63:72:b7:3c:4f:7d:73
	lease=0x6a6c58b9
}
{
	name=test-ubuntu-desktop01
	ip_address=192.168.64.77
	hw_address=1,aa:bb:cc:dd:ee:ff
	lease=0x6a6c0000
}
'@

# `arp -an` as macOS prints it: lowercase, leading zero of each octet
# stripped. The guest is at .51; the decoy is the SAME MAC cached on another
# interface's subnet, which a prefix-blind match would return instead.
$ArpWithGuest = @(
    '? (192.168.7.1) at d8:b3:70:3c:c1:bf on en0 ifscope [ethernet]'
    '? (192.168.7.13) at a4:bb:6d:5b:85:6f on en0 ifscope [ethernet]'
    '? (192.168.7.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]'
    '? (192.168.7.226) at 56:18:74:ac:6:32 on en0 ifscope [ethernet]'
)
$ArpDecoyOnly = @(
    '? (10.211.55.3) at e6:1:bc:6d:21:cd on bridge100 ifscope [ethernet]'
    '? (192.168.7.13) at a4:bb:6d:5b:85:6f on en0 ifscope [ethernet]'
)

$GuestMac    = 'E6:01:BC:6D:21:CD'
$GuestName   = 'yuruna-stash-service'
$LanPrefix   = '192.168.7.'
$LanHostIp   = '192.168.7.101'

function New-BundleNetwork {
    <#
    .SYNOPSIS
        A bundle network descriptor in the shape Get-UtmBundleNetwork returns.
        Built in memory rather than read from a .utm bundle so the cases do
        not depend on which VMs happen to exist on the host running them.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory descriptor; changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Mode = 'Bridged', [string]$MacAddress = 'E6:01:BC:6D:21:CD', [string]$VMName = 'yuruna-stash-service')
    return [pscustomobject]@{
        VMName     = $VMName
        PlistPath  = "/nonexistent/$VMName.utm/config.plist"
        Mode       = $Mode
        MacAddress = $MacAddress
    }
}

function Invoke-InModule {
    <#
    .SYNOPSIS
        Run a scriptblock against the driver's private functions. A rung is
        module-private, so it is reachable only in the module's own session
        state -- a bare call from here would not resolve at all.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Body, [object[]]$ArgumentList = @())
    $mod = Get-Module Yuruna.Host
    if (-not $mod) { throw 'Yuruna.Host is not loaded; the module import at file scope did not survive.' }
    & $mod $Body @ArgumentList
}

function Reset-DiscoveryModule {
    <#
    .SYNOPSIS
        Put the real rungs back. Every case starts from here, because a
        substitute is written into the module's own scope and outlives the
        case that installed it -- a later case would otherwise assert against
        the previous one's stand-in and pass without running the code it
        names. A re-import costs single-digit milliseconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: re-imports the module the suite imported for itself.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: Pester runs each case in a scope of its own, so the module path has to be reachable globally.')]
    [CmdletBinding()]
    param()
    Import-Module $global:DiscoveryModulePath -Force -DisableNameChecking -Global -ErrorAction Stop
}

function Set-DiscoveryRungSubstitute {
    <#
    .SYNOPSIS
        Replace the three rungs (and the bundle read, and the sweep) inside the
        module with recording substitutes, and reset the record.
    .DESCRIPTION
        `function script:<name>` inside `& $module { }` writes into the module
        scope itself, which is where a module-private call resolves -- a plain
        `function` there would land in the scriptblock's own child scope and be
        gone before Get-VMIp ran. The module is re-imported first so each case
        starts from the real rungs rather than the previous case's stand-ins.

        Declared as a function a case CALLS, not at file scope: Pester scans
        the file to collect its blocks and runs them afterwards, so a
        substitution performed during the scan would be long gone by the time
        the cases execute.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: substitutes rungs inside the module the suite imported for itself.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the substitutes run inside module session state, so their record has to live where both session states agree.')]
    [CmdletBinding()]
    param(
        [string]$AgentAnswer = '',
        [string]$LeaseAnswer = '',
        [string]$ArpAnswer   = ''
    )
    $global:DiscoveryRungCall   = @()
    $global:DiscoveryRungAsk    = @()
    $global:DiscoveryAgentReply = $AgentAnswer
    $global:DiscoveryLeaseReply = $LeaseAnswer
    $global:DiscoveryArpReply   = $ArpAnswer
    Reset-DiscoveryModule
    # Each substitute records what it was ASKED, not just that it was asked:
    # a chain that runs its rungs in the right order but hands one of them
    # the wrong VM name or a bundle it did not read is broken in a way a
    # call-order record alone cannot see.
    Invoke-InModule -Body {
        function script:Get-UtmBundleNetwork {
            param([Parameter(Mandatory)][string]$VMName)
            $global:DiscoveryRungCall += 'bundle'
            return [pscustomobject]@{ VMName = $VMName; PlistPath = "/nonexistent/$VMName.utm/config.plist"; Mode = 'Bridged'; MacAddress = 'E6:01:BC:6D:21:CD' }
        }
        function script:Get-UtmAgentReportedIp {
            param([Parameter(Mandatory)][string]$VMName, [string[]]$UtmctlLine)
            $global:DiscoveryRungCall += 'agent'
            $global:DiscoveryRungAsk += [pscustomobject]@{ Rung = 'agent'; VMName = $VMName; Detail = ($UtmctlLine -join '|') }
            if ($global:DiscoveryAgentReply) { return $global:DiscoveryAgentReply }
            return $null
        }
        function script:Get-UtmSharedLeaseIp {
            param([Parameter(Mandatory)][string]$VMName, [psobject]$BundleNetwork, [string]$LeaseText)
            $global:DiscoveryRungCall += 'lease'
            $global:DiscoveryRungAsk += [pscustomobject]@{ Rung = 'lease'; VMName = $VMName; Detail = "$($BundleNetwork.VMName)/$LeaseText" }
            if ($global:DiscoveryLeaseReply) { return $global:DiscoveryLeaseReply }
            return $null
        }
        function script:Get-UtmBridgedGuestIp {
            param([Parameter(Mandatory)][string]$VMName, [psobject]$BundleNetwork, [string]$SubnetPrefix, [string]$HostIp, [string[]]$ArpLine)
            $global:DiscoveryRungCall += 'arp'
            $global:DiscoveryRungAsk += [pscustomobject]@{ Rung = 'arp'; VMName = $VMName; Detail = "$($BundleNetwork.VMName)/$SubnetPrefix/$HostIp/$($ArpLine.Count)" }
            if ($global:DiscoveryArpReply) { return $global:DiscoveryArpReply }
            return $null
        }
    }
}

function Set-SweepSubstitute {
    <#
    .SYNOPSIS
        Replace the ICMP-sweep resolver with one that records how it was
        called and answers $SweepAnswer. Nothing here may put packets on a
        network, and the constraint under test -- one bounded attempt -- is
        readable only from the arguments it is handed.
    .DESCRIPTION
        The VM-state query is substituted alongside it, and defaults to
        'running'. The rung asks for the state before it escalates, and the
        fixtures name VMs no host has, so the real query would answer
        'absent' for every one of them -- every sweep case would then pass by
        never reaching the code it is about. -VMState is what the cases that
        ARE about the guard set.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: substitutes one helper inside the module the suite imported for itself.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the substitute runs inside module session state, so its record has to live where both session states agree.')]
    [CmdletBinding()]
    param([string]$SweepAnswer = '', [string]$VMState = 'running')
    $global:DiscoverySweepCall   = @()
    $global:DiscoverySweepReply  = $SweepAnswer
    $global:DiscoveryVmState     = $VMState
    $global:DiscoveryVmStateCall = @()
    Reset-DiscoveryModule
    Invoke-InModule -Body {
        function script:Get-VMState {
            param([Parameter(Mandatory)][string]$VMName)
            $global:DiscoveryVmStateCall += $VMName
            return $global:DiscoveryVmState
        }
        function script:Resolve-UtmGuestIpByMac {
            param(
                [Parameter(Mandatory)][string]$PlistPath,
                [Parameter(Mandatory)][string]$SubnetPrefix,
                [string]$HostIp,
                [int]$ProbePort = 0,
                [int]$TimeoutMinutes = 15,
                [int]$PollSeconds = 5,
                [int]$MaxAttempt = 0
            )
            $global:DiscoverySweepCall += [pscustomobject]@{
                PlistPath      = $PlistPath
                SubnetPrefix   = $SubnetPrefix
                HostIp         = $HostIp
                ProbePort      = $ProbePort
                TimeoutMinutes = $TimeoutMinutes
                PollSeconds    = $PollSeconds
                MaxAttempt     = $MaxAttempt
            }
            if ($global:DiscoverySweepReply) { return $global:DiscoverySweepReply }
            return $null
        }
    }
}

function Set-HostAddressSubstitute {
    <#
    .SYNOPSIS
        Replace the host's default-route lookup with one that records how many
        times it was asked, and answers $Answer. Call AFTER a fixture that
        re-imports the module, or the re-import undoes it.
    .DESCRIPTION
        Rung 3 needs two things the host's default route decides: the /24 to
        look on, and the host's own address on it. Each independent resolution
        of those is a `route` plus an `ipconfig` spawn, on a path Wait-VMIp
        polls -- so the CALL COUNT is the assertion. A chain that resolves them
        separately returns exactly the same address for twice the cost, which
        no result-only check can see.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: substitutes one helper inside the module the suite imported for itself.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the substitute runs inside module session state, so its record has to live where both session states agree.')]
    [CmdletBinding()]
    param([string]$Answer = '192.168.7.101')
    $global:DiscoveryHostIpCall  = 0
    $global:DiscoveryHostIpReply = $Answer
    Invoke-InModule -Body {
        function script:Get-BestHostIp {
            $global:DiscoveryHostIpCall++
            return $global:DiscoveryHostIpReply
        }
    }
}

function Get-DiscoveryHostIpCallCount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted host lookup keeps; see Set-HostAddressSubstitute.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$global:DiscoveryHostIpCall
}

function Get-DiscoveryRungCall {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted rungs keep; see Set-DiscoveryRungSubstitute.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($global:DiscoveryRungCall | Where-Object { $_ -ne 'bundle' })
}

function Get-DiscoveryBundleReadCount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted bundle reader keeps; see Set-DiscoveryRungSubstitute.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]@($global:DiscoveryRungCall | Where-Object { $_ -eq 'bundle' }).Count
}

function Get-DiscoveryRungAsk {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted rungs keep; see Set-DiscoveryRungSubstitute.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return [object[]]@($global:DiscoveryRungAsk)
}

function Get-DiscoverySweepCall {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted sweep keeps; see Set-SweepSubstitute.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return [object[]]@($global:DiscoverySweepCall)
}

function Get-DiscoveryVmStateCallCount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the record the substituted state query keeps; see Set-SweepSubstitute.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]@($global:DiscoveryVmStateCall).Count
}

function Set-DiscoveryModulePath {
    <#
    .SYNOPSIS
        Publish the module path where the fixtures can reach it. Pester runs
        each case in a scope of its own, so a file-scope variable is not
        visible from inside one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: publishes one path for the suite that is running.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the fixtures run in scopes of their own, so the path has to live where all of them agree.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $global:DiscoveryModulePath = $Path
}
Set-DiscoveryModulePath -Path $DiscoveryModule

Describe 'The rungs run cheapest-first and stop at the first answer' {

    It 'takes the guest agent answer and asks nothing else' {
        Set-DiscoveryRungSubstitute -AgentAnswer '192.168.64.5' -LeaseAnswer '192.168.64.9' -ArpAnswer '192.168.7.51'
        Assert-Equal -Expected '192.168.64.5' -Actual (Get-VMIp -VMName $GuestName) -Because 'the cheapest rung answered'
        Assert-Equal -Expected 'agent' -Actual ((Get-DiscoveryRungCall) -join ',') -Because 'no rung below it was consulted'
    }

    It 'falls to the lease file when the agent is silent, and stops there' {
        # The ARP rung is the only one that can cost seconds. A Shared-NAT
        # guest, which the lease file answers for, must never reach it.
        Set-DiscoveryRungSubstitute -LeaseAnswer '192.168.64.9' -ArpAnswer '192.168.7.51'
        Assert-Equal -Expected '192.168.64.9' -Actual (Get-VMIp -VMName $GuestName)
        Assert-Equal -Expected 'agent,lease' -Actual ((Get-DiscoveryRungCall) -join ',') -Because 'the expensive rung stays unreached'
    }

    It 'reaches the ARP rung only when both cheap rungs decline' {
        Set-DiscoveryRungSubstitute -ArpAnswer '192.168.7.51'
        Assert-Equal -Expected '192.168.7.51' -Actual (Get-VMIp -VMName $GuestName) -Because 'the bridged guest is found'
        Assert-Equal -Expected 'agent,lease,arp' -Actual ((Get-DiscoveryRungCall) -join ',') -Because 'in that order, every time'
    }

    It 'resolves nothing, and says every rung was tried, when all three decline' {
        Set-DiscoveryRungSubstitute
        $emitted = @(Get-VMIp -VMName $GuestName -Verbose 4>&1)
        $verbose = @($emitted | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { "$_" })
        $ip = @($emitted | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }) | Select-Object -First 1
        Assert-Null $ip 'nothing was discovered'
        Assert-Equal -Expected 'agent,lease,arp' -Actual ((Get-DiscoveryRungCall) -join ',') -Because 'every rung was given its turn'
        Assert-True (($verbose -join "`n") -match 'all three rungs declined') 'the empty result is explained, not silent'
    }

    It 'reads the bundle once for the whole chain' {
        # Both lower rungs need the bundle; each reading it on its own would
        # shell out to plutil twice per call, in a per-cycle path.
        Set-DiscoveryRungSubstitute
        $null = Get-VMIp -VMName $GuestName
        Assert-Equal -Expected 1 -Actual (Get-DiscoveryBundleReadCount) -Because 'one plist read serves the chain'
    }

    It 'asks every rung about the VM the caller named, with the bundle it read' {
        # A chain that runs its rungs in order but hands one of them the
        # wrong name, or a bundle it did not read, resolves someone else.
        Set-DiscoveryRungSubstitute
        $null = Get-VMIp -VMName $GuestName
        foreach ($ask in (Get-DiscoveryRungAsk)) {
            Assert-Equal -Expected $GuestName -Actual $ask.VMName -Because "rung '$($ask.Rung)' was asked about the wrong VM"
        }
        $arpAsk = @(Get-DiscoveryRungAsk | Where-Object { $_.Rung -eq 'arp' })[0]
        Assert-True ("$($arpAsk.Detail)".StartsWith($GuestName)) 'the ARP rung got the bundle the chain read'
    }
}

Describe 'A bridged guest the cheap rungs cannot see' {

    It 'declines rung 1: utmctl exits 0 while saying the guest has no agent' {
        # The exit code cannot be the test for "an address came back"; only
        # the parse can.
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $lines) Get-UtmAgentReportedIp -VMName $n -UtmctlLine $lines } -ArgumentList @($GuestName, $UtmctlAgentAbsent)
        Assert-Null $ip 'an agent complaint is not an address'
    }

    It 'declines rung 2: the bundle is Bridged, so a same-named lease block is a predecessor' {
        # The block parses, sits on-link while the vmnet bridge is up, and
        # looks exactly like a good answer. Returning it would hide the
        # guest's real LAN address behind a dead one for the rest of the run.
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $b, $t) Get-UtmSharedLeaseIp -VMName $n -BundleNetwork $b -LeaseText $t -OnLinkVerdict { 'onlink' } } `
            -ArgumentList @($GuestName, (New-BundleNetwork -Mode 'Bridged'), $LeaseWithStaleSharedBlock)
        Assert-Null $ip 'a bridged guest never leases from the shared-NAT server'
        # Same name, same file, mode flipped: the block IS there and IS
        # selectable, so it is the Bridged verdict -- nothing else -- that
        # keeps it from being handed out.
        $wouldHave = Invoke-InModule -Body { param($n, $b, $t) Get-UtmSharedLeaseIp -VMName $n -BundleNetwork $b -LeaseText $t -OnLinkVerdict { 'onlink' } } `
            -ArgumentList @($GuestName, (New-BundleNetwork -Mode 'Shared'), $LeaseWithStaleSharedBlock)
        Assert-Equal -Expected '192.168.64.11' -Actual $wouldHave -Because 'the dead address a mode-blind lookup would return'
    }

    It 'resolves at rung 3: the bundle MAC is in the host ARP table' {
        Set-SweepSubstitute
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip -Because 'the guest was serving the whole time; only discovery was missing'
        Assert-Equal -Expected 0 -Actual (Get-DiscoverySweepCall).Count -Because 'an entry already in the table costs no sweep'
    }

    It 'derives the /24 and the host address from ONE default-route lookup' {
        # Neither is supplied here, which is how Get-VMIp calls this rung. Both
        # come from the same default route, and resolving them independently
        # costs a second `route` + `ipconfig` pair every poll -- and lets the
        # two answers come from different uplinks if the route changes between
        # the reads.
        Set-SweepSubstitute
        Set-HostAddressSubstitute -Answer $LanHostIp
        $ip = Invoke-InModule -Body { param($n, $b, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $ArpWithGuest)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip -Because 'the derived prefix is the one the guest is on'
        Assert-Equal -Expected 1 -Actual (Get-DiscoveryHostIpCallCount) -Because 'asked once, used for both'
    }

    It 'sweeps ONCE, never in a retry loop, when the table has no entry yet' {
        # Get-VMIp is called per cycle by the runner and inside Wait-VMIp's
        # poll loop. The poll loop is the retry; a rung that retried here
        # would block those callers for minutes.
        Set-SweepSubstitute -SweepAnswer '192.168.7.51'
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, @())
        Assert-Equal -Expected '192.168.7.51' -Actual $ip
        $calls = Get-DiscoverySweepCall
        Assert-Equal -Expected 1 -Actual $calls.Count -Because 'exactly one escalation'
        Assert-Equal -Expected 1 -Actual $calls[0].MaxAttempt -Because 'and it is bounded to a single attempt'
        Assert-Equal -Expected $LanPrefix -Actual $calls[0].SubnetPrefix -Because "the host's own LAN is where a bridged guest is"
    }
}

Describe 'The ARP rung refuses what it cannot prove, and skips what it cannot help' {

    It 'ignores the same MAC cached on another subnet' {
        # `arp -an` lists every interface, so a recreated bundle MAC still
        # cached elsewhere would otherwise be returned -- and, since the first
        # match wins, returned again on every poll.
        Set-SweepSubstitute
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, $ArpDecoyOnly)
        Assert-Null $ip 'an entry outside the swept subnet is not this guest'
    }

    It 'declines for a Shared-NAT bundle without sweeping' {
        # It lives on the vmnet subnet, not the host LAN, so the sweep could
        # not match it -- and the lease file already answered for it.
        Set-SweepSubstitute -SweepAnswer '192.168.7.51'
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork -Mode 'Shared'), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Null $ip 'a NAT guest is not looked for on the LAN'
        Assert-Equal -Expected 0 -Actual (Get-DiscoverySweepCall).Count -Because 'and costs nothing to skip'
    }

    It 'still runs for a bundle whose mode cannot be read' {
        # An unreadable mode is not evidence the guest is on NAT.
        Set-SweepSubstitute
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork -Mode ''), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip
    }

    It 'declines when the bundle carries no MAC' {
        Set-SweepSubstitute -SweepAnswer '192.168.7.51'
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork -MacAddress ''), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Null $ip 'there is no identity to match on'
        Assert-Equal -Expected 0 -Actual (Get-DiscoverySweepCall).Count -Because 'and nothing to sweep for'
    }

    It 'declines when this host has no LAN of its own' {
        # No default-route IPv4 means no subnet a bridged guest could be on.
        Set-SweepSubstitute -SweepAnswer '192.168.7.51'
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), '', '', $ArpWithGuest)
        Assert-Null $ip 'nothing to look at'
        Assert-Equal -Expected 0 -Actual (Get-DiscoverySweepCall).Count -Because 'and nowhere to sweep'
    }

    It 'declines when there is no bundle on this host' {
        Set-SweepSubstitute -SweepAnswer '192.168.7.51'
        $ip = Invoke-InModule -Body { param($n, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $null -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @('no-such-vm', $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Null $ip 'a VM this host never built has no MAC to match'
    }
}

Describe 'The sweep is escalation, and what it costs a repeat caller is bounded' {

    It 'never sweeps for a VM that is not running' {
        # A bundle outlives its guest, so "bundle present, VM down" is the
        # ordinary state of a stopped service -- not an edge case. Nothing
        # powered off answers ICMP, so the sweep could only come back empty.
        Set-SweepSubstitute -SweepAnswer '192.168.7.51' -VMState 'stopped'
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, @())
        Assert-Null $ip 'a stopped guest has no address to find'
        Assert-Equal -Expected 0 -Actual (Get-DiscoverySweepCall).Count -Because 'one state query answers what a /24 of ICMP would take seconds to'
    }

    It 'answers a running guest already in the table without asking for its state' {
        # The passive read is what steady state costs. Reaching the state
        # query at all on a hit would put a utmctl call in a per-cycle path
        # that does not need one.
        Set-SweepSubstitute
        $ip = Invoke-InModule -Body { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a } `
            -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip
        Assert-Equal -Expected 0 -Actual (Get-DiscoveryVmStateCallCount) -Because 'nothing is escalated, so nothing is asked'
    }

    It 'does not re-sweep straight away after a sweep that found nothing' {
        # Wait-YurunaServiceVmEndpoint re-resolves on EVERY poll, at three
        # seconds. Without this, a bridged guest that never appears turns each
        # of those polls into a full /24 of ICMP for the whole budget.
        Set-SweepSubstitute
        $body = { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a }
        $callArgs = @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, @())
        foreach ($i in 1..5) { Assert-Null (Invoke-InModule -Body $body -ArgumentList $callArgs) "call $i found nothing" }
        Assert-Equal -Expected 1 -Actual (Get-DiscoverySweepCall).Count -Because 'five polls, one sweep'
    }

    It 'keeps reading the ARP table while the sweep is on cooldown' {
        # The memo suppresses the ESCALATION only. A guest that finishes its
        # DHCP exchange during the cooldown has to be picked up by the very
        # next poll, at the passive read's ~20 ms -- suppressing that too
        # would trade one stall for a shorter one.
        Set-SweepSubstitute
        $body = { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a }
        Assert-Null (Invoke-InModule -Body $body -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, @())) 'nothing yet'
        $ip = Invoke-InModule -Body $body -ArgumentList @($GuestName, (New-BundleNetwork), $LanPrefix, $LanHostIp, $ArpWithGuest)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip -Because 'the guest appeared, and the cooldown did not hide it'
        Assert-Equal -Expected 1 -Actual (Get-DiscoverySweepCall).Count -Because 'and it cost no second sweep'
    }

    It 'is free to sweep again once the guest has been found and lost' {
        # A hit retires the memo. Otherwise a guest that appears and then moves
        # would be stuck behind a cooldown recorded before it was ever seen.
        Set-SweepSubstitute
        $body = { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a }
        $bundle = New-BundleNetwork
        Assert-Null  (Invoke-InModule -Body $body -ArgumentList @($GuestName, $bundle, $LanPrefix, $LanHostIp, @()))            'miss: memo recorded'
        Assert-Equal -Expected '192.168.7.51' -Actual (Invoke-InModule -Body $body -ArgumentList @($GuestName, $bundle, $LanPrefix, $LanHostIp, $ArpWithGuest)) -Because 'hit: memo retired'
        Assert-Null  (Invoke-InModule -Body $body -ArgumentList @($GuestName, $bundle, $LanPrefix, $LanHostIp, @()))            'gone again'
        Assert-Equal -Expected 2 -Actual (Get-DiscoverySweepCall).Count -Because 'the second disappearance is escalated on its own merits'
    }

    It 'holds the memo per VM, not for the host' {
        # One service that is down must not stop another from being looked for.
        Set-SweepSubstitute
        $body = { param($n, $b, $p, $h, $a) Get-UtmBridgedGuestIp -VMName $n -BundleNetwork $b -SubnetPrefix $p -HostIp $h -ArpLine $a }
        Assert-Null (Invoke-InModule -Body $body -ArgumentList @('yuruna-stash-service',        (New-BundleNetwork -VMName 'yuruna-stash-service'),        $LanPrefix, $LanHostIp, @()))
        Assert-Null (Invoke-InModule -Body $body -ArgumentList @('yuruna-pool-control-service', (New-BundleNetwork -VMName 'yuruna-pool-control-service'), $LanPrefix, $LanHostIp, @()))
        Assert-Equal -Expected 2 -Actual (Get-DiscoverySweepCall).Count -Because 'each VM gets its own escalation'
    }
}

Describe 'A Shared-NAT guest is answered by the lease file, and only by it' {

    It 'returns the lease the shared-NAT server filed under its name' {
        Reset-DiscoveryModule
        # The on-link judgement is pinned: whether 192.168.64.x is reachable
        # depends on the vmnet bridge existing on the machine running this,
        # and that is not what the case is about.
        $ip = Invoke-InModule -Body { param($n, $b, $t) Get-UtmSharedLeaseIp -VMName $n -BundleNetwork $b -LeaseText $t -OnLinkVerdict { 'onlink' } } `
            -ArgumentList @('test-ubuntu-desktop01', (New-BundleNetwork -Mode 'Shared' -VMName 'test-ubuntu-desktop01'), $LeaseWithStaleSharedBlock)
        Assert-Equal -Expected '192.168.64.77' -Actual $ip -Because 'the lease file is authoritative for a Shared-NAT guest'
    }

    It 'refuses an address no live interface can reach' {
        # Only an explicit 'offlink' rejects. The guard is what keeps a
        # predecessor's lease on a retired subnet from being handed out.
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $b, $t) Get-UtmSharedLeaseIp -VMName $n -BundleNetwork $b -LeaseText $t -OnLinkVerdict { 'offlink' } } `
            -ArgumentList @('test-ubuntu-desktop01', (New-BundleNetwork -Mode 'Shared' -VMName 'test-ubuntu-desktop01'), $LeaseWithStaleSharedBlock)
        Assert-Null $ip 'an unreachable lease is not an answer'
    }

    It 'reads the live lease file when no text is supplied' {
        Reset-DiscoveryModule
        # The seam replaces the source, not the behaviour: unbound, the rung
        # must still go to the file. A host with no shared-NAT guest history
        # has no file, and declining is the correct answer there too.
        $ip = Invoke-InModule -Body { param($n, $b) Get-UtmSharedLeaseIp -VMName $n -BundleNetwork $b } `
            -ArgumentList @('yuruna-no-such-guest-anywhere', (New-BundleNetwork -Mode 'Shared' -VMName 'yuruna-no-such-guest-anywhere'))
        Assert-Null $ip 'no guest by that name has ever leased here'
    }
}

Describe 'The MAC needle matches the form macOS prints' {

    It 'strips leading zeros and lowercases, as `arp -an` does' {
        Reset-DiscoveryModule
        Assert-Equal -Expected 'e6:1:bc:6d:21:cd' -Actual (Invoke-InModule -Body { param($m) ConvertTo-ArpMacNeedle -MacAddress $m } -ArgumentList @($GuestMac))
    }

    It 'answers nothing for input that is not six hex octets' {
        Reset-DiscoveryModule
        foreach ($bad in @('', 'not-a-mac', 'E6:01:BC:6D:21', 'E6:01:BC:6D:21:CD:EF', 'ZZ:01:BC:6D:21:CD')) {
            Assert-Null (Invoke-InModule -Body { param($m) ConvertTo-ArpMacNeedle -MacAddress $m } -ArgumentList @($bad)) "'$bad' is not a MAC"
        }
    }

    It 'matches an entry the bundle MAC produced, in either written form' {
        Reset-DiscoveryModule
        $needle = Invoke-InModule -Body { param($m) ConvertTo-ArpMacNeedle -MacAddress $m } -ArgumentList @($GuestMac)
        $ip = Invoke-InModule -Body { param($a, $n, $p) Select-ArpIpByMac -ArpLine $a -MacNeedle $n -SubnetPrefix $p } `
            -ArgumentList @($ArpWithGuest, $needle, $LanPrefix)
        Assert-Equal -Expected '192.168.7.51' -Actual $ip
    }

    It 'does not false-match a sibling /24' {
        Reset-DiscoveryModule
        # The prefix is dot-terminated, so '192.168.7.' cannot swallow
        # 192.168.70.x.
        $lines = @('? (192.168.70.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]')
        $ip = Invoke-InModule -Body { param($a, $n, $p) Select-ArpIpByMac -ArpLine $a -MacNeedle $n -SubnetPrefix $p } `
            -ArgumentList @($lines, 'e6:1:bc:6d:21:cd', $LanPrefix)
        Assert-Null $ip 'a neighbouring subnet is not this LAN'
    }

    It 'returns nothing for an empty table' {
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $p) Select-ArpIpByMac -ArpLine @() -MacNeedle $n -SubnetPrefix $p } `
            -ArgumentList @('e6:1:bc:6d:21:cd', $LanPrefix)
        Assert-Null $ip
    }
}

Describe 'Rung 1 reads what utmctl reports when it does answer' {

    It 'takes the routable address and skips loopback and link-local' {
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $lines) Get-UtmAgentReportedIp -VMName $n -UtmctlLine $lines } `
            -ArgumentList @($GuestName, (@('127.0.0.1', '169.254.3.4') + $UtmctlAnswered))
        Assert-Equal -Expected '192.168.7.51' -Actual $ip
    }

    It 'takes a routable IPv6 when that is all there is' {
        Reset-DiscoveryModule
        $ip = Invoke-InModule -Body { param($n, $lines) Get-UtmAgentReportedIp -VMName $n -UtmctlLine $lines } `
            -ArgumentList @($GuestName, @('fe80::1', '2001:db8::42'))
        Assert-Equal -Expected '2001:db8::42' -Actual $ip -Because 'a v6-only guest is not invisible'
    }
}

# Leaves the module as the rest of the session expects to find it: the
# substitutes above are written into its own scope and would otherwise
# outlive this file. Under Pester this runs during discovery, so the
# substitutions each case installs are undone by the re-import the next one
# performs.
Import-Module $DiscoveryModule -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
