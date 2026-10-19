<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 4276e020-0628-4d46-8dad-488125045d50
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest cache wait network verdict pester
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
    Guard: a guest waiting on the caching proxy reports what it can see of its
    own path, repairs a lost address once, and blames the cache only for a
    refusal.
.DESCRIPTION
    curl prints one "could not connect" for a refused port, a missing address,
    a missing route and an unanswered ARP, so a guest whose DHCP lease expired
    must not spend its whole wait saying the cache "may be restarting" and then
    send the reader to a cache that is serving every other guest. Three
    properties are asserted here:

      * The verdict is read from the guest's own state, in one line and under a
        bound: address, default route, route to the peer, the next hop's
        neighbor state, then a connect that is given a few seconds. Each shape
        is driven with stubs for the kernel's answers where the real network
        cannot be made to produce it on a test host.
      * The self report that closes the failing run is a fixed size however many
        interfaces the guest has, and its verdict is the last line, because the
        host keeps only a bounded tail of the console it reads back.
      * The k8s wait loop records curl's exit code, prints the verdict on every
        poll, repairs a lost address exactly once inside the same budget, and
        picks its exhausted-budget wording by the last verdict. The loop is
        lifted from the shipped script and driven with a clock that advances
        instead of sleeping, so the two polls and the exhausted branch take no
        wall time.

    The shell functions are lifted out of the files with the parser-free
    extraction the sibling network-diag suite uses, and driven under bash
    against fixture trees the drivers build themselves. Fixture interfaces are
    named enfixture* because the sysfs seam covers only the interface walk:
    addresses are still read with a live `ip`, so a fixture named eth0 would
    collide with a real eth0 on the machine running the suite. The suite passes
    (skips) where bash is unavailable.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$script:netLib       = Join-Path $repoRoot 'automation' -AdditionalChildPath 'yuruna-network.sh'
$script:k8sPath      = Join-Path $repoRoot 'guest' -AdditionalChildPath 'shared', 'ubuntu.k8s.sh'
# A project is a separate checkout beside the engine; its workload helper
# addresses the same cache from the same guest.
$script:workloadPath = Join-Path (Split-Path -Parent $repoRoot) 'yuruna-project' -AdditionalChildPath 'tools', 'example-workload.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

# The verdict calls yuruna_has_ipv4 and the resolver, and the report calls the
# physical-NIC predicate. Absent, each is a "command not found" that reads as
# false and lands every case on the wrong branch, so all five travel together.
function Get-VerdictFunctionText {
    return (Get-ShellFunctionText -Path $script:netLib -Name `
        'yuruna_has_ipv4', '_yuruna_net_is_physical', '_yuruna_net_addr_of', 'yuruna_net_tcp_verdict', 'yuruna_net_self_report')
}

# Runs extracted shell text under a driver that builds its own fixtures, so
# nothing depends on a Windows path surviving translation into bash. A driver
# that wants stderr merges it itself with `exec 2>&1`.
function Invoke-ShellDriver {
    param([string]$FunctionText, [string]$Driver)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) { return $null }
    $script = $FunctionText + "`n" + $Driver
    return ($script | & $bash.Source 2>$null | Out-String)
}

# Stubs of the kernel's answers for one peer: how `ip -4 route get` resolves
# it, and what the neighbor table says about the next hop. Every other `ip`
# question is answered with a default route so the verdict walks past it.
function Get-IpStub {
    param([string]$RouteGet, [string]$Neighbor, [string]$Peer, [string]$NextHop)
    return @"

yuruna_has_ipv4() { return 0; }
ip() {
    case "`$*" in
        "-4 route get $Peer") $RouteGet ;;
        "-4 route show default") echo "default via 10.0.0.1 dev enfixture0" ;;
        "-4 neigh show to $NextHop") $Neighbor ;;
        *) return 0 ;;
    esac
}

"@
}

# A sysfs fixture of physical-looking NICs with no carrier, so the walk finds
# interfaces but no address and the verdict is decided without the network.
function Get-SelfReportDriver {
    param([int]$Count, [switch]$LineCountOnly)
    $tail = if ($LineCountOnly) { 'YURUNA_NET_SYSFS="$root" yuruna_net_self_report 198.51.100.7 | wc -l' } else { 'YURUNA_NET_SYSFS="$root" yuruna_net_self_report 198.51.100.7' }
    return @"

root=`$(mktemp -d)
i=0
while [ `$i -lt $Count ]; do
    mkdir -p "`$root/enfixture`$i/device"
    echo down > "`$root/enfixture`$i/operstate"
    i=`$((i + 1))
done
$tail
rm -rf "`$root"
"@
}

# The wait loop, lifted from the shipped script between the library guard that
# opens it and the health-page region that follows it. The library path is
# redirected to a fixture file so the suite's own stubs stand in for the lib a
# guest carries -- and so the guard itself is exercised rather than bypassed.
function Get-CacheWaitBlock {
    $src = Get-Content -Raw -LiteralPath $script:k8sPath
    $start = $src.IndexOf('if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then')
    if ($start -lt 0) { throw 'the k8s script must guard the network library before the cache wait' }
    $end = $src.IndexOf('# --- REGION: https://yuruna.link/42f6b05f-0020', $start)
    if ($end -lt 0) { throw 'the region that follows the cache wait moved' }
    return $src.Substring($start, $end - $start).Replace('/usr/local/lib/yuruna/yuruna-network.sh', '"$YRN_NET_LIB"')
}

# Drives the lifted loop with curl failing the way ECONNREFUSED, ENETUNREACH
# and EHOSTUNREACH all do (exit 7), a sleep that advances the shell's clock
# instead of waiting, and a fixture library whose verdict is the one under
# test. A 30 s budget with the shipped 15 s poll gives two polls and then the
# exhausted branch, under the same set -euo pipefail the script runs with.
function Invoke-CacheWait {
    param([string]$Verdict, [switch]$NoLibrary)
    $head = @'

exec 2>&1
root=$(mktemp -d)
export YRN_NET_LIB="$root/net.sh"
'@
    $lib = @'
cat > "$YRN_NET_LIB" <<'LIB'
yuruna_net_tcp_verdict() { echo "@VERDICT@"; return 1; }
yuruna_net_repair_ipv4() { repairs=$((repairs + 1)); SECONDS=$((SECONDS + 5)); echo "REPAIR $repairs"; }
yuruna_net_self_report() { echo "SELF REPORT $1:$2"; }
LIB
'@
    $mid = @'
repairs=0
CACHE_HOST=cache.invalid
curl() { echo "curl: (7) Failed to connect to cache.invalid port 5000 after 0 ms: Could not connect to server" >&2; return 7; }
sleep() { SECONDS=$((SECONDS + ${1%%.*})); }
YURUNA_CACHE_WAIT_SECONDS=30
( set -euo pipefail
'@
    $tail = @'
); echo "RC=$?"
rm -rf "$root"
'@
    # A here-string drops its final newline, so the pieces are joined with one
    # or the here-document terminator and the next command would share a line.
    $pieces = @($head)
    if (-not $NoLibrary) { $pieces += $lib.Replace('@VERDICT@', $Verdict) }
    $pieces += $mid, (Get-CacheWaitBlock), $tail
    return (Invoke-ShellDriver -FunctionText '' -Driver ($pieces -join "`n"))
}

function Get-NonEmptyLine {
    param([string]$Text)
    return @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
}

}

BeforeDiscovery {
    $script:HasLinuxIp = $false
    try {
        $script:HasLinuxIp = [bool](& bash -c 'command -v ip' 2>$null)
    } catch {
        $script:HasLinuxIp = $false
    }
}

Describe 'guest-cache-wait: the verdict names what this guest can see' -Skip:(-not $script:HasLinuxIp) {

    It 'reports a refusal against a closed loopback port, in exactly one line' {
        # A free port is taken and released so that nothing listens on it; port
        # 1 stands in where python is absent.
        $driver = @'

yuruna_has_ipv4() { return 0; }
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 1)
yuruna_net_tcp_verdict 127.0.0.1 "$port"
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'connection refused by 127\.0\.0\.1:\d+ \(host up, nothing listening\)') "a closed port is a refusal; output was:`n$out"
        Assert-True ($out -match 'RC=1') 'a refusal is not a connection'
        Assert-StringEqual -Expected 2 -Actual (Get-NonEmptyLine $out).Count 'the verdict is one line, then the status line'
    }

    It 'reports a connection against a listening port' {
        if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'python3 is not available to hold a listening port'; return }
        $driver = @'

yuruna_has_ipv4() { return 0; }
portfile=$(mktemp)
python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
with open(sys.argv[1], "w") as f: f.write(str(s.getsockname()[1]))
time.sleep(8)' "$portfile" >/dev/null 2>&1 </dev/null &
lpid=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$portfile" ] && break; sleep 0.2; done
yuruna_net_tcp_verdict 127.0.0.1 "$(cat "$portfile")"
echo "RC=$?"
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
rm -f "$portfile"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'connected to 127\.0\.0\.1:\d+') "a listening port is a connection; output was:`n$out"
        Assert-True ($out -match 'RC=0') 'only a connection returns success'
    }

    It 'reports no IPv4 address when nothing in the sysfs walk is carrier-up' {
        # The seam on yuruna_has_ipv4 is what makes this case drivable: with the
        # walk pointed at a tree of down interfaces, no live address can leak in.
        $driver = @'

root=$(mktemp -d)
mkdir -p "$root/enfixture0/device"
echo down > "$root/enfixture0/operstate"
YURUNA_NET_SYSFS="$root" yuruna_net_tcp_verdict 198.51.100.7 5000
echo "RC=$?"
rm -rf "$root"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'no IPv4 address on this guest \(the lease is gone or never landed\)') "the missing address must lead; output was:`n$out"
        Assert-True ($out -match 'RC=1') 'no address is no connection'
        Assert-StringEqual -Expected 2 -Actual (Get-NonEmptyLine $out).Count 'the verdict is one line'
    }

    It 'names a missing default route when nothing routes to the peer, and a missing route when one is expected' {
        $noDefault = @'

yuruna_has_ipv4() { return 0; }
ip() {
    case "$*" in
        "-4 route get 198.51.100.7") echo "RTNETLINK answers: Network is unreachable" >&2; return 2 ;;
        "-4 route show default") return 0 ;;
        *) return 0 ;;
    esac
}
yuruna_net_tcp_verdict 198.51.100.7 5000
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $noDefault
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match '^no default route') "an unrouted peer with no default route is the default route's absence; output was:`n$out"
        Assert-True ($out -match 'RC=1') 'no route is no connection'
        Assert-StringEqual -Expected 2 -Actual (Get-NonEmptyLine $out).Count 'the verdict is one line'

        $withDefault = (Get-IpStub -Peer '198.51.100.7' -NextHop '10.0.0.1' `
            -RouteGet 'echo "RTNETLINK answers: Network is unreachable" >&2; return 2' -Neighbor 'return 0') + @'
yuruna_net_tcp_verdict 198.51.100.7 5000
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $withDefault
        Assert-True ($out -match '^no route to 198\.51\.100\.7') "a default route that still does not reach the peer is a missing route; output was:`n$out"
        Assert-True ($out -notmatch 'no default route') 'the default route is present in this case'
    }

    It 'names the next hop whose ARP went unanswered, on-link and through the gateway' {
        $onLink = (Get-IpStub -Peer '10.0.0.7' -NextHop '10.0.0.7' `
            -RouteGet 'echo "10.0.0.7 dev enfixture0 src 10.0.0.5 uid 1000"' -Neighbor 'echo "10.0.0.7 dev enfixture0 FAILED"') + @'
yuruna_net_tcp_verdict 10.0.0.7 5000
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $onLink
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'no ARP reply from 10\.0\.0\.7 \(neighbor FAILED\)') "an on-link peer is its own next hop; output was:`n$out"
        Assert-True ($out -match 'RC=1') 'no ARP reply is no connection'
        Assert-StringEqual -Expected 2 -Actual (Get-NonEmptyLine $out).Count 'the verdict is one line'

        $viaGateway = (Get-IpStub -Peer '198.51.100.7' -NextHop '10.0.0.1' `
            -RouteGet 'echo "198.51.100.7 via 10.0.0.1 dev enfixture0 src 10.0.0.5 uid 1000"' -Neighbor 'echo "10.0.0.1 dev enfixture0 INCOMPLETE"') + @'
yuruna_net_tcp_verdict 198.51.100.7 5000
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $viaGateway
        Assert-True ($out -match 'no ARP reply from 10\.0\.0\.1 \(neighbor INCOMPLETE\)') "a routed peer's next hop is the gateway; output was:`n$out"
    }

    It 'calls a connect that never completes lost packets' {
        # The bound is the verdict: timeout's own status, not an error text.
        $driver = (Get-IpStub -Peer '10.0.0.7' -NextHop '10.0.0.7' `
            -RouteGet 'echo "10.0.0.7 dev enfixture0 src 10.0.0.5 uid 1000"' -Neighbor 'echo "10.0.0.7 dev enfixture0 lladdr 00:00:5e:00:53:07 REACHABLE"') + @'
timeout() { return 124; }
yuruna_net_tcp_verdict 10.0.0.7 5000
echo "RC=$?"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'connection to 10\.0\.0\.7:5000 timed out \(packets lost') "a connect the bound ended is lost packets; output was:`n$out"
        Assert-True ($out -match 'RC=1') 'a timeout is no connection'
        Assert-StringEqual -Expected 2 -Actual (Get-NonEmptyLine $out).Count 'the verdict is one line'
    }

    It 'reads the kernel host-unreachable as the ARP that went unanswered' {
        # Before the connect the neighbor table has no entry; the connect is
        # what makes the kernel ask, fail, and record FAILED. The stub answers
        # empty until the connect has run, then FAILED.
        $driver = @'

yuruna_has_ipv4() { return 0; }
marker=$(mktemp -u)
ip() {
    case "$*" in
        "-4 route get 10.0.0.7") echo "10.0.0.7 dev enfixture0 src 10.0.0.5 uid 1000" ;;
        "-4 route show default") echo "default via 10.0.0.1 dev enfixture0" ;;
        "-4 neigh show to 10.0.0.7") if [ -e "$marker" ]; then echo "10.0.0.7 dev enfixture0 FAILED"; fi ;;
        *) return 0 ;;
    esac
}
timeout() { : > "$marker"; echo "bash: connect: No route to host" >&2; return 1; }
yuruna_net_tcp_verdict 10.0.0.7 5000
echo "RC=$?"
rm -f "$marker"
'@
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver $driver
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'no ARP reply from 10\.0\.0\.7 \(neighbor FAILED\)') "EHOSTUNREACH on a LAN is the unanswered ARP; output was:`n$out"
        Assert-True ($out -notmatch 'no route to host') 'the richer verdict must replace the generic one when the neighbor table has the answer'
    }
}

Describe 'guest-cache-wait: the self report stays inside the captured frame' -Skip:(-not $script:HasLinuxIp) {

    It 'emits the same number of lines for 2 physical NICs as for 30, and no more than 12' {
        # The marker lines the host matches sit just below this block, and the
        # capture surface keeps a bounded tail. Output that grows per interface
        # pushes them out of the frame.
        $fn = Get-VerdictFunctionText
        $few  = Invoke-ShellDriver -FunctionText $fn -Driver (Get-SelfReportDriver -Count 2  -LineCountOnly)
        if ($null -eq $few) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $many = Invoke-ShellDriver -FunctionText $fn -Driver (Get-SelfReportDriver -Count 30 -LineCountOnly)
        Assert-StringEqual -Expected ([int]$few.Trim()) -Actual ([int]$many.Trim()) 'the block must be a fixed size regardless of interface count'
        Assert-True ([int]$few.Trim() -gt 0)   'the line count must actually have been measured'
        Assert-True ([int]$many.Trim() -le 12) "the block must fit the frame budget; printed $($many.Trim()) lines"
    }

    It 'carries the fields that separate a clock jump from a dead link, and ends on the verdict' {
        $out = Invoke-ShellDriver -FunctionText (Get-VerdictFunctionText) -Driver (Get-SelfReportDriver -Count 3)
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'address: enfixture0 \(no IPv4 address\)') "the first NIC's address line must appear; output was:`n$out"
        Assert-True ($out -match 'address: enfixture1 \(no IPv4 address\) \(\+1 more physical NIC\(s\)\)') 'the third NIC is a count on the second line, not a third line'
        Assert-True ($out -match 'default route: ') 'the default route must be shown'
        Assert-True ($out -match 'neighbor: no neighbor entry for 198\.51\.100\.7') 'an empty neighbor table must be said, not left blank'
        Assert-True ($out -match 'link: enfixture0 operstate=down carrier=none') 'the first physical NIC carries the link state'
        Assert-True ($out -match 'clock: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z uptime=') 'wall clock and uptime are what expose a clock anomaly'
        $lines = Get-NonEmptyLine $out
        Assert-True ($lines[-1] -match 'END OF THIS GUEST') 'the block must close with its end marker'
        Assert-True ($lines[-2] -match 'verdict: no IPv4 address on this guest') "the verdict must be the last line before the marker; got: $($lines[-2])"
    }

}

Describe 'guest-cache-wait: the network library text' {

    # Read from the script text, so these run on any host and never need bash.
    It 'keeps the sysfs seam walk-only on yuruna_has_ipv4' {
        # Unset, the walk reads the real sysfs; set, only the walk moves -- the
        # address probe stays live, or the predicate would report fixture state
        # on a guest.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name 'yuruna_has_ipv4'
        Assert-True ($fn -match '\$\{YURUNA_NET_SYSFS:-/sys/class/net\}') 'the default must be the real sysfs root'
        $ipCalls = @([regex]::Matches($fn, '(?m)^.*\bip\s+-4.*$') | ForEach-Object { $_.Value })
        Assert-True ($ipCalls.Count -ge 1) 'the live address probe must still be there'
        Assert-True ((($ipCalls -join "`n") -notmatch 'YURUNA_NET_SYSFS')) 'the seam must not reach the live probe'
    }

    It 'bounds every probe that can wait on the network' {
        # A verdict that hangs spends the caller's budget on probing instead of
        # waiting, and a name is resolved once under a bound rather than handed
        # to `ip route get`, which would resolve it again without one.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_addr_of', 'yuruna_net_tcp_verdict'
        Assert-True ($fn -match 'timeout 3 bash -c') 'the connect must be bounded'
        Assert-True ($fn -match 'timeout 2 getent') 'name resolution must be bounded'
        Assert-True ($fn -match 'ip -4 route get "\$addr"') 'the route is asked for the resolved literal, not the name'
        Assert-True ($fn -notmatch 'ip -4 route get "\$host"') 'the name must not reach the unbounded resolver inside ip'
    }

    It 'prints neither of the words that fuzzy-match the command line' {
        # The console frame is matched against the echoed command line to detect
        # a failing run; 'fetch' and 'execute' would close a healthy run's wait.
        $fn = Get-ShellFunctionText -Path $script:netLib -Name '_yuruna_net_addr_of', 'yuruna_net_tcp_verdict', 'yuruna_net_self_report'
        Assert-True ($fn -notmatch '(?i)fetch')   'no "fetch" anywhere in the verdict or the report'
        Assert-True ($fn -notmatch '(?i)execute') 'no "execute" anywhere in the verdict or the report'
    }
}

Describe 'guest-cache-wait: the k8s wait loop reports what the guest can see' {

    It 'sources the network library behind a readability guard, inside the cache-gated block' {
        # A guest imaged without the library must keep working, and the guard
        # has to sit where the loop runs so the warm pass further down finds the
        # same functions.
        $src = Get-Content -Raw -LiteralPath $script:k8sPath
        $gateAt  = $src.IndexOf('if [ -n "$CACHE_HOST" ]; then')
        $guardAt = $src.IndexOf('if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then')
        $dotAt   = $src.IndexOf('. /usr/local/lib/yuruna/yuruna-network.sh')
        $waitAt  = $src.IndexOf('cache_wait="${YURUNA_CACHE_WAIT_SECONDS:-180}"')
        Assert-True ($gateAt -ge 0 -and $guardAt -gt $gateAt) 'the guard must follow the cache gate'
        Assert-True ($dotAt -gt $guardAt -and $waitAt -gt $dotAt) 'the library must be sourced before the wait begins'
        Assert-True ($src -match '# shellcheck disable=SC1091\s*\n\s*\. /usr/local/lib/yuruna/yuruna-network\.sh') 'the runtime-only source needs its shellcheck directive'
    }

    It 'records curl exit code on the line after the probe and classifies the three it can name' {
        $block = Get-CacheWaitBlock
        Assert-True ($block -match 'until cache_err=\$\(curl -fsS --max-time 15 -o /dev/null "http://\$\{CACHE_HOST\}:5000/v2/" 2>&1\); do\s*\n\s*cache_rc=\$\?') `
            'the exit code must be captured before anything else can overwrite $?'
        Assert-True ($block -match '7\)\s+cache_class="curl exit 7: could not connect"')      'exit 7 is "could not connect"'
        Assert-True ($block -match '28\)\s+cache_class="curl exit 28: timed out"')           'exit 28 is "timed out"'
        Assert-True ($block -match '6\)\s+cache_class="curl exit 6: name did not resolve"')  'exit 6 is "name did not resolve"'
        Assert-True ($block -match '\*\)\s+cache_class="curl exit \$\{cache_rc\}"')          'any other code is named by number'
    }

    It 'keeps the 180 s default, the 15 s poll and the 15 s per-request bound' {
        # The budget outlasts a cache VM being replaced, which refuses
        # connections for minutes; shortening it would turn that into a failure.
        $block = Get-CacheWaitBlock
        Assert-True ($block -match 'cache_wait="\$\{YURUNA_CACHE_WAIT_SECONDS:-180\}"') 'the default budget stays 180 s'
        Assert-True ($block -match '(?m)^\s*sleep 15\s*$') 'the poll stays 15 s'
        Assert-True ($block -match '--max-time 15') 'each probe stays bounded at 15 s'
    }

    It 'repairs a lost address once and keeps waiting inside the same budget' {
        $out = Invoke-CacheWait -Verdict 'no IPv4 address on this guest (the lease is gone or never landed)'
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -notmatch 'command not found') "the lifted block must carry every dependency; output was:`n$out"
        Assert-StringEqual -Expected 1 -Actual ([regex]::Matches($out, 'attempting an address repair once')).Count 'the repair is announced exactly once'
        Assert-True ($out -match 'REPAIR 1')    'the repair must actually be called'
        Assert-True ($out -notmatch 'REPAIR 2') 'a second poll with the same verdict must not re-kick the client'
        Assert-StringEqual -Expected 2 -Actual ([regex]::Matches($out, 'not answering after \d+s \(curl exit 7: could not connect\) -- no IPv4 address')).Count `
            'both polls print the exit code, its class and the verdict'
        # The repair stub spends 5 s, as a real repair does, and the shell's SECONDS
        # counter keeps running in real time after the fake sleep. The second poll
        # reads 20 s or more while the budget keeps running, and 15 s when a reset
        # after the repair restarted it.
        $polls = @([regex]::Matches($out, 'not answering after (\d+)s \(curl exit 7') | ForEach-Object { [int]$_.Groups[1].Value })
        Assert-True ($polls.Count -eq 2 -and $polls[1] -ge 20) "the second poll must read 20 s or more, so the budget kept running through the repair; polls at $($polls -join 's, ')s"
        Assert-True ($out -match 'RC=1') 'the exhausted budget still fails the step'
    }

    It 'blames the guest, not the cache, for a lost address and prints the self report last' {
        $out = Invoke-CacheWait -Verdict 'no IPv4 address on this guest (the lease is gone or never landed)'
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'ERROR: this guest lost its IPv4 path to the LAN \(no IPv4 address on this guest') "the guest-side verdict must lead; output was:`n$out"
        Assert-True ($out -match 'was never reached, so it cannot be judged from here') 'the cache must not be judged on evidence never gathered'
        Assert-True ($out -notmatch 'zot is serving') 'the cache hint belongs to the refusal only'
        Assert-True ($out -notmatch 'it may be restarting') 'the restarting theory is gone from the progress line'
        $lines = Get-NonEmptyLine $out
        Assert-True ($lines[-1] -match '^RC=1') 'the driver reports the exit status last'
        Assert-True ($lines[-2] -match '^SELF REPORT cache\.invalid:5000$') "the self report must be the last thing before exit 1; got: $($lines[-2])"
    }

    It 'keeps the cache wording for a refusal, and only for a refusal' {
        $out = Invoke-CacheWait -Verdict 'connection refused by cache.invalid:5000 (host up, nothing listening)'
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'Check that the caching proxy VM is up and zot is serving') "a refusal still points at the cache; output was:`n$out"
        Assert-True ($out -match 'within 30s \(curl exit 7: could not connect\): connection refused by') 'the exhausted line names the class and the verdict'
        Assert-True ($out -notmatch 'lost its IPv4 path') 'an addressed guest did not lose its path'
        Assert-True ($out -notmatch 'REPAIR')      'a refusal must not re-kick the DHCP client'
        Assert-True ($out -notmatch 'SELF REPORT') 'the self report explains a lost path, not a refusal'
        Assert-True ($out -match 'RC=1') 'the exhausted budget still fails the step'
    }

    It 'calls a connect that keeps timing out lost packets' {
        $out = Invoke-CacheWait -Verdict 'connection to cache.invalid:5000 timed out (packets lost between this guest and cache.invalid)'
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -match 'ERROR: no answer from cache\.invalid:5000 within 30s \(packets are lost between this guest and the proxy\)') "a timeout is its own verdict; output was:`n$out"
        Assert-True ($out -notmatch 'zot is serving')     'a timeout is not a refusal'
        Assert-True ($out -notmatch 'lost its IPv4 path') 'a timeout is not a lost address'
        Assert-True ($out -match 'RC=1') 'the exhausted budget still fails the step'
    }

    It 'degrades to curl text where the library is absent' {
        # A guest imaged before the library existed must get the behavior it
        # always had rather than die on an undefined function inside the wait.
        $out = Invoke-CacheWait -NoLibrary
        if ($null -eq $out) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        Assert-True ($out -notmatch 'command not found') "no helper may be assumed; output was:`n$out"
        Assert-True ($out -match 'not answering after \d+s \(curl exit 7: could not connect\) -- curl: \(7\) Failed to connect') 'curl text is the fallback verdict'
        Assert-True ($out -match 'Check that the caching proxy VM is up and zot is serving') 'with no verdict the cache wording is the fallback'
        Assert-True ($out -notmatch 'attempting an address repair') 'no repair primitive means no repair'
        Assert-True ($out -match 'RC=1') 'the exhausted budget still fails the step'
    }

    It 'does not print the restarting theory over a lost address' {
        $block = Get-CacheWaitBlock
        Assert-True ($block -notmatch 'it may be restarting') 'the restarting theory must not be printed over a lost address'
        Assert-True ($block -match 'lost its IPv4 path to the LAN') 'the lost-path branch must exist'
        Assert-True ($block -match 'packets are lost between this guest and the proxy') 'the timeout branch must exist'
        Assert-True ($block -match 'zot is serving') 'the refusal branch must survive'
        Assert-StringEqual -Expected 2 -Actual ([regex]::Matches($block, 'yuruna_net_repair_ipv4')).Count 'one feature test and one call site'
        Assert-True ($block.IndexOf('[ "$cache_repaired" -eq 0 ]') -lt $block.IndexOf('yuruna_net_repair_ipv4 || true')) 'the once-guard must precede the call'
        Assert-True ($block.IndexOf('yuruna_net_self_report "$CACHE_HOST" 5000') -lt $block.IndexOf('exit 1')) 'the self report must print before the exit'
    }

    It 'adds the guest view to the warm pass when the cache was not reached' {
        $src = Get-Content -Raw -LiteralPath $script:k8sPath
        $at = $src.IndexOf("Look at this guest's path to it first")
        Assert-True ($at -ge 0) 'the not-reached branch of the warm pass must exist'
        $end = $src.IndexOf('elif [ "$yuruna_warm_refused"', $at)
        $branch = $src.Substring($at, $end - $at)
        Assert-True ($branch -match 'command -v yuruna_net_tcp_verdict') 'the verdict must be feature-detected'
        Assert-True ($branch -match 'yuruna_net_tcp_verdict "\$CACHE_HOST" 5000') 'the verdict must be taken against the cache port'
    }
}

Describe 'guest-cache-wait: the workload helper names a lost address too' {

    It 'prints the guest view before the zot hint in the unreachable branch' {
        if (-not (Test-Path -LiteralPath $script:workloadPath)) { Set-ItResult -Skipped -Because 'no yuruna-project checkout beside the engine'; return }
        $src = Get-Content -Raw -LiteralPath $script:workloadPath
        $errAt  = $src.IndexOf("ERROR: the caching proxy's registry is unreachable at")
        Assert-True ($errAt -ge 0) 'the unreachable branch must exist'
        $hintAt = $src.IndexOf("Check that the caching proxy's zot is up", $errAt)
        Assert-True ($hintAt -gt $errAt) 'the zot hint must follow the error'
        $branch = $src.Substring($errAt, $hintAt - $errAt)
        Assert-True ($branch -match '\[ -r /usr/local/lib/yuruna/yuruna-network\.sh \]') 'the library must be sourced behind a readability guard'
        Assert-True ($branch -match 'command -v yuruna_net_tcp_verdict') 'the verdict must be feature-detected'
        Assert-True ($branch -match 'yuruna_net_tcp_verdict "\$CACHE_HOST" 5000') 'the verdict line must precede the zot hint'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
