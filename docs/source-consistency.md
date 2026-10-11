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

Treat region labels as shared vocabulary, not prose to paraphrase. Recurring
host phases use `Log level from environment`, `Import host modules`, `Seek the
base image`, `Remove existing VM`, `Create copies and files for VM`, `Clean up
temporary files`, `Installation summary`, and `Completion`. Service guests keep
`Initialize environment`, `Detect architecture`, `Load retry helpers`, `Service
user`, `Load service helpers`, `Service tunables`, `Storage paths`, `Package
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

<a id="42e220c4-0005"></a>

## Guest installers

Ubuntu 24 and 26 carry the same update, Code, Kubernetes, n8n, OpenClaw, and PostgreSQL installer logic. A release name is not a reason to omit retry behavior, installed-tool checks, or diagnostics. Common phases use the same region names and order. Amazon Linux retains dnf/RPM paths, Amazon Corretto, NodeSource RPM installation, and PostgreSQL 17; Ubuntu uses apt, nvm, and PostgreSQL 18. PostgreSQL is stopped after Ubuntu's package installation because its post-install script starts a cluster, and before Amazon's installation because its RPM leaves initialization to the caller. Windows uses elevation and Windows package tools. The macOS update workload runs after Setup Assistant; the IPSW restore already supplies its initial operating system.

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
| Pool-control | Go daemon plus PowerShell and `powershell-yaml` for pool-admin commands. Its repository path and intent store must be usable; audit and status files live under the pool share's service directory. |
| Download agent | Go daemon with optional PowerShell/Fido support for Windows image discovery. Missing support marks that image family unavailable so hosts can fetch it themselves. The pool share holds both images and service state. |

Pool-control resolves an explicitly seeded intent-store location before the pool NAS default and initializes the resolved directory when it is not yet a Git repository. Testing only whether the seed was empty would skip initialization of a newly seeded NAS path. Git initialization runs as the service user, matching CIFS ownership; `core.fileMode=false` avoids changes caused solely by mount-provided modes.

Stash permits `STASH_HTTP_ADDR=''` to disable HTTP, so its shell expansion uses `${name-default}` rather than substituting the default for an explicitly empty value. Its aggregator URL prefers an operator override over `/etc/yuruna/pool.env`. Presence beacons use the owning host's identity and must recur faster than the aggregator's extension-health grace so a changed address is announced promptly.

The stash build stages `extension-sdk` beside `server`, preserving the Go module's `replace ... => ../extension-sdk` relationship. A workspace file outside the staged build does not satisfy that dependency. The systemd unit grants access to local state and share paths; its optional share path has a `-` prefix so an absent NAS mount does not fail namespace setup in local-storage mode. See [stash](https://yuruna.link/42f5e921), [pool-control](https://yuruna.link/4207d71a-000c), and [download agent](https://yuruna.link/4268e4cb).

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
the VM is running, configure NAT forwarding, probe readiness, publish the
readiness result, and report the deployed source or collect diagnostics.
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
the caching proxy's read-only intent alias; that alias sync runs on the
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
while a fallback is still available; an unusable path selects a temporary file.
Printed transcript instructions remain operator text and are not a wire format
for callers to parse.

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
decorative headers do not return, and PowerShell help stays inside a function
when a region precedes it. The suite also compares Ubuntu release sequences and
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
Git hooks and attributes, Terraform, and TOML alongside the host/guest scripts.
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

The Windows QEMU installer can leave `qemu-img` off PATH. Its fallback paths
must match `Resolve-QemuImgCommand` in `host/modules/Yuruna.Image.psm1`.
Strip the constant copyright suffix from its first version line. Keep this
fallback Windows-only: a missing package-manager link on macOS or Linux is
a defect that installation repair must detect.

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

Last review: 2026.10.11.1

Back to [Yuruna](../README.md)
