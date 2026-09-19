<#PSScriptInfo
.VERSION 2026.09.18
.GUID 426d4c3d-0ae7-41c9-8bac-5f42f9255e5b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna kvm libvirt rail guest-to-guest addressing
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

# --- REGION: https://yuruna.link/4220a755-0019
# A second, stable libvirt-NAT address per guest, for guests that must reach
# EACH OTHER. KVM-only: every consumer treats a rail address as an optimization
# that may be absent, never as a dependency.
# NOTHING CALLS THIS. Get-GuestRailAddress keys on the transient VM name, so
# wiring it back as it stands breaks VM creation on the second guest of every
# cycle. It is kept for the derivation and its tests --
# https://yuruna.link/4220a755-001a

Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:RailNetwork = 'default'
# The band reservations are allocated from. Inside libvirt's default DHCP range
# (192.168.122.2-254), because dnsmasq only serves a reservation that falls
# within the range it is authoritative for. High end of it, leaving the low
# addresses to anything that asks dynamically.
$script:RailFirstOctet = 200
$script:RailLastOctet  = 249
$script:RailPrefix     = '192.168.122'

function Test-GuestRailAvailable {
<#
.SYNOPSIS
    $true when this host can offer a guest-to-guest rail.
.DESCRIPTION
    Both halves are required and neither is guaranteed: virsh has to be present
    (it is not, on the other host types this workload runs on) and the NAT
    network has to be active. Every caller is expected to carry on without a
    rail when this is false -- that is the normal case on two of the three host
    types, not a fault.
.OUTPUTS
    System.Boolean
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) { return $false }
    # net-list --name lists exactly the active networks, one name per line, and
    # a network name is not translated. Reading net-info's "Active: yes" instead
    # would put both the field label and the answer through gettext, so a host
    # in another language would report every network inactive and quietly drop
    # the rail on hosts that have one.
    $active = & virsh net-list --name 2>$null
    foreach ($name in @($active)) {
        if ("$name".Trim() -eq $script:RailNetwork) { return $true }
    }
    return $false
}

function Get-GuestRailAddress {
<#
.SYNOPSIS
    The rail MAC and address a guest of this name should hold.
.DESCRIPTION
    Derived from the name rather than allocated, so the answer is the same on
    every call, in any process, before the VM exists and after it is gone. That
    is what lets a reservation be re-asserted idempotently and a peer's
    coordinate be known without a lookup.

    The MAC uses the 52:54:00 QEMU prefix so it reads as a KVM guest in any
    capture, with the low three bytes from the name digest. The address takes the
    band's width modulo that same digest; the band is narrower than the digest,
    so two names CAN land on one address, which is why Register-GuestRailAddress
    resolves the collision at reservation time rather than pretending it cannot
    happen.
.PARAMETER VMName
    Guest name. Case-insensitive: libvirt domain names are compared that way,
    and two spellings of one guest must not get two rail addresses.
.OUTPUTS
    PSCustomObject with VMName, Mac and Ip.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($VMName.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    $span   = $script:RailLastOctet - $script:RailFirstOctet + 1
    $octet  = $script:RailFirstOctet + (([int]$digest[0] * 256 + [int]$digest[1]) % $span)
    $mac    = '52:54:00:{0:x2}:{1:x2}:{2:x2}' -f $digest[2], $digest[3], $digest[4]
    return [pscustomobject]@{
        VMName = $VMName
        Mac    = $mac
        Ip     = "$($script:RailPrefix).$octet"
    }
}

function Get-GuestRailReservation {
<#
.SYNOPSIS
    The rail reservations libvirt currently holds, as name/mac/ip rows.
.OUTPUTS
    PSCustomObject[]; empty when there are none or the rail is unavailable.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    if (-not (Test-GuestRailAvailable)) { return [pscustomobject[]]@() }
    $xml = (& virsh net-dumpxml $script:RailNetwork 2>$null) -join "`n"
    if (-not $xml) { return [pscustomobject[]]@() }
    $rows = foreach ($m in [regex]::Matches($xml, "<host\s+mac='(?<mac>[^']+)'\s+name='(?<name>[^']*)'\s+ip='(?<ip>[^']+)'\s*/>")) {
        [pscustomobject]@{
            Mac    = $m.Groups['mac'].Value
            VMName = $m.Groups['name'].Value
            Ip     = $m.Groups['ip'].Value
        }
    }
    return [pscustomobject[]]@($rows)
}

function Register-GuestRailAddress {
<#
.SYNOPSIS
    Pin this guest's rail address and name in libvirt, idempotently.
.DESCRIPTION
    Re-asserting an identical reservation is a no-op, so this is safe to call on
    every VM creation. An entry for the same guest with different values is
    replaced rather than added beside, because libvirt would otherwise serve
    whichever it reached first and the guest's address would depend on the order
    of a file.

    Address collisions are resolved here rather than assumed away: the derived
    address is the preference, and when a DIFFERENT guest already holds it the
    band is walked until a free one is found. That keeps the derivation useful
    for the common case while staying correct in the case it cannot cover.

    Returns the reservation actually made, or $null when the rail is
    unavailable -- which is a normal answer on a host without libvirt, not an
    error, so nothing here throws for it.
.PARAMETER VMName
    Guest to reserve for.
.OUTPUTS
    PSCustomObject with VMName, Mac and Ip, or $null.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Test-GuestRailAvailable)) {
        Write-Verbose "Register-GuestRailAddress: no libvirt rail on this host; '$VMName' will run without one."
        return $null
    }
    $want     = Get-GuestRailAddress -VMName $VMName
    $existing = @(Get-GuestRailReservation)
    $mine     = @($existing | Where-Object { $_.VMName -eq $VMName })
    if ($mine.Count -eq 1 -and $mine[0].Mac -eq $want.Mac -and $mine[0].Ip -eq $want.Ip) {
        Write-Verbose "Register-GuestRailAddress: '$VMName' already reserved at $($want.Ip)."
        return $want
    }
    foreach ($stale in $mine) {
        if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_43a3bbcab70a1061' -Arguments @{ ip = "$($stale.Ip)" }))) { continue }
        $null = & virsh net-update $script:RailNetwork delete ip-dhcp-host `
            ("<host mac='{0}' name='{1}' ip='{2}'/>" -f $stale.Mac, $stale.VMName, $stale.Ip) --live --config 2>&1
    }
    # Someone else on the address: walk the band. Bounded by the band itself, so
    # a full band reports rather than looping.
    $taken = @($existing | Where-Object { $_.VMName -ne $VMName } | ForEach-Object { $_.Ip })
    $ip    = $want.Ip
    if ($taken -contains $ip) {
        $ip = $null
        for ($o = $script:RailFirstOctet; $o -le $script:RailLastOctet; $o++) {
            $candidate = "$($script:RailPrefix).$o"
            if ($taken -notcontains $candidate) { $ip = $candidate; break }
        }
        if (-not $ip) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_df10f38143b3b549' -Arguments @{ railPrefix = "$($script:RailPrefix)"; railFirstOctet = "$($script:RailFirstOctet)"; railLastOctet = "$($script:RailLastOctet)"; vMName = "$VMName" })
            return $null
        }
        Write-Verbose "Register-GuestRailAddress: '$VMName' derives $($want.Ip), which another guest holds; using $ip."
    }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_e97a5320d78112ee' -Arguments @{ ip = "$ip" }))) { return $null }
    $entry  = "<host mac='{0}' name='{1}' ip='{2}'/>" -f $want.Mac, $VMName, $ip
    $output = & virsh net-update $script:RailNetwork add ip-dhcp-host $entry --live --config 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_82d7b4c9909ca4dd' -Arguments @{ ip = "$ip"; vMName = "$VMName"; join = "$($output -join ' ')" })
        return $null
    }
    return [pscustomobject]@{ VMName = $VMName; Mac = $want.Mac; Ip = $ip }
}

function Unregister-GuestRailAddress {
<#
.SYNOPSIS
    Release this guest's rail reservation.
.DESCRIPTION
    Called from the same teardown that removes the domain. Leaving reservations
    behind would eventually exhaust the band and, worse, hand a recycled VM name
    an address that dnsmasq still associates with a MAC the new guest does not
    have -- so the name would resolve to somewhere nothing answers.

    Removal is best-effort and never throws: teardown must not fail because a
    reservation was already gone.
.PARAMETER VMName
    Guest to release.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Test-GuestRailAvailable)) { return }
    foreach ($row in @(Get-GuestRailReservation | Where-Object { $_.VMName -eq $VMName })) {
        if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_868207db699b0be7' -Arguments @{ ip = "$($row.Ip)" }))) { continue }
        $output = & virsh net-update $script:RailNetwork delete ip-dhcp-host `
            ("<host mac='{0}' name='{1}' ip='{2}'/>" -f $row.Mac, $row.VMName, $row.Ip) --live --config 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "Unregister-GuestRailAddress: '$VMName' at $($row.Ip) -- $($output -join ' ')"
        }
    }
}

# --- REGION: Exports
Export-ModuleMember -Function Test-GuestRailAvailable, Get-GuestRailAddress, Get-GuestRailReservation,
    Register-GuestRailAddress, Unregister-GuestRailAddress
