<#PSScriptInfo
.VERSION 2026.09.12
.GUID 4204dc0d-3f1d-4015-b639-9480d7186c23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest network diagnostic ocr pester
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
    Guard: the guest network diagnostic must name a down link instead of
    reporting an all-clear over it, and must stay bounded.
.DESCRIPTION
    On a guest that never got an IPv4 address there is no SSH and no HTTP
    path back, so the console capture the host OCRs is the only artifact the
    failure leaves. Its correctness is therefore disproportionately
    load-bearing, and two properties are asserted here:

      * A link with no carrier is its own verdict. It never reaches DHCP, so
        a lease-pool diagnosis printed over it points at the wrong subsystem,
        and "all carrier-up interfaces hold an address" is vacuously true when
        nothing was carrier-up at all.
      * The verdict block is a fixed size. It is printed immediately before
        the marker the host matches on a failing run, and the capture surface
        holds a bounded number of trailing lines -- output that grows with
        interface count pushes the marker out of the captured frame and turns
        a classified failure into an unclassified timeout.

    The shell function is lifted out of the file with the parser-free
    extraction the sibling fetch-and-execute suite uses, and driven under bash
    against a fixture tree it builds itself, so there is no host path to
    translate. Fixture interfaces are named yurunatest* because the sysfs seam
    covers only the interface WALK: addresses are still read with a live
    `ip -4 -o address show dev <if>`, so a fixture named eth0 would collide
    with a real eth0 on the machine running the suite and the address-less
    branch would report a green change as red. The suite passes (skips) where
    bash is unavailable.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$script:netLib   = Join-Path $repoRoot 'automation' -AdditionalChildPath 'yuruna-network.sh'
$script:faePath  = Join-Path $repoRoot 'automation' -AdditionalChildPath 'fetch-and-execute.sh'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-ShellFunctionText {
    param([string]$Path, [string[]]$Name)
    $src = Get-Content -Raw -LiteralPath $Path
    $parts = foreach ($n in $Name) {
        $m = [regex]::Match($src, "(?ms)^$([regex]::Escape($n))\(\)\s*\{.*?^\}")
        if (-not $m.Success) { throw "$n not found in $Path" }
        $m.Value
    }
    return ($parts -join "`n")
}

# network_diag calls _yuruna_net_admin_down to tell an administratively-down
# link from one that lost carrier, so the helper has to be extracted with it.
# Left out, the call is a "command not found" -- which reads as false and lands
# every down link on the carrier verdict, so the suite would pass while testing
# only half the branch. Asserted directly in the fail-safe case below. The
# client-state pair is extracted for the same reason: absent, the probe is a
# silent no-op and every assertion about what the report contains would be
# measuring a report that never ran it.
function Get-DiagFunctionText {
    return (Get-ShellFunctionText -Path $script:netLib -Name `
        '_yuruna_net_admin_down', '_yuruna_net_journal_slice', '_yuruna_net_client_state', 'network_diag')
}

# Runs an extracted shell function under a driver that builds its own fixture
# tree, so nothing depends on a Windows path surviving translation into bash.
#
# The journal command the client-state probe runs is pinned to one that prints
# nothing, so a suite running on a machine whose journal happens to hold DHCP
# lines measures the same report as one running where it does not. A test that
# wants journal content passes its own on the command line, which overrides
# this default for that call only.
function Invoke-ShellDriver {
    param([string]$FunctionText, [string]$Driver)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { return $null }
    $script = ": `"`${YURUNA_NET_JOURNAL:=true}`"`nexport YURUNA_NET_JOURNAL`n" + $FunctionText + "`n" + $Driver
    return ($script | & $bash.Source 2>$null | Out-String)
}

# A fixture tree of $Count down interfaces, named so they cannot collide with
# a real adapter on the machine running the suite.
#
# -Flags writes the sysfs flags word the real kernel exposes, whose bit 0 is
# IFF_UP. Omitted, no flags file is written at all -- the shape an interface
# fixture had before the two down states were told apart, kept as a case in its
# own right because a guest whose sysfs cannot be read must still get the
# verdict that does not accuse its host.
function Get-DownLinkDriver {
    param([int]$Count, [switch]$LineCountOnly, [string]$Flags, [string]$Carrier)
    $tail = if ($LineCountOnly) { 'YURUNA_NET_SYSFS="$root" network_diag | wc -l' } else { 'YURUNA_NET_SYSFS="$root" network_diag' }
    $extra = ''
    if ($Flags)   { $extra += "`n    echo $Flags > `"`$root/yurunatest`$i/flags`"" }
    if ($Carrier) { $extra += "`n    echo $Carrier > `"`$root/yurunatest`$i/carrier`"" }
    return @"

root=`$(mktemp -d)
i=0
while [ `$i -lt $Count ]; do
    mkdir -p "`$root/yurunatest`$i"
    echo down > "`$root/yurunatest`$i/operstate"$extra
    i=`$((i + 1))
done
$tail
rm -rf "`$root"
"@
}

}

Describe 'guest-network-diag: a link with no carrier is its own verdict' {

    It 'reports LINK DOWN and does not claim the carrier-up interfaces are healthy' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 2)
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'LINK DOWN on 2 interface\(s\)') "the down links must be named; output was:`n$out"
        Assert-True ($out -match 'yurunatest0\(operstate=down,carrier=none\)') 'carrier reads back empty on a down interface, so it is reported as none'
        Assert-True ($out -notmatch 'All carrier-up interfaces hold an IPv4 address') `
            'an all-clear over a dead link is vacuously true and sends the reader after the wrong subsystem'
        Assert-True ($out -notmatch 'DHCP POOL EXHAUSTION') 'a down link never reaches DHCP, so lease-pool causes do not apply'
    }

    It 'reports no-IPv4 without asserting a cause it cannot observe' {
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/yurunatest0"
echo up > "$root/yurunatest0/operstate"
echo 1  > "$root/yurunatest0/carrier"
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'NO IPv4 ADDRESS on carrier-up interface\(s\):\s*yurunatest0') "the addressless verdict must survive; output was:`n$out"
        Assert-True ($out -notmatch 'DHCP POOL EXHAUSTION IS A POSSIBILITY') `
            'free leases live on the DHCP server; a guest cannot see them, so it must not headline that guess'
        # The order is the fix. A guest that has simply not been answered yet is
        # the common case and the only one the guest can act on, so it leads;
        # the pool is named last and explicitly marked unobservable, because
        # leading with it is what sends a reader to audit a server whose pool is
        # mostly free.
        Assert-True ($out -match 'has not landed YET') 'the recoverable case must be offered first'
        Assert-True ($out -match 'not observable from here') `
            'the pool must be marked as something only the DHCP server can confirm'
        Assert-True ($out.IndexOf('has not landed YET') -lt $out.IndexOf('no free lease')) `
            'the not-yet case must precede the pool case, not merely appear somewhere'
        Assert-True ($out -notmatch 'LINK DOWN') 'a carrier-up interface is not a down link'
    }

    It 'says so when nothing was examined at all instead of printing an all-clear' {
        $driver = @'

root=$(mktemp -d)
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'No non-loopback interface is carrier-up\.') "an empty walk must say so; output was:`n$out"
        Assert-True ($out -notmatch 'All carrier-up interfaces hold an IPv4 address') 'the all-clear must be gated on having examined something'
        Assert-True ($out -notmatch 'LINK DOWN') 'an unmatched glob is not a down interface'
    }
}

Describe 'guest-network-diag: the two down states are different faults' {

    # A link with IFF_UP clear was taken down by something on this machine. No
    # switch, cable or DHCP server can produce that state, so the carrier
    # verdict's "the cause is outside this machine" is provably wrong for it --
    # and wrong in the expensive direction, because the host it accuses is
    # usually healthy and provably so, while the guest that is actually at
    # fault goes unexamined.
    It 'names an administratively-down link as guest-side and does not blame the host' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 1 -Flags '0x1002')
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'DOWN INSIDE THIS GUEST on 1 interface\(s\)') "the guest-side verdict must lead; output was:`n$out"
        Assert-True ($out -match 'yurunatest0\(operstate=down,flags=0x1002\)') 'the flags word is the evidence, so it must be shown'
        Assert-True ($out -notmatch 'LINK DOWN') 'a link held down from inside is not a carrier fault'
        Assert-True ($out -notmatch 'cause is outside') 'nothing outside this machine can clear IFF_UP'
        Assert-True ($out -notmatch 'DHCP POOL EXHAUSTION') 'a down link never reaches DHCP, so lease-pool causes do not apply'
    }

    It 'still calls a carrier loss external when IFF_UP is set' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 1 -Flags '0x1003' -Carrier '0')
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'LINK DOWN on 1 interface\(s\)') "carrier loss keeps its own verdict; output was:`n$out"
        Assert-True ($out -match 'cause is outside') 'IFF_UP set with no carrier is driven by the far end'
        Assert-True ($out -notmatch 'DOWN INSIDE THIS GUEST') 'an interface this machine holds up was not held down by it'
    }

    It 'reports both when both are present rather than suppressing one' {
        # Separate interfaces in separate states are separate faults. Printing
        # only the first would hide a real cause to shorten the report.
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/yurunatest0" "$root/yurunatest1"
echo down   > "$root/yurunatest0/operstate"
echo 0x1002 > "$root/yurunatest0/flags"
echo down   > "$root/yurunatest1/operstate"
echo 0x1003 > "$root/yurunatest1/flags"
echo 0      > "$root/yurunatest1/carrier"
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'DOWN INSIDE THIS GUEST on 1 interface\(s\)') "the guest-side fault must appear; output was:`n$out"
        Assert-True ($out -match 'LINK DOWN on 1 interface\(s\)') 'the carrier fault must appear too'
    }

    # Both fail-safe directions. The guest-side verdict requires POSITIVE proof
    # that IFF_UP is clear, so an unreadable flags word -- and the predicate not
    # being defined at all, which a single-function extraction produces -- must
    # land on the verdict that does not accuse the host.
    It 'falls back to the carrier verdict when the flags word is unreadable' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 1)
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'LINK DOWN on 1 interface\(s\)') "no flags file must not become a guest-side accusation; output was:`n$out"
        Assert-True ($out -notmatch 'DOWN INSIDE THIS GUEST') 'an unknown flags word is not proof the link was held down'
    }

    It 'falls back to the carrier verdict when the predicate is not defined at all' {
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $script:netLib -Name 'network_diag') `
                                  -Driver (Get-DownLinkDriver -Count 1 -Flags '0x1002')
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'LINK DOWN on 1 interface\(s\)') "a missing predicate must degrade to the carrier verdict; output was:`n$out"
        Assert-True ($out -notmatch 'DOWN INSIDE THIS GUEST') 'the guest-side verdict must never fire by accident'
    }

    It 'keeps the guest-side verdict a fixed size too' {
        $fn = Get-DiagFunctionText
        $few  = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 2  -Flags '0x1002' -LineCountOnly)
        if ($null -eq $few) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $many = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 30 -Flags '0x1002' -LineCountOnly)
        Assert-StringEqual -Expected ([int]$few.Trim()) -Actual ([int]$many.Trim()) `
            'the verdict block must be a fixed size regardless of how many interfaces are held down'
    }
}

Describe 'guest-network-lib: a release never acts on an interface it does not recognize' {

    # network_diag uses a deny-list and network_release an allow-list, and the
    # asymmetry is the point: a diagnostic that meets an unknown interface should
    # name it, an actor that meets one must leave it alone. The names a CNI
    # invents are open-ended, so a deny-list that misses one takes down a
    # cluster's data plane while trying to return a DHCP lease.
    It 'skips CNI and virtual devices, and accepts physical NIC names' {
        $driver = @'

root=$(mktemp -d)
# Only the physical-looking ones get a device link, which is what sysfs gives
# real hardware and withholds from veth/bridge/dummy/CNI devices.
for n in enp1s0 eth0 wlp2s0; do mkdir -p "$root/$n/device"; done
for n in cali1a2b3c vxlan.calico tunl0 cilium_host lxc0abc nodelocaldns kube-ipvs0 docker0 veth9f2 br-abc virbr0 flannel.1 cni0; do mkdir -p "$root/$n"; done
export YURUNA_NET_SYSFS="$root"
for d in "$root"/*; do
    n=$(basename "$d")
    if _yuruna_net_is_physical "$n"; then echo "ACT $n"; else echo "SKIP $n"; fi
done
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_is_physical') -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        foreach ($n in @('enp1s0', 'eth0', 'wlp2s0')) {
            Assert-True ($out -match "ACT $([regex]::Escape($n))\b") "a physical NIC must be releasable; output was:`n$out"
        }
        foreach ($n in @('cali1a2b3c', 'vxlan.calico', 'tunl0', 'cilium_host', 'lxc0abc', 'nodelocaldns', 'kube-ipvs0', 'docker0', 'veth9f2', 'br-abc', 'virbr0', 'flannel.1', 'cni0')) {
            Assert-True ($out -match "SKIP $([regex]::Escape($n))\b") "$n is not a physical NIC and a release must not touch it"
        }
    }

    It 'never disables networking globally, on either stack' {
        # A global disable persists in NetworkManager.state and outlives both
        # the teardown that issued it and every reboot after it, on a guest
        # whose console is the only way back in.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'network_release'
        Assert-True ($fn -notmatch 'nmcli\s+networking\s+off') 'a release must scope to connections, never to the whole stack'
        Assert-True ($fn -match 'nmcli connection down') 'the NetworkManager stack needs its own release path'
        Assert-True ($fn -match 'dhcp-send-release') 'NM does not return the address on deactivation unless asked'
        Assert-True ($fn -match 'networkctl down') 'the systemd-networkd path must survive'
    }
}

Describe 'guest-network-diag: the report stays inside the captured frame' {

    It 'emits the same number of lines for 2 down interfaces as for 30' {
        # The marker the host matches sits a few lines below this output, and
        # the headless capture surface freezes a bounded number of trailing
        # lines. Output that grows per interface scrolls the marker away and
        # turns a classified failure into an unclassified timeout.
        $fn = Get-DiagFunctionText
        $few  = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 2  -LineCountOnly)
        if ($null -eq $few) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $many = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 30 -LineCountOnly)
        Assert-StringEqual -Expected ([int]$few.Trim()) -Actual ([int]$many.Trim()) `
            'the verdict block must be a fixed size regardless of how many interfaces are down'
        Assert-True ([int]$few.Trim() -gt 0) 'the line count must actually have been measured'
    }

    It 'names at most three down interfaces but reports the true total' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 30)
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'LINK DOWN on 30 interface\(s\)') "the count must be the real one; output was:`n$out"
        $named = ([regex]::Matches($out, 'yurunatest\d+\(operstate=')).Count
        Assert-True ($named -le 3) "at most three interfaces may be named inline, found $named"
        Assert-True ($named -ge 1) 'at least one must be named, or the verdict says nothing actionable'
    }
}

Describe 'guest-network-diag: the client is asked, not merely recommended' {

    # The verdict block bottoms out at "no address", which cannot separate a
    # lease that is late from a client that stopped asking -- and those two
    # indict different machines. The answer is in the client's own state, on a
    # guest destroyed at cleanup minutes later, so a report that only tells the
    # reader which command to run is a report of a question nobody can ask.
    It 'runs the client-state probe from the report itself' {
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'network_diag'
        Assert-True ($fn -match '_yuruna_net_client_state "\$\{probe_ifc:-\$probe_admin\}"') `
            'the probe must run inside the report, on the interface the verdict just named'
        Assert-True ($fn -notmatch "Ask the client") `
            'the text must not send the reader after state that will not exist by the time they read it'
    }

    It 'prints what the client is doing for an address-less interface' {
        $driver = @'

stub=$(mktemp)
printf '#!/bin/bash\nprintf "%%s\\n" "enp1s0: DHCPv4 client: Sending DISCOVER" "enp1s0: DHCPv4 client: Sending DISCOVER"\n' > "$stub"
chmod +x "$stub"
root=$(mktemp -d)
mkdir -p "$root/yurunatest0"
echo up > "$root/yurunatest0/operstate"
echo 1  > "$root/yurunatest0/carrier"
YURUNA_NET_SYSFS="$root" YURUNA_NET_JOURNAL="$stub" network_diag
rm -rf "$root" "$stub"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'DHCP client state \(yurunatest0\)') "the probe must name the interface it asked about; output was:`n$out"
        Assert-True ($out -match 'Sending DISCOVER') 'a client still soliciting must be visible in the report'
    }

    It 'says so when the client has nothing to say, instead of printing an empty block' {
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/yurunatest0"
echo up > "$root/yurunatest0/operstate"
echo 1  > "$root/yurunatest0/carrier"
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'no DHCP line in the client journal') `
            "a silent journal is itself the finding and must be stated; output was:`n$out"
    }

    It 'asks about one interface however many are address-less' {
        # The probe is the only unbounded thing in the report: each block is
        # several lines of another program's output, and the marker the host
        # matches sits just below it.
        $driver = @'

root=$(mktemp -d)
i=0
while [ $i -lt 6 ]; do
    mkdir -p "$root/yurunatest$i"
    echo up > "$root/yurunatest$i/operstate"
    echo 1  > "$root/yurunatest$i/carrier"
    i=$((i + 1))
done
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $blocks = ([regex]::Matches($out, 'DHCP client state \(')).Count
        Assert-StringEqual -Expected 1 -Actual $blocks 'exactly one client-state block may print, whatever the interface count'
    }

    It 'prints nothing at all when no interface needs explaining' {
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver (Get-DownLinkDriver -Count 2)
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -notmatch 'DHCP client state') `
            'a link with no carrier never reached DHCP, so its client state explains nothing'
    }

    It 'caps the journal slice rather than printing the unit log' {
        # The cap is a frame budget, not a preference: this block lands
        # immediately above the marker the host matches, and the capture
        # surface freezes a bounded number of trailing lines. Every line
        # added here is paid for by one removed from the static prose in
        # network_diag's addressless verdict.
        $driver = @'

stub=$(mktemp)
cat > "$stub" <<'STUB'
#!/bin/bash
i=0
while [ $i -lt 40 ]; do echo "enp1s0: DHCPv4 client: Sending DISCOVER $i"; i=$((i + 1)); done
STUB
chmod +x "$stub"
YURUNA_NET_JOURNAL="$stub" _yuruna_net_client_state yurunatest0 | grep -c 'Sending DISCOVER'
rm -f "$stub"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-DiagFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ([int]$out.Trim() -le 7) "the slice must stay bounded; printed $($out.Trim()) lines"
        Assert-True ([int]$out.Trim() -gt 0) 'the slice must actually print what it found'
    }

    It 'keeps the lines the client volunteers about which profile claimed the NIC' {
        # A NIC no profile matched reports "Network File: n/a", and that is the
        # shape where DHCP is never attempted at all -- a different fault from a
        # lease that did not come, with a different repair.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_client_state'
        Assert-True ($fn -match 'Network File') 'the claiming profile is the evidence for the never-attempted shape'
        Assert-True ($fn -match 'DHCP4 Client ID') 'the identity in use is what a lease keyed on client-id turns on'
    }

    It 'keeps ordering in the slice, which is what separates the three shapes' {
        # A late lease, a client that stopped asking, and a lease the server
        # ACKed that was never installed all bottom out at "no address". Only
        # the order and spacing of the client's own lines tell them apart, so
        # the timestamp is load-bearing -- but only the time part of it: the
        # date, hostname and unit prefix would wrap the line on the console
        # this is read back from.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_journal_slice'
        Assert-True ($fn -match 'short-precise') 'the slice must carry timestamps'
        Assert-True ($fn -notmatch '\-o cat') 'a stripped timestamp cannot order the evidence'
        Assert-True ($fn -match 'sed') 'the date/hostname/unit prefix must be trimmed back off'
    }

    It 'reaches past the DHCP words into the address plane' {
        # The shape that motivates the timestamps leaves its evidence where a
        # dhcp|lease|carrier filter cannot see it: the refusal or error that
        # stopped an ACKed address from reaching the link.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_journal_slice'
        foreach ($word in 'address', 'not ready', 'could not set') {
            Assert-True ($fn -match [regex]::Escape($word)) "the slice must match '$word'"
        }
    }

    It 'never parks a console at a password prompt nobody can answer' {
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_journal_slice', '_yuruna_net_client_state'
        Assert-True ($fn -notmatch '(?m)(^|[^-\w])sudo\s+(?!-n)') `
            'every elevation in a console-only diagnostic must be non-interactive'
    }

    It 'reads unprivileged first and elevates only if that came back empty' {
        # Elevation is the fallback, not the default: most guests let the login
        # user read the system journal, and a run that always shells out to sudo
        # pays for it on every failing step.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_client_state'
        $plain = $fn.IndexOf('out=$(_yuruna_net_journal_slice)')
        $sudo  = $fn.IndexOf('_yuruna_net_journal_slice sudo -n')
        Assert-True ($plain -ge 0 -and $sudo -gt $plain) 'the unprivileged read must come first'
    }
}

Describe 'guest-network-diag: OCR-safe wording' {

    # The console frame is matched against the echoed command line to detect a
    # failing run. The words 'fetch' and 'execute' fuzzy-match that line, so
    # either one inside diagnostic output would fail a HEALTHY run in seconds.
    It 'network_diag prints neither of the words that fuzzy-match the command line' {
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'network_diag', '_yuruna_net_client_state'
        $echoed = @([regex]::Matches($fn, '(?m)^\s*echo\s+.*$') | ForEach-Object { $_.Value }) -join "`n"
        Assert-True ($echoed.Length -gt 0) 'the diagnostic must print something'
        Assert-True ($echoed -notmatch '(?i)fetch')   'no "fetch" in diagnostic output'
        Assert-True ($echoed -notmatch '(?i)execute') 'no "execute" in diagnostic output'
    }

    It 'the guest-has-no-IPv4 banner prints neither of them either' {
        $fn = Get-ShellFunctionText -Path $script:faePath -Name 'resolve_fetch_source'
        $banner = [regex]::Match($fn, '(?ms)GUEST HAS NO IPv4.*?FETCH_SOURCE=')
        Assert-True $banner.Success 'the no-IPv4 banner must exist'
        $printed = @([regex]::Matches($banner.Value, '(?m)^\s*>&2 echo\s+.*$') | ForEach-Object { $_.Value }) -join "`n"
        Assert-True ($printed.Length -gt 0) 'the banner must print something'
        Assert-True ($printed -notmatch '(?i)fetch')   'no "fetch" in the banner text'
        Assert-True ($printed -notmatch '(?i)execute') 'no "execute" in the banner text'
    }
}

Describe 'guest-source-resolution: a guest with no address does not blame the host' {

    # Every cause the HOST UNREACHABLE banner names is host-side and presumes
    # a working guest network. A guest holding no IPv4 reaches neither the host
    # nor GitHub, so that banner would lead the artifact with a theory that is
    # provably wrong.
    It 'prints GUEST HAS NO IPv4 instead of HOST UNREACHABLE, and still resolves to github' {
        # resolve_fetch_source sources /etc/yuruna/host.env when present, which
        # would supply its own values. A machine that has one is a guest, not a
        # test host.
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Set-ItResult -Skipped -Because 'this host is guest-shaped (/etc/yuruna/host.env present)'; return }
        $driver = @'

ip()   { :; }
wget() { return 1; }
YURUNA_STATUS_SERVICE_IP=10.0.0.1
YURUNA_STATUS_SERVICE_PORT=8080
resolve_fetch_source 2>&1
echo "SOURCE=$FETCH_SOURCE"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $script:faePath -Name 'resolve_fetch_source') -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'GUEST HAS NO IPv4') "the guest-side cause must lead; output was:`n$out"
        Assert-True ($out -notmatch 'HOST UNREACHABLE') 'the host-side theory must be suppressed when the guest holds no address'
        Assert-True ($out -match 'SOURCE=github') 'resolution must still fall through rather than stall'
    }

    It 'still prints HOST UNREACHABLE when the guest does hold an address' {
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Set-ItResult -Skipped -Because 'this host is guest-shaped (/etc/yuruna/host.env present)'; return }
        $driver = @'

ip()   { echo "2: yurunatest0    inet 10.0.0.5/24 scope global yurunatest0"; }
wget() { return 1; }
YURUNA_STATUS_SERVICE_IP=10.0.0.1
YURUNA_STATUS_SERVICE_PORT=8080
resolve_fetch_source 2>&1
echo "SOURCE=$FETCH_SOURCE"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $script:faePath -Name 'resolve_fetch_source') -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'HOST UNREACHABLE') "an addressed guest that cannot reach the host still gets the host-side banner; output was:`n$out"
        Assert-True ($out -notmatch 'GUEST HAS NO IPv4') 'the no-address banner must not fire for an addressed guest'
        Assert-True ($out -match 'SOURCE=github') 'resolution falls through to the off-LAN source'
    }
}

Describe 'guest-network-lib: the repair verb re-kicks without taking anything down' {

    # The repair exists precisely because a down that fails to pair with its
    # up outlives the boot that issued it. A regression that sneaks a down
    # into the repair path turns the self-heal into the fault it heals, so
    # the no-down property is pinned as hard as the dispatch itself.
    It 'contains no down verb in any form' {
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'yuruna_net_repair_ipv4'
        Assert-True ($fn -notmatch 'networkctl\s+down')  'networkd links must never be downed by the repair'
        Assert-True ($fn -notmatch 'connection\s+down')  'NM connections must never be downed by the repair'
        Assert-True ($fn -notmatch 'ip\s+link\s+set')    'raw link state must never be touched by the repair'
        Assert-True ($fn -notmatch 'networking\s+off')   'global networking must never be disabled by the repair'
    }

    It 'reloads before reconfiguring, so late-written profiles are in force' {
        # A .network drop-in written after the daemon started is invisible to
        # a reconfigure until a reload has landed it; reversed, the re-kick
        # re-runs the same configuration that already failed to produce a
        # lease.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'yuruna_net_repair_ipv4'
        $reloadAt = $fn.IndexOf('networkctl reload')
        $reconfAt = $fn.IndexOf('networkctl reconfigure')
        Assert-True ($reloadAt -ge 0 -and $reconfAt -ge 0 -and $reloadAt -lt $reconfAt) 'reload must precede reconfigure'
    }

    It 'leaves an interface that already holds an IPv4 alone, and re-kicks one that does not' {
        # A held lease is the one thing the repair must not spend: re-kicking
        # a healthy sibling trades its live address for a fresh transaction
        # against the very server that is failing to answer.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_sudo', '_yuruna_net_is_physical', 'yuruna_net_repair_ipv4'
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/enfixture0/device"
stubdir=$(mktemp -d)
printf '#!/bin/bash\necho "networkctl $*" >> "$YRN_STUB_LOG"\nexit 0\n' > "$stubdir/networkctl"
printf '#!/bin/bash\nexit 1\n' > "$stubdir/nmcli"
printf '#!/bin/bash\nif [ -n "$YRN_HAS_V4" ]; then echo "inet 192.0.2.9/24"; fi\nexit 0\n' > "$stubdir/ip"
printf '#!/bin/bash\n"$@"\n' > "$stubdir/sudo"
chmod +x "$stubdir"/*
export YRN_STUB_LOG="$stubdir/calls.log"; : > "$YRN_STUB_LOG"
PATH="$stubdir:$PATH"
YURUNA_NET_SYSFS="$root"
# The settle between reload and reconfigure is what this case is NOT about;
# zero keeps the dispatch assertion off the wall clock.
YURUNA_NET_RELOAD_SETTLE_SECONDS=0
YRN_HAS_V4=1 yuruna_net_repair_ipv4 >/dev/null
echo "WITH_V4:$(grep -c reconfigure "$YRN_STUB_LOG")"
: > "$YRN_STUB_LOG"
YRN_HAS_V4= yuruna_net_repair_ipv4 >/dev/null
echo "WITHOUT_V4:$(grep -c reconfigure "$YRN_STUB_LOG")"
rm -rf "$root" "$stubdir"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -match 'WITH_V4:0')    'a held lease must not be re-kicked'
        Assert-True ($out -match 'WITHOUT_V4:1') 'an addressless physical link must be reconfigured'
    }

    It 'waits for the reload to land an address before reconfiguring on top of it' {
        # networkctl reload re-runs acquisition on any link whose configuration
        # changed, so acquisition can still be in flight when it returns.
        # Reconfiguring on top of that restarts a DHCP client that is
        # mid-configuration: networkd then settles at "degraded (configuring)"
        # holding the lease's DNS but no address and no route, believing it has
        # finished asking, so nothing retries. The repair would be manufacturing
        # the state it exists to clear. The address here lands on the third
        # look, which must produce no reconfigure at all.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_sudo', '_yuruna_net_is_physical', 'yuruna_net_repair_ipv4'
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/enfixture0/device"
stubdir=$(mktemp -d)
printf '#!/bin/bash\necho "networkctl $*" >> "$YRN_STUB_LOG"\nexit 0\n' > "$stubdir/networkctl"
printf '#!/bin/bash\nexit 1\n' > "$stubdir/nmcli"
# Empty for the first two looks, an address from the third on -- a lease the
# reload had already put in flight.
printf '#!/bin/bash\nn=$(cat "$YRN_IP_CALLS" 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > "$YRN_IP_CALLS"\nif [ "$n" -ge 3 ]; then echo "inet 192.0.2.9/24"; fi\nexit 0\n' > "$stubdir/ip"
printf '#!/bin/bash\n"$@"\n' > "$stubdir/sudo"
chmod +x "$stubdir"/*
export YRN_STUB_LOG="$stubdir/calls.log"; : > "$YRN_STUB_LOG"
export YRN_IP_CALLS="$stubdir/ip.calls"; echo 0 > "$YRN_IP_CALLS"
PATH="$stubdir:$PATH"
YURUNA_NET_SYSFS="$root"
YURUNA_NET_RELOAD_SETTLE_SECONDS=3 yuruna_net_repair_ipv4 > "$stubdir/out.txt"
echo "RECONFIGURES:$(grep -c reconfigure "$YRN_STUB_LOG")"
echo "RELOADS:$(grep -c 'networkctl reload' "$YRN_STUB_LOG")"
grep -q 'address landed' "$stubdir/out.txt" && echo "REPORTED:1" || echo "REPORTED:0"
rm -rf "$root" "$stubdir"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -match 'RELOADS:1')      'the reload must still be issued'
        Assert-True ($out -match 'RECONFIGURES:0') 'an address that lands during the settle must not be reconfigured away'
        Assert-True ($out -match 'REPORTED:1')     'a silent wait is indistinguishable from one that never ran'
    }

    It 'still reconfigures a link the settle leaves address-less' {
        # The settle must bound the wait, not replace the re-kick: a client in
        # lost-DISCOVER backoff never lands an address on its own, and that is
        # the case the repair exists for.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_sudo', '_yuruna_net_is_physical', 'yuruna_net_repair_ipv4'
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/enfixture0/device"
stubdir=$(mktemp -d)
printf '#!/bin/bash\necho "networkctl $*" >> "$YRN_STUB_LOG"\nexit 0\n' > "$stubdir/networkctl"
printf '#!/bin/bash\nexit 1\n' > "$stubdir/nmcli"
printf '#!/bin/bash\nexit 0\n' > "$stubdir/ip"
printf '#!/bin/bash\n"$@"\n' > "$stubdir/sudo"
chmod +x "$stubdir"/*
export YRN_STUB_LOG="$stubdir/calls.log"; : > "$YRN_STUB_LOG"
PATH="$stubdir:$PATH"
YURUNA_NET_SYSFS="$root"
start=$(date +%s)
YURUNA_NET_RELOAD_SETTLE_SECONDS=2 yuruna_net_repair_ipv4 >/dev/null
echo "ELAPSED:$(( $(date +%s) - start ))"
echo "RECONFIGURES:$(grep -c reconfigure "$YRN_STUB_LOG")"
rm -rf "$root" "$stubdir"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -match 'RECONFIGURES:1') 'a link with no address after the settle must still be re-kicked'
        Assert-True ($out -match 'ELAPSED:[2-9]')  'the settle must actually be waited, not skipped'
    }

    It 'samples the client state before it restarts the client' {
        # The reconfigure below the sample restarts the DHCP client, so every
        # field it would have answered with is gone a moment later -- and the
        # failing run reaches its own diagnostic minutes after that. Ordering is
        # the whole property: a sample taken after the nudge describes the nudge.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'yuruna_net_repair_ipv4'
        $sampleAt = $fn.IndexOf('_yuruna_net_client_state')
        $reconfAt = $fn.IndexOf('networkctl reconfigure "$ifc"')
        Assert-True ($sampleAt -ge 0) 'the repair must sample the client state'
        Assert-True ($reconfAt -gt $sampleAt) 'the sample must precede the reconfigure that discards it'
        Assert-True ($fn -match 'command -v _yuruna_net_client_state') `
            'the probe must be feature-detected: a guest may carry an older network lib without it'
    }

    It 'is what the fetch wait calls between its two budget halves' {
        # Feature-detected, so a guest carrying an older network lib waits the
        # full budget instead of dying on an undefined function.
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        Assert-True ($fae -match 'command -v yuruna_net_repair_ipv4') 'the nudge must be feature-detected'
        Assert-True ($fae -match 'yuruna_wait_ipv4 "\$nudge_at"') 'the first half of the budget must run before the nudge'
        Assert-True ($fae -match 'still no IPv4 after \$\{spent\}s') 'the exhausted line must report what was actually spent'
    }
}

Describe 'fetch-and-execute: an address is held before a source is chosen' {

    # THE structural invariant. Source resolution probes the host status
    # service, and a guest with no IPv4 fails that probe for a reason that
    # says nothing about the host -- the probe could not have succeeded
    # either way. Resolving there does not pick a fallback, it discards the
    # host route on evidence never gathered; and where the framework repo is
    # private, the GitHub leg it lands on can only 404, so no later lease can
    # rescue the fetch. The order below is the whole fix.
    It 'waits for an address before resolving the fetch source' {
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        # The main-flow call sites, not the function definitions above them.
        $awaitAt  = $fae.IndexOf("`nfae_await_ipv4`n")
        $resolveAt = $fae.IndexOf("`nresolve_fetch_source`n")
        Assert-True ($awaitAt -ge 0)   'the main flow must call fae_await_ipv4'
        Assert-True ($resolveAt -ge 0) 'the main flow must call resolve_fetch_source'
        Assert-True ($awaitAt -lt $resolveAt) 'the address must be held BEFORE the source is chosen, or the host route is discarded on evidence never gathered'
    }

    # The host probe decides between the only source that can serve a private
    # repo and one that then cannot serve it at all, and it may run on an
    # address that arrived seconds earlier.
    It 'gives the host livecheck probe more than one attempt, spaced apart' {
        # Driven rather than read: what matters is how many times the probe
        # actually asks and whether it waits between asks, and a wget stub
        # counts both. A source match would pin one spelling of the retry and
        # would pass just as happily on a loop that never loops.
        #
        # The spacing is half the point. A guest that has just been given an
        # address is behind a bridge that has not learned it yet, and that
        # clears in seconds -- so attempts stacked back to back all land
        # inside the same dead moment and answer the same way.
        $driver = @'

ip()    { echo "2: yurunatest0    inet 10.0.0.5/24 scope global yurunatest0"; }
attempts=0
naps=0
wget()  { attempts=$((attempts + 1)); return 1; }
sleep() { naps=$((naps + 1)); }
YURUNA_STATUS_SERVICE_IP=10.0.0.1
YURUNA_STATUS_SERVICE_PORT=8080
resolve_fetch_source >/dev/null 2>&1
echo "ATTEMPTS=$attempts NAPS=$naps SOURCE=$FETCH_SOURCE"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $script:faePath -Name 'resolve_fetch_source') -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $m = [regex]::Match($out, 'ATTEMPTS=(\d+) NAPS=(\d+) SOURCE=(\w*)')
        Assert-True $m.Success "the driver must report its tallies; output was:`n$out"
        $attempts = [int]$m.Groups[1].Value
        $naps     = [int]$m.Groups[2].Value
        Assert-True ($attempts -gt 1) `
            "a verdict that cannot be revisited must not rest on one 2s exchange; the probe asked $attempts time(s)"
        Assert-True ($naps -eq ($attempts - 1)) `
            "the attempts must be spaced, so a settling path has time to come up; got $attempts attempt(s) and $naps gap(s)"
        Assert-StringEqual -Actual $m.Groups[3].Value -Expected 'github' `
            'a host that stays silent through the whole budget must still fall through rather than stall'
    }

    # Two call sites, one allowance. Without the shared budget the structural
    # wait and the post-fetch second chance would each spend the full
    # YURUNA_FETCH_IPV4_WAIT, doubling the worst-case boot of a guest whose
    # lease never comes.
    It 'shares one budget across both waits instead of spending it twice' {
        $fn = Get-ShellFunctionText -Path $script:faePath -Name 'fae_await_ipv4'
        $driver = @'

fae_ipv4_budget=2
yuruna_has_ipv4() { return 1; }
yuruna_wait_ipv4() { sleep "$1"; return 1; }
first_start=$SECONDS
fae_await_ipv4 >/dev/null 2>&1
echo "FIRST_SPENT:$((SECONDS - first_start))"
echo "BUDGET_LEFT:$fae_ipv4_budget"
second_start=$SECONDS
fae_await_ipv4 >/dev/null 2>&1
echo "SECOND_RC:$?"
echo "SECOND_SPENT:$((SECONDS - second_start))"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -match 'BUDGET_LEFT:0')  'an exhausting wait must consume the budget'
        Assert-True ($out -match 'SECOND_RC:1')    'the second call must report no address rather than succeed'
        Assert-True ($out -match 'SECOND_SPENT:0') 'the second call must not wait again on a spent budget'
    }

    # The cost of the structural wait on every healthy boot has to be zero,
    # or it is paid by every guest in the fleet on every fetch.
    It 'costs a guest that already holds an address nothing at all' {
        $fn = Get-ShellFunctionText -Path $script:faePath -Name 'fae_await_ipv4'
        $driver = @'

fae_ipv4_budget=30
yuruna_has_ipv4() { return 0; }
yuruna_wait_ipv4() { echo "WAITED"; sleep "$1"; return 1; }
start=$SECONDS
fae_await_ipv4
echo "RC:$?"
echo "SPENT:$((SECONDS - start))"
echo "BUDGET_LEFT:$fae_ipv4_budget"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -notmatch 'WAITED')       'a guest holding an address must never enter the wait'
        Assert-True ($out -match 'RC:0')            'it must report the address it already holds'
        Assert-True ($out -match 'SPENT:0')         'the fast path must cost no wall clock'
        Assert-True ($out -match 'BUDGET_LEFT:30')  'the fast path must not consume budget the late-lease path needs'
    }

    # A guest imaged before yuruna-network.sh existed has no yuruna_wait_ipv4,
    # and must keep the behavior it always had rather than dying on an
    # undefined function inside a diagnostic path.
    It 'degrades to the pre-existing behavior where the network library is absent' {
        $fn = Get-ShellFunctionText -Path $script:faePath -Name 'fae_await_ipv4'
        $driver = @'

fae_ipv4_budget=30
fae_await_ipv4
echo "RC:$?"
echo "BUDGET_LEFT:$fae_ipv4_budget"
'@
        $out = Invoke-ShellDriver -FunctionText $fn -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }
        Assert-True ($out -match 'RC:1')           'no wait primitive means no address claim'
        Assert-True ($out -match 'BUDGET_LEFT:30') 'a guest that cannot wait must not be charged for waiting'
    }
}

Describe 'guest-network-lib: the sysfs seam is walk-only' {

    It 'defaults to the real sysfs root and does not redirect the live address probes' {
        # The override exists so a fixture tree can be walked. Letting it reach
        # the `ip` invocations would make the diagnostic report fixture state
        # instead of the machine's own.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'network_diag'
        Assert-True ($fn -match '\$\{YURUNA_NET_SYSFS:-/sys/class/net\}') 'unset, behavior must be identical to the real path'
        $ipCalls = @([regex]::Matches($fn, '(?m)^\s*(?:\w+=\$\()?\s*ip\s+-.*$') | ForEach-Object { $_.Value })
        Assert-True ($ipCalls.Count -ge 3) "the live probes must still be there, found $($ipCalls.Count)"
        Assert-True ((($ipCalls -join "`n") -notmatch 'YURUNA_NET_SYSFS')) 'the seam must not leak into the live probes'
    }

    It 'keeps the dual-use dispatcher contract intact' {
        # The networkRelease sequence action invokes this file by path, and its
        # usage/exit-2 branch is what a typo surfaces as.
        $src = Get-Content -Raw -LiteralPath $script:netLib
        Assert-True ($src -match 'diag\)\s+network_diag')       'the diag verb must still dispatch'
        Assert-True ($src -match 'release\)\s+network_release') 'the release verb must still dispatch'
        Assert-True ($src -match 'repair\)\s+yuruna_net_repair_ipv4') 'the repair verb must still dispatch'
        Assert-True ($src -match 'usage: \$0 \{diag\|release\|repair\}') 'the usage line and its exit 2 are the action''s contract'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
