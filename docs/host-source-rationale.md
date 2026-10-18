<a id="42f52e37-0001"></a>

# Host source rationale

These technical notes preserve detailed constraints from host drivers and
service launchers. Each section accompanies the corresponding topic in the
[host implementation guide](host-implementation-notes.md). The source paths
identify the implementation to inspect; the explanations describe its runtime
invariants. This supplemental source reference is maintained in English.

<a id="42f52e37-0002"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Resume-YurunaServiceVM

Related topic: https://yuruna.link/42e5cdfd-0006

**`host/macos.utm/modules/Yuruna.Host.psm1`.**

Only a positive 'stopped' reading reaches here.
The watchdog is started HERE rather than left to the caller. The path
that leads to a resume quits UTM, and the Stop-VM on the way in reaps
any watchdog with it -- so this is the one place a service VM is
launched with nothing to dismiss the launch-time custom-QEMU-args
confirmation that service VMs carry, and a start waiting on a
modal nobody answers looks exactly like a start that was refused.

<a id="42f52e37-0003"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Rename-VM

Related topic: https://yuruna.link/42e5cdfd-0007

**`host/macos.utm/modules/Yuruna.Host.psm1`.**

Quitting UTM is collateral damage for every OTHER VM that happens to
be running: UTM saves their state on the way out and they come back
suspended, not started. The service VMs are the ones that matter --
a cycle consumes them from beginning to end -- so record which are up
now, while UTM can still be asked, and resume them after the relaunch.
A listing that could not be read is not an empty one: quitting on it
would resume nothing and strand every service suspended.

A bundle still holding the address the OLD name derives is holding that
NAME's address rather than the guest's, and the name is being vacated --
so it moves here, in the same window and for the same reason as the
display below: both are per-name values, and this relaunch is the one
moment the file is authoritative again. A bundle on any other address was
pinned at build time to the identity its guest keeps for life; moving that
one re-DHCPs a guest whose own state records the address it has.

The failed list is NOT discarded. This function's caller judges
the rename, and a rename can succeed while the services it took
down stay down -- which reads as a passing step that quietly
hands every later step, and the next cycle, a host with no cache
and no stash. The rename verdict is still the return value; this
makes the collateral damage say so at the point it happened.

<a id="42f52e37-001d"></a>

## host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1: Validate the resolved libvirt network

Related topic: https://yuruna.link/42e220c4-0004

**`host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1`.**

The Linux cloud-init builders -- Amazon Linux and the four service guests on
all three hosts -- share one seed-phase order: Yuruna harness SSH key, the
vault password, Select the guest network, Yuruna host coordinates, any
service-specific phases, Render user-data / meta-data, and Generate cloud-init
seed ISO. Service guests copy network-config (https://yuruna.link/4220a755-000b)
before ISO generation; Amazon Linux preserves cloud-init fallback networking
and pins DHCP identity in user-data instead. Host-specific phases sit between
those. All three hosts stage a seed source directory before credentials are
read; KVM places it beside the guest disk. Hyper-V picks the switch
first and then asks for the host address reachable through it; UTM and KVM
resolve the network and that address as one pair, because the bundle or
domain and the seed must agree on both. The Amazon Linux builder on KVM
generates its seed before it replaces the guest disk, so a failed seed never
costs the previous disk.

The caching-proxy builder is the one KVM service builder that validates its
libvirt network after generating the seed. The stash, pool-control and
download-agent builders reject a dead bridge inside Select the guest network.
This validation can exit, and moving it ahead of the vault, internal
authentication key, client certificate and seed phases would change which of
their side effects a failed run leaves behind, so it stays after the seed.
Its checks also differ: it warns at length about the NAT fallback and
requires a physical uplink only for a bridge-mode network.

Every KVM service builder checks its seed templates right after the vault
phase, before any network work, so a missing template fails before the guest
network is resolved.

<a id="42f52e37-0004"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Remove-VM

Related topic: https://yuruna.link/42e5cdfd-0012

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

libvirt refuses to undefine a domain that still owns per-domain
metadata, and each kind needs its own opt-in flag: snapshot metadata
("cannot delete inactive domain with N snapshots"), checkpoint
metadata, a managed-save image, and the NVRAM file. A workload that
takes a disk snapshot would otherwise leave a domain that can never
be undefined. Ask for all of them in one call so removal does not
depend on which features the guest workload happened to use.

<a id="42f52e37-0005"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-VMIp

Related topic: https://yuruna.link/42e5cdfd-0015

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

The lease rung asks the network's own lease table first, because that
is the only view carrying expiry -- and expiry is the only thing that
separates this build's address from the ones earlier builds of the
same guest left behind. domifaddr stays underneath it: a bridged
domain has no libvirt network to ask, and there the ambiguity this
avoids cannot arise anyway, since no libvirt-managed server issued
the lease.

<a id="42f52e37-0006"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Clear-YurunaExternalBridgeResidue

Related topic: https://yuruna.link/42e5cdfd-0018

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

2. Stale netplan definition. Moving the file aside (netplan only
   reads *.yaml, so a .bak is inert -- and it preserves any hand
   edits an operator made) and regenerating drops systemd-networkd's
   on-disk claim AND the udev NM_UNMANAGED rules netplan generated.
   `netplan generate` only rewrites files under /run, though --
   the RUNNING daemons keep their old view until udev re-evaluates
   the devices and networkd reloads, so trigger both explicitly.

<a id="42f52e37-0007"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Related topic: https://yuruna.link/42e5cdfd-0019

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

IMPORTANT: this function's only pipeline output is a single string
(network name) or $null. All diagnostics MUST go through
Write-Information / Write-Warning / Write-Error so callers can
safely assign with `$x = New-YurunaExternalNetwork`. A stray
Write-Output would turn $x into a string[] and break downstream
consumers (Get-ExternalNetwork compares against this exact name).

Every failure exit from here to the build must stop an
already-defined network (Stop-YurunaUnusableExternalNetwork):
the reuse branch above (re)started it BEFORE the bridge proved
unusable, and leaving it active would hand guests a bridge that
can never DHCP them -- the exact wedge the rebuild flow exists to
clear.

The full brief-network-outage warning + rollback recipe is
surfaced UP FRONT by the caller via Get-YurunaExternalNetworkPlan
(Start-CachingProxyServiceVM.ps1's plan phase), so it isn't repeated here.
ShouldProcess is kept so a standalone or -Confirm caller still
gets a gate; Start-CachingProxyServiceVM passes -Confirm:$false because it
already explained the impact and planned the run.

Sweep the residue of any previous half-built attempt FIRST --
stale NM profiles, a stale netplan definition, and the stale
kernel bridge device each make a fresh build fail in its own
way (see Clear-YurunaExternalBridgeResidue). Safe here by
construction: $nic is not enslaved (checked above), so nothing
the sweep removes carries the host's connectivity.

libvirt's <forward mode='bridge'/> with a <bridge name='...'/> tells
qemu to attach guests directly to the named bridge via a tap; the
guest's MAC is visible on the LAN and gets its own DHCP lease.
In the rebuild flow the network is usually already defined and only
needs its definition refreshed when the backing bridge name changed
(the NIC turned up enslaved to a different bridge in Step 3).

<a id="42f52e37-0008"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Related topic: https://yuruna.link/42e5cdfd-001a

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

Guard: if NetworkManager has core-dumped recently AND NM is the
active backend, the nmcli bridge build is almost certainly what
crashed it (upstream NM assertion bug in nm-settings-utils.c).
Re-running it just crashes NM again and raises another apport
"system problem" dialog -- skip straight to NAT fallback. The
netplan backend (NM not active) is unaffected, so this guard is
scoped to the NM-active case only.

<a id="42f52e37-0009"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNmcli

Related topic: https://yuruna.link/42e5cdfd-001b

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

Wait up to 30 s for the bridge to DHCP. nmcli connection up
returns when the connection is "activated" -- which can be before
DHCP completes. A bridge with no IP is still useless for the
libvirt network we are about to define, so block here briefly.
Wall-clock deadline (not an iteration count): the per-iteration `ip`
probe adds its own latency, so a counted loop would stretch the 30 s
budget past the advertised timeout.

<a id="42f52e37-000a"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNetplan

Related topic: https://yuruna.link/42e5cdfd-001c

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

Internal. Build $BridgeName via netplan, with $Nic as the only port.
Returns $true on success. Side effect: writes a new file under
/etc/netplan/ and runs `netplan apply`, which renews the lease for the
bridge in place of $Nic. On failure the netplan change is rolled back,
keeping the "returns $false => host NIC config unchanged" contract the
caller advertises.

<a id="42f52e37-000b"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: DHCP evidence capture

Related topic: https://yuruna.link/42e5cdfd-001f

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

What last happened to that one slot, in words, for the guest that ends up
without evidence. An empty slot has exactly one message today and three
possible histories behind it -- nothing ever armed, another guest's start
took the slot, or a teardown discarded it -- and they call for different
fixes in different files. The slot itself cannot carry that: it is null in
every one of them. Recorded on each transition so the gap can name which
one it was instead of leaving the reader to reconstruct it from a cycle
transcript that does not log the arm at all.

One window at a time: a later Start-VM for another guest replaces
it, and the already-running path never arms one at all. Either way
the guest that failed has no evidence, and that is worth a line.
The trail belongs to the empty-slot case only. A slot held by
another guest already names what happened to this one; adding a
history behind that reads as a second, competing explanation.

<a id="42f52e37-001a"></a>

## host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1: Scan for VM artifacts

Related topic: https://yuruna.link/42e5cdfd-0024

**`host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1`.**

The three Remove-OrphanedVMFiles.ps1 scripts share one phase vocabulary, but
this one scans for VM artifacts before it checks its prerequisites, while the
Hyper-V and UTM scripts check first. The order stays because the two blocks
exit differently: the scan exits 0 when ~/yuruna/vms does not exist, and the
prerequisite check exits 1 when virsh is missing. On a host with neither, the
scan-first order reports a clean sweep, and checking virsh first would report
a failure. test/Remove-TestVMFiles.ps1 turns a non-zero exit from this script
into a failed cycle-start cleanup, so swapping the blocks would change the
outcome on such a host. A missing VM directory is a complete answer here:
everything this script can delete lives under it.

The Hyper-V script cannot scan first: its scan paths come from Get-VMHost,
which answers only once Hyper-V is confirmed. The UTM script keeps its own
established order for the same exit-code reason.

This script also has no List protected base images phase. Its base images
live under ~/yuruna/image/<guest>/, outside the vms/ tree it scans, so no
file it could delete is a base image.

<a id="42f52e37-000c"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-CacheVmCandidateIp

Related topic: https://yuruna.link/42e5cdfd-0028

**`host/windows.hyper-v/modules/Yuruna.Host.psm1`.**

Single source of truth for KVP+ARP discovery shared by guest.caching-proxy-service/
New-VM.ps1, ../guest.ubuntu.server.24/New-VM.ps1, and test/service/Start-CachingProxyServiceVM.ps1.
Guards against the regression class where a KVP-only summary reports
"(discovery failed)" even though the ARP fallback has already found the
cache and it is serving -- by routing all three callers through the same
function.

<a id="42f52e37-000d"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-HyperVScreenshot

Related topic: https://yuruna.link/42e5cdfd-002b

**`host/windows.hyper-v/modules/Yuruna.Host.psm1`.**

Get-VMVideo is the configured mode, not necessarily the live boot
framebuffer. ARM64 firmware/early Linux can reject 1920x1080 with
32775 while 1024x768 or 640x480 still returns a usable thumbnail.
Keep the configured OCR resolution first, then try only smaller
modes. Encode each response at its requested size without stretching
it to the configured mode; click-by-OCR uses the separate window path.

<a id="42f52e37-000e"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-BestHostIp

Related topic: https://yuruna.link/42e5cdfd-002e

**`host/windows.hyper-v/modules/Yuruna.Host.psm1`.**

Three ranks, decades apart so a hand-set InterfaceMetric cannot reach
across them: carrying the default route, then being an External
switch's management vNIC, then the metric. The middle rank is what
answers the case with no default route to rank by at all -- a host
between DHCP leases -- where the pick would otherwise fall to
whichever unrelated NAT adapter happened to sort first.

<a id="42f52e37-001b"></a>

## host/windows.hyper-v/Sync-HostConfiguration.ps1: Initialize host setup

Related topic: https://yuruna.link/428405a0-0011

**`host/windows.hyper-v/Sync-HostConfiguration.ps1`.**

The macOS and Ubuntu Sync-HostConfiguration.ps1 scripts open with an
Elevation notice: they run unprivileged and ask sudo for their conditional
privileged writes later, so they announce those prompts before the bootstrap
starts. This script has no such phase. Its `#requires -RunAsAdministrator`
line refuses an unelevated session before any statement runs, so by the time
Initialize host setup executes, the process already holds the elevation every
later write needs. There is no deferred credential request to announce, and a
notice would describe a prompt that never comes.

<a id="42f52e37-001c"></a>

## test/lab/Remove-OrphanedVMFiles.ps1: Shared bootstrap

Related topic: https://yuruna.link/42010605-006d

**`test/lab/Remove-OrphanedVMFiles.ps1`.**

The test/lab redirectors share one region order: Log level from environment,
Shared bootstrap, Elevation check, Common-parameter relay, Internal
authentication key, and Delegate to the per-host script. Each one uses only
the phases it needs, always in that order.

Enable-TestAutomation.ps1 and Disable-TestAutomation.ps1 use the log level,
the bootstrap, the relay and the delegation. The log level exists to feed the
relay: a Verbose or Debug level becomes the -Verbose switch the per-host
script binds.

This redirector omits both the log level and the relay. Its per-host scripts
write no verbose stream, so neither has anything to turn on. -Quiet is the
switch that matters here; it reaches the per-host script with the forwarded
arguments and also silences this redirector's own banner.

Sync-HostConfiguration.ps1 adds two phases. Internal authentication key
stores the key in this host's vault and restarts the status service before
the delegation -- the only change a redirector makes before its per-host
script runs. Elevation check runs ahead of it, so an unelevated Windows
session is refused before that work rather than after it;
Invoke-YurunaHostScript makes the same check only at the point of delegation.
The gate acts on Windows only, because only the Hyper-V per-host script
requires Administrator.

<a id="42f52e37-000f"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Remove existing VM

Related topic: https://yuruna.link/42e5cdfd-0033

**`test/service/Start-CachingProxyServiceVM.ps1`.**

Wipe any leftover host-proxy state BEFORE provisioning. Remove-HostProxy
(not Clear-HostProxy) is the right model: a previous cycle's WinINet
ProxyServer or HTTP_PROXY env var pointing at an IP that no longer hosts
squid is junk we want gone, not state we want to preserve. The snapshot/restore
alternative (Clear-HostProxy) captures whatever is on disk at first promotion
and faithfully reinstates it on each Stop, leaking stale IPs into every
subsequent Test-CachingProxyService probe. Symmetric with Stop-CachingProxyServiceVM.ps1.

<a id="42f52e37-0010"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Start the host config service

Related topic: https://yuruna.link/42e5cdfd-0036

**`test/service/Start-CachingProxyServiceVM.ps1`.**

configService is enabled but the service did not come up -- REFUSE to build
the cache VM. A VM built now bakes EMPTY mTLS materials into its seed (New-VM
cannot mint a client cert against a down/unusable CA), so it could never fetch
its ystash-nas/ypool-nas credentials: no password rotation, and an EMPTY
"Extension hosts" panel (ystash-nas is never mounted). Failing here keeps the
operator to ONE reliable step instead of silently shipping a broken VM to
rediscover later. The opt-out is explicit: configService.enabled=false.

<a id="42f52e37-0011"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Register and start the UTM VM

Related topic: https://yuruna.link/42e5cdfd-0037

**`test/service/Start-CachingProxyServiceVM.ps1`.**

Every utmctl call below is bounded: utmctl reaches UTM over Apple Events,
and a call that raised an Automation consent dialog nobody answers does not
return on its own, so a bare call would hang the bring-up instead of
reporting the stall. The macOS driver's wrappers are used when it exports
them (they also resolve the bundle's utmctl when the PATH link is
missing); otherwise the shared bounded runner calls utmctl by name.

<a id="42f52e37-0012"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Step 6: macOS bridged -- tear down legacy host-side forwarders

Related topic: https://yuruna.link/42e5cdfd-0039

**`test/service/Start-CachingProxyServiceVM.ps1`.**

With bridged networking the cache VM is reachable directly at its
LAN IP -- no host:port forwarder layer needed. Any leftover pwsh
forwarders from a prior shared-NAT cycle would now bind ports that
the operator expects to be free, and would tunnel to a stale IP.
Remove-PortMap clears every Yuruna-managed forwarder symmetrically
with Stop-CachingProxyServiceVM.ps1; on a fresh install this is a no-op.

KVM/libvirt: guest.caching-proxy-service/New-VM.ps1 already calls virt-install
with --import and blocks until the VM has an IP AND squid is
listening on :3128 (see host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1
for the wait loop). No separate "register + start" phase like UTM,
and no host-side discovery loop like Hyper-V -- by the time we
reach here the cache is up and reachable, we just need to re-query
the IP for the summary and persist it for downstream consumers.

<a id="42f52e37-0013"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Windows -- discover the cache VM and expose its ports to the LAN

Related topic: https://yuruna.link/42e5cdfd-003b

**`test/service/Start-CachingProxyServiceVM.ps1`.**

Use the same KVP+ARP+:3128-probe discovery the guest consumers
(guest.ubuntu.server.24/New-VM.ps1) use, so the summary line
below matches what a subsequent guest install will actually see.
KVP-only discovery would print "(discovery failed)" whenever
hv_kvp_daemon wasn't warm, even though the inner New-VM.ps1's ARP
path had already found the cache and the cache was serving :3128.

Get-WorkingCachingProxyServiceUrl builds its host through
Format-IpUrlHost, which brackets IPv6, while the pattern above
reads IPv4 only -- so a cache reachable only at an IPv6 address
answers the probe and still leaves no address to record. Naming
the URL is what makes that five seconds to diagnose instead of a
silent stop.

<a id="42f52e37-0014"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Report the service state

Related topic: https://yuruna.link/42e5cdfd-003c

**`test/service/Start-CachingProxyServiceVM.ps1`.**

The caching-proxy-service-admin user's password is NOT printed in the banner -- the value
already lives in <runtime>/yuruna-caching-proxy-service.yml (written by the
cache VM's New-VM.ps1) and the vault. Reading it again here just to echo
to the terminal leaks the secret into operator transcripts / scrollback
for no real gain. Operators who need it run:
    yq .password $PasswordFile        (or: Get-Content $PasswordFile)

<a id="42f52e37-0015"></a>

## test/service/Start-StatusService.ps1: Module setup

Related topic: https://yuruna.link/42e5cdfd-003d

**`test/service/Start-StatusService.ps1`.**

$env:YURUNA_RUNTIME_DIR (runtime state) + $env:YURUNA_LOG_DIR (transcripts/
debug artifacts). Default to status/ subdirs so the HTTP server serves
them at /runtime/* and /log/*. Other status/ subdirs (perf/, extension/,
captures/, ssh/) are served straight from $StatusDir as relative paths.
StatusService kind imports Test.YurunaDir, Test.VMUtility, Test.CachingProxyService,
Test.PortOwner, and Test.HostContract -- one call replaces five inline imports
spread across the bootstrap section of this script.

<a id="42f52e37-0016"></a>

## test/service/Start-StatusService.ps1: Check for an existing server

Related topic: https://yuruna.link/42e5cdfd-003f

**`test/service/Start-StatusService.ps1`.**

SHA differs (or either side is unknown). Tear down + fall
through to the launch path so the new framework code is
picked up. Conservative on unknown: an unwritten / unreadable
server.sha (e.g. upgrade from an older Start-StatusService
that didn't persist it) forces a restart rather than risking
a stale-code server.

<a id="42f52e37-0017"></a>

## test/service/Start-StatusService.ps1: Ensure repoUrl is set in status.json

Related topic: https://yuruna.link/42e5cdfd-0040

**`test/service/Start-StatusService.ps1`.**

BOM-less UTF-8: status.json is served over HTTP to the browser
dashboard and the Go aggregator, whose JSON parsers reject a
leading BOM. WriteAllText with an explicit BOM-less UTF8Encoding
keeps the byte encoding stable across PowerShell editions (5.1's
-Encoding utf8 emits a BOM), matching the detached server's
status.json writes and the canonical sidecar encoding.

<a id="42f52e37-0018"></a>

## test/service/Start-StatusService.ps1: Probe proxy cache -> $env:YURUNA_RUNTIME_DIR/caching-proxy-service.txt

Related topic: https://yuruna.link/42e5cdfd-0044

**`test/service/Start-StatusService.ps1`.**

UI banner appends this string to the status text so viewers see at a
glance whether the harness is behind a local squid. File holds
ready-to-embed HTML (including <a href> to the Grafana dashboards URL) so the UI
injects it without knowing the URL format. Written once at
Start-StatusService -- restart to refresh after bringing squid up/down.
Needs $detectedHost, so runs AFTER the SSH block's host detection.

<a id="42f52e37-0019"></a>

## test/service/Start-StatusService.ps1: Detached server launch

Related topic: https://yuruna.link/42e5cdfd-0045

**`test/service/Start-StatusService.ps1`.**

The worker-backed routes (host refresh, start-cycle, host diagnostic) and
the modules they call. Best-effort like the imports above: each of those
routes names what it needs to Import-RouteModule before using it, so one
module that fails to load refuses its own route with a documented reply
instead of keeping the server from starting. Test.CriticalRecord is here so
its I/O helper can be compiled once at startup, off the request path.

NOTE: deliberately NO self-exit on a stale server.heartbeat --
legitimate runner states outlast ANY threshold: a
prompt-for-confirmation pausing the runner for hours, or a single
waitForText with timeoutSeconds:3600. UI must stay up, so the ONLY
stop path is service/Stop-StatusService.ps1 (kills server.pid). A truly
orphaned server must be killed manually -- deliberate trade-off.
Log per-iteration exceptions so we can see why the server died. Process
stderr goes to server.stderr, separately from this rotating log;
otherwise its open handle would keep writing into a renamed archive.

JSON string-escaping shared by every error-response builder below. The
`$_.Exception.Message` / operator-supplied text is spliced into a hand-built
{"ok":false,"error":"..."} literal, so quotes must be backslash-escaped and
CR/LF collapsed to a space to keep the payload a single valid JSON line.
The backslash pass doubles each literal backslash before quotes are escaped.
The language a request is answered in, and the direction that language reads.

Decided here so the document leaves already correct rather than being
corrected by script after first paint -- on the floor browser that correction
IS the load. The set is what the page can actually render: the default locale
is compiled into yuruna.common.js, and the pseudo locales exist only to make
a translation problem visible, so they are refused unless the run asked for
them. A reader who received expanded or mirrored text would read the page as
broken rather than as translated.

Render a perf-row timestamp as round-trip ISO-8601 UTC regardless of how it
arrived. ConvertFrom-Json silently materializes an ISO-8601 field as a
[DateTime], and interpolating one of those renders it in the SERVER's culture
("07/28/2026 17:32:03" on an en-US host). Two things break on that form: the
status page parses these as ISO to label each cycle row, and the aggregate
sorts cycles by comparing the field as TEXT -- and a lexical sort of
MM/DD/YYYY orders December 2025 after January 2026, silently drawing a
sequence's cycles out of chronological order. Normalizing on read keeps both
the wire format and the ordering key locale-independent.

Uniform tail for an error response whose Content-Type / Cache-Control / Allow
headers (when a branch needs them) are set by the caller BEFORE this call, so
the caller keeps full control of the exact header set. This only owns the
status code + body-byte emit + stream close that every branch repeats
identically. ``continue`` stays at the call site because it must target the
request loop, not this function.

Re-import a module a route depends on, on demand, when its commands are not in
this runspace. The startup imports above are best-effort by design
(-ErrorAction SilentlyContinue keeps one bad module from aborting the whole
server), and nothing else retries them: a runspace that came up without a
module answers its routes with a hard 500 for the ENTIRE life of the process --
and this server is long-lived, so only an operator restart cures it. That is
how a peer running Sync-HostConfiguration gets told 'not loaded in the server
runspace' and silently falls back to prompting the operator for values this
host could have served. Routes call this immediately before they need a
command, so the runspace heals on the next request instead.

Whether a worker-backed route can run in this runspace: every command it
calls resolves (re-imported through Import-RouteModule when a startup
import lost it), with every parameter the route passes, and the worker
vector it would launch binds against the worker script's own parameters.
A route that is not ready refuses with listener_dependency_missing, and the
refresh summary stops advertising it. A ready answer is reused for a minute;
a refusal is re-checked after ten seconds, so a runspace heals on its own.

Every detached worker this server launches goes through here. The vector is
checked against the worker script's own parameters first; stdin comes from
the empty sentinel, both streams go to the worker's private directory, and
only the launch is bounded (five seconds). The listener never waits for the
worker itself, and a worker's failure after launch is published by the
worker, never inferred here.

Refresh and artifact uploads read bodies without parking the request loop: the read
is issued asynchronously and the loop keeps accepting and serving while it
is pending, waking for whichever comes first -- the next request, a read
completing, or the earliest body deadline. At most four bodies are read at
once. A finished body is validated and admitted serially, like any other
request, and every reply goes to the context the read carries.

Admission has recorded a pending launch that names this listener
as its requester, and only this listener can close it: left
pending, a live listener reads as a launch in progress, so the
same id answers already_claimed with no worker behind it and
every other request answers busy until the queued expiry. Every
way out of here -- a work directory that cannot be secured, a
throw, a failed launch -- therefore records the outcome in the
finally, and a record that does not commit is tried once more.

A move-mode host copies each finished cycle to the pool share, verifies it, and
DELETES the local folder. Every link in the product still names the local URL
("log/<cycle>/..."), recorded in status.json history rows that were written while
the folder was local -- so rather than rewriting recorded URLs after the fact,
across processes and under the status lock, the server resolves those same URLs
against the mounted share when the local copy is gone.

Only this host's OWN hostId is ever used, so a host can never serve another
host's archives; the caller applies the same containment and deny-list checks to
the returned path that it applies to a local one.

Maps a log-relative request path onto the flat share layout. Two shapes have
to be normalized away, both of which appear in URLs recorded before a cycle
was archived:
  history.YYYY-MM-DD/<leaf>/...  the local rotation bucket; the share has no
                                 buckets, the archiver flattens them in.
  <base>.incomplete / <base>.aborted.<UTC>
                                 lifecycle suffixes; the archiver keys the
                                 destination on the STRIPPED identity, so the
                                 share holds '<base>'.
Without this a link to a rotated or crash-recovered cycle 404s against an
archive that is holding exactly the folder it asked for, under its real name.

The archived cycle folders, for the merged /log/ index and the
cycle-number short link. Only sentinel-complete folders: a destination
exists sentinel-less for the whole duration of its copy, and listing one
would advertise a half-copied tree as a finished cycle.

One enumeration returns the folder objects themselves, which carry every
property the index renders. Never look a name up again with Get-Item: on
Linux every Get-Item enumerates the whole parent directory, so a per-name
lookup makes the index quadratic. Over the pool share, a few thousand
archived cycles then hold this single-threaded listener for tens of
minutes, and every guest livecheck queued behind it fails.

Get-RunnerInstanceState surfaces a runner.start cross-check failure on
its verbose stream; run it with verbose enabled so that diagnostic
materializes, capture the records, and keep only the returned
classification hashtable. Only the module's own "cross-check failed"
line is forwarded -- to server.err by default, or the debug stream when
the caller is quiet -- so cmdline-probe chatter (e.g. the Windows CIM
query trace that ambient verbose also emits) never reaches the log.

/control/host-facts' repository columns, keyed 'framework' / 'project' ->
@{ Access; Link; Url; At }. Only the NETWORK answer is cached: reading the clone this
host holds is a local git call and stays live, but probing a configured
URL costs a round trip through the credential chain, and the pool's
fan-out gives every host in the lab one shared six-second budget. So the
probe runs AFTER the response is sent and the next request serves its
answer -- a machine that has not cloned yet reads blank for one refresh
rather than making its own hardware columns time out with it.

IPAddress.IsLoopback is a STATIC method: the instance-property
form (`$addr.IsLoopback`) silently resolves to `$null` (it never
throws, so the catch below cannot save it), which would treat the
on-host operator as remote and 403 every control action. The
static call also returns `$true` for the IPv4-mapped ::ffff:127.0.0.1
form a dual-stack listener can surface.

'internal-auth-key' first, then the legacy
'lab-auth-token' and 'pool-auth-token' names -- a
host whose vault was provisioned under an older
name keeps verifying proofs without re-enrollment
(same fallback order as Get-InternalAuthKeyValue,
inlined because the module may not be loaded here).

Which precondition failed is invisible from the status line alone:
an unconfigured host, a caller that sent no proof, and a genuinely
bad proof all render as one 403, so the operator cannot tell
"finish the setup" from "your proof expired". Name the failing
precondition in a stable machine-readable reason so the pages can
say which one, while the human-facing message keeps pointing at
the same guidance section.

GET parses the YAML on disk and sends it as JSON (200) so the
in-browser tree editor (config.html) does not need a YAML
parser. POST/PUT accepts a JSON body, validates that
ConvertFrom-Json parses it, converts to YAML, and atomically
replaces the file (write .tmp + [IO.File]::Move). Bypasses the
/yuruna-repo/ deny-list because the operator has explicitly
opted into editing this file from the UI; the response is
no-store. All errors come back as {"ok":false,"error":...}.
The deny-list still applies to the read-only repo route, so
curl GET /yuruna-repo/test/test.config.yml continues to 403.

Validate vmStart.cachingProxyIp at save time: must be
a valid IPv4/IPv6 address AND TCP-reachable on the
squid HTTP port (3128). Empty/whitespace -> stored as
empty (cycle-start treats empty as absent). Either
failure returns 400 so the UI surfaces the problem
immediately instead of the operator discovering it at
cycle start.

Re-merge the on-disk secrets node: the GET above serves
it redacted (present-but-empty) and the UI round-trips
the whole document, so without this splice a UI save
would overwrite the stored secrets with the empty node.
Per key: a posted non-empty value wins (the operator
typed a new secret in the editor); a missing/empty key
falls back to what is on disk. Clearing a stored secret
therefore requires editing the file directly -- the
trade accepted for making the redacted round-trip safe.

Written in the JSON body's key/element order (NOT canonical
alphabetical). That is intentional: Sync-TestConfigToTemplate /
Update-TestConfigFromTemplate reconcile this file to canonical
sorted order (and prune orphans) on the next Test-Config run /
cycle start, and every reader parses via ConvertFrom-Yaml, which
is order-insensitive -- so the UI save does not need to sort here.

Read-only GET/HEAD endpoint. Emits YURUNA_CACHING_PROXY_SERVICE_IP and
serverUserAccount, so the test-config editor can show
the env value side-by-side with the persisted
vmStart.cachingProxyIp. Value reflects the server process's
env (snapshotted at server start when this pwsh inherited
its parent's env block) -- separate from the value that a
Start-TestRunner.ps1 inner runspace might see if it was
launched from a different shell. Caveat documented in the
UI tooltip on the read-only field.

[Environment]::UserName returns the effective user the
status-service process is running as. Cross-platform: on
Windows it's the (possibly space-containing) display name
like "Yuruna Test"; on macOS / Linux it's the short
username like "alissonsol". Surfaced so the test.config
banner can show which account the operator's session is
actually under (useful when sudo / Run-As elevation is
in play, or on a host with multiple operator accounts).

Read-only GET, open like the other LAN reads: RAM, physical core
count, and permanent-storage totals as raw bytes/counts -- the
consumer picks display units. Physical cores (not logical
processors) because capacity planning cares about the silicon;
when the platform cannot enumerate them (some ARM guests, some
VMs) the logical count is served rather than a zero. Storage is
what the machine keeps: Get-HostStorageFact counts each space
pool once and leaves out what is only attached to the host --
see Test.HostFacts.psm1 for why both halves of that are needed.

frameworkAccess / projectAccess ride along because they answer the
same kind of question about the same machine -- what this host IS,
asked of the host itself -- and a pool UI that already fans out
here must not pay a second round trip per host to ask them.

Unique (core, socket) pairs; -b keeps offline CPUs out.
The argument MUST stay quoted: unquoted, PowerShell reads
-p=Core as a command parameter and the comma after it as an
array operator with nothing to its left, which is a parse
error rather than a runtime one -- it takes down the whole
generated script, not just this line.

The two repositories a host runs on: the framework is the
checkout this service runs FROM, and the project is the clone
beside it. Named from each clone's own remote.origin.url,
which is what the host actually tracks -- a pool assignment
overrides the configured URL for a cycle, and the operator
asking this question wants the repository that is there.

Each name travels with the location it was read from, so a
consumer can offer the repository itself rather than a name to
retype. It is normalized for linking here, at the machine that
holds it: a credential written into a remote is stripped
BEFORE the value leaves the host, since this route is an open
LAN read.

Sort each cycle's steps by their absolute start instant
-- the only key that is genuinely execution order --
then splice any matching checkpoint sidecar onto the
fetchAndExecute steps. Ordinal is a position WITHIN a
steps: block, so a retry that re-runs its block emits
the same ordinals once per attempt; ordering by
(ordinal, occurrence) interleaves the attempts and
presents a later attempt's steps as if they had run
beside the first attempt's. -Stable keeps rows that
share a start instant in the order the runner appended
them, which is also what a row with no usable window
falls back to.

Serialize once on (re)build; every subsequent GET writes
these bytes directly. Depth 8: payload -> sequences ->
cycles[] -> cycle -> steps[] -> step -> checkpoints[] ->
checkpoint{name,offsetMs}; the checkpoint objects sit one
level deeper than the rest, so a shallower depth would
stringify them and drop name/offsetMs.

fetch-and-execute.sh POSTs the ==== checkpoint ==== markers it
collected while running a fetched script. Execution IDs provide the
exact join; host-stamped arrival time remains the fallback for old
sidecars without IDs. Guest clock adjustments cannot alter that join.
The sidecar filename is minted here, never taken
from the body, so nothing in the payload can traverse the path.

Wraps Invoke-CachingProxyServiceProbe (Test.CachingProxyService.psm1, same
function the startup probe uses) so the test-config UI can
show a live connectivity verdict next to cachingProxyIp and
the `$env:YURUNA_CACHING_PROXY_SERVICE_IP` mirror. UI debounces input;
the probe is synchronous: four ports, up to three TCP attempts per port,
3s connect timeouts and 200ms retry backoff, plus a 5s CA-cert HTTP fetch.
Empty/invalid IP
returns valid=false WITHOUT running the probe so the UI can
render a "disabled" mark instead of a false negative.

Powers the test-config editor's guestSequence dropdown so the
operator picks from real folders instead of free-typing a name
no folder on this host matches. That list is only the fallback
guest set: a cycle takes its guests from test/test.runner.yml in
the project repository whenever a plan resolves. Host folder is
derived from the host type captured at server startup
(host.windows.hyper-v -> host/windows.hyper-v); empty array
is returned when the host is unknown or has no guests.

Build the JSON array literally: ConvertTo-Json 's
array-vs-scalar handling is brittle on PowerShell 7
(-AsArray + -InputObject double-wraps an existing
array, plain pipe drops the empty case to nothing).
Folder names are safe ASCII so a hand-built [...]
avoids the dance entirely.

"A runner process exists" is NOT "the runner is progressing".
runner.heartbeat is written by a threadpool timer that keeps
ticking through a wedged runspace, so a host blocked on an
unanswerable prompt would look healthy here and the dashboard
would keep showing the previous cycle's green. runner.stepHeartbeat is
written from the runspace itself, so its AGE is the real
progress signal -- and this detached server is the only Yuruna
process still live mid-cycle, so it is the only place that can
compute it. Everything below is best-effort: a liveness probe
must never be able to take the status service down.

The runner's own declared lifecycle state. runner.stepHeartbeat
is the INNER runner's per-step signal, so its age measures
progress only while an inner is actually executing. When the
outer is holding instead -- the pause after a non-zero inner
exit, or a pool configuredState=paused hold -- there is no inner,
nothing refreshes the file, and its age is just the previous
cycle's last step counting up. Reading the state is what keeps
a declared hold from being reported as a stall.

Same bound the watchdog applies: the tight preamble one
while runner.phase exists, the step budget otherwise.

A cached read is what reflects an operator's config edit,
not a bypassed one: Read-TestConfig keys its cache on the
path, the file's LastWriteTimeUtc AND a SHA-256 of its
first 64 KB, so an edit invalidates the entry by content
even when the timestamp and size are unchanged. -NoCache
here bought nothing and re-parsed the whole document on
every poll of this route.

'idle' is NOT 'ok': with no runner there is nothing to be
progressing, and reporting ok would reproduce the very
false-green this endpoint exists to remove. 'paused' is that
same argument one step in, which is why it is tested ahead of
every age comparison: a runner that has declared a hold is
not progressing and must not read 'ok', but it is not wedged
either, and an operator needs those two told apart. The hold
is bounded by the runner itself -- the pause after a failed
cycle returns to 'idle' at its cap, and a pool hold ends when
the pulled configuration flips back to run -- so this branch cannot
latch on a state the runner has already left.

Test-YurunaControlProof is required above alongside the tag
helper on purpose: a runspace that cannot load the verifier
reports no tag at all, rather than a tag that promises control
this host would then refuse ('verifier-unavailable').
refresh: the compact host-refresh capability (protocol,
availability, ceiling, reason, remote, state). A client that
finds it missing treats refresh as unavailable, which is what
an older server means.

The diagnostic reaches tools that can take minutes or never
answer, so it runs in a detached single-flight worker and this
route only reads that worker's state. A report finished in the
last 15 seconds is served as text/plain (200); a run in progress,
or one just launched, answers 202 pending with Retry-After: 3; a
run that failed in the last 15 seconds is served as its failure
text. The worker never runs twice at once, and a caller polling
faster than a worker starts is answered pending rather than given
a second worker. The report and its state stay in the private
worker directory, never under a served tree.

Read-only GET. Serves the name->IP resolutions for the server
names referenced by this host's networkStorage config (and
nothing else -- a full hosts-file dump stays in the diagnostic
report). A peer host syncing its config from this one uses it
to adopt the alias for a NAS name that does not resolve there
(host/<type>/Sync-HostConfiguration.ps1). Names + LAN IPs are
not secrets, so the route stays unauthenticated like the rest
of the status surface.

GET ?user=<logicalUser>&nonce=<b64>&proof=<b64>. Serves ONE
vault password -- and only for a user this host's own
networkStorage config references -- to a peer that proves it
holds the internal authentication key (HMAC proof; the
token itself never crosses the wire). The response password is
AES-GCM encrypted with a key derived from token + user + the
client's nonce (Protect-ConfigSyncCredential), so the secret
stays confidential over this plain-HTTP listener. Replaying a
captured request only re-fetches ciphertext the replayer still
cannot decrypt. 503 until the operator configures the shared
token (mirrors the aggregator's default-off /ingest gate);
never auto-generates a vault entry to serve.

The cycle's lab-health gate holds while a service it had been
reaching is away, re-probing on backoff. This is the operator
saying the outage is not going to end: the gate consumes the flag,
drops the hold, and lets the step run so it fails on its own terms.

Refused when no hold is up. A flag written now would sit on disk
and silently release the NEXT hold -- one nobody has looked at --
which is the opposite of an operator decision.

POST or PUT. Writes control.break-continue under runtimeDir;
the break action in Test.SequenceHandler.psm1 polls for this
file inside its wait loop, removes the marker, and resumes in place.
Only restoreOnContinue: true with an id naming an existing snapshot
invokes Restore-VMDiskSnapshot + Start-VM before resuming.
Refuses the call when no break is active (no break-active.json
sidecar) so a stray click doesn't arm the flag for the
NEXT break -- which would silently auto-resume it on the
first poll tick.

POST or PUT, no body. The listener changes nothing itself.
Invoke-StartCycleRequest records a start-cycle reservation under
the short admission lock -- answered busy while a host refresh is
active, so a runner a refresh is holding parked is never
un-paused from here -- then launches the detached worker and
answers 202 queued. The worker
takes the host's lifetime repair lock, confirms the reservation,
and only then clears the pause and lab-hold controls, rewrites
status.json, signals the restart, runs the bounded VM cleanup,
re-reads the runner's state and starts or wakes it
(test/modules/Invoke-StartCycleWorker.ps1). Its progress is
runtime/start-cycle.state.json. A launch that fails removes the
reservation, since nothing was changed.
Save the test.config.yml separately via /control/test-config
before calling this (config.html does both back-to-back).

POST only, a JSON body of at most 4096 bytes naming requestId,
tier and maxRung (docs/control-routes.md). This half runs inside
the request loop and only decides whether the body is worth
reading. The read itself is asynchronous; Step-PendingRequestBody
finishes it and Invoke-HostRefreshRequest validates, authorizes a
non-loopback caller's refresh proof, takes the short admission
lock and launches the detached worker. The listener never waits
for a repair and never takes the repair lock.

Test-YurunaHost.ps1 (and fetch-and-execute's host probe) GET
this; success means "host server is reachable from this
guest, prefer it over GitHub." JSON body is {ok, service,
time} -- `service` lets a misdirected probe (e.g. someone
else's HTTP server on the same port) be distinguished by
value, not just by 200/non-200.

A guest whose seed was baked CA-less (the caching-proxy service was
unreachable when the host built the seed) fetches this over the
RFC1918 plain-HTTP path and update-ca-certificates it, so bumped
HTTPS validates. Resolve-CachingProxyServiceCaCertPem live-reads the
CURRENT cache first (never a stale cached CA) and only falls back
to the persisted last-good CA; 404 when neither resolves so the
guest degrades to a diagnosed rc=60 rather than a silent pass.
Serves the PUBLIC CA only -- never the state file, whose password
stays deny-listed.

Second-defense path for Test.Diagnostic. The host has just
injected a one-liner into the guest console that:
  1. wgets automation/Get-SystemDiagnostic.ps1 from us,
  2. runs it locally on the guest,
  3. POSTs the captured text to this endpoint.
We accept POST or PUT and only into a folder that already
exists under logDir (the per-guest cycleGuestDataFolder
is the trust anchor: only the runner creates these, so
writing into one cannot be initiated by an attacker that
hasn't already caused the cycle to enter that guest's
loop). The filename has to match `*.system.diagnostic.*.txt`
so it lines up with Test.Diagnostic's Get-DiagnosticsFileName
output (yyyy-MM-dd.HH-mm.system.diagnostic.<Id>.txt). Body
cap is 5 MB; a real dump is ~30-60 kB, so anything larger
is an upload pathology, not a legit capture.

path: 'diagnostics/<folder>.../<filename>' -- at least
2 segments after the prefix; the last is the filename
and everything before is the folder relative to logDir.
The current layout writes to <logDir>/<cycleBase>/<VMName>/
so the typical request has 3 segments. The older
<logDir>/<failure-folder>/ flat layout (2 segments)
is still accepted because the existence-on-disk check
below is what gates writes -- the runner is the only
producer of these folders, so anything that resolves
to an existing dir is by construction a runner-created
cycle artifact.

Path-traversal guard on every folder segment. Filename
is checked separately below. We don't pattern-match the
folder shape (cycleGuestDataFolders are just the VM
name, with no stable grammar to match) because the
existence-on-disk requirement at the end of this block
is the actual security boundary.
Note: ``continue`` inside the loop would only iterate
over segments -- we set a flag and break, then short-
circuit out of the dispatch with ``continue`` against
the enclosing request loop.

Injects .yuruna-origin and .yuruna-revision sidecars at the
tarball root so guests (which have no .git/ after
``git archive`` extract) can still report the framework repo's
origin URL in Get-SystemDiagnostic and prove which exact commit
the running services were built and launched from.
Guests extract this tarball every cycle; neither folder is
read on a guest, and the public tree has no dev-only/ at all.

Symmetric counterpart to /yuruna-archive.tar.gz, but for the
project repo at <repoRoot>/project/. Update-ProjectClone
populates that folder each cycle by ``git clone``-ing the
configured repositories.projectUrl, so HEAD here is the
project's latest committed tree.

Returns 404 when the project dir is missing or not a git
repo - that's the in-tree-stop-gap path (repositories.projectUrl
is empty in test.config.yml, no clone happened) and the guest
bootstrap interprets a 404 here as "fall back to git clone".

Failed-install diagnostic sink. Method, path, extension and body-cap
limits below keep the write surface tight; the path is normalized and
range-checked against `$logDir` so nothing escapes the log mount.
.tar is allowed alongside the log extensions to carry curtin's
error_tarfile, which holds the curtin logs that are routinely absent
as standalone files at error time -- without it their only copy is
the one embedded in a multi-megabyte crash report. The service
writes and serves these bytes and never unpacks or runs them, so an
archive is no more privileged here than a log.

Download name, derived here so a direct hit on this URL saves
something an operator can recognize months later. The share
page builds the same name from the same folder for the mail
attachment; both read it out of the folder, which already
carries the UTC start (Format-CycleFolderBaseName) and the
host id -- so neither has to be told.

A HEAD asks whether there is a cycle folder to pack, and the
grammar match and the folder check above have already answered
it -- so answer without packing one. The share page probes with
HEAD before starting a download whose outcome it has no way to
observe; packing a whole folder to answer it would make the
probe cost as much as the download it precedes, on a route that
is open to the LAN.

ContentLength64 stays unset, so the reply frames itself and
carries no length. The length here is knowable only by
packing, which is the work this branch exists to skip, and
RFC 9110 section 9.3.2 permits a HEAD to omit a field
determined only while generating content -- while
forbidding outright a length a GET would not have sent.
Setting it to 0 to look tidy would be exactly that.

The archive is written to a file and then served, rather than
packed straight into the response: a pack that fails halfway
can still answer 500 instead of a truncated download, and the
finished size is what the browser and the share page report.
Packed in-process (System.IO.Compression) rather than by
shelling out, so the route needs no archiver on the host.

One response carrying a whole folder is a bulk read,
and the deny-list that guards the per-file reads runs
further down this dispatch -- so it never sees these
bytes. Pack under the same rule instead: a shape the
server refuses to serve on its own is not one it may
hand over inside an archive.

NTFS reads a named stream through the filename (`name::$DATA` is
the file's own bytes), and GetFullPath leaves that suffix in
place, so the spelling reaches a refused file under a name no
pattern below recognizes. (An 8.3 alias needs no rule of its
own: GetFullPath already resolves it to the long name above.)
Nothing this service serves has a colon in its name, so such a
spelling is refused outright rather than resolved.

Unified deny-list across non-yuruna-repo dispatches. The
/runtime/ route serves runtime/yuruna-caching-proxy-service.yml
(plaintext caching-proxy-service-admin password); the catch-all serves
status/extension/ (vault.yml, vault.lock, transports.yml,
events.log) and status/ssh/ (private SSH key). Block all
of those uniformly so URL probing never returns secrets.

When the resolved path is a directory, serve an HTML index
of its contents with relative links. Used by the failure-
screens folder under /log/<id>.<ts>.failure-screens-<vm>/
whose <a href=".../"> in the HTML transcript otherwise 404'd.
Skipped for /yuruna-repo/* so a working-tree listing never
exposes paths beyond the existing per-file deny-list.

The /log/ ROOT index also lists archived cycles. Without this a
move-mode host shows an almost empty log directory -- and the pool
aggregator, which resolves a clicked cycle partly by reading this
listing, loses its view of everything the host has archived.
Scoped to the root index only (that is the one level the
aggregator fetches) and deduplicated by name with the LOCAL entry
winning, so a copy-mode host -- where every archived cycle is also
still local -- renders exactly as it did before.

Resolved BEFORE the rendering block below, not inside it. That
block is lifted out verbatim and run on its own by the page
exporter, so anything in it that reaches for a request would
certify markup no service emits -- and the export would fail
on a null rather than on anything about the page.
The exporter supplies this variable the same way it supplies
the entries, which also lets it render the listing in a
pseudo-locale for the mirrored-direction check.

Single-quoted concat avoids double-quote escaping
noise both at template time (`@"..."@` collapses
backtick-quote to bare quote, which would corrupt
the inner attribute quotes) and at deployed-parse
time. `$titleEnc` is the only dynamic part, so a
plain `+` keeps the rest literal.

The table IS the page here. Without a caption and column scopes
a reader landing in the middle of a thousand-row listing cannot
learn which directory it is in or which column a cell belongs to.
Cycle folder names run past sixty characters, so at a narrow
viewport the horizontal scroll has to belong to the table.
Left on the body it is a two-dimensional scroll of the page.

Cache policy by file type. HTML files, including index.html and
config.html, carry a 60-second freshness window with must-revalidate so a
browser left open re-fetches on the next navigation/poll instead of serving
a stale DOM that bare 'no-store' headers paradoxically leak through some
clients. Last-Modified is sent, but revalidation uses an ETag for the final
localized HTML and returns 304 for a matching If-None-Match;
If-Modified-Since matching is not implemented. Files that mutate per cycle
(.json) and repo content served for guests (.sh, .ps1, .psm1, .yml, .yaml,
.md) keep no-store so a host edit + Start-StatusService restart is visible
immediately. Other .txt / .css / .js files are rare on this server and use
the dynamic no-store bucket to be safe. Content-addressed locale catalogs
instead carry an ETag and a one-year immutable cache policy.

The language goes into the document before it is sent, so
the page is already in the right one at first paint and
the script that runs afterwards reads it rather than
deciding it. The representation is negotiated, so it says
which language it is and varies on the header that chose
it -- without that a shared cache hands whichever
language was asked for first to everyone after.

/yuruna-repo/* 404s are operationally distinct from
generic dashboard 404s: they signal the working-tree
rename race, where a guest's mid-cycle
fetch-and-execute resolves to a path the host has just
renamed/deleted. Log the requested path + resolved file
so the operator can correlate a wget exit 8 in the
guest transcript with the file that vanished here.

Aborting is the only honest answer once a handler has failed
mid-response, but it reaches the client as a bare torn
connection -- an RST under http.sys, an empty 200 under the
managed listener -- and carries no reason with it. Record the
throw here or a route that fails on every request is
indistinguishable from a network fault to everyone looking at it.

Wrap $serverScriptFile in literal double quotes before handing it to
-ArgumentList. Start-Process joins the array elements with spaces
WITHOUT quoting, so a path like "C:\Users\Yuruna Test\..." gets
re-split by CreateProcess and the child pwsh sees -File C:\Users\Yuruna
and reports: The argument 'C:\Users\Yuruna' is not recognized as the
name of a script file.

stdout to a file, NOT /dev/null. The address-change history is
written with Write-Information, which goes to stdout, so
discarding it discards the only local record of when this host
moved -- and that record is what an operator reconstructs a
failed cycle from. Warnings already reach the .err file; the
changes are the part worth keeping.

Non-fatal, but not silent. With the already-running case handled
above, reaching here means this host has NO push path to the pool
directory: guests that need to re-resolve a moved host wait on the
aggregator's own log-tail discovery, which lags exactly when it
matters. A verbose-only line makes that state indistinguishable from
a healthy one in the cycle log.

Persist the framework HEAD SHA the new server was launched against so a
subsequent Start-StatusService invocation (the per-cycle call from
Invoke-TestRunnerInnerLoop.ps1) can short-circuit the kill+relaunch when the
code the running server already loaded is still current. Written AFTER
the readiness probe so a server that never came up does not advertise
itself as "already running on SHA X" -- the missing SHA file forces the
next call to restart.

<a id="42f52e37-0020"></a>

## test/service/Start-StashServiceVM.ps1: Phase order across the service VM family

Related topic: https://yuruna.link/42e220c4-0008

**`test/service/Start-CachingProxyServiceVM.ps1`, `Start-DownloadAgentServiceVM.ps1`,
`Start-PoolControlServiceVM.ps1` and `Start-StashServiceVM.ps1`.**

The three guest-service scripts (download-agent, pool-control and stash) keep
one pinned order: Confirm the service operation, Initialize service runtime,
Storage preflight, Resolve the VM builder, Start the host status service,
Verify the framework source, Create the VM, Configure Shared NAT forwarding,
Probe service readiness, Evaluate service readiness. The phases around that
skeleton differ on purpose.

Runtime directory. Download-agent initializes it after the elevation check, so
a refusal changes nothing. Pool-control initializes it first, ahead of the
elevation check, because the VM path and -HostSideProof both need it and only
the VM path checks elevation. Stash initializes it right before the readiness
probe and treats a failure as non-fatal: the only loss is the marker it would
have published, so the bring-up does not depend on it.

Address recovery. Download-agent and pool-control evaluate readiness, and on a
failure recover the guest address and evaluate again. Stash recovers first,
behind an inline verdict check, and evaluates once. Both orders reach the same
verdict from the same endpoint record.

Success and failure branches. Download-agent and pool-control report the
deployed source on the success branch and fall through to the failure
diagnostics. Stash handles the failure first, exits, and reports the deployed
source after the still-building exit. The messages on each path are the same.

VM address. Download-agent and pool-control wait for an address between Create
the VM and NAT forwarding. Stash has no such phase: it hands the readiness wait
the address its Shared NAT step learned, if any, and the wait resolves the
guest by name.

Caching proxy. It resolves its builder scripts and runs its host preflight
before it records the start intent, so a missing builder or an unmet host
requirement stops the run before anything is recorded, locked or changed. The
guest-service scripts record the intent first and let the shared finally close
it as failed. The caching proxy has no storage preflight, framework-source
check or single address phase: it owns host proxy settings, bridge
preparation, the lifecycle lock, adoption of a healthy VM and per-platform
address discovery instead.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
