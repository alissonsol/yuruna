<a id="42e220c4-0001"></a>

# Source consistency across hosts and guests

Related host providers, guest installers, VM seeds, and project test sequences
share a maintenance contract. Compare the corresponding regions together when
changing a common behavior; retain differences required by an operating system,
hypervisor, service, or measured workload.

<a id="42e220c4-0002"></a>

## Region conventions

Use `# --- REGION: <label>` for a named block and
`# --- REGION: https://yuruna.link/42xxxxxx-yyyy` for its rationale.
Keep the same label and relative order wherever the blocks have the same role.
Do not put empty lines after a region marker; its content starts on the next line.
Use short labels such as `Install log`, `Configuration`, `Remove existing VM`,
`Fetch the framework`, and `Build and start the service`. Explain an ordering
exception at the affected block, with a link to its durable rationale.

Other comment syntaxes keep the same label in their native form: `<!-- REGION: <label> -->`
in XML, HTML and plist templates, `/* REGION: <label> */` in CSS, and `-- --- REGION: <label>`
in SQL. A rationale link in a file header is an ordinary `See https://yuruna.link/...` line,
because no block follows it.

Treat region labels as shared vocabulary, not prose to paraphrase. Recurring
host phases use `Log level from environment`, `Import host modules`, `Seek the
base image`, `Remove existing VM`, `Create copies and files for VM`, `Stage the
cloud-init seed directory`, `Clean up temporary files`, `Installation summary`,
and `Completion`. Service guests keep
`Initialize environment`, `Detect architecture`, `Load retry helpers`, `Service
user`, `Load service helpers`, `Service locale`, `Service tunables`, `Storage paths`, `Package
dependencies`, `Locate the daemon source`, `Build`, `Install the binary`, `Storage directories`,
`Environment file`, `systemd unit`, and `Start the service and wait for
readiness` in that order; service-specific regions may sit between those shared
phases. Reuse labels exactly, including case, whenever a block has the same
role; do not introduce synonyms such as `Install logging`, `Storage dirs`, or
`Cleanup temporary files`.

When a region introduces a standard marker, use that marker's exact name and
case: the YAML key, plist key, XML/HTML element name, or bracketed systemd/INI
section such as `[Service]`. Do not expand it into
a descriptive title. A substitution placeholder is not such a marker: naming a
`<NAME>_PLACEHOLDER` token in any comment makes that comment a second injection
site, because substitution is substring-based over the whole file. A multi-line
value then leaves only its first line behind the `#` and splices the rest at the
comment's indentation. Label the region with the key the substituted block
produces instead: `apt` for the block replacing `APT_PROXY_BLOCK_PLACEHOLDER`.
Test sequences have only `resource`, `component`, and `workload` regions,
placed before their corresponding top-level keys:

```yaml
# --- REGION: resource
resource:
```

Sequence variables and individual actions do not need regions. Keep useful
explanations and documentation links in ordinary comments, such as
`# See https://yuruna.link/42e220c4-0007`, without making them region labels.
The same rule applies to documentation links beside other structural markers.

The anchor gate resolves published Markdown targets in every inventoried
workspace checkout, including yuruna.link's own maintenance guide. A broken or
missing local target fails the check; a target outside the available checkouts
is reported as unresolvable because no local document can establish its anchors.

Keep function help, license headers, shebangs, diagnostic output, and parser
directives intact. The `# === YURUNA_OVERLAY_<KEY> ===` lines are merge tokens,
not decorative dividers: their names must pair between a base and every overlay.
Preserve shell indentation and YAML block-scalar indentation when moving comments.

When a region precedes a PowerShell function, place that function's comment-based
help inside its body, before attributes and `param`. A region line directly
against an external help block can prevent PowerShell from discovering the
help. Internal placement preserves both the region spacing and `Get-Help`.
Keep parameter help in that help block, outside `PSScriptInfo` metadata. Put
only the parameter name on its `.PARAMETER` line and the description on the
following lines; PowerShell otherwise includes the description in the name
and cannot associate it with the parameter.

Long explanations belong in Markdown. Prefer an existing specific topic over
duplicating it here, and retain a brief local warning when moving it would hide
a surprising constraint. Stable heading IDs keep source references valid through
renames and translation; generate the anchor manifest and link catalog after
adding a target.

<a id="42e220c4-0003"></a>

## Image acquisition

Service image wrappers select a guest identity and host format, import the
shared image and logging modules, validate the host, then call the shared image
acquisition helper. Their common contract belongs in the shared helper; platform
wrappers retain only platform and guest parameters.

Resolve `Save-CachedHttpUri` to the active host driver's two-parameter wrapper.
The shared download module's additional `ResolveCacheHostIp` parameter signals
incorrect import precedence: calling that helper directly bypasses the driver's
local cache discovery.

Ubuntu checksum authentication pins the primary CD Image and UEC signing-key
fingerprints. Verify the detached signature against the same saved
`SHA256SUMS` file used to select the artifact hash. Unavailable verification may
leave an image explicitly unverified; a bad or foreign signature must fail.
Before rotating a pinned key, independently verify a fresh `SHA256SUMS.gpg`
and then refresh the fingerprint pins.

All service families on one host share the same downloaded Ubuntu cloud image.
Hyper-V converts it to VHDX once. Keep the base image's native capacity and grow
the private per-VM copy to the service's configured size. Import the host driver
before discovering a cache; direct fetching remains available while the cache
itself is being bootstrapped. Reuse an already imported logging module so a
child wrapper cannot evict its caller's state. Explicit success exits prevent
a harmless native probe's stale exit code from reporting a failed download.

Ubuntu test guests use the live server installer ISO: Subiquity supplies the
autoinstall prompt, late commands, and installed kernel/package-source setup
expected by the test sequence. Architecture follows the host: ARM64 on Apple
silicon, native `uname` architecture on KVM, and OS architecture on Windows.
Release and daily image selection use the same fallback policy. The Ubuntu 26
daily-image option retains a workaround for early 7.0.0-14 installer kernels
whose overlayfs failures could interrupt curtin extraction.

Ubuntu 24 and 26 entrypoints delegate image acquisition and VM creation to
one shared implementation per provider. Keep release identity and release-specific
operator message keys in the thin wrappers. Hyper-V's shared builder retains Ubuntu
26's MAC spoofing and ARM64 provisioning cap of one processor; Ubuntu 24's
ARM64 default cap remains two. These release-specific workarounds stay explicit
instead of requiring two copies of the full provisioning workflow.

**Artifact selection and provenance.** Windows uses `OSArchitecture`, because an
x64 PowerShell process under ARM64 emulation reports its process architecture
through `PROCESSOR_ARCHITECTURE`. Hyper-V cannot emulate the other architecture.
When adopting manually supplied Windows media, ARM64 requires an ARM token in
the filename; AMD64 rejects that token but accepts x64 media without an explicit
architecture token. KVM's Windows builder requires an x86-64 host and uses the
same ARM-token rejection when adopting an ISO. Amazon publishes no ARM64 Hyper-V artifact, so that path
converts its KVM qcow2. Conversion alone does not make it bootable: the AL2023
ARM64 kernel lacks the Hyper-V disk and network drivers, so the downloader warns
while allowing an operator to stage the VHDX. See [the boot limitation](https://yuruna.link/42dc5bb9-0004).

Apple's `VZMacOSRestoreImage.fetchLatestSupported` chooses an IPSW for the current
hardware. The installer refuses a returned version below macOS 26, even if an
older host's catalog still offers macOS 15. The Swift helper emits
`URL<TAB>BUILD<TAB>VERSION`; stderr identifies
`version-below-floor`, `vz-catalog-fetch`, or `vz-other` so the operator receives
the relevant remedy rather than an unconditional Xcode instruction.

**Reliable image transfer.** The virtio-win URL names a version under
`archive-virtio/`. The stable/latest convenience links can redirect through
HTTP, which strict HTTPS clients and an inspecting proxy may refuse. To update
the pin, find the version in `stable-virtio/` and select its concrete archived
HTTPS file. This driver image uses the download-agent path before any origin
HEAD request; a healthy agent can satisfy a matching four-line sentinel without
transferring bytes. A missing or failing agent leaves direct downloading
available. Preserve the agent's original URL, size, and Last-Modified together;
reprobing the origin defeats that path and can discard a known timestamp. A
subsequent agentless request for a newer pin may download again, but it cannot
mistake the old bytes for that newer artifact.

Download and staging failures must stop the script before it reports success.
The retry closure captures `Save-CachedHttpUri` as a `CommandInfo` because a
foreign module's session state may not resolve the caller's command by name.
After a successful call, verify a nonempty destination and only then clear a
native cache-discovery probe's stale exit code. Missing or empty files throw a
useful failure for the retry policy instead of producing an unexplained retry
or false success.

Amazon Linux's adjacent qcow2 SHA-256 file is optional while a publisher upload
is incomplete. A published checksum mismatch deletes the artifact and fails;
a missing checksum remains a soft pass. A builder with missing installation
media invokes `Get-Image` once for all missing files, then rechecks every required
path. Windows media may require manual downloading. Hyper-V's Windows downloader
needs elevation for its host probe, BITS, and ProgramData; without elevation it
prints the same manual-download instructions used by the test runner.

**`host/macos.utm/guest.windows.11/Get-Image.ps1`.**

Fido refuses to run anywhere but Windows: Get-Platform-Version answers
0.0 off Windows and the command-line path exits 403 ("This feature is
not available on this platform.") before making any request. The
-GetUrl flow behind that gate is platform-neutral, so neuter the gate
-- AFTER the hash check, so only the verified pinned bytes are ever
patched. Without this the automated path can never work on macOS.

**`host/modules/Yuruna.HostDownload.psm1`.**

A platform that imports this module only for the sentinel/skip helpers has
no driver wrapper to bind Resolve-CacheHostIp, so the closure arrives $null:
no discovery means no cache to route through, so download direct. The
closure stays optional on purpose -- the image helpers feature-detect this
command by name and call it with just -Uri/-OutFile, and a mandatory
parameter would stall that call on an interactive prompt.

**`host/modules/Yuruna.UbuntuImage.psm1`.**

Ask the download agent before the origin is touched at all: when it
confirms the local copy IS the current artifact there is nothing to
resolve, HEAD-probe or transfer. Both the client module and a healthy
agent are feature-detected, so a lab with no agent -- or one whose agent
is down, has no pool, or errors mid-request -- falls through to the
resolve / same-source guard / download pipeline below.

Hard-fail on a genuine checksum MISMATCH (corruption or tamper,
never benign) and on a SHA256SUMS fetch still failing after the
bounded retry budget -- unverifiable bytes must not be promoted.
Only a definitively MISSING upstream checksum (HTTP 403/404/410 or
no line for this ISO) is a soft pass, and that returns $true from
Test-UbuntuServerImageChecksum and never reaches here.

Write the sentinel in the SAME format the skip-guard above reads back: the
4-line shape (filename + URL + size + Last-Modified) via Write-ImageSentinel
when the host driver ships Test-DownloadAlreadyCurrent, else the bundled
3-line shape that Test-UbuntuServerImageAlreadyCurrent reads. An asymmetric
writer/reader pair never matches, so the skip-guard would re-download every
run.

**`host/ubuntu.kvm/guest.windows.11/Get-Image.ps1`.**

The KVM host driver brings the skip-if-same-source guard + sentinel writer
(Test-DownloadAlreadyCurrent / Write-ImageSentinel, the shared 4-line filename +
URL + size + Last-Modified format) AND the cache-aware Save-CachedHttpUri
wrapper used for the virtio-win download below. (The Windows ISO is a manual
download -- Microsoft serves it only via short-lived signed URLs -- so it
cannot route through the cache.)

<a id="42e220c4-0004"></a>

## Host provisioning

A replacement build validates the base image before removing an existing VM.
It then stops and unregisters that VM before replacing its disk or seed files.
Writing a disk still attached to a running VM can damage both the current guest
and the replacement. Stop or removal failure must prevent those writes.
UTM builders use the same removal operation as teardown: stop, establish final
power-off and released disk locks, remove registration, then remove the bundle.
A failed final safety check preserves both registration and files. A stop
command's exit status alone is advisory when the final checks prove safety.

Ubuntu builders on all three hosts discover the caching proxy when its URL
parameter is unbound. A missing or stopped cache permits direct fetching; a
running cache with an unreachable proxy stops provisioning. An explicitly
bound URL, including an empty value for direct fetching, bypasses discovery.
UTM discovery consumes normalized states: a verified endpoint remains usable
when state discovery fails; only recognized stopped or absent state permits
implicit direct fetching. Running-but-unreachable or unknown state requires
repair or an explicit URL override.

Amazon builders keep SSH-key acquisition, the vault user password, host
coordinates, user-data rendering, and seed-ISO generation in the same relative
order. Cloud-init expires the initial password for the console sequence's
Current/New/Retype rotation. Hyper-V and UTM copy their private disk before
rendering; KVM delays replacing its qcow2 overlay until seed generation succeeds.
Every KVM Linux builder resolves its network and reachable host address once,
as a pair, before rendering. Its explicit address override remains authoritative.

Amazon Linux 2023 boots a prebuilt cloud image. Its builders do not seed a dnf
proxy address: the address could go stale before the guest can verify it, which
would strand package transactions. The guest update script discovers and probes
the caching proxy at runtime. `Invoke-PerGuestNewVm` forwards
`-CachingProxyServiceUrl` only to builders that declare it, so its omission from
all three Amazon builders is intentional.

Child builders receive only overrides they declare. Preserve the distinction
between an unbound caching-proxy URL and an explicitly empty URL: the empty
value selects direct fetching and must not trigger discovery. Local cache
probes consult saved addresses and report remediation for the discovered
state; a stopped cache needs starting rather than rebuilding.

Decide whether a cache VM is directly reachable on the LAN from its recorded
attachment. UTM reads the bundle's actual network mode; KVM resolves the first
NIC's libvirt network and its forward mode. A custom network name does not
establish bridging, and today's host uplink does not describe an existing VM's
attachment. Only verified bridging permits skipping or removing host port
forwarders; NAT, routed, isolated, missing, and unreadable configurations do not.

Hyper-V creates and starts a registered VM through host cmdlets. KVM imports and
starts a libvirt domain. UTM first creates a bundle; the caller registers and
starts it in the logged-in GUI session. These differences determine where
startup and address discovery occur. Format conversion, Hyper-V switch settings,
KVM permissions, and UTM bundle layout remain platform-specific.

Force-stop requests retain the same contract across providers. UTM implements
`Stop-VM -Force` with `utmctl stop --kill`; an ordinary stop remains graceful.
Failed domain lookups do not prove absence. If KVM unregistering fails, require
a successful domain inventory that excludes the VM before deleting its files.
An unavailable libvirt connection must leave those files intact.
Require this inventory after successful undefine too: libvirt can undefine an
active VM after an earlier stop failed, leaving a transient domain using the
same disk. Only a successful complete inventory excluding its exact name
permits storage deletion.

Orphan sweeps on every provider return 0 only when their owned cleanup completed,
and 1 when deletion or registration checks fail. UTM requires a recognized
status or explicit `not found` answer; AppleEvents denial, timeout, and unknown
output do not prove absence and must preserve the bundle. Continue best-effort
cleanup for other artifacts while retaining the failure outcome. The parent
test-VM cleanup propagates that outcome and fails when its final inventory is
unreadable or still contains matching VMs.

Disk snapshot saves and restores must establish power-off before replacing or
applying checkpoint metadata. A successful stop alone is insufficient: query
again. KVM requires a present domain with raw `shut off`, rather than normalized
stopped states such as paused or in shutdown. Hyper-V requires a present VM in
`Off` or `OffCritical` and rejects saved RAM state. UTM can also snapshot an
unregistered bundle: it requires recognized stopped or absent state plus proof
that QEMU and disk locks have cleared. Unconfirmed power-off preserves existing
snapshot metadata. Hyper-V and KVM also reject failed stops and absent VMs; UTM
may proceed when its final state and disk-lock checks establish safety.
Saves attempt graceful shutdown first; rollback may force-stop because the
current writes will be discarded.

Teardown also removes managed-save, snapshot, checkpoint, and NVRAM metadata
where libvirt supports them. A failed domain inventory is an error, not evidence
that the VM is absent. The shared SSH key must match the harness diagnostics key;
admin credentials come from the persistent authentication vault. A new test
cycle must not reset either. Versioned guest usernames help distinguish logs,
and deterministic guest MACs follow the durable hostname rather than a temporary
VM name. Bake the host address reachable through the selected guest network.

Pin DHCP identity before networking starts. Never disable networking globally
to apply that pin: NetworkManager persists its networking-enabled flag in
`/var/lib/NetworkManager/NetworkManager.state`, so an interrupted disable/enable
pair can leave the guest offline across reboots. A durable hostname also keeps
the MAC stable when a test slot is promoted to its final VM name. Changing that
address can invalidate Kubernetes certificates, etcd URLs, and kubeconfig files.

Resolve optional aggregator URLs only after the bounded readiness wait; a seed
does not resolve its URLs again after creation. An absent proxy or expired wait
can still leave an optional URL empty. UTM runs unelevated in the operator's GUI
session; ownership repair is needed only when an earlier invocation used sudo.

The host contract exports generic verbs that overlap Hyper-V cmdlets. Load only
the active provider and qualify native Hyper-V calls. New contract operations
must exist in every provider before callers use them. Check actual module
exports, propagate inventory errors, and keep active neighbor refresh separate
from passive address reads.

Host automation setup captures original settings once before changing them.
Disable restores that capture, removes only provably Yuruna-owned additions if
no capture exists, refuses an active cycle, and stops services only when asked
with `-StopServices`. The shared restore driver receives the calling script's
bound `PSCmdlet`: an ambient `WhatIf` preference does not cross module session
state. The platform-specific settings remain in the host guides.

Every `Enable-TestAutomation.ps1` uses the same process-boundary outcome:
0 means the conditions are in place (or the run was only a preview), 1 means
execution failed, and 2 means changes were applied but an operator-only
condition remains. The caller maps 2 to a warning because re-running cannot
clear it. KVM's missing-package warning is instead the first pass of its
documented two-pass installation and is not an operator-only outcome.

**Disk independence and capacity.** Long-lived service disks are private copies,
not qcow2 overlays against a base image that a later download can rotate. Copying
keeps a service independent of changes to the source artifact. A transient
Amazon Linux overlay must expose at least its backing disk's virtual size:
`qemu-img create -b` permits a smaller size that truncates the visible root
partition and leaves dracut waiting for an unusable device. Its size is therefore
`max(base virtual size, 16 GiB)`. Cache VMs use 512 GiB of virtual capacity for
Squid's 393216 MiB cache plus OS, logs, and headroom; sparse/dynamic images consume
host space as written. The `maximum_object_size 65 GB` policy permits large
artifacts such as IPSWs to remain cacheable end to end.

Every provider must stop provisioning if expansion to the requested service
disk size fails. A copied base image can still boot with its original small
capacity, so continuing merely moves the failure into package installation,
image prewarming, or service startup.

**Credentials and module lifetime.** Zot consults scoped upstreams before Docker
Hub's final catch-all. Anonymous requests share the egress IP's allowance;
exhausting it can delay revalidation beyond Docker's response-header budget.
Stored Docker Hub credentials use the account's allowance. Leave both fields
empty without a real vault entry: `Get-Password` can mint a missing secret, which
would turn anonymous access into failed authentication. A vault read failure is
not evidence that the entry is absent. In-process cache builders also reuse the
existing log module; force re-importing it discards caller state and creates
verbose import noise. This intentionally defers module-code updates until a
fresh load.

**Host storage access.** Ubuntu home directories created with mode 0750 can
prevent `libvirt-qemu` from traversing to disks below the operator's home. A
traverse-only ACL for that account grants the required search permission without
opening directory listing or read/write access for other users. Reapplying the
ACL is idempotent.

**Network selection and fallback.** Resolve a guest's network and reachable host
address together. KVM uses the selected external bridge or default NAT network;
Hyper-V selects its switch before choosing the corresponding LAN address or NAT
gateway. This prevents the seed from inheriting an address for a different
network. Status ports come from configuration, with 8080 as the default. A
Windows guest on libvirt's default NAT can use its stable gateway, while a
bridged guest's host address can expire during Windows Setup. The seeded host
identity and directory resolver repair that hint. See [host-coordinate recovery](https://yuruna.link/4220a755-002d).

A Hyper-V Default Switch is not guaranteed: it belongs to client Windows and can
be removed. Verify it exists before falling back. If external bridging is
unavailable, rank existing non-External switches first; reusing an External
switch over an unsuitable uplink can leave the guest without carrier. On UTM,
resolve the bridge interface from the default IPv4 route, retaining the existing
`en0` fallback when the route is unavailable. Wi-Fi commonly cannot carry the
VM's additional MAC, so it uses Shared NAT and host forwarding; Ethernet uses
direct bridging and preserves client source addresses.

**Bridge health and discovery.** An active libvirt bridge-mode network can still
lack a physical uplink. Probe its `brif` members before provisioning; otherwise
DHCP and the guest-agent installation can spend their entire wait budgets with
no path to the LAN. NAT, routed, and isolated libvirt networks legitimately have
no physical bridge member and must not be rejected by that check. The caching
proxy launcher owns bridge repair; other service builders reject a confirmed
dead bridge and point to that owner, while an inconclusive probe remains best
effort.

A libvirt network can remain defined after its backing bridge loses its LAN
uplink. NetworkManager may have created the bridge without activating its slave,
or a netplan definition may not have converged. Before reusing a defined network,
repair the bridge slave. If repair reports that the bridge is gone or the uplink
cannot recover, continue through network creation instead of returning an
apparently healthy network whose guests cannot receive upstream DHCP leases.

Hyper-V management vNICs clone the MAC of their bridged NIC. After two External
switches have used one NIC, live and leftover vEthernet adapters can share that
MAC; a first-match lookup may select an APIPA address and falsely mark a healthy
bridge unaddressed. Resolve the MAC match by switch alias, and leave an ambiguous
mapping unresolved instead of demoting the host to NAT on guessed evidence.

Use shared IP discovery instead of parsing the first dotted address in guest
agent output: loopback and link-local rows are not usable guest endpoints.
Hyper-V cache builders collect KVP/ARP candidates before Squid is listening;
the later port probe distinguishes stale and serving addresses. On an external
switch, an active neighbor sweep can discover the guest while KVP is still being
installed. The Default Switch already supplies neighbor evidence through its
NAT/DHCP path.

Hyper-V's ordinary VM address lookup reads KVP first, then host neighbor entries
filtered by that VM's MAC. On an External switch, `hv_kvp_daemon` can take 5 to 15
minutes to publish an address, while a matching neighbor entry may be available
earlier. Keep this lookup passive and cheap for polling loops. Consumers that
need fresh evidence, including guest diagnostics and cache discovery, invoke the
separate active neighbor probe. The shared routable-address selector decides
which IPv4 or IPv6 candidates can be returned by every provider.

Libvirt's bridged network does not own the DHCP server, so its lease lookup can
be empty. Agent discovery may need the first-boot package installation to finish;
ARP helps only after the guest has sent a packet to the host. Readiness budgets
must cover that work. Hyper-V Ubuntu installers warn and fetch directly when the
cache VM is absent or stopped, but fail if a running cache cannot answer on 3128.

KVM's cache probe returns bare-IP URLs for its consumers and tries the connection
three times: a systemd socket proxy into libvirt NAT can take more than one second
to accept while it is prewarming or the host is busy. A false negative would send
the entire guest cycle directly to the internet. Quiet callers only decorate
output when a cache exists, so an absent cache is not a warning there.

A guest without an address can only say that it has no lease; it cannot tell a
DHCP DISCOVER that was never sent from one that got no answer. Libvirt's dnsmasq
already logs the server side, so KVM marks each guest boot with a timestamp, MAC,
and bridge and copies the journal evidence before the domain is undefined. This
has no persistent capture session to collide with another guest or leak after a
failed teardown. Packet capture adds evidence about frames missing from the
journal only when tcpdump can open the bridge without elevation. If that is not
available, record why capture was disabled beside the journal slice.

**Boot and console continuity.** Explicit `on_reboot=restart` keeps imported
cloud guests inside QEMU across a guest reboot, retaining the domain, NVRAM boot
entry, and console connection. The KVM Amazon Linux builder defines without
booting: the host `Start-VM` operation must open DHCP evidence capture before the
first DISCOVER. Ubuntu 24 and 26 both pin virtio video; the bochs framebuffer path
in an early Ubuntu 26 installer kernel consumed display work and correlated
with an overlayfs failure that stalled installation. Direct VM-configuration
cmdlet failures must terminate the child script so the parent receives a failed
exit instead of proceeding with a partially configured VM.

A Hyper-V checkpoint must follow a guest flush and shutdown. Freezing a running
guest produces a crash-consistent image that may lose the tail of an installation;
later restores would inherit that incomplete baseline. Check every state except
genuinely Off, since the provider reports transitional states such as Paused,
Starting, and Stopping as `unknown`. A force-stop is preferable to a live
checkpoint but makes the snapshot untrustworthy, so the caller warns loudly.

Printed shell examples belong in a literal PowerShell here-string, with named
placeholders replaced afterward. An expandable string would evaluate `$()`;
backslashes do not escape that PowerShell interpolation.

**`host/macos.utm/Disable-TestAutomation.ps1`.**

`defaults` takes the host selector BEFORE the verb. Emitted verb-first it
binds '-currentHost' as the domain and rejects the rest, so the three
ByHost knobs would be neither written nor deleted and "Disable puts the
Mac back" would not be true for them. Get-MacDefaultsCommandArgument
re-emits the selector where it belongs, from the same knob table the
capture and the apply paths use.

A captured value has to be spoken back in the vocabulary of the type it
is written as. `defaults read` renders a boolean as 1 / 0, and
`defaults write -bool` accepts only true / false / yes / no -- a digit
exits 255 with the usage text, so without this translation every
boolean knob reports a failed restore and stays exactly as the
automation left it.

**`host/macos.utm/Remove-OrphanedVMFiles.ps1`.**

utmctl is an Apple Events client with no timeout of its own: a UTM that
stopped answering holds every call indefinitely, and this sweep runs
unattended at cycle start. Every call is therefore bounded -- through the
macOS driver's wrappers when the driver is loaded, through the shared
bounded runner otherwise -- and a call that did not finish proves nothing:
a bundle whose registration could not be read is kept, never deleted.

Verify no longer registered before removing files. Prefer the UUID
(unambiguous); otherwise re-query by NAME, because a name-based
`utmctl delete` can silently fail -- and without a probe a UUID-less
bundle would be removed while its VM is still registered in UTM,
deleting the on-disk state of a live registration. A probe that did
not finish counts as still registered for the same reason.

**`host/macos.utm/Remove-StaleDhcpLease.ps1`.**

Candidates first, reachability second, both here rather than handing the
probe to Select-StaleDhcpLeaseBlock: its -InUseVerdict runs the scriptblock
across a module boundary, and a veto that silently misfires there would
either delete a live guest's lease or quietly protect every block. Splitting
the two keeps the probe running in the scope it was written for, and lets the
skipped addresses be reported instead of just vanishing from the list.

**`host/macos.utm/modules/Yuruna.Host.psm1`.**

The GUI-session probe and the in-bundle utmctl path come from the macOS
host-condition module. -Global without -Force: a copy the host-condition
facade already loaded is reused as is, rather than re-run and reset under
its other callers every time this driver is re-imported. A long-lived
process can hold a copy loaded before those two entry points existed; that
copy is replaced (still -Global, so every caller sees the same one) rather
than left to fail the driver's first call into it.

The one wording table for utmctl's Apple Event failures. utmctl exits 0 on
most of them and prints the OSStatus text instead, so the text is the only
evidence, and the ORDER is the classification: a denial (-1743) or timeout
(-1712) message also carries the generic OSStatus phrasing, so the specific
rows must be tried before the catch-all. Every wording the repository has
seen (driver and installer gate) belongs here, each pinned by a fixture.

Ports below 1024 need root on macOS. Spawn via `sudo -E pwsh` when not
already root; the caller pre-caches credentials via `sudo -v` so the
detached subprocess can bind the port without an interactive tty prompt.
sudo exec's pwsh (no fork), so the pidfile PID matches the sudo PID.
An unreadable uid is treated as non-root: the sudo -n spawn below then
fails fast when root is not reachable, instead of binding as nobody.

Leaving the bundle on disk is the point. UTM deletes a VM by moving
its bundle to the trash, so removing the files under a registration
that survived strands the name in UTM with nothing left to delete --
and a stranded name is worse than a stranded bundle, because it still
answers `utmctl status` and so reads as a reusable VM to the sequence
engine, which then starts a VM that has no disk.

Polled even when the verb reported an error: a start that printed an
Apple Event timeout can still have been carried out, and the state is
what settles it.
The guard reads the shared deadline, not the settle window: the
window only paces polling, and a window of exactly one second is
already under a second by the time it is measured, which would
refuse every short settle regardless of the time actually left.

Gate on a positive stopped reading FIRST: if UTM runs QEMU without
an enforced write lock, the qemu-img probe below would pass while
the process is still alive, so the lock check alone is not
sufficient. Status can flip to 'stopped' a beat before QEMUHelper
releases the file handle -- qemu-img info WITHOUT -U fails while
the lock is held, so a clean exit on every disk is the all-clear.

Emits the names one by one: zero elements for an empty set, N for N.
Callers MUST normalize with `@(Get-RunningVmName)` to get a proper
array regardless of count. Do NOT use `return ,@($arr)` here: the
comma wrapper inverts for empty arrays (caller's @() then receives
a 1-element array whose single element is the empty array itself,
surfacing as a phantom "running VM" with empty name).

Every remaining process's identity is read once, before the first
signal: a helper's baseline read after UTM's own TERM/KILL waits
would be seconds younger than the census that listed it. The census
is only a candidate list, so each baseline must already be this
user's UTM or helper executable; each signal then revalidates
against the baseline taken here.

networksetup -listallhardwareports prints stanzas of the form:
  Hardware Port: Wi-Fi
  Device: en0
  Ethernet Address: ...
Collect the Device of every Wi-Fi port, then test the default-route
interface for membership.

**`host/modules/Yuruna.HostProvision.psm1`.**

A common -Verbose sets $VerbosePreference only in the scope of the cmdlet
that received it, and this function lives in a different module from its
callers -- so without this, every narration line below is silently dropped
for a caller who asked for it. The narration is the entire reason this
function exists: a discovery chain that declines without saying why leaves
the caller unable to tell "no address yet" from "no such guest".

3s/attempt cap, not 1s: on the EXTERNAL/remote proxy path a cross-host
cache (a UTM/macOS squid over bridged networking, or a kvm cache behind
the host's systemd socket-proxy forwarder into libvirt NAT) routinely
takes 600ms-1s+ to ACCEPT, so a 1s cap makes the runner report a healthy
remote cache as "did not answer." The cap is free for a fast cache
(connect returns on accept); it only delays a genuinely-down verdict.

**`host/ubuntu.kvm/Enable-TestAutomation.ps1`.**

SupportsShouldProcess on the script-level param() does NOT propagate to
nested functions -- $PSCmdlet inside this function refers to the
function's own context, so the attribute must be repeated here for
ShouldProcess to be wired up and for PSScriptAnalyzer's PSShouldProcess
rule to be satisfied. -WhatIf flows through automatically because
$WhatIfPreference inherits from the calling scope.

Reported for every caller. install/ubuntu.kvm.sh says the same thing
once more in its own closing summary, and that duplication is the
cheaper mistake: suppressing the reminder for callers that publish a
particular environment variable suppresses it for every caller that
publishes it, including the ones that print no such reminder of their
own -- and virsh then fails for a reason nothing on screen explains.

**`host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1`.**

Capture instead of streaming: Yuruna.Host\New-VM re-emits every child
stdout/stderr line via Write-Information, so virt-install's
"Starting install... / Creating domain... / Domain creation completed."
would clutter the cycle log at Info level. The verbose stream is not
captured by the parent's `2>&1`, so Write-Verbose hides these unless
the operator re-runs the script directly with -Verbose.

**`host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1`.**

Print one status line per ~30 s rather than Write-Progress. PowerShell-
on-Linux's progress renderer trips an internal SetCursorPosition with
nonsensical column values ("Parameter 'left'. Actual value was
51515410") on certain ANSI-styled terminals (tmux, vscode integrated,
some sshd PTYs). Falling back to plain stdout lines makes the wait
loop terminal-agnostic and keeps the operator informed.

**`host/ubuntu.kvm/modules/New-UbuntuServerVM.ps1`.**

Pinned rather than left to the default. virt-install adds this channel on
its own for this argument shape today, so the line changes nothing now --
but qemu-guest-agent in the seed is useless without it, and a future
default change would remove the host's only on-demand way to ask this
guest for its address, leaving discovery on a decaying ARP cache with no
sign of what broke.

**`host/ubuntu.kvm/modules/Yuruna.Host.psm1`.**

Read once and require a domain that is positively powered off: an
'unknown' from a denied or timed-out read must refuse here rather than
pass on to domrename. Get-VMState folds paused, in shutdown, pmsuspended
and crashed into 'stopped', but each of those can still have a live QEMU
process (crashed does under on_crash=preserve), which libvirt counts as
an active domain and will not rename. Only the raw 'shut off' qualifies.

A NIC still holding the address the OLD name derives is holding that
NAME's address rather than the guest's, and the name is being vacated
-- so the address has to move with it, or the next domain built under
it is refused for a duplicate. Any other address was pinned at build
time to the identity this guest keeps for life: re-deriving it here
would re-DHCP a guest whose own state records the address it has.

Thin wrapper over the shared runner. The host subdir and the image-path
table (Get-ImagePath, injected as a CommandInfo resolved in THIS driver's
scope) are the platform variables. Unlike win/mac, this driver logs via
the bare Information stream rather than Write-GetImageLine, so the writer
is injected too -- `& (Get-Command Write-Information) $line` binds $line to
-MessageData positionally, identical to an inline `Write-Information $line`.

Import only when the dispatcher isn't already resolvable, so the
steady-state path (module already loaded by the outer loop) is a
no-op. -Global on the cold path: a bare -Force import evicts the
global Invoke-Sequence (and its nested modules) the outer loop
still calls; refresh
it in place instead.

Defer to Invoke-Sequence's host-aware dispatcher rather than mapping key
names here. A local map holds only single keycodes, so a modifier chord
(which `virsh send-key` expresses as several positional keycodes pressed
together) degrades silently to one keypress -- Ctrl-U arriving as a bare
'u' typed into the guest. The dispatcher's Send-KeyKvm backend owns both
the chord table and the splat.

Rows look like:
  vnet0      52:54:00:1a:b2:c3    ipv4         192.168.122.42/24
  vnet0      52:54:00:1a:b2:c3    ipv6         2001:db8::1234/64
The MAC column repeats only on the first row of a multi-address
interface; a continuation row carries '-' there and inherits the MAC
above it, so the last seen MAC is carried forward.

MAC affinity is a REQUIREMENT here, not the preference it is when
reading domifaddr. That view is already scoped to one domain, so every
row belongs to the guest being asked about and falling back to any row
is harmless. This view is scoped to the NETWORK: every other guest's
lease is in it, and the same fallback would hand back a peer's address
-- reachable, wrong, and indistinguishable from success.

Internal. The name of the NM connection currently ACTIVE on $Nic, or
$Nic itself when none is found (best-effort fallback so operator
recipes always show something actionable). Stock profiles are rarely
named after the device ("Wired connection 1", "netplan-eno1"), and a
recipe pointing at a nonexistent profile fails at the exact moment
the operator is disconnected.

A MAC pin in the yaml only applies when the device is
CREATED ([NetDev] MACAddress is not retro-fitted), so a
bridge that already exists with a generated MAC would keep
it after a re-apply and the host would renumber. Rebuild
instead: the sweep deletes the device and the fresh build
pins the NIC's MAC at creation.

The failed re-apply just put the NIC under the stale
definition (dhcp off, bridge member) without delivering
the uplink -- undo it BEFORE handing back 'rebuild', or
the host sits addressless and the caller's rebuild path
cannot even resolve the default-route NIC. Moving the
yaml aside + re-applying restores whatever the surviving
netplan files declare for the NIC.

Probe the backing bridge so the plan is truthful about whether
the run will flap host networking (heal/rebuild) or not. Only
<forward mode='bridge'/> networks are host-bridge-backed --
NAT/routed networks own their virbrN bridge (no physical
uplink by design; dnsmasq serves DHCP on it) and are reused
as-is.

The bridge would have to be built -- this is the only branch that
perturbs host networking. The rollback recipe names the NIC's REAL
active profile ("Wired connection 1", "netplan-eno1", ...): stock
profiles are rarely named after the device, and a recipe pointing
at a nonexistent profile fails at the exact moment the operator is
disconnected.

Build the hostPort -> vmPort mapping list. Straight ports map 1:1;
a PortRemap entry (e.g. 8022 -> 22) overrides that hostPort. This
is a plain array of objects ON PURPOSE -- NOT [ordered]@{}: an
OrderedDictionary keyed by integers indexes POSITIONALLY when the
index is an [int], so `$map[3128]` is an out-of-range positional
lookup ("argument out of range, Parameter 'index'"), not the key
lookup it looks like. An object array sidesteps that trap.

Current mechanism: systemd socket-proxy units. Disable+stop the
.socket (drops it from sockets.target and closes the listener),
stop the .service, delete the unit files, reload systemd.
Invoke-YurunaSudo, not a bare `& sudo`: on the runner's unattended path it
adds -n so a cold timestamp fails immediately instead of parking the whole
host on a password prompt read from /dev/tty that nobody will answer, and
it throws with the exact sudoers rule to install when that happens.

**`host/windows.hyper-v/Enable-TestAutomation.ps1`.**

The virtual display is opt-in (see header) and deliberately NOT set here: it
changes the host's monitor topology / scaling, so it stays an explicit
operator choice. Test-YurunaVirtualDisplayEnabled resolves the live process
variable first, then the persisted User/Machine scope, so this reflects what
the runner will actually do rather than this shell's (possibly stale)
process block. See docs/host-hyperv.md.

**`host/windows.hyper-v/Remove-OrphanedVMFiles.ps1`.**

Remove empty subfolders, deepest first so parents empty as children go.
Hyper-V's system subdirs under VirtualMachinePath (Planned Virtual Machines,
Snapshots Cache, Resource Types, ...) are normally empty on a no-VMs
host but are part of vmms's expected layout -- without a guard the
empty-folder sweep removes 15+ vmms system dirs on every run, only for
vmms to recreate them. Skip anything Test-IsHyperVSystemPath flags.

**`host/windows.hyper-v/guest.caching-proxy-service/New-VM.ps1`.**

The ARP sweep only makes sense on a bridged (External) switch, where the
host is not the DHCP server and never observes the guest's lease. The
External vSwitch name is operator-configurable (Get-OrCreateYurunaExternalSwitch
honors a pre-created switch under any name), so key off the switch this
script resolved rather than a literal name -- a literal silently skips the
sweep on a host that named its bridge anything else.

A Hyper-V vSwitch object outlives its uplink binding across a host reboot,
so the switch still existing is not evidence that its bridge forwards. When
the bridge is dead the VM's DHCP request never reaches the LAN and no amount
of waiting produces an address, so bound the discovery budget instead of
spending the full 20 minutes re-proving it. The classifier is driver-private
and may be absent, in which case the uplink is treated as usable.

**`host/windows.hyper-v/guest.windows.11/New-VM.ps1`, `host/windows.hyper-v/modules/New-UbuntuServerVM.ps1`.**

Nested virtualization is opt-in and AMD64-only: ARM64 Hyper-V rejects a VM
with virtualization extensions exposed at start time ("this platform does
not support nested virtualization"), so an impossible ask fails here,
before any VM state is created. OSArchitecture rather than
$env:PROCESSOR_ARCHITECTURE, which reports AMD64 for an x64 pwsh under
emulation on an ARM64 host.

**`host/windows.hyper-v/modules/Yuruna.Host.psm1`.**

Hyper-V's own answer, asked two ways so a single property name is
never what decides an unhealthy verdict: a vNIC record flagged
IsManagementOs, or any vSwitch-side record naming this switch (live
mode only queries those for the switch's management OS, and a
host-side Get-NetAdapter record always carries an
InterfaceDescription instead).

Falling through to the Default-Switch address keeps a stale or
mistyped switch name from stranding a guest with no host address
at all, but the answer is only correct if the guest really does
attach to the Default Switch. Say so, because the alternative is
a 172.x address baked into a bridged guest's seed with nothing
in the log to explain where it came from.

-Name is a wildcard parameter. A name holding a wildcard or escape
character cannot be looked up as itself: unescaped it matches other VMs
and never itself alone, and whether the provider honors an escaped
pattern cannot be relied on. Such a name is matched exactly against the
full inventory instead, which answers presence as reliably as it answers
absence.

Close the VM's vmconnect viewer before unregistering. vmconnect has
no setting to suppress the modal "The virtual machine ... has been
deleted" dialog it raises when its VM disappears, and that dialog
blocks until a human clicks Exit. Must happen pre-delete: once the
dialog is up the window title no longer carries the VM name, so the
title match below would miss it.

Wall-clock deadline rather than an iteration counter: `$elapsed += $Poll`
silently expands the budget by 3-6x when each iteration does
real work (Get-VM is CIM-backed and can hang briefly under VMMS
contention). [DateTime]::UtcNow is monotonic-enough for a 120s
budget and tracks actual wall time regardless of poll cost.

A modal "Another user is connected" dialog disables its own owner window,
so a vmconnect main window that is visible, enabled and steadily titled
for the VM is direct evidence no dialog is coming -- the wait below exits
on that instead of only on a dialog or the timeout. Sized from a measured
worst-case dialog-appearance delay D (D = 1.5 s: no Hyper-V host was
available to provoke the dialog and time it, so this is the plan's own
documented fallback, not a measurement) as max(1.0, 2 * D), rounded up to
the poll's own 0.25 s grid.

Two capture paths:
  1. Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage --
     no window required, configured resolution with smaller boot-mode
     fallbacks. Used by OCR.
  2. PrintWindow against the vmconnect window -- used by click-by-OCR
     because clicks need the same coord space as the captured pixels,
     and the WMI thumbnail does NOT match vmconnect's client area.

GUI: defer to Invoke-Sequence's host-aware dispatcher (same pattern
as KVM and macOS). Send-TextHyperV is a private helper inside that
module; calling it directly from here fails under module scoping
because Yuruna.Host's body cannot see another module's private
functions even when both are loaded -Global. Going through the
exported Test.SequenceEngine\Send-Text avoids the visibility trap.

Prefer IPv4 (downstream Add-PortMap uses netsh portproxy v4tov4),
but fall back to a routable IPv6 if no v4 is available so v6-only
guests don't return $null. Loopback/link-local excluded.
v4-before-v6 and the loopback/link-local rejection are the shared
selector's job, so KVP, the neighbor stage below, and the other two
drivers cannot drift apart on what counts as a usable address.

Child scripts run by the bounded probe and the rung-2 helpers in a fresh
`pwsh -NoLogo -NoProfile -NonInteractive -Command`. Each prints only
`yuruna-probe <key>=<token>` lines through [Console]::Out, which flushes per
line, so what the child saw survives a kill at the cap; tokens are enum names
and never localized. Single quotes only, so the text crosses the process
command line without any quoting to undo.

**`test/modules/Test.HostSampling.psm1`.**

The per-cause rates after the scheduling counters split Total
Intercepts/sec by source, so a virtual processor trapping millions of
times a second names what it is trapping on: a timer or interrupt-
controller register loop, an interrupt storm, hypercalls, device
memory, or (ARM64) a secure-monitor call. SysReg and SMC are the
ARM64 traps, MSR/IO the x64 ones; capability resolution drops
whichever this host does not publish. This list is deliberately not
exhaustive -- Hyper-V Hypervisor Virtual Processor carries dozens of
narrower sub-counters -- so the livelock verdict also reports what
these named causes leave unaccounted for, rather than reading a gap
in this list as zero cause.

<a id="42e220c4-0005"></a>

## Guest installers

Ubuntu 24 and 26 carry the same update, Code, Kubernetes, n8n, OpenClaw, and PostgreSQL installer logic. A release name is not a reason to omit retry behavior, installed-tool checks, or diagnostics. Common phases use the same region names and order. Amazon Linux retains dnf/RPM paths, Amazon Corretto, NodeSource RPM installation, and PostgreSQL 17; Ubuntu uses apt, nvm, and PostgreSQL 18. Ubuntu's package installation already creates and starts a cluster, so its `Ensure PostgreSQL cluster` region keeps an existing 18/main cluster and creates one only when it is missing. Amazon's RPM leaves initialization to the caller. Its `Ensure PostgreSQL cluster` region initializes only absent or empty data, preserves an existing PostgreSQL 17 cluster, and refuses a nonempty partial cluster or an incompatible `PG_VERSION`. Retries never delete an existing data directory. Windows uses elevation and Windows package tools. The macOS update workload runs after Setup Assistant; the IPSW restore already supplies its initial operating system.

Ubuntu release entrypoints for `update`, `code`, `k8s`, `n8n`, `openclaw`, and
`postgresql` all delegate to `guest/shared/ubuntu.<workload>.sh`. Edit that shared
body and run `python3 tools/Sync-GuestWorkflows.py`; the generator refreshes both
release wrappers and their SHA-256 pins. A local checkout verifies the body
before execution; a downloaded entrypoint supplies the same digest to the
installed fetcher. Pre-commit and release checks cover all twelve wrappers.
Behavior fixtures read the shared implementation, while wrapper fixtures verify
argument forwarding, failure propagation, downloaded execution, and stale pins.

Architecture detection reports the guest's CPU architecture independently of
its hypervisor. An x64 guest does not identify its host provider. JDK and .NET
suppliers follow the packages supported by each OS; keep their versions and
availability checks aligned rather than forcing identical download formats.

Windows JDK setup removes a stale MSI before downloading and requires a fresh,
nonempty installer file. Check the installer process outcome before completion:
MSI codes 0, 1641, and 3010 indicate success; reboot outcomes produce a warning.
Other codes, unavailable outcomes, launch failures, and failed transfers stop
installation. Clean the temporary installer after the attempt. See
[Microsoft's MSI return codes](https://learn.microsoft.com/en-us/windows/win32/msi/error-codes).

Windows .NET setup follows the same fresh-file and cleanup contract. Reset the
native exit status before invoking Microsoft's script, then check both command
success and the resulting status before registering machine-wide environment
variables or reporting completion. A downloaded script can exit unsuccessfully
without throwing in its caller; command dispatch and terminating script errors
must also stop this phase.

Windows package prerequisites check winget outcomes before completion. Accept
success and its documented already-installed or no-applicable-update results;
those outcomes preserve repeat installation without claiming the newest version
is available for this OS. Other failures, including installer version conflicts,
stop the phase. Every Windows guest prerequisite uses the same standalone native
outcome gate, including the update workload's initial PowerShell installation.
See [Microsoft's winget return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md).

macOS Command Line Tools updates remain best-effort because the updater can
fail even when usable tools are installed. Before repository fallback, require
a selected developer-tool path and a successful `git --version`. Do not invoke
Apple's Git stub while selection is absent: it may open a GUI installation
prompt rather than report a noninteractive failure.

Guest checkout ownership follows the operator's account metadata. macOS
Directory Services home paths can contain spaces, and the account's primary
group is commonly `staff`, not the username. Preserve the full absolute home
path and resolve the group with `id -gn` before extracting or restoring
ownership. Missing account metadata must fail before modifying a checkout.

Kubernetes certificate exports use a random PFX password with an owner-only
sidecar consumed by workload deployment. Linux disables xtrace while producing
the secret. Windows uses PowerShell 7 for secure-string conversion because the
initial Windows PowerShell 5.1 environment has different certificate tooling.
These differences preserve the same certificate and password contract. Windows also
requires successful mkcert and PFX-export process outcomes plus fresh nonempty
PEM, PFX, and password files before completion. A failed export removes
incomplete PFX outputs and retains PEM inputs for diagnosis; a previous PFX pair
cannot satisfy the new export's success gate.

<a id="42e220c4-000d"></a>

### Host discovery and package initialization

Linux update workloads re-read `/etc/yuruna/host.env` before using the host status service. Framework and project archive downloads retry once after invoking `yuruna-host-locate.sh`; a failed resolver must remain a failure, with stderr preserved. A readable file containing an old DHCP address does not prove that the host is reachable. Re-resolving prevents an unnecessary fallback to a possibly private Git repository. Windows also disables Git Credential Manager interaction: `GIT_TERMINAL_PROMPT=0` alone does not suppress its credential dialog. See [host-coordinate recovery](https://yuruna.link/4220a755-004d) and [noninteractive Git](https://yuruna.link/4220a755-004f).

Windows and macOS retain the seeded framework and project repository URLs when
host archive transfer fails. Every guest therefore falls back to the configured
repositories before using the public defaults. Repository identity must survive
a host-address change or an unavailable status service.

The standalone PowerShell tarball installer fallbacks copy the shared retry
library's installer exactly. Both paths require a usable publisher checksum
list and verify SHA-256 before extracting or installing the payload. A missing
checksum is a failure; it must not become an unchecked installation merely
because the retry library was unavailable.

Bash and PowerShell retry settings accept positive decimal integers within the
Int32 range. Invalid, zero, negative, or overflowing values fall back to five
attempts and a ten-second initial delay. A bad attempt count must never turn an
unexecuted command into success. Leading zeros are decimal, not shell octal.

Proxy discovery prefers `http_proxy`, then the address in `host.env`, then a probed service name. An empty cache address is supported and selects direct upstream access. Amazon's dnf setup probes every candidate before writing it to `dnf.conf`; a Squid HTTP 400 still proves that its port answered, so this reachability probe intentionally omits `curl -f`. A missing cache clears stale proxy configuration instead of leaving dnf pointed at a dead endpoint.

`powershell-yaml` is a required dependency. Installation must end with an import, a `ConvertFrom-Yaml` smoke check, and a module-availability check where the retry wrapper uses one. `Install-Module` can report nonterminating errors or leave a corrupt package, so its return alone is insufficient. Windows installs through PowerShell 7 for all users, matching the interpreter and module search path used by guest automation. See [PowerShell bootstrap](https://yuruna.link/42d69dfa-0038).

<a id="42e220c4-000e"></a>

### Installed tools and container networking

Helm and mkcert must be present on PATH, nonempty, and produce version output. Bash treats an executable zero-byte file as a successful empty script; checking only its presence or exit status can preserve a broken tool in a saved VM image. Ubuntu's VS Code install skips recommended desktop packages while retaining the Electron dependencies `libgl1` and `libgl1-mesa-dri`. Kubernetes installs its own prerequisites, including `socat`.

Ubuntu n8n and OpenClaw use the manifest's Node major when exposing executables
and printing installation summaries. Load NVM with `--no-use` and resolve that
major explicitly: a user's saved default can still name an older Node after a
successful installation. Verify Node, npm, and the workload executable before
creating any global links, and stop on missing NVM, failed version lookup, or
incomplete installation. After Node installs successfully, set NVM's default
alias to that major so future interactive shells select it too. Amazon Linux
retains its NodeSource RPM workflow.

Kubernetes explicitly installs `cri-tools` and verifies `crictl` before checking containerd. Both initial setup and kubeadm recovery require its CRI API to answer within 30 seconds. Each probe uses a timeout of at most five seconds, capped by the remaining deadline, with a one-second termination grace for child cleanup. A blocked probe and its children are terminated. A missing tool fails immediately, and an unavailable API reports the last probe's exit code and bounded diagnostic output before aborting. Flannel begins its bounded rollout check immediately after manifest application. The following 180-second node readiness check remains mandatory and retains node, pod, and CNI diagnostics on failure.

Resetting an existing Kubernetes cluster flushes shared firewall tables, including Docker's bridge forwarding and NAT rules. After containerd recovery and its CRI readiness check, that reset path restarts Docker within 60 seconds to restore its rules and requires `docker info` to answer within ten seconds. Both commands allow a one-second termination grace. A failed restart or engine probe aborts before cluster initialization. Fresh installations do not need this additional Docker restart.

The Kubernetes installers replace and verify containerd's registry configuration regardless of quoting or previous value. Containerd 2.2 can emit a single-quoted, colon-separated `config_path`; matching only an empty double-quoted value silently leaves the mirror inactive. The generated configuration selects the supported single directory. MCR needs its own mirror entry, and manifest probes name their upstream with `ns=mcr.microsoft.com` or the appropriate registry, so zot does not spend Docker Hub requests resolving another registry's images.

A selected cache must become reachable before cache-only pulls begin. Liveness retries tolerate a cache VM rebuilding without consuming upstream image requests. Manifest diagnostics preserve curl's failure details even when a retry succeeds, distinguish transport failure, upstream refusal, and actual elapsed-time exhaustion, and stay concise enough to fit the console capture. See [container caching](https://yuruna.link/42d69dfa-0042).

Archive transfer bounds distinguish a stalled transfer from a large transfer that is still progressing. The macOS curl path allows a moving transfer to finish while bounding connection time and low throughput. Only `fetch-and-execute.sh` prints the success marker based on the payload's exit code. Payloads end with ordinary visible output so the marker follows an active console frame rather than an idle capture surface.

Windows checks `tar.exe`'s exit code before accepting framework or project
archives. Failed extraction removes the partial destination before fallback;
a directory left by a failed extraction is not a usable checkout. Fallback Git
clones use the same low-throughput limits as Linux and macOS: 1024 bytes per
second for 60 seconds.

Every guest accepts a framework archive or fallback clone only when transfer
and extraction succeeded and the result has a regular, nonempty `VERSION` file.
An empty but syntactically valid tar archive is not a usable framework. Keep
early diagnostic prefetch and later repository materialization on the same
acceptance contract, including Linux's shared retry helper and inline fallback.

<a id="42e220c4-000f"></a>

### Service guests

Service installers export `HOME` before building Go code because cloud-init may omit it and Go requires it to locate its module cache. All three select a service user, resolve storage and tunables, build, install a systemd unit, and start the daemon; their storage and runtime dependencies justify different intervening steps.

Keep strict shell initialization in `Initialize environment` and library lookup
in `Load service helpers`, after `Service user` identifies the account whose
framework checkout may contain that library. Account selection and helper
discovery are separate phases even when their statements are adjacent.

All three service installers allow 30 readiness probes and require both an
active systemd unit and a successful `/healthz` HTTP response. Stash retains
active-only readiness when `STASH_HTTP_ADDR` is explicitly empty because HTTP
is disabled. Missing NAS storage remains a runtime health detail and does not
prevent the daemon from starting.

| Guest | Dependencies and storage |
| --- | --- |
| Stash | Go daemon on SSH 22 with optional HTTP 80. Cloud-init mounts the stash share; an unconfigured guest can use a local folder that does not survive reimaging. |
| Pool-control | Go daemon plus PowerShell and `powershell-yaml` for pool-admin commands. Its repository path and configuration store must be usable; audit and status files live under the pool share's service directory. |
| Download agent | Go daemon with optional PowerShell/Fido support for Windows image discovery. Missing support marks that image family unavailable so hosts can fetch it themselves. The pool share holds both images and service state. |

Pool-control resolves an explicitly seeded configuration-store location before the pool NAS default and initializes the resolved directory when it is not yet a Git repository. Testing only whether the seed was empty would skip initialization of a newly seeded NAS path. Git initialization runs as the service user, matching CIFS ownership; `core.fileMode=false` avoids changes caused solely by mount-provided modes.

Stash permits `STASH_HTTP_ADDR=''` to disable HTTP, so its shell expansion uses `${name-default}` rather than substituting the default for an explicitly empty value. Its aggregator URL prefers an operator override over `/etc/yuruna/pool.env`. Presence beacons use the owning host's identity and must recur faster than the aggregator's extension-health grace so a changed address is announced promptly.

The stash build stages `extension-sdk` beside `server`, preserving the Go module's `replace ... => ../extension-sdk` relationship. A workspace file outside the staged build does not satisfy that dependency. The systemd unit grants access to local state and share paths; its optional share path has a `-` prefix so an absent NAS mount does not fail namespace setup in local-storage mode. See [stash](https://yuruna.link/42f5e921), [pool-control](https://yuruna.link/4207d71a-000c), and [download agent](https://yuruna.link/4268e4cb).

Service guest installers resolve their account and load shared helpers before
`Service locale`, then `Service tunables`. The seeded cloud-init account takes
precedence; an explicit override or the current caller is used only if that
account is absent. Locale initialization precedes other tunables on all three
service guests while pool-control retains its compatible legacy seed fallback.

<a id="42e220c4-0006"></a>

## VM configuration

The stash, pool-control, and download-agent services use the same host-agent
overlay sections. KVM builders expose `org.qemu.guest_agent.0`; their seeds
install and start `qemu-guest-agent` so address discovery works on a bridge
where libvirt is not the DHCP server. ARP remains a fallback. These persistent
service VMs install the agent in the package phase. Ubuntu autoinstall guests
install it on a best-effort basis in late commands so an optional discovery improvement
cannot abort an entire OS installation.

Hyper-V service overlays leave those sections empty: the Ubuntu cloud image
already carries KVP support, and installing `hyperv-daemons` can fail when the
running kernel's cloud-tools package is unavailable. The caching proxy has its
own best-effort install in `runcmd`. UTM service overlays leave them empty because
their bundles do not expose a QEMU guest-agent channel. Ubuntu's UTM autoinstall
seed also leaves agent installation empty and retains the provider's existing
address-discovery fallbacks. Keep these provider distinctions.

Shared seed regions cover identity, packages, SSH keepalive, host coordinates,
framework fetching, and service startup. The stash mounts its separate NAS before
starting its daemon; pool-control and download-agent mount pool storage in their
guest scripts. Stash startup runs under systemd, so a slow NAS or source fetch
does not prevent cloud-init completion. Download-agent additionally installs the
proxy CA and prepares Windows-image tooling; those blocks have no pool-control
equivalent.

All service seeds and the Windows bootstrap write `host.env` in the same key order: host ID,
status-service IP and port, then caching-proxy IP. The caching-proxy VM points
that last key to its own loopback address; the other guests receive the seeded
cache address. Keep the order aligned so a diff isolates the intentional value
exception.

All four service seeds write locale settings to `/etc/yuruna/globalization.env`
with the same key order, root ownership, and permissions. Pool-control reads
that canonical file first; only an older VM without it falls back to the locale
keys formerly stored in `/etc/yuruna/pool.env`. An existing canonical file stays
authoritative even when its values are `auto` or `false`.

Windows seed generation keeps its first-logon body in a separate, parsable
PowerShell 5.1 template because nested here-string terminators cannot safely
live inside an outer here-string. Trusted seed media carries both the bootstrap
and host locator. A compact encoded launcher finds that media without requiring
networking; repository URLs follow the common host coordinates in the env file.

Framework fetches retry the host status service six times, re-reading `host.env`
after each wait because the host locator may have corrected a stale address.
Each archive attempt bounds stalled network I/O at 30 seconds and makes one
wget attempt; the six outer host attempts remain authoritative. Mirror clones
stop when throughput stays below 1024 bytes per second for 60 seconds. The
public mirror is the fallback for an off-LAN build. The VERSION file
must be a regular, nonempty file after extraction, and
`/etc/yuruna/framework-source` records the source, URL, version, and UTC fetch time. Keep it readable by the seed account so host
readiness checks can distinguish a published mirror from the local enlistment.
See [service source provenance](https://yuruna.link/42fffc2c-0013).

The three daemon seeds stage the downloaded archive and extracted tree in a
private temporary directory beside the destination. Check wget's status before
extracting: tar can succeed even when the producer exits with a transfer error.
Validate `VERSION` before promoting either a host archive or mirror clone. A
failed attempt preserves an existing checkout and its source record. If
promotion fails after moving the old checkout aside, restore it; retain that
backup when restoration cannot complete. Write provenance only after successful
promotion, and remove disposable staging on completed or failed attempts.

Netplan guests receive the shared `network-config` with MAC-based DHCP identity.
Amazon Linux receives no such file: its networkd fallback and identity drop-ins
are intentionally different. See [DHCP identity](https://yuruna.link/4220a755-000b).
The metadata's instance ID follows the VM name for test guests and is fixed for
each persistent service. See [seed identity](https://yuruna.link/429f3d06-0002).
Ubuntu's legacy ENI `network-interfaces` metadata is only a compatibility hint;
the shared `network-config` now shipped by all three builders takes precedence.
Overlay sections follow their base's order, including intentionally empty ones.
Regions immediately before YAML keys use the exact key, including `write_files`,
`runcmd`, `late-commands`, and `early-commands`. Embedded shell blocks retain
their shared phase names. Documentation beside a functional overlay delimiter
uses an ordinary comment so it does not introduce a mismatched region.

<a id="42e220c4-0007"></a>

## Console sequences

The Ubuntu 24.04 and 26.04 first-login sequences share the same order:
answer autoinstall, redraw and wait for the installed guest, rotate the
password, verify a working shell, persist the confirmed password, update
the guest, and wait for reboot. Amazon Linux starts from a prepared cloud
image, so it omits autoinstall and waits for its ordinary login prompt.
Its shorter first-boot budget is intentional. Ubuntu SSH variants use a blind
GRUB bridge before sshd is available, then use the same guest workload
scripts as console variants.

Manual stash and download-agent smoke workloads choose service-named accounts.
The planner passes that account to the vanilla VM seed and prerequisite startup
login; it is not an account inherited from a production service image.

Subiquity asks `Continue with autoinstall?` once. Its network-controller
messages can scroll that question away while it still waits for an answer;
Enter cannot redraw it. `blindAfterSeconds: 120` allows capture repairs
first, then supplies `yes` and requires evidence that the console moved.

"The console moved" cannot by itself tell a consumed answer from a keystroke
navigating a menu, and an interactive menu is equally static beforehand, so it
satisfies both halves of that test. `blindSkipPattern` names the screens a blind
answer must never be typed at; the Ubuntu guests name the installer's language
menu, which is what appears when autoinstall did not engage and the prompt is
therefore never coming. Prefer it to `failurePatterns` for this purpose: a
skip pattern that matches wrongly costs only the recovery, because the step
still spends the rest of its budget on the wait it asked for, while a failure
pattern that matches wrongly ends a healthy run. Entries are matched without
segment matching, so an anti-pattern cannot fire on its own words scattered
across an unrelated screen. A wait that already stopped on one of its own
`failurePatterns` never reaches the blind answer at all: it read the console and
found a screen the step declared wrong.

The login prompt behaves differently: agetty redraws it after Enter.
Every retry therefore nudges before waiting, and Ubuntu repeats that nudge
once a minute within the original wait deadline. A recovery placed after
the wait cannot run when the prompt has already scrolled away.
The first-login priming delay also lets terminal input settle after the redraw.

Console waits repair a frozen capture feed separately from an empty OCR result.
On headless Hyper-V, vmconnect's PrintWindow surface can keep returning the
same readable frame after the guest has repainted; OCR then waits for a marker
that is present only on the live screen. Hash the raw frame, and reconnect the
viewer if it stays byte-identical for the frozen-feed budget. The same repair
reopens virt-viewer or the UTM console on their hosts. A blinking cursor changes
live idle frames, while a cap on reconnects lets a genuinely static guest time
out without repeatedly restarting the viewer.

The status service's step-pause request writes `control.step-pause`. Check it
before sequence setup, so setup and the first action do not start during a pause
between sequences, and again before each action so a mid-sequence click takes
effect at the next step. Empty sequences have already returned before that
wait. Cycle pause is a separate runner gate at cycle boundaries.

Ubuntu waits for `${hostLabel} login:` with `freshMatch`, because the
installer can expose its own login prompt during the first reboot.
`hostLabel` is the first DNS label that agetty prints; a full dotted hostname
may appear only in the `/etc/issue` banner and disappear while the actual
prompt remains. Amazon Linux has no installer-to-installed-system console
transition and retains the plain `login:` pattern.

Password prompts use `sinceStepStart` to exclude earlier prompts and
rejected attempts from the captured console. PAM produces its next prompt
before another screenshot can usually be taken, so the baseline must be
the preceding wait's matched frame, not a fresh capture at the start of
the new step. The username prompt instead uses spatial freshness: that
prompt is already present in the frame returned by its preceding wait.
Keep the full `New password` token, because shortened alternatives can
also match the current-password or retype prompt. Bound the first
`Password:` wait to 30 seconds and stop on firmware/GRUB output; a username
that never arrived needs a retry, not a long password wait.

A rejected rotation can leave PAM waiting for another new password,
where no login prompt will appear. Both the retry's login wait and the
shell-confirmation wait therefore detect `passwords do not match` and
`Authentication token manipulation error`. Only the short shell check
also matches the full dictionary-check rejection. Bare `BAD PASSWORD` is
too broad: OCR folds `8` into `b` and accepts separated segments, allowing
unrelated address and password text to satisfy it. `Login incorrect` is
also excluded because recovered attempts leave it in scrollback.

Typing a password does not prove that login succeeded. A prompt-shaped
`user@host` pattern can match agetty's echo because OCR splits punctuation,
accepts segments out of order, and normalizes dots and colons. Instead,
type ` echo yuruna_$(seq -s '' 1 9)_ok` and freshly match its expanded
output. Only a shell performs that expansion; agetty merely echoes the
literal command. The leading space absorbs an occasional first-keystroke
loss on ARM64 Hyper-V. Persist the rotated password only after this
confirmation. After typing reboot, allow the console to transition and
wait for a fresh login prompt without nudging: a rebooting guest may
temporarily have no synthetic keyboard driver.

Timeouts remain guest-specific where observations justify them:

| Budget | Ubuntu 24.04 | Ubuntu 26.04 | Amazon Linux 2023 |
|---|---:|---:|---:|
| Autoinstall question | 1800 s | 1800 s | Not applicable |
| First login, per attempt | 1800 s | 2400 s | 300 s |
| Workload install, console and SSH | 1800 s | 3000 s | 1800 s |

These are ceilings: faster hosts do not wait out unused time. Historical
ARM64 Hyper-V observations found the autoinstall question at about 2600 s
for Ubuntu 24.04 versus 720 s for 26.04, so the 24.04 ceiling does not imply
support for that slow path. Ubuntu 26.04 installs reached 92 minutes on the
slowest measured host; three 2400 s login attempts allow roughly two hours.
The outer runner's step watchdog advances at step boundaries, not within
an OCR wait. Keep a declared wait at least 120 s plus polling overhead
below `testCycle.stepTimeoutSeconds` to permit capture-feed repair and a
named step failure. Increasing a guest timeout without the watchdog
ceiling can instead kill the whole inner runner.

Ubuntu 26.04's Code install measured 1373 s on a quiet ARM64 Hyper-V host
(456 s JDK, 20 s .NET, 897 s Code) and remained unfinished after 1810 s
under contention. The cost was unpacking/configuration, despite fast
downloads and an idle virtual disk. Those measurements included Code's
recommended packages, while current scripts use `--no-install-recommends`.
The 3000 s ceiling allows host contention and must be accompanied by a
sufficient runner watchdog ceiling. Keep console and SSH budgets equal
for the same guest workload: the package installation dominates either
transport. Amazon Linux installs the Desktop package group; its console
and SSH paths both allow 1800 s. The console expands its success marker
only after `dnf` succeeds so the echoed command cannot satisfy the wait. See [Hyper-V troubleshooting](https://yuruna.link/42dc5bb9)
for the VMBus and hypervisor-intercept constraints.

<a id="42e220c4-0008"></a>

## Service lifecycle

All four service VM Start/Stop pairs expose `SupportsShouldProcess`.
Their first executable statement gates the operation before imports,
runtime-file writes, NAS mounts, service starts, or VM changes. `-WhatIf`
therefore returns at the same boundary across caching proxy, stash,
pool-control, and download-agent services. Pool-control's actual
`-HostSideProof` keeps its existing build and process-launch gates; its
`-WhatIf` path returns at the common early boundary.

Stash, pool-control and download-agent starts follow these common phases:
validate the VM name and Windows elevation, initialize host access, check
storage, resolve the VM builder, start the host status service, verify the
framework source, build the VM, register/start UTM if applicable, confirm
the VM is running, configure NAT forwarding, probe readiness, recover the
address if the probe failed, evaluate the final readiness result, publish it,
and collect failure diagnostics or report the deployed source. The preliminary
verdict only gates recovery; the final verdict always reads the resulting endpoint.
The caching proxy additionally owns host proxy settings, CA/config-service
setup, bridge preparation and multiple port mappings; its healthy-VM
adoption and lifecycle lock remain specific to those responsibilities.

Acquire the caching-proxy lifecycle lock before destructive VM or port-map
changes and release it through `try`/`finally` on every exit. An in-process
script shares its operator's long-lived PowerShell PID, so a leaked lock cannot
rely on dead-process recovery. Before calling a child script, reset the global
`LASTEXITCODE`, capture `$?` immediately afterward, and verify its artifacts.
A local variable would shadow the native exit-code updates in child scopes.

Check for Administrator privileges on Windows before mounting a share or starting a
detached service: the delegated Hyper-V builder cannot elevate mid-run.
KVM instead uses the shared libvirt-group re-execution helper; UTM has its
own provider requirements. `Initialize-YurunaEntryPoint` returns paths
only, so commands such as `Initialize-YurunaRuntimeDir` need their module
imported explicitly. Log-level overrides follow script defaults and a
script-scoped preference must be refreshed from the resulting global
value. Preserve nonterminating host-contract behavior: these service
scripts use explicit failure paths instead of setting a blanket
`ErrorActionPreference = 'Stop'`.

The inner runner reloads its complete module set at each cycle boundary using
the same list as bootstrap. The recurring runner starts fresh cycle and inner
processes on every host. A pull within the cycle can still change code after
bootstrap, so this reload loads the current modules and host driver before
provisioning; it also protects an in-process retry. Keeping one module list
avoids a second source of truth. The reload costs roughly a second per cycle.

After a watchdog stop, the outer runner re-ensures the status service before
the failure pause. Windows `taskkill /T` can kill the inner runner's status
server child just when an operator needs `/control/start-cycle`; Unix reparents
the server, and the config service is owned by a different process. Starting it
from the outer runner gives it a stable parent. Invoke the starter directly so
a transient port conflict is logged without exiting the outer runner, and wait
for the host-refresh gate before allowing a starter that can replace a port
owner.

At a fresh outer-runner start, recover stale incomplete cycle markers, dead
inner PID files, abandoned break markers, and pause flags before claiming the
runner PID. PID cleanup removes only proven-dead processes, leaving a legitimate
concurrent runner to the single-instance gate. If the prior state belongs to a
different run and is not idle, initialize the state machine with an explicit
fault-to-idle transition. A host-refresh resume preserves the operator's pauses,
holds, and restart request; it archives only the reclaimed inner generation and
delays the recovery sweep until it owns the runner PID.

Stash uses its isolated stash share; pool-control and download-agent use
pool storage. Missing configuration or a missing stored NAS password is
a hard preflight failure. A mapped vault key without a stored password
can generate a value the existing NAS account will reject. An unavailable
share after a real credential was stored is a warning: stash can buffer
uploads locally and the other daemons expose the offline state. Diagnose
the actual mount error; a sudo refusal does not test the NAS credential.

The host status service must serve the local framework before the guest
boots and also serve host registration to the aggregator. Honor its
configured enablement and port, reuse a healthy instance, capture the
expected framework snapshot before building, and verify the running
daemon's source afterward. An explicitly allowed mirror source supports
off-LAN deployment. Pool-control verifies that source before repointing
the caching proxy's read-only configuration alias; that alias sync runs on the
host, which holds the private SSH key, rather than baking that key into
a web-facing guest. Alias synchronization is best-effort.

Hyper-V and KVM start inside their builders. UTM builders create bundles,
so the launcher calls the shared host-contract `Start-VM`: that owns VNC
display arbitration, dialog handling, registration/open/start, and checks
for a QEMU process that immediately dies. Every launcher then verifies the
VM actually reached `running` before diagnosing the guest daemon.

UTM network mode comes from the created bundle. Moving between Wi-Fi and
Ethernet can require rebuilding a VM whose baked network differs from
the host's current uplink. Shared NAT exposes stash SSH on host 2222,
pool-control HTTP on 8081 and download-agent HTTP on 8082. The Mac's SSH
server owns 22 and the caching proxy already owns 80. A host-private guest
address is not a LAN address. Repoint forwarders when DHCP identity
changes the guest address: a listener aimed at a dead predecessor accepts
connections and then stalls, misleading every caller.

All three daemon waits resolve their 2700 s default and positive-integer
`YURUNA_<SERVICE>_READY_TIMEOUT_SECONDS` override through
`Get-ExtensionServiceReadyTimeoutSeconds`; the download-agent-specific
helper remains as a delegating API. A cold build may install Go and
PowerShell and compile for about half an hour on a slow UTM guest. The
wait polls actual service readiness and extends to at most twice the
initial budget while the guest reports cloud-init running or not started.
Progress describes the observed guest state, not an assumed build.

Wait for an address after starting; one empty lookup is not proof that
the VM failed. Bridged UTM guests may have neither a local DHCP lease nor
a guest agent. SSH can resolve a guest by another route and confirm its
listener from inside. Report the actual discovery time when no ordinary
probe ran. On failure, try the diagnostic address resolver once and
recheck the service for a bounded 60 seconds before finalizing the
verdict. The resolver may recover through ordinary discovery or a bundle
MAC, so report the recovered address without asserting an unobserved
mechanism. Reuse that address for SSH diagnostics and forwarder repair.

One readiness verdict drives every report and marker:

| Verdict | Bring-up result | Active marker | Published URL |
|---|---|---|---|
| Ready | Success | true | Verified reachable endpoint |
| Unreachable | Success; guest confirms its listener | true | Empty |
| StillBuilding | Build remains in progress | false | Empty |
| NotServing / no result | Failure | false | Empty |

Do not write an optimistic active marker before readiness. Marker writes
are followed by best-effort host registration so the aggregator sees
the change within a poll instead of waiting for a test cycle. The stash
address helper additionally rejects a host-private endpoint for pool
publication and checks its health. A daemon's own announcement can still
register it where peers can reach it.

On failure preserve the VM as evidence. Capture a console screenshot and
report it only if a file exists. SSH diagnostics name the account created
by the service seed rather than a leftover per-cycle override; prefer the
address just recovered and retain the VM name as a fallback. Capture guest
addresses, cloud-init status, systemd state, journal, listener, NAS mount,
and cloud-init output. Generate an SSH hint only when an address is
known, otherwise explain how to discover it. Stash additionally confirms
that the host status service is reachable before reporting completion.

Stops clear the marker and republish registration before stopping or
deleting the VM, avoiding an advertised endpoint that is already gone.
Caching-proxy teardown also clears its persisted IP on every host before VM
removal while retaining the durable password.
Pool-control reads its marker before removal so a host-side proof PID can
also be stopped. Graceful stop comes first, allowing beacon goodbye,
lease release and a stash-buffer flush; force-stop is the fallback.
Remove domain registration and per-VM disk/seed/bundle even when the VM
is already absent, because an interrupted builder can leave files behind.
The final state must be `absent`. Downloaded image generations and pool
state live on pool storage; committed stash artifacts and host keys live
on the stash share. A locally buffered upload that still has not flushed
can be lost when the disposable VM disk is removed.

**`test/service/Repair-CachingProxyServiceForwarder.ps1`.**

The cache lives directly on the LAN now. Any pwsh forwarder.<port>.pid
subprocess left behind from the legacy shared-NAT layout is noise --
it binds 0.0.0.0:<port> on this Mac, tunnels to a stale 192.168.64.X
IP that may have been reassigned, and blocks anything else (this very
script's verification probes; a remote host that points
YURUNA_CACHING_PROXY_SERVICE_IP back at the Mac instead of the cache) from
reusing those ports. No-op on a fresh install.

**`test/service/Start-CachingProxyServiceVM.ps1`.**

Size the cache for a shared lab beacon, whose cache answers every machine
in the pool. Without it the VM is built for a host that runs the cache
beside the stash, the download agent and its own test guests, where every
gigabyte here is one those guests cannot have -- the ordinary case, and
the safer one to default to. The RAM and squid's cache_mem are resolved
together and passed together -- swap is masked in the guest, so moving one
without the other is an unrecoverable OOM rather than a slowdown.

Windows has no mid-run elevation: querying Hyper-V (Get-VMHost), creating
and removing the cache VM, and setting the host proxy + netsh portproxy
all need an elevated session. Check NOW and stop with a clear reason. A
non-elevated run otherwise hits a non-terminating Get-VMHost permission
error, leaves the VHD path $null, and cascades through null-path failures
before the real cause (need-admin) finally surfaces from Get-Image.ps1.

Capture the cleared values to a sidecar BEFORE removing them, so
a downstream operator (or an automated re-invocation after a Ctrl+C
mid-bring-up) can restore the proxy state without re-typing it from
memory. The sidecar lives next to runner.pid so it's wiped by
Remove-TestVMFiles along with the rest of per-host state. Best-effort:
write failures are logged Verbose and the cleanup continues.

Surface the sudo requirement up front, unconditionally. The Step 0 sudo
priming only prints its reason box when it actually prompts -- a warm
sudo timestamp, or YURUNA_SUDO_PRIMED=1 from an install wrapper, skips
that box, and the long Step 5 discovery wait can expire the timestamp so
a later call prompts bare. This notice guarantees the operator always
sees WHY their password may be requested. (Windows handled above.)

The cache VM boots the base image every extension service on this host
shares; resolve it from the same helper Get-Image.ps1 and New-VM.ps1 use so
the artifact check below can never test a path they don't write. On Hyper-V
the resolver reads (Get-VMHost).VirtualHardDiskPath, which loads the Hyper-V
module on first use -- the underlying New-VM.ps1 has the same dependency, so
surfacing that failure here keeps the error close to the user.

Single cross-cycle persistence file (yuruna password + cache VM IP)
under the framework's runtime directory. One framework-managed path
avoids the per-platform sidecar drift class where each host's
VHD/raw image directory carried its own caching-proxy-service-password.txt
and cache-ip.txt out of sync. Get-CachingProxyServiceStatePath comes from
Test.CachingProxyService, loaded by the CachingProxyService kind at file top.

The start is on record, and this service's operation lock held, before the
bring-up lock and before anything is torn down or built: a Stop issued
meanwhile waits for the lock instead of removing a half-built cache, and the
reboot sweep and a host refresh see the request. The operation lock comes
first, the same order Stop-CachingProxyServiceVM.ps1 takes them in, so the two
scripts can never each hold the lock the other waits for. A request that
cannot be recorded changes nothing.

Step 0's plan already determined a LAN-routable bridge is
impossible right now (no default route, Wi-Fi NIC, or -- most
importantly -- NetworkManager has crashed recently and re-trying
the nmcli build would just crash it again + raise another apport
dialog). Honor that plan: skip the attempt entirely rather than
re-running New-YurunaExternalNetwork only for its internal guard
to bail. The full reason was printed in Step 0.

By-name (hashtable) splatting is REQUIRED here. Array splatting binds
every element POSITIONALLY -- a literal '-MacAddress' string element is
never re-parsed as a parameter name, so the child rejects it with "A
positional parameter cannot be found" and never runs at all. The key is
added conditionally so the bare call keeps each platform New-VM.ps1's
random-MAC default.

**`test/service/Start-ConfigService.ps1`.**

Resolve the JSON payload for a NAS name, or $null when not configured. Reads
test.config.yml + the vault FRESH each call so a rotated password / changed
share is picked up live. Never mints a junk password: when the networkUser has
no real vault entry (empty vaultKey AND no stored secret) it returns $null so
the caller answers 503 rather than baking an auto-generated credential the NAS
would reject.

The child echoes its PID via `echo $!`. Verify that value parsed to an
integer AND the process is still alive right after launch: a serve process
that dies immediately (module-import error, port already bound) never opens
$Port, so without this check we would record a PID file pointing at a dead
process and then burn the full readiness timeout on a port that will never
accept. If it is already gone, surface the captured startup log now.

**`test/service/Start-DownloadAgentServiceVM.ps1`, `test/service/Start-PoolControlServiceVM.ps1`, `test/service/Start-StashServiceVM.ps1`.**

The start is on record, and this service's operation lock held, before
anything is built: a Stop issued meanwhile waits for the lock instead of
tearing down a half-built guest, and the reboot sweep and a host refresh see
the request. Taken after the group relaunch, because a lock taken in the
parent would block the relaunched child. A request that cannot be recorded
changes nothing.

**`test/service/Start-PoolControlServiceVM.ps1`.**

No trailing slash, which is not cosmetic: the service's own announce derives
its address from the connection it arrives on and so never carries one. The
aggregator keys a candidate on the exact target string, so the two spellings
of one address register as two candidates for the same host and area, and the
loser is reported as a supersededTarget. Probing already tolerates either
form, which is why nothing failed and the difference showed up only as a
duplicate. The sibling services advertise the bare form as well.

**`test/service/Stop-CachingProxyServiceVM.ps1`.**

The stop is on record, and this service's operation lock held, before the
first change (the bring-up lock clear below): the reboot sweep and a host
refresh then honor the request, and a concurrent Start cannot rebuild the
cache mid-teardown. Taken before the sudo priming so a busy service refuses
before anything is asked of the operator. A request that cannot be recorded
changes nothing.

Tear down any leftover host-side forwarders from the retired
shared-NAT path (forwarder.<port>.pid pwsh subprocesses under
$HOME/yuruna/image/caching-proxy-service). With the cache VM bridged
directly to the host's LAN NIC there is no host:port forwarder
layer in the data path -- but an upgrade from the previous shape
can leave one running, and on macOS killing the root-owned :80
forwarder requires sudo. No-op on a fresh install.

<a id="42e220c4-0009"></a>

## Project examples

Website workloads for Ubuntu 24 and 26 and the text-to-sql application workload use the same container acquisition and deployment flow, differing in project/component names. Their PowerShell certificate-check, certificate-Secret and base-image seed scripts share behavior. Dockerfiles retain application dependencies such as the website's LibMan restore; database setup and connection settings belong specifically to text-to-sql.

Both Helm deployments request ephemeral storage so kubelet accounts for the pod
before its node reaches the 85% eviction threshold; the limit caps a runaway
build or log loop. CPU and memory requests equal their limits, which keeps the
pods in Kubernetes' Guaranteed quality-of-service class. The website needs a
256 MiB memory limit: its healthy steady state has measured about 127.5 MiB,
leaving almost no startup headroom under 128 MiB. At that lower limit the
process can stall with its port unbound rather than exit cleanly, and readiness
times out. Text-to-sql retains its separate 128 MiB limit.

The mobile navigation check follows `aria-controls` and verifies both the ARIA
state and the controlled panel's visible expansion/collapse. A completed ARIA
change alone does not prove the panel finished its collapse transition.

<a id="42e220c4-0010"></a>

### Image acquisition and build boundaries

A workload first reuses local images. When a cache is configured, it pulls the registry image explicitly as `<cache>:5000/library/registry:2`; a bare Docker Hub reference could let Docker abandon a slow mirror and consume the lab's upstream quota. In a lab without a cache, `registry:2` is the appropriate upstream reference. Five attempts with increasing delays tolerate a cache VM restart. Final diagnostics identify the actual source: an unavailable cache, an unavailable upstream, a slow response, or throttling. See [registry startup](https://yuruna.link/42f6b05f-0019).

`warm_manifest` holds a bounded curl request open while a cold tag synchronizes. Docker's own response-header timeout can be shorter than this synchronization; increasing the surrounding pull timeout does not change Docker's internal limit. Warm-up is advisory and records HTTP status, elapsed time, and curl's exit code so connection refusal, DNS failure, and timeout remain distinguishable. The subsequent pull owns success or failure. `YURUNA_PULL_STALL_TIMEOUT` bounds elapsed pull time, not progress, and can be increased for slow links.

Base images are acquired from the local Docker store, then the configured cache, then MCR, and seeded into the project's local distribution registry. Cache probes include the upstream namespace. Builds use that local registry for `FROM` metadata and layers so a remote metadata fetch cannot wedge a single opaque build invocation. The image lists must match Dockerfile `FROM` lines. Both shell and PowerShell seed paths skip images already available at the required destination. See [local base-image seeding](https://yuruna.link/42f6b05f-001a).

Shell command bounds use `timeout --foreground` to avoid stopping terminal-dependent children with SIGTTIN/SIGTTOU, returning 124 for retryable expiry. If `timeout` is unavailable the command runs without that bound. PowerShell's Docker wrapper bounds the process tree and keeps command output off the success stream, which contains only the exit code.

The Dockerfile's `REGISTRY` prefix must end in `/`; its default permits ordinary MCR builds outside the harness. Component preparation only verifies that the development certificate opens with the nonempty password in `ASPNETCORE_Kestrel__Certificates__Default__Password`, falling back to `<certificate>.password` when the variable is unset or empty. It fails immediately when the certificate cannot open, without changing the caller's working directory. The image carries no certificate: the workloads phase creates a Kubernetes Secret holding it under a generated password (a throwaway self-signed certificate when `YURUNA_EXAMPLE_SELF_SIGNED_CERT=1`), and the pod mounts that Secret. Visual Studio's Dockerfile integration is described in [Microsoft's container development guidance](https://aka.ms/containerfastmode).

The website and text-to-sql SDK stages restore their project packages once, then compile through `dotnet publish --no-restore`. Publishing must compile fresh and fail on compiler errors; an intermediate `dotnet build` would compile the same application twice. Website client-library restoration still precedes publication.

The development launchers stop when Docker build fails so an old tagged image
cannot masquerade as the new build. Both report a failed Docker run, build from
their own component directory, and restore the caller's directory on completion.
PowerShell uses `finally`; CMD uses `popd` on each exit path.

Certificate and database Secret helpers redact secret values from native
failure output and exceptions, including errors that echo the submitted JSON.
Keep the failure cause while removing plaintext passwords and encoded Secret
data. Tests restore each original environment value, including absence, after
running native-command fixtures.

Docker arguments retain their individual boundaries on every host. Standard
output and error drain concurrently. Execution, process-tree termination, and
output drain stay bounded; incomplete capture fails instead of returning
success. A diagnostic relay after process cleanup may still take time to print
captured output.

<a id="42e220c4-0011"></a>

### Sequence parity and readiness

The identical website deployment script receives 1800 seconds in GUI, cold SSH,
warm SSH, and chapter-two flows. Prompt, boot, and input budgets remain separate.

GUI and SSH website sequences both wait for every Kubernetes node to become Ready. GUI sequences clear the screen after a successful wait and match `control-plane` in the resulting node table. Matching `Ready` alone could accept either the echoed command or `NotReady` under fuzzy OCR. The outer 360-second limit exceeds the inner 300-second wait.

SSH HTTP checks use `sshFetchAndExecute` so the helper's exit status reaches
the runner. Searching a piped output file for `200` can accept an earlier
successful response after the helper fails. Their 240-second step allowance
exceeds the helper's 180-second readiness budget. GUI HTTP checks allow at
least 420 seconds for console delivery, readiness, and OCR; longer application
budgets remain valid. Book and website console flows share shell prompt guards
and input priming before typing commands.

Website and book chapter-two GUI sequences use the same 60-line completion window after clearing the console and activating the Docker group. The wider window retains the build/deployment completion marker without admitting a marker from an earlier step. Deployment readiness waits stay inside workload scripts; typing their full command into the UTM console risks dropped or repeated characters. Book interactive/unattended pairs differ only in identity, descriptive metadata, and the intended breakpoint. See [console-safe readiness](https://yuruna.link/42a76c30-000b).

The default runner chooses Ubuntu 26 for the website workload. Ubuntu 24's ARM64 Hyper-V boot has an observed VMBus soft-lockup failure; the separate `workload.guest.ubuntu.server.24.k8s.website` sequence preserves that workload for compatible hosts. Amazon Linux's ARM64 cloud image lacks the Hyper-V storage drivers needed by this lab, while its x86-64 Hyper-V image and virtio-based KVM/UTM paths remain available through `workload.guest.amazon.linux.2023`. These compatibility constraints justify selection differences, not omissions from shared workload logic.

Project sequences keep English `description` values as fallbacks. Optional `descriptionLocalized` maps use canonical locale tags and hashes in `globalization/project-locale-source-hashes.json`; invalid or stale published translations are rejected, while runtime readers fall back to English.

<a id="42e220c4-0012"></a>

### Workload configuration boundaries

Cert-manager cleanup selects installed resources by `app.kubernetes.io/instance=cert-manager`, including cluster-wide resources and leader-election roles in `kube-system`. It must not download a version-specific release manifest to remove existing resources. Namespaced resources are removed with the namespaces already covered by the workload cleanup.

The generic template creates a namespace and registry pull secret, leaving `TO-SET` for the user's component. The website localhost configuration supplies a complete mkcert/ingress example; its Azure configuration demonstrates cert-manager using a single `certManagerLatest` variable.

Text-to-sql initializes PostgreSQL before deploying its application. The pod's `status.hostIP` identifies the node running PostgreSQL, `$(HOST_IP)` and `$(TEXT2SQL_PG_PASSWORD)` expand from the environment variables defined before them in the pod, the password arriving from the `text-to-sql-db` Secret that the setup script's owner-only password file feeds. The application has no built-in connection string: `TEXT2SQL_PG_CONN`, `ConnectionStrings:Postgres` or `TEXT2SQL_PG_PASSWORD` must be set, or startup fails. PostgreSQL listens on the node network and permits the pod CIDR. Npgsql connects lazily, so pod readiness or HTTP 200 alone does not establish database connectivity. See [text-to-sql integration](https://github.com/alissonsol/yuruna-project/blob/main/example/text-to-sql/README.md).

<a id="42e220c4-0019"></a>

## Automation entrypoints

`yuruna.ps1`, `Set-Resource.ps1`, `Set-Component.ps1`, `Set-Workload.ps1`,
and `Invoke-Clear.ps1` share the same bootstrap phases: log level, root
resolution, transcript path, operation module imports, transcript start,
operation, transcript stop, and completion. `Set-Workload.ps1` additionally
checks the container runtime before resolving the project roots; the other
entrypoints omit that runtime preflight before root resolution.

Resolve project/configuration roots and the transcript path before removing
`Yuruna.*` modules. Both resolvers live in `Yuruna.LogLevel.psm1`, which that
removal also unloads. Resolve the roots once, export the matching environment
values, and then load the operation modules. The log-level helper imports the
globalization renderer and has no operation-module state to preserve.

`Test-Runtime.ps1` can print diagnostic tables before returning its Boolean
verdict. Inspect the last output item, require its Boolean type, and fail when
there is no verdict; testing the entire collection would treat printed
diagnostics as success. A missing prerequisite or failed operation must exit
with status 1 so shell callers using `set -e` stop at the failing action.
Resource, component, and workload operations return result manifests;
clear/requirements/validation retain their Boolean outcomes. The dispatcher
checks the result type before choosing the corresponding completion path.

A caller can name its transcript through `YURUNA_TRANSCRIPT_PATH`. The resolver
consumes that environment value before starting nested operations so an inner
run cannot truncate an outer transcript. It verifies the named path is writable
while a fallback is still available; an unusable path selects the default. The
default is a named `transcript-<utc>-<id>.log` in the `yuruna-transcripts` temp
folder, which keeps only the newest 20, so transcripts never accumulate as
anonymous `tmp*.tmp` files (on Windows, `GetTempFileName` fails once 65,535 of
those exist).
Printed transcript instructions remain operator text and are not a wire format
for callers to parse.

**`test/service/Start-McpServer.ps1`.**

Most of these scripts have no [CmdletBinding()], and a script without it
absorbs an unknown -Name into $args and runs anyway. So an argument the
target does not declare is not refused by PowerShell -- it is silently
dropped, and the run proceeds against defaults while the caller believes
its input was honored. Refusing here is the only place that reads as a
failure. The check is over the declared parameter names, not over any
message, so it holds on a host in any language.

<a id="42e220c4-000a"></a>

## Automated checks

Run the focused consistency suite with
`Invoke-Pester -Path test/modules/Test.SourceConsistency.Tests.ps1`.
It compares common regions and verifies seed/provider contracts without starting
a VM. Its source scan covers `yuruna`, `yuruna-project`, `yuruna.link`, and
`amisad.dev` (or the `alius-git/amisad.dev` fallback): region markers have no
following blank line, structural links remain
ordinary comments, test sequences use only their three canonical regions,
YAML, XML/plist, HTML, and systemd/INI regions match the key, element, or
bracketed section they introduce,
decorative headers do not return, SQL `--` and CSS `/* */` dividers are held to the
same rule, native SQL and CSS REGION markers have no following blank line, and
PowerShell help stays inside a function when a region precedes it. The suite also compares Ubuntu release sequences and
the common service-lifecycle preamble. Sequence fixtures prove that missing,
misnamed, nested, and action-level regions fail the guard, while ordinary
documentation comments and CRLF remain valid. Structural marker fixtures also
cover quoted YAML keys, ordinary adjacent comments, exact case, and separation
by another region or a blank line. Both direct and organization-
nested AmisAd sibling checkout layouts are recognized when present. The source
and link-validation inventories prefer the direct sibling and use the nested
layout when it is absent. Explicit roots retain Git ignore and path filtering;
adding a default root explicitly does not scan it twice.
The inventory includes CommonJS/ES modules, PowerShell data files, Dockerfiles,
Git hooks and attributes, SQL, Terraform, and TOML alongside the host/guest scripts.
Git-tracked hidden files must be read explicitly; filesystem visibility does
not exempt them. Runtime, build, vendor, and dependency directories remain
excluded even when a file there has a supported source extension.
Run the affected guest, image, and
sequence suites after behavior changes. PowerShell edits must pass
`tools/Invoke-Lint.ps1`; shell edits must parse with `bash -n`.

`tools/Test-AsciiNoBom.ps1` applies the ASCII policy to maintained PowerShell,
shell, CSS, JSON, and YAML source. The bootstrap installers and first-run guest
scripts also have a narrow gate because a BOM can break `irm | iex` or
`curl | bash` before a tolerant file reader exists. Translated catalogs and
their generated artifacts require UTF-8 rather than ASCII and are checked by
`tools/Test-Utf8Catalog.ps1`. Markdown, HTML, JavaScript, and explicit non-ASCII
test fixtures retain their intended typography or charset coverage. The
separate BOM-only gate checks staged files regardless of their ASCII policy.

`host/modules/Yuruna.HostConsistency.Tests.ps1` checks the same 40 contract
function regions in every provider, verifies internal help placement, and calls
`Get-Help` on isolated lifecycle definitions. The guest installer outcome suite
compares the standalone winget helpers and exercises every prerequisite call
site. Service seed checks compare the complete shared locale file; pool-control
fixtures also exercise canonical, legacy, and absent locale settings.

The host-provisioning and guest/project consistency suites exercise failure
paths with temporary files and native-command substitutes. They cover disk
resize failures, media architecture, force-stop dispatch, safe domain removal,
archive fallback, and development-launcher failures. Host I/O fixtures remove
only their own registry entry and restore any previous value under that name;
unrelated providers must survive a suite running in an existing session.

After changing documentation links, run `tools/Invoke-DocAnchor.ps1 -Update`,
`tools/Update-LinkCatalog.ps1 -Update`, and `tools/Test-RegionAnchors.ps1 -Quiet`
with the project and link repositories checked out beside the framework.
The anchor gate also scans the AmisAd checkout and accepts extra source roots;
Git ignores continue to exclude generated artifacts. Anchor generation accepts
LF and CRLF equally so a Windows checkout cannot reissue existing heading IDs.
Static checks complement a real Windows, macOS, and Ubuntu guest cycle; they
cannot verify host networking, GUI console behavior, or vendor image availability.

<a id="42e220c4-000b"></a>

## UTM templates

XML templates use `<!-- REGION: <label or short link> -->` because a shell
comment would make the plist invalid. Common top-level fields keep the same
labels. Preserve the following hardware and schema constraints when comparing
templates:

- Linux guests use QEMU so the harness can capture screens and inject keys
  through a localhost VNC connection without taking GUI focus. The display
  number comes from `Get-VncDisplayForVm`; the port is 5900 plus that number.
  `share=force-shared` lets the screenshot and cached keyboard clients coexist.
- `AdditionalArguments` contains plain strings, one per argument. A dictionary
  with an `Argument` key fails UTM configuration decoding. Linux VNC guests use
  `virtio-gpu-pci`: GL display devices conflict with VNC, while plain ramfb does
  not provide the early UEFI graphics output needed for boot-console OCR.
- Test displays stay at 1920 by 1080 with dynamic resolution disabled; QEMU
  `xres` and `yres` also pin the Linux device's preferred mode. Service displays
  remain minimal because their workload is headless. Windows uses
  `virtio-ramfb`, the non-GL variant, because its localhost VNC listener sends
  the DVD boot key; `virtio-ramfb-gl` makes QEMU exit with "The console requires
  a GL context". Changing the Windows display device needs a Windows display and
  driver test, not just copying Linux display arguments.
- Ubuntu's disk has boot index 0 and installer ISO index 1. The unindexed cidata
  seed stays attached. This order allows the installed disk to boot after the
  installer finishes, before or after its `efibootmgr` entry is available.
  VirtIO seed disks avoid the USB enumeration race that can hide the cidata
  label when cloud-init's local stage starts.
- Amazon Linux's ARM cloud image needs `type=1,serial=ds=nocloud` in SMBIOS to
  select NoCloud when its datasource list otherwise contains only EC2 and None.
  The Hyper-V image already includes NoCloud. This difference is required for
  user creation, passwords, and SSH settings to run at all.
- Ubuntu 26 uses e1000 while Ubuntu 24 uses virtio networking. The emulated NIC
  limits early link-change events that can stall the Ubuntu 26 installer;
  `accept-ra: false` alone did not prevent that behavior. Keep this workaround
  until a real installer cycle proves it unnecessary.
- Service network mode and bridge interface come from the builder. Bridging
  gives the service a LAN address; Shared NAT requires the host forwarding
  paths used by the service launchers. Storage-backed services still need a
  route to their NAS. Cache-specific offload settings belong in its overlay.
- macOS guests use Apple Virtualization and an IPSW restore. `MacPlatform`
  requires PascalCase `AuxiliaryStoragePath`, `HardwareModel`, and
  `MachineIdentifier` keys; lowercase variants fail configuration decoding.

**`host/macos.utm/guest.macos.26/New-VM.ps1`.**

VZMacOSInstaller only reaches the system installation service when the
helper binary carries the com.apple.security.virtualization entitlement;
Invoke-EntitledSwift compiles + self-signs it before running. The helper
prints "Restore progress: N%" to stderr every few percent; -LineHandler
routes those into a PowerShell progress bar live, and the merged output
is still returned so we can recover the final MAC_PLATFORM tuple.

<a id="42e220c4-000c"></a>

## Windows unattended setup

The three unattended files share setup passes, locale, partitioning, account
creation, and bootstrap commands. Hyper-V and KVM use `amd64`; UTM uses `arm64`.
KVM additionally loads virtio storage and network drivers from the attached
driver ISO. Drive letters vary, so the driver search covers D through F.

KVM installs and starts OpenSSH Server and opens inbound TCP 22. Its initial
password is not expired because Windows SSH cannot perform the password-change
challenge. Hyper-V and UTM retain the console-driven password-change step.
Keep first-logon command ordering consistent after accounting for those extra
KVM commands.

The shared bootstrap writes host coordinates, installs address refresh, and
configures noninteractive Git credentials for private framework and project
clones. Builders pass it as an encoded PowerShell command so quotes, dollar
signs, and redirection cannot be corrupted by XML or command-line escaping.

<a id="42e220c4-0016"></a>

## Dependency probe contract

`automation/Yuruna.Requirement.yml` supplies the same version expressions to
`Confirm-RequirementList` in `automation/Yuruna.Requirement.psm1` and the
standalone diagnostic's HOST software section. On a healthy installation,
each expression prints only its version string. The consumers add their own
missing-tool fallback. Use YAML block literals (`|-`) for expressions with
regex backslashes or embedded apostrophes: double-quoted YAML interprets
backslashes, while single-quoted YAML requires doubled apostrophes.

A version floor follows the lowest version available through every supported
host's package source. Ubuntu LTS archives freeze versions and backport fixes;
Homebrew and winget can move sooner. A floor above a supported source reports
a defect that its installer cannot repair. Docker Engine and buildx floors
follow Docker Desktop's bundled versions; npm follows the bundled Node LTS
version. A floor establishes provisioning, without promising the latest release.

`docker --version` is a local probe. `docker version -f json` contacts the
daemon and can stall for about 30 seconds precisely when diagnostics need to
report an unreachable daemon.

The Windows QEMU installer can leave `qemu-img` off PATH, while other Windows
packages that ship one put it on PATH -- the Cloudbase 2.3.0 port, from
winget's `cloudbase.qemu-img` or Chocolatey's `qemu-img`, is the common one.
On Windows the probe therefore ranks the installer's locations and every
copy on PATH and reports the newest, the earlier one on a tie, exactly as
`Resolve-QemuImgCommand` in `host/modules/Yuruna.Image.psm1` chooses the copy
the harness runs; a PATH-first probe judged the floor on a copy the harness
should never use. The installer locations must match the resolver's, and
`test/modules/Test.QemuImgResolution.Tests.ps1` holds the probe, the
standalone diagnostic's copy and the resolver to the same set and the same
ranking. Strip the constant copyright suffix from its first version line.
Keep the ranking Windows-only: on macOS and Linux the drivers run the name,
and a missing or older package-manager link there is a defect that
installation repair must detect.

`oscdimg` prints `OSCDIMG X.YZ CD-ROM and DVD-ROM Premastering Utility`
before its usage text when called without arguments. It has no version flag;
`-h` means include hidden files. Find the banner rather than assuming line 1.
Disable `PSNativeCommandUseErrorActionPreference` locally because this probe's
expected non-zero exit must not become a terminating error under PowerShell 7.4+.
The ADK keeps architecture-specific copies off PATH; any installed copy can
establish the version floor. Executable architecture selection remains the
responsibility of `Resolve-OscdimgPath` in the Hyper-V provider.

<a id="42e220c4-0017"></a>

## Standalone diagnostic dependencies

`automation/Get-SystemDiagnostic.ps1` runs alone in a guest's `/tmp` when the
console diagnostic path downloads it. Keep it self-contained: no module
imports, `using module`, `#requires -Modules`, dot-sourcing, or shared helper
files. It intentionally embeds copies of the log-level cascade, message
renderer, and English messages. Modules remain the source of truth; update
embedded copies when their source changes. `Test.SystemDiagnosticSelfContained`
checks that parity.

Inside a checkout, the diagnostic reads the compiled catalogs and locale
manifest as data; outside it, embedded English messages remain available.
Optional commands supplied by an existing caller require a `Get-Command`
guard and a local fallback.

<a id="42e220c4-0013"></a>

## Extension module boundaries

The [digest extension](../test/extension/digest/README.md) computes SHA-256
values on the host and carries them through the typed launch command.
`fetch-and-execute` verifies its script against that value. Nested downloads
need their own digests before extraction, installation, or database execution:
a script's digest does not establish the bytes of a later HTTP response.
The expression readers `Get-FileSha256`, `Get-ArchiveSha256`, and
`Get-PublishedSha256` warn and return an empty string on failure. A verifying
guest rejects the empty value. `Publish-GuestFileSha256` runs through
`callExtension` and throws to fail its step.

The [stash daemon](../test/extension/stash-service/server/README.md) owns the
SCP/SFTP handlers, SQLite index, and storage layout. The host extension's
`Get-StashServiceInfo` remains an unsupported-status stub until host-side
status probing is implemented. `Resolve-Host` resolves the current VM address,
then the published `<runtime>/stash-host.txt` address, then the extension's
configured host address, which can belong to another pool machine.

`Test-StashServiceHost` and `Publish-StashServiceHost` check `/healthz` during
cycle warm-up and publish the result. This stops an unreachable stash before
long provisioning stages. Later `Resolve-Host` calls recheck the published
address because a cycle can outlast its guest's address, and republish a
working fallback when necessary. See the [stash guide](https://yuruna.link/42f5e921).

**`test/extension/authentication/default.psm1`.**

Leading-character alphabet: alphanumerics ONLY (no symbols). A symbol in the
first position -- notably a YAML indicator (! @ # % & *) -- makes the YAML
serializer single-quote the whole scalar when the vault is written. The
cloud-init seed then substitutes it UNQUOTED into `password: <value>` via
literal .Replace (New-CloudInitUserData), where a leading indicator is an
invalid scalar: it silently mangles the guest's chpasswd (login impossible)
and can abort the cloud-config stage, so the VM never finishes cloud-init and
never gets an IP. Interior symbols are safe -- the password has no spaces, so
no `: ` / ` #` sequence forms and nothing needs quoting -- and the quoting
characters (' ") are already absent from $script:Alphabet.

**`test/extension/authentication/users.yml.template`.**

Yuruna authentication: logical-username -> corporate-identity mapping.

With all corporate.* / vaultKey / localOsPasswordRef fields empty
(the default), each logical user is its own local OS account with a
vault-auto-generated password.

To integrate with a corporate directory (AD / Entra / SSSD-against-
LDAP / ...):
  1. Populate `corporate.domain` + `corporate.sam` (or `corporate.upn`)
     so sequence-login steps render the right identity via the
     ${loginUser} substitution.
  2. Set `vaultKey` to the vault.yml entry holding the corporate
     password (e.g. "corp.alisson.sol") and pre-populate that entry
     manually. Test-Config.ps1 blocks the cycle if it is missing --
     the vault never auto-generates for a populated vaultKey.
  3. Leave `localOsPasswordRef` empty unless the local OS account on
     the test VM should share its password with the corporate
     identity. The default is decoupled: the local account receives
     a fresh auto-gen secret that nobody needs to know.

Add an entry here whenever a sequence introduces a new logical
username. With `strict: true` (recommended), Test-Config.ps1 fails
the cycle on the first undeclared name -- intentional, so the
production AD path stays exercised on every dev cycle.

Internal authentication key. NOT a login user: this entry holds the shared secret
that gates the pool-aggregator-service's POST /ingest write route and keys the
control proofs for the status-service /control/* routes. Leave vaultKey EMPTY
(default) to keep the host un-enrolled -- push stays disabled and control stays
loopback-only. To populate it, run `pwsh test/lab/Set-LabToken.ps1 -LabToken <code>`
with the code from the dashboard's "Lab token" tile; that sets vaultKey and
stores the token in one step. Building the caching-proxy service mints one
automatically when none exists. The vault never auto-generates for a populated
vaultKey, so the token stays lab-owned; every pool host and the proxy must hold
the SAME value. Hosts holding a legacy 'lab-auth-token' or 'pool-auth-token' entry
keep working: every reader falls back to those when this one is empty.

Adapt this mapping when a `workload.*.yml` declares
`variables.username: webuser`:

```yaml
webuser:
  localOsUser: webuser
  corporate:
    domain: "CORP"
    sam:    "alisson.sol"
    # upn:  "alisson.sol@corp.example.com"      # alternative form
  vaultKey:           "corp.alisson.sol"
  localOsPasswordRef: ""                         # decoupled: local
                                                 # OS account gets
                                                 # auto-gen secret
```

<a id="42e220c4-0018"></a>

## Guest update shutdown boundaries

Stopping periodic apt timers and disabling the independent
`unattended-upgrades` shutdown service solve separate problems. After
`dist-upgrade`, stop and disable the shutdown service inside the update step
so any repeated package or network check remains observable instead of
turning into a silent VM shutdown timeout.

The fetch wrapper executes a literal `bash -c` payload. Construct the target
for `pkill -f` from two fragments: spelling it contiguously in the payload
can make the shell match and terminate itself. Keep the split construction
even when shortening the surrounding comments.

<a id="42e220c4-0014"></a>

## Test fixture placement

The [Pester scope rules](https://yuruna.link/42d38664-000a) apply across
host, guest, and service tests. These fixture-specific constraints explain
why superficially similar test files can need different placements.

**Runner and service fixtures**

Runner collaborators imported with `-Global` must be stubbed in the global
command table. Assertions inside `InModuleScope` see the module's script scope,
so their shared counters also need a saved and restored global channel.
`Write-CycleInfraFailure` deliberately does nothing when its builders cannot
resolve; verify the resulting record, rather than only a successful invocation.
Guest-iteration tests must verify config carry-back even when an iteration
throws, and failure artifacts must be copied before a `stopOnFailure` return.
The outer cycle needs the current config and failure fields when completing
history and handling errors.

Service scripts inherit `ErrorActionPreference` because their advanced helper
functions inherit it too. Forcing `Stop` converts intended nonterminating
outcomes, such as an absent VM or best-effort cleanup, into exceptions. Keep
hard-stop decisions explicit at the operation that requires them.

**Portable native-command fixtures**

A checkout rename fixture uses an exclusive file handle on Windows and removes
write permission from the parent directory on POSIX. POSIX permits renaming
directories with open files, so an open handle alone cannot exercise access
denial there. Both fixture tokens expose `Dispose()` to restore access.

Retry fixtures inject `DEBIAN_FRONTEND=noninteractive` and
`DEBIAN_PRIORITY=critical` after `sudo`, whose environment filtering can remove
exported settings. Use the executable `env` before those assignments so
`timeout(1)` can execute the bounded command. Otherwise a debconf prompt can
block an unattended guest, or the timeout wrapper can fail before apt starts.

**`test/modules/Test.CachingProxyServiceEndpoint.Tests.ps1`**

Fresh -Force import ONCE per suite run (guards against a stale module a
prior suite loaded into this process) -- NOT per-It in BeforeEach. A
-Force re-import between Its replaces the module instance, but Pester 4
caches the Mock -ModuleName injection target per Context: the second It
in a Context then mocks the EVICTED instance while the resolver runs in
the new one, silently disabling the mock. The suite's dead-address
candidates then really get probed (3 attempts x 3 s per candidate on a
stealth-firewall host) and any It whose expected outcome depends on the
mock's reachability rule fails.

**`test/modules/Test.CachingProxyServiceStart.Tests.ps1`**

The per-platform case list is built at FILE SCOPE, and reaches the It bodies as
-TestCases, because file scope is the only part of this file that Pester's
discovery pass executes -- and discovery is where the Its below are collected.
A path derived inside BeforeAll is still $null here, so Split-Path would fail
the whole container and no Describe declared past this point would be collected
at all. Feeding the list to a `foreach` inside an It is just as wrong in the
other direction: file-scope values are gone by the time the It runs, and
`foreach` over $null iterates zero times, so the test asserts nothing and
reports green. One It per case cannot degrade that way -- a lost case is a
missing test, which the count guard below turns into a hard failure.

**`test/modules/Test.HostClockSkew.Tests.ps1`**

The three host types this file holds to the same clock contract. The list is
built at FILE scope because every Describe body is executed while the file is
being discovered, which happens before any BeforeAll runs: a list assigned in
BeforeAll is still $null when the foreach that emits the per-host Its reads it,
so the loop emits no tests at all and its Describe passes without asserting
anything. Each case then reaches its It through -TestCases for the same
reason -- discovery's loop variable is gone by the time the body executes, so a
$case read inside the body would arrive as $null and assert against an empty
path. Nothing here may have a side effect: discovery builds and discards this
scope before the first It runs.

**`test/modules/Test.Log.Tests.ps1`**

The archive fixture lives at FILE scope, not inside its Describe: a Describe
body is executed during discovery and everything it declares is discarded
before any It runs, so a helper defined there is a CommandNotFoundException by
the time the It blocks call it.

All $global:__Yuruna* access (the Yuruna.Log cross-module channels Stop-LogFile
consumes) is confined to these two suppressed helpers so the It blocks stay
clean; the production Copy-FailureArtifactsToStatusLog suppresses
PSAvoidGlobalVars for the same channels.

**`test/modules/Test.WarmResume.Tests.ps1`**

Fixtures must sit ABOVE THE FIRST Describe, not merely at file scope. Only
top-level statements executed before the first Describe land in the session
state the run phase reuses; a top-level assignment placed after one is
evaluated during discovery and then discarded, so every later It reads $null.
Declaring this inside the Describe body has the same effect for the same
reason. It is a silent failure: an empty workload list refuses a resume just
as surely as the condition each test means to check, so four of the five
tests below -- including the two asserting a specific .Reason -- kept passing
for the wrong reason while the list was empty.

**`test/modules/Test.CachingProxyServiceEndpoint.Tests.ps1`: smoke checks**

Parse the standalone smoke script instead of invoking its VM probe. Its target
must use the runner's resolver and source order. Derive its AST path purely at
file scope from `$PSCommandPath`, before discovery collects the tests. A path
taken from `BeforeAll` is unavailable during discovery and can erase the cases;
discovery must not create temporary state that no teardown would own.

**`test/modules/Test.ModuleImportScope.Tests.ps1`**

The [nested import trap](https://yuruna.link/42aaf735-0006) requires a module's
private session state. Scan `.psm1` files from Git's tracked and new, non-ignored
inventory; script-level imports have different scope semantics. A directory
allowlist can silently omit new module trees, while a filesystem walk admits
generated working copies.

Each recorded exception names a file and enclosing function, with an empty
function name for module top level. Its count is a cap: adding another private
force-import still fails. A prior `Get-Command` guard can prove that a caller
does not hold the command; other sites require a deliberate scope decision.

Caller-held pairs test that decision in an isolated runspace. `Publishes`
records whether the dependency must enter global session state, `Reloads`
records whether a held dependency must refresh, and `Call` proves its code ran.
A wrapper exporting `*` can re-export private dependency commands and remove
the caller's access when unloaded. Mirror a consuming script's import flags,
then probe exact command names: several modules share a base name, making
`Get-Module` insufficient evidence of command availability.

**`test/modules/Test.PortOwner.Tests.ps1`**

Build reservation capability at file scope before the first `Describe` because
`-Skip` is evaluated during discovery. Keep the chosen high port at script scope
so execution sees the same reservation. Computing capability in `BeforeAll`
silently skips every case on otherwise capable hosts.

The production probe binds `http://*:<port>/` to detect reservations owned by
another user. Windows HTTP.sys can deny that wildcard without elevation or a
URL ACL. A successful localhost bind followed by denied wildcard access proves
an unavailable capability; skip only that combination. Do not report a busy
port as a permissions skip or treat missing test coverage as a pass.

**`test/modules/Test.Transport.Tests.ps1`: stale keyboard handles**

Hyper-V can replace `Msvm_Keyboard` after reboot without changing the VM name.
Failed delivery must invalidate the cached association before another key is
sent. Portable fixtures shadow `Invoke-CimMethod` inside the module's session
state, exercising the same failure branch where Windows CIM is unavailable.
Remove that shadow after every case so later tests keep their own command view.

**`test/modules/Test.Catalog.Tests.ps1`.**

Importing the renderer has to be additive: it may ADD its own
commands, never REMOVE the commands of the locale module it loads for
the plural rule and the separators. A nested -Force import that is
not -Global breaks precisely that half -- it re-homes the locale
module into the renderer's private scope, so the renderer's own
functions go on working while the importer silently loses
Get-LocaleManifest and New-LocaleContext. Both imports return
normally and write to no stream, so only a resolution probe sees it.

A fresh child runspace, not this one. The loss needs the locale
module loaded BEFORE the renderer -- the order a long-lived consumer
imports in, and the reverse of the order this suite's BeforeAll
leaves behind. Probing in place would assert against an order that
cannot produce the failure.

**`test/modules/Test.ConfigServiceSync.Tests.ps1`.**

The status-service bounce must be bounded by the CHILD it starts, never by the
status service that child detaches.

Start-StatusService.ps1 launches the server as a process that outlives it by
design. Windows turns handle inheritance ON for a child whenever a std stream
is redirected, so a bounce spawned that way (`& pwsh ... *> $null` redirects)
hands the detached server the write end of the caller's stdout pipe. The server
holds it for its whole lifetime, the caller's read never sees EOF, and the
bounce blocks on the SERVER instead of the child that exited seconds ago --
silently, because the same redirection swallowed every progress line. This
drives the real code path against a stand-in start script that detaches a
long-lived grandchild the same way the real one does.

**`test/modules/Test.DiagnosticEchoVerify.Tests.ps1`.**

Test-OCRMatch is the module's other text predicate and is NOT
usable here: it answers "is this prompt on screen", splitting its
pattern on whitespace and punctuation and requiring only that each
fragment appear somewhere in the text. On a screen that still shows
the command plus a wall of garbage, every fragment is present.

The check below is the structural version of that argument, stated
without depending on Test-OCRMatch's internals: the corrupt sample
CONTAINS the healthy one verbatim, so any predicate satisfied by
"the expected content is present" passes it. Only a predicate that
also weighs what is present in EXCESS can tell them apart.

**`test/modules/Test.DownloadAgentService.Tests.ps1`.**

Order matters, and getting it wrong aborts the whole process rather than
failing a test. The responder runs on a thread job; an exception that
escapes there is unhandled by definition, and .NET tears the process down
(SIGABRT, no Pester result file). Disposing the listener underneath a live
responder is exactly such an escape -- ObjectDisposedException from inside
GetContext or the write path.

So: Stop() first, which unblocks the pending GetContext and lets the loop
break on its own; WAIT for the thread to actually exit; only then dispose.
Under parallel suite execution the thread is descheduled long enough for
the old Stop-Close-Remove order to lose this race about one run in three.

**`test/modules/Test.ExternalToolOutput.Tests.ps1`.**

"NT VIRTUAL MACHINE" is a display name and Windows localizes it, so a
lookup by name throws on a host installed in another language. The
caller then cannot prove which access entries are stale and skips the
cleanup -- safe, and silent, which is why it went unnoticed: the
cleanup simply stopped happening, one warning at a time.

The SID is computable instead: S-1-5-83-1 followed by the machine
GUID's sixteen bytes read as four little-endian unsigned 32-bit
values. Pure arithmetic, so it is checkable on any platform even
though the code around it is Windows-only.

**`test/modules/Test.FetchExecuteFastFail.Tests.ps1`.**

A healthy step several seconds in, doing the loudest thing a step does: a
container build restoring web assets. Nothing here is a shell refusal, and
the shell that would have issued one accepted its command line long ago.

This screen is kept verbatim because it, and not merely a screen of its
size, satisfies "No such file or directory" through the matcher's unbounded
strategy -- the one asking only whether each word of the pattern turns up
SOMEWHERE. Normalization folds each word to a short token, and the tokens
are then supplied by text that has nothing to do with any of the words:
'No' by a run of hex inside a sha256 digest, 'such' by a line OCR garbled
beyond reading, 'file' by "profile", 'or' by "WORKDIR", and only
'directory' by an actual directory. Thin out any of those five and the
coincidence stops reproducing, which is the point -- it never needed a
screen that said anything like the pattern.

Reproduced ASCII-only, garbled line included: that line is what a real
frame's noise looks like, and it is load-bearing here.

**`test/modules/Test.GlobalizationGates.Tests.ps1`.**

Two triggers, because one is not enough. A custom property is the
obvious one, but a producer that styles only with literal colors
has none -- and the floor rules this registry feeds are about flex
gap, grid, logical properties and safe-area units, none of which
need a custom property either. Selecting on var(--) alone is how a
whole shipped page stayed outside every floor gate: it is a page
that carries a stylesheet, not a page that carries a token.
Both tags, anywhere in the file. A producer that assembles its
document in pieces writes the open and the close from separate
statements, so they are not adjacent in the source and the body
between them is code rather than CSS -- matching an opening tag
followed by a declaration would miss exactly that shape. A bare
mention (a comment saying a page carries no inline style, a CSP
note naming the tag) has the open and no close, so requiring both
separates a producer from a sentence about one.

These artifacts are written by a generator that copies shipped text
verbatim, so a sentence naming the private repository arrives in one
of them without anybody typing it there. Unlike a document or an
installer it cannot earn a reviewed exception either: the publisher's
allowlist names source paths that point at the private source on
purpose, and a generated file is never one of them. The result is a
published artifact sending a reader to a repository they cannot clone,
reported against the generated file at release time rather than
against the source line that has to change. Failing here names that
line instead. The repair is to interpolate the name at the call site
rather than write it into the sentence.

PSUseBOMForUnicodeEncodedFile wants a byte-order mark on the mirrored
pseudo catalog, which carries non-ASCII text. This project will not
write one: a BOM is invisible in every editor, rides into hashes, and
breaks byte-for-byte consumers -- and the drift check for these very
files compares their bytes. The renderer that reads them requires
PowerShell 7, which decodes UTF-8 without a mark correctly, so the
condition the rule protects against does not arise here.

The exception is bounded rather than waved through: any OTHER analyzer
finding in generated output is a real defect in the emitter, and this
is what would notice one.

**`test/modules/Test.GuestDhcpIdentity.Tests.ps1`.**

The guests that receive the shared seed network-config. Scoped by RENDERER,
not by "does it run cloud-init": the file identifies interfaces by name
glob, and only netplan resolves a glob against real devices.

That scope is a safety boundary rather than an optimization. Handing
cloud-init a network-config REPLACES the fallback it would otherwise
generate, so seeding this file to a guest whose renderer cannot resolve the
glob does not leave it "unpinned" -- it leaves it with no network
configuration at all, nothing claiming the NIC, and no route in but the
console it can no longer use to say so.

The test above names ONE file, and that is the hole a regression walked
through: seeding a DIFFERENT network-config -- matched by MAC rather than
by glob -- passed it while leaving every Amazon guest on every hypervisor
with its NIC unclaimed and IFF_UP clear.

The invariant is not "do not ship that file". It is "ship this guest NO
network-config by any name". Supplying one replaces cloud-init's fallback,
so any config its renderer fails to resolve to a real device is strictly
worse than none, and whether a given match form resolves under
NetworkManager is not decidable by reading the parser -- only a lab cycle
settles it. So the seed stays empty and the destination filename is what
gets asserted, not the source.

The late-command above patches /target, which does not exist while the
installer is running its own DHCP client. So the pin has to be in the
autoinstall `network:` key as well, or the INSTALL draws a lease under a
machine-id DUID and the installed system draws a second one under the MAC:
two addresses out of a shared pool for one guest, every build, with the
installer's copy belonging to no guest that still exists.

The key is per-hypervisor because the interface name is: enp0s1 on UTM,
enp1s0 on KVM, eth0 on Hyper-V. Asserted for every overlay rather than
for one, because a pin present on the host someone tested and absent on
its siblings is the shape this whole suite exists to catch.

**`test/modules/Test.GuestHostname.Tests.ps1`.**

agetty prints "login:" once and never reprints it. Console writes that
land afterwards (cloud-init's closing banner, subiquity's tail) scroll the
prompt away, and the screen then stops changing -- so an OCR wait for
"login:" can only spend its entire budget against a frozen frame. The
recovery is a keypress, and it only works if it happens BEFORE the wait.

Placed after the wait it is unreachable, because a retry block restarts at
its first step: every attempt re-enters the wait that cannot pass and no
attempt ever reaches the nudge. That shape cost three full waits per guest
on several hosts before it was found, and it is invisible in a passing run
because the ordering only matters once the prompt has been overwritten.

**`test/modules/Test.HostClockSkew.Tests.ps1`.**

One-shot NTP responder on loopback: answers a single request with a
transmit timestamp $OffsetSeconds BEHIND now, so a correct probe reports
the host as that many seconds ahead.

The socket is bound by the CALLER and handed in already listening
(ThreadJob shares this process, so the live object crosses intact). A
responder that binds inside the job races the probe, and a datagram sent
to a not-yet-bound loopback port draws an ICMP port-unreachable that
fails the receive instantly -- which reads exactly like "no time server
answered" and turns this into a flaky test of the wrong thing.

What has to hold is that running Enable-TestAutomation.ps1
disciplines the clock. Two shapes do that: the host's
Set-*HostConditionSet calls the sync and the script calls that
function, or the script calls the sync itself. Requiring only the
first shape let one host keep its clock fix inside a function no
script ever called -- green, and protecting nothing.

Bind to locals so the parameters are referenced in the body:
the predicates below capture them, but PSReviewUnusedParameter
cannot see a use that occurs only inside a FindAll scriptblock.

**`test/modules/Test.HyperVHostSeedIp.Tests.ps1`.**

The seed carries an address the guest can correct later; Get-BestHostIp is
the other half of that -- what this host publishes about ITSELF, to the pool
directory the guest corrects against. A wrong answer here is worse than a
stale seed: it does not merely age, it never changes, so a host that is
renumbering constantly looks perfectly still and no guest is ever told.

Behavioral rather than AST, because what has to hold is the choice the
function makes among adapters, and no call shape expresses that. The function
body is lifted out of the module and run against a recorded inventory, so
these cases need neither a live hypervisor nor a Windows host.

**`test/modules/Test.KvmGuestAddressDiscovery.Tests.ps1`.**

WHY THIS BLOCK IS HERE. Get-GuestAddress answers with the VM name when no
probe found an address. Four consumers test for that; Invoke-GuestSsh was
the one that did not, so every transient discovery miss became a hard step
failure reported as a guest script error. The invariant is asserted by name
in Test.GuestAddressChurn.Tests.ps1, but only for a consumer that already
got it right -- these cases cover the one that did not.

ssh really runs. Both targets below fail in single-digit milliseconds (an
unresolvable name, and a loopback that refuses the harness key), so the
cases stay fast without mocking System.Diagnostics.Process.

**`test/modules/Test.LabHealth.Tests.ps1`.**

The module reaches Send-CycleEventSafely and Write-CycleInfraFailure through
Get-Command, and a module's command lookup falls back to the GLOBAL session
state -- not to this file's script scope -- so the stubs have to be global
functions to be found at all. That is the same resolution path a real cycle
uses.

What they collect is appended to files in the per-test runtime dir rather than
to a global variable: the collection then has the same lifetime as the
directory an It block already creates and deletes, so no state survives a test
to color the next one.

**`test/modules/Test.MacScreenLockPassword.Tests.ps1`.**

The regression is easy to reintroduce, because the unpiped form is
shorter and appears to work -- the password is accepted, it is merely
also displayed.

Invocations, read from the AST -- not matching lines. Comment-based
help quotes the wrong form on purpose, and the copy-paste one-liner is
a string literal, so a line scan reports both and the guard gets
muted. A CommandAst is a thing that actually runs.

The test for "piped" is structural: the invocation must not be the
first element of its pipeline. Something ahead of it in the pipeline
IS its stdin, which is the whole difference between a password that is
fed in and one that a person types at an unmasked prompt.

**`test/modules/Test.SequenceEngineFlags.Tests.ps1`.**

A verb's registered class is its DEFAULT -- what it failed as when no
failPattern matched. For fetchAndExecute that is the completion marker
never arriving (a wait_timeout), most often because the fetched script
is blocked on a stalled package mirror. Registering
pattern_matched_failure here asserted the opposite -- that the wrapper
printed its failure tag -- and nothing downstream re-checks it, so a
plain timeout was reported as a script error, routed to
pause_and_inspect ("auto-retry would just re-trigger it") and excluded
from the warm-resume allow-list. That turned a transient upstream
stall into a dead cycle needing an operator.
Build-SequenceFailureRecord still reclassifies to
pattern_matched_failure when a pattern really matched.

**`test/modules/Test.StashAddressResolution.Tests.ps1`.**

Substitute the discovery the marker refresh consumes. $IpAnswer supplies
Get-VMIp's replies in order (the last repeats, so a case can model "stale,
stale, then the real one"); $Healthy is the set of addresses that answer
/healthz. State lives in the global scope because the substitutes are called
from inside a module, which has a session state of its own.

The substitutes are declared HERE, from a helper each case calls, rather than
at file scope: Pester scans the file to collect its blocks and runs those
blocks afterwards, and a function declared during the scan is not present by
the time the cases execute -- Get-VMIp comes back "not recognized" and the
refresh resolves nothing, which reads exactly like the bug under test.

**`test/modules/Test.StatusCycleArchive.Tests.ps1`.**

On the download path the message is incomplete until the operator
attaches the file themselves, so the sentence that says so has to
carry weight on the page.

What is pinned is the instruction inside an emphasis element, not the
sentence that carries it. Copy on this page gets reworded, and a test
that fails on a synonym teaches its reader to edit the expectation
rather than look at the page -- which costs the assertion the only
thing it was for. The tempered dot keeps the match inside ONE <strong>,
so emphasis somewhere else on the page plus the words somewhere else
again cannot satisfy it between them.

**`test/modules/Test.StatusServiceLocale.Tests.ps1`.**

The commands a fresh server runspace has to end up holding, derived from the
server rather than listed here. A hand-written list goes stale the first time
a route starts calling something new, and a stale guard is worse than none
because it still reports green.

Two rules select them. Whatever the server calls out of a module it imports
-ErrorAction Stop is mandatory by the server's own declaration. And whatever
the locale resolver calls is mandatory however its module was imported: that
function runs on every localized route, and it reads the language lock inside
a try/catch that swallows the loss, so a missing config command degrades the
page silently rather than failing loudly.

**`test/modules/Test.SudoDiscipline.Tests.ps1`.**

A refusal has to be told apart from an ordinary command failure on TEXT:
sudo exits 1 for "I will not run this unprompted" and the commands it
runs exit 1 for their own reasons. That text is implementation-specific.
The C sudo says "a password is required" / "no tty present"; sudo-rs --
the default sudo on Ubuntu from 25.10 on -- says "interactive
authentication is required".

A matcher that knows only one of them does not fail loudly on a host
running the other. It quietly reclassifies every refusal as a command
result, and the caller then reports its fallback cause -- a stale NAS
password, an absent directory -- for as long as that host lives. So the
two spellings have to travel together, in whatever expression tests for
one of them.

The phrases are held in variables so this scan does not flag its own
source: the literals below never share a line with a match operator.

**`test/modules/Test.UtmGhostRegistration.Tests.ps1`.**

The fake reproduces the behaviors of the real tool that the code
under test exists for: `status` is the only trustworthy answer to "is
this name registered", and `delete` exits 0 whether or not it deleted
anything, printing the OSStatus -2700 notice when the bundle it wants
to trash is not there. YRN_FAKE_DELETE_FAILS makes every delete fail,
standing in for a bundle UTM cannot move (open file handles, a
permissions fault). YRN_FAKE_STATUS_MODE turns `status` into a denial
at exit 0 (deny0), an OSStatus failure at exit 1 (oserr) or a call
that never returns (hang); YRN_FAKE_DENY_AFTER_DELETE makes every
status after the first delete a denial. Every call is logged. The
fake refuses to run at all without its directories, so no removal it
performs can reach outside them.

**`test/modules/Test.WarmResume.Tests.ps1`.**

ip_not_discovered belongs here for the same reason as the rest: a step
that never resolved an address never reached the guest, so nothing it
might have done is in doubt and replaying it is as sound as replaying a
timeout. The count is asserted alongside the members so that widening
this list stays a deliberate act -- a class added without a reason to
trust a replay is how warm resume starts re-running work that changed
something.
payload_unavailable earns its place on the same ground: the guest ran
the fetch wrapper and no source served the script, so the step did
nothing and there is nothing a replay could do twice. Its usual cause
-- a host that renumbered while the guest still held the old address --
is normally gone by the next attempt.

<a id="42e220c4-0015"></a>

## Installer preflight

Check the running session's elevation capability before requirements questions
or password prompts. A group grant made after login is absent from that
session's authorization token. Bare `id -Gn` reports the session groups;
adding a username queries the account database instead. macOS requires
`admin`, while Ubuntu accepts `sudo` or `wheel`. Read sudo's exit status
rather than matching refusal wording that differs between implementations.

Keep the installers' `group_names` functions identical. Preserve the names
`id` returns even if another group no longer resolves. Consumers drain the
output with `grep -x ... >/dev/null`: `grep -q` can close the pipe early and
make `pipefail` interpret the writer's SIGPIPE as a failed authorization check.

The Windows bootstrap can run under Windows PowerShell 5.1 or an emulated x64
process on ARM64. Read the machine environment in HKLM first, then
`RuntimeInformation.OSArchitecture` when its property exists, then environment
fallbacks. A missing managed static property can return null without an error;
check its existence before reading it. `PROCESSOR_ARCHITEW6432` precedes
`PROCESSOR_ARCHITECTURE` because the latter can describe the emulated process.
Report unsupported architecture names explicitly. The guest JDK installer
uses `Win32_Processor.Architecture` through CIM, so native ARM64 detection
also works in Windows PowerShell 5.1 and older emulated PowerShell processes.
Both the JDK and update phases accept native identities 9 (AMD64) and 12 (ARM64)
and reject unsupported or unavailable identities before package installation.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.18.1

Back to [Yuruna](../README.md)
