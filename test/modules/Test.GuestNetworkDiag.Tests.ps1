<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42adb0ed-d31c-458d-8804-4c2ba751642e
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

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$netLib   = Join-Path $repoRoot 'automation' -AdditionalChildPath 'yuruna-network.sh'
$faePath  = Join-Path $repoRoot 'automation' -AdditionalChildPath 'fetch-and-execute.sh'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ("$Expected" -ne "$Actual") { throw "Expected [$Expected] got [$Actual]. $Because" } }

function Get-ShellFunctionText {
    param([string]$Path, [string]$Name)
    $src = Get-Content -Raw -LiteralPath $Path
    $m = [regex]::Match($src, "(?ms)^$([regex]::Escape($Name))\(\)\s*\{.*?^\}")
    if (-not $m.Success) { throw "$Name not found in $Path" }
    return $m.Value
}

# Runs an extracted shell function under a driver that builds its own fixture
# tree, so nothing depends on a Windows path surviving translation into bash.
function Invoke-ShellDriver {
    param([string]$FunctionText, [string]$Driver)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { return $null }
    $script = $FunctionText + "`n" + $Driver
    return ($script | & $bash.Source 2>$null | Out-String)
}

# A fixture tree of $Count down interfaces, named so they cannot collide with
# a real adapter on the machine running the suite.
function Get-DownLinkDriver {
    param([int]$Count, [switch]$LineCountOnly)
    $tail = if ($LineCountOnly) { 'YURUNA_NET_SYSFS="$root" network_diag | wc -l' } else { 'YURUNA_NET_SYSFS="$root" network_diag' }
    return @"

root=`$(mktemp -d)
i=0
while [ `$i -lt $Count ]; do
    mkdir -p "`$root/yurunatest`$i"
    echo down > "`$root/yurunatest`$i/operstate"
    i=`$((i + 1))
done
$tail
rm -rf "`$root"
"@
}

Describe 'guest-network-diag: a link with no carrier is its own verdict' {

    It 'reports LINK DOWN and does not claim the carrier-up interfaces are healthy' {
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $netLib -Name 'network_diag') -Driver (Get-DownLinkDriver -Count 2)
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'LINK DOWN on 2 interface\(s\)') "the down links must be named; output was:`n$out"
        Assert-True ($out -match 'yurunatest0\(operstate=down,carrier=none\)') 'carrier reads back empty on a down interface, so it is reported as none'
        Assert-True ($out -notmatch 'All carrier-up interfaces hold an IPv4 address') `
            'an all-clear over a dead link is vacuously true and sends the reader after the wrong subsystem'
        Assert-True ($out -notmatch 'DHCP POOL EXHAUSTION') 'a down link never reaches DHCP, so lease-pool causes do not apply'
    }

    It 'still reports the DHCP-exhaustion class for a carrier-up interface with no address' {
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/yurunatest0"
echo up > "$root/yurunatest0/operstate"
echo 1  > "$root/yurunatest0/carrier"
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $netLib -Name 'network_diag') -Driver $driver
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'NO IPv4 ADDRESS on carrier-up interface\(s\):\s*yurunatest0') "the lease-pool verdict must survive; output was:`n$out"
        Assert-True ($out -match 'DHCP POOL EXHAUSTION IS A POSSIBILITY') 'the documented wording is what docs/network.md describes'
        Assert-True ($out -notmatch 'LINK DOWN') 'a carrier-up interface is not a down link'
    }

    It 'says so when nothing was examined at all instead of printing an all-clear' {
        $driver = @'

root=$(mktemp -d)
YURUNA_NET_SYSFS="$root" network_diag
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $netLib -Name 'network_diag') -Driver $driver
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'No non-loopback interface is carrier-up\.') "an empty walk must say so; output was:`n$out"
        Assert-True ($out -notmatch 'All carrier-up interfaces hold an IPv4 address') 'the all-clear must be gated on having examined something'
        Assert-True ($out -notmatch 'LINK DOWN') 'an unmatched glob is not a down interface'
    }
}

Describe 'guest-network-diag: the report stays inside the captured frame' {

    It 'emits the same number of lines for 2 down interfaces as for 30' {
        # The marker the host matches sits a few lines below this output, and
        # the headless capture surface freezes a bounded number of trailing
        # lines. Output that grows per interface scrolls the marker away and
        # turns a classified failure into an unclassified timeout.
        $fn = Get-ShellFunctionText -Path $netLib -Name 'network_diag'
        $few  = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 2  -LineCountOnly)
        if ($null -eq $few) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        $many = Invoke-ShellDriver -FunctionText $fn -Driver (Get-DownLinkDriver -Count 30 -LineCountOnly)
        Assert-Equal -Expected ([int]$few.Trim()) -Actual ([int]$many.Trim()) `
            'the verdict block must be a fixed size regardless of how many interfaces are down'
        Assert-True ([int]$few.Trim() -gt 0) 'the line count must actually have been measured'
    }

    It 'names at most three down interfaces but reports the true total' {
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $netLib -Name 'network_diag') -Driver (Get-DownLinkDriver -Count 30)
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'LINK DOWN on 30 interface\(s\)') "the count must be the real one; output was:`n$out"
        $named = ([regex]::Matches($out, 'yurunatest\d+\(operstate=')).Count
        Assert-True ($named -le 3) "at most three interfaces may be named inline, found $named"
        Assert-True ($named -ge 1) 'at least one must be named, or the verdict says nothing actionable'
    }
}

Describe 'guest-network-diag: OCR-safe wording' {

    # The console frame is matched against the echoed command line to detect a
    # failing run. The words 'fetch' and 'execute' fuzzy-match that line, so
    # either one inside diagnostic output would fail a HEALTHY run in seconds.
    It 'network_diag prints neither of the words that fuzzy-match the command line' {
        $fn = Get-ShellFunctionText -Path $netLib -Name 'network_diag'
        $echoed = @([regex]::Matches($fn, '(?m)^\s*echo\s+.*$') | ForEach-Object { $_.Value }) -join "`n"
        Assert-True ($echoed.Length -gt 0) 'the diagnostic must print something'
        Assert-True ($echoed -notmatch '(?i)fetch')   'no "fetch" in diagnostic output'
        Assert-True ($echoed -notmatch '(?i)execute') 'no "execute" in diagnostic output'
    }

    It 'the guest-has-no-IPv4 banner prints neither of them either' {
        $fn = Get-ShellFunctionText -Path $faePath -Name 'resolve_fetch_source'
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
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Assert-True $true 'guest-shaped machine -- skipping'; return }
        $driver = @'

ip()   { :; }
wget() { return 1; }
YURUNA_STATUS_SERVICE_IP=10.0.0.1
YURUNA_STATUS_SERVICE_PORT=8080
resolve_fetch_source 2>&1
echo "SOURCE=$FETCH_SOURCE"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $faePath -Name 'resolve_fetch_source') -Driver $driver
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'GUEST HAS NO IPv4') "the guest-side cause must lead; output was:`n$out"
        Assert-True ($out -notmatch 'HOST UNREACHABLE') 'the host-side theory must be suppressed when the guest holds no address'
        Assert-True ($out -match 'SOURCE=github') 'resolution must still fall through rather than stall'
    }

    It 'still prints HOST UNREACHABLE when the guest does hold an address' {
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Assert-True $true 'guest-shaped machine -- skipping'; return }
        $driver = @'

ip()   { echo "2: yurunatest0    inet 10.0.0.5/24 scope global yurunatest0"; }
wget() { return 1; }
YURUNA_STATUS_SERVICE_IP=10.0.0.1
YURUNA_STATUS_SERVICE_PORT=8080
resolve_fetch_source 2>&1
echo "SOURCE=$FETCH_SOURCE"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-ShellFunctionText -Path $faePath -Name 'resolve_fetch_source') -Driver $driver
        if ($null -eq $out) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        Assert-True ($out -match 'HOST UNREACHABLE') "an addressed guest that cannot reach the host still gets the host-side banner; output was:`n$out"
        Assert-True ($out -notmatch 'GUEST HAS NO IPv4') 'the no-address banner must not fire for an addressed guest'
        Assert-True ($out -match 'SOURCE=github') 'resolution falls through to the off-LAN source'
    }
}

Describe 'guest-network-lib: the sysfs seam is walk-only' {

    It 'defaults to the real sysfs root and does not redirect the live address probes' {
        # The override exists so a fixture tree can be walked. Letting it reach
        # the `ip` invocations would make the diagnostic report fixture state
        # instead of the machine's own.
        $fn = Get-ShellFunctionText -Path $netLib -Name 'network_diag'
        Assert-True ($fn -match '\$\{YURUNA_NET_SYSFS:-/sys/class/net\}') 'unset, behavior must be identical to the real path'
        $ipCalls = @([regex]::Matches($fn, '(?m)^\s*(?:\w+=\$\()?\s*ip\s+-.*$') | ForEach-Object { $_.Value })
        Assert-True ($ipCalls.Count -ge 3) "the live probes must still be there, found $($ipCalls.Count)"
        Assert-True ((($ipCalls -join "`n") -notmatch 'YURUNA_NET_SYSFS')) 'the seam must not leak into the live probes'
    }

    It 'keeps the dual-use dispatcher contract intact' {
        # The networkRelease sequence action invokes this file by path, and its
        # usage/exit-2 branch is what a typo surfaces as.
        $src = Get-Content -Raw -LiteralPath $netLib
        Assert-True ($src -match 'diag\)\s+network_diag')       'the diag verb must still dispatch'
        Assert-True ($src -match 'release\)\s+network_release') 'the release verb must still dispatch'
        Assert-True ($src -match 'usage: \$0 \{diag\|release\}') 'the usage line and its exit 2 are the action''s contract'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
