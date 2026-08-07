<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b6a17d-3c48-4e90-9f2b-5d81c4e73a06
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test stash dhcp lease address pester
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
    Coverage for the two halves of stash-address resolution: confirming an
    address before advertising it (Update-StashServiceMarkerAddress) and
    collapsing the same-named lease blocks that make confirmation necessary
    (Select-StaleDhcpLeaseBlock / Remove-DhcpLeaseBlockText).
.DESCRIPTION
    macOS files each DHCP lease under the name the guest sent and never
    prunes, and a rebuilt guest presents a fresh client identity, so it is
    issued a new address instead of its predecessor's. A name therefore
    accumulates one block per incarnation, and for the seconds before the
    live guest takes its lease the only blocks bearing its name belong to
    guests that are gone. Address discovery hands one of those back: a dead
    address that parses, sits on-link, and looks exactly like a good answer.

    The cases below pin both responses to that. The marker refresh must keep
    polling until an address proves itself rather than publishing the first
    reply, and must still publish a correct-but-unconfirmed address when its
    budget runs out, because refusing that would trade this bug for its
    opposite. The pruner must remove only blocks it can prove are superseded:
    never the newest of a name, never a singleton, and never one whose
    address answers.

    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Get-VMIp and Test-StashServiceHost are substituted, so no
    VM, no network, and no macOS are required.
    Run: pwsh -NoProfile -File test/modules/Test.StashAddressResolution.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$StashRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $StashRepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $StashRepoRoot 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking -Global -WarningAction SilentlyContinue

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

$StashTestHome = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-stash-$PID"
function New-MarkerDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes only into the suite-owned temp root the suite removes when it ends.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Json = '{"active":true,"vmName":"yuruna-stash-service","hostType":"host.macos.utm"}')
    $dir = Join-Path $StashTestHome ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'stash-service.json') -Value $Json -Encoding ascii
    return $dir
}
function Get-MarkerUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Dir)
    return [string]((Get-Content -Raw -LiteralPath (Join-Path $Dir 'stash-service.json') | ConvertFrom-Json).stashBaseUrl)
}

# Two same-named blocks a lookup cannot tell apart except by expiry, plus an
# unrelated name that must survive every case untouched.
$StaleLeaseText = @'
{
	name=yuruna-stash-service
	ip_address=192.168.64.11
	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:79:63:72:b7:3c:4f:7d:73
	lease=0x6a6c58b9
}
{
	name=yuruna-stash-service
	ip_address=192.168.64.5
	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:cf:34:14:1a:94:cf:bf:ae
	lease=0x6a6c5940
}
{
	name=lonely-guest
	ip_address=192.168.64.77
	hw_address=1,aa:bb:cc:dd:ee:ff
	lease=0x6a6c0000
}
'@

# Substitute the discovery the marker refresh consumes. $IpAnswer supplies
# Get-VMIp's replies in order (the last repeats, so a case can model "stale,
# stale, then the real one"); $Healthy is the set of addresses that answer
# /healthz. State lives in the global scope because the substitutes are called
# from inside a module, which has a session state of its own.
#
# The substitutes are declared HERE, from a helper each case calls, rather than
# at file scope: Pester scans the file to collect its blocks and runs those
# blocks afterwards, and a function declared during the scan is not present by
# the time the cases execute -- Get-VMIp comes back "not recognized" and the
# refresh resolves nothing, which reads exactly like the bug under test.
function Set-StashDiscovery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: installs the substituted discovery for the case that calls it.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: the substitutes are called from inside a module, so their state has to live where both session states agree.')]
    [CmdletBinding()]
    param([string[]]$IpAnswer = @(), [string[]]$Healthy = @())
    $global:StashIpAnswer = $IpAnswer
    $global:StashHealthy  = $Healthy
    $global:StashIpCalls  = 0

    function Global:Get-VMIp {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$VMName)
        if ([string]::IsNullOrWhiteSpace($VMName)) { throw 'Get-VMIp was called without a VM name.' }
        $global:StashIpCalls++
        if ($global:StashIpAnswer.Count -eq 0) { return $null }
        $index = [Math]::Min($global:StashIpCalls - 1, $global:StashIpAnswer.Count - 1)
        return [string]$global:StashIpAnswer[$index]
    }

    function Global:Test-StashServiceHost {
        [CmdletBinding()]
        [OutputType([bool])]
        param([Parameter(Mandatory)][string]$Address, [int]$Attempts = 3, [int]$TimeoutSeconds = 10, [int]$BackoffMs = 500)
        # Assert the caller keeps each probe cheap. A wide per-probe deadline
        # would spend a whole poll budget confirming one dead predecessor,
        # which is the failure this substitution exists to model.
        if ($Attempts -lt 1) { throw "Test-StashServiceHost called with Attempts=$Attempts." }
        if ($TimeoutSeconds -gt 5) { throw "Test-StashServiceHost called with a $TimeoutSeconds s deadline; the poll loop is the retry." }
        if ($BackoffMs -lt 0) { throw "Test-StashServiceHost called with BackoffMs=$BackoffMs." }
        return ($global:StashHealthy -contains $Address)
    }
}

function New-PoolSegment {
    <#
    .SYNOPSIS
        A fixed pool-facing segment for the marker refresh to judge against, in
        the shape Get-PoolFacingIpv4Segment returns. Fixed rather than live so a
        case's verdict does not depend on the network the suite happens to run
        on -- the 192.168.64.x addresses these cases use are a real lab's LAN on
        one machine and a hypervisor-private vmnet on the next.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory descriptor; changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Address, [int]$PrefixLength = 24)
    $addrVal = ConvertTo-Ipv4UInt32 $Address
    # Built by arithmetic rather than by shifting a hex literal: PowerShell reads
    # 0xFFFFFFFF as a signed [int] (-1), which overflows every unsigned cast.
    $maskVal = [uint32][uint64](([Math]::Pow(2, $PrefixLength) - 1) * [Math]::Pow(2, 32 - $PrefixLength))
    return [pscustomobject]@{
        Address      = $Address
        AddressValue = $addrVal
        MaskValue    = $maskVal
        NetworkValue = [uint32]($addrVal -band $maskVal)
        PrefixLength = $PrefixLength
    }
}

function Get-StashDiscoveryCallCount {
    <#
    .SYNOPSIS
        How many times the substituted Get-VMIp has been asked since the last
        Set-StashDiscovery. A case asserts on this to show the poll did not
        stop on the first reply.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Test fixture: reads the counter the substituted discovery keeps; see Set-StashDiscovery.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return [int]$global:StashIpCalls
}

Describe 'An address is confirmed before it is advertised' {

    It 'polls past a dead predecessor and publishes the live guest' {
        # The incident this exists for: a rebuilt VM has not taken its lease
        # yet, so the only block bearing its name is the previous
        # incarnation's. Accepting the first non-empty reply spends the whole
        # budget on tick one and advertises an address nothing answers.
        Set-StashDiscovery -IpAnswer @('192.168.64.11', '192.168.64.11', '192.168.64.5') -Healthy @('192.168.64.5')
        $dir = New-MarkerDir
        $url = Update-StashServiceMarkerAddress -RuntimeDir $dir -TimeoutSeconds 60 -PoolSegment (New-PoolSegment '192.168.64.1')
        Assert-Equal -Expected 'http://192.168.64.5' -Actual $url -Because 'the confirmed address is the one returned'
        Assert-Equal -Expected 'http://192.168.64.5' -Actual (Get-MarkerUrl $dir) -Because 'and the one written to the marker'
        Assert-True ((Get-StashDiscoveryCallCount) -gt 1) 'the poll did not stop on the first reply'
    }

    It 'publishes an unconfirmed address rather than none when the budget runs out' {
        # By the time the budget is gone the stale-lease window is long past,
        # so the candidate is the live VM whose daemon is merely slower than
        # the budget. Dropping it would trade this bug for the opposite one.
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @()
        $dir = New-MarkerDir
        $url = Update-StashServiceMarkerAddress -RuntimeDir $dir -TimeoutSeconds 0 -PoolSegment (New-PoolSegment '192.168.64.1') -WarningVariable warned -WarningAction SilentlyContinue
        Assert-Equal -Expected 'http://192.168.64.5' -Actual $url -Because 'a correct address is not thrown away'
        Assert-True ($warned.Count -gt 0) 'and publishing it unconfirmed is said out loud'
    }

    It 'never re-advertises a marker that is being torn down' {
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @('192.168.64.5')
        $dir = New-MarkerDir -Json '{"active":false,"vmName":"yuruna-stash-service"}'
        Assert-True ($null -eq (Update-StashServiceMarkerAddress -RuntimeDir $dir)) 'an inactive marker resolves nothing'
        Assert-Equal -Expected 0 -Actual (Get-StashDiscoveryCallCount) -Because 'a torn-down marker is not even resolved'
    }

    It 'is a no-op when there is no marker' {
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @('192.168.64.5')
        $absent = Join-Path $StashTestHome 'no-such-runtime-dir'
        Assert-True ($null -eq (Update-StashServiceMarkerAddress -RuntimeDir $absent)) 'a host running no stash service is untouched'
    }

    It 'leaves the marker alone when discovery reports nothing' {
        # A VM that has not booted far enough to have any address must not
        # cause a marker rewrite, let alone a blank one.
        Set-StashDiscovery -IpAnswer @() -Healthy @()
        $dir = New-MarkerDir
        Assert-True ($null -eq (Update-StashServiceMarkerAddress -RuntimeDir $dir -TimeoutSeconds 0)) 'nothing resolved'
        Assert-True ([string]::IsNullOrEmpty((Get-MarkerUrl $dir))) 'and nothing was written'
    }
}

Describe 'Only an address the rest of the lab can reach is advertised' {

    It 'refuses an address that exists only inside this host' {
        # A stash VM on a hypervisor-private network (macOS shared vmnet,
        # Hyper-V Default Switch, libvirt virbr0) answers its own host and
        # nobody else. Advertising it puts that address in
        # host.registration.json, where every other host resolves it and spends
        # its whole timeout budget on a machine it cannot route to.
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @('192.168.64.5')
        $dir = New-MarkerDir
        $url = Update-StashServiceMarkerAddress -RuntimeDir $dir -PoolSegment (New-PoolSegment '192.168.7.101') `
            -WarningVariable warned -WarningAction SilentlyContinue
        Assert-True ($null -eq $url) 'a host-private address is not published'
        Assert-True ([string]::IsNullOrEmpty((Get-MarkerUrl $dir))) 'and never reaches the marker the registration reads'
        Assert-True ($warned.Count -gt 0) 'and the host is told why its stash is not in the pool'
    }

    It 'retracts an address published before the VM moved off the segment' {
        # A rebuild can land the VM on the private network with the previous,
        # routable address already advertised. Leaving it in place would keep
        # feeding the pool an address it cannot reach.
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @('192.168.64.5')
        $dir = New-MarkerDir -Json '{"active":true,"vmName":"yuruna-stash-service","stashBaseUrl":"http://192.168.7.217"}'
        $null = Update-StashServiceMarkerAddress -RuntimeDir $dir -PoolSegment (New-PoolSegment '192.168.7.101') `
            -WarningAction SilentlyContinue
        Assert-True ([string]::IsNullOrEmpty((Get-MarkerUrl $dir))) 'the stale advertisement is withdrawn'
        $kept = Get-Content -Raw -LiteralPath (Join-Path $dir 'stash-service.json') | ConvertFrom-Json
        Assert-Equal -Expected 'yuruna-stash-service' -Actual $kept.vmName -Because 'and the rest of the marker survives'
    }

    It 'publishes when the pool-facing segment cannot be determined' {
        # 'unknown' proves nothing. Reading it as a refusal would withdraw a
        # working stash from the pool on any host whose routing table this
        # cannot read.
        Set-StashDiscovery -IpAnswer @('192.168.64.5') -Healthy @('192.168.64.5')
        $dir = New-MarkerDir
        $url = Update-StashServiceMarkerAddress -RuntimeDir $dir -PoolSegment $null
        Assert-Equal -Expected 'http://192.168.64.5' -Actual $url -Because 'an undetermined segment does not refuse'
    }
}

Describe 'Superseded lease blocks are selected, and only those' {

    It 'keeps the largest expiry of a name and selects the rest' {
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        Assert-Equal -Expected 1 -Actual $stale.Count -Because 'only the superseded block is selected'
        Assert-Equal -Expected '192.168.64.11' -Actual $stale[0].IpAddress -Because 'the older expiry is the superseded one'
    }

    It 'agrees with the resolver about which block is live' {
        # A pruner that removed the block the resolver would have picked would
        # be worse than the duplication it set out to fix.
        $live = Select-DhcpLeaseIpAddress -LeaseText $StaleLeaseText -Name @('yuruna-stash-service') -OnLinkVerdict { 'unknown' }
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        Assert-True ($stale.IpAddress -notcontains $live) "the resolver's answer ($live) is never selected for removal"
    }

    It 'leaves a name that carries only one block alone' {
        # Right or wrong, a singleton is the only answer a lookup can give for
        # that name; removing it loses history and changes no resolution.
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        Assert-True ($stale.Name -notcontains 'lonely-guest') 'the single-block name is untouched'
    }

    It 'lets a responding address veto its own removal' {
        # An observation outranks an expiry heuristic: something is using it.
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'inuse' })
        Assert-Equal -Expected 0 -Actual $stale.Count -Because 'nothing that answers is removed'
    }

    It 'does not treat an unrunnable probe as a veto' {
        # 'unknown' means the probe could not be run. Reading that as in-use
        # would select nothing at all on a host where probing is unavailable.
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        Assert-Equal -Expected 1 -Actual $stale.Count -Because 'an unknown verdict still allows selection'
    }

    It 'keeps both blocks of a tie' {
        $tied = $StaleLeaseText -replace '0x6a6c58b9', '0x6a6c5940'
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $tied -InUseVerdict { 'unknown' })
        Assert-Equal -Expected 0 -Actual $stale.Count -Because 'two blocks with one expiry cannot be told apart'
    }

    It 'honours a name scope' {
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -Name @('lonely-guest') -InUseVerdict { 'unknown' })
        Assert-Equal -Expected 0 -Actual $stale.Count -Because 'a scoped run considers only the names given'
    }

    It 'returns nothing for empty or absent text' {
        Assert-Equal -Expected 0 -Actual @(Select-StaleDhcpLeaseBlock -LeaseText '' -InUseVerdict { 'unknown' }).Count
        Assert-Equal -Expected 0 -Actual @(Select-StaleDhcpLeaseBlock -LeaseText $null -InUseVerdict { 'unknown' }).Count
    }
}

Describe 'Removal cuts whole blocks and nothing else' {

    It 'removes the selected block and leaves the others byte-identical' {
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        $after = Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block $stale
        Assert-True ($after -notmatch '192\.168\.64\.11') 'the superseded block is gone'
        Assert-True ($after -match '192\.168\.64\.5')  'the live block survives'
        Assert-True ($after -match '192\.168\.64\.77') 'the unrelated name survives'
        Assert-Equal -Expected 2 -Actual ([regex]::Matches($after, '\{[^}]*\}')).Count -Because 'exactly one block was cut'
    }

    It 'still resolves the live guest afterwards' {
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        $after = Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block $stale
        $live = Select-DhcpLeaseIpAddress -LeaseText $after -Name @('yuruna-stash-service') -OnLinkVerdict { 'unknown' }
        Assert-Equal -Expected '192.168.64.5' -Actual $live -Because 'pruning does not disturb resolution'
    }

    It 'leaves no run of blank lines behind' {
        # The block's trailing newline goes with it, so a file pruned many
        # times does not accumulate whitespace the DHCP server never wrote.
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        $after = Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block $stale
        Assert-True ($after -notmatch "`n`n`n") 'no blank-line run appears'
    }

    It 'is idempotent' {
        $stale = @(Select-StaleDhcpLeaseBlock -LeaseText $StaleLeaseText -InUseVerdict { 'unknown' })
        $after = Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block $stale
        Assert-Equal -Expected 0 -Actual @(Select-StaleDhcpLeaseBlock -LeaseText $after -InUseVerdict { 'unknown' }).Count -Because 'a second pass finds nothing'
        Assert-Equal -Expected $after -Actual (Remove-DhcpLeaseBlockText -LeaseText $after -Block $stale) -Because 'removing an absent block changes nothing'
    }

    It 'ignores a block that is no longer in the text' {
        # The DHCP server rewrites this file whenever a lease moves; a block
        # that vanished under us is already gone, not an error.
        $ghost = [pscustomobject]@{ Text = "{`n`tname=ghost`n`tip_address=192.168.64.200`n`tlease=0x1`n}" }
        Assert-Equal -Expected $StaleLeaseText -Actual (Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block @($ghost))
    }

    It 'accepts an empty removal set' {
        Assert-Equal -Expected $StaleLeaseText -Actual (Remove-DhcpLeaseBlockText -LeaseText $StaleLeaseText -Block @())
    }
}

Remove-Item -Path 'Function:\Get-VMIp' -ErrorAction SilentlyContinue
Remove-Item -Path 'Function:\Test-StashServiceHost' -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $StashTestHome) {
    Remove-Item -LiteralPath $StashTestHome -Recurse -Force -ErrorAction SilentlyContinue
}
