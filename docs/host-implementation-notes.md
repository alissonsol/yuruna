<a id="42e5cdfd-0001"></a>

# Host implementation notes

These notes describe constraints kept by the host drivers, image and VM
builders, and host-side service launchers. Related scripts use short local
comments and point here for the longer explanation. Public command help
stays with each command, and executable templates retain their own comments.

<a id="42e5cdfd-0002"></a>

## Shared host module lifetime

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)
- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)
- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

The supporting test/modules become callable from our function bodies;
Export-ModuleMember below decides which of OUR functions become visible
to test/ orchestration. Yuruna.Host.psm1's exports shadow any same-name
exports the supporting modules also produce.
These dependency modules are imported -Global: Yuruna.Host is -Force re-imported
mid-cycle, and a bare -Force import here lands in Yuruna.Host's nested scope and
EVICTS the global copy other modules call via qualified names (e.g.
Test.Ssh\Invoke-GuestSsh) -- feedback_module_force_import_evicts_global.

<a id="42e5cdfd-0003"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Start-UtmVM

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Distinguish the two ways the bundle can be missing, from the
structured probe rather than the throwing boolean wrapper: still
registered means UTM holds a name whose files are gone -- the
caller reached here because that name answered the reuse check, so
pointing at the path alone would send the reader looking for a VM
that was never created, not for the registration that has to be
cleared before one can be. Unknown gets its own message: neither
"create a VM" nor "clear a registration" advice is warranted when
the probe could not establish which situation this is.

Resolve the VNC display before starting. The display is baked into
the bundle when the VM is BUILT, and every guest of a kind is built
under the same test-VM name, so a topology that promotes several
VMs out of that namespace ends up with all of them pinned to one
port -- QEMU then refuses to start every VM after the first with
"Failed to find an available port: Address already in use". Prefer
the display derived from the VM's CURRENT name (distinct per VM),
and exclude what the other bundles already claim so a genuine hash
collision falls through to the next free slot.

This write only reaches QEMU for a bundle UTM has not loaded yet.
UTM reads config.plist when it loads a VM and keeps that copy for
the life of the app, so for an already-registered VM the file and
the command line diverge silently. Rename-VM does the durable
allocation, in the window where it has UTM quit.

Adjudicated by state and retried, because utmctl exits 0 in three
different situations that are not success: a request UTM dropped
while still ingesting the bundle, a request UTM never acted on
(Apple Event error), and a VM whose QEMU died right after launch.
Reporting any of them as started buys a dead VM a full sequence of
downstream steps before anything notices, and the eventual symptom
-- an SSH timeout, a guest asserting on a peer that never came up
-- names neither this VM nor this reason.

<a id="42e5cdfd-0004"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Assert-NoConcurrentUtmVm

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Distinguish "confirmed no concurrent VM" from "couldn't check". If
UTM.app is unresponsive (host memory pressure -> Apple Event timeout,
OSStatus -1712), utmctl list returns empty and the running-set probe
below reads as "nothing running" -- a false all-clear that would let a
leftover VM slip past this guard. Surface that instead of silently
passing. We still proceed (returning $false here would wedge every cycle
on a host whose utmctl is intermittently unresponsive); the warning is
the signal, and the per-guest teardown probe is the other backstop.

<a id="42e5cdfd-0005"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Get-VncScreenshot

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Full-frame rect (the common case for an initial
FramebufferUpdateRequest after a fresh handshake): read
straight into $fb so we skip the per-row PowerShell copy
loop. Without this fast path, a 1080-row loop of
[Array]::Copy in PowerShell takes ~10 s on a 1920x1080
framebuffer because each iteration pays scriptblock
dispatch overhead -- the bytes arrive in <50 ms, the
loop is the bottleneck.

<a id="42e5cdfd-0006"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Resume-YurunaServiceVM

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

UTM ingests its library asynchronously after launch, and utmctl
cannot address a VM until that finishes -- an immediate start
would be answered with "not found" and silently dropped. This
waits through BOTH 'absent' (not yet re-registered) and 'unknown'
(a probe that could not yet be read -- which a genuinely wedged
connection also produces): only a positive 'running' or 'stopped'
reading ends the wait, and a start is only ever attempted from a
positive 'stopped' reading, never from 'unknown'.
A read the deadline had no time left for never replaces an answer
already obtained.

<a id="42e5cdfd-0007"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Rename-VM

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Re-derive the VNC display for the NEW name, here, while UTM is down.
UTM reads a bundle's -vnc argument only when it loads the VM, and
loads it once per app launch: a rewrite performed while UTM already
holds the VM changes the file without changing the QEMU command
line, so the guest still starts on the display it was loaded with.
This relaunch is the one moment the file is authoritative again.
It matters because bundles are built under a single per-kind test
name -- every VM promoted out of that namespace inherits the same
display, and only the first of them can bind the port.

<a id="42e5cdfd-0008"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Restore-VMDiskSnapshot

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

The apply below must not race a still-live QEMU helper: it holds the
qcow2's L1/L2 tables in memory and flushes its (un-reverted) view on
exit, so `qemu-img snapshot -a` exits 0 yet the guest resumes the
pre-revert disk -- "continues from where the last run left off"
instead of starting from the snapshot. Blocking on a true power-off
and lock release is what makes this revert as deterministic as a
Hyper-V checkpoint restore. Runs unconditionally because Get-VMState
maps 'suspended'/'paused' to 'stopped' yet those still hold the lock.

<a id="42e5cdfd-0009"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Send-Text

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Import once and reuse, matching Send-Key below. Re-importing -Force on
every call evicts the global Invoke-Sequence (and its nested modules
+ $script: state) that the outer loop still calls
(feedback_module_force_import_evicts_global,
feedback_module_script_state_reset_by_force_reimport). Paying that per
keystroke is not just overhead: it churns the module state that this
driver's own -HostType argument is read from, so the very act of
typing can disable the keystrokes that follow it.

<a id="42e5cdfd-000a"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Send-Key

Applies to:

- [host/macos.utm/modules/Yuruna.Host.psm1](../host/macos.utm/modules/Yuruna.Host.psm1)

Defer to Invoke-Sequence's host-aware dispatcher, which resolves the key
name through the key-code registry and picks the VNC or CGEvent backend.

Routing a key name through Send-Text instead does NOT work: the
character maps cover printable ASCII only, so a control character such
as CR is warn-and-skipped by every text backend while the call still
reports success -- a key that silently types nothing. Named keys and
modifier chords have to go through the key path.

<a id="42e5cdfd-000b"></a>

## host/macos.utm/Enable-TestAutomation.ps1: Initialize host setup

Applies to:

- [host/macos.utm/Enable-TestAutomation.ps1](../host/macos.utm/Enable-TestAutomation.ps1)

Shared bootstrap (Test.HostContract import + sudo prime + powershell-yaml +
PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
-SudoCacheReason keeps the sudo prompt EARLY (before the two PSGallery
installs, which on a freshly imaged Mac are a long silent wait) with a visible
reason banner so the operator knows WHAT will need elevation before they
consent. Set-MacHostConditionSet primes again below and is idempotent; when
invoked via install/macos.utm.sh (YURUNA_SUDO_PRIMED=1) both are silent no-ops.
Without an operator there is nobody to consent and no download to wait
through, so that mode asks for neither: missing modules are reported, not
installed, and no sudo prompt is primed.

<a id="42e5cdfd-000c"></a>

## host/macos.utm/Remove-OrphanedVMFiles.ps1: Enumerate registered VMs

Applies to:

- [host/macos.utm/Remove-OrphanedVMFiles.ps1](../host/macos.utm/Remove-OrphanedVMFiles.ps1)

utmctl exits 0 even when it could not ask UTM anything -- Apple Events
denied (typical from SSH, launchd, or any non-Automation-entitled host
process), a request that timed out, or any other Apple Event fault. It
just emits the error to stderr and prints the header with zero data
rows. This script would then treat EVERY bundle as orphaned and -- with
-Force -- delete them all even though UTM still has the VMs registered.
Bail loudly instead.

Matched on ANY OSStatus code rather than an enumerated few: the set that
can appear here is open, the cost of missing one is a deleted VM disk,
and no OSStatus value has "believe the empty list" as its right reading.

<a id="42e5cdfd-000d"></a>

## host/macos.utm/Remove-OrphanedVMFiles.ps1: Why utmctl list needs a UUID-anchored parser?

Applies to:

- [host/macos.utm/Remove-OrphanedVMFiles.ps1](../host/macos.utm/Remove-OrphanedVMFiles.ps1)

Read VM UUID from a bundle's config.plist. utmctl list may only return
running VMs; UUID-based `utmctl status` works for stopped VMs too --
without this, a stopped service VM (e.g. caching-proxy-service) is misclassified
as orphaned and deleted by the -Force cleanup path.

`plutil -extract Information.UUID raw` (not `-convert json`):
  * UTM stores the UUID at Information.UUID, not a top-level key.
  * `-convert json` fails outright on these bundles because config.plist
    contains a <data> blob (MachineIdentifier) that JSON can't represent
    -- plutil exits 1 and ConvertFrom-Json throws, which would make the
    whole function silently return $null and let the orphan check fall
    through, misclassifying a live VM as orphaned.

<a id="42e5cdfd-000e"></a>

## host/modules/Yuruna.DownloadAgent.psm1: Module setup

Applies to:

- [host/modules/Yuruna.DownloadAgent.psm1](../host/modules/Yuruna.DownloadAgent.psm1)

Host-side client for the download-agent service: find an agent, ask it about
an image, and take the bytes it already holds instead of pulling them from the
origin once per host.

Two structural rules this file lives by, both load-bearing:

  * It imports only Yuruna.Globalization -- no -Global, no -Force -- and exports
    only three uniquely-named functions. The per-host drivers wrap
    Save-CachedHttpUri to inject their own cache resolver and the image helpers
    resolve that wrapper BY NAME, so a module re-exporting Save-CachedHttpUri
    (or Test-DownloadAlreadyCurrent) and imported after a driver would take the
    command-table slot, drop the cache-discovery closure, and send every
    download direct with no error anywhere -- the regression class the drivers'
    load-tail guards warn about.
  * Nothing here throws at the caller. Discovery collapses to '' and the
    request protocol to an outcome string, because every one of these calls
    sits in front of a Get-Image run whose fallback is the origin path. A
    broken agent must cost a warning line, never a cycle.

<a id="42e5cdfd-000f"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Invoke-Virsh

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

virsh puts its own output through gettext -- domain states, field labels
and error text alike -- and the callers below read those words. On a host
whose operator runs a non-English locale, "running" arrives translated and
every state comparison silently answers 'unknown'.

LC_MESSAGES rather than LC_ALL: it pins the words while leaving encoding
and collation on the operator's own locale, so a name with an accent in it
still survives the round trip. LC_ALL has to be cleared for the duration
because it outranks LC_MESSAGES -- an operator who exports it would
otherwise get translated output regardless.

<a id="42e5cdfd-0010"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-VM

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Some per-guest builders boot the domain themselves -- an --import that is
not told otherwise, and the define+start pair the ISO installers use. Those
guests reach Start-VM already running, and its early return must not arm,
because for every other caller a running domain's first ask is long past.
Here it is not: the domain came up moments ago, inside the call above, so
this is the last point at which a window can still contain its first
DISCOVER. Gated on the domain actually running, so a builder that leaves it
defined and shut off is armed by Start-VM instead -- earlier still, before
the guest has drawn power at all.

The create's exit code is put back afterwards: the state read and the arm
run virsh lookups of their own, and a caller reading $LASTEXITCODE after
this function would otherwise be reading the diagnostic's result as the
create's.

<a id="42e5cdfd-0011"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Start-VM

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Arm the DHCP evidence window here and only here: the guest's first
DISCOVER lands seconds after firmware, before any sequence step runs, so
nothing later could open a window that contains it. The already-running
path above deliberately does not arm -- that transaction is already in
the past, and a window opened after it would show an empty slice for a
guest that did ask, which reads as the opposite of what happened.

The start's exit code is put back afterwards: arming runs virsh lookups
of its own, and a caller that reads $LASTEXITCODE after this function
would otherwise be reading the diagnostic's result as the start's.

<a id="42e5cdfd-0012"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Remove-VM

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Per-VM artifact directory (qcow2, seed.iso, autounattend.iso, nvram).
New-VM.ps1 places everything under ~/yuruna/vms/<vmname>/. This is
what actually deletes the per-VM disk; the virsh undefine above
only drops the libvirt domain definition + tracked NVRAM file.

Only once the domain is gone. A defined domain whose disk has been
deleted is worse than a leaked file: the next run finds the VM
"already there", skips creation, and every guest step fails against
a domain that cannot boot. Files kept here stay claimed by the
surviving domain, which is exactly what the orphan-file sweep
expects to skip.

<a id="42e5cdfd-0013"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-KvmNeighborIp

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

A guest that renumbers leaves its OLD address in this table under the same
MAC, and the kernel does not remove it -- it ages to STALE and sits there.
Taking the first matching line therefore returns whichever entry the hash
order happens to yield, which is as likely to be the address the guest has
already left as the one it holds now. Every candidate is collected and
ranked instead: a REACHABLE entry was confirmed by the kernel within the
last few seconds, while STALE means only that it was true at some point.
Ties are broken by a single bounded ping, because two stale entries carry
no information to choose between and asking is cheap.

<a id="42e5cdfd-0014"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Update-GuestNeighborCache

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

A host between leases has no default-route IPv4 for a few seconds, and
Get-HostIpv4Prefix answers with nothing. That window is not a reason to
skip the sweep -- it is the window the sweep exists for, because a host
that just renumbered is exactly when the guest's neighbor entry is stale
and a lookup is about to fail. The subnet does not move when the address
within it does, so the last prefix this host held is still the right place
to look, and remembering it turns "no sweep, no address" into a sweep that
answers.

<a id="42e5cdfd-0015"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-VMIp

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Rung bodies only. The shared runner owns the ordering, first-answer-wins
and the per-rung narration, so those cannot drift between this driver
and the other two.

Each probe reads what it needs from the $State bag rather than from this
function's locals, and none of them is a closure. Both halves matter:
the runner invokes a probe with `&`, which runs it in the session state
where it was defined -- this module, so Invoke-Virsh and the private
selectors below resolve -- while GetNewClosure() would bind the locals
at the cost of that resolution, because the closure carries the calling
scope instead of the module's.

Agent first, then the caches. The agent asks the guest what addresses
it holds RIGHT NOW, over a virtio-serial channel that carries no IP and
so cannot itself be broken by the renumbering this exists to survive.
The lease database and the ARP/neighbor table are both records of what
was true earlier, and on a guest that has just moved they are confidently
wrong rather than merely empty -- which is worse, because a wrong answer
ends the ladder just as surely as a right one.

It is a preference and not an authority: the channel needs a
qemu-guest-agent that has finished starting, so it is absent for the
whole boot window after each snapshot restore, which is exactly when a
cycle does most of its address lookups. The cache rungs stay beneath it
for that window, unchanged.

<a id="42e5cdfd-0016"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-ExternalNetwork

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

libvirt convention: a bridged 'external' network ($env:YURUNA_EXTERNAL_NETWORK
or 'yuruna-external' if defined) is preferred when present; otherwise
fall back to the built-in NAT 'default' network. Callers compare the
returned name to the cache VM's interface in Test-CacheVMOnExternalNetwork.

Only ACTIVE networks qualify: virt-install refuses an inactive
network at create time, and a failed bridge build can leave
'yuruna-external' defined but deliberately stopped (see
New-YurunaExternalNetwork's rebuild-failure branch). Attaching a
guest to that network would strand it with no DHCP, so a candidate
that is defined but inactive is skipped with a pointer at the fix.

<a id="42e5cdfd-0017"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: External network helpers

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Internal. The reason $Iface cannot serve as a bridge's uplink port,
or '' when it can. Only plain wired Ethernet works: bond/vlan/tunnel
devices need their own netplan sections (declaring them under
ethernets: misrenders or is rejected), and a name with characters
outside the safe set would inject into the generated netplan yaml.
Wi-Fi is checked separately by callers (it has its own operator-facing
message).

This is the Linux/KVM view of the same "uplink not bridgeable" decision
that host.windows.hyper-v Test-WindowsUplinkNotBridgeable and
host.macos.utm Test-MacUplinkNotBridgeable make for their hypervisors.
The criteria differ: a Linux host bridge carries USB Ethernet fine (it
is ARPHRD_ETHER type 1, plain wired), so -- unlike Hyper-V -- USB is not
a blocker here.

Internal. True iff NetworkManager actually MANAGES $Nic -- not merely that
the NM daemon is running. On Ubuntu Server the netplan renderer defaults to
systemd-networkd, so NM can be RUNNING yet manage zero devices: every NIC
shows STATE 'unmanaged' in `nmcli device status`. Building a bridge with
nmcli then adds the connection profiles fine but `nmcli connection up
<bridge>` fails with "Failed to find a compatible device for this
connection", and the cache silently falls back to NAT. So the bridge-backend
choice must key off management of the target NIC, not the daemon's presence.
The $StatusLines seam lets the classification be unit-tested without a live
nmcli; omitted, it queries `nmcli -t -f DEVICE,STATE device status` live.

<a id="42e5cdfd-0018"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Clear-YurunaExternalBridgeResidue

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Safety latches, not just comments: never sweep anything that could
be carrying the host's connectivity.
  * $Nic enslaved to $BridgeName: that bridge IS the host's uplink.
  * $Nic is itself a bridge: the caller mis-resolved (a leftover
    netplan bridge holding the default route after a reboot lands
    here if the reuse checks were skipped) -- deleting it would cut
    the host off with nothing left to restore it.
  * $BridgeName has some OTHER physical port, or holds the default
    route: it is somebody's live bridge (e.g. the default route
    moved to a second NIC between runs while the bridge still
    enslaves the first) -- not residue.

4. Give the NIC back to NetworkManager when OUR netplan residue is
   what had unmanaged it. Scoped on purpose: if any REMAINING
   netplan file references the NIC (Ubuntu Server's cloud-init
   config, an operator file), networkd is its rightful owner and
   forcing NM onto it would start the exact two-daemon fight the
   sweep exists to end. `nmcli device set managed` is runtime-only
   state, but a previous run's 'managed no' survives for the rest
   of the boot and would silently pin the backend choice to
   netplan on hosts that should use nmcli.

<a id="42e5cdfd-0019"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

If the operator (or a previous run) already put the WAN NIC on a
bridge, reuse it. This keeps the host networking change to zero:
we only need to define the libvirt network pointing at the existing
bridge. $BridgeName becomes a no-op suggestion in that case.
The default-route interface can also BE a bridge already (a
netplan-built bridge holds the route after a reboot) -- reuse it
directly; treating it as a NIC to enslave would try to put a
bridge inside itself.

<a id="42e5cdfd-001a"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Pick the bridge backend by whether NetworkManager actually MANAGES the
NIC -- not merely whether the NM daemon is running. On Ubuntu Server the
default netplan renderer is systemd-networkd, so NM can be running yet
manage no devices; nmcli then builds the bridge PROFILES but
`nmcli connection up` fails with "Failed to find a compatible device for
this connection" and the cache silently drops to NAT (the exact failure
this branch now avoids). netplan (systemd-networkd) is the native backend
there. When NM does manage the NIC (desktop / NM-rendered hosts) nmcli is
correct; fall back to netplan if it fails anyway so a plugin/version quirk
doesn't cost the LAN exposure + pool dashboard.

<a id="42e5cdfd-001b"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNmcli

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Record which profile currently holds $Nic -- needed twice: the
success epilogue disables its autoconnect (so on reboot the bridge
activates, not the bare NIC re-grabbing the LAN IP and starving
the bridge of carrier), and the failure paths re-activate it so a
failed build NEVER strands the host without networking. It is NOT
modified before activation: the explicit slave 'up' below already
overrides a competing active profile, and touching autoconnect
early opens a window where a failure (or crash) leaves the NIC
with no profile that will ever reconnect it.

Activate the bridge profile. This creates the kernel bridge
interface under NM's control but does NOT yet take $Nic's
carrier -- contrary to a tempting reading, `nmcli c up <bridge>`
does not auto-enslave member ports. The bridge sits up with no
uplink until the slave is brought up below; DHCP on the bridge
will start, time out at ~45 s with `ip-config-unavailable`, and
loop -- which is exactly the failure mode that strands the cache
VM with no IP if this branch is skipped.

Critical: explicitly activate the slave so $Nic actually gets
enslaved to the bridge. The slave profile's autoconnect alone
is NOT sufficient when another profile (netplan-<nic>, "Wired
connection N", etc.) currently holds $Nic -- NM will not
auto-deactivate a competing active profile to satisfy a slave's
autoconnect. A user-initiated `nmcli c up $slaveConn` overrides
that policy: NM deactivates the conflicting profile, binds $Nic
to the slave, the bridge sees new carrier, and DHCP succeeds.
This is the moment SSH sessions over $Nic flap; with the cloned
MAC above the new DHCP lease should be the same IP and SSH
reconnects within a few seconds.

<a id="42e5cdfd-001c"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNetplan

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

If NetworkManager currently manages the NIC (this path also runs as
the fallback after a failed nmcli build on an NM host), hand the
NIC off BEFORE apply. netplan's generated udev NM_UNMANAGED rule
only takes effect on the next device event, and in the window
between `netplan apply` restarting systemd-networkd and NM noticing,
both daemons configure the NIC: networkd tries to enslave it while
NM re-activates its profile on it -- and the bridge ends up
uplink-less, so guests never see a DHCP offer. `nmcli device set
managed no` releases the device immediately (runtime-only; the udev
rule makes it stick), and autoconnect off on the bound profile
stops NM re-grabbing it at its next restart.

Local rollback: put the host back exactly as it was, so a $false
return never leaves a half-applied netplan layout behind (a stale
one is what makes the NEXT run's nmcli path fail with "no
compatible device"). `netplan apply` -- not merely generate -- is
load-bearing: generate only rewrites files under /run, and the
RUNNING systemd-networkd keeps the ingested bridge-slave/no-DHCP
view of the NIC until told to re-read. On a pure-networkd host
(the primary audience of this backend) apply is the only thing
that re-hands the NIC to the surviving original netplan config and
restores its DHCP; without it a failed build leaves the host
addressless until a manual apply or reboot.

<a id="42e5cdfd-001d"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Test-CacheVMOnExternalNetwork

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Matches the Hyper-V contract semantic: the cache VM's configured first
NIC must use host bridging before callers remove host-side port forwarders.
On KVM a direct bridge attachment qualifies; a named libvirt network qualifies
only when its readable definition has `forward mode='bridge'`. A custom name
or `YURUNA_EXTERNAL_NETWORK` alone proves nothing: NAT, routed, and isolated
networks can also have libvirt-owned bridges. Missing or unreadable attachment
evidence returns false, preserving the forwarding path.

<a id="42e5cdfd-001e"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Assert-Virtualization

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

libvirtd being active is not the same as THIS process being able to
reach it. A user added to 'libvirt' via usermod -aG only gets the
group in their effective set after a re-login -- and on systemd-
logind systems with user lingering, even a desktop logout/login
often does NOT refresh existing terminal sessions. Without this
check, the runner cruises past Assert-Virtualization, spends ~8
minutes downloading ISOs, and only THEN crashes inside New-VM.ps1
with the verbatim libvirt-sock "Permission denied" line.

<a id="42e5cdfd-001f"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: DHCP evidence capture

Applies to:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Say why the DHCP evidence is not there. The capture is armed on every VM
start and copied only on the failure path, so a cycle that ends with no
dhcp.capture.txt cannot distinguish a window that was never armed from a save
that declined -- and that is precisely the cycle where someone is looking for
the file. Reported on two surfaces because neither is complete alone: the
warning reaches the console and the process transcript but not the cycle's
own event stream, and the degradation event lands beside the missing artifact
but is dropped silently when no cycle folder is open.

<a id="42e5cdfd-0020"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: libvirt services and default network

Applies to:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../host/ubuntu.kvm/Enable-TestAutomation.ps1)

Whether these steps run is decided by whether root is reachable RIGHT NOW,
never by who started the run. Only install/ubuntu.kvm.sh performs these
commands ahead of time; every other caller does not, so a gate keyed on the
caller's identity leaves libvirtd disabled on those hosts while claiming a
wrapper already handled it.

Re-running them after the bash wrapper already did is safe: systemctl enable
--now, virsh net-start and virsh net-autostart are all idempotent, and paying
for that is the price of not guessing. Every call goes out with `sudo -n`, so
a cold credential is an exit code rather than a password prompt on a terminal
whose output is being captured.

<a id="42e5cdfd-0021"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Status-service LAN reachability

Applies to:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../host/ubuntu.kvm/Enable-TestAutomation.ps1)

Start-StatusService binds http://*:<port>/ (every interface), but a host
firewall silently DROPs inbound TCP on non-loopback interfaces without an
allow rule -- so localhost answers while the pool-aggregator service (and an operator's
browser) time out, and the host disappears from the pool dashboard. The
Windows path opens this in Set-WindowsHostConditionSet; do the ufw equivalent
here so an Ubuntu host is reachable too. This is the PERSISTENT fix: a host
whose runner is stopped never re-runs the per-cycle status start, so the
status-service self-heal cannot fire there -- the rule set once at setup is
what survives. Port from test.config.yml (8080 default), the same source
Start-StatusService reads. No-op when ufw is inactive/absent.

<a id="42e5cdfd-0022"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Host clock

Applies to:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../host/ubuntu.kvm/Enable-TestAutomation.ps1)

libvirt seeds each guest's clock from this host at power-on, so a host
that has drifted starts every VM equally wrong and the guest's own NTP
client steps it to real time seconds into the boot -- mid-startup for
whatever that guest is bringing up. On a Kubernetes guest that leaves
pods Running but never Ready and every NodePort refusing, with nothing
in the picture pointing back at a clock. The Windows and macOS paths do
this inside their Set-*HostConditionSet; this host has no equivalent, so
the same call lands here.

<a id="42e5cdfd-0023"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Pool-storage mount point

Applies to:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../host/ubuntu.kvm/Enable-TestAutomation.ps1)

networkStorage pool (test.config.yml) mounts an SMB share at localPath. The test
runner runs UNPRIVILEGED; when localPath sits under a root-owned parent
(e.g. /mnt/ypool-nas under /mnt 0755 root:root), Connect-YurunaPoolStorage's own
New-Item cannot create the directory and the mount is never even attempted
-- a reachable NAS that silently never replicates. Pre-create the mount
point here, where this host-setup script can elevate, owned by the runner so
the unprivileged mount path finds it already present and writable. The
mount.cifs helper itself comes from cifs-utils (install/ubuntu.kvm.sh).

<a id="42e5cdfd-0024"></a>

## host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1: Delete orphaned VM artifacts

Applies to:

- [host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1](../host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1)

Belt-and-suspenders: make sure libvirt didn't pick up the domain
between the initial scan and the actual delete.
The not-found signature below is gettext text, so the words have to be
pinned or the check never matches on a host in another language --
which does not delete anything it should not, but does refuse every
cleanup and leaves the operator with a warning per orphan and no way
to act on it. LC_ALL is cleared for the call because it outranks
LC_MESSAGES.

<a id="42e5cdfd-0025"></a>

## host/ubuntu.kvm/Sync-HostConfiguration.ps1: Guest address-discovery readiness

Applies to:

- [host/ubuntu.kvm/Sync-HostConfiguration.ps1](../host/ubuntu.kvm/Sync-HostConfiguration.ps1)

Which of this driver's discovery rungs can answer AT ALL is decided by host
configuration, not by the harness: the lease rung needs libvirt to be the DHCP
server for the guest network, and the agent rung needs qemu-guest-agent inside
the guest. When both are structurally silent, discovery rests entirely on a
passive read of the host neighbor cache -- which decays, so lookups start
missing intermittently, and a miss surfaces to the operator as an ssh
name-resolution error that says nothing about any of this.

Reporting it here turns that from something diagnosed across many failed
cycles into a line of setup output.

<a id="42e5cdfd-0026"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Module setup

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

ADK Deployment Tools path. The '10' is the ADK major version, not the Windows
version -- adjust it if a different ADK is installed.

The ADK lays Oscdimg down once per architecture -- amd64, arm64 and x86 are
all present after a single install, on an ARM64 host as much as an x64 one --
so the subdirectory is a choice, not a constant. Pinning amd64 does run on
ARM64, silently, through the x64 emulation layer, which is exactly what makes
the wrong pin hard to notice: a seed ISO is on the path of every guest this
driver creates, and it would keep working until it met a host where that
layer is unavailable. Prefer the native build and keep the others as
fallbacks, so a partial ADK still yields a runnable copy.

<a id="42e5cdfd-0027"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Resolve-OscdimgPath

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

The tool lives under a Windows-only root. Off Windows there is no C:
drive for Join-Path to build a candidate against, so it fails and hands
the probe below a null path -- and Test-Path on null is an error that a
caller running with ErrorActionPreference 'Stop' turns into a failed
module load. This runs at import time, so the whole module then loads as
nothing, and every consumer reports a missing command rather than a
missing tool. RuntimeInformation rather than $IsWindows: the latter is
undefined on PowerShell 5.1, where -not $IsWindows is true on the one
platform this path is for.

<a id="42e5cdfd-0028"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-CacheVmCandidateIp

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

KVP can emit both IPv4 and IPv6. Net-routable v4 stays first since
downstream port-forwarders here are netsh portproxy v4tov4; v6
entries are kept too so callers that handle v6 (SSH, generic TCP)
still see them. Loopback/link-local on either family is excluded.

Kept as an inline filter rather than routed through
Select-YurunaRoutableAddress: this site needs the whole surviving LIST of
candidates to rank against ARP results below, and the shared helper
deliberately answers with one address. The rejection rule it applies is the
same one; change both together.

<a id="42e5cdfd-0029"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-OrCreateYurunaExternalSwitch

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

2. ANY existing External-type vSwitch: reuse it instead of
creating a redundant second External on the same NIC. Hyper-V
only allows one External vSwitch per physical adapter, so a
blind New-VMSwitch on top of an existing one tears down the
original (network blip + every existing VM on the old switch
gets disconnected). On hosts where the operator pre-created an
External vSwitch under a different name (e.g., 'External',
'LAN-Bridge'), we honor that and return its name. That same
invariant is why an External switch whose bridge is degraded
declines here instead of falling through to the create path.

<a id="42e5cdfd-002a"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Start-WindowsCachingProxyServiceForwarder

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

-RedirectStandardInput against an empty file: without an explicit
stdin redirect the detached forwarder inherits the parent
console's stdin handle, and Windows conhost cannot tear down
when the parent shell exits -- pinning the operator's
PowerShell window in a close-pending state until the forwarder
is killed. Passing 'NUL' / '\\.\NUL' is rejected by
Start-Process's path resolver (it prepends the cwd and the
underlying FileStream open fails), so we use a persistent empty
sentinel file in the forwarder's state dir.

<a id="42e5cdfd-002b"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-HyperVScreenshot

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Detect the "headless host" symptom: WMI returns a valid
thumbnail but every pixel is black because the host's
DWM isn't actively painting the synthetic GPU. Reported
ONCE per process so a long Start-TestRunner cycle
doesn't flood the log with the same message every step.
Verbose, not Warning: the PrintWindow/vmconnect fallback
below recovers a usable framebuffer, so a headless host
keeps passing -- raise the log level to see the
troubleshooting pointer when OCR does start timing out.

<a id="42e5cdfd-002c"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Rename-VM

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

A NIC still holding the address the OLD name derives is holding that
NAME's address rather than the guest's, and the name is being vacated --
leave it there and every guest promoted out of that slot ends up on one
address on one switch. Any other address was pinned at build time to the
identity this guest keeps for life: moving it re-DHCPs a guest whose own
state already records the address it has, which no reboot recovers from.
Only the first adapter is considered: a second interface needs a second
DISTINCT address, and -VMName would write this one to both. Hyper-V takes
bare hex, no separators.

<a id="42e5cdfd-002d"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: DHCP evidence capture

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

The guest-side network diagnostic can only say "no lease". Whether the
DISCOVER left the guest at all, died crossing the vSwitch or the uplink, or
went out and was never answered is visible only on the host's packet path --
and each of those shapes indicts a different machine. pktmon records every
component a packet traverses, so the drop point is in the artifact, and the
pcapng form keeps payloads (client-id, xid) for reading which identity asked.

pktmon allows ONE session per system, so every start clears whatever session
precedes it, and the capture is DHCP-only (ports 67/68) in a small circular
log: a session nothing ever stops -- a flow that starts a VM and never
removes it -- stays bounded instead of growing with uptime.

<a id="42e5cdfd-002e"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-BestHostIp

Applies to:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Binding a NIC to an External vSwitch moves the host's own LAN address off
that NIC and onto `vEthernet (<switch>)`, so on the topology this
framework builds the correct answer is ALWAYS a vEthernet adapter.
Excluding vEthernet wholesale -- the obvious way to keep the internal and
NAT vNICs out (Default Switch, WSL) -- therefore discards the only right
answer and settles for whatever NAT adapter another hypervisor installed:
an address that resolves locally, answers nothing, and never changes,
which is indistinguishable from a host that is not moving.

A vEthernet is admitted on either of two independent grounds, and the
second is what keeps this working where the first cannot be read:
Get-VMSwitch needs Hyper-V administrator rights, and not every caller has
them, while the default route is readable by anyone and is on the
LAN-facing adapter whatever it happens to be called.

<a id="42e5cdfd-002f"></a>

## host/windows.hyper-v/Remove-OrphanedVMFiles.ps1: Elevation gate

Applies to:

- [host/windows.hyper-v/Remove-OrphanedVMFiles.ps1](../host/windows.hyper-v/Remove-OrphanedVMFiles.ps1)

Every path below needs Administrator (Get-VMHost, Get-VM, Get-VMHardDiskDrive),
so refuse HERE -- ahead of the destructive-operation banner and the base-image
scan -- rather than after the operator has read "THIS CANNOT BE UNDONE" for a
run that cannot proceed. Write-Warning, not Write-CleanupMessage: the module is
not imported yet, and -Quiet must not swallow the reason for exit 1. Neither
Write-Error nor '#requires -RunAsAdministrator' would do: Remove-TestVMFiles.ps1
invokes this in-process under $ErrorActionPreference='Stop', where either would
abort the parent teardown instead of returning a graceful exit 1.

<a id="42e5cdfd-0030"></a>

## host/Yuruna.Host.Contract.psm1: Virtualization repair

Applies to:

- [host/Yuruna.Host.Contract.psm1](../host/Yuruna.Host.Contract.psm1)

The first verb is a read-only, bounded probe that returns a versioned
record (state/reason/started/timedOut/observedUtc/elapsedMs plus
platform evidence), distinct from the plain [bool] Assert-Virtualization
above: a caller deciding whether to disrupt the hypervisor needs to tell
a missing client apart from a denied permission apart from a genuine
timeout, not just yes-or-no. The second starts only a hypervisor service
the driver itself positively observes as stopped, immediately before
acting, and refuses on anything it cannot establish; a host-neutral
caller invokes both by one name on every platform.

<a id="42e5cdfd-0031"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Preflight

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Past this point Start-CachingProxyServiceVM runs UNATTENDED -- it must not stop
for an interactive prompt. Everything that needs operator awareness is
surfaced and resolved HERE, at the start:
  * a host-networking change (the 'yuruna-external' bridge) is described
    up front via Get-YurunaExternalNetworkPlan, before anything happens;
  * sudo is primed once, with the reasons, so no step re-prompts;
  * hard requirements (/dev/kvm, libvirtd) are checked so a doomed run
    stops NOW with a clear explanation instead of failing deep inside
    Step 3 (virt-install) after a multi-minute image download.

<a id="42e5cdfd-0032"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Bridge plan -- does the bridge step perturb host networking?

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Prime sudo ONCE, now, with the reasons -- so the host-proxy wipe (Step 1)
and, on Linux, the bridge's `sudo nmcli` calls (Step 1.5) never prompt
mid-run. Initialize-SudoCache is idempotent + silent when the cache is
already warm or elevation isn't needed (e.g. running as root).
The Step 1 host-proxy wipe needs root, but the mechanism differs per
platform -- name the real one so the prompt box explains why THIS host
is asking. macOS clears the system proxy via networksetup; Linux edits
/etc/environment + the apt proxy config. (Windows skips sudo entirely,
so the text is never shown there.) Build the base reason as a scalar
first, then wrap with @() so the later += appends instead of string-
concatenating onto an unwrapped single-element array.

<a id="42e5cdfd-0033"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Remove existing VM

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Tear down any leftover host-side TCP forwarders from the retired
shared-NAT path (forwarder.<port>.pid pwsh subprocesses under
$HOME/yuruna/image/caching-proxy-service). With the bridged cache VM these
forwarders are no longer needed -- and if left running on
0.0.0.0:3128 they would conflict with anyone who later sets
YURUNA_CACHING_PROXY_SERVICE_IP=<host-lan-ip> pointing back at this Mac.
No-op on a fresh install. Stop-CachingProxyServiceVM.ps1 also calls this
symmetrically.

<a id="42e5cdfd-0034"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Host status-service bootstrap

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

The cache VM's cloud-init build block fetches the collector + parser source
from the LOCAL host working tree (http://<host>:<port>/yuruna-repo/) rather
than the public github mirror -- this repo is the source of truth. That needs
the status service running on this host when the guest builds (~20-35 min into
first boot). Start it now (detached; it persists past this script's exit) so a
standalone cache rebuild fetches local source. Honors statusService.enabled;
if disabled, the guest build falls back to github (the collector may be absent,
but the inlined Grafana dashboards still deploy).

<a id="42e5cdfd-0035"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Start the host status service

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

The cache VM mounts ystash-nas (for the Extension hosts crawl) and ypool-nas
using credentials it fetches at boot AND hourly from this service over mutual
TLS, so a rotated NAS password reaches the running VM with no rebuild (the fix
for the bake-once staleness). mTLS scopes access to VMs THIS host created --
each carries a client cert signed by this host's Config CA. Detached; persists
past this script. Best-effort: if it fails, the guest falls back to its baked
credential (rotation won't propagate until the service is up). Honors
configService.enabled (default true).

<a id="42e5cdfd-0036"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Start the host config service

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

The ensure above is best-effort: Start-ConfigService only WARNS (it never
fails) when its port never comes up, so verify it HERE, before Step 3 builds
the VM. New-VM mints the cache VM's mTLS client cert from THIS host's Config CA
(which this service initializes) and bakes it into the seed; the VM then fetches
its ystash-nas/ypool-nas credentials from this endpoint at boot. A service that
is DOWN at build time is the silent cause of a cache VM that bakes EMPTY mTLS
materials, never mounts ystash-nas, and shows an empty "Extension hosts" panel.
Surface it now (loudly) instead of leaving the operator to discover it later.

<a id="42e5cdfd-0037"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Register and start the UTM VM

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Auto-dismiss UTM's modal "this VM uses custom QEMU arguments which is
potentially dangerous" warning. The cache VM runs the QEMU backend with
-vnc AdditionalArguments (guest.caching-proxy-service/config.plist.template), so
UTM gates every launch behind that confirmation -- which would block
this unattended bring-up until a human clicks Continue. UTM exposes no
way to suppress it (it is a deliberate security gate), so reuse the same
osascript watchdog Start-UtmVM uses for the Start-TestRunner path.
Ensure the macOS host module (which exports the watchdog) is loaded --
Step 2/3's Get-Image / New-VM run -Force imports that can evict the
copy Step 1 loaded (feedback_module_force_import_evicts_global); only
re-import when the function is actually missing so we don't trigger
unnecessary nested-import churn.

On a freshly-imported bundle, `utmctl start` can return 0 at the RPC
level while UTM is still finalizing bundle ingestion, and the start
request is silently dropped -- the VM stays in 'stopped'. Verify the
transition by parsing `utmctl status` output and retry a few times.
`utmctl status` prints one of: started / paused / stopped / suspended.

Matched as an ALLOW-list on the one state that means "running". A
deny-list of the states known to be bad reads the same until UTM reports
something the list does not mention, and then it reads that as success:
'suspended' is a VM whose RAM has been written to disk and whose CPU is
not executing, which passes a "not stopped, not paused" test while being
exactly as unusable as 'stopped'. Everything after this point -- a 15
minute discovery sweep, then whatever waits on the service inside the
guest -- then spends its whole budget on a VM that is not running.

The two accepted words are the pair Confirm-UtmVMStarted accepts, so this
check and the host contract's cannot disagree about what running means. A
stricter list here would be its own hazard: a state the shared helper calls
running and this one does not is a bring-up that fails while the VM is up.

The exit code comes back with the output it belongs to, never
from $LASTEXITCODE, which a later pipeline stage or native call
can leave describing a different command. A call that timed out,
was cut short or truncated counts as no answer (-1). stderr is
read with stdout, so a refused status (Apple Events denied prints
"Error from event: ... OSStatus error -1743") is seen as text,
and it never matches a state word, so it is never read as the
VM's state.

The observed state is named because the ones it can be need different
things from the operator: 'stopped' is a start that never took,
'suspended' is a VM that started and was then saved to disk by
something else on this machine, and 'paused' is one deliberately held.
A status that never answered is its own fourth case -- utmctl reaches
UTM over Apple Events, which a host that has not granted Automation
denies outright -- so it is reported as silence rather than dressed up
as a state UTM never named.

<a id="42e5cdfd-0038"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Configure Shared NAT forwarding

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Identify the cache VM by its bundle MAC via ARP -- NOT by DHCP
hostname. A rebuilt cache reuses the name 'yuruna-caching-proxy-service',
so /var/db/dhcpd_leases accumulates stale same-named blocks from
deleted predecessors; a name lookup that runs before THIS VM
finishes DHCP locks onto a dead predecessor's IP and the forwarders
then tunnel to an address nothing listens on (guards the stale-
lease-discovery regression class). The VM is on UTM Shared NAT
(192.168.64.0/24) with the host as its gateway, so it ARPs the host
and appears in `arp -an`; Resolve-UtmGuestIpByMac also waits for
squid on :$httpPort, so the IP it returns is one squid is serving.

MAC/ARP discovery above can run minutes -- longer than the ~5-min
sudo timestamp primed in Step 0. Add-PortMap launches the :80
(sub-1024) forwarder via `sudo -E pwsh`; with a cold timestamp
that sudo prompts for a password ASYNCHRONOUSLY on the TTY,
racing this script's output with no context (the operator sees a
bare "Password:" mid-bring-up). Re-warm sudo now, with a clear
reason, so the privileged forwarder binds silently. Best-effort:
a declined prime skips the :80 forwarder (a remote-LAN
CA-cert convenience); everything else still comes up.

`utmctl ip-address` does not work for Apple Virtualization VMs
("Operation not supported by the backend"). The cache bundle uses the QEMU
backend; in Bridged mode its NIC attaches to the host's LAN interface.
We identify OUR VM by the MAC written into config.plist: an explicit
`-MacAddress` override, or a deterministic address derived from the host identity
and VM name by default. We look its IP up via the host's ARP table -- never by "first :3128 we find on the
LAN", which would happily lock onto a peer host's yuruna-caching-
proxy that DHCP'd before ours did. Matches the narrow
Test-CachingProxyServiceAvailable contract: only caches we own.

Identify OUR VM by the bundle MAC via ARP (Resolve-UtmGuestIpByMac):
the bundle is brand new (Step 3 just built it), so its config.plist
MAC is unambiguously the one the cache VM boots with. The helper
ICMP-sweeps the /24 to populate the ARP cache, matches our MAC, and
waits for squid on :$httpPort before returning -- never "first :3128
we find", which would lock onto a peer host's cache that DHCP'd first.
Same helper the Shared-NAT branch uses, so both paths share one
tested implementation.

<a id="42e5cdfd-0039"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Step 6: macOS bridged -- tear down legacy host-side forwarders

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Persist the cache VM's LAN IP so guest provisioners and the
status service's fast path don't have to re-discover it. The
host reaches the cache directly on the LAN (same /24); guest
provisioners base64-embed the CA cert by fetching it via
`curl http://<cacheIp>/yuruna-squid-ca.crt` from the host.

The re-import is mandatory after Step 5's Initialize-YurunaHost:
docs/workarounds.md#nested-non-global-import-evicts-a-callers-view-of-a-module

<a id="42e5cdfd-003a"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Linux -- re-query the cache VM IP for persistence + summary

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

LAN exposure. On a network verified to use host bridging, the VM has
its own LAN IP and remote consumers reach it
directly at $cacheIp. On the NAT 'default' network the VM is
host-only, so Add-PortMap installs systemd socket-activated
forwarders (systemd-socket-proxyd) and LAN clients reach the cache
at the HOST's LAN IP. See Add-PortMap in host/ubuntu.kvm/modules/
Yuruna.Host.psm1 for why socket forwarding rather than nftables
DNAT: libvirt's own forward chain rejects DNAT'd inbound to its
NAT guests, and overriding that is firewall-backend-specific.

The pool DASHBOARD does not work on this NAT path, and the forwarder
cannot make it work: systemd-socket-proxyd re-originates every
connection from the host, so squid records ONE client IP (the NAT
gateway 192.168.122.1) for the entire LAN. The pool-aggregator-service
discovers hosts by their real squid-log client IP, so it discovers
none and http://<this-host>:3000/d/yuruna-pool/yuruna-hosts shows
"No data". A caching-proxy service that only caches (same-host guests) is
fine on NAT; the multi-host pool view needs the cache VM BRIDGED so
squid sees real client IPs (the macOS UTM / Hyper-V cache VMs are
bridged, which is why their pool dashboards populate).

<a id="42e5cdfd-003b"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Windows -- discover the cache VM and expose its ports to the LAN

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Expose the cache VM's ports to the host's LAN so remote clients can
reach squid (:3128 / :3129), Apache (:80 serving yuruna-squid-ca.crt),
and Grafana (:3000). Local guests on the Default Switch already reach
the VM directly (172.25.x.x NAT subnet is visible from the host and
from every Hyper-V guest on that switch), so this portproxy adds LAN
exposure without changing the local-guest path -- those still target
the VM's private IP. The port list matches Invoke-TestRunnerInnerLoop.ps1's
Add-PortMap call; mismatched lists fight each other because
the function runs Clear-AllCachingProxyServicePortMapping first. Requires
elevation; Add-PortMap warns and no-ops otherwise.

If the cache VM is on an External vSwitch, it has its own LAN
IP via DHCP and remote clients reach it directly -- squid sees
real client IPs at TCP level, no host-side forwarder needed.
Tear down any leftover netsh portproxy / firewall rules from
a prior Default-Switch cycle so they can't NAT-rewrite traffic
to a stale host:port path. On the Default-Switch fallback,
set up netsh portproxy as before -- kernel-mode IP Helper is
the only LAN-reachable path on this Hyper-V host (the user-
mode pwsh forwarder is silently dropped by Defender / EDR /
WFP regardless of rules -- see docs/caching.md).

<a id="42e5cdfd-003c"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Report the service state

Applies to:

- [test/service/Start-CachingProxyServiceVM.ps1](../test/service/Start-CachingProxyServiceVM.ps1)

Wi-Fi/Shared NAT: the cache is at $cacheIp (192.168.64.x). On macOS 26
UTM vmnet-shared every VM joins one bridge (192.168.64.1) and guests
route to each other directly, so THIS host AND a test VM started on
the same Mac reach the cache at $cacheIp with no env var and no
host-side forwarder -- the guest auto-discovers it. The pwsh
forwarders at $cacheLanIp exist ONLY for remote LAN hosts and are
best-effort: any cycle that runs Remove-PortMap (a test run, a
status-service restart) tears them down, so $cacheLanIp is not a
reliable steady-state address.

<a id="42e5cdfd-003d"></a>

## test/service/Start-StatusService.ps1: Module setup

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

Two starts for one runtime must not interleave: a start that finds a server
not yet answering reads it as dead, and the normal path then stops it. The
startup lock serializes them. It lives in the private state root, keyed by
runtime, because the runtime directory is served and lock metadata there
would be public, and so two checkouts' listeners never wait on each other.
The normal start waits a bounded time and then proceeds without it (a
start that never happens is worse than the race); the refresh-safe start
refuses instead, because its whole promise is to disturb nothing.

The lock is an open handle held by this process. The normal start is
&-invoked inside the long-lived inner runner, so a handle that leaked past
this script would block every later start for the life of that process:
every exit below releases it first, and the trap releases it on any
uncaught error while letting the error propagate unchanged (the tagged
port-conflict exception included).

<a id="42e5cdfd-003e"></a>

## test/service/Start-StatusService.ps1: Startup serialization and the refresh-safe outcome

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

The detached server bakes the ~3.5 KLOC here-string (and the modules
it imports at startup) into its in-memory state. Files under test/status/
are served from disk per request, so frontend edits do NOT need a
restart; only a change in the framework code does. We persist the
framework HEAD SHA to server.sha at launch and compare it here, so the
zero-change cycle of the inner runner (the common case) is a no-op
instead of a 1 s teardown + multi-second relaunch. Cycle-start downtime
drops from "every cycle" to "only when `git pull` actually pulled
something that affects the server".

<a id="42e5cdfd-003f"></a>

## test/service/Start-StatusService.ps1: Check for an existing server

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

Resolve port conflicts from untracked orphan detached servers.
Why it's needed and the Test.PortOwner.psm1 dispatch contract:
https://yuruna.link/42d38664

-Elevate: take the port even when the holder is one this account cannot stop.
The holder in that case is almost always a status service this same harness
left behind as ROOT during an earlier sudo run -- invisible to an unprivileged
lsof, immune to an unprivileged kill. Handing that back as instructions makes
the operator finish a cleanup the harness caused and can do itself; it already
has (or can ask once for) the authorization. Every target is named as it is
stopped, and this process, its ancestors and pid 1 are never candidates.

The refresh-safe start takes nothing: a port anyone holds is reported, and
the privilege case is told apart from a real holder for the same reason the
normal path tells them apart.

Refuse, and make the refusal PROPAGATE. A bare `exit 1` here would only
set $LASTEXITCODE for the call-operator invocation the shared gate runs
(`& $StartScript`), so the parent cycle would carry on without a status
server -- the blind-cycle trap this guards against. Throw a tagged
exception instead: Start-YurunaStatusServiceIfEnabled recognizes the tag
and aborts the entry point cleanly; a standalone run exits non-zero on the
uncaught throw. The detection is OS-agnostic (HttpListener bind probe), so
this fires identically on macOS/UTM, Ubuntu/KVM, and Windows/Hyper-V.

<a id="42e5cdfd-0040"></a>

## test/service/Start-StatusService.ps1: Ensure repoUrl is set in status.json

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

server.heartbeat: server no longer reads this; tidy up so inspectors
don't think it's load-bearing.
Legacy paths directly under test/status/ and under the old
test/status/track/ (now test/status/runtime/): older on-disk layouts
place server.pid, runner.pid, status.json, server.err,
current-action.json, control.*-pause, .status-service.ps1 in those
locations. A checkout upgrade can leave those untracked (no longer
.gitignored), cluttering `git status`. Drop them on every start so
operator runs land on a clean status dir.
The refresh-safe start skips this sweep: it removes the break sidecar and
the continue flag, which a held runner still needs.

<a id="42e5cdfd-0041"></a>

## test/service/Start-StatusService.ps1: Clean up leftovers from older layouts

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

UI footer reads this to show reachable addresses. Loopback
(127.0.0.1, ::1) excluded -- useless for remote clients.

File format:
  * No addresses  -> single line "No IP addresses detected"
  * Addresses     -> up to two lines:
      line 1: IPv4, comma-separated (omitted if none)
      line 2: IPv6, comma-separated (omitted if none)

Split IPv4/IPv6 so the UI renders two short rows instead of one long
run. File is overwritten on every Start-StatusService invocation so
stale entries from a previous host/network are not preserved.

<a id="42e5cdfd-0042"></a>

## test/service/Start-StatusService.ps1: Detect host type

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

macOS: the Remove-PortMap calls in the port-map region below are clear-ALL,
so they stop every host-side forwarder -- and killing the root-owned :80
forwarder that Start-CachingProxyServiceVM created on the Shared-NAT path
needs sudo. Left to itself that fires a bare "[sudo] password for ..." deep
in the run, including on the unattended per-cycle path. Detect the exact
condition and announce the reason NOW, so the prompt is never a surprise and
a host without such a forwarder is never asked. Mirrors the same detection in
Stop-CachingProxyServiceVM.ps1; self-contained (pidfile + /bin/ps), no import.

<a id="42e5cdfd-0043"></a>

## test/service/Start-StatusService.ps1: Announce the forwarder teardown's sudo

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

This script is reached IN-PROCESS by all four service bring-ups
(Start-YurunaStatusServiceIfEnabled), and those run with their output
captured by whatever started them -- install/setup.ps1, a runner cycle.
A password prompt there is invisible: the text goes to a log and the
run waits on a keystroke nobody knows to press. So when the caller has
declared the run non-interactive, probe with -n and report instead of
asking. The trigger is a root-owned forwarder from an earlier
bring-up, i.e. precisely the re-run case, which is why this fires on
the machines least able to answer it.

<a id="42e5cdfd-0044"></a>

## test/service/Start-StatusService.ps1: Probe proxy cache -> $env:YURUNA_RUNTIME_DIR/caching-proxy-service.txt

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

-Quiet: this probe DECORATES the dashboard banner with the cache URL
when a cache exists. Having none is an ordinary state -- and it is the
GUARANTEED state when the caller is Start-CachingProxyServiceVM.ps1,
which starts this service in the step right before it creates the
cache. Warning there, and telling the operator to point
YURUNA_CACHING_PROXY_SERVICE_IP at a remote cache, describes a problem
nobody has. The runner's own bootstrap probe stays loud: a missing
cache there silently costs the whole cycle its downloads.

Resolve the operator's configured cache FIRST. The probe consults only
$Env:YURUNA_CACHING_PROXY_SERVICE_IP and this host's own cache-VM state
file -- never vmStart.cachingProxyIp -- and that environment variable is
published by the cycle's caching-proxy gate. A status service started by
anything other than a running cycle therefore probes with neither source
set, finds nothing, and reports a remote cache that is up and serving as
absent. The same file is where the Dashboards link comes from, so the
wrong answer also removes the link at the moment an operator goes
looking for it. Resolving here applies the same precedence and the same
:3128 acceptance the cycle applies, so the banner names the cache the
cycle would use -- or stays silent when nothing answers.

Port mapping so the status-page banner reports the same
state as Start-TestRunner's console output.
Add-PortMap dispatches per-platform via the host driver
(netsh portproxy on Hyper-V, detached TcpListener
forwarders on macOS/UTM). Both channels read
the same caching-proxy-service.txt so banner and console stay
in lock-step.

Windows: port lists across callers MUST match -- Add-PortMap
runs Clear-AllCachingProxyServicePortMapping first (netsh clears all), so
any port omitted here would be torn down. macOS: per-port pidfiles
mean each caller manages its own subset independently; no match
required. The macOS fallback includes port 80 and Grafana on 3000; the
bridged-cache path uses the VM address directly.

External-cache branch: when $Env:YURUNA_CACHING_PROXY_SERVICE_IP
is set, Test-CachingProxyServiceAvailable returns the remote URL and
the remote host exposes all its ports itself. Skip the
local portproxy/forwarder entirely -- the dashboard link
points straight at the remote IP.

External handling below removes this host's
forwarders, so it may only run when the endpoint is
POSITIVELY not this host. 'local': the endpoint is this
host's own forwarder set fronting its NAT'd cache VM --
removing it severs the listeners that just answered the
probe (self-teardown). 'unknown': transient NIC-
enumeration gaps must land on the local side, because a
wrong 'external' verdict tears the forwarders down while
a wrong 'local' verdict merely re-asserts a port map.

Initialize-YurunaHost was already called above; Add-PortMap /
Remove-PortMap / Get-BestHostIp are now resolvable via Yuruna.Host.

Serialize the whole discriminate-and-write block against the
runner's per-cycle refresh and against a caching-proxy-service
bring-up. Add-PortMap is clear-all-first, so two writers whose
port lists differ tear each other's netsh mappings, firewall
rules and forwarders down; and a forwarder installed in front of
a BRIDGED cache replaces the direct LAN path with kernel NAT,
which loses the client source IP squid logs. Try-once with the
same policy the runner uses: a live holder owns the maps for the
duration of its own work and the next start re-applies.

Local-cache port-map target IP: on Windows
Test-CachingProxyServiceAvailable returns the VM's direct
IP (Hyper-V Default Switch is reachable from the
host), so parsing works. On macOS the URL is
http://192.168.64.1:3128 -- the VZ-gateway URL
guests use, NOT the cache VM. Feeding 192.168.64.1
to Start-CachingProxyServiceForwarder would make the
forwarder tunnel to its own listen socket (self-
loop: TCP accepts succeed, nothing reaches squid,
subiquity sees "Connection failed [IP: 192.168.64.1
3128]" and falls back to offline install). Read
the real VM IP from the yuruna-caching-proxy-service state
file written by Start-CachingProxyServiceVM.ps1.

macOS fallback: status startup selects ports 80 and 3000, plus the
configured HTTP and HTTPS proxy remaps. Each port has its own pidfile,
so refreshing one does not remove the others. The normal bridged-cache
path removes host forwarders and uses the cache VM's LAN address.
On Windows, all caching-proxy-service port mappings are repeated in every
caller's list because Add-PortMap clears Yuruna netsh and firewall state
first; omitting any here would tear it down each status-service restart.

Windows External-vSwitch fast path: when the cache
VM is bridged to LAN (its own routable IP), remote
clients reach it directly and squid sees real
client IPs at TCP level. Tear down any prior netsh
mappings so the alternate host:port path doesn't
silently NAT-rewrite a parallel route.
Yuruna.Host's Test-CacheVMOnExternalNetwork inspects the cache VM's
actual attachment. Windows requires an attached External-type vSwitch without
a positively degraded uplink; macOS requires a readable bundle in Bridged mode.
Shared NAT and missing macOS attachment evidence return false.

HTTP/HTTPS port mapping is platform-divergent on the
Default-Switch fallback (see docs/caching.md
for full rationale): macOS uses pwsh forwarder +
PROXY v1 (real LAN IPs); Windows uses plain netsh
portproxy because the user-mode listener path is
unreachable from LAN on this host (squid logs the
NAT-side IP -- see docs/caching.md).
The macOS fallback includes :80 so the VM's landing page remains reachable;
its normal bridged-cache path needs no privileged host bind.
Port values come from YURUNA_CACHING_PROXY_SERVICE_*_PORT
env vars (defaults 3128 / 3129).

The exposed-port set (incl. 9302 caching-proxy-parser-service
live tail) comes from Get-CachingProxyServiceExposedPort so it
cannot drift from Start-CachingProxyServiceVM's install list;
Add-PortMap is clear-all-first, so a dropped port goes
dark on reinstall. macOS re-maps only the two ports an
operator opens by hand: Grafana, and 80 -- which is
where the caching-proxy VM's landing page lives, and
therefore where the Dashboards link below points.
Without 80 that link reaches nothing from a Mac host.

Port 80 on the caching-proxy VM, which serves that VM's landing
page: an index of the Grafana dashboards and the extension
services, each linked only where it is actually reachable.
Deliberately NOT a deep link into Grafana -- that page is a
single-page app, so an older browser that cannot run it lands
on a blank screen with nothing to fall back to, while the
landing page is plain server-rendered HTML that says what
exists and lets the operator choose.

runtime/host-network.txt (the banner the status page renders) and
runtime/host-network.json (the record host.registration.json advertises) are
served by the /runtime/* handler below like every other runtime file, and are
written by exactly one owner: the runner's cycle-start guest-network gate.
That gate is the only thing that observes the host's switch state once per
cycle, so it alone can advance the consecutive-cycle count on the pair. A
second writer here would either re-open a banner the gate had just cleared or
freeze the count at whatever the last service start happened to see -- this
service is long-lived and restarts far more rarely than a cycle runs.

<a id="42e5cdfd-0045"></a>

## test/service/Start-StatusService.ps1: Detached server launch

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

Write the server script to a file and launch with -File rather than
base64-encoding it onto the command line. The server script grew past
~23 KB of source, which becomes ~61 KB when base64(UTF-16LE) encoded --
that plus the pwsh.exe path (on Windows Store installs, pwsh resolves
to a 100+ char Microsoft.PowerShell_*_8wekyb3d8bbwe\pwsh.exe path)
pushes the command line past the Windows CreateProcess 32,767-char
limit. The failure mode is a Start-Process error reading
"The filename or extension is too long" which is obscure and easy to
misread as a path problem. -File sidesteps the size limit entirely:
pwsh reads the script from disk instead of its command line.
Drop the previously generated server script (.status-service.ps1) and its
stdout log (server.out) so an upgrade does not leave a stale, misleading copy
under the runtime dir that an inspector could mistake for the live server.
Runs before the current script is written below.

The server body above is a here-string: THIS process only ever parses it as
text, and the detached child is the first thing that parses it as code. So a
syntax slip that survives the escaping -- "$var:" (a colon right after a
variable name reads as a scope qualifier), a `" that collapsed into a bare
quote -- costs nothing at write time and kills the child on its first line.
Without this gate the operator sees none of that: the launch "succeeds", the
readiness probe below burns its full budget, and the report names the PORT,
sending the search to port ownership when the real defect is a typo in the
generated file. Parse it here, where the error is exact and instant.

Explicit stdio redirection on Windows is REQUIRED for outer-runner
liveness. Without -RedirectStandardOutput / -RedirectStandardError,
this grandchild inherits the parent's console handles. The chain
is: Start-TestRunner.ps1 spawns modules/Invoke-TestRunnerInnerLoop.ps1 with
Start-Process -NoNewWindow (shared console); the inner here spawns
the long-running status service which without explicit redirection
also inherits those shared handles. When the inner cycle ends and
the outer's WaitForExit() returns, the grandchild still holds the
console handles open -- which on Windows can keep the outer's
Start-Process -Wait pinned past the inner's actual exit, producing
the symptom "[outer cycle N] outer runner back in control" never
firing on outer.log even though the inner clearly emitted its
final cycleDelaySeconds-wait-complete line. Redirecting to files
gives the grandchild dedicated handles and breaks the chain.

-RedirectStandardInput against a real empty file is non-optional on
Windows: without an explicit stdin redirect, the detached child
inherits the parent console's stdin handle and conhost cannot tear
down when the parent pwsh exits, leaving the operator's PowerShell
window in a multi-second to indefinite close-pending state. Passing
'NUL' / '\\.\NUL' does NOT work because Start-Process runs the value
through Resolve-Path, which prepends the current directory and then
the underlying FileStream open fails on the bogus cwd\NUL path. The
macOS branch below achieves the same effect via '</dev/null' in the
bash invocation -- bash's redirection accepts the device name
directly, so no sentinel file is needed there.

On macOS/Linux, detach the status service from the test-runner shell's
terminal job. `bash -c` runs a NON-interactive shell, so job control is
off and a bare `&` leaves the backgrounded process in the caller's
process group: exiting that shell then lingers because its terminal job
still has a live member. `set -m` turns job control on for this shell,
so `&` places the server in its OWN process group (bash setpgid's it).
`nohup` ignores SIGHUP and stdin/stdout/stderr are redirected off the
tty, so the server cleanly outlives the caller. (macOS has no `setsid`,
so a new session is not available here -- a new process group plus
nohup is what decouples it from the caller's exit.)

<a id="42e5cdfd-0046"></a>

## test/service/Start-StatusService.ps1: Verify server started

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

Host-address beacon. Guests resolve a moved host through the pool directory,
and that directory can only be as current as what reaches it: its own
discovery tails the squid access log, which is pull-only and so lags exactly
when it matters -- a host appears there when it or its guests pull through
the proxy, so between cycles the view ages out and still names the address
the host has just left. This is the push half.

Spawned only once the port answered. The beacon advertises THIS service; an
announcement for an address nothing serves would be worse than none, and the
probe above is what distinguishes the two.

Detached rather than a timer inside the server: that process waits
indefinitely for its next request (it wakes early only to finish a request
body it is reading), so it has no periodic tick site.
Same idiom as the pool push forwarder. Single-instance via its own lock, so
the per-cycle Start-StatusService call cannot stack beacons; spawn failure is
non-fatal, exactly like every other best-effort pool hook.

-NonInteractive is load-bearing, not decoration: a cmdlet reached with a
missing Mandatory parameter PROMPTS, and a prompt in a detached process with
no console never returns. It converts that whole class from a silent hang
into a logged throw the error file captures.

<a id="42e5cdfd-0047"></a>

## test/service/Start-StatusService.ps1: Host-address beacon

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

Ask whether a beacon is already running BEFORE spawning, rather
than spawning and letting its own lock turn the surplus process
away. The beacon follows server.pid rather than a process handle,
so one that predates this restart keeps ticking for the service
started here and nothing needs launching -- while the spawn itself
is not free of side effects: the redirection files below are opened
by the PARENT, so a live beacon still holding them makes
Start-Process throw before the new process ever reaches the lock.
That turns the ordinary every-cycle case into an exception, which
is why a real spawn failure has to be told apart from it here.

An OPEN probe, not Test-Path: the beacon deletes the file on a
clean exit, so a lock file that survives a kill names no holder and
must not wedge the next beacon out.

<a id="42e5cdfd-0048"></a>

## test/service/Start-StatusService.ps1: Display connection info

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

A caller that just started this service should not have to guess its address.
The pool-control service publishes a marker its callers read; with nothing
equivalent here, a prober falls back to whatever constant it was configured
with and can spend its whole timeout on a host this service never ran on.

Written as its own file rather than through the extension-service marker
helpers: those are keyed by an extension area with a service manifest behind
it, and the status service is host-side infrastructure rather than an
extension. Reusing that mechanism would mean declaring it to be one.

<a id="42e5cdfd-0049"></a>

## test/service/Start-StatusService.ps1: Publish where this service can be reached

Applies to:

- [test/service/Start-StatusService.ps1](../test/service/Start-StatusService.ps1)

The server binds to http://*:$Port so the socket is on every interface, but a
host firewall silently DROPs inbound TCP on non-loopback interfaces without an
allow rule -- so the localhost probe above passes while a LAN browser (and the
pool-aggregator service) time out. Best-effort SELF-HEAL: ensure the allow rule when
this start is privileged (Windows admin / Linux root|sudo), else warn with the
durable-fix pointer only when we can positively determine it's blocked.
-NonInteractive so an unprivileged start never prompts and hangs; an
indeterminate state (e.g. can't read ufw unprivileged) stays quiet -- host
setup (Enable-TestAutomation) is the durable owner, which matters for a host
whose runner is stopped and so never re-runs this per-cycle start.
The refresh-safe start edits no firewall: a rule change is host
configuration, and the listener it restores was reachable before.

<a id="42e5cdfd-004a"></a>

## test/service/Stop-CachingProxyServiceVM.ps1: Clear an abandoned bring-up lock

Applies to:

- [test/service/Stop-CachingProxyServiceVM.ps1](../test/service/Stop-CachingProxyServiceVM.ps1)

Stopping the service IS the operator's reset action, so it owns the recovery
from a leaked caching-proxy-service.lock. The leak does not self-heal: a .ps1
runs inside the caller's pwsh, so a bring-up that exits without releasing
records the operator's long-lived interactive shell as the holder -- that shell
stays alive, the acquire-time stale drain never fires, and every later Start is
refused ("Another caching-proxy-service bring-up holds the lock").
A genuinely LIVE FOREIGN holder (a real rebuild in another process, still
inside the age ceiling) is only reported: Stop must not steal the lock from it.
Done FIRST -- before the teardown touches the VM -- so that warning reaches the
operator while aborting is still cheap.
The runtime dir mirrors Start-CachingProxyServiceVM.ps1's $envSidecarDir exactly;
the module's own fallback is the temp dir, which is NOT where Start writes.
Get-Command-guarded like Invoke-TestRunnerInnerLoop.ps1 guards its lock calls, so
a partial module set degrades to the previous (no-op) behavior instead of erroring.

<a id="42e5cdfd-004b"></a>

## test/service/Stop-CachingProxyServiceVM.ps1: Clear an abandoned caching-proxy-service bring-up lock

Applies to:

- [test/service/Stop-CachingProxyServiceVM.ps1](../test/service/Stop-CachingProxyServiceVM.ps1)

Symmetric with Test-CachingProxyService.ps1 -SetHostProxy. Runs UNCONDITIONALLY
and uses Remove-HostProxy (definitive wipe) rather than the older
Clear-HostProxy (snapshot/restore from $HOME/.yuruna/host-proxy.backup.json).
Definitive wipe is the right model here: any HTTP_PROXY/HTTPS_PROXY env
var or WinINet ProxyServer string left after Stop-CachingProxyServiceVM is, by
definition, pointing at a cache VM we are tearing down -- restoring
whatever was there before leaks a stale IP into the next cycle.
Done first so a failure tearing down the VM doesn't leave the host
pointing at a dead proxy for the rest of the session.
On macOS networksetup requires root -- the sudo preamble above guarantees
we are already elevated by the time this runs.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
